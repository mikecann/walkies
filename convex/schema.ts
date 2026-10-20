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
  }).index("by_email", ["email"]),

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
    /** Monotonic server time for tile uploads, also used as the snapshot cursor. */
    tilesUpdatedAt: v.number(),
  }).index("by_invite", ["inviteCode"]).index("by_creator", ["createdBy"]),

  teamMembers: defineTable({
    teamId: v.id("teams"),
    userId: v.id("users"),
    name: v.string(),
    colour: v.string(),
    sharing: v.union(v.literal("tiles"), v.literal("tilesAndTrail")),
    walksCount: v.boolean(),
    joinedAt: v.number(),
    trailEpoch: v.optional(v.number()),
  }).index("by_team_user", ["teamId", "userId"])
    .index("by_user", ["userId"]),

  teamPlaces: defineTable({
    teamId: v.id("teams"),
    clientId: v.string(),
    name: v.string(),
    /** Dedicated team JSON: shared grid, boundary and streets, no personal progress. */
    file: v.id("_storage"),
    addedBy: v.id("users"),
    updatedAt: v.number(),
    bounds: v.optional(v.object({ minQ: v.number(), maxQ: v.number(), minR: v.number(), maxR: v.number() })),
    tileCount: v.optional(v.number()),
  }).index("by_team_client", ["teamId", "clientId"]).index("by_added", ["addedBy"]),

  teamTiles: defineTable({
    teamId: v.id("teams"),
    placeId: v.id("teamPlaces"),
    q: v.number(),
    r: v.number(),
    by: v.id("users"),
    /** Phone's discovery time, including walks replayed from before joining. */
    at: v.number(),
    /** Server ingestion time; an old walk must still appear in the next delta. */
    receivedAt: v.number(),
  }).index("by_team_place_hex", ["teamId", "placeId", "q", "r"])
    .index("by_team_received", ["teamId", "receivedAt"]).index("by_user", ["by"]),

  teamTrails: defineTable({
    teamId: v.id("teams"),
    userId: v.id("users"),
    walkClientId: v.string(),
    /** Dedicated upload, already clipped by the phone to this team's places. */
    file: v.id("_storage"),
    at: v.number(),
    updatedAt: v.optional(v.number()),
    memberId: v.optional(v.id("teamMembers")),
    epoch: v.optional(v.number()),
  }).index("by_team_user_walk", ["teamId", "userId", "walkClientId"])
    .index("by_user", ["userId"])
    .index("by_cleanup", ["teamId", "userId", "memberId", "epoch"]),

  teamSecrets: defineTable({
    teamId: v.id("teams"),
    secretId: v.string(),
    by: v.id("users"),
    at: v.number(),
  }).index("by_team_secret", ["teamId", "secretId"]).index("by_user", ["by"]),

  // Removal records survive automatic rotations. Only an explicit fresh invite
  // invalidates them, so removing a second person cannot unblock the first.
  teamRemovals: defineTable({ teamId: v.id("teams"), userId: v.id("users"), epoch: v.number() })
    .index("by_team_user", ["teamId", "userId"]).index("by_user", ["userId"]),

  teamInviteAttempts: defineTable({ userId: v.id("users"), windowStart: v.number(), count: v.number() })
    .index("by_user", ["userId"]),

  // Only the server's upload action can register ownership, never a client
  // claiming an arbitrary storage ID. Each file can be consumed once.
  teamUploads: defineTable({ file: v.id("_storage"), userId: v.id("users"), used: v.boolean() })
    .index("by_file", ["file"]).index("by_user", ["userId"]),

  // Shared OSM data. Missing files are short-lived fetching markers; osmId 0
  // is the shared Nominatim throttle, so every server request observes its limit.
  placeData: defineTable({
    osmId: v.number(),
    name: v.string(),
    fetchedAt: v.number(),
    version: v.number(),
    file: v.optional(v.id("_storage")),
    fetchingAt: v.optional(v.number()),
  }).index("by_osm", ["osmId"]),
});
