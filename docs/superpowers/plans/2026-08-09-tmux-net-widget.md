# Widget `net` (prędkość łącza + zasięg) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dodać do `status-right` w tmux segment `net` pokazujący transfer na żywo, zasięg Wi-Fi i świeży wynik speedtestu, wraz z menu `prefix + N` i przełącznikiem w `prefix + W`.

**Architecture:** Widget (`net-speed.sh`, POSIX sh) jest wołany co sekundę i musi być tani — liczniki bierze z `netstat` (36 ms), a RSSI wyłącznie z pliku cache pisanego przez długo żyjącego demona (`wifi-rssi-daemon.sh`), bo `wifi-rssi.swift` startuje 2,6 s. Demon startuje leniwie z widgetu, gdy cache zwietrzeje. Kosztowny speedtest żyje osobno w `net-ctl.sh`, odpalany z menu.

**Tech Stack:** POSIX sh (`/bin/sh` = bash 3.2 w trybie sh), awk, `netstat -ibn`, `route -n get default`, tmux 3.x formaty `#[fg=...]`, istniejący `wifi-rssi.swift` (CoreWLAN), `speedtest-cli 2.1.4b1`, `/usr/bin/jq`.

**Spec:** `docs/superpowers/specs/2026-08-09-tmux-net-widget-design.md`

## Global Constraints

- **Repo jest brudny.** Niezacommitowane są `README.md`, `tmux.conf`, `scripts/claude-usage.sh`, `scripts/claude_usage_api.py`, spec z 2026-06-16 oraz nietrackowane `music.sh`, `wifi-rssi.swift`, `wifi-survey.sh`, `widgets-menu.sh`, `widgets-toggle.sh`, `claude-other-sessions.sh`, `claude-tmux-notify.sh`, `sesh-list-claude.sh`, `layouts/8.sh`, `layouts/8c.sh`, `.antigravitycli/`. **Nigdy `git add -A` ani `git commit -a`** — każdy commit stage'uje wyłącznie pliki wymienione w kroku.
- Commity wykonać dopiero po zgodzie Maćka. Jeśli jej nie ma, zostawić zmiany w working tree i powiedzieć, co jest gotowe.
- Wszystkie nowe skrypty: `#!/bin/sh`, `chmod +x`, komentarz nagłówkowy po polsku w stylu `vpn.sh` / `battery.sh`.
- Paleta Vesper, dokładnie te wartości: dim `#4e4e4e`, biały `#ffffff`, akcent `#ff8080`, zielony `#87d787`, bursztyn `#ffaf5f`, czerwony `#ff5f5f`.
- Ścieżki w `tmux.conf` i w menu zawsze przez `~/.tmux/scripts/...` (symlink do repo), nigdy `~/dotfiles/...`.
- Progi zasięgu muszą zostać zgodne z `rate()` w `scripts/wifi-survey.sh`: ≥ −60 zielony, ≥ −75 bursztyn, niżej czerwony.
- ⚠ Nie weryfikować widgetów przez `tmux display-message -p '#(...)'` — nie czeka na joba w tle i zwraca pusto nawet dla działającego skryptu. Testować standalone i realnym paskiem.

---

### Task 1: Czyste funkcje widgetu + `--self-test`

Cała logika progów, jednostek i przypadków brzegowych, zanim cokolwiek dotknie sieci. Bez tego reszta jest testowalna tylko przez wpatrywanie się w pasek.

**Files:**
- Create: `scripts/net-speed.sh`
- Test: `scripts/net-speed.sh --self-test` (wbudowany, wzorem `wifi-survey.sh --stats-test`)

**Interfaces:**
- Consumes: nic.
- Produces: `fmt_rate <bytes_per_sec>` → `"1,2M"`; `rate_color <bytes_per_sec>` → `"#4e4e4e"|"#ffffff"|"#ff8080"`; `sig_bars <dbm>` → string z `#[fg=...]` i trzema komórkami; `calc_rate <bytes_now> <bytes_prev> <elapsed> <last_rate>` → liczba; `is_expired <now> <stamp> <max_age>` → exit 0 gdy przeterminowane. Task 3 i 4 wołają dokładnie te nazwy.

- [ ] **Step 1: Napisz szkielet skryptu z sekcją self-test (test najpierw)**

Utwórz `scripts/net-speed.sh` z samym self-testem i **pustymi** funkcjami:

```sh
#!/bin/sh
# Widget "net" — transfer na żywo, zasięg Wi-Fi, świeży speedtest.
# Wołany co sekundę z status-right, więc musi być tani: liczniki z netstat,
# RSSI wyłącznie z cache'u demona (wifi-rssi.swift startuje 2,6 s).
#
# Self-check czystych funkcji:  scripts/net-speed.sh --self-test

DIM='#4e4e4e'; WHITE='#ffffff'; ACCENT='#ff8080'
GREEN='#87d787'; AMBER='#ffaf5f'; RED='#ff5f5f'

fmt_rate()   { :; }
rate_color() { :; }
sig_bars()   { :; }
calc_rate()  { :; }
is_expired() { :; }

if [ "$1" = "--self-test" ]; then
  fail=0
  check() { # check <opis> <oczekiwane> <otrzymane>
    if [ "$2" = "$3" ]; then
      printf 'ok   %s\n' "$1"
    else
      printf 'FAIL %s — oczek. [%s], otrzym. [%s]\n' "$1" "$2" "$3"; fail=1
    fi
  }

  check 'fmt_rate 0'          '0B'    "$(fmt_rate 0)"
  check 'fmt_rate 1023'       '1023B' "$(fmt_rate 1023)"
  check 'fmt_rate 1024'       '1K'    "$(fmt_rate 1024)"
  check 'fmt_rate 84000'      '82K'   "$(fmt_rate 84000)"
  check 'fmt_rate 1572864'    '1,5M'  "$(fmt_rate 1572864)"
  check 'fmt_rate 10485760'   '10M'   "$(fmt_rate 10485760)"
  check 'fmt_rate 2147483648' '2,0G'  "$(fmt_rate 2147483648)"

  check 'rate_color idle'  "$DIM"    "$(rate_color 1000)"
  check 'rate_color ruch'  "$WHITE"  "$(rate_color 200000)"
  check 'rate_color heavy' "$ACCENT" "$(rate_color 6000000)"

  check 'sig_bars -47 (mocny)'   "#[fg=$GREEN]▁▄█"                 "$(sig_bars -47)"
  check 'sig_bars -60 (granica)' "#[fg=$GREEN]▁▄█"                 "$(sig_bars -60)"
  check 'sig_bars -61 (średni)'  "#[fg=$AMBER]▁▄#[fg=$DIM]█"       "$(sig_bars -61)"
  check 'sig_bars -75 (granica)' "#[fg=$AMBER]▁▄#[fg=$DIM]█"       "$(sig_bars -75)"
  check 'sig_bars -76 (słaby)'   "#[fg=$RED]▁#[fg=$DIM]▄█"         "$(sig_bars -76)"

  check 'calc_rate normalny'      '1000' "$(calc_rate 2000 1000 1 999)"
  check 'calc_rate okno 2 s'      '2000' "$(calc_rate 5000 1000 2 0)"
  check 'calc_rate elapsed=0'     '777'  "$(calc_rate 2000 1000 0 777)"
  check 'calc_rate licznik cofn.' '0'    "$(calc_rate 500 1000 1 42)"

  is_expired 1000 995 5 && r=tak || r=nie
  check 'is_expired 5 s przy TTL 5' 'tak' "$r"
  is_expired 1000 996 5 && r=tak || r=nie
  check 'is_expired 4 s przy TTL 5' 'nie' "$r"

  exit $fail
fi
```

- [ ] **Step 2: Uruchom self-test i potwierdź, że pada**

```bash
chmod +x scripts/net-speed.sh && ./scripts/net-speed.sh --self-test
```

Oczekiwane: **exit code 1** i niemal same `FAIL` — puste funkcje nie zwracają nic, więc porównania lecą na pusty string. Jeden wyjątek: `is_expired 5 s przy TTL 5` przejdzie przypadkiem, bo zaślepka `:` zwraca 0, czyli akurat to, czego ten przypadek oczekuje. Drugi test `is_expired` (4 s przy TTL 5) musi paść — jeśli oba przechodzą, zaślepka nie została podmieniona.

- [ ] **Step 3: Zaimplementuj funkcje**

Podmień pięć zaślepek na:

