#!/bin/bash
# Offline visual snapshots: builds the popover against the app's sources (minus
# the @main entry point) and renders a fixed set of states, light and dark, to
# build/snapshots/*.png. No network, account, Keychain or device.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sources=()
for f in App/Sources/*.swift; do
    [[ "$f" == */DysonBarApp.swift ]] || sources+=("$f")
done
swiftc -D DEBUG -target arm64-apple-macos14.0 -o build/snapshot \
    Tests/snapshot/main.swift "${sources[@]}"
build/snapshot build/snapshots
