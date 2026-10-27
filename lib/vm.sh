# shellcheck shell=bash
# VM lifecycle (create, start, wait, stop, list, info, delete), connecting
# (rdp, ssh, console, password) and the doctor. Hypervisor specifics live in
# lib/backends/<name>.sh; everything here goes through be().

BACKENDS="qemu vmware parallels virtualbox manual"

# Everything stored in vm.conf. load_vm/save_vm round-trip exactly these keys.
VM_KEYS="NAME BACKEND ARCH ISO BOOT_ISO TOOLS_ISO IMAGE_INDEX EDITION EXPERIENCE CPUS MEMORY DISK_SIZE
HOSTNAME_WIN UI_LANG LOCALE KEYBOARD TIMEZONE PRODUCT_KEY ROLE DOMAIN NETBIOS FEATURES NIC MAC CPU_MODEL RTC
RDP_PORT SSH_PORT WINRM_PORT VNC_PORT INSTALLED CREATED"

# Call the loaded VM's backend: be start gui 0  ->  be_qemu_start gui 0
be() {
  local fn="be_${BACKEND}_$1"
  shift
  "$fn" "$@"
}

load_vm() {
  local k
  VM_DIR="$VMS_DIR/$1"
  [ -f "$VM_DIR/vm.conf" ] || die "no VM named '$1' (see 'winserver list')"
  for k in $VM_KEYS; do eval "$k=''"; done
  # shellcheck disable=SC1091
  . "$VM_DIR/vm.conf"
  BACKEND="${BACKEND:-qemu}"     # VMs created before backends existed
  BOOT_ISO="${BOOT_ISO:-$ISO}"
}

save_vm() {
  local k v tmp
  tmp="$(mktemp "$VM_DIR/vm.conf.XXXXXX")"
  for k in $VM_KEYS; do
    eval "v=\${$k:-}"
    printf '%s=%q\n' "$k" "$v" >>"$tmp"
  done
  mv "$tmp" "$VM_DIR/vm.conf"
}

vm_running() { be running; }

need_name() {
  if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then die "missing VM name"; fi
}

valid_vm_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' || return 1
  printf '%s' "$1" | grep -Eq '[A-Za-z]'
}

admin_user() {
  if [ "$ROLE" = ad-dc ]; then echo "$NETBIOS\\Administrator"; else echo "Administrator"; fi
}

# First 4 bytes the guest's sshd sends ("SSH-" once it is up). A port forward
# accepts connections even when nothing listens in the guest, so a plain
# connect test is not enough.
ssh_banner() {
  ( b=""
    exec 3<>"/dev/tcp/$1/$2" || exit 0
    IFS= read -r -t 5 -n 4 b <&3 || true
    printf '%s' "$b" ) 2>/dev/null || true
}

# Pick a backend for an architecture from what is installed.
choose_backend() {
  local arch="$1" b
  if [ -n "$(qemu_path "$arch")" ]; then echo qemu; return 0; fi
  if [ "$arch" = arm64 ] || [ "$(host_arch)" = x86_64 ]; then
    for b in vmware parallels virtualbox; do
      if "be_${b}_available"; then echo "$b"; return 0; fi
    done
  fi
  return 1
}

print_access() {
  local addr
  addr="$(be address)"
  echo
  if [ -z "$addr" ]; then
    dim "  The VM's address shows up once guest tools are running (winserver wait $NAME)."
  fi
  printf '  %sRemote Desktop%s  winserver rdp %s      (%s:%s, user %s)\n' "$C_BLD" "$C_RST" "$NAME" "${addr:-<vm-ip>}" "$(be port rdp)" "$(admin_user)"
  printf '  %sSSH%s             winserver ssh %s      (%s:%s, PowerShell)\n' "$C_BLD" "$C_RST" "$NAME" "${addr:-<vm-ip>}" "$(be port ssh)"
  printf '  %sWinRM%s           http://%s:%s/wsman\n' "$C_BLD" "$C_RST" "${addr:-<vm-ip>}" "$(be port winrm)"
  printf '  %sPassword%s        winserver password %s  (copies it to the clipboard)\n' "$C_BLD" "$C_RST" "$NAME"
  echo
}

