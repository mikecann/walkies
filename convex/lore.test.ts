/// <reference types="vite/client" />
// @ts-expect-error Convex's tsconfig has no Node types; the tests run in Node, which has zlib.
import zlibModule from "node:zlib";
import { convexTest } from "convex-test";
import workflowTest from "@convex-dev/workflow/test";
import { afterEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { findQuote, placePin, sensitiveWords } from "./loreChecks";
import { cutOut, decodePng, encodePng } from "./loreCutout";
import schema from "./schema";

// Secrets for new suburbs: the trigger, the caps, the checks and what the phones get.
// OpenRouter and every web page are mocked; nothing here goes to the network.

const modules = import.meta.glob(["./**/*.{ts,js}", "!./**/*.test.ts"]);
type T = ReturnType<typeof convexTest>;
const somewhere = 4242;
const geographe = 11688696;

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

type ChatRequest = { model: string; messages: { role: string; content: string }[] };

/** Pages by URL, and OpenRouter's answer to each request. Anything else is a 404. */
function mockWeb(pages: Record<string, string>, answer: (request: ChatRequest) => unknown = () => { throw new Error("No OpenRouter here"); }) {
  const calls: ChatRequest[] = [];
  vi.stubGlobal("fetch", vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.startsWith("https://openrouter.ai/")) {
      const request = JSON.parse(String(init?.body)) as ChatRequest;
      calls.push(request);
      return new Response(JSON.stringify(chatCompletion(answer(request))), { headers: { "Content-Type": "application/json" } });
    }
    if (url in pages) return new Response(pages[url], { headers: { "Content-Type": "text/html; charset=utf-8" } });
    return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain" } });
  }));
  return calls;
}

/** OpenRouter's chat completion, with its usage accounting, answering with `output` as JSON. */
function chatCompletion(output: unknown) {
  return {
    id: "gen-test", object: "chat.completion", created: 1_800_000_000, model: "openai/gpt-5.6-terra", provider: "OpenAI",
    choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content: JSON.stringify(output) } }],
    usage: { prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100, cost: 0.0125 },
  };
}

async function setup() {
  vi.useFakeTimers();
  const t = convexTest(schema, modules);
  workflowTest.register(t, "workflow");
  mockWeb({});
  const [aliceId, bobId] = await t.run((ctx) => Promise.all([
    ctx.db.insert("users", { name: "Alice" }), ctx.db.insert("users", { name: "Bob" }),
  ]));
  return { t, aliceId, bobId, alice: t.withIdentity({ subject: aliceId }), bob: t.withIdentity({ subject: bobId }) };
}

/** A finished walk, so the person has walked somewhere. */
async function walked(t: T, userId: Id<"users">) {
  await t.run(async (ctx) => {
    const file = await ctx.storage.store(new Blob(["{}"]));
    await ctx.db.insert("walks", { userId, clientId: `walk-${userId}`, startedAt: 0, endedAt: 1, distance: 800, newTiles: 6, file });
  });
}

/** Saves a place the way the phones do: the city file to storage, then sync:savePlace. */
async function savePlace(t: T, client: ReturnType<T["withIdentity"]>, osmId: number, visited: number, updatedAt = Date.now()) {
  const city = { id: "P", name: "Somewhere", detail: "Somewhere, Western Australia, Australia", osmId, visited: Array.from({ length: visited }, (_, i) => [i, 0]) };
  const file = await t.run((ctx) => ctx.storage.store(new Blob([JSON.stringify(city)])));
  await client.mutation(api.sync.savePlace, { gridVersion: 2, clientId: `place-${osmId}`, name: "Somewhere", createdAt: 0, updatedAt, file });
}

/** Runs what savePlace scheduled (lore.readPlace), but not the workflow it may start. */
async function runScheduled(t: T) {
  vi.runOnlyPendingTimers();
  await t.finishInProgressScheduledFunctions();
}

const lorePlaces = (t: T) => t.run((ctx) => ctx.db.query("lorePlaces").collect());

async function addPlace(t: T, fields: Partial<Doc<"lorePlaces">> = {}) {
  return await t.run((ctx) => ctx.db.insert("lorePlaces", {
    osmId: somewhere, name: "Somewhere", status: "researching", version: 0, attempts: 1, queuedAt: 0, cost: 0, runCost: 0, ...fields,
  }));
}

