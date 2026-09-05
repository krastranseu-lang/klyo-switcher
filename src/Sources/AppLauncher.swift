import AppKit
import ApplicationServices
import SwiftUI

/// Skroty przypisane do konkretnych aplikacji. Zachowanie jest takie jak na pasku zadan
/// Windows: pierwszy raz przenosi do aplikacji, kolejne wciskniecia kraza po jej oknach,
/// a jesli aplikacja nie dziala - uruchamia ja.
enum AppLauncher {
    static func trigger(_ shortcut: AppShortcut) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleID)
            .filter { $0.activationPolicy != .prohibited }
        guard let app = running.first else {
            launch(bundleID: shortcut.bundleID)
            return
        }
        if app.isActive {
            cycleWindows(pid: app.processIdentifier)
        } else {
            WindowActivator.activateApp(pid: app.processIdentifier)
        }
    }

    private static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private static func cycleWindows(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let windows = axElements(axApp, AXKey.windows) else { return }
        let usable = windows.filter { window in
            let subrole = axString(window, AXKey.subrole)
            let minimized = axBool(window, AXKey.minimized) ?? false
            return !minimized && (subrole == nil || subrole == AXKey.standardWindow)
        }
        guard usable.count > 1 else { return }

        var index = 0
        if let focused = axElement(axApp, AXKey.focusedWindow) {
            let focusedID = axWindowID(focused)
            if let position = usable.firstIndex(where: { axWindowID($0) == focusedID }) {
                index = (position + 1) % usable.count
            }
        }
        let target = usable[index]
        AXUIElementSetAttributeValue(target, AXKey.main as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, AXKey.focusedWindow as CFString, target)
        AXUIElementPerformAction(target, AXKey.raise as CFString)
    }

    /// Aplikacje widoczne teraz w Docku - najkrotsza droga do przypisania skrotu
    /// bez przegladania calego dysku.
    static func runningApplications() -> [(name: String, bundleID: String, icon: NSImage?)] {
        var seen = Set<String>()
        var result: [(String, String, NSImage?)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID) else { continue }
            guard bundleID != Bundle.main.bundleIdentifier else { continue }
            seen.insert(bundleID)
            let icon = app.icon?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            result.append((app.localizedName ?? bundleID, bundleID, icon))
        }
        return result.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, bundleID: $0.1, icon: $0.2) }
    }

    /// Dowolna aplikacja z dysku - okno wyboru pliku otwarte na /Applications.
    static func chooseFromDisk() -> (name: String, bundleID: String)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Wybierz"
        panel.message = "Wskaż aplikację, którą ma otwierać ten skrót"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, identifier)
    }
}

/// Globalne wstrzymanie skrotow na czas nagrywania nowego w oknie ustawien.
enum HotkeySuspension {
    static var setter: ((Bool) -> Void)?

    static func set(_ suspended: Bool) {
        setter?(suspended)
    }
}

// MARK: - Krotki komunikat na ekranie

/// Male okienko z jednym zdaniem, znikajace samo. Uzywane po zrzucie ekranu
/// i po sprawdzeniu aktualizacji - bez systemowych powiadomien, ktore dla aplikacji
/// bez ikony w Docku wymagaja osobnej zgody.
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var panel: NSPanel?
    private var hideTimer: Timer?

    private init() {}

    func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        let view = ToastView(text: text, symbol: symbol)
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        let size = NSSize(width: max(240, min(520, hosting.fittingSize.width)), height: max(52, hosting.fittingSize.height))

        let panel = ensurePanel()
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(
                NSRect(x: frame.midX - size.width / 2, y: frame.minY + 90, width: size.width, height: size.height),
                display: false
            )
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 2.6, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func dismiss() {
        hideTimer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let panel = self.panel else { return }
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            self.panel = nil
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.isReleasedWhenClosed = false
        created.level = .statusBar
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.ignoresMouseEvents = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = created
        return created
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        )
    }
}