```sh
# Bajty/s → "0B" / "82K" / "1,2M" / "2,0G". Przecinek, bo cały config jest po polsku.
fmt_rate() {
  b=$1
  [ "$b" -lt 0 ] && b=0
  if   [ "$b" -lt 1024 ];       then printf '%dB' "$b"
  elif [ "$b" -lt 1048576 ];    then printf '%dK' $((b / 1024))
  elif [ "$b" -lt 10485760 ];   then printf '%d,%dM' $((b / 1048576)) $(((b % 1048576) * 10 / 1048576))
  elif [ "$b" -lt 1073741824 ]; then printf '%dM' $((b / 1048576))
  else printf '%d,%dG' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
  fi
}

# Rampa jasności, nie kolory zdrowia: 0 B/s w nocy to nie awaria.
rate_color() {
  if   [ "$1" -lt 102400 ];  then printf '%s' "$DIM"
  elif [ "$1" -lt 5242880 ]; then printf '%s' "$WHITE"
  else printf '%s' "$ACCENT"
  fi
}

# dBm → trzy komórki, wypełnione w kolorze jakości, reszta wygaszona.
# Progi identyczne z rate() w wifi-survey.sh — zmiana tu wymaga zmiany tam.
# Stała szerokość: zmienna przepychałaby cpu/ram/zegar przy każdym drgnięciu.
sig_bars() {
  if   [ "$1" -ge -60 ]; then printf '#[fg=%s]▁▄█' "$GREEN"
  elif [ "$1" -ge -75 ]; then printf '#[fg=%s]▁▄#[fg=%s]█' "$AMBER" "$DIM"
  else printf '#[fg=%s]▁#[fg=%s]▄█' "$RED" "$DIM"
  fi
}

# Delta bajtów / realny elapsed. Dwa przypadki brzegowe:
#   elapsed 0 — date +%s ma rozdzielczość sekundy (brak $EPOCHREALTIME w sh),
#               więc zamiast dzielić przez zero oddajemy ostatni wynik;
#   licznik cofnięty — reset interfejsu albo zmiana <if>, liczymy od zera.
calc_rate() {
  [ "$3" -le 0 ] && { printf '%d' "$4"; return; }
  [ "$1" -lt "$2" ] && { printf '0'; return; }
  printf '%d' $(( ($1 - $2) / $3 ))
}

# is_expired <now> <stamp> <max_age> — exit 0 gdy przeterminowane.
is_expired() { [ $(( $1 - $2 )) -ge "$3" ]; }
```

- [ ] **Step 4: Uruchom self-test i potwierdź, że przechodzi**

```bash
./scripts/net-speed.sh --self-test
```

Oczekiwane: wyłącznie linie `ok`, exit code 0. Jeśli `fmt_rate 84000` daje `84K` zamiast `82K`, ktoś dzieli przez 1000 zamiast 1024 — poprawić dzielnik, nie test.

- [ ] **Step 5: Commit** (po zgodzie Maćka)

```bash
git add scripts/net-speed.sh
git commit -m "net widget: czyste funkcje formatowania + self-test"
```

---

### Task 2: Demon RSSI

**Files:**
- Create: `scripts/wifi-rssi-daemon.sh`
- Reads: `scripts/wifi-rssi.swift` (istniejący, bez zmian)
- Writes: `/tmp/tmux-wifi-rssi`, `/tmp/tmux-wifi-rssi.pid`, `/tmp/tmux-wifi-rssi.lock`

**Interfaces:**
- Consumes: nic z poprzednich tasków.
- Produces: plik `/tmp/tmux-wifi-rssi` z jedną linią w formacie samplera: `<rssi> <noise> <txMbps> <channel> <width> <band> <phy>`, odświeżaną co sekundę. Task 3 czyta ten plik i jego mtime. Skrypt jest idempotentny — drugie uruchomienie przy żywym demonie kończy się natychmiast z kodem 0.

- [ ] **Step 1: Napisz demona**

```sh
#!/bin/sh
# Trzyma wifi-rssi.swift przy życiu i zrzuca ostatni sample do cache'u.
#
# Po co: shebang `#!/usr/bin/env swift` kompiluje skrypt przy KAŻDYM starcie
# (zmierzone 2,6 s), więc wołanie samplera z widgetu co sekundę zamroziłoby
# status bar. Tu koszt płacimy raz, a widget robi tylko odczyt pliku.
#
# Uruchamiany leniwie przez net-speed.sh — nie trzeba go startować ręcznie.

CACHE=/tmp/tmux-wifi-rssi
PIDFILE=/tmp/tmux-wifi-rssi.pid
LOCKDIR=/tmp/tmux-wifi-rssi.lock
SAMPLER="$HOME/.tmux/scripts/wifi-rssi.swift"

# mkdir jest atomowe — dwa widgety startujące w tej samej sekundzie nie zrobią
# dwóch demonów. Zamek po ubitym procesie sprzątamy, inaczej demon nigdy nie wstanie.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi

echo $$ > "$PIDFILE"
trap 'rm -rf "$LOCKDIR"; rm -f "$PIDFILE"' EXIT INT TERM

# Zapis atomowy: widget nie może przeczytać połowy linii.
"$SAMPLER" 1 2>/dev/null | while IFS= read -r line; do
  printf '%s\n' "$line" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
