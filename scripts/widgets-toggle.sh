#!/usr/bin/env bash
# Toggle visibility of a status-right widget, then reopen the menu so
# multiple widgets can be flipped in a row.

WIDGETS=(music git vpn net claude battery cpu ram date time)

name="$1"
case "$name" in
  all-hide)
    for w in "${WIDGETS[@]}"; do tmux set -g "@hide-$w" 1; done
    ;;
  all-show)
    for w in "${WIDGETS[@]}"; do tmux set -gu "@hide-$w"; done
    ;;
  *)
    if [[ "$(tmux show -gqv "@hide-$name")" == "1" ]]; then
      tmux set -gu "@hide-$name"
    else
      tmux set -g "@hide-$name" 1
    fi
    ;;
esac

tmux refresh-client -S
exec ~/.tmux/scripts/widgets-menu.sh
