# shellcheck shell=bash
# Shared helpers: logging, paths, config files, ports, dependency checks.

WINSERVER_HOME="${WINSERVER_HOME:-$HOME/.winserver}"
VMS_DIR="$WINSERVER_HOME/vms"
CACHE_DIR="$WINSERVER_HOME/cache"
ISO_DIR="$CACHE_DIR/iso"
# UNIX sockets are limited to 104 bytes on macOS, so they live under a short path.
RUN_DIR="/tmp/winserver-$(id -u)"

# ---------------------------------------------------------------- logging

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_RST=""
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s ✓%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST" >&2; }

# ---------------------------------------------------------------- small utils

has() { command -v "$1" >/dev/null 2>&1; }

need() {
  local cmd="$1" hint="${2:-}"
  has "$cmd" && return 0
  if [ -n "$hint" ]; then die "'$cmd' not found. Install it with: $hint"; fi
  die "'$cmd' not found"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

confirm() {
  local prompt="$1" reply
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$prompt" >&2
  read -r reply || return 1
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

host_arch() { uname -m; }

# Free space in GiB on the volume holding $1.
free_gib() {
  local dir="$1"
  while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
  df -g "$dir" | awk 'NR==2 {print $4}'
}

require_free_space() {
  local dir="$1" want="$2" have
  have="$(free_gib "$dir")"
  if [ "$have" -lt "$want" ]; then
    die "need at least ${want} GiB free near $dir, only ${have} GiB available"
  fi
}

# Size like 8G / 8192M / 64G -> bytes / MiB helpers for validation.
size_to_mib() {
  local s n u
  s="$(upper "$1")"
  n="${s%[GMT]}"; u="${s#"$n"}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in
    G|"") echo $((n * 1024)) ;;
    M)    echo "$n" ;;
    T)    echo $((n * 1024 * 1024)) ;;
    *)    return 1 ;;
  esac
}

# QEMU option values use ',' as a separator; a literal comma is written ',,'.
qemu_escape() { printf '%s' "${1//,/,,}"; }

# Random string from an alphabet without look-alike characters.
rand_str() {
  local n="$1"
  openssl rand -base64 $((n * 4)) | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' | cut -c "1-$n"
}

# A password that meets Windows' default complexity rules (3 of 4 character classes).
gen_password() {
  local pw
  while :; do
    pw="$(rand_str 6)-$(rand_str 6)-$(rand_str 4)"
    case "$pw" in *[A-Z]*) ;; *) continue ;; esac
    case "$pw" in *[a-z]*) ;; *) continue ;; esac
    case "$pw" in *[0-9]*) ;; *) continue ;; esac
    printf '%s' "$pw"
    return 0
  done
}

# Locally administered, QEMU-style MAC address.
gen_mac() {
  printf '52:54:00:%s\n' "$(openssl rand -hex 3 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')"
}

# ---------------------------------------------------------------- ports

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

# Ports already promised to other VMs, even if they are not running.
ports_reserved() {
  local conf
  for conf in "$VMS_DIR"/*/vm.conf; do
    [ -f "$conf" ] || continue
    grep -E '^(RDP_PORT|SSH_PORT|WINRM_PORT|VNC_PORT)=' "$conf" | cut -d= -f2
  done
}

# First port >= $1 that is neither listening nor reserved by another VM.
find_free_port() {
  local port="$1" reserved
  reserved=" $(ports_reserved | tr '\n' ' ') "
  while :; do
    case "$reserved" in *" $port "*) port=$((port + 1)); continue ;; esac
    if port_in_use "$port"; then port=$((port + 1)); continue; fi
    printf '%s' "$port"
    return 0
  done
}

# ---------------------------------------------------------------- ISO mounting

# Mount an ISO read-only without showing it in Finder. Prints the mount point.
iso_mount() {
  local iso="$1" out
  out="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$iso")" ||
    die "could not mount $iso"
  printf '%s\n' "$out" | awk -F'\t' 'index($NF, "/Volumes/") == 1 {print $NF; exit}' | sed 's/[[:space:]]*$//'
}

iso_unmount() {
  hdiutil detach -quiet "$1" >/dev/null 2>&1 || hdiutil detach -force -quiet "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- JSON

# Run a small Python snippet over JSON on stdin. Python 3 ships with the
# Xcode Command Line Tools, which Homebrew already requires.
json_py() {
  need python3 "xcode-select --install"
  python3 -I -c "$1"
}
