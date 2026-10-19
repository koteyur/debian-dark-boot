# Edits of files that other packages own: /etc/grub.d/10_linux,
# /etc/plymouth/plymouthd.conf and /etc/initramfs-tools/modules.
# Each function reads a file and prints the new text. Nothing here writes
# to the system. This file is sourced, not run.

# The regular expressions go to awk through the environment, because awk
# changes backslashes in -v values.
SIMPLE_ENTRY_RE='linux_entry "\$\{OS\}" "\$\{version\}" simple \\$'
STOCK_ARGS_RE='^[[:space:]]*"\$\{GRUB_CMDLINE_LINUX\} \$\{GRUB_CMDLINE_LINUX_DEFAULT\}"$'
SPLASH_ARGS_RE='^[[:space:]]*"\$\{GRUB_CMDLINE_LINUX\} \$\{GRUB_CMDLINE_LINUX_DEFAULT\}'
SPLASH_ARGS_RE="$SPLASH_ARGS_RE"' \$\{GRUB_CMDLINE_LINUX_SPLASH\}"$'
MODULES_COMMENT="# debian-dark-boot: load the graphics driver early, for the boot splash."

# Print the value of quiet_boot in 10_linux: 0, 1 or nothing.
linux_quiet_boot() {
	sed -n 's/^quiet_boot="\([01]\)"$/\1/p' "$1" | head -n 1
}

# Print the state of the arguments of the main ("simple") entry in
# 10_linux: "splash" (edited), "stock" or "unknown".
linux_splash_state() {
	RE_SE=$SIMPLE_ENTRY_RE RE_ST=$STOCK_ARGS_RE RE_SP=$SPLASH_ARGS_RE awk '
	BEGIN { se = ENVIRON["RE_SE"]; st = ENVIRON["RE_ST"]; sp = ENVIRON["RE_SP"] }
	prev && $0 ~ sp { s = "splash"; n++ }
	prev && $0 ~ st { s = "stock"; n++ }
	{ prev = ($0 ~ se) }
	END { print (n == 1 ? s : "unknown") }' "$1"
}

# Print 10_linux with both edits: quiet_boot="1", and the splash options
# added to the main entry only.
linux_apply() {
	RE_SE=$SIMPLE_ENTRY_RE RE_ST=$STOCK_ARGS_RE awk '
	BEGIN { se = ENVIRON["RE_SE"]; st = ENVIRON["RE_ST"] }
	/^quiet_boot="0"$/ { print "quiet_boot=\"1\""; prev = 0; next }
	prev && $0 ~ st { sub(/"$/, " ${GRUB_CMDLINE_LINUX_SPLASH}\"") }
	{ prev = ($0 ~ se); print }' "$1"
}

# Print 10_linux without the edits. $2 is "yes" to set quiet_boot back
# to "0".
linux_revert() {
	RE_SE=$SIMPLE_ENTRY_RE RE_SP=$SPLASH_ARGS_RE awk -v q="$2" '
	BEGIN { se = ENVIRON["RE_SE"]; sp = ENVIRON["RE_SP"] }
	q == "yes" && /^quiet_boot="1"$/ { print "quiet_boot=\"0\""; prev = 0; next }
	prev && $0 ~ sp { sub(/ \$\{GRUB_CMDLINE_LINUX_SPLASH\}"$/, "\"") }
	{ prev = ($0 ~ se); print }' "$1"
}

# Print the value of KEY in the [Daemon] section of plymouthd.conf.
ply_conf_get() {
	[ -f "$1" ] || return 0
	awk -v key="$2" '
	/^[[:space:]]*\[/ { sect = $0; gsub(/[[:space:]]/, "", sect); next }
	sect == "[Daemon]" && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
	' "$1"
}

# Print plymouthd.conf with KEY=VALUE pairs set in the [Daemon] section.
# A VALUE of "-" removes the key. Other lines stay as they are.
ply_conf_set() {
	local file=$1
	shift
	[ -f "$file" ] || file=/dev/null
	awk -v pairs="$*" '
	BEGIN {
		n = split(pairs, kv, " ")
		for (i = 1; i <= n; i++) {
			p = index(kv[i], "=")
			key[i] = substr(kv[i], 1, p - 1)
			val[i] = substr(kv[i], p + 1)
		}
	}
	function flush(   i) {
		for (i = 1; i <= n; i++)
			if (!done[i] && val[i] != "-") print key[i] "=" val[i]
		flushed = 1
	}
	/^[[:space:]]*\[/ {
		if (sect == "[Daemon]") flush()
		sect = $0; gsub(/[[:space:]]/, "", sect)
		if (sect == "[Daemon]") seen = 1
		print; next
	}
	sect == "[Daemon]" {
		for (i = 1; i <= n; i++) {
			if (index($0, key[i] "=") == 1) {
				if (!done[i] && val[i] != "-") print key[i] "=" val[i]
				done[i] = 1
				next
			}
		}
	}
	{ print }
	END {
		if (sect == "[Daemon]" && !flushed) flush()
		if (!seen) {
			need = 0
			for (i = 1; i <= n; i++) if (val[i] != "-") need = 1
			if (need) { print "[Daemon]"; flush() }
		}
	}' "$file"
}

# Print the modules from the list that are not in the modules file yet.
modules_missing() {
	local file=$1 mod
	shift
	for mod in "$@"; do
		if ! awk -v m="$mod" '!/^[[:space:]]*#/ && $1 == m { found = 1 } END { exit !found }' \
			"$file"; then
			echo "$mod"
		fi
	done
}

# Print the modules file with the given modules added at the end, after
# one comment line.
modules_add() {
	local file=$1
	shift
	cat "$file"
	[ $# -gt 0 ] || return 0
	echo "$MODULES_COMMENT"
	printf '%s\n' "$@"
}

# Print the modules file without the given module lines and without the
# comment line of modules_add.
modules_remove() {
	local file=$1
	shift
	awk -v list="$*" -v c="$MODULES_COMMENT" '
	BEGIN { n = split(list, m, " "); for (i = 1; i <= n; i++) drop[m[i]] = 1 }
	$0 == c { next }
	($0 in drop) && !gone[$0]++ { next }
	{ print }' "$file"
}
