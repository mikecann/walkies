import { expect, test } from "vitest";
import { mergeLedgers, parseLedger, type Ledger } from "./progression";

const ledger = (trail: string, updatedAt: number, purchases: Ledger["purchases"] = []): Ledger => ({
  purchases, claims: [], spyglasses: [],
  equipped: { marker: "marker.dot", trail, clouds: "classic", cover: "cover.red", celebration: "celebration.confetti", updatedAt },
});

test("switching back to a free look after buying one survives the merge both ways", () => {
  const bought = [{ id: "a", item: "trail.footprints", cost: 150, at: 1 }];
  const stored = ledger("trail.footprints", 1_790_000_000.25, bought);
  const phone = ledger("trail.teal", 1_790_000_100.5, bought);
  // The phone pushes its newer choice; the server keeps it.
  const saved = mergeLedgers(stored, phone);
  expect(saved.equipped.trail).toBe("trail.teal");
  expect(saved.purchases).toHaveLength(1);
  // An older copy arriving late doesn't undo it.
  expect(mergeLedgers(saved, stored).equipped.trail).toBe("trail.teal");
  // And the stored copy survives a JSON round trip unchanged.
  expect(parseLedger(JSON.stringify(saved))).toEqual(saved);
});
