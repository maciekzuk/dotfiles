#!/bin/bash
# Dev layout: 3 Claude columns top (70%) + terminal bottom (30%)

# Get current pane dimensions
ROWS=$(tmux display-message -p '#{window_height}')
COLS=$(tmux display-message -p '#{window_width}')

# Kill all panes except current
tmux kill-pane -a 2>/dev/null

# Calculate sizes
BOTTOM_ROWS=$(( ROWS * 30 / 100 ))
THIRD=$(( COLS / 3 ))

# Bottom terminal — 30% height
tmux split-window -v -l "$BOTTOM_ROWS"

# Top pane → 3 equal columns
tmux select-pane -U
tmux split-window -h -l $(( THIRD * 2 ))
tmux split-window -h -l "$THIRD"

# Name panes
tmux select-pane -T "claude-1" -t 1
tmux select-pane -T "claude-2" -t 2
tmux select-pane -T "claude-3" -t 3
tmux select-pane -T "terminal" -t 4

# Launch Claude in top 3 panes
tmux send-keys -t 1 'claude' Enter
tmux send-keys -t 2 'claude' Enter
tmux send-keys -t 3 'claude' Enter

# Focus first pane
tmux select-pane -t 1