type EntryFields = Partial<Doc<"loreEntries">> & { slug: string };
async function addEntry(t: T, { slug, ...fields }: EntryFields) {
  return await t.run((ctx) => ctx.db.insert("loreEntries", {
    osmId: somewhere, run: 1, entryId: `osm${somewhere}-${slug}`, title: slug, body: "The jetty here was built in 1865 and is 1,841 m long.",
    category: "history", sticker: "A little jetty", sources: ["https://example.org/jetty"], suburb: "Somewhere",
    claims: [{ text: "Built in 1865", url: "https://example.org/jetty", quote: "construction commenced in 1864 and the first section opened in 1865", found: true }],
    sensitive: [], review: "checking", checkNotes: [], ...fields,
  }));
}

describe("what starts research", () => {
  test("a walked place is queued once and starts a run", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const { t, aliceId, alice } = await setup();
    await walked(t, aliceId);
    await savePlace(t, alice, somewhere, 5);
    await runScheduled(t);
    let rows = await lorePlaces(t);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ osmId: somewhere, status: "researching", attempts: 1, workflowId: expect.any(String) });
    // The place remembers its relation, so the next save doesn't even read the file.
    const place = await t.run((ctx) => ctx.db.query("places").first());
    expect(place?.osmId).toBe(somewhere);
    await savePlace(t, alice, somewhere, 9, Date.now() + 1000);
    await runScheduled(t);
    rows = await lorePlaces(t);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.attempts).toBe(1);
  });

  test("two people walking the same new suburb start one run", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const { t, aliceId, bobId, alice, bob } = await setup();
    await walked(t, aliceId);
    await walked(t, bobId);
    await savePlace(t, alice, somewhere, 5);
    await savePlace(t, bob, somewhere, 7);
    await runScheduled(t);
    const rows = await lorePlaces(t);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.attempts).toBe(1);
    const bobsPlace = await t.run((ctx) => ctx.db.query("places").filter((q) => q.eq(q.field("userId"), bobId)).first());
    expect(await t.mutation(internal.lore.noteWalked, { userId: bobId, placeId: bobsPlace!._id, osmId: somewhere, name: "Somewhere", walkedTiles: 7 }))
      .toBe("known");
  });

  test("a place with bundled secrets is skipped", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const { t, aliceId, alice } = await setup();
    await walked(t, aliceId);
    await savePlace(t, alice, geographe, 30);
    await runScheduled(t);
    expect(await lorePlaces(t)).toHaveLength(0);
  });

  test("adding a place isn't enough: it has to be walked, by someone with a saved walk", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const { t, aliceId, alice } = await setup();
    await savePlace(t, alice, somewhere, 5);
    await runScheduled(t);
    expect(await lorePlaces(t)).toHaveLength(0);
    await walked(t, aliceId);
    await savePlace(t, alice, somewhere, 1, Date.now() + 1000);
    await runScheduled(t);
    expect(await lorePlaces(t)).toHaveLength(0);
    await savePlace(t, alice, somewhere, 3, Date.now() + 2000);
    await runScheduled(t);
    expect(await lorePlaces(t)).toHaveLength(1);
  });

  test("one person's walks start at most three new suburbs a day", async () => {
    vi.stubEnv("LORE_AUTO", "1");
    const { t, aliceId } = await setup();
    await walked(t, aliceId);
    const placeId = await t.run(async (ctx) => ctx.db.insert("places", {
      userId: aliceId, clientId: "p", name: "p", createdAt: 0, updatedAt: 0, file: await ctx.storage.store(new Blob(["{}"])),
    }));
    const note = (osmId: number) => t.mutation(internal.lore.noteWalked, { userId: aliceId, placeId, osmId, name: "p", walkedTiles: 5 });
    expect([await note(1), await note(2), await note(3), await note(4)]).toEqual(["queued", "queued", "queued", "too many"]);
    vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
    expect(await note(4)).toBe("queued");
  });

  test("with the switch off, saving a place does nothing and walked places aren't started", async () => {
    const { t, aliceId, alice } = await setup();
    await walked(t, aliceId);
    await savePlace(t, alice, somewhere, 5);
    expect(await t.run((ctx) => ctx.db.system.query("_scheduled_functions").collect())).toHaveLength(0);
    const place = await t.run((ctx) => ctx.db.query("places").first());
    expect(await t.mutation(internal.lore.noteWalked, { userId: aliceId, placeId: place!._id, osmId: somewhere, name: "Somewhere", walkedTiles: 5 }))
      .toBe("off");
    // A place a walk queued before the switch went off waits; one asked for by hand doesn't.
    await addPlace(t, { status: "queued" });
    await t.mutation(internal.lore.tick, {});
    expect((await lorePlaces(t))[0]!.status).toBe("queued");
    expect(await t.mutation(internal.lore.queueManual, { osmId: somewhere })).toBe("started");
  });
});

