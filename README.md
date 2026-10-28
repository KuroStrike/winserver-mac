# winserver-mac

**Windows Server on Apple Silicon Macs, with free and open-source tools. One command, fully unattended.**

```bash
winserver fetch x64                            # official Windows Server 2025 evaluation ISO, from Microsoft
winserver create dc01 --domain lab.local       # unattended install, promoted to a domain controller
winserver wait dc01 && winserver rdp dc01      # when setup is done: Remote Desktop, password in your clipboard
```

"You can't run Windows Server on an M-series Mac" is *almost* true. Microsoft sells Windows Server for x64, and Apple
Silicon hypervisors virtualize ARM. `winserver` handles everything that's still possible, end to end, on open-source
software: [QEMU](https://www.qemu.org) and [UTM](https://mac.getutm.app), the free Mac app built on it.

- **x64 Windows Server 2025** (official evaluation) under emulation. Slow, but real, and it works today.
- **ARM64 Windows** at native speed: Windows Server from Insider builds or your own media, and Windows 11.
- **Windows 11** ISOs work too (Pro, Enterprise, Education): a client next to your lab servers.
- **Any other hypervisor** (UTM's window, Hyper-V, Proxmox, even a USB stick): `winserver iso` builds a single ISO that
  installs everything with no clicks and no keypress.

| On Apple Silicon | ARM64 Windows | x64 Windows Server | Proven on a real install |
|---|---|---|---|
| **QEMU** (open source) | ✅ native speed | ✅ emulated, slow | ARM64, and x64 as server and DC |
| **UTM** (open source, QEMU in a Mac app) | ✅ native speed | ✅ emulated, slow | ARM64, x64 |
| **VirtualBox 7.1+** (open-source core) | ✅ native (experimental in VirtualBox) | ❌ | ARM64 |
| Anything else | ✅ `winserver iso` | ✅ `winserver iso` (emulated) | |

Also works, for people who already have them: **VMware Fusion** (proprietary, free for personal use; ARM64 proven) and
**Parallels Desktop** Pro or Business (proprietary; its Standard and App Store editions can't be scripted). On an Intel
Mac, every backend runs x64 at full speed. Details: [docs/HYPERVISORS.md](docs/HYPERVISORS.md).

The ARM64 results come from Microsoft's Windows 11 ARM64 ISO, since no ARM64 Server ISO can be downloaded today: same
installer, answer file, drivers and first boot (see [Status](#status)).

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
brew install qemu                 # the QEMU backend (command line)
brew install --cask utm           # and/or UTM, if you'd rather see your VMs in an app
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

**ARM64 at native speed, in UTM's window:**

```bash
winserver fetch arm64                   # when Microsoft serves an ARM64 build, or bring your own with --iso
winserver create srv01 --backend utm    # also: qemu, virtualbox (or vmware, parallels)
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
# (~37 min emulated; the users' password is in C:\ProgramData\winserver\lab-users.csv on the DC)
winserver create dc01 --domain lab.local --script examples/ad-lab-seed.ps1

# IIS web server on Server Core
winserver create web01 --feature Web-Server --core

# Your keyboard, region and time zone
winserver create srv01 --locale fr-FR --keyboard fr-FR --timezone "Romance Standard Time"

# Headless QEMU, watch the install over VNC
winserver create srv01 --headless --vnc && winserver console srv01

# Any Windows Server ISO: architecture and editions are read from it
winserver create srv01 --iso ~/Downloads/server.iso --edition standard --desktop

# Windows 11 from Microsoft's ISO (ARM64: microsoft.com/software-download/windows11arm64); Pro by default
winserver create w11 --iso ~/Downloads/Windows11_Client_arm64_en-us.iso --backend vmware
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
4. **VM.** The backend creates the VM in QEMU, UTM, VirtualBox, VMware Fusion or Parallels, with UEFI, an NVMe disk, and the
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
- [x] **Domain controller, end to end under QEMU, in ~37 minutes**: `create dc01 --domain lab.local --script
  examples/ad-lab-seed.ps1` gave a new forest at the Windows Server 2025 functional level, with DNS (SRV records, outside
  names resolved through forwarders), SYSVOL and NETLOGON shared, a static address, the time synced from
  `time.windows.com`, and 15 seeded users in their OUs and groups (logons checked with the generated password). SSH
  logs in as `LAB\Administrator` with your key; Remote Desktop (NLA) and WinRM answer.
- [x] **ARM64 with QEMU 11.1 (HVF), end to end in ~14 minutes**, with Microsoft's Windows 11 ARM64 ISO: prompt-free
  boot, answer file, disc ejected at the first reboot, virtio drivers, network, then RDP (NLA), SSH (key and password)
  and WinRM from the Mac
- [x] **ARM64 with UTM 5.0.8, end to end in ~12 minutes**, same ISO, through `--backend utm`: VM made through UTM's
  scripting interface, prompt-free boot, the disk booting first after Setup's reboot, virtio network, then RDP (NLA),
  SSH (key and password) and WinRM on `127.0.0.1`; then `stop`, `start` (install discs detached), `wait` and `ssh`,
  with the clock right on Tokyo time
- [x] **ARM64 with VMware Fusion 13.6.2, end to end in ~13 minutes**, same ISO: VMware Tools and the vmxnet3 driver
  installed on first boot, address found through Fusion's NAT, RDP, SSH and WinRM, then `stop`/`start`/`wait`/`ssh`
- [x] Automated test suite: 196 checks covering every command and every backend, with fake ISOs and stub hypervisors,
  plus shellcheck and PowerShell syntax checks. Runs in CI.
- [ ] ARM64 **Windows Server** itself: no ARM64 Server ISO is downloadable right now (see the warning above)
- [x] **x64 Windows Server 2025 with UTM (emulated), end to end in ~27 minutes**: RDP (NLA), SSH, WinRM, then `stop`,
  `start`, `wait`. Once, after a restart, PowerShell crashed inside Windows (`AccessViolationException`): emulated x64
  on ARM can surface such errors. Not reproduced; prefer ARM64, or the QEMU backend, for x64 work.
- [x] **Installed with Homebrew**, dependencies included (`brew install kurostrike/tap/winserver` in a fresh Homebrew
  owned by the user): `doctor`, `brew test`, and the domain controller recipe with the bundled seed script
- [x] **ARM64 with VirtualBox 7.2.22, end to end in ~18 minutes**, same ISO, through `--backend virtualbox`: disk on
  SATA, Guest Additions installed and running, virtio network, then RDP (NLA), SSH (key and password) and WinRM on
  `127.0.0.1`; `stop` through the Guest Additions in seconds, `start` (discs ejected), `wait`, `ssh`, `delete`,
  with the clock right on Tokyo time
- [ ] Parallels Desktop: tested with the App Store edition, which can't be scripted (Pro/Business only); through the
  GUI, Windows installed unattended but had no network without Parallels Tools. Reports from Pro users welcome.

Tried it? Please [open an issue](https://github.com/KuroStrike/winserver-mac/issues) with your Mac, macOS, hypervisor
and what happened, whether it worked or not.

## Security

winserver builds labs, not production servers. What it does with credentials and network access:

- Every VM gets its own random Administrator password, kept on the Mac in `~/.winserver/vms/<name>/password`
  (readable by you only) and shown by `winserver password`. On a domain controller it is also the domain
  Administrator's and the Directory Services Restore Mode password.
- QEMU, UTM and VirtualBox forward RDP, SSH and WinRM on `127.0.0.1` only; VMware and Parallels VMs sit on the
  hypervisor's private NAT network. Nothing is exposed to your LAN unless you change that yourself. QEMU's VNC console
  (`--vnc`) also listens on `127.0.0.1` only, with its own password, which `winserver console` passes for you.
- SSH accepts your Mac's key (`administrators_authorized_keys`) and the password. WinRM keeps Windows' defaults
  (HTTP with Negotiate/Kerberos, no Basic auth).
- When setup is done, no copy of the password is left in the guest: the automatic logon, `settings.ps1` and the copy
  of the answer file that Setup keeps in `C:\Windows\Panther` are deleted. `C:\ProgramData\winserver`, with the logs
  and scripts, is readable by administrators only. The example seed script's `lab-users.csv` holds the lab users'
  shared password.
- VMs set up by 0.1.0 or 0.1.1 still have Setup's copy, readable by every local user. Delete it:
  `winserver ssh <name> -- 'Remove-Item C:\Windows\Panther\unattend-original.xml'`

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
