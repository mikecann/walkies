#!/bin/bash
# Runs model and app/sync regression tests on macOS, without CoreSimulator or ChefKit.
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
    .target(name: "Walkies", resources: [.process("Lore")]),
    .testTarget(name: "WalkiesTests", dependencies: ["Walkies"])
])
''')
for name in ['Progression', 'Geo', 'HexGrid', 'City', 'Walk', 'Boundary', 'Lore', 'WalkRecap', 'LevelMeter']:
    shutil.copy(f'Walkies/Model/{name}.swift', root / 'Sources/Walkies')
shutil.copytree('Walkies/Lore', root / 'Sources/Walkies/Lore', dirs_exist_ok=True)
# SwiftPM keeps resources in its own bundle rather than the iOS app bundle.
lore = root / 'Sources/Walkies/Lore.swift'
lore.write_text(lore.read_text().replace('Bundle.main', 'Bundle.module'))
# Lore's existing random generator lives alongside the cloud renderer. Copy that
# exact type rather than importing a UI renderer into the model-only test target.
clouds = Path('Walkies/Views/Clouds.swift').read_text()
(root / 'Sources/Walkies/SplitMix64.swift').write_text(clouds[clouds.index('nonisolated struct SplitMix64'):])
# Exercise the actual app integration and sync on macOS too. Sensors and the
# notification/account UI are stubbed; networking uses a URLProtocol test server.
for name in ['Store', 'Sync', 'Convex', 'OSMClient', 'CityBuilder']:
    shutil.copy(f'Walkies/Services/{name}.swift', root / 'Sources/Walkies')
shutil.copy('Walkies/AppModel.swift', root / 'Sources/Walkies')
shutil.copy('scripts/progression-test-support/Platform.swift', root / 'Sources/Walkies')
for name in ['ProgressionTests', 'WalkRecapTests', 'LevelMeterTests', 'ProgressionIntegrationTests']:
    shutil.copy(f'WalkiesTests/{name}.swift', root / 'Tests/WalkiesTests')
PY
export WALKIES_TEST_ROOT="$PWD/build/progression-test-data"
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
swift test --disable-sandbox --package-path build/progression-model-tests \
    --scratch-path build/progression-model-tests/.build \
    -Xswiftc -default-isolation -Xswiftc MainActor -Xswiftc -strict-concurrency=complete
