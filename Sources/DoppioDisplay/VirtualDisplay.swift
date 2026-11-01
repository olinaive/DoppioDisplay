import CPrivateAPI
import CoreGraphics
import Foundation

/// Owns one CGVirtualDisplay. The display lives exactly as long as this object.
/// Size, HiDPI and refresh rate change in place (`apply`), so the display keeps
/// its ID, windows, arrangement and mirrors, like a monitor switching modes.
final class VirtualDisplay {
    private(set) var config: VirtualDisplayConfig
    private var display: CGVirtualDisplay?

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    /// The descriptor's pixel limit is fixed for the display's lifetime; this covers
    /// the largest allowed size (7680 × 4320) in HiDPI, either orientation fitting within it.
    static let maxPixelsWide: UInt32 = 15360
    static let maxPixelsHigh: UInt32 = 8640

    /// The private classes are resolved at runtime; a macOS update may drop them.
    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    init?(config: VirtualDisplayConfig) {
        guard Self.isSupported else { return nil }
        self.config = config
        // The new CGVirtualDisplay is autoreleased; drain it here so `destroy()` really
        // releases it. Otherwise it lingers until the event ends, and a display with the
        // same serial cannot be created again in the meantime.
        let display: CGVirtualDisplay? = autoreleasepool {
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = DispatchQueue.main
            descriptor.name = config.name
            descriptor.maxPixelsWide = Self.maxPixelsWide
            descriptor.maxPixelsHigh = Self.maxPixelsHigh
            // ~110 points per inch keeps the default UI scale sane.
            descriptor.sizeInMillimeters = CGSize(
                width: Double(config.width) * 25.4 / 110,
                height: Double(config.height) * 25.4 / 110
            )
            descriptor.vendorID = 0x5644
            descriptor.productID = 0x0001
            descriptor.serialNum = config.serial
            descriptor.terminationHandler = { _, _ in
                NSLog("DoppioDisplay: virtual display terminated by WindowServer")
            }
            guard let display = CGVirtualDisplay(descriptor: descriptor),
                  display.apply(Self.settings(for: config)) else { return nil }
            return display
        }
        guard let display else { return nil }
        self.display = display
    }

    /// Switches size, HiDPI and refresh rate without recreating the display.
    /// WindowServer picks the new mode asynchronously (well under a second).
    func apply(_ config: VirtualDisplayConfig) -> Bool {
        guard let display else { return false }
        let ok = autoreleasepool { display.apply(Self.settings(for: config)) }
        if ok { self.config = config }
        return ok
    }

    /// Mode size is in points; with hiDPI = 1 WindowServer adds the 2x backing mode.
    private static func settings(for config: VirtualDisplayConfig) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: config.width, height: config.height, refreshRate: config.refreshRate),
        ]
        return settings
    }

    /// Whether WindowServer currently runs the display in the mode `config` asks for.
    func isShowing(_ config: VirtualDisplayConfig) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
        return mode.width == Int(config.width) && mode.height == Int(config.height)
            && mode.pixelWidth == Int(config.width) * (config.hiDPI ? 2 : 1)
            && abs(mode.refreshRate - config.refreshRate) < 1
    }

    /// Releasing the object removes the display from WindowServer.
    func destroy() {
        display = nil
    }

    var isOnline: Bool { DisplayManager.onlineDisplayIDs().contains(displayID) }

    /// Waits until the new display shows up in the online display list.
    func waitUntilOnline(timeout: TimeInterval = 3) -> Bool {
        Self.wait(timeout: timeout) { self.isOnline }
    }

    /// WindowServer refuses a second display with the same serial, so a
    /// recreate must wait for the old one to go away.
    static func waitUntilOffline(_ id: CGDirectDisplayID, timeout: TimeInterval = 3) -> Bool {
        wait(timeout: timeout) { !DisplayManager.onlineDisplayIDs().contains(id) }
    }

    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
