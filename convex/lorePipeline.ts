// One suburb's research run, as a durable workflow: research → write → quote check →
// fact-check → rules → pins → stickers → publish. Each step is its own action, so a
// crash or an OpenRouter outage retries that step, not the whole run. lore.ts starts
// these and loreRun.ts keeps their results.
import { v } from "convex/values";
import { Agent } from "@convex-dev/agent";
import { createOpenRouter } from "@openrouter/ai-sdk-provider";
import { generateText, Output, stepCountIs, tool, type ToolSet } from "ai";
import { z } from "zod";
import { components, internal } from "./_generated/api";
import { env, internalAction, type ActionCtx } from "./_generated/server";
import { boundingBox, fetchPage, findQuote, insideBoundary, placePin, type Page } from "./loreChecks";
import { caps, entries as wanted, maxPinToStreet, models, research as limits } from "./loreConfig";
import { angles, categories, checkerInstructions, researchInstructions, reviserInstructions, writerInstructions, type Angle, type PlaceBrief } from "./lorePrompts";
import { workflow } from "./lore";
import { budgetMessage, overBudget } from "./loreRun";
import type { PlaceData } from "./placeData";
import { cachedFile, nominatim } from "./places";


const retry = { maxAttempts: 3, initialBackoffMs: 30_000, base: 2 };
const vResult = v.object({ live: v.number(), pending: v.number(), dropped: v.number(), status: v.string() });

export const run = workflow
  .define({ args: { osmId: v.number(), run: v.number() }, returns: vResult })
  .handler(async (step, { osmId, run }): Promise<{ live: number; pending: number; dropped: number; status: string }> => {
    const budget = () => step.runQuery(internal.loreRun.checkBudget, { osmId });
    const { wa, country } = await step.runAction(internal.lorePipeline.prepare, { osmId }, { retry });
    // An angle that keeps failing keeps the notes it saved, and the others carry on.
    // If they all fail, something's wrong (OpenRouter's down, or out of credit), and
    // the run fails rather than calling the place quiet.
    const failures: unknown[] = [];
    await Promise.all((Object.keys(angles) as Angle[]).map((angle) =>
      step.runAction(internal.lorePipeline.research, { osmId, run, angle, wa }, { retry: { ...retry, maxAttempts: 2 }, name: `research ${angle}` })
        .catch((error: unknown) => failures.push(error))));
    if (failures.length === Object.keys(angles).length) throw failures[0];
    await budget();
    await step.runAction(internal.lorePipeline.write, { osmId, run, wa }, { retry });
    await budget();
    await step.runAction(internal.lorePipeline.checkQuotes, { osmId, run }, { retry });
    await step.runAction(internal.lorePipeline.factCheck, { osmId, run, wa }, { retry });
    await step.runMutation(internal.loreRun.applyRules, { osmId, run, wa });
    await step.runAction(internal.lorePipeline.checkPins, { osmId, run }, { retry });
    await budget();
    const survivors: Entry[] = await step.runQuery(internal.loreRun.checking, { osmId, run });
    // A sticker that keeps failing leaves its secret without one (the phones show a
    // plain sticker). Only the spending limit stops the run here.
    await Promise.all(survivors.map((entry) =>
      step.runAction(internal.loreStickers.draw, { osmId, entryId: entry.entryId, subject: entry.sticker, country }, { retry, name: `sticker ${entry.entryId}` })
        .catch((error: unknown) => {
          if (String(error).includes(overBudget)) throw error;
          return false;
        })));
    return await step.runMutation(internal.loreRun.publish, { osmId, run });
  });

/**
 * OpenRouter, with every call's `usage.cost` recorded against the place before the
 * answer goes back to the AI SDK, and the run stopped once it reaches its limit. Counting
 * at the fetch catches calls the SDK retries or fails to parse, which still cost money.
 */
