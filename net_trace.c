/* UDP receive safety net and tracing.
 *
 * Roblox's network threads wait for socket readiness with kqueue, using
 * edge-triggered EV_CLEAR events (Asio). Darling emulates kqueue on top of
 * epoll, and a lost "data arrived" edge leaves the reader asleep: the socket
 * buffer fills, the kernel drops every further datagram, so no new edge ever
 * comes and the game connection dies with AckTimeout after 20 s. Observed:
 * RakNet socket with a full 512 KB receive queue and thousands of drops.
 *
 * kevent() is therefore wrapped: UDP sockets registered for EVFILT_READ are
 * remembered, waits are split into 50 ms slices, and between slices those
 * sockets are checked with MSG_PEEK. Pending data without an event gets a
 * synthesized EVFILT_READ event, i.e. level-triggered behaviour for UDP.
 *
 * MACOBLOX_TRACE_UDP=1 also prints socket activity every two seconds;
 * MACOBLOX_TRACE_UDP=2 also logs the first 6000 UDP packets one by one (time,
 * size, peer), to see where a handshake waits. */
typedef unsigned int socklen_t;
typedef long ssize_t;
typedef unsigned long size_t;
extern char *getenv(const char *);
extern int getsockopt(int, int, int, void *, socklen_t *);
extern ssize_t recvfrom(int, void *, size_t, int, void *, socklen_t *);
extern ssize_t recvmsg(int, void *, int);
extern ssize_t sendto(int, const void *, size_t, int, const void *, socklen_t);
extern ssize_t sendmsg(int, const void *, int);
extern int poll(void *, unsigned int, int);
extern int kevent(int, const void *, int, void *, int, const void *);
extern int pthread_create(void **, const void *, void *(*)(void *), void *);
extern unsigned int sleep(unsigned int);
extern int snprintf(char *, size_t, const char *, ...);
extern ssize_t write(int, const void *, size_t);
extern int *__error(void);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

extern unsigned long long mach_absolute_time(void);
#define MSG_PEEK 0x2
#define MSG_DONTWAIT 0x80

static int enabled = -1;
static volatile long udp_recv_calls, udp_recv_ok, udp_recv_bytes, udp_recv_eagain;
static volatile long udp_send_calls, udp_send_ok, udp_send_fail;
static volatile long poll_calls, kevent_calls;
extern void *pthread_self(void);
static void *reader_thread[1024];
static volatile unsigned long long last_read_time[1024];
static volatile int stall_dumped[1024];
static volatile long synthesized_events;
static volatile long emulated_blocking_receives;
static volatile int last_send_errno;

static int trace_enabled(void) {
    if (enabled < 0) {
        const char *value = getenv("MACOBLOX_TRACE_UDP");
        enabled = value && value[0] ? (value[0] == '2' ? 2 : 1) : 0;
    }
    return enabled;
}

static volatile long packets_logged;
static void log_connected(const char *direction, int fd, long result, int error);
static unsigned long long trace_start;

/* One line per packet: ms since the first logged packet, direction, fd,
 * bytes (or -errno) and the peer from a sockaddr_in. */
static void log_packet(const char *direction, int fd, long result, int error, const void *peer) {
    /* Only network packets: Roblox's threads wake each other with one-byte
     * datagrams on a local socket pair, thousands per second. */
    const unsigned char *family = peer;
    if (trace_enabled() != 2 || !family || family[1] != 2 /* AF_INET */ ||
        __sync_add_and_fetch(&packets_logged, 1) > 6000)
        return;
    unsigned long long now = mach_absolute_time();
    if (!trace_start)
        trace_start = now;
    const unsigned char *address = peer;
    char where[40] = "";
    if (address && address[1] == 2 /* AF_INET */)
        snprintf(where, sizeof where, " %u.%u.%u.%u:%u", address[4], address[5], address[6],
                 address[7], (unsigned)(address[2] << 8 | address[3]));
    char line[160];
    int length = snprintf(line, sizeof line, "[MacOBlox PKT] %7.1fms %s fd=%d %ld%s\n",
                          (now - trace_start) / 1e6, direction, fd,
                          result < 0 ? -(long)error : result, where);
    if (length > 0)
        write(2, line, (size_t)length);
}

