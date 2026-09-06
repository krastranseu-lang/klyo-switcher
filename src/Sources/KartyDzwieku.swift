import AppKit
import ApplicationServices

// MARK: - Ktora KARTA przegladarki gra
//
// CoreAudio nie odpowie na to pytanie i nigdy nie odpowie: zmierzone 6 wrzesnia
// 2026 - Chrome z kilkunastoma kartami ma JEDEN proces dzwieku (miksuje w nim
// wszystkie karty naraz). Z punktu widzenia systemu gra „Chrome", kropka.
//
// Odpowiedz jest gdzie indziej i lezala na wierzchu: przegladarka SAMA oznacza
// grajaca karte, bo musi - czlowiek ma zobaczyc, ktora ucisza. Zmierzone na
// zywym Chrome przez Dostepnosc (zgoda, ktora program i tak ma):
//
//     AXDescription karty: „Superman - YouTube – odtwarzanie dźwięku – 808 MB"
//                                                ^^^^^^^^^^^^^^^^^^
//
// Safari mowi to samo INACZEJ - i wygodniej. Zmierzone tego samego dnia: karta,
// ktora gra, dostaje dziecko `AXButton` o nazwie „wycisz kartę". Czyli jest tam
// naraz WSKAZNIK (jest przycisk = karta gra) i GOTOWA AKCJA (nacisnij go).
//
// Stad dwie drogi wyciszenia, obie prawdziwe:
//     Safari   → nacisnij przycisk na karcie,
//     Chromium → otworz menu karty i wybierz „Wycisz stronę".
//
// Zadna z tych rzeczy nie wymaga zgody na Automatyzacje - wystarczy Dostepnosc,
// ktora program i tak ma. To wazne, bo zgody na Automatyzacje Chrome u wlasciciela
// projektu nie ma i sprawdzone: AppleScript zwraca zero okien.

struct KartaGrajaca: Identifiable {
    let id: String
    let tytul: String
    let pid: pid_t
    let program: String
    let element: AXUIElement
    let wyciszona: Bool
    /// Numery liczone od 1 - tak, jak numeruje karty i okna sama przegladarka
    /// w swoim slowniku polecen. Sluza do wskazania KTOREJ karty dotyczy suwak.
    let numerOkna: Int
    let numerKarty: Int
    let rodzaj: BrowserKind
}

enum KartyDzwieku {
    /// Dopiski, ktorymi przegladarki oznaczaja grajaca karte.
    ///
    /// Napis jest w jezyku PRZEGLADARKI, nie naszym - stad lista, a nie jedno
    /// slowo. Znaki glosnika sa uniwersalne i lapia jezyki, ktorych tu nie ma.
    private static let sladyGrania = [
        "odtwarzanie dźwięku",      // polski
        "audio playing", "playing audio",
        "відтворення звуку", "воспроизведение звука",
        "audiowiedergabe", "wiedergabe von audio",
        "reproduciendo audio", "reproducción de audio",
        "lecture audio", "audio en cours",
        "riproduzione audio", "áudio em reprodução",
        "audio wordt afgespeeld"
    ]

    /// Dopiski oznaczajace karte JUZ wyciszona.
    private static let sladyWyciszenia = [
        "wyciszona", "wyciszone", "muted", "звук вимкнено", "звук выключен",
        "stummgeschaltet", "silenciado", "coupé", "disattivato", "gedempt"
    ]

    private static let znakiGlosnika: [Character] = ["🔊", "🔈", "🔉"]

    /// Nazwy przycisku wyciszenia NA KARCIE - tak robi Safari.
    private static let nazwyPrzycisku = [
        "wycisz", "mute", "вимкнути звук", "выключить звук",
        "stumm", "silenciar", "couper", "disattiva", "dempen"
    ]

    /// Nazwy pozycji menu „Wycisz stronę" i jej odwrotnosci.
    private static let pozycjeWyciszenia = [
        "wycisz", "mute", "вимкнути звук", "выключить звук", "stumm",
        "silenciar", "couper le son", "disattiva audio", "dempen"
    ]

    // MARK: Czytanie

