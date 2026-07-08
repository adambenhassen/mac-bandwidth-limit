#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Generates the Xcode project from project.yml and builds all three targets (app + system
# extension + privileged helper), ad-hoc signed for local dev. Unlike mac-latency-mon this needs
# Xcode + xcodegen because a NetworkExtension system extension can't be built with bare swiftc.

command -v xcodegen >/dev/null || { echo "need xcodegen: brew install xcodegen"; exit 1; }

xcodegen generate
xcodebuild -project BandwidthLimit.xcodeproj -scheme BandwidthLimit \
    -configuration Debug -derivedDataPath build build

APP="build/Build/Products/Debug/BandwidthLimit.app"
echo "Built $APP"
echo "Install + run:  ./install.sh"
