// Sign in with Apple：验身份令牌；配了密钥时换刷新令牌、删号时撤销。
const b64urlToBytes = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
const bytesToB64url = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const jsonOf = s => JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));

// 纯函数，方便测试。jwks 形如 {keys:[...]}。不对就抛错。
export async function verifyIdentityToken(token, jwks, audience, nowSeconds = Date.now() / 1000) {
  const parts = String(token || "").split(".");
  if (parts.length !== 3) throw new Error("bad token");
  const head = jsonOf(parts[0]), claims = jsonOf(parts[1]);
  if (head.alg !== "RS256") throw new Error("bad alg");
  const jwk = (jwks.keys || []).find(k => k.kid === head.kid);
  if (!jwk) throw new Error("unknown key");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64urlToBytes(parts[2]), new TextEncoder().encode(parts[0] + "." + parts[1]));
  if (!ok) throw new Error("bad signature");
  if (claims.iss !== "https://appleid.apple.com") throw new Error("bad iss");
  if (claims.aud !== audience) throw new Error("bad aud");
  if (!(claims.exp > nowSeconds)) throw new Error("expired");
  if (!claims.sub) throw new Error("no sub");
  return claims;
}

export async function fetchAppleKeys() {
  const r = await fetch("https://appleid.apple.com/auth/keys", { cf: { cacheTtl: 3600, cacheEverything: true } });
  if (!r.ok) throw new Error("apple keys " + r.status);
  return r.json();
}

// 客户端密钥：用 Sign in with Apple 的 .p8 签 ES256。三个 secrets 没配齐就返回 null，登录照常，只是不存刷新令牌。
async function clientSecret(env) {
  if (!env.APPLE_KEY_P8 || !env.APPLE_KEY_ID || !env.APPLE_TEAM_ID) return null;
  const der = Uint8Array.from(atob(env.APPLE_KEY_P8.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = o => bytesToB64url(new TextEncoder().encode(JSON.stringify(o)));
  const now = Math.floor(Date.now() / 1000);
  const body = enc({ alg: "ES256", kid: env.APPLE_KEY_ID }) + "." + enc({ iss: env.APPLE_TEAM_ID, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: env.APPLE_AUDIENCE });
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(body));
  return body + "." + bytesToB64url(sig);
}

export async function exchangeCode(env, code) {
  const secret = await clientSecret(env);
  if (!secret || !code) return null;
  const r = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env.APPLE_AUDIENCE, client_secret: secret, code, grant_type: "authorization_code" })
  });
  if (!r.ok) return null;
  return (await r.json()).refresh_token || null;
}

export async function revokeToken(env, refreshToken) {
  const secret = await clientSecret(env);
  if (!secret || !refreshToken) return false;
  const r = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: env.APPLE_AUDIENCE, client_secret: secret, token: refreshToken, token_type_hint: "refresh_token" })
  });
  return r.ok;
}
