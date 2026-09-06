import AppKit
import ApplicationServices

// MARK: - Postawienie KONKRETNEGO okna na wierzchu
//
// Dlaczego osobny plik: na macOS 26 przestala dzialac droga, ktora program uwazal
// za glowna. `_SLPSSetFrontProcessWithOptions` zwraca 0 (czyli „zrobione"), a nie
// dzieje sie NIC - zmierzone 6 wrzesnia 2026 na macOS 26.6: okno na wierzchu
// zostawalo to samo, mimo trzech kolejnych wywolan z kodem powodzenia.
//
// Skutek dla uzytkownika byl taki, jakby przelacznik nie istnial: lista sie
// pokazywala, znikala po puszczeniu ⌘ i okno zostawalo to samo. Najczestszy ruch -
// jedno ⌘⇥ na poprzednie okno - nie dzialal ANI RAZU w piatce prob.
//
// Droga, ktora dziala (sprawdzona na tej samej maszynie, 4 przypadki na 4, w tym
// przelaczenie miedzy dwoma oknami TEGO SAMEGO programu):
//   1. `AXFrontmost = true` na aplikacji - to jest ta czesc, ktorej brakowalo,
//   2. chwila przerwy (system wystawia aplikacje na wierzch swoim tempem),
//   3. `AXMain`, `AXFocusedWindow` i `AXRaise` na wybranym oknie.
//
// Niezmiennik: **wynik sprawdzamy, a nie zakladamy**. Kazde przelaczenie konczy
// pytaniem do systemu, ktore okno jest teraz na wierzchu. Zalozenie, ze „skoro
// funkcja zwrocila zero, to sie udalo", kosztowalo tydzien szukania nie tam.

enum Wierzch {
    /// Ile czekamy, zanim wydamy oknu polecenie podniesienia. Aplikacja potrzebuje
    /// chwili, zeby stac sie ta na wierzchu; bez tej przerwy podniesienie trafia
    /// w program, ktory jeszcze nie jest aktywny, i przepada.
    private static let przerwaPoAktywacji = 0.12
    /// Po tylu sekundach pytamy system, czy naprawde sie udalo.
    private static let przerwaPrzedSprawdzeniem = 0.30

