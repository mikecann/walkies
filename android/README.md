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

- `AppModel.kt`: places, walks and turning GPS fixes into uncovered tiles (the walk side of `AppModel.swift`). Plain Kotlin, tested on the JVM.
- `model/`: `Walk`, `TrackPoint`, `CoverageTracer`, `Ledger`, `SyncState`, and `Codec`, which reads and writes exactly the iPhone's JSON (`Walk.swift`, `Progression.swift`, `Sync.swift`).
- `store/`: the save files, laid out like `Store.swift` (`cities.json` with streets in `roads.json`, `walks/<id>.json`, ...), under the app's files folder in `Walkies/`.
- `location/`: GPS from the fused location provider (`LocationTracker.swift`). Runs while the app's open; stage 3 adds the always-on service.
- `grid/`: the world hex grid, matching `HexGrid.swift` and `convex/grid.ts` (`design/grid.md`).
- `place/`: boundaries, places and the street-cache blob (`City.swift`, `Boundary.swift`, `CityBuilder.swift`).
- `map/`: Mapbox, the cloud field, the homography and the cloud painter (`Clouds.swift`, `FogMapView.swift`).
- `ui/`: colours, the sticker cards, hex badges and the place chip (`Theme.swift`, `ContentView.swift`).

Lore, icons and stickers are copied from the iOS sources into the app's assets at build time (`copyIosAssets` in `app/build.gradle.kts`), as is the Geographe fixture from `shared/fixtures/places`.

## Walking on the emulator

On first run, with no places saved, Geographe is added from the bundled fixture (place search comes in stage 4). Walks record while the app's open; always-on is the default until stage 3's setup asks, so walks start by themselves, show "walk pending" until you're 150 m from the start, then uncover everything since the start.

```
android/scripts/sim-walk.sh scripts/routes/navigation-way.txt      # 1.4 m/s, a fix a second
android/scripts/sim-walk.sh scripts/routes/navigation-way.txt 3    # jogging
```

Testing switches, like the iPhone's launch arguments:

```
adb shell am start -n com.mikecann.walkies/.MainActivity --ez alwaysOn false   # Start walk button instead
adb shell am start -n com.mikecann.walkies/.MainActivity --es autoWalkGap 60    # end always-on walks after a minute still
```
