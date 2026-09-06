import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Ikona programu rysowana kodem — bez plików graficznych i bez zewnętrznych narzędzi.
//
// Co ma mówić: „wyciągam jedno okno z gąszczu innych". Dlatego znakiem są trzy
// okna ustawione w głąb, z których przednie jest podświetlone. To jedyna rzecz,
// jaką ten program robi, więc ikona nie potrzebuje niczego więcej.
//
// Barwy są barwami klyo — grafit `#0c0e14` i czerwień `#ee3f2c`. Ikona ma
// wyglądać jak część tej marki, a nie jak losowy obrazek: kolor jest tym, po
// czym człowiek rozpoznaje ikonę w Docku, zanim zdąży odczytać kształt.
//
// Reguły, których trzymamy się świadomie:
//   • kształt „squircle" i margines ~5,5 % — takie proporcje mają ikony systemowe,
//     a ikona odstająca kształtem wygląda w Docku jak obca wtręta;
//   • znak czytelny w 16 px (pasek menu): trzy prostokąty i jeden akcent, zero
//     drobnicy, która w tym rozmiarze zlewa się w plamę;
//   • światło z góry i cień pod przednim oknem — bez nich ikona jest płaska
//     i wygląda na niedokończoną;
//   • czerwony akcent TYLKO na przednim oknie: to on niesie znaczenie „to jest
//     wybrane". Rozlany po całości przestałby cokolwiek znaczyć.

let ROZMIARY: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

/// Barwy marki klyo — te same, których używa strona.
enum Barwy {
    static let tloGora = CGColor(red: 0.086, green: 0.098, blue: 0.129, alpha: 1)   // #16191f
    static let tloDol  = CGColor(red: 0.031, green: 0.035, blue: 0.051, alpha: 1)   // #08090d
    static let akcent  = CGColor(red: 0.933, green: 0.247, blue: 0.173, alpha: 1)   // #ee3f2c
    static let akcentJasny = CGColor(red: 1.0, green: 0.373, blue: 0.298, alpha: 1) // #ff5f4c
    static let jasne   = CGColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1)   // #f7f8fa
}

func squircle(_ prostokat: CGRect, promien: CGFloat) -> CGPath {
    CGPath(roundedRect: prostokat, cornerWidth: promien, cornerHeight: promien, transform: nil)
}

