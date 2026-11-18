/**
 * Owner 18 Nov 2026 — a long post caption covered the whole story. The story
 * shows two lines without the trailing hashtags; "more" opens the full text.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import StoryCaption, { storyCaptionShort } from "@/components/stories/StoryCaption";

vi.mock("@/hooks/profile/useMemberHandles", () => ({ useMemberHandles: () => new Map() }));

const LONG =
  "A New Photography Competition is Here! PEOPLE – A celebration of human stories.\n" +
  "Submissions Open: 17 November 2026\n#50mmRetinaWorld #PhotographyCompetition #PeoplePhotography";

describe("storyCaptionShort", () => {
  it("drops the trailing block of hashtags", () => {
    expect(storyCaptionShort(LONG)).toBe(
      "A New Photography Competition is Here! PEOPLE – A celebration of human stories.\nSubmissions Open: 17 November 2026",
    );
  });
  it("keeps a hashtag inside the sentence, and keeps tags when they are all there is", () => {
    expect(storyCaptionShort("Love #birds in winter")).toBe("Love #birds in winter");
    expect(storyCaptionShort("#birds #nature")).toBe("#birds #nature");
  });
});

describe("StoryCaption", () => {
  const draw = (caption: string, onMore = vi.fn()) =>
    render(<MemoryRouter><StoryCaption caption={caption} onMore={onMore} /></MemoryRouter>);

  it("is clamped to two lines and offers 'more' when tags were left out", () => {
    const onMore = vi.fn();
    draw(LONG, onMore);
    const p = screen.getByTestId("story-caption").querySelector("p")!;
    expect(p.className).toContain("line-clamp-2");
    expect(p.textContent).not.toContain("#PeoplePhotography");
    fireEvent.click(screen.getByTestId("story-caption-more"));
    expect(onMore).toHaveBeenCalledTimes(1);
  });

  it("a short caption with nothing hidden has no 'more'", () => {
    draw("Scarlet minivet (female)");
    expect(screen.queryByTestId("story-caption-more")).toBeNull();
  });

  it("a mention reads @Name, never the stored form", () => {
    draw("Thanks @[Sri V R Narayanasw](83f6d083-e78e-4b74-8ac6-af3a9717e295) 🙏");
    const text = screen.getByTestId("story-caption").textContent ?? "";
    expect(text).toContain("Sri V R Narayanasw");
    expect(text).not.toContain("83f6d083");
    expect(text).not.toContain("@[");
  });
});
