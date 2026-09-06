import AppKit
import SwiftUI

/// Znacznik "juz nieaktualne" bezpieczny miedzy watkami - watek miniatur sprawdza go
/// przed kazdym zrzutem, wiec szybkie ⌘⇥ nie zostawia za soba sekundy pracy w tle.
final class CancelToken {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Steruje cala sesja przelaczania: zbiera okna, pokazuje HUD, przesuwa zaznaczenie
/// i na koniec przenosi fokus na wybrane okno lub karte przegladarki.
///
/// Niezmiennik czasu: wszystko, co wola podsluch klawiatury (`cycle`, `commit`, `cancel`),
/// wraca natychmiast. Spis okien i rozmowa z aplikacja docelowa ida na glowna kolejke
/// w nastepnym obiegu petli zdarzen - podsluch nigdy nie czeka na cudza aplikacje.
final class SwitcherController {
    let hotkey = HotkeyRouter()
    let browsers = BrowserTabIndex()
    let usage = WindowUsageTracker()

    private let model = SwitcherModel()
    private let enumerator = WindowEnumerator()
    private let thumbnailQueue = DispatchQueue(label: "pl.klyo.switcher.thumbnails", qos: .userInitiated)
    private let thumbnailBatchSize = 4

    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherView>?
    private var sessionActive = false
    private var generation = 0
    private var thumbnailToken: CancelToken?
    /// Znacznik zamowienia duzego podgladu - kazde nowe uniewaznia poprzednie.
    private var podgladToken: CancelToken?
    private var watchdog: Timer?
    private var idleCleanup: Timer?

    /// Sesja w przygotowaniu: pierwsze ⌘⇥ tylko ZAMAWIA liste, a buduje ja nastepny
    /// obieg petli. Klawisze wcisniete w tym oknie czasu nie gina - sa doliczane.
    private var beginPending = false
    private var pendingSteps = 0
    private var pendingCommit = false
    private var pendingCancel = false

