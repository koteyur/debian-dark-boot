#!/bin/sh
# Runs inside the ddboot-tools container. See grub-qemu.sh.
set -eu
W=/work
S=/scratch
SHOTS=$W/screenshots/grub
THEME=${THEME:-$W/themes/grub/debian-dark}
mkdir -p "$SHOTS"

mon() {
  printf '%s\n' "$1" | socat - "UNIX-CONNECT:$S/mon.sock" > /dev/null
}

shot() {
  mon "screendump $S/shot.ppm"
  sleep 0.5
  convert "$S/shot.ppm" "$SHOTS/$1.png"
  echo "saved grub/$1.png"
}

# $1 = file with menu entries
make_cfg() {
  cat <<CFG
insmod part_gpt
insmod fat
insmod all_video
insmod gfxterm
insmod gfxmenu
insmod png
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm
CFG
  for f in "$THEME"/*.pf2; do
    echo "loadfont \$prefix/themes/debian-dark/$(basename "$f")"
  done
  cat <<CFG
set theme=\$prefix/themes/debian-dark/theme.txt
export theme
set timeout_style=menu
set timeout=${TIMEOUT:-30}
CFG
  cat "$1"
}

# A menu like on a computer with Windows and memtest86+: 6 entries.
cat > "$S/entries6.cfg" <<'CFG'
menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class os {
	echo 'Loading Linux 6.12.113+deb13-amd64 ...'
	sleep 2
	echo 'Loading initial ramdisk ...'
	sleep 30
}
submenu 'Advanced options for Debian GNU/Linux' {
	menuentry 'Debian GNU/Linux, with Linux 6.12.113+deb13-amd64' { true; }
	menuentry 'Debian GNU/Linux, with Linux 6.12.113+deb13-amd64 (recovery mode)' { true; }
	menuentry 'Debian GNU/Linux, with Linux 6.12.107+deb13-amd64' { true; }
	menuentry 'Debian GNU/Linux, with Linux 6.12.107+deb13-amd64 (recovery mode)' { true; }
}
menuentry 'Windows Boot Manager (on /dev/nvme0n1p1)' --class windows --class os { true; }
menuentry 'Memory test (memtest86+x64.efi)' { true; }
menuentry 'Memory test (memtest86+x64.efi, serial console)' { true; }
menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' { fwsetup; }
CFG
# A plain Debian install: 3 entries.
sed -n '1,12p;$p' "$S/entries6.cfg" > "$S/entries3.cfg"

# $1 = WxH of the display, $2 = entries file, then actions.
# OVMF always starts in 800x600, so the test sets the GRUB mode to the
# size of the virtual screen. On real hardware the theme uses
# GRUB_GFXMODE=auto, which keeps the mode of the firmware.
run_vm() {
  res=$1; entries=$2; shift 2
  rm -rf "$S/esp"; mkdir -p "$S/esp/EFI/BOOT"
  make_cfg "$entries" | sed "s/^set gfxmode=auto/set gfxmode=$res/" > "$S/grub.cfg"
  args="boot/grub/grub.cfg=$S/grub.cfg"
  for f in "$THEME"/*; do
    args="$args boot/grub/themes/debian-dark/$(basename "$f")=$f"
  done
  # shellcheck disable=SC2086
  grub-mkstandalone -O x86_64-efi -o "$S/esp/EFI/BOOT/BOOTX64.EFI" $args
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$S/vars.fd"
  rm -f "$S/mon.sock"
  qemu-system-x86_64 -enable-kvm -m 512 -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$S/vars.fd" \
    -drive file=fat:rw:"$S/esp",format=raw,if=virtio \
    -device ${GPU:-VGA,vgamem_mb=128},edid=on,xres=${res%x*},yres=${res#*x} \
    -display none -monitor unix:"$S/mon.sock",server,nowait \
    -net none &
  qpid=$!
  sleep 1
  for action in "$@"; do
    case $action in
      wait=*) sleep "${action#wait=}" ;;
      key=*) mon "sendkey ${action#key=}"; sleep 0.3 ;;
      shot=*) shot "${action#shot=}" ;;
    esac
  done
  mon quit || true
  timeout 20 tail --pid=$qpid -f /dev/null || kill $qpid
}

case "${1:-all}" in
fonts)
  rm -rf "$S/fontcmp"
  python3 -I "$W/test/grub-font-compare.py" "$S/fontcmp"
  THEME=$S/fontcmp run_vm 1920x1200 "$S/entries3.cfg" wait=6 shot=fonts-1920x1200
  ;;
sizes)
  # The QEMU VGA needs a width that is a multiple of 8, so 1360x768 too.
  for res in 1360x768 1280x800 1920x1080 1920x1200 2560x1440 3840x2160; do
    run_vm "$res" "$S/entries6.cfg" wait=6 shot="menu6-$res"
  done
  # A real 1366x768 screen. virtio-vga can set this mode, but QEMU saves
  # the screenshot skewed. unskew.py fixes it (the last 4 rows are lost).
  GPU=virtio-vga run_vm 1366x768 "$S/entries6.cfg" wait=6 shot=menu6-1366x768
  python3 -I "$W/test/unskew.py" "$SHOTS/menu6-1366x768.png" "$SHOTS/menu6-1366x768.png" 1366
  for res in 1360x768 1920x1200; do
    run_vm "$res" "$S/entries3.cfg" wait=6 shot="menu3-$res"
  done
  ;;
detail)
  for res in 1280x800 1920x1200; do
    run_vm "$res" "$S/entries6.cfg" wait=6 key=down key=ret wait=1 key=down shot="advanced-$res"
  done
  for res in 1360x768 1920x1200; do
    run_vm "$res" "$S/entries6.cfg" wait=6 key=e wait=1 shot="edit-$res" \
      key=esc wait=1 key=c wait=1 shot="console-$res"
  done
  TIMEOUT=8 run_vm 1920x1200 "$S/entries3.cfg" wait=5 shot=countdown-1920x1200
  for res in 1360x768 1920x1080 1920x1200; do
    run_vm "$res" "$S/entries3.cfg" wait=6 key=ret wait=1 shot="after-select-$res"
  done
  ;;
old)
  # The first design (scale 1), copied by hand to $S/old-theme.
  THEME=$S/old-theme run_vm 1920x1200 "$S/entries6.cfg" wait=6 shot=old-menu6-1920x1200
  ;;
esac
