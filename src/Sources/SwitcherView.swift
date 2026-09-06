import AppKit
import SwiftUI

enum HUDLayout {
    static let padding: CGFloat = 18
    static let cardWidth: CGFloat = 186
    static let cardHeight: CGFloat = 168
    /// Kadr 170×106 - proporcje zblizone do ekranu, wiec caly zrzut okna miesci sie
    /// bez ucinania, a miniatura jest na tyle duza, ze widac, co jest w oknie.
    static let previewHeight: CGFloat = 106
    static let gap: CGFloat = 12
    static let sectionGap: CGFloat = 14
    static let footerHeight: CGFloat = 40
    static let maxColumns: Int = 7

    static func columns(for count: Int, screenWidth: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let usable = screenWidth - 140 - padding * 2 + gap
        let fitting = Int(floor(usable / (cardWidth + gap)))
        return max(1, min(min(count, maxColumns), max(1, fitting)))
    }

    /// Ile rzedow kart zmiesci sie na ekranie bez wychodzenia poza jego krawedzie.
    static func maxRows(screenHeight: CGFloat) -> Int {
        let usable = screenHeight - 140 - padding * 2 - sectionGap - footerHeight + gap
        return max(1, Int(floor(usable / (cardHeight + gap))))
    }

    static func panelSize(count: Int, columns: Int) -> NSSize {
        let safeColumns = max(1, columns)
        let rows = max(1, Int(ceil(Double(count) / Double(safeColumns))))
        let width = padding * 2 + CGFloat(safeColumns) * cardWidth + CGFloat(safeColumns - 1) * gap
        let height = padding * 2
            + CGFloat(rows) * cardHeight
            + CGFloat(rows - 1) * gap
            + sectionGap
            + footerHeight
        return NSSize(width: width, height: height)
    }
}

final class SwitcherModel: ObservableObject {
    /// Pelna lista okien z tej sesji. `items` to jej przefiltrowany widok, wiec
    /// skasowanie frazy przywraca wszystko bez ponownego zbierania okien.
    private var wszystkie: [SwitcherItem] = []
    @Published private(set) var fraza: String = ""
    @Published var items: [SwitcherItem] = []
    @Published var selection: Int = 0
    @Published var columns: Int = 1
    @Published var hoveredID: String?
    /// Mysz slnie NIE wybiera - to byla prosba uzytkownika po realnej pomylce:
    /// kursor stojacy na srodku ekranu przestawial wybor tuz przed puszczeniem
    /// modyfikatora i program przelaczal na zle okno. Zostaje samo podswietlenie
    /// pod kursorem, zeby bylo widac, w co trafi klikniecie.

    var onPick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onQuit: ((Int) -> Void)?

