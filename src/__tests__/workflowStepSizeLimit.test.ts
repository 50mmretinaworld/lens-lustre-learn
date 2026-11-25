/**
 * GITHUB REFUSES A `run:` STEP OVER 21,000 CHARACTERS — and it refuses the WHOLE workflow, silently:
 * no job starts, the run just says "workflow file issue". Android 1.2.59, 25 Nov 2026 (run 45679260559):
 * the "Set app version" step had collected a comment for every version bump since 1.2.45 and two more
 * lines took it from 20,846 to 21,079. The history now lives as YAML comments ABOVE the step.
 *
 * This keeps every step in every workflow under 18,000 characters, so the next bump fails HERE, in a
 * PR check, with the step named — never as a release build that does not start.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { parse } from "yaml";

const LIMIT = 18_000; // GitHub's hard limit is 21,000; keep a margin
const dir = join(process.cwd(), ".github/workflows");

describe("no workflow step comes near GitHub's 21,000-character limit", () => {
  const files = readdirSync(dir).filter((f) => /\.ya?ml$/.test(f));

  it("finds the workflows", () => {
    expect(files.length).toBeGreaterThan(10);
  });

  it.each(files)("%s: every run step is under 18,000 characters", (f) => {
    const wf = parse(readFileSync(join(dir, f), "utf8")) ?? {};
    const tooLong: string[] = [];
    for (const [job, def] of Object.entries<Record<string, unknown>>(wf.jobs ?? {})) {
      for (const step of (def?.steps as Array<{ name?: string; run?: string }>) ?? []) {
        if (typeof step.run === "string" && step.run.length > LIMIT) tooLong.push(`${job} / ${step.name ?? "(unnamed)"}: ${step.run.length}`);
      }
    }
    expect(tooLong).toEqual([]);
  });
});
