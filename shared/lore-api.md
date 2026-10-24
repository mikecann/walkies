# Secrets for new suburbs: what the apps get

The server researches and writes secrets for a suburb once someone has added it and walked in it (`convex/lore.ts`). This is what the iPhone and Android apps build against to download them. The apps don't use any of it yet.

## `lore:forPlace`

A public query. It needs a signed-in user, like `places:get`.

```
lore:forPlace({ osmId: number }) -> { status, version, entries }
```

`osmId` is the place's OpenStreetMap relation, `City.osmId`. A place without one has no server secrets.

| `status` | What it means | What the app does |
|---|---|---|
| `bundled` | The app ships its own secrets for this place (the Busselton area, `bundledOsmIds` in `convex/loreConfig.ts`). | Use the bundled ones. Don't ask again. |
| `none` | Nobody has walked here since the server started researching. | Nothing yet. Ask again after the next walk there syncs. |
| `queued` | Waiting for a free slot or for a spending cap to reset. It can take until the next day. | Show the "researching your area" card. |
| `researching` | A run is going. It takes 5 to 15 minutes. | Show the card, and ask again every couple of minutes while the app's open. |
| `ready` | Done. | Use `entries`. |
| `quiet` | Done, but there wasn't much to find (fewer than three secrets). Whatever was found is in `entries`. The server has one more look after 90 days. | Use `entries`, with friendly copy about a quiet suburb. |
| `failed` | The run broke. The server retries once after a day. | Treat it like `none`. |

`version` goes up whenever the live secrets change: a run finishing, Mike approving one, or Mike hiding one. Cache the answer and the sticker PNGs in Application Support, and only fetch the stickers again when `version` changes. A secret can disappear from `entries` (hidden later), so replace the cached list rather than merging it.

Only live secrets come back. Ones waiting for Mike's review, hidden ones, and ones the checks dropped never do.

## An entry

Each entry is the same JSON as a `LoreEntry` in `Walkies/Lore/*.json` (`Walkies/Model/Lore.swift`, `Lore.kt` on Android), plus `stickerUrl`, so the existing decoders read it:

```json
{
  "id": "osm11688696-the-seagrass-that-moved-house",
  "title": "The Seagrass That Moved House",
  "body": "45 to 95 words of the story.",
  "category": "the-sea",
  "place": { "name": "Western Beach, Port Geographe", "lat": -33.632, "lon": 115.3865 },
  "sticker": "A grumpy brown mountain of seagrass with little wavy stink lines rising off the top",
  "sources": ["https://www.abc.net.au/news/..."],
  "suburb": "Geographe",
  "stickerUrl": "https://<deployment>.convex.cloud/api/storage/<id>"
}
```

- `id` always starts with `osm<relation>-`, so it never clashes with a bundled secret's id. Found secrets sync with `sync:saveSecrets` the same way as bundled ones.
- `category` is one of `history`, `first-nations`, `nature`, `the-sea`, `odd-records` or `modern-life`.
- `place` is missing when the story is about the whole suburb. Those get scattered over its streets, the same as bundled ones without a pin. When it's there, it's already been moved onto the nearest walkable street inside the suburb, so `placeStickers()` will find a street tile for it.
- `suburb` is the place's OpenStreetMap name. Assign server entries to a city by `City.osmId`, not by matching this.
- `photos` is never set.
- `sticker` is what the art shows. The art itself is at `stickerUrl`: a 512 × 512 PNG on a transparent background, the same as the bundled `sticker-<id>` assets. It's `null` if the drawing failed, so show a plain placeholder sticker.

## Running it by hand

All of these are internal, so only `npx convex run` (or the dashboard) can call them. Add `--prod` for production.

| Command | What it does |
|---|---|
| `npx convex run lore:status` | Every researched place, what it cost, and today's and this month's spend |
| `npx convex run lore:credits` | What the OpenRouter key has used and has left, from OpenRouter (its limit is the backstop behind the caps) |
| `npx convex run lore:research '{"osmId": 123}'` | Researches a place now, ignoring the switch and the walked check but not the caps |
| `npx convex run lore:entries '{"osmId": 123}'` | Every secret a place's runs wrote, dropped ones too, with what each check said |
| `npx convex run lore:pending` | Secrets waiting for review |
| `npx convex run lore:approve '{"entryId": "osm123-..."}'` | Puts one live |
| `npx convex run lore:hide '{"entryId": "osm123-..."}'` | Takes one down |
| `npx convex run lore:resume '{"osmId": 123, "from": "lorePipeline:write"}'` | Runs a finished run again from one of its steps, keeping what the earlier steps found and paid for |

To redraw a place's stickers, resume from its first sticker step, e.g. `"from": "sticker osm123-<slug>"`; the step names are in the workflow's journal on the dashboard.

Walks only start research when the deployment's `LORE_AUTO` environment variable is exactly `1`. It's unset on dev and prod.
