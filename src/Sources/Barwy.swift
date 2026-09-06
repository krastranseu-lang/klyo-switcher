import SwiftUI

// MARK: - Wspolna paleta ozdobna
//
// Jedno miejsce na barwy, ktore nie niosa znaczenia, tylko wyglad. Gdyby kazde
// okno mialo wlasny gradient, po dwoch zmianach programy wygladalyby jak dwa
// rozne programy - a to samo obramowanie powtorzone w trzech plikach rozjezdza
// sie zawsze, tylko nie wiadomo kiedy.
//
// Barwy sa dobrane tak, zeby czytelnie wygladaly na jasnym I ciemnym tle: zadna
// nie jest jasniejsza niz 0.8 ani ciemniejsza niz 0.25 w skladowej jasnosci.

enum Barwy {
    static let blekit = Color(red: 0.36, green: 0.55, blue: 1.00)
    static let fiolet = Color(red: 0.60, green: 0.42, blue: 0.98)
    static let turkus = Color(red: 0.25, green: 0.78, blue: 0.76)

    /// Obramowanie „z gradientem" - to samo, co daje oknom wrazenie glebi.
    /// Uzywane na krawedziach okien, nigdy do oznaczania stanu (od tego sa
    /// zielen, pomarancz i kolor akcentu systemu).
    static let obramowanie = LinearGradient(
        colors: [blekit.opacity(0.85), fiolet.opacity(0.75), turkus.opacity(0.70)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Ta sama paleta, ale ledwo widoczna - do krawedzi duzych plaszczyzn,
    /// gdzie pelna moc gradientu wygladalaby jak zabawka.
    static let obramowanieDelikatne = LinearGradient(
        colors: [blekit.opacity(0.30), fiolet.opacity(0.26), turkus.opacity(0.22)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Poswiata pod oknem - jeden kolor, bo cien z gradientem nie istnieje
    /// w SwiftUI, a dwie warstwy cienia kosztuja klatki.
    static let poswiata = fiolet.opacity(0.28)
}
