import AppKit
import SwiftUI

// MARK: - Historia schowka
//
// macOS nie ma zdarzenia „schowek sie zmienil". Jedyne, co system udostepnia, to
// licznik zmian (`changeCount`) - liczba calkowita, ktora rosnie po kazdej kopii.
// Dlatego TU, jako jedyne miejsce w calym programie, pytamy zegarem: raz na
// pol sekundy porownujemy jedna liczbe. Odczyt kosztuje mikrosekundy i nie budzi
// zadnej aplikacji; dopiero ZMIANA licznika uruchamia realna prace.
//
// Niezmiennik bezpieczenstwa: wpis oznaczony przez program jako poufny (tak robia
// menedzery hasel) NIE jest zapisywany ani na dysk, ani do pamieci. Hasla nie maja
// prawa trafic do historii.

enum RodzajWpisu: String, Codable {
    case tekst
    case obraz
}

struct WpisSchowka: Identifiable, Codable, Equatable {
    let id: UUID
    let czas: Date
    let rodzaj: RodzajWpisu
    /// Dla tekstu - cala tresc. Dla obrazu - opis rozmiaru, zeby bylo co pokazac obok miniatury.
    let tekst: String
    /// Nazwa pliku z obrazem w katalogu historii (tylko dla obrazow).
    let plik: String?
    /// Program, z ktorego pochodzi wpis - najszybszy sposob na odnalezienie sie w liscie.
    let zrodlo: String
    var przypiety: Bool

    /// Skrocony podglad do listy: jedna linia, bez zbednych bialych znakow.
    var podglad: String {
        let scisniety = tekst
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return scisniety.count > 300 ? String(scisniety.prefix(300)) + "…" : scisniety
    }
}

final class HistoriaSchowka: ObservableObject {
    static let shared = HistoriaSchowka()

    @Published private(set) var wpisy: [WpisSchowka] = []

    private let schowek = NSPasteboard.general
    private var ostatniLicznik: Int = -1
    private var zegar: Timer?
    /// Ustawiane na czas WLASNEGO wpisu do schowka - inaczej program zapisywalby
    /// w kolko to, co sam przed chwila wkleil.
    private var wlasnyZapis = false

    private let katalog: URL = {
        let baza = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let cel = baza.appendingPathComponent("pl.klyo.switcher/schowek", isDirectory: true)
        try? FileManager.default.createDirectory(at: cel, withIntermediateDirectories: true)
        return cel
    }()

    private var plikHistorii: URL { katalog.appendingPathComponent("historia.json") }

    private init() {
        wczytaj()
    }

    // MARK: - Start i zatrzymanie

    func start() {
        guard Settings.historiaSchowkaWlaczona else { return }
        guard zegar == nil else { return }
        ostatniLicznik = schowek.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sprawdz()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        zegar = timer
        NotificationCenter.default.addObserver(self, selector: #selector(ustawieniaZmienione),
                                               name: .klyoSettingsChanged, object: nil)
    }

    func stop() {
        zegar?.invalidate()
        zegar = nil
    }

