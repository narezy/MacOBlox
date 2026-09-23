/* Darling/x86_64 only. Its sys_exit first calls native libc exit(), which
 * executes inherited Mesa atexit callbacks in forked children. _exit must
 * terminate without callbacks; use the same Linux exit_group syscall as
 * Darling's final sys_exit step, without native_exit.
 */
extern void _exit(int);
__attribute__((noreturn)) void macoblox_immediate_exit(int status) {
    __asm__ volatile("syscall" : : "a"(231L), "D"((long)status) : "rcx", "r11", "memory");
    __builtin_unreachable();
}
__attribute__((used,section("__DATA,__interpose")))
static const void *exit_interpose[] = {(const void *)macoblox_immediate_exit, (const void *)_exit};

/* MACOBLOX_TRACE_EXIT=1: report who calls exit() before the process ends. */
extern char *getenv(const char *);
extern int write(int, const void *, unsigned long);
extern int backtrace(void **, int);
extern void backtrace_symbols_fd(void *const *, int, int);
extern void exit(int);
static void macoblox_traced_exit(int status) {
    const char *enabled = getenv("MACOBLOX_TRACE_EXIT");
    if (enabled && enabled[0]) {
        static const char message[] = "\n[MacOBlox] exit() called, backtrace:\n";
        void *frames[48];
        write(2, message, sizeof(message) - 1);
        backtrace_symbols_fd(frames, backtrace(frames, 48), 2);
    }
    exit(status);
}
__attribute__((used,section("__DATA,__interpose")))
static const void *exit_trace_interpose[] = {(const void *)macoblox_traced_exit, (const void *)exit};
