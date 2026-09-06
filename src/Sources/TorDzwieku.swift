import AppKit
import CoreAudio

// MARK: - Tor dzwieku jednego programu
//
// macOS nie umie sciszyc aplikacji na zyczenie - nie ma na to API i nigdy nie
// bylo. Umie natomiast dwie rzeczy, ktore razem daja to samo (od 14.2, bez
// zadnego sterownika w systemie):
//
//     przejmij dzwiek programu  →  wycisz jego oryginal  →  pomnoz probki
//     przez suwak  →  wypusc na glosnik
//
// Tak dzialaja platne narzedzia tego rodzaju i tak dziala ten plik. Jeden tor
// obsluguje JEDEN program: przechwycenie (`tap`) + prywatne urzadzenie zbiorcze
// (`agregat`), ktore laczy przechwycenie z prawdziwym wyjsciem, i procedura IO,
// ktora przepisuje probki z jednego do drugiego, mnozac je po drodze.
//
// Zmierzone 6 wrzesnia 2026, zanim ten plik powstal - i to jest powod, dla
// ktorego pierwsza wersja wyciszania nie dzialala: dzwiek Chrome wysyla
// `com.google.Chrome.helper` (pid 2950), a NIE `com.google.Chrome` (pid 671),
// w ktory czlowiek klika. Tor bierze wiec cala rodzine procesow programu.

final class TorDzwieku {
    /// Klucze slownika urzadzenia zbiorczego - z `AudioHardware.h`.
    ///
    /// Trzymane w jednym miejscu, bo to jedyne miejsce, w ktorym program zna te
    /// napisy; rozsiane po kodzie rozjechalyby sie przy pierwszej literowce.
    private enum Klucz {
        static let uid = "uid"
        static let nazwa = "name"
        static let podurzadzenia = "subdevices"
        static let glowne = "master"
        static let prywatne = "private"
        static let ulozone = "stacked"
        static let tapy = "taps"
        static let tapAutoStart = "tapautostart"
        static let dryf = "drift"
    }

    private(set) var pid: pid_t
    /// 1.0 = bez zmiany. Ponizej - ciszej, powyzej - glosniej.
    var wzmocnienie: Float {
        didSet { wzmocnienieAtomowe = max(0, min(2.0, wzmocnienie)) }
    }
    /// Czytane w procedurze IO, ktora chodzi na watku dzwieku - stad osobne pole
    /// z gotowa, ograniczona wartoscia zamiast liczenia w czasie rzeczywistym.
    private var wzmocnienieAtomowe: Float = 1.0

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var agregat = AudioObjectID(kAudioObjectUnknown)
    private var procedura: AudioDeviceIOProcID?
    /// Najglosniejsza probka, jaka przeszla przez tor - dowod, ze cos tedy plynie.
    private(set) var szczyt: Float = 0

    init?(pid: pid_t, wzmocnienie: Float) {
        guard #available(macOS 14.2, *) else { return nil }
        self.pid = pid
        self.wzmocnienie = wzmocnienie
        self.wzmocnienieAtomowe = max(0, min(2.0, wzmocnienie))
        guard zbuduj() else {
            rozbierz()
            return nil
        }
    }

    deinit { rozbierz() }

    // MARK: Budowa toru

    @available(macOS 14.2, *)
    private func zbuduj() -> Bool {
        let obiekty = Dzwiek.obiektyAudio(rodzinyProgramu: pid)
        guard !obiekty.isEmpty else { return false }

        // 1. Przechwycenie z wyciszeniem oryginalu. Bez `.muted` slychac by bylo
        //    dwa razy: raz od programu, raz z naszego toru.
        let opis = CATapDescription(stereoMixdownOfProcesses: obiekty)
        opis.name = "Klyo Switcher — \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "program")"
        opis.uuid = UUID()
        opis.isPrivate = true
        opis.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        guard AudioHardwareCreateProcessTap(opis, &tap) == noErr, tap != kAudioObjectUnknown else {
            return false
        }
        guard let tapUID = napis(obiekt: tap, selektor: kAudioTapPropertyUID),
              let wyjscie = TorDzwieku.urzadzenieWyjscia(),
              let wyjscieUID = napis(obiekt: wyjscie, selektor: kAudioDevicePropertyDeviceUID) else {
            return false
        }

        // 2. Prywatne urzadzenie zbiorcze: z jednej strony nasze przechwycenie,
        //    z drugiej prawdziwe wyjscie. Prywatne znaczy, ze nie pojawi sie na
        //    liscie urzadzen w Ustawieniach - nikt go nie wybierze przez pomylke.
        let opisAgregatu: [String: Any] = [
            Klucz.nazwa: "Klyo Switcher — mikser",
            Klucz.uid: "pl.klyo.switcher.mikser.\(pid).\(UUID().uuidString)",
            Klucz.glowne: wyjscieUID,
            Klucz.prywatne: true,
            Klucz.ulozone: false,
            Klucz.tapAutoStart: true,
            Klucz.podurzadzenia: [[Klucz.uid: wyjscieUID]],
            Klucz.tapy: [[Klucz.uid: tapUID, Klucz.dryf: true]]
        ]
        guard AudioHardwareCreateAggregateDevice(opisAgregatu as CFDictionary, &agregat) == noErr,
              agregat != kAudioObjectUnknown else {
            return false
        }

        // 3. Procedura IO: przepisuje probki z przechwycenia na wyjscie, mnozac
        //    je przez suwak. To jest cale „sciszanie jednego programu".
        let wskaznik = Unmanaged.passUnretained(self).toOpaque()
        let blad = AudioDeviceCreateIOProcID(agregat, TorDzwieku.przepisz, wskaznik, &procedura)
        guard blad == noErr, let procedura else { return false }
        return AudioDeviceStart(agregat, procedura) == noErr
    }

