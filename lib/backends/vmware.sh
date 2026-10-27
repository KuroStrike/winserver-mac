# shellcheck shell=bash
# VMware Fusion backend, driven by vmrun. Free for personal use.
# On Apple Silicon, Fusion runs ARM64 guests only; on Intel Macs, x64 guests.
#
# The VM gets NAT networking; winserver reaches it on its own IP address,
# which VMware Tools (installed on first boot from Fusion's tools ISO) reports.

FUSION_APP="${WINSERVER_FUSION_APP:-/Applications/VMware Fusion.app}"

vmrun_bin()       { echo "${WINSERVER_VMRUN:-$FUSION_APP/Contents/Library/vmrun}"; }
vdiskmanager_bin() { echo "${WINSERVER_VDISKMANAGER:-$FUSION_APP/Contents/Library/vmware-vdiskmanager}"; }
vmx_path()        { echo "$VM_DIR/$NAME.vmwarevm/$NAME.vmx"; }
vmrun_()          { "$(vmrun_bin)" -T fusion "$@"; }

# Set KEY = "VALUE" in a .vmx file, replacing the key if it is there.
vmx_set() {
  local vmx="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$vmx.XXXXXX")"
  grep -v "^$key = " "$vmx" >"$tmp" || true
  printf '%s = "%s"\n' "$key" "$value" >>"$tmp"
  mv "$tmp" "$vmx"
}

be_vmware_available() { [ -x "$(vmrun_bin)" ]; }
be_vmware_describe() {
  printf 'VMware Fusion %s' "$(defaults read "$FUSION_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
}
be_vmware_needs_noprompt() { return 0; }    # vmrun cannot type at the boot prompt

be_vmware_tools_iso() {
  local iso
  case "$ARCH" in
    arm64) iso="$FUSION_APP/Contents/Library/isoimages/arm64/windows.iso" ;;
    x64)   iso="$FUSION_APP/Contents/Library/isoimages/x86_x64/windows.iso" ;;
  esac
  if [ -f "$iso" ]; then echo "$iso"; fi
}

be_vmware_require() {
  be_vmware_available || die "VMware Fusion not found at $FUSION_APP (free for personal use: https://www.vmware.com/products/desktop-hypervisor)"
  if [ "$ARCH" = x64 ] && [ "$(host_arch)" = arm64 ]; then
    die "VMware Fusion can't run x64 guests on Apple Silicon. Use --backend qemu (emulated) or an ARM64 ISO."
  fi
  [ -x "$(vdiskmanager_bin)" ] || die "vmware-vdiskmanager not found in $FUSION_APP"
}

be_vmware_create() {
  local dir vmx guest nic n=0 iso
  dir="$VM_DIR/$NAME.vmwarevm"
  vmx="$(vmx_path)"
  mkdir -p "$dir"
  "$(vdiskmanager_bin)" -c -s "$(size_to_mib "$DISK_SIZE")MB" -a lsilogic -t 0 "$dir/disk.vmdk" >/dev/null ||
    die "could not create the virtual disk"
  if [ "$ARCH" = arm64 ]; then
    guest="arm-windows11-64"; nic="vmxnet3"     # vmxnet3 driver comes with VMware Tools
  else
    guest="windows2019srvnext-64"; nic="e1000e" # inbox driver
  fi
  cat >"$vmx" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "20"
displayName = "winserver-$NAME"
guestOS = "$guest"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
numvcpus = "$CPUS"
memsize = "$(size_to_mib "$MEMORY")"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "disk.vmdk"
sata0.present = "TRUE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "$nic"
ethernet0.addressType = "generated"
usb.present = "TRUE"
usb_xhci.present = "TRUE"
svga.present = "TRUE"
tools.syncTime = "TRUE"
floppy0.present = "FALSE"
bios.bootOrder = "hdd,cdrom"
uuid.action = "create"
msg.autoAnswer = "TRUE"
EOF
  for iso in "$BOOT_ISO" "$VM_DIR/config.iso" "$TOOLS_ISO"; do
    [ -n "$iso" ] || continue
    vmx_set "$vmx" "sata0:$n.present" TRUE
    vmx_set "$vmx" "sata0:$n.deviceType" cdrom-image
    vmx_set "$vmx" "sata0:$n.fileName" "$iso"
    vmx_set "$vmx" "sata0:$n.startConnected" TRUE
    n=$((n + 1))
  done
}

be_vmware_running() {
  local vmx
  vmx="$(vmx_path)"
  vmrun_ list 2>/dev/null | grep -Fqx "$vmx"
}

be_vmware_start() {
  local display="$1" vmx
  vmx="$(vmx_path)"
  if [ "$INSTALLED" = 1 ]; then
    # Install discs stay in the .vmx but no longer connect at power-on.
    vmx_set "$vmx" "sata0:0.startConnected" FALSE
    vmx_set "$vmx" "sata0:1.startConnected" FALSE
  fi
  if [ "$display" = headless ]; then vmrun_ start "$vmx" nogui; else vmrun_ start "$vmx" gui; fi ||
    die "vmrun could not start $vmx"
  ok "Running in VMware Fusion"
}

be_vmware_stop() {
  if [ "$1" = 1 ]; then vmrun_ stop "$(vmx_path)" hard; else vmrun_ stop "$(vmx_path)" soft; fi >/dev/null 2>&1 || true
}

be_vmware_eject() {
  vmrun_ disconnectNamedDevice "$(vmx_path)" sata0:0 >/dev/null 2>&1 || true
  vmrun_ disconnectNamedDevice "$(vmx_path)" sata0:1 >/dev/null 2>&1 || true
}

be_vmware_destroy() { vmrun_ deleteVM "$(vmx_path)" >/dev/null 2>&1 || true; }

be_vmware_address() {
  local ip
  ip="$(vmrun_ getGuestIPAddress "$(vmx_path)" 2>/dev/null || true)"
  case "$ip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$ip" ;; esac
}

be_vmware_port() {
  case "$1" in rdp) echo 3389 ;; ssh) echo 22 ;; winrm) echo 5985 ;; esac
}
