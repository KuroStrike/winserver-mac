# shellcheck shell=bash
# VirtualBox backend, driven by VBoxManage (VirtualBox 7.1 or later).
# Apple Silicon: ARM64 guests only. Intel Macs: x64 guests.
# Networking is NAT with the same 127.0.0.1 port forwards as the QEMU backend.

VBOX_APP="${WINSERVER_VBOX_APP:-/Applications/VirtualBox.app}"

vbox_bin() {
  if [ -n "${WINSERVER_VBOXMANAGE:-}" ]; then echo "$WINSERVER_VBOXMANAGE"; return; fi
  command -v VBoxManage 2>/dev/null || echo "$VBOX_APP/Contents/MacOS/VBoxManage"
}
vbox_()  { "$(vbox_bin)" "$@"; }
vbox_vm() { echo "winserver-$NAME"; }

be_virtualbox_available() { [ -x "$(vbox_bin)" ]; }
be_virtualbox_describe() { printf 'VirtualBox %s' "$(vbox_ --version 2>/dev/null | cut -d r -f1)"; }
be_virtualbox_needs_noprompt() { return 0; }

be_virtualbox_tools_iso() {
  local iso="$VBOX_APP/Contents/MacOS/VBoxGuestAdditions.iso"
  if [ -f "$iso" ]; then echo "$iso"; fi
}

be_virtualbox_require() {
  be_virtualbox_available || die "VirtualBox not found (https://www.virtualbox.org)"
  if [ "$ARCH" = x64 ] && [ "$(host_arch)" = arm64 ]; then
    die "VirtualBox can't run x64 guests on Apple Silicon. Use --backend qemu (emulated) or an ARM64 ISO."
  fi
}

be_virtualbox_create() {
  local vm ostype gfx nic port=0 iso
  local platform=()
  vm="$(vbox_vm)"
  if [ "$ARCH" = arm64 ]; then
    ostype=Windows11_arm64; gfx=qemuramfb; nic=virtio; platform=(--platform-architecture arm)
  else
    ostype=Windows2022_64; gfx=vmsvga; nic=82540EM
  fi
  vbox_ createvm --name "$vm" --basefolder "$VM_DIR" --ostype "$ostype" ${platform[@]+"${platform[@]}"} --register >/dev/null ||
    die "VBoxManage could not create $vm"
  vbox_ modifyvm "$vm" --cpus "$CPUS" --memory "$(size_to_mib "$MEMORY")" --vram 64 \
    --firmware efi --graphicscontroller "$gfx" --mouse usbtablet --usb-xhci on \
    --boot1 disk --boot2 dvd --boot3 none --boot4 none --audio-enabled off \
    --nic1 nat --nic-type1 "$nic" --mac-address1 "$(printf '%s' "$MAC" | tr -d ':' | tr '[:lower:]' '[:upper:]')" \
    --nat-pf1 "rdp,tcp,127.0.0.1,$RDP_PORT,,3389" \
    --nat-pf1 "ssh,tcp,127.0.0.1,$SSH_PORT,,22" \
    --nat-pf1 "winrm,tcp,127.0.0.1,$WINRM_PORT,,5985" >/dev/null ||
    die "VBoxManage could not configure $vm"
  vbox_ createmedium disk --filename "$VM_DIR/disk.vdi" --size "$(size_to_mib "$DISK_SIZE")" --format VDI >/dev/null ||
    die "VBoxManage could not create the disk"
  vbox_ storagectl "$vm" --name NVMe --add pcie --controller NVMe >/dev/null
  vbox_ storageattach "$vm" --storagectl NVMe --port 0 --device 0 --type hdd --medium "$VM_DIR/disk.vdi" >/dev/null
  vbox_ storagectl "$vm" --name SATA --add sata --controller IntelAhci --portcount 3 >/dev/null
  for iso in "$BOOT_ISO" "$VM_DIR/config.iso" "$TOOLS_ISO"; do
    [ -n "$iso" ] || continue
    vbox_ storageattach "$vm" --storagectl SATA --port "$port" --device 0 --type dvddrive --medium "$iso" >/dev/null ||
      die "VBoxManage could not attach $iso"
    port=$((port + 1))
  done
}

be_virtualbox_running() { vbox_ list runningvms 2>/dev/null | grep -Fq "\"$(vbox_vm)\""; }

be_virtualbox_start() {
  local type=gui
  [ "$1" = headless ] && type=headless
  vbox_ startvm "$(vbox_vm)" --type "$type" >/dev/null || die "VBoxManage could not start $(vbox_vm)"
  ok "Running in VirtualBox"
}

be_virtualbox_stop() {
  if [ "$1" = 1 ]; then vbox_ controlvm "$(vbox_vm)" poweroff; else vbox_ controlvm "$(vbox_vm)" acpipowerbutton; fi >/dev/null 2>&1 || true
}

be_virtualbox_eject() {
  vbox_ storageattach "$(vbox_vm)" --storagectl SATA --port 0 --device 0 --type dvddrive --medium emptydrive >/dev/null 2>&1 || true
  vbox_ storageattach "$(vbox_vm)" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive >/dev/null 2>&1 || true
}

be_virtualbox_destroy() { vbox_ unregistervm "$(vbox_vm)" --delete >/dev/null 2>&1 || true; }
be_virtualbox_address() { echo 127.0.0.1; }
be_virtualbox_port() {
  case "$1" in rdp) echo "$RDP_PORT" ;; ssh) echo "$SSH_PORT" ;; winrm) echo "$WINRM_PORT" ;; esac
}
