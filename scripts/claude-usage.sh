#!/bin/sh
FILE="/tmp/claude-usage.txt"
MAX_AGE=600

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
[ -n "$FIVE_H" ] && parts="5h: ${FIVE_H%%|*}"
if [ -n "$SEVEN_D" ]; then
  [ -n "$parts" ] && parts="${parts} #[fg=#4e4e4e]•#[fg=#ff8080]"
  parts="${parts} 7d: ${SEVEN_D%%|*}"
fi
[ -z "$parts" ] && parts="–"

echo "$parts"
