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
        return a.contains("--co-gra") || a.contains("--wycisz")
    }

    static func wykonaj() {
        let argumenty = CommandLine.arguments
        wypiszGrajace()

        guard let miejsce = argumenty.firstIndex(of: "--wycisz"),
              miejsce + 1 < argumenty.count,
              let pid = pid_t(argumenty[miejsce + 1]) else {
            exit(0)
        }

        guard GlosnoscAplikacji.dostepne else {
            print("wyciszanie pojedynczego programu wymaga macOS 14.2 lub nowszego")
            exit(2)
        }

        let sekundy = liczbaPo("--na") ?? 8
        let nazwa = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        guard GlosnoscAplikacji.przelaczWyciszenie(pid: pid) else {
            print("NIE UDALO SIE wyciszyc: \(nazwa)")
            exit(1)
        }
        print("wyciszone: \(nazwa) — na \(sekundy) s")
        // Cisza ma miec koniec nawet po Ctrl-C.
        signal(SIGINT) { _ in GlosnoscAplikacji.przywrocWszystkie(); exit(130) }
        Thread.sleep(forTimeInterval: sekundy)
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
        for pid in grajace.sorted() {
            let program = NSRunningApplication(processIdentifier: pid)
            let nazwa = program?.localizedName ?? nazwaProcesu(pid) ?? "?"
            // Widoczne programy oznaczamy, bo lista zawiera takze procesy
            // pomocnicze - to one zglaszaja dzwiek, a czlowiek szuka programu.
            let widoczny = program?.activationPolicy == .regular ? "  ← widoczny" : ""
            print("  \(pid)\t\(nazwa)\(widoczny)")
        }
    }

    private static func nazwaProcesu(_ pid: pid_t) -> String? {
        var bufor = [CChar](repeating: 0, count: 1024)
        guard proc_pidpath(pid, &bufor, UInt32(bufor.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: bufor)).lastPathComponent
    }
}
