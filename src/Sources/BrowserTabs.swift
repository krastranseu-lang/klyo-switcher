import AppKit
import ApplicationServices
import Foundation

// MARK: - Model karty przegladarki

struct BrowserTab: Equatable {
    let bundleID: String
    let windowID: Int
    let windowIndex: Int
    let tabIndex: Int
    let isActive: Bool
    let title: String
    let url: String

    var key: String { "\(bundleID):\(windowID):\(tabIndex)" }
}

enum BrowserKind {
    case chromium
    case safari
}

struct BrowserDefinition {
    let bundleID: String
    let kind: BrowserKind
}

enum BrowserSupport {
    /// Przegladarki, z ktorych potrafimy wyciagnac liste kart przez Apple Events.
    static let definitions: [BrowserDefinition] = [
        BrowserDefinition(bundleID: "com.google.Chrome", kind: .chromium),
        BrowserDefinition(bundleID: "com.google.Chrome.beta", kind: .chromium),
        BrowserDefinition(bundleID: "com.google.Chrome.dev", kind: .chromium),
        BrowserDefinition(bundleID: "com.google.Chrome.canary", kind: .chromium),
        BrowserDefinition(bundleID: "org.chromium.Chromium", kind: .chromium),
        BrowserDefinition(bundleID: "com.brave.Browser", kind: .chromium),
        BrowserDefinition(bundleID: "com.brave.Browser.beta", kind: .chromium),
        BrowserDefinition(bundleID: "com.microsoft.edgemac", kind: .chromium),
        BrowserDefinition(bundleID: "com.microsoft.edgemac.Beta", kind: .chromium),
        BrowserDefinition(bundleID: "com.vivaldi.Vivaldi", kind: .chromium),
        BrowserDefinition(bundleID: "com.operasoftware.Opera", kind: .chromium),
        BrowserDefinition(bundleID: "com.apple.Safari", kind: .safari),
        BrowserDefinition(bundleID: "com.apple.SafariTechnologyPreview", kind: .safari)
    ]

    static func definition(for bundleID: String) -> BrowserDefinition? {
        definitions.first { $0.bundleID == bundleID }
    }

    static func isSupported(_ bundleID: String) -> Bool {
        definition(for: bundleID) != nil
    }

    static func host(of urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func listScript(for definition: BrowserDefinition) -> String {
        let tabsExpression: String
        let titleExpression: String
        let activeExpression: String
        switch definition.kind {
        case .chromium:
            tabsExpression = "every tab of currentWindow"
            titleExpression = "title of currentTab"
            activeExpression = "active tab index of currentWindow"
        case .safari:
            tabsExpression = "every tab of currentWindow"
            titleExpression = "name of currentTab"
            activeExpression = "index of current tab of currentWindow"
        }
        return """
        set tabChar to (ASCII character 9)
        set outText to ""
        tell application id "\(definition.bundleID)"
            set windowIndexCounter to 0
            repeat with currentWindow in every window
                set windowIndexCounter to windowIndexCounter + 1
                set windowIdentifier to (id of currentWindow) as text
                set activeIndex to 0
                try
                    set activeIndex to (\(activeExpression)) as integer
                end try
                set tabIndexCounter to 0
                repeat with currentTab in \(tabsExpression)
                    set tabIndexCounter to tabIndexCounter + 1
                    set tabTitle to ""
                    try
                        set tabTitle to (\(titleExpression)) as text
                    end try
                    set tabURL to ""
                    try
                        set tabURL to (URL of currentTab) as text
                    end try
                    set outText to outText & windowIdentifier & tabChar & (windowIndexCounter as text) & tabChar & (tabIndexCounter as text) & tabChar & (activeIndex as text) & tabChar & tabURL & tabChar & tabTitle & linefeed
                end repeat
            end repeat
        end tell
        return outText
        """
    }

    static func focusScript(for tab: BrowserTab) -> String? {
        guard let definition = definition(for: tab.bundleID) else { return nil }
        switch definition.kind {
        case .chromium:
            return """
            tell application id "\(definition.bundleID)"
                activate
                set targetWindow to (first window whose id is \(tab.windowID))
                set index of targetWindow to 1
                set active tab index of targetWindow to \(tab.tabIndex)
            end tell
            """
        case .safari:
            return """
            tell application id "\(definition.bundleID)"
                activate
                set targetWindow to (first window whose id is \(tab.windowID))
                set current tab of targetWindow to (tab \(tab.tabIndex) of targetWindow)
                set index of targetWindow to 1
            end tell
            """
        }
    }
}

// MARK: - Indeks kart odswiezany zdarzeniowo

/// Apple Events sa synchroniczne i potrafia zablokowac watek na dziesiatki milisekund,
/// dlatego lista kart zyje w pamieci, a jej odswiezanie jest w 100% zdarzeniowe:
/// obserwator Accessibility na procesie przegladarki budzi nas dokladnie wtedy, gdy
/// zmieni sie tytul okna (czyli po otwarciu, zamknieciu lub przelaczeniu karty).
/// W trybie "tylko okna" indeks w ogole nie startuje - zero Apple Events.
final class BrowserTabIndex {
    private(set) var tabs: [BrowserTab] = [] {
        didSet { onZmianaKart?(tabs.count) }
    }
    /// Zglaszane po kazdym odczycie kart - okno zgod poznaje po tym, czy zgoda
    /// „Automatyzacja" naprawde dziala.
    var onZmianaKart: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "pl.klyo.switcher.applescript", qos: .utility)
    private var pendingRefresh: DispatchWorkItem?
    private var observers: [pid_t: AXObserver] = [:]
    private var isRunning = false
    private var lastRefreshTime: CFAbsoluteTime = 0

