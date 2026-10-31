import CoreGraphics
import Darwin
import IOKit

/// Private display symbols, resolved at runtime with dlsym so the app keeps
/// running (with software dimming) if a macOS update removes any of them.
enum PrivateDisplayAPI {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    typealias CreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    static let getBrightness: GetBrightness? = symbol(displayServices, "DisplayServicesGetBrightness")
    static let setBrightness: SetBrightness? = symbol(displayServices, "DisplayServicesSetBrightness")
    static let canChangeBrightness: CanChangeBrightness? = symbol(displayServices, "DisplayServicesCanChangeBrightness")
    static let createInfoDictionary: CreateInfoDictionary? = symbol(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary")
    static let avServiceCreate: AVServiceCreate? = symbol(ioKit, "IOAVServiceCreateWithService")
    static let avServiceWriteI2C: AVServiceI2C? = symbol(ioKit, "IOAVServiceWriteI2C")
    static let avServiceReadI2C: AVServiceI2C? = symbol(ioKit, "IOAVServiceReadI2C")

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Built-in panels and Apple displays expose brightness through DisplayServices.
    static func supportsNativeBrightness(_ id: CGDirectDisplayID) -> Bool {
        guard let canChange = canChangeBrightness, getBrightness != nil, setBrightness != nil else { return false }
        return canChange(id)
    }

    static func nativeBrightness(_ id: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let get = getBrightness, get(id, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setNativeBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        setBrightness?(id, value) == 0
    }

    static func infoDictionary(_ id: CGDirectDisplayID) -> [String: Any]? {
        createInfoDictionary?(id)?.takeRetainedValue() as? [String: Any]
    }
}
