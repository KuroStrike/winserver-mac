# Hypervisors

winserver does the Windows part (media, answer file, drivers, guest tools, first-boot setup) the same way everywhere.
Only creating and running the VM differs. It is built around free and open-source hypervisors: **QEMU** and **UTM**
(QEMU in a Mac app) are automated end to end, VirtualBox is too, and every other hypervisor is covered by a single
unattended ISO. VMware Fusion and Parallels Desktop work as optional extras for people who already use them.

| | ARM64 on Apple Silicon | x64 on Apple Silicon | Intel Mac (x64) | Verified on a real install |
|---|---|---|---|---|
| **QEMU** (`--backend qemu`, GPL) | Native speed (HVF) | Emulated (TCG), slow but works | Native (HVF) | ARM64 and x64, server and DC |
| **UTM** (`--backend utm`, Apache-2.0) | Native (Apple Hypervisor) | Emulated | Native | ARM64 |
| **VirtualBox 7.1+** (`--backend virtualbox`, GPL core) | Native (experimental in VirtualBox) | Not possible | Native | ARM64 |
| **UTM's window, Hyper-V, Proxmox, bare metal…** | `winserver iso` | `winserver iso` (emulated) | `winserver iso` | |
| VMware Fusion (`--backend vmware`, proprietary, free for personal use) | Native | Not possible | Native | ARM64 |
| Parallels Desktop Pro/Business (`--backend parallels`, proprietary) | Native | Not supported | Native | no (see below) |

Without `--backend`, winserver uses QEMU if it is installed, then UTM, then the first of VirtualBox, VMware Fusion and
Parallels that it finds. `winserver doctor` shows what's installed.

## Two ways to deliver the setup

**Two discs** (used by the backends): the Windows ISO plus a small `config.iso` with the answer file, scripts and
drivers. Windows Setup finds the answer file on the second disc by itself.

**One disc** (`winserver iso <name>`): the Windows ISO rebuilt with the same payload at its root. Attach it as the VM's
only CD and start. Nothing else to do.

Either way, the Windows disc is rebuilt once to boot through Microsoft's `efisys_noprompt.bin`, so it never stops at
"Press any key to boot from CD or DVD". This needs `mkisofs` (`brew install cdrtools`). The rebuilt copy is cached in
`~/.winserver/cache/iso/noprompt/` and shared by every VM made from that ISO.

## QEMU

```bash
brew install qemu
winserver create srv01                  # --backend qemu is the default when QEMU is installed
```

- Only option for x64 Windows on Apple Silicon (full emulation).
- Networking: user-mode NAT with port forwards on `127.0.0.1` (RDP 33890+, SSH 22220+, WinRM 59850+). No admin rights needed.
- Console: a Cocoa window, or `--headless --vnc` and `winserver console`.
- Drivers: virtio-win (network, balloon…) on ARM64; x64 uses devices Windows has inbox drivers for.
- On ARM64, Device Manager lists about 33 devices without a driver (`ACPI\LNRO0005`, `ACPI\QEMU0002`). They are the
  empty virtio-mmio slots and the firmware-config device of QEMU's `virt` machine: harmless, every Windows guest on it has them.

## UTM

```bash
brew install --cask utm                 # or download it from https://mac.getutm.app
winserver create srv01 --backend utm    # chosen by default when QEMU itself isn't installed
```

