#!/bin/sh
# Battery percentage with a green dot to the right when charging.
pct=$(/Users/maciek/.tmux/plugins/tmux-battery/scripts/battery_percentage.sh)
colored=$(~/.tmux/scripts/color-pct.sh "$pct" --invert)

charging=""
if pmset -g batt 2>/dev/null | grep -q "'AC Power'"; then
  charging=" #[fg=#87d787]•"
fi

printf "%s%s" "$colored" "$charging"
