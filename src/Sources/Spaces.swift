import AppKit
import ApplicationServices

// MARK: - Biurka (Spaces) i fokus okna po stronie WindowServera
//
// macOS nie ma publicznego API, ktore odpowie "na ktorym biurku stoi to okno" ani
// ktore przeniesie fokus na okno z innego biurka razem z przelaczeniem biurka.
// Robi to WindowServer przez prywatna biblioteke SkyLight - te same wywolania,
// z ktorych korzystaja AltTab i Hammerspoon. Symbole pobieramy przez `dlsym`:
//   - brak symbolu (np. przyszly macOS) NIE wywala aplikacji - wracamy do drogi
//     systemowej (aktywacja aplikacji), tylko bez gwarancji zmiany biurka,
//   - zadnych prywatnych naglowkow, kompiluje sie zwyklym `swiftc`.
//
// Niezmiennik: kazda funkcja z `SkyLight` jest opcjonalna, a reszta aplikacji MUSI
// dzialac poprawnie (choc ubozej), gdy ktoras jest `nil`.

typealias SpaceID = UInt64

enum SkyLight {
    typealias MainConnection = @convention(c) () -> Int32
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// SkyLight jest juz zaladowany w kazdym procesie AppKit; osobne `dlopen` to tylko
    /// zabezpieczenie na wypadek, gdyby kiedys przestal byc ladowany domyslnie.
    private static let library: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

