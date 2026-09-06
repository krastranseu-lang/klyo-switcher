import AppKit

// MARK: - Glosnosc POJEDYNCZEJ karty przegladarki
//
// Zadanie wlasciciela: „chce jedna karte zrobic glosno, kolejna sciszyc - np. gdy
// na jednej mam powiadomienia".
//
// Dlaczego to nie moze isc ta sama droga, co glosnosc programu: przechwycenie
// dziala na PROCES, a wszystkie karty Chrome miksuja sie w jednym procesie
// dzwieku (zmierzone: 33 karty, jeden proces). Z punktu widzenia systemu karta
// nie istnieje.
//
// Karta istnieje za to w samej STRONIE - i tam da sie ja sciszyc: kazdy film i
// kazde audio na stronie ma wlasna glosnosc. Przegladarki daja do tego droge:
//     Safari: `do JavaScript … in tab N of window M`
//     Chrome: `execute tab N of window M javascript …`
//
// Obie wymagaja zgody na Automatyzacje ORAZ jednorazowego przelacznika w samej
// przegladarce. Zmierzone 6 wrzesnia 2026:
//   • Safari odpowiada wprost: „You must enable 'Allow JavaScript from Apple
//     Events' in the Developer section of Safari Settings",
//   • Chrome odpowiada na AppleScript (podaje wersje), ale przy KILKU
//     uruchomionych instancjach (rozne konta) kieruje pytanie do tej bez okien
//     i zwraca „Nie mozna uzyskac window 1".
//
// Dlatego kazda odpowiedz tego modulu mowi, CO sie stalo - a interfejs pokazuje
// to czlowiekowi zamiast suwaka, ktory tylko udaje.

enum WynikGlosnosciKarty {
    /// Udalo sie - i tyle elementow dzwiekowych na stronie posluchalo.
    case ustawione(elementow: Int)
    /// Strona nie ma zadnego filmu ani audio (np. dzwiek gra przez Web Audio).
    case stronaNieOddajeGlosnosci
    /// Brak zgody na Automatyzacje tej przegladarki.
    case brakZgody
    /// Przegladarka ma wylaczone wykonywanie JavaScriptu z Apple Events.
    case javascriptWylaczony
    /// Przegladarka nie pokazuje swoich okien przez AppleScript.
    case brakOkien
    case nieObslugiwana

    var mozliwe: Bool {
        if case .ustawione = self { return true }
        return false
    }

    /// Jedno zdanie dla czlowieka - to ono stoi w oknie zamiast suwaka.
    var powod: String? {
        switch self {
        case .ustawione: return nil
        case .stronaNieOddajeGlosnosci:
            return "Ta strona nie oddaje głośności — jej dźwięk nie jest zwykłym filmem ani audio."
        case .brakZgody:
            return "Brakuje zgody na sterowanie tą przeglądarką (Automatyzacja)."
        case .javascriptWylaczony:
            return "Włącz w przeglądarce „Zezwalaj na JavaScript w Apple Events” (Safari: Ustawienia → Programowanie; Chrome: Widok → Programista)."
        case .brakOkien:
            return "Przeglądarka nie pokazuje swoich okien — zdarza się, gdy działa kilka jej instancji naraz."
        case .nieObslugiwana:
            return "Ta przeglądarka nie pozwala sterować głośnością karty z zewnątrz."
        }
    }
}

enum GlosnoscKarty {
    /// Poziomy kart, ktore SAMI ustawilismy - klucz to program i tytul karty.
    ///
    /// Przegladarka nam tego nie odda: Chrome oznacza karte tylko wtedy, gdy GRA,
    /// a karty wyciszonej nie oznacza wcale. Bez wlasnej pamieci karta znikala z
    /// listy zaraz po wyciszeniu i nie bylo czego kliknac, zeby wrocic - to jest
    /// dokladnie usterka „wylaczylem dzwiek i juz nie wraca".
    private static var poziomy: [String: Float] = [:]

    /// Karta jest rozpoznawana po programie i tytule - jej element Dostepnosci
    /// zmienia sie przy kazdym przerysowaniu paska i nie nadaje sie na klucz.
    static func klucz(pid: pid_t, tytul: String) -> String { "\(pid):\(tytul)" }

