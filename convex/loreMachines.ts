// The research lifecycles as state machines, on @convex-dev/state-machines: a suburb's
// (lorePlace, on lorePlaces.state) and each secret's (loreEntry, on loreEntries.state).
// The rules are the first argument and the code behind their names the second, and
// docs/machines.md is drawn from the same rules (`npm run diagrams`). lore.ts and
// loreRun.ts send the events; the queue's expiry and the retries are timers here.
// Import the machines from ./machines, which loads the catalog that sending needs.
import { defineMachine, type AppCtx } from "@convex-dev/state-machines";
import type { GenericDatabaseReader } from "convex/server";
import { v } from "convex/values";
import type { DataModel, Doc, Id } from "./_generated/dataModel";
import { env, type MutationCtx } from "./_generated/server";
import { overBudget } from "./loreBudget";
import { day, entries as wanted, failedRetry, maxAttempts, queueExpiry, quietRetry, reviewSensitive } from "./loreConfig";
import type { LorePlaceState } from "./loreStates";
import schema from "./schema";

/** The switch. Off unless LORE_AUTO is exactly "1", so a deployment only starts paid runs by itself when it's switched on. */
export const autoOn = () => env.LORE_AUTO === "1";

type Reader = { db: GenericDatabaseReader<DataModel> };

export async function placeRow(ctx: Reader, osmId: number) {
  return await ctx.db.query("lorePlaces").withIndex("by_osm", (q) => q.eq("osmId", osmId)).unique();
}

/** The journal of the place's latest run, if it's still kept (lore:resume needs it). */
export async function journalOf(ctx: Reader, place: Doc<"lorePlaces">) {
  const journals = await ctx.db.query("loreJournals").withIndex("by_osm", (q) => q.eq("osmId", place.osmId)).collect();
  return journals.find((journal) => journal.run === place.attempts) ?? null;
}

/** The live secrets changed, so the phones should fetch them again. */
export async function bumpVersion(ctx: { db: AppCtx<DataModel>["db"] }, osmId: number) {
  const row = await placeRow(ctx, osmId);
  if (row) await ctx.db.patch("lorePlaces", row._id, { version: row.version + 1 });
}

/** Deletes a secret's sticker file, for one that's dropped, hidden or replaced. */
export async function deleteSticker(ctx: Reader & Pick<MutationCtx, "storage">, entry: Doc<"loreEntries">) {
  if (entry.stickerFile && await ctx.db.system.get("_storage", entry.stickerFile)) await ctx.storage.delete(entry.stickerFile);
}

/** Secrets dropped for reasons that weren't theirs, which lore:resume brings back. */
export const notTheirFault = ["run stopped", "budget", "not checked"];

/** A finished state as it's kept in `queued.was`: the waiting ones without their retry. */
function finished(state: LorePlaceState & { kind: "ready" | "quiet" | "failed" | "quietWaiting" | "failedWaiting" }) {
  if (state.kind === "failed" || state.kind === "failedWaiting") {
    return { kind: "failed" as const, startedAt: state.startedAt, finishedAt: state.finishedAt, error: state.error };
  }
  return { kind: state.kind === "ready" ? "ready" as const : "quiet" as const, startedAt: state.startedAt, finishedAt: state.finishedAt };
}

const stopped = { machine: "loreEntry", event: "RUN_STOPPED", onRefused: "ignore" } as const;
const broughtBack = { machine: "loreEntry", event: "BROUGHT_BACK", onRefused: "ignore" } as const;

