import AppKit

// Wartosci domyslne musza byc znane, zanim powstana obiekty czytajace ustawienia
// (router skrotow robi to juz w swoim inicjalizatorze).
Settings.registerDefaults()

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
