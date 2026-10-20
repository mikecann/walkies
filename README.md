# Walkies

An iPhone app that turns your walks into exploring. Add your suburb and it disappears under clouds on a satellite map. Go for a walk and the clouds clear off the hex tiles you walk through. The goal is to get your suburb to 100%.

Based on an idea from James.

## How it works

- **Adding a place** suggests suburbs and towns as you type, from Apple's `MKLocalSearchCompleter` (Nominatim's rules don't allow search-as-you-type). Picking one looks up its boundary on OpenStreetMap (Nominatim) and adds it straight away if there's one clear match; pressing Search asks Nominatim directly. Signed-in adds download the suburb’s streets and paths from a shared Convex cache, warmed in the background for neighbouring suburbs. A first fetch still asks Overpass and can take a minute or more; if the cache fails, the phone asks Overpass directly.
- **Tiles** are hexes 50 m from centre to corner, so about 87 m across. Only tiles with a street or path through them count towards the total, so canals, the estuary and the middle of the bay don't stop you finishing. If you walk through a tile that wasn't counted (a beach, or a park with no mapped paths) it gets added and counts.
- **The map** is Apple's satellite view with labels. The whole suburb starts under cloud, and the streets underneath are drawn across the clouds as dotted lines so you can plan where to go. Bits with no street or path (bush, wetland, canals) don't count towards 100%, so each one clears when you walk the street nearest to it. The look came from a round of concept art in `design/concepts/`, and `design/compare/` shows why the no-path bits are clouded too.
- **Walks** keep tracking with the phone locked in your pocket, using "While Using the App" location permission plus the background location mode. Tiles turn orange as you uncover them, and the phone buzzes if the app's open.
- **Always on** is switched on by the first-run setup (`SetupView`), which asks for location, motion and notifications one at a time. With "Always" location permission, walks start by themselves when you're moving on foot and end after 10 minutes without moving. GPS pauses while you're still, and iOS relaunches the app after a few hundred metres if it was closed. Only on-foot points are saved. It can be turned off in Settings, and then you press Start walk.
- **Neighbours**: zoomed out, the suburbs within about 5 km of your places are outlined with a "+ name" button to add them. Overpass finds the localities (admin_level 9 in WA, 10 elsewhere in Australia) and one Nominatim lookup fetches their outlines. Overpass is often slow or down, so if it fails the app asks Nominatim which suburb each point on a 2.5 km grid is in instead, and retries a few times if that fails too. The list is kept in `nearby.json` for a month. A new place within 40 km of one you've got uses the same hex grid, so tiles line up along the borders, and the map draws every place's clouds at once.
- **The map** starts tilted at an isometric angle with Apple's 3D buildings (Settings > 3D view to flatten it). Your position is drawn on top of the clouds, since MapKit's own dot would be under them.
- **Walking only**: fixes worse than 30 m accuracy are ignored, anything faster than about 12 km/h (by the GPS's own speed reading) doesn't count, and the phone's motion chip vetoes anything it thinks is cycling or driving, however slow. A spot only counts once two on-foot fixes in a row agree, and gaps over 150 m aren't joined up.
- **Secrets**: 40 bits of local history, Wardandi Noongar heritage and nature for the Busselton area, in `Walkies/Lore/geographe.json` (research notes and sources in `design/lore/`). Each is hidden under a tile, with nothing on the map to give it away: stories about a spot go under the nearest street tile to it, the rest are spread out. Walk over one and you get a pop-up, or a notification if the phone's in your pocket. Found secrets are pinned on the map and kept in the Secrets book, each with its own sticker. In the code they're `LoreEntry` and "stickers". The art is made by `scripts/make-stickers.mjs` (Gemini 3 Pro Image, then cut out with Vision by `scripts/cutout.swift`).
- **History**: every GPS fix from every walk is kept. A new city is built by replaying all past walks, so if you add a city later, the walks you've already done there count.
- **Storage** is local-first: everything is JSON in the app's Application Support folder, and the app works fully offline. Whenever there's signal it syncs with your account on Convex, so a lost phone loses nothing and a new phone gets everything back when you sign in.
- **Accounts** use Convex Auth v2 (`@convex-dev/auth` 2.0 beta) with Sign in with Apple and Google, so every account has an email address to reach people with. Each person only sees their own data.

## Running it

Open `Walkies.xcodeproj` in Xcode 27, pick your iPhone and hit Run. It needs iOS 18 or later, and uses the iOS 26 glass look where it can. Signing is set to the same team as Lets Build It (`4DTAZSZL6B`).

The project uses Xcode's synced folders, so any Swift file you drop into `Walkies/` is picked up without touching the project file.

Tests:

```bash
xcodebuild -project Walkies.xcodeproj -scheme Walkies -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

To fake a walk in the simulator, start a walk in the app and then:

```bash
scripts/sim-walk.sh scripts/routes/navigation-way.txt
```

To test always-on without waiting 10 minutes for a walk to end, launch with a shorter gap: `xcrun simctl launch booted com.mikecann.walkies -autoWalkGap 20`.

### Simulator test accounts

Debug simulator builds have a small **Test sign-in (simulator only)** button. It uses Convex Auth v2's anonymous method to create a fresh account without Apple or Google. The server refuses both the test wrapper and direct anonymous sign-in unless `WALKIES_TEST_SIGNIN` is exactly `1`. Enable that variable only on dev (`resolute-pig-177`), never production. It is optional and disabled when unset. No user schema changes are needed.

For two installed Debug simulators, launch each with its device UUID and a different name:

```bash
xcrun simctl launch <simulator-A-UUID> com.mikecann.walkies -testSignIn -testUserName 'Sim A'
xcrun simctl launch <simulator-B-UUID> com.mikecann.walkies -testSignIn -testUserName 'Sim B'
```

`-testSignIn` runs once at launch only if signed out. It saves and refreshes the session in the usual Keychain, so relaunching keeps the same user. Sign out before launching again to create a new account. `-testUserName` also applies to the button; without it the server chooses a name like `Test walker 3F7A`. Test accounts have no email and never merge by email. The button, launch arguments and test sign-in code are compiled out of Release and physical-device builds. Create a team on one simulator and join it with its invite code on the other.

## Backend

Convex, in Sydney (`aws-ap-southeast-2`), team `mikec`, project `walkies`:

- **dev** `resolute-pig-177`: the simulator talks to this one.
- **production** `savory-bee-296`: real phones talk to this one.

```bash
npm install
npx convex dev
```

Deploy with `npx convex deploy`. The auth signing keys were set with `npx @convex-dev/auth` (dev) and `node scripts/set-prod-auth-keys.mjs` (prod).

How sync works: walks never change once finished, tiles only get uncovered and secrets only get found, so syncing is just adding. The phone uploads anything the server hasn't got (walk and city files go to Convex file storage), downloads anything it hasn't got, and merges cities by keeping every tile either copy uncovered. See `convex/sync.ts` and `Walkies/Services/Sync.swift`.

Team maps have a separate backend in `convex/crews.ts`. The [team API contract](design/crews-api.md) documents uploads, membership, invite links and incremental tile sync used by the phone integration. The place chip switches between My map and team maps, with create, join and team settings alongside the place list. Team tiles, clipped trails and secrets are queued locally in `crews.json` and per-team files, retried by sync and refreshed every three minutes while the app is open. Joining or adding a team place replays saved walks off the main actor onto its shared grid. Run its backend tests with `npm test`, and check types with `npx tsc -p convex --noEmit`.

Suburb street data is shared across accounts in `placeData`, keyed by OSM relation id. `places:get` requires sign-in and returns a storage URL for compact JSON (GeoJSON boundary rings and tagged street lines), refreshing after 60 days. `places:warm` schedules missing or stale neighbours without waiting for OSM. Fetch markers deduplicate work; `osmId: 0` is a shared Nominatim throttle, keeping requests at least 1.1 seconds apart. Pending markers have no file yet. These files contain public OSM data, not anyone's walks.

Offline cache checks: `node scripts/test-places.mjs` and `bash scripts/test-places-model.sh`. The latter runs the real Swift builder and HTTP fallback tests on macOS when Simulator is unavailable.

Sign-in runs Apple's or Google's page in an `ASWebAuthenticationSession`. Convex Auth's callback (`/oauth/apple/callback`, `/oauth/google/callback`) sends the browser on to `/app/signed-in?convexAuthCode=…` on the same deployment, which the sheet catches (the app is linked to that domain through `/.well-known/apple-app-site-association` in `convex/http.ts` and `Config/Walkies.entitlements`). The app then calls `completeSignInWith…` with the code.

### Setting up Apple and Google sign-in

Each deployment needs its own return URLs registered:

- dev: `https://resolute-pig-177.ap-southeast-2.convex.site`
- prod: `https://savory-bee-296.ap-southeast-2.convex.site`

**Apple** (developer.apple.com > Certificates, IDs & Profiles):
1. Identifiers > App IDs > `com.mikecann.walkies`: tick Sign in with Apple.
2. Identifiers > + > Services IDs: make one, e.g. `com.mikecann.walkies.signin`. Tick Sign in with Apple > Configure: primary App ID `com.mikecann.walkies`, domains `resolute-pig-177.ap-southeast-2.convex.site` and `savory-bee-296.ap-southeast-2.convex.site`, return URLs `<site>/oauth/apple/callback` for both.
3. Keys > +: tick Sign in with Apple (configure it for `com.mikecann.walkies`), download the `AuthKey_<ID>.p8` and note the key ID.

**Google** (console.cloud.google.com, a project for Walkies):
1. APIs & Services > OAuth consent screen: External, add yourself and your dad as test users.
2. Credentials > Create credentials > OAuth client ID > Web application. Authorised redirect URIs: `<site>/oauth/google/callback` for both sites. Copy the client ID and secret.

Then put them in a JSON file (see the top of `scripts/set-oauth-keys.mjs`) and run it for each deployment:

```bash
node scripts/set-oauth-keys.mjs dev ~/Downloads/walkies-oauth.json
```

```bash
node scripts/set-oauth-keys.mjs prod ~/Downloads/walkies-oauth.json
```

What's set up now (2026-10-19): Services ID `com.mikecann.walkies.signin` (shown to people as "Walkies"), Sign in with Apple key `CYUWDZYQ3R`, and Google project `walkies-512104` on mike.cann@gmail.com with the "Walkies (Convex)" web client. Google's consent screen is in Testing, so only listed test users can sign in. To swap the Apple key, make a new one, then run the script with a JSON holding just `appleKeyId` and `appleKeyFile`; it skips anything missing.

Signing in with Apple and Google gives the same account when both vouch for the same email (`existingUser` in `convex/users.ts`). Users made twice before that was in place are folded together by `users:mergeDuplicateUsers`, which points the newer one at the older with `mergedInto`; every function finds who's signed in with `currentUserId`, which follows it.

### Chef (feature requests)

Settings has "Suggest a feature", which opens Chef, Seth Raphael's feedback board (`@convex-dev/feedback`, private and pre-release, from `sethconvex/feedback-chef`). People type a request or send a screenshot with a voice note and follow it through; the admin (Mike's prod account) sees the approval queue in the same sheet. Cloud builds aren't set up.

