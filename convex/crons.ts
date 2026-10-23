import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account deletions run as a chain of steps; this restarts any chain that stopped.
crons.interval("resume account deletions", { hours: 1 }, internal.accountDeletion.resumeStalled, {});

export default crons;
