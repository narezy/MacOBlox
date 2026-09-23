/* Video memory size for Roblox. Roblox's macOS client reads IOFBMemorySize
 * from the display's IOKit registry entry to size its graphics budget.
 * Darling has no such entry, so Roblox assumed 64 MB of video memory, which
 * turned off MSAA (antialiasing) and other quality features whatever the
 * graphics level. Answer it with the host GPU's real VRAM, passed by the
 * launcher as MACOBLOX_VRAM_BYTES (read from sysfs), defaulting to 4 GB. */

typedef const void *CFTypeRef;
typedef const void *CFStringRef;
typedef const void *CFAllocatorRef;
typedef unsigned int io_registry_entry_t;
typedef unsigned int IOOptionBits;

extern char *getenv(const char *);
extern unsigned char CFStringGetCString(CFStringRef, char *, long, unsigned int);
extern CFTypeRef CFNumberCreate(CFAllocatorRef, long, const void *);
extern int snprintf(char *, unsigned long, const char *, ...);
extern long write(int, const void *, unsigned long);
__attribute__((weak_import)) extern unsigned int CGDisplayIOServicePort(unsigned int);
__attribute__((weak_import)) extern const void *IOServiceMatching(const char *);
__attribute__((weak_import)) extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t, CFStringRef,
                                                                               CFAllocatorRef, IOOptionBits);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

static long long vram_bytes(void) {
    const char *text = getenv("MACOBLOX_VRAM_BYTES");
    long long value = 0;
    for (const char *c = text; c && *c >= '0' && *c <= '9'; c++)
        value = value * 10 + (*c - '0');
    return value >= (64LL << 20) ? value : (4LL << 30);
}

static int key_is(CFStringRef key, const char *expected) {
    char text[64];
    if (!key || !CFStringGetCString(key, text, sizeof text, 0x08000100 /* UTF-8 */))
        return 0;
    for (int i = 0;; i++) {
        if (text[i] != expected[i])
            return 0;
        if (!text[i])
            return 1;
    }
}

static int tracing(void) {
    const char *text = getenv("MACOBLOX_TRACE_IOKIT");
    return text && text[0];
}

static void trace(const char *what, const char *detail, unsigned long value) {
    if (!tracing())
        return;
    char line[200];
    int length = snprintf(line, sizeof line, "[MacOBlox IOKit] %s %s -> 0x%lx\n", what, detail ? detail : "", value);
    if (length > 0) write(2, line, (unsigned long)length);
}

static CFTypeRef macoblox_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key,
                                                          CFAllocatorRef allocator, IOOptionBits options) {
    if (tracing()) {
        char text[64] = "?";
        if (key) CFStringGetCString(key, text, sizeof text, 0x08000100);
        trace("IORegistryEntryCreateCFProperty", text, entry);
    }
    if (key_is(key, "IOFBMemorySize")) {
        long long bytes = vram_bytes();
        return CFNumberCreate(allocator, 4 /* kCFNumberSInt64Type */, &bytes);
    }
    return IORegistryEntryCreateCFProperty(entry, key, allocator, options);
}
DYLD_INTERPOSE(macoblox_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)

/* Darling's CGDisplayIOServicePort returns 0, and Roblox then never asks for
 * IOFBMemorySize. Hand out a stand-in entry; the property hook above answers
 * IOFBMemorySize for it, other IOKit calls on it simply fail. */
#define FAKE_DISPLAY_SERVICE 0x4d4f4231u
static unsigned int macoblox_CGDisplayIOServicePort(unsigned int display) {
    unsigned int port = CGDisplayIOServicePort(display);
    if (!port)
        port = FAKE_DISPLAY_SERVICE;
    trace("CGDisplayIOServicePort", 0, port);
    return port;
}
DYLD_INTERPOSE(macoblox_CGDisplayIOServicePort, CGDisplayIOServicePort)

static const void *macoblox_IOServiceMatching(const char *name) {
    const void *result = IOServiceMatching(name);
    trace("IOServiceMatching", name, (unsigned long)result);
    return result;
}
DYLD_INTERPOSE(macoblox_IOServiceMatching, IOServiceMatching)

/* Roblox may read the display's properties as one dictionary, or go to the
 * parent (framebuffer) entry first; cover both for the stand-in entry. */
typedef void *CFMutableDictionaryRef;
extern CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef, long, const void *, const void *);
extern void CFDictionarySetValue(CFMutableDictionaryRef, const void *, const void *);
extern void CFRelease(CFTypeRef);
extern CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, unsigned int);
extern const char kCFTypeDictionaryKeyCallBacks[];
extern const char kCFTypeDictionaryValueCallBacks[];
__attribute__((weak_import)) extern int IORegistryEntryCreateCFProperties(io_registry_entry_t, CFMutableDictionaryRef *,
                                                                         CFAllocatorRef, IOOptionBits);
__attribute__((weak_import)) extern int IORegistryEntryGetParentEntry(io_registry_entry_t, const char *,
                                                                     io_registry_entry_t *);

static int macoblox_IORegistryEntryCreateCFProperties(io_registry_entry_t entry, CFMutableDictionaryRef *properties,
                                                      CFAllocatorRef allocator, IOOptionBits options) {
    trace("IORegistryEntryCreateCFProperties", 0, entry);
    if (entry == FAKE_DISPLAY_SERVICE && properties) {
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
            allocator, 0, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks);
        long long bytes = vram_bytes();
        CFTypeRef number = CFNumberCreate(allocator, 4 /* kCFNumberSInt64Type */, &bytes);
        CFStringRef key = CFStringCreateWithCString(allocator, "IOFBMemorySize", 0x08000100);
        CFDictionarySetValue(dictionary, key, number);
        CFRelease(key);
        CFRelease(number);
        *properties = dictionary;
        return 0;
    }
    return IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
}
DYLD_INTERPOSE(macoblox_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties)

static int macoblox_IORegistryEntryGetParentEntry(io_registry_entry_t entry, const char *plane,
                                                  io_registry_entry_t *parent) {
    trace("IORegistryEntryGetParentEntry", plane, entry);
    if (entry == FAKE_DISPLAY_SERVICE && parent) {
        *parent = FAKE_DISPLAY_SERVICE;
        return 0;
    }
    return IORegistryEntryGetParentEntry(entry, plane, parent);
}
DYLD_INTERPOSE(macoblox_IORegistryEntryGetParentEntry, IORegistryEntryGetParentEntry)

/* Log multisample buffer creation (a handful of calls, at resize) to see
 * whether Roblox enables MSAA and with how many samples. */
extern void glRenderbufferStorageMultisample(unsigned int, int, unsigned int, int, int);
static void macoblox_glRenderbufferStorageMultisample(unsigned int target, int samples, unsigned int format,
                                                      int width, int height) {
    char line[160];
    int length = snprintf(line, sizeof line,
                          "[MacOBlox GL] multisample renderbuffer samples=%d format=0x%x %dx%d\n",
                          samples, format, width, height);
    if (length > 0) write(2, line, (unsigned long)length);
    glRenderbufferStorageMultisample(target, samples, format, width, height);
}
DYLD_INTERPOSE(macoblox_glRenderbufferStorageMultisample, glRenderbufferStorageMultisample)
