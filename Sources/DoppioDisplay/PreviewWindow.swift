import AppKit
import CoreImage
import Observation
import QuartzCore
import SwiftUI

/// Picture-in-picture window for a display or a window: borderless look,
/// glass toolbar on hover, crop / rotate / flip, adjustable frame rate,
/// minimizes to the Dock (capture pauses, or keeps a live thumbnail).
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let previewView: PreviewView
    private let capture: DisplayCapture
    private let target: CaptureTarget
    /// Display actually being captured: the previewed one, or the display it mirrors.
    /// Capturing a mirror itself shows its old desktop flickering through.
    private var capturedDisplay: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private let model: PreviewModel
    private var contentAspect: CGSize
    private var isClosed = false
    private var lastThumbnail = Date.distantPast
    private lazy var ciContext = CIContext()

    var onStateChange: ((PreviewState) -> Void)?

    init(source: PreviewSource, capture target: CaptureTarget, displayID: CGDirectDisplayID?, title: String, aspect: CGSize) {
        self.target = target
        contentAspect = aspect
        model = PreviewModel(source: source, displayID: displayID)
        previewView = PreviewView(model: model)
        capture = DisplayCapture(layer: previewView.frameLayer)

        let host = XDRBoost.builtinScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 520
        let height = width * aspect.height / aspect.width
        let visible = host.visibleFrame
        let frame = NSRect(x: visible.maxX - width - 20, y: visible.minY + 20, width: width, height: height)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = PreviewSettings.keepOnTop ? .floating : .normal
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.contentView = previewView
        window.delegate = self
        // Remember position and width per source.
        window.setFrameAutosaveName(source.autosaveName)
        applyAspect()

        model.framesPerSecond = PreviewSettings.framesPerSecond
        model.isPinned = PreviewSettings.keepOnTop
        model.actions = PreviewActions(
            togglePin: { [weak self] in self?.togglePin() },
            toggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            beginCrop: { [weak self] in self?.previewView.beginCropSelection() },
            resetCrop: { [weak self] in self?.updateGeometry { $0.crop = CGRect(x: 0, y: 0, width: 1, height: 1) } },
            rotate: { [weak self] turns in self?.updateGeometry { $0.quarterTurns = ($0.quarterTurns + turns + 4) % 4 } },
            flip: { [weak self] in self?.updateGeometry { $0.flipped.toggle() } },
            setFrameRate: { [weak self] fps in self?.setFrameRate(fps) }
        )
        previewView.onCropSelected = { [weak self] rect in
            self?.updateGeometry { $0.cropToViewRect(rect) }
        }
        previewView.onHoverChange = { [weak self] hovering in
            guard let self, !self.model.isFullScreen else { return }
            self.setTrafficLightsVisible(hovering)
        }
        setTrafficLightsVisible(false)
        // The green button goes full screen (instead of zooming), like in other apps.
        if let zoom = window.standardWindowButton(.zoomButton) {
            zoom.target = self
            zoom.action = #selector(fullScreenButton(_:))
        }

        capture.onStop = { [weak self] error in
            if let error { NSLog("DoppioDisplay: capture stopped: \(error.localizedDescription)") }
            self?.close()
        }
        capture.onFrame = { [weak self] surface in
            self?.updateDockThumbnail(surface)
        }
    }

    var isMinimized: Bool { window.isMiniaturized }

    func show() {
        window.orderFrontRegardless()
        startCapture()
    }

    func restore() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
    }

    func close() {
        guard !isClosed else { return }
        window.close()
    }

    // MARK: Geometry

    private func updateGeometry(_ change: (inout PreviewGeometry) -> Void) {
        var geometry = model.geometry
        change(&geometry)
        // Ignore accidental tiny selections.
        guard geometry.crop.width > 0.03, geometry.crop.height > 0.03 else { return }
        let cropChanged = geometry.crop != model.geometry.crop
        let turnsChanged = geometry.quarterTurns != model.geometry.quarterTurns
        model.geometry = geometry
        applyAspect()
        previewView.needsLayout = true
        if cropChanged || turnsChanged {
            let crop = geometry.isCropped ? geometry.crop : nil
            let width = shownPixelWidth
            Task {
                await capture.setCrop(crop)
                await capture.setMaxWidth(width)
            }
        }
    }

    /// Keeps the window's width and fits its height to the shown content.
    private func applyAspect() {
        let aspect = model.geometry.aspect(for: contentAspect)
        guard aspect.width > 0, aspect.height > 0 else { return }
        var frame = window.frame
        let contentWidth = window.contentRect(forFrameRect: frame).width
        let newContent = NSSize(width: contentWidth, height: contentWidth * aspect.height / aspect.width)
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContent))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.contentAspectRatio = aspect
        window.contentMinSize = NSSize(width: 160, height: 160 * aspect.height / aspect.width)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func setFrameRate(_ fps: Int) {
        model.framesPerSecond = fps
        PreviewSettings.framesPerSecond = fps
        Task { await capture.setFramesPerSecond(fps) }
    }

    @objc private func fullScreenButton(_ sender: Any?) {
        toggleFullScreen()
    }

    /// Native full screen in its own Space. Floating, all-Spaces windows cannot go full
    /// screen, so those traits are dropped on the way in and restored on the way out.
    func toggleFullScreen() {
        if !window.styleMask.contains(.fullScreen) {
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
            // A fixed aspect ratio would fight the screen's own shape.
            window.resizeIncrements = NSSize(width: 1, height: 1)
        }
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
        // The title bar slides in at the top edge in full screen; its buttons must be visible there.
        setTrafficLightsVisible(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
        setTrafficLightsVisible(model.isHovering)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = model.isPinned ? .floating : .normal
        applyAspect()
    }

    private func togglePin() {
        window.level = window.level == .floating ? .normal : .floating
        model.isPinned = window.level == .floating
    }

    private func setTrafficLightsVisible(_ visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// What to capture right now, following mirroring.
    private var effectiveTarget: CaptureTarget {
        guard case .display(let id) = target else { return target }
        let master = CGDisplayMirrorsDisplay(id)
        return .display(master == kCGNullDirectDisplay ? id : master)
    }

    private func observeMirroring() {
        guard case .display = target, screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMirroring() }
        }
    }

    /// The captured display switched mode: show its new title, pick up the new aspect.
    func displayChanged(title: String) {
        window.title = title
        restartCapture()
    }

    /// Rebuilds the capture, e.g. so a new software-mirror window on this display is included.
    func restartCapture() {
        guard !isClosed, !window.isMiniaturized else { return }
        Task { @MainActor in
            await capture.stop()
            startCapture()
        }
    }

    /// Restarts the capture on the right display when mirroring starts or stops.
    private func followMirroring() {
        guard case .display(let wanted) = effectiveTarget, wanted != capturedDisplay,
              !isClosed, !window.isMiniaturized else { return }
        Task { @MainActor in
            await capture.stop()
            startCapture()
        }
    }

    private func startCapture() {
        observeMirroring()
        let current = effectiveTarget
        if case .display(let id) = current { capturedDisplay = id }
        Task { @MainActor in
            do {
                await capture.setFramesPerSecond(model.framesPerSecond)
                await capture.setMaxWidth(shownPixelWidth)
                try await capture.start(current)
                if contentAspect != capture.contentSize, capture.contentSize.width > 0 {
                    contentAspect = capture.contentSize
                    applyAspect()
                }
            } catch {
                close()
                DisplayStore.shared.lastError = "Preview failed: \(error.localizedDescription)"
            }
        }
    }

    /// Width of the preview in pixels along the content's own width (rotation swaps axes).
    private var shownPixelWidth: Int {
        let size = previewView.bounds.size
        let along = model.geometry.quarterTurns.isMultiple(of: 2) ? size.width : size.height
        // Divide by the crop so a cropped region is still captured sharply.
        let scale = window.backingScaleFactor / max(model.geometry.crop.width, 0.05)
        return Int((along * scale).rounded(.up))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let width = shownPixelWidth
        Task { await capture.setMaxWidth(width) }
    }

    // MARK: Dock thumbnail

    private func updateDockThumbnail(_ surface: IOSurface) {
        guard window.isMiniaturized, Date().timeIntervalSince(lastThumbnail) > 0.9 else { return }
        lastThumbnail = Date()
        let image = CIImage(ioSurface: surface)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        window.miniwindowImage = NSImage(cgImage: cgImage, size: NSSize(width: 256, height: 256 * image.extent.height / image.extent.width))
    }

    // MARK: NSWindowDelegate

    func windowDidMiniaturize(_ notification: Notification) {
        if PreviewSettings.liveDockThumbnail {
            // A couple of frames per second keep the Dock thumbnail alive cheaply.
            Task { await capture.setFramesPerSecond(2) }
        } else {
            Task { await capture.stop() }
        }
        onStateChange?(.minimized)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        window.miniwindowImage = nil
        if capture.isRunning {
            Task { await capture.setFramesPerSecond(model.framesPerSecond) }
        } else {
            startCapture()
        }
        onStateChange?(.open)
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        Task { await capture.stop() }
        onStateChange?(.closed)
    }
}

