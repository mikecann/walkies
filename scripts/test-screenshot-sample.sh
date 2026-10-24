#!/bin/bash
# Builds the App Store screenshots' sample explorer (Walkies/Model/SampleExplorer.swift) on
# macOS from appstore/sample/{fremantle,busselton}.json and prints how much of each place it
# uncovers and which secrets it finds, without needing the simulator. Fails if Fremantle isn't
# part explored (20% to 70%) or the Busselton weekend finds no secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/walkies-sample-check
mkdir -p "$OUT"
ROOT="$PWD"
cat > "$OUT/main.swift" <<SWIFT
import Foundation

func sample(_ name: String) throws -> CachedPlaceData {
    try JSONDecoder().decode(CachedPlaceData.self, from: Data(contentsOf: URL(fileURLWithPath: "$ROOT/appstore/sample/\(name).json")))
}
// The app reads the lore from its bundle, which a command-line build doesn't have.
let lore = try ["geographe", "busselton-area"].flatMap { name in
    try JSONDecoder().decode([LoreEntry].self, from: Data(contentsOf: URL(fileURLWithPath: "$ROOT/Walkies/Lore/\(name).json")))
}
let fremantle = try sample("fremantle"), busselton = try sample("busselton")
let trips = [
    SampleExplorer.Trip(
        place: PlaceResult(id: 0, name: "Fremantle", detail: "Western Australia, Australia", kind: "suburb",
                           boundary: fremantle.boundary, area: 0, osmId: 11689400),
        ways: fremantle.ways, home: SampleExplorer.fremantleHome, walks: SampleExplorer.fremantleWalks),
    SampleExplorer.Trip(
        place: PlaceResult(id: 1, name: "Busselton", detail: "Western Australia, Australia", kind: "suburb",
                           boundary: busselton.boundary, area: 0, osmId: 11688699),
        ways: busselton.ways, home: SampleExplorer.busseltonStay, walks: SampleExplorer.busseltonWalks,
        targets: SampleExplorer.busseltonTargets),
]
let result = SampleExplorer.make(trips, lore: lore)
for city in result.cities {
    print("\(city.name): tiles \(city.tiles.count), uncovered \(city.visited.count) (\(Int(city.progress * 100))%), \(city.stickers?.count ?? 0) secrets hidden")
}
let km = result.walks.map(\.distance).reduce(0, +) / 1000
print("\(result.walks.count) walks, \(Int(km)) km")
for walk in result.walks { print("  \(walk.startedAt.formatted()) \(Int(walk.distance)) m, \(walk.newTiles) new tiles, \(walk.steps ?? 0) steps") }
let titles = Dictionary(lore.map { (\$0.id, "\(\$0.title) (\(\$0.suburb ?? "Around Busselton"))") }) { a, _ in a }
print("\(result.secrets.count) secrets found:")
for (id, date) in result.secrets.sorted(by: { \$0.value < \$1.value }) { print("  \(date.formatted(date: .abbreviated, time: .shortened)) \(titles[id] ?? id)") }
guard let home = result.cities.first, home.progress > 0.2, home.progress < 0.7 else { print("Fremantle isn't part explored"); exit(1) }
guard !result.secrets.isEmpty else { print("The Busselton weekend found no secrets"); exit(1) }
SWIFT
# SplitMix64 lives in Clouds.swift, which needs UIKit, so the check gets its own copy.
sed -n '/^nonisolated struct SplitMix64/,/^}/p' Walkies/Views/Clouds.swift > "$OUT/SplitMix64.swift"
export CLANG_MODULE_CACHE_PATH="$OUT/module-cache"
xcrun swiftc -D DEBUG -O -default-isolation MainActor -o "$OUT/check" \
  Walkies/Model/{Geo,HexGrid,City,Walk,Boundary,Mist,Lore,SampleExplorer}.swift \
  Walkies/Services/{OSMClient,Convex,CachedPlaceData,CityBuilder}.swift \
  "$OUT/SplitMix64.swift" "$OUT/main.swift" 2>&1 | grep -E "error" || true
"$OUT/check"
