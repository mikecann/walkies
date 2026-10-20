# Walkies for Android

Kotlin and Jetpack Compose, following the iPhone app in `../Walkies`. See `../design/android.md` for the plan.

## Setup

1. JDK 17: `export JAVA_HOME=~/Library/Java/JavaVirtualMachines/jdk-17.0.20.1+1/Contents/Home`
2. A Mapbox public token (`pk.…`) in `android/local.properties`, which git ignores:
   ```
   sdk.dir=/Users/you/Library/Android/sdk
   MAPBOX_ACCESS_TOKEN=pk.…
   ```
   Without it the app still runs, with a blank stand-in map under the clouds.
3. `./gradlew assembleDebug testDebugUnitTest`
4. `./gradlew testDebugUnitTest -PwriteFixtures` also writes `shared/fixtures/android` for the iPhone's tests (see `shared/fixtures/README.md`).

The first build downloads Nunito (the rounded heading font) into `app/src/main/assets/fonts/`. Commit it so builds don't need to fetch it again.

## Where things are

- `AppModel.kt`: places, walks and turning GPS fixes into uncovered tiles (the walk side of `AppModel.swift`), adding and deleting places, the suburbs next door, and taking in what sync pulls down. Plain Kotlin, tested on the JVM.
- `convex/`: `ConvexClient`, calling Convex functions over HTTP (`Convex.swift`). Debug builds use the dev deployment (resolute-pig-177), release builds prod (savory-bee-296), from `BuildConfig`.
- `auth/`: `Account` (`Account.swift`): Google sign-in through Convex Auth in a Custom Tab, coming back on `walkies://signed-in`, the session sealed by the Android Keystore, and refreshing it only in its last five seconds. Test sign-in lives in `src/debug` and isn't in release builds.
- `sync/`: `SyncEngine`, a port of `Sync.swift`: push, explicit place deletions, incremental pull, the owner check.
- `place/OSMClient.kt`: Nominatim search and the suburbs nearby. Adding a place gets its streets from the server's cache (`places:get`), falling back to Overpass like the iPhone.
- `model/`: `Walk`, `TrackPoint`, `CoverageTracer`, `Ledger`, `SyncState`, and `Codec`, which reads and writes exactly the iPhone's JSON (`Walk.swift`, `Progression.swift`, `Sync.swift`).
- `store/`: the save files, laid out like `Store.swift` (`cities.json` with streets in `roads.json`, `walks/<id>.json`, ...), under the app's files folder in `Walkies/`.
- `location/`: always-on tracking (`LocationTracker.swift`, `StationaryFence.swift`, `MotionMonitor.swift`). `AlwaysOnTracking` decides where the stationary fence goes and how hard the GPS works, as plain tested Kotlin; `LocationTracker` (fused location), `Wakeups.kt` (Geofencing, Activity Recognition, boot/update receivers) and `TrackingService` (the foreground service and its notification) are the thin Android parts. `WalkiesApplication.refreshTracking()` keeps them in line with the one `AppModel`.
- `ui/SetupScreen.kt`: the first-run setup (`SetupView.swift`): location, all the time, physical activity, notifications, battery, and Samsung's sleeping apps. Settings' "Fix permissions" reruns just what's missing.
- `grid/`: the world hex grid, matching `HexGrid.swift` and `convex/grid.ts` (`design/grid.md`).
- `place/`: boundaries, places and the street-cache blob (`City.swift`, `Boundary.swift`, `CityBuilder.swift`).
- `map/`: Mapbox, the cloud field, the homography and the cloud painter (`Clouds.swift`, `FogMapView.swift`).
- `lore/`: the secrets (`Lore.swift`, `SecretsBook.swift`). `LoreLibrary` reads the lore JSON (from assets on the phone, straight from `../Walkies/Lore` in tests), `assign` and `City.placeStickers` hide each secret under the same tile the iPhone would, and `SecretsBook` sorts and filters the book. `SecretNotifier` pings you when you walk over one with the app closed (`Notifier.swift`), on a "Secrets found" channel of its own.
- `model/WalkRecap.kt`: what the end-of-walk celebration plays (`WalkRecap.swift`). `AppModel` makes one when a walk ends, and `replay(walk)` makes a rewatch from history that changes nothing.
- `ui/`: colours, the sticker cards, hex badges and the place chip (`Theme.swift`, `ContentView.swift`), sign-in (`SignInView.swift`), Places and Add a place (`MapsAndPlacesView.swift`, `AddCityView.swift`), Settings. Also the secrets: `Stickers.kt` (sticker art, the story card with its photos, and the slide-up `Sheet`), `SecretsBookScreen.kt`, and the pins on the map (`map/StickerPins.kt`); the celebration and replay (`CelebrationScreen.kt`, with `SoundFX.kt` making its sounds in code like `SoundFX.swift`); and Settings > Past walks (`WalkHistoryScreen.kt`).

Lore, icons, stickers and the secrets' photos are copied from the iOS sources into the app's assets at build time (`copyIosAssets` in `app/build.gradle.kts`). The iPhone ships no sound files: the celebration's pops, chime and fanfare are synthesised on both.

## Signing in on the emulator

Google sign-in works on the emulator if it has a browser. For testing sync without Google, debug builds take the iPhone's test sign-in, which makes a fresh account on the dev deployment (only dev allows it, with `WALKIES_TEST_SIGNIN=1`):

```
adb shell am start -n com.mikecann.walkies/.MainActivity --ez testSignIn true --es testUserName "Emu"
```

There's also a "Test sign-in" link under the Google button on debug builds. Signing out (Settings) clears the phone, as on the iPhone; signing in as someone else wipes the last account's data first.

With no places yet the map is empty: tap the place chip, Change place, Add a place, and search (say "Geographe"). Zoomed out, the suburbs next door show with a "+" to add them.

## Walking on the emulator

The setup switches always-on on, so walks start by themselves, show "walk pending" until you're 150 m from the start, then uncover everything since the start. With the app closed the foreground service keeps recording, and its notification shows the walk. Finished walks sync to the account a couple of seconds later (`npx convex data walks --limit 3` on dev).

To skip the setup with everything granted:

```
pkg=com.mikecann.walkies
for p in ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION ACTIVITY_RECOGNITION POST_NOTIFICATIONS; do adb shell pm grant $pkg android.permission.$p; done
adb shell dumpsys deviceidle whitelist +$pkg
adb shell am start -n $pkg/.MainActivity --ez setupDone true --ez alwaysOn true
```

`adb shell am kill` won't touch the app while the service is running. To test the walk surviving process death, `adb root && adb shell kill -9 $(adb shell pidof $pkg)`: the service comes back by itself (`START_STICKY`) and the store resumes the walk. The emulator has no Activity Recognition, so there the GPS just goes down to low power once you've settled, rather than off.

```
android/scripts/sim-walk.sh scripts/routes/navigation-way.txt      # 1.4 m/s, a fix a second
android/scripts/sim-walk.sh scripts/routes/navigation-way.txt 3    # jogging
```

Testing switches, like the iPhone's launch arguments:

```
adb shell am start -n com.mikecann.walkies/.MainActivity --ez setupDone true   # skip the first-run setup
adb shell am start -n com.mikecann.walkies/.MainActivity --ez alwaysOn false   # Start walk button instead
adb shell am start -n com.mikecann.walkies/.MainActivity --es autoWalkGap 60    # end always-on walks after a minute still
```
