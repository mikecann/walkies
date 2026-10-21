# Android

Mike's dad has an Android phone, so Walkies needs an Android version that looks and behaves as close to the iPhone app as possible. Decided on 2026-10-20 after a panel review (Codex, Grok, Muse, chaired by Claude).

## Decisions

- **Native Kotlin + Jetpack Compose**, in `android/` in this repo. Not Kotlin Multiplatform, Flutter or React Native: the iPhone app is finished native Swift and stays that way, and the hard parts (background location, a per-frame canvas over a tilted map) are best done natively.
- **Mapbox Maps SDK** for the map: satellite imagery, pitch up to 55° like iOS, and camera/projection available every frame for the cloud overlay. Google Maps caps tilt lower at suburb zoom, and MapLibre would still need a licensed satellite source. Mapbox needs a free account and a public access token (`pk.…`), read from `android/local.properties` (`MAPBOX_ACCESS_TOKEN=…`), which is never committed. The SDK downloads without a secret token.
- **Clouds**: the same look as iOS, drawn over the map and projected with a homography measured from 4 screen points each frame, with no per-frame allocations. Drawing every puff each frame like iOS took 100-150 ms a frame on a Galaxy Tab A (2026-10-21), so instead the clouds, roads, grid and honeycomb are baked on a background thread into a picture of what the camera sees (plus a margin), and each frame draws that with one perspective matrix worked out from the same homography. It's baked again when the camera's moved, zoomed, tilted or turned past a little, and every few seconds for the drift. While a finger's on the map it's left alone until the screen's half way into the margin (or zoomed or turned well past), then baked roughly, at low priority, with the drift held so it swaps in without a crossfade; the sharp bake (0.8x the screen's pixels) waits until the map's still. Each bake is copied once to an immutable hardware bitmap, so the GPU uploads it once rather than every frame, and old ones are recycled as soon as nothing draws them. Tiles clearing are drawn live over the bake, round just those tiles, while they open. A Mapbox image source would also stay in sync with the map, but each update is a full texture upload through the style, and its corners are geographic so the clouds would tilt as decals rather than staying upright sprites.
- **One world grid**: port `HexGrid`/`WorldProjection` exactly per `design/grid.md`, tested against the same worked examples as the Swift tests and `convex/grid.ts`.
- **Same JSON blobs as iOS**, byte-compatible, so one account could work on both and sync can't corrupt anything:
  - Swift `Codable` dates are seconds since 2001-01-01 (`Date` default). Track points and the ledger use their own fields; Convex arguments are milliseconds. Watch all three.
  - Hexes are `[q, r]` arrays.
  - Swift doesn't default missing keys, so always write every field (kotlinx.serialization `encodeDefaults = true`, explicit `0` and `[]`).
  - Golden fixtures written by the Swift code (`shared/fixtures/`) are decoded and re-encoded by Kotlin tests, and Kotlin-written files decode in Swift tests.
- **Always-on walks**: a foreground service (type `location`) with FusedLocationProvider while moving; Activity Recognition transitions and a ~100 m Geofencing API fence (like iOS's stationary fence) to wake it; GPS off when still. The walk rules stay app logic, ported from Swift: pending until 150 m, speed and activity filtering, auto-end. Restart after reboot and app update (`BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`). Setup asks for location (then "Allow all the time"), physical activity, notifications, and a battery-optimisation exemption, with clear steps for Samsung's "sleeping apps".
- **Sign-in**: Google through the existing Convex Auth web flow in a Custom Tab, returning to `walkies://signed-in` via an intent filter. No Android OAuth client is needed. While the Google OAuth app is in testing mode, Dad's Gmail must be added as a test user.
- **Backend**: unchanged. Android calls the same Convex functions over HTTP with the same `gridVersion: 2` arguments.
- **Lore, stickers and photos**: shared from the iOS sources. A Gradle task copies `Walkies/Lore/*.json` and the sticker/photo imagesets into Android assets at build time, so there's one source of truth.
- **Chef (feedback board)**: iOS-only for now (ChefKit is Swift).
- **Distribution**: a signed release APK, sideloaded onto Dad's phone. Play Console internal testing later if updates get fiddly.

## Stages

Each stage leaves an app that builds (`./gradlew assembleDebug`), passes its tests, and runs on the emulator.

1. **Map spike.** Project scaffold, world grid port with shared worked examples, Mapbox tilted satellite map, cloud overlay over a fixture place (with roads and the honeycomb), camera controls like iOS. Proves the hardest visual part first.
2. **Offline walks and fixtures.** Local store with byte-compatible JSON and golden fixtures in both directions. Foreground location while the app is open, walk recording and tile uncovering ported from Swift (coverage tracing, the 150 m pending rule, filtering, flood fill), the you-are-here marker and trail.
3. **Always-on tracking.** Foreground service, Activity Recognition, stationary geofence, boot/update restart, the first-run setup flow for permissions and battery.
4. **Sign-in and sync.** Custom Tabs Google sign-in, Convex HTTP client and session refresh, push/pull matching iOS (explicit deletions, incremental pull, owner check). Adding places through search and the server street cache, neighbouring suburbs.
5. **Everything else.** Secrets book, stickers and photos, the end-of-walk celebration and replay, history, progression (shells, levels, quests, shop, wardrobe), settings. Then a polish pass side by side with the iPhone app.