    var rows: [[SwitcherItem]] {
        guard columns > 0, !items.isEmpty else { return [] }
        var result: [[SwitcherItem]] = []
        var index = 0
        while index < items.count {
            let end = min(index + columns, items.count)
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }

    var selectedItem: SwitcherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    // MARK: - Szukanie po nazwie

    /// Podstawia pelna liste okien i zeruje szukana fraze.
    func ustawWszystkie(_ lista: [SwitcherItem]) {
        wszystkie = lista
        fraza = ""
        items = lista
    }

    func dopiszDoFrazy(_ znak: String) {
        zmienFraze(fraza + znak)
    }

    func skasujZnakFrazy() {
        guard !fraza.isEmpty else { return }
        zmienFraze(String(fraza.dropLast()))
    }

    /// Filtr dziala na tytule okna I nazwie programu, bez ogladania sie na wielkosc
    /// liter oraz na ogonki - „zlec" znajdzie „Zlecenia", a „lodz" znajdzie „Łódź".
    private func zmienFraze(_ nowa: String) {
        fraza = nowa
        let szukane = SwitcherModel.uprosc(nowa)
        if szukane.isEmpty {
            items = wszystkie
        } else {
            items = wszystkie.filter {
                SwitcherModel.uprosc($0.title).contains(szukane)
                    || SwitcherModel.uprosc($0.subtitle).contains(szukane)
            }
        }
        selection = items.isEmpty ? 0 : min(selection, items.count - 1)
        hoveredID = nil
    }

    static func uprosc(_ tekst: String) -> String {
        tekst.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
    }

    /// Ile okien odpadlo przez fraze - stopka mowi o tym wprost, zeby nikt nie
    /// pomyslal, ze polowa okien zniknela z systemu.
    var odfiltrowane: Int { max(0, wszystkie.count - items.count) }

    func index(of id: String) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Miniatury wchodza paczkami - jedna zmiana `items` na paczke zamiast
    /// jednego przerysowania HUD-a na kazde okno.
    func setThumbnails(_ ready: [(id: String, image: NSImage)]) {
        guard !ready.isEmpty else { return }
        var updated = items
        var changed = false
        for entry in ready {
            guard let index = updated.firstIndex(where: { $0.id == entry.id }) else { continue }
            updated[index].thumbnail = entry.image
            changed = true
        }
        if changed {
            items = updated
        }
    }

    // MARK: - Mysz

    /// Nowa sesja zaczyna sie bez podswietlenia pod kursorem.
    func wyczyscPodswietlenie() {
        hoveredID = nil
    }

    // MARK: - Klawiatura

    /// Ruch po siatce: w poziomie po kolei z zawinieciem, w pionie o rzad w tej samej
    /// kolumnie - z ostatniego rzedu na pierwszy i odwrotnie.
    func move(_ direction: ArrowDirection) {
        let count = items.count
        guard count > 0 else { return }
        let cols = max(1, columns)
        switch direction {
        case .right:
            selection = (selection + 1) % count
        case .left:
            selection = (selection - 1 + count) % count
        case .down:
            let next = selection + cols
            selection = next < count ? next : selection % cols
        case .up:
            let previous = selection - cols
            if previous >= 0 {
                selection = previous
            } else {
                let column = selection % cols
                let lastRowStart = ((count - 1) / cols) * cols
                selection = min(lastRowStart + column, count - 1)
            }
        }
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: HUDLayout.sectionGap) {
            VStack(alignment: .leading, spacing: HUDLayout.gap) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: HUDLayout.gap) {
                        ForEach(row) { item in
                            card(for: item)
                        }
                        // Ostatni rzad bywa niepelny - rozpieracz trzyma go przy lewej
                        // krawedzi zamiast srodkowac wzgledem pelnych rzedow.
                        Spacer(minLength: 0)
                    }
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: model.selection)
            .animation(.easeOut(duration: 0.14), value: model.items.count)

