# Widget `net` — prędkość łącza i zasięg — design

Segment w `status-right` pokazujący **realny transfer** (↓/↑ na żywo), **zasięg
Wi-Fi** (słupki + dBm) i — przez chwilę po pomiarze — **wynik speedtestu**.
Pod `prefix + N` menu z pomiarem na żądanie i szczegółami połączenia.

## Cel

Chcę bez przełączania się gdziekolwiek widzieć, czy łącze *teraz* pracuje i czy
sygnał jest zdrowy. Trzy pytania, na które ma odpowiadać:

- **Czy coś leci?** — ↓/↑ na żywo (widać zawieszony download, widać upload).
- **Czy to wina zasięgu?** — dBm + słupki, te same progi co `wifi-survey.sh`.
- **Ile realnie mam?** — speedtest, ale na żądanie (kosztowny, zżera transfer).

## Co widać

```
net ↓1,2M ↑84K ▁▄█ -47 │ 115↓/38↑
    └ transfer        └ zasięg  └ speedtest (tylko 10 min po pomiarze)
```

Każda z trzech części znika samodzielnie, gdy nie ma danych: na Ethernecie
znika zasięg, przy offline zostaje przygaszone `—`, speedtest pojawia się
tylko świeżo po pomiarze.

## Dlaczego demon (pomiary, nie przypuszczenia)

Widget odpala się co sekundę (`status-interval 1`), więc koszt jest twardym
ograniczeniem. Zmierzone na tej maszynie 2026-08-09:

| Źródło | Czas | Wniosek |
|---|---|---|
| `netstat -ib` | **36 ms** | liczymy wprost w widgecie |
| `wifi-rssi.swift` (zimny start) | **2584 ms** | nie do ruszenia z widgetu |

Te 2,6 s to **kompilacja shebanga** `#!/usr/bin/env swift` przy każdym
uruchomieniu — osobny koszt od ~230 ms inicjalizacji CoreWLAN, przed którym
ostrzega nagłówek `wifi-rssi.swift`. Dlatego RSSI idzie przez **demona z
cache'em**, tak jak demon openfortivpn (commit `20f0e56`): sampler żyje długo,
widget robi `stat` + odczyt pliku.

Odrzucone alternatywy: wołanie samplera co sekundę (zamroziłoby pasek);
kompilacja `wifi-rssi.swift` do binarki `swiftc` (znika bezstanowość repo —
trzeba by budować przy instalacji i wersjonować artefakt).

## Komponenty

### `scripts/net-speed.sh` (nowy) — widget

POSIX sh, jak `battery.sh` / `vpn.sh`. Drukuje jeden sformatowany string.

**Transfer.** Interfejs z trasy domyślnej: `route -n get default | awk
'/interface:/{print $2}'`. Liczniki z `netstat -ibn -I <if>`, wiersz `<Link`.
Kolumny indeksowane **od końca** (`$(NF-4)` = Ibytes, `$(NF-1)` = Obytes) —
wiersz `ppp0` (VPN) nie ma kolumny Address, więc indeksowanie od początku
rozjeżdża się dokładnie wtedy, gdy VPN jest podniesiony.

Stan w `/tmp/tmux-net-speed-$(id -u)-<if>`: `epoch ibytes obytes last_dn last_up`.
Rate = delta bajtów / **rzeczywisty** elapsed, nie z założenia 1 s (tmux
odświeża pasek również poza harmonogramem). Przypadki brzegowe:
- `elapsed == 0` (rozdzielczość `date +%s` to sekunda) → pokazujemy ostatnio
  policzony rate zamiast dzielić przez zero,
- licznik zmalał (reset interfejsu / zmiana `<if>`) → traktujemy jak start, 0.

**Zasięg.** Odczyt `/tmp/tmux-wifi-rssi`. Cache starszy niż 5 s → uznajemy za
martwy, odpalamy demona w tle i w tej rundzie pokazujemy `—`.

