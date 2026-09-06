import AppKit
import ApplicationServices

// MARK: - Element listy przelacznika

enum SwitcherTarget {
    case window(AXUIElement)
    case browserTab(BrowserTab)
    /// Okno widoczne w spisie systemowym, ale nieoddane przez Accessibility - zdarza sie
    /// dla okien na innym pulpicie, zanim system je tam "obudzi".
    case processWindow(CGWindowID)
}

struct SwitcherItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let pid: pid_t
    let windowID: CGWindowID
    let isMinimized: Bool
    /// Gdzie okno stoi wzgledem biurka, na ktore patrzy uzytkownik.
    let place: WindowPlace
    let target: SwitcherTarget
    var thumbnail: NSImage?
    /// Identyfikator programu — po nim rozpoznajemy, do czego wracasz najczęściej.
    /// Domyślnie pusty, żeby dodanie pola nie wymagało zmiany wszystkich miejsc,
    /// które tworzą element listy.
    var bundleID: String = ""
}

// MARK: - Spis okien systemowych

private struct WindowRecord {
    let windowID: CGWindowID
    let rank: Double
    let title: String
    let place: WindowPlace
}

/// Laczy trzy zrodla prawdy o oknach:
///   1. `CGWindowList` z opcja `.optionAll` - widzi okna ze WSZYSTKICH pulpitow
///      (Spaces) i zna ich kolejnosc od wierzchu, ale nie pozwala ich podniesc,
///   2. Accessibility API - pozwala podniesc konkretne okno i zna stan zminimalizowania,
///   3. SkyLight (`Spaces`) - mowi, na ktorym biurku stoi okno spoza ekranu.
/// Dzieki temu na liscie sa rowniez aplikacje z innego pulpitu, a nie tylko te,
/// ktore akurat widac na ekranie.
final class WindowEnumerator {
    private let ownProcessID = getpid()
    private var iconCache: [String: NSImage] = [:]

    /// Aplikacja, ktora nie odpowiedziala Accessibility w rozsadnym czasie (zawieszona,
    /// w trakcie startu), dostaje kilkusekundowa karencje: przez ten czas jej okna
    /// bierzemy wylacznie ze spisu systemowego, zamiast czekac przy kazdym otwarciu HUD-a.
    private var axPausedUntil: [pid_t: CFAbsoluteTime] = [:]
    private let axSlowThreshold: CFAbsoluteTime = 0.2
    private let axPause: CFAbsoluteTime = 8.0

    /// Ikony aplikacji sa przeskalowane raz i trzymane w cache - inaczej kazde
    /// otwarcie przelacznika kazaloby systemowi renderowac je od nowa.
    private func cachedIcon(for app: NSRunningApplication) -> NSImage? {
        let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        if let cached = iconCache[key] { return cached }
        guard let source = app.icon, let scaled = source.copy() as? NSImage else { return nil }
        scaled.size = NSSize(width: 64, height: 64)
        iconCache[key] = scaled
        return scaled
    }

    /// Okno, ktore znamy z historii uzycia, zawsze wyprzedza okno widziane pierwszy raz -
    /// stad dwa rozlaczne zakresy wartosci.
    private func rank(usage: UInt64?, fallback: Double) -> Double {
        guard let usage else { return 1_000_000.0 + fallback }
        return -Double(usage)
    }

    /// Tytul, ktory czlowiek moze przeczytac - albo nic.
    ///
    /// Niektore programy (edytory z wbudowana przegladarka) podaja jako tytul okna
    /// wewnetrzny adres: `blob:file:///30903694-ab85-4034-...`. Na liscie wygladalo
    /// to jak cztery identyczne karty z ciagiem znakow zamiast nazwy - gorzej niz
    /// sama nazwa programu, bo nie da sie ich od siebie odroznic.
    private func czytelnyTytul(_ tytul: String) -> String {
        let przyciety = tytul.trimmingCharacters(in: .whitespacesAndNewlines)
        for przedrostek in ["blob:", "data:", "about:blank", "chrome-extension://", "devtools://"] {
            if przyciety.hasPrefix(przedrostek) { return "" }
        }
        return przyciety
    }

