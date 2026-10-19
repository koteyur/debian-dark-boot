#!/bin/sh
# Make ../screenshots/compare-old-new-1920x1200.png: the first design
# (scale 1) on the left, this one on the right. Top: GRUB. Bottom: the
# Plymouth password prompt.
# Usage: side-by-side.sh OLD-PROMPT.png
# OLD-PROMPT.png is a 1920x1200 screenshot of the old prompt. The old GRUB
# shot comes from "grub-qemu.sh old".
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$HOME/.cache/ddboot-scratch}
cp "$1" "$scratch/old-prompt.png"
podman run --rm --name ddboot-sheet -v "$top/screenshots:/s" -v "$scratch:/x:ro" \
  localhost/ddboot-tools:latest montage \
  -label 'First design: GRUB' /s/grub/old-menu6-1920x1200.png \
  -label 'Now: GRUB' /s/grub/menu6-1920x1200.png \
  -label 'First design: password' /x/old-prompt.png \
  -label 'Now: password' /s/vm/luks-1920x1200-prompt.png \
  -tile 2x -geometry 960x600+6+6 -background '#303030' -fill white -pointsize 18 \
  /s/compare-old-new-1920x1200.png
echo "saved screenshots/compare-old-new-1920x1200.png"
