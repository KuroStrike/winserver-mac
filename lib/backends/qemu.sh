# shellcheck shell=bash
# QEMU backend: free, scriptable, and the only one that runs x64 Windows on
# Apple Silicon (by emulation).
#
#   arm64 guest  -> qemu-system-aarch64, Apple Hypervisor (HVF), native speed
#   x64 guest    -> qemu-system-x86_64, TCG emulation on Apple Silicon
#                   (or HVF on an Intel Mac)
#
# Every backend implements the same functions (see lib/vm.sh):
#   be_<b>_available  be_<b>_describe  be_<b>_require  be_<b>_create
#   be_<b>_start  be_<b>_running  be_<b>_stop  be_<b>_eject  be_<b>_destroy
#   be_<b>_address  be_<b>_port  be_<b>_tools_iso  be_<b>_needs_noprompt

qemu_bin_name() {
  case "$1" in
    arm64) echo qemu-system-aarch64 ;;
    x64)   echo qemu-system-x86_64 ;;
    *)     die "unknown architecture '$1'" ;;
  esac
}

# Full path of the QEMU system emulator for an architecture, or nothing.
qemu_path() {
  local name
  name="$(qemu_bin_name "$1")"
  if [ -n "${WINSERVER_QEMU_DIR:-}" ]; then
    if [ -x "$WINSERVER_QEMU_DIR/$name" ]; then echo "$WINSERVER_QEMU_DIR/$name"; fi
    return 0
  fi
  command -v "$name" || true
}

qemu_img_path() {
  if [ -n "${WINSERVER_QEMU_DIR:-}" ]; then echo "$WINSERVER_QEMU_DIR/qemu-img"; else command -v qemu-img || true; fi
}

require_qemu() {
  local bin
  bin="$(qemu_path "$1")"
  [ -n "$bin" ] || die "$(qemu_bin_name "$1") not found. Install QEMU with: brew install qemu"
  printf '%s' "$bin"
}

# Directory with QEMU's bundled UEFI firmware.
qemu_share_dir() {
  local bin="$1" d
  for d in "${WINSERVER_QEMU_SHARE:-}" "$(dirname "$bin")/../share/qemu" /opt/homebrew/share/qemu /usr/local/share/qemu; do
    if [ -n "$d" ] && [ -d "$d" ]; then (cd "$d" && pwd); return 0; fi
  done
  die "cannot find QEMU's firmware directory (set WINSERVER_QEMU_SHARE)"
}

# UEFI code and variable-store template for a guest architecture.
firmware_code() { case "$1" in arm64) echo edk2-aarch64-code.fd ;; x64) echo edk2-x86_64-code.fd ;; esac; }
firmware_vars() { case "$1" in arm64) echo edk2-arm-vars.fd ;; x64) echo edk2-i386-vars.fd ;; esac; }

monitor_socket() { echo "$RUN_DIR/$1.monitor"; }

