import AppKit

/// The DoppioDisplay icon, drawn in code so the app needs no asset catalog.
/// Geometry mirrors `design/tools/make-doppio-icon.py` (1024 macOS icon grid,
/// body 824×824 at 100,100): a real display in front of its dashed virtual twin.
enum AppIcon {
    /// The bundle's compiled glass icon when running as an app; the code-drawn one otherwise.
    static let image: NSImage = {
        if Bundle.main.bundleIdentifier != nil, let icon = NSImage(named: NSImage.applicationIconName),
           icon.representations.contains(where: { $0.pixelsWide >= 256 }) {
            return icon
        }
        return render(size: 1024)
    }()

    /// Menu bar glyph styles (Settings › General). Both drop the stand: at 18 pt it was too small to read.
    enum MenuBarStyle: String, CaseIterable, Identifiable {
        /// Filled display in front of an outlined twin.
        case twin
        /// Both displays outlined, the front one with a filled screen.
        case outline

        var id: String { rawValue }
        var title: String { self == .twin ? "Twin" : "Outline" }
    }

    /// Template image for the menu bar; macOS tints it for light and dark bars.
    static func menuBarImage(_ style: MenuBarStyle) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let back = CGRect(x: 1.25, y: 2.5, width: 11, height: 8)
            let front = CGRect(x: 5.75, y: 7.5, width: 11, height: 8)
            let radius: CGFloat = 1.9
            NSColor.black.set()

