# shellcheck shell=bash
# Install media: ARM64 builds through UUP dump, the x64 evaluation ISO,
# the virtio drivers, and inspection of whatever ISO the user brings.

UUP_API="https://api.uupdump.net"
UUP_SITE="https://uupdump.net"
# Microsoft's own redirect to the Windows Server 2025 evaluation ISO (en-US).
EVAL_X64_URL_EN_US="https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
EVAL_CENTER_URL="https://www.microsoft.com/evalcenter/download-windows-server-2025"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_ISO="$CACHE_DIR/virtio-win.iso"
UUP_EDITIONS="SERVERDATACENTER SERVERDATACENTERCORE SERVERSTANDARD SERVERSTANDARDCORE"

# ---------------------------------------------------------------- UUP dump

# "uuid<TAB>build<TAB>date<TAB>title" for full ARM64 Windows Server builds, newest first.
uup_server_builds() {
  curl -fsS --max-time 60 "$UUP_API/listid.php?search=Windows%20Server&sortByDate=1" |
    json_py '
import json, sys, datetime
builds = json.load(sys.stdin)["response"].get("builds") or {}
items = builds.values() if isinstance(builds, dict) else builds
for b in items:
    title = b.get("title", "")
    if b.get("arch") != "arm64" or not title.startswith("Windows Server"):
        continue
    day = datetime.datetime.fromtimestamp(b.get("created") or 0, datetime.timezone.utc)
    print("\t".join([b["uuid"], b["build"], day.strftime("%Y-%m-%d"), title]))
'
}

# Space-separated list of languages a build offers.
uup_langs() {
  curl -fsS --max-time 60 "$UUP_API/listlangs.php?id=$1" |
    json_py 'import json,sys; print(" ".join(json.load(sys.stdin)["response"].get("langList") or []))'
}

# Space-separated list of editions a build offers in a language.
uup_editions() {
  curl -fsS --max-time 60 "$UUP_API/listeditions.php?id=$1&lang=$2" |
    json_py 'import json,sys; print(" ".join(json.load(sys.stdin)["response"].get("editionList") or []))'
}

# Does Windows Update still serve the files of a build? Prints "ok" or the
# UUP dump error (EMPTY_FILELIST once Microsoft has pulled an expired build).
uup_files_status() {
  # No -f: the API reports errors with an HTTP error status and a JSON body.
  curl -sS --max-time 60 "$UUP_API/get.php?id=$1&lang=$2&edition=$3" 2>/dev/null |
    json_py '
import json, sys
r = json.load(sys.stdin)["response"]
print(r.get("error") or ("ok" if r.get("files") else "EMPTY_FILELIST"))
' 2>/dev/null || echo "UNREACHABLE"
}

cmd_builds() {
  local rows
  info "Asking UUP dump which ARM64 Windows Server builds Microsoft serves…"
  rows="$(uup_server_builds)" || die "could not reach $UUP_API"
  [ -n "$rows" ] || die "no ARM64 Windows Server builds found"
  printf '%s%-38s  %-12s  %-10s  %s%s\n' "$C_BLD" "ID" "BUILD" "DATE" "TITLE" "$C_RST"
  printf '%s\n' "$rows" | awk -F'\t' '{printf "%-38s  %-12s  %-10s  %s\n", $1, $2, $3, $4}'
  echo
  warn "ARM64 Windows Server is only published as Insider Preview builds. They are time-limited:"
  dim  "  each one stops working on a fixed date (check with 'winver' in the guest)."
  dim  "  Use them for labs and testing, not production. See docs/LICENSING.md."
}

fetch_arm64() {
  local build="" lang="en-us" rows row candidate status uuid buildnum title langs eds want e work pkg iso out
  while [ $# -gt 0 ]; do
    case "$1" in
      --build) build="${2:?--build needs a value}"; shift 2 ;;
      --lang)  lang="$(lower "${2:?--lang needs a value}")"; shift 2 ;;
      -h|--help)
        echo "Usage: winserver fetch arm64 [--build <id|build-number>] [--lang en-us]"; return 0 ;;
      *) die "unknown option '$1'" ;;
    esac
  done

  need aria2c "brew install aria2"
  need cabextract "brew install cabextract"
  need wimlib-imagex "brew install wimlib"
  has mkisofs || has genisoimage || die "'mkisofs' not found. Install it with: brew install cdrtools"
  need unzip

  info "Looking up ARM64 Windows Server builds…"
  rows="$(uup_server_builds)" || die "could not reach $UUP_API"
  if [ -n "$build" ]; then
    rows="$(printf '%s\n' "$rows" | awk -F'\t' -v b="$build" '$1 == b || $2 == b {print; exit}')"
    [ -n "$rows" ] || die "build '$build' not found (see 'winserver builds')"
  fi

  # Newest build whose files Microsoft still serves: expired previews get pulled.
  row=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    uuid="$(printf '%s' "$candidate" | cut -f1)"
    buildnum="$(printf '%s' "$candidate" | cut -f2)"
    status="$(uup_files_status "$uuid" "$lang" SERVERDATACENTER)"
    if [ "$status" = USER_RATE_LIMITED ]; then
      warn "UUP dump is rate-limiting requests; waiting a minute…"
      sleep 60
      status="$(uup_files_status "$uuid" "$lang" SERVERDATACENTER)"
    fi
    if [ "$status" = ok ]; then row="$candidate"; break; fi
    dim "  $buildnum: no longer served by Microsoft ($status)"
    sleep 2
  done <<ROWS
