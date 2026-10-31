import SwiftUI

// Building blocks for the menu bar panel. Every control uses one of these so
// buttons, menus and rows look the same everywhere.

/// Expanded cards survive closing and reopening the panel.
@MainActor
@Observable
final class PanelState {
    static let shared = PanelState()
    var expanded: Set<String> = []

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    /// Shows exactly these cards expanded, by short name: "builtin", "virtual" (all),
    /// "external" (all), "arrangement", "color" (built-in color section).
    func expand(_ names: [String]) {
        let store = DisplayStore.shared
        expanded = []
        for name in names {
            switch name {
            case "builtin":
                if let builtin = store.physicalDisplays.first(where: \.isBuiltin) { expanded.insert("display-\(builtin.key)") }
            case "external":
                for display in store.physicalDisplays where !display.isBuiltin { expanded.insert("display-\(display.key)") }
            case "virtual":
                for config in store.configs { expanded.insert("virtual-\(config.id.uuidString)") }
            case "color":
                if let builtin = store.physicalDisplays.first(where: \.isBuiltin) { expanded.insert("color-\(builtin.key)") }
            default:
                expanded.insert(name)
            }
        }
    }

    /// Layout changes are not animated: the menu bar window resizes in one step, and
    /// sliding rows against a jumping frame looks broken. Only the revealed content
    /// animates (see `revealTransition`).
    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

extension AnyTransition {
    /// Expanded content fades in and settles from slightly above; collapsing is instant,
    /// because the window has already shrunk by the time a fade-out would play.
    static var reveal: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97, anchor: .top))
                .combined(with: .offset(y: -6))
                .animation(.smooth(duration: 0.32)),
            removal: .identity
        )
    }
}

/// Round glass icon used for header buttons and menus alike.
struct GlassIcon: View {
    let systemName: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// A card with a tappable header that expands into settings.
struct DisplayCard<Header: View, Trailing: View, Collapsed: View, Content: View>: View {
    let id: String
    @ViewBuilder var header: Header
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var collapsed: Collapsed
    @ViewBuilder var content: Content
    private var state: PanelState { .shared }

    var body: some View {
        let open = state.isExpanded(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                header
                Spacer(minLength: 6)
                trailing
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.snappy(duration: 0.2), value: open)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(.rect)
            .onTapGesture { state.toggle(id) }

            if open {
                VStack(alignment: .leading, spacing: 8) { content }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.reveal)
            } else {
                collapsed
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Icon in a circle + name + subtitle, used as a card header.
struct CardTitle<Badges: View>: View {
    let systemName: String
    let title: String
    let subtitle: String
    var active = false
    @ViewBuilder var badges: Badges

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.white.opacity(0.14))))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    badges
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.12 : 0.2)))
    }
}

/// Grouped rows with hairline separators, like an inset list.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                // Rows that appear later (Color details, XDR level, Night Shift strength) reveal the same way cards do.
                ForEach(subviews) { subview in
                    VStack(spacing: 0) {
                        if subview.id != subviews.first?.id { Divider().opacity(0.6) }
                        subview
                    }
                    .transition(.reveal)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.16)))
    }
}

/// "Label …… trailing" row.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(title)
            if let hint { Text(hint).font(.caption).foregroundStyle(.tertiary) }
            Spacer(minLength: 8)
            trailing
        }
        .font(.callout)
        .frame(minHeight: 34)
        .padding(.horizontal, 10)
    }
}

/// Value shown in secondary text that opens a menu: the right side of a settings row.
struct ValueMenu<Content: View>: View {
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            // One Text, so borderless menu styling cannot move the chevron in front of the value.
            Text("\(value)  \(Image(systemName: "chevron.up.chevron.down"))")
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SwitchToggle: View {
    let isOn: Binding<Bool>

    var body: some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

struct SliderRow: View {
    let lowIcon: String
    let highIcon: String
    let value: Binding<Double>
    var tint: Color? = nil
    var label: ((Double) -> String)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lowIcon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
                .tint(tint)
            Image(systemName: highIcon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(label?(value.wrappedValue) ?? "\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 10)
    }
}

/// Uniform action button at the bottom of a card.
struct CardActionStyle: ButtonStyle {
    var role: ButtonRole? = nil
    var iconOnly = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            .frame(maxWidth: iconOnly ? nil : .infinity)
            .frame(width: iconOnly ? 36 : nil, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : 0.1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(.rect)
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 12))
    }
}

struct MethodChip: View {
    let method: BrightnessMethod

    var body: some View {
        Chip(text: method.rawValue, tint: tint).help(help)
    }

    private var tint: Color {
        switch method {
        case .native: .green
        case .ddc: .blue
        case .software: .orange
        }
    }

    private var help: String {
        switch method {
        case .native: "Hardware backlight via macOS DisplayServices"
        case .ddc: "Hardware brightness via DDC/CI"
        case .software: "No hardware control found; dims the image with gamma"
        }
    }
}
