import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Zrzut zaznaczonego fragmentu ekranu, od razu sciesniety do zadanego rozmiaru pliku.
/// Powstal po to, zeby zrzuty z Retiny (czesto 5-8 MB PNG) miescily sie w limitach
/// okien czatu, do ktorych sie je wkleja.
enum ScreenshotService {
    struct Result {
        let url: URL?
        let byteCount: Int
        let pixelSize: NSSize
        let quality: Double
    }

    private static let queue = DispatchQueue(label: "pl.klyo.switcher.screenshot", qos: .userInitiated)
    private static var isCapturing = false

    static func captureSelection(completion: @escaping (Result?, String?) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true

        let rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("klyo-shot-\(UInt32.random(in: 0...UInt32.max)).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i wybor myszka, -o bez cienia okna, -r bez metadanych ekranu.
        process.arguments = ["-i", "-o", "-r", rawURL.path]

        process.terminationHandler = { _ in
            queue.async {
                defer {
                    try? FileManager.default.removeItem(at: rawURL)
                    DispatchQueue.main.async { isCapturing = false }
                }
                guard FileManager.default.fileExists(atPath: rawURL.path),
                      let data = try? Data(contentsOf: rawURL), !data.isEmpty else {
                    DispatchQueue.main.async { completion(nil, nil) }
                    return
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    DispatchQueue.main.async { completion(nil, "Nie udało się odczytać zrzutu.") }
                    return
                }
                let outcome = compressAndDeliver(image)
                DispatchQueue.main.async { completion(outcome.0, outcome.1) }
            }
        }

        do {
            try process.run()
        } catch {
            isCapturing = false
            completion(nil, "Nie udało się uruchomić narzędzia zrzutu ekranu.")
        }
    }

    // MARK: - Kompresja

    private static func compressAndDeliver(_ original: CGImage) -> (Result?, String?) {
        let format = Settings.screenshotFormat
        let budget = Settings.screenshotMaxKB * 1024
        let maxPixels = Settings.screenshotMaxPixels

        var working = original
        if let scaled = downscale(original, longestSide: maxPixels) {
            working = scaled
        }

        var quality = 0.86
        var encoded: Data?
        var attempts = 0

        // Najpierw obnizamy jakosc, a dopiero gdy to nie wystarczy - rozmiar w pikselach.
        // Taka kolejnosc daje ostrzejszy tekst niz od razu zmniejszony obraz.
        while attempts < 12 {
            attempts += 1
            guard let data = encode(working, format: format, quality: quality) else { break }
            encoded = data
            if data.count <= budget { break }
            if quality > 0.35 {
                quality = max(0.32, quality - 0.14)
            } else {
                let longest = max(working.width, working.height)
                let next = Int(Double(longest) * 0.82)
                guard next > 700, let smaller = downscale(working, longestSide: next) else { break }
                working = smaller
                quality = 0.6
            }
        }

        guard let data = encoded else {
            return (nil, "Nie udało się skompresować zrzutu.")
        }

        var savedURL: URL?
        if Settings.screenshotSaveToDisk {
            savedURL = write(data, format: format)
        }
        putOnPasteboard(data: data, format: format, fileURL: savedURL)

        return (
            Result(
                url: savedURL,
                byteCount: data.count,
                pixelSize: NSSize(width: working.width, height: working.height),
                quality: quality
            ),
            nil
        )
    }

    private static func downscale(_ image: CGImage, longestSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longestSide, longestSide > 0 else { return nil }
        let scale = Double(longestSide) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, format: ScreenshotFormat, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let type = UTType(format.uti),
              let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func write(_ data: Data, format: ScreenshotFormat) -> URL? {
        let folder = Settings.screenshotFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'o' HH.mm.ss"
        let name = "Zrzut \(formatter.string(from: Date())).\(format.fileExtension)"
        let url = folder.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Do schowka trafia i plik, i same dane obrazu - dzieki temu jedne aplikacje
    /// wkleja gotowy plik, a inne obrazek, i w obu przypadkach jest to wersja lekka.
    private static func putOnPasteboard(data: Data, format: ScreenshotFormat, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let fileURL {
            pasteboard.writeObjects([fileURL as NSURL])
        }
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(format.uti))
        if format == .heic, let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            // HEIC nie jest rozumiane wszedzie - dokladamy zapasowa reprezentacje.
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    static func describe(_ result: Result) -> String {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(result.byteCount), countStyle: .file)
        let dimensions = "\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))"
        if result.url != nil {
            return "Zrzut w schowku i na dysku · \(sizeText) · \(dimensions)"
        }
        return "Zrzut w schowku · \(sizeText) · \(dimensions)"
    }
}