describe("spending caps", () => {
  const today = () => new Date().toISOString().slice(0, 10);

  test("a run stops at its own limit and isn't retried by itself", async () => {
    const { t } = await setup();
    await addPlace(t, { runCost: 5.5, workflowId: "w" });
    expect(await t.query(internal.loreRun.checkBudget, { osmId: somewhere })).toBe(5.5);
    expect(await t.mutation(internal.loreRun.recordSpend, { osmId: somewhere, step: "research", cost: 0.6 })).toBeCloseTo(6.1);
    await expect(t.query(internal.loreRun.checkBudget, { osmId: somewhere })).rejects.toThrow(/Over budget/);
    await t.mutation(internal.lore.runFinished, {
      workflowId: "w" as never, result: { kind: "failed", error: "Over budget: this run has spent $6.10, and stops at $6." }, context: { osmId: somewhere, run: 1 },
    });
    const row = (await lorePlaces(t))[0]!;
    expect(row.status).toBe("failed");
    expect(row.retryAt).toBeUndefined();
    const spend = await t.run((ctx) => ctx.db.query("loreSpend").collect());
    expect(spend).toMatchObject([{ day: today(), osmId: somewhere, step: "research", calls: 1 }]);
  });

  test("a run that would take today over the daily cap waits for tomorrow", async () => {
    const { t } = await setup();
    await t.run((ctx) => ctx.db.insert("loreSpend", { day: today(), osmId: 1, step: "research", cost: 9.5, calls: 40 }));
    expect(await t.mutation(internal.lore.queueManual, { osmId: somewhere })).toBe("queued (held by the daily cap)");
    expect((await lorePlaces(t))[0]).toMatchObject({ status: "queued", held: "daily cap" });
    // Tomorrow (well within the month) the hourly tick starts it.
    vi.setSystemTime(new Date(`${today()}T12:00:00Z`).getTime() + 24 * 60 * 60 * 1000);
    if (new Date().getUTCDate() === 1) vi.setSystemTime(Date.now() + 24 * 60 * 60 * 1000);
    await t.mutation(internal.lore.tick, {});
    const row = (await lorePlaces(t))[0]!;
    expect(row.status).toBe("researching");
    expect(row.held).toBeUndefined();
  });

  test("runs already going count as if they'll spend their whole limit", async () => {
    const { t } = await setup();
    await addPlace(t, { osmId: 1, runCost: 0.5 });
    await t.run((ctx) => ctx.db.insert("loreSpend", { day: today(), osmId: 1, step: "research", cost: 4, calls: 10 }));
    // 4 spent + 5.50 the running one could still spend + 6 for a new one is over 15.
    expect(await t.mutation(internal.lore.queueManual, { osmId: somewhere })).toBe("queued (held by the daily cap)");
  });

  test("the monthly cap holds runs too", async () => {
    const { t } = await setup();
    const month = today().slice(0, 7);
    const otherDay = today().endsWith("-01") ? `${month}-02` : `${month}-01`;
    await t.run((ctx) => ctx.db.insert("loreSpend", { day: otherDay, osmId: 1, step: "research", cost: 45, calls: 200 }));
    expect(await t.mutation(internal.lore.queueManual, { osmId: somewhere })).toBe("queued (held by the monthly cap)");
  });
});

