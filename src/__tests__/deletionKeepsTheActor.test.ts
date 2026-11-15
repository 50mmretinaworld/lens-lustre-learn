/**
 * DELETING AN ACCOUNT MUST NOT ERASE WHO SENT A NOTIFICATION.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THE DECISION, owner 2026-08-10, option C of three he was offered:
 *   keep the id, let the profile go, and let the display say
 *   "A deleted account".
 *
 * WHAT THE OLD BEHAVIOUR ACTUALLY DID
 *   Both delete paths ran
 *     .from("user_notifications").update({ actor_id: null }).eq("actor_id", id)
 *   under a comment claiming it anonymised the departing member. It did not.
 *   The same row's `reference_id` still pointed at that person — for
 *   `new_follower` the trigger sets `reference_id = follower_id` — so the
 *   identity was recoverable from the row either way. All the null-out achieved
 *   was destroying the ONE fact the bell needed.
 *
 *   The result, measured on production: 33 follow notifications with no actor
 *   at all, every one of them reading "A member started following you." — which
 *   is the wording reserved for a member who is present and simply has no name
 *   set. Two different facts wearing one sentence. After the repair there are
 *   35 rows whose actor is a deleted account, and the bell now says so.
 *
 * WHY REMOVING THOSE TWO LINES IS SAFE — verified on production 2026-08-10
 * BEFORE the change, because a fix that something else undoes is not a fix:
 *
 *   * `user_notifications` has **zero foreign keys**. There is no
 *     ON DELETE SET NULL to null the column behind our back, and no constraint
 *     that could make deleting the profile fail once the id stays.
 *   * **No database function sets `actor_id`.** Every routine that mentions the
 *     column only ever writes notifications. `admin_purge_orphan_user_data`,
 *     the one purge routine, does not touch it.
 *
 *   So these two edge functions were the only thing doing it.
 *
 * SINCE 2026-11-15 (A3) the deletion lives in ONE database function,
 * public.account_delete_execute; both edge functions call the database. The
 * same two rules are now checked on that function (second describe below).
 *
 * WHY THIS IS A TEST AND NOT JUST A DELETION
 *   These two files are the P0 deleted-account security fix of 2026-08-06. They
 *   are exactly the kind of file where somebody adds a tidy-up loop later and
 *   quietly puts the null-out back, believing it protects a departing member.
 *   It does the opposite: it degrades a truthful "A deleted account" into a
 *   misleading "A member", and anonymises nothing.
 * ─────────────────────────────────────────────────────────────────────────────
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { stripComments } from "@/test-utils/sourceText";

const FILES = [
  "supabase/functions/delete-my-account/index.ts",
  "supabase/functions/delete-user/index.ts",
];

/** Comments stripped: both files EXPLAIN the removed line at length. */
const codeOf = (p: string) => stripComments(readFileSync(join(process.cwd(), p), "utf8"));

describe("neither delete path erases the sender of a notification", () => {
  for (const f of FILES) {
    const name = f.split("/")[2];

    it(`${name}: never writes actor_id = null`, () => {
      const code = codeOf(f);
      expect(code).not.toMatch(/actor_id:\s*null/);
    });

    it(`${name}: does not touch user_notifications at all`, () => {
      // Stronger than the line above, and deliberately so. Deleting the rows,
      // or blanking any other column on them, would lose the same fact by a
      // different route.
      const code = codeOf(f);
      expect(code).not.toContain('from("user_notifications")');
    });

    it(`${name}: deletes only through the one database delete program`, () => {
      // Since 2026-11-15 (A3) both edge functions hand the work to the database:
      // delete-user → admin_delete_member, delete-my-account →
      // request_my_account_deletion. Neither may grow its own copy again.
      const code = codeOf(f);
      expect(code).toMatch(/rpc\("(admin_delete_member|request_my_account_deletion)"/);
      expect(code).not.toContain("admin_delete_auth_user");
      expect(code).not.toMatch(/\.delete\(\)/);
    });
  }
});

// The one delete program (A3). Its LAST definition in the migrations is the one
// that runs; the same two rules apply to it.
const DELETE_PROGRAM = "supabase/migrations/20261115_1330_a2_a3_deletion_review.sql";
const sqlOf = (p: string) =>
  readFileSync(join(process.cwd(), p), "utf8").replace(/--[^\n]*/g, "");

describe("the one delete program keeps the sender and clears the reviewers", () => {
  const sql = sqlOf(DELETE_PROGRAM);
  const body = sql.slice(sql.indexOf("CREATE FUNCTION public.account_delete_execute"),
                         sql.indexOf("CREATE FUNCTION public.admin_delete_member"));

  it("never sets actor_id to NULL", () => {
    expect(body.length).toBeGreaterThan(0);
    expect(body).not.toMatch(/actor_id\s*=\s*NULL/i);
  });

  it("still clears the reviewer on the five tables a report must outlive", () => {
    for (const t of ["comment_reports", "post_reports", "role_applications", "verification_requests", "withdrawal_requests"]) {
      expect(body, `${t} must still have its reviewer cleared`).toMatch(
        new RegExp(`UPDATE public\\.${t}\\s+SET reviewed_by = NULL`, "i"));
    }
  });
});
