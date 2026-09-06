import AppKit

// MARK: - Rozmowa z KONKRETNYM oknem przegladarki
//
// AppleScript adresuje program po identyfikatorze - i to jest tu caly klopot.
// Zmierzone na maszynie wlasciciela: dziewiec procesow o identyfikatorze
// `com.google.Chrome` (rozne konta uruchomione osobno). Polecenie szlo wiec do
// tej instancji, ktora akurat odpowiadala pierwsza - a ta nie miala zadnych
// okien i odpowiadala „Nie mozna uzyskac window 1".
//
// Zdarzenie Apple Events da sie zaadresowac PIDEM. Kody komend wziete wprost ze
// slownikow przegladarek (`scripting.sdef`), nie z pamieci:
//     Chrome: klasa „CrSu", polecenie „ExJa", parametr javascript „JvSc",
//             klasa karty „CrTb", klasa okna „cwin"
//     Safari: klasa „sfri", polecenie „dojs", parametr „in" = „dcnm",
//             klasa karty „bTab"
//
// Program nadal potrzebuje zgody na Automatyzacje i wlaczonego w przegladarce
// „JavaScript w Apple Events" - tego zadne adresowanie nie omija.

enum ZdarzeniaPrzegladarki {
    private static func kod(_ napis: String) -> OSType {
        var wynik: OSType = 0
        for znak in napis.utf8.prefix(4) { wynik = (wynik << 8) | OSType(znak) }
        return wynik
    }

    /// Specyfikator „element numer N w tym kontenerze".
    private static func pozycja(klasa: OSType, numer: Int,
                                w kontenerze: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let rekord = NSAppleEventDescriptor.record()
        rekord.setDescriptor(NSAppleEventDescriptor(typeCode: klasa), forKeyword: AEKeyword(keyAEDesiredClass))
        rekord.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)),
                             forKeyword: AEKeyword(keyAEKeyForm))
        rekord.setDescriptor(NSAppleEventDescriptor(int32: Int32(numer)), forKeyword: AEKeyword(keyAEKeyData))
        rekord.setDescriptor(kontenerze, forKeyword: AEKeyword(keyAEContainer))
        return rekord.coerce(toDescriptorType: typeObjectSpecifier) ?? rekord
    }

    /// Wykonuje JavaScript w karcie o podanym numerze w oknie o podanym numerze.
    ///
    /// Zwraca odpowiedz strony albo `nil` z powodem - powod jest wazniejszy niz
    /// sam brak wyniku, bo to on trafia do okna zamiast martwego suwaka.
    static func wykonajJavaScript(_ kodJS: String, pid: pid_t, rodzaj: BrowserKind,
                                  numerOkna: Int, numerKarty: Int) -> (wynik: String?, blad: Int) {
        let cel = NSAppleEventDescriptor(processIdentifier: pid)
        let pusty = NSAppleEventDescriptor.null()
        let okno = pozycja(klasa: kod("cwin"), numer: numerOkna, w: pusty)

        let zdarzenie: NSAppleEventDescriptor
        switch rodzaj {
        case .chromium:
            let karta = pozycja(klasa: kod("CrTb"), numer: numerKarty, w: okno)
            zdarzenie = NSAppleEventDescriptor.appleEvent(
                withEventClass: kod("CrSu"), eventID: kod("ExJa"), targetDescriptor: cel,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            zdarzenie.setDescriptor(karta, forKeyword: AEKeyword(keyDirectObject))
            zdarzenie.setDescriptor(NSAppleEventDescriptor(string: kodJS), forKeyword: kod("JvSc"))
        case .safari:
            let karta = pozycja(klasa: kod("bTab"), numer: numerKarty, w: okno)
            zdarzenie = NSAppleEventDescriptor.appleEvent(
                withEventClass: kod("sfri"), eventID: kod("dojs"), targetDescriptor: cel,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            zdarzenie.setDescriptor(NSAppleEventDescriptor(string: kodJS), forKeyword: AEKeyword(keyDirectObject))
            zdarzenie.setDescriptor(karta, forKeyword: kod("dcnm"))
        }

        do {
            let odpowiedz = try zdarzenie.sendEvent(options: [.waitForReply], timeout: 1.2)
            if let blad = odpowiedz.forKeyword(AEKeyword(keyErrorNumber))?.int32Value, blad != 0 {
                return (nil, Int(blad))
            }
            return (odpowiedz.stringValue, 0)
        } catch let blad as NSError {
            return (nil, blad.code)
        }
    }
}
