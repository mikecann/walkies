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

The first build downloads Nunito (the rounded heading font) into `app/src/main/assets/fonts/`. Commit it so builds don't need to fetch it again.

## Where things are

- `grid/`: the world hex grid, matching `HexGrid.swift` and `convex/grid.ts` (`design/grid.md`).
- `place/`: boundaries, places and the street-cache blob (`City.swift`, `Boundary.swift`, `CityBuilder.swift`).
- `map/`: Mapbox, the cloud field, the homography and the cloud painter (`Clouds.swift`, `FogMapView.swift`).
- `ui/`: colours, the sticker cards, hex badges and the place chip (`Theme.swift`, `ContentView.swift`).

Lore, icons and stickers are copied from the iOS sources into the app's assets at build time (`copyIosAssets` in `app/build.gradle.kts`), as is the Geographe fixture from `shared/fixtures/places`.

Map spike debug: "Tap tiles to clear" in the bottom left turns on clearing (or re-clouding) a tile by tapping it.
