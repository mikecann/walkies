# Shared fixtures

Test data used by both the iPhone and Android apps.

- `places/geographe.json`: the server street cache blob (`PlaceData`: boundary and walkable ways) for Geographe, OSM relation 11688696, as served by `places:get`. Map data © OpenStreetMap contributors, ODbL. Refresh with `npx convex run places:cachedUrl '{"osmId": 11688696}'` and download the URL.
- `lore/forPlace-porlock.json`: what `lore:forPlace` answered for Porlock, Somerset (OSM relation 2676434) after the first server research run on dev, 24 Oct 2026, for the apps' decoder tests (shared/lore-api.md). That run had no credit left for stickers, so every `stickerUrl` was null; the first entry's is a made-up storage URL so both cases are covered.
- `places/suburb-rule.json`: which boundary a place that adds itself uses (`AutoPlaces.suburbCandidates`), as cases of what Overpass's `is_in` says a spot is in, plus the id each phone gives a place from its OSM relation. `AutoPlacesTests.swift` and `AutoPlacesTest.kt` both check against it.
- `ios/` and `android/`: golden save files, the same synthetic values (`FixtureValues` in `WalkiesTests/FixtureExportTests.swift`, `Fixtures` in `android/app/src/test/.../model/FixtureTest.kt`) written by each app's real `Store`, in its layout: `cities.json`, `roads.json`, `walks/<id>.json`, `stickers.json`, `progress.json`, `sync.json`, `owner.json`, `data-version.json`.
  - Write `ios/` with `TEST_RUNNER_WALKIES_FIXTURES_OUT=$PWD/shared/fixtures/ios xcodebuild test -only-testing:WalkiesTests/FixtureExportTests ...`. The Android tests read every file in it, write it back and check the JSON means the same.
  - Write `android/` with `cd android && ./gradlew testDebugUnitTest -PwriteFixtures`. `FixtureExportTests` reads every file in it with the iPhone's decoders and `Store`.
  - Sets (tiles, hexes) come out in any order on the iPhone, so regenerating `ios/` shuffles them. That's fine: the tests compare meaning, not bytes.

The fixture tests also round-trip the saved walks with optional `steps` added. The golden files without steps stay valid for older app versions.
