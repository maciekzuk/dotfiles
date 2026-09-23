#!/bin/sh
# Wołane z hooków Claude Code:
#   Stop          -> claude-tmux-notify.sh done
#   Notification  -> claude-tmux-notify.sh waiting
#
# Robi dwie rzeczy:
#   1) Kropka przy oknie — ustawia okienną flagę tmux @claude-state (czyszczoną
#      hookiem `pane-focus-in`). Pomijane TYLKO gdy realnie patrzysz na pane:
#      okno aktywne W PODPIĘTEJ sesji. Dzięki temu działa też dla odpiętych
#      sesji (ich "aktywne" okno dostanie kropkę po powrocie).
#   2) Flash w status-barze — `display-message` na KAŻDYM podpiętym kliencie,
#      z kontekstem `sesja:okno`. Widać go niezależnie od tego, w której sesji
#      siedzisz → rozwiązuje "Claude skończył w innej sesji". Czysto tmux,
#      bez macOS-owych banerów.

state="${1:-done}"

[ -n "$TMUX" ] || exit 0          # tylko wewnątrz tmux
[ -n "$TMUX_PANE" ] || exit 0     # musimy znać pane Claude'a

ctx=$(tmux display -p -t "$TMUX_PANE" '#{session_name}:#{window_index} #{window_name}' 2>/dev/null)
[ -n "$ctx" ] || exit 0

# Czy realnie patrzysz na to okno: aktywne ORAZ sesja podpięta.
set -- $(tmux display -p -t "$TMUX_PANE" '#{window_active} #{session_attached}' 2>/dev/null)
win_active="$1"; sess_attached="${2:-0}"

# 1) Kropka.
if [ "$win_active" = "1" ] && [ "$sess_attached" -ge 1 ] 2>/dev/null; then
  :   # patrzysz na to okno — kropka niepotrzebna
else
  tmux set -w -t "$TMUX_PANE" @claude-state "$state" 2>/dev/null
  tmux refresh-client -S 2>/dev/null
fi

# 2) Flash w status-barze każdego podpiętego klienta.
if [ "$state" = "waiting" ]; then
  msg="#[fg=#ffaf5f]🟠 Claude czeka#[default]  $ctx"
else
  msg="#[fg=#87d787]✅ Claude skończył#[default]  $ctx"
fi
tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r client; do
  [ -n "$client" ] && tmux display-message -c "$client" "$msg" 2>/dev/null
done
