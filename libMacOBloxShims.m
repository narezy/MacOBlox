typedef struct objc_class *Class;
typedef struct objc_object { Class isa; } *id;
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef void (*IMP)(void);

extern unsigned long long mach_absolute_time(void);
extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *str);
extern Method class_getInstanceMethod(Class cls, SEL name);
extern Method class_getClassMethod(Class cls, SEL name);
extern IMP method_getImplementation(Method m);
extern IMP method_setImplementation(Method m, IMP imp);
extern Class object_getClass(id obj);
extern const char* object_getClassName(id obj);
extern id objc_msgSend(id self, SEL op, ...);

extern char *getenv(const char *);
extern int write(int fd, const void *buf, unsigned long count);
extern int backtrace(void** array, int size);
extern void backtrace_symbols_fd(void* const* array, int size, int fd);
extern void* dlsym(void* handle, const char* symbol);
extern long _dyld_get_image_vmaddr_slide(unsigned int image_index);

#define RTLD_NEXT ((void*)-1)
#define RTLD_DEFAULT ((void*)-2)

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static void write_str(const char* s);
static void print_hex(unsigned long long val);
static void print_num(long long val);

// Darling can create an IONotificationPort but currently returns an error when
// Roblox registers HID matching notifications.  Roblox then destroys the port
// and attempts a second registration with the cleared pointer, which crashes
// inside IOKit.  Report a valid empty registration: controller hot-plugging is
// unavailable, while AppKit keyboard and mouse input remain unaffected.
typedef void (*MacOBloxIOServiceMatchingCallback)(void*, unsigned int);
extern int IOServiceAddMatchingNotification(
    void*, const char*, void*, MacOBloxIOServiceMatchingCallback, void*, unsigned int*);
static int macoblox_IOServiceAddMatchingNotification(
    void* notification_port,
    const char* notification_type,
    void* matching,
    MacOBloxIOServiceMatchingCallback callback,
    void* context,
    unsigned int* iterator) {
    (void)notification_port;
    (void)notification_type;
    (void)matching;
    (void)callback;
    (void)context;
    if (iterator)
        *iterator = 0;
    write_str("[MacOBlox] IOKit HID notification registered with empty iterator\n");
    return 0;
}
DYLD_INTERPOSE(macoblox_IOServiceAddMatchingNotification,
               IOServiceAddMatchingNotification);

// Keep the source for each OpenGL shader long enough to capture the first
// source rejected by Mesa. Roblox's normal log contains the compiler message
// and line number, but not the GLSL text that caused it.
extern void glShaderSource(unsigned int, int, const char* const*, const int*);
extern void glCompileShader(unsigned int);
extern unsigned int glCreateShader(unsigned int);
extern void glAttachShader(unsigned int, unsigned int);
extern void* malloc(unsigned long);
extern void free(void*);
typedef struct MacOBloxFILE MacOBloxFILE;
extern MacOBloxFILE* fopen(const char*, const char*);
extern unsigned long fwrite(const void*, unsigned long, unsigned long, MacOBloxFILE*);
extern int fclose(MacOBloxFILE*);

#define MACOBLOX_SHADER_SLOTS 8192
static char* macoblox_shader_sources[MACOBLOX_SHADER_SLOTS];
static unsigned long macoblox_shader_source_lengths[MACOBLOX_SHADER_SLOTS];
static unsigned int macoblox_shader_types[MACOBLOX_SHADER_SLOTS];
static unsigned int macoblox_program_shaders[MACOBLOX_SHADER_SLOTS][4];
static volatile int macoblox_dumped_failed_shader;
static volatile int macoblox_dumped_final_program;

static unsigned int macoblox_glCreateShader(unsigned int type) {
    static unsigned int (*real_function)(unsigned int);
    if (!real_function)
        real_function = (unsigned int (*)(unsigned int))
            dlsym(RTLD_NEXT, "glCreateShader");
    unsigned int shader = real_function ? real_function(type) : 0;
    if (shader < MACOBLOX_SHADER_SLOTS)
        macoblox_shader_types[shader] = type;
    return shader;
}
DYLD_INTERPOSE(macoblox_glCreateShader, glCreateShader);

static void macoblox_glAttachShader(unsigned int program, unsigned int shader) {
    static void (*real_function)(unsigned int, unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int))
            dlsym(RTLD_NEXT, "glAttachShader");
    if (program < MACOBLOX_SHADER_SLOTS) {
        for (int index = 0; index < 4; index++) {
            if (!macoblox_program_shaders[program][index] ||
                macoblox_program_shaders[program][index] == shader) {
                macoblox_program_shaders[program][index] = shader;
                break;
            }
        }
    }
    if (real_function)
        real_function(program, shader);
}
DYLD_INTERPOSE(macoblox_glAttachShader, glAttachShader);

static unsigned long macoblox_cstr_length(const char* text) {
    unsigned long length = 0;
    if (text)
        while (text[length]) length++;
    return length;
}

static char* macoblox_fix_mesa_shader_indices(char* source,
                                              unsigned long* source_length) {
    static const char needle[] = "((uint(POSITION.w) >> 8u) & 255u)";
    static const char prefix[] = "int(";
    const unsigned long needle_length = sizeof(needle) - 1;
    unsigned long matches = 0;
    for (unsigned long position = 0;
         position + needle_length <= *source_length; position++) {
        unsigned long index = 0;
        while (index < needle_length &&
               source[position + index] == needle[index])
            index++;
        if (index == needle_length) {
            matches++;
            position += needle_length - 1;
        }
    }
    if (!matches)
        return source;

    unsigned long fixed_length = *source_length + matches * 5;
    char* fixed = (char*)malloc(fixed_length + 1);
    if (!fixed)
        return source;

    unsigned long input = 0;
    unsigned long output = 0;
    while (input < *source_length) {
        unsigned long index = 0;
        while (input + index < *source_length && index < needle_length &&
               source[input + index] == needle[index])
            index++;
        if (index == needle_length) {
            for (unsigned long prefix_index = 0;
                 prefix_index < sizeof(prefix) - 1; prefix_index++)
                fixed[output++] = prefix[prefix_index];
            for (unsigned long needle_index = 0;
                 needle_index < needle_length; needle_index++)
                fixed[output++] = needle[needle_index];
            fixed[output++] = ')';
            input += needle_length;
        } else {
            fixed[output++] = source[input++];
        }
    }
    fixed[output] = 0;
    free(source);
    *source_length = output;
    return fixed;
}

static void macoblox_apply_ui_color_test(char* source,
                                         unsigned long source_length) {
    const char* enabled = getenv("MACOBLOX_GL_TEST_UI_COLOR");
    if (!enabled || !enabled[0])
        return;
    static const char needle[] =
        "_entryPointOutput = VARYING1 * _676;";
    static const char replacement[] =
        "_entryPointOutput = vec4(1,0,1,1)  ;";
    const unsigned long length = sizeof(needle) - 1;
    for (unsigned long position = 0;
         position + length <= source_length; position++) {
        unsigned long index = 0;
        while (index < length && source[position + index] == needle[index])
            index++;
        if (index == length) {
            for (index = 0; index < length; index++)
                source[position + index] = replacement[index];
            write_str("[MacOBlox GL] Forced UI fragment shader color\n");
            return;
        }
    }
}

static int macoblox_source_contains(const char* source,
                                    unsigned long source_length,
                                    const char* needle) {
    unsigned long needle_length = macoblox_cstr_length(needle);
    for (unsigned long position = 0;
         position + needle_length <= source_length; position++) {
        unsigned long index = 0;
        while (index < needle_length &&
               source[position + index] == needle[index])
            index++;
        if (index == needle_length)
            return 1;
    }
    return 0;
}

static void macoblox_glShaderSource(unsigned int shader, int count,
                                    const char* const* strings,
                                    const int* lengths) {
    void (*real_function)(unsigned int, int, const char* const*, const int*) =
        (void (*)(unsigned int, int, const char* const*, const int*))
            dlsym(RTLD_NEXT, "glShaderSource");

    const char* fixed_string = 0;
    int fixed_length = 0;
    if (shader < MACOBLOX_SHADER_SLOTS && count > 0 && strings) {
        unsigned long total = 0;
        for (int index = 0; index < count; index++) {
            unsigned long part = (lengths && lengths[index] >= 0)
                ? (unsigned long)lengths[index]
                : macoblox_cstr_length(strings[index]);
            if (part > 1024UL * 1024UL - total) {
                total = 0;
                break;
            }
            total += part;
        }
        if (total) {
            char* copy = (char*)malloc(total + 1);
            if (copy) {
                unsigned long position = 0;
                for (int index = 0; index < count; index++) {
                    unsigned long part = (lengths && lengths[index] >= 0)
                        ? (unsigned long)lengths[index]
                        : macoblox_cstr_length(strings[index]);
                    for (unsigned long offset = 0; offset < part; offset++)
                        copy[position++] = strings[index][offset];
                }
                copy[position] = 0;
                copy = macoblox_fix_mesa_shader_indices(copy, &total);
                macoblox_apply_ui_color_test(copy, total);
                const char* ui_test = getenv("MACOBLOX_GL_TEST_UI_COLOR");
                if (ui_test && ui_test[0] &&
                    macoblox_shader_types[shader] == 0x8B31U &&
                    macoblox_source_contains(copy, total,
                                             "out vec2 VARYING2;")) {
                    static const char forced_vertex[] =
                        "#version 150\n"
                        "in vec4 POSITION; in vec2 TEXCOORD0; in vec4 COLOR0;\n"
                        "out vec2 VARYING0; out vec4 VARYING1; out vec2 VARYING2;\n"
                        "void main(){ int v=gl_VertexID%3; vec2 p=(v==0)?vec2(-1,-1):(v==1)?vec2(3,-1):vec2(-1,3); gl_Position=vec4(p,0,1); VARYING0=vec2(0); VARYING1=vec4(1); VARYING2=vec2(0); }\n";
                    unsigned long forced_length = sizeof(forced_vertex) - 1;
                    char* forced = (char*)malloc(forced_length + 1);
                    if (forced) {
                        for (unsigned long index = 0; index <= forced_length;
                             index++)
                            forced[index] = forced_vertex[index];
                        free(copy);
                        copy = forced;
                        total = forced_length;
                        write_str("[MacOBlox GL] Forced UI vertex coverage\n");
                    }
                }
                if (macoblox_shader_sources[shader])
                    free(macoblox_shader_sources[shader]);
                macoblox_shader_sources[shader] = copy;
                macoblox_shader_source_lengths[shader] = total;
                fixed_string = copy;
                fixed_length = (int)total;
            }
        }
    }
    if (real_function) {
        if (fixed_string)
            real_function(shader, 1, &fixed_string, &fixed_length);
        else
            real_function(shader, count, strings, lengths);
    }
}
DYLD_INTERPOSE(macoblox_glShaderSource, glShaderSource);

static void macoblox_glCompileShader(unsigned int shader) {
    void (*real_compile)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glCompileShader");
    void (*real_get_shader_iv)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetShaderiv");
    if (real_compile)
        real_compile(shader);

    int succeeded = 1;
    if (real_get_shader_iv)
        real_get_shader_iv(shader, 0x8B81U, &succeeded); // GL_COMPILE_STATUS
    if (!succeeded && shader < MACOBLOX_SHADER_SLOTS &&
        macoblox_shader_sources[shader] &&
        __sync_bool_compare_and_swap(&macoblox_dumped_failed_shader, 0, 1)) {
        MacOBloxFILE* output = fopen(
            "/private/tmp/macoblox-first-failed-shader.glsl", "w");
        if (output) {
            fwrite(macoblox_shader_sources[shader], 1,
                   macoblox_shader_source_lengths[shader], output);
            fclose(output);
            write_str("[MacOBlox GL] Captured first failed shader source\n");
        }
    }
}
DYLD_INTERPOSE(macoblox_glCompileShader, glCompileShader);

// Trace every CGL/EGL binding change with its thread. Roblox renders on a
// worker thread; EGL allows a surface to be current in only one thread, so a
// failed eglMakeCurrent there leaves the renderer without a window surface.
// Enabled with MACOBLOX_TRACE_CGL=1; the output is bounded per function.
extern void* pthread_self(void);
extern unsigned int pthread_mach_thread_np(void*);
extern int CGLCreateContext(void*, void*, void**);
extern int CGLSetCurrentContext(void*);
extern int CGLContextMakeCurrentAndAttachToWindow(void*, void*);
extern int CGLFlushDrawable(void*);
extern unsigned int eglMakeCurrent(void*, void*, void*, void*);

static int macoblox_trace_cgl_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACOBLOX_TRACE_CGL");
        enabled = value && value[0] ? 1 : 0;
    }
    return enabled;
}

static int macoblox_trace_cgl_should_log(volatile long* counter) {
    long count = __sync_add_and_fetch(counter, 1);
    return count <= 40 || count % 1000 == 0;
}

static void macoblox_trace_cgl_prefix(const char* name, volatile long* counter) {
    write_str("[MacOBlox CGL] ");
    write_str(name);
    write_str(" #");
    print_num(*counter);
    write_str(" thread=");
    print_num(pthread_mach_thread_np(pthread_self()));
}

static void* macoblox_cgl_egl_context(void* cgl) {
    // struct _CGLContextObj: retain_count, pthread_mutex_t (64 bytes on
    // Darwin x86_64), egl_context, egl_surface.
    return cgl ? ((void**)cgl)[9] : 0;
}

static void* macoblox_cgl_egl_surface(void* cgl) {
    return cgl ? ((void**)cgl)[10] : 0;
}

static volatile long macoblox_cgl_create_count;
static int macoblox_CGLCreateContext(void* format, void* share, void** result) {
    if (macoblox_trace_cgl_enabled() && format) {
        // struct _CGLPixelFormatObj { GLuint retain_count; CGLPixelFormatAttribute* attributes; }
        int* attributes = ((int**)format)[1];
        write_str("[MacOBlox CGL] pixel format:");
        for (int index = 0; attributes && index < 64 && attributes[index]; index++) {
            write_str(" ");
            print_num(attributes[index]);
        }
        write_str("\n");
    }
    int error = CGLCreateContext(format, share, result);
    if (macoblox_trace_cgl_enabled() &&
        macoblox_trace_cgl_should_log(&macoblox_cgl_create_count)) {
        macoblox_trace_cgl_prefix("CGLCreateContext", &macoblox_cgl_create_count);
        write_str(" share=");
        print_hex((unsigned long long)share);
        write_str(" share-egl=");
        print_hex((unsigned long long)macoblox_cgl_egl_context(share));
        write_str(" result=");
        print_hex((unsigned long long)(result ? *result : 0));
        write_str(" egl=");
        print_hex((unsigned long long)macoblox_cgl_egl_context(result ? *result : 0));
        write_str(" error=");
        print_num(error);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macoblox_CGLCreateContext, CGLCreateContext);

static volatile long macoblox_cgl_set_current_count;
static int macoblox_CGLSetCurrentContext(void* context) {
    int error = CGLSetCurrentContext(context);
    if (macoblox_trace_cgl_enabled() &&
        macoblox_trace_cgl_should_log(&macoblox_cgl_set_current_count)) {
        macoblox_trace_cgl_prefix("CGLSetCurrentContext",
                                  &macoblox_cgl_set_current_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macoblox_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)macoblox_cgl_egl_surface(context));
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macoblox_CGLSetCurrentContext, CGLSetCurrentContext);

static volatile long macoblox_cgl_attach_count;
static int macoblox_CGLContextMakeCurrentAndAttachToWindow(void* context,
                                                           void* window) {
    int error = CGLContextMakeCurrentAndAttachToWindow(context, window);
    if (macoblox_trace_cgl_enabled() &&
        macoblox_trace_cgl_should_log(&macoblox_cgl_attach_count)) {
        macoblox_trace_cgl_prefix("CGLContextMakeCurrentAndAttachToWindow",
                                  &macoblox_cgl_attach_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macoblox_cgl_egl_context(context));
        write_str(" window=");
        print_hex((unsigned long long)window);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(macoblox_CGLContextMakeCurrentAndAttachToWindow,
               CGLContextMakeCurrentAndAttachToWindow);

// Frame presentation (gl_profile.c): vsync off unless MACOBLOX_VSYNC=1,
// and an FPS line every 5 s with MACOBLOX_FPS_LOG=1.
extern void macoblox_frame_presenting(void* cgl_context);
static volatile long macoblox_cgl_flush_drawable_count;
static int macoblox_CGLFlushDrawable(void* context) {
    if (macoblox_trace_cgl_enabled() &&
        macoblox_trace_cgl_should_log(&macoblox_cgl_flush_drawable_count)) {
        macoblox_trace_cgl_prefix("CGLFlushDrawable",
                                  &macoblox_cgl_flush_drawable_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)macoblox_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)macoblox_cgl_egl_surface(context));
        write_str("\n");
    }
    macoblox_frame_presenting(context);
    return CGLFlushDrawable(context);
}
DYLD_INTERPOSE(macoblox_CGLFlushDrawable, CGLFlushDrawable);

static volatile long macoblox_egl_make_current_count;
static unsigned int macoblox_eglMakeCurrent(void* display, void* draw,
                                            void* read, void* context) {
    unsigned int result = eglMakeCurrent(display, draw, read, context);
    if (macoblox_trace_cgl_enabled() &&
        macoblox_trace_cgl_should_log(&macoblox_egl_make_current_count)) {
        unsigned int (*egl_error)(void) =
            (unsigned int (*)(void))dlsym(RTLD_DEFAULT, "eglGetError");
        macoblox_trace_cgl_prefix("eglMakeCurrent",
                                  &macoblox_egl_make_current_count);
        write_str(" display=");
        print_hex((unsigned long long)display);
        write_str(" draw=");
        print_hex((unsigned long long)draw);
        write_str(" context=");
        print_hex((unsigned long long)context);
        write_str(" result=");
        print_num(result);
        write_str(" error=");
        print_hex(result || !egl_error ? 0x3000 : egl_error());
        write_str("\n");
    }
    return result;
}
DYLD_INTERPOSE(macoblox_eglMakeCurrent, eglMakeCurrent);

// Count the commands that can actually produce or resolve pixels. A steady
// stream of NSOpenGLContext flushes only proves that Darling swaps the X11
// surface; it does not prove that Roblox submitted a frame to that surface.
// Keep these wrappers passive so the diagnostic cannot change GL state.
extern void glDrawArrays(unsigned int, int, int);
extern void glDrawElements(unsigned int, int, unsigned int, const void*);
extern void glDrawRangeElements(unsigned int, unsigned int, unsigned int, int,
                                unsigned int, const void*);
extern void glDrawElementsBaseVertex(unsigned int, int, unsigned int,
                                     const void*, int);
extern void glDrawArraysInstanced(unsigned int, int, int, int);
extern void glDrawElementsInstanced(unsigned int, int, unsigned int,
                                    const void*, int);
extern void glDrawElementsInstancedBaseVertex(unsigned int, int, unsigned int,
                                              const void*, int, int);
extern void glBlitFramebuffer(int, int, int, int, int, int, int, int,
                              unsigned int, unsigned int);
extern void glBindFramebuffer(unsigned int, unsigned int);
extern void glClear(unsigned int);

static volatile long macoblox_gl_draw_count;
static volatile long macoblox_gl_blit_count;
static volatile long macoblox_gl_clear_count;
static volatile long macoblox_gl_default_framebuffer_bind_count;
static void* macoblox_gl_window_surface;
static void* macoblox_gl_window_egl_context;
static void* macoblox_gl_render_egl_context;
static volatile long macoblox_gl_surface_repair_attempts;
static volatile long macoblox_gl_traced_window_draws;
static volatile long macoblox_gl_skipped_foreign_draws;
static volatile int macoblox_dumped_uniform_blocks;
static volatile int macoblox_dumped_actual_program;

static void macoblox_dump_actual_program_sources(unsigned int program) {
    if (program < 700 ||
        !__sync_bool_compare_and_swap(&macoblox_dumped_actual_program, 0, 1))
        return;
    void (*attached_shaders)(unsigned int, int, int*, unsigned int*) =
        (void (*)(unsigned int, int, int*, unsigned int*))
            dlsym(RTLD_NEXT, "glGetAttachedShaders");
    void (*shader_iv)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetShaderiv");
    void (*shader_source)(unsigned int, int, int*, char*) =
        (void (*)(unsigned int, int, int*, char*))
            dlsym(RTLD_NEXT, "glGetShaderSource");
    if (!attached_shaders || !shader_iv || !shader_source)
        return;
    unsigned int shaders[4] = {0, 0, 0, 0};
    int shader_count = 0;
    attached_shaders(program, 4, &shader_count, shaders);
    write_str("[MacOBlox GL] actual program=");
    print_num(program);
    write_str(" attached=");
    print_num(shader_count);
    write_str(" shaders=");
    for (int index = 0; index < shader_count && index < 4; index++) {
        if (index)
            write_str(",");
        print_num(shaders[index]);
        int source_length = 0;
        shader_iv(shaders[index], 0x8B88U, &source_length);
        if (source_length <= 1 || source_length > 1024 * 1024)
            continue;
        char* source = (char*)malloc((unsigned long)source_length);
        if (!source)
            continue;
        int written = 0;
        shader_source(shaders[index], source_length, &written, source);
        char path[] =
            "/Volumes/SystemRoot/tmp/macoblox-actual-program-shader-0.glsl";
        path[sizeof(path) - sizeof("0.glsl")] = (char)('0' + index);
        MacOBloxFILE* output = fopen(path, "w");
        if (output) {
            fwrite(source, 1, (unsigned long)(written > 0 ? written : 0),
                   output);
            fclose(output);
        }
        free(source);
    }
    write_str("\n");
}

// The EGL surface repair and foreign-draw filtering below were workarounds
// for Roblox drawing into the wrong context, which restoring the context
// after CALayerContext renders fixed properly. They stay available for
// debugging with MACOBLOX_GL_HACKS=1.
static int macoblox_gl_hacks_disabled(void) {
    static int disabled = -1;
    if (disabled < 0) {
        const char* value = getenv("MACOBLOX_GL_HACKS");
        disabled = value && value[0] ? 0 : 1;
    }
    return disabled;
}

static void macoblox_ensure_gl_window_surface(void) {
    if (macoblox_gl_hacks_disabled())
        return;
    void* surface = macoblox_gl_window_surface;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!surface || !current_surface || current_surface(0x3059)) // EGL_DRAW
        return;

    void* (*current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    int (*make_current)(void*, void*, void*, void*) =
        (int (*)(void*, void*, void*, void*))
            dlsym(RTLD_NEXT, "eglMakeCurrent");
    unsigned int (*egl_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "eglGetError");
    if (!current_display || !current_context || !make_current)
        return;

    // Roblox switches from AppKit's initial CGL context to its own shared
    // render context. The latter owns the draws but Darling leaves it
    // surfaceless, so attach whichever live context is selecting framebuffer
    // zero rather than limiting this repair to AppKit's original context.
    void* context = current_context();
    if (!context)
        return;

    int attached = make_current(current_display(), surface, surface,
                                context);
    long attempt = __sync_add_and_fetch(&macoblox_gl_surface_repair_attempts, 1);
    if (attempt <= 5) {
        write_str("[MacOBlox GL] draw-time EGL surface repair #");
        print_num(attempt);
        write_str(" result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
}

static int macoblox_should_skip_foreign_window_command(int learn_renderer) {
    if (macoblox_gl_hacks_disabled())
        return 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    if (!current_surface || !current_context ||
        current_surface(0x3059) != macoblox_gl_window_surface)
        return 0;

    void* context = current_context();
    if (learn_renderer) {
        void (*get_integer)(unsigned int, int*) =
            (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
        int program = 0;
        if (get_integer)
            get_integer(0x8B8DU, &program); // GL_CURRENT_PROGRAM
        if (program > 0) {
            macoblox_gl_render_egl_context = context;
            const char* ui_test = getenv("MACOBLOX_GL_TEST_UI_COLOR");
            if (ui_test && ui_test[0] && program >= 700) {
                void (*disable)(unsigned int) =
                    (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
                void (*color_mask)(unsigned char, unsigned char,
                                   unsigned char, unsigned char) =
                    (void (*)(unsigned char, unsigned char, unsigned char,
                              unsigned char))dlsym(RTLD_NEXT, "glColorMask");
                if (disable) {
                    disable(0x0BE2U); // GL_BLEND
                    disable(0x0B71U); // GL_DEPTH_TEST
                    disable(0x0B44U); // GL_CULL_FACE
                    disable(0x0C11U); // GL_SCISSOR_TEST
                    disable(0x0B90U); // GL_STENCIL_TEST
                    disable(0x8C89U); // GL_RASTERIZER_DISCARD
                    for (unsigned int clip = 0; clip < 8; clip++)
                        disable(0x3000U + clip); // GL_CLIP_DISTANCE0..
                }
                if (color_mask)
                    color_mask(1, 1, 1, 1);
            }
        }
    }
    return macoblox_gl_render_egl_context &&
           context != macoblox_gl_render_egl_context;
}

static void macoblox_trace_window_draw(unsigned int mode, int count) {
    unsigned int (*get_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
    unsigned int draw_error = get_error ? get_error() : 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!current_surface || !current_surface(0x3059))
        return;

    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    if (!get_integer)
        return;
    int framebuffer = -1;
    get_integer(0x8CA6U, &framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    if (framebuffer)
        return;

    long sequence = __sync_add_and_fetch(&macoblox_gl_traced_window_draws, 1);
    if (sequence > 16)
        return;

    int program = 0;
    int vertex_array = 0;
    int active_texture = 0;
    int texture = 0;
    int viewport[4] = {0, 0, 0, 0};
    int scissor[4] = {0, 0, 0, 0};
    get_integer(0x8B8DU, &program);       // GL_CURRENT_PROGRAM
    get_integer(0x85B5U, &vertex_array);  // GL_VERTEX_ARRAY_BINDING
    get_integer(0x84E0U, &active_texture);// GL_ACTIVE_TEXTURE
    get_integer(0x0BA2U, viewport);       // GL_VIEWPORT
    get_integer(0x0C10U, scissor);        // GL_SCISSOR_BOX

    int (*uniform_location)(unsigned int, const char*) =
        (int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformLocation");
    void (*get_uniform)(unsigned int, int, int*) =
        (void (*)(unsigned int, int, int*))
            dlsym(RTLD_NEXT, "glGetUniformiv");
    void (*active_texture_fn)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glActiveTexture");
    int sampler = 0;
    if (uniform_location && get_uniform && program > 0) {
        int location = uniform_location((unsigned int)program,
                                        "DiffuseMapTexture");
        if (location >= 0)
            get_uniform((unsigned int)program, location, &sampler);
    }
    if (active_texture_fn) {
        active_texture_fn(0x84C0U + (unsigned int)sampler); // GL_TEXTURE0
        get_integer(0x8069U, &texture); // GL_TEXTURE_BINDING_2D
        active_texture_fn((unsigned int)active_texture);
    }

    unsigned int (*uniform_block_index)(unsigned int, const char*) =
        (unsigned int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformBlockIndex");
    void (*uniform_block_iv)(unsigned int, unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetActiveUniformBlockiv");
    void (*get_integer_indexed)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetIntegeri_v");
    int cb0_buffer = -1;
    int cb1_buffer = -1;
    macoblox_dump_actual_program_sources((unsigned int)program);
    if (uniform_block_index && uniform_block_iv && get_integer_indexed &&
        program > 0) {
        const char* names[2] = {"block_CB0", "block_CB1"};
        int* buffers[2] = {&cb0_buffer, &cb1_buffer};
        for (int index = 0; index < 2; index++) {
            unsigned int block = uniform_block_index((unsigned int)program,
                                                      names[index]);
            if (block != 0xFFFFFFFFU) {
                int binding = 0;
                uniform_block_iv((unsigned int)program, block, 0x8A3FU,
                                 &binding); // GL_UNIFORM_BLOCK_BINDING
                get_integer_indexed(0x8A28U, (unsigned int)binding,
                                    buffers[index]);
            }
        }
    }

    if (program >= 700 && uniform_block_iv && get_integer_indexed &&
        __sync_bool_compare_and_swap(&macoblox_dumped_uniform_blocks, 0, 1)) {
        void (*get_program)(unsigned int, unsigned int, int*) =
            (void (*)(unsigned int, unsigned int, int*))
                dlsym(RTLD_NEXT, "glGetProgramiv");
        void (*block_name)(unsigned int, unsigned int, int, int*, char*) =
            (void (*)(unsigned int, unsigned int, int, int*, char*))
                dlsym(RTLD_NEXT, "glGetActiveUniformBlockName");
        int blocks = 0;
        if (get_program)
            get_program((unsigned int)program, 0x8A36U, &blocks);
        write_str("[MacOBlox GL] uniform-blocks program=");
        print_num(program);
        write_str(" count=");
        print_num(blocks);
        write_str("\n");
        for (int block = 0; block < blocks && block < 8; block++) {
            int binding = -1;
            int size = -1;
            int buffer = -1;
            int written = 0;
            char name[128];
            name[0] = 0;
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A3FU, &binding);
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A40U, &size); // GL_UNIFORM_BLOCK_DATA_SIZE
            if (block_name)
                block_name((unsigned int)program, (unsigned int)block,
                           127, &written, name);
            name[127] = 0;
            if (binding >= 0)
                get_integer_indexed(0x8A28U, (unsigned int)binding, &buffer);
            write_str("[MacOBlox GL] uniform-block #");
            print_num(block);
            write_str(" name=");
            write_str(name);
            write_str(" binding=");
            print_num(binding);
            write_str(" buffer=");
            print_num(buffer);
            write_str(" size=");
            print_num(size);
            write_str("\n");
        }
    }

    unsigned char (*is_enabled)(unsigned int) =
        (unsigned char (*)(unsigned int))dlsym(RTLD_NEXT, "glIsEnabled");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    write_str("[MacOBlox GL] window-draw #");
    print_num(sequence);
    write_str(" mode=");
    print_hex(mode);
    write_str(" count=");
    print_num(count);
    write_str(" program=");
    print_num(program);
    write_str(" error=");
    print_hex(draw_error);
    write_str(" egl-context=");
    print_hex((unsigned long long)(current_context ? current_context() : 0));
    write_str(" vao=");
    print_num(vertex_array);
    write_str(" sampler=");
    print_num(sampler);
    write_str(" texture=");
    print_num(texture);
    write_str(" cb0=");
    print_num(cb0_buffer);
    write_str(" cb1=");
    print_num(cb1_buffer);
    write_str(" blend=");
    print_num(is_enabled ? is_enabled(0x0BE2U) : -1);
    write_str(" scissor-enabled=");
    print_num(is_enabled ? is_enabled(0x0C11U) : -1);
    write_str(" viewport=");
    print_num(viewport[0]); write_str(","); print_num(viewport[1]);
    write_str(","); print_num(viewport[2]); write_str(",");
    print_num(viewport[3]);
    write_str(" scissor=");
    print_num(scissor[0]); write_str(","); print_num(scissor[1]);
    write_str(","); print_num(scissor[2]); write_str(",");
    print_num(scissor[3]);
    write_str("\n");
}

// GL call tracing is opt-in (MACOBLOX_TRACE_GL=1). Without it the wrappers
// below only forward: tracing costs dlsym, glGetError and several
// glGetIntegerv per draw, which in game (thousands of draws per frame) was a
// large part of the frame time.
static int macoblox_gl_trace_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACOBLOX_TRACE_GL");
        enabled = value && value[0] ? 1 : 0;
    }
    return enabled;
}

static void macoblox_glBindFramebuffer(unsigned int target,
                                       unsigned int framebuffer) {
    static void (*real_function)(unsigned int, unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int))
            dlsym(RTLD_NEXT, "glBindFramebuffer");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(target, framebuffer);
        return;
    }
    // Binding framebuffer 0 selects the window drawable. Restore its EGL
    // surface before GL validates the following clear and draw commands.
    if (!framebuffer) {
        macoblox_ensure_gl_window_surface();
        __sync_add_and_fetch(&macoblox_gl_default_framebuffer_bind_count, 1);
    }
    if (real_function)
        real_function(target, framebuffer);
}
DYLD_INTERPOSE(macoblox_glBindFramebuffer, glBindFramebuffer);

static void macoblox_glClear(unsigned int mask) {
    static void (*real_function)(unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mask);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_clear_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(0))
        real_function(mask);
}
DYLD_INTERPOSE(macoblox_glClear, glClear);

static void macoblox_glDrawArrays(unsigned int mode, int first, int count) {
    static void (*real_function)(unsigned int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int))
            dlsym(RTLD_NEXT, "glDrawArrays");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, first, count);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawArrays, glDrawArrays);

