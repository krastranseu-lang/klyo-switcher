import CoreGraphics
import Foundation
import ImageIO

// Generator ikony aplikacji. Uruchamiany raz podczas instalacji, rysuje komplet
// rozmiarow do katalogu .iconset, z ktorego `iconutil` sklada plik .icns.
// Zadnych zewnetrznych grafik - wszystko liczone tutaj.

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let names: [Int: [String]] = [
    16: ["icon_16x16"],
    32: ["icon_16x16@2x", "icon_32x32"],
    64: ["icon_32x32@2x"],
    128: ["icon_128x128"],
    256: ["icon_128x128@2x", "icon_256x256"],
    512: ["icon_256x256@2x", "icon_512x512"],
    1024: ["icon_512x512@2x"]
]

func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2237,
        cornerHeight: rect.height * 0.2237,
        transform: nil
    )
}

func windowPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage? {
    let side = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    // macOS zostawia wokol ikony powietrze - bez tego wyglada wieksza niz sasiednie.
    let inset = side * 0.055
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let plateShape = squirclePath(in: plate)

    // Cien pod plytka.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.012),
        blur: side * 0.045,
        color: rgb(0, 0, 0, 0.38)
    )
    context.addPath(plateShape)
    context.setFillColor(rgb(20, 23, 29))
    context.fillPath()
    context.restoreGState()

    // Grafitowe tlo z lekkim pionowym przejsciem.
    context.saveGState()
    context.addPath(plateShape)
    context.clip()
    let backdrop = CGGradient(
        colorsSpace: space,
        colors: [rgb(60, 68, 84), rgb(31, 35, 44), rgb(18, 20, 26)] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )

    // Delikatny polysk przy gornej krawedzi.
    let gloss = CGGradient(
        colorsSpace: space,
        colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        gloss,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.midY + plate.height * 0.12),
        options: []
    )
    context.restoreGState()

    // Stos okien: dwa w tle, jedno na wierzchu w kolorze akcentu.
    let windowWidth = plate.width * 0.56
    let windowHeight = windowWidth * 0.70
    let radius = windowWidth * 0.11
    let step = plate.width * 0.085
    let originX = plate.minX + plate.width * 0.16
    let originY = plate.minY + plate.height * 0.20

    let back = CGRect(
        x: originX + step * 2, y: originY + step * 2,
        width: windowWidth, height: windowHeight
    )
    let middle = CGRect(
        x: originX + step, y: originY + step,
        width: windowWidth, height: windowHeight
    )
    let front = CGRect(x: originX, y: originY, width: windowWidth, height: windowHeight)

    func drawBackdropWindow(_ rect: CGRect, fill: CGColor, stroke: CGColor) {
        context.saveGState()
        context.addPath(windowPath(rect, radius: radius))
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(windowPath(rect.insetBy(dx: 0.5, dy: 0.5), radius: radius))
        context.setStrokeColor(stroke)
        context.setLineWidth(max(1, side * 0.004))
        context.strokePath()
        context.restoreGState()
    }

    drawBackdropWindow(back, fill: rgb(255, 255, 255, 0.13), stroke: rgb(255, 255, 255, 0.16))
    drawBackdropWindow(middle, fill: rgb(255, 255, 255, 0.22), stroke: rgb(255, 255, 255, 0.20))

    // Przednie okno - jedyne miejsce z mocnym kolorem.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -side * 0.008),
        blur: side * 0.03,
        color: rgb(0, 0, 0, 0.45)
    )
    context.addPath(windowPath(front, radius: radius))
    context.setFillColor(rgb(255, 122, 82))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(windowPath(front, radius: radius))
    context.clip()
    let accent = CGGradient(
        colorsSpace: space,
        colors: [rgb(255, 149, 105), rgb(224, 88, 55)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        accent,
        start: CGPoint(x: front.midX, y: front.maxY),
        end: CGPoint(x: front.midX, y: front.minY),
        options: []
    )

    // Pasek tytulu i dwie "kropki" okna - czytelne nawet w 32 px.
    let barHeight = front.height * 0.22
    context.setFillColor(rgb(255, 255, 255, 0.24))
    context.fill(CGRect(x: front.minX, y: front.maxY - barHeight, width: front.width, height: barHeight))

    let dotRadius = barHeight * 0.17
    let dotY = front.maxY - barHeight / 2
    for index in 0..<2 {
        let dotX = front.minX + barHeight * (0.55 + Double(index) * 0.52)
        context.setFillColor(rgb(255, 255, 255, 0.75))
        context.fillEllipse(in: CGRect(
            x: dotX - dotRadius, y: dotY - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        ))
    }
    context.restoreGState()

    // Cienki jasny obrys calej plytki - daje wrazenie szkla.
    context.saveGState()
    context.addPath(squirclePath(in: plate.insetBy(dx: 0.5, dy: 0.5)))
    context.setStrokeColor(rgb(255, 255, 255, 0.13))
    context.setLineWidth(max(1, side * 0.0035))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()
}

var failures = 0
for size in sizes {
    guard let image = drawIcon(size: size) else {
        failures += 1
        continue
    }
    for name in names[size] ?? [] {
        let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            failures += 1
            continue
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { failures += 1 }
    }
}

if failures > 0 {
    FileHandle.standardError.write("icongen: nie udało się zapisać \(failures) plików\n".data(using: .utf8)!)
    exit(1)
}
