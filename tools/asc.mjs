// 用 App Store Connect API 做苹果后台的几件事（在 Windows 上跑，不用 Mac）：
//   node tools/asc.mjs check            密钥能不能用：列出 Bundle ID、App
//   node tools/asc.mjs register         注册 com.avenmeee.fengji，打开 Sign in with Apple，打印团队号
//   node tools/asc.mjs profile          用已有上架证书建描述文件 Fengji AppStore，存进 ASC_DIR\dist\
//   node tools/asc.mjs testers          App 记录建好后：建内部测试组，把账号持有人加进去
//   node tools/asc.mjs builds           最近几次上传的构建处理到哪了
// 密钥读 ASC_DIR，只在内存里签 15 分钟的令牌，不打印、不复制。只碰蜂集自己的记录。
import crypto from "crypto";
import fs from "fs";
import path from "path";

const DIR = process.env.ASC_DIR;  // 密钥目录，不进仓库
if (!DIR) { console.log("要设环境变量 ASC_DIR"); process.exit(1); }
const APP_ID = "com.avenmeee.fengji", PROFILE = "Fengji AppStore";

const p8 = fs.existsSync(DIR) && fs.readdirSync(DIR).find(f => /^AuthKey_[A-Z0-9]+\.p8$/.test(f));
if (!p8) { console.log("没找到 API 密钥"); process.exit(1); }
const KEY_ID = p8.slice(8, -3);
const ISSUER = fs.readFileSync(path.join(DIR, "issuer.txt"), "utf8").trim();

function token() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = o => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = b64({ alg: "ES256", kid: KEY_ID, typ: "JWT" }) + "." + b64({ iss: ISSUER, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" });
  const sig = crypto.sign("sha256", Buffer.from(head), { key: fs.readFileSync(path.join(DIR, p8)), dsaEncoding: "ieee-p1363" });
  return head + "." + sig.toString("base64url");
}

async function api(method, p, body) {
  const r = await fetch("https://api.appstoreconnect.apple.com" + p, {
    method,
    headers: { authorization: "Bearer " + token(), "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await r.text();
  let j = null; try { j = JSON.parse(text); } catch (e) {}
  if (!r.ok) throw new Error(`${method} ${p} → ${r.status} ${(j && j.errors || []).map(e => e.detail || e.title).join("；") || text.slice(0, 300)}`);
  return j;
}

const findBundle = async () => ((await api("GET", `/v1/bundleIds?filter[identifier]=${APP_ID}&limit=20`)).data || []).find(b => b.attributes.identifier === APP_ID);
const findApp = async () => ((await api("GET", `/v1/apps?filter[bundleId]=${APP_ID}`)).data || [])[0];

const cmd = process.argv[2] || "check";
try {
  if (cmd === "check") {
    const b = await api("GET", "/v1/bundleIds?limit=50");
    console.log("密钥能用。已有 Bundle ID：" + ((b.data || []).map(x => x.attributes.identifier).join("、") || "没有"));
    const a = await api("GET", "/v1/apps?limit=20");
    console.log("已有 App：" + ((a.data || []).map(x => `${x.attributes.name}（${x.attributes.bundleId}）`).join("、") || "没有"));
  } else if (cmd === "register") {
    let got = await findBundle();
    if (!got) {
      got = (await api("POST", "/v1/bundleIds", { data: { type: "bundleIds", attributes: { identifier: APP_ID, name: "Fengji", platform: "IOS" } } })).data;
      console.log("注册了 " + APP_ID);
    } else console.log("已经有 " + APP_ID);
    const have = ((await api("GET", `/v1/bundleIds/${got.id}/bundleIdCapabilities`)).data || []).map(c => c.attributes.capabilityType);
    if (!have.includes("APPLE_ID_AUTH")) {
      await api("POST", "/v1/bundleIdCapabilities", { data: { type: "bundleIdCapabilities", attributes: { capabilityType: "APPLE_ID_AUTH", settings: [{ key: "APPLE_ID_AUTH_APP_CONSENT", options: [{ key: "PRIMARY_APP_CONSENT" }] }] }, relationships: { bundleId: { data: { type: "bundleIds", id: got.id } } } } });
      console.log("打开了 Sign in with Apple");
    } else console.log("Sign in with Apple 已经开着");
    console.log("团队号：" + got.attributes.seedId);
  } else if (cmd === "profile") {
    const certId = fs.readFileSync(path.join(DIR, "dist", "cert-id.txt"), "utf8").trim(), bundle = await findBundle();
    let p = ((await api("GET", `/v1/profiles?filter[name]=${encodeURIComponent(PROFILE)}&limit=5`)).data || []).find(x => x.attributes.name === PROFILE);
    if (!p) {
      p = (await api("POST", "/v1/profiles", { data: { type: "profiles", attributes: { name: PROFILE, profileType: "IOS_APP_STORE" }, relationships: { bundleId: { data: { type: "bundleIds", id: bundle.id } }, certificates: { data: [{ type: "certificates", id: certId }] } } } })).data;
      console.log("建了描述文件：" + PROFILE);
    } else console.log("描述文件已经有了：" + PROFILE);
    fs.writeFileSync(path.join(DIR, "dist", "fengji.mobileprovision"), Buffer.from(p.attributes.profileContent, "base64"));
  } else if (cmd === "testers") {
    const app = await findApp();
    if (!app) { console.log("App Store Connect 里还没有这个 App 的记录"); process.exit(1); }
    const groups = (await api("GET", `/v1/apps/${app.id}/betaGroups`)).data || [];
    let g = groups.find(x => x.attributes.isInternalGroup);
    if (!g) {
      g = (await api("POST", "/v1/betaGroups", { data: { type: "betaGroups", attributes: { name: "自己", isInternalGroup: true, hasAccessToAllBuilds: true }, relationships: { app: { data: { type: "apps", id: app.id } } } } })).data;
      console.log("建了内部测试组“自己”");
    } else console.log(`已经有内部测试组“${g.attributes.name}”`);
    const users = (await api("GET", "/v1/users?limit=50")).data || [];
    const me = users.find(u => (u.attributes.roles || []).includes("ACCOUNT_HOLDER")) || users[0];
    const testers = (await api("GET", `/v1/betaGroups/${g.id}/betaTesters?limit=50`)).data || [];
    if (testers.some(t => (t.attributes.email || "").toLowerCase() === (me.attributes.username || "").toLowerCase())) console.log("账号持有人已经在组里");
    else {
      await api("POST", "/v1/betaTesters", { data: { type: "betaTesters", attributes: { email: me.attributes.username, firstName: me.attributes.firstName, lastName: me.attributes.lastName }, relationships: { betaGroups: { data: [{ type: "betaGroups", id: g.id }] } } } });
      console.log("把账号持有人加进组了");
    }
  } else if (cmd === "builds") {
    const app = await findApp();
    if (!app) { console.log("还没有 App 记录"); process.exit(1); }
    const b = (await api("GET", `/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=5`)).data || [];
    if (!b.length) console.log("还没有上传过构建");
    for (const x of b) console.log(`构建 ${x.attributes.version}：${x.attributes.processingState}，上传于 ${x.attributes.uploadedDate}`);
  } else console.log("用法：node tools/asc.mjs check | register | profile | testers | builds");
} catch (e) {
  console.log("出错：" + e.message);
  process.exit(1);
}
