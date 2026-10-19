# Shared code of install.sh and uninstall.sh: paths, messages, the state
# file and the backups. This file is sourced, not run.

PKG_NAME=debian-dark-boot
PKG_VERSION=1.0

STATE_DIR=/var/lib/debian-dark-boot
STATE_FILE=$STATE_DIR/state
BACKUP_ROOT=/var/backups/debian-dark-boot
LOCK_FILE=/run/debian-dark-boot.lock

GRUB_THEME_DIR=/boot/grub/themes/debian-dark
GRUB_DEFAULT_CFG=/etc/default/grub.d/debian-dark.cfg
GRUB_LINUX=/etc/grub.d/10_linux
GRUB_CFG=/boot/grub/grub.cfg
PLY_THEME_DIR=/usr/share/plymouth/themes/debian-dark
PLY_CONF=/etc/plymouth/plymouthd.conf
HOOK_PLY=/etc/initramfs-tools/hooks/debian-dark-plymouth
HOOK_CRYPT=/etc/initramfs-tools/hooks/debian-dark-cryptroot
MODULES_FILE=/etc/initramfs-tools/modules
ISSUE_DIR=/etc/issue.d
ISSUE_FILE=$ISSUE_DIR/vt-cursor.issue
APT_HOOK=/etc/apt/apt.conf.d/99debian-dark-boot
SYSFS=/sys
PACKAGES="plymouth plymouth-themes plymouth-label"

DRY_RUN=0
ASSUME_YES=0
RUN_BACKUP=""

if [ -t 1 ]; then
	C_BOLD=$(printf '\033[1m')
	C_RED=$(printf '\033[31m')
	C_YELLOW=$(printf '\033[33m')
	C_GREEN=$(printf '\033[32m')
	C_OFF=$(printf '\033[0m')
else
	C_BOLD="" C_RED="" C_YELLOW="" C_GREEN="" C_OFF=""
fi

say() {
	printf '%s\n' "$*"
}

heading() {
	printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_OFF"
}

warn() {
	printf '%sWarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
}

die() {
	printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
	exit 1
}

# Run a command that changes the system. With --dry-run, only print it.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		say "  would run: $*"
		return 0
	fi
	"$@"
}

need_root() {
	[ "$(id -u)" = 0 ] && return 0
	die "Run this as root, for example: sudo $0 $*"
}

take_lock() {
	[ "$DRY_RUN" = 1 ] && return 0
	exec 9> "$LOCK_FILE"
	flock -n 9 || die "Another run of $PKG_NAME is in progress."
	# LVM tools warn about the open lock file in every child process.
	export LVM_SUPPRESS_FD_WARNINGS=1
}

confirm() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ "$DRY_RUN" = 1 ] && return 0
	if [ ! -t 0 ]; then
		die "No terminal to ask for confirmation. Use --yes to go on without asking."
	fi
	printf '\n%s [y/N] ' "$1"
	read -r answer
	case $answer in
		y | Y | yes | YES) return 0 ;;
	esac
	say "Stopped. Nothing was changed."
	exit 0
}

sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# The state file lists what install.sh changed, one "KEY VALUE" per line.
state_has() {
	[ -f "$STATE_FILE" ] && grep -Fxq -- "$1 $2" "$STATE_FILE"
}

state_get() {
	[ -f "$STATE_FILE" ] || return 0
	awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$STATE_FILE"
}

state_all() {
	[ -f "$STATE_FILE" ] || return 0
	awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print }' "$STATE_FILE"
}

state_add() {
	[ "$DRY_RUN" = 1 ] && return 0
	state_has "$1" "$2" && return 0
	mkdir -p "$STATE_DIR"
	printf '%s %s\n' "$1" "$2" >> "$STATE_FILE"
}

state_del_key() {
	[ "$DRY_RUN" = 1 ] && return 0
	[ -f "$STATE_FILE" ] || return 0
	awk -v k="$1" '$1 != k' "$STATE_FILE" > "$STATE_FILE.new"
	mv "$STATE_FILE.new" "$STATE_FILE"
}

state_set() {
	state_del_key "$1"
	state_add "$1" "$2"
}

# Return the value of KEY for one PATH, from lines "KEY PATH VALUE".
state_path_value() {
	[ -f "$STATE_FILE" ] || return 0
	awk -v k="$1" -v p="$2" '$1 == k && $2 == p { print $3; exit }' "$STATE_FILE"
}

# Each run that changes files gets its own dated backup directory with a
# MANIFEST. The directory is made on the first change of the run.
init_backup_dir() {
	[ -n "$RUN_BACKUP" ] && return 0
	RUN_BACKUP=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$1
	mkdir -p "$RUN_BACKUP"
	chmod 700 "$BACKUP_ROOT" "$RUN_BACKUP"
	{
		echo "# $PKG_NAME $PKG_VERSION, $1, $(date -R)"
		echo "# ACTION PATH SHA256-BEFORE (\"-\" if it did not exist or is a directory)"
	} > "$RUN_BACKUP/MANIFEST"
}

# Copy PATH (a file or a directory) into the backup directory of this run
# and add a manifest line. Set BACKUP_COPY to the path of the copy, or to
# "-" if PATH does not exist.
backup_path() {
	local path=$1 action=$2 sum="-"
	BACKUP_COPY="-"
	if [ -e "$path" ]; then
		BACKUP_COPY=$RUN_BACKUP/files$path
		mkdir -p "$(dirname "$BACKUP_COPY")"
		if [ ! -e "$BACKUP_COPY" ]; then
			cp -a "$path" "$BACKUP_COPY"
		fi
		[ -f "$path" ] && sum=$(sha_of "$path")
	fi
	echo "$action $path $sum" >> "$RUN_BACKUP/MANIFEST"
}

# The newest installed kernel, as update-initramfs and the main GRUB
# entry see it.
newest_kernel() {
	linux-version list 2> /dev/null | linux-version sort | tail -n 1
}

kernels_to_build() {
	local newest running
	newest=$(newest_kernel)
	running=$(uname -r)
	echo "$newest"
	if [ "$running" != "$newest" ] && [ -e "/boot/initrd.img-$running" ]; then
		echo "$running"
	fi
}

pkg_installed() {
	[ "$(dpkg-query -W -f='${Status}' "$1" 2> /dev/null)" = "install ok installed" ]
}

installed_packages() {
	dpkg-query -W -f='${Package}:${Architecture} ${Status}\n' 2> /dev/null |
		awk '$NF == "installed" { print $1 }' | sort
}
