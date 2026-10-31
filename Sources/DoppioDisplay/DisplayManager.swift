import AppKit
import CoreGraphics

struct PhysicalDisplay: Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let mirrorMaster: CGDirectDisplayID
    let isBuiltin: Bool

    var title: String { "\(name) (\(pixelWidth)×\(pixelHeight))" }

    /// Survives replugging and sleep, unlike `CGDirectDisplayID`.
    var key: String { DisplayManager.key(for: id) }
}

enum DisplayManager {
    /// Online includes displays that are currently mirroring another one,
    /// unlike the active list.
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func key(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// Real (non-virtual) displays, built-in first.
    static func physicalDisplays(excluding excluded: Set<CGDirectDisplayID>) -> [PhysicalDisplay] {
        onlineDisplayIDs()
            .filter { !excluded.contains($0) }
            .map { id in
                let mode = CGDisplayCopyDisplayMode(id)
                return PhysicalDisplay(
                    id: id,
                    name: localizedName(for: id),
                    pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)),
                    pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)),
                    mirrorMaster: CGDisplayMirrorsDisplay(id),
                    isBuiltin: CGDisplayIsBuiltin(id) != 0
                )
            }
            .sorted { $0.isBuiltin && !$1.isBuiltin }
    }

    static func localizedName(for id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if let screen { return screen.localizedName }
        return "Display \(CGDisplayVendorNumber(id) & 0xFFFF):\(CGDisplayModelNumber(id) & 0xFFFF)"
    }

    /// Makes `target` show the contents of `master` (hardware mirror).
    @discardableResult
    static func mirror(_ target: CGDirectDisplayID, of master: CGDirectDisplayID) -> CGError {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return begin }
        let set = CGConfigureDisplayMirrorOfDisplay(config, target, master)
        guard set == .success else {
            CGCancelDisplayConfiguration(config)
            return set
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }

    @discardableResult
    static func stopMirroring(_ target: CGDirectDisplayID) -> CGError {
        mirror(target, of: kCGNullDirectDisplay)
    }
}
