# winserver-mac

**Windows Server on Apple Silicon Macs, in the hypervisor you already use. One command, fully unattended.**

```bash
winserver fetch x64                            # official Windows Server 2025 evaluation ISO, from Microsoft
winserver create dc01 --domain lab.local       # unattended install, promoted to a domain controller
winserver wait dc01 && winserver rdp dc01      # when setup is done: Remote Desktop, password in your clipboard
```

"You can't run Windows Server on an M-series Mac" is *almost* true. Microsoft sells Windows Server for x64, and Apple
Silicon hypervisors virtualize ARM. `winserver` handles everything that's still possible, end to end:

- **x64 Windows Server 2025** (official evaluation) under emulation with QEMU. Slow, but real, and it works today.
- **ARM64 Windows Server** at native speed in **QEMU, VMware Fusion, Parallels or VirtualBox**, from Insider builds or your own media.
- **Any other hypervisor** (UTM, Hyper-V, Proxmox, VMware Workstation, even a USB stick): `winserver iso` builds a single
  ISO that installs everything with no clicks and no keypress.

| On Apple Silicon | ARM64 Windows Server | x64 Windows Server |
|---|---|---|
| QEMU (free) | ✅ native speed | ✅ emulated, slow |
| VMware Fusion (free for personal use) | ✅ native speed | ❌ impossible on Apple Silicon |
| Parallels Desktop | ✅ native speed | ❌ |
| VirtualBox 7.1+ | ✅ native (experimental in VirtualBox) | ❌ |
| UTM and anything else | ✅ `winserver iso` | ✅ UTM (emulated) via `winserver iso` |

On an Intel Mac, every backend runs x64 Windows Server at full speed. Details per hypervisor: [docs/HYPERVISORS.md](docs/HYPERVISORS.md).

> [!WARNING]
> **ARM64 media, October 2026.** Microsoft publishes ARM64 Windows Server only as Insider Preview builds, and pulls them
> from Windows Update once they expire. As of today **none are downloadable**: the newest, 26501 (October 2025), is gone,
> and the 2026 Server previews are x64-only. `winserver fetch arm64` checks and picks up new ARM64 builds as soon as
> Microsoft serves them. Until then, use ARM64 media you already have (`--iso`), or the x64 evaluation.
> See [docs/LICENSING.md](docs/LICENSING.md).

## What you get

- Windows Server installed with **no clicks**: edition, disk layout, language, keyboard, time zone, computer name and
  Administrator password all come from an answer file. The installer never waits for "Press any key".
