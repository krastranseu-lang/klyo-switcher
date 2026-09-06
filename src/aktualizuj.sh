#!/bin/bash
# Podmiana Klyo Switchera na nową wersję.
#
# Ten plik jest OSOBNY, a nie zaszyty w kodzie programu, z jednego powodu:
# skrypt w osobnym pliku można URUCHOMIĆ NA PRAWDZIWYM macOS i sprawdzić, czy
# działa. Logika zaszyta w napisie wewnątrz programu jest niesprawdzalna —
# a niesprawdzona aktualizacja to aktualizacja, która zostawia człowieka bez
# programu i każe mu pobierać plik ze strony.
#
#   aktualizuj.sh <paczka.zip> <ścieżka programu> [suma SHA-256]
#
# Zasady, których ten skrypt nie ma prawa złamać:
#   1. Po zakończeniu ZAWSZE istnieje działający program pod <ścieżką>.
#      Nowy, jeśli się udało; poprzedni, jeśli się nie udało.
#   2. Poprzednia wersja nie znika, dopóki nowa nie wystartuje.
#   3. Ścieżka programu się nie zmienia — inaczej macOS unieważnia zgody.
set -u

paczka="${1:?brak paczki}"
cel="${2:?brak ścieżki programu}"
suma_oczekiwana="${3:-}"

nazwa_procesu="KlyoSwitcher"
katalog="$(dirname "${cel}")"
nazwa_bazowa="$(basename "${cel}" .app)"
ustepujaca="${katalog}/.${nazwa_bazowa}-poprzednia-$$.app"
przygotowana="${katalog}/.${nazwa_bazowa}-nowa-$$.app"
rozpakowane="$(mktemp -d)"
rejestr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

powiedz() { printf '%s\n' "$*"; }
posprzataj() { rm -rf "${rozpakowane}" "${przygotowana}" 2>/dev/null || true; }
trap posprzataj EXIT

# --- 1. Czy dostaliśmy dokładnie to, co ogłoszono ---------------------------
if [ -n "${suma_oczekiwana}" ]; then
  suma_policzona="$(/usr/bin/shasum -a 256 "${paczka}" | awk '{print $1}')"
  if [ "${suma_policzona}" != "${suma_oczekiwana}" ]; then
    powiedz "BŁĄD: suma kontrolna się nie zgadza (${suma_policzona} ≠ ${suma_oczekiwana})"
    exit 1
  fi
  powiedz "suma kontrolna zgodna"
fi

# --- 2. Rozpakowanie i sprawdzenie podpisu ----------------------------------
if ! /usr/bin/ditto -x -k "${paczka}" "${rozpakowane}"; then
  powiedz "BŁĄD: nie udało się rozpakować paczki"
  exit 1
fi
nowa="$(/usr/bin/find "${rozpakowane}" -maxdepth 1 -name '*.app' | /usr/bin/head -1)"
if [ -z "${nowa}" ]; then
  powiedz "BŁĄD: w paczce nie ma programu"
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "${nowa}" 2>/dev/null; then
  powiedz "BŁĄD: podpis nowej wersji nie przechodzi kontroli"
  exit 1
fi
powiedz "podpis w porządku"

# --- 3. Zamknięcie starej i podmiana przez PRZESTAWIENIE NAZW ---------------
# Nie „skasuj i skopiuj". macOS przypisuje zgody konkretnej kopii programu;
# skasowanie pakietu i utworzenie nowego pod tą samą nazwą daje systemowi INNY
# program — zgoda zostaje przy nieistniejącej kopii i przełącznik w Ustawieniach
# przestaje cokolwiek znaczyć. Przestawienie nazw zachowuje ciągłość.
# Czekamy, aż proces NAPRAWDĘ zniknie, a nie „sekundę na wszelki wypadek".
#
# macOS zwraca błąd -47 („plik jest zajęty"), gdy próbujemy otworzyć program,
# którego pliki są jeszcze w użyciu przez zamykający się proces. Zamknięcie
# programu z żywym oknem, zgodami i podsłuchem klawiatury trwa dłużej niż
# sekunda — a wtedy podmiana wchodzi na zajęte pliki i człowiek dostaje
# „Nie można otworzyć aplikacji".
czekaj_az_zniknie() {
  local proba
  /usr/bin/pkill -x "${nazwa_procesu}" 2>/dev/null || true
  for proba in $(seq 1 30); do
    /usr/bin/pgrep -x "${nazwa_procesu}" >/dev/null 2>&1 || { powiedz "stara wersja zamknięta (po ${proba} próbach)"; sleep 1; return 0; }
    sleep 0.5
  done
  # Nie odpuszcza po 15 s — kończymy stanowczo, ale nadal czekamy na zwolnienie.
  /usr/bin/pkill -9 -x "${nazwa_procesu}" 2>/dev/null || true
  sleep 2
  powiedz "stara wersja zamknięta stanowczo"
}
czekaj_az_zniknie

rm -rf "${przygotowana}" "${ustepujaca}"
if ! /bin/cp -R "${nowa}" "${przygotowana}"; then
  powiedz "BŁĄD: brak prawa zapisu w ${katalog}"
  exit 1