    func start() {
        model.onPick = { [weak self] index in
            self?.model.selection = index
            self?.commit()
        }
        model.onClose = { [weak self] index in
            self?.closeItem(at: index)
        }
        model.onQuit = { [weak self] index in
            self?.quitApplication(at: index, force: false)
        }
        model.onPrzypnij = { [weak self] index in
            self?.przelaczUlubione(at: index)
        }

        // Sesja "trwa" takze w oknie miedzy zamowieniem listy a jej pokazaniem - inaczej
        // puszczenie modyfikatora przy szybkim ⌘⇥ trafialoby w prozni i HUD zostawalby otwarty.
        hotkey.isSessionActive = { [weak self] in
            guard let self else { return false }
            return self.sessionActive || self.beginPending
        }
        hotkey.onCycle = { [weak self] forward in self?.cycle(forward: forward) }
        hotkey.onArrow = { [weak self] direction in self?.move(direction) }
        hotkey.onSelectIndex = { [weak self] index in self?.select(index) }
        hotkey.onSzukaj = { [weak self] znak in
            guard let self, self.sessionActive else { return }
            self.model.dopiszDoFrazy(znak)
            self.przeliczRozmiar()
            self.startWatchdog()
        }
        hotkey.onKasujZnak = { [weak self] in
            guard let self, self.sessionActive else { return }
            self.model.skasujZnakFrazy()
            self.przeliczRozmiar()
            self.startWatchdog()
        }
        hotkey.onCommit = { [weak self] in self?.commit() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.onPrzypnijUlubione = { [weak self] in
            self?.przelaczUlubione(at: self?.model.selection ?? 0)
        }
        hotkey.onCloseSelected = { [weak self] in
            guard let self else { return }
            self.closeItem(at: self.model.selection)
        }
        hotkey.onQuitSelected = { [weak self] force in
            guard let self else { return }
            self.quitApplication(at: self.model.selection, force: force)
        }
        // Panel szybkich akcji: przytrzymanie modyfikatora. Spis okien bierze
        // stad, zeby nie zbierac go drugi raz wlasnym kodem.
        hotkey.onSzybkieAkcje = { [weak self] in
            guard let self else { return }
            SzybkieAkcjeController.shared.zbierzOkna = { [weak self] in
                guard let self else { return [] }
                return self.enumerator.snapshot(browsers: self.browsers, usage: self.usage)
            }
            SzybkieAkcjeController.shared.przegladarki = self.browsers
            SzybkieAkcjeController.shared.przelacz()
        }

        hotkey.onPermissionGranted = { [weak self] in
            self?.browsers.attachPendingObservers()
            self?.browsers.refresh(after: 0.3)
            self?.usage.attachPendingObservers()
        }

        // Kursor na karcie zamawia OSTRY zrzut tego jednego okna. Robimy go dopiero
        // na zadanie, bo w takiej rozdzielczosci wszystkie karty naraz zajelyby
        // dziesiatki megabajtow - a czyta sie i tak jedno okno naraz.
        model.onZmianaKursora = { [weak self] identyfikator in
            self?.zamowDuzyPodglad(identyfikator)
        }

        // Kolejnosc kart zmienia sie wylacznie po POTWIERDZONYM przelaczeniu -
        // patrz komentarz w `switchTo`.
        Wierzch.poUdanymPrzelaczeniu = { [weak self] windowID, pid in
            self?.usage.noteSelection(windowID: windowID, pid: pid)
        }

        // Przelaczanie biurek wlaczone -> systemowe skroty „Przelacz na Biurko N"
        // maja byc gotowe, zanim ktos pierwszy raz wybierze okno z innego biurka.
        // Liczba biurek moze urosnac miedzy startami, stad sprawdzanie przy kazdym.
        if PrzelaczanieBiurek.wlaczone {
            DispatchQueue.global(qos: .utility).async {
                SkrotyBiurekSystemu.wlacz(ile: max(1, Spaces.map().desktopNumbers.count))
            }
        }

        usage.start()
        browsers.start()
        // Okno zgod nie ma jak zapytac systemu o zgode „Automatyzacja" wprost,
        // wiec patrzy na skutek: czy karty przegladarek naprawde sie czytaja.
        browsers.onZmianaKart = { ile in
            HistoriaKartPrzegladarki.brakKart = (ile == 0)
        }
        hotkey.install()
    }

    /// Spis okien dla panelu szybkich akcji - ten sam, ktory widzi ⌘⇥.
    func spisOkienDlaAkcji() -> [SwitcherItem] {
        enumerator.snapshot(browsers: browsers, usage: usage)
    }

    // MARK: - Zamykanie z poziomu przelacznika

    private func closeItem(at index: Int) {
        guard sessionActive, model.items.indices.contains(index) else { return }
        let item = model.items[index]
        WindowActions.close(item)
        remove(indexes: [index])
        browsers.refresh(after: 0.6)
    }

    /// Przypiecie programu wybranej karty do ulubionych albo cofniecie przypiecia.
    /// Lista przerysowuje sie od razu, wiec czlowiek widzi skutek, zanim puscil ⌘.
    private func przelaczUlubione(at index: Int) {
        guard sessionActive, model.items.indices.contains(index) else { return }
        let pozycja = model.items[index]
        guard !pozycja.bundleID.isEmpty else { return }
        let przypiety = Ulubione.przelaczPrzypiecie(pozycja.bundleID)
        model.odswiezUlubione()
        ToastPresenter.shared.show(
            przypiety ? "\(pozycja.subtitle) w ulubionych" : "\(pozycja.subtitle) już nie w ulubionych",
            symbol: przypiety ? "star.fill" : "star.slash"
        )
    }

    private func quitApplication(at index: Int, force: Bool) {
        guard sessionActive, model.items.indices.contains(index) else { return }
        let pid = model.items[index].pid
        WindowActions.quitApplication(pid: pid, force: force)
        let doomed = model.items.enumerated().filter { $0.element.pid == pid }.map { $0.offset }
        remove(indexes: doomed)
        browsers.refresh(after: 0.8)
    }

    /// Lista kurczy sie w miejscu - uzytkownik wciaz trzyma modyfikator, wiec HUD
    /// zostaje otwarty i tylko przelicza swoj rozmiar.
    private func remove(indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        let doomed = Set(indexes)
        var items = model.items
        let anchor = indexes.min() ?? 0
        items = items.enumerated().filter { !doomed.contains($0.offset) }.map { $0.element }
        guard !items.isEmpty else {
            hide()
            return
        }
        model.items = items
        model.selection = min(anchor, items.count - 1)
        model.hoveredID = nil
        if let panel, let screen = panel.screen ?? NSScreen.main {
            let size = HUDLayout.panelSize(count: items.count, columns: model.columns)
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }
        startWatchdog()
    }

    // MARK: - Sesja

    private func cycle(forward: Bool) {
        let step = forward ? 1 : -1
        if sessionActive {
            advance(by: step)
            return
        }
        if beginPending {
            pendingSteps += step
            return
        }
        beginPending = true
        pendingSteps = step
        pendingCommit = false
        pendingCancel = false
        DispatchQueue.main.async { [weak self] in self?.begin() }
    }

    private func begin() {
        guard beginPending else { return }
        beginPending = false
        if pendingCancel {
            pendingCancel = false
            pendingCommit = false
            return
        }

        var items = enumerator.snapshot(browsers: browsers, usage: usage)
        guard !items.isEmpty else {
            pendingCommit = false
            return
        }

        let screen = activeScreen()
        let columns = HUDLayout.columns(for: items.count, screenWidth: screen.frame.width)
        // Przy setkach kart obcinamy liste do tego, co realnie miesci sie na ekranie -
        // najswiezej uzywane okna sa na poczatku, wiec zostaja widoczne.
        let capacity = columns * HUDLayout.maxRows(screenHeight: screen.visibleFrame.height)
        if items.count > capacity {
            items = Array(items.prefix(capacity))
        }
        let count = items.count
        let selection = count > 1 ? ((pendingSteps % count) + count) % count : 0

        if pendingCommit || !hotkey.isSwitcherModifierHeld {
            // Szybkie ⌘⇥: modyfikator puszczony, zanim lista zdazyla sie narysowac -
            // przelaczamy od razu, bez migniecia HUD-em. Fizyczny stan klawiatury jest tu
            // druga prawda na wypadek, gdyby samo zdarzenie zwolnienia zginelo.
            pendingCommit = false
            switchTo(items[selection])
            return
        }

        idleCleanup?.invalidate()
        idleCleanup = nil
        generation &+= 1
        model.ustawWszystkie(items)
        model.columns = columns
        model.selection = selection
        model.wyczyscPodswietlenie()

        showPanel(on: screen, itemCount: count)
        sessionActive = true
        startWatchdog()
        captureThumbnails(for: generation)
    }

    /// Po zmianie frazy lista ma inna dlugosc, wiec okno HUD-a musi sie przeliczyc -
    /// inaczej zostaje puste miejsce albo karty wychodza poza ramke.
    private func przeliczRozmiar() {
        guard sessionActive, let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let liczba = max(1, model.items.count)
        let kolumny = HUDLayout.columns(for: liczba, screenWidth: screen.frame.width)
        model.columns = kolumny
        let size = HUDLayout.panelSize(count: liczba, columns: kolumny)
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                   width: size.width, height: size.height),
            display: true
        )
    }