- [UTM](https://mac.getutm.app) is QEMU in a Mac app, free and open source. winserver creates the VM through UTM's
  scripting interface, named `winserver-srv01`, and drives it with `utmctl`: it shows in UTM's window like any other.
  The first time, macOS asks whether your terminal may control UTM: allow it.
- ARM64 runs at native speed with the Apple Hypervisor; x64 is emulated, as with QEMU.
- NVMe disk listed before the install and config discs (USB CD drives on ARM64), so the firmware boots Windows from
  the disk after Setup's first reboot. At the next `start` after setup, winserver detaches both discs.
- Networking: QEMU's user-mode NAT with RDP, SSH and WinRM forwarded on `127.0.0.1` (33890+, 22220+, 59850+), as with
  the QEMU backend. The hardware clock is UTC, and the answer file tells Windows so.
- UTM is sandboxed and keeps references to the ISOs, not copies: don't move `~/.winserver` while a VM still needs its
  install discs.
- Prefer clicking? `winserver create srv01 --backend manual && winserver iso srv01`, then in UTM: Create a New Virtual
  Machine → Virtualize (ARM64) or Emulate (x64) → Windows → uncheck "Install drivers and SPICE tools" → boot ISO image:
  `srv01-unattended.iso`. Before the first start, drag the disk above the CD drive in the VM's Drives list.

## VirtualBox

```bash
winserver create srv01 --backend virtualbox
```

- Needs VirtualBox 7.1 or later (verified with 7.2.22). ARM64 guests on Apple Silicon are still young in VirtualBox,
  and a little slower to install than with QEMU or UTM.
- UEFI, one SATA (AHCI) controller with the disk first and the CD drives after it, as VirtualBox itself sets up
  Windows 11 on ARM. (With the disk on NVMe, Windows Setup on ARM stalls at "Searching for disks".)
- NAT with the same `127.0.0.1` port forwards as QEMU; a UTC hardware clock, and the answer file tells Windows so.
- ARM64 uses a virtio network card (driver from virtio-win on the config disc); x64 uses the Intel PRO/1000.
  No OHCI USB controller (Windows on ARM has no driver for it); mouse and keyboard use xHCI.
- First boot installs the **Guest Additions**, trusting Oracle's certificates first so the silent install doesn't stop at a prompt.
- `stop` asks Windows to shut down through the Guest Additions (first boot starts their service right away): on ARM,
  VirtualBox's ACPI power button shows in Device Manager as a resource conflict (`ACPI0011`) and does nothing.

## VMware Fusion (optional)

```bash
winserver create srv01 --backend vmware
```

- Creates `~/.winserver/vms/srv01/srv01.vmwarevm`, which you can also open in the Fusion window.
- UEFI, NVMe disk, SATA CD drives, vmxnet3 network on NAT.
- First boot installs **VMware Tools** from Fusion's own tools ISO, which brings the ARM64 network driver.
- winserver finds the VM's IP address through VMware Tools, or else in the leases of Fusion's NAT DHCP server
  (`/var/db/vmware/vmnet-dhcpd-vmnet8.leases`). On Apple Silicon the second is the one that works: VMware Tools for
  Windows on ARM (12.4) don't report the address to `vmrun`. `winserver rdp`/`ssh` connect to that IP on the standard ports.
- `stop` uses a soft power-off; `--force` is a hard one.

## Parallels Desktop (optional, Pro or Business edition)

```bash
winserver create srv01 --backend parallels
```

- Needs **Parallels Desktop Pro or Business**: in the Standard and App Store editions, `prlctl` may not create, start,
  stop or query VMs ("available only in Parallels Desktop for Mac Pro or Business Edition"), so winserver can't
  drive them. winserver says so and points to `winserver iso` instead.
- Tested with the App Store edition 1.26.4 through the GUI and `winserver iso`: Windows installs unattended to the
  desktop in about 7 minutes, but gets **no network**, because Parallels' virtio network card needs Parallels Tools,
  which the GUI path doesn't attach. Not verified end to end, then; reports from Pro users welcome.
- Open Parallels once (and sign in) so its service is running. Don't close the VM window during setup: the default
  "suspend on close" loses the sandboxed app's access to the ISO.

## Anything else

`winserver iso` produces a normal bootable ISO. Use it in Hyper-V (Generation 2, Secure Boot off),
Proxmox (OVMF, q35), VMware Workstation, GNOME Boxes, or write it to a USB stick for real hardware.

1. `winserver create srv01 --backend manual [--core] [--domain lab.local] …`
2. `winserver iso srv01`, then copy `~/.winserver/vms/srv01/srv01-unattended.iso` wherever you need it.
3. Create a UEFI VM with 2+ vCPUs, 4 GB RAM and a 64 GB disk, attach the ISO, and put the **disk before the CD** in
   the boot order (the empty disk is skipped on the first boot; afterwards it keeps the VM from booting the
   installer again). Start it.
4. Optional: attach the hypervisor's guest tools ISO as a second CD; first boot installs VMware Tools,
   Parallels Tools or VirtualBox Guest Additions when it finds them.
5. Administrator password: `winserver password srv01`.

The ISO contains your Administrator password (encoded, not encrypted). Treat it like the password itself.
