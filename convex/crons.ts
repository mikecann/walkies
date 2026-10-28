import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account deletions run as a chain of steps; this restarts any chain that stopped.
crons.interval("resume account deletions", { hours: 1 }, internal.accountDeletion.resumeStalled, {});

// Secrets research held by a spending cap starts once the day or month rolls over, and
// places a retry put back on the queue start. The retries themselves are the research
// machine's timers (loreMachines.ts).
crons.interval("start held secrets research", { hours: 1 }, internal.lore.tick, {});

export default crons;