done
```

- [ ] **Step 2: Uruchom demona i sprawdź, że cache żyje**

```bash
chmod +x scripts/wifi-rssi-daemon.sh
nohup ./scripts/wifi-rssi-daemon.sh >/dev/null 2>&1 &
sleep 5
cat /tmp/tmux-wifi-rssi
```

Oczekiwane: linia w rodzaju `-60 -93 720 40 80 5 ax` (siedem pól). Pierwszy sample pojawia się po ~3 s — 2,6 s idzie na kompilację Swifta.

- [ ] **Step 3: Sprawdź, że cache się odświeża, a nie zamarł**

```bash
a=$(stat -f %m /tmp/tmux-wifi-rssi); sleep 3; b=$(stat -f %m /tmp/tmux-wifi-rssi)
[ "$b" -gt "$a" ] && echo "ok — cache żyje" || echo "FAIL — mtime stoi"
```

Oczekiwane: `ok — cache żyje`.

- [ ] **Step 4: Sprawdź pojedynczą instancję**

```bash
./scripts/wifi-rssi-daemon.sh; echo "exit=$?"
pgrep -fc wifi-rssi.swift
```

Oczekiwane: `exit=0` natychmiast (bez zawieszenia) i **dokładnie 1** proces samplera.

- [ ] **Step 5: Sprawdź samonaprawę po ubiciu**

```bash
kill "$(cat /tmp/tmux-wifi-rssi.pid)"; sleep 1
ls -d /tmp/tmux-wifi-rssi.lock 2>/dev/null && echo "FAIL — zamek został" || echo "ok — zamek sprzątnięty"
nohup ./scripts/wifi-rssi-daemon.sh >/dev/null 2>&1 &
sleep 5; pgrep -fc wifi-rssi.swift
```

Oczekiwane: `ok — zamek sprzątnięty`, potem znowu 1 proces. Jeśli zamek został, `trap` nie złapał sygnału — sprawdź, czy lista sygnałów to `EXIT INT TERM`.

- [ ] **Step 6: Commit** (po zgodzie Maćka)

```bash
git add scripts/wifi-rssi-daemon.sh
git commit -m "net widget: demon RSSI z atomowym cache'em"
```

---

### Task 3: Transfer w widgecie

**Files:**
- Modify: `scripts/net-speed.sh` (dopisz ciało główne pod sekcją `--self-test`)

**Interfaces:**
- Consumes: `fmt_rate`, `rate_color`, `calc_rate` z Taska 1.
- Produces: widget drukujący samą część transferową, np. `#[fg=#ffffff]↓1,2M ↑84K`. Task 4 dokleja się do tego wyjścia.

- [ ] **Step 1: Sprawdź parsowanie liczników na obu kształtach wiersza**

```bash
netstat -ibn -I en0   | awk 'NR>1 && $3 ~ /Link/ {print "en0   NF="NF" I="$(NF-4)" O="$(NF-1); exit}'
netstat -ibn -I utun0 | awk 'NR>1 && $3 ~ /Link/ {print "utun0 NF="NF" I="$(NF-4)" O="$(NF-1); exit}'
```

Oczekiwane: `en0 NF=11`, `utun0 NF=10`, w obu przypadkach sensowne liczby. `utun0` nie ma kolumny Address — dokładnie ten kształt ma `ppp0` z openfortivpn, dlatego kolumny liczymy **od końca**, nigdy od początku.

- [ ] **Step 2: Dopisz ciało główne**

Na końcu `scripts/net-speed.sh`, **pod** blokiem `--self-test`:

```sh
iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -z "$iface" ] && { printf '#[fg=%s]—' "$DIM"; exit 0; }

# Kolumny od końca: wiersz <Link dla ppp0/utun0 nie ma kolumny Address,
# więc indeksowanie od początku rozjeżdża się dokładnie na VPN-ie.
set -- $(netstat -ibn -I "$iface" 2>/dev/null | awk 'NR>1 && $3 ~ /Link/ {print $(NF-4), $(NF-1); exit}')
ib=$1; ob=$2
[ -z "$ib" ] && { printf '#[fg=%s]—' "$DIM"; exit 0; }

now=$(date +%s)
STATE="/tmp/tmux-net-speed-$(id -u)-$iface"
if [ -r "$STATE" ]; then
  read p_t p_ib p_ob p_dn p_up < "$STATE"
else
  p_t=$now; p_ib=$ib; p_ob=$ob; p_dn=0; p_up=0
fi

el=$((now - p_t))
dn=$(calc_rate "$ib" "$p_ib" "$el" "$p_dn")
up=$(calc_rate "$ob" "$p_ob" "$el" "$p_up")

# Przy elapsed 0 stanu NIE nadpisujemy — inaczej znacznik czasu pełzłby o
# sekundę przy każdym wywołaniu i okno pomiaru nigdy by się nie domknęło.
if [ ! -r "$STATE" ] || [ "$el" -gt 0 ]; then
  printf '%s %s %s %s %s\n' "$now" "$ib" "$ob" "$dn" "$up" > "$STATE.tmp" &&
    mv -f "$STATE.tmp" "$STATE"
fi

printf '#[fg=%s]↓%s #[fg=%s]↑%s' \
  "$(rate_color "$dn")" "$(fmt_rate "$dn")" \
  "$(rate_color "$up")" "$(fmt_rate "$up")"
```

