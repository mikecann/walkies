import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account deletions run as a chain of steps; this restarts any chain that stopped.
crons.interval("resume account deletions", { hours: 1 }, internal.accountDeletion.resumeStalled, {});

// Secrets research held by a spending cap starts once the day or month rolls over, and
// places a retry put back on the queue start. The retries themselves are the research
// machine's timers (loreMachines.ts).
crons.interval("start held secrets research", { hours: 1 }, internal.lore.tick, {});

// The street cache's warm queue restarts its own worker whenever a place is queued. This
// catches one that died mid-queue, which would otherwise leave the rest waiting.
crons.interval("resume warming streets", { minutes: 15 }, internal.places.resumeWorker, {});

export default crons;