$rows
ROWS
  if [ -z "$row" ]; then
    die "Microsoft no longer serves the files of any ARM64 Windows Server build${build:+ matching $build}.
  Preview builds are pulled once they expire. Until Microsoft publishes a new one:
    - use an ARM64 Windows Server ISO you already have:  winserver create <name> --iso FILE
    - or the official x64 evaluation (emulated on Apple Silicon):  winserver fetch x64
  See docs/LICENSING.md."
  fi
  title="$(printf '%s' "$row" | cut -f4)"
  ok "$title"

  langs=" $(uup_langs "$uuid") "
  case "$langs" in *" $lang "*) ;; *) die "language '$lang' not offered. Available:$langs" ;; esac

  eds=" $(uup_editions "$uuid" "$lang") "
  want=""
  for e in $UUP_EDITIONS; do
    case "$eds" in *" $e "*) want="${want:+$want;}$e" ;; esac
  done
  [ -n "$want" ] || die "no Standard/Datacenter editions in this build (got:$eds)"
  ok "Editions: ${want//;/, }"

  out="$ISO_DIR/winserver-arm64-$buildnum-$lang.iso"
  if [ -f "$out" ]; then
    ok "Already built: $out"
    return 0
  fi

  work="$CACHE_DIR/uup/$buildnum-$lang"
  mkdir -p "$work" "$ISO_DIR"
  require_free_space "$work" 20

  pkg="$work/package.zip"
  info "Downloading the UUP dump conversion package…"
  curl -fsSL --max-time 120 -X POST \
    --data "autodl=2&updates=1&cleanup=1" \
    -o "$pkg" "$UUP_SITE/get.php?id=$uuid&pack=$lang&edition=$want" ||
    die "could not download the conversion package from $UUP_SITE"
  unzip -tq "$pkg" >/dev/null 2>&1 || die "UUP dump did not return a valid zip (see $pkg)"
  unzip -oq "$pkg" -d "$work"
  [ -f "$work/uup_download_macos.sh" ] || die "package has no uup_download_macos.sh"

  # The converter insists on chntpw, but only uses it to tweak the registry of
  # boot.wim image 1 (WinPE for repair/upgrade). Setup boots from image 2, which
  # it never touches, so a no-op stand-in is safe when chntpw isn't installed.
  local shim_path="$PATH"
  if ! has chntpw; then
    mkdir -p "$work/shim"
    printf '#!/bin/sh\n# winserver: no-op stand-in for chntpw\ncat >/dev/null\nexit 0\n' >"$work/shim/chntpw"
    chmod +x "$work/shim/chntpw"
    shim_path="$work/shim:$PATH"
    dim "  chntpw not installed; using a no-op stand-in (only affects the WinPE repair image)."
  fi

  info "Downloading Windows from Microsoft's servers and building the ISO."
  dim  "  This is UUP dump's own converter. It takes 10-30 minutes and ~15 GiB of temporary space."
  ( cd "$work" && PATH="$shim_path" bash ./uup_download_macos.sh ) || die "conversion failed (logs in $work)"

  iso="$(find "$work" -maxdepth 1 -iname '*.iso' -print | head -n 1)"
  [ -n "$iso" ] || die "conversion finished but no ISO found in $work"
  mv "$iso" "$out"
  rm -rf "$work"
  ok "ISO ready: $out"
}

# ---------------------------------------------------------------- x64 evaluation

fetch_x64() {
  local lang="en-us" url="" out
  while [ $# -gt 0 ]; do
    case "$1" in
      --lang) lang="$(lower "${2:?--lang needs a value}")"; shift 2 ;;
      --url)  url="${2:?--url needs a value}"; shift 2 ;;
      -h|--help)
        echo "Usage: winserver fetch x64 [--lang en-us] [--url <iso-url>]"; return 0 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  if [ -z "$url" ]; then
    [ "$lang" = "en-us" ] || die "only en-us has a direct link. Pick your language at
  $EVAL_CENTER_URL
