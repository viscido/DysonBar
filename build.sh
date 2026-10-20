#!/bin/bash
# Build DysonBar.app (Apple silicon) into build/.
# Needs Xcode or the Command Line Tools (xcode-select --install).
#   ./build.sh            build
#   ./build.sh --install  build, then copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -eq 0 ]]; then
    echo "Run build.sh as your normal user, without sudo: it asks for your password" >&2
    echo "only if /Applications needs it. (A build made with sudo leaves root-owned files.)" >&2
    exit 1
fi

MIN_MACOS=14.0
APP=build/DysonBar.app

if [[ -e build && ! -O build ]]; then
    echo "build/ belongs to another user (an earlier run with sudo). Remove it once with:" >&2
    echo "  sudo rm -rf \"$PWD/build\"" >&2
    exit 1
fi
rm -rf build
mkdir -p "$APP/Contents/MacOS"

echo "== compiling =="
# -file-prefix-map: keep local folder names out of the binary.
swiftc -parse-as-library -O -target "arm64-apple-macos$MIN_MACOS" -file-prefix-map "$PWD=." \
    -o "$APP/Contents/MacOS/DysonBar" App/Sources/*.swift
cp App/Info.plist "$APP/Contents/Info.plist"

echo "== signing (ad-hoc) =="
codesign --force --sign - "$APP"
echo "== built $(pwd)/$APP =="

if [[ "${1:-}" == "--install" ]]; then
    pkill -x DysonBar 2>/dev/null && sleep 1 || true
    target=/Applications/DysonBar.app
    sudo=""
    # An older copy installed as root (or a locked /Applications) needs sudo,
    # once: the new copy is handed back to you so later installs don't.
    if [[ ! -w /Applications ]] || [[ -e "$target" && ! -O "$target" ]]; then
        echo "== /Applications needs your password once =="
        sudo=sudo
    fi
    $sudo rm -rf "$target"
    $sudo cp -R "$APP" /Applications/
    [[ -n "$sudo" ]] && sudo chown -R "$(id -un)" "$target"
    open "$target"
    echo "== installed to /Applications =="
fi
