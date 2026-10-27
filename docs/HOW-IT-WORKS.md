# How winserver works

```
  winserver fetch            winserver create                      first boot (inside Windows)
 ─────────────────┐         ┌───────────────────────────┐        ┌──────────────────────────────┐
 Microsoft servers│         │ read editions (wimlib)     │        │ firstboot.ps1                │
   │  UUP files   │         │ render autounattend.xml    │        │   drivers, RDP, WinRM        │
   ▼              │         │ config.iso  ───────────────┼──CD 2─▶│   features, domain promotion │
 UUP dump convert │  ISO    │ disk.qcow2 + UEFI vars     │        │ post-setup.ps1               │
   → install ISO ─┼────────▶│ qemu (HVF or TCG) ─────────┼──CD 1─▶│   your script, then sshd     │
 ─────────────────┘         └───────────────────────────┘        └──────────────┬───────────────┘
                                                                                 │ "SSH-2.0…" on
                                  winserver wait  ◀──────────────────────────────┘ 127.0.0.1:2222x
```

## 1. Install media

### ARM64

Microsoft builds Windows Server for ARM64 and serves Insider Preview builds of it through Windows Update as *UUP*
(Unified Update Platform) files: compressed packages, not an ISO. [UUP dump](https://uupdump.net) indexes those builds
and provides a converter that turns the files into a bootable ISO.

`winserver fetch arm64`:

1. Calls the UUP dump API for the newest full **Windows Server** build with `arch = arm64`.
2. Checks that your language and the Standard / Datacenter editions (Core and Desktop) are available.
3. Downloads UUP dump's conversion package (a small zip with `uup_download_macos.sh`) and runs it. The script uses
   `aria2c` to download the UUP files from Microsoft's CDN, then `cabextract`, `wimlib` and `mkisofs` to build the ISO.
4. Moves the ISO to `~/.winserver/cache/iso/winserver-arm64-<build>-<lang>.iso`.

### x64

`winserver fetch x64` follows Microsoft's `go.microsoft.com/fwlink` redirect to the Windows Server 2025 Evaluation ISO
and downloads it with resume support.

## 2. The config disc

Windows Setup searches the root of every removable and CD drive for `autounattend.xml`. So instead of rebuilding a
6 GB ISO, winserver builds a tiny second disc (`config.iso`, volume label `WSCONFIG`) containing:

| File | Purpose |
|---|---|
| `autounattend.xml` | Rendered from `templates/autounattend.xml` |
| `firstboot.ps1`, `post-setup.ps1` | Run at the first logon |
| `settings.ps1` | Role, domain, features for this VM |
| `drivers/` | ARM64 virtio drivers (NetKVM, viostor, vioscsi, Balloon, vioserial, viorng) |
| `authorized_keys` | Your SSH public key, if any |
| `custom.ps1` | Your `--script`, if any |
| `winserver.tag` | Marker so the first-logon command can find this disc |

### Picking the right image

An `install.wim` holds several images (Standard Core, Standard Desktop, Datacenter Core…). winserver reads them with
`wimlib-imagex info` and matches *Edition ID* (`ServerDatacenter`, `ServerStandardEval`…) and *Installation Type*
(`Server Core` vs `Server`). The index goes into `/IMAGE/INDEX` in the answer file. The ISO's language becomes the setup
language, and the architecture comes from the UEFI boot loader on the disc (`bootaa64.efi` or `bootx64.efi`).

### The answer file

- **windowsPE**: language, disk layout (EFI 260 MB, MSR 16 MB, Windows on the rest of disk 0), image index,
  `DriverPaths` pointing at `X:\drivers` for every likely drive letter (ARM64 only), dynamic update off.
- **specialize**: computer name, time zone, Remote Desktop on and its firewall group enabled, Server Manager not opened at logon.
- **oobeSystem**: Administrator password, one automatic logon, and a `FirstLogonCommands` entry that looks for
  `winserver.tag` on drives D: to M: and runs `firstboot.ps1` from there.

Passwords use Setup's `PlainText=false` encoding: base64 of UTF-16LE *password + field name*. That keeps them out of
plain sight but is **not** encryption. `config.iso` and the `password` file are `chmod 600`.

## 3. The virtual machine

### ARM64 (`qemu-system-aarch64`)

| Option | Why |
|---|---|
| `-machine virt -accel hvf -cpu host` | Apple Hypervisor.framework: the guest runs on the real CPU cores |
| UEFI `edk2-aarch64-code.fd` + per-VM vars | Windows on ARM boots only via UEFI |
| `-device ramfb` | A plain UEFI framebuffer. Windows has no driver for QEMU's PCI GPUs on ARM, and the Basic Display driver works with this |
| `-device nvme` | Windows has an inbox NVMe driver, so no storage driver is needed during setup |
| `usb-storage` CD drives | The virt machine has no SATA/IDE. Windows' inbox USB mass-storage driver reads them |
| `virtio-net-pci` | Fast networking. The driver comes from virtio-win via the config disc |
| `usb-kbd`, `usb-tablet` | Input with absolute pointer, so the mouse isn't captured |

### x64 (`qemu-system-x86_64`)

`-machine q35` with UEFI, NVMe disk, AHCI CD drives and an `e1000e` NIC. Windows has inbox drivers for all of them, so no
extra drivers are needed. On Apple Silicon it uses `-accel tcg,thread=multi`: multi-threaded binary translation, one host
thread per virtual CPU. That works, but every x86 instruction is translated, hence the slowness. On an Intel Mac it uses HVF.

### Other hypervisors

VMware Fusion, Parallels and VirtualBox are driven through `vmrun`, `prlctl` and `VBoxManage`. Each backend is one file in
`lib/backends/` implementing the same small interface (create, start, running, stop, eject, destroy, address, port…).
They attach the hypervisor's own guest tools ISO as a third CD. See [HYPERVISORS.md](HYPERVISORS.md).

### Networking (QEMU)

QEMU's user-mode network (SLIRP): the guest is `10.0.2.15`, gateway `10.0.2.2`, DNS `10.0.2.3`, with outbound internet
access. Inbound access goes only through port forwards bound to `127.0.0.1`:

| Guest port | Host port (first VM) |
|---|---|
| 3389 RDP | 33890 |
| 22 SSH | 22220 |
| 5985 WinRM | 59850 |

No root, no kernel extensions, no bridged interfaces. The trade-off: VMs can't see each other (yet; see the roadmap
in the issues).

