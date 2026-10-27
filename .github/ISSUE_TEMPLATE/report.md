---
name: Report how it went
about: It worked, or it didn't. Both help, especially for VMware, Parallels, VirtualBox and ARM64.
---

**Mac and macOS** (e.g. MacBook Pro M3 Pro, macOS 26.1):

**winserver version** (`winserver version`):

**`winserver doctor` output:**

```
```

**What you ran:**

```
winserver create …
```

**What happened** (did it work, how long did it take, where did it stop?):

**Logs, if it failed:** `~/.winserver/vms/<name>/qemu.log` on the Mac, and inside Windows
`C:\ProgramData\winserver\firstboot.log` and `post-setup.log`.

Please don't paste passwords: `~/.winserver/vms/<name>/password` and `config.iso` contain one, the logs don't.
