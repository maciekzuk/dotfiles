#!/usr/bin/env zsh
#
# Wi-Fi site survey — walk around the house and measure the signal room by room.
#
# Usage:  scripts/wifi-survey.sh [--window SECONDS] [--interval SECONDS]
#         scripts/wifi-survey.sh --stats-test        (self-check of the maths)
#
# Flow: type a room name, hit Enter, stand still for ten seconds while it
# collects samples, and it stores median / min / max for that room. Repeat.
# `q` (or Ctrl-C) exits and prints the rooms ranked best-to-worst — outside the
# alternate screen, so the table stays in your scrollback.
#
# Why zsh and not bash: the render loop needs sub-second non-blocking reads, and
# macOS still ships bash 3.2, whose `read -t` rejects fractional timeouts.
#
# Data comes from wifi-rssi.swift (CoreWLAN) — see that file for why the obvious
# sources (`airport`, `wdutil`, `system_profiler`) are all unusable here. No sudo
# is required.

emulate -L zsh
zmodload zsh/datetime

SCRIPT_DIR=${0:A:h}
SAMPLER=$SCRIPT_DIR/wifi-rssi.swift

INTERVAL=0.25    # seconds between samples
WINDOW=10        # seconds of sampling per room
BAR_W=22         # width of the live signal bar
ROOM_BAR_W=17    # width of the per-room bars in the saved list
RSSI_FLOOR=-90   # bar empty at or below this
RSSI_CEIL=-30    # bar full at or above this

# Palette — same values as scripts/color-pct.sh, as 24-bit escapes.
GREEN=$'\e[38;2;135;215;135m'
AMBER=$'\e[38;2;255;175;95m'
RED=$'\e[38;2;255;95;95m'
ACCENT=$'\e[38;2;255;128;128m'
WHITE=$'\e[38;2;255;255;255m'
DIM=$'\e[38;2;128;128;128m'
FAINT=$'\e[38;2;78;78;78m'
RESET=$'\e[0m'

# ── pure helpers (exercised by --stats-test) ─────────────────────────────

# Number of filled cells for a dBm value, mapped over RSSI_FLOOR..RSSI_CEIL.
bar_fill() {
  local dbm=$1 width=$2
  local span=$(( RSSI_CEIL - RSSI_FLOOR ))
  local v=$(( dbm - RSSI_FLOOR ))
  (( v < 0 )) && v=0
  (( v > span )) && v=span
  print -r -- $(( v * width / span ))
}

bar() {
  local dbm=$1 width=$2
  local filled=$(bar_fill $dbm $width)
  local empty=$(( width - filled ))
  local f='' e=''
  (( filled > 0 )) && f=${(l:filled::█:)}
  (( empty  > 0 )) && e=${(l:empty::░:)}
  print -r -- "$f$e"
}

# "<colour escape>|<label>" for a dBm value.
rate() {
  local d=$1
  if   (( d >= -50 )); then print -r -- "$GREEN|Świetnie"
  elif (( d >= -60 )); then print -r -- "$GREEN|Dobrze"
  elif (( d >= -67 )); then print -r -- "$AMBER|OK"
  elif (( d >= -75 )); then print -r -- "$AMBER|Słabo"
  else                      print -r -- "$RED|Bardzo słabo"
  fi
}

# "median worst best count" for the dBm values passed as arguments.
#
# Median rather than mean: dBm is logarithmic, so an arithmetic mean is not
# strictly meaningful, and one momentary dropout would drag it several dB.
# For an even count we take the lower of the two middle values — a survey
# should err pessimistic, and it keeps the result a whole dBm.
stats() {
  # sort -n rather than zsh's ${(n)} flag: that flag reads embedded numbers and
  # ignores the leading minus, so it orders dBm values by magnitude and hands
  # back min/max reversed. Runs once per room, so the fork costs nothing.
  # Guard before the pipeline: ${(f)""} would yield one empty field, not none.
  (( $# == 0 )) && { print -r -- "0 0 0 0"; return }
  local -a v=(${(f)"$(print -l -- $@ | sort -n)"})
  local n=$#v
  local med
  if (( n % 2 == 0 )); then
    med=$v[$(( n / 2 ))]
  else
    med=$v[$(( (n + 1) / 2 ))]
  fi
  print -r -- "$med $v[1] $v[$n] $n"
}

# ── self-check ───────────────────────────────────────────────────────────

if [[ $1 == --stats-test ]]; then
  print -r -- "stats odd   (-70 -50 -60)            -> $(stats -70 -50 -60)           [oczek. -60 -70 -50 3]"
  print -r -- "stats even  (-70 -50 -60 -55)        -> $(stats -70 -50 -60 -55)       [oczek. -60 -70 -50 4]"
  print -r -- "stats one   (-42)                    -> $(stats -42)                   [oczek. -42 -42 -42 1]"
  print -r -- "stats empty ()                       -> $(stats)                       [oczek. 0 0 0 0]"
  print -r -- "bar_fill -90 / -30 / -60 (w=22)      -> $(bar_fill -90 22) $(bar_fill -30 22) $(bar_fill -60 22)  [oczek. 0 22 11]"
  print -r -- "bar_fill klamrowanie -120 / -10      -> $(bar_fill -120 22) $(bar_fill -10 22)  [oczek. 0 22]"
  print -r -- "bar -60 (w=10)                       -> $(bar -60 10)"
  print -r -- "rate -37 / -65 / -80                 -> ${$(rate -37)#*|} / ${$(rate -65)#*|} / ${$(rate -80)#*|}"
  exit 0
fi

while (( $# )); do
  case $1 in
    --window)   WINDOW=$2;   shift 2 ;;
    --interval) INTERVAL=$2; shift 2 ;;
    -h|--help)  sed -n '3,20p' $0; exit 0 ;;
    *) print -u2 "wifi-survey: nieznana opcja: $1"; exit 2 ;;
  esac
