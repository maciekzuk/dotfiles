#!/bin/sh
# status-left: kropka, gdy INNA sesja (≠ bieżąca) ma okno z zaległym Claude'em.
# Pomarańcz jeśli gdziekolwiek 'waiting', inaczej zielony. Pusto, gdy nic poza
# bieżącą sesją (jej zaległości widać i tak jako kropki przy oknach).
# Wołane z #() w status-left z argumentem '#{client_session}'.

cur="$1"

st=$(tmux list-windows -a -F '#{session_name}	#{@claude-state}' 2>/dev/null \
  | awk -F'\t' -v cur="$cur" '
      $2 != "" && $1 != cur { if ($2 == "waiting") w = 1; else d = 1 }
      END { if (w) print "waiting"; else if (d) print "done" }')

# Wiodąca spacja → kropka przykleja się do nazwy sesji (#S), a stałe 3 spacje
# w status-left zostają między kropką a listą okien.
case "$st" in
  waiting) printf ' #[fg=#ffaf5f]●#[default]' ;;
  done)    printf ' #[fg=#87d787]●#[default]' ;;
esac
