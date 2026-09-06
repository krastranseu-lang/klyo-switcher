# Klyo Switcher — przekazanie projektu

Alt+Tab dla macOS. Darmowy, wydawany poza App Store (sklep odpada: piaskownica
zabrania przechwytywania klawiszy i sterowania cudzymi oknami).

---

## 1. GDZIE JEST KOD — czytaj to najpierw

**Źródłem prawdy jest GitHub: `krastranseu-lang/klyo-switcher`** (publiczne, 19 plików Swift).

⚠️ **Na ex44 leży `/data/klyo/klyo-switcher/src/` i jest STARSZY** (15 plików — brakuje
`Schowek.swift`, `SchowekOkno.swift`, `Uprawnienia.swift`, `Spaces.swift` w aktualnej
postaci). Wgranie tamtej wersji na GitHub **skasuje kilkanaście godzin pracy**.
Sprawdź to sam przed jakąkolwiek synchronizacją:

```bash
gh api "repos/krastranseu-lang/klyo-switcher/git/trees/HEAD?recursive=1" \
  --jq '[.tree[]|select(.path|endswith(".swift"))]|length'
ssh root@10.10.0.18 'ls /data/klyo/klyo-switcher/src/Sources/*.swift | wc -l'
```

Ten rozjazd nie został scalony — ex44 ma ~130 linii, których nie ma na GitHubie
(w `AppController.swift`, `SwitcherView.swift`, `SettingsWindow.swift`). Trzeba je
przejrzeć **przed** ujednoliceniem, ale pracować zawsze na wersji z GitHuba.

### Edycja bez klonowania repozytorium
Cała praca w tej sesji szła przez API, bez `git clone`:
```bash
gh api repos/krastranseu-lang/klyo-switcher/contents/src/Sources/PLIK.swift \
  --jq '.content' | base64 -d > PLIK.swift
# … edycja …
sha=$(gh api repos/krastranseu-lang/klyo-switcher/contents/src/Sources/PLIK.swift --jq '.sha')
gh api -X PUT repos/krastranseu-lang/klyo-switcher/contents/src/Sources/PLIK.swift \
  -f message="opis zmiany" -f content="$(base64 -w0 PLIK.swift)" -f sha="$sha"
```

---

## 2. JAK SIĘ BUDUJE — Swift kompiluje się tylko na macOS

Nie mamy Maca. Kompiluje **GitHub Actions na `macos-15`**.

| Przepis | Do czego |
|---|---|
| `wydanie.yml` | buduje uniwersalną binarkę (arm64 + x86_64), rysuje ikonę, pakuje **bez podpisu** |
| `dmg.yml` | składa obraz instalacyjny z okna: tło, strzałka, ikony na miejscach |
| `sprawdz-aktualizacje.yml` | sprawdzian aktualizacji na żywym macOS + 2 próby negatywne |
| `sprawdz-obraz.yml` | otwiera obraz, ocenia Gatekeeperem, przeciąga i **uruchamia** program |

Budowanie rusza samo po zmianie w `src/**`. Wersję bierze z `src/Sources/Info.plist`
(`CFBundleShortVersionString` + `CFBundleVersion`) — **podbij ją przed każdym wydaniem**.

```bash
gh run list --repo krastranseu-lang/klyo-switcher --workflow wydanie.yml --limit 1
gh run download <ID> --repo krastranseu-lang/klyo-switcher   # paczka BEZ PODPISU
```

**Pułapka kompilatora SwiftUI:** przy dłuższych łańcuchach modyfikatorów dostaniesz
`unable to type-check this expression in reasonable time`. Lekarstwo: policz wartości
do zwykłych `let` **przed** `return`, a do widoku wstaw gotowe zmienne. Wystąpiło
dwa razy (`Uprawnienia.swift`, `SwitcherView.swift`).

---

## 3. JAK SIĘ PODPISUJE — klucz nigdy nie opuszcza ex44

Sekrety **celowo nie są** w GitHub Secrets. Podpis i notaryzacja dzieją się na ex44,
z Linuksa, narzędziem `rcodesign` (apple-codesign).

```
/data/apple-wydawanie/          (prawa 700)
├── klucze/                     certyfikat.p12 · haslo.txt · api-klucz.json · AuthKey_*.p8
├── podpisz.sh                  podpis + notaryzacja + przypięcie biletu
└── prace/                      katalog roboczy
```

