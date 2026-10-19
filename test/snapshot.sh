#!/bin/sh
# Save what install.sh and uninstall.sh can change, to compare the system
# before install.sh with the system after uninstall.sh.
# Usage (in the test VM): snapshot.sh NAME    writes /root/snap-NAME
set -eu
out=/root/snap-$1
rm -rf "$out"
mkdir -p "$out/initramfs"
# All of /etc: type, mode, owner, link target, and a checksum of each file.
find /etc -xdev -printf '%y %m %u:%g %p %l\n' | sort > "$out/etc-list"
find /etc -xdev -type f -print0 | sort -z | xargs -0 sha256sum > "$out/etc-sha256"
cp /boot/grub/grub.cfg "$out/grub.cfg"
find /boot/grub/themes /usr/share/plymouth/themes -maxdepth 1 -printf '%y %m %u %p\n' \
  2> /dev/null | sort > "$out/theme-dirs" || true
dpkg-query -W -f='${Package}:${Architecture} ${Version} ${Status}\n' | sort > "$out/packages"
for img in /boot/initrd.img-*; do
  kver=${img#/boot/initrd.img-}
  lsinitramfs "$img" | sort > "$out/initramfs/$kver.files"
  grep '\.ko' "$out/initramfs/$kver.files" > "$out/initramfs/$kver.modules" || true
  dir=$(mktemp -d)
  unmkinitramfs "$img" "$dir"
  find "$dir" -path '*/conf/modules' -exec cat {} \; > "$out/initramfs/$kver.conf-modules"
  rm -rf "$dir"
done
ls -d /var/lib/debian-dark-boot > "$out/state-dir" 2>&1 || true
echo "snapshot $out done"
