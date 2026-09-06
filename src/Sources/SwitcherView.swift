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
    /// Duzy podglad okna pod kursorem - na tyle duzy, zeby dalo sie przeczytac
    /// tresc strony, i na tyle maly, zeby zmiescil sie w panelu przy trzech
    /// kolumnach kart (3 × 186 + 2 × 12 = 582 px).
    static let duzyPodgladSzerokosc: CGFloat = 640
    static let duzyPodgladWysokosc: CGFloat = 420

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
    @Published var items: [SwitcherItem] = [] { didSet { przeliczPierwszeKarty() } }
    /// Karty, ktore sa PIERWSZYM oknem swojego programu na liscie.
    ///
    /// Ulubiony jest programem, nie oknem - wiec znak ulubionego nalezy sie jednej
    /// karcie, a nie kazdemu z pietnastu okien Chrome. Bez tego rozroznienia lista
    /// zapelnia sie gwiazdkami i przestaja one cokolwiek znaczyc.
    private(set) var pierwszeKarty: Set<String> = []
    @Published var selection: Int = 0
    @Published var columns: Int = 1
    @Published var hoveredID: String? {
        didSet {
            guard oldValue != hoveredID else { return }
            // Duzy podglad nalezy do POPRZEDNIEJ karty - gasimy go od razu, zeby
            // przez chwile nie pokazywac tresci innego okna niz to pod kursorem.
            // Wyjatek: kursor wjechal NA PODGLAD. To dalej ten sam wybor, a bez
            // wyjatku podglad gasl w chwili, gdy czlowiek szedl mysza do jego
            // przyciskow - czyli dokladnie wtedy, gdy byl potrzebny.
            if duzyPodglad?.id != hoveredID, !kursorNaPodgladzie { duzyPodglad = nil }
            onZmianaKursora?(hoveredID)
        }
    }
    /// Kursor stoi nad panelem duzego podgladu (a nie nad karta).
    @Published var kursorNaPodgladzie = false
    /// Ostry zrzut okna pod kursorem, robiony na zadanie - patrz `onZmianaKursora`.
    ///
    /// Miniatura na karcie ma 170 px szerokosci: widac po niej UKLAD okna, ale nie
    /// tresc. Przy kilku podobnych stronach otwartych w przegladarce to za malo,
    /// zeby rozpoznac, ktora jest ktora - a po to czlowiek otwiera przelacznik.
    @Published var duzyPodglad: (id: String, obraz: NSImage)?
    /// Wolane, gdy kursor wchodzi na inna karte (albo z niej schodzi).
    var onZmianaKursora: ((String?) -> Void)?
    /// Mysz slnie NIE wybiera - to byla prosba uzytkownika po realnej pomylce:
    /// kursor stojacy na srodku ekranu przestawial wybor tuz przed puszczeniem
    /// modyfikatora i program przelaczal na zle okno. Zostaje samo podswietlenie
    /// pod kursorem, zeby bylo widac, w co trafi klikniecie.

    var onPick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onQuit: ((Int) -> Void)?
    var onPrzypnij: ((Int) -> Void)?
    /// Licznik przerysowania po zmianie ulubionych - `Ulubione` trzyma stan poza
    /// modelem, wiec SwiftUI nie ma jak sam zauwazyc, ze gwiazdka sie przeniosla.
    @Published var wersjaUlubionych = 0

    func odswiezUlubione() {
        Ulubione.odswiez()
        wersjaUlubionych &+= 1
    }

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
    private func przeliczPierwszeKarty() {
        var widziane = Set<String>()
        var wynik = Set<String>()
        for pozycja in items {
            let klucz = pozycja.bundleID.isEmpty ? pozycja.subtitle : pozycja.bundleID
            if widziane.insert(klucz).inserted { wynik.insert(pozycja.id) }
        }
        pierwszeKarty = wynik
    }

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
        // Duzy podglad rysuje sie NAD siatka, w srodku panelu. Nie powiekszamy
        // samej karty ponad miare, bo karta przy krawedzi wyszlaby poza panel
        // i system by ja przycial - a podglad ma byc CZYTELNY, nie polowiczny.
        .overlay(duzyPodglad)
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
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // Dwie krawedzie zamiast jednej: bialy wlos tuz przy szkle (to on daje
        // wrazenie grubosci) i kolorowa obwodka na zewnatrz. Osobno, bo jedna
        // linia nie umie byc naraz jasna i barwna.
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .inset(by: -0.5)
                .strokeBorder(Barwy.obramowanieDelikatne, lineWidth: 1.2)
        )
        // Cien w dwoch warstwach: waski i ciemny tuz pod panelem (odklejenie od
        // tla) oraz szeroki i miekki (glebia). Jedna warstwa daje albo plaska
        // ramke, albo szara mgle - nigdy obu naraz.
        .shadow(color: Color.black.opacity(0.30), radius: 10, y: 4)
        .shadow(color: Color.black.opacity(0.26), radius: 38, y: 16)
    }

    /// O ile rosnie karta pod kursorem - zalezy od wybranego rysunkiem wariantu.
    private var skalaPodKursorem: CGFloat {
        switch Settings.trybPodgladu {
        case .duzy: return 1.12          // czytelnosc bierze na siebie duzy podglad
        case .powiekszenie: return 1.34  // cala robota robi sama karta
        case .brak: return 1.0
        }
    }

    // MARK: - Duzy podglad okna pod kursorem

    /// Panel z ostrym zrzutem okna, ktore jest pod kursorem.
    ///
    /// Powod istnienia jednym zdaniem wlasciciela projektu: „jak masz kilka
    /// podobnych stron otwartych, musisz przeczytac jakakolwiek tresc, zeby
    /// wiedziec, ktory Chrome otworzyc". Miniatura na karcie ma 170 px - widac
    /// uklad, nie tresc. Ten podglad ma 640 px szerokosci i zrzut robiony
    /// specjalnie dla niego, wiec tekst w oknie da sie przeczytac.
    @ViewBuilder
    private var duzyPodglad: some View {
        if Settings.trybPodgladu == .duzy, let podglad = model.duzyPodglad,
           let pozycja = model.items.first(where: { $0.id == podglad.id }) {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: podglad.obraz)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: HUDLayout.duzyPodgladSzerokosc,
                           maxHeight: HUDLayout.duzyPodgladWysokosc)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                HStack(spacing: 8) {
                    if let ikona = pozycja.icon {
                        Image(nsImage: ikona).resizable().frame(width: 20, height: 20)
                    }
                    Text(pozycja.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plakietka = pozycja.place.label {
                        Text(plakietka)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                            .foregroundStyle(Color.white)
                    }
                    Spacer(minLength: 8)
                    // Te same akcje, co na malej karcie. Bez nich powiekszenie
                    // zabieralo mozliwosc kliknięcia w gwiazdke albo krzyzyk -
                    // panel zaslanial karte, a swoich przyciskow nie mial.
                    przyciskPodgladu("star", pozycja: pozycja, podpowiedz: "Ulubione (⌘D)") { index in
                        model.onPrzypnij?(index)
                    }
                    przyciskPodgladu("xmark", pozycja: pozycja, podpowiedz: "Zamknij okno (⌘W)") { index in
                        model.onClose?(index)
                    }
                    przyciskPodgladu("power", pozycja: pozycja, podpowiedz: "Zakończ program (⌘Q)") { index in
                        model.onQuit?(index)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .background(
                        VisualEffectBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Barwy.obramowanie, lineWidth: 1.4)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 30, y: 12)
            // Klikniecie w podglad przelacza na to okno - tak samo jak klikniecie
            // w karte, tylko w cel, ktory widac duzy.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                if let index = model.index(of: podglad.id) { model.onPick?(index) }
            }
            .onHover { wewnatrz in
                model.kursorNaPodgladzie = wewnatrz
                if wewnatrz { model.hoveredID = podglad.id }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: podglad.id)
        }
    }

    /// Przycisk w pasku duzego podgladu - te same akcje, co na karcie.
    private func przyciskPodgladu(_ symbol: String, pozycja: SwitcherItem,
                                  podpowiedz: String,
                                  akcja: @escaping (Int) -> Void) -> some View {
        Button {
            if let index = model.index(of: pozycja.id) { akcja(index) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(podpowiedz)
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
            hint("\(symbol)D", "ulubione")
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
        // Miejsce w ulubionych decyduje o obramowaniu i poświacie całej karty —
        // gwiazdka w rogu sama w sobie jest za mała, żeby rozpoznać ulubiony
        // program kątem oka w rzędzie kilkunastu kart.
        // Znak ulubionego dostaje tylko pierwsze okno danego programu na liscie.
        let podKursorem = model.hoveredID == item.id
        let pierwszaTegoProgramu = model.pierwszeKarty.contains(item.id)
        let ulubione = pierwszaTegoProgramu ? Ulubione.miejsce(programu: item.bundleID) : nil
        let barwaUlubionego = ulubione.map(PaletaUlubionych.barwa)
        // Przyciski widac ZAWSZE. Chowanie ich pod kursorem zmuszaloby do szukania
        // ich myszka, a mysz w tym oknie celowo nic nie wybiera.
        let showsControls = true

        // Wartosci GOTOWE, nie wyrazenia do rozwiazania w srodku lancucha
        // modyfikatorow — kompilator SwiftUI dusi sie na zagniezdzonych ternarach
        // zmieszanych z opcjonalnym `map`, tak jak przy oknie zgod (Uprawnienia.swift).
        // Obramowanie ulubionego jest CELOWO delikatne. Pierwsza wersja swiecila
        // mocno i wygladala dobrze na jednej karcie - ale ulubiony jest PROGRAM,
        // a nie okno, wiec przy pietnastu oknach Chrome pietnascie kart dostawalo
        // bursztynowa ramke i cala lista stawala sie zolta. Znak, ktory dostaje
        // polowa listy, przestaje byc znakiem.
        // Ulubione maja byc widoczne KATEM OKA, bo po to sa: zeby dalo sie w nie
        // trafic mysza bez czytania listy. Wczesniejsza wersja przygaszala je tak
        // mocno (0,34), ze przestaly cokolwiek mowic - ale wtedy znak dostawalo
        // kilkanascie kart naraz. Teraz znak ma tylko PIERWSZE okno programu,
        // wiec moze byc wyrazny bez zamieniania listy w choinke.
        let barwaObramowania: Color = isSelected
            ? Color.accentColor.opacity(0.95)
            : (barwaUlubionego ?? Color.white).opacity(barwaUlubionego != nil ? 0.95 : 0.055)
        let grubosc: CGFloat = isSelected ? 1.8 : (barwaUlubionego != nil ? 2.2 : 1)
        let poswiataBarwa: Color = barwaUlubionego ?? .clear
        let poswiataOpacja: Double = ulubione == 0 ? 0.55 : (barwaUlubionego != nil ? 0.35 : 0)
        let poswiataPromien: CGFloat = ulubione == 0 ? 12 : (barwaUlubionego != nil ? 8 : 0)
        // Tlo karty jako gradient, nie plaski kolor: plaska plama w kolorze akcentu
        // wyglada jak zaznaczenie w tabelce, a nie jak karta, ktora stoi wyzej.
        // Tlo karty ulubionego jest zabarwione jego kolorem - to widac wczesniej
        // niz obramowanie, bo zajmuje cala karte, a nie jej krawedz.
        let barwaTla: Color = barwaUlubionego ?? Color.primary
        let gornaBarwa: Color = isSelected
            ? Color.accentColor.opacity(0.38)
            : barwaTla.opacity(barwaUlubionego != nil ? 0.22 : 0.07)
        let dolnaBarwa: Color = isSelected
            ? Color.accentColor.opacity(0.16)
            : barwaTla.opacity(barwaUlubionego != nil ? 0.07 : 0.03)
        let tloKarty = LinearGradient(colors: [gornaBarwa, dolnaBarwa], startPoint: .top, endPoint: .bottom)
        // Niewybrane karty odrobine przygaszone - wzrok idzie tam, gdzie trzeba,
        // a lista nie zamienia sie w rownomierna sciane kwadratow.
        let przejrzystosc: Double = isSelected ? 1.0 : 0.93
        // Drugi wiersz powtarzajacy pierwszy to zmarnowany wiersz. Okno bez wlasnego
        // tytulu nazywa sie tak, jak program - wtedy pod spodem lepiej powiedziec,
        // GDZIE ono jest, niz drugi raz to samo.
        // Polozenie okna stoi juz na plakietce nad miniatura, wiec powtorzone pod
        // spodem byloby trzecim napisem o tym samym. Gdy nie ma czego napisac,
        // wiersz zostaje pusty - pusty wiersz czyta sie szybciej niz powtorzenie.
        let podtytul: String = {
            let tytul = item.title.trimmingCharacters(in: .whitespaces)
            let opis = item.subtitle.trimmingCharacters(in: .whitespaces)
            return opis == tytul ? "" : opis
        }()

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
                Text(podtytul)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .opacity(podtytul.isEmpty ? 0 : 1)
        }
        .padding(9)
        .frame(width: HUDLayout.cardWidth, height: HUDLayout.cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(tloKarty)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(barwaObramowania, lineWidth: grubosc)
        )
        // Wlos u gory karty - swiatlo padajace z gory. Bez niego karta na ciemnym
        // tle wyglada jak wyciety otwor, a nie jak plytka lezaca na szkle.
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .inset(by: 0.5)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .opacity(przejrzystosc)
        // Wybrana karta stoi minimalnie blizej patrzacego. Czarny cien rysujemy
        // TYLKO pod nia: cien pod kazda karta zamienilby liste w szarą papkę
        // i kosztowal klatki na starszym sprzecie.
        .shadow(color: Color.black.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 14 : 0, y: isSelected ? 5 : 0)
        // Kolorowa poświata ulubionego — osobna warstwa cienia, więc nie gasi
        // czarnego cienia karty wybranej. Świeci zawsze, także gdy karta jest
        // akurat zaznaczona, żeby zaznaczenie ulubionego nie „gubiło" koloru.
        .shadow(color: poswiataBarwa.opacity(poswiataOpacja), radius: poswiataPromien)
        // Karta pod kursorem podnosi sie lekko - to sygnal „tu jestes". Czytelnosc
        // zapewnia DUZY PODGLAD na srodku panelu, wiec karty nie trzeba juz
        // rozdymac; przy krawedzi panelu i tak zostalaby przycieta.
        .scaleEffect(podKursorem ? skalaPodKursorem : (isSelected ? 1.035 : 1.0))
        .shadow(color: Color.black.opacity(podKursorem ? 0.34 : 0), radius: podKursorem ? 22 : 0, y: podKursorem ? 10 : 0)
        .zIndex(podKursorem ? 2 : (isSelected ? 1 : 0))
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: podKursorem)
        .id("\(item.id)#\(model.wersjaUlubionych)")
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
    /// Wspólna paleta ulubionych: bursztyn, srebro, brąz — jak miejsca na podium.
    /// Jedno miejsce definicji, używane przez gwiazdkę I przez obramowanie karty,
    /// żeby oba efekty zawsze mówiły to samo.
    enum PaletaUlubionych {
        static func barwa(_ miejsce: Int) -> Color {
            switch miejsce {
            case 0: return Color(red: 1.00, green: 0.78, blue: 0.28)   // bursztyn
            case 1: return Color(red: 0.83, green: 0.85, blue: 0.89)   // srebro
            default: return Color(red: 0.80, green: 0.60, blue: 0.42) // brąz
            }
        }
    }

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
        let barwa = PaletaUlubionych.barwa(miejsce)
        Image(systemName: "star.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(barwa)
            .shadow(color: Color.black.opacity(0.55), radius: 1.5, x: 0, y: 0.5)
            .help(miejsce == 0 ? "Najczęściej wybierany" : "Często wybierany")
    }

    /// w calosci (bez ucinania), jak w podgladzie Windows i Mission Control.
    private func preview(for item: SwitcherItem, showsControls: Bool, isSelected: Bool) -> some View {
        let symbol = Settings.modifier.symbol
        // Ten sam stan co w karcie - pusta gwiazdka „dodaj do ulubionych" ma sie
        // pokazywac tylko pod kursorem, zeby nie zasmiecac calej listy.
        let podKursorem = model.hoveredID == item.id
        return ZStack(alignment: .topLeading) {
            // Kadr bez zrzutu ma wygladac na zamierzony, a nie na pusty. Plaski
            // ciemny prostokat czyta sie jak „cos sie nie wczytalo"; delikatny
            // gradient z wieksza ikona wyglada jak karta programu.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.30), Color.black.opacity(0.16)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            if let thumbnail = item.thumbnail {
                // Zrzut WYPELNIA kadr, zamiast miescic sie w nim w calosci.
                // Okna sa rozne, kadr jest jeden - przy mieszczeniu w calosci kazda
                // karta miala po bokach szare pasy roznej szerokosci i rzad kart
                // wygladal jak plot z nierownych desek. Gora okna (pasek tytulu,
                // karty, tresc) i tak niesie cala rozpoznawalnosc, wiec kadrujemy
                // od gory - nic wartego zapamietania nie znika.
                //
                // Rozmiar podany WPROST, nie `maxWidth: .infinity`: obraz wypelniajacy
                // kadr jest szerszy niz kadr, a wtedy „nieskonczona" szerokosc pozwala
                // mu rozepchnac cala warstwe. Plakietka biurka i ikona programu, ktore
                // stoja przy krawedziach, wyjezdzaly wtedy poza karte i system je
                // przycinał - „Biurko 3" na ekranie konczylo sie jako „Biurko".
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: HUDLayout.cardWidth - 18, height: HUDLayout.previewHeight, alignment: .top)
                    .clipped()
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .shadow(color: Color.black.opacity(0.30), radius: 8, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if item.thumbnail != nil, let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if model.pierwszeKarty.contains(item.id), !item.bundleID.isEmpty {
                let miejsce = Ulubione.miejsce(programu: item.bundleID)
                Button {
                    if let index = model.index(of: item.id) { model.onPrzypnij?(index) }
                } label: {
                    if let miejsce {
                        gwiazdkaUlubionego(miejsce)
                    } else {
                        // Pusta gwiazdka pojawia sie pod kursorem - zeby dalo sie
                        // dodac program do ulubionych jednym klikiem, bez szukania
                        // ustawien. Bez kursora nie zasmieca listy.
                        Image(systemName: "star")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                            .opacity(podKursorem ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .help(miejsce == nil ? "Dodaj do ulubionych (⌘D)" : "Usuń z ulubionych (⌘D)")
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
                    // Plakietka nie moze sie zwezac razem z kadrem - przy waskiej
                    // karcie „Biurko 3" traci numer i zostaje samo „Biurko",
                    // czyli napis, ktory nie mowi juz nic.
                    .fixedSize()
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
                // Przyciski zostaja widoczne zawsze (mysz w tym oknie nie wybiera,
                // wiec nie ma jak ich „wywolac"), ale w spoczynku sa ledwo widoczne -
                // dwadziescia osiem kart z wyraznymi krzyzykami to sciana ikon.
                .opacity(isSelected || model.hoveredID == item.id ? 1 : 0.28)
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
