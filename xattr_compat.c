/* Darling compatibility for Crashpad xattrs, without discarding their data.
 * Linux requires the user. namespace. Darling's path-based setxattr also
 * fails for valid virtual paths, so resolve through open() and fd operations.
 * Keep other attributes and nonzero position/options on the native path.
 */
extern int dprintf(int, const char *, ...);
extern char *getenv(const char *);
extern int open(const char *, int, ...);
extern int close(int);
extern int *__error(void);
extern void *dlsym(void *, const char *);
extern unsigned long strlen(const char *);
extern int strncmp(const char *, const char *, unsigned long);
extern void *memcpy(void *, const void *, unsigned long);
extern long getxattr(const char *, const char *, void *, unsigned long, unsigned int, int);
extern int setxattr(const char *, const char *, const void *, unsigned long, unsigned int, int);
extern long fgetxattr(int, const char *, void *, unsigned long, unsigned int, int);
extern int fsetxattr(int, const char *, const void *, unsigned long, unsigned int, int);
#define RTLD_NEXT ((void *)-1)
#define INTERPOSE(replacement, original) \
 __attribute__((used,section("__DATA,__interpose"))) \
 static const void *interpose_##original[] = {(const void *)&replacement, (const void *)&original};

static int translated_name(const char *name, char out[256]) {
    if (!name || (strncmp(name, "org.chromium.crashpad.", 21) &&
                  strncmp(name, "com.googlecode.crashpad.", 23))) return 0;
    unsigned long n = strlen(name);
    if (n + 6 > 256) return 0;
    memcpy(out, "user.", 5);
    memcpy(out + 5, name, n + 1);
    return 1;
}
long macoblox_getxattr(const char *path, const char *name, void *value,
                      unsigned long size, unsigned int position, int options) {
    char linux_name[256];
    if (!position && !options && translated_name(name, linux_name)) {
        int fd = open(path, 0);
        if (fd < 0) {
            int saved = *__error();
            if (getenv("MACOBLOX_TRACE_XATTR") && *getenv("MACOBLOX_TRACE_XATTR"))
                dprintf(2, "[xattr] open failed: %s errno=%d\n", path, saved);
            *__error() = saved;
            return -1;
        }
        long result = fgetxattr(fd, linux_name, value, size, 0, 0);
        int err = *__error();
        close(fd);
        if (getenv("MACOBLOX_TRACE_XATTR") && *getenv("MACOBLOX_TRACE_XATTR")) dprintf(2, "[xattr] %s %s result=%ld errno=%d\n", path, name, (long)result, err);
        /* Linux ENODATA becomes Darwin ENODATA; Cocoa expects ENOATTR. */
        *__error() = (result < 0 && err == 96) ? 93 : err;
        return result;
    }
    long (*real_fn)(const char*, const char*, void*, unsigned long, unsigned int, int) =
        dlsym(RTLD_NEXT, "getxattr");
    if (!real_fn) { *__error() = 78; return -1; }
    return real_fn(path, name, value, size, position, options);
}
INTERPOSE(macoblox_getxattr, getxattr);

int macoblox_setxattr(const char *path, const char *name, const void *value,
                     unsigned long size, unsigned int position, int options) {
    char linux_name[256];
    if (!position && !options && translated_name(name, linux_name)) {
        int fd = open(path, 0);
        if (fd < 0) {
            int saved = *__error();
            if (getenv("MACOBLOX_TRACE_XATTR") && *getenv("MACOBLOX_TRACE_XATTR"))
                dprintf(2, "[xattr] open failed: %s errno=%d\n", path, saved);
            *__error() = saved;
            return -1;
        }
        int result = fsetxattr(fd, linux_name, value, size, 0, 0);
        int err = *__error();
        close(fd);
        if (getenv("MACOBLOX_TRACE_XATTR") && *getenv("MACOBLOX_TRACE_XATTR")) dprintf(2, "[xattr] %s %s result=%ld errno=%d\n", path, name, (long)result, err);
        *__error() = err;
        return result;
    }
    int (*real_fn)(const char*, const char*, const void*, unsigned long, unsigned int, int) =
        dlsym(RTLD_NEXT, "setxattr");
    if (!real_fn) { *__error() = 78; return -1; }
    return real_fn(path, name, value, size, position, options);
}
INTERPOSE(macoblox_setxattr, setxattr);
