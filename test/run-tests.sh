#!/bin/sh
# Full test of install.sh and uninstall.sh in a fresh Debian trixie VM.
# Usage: run-tests.sh VARIANT [PART...]
#   VARIANT  luks or plain (see Containerfile.guest)
#   PART     install shots advanced upgrade uninstall after adopt s1366
#            (default: all but adopt and s1366)
# Needs the images and base disks: see README.md in this directory.
# The serial output goes to ../screenshots/vm/test-VARIANT.log. Screenshots
# go to $SCRATCH/vm/shots, and the chosen ones to ../screenshots/vm.
set -eu
cd "$(dirname "$0")"
V=$1
shift
PARTS=${*:-install shots advanced upgrade uninstall after}
SCRATCH=${SCRATCH:-$HOME/.cache/ddboot-scratch}
SHOTS=$SCRATCH/vm/shots
OUT=../screenshots/vm
LOG=${LOG:-$OUT/test-$V.log}
DISK=work-$V.raw
R=1920x1200
mkdir -p "$OUT"

# The center of the first menu entry (the GRUB selection bar) and of the
# Plymouth password box, as offsets from the screen center, and the place
# of the spinner.
. ./layout.env

log() {
  echo "=== $*" | tee -a "$LOG"
}

vm() {
  ./vm.sh boot "$DISK" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' |
    grep -v -e '^saved ' -e '^debugfs ' >> "$LOG" || true
}

