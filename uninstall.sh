#!/bin/bash
# Remove the "debian-dark" boot splash that install.sh installed, and put
# back what it changed. See README.md.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/detect.sh"
. "$HERE/lib/edits.sh"

usage() {
	cat << EOF
Usage: $0 [OPTION]

Remove the debian-dark boot splash and undo every change of install.sh.

  --dry-run         show what would change, and change nothing
  --yes             do not ask for confirmation
  --keep-packages   keep the packages that install.sh installed
  --help            show this help

Run it as root.
EOF
}

OPT_KEEP_PACKAGES=0
STEP="start"
PHASE="checks"
STAGE=""
# One item per line: ACTION TARGET SOURCE. ACTION is remove, restore,
# write or rmdir.
PLAN=""

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
			--dry-run | -n) DRY_RUN=1 ;;
			--yes | -y) ASSUME_YES=1 ;;
			--keep-packages) OPT_KEEP_PACKAGES=1 ;;
			--help | -h) usage; exit 0 ;;
			*) usage >&2; exit 2 ;;
		esac
		shift
	done
}

check_installed() {
	[ -f "$STATE_FILE" ] && return 0
	if [ -e "$GRUB_DEFAULT_CFG" ] || [ -e "$GRUB_THEME_DIR" ] || [ -e "$PLY_THEME_DIR" ]; then
		say "The debian-dark files are there, but install.sh did not install them"
		say "(no $STATE_FILE). Run install.sh once to take them over, then uninstall.sh."
		exit 1
	fi
	say "debian-dark-boot is not installed. Nothing to do."
	exit 0
}

plan_item() {
	PLAN="${PLAN}$1 $2 ${3:--}
"
}

# Files and directories that belong to this package.
plan_own() {
	local path
	for path in $(state_all own); do
		[ -e "$path" ] && plan_item remove "$path"
	done
	return 0
}

# plymouthd.conf: if nobody changed it since install.sh, put the old file
# back as it was. Otherwise only set the two keys back.
plan_ply_conf() {
	local orig sha old_theme old_scale
	[ -e "$PLY_CONF" ] || return 0
	orig=$(state_path_value orig "$PLY_CONF")
	[ -n "$orig" ] || return 0
	if [ "$orig" = keys ]; then
		plan_ply_keys
		return 0
	fi
	sha=$(state_get plysha)
	if [ "$(sha_of "$PLY_CONF")" = "$sha" ]; then
		if [ "$orig" = - ]; then
			plan_item remove "$PLY_CONF"
		elif [ -f "$orig" ]; then
			plan_item restore "$PLY_CONF" "$orig"
		else
			warn "The copy $orig is missing. Only the keys in $PLY_CONF are set back."
			plan_ply_keys
		fi
		return 0
	fi
	warn "$PLY_CONF was changed after the install. Only Theme and DeviceScale are set back."
	plan_ply_keys
}

plan_ply_keys() {
	local old_theme old_scale
	old_theme=$(state_path_value plyold Theme)
	old_scale=$(state_path_value plyold DeviceScale)
	ply_conf_set "$PLY_CONF" "Theme=${old_theme:--}" "DeviceScale=${old_scale:--}" \
		> "$STAGE/plymouthd.conf"
	plan_write "$PLY_CONF" "$STAGE/plymouthd.conf"
}

plan_write() {
	cmp -s "$1" "$2" || plan_item write "$1" "$2"
}

# 10_linux: undo the two edits, and keep any other change in the file.
plan_linux() {
	local quiet=no
	[ -e "$GRUB_LINUX" ] || return 0
	state_has edit10 quiet && quiet=yes
	if state_has edit10 quiet || state_has edit10 splash; then
		linux_revert "$GRUB_LINUX" "$quiet" > "$STAGE/10_linux"
		plan_write "$GRUB_LINUX" "$STAGE/10_linux"
	fi
	return 0
}

plan_modules() {
	local mods
	mods=$(state_all module | xargs)
	[ -e "$MODULES_FILE" ] || return 0
	# shellcheck disable=SC2086
	modules_remove "$MODULES_FILE" $mods > "$STAGE/modules"
	plan_write "$MODULES_FILE" "$STAGE/modules"
}

# Directories that install.sh made, deepest first.
plan_dirs() {
	local dir
	for dir in $(state_all dir | sort -r); do
		[ -d "$dir" ] && plan_item rmdir "$dir"
	done
	return 0
}

make_plan() {
	PLAN=""
	plan_own
	plan_ply_conf
	plan_linux
	plan_modules
	plan_dirs
}

