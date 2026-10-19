#!/bin/bash
# Runs the actual pure Swift model and tests on macOS, without CoreSimulator or ChefKit.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('build/progression-model-tests')
(root / 'Sources/Walkies').mkdir(parents=True, exist_ok=True)
(root / 'Tests/WalkiesTests').mkdir(parents=True, exist_ok=True)
(root / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WalkiesModelTests", platforms: [.macOS(.v15)], targets: [
    .target(name: "Walkies"),
    .testTarget(name: "WalkiesTests", dependencies: ["Walkies"])
])
''')
for name in ['Progression', 'Geo', 'HexGrid', 'City', 'Walk', 'Boundary', 'Lore', 'WalkRecap']:
    shutil.copy(f'Walkies/Model/{name}.swift', root / 'Sources/Walkies')
# Lore's existing random generator lives alongside the cloud renderer. Copy that
# exact type rather than importing a UI renderer into the model-only test target.
clouds = Path('Walkies/Views/Clouds.swift').read_text()
(root / 'Sources/Walkies/SplitMix64.swift').write_text(clouds[clouds.index('nonisolated struct SplitMix64'):])
for name in ['ProgressionTests', 'WalkRecapTests']:
    shutil.copy(f'WalkiesTests/{name}.swift', root / 'Tests/WalkiesTests')
PY
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
swift test --disable-sandbox --package-path build/progression-model-tests \
    --scratch-path build/progression-model-tests/.build \
    -Xswiftc -default-isolation -Xswiftc MainActor -Xswiftc -strict-concurrency=complete
