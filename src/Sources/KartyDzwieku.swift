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
            wynik += karty(pid: pid, nazwaProgramu: program.localizedName ?? identyfikator)
        }
        return wynik
    }

    private static func karty(pid: pid_t, nazwaProgramu: String) -> [KartaGrajaca] {
        let aplikacja = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(aplikacja, 0.4)
        guard let okna = wartosc(aplikacja, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var wynik: [KartaGrajaca] = []
        for (numer, okno) in okna.enumerated() {
            for karta in paskiKart(okno) {
                let opis = (wartosc(karta, kAXDescriptionAttribute) as? String)
                    ?? (wartosc(karta, kAXTitleAttribute) as? String) ?? ""
                let male = opis.lowercased()
                // Safari: sam fakt, ze karta ma przycisk wyciszenia, znaczy „gra".
                let przycisk = przyciskWyciszenia(karta)
                let nazwaPrzycisku = przycisk.flatMap { wartosc($0, kAXTitleAttribute) as? String }?.lowercased() ?? ""
                let gra = sladyGrania.contains(where: { male.contains($0) })
                    || opis.contains(where: { znakiGlosnika.contains($0) })
                    || przycisk != nil
                let wyciszona = sladyWyciszenia.contains(where: { male.contains($0) })
                    || sladyWyciszenia.contains(where: { nazwaPrzycisku.contains($0) })
                guard gra || wyciszona else { continue }
                wynik.append(KartaGrajaca(
                    id: "karta:\(pid):\(numer):\(wynik.count):\(opis.prefix(40))",
                    tytul: czystyTytul(opis),
                    pid: pid,
                    program: nazwaProgramu,
                    element: karta,
                    wyciszona: wyciszona
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
        guard glebokosc < 7,
              let dzieci = wartosc(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var wynik: [AXUIElement] = []
        for dziecko in dzieci {
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
        guard let dzieci = wartosc(karta, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for dziecko in dzieci {
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
        // Menu buduje sie chwile - bez tej przerwy nie ma czego szukac.
        Thread.sleep(forTimeInterval: 0.25)
        guard let pozycja = znajdzPozycjeWyciszenia(aplikacja) else {
            zamknijMenu()
            return false
        }
        return AXUIElementPerformAction(pozycja, kAXPressAction as CFString) == .success
    }

    private static func znajdzPozycjeWyciszenia(_ aplikacja: AXUIElement, glebokosc: Int = 0) -> AXUIElement? {
        guard glebokosc < 5,
              let dzieci = wartosc(aplikacja, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for dziecko in dzieci {
            if (wartosc(dziecko, kAXRoleAttribute) as? String) == kAXMenuRole,
               let pozycje = wartosc(dziecko, kAXChildrenAttribute) as? [AXUIElement] {
                for pozycja in pozycje {
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

    private static func wartosc(_ element: AXUIElement, _ atrybut: String) -> Any? {
        var wynik: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, atrybut as CFString, &wynik) == .success else { return nil }
        return wynik
    }
}
