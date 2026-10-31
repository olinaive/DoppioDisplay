import AppKit
import CPrivateAPI
import CoreGraphics
import Foundation

enum SelfTest {
    static func run() -> Int32 {
        print("CGVirtualDisplay classes present: \(VirtualDisplay.isSupported)")
        guard VirtualDisplay.isSupported else { return 1 }

        let config = VirtualDisplayConfig(name: "DoppioDisplay Self-Test", width: 1920, height: 1080)
        guard let display = VirtualDisplay(config: config) else {
            print("FAIL: WindowServer refused the descriptor")
            return 1
        }
        let id = display.displayID
        guard display.waitUntilOnline() else {
            print("FAIL: display \(id) never came online")
            return 1
        }
        let mode = CGDisplayCopyDisplayMode(id)
        print("OK: display \(id) online, \(mode?.width ?? 0)x\(mode?.height ?? 0) pt, \(mode?.pixelWidth ?? 0)x\(mode?.pixelHeight ?? 0) px")

        display.destroy()
        let gone = VirtualDisplay.waitUntilOffline(id)
        print(gone ? "OK: display removed" : "FAIL: display still online after release")
        return gone ? 0 : 1
    }

    static func brightnessProbe() -> Int32 {
        print("DisplayServices: get=\(PrivateDisplayAPI.getBrightness != nil) set=\(PrivateDisplayAPI.setBrightness != nil)")
        print("CoreDisplay info: \(PrivateDisplayAPI.createInfoDictionary != nil)")
        print("IOAVService: create=\(PrivateDisplayAPI.avServiceCreate != nil) i2c=\(PrivateDisplayAPI.avServiceWriteI2C != nil)")
        let ids = DisplayManager.onlineDisplayIDs()
        let services = DDCService.services(for: ids.filter { CGDisplayIsBuiltin($0) == 0 })
        for id in ids {
            var line = "display \(id) builtin=\(CGDisplayIsBuiltin(id) != 0) key=\(DisplayManager.key(for: id))"
            if PrivateDisplayAPI.supportsNativeBrightness(id) {
                line += " native=\(PrivateDisplayAPI.nativeBrightness(id).map { String(format: "%.2f", $0) } ?? "?")"
            } else if let service = services[id] {
                let brightness = service.read(.brightness)
                line += " ddc brightness=\(brightness.map { "\($0.current)/\($0.max)" } ?? "no reply")"
            } else {
                line += " software only"
            }
            print(line)
        }
        return 0
    }

    @MainActor
    static func xdrProbe() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = XDRBoost.builtinScreen else {
            print("no built-in screen")
            return 1
        }
        print("potential headroom: \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
        print("headroom before: \(screen.maximumExtendedDynamicRangeColorComponentValue)")
        let trigger = EDRTriggerWindow()
        trigger.place(on: screen)
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                trigger.render()
                ticks += 1
                if ticks % 8 == 0 {
                    let current = XDRBoost.builtinScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 0
                    print("headroom after \(ticks / 4) s: \(current)")
                }
                if ticks >= 40 { exit(0) }
            }
        }
        app.run()
        return 0
    }

    static func configProbe() -> Int32 {
        let defaults = UserDefaults(suiteName: "app.doppiodisplay") ?? .standard
        guard let data = defaults.data(forKey: "virtualDisplayConfigs") else {
            print("no saved virtual displays")
            return 0
        }
        let raw = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? -1
        do {
            let configs = try JSONDecoder().decode([VirtualDisplayConfig].self, from: data)
            print("saved: \(raw), decoded: \(configs.count)")
            for config in configs {
                print("  \(config.name) \(config.resolutionTitle) hiDPI=\(config.hiDPI) placement=\(config.placement.rawValue)")
            }
            return configs.count == raw ? 0 : 1
        } catch {
            print("decode failed: \(error)")
            return 1
        }
    }

    static func colorProbe() -> Int32 {
        var enabled: ObjCBool = false
        var strength: Float = 0
        print("Night Shift available: \(DPNightShiftAvailable())")
        if DPNightShiftGetStatus(&enabled, &strength) {
            print("Night Shift enabled: \(enabled.boolValue) strength: \(strength)")
        } else {
            print("Night Shift status: unavailable")
        }
        print("True Tone supported: \(DPTrueToneSupported()) enabled: \(DPTrueToneEnabled())")
        let builtin = DisplayManager.onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
        print("Presets: \(DPPresetNames(builtin) ?? ["unavailable"])")
        print("Active preset: \(DPActivePresetName(builtin) ?? "unavailable")")

        return 0
    }
}
