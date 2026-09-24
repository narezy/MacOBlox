/* Sampling profiler for the game's main (render) thread.
 *
 * MACOBLOX_PROFILE=1: a helper thread interrupts the main thread about 250
 * times a second with SIGPROF; the handler notes the instruction pointer.
 * Every 10 s the helper prints the hottest places: Mach-O code by image and
 * symbol (dladdr), everything else (Linux libraries such as Mesa) as raw
 * addresses, which /proc/<pid>/maps turns into library offsets. Sampling
 * starts 20 s after launch. Off by default: under Darling every signal goes
 * through darlingserver. */
typedef unsigned long size_t;
typedef long ssize_t;
typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } dl_info_t;
struct darwin_sigaction_t { void (*handler)(int, void *, void *); unsigned int mask; int flags; };

extern char *getenv(const char *);
extern int pthread_create(void **, const void *, void *(*)(void *), void *);
extern void *pthread_self(void);
extern int pthread_kill(void *, int);
extern int usleep(unsigned int);
extern int sigaction(int, const struct darwin_sigaction_t *, struct darwin_sigaction_t *);
extern int dladdr(const void *, dl_info_t *);
extern int snprintf(char *, size_t, const char *, ...);
extern ssize_t write(int, const void *, size_t);
extern void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
extern int strcmp(const char *, const char *);

#define DARWIN_SIGPROF 27
#define SA_SIGINFO 0x40
#define RING 8192

static void *main_thread;
static unsigned long ring[RING];
static volatile unsigned long ring_head;

static void on_sample(int signal, void *info, void *context) {
    (void)signal; (void)info;
    unsigned long long *uc = context;
    unsigned long long *mc = uc ? (unsigned long long *)uc[6] : 0;
    if (!mc)
        return;
    unsigned long index = __sync_fetch_and_add(&ring_head, 1);
    ring[index % RING] = (unsigned long)mc[18]; /* RIP */
}

struct bucket { const char *image, *symbol; unsigned long raw; long count; };
static struct bucket buckets[512];

static int by_count(const void *a, const void *b) {
    long x = ((const struct bucket *)a)->count, y = ((const struct bucket *)b)->count;
    return (y > x) - (y < x);
}

static void report(unsigned long from, unsigned long to) {
    int used = 0;
    long total = 0, images = 0;
    for (unsigned long i = from; i < to; i++) {
        unsigned long rip = ring[i % RING];
        dl_info_t info = {0, 0, 0, 0};
        const char *image = 0, *symbol = 0;
        unsigned long raw = 0;
        if (dladdr((void *)rip, &info) && info.fname) {
            image = info.fname;
            for (const char *c = info.fname; *c; c++)
                if (*c == '/') image = c + 1;
            symbol = info.sname ? info.sname : "?";
            images++;
        } else {
            raw = rip & ~0xfffUL; /* 4 KB pages keep the table small */
        }
        int found = -1;
        for (int b = 0; b < used; b++)
            if (buckets[b].raw == raw && buckets[b].image == image && buckets[b].symbol == symbol) {
                found = b;
                break;
            }
        if (found < 0 && used < 512) {
            buckets[used] = (struct bucket){image, symbol, raw, 0};
            found = used++;
        }
        if (found >= 0)
            buckets[found].count++;
        total++;
    }
    if (!total)
        return;
    qsort(buckets, (size_t)used, sizeof buckets[0], by_count);
    char line[256];
    int length = snprintf(line, sizeof line, "[MacOBlox PROFILE] %ld samples, %ld%% in Mach-O code\n",
                          total, images * 100 / total);
    write(2, line, (size_t)length);
    for (int b = 0; b < used && b < 30; b++) {
        if (buckets[b].image)
            length = snprintf(line, sizeof line, "[MacOBlox PROFILE] %5.1f%% %s %s\n",
                              buckets[b].count * 100.0 / total, buckets[b].image, buckets[b].symbol);
        else
            length = snprintf(line, sizeof line, "[MacOBlox PROFILE] %5.1f%% linux 0x%lx\n",
                              buckets[b].count * 100.0 / total, buckets[b].raw);
        if (length > 0)
            write(2, line, (size_t)length);
    }
}

static void *sampler(void *unused) {
    (void)unused;
    unsigned long reported = 0;
    /* Interrupting the main thread while the client starts up stalled it;
     * start sampling once it is running. */
    for (int wait = 0; wait < 20; wait++)
        usleep(1000000);
    for (int tick = 1;; tick++) {
        usleep(4000);
        pthread_kill(main_thread, DARWIN_SIGPROF);
        if (tick % 2500 == 0) { /* about every 10 s */
            unsigned long head = ring_head;
            if (head - reported > RING)
                reported = head - RING;
            report(reported, head);
            reported = head;
        }
    }
    return 0;
}

__attribute__((constructor)) static void start_profiler(void) {
    const char *value = getenv("MACOBLOX_PROFILE");
    if (!value || value[0] != '1')
        return;
    main_thread = pthread_self();
    struct darwin_sigaction_t action = {on_sample, 0, SA_SIGINFO};
    sigaction(DARWIN_SIGPROF, &action, 0);
    void *thread;
    pthread_create(&thread, 0, sampler, 0);
}