    /// Nazwy w kolejnosci prob: nowe `SLS*` z SkyLight, potem starsze aliasy `CGS*`.
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        for name in names {
            if let found = dlsym(rtldDefault, name) { return found }
            if let library, let found = dlsym(library, name) { return found }
        }
        return nil
    }

    static let mainConnectionID: MainConnection? = {
        guard let pointer = symbol(["SLSMainConnectionID", "CGSMainConnectionID"]) else { return nil }
        return unsafeBitCast(pointer, to: MainConnection.self)
    }()

    static let copySpacesForWindows: CopySpacesForWindows? = {
        guard let pointer = symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"]) else { return nil }
        return unsafeBitCast(pointer, to: CopySpacesForWindows.self)
    }()

    static let copyManagedDisplaySpaces: CopyManagedDisplaySpaces? = {
        guard let pointer = symbol(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"]) else { return nil }
        return unsafeBitCast(pointer, to: CopyManagedDisplaySpaces.self)
    }()

    static let setFrontProcessWithOptions: SetFrontProcessWithOptions? = {
        guard let pointer = symbol(["_SLPSSetFrontProcessWithOptions"]) else { return nil }
        return unsafeBitCast(pointer, to: SetFrontProcessWithOptions.self)
    }()

    /// Ustawia proces na wierzchu POJEDYNCZEGO biurka, bez ruszania reszty.
    ///
    /// Potrzebne po przeskoku na inne biurko: przelaczenie zapisuje NASZ program
    /// jako „ten na wierzchu" takze na biurku, z ktorego wyszlismy. Po powrocie
    /// wyskakuje wtedy nie to okno, ktore tam bylo. Ta funkcja przywraca stan
    /// poprzedniego biurka.
    static let spaceSetFrontPSN: SpaceSetFrontPSN? = {
        guard let pointer = symbol(["SLSSpaceSetFrontPSN"]) else { return nil }
        return unsafeBitCast(pointer, to: SpaceSetFrontPSN.self)
    }()

    /// Skok WPROST na wskazane biurko - bez udawania Ctrl+strzalek.
    ///
    /// Zmierzone 6 wrzesnia 2026 na macOS 26.6: `SLSManagedDisplaySetCurrentSpace`
    /// odpowiada zerem i biurko naprawde sie zmienia. To jedyna z prywatnych drog,
    /// ktora na tym systemie jeszcze robi to, co obiecuje - `_SLPSSetFrontProcess`
    /// zwraca zero i nie robi nic.
    typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Int32

    static let setCurrentSpace: SetCurrentSpace? = {
        guard let pointer = symbol(["SLSManagedDisplaySetCurrentSpace", "CGSManagedDisplaySetCurrentSpace"]) else {
            return nil
        }
        return unsafeBitCast(pointer, to: SetCurrentSpace.self)
    }()

    static let postEventRecordTo: PostEventRecordTo? = {
        guard let pointer = symbol(["SLPSPostEventRecordTo"]) else { return nil }
        return unsafeBitCast(pointer, to: PostEventRecordTo.self)
    }()

    /// `GetProcessForPID` jest oznaczone jako przestarzale, ale nadal dziala - wolane
    /// przez wskaznik, zeby build byl wolny od ostrzezen (jak `CGWindowListCreateImage`).
    static let processForPID: ProcessForPID? = {
        guard let pointer = symbol(["GetProcessForPID"]) else { return nil }
        return unsafeBitCast(pointer, to: ProcessForPID.self)
    }()

    /// Polaczenie z WindowServerem - jedno na proces, nigdy nie zamykane.
    typealias SpaceSetFrontPSN = @convention(c) (Int32, UInt64, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    static let connection: Int32? = mainConnectionID?()

    static var canReadSpaces: Bool {
        connection != nil && copySpacesForWindows != nil && copyManagedDisplaySpaces != nil
    }

    static var canBringWindows: Bool {
        setFrontProcessWithOptions != nil && postEventRecordTo != nil && processForPID != nil
    }
}

// MARK: - Polozenie okna wzgledem biurka uzytkownika

enum WindowPlace: Equatable {
    /// Na biurku, na ktore uzytkownik patrzy (albo zminimalizowane z tego biurka).
    case here
    /// Na innym zwyklym biurku - numer taki, jak w Mission Control ("Biurko 2").
    case desktop(Int)
    /// Aplikacja w trybie pelnoekranowym - ma wlasne biurko bez numeru.
    case fullscreen
    /// Poza ekranem, ale system nie zdradzil gdzie (brak SkyLight).
    case elsewhere

    var isHere: Bool { self == .here }

    var label: String? {
        switch self {
        case .here: return nil
        case .desktop(let number): return "Biurko \(number)"
        case .fullscreen: return "Pełny ekran"
        case .elsewhere: return "Inne biurko"
        }
    }
}

/// Migawka ukladu biurek pobierana raz na otwarcie HUD-a: ktore biurka sa teraz
/// widoczne (po jednym na monitor) i jaki numer nosi kazde zwykle biurko.
struct SpaceMap {
    let current: Set<SpaceID>
    let desktopNumbers: [SpaceID: Int]
    let fullscreen: Set<SpaceID>
    let isAvailable: Bool
    /// Ekran, na ktorym stoi dane biurko. Potrzebny, zeby skoczyc na nie WPROST -
    /// system pyta o biurko zawsze razem z ekranem, bo kazdy monitor ma wlasny zestaw.
    var ekranBiurka: [SpaceID: String] = [:]

    static let unavailable = SpaceMap(current: [], desktopNumbers: [:], fullscreen: [], isAvailable: false)

    /// `onScreen` to zapasowa prawda ze spisu systemowego - uzywana tylko, gdy
    /// SkyLight nie odpowiedzial (wtedy okno spoza ekranu opisujemy ostroznie).
    func place(of space: SpaceID?, onScreen: Bool) -> WindowPlace {
        guard isAvailable, let space else { return onScreen ? .here : .elsewhere }
        if current.contains(space) { return .here }
        if let number = desktopNumbers[space] { return .desktop(number) }
        if fullscreen.contains(space) { return .fullscreen }
        return .elsewhere
    }
}

enum Spaces {
    /// Maska "wszystkie biurka": biezace (1) | pozostale (2) | pelnoekranowe (4).
    private static let allSpacesMask: Int32 = 0x7
    /// Typ 0 = zwykle biurko uzytkownika; inne typy to pelny ekran / kafelki.
    private static let desktopType = 0

    static func map() -> SpaceMap {
        guard let cid = SkyLight.connection,
              let copy = SkyLight.copyManagedDisplaySpaces,
              let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return .unavailable
        }
        var current = Set<SpaceID>()
        var numbers: [SpaceID: Int] = [:]
        var fullscreen = Set<SpaceID>()
        var ekrany: [SpaceID: String] = [:]
        var desktopCounter = 0
        // Monitory przychodza w kolejnosci Mission Control, wiec numeracja biurek
        // rosnie tak samo, jak widzi ja uzytkownik na gornym pasku Mission Control.
        for display in displays {
            if let active = display["Current Space"] as? [String: Any], let identifier = spaceID(active) {
                current.insert(identifier)
            }
            let ekran = display["Display Identifier"] as? String
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let identifier = spaceID(space) else { continue }
                if let ekran { ekrany[identifier] = ekran }
                let type = (space["type"] as? NSNumber)?.intValue ?? desktopType
                if type == desktopType {
                    desktopCounter += 1
                    numbers[identifier] = desktopCounter
                } else {
                    fullscreen.insert(identifier)
                }
            }
        }
        return SpaceMap(current: current, desktopNumbers: numbers, fullscreen: fullscreen,
                        isAvailable: !current.isEmpty, ekranBiurka: ekrany)
    }

    private static func spaceID(_ dictionary: [String: Any]) -> SpaceID? {
        ((dictionary["id64"] ?? dictionary["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }

    /// Biurko konkretnego okna. Jedno zapytanie do WindowServera (mikrosekundy) -
    /// wolane tylko dla okien, ktorych nie widac na ekranie.
    static func space(of windowID: CGWindowID) -> SpaceID? {
        guard let cid = SkyLight.connection, let copy = SkyLight.copySpacesForWindows else { return nil }
        let list = [NSNumber(value: windowID)] as CFArray
        guard let spaces = copy(cid, allSpacesMask, list)?.takeRetainedValue() as? [NSNumber],
              let first = spaces.first else { return nil }
        return first.uint64Value
    }
}

// MARK: - Fokus okna z przelaczeniem biurka

enum WindowFocus {
    /// Przejscie na wskazane biurko jednym wywolaniem. `false` znaczy, ze system
    /// nie ma tej funkcji albo odmowil - wtedy zostaje droga przez skrot klawiszowy.
    @discardableResult
    static func skoczNaBiurko(_ biurko: SpaceID, mapa: SpaceMap) -> Bool {
        guard let cid = SkyLight.connection,
              let skok = SkyLight.setCurrentSpace,
              let ekran = mapa.ekranBiurka[biurko] else { return false }
        let wynik = skok(cid, ekran as CFString, biurko)
        DziennikBiurek.zapisz("skok wprost na biurko \(biurko) (ekran \(ekran.prefix(8))): odpowiedz \(wynik)")
        return wynik == 0
    }

    /// Tryb "jak z reki uzytkownika" - WindowServer przelacza biurko tak samo,
    /// jak po kliknieciu okna w Docku albo w Mission Control.
    private static let userGenerated: UInt32 = 0x200
    private static let recordLength = 0xF8

    /// Przenosi proces i wskazane okno na wierzch po stronie WindowServera; jesli
    /// okno stoi na innym biurku, system przelacza biurko. Zwraca `false`, gdy
    /// prywatne funkcje sa niedostepne - wtedy dzwoni sciezka systemowa.
    @discardableResult
    static func bring(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard windowID != 0,
              let processForPID = SkyLight.processForPID,
              let setFront = SkyLight.setFrontProcessWithOptions,
              let post = SkyLight.postEventRecordTo else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return false }
        // Wynik CELOWO nie przerywa dalszych krokow. WindowServer potrafi zwrocic
        // niezerowy kod i mimo to wykonac przelaczenie, a nastepne kroki (zdarzenia
        // „key" i podniesienie przez Accessibility) dokoncza robote. Przerywanie
        // w tym miejscu konczylo sie sciezka zapasowa, ktora WRACALA na biurko,
        // z ktorego wlasnie wyszlismy.
        _ = setFront(&psn, windowID, userGenerated)

        // JEDEN rekord zdarzenia: wcisniecie lewego przycisku myszy „w to okno",
        // wycelowane daleko poza jego tresc. Uklad bajtow przepisany z AltTab
        // (src/macos/api-wrappers/SkyLight.framework.swift, zweryfikowany przez
        // nich na macOS 26.5), ktory rozni sie od naszego dawnego w trzech miejscach
        // i kazde z nich AltTab uzasadnia pomiarem:
        //   - bufor 0x100 zamiast 0xF8: WindowServer od 14.7.4 czyta poza rekord,
        //   - sam DOWN (typ 0x01), bez UP: para down/up to juz klikniecie,
        //     a sam down wystarcza, zeby okno stalo sie „key",
        //   - punkt (300000, 300000) zamiast NaN: NaN niektore programy zamieniaja
        //     na (0,0), czyli klikaja w lewy gorny rog wlasnej tresci.
        var record = [UInt8](repeating: 0, count: 0x100)
        record[0x04] = 0xF8          // deklarowana dlugosc rekordu
        record[0x08] = 0x01          // kCGEventLeftMouseDown
        record[0x3A] = 0x10          // flaga o nieznanym znaczeniu; yabai i Hammerspoon ustawiaja 0x10
        var punkt = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &punkt) { raw in
            for (index, byte) in raw.enumerated() { record[0x20 + index] = byte }
        }
        withUnsafeBytes(of: windowID) { raw in
            for (index, byte) in raw.enumerated() { record[0x3C + index] = byte }
        }
        record.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = post(&psn, base)
        }
        return true
    }

    /// Przywraca program, ktory byl na wierzchu POPRZEDNIEGO biurka.
    ///
    /// Bez tego powrot na tamto biurko pokazuje nasze okno zamiast tego, ktore
    /// tam bylo — bo przeskok zapisal nas jako „ten na wierzchu" takze tam.
    static func przywrocPoprzednieBiurko(space: UInt64, pid: pid_t) {
        guard let processForPID = SkyLight.processForPID,
              let setFront = SkyLight.spaceSetFrontPSN,
              let polaczenie = SkyLight.connection else { return }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return }
        _ = setFront(polaczenie, space, &psn)
    }
}

