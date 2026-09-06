import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Accessibility API helpers
//
// Stale atrybutow AX podajemy jako zwykle stringi zamiast makr CFSTR z naglowkow C,
// dzieki czemu kod kompiluje sie tym samym `swiftc` na kazdej wersji SDK.

enum AXKey {
    static let windows = "AXWindows"
    static let title = "AXTitle"
    static let subrole = "AXSubrole"
    static let minimized = "AXMinimized"
    static let main = "AXMain"
    static let mainWindow = "AXMainWindow"
    /// Ustawienie tego na `true` wystawia PROGRAM na wierzch. Bez tego kroku
    /// podniesienie pojedynczego okna nie robi nic, gdy program nie jest aktywny.
    static let frontmost = "AXFrontmost"
    static let focusedWindow = "AXFocusedWindow"
    static let raise = "AXRaise"
    static let standardWindow = "AXStandardWindow"
    static let dialog = "AXDialog"
    static let trustedPrompt = "AXTrustedCheckOptionPrompt"
}

@inline(__always)
func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

@inline(__always)
func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axCopy(element, attribute) as? String
}

@inline(__always)
func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    guard let raw = axCopy(element, attribute) else { return nil }
    return (raw as? NSNumber)?.boolValue
}

@inline(__always)
func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
    axCopy(element, attribute) as? [AXUIElement]
}

/// Pojedynczy element AX (np. okno z fokusem). Typ sprawdzamy identyfikatorem
/// CoreFoundation, bo `as?` na typach CF potrafi zwrocic nil mimo poprawnej wartosci.
@inline(__always)
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopy(element, attribute) else { return nil }
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Prywatne `_AXUIElementGetWindow` mapuje okno AX na `CGWindowID`.
/// Pobierane przez `dlsym`, wiec brak symbolu nie wywala linkera ani aplikacji.
let axWindowIDFunction: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

@inline(__always)
func axWindowID(_ window: AXUIElement) -> CGWindowID {
    guard let function = axWindowIDFunction else { return 0 }
    var identifier: CGWindowID = 0
    guard function(window, &identifier) == .success else { return 0 }
    return identifier
}

/// `CGWindowListCreateImage` jest oznaczone jako deprecated od macOS 14, ale nadal
/// dziala i jest jedynym synchronicznym zrodlem miniatur. Wolamy je przez wskaznik,
/// zeby build byl w 100% wolny od ostrzezen.
let cgWindowListCreateImageFunction: (@convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?)? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?).self)
}()

enum Permissions {
    /// Czy zgoda Dostepnosci kiedykolwiek dzialala na tym komputerze.
    ///
    /// Sluzy do rozpoznania sytuacji, ktora doprowadza uzytkownikow do rozpaczy:
    /// w Ustawieniach ptaszek JEST, a program nie dziala. Sam brak zgody wyglada
    /// tak samo jak zgoda przypisana do starej kopii programu - roznica jest
    /// tylko w historii. Jesli zgoda kiedys dzialala, a teraz nie, to prawie na
    /// pewno wpis w systemie zostal po poprzedniej kopii i trzeba go odswiezyc,
    /// a nie „wlaczyc jeszcze raz" (to ostatnie nie pomaga i tylko frustruje).
    static var zgodaKiedysDzialala: Bool {
        get { UserDefaults.standard.bool(forKey: "zgodaKiedysDzialala") }
        set { UserDefaults.standard.set(newValue, forKey: "zgodaKiedysDzialala") }
    }

    /// Zgoda zaznaczona, a program i tak bez dostepu.
    static var zgodaMartwa: Bool {
        !accessibilityGranted && zgodaKiedysDzialala
    }

