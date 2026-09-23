// Darling's sysroot has no SDK headers, so the stubs declare the little they
// need themselves. NSObject comes from libobjc, string literals are
// CoreFoundation constant strings.
typedef struct objc_class *Class;

__attribute__((objc_root_class))
@interface NSObject {
    Class isa;
}
@end

@interface NSString : NSObject
@end
