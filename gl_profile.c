/* OpenGL Core Profile for Roblox's context.
 *
 * Roblox asks NSOpenGLPixelFormat for NSOpenGLPFAOpenGLProfile = 3.2 Core
 * (as macOS requires for modern OpenGL). Darling's pixel format drops that
 * attribute and CGL creates every context through eglCreateContext without
 * attributes, i.e. a Compatibility Profile context. In that context Roblox
 * reported no multisample-texture support ("Caps: Texture: ... MSAA 0") and
 * never enabled MSAA, whatever the graphics level or fast flags.
 *
 * The pixel format hook records the requested profile per pixel format; the
 * NSOpenGLContext init hook marks the thread; eglCreateContext then adds the
 * Core Profile attributes for that one context. Darling's own contexts (its
 * layer and window compositing use fixed-function GL) stay Compatibility. */

extern char *getenv(const char *);
extern void *eglCreateContext(void *, void *, void *, const int *);
extern int snprintf(char *, unsigned long, const char *, ...);
extern long write(int, const void *, unsigned long);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define NSOpenGLPFAOpenGLProfile 99
#define EGL_NONE 0x3038
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT 0x1

static struct { void *format; unsigned int profile; } formats[32];
static volatile int formats_lock;
static __thread unsigned int wanted_profile;

static int core_enabled(void) {
    const char *text = getenv("MACOBLOX_GL_COMPAT");
    return !(text && text[0] == '1');
}

/* Attribute lists alternate between flags and "attribute, value" pairs;
 * these are the NSOpenGLPixelFormat attributes that take a value. */
static int takes_value(unsigned int attribute) {
    switch (attribute) {
    case 7: case 8: case 11: case 12: case 13: case 14: case 51: case 52: case 55: case 56:
    case 70: case 84: case 99: case 128:
        return 1;
    }
    return 0;
}

void macoblox_note_pixel_format(void *format, const unsigned int *attributes) {
    unsigned int profile = 0;
    for (int index = 0; attributes && index < 64 && attributes[index]; index++) {
        if (attributes[index] == NSOpenGLPFAOpenGLProfile)
            profile = attributes[index + 1];
        if (takes_value(attributes[index]))
            index++;
    }
    while (__sync_lock_test_and_set(&formats_lock, 1)) {}
    int slot = 0;
    for (int i = 0; i < 32; i++) {
        if (formats[i].format == format || !formats[i].format) { slot = i; break; }
        slot = i;
    }
    formats[slot].format = format;
    formats[slot].profile = profile;
    __sync_lock_release(&formats_lock);
}

void macoblox_prepare_context(void *format) {
    unsigned int profile = 0;
    while (__sync_lock_test_and_set(&formats_lock, 1)) {}
    for (int i = 0; i < 32; i++)
        if (format && formats[i].format == format)
            profile = formats[i].profile;
    __sync_lock_release(&formats_lock);
    wanted_profile = core_enabled() ? profile : 0;
}

void macoblox_finish_context(void) {
    wanted_profile = 0;
}

static void *macoblox_eglCreateContext(void *display, void *config, void *share, const int *attributes) {
    unsigned int profile = wanted_profile;
    if (profile >= 0x3200 && !attributes) {
        wanted_profile = 0;
        int major = profile >= 0x4100 ? 4 : 3, minor = profile >= 0x4100 ? 1 : 2;
        int core[] = {EGL_CONTEXT_MAJOR_VERSION, major, EGL_CONTEXT_MINOR_VERSION, minor,
                      EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
        void *context = eglCreateContext(display, config, share, core);
        char line[120];
        int length = snprintf(line, sizeof line, "[MacOBlox GL] Core Profile %d.%d context for Roblox: %s\n",
                              major, minor, context ? "created" : "failed, using Compatibility");
        if (length > 0) write(2, line, (unsigned long)length);
        if (context)
            return context;
    }
    return eglCreateContext(display, config, share, attributes);
}
DYLD_INTERPOSE(macoblox_eglCreateContext, eglCreateContext)

/* Roblox turns off multisampled textures (and with them MSAA) when
 * GL_RENDERER contains "AMD", a workaround for Apple's AMD drivers since
 * macOS 10.12. Mesa's radeonsi does not have that bug, so Roblox gets the
 * renderer name without the vendor word. MACOBLOX_GL_COMPAT=1 keeps it. */
extern const unsigned char *glGetString(unsigned int);

static const unsigned char *macoblox_glGetString(unsigned int name) {
    static char renderer[256];
    const unsigned char *value = glGetString(name);
    if (name != 0x1F01 || !value || !core_enabled())
        return value;
    const char *text = (const char *)value;
    int out = 0;
    for (int in = 0; text[in] && out < (int)sizeof renderer - 1; in++) {
        if (text[in] == 'A' && text[in + 1] == 'M' && text[in + 2] == 'D') {
            in += text[in + 3] == ' ' ? 3 : 2;
            continue;
        }
        renderer[out++] = text[in];
    }
    renderer[out] = 0;
    return (const unsigned char *)renderer;
}
DYLD_INTERPOSE(macoblox_glGetString, glGetString)
