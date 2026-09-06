import AppKit
import CoreAudio

// MARK: - Glosnosc POJEDYNCZEGO programu (i calego systemu)
//
// Zadanie brzmialo: „jak w Windows i Android" - suwak przy kazdej aplikacji
// osobno, a nie glosnosc calego komputera. macOS nie ma na to API i nigdy nie
// mial; jest za to droga okrezna, ktora daje dokladnie ten sam wynik: przejac
// dzwiek programu, wyciszyc oryginal, przemnozyc probki i wypuscic je z
// powrotem. Cala ta robota siedzi w `TorDzwieku`; tutaj jest tylko ksiegowosc:
// ktory program ma jaki poziom i kiedy tor jest w ogole potrzebny.
//
// Niezmiennik: tor istnieje TYLKO wtedy, gdy cos zmienia. Przy 100 procentach
// dzwiek idzie systemem tak jak zawsze - nie stoimy w drodze niczemu, czego nie
// prosil nas nikt, zeby zmieniac.
//
// Dwie rzeczy, ktore ten plik naprawil po zgloszeniu „wyciszylem, a nadal gra":
//   1. wyciszany byl pid programu, a dzwiek wysyla proces POMOCNICZY - teraz
//      idzie do przechwycenia cala rodzina procesow (patrz `Dzwiek.rodzina`),
//   2. samo przechwycenie z wyciszeniem nie odtwarzalo niczego z powrotem, wiec
//      przy poziomie innym niz zero nie mialo jak zagrac ciszej.

enum GlosnoscAplikacji {
    private static var tory: [pid_t: TorDzwieku] = [:]
    /// Poziom sprzed wyciszenia - zeby glosnik przywracal to, co bylo, a nie 100%.
    private static var poziomPrzedWyciszeniem: [pid_t: Float] = [:]

    static var wyciszone: Set<pid_t> {
        Set(tory.filter { $0.value.wzmocnienie <= 0.0001 }.keys)
    }

    /// Programy, ktorym cokolwiek zmieniamy - takze te tylko przyciszone.
    static var zmienione: Set<pid_t> { Set(tory.keys) }

    /// Czy ten system w ogole umie regulowac glosnosc jednego programu.
    ///
    /// Przechwycenie procesu istnieje od macOS 14.2. Na starszych zostaje sam
    /// znak „ten program gra" - lepiej nie dac funkcji, niz dac taka, ktora
    /// wyglada na dzialajaca i nic nie robi.
    static var dostepne: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func czyWyciszony(pid: pid_t) -> Bool {
        guard let tor = tory[pid] else { return false }
        return tor.wzmocnienie <= 0.0001
    }

    /// Poziom programu: 1.0 = bez zmiany, 0.0 = cisza, 2.0 = dwa razy glosniej.
    static func poziom(pid: pid_t) -> Float {
        tory[pid]?.wzmocnienie ?? 1.0
    }

    /// Ustawia poziom i zwraca to, co udalo sie osiagnac.
    ///
    /// Zwrocona wartosc bywa inna niz zadana dokladnie w jednym przypadku: gdy
    /// nie da sie zbudowac toru (program nie ma jeszcze procesu dzwieku albo
    /// system jest starszy niz 14.2). Wtedy odpowiedzia jest 1.0 - i interfejs
    /// pokaze prawde zamiast suwaka, ktory tylko udaje.
    @discardableResult
    static func ustawPoziom(pid: pid_t, _ nowy: Float) -> Float {
        // Wlasnego dzwieku nie regulujemy - patrz `TorDzwieku.init`.
        guard !Dzwiek.nasze().contains(pid) else { return 1.0 }
        let docelowy = max(0, min(2.0, nowy))

        // Powrot do 100 procent = rozebranie toru. Nie zostawiamy przechwycenia,
        // ktore nic nie zmienia, a kosztuje program przejscie przez nasz kod.
        if abs(docelowy - 1.0) < 0.0001 {
            tory.removeValue(forKey: pid)?.rozbierz()
            poziomPrzedWyciszeniem.removeValue(forKey: pid)
            return 1.0
        }

        guard dostepne else { return 1.0 }

        if let tor = tory[pid] {
            tor.wzmocnienie = docelowy
            return docelowy
        }
        guard let tor = TorDzwieku(pid: pid, wzmocnienie: docelowy) else { return 1.0 }
        tory[pid] = tor
        return docelowy
    }