- [ ] **Step 3: Sprawdź, że idle daje zera, a ruch je podnosi**

```bash
./scripts/net-speed.sh; echo
sleep 2; ./scripts/net-speed.sh; echo
curl -s -o /dev/null https://speed.hetzner.de/100MB.bin & sleep 3
./scripts/net-speed.sh; echo
kill %1 2>/dev/null
```

Oczekiwane: pierwsze wywołania blisko `↓0B ↑0B` w kolorze `#4e4e4e`, w trakcie `curl` wyraźne `↓` w `#ffffff` lub `#ff8080`. Jeśli po `curl` dalej jest `0B`, plik stanu nie zapisuje się — sprawdź uprawnienia do `/tmp` i czy `mv -f` nie pada.

- [ ] **Step 4: Sprawdź, że self-test dalej przechodzi**

```bash
./scripts/net-speed.sh --self-test
```

Oczekiwane: same `ok`. Blok self-testu kończy się `exit`, więc ciało główne nie może się przy nim odpalić.

- [ ] **Step 5: Commit** (po zgodzie Maćka)

```bash
git add scripts/net-speed.sh
git commit -m "net widget: transfer z liczników netstat"
```

---

### Task 4: Zasięg i speedtest w widgecie

**Files:**
- Modify: `scripts/net-speed.sh` (rozszerz wyjście)
- Reads: `/tmp/tmux-wifi-rssi` (Task 2), `/tmp/tmux-net-speedtest` (Task 5 zapisuje; tu tylko odczyt)

**Interfaces:**
- Consumes: `sig_bars`, `is_expired` z Taska 1; format cache'u z Taska 2.
- Produces: pełne wyjście widgetu, np. `#[fg=#ffffff]↓1,2M ↑84K #[fg=#87d787]▁▄█ #[fg=#87d787]-47`. Task 6 wstawia je do `status-right`.

- [ ] **Step 1: Dopisz zasięg**

Na końcu `scripts/net-speed.sh`, za `printf` z transferem:

```sh
RSSI_CACHE=/tmp/tmux-wifi-rssi
RSSI_MAX_AGE=5

# Zasięg pokazujemy niezależnie od trasy domyślnej: przy VPN-ie trasa to ppp0,
# ale fizycznie dalej siedzisz na Wi-Fi. rssi == 0 (radio off, kabel, brak
# asocjacji) chowa tę część sam z siebie — bez forka networksetup w pętli.
rssi=0
if [ -r "$RSSI_CACHE" ]; then
  mt=$(stat -f %m "$RSSI_CACHE" 2>/dev/null || echo 0)
  if is_expired "$now" "$mt" "$RSSI_MAX_AGE"; then
    # Cache zwietrzały — demon padł albo nigdy nie wstał. Odpal go w tle.
    # Pełne odcięcie strumieni jest konieczne: tmux czyta stdout #() do EOF,
    # więc potomek trzymający ten deskryptor zawiesiłby widget.
    nohup "$HOME/.tmux/scripts/wifi-rssi-daemon.sh" >/dev/null 2>&1 &
  else
    read rssi noise tx ch width band phy < "$RSSI_CACHE"
  fi
else
  nohup "$HOME/.tmux/scripts/wifi-rssi-daemon.sh" >/dev/null 2>&1 &
fi

if [ "${rssi:-0}" -ne 0 ] 2>/dev/null; then
  if   [ "$rssi" -ge -60 ]; then sig_col=$GREEN
  elif [ "$rssi" -ge -75 ]; then sig_col=$AMBER
  else sig_col=$RED
  fi
  printf ' %s #[fg=%s]%s' "$(sig_bars "$rssi")" "$sig_col" "$rssi"
fi
```

- [ ] **Step 2: Sprawdź zasięg na żywo**

```bash
./scripts/net-speed.sh; echo
cat /tmp/tmux-wifi-rssi
```

Oczekiwane: wyjście kończy się słupkami i wartością dBm zgodną z pierwszą liczbą w cache'u. Kolor musi zgadzać się z progami: −47 → zielony `#87d787`.

- [ ] **Step 3: Sprawdź zachowanie przy martwym cache'u**

```bash
kill "$(cat /tmp/tmux-wifi-rssi.pid)" 2>/dev/null
rm -f /tmp/tmux-wifi-rssi
./scripts/net-speed.sh; echo    # zasięgu brak, widget NIE wisi
sleep 6
./scripts/net-speed.sh; echo    # zasięg wraca — demon wstał sam
```

