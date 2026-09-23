/* DNS for Roblox only. MACOBLOX_DNS=127.0.0.1:PORT points at the launcher's
 * local forwarder, which sends the queries over DNS-over-TLS to the server
 * chosen in the launcher (e.g. Quad9). Some Roblox image hosts do not resolve
 * through ISP or system resolvers in some regions, and plain UDP DNS to
 * public resolvers is unreliable there, while the rest of the system keeps
 * its own DNS.
 *
 * macoblox_dns_resolve() answers A lookups by asking the forwarder over UDP
 * and builds the addrinfo list itself; anything it cannot handle (IP
 * literals, IPv6-only requests, named services, no answer) falls back to
 * Darling's resolver. freeaddrinfo() is wrapped so lists built here are freed
 * here. */

typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned long size_t;
struct darwin_sockaddr_in {
    unsigned char len, family;
    unsigned short port;
    unsigned int address;
    char zero[8];
};
/* Darwin struct addrinfo (x86_64). */
struct darwin_addrinfo {
    int flags, family, socktype, protocol;
    socklen_t addrlen;
    char *canonname;
    void *addr;
    struct darwin_addrinfo *next;
};
struct darwin_pollfd { int fd; short events, revents; };

extern char *getenv(const char *);
extern int socket(int, int, int);
extern int connect(int, const void *, socklen_t);
extern ssize_t send(int, const void *, size_t, int);
extern ssize_t recv(int, void *, size_t, int);
extern int close(int);
extern int poll(struct darwin_pollfd *, unsigned int, int);
extern void *calloc(size_t, size_t);
extern void free(void *);
extern unsigned long long mach_absolute_time(void);
extern void freeaddrinfo(void *);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define AF_INET_DARWIN 2
#define EAI_NONAME_DARWIN 8
#define MAX_ADDRESSES 16

static int forwarder_port(unsigned int *address, unsigned short *port) {
    const char *value = getenv("MACOBLOX_DNS");
    if (!value || !value[0])
        return 0;
    unsigned int parts[4] = {0, 0, 0, 0};
    int part = 0;
    unsigned int number = 0;
    const char *c = value;
    for (; *c && *c != ':'; c++) {
        if (*c == '.') {
            if (part > 3) return 0;
            parts[part++] = number;
            number = 0;
        } else if (*c >= '0' && *c <= '9') {
            number = number * 10 + (unsigned int)(*c - '0');
        } else {
            return 0;
        }
    }
    if (part != 3 || *c != ':')
        return 0;
    parts[3] = number;
    number = 0;
    for (c++; *c >= '0' && *c <= '9'; c++)
        number = number * 10 + (unsigned int)(*c - '0');
    if (!number || number > 65535)
        return 0;
    *address = parts[0] | parts[1] << 8 | parts[2] << 16 | parts[3] << 24; /* network order */
    *port = (unsigned short)((number >> 8) | ((number & 255) << 8));
    return 1;
}

static int is_ip_literal(const char *node) {
    int digits_and_dots = 1;
    for (const char *c = node; *c; c++) {
        if (*c == ':')
            return 1; /* IPv6 literal */
        if (!((*c >= '0' && *c <= '9') || *c == '.'))
            digits_and_dots = 0;
    }
    return digits_and_dots;
}

static int parse_port(const char *service, unsigned short *port) {
    unsigned int number = 0;
    if (!service) {
        *port = 0;
        return 1;
    }
    if (!*service)
        return 0;
    for (const char *c = service; *c; c++) {
        if (*c < '0' || *c > '9')
            return 0; /* named service: let the system resolve it */
        number = number * 10 + (unsigned int)(*c - '0');
        if (number > 65535)
            return 0;
    }
    *port = (unsigned short)((number >> 8) | ((number & 255) << 8));
    return 1;
}

/* Skip a possibly compressed DNS name; returns the offset after it or -1. */
static int skip_name(const unsigned char *packet, int length, int offset) {
    while (offset < length) {
        unsigned char label = packet[offset];
        if (label == 0)
            return offset + 1;
        if ((label & 0xC0) == 0xC0)
            return offset + 2 <= length ? offset + 2 : -1;
        offset += label + 1;
    }
    return -1;
}

/* Returns the number of A records found, 0 for none, -1 on failure, and -2
 * for NXDOMAIN. */
