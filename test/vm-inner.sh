#!/bin/sh
# Runs inside the ddboot-tools container. See vm.sh.
set -eu
S=/scratch
W=/work
OVMF=/usr/share/OVMF

rootfs_image() {
  rm -rf "$S/rootfs-$1" && mkdir "$S/rootfs-$1"
  tar -C "$S/rootfs-$1" -xf "$S/rootfs-$1.tar"
  rm -f "$S/rootfs-$1.tar"
}

builder() {
  variant=$1
  r=$S/rootfs-$variant
  cp "$W/test/vm-setup-target.sh" "$r/sbin/init.bs"
  chmod +x "$r/sbin/init.bs"
  rm -f "$S/builder.img"
  mkfs.ext4 -q -d "$r" "$S/builder.img" 3G
  rm -f "$r/sbin/init.bs"
  k=$(ls "$r"/boot/vmlinuz-* | tail -1)
  i=$(ls "$r"/boot/initrd.img-* | tail -1)
  rm -f "$S/base-$variant.raw"
  truncate -s 6G "$S/base-$variant.raw"
  timeout 900 qemu-system-x86_64 -enable-kvm -m 2048 -smp 4 -machine q35 \
    -kernel "$k" -initrd "$i" \
    -append "root=/dev/vdb rw init=/sbin/init.bs bsvariant=$variant console=ttyS0 quiet" \
    -drive file="$S/base-$variant.raw",format=raw,if=virtio \
    -drive file="$S/builder.img",format=raw,if=virtio \
    -display none -serial file:"$S/builder-$variant.log" -no-reboot -net none
  rm -f "$S/builder.img"
  tail -5 "$S/builder-$variant.log"
  grep -q BSDONE "$S/builder-$variant.log"
}

# Write grubenv on the /boot partition (number 2) of a raw disk. The
# partition is copied out and checked first, so that an ext4 journal
# left by an unclean stop is replayed before debugfs writes to it.
set_grubenv() {
  disk=$1; mode=$2; cmdline=$3
  start=$(partx -g -o START -n 2 "$disk" | tr -d ' ')
  sectors=$(partx -g -o SECTORS -n 2 "$disk" | tr -d ' ')
  part=$S/bootpart.img
  dd if="$disk" of="$part" bs=512 skip="$start" count="$sectors" status=none
  e2fsck -fy "$part" > /dev/null 2>&1 || true
  env=$S/grubenv
  rm -f "$env"
  grub-editenv "$env" create
  grub-editenv "$env" set "vmtest_gfxmode=$mode" "vmtest_cmdline=$cmdline"
  debugfs -w -R "rm grub/grubenv" "$part" > /dev/null 2>&1 || true
  debugfs -w -R "write $env grub/grubenv" "$part" > /dev/null 2>&1
  dd if="$part" of="$disk" bs=512 seek="$start" conv=notrunc status=none
  rm -f "$part"
}

# A small disk with this repository, for the guest to copy from.
repo_disk() {
  rm -rf "$S/repo" "$S/repo.img"
  mkdir "$S/repo"
  tar -C "$W" --exclude=./.git --exclude=./screenshots -cf - . | tar -C "$S/repo" -xf -
  mkfs.ext4 -q -d "$S/repo" "$S/repo.img" 64M
  rm -rf "$S/repo"
}

boot() {
  disk=$S/$1; res=$2; cmdline=$3; shift 3
  set_grubenv "$disk" "$res" "$cmdline"
  repo_disk
  cp "$OVMF/OVMF_VARS_4M.fd" "$S/vars.fd"
  rm -f "$S/mon.sock" "$S/ser.sock"
  qemu-system-x86_64 -enable-kvm -m 2048 -smp 4 -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF/OVMF_CODE_4M.fd" \
    -drive if=pflash,format=raw,file="$S/vars.fd" \
    -drive file="$disk",format=raw,if=virtio \
    -drive file="$S/repo.img",format=raw,if=virtio,readonly=on \
    ${VMGPU:--device VGA,vgamem_mb=128,edid=on,xres=${res%x*},yres=${res#*x}} \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -monitor unix:"$S/mon.sock",server,nowait \
    -serial unix:"$S/ser.sock",server,nowait &
  qpid=$!
  sleep 0.5
  python3 -I "$W/test/vmctl.py" "$S" /shots "$@" || echo "vmctl failed"
  printf 'quit\n' | socat - "UNIX-CONNECT:$S/mon.sock" > /dev/null 2>&1 || true
  timeout 30 tail --pid=$qpid -f /dev/null || kill $qpid
}

cmd=$1; shift
case $cmd in
  image) rootfs_image "$1" ;;
  install) builder "$1" ;;
  fresh) cp --sparse=always "$S/base-$1.raw" "$S/work-$1.raw" ;;
  boot) boot "$@" ;;
esac