    private func axWindows(of axApp: AXUIElement, pid: pid_t) -> [AXUIElement]? {
        let started = CFAbsoluteTimeGetCurrent()
        if let pausedUntil = axPausedUntil[pid], pausedUntil > started { return nil }
        let windows = axElements(axApp, AXKey.windows)
        if CFAbsoluteTimeGetCurrent() - started > axSlowThreshold {
            axPausedUntil[pid] = started + axPause
        } else if axPausedUntil[pid] != nil {
            axPausedUntil.removeValue(forKey: pid)
        }
        return windows
    }

    func snapshot(browsers: BrowserTabIndex, usage: WindowUsageTracker) -> [SwitcherItem] {
        let spaces = Spaces.map()
        let records = systemWindows(spaces: spaces, mode: Settings.spacesMode)
        let mode = Settings.browserMode
        // Gdy zgoda na nagrywanie ekranu jest nadana, spis systemowy podaje tytuly okien.
        // Pusty tytul znaczy wtedy naprawde "okno bez tytulu", czyli zwykle okno pomocnicze,
        // ktorego nie ma sensu pokazywac.
        let titlesAvailable = Permissions.screenRecordingGranted
        var ranked: [(rank: Double, item: SwitcherItem)] = []
        var appCounter = 0

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            guard pid != ownProcessID else { continue }

            appCounter += 1
            let appName = app.localizedName ?? "Aplikacja"
            let icon = cachedIcon(for: app)
            let bundleID = app.bundleIdentifier ?? ""
            let appRecords = records[pid] ?? []
            let fallbackRank = 50_000.0 + Double(appCounter) * 10.0
            let appRank = rank(
                usage: usage.appOrder(for: pid),
                fallback: appRecords.map { $0.rank }.min() ?? fallbackRank
            )

            // Tryb "okna i karty" zamienia przegladarke na liste kart.
            if mode.usesTabs, BrowserSupport.isSupported(bundleID) {
                let tabs = browsers.tabsForDisplay(bundleID: bundleID)
                if !tabs.isEmpty {
                    for tab in tabs {
                        let host = BrowserSupport.host(of: tab.url)
                        let title = tab.title.isEmpty ? (host.isEmpty ? appName : host) : tab.title
                        let subtitle = host.isEmpty ? appName : "\(appName) · \(host)"
                        let item = SwitcherItem(
                            id: "tab:\(tab.key)",
                            title: title,
                            subtitle: subtitle,
                            icon: icon,
                            pid: pid,
                            windowID: 0,
                            isMinimized: false,
                            place: .here,
                            target: .browserTab(tab),
                            thumbnail: nil,
                            bundleID: bundleID
                        )
                        let tabRank = appRank + Double(tab.windowIndex) * 0.01 + Double(tab.tabIndex) * 0.0001
                        ranked.append((tabRank, item))
                    }
                    continue
                }
            }

            // Okna z Accessibility, zindeksowane po identyfikatorze systemowym.
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var axByID: [CGWindowID: AXUIElement] = [:]
            var axLoose: [(AXUIElement, String, Bool)] = []
            if let windows = axWindows(of: axApp, pid: pid) {
                for window in windows {
                    let subrole = axString(window, AXKey.subrole)
                    let title = axString(window, AXKey.title) ?? ""
                    if let subrole {
                        guard subrole == AXKey.standardWindow || subrole == AXKey.dialog else { continue }
                    } else if title.isEmpty {
                        continue
                    }
                    let identifier = axWindowID(window)
                    let minimized = axBool(window, AXKey.minimized) ?? false
                    if identifier != 0 {
                        axByID[identifier] = window
                    } else {
                        axLoose.append((window, title, minimized))
                    }
                }
            }

            var used = Set<CGWindowID>()
            // Te same okna potrafia przyjsc dwiema droga: ze spisu systemowego
            // i z Accessibility. Tytul jest jedynym wspolnym mianownikiem, gdy
            // identyfikatory sie nie zgadzaja - bez tego lista ma podwojne pozycje.
            var seenTitles = Set<String>()
            for record in appRecords {
                used.insert(record.windowID)
                let axWindow = axByID[record.windowID]
                let axTitle = axWindow.flatMap { axString($0, AXKey.title) } ?? ""
                let rawTitle = czytelnyTytul(!axTitle.isEmpty ? axTitle : record.title)
                if rawTitle.isEmpty, axWindow == nil, titlesAvailable { continue }
                let title = rawTitle.isEmpty ? appName : rawTitle
                if !rawTitle.isEmpty { seenTitles.insert(rawTitle) }
                let minimized = axWindow.flatMap { axBool($0, AXKey.minimized) } ?? false
                // Bez SkyLight okno zminimalizowane wyglada jak "poza ekranem" -
                // wtedy wracamy do dawnej reguly: zminimalizowane znaczy tutaj.
                let place: WindowPlace = (minimized && !spaces.isAvailable) ? .here : record.place
                let target: SwitcherTarget = axWindow.map { SwitcherTarget.window($0) }
                    ?? SwitcherTarget.processWindow(record.windowID)
                ranked.append((
                    rank(usage: usage.order(for: record.windowID), fallback: record.rank),
                    SwitcherItem(
                        id: "win:\(record.windowID)",
                        title: title,
                        subtitle: appName,
                        icon: icon,
                        pid: pid,
                        windowID: record.windowID,
                        isMinimized: minimized,
                        place: place,
                        target: target,
                        thumbnail: nil,
                        bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                    )
                ))
            }

            // Okna znane tylko Accessibility. Spis systemowy z opcja `.optionAll` widzi
            // praktycznie wszystko, wiec te pozycje dokladamy ostroznie: tylko gdy maja
            // wlasny tytul, ktorego jeszcze nie ma na liscie, albo gdy spis systemowy
            // nie zwrocil dla tej aplikacji zupelnie nic.
            for (identifier, window) in axByID where !used.contains(identifier) {
                let rawTitle = axString(window, AXKey.title) ?? ""
                if !appRecords.isEmpty {
                    guard !rawTitle.isEmpty, !seenTitles.contains(rawTitle) else { continue }
                }
                if !rawTitle.isEmpty { seenTitles.insert(rawTitle) }
                let minimized = axBool(window, AXKey.minimized) ?? false
                ranked.append((
                    rank(usage: usage.order(for: identifier),
                         fallback: fallbackRank + Double(identifier % 1000) * 0.001),
                    SwitcherItem(
                        id: "win:\(identifier)",
                        title: rawTitle.isEmpty ? appName : rawTitle,
                        subtitle: appName,
                        icon: icon,
                        pid: pid,
                        windowID: identifier,
                        isMinimized: minimized,
                        // Biurko pytamy SYSTEMU, zamiast zakładać „to samo".
                        // Accessibility oddaje okna ze wszystkich biurek —
                        // sztywne `.here` kasowało tę wiedzę i program uznawał,
                        // że nie ma dokąd przełączać.
                        place: spaces.place(of: spaces.isAvailable ? Spaces.space(of: identifier) : nil,
                                            onScreen: false),
                        target: .window(window),
                        thumbnail: nil,
                        bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                    )
                ))
            }

            var looseCounter = 0
            for (window, rawTitle, minimized) in axLoose {
                if !appRecords.isEmpty {
                    guard !rawTitle.isEmpty, !seenTitles.contains(rawTitle) else { continue }
                }
                if !rawTitle.isEmpty { seenTitles.insert(rawTitle) }
                looseCounter += 1
                ranked.append((
                    fallbackRank + Double(looseCounter),
                    SwitcherItem(
                        id: "ax:\(pid):\(looseCounter)",
                        title: rawTitle.isEmpty ? appName : rawTitle,
                        subtitle: appName,
                        icon: icon,
                        pid: pid,
                        windowID: 0,
                        isMinimized: minimized,
                        // Te okna nie mają własnego identyfikatora w systemie
                        // (Accessibility oddało je bez numeru), więc nie ma o co
                        // zapytać, na którym są biurku. Zakładamy bieżące —
                        // to jedyne uczciwe założenie przy braku danych.
                        place: .here,
                        target: .window(window),
                        thumbnail: nil,
                        bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                    )
                ))
            }
        }