Zasięg pokazujemy **zawsze, gdy Wi-Fi jest zasocjowane** (`rssi != 0`), bez
oglądania się na trasę domyślną. Pierwotnie miało to zależeć od `networksetup
-listallhardwareports`, ale ta reguła była gorsza w dwóch miejscach: przy
podniesionym VPN-ie trasa domyślna to `ppp0`, więc zasięg zniknąłby dokładnie
wtedy, gdy fizycznie dalej siedzisz na Wi-Fi, a do tego dokładałaby forka
`networksetup` w pętli sekundowej. `rssi == 0` (radio off, brak asocjacji,
kabel) chowa tę część sam z siebie — bez dodatkowego kosztu.

**Speedtest.** `/tmp/tmux-net-speedtest`: `epoch down_mbps up_mbps`. Doklejane
do paska tylko gdy wiek < 600 s.

**`--self-test`** — w duchu `wifi-survey.sh --stats-test`, na ustalonych
danych: formatowanie bajtów, mapowanie dBm → słupki/kolor, wykrycie
przeterminowanego cache'u, `elapsed == 0`, cofnięty licznik.

### `scripts/wifi-rssi-daemon.sh` (nowy)

Trzyma `wifi-rssi.swift 1` przy życiu i zapisuje każdą linię **atomowo**
(`> $CACHE.tmp && mv -f`) — widget nie może przeczytać połowy linii.
Pojedyncza instancja pilnowana `/tmp/tmux-wifi-rssi.pid` + `kill -0`.
Start **leniwy**, z widgetu: brak kroku instalacji, przeżywa reboot i padnięcie
demona, a koszt sprawdzenia to jeden `stat`.

### `scripts/net-ctl.sh` (nowy) — akcje menu

- `speedtest` — popup z żywym postępem. Zainstalowany `speedtest` to
  **speedtest-cli 2.1.4b1** (Python, sivel), **nie** oficjalne CLI Ookli —
  flagi to `--json` / `--simple`, nie `-f json`, i nie ma `--accept-license`.
  Uruchamiamy go w trybie domyślnym (gadatliwym), bo tylko ten pokazuje postęp
  na żywo, i przepuszczamy przez `tee`: linie `Download: <x> Mbit/s` /
  `Upload: ...` parsujemy z logu. Jednostkę normalizujemy (na wolnym łączu
  potrafi wypisać `Kbit/s`). Fallback: systemowy `networkQuality -c` + `jq`
  (`/usr/bin/jq` jest w systemie).
