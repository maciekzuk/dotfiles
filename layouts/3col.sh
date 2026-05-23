#!/bin/bash
# Layout: 3 equal columns

# Get current pane dimensions
COLS=$(tmux display-message -p '#{window_width}')
THIRD=$(( COLS / 3 ))

# Kill all panes except current
tmux kill-pane -a 2>/dev/null

# Split into 3 equal columns
tmux split-window -h -l $(( THIRD * 2 ))
tmux split-window -h -l "$THIRD"

# Focus first pane
tmux select-pane -t 1