    /// Usuwa systemowy wpis zgody dla TEGO programu, zeby macOS zapytal o nia
    /// od nowa i zwiazal ja z aktualna kopia.
    ///
    /// Alternatywa jest kazanie czlowiekowi odszukac program na liscie, kliknac
    /// minus, potem plus i wskazac plik - czyli kilkanascie klikniec w miejscu,
    /// ktorego wiekszosc ludzi nie zna. `tccutil` robi dokladnie to samo jednym
    /// ruchem i nie wymaga hasla administratora, bo dotyczy wylacznie nas.
    /// Czy mamy zgode na sterowanie INNYM programem (Automatyzacja).
    ///
    /// Do tej pory wnioskowalismy o tym po tym, czy udalo sie pobrac karty
    /// przegladarki - a to zupelnie co innego. Brak kart znaczy najczesciej
    /// tyle, ze zadna przegladarka nie jest otwarta albo dziala tryb „tylko
    /// okna". Program pokazywal wtedy „wylaczona" przy zgodzie, ktora czlowiek
    /// mial WLACZONA w Ustawieniach - i slusznie sie zloscil.
    ///
    /// macOS ma na to osobne pytanie systemowe. `askUserIfNeeded: false` znaczy:
    /// SPRAWDZ stan, ale nie wyswietlaj okna z pytaniem - inaczej samo otwarcie
    /// listy zgod zasypywaloby czlowieka pytaniami o kazda przegladarke.
    static func automatyzacjaNadana(dla identyfikator: String) -> Bool {
        var cel = AEAddressDesc()
        var bajty = Array(identyfikator.utf8)
        let wynik = AECreateDesc(typeApplicationBundleID, &bajty, bajty.count, &cel)
        guard wynik == noErr else { return false }
        defer { AEDisposeDesc(&cel) }
        return AEDeterminePermissionToAutomateTarget(&cel, typeWildCard, typeWildCard, false) == noErr
    }

    /// Czy zgoda na Automatyzacje jest nadana dla KTOREJKOLWIEK z przegladarek,
    /// ktore program potrafi obsluzyc. Wystarczy jedna: to znaczy, ze czlowiek
    /// przeszedl przez pytanie systemu i zgode wlaczyl.
    static var automatyzacjaNadanaDlaJakiejsPrzegladarki: Bool {
        let przegladarki = [
            "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
            "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
        ]
        return przegladarki.contains { automatyzacjaNadana(dla: $0) }
    }

    /// Usuwa systemowy wpis zgody na NAGRYWANIE EKRANU dla tego programu.
    ///
    /// To osobna sprawa niz Dostepnosc: macOS trzyma te zgody w osobnych rejestrach.
    /// Wpis potrafi utknac w stanie „jest, ale nie dziala" - zwlaszcza gdy program
    /// byl wczesniej uruchamiany z katalogu tymczasowego albo jako inna kopia.
    /// Przelacznik daje sie wtedy przesuwac, ale nie zostaje wlaczony. Po usunieciu
    /// wpisu system pyta od nowa i wiaze zgode z kopia, ktora naprawde dziala.
    @discardableResult
    static func naprawZgodeNagrywania() -> Bool {
        guard let identyfikator = Bundle.main.bundleIdentifier else { return false }
        let proces = Process()
        proces.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proces.arguments = ["reset", "ScreenCapture", identyfikator]
        proces.standardOutput = FileHandle.nullDevice
        proces.standardError = FileHandle.nullDevice
        guard (try? proces.run()) != nil else { return false }
        proces.waitUntilExit()
        return proces.terminationStatus == 0
    }

