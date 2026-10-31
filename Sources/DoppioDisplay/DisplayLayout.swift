import AppKit
import CoreGraphics

/// Display arrangement through the public Quartz display configuration API.
enum DisplayLayout {
    /// Display that saved positions are relative to: the built-in panel, or the main display when the lid is closed.
    static func anchor(excluding display: CGDirectDisplayID = kCGNullDirectDisplay) -> CGDirectDisplayID {
        DisplayManager.onlineDisplayIDs().first { CGDisplayIsBuiltin($0) != 0 && $0 != display } ?? CGMainDisplayID()
    }

    /// Applies a virtual display's saved position, if any.
    @discardableResult
    static func apply(_ config: VirtualDisplayConfig, to display: CGDirectDisplayID) -> CGError {
        if let relative = config.relativeOrigin {
            return move(display, relativeOrigin: relative)
        }
        return place(display, config.placement)
    }

    /// Moves `display` so its top-left sits at `relativeOrigin` from the anchor's top-left.
    @discardableResult
    static func move(_ display: CGDirectDisplayID, relativeOrigin: CGPoint) -> CGError {
        let anchorID = anchor(excluding: display)
        guard anchorID != display else { return .success }
        let base = CGDisplayBounds(anchorID).origin
        return configure { config in
            CGConfigureDisplayOrigin(config, display, Int32((base.x + relativeOrigin.x).rounded()),
                                     Int32((base.y + relativeOrigin.y).rounded()))
        }
    }

    /// Puts `display` next to the built-in panel (or the main display when the lid is closed).
    @discardableResult
    static func place(_ display: CGDirectDisplayID, _ placement: DisplayPlacement) -> CGError {
        guard placement != .automatic else { return .success }
        let anchorID = anchor(excluding: display)
        guard anchorID != display else { return .success }
        let anchor = CGDisplayBounds(anchorID)
        let size = CGDisplayBounds(display).size
        let origin: CGPoint
        switch placement {
        case .automatic: return .success
        case .left: origin = CGPoint(x: anchor.minX - size.width, y: anchor.minY)
        case .right: origin = CGPoint(x: anchor.maxX, y: anchor.minY)
        case .above: origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height)
        case .below: origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY)
        }
        return configure { config in
            CGConfigureDisplayOrigin(config, display, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        }
    }

    /// The main display (menu bar, Dock) is the one at the global origin;
    /// shift every display so `display` lands there.
    @discardableResult
    static func makeMain(_ display: CGDirectDisplayID) -> CGError {
        let offset = CGDisplayBounds(display).origin
        guard offset != .zero else { return .success }
        // Mirrors follow their master, so only move displays that are not mirroring.
        let movable = DisplayManager.onlineDisplayIDs().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        return configure { config in
            for id in movable {
                let bounds = CGDisplayBounds(id)
                CGConfigureDisplayOrigin(config, id, Int32(bounds.minX - offset.x), Int32(bounds.minY - offset.y))
            }
        }
    }

    private static func configure(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { return begin }
        body(config)
        return CGCompleteDisplayConfiguration(config, .forSession)
    }
}
