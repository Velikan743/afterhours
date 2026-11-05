const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function rest(path: string, init: RequestInit = {}) {
  return fetch(`${url}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
}
function b64(bytes: Uint8Array) { return btoa(String.fromCharCode(...bytes)); }
function unb64(value: string) { return Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
async function keyFromSecret(secret: string) {
  const raw = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
async function encrypt(value: unknown) {
  const secret = Deno.env.get("EMAIL_2FA_ENCRYPTION_SECRET")!;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await keyFromSecret(secret), new TextEncoder().encode(JSON.stringify(value)));
  return `${b64(iv)}.${b64(new Uint8Array(cipher))}`;
}
async function decrypt(value: string) {
  const [iv, cipher] = value.split(".");
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await keyFromSecret(Deno.env.get("EMAIL_2FA_ENCRYPTION_SECRET")!), unb64(cipher));
  return JSON.parse(new TextDecoder().decode(clear));
}
async function codeHash(code: string) {
  const secret = Deno.env.get("EMAIL_2FA_CODE_SECRET")!;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(code))));
}
function makeCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const out: string[] = [];
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  for (const byte of bytes) { if (byte >= 256 - (256 % chars.length)) continue; out.push(chars[byte % chars.length]); if (out.length === 8) break; }
  while (out.length < 8) return makeCode();
  return out.join("");
}
function jwtClaims(token: string) {
  const part = token.split(".")[1];
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(new TextDecoder().decode(unb64(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="))));
}
async function sendCode(email: string, code: string) {
  const apiKey = Deno.env.get("RESEND_API_KEY")!;
  const from = Deno.env.get("EMAIL_2FA_FROM")!;
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to: [email], subject: "Your afterhours verification code", text: `Your afterhours code is ${code}. It expires in 10 minutes. If you did not request this, ignore this email.`, html: `<p>Your afterhours verification code is:</p><p style="font-size:28px;font-weight:bold;letter-spacing:6px">${code}</p><p>It expires in 10 minutes. If you did not request this, ignore this email.</p>` }),
  });
  if (!response.ok) throw new Error("Email delivery failed. Check the email provider configuration.");
}
async function createChallenge(userId: string, email: string, purpose: string, payload: unknown = null) {
  const recentResponse = await rest(`email_2fa_challenges?user_id=eq.${userId}&purpose=eq.${purpose}&created_at=gte.${encodeURIComponent(new Date(Date.now() - 10 * 60_000).toISOString())}&select=created_at&order=created_at.desc`);
  if (!recentResponse.ok) throw new Error("Could not prepare a verification email.");
  const recent = await recentResponse.json();
  if (recent.length >= 3) throw new Error("Too many codes requested. Wait 10 minutes before trying again.");
  if (recent.length && Date.now() - new Date(recent[0].created_at).getTime() < 60_000) throw new Error("Wait one minute before requesting another code.");
  // Supersede unused codes for this user and flow.
  await rest(`email_2fa_challenges?user_id=eq.${userId}&purpose=eq.${purpose}&consumed_at=is.null`, { method: "PATCH", body: JSON.stringify({ consumed_at: new Date().toISOString() }) });
  const code = makeCode();
  const result = await rest("email_2fa_challenges", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({ user_id: userId, purpose, code_hash: await codeHash(code), encrypted_payload: payload ? await encrypt(payload) : null, expires_at: new Date(Date.now() + 10 * 60_000).toISOString() }) });
  if (!result.ok) throw new Error("Could not create a verification challenge.");
  const [challenge] = await result.json();
  await sendCode(email, code);
  return challenge.id;
}
async function verifiedUser(req: Request) {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("Sign in to manage two-factor authentication.");
  const response = await fetch(`${url}/auth/v1/user`, { headers: { apikey: req.headers.get("apikey") || "", Authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error("Your session expired. Sign in again.");
  const user = await response.json();
  const claims = jwtClaims(token);
  if (await getSetting(user.id)) {
    const sessionResponse = await rest(`email_2fa_verified_sessions?user_id=eq.${user.id}&session_id=eq.${claims.session_id}&select=session_id`);
    const rows = await sessionResponse.json();
    if (!sessionResponse.ok || !rows?.length) throw new Error("Complete email two-factor verification before managing account security.");
  }
  return { user, token, claims };
}
async function getSetting(userId: string) {
  const response = await rest(`email_2fa_settings?user_id=eq.${userId}&select=enabled`);
  if (!response.ok) throw new Error("Could not check two-factor settings.");
  const rows = await response.json();
  return Boolean(rows?.[0]?.enabled);
}
async function findChallenge(id: string, purpose: string) {
  const response = await rest(`email_2fa_challenges?id=eq.${encodeURIComponent(id)}&purpose=eq.${purpose}&select=*`);
  const rows = await response.json();
  return rows?.[0];
}
async function consumeChallenge(id: string) {
  const response = await rest(`email_2fa_challenges?id=eq.${encodeURIComponent(id)}&consumed_at=is.null`, { method: "PATCH", body: JSON.stringify({ consumed_at: new Date().toISOString() }) });
  if (!response.ok) throw new Error("Could not update the verification request.");
}
async function saveVerifiedSession(userId: string, sessionId: string) {
  const response = await rest("email_2fa_verified_sessions", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify({ user_id: userId, session_id: sessionId }) });
  if (!response.ok) throw new Error("Could not finish session verification.");
}
async function verifyChallenge(challenge: any, entered: string) {
  if (!challenge || challenge.consumed_at || new Date(challenge.expires_at).getTime() < Date.now()) throw new Error("This code expired. Start again to get a new code.");
  if (challenge.attempts >= 5) { await consumeChallenge(challenge.id); throw new Error("Too many incorrect codes. Start again to request a new one."); }
  if (await codeHash(entered.toUpperCase()) !== challenge.code_hash) {
    const response = await rest(`email_2fa_challenges?id=eq.${challenge.id}`, { method: "PATCH", body: JSON.stringify({ attempts: challenge.attempts + 1 }) });
    if (!response.ok) throw new Error("Could not record the verification attempt.");
    throw new Error(`Incorrect code. ${4 - challenge.attempts} attempt${challenge.attempts === 3 ? "" : "s"} remaining.`);
  }
  await consumeChallenge(challenge.id);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  try {
    const body = await req.json();
    if (body.action === "status") {
      const { user } = await verifiedUser(req);
      return json({ enabled: await getSetting(user.id) });
    }
    if (body.action === "check_password") {
      const { user } = await verifiedUser(req);
      const check = await fetch(`${url}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: req.headers.get("apikey") || "", "Content-Type": "application/json" }, body: JSON.stringify({ email: user.email, password: body.password }) });
      if (!check.ok) throw new Error("The current password is incorrect.");
      return json({ ok: true });
    }
    if (body.action === "login") {
      const login = await fetch(`${url}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: req.headers.get("apikey") || "", "Content-Type": "application/json" }, body: JSON.stringify({ email: body.email, password: body.password }) });
      const session = await login.json();
      if (!login.ok) return json({ error: "Invalid login credentials" });
      if (!await getSetting(session.user.id)) return json({ session });
      const challengeId = await createChallenge(session.user.id, session.user.email, "login", session);
      return json({ challengeId });
    }
    if (["start_enable", "start_disable"].includes(body.action)) {
      const { user } = await verifiedUser(req);
      const enable = body.action === "start_enable";
      if (await getSetting(user.id) === enable) throw new Error(enable ? "Email two-factor authentication is already enabled." : "Email two-factor authentication is already disabled.");
      const challengeId = await createChallenge(user.id, user.email, enable ? "enable" : "disable");
      return json({ challengeId, email: user.email });
    }
    if (["verify_login", "verify_enable", "verify_disable"].includes(body.action)) {
      const purpose = body.action === "verify_login" ? "login" : body.action === "verify_enable" ? "enable" : "disable";
      const challenge = await findChallenge(body.challengeId, purpose);
      if (!challenge) throw new Error("This verification request is no longer available. Start again.");
      let currentUser: { user: any; claims: any } | null = null;
      if (purpose !== "login") {
        currentUser = await verifiedUser(req);
        if (currentUser.user.id !== challenge.user_id) throw new Error("This verification request belongs to another account.");
      }
      await verifyChallenge(challenge, String(body.code || "").trim());
      if (purpose === "login") {
        const session = await decrypt(challenge.encrypted_payload);
        const claims = jwtClaims(session.access_token);
        await saveVerifiedSession(challenge.user_id, claims.session_id);
        return json({ session });
      }
      if (purpose === "enable") {
        await saveVerifiedSession(challenge.user_id, currentUser!.claims.session_id);
        const setting = await rest("email_2fa_settings", { method: "POST", headers: { Prefer: "resolution=merge-duplicates" }, body: JSON.stringify({ user_id: challenge.user_id, enabled: true, updated_at: new Date().toISOString() }) });
        if (!setting.ok) throw new Error("Could not enable email two-factor authentication.");
      } else {
        const setting = await rest(`email_2fa_settings?user_id=eq.${challenge.user_id}`, { method: "PATCH", body: JSON.stringify({ enabled: false, updated_at: new Date().toISOString() }) });
        const sessions = await rest(`email_2fa_verified_sessions?user_id=eq.${challenge.user_id}`, { method: "DELETE" });
        if (!setting.ok || !sessions.ok) throw new Error("Could not update two-factor settings.");
      }
      return json({ ok: true });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Request failed." });
  }
});
