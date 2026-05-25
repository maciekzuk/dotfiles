#!/bin/sh
# VPN status — green "on" when openfortivpn is alive (not Stopped), dim "off" otherwise.
if ps -axo stat,ucomm 2>/dev/null | awk '$2 == "openfortivpn" && $1 !~ /T/ {f=1} END{exit !f}'; then
  printf "#[fg=#87d787]on"
else
  printf "#[fg=#4e4e4e]off"
fi