static int query_forwarder(const char *node, unsigned int *addresses) {
    unsigned int server;
    unsigned short server_port;
    if (!forwarder_port(&server, &server_port))
        return -1;
    unsigned char query[300];
    unsigned short id = (unsigned short)(mach_absolute_time() >> 3);
    int length = 0;
    query[length++] = (unsigned char)(id >> 8);
    query[length++] = (unsigned char)id;
    query[length++] = 0x01; /* recursion desired */
    query[length++] = 0x00;
    query[length++] = 0; query[length++] = 1; /* one question */
    for (int i = 0; i < 6; i++) query[length++] = 0;
    const char *label = node;
    while (*label) {
        const char *end = label;
        while (*end && *end != '.') end++;
        int size = (int)(end - label);
        if (size == 0 || size > 63 || length + size + 6 > (int)sizeof query)
            return -1;
        query[length++] = (unsigned char)size;
        for (int i = 0; i < size; i++) query[length++] = (unsigned char)label[i];
        label = *end ? end + 1 : end;
    }
    query[length++] = 0;
    query[length++] = 0; query[length++] = 1; /* type A */
    query[length++] = 0; query[length++] = 1; /* class IN */

    int fd = socket(AF_INET_DARWIN, 2 /* SOCK_DGRAM */, 0);
    if (fd < 0)
        return -1;
    struct darwin_sockaddr_in address = {sizeof address, AF_INET_DARWIN, server_port, server, {0}};
    int found = -1;
    if (connect(fd, &address, sizeof address) == 0) {
        for (int attempt = 0; attempt < 2 && found == -1; attempt++) {
            if (send(fd, query, (size_t)length, 0) != length)
                break;
            struct darwin_pollfd wait = {fd, 1, 0};
            if (poll(&wait, 1, 2500) <= 0)
                continue;
            unsigned char reply[1500];
            ssize_t got = recv(fd, reply, sizeof reply, 0);
            if (got < 12 || reply[0] != query[0] || reply[1] != query[1])
                continue;
            int rcode = reply[3] & 15;
            if (rcode == 3) {
                found = -2;
                break;
            }
            if (rcode != 0)
                break;
            int answers = reply[6] << 8 | reply[7];
            int offset = skip_name(reply, (int)got, 12);
            if (offset < 0)
                break;
            offset += 4;
            found = 0;
            for (int i = 0; i < answers && offset >= 0 && offset + 10 <= got; i++) {
                offset = skip_name(reply, (int)got, offset);
                if (offset < 0 || offset + 10 > got)
                    break;
                int type = reply[offset] << 8 | reply[offset + 1];
                int data_length = reply[offset + 8] << 8 | reply[offset + 9];
                offset += 10;
                if (offset + data_length > got)
                    break;
                if (type == 1 && data_length == 4 && found < MAX_ADDRESSES)
                    addresses[found++] = (unsigned int)reply[offset] |
                                         (unsigned int)reply[offset + 1] << 8 |
                                         (unsigned int)reply[offset + 2] << 16 |
                                         (unsigned int)reply[offset + 3] << 24;
                offset += data_length;
            }
        }
    }
    close(fd);
    return found;
}

/* Lists built here, so freeaddrinfo can tell them apart. */
static void *volatile owned_lists[256];

static void remember(void *list) {
    for (int i = 0; i < 256; i++)
        if (__sync_bool_compare_and_swap(&owned_lists[i], (void *)0, list))
            return;
}

static int forget(void *list) {
    for (int i = 0; i < 256; i++)
        if (owned_lists[i] == list && __sync_bool_compare_and_swap(&owned_lists[i], list, (void *)0))
            return 1;
    return 0;
}

/* 0 on success with *result set, an EAI error, or -1 to use the system resolver. */
int macoblox_dns_resolve(const char *node, const char *service, const void *hints_pointer,
                         void **result) {
    const struct darwin_addrinfo *hints = hints_pointer;
    unsigned short port;
    if (!node || !*node || !result || is_ip_literal(node) || !parse_port(service, &port))
        return -1;
    if (hints && hints->family != 0 && hints->family != AF_INET_DARWIN)
        return -1;
    if (hints && (hints->flags & 0x4 /* AI_NUMERICHOST */))
        return -1;
    const char *local = "localhost";
    int is_local = 1;
    for (int i = 0; local[i] || node[i]; i++)
        if (local[i] != node[i]) { is_local = 0; break; }
    if (is_local)
        return -1;

    unsigned int addresses[MAX_ADDRESSES];
    int count = query_forwarder(node, addresses);
    if (count == -2)
        return EAI_NONAME_DARWIN;
    if (count <= 0)
        return -1;

    int socktypes[2] = {1 /* STREAM */, 2 /* DGRAM */};
    int protocols[2] = {6, 17};
    int kinds = 2;
    if (hints && hints->socktype) {
        socktypes[0] = hints->socktype;
        protocols[0] = hints->protocol ? hints->protocol : (hints->socktype == 2 ? 17 : 6);
        kinds = 1;
    }
    struct darwin_addrinfo *head = 0, *tail = 0;
    for (int i = 0; i < count; i++) {
        for (int kind = 0; kind < kinds; kind++) {
            struct darwin_addrinfo *entry = calloc(1, sizeof *entry + sizeof(struct darwin_sockaddr_in));
            if (!entry)
                break;
            struct darwin_sockaddr_in *address = (struct darwin_sockaddr_in *)(entry + 1);
            address->len = sizeof *address;
            address->family = AF_INET_DARWIN;
            address->port = port;
            address->address = addresses[i];
            entry->family = AF_INET_DARWIN;
            entry->socktype = socktypes[kind];
            entry->protocol = protocols[kind];
            entry->addrlen = sizeof *address;
            entry->addr = address;
            if (tail) tail->next = entry; else head = entry;
            tail = entry;
        }
    }
    if (!head)
        return -1;
    remember(head);
    *result = head;
    return 0;
}

static void macoblox_freeaddrinfo(void *list) {
    if (list && forget(list)) {
        struct darwin_addrinfo *entry = list;
        while (entry) {
            struct darwin_addrinfo *next = entry->next;
            free(entry); /* sockaddr lives in the same allocation */
            entry = next;
        }
        return;
    }
    freeaddrinfo(list);
}
DYLD_INTERPOSE(macoblox_freeaddrinfo, freeaddrinfo)
