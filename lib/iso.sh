# shellcheck shell=bash
# Remastering Windows ISOs.
#
# Microsoft's UEFI boot image (efisys.bin) waits for "Press any key to boot
# from CD or DVD". Their media also carries efisys_noprompt.bin, which boots
# straight into Setup. Rebuilding the ISO around that image gives a disc that
# installs with no keyboard at all, in any hypervisor. The same rebuild can add
# the config payload to the root, giving a single all-in-one unattended disc.

mkisofs_bin() {
  # WINSERVER_MKISOFS overrides discovery; set it empty to behave as if mkisofs were missing.
  if [ -n "${WINSERVER_MKISOFS+set}" ]; then printf '%s' "$WINSERVER_MKISOFS"; return 0; fi
  command -v mkisofs || command -v genisoimage || true
}

# Rebuild $1 into $2, booting without a prompt; merge directory $3 (optional) into the root.
remaster_iso() {
  local src="$1" out="$2" extra="${3:-}" mkiso mnt efi label need rc=0
  local boot_args=()
  mkiso="$(mkisofs_bin)"
  [ -n "$mkiso" ] || die "'mkisofs' not found. Install it with: brew install cdrtools"
  need=$(( $(du -k "$src" | cut -f1) / 1048576 + 2 ))
  mkdir -p "$(dirname "$out")"
  require_free_space "$(dirname "$out")" "$need"

  mnt="$(iso_mount "$src")"
  [ -n "$mnt" ] || die "could not mount $src"
  efi="efi/microsoft/boot/efisys_noprompt.bin"
  if [ ! -f "$mnt/$efi" ]; then
    warn "$(basename "$src") has no efisys_noprompt.bin; the new disc will still ask for a key at boot"
    efi="efi/microsoft/boot/efisys.bin"
  fi
  # x64 media also boots on BIOS firmware (etfsboot.com only prompts when a disk is already bootable).
  if [ -f "$mnt/boot/etfsboot.com" ]; then
    boot_args=(-b boot/etfsboot.com -no-emul-boot -eltorito-alt-boot -b "$efi" -no-emul-boot)
  else
    boot_args=(-b "$efi" -no-emul-boot)
  fi
  label="$(basename "$mnt" | cut -c1-32)"

  # Same layout as UUP dump's converter: UDF for the >4 GB install.wim, ISO 9660 names hidden.
  # Several source directories are merged at the root, so nothing is copied first.
  "$mkiso" "${boot_args[@]}" -udf -iso-level 3 -hide "*" -V "$label" -o "$out.part" \
    "$mnt" ${extra:+"$extra"} >"$out.log" 2>&1 || rc=$?
  iso_unmount "$mnt"
  if [ "$rc" != 0 ]; then
    tail -n 5 "$out.log" >&2
    rm -f "$out.part"
    die "mkisofs failed (full log: $out.log)"
  fi
  mv "$out.part" "$out"
  rm -f "$out.log"
}

# Cached prompt-free copy of an install ISO, shared by every VM that uses it.
noprompt_iso() {
  local src="$1" out
  out="$ISO_DIR/noprompt/$(basename "$src")"
  if [ ! -f "$out" ] || [ "$src" -nt "$out" ]; then
    info "Making a copy of $(basename "$src") that boots without 'Press any key' (once per ISO)…"
    remaster_iso "$src" "$out"
  fi
  printf '%s' "$out"
}

cmd_iso() {
  local name="" out="" stage
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) out="${2:?}"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: winserver iso <name> [-o FILE]

Builds one bootable ISO that installs Windows Server with no clicks and no
keypress: the VM's install ISO, plus its answer file, first-boot scripts and
drivers, booting straight into Setup.

Boot it in anything: VMware, VirtualBox, Parallels, UTM, Hyper-V, Proxmox,
or write it to a USB stick. Create the definition first, e.g.:

  winserver create srv01 --backend manual --core
  winserver iso srv01
EOF
        return 0 ;;
      -*) die "unknown option '$1'" ;;
      *)  name="$1"; shift ;;
    esac
  done
  need_name "$name"
  load_vm "$name"
  [ -f "$ISO" ] || die "install ISO is gone: $ISO"
  out="${out:-$VM_DIR/$NAME-unattended.iso}"

  stage="$(mktemp -d "${TMPDIR:-/tmp}/winserver-iso.XXXXXX")"
  stage_config "$stage"
  info "Building $(basename "$out") (about the size of the Windows ISO)…"
  remaster_iso "$ISO" "$out" "$stage"
  rm -rf "$stage"
  chmod 600 "$out"
  ok "Unattended ISO ready: $out"
  echo
  echo "  Create a UEFI VM (Secure Boot off, 2+ vCPU, 4 GB RAM, 64 GB disk) in any hypervisor,"
  echo "  attach this ISO as its only CD, and start it. Setup runs on its own."
  echo "  Administrator password: winserver password $NAME"
  echo "  Guest tools are installed automatically if you also attach the hypervisor's tools ISO."
  echo
}
