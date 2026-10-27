# Troubleshooting

Start with `winserver doctor`, then look at `~/.winserver/vms/<name>/qemu.log` and `qemu.cmd`.
Inside Windows, the first-boot logs are in `C:\ProgramData\winserver\`.

## The VM boots into a UEFI shell or "No bootable device"

The firmware skipped the installer at "Press any key to boot from CD or DVD". winserver avoids that prompt by booting a
rebuilt copy of the ISO, which needs `mkisofs`:

```bash
brew install cdrtools
winserver delete <name> && winserver create <name> …     # recreate so it uses the prompt-free copy
```

Without mkisofs the QEMU backend presses Enter for you during the first seconds. If that was missed:
`winserver stop <name> --force && winserver start <name> --press-enter`, or press a key in the VM window yourself.

If the ISO has no `efi/microsoft/boot/efisys_noprompt.bin` (some third-party ISOs), winserver warns that the copy will
still prompt.

## "It looks like you started an upgrade and booted from installation media"

The VM booted the install disc again after Setup's first reboot. winserver's QEMU backend prevents this by ejecting
the disc at that reboot, and the other backends put the disk first in the boot order. If you built the VM yourself
from `winserver iso` or the two discs, put the **hard disk before the CD** in its boot order: the empty disk is skipped
on the first boot.

To recover: power the VM off, detach the Windows ISO (keep the config disc), and start it again. If it then stops in
a UEFI shell, Setup did not get far enough to make the disk bootable: delete the VM and create it again.

## Setup asks a question, or stops at "Select the operating system"

The answer file didn't match the ISO. Check what's inside:

```bash
brew install wimlib    # lets winserver read editions instead of guessing
hdiutil attach -nobrowse -readonly your.iso
wimlib-imagex info "/Volumes/<label>/sources/install.wim"
```

Then recreate the VM with `--image-index N`. If Setup asks for a product key, pass `--product-key` with a key valid for
your media. For Insider builds, Microsoft publishes keys in each build's announcement.

## `winserver wait` never finishes (ARM64)

Almost always networking: without a network driver, sshd is unreachable. With VMware and Parallels, winserver also
needs the guest tools running to learn the VM's IP address (`winserver info <name>` shows "unknown yet" until then).

1. Open the VM window (or `winserver console` with `--vnc`) and log on with `winserver password <name> --show`.
2. Run `ipconfig`. No adapter means the virtio driver did not install. Try:
   ```powershell
   pnputil /enum-drivers | findstr /i netkvm
   Get-Content C:\ProgramData\winserver\firstboot.log
   ```
3. If Windows rejects the driver signature, please open an issue with the build number. As a workaround, recreate the
   VM with another NIC model, e.g. `--nic usb-net`, which Windows may drive with its inbox RNDIS driver.

## `winserver wait` never finishes (x64)

Emulated installs take 1-3 hours on an M-series Mac, longer with Desktop Experience. `wait` gives up after 8 hours.
Watch progress in the VM window or with `--vnc`. Use `--core`, give it `--cpus 6` or more, and close other heavy apps.

## "This version of Windows has expired" / restarts every hour

Insider Preview builds stop working on a fixed date. See [LICENSING.md](LICENSING.md). Run `winserver builds` to check
for a newer build, or use the x64 evaluation.

## `brew install qemu` fails: "Cellar is not writable"

Homebrew is owned by another user account on this Mac. Ask that user (or an admin) to run `brew install qemu`, or fix
ownership with `sudo chown -R $(whoami) $(brew --prefix)/*` if it's your Mac. Or use a hypervisor you already have
(`--backend vmware`, `parallels`, `virtualbox`). If you have QEMU somewhere else, point winserver at it:

```bash
export WINSERVER_QEMU_DIR=/path/to/qemu/bin        # where qemu-system-aarch64 and qemu-img live
export WINSERVER_QEMU_SHARE=/path/to/qemu/share/qemu   # where edk2-*.fd live
```

## VMware Fusion: "No PCIe slot available for Ethernet0"

Fixed in winserver: VMs created by older versions lack PCIe root ports. Delete and recreate the VM.

## Parallels: "prlctl cannot reach the Parallels service"

Open Parallels Desktop once (and sign in) so its background service runs, then retry. If it says to restart your Mac,
do that.

## VirtualBox: ARM64 guest doesn't boot

VirtualBox's ARM64 support on Apple Silicon is recent. Make sure you run 7.1 or later. If it still fails, use
`--backend qemu` or `--backend vmware`, and please open an issue with your VirtualBox version.

## "HV_UNSUPPORTED" or "hvf: not supported"

QEMU needs the `com.apple.security.hypervisor` entitlement, which Homebrew's build has. A QEMU you compiled yourself
must be signed with it (QEMU's build does this when it targets macOS). Also make sure you're not running inside
another VM.

## Remote Desktop: "unable to connect"

- Is the VM running and set up? `winserver list` should show `running` and `done`.
- RDP is forwarded to `127.0.0.1:<RDP_PORT>` only (see `winserver info <name>`).
- For a domain controller, the user is `DOMAIN\Administrator`.

## Not enough disk space

A VM disk grows up to its `--disk` size (default 64 GB; a fresh install uses 12-25 GB). `fetch arm64` needs ~20 GB
temporarily. VMs and ISOs live in `~/.winserver`; set `WINSERVER_HOME` to put them on an external drive.

## Reporting a bug

Please include: Mac model, macOS version, `qemu-system-aarch64 --version`, the ISO name (`winserver info <name>`),
`qemu.log`, and the guest logs if you can reach them.
