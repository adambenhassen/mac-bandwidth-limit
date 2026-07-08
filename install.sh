#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Installs the locally-built app to /Applications and enables system-extension developer mode.
# The system extension + privileged helper both require this; distribution would need a paid
# Apple Developer account instead. Re-run build.sh first if you changed code.

APP_SRC="build/Build/Products/Debug/BandwidthLimit.app"
APP_DST="/Applications/BandwidthLimit.app"

[ -d "$APP_SRC" ] || { echo "build first: ./build.sh"; exit 1; }

echo "1/3  Enabling system-extension developer mode (needs sudo)…"
sudo systemextensionsctl developer on

echo "2/3  Installing to /Applications…"
# Must run from /Applications for SMAppService + sysext approval to stick.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "3/3  Launching…"
open "$APP_DST"

cat <<'EOF'

Next, in the menu-bar ⇅ icon:
  • Per-app throttle: On   → approve "BandwidthLimit Proxy" in
      System Settings ▸ General ▸ Login Items & Extensions ▸ (extensions)
  • Set global limit ▸ 20 Mbps → approve the helper if prompted (Login Items)

Verify (see verify.sh) once approved.
EOF
