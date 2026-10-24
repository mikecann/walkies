import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account deletions run as a chain of steps; this restarts any chain that stopped.
crons.interval("resume account deletions", { hours: 1 }, internal.accountDeletion.resumeStalled, {});

// Secrets research held by a spending cap starts once the day or month rolls over, and
// quiet or failed places that are due go back on the queue (only with LORE_AUTO on).
crons.interval("start held secrets research", { hours: 1 }, internal.lore.tick, {});

export default crons;
