import AppKit
import SwiftUI

// MARK: - Okno szybkich akcji
//
// Otwiera sie po PRZYTRZYMANIU modyfikatora (domyslnie ⌃ Control) i jest jednym
// polem, w ktorym pisze sie nazwe: okna, karty przegladarki, programu albo
// polecenia. Enter wykonuje pierwszy wynik.
//
// Dlaczego osobne okno, a nie kolejny tryb przelacznika: przelacznik zyje tylko
// wtedy, gdy trzymasz ⌘, i celowo nie przyjmuje fokusu. Tutaj czlowiek pisze
// zdanie i patrzy na wyniki - to jest zwykle okno, ktore ma byc aktywne.

final class ModelSzybkichAkcji: ObservableObject {
    @Published var fraza: String = "" { didSet { przelicz() } }
    @Published private(set) var wyniki: [AkcjaSzybka] = []
    @Published var zaznaczony: Int = 0

    var okna: [SwitcherItem] = []
    var karty: [BrowserTab] = []
    var polecenia: [AkcjaSzybka] = []

    func przelicz() {
        wyniki = ZrodloAkcji.znajdz(fraza: fraza, okna: okna, karty: karty, polecenia: polecenia)
        zaznaczony = wyniki.isEmpty ? 0 : min(zaznaczony, wyniki.count - 1)
    }

    var wybrany: AkcjaSzybka? {
        wyniki.indices.contains(zaznaczony) ? wyniki[zaznaczony] : nil
    }

    func przesun(_ krok: Int) {
        guard !wyniki.isEmpty else { return }
        zaznaczony = ((zaznaczony + krok) % wyniki.count + wyniki.count) % wyniki.count
    }
}

final class SzybkieAkcjeController: NSObject, NSWindowDelegate {
    static let shared = SzybkieAkcjeController()

    private var okno: NSPanel?
    private let model = ModelSzybkichAkcji()
    /// Podsluch klawiszy TEGO okna. Strzalki i Esc musza dzialac, choc kursor
    /// stoi w polu tekstowym - inaczej stopka obiecuje ruch, ktorego nie ma.
    private var klawisze: Any?
    /// Zrodla danych wstrzykiwane przez `AppController` - okno nie zbiera ich samo,
    /// bo spis okien i indeks kart maja juz swoich wlascicieli.
    var zbierzOkna: (() -> [SwitcherItem])?
    var przegladarki: BrowserTabIndex?

    private override init() { super.init() }

    func przelacz() {
        if okno?.isVisible == true { schowaj() } else { pokaz() }
    }