# Actions to get from the power-on to a root shell on the serial port.
# $1 = WxH, $2 = prefix for screenshots, $3 = real row width of skewed
# screenshots (optional).
to_shell() {
  w=${1%x*}; h=${1#*x}; row=${3:+:$3}
  x=$((w / 2)); y=$((h / 2 + ITEM_CENTER)); yb=$((h / 2 + BOX_CENTER))
  echo "waitpixel=$x:$y:262626:90:$2-grub$row key=ret burst=$2-boot:9:0.4"
  if [ "$V" = luks ]; then
    echo "waitpixel=$x:$yb:1c1c1c:90:$2-prompt$row type=wrong key=ret wait=6 shot=$2-wrong"
    echo "waitpixel=$x:$yb:1c1c1c:30:$2-prompt2$row type=tes key=caps_lock wait=0.5"
    echo "shot=$2-typing key=caps_lock"
    echo "key=esc wait=1.5 shot=$2-esc key=esc wait=1.5 type=t key=ret"
    echo "burst=$2-unlocked:4:0.5"
  fi
  echo "login"
}

prep="run=mount -o ro /dev/vdb /mnt && rm -rf /root/ddb && cp -a /mnt /root/ddb && umount /mnt"
info="run=cat /proc/cmdline; cat /sys/class/graphics/fb0/name; journalctl -b -o cat |"
info="$info grep -i -E 'plymouth|bochs|virtio_gpu|fbcon' | head -20"

part_install() {
  log "$V: fresh system, snapshot, install.sh twice, --status"
  ./vm.sh fresh "$V"
  unlock=""
  [ "$V" = luks ] && unlock="wait=22 type=test key=ret"
  # The builder made the first initramfs in a chroot, where console-setup
  # puts a keymap with a temporary name into it. Build it again once, as on
  # a normal system, so that the compare at the end is clean.
  vm $R "" wait=4 shot="$V-stock-grub" $unlock login "$prep" \
    "runt=600:update-initramfs -u" \
    "runt=600:sh /root/ddb/test/snapshot.sh pre" \
    "run=cp /etc/grub.d/10_linux /root/10_linux.before" \
    "runt=1800:/root/ddb/install.sh --yes; echo install-exit=\$?" \
    "runt=900:/root/ddb/install.sh --yes; echo install2-exit=\$?" \
    "runt=300:/root/ddb/install.sh --status; echo status-exit=\$?" \
    "run=cat /var/lib/debian-dark-boot/state; ls /var/backups/debian-dark-boot" \
    "send=poweroff" wait=10
}

part_shots() {
  for res in ${RESOLUTIONS:-1920x1200 1920x1080 1360x768 1280x800 2560x1440 3840x2160}; do
    log "$V: boot at $res"
    # shellcheck disable=SC2046
    vm "$res" "" $(to_shell "$res" "$V-$res") "$info" "send=poweroff" wait=10
    pick "$V-$res"
  done
  return 0
}

# Not part of the default run: in a 1366x768 VM with virtio-gpu, QEMU saves
# the Plymouth screens skewed, and unskew.py cannot fix them. The GRUB menu
# at 1366x768 is in grub-qemu.sh. The Plymouth layout at 1360x768 differs
# only by 3 pixels to the side.
part_s1366() {
  if [ "$V" = luks ]; then
    log "$V: boot at 1366x768 (virtio-vga, the screenshots are fixed with unskew.py)"
    rm -f "$SHOTS/$V-1366x768"-*.png
    # shellcheck disable=SC2046
    VMGPU="-device virtio-vga,edid=on,xres=1366,yres=768" \
      vm 1366x768 "" $(to_shell 1366x768 "$V-1366x768" 1366) "$info" "send=poweroff" wait=10
    unskew "$V-1366x768"
    pick "$V-1366x768"
  fi
}

# Run a tool from this folder in the tools container, with the shots.
tool() {
  podman run --rm --name "ddboot-tool-$V" -v "$PWD/..:/work:ro" -v "$SHOTS:/shots" \
    localhost/ddboot-tools:latest "$@"
}

unskew() {
  for f in "$SHOTS/$1"-*.png; do
    tool python3 -I /work/test/unskew.py "/shots/${f##*/}" "/shots/${f##*/}" 1366
  done
}

# Choose the splash frame, check the logo and copy the shots to OUT.
pick() {
  tool python3 -I /work/test/check-shots.py /shots /work/themes "$1" "$BOX_CENTER" \
    "$SPIN_OFFSET" |
    tee -a "$LOG"
  for kind in grub splash prompt wrong typing esc unlocked; do
    [ -f "$SHOTS/$1-$kind.png" ] && cp "$SHOTS/$1-$kind.png" "$OUT/"
  done
  return 0
}

part_advanced() {
  log "$V: Advanced options, first kernel entry (stock boot, no splash)"
  unlock=""
  [ "$V" = luks ] && unlock="wait=14 shot=$V-advanced-boot type=test key=ret"
  vm $R "" wait=3 key=down key=ret wait=1 shot="$V-advanced-menu" key=ret \
    $unlock login "run=cat /proc/cmdline" "send=poweroff" wait=10
  cp "$SHOTS/$V-advanced-menu.png" "$OUT/"
  [ -f "$SHOTS/$V-advanced-boot.png" ] && cp "$SHOTS/$V-advanced-boot.png" "$OUT/"
  return 0
}

part_upgrade() {
  log "$V: grub-common upgrade replaces 10_linux, --status, install.sh again"
  apt_opts="-o Dpkg::Options::=--force-confask -o Dpkg::Options::=--force-confnew"
  # shellcheck disable=SC2046
  vm $R "" $(to_shell $R "$V-upgrade") "$prep" \
    "runt=600:apt-get install -y --reinstall $apt_opts /root/debs/grub-common_*.deb" \
    "run=ls /etc/grub.d/; rm -f /etc/grub.d/10_linux.dpkg-old" \
    "run=grep -n 'quiet_boot=\\|GRUB_CMDLINE_LINUX_DEFAULT}\"' /etc/grub.d/10_linux" \
    "runt=300:/root/ddb/install.sh --status; echo status-exit=\$?" \
    "runt=900:/root/ddb/install.sh --yes; echo install-exit=\$?" \
    "runt=300:/root/ddb/install.sh --status; echo status-exit=\$?" \
    "send=poweroff" wait=10
}

part_uninstall() {
  log "$V: uninstall.sh, snapshot, compare with the snapshot before install"
  # shellcheck disable=SC2046
  vm $R "" $(to_shell $R "$V-uninstall") "$prep" \
    "runt=1200:/root/ddb/uninstall.sh --yes; echo uninstall-exit=\$?" \
    "runt=600:sh /root/ddb/test/snapshot.sh post" \
    "runt=60:cd /root && diff -r snap-pre snap-post; echo diff-exit=\$?; cd /" \
    "run=cmp /root/10_linux.before /etc/grub.d/10_linux && echo 10_linux-same" \
    "run=/root/ddb/uninstall.sh --yes; echo uninstall2-exit=\$?" \
    "send=poweroff" wait=10
}

part_after() {
  log "$V: boot after uninstall"
  unlock=""
  [ "$V" = luks ] && unlock="wait=20 shot=$V-after-uninstall-prompt type=test key=ret"
  vm $R "" wait=4 shot="$V-after-uninstall-grub" $unlock login "run=cat /proc/cmdline" \
    "send=poweroff" wait=10
  cp "$SHOTS/$V-after-uninstall-grub.png" "$OUT/"
}

part_adopt() {
  log "$V: install by hand, install.sh takes it over, uninstall.sh removes it"
  ./vm.sh fresh "$V"
  # shellcheck disable=SC2046
  vm $R "" wait=4 $( [ "$V" = luks ] && echo "wait=22 type=test key=ret" ) login "$prep" \
    "runt=600:update-initramfs -u" "runt=600:sh /root/ddb/test/snapshot.sh pre" \
    "runt=900:sh /root/ddb/test/manual-install.sh; echo manual-exit=\$?" \
    "runt=1800:/root/ddb/install.sh --yes; echo install-exit=\$?" \
    "runt=300:/root/ddb/install.sh --status; echo status-exit=\$?" \
    "run=cat /var/lib/debian-dark-boot/state" \
    "runt=1200:/root/ddb/uninstall.sh --yes; echo uninstall-exit=\$?" \
    "runt=600:sh /root/ddb/test/snapshot.sh post" \
    "runt=60:cd /root && diff -r snap-pre snap-post; echo diff-exit=\$?; cd /" \
    "send=poweroff" wait=10
}

for part in $PARTS; do
  "part_$part"
done
