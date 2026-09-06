import AppKit
import SwiftUI

// MARK: - Mikser dzwieku
//
// Jedno okno na pytanie „co teraz gra i jak to uciszyc". Otwiera je skrot
// (domyslnie ⌥⌘S) albo pozycja w menu paska.
//
// Co tu JEST, bo dziala:
//   • lista programow, ktore naprawde graja - czytana z CoreAudio, nie zgadywana,
//   • wyciszenie kazdego z osobna (macOS 14.2+) i przywrocenie,
//   • glosnosc calego systemu.
//
// Czego tu NIE MA i dlaczego: suwaka glosnosci OSOBNO dla programu ani pasm
// ekwalizera. Zeby przyciszyc jeden program do 40 procent, trzeba przejac jego
// dzwiek, przemnozyc probki i wypuscic je z powrotem przez wlasne urzadzenie -
// to silnik, nie suwak. Suwak bez tego silnika wygladalby jak dzialajacy i nie
// robilby nic, a to gorsze niz jego brak.

final class ModelMiksera: ObservableObject {
    struct Pozycja: Identifiable {
        let id: pid_t
        let nazwa: String
        let ikona: NSImage?
        let gra: Bool
        let wyciszony: Bool
        /// 1.0 = bez zmiany. Suwak pokazuje to jako 100%.
        let poziom: Float
    }

    @Published private(set) var pozycje: [Pozycja] = []
    /// Grajace karty przegladarek, po programie. To odpowiedz na „pokaz KAZDA
    /// grajaca zakladke" - CoreAudio widzi tylko caly Chrome, karty widac przez
    /// Dostepnosc (patrz `KartyDzwieku`).
    @Published private(set) var karty: [pid_t: [KartaGrajaca]] = [:]
    @Published var glosnoscSystemu: Double = 0.5 {
        didSet {
            guard !wczytywanie else { return }
            GlosnoscAplikacji.glosnoscSystemu = Float(glosnoscSystemu)
        }
    }
    /// `false`, gdy urzadzenie wyjscia nie oddaje glosnosci - tak bywa przy HDMI
    /// albo zewnetrznym wzmacniaczu. Wtedy suwak jest wylaczony, a nie udaje.
    @Published private(set) var glosnoscDostepna = true
    private var wczytywanie = false
    private var zegar: Timer?

    func zacznij() {
        odswiez()
        zegar = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.odswiez()
        }
    }

    func przestan() {
        zegar?.invalidate()
        zegar = nil
    }

    func odswiez() {
        Dzwiek.odswiez()
        GlosnoscAplikacji.posprzatajPoZamknietych()
        let grajace = Dzwiek.grajace()
        let wyciszone = GlosnoscAplikacji.wyciszone
        // Program przyciszony ma zostac na liscie takze wtedy, gdy chwilowo milczy -
        // inaczej znikalby razem z suwakiem, ktory czlowiek wlasnie ustawil.
        let zmienione = GlosnoscAplikacji.zmienione

        // Pokazujemy tylko programy WIDOCZNE dla czlowieka. Dzwiek zglasza procesy
        // pomocnicze (np. Chrome Helper), ale nikt nie szuka na liscie pomocnika -
        // szuka Chrome'a.
        var wynik: [Pozycja] = []
        for program in NSWorkspace.shared.runningApplications
        where program.activationPolicy == .regular {
            let pid = program.processIdentifier
            let gra = grajace.contains(pid)
            let wyciszony = wyciszone.contains(pid)
            let zmieniony = zmienione.contains(pid)
            guard gra || wyciszony || zmieniony else { continue }
            wynik.append(Pozycja(id: pid,
                                 nazwa: program.localizedName ?? "pid \(pid)",
                                 ikona: program.icon,
                                 gra: gra,
                                 wyciszony: wyciszony,
                                 poziom: GlosnoscAplikacji.poziom(pid: pid)))
        }
        pozycje = wynik.sorted { $0.nazwa.localizedCaseInsensitiveCompare($1.nazwa) == .orderedAscending }

        // Karty pytamy tylko o te przegladarki, ktore naprawde graja - chodzenie
        // po drzewie Dostepnosci kilkudziesieciu kart co sekunde bez powodu
        // kosztowaloby wiecej niz cala reszta okna.
        var noweKarty: [pid_t: [KartaGrajaca]] = [:]
        for karta in KartyDzwieku.grajace(wsrodGrajacych: grajace) {
            noweKarty[karta.pid, default: []].append(karta)
        }
        karty = noweKarty

        wczytywanie = true
        if let poziom = GlosnoscAplikacji.glosnoscSystemu {
            glosnoscSystemu = Double(poziom)
            glosnoscDostepna = true
        } else {
            glosnoscDostepna = false
        }
        wczytywanie = false
    }

    /// Wycisza pojedyncza karte - i od razu pyta o stan, bo przegladarka
    /// przerysowuje swoj pasek dopiero po chwili.
    func przelaczKarte(_ karta: KartaGrajaca) {
        KartyDzwieku.przelaczWyciszenie(karta)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.odswiez() }
    }

    func pokazKarte(_ karta: KartaGrajaca) {
        KartyDzwieku.pokaz(karta)
    }

    func przelacz(_ pid: pid_t) {
        GlosnoscAplikacji.przelaczWyciszenie(pid: pid)
        odswiez()
    }

    /// Suwak przy programie. Ustawiamy od razu - dzwiek ma isc za palcem, a nie
    /// za puszczeniem myszy.
    func ustawPoziom(_ pid: pid_t, _ nowy: Float) {
        let osiagniety = GlosnoscAplikacji.ustawPoziom(pid: pid, nowy)
        // Gdy toru nie da sie zbudowac, poziom wraca do 100% - i suwak ma to
        // pokazac, zamiast stac w miejscu, w ktorym nic sie nie stalo.
        if abs(osiagniety - nowy) > 0.01 { odswiez() } else { odswiezCicho(pid: pid, poziom: osiagniety) }
    }

    /// Zmiana samego poziomu bez pytania systemu o cala liste - suwak ciagniety
    /// mysza wywolywalby inaczej kilkadziesiat odczytow CoreAudio na sekunde.
    private func odswiezCicho(pid: pid_t, poziom: Float) {
        guard let miejsce = pozycje.firstIndex(where: { $0.id == pid }) else { return }
        let stara = pozycje[miejsce]
        pozycje[miejsce] = Pozycja(id: stara.id, nazwa: stara.nazwa, ikona: stara.ikona,
                                   gra: stara.gra, wyciszony: poziom <= 0.0001, poziom: poziom)
    }
}

