import AppKit

/// The menu-bar icon: a tower purifier glyph (hollow loop on a small
/// cylinder base) with two airflow arcs to its right. Rendered as a
/// template image so it follows the menu-bar appearance (white in dark
/// mode, black in light mode — always visible).
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawIcon()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawIcon() {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // base: a short cylinder
        let base = NSBezierPath(roundedRect: NSRect(x: 2.85, y: 1.65, width: 6.3, height: 4.9), xRadius: 1.6, yRadius: 1.6)
        base.lineWidth = 1.3
        base.stroke()

        // hollow loop standing on the base
        let loopRect = NSRect(x: 3.35, y: 8.3, width: 5.3, height: 9.0)
        let loop = NSBezierPath(roundedRect: loopRect, xRadius: loopRect.width / 2, yRadius: loopRect.width / 2)
        loop.lineWidth = 1.3
        loop.stroke()

        // airflow: two short arcs leaving the loop toward the right
        let arcs: [(from: NSPoint, to: NSPoint, control: NSPoint)] = [
            (NSPoint(x: 11, y: 14.6), NSPoint(x: 16.9, y: 12.4), NSPoint(x: 14.4, y: 14.9)),
            (NSPoint(x: 11, y: 10.6), NSPoint(x: 15.4, y: 8.6), NSPoint(x: 13.6, y: 10.8)),
        ]
        for arc in arcs {
            let path = NSBezierPath()
            path.move(to: arc.from)
            path.curve(to: arc.to, controlPoint1: arc.control, controlPoint2: arc.control)
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