// MARK: - Ustawienie systemowe, od ktorego zalezy przelaczanie biurek

/// macOS przelacza biurko przy aktywacji okna TYLKO wtedy, gdy czlowiek na to
/// pozwolil w ustawieniu:
///
///   Ustawienia → Biurko i Dock → Mission Control →
///   „Podczas przelaczania sie do programu przelacz na biurko z otwartymi oknami
///    tego programu"
///
/// Gdy jest wylaczone, ZADEN przelacznik okien nie zmieni biurka - to decyzja
/// systemu, nie programu. Program, ktory o tym milczy, wyglada na zepsuty:
/// pokazuje okno z innego biurka, czlowiek je wybiera i nic sie nie dzieje.
enum PrzelaczanieBiurek {
    static let klucz = "AppleSpacesSwitchOnActivate"

    /// Czy system ma pozwolenie na zmiane biurka. Brak wpisu znaczy „wlaczone" -
    /// takie jest ustawienie domyslne macOS.
    static var wlaczone: Bool {
        guard let wartosc = UserDefaults.standard.object(forKey: klucz) else { return true }
        return (wartosc as? Bool) ?? true
    }

    /// Wlacza ustawienie i przeladowuje Dock, zeby zaczelo obowiazywac od razu.
    ///
    /// Zmieniamy CUDZE ustawienie systemowe, wiec robimy to wylacznie na wyrazne
    /// klikniecie czlowieka - nigdy sami przy starcie.
    /// Ustawia wartosc w obie strony - wlaczyc i wylaczyc.
    @discardableResult
    static func ustaw(_ wlaczone: Bool) -> Bool {
        UserDefaults.standard.set(wlaczone, forKey: klucz)
        UserDefaults.standard.synchronize()

        let zapis = Process()
        zapis.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        zapis.arguments = ["write", "-g", klucz, "-bool", wlaczone ? "true" : "false"]
        zapis.standardOutput = FileHandle.nullDevice
        zapis.standardError = FileHandle.nullDevice
        guard (try? zapis.run()) != nil else { return false }
        zapis.waitUntilExit()

        // Bez przeladowania Docka ustawienie zaczyna dzialac dopiero po wylogowaniu.
        let dock = Process()
        dock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dock.arguments = ["Dock"]
        dock.standardOutput = FileHandle.nullDevice
        dock.standardError = FileHandle.nullDevice
        try? dock.run()
        dock.waitUntilExit()
        return zapis.terminationStatus == 0
    }

