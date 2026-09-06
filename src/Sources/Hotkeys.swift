import AppKit
import CoreGraphics

enum ArrowDirection {
    case left
    case right
    case up
    case down
}

/// Globalny podsluch klawiatury na poziomie HID. Wpiety na poczatku lancucha zdarzen,
/// dzieki czemu przechwytuje ⌘+Tab zanim zobaczy je Dock i pokaze systemowy przelacznik.
/// Jeden tap obsluguje wszystkie skroty aplikacji - przelacznik, zrzut ekranu
/// i skroty do aplikacji - zeby system nie musial utrzymywac kilku podsluchow.
///
/// Niezmiennik: callback podsluchu wraca w mikrosekundach. System wylacza podsluch,
/// ktory nie odpowiada na czas (`tapDisabledByTimeout`), a wtedy ginie zwolnienie
/// modyfikatora - dlatego zadna praca (spis okien, rozmowa z aplikacja) nie dzieje sie
/// tutaj, tylko w kontrolerze, po powrocie z callbacku.
final class HotkeyRouter {
    enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let arrowLeft: Int64 = 123
        static let arrowRight: Int64 = 124
        static let arrowUp: Int64 = 126
        static let arrowDown: Int64 = 125
        static let backtick: Int64 = 50
        static let w: Int64 = 13
        static let q: Int64 = 12
        static let backspace: Int64 = 51
        static let v: Int64 = 9
    }

    /// Klawisze 1…9 w gornym rzedzie - skok do pozycji na liscie.
    private static let digitKeys: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]

    /// Litera dopisana do szukanej frazy podczas otwartej listy.
    var onSzukaj: ((String) -> Void)?
    /// Skasowanie ostatniego znaku frazy (klawisz cofania).
    var onKasujZnak: (() -> Void)?
    var onCycle: ((Bool) -> Void)?
    var onArrow: ((ArrowDirection) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onHistoriaSchowka: (() -> Void)?
    var onCzystyTekst: (() -> Void)?
    /// Zwykle ⌘V, gdy uzytkownik wlaczyl przerabianie wklejanej tresci.
    var onWklejenie: (() -> Void)?
    /// Przepustka dla NASZEGO wlasnego ⌘V wysylanego po przerobieniu schowka -
    /// bez niej podsluch przechwycilby je jeszcze raz i program krecilby sie w kolko.
    var pomijamWklejenie = false
    var onAppShortcut: ((AppShortcut) -> Void)?
    var onCloseSelected: (() -> Void)?
    /// `true` = wymuszone zakonczenie (⌥ razem z Q) - dla aplikacji, ktora nie odpowiada.
    var onQuitSelected: ((Bool) -> Void)?
    var onPermissionGranted: (() -> Void)?
    /// Zgoda widnieje w Ustawieniach, ale system jej NIE honoruje. Tak dzieje sie
    /// po podmianie programu na wersje z innym podpisem: wpis w Ustawieniach
    /// zostaje przypisany do starej tozsamosci, a nowy program go nie dziedziczy.
    /// Bez tego sygnalu program wyglada na zepsuty: ikona jest, zgoda „jest",
    /// a ⌘ Tab dalej otwiera systemowy przelacznik.
    var onZgodaNieDziala: (() -> Void)?
    var isSessionActive: () -> Bool = { false }

    /// Wstrzymanie na czas nagrywania nowego skrotu w oknie ustawien -
    /// inaczej pierwszy wcisniety skrot od razu by sie wykonal.
    var isSuspended = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private(set) var isInstalled = false

    private var switcherModifier: CGEventFlags = Settings.modifier.eventFlag
    private var screenshotCombo: KeyCombo = .unset
    private var screenshotEnabled = false
    private var schowekCombo: KeyCombo = .unset
    private var schowekEnabled = false
    private var czystyTekstCombo: KeyCombo = .unset
    private var wklejanieWlaczone = false
    private var appShortcuts: [AppShortcut] = []

    init() {
        reloadSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .klyoSettingsChanged,
            object: nil
        )
    }

    deinit {
        uninstall()
    }

    @objc private func settingsChanged() {
        reloadSettings()
    }

    /// Ustawienia sa czytane raz przy zmianie i trzymane w polach - sciezka gorąca
    /// nie dotyka `UserDefaults` ani razu.
    private func reloadSettings() {
        switcherModifier = Settings.modifier.eventFlag
        screenshotCombo = Settings.screenshotCombo
        screenshotEnabled = Settings.screenshotEnabled
        schowekCombo = Settings.skrotHistoriiSchowka
        schowekEnabled = Settings.historiaSchowkaWlaczona
        czystyTekstCombo = Settings.skrotCzystegoTekstu
        wklejanieWlaczone = Wklejanie.wlaczone
        appShortcuts = Settings.appShortcuts.filter { $0.combo.isSet }
    }

    /// Fizyczny stan klawiatury wprost z systemu - prawda, a nie ostatnie zdarzenie,
    /// ktore mogloby zginac.
    var isSwitcherModifierHeld: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(switcherModifier)
    }

    // MARK: - Instalacja

    /// Probuje wpiac tap. Jesli brakuje zgody "Dostepnosc", czeka na systemowe
    /// rozgloszenie o zmianie zgod i wpina sie automatycznie - bez restartu aplikacji.
    func install() {
        guard !isInstalled else { return }
        guard Permissions.accessibilityGranted else {
            startPermissionWatch()
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let router = Unmanaged<HotkeyRouter>.fromOpaque(refcon).takeUnretainedValue()
            return router.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Zgoda jest nadana (sprawdzone wyzej), a mimo to system nie pozwala
            // podsluchiwac klawiatury. To NIE jest brak zgody - to zgoda martwa.
            onZgodaNieDziala?()
            startPermissionWatch()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        isInstalled = true
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func uninstall() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isInstalled = false
    }

    private func startPermissionWatch() {
        guard permissionTimer == nil else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityDatabaseChanged),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard Permissions.accessibilityGranted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.install()
            self.onPermissionGranted?()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    @objc private func accessibilityDatabaseChanged() {
        // Rozgloszenie przychodzi chwile przed aktualizacja bazy zaufania.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, Permissions.accessibilityGranted else { return }
            DistributedNotificationCenter.default().removeObserver(self)
            self.install()
            self.onPermissionGranted?()
        }
    }

    // MARK: - Sciezka goraca

    /// Wywolywana dla kazdego zdarzenia klawiatury w systemie, wiec typowy przypadek
    /// (zwykle pisanie) konczy sie na dwoch porownaniach i zwrocie wskaznika.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isSuspended { return Unmanaged.passUnretained(event) }
        // Wlasnych zdarzen nie przechwytujemy NIGDY. Program wysyla ⌘V (po
        // przerobieniu tresci i po wybraniu wpisu z historii) oraz Ctrl+strzalki
        // (przejscie na inne biurko) - gdyby wracaly do nas jako cudze, zamknelyby
        // sie w petli albo, przy otwartej liscie, zostaly wziete za ruch wyboru.
        if Wklejanie.nasze(event) { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            if (keyCode == Key.tab || keyCode == Key.backtick),
               flags.contains(switcherModifier),
               !flags.contains(.maskControl) {
                onCycle?(!flags.contains(.maskShift))
                return nil
            }

            if isSessionActive() {
                switch keyCode {
                case Key.escape:
                    onCancel?()
                    return nil
                case Key.arrowRight:
                    onArrow?(.right)
                    return nil
                case Key.arrowLeft:
                    onArrow?(.left)
                    return nil
                case Key.arrowDown:
                    onArrow?(.down)
                    return nil
                case Key.arrowUp:
                    onArrow?(.up)
                    return nil
                case Key.returnKey, Key.keypadEnter:
                    onCommit?()
                    return nil
                case Key.w:
                    guard flags.contains(switcherModifier) else { return Unmanaged.passUnretained(event) }
                    onCloseSelected?()
                    return nil
                case Key.q:
                    guard flags.contains(switcherModifier) else { return Unmanaged.passUnretained(event) }
                    onQuitSelected?(flags.contains(.maskAlternate))
                    return nil
                case Key.backspace:
                    onKasujZnak?()
                    return nil
                default:
                    if flags.contains(switcherModifier), let digit = HotkeyRouter.digitKeys[keyCode] {
                        onSelectIndex?(digit - 1)
                        return nil
                    }
                    // Wszystko inne, co ma czytelny znak, dopisuje sie do szukanej frazy.
                    // Uzytkownik trzyma modyfikator, wiec system i tak nie dostalby tych
                    // klawiszy do niczego pozytecznego, a pisanie jest najszybszym sposobem
                    // znalezienia jednego okna wsrod trzydziestu.
                    if !flags.contains(.maskControl),
                       let znak = event.znakBezModyfikatorow(), !znak.isEmpty {
                        onSzukaj?(znak)
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
            }

            // Skroty jednorazowe sprawdzamy dopiero, gdy zdarzenie ma jakikolwiek
            // modyfikator - to odsiewa cale zwykle pisanie jednym testem bitowym.
            guard flags.rawValue & KeyCombo.significantMask != 0 else {
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return Unmanaged.passUnretained(event)
            }

            // ⌘V samo, bez innych modyfikatorow. Sprawdzane po jednym porownaniu
            // logicznym, wiec gdy przerabianie jest wylaczone (domyslnie), kosztuje tyle,
            // co nic. Wlasne, ponownie wyslane ⌘V przepuszczamy bez zmian.
            if wklejanieWlaczone, keyCode == Key.v, flags.contains(.maskCommand),
               !flags.contains(.maskShift), !flags.contains(.maskAlternate),
               !flags.contains(.maskControl) {
                if pomijamWklejenie || Wklejanie.nasze(event) { return Unmanaged.passUnretained(event) }
                onWklejenie?()
                return nil
            }

            if screenshotEnabled, screenshotCombo.matches(keyCode: keyCode, flags: flags) {
                onScreenshot?()
                return nil
            }

            if schowekEnabled, schowekCombo.matches(keyCode: keyCode, flags: flags) {
                onHistoriaSchowka?()
                return nil
            }

            if czystyTekstCombo.matches(keyCode: keyCode, flags: flags) {
                onCzystyTekst?()
                return nil
            }

            for shortcut in appShortcuts where shortcut.combo.matches(keyCode: keyCode, flags: flags) {
                onAppShortcut?(shortcut)
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            guard isSessionActive() else { return Unmanaged.passUnretained(event) }
            if !event.flags.contains(switcherModifier) {
                onCommit?()
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if (keyCode == Key.tab || keyCode == Key.backtick), isSessionActive() {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }
    }
}

extension CGEvent {
    /// Znak, ktory ten klawisz dalby BEZ wcisnietych modyfikatorow. Dzieki temu
    /// „⌘ + S" podczas otwartej listy dopisuje do frazy litere „s", a nie znak
    /// sterujacy, i dziala tak samo na kazdym ukladzie klawiatury.
    func znakBezModyfikatorow() -> String? {
        var dlugosc = 0
        var bufor = [UniChar](repeating: 0, count: 4)
        let kopia = self.copy()
        kopia?.flags = []
        kopia?.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &dlugosc, unicodeString: &bufor)
        guard dlugosc > 0 else { return nil }
        let tekst = String(utf16CodeUnits: bufor, count: dlugosc)
        // Znaki sterujace (esc, enter, tabulator) maja wlasna obsluge wyzej.
        guard let pierwszy = tekst.unicodeScalars.first, pierwszy.value >= 32, pierwszy.value != 127 else { return nil }
        return tekst
    }
}
