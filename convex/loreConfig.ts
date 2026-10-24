// Settings for researching secrets for new suburbs (lore.ts, lorePipeline.ts).

/**
 * The OpenRouter models for each step. The fact-checker is always from a different
 * lab to the writer, so the two don't share blind spots. To drop to the cheaper tier
 * (about $1.50 a suburb instead of $4), set `models` to `tiers.flash`.
 */
export const tiers = {
  best: {
    research: "anthropic/claude-sonnet-5.5",
    write: "anthropic/claude-opus-5.5",
    check: "openai/gpt-5.6-terra",
    sticker: "google/gemini-3-pro-image",
  },
  flash: {
    research: "google/gemini-3.8-flash",
    write: "google/gemini-3.8-flash",
    check: "openai/gpt-5.6-luna",
    sticker: "google/gemini-3.1-flash-image",
  },
} as const;
export const models = tiers.best;

/** US dollars, from OpenRouter's own `usage.cost` on every call. */
export const caps = {
  /** One suburb's run stops here, whatever step it's on. */
  perRun: 6,
  /** Across everyone, by UTC day and month. A run only starts if it can't take either over. */
  daily: 15,
  monthly: 50,
};

/** Research runs at once, across everyone. */
export const maxRunning = 2;
/** New suburbs one person's walks can start in a UTC day. Spoofed GPS still hits the daily cap. */
export const suburbsPerUserPerDay = 3;
/**
 * Walked tiles a place needs before it's researched: about 250 m of walking, so a
 * GPS wobble over the border of a place you added doesn't start a paid run.
 */
export const minWalkedTiles = 3;

/** How many secrets a run aims for. Fewer than `enough` survive and the place is "quiet". */
export const entries = { enough: 3, most: 8 };
export const day = 24 * 60 * 60 * 1000;
/** A quiet place gets one more look after this, in case more has been written about it. */
export const quietRetry = 90 * day;
/** A run that broke gets another go after this, up to `maxAttempts` runs in all. */
export const failedRetry = day;
export const maxAttempts = 2;

export const research = {
  /** Each research angle stops after this many model calls... */
  maxSteps: 22,
  /** ...or this many saved notes... */
  maxNotes: 14,
  /** ...or this much spend, or this long (Convex runtime actions can run for 30 minutes). */
  maxSpend: 0.9,
  maxTime: 14 * 60 * 1000,
  /**
   * Most a research step can write. OpenRouter turns a call away unless the key can
   * afford its maximum, and the default (64k tokens) needs far more credit than a step uses.
   */
  outputTokens: 8000,
  /** Characters of a page the model gets per fetch. About 3,000 tokens. */
  pageChars: 12_000,
  /** OpenRouter's web search (Exa, $0.007 a search): results per search, characters per result. */
  searchResults: 5,
  searchChars: 1200,
};

/** Stories about a spot further than this from a walkable street are scattered instead,
 * the same limit `placeStickers` uses on the phones. */
export const maxPinToStreet = 300;

/**
 * The OSM relations the bundled lore covers (`Walkies/Lore/geographe.json` and
 * `busselton-area.json`), which never get researched. These are the 29 `suburb` names
 * in those files, matched to the admin_level 9 localities Overpass lists inside the
 * City of Busselton and the Shire of Capel (every name matched exactly). A
 * point-in-polygon test of every pin against those localities' outlines put each one
 * in the suburb its entry names, so no other suburb has bundled secrets. Checked
 * 2026-10-24. Update this when a new bundled file ships.
 */
export const bundledOsmIds = new Set([
  11688677, // Abbey
  11688685, // Acton Park
  11688680, // Ambergate
  11688681, // Bovell
  11688678, // Broadwater
  11688699, // Busselton
  11688793, // Capel
  11688673, // Carbunup River
  11688722, // Forrest Beach
  11688696, // Geographe
  11688671, // Jindong
  11688688, // Kalgup
  11295258, // Kealy
  11688694, // Ludlow
  11688674, // Marybrook
  11688672, // North Jindong
  11688723, // Peppermint Grove Beach
  11688697, // Reinscourt
  11688692, // Ruabon
  11688684, // Sabina River
  11688676, // Siesta Park
  11688724, // Stirling Estate
  11688693, // Tutunup
  11295257, // Vasse
  11688700, // West Busselton
  11688695, // Wonnerup
  11688698, // Yalyalup
  11688683, // Yoganup
  11688689, // Yoongarillup
]);

/**
 * First Nations stories only come from these: state government (which covers WA's
 * councils, Landgate's naming records and DPIRD), AIATSIS, and the South West's
 * Traditional Owner organisations, the same sources the hand research kept to.
 */
export const firstNationsSources = [
  ".wa.gov.au", "aiatsis.gov.au", "noongar.org.au", "noongarculture.org.au", "undalup.com", "undalup.com.au",
];

/** Two of the bundled stickers, served by the website, so new art matches the old. */
export const stickerReferences = [
  "https://walkies.mikecann.app/img/sticker-a-piano-on-a-truck.png",
  "https://walkies.mikecann.app/img/sticker-a-rest-stop-for-whales.png",
];
