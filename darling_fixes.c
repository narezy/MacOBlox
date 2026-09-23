/* Workarounds for Darling runtime bugs that are not specific to one API.
 *
 * pthread_mutex_lock: Darling implements contended waits through darlingserver
 * (psynch_mutexwait) and can lose the wakeup, so a thread sleeps forever on a
 * mutex that is already free. Observed: the RakNet receive thread stuck in
 * std::mutex::lock with its socket queue full, game disconnected after 20 s.
 * Acquire with trylock plus yield/short sleeps first; only a mutex that stays
 * busy for ~200 ms falls back to the real (psynch) wait. A recursive mutex
 * already held by this thread succeeds in trylock, as with a real lock. */
extern int pthread_mutex_lock(void *);
extern int pthread_mutex_trylock(void *);
extern int sched_yield(void);
extern int usleep(unsigned int);
extern char *getenv(const char *);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define DARWIN_EBUSY 16

static int native_mutex(void) {
    static int native = -1;
    if (native < 0) {
        const char *value = getenv("MACOBLOX_NATIVE_MUTEX");
        native = value && value[0] ? 1 : 0;
    }
    return native;
}

static int macoblox_pthread_mutex_lock(void *mutex) {
    if (native_mutex())
        return pthread_mutex_lock(mutex);
    int result = pthread_mutex_trylock(mutex);
    if (result != DARWIN_EBUSY)
        return result;
    for (int attempt = 0; attempt < 64; attempt++) {
        sched_yield();
        result = pthread_mutex_trylock(mutex);
        if (result != DARWIN_EBUSY)
            return result;
    }
    /* ~200 ms of 50 us naps before trusting the psynch wait. */
    for (int attempt = 0; attempt < 4000; attempt++) {
        usleep(50);
        result = pthread_mutex_trylock(mutex);
        if (result != DARWIN_EBUSY)
            return result;
    }
    return pthread_mutex_lock(mutex);
}
DYLD_INTERPOSE(macoblox_pthread_mutex_lock, pthread_mutex_lock)

/* Thread stacks: every Darling system call goes through an RPC to
 * darlingserver, which needs much more stack than the macOS kernel call it
 * replaces. FMOD creates its audio threads with small stacks that are enough
 * on macOS; under Darling one overflowed inside the RPC code
 * (dserver_rpc_hooks_receive_message, stack pointer just below its last
 * page) a few seconds after a game with sound started. Raise small requested
 * stack sizes to 1 MB. Threads with a caller-provided stack are left alone. */
typedef struct { long opaque[8]; } darwin_pthread_attr_t; /* 64 bytes on x86_64 */
extern int pthread_attr_setstacksize(darwin_pthread_attr_t *, unsigned long);
extern int pthread_attr_getstacksize(const darwin_pthread_attr_t *, unsigned long *);
extern int pthread_attr_getstackaddr(const darwin_pthread_attr_t *, void **);
extern int pthread_create(void **, const darwin_pthread_attr_t *, void *(*)(void *), void *);

#define MIN_THREAD_STACK (1UL << 20)

static int macoblox_pthread_attr_setstacksize(darwin_pthread_attr_t *attr, unsigned long size) {
    if (size < MIN_THREAD_STACK)
        size = MIN_THREAD_STACK;
    return pthread_attr_setstacksize(attr, size);
}
DYLD_INTERPOSE(macoblox_pthread_attr_setstacksize, pthread_attr_setstacksize)

static int macoblox_pthread_create(void **thread, const darwin_pthread_attr_t *attr,
                                   void *(*start)(void *), void *argument) {
    if (attr) {
        void *address = 0;
        unsigned long size = 0;
        if (pthread_attr_getstackaddr(attr, &address) == 0 && !address &&
            pthread_attr_getstacksize(attr, &size) == 0 && size < MIN_THREAD_STACK)
            pthread_attr_setstacksize((darwin_pthread_attr_t *)attr, MIN_THREAD_STACK);
    }
    return pthread_create(thread, attr, start, argument);
}
DYLD_INTERPOSE(macoblox_pthread_create, pthread_create)

/* Condition variables: the same lost psynch wakeups hit pthread_cond_wait.
 * Leaving a game, the network thread waited 9.4 s for a signal that had
 * already been sent (until its own ~10 s timeout). POSIX allows spurious
 * wakeups and correct callers re-check their predicate, so waits are cut
 * into slices that return as spurious wakeups. Every wait is an RPC to
 * darlingserver, so the slice starts at 50 ms and doubles up to 1 s while
 * the same thread keeps waiting on the same condition (flat 50 ms slices
 * cost darlingserver half a core). MACOBLOX_NATIVE_COND=1 turns this off. */
