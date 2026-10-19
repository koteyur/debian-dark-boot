# install.sh --status: check that every part of the boot splash is in
# place. This file is sourced, not run.

STATUS_FAIL=0

report() {
	local result=$1
	shift
	case $result in
		ok) printf '  %sOK%s      %s\n' "$C_GREEN" "$C_OFF" "$*" ;;
		skip) printf '  %sSKIP%s    %s\n' "$C_YELLOW" "$C_OFF" "$*" ;;
		*)
			printf '  %sMISSING%s %s\n' "$C_RED" "$C_OFF" "$*"
			STATUS_FAIL=1 ;;
	esac
}

check() {
	local text=$1
	shift
	if "$@" > /dev/null 2>&1; then
		report ok "$text"
	else
		report fail "$text"
	fi
}

same_tree() {
	[ -d "$2" ] && diff -rq "$1" "$2"
}

ply_conf_ok() {
	[ "$(ply_conf_get "$PLY_CONF" Theme)" = debian-dark ] &&
		[ "$(ply_conf_get "$PLY_CONF" DeviceScale)" = 1 ]
}

# The modules that install.sh adds on this computer.
status_modules() {
	{ state_all module; echo "$MODULES_ADD" | tr ' ' '\n'; } | sort -u | xargs
}

modules_ok() {
	local mod
	for mod in $(status_modules); do
		[ -z "$(modules_missing "$MODULES_FILE" "$mod")" ] || return 1
	done
}

# The main entry is the first "linux" line of grub.cfg.
grub_cfg_main_splash() {
	awk '$1 == "linux" { print; exit }' "$GRUB_CFG" | grep -q ' splash vt.global_cursor_default=0'
}

grub_cfg_theme() {
	grep -q '^[[:space:]]*set theme=.*/themes/debian-dark/theme.txt' "$GRUB_CFG"
}

status_files() {
	check "GRUB theme in $GRUB_THEME_DIR" same_tree "$HERE/themes/grub/debian-dark" \
		"$GRUB_THEME_DIR"
	check "GRUB settings in $GRUB_DEFAULT_CFG" cmp -s "$HERE/files/grub-debian-dark.cfg" \
		"$GRUB_DEFAULT_CFG"
	check "10_linux: quiet_boot=\"1\" (no \"Loading Linux\" text)" \
		test "$(linux_quiet_boot "$GRUB_LINUX")" = 1
	check "10_linux: splash options on the main entry only" \
		test "$(linux_splash_state "$GRUB_LINUX")" = splash
	check "Plymouth theme in $PLY_THEME_DIR" same_tree "$HERE/themes/plymouth/debian-dark" \
		"$PLY_THEME_DIR"
	check "$PLY_CONF: Theme=debian-dark, DeviceScale=1" ply_conf_ok
	check "initramfs hook $HOOK_PLY" cmp -s "$HERE/files/debian-dark-plymouth" "$HOOK_PLY"
	check "initramfs hook $HOOK_CRYPT" cmp -s "$HERE/files/debian-dark-cryptroot" "$HOOK_CRYPT"
	check "early graphics modules in $MODULES_FILE: $(status_modules)" modules_ok
	check "text console cursor: $ISSUE_FILE" cmp -s "$HERE/files/vt-cursor.issue" "$ISSUE_FILE"
	check "apt warning hook $APT_HOOK" cmp -s "$HERE/files/apt-hook.conf" "$APT_HOOK"
	local pkg
	for pkg in $PACKAGES; do
		check "package $pkg" pkg_installed "$pkg"
	done
}

status_grub_cfg() {
	if [ ! -r "$GRUB_CFG" ]; then
		report skip "$GRUB_CFG is not readable (run as root)"
		return 0
	fi
	check "$GRUB_CFG uses the theme" grub_cfg_theme
	check "$GRUB_CFG: main entry has the splash options" grub_cfg_main_splash
}

# Check the initramfs of a kernel. Without root it can only be listed if
# it is readable.
status_initramfs() {
	local kver=$1 img=/boot/initrd.img-$1 dir list
	if [ ! -r "$img" ]; then
		report skip "initramfs $img is not readable (run as root)"
		return 0
	fi
	list=$(lsinitramfs "$img" 2> /dev/null)
	check "initramfs $kver has the Plymouth theme" \
		grep -q 'usr/share/plymouth/themes/debian-dark/debian-dark.plymouth' <<< "$list"
	local mod
	for mod in $(status_modules); do
		check "initramfs $kver has module $mod" grep -Eq "/${mod//_/[_-]}\.ko" <<< "$list"
	done
	dir=$(mktemp -d)
	if unmkinitramfs "$img" "$dir" > /dev/null 2>&1; then
		check "initramfs $kver has the grey logo (not the Debian one)" \
			cmp -s "$PLY_THEME_DIR/watermark.png" \
			"$(find "$dir" -path '*themes/debian-dark/watermark.png' | head -n 1)"
		status_cryptroot "$kver" "$dir"
	fi
	rm -rf "$dir"
}

status_cryptroot() {
	local kver=$1 dir=$2 script
	[ "$LUKS" = yes ] || return 0
	script=$(find "$dir" -path '*scripts/local-top/cryptroot' | head -n 1)
	if [ -z "$script" ]; then
		report fail "initramfs $kver has no cryptroot script"
		return 0
	fi
	check "initramfs $kver: cryptroot message changed for the splash" \
		grep -q 'grep -qw splash /proc/cmdline' "$script"
}

run_status() {
	heading "debian-dark-boot status"
	if [ -f "$STATE_FILE" ]; then
		say "  Installed by install.sh $(state_get version) on $(state_get installed)."
	else
		say "  Not installed by install.sh (no $STATE_FILE)."
	fi
	detect_luks
	detect_modules "$(newest_kernel)"
	say "  Disk encryption (LUKS): $LUKS"
	status_files
	status_grub_cfg
	status_initramfs "$(newest_kernel)"
	say ""
	if [ "$STATUS_FAIL" = 0 ]; then
		say "Everything is in place."
		return 0
	fi
	say "Some parts are missing. Run install.sh again to put them back."
	if [ "$(linux_splash_state "$GRUB_LINUX")" = stock ]; then
		say "An upgrade of grub-common has probably replaced $GRUB_LINUX."
	fi
	return 1
}