    /// Wszystkie grajace karty WSZYSTKICH otwartych przegladarek.
    ///
    /// Pytamy tylko te programy, ktore wedlug systemu naprawde wysylaja dzwiek -
    /// przechodzenie po drzewie Dostepnosci kilkunastu okien co sekunde bez
    /// powodu byloby praca dla nikogo.
    static func grajace(wsrodGrajacych grajaceProgramy: Set<pid_t>) -> [KartaGrajaca] {
        var wynik: [KartaGrajaca] = []
        for program in NSWorkspace.shared.runningApplications {
            guard let identyfikator = program.bundleIdentifier,
                  BrowserSupport.isSupported(identyfikator) else { continue }
            let pid = program.processIdentifier
            guard grajaceProgramy.contains(pid) else { continue }
            guard let rodzaj = BrowserSupport.definition(for: identyfikator)?.kind else { continue }
            wynik += karty(pid: pid, nazwaProgramu: program.localizedName ?? identyfikator, rodzaj: rodzaj)
        }
        return wynik
    }

    private static func karty(pid: pid_t, nazwaProgramu: String, rodzaj: BrowserKind) -> [KartaGrajaca] {
        let aplikacja = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(aplikacja, 0.4)
        let okna = elementy(aplikacja, kAXWindowsAttribute)
        var wynik: [KartaGrajaca] = []
        for (numer, okno) in okna.enumerated() {
            for (numerKarty, karta) in paskiKart(okno).enumerated() {
                let opis = (wartosc(karta, kAXDescriptionAttribute) as? String)
                    ?? (wartosc(karta, kAXTitleAttribute) as? String) ?? ""
                let male = opis.lowercased()
                // Safari: sam fakt, ze karta ma przycisk wyciszenia, znaczy „gra".
                let przycisk = przyciskWyciszenia(karta)
                let nazwaPrzycisku = przycisk.flatMap { wartosc($0, kAXTitleAttribute) as? String }?.lowercased() ?? ""
                let gra = sladyGrania.contains(where: { male.contains($0) })
                    || opis.contains(where: { znakiGlosnika.contains($0) })
                    || przycisk != nil
                let wyciszonaWgPrzegladarki = sladyWyciszenia.contains(where: { male.contains($0) })
                    || sladyWyciszenia.contains(where: { nazwaPrzycisku.contains($0) })
                let tytul = czystyTytul(opis)
                // Karta zostaje na liscie takze wtedy, gdy MY jej cos ustawilismy.
                // Bez tego wyciszona karta znikala natychmiast po wyciszeniu -
                // Chrome oznacza tylko te, ktore GRAJA - i nie bylo czego kliknac,
                // zeby dzwiek wrocil. To jest usterka „wylaczylem i juz nie wraca".
                let nasza = GlosnoscKarty.zapamietany(pid: pid, tytul: tytul)
                guard gra || wyciszonaWgPrzegladarki || nasza else { continue }
                // Ta sama strona bywa otwarta w dwoch oknach albo w dwoch kartach -
                // na liscie ma stac RAZ, bo suwak i tak dotyczy jej wszystkich
                // wystapien (rozpoznajemy karte po tytule).
                if wynik.contains(where: { $0.tytul == tytul }) { continue }
                wynik.append(KartaGrajaca(
                    id: "karta:\(pid):\(numer):\(numerKarty):\(tytul.prefix(40))",
                    tytul: tytul,
                    pid: pid,
                    program: nazwaProgramu,
                    element: karta,
                    wyciszona: wyciszonaWgPrzegladarki
                        || GlosnoscKarty.poziom(pid: pid, tytul: tytul) <= 0.0001,
                    numerOkna: numer + 1,
                    numerKarty: numerKarty + 1,
                    rodzaj: rodzaj
                ))
            }
        }
        return wynik
    }

    /// Karty okna - szukane po PODROLI `AXTabButton` w calym drzewie.
    ///
    /// Pierwsza wersja szukala ich pod `AXTabGroup` i to bylo za waskie: w Safari
    /// karty leza gdzie indziej, a pierwsza napotkana `AXTabGroup` okazala sie
    /// zawartoscia STRONY, nie paskiem kart.
    private static func paskiKart(_ element: AXUIElement, glebokosc: Int = 0) -> [AXUIElement] {
        guard glebokosc < 8 else { return [] }
        var wynik: [AXUIElement] = []
        for dziecko in elementy(element, kAXChildrenAttribute) {
            if (wartosc(dziecko, kAXSubroleAttribute) as? String) == "AXTabButton" {
                wynik.append(dziecko)
                continue
            }
            wynik += paskiKart(dziecko, glebokosc: glebokosc + 1)
        }
        return wynik
    }

