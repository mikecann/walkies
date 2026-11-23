# Walk lifecycle regression checks

The scripts use real tracking policies, walk models, storage and sync clients with
synthetic locations and fake HTTP servers. They never need a Convex deployment,
account session or phone. Run complete suites on Tinker Desk through `heavy`, with
the checkout and its `build/` directory on `/Volumes/TinkerSSD`.

```bash
# macOS Swift model, persistence and HTTP sync checks
bash scripts/test-progression-model.sh
# A narrow selection; a filter matching no tests exits with an error
bash scripts/test-progression-model.sh --filter RideRelaunchTests

# Native iOS tracker, motion, first-unlock and launch checks with fake OS drivers
# Creates its own simulator with data in build/, and shuts it down on exit
bash scripts/test-location-startup.sh

# Kotlin model, persistence, tracking policy and HTTP sync checks, without an SDK
# Requires JDK 21 and Gradle wrapper downloads/cache
bash scripts/test-android-model.sh
bash scripts/test-android-model.sh --tests com.mikecann.walkies.FinishRelaunchTest
```

For example, on Tinker Desk:

```bash
ssh tinker-desk 'cd /Volumes/TinkerSSD/scratch/walkies-check && ~/.local/bin/heavy bash scripts/test-progression-model.sh'
```

Local selections must stay narrow and use `taskpolicy -b`. The Swift model script
prints included suites and names its native-only exclusions. The Kotlin script
prints discovered, passed, failed and skipped counts. Fixture export tests remain
conditional on their export environment variables.

`shared/fixtures/walk-lifecycle.json` is replayed by both clients. It covers rides,
walking dropouts, rest, process recreation and exact gap boundaries with the same
coordinates, expected identities, times and distances. A relaunch does not save
implicitly. Held sensor responses and filesystem failures have additional native
language tests, including snapshots copied into a separate root to represent a
process that no longer exists.

A saved walk's optional continuation state distinguishes walking from an observed
ride. Its pending finish records the requested time, reason and explicit End
intent while `endedAt` stays nil, so sync waits for final history and steps. A ride
finish owns a successor seed with a stable UUID until that next walk's file is
written successfully. The next file is committed before the predecessor clears
its seed. Older JSON without these fields still loads.

The native tracker suite replaces Core Location managers and sessions, then calls
the real start/stop code and asserts the configuration it asks for. It tests the
first-unlock filesystem probe on a simulator. This covers launch ordering and
configuration; actual locked-device delivery, suspension and battery behavior
still need an explicitly authorized device check.
