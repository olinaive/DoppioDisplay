import CoreGraphics
import Foundation

struct DisplayPreset: Hashable {
    let width: UInt32
    let height: UInt32

    var title: String { "\(width) × \(height)" }

    static let all: [DisplayPreset] = [
        DisplayPreset(width: 1280, height: 720),
        DisplayPreset(width: 1920, height: 1080),
        DisplayPreset(width: 1920, height: 1200),
        DisplayPreset(width: 2560, height: 1440),
        DisplayPreset(width: 2560, height: 1600),
        DisplayPreset(width: 3440, height: 1440),
        DisplayPreset(width: 3840, height: 2160),
    ]
}

/// Everything needed to (re)create one virtual display. Persisted in UserDefaults.
struct VirtualDisplayConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var width: UInt32
    var height: UInt32
    var hiDPI = true
    var refreshRate: Double = 60
    var isEnabled = true
    /// Stable keys (`PhysicalDisplay.key`) of monitors that should mirror this display.
    var mirrorTargets: [String] = []
    /// Legacy side placement; superseded by `relativeOrigin` once the display is dragged.
    var placement: DisplayPlacement = .automatic
    /// Top-left corner relative to the built-in display's top-left, in points. Nil = let macOS decide.
    var relativeOrigin: CGPoint?
    var keepAwake: KeepAwake = .never
    /// Set when this display only exists to give a monitor HiDPI (mirrored onto it); the monitor's key.
    var hiDPIFor: String?

    var resolutionTitle: String { "\(width) × \(height)" }
    var isPortrait: Bool { height > width }

    init(name: String, width: UInt32, height: UInt32) {
        self.name = name
        self.width = width
        self.height = height
    }

    /// Fields added in later versions fall back to their defaults, so saved displays survive upgrades.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decode(UInt32.self, forKey: .width)
        height = try c.decode(UInt32.self, forKey: .height)
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? true
        refreshRate = try c.decodeIfPresent(Double.self, forKey: .refreshRate) ?? 60
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        mirrorTargets = try c.decodeIfPresent([String].self, forKey: .mirrorTargets) ?? []
        placement = try c.decodeIfPresent(DisplayPlacement.self, forKey: .placement) ?? .automatic
        relativeOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .relativeOrigin)
        keepAwake = try c.decodeIfPresent(KeepAwake.self, forKey: .keepAwake) ?? .never
        hiDPIFor = try c.decodeIfPresent(String.self, forKey: .hiDPIFor)
    }

    /// Same serial across launches lets macOS remember the arrangement.
    var serial: UInt32 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } | 1
    }

    /// Fields that switch the display's mode when changed.
    func needsModeChange(comparedTo other: VirtualDisplayConfig) -> Bool {
        width != other.width || height != other.height
            || hiDPI != other.hiDPI || refreshRate != other.refreshRate
    }

    static func makeDefault(index: Int) -> VirtualDisplayConfig {
        VirtualDisplayConfig(name: "Virtual \(index)", width: 1920, height: 1080)
    }

    static let refreshRates: [Double] = [30, 60, 120]
}

/// Keeps the Mac (and its displays) from idling to sleep while a virtual display is in use.
enum KeepAwake: String, Codable, CaseIterable {
    case never, whileMirroring, whileOn

    var title: String {
        switch self {
        case .never: "Never"
        case .whileMirroring: "While Mirroring"
        case .whileOn: "While Display Is On"
        }
    }
}

/// Where a virtual display sits relative to the built-in panel.
enum DisplayPlacement: String, Codable, CaseIterable {
    case automatic, left, right, above, below

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .left: "Left of Built-in"
        case .right: "Right of Built-in"
        case .above: "Above Built-in"
        case .below: "Below Built-in"
        }
    }
}

enum PreviewState {
    case closed, open, minimized
}

/// What a preview window shows: one of our virtual displays or any physical display.
enum PreviewSource: Hashable {
    case virtual(UUID)
    case display(key: String)
    /// A window picked in the system picker; lives only as long as its preview.
    case window(UUID)

    var autosaveName: String {
        switch self {
        case .virtual(let id): "Preview-\(id.uuidString)"
        case .display(let key): "Preview-Display-\(key)"
        case .window: "Preview-Window"
        }
    }
}
