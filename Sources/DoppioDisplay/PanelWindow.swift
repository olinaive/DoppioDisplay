import AppKit
import SwiftUI

/// The menu bar panel in a floating window (`doppio://panel`). Handy to keep the
/// controls on screen, and the only way to open the panel from a URL: SwiftUI's
/// MenuBarExtra cannot be opened programmatically.
@MainActor
final class PanelWindowController {
    static let shared = PanelWindowController()
    private(set) var window: NSPanel?

    func show() {
        if window == nil {
            let root = MenuPanel()
                .padding(.top, 18) // room for the close button
                .background(PopoverMaterial().ignoresSafeArea())
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: host)
            panel.styleMask = [.titled, .closable, .fullSizeContentView, .utilityWindow]
            panel.title = "DoppioDisplay"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.center()
            window = panel
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Same translucent material as the menu bar window behind the glass cards.
private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Keeps the menu bar panel attached to the menu bar. When displays are reconfigured
/// (mirroring, arrangement, resolution) macOS moves open windows to fit the new layout,
/// which pushes the menu bar window down the screen; this puts it back.
struct MenuBarWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Let AppKit finish its own repositioning, then correct it (twice: mirroring
                // can arrive as more than one reconfiguration).
                for delay in [0.15, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.reanchor() }
                }
            }
        }

        private func reanchor() {
            MainActor.assumeIsolated {
                guard let window, window.isVisible, window !== PanelWindowController.shared.window else { return }
                let midX = window.frame.midX
                guard let screen = NSScreen.screens.first(where: { $0.frame.minX <= midX && midX <= $0.frame.maxX })
                        ?? window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                var frame = window.frame
                frame.origin.y = visible.maxY - frame.height
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                if frame != window.frame { window.setFrame(frame, display: true) }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
