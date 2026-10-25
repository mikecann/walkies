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

/**
 * US dollars, from OpenRouter's own `usage.cost` on every call. Hard limits: before
 * each paid call a hold for the most it could cost is booked against all three
 * (loreRun.reserve), and a call that would pass one isn't made. The hold is settled to
 * the real cost after, or kept as spent if the cost never comes back.
 */
export const caps = {
  /** One budget segment of a suburb's run: a run, or a lore:resume of one. */
  perRun: 6,
  /** Across everyone, by UTC day and month. A run only starts if it can't take either
   * over, even if every run going spends its whole limit. */
  daily: 15,
  monthly: 50,
};

/**
 * US dollars per token for each chat model, from OpenRouter's /api/v1/models on
 * 2026-10-25. `input` is the dearest a prompt token can be billed: Anthropic's
 * 5-minute cache write (1.25 times its input price), and OpenAI's long-prompt rate.
 * A model that isn't here is never called, so a new tier needs its prices first.
 */
export const prices: Record<string, { input: number; output: number; image?: number }> = {
  "anthropic/claude-sonnet-5.5": { input: 2.5e-6, output: 10e-6 },
  "anthropic/claude-opus-5.5": { input: 5e-6, output: 20e-6 },
  "openai/gpt-5.6-terra": { input: 5e-6, output: 18e-6 },
  "openai/gpt-5.6-luna": { input: 0.5e-6, output: 1.8e-6 },
  "google/gemini-3.8-flash": { input: 0.825e-6, output: 4.125e-6 },
  // `image` is what an image token written costs; images read (the reference stickers) cost `input`.
  "google/gemini-3-pro-image": { input: 2e-6, output: 12e-6, image: 120e-6 },
  "google/gemini-3.1-flash-image": { input: 0.5e-6, output: 3e-6, image: 60e-6 },
};

/** What a hold assumes about a call it can't see the inside of. */
export const holds = {
  /** Request bytes per prompt token, at least. Real text runs 3 to 4. */
  bytesPerToken: 2,
  /** Tokens an attached image costs to read, and one drawn sticker costs to write
   * (Gemini's 1K and 2K images are 1,120; 4K is 2,000). */
  imageInTokens: 1_120,
  imageOutTokens: 2_000,
  /** Most a sticker answer can write besides its image. */
  stickerOutputTokens: 8_000,
  /** Searches OpenRouter's web_search may run inside one request (its `max_uses`), and
   * what one costs: Exa is $0.007, native search $0.01. Each search means the model
   * reads the conversation again, so a call can bill this many times over plus one. */
  searchesPerCall: 1,
  searchPrice: 0.01,
  /** A hold still open after this is a call that crashed: lore.tick keeps it as spent. */
  staleAfter: 60 * 60 * 1000,
};

/** Research runs at once, across everyone. */
export const maxRunning = 2;
/** New suburbs one person's walks can start in a UTC day and month. Spoofed GPS hits these. */
export const suburbsPerUserPerDay = 3;
export const suburbsPerUserPerMonth = 6;
/** Places one person's saves and walks can have checked in a UTC day (each check may ask Nominatim). */
export const checksPerUserPerDay = 20;
/**
 * Walked tiles a place needs before it's researched: about 250 m of walking, so a
 * GPS wobble over the border of a place you added doesn't start a paid run. What the
 * phone says, so the server also looks for the walk itself (walkCheck).
 */
export const minWalkedTiles = 3;
/** Square metres, the same as the phones' AutoPlaces.minArea and CityBuilder.maxArea. */
export const suburbArea = { min: 100_000, max: 400_000_000 };
/**
 * A suburb is only walked in if one of the person's saved walks has this many good
 * GPS fixes inside its boundary. Only their newest walks are read.
 */
export const walkCheck = { minPoints: 3, maxAccuracy: 65, walks: 20 };
/** A place a walk queued that hasn't started after this leaves the queue. */
export const queueExpiry = 30 * 24 * 60 * 60 * 1000;

/** How many secrets a run aims for. Fewer than `enough` survive and the place is "quiet". */
export const entries = { enough: 3, most: 8 };
export const day = 24 * 60 * 60 * 1000;
/** A quiet place gets one more look after this, in case more has been written about it. */
export const quietRetry = 90 * day;
/** A run that broke gets another go after this, up to `maxAttempts` runs in all. */
export const failedRetry = day;
export const maxAttempts = 2;

/**
 * How long each step's action may take. Convex runtime actions are stopped at 30
 * minutes and Node ones (loreStickers.ts) at 10 (docs.convex.dev/production/state/limits,
 * checked 2026-10-25), so each stops itself well short of that.
 */
export const timeLimits = {
  /** The model call writing the secrets, retries and all. */
  write: 10 * 60 * 1000,
  /** Reading every page the secrets cite. */
  quotes: 8 * 60 * 1000,
  /** Starting new fact-checks; ones under way finish, and a retried step skips what's done. */
  factCheck: 12 * 60 * 1000,
  /** One model call in the fact-check. */
  check: 3 * 60 * 1000,
  /** One sticker drawing, in a Node action. */
  sticker: 3 * 60 * 1000,
};

/** A finished run's journal is kept this long for lore:resume, then deleted. */
export const journalKeep = 14 * 24 * 60 * 60 * 1000;

export const research = {
  /** Each research angle stops after this many model calls... */
  maxSteps: 22,
  /** ...or this many saved notes... */
  maxNotes: 14,
  /** ...or this much spend, or once it's been going this long... */
  maxSpend: 0.9,
  maxTime: 12 * 60 * 1000,
  /** ...and a model call still going at this point is stopped, keeping the notes. */
  hardTime: 20 * 60 * 1000,
  /**
   * Most a research step can write. OpenRouter turns a call away unless the key can
   * afford its maximum, and the default (64k tokens) needs far more credit than a step uses.
   */
  outputTokens: 8000,
  /** Characters of a page the model gets per fetch. About 3,000 tokens. */
  pageChars: 12_000,
  /** Pages an agent keeps to check its quotes against; the oldest goes first. */
  pagesKept: 12,
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

/**
 * Wikipedia and sites anyone can write on are good for leads, not sources. A claim
 * citing one only counts when the same secret has another claim from a different site
 * that isn't one of these (loreChecks.leadOnly).
 */
export const leadOnlySources = [
  "wikipedia.org", "wikimedia.org", "wikidata.org", "wikivoyage.org", "wikitravel.org", "fandom.com",
  "reddit.com", "quora.com", "facebook.com", "instagram.com", "twitter.com", "x.com", "tiktok.com", "pinterest.com",
  "youtube.com", "medium.com", "substack.com", "blogspot.com", "wordpress.com", "tumblr.com", "tripadvisor.com",
  "tripadvisor.com.au", "tripadvisor.co.uk", "yelp.com", "findagrave.com", "ancestry.com", "geni.com", "wikitree.com",
];

/** Two of the bundled stickers, served by the website, so new art matches the old. */
export const stickerReferences = [
  "https://walkies.mikecann.app/img/sticker-a-piano-on-a-truck.png",
  "https://walkies.mikecann.app/img/sticker-a-rest-stop-for-whales.png",
];
