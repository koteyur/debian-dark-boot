#!/bin/bash
# Install the "debian-dark" boot splash: a GRUB theme and a Plymouth theme
# with the same grey Debian logo at the same place. See README.md.
# Run it again to repair, for example after an upgrade of grub-common.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/detect.sh"
. "$HERE/lib/edits.sh"
. "$HERE/lib/plan.sh"
. "$HERE/lib/status.sh"

usage() {
	cat << EOF
Usage: $0 [OPTION]

Install the debian-dark boot splash (GRUB theme and Plymouth theme).

  --dry-run   show what would change, and change nothing
  --status    check that everything is in place (also --check)
  --yes       do not ask for confirmation
  --force     go on with a distribution other than Debian 13
  --help      show this help

Run it as root. Undo everything with uninstall.sh.
EOF
}

OPT_STATUS=0
OPT_FORCE=0
STEP="start"
PHASE="checks"
STAGE=""
ADOPTED=0
MODULES_NEW=""

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
			--dry-run | -n) DRY_RUN=1 ;;
			--status | --check) OPT_STATUS=1 ;;
			--yes | -y) ASSUME_YES=1 ;;
			--force) OPT_FORCE=1 ;;
			--help | -h) usage; exit 0 ;;
			*) usage >&2; exit 2 ;;
		esac
		shift
	done
}

check_distro() {
	local id="" version="" like="" name=""
	if [ -r /etc/os-release ]; then
		id=$(. /etc/os-release && echo "${ID:-}")
		version=$(. /etc/os-release && echo "${VERSION_ID:-}")
		like=$(. /etc/os-release && echo "${ID_LIKE:-}")
		name=$(. /etc/os-release && echo "${PRETTY_NAME:-}")
	fi
	if [ "$id" = debian ] && [ "$version" = 13 ]; then
		return 0
	fi
	case " $id $like " in
		*" debian "*)
			[ "$OPT_FORCE" = 1 ] && {
				warn "Made for Debian 13 (trixie). This is $name. Going on (--force)."
				return 0
			}
			die "Made for Debian 13 (trixie). This is $name. Use --force to try anyway." ;;
	esac
	die "Made for Debian 13 (trixie). This is ${name:-an unknown system}."
}

check_tools() {
	local tool
	for tool in grub-mkconfig update-grub grub-script-check update-initramfs lsinitramfs \
		unmkinitramfs dpkg-query modinfo linux-version flock; do
		command -v "$tool" > /dev/null || die "The command $tool is missing."
	done
	pkg_installed initramfs-tools || die "initramfs-tools is not installed."
	if pkg_installed dracut; then
		die "dracut is installed. This package works only with initramfs-tools."
	fi
	pkg_installed grub-common || die "GRUB (grub-common) is not installed."
	if ! grep -Eq '^(grub-efi-[a-z0-9]+|grub-pc) install ok installed' <<< \
		"$(dpkg-query -W -f='${Package} ${Status}\n' 'grub-efi-*' grub-pc 2> /dev/null)"; then
		die "Neither grub-efi nor grub-pc is installed. GRUB must be the boot loader."
	fi
	[ -f "$GRUB_LINUX" ] || die "$GRUB_LINUX is missing."
	[ -n "$(linux_quiet_boot "$GRUB_LINUX")" ] ||
		die "$GRUB_LINUX has no quiet_boot line. Its version is not known to this script."
	[ "$(linux_splash_state "$GRUB_LINUX")" != unknown ] ||
		die "The main entry in $GRUB_LINUX looks different. Its version is not known."
	[ -d "$HERE/themes/grub/debian-dark" ] && [ -d "$HERE/themes/plymouth/debian-dark" ] ||
		die "The themes are missing in $HERE/themes."
	[ -n "$(newest_kernel)" ] || die "No installed kernel found."
}

