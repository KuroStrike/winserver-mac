# Hypervisors

winserver does the Windows part (media, answer file, drivers, guest tools, first-boot setup) the same way everywhere.
Only creating and running the VM differs. Four hypervisors are automated end to end, and every other one is covered by a
single unattended ISO.

| | ARM64 Windows Server on Apple Silicon | x64 Windows Server on Apple Silicon | Intel Mac (x64) |
|---|---|---|---|
| **QEMU** (`--backend qemu`, free) | Native speed (HVF) | Emulated (TCG), slow but works | Native (HVF) |
| **VMware Fusion** (`--backend vmware`, free for personal use) | Native | Not possible | Native |
| **Parallels Desktop** (`--backend parallels`) | Native | Not supported | Native |
| **VirtualBox 7.1+** (`--backend virtualbox`, free) | Native (experimental in VirtualBox) | Not possible | Native |
| **UTM, Hyper-V, Proxmox, VMware Workstation, bare metal…** | `winserver iso` | UTM: `winserver iso` (emulated) | `winserver iso` |

Without `--backend`, winserver uses QEMU if it is installed, otherwise the first of VMware Fusion, Parallels and
VirtualBox that it finds. `winserver doctor` shows what's installed.

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

## VMware Fusion

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

## Parallels Desktop

```bash
winserver create srv01 --backend parallels
```

- Uses `prlctl`, which ships with Parallels Desktop. Open Parallels once (and sign in) so its service is running.
- Avoids Parallels' "Express installation", which would fight the answer file.
- First boot installs **Parallels Tools** from the ISO inside the app (network driver, IP reporting).
- Connections go to the VM's IP on Parallels' shared network.

## VirtualBox

```bash
winserver create srv01 --backend virtualbox
```

- Needs VirtualBox 7.1 or later. ARM64 guests on Apple Silicon are still young in VirtualBox; report what you see.
- UEFI, NVMe disk, AHCI CD drives, NAT with the same `127.0.0.1` port forwards as QEMU.
- ARM64 uses a virtio network card (driver from virtio-win on the config disc); x64 uses the Intel PRO/1000.
- First boot installs the **Guest Additions**, trusting Oracle's certificates first so the silent install doesn't stop at a prompt.

## UTM

UTM is QEMU underneath, so the QEMU backend gives the same result. To use UTM's interface instead:

```bash
winserver create srv01 --backend manual
winserver iso srv01
```

In UTM: Create a New Virtual Machine → Virtualize (ARM64 ISO) or Emulate (x64 ISO) → Windows → **uncheck** "Install
drivers and SPICE tools" and "Import VHDX" → Boot ISO image: the `srv01-unattended.iso` that `winserver iso` built.
Pick at least 4 GB of RAM and a 64 GB disk. Before the first start, open the VM's settings and drag the disk
above the CD drive in the Drives list, so the installer doesn't boot again after Setup's first reboot. Setup runs on its own. On ARM64 the virtio network driver is already on the
disc. Connect with Remote Desktop to the IP that UTM shows.

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
