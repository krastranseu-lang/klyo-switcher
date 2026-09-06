import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let switcher = SwitcherController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicate() else { return }
        // Kolejnosc jest istotna: najpierw sprowadzamy sie na jedyna dozwolona
        // sciezke, dopiero potem cokolwiek robimy. Program uruchomiony jako
        // „Klyo Switcher 5.app" nie ma prawa dzialac - zgody systemowe naleza
        // do innej kopii i nic tego nie zmieni poza przeniesieniem sie tam.
        guard !znormalizujSciezke() else { return }
        guard !przeniesSieDoProgramow() else { return }

        buildStatusItem()
        switcher.start()
        HistoriaSchowka.shared.start()
        wireExtraShortcuts()
        Updater.shared.startAutomaticChecks()

        if !Settings.didBootstrapLoginItem {
            Settings.didBootstrapLoginItem = true
            if Settings.launchAtLogin {
                LoginItem.setEnabled(true)
            }
        }

        sprzatnijStareKopie()

        if Permissions.accessibilityGranted {
            // Zapamietujemy, ze zgoda dziala. Gdy kiedys przestanie, bedziemy
            // wiedziec, ze to zerwane powiazanie, a nie brak zgody.
            Permissions.zgodaKiedysDzialala = true
        } else {
            let martwa = Permissions.zgodaMartwa
            if !martwa { Permissions.requestAccessibility() }
            // Okno pokazuje stan KAZDEJ zgody i mowi, co dokladnie kliknac -
            // zamiast alertu, ktory tylko odsyla do Ustawien.
            OknoUprawnienController.shared.pokaz(zgodaMartwa: martwa)
        }
    }

    /// Pytanie o przeniesienie do katalogu Programy.
    ///
    /// macOS uruchamia program pobrany z internetu z losowego katalogu tymczasowego
    /// („AppTranslocation"), dopoki czlowiek nie przeniesie go do Programow. Sciezka
    /// jest wtedy INNA przy kazdym uruchomieniu, wiec zgody systemowe nie maja sie
    /// czego uchwycic: przelacznik Nagrywania ekranu wraca do wylaczonego, a czlowiek
    /// jest przekonany, ze program jest zepsuty. Nie da sie tego obejsc od srodka -
    /// mozna tylko stanac we wlasciwym miejscu.
    private func zapytajOPrzeniesienie(wTranslokacji: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Przenieść \(AppInfo.name) do katalogu Programy?"
        alert.informativeText = wTranslokacji
            ? """
              macOS uruchomił ten program z katalogu tymczasowego, bo został pobrany z internetu               i nie stoi jeszcze w Programach. Ten katalog ma inną nazwę przy każdym uruchomieniu,               więc zgody systemowe — w tym Nagrywanie ekranu — nie mają się czego trzymać i wracają               do wyłączonych.

              Po przeniesieniu program uruchomi się ponownie z właściwego miejsca i zgody zaczną               działać na stałe.
              """
            : """
              Ten program działa jako dodatkowa kopia. macOS przypisuje zgody konkretnej kopii,               więc zgoda włączona dla jednej nie działa dla drugiej — stąd „wszystko włączone,               a nic nie działa".

              Po przeniesieniu zostanie jedna kopia we właściwym miejscu i jeden komplet zgód.
              """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Przenieś i uruchom ponownie")
        alert.addButton(withTitle: "Nie teraz")
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Program ma DOKLADNIE JEDNO miejsce, w ktorym wolno mu istniec:
    /// `/Applications/Klyo Switcher.app` (albo ten sam katalog w folderze domowym,
    /// gdy konto nie ma prawa zapisu do systemowego).
    ///
    /// Dlaczego to jest twarda zasada, a nie porzadki: macOS przypisuje zgody
    /// (Dostepnosc, Nagrywanie ekranu) KONKRETNEJ kopii programu - jej sciezce
    /// i podpisowi. Kazda dodatkowa kopia to dla systemu osobny program z wlasnym
    /// wpisem. Uzytkownik wlacza wtedy zgode jednej kopii, a uruchamia sie druga
    /// i nic nie dziala, mimo ptaszka w Ustawieniach. Tak powstaje „Klyo Switcher 5":
    /// piata kopia, piaty wpis, jedna wlaczona zgoda i zero dzialania.
    ///
    /// Kopie z numerem biora sie z rozpakowania paczki tam, gdzie program juz lezy -
    /// system nie nadpisuje, tylko dokleja numer. Dlatego nie wystarczy sprzatac
    /// cudzych kopii: gdy to MY jestesmy ta z numerem, musimy przeniesc sie na
    /// wlasciwe miejsce i uruchomic stamtad.
    ///
    /// Zwraca `true`, gdy uruchomiono wlasciwa kopie i ta ma zakonczyc prace.
    private func znormalizujSciezke() -> Bool {
        let menedzer = FileManager.default
        let moja = Bundle.main.bundlePath
        let nazwaPliku = (moja as NSString).lastPathComponent
        let bezRozszerzenia = (nazwaPliku as NSString).deletingPathExtension
        let dom = NSHomeDirectory()

        // Czy jestesmy kopia z numerem? („Klyo Switcher 5")
        let numerowana: Bool = {
            guard bezRozszerzenia.hasPrefix(AppInfo.name + " ") else { return false }
            let reszta = bezRozszerzenia.dropFirst(AppInfo.name.count + 1)
            return !reszta.isEmpty && reszta.allSatisfy { $0.isNumber }
        }()

        // Program pobrany z internetu i uruchomiony BEZ przeniesienia do Programow
        // macOS uruchamia z losowego katalogu tymczasowego („AppTranslocation").
        // To zabezpieczenie Gatekeepera, ale dla nas oznacza katastrofe: sciezka
        // jest INNA przy kazdym uruchomieniu, wiec zgody systemowe nie maja sie
        // czego uchwycic. Zgoda Nagrywania ekranu w ogole sie wtedy nie utrwala -
        // czlowiek przesuwa przelacznik, a ten wraca do wylaczonego. Dostepnosc
        // czasem dziala, bo przyczepia sie do podpisu, i to najgorszy mozliwy
        // stan posredni: czesc dziala, czesc nie, a przyczyny nie widac.
        let wTranslokacji = moja.contains("/AppTranslocation/")

        guard numerowana || wTranslokacji else { return false }

        // Pytamy, zamiast przenosic po cichu. Tak robi kazdy porzadny program na
        // Macu i tak trzeba: to jest ruch cudzego pliku po dysku uzytkownika,
        // a nie nasza wewnetrzna sprawa. Okno musi tez powiedziec DLACZEGO -
        // inaczej brzmi jak kaprys programu, a jest warunkiem dzialania zgod.
        guard zapytajOPrzeniesienie(wTranslokacji: wTranslokacji) else { return false }

        var katalog = "/Applications"
        if !menedzer.isWritableFile(atPath: katalog) {
            katalog = "\(dom)/Applications"
            try? menedzer.createDirectory(atPath: katalog, withIntermediateDirectories: true)
        }
        let cel = "\(katalog)/\(AppInfo.name).app"
        guard cel != moja else { return false }
        // Z translokacji zawsze wychodzimy pod kanoniczna nazwa - katalog
        // tymczasowy trzyma kopie o wlasciwej nazwie, wiec przenosimy ja tam,
        // gdzie ma stac na stale.

        // Podmiana przez przestawienie nazw: nowa kopia wchodzi na miejsce starej
        // jednym ruchem. Gdyby cokolwiek zawiodlo, stara wraca i dalej dziala.
        let ustepujaca = "\(katalog)/.\(AppInfo.name)-poprzednia-\(getpid()).app"
        let przygotowana = "\(katalog)/.\(AppInfo.name)-nowa-\(getpid()).app"
        try? menedzer.removeItem(atPath: ustepujaca)
        try? menedzer.removeItem(atPath: przygotowana)
        do { try menedzer.copyItem(atPath: moja, toPath: przygotowana) } catch { return false }

        let bylaStara = menedzer.fileExists(atPath: cel)
        if bylaStara {
            do { try menedzer.moveItem(atPath: cel, toPath: ustepujaca) } catch {
                try? menedzer.removeItem(atPath: przygotowana)
                return false
            }
        }
        do { try menedzer.moveItem(atPath: przygotowana, toPath: cel) } catch {
            if bylaStara { try? menedzer.moveItem(atPath: ustepujaca, toPath: cel) }
            try? menedzer.removeItem(atPath: przygotowana)
            return false
        }
        try? menedzer.removeItem(atPath: ustepujaca)

        // Rejestr programow trzyma opis poprzedniej kopii - bez odswiezenia
        // polecenie otwarcia potrafi trafic w nieaktualny wpis i nie zrobic nic.
        let rejestr = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if menedzer.isExecutableFile(atPath: rejestr) {
            let odswiez = Process()
            odswiez.executableURL = URL(fileURLWithPath: rejestr)
            odswiez.arguments = ["-f", cel]
            odswiez.standardOutput = FileHandle.nullDevice
            odswiez.standardError = FileHandle.nullDevice
            try? odswiez.run()
            odswiez.waitUntilExit()
        }

        let konfiguracja = NSWorkspace.OpenConfiguration()
        konfiguracja.createsNewApplicationInstance = true
        let grupa = DispatchGroup()
        grupa.enter()
        var wystartowala = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: cel), configuration: konfiguracja) { program, _ in
            wystartowala = program != nil
            grupa.leave()
        }
        _ = grupa.wait(timeout: .now() + 12)
        guard wystartowala else { return false }

        // Kopia z numerem zrobila swoje - wyrzucamy ja, zeby nie zostawic kolejnej.
        // Kopii w katalogu tymczasowym NIE ruszamy: nalezy do systemu, jest tylko
        // do odczytu i zniknie sama.
        if !wTranslokacji {
            let doUsuniecia = moja
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: doUsuniecia), resultingItemURL: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        return true
    }

    /// Kopie z numerem w nazwie („Klyo Switcher 2.app") powstaja, gdy nowa wersja
    /// trafia OBOK starej - przy rozpakowaniu paczki do katalogu, w ktorym program
    /// juz lezy. Dla systemu kazda taka kopia to osobny program z osobna zgoda,
    /// wiec czlowiek wlacza zgode jednej, a uruchamia sie druga i nic nie dziala.
    /// Zostawiamy wylacznie te kopie, ktora wlasnie dziala.
    private func sprzatnijStareKopie() {
        let menedzer = FileManager.default
        let moja = Bundle.main.bundlePath
        let nazwa = ((moja as NSString).lastPathComponent as NSString).deletingPathExtension
        let dom = NSHomeDirectory()
        let katalogi = ["/Applications", "\(dom)/Applications", "\(dom)/Downloads", "\(dom)/Desktop"]

        for katalog in katalogi {
            guard let pliki = try? menedzer.contentsOfDirectory(atPath: katalog) else { continue }
            for plik in pliki where plik.hasSuffix(".app") {
                let sciezka = "\(katalog)/\(plik)"
                guard sciezka != moja else { continue }
                let bez = (plik as NSString).deletingPathExtension
                // Tylko „nazwa + spacja + numer". Nic innego nie ruszamy.
                guard bez.hasPrefix(nazwa + " ") else { continue }
                let reszta = bez.dropFirst(nazwa.count + 1)
                guard !reszta.isEmpty, reszta.allSatisfy({ $0.isNumber }) else { continue }
                guard Bundle(path: sciezka)?.bundleIdentifier == Bundle.main.bundleIdentifier else { continue }
                try? menedzer.trashItem(at: URL(fileURLWithPath: sciezka), resultingItemURL: nil)
            }
        }
    }

    /// Program pobrany z internetu laduje w katalogu Pobrane. Zostawiony tam dziala,
    /// ale znika przy sprzataniu katalogu, nie widzi go Launchpad, a autostart po
    /// zalogowaniu wskazuje na sciezke, ktorej moze juz nie byc. Dlatego przenosimy
    /// sie sami do katalogu Programy - uzytkownik ma o jeden krok mniej.
    ///
    /// Robimy to WYLACZNIE z Pobranych i z biurka, czyli z miejsc, gdzie plik ladue
    /// po pobraniu. Program uruchomiony swiadomie z innego katalogu zostawiamy w spokoju.
    /// Zwraca `true`, gdy kopia zostala uruchomiona i ta kopia ma zakonczyc prace.
    private func przeniesSieDoProgramow() -> Bool {
        let mojaSciezka = Bundle.main.bundlePath
        let dom = NSHomeDirectory()
        let zPobranych = mojaSciezka.hasPrefix("\(dom)/Downloads/")
        let zBiurka = mojaSciezka.hasPrefix("\(dom)/Desktop/")
        guard zPobranych || zBiurka else { return false }

        let nazwa = (mojaSciezka as NSString).lastPathComponent
        let menedzer = FileManager.default
        // Najpierw katalog systemowy; gdy nie ma do niego prawa zapisu (konto bez
        // uprawnien administratora), wlasny katalog uzytkownika dziala tak samo dobrze.
        var katalog = "/Applications"
        if !menedzer.isWritableFile(atPath: katalog) {
            katalog = "\(dom)/Applications"
            try? menedzer.createDirectory(atPath: katalog, withIntermediateDirectories: true)
        }
        let cel = "\(katalog)/\(nazwa)"
        guard cel != mojaSciezka else { return false }

        if menedzer.fileExists(atPath: cel) {
            // W Programach stoi juz starsza kopia - podmieniamy ja na te, ktora
            // wlasnie uruchomil uzytkownik.
            try? menedzer.removeItem(atPath: cel)
        }
        do {
            try menedzer.copyItem(atPath: mojaSciezka, toPath: cel)
        } catch {
            return false
        }

        // Znacznik pochodzenia z internetu zdjety z KOPII: uzytkownik wlasnie
        // potwierdzil uruchomienie, wiec system nie musi pytac drugi raz.
        let czyszczenie = Process()
        czyszczenie.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        czyszczenie.arguments = ["-dr", "com.apple.quarantine", cel]
        try? czyszczenie.run()
        czyszczenie.waitUntilExit()

        let konfiguracja = NSWorkspace.OpenConfiguration()
        konfiguracja.activates = true
        konfiguracja.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: cel), configuration: konfiguracja) { program, blad in
            DispatchQueue.main.async {
                guard program != nil, blad == nil else { return }
                NSApp.terminate(nil)
            }
        }
        // Zamykamy sie DOPIERO wtedy, gdy nowa kopia naprawde dziala. Bezwarunkowe
        // zamkniecie po czasie zostawialo uzytkownika bez programu, gdy system
        // nie zdazyl uruchomic kopii w Programach.
        potwierdzUruchomienie(cel: cel, prob: 6)
        return true
    }

    /// Sprawdza, czy kopia w Programach naprawde ruszyla. Dopiero wtedy TA kopia
    /// konczy prace. Gdy po kilku probach nic nie dziala, zostajemy uruchomieni -
    /// dzialajacy program w Pobranych jest lepszy niz zaden.
    private func potwierdzUruchomienie(cel: String, prob: Int) {
        guard prob > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let dziala = NSWorkspace.shared.runningApplications.contains { program in
                program.processIdentifier != getpid() && program.bundleURL?.path == cel
            }
            if dziala {
                NSApp.terminate(nil)
            } else {
                self?.potwierdzUruchomienie(cel: cel, prob: prob - 1)
            }
        }
    }

    /// Dwie kopie tego samego programu nie moga chodzic naraz - obie walczylyby
    /// o ten sam skrot. Ale to STARSZA ma ustapic, nie nowo uruchomiona: uzytkownik
    /// wlasnie kliknal w ikone i oczekuje, ze cos sie stanie. Wczesniej konczyla
    /// prace nowa kopia i wygladalo to jak program, ktory sie nie uruchamia.
    private func terminateIfDuplicate() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let inne = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        guard !inne.isEmpty else { return false }
        for stara in inne {
            stara.terminate()
        }
        // Stara kopia potrzebuje chwili na zwolnienie podsluchu klawiatury.
        Thread.sleep(forTimeInterval: 0.6)
        for stara in inne where !stara.isTerminated {
            stara.forceTerminate()
        }
        return false
    }

    private func wireExtraShortcuts() {
        switcher.hotkey.onScreenshot = { [weak self] in self?.takeScreenshot() }
        switcher.hotkey.onHistoriaSchowka = { SchowekOknoController.shared.pokaz() }
        switcher.hotkey.onZgodaNieDziala = {
            OknoUprawnienController.shared.pokaz(zgodaMartwa: true)
        }
        switcher.hotkey.onCzystyTekst = {
            if !Wklejanie.wklejBezFormatowania() {
                ToastPresenter.shared.show("W schowku nie ma tekstu do wklejenia.", symbol: "text.badge.xmark")
            }
        }
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

        if Settings.historiaSchowkaWlaczona {
            let historia = NSMenuItem(
                title: "Historia kopiowania  (\(Settings.skrotHistoriiSchowka.display))",
                action: #selector(pokazHistorieSchowka),
                keyEquivalent: ""
            )
            historia.target = self
            menu.addItem(historia)
        }

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

        let zgody = NSMenuItem(
            title: ready ? "Zgody systemowe…" : "Brakuje zgody — pokaż, co zrobić…",
            action: #selector(pokazZgody),
            keyEquivalent: ""
        )
        zgody.target = self
        menu.addItem(zgody)

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

    @objc private func pokazZgody() {
        OknoUprawnienController.shared.pokaz()
    }

    @objc private func pokazHistorieSchowka() {
        SchowekOknoController.shared.pokaz()
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

}
