import { defineMachines, deliveryArgs, historyEntry, type AppCtx, type Machines } from "@convex-dev/state-machines";
import type { GenericDatabaseWriter, WithoutSystemFields } from "convex/server";
import { v } from "convex/values";
import { components, internal } from "./_generated/api";
import type { DataModel, Doc, TableNames } from "./_generated/dataModel";
import { internalMutation, internalQuery, mutation } from "./_generated/server";
// Import the machines from here rather than their own module: sending needs the
// catalog, and importing this loads it.
import { loreEntry, lorePlace } from "./loreMachines";
import schema from "./schema";

// Every state machine in Walkies, checked together when the app loads: a suburb's
// research and each secret it writes (loreMachines.ts). The lore functions are built
// with this catalog's builders, whose db can't write a machine's state or delete its
// rows; `server` events and purge need its internalMutation, which carries the
// internal brand. Everything else in the app stays on Convex's own builders, as no
// other table holds a state union.
export const machines: Machines<typeof schema> = defineMachines(schema, [lorePlace, loreEntry], {
  mutation,
  internalMutation,
  internalQuery,
  deliver: internal.machines.deliver,
  component: components.stateMachines,
});

export { loreEntry, lorePlace };

// Timers (the queue's expiry, the retries) and the ignore links between the two
// machines fire through this. A timer whose step throws stays pending, its job
// failed, until rearmTimer.
export const deliver = machines.internalMutation({ args: deliveryArgs, handler: machines.deliver });

/** Timers whose step threw, newest first. `npx convex run machines:failedTimers` */
export const failedTimers = machines.internalQuery({
  args: { limit: v.optional(v.number()) },
  returns: v.array(v.object({ machine: v.string(), id: v.string(), event: v.string(), dueAt: v.number() })),
  handler: async (ctx, args) => await machines.failedTimers(ctx, args),
});

/** Delivers a failed timer again, once its bug is fixed.
 * `npx convex run machines:rearmTimer '{"machine": "lorePlace", "id": "...", "event": "RETRY_DUE"}'` */
export const rearmTimer = machines.internalMutation({
  args: { machine: v.string(), id: v.string(), event: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => {
    await machines.rearmTimer(ctx, args);
    return null;
  },
});

export const vHistory = v.array(historyEntry);

/** Tables no machine is on. */
type PlainTable = Exclude<TableNames, "lorePlaces" | "loreEntries">;

/**
 * Inserts a row into a table no machine is on, from a function built with the catalog.
 * The catalog's db allows that at runtime, but in @convex-dev/state-machines 0.1.1 its
 * insert type refuses any table with an optional field (loreSpend, loreNotes), as if
 * it held a machine's state. The table's type here keeps the machines' tables out.
 */
export async function insertPlain<T extends PlainTable>(ctx: { db: AppCtx<DataModel>["db"] }, table: T, value: WithoutSystemFields<Doc<T>>) {
  return await (ctx.db as unknown as GenericDatabaseWriter<DataModel>).insert(table, value);
}
