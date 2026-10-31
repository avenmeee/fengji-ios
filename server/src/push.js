// 苹果推送。没配密钥就不发，别的流程不受影响。
const b64url = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function providerToken(env) {
  const der = Uint8Array.from(atob(env.APNS_KEY_P8.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = o => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const body = enc({ alg: "ES256", kid: env.APNS_KEY_ID }) + "." + enc({ iss: env.APPLE_TEAM_ID, iat: Math.floor(Date.now() / 1000) });
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(body));
  return body + "." + b64url(sig);
}

// 给一个人的所有设备发。令牌失效的删掉。推送失败不影响留言。
export async function pushToUser(env, userId, title, body) {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APPLE_TEAM_ID) return 0;
  const rows = (await env.DB.prepare("SELECT token FROM devices WHERE user_id = ?").bind(userId).all()).results;
  if (!rows.length) return 0;
  const auth = await providerToken(env);
  let sent = 0;
  for (const { token } of rows) {
    const r = await fetch(`https://api.push.apple.com/3/device/${token}`, {
      method: "POST",
      headers: { authorization: `bearer ${auth}`, "apns-topic": env.APPLE_AUDIENCE, "apns-push-type": "alert", "apns-priority": "10" },
      body: JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, route: "wants" })
    });
    if (r.status === 410 || r.status === 400) {
      await env.DB.prepare("DELETE FROM devices WHERE token = ?").bind(token).run();
    } else if (r.ok) {
      sent++;
    }
  }
  return sent;
}
