# shellcheck shell=bash
# UTM backend: the free, open-source Mac app built on QEMU (Apache-2.0),
# driven through its scripting interface (osascript) and utmctl.
#
#   arm64 guest  -> Apple Hypervisor, native speed
#   x64 guest    -> QEMU emulation, slow (like the QEMU backend)
#
# The VM lives in UTM's library, named winserver-<name>, and shows in UTM's
# window. Networking is QEMU's user-mode NAT with RDP, SSH and WinRM forwarded
# on 127.0.0.1, as with the QEMU backend.

utm_app() {
  local a
  for a in "${WINSERVER_UTM_APP:-}" /Applications/UTM.app "$HOME/Applications/UTM.app"; do
    if [ -n "$a" ] && [ -d "$a" ]; then echo "$a"; return; fi
  done
}
utmctl_bin()    { echo "${WINSERVER_UTMCTL:-$(utm_app)/Contents/MacOS/utmctl}"; }
utmctl_()       { "$(utmctl_bin)" "$@"; }
utm_osascript() { "${WINSERVER_OSASCRIPT:-osascript}" "$WINSERVER_ROOT/lib/backends/$1" "${@:2}"; }
utm_vm()        { echo "winserver-$NAME"; }

be_utm_available() { [ -x "$(utmctl_bin)" ]; }
be_utm_describe() {
  printf 'UTM %s' "$(defaults read "$(utm_app)/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
}
be_utm_needs_noprompt() { return 0; }    # nothing presses a key at the boot prompt
be_utm_tools_iso() { :; }                # virtio drivers come on the config disc

be_utm_require() {
  be_utm_available || die "UTM not found. Get it free from https://mac.getutm.app (or: brew install --cask utm)"
}

be_utm_create() {
  local arch hv nic disp id
  if [ "$ARCH" = arm64 ]; then
    arch=aarch64; nic=virtio-net-pci; disp=ramfb    # virtio driver on the config disc
  else
    arch=x86_64; nic=e1000e; disp=VGA               # inbox drivers
  fi
  # Guests of the Mac's own architecture use the Apple Hypervisor; others are emulated.
  hv=false
  case "$(host_arch)/$ARCH" in arm64/arm64|x86_64/x64) hv=true ;; esac
  id="$(utm_osascript utm-create.applescript "$(utm_vm)" "$arch" "$(size_to_mib "$MEMORY")" "$CPUS" "$hv" \
    "$(size_to_mib "$DISK_SIZE")" "$nic" "$disp" "$RDP_PORT" "$SSH_PORT" "$WINRM_PORT" \
    "$BOOT_ISO" "$VM_DIR/config.iso" 2>&1)" || die "UTM could not create $(utm_vm): $id"
  printf '%s\n' "$id" >"$VM_DIR/utm.id"
}

be_utm_running() {
  case "$(utmctl_ status "$(utm_vm)" 2>/dev/null)" in started|starting|resuming) return 0 ;; esac
  return 1
}

be_utm_start() {
  local display="$1" hide=""
  if [ "$INSTALLED" = 1 ]; then
    # Like ejecting: the config disc holds the password, and setup is done.
    utm_osascript utm-eject.applescript "$(utm_vm)" >/dev/null 2>&1 || warn "could not detach the install discs in UTM"
  fi
  [ "$display" = headless ] && hide=--hide
  utmctl_ start $hide "$(utm_vm)" >/dev/null || die "UTM could not start $(utm_vm)"
  ok "Running in UTM"
}

be_utm_stop() {
  if [ "$1" = 1 ]; then utmctl_ stop --force "$(utm_vm)"; else utmctl_ stop --request "$(utm_vm)"; fi >/dev/null 2>&1 || true
}

be_utm_eject() { :; }    # the next start detaches the discs (UTM can't while running)
be_utm_destroy() { utmctl_ delete "$(utm_vm)" >/dev/null 2>&1 || true; }
be_utm_address() { echo 127.0.0.1; }
be_utm_port() {
  case "$1" in rdp) echo "$RDP_PORT" ;; ssh) echo "$SSH_PORT" ;; winrm) echo "$WINRM_PORT" ;; esac
}
