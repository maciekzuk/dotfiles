#!/bin/sh
dir="${1:-.}"
out=$(gitmux -cfg "$HOME/.config/gitmux/gitmux.conf" "$dir" 2>/dev/null)
[ -z "$out" ] && exit
printf '%s' "$out" | sed 's/bg=default//g'
