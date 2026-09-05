import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case schowek
    case browsers
    case screenshots
    case shortcuts
    case updates
}

/// Zwykle okno aplikacji dla aplikacji, ktora normalnie zyje tylko w pasku menu.
/// Na czas jego zycia przelaczamy sie na polityke `.regular`, zeby dalo sie je
/// aktywowac i pisac w polach tekstowych, a po zamknieciu wracamy do `.accessory`.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let store = SettingsStore()

    private override init() {
        super.init()
    }

    func show(tab: SettingsTab = .general) {
        store.reload()
        store.tab = tab

        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(store: store))
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "\(AppInfo.name) — Ustawienia"
            created.contentView = hosting
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }

        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        HotkeySuspension.set(false)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Stan ustawien dla widoku

final class SettingsStore: ObservableObject {
    @Published var tab: SettingsTab = .general

    @Published var modifier: HotkeyModifier = .command { didSet { commit { Settings.modifier = modifier } } }
    @Published var launchAtLogin: Bool = true {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            LoginItem.setEnabled(launchAtLogin)
            Settings.launchAtLogin = launchAtLogin
        }
    }
    @Published var browserMode: BrowserMode = .windowsOnly { didSet { commit { Settings.browserMode = browserMode } } }
    @Published var spacesMode: SpacesMode = .allDesktops { didSet { commit { Settings.spacesMode = spacesMode } } }
    @Published var tabLimit: Int = 6 { didSet { commit { Settings.tabLimitPerWindow = tabLimit } } }
    @Published var thumbnails: Bool = false {
        didSet {
            Settings.showThumbnails = thumbnails
            if thumbnails && !Permissions.screenRecordingGranted {
                Permissions.requestScreenRecording()
                Permissions.openScreenRecordingSettings()
            }
            SettingsBus.announce()
        }
    }

    @Published var historiaSchowka: Bool = true {
        didSet {
            Settings.historiaSchowkaWlaczona = historiaSchowka
            SettingsBus.announce()
        }
    }
    @Published var limitHistorii: Int = 200 { didSet { commit { Settings.limitHistoriiSchowka = limitHistorii } } }
    @Published var skrotSchowka: KeyCombo = .unset { didSet { commit { Settings.skrotHistoriiSchowka = skrotSchowka } } }
    @Published var skrotCzysty: KeyCombo = .unset { didSet { commit { Settings.skrotCzystegoTekstu = skrotCzysty } } }

    @Published var screenshotEnabled: Bool = true { didSet { commit { Settings.screenshotEnabled = screenshotEnabled } } }
    @Published var screenshotCombo: KeyCombo = .unset { didSet { commit { Settings.screenshotCombo = screenshotCombo } } }
    @Published var screenshotMaxKB: Int = 1200 { didSet { commit { Settings.screenshotMaxKB = screenshotMaxKB } } }
    @Published var screenshotMaxPixels: Int = 2400 { didSet { commit { Settings.screenshotMaxPixels = screenshotMaxPixels } } }
    @Published var screenshotFormat: ScreenshotFormat = .jpeg { didSet { commit { Settings.screenshotFormat = screenshotFormat } } }
    @Published var screenshotSaveToDisk: Bool = true { didSet { commit { Settings.screenshotSaveToDisk = screenshotSaveToDisk } } }
    @Published var screenshotFolder: String = ""

    @Published var appShortcuts: [AppShortcut] = [] { didSet { commit { Settings.appShortcuts = appShortcuts } } }

    @Published var updateFeed: String = "" { didSet { commit { Settings.updateFeedURL = updateFeed } } }
    @Published var autoCheckUpdates: Bool = true { didSet { commit { Settings.autoCheckUpdates = autoCheckUpdates } } }

    private var isLoading = false

    func reload() {
        isLoading = true
        modifier = Settings.modifier
        launchAtLogin = LoginItem.isEnabled
        browserMode = Settings.browserMode
        spacesMode = Settings.spacesMode
        tabLimit = Settings.tabLimitPerWindow
        thumbnails = Settings.showThumbnails
        historiaSchowka = Settings.historiaSchowkaWlaczona
        limitHistorii = Settings.limitHistoriiSchowka
        skrotSchowka = Settings.skrotHistoriiSchowka
        skrotCzysty = Settings.skrotCzystegoTekstu
        screenshotEnabled = Settings.screenshotEnabled
        screenshotCombo = Settings.screenshotCombo
        screenshotMaxKB = Settings.screenshotMaxKB
        screenshotMaxPixels = Settings.screenshotMaxPixels
        screenshotFormat = Settings.screenshotFormat
        screenshotSaveToDisk = Settings.screenshotSaveToDisk
        screenshotFolder = Settings.screenshotFolder.path
        appShortcuts = Settings.appShortcuts
        updateFeed = Settings.updateFeedURL
        autoCheckUpdates = Settings.autoCheckUpdates
        isLoading = false
    }

    private func commit(_ apply: () -> Void) {
        guard !isLoading else { return }
        apply()
        SettingsBus.announce()
    }

    func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.screenshotFolder
        panel.prompt = "Wybierz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.screenshotFolder = url
        screenshotFolder = url.path
        SettingsBus.announce()
    }

    func addShortcut(name: String, bundleID: String) {
        guard !appShortcuts.contains(where: { $0.bundleID == bundleID }) else { return }
        appShortcuts.append(AppShortcut(combo: .unset, bundleID: bundleID, name: name))
    }

    func removeShortcut(id: UUID) {
        appShortcuts.removeAll { $0.id == id }
    }

    func updateCombo(id: UUID, combo: KeyCombo) {
        guard let index = appShortcuts.firstIndex(where: { $0.id == id }) else { return }
        appShortcuts[index].combo = combo
    }
}