fi
/usr/bin/xattr -dr com.apple.quarantine "${przygotowana}" 2>/dev/null || true

byla_stara=0
if [ -e "${cel}" ]; then
  if /bin/mv "${cel}" "${ustepujaca}"; then
    byla_stara=1
  else
    powiedz "BŁĄD: nie mogę odsunąć poprzedniej wersji"
    exit 1
  fi
fi
if ! /bin/mv "${przygotowana}" "${cel}"; then
  powiedz "BŁĄD: podmiana się nie powiodła"
  [ "${byla_stara}" = "1" ] && /bin/mv "${ustepujaca}" "${cel}"
  exit 1
fi
powiedz "podmieniono program"

# --- 4. Start nowej wersji --------------------------------------------------
# Rejestr programów trzyma opis POPRZEDNIEJ kopii; bez odświeżenia polecenie
# otwarcia trafia w nieaktualny wpis i nie uruchamia nic.
[ -x "${rejestr}" ] && "${rejestr}" -f "${cel}" 2>/dev/null || true

# Znacznik pobrania zdejmujemy TAKŻE po podmianie: gdyby został, macOS
# odesłałby nową wersję do katalogu tymczasowego i zgody przestałyby działać.
/usr/bin/xattr -dr com.apple.quarantine "${cel}" 2>/dev/null || true

# Krótka pauza na zwolnienie plików po podmianie — bez niej pierwsze otwarcie
# potrafi trafić w moment, gdy system jeszcze trzyma stary opis programu.
sleep 2

uruchomione=0
if [ "${KLYO_BEZ_STARTU:-0}" = "1" ]; then
  # Tryb sprawdzania: na maszynie budującej nie ma pulpitu, więc program nie
  # ma jak wystartować. Sprawdzamy wszystko poza samym startem.
  uruchomione=1
  powiedz "pominięto start (tryb sprawdzania)"
else
  for proba in 1 2 3 4 5 6 7 8; do
    # Wynik `open` zapisujemy: to on niesie kod błędu (-47 = pliki jeszcze zajęte),
    # a bez niego nie wiadomo, czy system odmówił, czy program sam nie wstał.
    odpowiedz=$(/usr/bin/open -n "${cel}" 2>&1) || powiedz "otwarcie odmówione: ${odpowiedz}"
    sleep 2
    if /usr/bin/pgrep -x "${nazwa_procesu}" >/dev/null 2>&1; then
      powiedz "uruchomiono za ${proba} razem"
      uruchomione=1
      break
    fi
    sleep 2
  done
fi

# --- 5. Sprzątanie ALBO powrót ---------------------------------------------
if [ "${uruchomione}" = "1" ]; then
  rm -rf "${ustepujaca}"
  # Kopie z numerem w nazwie („Klyo Switcher 2.app") to dla macOS osobne programy
  # z osobnymi zgodami. Człowiek włącza zgodę jednej, a uruchamia się druga.
  for katalog_kopii in /Applications "${HOME}/Applications" "${HOME}/Downloads" "${HOME}/Desktop"; do
    [ -d "${katalog_kopii}" ] || continue
    for kopia in "${katalog_kopii}/${nazwa_bazowa} "*.app; do
      [ -e "${kopia}" ] || continue
      [ "${kopia}" = "${cel}" ] && continue
      reszta="$(basename "${kopia}" .app)"
      reszta="${reszta#"${nazwa_bazowa} "}"
      case "${reszta}" in
        ''|*[!0-9]*) continue ;;
      esac
      powiedz "usuwam zbędną kopię: ${kopia}"
      rm -rf "${kopia}" || true
    done
  done
  powiedz "GOTOWE"
  exit 0
fi

# Nowa wersja nie wstała — wraca ta, która działała minutę temu.
powiedz "nowa wersja nie wystartowała — przywracam poprzednią"
if [ -e "${ustepujaca}" ]; then
  rm -rf "${cel}"
  /bin/mv "${ustepujaca}" "${cel}" || true
  [ -x "${rejestr}" ] && "${rejestr}" -f "${cel}" 2>/dev/null || true
  for proba in 1 2 3; do
    /usr/bin/open -n "${cel}" 2>/dev/null || true
    sleep 2
    /usr/bin/pgrep -x "${nazwa_procesu}" >/dev/null 2>&1 && { uruchomione=1; break; }
  done
fi
if [ "${uruchomione}" = "1" ]; then
  /usr/bin/osascript -e 'display notification "Aktualizacja się nie powiodła — pracujesz na poprzedniej wersji. Nic nie zginęło." with title "Klyo Switcher"' 2>/dev/null || true
  powiedz "PRZYWRÓCONO POPRZEDNIĄ"
else
  /usr/bin/osascript -e 'display notification "Program nie wystartował po aktualizacji. Otwórz Klyo Switcher z katalogu Programy." with title "Klyo Switcher"' 2>/dev/null || true
  powiedz "BŁĄD: brak działającego programu"
fi
exit 1
