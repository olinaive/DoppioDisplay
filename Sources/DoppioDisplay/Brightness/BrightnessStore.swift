import AppKit
import CoreGraphics
import Foundation
import Observation

enum BrightnessMethod: String {
    /// DisplayServices: built-in panel and Apple displays.
    case native = "Native"
    /// DDC/CI: most external monitors over USB-C / Thunderbolt / DisplayPort.
    case ddc = "DDC"
    /// Gamma table scaling: works everywhere, dims the image rather than the backlight.
    case software = "Software"
}

struct DisplayControl {
    let displayID: CGDirectDisplayID
    var method: BrightnessMethod
    /// 0...1
    var brightness: Double
    /// 0...1, only for DDC monitors that answer the volume VCP code.
    var volume: Double?
    /// DDC extras; nil when the monitor does not answer.
    var contrast: Double?
    var muted: Bool?
    var inputSource: UInt16?
}

/// Everything read from one monitor over DDC during the probe.
private struct DDCReadout: @unchecked Sendable {
    let service: DDCService
    var values: [DDCService.VCP: (current: UInt16, max: UInt16)]
}

/// Brightness and volume for physical displays. Picks the best available
/// method per display and falls back to software dimming.
@MainActor
@Observable
final class BrightnessStore {
    static let shared = BrightnessStore()

    /// Keyed by `PhysicalDisplay.key`. Missing while a display is still being probed.
    private(set) var controls: [String: DisplayControl] = [:]

    var syncWithBuiltin: Bool {
        didSet {
            UserDefaults.standard.set(syncWithBuiltin, forKey: Keys.sync)
            lastBuiltinBrightness = nil
        }
    }

    @ObservationIgnored private var ddc: [String: (service: DDCService, max: [DDCService.VCP: UInt16])] = [:]
    @ObservationIgnored private var probing: Set<String> = []
    @ObservationIgnored private var softwareLevels: [String: Double]
    @ObservationIgnored private let writer = DDCWriter()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastBuiltinBrightness: Double?

    static let softwareFloorChoices = [0.05, 0.1, 0.2]

    /// Software dimming never goes fully black, so the screen stays usable.
    var softwareFloor: Double {
        didSet {
            UserDefaults.standard.set(softwareFloor, forKey: Keys.softwareFloor)
            for control in controls.values where control.method == .software {
                applySoftware(control.displayID, control.brightness)
            }
        }
    }

    private enum Keys {
        static let sync = "syncBrightnessWithBuiltin"
        static let softwareLevels = "softwareBrightnessLevels"
        static let softwareFloor = "softwareDimmingFloor"
    }

