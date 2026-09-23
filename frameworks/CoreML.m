// CoreML is missing from Darling, and RobloxPlayer links it (not weakly), so
// without it the client does not load. Roblox only needs the classes to exist.
#import "stub.h"

@interface MLFeatureValue : NSObject @end
@implementation MLFeatureValue @end
@interface MLModel : NSObject @end
@implementation MLModel @end
@interface MLModelConfiguration : NSObject @end
@implementation MLModelConfiguration @end
@interface MLMultiArray : NSObject @end
@implementation MLMultiArray @end
@interface MLPredictionOptions : NSObject @end
@implementation MLPredictionOptions @end
