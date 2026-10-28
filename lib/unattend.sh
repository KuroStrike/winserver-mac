# shellcheck shell=bash
# The config disc: autounattend.xml, first-boot scripts, drivers and settings.
# Windows Setup looks for autounattend.xml at the root of every CD drive, so
# the Windows ISO itself never has to be modified.

VIRTIO_DRIVERS="NetKVM viostor vioscsi Balloon vioserial viorng"

# base64(UTF-16LE(password + field)), what Setup expects when PlainText is false.
unattend_password() {
  printf '%s%s' "$1" "$2" | iconv -f UTF-8 -t UTF-16LE | base64
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Single-quoted PowerShell string literal.
ps_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Fill @@KEY@@ placeholders in a template from WS_KEY environment variables.
render_template() {
  local template="$1"
  shift
  env "$@" python3 -I -c '
import os, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for key, value in os.environ.items():
    if key.startswith("WS_"):
        text = text.replace("@@" + key[3:] + "@@", value)
left = sorted(set(re.findall(r"@@[A-Z_]+@@", text)))
if left:
    sys.exit("unfilled placeholders: " + ", ".join(left))
sys.stdout.write(text)
' "$template"
}

# <DriverPaths> for every drive letter the config disc might get in WinPE.
driver_paths_xml() {
  local arch="$1" n=0 letter
  printf '    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="%s" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">\n' "$arch"
  printf '      <DriverPaths>\n'
  for letter in D E F G H I J K L M; do
    n=$((n + 1))
    printf '        <PathAndCredentials wcm:action="add" wcm:keyValue="%s"><Path>%s:\\drivers</Path></PathAndCredentials>\n' "$n" "$letter"
  done
  printf '      </DriverPaths>\n'
  printf '    </component>\n'
}

# Copy the ARM64 virtio drivers Windows needs (network, storage, balloon…) into $1.
copy_virtio_drivers() {
  local out="$1" mnt drv ver src copied=0
  [ -f "$VIRTIO_ISO" ] || fetch_drivers
  mnt="$(iso_mount "$VIRTIO_ISO")"
  for drv in $VIRTIO_DRIVERS; do
    for ver in 2k25 w11; do
      src="$mnt/$drv/$ver/ARM64"
      if [ -d "$src" ]; then
        mkdir -p "$out/$drv"
        cp -R "$src/" "$out/$drv/"
        copied=$((copied + 1))
        break
      fi
    done
  done
  iso_unmount "$mnt"
  [ "$copied" -gt 0 ] || die "no ARM64 drivers found in $VIRTIO_ISO"
  ok "Added $copied ARM64 virtio drivers"
}

# Windows 11 rather than Windows Server: the editions cmd_create allows for it.
is_client() { case "${EDITION:-}" in pro|enterprise|education) return 0 ;; esac; return 1; }