    /// Przycisk wyciszenia NA karcie - Safari go daje, Chromium nie.
    private static func przyciskWyciszenia(_ karta: AXUIElement) -> AXUIElement? {
        for dziecko in elementy(karta, kAXChildrenAttribute) {
            guard (wartosc(dziecko, kAXRoleAttribute) as? String) == kAXButtonRole,
                  let nazwa = (wartosc(dziecko, kAXTitleAttribute) as? String)?.lowercased() else { continue }
            if nazwyPrzycisku.contains(where: { nazwa.contains($0) }) { return dziecko }
        }
        return nil
    }

    /// Tytul bez dopiskow przegladarki - czlowiek ma czytac nazwe strony, a nie
    /// „– duże wykorzystanie pamięci – 808 MB".
    private static func czystyTytul(_ opis: String) -> String {
        // Dopiski Chrome sa doklejane po pauzie (–). Pierwszy czlon to tytul.
        let czesci = opis.components(separatedBy: " – ")
        let tytul = czesci.first ?? opis
        return tytul.trimmingCharacters(in: CharacterSet(charactersIn: " \u{00A0}🔊🔈🔉"))
    }

    // MARK: Dzialanie

    /// Przelacza na te karte - tak, jakby czlowiek w nia kliknal.
    static func pokaz(_ karta: KartaGrajaca) {
        NSRunningApplication(processIdentifier: karta.pid)?
            .activate(options: [.activateAllWindows])
        AXUIElementPerformAction(karta.element, kAXPressAction as CFString)
    }

    /// Czy te karte da sie wyciszyc BEZ pokazywania czegokolwiek na ekranie.
    ///
    /// Safari daje przycisk wprost na karcie - nacisniecie go niczego nie otwiera
    /// i nie wymaga, zeby przegladarka byla na wierzchu (zmierzone: „wycisz kartę"
    /// zmienilo sie w „włącz dźwięk karty" przy nieaktywnym Safari).
    /// Chromium ma tylko menu karty, ktore widac na ekranie.
    static func ciszaBezPokazywania(_ karta: KartaGrajaca) -> Bool {
        przyciskWyciszenia(karta.element) != nil
    }

