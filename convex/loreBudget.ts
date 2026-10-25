// Every paid OpenRouter call goes through `meteredFetch`: it books a hold for the most
// the call could cost before sending it (loreRun.reserve, which refuses a hold that
// would pass the run's, the day's or the month's cap), then settles the hold to the
// call's real `usage.cost`. A call whose cost never comes back (lost, unreadable, or
// an answer with no usage) keeps its hold as spent. Used by lorePipeline.ts and the
// Node sticker action, so nothing here needs Node.
import { internal } from "./_generated/api";
import type { ActionCtx } from "./_generated/server";
import { holds, prices } from "./loreConfig";

/** How a cap refusing a call starts its message. lore.runFinished doesn't retry these.
 * Here rather than in loreRun.ts so the Node sticker action needn't load that file. */
export const overBudget = "Over budget:";

type Request = {
  model?: unknown;
  max_tokens?: unknown;
  max_completion_tokens?: unknown;
  modalities?: unknown;
  messages?: { content?: unknown }[];
  tools?: { type?: unknown; parameters?: { max_uses?: unknown; max_results?: unknown; max_characters?: unknown } }[];
};

const count = (value: unknown, fallback: number) => typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback;

/**
 * The most one chat completion request could cost, in US dollars: its prompt (at
 * least one token per `holds.bytesPerToken` bytes, plus attached images) and its
 * `max_tokens` of output, at the dearest rates in `prices`, read once more for each
 * web search it may run, plus the searches and their results. Throws for a model
 * with no price or a request with no output limit, so neither can be sent unbounded.
 */
export function callBound(request: Request, bytes: number): number {
  const model = typeof request.model === "string" ? request.model : "";
  const price = prices[model];
  if (!price) throw new Error(`No price for ${model || "this model"} in loreConfig.prices, so it isn't called`);
  const output = count(request.max_tokens, count(request.max_completion_tokens, -1));
  if (output < 0) throw new Error("A paid call needs max_tokens, so its cost has a limit");
  const images = (request.messages ?? []).reduce((n, message) =>
    n + (Array.isArray(message.content) ? message.content.filter((part: { type?: unknown }) => part?.type === "image_url").length : 0), 0);
  const search = (request.tools ?? []).find((t) => t?.type === "openrouter:web_search");
  // OpenRouter's own default is 30 searches a request, so a search tool must set max_uses.
  const searches = search ? count(search.parameters?.max_uses, 30) : 0;
  const resultChars = searches * count(search?.parameters?.max_results, 25) * count(search?.parameters?.max_characters, 100_000);
  const prompt = Math.ceil(bytes / holds.bytesPerToken) + Math.ceil(resultChars / holds.bytesPerToken);
  const reads = 1 + searches;
  const drawsImage = Array.isArray(request.modalities) && request.modalities.includes("image");
  return reads * (prompt * price.input + output * price.output)
    + images * holds.imageInTokens * price.input
    + (drawsImage ? holds.imageOutTokens * (price.image ?? price.output) : 0)
    + searches * holds.searchPrice;
}

/** Whether an error (perhaps wrapped by the AI SDK's retries) is a cap refusing a call. */
export function isOverBudget(error: unknown): boolean {
  return String(error instanceof Error ? error.message : error).includes(overBudget);
}

/**
 * fetch for OpenRouter's chat completions, with each request held, sent and settled
 * as above. `onSettled` hears what the call cost (its hold, if the cost never came)
 * and what this budget segment has now spent.
 */
export function meteredFetch(ctx: ActionCtx, osmId: number, step: string, onSettled?: (cost: number, runCost: number) => void): typeof fetch {
  return async (input, init) => {
    const body = typeof init?.body === "string" ? init.body : null;
    if (body === null) throw new Error("Only JSON requests to OpenRouter can be metered");
    const amount = callBound(JSON.parse(body) as Request, new TextEncoder().encode(body).length);
    const booked = await ctx.runMutation(internal.loreRun.reserve, { osmId, step, amount });
    if ("refused" in booked) throw new Error(booked.refused);
    let cost: number | undefined;
    try {
      const response = await fetch(input, init);
      const usage = await response.clone().json().then((json: { usage?: { cost?: unknown } }) => json?.usage?.cost, () => undefined);
      if (typeof usage === "number" && Number.isFinite(usage) && usage >= 0) cost = usage;
      return response;
    } finally {
      // Also when the request threw or was aborted: it may have been billed anyway.
      const runCost = await ctx.runMutation(internal.loreRun.settle, { holdId: booked.holdId, ...(cost === undefined ? {} : { cost }) });
      onSettled?.(cost ?? amount, runCost);
    }
  };
}