# Settings in /etc/default/grub that hide the theme.
check_grub_terminal() {
	local term
	term=$(
		set +eu
		. /etc/default/grub > /dev/null 2>&1
		for f in /etc/default/grub.d/*.cfg; do
			[ "$f" = "$GRUB_DEFAULT_CFG" ] || . "$f" > /dev/null 2>&1
		done
		echo "${GRUB_TERMINAL_OUTPUT:-${GRUB_TERMINAL:-}}"
	)
	case $term in
		*console* | *serial*)
			warn "GRUB_TERMINAL is \"$term\". GRUB then shows no theme. Plymouth still works." ;;
	esac
}

missing_packages() {
	local pkg out=""
	for pkg in $PACKAGES; do
		pkg_installed "$pkg" || out="$out $pkg"
	done
	echo $out
}

print_detection() {
	heading "This computer"
	say "  Kernel for the main entry: $(newest_kernel)"
	say "  Disk encryption (LUKS): $LUKS${LUKS_NAMES:+ ($LUKS_NAMES)}"
	say "  Graphics modules to load early: ${MODULES_ADD:-none}"
	if [ -n "$MODULES_NOTES" ]; then
		printf '%s' "$MODULES_NOTES" | sed 's/^/    /'
	fi
	if [ "$ADOPTED" = 1 ] || { [ ! -f "$STATE_FILE" ] && [ -e "$GRUB_DEFAULT_CFG" ]; }; then
		say "  An earlier install made by hand was found. Its files are taken over."
		say "  uninstall.sh removes them too."
	fi
	[ -f "$STATE_FILE" ] && say "  Installed before by install.sh. This run repairs and updates."
	return 0
}

print_summary() {
	local pkgs
	pkgs=$(missing_packages)
	heading "Changes"
	[ -n "$pkgs" ] && say "  install packages: $pkgs (with apt-get)"
	if [ -n "$pkgs" ] && [ "$DRY_RUN" = 1 ]; then
		say "  (The list below is made before the packages are installed.)"
	fi
	print_plan
	say "  Then rebuild the initramfs ($(kernels_to_build | xargs)) and $GRUB_CFG."
	say "  Backups go to $BACKUP_ROOT/<date>-install, with a MANIFEST."
	if [ "$DRY_RUN" = 1 ]; then
		heading "Edits of files that belong to other packages"
		print_plan_diffs
	fi
}

install_packages() {
	local pkgs before after pkg
	pkgs=$(missing_packages)
	[ -n "$pkgs" ] || return 0
	STEP="install packages: $pkgs"
	heading "Installing packages: $pkgs"
	before=$(installed_packages)
	apt-get update
	# shellcheck disable=SC2086
	apt-get install -y $pkgs
	after=$(installed_packages)
	for pkg in $(comm -13 <(echo "$before") <(echo "$after")); do
		state_add package "$pkg"
	done
}

on_error() {
	local code=$? line=$1
	trap - ERR
	echo >&2
	printf '%sFailed%s at line %s, step: %s (exit code %s).\n' \
		"$C_RED" "$C_OFF" "$line" "$STEP" "$code" >&2
	case $PHASE in
		checks) say "Nothing was changed." >&2 ;;
		files)
			say "Some files were changed. The initramfs and grub.cfg were NOT rebuilt," >&2
			say "so the next boot is as before." >&2 ;;
		initramfs)
			say "The initramfs build failed. The old initramfs is still in place." >&2
			say "grub.cfg was NOT rebuilt." >&2 ;;
		grub) say "The initramfs was rebuilt. grub.cfg was NOT rebuilt." >&2 ;;
	esac
	if [ "$PHASE" != checks ]; then
		say "To undo all changes: sudo $HERE/uninstall.sh" >&2
		[ -n "$RUN_BACKUP" ] && say "Copies of the changed files: $RUN_BACKUP" >&2
	fi
	exit 1
}

cleanup() {
	[ -n "$STAGE" ] && rm -rf "$STAGE"
	return 0
}

# Check the new grub.cfg in a temporary file first.
test_grub_cfg() {
	STEP="test grub-mkconfig"
	say "  Testing the new GRUB menu in a temporary file..."
	grub-mkconfig -o "$STAGE/grub.cfg" > "$STAGE/grub-mkconfig.log" 2>&1 || {
		cat "$STAGE/grub-mkconfig.log" >&2
		return 1
	}
	grub-script-check "$STAGE/grub.cfg"
	GRUB_CFG=$STAGE/grub.cfg grub_cfg_theme || {
		echo "The test grub.cfg does not use the theme." >&2
		return 1
	}
	GRUB_CFG=$STAGE/grub.cfg grub_cfg_main_splash || {
		echo "The main entry of the test grub.cfg has no splash options." >&2
		return 1
	}
}

# Keep a copy of the initramfs, if there is room for it.
keep_initramfs() {
	local img=/boot/initrd.img-$1 size free
	[ -f "$img" ] || return 0
	size=$(du -k "$img" | cut -f1)
	free=$(df -Pk "$RUN_BACKUP" | awk 'NR == 2 { print $4 }')
	if [ "$free" -gt $((size * 3)) ]; then
		cp -a "$img" "$RUN_BACKUP/"
		echo "copy $img -" >> "$RUN_BACKUP/MANIFEST"
	else
		warn "Not enough space in $BACKUP_ROOT for a copy of $img."
	fi
}

# Check a new initramfs. On a failure put the old one back.
verify_initramfs() {
	local kver=$1 out
	out=$(LUKS=$LUKS STATUS_FAIL=0; status_initramfs "$kver"; echo "fail=$STATUS_FAIL")
	printf '%s\n' "$out" | grep -v '^fail=' | sed 's/^ */  /'
	if printf '%s\n' "$out" | grep -q '^fail=1'; then
		if [ -f "$RUN_BACKUP/initrd.img-$kver" ]; then
			cp -a "$RUN_BACKUP/initrd.img-$kver" "/boot/initrd.img-$kver"
			say "The old initramfs of $kver was put back."
		fi
		STEP="check initramfs $kver"
		return 1
	fi
	return 0
}

check_cryptroot_syntax() {
	local kver=$1 dir script
	[ "$LUKS" = yes ] || return 0
	dir=$(mktemp -d)
	unmkinitramfs "/boot/initrd.img-$kver" "$dir"
	script=$(find "$dir" -path '*scripts/local-top/cryptroot' | head -n 1)
	if [ -n "$script" ] && ! sh -n "$script"; then
		rm -rf "$dir"
		echo "The changed cryptroot script has a syntax error." >&2
		return 1
	fi
	rm -rf "$dir"
}

initramfs_needed() {
	local t
	for t in $CHANGED; do
		case $t in
			"$PLY_THEME_DIR" | "$PLY_CONF" | "$HOOK_PLY" | "$HOOK_CRYPT" | "$MODULES_FILE")
				return 0 ;;
		esac
	done
	[ -n "$(state_all package)" ] && [ "$PACKAGES_INSTALLED_NOW" = 1 ] && return 0
	! (STATUS_FAIL=0; status_initramfs "$(newest_kernel)" > /dev/null; exit "$STATUS_FAIL")
}

