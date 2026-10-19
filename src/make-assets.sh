#!/bin/sh
# Make the GRUB and Plymouth themes into ../themes.
# Runs rootless in the ddboot-tools container (test/Containerfile.tools).
# Usage: make-assets.sh [--scale S] [--menu-font PX] [--term-font PX]
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
podman run --rm --name ddboot-assets -v "$top:/work" \
  localhost/ddboot-tools:latest \
  python3 -I /work/src/make-assets.py /work/themes "$@"