struct PreviewActions {
    var togglePin: () -> Void = {}
    var toggleFullScreen: () -> Void = {}
    var beginCrop: () -> Void = {}
    var resetCrop: () -> Void = {}
    var rotate: (Int) -> Void = { _ in }
    var flip: () -> Void = {}
    var setFrameRate: (Int) -> Void = { _ in }
}

/// State shared by the preview view and its SwiftUI toolbar.
@MainActor
@Observable
final class PreviewModel {
    let source: PreviewSource
    /// Nil for window previews.
    let displayID: CGDirectDisplayID?
    var geometry = PreviewGeometry()
    var framesPerSecond = 60
    var isHovering = false
    var isPinned = true
    var isSelectingCrop = false
    var isFullScreen = false
    @ObservationIgnored var actions = PreviewActions()

    init(source: PreviewSource, displayID: CGDirectDisplayID?) {
        self.source = source
        self.displayID = displayID
    }
}

/// Layer-backed view showing the captured frames.
/// Plain click and drag: moves the window.
/// Double-click: full screen.
final class PreviewView: NSView {
    private let model: PreviewModel
    let frameLayer = CALayer()
    private var toolbar: ToolbarHostingView<PreviewToolbar>!
    private let selectionLayer = CAShapeLayer()
    private var selectionStart: CGPoint?

