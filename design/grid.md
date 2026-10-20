# World grid, version 2

A tile identifies the same patch of ground for every place, user and platform.
There is one pointy-top axial hex grid, anchored at projected (0, 0), with no
per-place origin. `HexGrid.world` in Swift and `convex/grid.ts` implement it.
City save files contain `gridVersion: 2`, tiles and geometry, but no grid or origin.

## Projection and scale

Coordinates are latitude/longitude in degrees. All arithmetic is IEEE 754 Double
(JavaScript `number`). Convert angles to radians with `degrees * π / 180`.

```
R = 6_378_137
referenceLatitude = -33.65°
k = cos(referenceLatitude * π / 180) = approximately 0.8324379983891649
A = R * k
size = 50

x = A * longitude * π / 180
y = A * ln(tan(π / 4 + (latitude * π / 180) / 2))

longitude = (x / A) * 180 / π
latitude = (2 * atan(exp(y / A)) - π / 2) * 180 / π
```

Use the computed cosine, not the rounded decimal above. x points east and y north.
These are spherical Web Mercator units scaled so they are true ground metres at
latitude -33.65°. The local ground length of a projected length `d` at latitude φ
is `d * cos(φ) / k`. Centre-to-corner size is therefore 50 m at Busselton,
about 60 m at the equator and about 37 m in London. The scale is conformal, so the
hexes look regular on Apple Maps.

The normal Web Mercator map domain is approximately ±85.05112878° latitude and
±180° longitude. The formulas do not clamp or wrap coordinates. Poles are not
supported. Tiles at the antimeridian have distinct IDs on either side of the map
seam; neighbour arithmetic does not wrap around it.

`Coordinate.distance` uses a different, mean Earth radius (6_371_008.8 m). Tests
of the specified spherical scale account for that 0.112% difference.

## Axial conversion and rounding

```
q = (sqrt(3) / 3 * x - y / 3) / size
r = (2 / 3 * y) / size
s = -q - r

rq = roundAwayFromZero(q)
rr = roundAwayFromZero(r)
rs = roundAwayFromZero(s)
dq = abs(rq - q)
dr = abs(rr - r)
ds = abs(rs - s)

if dq > dr && dq > ds: rq = -rr - rs
else if dr > ds:      rr = -rq - rs
// Otherwise the correction is to s, which we do not store.
```

Half ties round away from zero, matching Swift `.rounded()`:
`roundAwayFromZero(n) = sign(n) * floor(abs(n) + 0.5)`. JavaScript `Math.round`
is insufficient for negative half ties. The strict `>` comparisons above are
intentional: a q/r error tie prefers correcting r, and a tie with s leaves q/r
alone. Canonicalize negative zero to zero. Store q/r as signed Int32 in Swift;
JSON stores each hex compactly as `[q, r]`. Normal world extents fit comfortably.

```
centre.x = size * sqrt(3) * (q + r / 2)
centre.y = size * 1.5 * r
area = 3 * sqrt(3) / 2 * size²
```

Corners run counterclockwise in projected coordinates, beginning southeast:
for i = 0 through 5, angle = `(60 * i - 30) * π / 180`, and corner = centre +
`size * (cos(angle), sin(angle))`. Inverse-project to obtain lat/lon.

Neighbour order is fixed:

```
(q+1, r), (q+1, r-1), (q, r-1), (q-1, r), (q-1, r+1), (q, r+1)
```

Edge i, from corner i to corner (i+1)%6, faces these offsets instead:
`(1,0), (0,1), (-1,1), (-1,0), (0,-1), (1,-1)`.

Rectangle enumeration uses rowHeight = `size * 1.5`, colWidth = `size * sqrt(3)`.
For r from `floor(lo.y / rowHeight)-1` through `ceil(hi.y / rowHeight)+1`, set
shift = r/2, then enumerate q from `floor(lo.x/colWidth-shift)-1` through
`ceil(hi.x/colWidth-shift)+1`. Keep only centres within the inclusive rectangle.

