/* Minimal X11 client that only hides/shows the cursor with XFixes.
 *
 * Why: under Xwayland, XWarpPointer moves only the X server's pointer and the
 * next Wayland motion undoes it, so recentering during mouse lock bounced the
 * pointer. Xwayland emulates warps properly (locked pointer + relative motion)
 * while the X cursor is hidden with XFixes, as Wine does. Darling wraps
 * libX11 but not libXfixes, and sending the requests through Xlib internals
 * is unsafe (_XGetRequest/_XReply need Xlib's internal display lock, which
 * XLockDisplay does not take; a test hung in XUnlockDisplay). So this speaks
 * the X protocol directly on its own socket: setup, QueryExtension("XFIXES"),
 * XFixes QueryVersion, then HideCursor/ShowCursor on the root window. The
 * hide is per-client and ends automatically if this connection closes. */

typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned long size_t;
struct darwin_sockaddr_un { unsigned char len, family; char path[104]; };
extern int socket(int, int, int);
extern int connect(int, const void *, socklen_t);
extern ssize_t write(int, const void *, size_t);
extern ssize_t read(int, void *, size_t);
extern int close(int);
extern char *getenv(const char *);

static int x_socket = -1;
static unsigned char xfixes_opcode;
static unsigned int root_window;

static int write_all(const void *data, size_t length) {
    const unsigned char *bytes = data;
    while (length) {
        ssize_t written = write(x_socket, bytes, length);
        if (written <= 0)
            return 0;
        bytes += written;
        length -= (size_t)written;
    }
    return 1;
}

static int read_all(void *data, size_t length) {
    unsigned char *bytes = data;
    while (length) {
        ssize_t got = read(x_socket, bytes, length);
        if (got <= 0)
            return 0;
        bytes += got;
        length -= (size_t)got;
    }
    return 1;
}

/* Read the 32-byte reply to the last request, skipping events. */
static int read_reply(unsigned char reply[32]) {
    for (int guard = 0; guard < 256; guard++) {
        if (!read_all(reply, 32))
            return 0;
        if (reply[0] == 0)
            return 0; /* X error */
        if (reply[0] == 1) {
            unsigned int extra = *(unsigned int *)(reply + 4) * 4;
            unsigned char skip[256];
            while (extra) {
                size_t chunk = extra < sizeof skip ? extra : sizeof skip;
                if (!read_all(skip, chunk))
                    return 0;
                extra -= (unsigned int)chunk;
            }
            return 1;
        }
    }
    return 0;
}

static int display_number(void) {
    const char *display = getenv("DISPLAY");
    int number = 0;
    if (!display)
        return 0;
    while (*display && *display != ':')
        display++;
    if (*display == ':')
        display++;
    while (*display >= '0' && *display <= '9')
        number = number * 10 + (*display++ - '0');
    return number;
}

static int connect_display(void) {
    struct darwin_sockaddr_un address = {0};
    int number = display_number();
    /* Darling's /tmp is private; the host's X socket is under SystemRoot. */
    const char prefix[] = "/Volumes/SystemRoot/tmp/.X11-unix/X";
    int length = 0;
    while (prefix[length]) {
        address.path[length] = prefix[length];
        length++;
    }
    char digits[12];
    int count = 0;
    do {
        digits[count++] = (char)('0' + number % 10);
        number /= 10;
    } while (number && count < 11);
    while (count)
        address.path[length++] = digits[--count];
    address.family = 1; /* AF_UNIX */
    address.len = (unsigned char)(2 + length + 1);
    x_socket = socket(1, 1 /* SOCK_STREAM */, 0);
    if (x_socket < 0)
        return 0;
    if (connect(x_socket, &address, sizeof address) != 0) {
        close(x_socket);
        x_socket = -1;
        return 0;
    }
    return 1;
}

static int setup(void) {
    /* 'l' = little endian, protocol 11.0, no authorization. */
    unsigned char request[12] = {'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    unsigned char header[8];
    if (!write_all(request, sizeof request) || !read_all(header, sizeof header) || header[0] != 1)
        return 0;
    unsigned int body_length = *(unsigned short *)(header + 6) * 4u;
    static unsigned char body[1 << 16];
    if (body_length > sizeof body || !read_all(body, body_length))
        return 0;
    unsigned int vendor_length = *(unsigned short *)(body + 16);
    unsigned int formats = body[21];
    unsigned int screen = 32 + ((vendor_length + 3) & ~3u) + 8 * formats;
    if (screen + 4 > body_length)
        return 0;
    root_window = *(unsigned int *)(body + screen);
    return 1;
}

static int query_xfixes(void) {
    unsigned char request[16] = {98 /* QueryExtension */, 0, 4, 0, 6, 0, 0, 0,
                                 'X', 'F', 'I', 'X', 'E', 'S', 0, 0};
    unsigned char reply[32];
    if (!write_all(request, sizeof request) || !read_reply(reply) || !reply[8])
        return 0;
    xfixes_opcode = reply[9];
    unsigned char version[12] = {xfixes_opcode, 0 /* QueryVersion */, 3, 0, 5, 0, 0, 0, 0, 0, 0, 0};
    return write_all(version, sizeof version) && read_reply(reply);
}

int macoblox_raw_xfixes_open(void) {
    if (x_socket >= 0)
        return 1;
    if (!connect_display())
        return 0;
    if (!setup() || !query_xfixes()) {
        close(x_socket);
        x_socket = -1;
        return 0;
    }
    return 1;
}

int macoblox_raw_xfixes_set_hidden(int hidden) {
    if (x_socket < 0)
        return 0;
    unsigned char request[8] = {xfixes_opcode, hidden ? 29 /* HideCursor */ : 30 /* ShowCursor */,
                                2, 0};
    *(unsigned int *)(request + 4) = root_window;
    return write_all(request, sizeof request);
}
