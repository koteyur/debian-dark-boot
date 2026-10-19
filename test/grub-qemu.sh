#!/bin/sh
# Boot a standalone GRUB with the debian-dark theme in QEMU + OVMF and take
# screenshots of the menu. Runs rootless in the ddboot-tools container.
# Usage: grub-qemu.sh MODE        (see the end of grub-qemu-inner.sh)
# Output: ../screenshots/grub/*.png
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$HOME/.cache/ddboot-scratch}/grub-test
mkdir -p "$scratch"
exec podman run --rm --name ddboot-grubtest \
  --device /dev/kvm --group-add keep-groups \
  -v "$top:/work" -v "$scratch:/scratch" \
  localhost/ddboot-tools:latest sh /work/test/grub-qemu-inner.sh "$@"
