#!/bin/bash
# Test the graphics driver detection of lib/detect.sh with fake sysfs
# trees. Runs as a normal user, without a VM.
set -eu
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/lib/common.sh"
. "$top/lib/detect.sh"
fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
fails=0

# Fake modinfo: every module exists, except "missing"; "builtin" is built in.
module_file() {
	case $2 in
		missing) ;;
		builtin) echo "(builtin)" ;;
		*) echo "/lib/modules/$1/$2.ko.xz" ;;
	esac
}

# A device with a driver and a module, like in /sys/devices.
# device DIR MODULE
device() {
	mkdir -p "$1/dev" "$1/drv" "$fake/module/$2"
	ln -sfn "$fake/module/$2" "$1/drv/module"
	ln -sfn "$1/drv" "$1/dev/driver"
}

# card NAME MODULE CONNECTOR:STATUS...
card() {
	local name=$1 mod=$2 c d=$fake/devices/$1
	shift 2
	device "$d" "$mod"
	mkdir -p "$d/drm/$name" "$fake/sys/class/drm"
	ln -sfn "$d/dev" "$d/drm/$name/device"
	ln -sfn "$d/drm/$name" "$fake/sys/class/drm/$name"
	for c in "$@"; do
		mkdir -p "$d/drm/$name/$name-${c%%:*}"
		echo "${c#*:}" > "$d/drm/$name/$name-${c%%:*}/status"
	done
}

privacy() {
	local d=$fake/devices/ps-$1
	device "$d" "$1"
	mkdir -p "$d/ps" "$fake/sys/class/drm"
	ln -sfn "$d/dev" "$d/ps/device"
	ln -sfn "$d/ps" "$fake/sys/class/drm/privacy_screen-$1"
}

expect() {
	local name=$1 want=$2
	SYSFS=$fake/sys
	detect_modules 6.12.0-test
	if [ "$MODULES_ADD" = "$want" ]; then
		echo "ok    $name: \"$MODULES_ADD\""
	else
		echo "FAIL  $name: got \"$MODULES_ADD\", want \"$want\""
		fails=1
	fi
	printf '%s' "$MODULES_NOTES" | sed 's/^/        /'
	rm -rf "${fake:?}"/*
}

card card0 i915 eDP-1:connected HDMI-A-1:disconnected
privacy thinkpad_acpi
expect "ThinkPad with a privacy screen" "thinkpad_acpi i915"

card card0 i915 eDP-1:connected
card card1 nouveau DP-1:disconnected
expect "hybrid Intel + nouveau, screen on Intel" "i915"

card card0 amdgpu eDP-1:connected
card card1 nvidia HDMI-A-1:connected
expect "AMD + NVIDIA driver" "amdgpu"

card card0 nvidia HDMI-A-1:connected
expect "NVIDIA driver only" ""

card card0 amdgpu DP-1:connected DP-2:connected
expect "desktop with two screens on one card" "amdgpu"

card card0 missing Virtual-1:connected
expect "module not in the target kernel" ""

card card0 builtin Virtual-1:connected
expect "driver built into the kernel" ""

card card0 bochs Virtual-1:connected
expect "QEMU VGA" "bochs"

exit $fails
