/**
 * ROOT RULE (Owner 18 Nov 2026): a tag's name comes from the member's profile —
 * one source — on every screen. A member renamed after being tagged shows the
 * NEW name in the full text and in every preview; a member who no longer exists
 * keeps the name typed at the time, as plain text, never a link; the stored
 * form @[Name](id) is never on screen.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const RENAMED = "11111111-1111-4111-8111-111111111111";
const GONE = "22222222-2222-4222-8222-222222222222";

vi.mock("@/lib/profileMapCache", () => ({
  fetchProfileMap: async (ids: string[]) =>
    new Map(ids.map((id) => [id, id === RENAMED
      ? { id, full_name: "Sri V R Narayanaswamy", custom_url: "sri.vr", avatar_url: null, badges: [], roles: [], last_active_at: null }
      : { id, full_name: null, custom_url: null, avatar_url: null, badges: [], roles: [], last_active_at: null }])),
}));

import RichContentRenderer from "@/components/RichContentRenderer";
import MemberText from "@/components/MemberText";

const TEXT = `Thanks @[Sri V R Narayanasw](${RENAMED}) and @[Old Friend](${GONE}) 🙏 @[@all](all)`;

describe("member tags — one source", () => {
  it("full text: the profile's current name, linked; a gone member stays plain text; nothing raw", async () => {
    render(<MemoryRouter><RichContentRenderer content={TEXT} /></MemoryRouter>);
    const link = await screen.findByRole("link", { name: "Sri V R Narayanaswamy" });
    expect(link.getAttribute("href")).toContain("sri.vr");
    const gone = document.querySelector(`[data-member-tag="${GONE}"]`)!;
    expect(gone.textContent).toBe("Old Friend");
    expect(gone.tagName).toBe("SPAN");
    const all = document.body.textContent ?? "";
    expect(all).toContain("@all");
    expect(all).not.toContain("@[");
    expect(all).not.toContain(RENAMED);
  });

  it("preview: the same current name, plain, cut", async () => {
    render(<MemberText text={TEXT} max={60} />);
    await waitFor(() => expect(document.body.textContent).toContain("@Sri V R Narayanaswamy"));
    expect(document.body.textContent).toContain("@Old Friend");
    expect(document.body.textContent).not.toContain("@[");
  });

  it("the renderer reads names from useMemberNames, never from the text (source check)", () => {
    const src = readFileSync(resolve(__dirname, "../RichContentRenderer.tsx"), "utf8");
    expect(src).toContain("useMemberNames(");
    expect(src).not.toMatch(/\{match\[1\]\}/); // the copied name is never printed directly
  });
});
