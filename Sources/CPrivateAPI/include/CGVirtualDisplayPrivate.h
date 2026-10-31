// CGVirtualDisplayPrivate.h
//
// Forward declarations for the private CGVirtualDisplay classes that live in
// CoreGraphics. There is no public header; the Objective-C runtime resolves
// these at call time. Apple may change or remove them in any macOS release.
//
// Shape taken from KhaosT/CGVirtualDisplay (Apache-2.0), Stengo/DeskPad (MIT)
// and lyonDan/vdscreen (MIT, tested on macOS 27).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
- (instancetype)init;
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
- (instancetype)init;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable reason, id _Nullable display);
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

// CoreBrightness (Night Shift, True Tone). Private; resolved at runtime in shim.m.
BOOL DPNightShiftAvailable(void);
BOOL DPNightShiftGetStatus(BOOL *enabled, float *strength);
BOOL DPNightShiftSetEnabled(BOOL enabled);
BOOL DPNightShiftSetStrength(float strength);
BOOL DPTrueToneSupported(void);
BOOL DPTrueToneEnabled(void);
BOOL DPTrueToneSetEnabled(BOOL enabled);

// Display presets ("reference modes", e.g. "Apple XDR Display (P3-1600 nits)").
// Private MonitorPanel framework; resolved at runtime in shim.m.
NSArray<NSString *> * _Nullable DPPresetNames(CGDirectDisplayID display);
NSString * _Nullable DPActivePresetName(CGDirectDisplayID display);
BOOL DPSetPreset(CGDirectDisplayID display, NSString *name);

// Display rotation (MonitorPanel). Degrees: 0, 90, 180, 270.
BOOL DPDisplayCanRotate(CGDirectDisplayID display);
int DPDisplayRotation(CGDirectDisplayID display);
BOOL DPDisplaySetRotation(CGDirectDisplayID display, int degrees);

NS_ASSUME_NONNULL_END
