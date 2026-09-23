#!/bin/sh
# Akcje menu prefix+N: pomiar łącza, szczegóły połączenia, survey pokoi.
#
# Zainstalowany `speedtest` to speedtest-cli (Python, sivel), NIE CLI Ookli —
# flagi to --json/--simple, nie `-f json`, i nie ma --accept-license.
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
