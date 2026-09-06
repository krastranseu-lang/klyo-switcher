import AppKit

// MARK: - Szybkie akcje: jedno pole, w ktorym znajdziesz wszystko
//
// Zasada, ktora rozstrzyga wszystkie przypadki: **jesli to juz jest otwarte,
// przelaczamy na to; jesli nie ma - dopiero wtedy otwieramy**. Dotyczy tak samo
// programu, okna i karty przegladarki. Bez tej zasady kazde wywolanie robilo
// nowe okno i po dniu pracy czlowiek mial pietnascie pustych Chrome'ow.
//
// Kolejnosc wynikow nie jest przypadkowa: najpierw to, co juz zyje (okna, karty),
// potem programy z dysku, na koncu polecenia samego programu. Czlowiek szukajacy
// „whatsapp" chce najczesciej WROCIC do rozmowy, a nie uruchomic druga kopie.

struct AkcjaSzybka: Identifiable {
    enum Rodzaj {
        /// Okno, ktore juz istnieje - przelaczamy sie na nie.
        case okno(SwitcherItem)
        /// Karta przegladarki, ktora juz istnieje.
        case karta(BrowserTab)
        /// Program z dysku. `dziala` znaczy, ze wystarczy go wystawic zamiast uruchamiac.
        case program(url: URL, bundleID: String, dziala: Bool)
        /// Polecenie samego przelacznika.
        case polecenie(() -> Void)
    }

    let id: String
    let tytul: String
    let podtytul: String
    let ikona: NSImage?
    let rodzaj: Rodzaj
    /// Nizsza waga = wyzej na liscie.
    let waga: Int

    var etykietaRodzaju: String {
        switch rodzaj {
        case .okno: return "Okno"
        case .karta: return "Karta"
        case .program(_, _, let dziala): return dziala ? "Program (działa)" : "Program"
        case .polecenie: return "Polecenie"
        }
    }
}

enum ZrodloAkcji {
    // MARK: Programy na dysku

    private static var programyPamiec: [(nazwa: String, url: URL, bundleID: String)] = []
    private static var programyCzas: Date = .distantPast

    /// Spis programow z katalogow, w ktorych macOS trzyma aplikacje.
    ///
    /// Odswiezany najwyzej raz na minute: czytanie katalogow przy kazdej literze
    /// byloby praca bez powodu, a programow nie przybywa co sekunde.
    static func programy() -> [(nazwa: String, url: URL, bundleID: String)] {
        if Date().timeIntervalSince(programyCzas) < 60, !programyPamiec.isEmpty {
            return programyPamiec
        }
        let menedzer = FileManager.default
        var katalogi = [URL(fileURLWithPath: "/Applications"),
                        URL(fileURLWithPath: "/System/Applications")]
        if let wlasne = menedzer.urls(for: .applicationDirectory, in: .userDomainMask).first {
            katalogi.append(wlasne)
        }
        var wynik: [(String, URL, String)] = []
        var widziane = Set<String>()
        for katalog in katalogi {
            let zawartosc = (try? menedzer.contentsOfDirectory(at: katalog,
                                                               includingPropertiesForKeys: nil)) ?? []
            for pozycja in zawartosc {
                // Jeden poziom w glab - tak macOS grupuje np. narzedzia systemowe.
                let dzieci = pozycja.pathExtension == "app"
                    ? [pozycja]
                    : ((try? menedzer.contentsOfDirectory(at: pozycja, includingPropertiesForKeys: nil)) ?? [])
                for program in dzieci where program.pathExtension == "app" {
                    guard let paczka = Bundle(url: program),
                          let identyfikator = paczka.bundleIdentifier,
                          widziane.insert(identyfikator).inserted else { continue }
                    let nazwa = menedzer.displayName(atPath: program.path)
                    wynik.append((nazwa, program, identyfikator))
                }
            }
        }
        programyPamiec = wynik.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        programyCzas = Date()
        return programyPamiec
    }

    // MARK: Zbieranie wynikow

