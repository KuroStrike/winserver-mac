#!/usr/bin/env bash
# End-to-end tests that need neither Windows nor a real hypervisor.
#
# Builds fake Windows ISOs (real WIM metadata via wimlib, fake payload), a fake
# virtio-win ISO, a stub QEMU and stubs for vmrun / VBoxManage / prlctl, then
# drives every winserver command against them.
# macOS only (hdiutil). Requires wimlib, mkisofs (cdrtools), xmllint, python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS="$ROOT/bin/winserver"
T="$(mktemp -d "${TMPDIR:-/tmp}/winserver-test.XXXXXX")"
export NO_COLOR=1
export WINSERVER_HOME="$T/home"
# Where winserver puts this home's QEMU sockets (see RUN_DIR in lib/common.sh).
RUN="/tmp/winserver-$(id -u)-$(printf '%s' "$WINSERVER_HOME" | cksum | cut -d' ' -f1)"
trap 'pkill -f "winserver-test.*qemu-system" 2>/dev/null || true; rm -rf "$T" "$RUN"' EXIT
export WINSERVER_QEMU_DIR="$T/qemu/bin"
export WINSERVER_QEMU_SHARE="$T/qemu/share"
export WINSERVER_PRESS_SECONDS=1
export STUB_SSH_DELAY=3
export STUB_STATE="$T/stub-state"
# Fake hypervisor installs: vmrun & co. are stubs, tools ISOs are empty files.
export WINSERVER_FUSION_APP="$T/apps/VMware Fusion.app"
export WINSERVER_VMRUN="$T/stubs/vmrun"
export WINSERVER_VDISKMANAGER="$T/stubs/vmware-vdiskmanager"
export WINSERVER_VBOXMANAGE="$T/stubs/VBoxManage"
export WINSERVER_VBOX_APP="$T/apps/VirtualBox.app"
export WINSERVER_PRLCTL="$T/stubs/prlctl"
export WINSERVER_PARALLELS_APP="$T/apps/Parallels Desktop.app"

pass=0
fail=0
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$what"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n' "$what"
  fi
}
fails() { ! "$@"; }
contains() { grep -q -- "$2" "$1"; }

# ---------------------------------------------------------------- fixtures

echo "Building fixtures in $T"
mkdir -p "$WINSERVER_QEMU_DIR" "$WINSERVER_QEMU_SHARE" "$WINSERVER_HOME/cache/iso" "$T/stubs" "$STUB_STATE"
for b in qemu-system-aarch64 qemu-system-x86_64; do
  cp "$ROOT/tests/stub/qemu-system" "$WINSERVER_QEMU_DIR/$b"
  chmod +x "$WINSERVER_QEMU_DIR/$b"
done
cat >"$WINSERVER_QEMU_DIR/qemu-img" <<'EOF'
#!/bin/sh
# qemu-img stub: "create -q -f qcow2 FILE SIZE" -> empty FILE
eval "file=\${$(($# - 1))}"
: >"$file"
EOF
chmod +x "$WINSERVER_QEMU_DIR/qemu-img"
for fw in edk2-aarch64-code.fd edk2-arm-vars.fd edk2-x86_64-code.fd edk2-i386-vars.fd; do
  : >"$WINSERVER_QEMU_SHARE/$fw"
done
for s in vmrun vmware-vdiskmanager VBoxManage prlctl; do
  ln -s "$ROOT/tests/stub/hypervisor" "$T/stubs/$s"
done
mkdir -p "$WINSERVER_FUSION_APP/Contents/Library/isoimages/arm64" \
  "$WINSERVER_VBOX_APP/Contents/MacOS" "$WINSERVER_PARALLELS_APP/Contents/Resources/Tools"
: >"$WINSERVER_FUSION_APP/Contents/Library/isoimages/arm64/windows.iso"
: >"$WINSERVER_VBOX_APP/Contents/MacOS/VBoxGuestAdditions.iso"
: >"$WINSERVER_PARALLELS_APP/Contents/Resources/Tools/prl-tools-win-arm.iso"

# A 2 KiB boot image whose first bytes say which one it is.
boot_image() { python3 -c "import sys; sys.stdout.buffer.write(sys.argv[1].encode().ljust(2048, b'\0'))" "$1" >"$2"; }

