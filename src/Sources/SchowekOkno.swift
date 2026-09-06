import AppKit
import SwiftUI

// MARK: - Okno historii schowka
//
// Wyglada i dziala jak przelacznik okien: pisanie filtruje, strzalki wybieraja,
// Enter wkleja. Roznica jest jedna - to okno przyjmuje klawisze samo, bez podsluchu
// systemowego, bo otwiera sie na zadanie i moze byc oknem aktywnym.

final class ModelSchowka: ObservableObject {
    @Published var fraza: String = "" { didSet { przelicz() } }
    @Published private(set) var widoczne: [WpisSchowka] = []
    @Published var zaznaczony: Int = 0

    private var wszystkie: [WpisSchowka] = []

    func odswiez() {
        wszystkie = HistoriaSchowka.shared.wpisy
        przelicz()
    }

    private func przelicz() {
        let szukane = SwitcherModel.uprosc(fraza)
        // Przypiete zawsze na gorze - to sa rzeczy, po ktore siega sie codziennie
        // (numer konta, adres, stala formulka).
        let dopasowane = szukane.isEmpty
            ? wszystkie
            : wszystkie.filter {
                SwitcherModel.uprosc($0.tekst).contains(szukane) || SwitcherModel.uprosc($0.zrodlo).contains(szukane)
            }
        widoczne = dopasowane.sorted { lewy, prawy in
            if lewy.przypiety != prawy.przypiety { return lewy.przypiety }
            return lewy.czas > prawy.czas
        }
        zaznaczony = widoczne.isEmpty ? 0 : min(zaznaczony, widoczne.count - 1)
    }

    var wybrany: WpisSchowka? {
        widoczne.indices.contains(zaznaczony) ? widoczne[zaznaczony] : nil
    }

    func przesun(_ krok: Int) {
        guard !widoczne.isEmpty else { return }
        zaznaczony = ((zaznaczony + krok) % widoczne.count + widoczne.count) % widoczne.count
    }
}

final class SchowekOknoController: NSObject, NSWindowDelegate {
    static let shared = SchowekOknoController()

    private var okno: NSPanel?
    private let model = ModelSchowka()

    private override init() { super.init() }

    func pokaz() {
        model.odswiez()
        model.fraza = ""
        model.zaznaczony = 0

        if okno == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
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
            panel.contentView = NSHostingView(rootView: WidokSchowka(model: model, zamknij: { [weak self] in self?.schowaj() }))
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
    }

    func schowaj() {
        okno?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Widok

struct WidokSchowka: View {
    @ObservedObject var model: ModelSchowka
    let zamknij: () -> Void
    @FocusState private var polePisania: Bool

    var body: some View {
        VStack(spacing: 0) {
            pasekSzukania
            Divider().opacity(0.5)
            if model.widoczne.isEmpty {
                pusto
            } else {
                lista
            }
            Divider().opacity(0.5)
            stopka
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(VisualEffectBackground())
        // Kolorowa obwodka po wewnetrznej stronie okna. Rysowana NAD trescia, ale
        // bez przejmowania klikniec - inaczej ramka zjadalaby klikniecia przy
        // krawedzi listy. Ten sam gradient co w przelaczniku, z jednego miejsca.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .inset(by: 1)
                .strokeBorder(Barwy.obramowanie, lineWidth: 1.4)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .inset(by: 2.4)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .onAppear { polePisania = true }
    }

    /// Zebatka w pasku okna - stad ustawia sie, jak dlugo trzymamy historie
    /// i czy w ogole ma dzialac. Szukanie tego w pasku menu bylo droga naokolo.
    private var zebatkaUstawien: some View {
        Button {
            zamknij()
            SettingsWindowController.shared.show(tab: .schowek)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Ustawienia schowka")
    }

    private var pasekSzukania: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Szukaj w historii kopiowania…", text: $model.fraza)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($polePisania)
                .onSubmit { wklej() }
            if !model.fraza.isEmpty {
                Button {
                    model.fraza = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            zebatkaUstawien
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var pusto: some View {
        VStack(spacing: 8) {
            Image(systemName: model.fraza.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.fraza.isEmpty
                 ? "Historia jest pusta. Skopiuj cokolwiek, a pojawi się tutaj."
                 : "Nic nie pasuje do „\(model.fraza)”.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var lista: some View {
        ScrollViewReader { przewijanie in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.widoczne.enumerated()), id: \.element.id) { pozycja, wpis in
                        wiersz(wpis, wybrany: pozycja == model.zaznaczony)
                            .id(wpis.id)
                            .onTapGesture {
                                model.zaznaczony = pozycja
                                wklej()
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: model.zaznaczony) { _ in
                guard let wpis = model.wybrany else { return }
                withAnimation(.easeOut(duration: 0.12)) { przewijanie.scrollTo(wpis.id, anchor: .center) }
            }
        }
    }

    private func wiersz(_ wpis: WpisSchowka, wybrany: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Obraz pokazujemy obrazem — nazwa pliku nikomu nic nie mówi.
            if wpis.rodzaj == .obraz, let miniatura = HistoriaSchowka.shared.obraz(dla: wpis) {
                Image(nsImage: miniatura)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 108, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: wpis.rodzaj == .obraz ? "photo" : "text.alignleft")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(wpis.podglad)
                    .font(.system(size: 12.5))
                    .lineLimit(wpis.rodzaj == .obraz ? 1 : 3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if wpis.przypiety {
                        Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(Color.accentColor)
                    }
                    Text(wpis.zrodlo)
                    Text("·")
                    Text(wpis.czas.formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)

            HStack(spacing: 4) {
                przycisk(wpis.przypiety ? "pin.slash" : "pin", pomoc: wpis.przypiety ? "Odepnij" : "Przypnij") {
                    HistoriaSchowka.shared.przypnij(wpis)
                    model.odswiez()
                }
                przycisk("trash", pomoc: "Usuń z historii") {
                    HistoriaSchowka.shared.usun(wpis)
                    model.odswiez()
                }
            }
            .opacity(wybrany ? 1 : 0.35)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(wybrany ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func przycisk(_ ikona: String, pomoc: String, akcja: @escaping () -> Void) -> some View {
        Button(action: akcja) {
            Image(systemName: ikona)
                .font(.system(size: 10.5))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(pomoc)
    }

    private var stopka: some View {
        HStack(spacing: 14) {
            podpowiedz("↑↓", "wybór")
            podpowiedz("⏎", "wklej")
            podpowiedz("esc", "zamknij")
            Spacer()
            Text("\(model.widoczne.count) z \(HistoriaSchowka.shared.wpisy.count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Button("Wyczyść") {
                HistoriaSchowka.shared.wyczysc()
                model.odswiez()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("Usuwa wszystko poza przypiętymi")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func podpowiedz(_ klawisz: String, _ opis: String) -> some View {
        HStack(spacing: 4) {
            Text(klawisz)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Color.primary.opacity(0.10)))
            Text(opis).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func wklej() {
        guard let wpis = model.wybrany else { return }
        guard HistoriaSchowka.shared.wstawDoSchowka(wpis) else { return }
        zamknij()
        // Program musi najpierw oddac pierwszenstwo temu, w czym uzytkownik pisze -
        // dopiero wtedy skrot wklejenia trafi we wlasciwe okno.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Wklejanie.wyslijSkrotWklejenia()
        }
    }
}
