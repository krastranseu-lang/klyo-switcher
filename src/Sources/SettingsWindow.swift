import AppKit
import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case general
    case schowek
    case browsers
    case screenshots
    case shortcuts
    case updates

    var id: String { rawValue }

    var nazwa: String {
        switch self {
        case .general: return "Ogólne"
        case .schowek: return "Schowek"
        case .browsers: return "Przeglądarki"
        case .screenshots: return "Zrzuty ekranu"
        case .shortcuts: return "Skróty do programów"
        case .updates: return "Aktualizacje"
        }
    }

    var ikona: String {
        switch self {
        case .general: return "gearshape"
        case .schowek: return "doc.on.clipboard"
        case .browsers: return "safari"
        case .screenshots: return "camera.viewfinder"
        case .shortcuts: return "command"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }

    /// Kolor kafelka ikony w pasku bocznym.
    ///
    /// Ustawienia systemowe macOS oznaczają każdą pozycję innym kolorem i ludzie
    /// odnajdują ją wzrokiem po kolorze, zanim przeczytają nazwę (Prawo Jakoba:
    /// nie wymyślamy własnych konwencji tam, gdzie użytkownik zna cudze).
    var kolorIkony: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .schowek: return Color(nsColor: .systemOrange)
        case .browsers: return Color(nsColor: .systemBlue)
        case .screenshots: return Color(nsColor: .systemGreen)
        case .shortcuts: return Color(nsColor: .systemPurple)
        case .updates: return Color(nsColor: .systemTeal)
        }
    }

    /// Jedno zdanie, po co tu wchodzic - zeby nie trzeba bylo klikac po kolei
    /// i sprawdzac, co sie gdzie chowa.
    var opis: String {
        switch self {
        case .general: return "Skrót przełącznika, biurka, wygląd listy, autostart"
        case .schowek: return "Historia kopiowania i wklejanie bez formatowania"
        case .browsers: return "Czy pokazywać karty przeglądarek"
        case .screenshots: return "Zrzut zaznaczonego fragmentu i kompresja"
        case .shortcuts: return "Własny klawisz do wybranego programu"
        case .updates: return "Wersja i kanał aktualizacji"
        }
    }
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
    /// Co widac po najechaniu mysza na karte - wybierane rysunkiem, patrz `WyborWygladu`.
    @Published var trybPodgladu: TrybPodgladu = .duzy {
        didSet { commit { Settings.trybPodgladu = trybPodgladu } }
    }
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

    // Przerabianie wklejanej tresci. Kazda zmiana idzie od razu do podsluchu
    // klawiatury (`SettingsBus`), bo to on decyduje, czy ⌘V ma byc przechwytywane.
    @Published var wklejajCzysty: Bool = false {
        didSet { Settings.wklejajCzystyTekst = wklejajCzysty; SettingsBus.announce() }
    }
    @Published var wklejajPrzycinaj: Bool = false {
        didSet { Settings.wklejajPrzycinaj = wklejajPrzycinaj; SettingsBus.announce() }
    }
    @Published var wklejajBezDoczepek: Bool = false {
        didSet { Settings.wklejajBezDoczepek = wklejajBezDoczepek; SettingsBus.announce() }
    }

    @Published var screenshotEnabled: Bool = true { didSet { commit { Settings.screenshotEnabled = screenshotEnabled } } }
    @Published var screenshotCombo: KeyCombo = .unset { didSet { commit { Settings.screenshotCombo = screenshotCombo } } }
    @Published var screenshotMaxKB: Int = 1200 { didSet { commit { Settings.screenshotMaxKB = screenshotMaxKB } } }
    @Published var screenshotMaxPixels: Int = 2400 { didSet { commit { Settings.screenshotMaxPixels = screenshotMaxPixels } } }
    @Published var screenshotFormat: ScreenshotFormat = .jpeg { didSet { commit { Settings.screenshotFormat = screenshotFormat } } }

    /// Czy system ma przełączać biurko przy przejściu do okna.
    ///
    /// To ustawienie należy do macOS (`AppleSpacesSwitchOnActivate`), nie do nas —
    /// ale dla człowieka jest po prostu funkcją przełącznika okien i tu jest jego
    /// miejsce. Zapis przeładowuje Dock, żeby zaczęło działać od razu, a nie po
    /// wylogowaniu.
    @Published var przelaczajBiurka: Bool = PrzelaczanieBiurek.wlaczone {
        didSet {
            guard oldValue != przelaczajBiurka else { return }
            commit {
                PrzelaczanieBiurek.ustaw(przelaczajBiurka)
                // Razem z tym ustawieniem wlaczamy systemowe skroty „Przelacz na
                // Biurko N" - to nimi program prosi macOS o prawdziwe przejscie.
                if przelaczajBiurka {
                    SkrotyBiurekSystemu.wlacz(ile: max(1, Spaces.map().desktopNumbers.count))
                }
            }
        }
    }
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
        trybPodgladu = Settings.trybPodgladu
        historiaSchowka = Settings.historiaSchowkaWlaczona
        limitHistorii = Settings.limitHistoriiSchowka
        skrotSchowka = Settings.skrotHistoriiSchowka
        skrotCzysty = Settings.skrotCzystegoTekstu
        wklejajCzysty = Settings.wklejajCzystyTekst
        wklejajPrzycinaj = Settings.wklejajPrzycinaj
        wklejajBezDoczepek = Settings.wklejajBezDoczepek
        screenshotEnabled = Settings.screenshotEnabled
        screenshotCombo = Settings.screenshotCombo
        screenshotMaxKB = Settings.screenshotMaxKB
        screenshotMaxPixels = Settings.screenshotMaxPixels
        screenshotFormat = Settings.screenshotFormat
        przelaczajBiurka = PrzelaczanieBiurek.wlaczone
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
    @State private var szukaj = ""
    /// Licznik odświeżania zgód. Zgody zmieniają się POZA programem (w Ustawieniach
    /// systemowych), więc bez pytania co chwilę okno pokazywałoby stan sprzed zmiany.
    @State private var odswiezZgody = 0

    /// Wyszukiwanie po nazwie I po opisie — człowiek pamięta zwykle funkcję
    /// („autostart"), a nie kategorię, w której ją schowaliśmy.
    private var widoczneSekcje: [SettingsTab] {
        let fraza = szukaj.trimmingCharacters(in: .whitespaces).lowercased()
        guard !fraza.isEmpty else { return SettingsTab.allCases }
        let znalezione = SettingsTab.allCases.filter {
            $0.nazwa.lowercased().contains(fraza) || $0.opis.lowercased().contains(fraza)
        }
        // Pusty wynik wyszukiwania nie może zostawić pustego paska bocznego —
        // wtedy okno wygląda na zepsute. Lepiej pokazać wszystko.
        return znalezione.isEmpty ? SettingsTab.allCases : znalezione
    }

    var body: some View {
        NavigationSplitView {
            List(widoczneSekcje, selection: Binding(
                get: { store.tab },
                set: { store.tab = $0 ?? store.tab }
            )) { sekcja in
                HStack(spacing: 9) {
                    // Ikona na kolorowym kafelku - dokladnie tak wyglada pasek
                    // boczny Ustawien systemowych. Rozmiar 20 pt i promien 5 pt
                    // to wymiary, ktorych uzywa system.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(sekcja.kolorIkony)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: sekcja.ikona)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                        )
                    Text(sekcja.nazwa)
                }
                .padding(.vertical, 1)
                .tag(sekcja)
            }
            .listStyle(.sidebar)
            .searchable(text: $szukaj, placement: .sidebar, prompt: "Szukaj")
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                naglowek
                Divider().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        zawartosc
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 800, height: 590)
    }

    /// Naglowek mowi, gdzie jestes i po co - bez tego okno ustawien jest zbiorem
    /// przelacznikow, w ktorym trzeba klikac na oslep.
    private var naglowek: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: store.tab.ikona)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.tab.nazwa).font(.system(size: 15, weight: .semibold))
                Text(store.tab.opis).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            znacznikGotowosci
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    /// Jedno spojrzenie zamiast wchodzenia w Ustawienia systemowe: czy program
    /// w ogole moze dzialac.
    private var znacznikGotowosci: some View {
        let gotowy = Permissions.accessibilityGranted
        return HStack(spacing: 6) {
            Circle()
                .fill(gotowy ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(gotowy ? "Gotowy do pracy" : "Czeka na zgodę „Dostępność”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private var zawartosc: some View {
        switch store.tab {
        case .general: general
        case .schowek: schowek
        case .browsers: browsers
        case .screenshots: screenshots
        case .shortcuts: shortcuts
        case .updates: updates
        }
    }

    // MARK: Ogolne

    private var general: some View {
        Group {
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

                    Divider().padding(.vertical, 2)

                    // To jest ustawienie SYSTEMU, ale człowiek nie ma powodu go
                    // szukać w Ustawieniach macOS — dla niego to po prostu funkcja
                    // przełącznika okien. Odsyłanie do cudzego panelu jest
                    // przerzucaniem naszej roboty na użytkownika.
                    Toggle("Przełączaj biurko przy wyborze okna", isOn: $store.przelaczajBiurka)
                    HStack(spacing: 8) {
                        Button("Skopiuj raport o biurkach") {
                            // Raport mówi, czy prywatne funkcje systemu w ogóle
                            // odpowiadają i co dokładnie stało się przy ostatnim
                            // przeskoku. Bez niego pozostaje zgadywanie.
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DziennikBiurek.tresc(), forType: .string)
                            ToastPresenter.shared.show("Raport skopiowany — wklej go w wiadomości.",
                                                       symbol: "doc.on.clipboard")
                        }
                        .controlSize(.small)
                        Text("Gdy przełączanie biurek nie działa — skopiuj i przyślij.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(store.przelaczajBiurka
                         ? "Wybór okna z innego biurka przenosi Cię na tamto biurko. Program włącza w tym celu systemowe skróty „Przełącz na Biurko 1…9” (Ctrl+1…9, Ustawienia → Klawiatura → Skróty → Mission Control) i nimi prosi macOS o przejście — jak z klawiatury."
                         : "Wyłączone: wybór okna z innego biurka NIE zmieni biurka. To ograniczenie systemu, nie programu — macOS pyta o tę zgodę raz i zapamiętuje ją dla wszystkich programów.")
                        .font(.caption)
                        .foregroundStyle(store.przelaczajBiurka ? .secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Pod kursorem") {
                    WyborTrybuPodgladu(wybor: $store.trybPodgladu)
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
                    VStack(alignment: .leading, spacing: 10) {
                        wierszZgody(
                            nazwa: "Dostępność",
                            opis: "Bez niej ⌘ Tab nie dochodzi do programu — system pokazuje swój przełącznik.",
                            stan: Permissions.accessibilityGranted ? .nadana : .brak,
                            akcja: Permissions.openAccessibilitySettings
                        )
                        Divider().opacity(0.4)
                        wierszZgody(
                            nazwa: "Nagrywanie ekranu",
                            opis: "Bez niej karty pokazują ikony zamiast podglądu okien i nie znają tytułów.",
                            stan: Permissions.screenRecordingGranted ? .nadana : .brak,
                            akcja: Permissions.openScreenRecordingSettings
                        )
                        ForEach(zgodyPrzegladarek(), id: \.bundleID) { zgoda in
                            Divider().opacity(0.4)
                            wierszZgody(
                                nazwa: "Automatyzacja — \(zgoda.nazwa)",
                                opis: zgoda.opis,
                                stan: zgoda.stan,
                                akcja: Permissions.openAutomationSettings
                            )
                        }
                    }
                    .id(odswiezZgody)
                }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                    odswiezZgody &+= 1
                }
            }
        }
    }

    // MARK: Przegladarki

    private var browsers: some View {
        Group {
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
        Group {
            VStack(alignment: .leading, spacing: 18) {
                section("Wklejanie pod ⌘V") {
                    Toggle("Wklejaj bez formatowania", isOn: $store.wklejajCzysty)
                    Toggle("Przycinaj spacje i puste wiersze na końcach", isOn: $store.wklejajPrzycinaj)
                    Toggle("Czyść adresy z doczepek śledzących (utm_…, fbclid)", isOn: $store.wklejajBezDoczepek)
                    Text("""
                        Zmiana dzieje się w chwili wklejania: program podmienia schowek, \
                        wysyła ⌘V i od razu oddaje schowkowi to, co w nim było. Skopiowana \
                        tabelka dalej wklei się z formatowaniem wszędzie indziej. \
                        Gdy wszystkie trzy są wyłączone — a tak jest domyślnie — program \
                        nie dotyka ⌘V w ogóle.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
        }
    }

    // MARK: Zrzuty

    private var screenshots: some View {
        Group {
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
        Group {
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
        }
    }

    // MARK: Pomocnicze

    /// Stan pojedynczej zgody. `nieznana` istnieje dlatego, ze o zgodę na
    /// automatyzację nie da się zapytać po cichu — a zielona kropka postawiona
    /// „na oko" byłaby atrapą: mówiłaby, że jest dobrze, nie wiedząc tego.
    enum StanZgody {
        case nadana
        case brak
        case nieznana

        var barwa: Color {
            switch self {
            case .nadana: return .green
            case .brak: return .orange
            case .nieznana: return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .nadana: return "checkmark.circle.fill"
            case .brak: return "exclamationmark.triangle.fill"
            case .nieznana: return "questionmark.circle"
            }
        }

        var podpis: String {
            switch self {
            case .nadana: return "nadana"
            case .brak: return "brak"
            case .nieznana: return "nie wiadomo"
            }
        }
    }

    /// Zgoda na automatyzowanie jednej przeglądarki - stan pytamy systemu, nie zgadujemy.
    struct ZgodaPrzegladarki: Identifiable {
        let bundleID: String
        let nazwa: String
        let stan: StanZgody
        let opis: String
        var id: String { bundleID }
    }

    /// Wiersze dla przeglądarek, które teraz działają. Program, którego nie ma,
    /// nie ma stanu zgody — i lepiej go nie pokazywać, niż pokazywać znak zapytania.
    private func zgodyPrzegladarek() -> [ZgodaPrzegladarki] {
        var widziane = Set<String>()
        var wynik: [ZgodaPrzegladarki] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  BrowserSupport.isSupported(bundleID),
                  widziane.insert(bundleID).inserted else { continue }
            let nazwa = app.localizedName ?? bundleID
            var stan: StanZgody = .nieznana
            var opis = ""
            switch Permissions.automatyzacja(bundleID: bundleID) {
            case .nadana:
                stan = .nadana
                opis = "Karty tej przeglądarki mogą trafiać na listę okien."
            case .odmowa:
                stan = .brak
                opis = "Odmowa w Ustawieniach systemowych — karty się nie pokażą, zostaną same okna przeglądarki."
            case .niePytano:
                stan = .nieznana
                opis = "System jeszcze nie pytał — zapyta przy pierwszej próbie odczytania kart."
            case .nieDziala:
                stan = .nieznana
                opis = "Program nie odpowiada — nie ma o co pytać."
            case .blad(let kod):
                stan = .nieznana
                opis = "System odpowiedział błędem \(kod)."
            }
            wynik.append(ZgodaPrzegladarki(bundleID: bundleID, nazwa: nazwa, stan: stan, opis: opis))
        }
        return wynik.sorted { $0.nazwa < $1.nazwa }
    }

    /// Jeden wiersz zgody: widać stan, po co ona jest i gdzie ją włączyć.
    /// Wartości liczone do zwykłych `let`, bo kompilator SwiftUI dławi się
    /// długimi łańcuchami z warunkami w środku (patrz Uprawnienia.swift).
    private func wierszZgody(nazwa: String, opis: String, stan: StanZgody,
                             akcja: @escaping () -> Void) -> some View {
        let barwa = stan.barwa
        let tlo = stan == .nadana ? Color.green.opacity(0.12) : Color.primary.opacity(0.06)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: stan.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(barwa)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(nazwa)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(stan.podpis)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(barwa)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tlo))
                }
                Text(opis)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Otwórz…", action: akcja)
                .controlSize(.small)
        }
    }

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