    /// Wycisza program albo przywraca mu poprzedni poziom. Zwraca stan PO zmianie.
    @discardableResult
    static func przelaczWyciszenie(pid: pid_t) -> Bool {
        if czyWyciszony(pid: pid) {
            let poprzedni = poziomPrzedWyciszeniem.removeValue(forKey: pid) ?? 1.0
            ustawPoziom(pid: pid, poprzedni)
            return false
        }
        poziomPrzedWyciszeniem[pid] = poziom(pid: pid)
        return ustawPoziom(pid: pid, 0) <= 0.0001
    }

    /// Najglosniejsza probka, jaka przeszla przez tor - zywy dowod, ze dzwiek
    /// naprawde plynie przez nas, a nie obok nas. Interfejs rysuje z tego wskaznik.
    static func szczyt(pid: pid_t) -> Float { tory[pid]?.szczyt ?? 0 }

    /// Kroki budowy toru z kodami bledow - dla sondy i dla nastepnego, ktory
    /// bedzie sie zastanawial, dlaczego cos nie gra.
    static func diagnoza(pid: pid_t) -> [String] { tory[pid]?.diagnoza ?? ["brak toru"] }

    /// Ile przeszlo przez tor: wywolania procedury IO, bufory i bajty wejscia.
    static func ruch(pid: pid_t) -> (wywolania: Int, bufory: Int, bajty: Int) {
        guard let tor = tory[pid] else { return (0, 0, 0) }
        return (tor.wywolania, tor.buforowWejscia, tor.bajtyWejscia)
    }

    /// Zdejmuje WSZYSTKO. Wolane przy zamykaniu programu, zeby nie zostawic
    /// czyjegos dzwieku wyciszonego po naszym znikniciu.
    static func przywrocWszystkie() {
        for (_, tor) in tory { tor.rozbierz() }
        tory.removeAll()
        poziomPrzedWyciszeniem.removeAll()
    }

    /// Program, ktory zniknal, nie potrzebuje juz toru - a tor zajmuje miejsce
    /// w serwerze dzwieku.
    static func posprzatajPoZamknietych() {
        for (pid, tor) in tory where NSRunningApplication(processIdentifier: pid) == nil {
            tor.rozbierz()
            tory.removeValue(forKey: pid)
            poziomPrzedWyciszeniem.removeValue(forKey: pid)
        }
    }

    // MARK: - Glosnosc calego systemu
    //
    // Osobna sprawa niz poziom jednego programu, ale mieszka tu, bo czlowiek
    // widzi to jako jedno: „chce to sciszyc".

    private static func urzadzenieWyjscia() -> AudioObjectID? {
        TorDzwieku.urzadzenieWyjscia()
    }

    /// Adres glosnosci urzadzenia.
    ///
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` nie jest widoczne
    /// ze Swifta, wiec pytamy o zwykla glosnosc kanalu glownego - to ta sama
    /// wartosc, ktora pokazuje pasek menu.
    private static func adresGlosnosci() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Glosnosc systemu w skali 0…1. `nil`, gdy urzadzenie jej nie oddaje
    /// (tak bywa z wyjsciem przez HDMI albo przez zewnetrzny wzmacniacz).
    static var glosnoscSystemu: Float? {
        get {
            guard let urzadzenie = urzadzenieWyjscia() else { return nil }
            var adres = adresGlosnosci()
            var wartosc: Float32 = 0
            var rozmiar = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(urzadzenie, &adres),
                  AudioObjectGetPropertyData(urzadzenie, &adres, 0, nil, &rozmiar, &wartosc) == noErr
            else { return nil }
            return wartosc
        }
        set {
            guard let nowa = newValue, let urzadzenie = urzadzenieWyjscia() else { return }
            var adres = adresGlosnosci()
            var wartosc = Float32(min(max(nowa, 0), 1))
            guard AudioObjectHasProperty(urzadzenie, &adres) else { return }
            AudioObjectSetPropertyData(urzadzenie, &adres, 0, nil,
                                       UInt32(MemoryLayout<Float32>.size), &wartosc)
        }
    }
}
