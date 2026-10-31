import CPrivateAPI
import SwiftUI

struct MenuPanel: View {
    private var store: DisplayStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let error = store.lastError {
                ErrorBanner(text: error) { store.lastError = nil }
            }

            SectionTitle("Displays").padding(.top, 4)
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    if let builtin = store.physicalDisplays.first(where: \.isBuiltin) {
                        PhysicalCard(display: builtin)
                    }
                    ForEach(store.configs) { config in
                        VirtualCard(config: config)
                    }
                    ForEach(store.physicalDisplays.filter { !$0.isBuiltin }, id: \.id) { display in
                        PhysicalCard(display: display)
                    }
                    ArrangementCard()
                }
            }

            Button {
                store.addDisplay()
            } label: {
                Label("New Virtual Display", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .foregroundStyle(.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!VirtualDisplay.isSupported)
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 30, height: 30)
            Text("DoppioDisplay").font(.headline)
            Spacer()
            if store.isKeepingAwake {
                Label("Awake", systemImage: "cup.and.saucer.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.orange.opacity(0.16)))
                    .help("A virtual display keeps the Mac awake")
            }
            ProfilesMenu()
            Menu {
                Button("Picture in Picture of a Window…", systemImage: "macwindow.on.rectangle") {
                    store.pickWindowForPreview()
                }
                Divider()
                Button("Settings…", systemImage: "gearshape") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",")
                Button("Quit DoppioDisplay", systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                GlassIcon(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Physical display

struct PhysicalCard: View {
    let display: PhysicalDisplay
    @AppStorage("showQuickSliders") private var showQuickSliders = true
    private var store: DisplayStore { .shared }
    private var brightness: BrightnessStore { .shared }

    var body: some View {
        let control = brightness.controls[display.key]
        DisplayCard(id: "display-\(display.key)") {
            CardTitle(systemName: display.isBuiltin ? "laptopcomputer" : "display",
                      title: display.isBuiltin ? "Built-in Display" : display.name,
                      subtitle: subtitle) {
                if display.id == CGMainDisplayID(), store.layoutRevision >= 0 { Chip(text: "Main") }
                if display.mirrorMaster != kCGNullDirectDisplay { Chip(text: "Mirrors \(mirrorSource)") }
            }
        } trailing: {
            EmptyView()
        } collapsed: {
            if let control, showQuickSliders {
                brightnessSlider(control).padding(.leading, 40).padding(.bottom, 6)
            }
        } content: {
            if let control {
                SettingsGroup {
                    brightnessSlider(control)
                    if control.method == .software {
                        // Explains why the slider dims the picture instead of the backlight.
                        Text("Software dimming — this monitor does not answer DDC.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                    if let contrast = control.contrast {
                        SliderRow(lowIcon: "circle.righthalf.filled", highIcon: "circle.righthalf.filled",
                                  value: Binding(get: { contrast }, set: { brightness.setContrast(display.key, $0) }))
                    }
                    if let volume = control.volume {
                        HStack(spacing: 0) {
                            SliderRow(lowIcon: control.muted == true ? "speaker.slash.fill" : "speaker.fill",
                                      highIcon: "speaker.wave.3.fill",
                                      value: Binding(get: { volume }, set: { brightness.setVolume(display.key, $0) }))
                            if let muted = control.muted {
                                Button {
                                    brightness.setMuted(display.key, !muted)
                                } label: {
                                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .foregroundStyle(muted ? .red : .secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 10)
                                .help(muted ? "Unmute" : "Mute")
                            }
                        }
                    }
                    if display.isBuiltin && XDRBoost.isSupported {
                        XDRBoostRows()
                    }
                }
            }
            SettingsGroup {
                modeRows
            }
            SettingsGroup {
                mirrorRow
                if let control, control.method == .ddc, let input = control.inputSource {
                    SettingsRow(title: "Input") {
                        ValueMenu(value: DDCService.inputNames[input] ?? "Input \(input)") {
                            ForEach(DDCService.inputNames.keys.sorted(), id: \.self) { code in
                                Toggle(DDCService.inputNames[code]!, isOn: Binding(
                                    get: { input == code },
                                    set: { _ in brightness.setInputSource(display.key, code) }
                                ))
                            }
                        }
                    }
                }
            }
            ColorSection(id: "color-\(display.key)", displayID: display.id, isBuiltin: display.isBuiltin)
            HStack(spacing: 6) {
                let source = PreviewSource.display(key: display.key)
                let open = store.previewState(source) != .closed
                Button(open ? "Close Picture in Picture" : "Picture in Picture",
                       systemImage: open ? "pip.exit" : "pip.enter") { store.togglePreview(source) }
                let isMain = display.id == CGMainDisplayID()
                Button(isMain ? "Main Display" : "Make Main", systemImage: "menubar.rectangle") { store.makeMain(display.id) }
                    .disabled(isMain || display.mirrorMaster != kCGNullDirectDisplay)
            }
            .buttonStyle(CardActionStyle())
        }
    }

    private func brightnessSlider(_ control: DisplayControl) -> some View {
        SliderRow(lowIcon: "sun.min.fill", highIcon: "sun.max.fill",
                  value: Binding(get: { control.brightness }, set: { brightness.setBrightness(display.key, $0) }))
    }

    @ViewBuilder
    private var modeRows: some View {
        let _ = store.layoutRevision
        let current = CGDisplayCopyDisplayMode(display.id)
        let resolutions = DisplayModes.resolutions(for: display.id)
        if resolutions.count > 1, let current {
            SettingsRow(title: "Resolution") {
                ValueMenu(value: DisplayModes.title(of: current)) {
                    ForEach(Array(resolutions.enumerated()), id: \.offset) { _, mode in
                        Toggle(DisplayModes.title(of: mode), isOn: Binding(
                            get: { mode.width == current.width && mode.height == current.height },
                            set: { _ in store.setMode(display.id, mode) }
                        ))
                    }
                }
            }
        }
        if DPDisplayCanRotate(display.id) {
            let rotation = Int(DPDisplayRotation(display.id))
            SettingsRow(title: "Orientation") {
                ValueMenu(value: Self.rotationTitle(rotation)) {
                    ForEach([0, 90, 180, 270], id: \.self) { degrees in
                        Toggle(Self.rotationTitle(degrees), isOn: Binding(
                            get: { rotation == degrees },
                            set: { _ in store.setRotation(display, degrees) }
                        ))
                    }
                }
            }
        }
        if DisplayModes.canToggleHiDPI(display.id), let current {
            SettingsRow(title: "HiDPI (Retina)") {
                SwitchToggle(isOn: Binding(get: { DisplayModes.isHiDPI(current) }, set: { store.setHiDPI(display, $0) }))
            }
        } else if !display.isBuiltin, !DisplayModes.hasHiDPIModes(display.id) {
            // No Retina modes of its own: a mirrored virtual HiDPI display provides them.
            SettingsRow(title: "HiDPI (Retina)", hint: "via virtual display") {
                SwitchToggle(isOn: Binding(get: { store.hasVirtualHiDPI(display) }, set: { store.setVirtualHiDPI(display, $0) }))
            }
        }
        let rates = DisplayModes.refreshRates(for: display.id)
        if rates.count > 1, let current {
            SettingsRow(title: "Refresh Rate") {
                ValueMenu(value: DisplayModes.rateTitle(current.refreshRate, builtin: display.isBuiltin)) {
                    ForEach(Array(rates.enumerated()), id: \.offset) { _, mode in
                        Toggle(DisplayModes.rateTitle(mode.refreshRate, builtin: display.isBuiltin), isOn: Binding(
                            get: { abs(mode.refreshRate - current.refreshRate) < 0.005 },
                            set: { _ in store.setMode(display.id, mode) }
                        ))
                    }
                }
            }
        }
    }

    /// Other physical displays that can show this one.
    @ViewBuilder
    private var mirrorRow: some View {
        let targets = store.physicalDisplays.filter { $0.id != display.id }
        let active = targets.filter { $0.mirrorMaster == display.id }
        SettingsRow(title: "Mirror To") {
            ValueMenu(value: active.isEmpty ? "Off" : active.map(\.name).joined(separator: ", ")) {
                if targets.isEmpty {
                    Text("No other displays connected")
                }
                ForEach(targets, id: \.id) { target in
                    Toggle(target.isBuiltin ? "Built-in Display" : target.title, isOn: Binding(
                        get: { target.mirrorMaster == display.id },
                        set: { _ in store.togglePhysicalMirror(source: display, target: target) }
                    ))
                }
            }
        }
        .disabled(display.mirrorMaster != kCGNullDirectDisplay)
    }

    static func rotationTitle(_ degrees: Int) -> String {
        degrees == 0 ? "Standard" : "\(degrees)°"
    }

    private var subtitle: String {
        _ = store.layoutRevision
        guard let mode = CGDisplayCopyDisplayMode(display.id) else { return "\(display.pixelWidth) × \(display.pixelHeight)" }
        let rate = mode.refreshRate > 0 ? " · " + DisplayModes.rateTitle(mode.refreshRate, builtin: display.isBuiltin) : ""
        return "\(mode.width) × \(mode.height)\(rate)"
    }

    private var mirrorSource: String {
        store.configs.first { store.liveIDs[$0.id] == display.mirrorMaster }?.name ?? "another display"
    }
}

struct XDRBoostRows: View {
    private var boost: XDRBoost { .shared }

    var body: some View {
        SettingsRow(title: "XDR Boost", systemImage: "sun.max.fill") {
            Chip(text: "HDR", tint: .yellow)
            Text(status).font(.caption).foregroundStyle(.secondary)
            SwitchToggle(isOn: Binding(get: { boost.isEnabled }, set: { boost.isEnabled = $0 }))
        }
        .help("Uses the XDR panel's HDR headroom to make the whole screen brighter. HDR video clips while on; uses more battery.")
        if boost.isEnabled {
            SliderRow(lowIcon: "sparkle", highIcon: "sparkles",
                      value: Binding(get: { boost.level }, set: { boost.level = $0 }),
                      tint: .yellow,
                      label: { "\(Int((100 + $0 * (boost.maxFactor - 1) * 100).rounded()))%" })
        }
    }

    private var status: String {
        switch boost.state {
        case .off: ""
        case .waitingForHDR: "Waiting…"
        case .pausedOnBattery: "Paused on battery"
        case .active(let factor): "\(Int((factor * 100).rounded()))%"
        }
    }
}

// MARK: - Virtual display

struct VirtualCard: View {
    let config: VirtualDisplayConfig
    @State private var name: String
    @State private var showsCustom = false
    private var store: DisplayStore { .shared }

    init(config: VirtualDisplayConfig) {
        self.config = config
        _name = State(initialValue: config.name)
    }

    var body: some View {
        let live = store.isLive(config.id)
        let vid = store.liveIDs[config.id]
        DisplayCard(id: "virtual-\(config.id.uuidString)") {
            CardTitle(systemName: "display", title: config.name, subtitle: subtitle(live: live), active: live) {
                Chip(text: config.hiDPIFor == nil ? "Virtual" : "HiDPI helper", tint: .blue)
                if let vid, vid == CGMainDisplayID(), store.layoutRevision >= 0 { Chip(text: "Main") }
            }
        } trailing: {
            SwitchToggle(isOn: Binding(get: { config.isEnabled && live }, set: { store.setEnabled(config.id, $0) }))
        } collapsed: {
            EmptyView()
        } content: {
            SettingsGroup {
                SettingsRow(title: "Name") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .onSubmit { store.update(config.id) { $0.name = name } }
                }
                SettingsRow(title: "Resolution") {
                    ValueMenu(value: config.resolutionTitle) {
                        ForEach(DisplayPreset.all, id: \.self) { preset in
                            // Presets follow the current orientation.
                            let width = config.isPortrait ? preset.height : preset.width
                            let height = config.isPortrait ? preset.width : preset.height
                            Toggle("\(width) × \(height)", isOn: Binding(
                                get: { config.width == width && config.height == height },
                                set: { _ in store.setResolution(config.id, width: width, height: height) }
                            ))
                        }
                        Divider()
                        Button("Custom…") { showsCustom = true }
                    }
                    .popover(isPresented: $showsCustom, arrowEdge: .trailing) {
                        CustomResolutionForm(config: config) { showsCustom = false }
                    }
                }
                SettingsRow(title: "Orientation") {
                    ValueMenu(value: config.isPortrait ? "Portrait" : "Landscape") {
                        Toggle("Landscape", isOn: Binding(get: { !config.isPortrait }, set: { _ in store.setPortrait(config.id, false) }))
                        Toggle("Portrait", isOn: Binding(get: { config.isPortrait }, set: { _ in store.setPortrait(config.id, true) }))
                    }
                }
                SettingsRow(title: "HiDPI (Retina)") {
                    SwitchToggle(isOn: Binding(get: { config.hiDPI }, set: { value in store.update(config.id) { $0.hiDPI = value } }))
                }
                SettingsRow(title: "Refresh Rate") {
                    ValueMenu(value: "\(Int(config.refreshRate)) Hz") {
                        ForEach(VirtualDisplayConfig.refreshRates, id: \.self) { rate in
                            Toggle("\(Int(rate)) Hz", isOn: Binding(
                                get: { config.refreshRate == rate },
                                set: { _ in store.update(config.id) { $0.refreshRate = rate } }
                            ))
                        }
                    }
                }
            }
            .disabled(!live)
            SettingsGroup {
                SettingsRow(title: "Mirror To") {
                    ValueMenu(value: mirrorTitle) {
                        let candidates = store.mirrorCandidates
                        if candidates.isEmpty {
                            Text("No external displays connected")
                        }
                        ForEach(candidates, id: \.id) { target in
                            Toggle(target.isBuiltin ? "Built-in Display (custom resolution)" : target.title, isOn: Binding(
                                get: { store.isMirroring(config.id, to: target) },
                                set: { _ in store.toggleMirror(config.id, to: target) }
                            ))
                        }
                    }
                }
                SettingsRow(title: "Keep Mac Awake") {
                    ValueMenu(value: config.keepAwake.title) {
                        ForEach(KeepAwake.allCases, id: \.self) { option in
                            Toggle(option.title, isOn: Binding(
                                get: { config.keepAwake == option },
                                set: { _ in store.update(config.id) { $0.keepAwake = option } }
                            ))
                        }
                    }
                }
            }
            .disabled(!live)
            if let vid {
                ColorSection(id: "color-virtual-\(config.id.uuidString)", displayID: vid, isBuiltin: false)
            }
            HStack(spacing: 6) {
                let state = store.previewState(config.id)
                Button(state == .closed ? "Preview" : (state == .minimized ? "Restore" : "Close Preview"),
                       systemImage: state == .open ? "pip.exit" : "pip.enter") {
                    state == .open ? store.closePreview(config.id) : store.showPreview(config.id)
                }
                .disabled(!live)
                let isMain = vid != nil && vid == CGMainDisplayID()
                Button(isMain ? "Main Display" : "Make Main", systemImage: "menubar.rectangle") {
                    if let vid { store.makeMain(vid) }
                }
                .disabled(!live || isMain)
                Button("Delete", systemImage: "trash", role: .destructive) { store.remove(config.id) }
                    .buttonStyle(CardActionStyle(role: .destructive, iconOnly: true))
                    .help("Delete this virtual display")
            }
            .buttonStyle(CardActionStyle())
        }
    }

    private var mirrorTitle: String {
        let active = store.mirrorCandidates.filter { store.isMirroring(config.id, to: $0) }
        if !active.isEmpty { return active.map(\.name).joined(separator: ", ") }
        return config.mirrorTargets.isEmpty ? "Off" : "Waiting for monitor"
    }

    private func subtitle(live: Bool) -> String {
        guard live else { return config.isEnabled ? "Starting…" : "Off" }
        var parts = [config.resolutionTitle]
        if config.hiDPI { parts.append("HiDPI") }
        parts.append("\(Int(config.refreshRate)) Hz")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Arrangement

struct ArrangementCard: View {
    private var store: DisplayStore { .shared }

    var body: some View {
        DisplayCard(id: "arrangement") {
            CardTitle(systemName: "rectangle.3.group", title: "Arrangement",
                      subtitle: "Drag a virtual display to move it") { EmptyView() }
        } trailing: {
            EmptyView()
        } collapsed: {
            EmptyView()
        } content: {
            ArrangementMap()
            HStack {
                Label("Menu bar = main display", systemImage: "menubar.rectangle")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Color

/// Collapsible "Color" group: ICC profile, and True Tone / Night Shift on the built-in panel.
struct ColorSection: View {
    let id: String
    let displayID: CGDirectDisplayID
    let isBuiltin: Bool
    private var colors: ColorControls { .shared }
    private var state: PanelState { .shared }

    var body: some View {
        let open = state.isExpanded(id)
        let current = colors.currentProfileName(for: displayID)
        let presets = colors.presets(for: displayID)
        let activePreset = colors.activePreset(for: displayID)
        SettingsGroup {
            SettingsRow(title: "Color", systemImage: "paintpalette.fill") {
                Text(summary(primary: activePreset ?? current)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.snappy(duration: 0.2), value: open)
            }
            .contentShape(.rect)
            .onTapGesture { state.toggle(id) }
            if open && !presets.isEmpty {
                // Presets (reference modes) are what System Settings shows; choosing one also switches the ICC profile.
                SettingsRow(title: "Preset") {
                    ValueMenu(value: activePreset ?? "Custom") {
                        ForEach(presets, id: \.self) { preset in
                            Toggle(preset, isOn: Binding(
                                get: { preset == activePreset },
                                set: { _ in colors.setPreset(preset, for: displayID) }
                            ))
                        }
                    }
                }
            }
            if open {
                SettingsRow(title: "ICC Profile") {
                    ValueMenu(value: current) {
                        ForEach(colors.profiles, id: \.self) { profile in
                            Toggle(profile.name, isOn: Binding(
                                get: { profile.name == current },
                                set: { _ in colors.setProfile(profile.url, for: displayID) }
                            ))
                        }
                        Divider()
                        Button("Other…") { colors.chooseProfileFile(for: displayID) }
                        Button("Reset to Default") { colors.resetProfile(for: displayID) }
                    }
                }
            }
            if open {
                if isBuiltin && colors.trueToneAvailable {
                    SettingsRow(title: "True Tone", hint: "adapts to ambient light") {
                        SwitchToggle(isOn: Binding(get: { colors.trueToneEnabled }, set: { colors.setTrueTone($0) }))
                    }
                }
                if isBuiltin && colors.nightShiftAvailable {
                    SettingsRow(title: "Night Shift") {
                        SwitchToggle(isOn: Binding(get: { colors.nightShiftEnabled }, set: { colors.setNightShift($0) }))
                    }
                    if colors.nightShiftEnabled {
                        SliderRow(lowIcon: "sun.max.fill", highIcon: "moon.fill",
                                  value: Binding(get: { colors.nightShiftStrength }, set: { colors.setNightShiftStrength($0) }),
                                  tint: .orange)
                    }
                }
            }
        }
        .onAppear { if isBuiltin { colors.reload() } }
    }

    private func summary(primary: String) -> String {
        // "Apple XDR Display (P3-1600 nits)" → "Apple XDR Display" keeps the row short.
        var parts = [primary.components(separatedBy: " (").first ?? primary]
        if isBuiltin && colors.trueToneEnabled { parts.append("True Tone") }
        if isBuiltin && colors.nightShiftEnabled { parts.append("Night Shift") }
        return parts.joined(separator: " · ")
    }
}
