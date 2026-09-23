/* Functions RobloxPlayer imports that Darling does not export. They bind
 * lazily, so each one aborts the process on its first call ("dyld: Symbol not
 * found"). Found by comparing `llvm-nm -u RobloxPlayer` with the exports of
 * Darling's frameworks. Where macOS would report "unsupported", these do the
 * same, so Roblox takes its normal fallback path. */
#include <stdint.h>
#include <stddef.h>

typedef int32_t OSStatus;
typedef int32_t CVReturn;
typedef const void *CFTypeRef;
typedef unsigned long CFTypeID;
#define kCVReturnError (-6660)
#define kCVReturnUnsupported (-6668)
/* kAudioConverterErr_FormatNotSupported, 'fmt?' */
#define kAudioConverterErr_FormatNotSupported ((OSStatus)0x666d743f)

extern CFTypeRef CFRetain(CFTypeRef);
extern void CFRelease(CFTypeRef);
extern CFTypeID CFGetTypeID(CFTypeRef);
extern void *CGColorCreateGenericRGB(double, double, double, double);
extern unsigned char LMGetKbdType(void);

/* Carbon low-memory accessor for the last keyboard type used. */
unsigned char LMGetKbdLast(void) {
    return LMGetKbdType();
}

/* Darling's mach_absolute_time already counts nanoseconds. */
uint64_t AudioConvertHostTimeToNanos(uint64_t host_time) {
    return host_time;
}

OSStatus AudioConverterNewSpecific(const void *source, const void *destination,
                                   uint32_t count, const void *descriptions,
                                   void **converter) {
    (void)source; (void)destination; (void)count; (void)descriptions;
    if (converter)
        *converter = NULL;
    return kAudioConverterErr_FormatNotSupported;
}

typedef struct { float minimum, maximum, preferred; } CAFrameRateRange;
CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum,
                                      float preferred) {
    CAFrameRateRange range = {minimum, maximum, preferred};
    return range;
}

CFTypeID CGColorGetTypeID(void) {
    static CFTypeID type_id;
    if (!type_id) {
        void *color = CGColorCreateGenericRGB(0, 0, 0, 1);
        if (color) {
            type_id = CFGetTypeID(color);
            CFRelease(color);
        }
    }
    return type_id;
}

/* CoreVideo: no hardware video frames on Darling. */
CFTypeRef CVBufferRetain(CFTypeRef buffer) {
    return buffer ? CFRetain(buffer) : NULL;
}
void CVPixelBufferRelease(CFTypeRef buffer) {
    if (buffer)
        CFRelease(buffer);
}
CVReturn CVPixelBufferCreate(const void *allocator, size_t width, size_t height,
                             uint32_t format, const void *attributes,
                             void **buffer) {
    (void)allocator; (void)width; (void)height; (void)format; (void)attributes;
    if (buffer)
        *buffer = NULL;
    return kCVReturnUnsupported;
}
CVReturn CVPixelBufferPoolCreatePixelBuffer(const void *allocator,
                                            const void *pool, void **buffer) {
    (void)allocator; (void)pool;
    if (buffer)
        *buffer = NULL;
    return kCVReturnError;
}
size_t CVPixelBufferGetBytesPerRow(const void *buffer) { (void)buffer; return 0; }
size_t CVPixelBufferGetHeightOfPlane(const void *buffer, size_t plane) {
    (void)buffer; (void)plane; return 0;
}
size_t CVPixelBufferGetWidthOfPlane(const void *buffer, size_t plane) {
    (void)buffer; (void)plane; return 0;
}
uint32_t CVPixelBufferGetPixelFormatType(const void *buffer) { (void)buffer; return 0; }
typedef struct { double width, height; } MacOBloxCGSize;
MacOBloxCGSize CVImageBufferGetEncodedSize(const void *buffer) {
    (void)buffer;
    MacOBloxCGSize size = {0, 0};
    return size;
}
CVReturn CVMetalTextureCacheCreate(const void *allocator, const void *attributes,
                                   const void *device, const void *texture_attributes,
                                   void **cache) {
    (void)allocator; (void)attributes; (void)device; (void)texture_attributes;
    if (cache)
        *cache = NULL;
    return kCVReturnUnsupported;
}
CVReturn CVMetalTextureCacheCreateTextureFromImage(
    const void *allocator, const void *cache, const void *image,
    const void *attributes, uint64_t format, size_t width, size_t height,
    size_t plane, void **texture) {
    (void)allocator; (void)cache; (void)image; (void)attributes; (void)format;
    (void)width; (void)height; (void)plane;
    if (texture)
        *texture = NULL;
    return kCVReturnUnsupported;
}
void *CVMetalTextureGetTexture(const void *texture) { (void)texture; return NULL; }

void VTRegisterSupplementalVideoDecoderIfAvailable(uint32_t codec) { (void)codec; }

/* FSEvents: Darling's streams deliver nothing, so there is nothing to flush. */
void FSEventStreamFlushSync(void *stream) { (void)stream; }

/* SystemConfiguration: report no network service details. */
void *SCNetworkServiceCopy(const void *prefs, const void *service_id) {
    (void)prefs; (void)service_id; return NULL;
}
void *SCNetworkServiceGetInterface(const void *service) { (void)service; return NULL; }
const void *SCNetworkInterfaceGetInterfaceType(const void *interface) {
    (void)interface; return NULL;
}
