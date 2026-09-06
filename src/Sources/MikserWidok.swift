import AppKit
import SwiftUI

// MARK: - Wyglad miksera
//
// Jedno okno na pytanie „co gra i jak to uciszyc". Uklad idzie od ogolu do
// szczegolu: glosnosc calego komputera na gorze, pod nia programy, a pod kazdym
// programem jego wlasne karty. Karta jest wcieta i ma cienszy suwak, bo to
// czesc programu wyzej, a nie osobny byt.
//
// Kolor niesie stan i tylko stan: zielen znaczy „gra teraz", pomarancz „wyciszone",
// blekit „zmienione przez ciebie". Gradienty sa wylacznie na tle i na wypelnieniu
// suwakow - tam, gdzie nie mowia niczego, czego nie widac.

struct MikserView: View {
    @ObservedObject var model: ModelMiksera

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            naglowek
            ScrollView {
                VStack(spacing: 14) {
                    kartaSystemu
                    ForEach(model.pozycje) { pozycja in
                        kartaProgramu(pozycja)
                    }
                    if model.pozycje.isEmpty { cisza }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            stopka
        }
        .frame(width: 440)
        .background(tlo)
    }

    // MARK: Naglowek

    private var naglowek: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Barwy.blekit, Barwy.fiolet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Mikser dźwięku")
                    .font(.system(size: 17, weight: .bold))
                Text(podpisNaglowka)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var podpisNaglowka: String {
        let ile = model.pozycje.count
        let kart = model.karty.values.reduce(0) { $0 + $1.count }
        if ile == 0 { return "cisza — nic teraz nie gra" }
        let programy = ile == 1 ? "1 program" : "\(ile) programy"
        return kart == 0 ? programy : "\(programy), \(kart) kart"
    }

    // MARK: Glosnosc systemu

