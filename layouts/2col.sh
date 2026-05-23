#!/bin/bash
# Layout: 2 equal columns

# Kill all panes except current
tmux kill-pane -a 2>/dev/null

# Split into 2 equal columns
tmux split-window -h -c "#{pane_current_path}"

# Focus first pane
tmux select-pane -t 1
