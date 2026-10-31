import CoreGraphics

/// Resolutions and refresh rates of physical displays (public Quartz API).
enum DisplayModes {
    /// Every mode usable for the desktop, including scaled (HiDPI) ones.
    static func all(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }

    static func isHiDPI(_ mode: CGDisplayMode) -> Bool { mode.pixelWidth > mode.width }

    /// Whether the display offers both HiDPI and 1:1 modes, so HiDPI can be switched.
    static func canToggleHiDPI(_ display: CGDirectDisplayID) -> Bool {
        let modes = all(for: display)
        return modes.contains(where: isHiDPI) && modes.contains { !isHiDPI($0) }
    }

    static func hasHiDPIModes(_ display: CGDirectDisplayID) -> Bool {
        all(for: display).contains(where: isHiDPI)
    }

    /// One entry per point size, from the HiDPI or the 1:1 modes (default: whichever is in use).
    static func resolutions(for display: CGDirectDisplayID, hiDPI: Bool? = nil) -> [CGDisplayMode] {
        let modes = all(for: display)
        let wantHiDPI = hiDPI ?? CGDisplayCopyDisplayMode(display).map(isHiDPI) ?? true
        let filtered = modes.filter { isHiDPI($0) == wantHiDPI }
        let pool = filtered.isEmpty ? modes : filtered
        let current = CGDisplayCopyDisplayMode(display)
        var bySize: [String: CGDisplayMode] = [:]
        for mode in pool {
            let key = "\(mode.width)x\(mode.height)"
            // Prefer the variant matching the current refresh rate.
            if bySize[key] == nil || mode.refreshRate == current?.refreshRate {
                bySize[key] = mode
            }
        }
        return bySize.values.sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    /// Modes with the current point size but different refresh rates.
    static func refreshRates(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        guard let current = CGDisplayCopyDisplayMode(display) else { return [] }
        let same = all(for: display).filter {
            $0.width == current.width && $0.height == current.height && $0.pixelWidth == current.pixelWidth
        }
        // Key by the rate rounded to 1/100 Hz so float noise does not create duplicates.
        var byRate: [Int: CGDisplayMode] = [:]
        for mode in same { byRate[Int((mode.refreshRate * 100).rounded())] = mode }
        return byRate.values.sorted { $0.refreshRate > $1.refreshRate }
    }

    /// Mode to switch to when HiDPI is turned on or off: the default one in that pool,
    /// otherwise the one closest to the current size.
    static func modeForHiDPI(_ on: Bool, display: CGDirectDisplayID) -> CGDisplayMode? {
        let pool = resolutions(for: display, hiDPI: on)
        if let preferred = pool.first(where: isDefault) { return preferred }
        guard let current = CGDisplayCopyDisplayMode(display) else { return pool.last }
        return pool.min { abs($0.width - current.width) < abs($1.width - current.width) }
    }

    static func isDefault(_ mode: CGDisplayMode) -> Bool {
        mode.ioFlags & 0x4 != 0 // kDisplayModeDefaultFlag (IOGraphicsTypes.h)
    }

    static func title(of mode: CGDisplayMode) -> String {
        "\(mode.width) × \(mode.height)" + (isDefault(mode) ? " (Default)" : "")
    }

    /// 59.94 and 60 are different modes, so fractional rates keep their decimals.
    /// The built-in panel's variable 120 Hz mode is what System Settings calls ProMotion.
    static func rateTitle(_ rate: Double, builtin: Bool = false) -> String {
        if rate == 0 { return "Default" }
        if builtin && rate >= 119 { return "ProMotion" }
        let rounded = rate.rounded()
        return abs(rate - rounded) < 0.01 ? "\(Int(rounded)) Hz" : String(format: "%.2f Hz", rate)
    }

    @discardableResult
    static func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> CGError {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return begin }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently)
    }
}