    /// Wycisza (albo odcisza) POJEDYNCZA karte przez jej wlasne menu.
    ///
    /// To jedyna droga, jaka przegladarka daje: nie ma na to ani API, ani skrotu
    /// klawiszowego. Menu otwiera sie na moment i zamyka samo - klikamy w nim
    /// WYLACZNIE pozycje wyciszenia i nic wiecej.
    @discardableResult
    static func przelaczWyciszenie(_ karta: KartaGrajaca) -> Bool {
        // Droga krotsza i pewniejsza: przycisk wprost na karcie. Zadnego menu,
        // zadnego migania na ekranie.
        if let przycisk = przyciskWyciszenia(karta.element) {
            return AXUIElementPerformAction(przycisk, kAXPressAction as CFString) == .success
        }
        let aplikacja = AXUIElementCreateApplication(karta.pid)
        AXUIElementSetMessagingTimeout(aplikacja, 0.6)
        guard AXUIElementPerformAction(karta.element, "AXShowMenu" as CFString) == .success else {
            return false
        }
        // Menu buduje sie chwile, a otwarte BLOKUJE petle zdarzen przegladarki,
        // wiec odpowiedzi z Dostepnosci przychodza wolniej niz zwykle. Pierwsza
        // wersja czekala 0,25 s i nie znajdowala nic - menu zostawalo otwarte na
        // ekranie, a dzwiek sie nie zmienial. Teraz probujemy kilka razy.
        var pozycja: AXUIElement?
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.12)
            if let znaleziona = znajdzPozycjeWyciszenia(aplikacja) {
                pozycja = znaleziona
                break
            }
        }
        guard let pozycja else {
            zamknijMenu()
            return false
        }
        let udane = AXUIElementPerformAction(pozycja, kAXPressAction as CFString) == .success
        // Menu ma zniknac tak czy inaczej - zostawione otwarte jest gorsze niz
        // brak akcji, bo blokuje przegladarke pod reka czlowieka.
        if !udane { zamknijMenu() }
        return udane
    }

    private static func znajdzPozycjeWyciszenia(_ aplikacja: AXUIElement, glebokosc: Int = 0) -> AXUIElement? {
        guard glebokosc < 5 else { return nil }
        for dziecko in elementy(aplikacja, kAXChildrenAttribute) {
            // Pasek menu programu nie jest tym, czego szukamy - tam „Wycisz"
            // nie ma prawa byc, a schodzenie w niego kosztuje czas przy
            // zablokowanej przegladarce.
            if (wartosc(dziecko, kAXRoleAttribute) as? String) == kAXMenuBarRole { continue }
            if (wartosc(dziecko, kAXRoleAttribute) as? String) == kAXMenuRole {
                for pozycja in elementy(dziecko, kAXChildrenAttribute) {
                    guard let tytul = (wartosc(pozycja, kAXTitleAttribute) as? String)?.lowercased() else { continue }
                    if pozycjeWyciszenia.contains(where: { tytul.contains($0) }) { return pozycja }
                }
            }
            if let znaleziona = znajdzPozycjeWyciszenia(dziecko, glebokosc: glebokosc + 1) { return znaleziona }
        }
        return nil
    }

    /// Esc - gdy w menu nie ma czego szukac, ma sie zamknac, a nie zostac otwarte.
    private static func zamknijMenu() {
        guard let zrodlo = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: zrodlo, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: zrodlo, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Odczyt atrybutu - przez wspolny pomocnik programu, nie wlasny.
    /// Wlasna kopia byla druga wersja tej samej rzeczy i rozjechalaby sie
    /// przy pierwszej poprawce w tamtej.
    private static func wartosc(_ element: AXUIElement, _ atrybut: String) -> Any? {
        axCopy(element, atrybut)
    }

    /// Tablica elementow czytana przez API CoreFoundation, a nie przez rzutowanie.
    ///
    /// `as? [AXUIElement]` na tablicy CF potrafi zwrocic pusto mimo poprawnej
    /// zawartosci - i wtedy „nie ma kart" znaczy tylko tyle, ze Swift nie umial
    /// przelozyc typu. Tu liczymy elementy wprost, wiec nie ma czego zgadywac.
    private static func elementy(_ element: AXUIElement, _ atrybut: String) -> [AXUIElement] {
        guard let surowe = axCopy(element, atrybut) else { return [] }
        guard CFGetTypeID(surowe) == CFArrayGetTypeID() else { return [] }
        let tablica = surowe as! CFArray
        var wynik: [AXUIElement] = []
        for numer in 0..<CFArrayGetCount(tablica) {
            guard let wskaznik = CFArrayGetValueAtIndex(tablica, numer) else { continue }
            let pozycja = unsafeBitCast(wskaznik, to: AXUIElement.self)
            guard CFGetTypeID(pozycja) == AXUIElementGetTypeID() else { continue }
            wynik.append(pozycja)
        }
        return wynik
    }

    /// Role dzieci na kolejnych poziomach - dla sondy, gdy kart nie widac.
    static func drzewo(pid: pid_t, poziomy: Int = 5) -> [String] {
        var wiersze: [String] = []
        let aplikacja = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(aplikacja, 1.0)
        for (numer, okno) in elementy(aplikacja, kAXWindowsAttribute).enumerated() where numer < 2 {
            wiersze.append("okno \(numer): \((wartosc(okno, kAXTitleAttribute) as? String)?.prefix(40) ?? "")")
            func zejdz(_ element: AXUIElement, _ poziom: Int) {
                guard poziom < poziomy else { return }
                for dziecko in elementy(element, kAXChildrenAttribute) {
                    let rola = (wartosc(dziecko, kAXRoleAttribute) as? String) ?? "?"
                    let pod = (wartosc(dziecko, kAXSubroleAttribute) as? String) ?? ""
                    wiersze.append(String(repeating: "  ", count: poziom + 1) + rola + (pod.isEmpty ? "" : "/" + pod))
                    zejdz(dziecko, poziom + 1)
                }
            }
            zejdz(okno, 0)
        }
        return wiersze
    }

    /// Ile czego widac - dla sondy. „Zero kart" i „zero okien" to dwie rozne
    /// usterki, a bez licznika wygladaja tak samo.
    static func policz(pid: pid_t) -> (okna: Int, karty: Int, zaufanie: Bool) {
        let aplikacja = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(aplikacja, 0.6)
        let okna = elementy(aplikacja, kAXWindowsAttribute)
        var karty = 0
        for okno in okna { karty += paskiKart(okno).count }
        return (okna.count, karty, AXIsProcessTrusted())
    }
}
