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
import { isOverBudget, meteredFetch } from "./loreBudget";
import { boundingBox, fetchPage, findQuote, insideBoundary, leadOnly, leadOnlyProblem, placePin, type Page } from "./loreChecks";
import { caps, entries as wanted, holds, maxPinToStreet, models, research as limits, timeLimits } from "./loreConfig";
import {
  angles, categories, checkerInstructions, researchInstructions, reviserInstructions, untrusted, writerInstructions, type Angle, type PlaceBrief,
} from "./lorePrompts";
import { workflow } from "./loreWorkflow";
import { budgetMessage } from "./loreRun";
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
    await step.runAction(internal.lorePipeline.checkQuotes, { osmId, run }, { retry });
    // Doesn't fail on money: what the run can't afford to check is dropped as "budget",
    // and whatever has passed goes on to be published.
    await step.runAction(internal.lorePipeline.factCheck, { osmId, run, wa }, { retry });
    await step.runMutation(internal.loreRun.applyRules, { osmId, run, wa });
    await step.runAction(internal.lorePipeline.checkPins, { osmId, run }, { retry });
    // Named, so `lore:resume` with "from": "stickers" draws the missing ones later.
    const wanting = await step.runQuery(internal.loreRun.needStickers, { osmId, run }, { name: "stickers" });
    // A sticker that keeps failing, or that the run can't afford, leaves its secret
    // without one (the phones show a plain badge). Nothing here stops the run.
    await Promise.all(wanting.map((entry) =>
      step.runAction(internal.loreStickers.draw, { osmId, entryId: entry.entryId, subject: entry.sticker, country }, { retry, name: `sticker ${entry.entryId}` })
        .catch(() => false)));
    return await step.runMutation(internal.loreRun.publish, { osmId, run });
  });

/**
 * OpenRouter, with every call held, sent and settled against the place's budget
 * (loreBudget.meteredFetch). Metering at the fetch catches calls the SDK retries or
 * fails to parse, which still cost money.
 */
function openRouter(ctx: ActionCtx, osmId: number, step: string, onSettled?: (cost: number, runCost: number) => void) {
  const apiKey = env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error("OPENROUTER_API_KEY isn't set");
  return createOpenRouter({ apiKey, compatibility: "strict", fetch: meteredFetch(ctx, osmId, step, onSettled), headers: { "X-Title": "Walkies secrets" } });
}

/** Runs `call` with a signal that aborts it after `ms`, so one slow model call can't
 * run the action into Convex's time limit. */