static void macoblox_glDrawElements(unsigned int mode, int count,
                                    unsigned int type, const void* indices) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawElements");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawElements, glDrawElements);

static void macoblox_glDrawRangeElements(unsigned int mode, unsigned int start,
                                         unsigned int end, int count,
                                         unsigned int type,
                                         const void* indices) {
    static void (*real_function)(unsigned int, unsigned int, unsigned int, int,
                                 unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int, unsigned int, int,
                                  unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawRangeElements");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, start, end, count, type, indices);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, start, end, count, type, indices);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawRangeElements, glDrawRangeElements);

static void macoblox_glDrawElementsBaseVertex(unsigned int mode, int count,
                                              unsigned int type,
                                              const void* indices,
                                              int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsBaseVertex");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, base_vertex);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, base_vertex);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawElementsBaseVertex, glDrawElementsBaseVertex);

static void macoblox_glDrawArraysInstanced(unsigned int mode, int first,
                                           int count, int instances) {
    static void (*real_function)(unsigned int, int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int, int))
            dlsym(RTLD_NEXT, "glDrawArraysInstanced");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count, instances);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, first, count, instances);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawArraysInstanced, glDrawArraysInstanced);

static void macoblox_glDrawElementsInstanced(unsigned int mode, int count,
                                             unsigned int type,
                                             const void* indices,
                                             int instances) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsInstanced");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawElementsInstanced, glDrawElementsInstanced);

static void macoblox_glDrawElementsInstancedBaseVertex(
    unsigned int mode, int count, unsigned int type, const void* indices,
    int instances, int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int, int);
    if (!real_function)
        real_function =
            (void (*)(unsigned int, int, unsigned int, const void*, int, int))
                dlsym(RTLD_NEXT, "glDrawElementsInstancedBaseVertex");
    if (!macoblox_gl_trace_enabled() && macoblox_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances, base_vertex);
        return;
    }
    macoblox_ensure_gl_window_surface();
    __sync_add_and_fetch(&macoblox_gl_draw_count, 1);
    if (real_function &&
        !macoblox_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances, base_vertex);
    else
        __sync_add_and_fetch(&macoblox_gl_skipped_foreign_draws, 1);
    macoblox_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(macoblox_glDrawElementsInstancedBaseVertex,
               glDrawElementsInstancedBaseVertex);

static void macoblox_glBlitFramebuffer(int sx0, int sy0, int sx1, int sy1,
                                       int dx0, int dy0, int dx1, int dy1,
                                       unsigned int mask,
                                       unsigned int filter) {
    static void (*real_function)(int, int, int, int, int, int, int, int,
                                 unsigned int, unsigned int);
    if (!real_function)
        real_function =
            (void (*)(int, int, int, int, int, int, int, int, unsigned int,
                      unsigned int))dlsym(RTLD_NEXT, "glBlitFramebuffer");
    __sync_add_and_fetch(&macoblox_gl_blit_count, 1);
    if (real_function)
        real_function(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}
DYLD_INTERPOSE(macoblox_glBlitFramebuffer, glBlitFramebuffer);

static void write_str(const char* s) {
    if (!s) return;
    int len = 0;
    while (s[len]) len++;
    write(2, s, len);
}

static void print_hex(unsigned long long val) {
    char buf[20];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 15; i >= 0; i--) {
        int nibble = (val >> (i * 4)) & 0xF;
        buf[2 + (15 - i)] = (nibble < 10) ? ('0' + nibble) : ('a' + nibble - 10);
    }
    buf[18] = '\0';
    write(2, buf, 18);
}

static void print_num(long long val) {
    char buf[32];
    int pos = 30;
    buf[31] = '\0';
    int neg = 0;
    if (val < 0) { neg = 1; val = -val; }
    if (val == 0) {
        buf[pos--] = '0';
    } else {
        while (val > 0) {
            buf[pos--] = '0' + (val % 10);
            val /= 10;
        }
    }
    if (neg) buf[pos--] = '-';
    write(2, &buf[pos + 1], 30 - pos);
}

static void print_backtrace(void) {
    void* frames[64];
    int n = backtrace(frames, 64);
    for (int i = 0; i < n; i++) {
        write_str("  [frame ");
        print_num(i);
        write_str("]: ");
        print_hex((unsigned long long)frames[i]);
        write_str("\n");
    }
    backtrace_symbols_fd(frames, n, 2);
}

// Trace the exact resolver requests made by Roblox. A plain getaddrinfo probe
// succeeds in Darling while Roblox reports DnsResolve, so the hints passed by
// its networking layer are relevant to the failure.
struct macoblox_addrinfo_head {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
};
extern int getaddrinfo(const char*, const char*, const void*, void**);
extern int usleep(unsigned int);
static volatile int macoblox_dns_lock;
extern int macoblox_dns_resolve(const char* node, const char* service,
                                const void* hints, void** result);
static int macoblox_getaddrinfo(const char* node, const char* service,
                                const void* hints, void** result) {
    // DNS chosen in the launcher, for Roblox only (dns_override.c).
    int own = macoblox_dns_resolve(node, service, hints, result);
    if (own >= 0)
        return own;
    int (*real_getaddrinfo)(const char*, const char*, const void*, void**) =
        (int (*)(const char*, const char*, const void*, void**))dlsym(RTLD_NEXT, "getaddrinfo");
    while (__sync_lock_test_and_set(&macoblox_dns_lock, 1))
        usleep(1000);

    int status = -1;
    int attempts = 0;
    if (real_getaddrinfo) {
        for (attempts = 1; attempts <= 4; attempts++) {
            if (result)
                *result = 0;
            status = real_getaddrinfo(node, service, hints, result);
            if (status == 0)
                break;
            usleep(50000);
        }
    }
    __sync_lock_release(&macoblox_dns_lock);

    const char* trace = getenv("MACOBLOX_TRACE_DNS");
    if (status != 0 || (trace && *trace == '1')) {
        write_str("[MacOBlox DNS] node=");
        write_str(node ? node : "(null)");
        write_str(" service=");
        write_str(service ? service : "(null)");
        if (hints) {
            const struct macoblox_addrinfo_head* head =
                (const struct macoblox_addrinfo_head*)hints;
            write_str(" flags="); print_num(head->ai_flags);
            write_str(" family="); print_num(head->ai_family);
            write_str(" socktype="); print_num(head->ai_socktype);
            write_str(" protocol="); print_num(head->ai_protocol);
        } else {
            write_str(" hints=(null)");
        }
        write_str(" attempts="); print_num(attempts);
        write_str(" result="); print_num(status);
        write_str("\n");
    }
    return status;
}
DYLD_INTERPOSE(macoblox_getaddrinfo, getaddrinfo)

// Interposed functions
extern void exit(int);
extern void _exit(int);
extern void _Exit(int);
extern void abort(void);
extern void __cxa_throw(void*, void*, void(*)(void*));
extern void _ZSt9terminatev(void);
extern void objc_exception_throw(id);
extern int NSApplicationMain(int argc, const char *argv[]);

static int in_interpose_exit = 0;
void my_exit(int status) {
    if (!in_interpose_exit) {
        in_interpose_exit = 1;
        write_str("\n[MacOBlox Hook] exit(");
        print_num(status);
        write_str(") called!\n[MacOBlox Hook] Backtrace:\n");
        print_backtrace();
    }
    void (*real_exit)(int) = (void (*)(int))dlsym(RTLD_NEXT, "exit");
    if (real_exit) real_exit(status);
    _exit(status);
}
// Disabled: tracing/suppressing exit changes crash and post-fork semantics.

void my__exit(int status) {
    if (!in_interpose_exit) {
        in_interpose_exit = 1;
        write_str("\n[MacOBlox Hook] _exit(");
        print_num(status);
        write_str(") called!\n[MacOBlox Hook] Backtrace:\n");
        print_backtrace();
    }
    void (*real__exit)(int) = (void (*)(int))dlsym(RTLD_NEXT, "_exit");
    if (real__exit) real__exit(status);
    while (1);
}
// Disabled: tracing/suppressing _exit changes crash and post-fork semantics.

void my__Exit(int status) {
    if (!in_interpose_exit) {
        in_interpose_exit = 1;
        write_str("\n[MacOBlox Hook] _Exit(");
        print_num(status);
        write_str(") called!\n[MacOBlox Hook] Backtrace:\n");
        print_backtrace();
    }
    void (*real__Exit)(int) = (void (*)(int))dlsym(RTLD_NEXT, "_Exit");
    if (real__Exit) real__Exit(status);
    while (1);
}
// Disabled: tracing/suppressing _Exit changes crash and post-fork semantics.

void my_abort(void) {
    write_str("\n[MacOBlox Hook] abort() called!\n[MacOBlox Hook] Backtrace:\n");
    print_backtrace();
    void (*real_abort)(void) = (void (*)(void))dlsym(RTLD_NEXT, "abort");
    if (real_abort) real_abort();
    while (1);
}
// Disabled: tracing/suppressing abort changes crash and post-fork semantics.

// Interpose pthread_kill, kill, raise
extern int pthread_kill(void* thread, int sig);
int my_pthread_kill(void* thread, int sig) {
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] pthread_kill called with sig: ");
    print_num(sig);
    write_str(" for thread: ");
    print_hex((unsigned long long)thread);
    write_str("\nBacktrace of caller:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");
    if (sig == 11 || sig == 10 || sig == 6) {
        write_str("[MacOBlox Hook] Suppressing fatal signal in pthread_kill!\n");
        return 0;
    }
    int (*real_pk)(void*, int) = (int (*)(void*, int))dlsym(RTLD_NEXT, "pthread_kill");
    return real_pk ? real_pk(thread, sig) : 0;
}
// Disabled: tracing/suppressing pthread_kill changes crash and post-fork semantics.

extern int kill(int pid, int sig);
int my_kill(int pid, int sig) {
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] kill() called with sig: ");
    print_num(sig);
    write_str(" for pid: ");
    print_num(pid);
    write_str("\nBacktrace of caller:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");
    if (sig == 11 || sig == 10 || sig == 6) {
        write_str("[MacOBlox Hook] Suppressing fatal signal in kill()!\n");
        return 0;
    }
    int (*real_k)(int, int) = (int (*)(int, int))dlsym(RTLD_NEXT, "kill");
    return real_k ? real_k(pid, sig) : 0;
}
// Disabled: tracing/suppressing kill changes crash and post-fork semantics.

extern int raise(int sig);
int my_raise(int sig) {
    write_str("\n[MacOBlox Hook] raise() called with sig: ");
    print_num(sig);
    write_str("\nBacktrace of caller:\n");
    print_backtrace();
    if (sig == 11 || sig == 10 || sig == 6) {
        write_str("[MacOBlox Hook] Suppressing fatal signal in raise()!\n");
        return 0;
    }
    int (*real_raise)(int) = (int (*)(int))dlsym(RTLD_NEXT, "raise");
    return real_raise ? real_raise(sig) : 0;
}
// Disabled: tracing/suppressing raise changes crash and post-fork semantics.

static int trace_exceptions_enabled(void) {
    const char* value = getenv("MACOBLOX_TRACE_EXCEPTIONS");
    return value && *value == '1';
}

void my_cxa_throw(void* thrown_exception, void* tinfo, void (*dest)(void*)) {
    if (!trace_exceptions_enabled()) {
        void (*real_throw)(void*, void*, void(*)(void*)) =
            (void (*)(void*, void*, void(*)(void*)))dlsym(RTLD_NEXT, "__cxa_throw");
        if (real_throw) real_throw(thrown_exception, tinfo, dest);
        while (1);
    }
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] __cxa_throw called!\n");
    if (tinfo) {
        const char* mangled = ((const char**)tinfo)[1];
        if (mangled) {
            write_str("[MacOBlox Hook] Mangled type: ");
            write_str(mangled);
            write_str("\n");
            typedef char* (*demangle_fn)(const char*, char*, unsigned long*, int*);
            demangle_fn demangle = (demangle_fn)dlsym(RTLD_DEFAULT, "__cxa_demangle");
            if (demangle) {
                int status = 0;
                char* demangled = demangle(mangled, 0, 0, &status);
                if (demangled) {
                    write_str("[MacOBlox Hook] Demangled type: ");
                    write_str(demangled);
                    write_str("\n");
                }
            }
        }
    }
    // C++ can throw scalars and arbitrary classes, not just std::exception.
    // Never interpret an unknown exception object as a vtable or call through it.
    write_str("[MacOBlox Hook] Backtrace:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");

    void (*real_throw)(void*, void*, void(*)(void*)) = (void (*)(void*, void*, void(*)(void*)))dlsym(RTLD_NEXT, "__cxa_throw");
    if (real_throw) {
        real_throw(thrown_exception, tinfo, dest);
    }
    while (1);
}
DYLD_INTERPOSE(my_cxa_throw, __cxa_throw);

void my_objc_exception_throw(id exception) {
    if (!trace_exceptions_enabled()) {
        void (*real_throw)(id) = (void (*)(id))dlsym(RTLD_NEXT, "objc_exception_throw");
        if (real_throw) real_throw(exception);
        while (1);
    }
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] objc_exception_throw called!\n");
    if (exception) {
        write_str("[MacOBlox Hook] Exception class: ");
        write_str(object_getClassName(exception));
        write_str("\n");
    }
    write_str("[MacOBlox Hook] Backtrace:\n");
    void (*real_throw)(id) = (void (*)(id))dlsym(RTLD_NEXT, "objc_exception_throw");
    if (real_throw) {
        real_throw(exception);
    }
    while (1);
}
DYLD_INTERPOSE(my_objc_exception_throw, objc_exception_throw);

// Interpose _Unwind_Resume, __throw_system_error, __cxa_rethrow
extern void _Unwind_Resume(void*);
void my_Unwind_Resume(void* exc) {
    if (!trace_exceptions_enabled()) {
        void (*real_fn)(void*) = (void (*)(void*))dlsym(RTLD_NEXT, "_Unwind_Resume");
        if (real_fn) real_fn(exc);
        while (1);
    }
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] _Unwind_Resume called! exc: ");
    print_hex((unsigned long long)exc);
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");
    void (*real_fn)(void*) = (void (*)(void*))dlsym(RTLD_NEXT, "_Unwind_Resume");
    if (real_fn) real_fn(exc);
    while (1);
}
DYLD_INTERPOSE(my_Unwind_Resume, _Unwind_Resume);

extern void _ZNSt3__120__throw_system_errorEiPKc(int, const char*);
void my_throw_system_error(int err, const char* msg) {
    if (!trace_exceptions_enabled()) {
        void (*real_fn)(int, const char*) =
            (void (*)(int, const char*))dlsym(RTLD_NEXT, "_ZNSt3__120__throw_system_errorEiPKc");
        if (real_fn) real_fn(err, msg);
        while (1);
    }
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] std::__throw_system_error called! err: ");
    print_num(err);
    write_str(", msg: ");
    write_str(msg ? msg : "(null)");
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");
    void (*real_fn)(int, const char*) = (void (*)(int, const char*))dlsym(RTLD_NEXT, "_ZNSt3__120__throw_system_errorEiPKc");
    if (real_fn) real_fn(err, msg);
    while (1);
}
DYLD_INTERPOSE(my_throw_system_error, _ZNSt3__120__throw_system_errorEiPKc);

