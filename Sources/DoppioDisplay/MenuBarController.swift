import AppKit
import SwiftUI

/// The menu bar icon and its panel, in AppKit so the panel can be kept exactly under the
/// icon: SwiftUI's MenuBarExtra window is positioned by the system, which moved it to
/// another display's menu bar whenever displays were mirrored or rearranged.
///
/// Behaves like a menu: the icon toggles it, a click elsewhere or Escape closes it.
/// It stays open through display changes and simply follows the icon.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var panel: MenuPanelWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { panel?.isVisible == true }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.setAccessibilityTitle("DoppioDisplay")
        statusItem = item
        updateIcon()

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.updateIcon() }
        })
        // Displays changed: put the panel back under the icon right away (no animation, no delay).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.reposition() }
        })
    }

    private func updateIcon() {
        let style = AppIcon.MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarIcon") ?? "") ?? .twin
        statusItem?.button?.image = AppIcon.menuBarImage(style)
    }

    @objc private func togglePanel(_ sender: Any?) {
        isOpen ? close() : open()
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition()
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem?.button?.highlight(true)
        startMonitoring()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        stopMonitoring()
        statusItem?.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    private func makePanel() -> MenuPanelWindow {
        let root = MenuPanel()
            .background(MenuMaterial())
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        let panel = MenuPanelWindow(contentViewController: host)
        panel.delegate = self
        return panel
    }

    /// Top-centres the panel under the status item, kept inside the screen.
    func reposition() {
        guard let panel, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.screens.first { $0.frame.contains(iconFrame.origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.anchorTop = min(iconFrame.minY - 4, visible.maxY)
        var frame = panel.frame
        frame.origin.x = min(max(iconFrame.midX - frame.width / 2, visible.minX + 6), visible.maxX - frame.width - 6)
        frame.origin.y = panel.anchorTop! - frame.height
        panel.setFrame(frame, display: true)
    }

    // MARK: Closing like a menu

    private func startMonitoring() {
        stopMonitoring()
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { MenuBarController.shared.close() }
        }) {
            monitors.append(global)
        }
        // Clicks in our other windows (previews, settings) and Escape.
        // Local monitors run on the main thread; the box only carries the event across the closure type.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { event in
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { MenuBarController.shared.handleLocal(box.event) }
        }) {
            monitors.append(local)
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53, event.window === panel {
                close()
                return nil
            }
            return event
        }
        let window = event.window
        // Inside the panel, its popovers, pop-up menus and alerts, or on the icon itself: keep open.
        let inside = window === panel || window?.parent === panel || window === statusItem?.button?.window
            || (window.map { $0.level.rawValue >= NSWindow.Level.modalPanel.rawValue } ?? false)
            || (window.map { String(describing: type(of: $0)).contains("Popover") } ?? false)
        if !inside { close() }
        return event
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Another app took focus (e.g. via ⌘Tab).
        if !NSApp.isActive { close() }
    }
}

/// Borderless, translucent, top-anchored panel. Growing or shrinking (expanding a card)
/// keeps its top edge under the menu bar instead of AppKit's bottom-left origin.
final class MenuPanelWindow: NSPanel {
    var anchorTop: CGFloat?

    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        // Above previews (floating) but below alerts, so "Keep or Revert?" dialogs show on top.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchorTop { frame.origin.y = anchorTop - frame.height }
        super.setFrame(frame, display: flag)
    }
}

/// The translucent material of system menus behind the glass cards.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct EventBox: @unchecked Sendable {
    let event: NSEvent
}