- **Remote Desktop**, **SSH** (PowerShell, with your Mac's SSH key) and **WinRM** turned on
- The right drivers and **guest tools** for the hypervisor: virtio, VMware Tools, Parallels Tools or VirtualBox Guest Additions
- Optional: an **Active Directory** forest with DNS (`--domain`), any Windows feature (`--feature Web-Server`),
  your own PowerShell (`--script`)
- `winserver rdp`, `ssh`, `password`, `wait`, `stop`: no hunting for IPs, ports or passwords

## Install

```bash
brew install kurostrike/tap/winserver   # also installs wimlib and cdrtools
winserver doctor                        # shows what's installed and what's missing
```

Requirements: macOS 13+, [Homebrew](https://brew.sh), 8 GB+ RAM (16 GB recommended), ~40 GB free disk. Then add
what your setup needs:

```bash
brew install qemu                 # for the QEMU backend (skip it if you use VMware, Parallels or VirtualBox)
brew install aria2 cabextract     # only for 'winserver fetch arm64'
```

Or install from a clone, which tracks `main` (`git pull` updates the command):

```bash
git clone https://github.com/KuroStrike/winserver-mac.git
cd winserver-mac
make install                      # links bin/winserver into ~/.local/bin (PREFIX=... to change)
brew install wimlib cdrtools      # read ISOs, build prompt-free and all-in-one ISOs
```

For `winserver rdp`, install Microsoft's [Windows App](https://apps.apple.com/app/windows-app/id1295203466).

## Quick start

**x64 evaluation with QEMU (works today):**

```bash
winserver fetch x64                     # ~6 GB from Microsoft
winserver create srv01 --headless --cpus 8   # Server Core by default: the desktop is painful when emulated
winserver wait srv01                    # ~22 min on an M4 Pro with 8 vCPUs
winserver ssh srv01
```

**ARM64 at native speed, in the hypervisor of your choice:**

```bash
winserver fetch arm64                   # when Microsoft serves an ARM64 build, or bring your own with --iso
winserver create srv01 --backend vmware # or qemu, parallels, virtualbox
winserver wait srv01
winserver rdp srv01
```

**Anything else: one unattended ISO.**

```bash
winserver create srv01 --backend manual --core
winserver iso srv01                     # boot ~/.winserver/vms/srv01/srv01-unattended.iso anywhere
```

## Recipes

```bash
# Active Directory lab: new forest + DNS, then OUs, groups and test users from the example script
winserver create dc01 --domain lab.local --script examples/ad-lab-seed.ps1

# IIS web server on Server Core
winserver create web01 --feature Web-Server --core

# Your keyboard, region and time zone
winserver create srv01 --locale fr-FR --keyboard fr-FR --timezone "Romance Standard Time"

# Headless QEMU, watch the install over VNC
winserver create srv01 --headless --vnc && winserver console srv01

# Any Windows Server ISO: architecture and editions are read from it
winserver create srv01 --iso ~/Downloads/server.iso --edition standard --desktop
```

## Commands

| Command | What it does |
|---|---|
| `doctor` | Checks for hypervisors, tools, firmware and disk space |
| `builds` | Lists ARM64 Windows Server builds UUP dump knows about |
| `fetch arm64 [--build ID] [--lang en-us]` | Builds an ARM64 ISO from Microsoft's servers (newest build still served) |
| `fetch x64` | Downloads the Windows Server 2025 Evaluation ISO |
| `create <name> [--backend …] [options]` | Creates a VM and starts the unattended install (`--help` lists every option) |
| `iso <name>` | Builds one unattended, prompt-free ISO for any hypervisor |
| `start <name> [--headless]` / `stop <name> [--force]` | Power on, clean shutdown or hard stop |
| `wait <name>` | Returns when setup is done and SSH answers |
| `list` / `info <name>` | Your VMs, and how each is set up |
| `rdp` / `ssh` / `password` / `console` `<name>` | Connect |
| `delete <name>` | Removes the VM (and its registration in the hypervisor) |

Everything lives in `~/.winserver` (set `WINSERVER_HOME` to move it, e.g. to an external disk).

## How it works

1. **Media.** `fetch x64` downloads Microsoft's evaluation ISO. `fetch arm64` asks [UUP dump](https://uupdump.net) which
   ARM64 Server builds exist, checks which ones Microsoft still serves, and runs UUP dump's converter to build an ISO
   from files downloaded straight from Windows Update. Nothing is redistributed.
2. **Prompt-free boot.** The ISO is rebuilt once around Microsoft's own `efisys_noprompt.bin`, so it boots straight into
   Setup with no keypress, in any hypervisor.
3. **Config disc.** The editions inside the ISO are read with wimlib, and a small second disc carries `autounattend.xml`,
   the first-boot scripts, your SSH key and drivers. `winserver iso` merges all of it into a single disc instead.
4. **VM.** The backend creates the VM in QEMU, VMware Fusion, Parallels or VirtualBox, with UEFI, an NVMe disk, and the
   hypervisor's guest tools attached.
5. **First boot.** A one-time logon installs drivers and guest tools, enables RDP, WinRM and ping, adds features,
   promotes the domain controller, runs your script, and starts OpenSSH last. When `winserver wait` sees an SSH
   banner, the server is ready.

Details: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Status

What has actually been verified (on an M4 Pro, macOS 26.7, October 2026):

- [x] **x64 Windows Server 2025 Evaluation, end to end under QEMU 11.1 (emulated), in ~22 minutes**: prompt-free boot,
  answer file applied, install disc ejected at Setup's first reboot, first-boot scripts, then Remote Desktop (NLA),
  SSH with key login into PowerShell, and WinRM all reachable from the Mac
- [x] VMware Fusion 13.6.2 creates and powers on VMs generated by `winserver`
- [x] Automated test suite: 129 checks covering every command and every backend, with fake ISOs and stub hypervisors,
  plus shellcheck and PowerShell syntax checks. Runs in CI.
- [ ] Domain controller promotion (`--domain`) on a real install
- [ ] ARM64 install: needs ARM64 media, which Microsoft doesn't serve right now
- [ ] Parallels and VirtualBox on real installs: not available on the test machine. Reports welcome!

Tried it? Please [open an issue](https://github.com/KuroStrike/winserver-mac/issues) with your Mac, macOS, hypervisor
and what happened, whether it worked or not.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Contributing

Pull requests are welcome, especially new backends and real-world reports. Run `make test` (macOS) and `make lint`
(shellcheck) first. The code targets the bash 3.2 that ships with macOS: no associative arrays, no `${var,,}`.
A backend is one file in `lib/backends/` implementing a dozen small `be_<name>_*` functions; `qemu.sh` documents the list.

## Credits

[QEMU](https://www.qemu.org), [UUP dump](https://git.uupdump.net/uup-dump),
[virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows), [wimlib](https://wimlib.net),
[cdrtools](https://codeberg.org/schilytools/schilytools), and the [UTM](https://mac.getutm.app) community's work on Windows guests.

Windows and Windows Server are trademarks of Microsoft. VMware Fusion, Parallels Desktop and VirtualBox are trademarks
of their owners. This project is not affiliated with any of them.

## License

[MIT](LICENSE)