static int is_udp(int fd) {
    int type = 0;
    socklen_t length = sizeof type;
    return getsockopt(fd, 0xffff /* SOL_SOCKET */, 0x1008 /* SO_TYPE */, &type, &length) == 0 &&
           type == 2 /* SOCK_DGRAM */;
}

/* Stall dump: when a UDP socket has queued data that its reader thread has
 * not read for 3 s, interrupt that thread with SIGUSR2 and print where it is. */
typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } dl_info_t;
extern int dladdr(const void *, dl_info_t *);
extern int pthread_kill(void *, int);
struct darwin_sigaction_t { void (*handler)(int, void *, void *); unsigned int mask; int flags; };
extern int sigaction(int, const struct darwin_sigaction_t *, struct darwin_sigaction_t *);

static void put(const char *text) {
    size_t length = 0;
    while (text[length]) length++;
    write(2, text, length);
}
static void put_address(void *address) {
    char line[512];
    dl_info_t info = {0, 0, 0, 0};
    int length;
    if (dladdr(address, &info) && info.fname) {
        const char *name = info.fname;
        for (const char *c = info.fname; *c; c++) if (*c == '/') name = c + 1;
        if (info.sname)
            length = snprintf(line, sizeof line, "    %p %s (%s+%ld)\n", address, name, info.sname,
                              (long)((char *)address - (char *)info.saddr));
        else
            length = snprintf(line, sizeof line, "    %p %s+0x%lx\n", address, name,
                              (unsigned long)((char *)address - (char *)info.fbase));
    } else {
        length = snprintf(line, sizeof line, "    %p\n", address);
    }
    if (length > 0) write(2, line, (size_t)length);
}
static void stall_signal_handler(int signal, void *info, void *context) {
    (void)signal; (void)info;
    if (!trace_enabled())
        return;
    put("[MacOBlox UDP] stalled reader thread is at:\n");
    unsigned long long *uc = (unsigned long long *)context;
    unsigned long long *mc = uc ? (unsigned long long *)uc[6] : 0;
    if (!mc) return;
    put_address((void *)mc[18]); /* RIP */
    void **frame = (void **)mc[8]; /* RBP */
    for (int depth = 0; depth < 40 && frame; depth++) {
        if ((unsigned long)frame < 0x1000 || ((unsigned long)frame & 7)) break;
        put_address(frame[1]);
        frame = (void **)frame[0];
    }
}

static void check_stalls(void) {
    static int handler_installed;
    if (!handler_installed) {
        struct darwin_sigaction_t action = {stall_signal_handler, 0, 0x0040 /* SA_SIGINFO */};
        sigaction(31 /* SIGUSR2 */, &action, 0);
        handler_installed = 1;
    }
    unsigned long long now = mach_absolute_time();
    for (int fd = 0; fd < 1024; fd++) {
        if (!reader_thread[fd] || !last_read_time[fd] || stall_dumped[fd])
            continue;
        /* A read recorded after `now` was taken (another thread) gives a
         * negative age; a socket idle for long may belong to a reader thread
         * that has exited, and signalling it could crash the game. */
        if (last_read_time[fd] > now || now - last_read_time[fd] < 2000000000ULL ||
            now - last_read_time[fd] > 30000000000ULL)
            continue;
        char byte;
        int saved = *__error();
        ssize_t peek = recvfrom(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT, 0, 0);
        *__error() = saved;
        if (peek < 0)
            continue;
        stall_dumped[fd] = 1;
        char line[160];
        int length = snprintf(line, sizeof line,
                              "[MacOBlox UDP] STALL fd=%d has queued data, last read %llus ago\n",
                              fd, (now - last_read_time[fd]) / 1000000000ULL);
        if (length > 0) write(2, line, (size_t)length);
        pthread_kill(reader_thread[fd], 31);
    }
}

