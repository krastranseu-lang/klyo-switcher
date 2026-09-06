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