// A finished place can be queued again (a walk after it expired, lore:research) or
// resumed from a step of its journal (lore:resume), from wherever it finished.
const reopen = {
  QUEUE: {
    to: "queued", effect: "requeue",
    description: "Mike asks for a fresh run of the finished place, so it goes back on the queue, remembering how it finished.",
  },
  RESUME: {
    to: "queued", guard: "hasJournal", effect: "resume", sends: [broughtBack],
    description: "Mike reruns the last run from one of its steps, keeping what the steps before found; secrets dropped through no fault of their own come back.",
  },
} as const;
const waiting = {
  timers: {
    RETRY_DUE: { at: "retryAt", description: "The wait for another look is over: 90 days after a quiet first run, or a day after a run that broke." },
  },
  on: {
    ...reopen,
    RETRY_DUE: [
      { to: "queued", guard: "autoOn", effect: "retry", description: "The retry is due and automatic research is switched on, so it goes back on the queue by itself." },
      { effect: "postpone", description: "The retry is due but automatic research is switched off, so it waits another day and asks again." },
    ],
  },
} as const;

export const lorePlace = defineMachine(
  schema,
  {
    name: "lorePlace",
    table: "lorePlaces",
    description: "A suburb's research for its secrets (short local stories): queued by a walk or by Mike, researched by a paid run of models, then ready, quiet or failed.",
    events: {
      server: {
        // A walk (lore.noteWalked) or Mike (lore:research) puts it on the queue.
        QUEUE: { manual: v.boolean(), requestedBy: v.optional(v.id("users")), nearby: v.optional(v.boolean()) },
        // The queue (lore.startQueued) started its workflow, or restarted its journal for a resume.
        START: { workflowId: v.string() },
        RESUMED: { workflowId: v.string() },
        RESUME_FAILED: { error: v.string() },
        // lore:resume, from a step of the last run's journal.
        RESUME: { from: v.string() },
        // The person whose walk queued it deleted their account.
        FORGET_REQUESTER: {},
        // The run's last step (loreRun.publish), and its workflow ending any other way (lore.runFinished).
        PUBLISHED: { run: v.number() },
        RUN_FAILED: { run: v.number(), error: v.string() },
      },
    },
    guards: {
      currentRun: "That report is from an earlier run of this place.",
      enough: `Fewer than ${wanted.enough} secrets came out of it.`,
      firstQuiet: "It's been quiet before, so it doesn't get another look.",
      canRetry: `It stopped at its spending limit, or it has had ${maxAttempts} runs.`,
      autoOn: "LORE_AUTO is off, so nothing goes back on the queue by itself.",
      notManual: "Mike asked for it, so it waits for as long as it takes.",
      wasReady: "It wasn't ready before it was queued.",
      wasQuiet: "It wasn't quiet before it was queued.",
      wasFailed: "It hadn't failed before it was queued.",
      neverRan: "It has been researched before.",
      isResume: "It was queued for a new run, not a resume.",
      notResume: "It was queued to resume a run.",
      hasJournal: "The last run's journal has been deleted, so it can't be resumed.",
    },
    states: {
      start: {
        on: {
          QUEUE: {
            to: "queued", effect: "enqueue",
            description: "Someone walks in a suburb with no secrets yet, or is near one, or Mike asks for it, so it joins the queue for research.",
          },
        },
      },
      queued: {
        description: "Waiting for a free research slot and room under the spending caps; Mike's asks go first, then walked places, then ones only nearby.",
        timers: {
          QUEUE_EXPIRED: {
            after: queueExpiry,
            description: "A month has passed without its run starting; this only counts when Mike didn't ask for it, as his own asks wait as long as it takes.",
          },
        },
        on: {
          QUEUE: { effect: "merge", description: "Asked for again while it waits: it keeps its place in the queue, and moves up if Mike asks or someone walks there." },
          FORGET_REQUESTER: { effect: "forget", description: "The person whose walk queued it deleted their account, so it forgets who asked and stays queued." },
          START: {
            to: "researching", guard: "notResume", effect: "start",
            description: "A slot is free and the caps allow it, so a new research run starts with a spending limit of its own.",
          },
          RESUMED: {
            to: "researching", guard: "isResume", effect: "resumed",
            description: "A slot is free and the caps allow it, so the last run restarts from the step Mike chose, with a fresh spending limit.",
          },
          RESUME_FAILED: [
            { to: "ready", guard: "wasReady", effect: "restore", description: "The last run couldn't be restarted, so it goes back to being ready, as it was." },
            { to: "quiet", guard: "wasQuiet", effect: "restore", description: "The last run couldn't be restarted, so it goes back to being quiet, as it was." },
            { to: "failed", guard: "wasFailed", effect: "restore", description: "The last run couldn't be restarted, so it goes back to having failed, as it was." },
          ],
          QUEUE_EXPIRED: [
            {
              to: "ready", guard: ["notManual", "wasReady"], effect: "restore",
              description: "A month on the queue without starting, so it goes back to being ready, as it was.",
            },
            {
              to: "quiet", guard: ["notManual", "wasQuiet"], effect: "restore",
              description: "A month on the queue without starting, so it goes back to being quiet, as it was.",
            },
            {
              to: "failed", guard: ["notManual", "wasFailed"], effect: "restore",
              description: "A month on the queue without starting, so it goes back to having failed, as it was.",
            },
            {
              to: "expired", guard: ["notManual", "neverRan"], effect: "expire",
              description: "A walk queued it and its first run never started, so it's as if nobody had walked there.",
            },
          ],
        },
      },
      researching: {
        description: "A paid research run is under way: models look into the suburb, write its secrets, fact-check them and draw their stickers.",
        on: {
          FORGET_REQUESTER: { effect: "forget", description: "The person whose walk queued it deleted their account, so it forgets who asked and keeps researching." },
          PUBLISHED: [
            {
              to: "ready", guard: ["currentRun", "enough"], effect: "finish",
              description: `The run published, and the suburb has at least ${wanted.enough} secrets kept, so it's ready.`,
            },
            {
              to: "quietWaiting", guard: ["currentRun", "firstQuiet"], effect: "quietAgainLater",
              description: "Its first run found too few secrets, so it's quiet for now and gets one more look in 90 days.",
            },
            { to: "quiet", guard: "currentRun", effect: "finish", description: "A later run found too few secrets, so it stays quiet with no more looks planned." },
          ],
          // A run stopped at its spending limit would only spend it again, so Mike decides.
          RUN_FAILED: [
            {
              to: "failedWaiting", guard: ["currentRun", "canRetry"], effect: "failAndRetry", sends: [stopped],
              description: "The run broke, not on a spending cap, and has a run to spare, so it tries again in a day; its secrets still being checked are dropped.",
            },
            {
              to: "failed", guard: "currentRun", effect: "fail", sends: [stopped],
              description: "The run hit a spending cap, or broke on its last allowed run, so it waits for Mike; its secrets still being checked are dropped.",
            },
          ],
        },
      },
      ready: { description: "Researched, with enough secrets kept; the live ones show on people's phones.", on: reopen },
      quietWaiting: {
        description: "Its first run found too few secrets; it gets one more look after 90 days, in case more has been written about it.",
        ...waiting,
      },
      quiet: { description: "Not much to find: its runs found too few secrets, and whatever they found still shows.", on: reopen },
      failedWaiting: {
        description: "Its run broke, not on a spending cap, and it has a run left, so it goes back on the queue after a day.",
        ...waiting,
      },
      failed: {
        description: "Its run broke and won't be tried again by itself, as it hit a spending cap or used all its runs; Mike decides what next.",
        on: reopen,
      },
      expired: {
        description: "A walk queued it and it never started within a month, so it's as if nobody had walked there; the next walk can queue it again.",
        on: {
          QUEUE: { to: "queued", effect: "enqueue", description: "Someone walks there again, or Mike asks for it, so it joins the queue afresh." },
        },
      },
    },
  },
  {
    guards: {
      // A workflow that finishes after its place moved on to another run can't touch it.
      currentRun: (_ctx, { row, event }) => event.run === row.attempts,
      enough: async (ctx, { row }) => {
        let kept = 0;
        for (const kind of ["auto", "approved", "pending"] as const) {
          kept += (await ctx.db.query("loreEntries").withIndex("by_osm_review", (q) => q.eq("osmId", row.osmId).eq("state.kind", kind)).collect()).length;
        }
        return kept >= wanted.enough;
      },
      firstQuiet: (_ctx, { row }) => row.attempts < 2,
      canRetry: (_ctx, { row, event }) => !event.error.includes(overBudget) && row.attempts < maxAttempts,
      autoOn: () => autoOn(),
      notManual: (_ctx, { state }) => !state.manual,
      wasReady: (_ctx, { state }) => state.was?.kind === "ready",
      wasQuiet: (_ctx, { state }) => state.was?.kind === "quiet",
      wasFailed: (_ctx, { state }) => state.was?.kind === "failed",
      neverRan: (_ctx, { row }) => row.attempts === 0,
      isResume: (_ctx, { state }) => state.resume !== undefined,
      notResume: (_ctx, { state }) => state.resume === undefined,
      hasJournal: async (ctx, { row }) => await journalOf(ctx, row) !== null,
    },
    effects: {
      enqueue: async (_ctx, { event }) => ({
        kind: "queued", queuedAt: Date.now(), manual: event.manual, ...(event.requestedBy ? { requestedBy: event.requestedBy } : {}),
        ...(event.nearby ? { nearby: true } : {}),
      }),
      requeue: async (_ctx, { state, event }) => ({
        kind: "queued", queuedAt: Date.now(), manual: event.manual, ...(event.requestedBy ? { requestedBy: event.requestedBy } : {}), was: finished(state),
        ...(event.nearby ? { nearby: true } : {}),
      }),
      retry: async (_ctx, { state }) => ({ kind: "queued", queuedAt: Date.now(), manual: false, was: finished(state) }),
      postpone: async (_ctx, { state }) => ({ ...state, retryAt: Date.now() + day }),
      resume: async (_ctx, { state, event }) => ({ kind: "queued", queuedAt: Date.now(), manual: true, resume: event.from, was: finished(state) }),
      // Asked for again while it waits: Mike asking makes it his, and it keeps its place in the queue.
      // Someone walking into a place that was only queued for being nearby moves it up.
      merge: async (_ctx, { state, event }) => {
        const { nearby: _was, ...rest } = state;
        return {
          ...rest, manual: state.manual || event.manual, ...(state.requestedBy ?? event.requestedBy ? { requestedBy: state.requestedBy ?? event.requestedBy } : {}),
          ...(state.nearby && event.nearby ? { nearby: true } : {}),
        };
      },
      forget: async (_ctx, { state }) => {
        const { requestedBy: _forgotten, ...rest } = state;
        return rest;
      },
      // A new run: the next run number, and a budget segment of its own.
      start: async (ctx, { id, row, state, event }) => {
        await ctx.db.patch("lorePlaces", id, { attempts: row.attempts + 1, runCost: 0, segment: row.segment + 1 });
        return {
          kind: "researching", manual: state.manual, ...(state.requestedBy ? { requestedBy: state.requestedBy } : {}),
          startedAt: Date.now(), workflowId: event.workflowId,
        };
      },
      // The same run again, from a step of its journal, with a budget segment of its own.
      resumed: async (ctx, { id, row, state, event }) => {
        await ctx.db.patch("lorePlaces", id, { runCost: 0, segment: row.segment + 1 });
        return {
          kind: "researching", manual: state.manual, ...(state.requestedBy ? { requestedBy: state.requestedBy } : {}),
          startedAt: Date.now(), workflowId: event.workflowId,
        };
      },
      restore: async (_ctx, { state, to }) => {
        if (state.was?.kind !== to) throw new Error(`lorePlace: restoring ${to}, but it was ${state.was?.kind ?? "nothing"}`);
        return state.was;
      },
      expire: async () => ({ kind: "expired", expiredAt: Date.now() }),
      finish: async (_ctx, { state, to }) => ({ kind: to, startedAt: state.startedAt, finishedAt: Date.now() }),
      quietAgainLater: async (_ctx, { state }) => ({
        kind: "quietWaiting", startedAt: state.startedAt, finishedAt: Date.now(), retryAt: Date.now() + quietRetry,
      }),
      failAndRetry: async (_ctx, { state, event }) => ({
        kind: "failedWaiting", startedAt: state.startedAt, finishedAt: Date.now(), error: event.error.slice(0, 500), retryAt: Date.now() + failedRetry,
      }),
      fail: async (_ctx, { state, event }) => ({ kind: "failed", startedAt: state.startedAt, finishedAt: Date.now(), error: event.error.slice(0, 500) }),
    },
    links: {
      // The run's secrets still in the pipeline. Its other ones are already decided.
      "loreEntry.RUN_STOPPED": async ({ db, row, event }) => (await runEntries(db, row.osmId, event.run)).filter((e) => e.state.kind === "checking").map((e) => e._id),
      // The run's dropped secrets. The entry's notTheirFault guard picks the ones that come back.
      "loreEntry.BROUGHT_BACK": async ({ db, row }) => (await runEntries(db, row.osmId, row.attempts)).filter((e) => e.state.kind === "dropped").map((e) => e._id),
    },
  },
);

