// Lifting a sticker off its plain background, on the server, with no image library.
// The sticker prompt asks for a flat light blue-grey background and a thick white
// border, so a flood fill in from the edges finds the background and stops at the
// border. This does what scripts/cutout.swift does with Vision on a Mac.
//
// Plain functions over RGBA pixels. zlib comes in from the Node action
// (loreStickers.ts), so the tests can run this too.

export type Zlib = { inflate: (data: Uint8Array) => Uint8Array; deflate: (data: Uint8Array) => Uint8Array };
export type Image = { width: number; height: number; rgba: Uint8Array };

const signature = [137, 80, 78, 71, 13, 10, 26, 10];

/** Decodes an 8-bit, non-interlaced PNG, which is what Gemini sends back. */
export function decodePng(bytes: Uint8Array, zlib: Zlib): Image {
  if (!signature.every((b, i) => bytes[i] === b)) throw new Error("Not a PNG");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let width = 0, height = 0, depth = 0, type = 0, interlace = 0;
  let palette: Uint8Array | null = null;
  let alphas: Uint8Array | null = null;
  const data: Uint8Array[] = [];
  for (let at = 8; at + 8 <= bytes.length;) {
    const length = view.getUint32(at);
    const name = String.fromCharCode(...bytes.subarray(at + 4, at + 8));
    const chunk = bytes.subarray(at + 8, at + 8 + length);
    if (name === "IHDR") {
      width = view.getUint32(at + 8);
      height = view.getUint32(at + 12);
      depth = chunk[8]!;
      type = chunk[9]!;
      interlace = chunk[12]!;
    } else if (name === "PLTE") palette = chunk;
    else if (name === "tRNS") alphas = chunk;
    else if (name === "IDAT") data.push(chunk);
    else if (name === "IEND") break;
    at += 12 + length;
  }
  const channels = ({ 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 } as Record<number, number>)[type];
  if (depth !== 8 || channels === undefined || interlace !== 0) throw new Error(`Unsupported PNG (depth ${depth}, type ${type})`);
  const joined = new Uint8Array(data.reduce((n, d) => n + d.length, 0));
  data.reduce((at, d) => (joined.set(d, at), at + d.length), 0);
  const raw = zlib.inflate(joined);
  const stride = width * channels;
  const pixels = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)]!;
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const out = pixels.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? out[x - channels]! : 0;
      const b = prev ? prev[x]! : 0;
      const c = prev && x >= channels ? prev[x - channels]! : 0;
      const v = line[x]!;
      out[x] = filter === 0 ? v : filter === 1 ? v + a : filter === 2 ? v + b
        : filter === 3 ? v + ((a + b) >> 1) : v + paeth(a, b, c);
    }
  }
  const rgba = new Uint8Array(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    const p = i * channels;
    if (type === 6) rgba.set(pixels.subarray(p, p + 4), i * 4);
    else if (type === 2) rgba.set([pixels[p]!, pixels[p + 1]!, pixels[p + 2]!, 255], i * 4);
    else if (type === 0) rgba.set([pixels[p]!, pixels[p]!, pixels[p]!, 255], i * 4);
    else if (type === 4) rgba.set([pixels[p]!, pixels[p]!, pixels[p]!, pixels[p + 1]!], i * 4);
    else {
      const index = pixels[p]!;
      rgba.set([palette?.[index * 3] ?? 0, palette?.[index * 3 + 1] ?? 0, palette?.[index * 3 + 2] ?? 0, alphas?.[index] ?? 255], i * 4);
    }
  }
  return { width, height, rgba };
}

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of bytes) c = crcTable[(c ^ b) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** An RGBA PNG. Each row gets whichever filter makes it smallest, as most encoders do. */
export function encodePng(image: Image, zlib: Zlib): Uint8Array<ArrayBuffer> {
  const { width, height, rgba } = image;
  const stride = width * 4;
  const raw = new Uint8Array((stride + 1) * height);
  const candidate = new Uint8Array(stride);
  for (let y = 0; y < height; y++) {
    const line = rgba.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? rgba.subarray((y - 1) * stride, y * stride) : null;
    let bestFilter = 0, bestScore = Infinity;
    let best = new Uint8Array(line);
    for (let filter = 0; filter <= 4; filter++) {
      let score = 0;
      for (let x = 0; x < stride; x++) {
        const a = x >= 4 ? line[x - 4]! : 0;
        const b = prev ? prev[x]! : 0;
        const c = prev && x >= 4 ? prev[x - 4]! : 0;
        const predicted = filter === 0 ? 0 : filter === 1 ? a : filter === 2 ? b : filter === 3 ? (a + b) >> 1 : paeth(a, b, c);
        const v = (line[x]! - predicted) & 0xff;
        candidate[x] = v;
        score += v < 128 ? v : 256 - v;
      }
      if (score < bestScore) {
        bestScore = score;
        bestFilter = filter;
        best = new Uint8Array(candidate);
      }
    }
    raw[y * (stride + 1)] = bestFilter;
    raw.set(best, y * (stride + 1) + 1);
  }
  const chunk = (name: string, body: Uint8Array) => {
    const out = new Uint8Array(12 + body.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, body.length);
    out.set([...name].map((ch) => ch.charCodeAt(0)), 4);
    out.set(body, 8);
    view.setUint32(8 + body.length, crc32(out.subarray(4, 8 + body.length)));
    return out;
  };
  const header = new Uint8Array(13);
  const hv = new DataView(header.buffer);
  hv.setUint32(0, width);
  hv.setUint32(4, height);
  header.set([8, 6, 0, 0, 0], 8);
  const parts = [new Uint8Array(signature), chunk("IHDR", header), chunk("IDAT", zlib.deflate(raw)), chunk("IEND", new Uint8Array())];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  parts.reduce((at, p) => (out.set(p, at), at + p.length), 0);
  return out;
}

const distance = (a: Uint8Array, i: number, r: number, g: number, b: number) =>
  Math.hypot(a[i]! - r, a[i + 1]! - g, a[i + 2]! - b);

// Colour distances (0 to 441). Background within `near` of the edge colour goes; a soft
// gradient or vignette can drift up to `far` as long as each step is tiny. Pixels just
// past `near` along the cut edge go see-through in part, so the edge isn't jagged.
const near = 34, far = 64, step = 7, feather = 40;

/**
 * The sticker on a transparent square `size` pixels across, trimmed with a 3% margin
 * like cutout.swift. Null when it doesn't look like a sticker on a plain background
 * (the fill took almost nothing, or almost everything), so the caller can redraw it.
 */
export function cutOut(image: Image, size = 512): Image | null {
  const { width, height, rgba } = image;
  // The background colour: the median of a thin frame round the edge.
  const frame: number[][] = [[], [], []];
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (x > 3 && y > 3 && x < width - 4 && y < height - 4) continue;
      for (let c = 0; c < 3; c++) frame[c]!.push(rgba[(y * width + x) * 4 + c]!);
    }
  }
  const [r, g, b] = frame.map((values) => values.sort((p, q) => p - q)[values.length >> 1]!) as [number, number, number];

  const gone = new Uint8Array(width * height);
  const queue = new Int32Array(width * height);
  let head = 0, tail = 0;
  const seed = (i: number) => {
    if (!gone[i] && distance(rgba, i * 4, r, g, b) < near) {
      gone[i] = 1;
      queue[tail++] = i;
    }
  };
  for (let x = 0; x < width; x++) { seed(x); seed((height - 1) * width + x); }
  for (let y = 0; y < height; y++) { seed(y * width); seed(y * width + width - 1); }
  while (head < tail) {
    const i = queue[head++]!;
    const x = i % width, y = (i - x) / width;
    for (const n of [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, y > 0 ? i - width : -1, y < height - 1 ? i + width : -1]) {
      if (n < 0 || gone[n]) continue;
      const toEdge = distance(rgba, n * 4, r, g, b);
      const drift = Math.hypot(rgba[n * 4]! - rgba[i * 4]!, rgba[n * 4 + 1]! - rgba[i * 4 + 1]!, rgba[n * 4 + 2]! - rgba[i * 4 + 2]!);
      if (toEdge < near || (toEdge < far && drift < step)) {
        gone[n] = 1;
        queue[tail++] = n;
      }
    }
  }
  const removed = tail / (width * height);
  if (removed < 0.15 || removed > 0.92) return null;

  const out = new Uint8Array(rgba);
  let minX = width, minY = height, maxX = -1, maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = y * width + x;
      if (gone[i]) {
        out[i * 4 + 3] = 0;
        continue;
      }
      const touches = (x > 0 && gone[i - 1]) || (x < width - 1 && gone[i + 1]) || (y > 0 && gone[i - width]) || (y < height - 1 && gone[i + width]);
      if (touches) {
        const d = distance(rgba, i * 4, r, g, b);
        const alpha = Math.min(1, Math.max(0, (d - near) / feather));
        if (alpha < 1) {
          // Take the background's share back out of the colour, so the edge isn't tinted blue.
          for (let c = 0; c < 3; c++) {
            const bg = [r, g, b][c]!;
            out[i * 4 + c] = alpha > 0 ? Math.max(0, Math.min(255, Math.round((rgba[i * 4 + c]! - bg * (1 - alpha)) / alpha))) : 0;
          }
          out[i * 4 + 3] = Math.round(alpha * 255);
        }
      }
      if (out[i * 4 + 3]! > 0) {
        minX = Math.min(minX, x); maxX = Math.max(maxX, x);
        minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      }
    }
  }
  if (maxX < 0) return null;
  // A cut that still runs edge to edge found the frame of a picture, not a sticker.
  if (minX === 0 && minY === 0 && maxX === width - 1 && maxY === height - 1) return null;

  const w = maxX - minX + 1, h = maxY - minY + 1;
  const side = Math.ceil(Math.max(w, h) * 1.06);
  const square = new Uint8Array(side * side * 4);
  const ox = Math.floor((side - w) / 2), oy = Math.floor((side - h) / 2);
  for (let y = 0; y < h; y++) {
    square.set(out.subarray(((minY + y) * width + minX) * 4, ((minY + y) * width + maxX + 1) * 4), ((oy + y) * side + ox) * 4);
  }
  return resize({ width: side, height: side, rgba: square }, size);
}

