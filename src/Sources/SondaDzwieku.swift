import AppKit
import Darwin

// MARK: - Sonda dzwieku: co teraz gra i czy wyciszenie naprawde dziala
//
// Powod powstania jest praktyczny: wyciszenie odpala sie z HUD-u klawiszem ⌘M,
// wiec nie da sie go sprawdzic inaczej niz reka na klawiaturze. Funkcja, ktorej
// nikt nie umie zmierzyc, jest funkcja, o ktorej tylko WIERZYMY, ze dziala.
//
//     Klyo\ Switcher --co-gra                 # lista grajacych programow
//     Klyo\ Switcher --wycisz 671 --na 8      # wycisza na 8 s i sam przywraca
//
// Wyciszenie zawsze sie cofa: sonda konczy sie przywroceniem dzwieku takze
// wtedy, gdy ktos ja przerwie - inaczej zostawialaby po sobie cisze bez wlasciciela.

enum SondaDzwieku {
    /// Czy program zostal uruchomiony jako sonda (a nie jako przelacznik okien).
    static var zadana: Bool {
        let a = CommandLine.arguments
        return a.contains("--co-gra") || a.contains("--wycisz") || a.contains("--glosnosc")
            || a.contains("--karty")
    }

    static func wykonaj() {
        let argumenty = CommandLine.arguments

        // `--karty` mierzy sam odczyt kart przez Dostepnosc: ile okien, ile kart,
        // czy program w ogole ma zaufanie. Bez tego „nie widac kart" nie mowi nic.
        if argumenty.contains("--karty") {
            for program in NSWorkspace.shared.runningApplications {
                guard let identyfikator = program.bundleIdentifier,
                      BrowserSupport.isSupported(identyfikator) else { continue }
                let wynik = KartyDzwieku.policz(pid: program.processIdentifier)
                print("\(program.localizedName ?? identyfikator): okien \(wynik.okna), kart \(wynik.karty), zaufanie \(wynik.zaufanie ? "TAK" : "NIE")")
            }
            let grajace = Dzwiek.grajace()
            for karta in KartyDzwieku.grajace(wsrodGrajacych: grajace) {
                print("  gra: \(karta.program) — \(karta.tytul)\(karta.wyciszona ? " [wyciszona]" : "")")
            }
            exit(0)
        }

        wypiszGrajace()

        // `--glosnosc <pid> <procent>` ustawia poziom TEGO programu; `--wycisz <pid>`
        // to skrot na zero procent. Obie drogi konczy przywrocenie.
        var pid: pid_t?
        var procent: Float = 0
        if let miejsce = argumenty.firstIndex(of: "--glosnosc"), miejsce + 1 < argumenty.count {
            pid = pid_t(argumenty[miejsce + 1])
            if miejsce + 2 < argumenty.count, let liczba = Float(argumenty[miejsce + 2]) {
                procent = liczba
            }
        } else if let miejsce = argumenty.firstIndex(of: "--wycisz"), miejsce + 1 < argumenty.count {
            pid = pid_t(argumenty[miejsce + 1])
        }
        guard let pid else { exit(0) }

        guard GlosnoscAplikacji.dostepne else {
            print("wyciszanie pojedynczego programu wymaga macOS 14.2 lub nowszego")
            exit(2)
        }

        let sekundy = liczbaPo("--na") ?? 8
        let nazwa = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let rodzina = Dzwiek.rodzina(pid).sorted()
        print("rodzina procesow: \(rodzina.count) (\(rodzina.prefix(8).map(String.init).joined(separator: ", "))\(rodzina.count > 8 ? ", …" : ""))")
        print("procesy audio programu: \(Dzwiek.obiektyAudio(rodzinyProgramu: pid).count)")

        let osiagniety = GlosnoscAplikacji.ustawPoziom(pid: pid, procent / 100)
        guard abs(osiagniety - procent / 100) < 0.01 else {
            print("NIE UDALO SIE ustawic poziomu: \(nazwa) — tor nie powstal")
            exit(1)
        }
        print("\(nazwa): \(Int(procent))% — na \(sekundy) s")
        // Poziom ma wrocic nawet po Ctrl-C.
        signal(SIGINT) { _ in GlosnoscAplikacji.przywrocWszystkie(); exit(130) }

        // Szczyt probki to DOWOD, ze dzwiek plynie przez nasz tor. Zero przez caly
        // czas znaczy, ze przechwycenie nic nie dostaje - i wtedy nie wolno mowic,
        // ze wyciszanie dziala.
        var najwyzszy: Float = 0
        let koniec = Date().addingTimeInterval(sekundy)
        while Date() < koniec {
            Thread.sleep(forTimeInterval: 0.2)
            najwyzszy = max(najwyzszy, GlosnoscAplikacji.szczyt(pid: pid))
        }
        for wiersz in GlosnoscAplikacji.diagnoza(pid: pid) { print("   \(wiersz)") }
        let ruch = GlosnoscAplikacji.ruch(pid: pid)
        print("wywolan procedury IO: \(ruch.wywolania), buforow wejscia: \(ruch.bufory), bajtow: \(ruch.bajty)")
        print(String(format: "najglosniejsza probka w torze: %.4f", najwyzszy))
        print(najwyzszy > 0.0001
              ? "dzwiek PRZECHODZI przez mikser"
              : "przez tor nie przeszlo nic - program prawdopodobnie nie gral")
        GlosnoscAplikacji.przywrocWszystkie()
        print("przywrocone: \(nazwa)")
        exit(0)
    }

    private static func liczbaPo(_ nazwa: String) -> Double? {
        let a = CommandLine.arguments
        guard let miejsce = a.firstIndex(of: nazwa), miejsce + 1 < a.count else { return nil }
        return Double(a[miejsce + 1])
    }

    private static func wypiszGrajace() {
        Dzwiek.odswiez()
        let grajace = Dzwiek.grajace()
        if grajace.isEmpty {
            print("nic teraz nie gra")
            return
        }
        print("gra teraz:")
        let karty = KartyDzwieku.grajace(wsrodGrajacych: grajace)
        for pid in grajace.sorted() {
            let program = NSRunningApplication(processIdentifier: pid)
            let nazwa = program?.localizedName ?? nazwaProcesu(pid) ?? "?"
            // Widoczne programy oznaczamy, bo lista zawiera takze procesy
            // pomocnicze - to one zglaszaja dzwiek, a czlowiek szuka programu.
            let widoczny = program?.activationPolicy == .regular ? "  ← widoczny" : ""
            print("  \(pid)\t\(nazwa)\(widoczny)")
            for karta in karty where karta.pid == pid {
                print("      └ \(karta.wyciszona ? "[wyciszona] " : "")\(karta.tytul)")
            }
        }
    }

    private static func nazwaProcesu(_ pid: pid_t) -> String? {
        var bufor = [CChar](repeating: 0, count: 1024)
        guard proc_pidpath(pid, &bufor, UInt32(bufor.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: bufor)).lastPathComponent
    }
}
