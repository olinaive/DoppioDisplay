import CPrivateAPI
import CoreGraphics
import Foundation

/// Owns one CGVirtualDisplay. The display lives exactly as long as this object.
final class VirtualDisplay {
    let config: VirtualDisplayConfig
    private var display: CGVirtualDisplay?

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

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
        let width = config.width
        let height = config.height

        // Mode size is in points. With hiDPI = 1 WindowServer adds a 2x backing
        // mode, so the descriptor must allow twice the pixels.
        let scale: UInt32 = config.hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = config.name
        descriptor.maxPixelsWide = width * scale
        descriptor.maxPixelsHigh = height * scale
        // ~110 points per inch keeps the default UI scale sane.
        descriptor.sizeInMillimeters = CGSize(
            width: Double(width) * 25.4 / 110,
            height: Double(height) * 25.4 / 110
        )
        descriptor.vendorID = 0x5644
        descriptor.productID = 0x0001
        descriptor.serialNum = config.serial
        descriptor.terminationHandler = { _, _ in
            NSLog("DoppioDisplay: virtual display terminated by WindowServer")
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: width, height: height, refreshRate: config.refreshRate),
        ]
        guard display.apply(settings) else { return nil }
        self.display = display
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
