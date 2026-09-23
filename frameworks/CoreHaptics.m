// CoreHaptics is missing from Darling; RobloxPlayer links it weakly. Empty
// classes plus the constants it references keep the game-controller haptics
// code from touching null symbols.
#import "stub.h"

NSString *const CHHapticDynamicParameterIDHapticIntensityControl = @"HapticIntensityControl";
NSString *const CHHapticEventParameterIDHapticIntensity = @"HapticIntensity";
NSString *const CHHapticEventTypeHapticContinuous = @"HapticContinuous";

@interface CHHapticDynamicParameter : NSObject @end
@implementation CHHapticDynamicParameter @end
@interface CHHapticEvent : NSObject @end
@implementation CHHapticEvent @end
@interface CHHapticEventParameter : NSObject @end
@implementation CHHapticEventParameter @end
@interface CHHapticPattern : NSObject @end
@implementation CHHapticPattern @end