# Write the config payload for the loaded VM (see load_vm) into directory $1:
# answer file, first-boot scripts, settings, drivers, SSH key, custom script.
stage_config() {
  local stage="$1" arch_tag drivers="" key="" specialize="" setup="" oobe="" manager="" pw feature features=""
  local commands=()
  pw="$(cat "$VM_DIR/password")"
  case "$ARCH" in arm64) arch_tag=arm64 ;; *) arch_tag=amd64 ;; esac

  if [ "$ARCH" = arm64 ]; then
    copy_virtio_drivers "$stage/drivers"
    drivers="$(driver_paths_xml "$arch_tag")"
  fi
  if [ -n "${PRODUCT_KEY:-}" ]; then
    key="        <ProductKey><Key>$(xml_escape "$PRODUCT_KEY")</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
  fi
  # Commands for the specialize pass ("description|command"); they take effect
  # from the reboot that follows.
  # Windows reads the hardware clock as local time unless told otherwise.
  if [ "${RTC:-}" = utc ]; then
    commands+=('Hardware clock is UTC|reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f')
  fi
  # Windows 11 turns on BitLocker device encryption by itself when the VM has a TPM.
  if is_client; then
    commands+=('No automatic BitLocker|reg.exe add HKLM\SYSTEM\CurrentControlSet\Control\BitLocker /v PreventDeviceEncryption /t REG_DWORD /d 1 /f')
  fi
  if [ "${#commands[@]}" -gt 0 ]; then
    specialize="$(
      printf '    <component name="Microsoft-Windows-Deployment" processorArchitecture="%s" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">\n' "$arch_tag"
      printf '      <RunSynchronous>\n'
      n=0
      for c in "${commands[@]}"; do
        n=$((n + 1))
        printf '        <RunSynchronousCommand wcm:action="add">\n'
        printf '          <Order>%s</Order>\n' "$n"
        printf '          <Description>%s</Description>\n' "${c%%|*}"
        printf '          <Path>%s</Path>\n' "${c#*|}"
        printf '        </RunSynchronousCommand>\n'
      done
      printf '      </RunSynchronous>\n'
      printf '    </component>')"
  fi

  if is_client; then
    # Windows 11 checks for TPM 2.0, Secure Boot and 4 GB of RAM, which not every
    # hypervisor gives a VM (VMware only with encryption): skip the checks, the
    # way Microsoft's LabConfig switches allow. Then no local account screen:
    # the built-in Administrator gets the password, as on Windows Server.
    setup="$(printf '%s\n' '      <RunSynchronous>'
      n=0
      for check in TPM SecureBoot RAM; do
        n=$((n + 1))
        printf '        <RunSynchronousCommand wcm:action="add"><Order>%s</Order><Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v Bypass%sCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>\n' "$n" "$check"
      done
      printf '%s\n' '      </RunSynchronous>')"
    oobe="        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>"
  else
    manager="    <component name=\"Microsoft-Windows-ServerManager-SvrMgrNc\" processorArchitecture=\"$arch_tag\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">
      <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
    </component>"
  fi

  render_template "$WINSERVER_ROOT/templates/autounattend.xml" \
    WS_ARCH="$arch_tag" \
    WS_UI_LANG="$(xml_escape "$UI_LANG")" \
    WS_LOCALE="$(xml_escape "$LOCALE")" \
    WS_KEYBOARD="$(xml_escape "$KEYBOARD")" \
    WS_TIMEZONE="$(xml_escape "$TIMEZONE")" \
    WS_HOSTNAME="$(xml_escape "$HOSTNAME_WIN")" \
    WS_IMAGE_INDEX="$IMAGE_INDEX" \
    WS_ORGANIZATION="winserver-mac" \
    WS_ADMIN_PASSWORD="$(unattend_password "$pw" AdministratorPassword)" \
    WS_AUTOLOGON_PASSWORD="$(unattend_password "$pw" Password)" \
    WS_DRIVER_PATHS="$drivers" \
    WS_PRODUCT_KEY="$key" \
    WS_SPECIALIZE_EXTRA="$specialize" \
    WS_SETUP_EXTRA="$setup" \
    WS_OOBE_EXTRA="$oobe" \
    WS_SERVER_MANAGER="$manager" \
    >"$stage/autounattend.xml" || die "could not render autounattend.xml"
  if has xmllint; then
    xmllint --noout "$stage/autounattend.xml" || die "generated autounattend.xml is not valid XML"
  fi

  cp "$WINSERVER_ROOT/templates/firstboot.ps1" "$WINSERVER_ROOT/templates/post-setup.ps1" "$stage/"
  for feature in $(printf '%s' "${FEATURES:-}" | tr ',' ' '); do
    features="${features:+$features, }$(ps_quote "$feature")"
  done
  {
    echo "# Generated by winserver for VM '$NAME'."
    echo "\$WS_Role     = $(ps_quote "${ROLE:-}")"
    echo "\$WS_Domain   = $(ps_quote "${DOMAIN:-}")"
    echo "\$WS_Netbios  = $(ps_quote "${NETBIOS:-}")"
    echo "\$WS_Features = @($features)"
    # Only a domain controller needs the password inside Windows (DSRM, re-logon).
    if [ "${ROLE:-}" = "ad-dc" ]; then
      echo "\$WS_Password = $(ps_quote "$pw")"
    else
      echo "\$WS_Password = ''"
    fi
  } >"$stage/settings.ps1"
  if [ -f "$VM_DIR/custom.ps1" ]; then cp "$VM_DIR/custom.ps1" "$stage/custom.ps1"; fi
  if [ -f "$VM_DIR/authorized_keys" ]; then cp "$VM_DIR/authorized_keys" "$stage/authorized_keys"; fi
  echo "winserver config disc" >"$stage/winserver.tag"
}

# Build $VM_DIR/config.iso, a small disc to attach next to the Windows ISO.
build_config_iso() {
  local stage out="$VM_DIR/config.iso"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/winserver-config.XXXXXX")"
  stage_config "$stage"
  rm -f "$out"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name WSCONFIG -o "$out" "$stage" ||
    die "could not build the config disc"
  rm -rf "$stage"
  chmod 600 "$out"
}
