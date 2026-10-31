import Foundation
import Observation

/// A named snapshot: virtual displays (with resolution, mirrors, placement),
/// brightness per physical display and XDR Boost.
struct DisplayProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var displays: [VirtualDisplayConfig]
    var brightness: [String: Double]
    var xdrEnabled: Bool?
    var xdrLevel: Double?
    var trigger: ProfileTrigger = .manual

    init(name: String, displays: [VirtualDisplayConfig], brightness: [String: Double], xdrEnabled: Bool?, xdrLevel: Double?) {
        self.name = name
        self.displays = displays
        self.brightness = brightness
        self.xdrEnabled = xdrEnabled
        self.xdrLevel = xdrLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([VirtualDisplayConfig].self, forKey: .displays)
        brightness = try c.decode([String: Double].self, forKey: .brightness)
        xdrEnabled = try c.decodeIfPresent(Bool.self, forKey: .xdrEnabled)
        xdrLevel = try c.decodeIfPresent(Double.self, forKey: .xdrLevel)
        trigger = try c.decodeIfPresent(ProfileTrigger.self, forKey: .trigger) ?? .manual
    }
}

/// When a profile applies itself: as the set of connected external monitors changes.
enum ProfileTrigger: Codable, Hashable {
    case manual
    case connected(key: String, name: String)
    case anyExternal
    case noExternal

    var title: String {
        switch self {
        case .manual: "Manually only"
        case .connected(_, let name): "When \(name) connects"
        case .anyExternal: "When any external connects"
        case .noExternal: "When no external is connected"
        }
    }

    var isAutomatic: Bool { self != .manual }
}

@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    private(set) var profiles: [DisplayProfile] = []
    /// Last profile applied, manually or automatically.
    private(set) var activeProfileID: UUID?
    private static let key = "displayProfiles"
    @ObservationIgnored private var lastExternalKeys: Set<String>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([DisplayProfile].self, from: data) {
            profiles = saved
        }
    }

    func saveCurrent(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let brightness = BrightnessStore.shared.controls.mapValues(\.brightness)
        let boost = XDRBoost.shared
        var profile = DisplayProfile(
            name: trimmed,
            displays: DisplayStore.shared.configs,
            brightness: brightness,
            xdrEnabled: XDRBoost.isSupported ? boost.isEnabled : nil,
            xdrLevel: XDRBoost.isSupported ? boost.level : nil
        )
        // Saving under an existing name replaces that profile.
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            profile.id = profiles[index].id
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func apply(_ profile: DisplayProfile) {
        activeProfileID = profile.id
        DisplayStore.shared.apply(configs: profile.displays)
        // Brightness only for displays that are connected right now.
        for (key, value) in profile.brightness where BrightnessStore.shared.controls[key] != nil {
            BrightnessStore.shared.setBrightness(key, value)
        }
        if XDRBoost.isSupported, let enabled = profile.xdrEnabled {
            if let level = profile.xdrLevel { XDRBoost.shared.level = level }
            XDRBoost.shared.isEnabled = enabled
        }
    }

    func apply(named name: String) -> Bool {
        guard let profile = profiles.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return false }
        apply(profile)
        return true
    }

    func setTrigger(_ trigger: ProfileTrigger, for profile: DisplayProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].trigger = trigger
        save()
    }

    /// Called when the physical display list changes. Applies the best matching
    /// automatic profile, but only when the set of external monitors actually changed,
    /// so applying a profile (which reconfigures displays) cannot loop.
    func externalDisplaysChanged(_ externals: [PhysicalDisplay]) {
        let keys = Set(externals.map(\.key))
        guard keys != lastExternalKeys else { return }
        lastExternalKeys = keys
        let match = profiles.first { profile in
            if case .connected(let key, _) = profile.trigger { return keys.contains(key) }
            return false
        } ?? profiles.first { $0.trigger == (keys.isEmpty ? .noExternal : .anyExternal) }
        if let match {
            // Let the reconfiguration that brought us here settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.apply(match) }
        }
    }

    func delete(_ profile: DisplayProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
