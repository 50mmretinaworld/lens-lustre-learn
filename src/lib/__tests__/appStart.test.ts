/**
 * N6-1 (Owner 24 Nov: close the gap to Meta): every start-up reader shares ONE get_app_start request; each part is
 * used once; anything missing means "ask alone" (today's behaviour); never another member's data.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";

let answer: unknown = { features: { video_posts: true }, message_allowed: true, my_stories: [{ id: "s1" }], me: null };
let fail = false;
const rpc = vi.fn(async (fn: string, _args?: unknown) => {
  if (fn !== "get_app_start") return { data: null, error: null };
  if (fail) return { data: null, error: { code: "PGRST202", message: "Could not find the function public.get_app_start" } };
  return { data: answer, error: null };
});
vi.mock("@/integrations/supabase/client", () => ({ supabase: { rpc: (fn: string, a?: unknown) => rpc(fn, a) } }));

async function load(me: string | null) {
  vi.resetModules();
  const logger = await import("@/lib/logger");
  logger.setLogUser(me);
  return import("@/lib/appStart");
}
const starts = () => rpc.mock.calls.filter((c) => c[0] === "get_app_start").length;

beforeEach(() => {
  rpc.mockClear();
  fail = false;
  answer = { features: { video_posts: true }, message_allowed: true, my_stories: [{ id: "s1" }], me: null };
});

describe("one start-up request for every reader", () => {
  it("several readers at once → ONE request; each gets its part", async () => {
    const { startPart } = await load("m1");
    const [f, m] = await Promise.all([startPart("features"), startPart("message_allowed")]);
    expect(f).toEqual({ video_posts: true });
    expect(m).toBe(true);
    expect(starts()).toBe(1);
  });

  it("a part is handed out once — the next read (a refresh) asks the network", async () => {
    const { startPart } = await load("m1");
    expect(await startPart("features")).toEqual({ video_posts: true });
    expect(await startPart("features")).toBeUndefined();
    expect(starts()).toBe(1);
  });

  it("one part, two named readers (the member's own row): each reader gets it once; JSON null is a real answer", async () => {
    const { startPart } = await load("m1");
    expect(await startPart("me", "m1", "banned")).toBeNull();
    expect(await startPart("me", "m1", "privacy")).toBeNull();
    expect(await startPart("me", "m1", "banned")).toBeUndefined();
  });

  it("a part the answer does not carry (it failed inside get_app_start) → ask alone", async () => {
    const { startPart } = await load("m1");
    expect(await startPart("trending")).toBeUndefined();
  });

  it("a lane without get_app_start → every part asks alone", async () => {
    fail = true;
    const { startPart } = await load("m1");
    expect(await startPart("features")).toBeUndefined();
    expect(await startPart("message_allowed")).toBeUndefined();
  });

  it("signed out → no request at all", async () => {
    const { startPart } = await load(null);
    expect(await startPart("features")).toBeUndefined();
    expect(starts()).toBe(0);
  });

  it("asking about ANOTHER member never gets the start-up answer", async () => {
    const { startPart } = await load("m1");
    expect(await startPart("my_stories", "someone-else")).toBeUndefined();
    expect(starts()).toBe(0);
  });

  it("only one start per member per page load", async () => {
    const { startPart } = await load("m1");
    await startPart("features");
    await startPart("message_allowed");
    await startPart("blocked");
    expect(starts()).toBe(1);
  });
});