rebuild_initramfs() {
	local kver
	PHASE=initramfs
	if ! initramfs_needed; then
		say "  The initramfs is up to date."
		return 0
	fi
	for kver in $(kernels_to_build); do
		STEP="update-initramfs -u -k $kver"
		keep_initramfs "$kver"
		heading "Building the initramfs of $kver"
		update-initramfs -u -k "$kver"
		check_cryptroot_syntax "$kver" || {
			cp -a "$RUN_BACKUP/initrd.img-$kver" "/boot/initrd.img-$kver" 2> /dev/null || true
			return 1
		}
		verify_initramfs "$kver"
		state_add kernel "$kver"
	done
}

grub_needed() {
	local t
	for t in $CHANGED; do
		case $t in
			"$GRUB_THEME_DIR" | "$GRUB_DEFAULT_CFG" | "$GRUB_LINUX") return 0 ;;
		esac
	done
	! { grub_cfg_theme && grub_cfg_main_splash; }
}

rebuild_grub() {
	PHASE=grub
	STEP="update-grub"
	heading "Building $GRUB_CFG"
	update-grub
}

# True when every file is in place, nothing needs a rebuild and the state
# file exists. A second run then has nothing to do.
nothing_to_do() {
	local kind target source mode
	[ -f "$STATE_FILE" ] || return 1
	[ -z "$(missing_packages)" ] || return 1
	while read -r kind target source mode; do
		[ -n "$kind" ] || continue
		[ "$(item_action "$kind" "$target" "$source")" = unchanged ] || return 1
	done <<< "$PLAN"
	grub_cfg_theme && grub_cfg_main_splash || return 1
	(STATUS_FAIL=0; status_initramfs "$(newest_kernel)" > /dev/null; exit "$STATUS_FAIL")
}

do_install() {
	PHASE=files
	init_backup_dir install
	state_set version "$PKG_VERSION"
	[ -n "$(state_get installed)" ] || state_add installed "$(date +%Y-%m-%d)"
	state_add backup "$RUN_BACKUP"
	PACKAGES_INSTALLED_NOW=0
	[ -n "$(missing_packages)" ] && PACKAGES_INSTALLED_NOW=1
	install_packages
	STAGE=$(mktemp -d)
	stage_plan "$STAGE"
	heading "Files"
	apply_plan
	if grub_needed; then
		test_grub_cfg
		rebuild_initramfs
		rebuild_grub
	else
		rebuild_initramfs
		say "  $GRUB_CFG is up to date."
	fi
	PHASE=done
}

main() {
	parse_args "$@"
	if [ "$OPT_STATUS" = 1 ]; then
		run_status
		exit $?
	fi
	[ "$DRY_RUN" = 1 ] || need_root "$@"
	check_distro
	check_tools
	check_grub_terminal
	detect_luks
	detect_modules "$(newest_kernel)"
	trap cleanup EXIT
	STAGE=$(mktemp -d)
	stage_plan "$STAGE"
	print_detection
	keymap_warning
	if [ "$DRY_RUN" = 0 ] && nothing_to_do; then
		heading "Nothing to do"
		say "  Everything is in place. install.sh --status shows the details."
		exit 0
	fi
	print_summary
	if [ "$DRY_RUN" = 1 ]; then
		say ""
		say "Dry run: nothing was changed."
		exit 0
	fi
	confirm "Install the debian-dark boot splash?"
	take_lock
	trap 'on_error $LINENO' ERR
	adopt_manual_install
	rm -rf "$STAGE"
	do_install
	trap - ERR
	heading "Done"
	say "  Backups: $RUN_BACKUP"
	run_status > "$STAGE.status" 2>&1 && say "  install.sh --status: everything is in place." || {
		cat "$STAGE.status"
	}
	rm -f "$STAGE.status"
	say "  Reboot to see the new boot screen. To undo: sudo $HERE/uninstall.sh"
}

main "$@"
