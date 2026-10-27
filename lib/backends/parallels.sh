# shellcheck shell=bash
# Parallels Desktop backend, driven by prlctl. Runs ARM64 guests on Apple
# Silicon. The VM uses Parallels' shared network; winserver reaches it on its
# own IP address, which Parallels Tools (installed on first boot) reports.

PARALLELS_APP="${WINSERVER_PARALLELS_APP:-/Applications/Parallels Desktop.app}"

prlctl_bin() {
  if [ -n "${WINSERVER_PRLCTL:-}" ]; then echo "$WINSERVER_PRLCTL"; return; fi
  command -v prlctl 2>/dev/null || echo "$PARALLELS_APP/Contents/MacOS/prlctl"
}
prl_()    { "$(prlctl_bin)" "$@"; }
prl_vm()  { echo "winserver-$NAME"; }

be_parallels_available() { [ -x "$(prlctl_bin)" ]; }
be_parallels_describe() {
  printf 'Parallels Desktop %s' "$(defaults read "$PARALLELS_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
}
be_parallels_needs_noprompt() { return 0; }

be_parallels_tools_iso() {
  local iso
  case "$ARCH" in
    arm64) iso="$PARALLELS_APP/Contents/Resources/Tools/prl-tools-win-arm.iso" ;;
    x64)   iso="$PARALLELS_APP/Contents/Resources/Tools/prl-tools-win.iso" ;;
  esac
  if [ -f "$iso" ]; then echo "$iso"; fi
}

be_parallels_require() {
  be_parallels_available || die "Parallels Desktop not found at $PARALLELS_APP"
  if [ "$ARCH" = x64 ] && [ "$(host_arch)" = arm64 ]; then
    die "Parallels runs ARM64 guests on Apple Silicon. Use --backend qemu for x64 (emulated) or an ARM64 ISO."
  fi
  prl_ list >/dev/null 2>&1 || die "prlctl cannot reach the Parallels service. Open Parallels Desktop once (and sign in), then retry."
}

be_parallels_create() {
  local vm iso n=0
  vm="$(prl_vm)"
  prl_ create "$vm" --ostype windows --dst "$VM_DIR" --no-hdd >/dev/null || die "prlctl could not create $vm"
  prl_ set "$vm" --cpus "$CPUS" --memsize "$(size_to_mib "$MEMORY")" >/dev/null
  prl_ set "$vm" --device-add hdd --type expand --size "$(size_to_mib "$DISK_SIZE")" --iface nvme >/dev/null ||
    die "prlctl could not add the disk"
  for iso in "$BOOT_ISO" "$VM_DIR/config.iso" "$TOOLS_ISO"; do
    [ -n "$iso" ] || continue
    prl_ set "$vm" --device-add cdrom --image "$iso" --connect >/dev/null || die "prlctl could not attach $iso"
    n=$((n + 1))
  done
  prl_ set "$vm" --device-bootorder "hdd0 cdrom0" >/dev/null || true
}

be_parallels_running() { prl_ status "$(prl_vm)" 2>/dev/null | grep -q ' running'; }

be_parallels_start() {
  local display="$1" view=window
  [ "$display" = headless ] && view=headless
  prl_ set "$(prl_vm)" --startup-view "$view" >/dev/null 2>&1 || true
  prl_ start "$(prl_vm)" >/dev/null || die "prlctl could not start $(prl_vm)"
  ok "Running in Parallels Desktop"
}

be_parallels_stop() {
  if [ "$1" = 1 ]; then prl_ stop "$(prl_vm)" --kill; else prl_ stop "$(prl_vm)"; fi >/dev/null 2>&1 &
}

be_parallels_eject() {
  prl_ set "$(prl_vm)" --device-disconnect cdrom0 >/dev/null 2>&1 || true
  prl_ set "$(prl_vm)" --device-disconnect cdrom1 >/dev/null 2>&1 || true
}

be_parallels_destroy() { prl_ delete "$(prl_vm)" >/dev/null 2>&1 || true; }

be_parallels_address() {
  prl_ list -f -o name,ip_configured --no-header 2>/dev/null |
    awk -v vm="$(prl_vm)" '$1 == vm { split($2, a, ","); if (a[1] ~ /^[0-9]+\./) print a[1] }'
}

be_parallels_port() {
  case "$1" in rdp) echo 3389 ;; ssh) echo 22 ;; winrm) echo 5985 ;; esac
}