describe("the checks", () => {
  const page = `<html><head><title>Jetty</title><script>var x = "construction";</script></head><body>
    <nav>Home | About</nav><p>The jetty&#8217;s construction commenced in 1864 and the first section opened in 1865.</p>
    <p>It is now 1,841&nbsp;metres long, making it the longest timber-piled jetty in the Southern Hemisphere.</p></body></html>`;

  test("quotes match through curly apostrophes, entities and ellipses, and nothing shorter or made up does", () => {
    const text = page.replace(/<[^>]+>/g, " ").replace(/&#8217;/g, "’").replace(/&nbsp;/g, " ");
    expect(findQuote(text, "The jetty's construction commenced in 1864").found).toBe(true);
    expect(findQuote(text, "construction commenced in 1864 ... longest timber-piled jetty").found).toBe(true);
    expect(findQuote(text, "The jetty").found).toBe(false);
    expect(findQuote(text, "construction commenced in 1858 and the first section opened").found).toBe(false);
  });

  test("the quote check drops a made-up quote, and a secret left with no real ones", async () => {
    const { t } = await setup();
    mockWeb({ "https://example.org/jetty": page });
    await addPlace(t);
    await addEntry(t, {
      slug: "half-made-up",
      claims: [
        { text: "Built in 1865", url: "https://example.org/jetty", quote: "construction commenced in 1864 and the first section opened in 1865" },
        { text: "A ghost", url: "https://example.org/jetty", quote: "the jetty is haunted by the ghost of a lighthouse keeper" },
      ],
    });
    await addEntry(t, {
      slug: "all-made-up",
      claims: [
        { text: "Famous", url: "https://example.org/jetty", quote: "the most photographed jetty in the whole of Australia" },
        { text: "Dead link", url: "https://example.org/gone", quote: "a page that no longer exists anywhere at all" },
      ],
    });
    expect(await t.action(internal.lorePipeline.checkQuotes, { osmId: somewhere, run: 1 })).toEqual({ kept: 1, dropped: 1 });
    const [half, all] = await t.run((ctx) => ctx.db.query("loreEntries").collect());
    expect(half).toMatchObject({ review: "checking", sources: ["https://example.org/jetty"] });
    expect(half!.claims.map((c) => c.found)).toEqual([true, false]);
    expect(half!.claims[0]!.context).toContain("1,841 metres");
    expect(half!.checkNotes).toEqual([expect.stringContaining("haunted")]);
    expect(all).toMatchObject({ review: "dropped", droppedBy: "quote check" });
    expect(all!.checkNotes).toEqual(expect.arrayContaining([expect.stringContaining("the site answered 404")]));
  });

  test("the fact-checker passes good secrets, gets others revised once, drops the rest, and every call's cost is recorded", async () => {
    const { t } = await setup();
    vi.stubEnv("OPENROUTER_API_KEY", "test-key");
    const verdict = (problems: string[], deathOrCrime = false) =>
      ({ supported: problems.length === 0, problems, firstNations: false, deathOrCrime, livingPeople: false, restricted: false });
    const calls = mockWeb({}, ({ model, messages }) => {
      const prompt = messages.at(-1)!.content;
      if (model === "anthropic/claude-opus-5.5") {
        return prompt.includes("Title: a-tall-tale")
          ? { title: "A Long Jetty", body: "The jetty here was built in 1865. It is 1,841 m long, which makes it the longest timber-piled jetty in the Southern Hemisphere, and you can walk the whole of it.", giveUp: false }
          : { title: "x", body: "x", giveUp: true };
      }
      if (prompt.includes("Title: a-true-one")) return verdict([], true);
      if (prompt.includes("Title: A Long Jetty")) return verdict([]);
      return verdict(["\"longest in the world\" isn't in the source"]);
    });
    await addPlace(t, { country: "au" });
    await addEntry(t, { slug: "a-true-one" });
    await addEntry(t, { slug: "a-tall-tale", body: "The longest jetty in the world." });
    await addEntry(t, { slug: "a-lost-cause", body: "The longest jetty in the world, built by giants." });
    expect(await t.action(internal.lorePipeline.factCheck, { osmId: somewhere, run: 1, wa: true })).toEqual({ kept: 1, revised: 1, dropped: 1 });
    // The checker is OpenAI's and the reviser Anthropic's, so they don't share blind spots.
    expect(calls.map((c) => c.model).sort()).toEqual([
      "anthropic/claude-opus-5.5", "anthropic/claude-opus-5.5",
      "openai/gpt-5.6-terra", "openai/gpt-5.6-terra", "openai/gpt-5.6-terra", "openai/gpt-5.6-terra",
    ]);
    const [good, fixed, lost] = await t.run((ctx) => ctx.db.query("loreEntries").collect());
    expect(good).toMatchObject({ review: "checking", sensitive: ["death-or-crime"], title: "a-true-one" });
    expect(fixed).toMatchObject({ review: "checking", title: "A Long Jetty" });
    expect(fixed!.checkNotes.at(-1)).toMatch(/^Revise: fixed/);
    expect(lost).toMatchObject({ review: "dropped", droppedBy: "fact check" });
    const spend = await t.run((ctx) => ctx.db.query("loreSpend").collect());
    expect(Object.fromEntries(spend.map((s) => [s.step, s.calls]))).toEqual({ check: 4, revise: 2 });
    expect((await lorePlaces(t))[0]!.runCost).toBeCloseTo(6 * 0.0125);
  });

  test("sensitive secrets wait for review and the rest go live", async () => {
    const { t } = await setup();
    await addPlace(t);
    await addEntry(t, { slug: "the-jetty" });
    await addEntry(t, { slug: "the-tuarts", category: "nature", body: "Tuart trees only grow on coastal limestone near here." });
    await addEntry(t, { slug: "the-wreck", body: "Three crew drowned when the barque ran aground off the beach in 1876." });
    await addEntry(t, { slug: "the-mayor", body: "The mayor still swims here every morning.", sensitive: ["living-people"] });
    // First Nations stories: only in WA, and only from the approved sources.
    await addEntry(t, { slug: "the-name", category: "first-nations", body: "The Noongar name means place of the digging stick.", sources: ["https://busselton.wa.gov.au/names"] });
    await addEntry(t, { slug: "the-blog", category: "history", body: "A Wardandi camp was here, a blog says.", sources: ["https://someblog.example.com/post"] });
    await t.mutation(internal.loreRun.applyRules, { osmId: somewhere, run: 1, wa: true });
    expect(await t.mutation(internal.loreRun.publish, { osmId: somewhere, run: 1 })).toEqual({ live: 2, pending: 3, dropped: 1, status: "ready" });
    const reviews = Object.fromEntries((await t.run((ctx) => ctx.db.query("loreEntries").collect())).map((e) => [e.entryId.split("-").slice(1).join("-"), e.review]));
    expect(reviews).toEqual({ "the-jetty": "auto", "the-tuarts": "auto", "the-wreck": "pending", "the-mayor": "pending", "the-name": "pending", "the-blog": "dropped" });
    expect((await lorePlaces(t))[0]).toMatchObject({ status: "ready", version: 1 });
  });

  test("outside WA, First Nations stories are left out", async () => {
    const { t } = await setup();
    await addPlace(t);
    await addEntry(t, { slug: "the-name", category: "first-nations", body: "The name is Aboriginal.", sources: ["https://www.planning.wa.gov.au/x"] });
    await t.mutation(internal.loreRun.applyRules, { osmId: somewhere, run: 1, wa: false });
    expect((await t.run((ctx) => ctx.db.query("loreEntries").first()))).toMatchObject({ review: "dropped", droppedBy: "rules" });
  });

  test("a suburb with fewer than three secrets is quiet, and gets one more look in 90 days", async () => {
    const { t } = await setup();
    await addPlace(t);
    await addEntry(t, { slug: "the-only-one" });
    expect((await t.mutation(internal.loreRun.publish, { osmId: somewhere, run: 1 })).status).toBe("quiet");
    const row = (await lorePlaces(t))[0]!;
    expect(row.status).toBe("quiet");
    expect(row.retryAt! - Date.now()).toBe(90 * 24 * 60 * 60 * 1000);
  });

  test("pins go onto the nearest walkable street inside the suburb, or the story is scattered", () => {
    // A 0.01° square with one street along its middle.
    const data = {
      boundary: [[[[115, -33], [115.01, -33], [115.01, -33.01], [115, -33.01], [115, -33]]]],
      ways: [{ highway: "residential", points: [[-33.005, 115.001], [-33.005, 115.009]] }],
    };
    const near = placePin(data, -33.0058, 115.005, 300);
    expect(near.pin).toEqual({ lat: -33.005, lon: 115.005 });
    expect(near.note).toMatch(/moved 88 m/);
    expect(placePin(data, -33.02, 115.005, 300).pin).toBeNull();
    expect(placePin(data, -33.0095, 115.005, 300).pin).toBeNull();
  });

  test("death, crime and First Nations words send a story for review", () => {
    expect(sensitiveWords("The barque was wrecked and two crew drowned.")).toEqual(["death-or-crime"]);
    expect(sensitiveWords("Wardandi people fished here.")).toEqual(["first-nations"]);
    expect(sensitiveWords("The jetty is 1,841 m long.")).toEqual([]);
  });

  test("a sticker on a plain background is cut out to a transparent square", () => {
    const zlib = zlibModule as { inflateSync(d: Uint8Array): Uint8Array; deflateSync(d: Uint8Array): Uint8Array };
    const z = { inflate: (d: Uint8Array) => new Uint8Array(zlib.inflateSync(d)), deflate: (d: Uint8Array) => new Uint8Array(zlib.deflateSync(d)) };
    const size = 200;
    const rgba = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const inSticker = x >= 50 && x < 150 && y >= 60 && y < 140;
        const inArt = x >= 58 && x < 142 && y >= 68 && y < 132;
        rgba.set(inArt ? [200, 40, 40, 255] : inSticker ? [255, 255, 255, 255] : [184, 198, 210, 255], (y * size + x) * 4);
      }
    }
    const raw = decodePng(encodePng({ width: size, height: size, rgba }, z), z);
    expect(raw.rgba).toEqual(rgba);
    const cut = cutOut(raw, 64)!;
    expect(cut.width).toBe(64);
    expect(cut.rgba[3]).toBe(0);
    const centre = (32 * 64 + 32) * 4;
    expect([...cut.rgba.subarray(centre, centre + 4)]).toEqual([200, 40, 40, 255]);
    // A photo with no plain background isn't a sticker.
    const noise = new Uint8Array(size * size * 4).map((_, i) => (i % 4 === 3 ? 255 : (i * 7919) % 256));
    expect(cutOut({ width: size, height: size, rgba: noise })).toBeNull();
  });
});

