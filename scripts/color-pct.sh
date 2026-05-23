#!/bin/sh
# Color a percentage value for the tmux status bar.
# Usage: color-pct.sh <value> [--invert]
# --invert flips thresholds (for battery: low = red).
val="$1"
mode="$2"
n="${val%\%}"

case "$n" in
  ''|*[!0-9]*) printf "#[fg=#ffffff]%s" "$val"; exit ;;
esac

if [ "$mode" = "--invert" ]; then
  if [ "$n" -le 15 ];   then color="#ff5f5f"
  elif [ "$n" -le 40 ]; then color="#ffaf5f"
  else                       color="#87d787"
  fi
else
  if [ "$n" -ge 85 ];   then color="#ff5f5f"
  elif [ "$n" -ge 60 ]; then color="#ffaf5f"
  else                       color="#87d787"
  fi
fi

printf "#[fg=%s]%s" "$color" "$val"
