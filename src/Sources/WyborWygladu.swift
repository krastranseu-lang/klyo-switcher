import SwiftUI

// MARK: - Wybor wygladu podgladu: obrazkiem, nie opisem
//
// Prosba wlasciciela projektu: „zeby user wybral obrazek, a nie trescia".
// Trzy warianty roznia sie tym, CO WIDAC po najechaniu mysza - a to najlatwiej
// pokazac rysunkiem tego, co sie stanie. Opis pod spodem zostaje jednym zdaniem,
// dla kogos, kto woli przeczytac.
//
// Rysunki sa robione ksztaltami SwiftUI, nie plikami graficznymi: skaluja sie
// z ekranem, dopasowuja do jasnego i ciemnego tla i nie dokladaja nic do paczki.

/// Co program pokazuje, gdy kursor stanie na karcie.
enum TrybPodgladu: String, CaseIterable, Identifiable {
    /// Duzy, ostry zrzut okna na srodku panelu - da sie przeczytac tresc strony.
    case duzy
    /// Sama karta rosnie pod kursorem. Mniej zaslania, ale tresci nie przeczytasz.
    case powiekszenie
    /// Nic sie nie dzieje - lista stoi w miejscu.
    case brak

    var id: String { rawValue }

    var nazwa: String {
        switch self {
        case .duzy: return "Duży podgląd"
        case .powiekszenie: return "Powiększenie karty"
        case .brak: return "Bez podglądu"
        }
    }

    var opis: String {
        switch self {
        case .duzy: return "Okno pod kursorem pokazuje się duże, na środku — widać treść strony."
        case .powiekszenie: return "Karta pod kursorem lekko rośnie. Nic nie zasłania listy."
        case .brak: return "Lista stoi nieruchomo. Najlżejsze dla starszych Maców."
        }
    }
}

/// Rysunek jednego wariantu: panel przelacznika w miniaturze.
private struct RysunekWariantu: View {
    let tryb: TrybPodgladu
    let wybrany: Bool

    private var barwaKarty: Color { Color.primary.opacity(0.16) }

    var body: some View {
        ZStack {
            // Siatka kart - trzy na dwa, jak w prawdziwym panelu.
            VStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { rzad in
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { kolumna in
                            let podKursorem = (rzad == 0 && kolumna == 1)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(podKursorem && tryb == .powiekszenie
                                      ? Color.accentColor.opacity(0.55) : barwaKarty)
                                .frame(width: 26, height: 18)
                                .scaleEffect(podKursorem && tryb == .powiekszenie ? 1.28 : 1)
                                .zIndex(podKursorem ? 1 : 0)
                        }
                    }
                }
            }
            // Wariant „duzy": prostokat podgladu na wierzchu, z paskiem tytulu.
            if tryb == .duzy {
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 58, height: 34)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 40, height: 4)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Barwy.obramowanie, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 6, y: 2)
            }
            // Wariant „brak": kursor stoi, nic sie nie zmienia - pokazujemy sam kursor.
            if tryb == .brak {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .offset(x: 2, y: -6)
            }
        }
        .frame(width: 118, height: 66)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(wybrany ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: wybrany ? 2 : 1)
        )
    }
}

// MARK: - Szybkie akcje: ktory klawisz przytrzymac
//
// Znowu obrazkiem: rysunek pokazuje wcisniety klawisz i wyskakujace okienko.
// Wybor modyfikatora to trzy kafelki, a nie lista rozwijana - klikasz ten,
// ktorego trzymasz kciukiem.

struct WyborSzybkichAkcji: View {
    @Binding var wlaczone: Bool
    @Binding var modyfikator: HotkeyModifier
    @Binding var czasMs: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Przytrzymanie klawisza otwiera szybkie akcje", isOn: $wlaczone)

