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
        var desktopCounter = 0
        // Monitory przychodza w kolejnosci Mission Control, wiec numeracja biurek
        // rosnie tak samo, jak widzi ja uzytkownik na gornym pasku Mission Control.
        for display in displays {
            if let active = display["Current Space"] as? [String: Any], let identifier = spaceID(active) {
                current.insert(identifier)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let identifier = spaceID(space) else { continue }
                let type = (space["type"] as? NSNumber)?.intValue ?? desktopType
                if type == desktopType {
                    desktopCounter += 1
                    numbers[identifier] = desktopCounter
                } else {
                    fullscreen.insert(identifier)
                }
            }
        }
        return SpaceMap(current: current, desktopNumbers: numbers, fullscreen: fullscreen, isAvailable: !current.isEmpty)
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
        guard setFront(&psn, windowID, userGenerated) == 0 else { return false }

        // Dwa rekordy zdarzen (aktywacja okna i nadanie mu statusu "key") w ukladzie
        // bajtow znanym z Hammerspoon #370 i AltTab. Bez nich okno jest na wierzchu,
        // ale klawiatura dalej pisze do poprzedniego.
        for kind: UInt8 in [0x01, 0x02] {
            var record = [UInt8](repeating: 0, count: recordLength)
            record[0x04] = 0xF8
            record[0x08] = kind
            record[0x3A] = 0x10
            for offset in 0x20..<0x30 {
                record[offset] = 0xFF
            }
            withUnsafeBytes(of: windowID) { raw in
                for (index, byte) in raw.enumerated() {
                    record[0x3C + index] = byte
                }
            }
            record.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = post(&psn, base)
            }
        }
        return true
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