# A Windows-like ISO: 4 images with the metadata winserver reads, and the boot files.
#   $1 out.iso  $2 wim arch code (12 = ARM64, 9 = x64)  $3 boot loader name
make_windows_iso() {
  local out="$1" arch="$2" loader="$3" dir="$T/iso-src-$2" payload="$T/payload" i ed type name cmd
  mkdir -p "$dir/sources" "$dir/efi/boot" "$dir/efi/microsoft/boot" "$payload"
  echo "not really windows" >"$payload/readme.txt"
  : >"$dir/efi/boot/$loader"
  boot_image PROMPT "$dir/efi/microsoft/boot/efisys.bin"
  boot_image NOPROMPT "$dir/efi/microsoft/boot/efisys_noprompt.bin"
  if [ "$arch" = 9 ]; then mkdir -p "$dir/boot"; boot_image BIOS "$dir/boot/etfsboot.com"; fi
  i=0
  for ed in ServerStandard ServerDatacenter; do
    for type in "Server Core" "Server"; do
      i=$((i + 1))
      name="Windows Server $ed $type"
      if [ "$i" = 1 ]; then cmd=capture; else cmd=append; fi
      wimlib-imagex "$cmd" "$payload" "$dir/sources/install.wim" "$name" \
        --image-property "WINDOWS/ARCH=$arch" \
        --image-property "WINDOWS/EDITIONID=$ed" \
        --image-property "WINDOWS/INSTALLATIONTYPE=$type" \
        --image-property "WINDOWS/LANGUAGES/DEFAULT=fr-FR" >/dev/null
    done
  done
  hdiutil makehybrid -quiet -iso -joliet -udf -o "$out" "$dir"
}
ARM_ISO="$WINSERVER_HOME/cache/iso/winserver-arm64-26501.1000-fr-fr.iso"
make_windows_iso "$ARM_ISO" 12 bootaa64.efi
make_windows_iso "$T/server-x64.iso" 9 bootx64.efi

mkdir -p "$T/virtio/NetKVM/w11/ARM64" "$T/virtio/viostor/w11/ARM64" "$T/virtio/NetKVM/2k25/amd64"
echo "; netkvm" >"$T/virtio/NetKVM/w11/ARM64/netkvm.inf"
echo "; viostor" >"$T/virtio/viostor/w11/ARM64/viostor.inf"
hdiutil makehybrid -quiet -iso -joliet -o "$WINSERVER_HOME/cache/virtio-win.iso" "$T/virtio"

echo "not an iso" >"$T/bogus.iso"
ssh-keygen -q -t ed25519 -N "" -f "$T/key" -C test@winserver

mount_iso() { hdiutil attach -nobrowse -readonly -noverify "$1" | awk -F'\t' 'index($NF, "/Volumes/") == 1 {print $NF}' | sed 's/[[:space:]]*$//'; }

# Copy a file out of an ISO; also lists the .inf files under drivers/.
iso_file() {
  local iso="$1" file="$2" tag="$3" mnt
  mnt="$(mount_iso "$iso")"
  cp "$mnt/$file" "$T/out-$tag-$(basename "$file")" 2>/dev/null || true
  if [ -d "$mnt/drivers" ]; then find "$mnt/drivers" -name '*.inf' >"$T/out-$tag-drivers"; else : >"$T/out-$tag-drivers"; fi
  hdiutil detach -quiet "$mnt"
  echo "$T/out-$tag-$(basename "$file")"
}
config_file() { iso_file "$WINSERVER_HOME/vms/$1/config.iso" "$2" "$1"; }

# First 8 bytes of the UEFI El Torito boot image of an ISO (the last boot entry).
efi_boot_image() {
  python3 - "$1" <<'EOF'
import struct, sys
f = open(sys.argv[1], "rb")
def sector(n):
    f.seek(n * 2048); return f.read(2048)
brvd = sector(17)
assert brvd[1:6] == b"CD001" and brvd[7:30].startswith(b"EL TORITO"), "no El Torito record"
cat = sector(struct.unpack_from("<I", brvd, 0x47)[0])
# 32-byte records; bootable entries (initial and section entries) start with 0x88.
entries = [cat[i:i + 32] for i in range(32, 2048, 32) if cat[i] == 0x88]
rba = struct.unpack_from("<I", entries[-1], 8)[0]
print(sector(rba)[:8].rstrip(b"\0").decode())
EOF
}

# Decode an unattend password field (base64 UTF-16LE of password + suffix).
decode_pw() { base64 -D | iconv -f UTF-16LE -t UTF-8; }

# ---------------------------------------------------------------- tests