    func pokaz() {
        model.okna = zbierzOkna?() ?? []
        model.karty = przegladarki.map { indeks in
            BrowserSupport.definitions.flatMap { indeks.tabsForDisplay(bundleID: $0.bundleID) }
        } ?? []
        model.polecenia = poleceniaProgramu()
        model.fraza = ""
        model.zaznaczony = 0
        model.przelicz()

        if okno == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
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
            panel.contentView = NSHostingView(
                rootView: WidokSzybkichAkcji(model: model,
                                             wykonaj: { [weak self] akcja in self?.wykonaj(akcja) },
                                             zamknij: { [weak self] in self?.schowaj() })
            )
            panel.center()
            okno = panel
        }
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        okno?.makeKeyAndOrderFront(nil)
        wepnijKlawisze()
    }

    func schowaj() {
        odepnijKlawisze()
        okno?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Strzalki chodza po wynikach, Esc zamyka, Enter wykonuje (Enter obsluguje
    /// samo pole tekstowe). Monitor jest LOKALNY - dziala tylko, gdy to okno jest
    /// aktywne, i nie dotyka klawiatury reszty systemu.
    private func wepnijKlawisze() {
        odepnijKlawisze()
        klawisze = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] zdarzenie in
            guard let self, self.okno?.isKeyWindow == true else { return zdarzenie }
            switch zdarzenie.keyCode {
            case 125: self.model.przesun(1); return nil    // strzalka w dol
            case 126: self.model.przesun(-1); return nil   // strzalka w gore
            case 53:  self.schowaj(); return nil           // Esc
            default:  return zdarzenie
            }
        }
    }

    private func odepnijKlawisze() {
        if let klawisze { NSEvent.removeMonitor(klawisze) }
        klawisze = nil
    }

    func windowWillClose(_ notification: Notification) {
        odepnijKlawisze()
        NSApp.setActivationPolicy(.accessory)
    }

    private func wykonaj(_ akcja: AkcjaSzybka) {
        schowaj()
        guard let przegladarki else { return }
        // Chwila zwloki: okno akcji musi zejsc z drogi, zanim cel wyjdzie na wierzch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            ZrodloAkcji.wykonaj(akcja, przegladarki: przegladarki)
        }
    }

    /// Polecenia samego programu - to, po co dzis trzeba szukac ikony w pasku menu.
    private func poleceniaProgramu() -> [AkcjaSzybka] {
        [
            AkcjaSzybka(id: "cmd:ustawienia", tytul: "Ustawienia Klyo Switcher",
                        podtytul: "Skróty, biurka, schowek", ikona: nil,
                        rodzaj: .polecenie { SettingsWindowController.shared.show() }, waga: 8),
            AkcjaSzybka(id: "cmd:schowek", tytul: "Historia kopiowania",
                        podtytul: "Ostatnio skopiowane rzeczy", ikona: nil,
                        rodzaj: .polecenie { SchowekOknoController.shared.pokaz() }, waga: 8),
            AkcjaSzybka(id: "cmd:skroty", tytul: "Skróty do programów",
                        podtytul: "Własny klawisz do wybranego programu", ikona: nil,
                        rodzaj: .polecenie { SettingsWindowController.shared.show(tab: .shortcuts) }, waga: 8),
            AkcjaSzybka(id: "cmd:program-z-dysku", tytul: "Wskaż program na dysku…",
                        podtytul: "Wybierz plik programu i otwórz go", ikona: nil,
                        rodzaj: .polecenie {
                            guard let wybrany = AppLauncher.chooseFromDisk() else { return }
                            let ustawienia = NSWorkspace.OpenConfiguration()
                            ustawienia.activates = true
                            if let url = NSWorkspace.shared
                                .urlForApplication(withBundleIdentifier: wybrany.bundleID) {
                                NSWorkspace.shared.openApplication(at: url, configuration: ustawienia)
                            }
                        }, waga: 9),
        ]
    }
}

// MARK: - Widok

struct WidokSzybkichAkcji: View {
    @ObservedObject var model: ModelSzybkichAkcji
    let wykonaj: (AkcjaSzybka) -> Void
    let zamknij: () -> Void
    @FocusState private var pisanie: Bool

    var body: some View {
        VStack(spacing: 0) {
            pasek
            Divider().opacity(0.5)
            if model.wyniki.isEmpty {
                pusto
            } else {
                lista
            }
            Divider().opacity(0.5)
            stopka
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(VisualEffectBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .inset(by: 1)
                .strokeBorder(Barwy.obramowanie, lineWidth: 1.4)
                .allowsHitTesting(false)
        )
        .onAppear { pisanie = true }
    }

    private var pasek: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
            TextField("Okno, karta, program albo polecenie…", text: $model.fraza)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($pisanie)
                .onSubmit { if let wybrany = model.wybrany { wykonaj(wybrany) } }
            Button {
                SettingsWindowController.shared.show()
                zamknij()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ustawienia")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var pusto: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.fraza.isEmpty
                 ? "Wpisz nazwę okna, karty albo programu."
                 : "Nic nie pasuje do „\(model.fraza)”.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var lista: some View {
        ScrollViewReader { przewijanie in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(model.wyniki.enumerated()), id: \.element.id) { pozycja, akcja in
                        wiersz(akcja, wybrany: pozycja == model.zaznaczony)
                            .id(akcja.id)
                            .onTapGesture {
                                model.zaznaczony = pozycja
                                wykonaj(akcja)
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: model.zaznaczony) { _ in
                guard let wybrany = model.wybrany else { return }
                withAnimation(.easeOut(duration: 0.12)) { przewijanie.scrollTo(wybrany.id, anchor: .center) }
            }
        }
    }

    private func wiersz(_ akcja: AkcjaSzybka, wybrany: Bool) -> some View {
        HStack(spacing: 10) {
            if let ikona = akcja.ikona {
                Image(nsImage: ikona).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "command")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(akcja.tytul).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(akcja.podtytul).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(akcja.etykietaRodzaju)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(wybrany ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var stopka: some View {
        HStack(spacing: 12) {
            Text("↑↓ wybór · ⏎ wykonaj · esc zamknij")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(model.wyniki.count) wyników")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
