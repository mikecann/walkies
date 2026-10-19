# Walkies

An iPhone app that turns dog walks into exploring. Add your suburb and it disappears under clouds on a satellite map. Go for a walk and the clouds clear off the hex tiles you walk through. The goal is to get your suburb to 100%.

Based on an idea from James.

## How it works

- **Adding a city** searches OpenStreetMap (Nominatim) for a place with a proper boundary, then pulls every street and path inside it from Overpass. A suburb takes up to 30 seconds or so, because Overpass is slow.
- **Tiles** are hexes 50 m from centre to corner, so about 87 m across. Only tiles with a street or path through them count towards the total, so canals, the estuary and the middle of the bay don't stop you finishing. If you walk through a tile that wasn't counted (a beach, or a park with no mapped paths) it gets added and counts.
- **The map** is Apple's satellite view with labels. The whole suburb starts under cloud, and the streets underneath are drawn across the clouds as dotted lines so you can plan where to go. Bits with no street or path (bush, wetland, canals) don't count towards 100%, so each one clears when you walk the street nearest to it. The look came from a round of concept art in `design/concepts/`, and `design/compare/` shows why the no-path bits are clouded too.
- **Walks** keep tracking with the phone locked in your pocket, using "While Using the App" location permission plus the background location mode. Tiles turn orange as you uncover them, and the phone buzzes if the app's open.
- **Always on** (in Settings, the gear button): with "Always" location permission, walks start by themselves when you're moving on foot and end after 10 minutes without moving. GPS pauses while you're still, and iOS relaunches the app after a few hundred metres if it was closed. Only on-foot points are saved. Without it, you press Start walk.
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

## Code map

- `Walkies/Model/` is the maths: a flat local projection (`Geo`), the hex grid, boundaries and point-in-polygon, cities, walks, and the GPS filter (`CoverageTracer`).
- `Walkies/Services/` talks to OpenStreetMap (`OSMClient`), builds a city's tiles (`CityBuilder`), runs GPS (`LocationTracker`) and saves files (`Store`).
- `Walkies/Services/Account.swift` is Apple and Google sign-in and the session (Keychain, token refresh), `Sync.swift` is the sync engine, and `Convex.swift` calls Convex over its HTTP API.
- `convex/` is the backend: auth, schema and sync functions.
- `Walkies/AppModel.swift` ties it together: GPS fixes in, tiles uncovered, saved every 30 seconds.
- `Walkies/Views/` is SwiftUI, apart from `FogMapView`, which wraps `MKMapView`, and `Clouds.swift`, a custom MapKit overlay renderer. It draws a soft cloud sprite over every unwalked hex (all the grey undersides first, then all the white tops, so they merge into one blanket), cuts soft holes over walked hexes, and dots the hidden streets on top. The sprites are drawn in code at launch.
- `scripts/make-icon.swift` draws the app icon.

## Ideas for later

- Pull past walks out of Apple Health, so a new city starts with everywhere you've already been.
- Point you at the nearest patch of fog.
- A Live Activity on the lock screen showing new tiles this walk.
- Lore for more places. Each place needs its own researched JSON file in `Walkies/Lore/`.
- Sync to Convex so a few people can race on the same suburb.
- A choice of tile size.