async function runEntries(db: GenericDatabaseReader<DataModel>, osmId: number, run: number) {
  return await db.query("loreEntries").withIndex("by_osm_run", (q) => q.eq("osmId", osmId).eq("run", run)).collect();
}

/** Takes a secret out of the running: its sticker goes, and a note says why when it isn't the check's own. */
async function takeOut(ctx: AppCtx<DataModel>, id: Id<"loreEntries">, row: Doc<"loreEntries">, note?: string) {
  await deleteSticker(ctx, row);
  await ctx.db.patch("loreEntries", id, { stickerFile: undefined, ...(note ? { checkNotes: [...row.checkNotes, note] } : {}) });
}

export const loreEntry = defineMachine(
  schema,
  {
    name: "loreEntry",
    table: "loreEntries",
    description: "One secret a suburb's research run writes: checked, then live on people's phones, waiting for Mike, or left out.",
    events: {
      server: {
        // The writer's draft (loreRun.saveDrafts).
        DRAFTED: {},
        // A check took it out (loreRun.updateEntry, loreRun.applyRules), `by` the check's name.
        DROPPED: { by: v.string() },
        // The run's last step (loreRun.publish).
        PUBLISH: {},
        // Mike's review: lore:approve and lore:hide, and the same from the app.
        APPROVE: {},
        HIDE: {},
      },
      lorePlace: { RUN_STOPPED: {}, BROUGHT_BACK: {} },
    },
    guards: {
      factChecked: "It hasn't passed the fact-check.",
      notSensitive: "It's about First Nations heritage, a death or crime, or living people, and those wait for Mike (when loreConfig.reviewSensitive is on).",
      notTheirFault: "A check dropped it for something in the secret itself.",
    },
    states: {
      start: { on: { DRAFTED: { to: "checking", description: "The run's writer drafts the secret, and it goes through the checks." } } },
      checking: {
        description: "Written by a run and going through its checks: its quotes against their sources, a fact-check, the rules and its sticker.",
        on: {
          DROPPED: {
            to: "dropped", effect: "drop",
            description: "A check takes it out: its quotes or facts don't hold up, it breaks a rule, or the run can't afford to check it.",
          },
          RUN_STOPPED: { to: "dropped", effect: "runStopped", description: "Its run broke before publishing, so it's taken out until a rerun brings it back." },
          // Never published without passing the fact-check: one the run couldn't afford to
          // check, say, or one lore:resume brought back without checking again.
          PUBLISH: [
            {
              to: "auto", guard: ["factChecked", "notSensitive"],
              description: "The run publishes, and it passed the fact-check and needn't wait for Mike, so it goes live.",
            },
            { to: "pending", guard: "factChecked", description: "The run publishes, and it passed the fact-check but is sensitive, so it waits for Mike's OK." },
            { to: "dropped", effect: "notChecked", description: "The run publishes, but it never passed the fact-check, so it's left out." },
          ],
        },
      },
      dropped: {
        description: "Left out and never shown: a check took it out, or the run stopped, ran out of budget, or never checked it.",
        on: {
          BROUGHT_BACK: {
            to: "checking", guard: "notTheirFault", effect: "bringBack",
            description: "Mike reruns its run, and a secret left out through no fault of its own goes back through the checks.",
          },
        },
      },
      auto: {
        description: "Live on people's phones, put there by the run without needing Mike's OK.",
        on: {
          APPROVE: { to: "approved", effect: "approve", description: "Mike approves it, so it stays live with his OK." },
          HIDE: { to: "hidden", effect: "hide", description: "Mike hides it, so it comes off people's phones." },
        },
      },
      pending: {
        description: "Sensitive (First Nations heritage, a death or crime, or living people), so it waits for Mike's OK, when that review is switched on.",
        on: {
          APPROVE: { to: "approved", effect: "approve", description: "Mike approves it, so it goes live." },
          HIDE: { to: "hidden", effect: "hide", description: "Mike decides it shouldn't go live." },
        },
      },
      approved: {
        description: "Live on people's phones, with Mike's OK.",
        on: { HIDE: { to: "hidden", effect: "hide", description: "Mike hides it, so it comes off people's phones." } },
      },
      hidden: {
        description: "Kept off people's phones by Mike, and its sticker deleted.",
        on: {
          APPROVE: {
            to: "approved", effect: "approve",
            description: "Mike puts it live after all; it shows a plain badge until its sticker is drawn again.",
          },
        },
      },
    },
  },
  {
    guards: {
      factChecked: (_ctx, { row }) => row.factChecked,
      notSensitive: (_ctx, { row }) => !reviewSensitive || row.sensitive.length === 0,
      notTheirFault: (_ctx, { state }) => notTheirFault.includes(state.by),
    },
    effects: {
      // The check's own notes come with the call that drops it.
      drop: async (ctx, { id, row, event }) => {
        await takeOut(ctx, id, row);
        return { kind: "dropped", by: event.by };
      },
      runStopped: async (ctx, { id, row }) => {
        await takeOut(ctx, id, row, "The run stopped before it finished.");
        return { kind: "dropped", by: "run stopped" };
      },
      notChecked: async (ctx, { id, row }) => {
        await takeOut(ctx, id, row, "It hadn't been fact-checked when the run published, so it's left out.");
        return { kind: "dropped", by: "not checked" };
      },
      bringBack: async (ctx, { id, row, from }) => {
        // The step lore:resume restarts from, on the place that brought it back.
        const place = await ctx.db.get("lorePlaces", from.id as Id<"lorePlaces">);
        const step = place?.state.kind === "queued" ? place.state.resume : undefined;
        await ctx.db.patch("loreEntries", id, { checkNotes: [...row.checkNotes, `Brought back by lore:resume from ${step ?? "a step"}.`] });
        return { kind: "checking" };
      },
      approve: async (ctx, { row }) => {
        await bumpVersion(ctx, row.osmId);
        return { kind: "approved" };
      },
      // A hidden secret's art goes too. Approved again later, it shows a plain badge until
      // lore:resume from "stickers" draws it again.
      hide: async (ctx, { id, row }) => {
        await takeOut(ctx, id, row);
        await bumpVersion(ctx, row.osmId);
        return { kind: "hidden" };
      },
    },
  },
);
