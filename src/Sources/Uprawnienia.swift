import AppKit
import SwiftUI

// MARK: - Okno uprawnien
//
// macOS NIE POZWALA zadnemu programowi wlaczyc sobie zgody samemu - to celowa
// bariera bezpieczenstwa i nie da sie jej obejsc. Wszystko, co mozemy zrobic, to
// pokazac wprost: co jest wlaczone, czego brakuje, po co to komu i co dokladnie
// kliknac. Reszta to juz jedno przesuniecie przelacznika.
//
// Stan zgod sprawdzamy co sekunde, ale WYLACZNIE gdy to okno jest otwarte:
// system nie wysyla zadnego zdarzenia o nadaniu zgody, a uzytkownik ma zobaczyc
// zielona kropke w tej samej chwili, w ktorej przesunie przelacznik - bez
// zamykania i otwierania czegokolwiek.

enum RodzajZgody: String, CaseIterable, Identifiable {
    case dostepnosc
    case nagrywanie
    case automatyzacja

    var id: String { rawValue }

    var nazwa: String {
        switch self {
        case .dostepnosc: return "Dostępność"
        case .nagrywanie: return "Nagrywanie ekranu"
        case .automatyzacja: return "Automatyzacja"
        }
    }

    var konieczna: Bool { self == .dostepnosc }

    var poCo: String {
        switch self {
        case .dostepnosc:
            return "Bez niej program nie może przechwycić ⌘ Tab ani podnieść okna innego programu — czyli nie zrobi nic z tego, po co go zainstalowałeś."
        case .nagrywanie:
            return "Daje podgląd zawartości okien na liście zamiast samych ikon, a także tytuły okien tych programów, które same ich nie zgłaszają."
        case .automatyzacja:
            return "Potrzebna tylko wtedy, gdy chcesz widzieć osobno karty przeglądarek. W trybie „tylko okna” program nie pyta przeglądarek o nic."
        }
    }

    /// Dokladna sciezka w Ustawieniach - zeby nie trzeba bylo jej szukac.
    var gdzie: String {
        switch self {
        case .dostepnosc: return "Prywatność i ochrona → Dostępność"
        case .nagrywanie: return "Prywatność i ochrona → Nagrywanie ekranu"
        case .automatyzacja: return "Prywatność i ochrona → Automatyzacja"
        }
    }

    var nadana: Bool {
        switch self {
        case .dostepnosc: return Permissions.accessibilityGranted
        case .nagrywanie: return Permissions.screenRecordingGranted
        case .automatyzacja:
            // Systemu nie da sie o to zapytac wprost. Sprawdzamy skutek: jesli
            // program ma odczytane karty przegladarki, zgoda jest nadana.
            return !HistoriaKartPrzegladarki.brakKart
        }
    }

    func otworzUstawienia() {
        switch self {
        case .dostepnosc: Permissions.openAccessibilitySettings()
        case .nagrywanie: Permissions.openScreenRecordingSettings()
        case .automatyzacja: Permissions.openAutomationSettings()
        }
    }

    /// Poproszenie SYSTEMU o zgodę — to co innego niż otwarcie Ustawień.
    ///
    /// Bez tej prośby macOS nie zakłada programowi wpisu w Nagrywaniu ekranu.
    /// Człowiek widzi wtedy nazwę na liście i przesuwa przełącznik, ale system
    /// nie ma czego zapamiętać — przełącznik wraca do wyłączonego i wygląda to
    /// jak awaria programu. Otwarcie Ustawień samo w sobie NIGDY nie poprosi
    /// o zgodę; robi to dopiero wywołanie systemowe poniżej.
    func popros() {
        switch self {
        case .dostepnosc: Permissions.requestAccessibility()
        case .nagrywanie: Permissions.requestScreenRecording()
        case .automatyzacja: break   // pytana przy pierwszym sięgnięciu po karty
        }
    }

    /// Czy zgoda zaczyna obowiązywać dopiero po ponownym uruchomieniu programu.
    ///
    /// Nagrywanie ekranu tak działa w macOS: przełącznik można włączyć, ale
    /// działający proces nadal nie ma dostępu. Kto o tym nie wie, przełącza tam
    /// i z powrotem i jest pewien, że program jest zepsuty.
    var wymagaRestartu: Bool { self == .nagrywanie }
}

