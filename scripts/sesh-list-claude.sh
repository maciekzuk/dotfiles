#!/bin/sh
# `sesh list -t` z pokolorowaniem sesji, które mają zaległego Claude'a:
#   pomarańcz (ANSI 215 = #ffaf5f) — gdzieś w sesji 'waiting'
#   zielony   (ANSI 114 = #87d787) — gdzieś 'done' (a nic nie 'waiting')
# Reszta sesji bez zmian. Używane w bindingu prefix+s z `fzf --ansi`, który
# zdejmuje kody koloru z wyniku — więc `sesh connect` dostaje czystą nazwę.
#
# Mapa stanów i lista sesh idą JEDNYM pipe'em do awk (rozdzielone markerem) —
# awk -v nie przyjmuje wieloliniowych wartości.

{
  tmux list-windows -a -F '#{session_name}	#{@claude-state}' 2>/dev/null
  printf '@@CLAUDE_SEP@@\n'
  sesh list -t 2>/dev/null
} | awk -F'\t' '
  BEGIN { phase = 0; O = "\033[38;5;215m"; G = "\033[38;5;114m"; R = "\033[0m" }
  $0 == "@@CLAUDE_SEP@@" { phase = 1; next }
  phase == 0 {
    if ($2 != "") {
      if ($2 == "waiting") s[$1] = "waiting"
      else if (s[$1] != "waiting") s[$1] = "done"
    }
    next
  }
  {
    if (s[$0] == "waiting") print O $0 R
    else if (s[$0] == "done") print G $0 R
    else print $0
  }'
