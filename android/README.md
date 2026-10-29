# Walkies for Android

Kotlin and Jetpack Compose, following the iPhone app in `../Walkies`. See `../design/android.md` for the plan.

Steps are counted by the phone's motion chip through Play services, with no extra battery use. Each walk keeps its steps, and Walks shows Steps today once a full day is available. Play services only keeps steps from when counting was switched on, so partial walks and the first partial day stay hidden. Count steps in Settings turns it off.

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

## Release builds

`./gradlew assembleRelease` makes a shrunk (R8) build that talks to the prod deployment (savory-bee-296), with no test sign-in. To sign it, put the key's details in `android/keystore.properties`, which git ignores:

```
storeFile=/Users/you/keys/walkies.jks
storePassword=…
keyAlias=walkies
keyPassword=…
```

Without that file the build still works and comes out unsigned (`app/build/outputs/apk/release/app-release-unsigned.apk`). Keep the keystore safe: updates to Dad's phone have to be signed with the same key. The keep rules for R8 are in `app/proguard-rules.pro`.

A signed `assembleRelease` also uploads R8's mapping to Sentry, so crash reports show real names. It needs `sentry-cli` (on PATH or in `~/.local/bin`) and a token in `SENTRY_AUTH_TOKEN` or `~/.config/sentry/token`; without them it says so and carries on.

The first build downloads Nunito (the rounded heading font) into `app/src/main/assets/fonts/`. Commit it so builds don't need to fetch it again.

## Where things are

