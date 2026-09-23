#!/bin/sh
# Layout: 8 panes in a 4×2 grid (4 columns, 2 rows)

tmux kill-pane -a 2>/dev/null

# 4 equal columns
tmux split-window -h -c "#{pane_current_path}"
tmux split-window -h -c "#{pane_current_path}"
tmux split-window -h -c "#{pane_current_path}"
tmux select-layout even-horizontal >/dev/null

# Capture the 4 column pane_ids, then split each one vertically
cols=$(tmux list-panes -F '#{pane_id}')
for id in $cols; do
  tmux split-window -v -t "$id" -c "#{pane_current_path}"
done

tmux select-pane -t "$(echo "$cols" | head -n 1)"
