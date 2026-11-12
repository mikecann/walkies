import { viewerArgs } from "@convex-dev/state-machines";
import { query, type QueryCtx } from "./_generated/server";
import { isAdmin } from "./lore";
import { machines } from "./machines";

// What the state machines viewer on walkies.mikecann.app/admin/machines reads (web/admin):
// the lore machines as the app runs them, and each row through `survey`. Read-only: there's
// no `send` or `create`, so nothing here can move a row.
//
// Only Chef's admin (Mike) reads anything, by the same check as the app's secrets review
// (lore.ts `isAdmin`: signed in, through `currentUserId`, so merged and deleted accounts
// are handled, and the feedback component says "admin"). Everyone else, guests included,
// gets null from every query, which the viewer shows as "off", rather than an error.
//
// That check asks the feedback component, and the library's `read` check only gets
// `{ db, auth }`, so it can't. So each query checks first, with the whole ctx, and `read`
// is a floor under it: whoever calls must at least be signed in.
const viewer = machines.viewer({ read: async (ctx) => (await ctx.auth.getUserIdentity()) !== null });

async function adminOnly<T>(ctx: QueryCtx, read: () => Promise<T>): Promise<T | null> {
  if (!(await isAdmin(ctx))) return null;
  return await read();
}

export const overview = query({
  args: viewerArgs.overview,
  handler: (ctx) => adminOnly(ctx, () => viewer.overview(ctx)),
});
export const counts = query({
  args: viewerArgs.counts,
  handler: (ctx, args) => adminOnly(ctx, () => viewer.counts(ctx, args)),
});
export const rows = query({
  args: viewerArgs.rows,
  handler: (ctx, args) => adminOnly(ctx, () => viewer.rows(ctx, args)),
});
export const row = query({
  args: viewerArgs.row,
  handler: (ctx, args) => adminOnly(ctx, () => viewer.row(ctx, args)),
});