    private func odswiezPoZmianieFrazy() {
        przeliczRozmiar()
        startWatchdog()
    }

    private func advance(by delta: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        model.selection = ((model.selection + delta) % count + count) % count
        startWatchdog()
    }

    private func move(_ direction: ArrowDirection) {
        guard sessionActive else { return }
        model.move(direction)
        startWatchdog()
    }

    private func select(_ index: Int) {
        guard sessionActive, model.items.indices.contains(index) else { return }
        model.selection = index
        startWatchdog()
    }

    private func commit() {
        if beginPending {
            pendingCommit = true
            return
        }
        guard sessionActive else { return }
        let item = model.selectedItem
        hide()
        if let item {
            switchTo(item)
        } else {
            browsers.refresh(after: 0.7)
        }
    }

    private func cancel() {
        if beginPending {
            pendingCancel = true
            return
        }
        guard sessionActive else { return }
        // Pomylka w pisaniu nie moze kosztowac calej sesji: pierwszy Esc kasuje fraze,
        // dopiero drugi zamyka liste.
        if !model.fraza.isEmpty {
            model.ustawWszystkie(model.items.isEmpty ? [] : model.items)
            odswiezPoZmianieFrazy()
            return
        }
        hide()
        browsers.refresh(after: 0.7)
    }

    private func switchTo(_ item: SwitcherItem) {
        // Historia uzycia zapisuje sie DOPIERO po potwierdzonym przelaczeniu -
        // robi to `Wierzch.poUdanymPrzelaczeniu`, wpiete w `start()`.
        //
        // Wczesniej zapisywalismy sam ZAMIAR, wiec kolejnosc kart zmieniala sie
        // takze po probie, ktora sie nie powiodla. Objaw zglosil wlasciciel:
        // „jak zrobie ⌘⇥ i szybko otworze jeszcze raz, widze, jak okienko zmienia
        // pozycje - musi juz stac na pierwszej".
        //
        // Karta przegladarki nie ma numeru okna, wiec nie ma czego sprawdzic -
        // dla niej zapisujemy od razu, jak dotad.
        if item.windowID == 0 {
            usage.noteSelection(windowID: 0, pid: item.pid)
        }
        // Każdy wybór buduje obraz tego, do czego naprawdę wracasz — stąd biorą
        // się gwiazdki na kartach.
        Ulubione.zapiszWybor(identyfikator: item.bundleID)
        // Rozmowa z aplikacja docelowa (Accessibility, AppleScript) moze potrwac -
        // idzie poza callbackiem podsluchu, ktory ma juz byc wolny.
        let browsers = self.browsers
        DispatchQueue.main.async {
            WindowActivator.activate(item, browsers: browsers)
            browsers.refresh(after: 0.7)
        }
    }

