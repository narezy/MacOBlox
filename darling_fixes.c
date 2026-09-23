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