    @discardableResult
    static func naprawZgode() -> Bool {
        guard let identyfikator = Bundle.main.bundleIdentifier else { return false }
        let proces = Process()
        proces.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proces.arguments = ["reset", "Accessibility", identyfikator]
        proces.standardOutput = FileHandle.nullDevice
        proces.standardError = FileHandle.nullDevice
        guard (try? proces.run()) != nil else { return false }
        proces.waitUntilExit()
        guard proces.terminationStatus == 0 else { return false }
        zgodaKiedysDzialala = false
        return true
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [AXKey.trustedPrompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Ponowne uruchomienie programu z tej samej sciezki.
    ///
    /// Zgoda Nagrywania ekranu obowiazuje dopiero nowy proces - dzialajacy nadal
    /// nie ma dostepu, choc przelacznik w Ustawieniach jest wlaczony. Zamiast
    /// kazac czlowiekowi zamykac i otwierac program recznie, robimy to za niego.
    /// Czy po ponownym uruchomieniu wrocic do okna zgod.
    ///
    /// Program restartuje sie po to, zeby zgoda zaczela obowiazywac - wiec zaraz
    /// po starcie czlowiek chce zobaczyc, CZY ZADZIALALO. Bez tego znacznika
    /// program wracal w milczeniu i trzeba bylo szukac okna w menu.
    static var wrocDoOknaZgod: Bool {
        get { UserDefaults.standard.bool(forKey: "wrocDoOknaZgod") }
        set { UserDefaults.standard.set(newValue, forKey: "wrocDoOknaZgod") }
    }

    static func uruchomPonownie() {
        wrocDoOknaZgod = true
        // Nowa kopia programu musi wystartowac PO tym, jak ta sie zamknie.
        //
        // Proba uruchomienia drugiej kopii, gdy pierwsza jeszcze zyje, konczy sie
        // niczym: macOS uznaje, ze program juz dziala, a nasz wlasny bezpiecznik
        // przed podwojnym uruchomieniem zamyka przybysza. Efekt jest taki, jaki
        // zglosil uzytkownik: „uruchom ponownie i nie otwiera sie od nowa".
        //
        // Dlatego start zleca sie osobnemu poleceniu powloki, ktore przezyje nasze
        // zamkniecie: czeka, az proces zniknie, i dopiero wtedy otwiera program.
        // Sciezke przekazujemy jako ARGUMENT skryptu, nie wklejamy jej w tresc.
        // Wklejanie wymagaloby cytowania, a kazdy blad w cytowaniu apostrofu albo
        // spacji w nazwie katalogu konczy sie poleceniem, ktore robi cos innego,
        // niz mysleliśmy. Argument jest odporny na wszystkie znaki.
        let skrypt = """
        for i in 1 2 3 4 5 6 7 8 9 10; do
          /usr/bin/pgrep -x KlyoSwitcher >/dev/null 2>&1 || break
          sleep 1
        done
        /usr/bin/open -n "$1"
        """
        let proces = Process()
        proces.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proces.arguments = ["/bin/bash", "-c", skrypt, "klyo-restart", Bundle.main.bundlePath]
        proces.standardOutput = FileHandle.nullDevice
        proces.standardError = FileHandle.nullDevice
        try? proces.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    /// Stan zgody na automatyzowanie KONKRETNEGO programu - bez budzenia pytania.
    ///
    /// `AEDeterminePermissionToAutomateTarget` z `askUserIfNeeded: false` odpowiada
    /// od reki. Poprzednia wersja pisala „nie wiadomo", bo zalozylismy, ze systemu
    /// nie da sie o to zapytac po cichu - da sie, i to jest jedyna droga, zeby
    /// powiedziec czlowiekowi prawde zamiast kazac mu zgadywac, czemu karty
    /// przegladarki sie nie pokazuja.
    enum StanAutomatyzacji {
        case nadana
        case odmowa
        case niePytano
        case nieDziala
        case blad(OSStatus)
    }

    static func automatyzacja(bundleID: String) -> StanAutomatyzacji {
        var cel = AEAddressDesc()
        let bajty = Array(bundleID.utf8)
        let utworzenie = AECreateDesc(typeApplicationBundleID, bajty, bajty.count, &cel)
        // `AECreateDesc` oddaje `OSErr` (16 bitow), a reszta swiata `OSStatus`
        // (32 bity) - stad przeliczenie, inaczej kompilator odmawia.
        guard utworzenie == noErr else { return .blad(OSStatus(utworzenie)) }
        defer { AEDisposeDesc(&cel) }
        let wynik = AEDeterminePermissionToAutomateTarget(&cel, typeWildCard, typeWildCard, false)
        if wynik == noErr { return .nadana }
        if wynik == OSStatus(errAEEventNotPermitted) { return .odmowa }
        if wynik == OSStatus(errAEEventWouldRequireUserConsent) { return .niePytano }
        if wynik == OSStatus(procNotFound) { return .nieDziala }
        return .blad(wynik)
    }

    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAutomationSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Skroty klawiszowe

/// Kombinacja klawiszy zapisywalna w ustawieniach. Modyfikatory trzymamy jako surowe
/// bity `CGEventFlags`, bo dokladnie w tej postaci przychodza ze zdarzen systemowych.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int64
    var modifiers: UInt64

    static let unset = KeyCombo(keyCode: -1, modifiers: 0)

    /// Tylko klawisze, ktore realnie tworza skrot - reszta bitow (Caps Lock, numpad,
    /// funkcja) zmienia sie samoistnie i psulaby porownania.
    static let significantMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue

    var isSet: Bool { keyCode >= 0 && (modifiers & KeyCombo.significantMask) != 0 }

    var normalizedModifiers: UInt64 { modifiers & KeyCombo.significantMask }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isSet, keyCode == self.keyCode else { return false }
        return flags.rawValue & KeyCombo.significantMask == normalizedModifiers
    }

    var display: String {
        guard isSet else { return "brak" }
        var text = ""
        if normalizedModifiers & CGEventFlags.maskControl.rawValue != 0 { text += "⌃" }
        if normalizedModifiers & CGEventFlags.maskAlternate.rawValue != 0 { text += "⌥" }
        if normalizedModifiers & CGEventFlags.maskShift.rawValue != 0 { text += "⇧" }
        if normalizedModifiers & CGEventFlags.maskCommand.rawValue != 0 { text += "⌘" }
        return text + KeyNames.name(for: keyCode)
    }
}

enum KeyNames {
    private static let table: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`", 48: "⇥", 49: "Spacja", 36: "↩", 51: "⌫", 53: "esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    static func name(for keyCode: Int64) -> String {
        table[keyCode] ?? "klawisz \(keyCode)"
    }
}

// MARK: - Skrot uruchamiajacy aplikacje

struct AppShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var combo: KeyCombo
    var bundleID: String
    var name: String

    init(id: UUID = UUID(), combo: KeyCombo, bundleID: String, name: String) {
        self.id = id
        self.combo = combo
        self.bundleID = bundleID
        self.name = name
    }
}

// MARK: - Tryby

enum BrowserMode: String, CaseIterable {
    /// Jedna pozycja na okno przegladarki, podpisana tytulem aktywnej karty.
    case windowsOnly
    /// Okno + wszystkie jego karty jako osobne pozycje.
    case allTabs
    /// Okno + tylko ostatnio uzywane karty (limit z ustawien).
    case recentTabs

    var label: String {
        switch self {
        case .windowsOnly: return "Tylko okna przeglądarki"
        case .allTabs: return "Okna i wszystkie karty"
        case .recentTabs: return "Okna i ostatnio używane karty"
        }
    }

    var usesTabs: Bool { self != .windowsOnly }
}

enum SpacesMode: String, CaseIterable {
    /// Okna ze wszystkich biurek; wybor okna z innego biurka przelacza biurko.
    case allDesktops
    /// Tylko okna z biurka, na ktore uzytkownik patrzy (jak domyslny Alt+Tab w Windows 11).
    case currentDesktop

    var label: String {
        switch self {
        case .allDesktops: return "Wszystkie biurka — wybór okna przełącza biurko"
        case .currentDesktop: return "Tylko bieżące biurko"
        }
    }
}

enum ScreenshotFormat: String, CaseIterable {
    case jpeg
    case heic

    var label: String {
        switch self {
        case .jpeg: return "JPEG (uniwersalny)"
        case .heic: return "HEIC (mniejszy, nowsze aplikacje)"
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    var uti: String { self == .jpeg ? "public.jpeg" : "public.heic" }
}

// MARK: - Ustawienia

enum HotkeyModifier: String, CaseIterable {
    case command
    case option

    var eventFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let modifier = "hotkeyModifier"
        static let browserMode = "browserMode"
        static let spacesMode = "spacesMode"
        static let tabLimit = "tabLimitPerWindow"
        static let thumbnails = "showThumbnails"
        static let launchAtLogin = "launchAtLogin"
        static let didBootstrap = "didBootstrapLoginItem"
        static let screenshotEnabled = "screenshotEnabled"
        static let screenshotCombo = "screenshotCombo"
        static let screenshotMaxKB = "screenshotMaxKB"
        static let screenshotMaxPixels = "screenshotMaxPixels"
        static let screenshotFormat = "screenshotFormat"
        static let screenshotSaveToDisk = "screenshotSaveToDisk"
        static let screenshotFolder = "screenshotFolder"
        static let appShortcuts = "appShortcuts"
        static let historiaSchowka = "historiaSchowkaWlaczona"
        static let limitHistorii = "limitHistoriiSchowka"
        static let skrotSchowka = "skrotHistoriiSchowka"
        static let skrotCzystegoTekstu = "skrotCzystegoTekstu"
        static let wklejajCzysty = "wklejajCzystyTekst"
        static let wklejajPrzycinaj = "wklejajPrzycinajSpacje"
        static let wklejajBezDoczepek = "wklejajBezDoczepek"
        static let updateFeed = "updateFeedURL"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.modifier: HotkeyModifier.command.rawValue,
            Key.browserMode: BrowserMode.windowsOnly.rawValue,
            Key.spacesMode: SpacesMode.allDesktops.rawValue,
            Key.tabLimit: 6,
            Key.thumbnails: true,
            Key.launchAtLogin: true,
            Key.didBootstrap: false,
            Key.screenshotEnabled: true,
            Key.screenshotMaxKB: 1200,
            Key.screenshotMaxPixels: 2400,
            Key.screenshotFormat: ScreenshotFormat.jpeg.rawValue,
            Key.screenshotSaveToDisk: true,
            Key.autoCheckUpdates: true,
            Key.historiaSchowka: true,
            Key.limitHistorii: 200,
            Key.updateFeed: "https://klyo.pl/klyo-switcher/appcast.json"
        ])
    }

    static var modifier: HotkeyModifier {
        get { HotkeyModifier(rawValue: defaults.string(forKey: Key.modifier) ?? "") ?? .command }
        set { defaults.set(newValue.rawValue, forKey: Key.modifier) }
    }

    static var browserMode: BrowserMode {
        get { BrowserMode(rawValue: defaults.string(forKey: Key.browserMode) ?? "") ?? .windowsOnly }
        set { defaults.set(newValue.rawValue, forKey: Key.browserMode) }
    }

    static var spacesMode: SpacesMode {
        get { SpacesMode(rawValue: defaults.string(forKey: Key.spacesMode) ?? "") ?? .allDesktops }
        set { defaults.set(newValue.rawValue, forKey: Key.spacesMode) }
    }

    static var tabLimitPerWindow: Int {
        get { max(1, defaults.integer(forKey: Key.tabLimit)) }
        set { defaults.set(max(1, newValue), forKey: Key.tabLimit) }
    }

    static var showThumbnails: Bool {
        get { defaults.bool(forKey: Key.thumbnails) }
        set { defaults.set(newValue, forKey: Key.thumbnails) }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    static var didBootstrapLoginItem: Bool {
        get { defaults.bool(forKey: Key.didBootstrap) }
        set { defaults.set(newValue, forKey: Key.didBootstrap) }
    }

    static var screenshotEnabled: Bool {
        get { defaults.bool(forKey: Key.screenshotEnabled) }
        set { defaults.set(newValue, forKey: Key.screenshotEnabled) }
    }

    /// Domyslnie ⌥⇧4 - obok systemowego ⌘⇧4, wiec latwo zapamietac.
    static var screenshotCombo: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.screenshotCombo),
                  let combo = try? PropertyListDecoder().decode(KeyCombo.self, from: data) else {
                return KeyCombo(
                    keyCode: 21,
                    modifiers: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
                )
            }
            return combo
        }
        set {
            guard let data = try? PropertyListEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.screenshotCombo)
        }
    }

    static var screenshotMaxKB: Int {
        get { max(100, defaults.integer(forKey: Key.screenshotMaxKB)) }
        set { defaults.set(max(100, newValue), forKey: Key.screenshotMaxKB) }
    }

    static var screenshotMaxPixels: Int {
        get { max(600, defaults.integer(forKey: Key.screenshotMaxPixels)) }
        set { defaults.set(max(600, newValue), forKey: Key.screenshotMaxPixels) }
    }

    static var screenshotFormat: ScreenshotFormat {
        get { ScreenshotFormat(rawValue: defaults.string(forKey: Key.screenshotFormat) ?? "") ?? .jpeg }
        set { defaults.set(newValue.rawValue, forKey: Key.screenshotFormat) }
    }

    static var screenshotSaveToDisk: Bool {
        get { defaults.bool(forKey: Key.screenshotSaveToDisk) }
        set { defaults.set(newValue, forKey: Key.screenshotSaveToDisk) }
    }

    static var screenshotFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.screenshotFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        }
        set { defaults.set(newValue.path, forKey: Key.screenshotFolder) }
    }

    static var historiaSchowkaWlaczona: Bool {
        get { defaults.bool(forKey: Key.historiaSchowka) }
        set { defaults.set(newValue, forKey: Key.historiaSchowka) }
    }

    /// Wlasna mechanika przechodzenia miedzy biurkami (skok prywatna funkcja
    /// WindowServera i udawane Ctrl+strzalki). DOMYSLNIE WYLACZONA - biurkami
    /// zarzadza system, a naszym interfejsem jest ⌘ Tab i nic wiecej. Zostaje
    /// jako ukryta furtka, gdyby kiedys byla potrzebna swiadomie:
    /// `defaults write pl.klyo.switcher wlasnaMechanikaBiurek -bool YES`
    static var wlasnaMechanikaBiurek: Bool {
        defaults.bool(forKey: "wlasnaMechanikaBiurek")
    }

    /// Wklejanie pod ⌘V bez formatowania. Domyslnie WYLACZONE - to zmiana
    /// zachowania klawisza, ktorego uzywa sie setki razy dziennie, wiec musi byc
    /// swiadomym wyborem, a nie niespodzianka po aktualizacji.
    static var wklejajCzystyTekst: Bool {
        get { defaults.bool(forKey: Key.wklejajCzysty) }
        set { defaults.set(newValue, forKey: Key.wklejajCzysty) }
    }

    static var wklejajPrzycinaj: Bool {
        get { defaults.bool(forKey: Key.wklejajPrzycinaj) }
        set { defaults.set(newValue, forKey: Key.wklejajPrzycinaj) }
    }

    static var wklejajBezDoczepek: Bool {
        get { defaults.bool(forKey: Key.wklejajBezDoczepek) }
        set { defaults.set(newValue, forKey: Key.wklejajBezDoczepek) }
    }

    static var limitHistoriiSchowka: Int {
        get { max(20, defaults.integer(forKey: Key.limitHistorii)) }
        set { defaults.set(max(20, newValue), forKey: Key.limitHistorii) }
    }

    /// Domyslnie ⌘⇧V - obok systemowego wklejania, wiec latwo zapamietac.
    static var skrotHistoriiSchowka: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.skrotSchowka),
                  let combo = try? PropertyListDecoder().decode(KeyCombo.self, from: data) else {
                return KeyCombo(
                    keyCode: 9,
                    modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
                )
            }
            return combo
        }
        set {
            guard let data = try? PropertyListEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.skrotSchowka)
        }
    }

    /// Domyslnie ⌥⇧⌘V - odpowiednik systemowego „wklej i dopasuj styl", ale dziala
    /// w KAZDYM programie, nie tylko w tych, ktore ten skrot obsluguja.
    static var skrotCzystegoTekstu: KeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.skrotCzystegoTekstu),
                  let combo = try? PropertyListDecoder().decode(KeyCombo.self, from: data) else {
                return KeyCombo(
                    keyCode: 9,
                    modifiers: CGEventFlags.maskCommand.rawValue
                        | CGEventFlags.maskShift.rawValue
                        | CGEventFlags.maskAlternate.rawValue
                )
            }
            return combo
        }
        set {
            guard let data = try? PropertyListEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.skrotCzystegoTekstu)
        }
    }

    static var appShortcuts: [AppShortcut] {
        get {
            guard let data = defaults.data(forKey: Key.appShortcuts),
                  let list = try? PropertyListDecoder().decode([AppShortcut].self, from: data) else { return [] }
            return list
        }
        set {
            guard let data = try? PropertyListEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.appShortcuts)
        }
    }

    static var updateFeedURL: String {
        get { defaults.string(forKey: Key.updateFeed) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.updateFeed) }
    }

    static var autoCheckUpdates: Bool {
        get { defaults.bool(forKey: Key.autoCheckUpdates) }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }
}

/// Jeden strumien powiadomien o zmianie ustawien - kazdy modul sluchajacy przelicza
/// swoje rzeczy dokladnie raz, bez odpytywania.
extension Notification.Name {
    static let klyoSettingsChanged = Notification.Name("pl.klyo.switcher.settingsChanged")
}

enum SettingsBus {
    static func announce() {
        NotificationCenter.default.post(name: .klyoSettingsChanged, object: nil)
    }
}

// MARK: - Wersja

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }

    static let name = "Klyo Switcher"
}

// MARK: - Autostart

enum LoginItem {
    private static let agentLabel = "pl.klyo.switcher.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // SMAppService zadzialalo - kasujemy zapasowy LaunchAgent, zeby aplikacja
            // nie wystartowala dwa razy przy logowaniu.
            removeAgent()
            return
        } catch {
            // Aplikacja podpisana lokalnie (ad-hoc) bywa odrzucana przez SMAppService.
            // Wtedy uzywamy klasycznego LaunchAgenta w katalogu uzytkownika.
        }
        if enabled {
            writeAgent()
        } else {
            removeAgent()
        }
    }

    private static func writeAgent() {
        let executablePath = Bundle.main.bundlePath + "/Contents/MacOS/KlyoSwitcher"
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let directory = agentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }
}

// MARK: - Tlo HUD

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.state = .active
    }
}


extension Notification.Name {
    /// Prosba o przeniesienie programu do katalogu Programy.
    ///
    /// Wysyla ja okno aktualizacji, gdy program stoi w katalogu tymczasowym:
    /// aktualizacja nie ma tam gdzie zapisac, wiec zanim cokolwiek pobierzemy,
    /// trzeba stanac we wlasciwym miejscu.
    static let klyoPrzeniesDoProgramow = Notification.Name("klyo.przenies-do-programow")
}
