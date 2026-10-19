# Progression: shells, levels, shop and quests

Mike asked (in Chef): "Is there something you could unlock other than the secrets as you level, maybe give you some agency to choose in a shop or something?" He approved all of this.

The rule throughout: **you can't buy progress**. Nothing clears tiles or finds secrets for you. Shells buy looks and hints; walking is still the only way to 100%.

## Shells (the currency)

Everything you've earned is **worked out from what's already synced** (places, walks, secrets), never stored as a running total. So two phones can't disagree, and a new phone shows the right number straight away.

| For | Shells |
|---|---|
| Each counting tile you've walked, in every place (`tiles ∩ visited`) | 1 |
| Each secret found | 10 |
| A place passing 10% / 25% / 50% / 75% / 90% / 100% | 20 / 30 / 50 / 75 / 100 / 250 |
| Each day with a walk (≥ 300 m) that follows a day with a walk | 5 × (days in the streak − 1), at most 25 a day |
| Each weekly quest completed | 40 |

Spending is an **append-only ledger** (see Ledger), so balance = earned − spent.

## Levels

XP is total shells earned (spending doesn't lower it). Level `n` (starting at 1) needs `50 × n × (n − 1) / 2` XP: 0, 50, 150, 300, 500, 750, 1050, …

Each level gained gives a **pick of three** (the agency): chosen from, in order of preference, shop cosmetics you don't own yet (worth up to about the level's price range), a bag of 50 shells, or 2 spyglasses. The three choices for a level are fixed (seeded by the level number), so they don't change if you close the sheet. Unclaimed picks wait; the shells chip shows a dot until you choose.

## Weekly quests

Three quests each week (Monday to Sunday, phone's local time), picked by a seed from the year and week number, from:

- Uncover 25 new tiles this week
- Uncover 60 new tiles this week
- Find a secret this week
- Walk on 3 different days this week
- Walk 5 km in total this week
- Uncover tiles in a place other than the one you've uncovered most of

Progress comes from that week's walks and secrets. Each completed quest gives 40 shells (counted in "earned" automatically). The celebration summary shows quest progress after each walk.

## The shop

Prices in shells. The free one in each group is what everyone starts with.

| Group | Items |
|---|---|
| Map marker (you on the map) | Classic dot (free), Sneaker 150, Paper boat 200, Explorer hat 250, Little lighthouse 300 |
| Trail (your route line) | Teal line (free), Footprints 150, Sparkles 250, Rainbow 400 |
| Clouds | Classic (free), Sunset 300, Storm 300, Cotton candy 400 |
| Secrets book cover | Red leather (free), Seashell 200, Old map 200, Gold 500 |
| Celebration | Confetti (free), Bubbles 200, Fireworks 250 |
| Spyglass (used up) | 60 each |

Buying equips it. A wardrobe lets you switch between anything you own.

## The spyglass

Use one from the shop sheet when there's an unfound secret in the selected place. It draws a soft gold dashed ring on the map, about 250 m across, around the nearest unfound secret's tile, with its centre nudged up to 120 m off (seeded, so it doesn't move), so it says "somewhere round here" without giving the tile away. The ring lasts until that secret is found or 3 hours pass.

## Ledger (synced)

```json
{
  "purchases": [{ "id": "uuid", "item": "trail.sparkles", "cost": 250, "at": 1790000000 }],
  "claims":    [{ "level": 3, "choice": "marker.sneaker" }],
  "spyglasses":[{ "id": "uuid", "secretId": "...", "centre": [lat, lon], "at": 1790000000 }],
  "equipped":  { "marker": "marker.dot", "trail": "trail.teal", "clouds": "clouds.classic", "cover": "cover.red", "celebration": "celebration.confetti", "updatedAt": 1790000000 }
}
```

Merging two copies: union purchases and spyglasses by id, claims by level (first wins), equipped by the later `updatedAt`. Saved on the phone as `progress.json`, and in Convex as one `progress` row per user holding the ledger JSON, merged in the mutation the same way, and returned by `sync:snapshot`.

## Where things show

- **Shells chip**: under the place chip, top left: a shell, the balance, and "Lv 4". A dot when there's a level pick waiting. Tap for the Progress sheet.
- **Progress sheet**: level and XP bar, this week's quests, the shop, the wardrobe, spyglasses.
- **Celebration summary**: shells earned on this walk (counting up with a shell sound), the XP bar filling, quests ticking, and "Level up, choose a reward" when one's waiting.
- **Map**: marker style, trail style, cloud theme and the spyglass ring.
- **Secrets book**: the cover style behind its header.