        ranked.sort { $0.rank < $1.rank }
        return ranked.map { $0.item }
    }

    /// `.optionAll` obejmuje okna ze wszystkich pulpitow; `.optionOnScreenOnly` mowi,
    /// ktore z nich sa na tym, na ktorym uzytkownik jest teraz. Dla pozostalych pytamy
    /// SkyLight o konkretne biurko - tylko dla nich, zeby nie placic za okna widoczne.
    private func systemWindows(spaces: SpaceMap, mode: SpacesMode) -> [pid_t: [WindowRecord]] {
        var onScreen = Set<CGWindowID>()
        if let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in visible {
                if let number = entry[kCGWindowNumber as String] as? CGWindowID {
                    onScreen.insert(number)
                }
            }
        }

        var result: [pid_t: [WindowRecord]] = [:]
        guard let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        var position = 0.0
        for entry in all {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double,
               let height = bounds["Height"] as? Double,
               width < 96 || height < 64 {
                continue
            }
            let visible = onScreen.contains(number)
            let place: WindowPlace = visible
                ? .here
                : spaces.place(of: spaces.isAvailable ? Spaces.space(of: number) : nil, onScreen: false)
            // Tryb "tylko biezace biurko" odfiltrowuje tu, u zrodla - tylko gdy naprawde
            // wiemy, gdzie okno stoi; bez tej wiedzy lepiej pokazac za duzo niz zgubic.
            if mode == .currentDesktop, spaces.isAvailable, !place.isHere { continue }
            position += 1
            let title = entry[kCGWindowName as String] as? String ?? ""
            result[owner, default: []].append(
                WindowRecord(
                    windowID: number,
                    rank: position,
                    title: title,
                    place: place
                )
            )
        }
        // Skład listy do raportu: bez tego wiadomo tylko, co użytkownik wybrał,
        // a nie CO MIAŁ DO WYBORU. Gdy okna z innych biurek w ogóle nie trafiają
        // na listę, objaw wygląda identycznie jak nieudane przełączanie — a to
        // dwie zupełnie różne usterki.
        var wgBiurek: [String: Int] = [:]
        for (_, okna) in result {
            for okno in okna {
                let gdzie: String
                switch okno.place {
                case .here: gdzie = "biezace"
                case .desktop(let n): gdzie = "biurko \(n)"
                case .fullscreen: gdzie = "pelny ekran"
                case .elsewhere: gdzie = "nieznane"
                }
                wgBiurek[gdzie, default: 0] += 1
            }
        }
        let opis = wgBiurek.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · ")
        DziennikBiurek.zapisz("""
            sklad listy (tryb: \(mode == .currentDesktop ? "tylko biezace biurko" : "wszystkie biurka"))
              okien wg polozenia: \(opis.isEmpty ? "brak" : opis)
              spis systemowy zwrocil: \(all.count) wpisow, widocznych na ekranie: \(onScreen.count)
            """)
        return result
    }
}

