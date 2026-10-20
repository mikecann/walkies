/** World grid v2. Keep formulas and tie-breaking in sync with design/grid.md and Swift. */
export const gridVersion = 2;
export const earthRadius = 6_378_137;
export const referenceLatitude = -33.65;
export const scale = Math.cos(referenceLatitude * Math.PI / 180);
const radius = earthRadius * scale;
export const size = 50;
export const tileArea = 3 * Math.sqrt(3) / 2 * size * size;

export type Coordinate = { lat: number; lon: number };
export type Point = { x: number; y: number };
export type Hex = { q: number; r: number };

export function project(c: Coordinate): Point {
  const lat = c.lat * Math.PI / 180;
  return { x: radius * c.lon * Math.PI / 180, y: radius * Math.log(Math.tan(Math.PI / 4 + lat / 2)) };
}

export function unproject(p: Point): Coordinate {
  return { lat: (2 * Math.atan(Math.exp(p.y / radius)) - Math.PI / 2) * 180 / Math.PI,
    lon: p.x / radius * 180 / Math.PI };
}

// JS Math.round breaks negative half ties toward +infinity. Swift rounds away from zero.
const rounded = (n: number) => Math.sign(n) * Math.floor(Math.abs(n) + 0.5);
export function roundHex(q: number, r: number): Hex {
  const s = -q - r;
  let rq = rounded(q), rr = rounded(r);
  const rs = rounded(s);
  const dq = Math.abs(rq - q), dr = Math.abs(rr - r), ds = Math.abs(rs - s);
  if (dq > dr && dq > ds) rq = -rr - rs;
  else if (dr > ds) rr = -rq - rs;
  return { q: rq || 0, r: rr || 0 };
}

export function hexAt(p: Point): Hex {
  return roundHex((Math.sqrt(3) / 3 * p.x - p.y / 3) / size, (2 / 3 * p.y) / size);
}
export function hexContaining(c: Coordinate): Hex { return hexAt(project(c)); }
export function centre(h: Hex): Point {
  return { x: size * Math.sqrt(3) * (h.q + h.r / 2), y: size * 1.5 * h.r };
}
export function corners(h: Hex): Coordinate[] {
  const c = centre(h);
  return Array.from({ length: 6 }, (_, i) => {
    const angle = (60 * i - 30) * Math.PI / 180;
    return unproject({ x: c.x + size * Math.cos(angle), y: c.y + size * Math.sin(angle) });
  });
}
export function neighbours(h: Hex): Hex[] {
  return [[1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]].map(([q, r]) => ({ q: h.q + q, r: h.r + r }));
}
export function hexes(lo: Point, hi: Point): Hex[] {
  const rowHeight = size * 1.5, colWidth = size * Math.sqrt(3);
  const out: Hex[] = [];
  for (let r = Math.floor(lo.y / rowHeight) - 1; r <= Math.ceil(hi.y / rowHeight) + 1; r++) {
    const shift = r / 2;
    for (let q = Math.floor(lo.x / colWidth - shift) - 1; q <= Math.ceil(hi.x / colWidth - shift) + 1; q++) {
      const h = { q, r }, c = centre(h);
      if (c.x >= lo.x && c.x <= hi.x && c.y >= lo.y && c.y <= hi.y) out.push(h);
    }
  }
  return out;
}
