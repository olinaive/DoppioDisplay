import AppKit
import ColorSync
import CPrivateAPI
import Observation

/// An installed RGB display profile.
struct ColorProfile: Hashable {
    let url: URL
    let name: String
}

/// Per-display ICC profiles (public ColorSync API) plus Night Shift and
/// True Tone for the built-in panel (private CoreBrightness, via shim.m).
@MainActor
@Observable
final class ColorControls {
    static let shared = ColorControls()

    private(set) var profiles: [ColorProfile] = []
    private(set) var nightShiftAvailable = false
    private(set) var nightShiftEnabled = false
    private(set) var nightShiftStrength: Double = 0.5
    private(set) var trueToneAvailable = false
    private(set) var trueToneEnabled = false
    /// Bumped after a profile change so views re-read the current profile name.
    private(set) var revision = 0

    private init() {
        reload()
    }

    /// Re-reads installed profiles and system Night Shift / True Tone state.
    func reload() {
        profiles = Self.installedDisplayProfiles()
        nightShiftAvailable = DPNightShiftAvailable()
        var enabled: ObjCBool = false
        var strength: Float = 0
        if DPNightShiftGetStatus(&enabled, &strength) {
            nightShiftEnabled = enabled.boolValue
            nightShiftStrength = Double(strength)
        }
        trueToneAvailable = DPTrueToneSupported()
        trueToneEnabled = DPTrueToneEnabled()
    }

    // MARK: Night Shift / True Tone

    func setNightShift(_ enabled: Bool) {
        guard DPNightShiftSetEnabled(enabled) else { return report("Night Shift") }
        nightShiftEnabled = enabled
    }

    func setNightShiftStrength(_ strength: Double) {
        let value = min(max(strength, 0), 1)
        guard DPNightShiftSetStrength(Float(value)) else { return report("Night Shift") }
        nightShiftStrength = value
    }

    func setTrueTone(_ enabled: Bool) {
        guard DPTrueToneSetEnabled(enabled) else { return report("True Tone") }
        trueToneEnabled = enabled
    }

    private func report(_ feature: String) {
        DisplayStore.shared.lastError = "\(feature) could not be changed on this macOS version."
    }

    // MARK: Presets

    /// Reference modes such as "Apple XDR Display (P3-1600 nits)"; empty when the display has none.
    func presets(for display: CGDirectDisplayID) -> [String] {
        _ = revision
        return DPPresetNames(display) ?? []
    }

    func activePreset(for display: CGDirectDisplayID) -> String? {
        _ = revision
        return DPActivePresetName(display)
    }

    func setPreset(_ name: String, for display: CGDirectDisplayID) {
        if !DPSetPreset(display, name) {
            DisplayStore.shared.lastError = "Preset could not be changed on this macOS version."
        }
        revision += 1
    }

    // MARK: ICC profiles

    func currentProfileName(for display: CGDirectDisplayID) -> String {
        _ = revision
        guard let profile = ColorSyncProfileCreateWithDisplayID(display)?.takeRetainedValue(),
              let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() else { return "Unknown" }
        return name as String
    }

    func setProfile(_ url: URL, for display: CGDirectDisplayID) {
        setCustomProfile(url as CFURL, for: display)
    }

    /// Drops the custom profile so macOS uses the display's factory one again.
    func resetProfile(for display: CGDirectDisplayID) {
        setCustomProfile(kCFNull, for: display)
    }

    /// Lets the user pick any .icc/.icm file.
    func chooseProfileFile(for display: CGDirectDisplayID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "icc")!, .init(filenameExtension: "icm")!]
        panel.directoryURL = URL(fileURLWithPath: "/Library/ColorSync/Profiles")
        panel.message = "Choose a color profile for this display"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            setProfile(url, for: display)
        }
    }

    private func setCustomProfile(_ value: CFTypeRef, for display: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return }
        let settings = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue(): value,
            kColorSyncProfileUserScope.takeUnretainedValue(): kCFPreferencesCurrentUser,
        ] as CFDictionary
        if !ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, settings) {
            DisplayStore.shared.lastError = "ColorSync refused the profile."
        }
        revision += 1
    }

    /// RGB monitor-class profiles from all ColorSync locations, by name.
    private static func installedDisplayProfiles() -> [ColorProfile] {
        final class Box { var profiles: [ColorProfile] = [] }
        let box = Box()
        var seed: UInt32 = 0
        ColorSyncIterateInstalledProfiles({ info, userInfo in
            guard let info = info as? [String: Any], let userInfo else { return true }
            let box = Unmanaged<Box>.fromOpaque(userInfo).takeUnretainedValue()
            let keys = ColorSyncKeys.self
            guard info[keys.profileClass] as? String == keys.displayClass,
                  info[keys.colorSpace] as? String == keys.rgb,
                  let url = info[keys.url] as? URL,
                  let name = info[keys.description] as? String
            else { return true }
            box.profiles.append(ColorProfile(url: url, name: name))
            return true
        }, &seed, Unmanaged.passUnretained(box).toOpaque(), nil)
        var seen = Set<String>()
        return box.profiles
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.name).inserted }
    }
}

/// ColorSync's C string constants, read once. They are immutable in practice; the C
/// headers declare them as `var`, which strict concurrency checking flags anyway.
private enum ColorSyncKeys {
    static let profileClass = kColorSyncProfileClass.takeUnretainedValue() as String
    static let colorSpace = kColorSyncProfileColorSpace.takeUnretainedValue() as String
    static let displayClass = kColorSyncSigDisplayClass.takeUnretainedValue() as String
    static let rgb = kColorSyncSigRgbData.takeUnretainedValue() as String
    static let url = kColorSyncProfileURL.takeUnretainedValue() as String
    static let description = kColorSyncProfileDescription.takeUnretainedValue() as String
}