    /// Kiedy dana karta byla ostatnio widziana jako aktywna - to jest nasza wlasna,
    /// tania miara "ostatnio uzywanych", bo przegladarki takiej listy nie udostepniaja.
    private var lastActiveAt: [String: CFAbsoluteTime] = [:]

    /// Minimalny odstep miedzy dwoma odczytami kart. Chroni przed lawina zdarzen
    /// "zmienil sie tytul" podczas ladowania strony.
    private let minimumInterval: CFAbsoluteTime = 1.2

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .klyoSettingsChanged, object: nil)
        attachObserversToRunningBrowsers()
        refresh(after: 0.4)
    }

    @objc private func settingsChanged() {
        if Settings.browserMode.usesTabs {
            attachObserversToRunningBrowsers()
            refresh(after: 0.1)
        } else if !tabs.isEmpty {
            tabs = []
        }
    }

    // MARK: - Zdarzenia systemowe

    private static func browserApp(from notification: Notification) -> NSRunningApplication? {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              BrowserSupport.isSupported(bundleID) else { return nil }
        return app
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = BrowserTabIndex.browserApp(from: notification) else { return }
        attachObserver(pid: app.processIdentifier)
        refresh(after: 1.0)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = BrowserTabIndex.browserApp(from: notification) else { return }
        detachObserver(pid: app.processIdentifier)
        refresh(after: 0.2)
    }

    @objc private func appActivated(_ notification: Notification) {
        // Obserwator AX moze nie wystartowac, zanim uzytkownik nada zgode "Dostepnosc".
        // Aktywacja przegladarki jest wtedy zapasowym momentem na dopiecie obserwatora.
        guard let app = BrowserTabIndex.browserApp(from: notification) else { return }
        attachObserver(pid: app.processIdentifier)
        if tabs.isEmpty { refresh(after: 0.3) }
    }

    // MARK: - Obserwator Accessibility

    private func attachObserversToRunningBrowsers() {
        guard Settings.browserMode.usesTabs else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, BrowserSupport.isSupported(bundleID) else { continue }
            attachObserver(pid: app.processIdentifier)
        }
    }

    private func attachObserver(pid: pid_t) {
        guard Settings.browserMode.usesTabs else { return }
        guard observers[pid] == nil, Permissions.accessibilityGranted else { return }
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let index = Unmanaged<BrowserTabIndex>.fromOpaque(refcon).takeUnretainedValue()
            index.refresh(after: 0.35)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = ["AXTitleChanged", "AXWindowCreated", "AXUIElementDestroyed", "AXFocusedWindowChanged"]
        for name in notifications {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func detachObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    func attachPendingObservers() {
        attachObserversToRunningBrowsers()
    }

    // MARK: - Odswiezanie

    func refresh(after delay: TimeInterval = 0.0) {
        guard Settings.browserMode.usesTabs else {
            if !tabs.isEmpty { tabs = [] }
            return
        }
        let sinceLast = CFAbsoluteTimeGetCurrent() - lastRefreshTime
        let throttled = max(delay, minimumInterval - sinceLast)
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performRefresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, throttled), execute: work)
    }

    private func performRefresh() {
        guard !isRunning, Settings.browserMode.usesTabs else { return }
        var targets: [BrowserDefinition] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  let definition = BrowserSupport.definition(for: bundleID) else { continue }
            targets.append(definition)
        }
        guard !targets.isEmpty else {
            if !tabs.isEmpty { tabs = [] }
            return
        }
        isRunning = true
        lastRefreshTime = CFAbsoluteTimeGetCurrent()
        queue.async { [weak self] in
            var collected: [BrowserTab] = []
            for definition in targets {
                collected.append(contentsOf: BrowserTabIndex.collect(definition))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.noteActiveTabs(collected)
                if self.tabs != collected {
                    self.tabs = collected
                }
            }
        }
    }

    private func noteActiveTabs(_ collected: [BrowserTab]) {
        let now = CFAbsoluteTimeGetCurrent()
        var seen = Set<String>()
        for tab in collected {
            seen.insert(tab.key)
            if tab.isActive {
                lastActiveAt[tab.key] = now
            }
        }
        // Karty, ktorych juz nie ma, wypadaja z pamieci - slownik nie rosnie bez konca.
        if lastActiveAt.count > seen.count {
            lastActiveAt = lastActiveAt.filter { seen.contains($0.key) }
        }
    }

    func lastActiveTime(for tab: BrowserTab) -> CFAbsoluteTime {
        lastActiveAt[tab.key] ?? 0
    }

    private static func collect(_ definition: BrowserDefinition) -> [BrowserTab] {
        let source = BrowserSupport.listScript(for: definition)
        guard let script = NSAppleScript(source: source) else { return [] }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return [] }
        guard let text = descriptor.stringValue, !text.isEmpty else { return [] }

        var result: [BrowserTab] = []
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            let parts = line.components(separatedBy: "\t")
            if parts.count < 6 { continue }
            guard let windowID = Int(parts[0]),
                  let windowIndex = Int(parts[1]),
                  let tabIndex = Int(parts[2]),
                  let activeIndex = Int(parts[3]) else { continue }
            let url = parts[4]
            let title = parts[5...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                BrowserTab(
                    bundleID: definition.bundleID,
                    windowID: windowID,
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    isActive: tabIndex == activeIndex,
                    title: title,
                    url: url
                )
            )
        }
        return result
    }

    /// Karty przyciete do tego, co uzytkownik chce ogladac: w trybie "ostatnio uzywane"
    /// zostaje aktywna karta kazdego okna plus najswiezsze z reszty.
    func tabsForDisplay(bundleID: String) -> [BrowserTab] {
        let mode = Settings.browserMode
        guard mode.usesTabs else { return [] }
        let mine = tabs.filter { $0.bundleID == bundleID }
        guard mode == .recentTabs else { return mine }

        let limit = Settings.tabLimitPerWindow
        var byWindow: [Int: [BrowserTab]] = [:]
        for tab in mine {
            byWindow[tab.windowID, default: []].append(tab)
        }
        var result: [BrowserTab] = []
        for (_, windowTabs) in byWindow {
            let sorted = windowTabs.sorted { left, right in
                if left.isActive != right.isActive { return left.isActive }
                let leftSeen = lastActiveTime(for: left)
                let rightSeen = lastActiveTime(for: right)
                if leftSeen != rightSeen { return leftSeen > rightSeen }
                return left.tabIndex < right.tabIndex
            }
            result.append(contentsOf: sorted.prefix(limit))
        }
        return result.sorted { left, right in
            if left.windowIndex != right.windowIndex { return left.windowIndex < right.windowIndex }
            return left.tabIndex < right.tabIndex
        }
    }

    func focus(_ tab: BrowserTab) {
        guard let source = BrowserSupport.focusScript(for: tab) else { return }
        lastActiveAt[tab.key] = CFAbsoluteTimeGetCurrent()
        queue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
        }
    }
}