// MARK: - Przelaczanie fokusu

enum WindowActivator {
    static func activate(_ item: SwitcherItem, browsers: BrowserTabIndex) {
        switch item.target {
        case .browserTab(let tab):
            browsers.focus(tab)
        case .window(let window):
            raise(window: window, windowID: item.windowID, pid: item.pid, wasMinimized: item.isMinimized)
        case .processWindow(let identifier):
            // Accessibility nie oddalo tego okna przy zbieraniu listy - probujemy
            // jeszcze raz teraz; jesli dalej go nie ma, WindowServer i tak potrafi
            // podniesc okno po samym identyfikatorze (razem z biurkiem).
            // Brak uchwytu AX NIE jest osobnym przypadkiem - to zwykly stan okna
            // z innego biurka. Accessibility oddaje wylacznie okna z biurka, na
            // ktorym stoimy (zmierzone: Chrome oddal 1 okno na 31, a program
            // pomocniczy 0 na 6), wiec pytanie o nie przed przeskokiem musi zawiesc.
            // Cala reszta - rozpoznanie biurka, przeskok, ponowne pytanie o okno -
            // jest wspolna, wiec idzie ta sama droga co okna z uchwytem.
            let axApp = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            let match = axElements(axApp, AXKey.windows)?.first(where: { axWindowID($0) == identifier })
            raise(window: match, windowID: identifier, pid: item.pid, wasMinimized: item.isMinimized)
        }
    }

    /// `window` moze byc `nil` - i to jest zwykly przypadek, nie awaria.
    /// Accessibility oddaje okna TYLKO z biezacego biurka, wiec dla celu stojacego
    /// gdzie indziej uchwytu po prostu nie ma. Zdobywamy go po przeskoku.
    private static func raise(window: AXUIElement?, windowID: CGWindowID, pid: pid_t, wasMinimized: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            app.unhide()
        }
        if wasMinimized, let window {
            AXUIElementSetAttributeValue(window, AXKey.minimized as CFString, kCFBooleanFalse)
        }

