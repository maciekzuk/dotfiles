#!/bin/sh
dir="${1:-.}"
dirname=$(basename "$dir")

printf '#[fg=#ffffff,bold] %s ' "$dirname"

if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gitout=$(gitmux -cfg "$HOME/.config/gitmux/gitmux.conf" "$dir" 2>/dev/null)
    printf ' %s#[fg=default]' "$gitout"

    stats=$(git -C "$dir" diff HEAD --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {printf "%d %d", a, d}')
    ins=${stats% *}
    del=${stats#* }
    while IFS= read -r f; do
        [ -f "$dir/$f" ] && ins=$(( ins + $(wc -l < "$dir/$f" 2>/dev/null || echo 0) ))
    done <<EOF
$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)
EOF

    if [ "$ins" -gt 0 ] || [ "$del" -gt 0 ]; then
        printf ' #[fg=#9ce5c0]+%s#[fg=default] #[fg=#ff8080]-%s#[fg=default]' "$ins" "$del"
    fi
    printf ' '
fi
