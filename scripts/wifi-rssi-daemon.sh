#!/bin/sh
# Trzyma wifi-rssi.swift przy życiu i zrzuca ostatni sample do cache'u.
#
# Po co: shebang `#!/usr/bin/env swift` kompiluje skrypt przy KAŻDYM starcie
# (zmierzone 2,6 s), więc wołanie samplera z widgetu co sekundę zamroziłoby
# status bar. Tu koszt płacimy raz, a widget robi tylko odczyt pliku.
#
# Startowany leniwie przez net-speed.sh — nie trzeba go odpalać ręcznie.

CACHE=/tmp/tmux-wifi-rssi
PIDFILE=/tmp/tmux-wifi-rssi.pid
LOCKDIR=/tmp/tmux-wifi-rssi.lock
SAMPLER="$HOME/.tmux/scripts/wifi-rssi.swift"

# mkdir jest atomowe — dwa widgety startujące w tej samej sekundzie nie zrobią
# dwóch demonów. Zamek po ubitym procesie sprzątamy, inaczej demon nie wstanie.
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