static void *reporter(void *unused) {
    (void)unused;
    long previous[9] = {0};
    for (unsigned long tick = 1;; tick++) {
        sleep(1);
        check_stalls();
        if (!trace_enabled() || (tick & 1))
            continue;
        long now[9] = {udp_recv_calls, udp_recv_ok, udp_recv_bytes, udp_recv_eagain,
                       udp_send_calls, udp_send_ok, udp_send_fail, poll_calls, kevent_calls};
        char line[320];
        int length = snprintf(line, sizeof line,
            "[MacOBlox UDP] t=%lus recv calls=%ld ok=%ld bytes=%ld eagain=%ld | "
            "send calls=%ld ok=%ld fail=%ld errno=%d | poll=%ld kevent=%ld | synthesized=%ld emulated=%ld\n",
            tick, now[0] - previous[0], now[1] - previous[1], now[2] - previous[2],
            now[3] - previous[3], now[4] - previous[4], now[5] - previous[5],
            now[6] - previous[6], last_send_errno, now[7] - previous[7], now[8] - previous[8],
            synthesized_events, emulated_blocking_receives);
        if (length > 0)
            write(2, line, (size_t)length);
        for (int index = 0; index < 9; index++)
            previous[index] = now[index];
    }
    return 0;
}

/* The stall watchdog always runs: a reader thread that stops draining a UDP
 * socket with queued data is interrupted with SIGUSR2, which ends a lost
 * psynch wait in Darling (the thread re-checks the lock and continues). */
__attribute__((constructor)) static void start_reporter(void) {
    void *thread;
    pthread_create(&thread, 0, reporter, 0);
}


static void count_receive(int fd, ssize_t result) {
    if (!is_udp(fd))
        return;
    if (trace_enabled())
        __sync_add_and_fetch(&udp_recv_calls, 1);
    if (fd >= 0 && fd < 1024) {
        reader_thread[fd] = pthread_self();
        if (result > 0) {
            last_read_time[fd] = mach_absolute_time();
            stall_dumped[fd] = 0;
        }
    }
    if (!trace_enabled())
        return;
    if (result > 0) {
        __sync_add_and_fetch(&udp_recv_ok, 1);
        __sync_add_and_fetch(&udp_recv_bytes, result);
    } else if (result < 0 && (*__error() == 35 /* EAGAIN */)) {
        __sync_add_and_fetch(&udp_recv_eagain, 1);
    }
}

static void count_send(int fd, ssize_t result) {
    if (!trace_enabled() || !is_udp(fd))
        return;
    __sync_add_and_fetch(&udp_send_calls, 1);
    if (result >= 0) {
        __sync_add_and_fetch(&udp_send_ok, 1);
    } else {
        __sync_add_and_fetch(&udp_send_fail, 1);
        last_send_errno = *__error();
    }
}

/* Darling's blocking receive can stay asleep while datagrams are queued: the
 * RakNet receive thread blocked in recvfrom() on a socket with a full 512 KB
 * queue and never returned. For blocking UDP sockets, wait with poll() in
 * 50 ms slices and read with MSG_DONTWAIT instead, honouring SO_RCVTIMEO. */
extern int fcntl(int, int, ...);
struct darwin_pollfd { int fd; short events, revents; };
struct darwin_timeval { long tv_sec; int tv_usec; };
#define DARWIN_O_NONBLOCK 0x4
#define DARWIN_EAGAIN 35
#define DARWIN_EINTR 4

static int wait_readable_or_timeout(int fd, unsigned long long start, long long timeout_ns) {
    struct darwin_pollfd entry = {fd, 1 /* POLLIN */, 0};
    int slice = 50;
    if (timeout_ns > 0) {
        long long left = timeout_ns - (long long)(mach_absolute_time() - start);
        if (left <= 0)
            return 0;
        if (left < 50000000LL)
            slice = (int)(left / 1000000LL) + 1;
    }
    poll(&entry, 1, slice);
    return 1;
}

