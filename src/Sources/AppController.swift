import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let switcher = SwitcherController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicate() else { return }

        buildStatusItem()
        switcher.start()
        wireExtraShortcuts()
        Updater.shared.startAutomaticChecks()

        if !Settings.didBootstrapLoginItem {
            Settings.didBootstrapLoginItem = true
            if Settings.launchAtLogin {
                LoginItem.setEnabled(true)
            }
        }

        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()
            showAccessibilityIntro()
        }
    }

    /// Autostart potrafi wystartowac druga kopie obok juz dzialajacej - wtedy nowa konczy prace.
    private func terminateIfDuplicate() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    private func wireExtraShortcuts() {
        switcher.hotkey.onScreenshot = { [weak self] in self?.takeScreenshot() }
        switcher.hotkey.onAppShortcut = { shortcut in AppLauncher.trigger(shortcut) }
        HotkeySuspension.setter = { [weak router = self.switcher.hotkey] suspended in
            router?.isSuspended = suspended
        }
    }

    // MARK: - Ikona w pasku menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarIcon.make()
            button.imagePosition = .imageOnly
            button.toolTip = "\(AppInfo.name) \(AppInfo.version)"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let ready = Permissions.accessibilityGranted && switcher.hotkey.isInstalled
        let statusTitle = ready
            ? "Aktywny — \(Settings.modifier.symbol) + Tab"
            : "Czeka na zgodę „Dostępność”"
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())

        // Najczesciej zmieniane ustawienie trzymamy pod reka, reszta jest w oknie ustawien.
        let browserItem = NSMenuItem(title: "Przeglądarki", action: nil, keyEquivalent: "")
        let browserMenu = NSMenu()
        for mode in BrowserMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(selectBrowserMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = Settings.browserMode == mode ? .on : .off
            browserMenu.addItem(entry)
        }
        browserItem.submenu = browserMenu
        menu.addItem(browserItem)

        let spacesItem = NSMenuItem(title: "Biurka", action: nil, keyEquivalent: "")
        let spacesMenu = NSMenu()
        for mode in SpacesMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(selectSpacesMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = Settings.spacesMode == mode ? .on : .off
            spacesMenu.addItem(entry)
        }
        spacesItem.submenu = spacesMenu
        menu.addItem(spacesItem)

        if Settings.screenshotEnabled {
            let shot = NSMenuItem(
                title: "Zrzut ekranu z kompresją  (\(Settings.screenshotCombo.display))",
                action: #selector(takeScreenshotFromMenu),
                keyEquivalent: ""
            )
            shot.target = self
            menu.addItem(shot)
        }

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Ustawienia…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: "Sprawdź aktualizacje…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        if !ready {
            let accessibility = NSMenuItem(title: "Otwórz ustawienia: Dostępność…", action: #selector(openAccessibility), keyEquivalent: "")
            accessibility.target = self
            menu.addItem(accessibility)
        }

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Zakończ \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Akcje menu

    @objc private func selectBrowserMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = BrowserMode(rawValue: raw) else { return }
        Settings.browserMode = mode
        SettingsBus.announce()
    }

    @objc private func selectSpacesMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SpacesMode(rawValue: raw) else { return }
        Settings.spacesMode = mode
        SettingsBus.announce()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        Updater.shared.check(manual: true)
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func takeScreenshotFromMenu() {
        takeScreenshot()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Zrzut ekranu

    private func takeScreenshot() {
        ScreenshotService.captureSelection { result, error in
            if let error {
                ToastPresenter.shared.show(error, symbol: "exclamationmark.triangle.fill")
                return
            }
            guard let result else { return }  // uzytkownik anulowal zaznaczenie
            ToastPresenter.shared.show(ScreenshotService.describe(result), symbol: "camera.viewfinder")
        }
    }

    // MARK: - Onboarding

    private func showAccessibilityIntro() {
        let alert = NSAlert()
        alert.messageText = "Włącz zgodę „Dostępność”"
        alert.informativeText = """
        Aby \(AppInfo.name) mógł przechwytywać ⌘ + Tab i przełączać okna, dodaj go w:

        Ustawienia systemowe → Prywatność i ochrona → Dostępność

        Znajdź na liście „\(AppInfo.name)” i przesuń przełącznik na włączony. \
        Aplikacja wykryje zgodę sama, nie trzeba jej restartować.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Otwórz ustawienia")
        alert.addButton(withTitle: "Później")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}
