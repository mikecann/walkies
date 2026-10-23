import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

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
});