    func rozbierz() {
        guard #available(macOS 14.2, *) else { return }
        if agregat != kAudioObjectUnknown, let procedura {
            AudioDeviceStop(agregat, procedura)
            AudioDeviceDestroyIOProcID(agregat, procedura)
        }
        procedura = nil
        if agregat != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(agregat)
            agregat = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Serce toru

    /// Wolane przez system kilkaset razy na sekunde na watku dzwieku.
    ///
    /// Tu nie wolno nic alokowac ani czekac - stad brak slownikow, logow i
    /// jakiegokolwiek zamka. Jedyne, co robimy, to mnozenie i kopiowanie.
    private static let przepisz: AudioDeviceIOProc = {
        (_, _, wejscie, _, wyjscie, _, kontekst) -> OSStatus in
        guard let kontekst else { return noErr }
        let tor = Unmanaged<TorDzwieku>.fromOpaque(kontekst).takeUnretainedValue()
        let mnoznik = tor.wzmocnienieAtomowe

        let buforyWejscia = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: wejscie))
        let buforyWyjscia = UnsafeMutableAudioBufferListPointer(wyjscie)
        var szczyt: Float = 0

        for numer in 0..<buforyWyjscia.count {
            let cel = buforyWyjscia[numer]
            guard let daneCelu = cel.mData else { continue }
            // Brak odpowiadajacego bufora wejscia = cisza. Zostawienie smieci z
            // poprzedniej ramki dawaloby trzask.
            guard numer < buforyWejscia.count, let daneZrodla = buforyWejscia[numer].mData else {
                memset(daneCelu, 0, Int(cel.mDataByteSize))
                continue
            }
            let bajty = min(Int(cel.mDataByteSize), Int(buforyWejscia[numer].mDataByteSize))
            let ile = bajty / MemoryLayout<Float32>.size
            let zrodlo = daneZrodla.assumingMemoryBound(to: Float32.self)
            let docelowe = daneCelu.assumingMemoryBound(to: Float32.self)
            for i in 0..<ile {
                // Ograniczenie do zakresu: przy wzmocnieniu powyzej 100 procent
                // probka moglaby wyjsc poza skale i zamiast glosniej byloby brzydko.
                let wartosc = max(-1.0, min(1.0, zrodlo[i] * mnoznik))
                docelowe[i] = wartosc
                let modul = abs(wartosc)
                if modul > szczyt { szczyt = modul }
            }
            if bajty < Int(cel.mDataByteSize) {
                memset(daneCelu.advanced(by: bajty), 0, Int(cel.mDataByteSize) - bajty)
            }
        }
        tor.szczyt = szczyt
        return noErr
    }

    // MARK: Drobiazgi

    private func napis(obiekt: AudioObjectID, selektor: AudioObjectPropertySelector) -> String? {
        var adres = AudioObjectPropertyAddress(mSelector: selektor,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var wartosc: CFString = "" as CFString
        var rozmiar = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(obiekt, &adres, 0, nil, &rozmiar, &wartosc) == noErr else {
            return nil
        }
        return wartosc as String
    }

    static func urzadzenieWyjscia() -> AudioObjectID? {
        var adres = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var urzadzenie = AudioObjectID(kAudioObjectUnknown)
        var rozmiar = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &adres,
                                         0, nil, &rozmiar, &urzadzenie) == noErr,
              urzadzenie != kAudioObjectUnknown else { return nil }
        return urzadzenie
    }
}
