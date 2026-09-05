import AppKit

/// Ikona w pasku menu rysowana kodem - jako obraz szablonowy sama dostosowuje sie
/// do jasnego i ciemnego paska oraz do trybu podswietlenia, bez zadnych plikow PNG.
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setLineJoin(.round)

            // Dwa okna w tle - sam obrys, coraz slabszy w glab.
            drawWindow(context, rect: CGRect(x: 6.5, y: 5.6, width: 11.0, height: 8.0),
                       filled: false, alpha: 0.38, lineWidth: 1.1)
            drawWindow(context, rect: CGRect(x: 3.4, y: 3.0, width: 11.0, height: 8.0),
                       filled: false, alpha: 0.62, lineWidth: 1.1)
            // Okno na wierzchu - pelne, z paskiem tytulu wycietym w srodku.
            drawWindow(context, rect: CGRect(x: 0.5, y: 0.4, width: 11.0, height: 8.0),
                       filled: true, alpha: 1.0, lineWidth: 1.1)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawWindow(
        _ context: CGContext,
        rect: CGRect,
        filled: Bool,
        alpha: CGFloat,
        lineWidth: CGFloat
    ) {
        let path = CGPath(roundedRect: rect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)
        context.saveGState()
        context.setAlpha(alpha)
        if filled {
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            // Pasek tytulu jako przerwa w wypelnieniu.
            let bar = CGRect(x: rect.minX + 1.4, y: rect.maxY - 3.0, width: rect.width - 2.8, height: 1.4)
            context.setBlendMode(.clear)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
            context.fillPath()
            context.setBlendMode(.normal)
        } else {
            context.addPath(path)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
        context.restoreGState()
    }
}
