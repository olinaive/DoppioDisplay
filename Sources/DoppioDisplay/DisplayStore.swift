import AppKit
import IOKit.pwr_mgt
import Observation
import ScreenCaptureKit
import ServiceManagement

/// Single source of truth: persisted configs, the live virtual displays,
/// mirror state and preview windows. Keeps reality in sync with the configs
/// whenever displays are reconfigured or the Mac wakes up.
@MainActor
@Observable
final class DisplayStore {
    static let shared = DisplayStore()

    private(set) var configs: [VirtualDisplayConfig] = []
    private(set) var physicalDisplays: [PhysicalDisplay] = []
    private(set) var liveIDs: [UUID: CGDirectDisplayID] = [:]
    private(set) var previewStates: [PreviewSource: PreviewState] = [:]
    /// Bumped when arrangement or the main display changes, so views re-read display bounds.
    private(set) var layoutRevision = 0
    /// True while some virtual display asks to keep the Mac awake.
    private(set) var isKeepingAwake = false
    @ObservationIgnored private var awakeAssertion: IOPMAssertionID = 0
    var lastError: String?

    var restoreOnLaunch: Bool {
        didSet { UserDefaults.standard.set(restoreOnLaunch, forKey: Keys.restoreOnLaunch) }
    }
    var previewOnCreate: Bool {
        didSet { UserDefaults.standard.set(previewOnCreate, forKey: Keys.previewOnCreate) }
    }
    /// Size and HiDPI for newly created virtual displays.
    var defaultPreset: DisplayPreset {
        didSet {
            UserDefaults.standard.set(Int(defaultPreset.width), forKey: Keys.defaultWidth)
            UserDefaults.standard.set(Int(defaultPreset.height), forKey: Keys.defaultHeight)
        }
    }
    var defaultHiDPI: Bool {
        didSet { UserDefaults.standard.set(defaultHiDPI, forKey: Keys.defaultHiDPI) }
    }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private var displays: [UUID: VirtualDisplay] = [:]
    @ObservationIgnored private var previews: [PreviewSource: PreviewWindowController] = [:]
    /// "virtualID->targetID" pairs already tried, so a failing mirror does not loop.
    @ObservationIgnored private var attemptedMirrors: Set<String> = []
    @ObservationIgnored private var reconcileScheduled = false

    private enum Keys {
        static let configs = "virtualDisplayConfigs"
        static let restoreOnLaunch = "restoreOnLaunch"
        static let previewOnCreate = "previewOnCreate"
        static let defaultWidth = "defaultVirtualWidth"
        static let defaultHeight = "defaultVirtualHeight"
        static let defaultHiDPI = "defaultVirtualHiDPI"
    }

