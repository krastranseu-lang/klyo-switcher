import AppKit

// MARK: - Ile rzeczy zostalo niezalatwionych
//
// Zgloszenie wlasciciela: „automatyzacja jest wylaczona, bo nasza aplikacja nie
// pyta - i ma to pisac w interfejsie czytelnie, np. liczba".
//
// Dwie osobne usterki w jednym zdaniu:
//   1. program NIE PROSIL systemu o zgode na automatyzacje, tylko odsylal
//      czlowieka do Ustawien systemowych - a tam trzeba wiedziec, czego szukac,
//   2. nigdzie nie bylo widac, ILE rzeczy czeka. Program wygladal na gotowy,
//      a polowa jego funkcji milczala.
//
// `StanZgod` liczy braki w jednym miejscu, zeby ta sama liczba mogla stanac
// przy ikonie w pasku, w oknie ustawien i w kazdym nastepnym miejscu, ktore ja
// pokaze. Jedna liczba, jedno zrodlo - inaczej rozjedzie sie jak kazda kopia.

struct BrakZgody: Identifiable {
    enum Rodzaj { case dostepnosc, nagrywanie, automatyzacja(bundleID: String) }

    let id: String
    let nazwa: String
    /// Co konkretnie NIE dziala, gdy tej zgody brak - bez tego zdania czlowiek
    /// nie wie, czy warto ja nadawac.
    let skutek: String
    let rodzaj: Rodzaj
}

enum StanZgod {
    /// Wszystko, czego programowi brakuje DO TEGO, CO MA WLACZONE.
    ///
    /// Zgody nie sa liczone „na zapas": gdy ktos wylaczyl miniatury, brak zgody
    /// na nagrywanie ekranu nie jest zadnym brakiem i nie ma prawa swiecic sie
    /// jako zaleglosc.
    static func braki() -> [BrakZgody] {
        var wynik: [BrakZgody] = []

        if !Permissions.accessibilityGranted {
            wynik.append(BrakZgody(
                id: "dostepnosc",
                nazwa: "Dostępność",
                skutek: "Bez niej ⌘ Tab nie dochodzi do programu — system pokazuje swój przełącznik.",
                rodzaj: .dostepnosc
            ))
        }

        if Settings.showThumbnails, !Permissions.screenRecordingGranted {
            wynik.append(BrakZgody(
                id: "nagrywanie",
                nazwa: "Nagrywanie ekranu",
                skutek: "Karty pokazują ikony zamiast podglądu okien i nie znają tytułów.",
                rodzaj: .nagrywanie
            ))
        }

        // Automatyzacja liczy sie tylko wtedy, gdy czlowiek WLACZYL karty
        // przegladarek - inaczej program prosilby o zgode, ktorej nie uzyje.
        if Settings.browserMode.usesTabs {
            for program in NSWorkspace.shared.runningApplications {
                guard let identyfikator = program.bundleIdentifier,
                      BrowserSupport.isSupported(identyfikator),
                      !Permissions.automatyzacjaNadana(dla: identyfikator) else { continue }
                wynik.append(BrakZgody(
                    id: "automatyzacja:\(identyfikator)",
                    nazwa: "Automatyzacja — \(program.localizedName ?? identyfikator)",
                    skutek: "Karty tej przeglądarki nie trafiają na listę — widać same okna.",
                    rodzaj: .automatyzacja(bundleID: identyfikator)
                ))
            }
        }
        return wynik
    }

    static var ile: Int { braki().count }

    // MARK: Proszenie o zgode

    /// Prosi system o zgode - czyli pokazuje TO okno, ktorego czlowiek oczekuje.
    ///
    /// `AEDeterminePermissionToAutomateTarget` z `askUserIfNeeded: true` jest
    /// jedynym sposobem, zeby macOS zapytal o automatyzacje konkretnego programu.
    /// Wywolanie potrafi czekac na odpowiedz czlowieka, wiec idzie poza glowny
    /// watek - inaczej caly program stalby z zawieszonym interfejsem.
    static func popros(_ brak: BrakZgody, gotowe: @escaping (Bool) -> Void) {
        switch brak.rodzaj {
        case .dostepnosc:
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
            gotowe(Permissions.accessibilityGranted)
        case .nagrywanie:
            let nadana = Permissions.requestScreenRecording()
            if !nadana { Permissions.openScreenRecordingSettings() }
            gotowe(nadana)
        case .automatyzacja(let bundleID):
            DispatchQueue.global(qos: .userInitiated).async {
                var cel = AEAddressDesc()
                var bajty = Array(bundleID.utf8)
                let utworzenie = AECreateDesc(typeApplicationBundleID, &bajty, bajty.count, &cel)
                guard utworzenie == noErr else {
                    DispatchQueue.main.async { gotowe(false) }
                    return
                }
                defer { AEDisposeDesc(&cel) }
                let wynik = AEDeterminePermissionToAutomateTarget(&cel, typeWildCard, typeWildCard, true)
                DispatchQueue.main.async {
                    if wynik != noErr {
                        // Czlowiek odmowil albo system juz raz zapytal i zapamietal
                        // odmowe - wtedy jedyna droga sa Ustawienia systemowe.
                        Permissions.openAutomationSettings()
                    }
                    gotowe(wynik == noErr)
                }
            }
        }
    }
}