    @discardableResult
    static func wlacz() -> Bool {
        UserDefaults.standard.set(true, forKey: klucz)
        UserDefaults.standard.synchronize()

        let zapis = Process()
        zapis.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        zapis.arguments = ["write", "-g", klucz, "-bool", "true"]
        zapis.standardOutput = FileHandle.nullDevice
        zapis.standardError = FileHandle.nullDevice
        guard (try? zapis.run()) != nil else { return false }
        zapis.waitUntilExit()

        // Bez przeladowania Docka ustawienie zaczyna dzialac dopiero po wylogowaniu.
        let dock = Process()
        dock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dock.arguments = ["Dock"]
        dock.standardOutput = FileHandle.nullDevice
        dock.standardError = FileHandle.nullDevice
        try? dock.run()
        dock.waitUntilExit()
        return zapis.terminationStatus == 0
    }

    /// Otwiera panel, w ktorym to ustawienie sie znajduje.
    static func otworzUstawienia() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.dock") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Zapasowa droga: ten sam skrot, ktorego uzywa gest trzema palcami

/// Przejscie na inne biurko systemowym skrotem Ctrl+strzalka.
///
/// Dlaczego to w ogole istnieje: WindowServer potrafi ODMOWIC przelaczenia, gdy
/// prosba nie wyglada dla niego na „prosto z reki uzytkownika". Dlatego klikniecie
/// mysza w liscie dziala, a wybor klawiatura nie - to samo okno, ta sama funkcja,
/// inny kontekst zdarzenia. Zamiast zgadywac, czego systemowi zabraklo, robimy to,
/// co robi czlowiek: naciskamy ten sam skrot, ktory macOS wykonuje przy gescie
/// trzema palcami. Tego system nie odmawia, bo to zwykle nacisniecie klawiszy.
///
/// Ctrl+strzalka jest w macOS wlaczone domyslnie (inaczej niz Ctrl+numer biurka),
/// wiec dziala u kazdego bez grzebania w ustawieniach.
enum SkrotBiurka {
    private static let strzalkaWLewo: CGKeyCode = 123
    private static let strzalkaWPrawo: CGKeyCode = 124

