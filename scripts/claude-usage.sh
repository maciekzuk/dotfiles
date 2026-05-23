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

parts=""
if [ -n "$FIVE_H" ]; then
  pct="${FIVE_H%%|*}"
  parts="${LABEL}5h: $(color_for "$pct")${pct}"
fi
if [ -n "$SEVEN_D" ]; then
  pct="${SEVEN_D%%|*}"
  [ -n "$parts" ] && parts="${parts}  "
  parts="${parts}${LABEL}7d: $(color_for "$pct")${pct}"
fi
[ -z "$parts" ] && parts="–"

echo "$parts"
