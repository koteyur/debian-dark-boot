#!/bin/sh
# Init script of the builder VM. It runs as PID 1 from a plain ext4 root
# (/dev/vdb, a copy of a ddboot-guest image) and installs Debian on the
# test disk /dev/vda, like the Debian installer would:
#   luks:  ESP, ext4 /boot, LUKS2 with LVM (root and swap)
#   plain: ESP, ext4 /boot, ext4 root, no encryption
# The variant comes from the kernel command line (bsvariant=...).
set -eux
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts /run
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run
mount -o remount,rw /
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger
udevadm settle

PASS=test
VARIANT=$(sed -n 's/.*bsvariant=\([a-z]*\).*/\1/p' /proc/cmdline)

partition() {
  sfdisk /dev/vda <<PART
label: gpt
size=100M, type=uefi
size=512M, type=linux
type=linux
PART
  udevadm settle
  mkfs.vfat -F 32 /dev/vda1
  mkfs.ext4 -q -F /dev/vda2
}

make_root_luks() {
  printf %s "$PASS" | cryptsetup luksFormat -q --type luks2 \
    --pbkdf argon2id --pbkdf-memory 65536 --iter-time 500 /dev/vda3 --key-file -
  printf %s "$PASS" | cryptsetup open /dev/vda3 vda3_crypt --key-file -
  pvcreate /dev/mapper/vda3_crypt
  vgcreate vg_debian /dev/mapper/vda3_crypt
  lvcreate -q -L 256M -n swap vg_debian
  lvcreate -q -l 100%FREE -n root vg_debian
  mkswap /dev/vg_debian/swap
  mkfs.ext4 -q /dev/vg_debian/root
  mount /dev/vg_debian/root /mnt
  ROOTDEV=/dev/mapper/vg_debian-root
}

make_root_plain() {
  mkfs.ext4 -q -F /dev/vda3
  mount /dev/vda3 /mnt
  ROOTDEV=UUID=$(blkid -s UUID -o value /dev/vda3)
}

copy_system() {
  cp -ax / /mnt/
  rm -f /mnt/sbin/init.bs
  rm -rf /mnt/boot && mkdir /mnt/boot
  mount /dev/vda2 /mnt/boot
  cp -a /boot/. /mnt/boot/
  mkdir -p /mnt/boot/efi
  mount /dev/vda1 /mnt/boot/efi
  for d in dev dev/pts proc sys run; do mount --bind /$d /mnt/$d; done
}

write_fstab() {
  boot=$(blkid -s UUID -o value /dev/vda2)
  efi=$(blkid -s UUID -o value /dev/vda1)
  {
    echo "$ROOTDEV / ext4 errors=remount-ro 0 1"
    echo "UUID=$boot /boot ext4 defaults 0 2"
    echo "UUID=$efi /boot/efi vfat umask=0077 0 1"
  } > /mnt/etc/fstab
  if [ "$VARIANT" = luks ]; then
    echo "/dev/mapper/vg_debian-swap none swap sw 0 0" >> /mnt/etc/fstab
    luks=$(blkid -s UUID -o value /dev/vda3)
    echo "vda3_crypt UUID=$luks none luks,discard,x-initrd.attach" > /mnt/etc/crypttab
    echo "RESUME=/dev/mapper/vg_debian-swap" > /mnt/etc/initramfs-tools/conf.d/resume
  fi
}

# Test only: root login on the serial port drives the tests, the network
# lets install.sh run apt-get, and grubenv sets the GRUB video mode and
# extra kernel options for one boot (OVMF always starts in 800x600). The
# kernel command line has no console=ttyS0, so Plymouth does not see the
# serial port.
test_setup() {
  echo ddtest > /mnt/etc/hostname
  printf '127.0.0.1 localhost\n127.0.1.1 ddtest\n' > /mnt/etc/hosts
  : > /mnt/etc/machine-id
  chroot /mnt sh -c 'echo root:test | chpasswd'
  chroot /mnt systemctl enable serial-getty@ttyS0.service
  printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' > /mnt/etc/systemd/network/10-vm.network
  chroot /mnt systemctl enable systemd-networkd.service
  echo "nameserver 10.0.2.3" > /mnt/etc/resolv.conf
  mkdir -p /mnt/etc/default/grub.d
  cat > /mnt/etc/default/grub.d/zz-vmtest.cfg <<'CFG'
GRUB_GFXMODE='${vmtest_gfxmode}'
GRUB_CMDLINE_LINUX='${vmtest_cmdline}'
CFG
}

install_grub() {
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=debian --no-nvram
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=debian --no-nvram --removable
  chroot /mnt update-initramfs -u -k all
  chroot /mnt update-grub
}

close_disk() {
  sync
  for d in run sys proc dev/pts dev; do umount /mnt/$d; done
  umount /mnt/boot/efi /mnt/boot /mnt
  if [ "$VARIANT" = luks ]; then
    vgchange -an vg_debian
    cryptsetup close vda3_crypt
  fi
}

partition
make_root_$VARIANT
copy_system
write_fstab
test_setup
install_grub
close_disk
echo BSDONE
sync
echo o > /proc/sysrq-trigger
sleep 30