extern void __cxa_rethrow(void);
void my_cxa_rethrow(void) {
    if (!trace_exceptions_enabled()) {
        void (*real_fn)(void) = (void (*)(void))dlsym(RTLD_NEXT, "__cxa_rethrow");
        if (real_fn) real_fn();
        while (1);
    }
    write_str("\n[MacOBlox Hook] ========================================\n");
    write_str("[MacOBlox Hook] __cxa_rethrow called!\nBacktrace:\n");
    print_backtrace();
    write_str("[MacOBlox Hook] ========================================\n\n");
    void (*real_fn)(void) = (void (*)(void))dlsym(RTLD_NEXT, "__cxa_rethrow");
    if (real_fn) real_fn();
    while (1);
}
DYLD_INTERPOSE(my_cxa_rethrow, __cxa_rethrow);

int my_NSApplicationMain(int argc, const char *argv[]) {
    write_str("\n[MacOBlox Hook] NSApplicationMain entered!\n");
    int (*real_main)(int, const char*[]) = (int (*)(int, const char*[]))dlsym(RTLD_NEXT, "NSApplicationMain");
    int res = real_main ? real_main(argc, argv) : 0;
    write_str("\n[MacOBlox Hook] NSApplicationMain returned: ");
    print_num(res);
    write_str("\n[MacOBlox Hook] Backtrace:\n");
    print_backtrace();
    return res;
}
DYLD_INTERPOSE(my_NSApplicationMain, NSApplicationMain);

// Signal crash handler
struct darwin_sigaction {
    void (*sa_sigaction)(int, void*, void*);
    unsigned int sa_mask;
    int sa_flags;
};
extern int sigaction(int, const struct darwin_sigaction*, struct darwin_sigaction*);

typedef struct dl_info {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
extern int dladdr(const void *, Dl_info *);

static void print_addr_info(const char* prefix, void* addr) {
    write_str(prefix);
    print_hex((unsigned long long)addr);
    Dl_info dli;
    if (dladdr(addr, &dli)) {
        if (dli.dli_fname) {
            write_str(" in ");
            write_str(dli.dli_fname);
        }
        if (dli.dli_sname) {
            write_str(" (");
            write_str(dli.dli_sname);
            write_str("+");
            print_num((long long)((char*)addr - (char*)dli.dli_saddr));
            write_str(")");
        }
    }
    write_str("\n");
}

static void crash_handler(int sig, void* info, void* uap) {
    write_str("\n\n[MacOBlox FATAL CRASH] ****************************************\n");
    write_str("[MacOBlox FATAL CRASH] Signal received: ");
    print_num(sig);
    write_str("\n");
    if (info) {
        write_str("[MacOBlox FATAL CRASH] siginfo: ");
        print_hex((unsigned long long)info);
        unsigned long long* si = (unsigned long long*)info;
        write_str("\n  si_signo/code: ");
        print_hex(si[0]);
        write_str("\n  si_addr (fault addr / sender pid): ");
        print_hex(si[2]);
        write_str("\n");
    }
    if (uap) {
        write_str("[MacOBlox FATAL CRASH] ucontext: ");
        print_hex((unsigned long long)uap);
        write_str("\n");
        unsigned long long* p = (unsigned long long*)uap;
        write_str("  uc_mcontext ptr: ");
        print_hex(p[6]);
        write_str("\n");
        unsigned long long* mc = (unsigned long long*)p[6];
        if (mc) {
            write_str("  RAX: "); print_hex(mc[2]); write_str("\n");
            write_str("  RBX: "); print_hex(mc[3]); write_str("\n");
            write_str("  RCX: "); print_hex(mc[4]); write_str("\n");
            write_str("  RDX: "); print_hex(mc[5]); write_str("\n");
            write_str("  RDI: "); print_hex(mc[6]); write_str("\n");
            write_str("  RSI: "); print_hex(mc[7]); write_str("\n");
            write_str("  RBP: "); print_hex(mc[8]); write_str("\n");
            write_str("  RSP: "); print_hex(mc[9]); write_str("\n");
            write_str("  RIP: "); print_hex(mc[18]); write_str("\n");
            write_str("  RFLAGS: "); print_hex(mc[19]); write_str("\n");

            print_addr_info("  Fault RIP info: ", (void*)mc[18]);
            print_addr_info("  RDI info: ", (void*)mc[6]);
            print_addr_info("  RSI info: ", (void*)mc[7]);

            write_str("\n[MacOBlox Stack Walk from RBP]:\n");
            void** fp = (void**)mc[8];
            for (int i = 0; i < 30 && fp; i++) {
                if ((unsigned long long)fp < 0x1000 || ((unsigned long long)fp & 7)) break;
                void* ret_addr = fp[1];
                write_str("  #"); print_num(i); write_str(" ");
                print_addr_info("", ret_addr);
                fp = (void**)fp[0];
            }
        }
    }
    write_str("[MacOBlox FATAL CRASH] ****************************************\n\n");
    _exit(128 + sig);
}

int my_sigaction(int sig, const struct darwin_sigaction *act, struct darwin_sigaction *oact) {
    write_str("[MacOBlox Hook] sigaction called for sig: ");
    print_num(sig);
    write_str(", new handler: ");
    print_hex(act ? (unsigned long long)act->sa_sigaction : 0);
    write_str("\n");
    int (*real_sigaction)(int, const void*, void*) = (int (*)(int, const void*, void*))dlsym(RTLD_NEXT, "sigaction");
    // Opt-in crash diagnosis only: preserve the application's handlers normally.
    const char *diagnose = getenv("MACOBLOX_DIAGNOSTIC_SIGNALS");
    if (diagnose && *diagnose == '1' && sig == 11 && act && real_sigaction) {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        return real_sigaction(sig, &debug_action, oact);
    }
    return real_sigaction ? real_sigaction(sig, act, oact) : 0;
}
DYLD_INTERPOSE(my_sigaction, sigaction);

// Swizzle NSConcreteScanner
static id (*orig_concrete_initWithString)(id self, SEL _cmd, id str) = 0;
static id hooked_concrete_initWithString(id self, SEL _cmd, id str) {
    if (!str) {
        write_str("\n[MacOBlox Hook] -[NSConcreteScanner initWithString:nil] called!\n");
    }
    return orig_concrete_initWithString(self, _cmd, str);
}

// Swizzle NSApplication run
static void (*orig_app_run)(id self, SEL _cmd) = 0;
static void hooked_app_run(id self, SEL _cmd) {
    write_str("\n[MacOBlox Hook] -[NSApplication run] entered!\n");
    orig_app_run(self, _cmd);
    write_str("\n[MacOBlox Hook] -[NSApplication run] returned!\n");
}

static int ascii_strings_equal(const char* left, const char* right) {
    if (!left || !right)
        return 0;
    while (*left && *right && *left == *right) {
        left++;
        right++;
    }
    return *left == 0 && *right == 0;
}

static void (*orig_app_finish_launching)(id self, SEL cmd) = 0;
// Window icon: MACOBLOX_ICON_ARGB names a file of 32-bit little-endian words
// in _NET_WM_ICON layout (width, height, ARGB pixels, repeated per size),
// written by the launcher. It is set on the Roblox X window from a separate
// X connection, so docks and window switchers show the Mac O Blox logo.
extern void* malloc(unsigned long);
extern void free(void*);
static unsigned long macoblox_icon_window;
static void* macoblox_set_window_icon_thread(void* unused) {
    (void)unused;
    const char* path = getenv("MACOBLOX_ICON_ARGB");
    MacOBloxFILE* file = path ? fopen(path, "rb") : 0;
    if (!file)
        return 0;
    extern unsigned long fread(void*, unsigned long, unsigned long, MacOBloxFILE*);
    unsigned int* words = (unsigned int*)malloc(1 << 22);
    unsigned long count = words ? fread(words, 4, (1 << 22) / 4, file) : 0;
    fclose(file);
    if (!count) {
        free(words);
        return 0;
    }
    // Xlib passes format-32 property data as C longs.
    unsigned long* longs = (unsigned long*)malloc(count * sizeof(unsigned long));
    for (unsigned long index = 0; index < count && longs; index++)
        longs[index] = words[index];
    free(words);
    void* (*open_display)(const char*) = (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    unsigned long (*intern)(void*, const char*, int) =
        (unsigned long (*)(void*, const char*, int))dlsym(RTLD_DEFAULT, "XInternAtom");
    int (*change)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int) =
        (int (*)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int))
            dlsym(RTLD_DEFAULT, "XChangeProperty");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    int (*sync)(void*, int) = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    void* display = open_display && longs ? open_display(0) : 0;
    if (display && intern && change) {
        unsigned long atom = intern(display, "_NET_WM_ICON", 0);
        change(display, macoblox_icon_window, atom, 6 /* XA_CARDINAL */, 32,
               0 /* PropModeReplace */, longs, (int)count);
        if (sync)
            sync(display, 0);
        write_str("[MacOBlox] Window icon set\n");
    }
    if (display && close_display)
        close_display(display);
    free(longs);
    return 0;
}

static void macoblox_set_window_icon(id window) {
    if (!getenv("MACOBLOX_ICON_ARGB") || macoblox_icon_window)
        return;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("platformWindow"));
    if (!platform || !((signed char (*)(id, SEL, SEL))objc_msgSend)(
                         platform, sel_registerName("respondsToSelector:"),
                         sel_registerName("windowHandle")))
        return;
    macoblox_icon_window = ((unsigned long (*)(id, SEL))objc_msgSend)(
        platform, sel_registerName("windowHandle"));
    if (!macoblox_icon_window)
        return;
    extern int pthread_create(void**, const void*, void* (*)(void*), void*);
    void* thread;
    pthread_create(&thread, 0, macoblox_set_window_icon_thread, 0);
}

// Darling draws the macOS menu bar (Roblox, Edit, Window...) inside each
// window. With MACOBLOX_HIDE_MENU_BAR=1 its height is 0: cocotron uses
// +[NSMainMenuView menuHeight] for the bar itself and for converting between
// window frame and content rect, so the game fills the whole window, also
// after Roblox rebuilds its menu (which re-showed a strip after sign-in).
static double macoblox_zero_menu_height(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return 0.0;
}

// Secure-coding convenience methods (macOS 10.13) missing in Darling.
// Roblox archives some state with them after sign-in and unarchives it at
// the next start, which crashed. Map them to the older keyed archiver API;
// unreadable data or an object of the wrong class gives nil, not a crash.
static id keyed_archiver_archived_data(id cls, SEL cmd, id root, signed char secure, id* error) {
    (void)cls; (void)cmd; (void)secure;
    if (error)
        *error = 0;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSKeyedArchiver"), sel_registerName("archivedDataWithRootObject:"), root);
}
static id keyed_unarchiver_unarchived_object(id cls, SEL cmd, Class expected, id data, id* error) {
    (void)cls; (void)cmd;
    if (error)
        *error = 0;
    if (!data)
        return 0;
    id object = 0;
    @try {
        object = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSKeyedUnarchiver"), sel_registerName("unarchiveObjectWithData:"), data);
    } @catch (id exception) {
        (void)exception;
        object = 0;
    }
    if (object && expected &&
        !((signed char (*)(id, SEL, Class))objc_msgSend)(object, sel_registerName("isKindOfClass:"), expected))
        object = 0;
    return object;
}

static void macoblox_install_late_hooks(void);
static void hooked_app_finish_launching(id self, SEL cmd) {
    macoblox_install_late_hooks();
    orig_app_finish_launching(self, cmd);

    id windows = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("windows"));
    unsigned long count = windows
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) : 0;
    for (unsigned long index = 0; index < count; index++) {
        id window = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            windows, sel_registerName("objectAtIndex:"), index);
        const char* class_name = window ? object_getClassName(window) : 0;
        if (!ascii_strings_equal(class_name, "RBXWindow"))
            continue;
        macoblox_set_window_icon(window);
        signed char visible = ((signed char (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("isVisible"));
        if (!visible) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                window, sel_registerName("makeKeyAndOrderFront:"), 0);
            write_str("[MacOBlox] Ordered RBXWindow to the front after launch\n");
        }
    }
}

// Swizzle NSApplication terminate:
static void (*orig_app_terminate)(id self, SEL _cmd, id sender) = 0;
static void hooked_app_terminate(id self, SEL _cmd, id sender) {
    write_str("\n[MacOBlox Hook] -[NSApplication terminate:] called!\nBacktrace:\n");
    print_backtrace();
    orig_app_terminate(self, _cmd, sender);
}

// Swizzle NSApplication setDelegate:
static void (*orig_app_setDelegate)(id self, SEL _cmd, id del) = 0;
static void hooked_app_setDelegate(id self, SEL _cmd, id del) {
    write_str("\n[MacOBlox Hook] -[NSApplication setDelegate:] called with: ");
    write_str(del ? object_getClassName(del) : "(nil)");
    write_str("\n");
    orig_app_setDelegate(self, _cmd, del);
}