    /// Ile krokow w prawo (dodatnie) albo w lewo (ujemne) dzieli biurka.
    /// `nil`, gdy ktoregos z nich nie ma w spisie (np. okno pelnoekranowe).
    static func odleglosc(z: SpaceID, do cel: SpaceID, mapa: SpaceMap) -> Int? {
        guard let numerZ = mapa.desktopNumbers[z], let numerDo = mapa.desktopNumbers[cel] else { return nil }
        return numerDo - numerZ
    }

    /// Przechodzi o zadana liczbe biurek. Kazdy krok to jedno nacisniecie
    /// Ctrl+strzalka z przerwa na animacje przejscia - bez niej system gubi
    /// kolejne nacisniecia i konczymy na biurku posrednim.
    /// Klawisz Control jako klawisz, nie jako flaga doklejona do strzalki.
    private static let klawiszControl: CGKeyCode = 59

    static func przejdzKrokami(_ kroki: Int, zakonczenie: @escaping () -> Void) {
        guard kroki != 0, abs(kroki) <= 12 else { zakonczenie(); return }
        let klawisz = kroki > 0 ? strzalkaWPrawo : strzalkaWLewo
        // Control WCISNIETY - osobnym zdarzeniem zmiany flag, tak jak z klawiatury.
        //
        // To jest cala roznica miedzy „przechodzi" a „nie przechodzi". Zmierzone
        // 6 wrzesnia 2026 na macOS 26.6, aktywne biurko czytane ze SkyLight:
        //   sama strzalka z flaga Control       -> biurko [4] zostaje [4]
        //   Control jako zmiana flag + strzalka -> biurko [4] staje sie [3]
        // System rozpoznaje swoje skroty po STANIE modyfikatora, a nie po fladze
        // doklejonej do zdarzenia klawisza. Dopoki wysylalismy sam klawisz, kroki
        // szly w prozne, a dziennik notowal „przechodze skrotem o -2 kroki"
        // i zaraz potem nieudane przelaczenie.
        ustawControl(wcisniety: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            wyslij(klawisz: klawisz, pozostalo: abs(kroki)) {
                ustawControl(wcisniety: false)
                // Przejscie miedzy biurkami trwa u macOS niecala sekunde. Pytanie
                // o cokolwiek wczesniej dostaje odpowiedz sprzed przejscia.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: zakonczenie)
            }
        }
    }