# ---------------------------------------------------------------- create

create_usage() {
  cat <<'EOF'
Usage: winserver create <name> [options]

Hypervisor
  --backend NAME         qemu, vmware, parallels, virtualbox or manual
                         (default: QEMU if installed, else the first of VMware Fusion,
                         Parallels, VirtualBox that is; 'manual' only prepares the discs)

Media
  --iso FILE             Windows Server ISO (default: newest from 'winserver fetch')
  --arch arm64|x64       Guest architecture (default: taken from the ISO)
  --edition NAME         datacenter (default) or standard
  --core | --desktop     Server Core or Desktop Experience
                         (default: --desktop on arm64, --core on x64, which is emulated on Apple Silicon)
  --image-index N        Pick the install.wim image yourself
  --product-key KEY      Only if your media asks for one

Hardware
  --cpus N               Virtual CPUs (default: 4)
  --memory SIZE          RAM, e.g. 4G (default: 4G)
  --disk SIZE            Disk size; the file grows as needed (default: 64G)
  --nic MODEL            QEMU only: virtio (arm64 default) or e1000e (x64 default)
  --cpu-model MODEL      QEMU x64 only: CPU model for emulation (default: max)

Windows
  --hostname NAME        Computer name (default: the VM name)
  --password PW          Administrator password (default: random, see 'winserver password')
  --locale xx-XX         Regional format (default: the ISO language)
  --keyboard xx-XX       Keyboard layout (default: same as --locale)
  --timezone "ZONE"      Windows time zone ID (default: "UTC")
  --ssh-key FILE         Public key allowed to SSH in (default: ~/.ssh/id_ed25519.pub or similar)
  --no-ssh-key           Password-only SSH

Roles
  --domain NAME          Promote to the first domain controller of a new forest (e.g. lab.local)
  --netbios NAME         NetBIOS domain name (default: first label of --domain, upper case)
  --feature A[,B]        Windows features to install (Install-WindowsFeature names); repeatable
  --script FILE.ps1      Your own PowerShell, run at the end of setup (after domain promotion)

Run
  --headless             No window; use RDP, SSH or --vnc
  --vnc                  QEMU only: also expose a VNC console (see 'winserver console')
  --no-start             Create only
EOF
}