packages_to_remove() {
	[ "$OPT_KEEP_PACKAGES" = 1 ] && return 0
	local pkg
	for pkg in $(state_all package); do
		pkg_installed "${pkg%:*}" && echo "$pkg"
	done
	return 0
}

print_summary() {
	local action target source pkgs
	heading "Changes"
	while read -r action target source; do
		[ -n "$action" ] || continue
		case $action in
			rmdir) say "  remove     $target (if empty)" ;;
			restore) say "  restore    $target (from $source)" ;;
			write) say "  edit       $target" ;;
			*) printf '  %-10s %s\n' "$action" "$target" ;;
		esac
	done <<< "$PLAN"
	pkgs=$(packages_to_remove | xargs)
	[ -n "$pkgs" ] && say "  purge packages that install.sh installed: $pkgs"
	say "  Then rebuild the initramfs and $GRUB_CFG, and remove $STATE_DIR."
	if [ "$DRY_RUN" = 1 ]; then
		print_diffs
	fi
}

print_diffs() {
	local action target source
	while read -r action target source; do
		case $action in
			write | restore)
				say ""
				diff -u --label "$target" --label "$target (new)" "$target" "$source" ||
					true ;;
		esac
	done <<< "$PLAN"
}

apply_plan() {
	local action target source
	while read -r action target source; do
		[ -n "$action" ] || continue
		STEP="$action $target"
		say "  $action $target"
		case $action in
			remove)
				backup_path "$target" remove
				rm -rf "$target" ;;
			restore | write)
				backup_path "$target" "$action"
				cp -p "$target" "$target.debian-dark-new"
				cat "$source" > "$target.debian-dark-new"
				mv "$target.debian-dark-new" "$target" ;;
			rmdir)
				rmdir "$target" 2> /dev/null || say "    (not empty, kept)" ;;
		esac
	done <<< "$PLAN"
}

purge_packages() {
	local pkgs
	pkgs=$(packages_to_remove | xargs)
	[ -n "$pkgs" ] || return 0
	STEP="apt-get purge $pkgs"
	heading "Removing packages: $pkgs"
	# shellcheck disable=SC2086
	apt-get purge -y $pkgs
}

# Rebuild each initramfs that install.sh built, and any other one that
# still has the theme.
rebuild_initramfs() {
	local kver img list=""
	for kver in $(state_all kernel); do
		[ -e "/boot/initrd.img-$kver" ] && list="$list $kver"
	done
	for img in /boot/initrd.img-*; do
		[ -e "$img" ] || continue
		kver=${img#/boot/initrd.img-}
		if grep -q 'plymouth/themes/debian-dark/' <<< "$(lsinitramfs "$img" 2> /dev/null)"; then
			list="$list $kver"
		fi
	done
	for kver in $(echo "$list" | tr ' ' '\n' | sort -u); do
		STEP="update-initramfs -u -k $kver"
		heading "Building the initramfs of $kver"
		update-initramfs -u -k "$kver"
	done
}

on_error() {
	local code=$? line=$1
	trap - ERR
	printf '\n%sFailed%s at line %s, step: %s (exit code %s).\n' \
		"$C_RED" "$C_OFF" "$line" "$STEP" "$code" >&2
	say "The state file $STATE_FILE is kept. Fix the problem and run uninstall.sh again." >&2
	[ -n "$RUN_BACKUP" ] && say "Copies of the changed files: $RUN_BACKUP" >&2
	exit 1
}

cleanup() {
	[ -n "$STAGE" ] && rm -rf "$STAGE"
	return 0
}

main() {
	parse_args "$@"
	[ "$DRY_RUN" = 1 ] || need_root "$@"
	check_installed
	trap cleanup EXIT
	STAGE=$(mktemp -d)
	make_plan
	print_summary
	if [ "$DRY_RUN" = 1 ]; then
		say ""
		say "Dry run: nothing was changed."
		exit 0
	fi
	confirm "Remove the debian-dark boot splash?"
	take_lock
	trap 'on_error $LINENO' ERR
	init_backup_dir uninstall
	PHASE=files
	heading "Files"
	apply_plan
	purge_packages
	PHASE=initramfs
	rebuild_initramfs
	PHASE=grub
	STEP="update-grub"
	heading "Building $GRUB_CFG"
	update-grub
	rm -rf "$STATE_DIR"
	trap - ERR
	heading "Done"
	say "  The boot splash is removed. Copies of the removed files: $RUN_BACKUP"
	say "  The backups in $BACKUP_ROOT stay. Delete them when you no longer need them."
}

main "$@"
