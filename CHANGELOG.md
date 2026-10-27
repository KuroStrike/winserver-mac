# Changelog

## 0.1.2 (2026-10-27)

Security and polish, from a full audit of 0.1.1 on real installs.

- Security: Windows Setup keeps a copy of the answer file, `C:\Windows\Panther\unattend-original.xml`, with the
  Administrator password base64-encoded and readable by every local user (on a DC, that is the domain admin and DSRM
  password). It is now deleted at the end of setup. **VMs set up by 0.1.0 or 0.1.1: delete it yourself**
  (`winserver ssh <name> -- 'Remove-Item C:\Windows\Panther\unattend-original.xml'`).
- Security: `C:\ProgramData\winserver` was readable and writable by local users while setup ran, including the
  scripts that the logon task runs as Administrator. It is now limited to Administrators and SYSTEM.
- Security: QEMU's VNC console (`--vnc`) had no password, so any local user could type into it. It now has its own
  random password, which `winserver console` passes to Screen Sharing.
- `--script examples/ad-lab-seed.ps1` (or just `--script ad-lab-seed.ps1`) works from any folder, so the README's
  domain controller recipe works when winserver is installed with Homebrew.
- `doctor` says when Parallels is installed but its service isn't running, instead of a green check.
- `builds` no longer claims Microsoft still serves the builds it lists; `doctor` describes mkisofs correctly.
- README: a Security section, and which cells of the compatibility table are proven on real installs.
  An issue template for reports.

## 0.1.1 (2026-10-27)

Domain controllers verified end to end under QEMU (about 37 minutes, with the `ad-lab-seed.ps1` example), and the
problems that test turned up are fixed.

- QEMU: the guest clock was off by the gap between the guest's time zone and the Mac's after every `start` (an hour
  with the default UTC on a Mac in Paris), and a domain controller never corrected it. New VMs get a UTC hardware
  clock and Windows is told so (`RealTimeIsUniversal`). VMs created by 0.1.0 keep their old behaviour.
- Domain controllers sync the domain's time from `time.windows.com` instead of trusting their own clock.
- Domain controllers start sshd late after a reboot: it used to answer before the DC could log anyone on, so the
  first `winserver ssh` after `wait` was refused.
- QEMU sockets of a non-default `WINSERVER_HOME` get their own folder. Two homes with a VM of the same name (the test
  suite and your real VMs, for instance) used to share sockets, and one could take over or delete the other's.
- `stop` waits up to 5 minutes for emulated VMs (it was 2), and the install warning gives measured times.
- The domain promotion's output is kept in `firstboot.log`.

## 0.1.0 (2026-10-27)

First public version. Verified end to end with Windows Server 2025 Evaluation under QEMU on an M4 Pro
(about 22 minutes from `create` to RDP/SSH/WinRM).

- Unattended Windows Server installs on Apple Silicon: ARM64 at native speed, or the official x64 evaluation under
  QEMU emulation.
- Backends: QEMU, VMware Fusion, Parallels Desktop, VirtualBox, and `manual` for any other hypervisor.
- `winserver iso`: one bootable ISO with the answer file, scripts and drivers, which boots without "Press any key".
- Install discs are rebuilt once around Microsoft's `efisys_noprompt.bin`. On QEMU, the install disc is ejected at
  Setup's first reboot (QMP), so the installer never boots twice.
- First boot: virtio drivers, VMware Tools / Parallels Tools / VirtualBox Guest Additions, RDP, WinRM, ping,
  OpenSSH with your key (firewall opened on every network profile), Windows features, optional Active Directory
  forest, custom PowerShell.
- `fetch arm64` skips builds Microsoft no longer serves and says so when none are left; works without chntpw.
- Test suite with fake ISOs and stub hypervisors; shellcheck and PowerShell syntax checks in CI.