static int emulate_blocking(int fd, int flags, long long *timeout_ns) {
    if (flags & MSG_DONTWAIT)
        return 0;
    int status = fcntl(fd, 3 /* F_GETFL */);
    if (status < 0 || (status & DARWIN_O_NONBLOCK) || !is_udp(fd))
        return 0;
    struct darwin_timeval timeout = {0, 0};
    socklen_t length = sizeof timeout;
    *timeout_ns = 0;
    if (getsockopt(fd, 0xffff, 0x1006 /* SO_RCVTIMEO */, &timeout, &length) == 0)
        *timeout_ns = timeout.tv_sec * 1000000000LL + timeout.tv_usec * 1000LL;
    return 1;
}

static ssize_t traced_recvfrom(int fd, void *buffer, size_t size, int flags, void *from,
                               socklen_t *from_length) {
    long long timeout_ns;
    if (emulate_blocking(fd, flags, &timeout_ns)) {
        __sync_add_and_fetch(&emulated_blocking_receives, 1);
        unsigned long long start = mach_absolute_time();
        socklen_t length_in = from_length ? *from_length : 0;
        for (;;) {
            if (from_length)
                *from_length = length_in;
            ssize_t result = recvfrom(fd, buffer, size, flags | MSG_DONTWAIT, from, from_length);
            if (result >= 0 || *__error() != DARWIN_EAGAIN) {
                int saved = *__error();
                if (is_udp(fd))
                    log_packet("recv", fd, result, saved, from);
                count_receive(fd, result);
                *__error() = saved;
                return result;
            }
            if (!wait_readable_or_timeout(fd, start, timeout_ns)) {
                *__error() = DARWIN_EAGAIN;
                return -1;
            }
        }
    }
    ssize_t result = recvfrom(fd, buffer, size, flags, from, from_length);
    int saved = *__error();
    if (!(result < 0 && saved == DARWIN_EAGAIN) && trace_enabled() == 2 && is_udp(fd))
        log_packet("recv", fd, result, saved, from);
    count_receive(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_recvfrom, recvfrom)

static ssize_t traced_recvmsg(int fd, void *message, int flags) {
    long long timeout_ns;
    if (emulate_blocking(fd, flags, &timeout_ns)) {
        __sync_add_and_fetch(&emulated_blocking_receives, 1);
        unsigned long long start = mach_absolute_time();
        /* struct msghdr: name length at offset 8 is updated on return. */
        socklen_t name_length = *(socklen_t *)((char *)message + 8);
        for (;;) {
            *(socklen_t *)((char *)message + 8) = name_length;
            ssize_t result = recvmsg(fd, message, flags | MSG_DONTWAIT);
            if (result >= 0 || *__error() != DARWIN_EAGAIN) {
                int saved = *__error();
                if (trace_enabled() == 2 && is_udp(fd)) {
                    if (*(void **)message)
                        log_packet("recv", fd, result, saved, *(void **)message);
                    else
                        log_connected("recv", fd, result, saved);
                }
                count_receive(fd, result);
                *__error() = saved;
                return result;
            }
            if (!wait_readable_or_timeout(fd, start, timeout_ns)) {
                *__error() = DARWIN_EAGAIN;
                return -1;
            }
        }
    }
    ssize_t result = recvmsg(fd, message, flags);
    int saved = *__error();
    if (!(result < 0 && saved == DARWIN_EAGAIN) && trace_enabled() == 2 && is_udp(fd)) {
        if (*(void **)message)
            log_packet("recv", fd, result, saved, *(void **)message);
        else
            log_connected("recv", fd, result, saved);
    }
    count_receive(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_recvmsg, recvmsg)

static ssize_t traced_sendto(int fd, const void *buffer, size_t size, int flags,
                             const void *to, socklen_t to_length) {
    ssize_t result = sendto(fd, buffer, size, flags, to, to_length);
    int saved = *__error();
    if (trace_enabled() == 2 && is_udp(fd))
        log_packet("send", fd, result, saved, to);
    count_send(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_sendto, sendto)

static ssize_t traced_sendmsg(int fd, const void *message, int flags) {
    ssize_t result = sendmsg(fd, message, flags);
    int saved = *__error();
    if (trace_enabled() == 2 && is_udp(fd)) {
        const void *name = message ? *(void *const *)message : 0;
        if (name)
            log_packet("send", fd, result, saved, name);
        else
            log_connected("send", fd, result, saved);
    }
    count_send(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_sendmsg, sendmsg)

/* Connected UDP sockets (the QUIC transport) use send()/recv(), which do
 * not go through sendto()/recvfrom(); log them with the connected peer. */
extern ssize_t send(int, const void *, size_t, int);
extern ssize_t recv(int, void *, size_t, int);
extern int getpeername(int, void *, socklen_t *);

static void log_connected(const char *direction, int fd, long result, int error) {
    if (trace_enabled() != 2 || (result < 0 && error == DARWIN_EAGAIN) || !is_udp(fd))
        return;
    unsigned char peer[128];
    socklen_t length = sizeof peer;
    if (getpeername(fd, peer, &length) == 0)
        log_packet(direction, fd, result, error, peer);
}

static ssize_t traced_send(int fd, const void *buffer, size_t size, int flags) {
    ssize_t result = send(fd, buffer, size, flags);
    int saved = *__error();
    log_connected("send", fd, result, saved);
    count_send(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_send, send)

static ssize_t traced_recv(int fd, void *buffer, size_t size, int flags) {
    ssize_t result = recv(fd, buffer, size, flags);
    int saved = *__error();
    log_connected("recv", fd, result, saved);
    count_receive(fd, result);
    *__error() = saved;
    return result;
}
DYLD_INTERPOSE(traced_recv, recv)

static int traced_poll(void *fds, unsigned int count, int timeout) {
    if (trace_enabled())
        __sync_add_and_fetch(&poll_calls, 1);
    return poll(fds, count, timeout);
}
DYLD_INTERPOSE(traced_poll, poll)

struct darwin_kevent {
    unsigned long ident;
    short filter;
    unsigned short flags;
    unsigned int fflags;
    long data;
    void *udata;
};
struct darwin_timespec { long tv_sec, tv_nsec; };
#define EVFILT_READ (-1)
#define EV_ADD 0x0001
#define EV_DELETE 0x0002
#define EV_ENABLE 0x0004
#define EV_DISABLE 0x0008
#define MAX_WATCHED 256
static struct {
    int queue, fd, enabled;
    unsigned short flags;
    void *udata;
} watched[MAX_WATCHED];
static volatile int watched_lock;

static volatile long synthesized_by_fd[1024];

static void lock_watched(void) {
    while (__sync_lock_test_and_set(&watched_lock, 1)) {}
}
static void unlock_watched(void) { __sync_lock_release(&watched_lock); }

static void record_changes(int queue, const struct darwin_kevent *changes, int count) {
    for (int index = 0; index < count; index++) {
        const struct darwin_kevent *change = &changes[index];
        if (change->filter != EVFILT_READ || change->ident >= 1024)
            continue;
        int fd = (int)change->ident;
        if (!(change->flags & (EV_ADD | EV_DELETE | EV_ENABLE | EV_DISABLE)))
            continue;
        if ((change->flags & EV_ADD) && !is_udp(fd))
            continue;
        lock_watched();
        int slot = -1, free_slot = -1;
        for (int i = 0; i < MAX_WATCHED; i++) {
            if (watched[i].fd > 0 && watched[i].queue == queue && watched[i].fd == fd) slot = i;
            else if (watched[i].fd <= 0 && free_slot < 0) free_slot = i;
        }
        if (change->flags & EV_DELETE) {
            if (slot >= 0) watched[slot].fd = 0;
        } else if (change->flags & EV_ADD) {
            if (slot < 0) slot = free_slot;
            if (slot >= 0) {
                watched[slot].queue = queue;
                watched[slot].fd = fd;
                watched[slot].flags = change->flags & ~(EV_ADD | EV_ENABLE | EV_DISABLE);
                watched[slot].udata = change->udata;
                watched[slot].enabled = !(change->flags & EV_DISABLE);
            }
        } else if (slot >= 0) {
            watched[slot].enabled = (change->flags & EV_ENABLE) != 0;
        }
        unlock_watched();
    }
}

/* Append synthesized read events for watched UDP sockets of this queue that
 * have data waiting but are missing from the returned events. */
static int add_missed_events(int queue, struct darwin_kevent *events, int returned, int capacity) {
    int fds[MAX_WATCHED];
    unsigned short flags[MAX_WATCHED];
    void *udata[MAX_WATCHED];
    int count = 0;
    lock_watched();
    for (int i = 0; i < MAX_WATCHED; i++) {
        if (watched[i].fd > 0 && watched[i].queue == queue && watched[i].enabled) {
            fds[count] = watched[i].fd;
            flags[count] = watched[i].flags;
            udata[count] = watched[i].udata;
            count++;
        }
    }
    unlock_watched();
    for (int i = 0; i < count && returned < capacity; i++) {
        int reported = 0;
        for (int j = 0; j < returned; j++)
            if (events[j].filter == EVFILT_READ && events[j].ident == (unsigned long)fds[i])
                reported = 1;
        if (reported)
            continue;
        char byte;
        int saved = *__error();
        ssize_t peek = recvfrom(fds[i], &byte, 1, MSG_PEEK | MSG_DONTWAIT, 0, 0);
        *__error() = saved;
        if (peek < 0)
            continue;
        struct darwin_kevent *event = &events[returned++];
        event->ident = (unsigned long)fds[i];
        event->filter = EVFILT_READ;
        event->flags = flags[i];
        event->fflags = 0;
        event->data = peek;
        event->udata = udata[i];
        __sync_add_and_fetch(&synthesized_events, 1);
        __sync_add_and_fetch(&synthesized_by_fd[fds[i]], 1);
    }
    return returned;
}

static int queue_has_watched(int queue) {
    int found = 0;
    lock_watched();
    for (int i = 0; i < MAX_WATCHED && !found; i++)
        found = watched[i].fd > 0 && watched[i].queue == queue && watched[i].enabled;
    unlock_watched();
    return found;
}

static int traced_kevent(int queue, const void *changes, int change_count, void *events,
                         int event_count, const void *timeout) {
    if (trace_enabled())
        __sync_add_and_fetch(&kevent_calls, 1);
    if (change_count > 0 && changes)
        record_changes(queue, (const struct darwin_kevent *)changes, change_count);
    if (event_count <= 0 || !events || !queue_has_watched(queue))
        return kevent(queue, changes, change_count, events, event_count, timeout);

    const struct darwin_timespec *limit = (const struct darwin_timespec *)timeout;
    unsigned long long start = mach_absolute_time();
    long long budget = limit ? limit->tv_sec * 1000000000LL + limit->tv_nsec : -1;
    struct darwin_kevent *out = (struct darwin_kevent *)events;
    int first = 1;
    for (;;) {
        /* Data already waiting without an event: report it right away. */
        int missed = add_missed_events(queue, out, 0, event_count);
        if (missed > 0) {
            if (first && change_count > 0) {
                /* Apply the change list without waiting, keep its events too. */
                struct darwin_timespec zero = {0, 0};
                int real = kevent(queue, changes, change_count, out + missed,
                                  event_count - missed, &zero);
                return real > 0 ? missed + real : missed;
            }
            return missed;
        }
        long long slice = 50000000LL;
        if (budget >= 0) {
            long long left = budget - (long long)(mach_absolute_time() - start);
            if (left <= 0) left = 0;
            if (left < slice) slice = left;
        }
        struct darwin_timespec wait = {slice / 1000000000LL, slice % 1000000000LL};
        int result = kevent(queue, first ? changes : 0, first ? change_count : 0,
                            events, event_count, &wait);
        first = 0;
        if (result != 0)
            return result;
        if (budget >= 0 && (long long)(mach_absolute_time() - start) >= budget)
            return 0;
    }
}
DYLD_INTERPOSE(traced_kevent, kevent)
