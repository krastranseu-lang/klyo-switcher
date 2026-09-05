import AppKit
import CoreGraphics

// Ikona programu rysowana kodem — bez plikow graficznych i bez zewnetrznych
// narzedzi. Ksztalt trzyma sie tego, czego macOS oczekuje od ikon: zaokraglony
// kwadrat („squircle"), lagodne swiatlo z gory, wyrazny znak w srodku, ktory
// czytelny jest takze w rozmiarze 32 px w Docku.
//
// Znak: trzy okna ustawione w glab, przednie podswietlone — to jest dokladnie to,
// co program robi: wyciaga jedno okno z gaszczu innych.

let ROZMIARY: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func sciezkaSquircle(_ prostokat: CGRect, promien: CGFloat) -> CGPath {
    // Krzywa zblizona do ksztaltu ikon Apple: rog lagodniejszy niz zwykle
    // zaokraglenie, bez widocznego zalamania w miejscu styku z bokiem.
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

    // Tlo: zaokraglony kwadrat z pionowym przejsciem barwy. Granat trzyma sie
    // dobrze i na jasnym, i na ciemnym pulpicie.
    let margines = s * 0.055
    let plyta = CGRect(x: margines, y: margines, width: s - margines * 2, height: s - margines * 2)
    let ksztalt = sciezkaSquircle(plyta, promien: plyta.width * 0.235)

    kontekst.saveGState()
    kontekst.addPath(ksztalt)
    kontekst.clip()
    let przestrzen = CGColorSpace(name: CGColorSpace.sRGB)!
    let gora = CGColor(colorSpace: przestrzen, components: [0.129, 0.184, 0.322, 1.0])!
    let dol = CGColor(colorSpace: przestrzen, components: [0.055, 0.078, 0.157, 1.0])!
    if let przejscie = CGGradient(colorsSpace: przestrzen, colors: [gora, dol] as CFArray, locations: [0, 1]) {
        kontekst.drawLinearGradient(przejscie,
                                    start: CGPoint(x: 0, y: plyta.maxY),
                                    end: CGPoint(x: 0, y: plyta.minY),
                                    options: [])
    }
    // Swiatlo z gory — bez niego plyta wyglada jak plaski prostokat.
    if let blask = CGGradient(colorsSpace: przestrzen,
                              colors: [CGColor(colorSpace: przestrzen, components: [1, 1, 1, 0.16])!,
                                       CGColor(colorSpace: przestrzen, components: [1, 1, 1, 0])!] as CFArray,
                              locations: [0, 1]) {
        kontekst.drawRadialGradient(blask,
                                    startCenter: CGPoint(x: plyta.midX, y: plyta.maxY),
                                    startRadius: 0,
                                    endCenter: CGPoint(x: plyta.midX, y: plyta.maxY),
                                    endRadius: plyta.width * 0.85,
                                    options: [])
    }
    kontekst.restoreGState()

    // Delikatna krawedz, zeby ikona nie zlewala sie z ciemnym tlem Docka.
    kontekst.saveGState()
    kontekst.addPath(ksztalt)
    kontekst.setStrokeColor(CGColor(colorSpace: przestrzen, components: [1, 1, 1, 0.14])!)
    kontekst.setLineWidth(max(1, s * 0.006))
    kontekst.strokePath()
    kontekst.restoreGState()

    // Trzy okna w glab. Przednie jest jasne i pelne — to ono jest wybrane.
    let szer = plyta.width * 0.50
    let wys = szer * 0.66
    let srodekX = plyta.midX
    let srodekY = plyta.midY
    let odsun = plyta.width * 0.085

    func okno(_ przesuniecie: CGFloat, jasnosc: CGFloat, pelne: Bool) {
        let r = CGRect(x: srodekX - szer / 2 + przesuniecie,
                       y: srodekY - wys / 2 - przesuniecie * 0.72,
                       width: szer, height: wys)
        let sc = CGPath(roundedRect: r, cornerWidth: r.width * 0.11, cornerHeight: r.width * 0.11, transform: nil)
        kontekst.saveGState()
        if pelne {
            kontekst.addPath(sc)
            kontekst.setFillColor(CGColor(colorSpace: przestrzen, components: [1, 1, 1, jasnosc])!)
            kontekst.fillPath()
            // Pasek tytulu jako przerwa w wypelnieniu — czytelny nawet przy 32 px.
            let pasek = CGRect(x: r.minX + r.width * 0.10, y: r.maxY - r.height * 0.30,
                               width: r.width * 0.80, height: r.height * 0.115)
            kontekst.addPath(CGPath(roundedRect: pasek, cornerWidth: pasek.height / 2, cornerHeight: pasek.height / 2, transform: nil))
            kontekst.setBlendMode(.clear)
            kontekst.fillPath()
            kontekst.setBlendMode(.normal)
        } else {
            kontekst.addPath(sc)
            kontekst.setStrokeColor(CGColor(colorSpace: przestrzen, components: [1, 1, 1, jasnosc])!)
            kontekst.setLineWidth(max(1, s * 0.018))
            kontekst.strokePath()
        }
        kontekst.restoreGState()
    }

    okno(odsun * 2, jasnosc: 0.30, pelne: false)
    okno(odsun, jasnosc: 0.52, pelne: false)
    okno(0, jasnosc: 0.97, pelne: true)

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
    guard let cel = CGImageDestinationCreateWithURL(plik as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(cel, obraz, nil)
    CGImageDestinationFinalize(cel)
}
print("ikona narysowana: \(ROZMIARY.count) rozmiarow")