cmd_create() {
  local name="" backend="" arch="" iso="" edition="datacenter" experience="" index="" key=""
  local cpus=4 memory="4G" disk="64G" nic="" cpu_model=""
  local hostname="" password="" locale="" keyboard="" timezone="UTC"
  local ssh_key="" no_ssh_key=0 domain="" netbios="" features="" script=""
  local headless=0 vnc=0 no_start=0
  local mnt iso_arch images lang k

  while [ $# -gt 0 ]; do
    case "$1" in
      --backend)      backend="$(lower "${2:?}")"; shift 2 ;;
      --config-only)  backend=manual; shift ;;
      --iso)          iso="${2:?}"; shift 2 ;;
      --arch)         arch="$(lower "${2:?}")"; shift 2 ;;
      --edition)      edition="$(lower "${2:?}")"; shift 2 ;;
      --core)         experience=core; shift ;;
      --desktop)      experience=desktop; shift ;;
      --image-index)  index="${2:?}"; shift 2 ;;
      --product-key)  key="${2:?}"; shift 2 ;;
      --cpus)         cpus="${2:?}"; shift 2 ;;
      --memory)       memory="$(upper "${2:?}")"; shift 2 ;;
      --disk)         disk="$(upper "${2:?}")"; shift 2 ;;
      --nic)          nic="${2:?}"; shift 2 ;;
      --cpu-model)    cpu_model="${2:?}"; shift 2 ;;
      --hostname)     hostname="${2:?}"; shift 2 ;;
      --password)     password="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --keyboard)     keyboard="${2:?}"; shift 2 ;;
      --timezone)     timezone="${2:?}"; shift 2 ;;
      --ssh-key)      ssh_key="${2:?}"; shift 2 ;;
      --no-ssh-key)   no_ssh_key=1; shift ;;
      --domain)       domain="$(lower "${2:?}")"; shift 2 ;;
      --netbios)      netbios="$(upper "${2:?}")"; shift 2 ;;
      --feature|--features) features="${features:+$features,}${2:?}"; shift 2 ;;
      --script)       script="${2:?}"; shift 2 ;;
      --headless)     headless=1; shift ;;
      --vnc)          vnc=1; shift ;;
      --no-start)     no_start=1; shift ;;
      -h|--help)      create_usage; return 0 ;;
      -*)             die "unknown option '$1' (see 'winserver create --help')" ;;
      *)              [ -z "$name" ] || die "unexpected argument '$1'"; name="$1"; shift ;;
    esac
  done

  # -- validate
  need_name "$name"
  valid_vm_name "$name" || die "VM name must be 1-15 letters, digits or '-', and contain a letter (it becomes the Windows computer name)"
  [ ! -e "$VMS_DIR/$name" ] || die "a VM named '$name' already exists"
  case "$backend" in ""|qemu|vmware|parallels|virtualbox|manual) ;; *) die "--backend must be one of: $BACKENDS" ;; esac
  case "$edition" in datacenter|standard) ;; *) die "--edition must be datacenter or standard" ;; esac
  case "$arch" in ""|arm64|x64) ;; aarch64) arch=arm64 ;; amd64|x86_64) arch=x64 ;; *) die "--arch must be arm64 or x64" ;; esac
  case "$cpus" in ''|*[!0-9]*) die "--cpus must be a number" ;; esac
  size_to_mib "$memory" >/dev/null || die "--memory must look like 4G or 4096M"
  size_to_mib "$disk" >/dev/null || die "--disk must look like 64G"
  [ "$(size_to_mib "$memory")" -ge 2048 ] || die "Windows Server needs at least 2G of memory"
  hostname="$(upper "${hostname:-$name}")"
  valid_vm_name "$hostname" || die "--hostname must be 1-15 letters, digits or '-'"
  if [ -n "$domain" ]; then
    printf '%s' "$domain" | grep -Eq '^[a-z0-9-]+(\.[a-z0-9-]+)+$' || die "--domain must look like lab.local"
    netbios="${netbios:-$(upper "${domain%%.*}" | cut -c1-15)}"
    [ "$netbios" != "$hostname" ] || die "the computer name and the NetBIOS domain name must differ (both are $hostname)"
  fi
  [ -z "$script" ] || [ -f "$script" ] || die "--script: no such file $script"

  # -- media
  if [ -z "$iso" ]; then
    if [ -n "$arch" ]; then
      iso="$(cached_iso "$arch")"
    else
      # Prefer native ARM64 media, otherwise whatever has been fetched.
      iso="$(cached_iso arm64)"
      [ -n "$iso" ] || iso="$(cached_iso x64)"
    fi
    [ -n "$iso" ] || die "no ${arch:-Windows Server} ISO yet. Run 'winserver fetch ${arch:-x64}' or pass --iso FILE"
  fi
  [ -f "$iso" ] || die "no such ISO: $iso"
  iso="$(cd "$(dirname "$iso")" && pwd)/$(basename "$iso")"

  info "Inspecting $(basename "$iso")…"
  mnt="$(iso_mount "$iso")"
  [ -n "$mnt" ] || die "could not mount $iso"
  if [ ! -f "$mnt/sources/install.wim" ] && [ ! -f "$mnt/sources/install.esd" ]; then
    iso_unmount "$mnt"
    die "$(basename "$iso") is not a Windows install ISO (no sources/install.wim)"
  fi
  iso_arch="$(iso_arch_from_boot "$mnt")"
  images="$(iso_images "$mnt" || true)"
  iso_unmount "$mnt"

  [ "$iso_arch" != unknown ] || die "cannot tell the architecture of $(basename "$iso")"
  if [ -n "$arch" ] && [ "$arch" != "$iso_arch" ]; then
    die "--arch $arch does not match the ISO, which is $iso_arch"
  fi
  arch="$iso_arch"
  if [ "$arch" = arm64 ] && [ "$(host_arch)" != arm64 ]; then
    die "ARM64 guests need an Apple Silicon Mac"
  fi
  experience="${experience:-$([ "$arch" = arm64 ] && echo desktop || echo core)}"
  nic="${nic:-$([ "$arch" = arm64 ] && echo virtio || echo e1000e)}"

  if [ -z "$index" ]; then
    if [ -n "$images" ]; then
      index="$(pick_image "$images" "$edition" "$experience")"
      [ -n "$index" ] || die "this ISO has no $edition $experience image. Images found:
