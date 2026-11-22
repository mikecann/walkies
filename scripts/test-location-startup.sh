#!/bin/bash
# Native tracker/startup regression tests with fake OS drivers. Run on Tinker Desk
# through ~/.local/bin/heavy; the simulator and build data stay beside the checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('build/location-startup-tests/package')
for part in ['Sources/Walkies', 'Tests/WalkiesTests']:
    shutil.rmtree(root / part, ignore_errors=True)
    (root / part).mkdir(parents=True)
(root / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "WalkiesLocationTests", platforms: [.iOS(.v18)], products: [
    .library(name: "WalkiesLocationTests", targets: ["Walkies"])
], targets: [
    .target(name: "Walkies", swiftSettings: [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v5)]),
    .testTarget(name: "WalkiesTests", dependencies: ["Walkies"], swiftSettings: [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v5)])
])
''')
for name in ['Geo', 'HexGrid', 'Walk']:
    shutil.copy(f'Walkies/Model/{name}.swift', root / 'Sources/Walkies')
for name in ['AppStartup', 'FirstUnlock', 'LocationDriver', 'LocationTracker', 'MotionMonitor', 'StationaryFence', 'TrackerTrace']:
    shutil.copy(f'Walkies/Services/{name}.swift', root / 'Sources/Walkies')
for name in ['StationaryFenceTests', 'LocationLaunchTests', 'TrackingTestDriver', 'StartupTests']:
    shutil.copy(f'WalkiesTests/{name}.swift', root / 'Tests/WalkiesTests')
PY
root="$PWD/build/location-startup-tests"
if [ -s "$root/simulator-id" ]; then
    simulator=$(cat "$root/simulator-id")
else
    simulator=$(xcrun simctl create WalkiesLocationTests com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "${WALKIES_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-2}")
    printf '%s\n' "$simulator" > "$root/simulator-id"
fi
cleanup() { xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true; }
trap cleanup EXIT
simulator_data="$HOME/Library/Developer/CoreSimulator/Devices/$simulator/data"
if [ ! -L "$simulator_data" ]; then
    mv "$simulator_data" "$root/simulator-data"
    ln -s "$root/simulator-data" "$simulator_data"
fi
export TMPDIR="$root/tmp"
mkdir -p "$TMPDIR"
cd "$root/package"
xcodebuild -scheme WalkiesLocationTests -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$root/DerivedData" -resultBundlePath "$root/results-$(date +%Y%m%d-%H%M%S).xcresult" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    CODE_SIGNING_ALLOWED=NO test "$@"