    private static func ustawControl(wcisniety: Bool) {
        let zrodlo = CGEventSource(stateID: .combinedSessionState)
        guard let zdarzenie = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawiszControl,
                                      keyDown: wcisniety) else { return }
        zdarzenie.type = .flagsChanged
        zdarzenie.flags = wcisniety ? .maskControl : []
        Wklejanie.oznacz(zdarzenie)
        zdarzenie.post(tap: .cghidEventTap)
    }

    private static func wyslij(klawisz: CGKeyCode, pozostalo: Int, zakonczenie: @escaping () -> Void) {
        guard pozostalo > 0 else {
            zakonczenie()
            return
        }
        let zrodlo = CGEventSource(stateID: .combinedSessionState)
        guard let wcisniecie = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawisz, keyDown: true),
              let puszczenie = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawisz, keyDown: false) else {
            zakonczenie(); return
        }
        wcisniecie.flags = .maskControl
        puszczenie.flags = .maskControl
        Wklejanie.oznacz(wcisniecie)
        Wklejanie.oznacz(puszczenie)
        wcisniecie.post(tap: .cghidEventTap)
        puszczenie.post(tap: .cghidEventTap)
        // Przejscie miedzy biurkami trwa u macOS ok. 0,3 s. Szybsze ponowienie
        // zostaje polkniete i konczymy w polowie drogi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            wyslij(klawisz: klawisz, pozostalo: pozostalo - 1, zakonczenie: zakonczenie)
        }
    }
}

// MARK: - Systemowe skroty „Przelacz na Biurko N"
//
// Pomysl wlasciciela projektu, potwierdzony pomiarem 6 wrzesnia 2026 na macOS 26.6:
// macOS ma gotowe skroty Ctrl+1…Ctrl+9 „Przelacz na Biurko N" (Klawiatura → Skroty
// → Mission Control), domyslnie WYLACZONE. Po ich wlaczeniu wyslanie Ctrl+N
// (Control jako zdarzenie zmiany flag, potem cyfra) powoduje PRAWDZIWE przejscie
// systemu na wskazane biurko - z animacja, z Mission Control, bez zadnej prywatnej
// funkcji. Biurko 3 → 1 i z powrotem, za kazdym razem.
//
// To zwykle ustawienie systemu, nie zgoda - program wlacza je wtedy, gdy czlowiek
// wlacza u nas „Przelaczaj biurko przy wyborze okna", i mowi o tym w ustawieniach.
enum SkrotyBiurekSystemu {
    /// Identyfikatory w `com.apple.symbolichotkeys`: 118 = Biurko 1, 119 = Biurko 2, …
    private static let pierwszyIdentyfikator = 118
    /// Kody klawiszy cyfr 1…9 w gornym rzedzie (te same, co w `HotkeyRouter.digitKeys`).
    private static let kodyCyfr: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let modyfikatorControl = 262144
    private static let klawiszControl: CGKeyCode = 59

    /// Czy skrot dla danego numeru biurka jest wlaczony w systemie.
    static func wlaczony(numer: Int) -> Bool {
        guard numer >= 1, numer <= kodyCyfr.count else { return false }
        guard let wszystkie = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let wpis = wszystkie[String(pierwszyIdentyfikator + numer - 1)] as? [String: Any],
              let wlaczone = wpis["enabled"] as? Bool else { return false }
        return wlaczone
    }