$(printf '%s\n' "$images" | awk -F'\t' '{printf "  %s  %s (%s)\n", $1, $6, $4}')"
      lang="$(printf '%s\n' "$images" | awk -F'\t' -v i="$index" '$1 == i {print $5}')"
    else
      # Without wimlib, assume the layout of Microsoft's media:
      # 1 Standard Core, 2 Standard Desktop, 3 Datacenter Core, 4 Datacenter Desktop.
      warn "wimlib not installed; guessing the image index (brew install wimlib to be sure)"
      index=1
      [ "$experience" = desktop ] && index=$((index + 1))
      [ "$edition" = datacenter ] && index=$((index + 2))
    fi
  fi
  lang="${lang:-en-US}"
  locale="${locale:-$lang}"
  keyboard="${keyboard:-$locale}"

  if [ "$no_ssh_key" = 0 ] && [ -z "$ssh_key" ]; then
    for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
      if [ -f "$k" ]; then ssh_key="$k"; break; fi
    done
  fi
  [ -z "$ssh_key" ] || [ -f "$ssh_key" ] || die "--ssh-key: no such file $ssh_key"

  # -- hypervisor
  if [ -z "$backend" ]; then
    backend="$(choose_backend "$arch")" || die "no hypervisor found for $arch guests. Install QEMU (brew install qemu),
or use --backend manual and 'winserver iso' to get media for any hypervisor."
  fi
  for k in $VM_KEYS; do eval "$k=''"; done
  NAME="$name"; BACKEND="$backend"; ARCH="$arch"
  be require

  # -- write the VM
  VM_DIR="$VMS_DIR/$name"
  mkdir -p "$VM_DIR" "$RUN_DIR"
  chmod 700 "$VM_DIR"
  ISO="$iso"; IMAGE_INDEX="$index"
  EDITION="$edition"; EXPERIENCE="$experience"; CPUS="$cpus"; MEMORY="$memory"; DISK_SIZE="$disk"
  HOSTNAME_WIN="$hostname"; UI_LANG="$lang"; LOCALE="$locale"; KEYBOARD="$keyboard"; TIMEZONE="$timezone"
  PRODUCT_KEY="$key"; FEATURES="$features"; NIC="$nic"; MAC="$(gen_mac)"; CPU_MODEL="$cpu_model"
  if [ -n "$domain" ]; then ROLE=ad-dc; DOMAIN="$domain"; NETBIOS="$netbios"; fi
  # QEMU has no guest tools to set the clock: give it a UTC hardware clock, and
  # the answer file tells Windows so. Other hypervisors' tools keep time.
  if [ "$BACKEND" = qemu ]; then RTC=utc; fi
  # Separate ranges, so the four ports of one VM can never collide with each other.
  RDP_PORT="$(find_free_port 33890)"
  SSH_PORT="$(find_free_port 22220)"
  WINRM_PORT="$(find_free_port 59850)"
  VNC_PORT="$(find_free_port 5910)"
  INSTALLED=0
  CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  BOOT_ISO="$ISO"
  TOOLS_ISO="$(be tools_iso)"
  save_vm

  ( umask 077; printf '%s' "${password:-$(gen_password)}" >"$VM_DIR/password" )
  [ -z "$ssh_key" ] || cp "$ssh_key" "$VM_DIR/authorized_keys"
  [ -z "$script" ] || cp "$script" "$VM_DIR/custom.ps1"

  info "Building the config disc (answer file, first-boot scripts, drivers)…"
  build_config_iso

  if [ "$BACKEND" = manual ]; then
    ok "Media ready for $NAME."
    echo
    echo "  In any hypervisor, create a UEFI VM (Secure Boot off, 2+ vCPU, 4 GB RAM, 64 GB disk), then either:"
    echo "    a) attach two CD drives:  $ISO"
    echo "                              $VM_DIR/config.iso"
    echo "       and press a key at 'Press any key to boot from CD or DVD', or"
    echo "    b) run 'winserver iso $NAME' and attach the single ISO it builds (no keypress needed)."
    echo "  Setup runs unattended. Administrator password: winserver password $NAME"
    echo "  Docs: docs/HYPERVISORS.md"
    echo
    return 0
  fi

  if be needs_noprompt; then
    BOOT_ISO="$(noprompt_iso "$ISO")"
    save_vm
  fi
  be create

  ok "Created $NAME on $(be describe): $arch, $edition $experience (image $index), $cpus vCPU, $memory RAM, $disk disk"
  [ -z "$ROLE" ] || ok "Will become the first domain controller of $DOMAIN ($NETBIOS)"
  [ -z "$ssh_key" ] || dim "  SSH key: $ssh_key"
  if [ "$arch" = x64 ] && [ "$(host_arch)" = arm64 ]; then
    warn "x64 Windows runs under full emulation on Apple Silicon: the install takes 20-40 min with 8 vCPUs (longer with fewer, or with the desktop), and the desktop is slow."
  fi

  if [ "$no_start" = 0 ]; then
    local start_args=()
    [ "$headless" = 1 ] && start_args+=(--headless)
    [ "$vnc" = 1 ] && start_args+=(--vnc)
    cmd_start "$name" ${start_args[@]+"${start_args[@]}"}
  else
    dim "  Start it with: winserver start $NAME"
  fi
}

