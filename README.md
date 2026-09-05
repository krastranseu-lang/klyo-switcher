# Klyo Switcher

Przełącznik okien dla macOS: ⌘ Tab pokazuje każde otwarte okno osobno, także z innych
biurek, i przełącza biurko razem z oknem. Bez konta, bez reklam, bez zbierania danych.

Strona programu: **https://klyo.pl/klyo-switcher/**

## Po co to repozytorium

Program potrzebuje macOS do zbudowania, a my pracujemy na serwerze z Linuksem.
To repozytorium istnieje po to, żeby budowa i podpisanie odbywały się na maszynie
macOS w chmurze GitHuba — dzięki temu nikt nie musi niczego instalować na własnym Macu.

Przebieg `Zbuduj i wydaj`:
1. buduje jeden plik dla Maców z procesorem Apple i Intel,
2. podpisuje certyfikatem Developer ID (gdy w repozytorium są sekrety),
3. wysyła do Apple po potwierdzenie i przypina bilet,
4. zostawia gotowy plik do pobrania.

Bez sekretów przebieg i tak sprawdza, czy kod się kompiluje.

## Sekrety, których używa przebieg

| nazwa | co to |
|---|---|
| `CERTYFIKAT_P12` | certyfikat Developer ID Application, zakodowany base64 |
| `HASLO_P12` | hasło do tego pliku |
| `APPLE_ID` | adres konta Apple |
| `HASLO_APLIKACJI` | hasło aplikacji z appleid.apple.com (nie hasło główne) |
| `TEAM_ID` | numer zespołu z portalu Apple |

## Kod

`src/Sources` to źródła programu, `src/IconGen` rysuje ikonę. Ten sam kod jest
rozpowszechniany w instalatorze `klyo.pl/klyo-switcher/install.sh`, który buduje
program na komputerze użytkownika.