    private var kartaSystemu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Cały komputer")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.glosnoscSystemu * 100))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            suwak(wartosc: Binding(get: { model.glosnoscSystemu },
                                   set: { model.glosnoscSystemu = $0 }),
                  zakres: 0...1,
                  barwy: [Color.secondary.opacity(0.8), Color.secondary],
                  wysoki: false)
                .disabled(!model.glosnoscDostepna)
            if !model.glosnoscDostepna {
                Text("To wyjście nie oddaje głośności systemowi (np. HDMI).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(szkloKarty(mocne: false))
    }

    // MARK: Program

    private func kartaProgramu(_ pozycja: ModelMiksera.Pozycja) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ikona(pozycja)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pozycja.nazwa)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(podpis(pozycja))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(barwaStanu(pozycja))
                }
                Spacer(minLength: 8)
                Text("\(Int((pozycja.poziom * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(pozycja.poziom > 1.01 ? Color.orange : Color.primary)
                przyciskGlosnika(wyciszony: pozycja.wyciszony, duzy: true) {
                    model.przelacz(pozycja.id)
                }
            }
            suwak(wartosc: Binding(get: { Double(pozycja.poziom) },
                                   set: { model.ustawPoziom(pozycja.id, Float($0)) }),
                  zakres: 0...2,
                  barwy: [Barwy.blekit, Barwy.fiolet],
                  wysoki: true)
                .disabled(!GlosnoscAplikacji.dostepne)

            let karty = model.karty[pozycja.id] ?? []
            if !karty.isEmpty {
                Divider().opacity(0.18)
                VStack(spacing: 9) {
                    ForEach(karty) { karta in wierszKarty(karta) }
                }
            }
        }
        .padding(14)
        .background(szkloKarty(mocne: pozycja.wyciszony))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(pozycja.wyciszony ? Color.orange.opacity(0.45)
                                                : Color.primary.opacity(0.07),
                              lineWidth: 1)
        )
    }

    private func ikona(_ pozycja: ModelMiksera.Pozycja) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let obraz = pozycja.ikona {
                Image(nsImage: obraz).resizable().frame(width: 30, height: 30)
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.25))
                    .frame(width: 30, height: 30)
            }
            if pozycja.gra, !pozycja.wyciszony {
                Circle().fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: Color.green.opacity(0.7), radius: 3)
                    .offset(x: 2, y: 2)
            }
        }
    }

    // MARK: Karta przegladarki

    private func wierszKarty(_ karta: KartaGrajaca) -> some View {
        let poziom = model.poziomKarty(karta)
        let powod = model.powodKarty(karta)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: karta.wyciszona ? "speaker.slash" : "waveform")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(karta.wyciszona ? Color.orange : Color.green)
                    .frame(width: 12)
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
                Text("\(Int((poziom * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                przyciskGlosnika(wyciszony: karta.wyciszona, duzy: false) {
                    model.przelaczKarte(karta)
                }
            }
            suwak(wartosc: Binding(get: { Double(poziom) },
                                   set: { model.ustawPoziomKarty(karta, Float($0)) }),
                  zakres: 0...1,
                  barwy: [Barwy.turkus, Barwy.blekit],
                  wysoki: false)
            if let powod {
                Text(powod)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 6)
    }

    // MARK: Czesci wspolne

    private func suwak(wartosc: Binding<Double>, zakres: ClosedRange<Double>,
                       barwy: [Color], wysoki: Bool) -> some View {
        GeometryReader { miejsce in
            let szerokosc = miejsce.size.width
            let udzial = CGFloat((wartosc.wrappedValue - zakres.lowerBound)
                                 / (zakres.upperBound - zakres.lowerBound))
            let wysokosc: CGFloat = wysoki ? 8 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: wysokosc)
                Capsule()
                    .fill(LinearGradient(colors: barwy, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(szerokosc, szerokosc * udzial)), height: wysokosc)
                Circle()
                    .fill(Color.white)
                    .frame(width: wysoki ? 16 : 13, height: wysoki ? 16 : 13)
                    .shadow(color: Color.black.opacity(0.28), radius: 2, y: 1)
                    .offset(x: max(0, min(szerokosc - (wysoki ? 16 : 13),
                                          szerokosc * udzial - (wysoki ? 8 : 6.5))))
            }
            .frame(height: wysoki ? 20 : 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { ruch in
                    let nowy = Double(ruch.location.x / max(1, szerokosc))
                    let wartoscNowa = zakres.lowerBound
                        + min(1, max(0, nowy)) * (zakres.upperBound - zakres.lowerBound)
                    wartosc.wrappedValue = wartoscNowa
                }
            )
        }
        .frame(height: wysoki ? 20 : 16)
    }

    private func przyciskGlosnika(wyciszony: Bool, duzy: Bool, akcja: @escaping () -> Void) -> some View {
        Button(action: akcja) {
            Image(systemName: wyciszony ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: duzy ? 12 : 10, weight: .semibold))
                .foregroundStyle(wyciszony ? Color.orange : Color.primary.opacity(0.85))
                .frame(width: duzy ? 30 : 25, height: duzy ? 26 : 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(wyciszony ? 0.14 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .help(wyciszony ? "Przywróć dźwięk" : "Wycisz")
    }

    private var cisza: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("Teraz nic nie gra")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var stopka: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().opacity(0.2)
            Text("Suwak zmienia głośność tylko tego, przy czym stoi. 100% znaczy, że dźwięk idzie systemem i nie przechodzi przez mikser.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private func podpis(_ pozycja: ModelMiksera.Pozycja) -> String {
        if pozycja.wyciszony { return "wyciszony" }
        if pozycja.poziom > 1.01 { return "wzmocniony" }
        if pozycja.poziom < 0.99 { return "przyciszony" }
        return pozycja.gra ? "gra teraz" : "cicho"
    }

    private func barwaStanu(_ pozycja: ModelMiksera.Pozycja) -> Color {
        if pozycja.wyciszony { return .orange }
        if abs(pozycja.poziom - 1.0) > 0.01 { return Barwy.blekit }
        return pozycja.gra ? .green : .secondary
    }

    private func szkloKarty(mocne: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(mocne ? 0.08 : 0.05))
    }

    private var tlo: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Barwy.blekit.opacity(0.10), Color.clear, Barwy.fiolet.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
