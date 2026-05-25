#!/bin/sh
# VPN control — dispatched from tmux display-menu binding.
# Connect: daemonizes ~/bin/vpn-connect (background, logs to /tmp/vpn.log).
# Disconnect: SIGINT to openfortivpn (clean route teardown via pppd).

set -eu

action="${1:-status}"
LOG="/tmp/vpn.log"

is_running() {
  # Live (not Stopped/zombie) openfortivpn process exists
  ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'
}

case "$action" in
  connect)
    if is_running; then
      tmux display-message "VPN already connected"
    else
      nohup "$HOME/bin/vpn-connect" >"$LOG" 2>&1 </dev/null &
      disown 2>/dev/null || true
      # Animowany komunikat: spinner co 200ms aż ppp0 dostanie adres 10.x.
      # Maks 30s timeout. display-time tmux jest odświeżane przez kolejne display-message.
      (
        i=0
        saw_alive=0
        while [ "$i" -lt 150 ]; do
          if ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'; then
            saw_alive=1
            if /sbin/ifconfig ppp0 2>/dev/null | grep -q 'inet 10\.'; then
              tmux display-message "VPN connected ✓"
              exit 0
            fi
          elif [ "$saw_alive" = 1 ]; then
            # proces żył i umarł — auth error / dropped conn
            tmux display-message "VPN failed — sprawdź $LOG"
            exit 0
          fi
          frame=$(printf '⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' | awk -v k=$((i % 10 + 1)) '{print $k}')
          tmux display-message "$frame  VPN connecting…"
          i=$((i + 1))
          sleep 0.2
        done
        tmux display-message "VPN connect timeout — sprawdź $LOG"
      ) >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
    ;;

  disconnect)
    if is_running; then
      # openfortivpn: 1st SIGINT = graceful (LOGOFF + pppd teardown), 2nd = force exit.
      # Jeden sygnał często zostawia proces w cleanup, więc wysyłamy oba.
      if sudo -n /usr/bin/pkill -INT -x openfortivpn 2>/dev/null; then
        ( sleep 1; sudo -n /usr/bin/pkill -INT -x openfortivpn 2>/dev/null || true ) &
        # Animowany komunikat: spinner co 200ms aż openfortivpn zniknie. Maks 15s.
        (
          i=0
          while [ "$i" -lt 75 ]; do
            if ! ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'; then
              tmux display-message "VPN disconnected ✓"
              exit 0
            fi
            frame=$(printf '⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏' | awk -v k=$((i % 10 + 1)) '{print $k}')
            tmux display-message "$frame  VPN disconnecting…"
            i=$((i + 1))
            sleep 0.2
          done
          tmux display-message "VPN disconnect timeout — proces dalej żyje"
        ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
      else
        tmux display-message "sudo pkill failed (sudoers?)"
      fi
    else
      tmux display-message "VPN not connected"
    fi
    ;;

  status)
    if is_running; then
      pid=$(ps -axo pid,stat,ucomm 2>/dev/null | awk '$3 == "openfortivpn" && $2 !~ /T/ {print $1; exit}')
      iface=$(ifconfig 2>/dev/null | awk '/^(ppp|utun)/{name=$1} /inet 10\./{print name}' | sed 's/:$//' | head -1)
      tmux display-message "VPN connected — pid=$pid iface=${iface:-?}"
    else
      tmux display-message "VPN disconnected"
    fi
    ;;

  *)
    tmux display-message "vpn-ctl: unknown action '$action'"
    exit 1
    ;;
esac
