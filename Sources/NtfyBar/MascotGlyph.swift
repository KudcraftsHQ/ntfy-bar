import AppKit

/// The ntfy mascot (a rounded tile wearing its notification badge) as a one-colour template image,
/// for the menu bar and anywhere else an SF Symbol bell used to be. Drawn from vector paths so it
/// stays crisp at every scale; the source is design/logo/tray/*.svg.
enum MascotGlyph {
    enum State {
        /// Outline, eyes open.
        case idle
        /// Filled, eyes cut out, badge on the corner.
        case unread
        /// Outline, eyes closed. Not configured, or the server refused the credentials.
        case asleep
    }

    static func image(_ state: State, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Artwork lives in a 100-unit box; this crop is the glyph's bounds within it.
            let viewBox = CGRect(x: 9, y: 5, width: 88, height: 88)
            ctx.scaleBy(x: rect.width / viewBox.width, y: rect.height / viewBox.height)
            ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)
            draw(state, in: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ntfy"
        return image
    }

    private static var body: CGPath {
        CGPath(roundedRect: CGRect(x: 16, y: 24, width: 62, height: 62),
               cornerWidth: 20, cornerHeight: 20, transform: nil)
    }
    private static let eyes = [CGPoint(x: 36, y: 56), CGPoint(x: 58, y: 56)]
    private static let badge = CGPoint(x: 78, y: 24)

    private static func draw(_ state: State, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch state {
        case .unread:
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            for eye in eyes { ctx.fillEllipse(in: circle(eye, 6.4)) }
            ctx.fillEllipse(in: circle(badge, 19))  // gap between badge and tile
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: circle(badge, 13))
        case .idle:
            outline(ctx)
            for eye in eyes { ctx.fillEllipse(in: circle(eye, 6.4)) }
        case .asleep:
            outline(ctx)
            ctx.setLineWidth(6)
            for eye in eyes {
                ctx.move(to: CGPoint(x: eye.x - 5, y: eye.y))
                ctx.addQuadCurve(to: CGPoint(x: eye.x + 5, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + 4))
            }
            ctx.strokePath()
        }
    }

    private static func outline(_ ctx: CGContext) {
        ctx.setLineWidth(8.5)
        ctx.addPath(body)
        ctx.strokePath()
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }
}