- `details` — pasmo, kanał, szerokość, PHY, szum, SNR, negocjowany link rate
  (wszystko z cache'u demona), SSID z `ipconfig getsummary en0`, brama,
  ostatni speedtest z godziną.
- `survey` — istniejący `wifi-survey.sh` w popupie.

### `tmux.conf` (zmiana)

- W `status-right`, **zaraz za `vpn`** (sieć trzyma się razem):
  `#{?@hide-net,,#[fg=#4e4e4e]net #(~/.tmux/scripts/net-speed.sh)  }`
- `bind N display-menu -T "#[fg=#ff8080] net "` → `s` speedtest, `d` szczegóły,
  `v` survey. Klawisz `N` zweryfikowany jako wolny.

### `widgets-menu.sh` / `widgets-toggle.sh` (zmiana)

`net` do tablicy `WIDGETS` i do menu `prefix + W` pod klawiszem `n`.

### `README.md` (zmiana)

Sekcja o widgecie + wpis w drzewie plików + `N` w tabeli keybindingów.

## Progi i kolory (paleta Vesper)

**Zasięg** — granice **skopiowane** z `rate()` w `wifi-survey.sh`, żeby widget
i survey nigdy nie mówiły dwóch różnych rzeczy o tym samym sygnale:

| dBm | Słupki | Kolor wypełnionych |
|---|---|---|
| ≥ −60 | `▁▄█` | zielony `#87d787` |
| ≥ −75 | `▁▄`+ wygaszony `█` | bursztyn `#ffaf5f` |
| < −75 | `▁` + wygaszone `▄█` | czerwony `#ff5f5f` |

Słupek ma **zawsze trzy komórki** — niewypełnione w `#4e4e4e`. Zmienna szerokość
przesuwałaby wszystko na prawo od widgetu przy każdym drgnięciu sygnału.

Świadomie **duplikat**, nie wspólny helper: `wifi-survey.sh` woła `rate()`
wiele razy na sekundę w pętli renderowania, więc fork do wspólnego skryptu
kosztowałby tam więcej, niż warta jest oszczędność. Zmiana progów wymaga tknięcia
obu plików — komentarz w każdym wskazuje na drugi.

**Transfer** — rampa jasności, nie kolory zdrowia: idle `#4e4e4e`, ruch biały,
≥ 5 MB/s akcent `#ff8080`. Zielony/bursztyn/czerwony w tym configu znaczą
„zdrowe/niezdrowe"; transfer to aktywność, nie zdrowie — 0 B/s w nocy nie jest
awarią.

## Decyzje projektowe

1. **Speedtest wygasa po 10 min.** Liczba wisząca na stałe twierdziłaby, że
   pomiar sprzed trzech dni jest stanem bieżącym. Pełny wynik z godziną
   zawsze jest w `prefix + N → d`.
2. **Trzy słupki, nie cztery.** `status-right` jest zatłoczony (już 9 widgetów),
   trzeci znak nie niesie tyle, ile kosztuje.
3. **Demon startowany leniwie, nie z `tmux.conf`.** Brak kroku instalacji,
   samonaprawialny.

## Założenia / ograniczenia

- Rozdzielczość czasu to sekunda (`date +%s`) — brak `$EPOCHREALTIME` w `/bin/sh`
  na macOS (bash 3.2). Stąd fallback na ostatni rate przy `elapsed == 0`.
- Transfer jest **sumaryczny dla interfejsu**, nie per-proces — pokazuje też
  ruch tła (Time Machine, iCloud). Świadomie: to ma odpowiadać „czy łącze
  pracuje", nie „co je zżera".
- Przy VPN trasa domyślna może wskazywać `ppp0` — wtedy transfer liczy się z
  tunelu, a zasięg (fizyczne Wi-Fi) pokazuje się dalej, bo nie zależy od trasy.
  Indeksowanie kolumn od końca **zweryfikowane**: wiersz `<Link` dla `en0` ma
  `NF=11`, a dla `utun0` (brak kolumny Address, ten sam kształt co `ppp0`)
  `NF=10` — `$(NF-4)`/`$(NF-1)` trafiają w Ibytes/Obytes w obu przypadkach.
- `wifi-rssi.swift` nie podaje SSID (wymaga Location Services) — nazwa sieci w
  `details` idzie z `ipconfig getsummary en0`, jak w `wifi-survey.sh`.

## Weryfikacja

1. `net-speed.sh --self-test` — czyste funkcje na ustalonych danych.
2. Standalone: `./scripts/net-speed.sh` kilka razy pod rząd — czy rate rośnie
   podczas `curl` dużego pliku, czy wraca do idle po.
3. Parsowanie `netstat` przy **podniesionym VPN-ie** — kształt kolumn już
   sprawdzony na `utun0`, zostaje potwierdzenie na żywym `ppp0`, że trasa
   domyślna faktycznie przełącza się na tunel i liczby rosną.
4. Demon: ubicie procesu → widget wstaje sam w ≤ 5 s.
5. Wyłączone Wi-Fi i kabel Ethernet → część zasięgowa znika, nie zostaje śmieć.
6. `prefix + W` → `net` chowa się i wraca; `prefix + N` → trzy akcje działają.

⚠ **Nie testować widgetów przez `display-message -p '#(...)'`** — nie czeka na
joba w tle i daje pusto nawet dla działającego skryptu (wniosek z poprzedniego
spec-a, `2026-06-16-claude-window-dot-design.md`). Weryfikacja standalone +
realnym paskiem.
