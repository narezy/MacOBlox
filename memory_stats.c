/* Memory statistics for Roblox.
 *
 * Darling's host_statistics()/host_statistics64() succeed but report every
 * page count as zero. Roblox reads free and inactive pages from them, so it
 * sees 0 MB available, raises "Low memory warning" during every place join
 * and unloads its Lua app (the menu) to free memory; leaving the game then
 * rebuilds the menu from scratch, about 15 s of waiting.
 *
 * When Darling reports nothing, the counts come from the host's
 * /proc/meminfo: MemFree is free, the rest of MemAvailable (page cache that
 * can be dropped) is inactive, as macOS counts it. */
typedef unsigned int natural_t;
typedef int kern_return_t;
typedef unsigned int host_t;
typedef long ssize_t;
typedef unsigned long size_t;

extern kern_return_t host_statistics(host_t, int, int *, natural_t *);
extern kern_return_t host_statistics64(host_t, int, int *, natural_t *);
extern int open(const char *, int, ...);
extern ssize_t read(int, void *, size_t);
extern int close(int);
extern unsigned long long mach_absolute_time(void);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define HOST_VM_INFO 2
#define HOST_VM_INFO64 4
#define PAGE_KB 4

struct pages { natural_t free, active, inactive, wire; };

static unsigned long long meminfo_value(const char *text, const char *key) {
    for (const char *line = text; *line; ) {
        const char *k = key, *c = line;
        while (*k && *c == *k) { k++; c++; }
        if (!*k && *c == ':') {
            unsigned long long value = 0;
            while (*c && (*c < '0' || *c > '9') && *c != '\n') c++;
            while (*c >= '0' && *c <= '9') value = value * 10 + (unsigned long long)(*c++ - '0');
            return value;  /* kB */
        }
        while (*line && *line != '\n') line++;
        if (*line) line++;
    }
    return 0;
}

static int host_pages(struct pages *out) {
    static struct pages cached;
    static unsigned long long cached_at;
    unsigned long long now = mach_absolute_time();
    if (cached_at && now - cached_at < 500000000ULL) {
        *out = cached;
        return 1;
    }
    char text[4096];
    int fd = open("/Volumes/SystemRoot/proc/meminfo", 0 /* O_RDONLY */);
    if (fd < 0)
        return 0;
    ssize_t length = read(fd, text, sizeof text - 1);
    close(fd);
    if (length <= 0)
        return 0;
    text[length] = 0;
    unsigned long long total = meminfo_value(text, "MemTotal");
    unsigned long long free = meminfo_value(text, "MemFree");
    unsigned long long available = meminfo_value(text, "MemAvailable");
    unsigned long long active = meminfo_value(text, "Active");
    if (!total || available > total)
        return 0;
    if (free > available)
        free = available;
    unsigned long long inactive = available - free;
    unsigned long long used = total - available;
    if (active > used)
        active = used;
    cached.free = (natural_t)(free / PAGE_KB);
    cached.inactive = (natural_t)(inactive / PAGE_KB);
    cached.active = (natural_t)(active / PAGE_KB);
    cached.wire = (natural_t)((used - active) / PAGE_KB);
    cached_at = now;
    *out = cached;
    return 1;
}

/* vm_statistics and vm_statistics64 both start with free, active, inactive
 * and wire counts; the 32-bit one has speculative at word 13, the 64-bit one
 * external/internal page counts at words 34/35. */
static void fill(int flavor, int *info, natural_t count) {
    natural_t *words = (natural_t *)info;
    if (count < 4 || words[0] || words[1] || words[2] || words[3])
        return;
    struct pages pages;
    if (!host_pages(&pages))
        return;
    words[0] = pages.free;
    words[1] = pages.active;
    words[2] = pages.inactive;
    words[3] = pages.wire;
    if (flavor == HOST_VM_INFO64 && count >= 36) {
        words[34] = pages.inactive;  /* external (file-backed) */
        words[35] = pages.active;    /* internal (anonymous) */
    }
}

static kern_return_t macoblox_host_statistics64(host_t host, int flavor, int *info, natural_t *count) {
    kern_return_t result = host_statistics64(host, flavor, info, count);
    if (result == 0 && flavor == HOST_VM_INFO64 && count)
        fill(flavor, info, *count);
    return result;
}
DYLD_INTERPOSE(macoblox_host_statistics64, host_statistics64)

static kern_return_t macoblox_host_statistics(host_t host, int flavor, int *info, natural_t *count) {
    kern_return_t result = host_statistics(host, flavor, info, count);
    if (result == 0 && flavor == HOST_VM_INFO && count)
        fill(flavor, info, *count);
    return result;
}
DYLD_INTERPOSE(macoblox_host_statistics, host_statistics)
