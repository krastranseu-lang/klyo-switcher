import AppKit
import SwiftUI

// MARK: - Mikser dzwieku
//
// Jedno okno na pytanie „co teraz gra i jak to uciszyc". Otwiera je skrot
// (domyslnie ⌥⌘S) albo pozycja w menu paska.
//
// Co tu JEST, bo dziala:
//   • lista programow, ktore naprawde graja - czytana z CoreAudio, nie zgadywana,
//   • wyciszenie kazdego z osobna (macOS 14.2+) i przywrocenie,
//   • glosnosc calego systemu.
//
// Czego tu NIE MA i dlaczego: suwaka glosnosci OSOBNO dla programu ani pasm
// ekwalizera. Zeby przyciszyc jeden program do 40 procent, trzeba przejac jego
// dzwiek, przemnozyc probki i wypuscic je z powrotem przez wlasne urzadzenie -
// to silnik, nie suwak. Suwak bez tego silnika wygladalby jak dzialajacy i nie
// robilby nic, a to gorsze niz jego brak.

final class ModelMiksera: ObservableObject {
    struct Pozycja: Identifiable {
        let id: pid_t
        let nazwa: String
        let ikona: NSImage?
        let gra: Bool
        let wyciszony: Bool
        /// 1.0 = bez zmiany. Suwak pokazuje to jako 100%.
        let poziom: Float
    }

    @Published private(set) var pozycje: [Pozycja] = []
    /// Grajace karty przegladarek, po programie. To odpowiedz na „pokaz KAZDA
    /// grajaca zakladke" - CoreAudio widzi tylko caly Chrome, karty widac przez
    /// Dostepnosc (patrz `KartyDzwieku`).
    @Published private(set) var karty: [pid_t: [KartaGrajaca]] = [:]
    @Published var glosnoscSystemu: Double = 0.5 {
        didSet {
            guard !wczytywanie else { return }
            GlosnoscAplikacji.glosnoscSystemu = Float(glosnoscSystemu)
        }
    }
    /// `false`, gdy urzadzenie wyjscia nie oddaje glosnosci - tak bywa przy HDMI
    /// albo zewnetrznym wzmacniaczu. Wtedy suwak jest wylaczony, a nie udaje.
    @Published private(set) var glosnoscDostepna = true
    private var wczytywanie = false
    private var zegar: Timer?

