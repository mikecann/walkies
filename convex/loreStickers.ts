"use node";
// A secret's sticker: drawn by Gemini 3 Pro Image through OpenRouter with two bundled
// stickers as style references, then lifted off its background (loreCutout.ts). Node,
// for zlib.
// @ts-expect-error Convex's tsconfig has no Node types, and zlib is all this file needs from Node.
import zlibModule from "node:zlib";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { env, internalAction, type ActionCtx } from "./_generated/server";
import { models, stickerReferences } from "./loreConfig";
import { cutOut, decodePng, encodePng, type Zlib } from "./loreCutout";
import { stickerPrompt } from "./lorePrompts";

const zlib = zlibModule as {
  inflateSync(data: Uint8Array): Uint8Array;
  deflateSync(data: Uint8Array, options: { level: number }): Uint8Array;
};
const png: Zlib = {
  inflate: (data) => new Uint8Array(zlib.inflateSync(data)),
  deflate: (data) => new Uint8Array(zlib.deflateSync(data, { level: 9 })),
};

/** One drawing, or null if the model sent back no image. Records what it cost. */
async function drawOnce(ctx: ActionCtx, osmId: number, prompt: string): Promise<Uint8Array | null> {
  const apiKey = env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error("OPENROUTER_API_KEY isn't set");
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json", "X-Title": "Walkies secrets" },
    body: JSON.stringify({
      model: models.sticker,
      modalities: ["image", "text"],
      image_config: { aspect_ratio: "1:1" },
      messages: [{
        role: "user",
        content: [{ type: "text", text: prompt }, ...stickerReferences.map((url) => ({ type: "image_url", image_url: { url } }))],
      }],
    }),
  });
  const json = await response.json().catch(() => null) as {
    usage?: { cost?: number };
    error?: { message?: string };
    choices?: { message?: { images?: { image_url?: { url?: string } }[] } }[];
  } | null;
  if (typeof json?.usage?.cost === "number" && json.usage.cost > 0) {
    await ctx.runMutation(internal.loreRun.recordSpend, { osmId, step: "stickers", cost: json.usage.cost });
  }
  if (!response.ok) throw new Error(`OpenRouter answered ${response.status}: ${json?.error?.message ?? ""}`.trim());
  const url = json?.choices?.[0]?.message?.images?.[0]?.image_url?.url;
  const base64 = url?.match(/^data:image\/png;base64,(.+)$/)?.[1];
  return base64 ? Uint8Array.from(atob(base64), (char) => char.charCodeAt(0)) : null;
}

/**
 * Draws and cuts out a secret's sticker. A drawing that doesn't cut out cleanly gets
 * one redraw; after that the secret goes without, and the phones show a plain one.
 */
export const draw = internalAction({
  args: { osmId: v.number(), entryId: v.string(), subject: v.string(), country: v.string() },
  returns: v.boolean(),
  handler: async (ctx, { osmId, entryId, subject, country }) => {
    const prompt = stickerPrompt(subject, country);
    for (let attempt = 0; attempt < 2; attempt++) {
      await ctx.runQuery(internal.loreRun.checkBudget, { osmId });
      const raw = await drawOnce(ctx, osmId, prompt);
      const sticker = raw && cutOut(decodePng(raw, png));
      if (sticker) {
        const file = await ctx.storage.store(new Blob([encodePng(sticker, png)], { type: "image/png" }));
        await ctx.runMutation(internal.loreRun.updateEntry, { entryId, stickerFile: file, ...(attempt > 0 ? { notes: ["Sticker: redrawn once, as the first didn't cut out cleanly."] } : {}) });
        return true;
      }
    }
    await ctx.runMutation(internal.loreRun.updateEntry, { entryId, notes: ["Sticker: two drawings didn't cut out cleanly, so it has none."] });
    return false;
  },
});