    /// Wlacza skroty dla biurek 1…`ile` (najwyzej 9). Zmiana cudzego ustawienia
    /// systemowego - wolana wylacznie po decyzji czlowieka w ustawieniach.
    @discardableResult
    static func wlacz(ile: Int) -> Bool {
        let liczba = max(1, min(ile, kodyCyfr.count))
        var udalo = true
        for numer in 1...liczba where !wlaczony(numer: numer) {
            let identyfikator = pierwszyIdentyfikator + numer - 1
            let znak = 48 + numer   // kod znaku „1"…„9"
            let xml = """
            <dict><key>enabled</key><true/><key>value</key><dict>\
            <key>parameters</key><array><integer>\(znak)</integer>\
            <integer>\(kodyCyfr[numer - 1])</integer><integer>\(modyfikatorControl)</integer></array>\
            <key>type</key><string>standard</string></dict></dict>
            """
            let zapis = Process()
            zapis.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            zapis.arguments = ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys",
                               "-dict-add", String(identyfikator), xml]
            zapis.standardOutput = FileHandle.nullDevice
            zapis.standardError = FileHandle.nullDevice
            guard (try? zapis.run()) != nil else { udalo = false; continue }
            zapis.waitUntilExit()
            udalo = udalo && zapis.terminationStatus == 0
        }
        // Bez tego system czyta nowe skroty dopiero po ponownym zalogowaniu.
        let odswiez = Process()
        odswiez.executableURL = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        odswiez.arguments = ["-u"]
        odswiez.standardOutput = FileHandle.nullDevice
        odswiez.standardError = FileHandle.nullDevice
        try? odswiez.run()
        odswiez.waitUntilExit()
        DziennikBiurek.zapisz("skroty systemowe Ctrl+1…\(liczba) wlaczone: \(udalo ? "tak" : "CZESCIOWO")")
        return udalo
    }

    /// Prosi SYSTEM o przejscie na biurko o danym numerze (jak w Mission Control).
    /// `false`, gdy skrot dla tego numeru nie jest wlaczony - wtedy nic nie wysylamy.
    @discardableResult
    static func przejdzNaBiurko(numer: Int) -> Bool {
        guard numer >= 1, numer <= kodyCyfr.count, wlaczony(numer: numer) else { return false }
        let zrodlo = CGEventSource(stateID: .combinedSessionState)
        guard let controlDol = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawiszControl, keyDown: true),
              let controlGora = CGEvent(keyboardEventSource: zrodlo, virtualKey: klawiszControl, keyDown: false),
              let cyfraDol = CGEvent(keyboardEventSource: zrodlo, virtualKey: kodyCyfr[numer - 1], keyDown: true),
              let cyfraGora = CGEvent(keyboardEventSource: zrodlo, virtualKey: kodyCyfr[numer - 1], keyDown: false)
        else { return false }
        // Control MUSI isc jako zmiana flag - system rozpoznaje skroty po stanie
        // modyfikatora, nie po fladze doklejonej do klawisza (zmierzone: bez tego nic).
        controlDol.type = .flagsChanged; controlDol.flags = .maskControl
        controlGora.type = .flagsChanged; controlGora.flags = []
        cyfraDol.flags = .maskControl
        cyfraGora.flags = .maskControl
        for zdarzenie in [controlDol, cyfraDol, cyfraGora, controlGora] {
            Wklejanie.oznacz(zdarzenie)
        }
        controlDol.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cyfraDol.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                cyfraGora.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    controlGora.post(tap: .cghidEventTap)
                }
            }
        }
        DziennikBiurek.zapisz("prosba do systemu: Ctrl+\(numer) (Przelacz na Biurko \(numer))")
        return true
    }
}

// MARK: - Dziennik: FAKTY zamiast domyslow

/// Zapisuje, co naprawde dzieje sie przy przeskoku miedzy biurkami.
///
/// Powstal, bo szukanie przyczyny „nie przelacza biurka" opieralo sie na
/// domyslach: nie da sie zobaczyc z zewnatrz, czy prywatne funkcje systemu w ogole
/// odpowiadaja, jakie biurko system przypisuje oknu i czy przejscie nastapilo.
/// Kazda z tych rzeczy moze zawiesc osobno, a objaw jest ten sam.
///
/// Dziennik trzyma ostatnie 200 wpisow w pamieci i oddaje je na zadanie -
/// nic nie zapisujemy na dysk i nic nie wychodzi z komputera.
enum DziennikBiurek {
    private static let kolejka = DispatchQueue(label: "klyo.dziennik-biurek")
    private static var wpisy: [String] = []
    private static let limit = 200

