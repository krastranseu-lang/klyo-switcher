import AppKit

// Wartosci domyslne musza byc znane, zanim powstana obiekty czytajace ustawienia
// (router skrotow robi to juz w swoim inicjalizatorze).
Settings.registerDefaults()

// Tryb podgladu: narysuj panel do pliku i skoncz. Sprawdzane PRZED zbudowaniem
// aplikacji, zeby podglad nie zaczepial sie o klawiature ani o ikone w pasku.
if let plik = PodgladHUD.zadanaSciezka() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    PodgladHUD.wykonaj(sciezka: plik, ciemny: CommandLine.arguments.contains("--ciemny"))
}

// Sonda dzwieku: wypisz, co gra (i ewentualnie wycisz na chwile) - to jedyny
// sposob, zeby sprawdzic wyciszanie bez reki na klawiaturze.
if SondaDzwieku.zadana {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    SondaDzwieku.wykonaj()
}

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
