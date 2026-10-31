import SwiftUI

/// Scaled map of all displays. Virtual displays can be dragged: the dragged
/// screen follows the pointer, a dashed ghost shows where it will snap (the
/// nearest side of another display), and on release it glides there.
/// The white strip marks the main display (menu bar and Dock).
struct ArrangementMap: View {
    private var store: DisplayStore { .shared }
    @State private var drag: Drag?
    /// Where a released screen is gliding to, until the real arrangement catches up.
    @State private var settling: (id: CGDirectDisplayID, frame: CGRect)?
    /// Scale and offset are frozen while dragging and settling so nothing else moves.
    @State private var frozen: Transform?

    private struct Item: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
        let configID: UUID?
        let mirroredBy: String?
        var isVirtual: Bool { configID != nil }
    }

    private struct Drag {
        let id: CGDirectDisplayID
        var proposed: CGRect
        var snapped: CGRect?
    }

    private static let glide = Animation.snappy(duration: 0.28)

    var body: some View {
        let items = self.items
        GeometryReader { proxy in
            let transform = frozen ?? Transform(items: items.map(\.frame), size: proxy.size)
            ZStack(alignment: .topLeading) {
                if let ghost = drag?.snapped {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                        .frame(width: ghost.width * transform.scale, height: ghost.height * transform.scale)
                        .position(transform.point(CGPoint(x: ghost.midX, y: ghost.midY)))
                        .animation(.snappy(duration: 0.16), value: ghost)
                }
                ForEach(items) { item in
                    let isDragging = drag?.id == item.id
                    let frame = isDragging ? drag!.proposed : (settling?.id == item.id ? settling!.frame : item.frame)
                    screen(item, lifted: isDragging)
                        .frame(width: frame.width * transform.scale, height: frame.height * transform.scale)
                        .position(transform.point(CGPoint(x: frame.midX, y: frame.midY)))
                        // The dragged screen tracks the pointer 1:1; everything else glides.
                        .animation(isDragging ? nil : Self.glide, value: frame)
                        .gesture(item.isVirtual ? dragGesture(item, items: items, transform: transform) : nil)
                        .zIndex(isDragging ? 2 : 1)
                }
            }
            .animation(Self.glide, value: transform)
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.22)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var items: [Item] {
        _ = store.layoutRevision
        var result: [Item] = []
        let virtualIDs = Set(store.liveIDs.values)
        for display in store.physicalDisplays where display.mirrorMaster == kCGNullDirectDisplay {
            result.append(Item(id: display.id, name: display.isBuiltin ? "Built-in" : display.name,
                               frame: CGDisplayBounds(display.id), configID: nil, mirroredBy: mirrors(of: display.id)))
        }
        for config in store.configs {
            // A virtual display that mirrors another one has no place of its own in the arrangement.
            guard let vid = store.liveIDs[config.id], virtualIDs.contains(vid),
                  CGDisplayMirrorsDisplay(vid) == kCGNullDirectDisplay else { continue }
            result.append(Item(id: vid, name: config.name, frame: CGDisplayBounds(vid), configID: config.id,
                               mirroredBy: mirrors(of: vid)))
        }
        return result
    }

    private func mirrors(of id: CGDirectDisplayID) -> String? {
        let names = store.physicalDisplays.filter { $0.mirrorMaster == id }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private func screen(_ item: Item, lifted: Bool) -> some View {
        let isMain = item.id == CGMainDisplayID()
        return RoundedRectangle(cornerRadius: 4)
            .fill(item.isVirtual
                  ? AnyShapeStyle(LinearGradient(colors: [.accentColor.opacity(0.6), .purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                  : AnyShapeStyle(Color.white.opacity(0.2)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(item.isVirtual ? Color.accentColor : .white.opacity(0.4), lineWidth: 1.5))
            .overlay(alignment: .top) {
                if isMain {
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).fill(.white.opacity(0.9)).frame(height: 4)
                }
            }
            .overlay {
                VStack(spacing: 1) {
                    Text(item.name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                    Text("\(Int(item.frame.width)) × \(Int(item.frame.height))").font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
                .padding(2)
            }
            .overlay(alignment: .bottomTrailing) {
                if let mirror = item.mirroredBy {
                    Label(mirror, systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 8))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.black.opacity(0.35)))
                        .padding(3)
                }
            }
            .scaleEffect(lifted ? 1.04 : 1)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
            .animation(.snappy(duration: 0.15), value: lifted)
            .help(item.isVirtual ? "Drag to move \(item.name)" : item.name)
    }

    // MARK: Dragging

    private func dragGesture(_ item: Item, items: [Item], transform: Transform) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if frozen == nil { frozen = transform }
                var proposed = item.frame
                proposed.origin.x += value.translation.width / transform.scale
                proposed.origin.y += value.translation.height / transform.scale
                let others = items.filter { $0.id != item.id }.map(\.frame)
                drag = Drag(id: item.id, proposed: proposed, snapped: Self.snap(proposed, to: others))
            }
            .onEnded { _ in
                guard let current = drag else { return }
                let target = current.snapped ?? item.frame
                // Hand the screen from the pointer to the glide animation.
                settling = (item.id, current.proposed)
                drag = nil
                withAnimation(Self.glide) { settling = (item.id, target) }
                // Reconfiguring displays blocks the main thread for a moment, which would freeze
                // the glide mid-way; apply the arrangement once the animation has played.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                    if let snapped = current.snapped, let configID = item.configID {
                        let anchor = CGDisplayBounds(DisplayLayout.anchor(excluding: item.id)).origin
                        store.setPosition(configID, relativeOrigin: CGPoint(
                            x: (snapped.minX - anchor.x).rounded(), y: (snapped.minY - anchor.y).rounded()
                        ))
                    }
                    // Then let the map re-fit smoothly to the new arrangement.
                    DispatchQueue.main.async {
                        withAnimation(Self.glide) {
                            settling = nil
                            frozen = nil
                        }
                    }
                }
            }
    }

    /// Closest position touching a side of another display, keeping some overlap along that side,
    /// magnetised to edge and centre alignment, and never overlapping anything.
    static func snap(_ rect: CGRect, to others: [CGRect]) -> CGRect? {
        let minOverlap: CGFloat = 80
        let magnet: CGFloat = 70
        var best: (frame: CGRect, distance: CGFloat)?
        for other in others {
            let clampY = { (y: CGFloat) in min(max(y, other.minY - rect.height + minOverlap), other.maxY - minOverlap) }
            let clampX = { (x: CGFloat) in min(max(x, other.minX - rect.width + minOverlap), other.maxX - minOverlap) }
            let candidates: [(CGPoint, Bool)] = [
                (CGPoint(x: other.maxX, y: clampY(rect.minY)), true),
                (CGPoint(x: other.minX - rect.width, y: clampY(rect.minY)), true),
                (CGPoint(x: clampX(rect.minX), y: other.maxY), false),
                (CGPoint(x: clampX(rect.minX), y: other.minY - rect.height), false),
            ]
            for (origin, vertical) in candidates {
                var origin = origin
                let targets = vertical
                    ? [other.minY, other.maxY - rect.height, other.midY - rect.height / 2]
                    : [other.minX, other.maxX - rect.width, other.midX - rect.width / 2]
                // Snap to the closest alignment within reach, not the last one checked.
                let current = vertical ? origin.y : origin.x
                if let target = targets.min(by: { abs($0 - current) < abs($1 - current) }),
                   abs(target - current) < magnet {
                    if vertical { origin.y = target } else { origin.x = target }
                }
                let frame = CGRect(origin: origin, size: rect.size)
                guard !others.contains(where: { $0.insetBy(dx: 1, dy: 1).intersects(frame) }) else { continue }
                let distance = hypot(origin.x - rect.minX, origin.y - rect.minY)
                if best == nil || distance < best!.distance {
                    best = (frame, distance)
                }
            }
        }
        return best?.frame
    }

    /// Display points → map points, fitting all displays with room to drag around them.
    private struct Transform: Equatable {
        let scale: CGFloat
        let offset: CGPoint

        init(items: [CGRect], size: CGSize) {
            let union = items.reduce(CGRect.null) { $0.union($1) }
            let margin = (items.map { max($0.width, $0.height) }.max() ?? 1000) * 0.6
            let padded = union.isNull ? CGRect(x: 0, y: 0, width: 1000, height: 600) : union.insetBy(dx: -margin, dy: -margin * 0.5)
            scale = min(size.width / padded.width, size.height / padded.height)
            offset = CGPoint(x: size.width / 2 - padded.midX * scale, y: size.height / 2 - padded.midY * scale)
        }

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale)
        }
    }
}