# Fill QEMU_BIN and the QEMU_ARGS array for the loaded VM.
#   $1  1 to attach the install media, 0 for a normal boot
#   $2  gui | headless
#   $3  1 to also expose a VNC console
build_qemu_args() {
  local with_media="$1" display="$2" vnc="$3"
  local bin share code fwd
  bin="$(require_qemu "$ARCH")"
  share="$(qemu_share_dir "$bin")"
  code="$share/$(firmware_code "$ARCH")"
  [ -f "$code" ] || die "missing firmware $code"

  QEMU_BIN="$bin"
  QEMU_ARGS=(
    -name "winserver-$NAME"
    -pidfile "$VM_DIR/qemu.pid"
    -monitor "unix:$(qemu_escape "$(monitor_socket "$NAME")"),server,nowait"
    -smp "$CPUS"
    -m "$MEMORY"
    -rtc base=localtime
  )

  case "$ARCH" in
    arm64)
      QEMU_ARGS+=(-machine virt -accel hvf -cpu host)
      ;;
    x64)
      QEMU_ARGS+=(-machine q35)
      if [ "$(host_arch)" = x86_64 ]; then
        QEMU_ARGS+=(-accel hvf -cpu host)
      else
        QEMU_ARGS+=(-accel "tcg,thread=${WINSERVER_TCG_THREAD:-multi},tb-size=1024" -cpu "${CPU_MODEL:-max}")
      fi
      ;;
  esac

  QEMU_ARGS+=(
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(qemu_escape "$code")"
    -drive "if=pflash,format=raw,unit=1,file=$(qemu_escape "$VM_DIR/efivars.fd")"
    -device qemu-xhci,id=xhci
    -device usb-tablet,bus=xhci.0
    -drive "if=none,id=disk0,format=qcow2,discard=unmap,detect-zeroes=unmap,file=$(qemu_escape "$VM_DIR/disk.qcow2")"
    -device nvme,drive=disk0,serial=winserver0,bootindex=0
  )

  # Windows on ARM has no driver for a PCI VGA card; ramfb is a plain UEFI framebuffer.
  if [ "$ARCH" = arm64 ]; then
    QEMU_ARGS+=(-device ramfb -device usb-kbd,bus=xhci.0)
  fi

  if [ "$with_media" = 1 ]; then
    QEMU_ARGS+=(
      -drive "if=none,id=cd0,media=cdrom,readonly=on,file=$(qemu_escape "$BOOT_ISO")"
      -drive "if=none,id=cd1,media=cdrom,readonly=on,file=$(qemu_escape "$VM_DIR/config.iso")"
    )
    if [ "$ARCH" = arm64 ]; then
      # The virt machine has no IDE/SATA; USB CD drives work with Windows' inbox drivers.
      QEMU_ARGS+=(
        -device usb-storage,drive=cd0,bus=xhci.0,bootindex=1
        -device usb-storage,drive=cd1,bus=xhci.0
      )
    else
      QEMU_ARGS+=(
        -device ide-cd,drive=cd0,bus=ide.0,bootindex=1
        -device ide-cd,drive=cd1,bus=ide.1
      )
    fi
  fi

  fwd="hostfwd=tcp:127.0.0.1:$RDP_PORT-:3389,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$WINRM_PORT-:5985"
  QEMU_ARGS+=(-netdev "user,id=net0,$fwd")
  # romfile= drops the PXE option ROM, so a missed CD prompt never stalls on network boot.
  case "$NIC" in
    virtio) QEMU_ARGS+=(-device "virtio-net-pci,netdev=net0,mac=$MAC,romfile=") ;;
    e1000e) QEMU_ARGS+=(-device "e1000e,netdev=net0,mac=$MAC,romfile=") ;;
    *)      QEMU_ARGS+=(-device "$NIC,netdev=net0,mac=$MAC") ;;
  esac

  case "$display" in
    gui)      QEMU_ARGS+=(-display cocoa) ;;
    headless) QEMU_ARGS+=(-display none -daemonize) ;;
  esac
  if [ "$vnc" = 1 ]; then
    QEMU_ARGS+=(-vnc "127.0.0.1:$((VNC_PORT - 5900))")
  fi
}

# Send one HMP command to the VM's monitor.
monitor_cmd() {
  printf '%s\n' "$1" | nc -U -w 1 "$(monitor_socket "$NAME")" >/dev/null 2>&1 || true
}

