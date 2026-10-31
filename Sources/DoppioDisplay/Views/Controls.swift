import SwiftUI

/// Resolution picker shared by the menu bar card and the preview toolbar.
struct ResolutionMenu: View {
    let config: VirtualDisplayConfig
    @State private var showsCustom = false
    private var store: DisplayStore { .shared }

    var body: some View {
        Menu {
            Section("Resolution") {
                ForEach(DisplayPreset.all, id: \.self) { preset in
                    Toggle(preset.title, isOn: presetBinding(preset))
                }
                Button("Custom…") { showsCustom = true }
            }
            Section("Refresh Rate") {
                ForEach(VirtualDisplayConfig.refreshRates, id: \.self) { rate in
                    Toggle("\(Int(rate)) Hz", isOn: rateBinding(rate))
                }
            }
            Toggle("HiDPI (Retina)", isOn: hiDPIBinding)
        } label: {
            Label(config.resolutionTitle, systemImage: "aspectratio")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.glass)
        .help("Resolution, refresh rate and HiDPI")
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            CustomResolutionForm(config: config) { showsCustom = false }
        }
    }

    private func presetBinding(_ preset: DisplayPreset) -> Binding<Bool> {
        let id = config.id
        let selected = config.width == preset.width && config.height == preset.height
        return Binding(
            get: { selected },
            set: { _ in DisplayStore.shared.setResolution(id, width: preset.width, height: preset.height) }
        )
    }

    private func rateBinding(_ rate: Double) -> Binding<Bool> {
        let id = config.id
        let selected = config.refreshRate == rate
        return Binding(
            get: { selected },
            set: { _ in DisplayStore.shared.update(id) { $0.refreshRate = rate } }
        )
    }

    private var hiDPIBinding: Binding<Bool> {
        let id = config.id
        let value = config.hiDPI
        return Binding(
            get: { value },
            set: { newValue in DisplayStore.shared.update(id) { $0.hiDPI = newValue } }
        )
    }
}

struct CustomResolutionForm: View {
    let config: VirtualDisplayConfig
    let dismiss: () -> Void
    @State private var width: Int
    @State private var height: Int

    init(config: VirtualDisplayConfig, dismiss: @escaping () -> Void) {
        self.config = config
        self.dismiss = dismiss
        _width = State(initialValue: Int(config.width))
        _height = State(initialValue: Int(config.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Resolution").font(.headline)
            HStack(spacing: 6) {
                TextField("Width", value: $width, format: .number.grouping(.never))
                    .frame(width: 72)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", value: $height, format: .number.grouping(.never))
                    .frame(width: 72)
                Text("pt").foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            Text("640×480 … 7680×4320. With HiDPI the display renders at twice these values.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Apply") {
                    DisplayStore.shared.setResolution(config.id, width: UInt32(clamping: width), height: UInt32(clamping: height))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Lists external monitors; a check mark means it currently mirrors this virtual display.
struct MirrorMenu: View {
    let config: VirtualDisplayConfig
    var compact = false
    private var store: DisplayStore { .shared }

    var body: some View {
        let candidates = store.mirrorCandidates
        let active = candidates.filter { store.isMirroring(config.id, to: $0) }
        Menu {
            if candidates.isEmpty {
                Text("No external displays connected")
            }
            ForEach(candidates, id: \.id) { target in
                Toggle(target.title, isOn: Binding(
                    get: { store.isMirroring(config.id, to: target) },
                    set: { _ in store.toggleMirror(config.id, to: target) }
                ))
            }
            if !config.mirrorTargets.isEmpty && active.isEmpty {
                Divider()
                Text("Remembered monitor is not connected")
            }
        } label: {
            if compact {
                Image(systemName: active.isEmpty ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill")
            } else {
                Label(active.isEmpty ? "Mirror" : active.map(\.name).joined(separator: ", "),
                      systemImage: active.isEmpty ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill")
                    .lineLimit(1)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.glass)
        .tint(active.isEmpty ? nil : .accentColor)
        // macOS keeps the built menu and its check marks; a new identity rebuilds it.
        .id("mirror-\(config.id)-\(active.map(\.key).joined(separator: ","))-\(store.layoutRevision)")
        .help("Mirror this virtual display to an external monitor")
    }
}

/// Header menu: apply a saved profile or save the current setup.
struct ProfilesMenu: View {
    @State private var showsSave = false
    @State private var name = ""
    private var profiles: ProfileStore { .shared }

    var body: some View {
        Menu {
            if profiles.profiles.isEmpty {
                Text("No profiles yet")
            }
            ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                Toggle(isOn: Binding(get: { profiles.activeProfileID == profile.id }, set: { _ in profiles.apply(profile) })) {
                    Text(profile.name)
                    let shortcut = index < 9 ? HotKeys.modifierSymbols + "\(index + 1)" : nil
                    let detail = [profile.trigger.isAutomatic ? "auto" : nil, shortcut].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail) }
                }
            }
            Divider()
            Button("Save Current Setup…", systemImage: "square.and.arrow.down") {
                name = ""
                showsSave = true
            }
            Button("Manage Profiles…", systemImage: "slider.horizontal.3") {
                SettingsWindowController.shared.show()
            }
        } label: {
            GlassIcon(systemName: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profiles")
        .popover(isPresented: $showsSave, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save Profile").font(.headline)
                TextField("Name, e.g. Desk or Presenting", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Text("Saves virtual displays, mirrors, placement, brightness and XDR Boost. An existing name is replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { showsSave = false }
                    Button("Save", action: save)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private func save() {
        profiles.saveCurrent(named: name)
        showsSave = false
    }
}

