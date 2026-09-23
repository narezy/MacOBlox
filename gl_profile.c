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
        /* macOS answers a 3.2 Core request with 4.1 Core, and Roblox's Mac
         * shaders expect that. Mesa gives 4.6 for either request, NVIDIA
         * exactly the version asked for (3.2 meant GLSL 1.50). */
        static const int versions[][2] = {{4, 1}, {3, 2}};
        for (int i = 0; i < 2; i++) {
            int core[] = {EGL_CONTEXT_MAJOR_VERSION, versions[i][0], EGL_CONTEXT_MINOR_VERSION, versions[i][1],
                          EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
            void *context = eglCreateContext(display, config, share, core);
            if (context) {
                char line[120];
                int length = snprintf(line, sizeof line, "[MacOBlox GL] Core Profile %d.%d context for Roblox: created\n",
                                      versions[i][0], versions[i][1]);
                if (length > 0) write(2, line, (unsigned long)length);
                return context;
            }
        }
        write(2, "[MacOBlox GL] Core Profile context failed, using Compatibility\n", 63);
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

/* EGL config for Darling's windows.
 *
 * Darling's CGL picks its EGL config with only "red, green, blue >= 1" and
 * uses the first match for every window surface. Mesa's first config fits
 * any X window, NVIDIA's does not: eglCreateWindowSurface failed, the game
 * window had no surface and stayed black (RTX 3050, driver 615). The chosen
 * config is replaced by one whose native visual is the X screen's default
 * visual, which Darling's windows use; if a window still has another
 * visual, its surface is created with a config for that visual. */
extern unsigned int eglChooseConfig(void *, const int *, void **, int, int *);
extern unsigned int eglGetConfigAttrib(void *, void *, int, int *);
extern void *eglCreateWindowSurface(void *, void *, unsigned long, const int *);
extern int eglGetError(void);
extern int macoblox_raw_x_visuals(unsigned int, unsigned int *, unsigned int *);

#define EGL_BLUE_SIZE 0x3022
#define EGL_GREEN_SIZE 0x3023
#define EGL_RED_SIZE 0x3024
#define EGL_NATIVE_VISUAL_ID 0x302E
#define EGL_SURFACE_TYPE 0x3033
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_WINDOW_BIT 0x0004
#define EGL_OPENGL_BIT 0x0008

static int darling_default_attributes(const int *list) {
    static const int darling[] = {EGL_RED_SIZE, 1, EGL_GREEN_SIZE, 1, EGL_BLUE_SIZE, 1, EGL_NONE};
    for (int i = 0; list && i < 7; i++)
        if (list[i] != darling[i])
            return 0;
    return list != 0;
}

static int config_visual(void *display, void *config) {
    int visual = 0;
    eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &visual);
    return visual;
}

/* A window-capable desktop OpenGL config for this X visual, or 0. */
static void *config_for_visual(void *display, unsigned int visual) {
    static const int wanted[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                                 EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
    void *configs[256];
    int count = 0;
    if (!eglChooseConfig(display, wanted, configs, 256, &count))
        return 0;
    for (int i = 0; i < count; i++)
        if ((unsigned int)config_visual(display, configs[i]) == visual)
            return configs[i];
    return 0;
}

static void log_line(const char *text) {
    int length = 0;
    while (text[length]) length++;
    write(2, text, (unsigned long)length);
}

static unsigned int macoblox_eglChooseConfig(void *display, const int *attributes, void **configs,
                                             int size, int *count) {
    unsigned int ok = eglChooseConfig(display, attributes, configs, size, count);
    if (!ok || !configs || size < 1 || !count || *count < 1 || !darling_default_attributes(attributes))
        return ok;
    unsigned int root_visual = 0;
    if (!macoblox_raw_x_visuals(0, &root_visual, 0) || !root_visual)
        return ok;
    int chosen = config_visual(display, configs[0]);
    if ((unsigned int)chosen == root_visual)
        return ok;
    void *better = config_for_visual(display, root_visual);
    char line[160];
    snprintf(line, sizeof line, "[MacOBlox GL] EGL config visual 0x%x, screen visual 0x%x: %s\n",
             chosen, root_visual, better ? "using a config for the screen visual" : "no config for it");
    log_line(line);
    if (better)
        configs[0] = better;
    return ok;
}
DYLD_INTERPOSE(macoblox_eglChooseConfig, eglChooseConfig)

static void *macoblox_eglCreateWindowSurface(void *display, void *config, unsigned long window,
                                             const int *attributes) {
    void *surface = eglCreateWindowSurface(display, config, window, attributes);
    if (surface)
        return surface;
    int error = eglGetError();
    unsigned int root_visual = 0, window_visual = 0;
    macoblox_raw_x_visuals((unsigned int)window, &root_visual, &window_visual);
    void *matching = window_visual ? config_for_visual(display, window_visual) : 0;
    if (matching && matching != config)
        surface = eglCreateWindowSurface(display, matching, window, attributes);
    char line[200];
    snprintf(line, sizeof line,
             "[MacOBlox GL] eglCreateWindowSurface failed (EGL error 0x%x): window visual 0x%x, "
             "config visual 0x%x, screen visual 0x%x; retry %s\n",
             error, window_visual, config_visual(display, config), root_visual,
             surface ? "with the window's visual worked" : "failed");
    log_line(line);
    return surface;
}
DYLD_INTERPOSE(macoblox_eglCreateWindowSurface, eglCreateWindowSurface)