        // Czy okno stoi na INNYM biurku — musimy to wiedzieć PRZED przeskokiem.
        //
        // Po przeskoku „bieżące biurko" to już tamto, więc porównanie nic nie da.
        // Ta wiedza rozstrzyga o dwóch rzeczach: czy wolno użyć zapasowej aktywacji
        // aplikacji (nie wolno — potrafi wrócić na biurko, z którego wyszliśmy)
        // i czy trzeba naprawić stan biurka źródłowego.
        let mapa = Spaces.map()
        let biurkoZrodlowe = mapa.current.first
        // Czy okno stoi na innym biurku — sprawdzane DWIEMA niezależnymi drogami.
        //
        // Droga pierwsza (SkyLight) bywa niedostępna: to prywatne funkcje systemu,
        // które Apple może w każdej chwili przemianować. Gdy milczą, program nie
        // wie, że okno jest gdzie indziej, i nie robi nic — objaw jest wtedy taki,
        // jakby przełączanie w ogóle nie istniało.
        //
        // Droga druga nie zależy od niczego prywatnego: system pytany o okna
        // WIDOCZNE NA EKRANIE pomija te z innych biurek. Okno, którego tam nie ma,
        // a które nie jest zminimalizowane, leży na innym biurku.
        let biurkoOkna = Spaces.space(of: windowID)
        let wedlugSkyLight: Bool? = {
            guard mapa.isAvailable, biurkoZrodlowe != nil, let biurkoOkna else { return nil }
            return !mapa.current.contains(biurkoOkna)
        }()
        let wedlugWidocznosci = !wasMinimized && !oknoJestNaEkranie(windowID)
        let naInnymBiurku = wedlugSkyLight ?? wedlugWidocznosci

        DziennikBiurek.zapisz("""
            wybor okna \(windowID) (pid \(pid))
              \(DziennikBiurek.stanBiurek())
              biurko okna: \(biurkoOkna.map(String.init) ?? "nieznane")
              inne biurko wg SkyLight: \(wedlugSkyLight.map { $0 ? "TAK" : "nie" } ?? "nie wiadomo")
              inne biurko wg widocznosci: \(wedlugWidocznosci ? "TAK" : "nie")
              decyzja: \(naInnymBiurku ? "PRZESKOK" : "to samo biurko")
            """)
        let programNaWierzchuZrodla = naInnymBiurku
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        // Najpierw WindowServer (przelacza biurko i oddaje fokus), potem Accessibility,
        // zeby sama aplikacja wiedziala, ktore z jej okien jest teraz glowne.
        let broughtByWindowServer = WindowFocus.bring(windowID: windowID, pid: pid)
        // Podnoszenie okna PRZED przejsciem na jego biurko jest bledem, ktory widac
        // od razu: `AXRaise` na oknie z innego biurka nie przenosi CIEBIE do okna,
        // tylko OKNO do ciebie. Uzytkownik zglosil to jednym zdaniem - „nie przerzuca
        // biurka, tylko otwiera w tym samym biurku okna z innego biurka".
        // Na wlasnym biurku podniesienie jest w porzadku i zostaje.
        if let window, !naInnymBiurku {
            AXUIElementSetAttributeValue(window, AXKey.main as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, AXKey.focusedWindow as CFString, window)
            AXUIElementPerformAction(window, AXKey.raise as CFString)
        }