Jedno polecenie na wszystko:
```bash
ssh root@10.10.0.18 'cd /data/klyo/klyo-switcher/wydanie && \
  /usr/local/bin/wydaj-dla-apple niepodpisana-X.Y.Z.zip'
```
Certyfikat: **Developer ID Application: Illia Krasnopolskyi (G7A4YAW56V)**.
Pełny opis i cztery pułapki `.p12`: `docs/wydawanie-dla-apple.md` w repozytorium VanFit.

Obraz DMG podpisuje się osobno (obraz to też plik, który system ocenia):
```bash
rcodesign sign --p12-file klucze/certyfikat.p12 --p12-password-file klucze/haslo.txt \
  --code-signature-flags runtime OBRAZ.dmg
rcodesign notary-submit --api-key-file klucze/api-klucz.json OBRAZ.dmg   # → ID zgłoszenia
rcodesign notary-wait --api-key-file klucze/api-klucz.json <ID>          # czekaj na "Accepted"
rcodesign staple OBRAZ.dmg
```

⚠️ **Bilet przypina się do `.app` albo do `.dmg`, NIGDY do archiwum ZIP** — `--staple`
na ZIP-ie kończy się „do not know how to staple", co narzędzie meldowało jako
„Apple nie potwierdziło programu" (fałszywa porażka). Poprawione w `podpisz.sh`.
⚠️ Bilet powstaje **kilka minut po wysyłce** — bez `notary-wait` dostaniesz
„NOT_FOUND: Record not found".
⚠️ `ditto` nie istnieje na Linuksie; pakujemy `zip -qry` (`-y` zachowuje dowiązania,
bez tego podpis pada).

---

## 4. GDZIE TRAFIA WYDANIE

Dwa miejsca, oba potrzebne:

| Miejsce | Po co |
|---|---|
| **GitHub Releases** (`v1.28.0`) | stąd pobiera **człowiek** — przeglądarki nie ostrzegają, bo domena ma historię |
| **klyo.pl** `/data/klyo/klyo-switcher/wydanie/` | stąd pobiera **program** przy aktualizacji + kopia zapasowa |

Publikacja na GitHuba narzędziem, które pilnuje zgodności sum kontrolnych:
```bash
~/bin/klyo-publikuj-wydania          # na vps-ai-1 (tam jest token gh)
```
Powstało, bo automat awansował wersję w kanale, ale wydania na GitHubie nie tworzył —
i przycisk na stronie prowadził w pustkę (404).

**Kanał aktualizacji:** `wydanie/appcast.json` (`version`, `build`, `packageURL` → ZIP,
`packageSHA256`, `notes`). Program aktualizuje się **archiwum ZIP**, nie obrazem —
obraz jest wyłącznie dla pierwszej instalacji.
**Historia na stronie:** `wydanie/wydania.json`.

**Strona:** generator `/data/klyo/studio/` na ex44 → `node zbuduj.cjs` (+ `node powiadom.cjs`
zgłasza zmiany wyszukiwarkom). Moduł `czesci/pobieranie.js` sam czyta `appcast.json`
i składa przycisk — **filtruje paczki po numerze wersji**, bo wcześniej brał
„najładniejszy plik z katalogu" i sklejał adres do pliku, którego nie było.

**Strażnik po każdej publikacji** (pyta z pominięciem pamięci podręcznej, ma test negatywny):
```bash
ssh root@10.10.0.18 '/data/klyo/klyo-switcher/wydanie/sprawdz-pobieranie.sh'
```

---

## 5. CZEGO NIE WOLNO ZEPSUĆ — blizny z tej sesji

1. **Podmiana programu przez PRZESTAWIENIE NAZW, nigdy `rm -rf` + `cp`.** macOS wiąże
   zgody z konkretną kopią; skasowanie i utworzenie nowej = dla systemu inny program,
   zgoda zostaje przy nieistniejącej kopii i przełącznik w Ustawieniach przestaje
   cokolwiek znaczyć. Kod: `src/aktualizuj.sh`.