async function withTimeout<T>(ms: number, call: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await call(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

// Usage accounting puts `usage.cost` in every answer. Anthropic models cache the
// growing research conversation, so each step only pays full price for what's new.
const chatSettings = { usage: { include: true }, cache_control: { type: "ephemeral" as const } };

type Brief = PlaceBrief & { runCost: number };
type Note = { angle: string; fact: string; url: string; quote: string; spot?: { name: string; lat?: number; lon?: number } };
type Entry = {
  entryId: string; title: string; body: string; category: string; place?: { name: string; lat: number; lon: number };
  sticker: string; claims: { text: string; url: string; quote: string; found?: boolean; context?: string }[];
  sensitive: string[]; checkNotes: string[]; factChecked?: boolean;
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
 * what it found. Its thread, with every search and page, is deleted when the run ends.
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
    // What fetch_page showed the agent, so save_note can check quotes against it. Only
    // the newest few pages, as this action has 64 MiB.
    const seen = new Map<string, string>();
    const remember = (url: string, text: string) => {
      seen.delete(url);
      seen.set(url, text);
      while (seen.size > limits.pagesKept * 2) seen.delete(seen.keys().next().value!);
    };

    const tools: ToolSet = {
      // The provider's types only know `engine` and `maxResults`, but OpenRouter also
      // takes a cap on characters per result, and the provider passes `parameters` on as is.
      // max_uses keeps each request to one search, which is what its hold allows for.
      web_search: provider.tools.webSearch({
        parameters: { engine: "exa", max_results: limits.searchResults, max_characters: limits.searchChars, max_uses: holds.searchesPerCall },
      } as { maxResults?: number }),
      fetch_page: tool({
        description: "Reads a web page as plain text. Long pages come in parts: pass `from` to read on.",
        inputSchema: z.object({ url: z.string(), from: z.number().int().min(0).optional() }),
        execute: async ({ url, from = 0 }) => {
          const page: Page = await fetchPage(url);
          if (!page.ok) return { error: `Couldn't read ${url}: ${page.reason}.` };
          remember(url, page.text);
          remember(page.url, page.text);
          const text = page.text.slice(from, from + limits.pageChars);
          const next = from + limits.pageChars < page.text.length ? from + limits.pageChars : undefined;
          return {
            url: page.url,
            page: untrusted(`page from ${page.url}`, `${page.title ? `Title: ${page.title}\n` : ""}${text}`),
            ...(next ? { more: `Call again with from: ${next} to read on.` } : {}),
          };
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
          if (text === undefined) return { error: "Read that page with fetch_page first (again, if it was a while ago), then quote from it." };
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
    const { threadId, thread } = await agent.createThread(ctx, { title: `${brief.name}: ${angle}, run ${run}` });
    await ctx.runMutation(internal.loreRun.saveThread, { osmId, run, threadId });
    const prompt = earlier.length === 0 ? `Start researching ${brief.name}.`
      : `Carry on researching ${brief.name}. You've already saved these notes, so find different ones:\n${earlier.map((n) => `- ${n.fact}`).join("\n")}`;
    let steps = 0;
    try {
      // A step still going at hardTime is cut off; its hold stays spent, and the notes stay saved.
      const result = await withTimeout(limits.hardTime, (abortSignal) =>
        thread.generateText({ prompt, abortSignal, stopWhen: [stepCountIs(limits.maxSteps), () => stopReason() !== null] }));
      steps = result.steps.length;
    } catch (error) {
      if (isOverBudget(error) || Date.now() - state.startedAt < limits.hardTime) throw error;
      return { notes: state.notes, steps, stopped: "out of time" };
    }
    const stopped = stopReason();
    if (stopped !== null && state.runCost >= caps.perRun) throw new Error(stopped);
    return { notes: state.notes, steps, stopped: stopped ?? "finished" };
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

const flagList = (s: { firstNations: boolean; deathOrCrime: boolean; livingPeople: boolean }) => [
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
    const { output } = await withTimeout(timeLimits.write, (abortSignal) => generateText({
      model: openRouter(ctx, osmId, "write").chat(models.write, { usage: { include: true } }),
      output: Output.object({ schema: draftSchema }),
      system: writerInstructions(brief, wanted.most),
      prompt: [
        `Research notes on ${brief.name}:`,
        untrusted("research notes", notes.map((n, i) => [
          `[${i + 1}] (${n.angle}) ${n.fact}`,
          `URL: ${n.url}`,
          `Quote: "${n.quote}"`,
          ...(n.spot ? [`Spot: ${n.spot.name}${n.spot.lat !== undefined ? ` (${n.spot.lat}, ${n.spot.lon})` : ""}`] : []),
        ].join("\n")).join("\n\n")),
        ...(earlier.length ? [`Already in the game for ${brief.name}, so don't repeat them: ${earlier.join("; ")}.`] : []),
      ].join("\n\n"),
      maxOutputTokens: 16_000,
      maxRetries: 1,
      abortSignal,
    }));
    const drafts = output.entries.filter((e) => e.claims.length > 0).slice(0, wanted.most).map((e) => ({
      slug: e.slug, title: e.title.trim(), body: e.body.trim(), category: e.category,
      ...(e.place ? { place: { name: e.place.name, lat: e.place.lat, lon: e.place.lon } } : {}),
      sticker: e.sticker, claims: e.claims, sensitive: flagList(e.sensitive),
    }));
    const ids: string[] = await ctx.runMutation(internal.loreRun.saveDrafts, { osmId, run, suburb: brief.name, drafts });
    return ids.length;
  },
});

/**
 * Opens every page a secret cites and looks for its quote. A quote that isn't there
 * (made up, or from a page that's changed) loses its claim, and so does one that only
 * Wikipedia or a site anyone can write on backs. A secret left with none is dropped;
 * one that lost some goes to the fact-check, which has those facts cut. Dead links
 * count as not there, as they did in the hand runs.
 */
export const checkQuotes = internalAction({
  args: { osmId: v.number(), run: v.number() },
  returns: v.object({ kept: v.number(), dropped: v.number() }),
  handler: async (ctx, { osmId, run }): Promise<{ kept: number; dropped: number }> => {
    // A retried step only looks at the secrets it hadn't got to.
    const entries = (await ctx.runQuery(internal.loreRun.checking, { osmId, run }) as Entry[])
      .filter((entry) => entry.claims.some((claim) => claim.found === undefined));
    const byUrl = new Map<string, string[]>();
    for (const entry of entries) for (const claim of entry.claims) byUrl.set(claim.url, [...byUrl.get(claim.url) ?? [], claim.quote]);
    // Each page once, four at a time, and let go as soon as its quotes are looked for,
    // so this action never holds more than a few pages.
    const results = new Map<string, { opened: false; reason: string } | { opened: true; found: boolean; context?: string }>();
    const key = (url: string, quote: string) => `${url}\n${quote}`;
    const deadline = Date.now() + timeLimits.quotes;
    const urls = [...byUrl.keys()];
    let next = 0;
    await Promise.all(Array.from({ length: 4 }, async () => {
      while (next < urls.length && deadline - Date.now() > 30_000) {
        const url = urls[next++]!;
        // Heritage databases can be slow, so pages get longer than research gave them,
        // and one more go if they time out or the site's busy.
        let opened = await fetchPage(url, 40_000);
        if (!opened.ok && /too long|answered (429|5\d\d)|wouldn't load/.test(opened.reason) && deadline - Date.now() > 45_000) opened = await fetchPage(url, 40_000);
        for (const quote of byUrl.get(url)!) {
          results.set(key(url, quote), opened.ok ? { opened: true, ...findQuote(opened.text, quote) } : { opened: false, reason: opened.reason });
        }
      }
    }));
    let kept = 0, dropped = 0, late = 0;
    for (const entry of entries) {
      if (entry.claims.some((claim) => !results.has(key(claim.url, claim.quote)))) {
        late++;
        continue;
      }
      const notes: string[] = [];
      let claims = entry.claims.map((claim) => {
        const result = results.get(key(claim.url, claim.quote))!;
        if (!result.opened) {
          notes.push(`Quote check: couldn't open ${claim.url} (${result.reason}), so "${claim.text}" lost its source.`);
          return { ...claim, found: false };
        }
        if (!result.found) notes.push(`Quote check: "${claim.quote.slice(0, 120)}" isn't on ${claim.url}.`);
        return { ...claim, found: result.found, ...(result.context ? { context: result.context } : {}) };
      });
      const problem = leadOnlyProblem(claims.filter((c) => c.found).map((c) => c.url));
      if (problem) {
        notes.push(`Quote check: ${problem}`);
        claims = claims.map((claim) => claim.found && leadOnly(claim.url) ? { ...claim, found: false } : claim);
      }
      const none = claims.every((c) => !c.found);
      await ctx.runMutation(internal.loreRun.updateEntry, {
        entryId: entry.entryId, claims, notes, ...(none ? { drop: "quote check" } : {}),
      });
      if (none) dropped++;
      else kept++;
    }
    // Out of time with pages still to read: the step's retry carries on from here.
    if (late > 0) throw new Error(`The quote check ran out of time with ${late} secrets to go`);
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

type Verdict = z.infer<typeof checkSchema>;

/**
 * A model from another lab reads each secret against its quotes. A secret with any
 * problem, or with a claim the quote check couldn't back, goes back to the writer once
 * to cut or soften the words at fault, and the revision is checked again. One that
 * still has problems is dropped.
 *
 * Each secret stands alone: a refusal or an answer that won't parse drops only that
 * one, a secret already passed is skipped when the step is retried, and once the run
 * can't afford another call the rest are dropped as "budget" and the run carries on
 * with what passed. Only when every secret it tried failed does the step fail, which
 * is what an OpenRouter outage looks like, so the workflow tries it again later.
 */
export const factCheck = internalAction({
  args: { osmId: v.number(), run: v.number(), wa: v.boolean() },
  returns: v.object({ kept: v.number(), revised: v.number(), dropped: v.number(), unaffordable: v.number() }),
  handler: async (ctx, { osmId, run, wa }): Promise<{ kept: number; revised: number; dropped: number; unaffordable: number }> => {
    const brief = await placeBrief(ctx, osmId, wa);
    const checker = openRouter(ctx, osmId, "check").chat(models.check, { usage: { include: true } });
    const reviser = openRouter(ctx, osmId, "revise").chat(models.write, { usage: { include: true } });
    const pending = (await ctx.runQuery(internal.loreRun.checking, { osmId, run }) as Entry[]).filter((entry) => !entry.factChecked);
    const deadline = Date.now() + timeLimits.factCheck;
    let kept = 0, revised = 0, dropped = 0, unaffordable = 0, started = 0, succeeded = 0;
    let broke = false;
    const failures: { entry: Entry; error: unknown }[] = [];
    const sources = (entry: Entry) => entry.claims.filter((c) => c.found).map((c, n) => [
      `Source ${n + 1}: ${c.url}`, `Claim: ${c.text}`,
      untrusted(`source ${n + 1} from ${c.url}`, `Quote: "${c.quote}"\nPage text around it: ${c.context ?? c.quote}`),
    ].join("\n"));
    const check = (entry: Entry, title: string, body: string) => withTimeout(timeLimits.check, async (abortSignal) => (await generateText({
      model: checker,
      output: Output.object({ schema: checkSchema }),
      system: checkerInstructions(brief),
      prompt: [`Title: ${title}`, `Body: ${body}`, `Place: ${entry.place?.name ?? `the whole of ${brief.name}`}`, ...sources(entry)].join("\n\n"),
      maxOutputTokens: 4000,
      maxRetries: 1,
      abortSignal,
    })).output);
    const revise = (entry: Entry, problems: string[]) => withTimeout(timeLimits.check, async (abortSignal) => (await generateText({
      model: reviser,
      output: Output.object({ schema: reviseSchema }),
      system: reviserInstructions(brief),
      prompt: [`Title: ${entry.title}`, `Body: ${entry.body}`, `Problems:\n${problems.map((p) => `- ${p}`).join("\n")}`, ...sources(entry)].join("\n\n"),
      maxOutputTokens: 4000,
      maxRetries: 1,
      abortSignal,
    })).output);

    const judge = async (entry: Entry) => {
      // Facts whose claims lost their source have to go, whatever the checker thinks.
      const unsourced = entry.claims.filter((c) => c.found === false).map((c) => `"${c.text}" has no source that could be checked, so it has to go.`);
      const first = await check(entry, entry.title, entry.body);
      const problems = [...unsourced, ...first.problems];
      const notes = problems.map((p) => `Fact-check: ${p}`);
      const passes = (verdict: Verdict, extra: string[] = []) => verdict.supported && verdict.problems.length === 0 && extra.length === 0;
      let flags: Verdict = first;
      let outcome: { drop?: string; title?: string; body?: string } = {};
      if (first.restricted) outcome = { drop: "rules" };
      else if (!passes(first, unsourced)) {
        const fix = await revise(entry, problems);
        if (fix.giveUp || fix.body.trim().split(/\s+/).length < 30) {
          notes.push("Revise: the writer couldn't save it without the faulty parts.");
          outcome = { drop: "fact check" };
        } else {
          const second = await check(entry, fix.title, fix.body);
          notes.push(...second.problems.map((p) => `Fact-check, after revising: ${p}`));
          // Sticky: a flag either look raised stays, as do the writer's and the word list's.
          flags = {
            ...first,
            firstNations: first.firstNations || second.firstNations,
            deathOrCrime: first.deathOrCrime || second.deathOrCrime,
            livingPeople: first.livingPeople || second.livingPeople,
          };
          if (second.restricted) outcome = { drop: "rules" };
          else if (!passes(second)) outcome = { drop: "fact check" };
          else {
            notes.push(`Revise: fixed, and the revision passed. It was: ${entry.title}: ${entry.body}`);
            outcome = { title: fix.title.trim(), body: fix.body.trim() };
          }
        }
      }
      await ctx.runMutation(internal.loreRun.updateEntry, {
        entryId: entry.entryId, sensitive: flagList(flags), notes,
        ...(outcome.title ? { title: outcome.title, body: outcome.body } : {}),
        ...(outcome.drop ? { drop: outcome.drop } : { factChecked: true }),
      });
      if (outcome.drop) dropped++;
      else if (outcome.title) revised++;
      else kept++;
    };

    // Four at a time keeps a big run quick without a burst of calls.
    for (let i = 0; i < pending.length && !broke && Date.now() < deadline; i += 4) {
      const batch = pending.slice(i, i + 4);
      started += batch.length;
      await Promise.all(batch.map(async (entry) => {
        try {
          await judge(entry);
          succeeded++;
        } catch (error) {
          if (isOverBudget(error)) broke = true;
          failures.push({ entry, error });
        }
      }));
    }
    const notStarted = pending.slice(started);
    if (!broke && succeeded === 0 && failures.length > 0) throw failures[0]!.error;
    for (const { entry, error } of failures) {
      const money = isOverBudget(error);
      await ctx.runMutation(internal.loreRun.updateEntry, {
        entryId: entry.entryId, drop: money ? "budget" : "fact check",
        notes: [money ? "Fact-check: the run reached its spending limit before this was checked." : `Fact-check: the checker's answer couldn't be used (${String(error).slice(0, 160)}).`],
      });
      if (money) unaffordable++;
      else dropped++;
    }
    if (broke) {
      for (const entry of notStarted) {
        await ctx.runMutation(internal.loreRun.updateEntry, { entryId: entry.entryId, drop: "budget", notes: ["Fact-check: the run reached its spending limit before this was checked."] });
        unaffordable++;
      }
    } else if (notStarted.length > 0) {
      // Out of time: the step's retry skips everything already decided.
      throw new Error(`The fact-check ran out of time with ${notStarted.length} secrets to go`);
    }
    return { kept, revised, dropped, unaffordable };
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