// Swizzle NSBundle loadNibNamed:owner:
static int (*orig_loadNibNamed)(id self, SEL _cmd, id name, id owner) = 0;
static int hooked_loadNibNamed(id self, SEL _cmd, id name, id owner) {
    write_str("\n[MacOBlox Hook] +[NSBundle loadNibNamed:owner:] entered\n");
    int res = orig_loadNibNamed(self, _cmd, name, owner);
    write_str("[MacOBlox Hook] +[NSBundle loadNibNamed:owner:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSNib instantiateNibWithExternalNameTable:
static int (*orig_instantiateNib)(id self, SEL _cmd, id table) = 0;
static int hooked_instantiateNib(id self, SEL _cmd, id table) {
    write_str("\n[MacOBlox Hook] -[NSNib instantiateNibWithExternalNameTable:] entered\n");
    int res = orig_instantiateNib(self, _cmd, table);
    write_str("[MacOBlox Hook] -[NSNib instantiateNibWithExternalNameTable:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSWindowTemplate initWithCoder:
static int in_wt_init = 0;
static id (*orig_wt_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_wt_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[MacOBlox Hook] -[NSWindowTemplate initWithCoder:] START\n");
    in_wt_init = 1;
    id res = orig_wt_initWithCoder(self, _cmd, coder);
    in_wt_init = 0;
    write_str("[MacOBlox Hook] -[NSWindowTemplate initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSKeyedUnarchiver decodeObjectForKey:
static id (*orig_decodeObjectForKey)(id self, SEL _cmd, id key) = 0;
static id hooked_decodeObjectForKey(id self, SEL _cmd, id key) {
    const char* kstr = key ? (const char*)objc_msgSend(key, sel_registerName("UTF8String")) : 0;
    if (in_wt_init) {
        write_str("  [WT decodeObjectForKey]: ");
        write_str(kstr ? kstr : "(null)");
        write_str("\n");
    }
    id res = orig_decodeObjectForKey(self, _cmd, key);
    if (in_wt_init) {
        write_str("    -> returned: ");
        write_str(res ? object_getClassName(res) : "(nil)");
        write_str("\n");
    }
    return res;
}

// Swizzle NSIBObjectData initWithCoder:
static id (*orig_od_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_od_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[MacOBlox Hook] -[NSIBObjectData initWithCoder:] START\n");
    id res = orig_od_initWithCoder(self, _cmd, coder);
    write_str("[MacOBlox Hook] -[NSIBObjectData initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSIBObjectData establishConnections
static void (*orig_od_establish)(id self, SEL _cmd) = 0;
static void hooked_od_establish(id self, SEL _cmd) {
    write_str("[MacOBlox Hook] -[NSIBObjectData establishConnections] START\n");
    orig_od_establish(self, _cmd);
    write_str("[MacOBlox Hook] -[NSIBObjectData establishConnections] END\n");
}

// Swizzle NSNibConnector establishConnection
static void (*orig_conn_establish)(id self, SEL _cmd) = 0;
static void hooked_conn_establish(id self, SEL _cmd) {
    write_str("[MacOBlox Hook] -[NSNibConnector establishConnection] called on: ");
    write_str(object_getClassName(self));
    write_str("\n");
    orig_conn_establish(self, _cmd);
    write_str("[MacOBlox Hook] -[NSNibConnector establishConnection] finished\n");
}

// Cocoa x86_64 ABI: NSRect is four doubles passed by value; BOOL is signed char.
typedef struct { double x, y; } MacOBloxPoint;
typedef struct { double width, height; } MacOBloxSize;
typedef struct { MacOBloxPoint origin; MacOBloxSize size; } MacOBloxRect;
typedef signed char MacOBloxBool;

// Swizzle NSWindow initWithContentRect:styleMask:backing:defer:
static id (*orig_win_init)(id self, SEL _cmd, MacOBloxRect r, unsigned long sm, unsigned long bs, MacOBloxBool def) = 0;
static id hooked_win_init(id self, SEL _cmd, MacOBloxRect r, unsigned long sm, unsigned long bs, MacOBloxBool def) {
    write_str("\n[MacOBlox Hook] -[NSWindow initWithContentRect:...] START, class: ");
    write_str(object_getClassName(self));
    write_str("\n");
    id res = orig_win_init(self, _cmd, r, sm, bs, def);
    write_str("[MacOBlox Hook] -[NSWindow initWithContentRect:...] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Experimental 1x backing-size fallback for Darling's non-Retina NSView.
// Only add it when AppKit does not implement the method.
extern signed char class_addMethod(Class, SEL, IMP, const char*);
static MacOBloxSize backing_size_1x(id self, SEL cmd, MacOBloxSize size) {
    (void)self; (void)cmd;
    return size;
}

// NSWindow gained rectangle variants of its screen conversion API after the
// AppKit snapshot used by Darling.  Roblox uses convertRectFromScreen: while
// handling mouse movement.  Falling through Objective-C forwarding is unsafe
// for a CGRect return on x86_64, so implement the methods in terms of the older
// point conversion calls which Darling does provide.
static MacOBloxRect window_convert_rect_from_screen(id self, SEL cmd, MacOBloxRect rect) {
    (void)cmd;
    rect.origin = ((MacOBloxPoint (*)(id, SEL, MacOBloxPoint))objc_msgSend)(
        self, sel_registerName("convertScreenToBase:"), rect.origin);
    return rect;
}

static MacOBloxRect window_convert_rect_to_screen(id self, SEL cmd, MacOBloxRect rect) {
    (void)cmd;
    rect.origin = ((MacOBloxPoint (*)(id, SEL, MacOBloxPoint))objc_msgSend)(
        self, sel_registerName("convertBaseToScreen:"), rect.origin);
    return rect;
}

// Darling exposes a deliberately small WebPreferences forwarding stub, but
// omits this legacy singleton constructor.  Roblox asks for the singleton while
// creating its experience coordinator, before any preference setters are sent.
static id macoblox_standard_web_preferences;
static volatile int macoblox_web_preferences_lock;
static id web_preferences_standard_preferences(id cls, SEL cmd) {
    (void)cmd;
    if (macoblox_standard_web_preferences)
        return macoblox_standard_web_preferences;
    while (__sync_lock_test_and_set(&macoblox_web_preferences_lock, 1))
        usleep(1000);
    if (!macoblox_standard_web_preferences) {
        id preferences = ((id (*)(id, SEL))objc_msgSend)(
            cls, sel_registerName("alloc"));
        preferences = preferences
            ? ((id (*)(id, SEL))objc_msgSend)(preferences, sel_registerName("init"))
            : 0;
        macoblox_standard_web_preferences = preferences;
    }
    __sync_lock_release(&macoblox_web_preferences_lock);
    return macoblox_standard_web_preferences;
}

// Darling's AVFoundation class shell does not implement device discovery.
// Roblox/WebRTC probes cameras during Universal App startup even when voice or
// video capture is not in use.  An empty inventory is the correct headless
// result and lets the rest of the client continue initializing.
static id empty_capture_devices(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel_registerName("array"));
}

static id empty_capture_devices_for_media_type(id cls, SEL cmd, id media_type) {
    (void)media_type;
    return empty_capture_devices(cls, cmd);
}

static id no_default_capture_device(id cls, SEL cmd, id media_type) {
    (void)cls; (void)cmd; (void)media_type;
    return 0;
}

// Keep the missing CALayer property as associated state. Darling's renderer
// still only supports the existing 1x path; this does not add Retina rendering.
extern void objc_setAssociatedObject(id, const void*, id, unsigned long);
extern id objc_getAssociatedObject(id, const void*);
static char contents_scale_key;
static void layer_set_contents_scale(id self, SEL cmd, double scale) {
    (void)cmd;
    id number = ((id (*)(id, SEL, double))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithDouble:"), scale);
    objc_setAssociatedObject(self, &contents_scale_key, number, 1);
    if (scale != 1.0)
        write_str("[MacOBlox] Warning: CALayer backing rendering above/below 1x is unimplemented\n");
}
static double layer_contents_scale(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &contents_scale_key);
    return number ? ((double (*)(id, SEL))objc_msgSend)(number, sel_registerName("doubleValue")) : 1.0;
}

// Preserve requested touch filtering; this does not synthesize touch events.
static char allowed_touch_types_key;
static void view_set_allowed_touch_types(id self, SEL cmd, unsigned long types) {
    (void)cmd;
    id number = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedLong:"), types);
    objc_setAssociatedObject(self, &allowed_touch_types_key, number, 1);
}
static unsigned long view_allowed_touch_types(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &allowed_touch_types_key);
    return number ? ((unsigned long (*)(id, SEL))objc_msgSend)(number, sel_registerName("unsignedLongValue")) : 0;
}

// Newer AppKit exposes inertial-scroll phases on NSEvent. Darling does not
// synthesize those events, so the only correct value for its existing mouse
// events is NSEventPhaseNone (zero). This also keeps Roblox's input path out of
// Objective-C forwarding while the pointer is over the render view.
static unsigned long event_phase_none(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Darling predates NSProcessInfo's thermal and low-power APIs. Linux exposes
// neither state through this compatibility layer, so report the documented
// neutral values used by macOS when no throttling is active.
static long process_info_thermal_state_nominal(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

static MacOBloxBool process_info_low_power_mode_disabled(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Trace the handoff between Roblox's OpenGL renderer and Darling's X11
// drawable. Keep this bounded because makeCurrentContext/flushBuffer normally
// run once per frame.
static id (*orig_gl_context_init)(id, SEL, id, id) = 0;
static void (*orig_gl_context_set_view)(id, SEL, id) = 0;
static void (*orig_gl_context_make_current)(id, SEL) = 0;
static void (*orig_gl_context_flush)(id, SEL) = 0;
static volatile long macoblox_gl_make_current_count;
static volatile long macoblox_gl_flush_count;

static void trace_gl_context(const char* action, id self, long count) {
    void** slots = (void**)self;
    write_str("[MacOBlox GL] ");
    write_str(action);
    if (count >= 0) {
        write_str(" #");
        print_num(count);
    }
    write_str(" self=");
    print_hex((unsigned long long)self);
    if (self) {
        write_str(" class=");
        write_str(object_getClassName(self));
        write_str(" view=");
        print_hex((unsigned long long)slots[2]);
        write_str(" cgl-context=");
        print_hex((unsigned long long)slots[3]);
        write_str(" subwindow=");
        print_hex((unsigned long long)slots[4]);
        write_str(" egl-surface=");
        print_hex((unsigned long long)slots[5]);
    }
    write_str("\n");
}

extern void macoblox_prepare_context(void* format);
extern void macoblox_finish_context(void);
extern void macoblox_note_pixel_format(void* format, const unsigned int* attributes);
static id hooked_gl_context_init(id self, SEL cmd, id format, id shared) {
    macoblox_prepare_context(format); // Core Profile if Roblox asked for it (gl_profile.c)
    id result = orig_gl_context_init(self, cmd, format, shared);
    macoblox_finish_context();
    trace_gl_context("init", result, -1);
    return result;
}

static void hooked_gl_context_set_view(id self, SEL cmd, id view) {
    orig_gl_context_set_view(self, cmd, view);
    trace_gl_context("setView", self, -1);
}

static void hooked_gl_context_make_current(id self, SEL cmd) {
    orig_gl_context_make_current(self, cmd);
    long count = __sync_add_and_fetch(&macoblox_gl_make_current_count, 1);
    void** slots = (void**)self;
    if (self && slots[3] && slots[5]) {
        void** cgl_slots = (void**)slots[3];
        macoblox_gl_window_surface = slots[5];
        macoblox_gl_window_egl_context = cgl_slots[9];
    }
    void* (*current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    int (*make_current)(void*, void*, void*, void*) =
        (int (*)(void*, void*, void*, void*))
            dlsym(RTLD_NEXT, "eglMakeCurrent");
    unsigned int (*egl_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "eglGetError");
    if (!macoblox_gl_hacks_disabled() &&
        self && slots[5] && current_display && current_context &&
        current_surface && make_current && !current_surface(0x3059)) {
        void* display = current_display();
        void* context = current_context();
        int attached = make_current(display, slots[5], slots[5], context);
        write_str("[MacOBlox GL] repaired missing EGL window surface result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
    if (count <= 5 || count == 60 || count == 600)
        trace_gl_context("makeCurrentContext", self, count);
}

static void dump_final_program_shaders(int program) {
    if (program <= 0 || program >= MACOBLOX_SHADER_SLOTS ||
        !__sync_bool_compare_and_swap(&macoblox_dumped_final_program, 0, 1))
        return;

    write_str("[MacOBlox GL] final program=");
    print_num(program);
    write_str(" shaders=");
    for (int index = 0; index < 4; index++) {
        unsigned int shader = macoblox_program_shaders[program][index];
        if (index)
            write_str(",");
        print_num(shader);
        write_str(":");
        print_hex(shader < MACOBLOX_SHADER_SLOTS
                      ? macoblox_shader_types[shader]
                      : 0);
        if (!shader || shader >= MACOBLOX_SHADER_SLOTS ||
            !macoblox_shader_sources[shader])
            continue;
        char path[] = "/Volumes/SystemRoot/tmp/macoblox-final-shader-0.glsl";
        path[sizeof(path) - sizeof("0.glsl")] = (char)('0' + index);
        MacOBloxFILE* output = fopen(path, "w");
        if (output) {
            fwrite(macoblox_shader_sources[shader], 1,
                   macoblox_shader_source_lengths[shader], output);
            fclose(output);
        }
    }
    write_str("\n");
}

static void trace_gl_frame_state(long count) {
    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    void (*read_pixels)(int, int, int, int, unsigned int, unsigned int, void*) =
        (void (*)(int, int, int, int, unsigned int, unsigned int, void*))
            dlsym(RTLD_NEXT, "glReadPixels");
    void (*set_read_buffer)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glReadBuffer");
    if (!get_integer)
        return;

    int draw_framebuffer = -1;
    int read_framebuffer = -1;
    int program = -1;
    int draw_buffer = -1;
    int read_buffer = -1;
    int viewport[4] = {-1, -1, -1, -1};
    get_integer(0x8CA6U, &draw_framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    get_integer(0x8CAAU, &read_framebuffer); // GL_READ_FRAMEBUFFER_BINDING
    get_integer(0x8B8DU, &program);          // GL_CURRENT_PROGRAM
    get_integer(0x0C01U, &draw_buffer);      // GL_DRAW_BUFFER
    get_integer(0x0C02U, &read_buffer);      // GL_READ_BUFFER
    get_integer(0x0BA2U, viewport);          // GL_VIEWPORT
    dump_final_program_shaders(program);

    void* (*egl_current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    void* (*egl_current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*egl_current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");

    write_str("[MacOBlox GL] frame-state #");
    print_num(count);
    write_str(" draws=");
    print_num(macoblox_gl_draw_count);
    write_str(" blits=");
    print_num(macoblox_gl_blit_count);
    write_str(" clears=");
    print_num(macoblox_gl_clear_count);
    write_str(" default-binds=");
    print_num(macoblox_gl_default_framebuffer_bind_count);
    write_str(" draw-fbo=");
    print_num(draw_framebuffer);
    write_str(" read-fbo=");
    print_num(read_framebuffer);
    write_str(" program=");
    print_num(program);
    write_str(" draw-buffer=");
    print_hex((unsigned long long)(unsigned int)draw_buffer);
    write_str(" read-buffer=");
    print_hex((unsigned long long)(unsigned int)read_buffer);
    write_str(" egl-context=");
    print_hex((unsigned long long)(egl_current_context
                                      ? egl_current_context()
                                      : 0));
    write_str(" egl-display=");
    print_hex((unsigned long long)(egl_current_display
                                      ? egl_current_display()
                                      : 0));
    write_str(" egl-draw-surface=");
    print_hex((unsigned long long)(egl_current_surface
                                      ? egl_current_surface(0x3059)
                                      : 0)); // EGL_DRAW
    write_str(" viewport=");
    print_num(viewport[0]);
    write_str(",");
    print_num(viewport[1]);
    write_str(",");
    print_num(viewport[2]);
    write_str(",");
    print_num(viewport[3]);
    if (read_pixels && set_read_buffer && viewport[2] > 0 && viewport[3] > 0) {
        static const int fractions[3] = {1, 2, 3};
        // Roblox leaves the default read buffer disabled. Select the same back
        // buffer it draws into only while sampling, then restore its state.
        set_read_buffer(0x0402U); // GL_BACK_LEFT
        write_str(" samples=");
        for (int row = 0; row < 3; row++) {
            for (int column = 0; column < 3; column++) {
                unsigned char pixel[4] = {0, 0, 0, 0};
                int x = viewport[0] + viewport[2] * fractions[column] / 4;
                int y = viewport[1] + viewport[3] * fractions[row] / 4;
                read_pixels(x, y, 1, 1, 0x1908U, 0x1401U, pixel);
                if (row || column)
                    write_str(";");
                print_num(pixel[0]);
                write_str(",");
                print_num(pixel[1]);
                write_str(",");
                print_num(pixel[2]);
                write_str(",");
                print_num(pixel[3]);
            }
        }
        set_read_buffer((unsigned int)read_buffer);
    }
    write_str("\n");
}

static void hooked_gl_context_flush(id self, SEL cmd) {
    long count = __sync_add_and_fetch(&macoblox_gl_flush_count, 1);
    const char* test_clear = getenv("MACOBLOX_GL_TEST_CLEAR");
    if (test_clear && test_clear[0]) {
        void (*disable)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
        void (*color_mask)(unsigned char, unsigned char, unsigned char,
                           unsigned char) =
            (void (*)(unsigned char, unsigned char, unsigned char,
                      unsigned char))dlsym(RTLD_NEXT, "glColorMask");
        void (*clear_color)(float, float, float, float) =
            (void (*)(float, float, float, float))
                dlsym(RTLD_NEXT, "glClearColor");
        void (*clear)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
        unsigned int (*get_error)(void) =
            (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
        unsigned int (*check_framebuffer)(unsigned int) =
            (unsigned int (*)(unsigned int))
                dlsym(RTLD_NEXT, "glCheckFramebufferStatus");
        void (*finish)(void) = (void (*)(void))dlsym(RTLD_NEXT, "glFinish");
        if (disable && color_mask && clear_color && clear) {
            unsigned int before_error = get_error ? get_error() : 0;
            disable(0x0C11U); // GL_SCISSOR_TEST
            color_mask(1, 1, 1, 1);
            clear_color(1.0f, 0.0f, 1.0f, 1.0f);
            clear(0x00004000U); // GL_COLOR_BUFFER_BIT
            if (finish)
                finish();
            if (count <= 5) {
                write_str("[MacOBlox GL] test-clear before-error=");
                print_hex(before_error);
                write_str(" after-error=");
                print_hex(get_error ? get_error() : 0);
                write_str(" framebuffer-status=");
                print_hex(check_framebuffer
                              ? check_framebuffer(0x8CA9U) // GL_DRAW_FRAMEBUFFER
                              : 0);
                write_str("\n");
            }
        }
    }
    if (macoblox_gl_trace_enabled() && (count <= 5 || count == 60 || count == 600)) {
        trace_gl_frame_state(count);
        trace_gl_context("flushBuffer", self, count);
    }
    orig_gl_context_flush(self, cmd);
}

// Darling's CALayerContext renders layers on the main thread and leaves its
// own CGL context current. On macOS the render server does this in another
// process, so Roblox makes its NSOpenGLContext current once and expects it to
// stay current. Without restoring it, every later Roblox GL call goes to the
// surfaceless layer context, where Roblox's shaders and buffers do not exist.
extern void* CGLGetCurrentContext(void);
static void (*orig_layer_context_render_layer)(id, SEL, id) = 0;
static volatile long macoblox_layer_context_restores;
static void hooked_layer_context_render_layer(id self, SEL cmd, id layer) {
    void* previous = CGLGetCurrentContext();
    orig_layer_context_render_layer(self, cmd, layer);
    if (previous && CGLGetCurrentContext() != previous) {
        CGLSetCurrentContext(previous);
        if (__sync_add_and_fetch(&macoblox_layer_context_restores, 1) == 1)
            write_str("[MacOBlox GL] Restored app GL context after CALayerContext render\n");
    }
}

// Mouse lock (in-game camera). On macOS CGAssociateMouseAndMouseCursorPosition
// (false) freezes the cursor and mouse events carry raw deltas. Darling's
// version cannot be used for that:
//  - it passes "connected" to -[NSDisplay grabMouse:] unchanged (inverted);
//  - Roblox repeats the call every frame and each grab recenters the pointer;
//  - in grab mode deltas are measured from the pin point, and events queued
//    before the asynchronous warp-back report growing offsets (5, 10, 15
//    instead of 5, 5, 5), so the camera spun far too fast;
//  - Roblox's per-frame CGWarpMouseCursorPosition fought the pin point.
// So the lock is implemented here: the pointer stays free and Darling's
// ordinary per-event deltas are used; when it drifts more than
// MACOBLOX_LOCK_RADIUS from the window center it is moved back with a
// relative XWarpPointer, and the single motion event caused by that warp is
// dropped. Warp requests during the lock are remembered and applied when the
// lock ends, as a frozen macOS cursor would stay put.
extern int CGAssociateMouseAndMouseCursorPosition(unsigned int connected);
extern int CGWarpMouseCursorPosition(MacOBloxPoint position);
#define MACOBLOX_LOCK_RADIUS 100.0
static volatile int macoblox_pointer_grabbed;
static volatile int macoblox_pending_warp;
static MacOBloxPoint macoblox_pending_warp_position;
static volatile int macoblox_drop_warp_motion;
static MacOBloxPoint macoblox_expected_warp_delta;
static volatile long macoblox_associate_mouse_count;
static MacOBloxPoint macoblox_lock_anchor;
static volatile int macoblox_lock_anchor_pending;

// Move the pointer by (dx, dy) window points (Cocoa axes, y up).
static void macoblox_warp_pointer_by(double dx, double dy) {
    static int (*warp)(void*, unsigned long, unsigned long, int, int,
                       unsigned int, unsigned int, int, int);
    static int (*flush)(void*);
    if (!warp) {
        warp = (int (*)(void*, unsigned long, unsigned long, int, int,
                        unsigned int, unsigned int, int, int))
            dlsym(RTLD_DEFAULT, "XWarpPointer");
        flush = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFlush");
    }
    id display_object = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
    void* display = display_object
        ? ((void* (*)(id, SEL))objc_msgSend)(display_object, sel_registerName("display"))
        : 0;
    int ix = (int)(dx < 0 ? dx - 0.5 : dx + 0.5);
    int iy = (int)(dy < 0 ? dy - 0.5 : dy + 0.5);
    if (!warp || !display || (!ix && !iy))
        return;
    // X11 y grows downward.
    warp(display, 0, 0, 0, 0, 0, 0, ix, -iy);
    if (flush)
        flush(display);
    macoblox_expected_warp_delta.x = ix;
    macoblox_expected_warp_delta.y = iy;
    macoblox_drop_warp_motion = 1;
}

static MacOBloxPoint macoblox_window_center(id window) {
    // NSRect is returned in memory on x86_64: objc_msgSend_stret, not objc_msgSend.
    extern void objc_msgSend_stret(void);
    MacOBloxRect frame = ((MacOBloxRect (*)(id, SEL))objc_msgSend_stret)(
        window, sel_registerName("frame"));
    MacOBloxPoint center = {frame.size.width / 2.0, frame.size.height / 2.0};
    return center;
}

static id macoblox_lock_window(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
                                             sel_registerName("sharedApplication"));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    if (!window)
        window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    return window;
}

// While locked, a macOS cursor does not move: event locations, the window's
// mouse location and +[NSEvent mouseLocation] all stay where the lock began,
// and only the deltas change. Here the real pointer wanders around the window
// center, so report the frozen positions to Roblox as macOS would.
static MacOBloxPoint macoblox_frozen_window_location;
static MacOBloxPoint macoblox_frozen_screen_location;
static MacOBloxPoint (*orig_event_location_in_window)(id, SEL) = 0;
static MacOBloxPoint (*orig_window_mouse_location)(id, SEL) = 0;
static MacOBloxPoint (*orig_event_mouse_location)(id, SEL) = 0;
static MacOBloxPoint hooked_event_location_in_window(id self, SEL cmd) {
    if (macoblox_pointer_grabbed) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("type"));
        if ((type >= 1 && type <= 7) || type == 25 || type == 26 || type == 27)
            return macoblox_frozen_window_location;
    }
    return orig_event_location_in_window(self, cmd);
}
static MacOBloxPoint hooked_window_mouse_location(id self, SEL cmd) {
    if (macoblox_pointer_grabbed)
        return macoblox_frozen_window_location;
    return orig_window_mouse_location(self, cmd);
}
static MacOBloxPoint hooked_event_mouse_location(id cls, SEL cmd) {
    if (macoblox_pointer_grabbed)
        return macoblox_frozen_screen_location;
    return orig_event_mouse_location(cls, cmd);
}
static MacOBloxPoint macoblox_real_window_mouse_location(id window) {
    SEL selector = sel_registerName("mouseLocationOutsideOfEventStream");
    return orig_window_mouse_location ? orig_window_mouse_location(window, selector)
        : ((MacOBloxPoint (*)(id, SEL))objc_msgSend)(window, selector);
}
static MacOBloxPoint macoblox_real_event_location(id event) {
    SEL selector = sel_registerName("locationInWindow");
    return orig_event_location_in_window ? orig_event_location_in_window(event, selector)
        : ((MacOBloxPoint (*)(id, SEL))objc_msgSend)(event, selector);
}

// Under Xwayland, XWarpPointer only moves the X server's idea of the pointer;
// the next Wayland motion reports the real position again, so recentering
// bounced the pointer back and forth. Xwayland emulates warps properly while
// the X cursor is hidden with XFixes. The requests go over a private X11
// socket (xfixes_raw.c), and on a worker thread, so the game thread never
// waits on X.
extern int macoblox_raw_xfixes_open(void);
extern int macoblox_raw_xfixes_set_hidden(int hidden);
extern int pthread_create(void**, const void*, void* (*)(void*), void*);
extern int usleep(unsigned int);
static volatile int macoblox_cursor_wanted_hidden;
static void* macoblox_xfixes_worker(void* unused) {
    (void)unused;
    if (!macoblox_raw_xfixes_open()) {
        write_str("[MacOBlox] XFixes unavailable, mouse lock may bounce\n");
        return 0;
    }
    write_str("[MacOBlox] XFixes ready for cursor hiding\n");
    int applied = 0;
    for (;;) {
        int wanted = macoblox_cursor_wanted_hidden;
        if (wanted != applied) {
            macoblox_raw_xfixes_set_hidden(wanted);
            applied = wanted;
        }
        usleep(5000);
    }
    return 0;
}

static void macoblox_set_x_cursor_hidden(int hidden) {
    static volatile int started;
    macoblox_cursor_wanted_hidden = hidden;
    if (hidden && __sync_bool_compare_and_swap(&started, 0, 1)) {
        void* thread;
        pthread_create(&thread, 0, macoblox_xfixes_worker, 0);
    }
}

static int macoblox_CGAssociateMouseAndMouseCursorPosition(unsigned int connected) {
    int grab = !connected;
    if (grab == macoblox_pointer_grabbed)
        return 0;
    if (__sync_add_and_fetch(&macoblox_associate_mouse_count, 1) <= 20)
        write_str(grab ? "[MacOBlox Input] mouse lock on\n"
                       : "[MacOBlox Input] mouse lock off\n");
    macoblox_drop_warp_motion = 0;
    if (grab) {
        id window = macoblox_lock_window();
        SEL screen_selector = sel_registerName("mouseLocation");
        id event_class = (id)objc_getClass("NSEvent");
        macoblox_frozen_screen_location = orig_event_mouse_location
            ? orig_event_mouse_location(event_class, screen_selector)
            : ((MacOBloxPoint (*)(id, SEL))objc_msgSend)(event_class, screen_selector);
        if (window)
            macoblox_frozen_window_location = macoblox_real_window_mouse_location(window);
    }
    if (grab) {
        // The pointer stays where the button was pressed. Recentering starts
        // from there; only a press close to the window edge moves the anchor
        // inward, and that first move waits for the first motion event, when
        // the cursor is surely hidden (a warp before that is not emulated by
        // Xwayland and the camera would jump).
        id window = macoblox_lock_window();
        macoblox_lock_anchor = macoblox_frozen_window_location;
        macoblox_lock_anchor_pending = 0;
        if (window) {
            MacOBloxPoint center = macoblox_window_center(window);
            double margin = MACOBLOX_LOCK_RADIUS + 20;
            double width = center.x * 2, height = center.y * 2;
            MacOBloxPoint anchor = macoblox_lock_anchor;
            if (width > margin * 2) {
                if (anchor.x < margin) anchor.x = margin;
                if (anchor.x > width - margin) anchor.x = width - margin;
            } else {
                anchor.x = center.x;
            }
            if (height > margin * 2) {
                if (anchor.y < margin) anchor.y = margin;
                if (anchor.y > height - margin) anchor.y = height - margin;
            } else {
                anchor.y = center.y;
            }
            macoblox_lock_anchor_pending = anchor.x != macoblox_lock_anchor.x ||
                                           anchor.y != macoblox_lock_anchor.y;
            macoblox_lock_anchor = anchor;
        }
        macoblox_pointer_grabbed = 1;
        macoblox_set_x_cursor_hidden(1);
    } else {
        // Put the pointer back where the button was pressed, while it is
        // still hidden, then show it.
        macoblox_pointer_grabbed = 0;
        macoblox_pending_warp = 0;
        id window = macoblox_lock_window();
        if (window) {
            MacOBloxPoint location = macoblox_real_window_mouse_location(window);
            macoblox_warp_pointer_by(macoblox_frozen_window_location.x - location.x,
                                     macoblox_frozen_window_location.y - location.y);
        }
        macoblox_drop_warp_motion = 0;
        macoblox_set_x_cursor_hidden(0);
    }
    return 0;
}
DYLD_INTERPOSE(macoblox_CGAssociateMouseAndMouseCursorPosition,
               CGAssociateMouseAndMouseCursorPosition);

static int macoblox_CGWarpMouseCursorPosition(MacOBloxPoint position) {
    if (macoblox_pointer_grabbed) {
        macoblox_pending_warp_position = position;
        macoblox_pending_warp = 1;
        return 0;
    }
    return CGWarpMouseCursorPosition(position);
}
DYLD_INTERPOSE(macoblox_CGWarpMouseCursorPosition, CGWarpMouseCursorPosition);

// Returns 1 if the motion event must be dropped (it only reflects our warp).
static int macoblox_filter_locked_motion_inner(id event, double dx, double dy);
static double (*orig_mouse_event_delta_x)(id, SEL);
static double (*orig_mouse_event_delta_y)(id, SEL);
// MACOBLOX_TRACE_LOCK=1: log every motion event seen during mouse lock.
static void macoblox_trace_lock_motion(id event, double dx, double dy, const char* action) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACOBLOX_TRACE_LOCK");
        enabled = value && value[0] ? 1 : 0;
    }
    if (!enabled)
        return;
    MacOBloxPoint location = macoblox_real_event_location(event);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
    write_str("[MacOBlox Lock] type=");
    print_num((long long)type);
    write_str(" dx=");
    print_num((long long)dx);
    write_str(" dy=");
    print_num((long long)dy);
    write_str(" at=");
    print_num((long long)location.x);
    write_str(",");
    print_num((long long)location.y);
    write_str(" ");
    write_str(action);
    write_str("\n");
}

static int macoblox_filter_locked_motion(id event) {
    if (!macoblox_pointer_grabbed)
        return 0;
    // Raw Darling deltas (Cocoa axes), without sign flip or sensitivity.
    SEL delta_x = sel_registerName("deltaX"), delta_y = sel_registerName("deltaY");
    double dx = orig_mouse_event_delta_x ? orig_mouse_event_delta_x(event, delta_x)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_x);
    double dy = orig_mouse_event_delta_y ? orig_mouse_event_delta_y(event, delta_y)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_y);
    int dropping = macoblox_drop_warp_motion;
    int dropped = macoblox_filter_locked_motion_inner(event, dx, dy);
    macoblox_trace_lock_motion(event, dx, dy,
                               dropped ? "DROPPED" : (dropping && !macoblox_drop_warp_motion ? "" :
                               (macoblox_drop_warp_motion && !dropping ? "RECENTER" : "")));
    return dropped;
}

static int macoblox_filter_locked_motion_inner(id event, double dx, double dy) {
    if (macoblox_drop_warp_motion) {
        double ex = macoblox_expected_warp_delta.x, ey = macoblox_expected_warp_delta.y;
        if ((dx - ex) * (dx - ex) + (dy - ey) * (dy - ey) <
            0.25 * (ex * ex + ey * ey) + 4.0) {
            macoblox_drop_warp_motion = 0;
            return 1;
        }
    }
    if (!macoblox_drop_warp_motion) {
        MacOBloxPoint location = macoblox_real_event_location(event);
        double ox = location.x - macoblox_lock_anchor.x, oy = location.y - macoblox_lock_anchor.y;
        if (macoblox_lock_anchor_pending) {
            macoblox_lock_anchor_pending = 0;
            macoblox_warp_pointer_by(-ox, -oy);
        } else if (ox > MACOBLOX_LOCK_RADIUS || ox < -MACOBLOX_LOCK_RADIUS ||
                   oy > MACOBLOX_LOCK_RADIUS || oy < -MACOBLOX_LOCK_RADIUS) {
            macoblox_warp_pointer_by(-ox, -oy);
        }
    }
    return 0;
}

// macOS reports mouse motion deltaY positive downward; Darling computes it in
// Cocoa window coordinates (positive upward). Scroll events keep their sign.
// MACOBLOX_MOUSE_SENSITIVITY scales camera motion during mouse lock.
static double macoblox_mouse_sensitivity(void) {
    static double value = -1;
    if (value < 0) {
        const char* text = getenv("MACOBLOX_MOUSE_SENSITIVITY");
        double parsed = 0;
        if (text && text[0]) {
            double scale = 1;
            int fraction = 0;
            for (const char* c = text; *c; c++) {
                if (*c >= '0' && *c <= '9') {
                    if (fraction) { scale /= 10; parsed += (*c - '0') * scale; }
                    else parsed = parsed * 10 + (*c - '0');
                } else if (*c == '.' || *c == ',') {
                    fraction = 1;
                }
            }
        }
        value = parsed > 0.05 && parsed < 20 ? parsed : 1.0;
    }
    return value;
}
static int macoblox_is_motion_type(id event) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    return type == 5 || type == 6 || type == 7 || type == 27;
}
static double (*orig_mouse_event_delta_x)(id, SEL) = 0;
static double hooked_mouse_event_delta_x(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_x(self, cmd);
    if (macoblox_pointer_grabbed && macoblox_is_motion_type(self))
        return delta * macoblox_mouse_sensitivity();
    return delta;
}
static double (*orig_mouse_event_delta_y)(id, SEL) = 0;
static double hooked_mouse_event_delta_y(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_y(self, cmd);
    if (!macoblox_is_motion_type(self))
        return delta;
    delta = -delta;
    return macoblox_pointer_grabbed ? delta * macoblox_mouse_sensitivity() : delta;
}

// Scroll wheel APIs missing from Darling's NSEvent. X11 wheels report coarse
// line deltas, so they are never "precise".
static MacOBloxBool event_has_precise_scrolling_deltas(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static MacOBloxBool event_is_direction_inverted(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static double event_scrolling_delta_x(id self, SEL cmd) {
    (void)cmd;
    return ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaX"));
}
static double event_scrolling_delta_y(id self, SEL cmd) {
    (void)cmd;
    return ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaY"));
}

// Darling's -[X11Cursor initWithImage:hotPoint:] copies each pixel row with a
// wrong source offset, so custom cursors show shifted rows and bytes read past
// the bitmap (the bright pink/blue fringe). Rebuild the Xcursor image here.
typedef struct {
    unsigned int version, size, width, height, xhot, yhot, delay;
    unsigned int* pixels;
} MacOBloxXcursorImage;
typedef struct objc_ivar* Ivar;
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);
extern void* objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void*);
extern void* CGColorSpaceCreateDeviceRGB(void);
extern void CGColorSpaceRelease(void*);
extern void* CGBitmapContextCreate(void*, unsigned long, unsigned long,
                                   unsigned long, unsigned long, void*,
                                   unsigned int);
extern void* CGBitmapContextGetData(void*);
extern unsigned long CGBitmapContextGetBytesPerRow(void*);
extern void CGContextRelease(void*);

extern unsigned long CGImageGetWidth(void*);
extern unsigned long CGImageGetHeight(void*);
extern unsigned long CGImageGetBitsPerComponent(void*);
extern unsigned long CGImageGetBitsPerPixel(void*);
extern unsigned long CGImageGetBytesPerRow(void*);
extern unsigned int CGImageGetBitmapInfo(void*);
extern void* CGImageGetDataProvider(void*);
extern void* CGDataProviderCopyData(void*);
extern const unsigned char* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(const void*);

// Read the cursor image's own pixels instead of drawing it through Darling,
// whose compositing corrupts channels of semi-transparent pixels. Returns an
// Xcursor-style premultiplied ARGB buffer (caller frees), or 0 if the format
// is not a plain 8-bit RGB(A) layout.
static unsigned int* macoblox_cursor_pixels_from_image(
    id image, unsigned long* width_out, unsigned long* height_out) {
    id reps = ((id (*)(id, SEL))objc_msgSend)(image, sel_registerName("representations"));
    unsigned long rep_count = reps
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(reps, sel_registerName("count")) : 0;
    void* cg_image = 0;
    for (unsigned long index = 0; index < rep_count && !cg_image; index++) {
        id rep = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            reps, sel_registerName("objectAtIndex:"), index);
        if (((MacOBloxBool (*)(id, SEL, SEL))objc_msgSend)(
                rep, sel_registerName("respondsToSelector:"), sel_registerName("CGImage")))
            cg_image = ((void* (*)(id, SEL))objc_msgSend)(rep, sel_registerName("CGImage"));
    }
    if (!cg_image)
        return 0;
    unsigned long width = CGImageGetWidth(cg_image);
    unsigned long height = CGImageGetHeight(cg_image);
    unsigned long bits_per_pixel = CGImageGetBitsPerPixel(cg_image);
    unsigned long bytes_per_row = CGImageGetBytesPerRow(cg_image);
    unsigned int info = CGImageGetBitmapInfo(cg_image);
    unsigned int alpha_info = info & 0x1FU;
    unsigned int byte_order = info & 0x7000U;
    static volatile long described;
    if (__sync_add_and_fetch(&described, 1) <= 4) {
        write_str("[MacOBlox Cursor] source ");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(" bpp=");
        print_num((long long)bits_per_pixel);
        write_str(" bpc=");
        print_num((long long)CGImageGetBitsPerComponent(cg_image));
        write_str(" alpha-info=");
        print_num(alpha_info);
        write_str(" byte-order=");
        print_hex(byte_order);
        write_str("\n");
    }
    if (!width || !height || width > 512 || height > 512 ||
        CGImageGetBitsPerComponent(cg_image) != 8 ||
        (bits_per_pixel != 32 && bits_per_pixel != 24) ||
        (byte_order != 0 && byte_order != 0x2000U && byte_order != 0x4000U))
        return 0;
    void* data = CGDataProviderCopyData(CGImageGetDataProvider(cg_image));
    if (!data)
        return 0;
    const unsigned char* bytes = CFDataGetBytePtr(data);
    if ((unsigned long)CFDataGetLength(data) < bytes_per_row * (height - 1) +
                                                   width * (bits_per_pixel / 8)) {
        CFRelease(data);
        return 0;
    }
    unsigned int* pixels = (unsigned int*)malloc(width * height * 4);
    if (!pixels) {
        CFRelease(data);
        return 0;
    }
    int alpha_first = alpha_info == 2 || alpha_info == 4 || alpha_info == 6;
    int has_alpha = alpha_info >= 1 && alpha_info <= 4;
    int premultiplied = alpha_info == 1 || alpha_info == 2;
    for (unsigned long row = 0; row < height; row++) {
        const unsigned char* source = bytes + row * bytes_per_row;
        for (unsigned long column = 0; column < width; column++) {
            unsigned int c[4] = {0, 0, 0, 0};
            if (bits_per_pixel == 24) {
                c[0] = source[column * 3];
                c[1] = source[column * 3 + 1];
                c[2] = source[column * 3 + 2];
                c[3] = 255;
            } else {
                const unsigned char* pixel = source + column * 4;
                // Logical component order, most significant first.
                unsigned char word[4];
                if (byte_order == 0x2000U) {
                    word[0] = pixel[3]; word[1] = pixel[2];
                    word[2] = pixel[1]; word[3] = pixel[0];
                } else {
                    word[0] = pixel[0]; word[1] = pixel[1];
                    word[2] = pixel[2]; word[3] = pixel[3];
                }
                if (alpha_first) {
                    c[3] = word[0]; c[0] = word[1]; c[1] = word[2]; c[2] = word[3];
                } else {
                    c[0] = word[0]; c[1] = word[1]; c[2] = word[2]; c[3] = word[3];
                }
                if (!has_alpha)
                    c[3] = 255;
            }
            if (!premultiplied) {
                for (int channel = 0; channel < 3; channel++)
                    c[channel] = c[channel] * c[3] / 255;
            }
            pixels[row * width + column] =
                (c[3] << 24) | (c[0] << 16) | (c[1] << 8) | c[2];
        }
    }
    CFRelease(data);
    *width_out = width;
    *height_out = height;
    return pixels;
}

static id (*orig_x11_cursor_init_image)(id, SEL, id, MacOBloxPoint) = 0;
static id hooked_x11_cursor_init_image(id self, SEL cmd, id image,
                                       MacOBloxPoint hot) {
    MacOBloxXcursorImage* (*image_create)(int, int) =
        (MacOBloxXcursorImage* (*)(int, int))
            dlsym(RTLD_DEFAULT, "XcursorImageCreate");
    void (*image_destroy)(MacOBloxXcursorImage*) =
        (void (*)(MacOBloxXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageDestroy");
    unsigned long (*load_cursor)(void*, const MacOBloxXcursorImage*) =
        (unsigned long (*)(void*, const MacOBloxXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageLoadCursor");
    Ivar cursor_ivar = class_getInstanceVariable(object_getClass(self), "_cursor");
    MacOBloxSize size = image
        ? ((MacOBloxSize (*)(id, SEL))objc_msgSend)(image, sel_registerName("size"))
        : (MacOBloxSize){0, 0};
    unsigned long width = (unsigned long)size.width;
    unsigned long height = (unsigned long)size.height;
    if (!image_create || !image_destroy || !load_cursor || !cursor_ivar ||
        !width || !height || width > 512 || height > 512)
        return orig_x11_cursor_init_image(self, cmd, image, hot);

    unsigned long source_width = 0, source_height = 0;
    unsigned int* source_pixels =
        macoblox_cursor_pixels_from_image(image, &source_width, &source_height);
    if (source_pixels) {
        id direct_display_object = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
        void* direct_display = direct_display_object
            ? ((void* (*)(id, SEL))objc_msgSend)(direct_display_object,
                                                  sel_registerName("display"))
            : 0;
        MacOBloxXcursorImage* direct = direct_display
            ? image_create((int)source_width, (int)source_height) : 0;
        if (direct) {
            for (unsigned long index = 0; index < source_width * source_height; index++)
                direct->pixels[index] = source_pixels[index];
            // The hot spot is given in image points; the bitmap may be larger.
            double scale_x = (double)source_width / (double)width;
            double scale_y = (double)source_height / (double)height;
            double hot_x = hot.x * scale_x, hot_y = hot.y * scale_y;
            direct->xhot = hot_x < 0 ? 0 : (hot_x >= source_width ? source_width - 1 : (unsigned int)hot_x);
            direct->yhot = hot_y < 0 ? 0 : (hot_y >= source_height ? source_height - 1 : (unsigned int)hot_y);
            unsigned long direct_cursor = load_cursor(direct_display, direct);
            image_destroy(direct);
            if (direct_cursor) {
                free(source_pixels);
                *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = direct_cursor;
                return self;
            }
        }
        free(source_pixels);
    }

    id display_object = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
    void* display = display_object
        ? ((void* (*)(id, SEL))objc_msgSend)(display_object, sel_registerName("display"))
        : 0;
    MacOBloxXcursorImage* ximage = display ? image_create((int)width, (int)height) : 0;
    void* color_space = ximage ? CGColorSpaceCreateDeviceRGB() : 0;
    // Premultiplied ARGB in host byte order, the XcursorPixel format.
    void* bitmap = color_space
        ? CGBitmapContextCreate(0, width, height, 8, 0, color_space,
                                2U /* PremultipliedFirst */ | 0x2000U /* 32Little */)
        : 0;
    if (color_space)
        CGColorSpaceRelease(color_space);
    if (!bitmap) {
        if (ximage)
            image_destroy(ximage);
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    }

    void* pool = objc_autoreleasePoolPush();
    id context_class = (id)objc_getClass("NSGraphicsContext");
    id graphics = ((id (*)(id, SEL, void*, MacOBloxBool))objc_msgSend)(
        context_class, sel_registerName("graphicsContextWithGraphicsPort:flipped:"),
        bitmap, 0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("saveGraphicsState"));
    ((void (*)(id, SEL, id))objc_msgSend)(
        context_class, sel_registerName("setCurrentContext:"), graphics);
    MacOBloxRect destination = {{0, 0}, {(double)width, (double)height}};
    MacOBloxRect whole_image = {{0, 0}, {0, 0}};
    ((void (*)(id, SEL, MacOBloxRect, MacOBloxRect, unsigned long, double))objc_msgSend)(
        image, sel_registerName("drawInRect:fromRect:operation:fraction:"),
        destination, whole_image, 1UL /* NSCompositeCopy */, 1.0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("restoreGraphicsState"));
    objc_autoreleasePoolPop(pool);

    const unsigned char* rows = (const unsigned char*)CGBitmapContextGetData(bitmap);
    unsigned long bytes_per_row = CGBitmapContextGetBytesPerRow(bitmap);
    for (unsigned long row = 0; row < height; row++) {
        const unsigned int* source = (const unsigned int*)(rows + row * bytes_per_row);
        for (unsigned long column = 0; column < width; column++)
            ximage->pixels[row * width + column] = source[column];
    }
    CGContextRelease(bitmap);

    // Xcursor expects premultiplied ARGB. Darling's image drawing can leave
    // straight alpha, which shows up as a bright fringe on soft edges. A
    // channel above its alpha is impossible when premultiplied, so use that
    // to detect the format and premultiply only in that case.
    unsigned long pixel_count = width * height;
    int straight_alpha = 0;
    for (unsigned long index = 0; index < pixel_count && !straight_alpha; index++) {
        unsigned int pixel = ximage->pixels[index];
        unsigned int alpha = pixel >> 24;
        if (((pixel >> 16) & 255) > alpha || ((pixel >> 8) & 255) > alpha ||
            (pixel & 255) > alpha)
            straight_alpha = 1;
    }
    if (straight_alpha) {
        for (unsigned long index = 0; index < pixel_count; index++) {
            unsigned int pixel = ximage->pixels[index];
            unsigned int alpha = pixel >> 24;
            unsigned int red = ((pixel >> 16) & 255) * alpha / 255;
            unsigned int green = ((pixel >> 8) & 255) * alpha / 255;
            unsigned int blue = (pixel & 255) * alpha / 255;
            ximage->pixels[index] = (alpha << 24) | (red << 16) | (green << 8) | blue;
        }
    }
    static volatile long dumped_cursors;
    long dump_index = __sync_add_and_fetch(&dumped_cursors, 1) - 1;
    if (dump_index < 4) {
        write_str("[MacOBlox Cursor] #");
        print_num(dump_index);
        write_str(" size=");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(straight_alpha ? " straight-alpha (premultiplied now)\n"
                                 : " already premultiplied\n");
    }

    ximage->xhot = hot.x < 0 ? 0 : (hot.x >= width ? width - 1 : (unsigned int)hot.x);
    ximage->yhot = hot.y < 0 ? 0 : (hot.y >= height ? height - 1 : (unsigned int)hot.y);
    unsigned long cursor = load_cursor(display, ximage);
    image_destroy(ximage);
    if (!cursor)
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = cursor;
    return self;
}

// Darling stubs +[NSEvent addLocalMonitorForEventsMatchingMask:handler:].
// Roblox installs local monitors for its input, so implement them the macOS
// way: -[NSApplication sendEvent:] passes each matching event to the handlers
// first; a handler may replace the event or return nil to consume it.
struct MacOBloxBlock {
    void* isa;
    int flags;
    int reserved;
    id (*invoke)(void*, id);
};
extern void* _Block_copy(const void*);
extern void _Block_release(const void*);
#define MACOBLOX_MAX_MONITORS 32
static struct {
    unsigned long long mask;
    struct MacOBloxBlock* block;
} macoblox_monitors[MACOBLOX_MAX_MONITORS];
static volatile int macoblox_monitor_lock;

static id event_add_local_monitor(id cls, SEL cmd, unsigned long long mask,
                                  void* handler) {
    (void)cls; (void)cmd;
    if (!handler)
        return 0;
    struct MacOBloxBlock* block = (struct MacOBloxBlock*)_Block_copy(handler);
    while (!__sync_bool_compare_and_swap(&macoblox_monitor_lock, 0, 1)) {}
    int stored = 0;
    for (int index = 0; index < MACOBLOX_MAX_MONITORS && !stored; index++) {
        if (!macoblox_monitors[index].block) {
            macoblox_monitors[index].mask = mask;
            macoblox_monitors[index].block = block;
            stored = 1;
        }
    }
    macoblox_monitor_lock = 0;
    write_str("[MacOBlox Input] addLocalMonitorForEventsMatchingMask mask=");
    print_hex(mask);
    write_str(stored ? "\n" : " (table full, ignored)\n");
    if (!stored) {
        _Block_release(block);
        return 0;
    }
    return (id)block;
}

static void event_remove_monitor(id cls, SEL cmd, id monitor) {
    (void)cls; (void)cmd;
    if (!monitor)
        return;
    while (!__sync_bool_compare_and_swap(&macoblox_monitor_lock, 0, 1)) {}
    for (int index = 0; index < MACOBLOX_MAX_MONITORS; index++) {
        if (macoblox_monitors[index].block == (struct MacOBloxBlock*)monitor) {
            macoblox_monitors[index].block = 0;
            macoblox_monitors[index].mask = 0;
            macoblox_monitor_lock = 0;
            _Block_release(monitor);
            return;
        }
    }
    macoblox_monitor_lock = 0;
}

// Keyboard state for CGEventSourceKeyState, which Darling lacks and Roblox
// polls in game. Built from the key events AppKit dispatches.
static volatile unsigned char macoblox_key_down[128];
static void macoblox_track_key_event(id event, unsigned long type) {
    if (type != 10 && type != 11 && type != 12) // keyDown, keyUp, flagsChanged
        return;
    unsigned short key = ((unsigned short (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("keyCode"));
    if (key >= 128)
        return;
    if (type != 12) {
        macoblox_key_down[key] = type == 10;
        return;
    }
    unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("modifierFlags"));
    unsigned long bit = 0;
    switch (key) {
    case 56: case 60: bit = 1UL << 17; break; // shift
    case 59: case 62: bit = 1UL << 18; break; // control
    case 58: case 61: bit = 1UL << 19; break; // option
    case 55: case 54: bit = 1UL << 20; break; // command
    case 57: bit = 1UL << 16; break;          // caps lock
    default: return;
    }
    macoblox_key_down[key] = (flags & bit) != 0;
}
unsigned char CGEventSourceKeyState(int state_id, unsigned short key) {
    (void)state_id;
    return key < 128 ? macoblox_key_down[key] : 0;
}

static int macoblox_trace_keys_enabled(void);
static void (*orig_app_send_event)(id, SEL, id) = 0;
static void hooked_app_send_event(id self, SEL cmd, id event) {
    if (event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        macoblox_track_key_event(event, type);
        if ((type == 10 || type == 11) && macoblox_trace_keys_enabled()) {
            write_str(type == 10 ? "[MacOBlox Keys] game keyDown code=" : "[MacOBlox Keys] game keyUp   code=");
            print_num(((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode")));
            write_str(((signed char (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat")) ? " repeat\n" : "\n");
        }
        if ((type == 5 || type == 6 || type == 7 || type == 27) &&
            macoblox_filter_locked_motion(event))
            return;
        unsigned long long event_mask = type < 64 ? 1ULL << type : 0;
        struct MacOBloxBlock* handlers[MACOBLOX_MAX_MONITORS];
        int handler_count = 0;
        while (!__sync_bool_compare_and_swap(&macoblox_monitor_lock, 0, 1)) {}
        for (int index = 0; index < MACOBLOX_MAX_MONITORS; index++) {
            if (macoblox_monitors[index].block &&
                (macoblox_monitors[index].mask & event_mask))
                handlers[handler_count++] = macoblox_monitors[index].block;
        }
        macoblox_monitor_lock = 0;
        for (int index = 0; index < handler_count && event; index++)
            event = handlers[index]->invoke(handlers[index], event);
        if (!event)
            return;
    }
    orig_app_send_event(self, cmd, event);
}

// Darling drops pointer motion unless the window accepts mouse-moved events.
// On macOS Roblox receives motion through tracking areas instead, which
// Darling does not deliver here, so the Roblox window always accepts them.
static MacOBloxBool (*orig_window_accepts_mouse_moved)(id, SEL) = 0;
static MacOBloxBool hooked_window_accepts_mouse_moved(id self, SEL cmd) {
    const char* class_name = object_getClassName(self);
    if (class_name && ascii_strings_equal(class_name, "RBXWindow"))
        return 1;
    return orig_window_accepts_mouse_moved(self, cmd);
}

// MACOBLOX_TRACE_EVENTS=1: log mouse events as AppKit dispatches them.
// Movement is sampled; button, enter/exit and scroll events are all logged.
static void (*orig_window_send_event)(id, SEL, id) = 0;
static volatile long macoblox_traced_motion_events;
static void hooked_window_send_event(id self, SEL cmd, id event) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACOBLOX_TRACE_EVENTS");
        enabled = value && value[0] ? 1 : 0;
    }
    if (enabled && event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        int is_button = type == 1 || type == 2 || type == 3 || type == 4 ||
                        type == 25 || type == 26;
        int is_motion = type == 5 || type == 6 || type == 7 || type == 27;
        int is_other = type == 8 || type == 9 || type == 22;
        int log = is_button || is_other;
        if (is_motion) {
            long count = __sync_add_and_fetch(&macoblox_traced_motion_events, 1);
            log = count <= 20 || count % 50 == 0;
        }
        if (log) {
            MacOBloxPoint location = ((MacOBloxPoint (*)(id, SEL))objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            write_str("[MacOBlox Event] type=");
            print_num((long long)type);
            write_str(" window=");
            write_str(object_getClassName(self));
            write_str(" x=");
            print_num((long long)location.x);
            write_str(" y=");
            print_num((long long)location.y);
            if (is_button) {
                write_str(" button=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("buttonNumber")));
                write_str(" clicks=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("clickCount")));
                id content = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("contentView"));
                id superview = content ? ((id (*)(id, SEL))objc_msgSend)(
                    content, sel_registerName("superview")) : 0;
                id root = superview ? superview : content;
                id hit = root ? ((id (*)(id, SEL, MacOBloxPoint))objc_msgSend)(
                    root, sel_registerName("hitTest:"), location) : 0;
                write_str(" hit=");
                write_str(hit ? object_getClassName(hit) : "(nil)");
                id responder = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("firstResponder"));
                write_str(" first-responder=");
                write_str(responder ? object_getClassName(responder) : "(nil)");
            }
            if (is_motion) {
                write_str(" sample=");
                print_num(macoblox_traced_motion_events);
            }
            write_str("\n");
        }
    }
    orig_window_send_event(self, cmd, event);
}

// Log where Roblox tries to send the user: an in-app WKWebView page or an
// external URL. Darling's WebKit is a stub, so both currently show nothing.
static void macoblox_log_url(const char* prefix, id url) {
    id text = url ? ((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")) : 0;
    const char* utf8 = text ? ((const char* (*)(id, SEL))objc_msgSend)(
                                  text, sel_registerName("UTF8String")) : 0;
    write_str(prefix);
    write_str(utf8 ? utf8 : "(nil)");
    write_str("\n");
}
static id (*orig_web_view_init)(id, SEL, MacOBloxRect, id) = 0;
static id hooked_web_view_init(id self, SEL cmd, MacOBloxRect frame, id configuration) {
    write_str("[MacOBlox Web] WKWebView initWithFrame:configuration:\n");
    return orig_web_view_init(self, cmd, frame, configuration);
}
static id (*orig_web_view_load_request)(id, SEL, id) = 0;
static id hooked_web_view_load_request(id self, SEL cmd, id request) {
    id url = request ? ((id (*)(id, SEL))objc_msgSend)(request, sel_registerName("URL")) : 0;
    macoblox_log_url("[MacOBlox Web] WKWebView loadRequest: ", url);
    return orig_web_view_load_request(self, cmd, request);
}
static MacOBloxBool (*orig_workspace_open_url)(id, SEL, id) = 0;
static MacOBloxBool hooked_workspace_open_url(id self, SEL cmd, id url) {
    MacOBloxBool result = orig_workspace_open_url(self, cmd, url);
    macoblox_log_url(result ? "[MacOBlox Web] NSWorkspace openURL: (ok) "
                            : "[MacOBlox Web] NSWorkspace openURL: (failed) ", url);
    return result;
}

// Darling stores the X11 button number (left 1, middle 2, right 3, back 8,
// forward 9) in -[NSEvent buttonNumber]. macOS numbers them left 0, right 1,
// middle 2, then 3 and 4. Roblox therefore saw every left click as the right
// button: GUI hover and press states still worked, but Activated (left button
// only) never fired, and the "right button" started camera mouse capture.
static long (*orig_mouse_event_button_number)(id, SEL) = 0;
static long hooked_mouse_event_button_number(id self, SEL cmd) {
    long x11_button = orig_mouse_event_button_number(self, cmd);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        self, sel_registerName("type"));
    switch (type) {
    case 1: case 2: case 6:   // left down, up, dragged
        return 0;
    case 3: case 4: case 7:   // right down, up, dragged
        return 1;
    default:
        break;
    }
    if (x11_button == 2)
        return 2;
    if (x11_button >= 8)
        return x11_button - 5;
    return x11_button;
}

// NSTextInputClient methods that macOS NSTextView provides and Darling's
// lacks. Roblox's InputMethodHandler (an NSTextView subclass) queries them
// when a text box gains focus; the missing hasMarkedText was fatal. These
// report "no IME composition in progress", matching a plain text field.
typedef struct { unsigned long location, length; } MacOBloxRange;
static MacOBloxBool text_view_has_marked_text(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static MacOBloxRange text_view_marked_range(id self, SEL cmd) {
    (void)self; (void)cmd;
    MacOBloxRange range = {0x7FFFFFFFFFFFFFFFUL /* NSNotFound */, 0};
    return range;
}
static void text_view_unmark_text(id self, SEL cmd) {
    (void)self; (void)cmd;
}
static id text_view_valid_marked_attributes(id self, SEL cmd) {
    (void)self; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSArray"),
                                           sel_registerName("array"));
}
static id text_view_attributed_substring(id self, SEL cmd, MacOBloxRange range,
                                         MacOBloxRange* actual) {
    (void)self; (void)cmd; (void)range;
    if (actual) {
        actual->location = 0x7FFFFFFFFFFFFFFFUL;
        actual->length = 0;
    }
    return 0;
}

// Convenience constructors from macOS 10.12 missing in Darling's AppKit.
// Roblox builds its web challenge window with them.
static id macoblox_new_view(const char* class_name) {
    id object = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass(class_name),
                                                sel_registerName("alloc"));
    MacOBloxRect zero = {{0, 0}, {0, 0}};
    object = ((id (*)(id, SEL, MacOBloxRect))objc_msgSend)(
        object, sel_registerName("initWithFrame:"), zero);
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName("autorelease"));
}
static id button_with_image_target_action(id cls, SEL cmd, id image, id target,
                                          SEL action) {
    (void)cls; (void)cmd;
    id button = macoblox_new_view("NSButton");
    if (!button)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setImage:"), image);
    ((void (*)(id, SEL, unsigned long))objc_msgSend)(
        button, sel_registerName("setImagePosition:"), 1UL /* NSImageOnly */);
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setTarget:"), target);
    ((void (*)(id, SEL, SEL))objc_msgSend)(button, sel_registerName("setAction:"), action);
    ((void (*)(id, SEL))objc_msgSend)(button, sel_registerName("sizeToFit"));
    return button;
}
static id text_field_label_with_string(id cls, SEL cmd, id string) {
    (void)cls; (void)cmd;
    id label = macoblox_new_view("NSTextField");
    if (!label)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setStringValue:"), string);
    ((void (*)(id, SEL, MacOBloxBool))objc_msgSend)(label, sel_registerName("setEditable:"), 0);
    ((void (*)(id, SEL, MacOBloxBool))objc_msgSend)(label, sel_registerName("setSelectable:"), 0);
    ((void (*)(id, SEL, MacOBloxBool))objc_msgSend)(label, sel_registerName("setBezeled:"), 0);
    ((void (*)(id, SEL, MacOBloxBool))objc_msgSend)(label, sel_registerName("setBordered:"), 0);
    ((void (*)(id, SEL, MacOBloxBool))objc_msgSend)(label, sel_registerName("setDrawsBackground:"), 0);
    ((void (*)(id, SEL))objc_msgSend)(label, sel_registerName("sizeToFit"));
    return label;
}

// Darling's Contacts framework is an empty stub. Roblox's home page asks for
// contacts permission (friend finding); report access as denied so it never
// tries to read contacts.
static long contact_store_authorization_denied(id cls, SEL cmd, long entity_type) {
    (void)cls; (void)cmd; (void)entity_type;
    return 2; // CNAuthorizationStatusDenied
}
struct MacOBloxAccessBlock {
    void* isa;
    int flags;
    int reserved;
    void (*invoke)(void*, MacOBloxBool, id);
};
static void contact_store_request_access(id self, SEL cmd, long entity_type,
                                         void* completion) {
    (void)self; (void)cmd; (void)entity_type;
    if (completion)
        ((struct MacOBloxAccessBlock*)completion)->invoke(completion, 0, 0);
}

// Darling's Keychain does not persist SecItemAdd, so Roblox's login (a
// generic password item keyed by kSecAttrAccount) was gone after every
// restart. Keep generic password items as files instead:
// ~/Library/MacOBlox/Keychain/<hex account>, mode 0600.
// Other item classes still go to Darling's Security framework.
extern int SecItemAdd(id attributes, id* result);
extern int SecItemCopyMatching(id query, id* result);
extern int SecItemDelete(id query);
extern const id kSecClass;
extern const id kSecClassGenericPassword;
extern const id kSecAttrAccount;
extern const id kSecValueData;
extern const id kSecReturnData;
extern int chmod(const char*, unsigned short);
#define MACOBLOX_ERR_SEC_ITEM_NOT_FOUND (-25300)

static id macoblox_keychain_path(id query) {
    id item_class = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecClass);
    id account = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecAttrAccount);
    if (!item_class || !account ||
        !((MacOBloxBool (*)(id, SEL, id))objc_msgSend)(item_class, sel_registerName("isEqual:"),
                                                        kSecClassGenericPassword))
        return 0;
    const char* name = ((const char* (*)(id, SEL))objc_msgSend)(account, sel_registerName("UTF8String"));
    if (!name)
        return 0;
    char hex[512];
    int length = 0;
    for (const unsigned char* c = (const unsigned char*)name; *c && length < 500; c++) {
        static const char digits[] = "0123456789abcdef";
        hex[length++] = digits[*c >> 4];
        hex[length++] = digits[*c & 15];
    }
    hex[length] = 0;
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    id directory = ((id (*)(id, SEL, id))objc_msgSend)(
        home, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), "Library/MacOBlox/Keychain"));
    ((MacOBloxBool (*)(id, SEL, id, MacOBloxBool, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    return ((id (*)(id, SEL, id))objc_msgSend)(
        directory, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), hex));
}

static int macoblox_SecItemAdd(id attributes, id* result) {
    id path = attributes ? macoblox_keychain_path(attributes) : 0;
    if (!path)
        return SecItemAdd(attributes, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)(attributes, sel_registerName("objectForKey:"), kSecValueData);
    if (!data)
        data = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSData"), sel_registerName("data"));
    ((MacOBloxBool (*)(id, SEL, id, MacOBloxBool))objc_msgSend)(
        data, sel_registerName("writeToFile:atomically:"), path, 0); // atomic writes are broken in Darling
    chmod(((const char* (*)(id, SEL))objc_msgSend)(path, sel_registerName("fileSystemRepresentation")), 0600);
    if (result)
        *result = 0;
    write_str("[MacOBlox Keychain] stored generic password item\n");
    return 0;
}
DYLD_INTERPOSE(macoblox_SecItemAdd, SecItemAdd);

static int macoblox_SecItemCopyMatching(id query, id* result) {
    id path = query ? macoblox_keychain_path(query) : 0;
    if (!path)
        return SecItemCopyMatching(query, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("NSData"),
                                                 sel_registerName("dataWithContentsOfFile:"), path);
    if (!data)
        return MACOBLOX_ERR_SEC_ITEM_NOT_FOUND;
    id wants_data = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecReturnData);
    if (result)
        *result = wants_data && ((MacOBloxBool (*)(id, SEL))objc_msgSend)(wants_data, sel_registerName("boolValue"))
            ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain"))  // caller owns (+1)
            : 0;
    return 0;
}
DYLD_INTERPOSE(macoblox_SecItemCopyMatching, SecItemCopyMatching);

static int macoblox_SecItemDelete(id query) {
    id path = query ? macoblox_keychain_path(query) : 0;
    if (!path)
        return SecItemDelete(query);
    MacOBloxBool removed = ((MacOBloxBool (*)(id, SEL, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("removeItemAtPath:error:"), path, 0);
    return removed ? 0 : MACOBLOX_ERR_SEC_ITEM_NOT_FOUND;
}
DYLD_INTERPOSE(macoblox_SecItemDelete, SecItemDelete);

// Records the requested OpenGL profile (gl_profile.c); MACOBLOX_TRACE_CGL
// logs the attributes (Darling's CGL pixel format keeps almost none of them).
static id (*orig_pixel_format_init)(id, SEL, const unsigned int*) = 0;
static const unsigned int* macoblox_last_pixel_attributes;
static id hooked_pixel_format_init(id self, SEL cmd, const unsigned int* attributes) {
    if (macoblox_trace_cgl_enabled()) {
        write_str("[MacOBlox CGL] NSOpenGLPixelFormat attributes:");
        for (int index = 0; attributes && index < 24; index++) {
            write_str(" ");
            print_num(attributes[index]);
        }
        write_str("\n");
    }
    macoblox_last_pixel_attributes = attributes;
    id result = orig_pixel_format_init(self, cmd, attributes);
    macoblox_note_pixel_format(result, attributes);
    return result;
}

// Darling's event queue (NSDisplay) fixed to behave like macOS.
//
// -nextEventMatchingMask:untilDate:inMode:dequeue: removed every queued
// event that did not match the mask while looking for one that did. macOS
// leaves them queued. When the game asked for mouse events during a camera
// drag, key releases waiting in front were thrown away: keys stuck ("W
// stayed pressed") or presses were lost. -discardEventsMatchingMask:
// beforeEvent: tested the reference event's type instead of each queued
// event's. The queue (an NSMutableArray) is also shared with the rendering
// thread (shared_current_display), so all three take a lock.
static volatile int macoblox_event_queue_lock;
static void macoblox_lock_event_queue(void) {
    while (__sync_lock_test_and_set(&macoblox_event_queue_lock, 1)) {}
}
static void macoblox_unlock_event_queue(void) {
    __sync_lock_release(&macoblox_event_queue_lock);
}
static id macoblox_event_queue(id display) {
    static Ivar queue_ivar;
    if (!queue_ivar)
        queue_ivar = class_getInstanceVariable(objc_getClass("NSDisplay"), "_eventQueue");
    return queue_ivar ? *(id*)((char*)display + ivar_getOffset(queue_ivar)) : (id)0;
}
static unsigned long macoblox_event_type(id event) {
    return ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
}
static int macoblox_mask_matches(unsigned long long mask, unsigned long type) {
    return type < 64 && (mask & (1ULL << type));
}

static id hooked_display_next_event(id self, SEL cmd, unsigned long long mask, id until, id mode,
                                    signed char dequeue) {
    (void)cmd;
    id queue = macoblox_event_queue(self);
    SEL count = sel_registerName("count"), object_at = sel_registerName("objectAtIndex:");
    if (queue && ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count))
        until = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSDate"), sel_registerName("date"));
    id run_loop = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSRunLoop"),
                                                  sel_registerName("currentRunLoop"));
    ((signed char (*)(id, SEL, id, id))objc_msgSend)(run_loop, sel_registerName("runMode:beforeDate:"),
                                                     mode, until);
    id result = (id)0;
    if (queue) {
        macoblox_lock_event_queue();
        unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count);
        for (unsigned long index = 0; index < total; index++) {
            id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, object_at, index);
            if (!macoblox_mask_matches(mask, macoblox_event_type(event)))
                continue;
            result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("retain"));
            if (dequeue)
                ((void (*)(id, SEL, unsigned long))objc_msgSend)(
                    queue, sel_registerName("removeObjectAtIndex:"), index);
            break;
        }
        /* Nobody may ever ask for some event types; keep the queue bounded. */
        while (((unsigned long (*)(id, SEL))objc_msgSend)(queue, count) > 4096)
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), 0);
        macoblox_unlock_event_queue();
        if (result)
            result = ((id (*)(id, SEL))objc_msgSend)(result, sel_registerName("autorelease"));
    }
    if (!result) {
        /* As Darling: an NSAppKitSystem event when nothing matches. */
        id event = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSEvent"), sel_registerName("alloc"));
        event = ((id (*)(id, SEL, unsigned long, MacOBloxPoint, unsigned long, id))objc_msgSend)(
            event, sel_registerName("initWithType:location:modifierFlags:window:"), 13 /* NSAppKitSystem */,
            (MacOBloxPoint){0, 0}, 0, (id)0);
        result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("autorelease"));
    }
    return result;
}

static void hooked_display_post_event(id self, SEL cmd, id event, signed char at_start) {
    (void)cmd;
    id queue = macoblox_event_queue(self);
    if (!queue || !event)
        return;
    macoblox_lock_event_queue();
    if (at_start)
        ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(queue, sel_registerName("insertObject:atIndex:"),
                                                             event, 0);
    else
        ((void (*)(id, SEL, id))objc_msgSend)(queue, sel_registerName("addObject:"), event);
    macoblox_unlock_event_queue();
}

static void hooked_display_discard_events(id self, SEL cmd, unsigned long long mask, id before) {
    (void)cmd;
    id queue = macoblox_event_queue(self);
    if (!queue)
        return;
    macoblox_lock_event_queue();
    unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, sel_registerName("count"));
    unsigned long stop = total;
    for (unsigned long index = 0; index < total; index++)
        if (((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index) == before) {
            stop = index;
            break;
        }
    for (unsigned long index = stop; index-- > 0;) {
        id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index);
        if (macoblox_mask_matches(mask, macoblox_event_type(event)))
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), index);
    }
    macoblox_unlock_event_queue();
}

// X11 events as Darling's AppKit receives them (-[X11Display postXEvent:]).
//
// Motion compression: a 1000 Hz mouse sends a motion event per pixel, and
// Darling turns every one into an NSEvent the game handles. It could not
// keep up; a pointer warp during mouse lock reached the game 180-340 events
// late and the camera lagged and jumped (reported on an RTX 3050 laptop).
// A motion event is skipped when the next queued event is a motion event
// of the same window and buttons: Darling computes deltas from positions,
// so the next one carries the skipped movement. Jumps over 48 px (our
// warps) are never merged, the lock logic needs to see them alone.
// MACOBLOX_NO_MOTION_COMPRESSION=1 turns this off.
// MACOBLOX_TRACE_KEYS=1 logs X key presses/releases here and the key events
// the game gets (sendEvent), to find lost or stuck keys.
static void (*orig_post_x_event)(id, SEL, void*);
static int macoblox_trace_keys_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("MACOBLOX_TRACE_KEYS");
        enabled = value && value[0] == '1';
    }
    return enabled;
}
static void hooked_post_x_event(id self, SEL cmd, void* event) {
    int type = *(int*)event;
    if (type == 6 /* MotionNotify */) {
        static int compression = -1;
        static int (*pending)(void*);
        static int (*peek)(void*, void*);
        if (compression < 0) {
            const char* value = getenv("MACOBLOX_NO_MOTION_COMPRESSION");
            pending = (int (*)(void*))dlsym(RTLD_DEFAULT, "XPending");
            peek = (int (*)(void*, void*))dlsym(RTLD_DEFAULT, "XPeekEvent");
            compression = !(value && value[0] == '1') && pending && peek;
        }
        Ivar display_ivar = compression ? class_getInstanceVariable(object_getClass(self), "_display") : 0;
        void* display = display_ivar ? *(void**)((char*)self + ivar_getOffset(display_ivar)) : 0;
        if (display && pending(display) > 0) {
            unsigned char next[192];
            peek(display, next);
            /* XMotionEvent: window at 32, x/y at 64/68, state at 80 */
            int dx = *(int*)(next + 64) - *(int*)((char*)event + 64);
            int dy = *(int*)(next + 68) - *(int*)((char*)event + 68);
            if (*(int*)next == 6 &&
                *(unsigned long*)(next + 32) == *(unsigned long*)((char*)event + 32) &&
                *(unsigned int*)(next + 80) == *(unsigned int*)((char*)event + 80) &&
                dx <= 48 && dx >= -48 && dy <= 48 && dy >= -48)
                return;
        }
    } else if ((type == 2 || type == 3) && macoblox_trace_keys_enabled()) {
        /* XKeyEvent: time at 56, keycode at 84 */
        write_str(type == 2 ? "[MacOBlox Keys] X press   keycode=" : "[MacOBlox Keys] X release keycode=");
        print_num(*(unsigned int*)((char*)event + 84));
        write_str(" time=");
        print_num((long long)*(unsigned long*)((char*)event + 56));
        /* When Darling handles it, in the same milliseconds scale: if the
         * gap to `time` grows, events wait inside Mac O' Blox. */
        write_str(" handled=");
        print_num((long long)(mach_absolute_time() / 1000000ULL));
        write_str("\n");
    }
    orig_post_x_event(self, cmd, event);
}

// OpenGL subwindows get the screen's visual (gl_profile.c explains why).
extern unsigned long macoblox_replace_gl_subwindow(void* display, unsigned long parent, unsigned long old);
static id (*orig_x11_subwindow_init)(id, SEL, id, MacOBloxRect);
static id hooked_x11_subwindow_init(id self, SEL cmd, id parent, MacOBloxRect frame) {
    id result = orig_x11_subwindow_init(self, cmd, parent, frame);
    if (!result || !parent)
        return result;
    Class cls = object_getClass(result);
    Ivar window_ivar = class_getInstanceVariable(cls, "_window");
    Ivar display_ivar = class_getInstanceVariable(cls, "_display");
    if (!window_ivar || !display_ivar)
        return result;
    unsigned long* window = (unsigned long*)((char*)result + ivar_getOffset(window_ivar));
    void* display = *(void**)((char*)result + ivar_getOffset(display_ivar));
    unsigned long parent_handle =
        ((unsigned long (*)(id, SEL))objc_msgSend)(parent, sel_registerName("windowHandle"));
    *window = macoblox_replace_gl_subwindow(display, parent_handle, *window);
    return result;
}

// Classes from Darling's X11 backend load after this library initializes, so
// hooks on them are installed again once NSApplication finishes launching.
static void macoblox_install_late_hooks(void) {
    static volatile int cursor_hooked;
    static volatile int window_events_hooked;
    static volatile int event_queue_hooked;
    Class display_class = objc_getClass("NSDisplay");
    if (display_class && __sync_bool_compare_and_swap(&event_queue_hooked, 0, 1)) {
        Method next = class_getInstanceMethod(display_class,
            sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:"));
        Method post = class_getInstanceMethod(display_class, sel_registerName("postEvent:atStart:"));
        Method discard = class_getInstanceMethod(display_class,
            sel_registerName("discardEventsMatchingMask:beforeEvent:"));
        if (next && post && discard && class_getInstanceVariable(display_class, "_eventQueue")) {
            method_setImplementation(next, (IMP)hooked_display_next_event);
            method_setImplementation(post, (IMP)hooked_display_post_event);
            method_setImplementation(discard, (IMP)hooked_display_discard_events);
            write_str("[MacOBlox] Event queue keeps non-matching events (NSDisplay fix)\n");
        }
    }
    static volatile int x_events_hooked;
    Class x11_display_class = objc_getClass("X11Display");
    if (x11_display_class && __sync_bool_compare_and_swap(&x_events_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(x11_display_class, sel_registerName("postXEvent:"));
        if (method) {
            orig_post_x_event = (void (*)(id, SEL, void*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_post_x_event);
            write_str("[MacOBlox] Hooked X11Display postXEvent: (motion compression)\n");
        }
    }
    static volatile int subwindow_hooked;
    Class x11_subwindow_class = objc_getClass("X11SubWindow");
    if (x11_subwindow_class && __sync_bool_compare_and_swap(&subwindow_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_subwindow_class, sel_registerName("initWithParentWindow:frame:"));
        if (method) {
            orig_x11_subwindow_init =
                (id (*)(id, SEL, id, MacOBloxRect))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_subwindow_init);
            write_str("[MacOBlox] Hooked X11SubWindow initWithParentWindow:frame: (GL visual)\n");
        }
    }
    Class x11_cursor_class = objc_getClass("X11Cursor");
    if (x11_cursor_class &&
        __sync_bool_compare_and_swap(&cursor_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_cursor_class, sel_registerName("initWithImage:hotPoint:"));
        if (method) {
            orig_x11_cursor_init_image =
                (id (*)(id, SEL, id, MacOBloxPoint))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_cursor_init_image);
            write_str("[MacOBlox] Replaced X11Cursor initWithImage:hotPoint: (row copy fix)\n");
        }
    }
    static volatile int monitors_hooked;
    Class event_class_for_monitors = objc_getClass("NSEvent");
    Class application_class = objc_getClass("NSApplication");
    if (event_class_for_monitors && application_class &&
        __sync_bool_compare_and_swap(&monitors_hooked, 0, 1)) {
        Method add = class_getClassMethod(
            event_class_for_monitors,
            sel_registerName("addLocalMonitorForEventsMatchingMask:handler:"));
        Method remove = class_getClassMethod(
            event_class_for_monitors, sel_registerName("removeMonitor:"));
        Method send = class_getInstanceMethod(
            application_class, sel_registerName("sendEvent:"));
        if (add && remove && send) {
            method_setImplementation(add, (IMP)event_add_local_monitor);
            method_setImplementation(remove, (IMP)event_remove_monitor);
            orig_app_send_event =
                (void (*)(id, SEL, id))method_getImplementation(send);
            method_setImplementation(send, (IMP)hooked_app_send_event);
            write_str("[MacOBlox] Implemented NSEvent local event monitors\n");
        }
        Method accepts = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("acceptsMouseMovedEvents"));
        if (accepts) {
            orig_window_accepts_mouse_moved =
                (MacOBloxBool (*)(id, SEL))method_getImplementation(accepts);
            method_setImplementation(accepts, (IMP)hooked_window_accepts_mouse_moved);
            write_str("[MacOBlox] RBXWindow always accepts mouse-moved events\n");
        }
    }
    static volatile int button_number_hooked;
    Class mouse_event_class = objc_getClass("NSEvent_mouse");
    if (mouse_event_class &&
        __sync_bool_compare_and_swap(&button_number_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            mouse_event_class, sel_registerName("buttonNumber"));
        if (method) {
            orig_mouse_event_button_number =
                (long (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_button_number);
            write_str("[MacOBlox] NSEvent buttonNumber uses macOS numbering\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaX"));
        if (method) {
            orig_mouse_event_delta_x =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_x);
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaY"));
        if (method) {
            orig_mouse_event_delta_y =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_y);
            write_str("[MacOBlox] NSEvent motion deltaY uses macOS sign\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("locationInWindow"));
        if (method) {
            orig_event_location_in_window =
                (MacOBloxPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_location_in_window);
        }
        method = class_getInstanceMethod(objc_getClass("NSWindow"),
                                         sel_registerName("mouseLocationOutsideOfEventStream"));
        if (method) {
            orig_window_mouse_location =
                (MacOBloxPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_mouse_location);
        }
        method = class_getClassMethod(objc_getClass("NSEvent"), sel_registerName("mouseLocation"));
        if (method) {
            orig_event_mouse_location =
                (MacOBloxPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_mouse_location);
        }
        write_str("[MacOBlox] Mouse location freezes during mouse lock\n");
    }
    static volatile int text_input_added;
    Class text_view_class = objc_getClass("NSTextView");
    if (text_view_class &&
        __sync_bool_compare_and_swap(&text_input_added, 0, 1)) {
        struct { const char* name; IMP imp; const char* types; } methods[] = {
            {"hasMarkedText", (IMP)text_view_has_marked_text, "c@:"},
            {"markedRange", (IMP)text_view_marked_range, "{_NSRange=QQ}@:"},
            {"unmarkText", (IMP)text_view_unmark_text, "v@:"},
            {"validAttributesForMarkedText", (IMP)text_view_valid_marked_attributes, "@@:"},
            {"attributedSubstringForProposedRange:actualRange:",
             (IMP)text_view_attributed_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}"},
        };
        for (unsigned long index = 0; index < sizeof(methods) / sizeof(methods[0]); index++) {
            SEL selector = sel_registerName(methods[index].name);
            if (!class_getInstanceMethod(text_view_class, selector) &&
                class_addMethod(text_view_class, selector, methods[index].imp,
                                methods[index].types)) {
                write_str("[MacOBlox] Added NSTextView ");
                write_str(methods[index].name);
                write_str("\n");
            }
        }
    }
    static volatile int constructors_added;
    if (__sync_bool_compare_and_swap(&constructors_added, 0, 1)) {
        Class button_meta = object_getClass((id)objc_getClass("NSButton"));
        Class text_field_meta = object_getClass((id)objc_getClass("NSTextField"));
        SEL button_selector = sel_registerName("buttonWithImage:target:action:");
        SEL label_selector = sel_registerName("labelWithString:");
        if (button_meta && !class_getInstanceMethod(button_meta, button_selector) &&
            class_addMethod(button_meta, button_selector,
                            (IMP)button_with_image_target_action, "@@:@@:"))
            write_str("[MacOBlox] Added +[NSButton buttonWithImage:target:action:]\n");
        if (text_field_meta && !class_getInstanceMethod(text_field_meta, label_selector) &&
            class_addMethod(text_field_meta, label_selector,
                            (IMP)text_field_label_with_string, "@@:@"))
            write_str("[MacOBlox] Added +[NSTextField labelWithString:]\n");
    }
    static volatile int contacts_added;
    Class contact_store_class = objc_getClass("CNContactStore");
    if (contact_store_class &&
        __sync_bool_compare_and_swap(&contacts_added, 0, 1)) {
        Class contact_store_meta = object_getClass((id)contact_store_class);
        SEL status = sel_registerName("authorizationStatusForEntityType:");
        SEL request = sel_registerName("requestAccessForEntityType:completionHandler:");
        if (!class_getInstanceMethod(contact_store_meta, status) &&
            class_addMethod(contact_store_meta, status,
                            (IMP)contact_store_authorization_denied, "q@:q"))
            write_str("[MacOBlox] Added CNContactStore authorization (denied)\n");
        if (!class_getInstanceMethod(contact_store_class, request))
            class_addMethod(contact_store_class, request,
                            (IMP)contact_store_request_access, "v@:q@?");
    }
    static volatile int pixel_format_hooked;
    Class pixel_format_class = objc_getClass("NSOpenGLPixelFormat");
    if (pixel_format_class && __sync_bool_compare_and_swap(&pixel_format_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(pixel_format_class, sel_registerName("initWithAttributes:"));
        if (method) {
            orig_pixel_format_init = (id (*)(id, SEL, const unsigned int*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_pixel_format_init);
        }
    }
    static volatile int web_hooked;
    Class web_view_class = objc_getClass("WKWebView");
    Class workspace_class = objc_getClass("NSWorkspace");
    if (web_view_class && workspace_class &&
        __sync_bool_compare_and_swap(&web_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            web_view_class, sel_registerName("initWithFrame:configuration:"));
        if (method) {
            orig_web_view_init = (id (*)(id, SEL, MacOBloxRect, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_init);
        }
        method = class_getInstanceMethod(web_view_class, sel_registerName("loadRequest:"));
        if (method) {
            orig_web_view_load_request = (id (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_load_request);
        }
        method = class_getInstanceMethod(workspace_class, sel_registerName("openURL:"));
        if (method) {
            orig_workspace_open_url = (MacOBloxBool (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_workspace_open_url);
        }
        write_str("[MacOBlox] Tracing WKWebView and NSWorkspace openURL:\n");
    }
    Class window_class = objc_getClass("NSWindow");
    if (window_class &&
        __sync_bool_compare_and_swap(&window_events_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            window_class, sel_registerName("sendEvent:"));
        if (method) {
            orig_window_send_event =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_send_event);
        }
    }
}

// A direct executable launch has no Apple Event. Darling lacks this selector;
// its generic forwarding path otherwise leaves an invalid object return value.
static id no_current_apple_event(id self, SEL cmd) { (void)self; (void)cmd; return 0; }

// Added in newer Foundation versions than Darling currently implements.
// Build relative file URLs using the older URL and NSString APIs that Darling
// does provide.
static id url_file_with_path_relative_to_url(id cls, SEL cmd, id path, id base_url) {
    (void)cmd;
    if (!path)
        return 0;

    signed char is_absolute = ((signed char (*)(id, SEL))objc_msgSend)(
        path, sel_registerName("isAbsolutePath"));
    if (!base_url || is_absolute)
        return ((id (*)(id, SEL, id))objc_msgSend)(
            cls, sel_registerName("fileURLWithPath:"), path);

    id base_path = ((id (*)(id, SEL))objc_msgSend)(base_url, sel_registerName("path"));
    id combined_path = base_path
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              base_path, sel_registerName("stringByAppendingPathComponent:"), path)
        : path;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, sel_registerName("fileURLWithPath:"), combined_path);
}

static int ascii_contains_case_insensitive(const char* text, const char* needle) {
    if (!text || !needle || !*needle)
        return 0;
    for (const char* start = text; *start; start++) {
        const char* a = start;
        const char* b = needle;
        while (*a && *b) {
            char ca = (*a >= 'A' && *a <= 'Z') ? *a + ('a' - 'A') : *a;
            char cb = (*b >= 'A' && *b <= 'Z') ? *b + ('a' - 'A') : *b;
            if (ca != cb)
                break;
            a++;
            b++;
        }
        if (!*b)
            return 1;
    }
    return 0;
}

// Cookies. Roblox on macOS keeps the login (.ROBLOSECURITY) in
// NSHTTPCookieStorage. Darling's CFNetwork cookie parser crashes on a valid
// host-only Set-Cookie (it copies a missing Domain), and its cookie storage
// lives only in memory. So Set-Cookie headers are parsed here, cookies are
// built with +[NSHTTPCookie cookieWithProperties:] (Domain always set), and
// persistent cookies are saved to
// ~/Library/MacOBlox/Cookies.plist (mode 0600) and loaded
// back at startup.
#define MSG0(r, o, sel) ((r (*)(id, SEL))objc_msgSend)((id)(o), sel_registerName(sel))
#define MSG1(r, o, sel, a) ((r (*)(id, SEL, id))objc_msgSend)((id)(o), sel_registerName(sel), (a))
#define MSG2(r, o, sel, a, b) ((r (*)(id, SEL, id, id))objc_msgSend)((id)(o), sel_registerName(sel), (a), (b))
static id macoblox_nsstring(const char* text) {
    return ((id (*)(id, SEL, const char*))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), text);
}
static id macoblox_trimmed(id string) {
    id whitespace = MSG0(id, objc_getClass("NSCharacterSet"), "whitespaceAndNewlineCharacterSet");
    return MSG1(id, string, "stringByTrimmingCharactersInSet:", whitespace);
}
static id macoblox_cf_boolean(int value) {
    return ((id (*)(id, SEL, MacOBloxBool))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), (MacOBloxBool)(value != 0));
}

static id macoblox_http_date(id text) {
    id formatter = MSG0(id, MSG0(id, objc_getClass("NSDateFormatter"), "alloc"), "init");
    MSG1(void, formatter, "setLocale:",
         MSG1(id, objc_getClass("NSLocale"), "localeWithLocaleIdentifier:", macoblox_nsstring("en_US_POSIX")));
    MSG1(void, formatter, "setTimeZone:",
         MSG1(id, objc_getClass("NSTimeZone"), "timeZoneWithAbbreviation:", macoblox_nsstring("GMT")));
    static const char* formats[] = {"EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                    "EEE, dd-MMM-yy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"};
    id date = 0;
    for (int index = 0; index < 4 && !date; index++) {
        MSG1(void, formatter, "setDateFormat:", macoblox_nsstring(formats[index]));
        date = MSG1(id, formatter, "dateFromString:", text);
    }
    MSG0(void, formatter, "release");
    return date;
}

// Build one NSHTTPCookie from a single "name=value; attr; attr=value" string.
static id macoblox_cookie_from_string(id line, id url) {
    id parts = MSG1(id, line, "componentsSeparatedByString:", macoblox_nsstring(";"));
    unsigned long count = MSG0(unsigned long, parts, "count");
    if (!count)
        return 0;
    id first = macoblox_trimmed(MSG1(id, parts, "objectAtIndex:", (id)0));
    unsigned long equals = ((MacOBloxRange (*)(id, SEL, id))objc_msgSend)(
        first, sel_registerName("rangeOfString:"), macoblox_nsstring("=")).location;
    if (equals == 0x7FFFFFFFFFFFFFFFUL || equals == 0)
        return 0;
    id properties = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
    MSG2(void, properties, "setObject:forKey:",
         macoblox_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringToIndex:"), equals)),
         macoblox_nsstring("Name"));
    MSG2(void, properties, "setObject:forKey:",
         ((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringFromIndex:"), equals + 1),
         macoblox_nsstring("Value"));
    id host = url ? MSG0(id, url, "host") : 0;
    MSG2(void, properties, "setObject:forKey:", host ? host : macoblox_nsstring("roblox.com"),
         macoblox_nsstring("Domain"));
    MSG2(void, properties, "setObject:forKey:", macoblox_nsstring("/"), macoblox_nsstring("Path"));
    // Darling's CFHTTPCookieIsSecure reads Secure with CFBooleanGetValue and
    // crashes when it is missing, so it is always set, as a CFBoolean.
    MSG2(void, properties, "setObject:forKey:", macoblox_cf_boolean(0), macoblox_nsstring("Secure"));
    for (unsigned long index = 1; index < count; index++) {
        id attribute = macoblox_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
            parts, sel_registerName("objectAtIndex:"), index));
        unsigned long split = ((MacOBloxRange (*)(id, SEL, id))objc_msgSend)(
            attribute, sel_registerName("rangeOfString:"), macoblox_nsstring("=")).location;
        id key = split == 0x7FFFFFFFFFFFFFFFUL ? attribute
            : ((id (*)(id, SEL, unsigned long))objc_msgSend)(attribute, sel_registerName("substringToIndex:"), split);
        id value = split == 0x7FFFFFFFFFFFFFFFUL ? macoblox_nsstring("")
            : macoblox_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
                  attribute, sel_registerName("substringFromIndex:"), split + 1));
        const char* name = MSG0(const char*, MSG0(id, macoblox_trimmed(key), "lowercaseString"), "UTF8String");
        if (!name)
            continue;
        if (ascii_strings_equal(name, "domain") && MSG0(unsigned long, value, "length")) {
            MSG2(void, properties, "setObject:forKey:", value, macoblox_nsstring("Domain"));
        } else if (ascii_strings_equal(name, "path") && MSG0(unsigned long, value, "length")) {
            MSG2(void, properties, "setObject:forKey:", value, macoblox_nsstring("Path"));
        } else if (ascii_strings_equal(name, "expires")) {
            id date = macoblox_http_date(value);
            if (date && !MSG1(id, properties, "objectForKey:", macoblox_nsstring("Max-Age")))
                MSG2(void, properties, "setObject:forKey:", date, macoblox_nsstring("Expires"));
        } else if (ascii_strings_equal(name, "max-age")) {
            double seconds = MSG0(double, value, "doubleValue");
            id date = ((id (*)(id, SEL, double))objc_msgSend)(
                (id)objc_getClass("NSDate"), sel_registerName("dateWithTimeIntervalSinceNow:"), seconds);
            MSG2(void, properties, "setObject:forKey:", date, macoblox_nsstring("Expires"));
            MSG2(void, properties, "setObject:forKey:", value, macoblox_nsstring("Max-Age"));
        } else if (ascii_strings_equal(name, "secure")) {
            MSG2(void, properties, "setObject:forKey:", macoblox_cf_boolean(1), macoblox_nsstring("Secure"));
        }
    }
    MSG1(void, properties, "removeObjectForKey:", macoblox_nsstring("Max-Age"));
    return MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", properties);
}

// Split a combined Set-Cookie header ("a=1; Expires=Wed, 21 Oct ...,b=2")
// at commas that start a new "name=" pair, not at commas inside dates.
static id macoblox_split_set_cookie(id header) {
    id result = MSG0(id, objc_getClass("NSMutableArray"), "array");
    const char* text = MSG0(const char*, header, "UTF8String");
    if (!text)
        return result;
    unsigned long start = 0, length = 0;
    while (text[length]) length++;
    for (unsigned long index = 0; index <= length; index++) {
        int boundary = index == length;
        if (!boundary && text[index] == ',') {
            unsigned long probe = index + 1;
            while (text[probe] == ' ') probe++;
            unsigned long name_end = probe;
            while (text[name_end] && text[name_end] != '=' && text[name_end] != ';' &&
                   text[name_end] != ',' && text[name_end] != ' ')
                name_end++;
            boundary = name_end > probe && text[name_end] == '=';
        }
        if (boundary) {
            if (index > start) {
                id piece = ((id (*)(id, SEL, const void*, unsigned long, unsigned long))objc_msgSend)(
                    MSG0(id, objc_getClass("NSString"), "alloc"),
                    sel_registerName("initWithBytes:length:encoding:"), text + start, index - start, 4UL);
                MSG1(void, result, "addObject:", piece);
                MSG0(void, piece, "release");
            }
            start = index + 1;
        }
    }
    return result;
}

static id (*orig_cookies_with_response_headers)(id, SEL, id, id) = 0;
static id cookies_with_response_headers(id cls, SEL cmd, id headers, id url) {
    (void)cls; (void)cmd;
    id cookies = MSG0(id, objc_getClass("NSMutableArray"), "array");
    id keys = headers ? MSG0(id, headers, "allKeys") : 0;
    unsigned long count = keys ? MSG0(unsigned long, keys, "count") : 0;
    for (unsigned long index = 0; index < count; index++) {
        id key = ((id (*)(id, SEL, unsigned long))objc_msgSend)(keys, sel_registerName("objectAtIndex:"), index);
        const char* key_text = key ? MSG0(const char*, key, "UTF8String") : 0;
        if (!key_text || !ascii_contains_case_insensitive(key_text, "set-cookie"))
            continue;
        id value = MSG1(id, headers, "objectForKey:", key);
        id lines = MSG1(MacOBloxBool, value, "isKindOfClass:", (id)objc_getClass("NSArray"))
            ? value : macoblox_split_set_cookie(value);
        unsigned long line_count = MSG0(unsigned long, lines, "count");
        for (unsigned long line = 0; line < line_count; line++) {
            id cookie = macoblox_cookie_from_string(
                ((id (*)(id, SEL, unsigned long))objc_msgSend)(lines, sel_registerName("objectAtIndex:"), line), url);
            if (cookie)
                MSG1(void, cookies, "addObject:", cookie);
        }
    }
    return cookies;
}

static id macoblox_cookie_file(void) {
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    id directory = MSG1(id, home, "stringByAppendingPathComponent:",
                        macoblox_nsstring("Library/MacOBlox"));
    ((MacOBloxBool (*)(id, SEL, id, MacOBloxBool, id, id*))objc_msgSend)(
        MSG0(id, objc_getClass("NSFileManager"), "defaultManager"),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    return MSG1(id, directory, "stringByAppendingPathComponent:", macoblox_nsstring("Cookies.plist"));
}

static volatile int macoblox_loading_cookies;
// Persistent cookies as Roblox hands them to NSHTTPCookieStorage, keyed by
// domain|path|name. Darling's storage cannot be read back for this: in
// Roblox's process it kept none of them, so the login was never saved.
static id macoblox_saved_cookies;

static id macoblox_cookie_key(id domain, id path, id name) {
    return ((id (*)(id, SEL, id, ...))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithFormat:"),
        macoblox_nsstring("%@|%@|%@"), domain ? domain : macoblox_nsstring(""),
        path ? path : macoblox_nsstring("/"), name ? name : macoblox_nsstring(""));
}

static void macoblox_write_saved_cookies(void) {
    id file = macoblox_cookie_file();
    id entries = MSG0(id, macoblox_saved_cookies, "allValues");
    ((MacOBloxBool (*)(id, SEL, id, MacOBloxBool))objc_msgSend)(
        entries, sel_registerName("writeToFile:atomically:"), file, 0); // Darling leaves atomic writes as .tmpN files
    chmod(MSG0(const char*, file, "fileSystemRepresentation"), 0600);
}

static void macoblox_remember_cookie(id cookie, int deleted) {
    if (!cookie || macoblox_loading_cookies)
        return;
    if (!macoblox_saved_cookies)
        macoblox_saved_cookies = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
    id name = MSG0(id, cookie, "name");
    id domain = MSG0(id, cookie, "domain");
    id path = MSG0(id, cookie, "path");
    id key = macoblox_cookie_key(domain, path, name);
    id expires = MSG0(id, cookie, "expiresDate");
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    int persistent = expires && MSG1(long, expires, "compare:", now) == 1;
    write_str("[MacOBlox Cookies] ");
    write_str(deleted ? "delete " : "set ");
    write_str(name ? MSG0(const char*, name, "UTF8String") : "?");
    write_str(" domain=");
    write_str(domain ? MSG0(const char*, domain, "UTF8String") : "?");
    write_str(deleted ? "\n" : (persistent ? " persistent\n" : " session\n"));
    if (deleted || !persistent) {
        MSG1(void, macoblox_saved_cookies, "removeObjectForKey:", key);
    } else {
        id entry = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
        MSG2(void, entry, "setObject:forKey:", name, macoblox_nsstring("Name"));
        MSG2(void, entry, "setObject:forKey:", MSG0(id, cookie, "value"), macoblox_nsstring("Value"));
        MSG2(void, entry, "setObject:forKey:", domain, macoblox_nsstring("Domain"));
        MSG2(void, entry, "setObject:forKey:", path ? path : macoblox_nsstring("/"), macoblox_nsstring("Path"));
        MSG2(void, entry, "setObject:forKey:", expires, macoblox_nsstring("Expires"));
        id properties = MSG0(id, cookie, "properties");
        id secure = properties ? MSG1(id, properties, "objectForKey:", macoblox_nsstring("Secure")) : 0;
        int is_secure = secure && MSG1(MacOBloxBool, secure, "respondsToSelector:", (id)sel_registerName("boolValue"))
            && MSG0(MacOBloxBool, secure, "boolValue");
        MSG2(void, entry, "setObject:forKey:", macoblox_cf_boolean(is_secure), macoblox_nsstring("Secure"));
        MSG2(void, macoblox_saved_cookies, "setObject:forKey:", entry, key);
    }
    macoblox_write_saved_cookies();
}

static void (*orig_cookie_storage_set)(id, SEL, id) = 0;
static void hooked_cookie_storage_set(id self, SEL cmd, id cookie) {
    orig_cookie_storage_set(self, cmd, cookie);
    macoblox_remember_cookie(cookie, 0);
}
static void (*orig_cookie_storage_set_many)(id, SEL, id, id, id) = 0;
static void hooked_cookie_storage_set_many(id self, SEL cmd, id cookies, id url, id main_url) {
    orig_cookie_storage_set_many(self, cmd, cookies, url, main_url);
    unsigned long count = cookies ? MSG0(unsigned long, cookies, "count") : 0;
    for (unsigned long index = 0; index < count; index++)
        macoblox_remember_cookie(((id (*)(id, SEL, unsigned long))objc_msgSend)(
            cookies, sel_registerName("objectAtIndex:"), index), 0);
}
static void (*orig_cookie_storage_delete)(id, SEL, id) = 0;
static void hooked_cookie_storage_delete(id self, SEL cmd, id cookie) {
    orig_cookie_storage_delete(self, cmd, cookie);
    macoblox_remember_cookie(cookie, 1);
}

// Requests ask cookiesForURL:; add saved cookies that match the URL in case
// Darling's storage dropped them (it keeps none of Roblox's in practice).
static id (*orig_cookie_storage_for_url)(id, SEL, id) = 0;
static id hooked_cookie_storage_for_url(id self, SEL cmd, id url) {
    id result = orig_cookie_storage_for_url(self, cmd, url);
    if (!macoblox_saved_cookies || !url)
        return result;
    id host = MSG0(id, MSG0(id, url, "host"), "lowercaseString");
    id url_path = MSG0(id, url, "path");
    if (!host)
        return result;
    int https = MSG1(MacOBloxBool, MSG0(id, MSG0(id, url, "scheme"), "lowercaseString"),
                     "isEqualToString:", macoblox_nsstring("https"));
    id merged = result ? MSG0(id, result, "mutableCopy") : MSG0(id, MSG0(id, objc_getClass("NSMutableArray"), "alloc"), "init");
    id present = MSG0(id, MSG0(id, objc_getClass("NSMutableSet"), "alloc"), "init");
    unsigned long count = MSG0(unsigned long, merged, "count");
    for (unsigned long index = 0; index < count; index++) {
        id cookie = ((id (*)(id, SEL, unsigned long))objc_msgSend)(merged, sel_registerName("objectAtIndex:"), index);
        MSG1(void, present, "addObject:", MSG0(id, cookie, "name"));
    }
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    id entries = MSG0(id, macoblox_saved_cookies, "allValues");
    unsigned long entry_count = MSG0(unsigned long, entries, "count");
    for (unsigned long index = 0; index < entry_count; index++) {
        id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
        id name = MSG1(id, entry, "objectForKey:", macoblox_nsstring("Name"));
        if (MSG1(MacOBloxBool, present, "containsObject:", name))
            continue;
        id expires = MSG1(id, entry, "objectForKey:", macoblox_nsstring("Expires"));
        if (expires && MSG1(long, expires, "compare:", now) != 1)
            continue;
        id domain = MSG0(id, MSG1(id, entry, "objectForKey:", macoblox_nsstring("Domain")), "lowercaseString");
        id bare = MSG1(MacOBloxBool, domain, "hasPrefix:", macoblox_nsstring("."))
            ? ((id (*)(id, SEL, unsigned long))objc_msgSend)(domain, sel_registerName("substringFromIndex:"), 1)
            : domain;
        int domain_match = MSG1(MacOBloxBool, host, "isEqualToString:", bare) ||
            MSG1(MacOBloxBool, host, "hasSuffix:",
                 MSG1(id, macoblox_nsstring("."), "stringByAppendingString:", bare));
        id path = MSG1(id, entry, "objectForKey:", macoblox_nsstring("Path"));
        int path_match = !path || !url_path || !MSG0(unsigned long, url_path, "length") ||
            MSG1(MacOBloxBool, url_path, "hasPrefix:", path);
        id secure = MSG1(id, entry, "objectForKey:", macoblox_nsstring("Secure"));
        int needs_https = secure && MSG0(MacOBloxBool, secure, "boolValue");
        if (!domain_match || !path_match || (needs_https && !https))
            continue;
        id cookie = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
        if (cookie) {
            MSG1(void, merged, "addObject:", cookie);
            MSG1(void, present, "addObject:", name);
        }
    }
    MSG0(void, present, "release");
    return MSG0(id, merged, "autorelease");
}

static void macoblox_load_cookies(void) {
    id storage = MSG0(id, objc_getClass("NSHTTPCookieStorage"), "sharedHTTPCookieStorage");
    id entries = MSG1(id, objc_getClass("NSArray"), "arrayWithContentsOfFile:", macoblox_cookie_file());
    unsigned long count = entries ? MSG0(unsigned long, entries, "count") : 0;
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    int loaded = 0;
    macoblox_loading_cookies = 1;
    for (unsigned long index = 0; index < count; index++) {
        id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
        id expires = MSG1(id, entry, "objectForKey:", macoblox_nsstring("Expires"));
        if (expires && MSG1(long, expires, "compare:", now) != 1 /* NSOrderedDescending */)
            continue;
        id cookie = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
        if (cookie) {
            MSG1(void, storage, "setCookie:", cookie);
            if (!macoblox_saved_cookies)
                macoblox_saved_cookies = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
            MSG2(void, macoblox_saved_cookies, "setObject:forKey:", entry,
                 macoblox_cookie_key(MSG1(id, entry, "objectForKey:", macoblox_nsstring("Domain")),
                                     MSG1(id, entry, "objectForKey:", macoblox_nsstring("Path")),
                                     MSG1(id, entry, "objectForKey:", macoblox_nsstring("Name"))));
            loaded++;
        }
    }
    macoblox_loading_cookies = 0;
    write_str("[MacOBlox Cookies] loaded ");
    print_num(loaded);
    write_str(" saved cookies\n");
}

// Cocotron stores NSDisplay in thread-local state. Its X11 backend cannot open
// a second display for Roblox's rendering worker, although the main thread's
// display is already valid. Share the first successfully created display.
static id (*orig_current_display)(id, SEL) = 0;
static id macoblox_shared_display;
static volatile int macoblox_display_lock;
static id shared_current_display(id cls, SEL cmd) {
    if (macoblox_shared_display)
        return macoblox_shared_display;
    while (__sync_lock_test_and_set(&macoblox_display_lock, 1))
        usleep(1000);
    if (!macoblox_shared_display) {
        id display = orig_current_display(cls, cmd);
        if (display)
            macoblox_shared_display = ((id (*)(id, SEL))objc_msgSend)(
                display, sel_registerName("retain"));
    }
    __sync_lock_release(&macoblox_display_lock);
    return macoblox_shared_display;
}

__attribute__((constructor))
static void install_swizzles(void) {
    write_str("[MacOBlox] libMacOBloxShims loaded.\n");
    long slide = _dyld_get_image_vmaddr_slide(0);
    write_str("[MacOBlox] Main executable ASLR slide: ");
    print_hex(slide);
    write_str("\n");

    // Let Darling and Crashpad own signals unless diagnosis is explicitly requested.
    const char *diagnose_signals = getenv("MACOBLOX_DIAGNOSTIC_SIGNALS");
    if (diagnose_signals && *diagnose_signals == '1') {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        sigaction(11, &debug_action, 0);
    }

    Class eventManager = objc_getClass("NSAppleEventManager");
    SEL currentEvent = sel_registerName("currentAppleEvent");
    if (eventManager && !class_getInstanceMethod(eventManager, currentEvent)) {
        class_addMethod(eventManager, currentEvent, (IMP)no_current_apple_event, "@@:");
        write_str("[MacOBlox] Added currentAppleEvent=nil for direct launch\n");
    }

    Class url_class = objc_getClass("NSURL");
    SEL relative_file_url = sel_registerName("fileURLWithPath:relativeToURL:");
    if (url_class && !class_getClassMethod(url_class, relative_file_url)) {
        Class url_meta_class = object_getClass((id)url_class);
        if (url_meta_class && class_addMethod(url_meta_class, relative_file_url,
                                              (IMP)url_file_with_path_relative_to_url,
                                              "@@:@@"))
            write_str("[MacOBlox] Added NSURL fileURLWithPath:relativeToURL:\n");
    }

    Class event_class = objc_getClass("NSEvent");
    if (event_class) {
        SEL phase = sel_registerName("phase");
        SEL momentum_phase = sel_registerName("momentumPhase");
        if (!class_getInstanceMethod(event_class, phase) &&
            class_addMethod(event_class, phase, (IMP)event_phase_none, "Q@:"))
            write_str("[MacOBlox] Added NSEvent phase=None\n");
        if (!class_getInstanceMethod(event_class, momentum_phase) &&
            class_addMethod(event_class, momentum_phase,
                            (IMP)event_phase_none, "Q@:"))
            write_str("[MacOBlox] Added NSEvent momentumPhase=None\n");
    }

    Class process_info_class = objc_getClass("NSProcessInfo");
    if (process_info_class) {
        SEL thermal_state = sel_registerName("thermalState");
        SEL low_power = sel_registerName("isLowPowerModeEnabled");
        if (!class_getInstanceMethod(process_info_class, thermal_state) &&
            class_addMethod(process_info_class, thermal_state,
                            (IMP)process_info_thermal_state_nominal, "q@:"))
            write_str("[MacOBlox] Added NSProcessInfo thermalState=nominal\n");
        if (!class_getInstanceMethod(process_info_class, low_power) &&
            class_addMethod(process_info_class, low_power,
                            (IMP)process_info_low_power_mode_disabled, "B@:"))
            write_str("[MacOBlox] Added NSProcessInfo lowPowerMode=false\n");
    }

    Class gl_context_class = objc_getClass("NSOpenGLContext");
    if (gl_context_class) {
        Method method = class_getInstanceMethod(
            gl_context_class, sel_registerName("initWithFormat:shareContext:"));
        if (method) {
            orig_gl_context_init =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_init);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("setView:"));
        if (method) {
            orig_gl_context_set_view =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_set_view);
        }
        method = class_getInstanceMethod(
            gl_context_class, sel_registerName("makeCurrentContext"));
        if (method) {
            orig_gl_context_make_current =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_make_current);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("flushBuffer"));
        if (method) {
            orig_gl_context_flush =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_flush);
        }
        write_str("[MacOBlox] Tracing NSOpenGLContext drawable presentation\n");
    }

    Class layer_context_class = objc_getClass("CALayerContext");
    if (layer_context_class) {
        Method method = class_getInstanceMethod(
            layer_context_class, sel_registerName("renderLayer:"));
        if (method) {
            orig_layer_context_render_layer =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_layer_context_render_layer);
            write_str("[MacOBlox] Hooked CALayerContext renderLayer: (restores GL context)\n");
        }
    }

    Class scroll_event_class = objc_getClass("NSEvent");
    if (scroll_event_class) {
        struct { const char* name; IMP imp; const char* types; } event_methods[] = {
            {"hasPreciseScrollingDeltas", (IMP)event_has_precise_scrolling_deltas, "c@:"},
            {"isDirectionInvertedFromDevice", (IMP)event_is_direction_inverted, "c@:"},
            {"scrollingDeltaX", (IMP)event_scrolling_delta_x, "d@:"},
            {"scrollingDeltaY", (IMP)event_scrolling_delta_y, "d@:"},
        };
        for (unsigned long index = 0;
             index < sizeof(event_methods) / sizeof(event_methods[0]); index++) {
            SEL selector = sel_registerName(event_methods[index].name);
            if (!class_getInstanceMethod(scroll_event_class, selector) &&
                class_addMethod(scroll_event_class, selector, event_methods[index].imp,
                                event_methods[index].types)) {
                write_str("[MacOBlox] Added NSEvent ");
                write_str(event_methods[index].name);
                write_str("\n");
            }
        }
    }

    macoblox_install_late_hooks();

    Class archiver_meta = object_getClass((id)objc_getClass("NSKeyedArchiver"));
    Class unarchiver_meta = object_getClass((id)objc_getClass("NSKeyedUnarchiver"));
    SEL archive = sel_registerName("archivedDataWithRootObject:requiringSecureCoding:error:");
    SEL unarchive = sel_registerName("unarchivedObjectOfClass:fromData:error:");
    if (archiver_meta && !class_getInstanceMethod(archiver_meta, archive) &&
        class_addMethod(archiver_meta, archive, (IMP)keyed_archiver_archived_data, "@@:@c^@"))
        write_str("[MacOBlox] Added +[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:]\n");
    if (unarchiver_meta && !class_getInstanceMethod(unarchiver_meta, unarchive) &&
        class_addMethod(unarchiver_meta, unarchive, (IMP)keyed_unarchiver_unarchived_object, "@@:#@^@"))
        write_str("[MacOBlox] Added +[NSKeyedUnarchiver unarchivedObjectOfClass:fromData:error:]\n");

    const char* hide_menu = getenv("MACOBLOX_HIDE_MENU_BAR");
    Class menu_view_class = objc_getClass("NSMainMenuView");
    if (hide_menu && hide_menu[0] == '1' && menu_view_class) {
        Method method = class_getClassMethod(menu_view_class, sel_registerName("menuHeight"));
        if (method) {
            method_setImplementation(method, (IMP)macoblox_zero_menu_height);
            write_str("[MacOBlox] Menu bar hidden\n");
        }
    }

    Class cookie_class = objc_getClass("NSHTTPCookie");
    if (cookie_class) {
        SEL parse_cookies = sel_registerName("cookiesWithResponseHeaderFields:forURL:");
        Method method = class_getClassMethod(cookie_class, parse_cookies);
        if (method) {
            orig_cookies_with_response_headers =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)cookies_with_response_headers);
            write_str("[MacOBlox] Hooked NSHTTPCookie response parser\n");
        }
        Class storage_class = objc_getClass("NSHTTPCookieStorage");
        Method set_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("setCookie:")) : 0;
        Method delete_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("deleteCookie:")) : 0;
        if (set_method && delete_method) {
            orig_cookie_storage_set = (void (*)(id, SEL, id))method_getImplementation(set_method);
            method_setImplementation(set_method, (IMP)hooked_cookie_storage_set);
            orig_cookie_storage_delete = (void (*)(id, SEL, id))method_getImplementation(delete_method);
            method_setImplementation(delete_method, (IMP)hooked_cookie_storage_delete);
            Method for_url = class_getInstanceMethod(storage_class, sel_registerName("cookiesForURL:"));
            if (for_url) {
                orig_cookie_storage_for_url = (id (*)(id, SEL, id))method_getImplementation(for_url);
                method_setImplementation(for_url, (IMP)hooked_cookie_storage_for_url);
            }
            Method set_many = class_getInstanceMethod(
                storage_class, sel_registerName("setCookies:forURL:mainDocumentURL:"));
            if (set_many) {
                orig_cookie_storage_set_many =
                    (void (*)(id, SEL, id, id, id))method_getImplementation(set_many);
                method_setImplementation(set_many, (IMP)hooked_cookie_storage_set_many);
            }
            macoblox_load_cookies();
        }
    }

    Class display_class = objc_getClass("NSDisplay");
    if (display_class) {
        SEL current_display = sel_registerName("currentDisplay");
        Method method = class_getClassMethod(display_class, current_display);
        if (method) {
            orig_current_display = (id (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)shared_current_display);
            write_str("[MacOBlox] Sharing NSDisplay across rendering threads\n");
        }
    }

    Class web_preferences_class = objc_getClass("WebPreferences");
    SEL standard_preferences = sel_registerName("standardPreferences");
    if (web_preferences_class &&
        !class_getClassMethod(web_preferences_class, standard_preferences)) {
        Class web_preferences_meta_class = object_getClass((id)web_preferences_class);
        if (web_preferences_meta_class &&
            class_addMethod(web_preferences_meta_class, standard_preferences,
                            (IMP)web_preferences_standard_preferences, "@@:"))
            write_str("[MacOBlox] Added WebPreferences standardPreferences\n");
    }

    Class capture_device_class = objc_getClass("AVCaptureDevice");
    if (capture_device_class) {
        Class capture_device_meta_class = object_getClass((id)capture_device_class);
        SEL devices = sel_registerName("devices");
        SEL devices_for_type = sel_registerName("devicesWithMediaType:");
        SEL default_for_type = sel_registerName("defaultDeviceWithMediaType:");
        if (!class_getClassMethod(capture_device_class, devices) &&
            class_addMethod(capture_device_meta_class, devices,
                            (IMP)empty_capture_devices, "@@:"))
            write_str("[MacOBlox] Added empty AVCaptureDevice devices inventory\n");
        if (!class_getClassMethod(capture_device_class, devices_for_type) &&
            class_addMethod(capture_device_meta_class, devices_for_type,
                            (IMP)empty_capture_devices_for_media_type, "@@:@"))
            write_str("[MacOBlox] Added empty AVCaptureDevice devicesWithMediaType:\n");
        if (!class_getClassMethod(capture_device_class, default_for_type) &&
            class_addMethod(capture_device_meta_class, default_for_type,
                            (IMP)no_default_capture_device, "@@:@"))
            write_str("[MacOBlox] Added AVCaptureDevice defaultDeviceWithMediaType:=nil\n");
    }

    Class layerCls = objc_getClass("CALayer");
    if (layerCls && !class_getInstanceMethod(layerCls, sel_registerName("setContentsScale:"))
                 && !class_getInstanceMethod(layerCls, sel_registerName("contentsScale"))) {
        class_addMethod(layerCls, sel_registerName("setContentsScale:"), (IMP)layer_set_contents_scale, "v@:d");
        class_addMethod(layerCls, sel_registerName("contentsScale"), (IMP)layer_contents_scale, "d@:");
        write_str("[MacOBlox] Added CALayer contentsScale state (1x rendering only)\n");
    }

    Class viewCls = objc_getClass("NSView");
    if (viewCls && !class_getInstanceMethod(viewCls, sel_registerName("setAllowedTouchTypes:"))
                && !class_getInstanceMethod(viewCls, sel_registerName("allowedTouchTypes"))) {
        class_addMethod(viewCls, sel_registerName("setAllowedTouchTypes:"), (IMP)view_set_allowed_touch_types, "v@:Q");
        class_addMethod(viewCls, sel_registerName("allowedTouchTypes"), (IMP)view_allowed_touch_types, "Q@:");
        write_str("[MacOBlox] Added NSView allowedTouchTypes state (no touch synthesis)\n");
    }
    SEL backingSize = sel_registerName("convertSizeToBacking:");
    if (viewCls && !class_getInstanceMethod(viewCls, backingSize)) {
        class_addMethod(viewCls, backingSize, (IMP)backing_size_1x,
                        "{CGSize=dd}@:{CGSize=dd}");
        write_str("[MacOBlox] Added NSView convertSizeToBacking: (experimental 1x)\n");
    }


    Class window_class = objc_getClass("NSWindow");
    if (window_class) {
        SEL rect_from_screen = sel_registerName("convertRectFromScreen:");
        SEL rect_to_screen = sel_registerName("convertRectToScreen:");
        const char* rect_conversion_types =
            "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}";
        if (!class_getInstanceMethod(window_class, rect_from_screen) &&
            class_addMethod(window_class, rect_from_screen,
                            (IMP)window_convert_rect_from_screen,
                            rect_conversion_types))
            write_str("[MacOBlox] Added NSWindow convertRectFromScreen:\n");
        if (!class_getInstanceMethod(window_class, rect_to_screen) &&
            class_addMethod(window_class, rect_to_screen,
                            (IMP)window_convert_rect_to_screen,
                            rect_conversion_types))
            write_str("[MacOBlox] Added NSWindow convertRectToScreen:\n");
    }

    Class ccls = objc_getClass("NSConcreteScanner");
    if (ccls) {
        Method m = class_getInstanceMethod(ccls, sel_registerName("initWithString:"));
        if (m) {
            orig_concrete_initWithString = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_concrete_initWithString);
            write_str("[MacOBlox] Hooked NSConcreteScanner initWithString:\n");
        }
    }

    Class appCls = objc_getClass("NSApplication");
    if (appCls) {
        Method mRun = class_getInstanceMethod(appCls, sel_registerName("run"));
        if (mRun) {
            orig_app_run = (void (*)(id, SEL))method_getImplementation(mRun);
            method_setImplementation(mRun, (IMP)hooked_app_run);
            write_str("[MacOBlox] Hooked NSApplication run\n");
        }
        Method mFinish = class_getInstanceMethod(appCls, sel_registerName("finishLaunching"));
        if (mFinish) {
            orig_app_finish_launching =
                (void (*)(id, SEL))method_getImplementation(mFinish);
            method_setImplementation(mFinish, (IMP)hooked_app_finish_launching);
            write_str("[MacOBlox] Hooked NSApplication finishLaunching\n");
        }
        Method mTerm = class_getInstanceMethod(appCls, sel_registerName("terminate:"));
        if (mTerm) {
            orig_app_terminate = (void (*)(id, SEL, id))method_getImplementation(mTerm);
            method_setImplementation(mTerm, (IMP)hooked_app_terminate);
            write_str("[MacOBlox] Hooked NSApplication terminate:\n");
        }
        Method mDel = class_getInstanceMethod(appCls, sel_registerName("setDelegate:"));
        if (mDel) {
            orig_app_setDelegate = (void (*)(id, SEL, id))method_getImplementation(mDel);
            method_setImplementation(mDel, (IMP)hooked_app_setDelegate);
            write_str("[MacOBlox] Hooked NSApplication setDelegate:\n");
        }
    }

    Class bndlCls = objc_getClass("NSBundle");
    if (bndlCls) {
        Method mNib = class_getClassMethod(bndlCls, sel_registerName("loadNibNamed:owner:"));
        if (mNib) {
            orig_loadNibNamed = (int (*)(id, SEL, id, id))method_getImplementation(mNib);
            method_setImplementation(mNib, (IMP)hooked_loadNibNamed);
            write_str("[MacOBlox] Hooked NSBundle loadNibNamed:owner:\n");
        }
    }

    Class nibCls = objc_getClass("NSNib");
    if (nibCls) {
        Method mInst = class_getInstanceMethod(nibCls, sel_registerName("instantiateNibWithExternalNameTable:"));
        if (mInst) {
            orig_instantiateNib = (int (*)(id, SEL, id))method_getImplementation(mInst);
            method_setImplementation(mInst, (IMP)hooked_instantiateNib);
            write_str("[MacOBlox] Hooked NSNib instantiateNibWithExternalNameTable:\n");
        }
    }

    Class unarchCls = objc_getClass("NSKeyedUnarchiver");
    if (unarchCls) {
        Method m = class_getInstanceMethod(unarchCls, sel_registerName("decodeObjectForKey:"));
        if (m) {
            orig_decodeObjectForKey = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_decodeObjectForKey);
            write_str("[MacOBlox] Hooked NSKeyedUnarchiver decodeObjectForKey:\n");
        }
    }

    Class wtCls = objc_getClass("NSWindowTemplate");
    if (wtCls) {
        Method mWT = class_getInstanceMethod(wtCls, sel_registerName("initWithCoder:"));
        if (mWT) {
            orig_wt_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mWT);
            method_setImplementation(mWT, (IMP)hooked_wt_initWithCoder);
            write_str("[MacOBlox] Hooked NSWindowTemplate initWithCoder:\n");
        }
    }

    Class odCls = objc_getClass("NSIBObjectData");
    if (odCls) {
        Method mOD = class_getInstanceMethod(odCls, sel_registerName("initWithCoder:"));
        if (mOD) {
            orig_od_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mOD);
            method_setImplementation(mOD, (IMP)hooked_od_initWithCoder);
            write_str("[MacOBlox] Hooked NSIBObjectData initWithCoder:\n");
        }
        Method mODE = class_getInstanceMethod(odCls, sel_registerName("establishConnections"));
        if (mODE) {
            orig_od_establish = (void (*)(id, SEL))method_getImplementation(mODE);
            method_setImplementation(mODE, (IMP)hooked_od_establish);
            write_str("[MacOBlox] Hooked NSIBObjectData establishConnections\n");
        }
    }

    Class connCls = objc_getClass("NSNibConnector");
    if (connCls) {
        Method mC = class_getInstanceMethod(connCls, sel_registerName("establishConnection"));
        if (mC) {
            orig_conn_establish = (void (*)(id, SEL))method_getImplementation(mC);
            method_setImplementation(mC, (IMP)hooked_conn_establish);
            write_str("[MacOBlox] Hooked NSNibConnector establishConnection\n");
        }
    }

    Class winCls = objc_getClass("NSWindow");
    if (winCls) {
        Method mW = class_getInstanceMethod(winCls, sel_registerName("initWithContentRect:styleMask:backing:defer:"));
        if (mW) {
            orig_win_init = (id (*)(id, SEL, MacOBloxRect, unsigned long, unsigned long, MacOBloxBool))method_getImplementation(mW);
            method_setImplementation(mW, (IMP)hooked_win_init);
            write_str("[MacOBlox] Hooked NSWindow initWithContentRect:...\n");
        }
    }
}

