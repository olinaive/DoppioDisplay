import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via Carbon hot keys (no extra permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    struct Shortcut {
        let id: UInt32
        let keyCode: Int
        let symbol: String
        let title: String
        let action: @MainActor () -> Void
    }

    /// ⌃⌥⌘ plus a key, unlikely to clash with apps.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let modifierSymbols = "⌃⌥⌘"

    let shortcuts: [Shortcut] = [
        Shortcut(id: 1, keyCode: kVK_ANSI_V, symbol: "V", title: "Turn first virtual display on/off") {
            let store = DisplayStore.shared
            if let first = store.configs.first {
                store.setEnabled(first.id, !store.isLive(first.id))
            } else {
                store.addDisplay()
            }
        },
        Shortcut(id: 2, keyCode: kVK_ANSI_P, symbol: "P", title: "Show/hide preview of first virtual display") {
            let store = DisplayStore.shared
            guard let first = store.configs.first(where: { store.isLive($0.id) }) else { return }
            store.togglePreview(.virtual(first.id))
        },
        Shortcut(id: 3, keyCode: kVK_ANSI_X, symbol: "X", title: "XDR Boost on/off") {
            guard XDRBoost.isSupported else { return }
            XDRBoost.shared.isEnabled.toggle()
        },
        Shortcut(id: 4, keyCode: kVK_UpArrow, symbol: "↑", title: "Brightness up (display under cursor)") {
            BrightnessStore.shared.step(by: 1 / 16)
        },
        Shortcut(id: 5, keyCode: kVK_DownArrow, symbol: "↓", title: "Brightness down (display under cursor)") {
            BrightnessStore.shared.step(by: -1 / 16)
        },
    ]

    /// ⌃⌥⌘1…9 apply profiles in list order.
    private static let profileKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    private static let profileIDBase: UInt32 = 100

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotKeysEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hotKeysEnabled")
            newValue ? register() : unregister()
        }
    }

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        if isEnabled { register() }
    }

    private func register() {
        unregister()
        for shortcut in shortcuts {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5644_5350), id: shortcut.id) // "VDSP"
            if RegisterEventHotKey(UInt32(shortcut.keyCode), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
        for (index, keyCode) in Self.profileKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5644_5350), id: Self.profileIDBase + UInt32(index))
            if RegisterEventHotKey(UInt32(keyCode), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func fire(_ id: UInt32) {
        if id >= Self.profileIDBase {
            let profiles = ProfileStore.shared.profiles
            let index = Int(id - Self.profileIDBase)
            if profiles.indices.contains(index) { ProfileStore.shared.apply(profiles[index]) }
            return
        }
        shortcuts.first { $0.id == id }?.action()
    }
}