            footer
        }
        .padding(HUDLayout.padding)
        .background(
            ZStack {
                VisualEffectBackground()
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 30, y: 12)
    }

    // MARK: - Stopka

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.selectedItem?.title
                         ?? (model.fraza.isEmpty ? "Brak otwartych okien" : "Nic nie pasuje do „\(model.fraza)”"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Zapowiedz skutku: wybor tej karty przelaczy biurko.
                    if let label = model.selectedItem?.place.label {
                        Text("→ \(label)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .fixedSize()
                    }
                }
                hints
            }
            Spacer(minLength: 8)
            if !model.fraza.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(model.fraza)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if model.odfiltrowane > 0 {
                        Text("−\(model.odfiltrowane)")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .fixedSize()
            }
            if !model.items.isEmpty {
                Text("\(model.selection + 1) / \(model.items.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
            }
        }
        .frame(height: HUDLayout.footerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hints: some View {
        let symbol = Settings.modifier.symbol
        return HStack(spacing: 5) {
            hint("\(symbol)⇥", "dalej")
            hint("⇧", "wstecz")
            hint("←→↑↓", "wybór")
            hint("\(symbol)1–9", "skok")
            hint("pisz", "szukaj")
            hint("⌘⇧V", "schowek")
            hint("\(symbol)W", "zamknij okno")
            hint("\(symbol)Q", "zakończ aplikację")
            hint("esc", "anuluj")
        }
        .foregroundStyle(.tertiary)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
            Text(label)
                .font(.system(size: 9))
        }
    }

    // MARK: - Karta okna

    private func card(for item: SwitcherItem) -> some View {
        let isSelected = model.selectedItem?.id == item.id
        // Przyciski widac ZAWSZE. Chowanie ich pod kursorem zmuszaloby do szukania
        // ich myszka, a mysz w tym oknie celowo nic nie wybiera.
        let showsControls = true

        return VStack(alignment: .leading, spacing: 7) {
            preview(for: item, showsControls: showsControls, isSelected: isSelected)

            Text(item.title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)

            HStack(spacing: 3) {
                if item.isMinimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 7.5))
                }
                Text(item.subtitle)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(width: HUDLayout.cardWidth, height: HUDLayout.cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.055),
                    lineWidth: isSelected ? 1.8 : 1
                )
        )
        // Wybrana karta stoi minimalnie blizej patrzacego. Cien rysujemy TYLKO pod nia:
        // cien pod kazda karta zamienilby liste w szarą papkę i kosztowal klatki
        // na starszym sprzecie.
        .shadow(color: Color.black.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 14 : 0, y: isSelected ? 5 : 0)
        .scaleEffect(isSelected ? 1.035 : 1.0)
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            if let index = model.index(of: item.id) {
                model.onPick?(index)
            }
        }
        // Mysz NIE zmienia zaznaczenia. Wybiera wylacznie klawiatura albo klikniecie -
        // kursor stojacy gdziekolwiek na ekranie nie ma prawa przestawic wyboru,
        // bo to przy szybkiej pracy z ⌘ Tab kosztowalo trafienie w zle okno.
        // Podswietlenie pod kursorem zostaje, ale to tylko podpowiedz, w co trafi klik.
        .onHover { wewnatrz in
            model.hoveredID = wewnatrz ? item.id : (model.hoveredID == item.id ? nil : model.hoveredID)
        }
    }

    /// Kadr o stalych proporcjach - dzieki temu rzad kart wyglada jak rzad, a nie
    /// jak zbior obrazkow o przypadkowych wysokosciach. Zrzut okna jest dopasowany
    /// Znak programu, do którego wracasz najczęściej.
    ///
    /// Trzy stopnie, trzy barwy — bursztyn, srebro, brąz — jak miejsca na podium.
    /// Znak jest MAŁY i stoi w rogu, bo ma pomagać rozpoznać kartę kątem oka,
    /// a nie odciągać uwagę od miniatury okna. Gwiazdka wielkości połowy karty
    /// zakrzyczałaby to, po co człowiek tu patrzy.
    ///
    /// Ciemna obwódka pod spodem sprawia, że znak jest czytelny także na jasnej
    /// miniaturze — bez niej gubi się na białym tle strony.
    @ViewBuilder
    private func gwiazdkaUlubionego(_ miejsce: Int) -> some View {
        let barwa: Color = {
            switch miejsce {
            case 0: return Color(red: 1.00, green: 0.78, blue: 0.28)   // bursztyn
            case 1: return Color(red: 0.83, green: 0.85, blue: 0.89)   // srebro
            default: return Color(red: 0.80, green: 0.60, blue: 0.42)  // brąz
            }
        }()
        Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(barwa)
            .shadow(color: Color.black.opacity(0.55), radius: 1.5, x: 0, y: 0.5)
            .help(miejsce == 0 ? "Najczęściej wybierany" : "Często wybierany")
    }

    /// w calosci (bez ucinania), jak w podgladzie Windows i Mission Control.
    private func preview(for item: SwitcherItem, showsControls: Bool, isSelected: Bool) -> some View {
        let symbol = Settings.modifier.symbol
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.26))

            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(3)
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if item.thumbnail != nil, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if let miejsce = Ulubione.miejsce(programu: item.bundleID ?? "") {
                gwiazdkaUlubionego(miejsce)
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if let label = item.place.label {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.92)))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if showsControls {
                HStack(spacing: 4) {
                    control("xmark", help: "Zamknij okno (\(symbol)W)") {
                        if let index = model.index(of: item.id) {
                            model.onClose?(index)
                        }
                    }
                    control("power", help: "Zakończ aplikację (\(symbol)Q; z ⌥ wymusza)") {
                        if let index = model.index(of: item.id) {
                            model.onQuit?(index)
                        }
                    }
                }
                .padding(4)
                .opacity(isSelected || model.hoveredID == item.id ? 1 : 0.55)
            }
        }
        .frame(width: HUDLayout.cardWidth - 18, height: HUDLayout.previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.62)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