Oczekiwane: pierwsze wywołanie kończy się natychmiast, sam transfer, bez części zasięgowej. Po ~6 s zasięg wraca. Jeśli pierwsze wywołanie **wisi**, `nohup` nie odciął deskryptorów — sprawdź `>/dev/null 2>&1` i `&`.

- [ ] **Step 4: Dopisz świeży speedtest**

Na końcu skryptu:

```sh
SPEEDTEST_CACHE=/tmp/tmux-net-speedtest
SPEEDTEST_TTL=600

# Wynik pokazujemy tylko przez 10 minut. Liczba wisząca na stałe twierdziłaby,
# że pomiar sprzed trzech dni to stan bieżący; pełny wynik jest w prefix+N → d.
if [ -r "$SPEEDTEST_CACHE" ]; then
  read st_t st_dn st_up < "$SPEEDTEST_CACHE"
  if [ -n "$st_t" ] && ! is_expired "$now" "$st_t" "$SPEEDTEST_TTL"; then
    printf ' #[fg=%s]│ #[fg=%s]%s↓/%s↑' "$DIM" "$WHITE" "$st_dn" "$st_up"
  fi
fi
```

- [ ] **Step 5: Sprawdź świeży i przeterminowany wynik**

```bash
printf '%s 115 38\n' "$(date +%s)" > /tmp/tmux-net-speedtest
./scripts/net-speed.sh; echo          # ma pokazać 115↓/38↑
printf '%s 115 38\n' "$(( $(date +%s) - 700 ))" > /tmp/tmux-net-speedtest
./scripts/net-speed.sh; echo          # ma NIE pokazać
rm -f /tmp/tmux-net-speedtest
```

Oczekiwane: dokładnie jak w komentarzach. Granica to 600 s — 700 s musi zniknąć.

- [ ] **Step 6: Sprawdź self-test i czas wykonania**

```bash
./scripts/net-speed.sh --self-test
time ./scripts/net-speed.sh >/dev/null
```

Oczekiwane: same `ok`, a `real` **poniżej 0,15 s**. Widget odpala się co sekundę — wszystko powyżej ~0,2 s będzie czuć jako lag paska.

- [ ] **Step 7: Commit** (po zgodzie Maćka)

```bash
git add scripts/net-speed.sh
git commit -m "net widget: zasięg z cache'u demona + świeży speedtest"
```

---

### Task 5: `net-ctl.sh` — speedtest, szczegóły, survey

**Files:**
- Create: `scripts/net-ctl.sh`
- Writes: `/tmp/tmux-net-speedtest`, `/tmp/tmux-net-speedtest.log`

**Interfaces:**
- Consumes: `/tmp/tmux-wifi-rssi` (Task 2).
- Produces: `/tmp/tmux-net-speedtest` w formacie `<epoch> <down_mbit> <up_mbit>` — dokładnie to, co czyta Task 4. Trzy podkomendy: `speedtest`, `details`, `survey`. Task 6 podpina je pod `prefix + N`.

- [ ] **Step 1: Napisz skrypt**