    static func zapisz(_ tekst: String) {
        kolejka.async {
            let czas = Self.znacznik()
            let wiersz = "\(czas)  \(tekst)"
            wpisy.append(wiersz)
            if wpisy.count > limit { wpisy.removeFirst(wpisy.count - limit) }
            doPliku(wiersz)
        }
    }

    /// Ten sam wpis ląduje w pliku, nie tylko w pamięci.
    ///
    /// Dziennik trzymany wyłącznie w pamięci daje się przeczytać jednym sposobem:
    /// człowiek otwiera Ustawienia i klika „kopiuj". Znaczy to, że przy każdej
    /// próbie diagnozy ktoś musi siedzieć przy komputerze — a usterka bywa taka,
    /// że pokazuje się raz na dziesięć naciśnięć. Plik czyta się po fakcie.
    ///
    /// Zapis idzie tą samą kolejką co reszta dziennika, więc dwa wątki nie wejdą
    /// sobie w słowo, a `FileHandle` domykamy sami — plik zostaje spójny nawet,
    /// gdy program zniknie w połowie sesji.
    private static func doPliku(_ wiersz: String) {
        guard let plik = sciezkaPliku else { return }
        let dane = Data((wiersz + "\n").utf8)
        let menedzer = FileManager.default
        if !menedzer.fileExists(atPath: plik.path) {
            try? menedzer.createDirectory(at: plik.deletingLastPathComponent(),
                                          withIntermediateDirectories: true)
            menedzer.createFile(atPath: plik.path, contents: dane)
            return
        }
        // Obcinamy dziennik, zanim urośnie: przełącznika używa się setki razy
        // dziennie, więc plik bez granicy rósłby bez końca.
        let atrybuty = try? menedzer.attributesOfItem(atPath: plik.path)
        if let rozmiar = atrybuty?[.size] as? Int, rozmiar > 512 * 1024,
           let calosc = try? String(contentsOf: plik, encoding: .utf8) {
            let ogon = String(calosc.suffix(100_000))
            try? ogon.write(to: plik, atomically: true, encoding: .utf8)
        }
        guard let uchwyt = try? FileHandle(forWritingTo: plik) else { return }
        defer { try? uchwyt.close() }
        _ = try? uchwyt.seekToEnd()
        try? uchwyt.write(contentsOf: dane)
    }

    /// `~/Library/Logs/Klyo Switcher/dziennik.log` — miejsce, w które system sam
    /// zagląda przy zbieraniu diagnostyki i które widać w programie Konsola.
    static let sciezkaPliku: URL? = {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return logs.appendingPathComponent("Logs/Klyo Switcher/dziennik.log")
    }()

    static func tresc() -> String {
        kolejka.sync {
            let naglowek = """
            Klyo Switcher \(AppInfo.version) (build \(AppInfo.build))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

            Dostep do biurek (SkyLight):
              odczyt biurek:        \(SkyLight.canReadSpaces ? "TAK" : "NIE - to jest przyczyna")
              przenoszenie okien:   \(SkyLight.canBringWindows ? "TAK" : "NIE - to jest przyczyna")
              polaczenie z systemem: \(SkyLight.connection.map(String.init) ?? "BRAK")
              przywracanie biurka:  \(SkyLight.spaceSetFrontPSN != nil ? "TAK" : "NIE")

            Przelaczanie biurek w systemie: \(PrzelaczanieBiurek.wlaczone ? "wlaczone" : "WYLACZONE")

            Ostatnie zdarzenia:
            """
            return ([naglowek] + wpisy).joined(separator: "\n")
        }
    }

    /// Zdjecie stanu biurek w tej chwili - do wpisu w dzienniku.
    static func stanBiurek() -> String {
        let mapa = Spaces.map()
        guard mapa.isAvailable else { return "mapa biurek NIEDOSTEPNA (SkyLight nie odpowiada)" }
        let biezace = mapa.current.map(String.init).sorted().joined(separator: ", ")
        let numery = mapa.desktopNumbers.map { "\($0.key)=biurko \($0.value)" }.sorted().joined(separator: ", ")
        return "biezace: [\(biezace)] · znane biurka: [\(numery)] · pelnoekranowe: \(mapa.fullscreen.count)"
    }

    private static func znacznik() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
