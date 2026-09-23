/* connectx() for Darling.
 *
 * Darling has no connectx (syscall 447: "Unimplemented syscall", ENOSYS).
 * Roblox's newer network transport ("RbxTransport DummyClient", QUIC over
 * UDP) connects its socket with it; the socket then stays unconnected, every
 * packet is lost, and joining a place stalls about 11 s until the client
 * gives up with NoResponse and falls back to RakNet.
 *
 * Emulated the way Apple documents it: bind to the source address if one is
 * given, connect to the destination, then send the optional initial data. */
typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned long size_t;
struct iovec { void *base; size_t length; };
struct msghdr {
    void *name; socklen_t namelen; struct iovec *iov; int iovlen;
    void *control; socklen_t controllen; int flags;
};
typedef struct {
    unsigned int srcif;            /* interface index, not needed here */
    const void *srcaddr; socklen_t srcaddrlen;
    const void *dstaddr; socklen_t dstaddrlen;
} sa_endpoints_t;

extern int bind(int, const void *, socklen_t);
extern int connect(int, const void *, socklen_t);
extern ssize_t sendmsg(int, const struct msghdr *, int);
extern int *__error(void);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define EINVAL 22
#define EINPROGRESS 36

extern int connectx(int, const sa_endpoints_t *, unsigned int, unsigned int,
                    const struct iovec *, unsigned int, size_t *, unsigned int *);

static int macoblox_connectx(int fd, const sa_endpoints_t *endpoints, unsigned int associd,
                             unsigned int flags, const struct iovec *iov, unsigned int iovcnt,
                             size_t *sent, unsigned int *connid) {
    (void)associd;
    (void)flags;
    if (sent)
        *sent = 0;
    if (!endpoints || !endpoints->dstaddr) {
        *__error() = EINVAL;
        return -1;
    }
    if (endpoints->srcaddr && bind(fd, endpoints->srcaddr, endpoints->srcaddrlen) < 0)
        return -1;
    int result = connect(fd, endpoints->dstaddr, endpoints->dstaddrlen);
    if (result < 0)
        return -1;  /* EINPROGRESS for a non-blocking TCP socket, as on macOS */
    if (connid)
        *connid = 1;
    if (iov && iovcnt) {
        struct msghdr message = {0, 0, (struct iovec *)iov, (int)iovcnt, 0, 0, 0};
        ssize_t written = sendmsg(fd, &message, 0);
        if (written < 0)
            return -1;
        if (sent)
            *sent = (size_t)written;
    }
    return 0;
}
DYLD_INTERPOSE(macoblox_connectx, connectx)