            // The twin is cut away around the front display, leaving a clean gap.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 18, height: 18))
            clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -1.4, dy: -1.4), xRadius: radius + 1.4, yRadius: radius + 1.4))
            clip.windingRule = .evenOdd
            clip.addClip()
            let twin = NSBezierPath(roundedRect: back, xRadius: radius, yRadius: radius)
            twin.lineWidth = 1.5
            twin.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let display = NSBezierPath(roundedRect: front, xRadius: radius, yRadius: radius)
            switch style {
            case .twin:
                display.fill()
            case .outline:
                display.lineWidth = 1.5
                display.stroke()
                NSBezierPath(roundedRect: front.insetBy(dx: 2.4, dy: 2.4), xRadius: 0.7, yRadius: 0.7).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Geometry (1024 grid)

    private static let screen = CGSize(width: 440, height: 300)
    private static let screenRadius: CGFloat = 44
    private static let offset: CGFloat = 120
    private static let bezel: CGFloat = 20
    private static let stand = CGSize(width: 96, height: 20)
    private static let standGap: CGFloat = 22
    private static let dashes = 20
    private static let dashFill: CGFloat = 0.62

    private static var back: CGPoint {
        let groupWidth = screen.width + offset
        let groupHeight = screen.height + offset + standGap + stand.height
        return CGPoint(x: 512 - groupWidth / 2, y: 512 - groupHeight / 2 + 4)
    }
    private static var front: CGPoint { CGPoint(x: back.x + offset, y: back.y + offset) }

    /// `simplified` drops fine detail for 16–32 px, where dashes and highlights turn to mush.
    static func render(size: CGFloat, simplified: Bool? = nil) -> NSImage {
        let simple = simplified ?? (size <= 32)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Shadow offsets and blur ignore the CTM, so they are scaled by hand.
            let scale = size / 1024
            context.scaleBy(x: scale, y: scale)
            drawBody(in: context, simple: simple)
            drawTwin(in: context, simple: simple, scale: scale)
            drawFront(in: context, simple: simple, scale: scale)
            return true
        }
    }

    private static func drawBody(in context: CGContext, simple: Bool) {
        let body = squircle(center: CGPoint(x: 512, y: 512), size: 824)
        context.saveGState()
        context.addPath(body)
        context.clip()
        linearGradient([("#7B65FF", 0), ("#4C6DFF", 0.55), ("#1E9CFF", 1)],
                       from: CGPoint(x: 100 + 0.15 * 824, y: 100), to: CGPoint(x: 100 + 0.85 * 824, y: 924), in: context)
        if !simple {
            let shine = CGGradient(colorsSpace: nil, colors: [
                NSColor.white.withAlphaComponent(0.34).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray, locations: [0, 0.65])!
            let center = CGPoint(x: 100 + 0.32 * 824, y: 100 + 0.08 * 824)
            context.drawRadialGradient(shine, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: 0.85 * 824, options: [])
        }
        context.restoreGState()
        if !simple {
            context.addPath(body)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
            context.setLineWidth(3)
            context.strokePath()
        }
    }

    private static func drawTwin(in context: CGContext, simple: Bool, scale: CGFloat) {
        let rect = CGRect(origin: back, size: screen)
        let path = roundedRectFromTopCenter(rect, radius: screenRadius)
        NSGraphicsContext.saveGraphicsState()
        if simple {
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 34
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.16).setFill()
            path.fill()
            // Evenly spaced dashes with a soft glow underneath.
            let glow = NSShadow()
            glow.shadowColor = NSColor.white.withAlphaComponent(0.55)
            glow.shadowBlurRadius = 18 * scale
            glow.shadowOffset = .zero
            glow.set()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 14
            path.lineCapStyle = .round
            setDashes(on: path, count: dashes)
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFront(in context: CGContext, simple: Bool, scale: CGFloat) {
        let outer = CGRect(origin: front, size: screen)
        let inner = outer.insetBy(dx: bezel, dy: bezel)
        let innerRadius = screenRadius - bezel + 4
        let standRect = CGRect(x: outer.midX - stand.width / 2, y: outer.maxY + standGap,
                               width: stand.width, height: stand.height)

        context.saveGState()
        if !simple {
            // Device space has a bottom-left origin: a negative y offset casts the shadow downwards.
            context.setShadow(offset: CGSize(width: 0, height: -22 * scale),
                              blur: 48 * scale, color: NSColor(hex: "#0A1060").withAlphaComponent(0.42).cgColor)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        // Bezel.
        context.saveGState()
        context.addPath(CGPath(roundedRect: outer, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
        context.clip()
        linearGradient([("#FFFFFF", 0), ("#DCE3FF", 1)],
                       from: CGPoint(x: outer.midX, y: outer.minY), to: CGPoint(x: outer.midX, y: outer.maxY), in: context)
        context.restoreGState()

        // Wallpaper and menu bar.
        context.saveGState()
        context.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
        context.clip()
        linearGradient([("#2F45FF", 0), ("#6A4DFF", 0.55), ("#F06BB4", 1)],
                       from: CGPoint(x: inner.minX, y: inner.minY), to: CGPoint(x: inner.maxX, y: inner.maxY), in: context)
        if !simple {
            context.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            context.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 18))
        }
        context.restoreGState()

        // Stand.
        context.addPath(CGPath(roundedRect: standRect, cornerWidth: stand.height / 2, cornerHeight: stand.height / 2, transform: nil))
        context.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.fillPath()

        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Helpers

    /// Superellipse |x|^5 + |y|^5 = 1: the continuous-corner shape of macOS icons.
    private static func squircle(center: CGPoint, size: CGFloat, n: CGFloat = 5, steps: Int = 720) -> CGPath {
        let path = CGMutablePath()
        let a = size / 2
        for i in 0..<steps {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: center.x + a * copysign(pow(abs(c), 2 / n), c),
                                y: center.y + a * copysign(pow(abs(s), 2 / n), s))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// Rounded rect starting at the middle of the top edge, so dashes come out symmetric.
    private static func roundedRectFromTopCenter(_ rect: CGRect, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 0)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(withCenter: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        path.line(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }

    /// `count` equal dashes around the path, the first one centred on its start point.
    private static func setDashes(on path: NSBezierPath, count: Int) {
        let length = pathLength(path)
        let period = length / CGFloat(count)
        let pattern: [CGFloat] = [period * dashFill, period * (1 - dashFill)]
        path.setLineDash(pattern, count: 2, phase: period * dashFill / 2)
    }

    private static func pathLength(_ path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var length: CGFloat = 0
        var start = CGPoint.zero, last = CGPoint.zero
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<flat.elementCount {
            switch flat.element(at: index, associatedPoints: &points) {
            case .moveTo: start = points[0]; last = start
            case .lineTo: length += hypot(points[0].x - last.x, points[0].y - last.y); last = points[0]
            case .closePath: length += hypot(start.x - last.x, start.y - last.y); last = start
            default: break
            }
        }
        return length
    }

    private static func linearGradient(_ stops: [(String, CGFloat)], from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: stops.map { NSColor(hex: $0.0).cgColor } as CFArray,
                                  locations: stops.map(\.1))!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Export

    static func exportMenuBarGlyphs(to directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for style in MenuBarStyle.allCases {
            let glyph = menuBarImage(style)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            glyph.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: directory.appendingPathComponent("menubar-\(style.rawValue).png"))) != nil else { return false }
        }
        return true
    }

    static func exportIconset(to directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let pixels = base * factor
                let suffix = factor == 2 ? "@2x" : ""
                let url = directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
                guard let png = pngData(pixels: pixels), (try? png.write(to: url)) != nil else { return false }
            }
        }
        return true
    }

    private static func pngData(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

private extension CGRect {
    func scaled(_ factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
