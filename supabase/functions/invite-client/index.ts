// Invites a client to the reserved area. Only administrators can call it (checked on user_roles,
// never trusted from the request). It records the access for the client code, sends Supabase's
// invitation email (Italian template, via the project SMTP) and links the new account to the client
// with the "client" role, so the client lands on their orders after choosing a password.
import { createClient } from "npm:@supabase/supabase-js@2";

const DASHBOARD = "https://dashboard.24pet.it/area-riservata/";
const ORIGINS = new Set(["https://dashboard.24pet.it", "https://24pet.it", "https://www.24pet.it"]);
const CODE = /^C-\d{3,5}$/;
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,24}$/;

function cors(req: Request) {
  const origin = req.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.has(origin) ? origin : "https://dashboard.24pet.it",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  const headers = { ...cors(req), "Content-Type": "application/json" };
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply({ error: "method" }, 405);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Caller must be a signed-in administrator.
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return reply({ error: "auth" }, 401);
  const { data: caller, error: callerError } = await db.auth.getUser(jwt);
  if (callerError || !caller?.user) return reply({ error: "auth" }, 401);
  const { data: callerRole } = await db.from("user_roles").select("role").eq("user_id", caller.user.id).maybeSingle();
  if (callerRole?.role !== "admin") return reply({ error: "forbidden" }, 403);

  let input: { client_code?: unknown; business_name?: unknown; email?: unknown };
  try { input = await req.json(); } catch { return reply({ error: "body" }, 400); }
  const code = String(input.client_code || "").trim();
  const name = String(input.business_name || "").trim().slice(0, 160);
  const email = String(input.email || "").trim().toLowerCase();
  if (!CODE.test(code) || !name || !EMAIL.test(email)) return reply({ error: "input" }, 400);

  // The email must not already belong to another client.
  const { data: other } = await db.from("client_access").select("client_code").eq("invite_email", email).neq("client_code", code).maybeSingle();
  if (other) return reply({ error: "email_used", client_code: other.client_code }, 409);

  const { data: access, error: accessError } = await db.from("client_access").select("user_id,invite_email,password_set_at").eq("client_code", code).maybeSingle();
  if (accessError) return reply({ error: "read" }, 500);
  let resent = false;
  if (access?.user_id) {
    const { data: linked } = await db.auth.admin.getUserById(access.user_id);
    const user = linked?.user;
    // Active = the client chose a password, or an account created before invitations that was already used.
    const active = !!access.password_set_at || (!!user?.last_sign_in_at && !user?.invited_at);
    if (active) return reply({ error: "already_active" }, 409);
    if (user?.email_confirmed_at) {
      // Login never really used (created before invitations, or invitation opened without choosing a
      // password): remove it and send a fresh invitation, exactly like for a new company. Orders and
      // profile stay, they belong to the client code. Staff accounts are never touched.
      const { data: role } = await db.from("user_roles").select("role").eq("user_id", access.user_id).maybeSingle();
      if (role && role.role !== "client") return reply({ error: "is_staff" }, 409);
      const { error: deleteError } = await db.auth.admin.deleteUser(access.user_id);
      if (deleteError) return reply({ error: "link" }, 500);
    } else if (user && user.email?.toLowerCase() !== email) {
      // Invitation never accepted and the email was corrected: move the pending account to the new address.
      const { error: moveError } = await db.auth.admin.updateUserById(access.user_id, { email });
      if (moveError) return reply({ error: "email_exists" }, 409);
    }
    // A fresh invitation for an unused old login reads as «inviato», a pending one as «rimandato».
    resent = !user?.email_confirmed_at;
  }

  const { error: upsertError } = await db.from("client_access")
    .upsert({ client_code: code, business_name: name, invite_email: email, password_set_at: null }, { onConflict: "client_code" });
  if (upsertError) return reply({ error: "save" }, 500);

  const { data: invited, error: inviteError } = await db.auth.admin.inviteUserByEmail(email, { redirectTo: DASHBOARD });
  if (inviteError || !invited?.user) {
    const status = (inviteError as { status?: number } | null)?.status;
    const codeName = (inviteError as { code?: string } | null)?.code;
    if (codeName === "email_exists" || status === 422) return reply({ error: "email_exists" }, 409);
    if (status === 429) return reply({ error: "rate_limit" }, 429);
    return reply({ error: "send_failed" }, 502);
  }
  const userId = invited.user.id;

  // Never turn a staff account into a client.
  const { data: role } = await db.from("user_roles").select("role").eq("user_id", userId).maybeSingle();
  if (role && role.role !== "client") return reply({ error: "is_staff" }, 409);
  if (!role) {
    const { error: roleError } = await db.from("user_roles").insert({ user_id: userId, role: "client" });
    if (roleError) return reply({ error: "link" }, 500);
  }
  const { error: linkError } = await db.from("client_access").update({ user_id: userId }).eq("client_code", code);
  if (linkError) return reply({ error: "link" }, 500);

  return reply({ ok: true, resent, email });
});
