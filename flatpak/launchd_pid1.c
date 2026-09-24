/* Makes launchd PID 1 inside Darling without a PID namespace.
 *
 * launchd only runs as the system launchd, which starts Darling's daemons
 * (shellspawn among them), when getpid() == 1. Without root Darling cannot
 * give it its own PID namespace (see darling-noroot.c), so launchd keeps
 * its real PID; this library, inserted into launchd only, answers getpid()
 * with 1 there. kill(1, ...) is sent to the real launchd, never to the
 * sandbox's own PID 1.
 *
 * launchd also becomes the child subreaper, as PID 1 of Darling's own
 * namespace would be: a daemon that double-forks (Roblox's crash handler)
 * then stays a descendant of darlingserver. Without root, darlingserver may
 * only read and write the memory of its descendants (Yama ptrace_scope 1);
 * reparented to the sandbox's init, the crash handler failed every call. */
typedef int pid_t;

extern pid_t getpid(void);
extern pid_t getppid(void);
extern int kill(pid_t, int);
extern const char *getprogname(void);
extern int strcmp(const char *, const char *);
extern char *getenv(const char *);
extern int setenv(const char *, const char *, int);
extern int unsetenv(const char *);
extern int snprintf(char *, unsigned long, const char *, ...);
extern long strtol(const char *, char **, int);
/* Darling processes are Linux processes: the syscall instruction reaches
 * the Linux kernel directly (Darling's own linux_syscall is not exported). */
static long linux_prctl(long option, long value) {
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(157L /* prctl */), "D"(option), "S"(value)
                     : "rcx", "r11", "memory");
    return result;
}
#define PR_SET_CHILD_SUBREAPER 36

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

static int in_launchd;
static pid_t launchd_pid;

__attribute__((constructor)) static void setup(void) {
    const char *name = getprogname();
    in_launchd = name && strcmp(name, "launchd") == 0;
    if (in_launchd) {
        char text[16];
        launchd_pid = getpid();
        snprintf(text, sizeof text, "%d", launchd_pid);
        setenv("MACOBLOX_LAUNCHD_PID", text, 1);
        /* Only launchd needs this library; keep it out of its children. */
        unsetenv("DYLD_INSERT_LIBRARIES");
        linux_prctl(PR_SET_CHILD_SUBREAPER, 1);
    } else {
        const char *text = getenv("MACOBLOX_LAUNCHD_PID");
        launchd_pid = text ? (pid_t)strtol(text, 0, 10) : 0;
    }
}

static pid_t macoblox_getpid(void) {
    return in_launchd ? 1 : getpid();
}
DYLD_INTERPOSE(macoblox_getpid, getpid)

static pid_t macoblox_getppid(void) {
    pid_t parent = getppid();
    return launchd_pid && parent == launchd_pid ? 1 : parent;
}
DYLD_INTERPOSE(macoblox_getppid, getppid)

static int macoblox_kill(pid_t pid, int signal) {
    if (pid == 1 && launchd_pid)
        pid = launchd_pid;
    return kill(pid, signal);
}
DYLD_INTERPOSE(macoblox_kill, kill)
