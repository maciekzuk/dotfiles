#!/usr/bin/env bash
# Toggle menu for status-right widgets. Bound to prefix + W.

mark() {
  if [[ "$(tmux show -gqv "@hide-$1")" == "1" ]]; then
    printf '[ ] %s' "$2"
  else
    printf '[x] %s' "$2"
  fi
}

tmux display-menu -T "#[fg=#ff8080] widgets " -x R -y S \
  "$(mark music   music)"    m "run-shell '~/.tmux/scripts/widgets-toggle.sh music'" \
  "$(mark git     git)"      g "run-shell '~/.tmux/scripts/widgets-toggle.sh git'" \
  "$(mark vpn     vpn)"      v "run-shell '~/.tmux/scripts/widgets-toggle.sh vpn'" \
  "$(mark net     net)"      n "run-shell '~/.tmux/scripts/widgets-toggle.sh net'" \
  "$(mark claude  claude)"   c "run-shell '~/.tmux/scripts/widgets-toggle.sh claude'" \
  "$(mark battery battery)"  b "run-shell '~/.tmux/scripts/widgets-toggle.sh battery'" \
  "$(mark cpu     cpu)"      u "run-shell '~/.tmux/scripts/widgets-toggle.sh cpu'" \
  "$(mark ram     ram)"      r "run-shell '~/.tmux/scripts/widgets-toggle.sh ram'" \
  "$(mark date    date)"     d "run-shell '~/.tmux/scripts/widgets-toggle.sh date'" \
  "$(mark time    time)"     t "run-shell '~/.tmux/scripts/widgets-toggle.sh time'" \
  "" \
  "Show all"  S "run-shell '~/.tmux/scripts/widgets-toggle.sh all-show'" \
  "Hide all"  H "run-shell '~/.tmux/scripts/widgets-toggle.sh all-hide'"
