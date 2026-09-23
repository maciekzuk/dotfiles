#!/bin/sh
# Widget "net" — transfer na żywo, zasięg Wi-Fi, świeży speedtest.
#
# Wołany co sekundę ze status-right, więc musi być tani: liczniki bierze z
# netstat (~36 ms), a RSSI wyłącznie z cache'u pisanego przez demona —
# wifi-rssi.swift startuje 2,6 s, bo shebang `swift` kompiluje skrypt przy
# każdym uruchomieniu.
#
# Self-check czystych funkcji:  scripts/net-speed.sh --self-test

DIM='#4e4e4e'; WHITE='#ffffff'; ACCENT='#ff8080'
GREEN='#87d787'; AMBER='#ffaf5f'; RED='#ff5f5f'

RSSI_CACHE=/tmp/tmux-wifi-rssi
RSSI_MAX_AGE=5
SPEEDTEST_CACHE=/tmp/tmux-net-speedtest
SPEEDTEST_TTL=600
DAEMON="$HOME/.tmux/scripts/wifi-rssi-daemon.sh"

# Bajty/s → "0B" / "82K" / "1,5M" / "2,0G". Przecinek — config jest po polsku.
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

# Rampa jasności, nie kolory zdrowia — 0 B/s w nocy to nie awaria.
rate_color() {
  if   [ "$1" -lt 102400 ];  then printf '%s' "$DIM"
  elif [ "$1" -lt 5242880 ]; then printf '%s' "$WHITE"
  else printf '%s' "$ACCENT"
  fi
}

# dBm → trzy komórki; wypełnione w kolorze jakości, reszta wygaszona.
# Progi identyczne z rate() w wifi-survey.sh — zmiana tu wymaga zmiany tam.
# Stała szerokość: zmienna przepychałaby cpu/ram/zegar przy każdym drgnięciu.
sig_bars() {
  if   [ "$1" -ge -60 ]; then printf '#[fg=%s]▁▄█' "$GREEN"
  elif [ "$1" -ge -75 ]; then printf '#[fg=%s]▁▄#[fg=%s]█' "$AMBER" "$DIM"
  else printf '#[fg=%s]▁#[fg=%s]▄█' "$RED" "$DIM"
  fi
}

sig_color() {
  if   [ "$1" -ge -60 ]; then printf '%s' "$GREEN"
  elif [ "$1" -ge -75 ]; then printf '%s' "$AMBER"
  else printf '%s' "$RED"
  fi
}

# Delta / realny elapsed. elapsed 0 → oddaj ostatni wynik (date +%s ma
# rozdzielczość sekundy); licznik cofnięty (reset iface) → zero.
calc_rate() {
  [ "$3" -le 0 ] && { printf '%d' "$4"; return; }
  [ "$1" -lt "$2" ] && { printf '0'; return; }
  printf '%d' $(( ($1 - $2) / $3 ))
}

is_expired() { [ $(( $1 - $2 )) -ge "$3" ]; }

if [ "$1" = "--self-test" ]; then
  fail=0
  check() {
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
    else printf 'FAIL %s — oczek. [%s], otrzym. [%s]\n' "$1" "$2" "$3"; fail=1; fi
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
  check 'sig_bars -47' "#[fg=$GREEN]▁▄█"           "$(sig_bars -47)"
  check 'sig_bars -61' "#[fg=$AMBER]▁▄#[fg=$DIM]█" "$(sig_bars -61)"
  check 'sig_bars -76' "#[fg=$RED]▁#[fg=$DIM]▄█"   "$(sig_bars -76)"
  check 'calc_rate normalny'  '1000' "$(calc_rate 2000 1000 1 999)"
  check 'calc_rate okno 2 s'  '2000' "$(calc_rate 5000 1000 2 0)"
  check 'calc_rate elapsed=0' '777'  "$(calc_rate 2000 1000 0 777)"
  check 'calc_rate cofnięty'  '0'    "$(calc_rate 500 1000 1 42)"
  is_expired 1000 995 5 && r=tak || r=nie; check 'is_expired 5 s / TTL 5' 'tak' "$r"
  is_expired 1000 996 5 && r=tak || r=nie; check 'is_expired 4 s / TTL 5' 'nie' "$r"
  exit $fail
fi

# ── transfer ───────────────────────────────────────────────────────────
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

# Przy elapsed 0 stanu nie nadpisujemy — inaczej znacznik czasu pełzłby o
# sekundę przy każdym wywołaniu i okno pomiaru nigdy by się nie domknęło.
if [ ! -r "$STATE" ] || [ "$el" -gt 0 ]; then
  printf '%s %s %s %s %s\n' "$now" "$ib" "$ob" "$dn" "$up" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
fi

printf '#[fg=%s]↓%s #[fg=%s]↑%s' \
  "$(rate_color "$dn")" "$(fmt_rate "$dn")" \
  "$(rate_color "$up")" "$(fmt_rate "$up")"

# ── zasięg ─────────────────────────────────────────────────────────────
# Niezależnie od trasy domyślnej: przy VPN-ie trasa to ppp0, ale fizycznie
# dalej siedzisz na Wi-Fi. rssi == 0 (radio off, kabel) chowa tę część sam.
rssi=0
if [ -r "$RSSI_CACHE" ] &&
   ! is_expired "$now" "$(stat -f %m "$RSSI_CACHE" 2>/dev/null || echo 0)" "$RSSI_MAX_AGE"; then
  read rssi noise tx ch width band phy < "$RSSI_CACHE"
else
  # Cache zwietrzał albo go nie ma — odpal demona. Pełne odcięcie strumieni
  # jest konieczne: tmux czyta stdout #() do EOF, więc potomek trzymający
  # ten deskryptor zawiesiłby widget.
  nohup "$DAEMON" >/dev/null 2>&1 &
fi

case "$rssi" in
  ''|0|*[!0-9-]*) ;;
  *) printf ' %s #[fg=%s]%s' "$(sig_bars "$rssi")" "$(sig_color "$rssi")" "$rssi" ;;
esac

# ── speedtest ──────────────────────────────────────────────────────────
# Wynik pokazujemy tylko przez 10 minut — liczba wisząca na stałe
# twierdziłaby, że pomiar sprzed trzech dni to stan bieżący.
if [ -r "$SPEEDTEST_CACHE" ]; then
  read st_t st_dn st_up < "$SPEEDTEST_CACHE"
  case "$st_t" in
    ''|*[!0-9]*) ;;
    *) is_expired "$now" "$st_t" "$SPEEDTEST_TTL" ||
         printf ' #[fg=%s]│ #[fg=%s]%s↓/%s↑' "$DIM" "$WHITE" "$st_dn" "$st_up" ;;
  esac
fi
