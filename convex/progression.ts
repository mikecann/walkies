import { ConvexError } from "convex/values";

type Purchase = { id: string; item: string; cost: number; at: number };
type Claim = { level: number; choice: string };
type Spyglass = { id: string; secretId: string; centre: number[]; at: number };
type Equipped = { marker: string; trail: string; clouds: string; cover: string; celebration: string; updatedAt: number };
export type Ledger = { purchases: Purchase[]; claims: Claim[]; spyglasses: Spyglass[]; equipped: Equipped; offers?: { level: number; choices: string[] }[] };

/** Keep this in step with Ledger.merged(with:) in Walkies/Model/Progression.swift.
 * The receiver (the server's saved copy) wins duplicate ids/levels and clock ties.
 */
export function mergeLedgers(stored: Ledger, incoming: Ledger): Ledger {
  function union<T>(a: T[], b: T[], key: (value: T) => string | number): T[] {
    const seen = new Set<string | number>();
    return [...a, ...b].filter((value) => {
      const id = key(value);
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    });
  }
  const offers = union(stored.offers ?? [], incoming.offers ?? [], (o) => o.level);
  return {
    ...(offers.length > 0 ? { offers } : {}),
    purchases: union(stored.purchases, incoming.purchases, (p) => p.id),
    claims: union(stored.claims, incoming.claims, (c) => c.level),
    spyglasses: union(stored.spyglasses, incoming.spyglasses, (s) => s.id),
    equipped: incoming.equipped.updatedAt > stored.equipped.updatedAt ? incoming.equipped : stored.equipped,
  };
}

/** Validate the JSON boundary before it becomes an account's saved ledger.
 * Earned shells remain derived on the phone; this doesn't award any progress.
 */
export function parseLedger(json: string): Ledger {
  try {
    const value = JSON.parse(json);
    const number = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);
    const text = (s: unknown): s is string => typeof s === "string";
    const record = (r: unknown): r is Record<string, unknown> => r !== null && typeof r === "object" && !Array.isArray(r);
    if (!record(value) || !Array.isArray(value.purchases) || !Array.isArray(value.claims) || !Array.isArray(value.spyglasses) || !record(value.equipped)) throw Error();
    if (!value.purchases.every((p) => record(p) && text(p.id) && text(p.item) && number(p.cost) && Number.isSafeInteger(p.cost) && p.cost >= 0 && number(p.at))) throw Error();
    if (!value.claims.every((c) => record(c) && number(c.level) && Number.isSafeInteger(c.level) && c.level >= 2 && text(c.choice))) throw Error();
    if (!value.spyglasses.every((s) => record(s) && text(s.id) && text(s.secretId) && number(s.at) && Array.isArray(s.centre) && s.centre.length === 2 && s.centre.every(number))) throw Error();
    if (value.offers !== undefined && (!Array.isArray(value.offers) || !value.offers.every((o) => record(o) && number(o.level) && Number.isSafeInteger(o.level) && o.level >= 2 && Array.isArray(o.choices) && o.choices.length === 3 && o.choices.every(text)))) throw Error();
    const equipped = value.equipped;
    if (!["marker", "trail", "clouds", "cover", "celebration"].every((group) => text(equipped[group])) || !number(value.equipped.updatedAt)) throw Error();
    return value as Ledger;
  } catch {
    throw new ConvexError("Invalid progression ledger");
  }
}