function openRouter(ctx: ActionCtx, osmId: number, step: string, onCost?: (cost: number, runCost: number) => void) {
  const apiKey = env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error("OPENROUTER_API_KEY isn't set");
  const metered: typeof fetch = async (input, init) => {
    const response = await fetch(input, init);
    const cost = await response.clone().json().then((body: { usage?: { cost?: unknown } }) => body?.usage?.cost, () => undefined);
    if (typeof cost === "number" && cost > 0) {
      const runCost = await ctx.runMutation(internal.loreRun.recordSpend, { osmId, step, cost });
      onCost?.(cost, runCost);
    }
    return response;
  };
  return createOpenRouter({ apiKey, compatibility: "strict", fetch: metered, headers: { "X-Title": "Walkies secrets" } });
}

// Usage accounting puts `usage.cost` in every answer. Anthropic models cache the
// growing research conversation, so each step only pays full price for what's new.
const chatSettings = { usage: { include: true }, cache_control: { type: "ephemeral" as const } };

type Brief = PlaceBrief & { runCost: number };
type Note = { angle: string; fact: string; url: string; quote: string; spot?: { name: string; lat?: number; lon?: number } };
type Entry = {
  entryId: string; title: string; body: string; category: string; place?: { name: string; lat: number; lon: number };
  sticker: string; claims: { text: string; url: string; quote: string; found?: boolean; context?: string }[];
  sensitive: string[]; checkNotes: string[];
};
async function placeBrief(ctx: ActionCtx, osmId: number, wa: boolean): Promise<Brief> {
  const row: { name: string; displayName: string; country: string; runCost: number } = await ctx.runQuery(internal.loreRun.brief, { osmId });
  return { name: row.name, displayName: row.displayName, wa, country: row.country, runCost: row.runCost };
}

async function placeData(ctx: ActionCtx, osmId: number): Promise<PlaceData> {
  const blob = await ctx.storage.get(await cachedFile(ctx, osmId));
  if (!blob) throw new Error("Place data file is missing");
  return JSON.parse(await blob.text()) as PlaceData;
}

/** Caches the suburb's streets and finds out where in the world it is. */
export const prepare = internalAction({
  args: { osmId: v.number() },
  returns: v.object({ wa: v.boolean(), country: v.string() }),
  handler: async (ctx, { osmId }): Promise<{ wa: boolean; country: string }> => {
    await cachedFile(ctx, osmId);
    const answer = await nominatim(ctx, "lookup", { osm_ids: `R${osmId}`, format: "jsonv2", addressdetails: "1" });
    const item = Array.isArray(answer) ? answer[0] as { name?: string; display_name?: string; address?: Record<string, string> } | undefined : undefined;
    if (!item) throw new Error("Nominatim doesn't know this relation");
    const address = item.address ?? {};
    const name = item.name || item.display_name?.split(",")[0] || "Somewhere";
    const region = address.state ?? address.region ?? address.county ?? "";
    const country = address.country_code ?? "";
    await ctx.runMutation(internal.loreRun.setPlaceInfo, { osmId, name, displayName: item.display_name ?? name, region, country });
    return { wa: country === "au" && region === "Western Australia", country };
  },
});

/**
 * One research angle: an agent with web search, a page reader, a map lookup and a
 * notebook. Notes are saved as it goes, so a step that's stopped or retried keeps
 * what it found. Its thread, with every search and page, stays in the agent component.
 */
