#!/usr/bin/env sh
# echo-target.sh — Linux echo target for LatencyBench keystroke-echo mode.
#
# Run this in a fullscreen terminal on the target machine. It paints a large
# white digit on a black background and replaces it every time you press a
# digit key. The bench measures how long it takes from `LatencyBench` sending
# the keystroke to the framebuffer rectangle changing pixels.
#
# Requires: a TTY that supports ANSI escape codes (any modern terminal),
# `stty`, `tput`. No external packages.
#
# Hand the `--echo-region x,y,w,h` flag the bounding box of where this paints
# the digit in your KVM viewer's framebuffer coordinates.

set -eu

cleanup() {
  stty "$_old_stty" 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  printf '\033[?1049l'
  exit 0
}

trap cleanup INT TERM HUP

# Enter alt screen, hide cursor, black background, large white text.
printf '\033[?1049h'
tput civis
printf '\033[40m'   # black bg
printf '\033[97m'   # bright white fg

_old_stty=$(stty -g)
stty -icanon -echo min 1 time 0

paint() {
  digit="$1"
  rows=$(tput lines)
  cols=$(tput cols)
  row=$((rows / 2))
  col=$((cols / 2))
  clear
  # A simple but visually-significant block of the digit. Repeat to ensure
  # the watched region picks up a big change.
  block=""
  i=0
  while [ "$i" -lt 6 ]; do
    block="$block$digit$digit$digit$digit$digit$digit$digit$digit\n"
    i=$((i + 1))
  done
  printf '\033[%s;%sH' "$row" "$col"
  printf "%b" "$block"
}

paint "0"

while :; do
  key=$(dd bs=1 count=1 2>/dev/null) || cleanup
  case "$key" in
    0|1|2|3|4|5|6|7|8|9) paint "$key" ;;
    q) cleanup ;;
    *) ;;
  esac
done
