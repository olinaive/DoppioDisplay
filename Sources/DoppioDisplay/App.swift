import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct DoppioDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("menuBarIcon") private var menuBarStyle = AppIcon.MenuBarStyle.twin.rawValue

    init() {
        if Bundle.main.bundleIdentifier == "app.doppiodisplay" {
            LegacyMigration.run()
        }
        let arguments = CommandLine.arguments
        // `--selftest` creates a display, checks it comes online, removes it and exits.
        if arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        // `--brightness-probe` prints how each display's brightness can be controlled. Read-only.
        if arguments.contains("--brightness-probe") {
            exit(SelfTest.brightnessProbe())
        }
        // `--xdr-probe` shows the EDR trigger for 10 s and reports the headroom. Gamma is not touched.
        if arguments.contains("--xdr-probe") {
            exit(SelfTest.xdrProbe())
        }
        // `--config-probe` checks that the saved virtual displays decode. Read-only.
        if arguments.contains("--config-probe") {
            exit(SelfTest.configProbe())
        }
        // `--color-probe` reads Night Shift / True Tone state. Read-only.
        if arguments.contains("--color-probe") {
            exit(SelfTest.colorProbe())
        }
        // `--export-menubar <dir>` writes the menu bar glyphs at 4× for design review.
        if let index = arguments.firstIndex(of: "--export-menubar"), index + 1 < arguments.count {
            exit(AppIcon.exportMenuBarGlyphs(to: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
        }
        // `--mirror-probe` mirrors the built-in display onto a temporary virtual display and back,
        // printing what CoreGraphics reports right away and a moment later.
        if arguments.contains("--mirror-probe") {
            exit(SelfTest.mirrorProbe())
        }
        // `--export-iconset <dir>` writes the PNGs iconutil needs for AppIcon.icns.
        if let index = arguments.firstIndex(of: "--export-iconset"), index + 1 < arguments.count {
            exit(AppIcon.exportIconset(to: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
        } label: {
            Image(nsImage: AppIcon.menuBarImage(AppIcon.MenuBarStyle(rawValue: menuBarStyle) ?? .twin))
        }
        .menuBarExtraStyle(.window)


    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    /// SwiftUI routes URLs to window scenes and installs its own handler during
    /// launch; a menu bar app takes them over afterwards.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installURLHandler()
        DisplayStore.shared.start()
        XDRBoost.shared.resume()
        HotKeys.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLCommands.handle(url) }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated { URLCommands.handle(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CursorCapture.shared.end()
        DisplayStore.shared.shutdown()
        XDRBoost.shared.stop()
        BrightnessStore.shared.restoreGamma()
    }

    /// Clicking the Dock icon brings back minimized previews.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DisplayStore.shared.restoreMinimizedPreviews()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
