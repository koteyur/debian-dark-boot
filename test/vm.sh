#!/bin/sh
# Full chain test in a QEMU VM: OVMF -> shim -> GRUB -> kernel ->
# Plymouth in the initramfs -> (LUKS prompt) -> systemd.
# Usage:
#   vm.sh image VARIANT          export ddboot-guest-VARIANT to a root fs
#   vm.sh install VARIANT        install Debian on base-VARIANT.raw
#   vm.sh fresh VARIANT          copy base-VARIANT.raw to work-VARIANT.raw
#   vm.sh boot DISK WxH CMDLINE ACTION...   boot DISK and run vmctl.py actions
# VARIANT is luks or plain. Everything runs rootless in the ddboot-tools
# container. Disks and logs go to $SCRATCH/vm.
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
scratch=${SCRATCH:-$HOME/.cache/ddboot-scratch}/vm
mkdir -p "$scratch/shots"
if [ "$1" = image ]; then
  podman rm -f "ddboot-export-$2" > /dev/null 2>&1 || true
  podman create --name "ddboot-export-$2" "localhost/ddboot-guest-$2:latest" /bin/true > /dev/null
  podman export -o "$scratch/rootfs-$2.tar" "ddboot-export-$2"
  podman rm "ddboot-export-$2" > /dev/null
fi
exec podman run --rm --name "ddboot-vm-$1" -e VMGPU \
  --device /dev/kvm --group-add keep-groups \
  -v "$top:/work:ro" -v "$scratch/shots:/shots" -v "$scratch:/scratch" \
  localhost/ddboot-tools:latest sh /work/test/vm-inner.sh "$@"
