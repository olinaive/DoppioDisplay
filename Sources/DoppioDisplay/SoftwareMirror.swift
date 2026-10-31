import AppKit
import QuartzCore

/// Shows one display on a virtual display without hardware mirroring, so both keep
/// their own resolution and aspect ratio. Hardware mirroring makes the GPU send one
/// picture to both displays, which forces them into the same mode; here the source is
/// captured (ScreenCaptureKit) and drawn full-screen, aspect-fit, on the target.
@MainActor
final class SoftwareMirror {
    /// Window numbers of all mirror windows, so display captures can keep them visible
    /// while leaving the app's other windows out.
    private(set) static var windowNumbers: Set<CGWindowID> = []

    let source: CGDirectDisplayID
    let target: CGDirectDisplayID
    private let window: NSWindow
    private let frameLayer = CALayer()
    private let capture: DisplayCapture
    var onStop: (() -> Void)?

    init?(source: CGDirectDisplayID, target: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == target }) else { return nil }
        self.source = source
        self.target = target

        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the target's menu bar and Dock; never takes clicks or focus.
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        frameLayer.frame = view.bounds
        frameLayer.contentsGravity = .resizeAspect
        frameLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(frameLayer)
        window.contentView = view
        capture = DisplayCapture(layer: frameLayer)
    }

    func start() {
        window.setFrame(NSScreen.screens.first { $0.displayID == target }?.frame ?? window.frame, display: false)
        window.orderFrontRegardless()
        Self.windowNumbers.insert(CGWindowID(window.windowNumber))
        capture.onStop = { [weak self] _ in self?.stop() }
        let pixelWidth = CGDisplayCopyDisplayMode(target)?.pixelWidth ?? 1920
        Task { @MainActor in
            await capture.setFramesPerSecond(60)
            await capture.setMaxWidth(pixelWidth)
            do {
                try await capture.start(.display(source))
            } catch {
                DisplayStore.shared.lastError = "Mirroring failed: \(error.localizedDescription)"
                stop()
            }
        }
    }

    func stop() {
        guard window.isVisible else { return }
        Self.windowNumbers.remove(CGWindowID(window.windowNumber))
        window.orderOut(nil)
        Task { await capture.stop() }
        onStop?()
    }
}
