import AppKit
import CoreAudio

// MARK: - Ktory program teraz gra
//
// Pytanie wlasciciela: „skad pochodzi dzwiek". macOS od 14.2 odpowiada na to
// publicznym API: CoreAudio wystawia OBIEKTY PROCESOW (`kAudioHardwareProperty\
// ProcessObjectList`), a kazdy z nich mowi swoj pid i to, czy wlasnie gra.
// Zmierzone 6 wrzesnia 2026 na macOS 26.6: przy odtwarzaniu dzwieku lista
// wskazala `afplay` oraz proces pomocniczy Chrome - obie pozycje z „gra: TAK".
//
// Pulapka, ktora ten pomiar odslonil: dzwiek zglasza PROCES POMOCNICZY
// (com.google.Chrome.helper, pid 2950), a nie program, ktory czlowiek widzi
// (Google Chrome, pid 671). Bez wejscia po procesach nadrzednych glosnik
// swiecilby przy niczym.

enum Dzwiek {
    private static var pamiec: Set<pid_t> = []
    private static var czas: CFAbsoluteTime = 0
    /// Lista jest odswiezana najwyzej raz na sekunde - HUD otwiera sie setki razy
    /// dziennie, a pytanie CoreAudio to rozmowa z serwerem dzwieku.
    private static let waznosc: CFAbsoluteTime = 1.0

    static func odswiez() { czas = 0 }

    /// Czy ten program (albo ktorykolwiek z jego procesow pomocniczych) gra.
    static func gra(pid: pid_t) -> Bool {
        grajace().contains(pid)
    }

    /// Znaki, ktorymi PRZEGLADARKI same oznaczaja grajaca karte w jej tytule.
    ///
    /// Odkryte pomiarem, nie z dokumentacji: na zrzucie listy karta z filmem
    /// nazywala sie „Beautiful - YouTube 🔊". Chrome i Safari dopisuja ten znak
    /// same, wiec dostajemy za darmo to, czego CoreAudio nie umie powiedziec -
    /// KTORA z kilkunastu kart tego samego programu naprawde gra.
    private static let znakiGlosnika: [Character] = ["🔊", "🔈", "🔉", "▶"]

    /// Czy tytul sam mowi, ze to okno/karta gra.
    static func tytulMowiOGraniu(_ tytul: String) -> Bool {
        tytul.contains(where: { znakiGlosnika.contains($0) })
    }

    static func grajace() -> Set<pid_t> {
        let teraz = CFAbsoluteTimeGetCurrent()
        if teraz - czas < waznosc { return pamiec }
        czas = teraz
        // SIEBIE nie liczymy nigdy. Gdy mikser reguluje czyjas glosnosc, to on
        // odtwarza ten dzwiek - wiec z punktu widzenia systemu „gra Klyo".
        // Technicznie prawda, dla czlowieka bez sensu, a w skutkach zgubna:
        // program pokazywal sie na wlasnej liscie, a suwak przy tej pozycji
        // zakladal przechwycenie na WLASNYM wyjsciu i wyciszal wszystko naraz.
        pamiec = zbierz().subtracting([ProcessInfo.processInfo.processIdentifier])
        return pamiec
    }

    // MARK: Odczyt z CoreAudio

    private static func zbierz() -> Set<pid_t> {
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rozmiar: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &adres, 0, nil, &rozmiar) == noErr, rozmiar > 0 else {
            return []
        }
        var obiekty = [AudioObjectID](repeating: 0, count: Int(rozmiar) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &adres, 0, nil, &rozmiar, &obiekty) == noErr else {
            return []
        }

