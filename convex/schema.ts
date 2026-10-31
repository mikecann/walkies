import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { machineTimers } from "@convex-dev/state-machines";
import { loreEntryState, lorePlaceState } from "./loreStates";

// The server keeps a copy of what each phone has. The phone is the source of truth
// and works offline; it pushes what it has whenever it can. Nothing here is ever
// edited in a way that can conflict: walks never change once finished, tiles only
// get uncovered and secrets only get found, so syncing is just adding.
export default defineSchema({
  users: defineTable({
    name: v.optional(v.string()),
    /** From Apple or Google, for reaching people later. Apple's can be a private relay address. */
    email: v.optional(v.string()),
    emailVerified: v.optional(v.boolean()),
    picture: v.optional(v.string()),
    /**
     * Set on a duplicate made by signing in another way before sign-ins were
     * linked by email. Everything treats it as this other user instead.
     */
    mergedInto: v.optional(v.id("users")),
    /**
     * Set when the account was deleted (users:deleteAccount). The row stays as an empty
     * tombstone, so Convex Auth's sign-ins that still point at it count as signed out.
     */
    deletedAt: v.optional(v.number()),
  }).index("by_email", ["email"]).index("by_mergedInto", ["mergedInto"]),

  /**
   * A deleted account's data going, a batch at a time. Each step records how far it
   * got, so an interrupted one picks up where it left off (accountDeletion.ts).
   */
  accountDeletions: defineTable({
    userId: v.id("users"),
    requestedAt: v.number(),
    /** The table being emptied now (`accountDeletion.STAGES`), or "done". */
    stage: v.string(),
    /** Full passes over every stage; another runs if rows turned up behind it. */
    passes: v.number(),
    deletedRows: v.number(),
    lastStepAt: v.number(),
    finishedAt: v.optional(v.number()),
  }).index("by_user", ["userId"]).index("by_finishedAt_lastStepAt", ["finishedAt", "lastStepAt"]),

  walks: defineTable({
    userId: v.id("users"),
    /** The walk's id on the phone. */
    clientId: v.string(),
    startedAt: v.number(),
    endedAt: v.number(),
    distance: v.number(),
    newTiles: v.number(),
    /** The walk exactly as the app saves it, GPS points and all. */
    file: v.id("_storage"),
  }).index("by_user_client", ["userId", "clientId"]),

  places: defineTable({
    userId: v.id("users"),
    clientId: v.string(),
    name: v.string(),
    createdAt: v.number(),
    /** When the phone last changed it. The newest copy wins. */
    updatedAt: v.number(),
    /** The city as the app saves it: boundary, tiles, streets and secret spots. */
    file: v.id("_storage"),
    /** Its OSM relation, read from the file by lore.readPlace. Unset until then. */
    osmId: v.optional(v.number()),
    /** Tiles walked in it, from the same file. What the phone says, so only a first filter. */
    walkedTiles: v.optional(v.number()),
    /** lore.readPlace found its relation isn't a suburb-sized admin boundary, so it's never researched. */
    loreNoSuburb: v.optional(v.boolean()),
  }).index("by_user_client", ["userId", "clientId"]),

  progress: defineTable({
    userId: v.id("users"),
    /** The append-only spending and reward ledger, encoded by the phone. */
    ledger: v.string(),
    updatedAt: v.number(),
  }).index("by_user", ["userId"]),

  secrets: defineTable({
    userId: v.id("users"),
    secretId: v.string(),
    foundAt: v.number(),
  }).index("by_user_secret", ["userId", "secretId"]),

  teams: defineTable({
    name: v.string(),
    createdBy: v.id("users"),
    inviteCode: v.string(),
    inviteEpoch: v.optional(v.number()),
    createdAt: v.number(),
  }).index("by_invite", ["inviteCode"]).index("by_creator", ["createdBy"]),

  teamMembers: defineTable({
    teamId: v.id("teams"),
    userId: v.id("users"),
    name: v.string(),
    colour: v.string(),
    joinedAt: v.number(),
  }).index("by_team_user", ["teamId", "userId"])
    .index("by_user", ["userId"]),

  // Removal records survive automatic rotations. Only an explicit fresh invite
  // invalidates them, so removing a second person cannot unblock the first.
  teamRemovals: defineTable({ teamId: v.id("teams"), userId: v.id("users"), epoch: v.number() })
    .index("by_team_user", ["teamId", "userId"]).index("by_user", ["userId"]),

  teamInviteAttempts: defineTable({ userId: v.id("users"), windowStart: v.number(), count: v.number() })
    .index("by_user", ["userId"]),

  // Calls to places:get and places:warm in the current minute, per user.
  placeCalls: defineTable({ userId: v.id("users"), windowStart: v.number(), count: v.number() })
    .index("by_user", ["userId"]),

  // Shared OSM data. Missing files are short-lived fetching markers; osmId 0
  // is the shared Nominatim throttle, so every server request observes its limit,
  // and osmId -2 is the one Overpass slot every street fetch takes turns with.
  placeData: defineTable({
    osmId: v.number(),
    name: v.string(),
    fetchedAt: v.number(),
    version: v.number(),
    file: v.optional(v.id("_storage")),
    fetchingAt: v.optional(v.number()),
    /** Waiting for the warm queue, which fetches one place at a time from this time on. */
    queuedAt: v.optional(v.number()),
    /** Failed warm attempts so far, for backing off. */
    attempts: v.optional(v.number()),
  }).index("by_osm", ["osmId"]).index("by_queued", ["queuedAt"]),

  // Secrets for new suburbs (lore.ts). One row per suburb that's been researched or is
  // waiting to be, shared by everyone, keyed by OSM relation like placeData.
  lorePlaces: defineTable({
    osmId: v.number(),
    name: v.string(),
    /** Where its research is: queued, researching, then ready, quiet or failed, perhaps waiting for
     * another look (loreStates.ts, loreMachines.ts). Only the lorePlace machine changes it. */
    state: lorePlaceState,
    /** The machine's pending timers: the queue's expiry and the retries. */
    stateTimers: machineTimers,
    /** Bumped whenever the live secrets change, so the phones know to fetch them again. */
    version: v.number(),
    /** Budget segments so far: each start or resume gets its own caps.perRun (runCost). */
    segment: v.number(),
    /** From Nominatim when the run starts: "Porlock, Somerset, England, United Kingdom",
     * "England" and "gb". */
    // eslint-disable-next-line machines/no-optional-on-machine-tables -- the run's first step reads it from Nominatim, and it stays the same in every state after
    displayName: v.optional(v.string()),
    // eslint-disable-next-line machines/no-optional-on-machine-tables -- as displayName
    region: v.optional(v.string()),
    // eslint-disable-next-line machines/no-optional-on-machine-tables -- as displayName
    country: v.optional(v.string()),
    /** Runs so far. Each run's entries and notes carry its number. */
    attempts: v.number(),
    /** US dollars from OpenRouter, for every run and for this budget segment, counting
     * holds on calls still going at their most (loreRun.reserve). */
    cost: v.number(),
    runCost: v.number(),
  }).index("by_osm", ["osmId"]).index("by_state", ["state.kind", "state.queuedAt"])
    .index("by_requester", ["state.requestedBy"]),

  // A finished run's workflow journal, kept for `journalKeep` so lore:resume can restart it
  // from a step. lore.tick deletes old ones, and a new run or a resume takes its place's.
  loreJournals: defineTable({ osmId: v.number(), run: v.number(), workflowId: v.string(), until: v.number() })
    .index("by_osm", ["osmId"]).index("by_until", ["until"]),

  // What the research agents found, one fact per row with the page and the exact words.
  loreNotes: defineTable({
    osmId: v.number(),
    run: v.number(),
    angle: v.string(),
    fact: v.string(),
    url: v.string(),
    quote: v.string(),
    spot: v.optional(v.object({ name: v.string(), lat: v.optional(v.number()), lon: v.optional(v.number()) })),
  }).index("by_osm_run", ["osmId", "run"]),

  // Every secret a run wrote, including the ones the checks dropped, with why.
  loreEntries: defineTable({
    osmId: v.number(),
    run: v.number(),
    /** `osm<relation>-<slug>`, so it can never clash with a bundled secret's id. */
    entryId: v.string(),
    title: v.string(),
    body: v.string(),
    category: v.string(),
    // eslint-disable-next-line machines/no-optional-on-machine-tables -- the writer's pin, which a check can remove in any state, so the story is scattered instead
    place: v.optional(v.object({ name: v.string(), lat: v.number(), lon: v.number() })),
    /** What the sticker shows. */
    sticker: v.string(),
    sources: v.array(v.string()),
    suburb: v.string(),
    claims: v.array(v.object({
      text: v.string(),
      url: v.string(),
      quote: v.string(),
      /** Set by the quote check: the words are on the page. */
      // eslint-disable-next-line machines/no-optional-on-machine-tables -- one claim's quote-check result, unset until the check has read its page, whatever the secret's state
      found: v.optional(v.boolean()),
      /** The page text around the quote, for the fact-checker. */
      // eslint-disable-next-line machines/no-optional-on-machine-tables -- as found: the quote check's, for a claim whose page it read
      context: v.optional(v.string()),
    })),
    /** Why it waits for Mike: "first-nations", "death-or-crime", "living-people". */
    sensitive: v.array(v.string()),
    /** checking (in the pipeline), dropped, then auto (live), pending, approved or hidden
     * (loreStates.ts). Only the loreEntry machine changes it. */
    state: loreEntryState,
    /** The fact-check has passed it (perhaps after revising), so a retried check skips it.
     * A secret is never published without this. */
    factChecked: v.boolean(),
    /** What each check found or changed, in plain words. */
    checkNotes: v.array(v.string()),
    // eslint-disable-next-line machines/no-optional-on-machine-tables -- drawn near the end of a run, or later by lore:resume from "stickers", and some secrets never get one
    stickerFile: v.optional(v.id("_storage")),
  }).index("by_osm_review", ["osmId", "state.kind"]).index("by_review", ["state.kind"]).index("by_entry", ["entryId"])
    .index("by_osm_run", ["osmId", "run"]),

  // OpenRouter spend in US dollars, by UTC day, place and step, for the caps. `cost`
  // includes `held`: holds on calls still going, at the most each could cost.
  loreSpend: defineTable({
    day: v.string(), osmId: v.number(), step: v.string(), cost: v.number(), calls: v.number(),
    held: v.optional(v.number()),
    /** Holds kept as spent because the call's real cost never came back. Part of `cost`. */
    unpriced: v.optional(v.number()),
  }).index("by_day", ["day", "osmId", "step"]),

  // One hold per paid call in flight (loreRun.reserve), settled to the real cost after.
  loreHolds: defineTable({
    osmId: v.number(), day: v.string(), step: v.string(), amount: v.number(),
    /** The place's budget segment when it was booked, so a late settle never touches a newer one's runCost. */
    segment: v.number(),
    at: v.number(),
  }).index("by_at", ["at"]),

  // Eligibility checks each person's places took today (lore.readPlace), for checksPerUserPerDay.
  loreCalls: defineTable({ userId: v.id("users"), windowStart: v.number(), count: v.number() })
    .index("by_user", ["userId"]),

  // Each new suburb someone's walk queued, for the per-person day and month limits.
  loreRequests: defineTable({ userId: v.id("users"), osmId: v.number(), at: v.number() })
    .index("by_user_at", ["userId", "at"]).index("by_at", ["at"]),

  // Each suburb lore:prepare queued for being next to where someone's been, which has limits of its own.
  loreNearbyRequests: defineTable({ userId: v.id("users"), osmId: v.number(), at: v.number() })
    .index("by_user_at", ["userId", "at"]).index("by_at", ["at"]),

  // The research agents' threads (every search and page they read), deleted when the run finishes.
  loreThreads: defineTable({ osmId: v.number(), run: v.number(), threadId: v.string() })
    .index("by_osm_run", ["osmId", "run"]),
});