done

# ── preflight ────────────────────────────────────────────────────────────

if ! command -v swift >/dev/null 2>&1; then
  print -u2 "wifi-survey: brak 'swift' — wymagane Xcode lub Command Line Tools (xcode-select --install)"
  exit 1
fi
if [[ ! -r $SAMPLER ]]; then
  print -u2 "wifi-survey: nie znaleziono samplera: $SAMPLER"
  exit 1
fi

# Wi-Fi device name, then the SSID it is on. Both are read once — neither
# changes while you walk, and `ipconfig` is too slow to poll in the loop.
wifi_dev=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/^Hardware Port: Wi-Fi$/ {getline; print $2; exit}')
: ${wifi_dev:=en0}
ssid=$(ipconfig getsummary $wifi_dev 2>/dev/null | awk -F' : ' '$1 ~ /^ *SSID$/ {print $2; exit}')
: ${ssid:=?}

# ── terminal ─────────────────────────────────────────────────────────────

saved_stty=$(stty -g 2>/dev/null)
sampler_pid=''
sampler_err=$(mktemp -t wifi-survey)
sampler_died=0

cleanup() {
  [[ -n $sampler_pid ]] && kill $sampler_pid 2>/dev/null
  exec 3<&- 2>/dev/null
  [[ -n $saved_stty ]] && stty $saved_stty 2>/dev/null
  printf '\e[?25h\e[?1049l'    # cursor back, leave the alternate screen
  if (( sampler_died )); then
    print -u2 "wifi-survey: sampler przestał odpowiadać${$(<$sampler_err):+ — $(<$sampler_err)}"
  fi
  rm -f $sampler_err
  summary
}
trap cleanup EXIT INT TERM

# ── state ────────────────────────────────────────────────────────────────

typeset -a room_name room_med room_min room_max room_n
typeset -a samples
mode=idle          # idle | measuring
typed=''           # room name being entered
current=''         # room being measured
started=0.0        # EPOCHREALTIME when the current measurement began
rssi=0 noise=0 tx=0 chan=0 width='-' band='-' phy='-'
last_frame=''

