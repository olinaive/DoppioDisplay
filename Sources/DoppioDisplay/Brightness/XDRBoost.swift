import AppKit
import IOKit.ps
import Metal
import Observation
import QuartzCore

/// Extra brightness for XDR panels (MacBook Pro M1 Pro and later).
///
/// 1. A 1×1 px window with EDR content asks WindowServer for HDR headroom.
/// 2. Once the panel has headroom (> 1.0), the built-in display's gamma table
///    is scaled above 1.0, so all SDR content is rendered brighter.
/// Public APIs only. HDR video clips while active; the system may cap the
/// headroom when the Mac gets hot.
@MainActor
@Observable
final class XDRBoost {
    static let shared = XDRBoost()

    enum State: Equatable {
        case off
        case waitingForHDR
        case pausedOnBattery
        case active(factor: Double)
    }

    static let maxFactorChoices = [1.3, 1.6, 2.0]

    /// Upper bound of the boost. Full-screen SDR at ~1.6× stays within what XDR panels sustain.
    var maxFactor: Double {
        didSet {
            UserDefaults.standard.set(maxFactor, forKey: Keys.maxFactor)
            tick()
        }
    }

    /// Pause the boost while running on battery.
    var offOnBattery: Bool {
        didSet {
            UserDefaults.standard.set(offOnBattery, forKey: Keys.offOnBattery)
            tick()
        }
    }

    private(set) var state: State = .off

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    /// 0...1 of the available boost.
    var level: Double {
        didSet {
            UserDefaults.standard.set(level, forKey: Keys.level)
            tick()
        }
    }

    @ObservationIgnored private var trigger: EDRTriggerWindow?
    @ObservationIgnored private var baseTable: GammaTable?
    @ObservationIgnored private var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    @ObservationIgnored private var appliedFactor = 1.0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    private enum Keys {
        static let enabled = "xdrBoostEnabled"
        static let level = "xdrBoostLevel"
        static let maxFactor = "xdrBoostMaxFactor"
        static let offOnBattery = "xdrBoostOffOnBattery"
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        level = UserDefaults.standard.object(forKey: Keys.level) as? Double ?? 1
        maxFactor = UserDefaults.standard.object(forKey: Keys.maxFactor) as? Double ?? 1.6
        offOnBattery = UserDefaults.standard.object(forKey: Keys.offOnBattery) as? Bool ?? true
    }

    /// Restores a boost that was on when the app quit.
    func resume() {
        if isEnabled { start() }
    }

    static var builtinScreen: NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
    }

    /// XDR panels report a potential headroom of 16; ordinary panels report 1–2.
    static var isSupported: Bool {
        (builtinScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 2
    }

    private func start() {
        guard timer == nil else { return }
        state = .waitingForHDR
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { XDRBoost.shared.screensChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { XDRBoost.shared.tick() }
        }
        screensChanged()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        restoreGamma()
        trigger?.close()
        trigger = nil
        baseTable = nil
        displayID = kCGNullDirectDisplay
        state = .off
    }

    /// Lid closed, resolution change, display reconnected: rebuild against the current screen.
    private func screensChanged() {
        guard let screen = Self.builtinScreen else {
            restoreGamma()
            trigger?.close()
            trigger = nil
            baseTable = nil
            displayID = kCGNullDirectDisplay
            state = .waitingForHDR
            return
        }
        if screen.displayID != displayID {
            restoreGamma()
            displayID = screen.displayID
            baseTable = GammaTable.read(displayID)
        }
        if trigger == nil { trigger = EDRTriggerWindow() }
        trigger?.place(on: screen)
        tick()
    }

    private func tick() {
        guard isEnabled, displayID != kCGNullDirectDisplay, let screen = Self.builtinScreen, let baseTable else { return }
        trigger?.render()

        if offOnBattery && Self.isOnBattery {
            restoreGamma()
            state = .pausedOnBattery
            return
        }
        let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        guard headroom > 1.05 else {
            // Without headroom a scaled table would just clip highlights.
            restoreGamma()
            state = .waitingForHDR
            return
        }
        let factor = 1 + level * (min(headroom, maxFactor) - 1)
        // macOS resets the table on wake, Night Shift updates and the like:
        // take its new table as the base and scale that.
        var base = baseTable
        let drifted = appliedFactor != 1 && !base.isApplied(displayID, factor: appliedFactor)
        if drifted, let fresh = GammaTable.read(displayID) {
            base = fresh
            self.baseTable = fresh
        }
        if drifted || abs(factor - appliedFactor) > 0.005 {
            base.apply(displayID, factor: factor)
            appliedFactor = factor
        }
        state = .active(factor: factor)
    }

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }

    private func restoreGamma() {
        guard let baseTable, displayID != kCGNullDirectDisplay, appliedFactor != 1 else { return }
        baseTable.apply(displayID, factor: 1)
        appliedFactor = 1
    }
}

/// Snapshot of a display's gamma table, scaled on demand.
struct GammaTable {
    private static let size: UInt32 = 256
    private var red: [CGGammaValue]
    private var green: [CGGammaValue]
    private var blue: [CGGammaValue]

    static func read(_ id: CGDirectDisplayID) -> GammaTable? {
        var table = GammaTable(
            red: .init(repeating: 0, count: Int(size)),
            green: .init(repeating: 0, count: Int(size)),
            blue: .init(repeating: 0, count: Int(size))
        )
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, size, &table.red, &table.green, &table.blue, &count) == .success,
              count > 0 else { return nil }
        table.red.removeLast(Int(size - count))
        table.green.removeLast(Int(size - count))
        table.blue.removeLast(Int(size - count))
        return table
    }

    @discardableResult
    func apply(_ id: CGDirectDisplayID, factor: Double) -> CGError {
        let f = CGGammaValue(factor)
        let r = red.map { $0 * f }, g = green.map { $0 * f }, b = blue.map { $0 * f }
        return CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b)
    }

    /// Compares the table's top end with what we last set.
    func isApplied(_ id: CGDirectDisplayID, factor: Double) -> Bool {
        guard let current = GammaTable.read(id), let expected = red.last, let actual = current.red.last else { return false }
        return abs(actual - expected * CGGammaValue(factor)) < 0.01
    }
}

/// Invisible 1×1 px window whose EDR pixel keeps the panel in HDR mode.
final class EDRTriggerWindow: NSWindow {
    static let requestedHeadroom: CGFloat = 2
    private let metalLayer = CAMetalLayer()
    private let queue: MTLCommandQueue?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)

        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = .none

        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        // macOS 26+: EDR is granted to layers that ask for high dynamic range
        // and tag how much headroom their drawables use.
        metalLayer.preferredDynamicRange = .high
        metalLayer.contentsHeadroom = Self.requestedHeadroom
        metalLayer.isOpaque = false
        metalLayer.drawableSize = CGSize(width: 1, height: 1)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.layer = metalLayer
        view.wantsLayer = true
        contentView = view
    }

    func place(on screen: NSScreen) {
        setFrame(NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1), display: false)
        orderFrontRegardless()
        render()
    }

    /// Clears the single pixel to an EDR value above 1.0.
    func render() {
        guard let queue, let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let value = Double(Self.requestedHeadroom)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? kCGNullDirectDisplay
    }
}
