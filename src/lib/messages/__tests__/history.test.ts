import { describe, it, expect } from "vitest";
import { mergeNewest, mergeOlder } from "@/lib/messages/history";

const ids = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => ({ id: from + i }));
const just = (l: { id: number }[]) => l.map((m) => m.id);

describe("Chat history is one list with no holes (Owner 23 Nov: 200 sent, few shown)", () => {
  it("first page: the page is the list", () => {
    expect(just(mergeNewest([], ids(51, 100), true).merged)).toEqual(just(ids(51, 100)));
  });

  it("a refresh that overlaps keeps the older rows and reports no hole", () => {
    const r = mergeNewest(ids(1, 100), ids(61, 110), true);
    expect(just(r.merged)).toEqual(just(ids(1, 110)));
    expect(r.gapBefore).toBeNull();
  });

  it("200 new messages after the screen loaded: the hole is reported, never silently dropped", () => {
    const r = mergeNewest(ids(1, 60), ids(211, 260), true);
    expect(r.gapBefore).toBe(211);
    expect(just(r.merged)).toEqual([...just(ids(1, 60)), ...just(ids(211, 260))]);
    // closing the hole page by page
    let h = r.merged;
    for (let before = 211; before > 61; before -= 50) h = mergeOlder(h, ids(Math.max(61, before - 50), before - 1));
    expect(just(h)).toEqual(just(ids(1, 260)));
  });

  it("a short newest page is the whole chat: no hole", () => {
    expect(mergeNewest(ids(1, 10), ids(5, 12), false).gapBefore).toBeNull();
  });

  it("a message removed on the server leaves the screen", () => {
    const page = ids(51, 100).filter((m) => m.id !== 70);
    expect(just(mergeNewest(ids(1, 100), page, true).merged)).not.toContain(70);
  });

  it("older pages merge in order without duplicates", () => {
    expect(just(mergeOlder(ids(40, 60), ids(30, 45)))).toEqual(just(ids(30, 60)));
  });
});