```sh
#!/bin/sh
# Akcje menu prefix+N: pomiar łącza, szczegóły połączenia, survey pokoi.
#
# Zainstalowany `speedtest` to speedtest-cli 2.1.4b1 (Python, sivel), NIE CLI
# Ookli — flagi to --json/--simple, nie `-f json`, i nie ma --accept-license.
# Puszczamy go w trybie domyślnym, bo tylko ten pokazuje postęp na żywo,
# a wynik wyłuskujemy z logu.

CACHE=/tmp/tmux-net-speedtest
LOG=/tmp/tmux-net-speedtest.log
RSSI_CACHE=/tmp/tmux-wifi-rssi

# <wartość> <jednostka> → liczba całkowita w Mbit/s (na wolnym łączu bywa Kbit/s).
to_mbit() {
  awk -v v="$1" -v u="$2" 'BEGIN {
    if (u ~ /^Kbit/)      v = v / 1000
    else if (u ~ /^Gbit/) v = v * 1000
    printf "%.0f", v
  }'
}

run_speedtest() {
  if command -v speedtest >/dev/null 2>&1; then
    printf 'Pomiar przez speedtest-cli — potrwa ok. 30 s...\n\n'
    speedtest 2>&1 | tee "$LOG"
    dn=$(to_mbit "$(awk '/^Download:/ {print $2; exit}' "$LOG")" "$(awk '/^Download:/ {print $3; exit}' "$LOG")")
    up=$(to_mbit "$(awk '/^Upload:/   {print $2; exit}' "$LOG")" "$(awk '/^Upload:/   {print $3; exit}' "$LOG")")
  else
    printf 'Brak speedtest — używam systemowego networkQuality...\n\n'
    networkQuality -c > "$LOG" 2>&1
    cat "$LOG"
    dn=$(jq -r '(.dl_throughput // 0) / 1000000 | floor' "$LOG" 2>/dev/null)
    up=$(jq -r '(.ul_throughput // 0) / 1000000 | floor' "$LOG" 2>/dev/null)
  fi

  case "$dn$up" in
    ''|*[!0-9]*) printf '\nNie udało się odczytać wyniku — cache bez zmian.\n' ;;
    *) printf '%s %s %s\n' "$(date +%s)" "$dn" "$up" > "$CACHE"
       printf '\nZapisano: %s Mbit/s ↓ / %s Mbit/s ↑\n' "$dn" "$up" ;;
  esac
  printf '\n[Enter zamyka]'; read _
}

show_details() {
  printf '── Połączenie ──────────────────────\n'
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  ssid=$(ipconfig getsummary en0 2>/dev/null | awk -F' : ' '/ SSID /{print $2; exit}')
  printf 'Interfejs trasy : %s\n' "${iface:-brak}"
  printf 'Brama           : %s\n' "${gw:-brak}"
  printf 'SSID            : %s\n' "${ssid:-brak}"

  if [ -r "$RSSI_CACHE" ]; then
    read rssi noise tx ch width band phy < "$RSSI_CACHE"
    printf '\n── Wi-Fi ───────────────────────────\n'
    printf 'Sygnał          : %s dBm\n' "$rssi"
    printf 'Szum            : %s dBm\n' "$noise"
    printf 'SNR             : %s dB\n' "$((rssi - noise))"
    printf 'Link rate       : %s Mbit/s\n' "$tx"
    printf 'Kanał           : %s (%s MHz, %s GHz, 802.11%s)\n' "$ch" "$width" "$band" "$phy"
  else
    printf '\nBrak danych Wi-Fi — demon nie działa.\n'
  fi

  if [ -r "$CACHE" ]; then
    read st_t st_dn st_up < "$CACHE"
    printf '\n── Ostatni speedtest ───────────────\n'
    printf '%s Mbit/s ↓ / %s Mbit/s ↑   (%s)\n' "$st_dn" "$st_up" \
      "$(date -r "$st_t" '+%Y-%m-%d %H:%M')"
  fi
  printf '\n[Enter zamyka]'; read _
}

case "$1" in
  speedtest) run_speedtest ;;
  details)   show_details ;;
  survey)    exec "$HOME/.tmux/scripts/wifi-survey.sh" ;;
  *) printf 'użycie: net-ctl.sh speedtest|details|survey\n' >&2; exit 2 ;;
esac
```

- [ ] **Step 2: Sprawdź `details`**

```bash
chmod +x scripts/net-ctl.sh
./scripts/net-ctl.sh details
```

Oczekiwane: trzy sekcje z sensownymi wartościami — SNR jako różnica sygnału i szumu (np. −60 − (−93) = 33 dB), kanał/pasmo/PHY zgodne z `cat /tmp/tmux-wifi-rssi`. `SSID` może być puste, jeśli `ipconfig getsummary` zwraca inny wcięcie — wtedy dostroić wzorzec `awk -F' : '`.

- [ ] **Step 3: Sprawdź `speedtest` i zapis cache'u**

```bash
./scripts/net-ctl.sh speedtest
cat /tmp/tmux-net-speedtest
```

Oczekiwane: widoczny postęp, na końcu `Zapisano: N Mbit/s ↓ / M Mbit/s ↑`, a w cache'u trzy pola `epoch dn up`. **Uwaga: to zżera realny transfer** (kilkadziesiąt–kilkaset MB) — nie puszczać w pętli ani na liczonym łączu.

- [ ] **Step 4: Sprawdź, że widget podchwytuje świeży wynik**

```bash
./scripts/net-speed.sh; echo
```

Oczekiwane: na końcu `│ N↓/M↑` z liczbami z kroku 3.

- [ ] **Step 5: Sprawdź `survey`**

```bash
./scripts/net-ctl.sh survey
```

Oczekiwane: startuje istniejący TUI `wifi-survey.sh`. Wyjść przez `q`.

- [ ] **Step 6: Commit** (po zgodzie Maćka)

```bash
git add scripts/net-ctl.sh
git commit -m "net widget: menu akcji — speedtest, szczegóły, survey"
```

---

### Task 6: Podpięcie do tmux (`status-right`, `prefix + W`, `prefix + N`) i README

**Files:**
- Modify: `tmux.conf:152` (`status-right`) oraz sekcja keybindingów przy `tmux.conf:89-95`
- Modify: `scripts/widgets-toggle.sh:5`
- Modify: `scripts/widgets-menu.sh:13-21`
- Modify: `README.md`