summary() {
  (( $#room_name == 0 )) && return
  print -r -- ""
  print -r -- "${ACCENT}  WiFi survey — wyniki${RESET}${DIM} (sieć: $ssid)${RESET}"
  print -r -- "${FAINT}  ────────────────────────────────────────────────────────────${RESET}"
  # Sort best-first. The key is median+200 zero-padded to three digits, which
  # turns the negative dBm into a plain descending string sort (+200 keeps it
  # positive for any RSSI a radio can actually report).
  local -a keyed
  local i
  for i in {1..$#room_name}; do
    keyed+=("${(l:3::0:)$(( room_med[i] + 200 ))}|$i")
  done
  local entry idx colour label
  for entry in ${(On)keyed}; do
    idx=${entry#*|}
    IFS='|' read -r colour label <<< "$(rate $room_med[idx])"
    printf '  %s%-14s%s %s%4d dBm%s  %s%s%s  %smin %d / max %d · n=%d%s\n' \
      "$WHITE" "$room_name[idx]" "$RESET" \
      "$colour" "$room_med[idx]" "$RESET" \
      "$colour" "$(bar $room_med[idx] $ROOM_BAR_W)" "$RESET" \
      "$FAINT" "$room_min[idx]" "$room_max[idx]" "$room_n[idx]" "$RESET"
  done
  print -r -- ""
}

draw() {
  local -a L
  local colour label
  L+=("  ${ACCENT}WiFi survey${RESET}${DIM} — ${ssid} · ch ${chan} (${band}GHz/${width}MHz) · 802.11${phy}${RESET}")
  L+=("")

  if (( rssi == 0 )); then
    L+=("  ${RED}brak połączenia z siecią Wi-Fi${RESET}")
    L+=("")
  else
    IFS='|' read -r colour label <<< "$(rate $rssi)"
    L+=("  ${colour}$(bar $rssi $BAR_W)${RESET}  ${WHITE}${rssi} dBm${RESET}   ${colour}${label}${RESET}")
    L+=("  ${DIM}SNR $(( rssi - noise )) dB   ·   tx ${tx} Mbps${RESET}")
  fi
  L+=("")

  if [[ $mode == measuring ]]; then
    local elapsed=$(( EPOCHREALTIME - started ))
    local secs=$(( elapsed < WINDOW ? elapsed : WINDOW ))
    # `local -i` truncates the float; int() would need zmodload zsh/mathfunc,
    # and calling it unloaded is a fatal error that kills the whole shell.
    local -i cells=$(( elapsed * 10 / WINDOW ))
    (( cells > 10 )) && cells=10
    (( cells < 0 ))  && cells=0
    local f='' e=''
    (( cells > 0 ))      && f=${(l:cells::█:)}
    (( 10 - cells > 0 )) && e=${(l:$(( 10 - cells ))::░:)}
    L+=("  ${ACCENT}▶${RESET} ${WHITE}${current}${RESET}   ${ACCENT}[${f}${e}]${RESET}  ${DIM}$(printf '%.0f' $secs)/${WINDOW} s   n=$#samples${RESET}")
  fi
  L+=("")

  if (( $#room_name > 0 )); then
    L+=("  ${FAINT}──── zapisane ────${RESET}")
    local i
    for i in {1..$#room_name}; do
      IFS='|' read -r colour label <<< "$(rate $room_med[i])"
      L+=("$(printf '  %s%-12s%s %s%4d%s  %smin %d / max %d%s  %s%s%s' \
        "$WHITE" "$room_name[i]" "$RESET" \
        "$colour" "$room_med[i]" "$RESET" \
        "$FAINT" "$room_min[i]" "$room_max[i]" "$RESET" \
        "$colour" "$(bar $room_med[i] $ROOM_BAR_W)" "$RESET")")
    done
    L+=("")
  fi

  if [[ $mode == idle ]]; then
    L+=("  ${ACCENT}pokój ❯${RESET} ${WHITE}${typed}${RESET}${ACCENT}▏${RESET}")
    L+=("  ${FAINT}[Enter] mierz ${WINDOW}s · [q] koniec${RESET}")
  else
    L+=("  ${FAINT}mierzę… stój w miejscu${RESET}")
  fi

  # Each line ends with \e[K (clear to EOL) and the frame with \e[J (clear the
  # rest), so a shorter frame cannot leave stale text behind — cheaper and less
  # flickery than clearing the whole screen first.
  # The `p` flag is required: without it the j separator is taken literally and
  # the escapes get printed as the text "\e[K\n".
  local frame=${(pj:\e[K\n:)L}$'\e[K\e[J'
  [[ $frame == $last_frame ]] && return
  last_frame=$frame
  printf '\e[H%s' "$frame"
}

finish_room() {
  local med worst best n
  read -r med worst best n <<< "$(stats $samples)"
  if (( n > 0 )); then
    room_name+=("$current"); room_med+=($med)
    room_min+=($worst);      room_max+=($best); room_n+=($n)
  fi
  samples=(); current=''; typed=''; mode=idle
}

# ── run ──────────────────────────────────────────────────────────────────

# coproc, not `exec 3< <(...)`: zsh leaves $! at 0 for a process substitution,
# so there would be no pid to kill and quitting would strand the swift process.
coproc swift $SAMPLER $INTERVAL 2>$sampler_err
sampler_pid=$!
exec 3<&p

stty -echo -icanon 2>/dev/null
printf '\e[?1049h\e[?25l\e[H\e[J'

while :; do
  # A dead sampler would otherwise leave a frozen bar looking like a live one.
  if ! kill -0 $sampler_pid 2>/dev/null; then
    sampler_died=1
    exit 1
  fi

  # New sample, if the sampler has one ready.
  if read -r -t 0.02 -u 3 s_rssi s_noise s_tx s_chan s_width s_band s_phy; then
    rssi=$s_rssi noise=$s_noise tx=$s_tx chan=$s_chan
    width=$s_width band=$s_band phy=$s_phy
    [[ $mode == measuring ]] && (( rssi != 0 )) && samples+=($rssi)
  fi

  # Keyboard, character by character — a line-oriented read would freeze the
  # bar while you type, which is exactly when you are walking.
  #
  # -u 0 is not redundant: bare `read -k` opens /dev/tty directly and ignores
  # stdin, which makes the script impossible to drive from a script or a pipe.
  if read -r -t 0.02 -k 1 -u 0 key; then
    case $key in
      $'\n'|$'\r')
        if [[ $mode == idle && -n $typed ]]; then
          current=$typed; samples=(); started=$EPOCHREALTIME; mode=measuring
        fi ;;
      $'\x7f'|$'\b') [[ $mode == idle ]] && typed=${typed%?} ;;
      q|Q)           [[ $mode == idle && -z $typed ]] && exit 0
                     [[ $mode == idle ]] && typed+=$key ;;
      $'\e')         : ;;   # swallow escape sequences rather than typing them
      *)             [[ $mode == idle && $key == [[:print:]] ]] && typed+=$key ;;
    esac
  fi

  [[ $mode == measuring ]] && (( EPOCHREALTIME - started >= WINDOW )) && finish_room

  draw
done
