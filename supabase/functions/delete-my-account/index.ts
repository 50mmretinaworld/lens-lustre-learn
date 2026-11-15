import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

/**
 * SELF-SERVE ACCOUNT DELETION — now a REQUEST, reviewed by an admin.
 *
 * Owner decision 2026-11-15 (plan Part 3, A2/A3): a member's own delete
 * request needs admin approval; the admin may hold it under review for as long
 * as needed; with no hold it is approved automatically after 180 days. While
 * waiting, the member can log in and look but cannot do anything (A1 guard).
 *
 * This function no longer deletes anything. It records the request through
 * public.request_my_account_deletion(), called AS THE CALLER (their JWT), so the
 * database itself decides — and every app version, old ones included, follows
 * the same rule. The actual deletion is the one delete program,
 * public.account_delete_execute(), run when an admin approves or the 180-day
 * sweep does (migration 20261115_1330).
 *
 * Admins are refused by the database (returned to support), as before.
 */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const callerClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user: caller } } = await callerClient.auth.getUser();
    if (!caller) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: corsHeaders });
    }

    const { data: status, error } = await callerClient.rpc("request_my_account_deletion");
    if (error) {
      const forbidden = error.code === "42501";
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: forbidden ? 403 : 500, headers: corsHeaders },
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        status,                       // deletion_requested | under_review | already_requested
        message: "Your account is under review",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("delete-my-account error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: corsHeaders });
  }
});