- Backend: the component in `convex/convex.config.ts`, the API in `convex/chef.ts` (written by `npx chef init --no-cloud`, then pointed at `currentUserId` so merged accounts are one person). The package is vendored in `vendor/` from a pinned commit.
- App: the `ChefKit` Swift package, pinned to the same commit. `Walkies/Services/ChefConnection.swift` lets it use Walkies' own HTTP client and sign-in, polling where ChefKit expects live subscriptions. Its floating button is hidden; Settings opens it with `ChefKit.present()`.
- Admin: `npx convex run chef:chefSetAdmin '{"userId":"<users _id>"}' --prod`.

## Code map

- `Walkies/Model/` is the maths: a flat local projection (`Geo`), the hex grid, boundaries and point-in-polygon, cities, walks, and the GPS filter (`CoverageTracer`).
- `Walkies/Services/` talks to OpenStreetMap (`OSMClient`), builds a city's tiles (`CityBuilder`), runs GPS (`LocationTracker`) and saves files (`Store`).
- `Walkies/Services/Account.swift` is Apple and Google sign-in and the session (Keychain, token refresh), `Sync.swift` is the sync engine, and `Convex.swift` calls Convex over its HTTP API.
- `convex/` is the backend: auth, schema and sync functions.
- `Walkies/AppModel.swift` ties it together: GPS fixes in, tiles uncovered, saved every 30 seconds.
- `Walkies/Views/` is SwiftUI, apart from `FogMapView`, which wraps `MKMapView`, and `Clouds.swift`, a custom MapKit overlay renderer. It draws a soft cloud sprite over every unwalked hex (all the grey undersides first, then all the white tops, so they merge into one blanket), cuts soft holes over walked hexes, and dots the hidden streets on top. The sprites are drawn in code at launch.
- The app icon and the Start walk and Secrets icons were drawn by Gemini 3 Pro Image. The concepts and their prompts are in `design/app-icon/`; the icon is `icon-badge`.

## Ideas for later

- Pull past walks out of Apple Health, so a new city starts with everywhere you've already been.
- Point you at the nearest patch of fog.
- A Live Activity on the lock screen showing new tiles this walk.
- Lore for more places. Each place needs its own researched JSON file in `Walkies/Lore/`.
- Sync to Convex so a few people can race on the same suburb.
- A choice of tile size.
