#!/bin/sh
# VPN status w status-barze tmux:
#   off        — brak procesu openfortivpn        (dim)
#   connecting — proces żyje, ale ppp0 jeszcze nie ma adresu 10.x  (yellow + spinner)
#   on         — ppp0 podniesione z adresem 10.x   (green)

if ! ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'; then
  printf "#[fg=#4e4e4e]off"
  exit 0
fi

if /sbin/ifconfig ppp0 2>/dev/null | grep -q 'inet 10\.'; then
  printf "#[fg=#87d787]on"
  exit 0
fi

# connecting — Braille spinner, klatka wybierana z epoch seconds (zakłada status-interval ≈ 1s)
frames="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"
idx=$(( $(date +%s) % 10 + 1 ))
spinner=$(printf '%s' "$frames" | awk -v i="$idx" '{print $i}')
printf '#[fg=#ffaf5f]%s connecting' "$spinner"