        var wynik = Set<pid_t>()
        for obiekt in obiekty {
            guard czyGra(obiekt) else { continue }
            guard let pid = pidProcesu(obiekt) else { continue }
            // Sam proces i cala jego linia rodzicow: dzwiek zglasza pomocnik,
            // a czlowiek szuka programu, ktory widzi na ekranie.
            wynik.insert(pid)
            // Program, do ktorego ten proces nalezy wedlug SYSTEMU - jedyna droga
            // dla uslug spod launchd (Safari, WebKit).
            let program = programProcesu(pid)
            if program != pid { wynik.insert(program) }
            for przodek in przodkowie(pid) { wynik.insert(przodek) }
        }
        return wynik
    }

    private static func czyGra(_ obiekt: AudioObjectID) -> Bool {
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var wartosc: UInt32 = 0
        var rozmiar = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obiekt, &adres, 0, nil, &rozmiar, &wartosc) == noErr else {
            return false
        }
        return wartosc != 0
    }

    private static func pidProcesu(_ obiekt: AudioObjectID) -> pid_t? {
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var wartosc: pid_t = 0
        var rozmiar = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obiekt, &adres, 0, nil, &rozmiar, &wartosc) == noErr,
              wartosc > 0 else { return nil }
        return wartosc
    }

    /// Procesy nadrzedne, najwyzej cztery poziomy w gore.
    ///
    /// Granica jest po to, zeby uszkodzone drzewo procesow (albo petla po
    /// ponownym uzyciu pidu) nie zakrecilo programu w nieskonczonosc.
    private static func przodkowie(_ pid: pid_t) -> [pid_t] {
        var wynik: [pid_t] = []
        var biezacy = pid
        for _ in 0..<4 {
            guard let rodzic = rodzicProcesu(biezacy), rodzic > 1 else { break }
            wynik.append(rodzic)
            biezacy = rodzic
        }
        return wynik
    }


    // MARK: Rodzina procesow programu
    //
    // Powod: dzwiek zglasza proces POMOCNICZY. Zmierzone 6 wrzesnia 2026 na
    // zywym Chrome - gral pid 2950 (`com.google.Chrome.helper`), a nie 671
    // (`com.google.Chrome`), w ktory czlowiek klika w mikserze. Wyciszanie
    // po samym pidzie programu nie mialo prawa zadzialac i nie dzialalo.

    /// Proces, ktory system uwaza za ODPOWIEDZIALNY za dany proces.
    ///
    /// To jest wlasciwa droga, a nie chodzenie po rodzicach. Zmierzone: procesy
    /// pomocnicze Safari maja rodzica `launchd` (ppid 1), wiec drzewo procesow
    /// NIE laczy ich z Safari - a system laczy:
    ///     70315 (WebKit.GPU)    → 70292 Safari
    ///      2950 (Chrome helper) →   671 Chrome
    /// Funkcja jest w libSystem i uzywa jej sam macOS (widac ja w dzienniku TCC
    /// jako „responsible"); bierzemy ja przez `dlsym`, zeby jej ewentualny brak
    /// byl brakiem funkcji, a nie odmowa uruchomienia programu.
    private static let odpowiedzialnyZa: ((pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Funkcja = @convention(c) (pid_t) -> pid_t
        let funkcja = unsafeBitCast(symbol, to: Funkcja.self)
        return { funkcja($0) }
    }()

    /// Program, do ktorego nalezy ten proces - albo on sam.
    static func programProcesu(_ pid: pid_t) -> pid_t {
        guard let odpowiedzialny = odpowiedzialnyZa?(pid), odpowiedzialny > 1 else { return pid }
        return odpowiedzialny
    }

    /// Program i wszystkie procesy, za ktore odpowiada.
    static func rodzina(_ korzen: pid_t) -> Set<pid_t> {
        var rodzice: [pid_t: pid_t] = [:]
        for proces in spisProcesow() {
            rodzice[proces.kp_proc.p_pid] = proces.kp_eproc.e_ppid
        }
        var wynik: Set<pid_t> = [korzen]
        for (dziecko, _) in rodzice {
            // Najpierw pytamy system, czyj to proces - to lapie takze uslugi
            // uruchamiane przez launchd, ktorych po rodzicach nie da sie znalezc.
            if programProcesu(dziecko) == korzen {
                wynik.insert(dziecko)
                continue
            }
            var biezacy = dziecko
            for _ in 0..<8 {
                guard let rodzic = rodzice[biezacy], rodzic > 1 else { break }
                if rodzic == korzen {
                    wynik.insert(dziecko)
                    break
                }
                biezacy = rodzic
            }
        }
        return wynik
    }

    /// Obiekty audio wszystkich procesow programu - to one ida do przechwycenia.
    static func obiektyAudio(rodzinyProgramu korzen: pid_t) -> [AudioObjectID] {
        let klan = rodzina(korzen)
        var adres = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rozmiar: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &adres, 0, nil, &rozmiar) == noErr, rozmiar > 0 else {
            return []
        }
        var obiekty = [AudioObjectID](repeating: 0, count: Int(rozmiar) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &adres, 0, nil, &rozmiar, &obiekty) == noErr else {
            return []
        }
        return obiekty.filter { obiekt in
            guard let pid = pidProcesu(obiekt) else { return false }
            return klan.contains(pid)
        }
    }

    private static func spisProcesow() -> [kinfo_proc] {
        var zapytanie: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var rozmiar = 0
        guard sysctl(&zapytanie, 4, nil, &rozmiar, nil, 0) == 0, rozmiar > 0 else { return [] }
        let ile = rozmiar / MemoryLayout<kinfo_proc>.stride
        var tablica = [kinfo_proc](repeating: kinfo_proc(), count: ile)
        guard sysctl(&zapytanie, 4, &tablica, &rozmiar, nil, 0) == 0 else { return [] }
        let realnie = rozmiar / MemoryLayout<kinfo_proc>.stride
        return Array(tablica.prefix(realnie))
    }

    private static func rodzicProcesu(_ pid: pid_t) -> pid_t? {
        var informacje = kinfo_proc()
        var rozmiar = MemoryLayout<kinfo_proc>.size
        var zapytanie: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let wynik = sysctl(&zapytanie, UInt32(zapytanie.count), &informacje, &rozmiar, nil, 0)
        guard wynik == 0, rozmiar > 0 else { return nil }
        let rodzic = informacje.kp_eproc.e_ppid
        return rodzic > 0 ? rodzic : nil
    }
}