export const research = internalAction({
  args: { osmId: v.number(), run: v.number(), angle: v.string(), wa: v.boolean() },
  returns: v.object({ notes: v.number(), steps: v.number(), stopped: v.string() }),
  handler: async (ctx, { osmId, run, angle, wa }): Promise<{ notes: number; steps: number; stopped: string }> => {
    const brief = await placeBrief(ctx, osmId, wa);
    const data = await placeData(ctx, osmId);
    const box = boundingBox(data.boundary);
    const earlier = (await ctx.runQuery(internal.loreRun.notes, { osmId, run }) as Note[]).filter((n) => n.angle === angle);
    const state = { notes: earlier.length, othersSeen: 0, runCost: brief.runCost, spent: 0, startedAt: Date.now() };
    const stopReason = () =>
      state.runCost >= caps.perRun ? budgetMessage(state.runCost)
        : state.spent >= limits.maxSpend ? "spent this angle's share"
          : state.notes >= limits.maxNotes ? "enough notes"
            : Date.now() - state.startedAt > limits.maxTime ? "out of time" : null;
    const provider = openRouter(ctx, osmId, "research", (cost, runCost) => {
      state.spent += cost;
      state.runCost = runCost;
    });
    // What fetch_page showed the agent, so save_note can check quotes against it.
    const seen = new Map<string, string>();

    const tools: ToolSet = {
      // The provider's types only know `engine` and `maxResults`, but OpenRouter also
      // takes a cap on characters per result, and the provider passes `parameters` on as is.
      web_search: provider.tools.webSearch({
        parameters: { engine: "exa", max_results: limits.searchResults, max_characters: limits.searchChars },
      } as { maxResults?: number }),
      fetch_page: tool({
        description: "Reads a web page as plain text. Long pages come in parts: pass `from` to read on.",
        inputSchema: z.object({ url: z.string(), from: z.number().int().min(0).optional() }),
        execute: async ({ url, from = 0 }) => {
          const page: Page = await fetchPage(url);
          if (!page.ok) return { error: `Couldn't read ${url}: ${page.reason}.` };
          seen.set(url, page.text);
          seen.set(page.url, page.text);
          const text = page.text.slice(from, from + limits.pageChars);
          const next = from + limits.pageChars < page.text.length ? from + limits.pageChars : undefined;
          return { url: page.url, title: page.title, text, ...(next ? { more: `Call again with from: ${next} to read on.` } : {}) };
        },
      }),
      find_spot: tool({
        description: `Looks up a named street, park, building or landmark in ${brief.name} on OpenStreetMap and gives its coordinates.`,
        inputSchema: z.object({ query: z.string() }),
        execute: async ({ query }) => {
          const answer = await nominatim(ctx, "search", {
            q: query, format: "jsonv2", limit: "5", bounded: "1",
            viewbox: `${box.west - 0.01},${box.north + 0.01},${box.east + 0.01},${box.south - 0.01}`,
          }).catch(() => null);
          if (!Array.isArray(answer) || answer.length === 0) return { found: [], hint: "Nothing by that name here. Try the street it's on." };
          return {
            found: (answer as { display_name?: string; type?: string; lat?: string; lon?: string }[]).map((item) => {
              const lat = Number(item.lat), lon = Number(item.lon);
              return { name: item.display_name?.split(",").slice(0, 2).join(",") ?? query, kind: item.type, lat, lon, inside: insideBoundary(data.boundary, lat, lon) };
            }),
          };
        },
      }),
      save_note: tool({
        description: "Saves one fact for the writer, with the page it came from and the exact words on that page that prove it.",
        inputSchema: z.object({
          fact: z.string().describe("The fact in your own words, one or two sentences."),
          url: z.string().describe("The page you read it on with fetch_page."),
          quote: z.string().describe("8 to 60 words copied exactly from that page."),
          spot: z.string().optional().describe("The spot it's about, if any."),
          lat: z.number().optional(),
          lon: z.number().optional(),
        }),
        execute: async ({ fact, url, quote, spot, lat, lon }) => {
          const text = seen.get(url);
          if (text === undefined) return { error: "Read that page with fetch_page first, then quote from it." };
          if (!findQuote(text, quote).found) return { error: "Those words aren't on the page exactly. Copy the quote straight from the fetch_page text." };
          const { saved, others } = await ctx.runMutation(internal.loreRun.saveNote, {
            osmId, run, angle, fact, url, quote,
            ...(spot ? { spot: { name: spot, ...(lat !== undefined && lon !== undefined ? { lat, lon } : {}) } } : {}),
          });
          state.notes = saved;
          // Only what's new since this agent last heard, to keep its context small.
          const fresh = others.slice(state.othersSeen);
          state.othersSeen = others.length;
          return {
            saved,
            ...(fresh.length ? { otherResearchersSaved: fresh } : {}),
            ...(saved >= limits.maxNotes ? { hint: "That's plenty. Finish up now." } : {}),
          };
        },
      }),
    };

    // Cast because tsc gives up ("union type too complex") checking these options
    // against the agent's types, which compare the model with every model id AI SDK
    // knows. The same options compile on their own; OpenRouter's model is AI SDK 7.
    const options = {
      name: `lore ${angle}`,
      languageModel: provider.chat(models.research, chatSettings),
      instructions: researchInstructions(brief, angle as Angle, limits.maxNotes),
      tools,
      callSettings: { maxRetries: 3, maxOutputTokens: limits.outputTokens },
    };
    const agent = new Agent(components.agent, options as never);
    const { thread } = await agent.createThread(ctx, { title: `${brief.name}: ${angle}, run ${run}` });
    const prompt = earlier.length === 0 ? `Start researching ${brief.name}.`
      : `Carry on researching ${brief.name}. You've already saved these notes, so find different ones:\n${earlier.map((n) => `- ${n.fact}`).join("\n")}`;
    const result = await thread.generateText({ prompt, stopWhen: [stepCountIs(limits.maxSteps), () => stopReason() !== null] });
    const stopped = stopReason();
    if (stopped?.startsWith(overBudget)) throw new Error(stopped);
    return { notes: state.notes, steps: result.steps.length, stopped: stopped ?? "finished" };
  },
});