// MARK: - Rejestrator skrotu

/// Nagrywanie trzyma zywy monitor zdarzen, wiec jego stan mieszka w klasie -
/// struktura widoku bylaby kopiowana przy kazdym odrysowaniu i monitor moglby
/// zostac w pamieci po zamknieciu okna.
final class KeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var handler: ((KeyCombo) -> Void)?

    func start(onChange: @escaping (KeyCombo) -> Void) {
        guard !isRecording else { stop(); return }
        handler = onChange
        isRecording = true
        HotkeySuspension.set(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let keyCode = Int64(event.keyCode)
            if keyCode == 53 {
                self.stop()
                return nil
            }
            if keyCode == 51 || keyCode == 117 {
                self.handler?(.unset)
                self.stop()
                return nil
            }
            var modifiers: UInt64 = 0
            if event.modifierFlags.contains(.command) { modifiers |= CGEventFlags.maskCommand.rawValue }
            if event.modifierFlags.contains(.option) { modifiers |= CGEventFlags.maskAlternate.rawValue }
            if event.modifierFlags.contains(.shift) { modifiers |= CGEventFlags.maskShift.rawValue }
            if event.modifierFlags.contains(.control) { modifiers |= CGEventFlags.maskControl.rawValue }
            guard modifiers != 0 else { return nil }
            self.handler?(KeyCombo(keyCode: keyCode, modifiers: modifiers))
            self.stop()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
        isRecording = false
        HotkeySuspension.set(false)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct KeyRecorder: View {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void

    @StateObject private var model = KeyRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if model.isRecording {
                    model.stop()
                } else {
                    model.start(onChange: onChange)
                }
            } label: {
                Text(model.isRecording ? "Naciśnij skrót…" : combo.display)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 104)
            }
            .buttonStyle(.bordered)

            if combo.isSet && !model.isRecording {
                Button {
                    onChange(.unset)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Usuń skrót")
            }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - Widok ustawien

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView(selection: $store.tab) {
            general.tabItem { Label("Ogólne", systemImage: "gearshape") }.tag(SettingsTab.general)
            browsers.tabItem { Label("Przeglądarki", systemImage: "safari") }.tag(SettingsTab.browsers)
            schowek.tabItem { Label("Schowek", systemImage: "doc.on.clipboard") }.tag(SettingsTab.schowek)
            screenshots.tabItem { Label("Zrzuty", systemImage: "camera.viewfinder") }.tag(SettingsTab.screenshots)
            shortcuts.tabItem { Label("Skróty aplikacji", systemImage: "command") }.tag(SettingsTab.shortcuts)
            updates.tabItem { Label("Aktualizacje", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.updates)
        }
        .padding(18)
        .frame(width: 660, height: 540)
    }

    // MARK: Ogolne

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Skrót przełącznika okien") {
                    Picker("", selection: $store.modifier) {
                        Text("⌘ + Tab (jak w Windows)").tag(HotkeyModifier.command)
                        Text("⌥ + Tab (zostaw systemowy ⌘+Tab)").tag(HotkeyModifier.option)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("⇧ odwraca kierunek, strzałki chodzą po siatce, 1–9 skaczą do pozycji, Esc zamyka. Puszczenie modyfikatora przełącza. Mysz wybiera kartę dopiero, gdy nią ruszysz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Biurka (Spaces)") {
                    Picker("", selection: $store.spacesMode) {
                        ForEach(SpacesMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(spacesExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Wygląd listy") {
                    Toggle("Miniatury podglądu okien zamiast ikon", isOn: $store.thumbnails)
                    Text(Permissions.screenRecordingGranted
                         ? "Zgoda „Nagrywanie ekranu” jest nadana — karty pokazują zrzut okna w całości."
                         : "Miniatury wymagają zgody „Nagrywanie ekranu”; bez niej karty pokazują ikony. Włączenie od razu ją zaproponuje.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Start systemu") {
                    Toggle("Uruchamiaj \(AppInfo.name) po zalogowaniu", isOn: $store.launchAtLogin)
                }

                section("Uprawnienia") {
                    HStack(spacing: 10) {
                        Button("Dostępność…") { Permissions.openAccessibilitySettings() }
                        Button("Nagrywanie ekranu…") { Permissions.openScreenRecordingSettings() }
                        Button("Automatyzacja…") { Permissions.openAutomationSettings() }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Przegladarki

    private var browsers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Co pokazywać dla Chrome, Safari i pokrewnych") {
                    Picker("", selection: $store.browserMode) {
                        ForEach(BrowserMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(modeExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.browserMode == .recentTabs {
                    section("Ile kart na okno") {
                        Stepper(value: $store.tabLimit, in: 1...30) {
                            Text("Pokazuj najwyżej \(store.tabLimit) \(store.tabLimit == 1 ? "kartę" : "kart") z każdego okna")
                        }
                        Text("Liczy się aktywna karta okna i te, które ostatnio były aktywne.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.browserMode.usesTabs {
                    section("Uwaga") {
                        Text("Odczyt kart wymaga zgody „Automatyzacja” dla każdej przeglądarki. W trybie „tylko okna” aplikacja nie wysyła do przeglądarek żadnych zapytań — tytuł okna i tak jest tytułem aktywnej karty.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var spacesExplanation: String {
        if SkyLight.canReadSpaces && SkyLight.canBringWindows {
            return "Okno z innego biurka ma plakietkę „Biurko 2” (numer jak w Mission Control), a jego wybór przełącza biurko tak jak kliknięcie w Docku. Aplikacje pełnoekranowe mają plakietkę „Pełny ekran”."
        }
        return "Ten macOS nie udostępnia informacji o biurkach. Okna spoza ekranu są oznaczone „Inne biurko”, a biurko przełącza sam system — o ile w ustawieniach Mission Control jest włączone „Przy przełączaniu na aplikację przełącz na biurko z jej otwartymi oknami”."
    }

    private var modeExplanation: String {
        switch store.browserMode {
        case .windowsOnly:
            return "Dwa okna Chrome = dwie pozycje na liście, podpisane tytułem aktywnej karty. Najbliżej zachowania paska zadań Windows."
        case .allTabs:
            return "Każda karta osobno. Przy kilkudziesięciu kartach lista robi się bardzo długa."
        case .recentTabs:
            return "Każde okno pokazuje aktywną kartę i kilka ostatnio używanych — kompromis między jednym a wszystkim."
        }
    }

    // MARK: Schowek

    private var schowek: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Historia kopiowania") {
                    Toggle("Zapamiętuj to, co kopiujesz", isOn: $store.historiaSchowka)
                    HStack {
                        Text("Skrót do historii")
                        KeyRecorder(combo: store.skrotSchowka) { store.skrotSchowka = $0 }
                    }
                    .disabled(!store.historiaSchowka)
                    Text("Otwiera listę skopiowanych rzeczy: pisz, żeby szukać, strzałki wybierają, Enter wkleja tam, gdzie właśnie piszesz. Obrazy i zrzuty ekranu pokazują się miniaturą.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Wklejanie bez formatowania") {
                    HStack {
                        Text("Skrót")
                        KeyRecorder(combo: store.skrotCzysty) { store.skrotCzysty = $0 }
                    }
                    Text("Wkleja to, co masz w schowku, jako czysty tekst — bez czcionki, koloru i tła ze strony, z której kopiowałeś. Działa w każdym programie, także w tych, które nie mają własnego „wklej i dopasuj styl”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Ile pamiętać") {
                    Stepper(value: $store.limitHistorii, in: 20...1000, step: 20) {
                        Text("Najwyżej \(store.limitHistorii) wpisów")
                    }
                    .disabled(!store.historiaSchowka)
                    Text("Przypięte wpisy zostają zawsze, niezależnie od tego limitu — od tego są przypięte. Historia leży wyłącznie na tym komputerze i nigdzie nie jest wysyłana.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Czego program nie zapisuje") {
                    Text("Treści oznaczonej przez inny program jako poufna — tak robią menedżery haseł. Hasło skopiowane z takiego programu nie trafia do historii ani na dysk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Wyczyść historię teraz") {
                        HistoriaSchowka.shared.wyczysc()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Zrzuty

    private var screenshots: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Zrzut zaznaczonego fragmentu") {
                    Toggle("Włącz skrót do zrzutu ekranu", isOn: $store.screenshotEnabled)
                    HStack {
                        Text("Skrót")
                        KeyRecorder(combo: store.screenshotCombo) { store.screenshotCombo = $0 }
                    }
                    .disabled(!store.screenshotEnabled)
                    Text("Zaznaczasz obszar myszką jak przy ⌘⇧4. Gotowy obraz trafia do schowka już skompresowany.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Kompresja") {
                    Picker("Format", selection: $store.screenshotFormat) {
                        ForEach(ScreenshotFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    HStack {
                        Text("Docelowy rozmiar pliku")
                        Spacer()
                        Text("\(store.screenshotMaxKB) kB")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(store.screenshotMaxKB) },
                        set: { store.screenshotMaxKB = Int($0) }
                    ), in: 200...5000, step: 100)
                    HStack {
                        Text("Dłuższy bok obrazu")
                        Spacer()
                        Text("\(store.screenshotMaxPixels) px")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(store.screenshotMaxPixels) },
                        set: { store.screenshotMaxPixels = Int($0) }
                    ), in: 800...4000, step: 100)
                    Text("Najpierw obniżana jest jakość, dopiero potem rozdzielczość — tekst na zrzucie zostaje czytelny.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Zapis na dysku") {
                    Toggle("Zapisuj też plik", isOn: $store.screenshotSaveToDisk)
                    HStack(spacing: 8) {
                        Text(store.screenshotFolder)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Zmień…") { store.chooseScreenshotFolder() }
                    }
                    .disabled(!store.screenshotSaveToDisk)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Skroty aplikacji

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Przypisz skrót do aplikacji")
                .font(.system(size: 13, weight: .semibold))
            Text("Pierwsze wciśnięcie przenosi do aplikacji, kolejne krążą po jej oknach. Jeśli aplikacja nie działa — zostanie uruchomiona.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.appShortcuts.isEmpty {
                Text("Nie masz jeszcze żadnych przypisań.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 26)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.appShortcuts) { shortcut in
                            HStack(spacing: 10) {
                                Text(shortcut.name)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                KeyRecorder(combo: shortcut.combo) { store.updateCombo(id: shortcut.id, combo: $0) }
                                Button {
                                    store.removeShortcut(id: shortcut.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Menu("Dodaj z uruchomionych") {
                    ForEach(AppLauncher.runningApplications(), id: \.bundleID) { app in
                        Button(app.name) { store.addShortcut(name: app.name, bundleID: app.bundleID) }
                    }
                }
                .frame(width: 200)

                Button("Wybierz z dysku…") {
                    guard let picked = AppLauncher.chooseFromDisk() else { return }
                    store.addShortcut(name: picked.name, bundleID: picked.bundleID)
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Aktualizacje

    private var updates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Wersja") {
                    Text("\(AppInfo.name) \(AppInfo.version) (build \(AppInfo.build))")
                        .font(.system(size: 12.5, weight: .medium))
                    if let last = Settings.lastUpdateCheck {
                        Text("Ostatnie sprawdzenie: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Sprawdź teraz") { Updater.shared.check(manual: true) }
                }

                section("Kanał aktualizacji") {
                    Toggle("Sprawdzaj automatycznie raz dziennie", isOn: $store.autoCheckUpdates)
                    TextField("https://twoj-serwer/klyo-switcher/appcast.json", text: $store.updateFeed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                    Text("Adres pliku JSON z polami: version, build, notes, installScriptURL. Aktualizacja pobiera wskazany skrypt i buduje z niego nową wersję na tym Macu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Pomocnicze

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}