# ---------------------------------------------------------------- start / wait / stop

cmd_start() {
  local name="" display=gui vnc=0 press=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --headless)    display=headless; shift ;;
      --vnc)         vnc=1; shift ;;
      --press-enter) press=1; shift ;;
      -h|--help)     echo "Usage: winserver start <name> [--headless] [--vnc] [--press-enter]"; return 0 ;;
      -*)            die "unknown option '$1'" ;;
      *)             name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  ! vm_running || die "'$NAME' is already running"
  if [ "$INSTALLED" != 1 ]; then
    [ -f "$BOOT_ISO" ] || die "install ISO is gone: $BOOT_ISO"
    [ -f "$VM_DIR/config.iso" ] || build_config_iso
  fi
  if [ "$vnc" = 1 ] && [ "$BACKEND" != qemu ]; then warn "--vnc is only supported with the QEMU backend"; vnc=0; fi

  info "Starting $NAME ($ARCH, $CPUS vCPU, $MEMORY) on $(be describe)…"
  be start "$display" "$vnc" "$press"

  if [ "$INSTALLED" != 1 ]; then
    ok "Windows Setup is running unattended."
    dim "  Follow it in the VM window, or run: winserver wait $NAME"
  else
    print_access
  fi
}

cmd_wait() {
  local name="" timeout="" start now elapsed last=-1 addr port
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:?}"; shift 2 ;;
      -h|--help) echo "Usage: winserver wait <name> [--timeout MINUTES]"; return 0 ;;
      -*)        die "unknown option '$1'" ;;
      *)         name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  if [ -z "$timeout" ]; then
    if [ "$ARCH" = x64 ] && [ "$(host_arch)" = arm64 ]; then timeout=480; else timeout=120; fi
  fi
  vm_running || die "'$NAME' is not running (winserver start $NAME)"

  start="$(date +%s)"
  info "Waiting for $NAME to finish setting up (up to $timeout min)…"
  while :; do
    addr="$(be address)"
    port="$(be port ssh)"
    if [ -n "$addr" ]; then
      case "$(ssh_banner "$addr" "$port")" in SSH-*) break ;; esac
    fi
    vm_running || die "'$NAME' stopped before setup finished"
    now="$(date +%s)"
    elapsed=$(((now - start) / 60))
    [ "$elapsed" -lt "$timeout" ] || die "still not ready after $timeout minutes. Look at the VM window, or C:\\ProgramData\\winserver\\*.log inside it."
    if [ $((elapsed % 5)) -eq 0 ] && [ "$elapsed" -ne "$last" ]; then
      dim "  … ${elapsed} min"
      last="$elapsed"
    fi
    sleep 15
  done
  now="$(date +%s)"
  if [ "$INSTALLED" != 1 ]; then
    INSTALLED=1
    save_vm
    be eject
    ok "$NAME is ready after $(((now - start) / 60)) min. The install discs are detached."
  else
    ok "$NAME is up."
  fi
  print_access
}

