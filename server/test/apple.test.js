// 验苹果身份令牌：用自己生成的钥匙签，确认对的过、改过的拒。
import assert from "node:assert/strict";
import { test } from "node:test";
import { verifyIdentityToken } from "../src/apple.js";

const b64 = o => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1" };
const jwks = { keys: [jwk] };
const AUD = "com.avenmeee.fengji", NOW = 1_800_000_000;

async function sign(claims, head = { alg: "RS256", kid: "k1" }) {
  const body = b64(head) + "." + b64(claims);
  const s = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(body));
  return body + "." + Buffer.from(s).toString("base64url");
}
const good = { iss: "https://appleid.apple.com", aud: AUD, sub: "abc", exp: NOW + 60 };

test("对的令牌能过", async () => {
  const c = await verifyIdentityToken(await sign(good), jwks, AUD, NOW);
  assert.equal(c.sub, "abc");
});
test("过期拒", async () => {
  await assert.rejects(verifyIdentityToken(await sign({ ...good, exp: NOW - 1 }), jwks, AUD, NOW), /expired/);
});
test("别的 App 的拒", async () => {
  await assert.rejects(verifyIdentityToken(await sign({ ...good, aud: "com.other" }), jwks, AUD, NOW), /bad aud/);
});
test("别的签发方拒", async () => {
  await assert.rejects(verifyIdentityToken(await sign({ ...good, iss: "https://evil" }), jwks, AUD, NOW), /bad iss/);
});
test("改过内容拒", async () => {
  const t = (await sign(good)).split(".");
  t[1] = b64({ ...good, sub: "someone-else" });
  await assert.rejects(verifyIdentityToken(t.join("."), jwks, AUD, NOW), /bad signature/);
});
test("alg none 拒", async () => {
  const t = b64({ alg: "none", kid: "k1" }) + "." + b64(good) + ".";
  await assert.rejects(verifyIdentityToken(t, jwks, AUD, NOW), /bad alg/);
});
test("不认识的钥匙拒", async () => {
  await assert.rejects(verifyIdentityToken(await sign(good, { alg: "RS256", kid: "other" }), jwks, AUD, NOW), /unknown key/);
});
