#!/bin/sh
FILE="/tmp/claude-usage.txt"
MAX_AGE=600

LABEL="#[fg=#ffffff]"

if [ -f "$FILE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$FILE") ))
else
  age=9999
fi

# Refresh in background if cache is stale; touch to debounce repeated triggers.
if [ "$age" -gt "$MAX_AGE" ]; then
  python3 ~/.tmux/scripts/claude_usage_api.py >/dev/null 2>&1 &
  touch "$FILE" 2>/dev/null
fi

# Reset timestamps arrive as epochs so the countdown stays fresh between
# API refreshes (the cache is only rewritten every 10 minutes).
human_left() {
  case "$1" in
    ''|*[!0-9]*) echo "$1"; return ;;   # already formatted by the statusline writer
  esac
  now=$(date +%s)
  left=$(( $1 - now ))
  [ "$left" -le 0 ] && return
  d=$(( left / 86400 ))
  h=$(( (left % 86400) / 3600 ))
  m=$(( (left % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then
    echo "${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then
    echo "${h}h ${m}m"
  else
    echo "${m}m"
  fi
}

# Pick a color for a percentage value: green < 60, orange 60–84, red ≥ 85.
color_for() {
  n="${1%\%}"
  case "$n" in
    ''|*[!0-9]*) echo "#[fg=#ffffff]"; return ;;
  esac
  if [ "$n" -ge 85 ]; then
    echo "#[fg=#ff5f5f]"
  elif [ "$n" -ge 60 ]; then
    echo "#[fg=#ffaf5f]"
  else
    echo "#[fg=#87d787]"
  fi
}

FIVE_H=""
SEVEN_D=""
if [ -f "$FILE" ]; then
  while IFS= read -r line; do
    key="${line%%:*}"
    val="${line#*:}"
    case "$key" in
      5h) FIVE_H="$val" ;;
      7d) SEVEN_D="$val" ;;
    esac
  done < "$FILE"
fi

DIM="#[fg=#4e4e4e]"
parts=""
if [ -n "$FIVE_H" ]; then
  pct="${FIVE_H%%|*}"
  reset="${FIVE_H#*|}"
  parts="${LABEL}5h: $(color_for "$pct")${pct}"
  if [ "$reset" != "$FIVE_H" ]; then
    left=$(human_left "$reset")
    [ -n "$left" ] && parts="${parts} ${DIM}(${left})"
  fi
fi
if [ -n "$SEVEN_D" ]; then
  pct="${SEVEN_D%%|*}"
  reset="${SEVEN_D#*|}"
  [ -n "$parts" ] && parts="${parts}  "
  parts="${parts}${LABEL}7d: $(color_for "$pct")${pct}"
  if [ "$reset" != "$SEVEN_D" ]; then
    left=$(human_left "$reset")
    [ -n "$left" ] && parts="${parts} ${DIM}(${left})"
  fi
fi
[ -z "$parts" ] && parts="–"

echo "$parts"