    /// Wszystkie akcje pasujace do frazy, w kolejnosci przydatnosci.
    static func znajdz(fraza: String, okna: [SwitcherItem], karty: [BrowserTab],
                       polecenia: [AkcjaSzybka]) -> [AkcjaSzybka] {
        let szukane = SwitcherModel.uprosc(fraza.trimmingCharacters(in: .whitespaces))
        var wynik: [AkcjaSzybka] = []

        for okno in okna {
            let tekst = SwitcherModel.uprosc(okno.title + " " + okno.subtitle)
            guard szukane.isEmpty || tekst.contains(szukane) else { continue }
            let gra = Dzwiek.tytulMowiOGraniu(okno.title) || Dzwiek.gra(pid: okno.pid)
            wynik.append(AkcjaSzybka(id: "okno:\(okno.id)", tytul: okno.title,
                                     podtytul: gra ? "🔊 \(okno.subtitle)" : okno.subtitle,
                                     ikona: okno.icon,
                                     rodzaj: .okno(okno), waga: gra ? -1 : 0))
        }

        for karta in karty {
            let tekst = SwitcherModel.uprosc(karta.title + " " + karta.url)
            guard szukane.isEmpty || tekst.contains(szukane) else { continue }
            let ikona = NSRunningApplication.runningApplications(withBundleIdentifier: karta.bundleID).first?.icon
            wynik.append(AkcjaSzybka(id: "karta:\(karta.key)",
                                     tytul: karta.title.isEmpty ? karta.url : karta.title,
                                     podtytul: BrowserSupport.host(of: karta.url),
                                     ikona: ikona, rodzaj: .karta(karta), waga: 1))
        }

        // Programy pokazujemy dopiero, gdy czlowiek cos wpisal - inaczej lista
        // zaczynalaby sie od dwustu ikon, przez ktore trzeba sie przekopac.
        if !szukane.isEmpty {
            let dzialajace = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for program in programy() {
                guard SwitcherModel.uprosc(program.nazwa).contains(szukane) else { continue }
                let dziala = dzialajace.contains(program.bundleID)
                // Program, ktory dziala i ma juz okno na liscie, nie musi byc drugi raz.
                if dziala, okna.contains(where: { $0.bundleID == program.bundleID }) { continue }
                wynik.append(AkcjaSzybka(id: "program:\(program.bundleID)", tytul: program.nazwa,
                                         podtytul: dziala ? "Przełącz" : "Otwórz",
                                         ikona: NSWorkspace.shared.icon(forFile: program.url.path),
                                         rodzaj: .program(url: program.url, bundleID: program.bundleID,
                                                          dziala: dziala),
                                         waga: dziala ? 2 : 3))
            }
        }

        // Wyciszenie jako osobna akcja: gdy cos gra (albo zostalo wyciszone),
        // czlowiek chce to zwykle uciszyc, a nie tylko sie tam przelaczyc.
        for okno in okna {
            let wyciszony = GlosnoscAplikacji.czyWyciszony(pid: okno.pid)
            guard wyciszony || Dzwiek.gra(pid: okno.pid) || Dzwiek.tytulMowiOGraniu(okno.title) else { continue }
            let tekst = SwitcherModel.uprosc("wycisz " + okno.subtitle + " " + okno.title)
            guard szukane.isEmpty || tekst.contains(szukane) else { continue }
            let pid = okno.pid
            wynik.append(AkcjaSzybka(
                id: "wycisz:\(pid)",
                tytul: wyciszony ? "Przywróć dźwięk — \(okno.subtitle)" : "Wycisz — \(okno.subtitle)",
                podtytul: wyciszony ? "Ten program jest wyciszony" : "Wycisza tylko ten program",
                ikona: okno.icon,
                rodzaj: .polecenie { GlosnoscAplikacji.przelaczWyciszenie(pid: pid) },
                waga: -2
            ))
        }

        for polecenie in polecenia {
            let tekst = SwitcherModel.uprosc(polecenie.tytul + " " + polecenie.podtytul)
            guard szukane.isEmpty || tekst.contains(szukane) else { continue }
            wynik.append(polecenie)
        }

        // Trafienie od poczatku nazwy jest zwykle tym, o co chodzilo - stad premia.
        return wynik.sorted { lewy, prawy in
            let odPoczatkuL = SwitcherModel.uprosc(lewy.tytul).hasPrefix(szukane) ? 0 : 1
            let odPoczatkuP = SwitcherModel.uprosc(prawy.tytul).hasPrefix(szukane) ? 0 : 1
            if lewy.waga != prawy.waga { return lewy.waga < prawy.waga }
            if odPoczatkuL != odPoczatkuP { return odPoczatkuL < odPoczatkuP }
            return lewy.tytul.localizedCaseInsensitiveCompare(prawy.tytul) == .orderedAscending
        }
    }

    // MARK: Wykonanie

    static func wykonaj(_ akcja: AkcjaSzybka, przegladarki: BrowserTabIndex) {
        switch akcja.rodzaj {
        case .okno(let okno):
            WindowActivator.activate(okno, browsers: przegladarki)
        case .karta(let karta):
            przegladarki.focus(karta)
        case .program(let url, let bundleID, let dziala):
            // Dziala = wystawiamy, a NIE uruchamiamy drugiej kopii. To jest cala
            // roznica miedzy „wroc do WhatsAppa" a „otworz drugi pusty WhatsApp".
            if dziala, let program = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first {
                WindowActivator.activateApp(pid: program.processIdentifier)
                return
            }
            let ustawienia = NSWorkspace.OpenConfiguration()
            ustawienia.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: ustawienia)
        case .polecenie(let dzialanie):
            dzialanie()
        }
    }
}
