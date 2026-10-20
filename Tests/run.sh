#!/bin/bash
# Offline end-to-end tests: builds the harness against the app's model and
# control sources and runs it against a fake Dyson cloud (no network, no account).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/harness Tests/harness/main.swift \
    App/Sources/SessionStore.swift App/Sources/DysonCloudAPI.swift \
    App/Sources/MQTTClient.swift App/Sources/DysonModel.swift App/Sources/LoginFlow.swift \
    App/Sources/Theme.swift App/Sources/PanelControls.swift
build/harness Tests/fake_dyson.py