/// Jedno miejsce, przez ktore okno uprawnien pyta o karty. Ustawiane przez
/// kontroler przelacznika, zeby okno nie musialo znac calej reszty programu.
enum HistoriaKartPrzegladarki {
    static var brakKart: Bool = true
}

final class ModelUprawnien: ObservableObject {
    @Published private(set) var stan: [RodzajZgody: Bool] = [:]
    @Published var zgodaMartwa: Bool = false
    private var zegar: Timer?

    init() {
        odswiez()
    }

    func start() {
        odswiez()
        guard zegar == nil else { return }
        // Jedyny zegar w tym oknie i tylko na czas jego zycia: system nie daje
        // zdarzenia o nadaniu zgody, a uzytkownik ma zobaczyc zmiane natychmiast.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.odswiez()
        }
        RunLoop.main.add(timer, forMode: .common)
        zegar = timer
    }

    func stop() {
        zegar?.invalidate()
        zegar = nil
    }

    /// Wolane takze z widoku, zaraz po naprawie wpisu zgody.
    func odswiez() {
        var nowy: [RodzajZgody: Bool] = [:]
        for zgoda in RodzajZgody.allCases {
            nowy[zgoda] = zgoda.nadana
        }
        if nowy != stan {
            stan = nowy
        }
    }

    var gotowe: Bool { stan[.dostepnosc] == true }
    var wszystkie: Bool { RodzajZgody.allCases.allSatisfy { stan[$0] == true } }
}

final class OknoUprawnienController: NSObject, NSWindowDelegate {
    static let shared = OknoUprawnienController()

    private var okno: NSWindow?
    private let model = ModelUprawnien()

    private override init() { super.init() }

