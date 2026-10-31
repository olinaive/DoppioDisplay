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

extension Notification.Name {
    /// Posted right before a change that reconfigures displays (mirroring, rotation, modes).
    static let doppioWillReconfigureDisplays = Notification.Name("DoppioWillReconfigureDisplays")
}

/// Closes the menu bar panel before displays are reconfigured. macOS moves open windows to
/// fit a new display layout, which would drag the panel down the screen; system menus
/// simply close before such changes, and so does this one. The floating panel window stays.
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
                forName: .doppioWillReconfigureDisplays, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let window = self?.window, window.isVisible,
                          window !== PanelWindowController.shared.window else { return }
                    window.close()
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