__attribute__((objc_root_class))
@interface NSObject { Class isa; }
@end

// Foundation Objective-C classes
@interface NSBackgroundActivityScheduler : NSObject @end
@implementation NSBackgroundActivityScheduler @end

// Foundation constants
const void* NSHTTPCookieDomain = @"Domain";
const void* NSHTTPCookieExpires = @"Expires";
const void* NSHTTPCookieName = @"Name";
const void* NSHTTPCookiePath = @"Path";
const void* NSHTTPCookieSecure = @"Secure";
const void* NSHTTPCookieValue = @"Value";
const void* NSHTTPCookieVersion = @"Version";
const void* NSLocalizedDescriptionKey = @"NSLocalizedDescriptionKey";
const void* NSProcessInfoThermalStateDidChangeNotification = @"NSProcessInfoThermalStateDidChangeNotification";
const void* NSProcessInfoPowerStateDidChangeNotification = @"NSProcessInfoPowerStateDidChangeNotification";

// Carbon constants
const void* kTISNotifySelectedKeyboardInputSourceChanged = @"kTISNotifySelectedKeyboardInputSourceChanged";
const void* kTISPropertyInputSourceLanguages = @"kTISPropertyInputSourceLanguages";
const void* kTISPropertyUnicodeKeyLayoutData = @"kTISPropertyUnicodeKeyLayoutData";

