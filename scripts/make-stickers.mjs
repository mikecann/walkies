// Makes sticker art for every lore entry that doesn't have any yet.
// Needs OPENROUTER_API_KEY. Usage: node scripts/make-stickers.mjs Walkies/Lore/geographe.json
// Each sticker is drawn by Gemini 3 Pro Image (about 14 US cents each), cut out with
// Vision by cutout.swift, and saved into the asset catalog as sticker-<id>.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const loreFile = process.argv[2];
const entries = JSON.parse(fs.readFileSync(loreFile, "utf8"));
const catalog = "Walkies/Assets.xcassets/Stickers";
const work = fs.mkdtempSync(path.join(os.tmpdir(), "stickers-"));
fs.mkdirSync(catalog, { recursive: true });
fs.writeFileSync(`${catalog}/Contents.json`, JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2));

const prompt = (subject) => `A cute die-cut vinyl sticker of ${subject}.
Style: flat vector illustration with soft cel shading and bold, clean dark outlines, a warm sunny Australian coastal palette, friendly and a bit playful, like a souvenir sticker from a beach town gift shop. A thick even white border runs around the whole outside of the shape, like a real die-cut sticker. No text, no letters, no numbers anywhere.
The sticker sits alone in the centre of a plain, flat, solid light blue-grey background with nothing else in the image, no shadow on the background. Square image.`;

async function draw(entry) {
  const set = `${catalog}/sticker-${entry.id}.imageset`;
  if (fs.existsSync(`${set}/sticker.png`)) return `${entry.id}: already done`;
  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.OPENROUTER_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "google/gemini-3-pro-image",
      modalities: ["image", "text"],
      image_config: { aspect_ratio: "1:1" },
      messages: [{ role: "user", content: prompt(entry.sticker) }],
    }),
  });
  const json = await res.json();
  const url = json.choices?.[0]?.message?.images?.[0]?.image_url?.url;
  if (!url) return `${entry.id}: FAILED ${JSON.stringify(json).slice(0, 200)}`;
  const raw = path.join(work, `${entry.id}.png`);
  fs.writeFileSync(raw, Buffer.from(url.split(",")[1], "base64"));
  fs.mkdirSync(set, { recursive: true });
  execFileSync("swift", ["scripts/cutout.swift", raw, `${set}/sticker.png`, "512"], { stdio: "ignore" });
  fs.writeFileSync(`${set}/Contents.json`, JSON.stringify({
    images: [{ filename: "sticker.png", idiom: "universal" }],
    info: { author: "xcode", version: 1 },
  }, null, 2));
  return `${entry.id}: ok ($${json.usage?.cost?.toFixed(3)})`;
}

// A few at a time, to be kind to the API.
for (let i = 0; i < entries.length; i += 6) {
  const results = await Promise.all(entries.slice(i, i + 6).map((e) => draw(e).catch((err) => `${e.id}: FAILED ${err}`)));
  results.forEach((r) => console.log(r));
}