    private init() {
        syncWithBuiltin = UserDefaults.standard.bool(forKey: Keys.sync)
        softwareLevels = UserDefaults.standard.dictionary(forKey: Keys.softwareLevels) as? [String: Double] ?? [:]
        softwareFloor = UserDefaults.standard.object(forKey: Keys.softwareFloor) as? Double ?? 0.1
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { BrightnessStore.shared.poll() }
        }
    }

    // MARK: Display list

    /// Called whenever the physical display list changes.
    func sync(with displays: [PhysicalDisplay]) {
        let keys = Set(displays.map(\.key))
        for key in controls.keys where !keys.contains(key) {
            controls[key] = nil
            ddc[key] = nil
        }

        var needsDDC: [PhysicalDisplay] = []
        for display in displays {
            if let control = controls[display.key], control.displayID == display.id {
                // macOS resets gamma on reconfiguration; put software dimming back.
                if control.method == .software { applySoftware(display.id, control.brightness) }
                continue
            }
            if PrivateDisplayAPI.supportsNativeBrightness(display.id) {
                let value = Double(PrivateDisplayAPI.nativeBrightness(display.id) ?? 1)
                controls[display.key] = DisplayControl(displayID: display.id, method: .native, brightness: value)
            } else if !probing.contains(display.key) {
                needsDDC.append(display)
            }
        }
        if !needsDDC.isEmpty { probeDDC(needsDDC) }
    }

    /// IORegistry walk and DDC reads are slow; do them on the DDC queue.
    private func probeDDC(_ displays: [PhysicalDisplay]) {
        for display in displays { probing.insert(display.key) }
        let ids = displays.map(\.id)
        writer.perform {
            let services = DDCService.services(for: ids)
            var results: [CGDirectDisplayID: DDCReadout] = [:]
            for (id, service) in services {
                guard let brightness = service.read(.brightness) else { continue }
                var readout = DDCReadout(service: service, values: [.brightness: brightness])
                for code in [DDCService.VCP.contrast, .volume, .mute, .inputSource] {
                    if let value = service.read(code) { readout.values[code] = value }
                }
                results[id] = readout
            }
            let readouts = results
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BrightnessStore.shared.finishProbe(displays, results: readouts)
                }
            }
        }
    }

    private func finishProbe(
        _ displays: [PhysicalDisplay],
        results: [CGDirectDisplayID: DDCReadout]
    ) {
        for display in displays {
            probing.remove(display.key)
            if let readout = results[display.id], let brightness = readout.values[.brightness] {
                ddc[display.key] = (readout.service, readout.values.mapValues(\.max))
                let fraction = { (code: DDCService.VCP) in readout.values[code].map { Double($0.current) / Double($0.max) } }
                var control = DisplayControl(displayID: display.id, method: .ddc,
                                             brightness: Double(brightness.current) / Double(brightness.max))
                control.volume = fraction(.volume)
                control.contrast = fraction(.contrast)
                // MCCS mute: 1 = muted, 2 = unmuted.
                control.muted = readout.values[.mute].map { $0.current == 1 }
                control.inputSource = readout.values[.inputSource].map { $0.current & 0xFF }
                controls[display.key] = control
            } else {
                let level = softwareLevels[display.key] ?? 1
                controls[display.key] = DisplayControl(displayID: display.id, method: .software, brightness: level)
                applySoftware(display.id, level)
            }
        }
    }

    // MARK: Changes

    func setBrightness(_ key: String, _ value: Double) {
        guard var control = controls[key] else { return }
        let value = min(max(value, 0), 1)
        control.brightness = value
        controls[key] = control

        switch control.method {
        case .native:
            PrivateDisplayAPI.setNativeBrightness(control.displayID, Float(value))
            if CGDisplayIsBuiltin(control.displayID) != 0 {
                lastBuiltinBrightness = value
                if syncWithBuiltin { propagateBuiltin(value) }
            }
        case .ddc:
            guard let entry = ddc[key], let maxValue = entry.max[.brightness] else { return }
            writer.write(key: key, service: entry.service, code: .brightness, value: UInt16((value * Double(maxValue)).rounded()))
        case .software:
            applySoftware(control.displayID, value)
            softwareLevels[key] = value
            UserDefaults.standard.set(softwareLevels, forKey: Keys.softwareLevels)
        }
    }

    func setContrast(_ key: String, _ value: Double) {
        guard var control = controls[key], control.contrast != nil,
              let entry = ddc[key], let maxValue = entry.max[.contrast] else { return }
        let value = min(max(value, 0), 1)
        control.contrast = value
        controls[key] = control
        writer.write(key: key, service: entry.service, code: .contrast, value: UInt16((value * Double(maxValue)).rounded()))
    }

    func setMuted(_ key: String, _ muted: Bool) {
        guard var control = controls[key], control.muted != nil, let entry = ddc[key] else { return }
        control.muted = muted
        controls[key] = control
        writer.write(key: key, service: entry.service, code: .mute, value: muted ? 1 : 2)
    }

    func setInputSource(_ key: String, _ input: UInt16) {
        guard var control = controls[key], let entry = ddc[key] else { return }
        control.inputSource = input
        controls[key] = control
        writer.write(key: key, service: entry.service, code: .inputSource, value: input)
    }

    func setVolume(_ key: String, _ value: Double) {
        guard var control = controls[key], control.volume != nil,
              let entry = ddc[key], let maxValue = entry.max[.volume] else { return }
        let value = min(max(value, 0), 1)
        control.volume = value
        controls[key] = control
        writer.write(key: key, service: entry.service, code: .volume, value: UInt16((value * Double(maxValue)).rounded()))
    }

    /// Hot key step for the display under the cursor. A virtual display maps to
    /// the monitor mirroring it, or to the built-in panel.
    func step(by delta: Double) {
        let point = NSEvent.mouseLocationInDisplaySpace
        var count: UInt32 = 0
        var id: CGDirectDisplayID = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        let entry = controls.first { $0.value.displayID == id }
            ?? controls.first { CGDisplayMirrorsDisplay($0.value.displayID) == id && id != 0 }
            ?? controls.first { CGDisplayIsBuiltin($0.value.displayID) != 0 }
        guard let (key, control) = entry else { return }
        setBrightness(key, control.brightness + delta)
    }

    /// Undo software dimming, e.g. on quit.
    func restoreGamma() {
        CGDisplayRestoreColorSyncSettings()
    }

    private func applySoftware(_ id: CGDirectDisplayID, _ value: Double) {
        let level = Float(softwareFloor + (1 - softwareFloor) * value)
        CGSetDisplayTransferByFormula(id, 0, level, 1, 0, level, 1, 0, level, 1)
    }

    // MARK: Polling

    /// Picks up changes made with the brightness keys or Control Center,
    /// and drives "sync with built-in".
    private func poll() {
        for (key, control) in controls where control.method == .native {
            guard let value = PrivateDisplayAPI.nativeBrightness(control.displayID).map(Double.init),
                  abs(value - control.brightness) > 0.005 else { continue }
            controls[key]?.brightness = value
        }
        guard syncWithBuiltin,
              let builtin = controls.values.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else { return }
        if let last = lastBuiltinBrightness, abs(last - builtin.brightness) < 0.005 { return }
        lastBuiltinBrightness = builtin.brightness
        propagateBuiltin(builtin.brightness)
    }

    private func propagateBuiltin(_ value: Double) {
        for (key, control) in controls where CGDisplayIsBuiltin(control.displayID) == 0 {
            setBrightness(key, value)
        }
    }
}

/// Serial DDC queue that only sends the latest value per display and VCP code,
/// so dragging a slider does not pile up slow I2C writes.
final class DDCWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "doppio.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [String: (service: DDCService, code: DDCService.VCP, value: UInt16)] = [:]
    private var isDraining = false

    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    func write(key: String, service: DDCService, code: DDCService.VCP, value: UInt16) {
        let shouldStart: Bool = lock.withLock {
            pending["\(key)#\(code.rawValue)"] = (service, code, value)
            defer { isDraining = true }
            return !isDraining
        }
        if shouldStart { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            let next: (service: DDCService, code: DDCService.VCP, value: UInt16)? = lock.withLock {
                guard let (key, item) = pending.first else {
                    isDraining = false
                    return nil
                }
                pending[key] = nil
                return item
            }
            guard let next else { return }
            next.service.write(next.code, next.value)
        }
    }
}

extension NSEvent {
    /// Cursor position in CoreGraphics display space (top-left origin).
    static var mouseLocationInDisplaySpace: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
