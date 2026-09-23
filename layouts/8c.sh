#!/bin/sh
# Layout: 8 panes in a 4×2 grid, each one running `claude`

tmux kill-pane -a 2>/dev/null

# Start claude in the surviving original pane
tmux send-keys "claude" Enter

# 3 more columns (each new pane runs claude directly)
tmux split-window -h -c "#{pane_current_path}" claude
tmux split-window -h -c "#{pane_current_path}" claude
tmux split-window -h -c "#{pane_current_path}" claude
tmux select-layout even-horizontal >/dev/null

# Split each column vertically — new bottom panel runs claude
cols=$(tmux list-panes -F '#{pane_id}')
for id in $cols; do
  tmux split-window -v -t "$id" -c "#{pane_current_path}" claude
done

tmux select-pane -t "$(echo "$cols" | head -n 1)"
