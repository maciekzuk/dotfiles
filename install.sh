#!/bin/sh
set -e

TMUX_DIR="$HOME/.tmux"
TMUX_CONF="$HOME/.tmux.conf"
GHOSTTY_DIR="$HOME/.config/ghostty"

echo "  Installing tmux config..."

if [ -f "$TMUX_CONF" ] && [ ! -L "$TMUX_CONF" ]; then
  echo "  Backing up existing ~/.tmux.conf → ~/.tmux.conf.bak"
  mv "$TMUX_CONF" "$TMUX_CONF.bak"
fi
ln -sf "$TMUX_DIR/tmux.conf" "$TMUX_CONF"
echo "  Linked ~/.tmux.conf → ~/.tmux/tmux.conf"

if [ ! -d "$TMUX_DIR/plugins/tpm" ]; then
  echo "  Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$TMUX_DIR/plugins/tpm"
fi

echo "  Installing ghostty config..."
mkdir -p "$GHOSTTY_DIR"
if [ -f "$GHOSTTY_DIR/config" ] && [ ! -L "$GHOSTTY_DIR/config" ]; then
  mv "$GHOSTTY_DIR/config" "$GHOSTTY_DIR/config.bak"
  echo "  Backed up existing ghostty config → config.bak"
fi
ln -sf "$TMUX_DIR/ghostty/config" "$GHOSTTY_DIR/config"

echo ""
echo "  Done. Next:"
echo "    1. Open tmux"
echo "    2. Press Ctrl+Space I to install plugins"
echo ""
echo "  Optional: brew install gitmux fzf joshmedeski/sesh/sesh lazygit"
