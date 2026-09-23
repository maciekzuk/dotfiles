#!/usr/bin/env bash
# Now-playing widget for the tmux status bar.
#
# Source: Music.app (primary) / Spotify (if running), queried over AppleScript.
# We do NOT use nowplaying-cli / MediaRemote — Apple locked that framework down
# for CLI tools on macOS 15.4+, so it returns null on this machine. AppleScript
# talks straight to the player app and gives a live `player position`.
#
# Never launches a player: each query is gated behind `pgrep -x`, so the widget
# stays silent (and cheap) when nothing is running.
#
# Layout when playing:   Title — Artist  1:23 / 3:45
#   paused:              Title — Artist  1:23 / 3:45   (dimmed)
#   nothing playing:     (empty — segment collapses)

ACCENT='#ff8080'   # theme accent (elapsed time)
WHITE='#ffffff'    # track title
DIM='#808080'      # artist / paused
FAINT='#4e4e4e'    # total time
TITLEMAX=30        # max chars for the title (truncated in AppleScript)
ARTMAX=22          # max chars for the artist

# ── pull track info from a running player (one osascript call) ───────────
# Emits 5 lines: state, title, artist, position(s), duration(s) — or nothing.
query_music() {
  osascript 2>/dev/null <<OSA
set theOut to ""
tell application "Music"
  set theState to player state as string
  if theState is "playing" or theState is "paused" then
    set theTitle to (name of current track)
    set theArtist to (artist of current track)
    if (count of theTitle) > $TITLEMAX then set theTitle to (text 1 thru $((TITLEMAX - 1)) of theTitle) & "…"
    if (count of theArtist) > $ARTMAX then set theArtist to (text 1 thru $((ARTMAX - 1)) of theArtist) & "…"
    set theOut to theState & linefeed & theTitle & linefeed & theArtist & linefeed & (player position as integer) & linefeed & (duration of current track as integer)
  end if
end tell
theOut
OSA
}

query_spotify() {
  osascript 2>/dev/null <<OSA
set theOut to ""
tell application "Spotify"
  set theState to player state as string
  if theState is "playing" or theState is "paused" then
    set theTitle to (name of current track)
    set theArtist to (artist of current track)
    if (count of theTitle) > $TITLEMAX then set theTitle to (text 1 thru $((TITLEMAX - 1)) of theTitle) & "…"
    if (count of theArtist) > $ARTMAX then set theArtist to (text 1 thru $((ARTMAX - 1)) of theArtist) & "…"
    set theOut to theState & linefeed & theTitle & linefeed & theArtist & linefeed & (player position as integer) & linefeed & ((duration of current track) / 1000 as integer)
  end if
end tell
OSA
}

data=''
if pgrep -x Music >/dev/null 2>&1; then
  data=$(query_music)
fi
if [ -z "$data" ] && pgrep -x Spotify >/dev/null 2>&1; then
  data=$(query_spotify)
fi

[ -z "$data" ] && exit 0

{
  IFS= read -r state
  IFS= read -r title
  IFS= read -r artist
  IFS= read -r pos
  IFS= read -r dur
} <<EOF
$data
EOF

case "$state" in
  playing|paused) ;;
  *) exit 0 ;;
esac

# tmux treats '#' as a format escape — double it so titles render literally.
title=${title//#/##}
artist=${artist//#/##}

fmt() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# Playing → title in white, elapsed in accent; paused → everything dimmed.
if [ "$state" = playing ]; then
  active="$ACCENT"
  titlecolor="$WHITE"
else
  active="$DIM"
  titlecolor="$DIM"
fi

# Emit via printf %s — bash 3.2 mangles multibyte strings, so the title
# passes through verbatim here.
printf '#[fg=%s]%s #[fg=%s]— %s' \
  "$titlecolor" "$title" "$DIM" "$artist"

# ── elapsed / total (skipped for streams with no duration) ───────────────
if [ "${dur:-0}" -gt 0 ] 2>/dev/null; then
  printf '  #[fg=%s]%s #[fg=%s]/ %s' "$active" "$(fmt "$pos")" "$FAINT" "$(fmt "$dur")"
fi

# trailing separator (only reached when a track is showing)
printf '  '
