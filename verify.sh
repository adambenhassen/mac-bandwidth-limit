#!/bin/bash
set -uo pipefail

# End-to-end checks. Run after install.sh and after approving the extension + helper.

echo "=== system extension state (want: [activated enabled]) ==="
systemextensionsctl list | grep -i bandwidthlimit || echo "  (not listed — enable 'Per-app throttle' in the app, then approve)"

echo
echo "=== helper daemon registered? ==="
launchctl print system/com.local.bandwidthlimit.helper >/dev/null 2>&1 \
  && echo "  helper: loaded" || echo "  helper: not loaded (set a global limit in the app to register it)"

echo
echo "=== global cap check ==="
echo "Set a global limit (e.g. 20 Mbps) in the app, then this download should cap near it:"
echo "  running: curl 100MB from cloudflare…"
URL='https://speed.cloudflare.com/__down?bytes=104857600'
curl -s -o /dev/null -w "  measured: %{speed_download} bytes/s  (= %{speed_download} * 8 / 1e6 Mbps)\n" "$URL" || true

echo
echo "=== dummynet pipes (present only while a global cap is active) ==="
sudo dnctl list 2>/dev/null | grep -i "pipe" || echo "  (no pipes — set a global limit to create them)"

echo
cat <<'EOF'
=== per-app throttle (manual) ===
1. Turn on "Per-app throttle" and approve the extension.
2. In the ⇅ menu, open a busy app's submenu → set e.g. 5 Mbps.
3. Start a big download in THAT app and another download in a DIFFERENT app.
   The limited app should pin near 5 Mbps in the "Live usage" list while the other runs free.
EOF
