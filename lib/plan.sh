# The install plan: what each target should look like, staged in a
# temporary directory, and the code that puts it in place.
# This file is sourced, not run.

# One plan item per line: KIND TARGET SOURCE MODE
#   tree    a directory that belongs to this package
#   own     a file that belongs to this package
#   shared  a file of another package, edited in place
PLAN=""
CHANGED=""          # targets that change in this run

stage_plan() {
	local stage=$1 missing
	PLAN=""
	plan_item tree "$GRUB_THEME_DIR" "$HERE/themes/grub/debian-dark" 644
	plan_item own "$GRUB_DEFAULT_CFG" "$HERE/files/grub-debian-dark.cfg" 644
	linux_apply "$GRUB_LINUX" > "$stage/10_linux"
	plan_item shared "$GRUB_LINUX" "$stage/10_linux" 755
	plan_item tree "$PLY_THEME_DIR" "$HERE/themes/plymouth/debian-dark" 644
	ply_conf_set "$PLY_CONF" Theme=debian-dark DeviceScale=1 > "$stage/plymouthd.conf"
	plan_item shared "$PLY_CONF" "$stage/plymouthd.conf" 644
	plan_item own "$HOOK_PLY" "$HERE/files/debian-dark-plymouth" 755
	plan_item own "$HOOK_CRYPT" "$HERE/files/debian-dark-cryptroot" 755
	# shellcheck disable=SC2086
	missing=$(modules_missing "$MODULES_FILE" $MODULES_ADD)
	MODULES_NEW=$(echo $missing)
	# shellcheck disable=SC2086
	modules_add "$MODULES_FILE" $MODULES_NEW > "$stage/modules"
	plan_item shared "$MODULES_FILE" "$stage/modules" 644
	plan_item own "$ISSUE_FILE" "$HERE/files/vt-cursor.issue" 644
	plan_item own "$APT_HOOK" "$HERE/files/apt-hook.conf" 644
}

plan_item() {
	PLAN="${PLAN}$1 $2 $3 $4
"
}

# Print "create", "replace", "edit" or "unchanged" for a plan item.
item_action() {
	local kind=$1 target=$2 source=$3
	if [ ! -e "$target" ]; then
		echo create
	elif [ "$kind" = tree ]; then
		if diff -rq "$source" "$target" > /dev/null 2>&1; then
			echo unchanged
		else
			echo replace
		fi
	elif cmp -s "$source" "$target"; then
		echo unchanged
	elif [ "$kind" = shared ]; then
		echo edit
	else
		echo replace
	fi
}

print_plan() {
	local kind target source mode action
	while read -r kind target source mode; do
		[ -n "$kind" ] || continue
		action=$(item_action "$kind" "$target" "$source")
		printf '  %-10s %s\n' "$action" "$target"
	done <<< "$PLAN"
}

print_plan_diffs() {
	local kind target source mode
	while read -r kind target source mode; do
		[ "$kind" = shared ] || continue
		[ -e "$target" ] || continue
		cmp -s "$source" "$target" && continue
		say ""
		diff -u --label "$target" --label "$target (new)" "$target" "$source" || true
	done <<< "$PLAN"
}

# Make the parent directories of a target. Record each one that did not
# exist, so that uninstall.sh can remove it again.
make_parents() {
	local dir=$1 missing=""
	while [ ! -d "$dir" ]; do
		missing="$dir $missing"
		dir=$(dirname "$dir")
	done
	for dir in $missing; do
		mkdir "$dir"
		state_add dir "$dir"
	done
}

apply_plan() {
	local kind target source mode action
	while read -r kind target source mode; do
		[ -n "$kind" ] || continue
		action=$(item_action "$kind" "$target" "$source")
		if [ "$action" = unchanged ]; then
			say "  unchanged  $target"
			continue
		fi
		STEP="$action $target"
		say "  $action $(printf '%*s' $((9 - ${#action})) '') $target"
		apply_item "$kind" "$target" "$source" "$mode" "$action"
		CHANGED="$CHANGED $target"
	done <<< "$PLAN"
}

apply_item() {
	local kind=$1 target=$2 source=$3 mode=$4 action=$5
	case $kind in
		tree) apply_tree "$target" "$source" "$mode" "$action" ;;
		own) apply_own "$target" "$source" "$mode" "$action" ;;
		shared) apply_shared "$target" "$source" "$mode" "$action" ;;
	esac
}