    @objc private func ustawieniaZmienione() {
        if Settings.historiaSchowkaWlaczona {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Odczyt zmiany

    private func sprawdz() {
        let licznik = schowek.changeCount
        guard licznik != ostatniLicznik else { return }
        ostatniLicznik = licznik
        guard !wlasnyZapis else { wlasnyZapis = false; return }

        // Menedzery hasel oznaczaja swoje wpisy tym typem. Takiej tresci nie
        // zapisujemy nigdzie - ani w pamieci, ani na dysku.
        let poufny = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if schowek.data(forType: poufny) != nil { return }
        if schowek.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != nil { return }

        let zrodlo = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nieznany program"

        if let obraz = NSImage(pasteboard: schowek), obraz.size.width > 1, obraz.size.height > 1 {
            zapiszObraz(obraz, zrodlo: zrodlo)
            return
        }
        if let tekst = schowek.string(forType: .string) {
            let czysty = tekst.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !czysty.isEmpty else { return }
            dodaj(WpisSchowka(id: UUID(), czas: Date(), rodzaj: .tekst, tekst: tekst,
                              plik: nil, zrodlo: zrodlo, przypiety: false))
        }
    }

    private func zapiszObraz(_ obraz: NSImage, zrodlo: String) {
        guard let dane = obraz.tiffRepresentation,
              let mapa = NSBitmapImageRep(data: dane),
              let png = mapa.representation(using: .png, properties: [:]) else { return }
        let nazwa = "\(UUID().uuidString).png"
        let cel = katalog.appendingPathComponent(nazwa)
        do {
            try png.write(to: cel, options: .atomic)
        } catch {
            return
        }
        let opis = "Obraz \(mapa.pixelsWide)×\(mapa.pixelsHigh) · \(ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file))"
        dodaj(WpisSchowka(id: UUID(), czas: Date(), rodzaj: .obraz, tekst: opis,
                          plik: nazwa, zrodlo: zrodlo, przypiety: false))
    }

    private func dodaj(_ wpis: WpisSchowka) {
        // Ta sama tresc skopiowana drugi raz nie robi drugiego wpisu - wedruje na gore.
        if wpis.rodzaj == .tekst, let istniejacy = wpisy.firstIndex(where: { $0.rodzaj == .tekst && $0.tekst == wpis.tekst }) {
            let stary = wpisy.remove(at: istniejacy)
            wpisy.insert(
                WpisSchowka(id: stary.id, czas: Date(), rodzaj: stary.rodzaj, tekst: stary.tekst,
                            plik: stary.plik, zrodlo: wpis.zrodlo, przypiety: stary.przypiety),
                at: 0
            )
            zapisz()
            return
        }
        wpisy.insert(wpis, at: 0)
        przytnij()
        zapisz()
    }

    /// Historia nie moze rosnac bez konca. Przypiete wpisy zostaja zawsze -
    /// od tego sa przypiete.
    private func przytnij() {
        let limit = Settings.limitHistoriiSchowka
        guard wpisy.count > limit else { return }
        var zostaje: [WpisSchowka] = []
        var licznik = 0
        for wpis in wpisy {
            if wpis.przypiety {
                zostaje.append(wpis)
                continue
            }
            if licznik < limit {
                zostaje.append(wpis)
                licznik += 1
            } else if let plik = wpis.plik {
                try? FileManager.default.removeItem(at: katalog.appendingPathComponent(plik))
            }
        }
        wpisy = zostaje
    }

    // MARK: - Uzycie wpisu

    /// Wkłada wpis z powrotem do schowka. Zwraca `false`, gdy plik obrazu zniknal.
    @discardableResult
    func wstawDoSchowka(_ wpis: WpisSchowka) -> Bool {
        wlasnyZapis = true
        schowek.clearContents()
        switch wpis.rodzaj {
        case .tekst:
            schowek.setString(wpis.tekst, forType: .string)
            return true
        case .obraz:
            guard let plik = wpis.plik,
                  let obraz = NSImage(contentsOf: katalog.appendingPathComponent(plik)) else {
                wlasnyZapis = false
                return false
            }
            schowek.writeObjects([obraz])
            return true
        }
    }

    func obraz(dla wpis: WpisSchowka) -> NSImage? {
        guard let plik = wpis.plik else { return nil }
        return NSImage(contentsOf: katalog.appendingPathComponent(plik))
    }

    func przypnij(_ wpis: WpisSchowka) {
        guard let index = wpisy.firstIndex(where: { $0.id == wpis.id }) else { return }
        wpisy[index].przypiety.toggle()
        zapisz()
    }

    func usun(_ wpis: WpisSchowka) {
        wpisy.removeAll { $0.id == wpis.id }
        if let plik = wpis.plik {
            try? FileManager.default.removeItem(at: katalog.appendingPathComponent(plik))
        }
        zapisz()
    }

    func wyczysc() {
        for wpis in wpisy where !wpis.przypiety {
            if let plik = wpis.plik {
                try? FileManager.default.removeItem(at: katalog.appendingPathComponent(plik))
            }
        }
        wpisy = wpisy.filter { $0.przypiety }
        zapisz()
    }

    // MARK: - Trwalosc

    private func zapisz() {
        guard let dane = try? JSONEncoder().encode(wpisy) else { return }
        try? dane.write(to: plikHistorii, options: .atomic)
    }

    private func wczytaj() {
        guard let dane = try? Data(contentsOf: plikHistorii),
              let lista = try? JSONDecoder().decode([WpisSchowka].self, from: dane) else { return }
        // Wpisy, ktorych pliki zniknely, odpadaja przy wczytaniu - inaczej lista
        // pokazywalaby obrazki, ktorych juz nie ma.
        wpisy = lista.filter { wpis in
            guard let plik = wpis.plik else { return true }
            return FileManager.default.fileExists(atPath: katalog.appendingPathComponent(plik).path)
        }
    }
}

// MARK: - Wklejanie do aktywnego programu

enum Wklejanie {
    /// Wysyla ⌘V do programu, ktory jest na wierzchu. Uzywane po wybraniu wpisu
    /// z historii: uzytkownik oczekuje, ze tresc od razu wyladuje tam, gdzie pisze.
    static func wyslijSkrotWklejenia() {
        guard let zrodlo = CGEventSource(stateID: .combinedSessionState) else { return }
        let klawiszV: CGKeyCode = 9
        guard let wcisniecie = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawiszV, keyDown: true),
              let zwolnienie = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawiszV, keyDown: false) else { return }
        wcisniecie.flags = .maskCommand
        zwolnienie.flags = .maskCommand
        wcisniecie.post(tap: .cghidEventTap)
        zwolnienie.post(tap: .cghidEventTap)
    }
}
