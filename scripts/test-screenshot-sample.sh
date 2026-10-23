#!/bin/bash
# Builds the App Store screenshots' sample explorer (Walkies/Model/SampleExplorer.swift) on
# macOS from appstore/sample/fremantle.json and prints how much of the suburb it uncovers,
# without needing the simulator. Fails if it's not part explored (20% to 70%).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/walkies-sample-check
mkdir -p "$OUT"
SAMPLE="$PWD/appstore/sample/fremantle.json"
cat > "$OUT/main.swift" <<SWIFT
import Foundation

let data = try JSONDecoder().decode(CachedPlaceData.self, from: Data(contentsOf: URL(fileURLWithPath: "$SAMPLE")))
let place = PlaceResult(id: 0, name: "Fremantle", detail: "Western Australia, Australia", kind: "suburb",
                        boundary: data.boundary, area: 0, osmId: 11689400)
let sample = SampleExplorer.make(place: place, ways: data.ways, home: SampleExplorer.fremantleHome)
let city = sample.cities[0]
let km = sample.walks.map(\.distance).reduce(0, +) / 1000
print("tiles \(city.tiles.count), uncovered \(city.visited.count) (\(Int(city.progress * 100))%), \(sample.walks.count) walks, \(Int(km)) km")
for walk in sample.walks { print("  \(walk.startedAt.formatted()) \(Int(walk.distance)) m, \(walk.newTiles) new tiles, \(walk.steps ?? 0) steps") }
guard city.progress > 0.2, city.progress < 0.7 else { print("Not part explored"); exit(1) }
SWIFT
export CLANG_MODULE_CACHE_PATH="$OUT/module-cache"
xcrun swiftc -D DEBUG -O -default-isolation MainActor -o "$OUT/check" \
  Walkies/Model/{Geo,HexGrid,City,Walk,Boundary,Mist,SampleExplorer}.swift \
  Walkies/Services/{OSMClient,Convex,CachedPlaceData,CityBuilder}.swift \
  "$OUT/main.swift" 2>&1 | grep -E "error" || true
"$OUT/check"
