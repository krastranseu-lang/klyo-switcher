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
        model.onHover = { [weak self] index in
            guard let self, self.sessionActive else { return }
            self.model.selection = index
        }
        model.onClose = { [weak self] index in
            self?.closeItem(at: index)
        }
        model.onQuit = { [weak self] index in
            self?.quitApplication(at: index, force: false)
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
        hotkey.onCommit = { [weak self] in self?.commit() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.onCloseSelected = { [weak self] in
            guard let self else { return }
            self.closeItem(at: self.model.selection)
        }
        hotkey.onQuitSelected = { [weak self] force in
            guard let self else { return }
            self.quitApplication(at: self.model.selection, force: force)
        }
        hotkey.onPermissionGranted = { [weak self] in
            self?.browsers.attachPendingObservers()
            self?.browsers.refresh(after: 0.3)
            self?.usage.attachPendingObservers()
        }

        usage.start()
        browsers.start()
        hotkey.install()
    }

    // MARK: - Zamykanie z poziomu przelacznika

    private func closeItem(at index: Int) {
        guard sessionActive, model.items.indices.contains(index) else { return }
        let item = model.items[index]
        WindowActions.close(item)
        remove(indexes: [index])
        browsers.refresh(after: 0.6)
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
        model.items = items
        model.columns = columns
        model.selection = selection
        model.resetPointer(origin: NSEvent.mouseLocation)

        showPanel(on: screen, itemCount: count)
        sessionActive = true
        startWatchdog()
        captureThumbnails(for: generation)
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
        hide()
        browsers.refresh(after: 0.7)
    }

    private func switchTo(_ item: SwitcherItem) {
        // Historia uzycia aktualizuje sie od razu, a nie dopiero gdy system
        // przesle powiadomienie o zmianie aktywnej aplikacji.
        usage.noteSelection(windowID: item.windowID, pid: item.pid)
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
                guard let image = WindowThumbnails.capture(windowID: windowID, maxWidth: 320) else { continue }
                batch.append((id: identifier, image: image))
                if batch.count >= batchSize {
                    flush()
                }
            }
            flush()
        }
    }
}