**Interfaces:**
- Consumes: `net-speed.sh` (Task 4), `net-ctl.sh` (Task 5).
- Produces: działający widget w pasku, przełącznik `@hide-net`, menu pod `N`.

- [ ] **Step 1: Wstaw segment do `status-right`**

W `tmux.conf:152`, **bezpośrednio po** segmencie `vpn` (czyli po `#{?@hide-vpn,,...vpn.sh)  }`, a przed `#{?@hide-claude,...`), wstaw:

```
#{?@hide-net,,#[fg=#4e4e4e]net #(~/.tmux/scripts/net-speed.sh)  }
```

Sieć trzyma się razem: `vpn` i `net` sąsiadują.

- [ ] **Step 2: Dodaj `net` do przełącznika**

W `scripts/widgets-toggle.sh:5` zmień tablicę na:

```sh
WIDGETS=(music git vpn net claude battery cpu ram date time)
```

W `scripts/widgets-menu.sh`, między wierszem `vpn` a `claude`, dopisz:

```sh
  "$(mark net     net)"      n "run-shell '~/.tmux/scripts/widgets-toggle.sh net'" \
```

Klawisz `n` jest wolny — zajęte w tym menu są `m g v c b u r d t` oraz `S`/`H`.

- [ ] **Step 3: Dodaj menu `prefix + N`**

W `tmux.conf`, zaraz za blokiem `bind V` (menu VPN, linie 89–95):

```
# Sieć — prefix + N: pomiar łącza, szczegóły, survey
bind N display-menu -T "#[fg=#ff8080] net " -x C -y C \
  "Speedtest"    s "display-popup -E -w 70% -h 60% '~/.tmux/scripts/net-ctl.sh speedtest'" \
  "Szczegóły"    d "display-popup -E -w 70% -h 60% '~/.tmux/scripts/net-ctl.sh details'" \
  "" \
  "Survey pokoi" v "display-popup -E -w 90% -h 90% '~/.tmux/scripts/net-ctl.sh survey'"
```

- [ ] **Step 4: Przeładuj i sprawdź w realnym pasku**

```bash
tmux source-file ~/.tmux.conf
```

Oczekiwane: w pasku między `vpn` a `claude` pojawia się `net ↓… ↑… ▁▄█ -NN`, aktualizowany co sekundę. Sprawdź kolejno:
- `prefix + W` → pozycja `[x] net`, po wybraniu `n` znika z paska, po ponownym wraca;
- `prefix + N` → trzy pozycje, każda otwiera popup;
- pasek nie zacina się ani nie miga.

Jeśli segment jest pusty, **nie** diagnozuj przez `display-message -p '#(...)'` — to zawsze daje pusto. Uruchom skrypt standalone.

- [ ] **Step 5: Uzupełnij README**

W `README.md`:
1. Nowa sekcja o widgecie — co pokazuje, skąd bierze dane, czemu przez demona, że speedtest znika po 10 min.
2. W tabeli keybindingów dopisz wiersz `| `N` | Menu sieci — speedtest, szczegóły, survey |`.
3. W drzewie plików, przy istniejących wpisach `wifi-*`, dopisz:

```
│   ├── net-speed.sh            # widget: transfer, zasięg, świeży speedtest
│   ├── net-ctl.sh              # akcje prefix+N: speedtest / szczegóły / survey
│   ├── wifi-rssi-daemon.sh     # trzyma sampler przy życiu, pisze cache RSSI
```

- [ ] **Step 6: Commit** (po zgodzie Maćka)

```bash
git add tmux.conf scripts/widgets-menu.sh scripts/widgets-toggle.sh README.md
git commit -m "tmux: widget net w status-right + menu prefix+N"
```

⚠ `widgets-menu.sh` i `widgets-toggle.sh` są dziś **nietrackowane** — ten commit wciągnie je do repo w całości, razem z ich dotychczasową zawartością. To zamierzone, ale warto, żeby Maciek o tym wiedział.

---

## Weryfikacja końcowa

- [ ] `./scripts/net-speed.sh --self-test` — same `ok`
- [ ] `time ./scripts/net-speed.sh` — poniżej 0,15 s
- [ ] Pasek żyje przez minutę bez migotania i przesuwania się prawej strony
- [ ] `prefix + W` chowa i przywraca `net`
- [ ] `prefix + N` — trzy akcje działają
- [ ] Wi-Fi wyłączone → część zasięgowa znika, transfer zostaje, brak śmieci
- [ ] VPN podniesiony (`prefix + V` → Connect) → transfer liczy się z `ppp0`, zasięg dalej widoczny
- [ ] Demon ubity → widget wstaje sam w ≤ 5 s i nie wisi w międzyczasie
