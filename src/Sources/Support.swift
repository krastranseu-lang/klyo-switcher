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
