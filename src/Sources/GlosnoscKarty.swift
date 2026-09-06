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
    /// Gdzie ta karta naprawde siedzi wedlug slownika przegladarki - raz znaleziona
    /// para numerow zostaje, zeby suwak nie szukal jej od nowa przy kazdym ruchu.
    private static var mapowanie: [String: (okno: Int, karta: Int)] = [:]

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

    /// Zapamietuje wyciszenie zrobione INNA droga niz suwak - przyciskiem na
    /// karcie (Safari) albo pozycja w menu (Chrome).
    ///
    /// Bez tego usterka „wylaczylem dzwiek i juz nie wraca" zostawalaby w polowie
    /// naprawiona: suwak pamietalby swoje, a glosnik nie - i karta wyciszona
    /// glosnikiem dalej znikalaby z listy.
    static func zapamietajWyciszenie(_ karta: KartaGrajaca) { poziomy[klucz(karta)] = 0 }

    // MARK: Ustawianie

    @discardableResult
    static func ustaw(_ karta: KartaGrajaca, poziom: Float) -> WynikGlosnosciKarty {
        let docelowy = max(0, min(1, poziom))
        // Numery okna i karty biora sie z Dostepnosci, a polecenie idzie
        // slownikiem przegladarki - to dwie rozne numeracje i nie musza sie
        // zgadzac. Dlatego skrypt SAM sprawdza, czy trafil we wlasciwa strone,
        // i dopiero wtedy cokolwiek zmienia; inaczej suwak przy jednej karcie
        // sciszalby inna.
        if let zapamietane = mapowanie[klucz(karta)],
           przypisz(karta, poziom: docelowy, okno: zapamietane.okno, karta: zapamietane.karta).mozliwe {
            poziomy[klucz(karta)] = docelowy
            return .ustawione(elementow: 1)
        }

        var ostatni: WynikGlosnosciKarty = .nieObslugiwana
        // Najpierw miejsce wskazane przez Dostepnosc, potem szukanie po kolei.
        var proby: [(okno: Int, karta: Int)] = [(karta.numerOkna, karta.numerKarty)]
        for okno in 1...2 {
            for numer in 1...25 where !(okno == karta.numerOkna && numer == karta.numerKarty) {
                proby.append((okno, numer))
            }
        }
        var pustychPodRzad = 0
        for proba in proby {
            let wynik = przypisz(karta, poziom: docelowy, okno: proba.okno, karta: proba.karta)
            switch wynik {
            case .ustawione:
                mapowanie[klucz(karta)] = proba
                poziomy[klucz(karta)] = docelowy
                return wynik
            case .brakZgody, .javascriptWylaczony:
                // To sa odmowy calej przegladarki - szukanie dalej nic nie da.
                return wynik
            case .brakOkien:
                // Karty o takim numerze nie ma. Kilka pustych pod rzad znaczy,
                // ze doszlismy do konca listy - dalsze pytanie to strata czasu.
                pustychPodRzad += 1
                ostatni = wynik
                if pustychPodRzad > 6 { return wynik }
            default:
                pustychPodRzad = 0
                ostatni = wynik
            }
        }
        return ostatni
    }

    /// Jedna proba: wykonaj skrypt w karcie o tych numerach.
    private static func przypisz(_ karta: KartaGrajaca, poziom: Float,
                                 okno: Int, karta numerKarty: Int) -> WynikGlosnosciKarty {
        let rozpoznanie = String(karta.tytul.prefix(18))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){if(document.title.indexOf('\(rozpoznanie)')<0)return 'inna';        var m=document.querySelectorAll('video,audio');        for(var i=0;i<m.length;i++){m[i].volume=\(poziom);m[i].muted=\(poziom == 0 ? "true" : "false");}        return 'ok'+m.length;})()
        """
        let odpowiedz = ZdarzeniaPrzegladarki.wykonajJavaScript(
            js, pid: karta.pid, rodzaj: karta.rodzaj, numerOkna: okno, numerKarty: numerKarty)

        if odpowiedz.blad != 0 {
            switch odpowiedz.blad {
            case -1743, -1744: return .brakZgody
            case 8, -2700: return .javascriptWylaczony
            case -1728, -1719: return .brakOkien
            default: return .nieObslugiwana
            }
        }
        guard let tekst = odpowiedz.wynik else { return .nieObslugiwana }
        if tekst == "inna" { return .brakOkien }
        guard tekst.hasPrefix("ok") else { return .nieObslugiwana }
        let ile = Int(tekst.dropFirst(2)) ?? 0
        return ile > 0 ? .ustawione(elementow: ile) : .stronaNieOddajeGlosnosci
    }
}
