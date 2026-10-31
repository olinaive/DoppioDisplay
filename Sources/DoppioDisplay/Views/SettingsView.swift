import AppKit
import SwiftUI

/// Settings window in the System Settings style: a sidebar of sections and a
/// scrolling grouped form on the right. Fixed size, so it never runs off screen.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case general, preview, brightness, profiles, shortcuts, automation, permissions, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .preview: "Preview"
            case .brightness: "Brightness"
            case .profiles: "Profiles"
            case .shortcuts: "Shortcuts"
            case .automation: "Automation"
            case .permissions: "Permissions"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .preview: "rectangle.inset.bottomright.filled"
            case .brightness: "sun.max.fill"
            case .profiles: "square.stack.3d.up.fill"
            case .shortcuts: "keyboard.fill"
            case .automation: "terminal.fill"
            case .permissions: "lock.shield.fill"
            case .about: "info"
            }
        }

        /// Tile colours in the System Settings palette.
        var tint: Color {
            switch self {
            case .general, .about: Color(red: 0.56, green: 0.56, blue: 0.58)
            case .preview: Color(red: 0.37, green: 0.36, blue: 0.90)
            case .brightness: Color(red: 1.0, green: 0.62, blue: 0.04)
            case .profiles: Color(red: 0.19, green: 0.69, blue: 0.78)
            case .shortcuts: Color(red: 0.39, green: 0.39, blue: 0.40)
            case .automation: Color(red: 0.20, green: 0.78, blue: 0.35)
            case .permissions: Color(red: 0.04, green: 0.52, blue: 1.0)
            }
        }
    }

    @State var selection: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                Text(selection.title)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                Divider()
                Group {
                    switch selection {
                    case .general: GeneralSettings()
                    case .preview: PreviewSettingsPane()
                    case .brightness: BrightnessSettings()
                    case .profiles: ProfilesSettings()
                    case .shortcuts: ShortcutsSettings()
                    case .automation: AutomationSettings()
                    case .permissions: PermissionsSettings()
                    case .about: AboutSettings()
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights, which sit on top of the sidebar.
            Color.clear.frame(height: 40)
            ForEach(Section.allCases) { section in
                SidebarRow(section: section, isSelected: selection == section) { selection = section }
            }
            Spacer()
            HStack(spacing: 8) {
                Image(nsImage: AppIcon.image).resizable().frame(width: 22, height: 22)
                Text("DoppioDisplay \(appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }
}

private struct SidebarRow: View {
    let section: SettingsView.Section
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsTile(symbol: section.symbol, tint: section.tint)
                Text(section.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Color.accentColor : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Rounded-square icon tile in the System Settings style: soft vertical gradient,
/// hairline edge, white symbol.
struct SettingsTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            )
            .frame(width: 20, height: 20)
    }
}

/// The translucent sidebar material System Settings uses.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("showQuickSliders") private var showQuickSliders = true
    @AppStorage("menuBarIcon") private var menuBarIcon = AppIcon.MenuBarStyle.twin.rawValue
    @AppStorage("panelSeveralExpanded") private var severalExpanded = false
    private var store: DisplayStore { .shared }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Toggle(isOn: $store.restoreOnLaunch) {
                    Text("Restore virtual displays on launch")
                    Text("Recreates the displays that were on when you quit.")
                }
            }
            Section("New Virtual Displays") {
                Picker("Default resolution", selection: $store.defaultPreset) {
                    ForEach(DisplayPreset.all, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("HiDPI by default", isOn: $store.defaultHiDPI)
                Toggle("Open preview when created", isOn: $store.previewOnCreate)
            }
            Section("Menu Bar") {
                Picker("Icon", selection: $menuBarIcon) {
                    ForEach(AppIcon.MenuBarStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: AppIcon.menuBarImage(style))
                        }
                        .tag(style.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Show quick brightness sliders on collapsed displays", isOn: $showQuickSliders)
                Toggle(isOn: $severalExpanded) {
                    Text("Allow several expanded displays")
                    Text("Off: opening a display's settings closes the others, so the menu stays short.")
                }
            }
        }
    }
}

// MARK: - Preview

private struct PreviewSettingsPane: View {
    @AppStorage("previewFPS") private var fps = 60
    @AppStorage("previewKeepOnTop") private var keepOnTop = true
    @AppStorage("previewLiveDock") private var liveDock = false

    var body: some View {
        Form {
            Section("Picture in Picture") {
                Picker("Default frame rate", selection: $fps) {
                    ForEach(PreviewSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Keep on top by default", isOn: $keepOnTop)
                Toggle(isOn: $liveDock) {
                    Text("Live Dock thumbnail when minimized")
                    Text("Streams about two frames per second instead of pausing.")
                }
            }
            Section {
                LabeledContent("Full screen") { KeyCaps(["Double-click"]); Text("or the green window button").foregroundStyle(.secondary) }
                LabeledContent("Leave full screen") { KeyCaps(["⎋"]) }
            } header: {
                Text("Full Screen")
            }
        }
    }
}

// MARK: - Brightness

private struct BrightnessSettings: View {
    private var brightness: BrightnessStore { .shared }
    private var boost: XDRBoost { .shared }

    var body: some View {
        @Bindable var brightness = brightness
        @Bindable var boost = boost
        Form {
            Section("Sync") {
                Toggle("Sync external displays with built-in brightness", isOn: $brightness.syncWithBuiltin)
            }
            if XDRBoost.isSupported {
                Section("XDR Boost") {
                    Toggle("Pause on battery", isOn: $boost.offOnBattery)
                    Picker("Maximum boost", selection: $boost.maxFactor) {
                        ForEach(XDRBoost.maxFactorChoices, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                    }
                }
            }
            Section {
                Picker(selection: $brightness.softwareFloor) {
                    ForEach(BrightnessStore.softwareFloorChoices, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
                } label: {
                    Text("Software dimming floor")
                    Text("Lowest level when a monitor has no hardware control.")
                }
            } header: {
                Text("External Monitors")
            } footer: {
                Text("DDC works over USB-C, Thunderbolt and DisplayPort. The built-in HDMI port on M1-series Macs does not pass DDC; such monitors use software dimming.")
            }
        }
    }
}

// MARK: - Profiles

private struct ProfilesSettings: View {
    @State private var showsSave = false
    @State private var newName = ""
    private var profiles: ProfileStore { .shared }

    var body: some View {
        Form {
            Section {
                if profiles.profiles.isEmpty {
                    Text("No profiles yet. Set up your displays, then save them here or from the menu bar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                    LabeledContent {
                        Picker("Apply", selection: Binding(
                            get: { profile.trigger },
                            set: { profiles.setTrigger($0, for: profile) }
                        )) {
                            ForEach(triggerOptions(current: profile.trigger), id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Delete", role: .destructive) { profiles.delete(profile) }
                    } label: {
                        Text(profile.name)
                        Text(detail(profile, index: index))
                    }
                }
            } header: {
                HStack {
                    Text("Saved Profiles")
                    Spacer()
                    Button("Save Current Setup…", systemImage: "plus") {
                        newName = ""
                        showsSave = true
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("A profile stores virtual displays (resolution, mirrors, position), brightness and XDR Boost. A rule makes it apply itself when the connected monitors change.")
            }
        }
        .sheet(isPresented: $showsSave) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Profile").font(.headline)
                TextField("Name, e.g. Desk or Presenting", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Cancel") { showsSave = false }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }

    private func save() {
        profiles.saveCurrent(named: newName)
        showsSave = false
    }

    private func detail(_ profile: DisplayProfile, index: Int) -> String {
        var parts: [String] = []
        if index < 9 { parts.append(HotKeys.modifierSymbols + "\(index + 1)") }
        let count = profile.displays.count
        parts.append(count == 0 ? "no virtual displays" : "\(count) virtual display\(count == 1 ? "" : "s")")
        if profile.xdrEnabled == true { parts.append("XDR on") }
        return parts.joined(separator: " · ")
    }

    /// Manual, any/no external, and one entry per connected monitor (plus the saved one if it is unplugged).
    private func triggerOptions(current: ProfileTrigger) -> [ProfileTrigger] {
        var options: [ProfileTrigger] = [.manual, .anyExternal, .noExternal]
        for display in DisplayStore.shared.physicalDisplays where !display.isBuiltin {
            options.append(.connected(key: display.key, name: display.name))
        }
        if !options.contains(current) { options.append(current) }
        return options
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @State private var enabled = HotKeys.shared.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Global shortcuts", isOn: $enabled)
                    .onChange(of: enabled) { _, value in HotKeys.shared.isEnabled = value }
            }
            Section("Displays") {
                row("First virtual display on/off", "V")
                row("Show/hide preview", "P")
            }
            Section("Brightness") {
                row("Brightness up (display under cursor)", "↑")
                row("Brightness down", "↓")
                row("XDR Boost on/off", "X")
            }
            Section("Profiles") {
                row("Apply profile 1…9", "1…9")
            }
        }
        .disabled(!enabled)
    }

    private func row(_ title: String, _ key: String) -> some View {
        LabeledContent(title) { KeyCaps(["⌃", "⌥", "⌘", key]) }
    }
}

// MARK: - Automation

private struct AutomationSettings: View {
    @State private var copied: String?
    @State private var cliStatus = CommandLineTool.status

    private let examples = [
        "doppio://create?width=2560&height=1440",
        "doppio://toggle?name=Virtual%201",
        "doppio://preview?action=toggle",
        "doppio://xdr?on=toggle&level=0.8",
        "doppio://brightness?display=builtin&value=0.6",
        "doppio://profile?name=Desk",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(examples, id: \.self) { url in
                    LabeledContent {
                        Button(copied == url ? "Copied" : "Copy", systemImage: copied == url ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = url
                        }
                    } label: {
                        Text(url).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            } header: {
                Text("URL Scheme")
            } footer: {
                Text("Works from Raycast, Alfred, Shortcuts (Open URL) or Terminal: open \"doppio://…\". Also: enable, disable, remove, resolution, mirror.")
            }
            Section {
                LabeledContent {
                    switch cliStatus {
                    case .installed:
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notInstalled, .other:
                        Button("Install…") {
                            CommandLineTool.install()
                            cliStatus = CommandLineTool.status
                        }
                    }
                } label: {
                    Text("doppio command")
                    Text(cliStatus == .other ? "\(CommandLineTool.linkPath) exists and points elsewhere." : "Links the CLI into \(CommandLineTool.linkPath).")
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text("Usage: doppio create width=2560 height=1440 · doppio xdr on=toggle · doppio profile name=Desk")
            }
        }
    }
}

/// Installs `doppio` (bundled in Contents/Resources) as a symlink in /usr/local/bin.
@MainActor
enum CommandLineTool {
    enum Status { case installed, notInstalled, other }

    static let linkPath = "/usr/local/bin/doppio"
    static var bundledPath: String? { Bundle.main.path(forResource: "doppio", ofType: nil) }

    static var status: Status {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return FileManager.default.fileExists(atPath: linkPath) ? .other : .notInstalled
        }
        return destination == bundledPath ? .installed : .other
    }

    /// /usr/local/bin needs admin rights; macOS shows its own password prompt.
    static func install() {
        guard let source = bundledPath else {
            DisplayStore.shared.lastError = "The doppio command is missing from the app bundle."
            return
        }
        let command = "mkdir -p /usr/local/bin && ln -sf '\(source)' '\(linkPath)'"
        let script = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            DisplayStore.shared.lastError = "Installing the doppio command failed: \(error[NSAppleScript.errorMessage] ?? "unknown error")"
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    status(screenRecording) {
                        CGRequestScreenCaptureAccess()
                        open("Privacy_ScreenCapture")
                    }
                } label: {
                    Text("Screen & System Audio Recording")
                    Text("Previews and picture in picture.")
                }
            } footer: {
                Text("With a development build macOS may ask again after each rebuild, because the code signature changes.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenRecording = CGPreflightScreenCaptureAccess()
        }
    }

    @ViewBuilder
    private func status(_ granted: Bool, request: @escaping () -> Void) -> some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("Open System Settings", action: request)
        }
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: AppIcon.image).resizable().frame(width: 96, height: 96)
                    Text("DoppioDisplay").font(.title2.weight(.semibold))
                    Text("Version \(appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                feature("Virtual displays", "CGVirtualDisplay (private)", VirtualDisplay.isSupported)
                feature("Built-in brightness", "DisplayServices (private)", PrivateDisplayAPI.setBrightness != nil)
                feature("DDC", "IOAVService (private)", PrivateDisplayAPI.avServiceWriteI2C != nil)
                feature("Night Shift & True Tone", "CoreBrightness (private)", ColorControls.shared.nightShiftAvailable || ColorControls.shared.trueToneAvailable)
                feature("Display presets", "MonitorPanel (private)", !ColorControls.shared.presets(for: CGMainDisplayID()).isEmpty)
            } header: {
                Text("System Features")
            } footer: {
                Text("Private APIs can change with any macOS update. If one disappears, the matching controls hide themselves.")
            }
            Section("Credits") {
                Text("KhaosT/CGVirtualDisplay, Stengo/DeskPad, lyonDan/vdscreen, sammcj/force-hidpi, MonitorControl")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ title: String, _ detail: String, _ available: Bool) -> some View {
        LabeledContent {
            if available {
                Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Unavailable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

/// Keyboard keys drawn as small caps.
struct KeyCaps: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            }
        }
    }
}

/// The settings window is a plain AppKit window hosting SwiftUI: transparent full-size
/// title bar with the sidebar under the traffic lights, fixed size, openable from anywhere
/// (menu bar panel, URL scheme).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(_ section: SettingsView.Section? = nil) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "DoppioDisplay Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // The hosting controller must not size the window: it would add the title bar height
        // on top of the content and leave an empty strip at the bottom.
        let host = NSHostingController(rootView: SettingsView(selection: section ?? .general))
        host.sizingOptions = []
        window?.contentViewController = host
        if let window {
            var frame = window.frame
            frame.origin.y += frame.height - 560
            frame.size = NSSize(width: 780, height: 560)
            window.setFrame(frame, display: true)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.windowNumber }
}