## Worked examples

These expected results are hard-coded in both Swift and TypeScript tests.

| Latitude | Longitude | q | r |
| ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 |
| -33.65 | 115.35 | 145525 | -44196 |
| -33.638 | 115.386 | 145554 | -44178 |
| 51.5074 | -0.1278 | -37383 | 74493 |
| 0 | 30 | 32101 | 0 |
| -33.65 | -115.35 | -101329 | -44196 |
| 40.7128 | -74.006 | -106770 | 55164 |
| 85 | 179.9 | 81661 | 221671 |
| -85 | -179.9 | -81661 | -221671 |

For the Busselton example (-33.65, 115.35), the projected point is approximately
(10689089.322164, -3314686.399223), giving (145525, -44196).

## Place membership and rendering

A tile counts for a place when its **centre** is inside the projected boundary
and outside any holes. Streets select counting tiles from those centres; a
walked tile whose centre is inside is added even if no street was mapped there.
The boundary ray test uses strict `point.x < crossing.x`, so west/south rectangle
edges are included and east/north edges excluded. Places with overlapping
boundaries can share a tile. A GPS fix across a place border can still uncover
the tile in the neighbouring place if the tile's centre belongs there.

No-path flood fill uses the same world neighbours. Lore, recaps, the drag
honeycomb and neighbouring-place buttons all use `City.grid`, which returns
`.world`. LocalProjection remains for geometry unrelated to tile identity.

Apple map points are also Web Mercator. A projected unit is a constant
`MKMapSize.world.width / (2 * π * R * k)` map points. Cloud radii use that factor;
centres and corners are still cached when coverage changes, with no new work
per animation frame.

## Reset and deployment

On the first launch with local data version below 2, Store writes a durable
`world-grid-reset.json` containing only each place's UUID, name, detail, boundary,
OSM relation ID and creation time. It deletes cities, stickers, the progression
ledger, nearby-place cache and sync bookkeeping. It strips saved walks' tile
counts, hex IDs and recap additions, retaining their UUIDs, timestamps and GPS.
The account/session, preferences and team membership cache are retained.

Before personal sync, the app fetches each known relation through `places:get`,
rebuilds it on the world grid and assigns lore again. This checkout's old City
format did not save osmId, so the reset first tries the nearby cache, then resolves
matching names near the saved boundary through Nominatim. If no relation exists,
the saved boundary can still be rebuilt from current Overpass ways. New cities
save osmId so later rebuilds go directly to the shared cache.

Saved walks replay in timestamp/UUID order through CoverageTracer and City.visit.
The app recomputes visited/counting tiles, per-walk counts and hex identities,
recap additions, distance and discovered secrets. Secret discovery dates use the
walk's end date. Shells, XP, levels and quests derive from that rebuilt history.
Purchases, claimed picks, spyglasses and short outings without saved GPS are lost.
The pending file survives offline errors or interruption, and is removed only
after every rebuilt file is written. Pending level choices are then regenerated.
Tracking and personal sync wait for rebuilding to finish. Sync retries it at the
next launch, foreground sync or manual sync. No server data migration runs.

Deploy the new backend and clear **places, progress and secrets** on both dev and
prod before allowing the new app to sync. Keep **walks**, their storage blobs,
users/auth data, teams/membership tables, and **placeData** (raw OSM street cache).
The old place blobs in `_storage` are disposable too, but do not indiscriminately
empty `_storage`: it also contains the walks and OSM cache files.

All mutations that save places, progress, secrets **and walks**, plus deletePlace,
require the literal argument `gridVersion: 2`; old clients fail runtime validation.
No Convex table/schema change is needed. Walk blobs include derived hexes, so the
new app sanitizes legacy downloaded walks and replaces the server copy of each
local walk after replay, retaining its identity/raw GPS and updating newTiles.
Legacy place blobs are rejected on download instead of being interpreted on the
world grid. Clearing the three derived tables remains an explicit deployment step.