// The original Carbon compatibility framework returned NULL for the current
// keyboard source and all of its properties. Roblox copies the Unicode layout
// data during startup, so that placeholder becomes CFDataCreateCopy(NULL) and
// crashes in CFDataGetLength. Keep real Objective-C objects alive for the
// process and interpose the three Text Input Source entry points.
static id macoblox_keyboard_source;
static id macoblox_keyboard_layout_data;
static id macoblox_keyboard_languages;

static void macoblox_initialize_keyboard_source(void) {
    if (macoblox_keyboard_source)
        return;

    Class object_class = objc_getClass("NSObject");
    Class data_class = objc_getClass("NSMutableData");
    Class array_class = objc_getClass("NSArray");
    if (!object_class || !data_class || !array_class)
        return;

    macoblox_keyboard_source = ((id (*)(id, SEL))objc_msgSend)(
        (id)object_class, sel_registerName("new"));

    id data = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        (id)data_class, sel_registerName("dataWithLength:"), 4096UL);
    macoblox_keyboard_layout_data = data
        ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain")) : 0;

    id languages = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)array_class, sel_registerName("arrayWithObject:"), @"en");
    macoblox_keyboard_languages = languages
        ? ((id (*)(id, SEL))objc_msgSend)(languages, sel_registerName("retain")) : 0;
}