    static func klucz(_ karta: KartaGrajaca) -> String { klucz(pid: karta.pid, tytul: karta.tytul) }

    static func poziom(pid: pid_t, tytul: String) -> Float { poziomy[klucz(pid: pid, tytul: tytul)] ?? 1.0 }

    static func poziom(_ karta: KartaGrajaca) -> Float { poziom(pid: karta.pid, tytul: karta.tytul) }

    static func zapamietany(pid: pid_t, tytul: String) -> Bool {
        poziomy[klucz(pid: pid, tytul: tytul)] != nil
    }

    static func zapamietany(_ karta: KartaGrajaca) -> Bool { zapamietany(pid: karta.pid, tytul: karta.tytul) }

    /// Karty, ktorym cos ustawilismy - zeby zostaly na liscie, nawet gdy
    /// przegladarka przestala je oznaczac.
    static var zmienioneKarty: [String: Float] { poziomy }

    static func zapomnij(_ karta: KartaGrajaca) { poziomy.removeValue(forKey: klucz(karta)) }

    // MARK: Ustawianie

    @discardableResult
    static func ustaw(_ karta: KartaGrajaca, poziom: Float) -> WynikGlosnosciKarty {
        let docelowy = max(0, min(1, poziom))
        guard let program = NSRunningApplication(processIdentifier: karta.pid),
              let identyfikator = program.bundleIdentifier,
              let rodzaj = BrowserSupport.definition(for: identyfikator)?.kind else {
            return .nieObslugiwana
        }
        let skrypt = zbudujSkrypt(rodzaj: rodzaj, program: program.localizedName ?? "",
                                  tytul: karta.tytul, poziom: docelowy)
        let wynik = wykonaj(skrypt)
        if case .ustawione = wynik {
            poziomy[klucz(karta)] = docelowy
        }
        return wynik
    }

    private static func zbudujSkrypt(rodzaj: BrowserKind, program: String,
                                     tytul: String, poziom: Float) -> String {
        // Skrypt ustawia glosnosc KAZDEGO filmu i audio na stronie i zwraca ich
        // liczbe. Zero znaczy, ze strona gra inaczej (np. Web Audio) - i wtedy
        // uczciwa odpowiedzia jest „nie da sie", a nie udawanie, ze sie udalo.
        let js = """
        (function(){var m=document.querySelectorAll('video,audio');var n=0;\
        for(var i=0;i<m.length;i++){m[i].volume=\(poziom);m[i].muted=\(poziom == 0 ? "true" : "false");n++;}return n;})()
        """
        let jsCytowany = js.replacingOccurrences(of: "\"", with: "\\\"")
        let tytulCytowany = tytul.replacingOccurrences(of: "\"", with: "\\\"")
        switch rodzaj {
        case .safari:
            return """
            tell application "\(program)"
              repeat with w in windows
                repeat with t in tabs of w
                  if name of t contains "\(tytulCytowany)" then
                    return (do JavaScript "\(jsCytowany)" in t)
                  end if
                end repeat
              end repeat
            end tell
            return -1
            """
        case .chromium:
            return """
            tell application "\(program)"
              repeat with w in windows
                repeat with t in tabs of w
                  if title of t contains "\(tytulCytowany)" then
                    return (execute t javascript "\(jsCytowany)")
                  end if
                end repeat
              end repeat
            end tell
            return -1
            """
        }
    }

    private static func wykonaj(_ zrodlo: String) -> WynikGlosnosciKarty {
        var blad: NSDictionary?
        guard let skrypt = NSAppleScript(source: zrodlo) else { return .nieObslugiwana }
        let odpowiedz = skrypt.executeAndReturnError(&blad)
        if let blad {
            let numer = (blad[NSAppleScript.errorNumber] as? Int) ?? 0
            let opis = ((blad[NSAppleScript.errorMessage] as? String) ?? "").lowercased()
            if numer == -1743 || numer == -1744 { return .brakZgody }
            if opis.contains("javascript") { return .javascriptWylaczony }
            if numer == -1719 { return .brakOkien }
            return .nieObslugiwana
        }
        let ile = Int(odpowiedz.int32Value)
        if ile < 0 { return .brakOkien }
        if ile == 0 { return .stronaNieOddajeGlosnosci }
        return .ustawione(elementow: ile)
    }
}