echo; echo "doctor / help"
check "help prints usage"              sh -c "'$WS' --help | grep -q 'in any hypervisor'"
check "doctor runs"                    "$WS" doctor
check "doctor lists the backends"      sh -c "'$WS' doctor | grep -q 'VMware Fusion'"
check "unknown command fails"          fails "$WS" frobnicate

echo; echo "create (QEMU, arm64, from cache)"
check "create arm64 --no-start"        "$WS" create web01 --no-start --ssh-key "$T/key.pub" --feature Web-Server
CONF="$WINSERVER_HOME/vms/web01/vm.conf"
check "QEMU picked automatically"      contains "$CONF" "^BACKEND=qemu"
check "arch detected as arm64"         contains "$CONF" "^ARCH=arm64"
check "desktop experience by default"  contains "$CONF" "^EXPERIENCE=desktop"
check "datacenter desktop is image 4"  contains "$CONF" "^IMAGE_INDEX=4"
check "language taken from the ISO"    contains "$CONF" "^UI_LANG=fr-FR"
check "virtio NIC on arm64"            contains "$CONF" "^NIC=virtio"
check "boots the prompt-free copy"     contains "$CONF" "^BOOT_ISO=.*/noprompt/winserver-arm64"
check "password file is private"       sh -c "[ \"\$(stat -f %Lp '$WINSERVER_HOME/vms/web01/password')\" = 600 ]"
NOPROMPT="$WINSERVER_HOME/cache/iso/noprompt/$(basename "$ARM_ISO")"
check "prompt-free ISO boots noprompt" test "$(efi_boot_image "$NOPROMPT")" = NOPROMPT
check "prompt-free ISO keeps the wim"  test -s "$(iso_file "$NOPROMPT" sources/install.wim noprompt)"
XML="$(config_file web01 autounattend.xml)"
check "autounattend.xml is valid XML"  xmllint --noout "$XML"
check "answer file targets arm64"      contains "$XML" 'processorArchitecture="arm64"'
check "answer file installs image 4"   contains "$XML" "<Value>4</Value>"
check "answer file sets the hostname"  contains "$XML" "<ComputerName>WEB01</ComputerName>"
check "answer file has driver paths"   contains "$XML" 'D:\\drivers'
check "QEMU VM gets a UTC clock"       contains "$CONF" "^RTC=utc"
check "  ...and Windows is told so"    contains "$XML" "RealTimeIsUniversal /t REG_DWORD /d 1"
check "ARM64 drivers on the disc"      contains "$T/out-web01-drivers" "NetKVM/netkvm.inf"
check "x64 drivers not on the disc"    fails grep -q amd64 "$T/out-web01-drivers"
PW="$(cat "$WINSERVER_HOME/vms/web01/password")"
ENC="$(sed -n '/<AdministratorPassword>/,/<\/AdministratorPassword>/s/.*<Value>\(.*\)<\/Value>.*/\1/p' "$XML")"
check "admin password encodes right"   test "$(printf '%s' "$ENC" | decode_pw)" = "${PW}AdministratorPassword"
SET="$(config_file web01 settings.ps1)"
check "features passed to Windows"     contains "$SET" "@('Web-Server')"
check "no password in settings"        contains "$SET" "WS_Password = ''"
KEYS="$(config_file web01 authorized_keys)"
check "ssh key on the disc"            contains "$KEYS" "test@winserver"
check "first-boot script on the disc"  test -s "$(config_file web01 firstboot.ps1)"
# Regression: Windows PowerShell 5.1 ignored a Get-ChildItem -Exclude copy, so first
# boot now copies the payload by name. Every file staged at the disc root must be listed.
payload_listed() {
  local mnt f missing=0
  mnt="$(mount_iso "$WINSERVER_HOME/vms/web01/config.iso")"
  for f in "$mnt"/*; do
    f="$(basename "$f")"
    case "$f" in autounattend.xml|winserver.tag|drivers) continue ;; esac
    grep -q "'$f'" "$ROOT/templates/firstboot.ps1" || { echo "not copied by firstboot.ps1: $f"; missing=1; }
  done
  hdiutil detach -quiet "$mnt"
  [ "$missing" = 0 ]
}
check "first boot copies all payload"  payload_listed
check "no -Exclude copies in scripts"  fails grep -n -- "-Exclude" "$ROOT/templates/firstboot.ps1" "$ROOT/templates/post-setup.ps1"
# Regression: Server 2025's own sshd rule is Private-only and VM networks are Public.
check "sshd rule opened on all profiles" sh -c "grep -A2 'sshRule) {' '$ROOT/templates/post-setup.ps1' | grep -q 'Profile Any'"
# Regression: a DC answered SSH before it could log anyone on, so `wait` returned too early.
check "DC starts sshd delayed"         sh -c "grep -B3 'delayed-auto' '$ROOT/templates/post-setup.ps1' | grep -q \"WS_Role -eq 'ad-dc'\""
check "DC syncs time from the internet" contains "$ROOT/templates/post-setup.ps1" "manualpeerlist:time.windows.com"

echo; echo "create (QEMU, x64 domain controller, --iso)"
check "create x64 DC"                  "$WS" create dc01 --iso "$T/server-x64.iso" --domain corp.lab --edition standard --no-start --no-ssh-key --locale en-GB --timezone "GMT Standard Time"
CONF="$WINSERVER_HOME/vms/dc01/vm.conf"
check "arch detected as x64"           contains "$CONF" "^ARCH=x64"
check "core by default on x64"         contains "$CONF" "^EXPERIENCE=core"
check "standard core is image 1"       contains "$CONF" "^IMAGE_INDEX=1"
check "e1000e NIC on x64"              contains "$CONF" "^NIC=e1000e"
check "netbios derived from domain"    contains "$CONF" "^NETBIOS=CORP"
check "ports do not collide"           sh -c "! grep -q \"^RDP_PORT=\$(sed -n 's/^RDP_PORT=//p' '$WINSERVER_HOME/vms/web01/vm.conf')\$\" '$CONF'"
check "x64 copy boots noprompt (UEFI)" test "$(efi_boot_image "$WINSERVER_HOME/cache/iso/noprompt/server-x64.iso")" = NOPROMPT
XML="$(config_file dc01 autounattend.xml)"
check "answer file targets amd64"      contains "$XML" 'processorArchitecture="amd64"'
check "no driver paths on x64"         fails grep -q 'PnpCustomizationsWinPE' "$XML"
check "locale applied"                 contains "$XML" "<UserLocale>en-GB</UserLocale>"
check "time zone applied"              contains "$XML" "<TimeZone>GMT Standard Time</TimeZone>"
SET="$(config_file dc01 settings.ps1)"
check "role in settings"               contains "$SET" "WS_Role     = 'ad-dc'"
check "DC keeps the password"          contains "$SET" "WS_Password = '"

echo; echo "create (validation)"
check "rejects a bad name"             fails "$WS" create "bad_name" --no-start
check "rejects a 16-char name"         fails "$WS" create abcdefghijklmnop --no-start
check "rejects a duplicate"            fails "$WS" create web01 --no-start
check "rejects arch mismatch"          fails "$WS" create mix01 --iso "$T/server-x64.iso" --arch arm64 --no-start
check "rejects a non-Windows ISO"      fails "$WS" create bog01 --iso "$T/bogus.iso" --no-start
check "rejects missing edition"        fails "$WS" create ent01 --edition enterprise --no-start
check "rejects hostname = netbios"     fails "$WS" create lab --domain lab.local --no-start
check "rejects tiny memory"            fails "$WS" create small1 --memory 1G --no-start
check "rejects unknown backend"        fails "$WS" create hv01 --backend hyperv --no-start
check "rejects x64 on VMware (arm64)"  fails "$WS" create vx01 --iso "$T/server-x64.iso" --backend vmware --no-start
check "rejects x64 on VirtualBox"      fails "$WS" create bx01 --iso "$T/server-x64.iso" --backend virtualbox --no-start

echo; echo "manual backend + winserver iso"
check "manual build"                   "$WS" create ext01 --backend manual
check "manual has a config disc"       test -s "$WINSERVER_HOME/vms/ext01/config.iso"
check "manual cannot start"            fails "$WS" start ext01
check "--config-only still works"      "$WS" create ext02 --config-only
check "iso builds"                     "$WS" iso ext01 -o "$T/ext01.iso"
check "iso boots noprompt"             test "$(efi_boot_image "$T/ext01.iso")" = NOPROMPT
check "iso has the answer file"        xmllint --noout "$(iso_file "$T/ext01.iso" autounattend.xml all)"
check "iso has the Windows media"      test -s "$(iso_file "$T/ext01.iso" sources/install.wim all)"
check "iso has the first-boot script"  test -s "$(iso_file "$T/ext01.iso" firstboot.ps1 all)"
check "iso has its drivers"            contains "$T/out-all-drivers" "NetKVM/netkvm.inf"
check "manual leaves the clock alone"  fails grep -q RealTimeIsUniversal "$(iso_file "$T/ext01.iso" autounattend.xml all)"

echo; echo "QEMU: start / wait / stop"
check "start headless"                 "$WS" start web01 --headless
check "list shows it running"          sh -c "'$WS' list | grep -E '^web01 +qemu +arm64 +running'"
check "start twice fails"              fails "$WS" start web01 --headless
check "no Enter needed (noprompt)"     test ! -f "$WINSERVER_HOME/vms/web01/monitor.log"
QCMD="$WINSERVER_HOME/vms/web01/qemu.cmd"
check "HVF on arm64"                   contains "$QCMD" "-accel hvf"
check "prompt-free ISO attached"       contains "$QCMD" "noprompt/winserver-arm64-26501.1000-fr-fr.iso"
check "NVMe boot disk"                 contains "$QCMD" "-device nvme"
check "hardware clock in UTC"          contains "$QCMD" "-rtc base=utc"
# Regression: test VMs shared ~/.winserver's socket folder and took over a real VM's sockets.
check "sockets apart from ~/.winserver" contains "$QCMD" "unix:$RUN/web01.monitor"
check "wait sees sshd"                 "$WS" wait web01 --timeout 2
check "setup marked done"              contains "$WINSERVER_HOME/vms/web01/vm.conf" "^INSTALLED=1"
check "stop"                           "$WS" stop web01 --timeout 10
check "powerdown sent"                 contains "$WINSERVER_HOME/vms/web01/monitor.log" "system_powerdown"
check "list shows it stopped"          sh -c "'$WS' list | grep -E '^web01 +qemu +arm64 +stopped +done'"
check "restart without install media"  "$WS" start web01 --headless
check "media detached after install"   fails grep -q "26501.1000-fr-fr.iso" "$QCMD"
check "stop --force"                   "$WS" stop web01 --force --timeout 10
check "x64 uses TCG"                   sh -c "'$WS' start dc01 --headless && grep -q -- '-accel tcg' '$WINSERVER_HOME/vms/dc01/qemu.cmd' && '$WS' stop dc01 --force"
check "install run: reboot → pause"     contains "$WINSERVER_HOME/vms/dc01/qemu.cmd" "reboot=shutdown"
check "first reboot ejects the disc"   sh -c "'$WS' create ej01 --no-start --no-ssh-key && STUB_GUEST_RESET=1 '$WS' start ej01 --headless && for i in 1 2 3 4 5 6 7 8 9 10; do [ -f '$WINSERVER_HOME/vms/ej01/.media-ejected' ] && break; sleep 0.5; done; [ -f '$WINSERVER_HOME/vms/ej01/.media-ejected' ]"
QLOG="$WINSERVER_HOME/vms/ej01/qmp.log"
check "  ...eject sent over QMP"        contains "$QLOG" "eject -f cd0"
check "  ...normal reboots restored"   contains "$QLOG" '"set-action".*"reboot": "reset"'
check "  ...VM reset and resumed"      sh -c "grep -q system_reset '$QLOG' && grep -q '\"cont\"' '$QLOG'"
check "  ...restart keeps config disc" sh -c "'$WS' stop ej01 --force && '$WS' start ej01 --headless && grep -q config.iso '$WINSERVER_HOME/vms/ej01/qemu.cmd' && '$WS' stop ej01 --force"
check "  ...but not the install disc"  fails grep -q "noprompt/winserver-arm64" "$WINSERVER_HOME/vms/ej01/qemu.cmd"
# VMs made by 0.1.0 have no RTC key and an answer file without RealTimeIsUniversal.
check "0.1.0 VMs keep local time"      sh -c "sed -i '' '/^RTC=/d' '$WINSERVER_HOME/vms/ej01/vm.conf' && '$WS' start ej01 --headless && grep -q -- '-rtc base=localtime' '$WINSERVER_HOME/vms/ej01/qemu.cmd' && '$WS' stop ej01 --force"
check "without mkisofs: original ISO"  env WINSERVER_MKISOFS= "$WS" create key01 --no-start --no-ssh-key
check "  ...and Enter at the prompt"   sh -c "'$WS' start key01 --headless && grep -q 'sendkey ret' '$WINSERVER_HOME/vms/key01/monitor.log' && '$WS' stop key01 --force"

echo; echo "VMware Fusion backend"
check "create on VMware"               "$WS" create vm01 --backend vmware --no-start --cpus 2 --memory 4G
VMX="$WINSERVER_HOME/vms/vm01/vm01.vmwarevm/vm01.vmx"
check "vmx written"                    test -f "$VMX"
check "ARM Windows guest type"         contains "$VMX" 'guestOS = "arm-windows11-64"'
check "UEFI without Secure Boot"       contains "$VMX" 'uefi.secureBoot.enabled = "FALSE"'
check "disk boots before the CD"       contains "$VMX" 'bios.bootOrder = "hdd,cdrom"'
check "memory in MiB"                  contains "$VMX" 'memsize = "4096"'
check "boots the prompt-free ISO"      contains "$VMX" 'sata0:0.fileName = ".*noprompt/winserver-arm64'
check "clock left to VMware Tools"     fails grep -q RealTimeIsUniversal "$(config_file vm01 autounattend.xml)"
check "config disc attached"           contains "$VMX" 'sata0:1.fileName = ".*config.iso"'
check "VMware Tools attached"          contains "$VMX" 'sata0:2.fileName = ".*isoimages/arm64/windows.iso"'
check "disk created"                   test -f "$WINSERVER_HOME/vms/vm01/vm01.vmwarevm/disk.vmdk"
check "start"                          "$WS" start vm01 --headless
check "vmrun started it headless"      contains "$STUB_STATE/vmrun.log" "start .*vm01.vmx nogui"
check "list shows it running"          sh -c "'$WS' list | grep -E '^vm01 +vmware +arm64 +running'"
check "address from VMware Tools"      sh -c "'$WS' info vm01 | grep -q '192.168.64.7'"
check "stop"                           "$WS" stop vm01 --timeout 10
check "discs off after install"        sh -c "sed -i '' 's/^INSTALLED=0/INSTALLED=1/' '$WINSERVER_HOME/vms/vm01/vm.conf' && '$WS' start vm01 --headless && grep -q 'sata0:0.startConnected = \"FALSE\"' '$VMX' && '$WS' stop vm01 --force"
check "delete"                         "$WS" delete vm01 --yes

echo; echo "VirtualBox backend"
check "create on VirtualBox"           "$WS" create vb01 --backend virtualbox --no-start
VLOG="$STUB_STATE/VBoxManage.log"
check "ARM platform"                   contains "$VLOG" "createvm --name winserver-vb01 .*--platform-architecture arm"
check "ARM Windows OS type"            contains "$VLOG" "--ostype Windows11_arm64"
check "EFI firmware"                   contains "$VLOG" "--firmware efi"
check "RDP forwarded to localhost"     contains "$VLOG" "rdp,tcp,127.0.0.1,"
check "virtio NIC"                     contains "$VLOG" "--nic-type1 virtio"
check "prompt-free ISO on port 0"      contains "$VLOG" "--port 0 --device 0 --type dvddrive --medium .*noprompt"
check "Guest Additions attached"       contains "$VLOG" "--port 2 .*VBoxGuestAdditions.iso"
check "start / stop"                   sh -c "'$WS' start vb01 --headless && '$WS' list | grep -qE '^vb01 +virtualbox +arm64 +running' && '$WS' stop vb01 --force"
check "delete unregisters"             sh -c "'$WS' delete vb01 --yes && grep -q 'unregistervm winserver-vb01 --delete' '$VLOG'"

echo; echo "Parallels backend"
check "create on Parallels"            "$WS" create pd01 --backend parallels --no-start
PLOG="$STUB_STATE/prlctl.log"
check "VM created"                     contains "$PLOG" "create winserver-pd01 --ostype windows"
check "NVMe disk"                      contains "$PLOG" "--device-add hdd .*--iface nvme"
check "Parallels Tools attached"       contains "$PLOG" "--device-add cdrom --image .*prl-tools-win-arm.iso"
check "start"                          "$WS" start pd01 --headless
check "address from Parallels Tools"   sh -c "'$WS' info pd01 | grep -q '10.211.55.9'"
check "stop"                           "$WS" stop pd01 --force --timeout 10

echo; echo "info / delete"
check "info"                           sh -c "'$WS' info dc01 | grep -q 'ad-dc: corp.lab (CORP)'"
check "password --show"                sh -c "[ \"\$('$WS' password dc01 --show)\" = \"\$(cat '$WINSERVER_HOME/vms/dc01/password')\" ]"
check "delete"                         "$WS" delete dc01 --yes
check "deleted from disk"              test ! -e "$WINSERVER_HOME/vms/dc01"
check "unknown VM fails"               fails "$WS" info nope

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