        if naInnymBiurku {
            // ŻADNEJ zapasowej aktywacji aplikacji przy przeskoku na inne biurko:
            // `NSRunningApplication.activate()` przy oknie na innym biurku potrafi
            // przywrócić biurko wyjściowe, czyli cofnąć to, co właśnie zrobiliśmy.
            //
            // Zamiast tego SPRAWDZAMY, czy przełączenie nastąpiło — i jeśli nie,
            // przechodzimy tak, jak zrobiłby to człowiek. WindowServer potrafi
            // odmówić, gdy prośba nie wygląda dla niego na „prosto z ręki
            // użytkownika"; stąd obserwacja, od której to się zaczęło: kliknięcie
            // myszą działa, a wybór klawiaturą nie. Naciśnięcie Ctrl+strzałki —
            // tego samego skrótu, który macOS wykonuje przy geście trzema palcami —
            // system wykonuje zawsze, bo to zwykłe zdarzenie klawiatury.
            let biurkoCelu = biurkoOkna
            // Droga pierwsza: skok WPROST na biurko celu, jednym wywolaniem.
            // Nie udaje klawiatury, nie liczy krokow i nie zalezy od tego, czy
            // uzytkownik ma wlaczone systemowe skroty przechodzenia miedzy biurkami.
            if let cel = biurkoCelu, WindowFocus.skoczNaBiurko(cel, mapa: mapa) {
                poczekajNaBiurko(cel, prob: 10) {
                    DziennikBiurek.zapisz("po skoku wprost: \(DziennikBiurek.stanBiurek())")
                    podniesPoPrzeskoku(window: window, windowID: windowID, pid: pid)
                    dokonczPoPrzeskoku(pid: pid, biurkoZrodlowe: biurkoZrodlowe,
                                       programNaWierzchuZrodla: programNaWierzchuZrodla)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                let poZmianie = Spaces.map()
                DziennikBiurek.zapisz("po probie WindowServera: \(DziennikBiurek.stanBiurek())")
                let trzebaPrzejsc = poZmianie.isAvailable && biurkoCelu != nil
                    && !poZmianie.current.contains(biurkoCelu!)
                guard trzebaPrzejsc,
                      let cel = biurkoCelu,
                      let teraz = poZmianie.current.first,
                      let kroki = SkrotBiurka.odleglosc(z: teraz, do: cel, mapa: poZmianie) else {
                    // Biurko sie zgadza (albo nie ma dokad isc) - zostaje samo okno.
                    podniesPoPrzeskoku(window: window, windowID: windowID, pid: pid)
                    dokonczPoPrzeskoku(pid: pid, biurkoZrodlowe: biurkoZrodlowe,
                                       programNaWierzchuZrodla: programNaWierzchuZrodla)
                    return
                }
                DziennikBiurek.zapisz("WindowServer nie przelaczyl - przechodze skrotem o \(kroki) krok(ow)")
                SkrotBiurka.przejdzKrokami(kroki) {
                    DziennikBiurek.zapisz("po przejsciu skrotem: \(DziennikBiurek.stanBiurek())")
                    // Dopiero gdy system POTWIERDZI biurko, wolno tknac okno.
                    // Samo przejście biurka nie nadaje oknu fokusu — podnosimy je
                    // jeszcze raz, już na właściwym biurku. Tu zapasowa aktywacja
                    // programu jest już bezpieczna: jesteśmy na docelowym biurku,
                    // więc nie ma jak wrócić na tamto, z którego wyszliśmy.
                    _ = WindowFocus.bring(windowID: windowID, pid: pid)
                    poczekajNaBiurko(cel, prob: 10) {
                        podniesPoPrzeskoku(window: window, windowID: windowID, pid: pid)
                        dokonczPoPrzeskoku(pid: pid, biurkoZrodlowe: biurkoZrodlowe,
                                           programNaWierzchuZrodla: programNaWierzchuZrodla)
                    }
                }
            }
            return
        }

        // Odpowiedz WindowServera idzie juz TYLKO do dziennika. Na macOS 26.6
        // `_SLPSSetFrontProcessWithOptions` zwraca zero (czyli „zrobione") i nie
        // zmienia niczego - zmierzone 6 wrzesnia 2026 na tej samej maszynie, na
        // ktorej uzytkownik zglosil, ze ⌘⇥ nie przelacza. Prawdziwe przelaczenie
        // robi `Wierzch`, ktory na koniec PYTA system, ktore okno jest na wierzchu.
        DziennikBiurek.zapisz("WindowServer odpowiedzial: \(broughtByWindowServer ? "przyjete" : "odmowa")")
        podniesPoPrzeskoku(window: window, windowID: windowID, pid: pid)
    }