struct darwin_timespec { long tv_sec; long tv_nsec; };
struct darwin_timeval { long tv_sec; int tv_usec; };
extern int pthread_cond_wait(void *, void *);
extern int pthread_cond_timedwait(void *, void *, const struct darwin_timespec *);
extern int gettimeofday(struct darwin_timeval *, void *);

#define DARWIN_ETIMEDOUT 60
#define COND_SLICE_NS 50000000L

static int native_cond(void) {
    static int native = -1;
    if (native < 0) {
        const char *value = getenv("MACOBLOX_NATIVE_COND");
        native = value && value[0] ? 1 : 0;
    }
    return native;
}

#define COND_SLICE_MAX_NS 1000000000L

/* Per-thread slice state in pthread TSD slots: __thread variables would
 * go through dyld's TLV code, which itself waits on locks during startup
 * and deadlocked the client right after NSApplicationMain. */
extern int pthread_key_create(unsigned long *, void (*)(void *));
extern void *pthread_getspecific(unsigned long);
extern int pthread_setspecific(unsigned long, const void *);
static unsigned long cond_key, slice_key;
static volatile int keys_ready;

__attribute__((constructor)) static void create_slice_keys(void) {
    if (pthread_key_create(&cond_key, 0) == 0 && pthread_key_create(&slice_key, 0) == 0)
        keys_ready = 1;
}

/* The slice for this wait: doubles while the thread keeps timing out on the
 * same condition variable, starts again at 50 ms otherwise. */
static long next_slice(void *cond) {
    if (!keys_ready)
        return COND_SLICE_NS;
    long length = (long)pthread_getspecific(slice_key);
    if (cond != pthread_getspecific(cond_key) || !length) {
        pthread_setspecific(cond_key, cond);
        length = COND_SLICE_NS;
    } else if (length < COND_SLICE_MAX_NS) {
        length *= 2;
    }
    pthread_setspecific(slice_key, (void *)length);
    return length;
}

static void wait_finished(int sliced_out) {
    if (!sliced_out && keys_ready)
        pthread_setspecific(slice_key, 0);
}

static struct darwin_timespec slice_deadline_ns(long length) {
    struct darwin_timeval now;
    gettimeofday(&now, 0);
    struct darwin_timespec deadline = {now.tv_sec, now.tv_usec * 1000L + length};
    while (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }
    return deadline;
}

static int macoblox_pthread_cond_wait(void *cond, void *mutex) {
    if (native_cond())
        return pthread_cond_wait(cond, mutex);
    struct darwin_timespec deadline = slice_deadline_ns(next_slice(cond));
    int result = pthread_cond_timedwait(cond, mutex, &deadline);
    wait_finished(result == DARWIN_ETIMEDOUT);
    return result == DARWIN_ETIMEDOUT ? 0 : result;
}
DYLD_INTERPOSE(macoblox_pthread_cond_wait, pthread_cond_wait)

static int macoblox_pthread_cond_timedwait(void *cond, void *mutex, const struct darwin_timespec *abstime) {
    if (native_cond() || !abstime)
        return pthread_cond_timedwait(cond, mutex, abstime);
    struct darwin_timespec slice = slice_deadline_ns(next_slice(cond));
    int caller_deadline_first = abstime->tv_sec < slice.tv_sec ||
        (abstime->tv_sec == slice.tv_sec && abstime->tv_nsec <= slice.tv_nsec);
    if (caller_deadline_first) {
        wait_finished(0);
        return pthread_cond_timedwait(cond, mutex, abstime);
    }
    int result = pthread_cond_timedwait(cond, mutex, &slice);
    wait_finished(result == DARWIN_ETIMEDOUT);
    return result == DARWIN_ETIMEDOUT ? 0 : result;
}
DYLD_INTERPOSE(macoblox_pthread_cond_timedwait, pthread_cond_timedwait)

extern int pthread_cond_timedwait_relative_np(void *, void *, const struct darwin_timespec *);

static int macoblox_pthread_cond_timedwait_relative_np(void *cond, void *mutex,
                                                       const struct darwin_timespec *relative) {
    if (native_cond() || !relative)
        return pthread_cond_timedwait_relative_np(cond, mutex, relative);
    long length = next_slice(cond);
    if (relative->tv_sec * 1000000000L + relative->tv_nsec <= length) {
        wait_finished(0);
        return pthread_cond_timedwait_relative_np(cond, mutex, relative);
    }
    struct darwin_timespec slice = {length / 1000000000L, length % 1000000000L};
    int result = pthread_cond_timedwait_relative_np(cond, mutex, &slice);
    wait_finished(result == DARWIN_ETIMEDOUT);
    return result == DARWIN_ETIMEDOUT ? 0 : result;
}
DYLD_INTERPOSE(macoblox_pthread_cond_timedwait_relative_np, pthread_cond_timedwait_relative_np)
