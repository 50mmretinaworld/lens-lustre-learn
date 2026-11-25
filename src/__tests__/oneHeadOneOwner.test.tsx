/**
 * ONE HEAD, ONE OWNER (Search Console 25 Nov 2026). Live post page after JS: 3 descriptions / 3 robots / 3
 * canonicals and a generic title over the edge's. The rule lives in src/lib/seo/headOwner.ts; these tests hold it.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { act, cleanup, render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import PageSEO from "@/components/PageSEO";
import { __resetHeadOwner } from "@/lib/seo/headOwner";

const count = (sel: string) => document.head.querySelectorAll(sel).length;
const DESC = 'meta[name="description"]';
const ROBOTS = 'meta[name="robots"]';
const CANON = 'link[rel="canonical"]';

function addEdgeTags() {
  document.head.insertAdjacentHTML(
    "beforeend",
    '<title data-seo="edge">Edge title</title>' +
      '<meta name="description" content="edge desc" data-seo="edge">' +
      '<meta name="robots" content="index, follow" data-seo="edge">' +
      '<link rel="canonical" href="https://www.50mmretina.com/x" data-seo="edge">',
  );
}

function mount(path: string) {
  const qc = new QueryClient();
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[path]}>
        {/* Layout's bare default + the page's own, as on every real page */}
        <PageSEO />
        <PageSEO title="Page" description="page desc" />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  document.head.innerHTML = "";
});
afterEach(() => cleanup());

describe("one head, one owner", () => {
  it("without edge tags: Layout default + page → exactly ONE set, the page's", async () => {
    __resetHeadOwner({ firstPathOverride: "/x" });
    await act(async () => { mount("/x"); });
    expect(count(DESC)).toBe(1);
    expect(count(ROBOTS)).toBe(1);
    expect(count(CANON)).toBe(1);
    expect(document.head.querySelector(DESC)?.getAttribute("content")).toBe("page desc");
  });

  it("on the loaded address the edge's tags are the only ones", async () => {
    addEdgeTags();
    __resetHeadOwner({ firstPathOverride: "/x" });
    await act(async () => { mount("/x"); });
    expect(count(DESC)).toBe(1);
    expect(count(ROBOTS)).toBe(1);
    expect(count(CANON)).toBe(1);
    expect(document.head.querySelector(DESC)?.getAttribute("content")).toBe("edge desc");
    expect(count("title")).toBe(1);
  });

  it("after moving to another address the edge's tags are gone and the app's set is the only one", async () => {
    addEdgeTags();
    __resetHeadOwner({ firstPathOverride: "/x" });
    await act(async () => { mount("/y"); });
    expect(count('[data-seo="edge"]')).toBe(0);
    expect(count(DESC)).toBe(1);
    expect(count(ROBOTS)).toBe(1);
    expect(count(CANON)).toBe(1);
    expect(document.head.querySelector(DESC)?.getAttribute("content")).toBe("page desc");
  });
});

describe("ratchet: head tags only through PageSEO", () => {
  it("no page or component writes <title>/description/robots/canonical in its own <Helmet>", () => {
    const hits: string[] = [];
    const walk = (dir: string) => {
      for (const f of readdirSync(dir)) {
        const p = join(dir, f);
        if (statSync(p).isDirectory()) { if (f !== "__tests__" && f !== "uiharness") walk(p); continue; }
        if (!/\.tsx$/.test(f) || p.endsWith(join("components", "PageSEO.tsx"))) continue;
        const s = readFileSync(p, "utf8");
        if (/<Helmet[\s>]/.test(s) && /<title|name="(description|robots)"|rel="canonical"/.test(s)) hits.push(p);
      }
    };
    walk(join(process.cwd(), "src"));
    expect(hits).toEqual([]);
  });
});
