# Tests

The tests run as a normal user, in podman containers with QEMU, KVM and
OVMF. Nothing on the host is changed.

They cover the full boot chain: OVMF, shim, GRUB, kernel, Plymouth in the
initramfs, the LUKS prompt and systemd. Two VMs are tested:

- `luks`: ESP, ext4 `/boot`, LUKS2 with LVM. Plymouth is installed,
  `plymouth-themes` is not.
- `plain`: no encryption and no Plymouth.

## Run

From this directory:

```
podman build -t localhost/ddboot-tools:latest -f Containerfile.tools .
podman build --build-arg VARIANT=luks -t localhost/ddboot-guest-luks -f Containerfile.guest .
podman build --build-arg VARIANT=plain -t localhost/ddboot-guest-plain -f Containerfile.guest .
./vm.sh image luks && ./vm.sh install luks && ./run-tests.sh luks
./vm.sh image plain && ./vm.sh install plain && ./run-tests.sh plain
./grub-qemu.sh sizes && ./grub-qemu.sh detail
./test-detect.sh
```

`run-tests.sh` runs `install.sh` twice, boots at several screen sizes and
checks the logo position in each frame. It boots an "Advanced options"
entry. It reinstalls grub-common, which replaces `10_linux`, and runs
`install.sh` again. At the end it
runs `uninstall.sh` and compares `/etc`, `grub.cfg`, the initramfs and the
package list with the state before the install.

To run only some steps: `./run-tests.sh luks install shots`. The steps are
`install shots advanced upgrade uninstall after adopt s1366`. The default
is all but `adopt` and `s1366`.

## Scripts

| File | What it does |
| --- | --- |
| `vm.sh` | Makes the base disks and boots a VM: `image`, `install`, `fresh`, `boot`. |
| `run-tests.sh` | The full test of `install.sh` and `uninstall.sh`. |
| `grub-qemu.sh` | Boots GRUB alone with the theme and takes screenshots. Modes: `sizes`, `detail`, `fonts`, `old`. |
| `test-detect.sh` | Tests the graphics driver detection with fake sysfs trees. No VM. |
| `check-shots.py` | Picks the splash frames and compares the logo pixels with GRUB. |
| `snapshot.sh` | Runs in the VM. Saves the state for the before and after compare. |
| `manual-install.sh` | Runs in the VM. Makes an install by hand, for the `adopt` step. |
| `side-by-side.sh` | Makes `screenshots/compare-old-new-1920x1200.png`. |
| `vmctl.py`, `vm-inner.sh`, `vm-setup-target.sh`, `grub-qemu-inner.sh`, `unskew.py`, `grub-font-compare.py` | Helpers of the scripts above. |
| `layout.env` | Positions for `check-shots.py`. `src/make-assets.py` writes it. |

## Output

- Logs: `../screenshots/vm/test-luks.log` and `test-plain.log`.
- Screenshots: `../screenshots/vm/` and `../screenshots/grub/`.
- Disks and all other frames: `~/.cache/ddboot-scratch`, or `$SCRATCH` if
  set. Delete it when you are done.

`screenshots/` is in `.gitignore`. The pictures in the main README are in
`../docs/`. Copy a new screenshot there by hand if the look changes.

The VM root password and the disk password are both `test`.

QEMU needs a screen width that is a multiple of 8. So 1366x768 is tested
as 1360x768 in the VM. `grub-qemu.sh` takes real 1366x768 shots and fixes
them with `unskew.py`.
