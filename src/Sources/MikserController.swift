import AppKit
import SwiftUI

// MARK: - Okno miksera: pokazywanie i chowanie
//
// Osobny plik od widoku, bo to dwie rozne roboty: tam wyglad, tu cykl zycia okna
// i zegar odswiezania. Zegar chodzi TYLKO przy otwartym oknie - pytanie CoreAudio
// co sekunde przy zamknietym oknie byloby praca dla nikogo.

final class MikserController: NSObject, NSWindowDelegate {
    static let shared = MikserController()

    private var okno: NSPanel?
    private let model = ModelMiksera()
    private var klawisze: Any?

    private override init() { super.init() }

    func przelacz() {
        if okno?.isVisible == true { schowaj() } else { pokaz() }
    }

    func pokaz() {
        model.odswiez()
        if okno == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: MikserView(model: model))
            panel.setContentSize(NSSize(width: 440, height: 540))
            panel.center()
            okno = panel
        }
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        okno?.makeKeyAndOrderFront(nil)
        model.zacznij()
        wepnijKlawisze()
    }

    func schowaj() {
        odepnijKlawisze()
        model.przestan()
        okno?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Esc zamyka - tak jak w kazdym innym oknie tego programu.
    private func wepnijKlawisze() {
        odepnijKlawisze()
        klawisze = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] zdarzenie in
            guard let self, self.okno?.isKeyWindow == true else { return zdarzenie }
            if zdarzenie.keyCode == 53 { self.schowaj(); return nil }
            return zdarzenie
        }
    }

    private func odepnijKlawisze() {
        if let klawisze { NSEvent.removeMonitor(klawisze) }
        klawisze = nil
    }

    func windowWillClose(_ notification: Notification) {
        odepnijKlawisze()
        model.przestan()
        NSApp.setActivationPolicy(.accessory)
    }
}