    func zacznij() {
        odswiez()
        zegar = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.odswiez()
        }
    }

    func przestan() {
        zegar?.invalidate()
        zegar = nil
    }

    func odswiez() {
        Dzwiek.odswiez()
        GlosnoscAplikacji.posprzatajPoZamknietych()
        let grajace = Dzwiek.grajace()
        let wyciszone = GlosnoscAplikacji.wyciszone
        // Program przyciszony ma zostac na liscie takze wtedy, gdy chwilowo milczy -
        // inaczej znikalby razem z suwakiem, ktory czlowiek wlasnie ustawil.
        let zmienione = GlosnoscAplikacji.zmienione

        // Pokazujemy tylko programy WIDOCZNE dla czlowieka. Dzwiek zglasza procesy
        // pomocnicze (np. Chrome Helper), ale nikt nie szuka na liscie pomocnika -
        // szuka Chrome'a.
        var wynik: [Pozycja] = []
        for program in NSWorkspace.shared.runningApplications
        where program.activationPolicy == .regular {
            let pid = program.processIdentifier
            let gra = grajace.contains(pid)
            let wyciszony = wyciszone.contains(pid)
            let zmieniony = zmienione.contains(pid)
            guard gra || wyciszony || zmieniony else { continue }
            wynik.append(Pozycja(id: pid,
                                 nazwa: program.localizedName ?? "pid \(pid)",
                                 ikona: program.icon,
                                 gra: gra,
                                 wyciszony: wyciszony,
                                 poziom: GlosnoscAplikacji.poziom(pid: pid)))
        }
        pozycje = wynik.sorted { $0.nazwa.localizedCaseInsensitiveCompare($1.nazwa) == .orderedAscending }

        // Karty pytamy tylko o te przegladarki, ktore naprawde graja - i robimy to
        // POZA glownym watkiem. Zmierzone: przejscie po drzewie Dostepnosci 36 kart
        // trwa okolo 0,2 s, a okno odswieza sie co sekunde - na glownym watku
        // byloby to widac jako zacinanie suwaka.
        let grajaceTeraz = grajace
        DispatchQueue.global(qos: .userInitiated).async {
            var noweKarty: [pid_t: [KartaGrajaca]] = [:]
            for karta in KartyDzwieku.grajace(wsrodGrajacych: grajaceTeraz) {
                noweKarty[karta.pid, default: []].append(karta)
            }
            DispatchQueue.main.async { [weak self] in self?.karty = noweKarty }
        }

        wczytywanie = true
        if let poziom = GlosnoscAplikacji.glosnoscSystemu {
            glosnoscSystemu = Double(poziom)
            glosnoscDostepna = true
        } else {
            glosnoscDostepna = false
        }
        wczytywanie = false
    }

    /// Wycisza pojedyncza karte - i od razu pyta o stan, bo przegladarka
    /// przerysowuje swoj pasek dopiero po chwili.
    func przelaczKarte(_ karta: KartaGrajaca) {
        let bylaWyciszona = karta.wyciszona
        // Zapamietujemy WYNIK po swojej stronie, bo przegladarka go nie odda:
        // Chrome oznacza tylko karty grajace, wiec zaraz po wyciszeniu karta
        // przestaje byc rozpoznawalna. To jest cala usterka „nie wraca".
        if KartyDzwieku.przelaczWyciszenie(karta) {
            if bylaWyciszona {
                GlosnoscKarty.zapomnij(karta)
            } else {
                GlosnoscKarty.zapamietajWyciszenie(karta)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.odswiez() }
    }

    func pokazKarte(_ karta: KartaGrajaca) {
        KartyDzwieku.pokaz(karta)
    }

    func przelacz(_ pid: pid_t) {
        GlosnoscAplikacji.przelaczWyciszenie(pid: pid)
        odswiez()
    }

    /// Suwak przy programie. Ustawiamy od razu - dzwiek ma isc za palcem, a nie
    /// za puszczeniem myszy.
    func ustawPoziom(_ pid: pid_t, _ nowy: Float) {
        let osiagniety = GlosnoscAplikacji.ustawPoziom(pid: pid, nowy)
        // Gdy toru nie da sie zbudowac, poziom wraca do 100% - i suwak ma to
        // pokazac, zamiast stac w miejscu, w ktorym nic sie nie stalo.
        if abs(osiagniety - nowy) > 0.01 { odswiez() } else { odswiezCicho(pid: pid, poziom: osiagniety) }
    }

    /// Zmiana samego poziomu bez pytania systemu o cala liste - suwak ciagniety
    /// mysza wywolywalby inaczej kilkadziesiat odczytow CoreAudio na sekunde.
    private func odswiezCicho(pid: pid_t, poziom: Float) {
        guard let miejsce = pozycje.firstIndex(where: { $0.id == pid }) else { return }
        let stara = pozycje[miejsce]
        pozycje[miejsce] = Pozycja(id: stara.id, nazwa: stara.nazwa, ikona: stara.ikona,
                                   gra: stara.gra, wyciszony: poziom <= 0.0001, poziom: poziom)
    }

    // MARK: Karty

    /// Poziom karty w skali 0…1 (100% = strona gra tak, jak ustawila sama).
    func poziomKarty(_ karta: KartaGrajaca) -> Float {
        obiecanePoziomy[GlosnoscKarty.klucz(karta)] ?? GlosnoscKarty.poziom(karta)
    }

    /// Ostatni powod, dla ktorego suwak karty nie zadzialal - pokazywany przy
    /// tej karcie, zeby czlowiek wiedzial, czego brakuje, zamiast szarpac suwak.
    @Published private(set) var powodyKart: [String: String] = [:]

    /// Ostatnia zadana wartosc suwaka karty - suwak ciagniety mysza wysyla
    /// dziesiatki zmian na sekunde, a kazda z nich to rozmowa z przegladarka.
    private var zadanePoziomyKart: [String: Float] = [:]
    private var wysylkaTrwa: Set<String> = []

    func ustawPoziomKarty(_ karta: KartaGrajaca, _ nowy: Float) {
        let klucz = GlosnoscKarty.klucz(karta)
        zadanePoziomyKart[klucz] = nowy
        // Suwak ma isc od razu, choc dzwiek dojdzie za chwile - inaczej wygladalby
        // na zaciety.
        obiecanePoziomy[klucz] = nowy
        guard !wysylkaTrwa.contains(klucz) else { return }
        wysylkaTrwa.insert(klucz)
        wyslijPoziomKarty(karta, klucz: klucz)
    }

    /// Poziom pokazywany w oknie, zanim przegladarka potwierdzi.
    @Published private(set) var obiecanePoziomy: [String: Float] = [:]

    private func wyslijPoziomKarty(_ karta: KartaGrajaca, klucz: String) {
        guard let wartosc = zadanePoziomyKart.removeValue(forKey: klucz) else {
            wysylkaTrwa.remove(klucz)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let wynik = GlosnoscKarty.ustaw(karta, poziom: wartosc)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let powod = wynik.powod {
                    self.powodyKart[klucz] = powod
                } else {
                    self.powodyKart.removeValue(forKey: klucz)
                }
                // W czasie rozmowy z przegladarka czlowiek mogl ruszyc suwak dalej.
                if self.zadanePoziomyKart[klucz] != nil {
                    self.wyslijPoziomKarty(karta, klucz: klucz)
                } else {
                    self.wysylkaTrwa.remove(klucz)
                    self.odswiez()
                }
            }
        }
    }

    func powodKarty(_ karta: KartaGrajaca) -> String? { powodyKart[GlosnoscKarty.klucz(karta)] }
}
