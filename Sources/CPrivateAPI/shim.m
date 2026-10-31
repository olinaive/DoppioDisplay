#import "CGVirtualDisplayPrivate.h"
#import <dlfcn.h>
#import <objc/message.h>

// Night Shift and True Tone live in the private CoreBrightness framework.
// Everything is looked up at runtime: if Apple renames a class or selector,
// these functions return NO and the app hides the controls.

typedef struct { int hour; int minute; } DPTime;
typedef struct { DPTime fromTime; DPTime toTime; } DPSchedule;
typedef struct {
    BOOL active;
    BOOL enabled;
    BOOL sunSchedulePermitted;
    int mode;
    DPSchedule schedule;
    unsigned long long disableFlags;
    BOOL available;
} DPBlueLightStatus;

static id DPClient(NSString *className) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
    });
    Class cls = NSClassFromString(className);
    return cls ? [[cls alloc] init] : nil;
}

static id DPBlueLight(void) {
    static id client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = DPClient(@"CBBlueLightClient"); });
    return client;
}

static id DPTrueTone(void) {
    static id client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = DPClient(@"CBTrueToneClient"); });
    return client;
}

BOOL DPNightShiftAvailable(void) {
    id client = DPBlueLight();
    if (![client respondsToSelector:@selector(getBlueLightStatus:)]) return NO;
    DPBlueLightStatus status = {0};
    BOOL ok = ((BOOL (*)(id, SEL, DPBlueLightStatus *))objc_msgSend)(client, @selector(getBlueLightStatus:), &status);
    return ok && status.available;
}

BOOL DPNightShiftGetStatus(BOOL *enabled, float *strength) {
    id client = DPBlueLight();
    if (![client respondsToSelector:@selector(getBlueLightStatus:)] || ![client respondsToSelector:@selector(getStrength:)]) return NO;
    DPBlueLightStatus status = {0};
    if (!((BOOL (*)(id, SEL, DPBlueLightStatus *))objc_msgSend)(client, @selector(getBlueLightStatus:), &status)) return NO;
    float value = 0;
    if (!((BOOL (*)(id, SEL, float *))objc_msgSend)(client, @selector(getStrength:), &value)) return NO;
    *enabled = status.enabled;
    *strength = value;
    return YES;
}

BOOL DPNightShiftSetEnabled(BOOL enabled) {
    id client = DPBlueLight();
    if (![client respondsToSelector:@selector(setEnabled:)]) return NO;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, @selector(setEnabled:), enabled);
}

BOOL DPNightShiftSetStrength(float strength) {
    id client = DPBlueLight();
    if (![client respondsToSelector:@selector(setStrength:commit:)]) return NO;
    return ((BOOL (*)(id, SEL, float, BOOL))objc_msgSend)(client, @selector(setStrength:commit:), strength, YES);
}

BOOL DPTrueToneSupported(void) {
    id client = DPTrueTone();
    if (![client respondsToSelector:@selector(supported)] || ![client respondsToSelector:@selector(available)]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(supported))
        && ((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(available));
}

BOOL DPTrueToneEnabled(void) {
    id client = DPTrueTone();
    if (![client respondsToSelector:@selector(enabled)]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(enabled));
}

BOOL DPTrueToneSetEnabled(BOOL enabled) {
    id client = DPTrueTone();
    if (![client respondsToSelector:@selector(setEnabled:)]) return NO;
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, @selector(setEnabled:), enabled);
}

// MARK: - Display presets (MonitorPanel)

static id DPMonitorDisplay(CGDirectDisplayID displayID) {
    static id manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY);
        Class cls = NSClassFromString(@"MPDisplayMgr");
        manager = cls ? [[cls alloc] init] : nil;
    });
    if (![manager respondsToSelector:@selector(displayWithID:)]) return nil;
    return ((id (*)(id, SEL, int))objc_msgSend)(manager, @selector(displayWithID:), (int)displayID);
}

static NSString *DPPresetName(id preset) {
    if ([preset respondsToSelector:@selector(presetName)]) {
        return ((id (*)(id, SEL))objc_msgSend)(preset, @selector(presetName));
    }
    return nil;
}

static NSArray *DPPresets(id display) {
    if (![display respondsToSelector:@selector(hasPresets)] || ![display respondsToSelector:@selector(presets)]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(display, @selector(hasPresets))) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(display, @selector(presets));
}

NSArray<NSString *> *DPPresetNames(CGDirectDisplayID displayID) {
    NSArray *presets = DPPresets(DPMonitorDisplay(displayID));
    if (!presets) return nil;
    NSMutableArray *names = [NSMutableArray array];
    for (id preset in presets) {
        if ([preset respondsToSelector:@selector(isValid)] && !((BOOL (*)(id, SEL))objc_msgSend)(preset, @selector(isValid))) continue;
        NSString *name = DPPresetName(preset);
        if (name.length) [names addObject:name];
    }
    return names;
}

NSString *DPActivePresetName(CGDirectDisplayID displayID) {
    id display = DPMonitorDisplay(displayID);
    if (![display respondsToSelector:@selector(activePreset)]) return nil;
    return DPPresetName(((id (*)(id, SEL))objc_msgSend)(display, @selector(activePreset)));
}

BOOL DPSetPreset(CGDirectDisplayID displayID, NSString *name) {
    id display = DPMonitorDisplay(displayID);
    if (![display respondsToSelector:@selector(setActivePreset:)]) return NO;
    for (id preset in DPPresets(display)) {
        if ([DPPresetName(preset) isEqualToString:name]) {
            ((void (*)(id, SEL, id))objc_msgSend)(display, @selector(setActivePreset:), preset);
            return YES;
        }
    }
    return NO;
}
