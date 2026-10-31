import Foundation

/// The app used to be called VDisplay (bundle ID `local.vdisplay`).
/// Copies its settings once so virtual displays, profiles and preferences survive the rename.
enum LegacyMigration {
    private static let legacyDomain = "local.vdisplay"
    private static let doneKey = "migratedFromVDisplay"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