    /// `zgodaMartwa` znaczy: w Ustawieniach jest ptaszek, ale system i tak nie
    /// wpuszcza programu. Trzeba wtedy powiedziec cos zupelnie innego niz
    /// „wlacz zgode", bo uzytkownik ma ja WLACZONA i slusznie sie zloszczy.
    func pokaz(zgodaMartwa: Bool = false) {
        model.zgodaMartwa = zgodaMartwa
        model.start()
        if okno == nil {
            let widok = NSHostingView(rootView: WidokUprawnien(model: model, zamknij: { [weak self] in self?.schowaj() }))
            let utworzone = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            utworzone.title = "\(AppInfo.name) — zgody systemowe"
            utworzone.contentView = widok
            utworzone.isReleasedWhenClosed = false
            utworzone.delegate = self
            utworzone.center()
            okno = utworzone
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
        okno?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Widok

struct WidokUprawnien: View {
    @ObservedObject var model: ModelUprawnien
    let zamknij: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            naglowek
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 10) {
                    // Najpierw fakt: która kopia programu działa i skąd. Dopiero
                    // potem stan zgód — inaczej człowiek porównuje dwie rzeczy,
                    // nie wiedząc, że dotyczą różnych kopii.
                    skadDzialam
                    if model.zgodaMartwa {
                        zgodaMartwaPasek
                    } else if !model.gotowe {
                        naprawaZgody
                    }
                    ForEach(RodzajZgody.allCases) { zgoda in
                        wiersz(zgoda)
                    }
                    wyjasnienie
                }
                .padding(18)
            }
            Divider().opacity(0.5)
            stopka
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    /// Osobny komunikat na wypadek, gdy w Ustawieniach jest ptaszek, a program
    /// i tak nie dziala. To najczesciej zdarza sie po aktualizacji, ktora zmienila
    /// podpis programu: zgoda zostaje przypisana do STAREJ tozsamosci.
    @State private var naprawiam = false

    /// Skąd dokładnie działa ten program i w jakiej wersji.
    ///
    /// To jedyny sposób, żeby człowiek mógł porównać to, co widzi w Ustawieniach,
    /// z tym, co naprawdę jest uruchomione. Gdy w Dostępności stoi ptaszek przy
    /// „Klyo Switcher", a program mówi „zgoda wyłączona", odpowiedź prawie zawsze
    /// brzmi: to dwie różne kopie. Bez pokazania ścieżki wygląda to jak awaria
    /// programu, a jest zwykłym rozjazdem, który widać gołym okiem.
    private var skadDzialam: some View {
        let sciezka = Bundle.main.bundlePath
        let wlasciwa = sciezka == "/Applications/\(AppInfo.name).app"
            || sciezka == "\(NSHomeDirectory())/Applications/\(AppInfo.name).app"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: wlasciwa ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(wlasciwa ? Color.green : Color.orange)
                    .font(.system(size: 11))
                Text("Działa wersja \(AppInfo.version) z:")
                    .font(.system(size: 11, weight: .medium))
            }
            Text(sciezka)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !wlasciwa {
                Text("To nie jest miejsce, w którym program powinien stać. Zgody z Ustawień należą do kopii w katalogu Aplikacje, nie do tej. Przenieś program do Aplikacji i uruchom go stamtąd.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.secondary.opacity(0.07)))
    }

    /// Naprawa wpisu zgody. Dostępna ZAWSZE, gdy zgody brakuje - nie tylko wtedy,
    /// gdy program sam rozpozna, że wpis jest zerwany. Rozpoznanie bywa niepewne
    /// (nowa instalacja nie ma czego porównać), a człowiek patrzący na włączony
    /// przełącznik obok napisu „wyłączona" musi mieć co kliknąć.
    /// Ratunek dla zgody, która „się nie zaznacza".
    ///
    /// Wpis w systemie potrafi utknąć w stanie zepsutym: przełącznik daje się
    /// przesuwać, ale nie zostaje włączony. Jedyne, co pomaga, to usunąć wpis
    /// i pozwolić systemowi zapytać od nowa.
    private var naprawaNagrywania: some View {
        Button {
            naprawiam = true
            _ = Permissions.naprawZgodeNagrywania()
            Permissions.requestScreenRecording()
            model.odswiez()
            naprawiam = false
        } label: {
            Label("Przełącznik się nie zaznacza? Napraw wpis", systemImage: "wand.and.stars")
                .font(.system(size: 11.5))
        }
        .buttonStyle(.bordered)
        .disabled(naprawiam)
    }

    private var naprawaZgody: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Widzisz w Ustawieniach włączony przełącznik, a tutaj „wyłączona”?")
                .font(.system(size: 11.5, weight: .medium))
            Text("To znaczy, że zgoda należy do innej kopii programu — na przykład poprzedniej wersji albo kopii z numerem w nazwie. Mogę usunąć nieaktualny wpis; system zapyta o zgodę jeszcze raz i wystarczy jedno kliknięcie.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                naprawiam = true
                if Permissions.naprawZgode() {
                    Permissions.requestAccessibility()
                    model.odswiez()
                }
                naprawiam = false
            } label: {
                Label(naprawiam ? "Naprawiam…" : "Napraw wpis zgody", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .disabled(naprawiam)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.secondary.opacity(0.07)))
    }

    private var zgodaMartwaPasek: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("Zgoda jest zaznaczona, ale system jej nie honoruje")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("macOS przypisał zgodę do poprzedniej kopii programu, a ta nie może jej odziedziczyć. Ptaszek w Ustawieniach dotyczy tamtej kopii — dlatego jego przełączanie nic nie daje. Mogę usunąć nieaktualny wpis za Ciebie: system zapyta o zgodę jeszcze raz i wystarczy jedno kliknięcie.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    naprawiam = true
                    if Permissions.naprawZgode() {
                        // Po usunieciu wpisu system pyta o zgode dopiero przy
                        // nastepnym siegnieciu po dostep - wiec od razu pytamy.
                        Permissions.requestAccessibility()
                        model.odswiez()
                    }
                    naprawiam = false
                } label: {
                    Label(naprawiam ? "Naprawiam…" : "Napraw to za mnie", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.orange)
                .disabled(naprawiam)

                Button {
                    RodzajZgody.dostepnosc.otworzUstawienia()
                } label: {
                    Text("Wolę zrobić to sam")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            Text("Gdy wolisz ręcznie: Ustawienia → Prywatność i ochrona → Dostępność, zaznacz „\(AppInfo.name)”, kliknij minus, potem plus i wskaż program w katalogu Aplikacje.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.orange.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var naglowek: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(model.gotowe ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: model.gotowe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(model.gotowe ? Color.green : Color.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.gotowe ? "Program jest gotowy do pracy" : "Brakuje jednej zgody")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.gotowe
                     ? (model.wszystkie ? "Wszystkie zgody nadane — nic więcej nie musisz robić." : "Działa. Zgody niżej są opcjonalne i dokładają wygody.")
                     : "macOS nie pozwala żadnemu programowi włączyć jej sobie samemu. Poniżej jest dokładnie to, co trzeba kliknąć.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func wiersz(_ zgoda: RodzajZgody) -> some View {
        let nadana = model.stan[zgoda] == true
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: nadana ? "checkmark.circle.fill" : (zgoda.konieczna ? "exclamationmark.circle.fill" : "circle.dashed"))
                    .font(.system(size: 14))
                    .foregroundStyle(nadana ? Color.green : (zgoda.konieczna ? Color.orange : Color.secondary))
                Text(zgoda.nazwa).font(.system(size: 13.5, weight: .semibold))
                if zgoda.konieczna {
                    Text("konieczna")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .foregroundStyle(Color.orange)
                } else {
                    Text("opcjonalna")
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(nadana ? "włączona" : "wyłączona")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(nadana ? Color.green : .secondary)
            }
            Text(zgoda.poCo)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !nadana {
                // Trzy kroki, nie ogolnik „wejdz w ustawienia" - bo wlasnie o to
                // pytal uzytkownik: co dokladnie ma kliknac.
                VStack(alignment: .leading, spacing: 4) {
                    krok(1, "Kliknij przycisk poniżej — otworzy dokładnie ten panel.")
                    krok(2, "Znajdź na liście „\(AppInfo.name)”.")
                    krok(3, "Przesuń przełącznik obok nazwy. Zielona kropka tutaj zapali się sama.")
                }
                .padding(.top, 2)
                Button {
                    // Najpierw prośba do systemu — bez niej macOS nie zakłada
                    // wpisu i przełącznik w Ustawieniach nie ma czego zapamiętać.
                    zgoda.popros()
                    zgoda.otworzUstawienia()
                } label: {
                    Label("Otwórz: \(zgoda.gdzie)", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(zgoda.konieczna ? Color.orange : Color.accentColor)
                if zgoda == .nagrywanie { naprawaNagrywania }
                if zgoda.wymagaRestartu {
                    // Bez tego zdania człowiek przesuwa przełącznik, nic się nie
                    // zmienia i jest pewien, że program jest zepsuty.
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.accentColor)
                        Text("Ta zgoda zaczyna działać dopiero po ponownym uruchomieniu programu. Po włączeniu przełącznika kliknij poniżej.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                    Button {
                        Permissions.uruchomPonownie()
                    } label: {
                        Label("Uruchom program ponownie", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(nadana ? Color.green.opacity(0.06) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(nadana ? Color.green.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func krok(_ numer: Int, _ tekst: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(numer)")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(tekst)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wyjasnienie: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dlaczego trzeba to klikać ręcznie")
                .font(.system(size: 12, weight: .semibold))
            Text("Zgody, o które prosi ten program, pozwalają czytać listę okien i przechwytywać skróty klawiszowe. macOS celowo nie pozwala włączyć ich programowo — gdyby pozwalał, każdy program mógłby to zrobić po cichu. Dlatego jedyne, co możemy, to otworzyć właściwy panel i pokazać, gdzie jest przełącznik.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Program niczego nie wysyła na zewnątrz. Listy okien i historia kopiowania zostają na tym komputerze.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private var stopka: some View {
        HStack {
            Text(model.gotowe ? "Możesz zamknąć to okno — ⌘ Tab już działa." : "To okno samo zauważy, gdy włączysz zgodę.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.gotowe ? "Gotowe" : "Zamknij") { zamknij() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
