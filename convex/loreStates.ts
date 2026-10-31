// The states of a suburb's research (lorePlaces.state) and of each secret a run
// writes (loreEntries.state), for the machines in loreMachines.ts. Each state holds
// only its own data, so a place can't be researching without its workflow, or failed
// without its error. docs/machines.md draws them.
import { v, type Infer } from "convex/values";

const ready = v.object({ kind: v.literal("ready"), startedAt: v.number(), finishedAt: v.number() });
const quiet = v.object({ kind: v.literal("quiet"), startedAt: v.number(), finishedAt: v.number() });
const failed = v.object({ kind: v.literal("failed"), startedAt: v.number(), finishedAt: v.number(), error: v.string() });

/** Where a finished place goes back to if it's queued again and the wait runs out, or a resume can't start. */
export const vFinished = v.union(ready, quiet, failed);

export const lorePlaceState = v.union(
  /** Waiting for a slot and the caps. `manual`: asked for with lore:research or lore:resume rather
   * than by someone's walk, so it runs with LORE_AUTO off. `requestedBy`: whose walk queued it, so
   * the queue takes turns between people. `resume`: the step lore:resume restarts its journal from.
   * `was`: what it was before it was queued again. `nearby`: queued by lore:prepare for being next
   * to where someone is, rather than walked in, so it waits behind places people have walked. */
  v.object({
    kind: v.literal("queued"),
    queuedAt: v.number(),
    manual: v.boolean(),
    requestedBy: v.optional(v.id("users")),
    resume: v.optional(v.string()),
    was: v.optional(vFinished),
    nearby: v.optional(v.boolean()),
  }),
  v.object({
    kind: v.literal("researching"),
    manual: v.boolean(),
    requestedBy: v.optional(v.id("users")),
    startedAt: v.number(),
    workflowId: v.string(),
  }),
  ready,
  /** Quiet after its first run: it gets one more look at `retryAt`. */
  v.object({ kind: v.literal("quietWaiting"), startedAt: v.number(), finishedAt: v.number(), retryAt: v.number() }),
  quiet,
  /** A run that broke, under budget and runs: it goes back on the queue at `retryAt`. */
  v.object({ kind: v.literal("failedWaiting"), startedAt: v.number(), finishedAt: v.number(), error: v.string(), retryAt: v.number() }),
  failed,
  /** A walk queued it and it never started in `queueExpiry`: as if nobody had walked there. */
  v.object({ kind: v.literal("expired"), expiredAt: v.number() }),
);
export type LorePlaceState = Infer<typeof lorePlaceState>;

export const loreEntryState = v.union(
  /** In the pipeline: written, being checked. */
  v.object({ kind: v.literal("checking") }),
  /** Taken out, `by` the check that did it. "run stopped", "budget" and "not checked" weren't the
   * secret's fault, so lore:resume brings those back. */
  v.object({ kind: v.literal("dropped"), by: v.string() }),
  /** Live. */
  v.object({ kind: v.literal("auto") }),
  /** Sensitive, so waiting for Mike. */
  v.object({ kind: v.literal("pending") }),
  v.object({ kind: v.literal("approved") }),
  v.object({ kind: v.literal("hidden") }),
);
export type LoreEntryState = Infer<typeof loreEntryState>;

/** A secret's state as adminPending and lore:entries have always named it. */
export const vLoreReview = v.union(
  v.literal("checking"), v.literal("dropped"), v.literal("auto"), v.literal("pending"), v.literal("approved"), v.literal("hidden"),
);

/** What forPlace tells the phones. They only know these words, so the waiting states say what they
 * are underneath, and an expired place is one nobody has walked. */
export function clientStatus(state: LorePlaceState): "none" | "queued" | "researching" | "ready" | "quiet" | "failed" {
  if (state.kind === "quietWaiting") return "quiet";
  if (state.kind === "failedWaiting") return "failed";
  if (state.kind === "expired") return "none";
  return state.kind;
}
