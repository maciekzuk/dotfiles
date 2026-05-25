#!/bin/sh
# VPN control — dispatched from tmux display-menu binding.
# Connect: opens new tmux window 'vpn' running ~/bin/vpn-connect (foreground, so C-c disconnects cleanly).
# Disconnect: sends C-c to that window (openfortivpn handles SIGINT → clean route teardown).

set -eu

action="${1:-status}"

is_running() {
  # Live (not Stopped/zombie) openfortivpn process exists
  ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'
}

has_window() {
  tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qx vpn
}

case "$action" in
  connect)
    if is_running; then
      tmux display-message "VPN already connected"
    else
      tmux new-window -n vpn "$HOME/bin/vpn-connect"
    fi
    ;;

  disconnect)
    if has_window; then
      tmux send-keys -t vpn C-c
      tmux display-message "VPN disconnecting…"
    elif is_running; then
      tmux display-message "openfortivpn running but no 'vpn' window — kill manually"
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
