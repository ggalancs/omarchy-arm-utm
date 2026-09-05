#!/bin/bash
# Builds the .utm bundle by hand and registers it with UTM.
#
# UTM 4.7 only scans ~/Library/Containers/com.utmapp.UTM/Data/Documents/ once,
# when the app starts (listRefresh() is called from ContentView.onAppear), so
# UTM has to be quit, the bundle written, and the app opened again.
# config.plist requires all TEN top-level keys: they are decoded with decode(),
# not decodeIfPresent(), and omitting any one makes UTM reject it.
set -euo pipefail

# The root is derived from the script's own location, so the repo can be
# cloned anywhere without editing anything.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
NAME="${1:-Omarchy ARM}"
: "${DEST_DIR:=$DOCS}"
BUNDLE="$DEST_DIR/$NAME.utm"
: "${SRC_QCOW:=$ROOT/vm/omarchy-arm.qcow2}"
VARS_TPL=/Applications/UTM.app/Contents/Resources/qemu/edk2-arm-vars.fd
: "${UTM_CPUS:=8}"
: "${UTM_MEM:=8192}"

[ -f "$SRC_QCOW" ] || { echo "!! $SRC_QCOW is missing"; exit 1; }
[ -f "$VARS_TPL" ] || { echo "!! the UEFI NVRAM template $VARS_TPL is missing"; exit 1; }

# Identifiers: random by default, DERIVED when UTM_SEED is set.
#
# The bundle that ships used to mint a fresh VM UUID, disk UUID and MAC on
# every run, so the zip's sha256 was different every time. ph_package refuses
# to finish while the six documents that publish that checksum disagree with
# it, and told the operator to "put $NEWSUM in the files above and package
# again" -- which produced yet another hash. The instruction described a loop
# that could not be closed, and the only way out was to stop believing the
# gate.
#
# With a seed the same image packages to the same bytes, so the checksum can
# be written down once. The build VM registered in UTM keeps random ones: two
# VMs sharing a UUID in the same UTM library is a real collision, and that one
# is not published anyway.
if [ -n "${UTM_SEED:-}" ]; then
  # Version and variant nibbles are forced so the result is a well-formed v4
  # UUID and not merely 32 hex characters with dashes in them.
  _seeded_uuid() {
    local h
    h=$(printf '%s\0%s' "$UTM_SEED" "$1" | shasum -a 256 | cut -c1-32)
    printf '%s-%s-4%s-8%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  }
  VM_UUID=$(_seeded_uuid vm)
else
  VM_UUID=$(uuidgen)
fi
# Whoever receives the bundle reads these notes in UTM before starting it:
# they have to state the real credentials, not the builder's.
NOTES_USER="${NOTES_USER:-omarchy}"
NOTES_PASS="${NOTES_PASS:-$NOTES_USER}"
# These two go inside XML. A '&' or a '<' in the password broke config.plist,
# and since `plutil -lint` runs at the end, the failure arrived AFTER the whole
# disk had been copied: nine gigabytes spent to die with a message that never
# mentioned the password at all.
xmlq() { printf "%s" "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_USER=$(xmlq "$NOTES_USER")
NOTES_PASS=$(xmlq "$NOTES_PASS")

if [ -n "${UTM_SEED:-}" ]; then
  DISK_UUID=$(_seeded_uuid disk)
  # Locally administered unicast, same as the random branch: the 02 prefix is
  # what makes it legal to invent one at all.
  _m=$(printf '%s\0mac' "$UTM_SEED" | shasum -a 256 | cut -c1-10)
  MAC=$(printf '02:%s:%s:%s:%s:%s' "${_m:0:2}" "${_m:2:2}" "${_m:4:2}" "${_m:6:2}" "${_m:8:2}" | tr 'a-f' 'A-F')
else
  DISK_UUID=$(uuidgen)
  MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
fi

# UTM only scans Documents when the app starts, so it has to be restarted for
# the bundle to be recognised. But quitting it by force takes down whatever VMs
# the user has running, so that is checked first.
if [ "$DEST_DIR" = "$DOCS" ] && pgrep -x UTM >/dev/null; then
  UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
  VMS_RUNNING=$("$UTMCTL" list 2>/dev/null | awk '$2=="started"{print $3" "$4}' | grep -v "^$" || true)
  if [ -n "$VMS_RUNNING" ]; then
    echo "==> THERE ARE VMs RUNNING in UTM:"
    echo "$VMS_RUNNING" | sed 's/^/      /'
    echo "    Registering the bundle needs UTM restarted, and that would cut them off."
    if [ -t 0 ] && [ "${ASSUME_YES:-}" != "1" ]; then
      printf "    Close them and restart UTM? [y/N]: "
      read -r R </dev/tty || R=""
      case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]')" in
        s|si|y|yes) : ;;
        *) echo "==> UTM not restarted: import the bundle by hand with File -> Import"; SKIP_RESTART=1 ;;
      esac
    else
      echo "==> unattended mode: UTM is NOT closed. Import the bundle by hand."
      SKIP_RESTART=1
    fi
  fi
  if [ "${SKIP_RESTART:-0}" != "1" ]; then
    echo "==> quitting UTM so it rescans Documents"
    osascript -e 'quit app "UTM"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x UTM >/dev/null || break; sleep 1; done
    pgrep -x UTM >/dev/null && { pkill -x UTM || true; sleep 2; }
  fi
