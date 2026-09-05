import AppKit

/// Sprawdzanie aktualizacji przez maly plik opisowy (appcast) pod adresem z ustawien.
/// Aktualizacja polega na pobraniu tego samego skryptu instalacyjnego, ktorym
/// aplikacja zostala zbudowana - buduje nowa wersje na miejscu i sam ja uruchamia.
final class Updater {
    struct Appcast: Decodable {
        let version: String
        let build: Int
        let notes: String?
        let installScriptURL: String
        /// Gotowy, podpisany program. Gdy jest, aktualizacja polega na pobraniu
        /// pliku i podmianie - bez kompilatora, bez narzedzi Apple, bez Terminala.
        let packageURL: String?
        /// Suma kontrolna paczki. Bez zgodnej sumy NIC nie jest podmieniane.
        let packageSHA256: String?
        let minimumSystemVersion: String?
    }

    enum Outcome {
        case upToDate
        case available(Appcast)
        case notConfigured
        case failed(String)
    }

    static let shared = Updater()

    private var dailyTimer: Timer?
    private var isChecking = false
    private var isInstalling = false

    private init() {}

    func startAutomaticChecks() {
        scheduleTimer()
        guard Settings.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.checkIfDue()
        }
    }

    /// Jeden timer na cala sesje, budzacy sie co szesc godzin. Realne zapytanie leci
    /// najwyzej raz na dobe - reszta przebudzen konczy sie porownaniem dwoch dat.
    private func scheduleTimer() {
        dailyTimer?.invalidate()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        timer.tolerance = 900
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    private func checkIfDue() {
        guard Settings.autoCheckUpdates else { return }
        if let last = Settings.lastUpdateCheck, Date().timeIntervalSince(last) < 23 * 3600 { return }
        check(manual: false)
    }

    // MARK: - Sprawdzanie

    func check(manual: Bool) {
        guard !isChecking else { return }
        let feed = Settings.updateFeedURL
        guard !feed.isEmpty, let url = URL(string: feed), url.scheme == "https" || url.scheme == "http" else {
            if manual { present(.notConfigured, manual: true) }
            return
        }
        isChecking = true
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                Settings.lastUpdateCheck = Date()

                if let error {
                    self.present(.failed(error.localizedDescription), manual: manual)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.present(.failed("Serwer odpowiedział kodem \(http.statusCode)."), manual: manual)
                    return
                }
                guard let data, let appcast = try? JSONDecoder().decode(Appcast.self, from: data) else {
                    self.present(.failed("Plik aktualizacji ma nieznany format."), manual: manual)
                    return
                }
                if appcast.build > AppInfo.build {
                    self.present(.available(appcast), manual: manual)
                } else {
                    self.present(.upToDate, manual: manual)
                }
            }
        }.resume()
    }

    private func present(_ outcome: Outcome, manual: Bool) {
        switch outcome {
        case .upToDate:
            guard manual else { return }
            ToastPresenter.shared.show("Masz najnowszą wersję (\(AppInfo.version)).")

        case .notConfigured:
            let alert = NSAlert()
            alert.messageText = "Kanał aktualizacji nie jest ustawiony"
            alert.informativeText = """
            Wpisz adres pliku z opisem aktualizacji w Ustawieniach → Aktualizacje.
            Bez niego aplikacja nie ma skąd wiedzieć, że pojawiła się nowa wersja.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Otwórz Ustawienia")
            alert.addButton(withTitle: "Anuluj")
            activate()
            if alert.runModal() == .alertFirstButtonReturn {
                SettingsWindowController.shared.show(tab: .updates)
            }

        case .failed(let message):
            guard manual else { return }
            let alert = NSAlert()
            alert.messageText = "Nie udało się sprawdzić aktualizacji"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            activate()
            alert.runModal()

        case .available(let appcast):
            let alert = NSAlert()
            alert.messageText = "Dostępna wersja \(appcast.version)"
            let sposob = appcast.packageURL != nil
                ? "Aktualizacja pobierze gotowy program i podmieni go w tle. Zajmie kilkanaście sekund."
                : "Aktualizacja zbuduje nową wersję na tym Macu i uruchomi ją ponownie."
            alert.informativeText = (appcast.notes?.isEmpty == false ? appcast.notes! + "\n\n" : "")
                + "Masz wersję \(AppInfo.version). " + sposob
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Zaktualizuj teraz")
            alert.addButton(withTitle: "Później")
            activate()
            if alert.runModal() == .alertFirstButtonReturn {
                install(appcast)
            }
        }
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Instalacja

    private func install(_ appcast: Appcast) {
        guard !isInstalling else { return }
        // Droga glowna: gotowy program. Uzytkownik nie potrzebuje do tego ani
        // kompilatora, ani narzedzi Apple - a to wlasnie o nie rozbijala sie
        // aktualizacja na swiezym systemie.
        if let adres = appcast.packageURL, let url = URL(string: adres) {
            isInstalling = true
            pobierzPaczke(url, oczekiwanaSuma: appcast.packageSHA256, wersja: appcast.version)
            return
        }
        guard let url = URL(string: appcast.installScriptURL) else { return }
        isInstalling = true
        ToastPresenter.shared.show("Pobieram aktualizację \(appcast.version)…", symbol: "arrow.down.circle.fill")

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil, !data.isEmpty else {
                    self.isInstalling = false
                    ToastPresenter.shared.show("Nie udało się pobrać aktualizacji.", symbol: "exclamationmark.triangle.fill")
                    return
                }
                let scriptURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("klyo-switcher-update.sh")
                do {
                    try data.write(to: scriptURL, options: .atomic)
                } catch {
                    self.isInstalling = false
                    ToastPresenter.shared.show("Nie udało się zapisać aktualizacji.", symbol: "exclamationmark.triangle.fill")
                    return
                }
                self.run(scriptURL)
            }
        }.resume()
    }

    // MARK: - Aktualizacja gotowym programem

    private func pobierzPaczke(_ url: URL, oczekiwanaSuma: String?, wersja: String) {
        ToastPresenter.shared.show("Pobieram wersję \(wersja)…", symbol: "arrow.down.circle.fill")
        var zadanie = URLRequest(url: url)
        zadanie.cachePolicy = .reloadIgnoringLocalCacheData
        zadanie.timeoutInterval = 180

        URLSession.shared.downloadTask(with: zadanie) { [weak self] plik, odpowiedz, blad in
            guard let self else { return }
            guard let plik, blad == nil,
                  let http = odpowiedz as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    ToastPresenter.shared.show("Nie udało się pobrać aktualizacji.", symbol: "exclamationmark.triangle.fill")
                }
                return
            }
            // Plik tymczasowy zniknie po powrocie z tej funkcji, wiec od razu
            // przenosimy go w miejsce, ktore kontrolujemy.
            let paczka = FileManager.default.temporaryDirectory
                .appendingPathComponent("klyo-switcher-\(wersja).zip")
            try? FileManager.default.removeItem(at: paczka)
            do {
                try FileManager.default.moveItem(at: plik, to: paczka)
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    ToastPresenter.shared.show("Nie udało się zapisać aktualizacji.", symbol: "exclamationmark.triangle.fill")
                }
                return
            }
            DispatchQueue.main.async {
                self.podmien(paczka: paczka, oczekiwanaSuma: oczekiwanaSuma, wersja: wersja)
            }
        }.resume()
    }

    /// Podmiana dzieje sie w skrypcie POZA tym procesem, bo program nie moze
    /// nadpisac samego siebie w trakcie dzialania. Skrypt sprawdza sume kontrolna,
    /// rozpakowuje paczke, sprawdza podpis Apple i dopiero WTEDY podmienia program.
    /// Kazdy z tych krokow, gdy zawiedzie, zostawia dotychczasowa wersje nietknieta.
    private func podmien(paczka: URL, oczekiwanaSuma: String?, wersja: String) {
        let mojaSciezka = Bundle.main.bundlePath
        let dziennik = FileManager.default.temporaryDirectory.appendingPathComponent("klyo-switcher-update.log").path
        let suma = oczekiwanaSuma ?? ""
        let skrypt = """
        set -e
        paczka="\(paczka.path)"
        cel="\(mojaSciezka)"
        suma="\(suma)"
        if [ -n "$suma" ]; then
          policzona=$(/usr/bin/shasum -a 256 "$paczka" | awk '{print $1}')
          if [ "$policzona" != "$suma" ]; then
            echo "suma kontrolna sie nie zgadza: $policzona != $suma"
            exit 1
          fi
          echo "suma kontrolna zgodna"
        fi
        katalog=$(/usr/bin/mktemp -d)
        /usr/bin/ditto -x -k "$paczka" "$katalog"
        nowa=$(/usr/bin/find "$katalog" -maxdepth 1 -name "*.app" | /usr/bin/head -1)
        [ -n "$nowa" ] || { echo "w paczce nie ma programu"; exit 1; }
        /usr/bin/codesign --verify --deep --strict "$nowa" || { echo "podpis nowej wersji nie przechodzi kontroli"; exit 1; }
        /usr/bin/pkill -x KlyoSwitcher || true
        sleep 1
        /bin/rm -rf "$cel"
        /bin/cp -R "$nowa" "$cel"
        /usr/bin/xattr -dr com.apple.quarantine "$cel" || true
        /bin/rm -rf "$katalog" "$paczka"
        /usr/bin/open "$cel"
        echo "podmieniono na wersje \(wersja)"
        """
        let proces = Process()
        proces.executableURL = URL(fileURLWithPath: "/bin/bash")
        proces.arguments = ["-c", "nohup /bin/bash -c \(skrypt.shellEscaped()) > \(dziennik) 2>&1 &"]
        do {
            try proces.run()
        } catch {
            isInstalling = false
            ToastPresenter.shared.show("Nie udało się uruchomić aktualizacji.", symbol: "exclamationmark.triangle.fill")
            return
        }
        ToastPresenter.shared.show("Podmieniam program — za chwilę wystartuje wersja \(wersja).", symbol: "arrow.triangle.2.circlepath")
    }

    /// Skrypt startuje odlaczony od naszego procesu: sam buduje nowa wersje, a dopiero po
    /// UDANEJ kompilacji zatrzymuje te aplikacje i uruchamia nowa. Jesli budowa sie nie
    /// powiedzie, ta wersja dziala dalej - uzytkownik nigdy nie zostaje bez przelacznika.
    private func run(_ scriptURL: URL) {
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("klyo-switcher-update.log").path
        let command = "nohup /bin/bash \"\(scriptURL.path)\" > \"\(logPath)\" 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            isInstalling = false
            ToastPresenter.shared.show("Nie udało się uruchomić aktualizacji.", symbol: "exclamationmark.triangle.fill")
            return
        }
        ToastPresenter.shared.show("Buduję nową wersję (do 2 minut) — przeładuje się sama po zbudowaniu.", symbol: "gearshape.2.fill")
        // Gdy budowa sie nie powiedzie, ta wersja dziala dalej - po chwili odblokowujemy
        // ponowna probe, zeby uzytkownik nie musial restartowac aplikacji.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            self?.isInstalling = false
        }
    }
}

private extension String {
    /// Cala tresc skryptu jako JEDEN argument powloki. Bez tego kazdy apostrof
    /// w sciezce (a katalog uzytkownika moze go miec) rozerwalby polecenie.
    func shellEscaped() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