    var onHoverChange: ((Bool) -> Void)?
    var onCropSelected: ((CGRect) -> Void)?

    init(model: PreviewModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        // Frames go into a plain sublayer below the toolbar's layer.
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layer?.insertSublayer(frameLayer, at: 0)

        selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)

        toolbar = ToolbarHostingView(rootView: PreviewToolbar(model: model))
        toolbar.isActive = { [weak self] in
            guard let self else { return false }
            return self.model.isHovering && !self.model.isSelectingCrop
        }
        toolbar.sizingOptions = [.intrinsicContentSize]
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // Rotate and flip the frame layer around the view centre.
        let geometry = model.geometry
        let size = geometry.quarterTurns.isMultiple(of: 2) ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        frameLayer.bounds = CGRect(origin: .zero, size: size)
        frameLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeRotation(-CGFloat(geometry.quarterTurns) * .pi / 2, 0, 0, 1)
        if geometry.flipped { transform = CATransform3DConcat(transform, CATransform3DMakeScale(-1, 1, 1)) }
        frameLayer.transform = transform
        selectionLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func cursorUpdate(with event: NSEvent) {
        (model.isSelectingCrop ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    private func setHovering(_ hovering: Bool) {
        withAnimation(.easeOut(duration: 0.18)) { model.isHovering = hovering }
        onHoverChange?(hovering)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Crop selection

    func beginCropSelection() {
        model.isSelectingCrop = true
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    private func endCropSelection() {
        model.isSelectingCrop = false
        selectionStart = nil
        selectionLayer.isHidden = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        if model.isSelectingCrop, event.keyCode == 53 {
            endCropSelection()
        } else if model.isFullScreen, event.keyCode == 53 {
            model.actions.toggleFullScreen()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.isSelectingCrop, let start = selectionStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionLayer.path = CGPath(rect: CGRect(start: start, end: point), transform: nil)
        selectionLayer.isHidden = false
    }

    override func mouseUp(with event: NSEvent) {
        guard model.isSelectingCrop, let start = selectionStart else { return }
        let rect = CGRect(start: start, end: convert(event.locationInWindow, from: nil))
        endCropSelection()
        guard bounds.width > 0, bounds.height > 0, rect.width > 8, rect.height > 8 else { return }
        // To normalized view space with a top-left origin.
        onCropSelected?(CGRect(
            x: rect.minX / bounds.width, y: 1 - rect.maxY / bounds.height,
            width: rect.width / bounds.width, height: rect.height / bounds.height
        ))
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        if model.isSelectingCrop {
            selectionStart = convert(event.locationInWindow, from: nil)
            return
        }
        // Double-click toggles full screen; a plain drag moves the window.
        if event.clickCount == 2 {
            model.actions.toggleFullScreen()
        } else {
            window?.performDrag(with: event)
        }
    }
}

private extension CGRect {
    init(start: CGPoint, end: CGPoint) {
        self.init(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    }
}

/// Lets clicks fall through to the preview while the toolbar is hidden.
final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
    var isActive: () -> Bool = { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive() ? super.hitTest(point) : nil
    }
}

struct PreviewToolbar: View {
    let model: PreviewModel
    private var store: DisplayStore { .shared }

    var body: some View {
        VStack(spacing: 8) {
            if model.isSelectingCrop {
                banner("Drag to select an area · ⎋ to cancel", systemImage: "crop")
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if case .virtual(let id) = model.source, let config = store.config(id) {
                        ResolutionMenu(config: config)
                        MirrorMenu(config: config, compact: true)
                    }
                    viewMenu
                    Button(action: model.actions.togglePin) {
                        Image(systemName: model.isPinned ? "pin.fill" : "pin.slash")
                    }
                    .help(model.isPinned ? "Stop keeping on top" : "Keep on top")
                    .buttonStyle(.glass)
                }
            }
            .opacity(model.isHovering && !model.isSelectingCrop ? 1 : 0)
            .offset(y: model.isHovering ? 0 : 6)
        }
        .controlSize(.regular)
        .padding(4)
    }

    private var viewMenu: some View {
        Menu {
            Section("Area") {
                Button("Crop…", systemImage: "crop", action: model.actions.beginCrop)
                if model.geometry.isCropped {
                    Button("Show Everything", systemImage: "arrow.up.left.and.arrow.down.right", action: model.actions.resetCrop)
                }
            }
            Section("Orientation") {
                Button("Rotate Left", systemImage: "rotate.left") { model.actions.rotate(-1) }
                Button("Rotate Right", systemImage: "rotate.right") { model.actions.rotate(1) }
                Toggle("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                       isOn: Binding(get: { model.geometry.flipped }, set: { _ in model.actions.flip() }))
            }
            Section("Frame Rate") {
                ForEach(PreviewSettings.frameRates, id: \.self) { fps in
                    Toggle("\(fps) fps", isOn: Binding(
                        get: { model.framesPerSecond == fps },
                        set: { _ in model.actions.setFrameRate(fps) }
                    ))
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.glass)
        .help("Crop, rotate, flip, frame rate")
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.accentColor.opacity(0.35)), in: .capsule)
    }
}