### "Press any key to boot from CD or DVD"

Microsoft's UEFI boot image on the disc (`efi/microsoft/boot/efisys.bin`) waits about 5 seconds for a key, otherwise
the firmware skips the disc. The same media also carries `efisys_noprompt.bin`, which boots straight into Setup.
winserver rebuilds the ISO once around that image with `mkisofs` (same layout as UUP dump's converter: UDF for the
large `install.wim`, El Torito entries for BIOS and UEFI), caches it in `~/.winserver/cache/iso/noprompt/`, and boots
every VM from it. No hypervisor has to type anything.

Pressing keys blindly does not work well, which is why: an arrow key gets past the prompt but then stops Windows
Boot Manager's countdown, and Enter gets past both but would hit Setup's **Cancel** button if it arrived too late.
Without `mkisofs`, the QEMU backend falls back to pressing Enter for a short window (15 s on ARM64, 60 s emulated),
which ends long before Setup's window appears.

The disk has boot priority over the CD, so once Windows is on it, reboots go straight to the installed system.

## 4. First boot and the "ready" signal

`firstboot.ps1` copies the payload to `C:\ProgramData\winserver`, installs the virtio drivers with `pnputil`, finds
the hypervisor (from the firmware's manufacturer string) and installs its guest tools from whichever tools disc is
attached (VMware Tools, Parallels Tools or VirtualBox Guest Additions), waits for an IPv4 address, enables RDP, ping and
WinRM, installs `--feature`s, and either:

- **member/standalone server**: runs `post-setup.ps1` right away, or
- **domain controller**: turns the DHCP lease into a static address (same IP, gateway and DNS), installs AD DS, registers a logon task and an automatic logon for
  `DOMAIN\Administrator`, and runs `Install-ADDSForest`, which reboots. After the reboot the task runs `post-setup.ps1`.
  A scheduled task is used instead of a `RunOnce` key because `RunOnce` is not processed on Server Core.

`post-setup.ps1` runs your `--script`, installs your SSH key into `administrators_authorized_keys`, makes PowerShell the
SSH shell, and **starts sshd last**. It then clears the automatic logon and deletes `settings.ps1`.

On the Mac, `winserver wait` opens a TCP connection to the SSH port every 15 seconds (the forwarded port on
127.0.0.1 for QEMU and VirtualBox, the VM's own IP as reported by guest tools for VMware and Parallels) and reads 4 bytes. QEMU
accepts the host side of a port forward even when nothing listens in the guest, so a plain connect proves nothing;
an `SSH-` banner proves sshd is really up. That's also why sshd must come up last.

Logs inside the guest: `C:\ProgramData\winserver\firstboot.log` and `post-setup.log`.
Logs on the Mac: `~/.winserver/vms/<name>/qemu.log`, and the exact QEMU command in `qemu.cmd`.