            HStack(spacing: 12) {
                ForEach(HotkeyModifier.allCases, id: \.rawValue) { wariant in
                    let wybrany = modyfikator == wariant
                    Button {
                        modyfikator = wariant
                    } label: {
                        VStack(spacing: 7) {
                            ZStack(alignment: .bottomTrailing) {
                                // Klawisz
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(wybrany ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
                                    .frame(width: 46, height: 34)
                                    .overlay(
                                        Text(wariant.symbol)
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(wybrany ? Color.accentColor : Color.primary.opacity(0.65))
                                    )
                                // Okienko, ktore z niego wyskakuje
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(wybrany ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.22))
                                    .frame(width: 30, height: 20)
                                    .overlay(
                                        VStack(spacing: 2) {
                                            ForEach(0..<3, id: \.self) { _ in
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.white.opacity(0.75))
                                                    .frame(width: 18, height: 2)
                                            }
                                        }
                                    )
                                    .offset(x: 16, y: 12)
                            }
                            .frame(width: 70, height: 52, alignment: .topLeading)
                            Text(wariant.symbol + " " + nazwa(wariant))
                                .font(.system(size: 11, weight: wybrany ? .semibold : .regular))
                        }
                        .frame(width: 88, height: 82)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(wybrany ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: wybrany ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!wlaczone)
                }
            }
            .opacity(wlaczone ? 1 : 0.4)

            HStack(spacing: 10) {
                Text("Po jakim czasie")
                    .font(.system(size: 12))
                Slider(value: Binding(get: { Double(czasMs) },
                                      set: { czasMs = Int($0.rounded()) }),
                       in: 200...900, step: 50)
                    .frame(width: 190)
                Text("\(czasMs) ms")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .disabled(!wlaczone)
            .opacity(wlaczone ? 1 : 0.4)

            Text("Sam przytrzymany klawisz otwiera panel. Użyty razem z innym klawiszem działa jak zwykle — ⌃⇥ i ⌃1…9 zostają nietknięte.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nazwa(_ wariant: HotkeyModifier) -> String {
        switch wariant {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        }
    }
}

// MARK: - Jak dlugo trzymamy historie kopiowania
//
// Te sama zasada co wyzej: wybor obrazkiem. Kazdy wariant to slupek pokazujacy,
// ile historii zostaje - od jednego dnia po „bez konca". Pytanie „jak dlugo
// przechowuja sie skopiowane rzeczy" padlo wprost i az do 1.44.0 nie mialo
// odpowiedzi, bo program pilnowal tylko LICZBY wpisow, nigdy ich wieku.

struct WyborOkresuHistorii: View {
    @Binding var dni: Int

    private static let warianty: [(dni: Int, nazwa: String, slupki: Int)] = [
        (1, "1 dzień", 1),
        (7, "Tydzień", 2),
        (30, "Miesiąc", 3),
        (0, "Bez limitu", 4),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(Self.warianty, id: \.dni) { wariant in
                    let wybrany = dni == wariant.dni
                    Button {
                        dni = wariant.dni
                    } label: {
                        VStack(spacing: 6) {
                            HStack(alignment: .bottom, spacing: 3) {
                                ForEach(0..<4, id: \.self) { numer in
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(numer < wariant.slupki
                                              ? (wybrany ? Color.accentColor : Color.primary.opacity(0.45))
                                              : Color.primary.opacity(0.12))
                                        .frame(width: 6, height: 10 + CGFloat(numer) * 6)
                                }
                            }
                            .frame(height: 30, alignment: .bottom)
                            Text(wariant.nazwa)
                                .font(.system(size: 11, weight: wybrany ? .semibold : .regular))
                        }
                        .frame(width: 74, height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(wybrany ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: wybrany ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(dni == 0
                 ? "Wpisy zostają, dopóki nie wypchną ich nowsze. Przypięte zostają zawsze."
                 : "Wpisy starsze niż \(dni) dni znikają same. Przypięte zostają zawsze.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Trzy rysunki obok siebie - klikniecie wybiera wariant.
struct WyborTrybuPodgladu: View {
    @Binding var wybor: TrybPodgladu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TrybPodgladu.allCases) { tryb in
                    Button {
                        wybor = tryb
                    } label: {
                        VStack(spacing: 6) {
                            RysunekWariantu(tryb: tryb, wybrany: wybor == tryb)
                            HStack(spacing: 5) {
                                Image(systemName: wybor == tryb ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(wybor == tryb ? Color.accentColor : Color.secondary)
                                Text(tryb.nazwa)
                                    .font(.system(size: 11.5, weight: wybor == tryb ? .semibold : .regular))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(tryb.opis)
                }
            }
            Text(wybor.opis)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