    /// Czeka, az system POTWIERDZI, ze jestesmy na wskazanym biurku.
    ///
    /// Kazde dotkniecie okna wykonane wczesniej dzieje sie jeszcze na starym
    /// biurku - a wtedy system robi rzecz odwrotna do zamierzonej: przynosi okno
    /// do nas, zamiast przeniesc nas do okna. Wolimy poczekac 1,2 s niz wyrwac
    /// komus okno z drugiego biurka.
    private static func poczekajNaBiurko(_ biurko: SpaceID, prob: Int, dalej: @escaping () -> Void) {
        let mapa = Spaces.map()
        if !mapa.isAvailable || mapa.current.contains(biurko) {
            DziennikBiurek.zapisz("biurko \(biurko) potwierdzone - podnosze okno")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: dalej)
            return
        }
        guard prob > 1 else {
            DziennikBiurek.zapisz("biurko \(biurko) NIE potwierdzone mimo czekania - nie ruszam okna")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            poczekajNaBiurko(biurko, prob: prob - 1, dalej: dalej)
        }
    }

    /// Podniesienie okna, gdy jestesmy juz na jego biurku.
    ///
    /// Gdy uchwytu AX nie bylo, pytamy o okno JESZCZE RAZ - i teraz zwykle jest,
    /// bo Accessibility oddaje okna z biezacego biurka. To jest cala poprawka
    /// zgloszenia „nie przelacza miedzy biurkami": program pytal o okno przed
    /// przeskokiem, dostawal nic i konczyl na aktywacji programu, ktora wyciaga
    /// jego ostatnie okno zamiast wybranego. Przy trzydziestu oknach Chrome
    /// oznaczalo to trafienie w losowe.
    private static func podniesPoPrzeskoku(window: AXUIElement?, windowID: CGWindowID, pid: pid_t) {
        if let window {
            Wierzch.podnies(window: window, windowID: windowID, pid: pid)
            return
        }
        szukajUchwytu(windowID: windowID, pid: pid, prob: 6)
    }

    /// Pytanie o okno kilka razy z rzedu.
    ///
    /// Po przejsciu na inne biurko Accessibility potrzebuje chwili, zanim zacznie
    /// oddawac stojace tam okna - a jedno pytanie zadane za wczesnie wyglada
    /// dokladnie tak samo jak „program nie ma tego okna" i konczylo sie droga
    /// zapasowa, ktora wyciaga losowe okno programu.
    private static func szukajUchwytu(windowID: CGWindowID, pid: pid_t, prob: Int) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        if let swieze = axElements(axApp, AXKey.windows)?.first(where: { axWindowID($0) == windowID }) {
            DziennikBiurek.zapisz("okno \(windowID): uchwyt AX zdobyty (pozostalo prob: \(prob))")
            Wierzch.podnies(window: swieze, windowID: windowID, pid: pid)
            return
        }
        guard prob > 1 else {
            DziennikBiurek.zapisz("okno \(windowID): Accessibility go nie oddaje mimo prob - droga zapasowa")
            Wierzch.podniesProces(windowID: windowID, pid: pid)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            szukajUchwytu(windowID: windowID, pid: pid, prob: prob - 1)
        }
    }

    /// Czy okno jest WIDOCZNE na biezacym biurku.
    ///
    /// System pytany o okna „na ekranie" pomija te z innych biurek — to jedyny
    /// sposob rozpoznania polozenia okna, ktory nie zalezy od prywatnych funkcji
    /// i dziala tak samo w kazdej wersji macOS.
    private static func oknoJestNaEkranie(_ windowID: CGWindowID) -> Bool {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        return lista.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// Domkniecie przeskoku: przywraca stan biurka, z ktorego wyszlismy.
    ///
    /// Przeskok zapisuje NASZ program jako „ten na wierzchu" takze na biurku
    /// zrodlowym. Bez tego po powrocie wyskakuje nasze okno zamiast tego, ktore
    /// tam bylo.
    private static func dokonczPoPrzeskoku(pid: pid_t, biurkoZrodlowe: SpaceID?,
                                           programNaWierzchuZrodla: pid_t?) {
        guard let zrodlo = biurkoZrodlowe,
              let poprzedni = programNaWierzchuZrodla,
              poprzedni != pid else { return }
        WindowFocus.przywrocPoprzednieBiurko(space: zrodlo, pid: poprzedni)
    }

    /// Jednorazowa kontrola po chwili (nie polling): jesli WindowServer mimo wszystko nie
    /// oddal fokusu, aktywujemy aplikacje droga systemowa - lepiej dwa razy niz wcale.
    private static func confirmFrontmost(pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
            activateApp(pid: pid)
        }
    }

    static func activateApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

// MARK: - Miniatury okien

enum WindowThumbnails {
    /// Zrzut okna po jego `CGWindowID`. Wymaga zgody "Nagrywanie ekranu";
    /// bez niej system zwraca pusty obraz i uzywamy ikony aplikacji.
    static func capture(windowID: CGWindowID, maxWidth: CGFloat) -> NSImage? {
        guard windowID != 0, let create = cgWindowListCreateImageFunction else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let unmanaged = create(.null, [.optionIncludingWindow], windowID, options) else { return nil }
        let image = unmanaged.takeRetainedValue()
        guard image.width > 8, image.height > 8 else { return nil }
        let scale = min(1.0, maxWidth / CGFloat(image.width))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSImage(cgImage: image, size: size)
    }
}