cmd_stop() {
  local name="" force=0 timeout="" i=0 addr
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --timeout)  timeout="${2:?}"; shift 2 ;;
      -h|--help)  echo "Usage: winserver stop <name> [--force] [--timeout SECONDS]"; return 0 ;;
      -*)         die "unknown option '$1'" ;;
      *)          name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  if ! vm_running; then ok "$NAME is not running"; return 0; fi
  if [ -z "$timeout" ]; then
    # An emulated shutdown takes 75-110 s on an M4 Pro.
    if [ "$ARCH" = x64 ] && [ "$(host_arch)" = arm64 ]; then timeout=300; else timeout=120; fi
  fi

  [ "$force" = 1 ] || info "Asking Windows to shut down…"
  be stop "$force"
  while vm_running; do
    sleep 1; i=$((i + 1))
    # Halfway through, try a clean shutdown over SSH (works when a key was installed).
    if [ "$force" = 0 ] && [ $i -eq $((timeout / 2)) ] && [ "$INSTALLED" = 1 ]; then
      addr="$(be address)"
      if [ -n "$addr" ]; then
        ssh -p "$(be port ssh)" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$VM_DIR/known_hosts" -o LogLevel=ERROR \
          "Administrator@$addr" "Stop-Computer -Force" >/dev/null 2>&1 || true
      fi
    fi
    [ $i -lt "$timeout" ] || die "$NAME is still running after ${timeout}s. Use: winserver stop $NAME --force"
  done
  ok "$NAME stopped"
}

# ---------------------------------------------------------------- list / info / delete