struct MikserView: View {
    @ObservedObject var model: ModelMiksera

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Barwy.blekit)
                Text("Mikser dźwięku")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text(model.pozycje.isEmpty ? "cisza" : "\(model.pozycje.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            glosnosc

            Divider().opacity(0.25)

            if model.pozycje.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash").foregroundStyle(.secondary)
                    Text("Teraz nic nie gra.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.pozycje) { pozycja in
                            VStack(spacing: 6) {
                                wiersz(pozycja)
                                ForEach(model.karty[pozycja.id] ?? []) { karta in
                                    wierszKarty(karta)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if GlosnoscAplikacji.dostepne, !model.pozycje.isEmpty {
                Text("Suwak przy programie zmienia głośność TYLKO jego — reszta gra jak grała. 100% znaczy, że program nie przechodzi przez mikser w ogóle.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !GlosnoscAplikacji.dostepne {
                Text("Wyciszanie pojedynczego programu wymaga macOS 14.2 lub nowszego.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(tlo)
    }

    private var glosnosc: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Głośność systemu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $model.glosnoscSystemu, in: 0...1)
                    .disabled(!model.glosnoscDostepna)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(Int(model.glosnoscSystemu * 100))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            if !model.glosnoscDostepna {
                Text("To wyjście nie oddaje głośności systemowi (np. HDMI).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func wiersz(_ pozycja: ModelMiksera.Pozycja) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let ikona = pozycja.ikona {
                    Image(nsImage: ikona).resizable().frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(pozycja.nazwa)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(podpis(pozycja))
                        .font(.system(size: 10.5))
                        .foregroundStyle(barwaPodpisu(pozycja))
                }
                Spacer(minLength: 8)
                if pozycja.gra, !pozycja.wyciszony {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                        .shadow(color: Color.green.opacity(0.8), radius: 4)
                }
                Button {
                    model.przelacz(pozycja.id)
                } label: {
                    Image(systemName: pozycja.wyciszony ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pozycja.wyciszony ? Color.orange : Color.white)
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(pozycja.wyciszony ? 0.20 : 0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!GlosnoscAplikacji.dostepne)
                .help(pozycja.wyciszony ? "Przywróć dźwięk" : "Wycisz ten program")
            }

            // Suwak TEGO programu - to jest ta rzecz, ktorej macOS nie ma, a
            // Windows i Android maja. 100% znaczy „nie dotykamy niczego".
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(pozycja.poziom) },
                        set: { model.ustawPoziom(pozycja.id, Float($0)) }
                    ),
                    in: 0...2
                )
                .disabled(!GlosnoscAplikacji.dostepne)
                Text("\(Int((pozycja.poziom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                    .foregroundStyle(pozycja.poziom > 1.01 ? Color.orange : Color.primary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(pozycja.wyciszony ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(pozycja.wyciszony ? Color.orange.opacity(0.45)
                                                : Color.white.opacity(0.10),
                              lineWidth: 1)
        )
    }

    /// Jedna grajaca karta przegladarki.
    ///
    /// Wciecie i mniejszy krok mowia, ze to czesc programu wyzej - a nie osobny
    /// program. Klikniecie w tytul przenosi na te karte, glosnik ja wycisza.
    private func wierszKarty(_ karta: KartaGrajaca) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Button {
                model.pokazKarte(karta)
            } label: {
                Text(karta.tytul)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(karta.wyciszona ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .help("Przejdź do tej karty")
            Spacer(minLength: 6)
            if !karta.wyciszona {
                Circle().fill(Color.green).frame(width: 5, height: 5)
            }
            Button {
                model.przelaczKarte(karta)
            } label: {
                Image(systemName: karta.wyciszona ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(karta.wyciszona ? Color.orange : Color.primary)
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help(karta.wyciszona ? "Przywróć dźwięk tej karty" : "Wycisz tę kartę")
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }

    private func podpis(_ pozycja: ModelMiksera.Pozycja) -> String {
        if pozycja.wyciszony { return "wyciszony" }
        if pozycja.poziom > 1.01 { return "wzmocniony do \(Int((pozycja.poziom * 100).rounded()))%" }
        if pozycja.poziom < 0.99 { return "przyciszony do \(Int((pozycja.poziom * 100).rounded()))%" }
        return pozycja.gra ? "gra teraz" : "cicho"
    }

    private func barwaPodpisu(_ pozycja: ModelMiksera.Pozycja) -> Color {
        if pozycja.wyciszony { return .orange }
        if abs(pozycja.poziom - 1.0) > 0.01 { return Barwy.blekit }
        return pozycja.gra ? .green : .secondary
    }

    private var tlo: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Color.white.opacity(0.06), Color.clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
