import AppKit
import SwiftUI

// MARK: - Zrzut wlasnego okna do pliku (tryb podgladu)
//
// Po co: wyglad przelacznika widac przez ulamek sekundy i tylko wtedy, gdy ktos
// trzyma ⌘. Nie da sie go ani sfotografowac z zewnatrz (zrzut ekranu wymaga zgody
// „Nagrywanie ekranu", ktorej narzedzia do pracy nie maja), ani obejrzec spokojnie.
// Kazda zmiana wygladu byla wiec robiona na slepo i sprawdzana cudzymi oczami.
//
// `--podglad-hud <plik.png>` sklada tę samą listę okien co przy prawdziwym ⌘⇥,
// rysuje ją do pliku i konczy program. Zadnych zmyslonych danych: okna sa
// prawdziwe, uklad jest prawdziwy, rozmiar jest ten sam co na ekranie.
//
// Ograniczenie, ktore trzeba znac: rozmyte tlo (`NSVisualEffectView`) rysuje
// serwer okien przy skladaniu ekranu, wiec w pliku go NIE MA. Zeby obraz nie byl
// przezroczysty, pod widok podkladamy plaskie tlo w kolorze zblizonym do materialu.
// Wszystko inne - odstepy, czcionki, obramowania, kolory - jest wierne.

enum PodgladHUD {
    /// Rozpoznanie argumentu. Zwraca sciezke pliku albo `nil`, gdy program ma
    /// wystartowac normalnie.
    static func zadanaSciezka() -> String? {
        let argumenty = CommandLine.arguments
        guard let miejsce = argumenty.firstIndex(of: "--podglad-hud") else { return nil }
        let nastepny = argumenty.index(after: miejsce)
        guard nastepny < argumenty.endIndex else { return "podglad-hud.png" }
        return argumenty[nastepny]
    }

    /// Buduje liste okien, rysuje panel i zapisuje PNG. Konczy proces sama -
    /// tryb podgladu nie ma po co zostawac w pamieci.
    static func wykonaj(sciezka: String, ciemny: Bool) -> Never {
        let model = SwitcherModel()
        let spis = WindowEnumerator()
        let przegladarki = BrowserTabIndex()
        let uzycie = WindowUsageTracker()
        var okna = spis.snapshot(browsers: przegladarki, usage: uzycie)

        let ekran = NSScreen.main ?? NSScreen.screens[0]
        let kolumny = HUDLayout.columns(for: max(1, okna.count), screenWidth: ekran.frame.width)
        let pojemnosc = kolumny * HUDLayout.maxRows(screenHeight: ekran.visibleFrame.height)
        if okna.count > pojemnosc { okna = Array(okna.prefix(pojemnosc)) }

        guard !okna.isEmpty else {
            FileHandle.standardError.write(Data("Nie ma zadnego okna do pokazania.\n".utf8))
            exit(2)
        }
        model.ustawWszystkie(okna)
        model.columns = kolumny
        // Miniatury robimy tu tak samo jak przy prawdziwym ⌘⇥ - inaczej podglad
        // pokazywalby wylacznie ikony i mowilby o wygladzie nieprawde w miejscu,
        // ktore zajmuje polowe kazdej karty.
        if Settings.showThumbnails, Permissions.screenRecordingGranted {
            var gotowe: [(id: String, image: NSImage)] = []
            for pozycja in okna where pozycja.windowID != 0 {
                if let obraz = WindowThumbnails.capture(windowID: pozycja.windowID, maxWidth: 560) {
                    gotowe.append((id: pozycja.id, image: obraz))
                }
            }
            model.setThumbnails(gotowe)
        }
        // Druga pozycja - dokladnie to, co widac po jednym ⌘⇥, czyli najczestszy widok.
        model.selection = min(1, okna.count - 1)

        let rozmiar = HUDLayout.panelSize(count: okna.count, columns: kolumny)
        let okno = NSWindow(
            contentRect: NSRect(origin: .zero, size: rozmiar),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        okno.appearance = NSAppearance(named: ciemny ? .darkAqua : .aqua)
        okno.isOpaque = true
        okno.backgroundColor = ciemny
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.93, alpha: 1)
        // Poza widocznym obszarem: podglad nie ma migac uzytkownikowi przed oczami.
        okno.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

        let widok = NSHostingView(rootView: SwitcherView(model: model))
        widok.frame = NSRect(origin: .zero, size: rozmiar)
        okno.contentView = widok
        okno.orderFrontRegardless()

        // Jeden obrot petli zdarzen - bez niego SwiftUI nie zdazy ulozyc widoku
        // i w pliku zostaje pusty prostokat.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        widok.layoutSubtreeIfNeeded()

        guard let bufor = widok.bitmapImageRepForCachingDisplay(in: widok.bounds) else {
            FileHandle.standardError.write(Data("Nie udalo sie utworzyc bufora obrazu.\n".utf8))
            exit(3)
        }
        widok.cacheDisplay(in: widok.bounds, to: bufor)
        guard let png = bufor.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Nie udalo sie zakodowac PNG.\n".utf8))
            exit(4)
        }
        do {
            try png.write(to: URL(fileURLWithPath: sciezka))
            print("zapisane: \(sciezka)  \(Int(rozmiar.width))x\(Int(rozmiar.height)) px, okien: \(okna.count), kolumn: \(kolumny)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Zapis nie wyszedl: \(error)\n".utf8))
            exit(5)
        }
    }
}