const draftSchema = z.object({
  entries: z.array(z.object({
    slug: z.string(),
    title: z.string(),
    body: z.string(),
    category: z.enum(categories),
    place: z.object({ name: z.string(), lat: z.number(), lon: z.number() }).nullable(),
    sticker: z.string(),
    claims: z.array(z.object({ text: z.string(), url: z.string(), quote: z.string() })),
    sensitive: z.object({ firstNations: z.boolean(), deathOrCrime: z.boolean(), livingPeople: z.boolean() }),
  })),
});

const flags = (s: { firstNations: boolean; deathOrCrime: boolean; livingPeople: boolean }) => [
  ...(s.firstNations ? ["first-nations"] : []), ...(s.deathOrCrime ? ["death-or-crime"] : []), ...(s.livingPeople ? ["living-people"] : []),
];

/** Turns the notes into secrets, each fact with the quote that backs it. */
export const write = internalAction({
  args: { osmId: v.number(), run: v.number(), wa: v.boolean() },
  returns: v.number(),
  handler: async (ctx, { osmId, run, wa }): Promise<number> => {
    const brief = await placeBrief(ctx, osmId, wa);
    const notes: Note[] = await ctx.runQuery(internal.loreRun.notes, { osmId, run });
    if (notes.length === 0) return 0;
    const earlier: string[] = await ctx.runQuery(internal.loreRun.earlierTitles, { osmId, run });
    const { output } = await generateText({
      model: openRouter(ctx, osmId, "write").chat(models.write, { usage: { include: true } }),
      output: Output.object({ schema: draftSchema }),
      system: writerInstructions(brief, wanted.most),
      prompt: [
        `Research notes on ${brief.name}:`,
        ...notes.map((n, i) => [
          `[${i + 1}] (${n.angle}) ${n.fact}`,
          `URL: ${n.url}`,
          `Quote: "${n.quote}"`,
          ...(n.spot ? [`Spot: ${n.spot.name}${n.spot.lat !== undefined ? ` (${n.spot.lat}, ${n.spot.lon})` : ""}`] : []),
        ].join("\n")),
        ...(earlier.length ? [`Already in the game for ${brief.name}, so don't repeat them: ${earlier.join("; ")}.`] : []),
      ].join("\n\n"),
      maxOutputTokens: 16_000,
      maxRetries: 2,
    });
    const drafts = output.entries.filter((e) => e.claims.length > 0).slice(0, wanted.most).map((e) => ({
      slug: e.slug, title: e.title.trim(), body: e.body.trim(), category: e.category,
      ...(e.place ? { place: { name: e.place.name, lat: e.place.lat, lon: e.place.lon } } : {}),
      sticker: e.sticker, claims: e.claims, sensitive: flags(e.sensitive),
    }));
    const ids: string[] = await ctx.runMutation(internal.loreRun.saveDrafts, { osmId, run, suburb: brief.name, drafts });
    return ids.length;
  },
});

