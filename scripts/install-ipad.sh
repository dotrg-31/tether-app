#!/bin/zsh
# Builds the iPad receiver, signs it with the free personal team and installs it on the
# USB-connected iPad. Re-run every 7 days (free provisioning expires) or after code changes.
set -euo pipefail
cd "${0:A:h}/.."
[[ -f signing.local ]] && source ./signing.local
: "${TETHER_TEAM_ID:?Set TETHER_TEAM_ID (copy signing.example to signing.local and fill it in)}"
SIGNING=(DEVELOPMENT_TEAM="$TETHER_TEAM_ID" TETHER_BUNDLE_PREFIX="${TETHER_BUNDLE_PREFIX:-com.example}")
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ && /physical|available/ && $0 !~ /simulated/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -z "$DEVICE" ]] && { echo "No iPad found. Connect it with the cable, unlock it and tap Trust."; exit 1; }
echo "Installing on iPad $DEVICE"
xcodebuild -project IPadDisplay.xcodeproj -scheme iPadDisplay -configuration Release \
  -derivedDataPath build -destination "id=$DEVICE" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "${SIGNING[@]}" build > build.log 2>&1 || { grep -E "error" build.log | head -20; echo "Build failed; full log in build.log"; exit 1; }
APP="build/Build/Products/Release-iphoneos/Tether.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "${TETHER_BUNDLE_PREFIX:-com.example}.ipaddisplay" || \
  echo "Installed. If it will not open: Settings > General > VPN & Device Management > trust the developer, and make sure Developer Mode is on."