then run: winserver fetch x64 --lang $lang --url <link>   (or pass --iso <file> to 'create')"
    url="$EVAL_X64_URL_EN_US"
  fi
  out="$ISO_DIR/winserver-x64-2025-eval-$lang.iso"
  if [ -f "$out" ]; then ok "Already downloaded: $out"; return 0; fi
  mkdir -p "$ISO_DIR"
  require_free_space "$ISO_DIR" 8
  info "Downloading the Windows Server 2025 evaluation ISO from Microsoft (~5.6 GiB)…"
  curl -fL --retry 3 -C - -o "$out.part" "$url" || die "download failed (re-run to resume)"
  mv "$out.part" "$out"
  ok "ISO ready: $out"
  dim "  The evaluation runs for 180 days. See docs/LICENSING.md."
}

# ---------------------------------------------------------------- virtio drivers

fetch_drivers() {
  if [ -f "$VIRTIO_ISO" ]; then ok "Already downloaded: $VIRTIO_ISO"; return 0; fi
  mkdir -p "$CACHE_DIR"
  info "Downloading virtio-win drivers (~850 MiB)…"
  curl -fL --retry 3 -C - -o "$VIRTIO_ISO.part" "$VIRTIO_URL" || die "download failed (re-run to resume)"
  mv "$VIRTIO_ISO.part" "$VIRTIO_ISO"
  ok "Drivers ready: $VIRTIO_ISO"
}

cmd_fetch() {
  local what="${1:-}"
  [ $# -gt 0 ] && shift
  case "$what" in
    arm64|aarch64) fetch_arm64 "$@" ;;
    x64|amd64|x86_64) fetch_x64 "$@" ;;
    drivers|virtio) fetch_drivers "$@" ;;
    *) die "usage: winserver fetch arm64|x64|drivers" ;;
  esac
}

cmd_media() {
  local f found=0
  for f in "$ISO_DIR"/*.iso "$VIRTIO_ISO"; do
    [ -f "$f" ] || continue
    found=1
    printf '%-8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
  done
  [ "$found" = 1 ] || dim "No media yet. Try: winserver fetch arm64   or   winserver fetch x64"
}

# Newest cached ISO for an architecture, if any.
cached_iso() {
  local arch="$1"
  # shellcheck disable=SC2012
  ls -t "$ISO_DIR"/winserver-"$arch"-*.iso 2>/dev/null | head -n 1 || true
}

# ---------------------------------------------------------------- ISO inspection

# Print one line per image in a mounted Windows ISO:
#   index<TAB>arch<TAB>edition-id<TAB>installation-type<TAB>language<TAB>name
# Needs wimlib; returns 1 without it.
iso_images() {
  local mnt="$1" wim
  has wimlib-imagex || return 1
  for wim in "$mnt/sources/install.wim" "$mnt/sources/install.esd"; do
    [ -f "$wim" ] && break
  done
  [ -f "$wim" ] || die "no sources/install.wim or install.esd on this ISO — is it a Windows ISO?"
  wimlib-imagex info "$wim" | awk -F': *' '
    /^Index:/              { if (idx) print_row(); idx=$2; name=""; arch=""; ed=""; type=""; lang="" }
    /^Name:/               { name=$2 }
    /^Architecture:/       { arch=$2 }
    /^Edition ID:/         { ed=$2 }
    /^Installation Type:/  { type=$2 }
    /^Default Language:/   { lang=$2 }
    function print_row() { printf "%s\t%s\t%s\t%s\t%s\t%s\n", idx, arch, ed, type, lang, name }
    END { if (idx) print_row() }'
}

# Architecture of a mounted ISO from its UEFI boot loader (works without wimlib).
iso_arch_from_boot() {
  local mnt="$1"
  if [ -f "$mnt/efi/boot/bootaa64.efi" ] || [ -f "$mnt/EFI/BOOT/BOOTAA64.EFI" ]; then echo arm64
  elif [ -f "$mnt/efi/boot/bootx64.efi" ] || [ -f "$mnt/EFI/BOOT/BOOTX64.EFI" ]; then echo x64
  else echo unknown
  fi
}

# Choose the image index for an edition and experience from iso_images output.
#   $1 images, $2 standard|datacenter, $3 core|desktop
pick_image() {
  printf '%s\n' "$1" | awk -F'\t' -v ed="$2" -v want="$3" '
    {
      e = tolower($3); t = $4
      if (e ~ /turbine|azure/) next
      if (index(e, ed) == 0) next
      core = (t == "Server Core")
      if ((want == "core") != core) next
      print $1; exit
    }'
}
