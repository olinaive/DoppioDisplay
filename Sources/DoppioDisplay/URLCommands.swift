import AppKit

/// `doppio://` automation, also used by `scripts/doppio`.
///
///     doppio://create?width=2560&height=1440&hidpi=1&hz=60&name=Desk
///     doppio://enable?name=Desk            (or index=1; default: first display)
///     doppio://disable?name=Desk
///     doppio://toggle?name=Desk
///     doppio://remove?name=Desk
///     doppio://resolution?name=Desk&width=1920&height=1080&hidpi=0&hz=120
///     doppio://preview?name=Desk&action=show|hide|toggle
///     doppio://mirror?name=Desk&target=LG&on=1|0
///     doppio://xdr?on=1|0|toggle&level=0.8
///     doppio://brightness?display=builtin|<name>&value=0.5
///     doppio://profile?name=Work             (action=apply|save; default apply)
///     doppio://settings?section=brightness
///     doppio://menu                           (opens the menu bar panel)
///     doppio://panel?expand=builtin,virtual,arrangement   (panel as a floating window)
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        // The old vdisplay:// scheme keeps working for existing shortcuts.
        guard ["doppio", "v" + "display"].contains(url.scheme ?? ""), let command = url.host() else { return }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { $1 }
        )
        let store = DisplayStore.shared

        switch command {
        case "create":
            store.addDisplay { config in
                if let name = query["name"], !name.isEmpty { config.name = name }
                if let hiDPI = bool(query["hidpi"]) { config.hiDPI = hiDPI }
                if let hz = query["hz"].flatMap(Double.init), VirtualDisplayConfig.refreshRates.contains(hz) { config.refreshRate = hz }
                if let width = query["width"].flatMap(UInt32.init), let height = query["height"].flatMap(UInt32.init),
                   (640...7680).contains(width), (480...4320).contains(height) {
                    config.width = width
                    config.height = height
                }
            }
        case "enable", "disable", "toggle":
            guard let config = virtualDisplay(query) else { return fail("No virtual display matches \(url.query() ?? "")") }
            let enable = command == "enable" || (command == "toggle" && !store.isLive(config.id))
            store.setEnabled(config.id, enable)
        case "remove":
            guard let config = virtualDisplay(query) else { return fail("No virtual display matches \(url.query() ?? "")") }
            store.remove(config.id)
        case "resolution":
            guard let config = virtualDisplay(query) else { return fail("No virtual display matches \(url.query() ?? "")") }
            apply(query, to: config.id)
        case "preview":
            guard let config = virtualDisplay(query) else { return fail("No virtual display matches \(url.query() ?? "")") }
            switch query["action"] ?? "toggle" {
            case "show": store.showPreview(config.id)
            case "hide": store.closePreview(config.id)
            default: store.togglePreview(.virtual(config.id))
            }
        case "mirror":
            guard let config = virtualDisplay(query) else { return fail("No virtual display matches \(url.query() ?? "")") }
            let targets = store.mirrorCandidates.filter { matches($0.name, query["target"]) }
            guard let target = targets.first else { return fail("No external display matches \(query["target"] ?? "")") }
            let wanted = bool(query["on"]) ?? !store.isMirroring(config.id, to: target)
            if wanted != store.isMirroring(config.id, to: target) { store.toggleMirror(config.id, to: target) }
        case "xdr":
            guard XDRBoost.isSupported else { return fail("This Mac has no XDR display") }
            if let level = query["level"].flatMap(Double.init) { XDRBoost.shared.level = min(max(level, 0), 1) }
            if let on = query["on"] {
                XDRBoost.shared.isEnabled = on == "toggle" ? !XDRBoost.shared.isEnabled : bool(on) ?? true
            }
        case "brightness":
            guard let value = query["value"].flatMap(Double.init) else { return fail("brightness needs value=0…1") }
            let wanted = query["display"] ?? "builtin"
            let match = store.physicalDisplays.first {
                wanted == "builtin" ? $0.isBuiltin : matches($0.name, wanted)
            }
            guard let match else { return fail("No display matches \(wanted)") }
            BrightnessStore.shared.setBrightness(match.key, value)
        case "menu":
            MenuBarController.shared.open()
        case "panel":
            if let expand = query["expand"] {
                PanelState.shared.expand(expand.split(separator: ",").map(String.init))
            }
            PanelWindowController.shared.show()
        case "settings":
            let section = query["section"].flatMap(SettingsView.Section.init(rawValue:))
            SettingsWindowController.shared.show(section)
        case "profile":
            guard let name = query["name"], !name.isEmpty else { return fail("profile needs name=") }
            if query["action"] == "save" {
                ProfileStore.shared.saveCurrent(named: name)
            } else if !ProfileStore.shared.apply(named: name) {
                fail("No profile matches \(name)")
            }
        default:
            fail("Unknown command \(command)")
        }
    }

    private static func apply(_ query: [String: String], to id: UUID) {
        let store = DisplayStore.shared
        if let name = query["name"], !name.isEmpty { store.update(id) { $0.name = name } }
        if let hiDPI = bool(query["hidpi"]) { store.update(id) { $0.hiDPI = hiDPI } }
        if let hz = query["hz"].flatMap(Double.init), VirtualDisplayConfig.refreshRates.contains(hz) {
            store.update(id) { $0.refreshRate = hz }
        }
        if let width = query["width"].flatMap(UInt32.init), let height = query["height"].flatMap(UInt32.init) {
            store.setResolution(id, width: width, height: height)
        }
    }

    private static func virtualDisplay(_ query: [String: String]) -> VirtualDisplayConfig? {
        let configs = DisplayStore.shared.configs
        if let name = query["name"] { return configs.first { matches($0.name, name) } }
        if let index = query["index"].flatMap(Int.init), configs.indices.contains(index - 1) { return configs[index - 1] }
        return configs.first
    }

    private static func matches(_ name: String, _ pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(pattern)
    }

    private static func bool(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }

    private static func fail(_ message: String) {
        DisplayStore.shared.lastError = "doppio:// — \(message)"
        NSLog("DoppioDisplay URL command failed: \(message)")
    }
}
