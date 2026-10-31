import CoreGraphics
import Foundation

/// How captured content is shown in a preview: an optional crop, quarter turns
/// clockwise and a horizontal flip. All points are normalized (0...1) with a
/// top-left origin, so the same maths serves cursor capture and crop selection.
struct PreviewGeometry: Equatable {
    /// Part of the full content shown; the unit rect means no crop.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var quarterTurns = 0
    var flipped = false

    var isCropped: Bool { crop != CGRect(x: 0, y: 0, width: 1, height: 1) }
    var isTransformed: Bool { quarterTurns != 0 || flipped }

    /// Width / height of the preview for content of the given size.
    func aspect(for content: CGSize) -> CGSize {
        let size = CGSize(width: content.width * crop.width, height: content.height * crop.height)
        return quarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// View point → point in the full content.
    func contentPoint(fromView view: CGPoint) -> CGPoint {
        var u = view.x, v = view.y
        if flipped { u = 1 - u }
        let local: CGPoint
        switch quarterTurns & 3 {
        case 1: local = CGPoint(x: v, y: 1 - u)
        case 2: local = CGPoint(x: 1 - u, y: 1 - v)
        case 3: local = CGPoint(x: 1 - v, y: u)
        default: local = CGPoint(x: u, y: v)
        }
        return CGPoint(x: crop.minX + local.x * crop.width, y: crop.minY + local.y * crop.height)
    }

    /// Point in the full content → view point (inverse of `contentPoint`).
    func viewPoint(fromContent content: CGPoint) -> CGPoint {
        let x = (content.x - crop.minX) / crop.width
        let y = (content.y - crop.minY) / crop.height
        var view: CGPoint
        switch quarterTurns & 3 {
        case 1: view = CGPoint(x: 1 - y, y: x)
        case 2: view = CGPoint(x: 1 - x, y: 1 - y)
        case 3: view = CGPoint(x: y, y: 1 - x)
        default: view = CGPoint(x: x, y: y)
        }
        if flipped { view.x = 1 - view.x }
        return view
    }

    /// Narrows the crop to a rect selected in view space.
    mutating func cropToViewRect(_ rect: CGRect) {
        let a = contentPoint(fromView: CGPoint(x: rect.minX, y: rect.minY))
        let b = contentPoint(fromView: CGPoint(x: rect.maxX, y: rect.maxY))
        let selected = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        crop = selected.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Preview defaults shared by all preview windows.
enum PreviewSettings {
    static let frameRates = [15, 30, 60, 120]

    static var framesPerSecond: Int {
        get { UserDefaults.standard.object(forKey: "previewFPS") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "previewFPS") }
    }

    static var keepOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "previewKeepOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "previewKeepOnTop") }
    }

    /// Keep streaming (slowly) while minimized so the Dock thumbnail stays live.
    static var liveDockThumbnail: Bool {
        get { UserDefaults.standard.bool(forKey: "previewLiveDock") }
        set { UserDefaults.standard.set(newValue, forKey: "previewLiveDock") }
    }
}