/**
 * Opens every page a secret cites and looks for its quote. A quote that isn't there
 * (made up, or from a page that's changed) loses its claim, and a secret left with
 * none is dropped. Dead links count as not there, as they did in the hand runs.
 */
export const checkQuotes = internalAction({
  args: { osmId: v.number(), run: v.number() },
  returns: v.object({ kept: v.number(), dropped: v.number() }),
  handler: async (ctx, { osmId, run }): Promise<{ kept: number; dropped: number }> => {
    // Heritage databases can be slow, so pages get longer than research gave them,
    // and one more go if they time out or the site's busy.
    const pages = new Map<string, Promise<Page>>();
    const page = (url: string) => {
      if (!pages.has(url)) {
        pages.set(url, fetchPage(url, 40_000).then((first) =>
          !first.ok && /too long|answered (429|5\d\d)|wouldn't load/.test(first.reason) ? fetchPage(url, 40_000) : first));
      }
      return pages.get(url)!;
    };
    let kept = 0, dropped = 0;
    for (const entry of await ctx.runQuery(internal.loreRun.checking, { osmId, run }) as Entry[]) {
      const notes: string[] = [];
      const claims = await Promise.all(entry.claims.map(async (claim) => {
        const opened = await page(claim.url);
        if (!opened.ok) {
          notes.push(`Quote check: couldn't open ${claim.url} (${opened.reason}), so "${claim.text}" lost its source.`);
          return { ...claim, found: false };
        }
        const match = findQuote(opened.text, claim.quote);
        if (!match.found) notes.push(`Quote check: "${claim.quote.slice(0, 120)}" isn't on ${claim.url}.`);
        return { ...claim, found: match.found, ...(match.context ? { context: match.context } : {}) };
      }));
      const none = claims.every((c) => !c.found);
      await ctx.runMutation(internal.loreRun.updateEntry, {
        entryId: entry.entryId, claims, notes, ...(none ? { drop: "quote check" } : {}),
      });
      if (none) dropped++;
      else kept++;
    }
    return { kept, dropped };
  },
});

const checkSchema = z.object({
  supported: z.boolean(),
  problems: z.array(z.string()),
  firstNations: z.boolean(),
  deathOrCrime: z.boolean(),
  livingPeople: z.boolean(),
  restricted: z.boolean(),
});

const reviseSchema = z.object({ title: z.string(), body: z.string(), giveUp: z.boolean() });

/**
 * A model from another lab reads each secret against its quotes. A secret with any
 * problem goes back to the writer once, to cut or soften the words at fault, and the
 * revision is checked again. One that still has problems is dropped.
 */
export const factCheck = internalAction({
  args: { osmId: v.number(), run: v.number(), wa: v.boolean() },
  returns: v.object({ kept: v.number(), revised: v.number(), dropped: v.number() }),
  handler: async (ctx, { osmId, run, wa }): Promise<{ kept: number; revised: number; dropped: number }> => {
    const brief = await placeBrief(ctx, osmId, wa);
    const checker = openRouter(ctx, osmId, "check").chat(models.check, { usage: { include: true } });
    const reviser = openRouter(ctx, osmId, "revise").chat(models.write, { usage: { include: true } });
    const entries: Entry[] = await ctx.runQuery(internal.loreRun.checking, { osmId, run });
    let kept = 0, revised = 0, dropped = 0;
    const sources = (entry: Entry) => entry.claims.filter((c) => c.found)
      .map((c, n) => `Source ${n + 1}: ${c.url}\nClaim: ${c.text}\nQuote: "${c.quote}"\nPage text around it: ${c.context ?? c.quote}`);
    const check = async (entry: Entry, title: string, body: string) => (await generateText({
      model: checker,
      output: Output.object({ schema: checkSchema }),
      system: checkerInstructions(brief),
      prompt: [`Title: ${title}`, `Body: ${body}`, `Place: ${entry.place?.name ?? `the whole of ${brief.name}`}`, ...sources(entry)].join("\n\n"),
      maxOutputTokens: 4000,
      maxRetries: 2,
    })).output;
    // Four at a time keeps a big run quick without a burst of calls.
    for (let i = 0; i < entries.length; i += 4) {
      await Promise.all(entries.slice(i, i + 4).map(async (entry) => {
        const first = await check(entry, entry.title, entry.body);
        let subject = first;
        const notes = first.problems.map((p) => `Fact-check: ${p}`);
        const passes = (verdict: typeof first) => verdict.supported && verdict.problems.length === 0;
        let outcome: { drop?: string; title?: string; body?: string } = {};
        if (first.restricted) outcome = { drop: "rules" };
        else if (!passes(first)) {
          const { output: fix } = await generateText({
            model: reviser,
            output: Output.object({ schema: reviseSchema }),
            system: reviserInstructions(brief),
            prompt: [`Title: ${entry.title}`, `Body: ${entry.body}`, `Problems:\n${first.problems.map((p) => `- ${p}`).join("\n")}`, ...sources(entry)].join("\n\n"),
            maxOutputTokens: 4000,
            maxRetries: 2,
          });
          if (fix.giveUp || fix.body.trim().split(/\s+/).length < 30) {
            notes.push("Revise: the writer couldn't save it without the faulty parts.");
            outcome = { drop: "fact check" };
          } else {
            const second = await check(entry, fix.title, fix.body);
            notes.push(...second.problems.map((p) => `Fact-check, after revising: ${p}`));
            if (second.restricted) outcome = { drop: "rules" };
            else if (!passes(second)) outcome = { drop: "fact check" };
            else {
              notes.push(`Revise: fixed, and the revision passed. It was: ${entry.title}: ${entry.body}`);
              outcome = { title: fix.title.trim(), body: fix.body.trim() };
            }
            subject = {
              ...first,
              firstNations: first.firstNations || second.firstNations,
              deathOrCrime: first.deathOrCrime || second.deathOrCrime,
              livingPeople: first.livingPeople || second.livingPeople,
            };
          }
        }
        await ctx.runMutation(internal.loreRun.updateEntry, {
          entryId: entry.entryId, sensitive: flags(subject), notes,
          ...(outcome.title ? { title: outcome.title, body: outcome.body } : {}),
          ...(outcome.drop ? { drop: outcome.drop } : {}),
        });
        if (outcome.drop) dropped++;
        else if (outcome.title) revised++;
        else kept++;
      }));
    }
    return { kept, revised, dropped };
  },
});

/** Puts each pin on a walkable street inside the suburb, or scatters the story instead. */
export const checkPins = internalAction({
  args: { osmId: v.number(), run: v.number() },
  returns: v.object({ pinned: v.number(), scattered: v.number() }),
  handler: async (ctx, { osmId, run }): Promise<{ pinned: number; scattered: number }> => {
    const data = await placeData(ctx, osmId);
    let pinned = 0, scattered = 0;
    for (const entry of await ctx.runQuery(internal.loreRun.checking, { osmId, run }) as Entry[]) {
      if (!entry.place) {
        scattered++;
        continue;
      }
      const { pin, note } = placePin(data, entry.place.lat, entry.place.lon, maxPinToStreet);
      await ctx.runMutation(internal.loreRun.updateEntry, {
        entryId: entry.entryId, place: pin ? { name: entry.place.name, ...pin } : null, notes: [`Pins: ${note}`],
      });
      if (pin) pinned++;
      else scattered++;
    }
    return { pinned, scattered };
  },
});