cmd_list() {
  local conf state found=0
  printf '%s%-16s %-10s %-6s %-9s %-8s %-26s%s\n' "$C_BLD" NAME BACKEND ARCH STATE SETUP IMAGE "$C_RST"
  for conf in "$VMS_DIR"/*/vm.conf; do
    [ -f "$conf" ] || continue
    found=1
    load_vm "$(basename "$(dirname "$conf")")"
    if [ "$BACKEND" = manual ]; then state=manual
    elif vm_running; then state=running
    else state=stopped
    fi
    printf '%-16s %-10s %-6s %-9s %-8s %-26s\n' "$NAME" "$BACKEND" "$ARCH" "$state" \
      "$([ "$INSTALLED" = 1 ] && echo "done" || echo pending)" \
      "$EDITION $EXPERIENCE${ROLE:+ ($ROLE)}"
  done
  [ "$found" = 1 ] || dim "No VMs yet. Create one with: winserver create <name>"
}

cmd_info() {
  local name="${1:-}" addr
  need_name "$name"
  load_vm "$name"
  printf '%-14s %s\n' Name "$NAME" Backend "$BACKEND" State "$(vm_running && echo running || echo stopped)" \
    Architecture "$ARCH" Image "$EDITION $EXPERIENCE (index $IMAGE_INDEX)" ISO "$ISO" \
    Hardware "$CPUS vCPU, $MEMORY RAM, $DISK_SIZE disk" \
    Hostname "$HOSTNAME_WIN" Locale "$LOCALE (keyboard $KEYBOARD, $TIMEZONE)"
  [ "$BOOT_ISO" = "$ISO" ] || printf '%-14s %s\n' "Boot ISO" "$BOOT_ISO"
  [ -z "$TOOLS_ISO" ] || printf '%-14s %s\n' "Guest tools" "$TOOLS_ISO"
  [ -z "$ROLE" ] || printf '%-14s %s\n' Role "$ROLE: $DOMAIN ($NETBIOS)"
  [ -z "$FEATURES" ] || printf '%-14s %s\n' Features "$FEATURES"
  addr="$(be address)"
  printf '%-14s %s\n' Setup "$([ "$INSTALLED" = 1 ] && echo "done" || echo pending)" \
    Address "${addr:-unknown yet}" \
    Ports "RDP $(be port rdp), SSH $(be port ssh), WinRM $(be port winrm)" \
    Folder "$VM_DIR" Created "$CREATED"
}

cmd_delete() {
  local name="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      -*)       die "unknown option '$1'" ;;
      *)        name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  if [ "$yes" = 0 ]; then
    confirm "Delete VM '$NAME' and its disk ($VM_DIR)?" || die "cancelled"
  fi
  if vm_running; then cmd_stop "$NAME" --force; fi
  be destroy
  case "$VM_DIR" in "$VMS_DIR"/?*) rm -rf "$VM_DIR" ;; *) die "refusing to delete $VM_DIR" ;; esac
  ok "Deleted $NAME"
}

# ---------------------------------------------------------------- connect

# Address of a running VM, or die explaining why there is none.
need_address() {
  local addr
  vm_running || die "'$NAME' is not running (winserver start $NAME)"
  addr="$(be address)"
  [ -n "$addr" ] || die "no address for '$NAME' yet; guest tools report it once setup is done (winserver wait $NAME)"
  printf '%s' "$addr"
}

cmd_rdp() {
  local name="${1:-}" rdp addr
  need_name "$name"
  load_vm "$name"
  addr="$(need_address)"
  rdp="$VM_DIR/$NAME.rdp"
  cat >"$rdp" <<EOF
full address:s:$addr:$(be port rdp)
username:s:$(admin_user)
prompt for credentials on client:i:1
screen mode id:i:1
dynamic resolution:i:1
smart sizing:i:1
desktopwidth:i:1600
desktopheight:i:1000
session bpp:i:32
audiomode:i:0
redirectclipboard:i:1
EOF
  if [ -z "$(mdfind "kMDItemCFBundleIdentifier == 'com.microsoft.rdc.macos'" 2>/dev/null | head -n 1)" ]; then
    warn "Microsoft's Windows App doesn't seem to be installed. Get it from the App Store:"
    dim  "  https://apps.apple.com/app/windows-app/id1295203466"
  fi
  pbcopy <"$VM_DIR/password"
  ok "Password copied to the clipboard. Opening Remote Desktop to $addr:$(be port rdp)…"
  open "$rdp"
}

cmd_ssh() {
  local name="${1:-}" addr
  need_name "$name"
  shift
  [ "${1:-}" = "--" ] && shift
  load_vm "$name"
  addr="$(need_address)"
  [ -f "$VM_DIR/authorized_keys" ] || dim "Password: run 'winserver password $NAME' in another terminal."
  exec ssh -p "$(be port ssh)" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$VM_DIR/known_hosts" -o LogLevel=ERROR \
    "Administrator@$addr" "$@"
}

cmd_console() {
  local name="${1:-}"
  need_name "$name"
  load_vm "$name"
  [ "$BACKEND" = qemu ] || die "use $(be describe)'s own window for the console"
  vm_running || die "'$NAME' is not running"
  port_in_use "$VNC_PORT" || die "no VNC console. Start the VM with: winserver start $NAME --vnc"
  open "vnc://127.0.0.1:$VNC_PORT"
}

cmd_password() {
  local name="" show=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --show) show=1; shift ;;
      -*)     die "unknown option '$1'" ;;
      *)      name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  if [ "$show" = 1 ]; then cat "$VM_DIR/password"; echo; return 0; fi
  pbcopy <"$VM_DIR/password"
  ok "Administrator password for $NAME copied to the clipboard (use --show to print it)"
}

# ---------------------------------------------------------------- doctor

cmd_doctor() {
  local missing="" bin share fw ram free a b c
  row() { printf '  %s %-22s %s\n' "$1" "$2" "$3"; }
  yes_() { row "${C_GRN}✓${C_RST}" "$1" "$2"; }
  no_()  { row "${C_RED}✗${C_RST}" "$1" "$2"; }
  meh_() { row "${C_YEL}!${C_RST}" "$1" "$2"; }

  echo "${C_BLD}This Mac${C_RST}"
  if [ "$(host_arch)" = arm64 ]; then
    yes_ "Apple Silicon" "$(sysctl -n machdep.cpu.brand_string)"
  else
    meh_ "Intel Mac" "x64 guests run with hardware acceleration; ARM64 guests are not possible"
  fi
  yes_ "macOS" "$(sw_vers -productVersion)"
  ram=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if [ "$ram" -ge 16 ]; then yes_ "Memory" "${ram} GiB"; else meh_ "Memory" "${ram} GiB (8+ GiB free recommended per VM)"; fi
  free="$(free_gib "$WINSERVER_HOME")"
  if [ "$free" -ge 40 ]; then yes_ "Free disk" "${free} GiB"; else meh_ "Free disk" "${free} GiB (a VM takes 15-30 GiB, an ISO ~6 GiB)"; fi

  echo; echo "${C_BLD}Hypervisors${C_RST}"
  for a in arm64 x64; do
    bin="$(qemu_path "$a")"
    if [ -n "$bin" ]; then
      share="$(qemu_share_dir "$bin" 2>/dev/null || true)"
      fw="$share/$(firmware_code "$a")"
      if [ -f "$fw" ]; then
        yes_ "QEMU ($a guests)" "$("$bin" --version | head -n 1 | sed 's/.*version //')"
      else
        no_ "QEMU ($a guests)" "missing firmware $(firmware_code "$a")"
      fi
    else
      no_ "QEMU ($a guests)" "not found (brew install qemu)"; missing="$missing qemu"
    fi
  done
  for b in vmware parallels virtualbox; do
    if "be_${b}_available"; then yes_ "$b" "$("be_${b}_describe")"; else dim "  - $b                 not installed"; fi
  done
  if [ "$(host_arch)" = arm64 ]; then
    dim "  On Apple Silicon only QEMU runs x64 Windows (emulated); all of them run ARM64 Windows."
  fi

  echo; echo "${C_BLD}Media tools${C_RST}"
  if has wimlib-imagex; then yes_ "wimlib" "reads editions from any ISO"; else meh_ "wimlib" "recommended"; missing="$missing wimlib"; fi
  if has mkisofs || has genisoimage; then yes_ "mkisofs" "for 'winserver iso' and non-QEMU backends"; else meh_ "mkisofs" "needed for 'winserver iso' and VMware/Parallels/VirtualBox"; missing="$missing cdrtools"; fi
  for c in aria2c cabextract; do
    if has "$c"; then yes_ "$c" "for 'fetch arm64'"; else meh_ "$c" "needed for 'fetch arm64'"; fi
  done
  has aria2c || missing="$missing aria2"
  has cabextract || missing="$missing cabextract"

  echo; echo "${C_BLD}Connecting${C_RST}"
  if [ -n "$(mdfind "kMDItemCFBundleIdentifier == 'com.microsoft.rdc.macos'" 2>/dev/null | head -n 1)" ]; then
    yes_ "Windows App" "for Remote Desktop"
  else
    meh_ "Windows App" "install from the App Store for 'winserver rdp'"
  fi
  if has python3; then yes_ "python3" "found"; else no_ "python3" "run: xcode-select --install"; fi

  echo
  # shellcheck disable=SC2086  # word-split the list on purpose
  missing="$(printf '%s\n' $missing | sort -u | tr '\n' ' ')"
  if [ -n "${missing// /}" ]; then
    echo "Install what's missing with:"
    echo "  brew install $missing"
  else
    ok "All set."
  fi
}
