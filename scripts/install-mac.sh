#!/bin/zsh
# Builds the Mac sender and opens it (it lives in the menu bar).
# Permissions (Screen Recording, Accessibility) follow the app's signature, so they survive rebuilds.
set -euo pipefail
cd "${0:A:h}/.."
[[ -f signing.local ]] && source ./signing.local
: "${TETHER_TEAM_ID:?Set TETHER_TEAM_ID (copy signing.example to signing.local and fill it in)}"
SIGNING=(DEVELOPMENT_TEAM="$TETHER_TEAM_ID" TETHER_BUNDLE_PREFIX="${TETHER_BUNDLE_PREFIX:-com.example}")
xcodebuild -project IPadDisplay.xcodeproj -scheme iPadDisplayMac -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates "${SIGNING[@]}" build > build.log 2>&1 || { grep -E "error" build.log | head -20; echo "Build failed; full log in build.log"; exit 1; }
pkill -x "Tether" 2>/dev/null || true
while pgrep -x "Tether" >/dev/null; do sleep 0.2; done
sleep 1
open "build/Build/Products/Release/Tether.app" || { sleep 2; open "build/Build/Products/Release/Tether.app"; }
echo "Tether is running in the menu bar (iPad icon)."