describe("what the phones get", () => {
  test("forPlace returns live secrets with their stickers, never pending, hidden or dropped ones", async () => {
    const { t, alice } = await setup();
    await addPlace(t, { status: "ready", version: 3 });
    const stickerFile = await t.run((ctx) => ctx.storage.store(new Blob(["png"], { type: "image/png" })));
    await addEntry(t, { slug: "a-live-one", review: "auto", stickerFile, place: { name: "The jetty", lat: -33.6, lon: 115.3 } });
    await addEntry(t, { slug: "b-approved", review: "approved" });
    await addEntry(t, { slug: "c-pending", review: "pending" });
    await addEntry(t, { slug: "d-hidden", review: "hidden" });
    await addEntry(t, { slug: "e-dropped", review: "dropped" });
    const result = await alice.query(api.lore.forPlace, { osmId: somewhere });
    expect(result.status).toBe("ready");
    expect(result.version).toBe(3);
    expect(result.entries.map((e) => e.id)).toEqual([`osm${somewhere}-a-live-one`, `osm${somewhere}-b-approved`]);
    // The same shape as the bundled LoreEntry JSON, plus the sticker's URL.
    expect(result.entries[0]).toEqual({
      id: `osm${somewhere}-a-live-one`, title: "a-live-one", body: expect.any(String), category: "history",
      place: { name: "The jetty", lat: -33.6, lon: 115.3 }, sticker: "A little jetty", sources: ["https://example.org/jetty"],
      suburb: "Somewhere", stickerUrl: expect.stringMatching(/^https?:\/\//),
    });
    expect(result.entries[1]).not.toHaveProperty("place");
    expect(result.entries[1]!.stickerUrl).toBeNull();

    await t.mutation(internal.lore.approve, { entryId: `osm${somewhere}-c-pending` });
    await t.mutation(internal.lore.hide, { entryId: `osm${somewhere}-a-live-one` });
    const after = await alice.query(api.lore.forPlace, { osmId: somewhere });
    expect(after.entries.map((e) => e.id)).toEqual([`osm${somewhere}-b-approved`, `osm${somewhere}-c-pending`]);
    expect(after.version).toBe(5);
    expect(await t.query(internal.lore.pending, {})).toEqual([]);
  });

  test("forPlace says when there's nothing yet, when the app has its own, and needs sign-in", async () => {
    const { t, alice } = await setup();
    expect(await alice.query(api.lore.forPlace, { osmId: somewhere })).toEqual({ status: "none", version: 0, entries: [] });
    expect(await alice.query(api.lore.forPlace, { osmId: geographe })).toEqual({ status: "bundled", version: 0, entries: [] });
    await expect(t.query(api.lore.forPlace, { osmId: somewhere })).rejects.toThrow(/Not signed in/);
  });
});
