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
    }

    @Published private(set) var pozycje: [Pozycja] = []
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

        // Pokazujemy tylko programy WIDOCZNE dla czlowieka. Dzwiek zglasza procesy
        // pomocnicze (np. Chrome Helper), ale nikt nie szuka na liscie pomocnika -
        // szuka Chrome'a.
        var wynik: [Pozycja] = []
        for program in NSWorkspace.shared.runningApplications
        where program.activationPolicy == .regular {
            let pid = program.processIdentifier
            let gra = grajace.contains(pid)
            let wyciszony = wyciszone.contains(pid)
            guard gra || wyciszony else { continue }
            wynik.append(Pozycja(id: pid,
                                 nazwa: program.localizedName ?? "pid \(pid)",
                                 ikona: program.icon,
                                 gra: gra,
                                 wyciszony: wyciszony))
        }
        pozycje = wynik.sorted { $0.nazwa.localizedCaseInsensitiveCompare($1.nazwa) == .orderedAscending }

        wczytywanie = true
        if let poziom = GlosnoscAplikacji.glosnoscSystemu {
            glosnoscSystemu = Double(poziom)
            glosnoscDostepna = true
        } else {
            glosnoscDostepna = false
        }
        wczytywanie = false
    }

    func przelacz(_ pid: pid_t) {
        GlosnoscAplikacji.przelaczWyciszenie(pid: pid)
        odswiez()
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
                            wiersz(pozycja)
                        }
                    }
                }
                .frame(maxHeight: 260)
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
        HStack(spacing: 10) {
            if let ikona = pozycja.ikona {
                Image(nsImage: ikona).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(pozycja.nazwa)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(pozycja.wyciszony ? "wyciszony" : "gra teraz")
                    .font(.system(size: 10.5))
                    .foregroundStyle(pozycja.wyciszony ? Color.orange : Color.green)
            }
            Spacer(minLength: 8)
            // Zywy wskaznik: swieci przy tym, co naprawde wysyla dzwiek.
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

    private var tlo: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Color.white.opacity(0.06), Color.clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
