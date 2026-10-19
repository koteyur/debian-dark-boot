#!/bin/sh
# Test only: make an install "by hand", like the steps that the first
# version of this boot splash used, without install.sh and without its
# state file. run-tests.sh then checks that install.sh takes it over and
# that uninstall.sh removes it.
set -eu
S=${1:-/root/ddb}
apt-get update -qq
apt-get install -y -qq plymouth-themes > /dev/null
install -d /boot/grub/themes/debian-dark
install -m 644 "$S"/themes/grub/debian-dark/* /boot/grub/themes/debian-dark/
sed '1s/.*/# Boot splash "debian-dark", installed by hand./' \
  "$S/files/grub-debian-dark.cfg" > /etc/default/grub.d/debian-dark.cfg
sed -i 's/^quiet_boot="0"$/quiet_boot="1"/' /etc/grub.d/10_linux
sed -i '/linux_entry "${OS}" "${version}" simple \\$/{n;s/}"$/} ${GRUB_CMDLINE_LINUX_SPLASH}"/}' \
  /etc/grub.d/10_linux
install -d /usr/share/plymouth/themes/debian-dark
install -m 644 "$S"/themes/plymouth/debian-dark/* /usr/share/plymouth/themes/debian-dark/
printf '%s\n' '# Boot splash "debian-dark", installed by hand.' '[Daemon]' \
  'Theme=debian-dark' 'DeviceScale=1' > /etc/plymouth/plymouthd.conf
grep -v '^# Installed by debian-dark-boot' "$S/files/debian-dark-plymouth" \
  > /etc/initramfs-tools/hooks/debian-dark-plymouth
grep -v '^# Installed by debian-dark-boot' "$S/files/debian-dark-cryptroot" \
  > /etc/initramfs-tools/hooks/debian-dark-cryptroot
chmod 755 /etc/initramfs-tools/hooks/debian-dark-*
echo bochs >> /etc/initramfs-tools/modules
install -d /etc/issue.d
install -m 644 "$S/files/vt-cursor.issue" /etc/issue.d/vt-cursor.issue
update-initramfs -u > /dev/null
update-grub > /dev/null 2>&1
grep -n 'quiet_boot=\|GRUB_CMDLINE_LINUX_SPLASH}' /etc/grub.d/10_linux
echo "manual install done"
