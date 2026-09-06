import AppKit
import CoreAudio

// MARK: - Wyciszanie POJEDYNCZEJ aplikacji i glosnosc systemu
//
// Do macOS 14.1 wlacznie nie bylo na to publicznej drogi - narzedzia typu
// SoundSource instaluja wlasny sterownik dzwieku do katalogu systemowego.
// Od 14.2 Apple dodalo „przechwycenie procesu" (`AudioHardwareCreateProcessTap`
// z `CATapDescription`), a opis tapu ma pole `muteBehavior`. Utworzenie
// PRYWATNEGO tapu z wyciszeniem wycisza wskazany proces i nic wiecej.
//
// Zmierzone 6 wrzesnia 2026 na macOS 26.6, zanim powstal ten plik:
//     pid 65391 -> obiekt audio 125 (blad 0)
//     AudioHardwareCreateProcessTap: 0 OK, tapID = 127
// Pierwsze podejscie zwrocilo `!obj`, bo opis tapu oczekuje IDENTYFIKATOROW
// OBIEKTOW AUDIO, a nie pidow - stad tlumaczenie przez `id2p`.
//
// Niezmiennik: kazde wyciszenie da sie cofnac. Tapy trzymamy w slowniku i
// niszczymy przy przywroceniu oraz przy zamykaniu programu - inaczej czyjs
// dzwiek zostalby wyciszony na zawsze, a czlowiek nie mialby jak tego odkrecic.

enum GlosnoscAplikacji {
    private static var tapy: [pid_t: AudioObjectID] = [:]

    static var wyciszone: Set<pid_t> { Set(tapy.keys) }

    /// Czy ten system w ogole umie wyciszyc pojedynczy program.
    ///
    /// Przechwycenie procesu istnieje od macOS 14.2. Na starszych glosnik na
    /// karcie zostaje ZNAKIEM (widac, co gra), ale nie udaje przycisku - lepiej
    /// nie dac funkcji, niz dac taka, ktora nic nie robi.
    static var dostepne: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    static func czyWyciszony(pid: pid_t) -> Bool { tapy[pid] != nil }

    /// Wycisza program albo przywraca mu dzwiek. Zwraca stan PO zmianie.
    @discardableResult
    static func przelaczWyciszenie(pid: pid_t) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        if let tap = tapy.removeValue(forKey: pid) {
            AudioHardwareDestroyProcessTap(tap)
            return false
        }
        guard let obiekt = obiektProcesu(pid: pid) else { return false }
        let opis = CATapDescription(stereoMixdownOfProcesses: [NSNumber(value: obiekt)])
        opis.name = "Klyo Switcher — wyciszenie"
        opis.uuid = UUID()
        opis.isPrivate = true
        opis.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(opis, &tap) == noErr, tap != kAudioObjectUnknown else {
            return false
        }
        tapy[pid] = tap
        return true
    }

    /// Zdejmuje WSZYSTKIE wyciszenia. Wolane przy zamykaniu programu, zeby
    /// nie zostawic czyjegos dzwieku wyciszonego po naszym zniknieciu.
    static func przywrocWszystkie() {
        guard #available(macOS 14.2, *) else { tapy.removeAll(); return }
        for (_, tap) in tapy { AudioHardwareDestroyProcessTap(tap) }
        tapy.removeAll()
    }

    /// Program, ktory zniknal, nie musi juz byc wyciszany - a jego tap zajmuje
    /// miejsce w serwerze dzwieku.
    static func posprzatajPoZamknietych() {
        guard #available(macOS 14.2, *) else { return }
        for (pid, tap) in tapy where NSRunningApplication(processIdentifier: pid) == nil {
            AudioHardwareDestroyProcessTap(tap)
            tapy.removeValue(forKey: pid)
        }
    }

    private static func obiektProcesu(pid: pid_t) -> AudioObjectID? {
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var wejscie = pid
        var wynik = AudioObjectID(kAudioObjectUnknown)
        var rozmiar = UInt32(MemoryLayout<AudioObjectID>.size)
        let blad = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &adres,
                                              UInt32(MemoryLayout<pid_t>.size), &wejscie,
                                              &rozmiar, &wynik)
        guard blad == noErr, wynik != kAudioObjectUnknown else { return nil }
        return wynik
    }

    // MARK: - Glosnosc calego systemu
    //
    // Osobna sprawa niz wyciszanie pojedynczego programu, ale mieszka tu, bo
    // czlowiek widzi to jako jedno: „chce to sciszyc".

    private static func urzadzenieWyjscia() -> AudioObjectID? {
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var urzadzenie = AudioObjectID(kAudioObjectUnknown)
        var rozmiar = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &adres,
                                         0, nil, &rozmiar, &urzadzenie) == noErr,
              urzadzenie != kAudioObjectUnknown else { return nil }
        return urzadzenie
    }

    private static func adresGlosnosci() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
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