    /// Numer okna, ktore jest teraz na samym wierzchu. Pytamy o to spis systemowy,
    /// bo tylko on zna kolejnosc rysowania - `frontmostApplication` mowi o PROGRAMIE,
    /// a przy dwoch oknach tego samego programu to za malo, zeby cokolwiek stwierdzic.
    static func czoloOkna() -> CGWindowID? {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return nil }
        for wpis in lista {
            guard let warstwa = wpis[kCGWindowLayer as String] as? Int, warstwa == 0 else { continue }
            guard let numer = wpis[kCGWindowNumber as String] as? CGWindowID else { continue }
            return numer
        }
        return nil
    }

    /// Postawienie okna na wierzchu wraz z wystawieniem jego programu.
    /// `dopilnuj` mowi, czy po wszystkim sprawdzic wynik i w razie czego powtorzyc.
    static func podnies(window: AXUIElement, windowID: CGWindowID, pid: pid_t, dopilnuj: Bool = true) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        AXUIElementSetAttributeValue(axApp, AXKey.frontmost as CFString, kCFBooleanTrue)

        DispatchQueue.main.asyncAfter(deadline: .now() + przerwaPoAktywacji) {
            wskazOkno(axApp: axApp, window: window)
            guard dopilnuj else { return }
            sprawdzWynik(window: window, windowID: windowID, pid: pid, proba: 1)
        }
    }

    /// Okno, ktorego Accessibility nie oddalo przy zbieraniu listy (zdarza sie oknom
    /// z innych biurek i programom, ktore odpowiadaja wolno). Mamy tylko numer okna.
    ///
    /// Wystawiamy program na wierzch i pytamy o jego okna JESZCZE RAZ - aktywny
    /// program oddaje je czesciej niz uspiony. Gdy dalej ich nie ma, zostaje sama
    /// aktywacja programu, ale wynik i tak sprawdzamy: dotad ta droga konczyla sie
    /// cisza i to ona odpowiadala za pozycje listy, ktore „nic nie robily".
    static func podniesProces(windowID: CGWindowID, pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        AXUIElementSetAttributeValue(axApp, AXKey.frontmost as CFString, kCFBooleanTrue)

        DispatchQueue.main.asyncAfter(deadline: .now() + przerwaPoAktywacji) {
            if let okna = axElements(axApp, AXKey.windows),
               let dopasowane = okna.first(where: { axWindowID($0) == windowID }) {
                DziennikBiurek.zapisz("okno \(windowID) znalezione w Accessibility po wystawieniu programu")
                wskazOkno(axApp: axApp, window: dopasowane)
                sprawdzWynik(window: dopasowane, windowID: windowID, pid: pid, proba: 1)
                return
            }
            sprawdzSamProces(windowID: windowID, pid: pid)
        }
    }

    /// Sprawdzenie wyniku, gdy nie mamy uchwytu do okna - zostaje pytanie „czy na
    /// wierzchu jest to, o co prosilismy" i jedna proba drogą systemową.
    private static func sprawdzSamProces(windowID: CGWindowID, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + przerwaPrzedSprawdzeniem) {
            if czoloOkna() == windowID {
                DziennikBiurek.zapisz("przelaczenie na okno \(windowID) (pid \(pid)): UDANE (bez uchwytu AX)")
                return
            }
            WindowActivator.activateApp(pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + przerwaPrzedSprawdzeniem) {
                let czolo = czoloOkna()
                DziennikBiurek.zapisz("""
                    przelaczenie na okno \(windowID) (pid \(pid)): \
                    \(czolo == windowID ? "UDANE po aktywacji programu" : "NIEUDANE - na wierzchu \(czolo.map(String.init) ?? "nieznane")") \
                    (program bez uchwytu AX do tego okna)
                    """)
            }
        }
    }

    /// Trzy polecenia, ktore mowia programowi „to okno jest teraz glowne".
    /// Osobno, bo powtarzamy je przy drugiej probie.
    private static func wskazOkno(axApp: AXUIElement, window: AXUIElement) {
        AXUIElementSetAttributeValue(window, AXKey.main as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, AXKey.mainWindow as CFString, window)
        AXUIElementSetAttributeValue(axApp, AXKey.focusedWindow as CFString, window)
        AXUIElementPerformAction(window, AXKey.raise as CFString)
    }

    /// Sprawdzenie wyniku po numerze OKNA, nie po nazwie programu.
    ///
    /// Pierwsza proba nieudana -> powtarzamy to samo (aplikacja mogla jeszcze nie
    /// byc na wierzchu). Druga nieudana -> zostaje droga systemowa, ktora umie
    /// wystawic program, choc nie umie wybrac okna. Trzecia nieudana konczy sie
    /// wpisem w dzienniku - cicho nie znikamy.
    private static func sprawdzWynik(window: AXUIElement, windowID: CGWindowID, pid: pid_t, proba: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + przerwaPrzedSprawdzeniem) {
            let czolo = czoloOkna()
            if czolo == windowID {
                DziennikBiurek.zapisz("przelaczenie na okno \(windowID) (pid \(pid)): UDANE (proba \(proba))")
                return
            }
            switch proba {
            case 1:
                DziennikBiurek.zapisz("""
                    przelaczenie na okno \(windowID) (pid \(pid)): na wierzchu jest \
                    \(czolo.map(String.init) ?? "nieznane") - powtarzam
                    """)
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.35)
                AXUIElementSetAttributeValue(axApp, AXKey.frontmost as CFString, kCFBooleanTrue)
                wskazOkno(axApp: axApp, window: window)
                sprawdzWynik(window: window, windowID: windowID, pid: pid, proba: 2)
            case 2:
                DziennikBiurek.zapisz("przelaczenie na okno \(windowID): druga proba nie wyszla - droga systemowa")
                WindowActivator.activateApp(pid: pid)
                AXUIElementPerformAction(window, AXKey.raise as CFString)
                sprawdzWynik(window: window, windowID: windowID, pid: pid, proba: 3)
            default:
                DziennikBiurek.zapisz("""
                    przelaczenie na okno \(windowID) (pid \(pid)): NIEUDANE - na wierzchu \
                    \(czolo.map(String.init) ?? "nieznane")
                    """)
            }
        }
    }
}
