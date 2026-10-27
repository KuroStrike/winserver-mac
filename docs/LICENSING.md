# Licensing and what you are allowed to do

**Short version:** winserver ships no Microsoft software. It automates getting media from Microsoft and installing it.
You are responsible for complying with the license of whatever you install. This page explains what that means for
each path. It is not legal advice.

## ARM64: Windows Server Insider Preview builds

- Microsoft does not sell or offer a general-availability ARM64 edition of Windows Server for on-premises use.
  ARM64 builds are published through the **Windows Server Insider** program and served by Windows Update.
- `winserver fetch arm64` uses [UUP dump](https://uupdump.net) to list those builds and to build an ISO from the files,
  which it downloads **directly from Microsoft's servers**. Nothing is mirrored or redistributed by this project.
- Insider Preview builds are covered by the Windows Insider Program Agreement, which you accept when you
  [join the Windows Server Insider program](https://www.microsoft.com/windowsinsider/for-business-getting-started-server).
  They are pre-release software meant for evaluation and testing, **not for production**.
- **Every preview build expires.** Microsoft states an expiration date in each build's announcement. Build 26491
  (September 2025), for example, was announced to expire on **September 15, 2026**. After its date an expired build may
  warn, shut down periodically, or refuse to run. Check yours with `winver` in the guest. winserver does not and will
  not try to work around expiration: fetch a newer build when Microsoft publishes one.
- **Expired builds disappear.** Microsoft removes their files from Windows Update. In October 2026 that is the case for
  every ARM64 Server build (UUP dump answers `EMPTY_FILELIST`), so `fetch arm64` has nothing to build until a new ARM64
  preview ships. It checks automatically and tells you.

## x64: Windows Server 2025 Evaluation

- `winserver fetch x64` downloads the evaluation ISO from Microsoft's
  [Evaluation Center](https://www.microsoft.com/evalcenter/download-windows-server-2025) link.
- The evaluation is free for **180 days**, under Microsoft's evaluation license, and is meant for evaluation, not production.
  Microsoft documents how to convert an evaluation installation to a licensed edition if you own a license.
- Running it under emulation is slow but changes nothing about the license.

## Your own media

`--iso` accepts any Windows Server ISO. If you have licensed media (for example from a Visual Studio subscription or a
volume license agreement), the terms of that license apply, including whether virtualization on your hardware is allowed.

## Third-party components

| Component | Where it comes from | License |
|---|---|---|
| QEMU | Homebrew, installed by you | GPL-2.0 |
| VMware Fusion, Parallels Desktop, VirtualBox | Installed by you | Their own licenses; winserver only calls their command-line tools |
| VMware Tools, Parallels Tools, VirtualBox Guest Additions | Ship inside each hypervisor; attached to the VM, never copied | Their vendors' licenses |
| UEFI firmware (EDK II) | Ships with QEMU | BSD-2-Clause-Patent |
| UUP dump converter | Downloaded by `fetch arm64` from uupdump.net | See the [UUP dump project](https://git.uupdump.net/uup-dump) |
| virtio-win drivers | Downloaded from fedorapeople.org | BSD-3-Clause / GPL (see the virtio-win package) |
| wimlib, aria2, cabextract, cdrtools, chntpw | Homebrew, installed by you | Their respective licenses |

winserver itself is MIT-licensed; see [LICENSE](../LICENSE).