    private init() {
        let defaults = UserDefaults.standard
        restoreOnLaunch = defaults.object(forKey: Keys.restoreOnLaunch) as? Bool ?? true
        previewOnCreate = defaults.object(forKey: Keys.previewOnCreate) as? Bool ?? true
        defaultPreset = DisplayPreset(
            width: UInt32(defaults.object(forKey: Keys.defaultWidth) as? Int ?? 1920),
            height: UInt32(defaults.object(forKey: Keys.defaultHeight) as? Int ?? 1080)
        )
        defaultHiDPI = defaults.object(forKey: Keys.defaultHiDPI) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.configs),
           let saved = try? JSONDecoder().decode([VirtualDisplayConfig].self, from: data) {
            configs = saved
        }
    }

    func start() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayStore.shared.scheduleReconcile() }
        }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DisplayStore.shared.scheduleReconcile(after: 1.5) }
        }

        guard VirtualDisplay.isSupported else {
            lastError = "This macOS version no longer exposes CGVirtualDisplay."
            return
        }
        if !restoreOnLaunch {
            for index in configs.indices { configs[index].isEnabled = false }
            save()
        }
        reconcile()
    }

    /// Undo mirrors and remove displays, but keep `isEnabled` so the next launch restores them.
    func shutdown() {
        for id in Array(displays.keys) { teardown(id) }
        if isKeepingAwake { IOPMAssertionRelease(awakeAssertion) }
    }

    // MARK: Queries

    func config(_ id: UUID) -> VirtualDisplayConfig? {
        configs.first { $0.id == id }
    }

    func isLive(_ id: UUID) -> Bool { liveIDs[id] != nil }

    func previewState(_ id: UUID) -> PreviewState { previewState(.virtual(id)) }

    func previewState(_ source: PreviewSource) -> PreviewState { previewStates[source] ?? .closed }

    /// Monitors that can mirror a virtual display; the built-in panel hosts the preview.
    var mirrorCandidates: [PhysicalDisplay] { physicalDisplays.filter { !$0.isBuiltin } }

    func isMirroring(_ id: UUID, to target: PhysicalDisplay) -> Bool {
        guard let vid = liveIDs[id] else { return false }
        return target.mirrorMaster == vid
    }

    // MARK: Config changes

    func addDisplay(_ customize: (inout VirtualDisplayConfig) -> Void = { _ in }) {
        var config = VirtualDisplayConfig.makeDefault(index: configs.count + 1)
        config.width = defaultPreset.width
        config.height = defaultPreset.height
        config.hiDPI = defaultHiDPI
        customize(&config)
        configs.append(config)
        save()
        createDisplay(for: config, openPreview: previewOnCreate)
    }

    func remove(_ id: UUID) {
        teardown(id)
        configs.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        update(id) { $0.isEnabled = enabled }
    }

    func setResolution(_ id: UUID, width: UInt32, height: UInt32) {
        guard width >= 640, height >= 480, width <= 7680, height <= 4320 else {
            lastError = "Resolution must be between 640×480 and 7680×4320."
            return
        }
        update(id) {
            $0.width = width
            $0.height = height
        }
    }

    func update(_ id: UUID, _ change: (inout VirtualDisplayConfig) -> Void) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        let old = configs[index]
        change(&configs[index])
        let new = configs[index]
        save()

        if !new.isEnabled {
            teardown(id)
        } else if displays[id] == nil {
            createDisplay(for: new, openPreview: previewOnCreate)
        } else if new.needsRecreate(comparedTo: old) {
            recreate(id)
        } else if new.placement != old.placement || new.relativeOrigin != old.relativeOrigin, let vid = liveIDs[id] {
            report(DisplayLayout.apply(new, to: vid), "Arrange")
            refreshPhysical()
        } else if new.keepAwake != old.keepAwake {
            updateKeepAwake()
        }
    }

    /// Makes the virtual displays match a profile: removes extras, updates
    /// existing ones in place (recreating only when size, HiDPI or Hz differ)
    /// and creates missing ones.
    func apply(configs wanted: [VirtualDisplayConfig]) {
        let wantedIDs = Set(wanted.map(\.id))
        for config in configs where !wantedIDs.contains(config.id) {
            remove(config.id)
        }
        for config in wanted {
            if self.config(config.id) != nil {
                update(config.id) { $0 = config }
            } else {
                configs.append(config)
                save()
                if config.isEnabled { createDisplay(for: config, openPreview: false) }
            }
        }
        configs.sort { a, b in
            (wanted.firstIndex { $0.id == a.id } ?? .max) < (wanted.firstIndex { $0.id == b.id } ?? .max)
        }
        save()
    }

    var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    /// One power assertion covers every virtual display that wants the Mac awake.
    private func updateKeepAwake() {
        let wanted = configs.contains { config in
            guard let vid = liveIDs[config.id] else { return false }
            switch config.keepAwake {
            case .never: return false
            case .whileOn: return true
            case .whileMirroring: return physicalDisplays.contains { $0.mirrorMaster == vid }
            }
        }
        guard wanted != isKeepingAwake else { return }
        if wanted {
            let created = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "DoppioDisplay keeps a virtual display in use" as CFString, &awakeAssertion
            )
            isKeepingAwake = created == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
            isKeepingAwake = false
        }
    }

    /// Swaps width and height. Real rotation is not available for virtual displays.
    func setPortrait(_ id: UUID, _ portrait: Bool) {
        guard let config = config(id), config.isPortrait != portrait else { return }
        setResolution(id, width: config.height, height: config.width)
    }

    /// Saves where a virtual display sits, relative to the built-in panel, and moves it there.
    func setPosition(_ id: UUID, relativeOrigin: CGPoint) {
        update(id) { $0.relativeOrigin = relativeOrigin }
    }

    /// Changes a physical display's mode (resolution / refresh rate).
    func setMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) {
        report(DisplayModes.apply(mode, to: display), "Change display mode")
        refreshPhysical()
    }

    /// Makes `display` the main one (menu bar and Dock) and asks to keep it,
    /// reverting after 15 seconds otherwise — the display might not be visible.
    func makeMain(_ display: CGDirectDisplayID) {
        let previous = CGMainDisplayID()
        guard previous != display else { return }
        let error = DisplayLayout.makeMain(display)
        guard error == .success else { return report(error, "Make main display") }
        refreshPhysical()
        layoutRevision += 1

        let alert = NSAlert()
        alert.messageText = "Keep this main display?"
        alert.informativeText = "The menu bar and Dock moved. The previous main display comes back in 15 seconds unless you keep this one."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")
        let timer = Timer(timeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate()
        let response = alert.runModal()
        timer.invalidate()
        if response != .alertFirstButtonReturn {
            DisplayLayout.makeMain(previous)
            refreshPhysical()
            layoutRevision += 1
        }
    }

    func toggleMirror(_ id: UUID, to target: PhysicalDisplay) {
        guard let vid = liveIDs[id] else { return }
        if target.mirrorMaster == vid {
            update(id) { $0.mirrorTargets.removeAll { $0 == target.key } }
            report(DisplayManager.stopMirroring(target.id), "Stop mirroring")
        } else {
            // A monitor can only mirror one display; take it from any other config.
            for index in configs.indices {
                configs[index].mirrorTargets.removeAll { $0 == target.key }
            }
            update(id) { $0.mirrorTargets.append(target.key) }
            attemptedMirrors.remove("\(vid)->\(target.id)")
            report(DisplayManager.mirror(target.id, of: vid), "Mirror")
        }
        refreshPhysical()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Preview

    func showPreview(_ id: UUID) { showPreview(.virtual(id)) }

    func closePreview(_ id: UUID) { closePreview(.virtual(id)) }

    func showPreview(_ source: PreviewSource) {
        if let existing = previews[source] {
            existing.restore()
            return
        }
        guard let target = previewTarget(source) else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            lastError = "Allow DoppioDisplay in System Settings › Privacy & Security › Screen & System Audio Recording, then open the preview again."
            return
        }
        openPreview(source, capture: .display(target.displayID), displayID: target.displayID,
                    title: target.title, aspect: target.aspect)
    }

    /// Window picked in the system picker; the picker grants access itself.
    func showWindowPreview(filter: SCContentFilter, title: String) {
        openPreview(.window(UUID()), capture: .filter(filter), displayID: nil,
                    title: title, aspect: filter.contentRect.size)
    }

    func pickWindowForPreview() {
        WindowPicker.shared.present()
    }

    private func openPreview(_ source: PreviewSource, capture: CaptureTarget, displayID: CGDirectDisplayID?,
                             title: String, aspect: CGSize) {
        let controller = PreviewWindowController(
            source: source, capture: capture, displayID: displayID, title: title, aspect: aspect
        )
        controller.onStateChange = { [weak self, weak controller] state in
            guard let self, let controller, self.previews[source] === controller else { return }
            if state == .closed {
                self.previews[source] = nil
                self.previewStates[source] = nil
            } else {
                self.previewStates[source] = state
            }
            self.updateActivationPolicy()
        }
        previews[source] = controller
        previewStates[source] = .open
        updateActivationPolicy()
        controller.show()
    }

    func closePreview(_ source: PreviewSource) {
        previews[source]?.close()
    }

    func togglePreview(_ source: PreviewSource) {
        if previews[source] == nil { showPreview(source) } else { closePreview(source) }
    }

    private func previewTarget(_ source: PreviewSource) -> (displayID: CGDirectDisplayID, title: String, aspect: CGSize)? {
        switch source {
        case .virtual(let id):
            guard let config = config(id), let vid = liveIDs[id] else { return nil }
            return (vid, "\(config.name) — \(config.resolutionTitle)", CGSize(width: Int(config.width), height: Int(config.height)))
        case .display(let key):
            guard let display = physicalDisplays.first(where: { $0.key == key }) else { return nil }
            let bounds = CGDisplayBounds(display.id)
            return (display.id, display.name, bounds.size)
        case .window:
            // Window previews are opened with their picker filter, never re-resolved.
            return nil
        }
    }

    func restoreMinimizedPreviews() {
        for preview in previews.values where preview.isMinimized {
            preview.restore()
        }
    }

    /// The Dock icon is only needed while a preview window exists (so it can be minimized there).
    private func updateActivationPolicy() {
        let wantsDock = !previews.isEmpty
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    // MARK: Lifecycle of displays

    @discardableResult
    private func createDisplay(for config: VirtualDisplayConfig, openPreview: Bool) -> Bool {
        guard let display = VirtualDisplay(config: config) else {
            lastError = "WindowServer refused \(config.resolutionTitle)\(config.hiDPI ? " HiDPI" : "") @ \(Int(config.refreshRate)) Hz."
            update(config.id) { $0.isEnabled = false }
            return false
        }
        guard display.waitUntilOnline() else {
            display.destroy()
            lastError = "\(config.name) was created but never came online."
            update(config.id) { $0.isEnabled = false }
            return false
        }
        displays[config.id] = display
        liveIDs[config.id] = display.displayID
        DisplayLayout.apply(config, to: display.displayID)
        applyMirrors(for: config.id)
        refreshPhysical()
        if openPreview { showPreview(config.id) }
        return true
    }

    /// Size, HiDPI and refresh rate are baked into the CGVirtualDisplay, so a change rebuilds it.
    private func recreate(_ id: UUID) {
        let hadPreview = previews[.virtual(id)] != nil
        teardown(id)
        guard let config = config(id) else { return }
        createDisplay(for: config, openPreview: hadPreview)
    }

    private func teardown(_ id: UUID) {
        previews[.virtual(id)]?.close()
        guard let display = displays.removeValue(forKey: id) else { return }
        let vid = display.displayID
        // Undo the mirror before the master disappears, or the target can stay blank.
        for target in DisplayManager.physicalDisplays(excluding: []) where target.mirrorMaster == vid {
            DisplayManager.stopMirroring(target.id)
        }
        display.destroy()
        liveIDs[id] = nil
        attemptedMirrors = attemptedMirrors.filter { !$0.hasPrefix("\(vid)->") }
        _ = VirtualDisplay.waitUntilOffline(vid)
        refreshPhysical()
    }

    private func applyMirrors(for id: UUID) {
        guard let config = config(id), let vid = liveIDs[id] else { return }
        for target in DisplayManager.physicalDisplays(excluding: Set(liveIDs.values))
        where config.mirrorTargets.contains(target.key) && target.mirrorMaster != vid {
            let attempt = "\(vid)->\(target.id)"
            guard !attemptedMirrors.contains(attempt) else { continue }
            attemptedMirrors.insert(attempt)
            report(DisplayManager.mirror(target.id, of: vid), "Mirror to \(target.name)")
        }
    }

    // MARK: Reconcile

    private func scheduleReconcile(after delay: TimeInterval = 0.4) {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.reconcileScheduled = false
            self.reconcile()
        }
    }

    /// Brings live state in line with the configs: recreates displays that
    /// vanished (e.g. WindowServer restart) and re-applies mirrors for monitors
    /// that came back after sleep or replugging.
    private func reconcile() {
        for config in configs where config.isEnabled {
            if let display = displays[config.id], !display.isOnline {
                displays[config.id] = nil
                liveIDs[config.id] = nil
            }
            if displays[config.id] == nil {
                createDisplay(for: config, openPreview: previewOnCreate)
            } else {
                applyMirrors(for: config.id)
            }
        }
        refreshPhysical()
    }

    private func refreshPhysical() {
        physicalDisplays = DisplayManager.physicalDisplays(excluding: Set(liveIDs.values))
        layoutRevision += 1
        BrightnessStore.shared.sync(with: physicalDisplays)
        updateKeepAwake()
        ProfileStore.shared.externalDisplaysChanged(physicalDisplays.filter { !$0.isBuiltin })
    }

    private func report(_ error: CGError, _ action: String) {
        if error != .success { lastError = "\(action) failed (CGError \(error.rawValue))." }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Keys.configs)
        }
    }
}