func rysuj(_ bok: Int) -> CGImage? {
    let s = CGFloat(bok)
    guard let kontekst = CGContext(
        data: nil, width: bok, height: bok, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    kontekst.setAllowsAntialiasing(true)
    kontekst.interpolationQuality = .high

    let margines = s * 0.055
    let plyta = CGRect(x: margines, y: margines, width: s - margines * 2, height: s - margines * 2)
    let ksztalt = squircle(plyta, promien: plyta.width * 0.2237)

    // --- Płyta: pionowe przejście barwy, jaśniejsze u góry ---
    kontekst.saveGState()
    kontekst.addPath(ksztalt)
    kontekst.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [Barwy.tloGora, Barwy.tloDol] as CFArray,
                                 locations: [0, 1]) {
        kontekst.drawLinearGradient(gradient,
                                    start: CGPoint(x: 0, y: plyta.maxY),
                                    end: CGPoint(x: 0, y: plyta.minY),
                                    options: [])
    }

    // Delikatna poświata u góry — tak wygląda światło na ikonach systemowych.
    if let blask = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        kontekst.drawRadialGradient(
            blask,
            startCenter: CGPoint(x: plyta.midX, y: plyta.maxY), startRadius: 0,
            endCenter: CGPoint(x: plyta.midX, y: plyta.maxY), endRadius: plyta.width * 0.8,
            options: [])
    }
    kontekst.restoreGState()

    // --- Znak: trzy okna w głąb ---
    // Rozmiary liczone z boku ikony, żeby w 16 px i w 1024 px wyglądały tak samo.
    let szerokoscOkna = plyta.width * 0.52
    let wysokoscOkna = szerokoscOkna * 0.70
    let odsun = plyta.width * 0.085
    let promienOkna = max(s * 0.012, szerokoscOkna * 0.085)
    let srodek = CGPoint(x: plyta.midX, y: plyta.midY)

    /// Jedno okno. `glebia` 0 = przednie (podświetlone), większa = dalsze.
    func okno(glebia: CGFloat, jasnosc: CGFloat, przednie: Bool) {
        let przesuniecie = odsun * glebia
        let ramka = CGRect(
            x: srodek.x - szerokoscOkna / 2 + przesuniecie,
            y: srodek.y - wysokoscOkna / 2 - przesuniecie,
            width: szerokoscOkna, height: wysokoscOkna
        ).offsetBy(dx: -odsun * 0.5, dy: odsun * 0.5)
        let sciezka = squircle(ramka, promien: promienOkna)

        kontekst.saveGState()
        if przednie {
            // Cień oddziela przednie okno od tylnych — bez niego wszystkie trzy
            // zlewają się w jeden prostokąt, zwłaszcza w małym rozmiarze.
            kontekst.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                               blur: s * 0.035,
                               color: CGColor(gray: 0, alpha: 0.55))
        }
        kontekst.addPath(sciezka)
        kontekst.setFillColor(CGColor(red: 0.969, green: 0.973, blue: 0.980, alpha: jasnosc))
        kontekst.fillPath()
        kontekst.restoreGState()

        guard przednie else { return }

        // Pasek tytułu w barwie marki — to on mówi „to okno jest wybrane".
        let paskaWysokosc = max(s * 0.02, wysokoscOkna * 0.235)
        let pasek = CGRect(x: ramka.minX, y: ramka.maxY - paskaWysokosc,
                           width: ramka.width, height: paskaWysokosc)
        kontekst.saveGState()
        kontekst.addPath(sciezka)
        kontekst.clip()
        if let gradientPaska = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          colors: [Barwy.akcentJasny, Barwy.akcent] as CFArray,
                                          locations: [0, 1]) {
            kontekst.drawLinearGradient(gradientPaska,
                                        start: CGPoint(x: pasek.minX, y: pasek.maxY),
                                        end: CGPoint(x: pasek.maxX, y: pasek.minY),
                                        options: [])
        }
        kontekst.restoreGState()

        // Trzy kropki okna — tylko tam, gdzie w ogóle będą widoczne.
        // Poniżej 128 px zlewają się w plamę i psują czytelność znaku.
        guard bok >= 128 else { return }
        let promienKropki = paskaWysokosc * 0.17
        let odstep = promienKropki * 3.1
        var x = pasek.minX + odstep
        for _ in 0..<3 {
            kontekst.setFillColor(CGColor(gray: 1, alpha: 0.85))
            kontekst.fillEllipse(in: CGRect(x: x - promienKropki,
                                            y: pasek.midY - promienKropki,
                                            width: promienKropki * 2, height: promienKropki * 2))
            x += odstep
        }
    }

    okno(glebia: 2, jasnosc: 0.22, przednie: false)
    okno(glebia: 1, jasnosc: 0.42, przednie: false)
    okno(glebia: 0, jasnosc: 1.0, przednie: true)

    // --- Obrys płyty: cienka jasna krawędź, jak na ikonach systemowych ---
    kontekst.saveGState()
    kontekst.addPath(ksztalt)
    kontekst.setStrokeColor(CGColor(gray: 1, alpha: 0.11))
    kontekst.setLineWidth(max(1, s * 0.004))
    kontekst.strokePath()
    kontekst.restoreGState()

    return kontekst.makeImage()
}

let argumenty = CommandLine.arguments
guard argumenty.count > 1 else {
    FileHandle.standardError.write("Podaj katalog wyjsciowy\n".data(using: .utf8)!)
    exit(1)
}
let katalog = URL(fileURLWithPath: argumenty[1])
try? FileManager.default.createDirectory(at: katalog, withIntermediateDirectories: true)

for (bok, nazwa) in ROZMIARY {
    guard let obraz = rysuj(bok) else { continue }
    let plik = katalog.appendingPathComponent("\(nazwa).png")
    guard let cel = CGImageDestinationCreateWithURL(plik as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(cel, obraz, nil)
    CGImageDestinationFinalize(cel)
}
print("ikona narysowana: \(ROZMIARY.count) rozmiarow")
