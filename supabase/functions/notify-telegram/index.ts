// Sends a Telegram message for each new order request or professional access request.
// Called by a database trigger with { table, id }. The row is re-read with the service role,
// so the request body is never trusted; each row is notified at most once (notification_log).
import { createClient } from "npm:@supabase/supabase-js@2";

const TABLES = new Set(["client_order_requests", "partner_requests"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_AGE_MS = 15 * 60 * 1000;
const DASHBOARD = "https://dashboard.24pet.it/area-riservata/";
const BUSINESS_TYPES: Record<string, string> = {
  agenzia: "Agenzia funebre per animali",
  crematorio: "Centro di cremazione per animali",
  altro: "Altra attività",
};
const euro = new Intl.NumberFormat("it-IT", { style: "currency", currency: "EUR" });
const when = new Intl.DateTimeFormat("it-IT", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Rome" });

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let payload: { table?: string; id?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "body" }, 400);
  }
  const { table, id } = payload;
  if (!table || !TABLES.has(table) || !id || !UUID.test(id)) return json({ error: "input" }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const dateColumn = table === "client_order_requests" ? "submitted_at" : "created_at";
  const { data: row, error } = await db.from(table).select("*").eq("id", id).maybeSingle();
  if (error) return json({ error: "read" }, 500);
  if (!row) return json({ skipped: "not_found" });
  if (Date.now() - new Date(row[dateColumn]).getTime() > MAX_AGE_MS) return json({ skipped: "old" });

  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  // Accepts "123456789", "Id: 123456789", "-100…" (groups) or "@channel"; several separated by commas.
  const chats = (Deno.env.get("TELEGRAM_CHAT_ID") ?? "").split(",")
    .map((c) => c.trim())
    .map((c) => (c.startsWith("@") ? c : (c.match(/-?\d{5,}/)?.[0] ?? "")))
    .filter(Boolean);
  if (!token || !chats.length) return json({ skipped: "not_configured" });

  const { data: claimed, error: claimError } = await db
    .from("notification_log")
    .upsert({ source: table, record_id: id }, { onConflict: "source,record_id", ignoreDuplicates: true })
    .select("record_id");
  if (claimError) return json({ error: "log" }, 500);
  if (!claimed?.length) return json({ skipped: "already_sent" });

  let text: string;
  if (table === "client_order_requests") {
    const { data: account } = await db.from("client_access").select("business_name").eq("client_code", row.client_code).maybeSingle();
    const { data: catalog } = await db.from("client_order_catalog").select("model,size,list_price");
    const prices = new Map((catalog ?? []).map((c) => [c.model + "|" + c.size, Number(c.list_price)]));
    const groups = new Map<string, number>();
    let pieces = 0;
    let listTotal = 0;
    let priced = true;
    for (const item of row.items ?? []) {
      const quantity = Number(item.quantity) || 0;
      pieces += quantity;
      const key = item.model + " · " + item.size;
      groups.set(key, (groups.get(key) ?? 0) + quantity);
      const price = prices.get(item.model + "|" + item.size);
      if (price == null) priced = false;
      else listTotal += price * quantity;
    }
    const alias = account?.business_name ?? row.client_code;
    const legal = row.billing_details?.legal_name;
    const lines = [...groups.entries()].sort((a, b) => b[1] - a[1]);
    text = [
      "🛒 Nuova richiesta d'ordine",
      "",
      alias + (legal && legal.toLowerCase() !== String(alias).toLowerCase() ? " · " + legal : ""),
      pieces + (pieces === 1 ? " urna" : " urne") + (priced ? " · " + euro.format(listTotal) + " di listino" : ""),
      "",
      ...lines.slice(0, 10).map(([key, q]) => "• " + key + ": " + q + " pz"),
      ...(lines.length > 10 ? ["• … e altri " + (lines.length - 10) + " articoli"] : []),
      "",
      "Ricevuta il " + when.format(new Date(row.submitted_at)),
      DASHBOARD,
    ].join("\n");
  } else {
    text = [
      "🤝 Nuova richiesta di accesso professionale",
      "",
      String(row.business_name ?? "Senza nome"),
      BUSINESS_TYPES[row.business_type] ?? String(row.business_type ?? ""),
      String(row.email ?? ""),
      "",
      "Ricevuta il " + when.format(new Date(row.created_at)),
      DASHBOARD,
    ].join("\n");
  }

  let delivered = 0;
  const problems: string[] = [];
  for (const chat of chats) {
    const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    });
    if (response.ok) delivered++;
    else {
      const detail = await response.json().catch(() => null);
      problems.push(String(detail?.description ?? response.status));
    }
  }
  if (!delivered) {
    await db.from("notification_log").delete().eq("source", table).eq("record_id", id);
    // Safe diagnostics: which bot the token belongs to, and the shape of each chat id (never the full value).
    const me = await fetch(`https://api.telegram.org/bot${token}/getMe`).then((r) => r.json()).catch(() => null);
    const botId = token.split(":")[0];
    const chatShapes = chats.map((c) => ({
      length: c.length,
      start: c.slice(0, 2),
      numeric: /^-?\d+$/.test(c),
      sameAsBot: c === botId,
    }));
    return json({ error: "telegram", detail: problems, bot: me?.result?.username ?? null, chats: chatShapes }, 502);
  }
  return json({ sent: delivered });
});