    private func hide() {
        sessionActive = false
        watchdog?.invalidate()
        watchdog = nil
        thumbnailToken?.cancel()
        thumbnailToken = nil
        podgladToken?.cancel()
        podgladToken = nil
        model.duzyPodglad = nil
        panel?.orderOut(nil)
        scheduleIdleCleanup()
    }

    /// Po minucie bezczynnosci oddajemy systemowi cala pamiec HUD-a: miniatury,
    /// warstwe SwiftUI i samo okno. Kolejne otwarcie odbuduje je w ulamku sekundy,
    /// a w miedzyczasie aplikacja siedzi w pamieci jako kilka megabajtow kodu.
    private func scheduleIdleCleanup() {
        idleCleanup?.invalidate()
        let timer = Timer(timeInterval: 60.0, repeats: false) { [weak self] _ in
            guard let self, !self.sessionActive else { return }
            self.idleCleanup = nil
            self.model.items = []
            self.model.selection = 0
            self.model.duzyPodglad = nil
            self.hostingView = nil
            self.panel?.contentView = nil
            self.panel?.close()
            self.panel = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        idleCleanup = timer
    }

    /// Zabezpieczenie na wypadek zgubienia zdarzenia zwolnienia modyfikatora. Pyta
    /// klawiature o fizyczny stan: dopoki klawisz jest trzymany, uzytkownik moze czytac
    /// liste dowolnie dlugo - HUD znika tylko wtedy, gdy klawisz naprawde puszczono.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self, self.sessionActive else { return }
            if self.hotkey.isSwitcherModifierHeld {
                self.startWatchdog()
            } else {
                self.cancel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - Okno HUD

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func showPanel(on screen: NSScreen, itemCount: Int) {
        let panel = ensurePanel()
        let size = HUDLayout.panelSize(count: itemCount, columns: model.columns)
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.isReleasedWhenClosed = false
        created.level = .popUpMenu
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.isMovable = false
        created.ignoresMouseEvents = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: SwitcherView(model: model))
        hosting.autoresizingMask = [.width, .height]
        created.contentView = hosting

        panel = created
        hostingView = hosting
        return created
    }

    // MARK: - Duzy podglad pod kursorem

    /// Zamawia ostry zrzut okna, na ktorym stoi kursor.
    ///
    /// Krotka zwloka przed zrzutem jest po to, zeby przejechanie mysza przez
    /// polowe listy nie zamawialo dziesieciu zrzutow po drodze - liczy sie karta,
    /// na ktorej kursor ZOSTAL.
    private func zamowDuzyPodglad(_ identyfikator: String?) {
        podgladToken?.cancel()
        guard let identyfikator, Settings.trybPodgladu == .duzy,
              Settings.showThumbnails, Permissions.screenRecordingGranted,
              let pozycja = model.items.first(where: { $0.id == identyfikator }),
              pozycja.windowID != 0 else {
            model.duzyPodglad = nil
            return
        }
        let token = CancelToken()
        podgladToken = token
        let okno = pozycja.windowID
        let pokolenie = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !token.isCancelled, self.sessionActive, self.generation == pokolenie else { return }
            self.thumbnailQueue.async { [weak self] in
                guard !token.isCancelled,
                      let obraz = WindowThumbnails.capture(windowID: okno, maxWidth: 1600) else { return }
                DispatchQueue.main.async {
                    guard let self, !token.isCancelled, self.sessionActive,
                          self.generation == pokolenie, self.model.hoveredID == identyfikator else { return }
                    self.model.duzyPodglad = (id: identyfikator, obraz: obraz)
                }
            }
        }
    }

    // MARK: - Miniatury

    private func captureThumbnails(for generation: Int) {
        guard Settings.showThumbnails, Permissions.screenRecordingGranted else { return }
        let targets = model.items.compactMap { item -> (String, CGWindowID)? in
            item.windowID != 0 ? (item.id, item.windowID) : nil
        }
        guard !targets.isEmpty else { return }
        let token = CancelToken()
        thumbnailToken = token
        let batchSize = thumbnailBatchSize
        thumbnailQueue.async { [weak self] in
            var batch: [(id: String, image: NSImage)] = []
            func flush() {
                guard !batch.isEmpty else { return }
                let ready = batch
                batch = []
                DispatchQueue.main.async {
                    guard let self, self.sessionActive, self.generation == generation else { return }
                    self.model.setThumbnails(ready)
                }
            }
            for (identifier, windowID) in targets {
                if token.isCancelled { return }
                guard let image = WindowThumbnails.capture(windowID: windowID, maxWidth: 560) else { continue }
                batch.append((id: identifier, image: image))
                if batch.count >= batchSize {
                    flush()
                }
            }
            flush()
        }
    }
}
