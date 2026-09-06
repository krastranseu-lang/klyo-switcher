import AppKit

// MARK: - Wklejanie po naszemu (⌘V)
//
// Tresc skopiowana ze strony przynosi ze soba czcionke, kolor, tlo i adresy
// obwieszone doczepkami sledzacymi. Po wklejeniu do notatki albo do wiadomosci
// wyglada to jak wycinanka i zwykle konczy sie recznym czyszczeniem.
//
// Program moze to zrobic za czlowieka, ale MUSI to zrobic dokladnie w chwili
// wklejania - nie wczesniej. Zamiana schowka „na zapas" zabralaby formatowanie
// takze wtedy, gdy ktos kopiuje tabelke do arkusza i chce ja miec z formatowaniem.
//
// Dlatego: przechwytujemy ⌘V, przerabiamy schowek, wysylamy ⌘V jeszcze raz i
// oddajemy schowkowi poprzednia tresc. Program docelowy widzi zwykle wklejenie.
//
// Niezmiennik: gdy wszystkie przelaczniki sa wylaczone (tak jest domyslnie),
// ten kod NIE dotyka klawiatury ani schowka - `wlaczone` jest wtedy `false`
// i podsluch nawet nie pyta o litere V.

extension Wklejanie {
    /// Znak wlasny odciskany na zdarzeniach, ktore sami wysylamy.
    ///
    /// Bez niego podsluch przechwytywalby WLASNE ⌘V - i to nie tylko z tego pliku:
    /// historia schowka tez wysyla ⌘V po wybraniu wpisu. Zwykla flaga „teraz pomijaj"
    /// nie wystarczy, bo nie wie, ktore zdarzenie jest czyje.
    static let znakWlasny: Int64 = 0x4B4C_594F   // "KLYO"

    static func oznacz(_ zdarzenie: CGEvent?) {
        zdarzenie?.setIntegerValueField(.eventSourceUserData, value: znakWlasny)
    }

    static func nasze(_ zdarzenie: CGEvent) -> Bool {
        zdarzenie.getIntegerValueField(.eventSourceUserData) == znakWlasny
    }

    /// Czy w ogole mamy co robic. Sprawdzane w podsluchu, wiec musi byc tanie.
    static var wlaczone: Bool {
        Settings.wklejajCzystyTekst || Settings.wklejajPrzycinaj || Settings.wklejajBezDoczepek
    }

    /// Doczepki, ktore serwisy dokladaja do adresow, zeby wiedziec, skad ktos przyszedl.
    /// Nie niosa tresci - po ich usunieciu adres prowadzi w to samo miejsce.
    private static let doczepki: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "gclid", "fbclid", "mc_cid", "mc_eid", "igshid", "si", "ref_src", "ref_url",
        "yclid", "msclkid", "_ga", "vero_id", "wickedid"
    ]

    /// Przerobiony tekst albo `nil`, gdy nie ma czego przerabiac.
    static func przerob(_ tekst: String) -> String {
        var wynik = tekst
        if Settings.wklejajBezDoczepek {
            wynik = bezDoczepek(wynik)
        }
        if Settings.wklejajPrzycinaj {
            wynik = wynik.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return wynik
    }

    /// Usuniecie doczepek z KAZDEGO adresu w tekscie, nie tylko z calosci - ludzie
    /// wklejaja zdanie z linkiem w srodku rownie czesto, co sam link.
    static func bezDoczepek(_ tekst: String) -> String {
        guard tekst.contains("http") else { return tekst }
        let wzorzec = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+")
        guard let wzorzec else { return tekst }
        let zakres = NSRange(tekst.startIndex..<tekst.endIndex, in: tekst)
        var wynik = tekst
        // Od konca, zeby wczesniejsze podmiany nie przesuwaly kolejnych zakresow.
        for dopasowanie in wzorzec.matches(in: tekst, range: zakres).reversed() {
            guard let r = Range(dopasowanie.range, in: tekst) else { continue }
            let adres = String(tekst[r])
            guard var czesci = URLComponents(string: adres), let pytania = czesci.queryItems else { continue }
            let zostaja = pytania.filter { !doczepki.contains($0.name.lowercased()) }
            guard zostaja.count != pytania.count else { continue }
            czesci.queryItems = zostaja.isEmpty ? nil : zostaja
            guard let nowy = czesci.string else { continue }
            wynik.replaceSubrange(r, with: nowy)
        }
        return wynik
    }

    /// Cala droga: przerob schowek, wyslij ⌘V, oddaj schowek.
    ///
    /// `pomijanie` mowi podsluchowi, zeby przepuscil NASZE wlasne ⌘V - inaczej
    /// przechwycilby je jeszcze raz i program wpadlby w petle.
    static func wykonaj(pomijanie: @escaping (Bool) -> Void) {
        let schowek = NSPasteboard.general
        guard let oryginal = schowek.string(forType: .string) else {
            wyslijZPodmiana(pomijanie: pomijanie, przywroc: nil)
            return
        }
        let przerobiony = przerob(oryginal)
        // Czysty tekst = zapisujemy sam tekst, bez pozostalych typow (RTF, HTML).
        // Gdy przelacznik jest wylaczony, a tresc sie nie zmienila, nie ruszamy nic.
        let trzebaZmienic = Settings.wklejajCzystyTekst || przerobiony != oryginal
        var przywroc: [(NSPasteboard.PasteboardType, Data)] = []
        if trzebaZmienic {
            for typ in schowek.types ?? [] {
                if let dane = schowek.data(forType: typ) { przywroc.append((typ, dane)) }
            }
            schowek.clearContents()
            schowek.setString(przerobiony, forType: .string)
        }
        wyslijZPodmiana(pomijanie: pomijanie, przywroc: trzebaZmienic ? przywroc : nil)
    }

    /// Wyslanie ⌘V i - po chwili - oddanie schowka. Chwila jest potrzebna: program
    /// docelowy czyta schowek juz po tym, jak dostanie klawisze.
    private static func wyslijZPodmiana(pomijanie: @escaping (Bool) -> Void,
                                    przywroc: [(NSPasteboard.PasteboardType, Data)]?) {
        pomijanie(true)
        let v: CGKeyCode = 9
        let zrodlo = CGEventSource(stateID: .combinedSessionState)
        let dol = CGEvent(keyboardEventSource: zrodlo, virtualKey: v, keyDown: true)
        let gora = CGEvent(keyboardEventSource: zrodlo, virtualKey: v, keyDown: false)
        dol?.flags = .maskCommand
        gora?.flags = .maskCommand
        oznacz(dol)
        oznacz(gora)
        dol?.post(tap: .cghidEventTap)
        gora?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pomijanie(false)
            guard let przywroc, !przywroc.isEmpty else { return }
            let schowek = NSPasteboard.general
            schowek.clearContents()
            for (typ, dane) in przywroc {
                schowek.setData(dane, forType: typ)
            }
        }
    }
}