2. **Po skopiowaniu programu zdejmij `com.apple.quarantine`** (`xattr -dr`). Bez tego
   macOS izoluje kopię w losowym katalogu tymczasowym („AppTranslocation") i pytanie
   o przeniesienie wraca w kółko. To robi Finder przy ręcznym przeciągnięciu — my
   musimy zrobić to samo.
3. **Poprzednia wersja nie znika, dopóki nowa nie wystartuje.** Inaczej każdy błąd po
   podmianie zostawia człowieka bez programu (zdarzyło się).
4. **Przed podmianą czekaj, aż stary proces NAPRAWDĘ zniknie** (pętla `pgrep`, nie
   `sleep 1`). Inaczej macOS zwraca **-47** („plik zajęty") i program się nie otwiera.
5. **`aktualizuj.sh` jest OSOBNYM PLIKIEM** (jedzie w `Contents/Resources/`), bo tylko
   plik da się uruchomić w sprawdzianie. Logika zaszyta w napisie wewnątrz Swifta jest
   niesprawdzalna — i właśnie dlatego aktualizacja potrafiła zostawić użytkownika z niczym.
6. **Zgód systemowych program NIE MOŻE sobie nadać** (Dostępność, Nagrywanie ekranu,
   Automatyzacja) — macOS tego zabrania. Może tylko poprosić system o pytanie, otworzyć
   właściwy panel i naprawić zepsuty wpis (`tccutil reset <usługa> <bundleID>`).
   **Zwykłe ustawienia systemu** (np. `AppleSpacesSwitchOnActivate`) zmieniać MOŻE — i to
   należy do naszego okna ustawień, nie do odsyłania człowieka do panelu Apple.
7. **Automatyzację sprawdzaj pytaniem do systemu** (`AEDeterminePermissionToAutomateTarget`),
   nie po skutku „czy udało się pobrać karty" — brak kart to zwykle zamknięta przeglądarka.

---

## 6. CO JEST NIEDOKOŃCZONE — zadanie dla następnego

### Zmiana biurka przy wyborze okna (główna otwarta sprawa)

Stan: program **poprawnie rozpoznaje** okna na innych biurkach (raport z 1.27.0
pokazał `biurko 2: 7 · biurko 3: 6`), ale **nie ma dowodu**, że samo przełączenie
działa — w żadnym zarejestrowanym wyborze użytkownik nie trafił w kartę z innego
biurka (zawsze `biurko okna == biezace`, `decyzja: to samo biurko`).

Zrobione dotąd:
- `_SLPSSetFrontProcessWithOptions` z trybem `userGenerated` (0x200) — jak AltTab;
- brak zapasowego `NSRunningApplication.activate()` przy przeskoku (potrafi **cofnąć**
  przełączenie);
- `SLSSpaceSetFrontPSN` przywraca stan biurka źródłowego (inaczej po powrocie wyskakuje
  nasze okno zamiast tamtego);
- zapasowe przejście **Ctrl+strzałka**, gdy WindowServer odmówi (ten sam skrót, co gest
  trzema palcami);
- wykrywanie biurka **dwiema drogami**: SkyLight oraz obecność okna wśród widocznych
  na ekranie (druga nie zależy od prywatnych funkcji).

**Następny krok:** poprosić użytkownika, żeby przytrzymał ⌘, doszedł Tabem do karty
z plakietką „Biurko 2"/„Biurko 3" i dopiero puścił, a potem przysłał raport
(Ustawienia → Ogólne → Biurka → **„Skopiuj raport o biurkach"**). Dopiero wpis
`decyzja: PRZESKOK` powie, czy mechanizm działa.

Drobiazg do zbadania: w raporcie **31 okien ma położenie „nieznane"** — SkyLight nie
przypisuje im biurka. Prawdopodobnie okna pomocnicze bez przypisanej przestrzeni;
nie wygląda na przyczynę usterki, ale nikt tego nie potwierdził.

### Mniejsze
- `gry.klyo.pl/projekty/klyo-switcher/` zwraca 404 — portal gier prowadzi inny agent,
  nie ruszaliśmy bez decyzji właściciela.
- Rozjazd źródeł ex44 ↔ GitHub (punkt 1) — do przejrzenia i scalenia.

---

## 7. SKĄD SIĘ UCZYĆ DALEJ

- Metoda AltTab (wzorzec dla przełączania okien): `lwouis/alt-tab-macos`, pliki
  `src/switcher/state/Window.swift` (funkcja `focus()`) i
  `src/macos/api-wrappers/SkyLight.framework.swift`.
- Translokacja programów: `lapcatsoftware.com/articles/app-translocation.html`,
  `eclecticlight.co/2023/05/09/what-causes-app-translocation/`.
- Podpisywanie i notaryzacja z Linuksa: `docs/wydawanie-dla-apple.md` (repozytorium VanFit).

**Zasada, która kosztowała najwięcej:** nie wydawaj bez sprawdzianu na prawdziwym
macOS i nie diagnozuj z domysłów — raport diagnostyczny wbudowany w program rozstrzygnął
sprawę, której trzy „naprawy" wcześniej nie ruszyły.
