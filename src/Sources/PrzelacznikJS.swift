import AppKit
import ApplicationServices

// MARK: - Przelacznik „JavaScript z Apple Events"
//
// Bez niego zadne sterowanie glosnoscia karty nie ma prawa zadzialac, bo
// przegladarka odmawia wykonania skryptu. Zmierzone na zywym Chrome:
//
//     Widok → Deweloper → „Zezwól na kod JavaScript z Apple Events"  (bez znacznika)
//
// Dobra wiadomosc: „JavaScript" i „Apple Events" to nazwy wlasne i nie sa
// tlumaczone, wiec ta sama para slow znajduje te pozycje w kazdym jezyku.
//
// Chrome ma ja w menu i mozemy ja WLACZYC - jednym kliknieciem, na zyczenie
// czlowieka. Safari trzyma to za dwoma przelacznikami, z ktorych pierwszy
// (pokazanie menu dla twórców) siedzi w ustawieniach w chronionym katalogu -
// tam mozemy tylko powiedziec, co zrobic.

enum StanJS {
    case wlaczony
    case wylaczony
    case brakPozycji
}

enum PrzelacznikJS {
    private static let szukaneSlowa = ["javascript", "apple events"]

    static func stan(pid: pid_t) -> StanJS {
        guard let pozycja = znajdz(pid: pid) else { return .brakPozycji }
        let znacznik = (axCopy(pozycja, "AXMenuItemMarkChar") as? String) ?? ""
        return znacznik.isEmpty ? .wylaczony : .wlaczony
    }

    // Nie ma tu funkcji „wlacz" i nie bedzie. Zmierzone na zywym systemie:
    // pozycji w pasku menu nie da sie nacisnac, dopoki program nie jest AKTYWNY -
    // otwarte podmenu Chrome bylo w calosci wyszarzone, bo na wierzchu stal inny
    // program. Zeby to obejsc, trzeba by wyciagac przegladarke na wierzch, a to
    // jest dokladnie to, czego w tym programie byc nie moze: wszystko ma sie
    // dziac w tle, bez ruszania tego, co czlowiek ma przed soba.
    //
    // Zostaje wiec sam ODCZYT - po to, zeby okno mogło powiedziec prawde o tym,
    // czego brakuje, zamiast milczec albo udawac.

    /// Szuka pozycji w PASKU MENU programu - nie w menu kontekstowym.
    private static func znajdz(pid: pid_t) -> AXUIElement? {
        let aplikacja = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(aplikacja, 1.0)
        guard let pasek = elementy(aplikacja, kAXChildrenAttribute)
            .first(where: { (axCopy($0, kAXRoleAttribute) as? String) == kAXMenuBarRole }) else {
            return nil
        }
        return szukajWMenu(pasek, glebokosc: 0)
    }

    private static func szukajWMenu(_ element: AXUIElement, glebokosc: Int) -> AXUIElement? {
        guard glebokosc < 6 else { return nil }
        for pozycja in elementy(element, kAXChildrenAttribute) {
            if let tytul = (axCopy(pozycja, kAXTitleAttribute) as? String)?.lowercased(),
               szukaneSlowa.allSatisfy({ tytul.contains($0) }) {
                return pozycja
            }
            if let znaleziona = szukajWMenu(pozycja, glebokosc: glebokosc + 1) { return znaleziona }
        }
        return nil
    }

    private static func elementy(_ element: AXUIElement, _ atrybut: String) -> [AXUIElement] {
        guard let surowe = axCopy(element, atrybut),
              CFGetTypeID(surowe) == CFArrayGetTypeID() else { return [] }
        let tablica = surowe as! CFArray
        var wynik: [AXUIElement] = []
        for numer in 0..<CFArrayGetCount(tablica) {
            guard let wskaznik = CFArrayGetValueAtIndex(tablica, numer) else { continue }
            let pozycja = unsafeBitCast(wskaznik, to: AXUIElement.self)
            guard CFGetTypeID(pozycja) == AXUIElementGetTypeID() else { continue }
            wynik.append(pozycja)
        }
        return wynik
    }
}
