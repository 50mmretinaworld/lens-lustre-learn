import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

/**
 * ADMIN: DELETE A MEMBER — instantly, everything (Owner decision 2026-11-15).
 *
 * The deletion itself is the ONE delete program in the database,
 * public.account_delete_execute() (migration 20261115_1330), reached through
 * public.admin_delete_member(user_id, reason), called AS THE CALLER (their JWT):
 * the database checks the admin role, refuses self-deletion, requires a reason,
 * deletes (auth user first, then every non-cascading table, the orphan purge),
 * writes the log row (who, when, reason) and queues the erasure e-mail as a job.
 *
 * Kept from the old program, now inside that one place: the reviewer columns
 * are cleared (comment_reports, post_reports, role_applications,
 * verification_requests, withdrawal_requests → reviewed_by = null) and the
 * sender of other members' notifications is NOT erased (Owner option C,
 * 2026-08-10: the display says "A deleted account").
 */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user: caller } } = await callerClient.auth.getUser();
    if (!caller) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });

    const { user_id, reason } = await req.json();
    if (!user_id || typeof user_id !== "string") {
      return new Response(JSON.stringify({ error: "user_id required" }), { status: 400, headers: corsHeaders });
    }
    if (user_id === caller.id) {
      return new Response(JSON.stringify({ error: "Cannot delete yourself" }), { status: 400, headers: corsHeaders });
    }

    const { data, error } = await callerClient.rpc("admin_delete_member", {
      _user_id: user_id,
      _reason: typeof reason === "string" && reason.trim() !== "" ? reason.trim() : "Deleted by admin",
    });
    if (error) {
      const status = error.code === "42501" ? 403 : error.code === "22023" ? 400 : 500;
      return new Response(JSON.stringify({ error: error.message }), { status, headers: corsHeaders });
    }
    const result = (data ?? {}) as { deleted?: boolean; confirmation_email_queued?: boolean };
    if (!result.deleted) {
      return new Response(JSON.stringify({ error: "User not found" }), { status: 404, headers: corsHeaders });
    }
    return new Response(
      JSON.stringify({ success: true, confirmation_email_queued: result.confirmation_email_queued === true }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("Delete user error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: corsHeaders });
  }
});
