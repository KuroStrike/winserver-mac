# Changelog

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