fi

echo "==> creating $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Data"
echo "    copying disk ($(du -h "$SRC_QCOW" | cut -f1))"
cp -c "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2" 2>/dev/null || cp "$SRC_QCOW" "$BUNDLE/Data/$DISK_UUID.qcow2"
# The VARS half of the aarch64 UEFI uses the edk2-ARM-vars.fd template (not
# aarch64);
# UTM supplies edk2-aarch64-code.fd at run time via -L.
install -m 0644 "$VARS_TPL" "$BUNDLE/Data/efi_vars.fd"

cat > "$BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Information</key>
	<dict>
		<key>Name</key>
		<string>$NAME</string>
		<key>UUID</key>
		<string>$VM_UUID</string>
		<key>IconCustom</key>
		<false/>
		<key>Icon</key>
		<string>arch-linux</string>
		<key>Notes</key>
		<string>Arch Linux ARM (aarch64) + Hyprland + Omarchy 4 dotfiles.
User: ${NOTES_USER} · Password: ${NOTES_PASS} (root too). Change it with passwd.
The Option key (⌥) acts as SUPER. Read README.md.</string>
	</dict>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>Target</key>
		<string>virt</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>CPUCount</key>
		<integer>$UTM_CPUS</integer>
		<key>ForceMulticore</key>
		<false/>
		<key>MemorySize</key>
		<integer>$UTM_MEM</integer>
		<key>JITCacheSize</key>
		<integer>0</integer>
	</dict>
	<key>QEMU</key>
	<dict>
		<key>DebugLog</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
		<key>RNGDevice</key>
		<true/>
		<key>BalloonDevice</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>PS2Controller</key>
		<false/>
		<key>AdditionalArguments</key>
		<array/>
	</dict>
	<key>Input</key>
	<dict>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
	</dict>
	<key>Sharing</key>
	<dict>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
		<key>ClipboardSharing</key>
		<true/>
	</dict>
	<key>Display</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-gpu-gl-pci</string>
			<key>DynamicResolution</key>
			<true/>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
			<key>DownscalingFilter</key>
			<string>Linear</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>$DISK_UUID</string>
			<key>ImageName</key>
			<string>$DISK_UUID.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Network</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Shared</string>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>MacAddress</key>
			<string>$MAC</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Ptty</string>
			<key>Target</key>
			<string>Auto</string>
		</dict>
	</array>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> validating the plist"
plutil -lint "$BUNDLE/config.plist"
du -sh "$BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/Data"

if [ "$DEST_DIR" = "$DOCS" ]; then
  echo "==> opening UTM so it registers the bundle"
  open -a UTM
  sleep 6
  /Applications/UTM.app/Contents/MacOS/utmctl list || true
else
  echo "==> bundle created outside UTM's folder (it is not registered)"
fi

echo ""
echo "Bundle:  $BUNDLE"
echo "UUID:    $VM_UUID"
echo "Start it: /Applications/UTM.app/Contents/MacOS/utmctl start \"$NAME\""
