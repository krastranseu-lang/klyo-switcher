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
    }

    /// Klawisze 1…9 w gornym rzedzie - skok do pozycji na liscie.
    private static let digitKeys: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9
    ]

    var onCycle: ((Bool) -> Void)?
    var onArrow: ((ArrowDirection) -> Void)?
    var onSelectIndex: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onAppShortcut: ((AppShortcut) -> Void)?
    var onCloseSelected: (() -> Void)?
    /// `true` = wymuszone zakonczenie (⌥ razem z Q) - dla aplikacji, ktora nie odpowiada.
    var onQuitSelected: ((Bool) -> Void)?
    var onPermissionGranted: (() -> Void)?
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
                default:
                    if flags.contains(switcherModifier), let digit = HotkeyRouter.digitKeys[keyCode] {
                        onSelectIndex?(digit - 1)
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

            if screenshotEnabled, screenshotCombo.matches(keyCode: keyCode, flags: flags) {
                onScreenshot?()
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
