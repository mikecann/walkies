#!/bin/bash
# Exercise the real place builder on macOS when CoreSimulator isn't available.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('build/places-model-tests')
(root / 'Sources/Walkies').mkdir(parents=True, exist_ok=True)
(root / 'Tests/WalkiesTests').mkdir(parents=True, exist_ok=True)
(root / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WalkiesPlacesTests", platforms: [.macOS(.v15)], targets: [
    .target(name: "Walkies"),
    .testTarget(name: "WalkiesTests", dependencies: ["Walkies"])
])
''')
for name in ['Geo', 'HexGrid', 'City', 'Walk', 'Boundary']:
    shutil.copy(f'Walkies/Model/{name}.swift', root / 'Sources/Walkies')
for name in ['OSMClient', 'Convex', 'CachedPlaceData', 'CityBuilder']:
    shutil.copy(f'Walkies/Services/{name}.swift', root / 'Sources/Walkies')
shutil.copy('WalkiesTests/CachedPlaceTests.swift', root / 'Tests/WalkiesTests')
PY
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
swift test --disable-sandbox --package-path build/places-model-tests \
    --scratch-path build/places-model-tests/.build \
    -Xswiftc -default-isolation -Xswiftc MainActor -Xswiftc -strict-concurrency=complete
