# Detection of the graphics drivers and of disk encryption.
# This file is sourced, not run. SYSFS can point to a fake tree for tests.

# Graphics drivers to load early in the initramfs.
# MODULES_ADD gets the modules to add, in load order. Privacy screen
# providers come first, because a GPU driver waits for them.
# MODULES_NOTES gets one line for each card or module that is left out.
detect_modules() {
	local kver=$1 card mod drv p
	MODULES_ADD="" MODULES_NOTES=""
	for p in "$SYSFS"/class/drm/privacy_screen-*; do
		[ -e "$p" ] || continue
		mod=$(link_name "$p/device/driver/module")
		[ -n "$mod" ] || mod=${p##*/privacy_screen-}
		add_module "$kver" "$mod" "privacy screen ${p##*/privacy_screen-}"
	done
	for card in "$SYSFS"/class/drm/card[0-9]*; do
		case ${card##*/} in *-*) continue ;; esac
		mod=$(link_name "$card/device/driver/module")
		drv=$(link_name "$card/device/driver")
		check_card "$kver" "$card" "$mod" "$drv"
	done
}

check_card() {
	local kver=$1 card=$2 mod=$3 drv=$4 name=${2##*/}
	case "$mod $drv" in
		*nvidia*)
			note_module "$name ($drv): the NVIDIA driver is not added." \
				"Plymouth may start late or use the firmware frame buffer."
			return 0 ;;
	esac
	if [ -z "$mod" ]; then
		note_module "$name (${drv:-no driver}): built into the kernel, nothing to add."
		return 0
	fi
	if ! card_has_screen "$card"; then
		note_module "$name ($mod): no screen connected, not added."
		return 0
	fi
	add_module "$kver" "$mod" "$name"
}

card_has_screen() {
	local c
	for c in "$1"/"${1##*/}"-*; do
		[ "$(cat "$c/status" 2> /dev/null)" = connected ] && return 0
	done
	return 1
}

add_module() {
	local kver=$1 mod=$2 what=$3 file
	case " $MODULES_ADD " in *" $mod "*) return 0 ;; esac
	file=$(module_file "$kver" "$mod")
	if [ -z "$file" ]; then
		note_module "$what: module $mod not found for kernel $kver, not added."
		return 0
	fi
	if [ "$file" = "(builtin)" ]; then
		note_module "$what: $mod is built into kernel $kver, nothing to add."
		return 0
	fi
	MODULES_ADD="${MODULES_ADD:+$MODULES_ADD }$mod"
}

# Print the file of a kernel module, "(builtin)", or nothing.
module_file() {
	modinfo -k "$1" -F filename "$2" 2> /dev/null | head -n 1 || true
}

note_module() {
	MODULES_NOTES="${MODULES_NOTES}$*
"
}

link_name() {
	local target
	target=$(readlink -f "$1" 2> /dev/null) || return 0
	[ -e "$target" ] || return 0
	basename "$target"
}

# Disk encryption: LUKS is "yes" when crypttab has an entry and the
# initramfs can unlock it.
detect_luks() {
	LUKS=no
	LUKS_NAMES=""
	if [ -r /etc/crypttab ]; then
		LUKS_NAMES=$(awk '!/^[[:space:]]*(#|$)/ { printf "%s ", $1 }' /etc/crypttab)
		LUKS_NAMES=${LUKS_NAMES% }
	fi
	if [ -n "$LUKS_NAMES" ] && pkg_installed cryptsetup-initramfs; then
		LUKS=yes
	fi
}

# With LUKS, the password is typed in the initramfs. Without KEYMAP=y the
# initramfs has only the US layout, but Plymouth shows the layout of
# /etc/default/keyboard.
keymap_warning() {
	local layout keymap
	[ "$LUKS" = yes ] || return 0
	layout=$(sed -n 's/^XKBLAYOUT="*\([^",]*\).*/\1/p' /etc/default/keyboard 2> /dev/null)
	[ -n "$layout" ] && [ "$layout" != us ] || return 0
	keymap=$(cat /etc/initramfs-tools/initramfs.conf /etc/initramfs-tools/conf.d/* 2> /dev/null |
		sed -n 's/^KEYMAP=//p' | tail -n 1)
	case $keymap in y | Y) return 0 ;; esac
	warn "The keyboard layout is \"$layout\", but the initramfs has only the US layout" \
		"(KEYMAP=y is not set in /etc/initramfs-tools/initramfs.conf). The disk password" \
		"is typed with the US layout, while Plymouth shows \"$layout\"."
}