/**
 * Shrinks a square image by averaging every source pixel under each new one, weighted
 * by alpha so the transparent background's colour doesn't bleed into the edges.
 */
export function resize(image: Image, size: number): Image {
  const { width, rgba } = image;
  if (width <= size) return image;
  const scale = width / size;
  const out = new Uint8Array(size * size * 4);
  for (let ty = 0; ty < size; ty++) {
    const y0 = ty * scale, y1 = y0 + scale;
    for (let tx = 0; tx < size; tx++) {
      const x0 = tx * scale, x1 = x0 + scale;
      let sr = 0, sg = 0, sb = 0, sa = 0, area = 0;
      for (let y = Math.floor(y0); y < Math.ceil(y1); y++) {
        const wy = Math.min(y + 1, y1) - Math.max(y, y0);
        for (let x = Math.floor(x0); x < Math.ceil(x1); x++) {
          const wx = Math.min(x + 1, x1) - Math.max(x, x0);
          const weight = wx * wy;
          const i = (y * width + x) * 4;
          const a = rgba[i + 3]! / 255;
          sr += rgba[i]! * a * weight; sg += rgba[i + 1]! * a * weight; sb += rgba[i + 2]! * a * weight;
          sa += a * weight; area += weight;
        }
      }
      const o = (ty * size + tx) * 4;
      if (sa > 0) {
        out[o] = Math.round(sr / sa); out[o + 1] = Math.round(sg / sa); out[o + 2] = Math.round(sb / sa);
      }
      out[o + 3] = Math.round((sa / area) * 255);
    }
  }
  return { width: size, height: size, rgba: out };
}
