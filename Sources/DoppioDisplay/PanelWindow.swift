import AppKit
import SwiftUI

/// The menu bar panel in a floating window (`doppio://panel`). Handy to keep the
/// controls on screen, and the only way to open the panel from a URL: SwiftUI's
/// MenuBarExtra cannot be opened programmatically.
@MainActor
final class PanelWindowController {
    static let shared = PanelWindowController()
    private var window: NSPanel?

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