# Fallback when the ISO could not be remastered (no mkisofs): Windows install
# discs wait ~5 s at "Press any key to boot from CD or DVD", so press Enter
# while the firmware boots. The window must end before Setup's own window
# appears (its Cancel button has focus), which is why the prompt-free ISO is
# preferred: see noprompt_iso in lib/iso.sh.
press_enter_during_boot() {
  local seconds="$1" sock i=0
  sock="$(monitor_socket "$NAME")"
  while [ ! -S "$sock" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  [ -S "$sock" ] || return 0
  i=0
  ( while [ $i -lt $((seconds * 2)) ]; do
      echo "sendkey ret"
      sleep 0.5
      i=$((i + 1))
    done ) | nc -U -w 2 "$sock" >/dev/null 2>&1 || true
}

# PID of the VM's QEMU process, if it is running.
qemu_pid() {
  local pid
  [ -f "$VM_DIR/qemu.pid" ] || return 1
  pid="$(cat "$VM_DIR/qemu.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Guard against a stale pidfile whose PID now belongs to another process.
  ps -p "$pid" -o command= 2>/dev/null | grep -q -- "-name winserver-$NAME " || return 1
  echo "$pid"
}

# ---------------------------------------------------------------- backend interface

be_qemu_available() { [ -n "$(qemu_path arm64)$(qemu_path x64)" ]; }
be_qemu_describe() {
  local bin
  bin="$(qemu_path arm64)"; [ -n "$bin" ] || bin="$(qemu_path x64)"
  "$bin" --version 2>/dev/null | head -n 1 | sed 's/ emulator version / /'
}
# Prompt-free ISO when mkisofs is there; otherwise winserver presses Enter at the prompt.
be_qemu_needs_noprompt() { [ -n "$(mkisofs_bin)" ]; }
be_qemu_tools_iso() { :; }

be_qemu_require() {
  require_qemu "$ARCH" >/dev/null
  [ -x "$(qemu_img_path)" ] || die "qemu-img not found. Install QEMU with: brew install qemu"
}

be_qemu_create() {
  "$(qemu_img_path)" create -q -f qcow2 "$VM_DIR/disk.qcow2" "$DISK_SIZE"
  cp "$(qemu_share_dir "$(require_qemu "$ARCH")")/$(firmware_vars "$ARCH")" "$VM_DIR/efivars.fd"
  chmod 600 "$VM_DIR/efivars.fd"
}

be_qemu_running() { qemu_pid >/dev/null; }

be_qemu_start() {
  local display="$1" vnc="$2" press="${3:-0}" with_media=0 pid i
  if [ "$INSTALLED" != 1 ]; then
    with_media=1
    # The original ISO prompts "Press any key to boot from CD" on the very first boot.
    if [ "$BOOT_ISO" = "$ISO" ] && [ ! -f "$VM_DIR/.booted" ]; then press=1; fi
  fi
  mkdir -p "$RUN_DIR"
  rm -f "$(monitor_socket "$NAME")" "$VM_DIR/qemu.pid"
  build_qemu_args "$with_media" "$display" "$vnc"
  printf '%q ' "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$VM_DIR/qemu.cmd"

  if [ "$display" = headless ]; then
    "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$VM_DIR/qemu.log" 2>&1 ||
      { tail -n 20 "$VM_DIR/qemu.log" >&2; die "QEMU failed to start (full command in $VM_DIR/qemu.cmd)"; }
  else
    nohup "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$VM_DIR/qemu.log" 2>&1 &
  fi

  i=0
  until pid="$(qemu_pid)"; do
    sleep 0.5; i=$((i + 1))
    if [ $i -ge 20 ]; then
      tail -n 20 "$VM_DIR/qemu.log" >&2
      die "QEMU did not start (full command in $VM_DIR/qemu.cmd)"
    fi
  done
  ok "Running (pid $pid)"
  if [ "$vnc" = 1 ]; then dim "  VNC console: winserver console $NAME"; fi

  if [ "$press" = 1 ]; then
    touch "$VM_DIR/.booted"
    info "Answering 'Press any key to boot from CD'…"
    if [ "$ARCH" = arm64 ]; then
      press_enter_during_boot "${WINSERVER_PRESS_SECONDS:-15}"
    else
      press_enter_during_boot "${WINSERVER_PRESS_SECONDS:-60}"
    fi
  fi
}

be_qemu_stop() {
  if [ "$1" = 1 ]; then monitor_cmd quit; else monitor_cmd system_powerdown; fi
}

be_qemu_eject() { :; }    # the next start simply leaves the discs out
be_qemu_destroy() { rm -f "$(monitor_socket "$NAME")"; }
be_qemu_address() { echo 127.0.0.1; }
be_qemu_port() {
  case "$1" in rdp) echo "$RDP_PORT" ;; ssh) echo "$SSH_PORT" ;; winrm) echo "$WINRM_PORT" ;; vnc) echo "$VNC_PORT" ;; esac
}
