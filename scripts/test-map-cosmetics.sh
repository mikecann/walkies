#!/bin/bash
# Runs route stamp geometry tests without CoreSimulator or UI dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('build/map-cosmetics-tests')
(root / 'Sources/Walkies').mkdir(parents=True, exist_ok=True)
(root / 'Tests/WalkiesTests').mkdir(parents=True, exist_ok=True)
(root / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WalkiesMapCosmeticsTests", platforms: [.macOS(.v15)], targets: [
    .target(name: "Walkies"),
    .testTarget(name: "WalkiesTests", dependencies: ["Walkies"])
])
''')
shutil.copy('Walkies/Views/TrailLayout.swift', root / 'Sources/Walkies')
shutil.copy('WalkiesTests/TrailLayoutTests.swift', root / 'Tests/WalkiesTests')
PY
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
swift test --disable-sandbox --package-path build/map-cosmetics-tests \
    --scratch-path build/map-cosmetics-tests/.build \
    -Xswiftc -default-isolation -Xswiftc MainActor -Xswiftc -strict-concurrency=complete