void* TISCopyCurrentKeyboardInputSource(void) {
    macoblox_initialize_keyboard_source();
    return macoblox_keyboard_source
        ? ((id (*)(id, SEL))objc_msgSend)(macoblox_keyboard_source, sel_registerName("retain")) : 0;
}

void* TISCopyCurrentKeyboardLayoutInputSource(void) {
    return TISCopyCurrentKeyboardInputSource();
}

const void* TISGetInputSourceProperty(void* source, const void* key) {
    (void)source;
    macoblox_initialize_keyboard_source();
    if (key == kTISPropertyInputSourceLanguages)
        return macoblox_keyboard_languages;
    if (key == kTISPropertyUnicodeKeyLayoutData)
        return macoblox_keyboard_layout_data;
    return 0;
}

// The zero-filled CFData above is only a non-null compatibility token. Avoid
// parsing it as a UCKeyboardLayout until Darling provides a real Carbon layout.
int UCKeyTranslate(const void* layout, unsigned short key_code,
                   unsigned short key_action, unsigned int modifiers,
                   unsigned int keyboard_type, unsigned int options,
                   unsigned int* dead_key_state,
                   unsigned long max_length,
                   unsigned long* actual_length,
                   unsigned short* unicode_string) {
    (void)layout; (void)key_code; (void)key_action; (void)modifiers;
    (void)keyboard_type; (void)options; (void)max_length; (void)unicode_string;
    if (dead_key_state)
        *dead_key_state = 0;
    if (actual_length)
        *actual_length = 0;
    return 0;
}

// CoreServices constants
const void* kUTTagClassFilenameExtension = @"public.filename-extension";
const void* kUTTypeImage = @"public.image";
const void* kUTTypeMovie = @"public.movie";

// CoreVideo constants
const void* kCVPixelBufferCGBitmapContextCompatibilityKey = @"kCVPixelBufferCGBitmapContextCompatibilityKey";
const void* kCVPixelBufferCGImageCompatibilityKey = @"kCVPixelBufferCGImageCompatibilityKey";

// GameController constants
const void* GCControllerDidConnectNotification = @"GCControllerDidConnectNotification";
const void* GCControllerDidDisconnectNotification = @"GCControllerDidDisconnectNotification";

// SystemConfiguration constants
const void* kSCNetworkInterfaceTypeEthernet = @"Ethernet";
const void* kSCNetworkInterfaceTypeIEEE80211 = @"IEEE80211";

// VideoToolbox constants
const void* kVTDecompressionPropertyKey_RealTime = @"RealTime";
const void* kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = @"RequireHardwareAcceleratedVideoDecoder";
const void* kVTVideoEncoderList_CodecType = @"CodecType";
const void* kVTVideoEncoderList_EncoderName = @"EncoderName";