- `AppModel.kt`: places, walks and turning GPS fixes into uncovered tiles (the walk side of `AppModel.swift`), adding and deleting places, places that add themselves where you are and where you've walked (deciding in `place/AutoPlaces.kt`), the suburbs next door, and taking in what sync pulls down. Plain Kotlin, tested on the JVM.
- `convex/`: `ConvexClient`, calling Convex functions over HTTP (`Convex.swift`). Debug builds use the dev deployment (resolute-pig-177), release builds prod (savory-bee-296), from `BuildConfig`.
- `auth/`: `Account` (`Account.swift`): Google sign-in through Convex Auth in a Custom Tab, coming back on `walkies://signed-in`, the session sealed by the Android Keystore, and refreshing it only in its last five seconds. Test sign-in lives in `src/debug` and isn't in release builds.
- `sync/`: `SyncEngine`, a port of `Sync.swift`: push, explicit place deletions, incremental pull, the owner check.
- `place/OSMClient.kt`: Nominatim search and the suburbs nearby. Adding a place gets its streets from the server's cache (`places:get`), falling back to Overpass like the iPhone.
- `model/`: `Walk`, `TrackPoint`, `CoverageTracer`, `Ledger`, `SyncState`, and `Codec`, which reads and writes exactly the iPhone's JSON (`Walk.swift`, `Progression.swift`, `Sync.swift`).
- `model/Progression.kt`: shells, XP, levels, weekly quests (in Perth weeks), level-up picks, the shop's catalogue and the spyglass, ported from `Progression.swift` and `LevelMeter.swift` with the same seeds, so both phones agree for the same data. `ProgressionTest` pins it to values printed by the iPhone's own code. `AppModel` works out the saved walks' first-discovery tile counts once at launch (off the main thread), keeps the shells and quests cached, and buys, equips and claims through the ledger.
- `store/`: the save files, laid out like `Store.swift` (`cities.json` with streets in `roads.json`, `walks/<id>.json`, ...), under the app's files folder in `Walkies/`.
- `location/`: always-on tracking (`LocationTracker.swift`, `StationaryFence.swift`, `MotionMonitor.swift`). `AlwaysOnTracking` decides where the stationary fence goes and how hard the GPS works, as plain tested Kotlin; `LocationTracker` (fused location), `Wakeups.kt` (Geofencing, Activity Recognition, boot/update receivers) and `TrackingService` (the foreground service and its notification) are the thin Android parts. `WalkiesApplication.refreshTracking()` keeps them in line with the one `AppModel`.
- `ui/SetupScreen.kt`: the first-run setup (`SetupView.swift`): location, all the time, physical activity, notifications, battery, and Samsung's sleeping apps. Settings' "Fix permissions" reruns just what's missing.
- `grid/`: the world hex grid, matching `HexGrid.swift` and `convex/grid.ts` (`design/grid.md`).
- `place/`: boundaries, places and the street-cache blob (`City.swift`, `Boundary.swift`, `CityBuilder.swift`).
- `map/`: Mapbox, the cloud field, the homography and the cloud painter (`Clouds.swift`, `FogMapView.swift`). The clouds are baked off the main thread (`CloudBaker`) and warped onto the map each frame (`BakeFrame`, `BakeWarp`, `CloudLayer`): see `design/android.md`. `adb logcat -s CloudBaker CloudLayer` shows how long each bake takes and, on debug builds, the layer's average and worst draw time every 60 frames, with how many of those drew everything live, crossfaded, drew the honeycomb or had tiles clearing.
- `lore/`: the secrets (`Lore.swift`, `SecretsBook.swift`, `ServerLore.swift`). `LoreLibrary` reads the lore JSON (from assets on the phone, straight from `../Walkies/Lore` in tests), `assign` and `City.placeStickers` hide each secret under the same tile the iPhone would, and `SecretsBook` sorts and filters the book. `ServerLore` is what `lore:forPlace` said about your places without bundled secrets, which `AppModel.updateLore` asks for and keeps in `server-lore.json` with the art in `server-stickers/` (shared/lore-api.md). `SecretNotifier` pings you when you walk over one with the app closed (`Notifier.swift`), on a "Secrets found" channel of its own.
- `model/WalkRecap.kt`: what the end-of-walk celebration plays (`WalkRecap.swift`). `AppModel` makes one when a walk ends, and `replay(walk)` makes a rewatch from history that changes nothing.
- `ui/`: colours, the sticker cards, hex badges and the place chip (`Theme.swift`, `ContentView.swift`), sign-in (`SignInView.swift`), Places and Add a place (`MapsAndPlacesView.swift`, `AddCityView.swift`), Settings (`SettingsPage.kt`). The app is five tabs along the bottom, as on the iPhone: Map, Secrets, Progress, Walks and Settings (`AppNavigation.kt` says which is showing, `TabBar.kt` draws the bar, and `MainActivity` keeps the map underneath the other pages so it doesn't load again). Also the secrets: `Stickers.kt` (sticker art, the story card with its photos, and the slide-up `Sheet`), `SecretsBookScreen.kt`, and the pins on the map (`map/StickerPins.kt`); the celebration and replay (`CelebrationScreen.kt`, with `SoundFX.kt` making its sounds in code like `SoundFX.swift`); and the Walks tab (`WalkHistoryScreen.kt`). Progression is `ProgressScreen.kt` (`ProgressView.swift`): the shells chip under the place chip, and the Progress tab with your level, rewards to choose, quests, the shop, the wardrobe and the spyglass, one at a time from the row of pills along its top. What's equipped changes the map's marker, trail and clouds (`CloudPainter`, `CloudSprites`, `TrailLayout`), the secrets book's cover and the celebration's confetti, bubbles or fireworks.

Not on Android: Chef ("Suggest a feature") and Mike's review of the server's secrets, which are iPhone-only, and teams.

Lore, icons, stickers, the secrets' photos and the shop's art are copied from the iOS sources into the app's assets at build time (`copyIosAssets` in `app/build.gradle.kts`). The iPhone ships no sound files: the celebration's pops, chime and fanfare are synthesised on both.

## Signing in on the emulator

Google sign-in works on the emulator if it has a browser. For testing sync without Google, debug builds take the iPhone's test sign-in, which makes a fresh account on the dev deployment (only dev allows it, with `WALKIES_TEST_SIGNIN=1`):

```
adb shell am start -n com.mikecann.walkies/.MainActivity --ez testSignIn true --es testUserName "Emu"
```

There's also a "Test sign-in" link under the Google button on debug builds. Signing out (Settings) clears the phone, as on the iPhone; signing in as someone else wipes the last account's data first.

With no places yet, the suburb you're in adds itself once the emulator has a location (Extended controls > Location) and the first sync has finished, with the place chip saying "Finding your suburb…" meanwhile. To add one by hand: tap the place chip, Change place, Add a place, and search (say "Geographe"). Zoomed out, the suburbs next door show with a "+" to add them.

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