apply_tree() {
	local target=$1 source=$2 mode=$3 action=$4 tmp
	backup_path "$target" "$action"
	make_parents "$(dirname "$target")"
	tmp=$target.debian-dark-new
	rm -rf "$tmp"
	mkdir -m 755 "$tmp"
	install -m "$mode" "$source"/* "$tmp"/
	rm -rf "$target"
	mv "$tmp" "$target"
	state_add own "$target"
}

apply_own() {
	local target=$1 source=$2 mode=$3 action=$4
	backup_path "$target" "$action"
	make_parents "$(dirname "$target")"
	install -m "$mode" "$source" "$target.debian-dark-new"
	mv "$target.debian-dark-new" "$target"
	state_add own "$target"
}

# Edit a file of another package. The first time, keep the old file as
# the original that uninstall.sh restores. The file keeps its owner and
# mode.
apply_shared() {
	local target=$1 source=$2 mode=$3 action=$4
	backup_path "$target" "$action"
	if [ -z "$(state_path_value orig "$target")" ]; then
		state_add orig "$target $BACKUP_COPY"
	fi
	record_shared_edit "$target"
	if [ -e "$target" ]; then
		cp -p "$target" "$target.debian-dark-new"
		cat "$source" > "$target.debian-dark-new"
	else
		make_parents "$(dirname "$target")"
		install -m "$mode" "$source" "$target.debian-dark-new"
	fi
	mv "$target.debian-dark-new" "$target"
	if [ "$target" = "$PLY_CONF" ]; then
		state_set plysha "$(sha_of "$target")"
	fi
}

# Write down which edits this run makes, so that uninstall.sh undoes
# exactly those.
record_shared_edit() {
	local mod
	case $1 in
		"$GRUB_LINUX")
			if [ "$(linux_quiet_boot "$GRUB_LINUX")" = 0 ]; then
				state_add edit10 quiet
			fi
			if [ "$(linux_splash_state "$GRUB_LINUX")" = stock ]; then
				state_add edit10 splash
			fi ;;
		"$PLY_CONF")
			record_ply_old Theme
			record_ply_old DeviceScale ;;
		"$MODULES_FILE")
			for mod in $MODULES_NEW; do
				state_add module "$mod"
			done ;;
	esac
}

record_ply_old() {
	local key=$1 old
	state_path_value plyold "$key" | grep -q . && return 0
	old=$(ply_conf_get "$PLY_CONF" "$key")
	# A Theme=debian-dark from an earlier install by hand is not kept.
	if [ "$key" = Theme ] && [ "$old" = debian-dark ]; then
		old=""
	fi
	state_add plyold "$key ${old:--}"
}

# True if directory $1 holds only the entry $2.
only_child() {
	[ -d "$1" ] && [ "$(ls -A "$1")" = "$2" ]
}

# An install made by hand (without this script) leaves files with the
# same names. They are taken over: uninstall.sh removes them too, and the
# 10_linux edits are undone.
adopt_manual_install() {
	[ -f "$STATE_FILE" ] && return 0
	[ -e "$GRUB_DEFAULT_CFG" ] || [ -e "$GRUB_THEME_DIR" ] || [ -e "$PLY_THEME_DIR" ] ||
		return 0
	ADOPTED=1
	local path
	for path in "$GRUB_THEME_DIR" "$GRUB_DEFAULT_CFG" "$PLY_THEME_DIR" "$HOOK_PLY" \
		"$HOOK_CRYPT" "$ISSUE_FILE" "$APT_HOOK"; do
		[ -e "$path" ] && state_add own "$path"
	done
	# Folders that hold nothing else were probably made for these files.
	# uninstall.sh removes them only if they are empty.
	only_child /boot/grub/themes debian-dark && state_add dir /boot/grub/themes
	only_child "$ISSUE_DIR" vt-cursor.issue && state_add dir "$ISSUE_DIR"
	if [ "$(linux_quiet_boot "$GRUB_LINUX")" = 1 ]; then
		state_add edit10 quiet
	fi
	if [ "$(linux_splash_state "$GRUB_LINUX")" = splash ]; then
		state_add edit10 splash
	fi
	# The old values of plymouthd.conf are not known. uninstall.sh removes
	# the two keys instead of restoring a copy.
	if [ "$(ply_conf_get "$PLY_CONF" Theme)" = debian-dark ]; then
		state_add orig "$PLY_CONF keys"
		state_add plyold "Theme -"
		state_add plyold "DeviceScale -"
	fi
}
