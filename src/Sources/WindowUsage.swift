import AppKit
import ApplicationServices

/// Pamiec kolejnosci uzywania okien - to, czego brakowalo, zeby przelacznik zachowywal sie
/// jak Alt+Tab w Windows: pierwsza pozycja to okno biezace, druga to poprzednie, dalej
/// coraz starsze. Spis systemowy `CGWindowList` podaje kolejnosc rysowania na ekranie,
/// a nie kolejnosc uzywania - dla okien z innych pulpitow i zminimalizowanych sa to
/// zupelnie rozne rzeczy.
final class WindowUsageTracker {
    private var sequence: [CGWindowID: UInt64] = [:]
    private var owner: [CGWindowID: pid_t] = [:]
    private var counter: UInt64 = 0
    private var observers: [pid_t: AXObserver] = [:]
    private var pendingBump: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        seedFromScreenOrder()
        if let front = NSWorkspace.shared.frontmostApplication {
            observe(pid: front.processIdentifier)
            scheduleBump(pid: front.processIdentifier, delay: 0.1)
        }
    }

    // MARK: - Odczyt

    /// Wieksza wartosc = uzywane pozniej. `nil` oznacza okno, ktorego jeszcze nie widzielismy.
    func order(for windowID: CGWindowID) -> UInt64? {
        guard windowID != 0 else { return nil }
        return sequence[windowID]
    }

    /// Najswiezsze okno danej aplikacji - uzywane przy sortowaniu kart przegladarki,
    /// ktore nie maja wlasnego identyfikatora okna systemowego.
    func appOrder(for pid: pid_t) -> UInt64? {
        var best: UInt64?
        for (windowID, windowOwner) in owner where windowOwner == pid {
            guard let value = sequence[windowID] else { continue }
            if best == nil || value > best! { best = value }
        }
        return best
    }

    // MARK: - Zapis

    func bump(windowID: CGWindowID, pid: pid_t) {
        guard windowID != 0 else { return }
        counter &+= 1
        sequence[windowID] = counter
        owner[windowID] = pid
        pruneIfNeeded()
    }

    /// Po przelaczeniu z naszego HUD-a - fokus zmieni sie za chwile, ale my juz wiemy,
    /// co uzytkownik wybral, wiec zapisujemy to natychmiast.
    func noteSelection(windowID: CGWindowID, pid: pid_t) {
        if windowID != 0 {
            bump(windowID: windowID, pid: pid)
        } else {
            scheduleBump(pid: pid, delay: 0.25)
        }
        observe(pid: pid)
    }

    private func pruneIfNeeded() {
        guard sequence.count > 400 else { return }
        // Zostawiamy dwiescie najswiezszych - reszta i tak nigdy nie trafi na widoczna liste.
        let keep = sequence.sorted { $0.value > $1.value }.prefix(200)
        sequence = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        owner = owner.filter { sequence[$0.key] != nil }
    }

    /// Przy starcie nie mamy historii, wiec bierzemy to, co widac na ekranie:
    /// okno na spodzie dostaje najstarszy numer, okno na wierzchu najswiezszy.
    private func seedFromScreenOrder() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        var entries: [(CGWindowID, pid_t)] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            entries.append((number, pid))
        }
        for (number, pid) in entries.reversed() {
            bump(windowID: number, pid: pid)
        }
    }

    // MARK: - Zdarzenia

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        observe(pid: pid)
        scheduleBump(pid: pid, delay: 0.12)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        let dead = owner.filter { $0.value == pid }.map { $0.key }
        for windowID in dead {
            sequence.removeValue(forKey: windowID)
            owner.removeValue(forKey: windowID)
        }
    }

    /// Fokus po aktywacji aplikacji ustala sie z niewielkim opoznieniem, wiec pytamy
    /// o niego chwile pozniej. Kolejne zdarzenia kasuja poprzednie zapytanie.
    private func scheduleBump(pid: pid_t, delay: TimeInterval) {
        pendingBump?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.bumpFocusedWindow(pid: pid)
        }
        pendingBump = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func bumpFocusedWindow(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let focused = axElement(axApp, AXKey.focusedWindow) else { return }
        let windowID = axWindowID(focused)
        guard windowID != 0 else { return }
        bump(windowID: windowID, pid: pid)
    }

    /// Obserwator wylapuje zmiane okna wewnatrz jednej aplikacji - bez tego przelaczanie
    /// miedzy dwoma oknami Chrome nie zmienialoby ich kolejnosci na liscie.
    private func observe(pid: pid_t) {
        guard observers[pid] == nil, Permissions.accessibilityGranted, pid != getpid() else { return }
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowUsageTracker>.fromOpaque(refcon).takeUnretainedValue()
            var elementPID: pid_t = 0
            AXUIElementGetPid(element, &elementPID)
            tracker.scheduleBump(pid: elementPID, delay: 0.05)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in ["AXFocusedWindowChanged", "AXMainWindowChanged", "AXApplicationActivated"] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func attachPendingObservers() {
        guard Permissions.accessibilityGranted else { return }
        if let front = NSWorkspace.shared.frontmostApplication {
            observe(pid: front.processIdentifier)
        }
    }
}

// MARK: - Akcje na oknach

enum WindowActions {
    /// Zamkniecie okna to nacisniecie jego czerwonej kropki - dokladnie to samo,
    /// co zrobilby uzytkownik, wiec aplikacja zdazy zapytac o niezapisane zmiany.
    @discardableResult
    static func close(_ item: SwitcherItem) -> Bool {
        switch item.target {
        case .browserTab(let tab):
            return closeBrowserTab(tab)
        case .window(let window):
            return pressCloseButton(window)
        case .processWindow(let identifier):
            let axApp = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            guard let windows = axElements(axApp, AXKey.windows),
                  let match = windows.first(where: { axWindowID($0) == identifier }) else { return false }
            return pressCloseButton(match)
        }
    }

    private static func pressCloseButton(_ window: AXUIElement) -> Bool {
        guard let button = axElement(window, "AXCloseButton") else { return false }
        return AXUIElementPerformAction(button, "AXPress" as CFString) == .success
    }

    private static func closeBrowserTab(_ tab: BrowserTab) -> Bool {
        guard let definition = BrowserSupport.definition(for: tab.bundleID) else { return false }
        let source: String
        switch definition.kind {
        case .chromium:
            source = """
            tell application id "\(definition.bundleID)"
                close (tab \(tab.tabIndex) of (first window whose id is \(tab.windowID)))
            end tell
            """
        case .safari:
            source = """
            tell application id "\(definition.bundleID)"
                close (tab \(tab.tabIndex) of (first window whose id is \(tab.windowID)))
            end tell
            """
        }
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo == nil
    }

    /// Zwykle zakonczenie aplikacji - takie samo jak ⌘Q w jej wlasnym menu (aplikacja
    /// zdazy zapytac o niezapisane zmiany). `force` to odpowiednik "Wymus koniec" -
    /// tylko na wyrazne zyczenie (⌥ razem z Q), bo pomija zapis.
    @discardableResult
    static func quitApplication(pid: pid_t, force: Bool = false) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return force ? app.forceTerminate() : app.terminate()
    }
}
