// 蜂集后端：买、卖、租房的条目，登录，照片，举报、屏蔽、删号、管理。
import { describePhoto, groupPhotos, tagWords } from "./ai.js";
import { exchangeCode, fetchAppleKeys, revokeToken, verifyIdentityToken } from "./apple.js";
import { listingPage, privacyPage, rulesPage, supportPage } from "./pages.js";
import { pushToUser } from "./push.js";

const CATS = ["furn", "elec", "kitchen", "art", "other"];
const CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"];
const BUMP_EVERY = 24 * 3600 * 1000;
const REASONS = ["违规内容", "虚假信息", "骚扰或诈骗", "其他", "原帖人申请删除"];
// 原帖人申请删除：进管理员的举报列表，但不算进自动隐藏
const OWNER_ASK = "原帖人申请删除";
const MAX_PHOTOS = 30, MAX_RENT_PHOTOS = 30, MAX_RENT_DESC = 5000, MAX_PHOTO_BYTES = 1_500_000;
const AUTO_HIDE_REPORTS = 3;
const MAX_ANON_REPORTS = 3;  // 同一条目没登录的举报最多留几条，免得刷屏挤掉真举报
// 发布每人每天 30 条：一次批量最多 30 张照片，分出来最多 30 件，得放得下（11-01 用户定，从 10 放宽）
const LIMITS = { post: 30, photo: 60 }, SITE_PHOTO_LIMIT = 2000;
const MAX_GROUP_PHOTOS = 30, MAX_GROUP_PHOTO_BYTES = 400_000;
const MAX_LIVE_LISTINGS = 50;
const PAGE = 40;
const GROUP_MAX_AGE = 10 * 86400 * 1000;  // 群里发了超过 10 天的不导入：旧帖多半卖掉了。导进来的不再过期，靠排序自然沉下去
const GROUP_BACKFILL_SINCE = Date.parse("2026-10-01T04:00:00Z");  // 补录：导入接口带 backfill: true 时，收 2026-10-01 00:00 美东及以后的帖子，更早的不收。只有 ADMIN_TOKEN 进得来
const SOLD_SHOWN = 7 * 86400000;
const DELETED_KEEP = 30 * 86400000;  // 删掉的帖子照片留 30 天，在“记录”里能一步重新上架  // 卖完的在买、租列表里再留 7 天
const GROUP_UID = "0".repeat(32);  // 群里搬来的条目挂在这个编号下，不对应真人
// 导入时拦下联系方式和门牌：这类信息不能存
const CONTACT_PATTERNS = [/微信号?\s*[:：]?\s*[A-Za-z][-_A-Za-z0-9]{5,}/, /\b(wx|vx|wechat)\s*[:：]?\s*[-_A-Za-z0-9]{5,}/i, /(?<!\d)1\d{10}(?!\d)/, /(?<!\d)(\+?1[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}(?!\d)/];
const ADDRESS_PATTERN = /\b\d{1,5}\s+[A-Za-z][A-Za-z. ]*\b(st|street|ave|avenue|rd|road|dr|drive|ln|lane|blvd|ct|court|way|pl|place|hwy)\b/i;

// 发布前过滤。命中就不让发（规则 1.2：要有过滤）。
const BANNED = [/约炮/, /裸聊/, /援交/, /代孕/, /枪支/, /冰毒/, /大麻/, /代写/, /代考/, /假证/, /办证/, /毕业证/, /学位证/, /学历认证/, /学位认证/, /留服认证/, /代办/, /成绩单/, /换汇/, /代换/, /换美元/, /换美金/, /换人民币/, /美元换/, /美金换/, /人民币换/, /\bdiploma\b/i, /赌博/, /博彩/, /\bescort\b/i, /\bcocaine\b/i, /\bfentanyl\b/i,
  // 10-31 竞品调研补的。不单拦“烟”字，免得误伤烟雾报警器、烟灰缸
  /电子烟/, /烟弹/, /\bvapes?\b/i, /\bjuul\b/i, /香烟/, /雪茄/, /处方药/, /代付/, /代缴/, /垫付/, /学费折扣/, /日结/];

class Fail extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
const newId = () => crypto.randomUUID().replace(/-/g, "");
const today = () => new Date().toISOString().slice(0, 10);

async function sha256(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, "0")).join("");
}

async function bodyOf(req) {
  try { return await req.json(); } catch (e) { throw new Fail(400, "bad_json"); }
}

// ---- 登录 ----
async function currentUser(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  if (!m) return null;
  const hash = await sha256(m[1]);
  const u = await env.DB.prepare("SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?").bind(hash).first();
  if (!u || u.banned) return null;
  return u;
}
async function needUser(req, env) {
  const u = await currentUser(req, env);
  if (!u) throw new Fail(401, "login_required");
  return u;
}
async function needAgreed(req, env) {
  const u = await needUser(req, env);
  if (!u.agreed_at) throw new Fail(403, "terms_required");
  return u;
}
async function needAdmin(req, env) {
  const u = await needUser(req, env);
  if (!u.is_admin) throw new Fail(403, "forbidden");
  return u;
}
async function isStaff(req, env) {
  try { await needStaff(req, env); return true; } catch (e) { return false; }
}

// 处理举报：管理员在 App 里登录，或者定时任务拿 ADMIN_TOKEN。后者没有账号，id 是 null
async function needStaff(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  if (env.ADMIN_TOKEN && m && m[1] === env.ADMIN_TOKEN) return { id: null, operator: true };
  return needAdmin(req, env);
}

async function startSession(env, userId) {
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  const token = [...raw].map(b => b.toString(16).padStart(2, "0")).join("");
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, created_at) VALUES (?, ?, ?)").bind(await sha256(token), userId, Date.now()).run();
  return token;
}

// 昵称和头像颜色：没改过就由账号 id 算，同一个人始终一样
const defaultName = id => "同学 " + String(id).slice(-3).toUpperCase();
const defaultColor = id => (parseInt(String(id).slice(0, 6), 16) || 0) % 6;
const meOf = u => ({ id: u.id, isAdmin: !!u.is_admin, agreed: !!u.agreed_at, name: u.nickname || defaultName(u.id), color: u.avatar_color ?? defaultColor(u.id), named: !!u.nickname, avatar: u.avatar_key ? "/p/" + u.avatar_key : null, aiConsent: !!u.ai_consent_at });
const NAME_NOT_ALLOWED = /官方|管理员|客服|蜂集|admin|apple|微信|weixin|\bvx\b|\bwx\b|\d{6,}/i;
const SELLER_COLUMNS = "(SELECT nickname FROM users u WHERE u.id = l.user_id) AS seller_nick, (SELECT avatar_color FROM users u WHERE u.id = l.user_id) AS seller_color, (SELECT avatar_key FROM users u WHERE u.id = l.user_id) AS seller_avatar";
const MAX_AVATAR_BYTES = 400 * 1024, MAX_THUMB_BYTES = 80 * 1024;

async function loginWithSub(env, sub, refresh) {
  let u = await env.DB.prepare("SELECT * FROM users WHERE apple_sub = ?").bind(sub).first();
  if (u && u.banned) throw new Fail(403, "banned");
  if (!u) {
    const id = newId(), now = Date.now();
    await env.DB.prepare("INSERT INTO users (id, apple_sub, apple_refresh, created_at) VALUES (?, ?, ?, ?)").bind(id, sub, refresh, now).run();
    u = { id, is_admin: 0, agreed_at: null };
  } else if (refresh) {
    await env.DB.prepare("UPDATE users SET apple_refresh = ? WHERE id = ?").bind(refresh, u.id).run();
  }
  return { token: await startSession(env, u.id), me: meOf(u) };
}

async function login(req, env) {
  const b = await bodyOf(req);
  let claims;
  try {
    claims = await verifyIdentityToken(b.identityToken, await fetchAppleKeys(), env.APPLE_AUDIENCE);
  } catch (e) {
    throw new Fail(401, "bad_identity");
  }
  const refresh = await exchangeCode(env, b.authorizationCode).catch(e => { console.error("apple exchangeCode", e?.message || e); return null; });
  if (!refresh && b.authorizationCode) console.error("apple exchangeCode: no refresh token");
  return json(await loginWithSub(env, claims.sub, refresh));
}

// 只在本机 wrangler dev 用：.dev.vars 里配 DEV_LOGIN=1。线上没有这个变量。
async function devLogin(req, env) {
  if (env.DEV_LOGIN !== "1") throw new Fail(404, "not_found");
  const b = await bodyOf(req);
  return json(await loginWithSub(env, "dev-" + String(b.name || "a"), null));
}

// ---- 条目 ----
function clean(s, max) { return String(s ?? "").trim().slice(0, max); }

// 选填的是否：没填 0，是 1，否 2；没填的详情不显示
const triOf = v => (v === true ? 1 : v === false ? 2 : 0);
const triView = v => (v === 1 ? true : v === 2 ? false : null);

function dayOf(v) {
  if (v === "" || v == null) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) throw new Fail(400, "bad_date");
  return v;
}

// 微信号：字母开头，6～20 位，字母、数字、下划线、减号；也过违禁词
const WECHAT_ID = /^[a-zA-Z][a-zA-Z0-9_-]{5,19}$/;
function checkWechat(contact) {
  if (!WECHAT_ID.test(contact)) throw new Fail(422, "bad_wechat");
  if (BANNED.some(r => r.test(contact))) throw new Fail(422, "not_allowed");
}

function checkListing(b, userId, existing = []) {
  const kind = b.kind;
  if (kind !== "goods" && kind !== "rent") throw new Fail(400, "bad_kind");
  const title = clean(b.title, 40), place = clean(b.place, 40), descr = clean(b.desc, kind === "rent" ? MAX_RENT_DESC : 500), contact = clean(b.contact, 40);
  // 方便的时间：东西是方便取货，房子是方便看房
  const availTime = clean(b.availTime, 40);
  const price = Number(b.price);
  if (!title) throw new Fail(400, "need_title");
  if (!Number.isInteger(price) || price < 0 || price > 1_000_000) throw new Fail(400, "bad_price");
  if (kind === "rent" && price === 0) throw new Fail(400, "bad_price");
  if (kind === "rent" && !place) throw new Fail(400, "need_place");
  const text = [title, place, descr, availTime].join(" ");
  if (BANNED.some(r => r.test(text))) throw new Fail(422, "not_allowed");
  if (contact) checkWechat(contact);

  const photos = Array.isArray(b.photos) ? b.photos : [];
  if (photos.length > (kind === "rent" ? MAX_RENT_PHOTOS : MAX_PHOTOS)) throw new Fail(400, "too_many_photos");
  for (const k of photos) {
    if (existing.includes(k)) continue;
    if (typeof k !== "string" || !k.startsWith(userId + "/") || !/^[0-9a-f]+\/[0-9a-f]+\.jpg$/.test(k)) throw new Fail(400, "bad_photo");
  }

  const out = { kind, title, price, place, descr, contact, avail_time: availTime || null, photos: JSON.stringify(photos), cat: null, cond: null, from_date: null, to_date: null, from_prec: null, to_prec: null, lease_end: null, utilities: 0, private_bath: 0, delivery: null, delivery_fee: null, pickup_before: null, pickup_after: null, long_term: 0, furnished: 0, room_type: null, unit_type: null, furniture: null, internet: 0, deposit: null, app_fee: null, parking: null, pets: null, roommates: null };
  if (kind === "goods") {
    // 只有照片、名字、价格、微信号是必须的；分类没选归其他，其余没填就不显示
    const cat = b.cat == null || b.cat === "" ? "other" : b.cat;
    if (!CATS.includes(cat)) throw new Fail(400, "bad_cat");
    const cond = b.cond == null || b.cond === "" ? null : b.cond;
    if (cond && !CONDS.includes(cond)) throw new Fail(400, "bad_cond");
    if (!photos.length) throw new Fail(400, "need_photo");
    const delivery = b.delivery == null || b.delivery === "" ? null : b.delivery;
    if (delivery && !["pickup", "deliver", "both"].includes(delivery)) throw new Fail(400, "bad_delivery");
    out.cat = cat; out.cond = cond; out.delivery = delivery;
    if (delivery && delivery !== "pickup" && b.deliveryFee != null) {
      const fee = Number(b.deliveryFee);
      if (!Number.isInteger(fee) || fee < 0 || fee > 10000) throw new Fail(400, "bad_fee");
      out.delivery_fee = fee;
    }
    out.pickup_before = dayOf(b.pickupBefore); out.pickup_after = dayOf(b.pickupAfter);
  } else {
    if (!photos.length) throw new Fail(400, "need_photo");
    if (typeof b.utilities !== "boolean") throw new Fail(400, "need_utilities");
    if (!["whole", "room", "both"].includes(b.unitType)) throw new Fail(400, "need_unit");
    const money = v => {
      if (v == null || v === "") return null;
      const n = Number(v);
      if (!Number.isInteger(n) || n < 0 || n > 1_000_000) throw new Fail(400, "bad_price");
      return n;
    };
    out.room_type = clean(b.roomType, 40) || null; out.unit_type = b.unitType; out.internet = triOf(b.internet); out.furniture = ["有", "部分有", "没有"].includes(b.furniture) ? b.furniture : null;
    out.deposit = money(b.deposit); out.app_fee = money(b.appFee);
    out.parking = clean(b.parking, 60) || null; out.pets = clean(b.pets, 60) || null; out.roommates = clean(b.roommates, 300) || null;
    const roomText = [out.room_type, out.parking, out.pets, out.roommates].filter(Boolean).join(" ");
    if (BANNED.some(r => r.test(roomText))) throw new Fail(422, "not_allowed");
    out.from_date = dayOf(b.from); out.to_date = b.longTerm ? null : dayOf(b.to); out.lease_end = dayOf(b.leaseEnd);
    out.from_prec = b.fromPrec === "xun" ? "xun" : null; out.to_prec = !b.longTerm && b.toPrec === "xun" ? "xun" : null;
    if (!out.from_date) throw new Fail(400, "need_dates");
    if (!b.longTerm && !out.to_date) throw new Fail(400, "need_dates");
    out.long_term = b.longTerm ? 1 : 0; out.furnished = b.furnished ? 1 : 0;
    out.utilities = b.utilities ? 1 : 0; out.private_bath = triOf(b.privateBath);
    if (out.from_date && out.to_date && out.from_date > out.to_date) throw new Fail(400, "bad_date");
  }
  return out;
}

function view(row, origin, viewer) {
  const mine = !!viewer && viewer.id === row.user_id;
  const group = row.source_type === "group";
  const nick = row.seller_nick ?? (mine ? viewer.nickname : null);
  const color = row.seller_color ?? (mine ? viewer.avatar_color : null);
  const avatar = row.seller_avatar ?? (mine ? viewer.avatar_key : null);
  return {
    id: row.id, uid: row.user_id, kind: row.kind, title: row.title, price: row.price,
    cat: row.cat, cond: row.cond, from: row.from_date, fromPrec: row.from_prec || null, toPrec: row.to_prec || null,
    roomType: row.room_type || null, unitType: row.unit_type || null, internet: triView(row.internet), furniture: row.furniture || null, deposit: row.deposit ?? null, appFee: row.app_fee ?? null,
    parking: row.parking || null, pets: row.pets || null, roommates: row.roommates || null, to: row.to_date,
    leaseEnd: row.lease_end, utilities: !!row.utilities, privateBath: triView(row.private_bath), delivery: row.delivery,
    place: row.place, desc: row.descr, status: row.status, availTime: row.avail_time || null,
    contact: group || !row.contact || (row.status === "off" && !mine) ? null : row.contact,
    soldAt: row.status === "off" ? (row.sold_at ?? null) : null,
    sellerName: group ? (row.source_poster || null) : (nick || defaultName(row.user_id)),
    sellerColor: group ? null : (color ?? defaultColor(row.user_id)),
    sellerNamed: group ? true : !!nick,
    sellerAvatar: group || !avatar ? null : `${origin}/p/${avatar}`,
    sourceType: row.source_type || "self", sourceGroup: row.source_group || null, sourcePoster: row.source_poster || null, sourcePostedAt: row.source_posted_at ?? null,
    score: mine ? null : (row.score ?? null),  // 卖家看不到自己的分
    deliveryFee: row.delivery_fee ?? null, pickupBefore: row.pickup_before || null, pickupAfter: row.pickup_after || null,
    longTerm: !!row.long_term, furnished: !!row.furnished,
    photos: JSON.parse(row.photos).map(k => ({ key: k, url: `${origin}/p/${k}` })),
    createdAt: row.created_at, bumpedAt: row.bumped_at, mine
  };
}

// 首页排序（10-31 用户定）：
// 1. 发布 6 小时内的放最前，按时间新的在前；
// 2. 其余按 划算系数 × 新鲜度，新鲜度每 2.5 天减半（擦亮、重新上架会刷新 bumped_at）；
// 3. 同一个卖家最多连着 2 件，第 3 件往后挪；
// 4. 卖完的（7 天内）放在全部在卖的后面，按卖出时间。
// 分数随时间变，所以第一页记下 now，编进 next 里，后面几页用同一个 now 算，翻页不错位。
const FRESH_TOP = 6 * 3600000, HALF_LIFE_HOURS = 60, FEED_POOL = 300;
const DEAL = { 4: 1.6, 3: 1.3, 2: 1.0, 1: 0.7 };
// next = 分钟数 × 10000 + 偏移；老版本 App 只认数字，这样也能用
const encodeNext = (nowMs, offset) => Math.floor(nowMs / 60000) * 10000 + offset;
const decodeNext = n => n >= 10000 ? { now: Math.floor(n / 10000) * 60000, offset: n % 10000 } : { now: null, offset: n };
const sellerKey = r => r.source_type === "group" ? "g:" + (r.sender_hash || (r.source_poster || "") + "\u0000" + (r.source_group || "")) : "u:" + r.user_id;

// 同一个卖家最多连着 2 件：第 3 件起往后挪，插到别人的后面
function spreadSellers(list) {
  const out = [], rest = list.slice();
  while (rest.length) {
    const n = out.length;
    const blocked = n >= 2 && sellerKey(out[n - 1]) === sellerKey(out[n - 2]) ? sellerKey(out[n - 1]) : null;
    let k = blocked === null ? 0 : rest.findIndex(x => sellerKey(x) !== blocked);
    if (k < 0) k = 0;  // 剩下的都是同一个人，只好接着放
    out.push(rest.splice(k, 1)[0]);
  }
  return out;
}

function rankFeed(rows, now) {
  const byNewest = (a, b) => b.bumped_at - a.bumped_at || (a.id < b.id ? 1 : -1);
  const live = rows.filter(r => r.status !== "off"), sold = rows.filter(r => r.status === "off");
  const fresh = live.filter(r => now - r.bumped_at < FRESH_TOP).sort(byNewest);
  const score = r => (DEAL[r.score] ?? 1.0) * Math.pow(0.5, Math.max(0, now - r.bumped_at) / 3600000 / HALF_LIFE_HOURS);
  const older = live.filter(r => now - r.bumped_at >= FRESH_TOP).map(r => ({ r, s: score(r) }))
    .sort((a, b) => b.s - a.s || (a.r.id < b.r.id ? 1 : -1)).map(x => x.r);
  sold.sort((a, b) => (b.sold_at || 0) - (a.sold_at || 0) || (a.id < b.id ? 1 : -1));
  return [...spreadSellers([...fresh, ...older]), ...sold];
}

// ---- 搜索（11-01）：查询词变形 + 同义词表 + 帖子的 AI 搜索标签 ----
// 同义词表兜底：一组里搜哪个都算。零结果词从 event-stats 里看，再往这里补
const SYNONYMS = [
  ["电脑", "笔记本", "笔记本电脑", "laptop", "macbook", "平板", "ipad"],
  ["显示器", "屏幕", "monitor"],
  ["椅子", "凳子", "chair"],
  ["桌子", "书桌", "desk", "table"],
  ["尺", "尺子", "直尺", "ruler"],
  ["画架", "easel"],
  ["颜料", "paint"],
  ["马克笔", "marker"],
  ["台灯", "灯", "lamp"],
  ["床垫", "mattress"],
  ["沙发", "sofa", "couch"],
  ["冰箱", "fridge"],
  ["微波炉", "microwave"],
  ["自行车", "单车", "bike"],
  ["画画", "画画用的", "画材", "美术用品", "art supplies"],
  ["搬家", "清仓", "moving"]
];
const SUFFIXES = ["子", "儿", "头"];

// 一个查询词的几种写法：去空格、去常见词尾、英文单复数
function directTerms(q) {
  const base = q.toLowerCase().trim();
  const out = new Set([base, base.replace(/\s+/g, "")]);
  for (const t of [...out]) {
    if (/[\u4e00-\u9fff]$/.test(t) && t.length >= 2 && SUFFIXES.includes(t.slice(-1))) out.add(t.slice(0, -1));
    if (/^[a-z][a-z ]*$/.test(t)) {
      if (t.endsWith("es") && t.length > 3) out.add(t.slice(0, -2));
      if (t.endsWith("s") && t.length > 2) out.add(t.slice(0, -1));
      else out.add(t + "s");
    }
  }
  return [...out].filter(Boolean);
}

// 再按同义词表扩开
function searchTerms(q) {
  const out = new Set(directTerms(q));
  for (const t of [...out]) {
    for (const group of SYNONYMS) if (group.includes(t)) group.forEach(w => out.add(w));
  }
  return [...out].filter(Boolean).slice(0, 24);
}

// ---- 语义相近（11-01）：Workers AI 的多语言向量，存在 D1 里。算不出来就只用前两层 ----
const EMBED_MODEL = "@cf/baai/bge-m3";
const EMBED_CACHE = new Map();

// 本机测试不连 AI：按字和字母对散列出一个小向量，像的字多就近
function mockVector(text) {
  const v = new Float32Array(64), s = text.toLowerCase();
  for (let i = 0; i < s.length; i++) v[(s.charCodeAt(i) * 31 + (s.charCodeAt(i + 1) || 0)) % 64] += 1;
  return v;
}

async function embed(env, texts) {
  if (env.AI_MOCK === "1") return texts.map(mockVector);
  if (!env.AI) return null;
  const r = await env.AI.run(EMBED_MODEL, { text: texts });
  return r.data.map(d => Float32Array.from(d));
}

function cosine(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return na && nb ? dot / Math.sqrt(na * nb) : 0;
}

const toBlob = v => new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
const fromBlob = b => {
  if (!b) return null;
  const bytes = b instanceof ArrayBuffer ? new Uint8Array(b) : Uint8Array.from(b);
  return new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength >> 2);
};

async function queryVector(env, q) {
  const key = q.toLowerCase();
  if (EMBED_CACHE.has(key)) return EMBED_CACHE.get(key);
  try {
    const v = (await embed(env, [key]))?.[0] || null;
    if (EMBED_CACHE.size > 500) EMBED_CACHE.clear();
    EMBED_CACHE.set(key, v);
    return v;
  } catch (e) {
    console.error("embed q", e && e.message);
    return null;
  }
}

async function embedListing(env, id) {
  const row = await env.DB.prepare("SELECT title, tags, descr FROM listings WHERE id = ?").bind(id).first();
  if (!row) return false;
  const text = [row.title, (row.tags || "").trim(), (row.descr || "").slice(0, 300)].filter(Boolean).join("\n");
  const v = (await embed(env, [text]))?.[0];
  if (!v) return false;
  await env.DB.prepare("UPDATE listings SET embedding = ? WHERE id = ?").bind(toBlob(v), id).run();
  return true;
}

// 搜索时分三层：名字直接有；同义词、备注、地点、标签有；语义相近。完全不沾边的不给
// 英文按整词算（table 不算 tablet），中文按包含
const hasTerm = (text, t) => /^[a-z0-9 ]+$/.test(t) ? new RegExp(`(^|[^a-z0-9])${t}([^a-z0-9]|$)`).test(text) : text.includes(t);

function searchTier(row, direct, expanded, qv, minSim) {
  const title = (row.title || "").toLowerCase();
  if (direct.some(t => hasTerm(title, t))) return { tier: 1, sim: null };
  const rest = [title, row.descr, row.place, row.tags].map(x => (x || "").toLowerCase());
  if (expanded.some(t => rest.some(x => hasTerm(x, t)))) return { tier: 2, sim: null };
  const sim = qv ? cosine(qv, fromBlob(row.embedding)) : 0;
  return sim >= minSim ? { tier: 3, sim } : { tier: 0, sim };
}

// 发帖、改帖以后在后台做，不耽误返回。拿不到 ctx 就直接等
const CTX = new WeakMap();
function later(req, work) {
  const p = work.catch(e => console.error("later", e && e.message));
  const ctx = CTX.get(req);
  if (ctx) ctx.waitUntil(p);
  return ctx ? null : p;
}

// 帖子的搜索标签：只给 AI 文字，不传图；记进全站预算，不扣卖家的额度。失败或没钱了就跳过。最后算向量
async function tagListing(env, id) {
  const tagged = await tagOnly(env, id).catch(e => { console.error("tag", id, e && e.message); return false; });
  await embedListing(env, id).catch(e => console.error("embed", id, e && e.message));
  return tagged;
}

async function tagOnly(env, id) {
  if (!aiEnabled(env)) return false;
  if (await monthSum(env, "ai_microusd") >= Number(env.AI_MONTHLY_USD || 40) * 1e6) return false;
  const row = await env.DB.prepare("SELECT title, descr, cat, kind FROM listings WHERE id = ?").bind(id).first();
  if (!row) return false;
  const r = await tagWords(env, { title: row.title, descr: (row.descr || "").slice(0, 300), cat: row.cat, kind: row.kind });
  await bumpBy(env, "*", "ai_microusd", r.microUsd);
  const tags = [...new Set(r.tags.map(t => scrubText(t).toLowerCase()).filter(t => t && t.length <= 20))].slice(0, 10);
  await env.DB.prepare("UPDATE listings SET tags = ? WHERE id = ?").bind(" " + tags.join(" ") + " ", id).run();
  return true;
}

// 没标签、没向量的补上：管理员接口和每天的定时任务都用它。一次最多 n 条
async function tagMissing(env, n) {
  const rows = (await env.DB.prepare("SELECT id, tags IS NULL AS needTags FROM listings WHERE (tags IS NULL OR embedding IS NULL) AND status IN ('on', 'reserved', 'off') ORDER BY bumped_at DESC LIMIT ?").bind(n).all()).results;
  let done = 0, embedded = 0;
  for (const r of rows) {
    try {
      if (r.needTags && await tagOnly(env, r.id)) done++;
      if (await embedListing(env, r.id)) embedded++;
    } catch (e) {
      console.error("tag", r.id, e && e.message);
    }
  }
  const left = (await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE (tags IS NULL OR embedding IS NULL) AND status IN ('on', 'reserved', 'off')").first()).n;
  return { done, embedded, left };
}

async function backfillTags(req, env, url) {
  await needStaff(req, env);
  const n = Math.min(50, Math.max(1, Number(url.searchParams.get("n")) || 20));
  return json(await tagMissing(env, n));
}

async function feed(req, env, url) {
  const viewer = await currentUser(req, env);
  const p = url.searchParams, kind = p.get("kind") === "rent" ? "rent" : "goods";
  const paged = decodeNext(Math.max(0, Math.floor(Number(p.get("offset")) || 0)));
  const now = paged.now ?? Date.now(), offset = paged.offset;
  // 每页几条：默认 40；测试可以传小一点的
  const size = Math.min(PAGE, Math.max(5, Math.floor(Number(p.get("n")) || PAGE)));
  // 卖完的照样显示 7 天
  const where = ["l.kind = ?", "(l.status IN ('on', 'reserved') OR (l.status = 'off' AND l.sold_at >= ?))"], args = [kind, now - SOLD_SHOWN];
  if (kind === "goods" && CATS.includes(p.get("cat"))) { where.push("l.cat = ?"); args.push(p.get("cat")); }
  const unit = p.get("unit");
  if (kind === "rent" && (unit === "whole" || unit === "room")) { where.push("l.unit_type IN (?, 'both')"); args.push(unit); }
  const q = clean(p.get("q"), 40);
  if (viewer) { where.push("l.user_id NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?)"); args.push(viewer.id); }
  // 按性价比档筛：在这里筛，再取候选，老帖才不会漏。没打分的不算；卖完的不算；自己的也不算（卖家看不到自己的分）
  const score = Number(p.get("score"));
  if (kind === "goods" && [1, 2, 3, 4].includes(score)) {
    where.push("l.score = ?", "l.status IN ('on', 'reserved')"); args.push(score);
    if (viewer) { where.push("l.user_id != ?"); args.push(viewer.id); }
  }
  // 候选先取最近的 300 条，在这里算分、打散、切页；量大了再搬进数据库。只有搜索才带向量
  const rows = (await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE ${where.join(" AND ")} ORDER BY l.bumped_at DESC, l.id DESC LIMIT ?`).bind(...args, FEED_POOL).all()).results;
  let ranked, tierOf = null;
  if (q) {
    // 分层：一层排完再排下一层，同一层里照旧按综合分；卖完的都放最后
    const direct = directTerms(q), expanded = searchTerms(q);
    const qv = await queryVector(env, q);
    // bge-m3 对短词偏高：不相干的也有 0.4～0.5，相近的 0.55 以上（11-01 拿 32 条样本试的，总管定 0.57）
    const minSim = Number(env.SEARCH_MIN_SIM || (env.AI_MOCK === "1" ? 0.5 : 0.57));
    tierOf = new Map(rows.map(r => [r.id, searchTier(r, direct, expanded, qv, minSim)]));
    const hit = rows.filter(r => tierOf.get(r.id).tier > 0);
    // 第三层按相似度排，越像越前
    const layer = (list, t) => t === 3 ? list.sort((a, b) => tierOf.get(b.id).sim - tierOf.get(a.id).sim) : rankFeed(list, now);
    const live = [1, 2, 3].flatMap(t => layer(hit.filter(r => r.status !== "off" && tierOf.get(r.id).tier === t), t));
    const sold = [1, 2, 3].flatMap(t => layer(hit.filter(r => r.status === "off" && tierOf.get(r.id).tier === t), t));
    ranked = [...live, ...sold];
  } else {
    ranked = rankFeed(rows, now);
  }
  const pageRows = ranked.slice(offset, offset + size);
  const more = offset + size < ranked.length;
  // 调阈值用：管理员带 debug=1 能看到每条在第几层、相似度多少
  const debug = q && p.get("debug") === "1" && await isStaff(req, env);
  return json({
    items: pageRows.map(r => debug ? { ...view(r, url.origin, viewer), tier: tierOf.get(r.id).tier, sim: tierOf.get(r.id).sim } : view(r, url.origin, viewer)),
    next: more ? encodeNext(now, offset + size) : null
  });
}


// ---- 卖家主页：只给在架上的（在售、已预订），不带记录 ----
// 被封的、不存在的、被我屏蔽的，打不开
async function sellerPage(req, env, url, uid) {
  const viewer = await currentUser(req, env);
  const u = uid === GROUP_UID ? null : await env.DB.prepare("SELECT id, nickname, avatar_color, avatar_key, banned FROM users WHERE id = ?").bind(uid).first();
  if (!u || u.banned) throw new Fail(404, "not_found");
  if (viewer && await env.DB.prepare("SELECT 1 AS x FROM blocks WHERE user_id = ? AND blocked_id = ?").bind(viewer.id, uid).first()) throw new Fail(404, "not_found");
  const rows = (await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE l.user_id = ? AND l.status IN ('on', 'reserved', 'off') ORDER BY l.status = 'off', l.bumped_at DESC, l.id DESC LIMIT 100`).bind(uid).all()).results;
  return json({
    seller: { id: uid, name: u.nickname || defaultName(uid), color: u.avatar_color ?? defaultColor(uid), named: !!u.nickname, avatar: u.avatar_key ? `${url.origin}/p/${u.avatar_key}` : null, group: false, groupName: null },
    items: rows.map(r => view(r, url.origin, viewer))
  });
}

// 从一条帖子找发帖人。自己发的就是那个账号；群里搬来的，同一个发送者（有 sender_hash 按它，没有按群昵称加群）
// 的其他群帖。用帖子 id 当入口，不对外露 sender_hash。
async function posterPage(req, env, url, id) {
  const row = await env.DB.prepare("SELECT user_id, source_type, source_group, source_poster, sender_hash, status FROM listings WHERE id = ?").bind(id).first();
  if (!row || row.status === "deleted" || row.status === "hidden" || row.status === "removed") throw new Fail(404, "not_found");
  if (row.source_type !== "group") return sellerPage(req, env, url, row.user_id);
  const viewer = await currentUser(req, env);
  const same = row.sender_hash ? ["l.sender_hash = ?", [row.sender_hash]] : ["l.sender_hash IS NULL AND l.source_poster = ? AND l.source_group = ?", [row.source_poster, row.source_group]];
  const rows = (await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE l.source_type = 'group' AND l.status IN ('on', 'reserved', 'off') AND ${same[0]} ORDER BY l.status = 'off', l.bumped_at DESC, l.id DESC LIMIT 100`)
    .bind(...same[1]).all()).results;
  return json({
    seller: { id: null, name: row.source_poster || "群友", color: null, named: true, avatar: null, group: true, groupName: row.source_group || null },
    items: rows.map(r => view(r, url.origin, viewer))
  });
}

async function oneListing(req, env, url, id) {
  const viewer = await currentUser(req, env);
  const row = await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE l.id = ?`).bind(id).first();
  const canSeeHidden = viewer && row && (viewer.id === row.user_id || viewer.is_admin);
  if (!row || (row.status === "hidden" && !canSeeHidden)) throw new Fail(404, "not_found");
  if (row.status === "deleted" && !(viewer && viewer.id === row.user_id)) throw new Fail(404, "not_found");
  // 被举报后作者删掉的：只有管理员还看得到
  if (row.status === "removed" && !(viewer && viewer.is_admin)) throw new Fail(404, "not_found");
  return json(view(row, url.origin, viewer));
}

async function bump(env, userId, what) {
  const day = today();
  const r = await env.DB.prepare("INSERT INTO daily_counts (day, user_id, what, n) VALUES (?, ?, ?, 1) ON CONFLICT (day, user_id, what) DO UPDATE SET n = n + 1 RETURNING n").bind(day, userId, what).first();
  return r.n;
}

async function createListing(req, env, url) {
  const u = await needAgreed(req, env);
  const body = await bodyOf(req);
  const v = checkListing(body, u.id);
  // 东西的信息会发给 AI 打分，要先同意（5.1.2(i)）
  if (v.kind === "goods" && !u.ai_consent_at) {
    if (body.aiConsent !== true) throw new Fail(400, "need_ai_consent");
    await env.DB.prepare("UPDATE users SET ai_consent_at = ? WHERE id = ?").bind(Date.now(), u.id).run();
  }
  const live = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND status = 'on'").bind(u.id).first();
  if (live.n >= MAX_LIVE_LISTINGS) throw new Fail(429, "too_many_listings");
  if (await bump(env, u.id, "post") > LIMITS.post) throw new Fail(429, "daily_limit");
  const id = newId(), now = Date.now();
  await bump(env, "*", "post");
  await env.DB.prepare("INSERT INTO listings (id, user_id, kind, title, price, cat, cond, from_date, to_date, lease_end, from_prec, to_prec, utilities, private_bath, delivery, delivery_fee, pickup_before, pickup_after, long_term, furnished, room_type, unit_type, furniture, internet, deposit, app_fee, parking, pets, roommates, place, descr, contact, avail_time, photos, status, created_at, updated_at, bumped_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'on', ?, ?, ?)")
    .bind(id, u.id, v.kind, v.title, v.price, v.cat, v.cond, v.from_date, v.to_date, v.lease_end, v.from_prec, v.to_prec, v.utilities, v.private_bath, v.delivery, v.delivery_fee, v.pickup_before, v.pickup_after, v.long_term, v.furnished, v.room_type, v.unit_type, v.furniture, v.internet, v.deposit, v.app_fee, v.parking, v.pets, v.roommates, v.place, v.descr, v.contact, v.avail_time, v.photos, now, now, now).run();
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  await later(req, tagListing(env, id));
  return json(view(row, url.origin, u), 201);
}

async function ownedOrFail(env, id, u, allowAdmin = false) {
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  if (row.user_id !== u.id && !(allowAdmin && u.is_admin)) throw new Fail(403, "forbidden");
  return row;
}

async function updateListing(req, env, url, id) {
  const u = await needAgreed(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status === "hidden") throw new Fail(403, "hidden");
  const body = await bodyOf(req);
  const relist = row.status === "deleted" && body.relist === true;
  if ((row.status === "deleted" && !relist) || row.status === "removed") throw new Fail(400, "deleted");
  const v = checkListing(body, u.id, JSON.parse(row.photos));
  if (v.kind !== row.kind) throw new Fail(400, "bad_kind");
  if (relist) {
    const live = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND status = 'on'").bind(u.id).first();
    if (live.n >= MAX_LIVE_LISTINGS) throw new Fail(429, "too_many_listings");
  }
  await env.DB.prepare("UPDATE listings SET title=?, price=?, cat=?, cond=?, from_date=?, to_date=?, lease_end=?, from_prec=?, to_prec=?, utilities=?, private_bath=?, delivery=?, delivery_fee=?, pickup_before=?, pickup_after=?, long_term=?, furnished=?, room_type=?, unit_type=?, furniture=?, internet=?, deposit=?, app_fee=?, parking=?, pets=?, roommates=?, place=?, descr=?, contact=?, avail_time=?, photos=?, updated_at=? WHERE id=?")
    .bind(v.title, v.price, v.cat, v.cond, v.from_date, v.to_date, v.lease_end, v.from_prec, v.to_prec, v.utilities, v.private_bath, v.delivery, v.delivery_fee, v.pickup_before, v.pickup_after, v.long_term, v.furnished, v.room_type, v.unit_type, v.furniture, v.internet, v.deposit, v.app_fee, v.parking, v.pets, v.roommates, v.place, v.descr, v.contact, v.avail_time, v.photos, Date.now(), id).run();
  if (v.price !== row.price) await clearScore(env, id);
  // 名字、备注、分类变了，搜索标签重做
  if (v.title !== row.title || v.descr !== row.descr || v.cat !== row.cat) {
    await env.DB.prepare("UPDATE listings SET tags = NULL WHERE id = ?").bind(id).run();
    await later(req, tagListing(env, id));
  }
  const kept = new Set(JSON.parse(v.photos));
  await removePhotos(env, JSON.parse(row.photos).filter(k => !kept.has(k)));
  if (relist) {
    const now = Date.now();
    if (row.thumb) await removePhotos(env, [row.thumb]);
    await env.DB.prepare("UPDATE listings SET status = 'on', deleted_at = NULL, thumb = NULL, sold_at = NULL, sold_price = NULL, bumped_at = ?, updated_at = ? WHERE id = ?").bind(now, now, id).run();
  }
  const next = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  return json(view(next, url.origin, u));
}

async function setStatus(req, env, url, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status === "hidden") throw new Fail(403, "hidden");
  if (row.status === "deleted" || row.status === "removed") throw new Fail(400, "deleted");
  const { status, soldPrice } = await bodyOf(req);
  if (!["on", "reserved", "off"].includes(status)) throw new Fail(400, "bad_status");
  // 成交价选填，重新上架就作废
  if (soldPrice !== undefined && soldPrice !== null && (!Number.isInteger(soldPrice) || soldPrice < 0 || soldPrice > 1_000_000)) throw new Fail(400, "bad_price");
  const sold = status === "off" ? (soldPrice ?? null) : null;
  const now = Date.now();
  const soldAt = status === "off" ? (row.status === "off" ? (row.sold_at ?? now) : now) : null;
  await env.DB.prepare("UPDATE listings SET status=?, sold_price=?, sold_at=?, updated_at=? WHERE id=?").bind(status, sold, soldAt, now, id).run();
  if (status === "off" && row.status !== "off") await bump(env, "*", "sold");
  const next = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  return json(view(next, url.origin, u));
}

// 价格变了，分作废，等后台重打
async function clearScore(env, id) {
  await env.DB.prepare("UPDATE listings SET score = NULL, scored_at = NULL WHERE id = ?").bind(id).run();
}

// 一步改价
async function setPrice(req, env, url, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status === "hidden") throw new Fail(403, "hidden");
  if (row.status === "deleted" || row.status === "removed") throw new Fail(400, "deleted");
  const price = Number((await bodyOf(req)).price);
  if (!Number.isInteger(price) || price < 0 || price > 1_000_000 || (row.kind === "rent" && price === 0)) throw new Fail(400, "bad_price");
  await env.DB.prepare("UPDATE listings SET price=?, updated_at=? WHERE id=?").bind(price, Date.now(), id).run();
  if (price !== row.price) await clearScore(env, id);
  const next = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  return json(view(next, url.origin, u));
}

// 擦亮：顶回最新，一条一天一次
async function bumpListing(req, env, url, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status !== "on" && row.status !== "reserved") throw new Fail(400, "not_on");
  const now = Date.now();
  if (now - row.bumped_at < BUMP_EVERY) throw new Fail(429, "too_soon");
  await env.DB.prepare("UPDATE listings SET bumped_at=? WHERE id=?").bind(now, id).run();
  return json(view({ ...row, bumped_at: now }, url.origin, u));
}

async function removePhotos(env, keys) {
  // R2 一次最多删 1000 个
  for (let i = 0; i < keys.length; i += 1000) await env.PHOTOS.delete(keys.slice(i, i + 1000));
}

async function deleteRows(env, rows) {
  await removePhotos(env, rows.flatMap(r => [...JSON.parse(r.photos), ...(r.thumb ? [r.thumb] : [])]));
  for (const r of rows) {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM reports WHERE listing_id = ?").bind(r.id),
      env.DB.prepare("DELETE FROM wants WHERE listing_id = ?").bind(r.id),
      env.DB.prepare("DELETE FROM listings WHERE id = ?").bind(r.id)
    ]);
  }
}

async function deleteListing(req, env, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u, true);
  const purge = new URL(req.url).searchParams.get("purge") === "1";
  if (purge || row.user_id !== u.id || row.source_type === "group") {
    await deleteRows(env, [row]);
    return json({ ok: true });
  }
  if (row.status === "deleted" || row.status === "removed") return json({ ok: true });
  // 被举报隐藏的：删掉就是彻底删，举报留给管理员看，不进“记录”，不能原样重发
  if (row.status === "hidden") {
    await removePhotos(env, JSON.parse(row.photos));
    await env.DB.batch([
      env.DB.prepare("UPDATE listings SET status = 'removed', deleted_at = ?, photos = '[]', score = NULL, scored_at = NULL, sold_price = NULL WHERE id = ?").bind(Date.now(), id),
      env.DB.prepare("DELETE FROM wants WHERE listing_id = ?").bind(id)
    ]);
    return json({ ok: true });
  }
  // 原图都删掉，App 顺手传一张小缩略图留给本人的记录
  let thumb = [];
  const buf = await req.arrayBuffer();
  const head = new Uint8Array(buf.slice(0, 3));
  if (buf.byteLength > 0 && buf.byteLength <= MAX_THUMB_BYTES && head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff) {
    const key = `${u.id}/${newId()}.jpg`;
    await env.PHOTOS.put(key, buf, { httpMetadata: { contentType: "image/jpeg", cacheControl: "private, max-age=86400" } });
    thumb = [key];
  }
  // 照片留 30 天给本人一步重新上架：换成新编号，旧网址马上失效，新编号只有本人的“记录”里有
  const kept = [];
  for (const old of JSON.parse(row.photos)) {
    const o = await env.PHOTOS.get(old);
    if (!o) continue;
    const key = `${u.id}/${newId()}.jpg`;
    await env.PHOTOS.put(key, o.body, { httpMetadata: { contentType: "image/jpeg", cacheControl: "private, max-age=86400" } });
    kept.push(key);
  }
  await removePhotos(env, JSON.parse(row.photos));
  await env.DB.batch([
    env.DB.prepare("UPDATE listings SET status = 'deleted', deleted_at = ?, photos = ?, thumb = ?, score = NULL, scored_at = NULL, sold_price = NULL WHERE id = ?").bind(Date.now(), JSON.stringify(kept), thumb[0] || null, id),
    env.DB.prepare("DELETE FROM wants WHERE listing_id = ?").bind(id),
    env.DB.prepare("DELETE FROM reports WHERE listing_id = ?").bind(id)
  ]);
  return json({ ok: true });
}

async function mine(req, env, url) {
  const u = await needUser(req, env);
  const rows = (await env.DB.prepare("SELECT * FROM listings WHERE user_id = ? AND status != 'removed' ORDER BY created_at DESC LIMIT 200").bind(u.id).all()).results;
  // 成交价和删除时间只给本人看
  return json({ items: rows.map(r => ({ ...view(r, url.origin, u), soldPrice: r.sold_price ?? null, deletedAt: r.deleted_at ?? null, updatedAt: r.updated_at ?? null, thumb: r.thumb ? `${url.origin}/p/${r.thumb}` : null })) });
}

// ---- 照片 ----
async function uploadPhoto(req, env) {
  const u = await needAgreed(req, env);
  const buf = await req.arrayBuffer();
  if (buf.byteLength > MAX_PHOTO_BYTES) throw new Fail(413, "photo_too_big");
  const head = new Uint8Array(buf.slice(0, 3));
  if (!(head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff)) throw new Fail(415, "not_jpeg");
  if (await bump(env, u.id, "photo") > LIMITS.photo) throw new Fail(429, "daily_limit");
  if (await bump(env, "*", "photo") > SITE_PHOTO_LIMIT) throw new Fail(429, "site_limit");
  const key = `${u.id}/${newId()}.jpg`;
  await env.PHOTOS.put(key, buf, { httpMetadata: { contentType: "image/jpeg", cacheControl: "public, max-age=31536000, immutable" } });
  return json({ key }, 201);
}

async function servePhoto(env, key) {
  if (!/^[0-9a-f]+\/[0-9a-f]+\.jpg$/.test(key)) throw new Fail(404, "not_found");
  const o = await env.PHOTOS.get(key);
  if (!o) throw new Fail(404, "not_found");
  return new Response(o.body, { headers: { "content-type": "image/jpeg", "cache-control": "public, max-age=31536000, immutable", etag: o.httpEtag } });
}

// ---- 举报、屏蔽 ----
// 不登录也能举报。匿名举报只给管理员看，不算进自动下架（不然谁都能刷下架）；不存 IP。
async function report(req, env, id) {
  const u = await currentUser(req, env);
  const b = await bodyOf(req);
  if (!REASONS.includes(b.reason)) throw new Fail(400, "bad_reason");
  const row = await env.DB.prepare("SELECT id, user_id FROM listings WHERE id = ?").bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  if (!u) {
    const anon = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE listing_id = ? AND status = 'open' AND reporter_id LIKE 'anon:%'").bind(id).first();
    if (anon.n >= MAX_ANON_REPORTS) return json({ ok: true });
  }
  await env.DB.prepare("INSERT OR IGNORE INTO reports (id, listing_id, reporter_id, reason, note, created_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(newId(), id, u ? u.id : "anon:" + newId(), b.reason, clean(b.note, 300), Date.now()).run();
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE listing_id = ? AND status = 'open' AND reporter_id NOT LIKE 'anon:%' AND reporter_id NOT LIKE 'want:%' AND reporter_id NOT LIKE 'name:%' AND reporter_id NOT LIKE 'avatar:%' AND reason != ?").bind(id, OWNER_ASK).first();
  if (c.n >= AUTO_HIDE_REPORTS) await env.DB.prepare("UPDATE listings SET status = 'hidden' WHERE id = ? AND status IN ('on', 'reserved')").bind(id).run();
  return json({ ok: true });
}

async function block(req, env, targetId) {
  const u = await needUser(req, env);
  if (targetId === u.id) throw new Fail(400, "self");
  await env.DB.prepare("INSERT OR IGNORE INTO blocks (user_id, blocked_id, created_at) VALUES (?, ?, ?)").bind(u.id, targetId, Date.now()).run();
  return json({ ok: true });
}
async function unblock(req, env, targetId) {
  const u = await needUser(req, env);
  await env.DB.prepare("DELETE FROM blocks WHERE user_id = ? AND blocked_id = ?").bind(u.id, targetId).run();
  return json({ ok: true });
}
async function blockList(req, env) {
  const u = await needUser(req, env);
  // 带上昵称和头像，屏蔽名单里认得出是谁
  const rows = (await env.DB.prepare("SELECT b.blocked_id AS id, b.created_at AS at, u.nickname, u.avatar_color, u.avatar_key FROM blocks b LEFT JOIN users u ON u.id = b.blocked_id WHERE b.user_id = ? ORDER BY b.created_at DESC").bind(u.id).all()).results;
  const origin = new URL(req.url).origin;
  return json({ items: rows.map(r => ({ id: r.id, at: r.at, name: r.nickname || defaultName(r.id), color: r.avatar_color ?? defaultColor(r.id), named: !!r.nickname, avatar: r.avatar_key ? `${origin}/p/${r.avatar_key}` : null })) });
}

// ---- 账号 ----
async function agree(req, env) {
  const u = await needUser(req, env);
  const now = Date.now();
  await env.DB.prepare("UPDATE users SET agreed_at = COALESCE(agreed_at, ?) WHERE id = ?").bind(now, u.id).run();
  return json(meOf({ ...u, agreed_at: u.agreed_at || now }));
}

async function wipeUser(env, u) {
  const rows = (await env.DB.prepare("SELECT id, photos, thumb FROM listings WHERE user_id = ?").bind(u.id).all()).results;
  await deleteRows(env, rows);
  if (u.avatar_key) await removePhotos(env, [u.avatar_key]);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM blocks WHERE user_id = ? OR blocked_id = ?").bind(u.id, u.id),
    env.DB.prepare("DELETE FROM claim_codes WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM wants WHERE seller_id = ? OR buyer_id = ?").bind(u.id, u.id),
    env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id),
    // 删过号的人，之后群里的帖子也不再搬
    ...(u.sender_hash ? [env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind("sender:" + u.sender_hash, Date.now())] : []),
    env.DB.prepare("DELETE FROM reports WHERE reporter_id = ? OR reported_user = ? OR reporter_id IN (?, ?)").bind(u.id, u.id, "name:" + u.id, "avatar:" + u.id),
    env.DB.prepare("DELETE FROM daily_counts WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(u.id)
  ]);
}

// 14. 被封的账号也能自己删号：这里不挡 banned
async function deleteAccount(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  const u = m && await env.DB.prepare("SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?").bind(await sha256(m[1])).first();
  if (!u) throw new Fail(401, "login_required");
  const revoked = await revokeToken(env, u.apple_refresh).catch(e => { console.error("apple revokeToken", e?.message || e); return false; });
  if (!revoked) console.error("apple revokeToken failed", u.apple_refresh ? "had refresh token" : "no refresh token");
  await wipeUser(env, u);
  return json({ ok: true });
}

async function logout(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  if (m) {
    const u = await currentUser(req, env);
    let token = "";
    try { token = String((await req.json()).deviceToken || ""); } catch (e) { token = ""; }
    if (u && token) await env.DB.prepare("DELETE FROM devices WHERE user_id = ? AND token = ?").bind(u.id, token).run();
    await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(m[1])).run();
  }
  return json({ ok: true });
}

// ---- 管理 ----
// 举报的种类看 reporter_id 前缀：want: 想要留言，name: 昵称，avatar: 头像，其余是帖子（anon: 是没登录的人举报帖子）
const reportType = reporter => reporter.startsWith("want:") ? "want" : reporter.startsWith("name:") ? "name" : reporter.startsWith("avatar:") ? "avatar" : "listing";

async function adminReports(req, env, url) {
  await needStaff(req, env);
  const rows = (await env.DB.prepare(`SELECT r.id, r.reason, r.note, r.created_at AS at, r.reporter_id AS reporter, r.reported_user, r.listing_id AS rlid,
      (SELECT nickname FROM users u WHERE u.id = COALESCE(r.reported_user, l.user_id)) AS target_nick,
      (SELECT avatar_key FROM users u WHERE u.id = COALESCE(r.reported_user, l.user_id)) AS target_avatar,
      (SELECT nickname FROM users u WHERE u.id = l.user_id) AS seller_nick, l.id AS lid, l.user_id, l.kind, l.title, l.price, l.cat, l.cond, l.from_date, l.to_date, l.lease_end, l.utilities, l.private_bath, l.delivery, l.delivery_fee, l.pickup_before, l.pickup_after, l.long_term, l.furnished, l.room_type, l.unit_type, l.furniture, l.internet, l.deposit, l.app_fee, l.parking, l.pets, l.roommates, l.score, l.source_type, l.source_group, l.source_poster, l.source_posted_at, l.bumped_at, l.place, l.descr, l.contact, l.photos, l.status, l.created_at
    FROM reports r LEFT JOIN listings l ON l.id = r.listing_id WHERE r.status = 'open' ORDER BY r.created_at DESC LIMIT 200`).all()).results;
  const photo = key => key ? url.origin + "/p/" + key : null;
  const merged = [], seen = new Map();
  for (const r of rows) {
    if (reportType(r.reporter) !== "listing") { merged.push({ ...r, count: 1, reasons: [r.reason] }); continue; }
    const hit = seen.get(r.rlid);
    if (hit) { hit.count++; if (!hit.reasons.includes(r.reason)) hit.reasons.push(r.reason); continue; }
    const one = { ...r, count: 1, reasons: [r.reason] };
    seen.set(r.rlid, one);
    merged.push(one);
  }
  return json({ items: merged.map(r => {
    const type = reportType(r.reporter);
    // 被举报的内容：留言原文、举报时的昵称、举报时的头像；帖子就是帖子本身（看 listing）
    const content = type === "want" ? r.note.replace(/^想要留言：/, "") : type === "name" ? r.note : type === "avatar" ? photo(r.note.replace(/^\/p\//, "")) : null;
    const current = type === "name" ? (r.target_nick || null) : type === "avatar" ? photo(r.target_avatar) : null;
    return {
      id: r.id, type, reason: r.reason, reasons: r.reasons, count: r.count, note: r.note, at: r.at, reporter: r.reporter,
      anonymous: r.reporter.startsWith("anon:"),
      reportedUser: r.reported_user || r.user_id || null,
      content, current, listingId: r.rlid,
      listing: r.lid ? view({ ...r, id: r.lid }, url.origin, { id: "admin" }) : null
    };
  }) });
}
async function adminCloseReport(req, env, id) {
  await needStaff(req, env);
  await env.DB.prepare("UPDATE reports SET status = 'done', done_at = unixepoch() * 1000 WHERE id = ?").bind(id).run();
  return json({ ok: true });
}
// 忽略举报后恢复上架
async function adminRestore(req, env, id) {
  await needStaff(req, env);
  await env.DB.batch([
    env.DB.prepare("UPDATE reports SET status = 'done', done_at = unixepoch() * 1000 WHERE listing_id = ? AND status != 'done'").bind(id),
    env.DB.prepare("UPDATE listings SET status = 'on' WHERE id = ? AND status = 'hidden'").bind(id)
  ]);
  return json({ ok: true });
}
// 管理员下架帖子：和在 App 里删别人的帖子一样，彻底删掉（照片、想要留言、举报一起删）。
// 群帖再留编号，之后不再导入。
async function adminRemove(req, env, id) {
  await needStaff(req, env);
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  if (row.source_type === "group") {
    await env.DB.batch([
      env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind(row.source_id, Date.now()),
      env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind("key:" + row.merge_key, Date.now())
    ]);
  }
  await deleteRows(env, [row]);
  return json({ ok: true });
}
async function adminBan(req, env, id) {
  const admin = await needStaff(req, env);
  if (id === admin.id) throw new Fail(400, "self");
  const target = await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(id).first();
  if (!target) throw new Fail(404, "not_found");
  if (target.is_admin) throw new Fail(400, "is_admin");
  const rows = (await env.DB.prepare("SELECT id, photos, thumb FROM listings WHERE user_id = ?").bind(id).all()).results;
  await deleteRows(env, rows);
  const banned = await env.DB.prepare("SELECT avatar_key FROM users WHERE id = ?").bind(id).first();
  if (banned?.avatar_key) await removePhotos(env, [banned.avatar_key]);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET banned = 1, avatar_key = NULL WHERE id = ?").bind(id),
    env.DB.prepare("DELETE FROM wants WHERE buyer_id = ? OR seller_id = ?").bind(id, id),
    env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(id),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(id)
  ]);
  return json({ ok: true });
}

async function countView(env, id) {
  await bump(env, "*", "view");
  return json({ ok: true });
}

// 只有总数，不记谁看的
async function adminStats(req, env) {
  await needAdmin(req, env);
  const since = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const rows = (await env.DB.prepare("SELECT what, SUM(n) AS n FROM daily_counts WHERE user_id = '*' AND day >= ? GROUP BY what").bind(since).all()).results;
  const of = w => (rows.find(r => r.what === w) || { n: 0 }).n;
  return json({ posts: of("post"), views: of("view"), sold: of("sold"), copies: of("copy"), groupClicks: of("group_click") });
}

// ---- 匿名使用记录（11-01）：只有本机随机的安装编号，不跟账号挂。原始事件留 90 天，之后只留每日汇总 ----
const EVENT_KEEP = 90 * 86400000, EVENT_BATCH = 50, EVENT_BODY_MAX = 32000, EVENTS_PER_DEVICE = 500, EVENTS_PER_SITE = 100000;
const EVENT_STEPS = ["photos", "name", "price", "details", "batch_choose", "batch_recognize", "batch_confirm"];
const EVENT_METHODS = ["copy_wechat", "want", "group"];

// 搜索词和 AI 名字：微信号、电话、邮箱这类格式的去掉，封顶 40
function scrubText(v) {
  if (typeof v !== "string") return "";
  return v
    .replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, " ")
    .replace(/(?:微信号?|vx|wx|wechat)[:：\s]*[a-z0-9_-]+/gi, " ")
    .replace(/\+?\d[\d\s()-]{5,}\d/g, " ")
    .replace(/\b[a-z][-_a-z0-9]{5,19}\b/gi, w => /[-_0-9]/.test(w) ? " " : w)
    .replace(/\s+/g, " ").trim().slice(0, 40);
}

const eventInt = (v, lo, hi) => Number.isInteger(v) ? Math.min(hi, Math.max(lo, v)) : null;
const eventBool = v => v === true ? 1 : v === false ? 0 : null;
const eventOneOf = (v, list) => list.includes(v) ? v : null;
const eventId = v => typeof v === "string" && /^[0-9a-f]{8,64}$/.test(v) ? v : null;
const eventCat = v => typeof v === "string" && /^[a-z]{1,16}$/.test(v) ? v : null;
const eventKind = v => eventOneOf(v, ["goods", "rent"]);

// 字段白名单：每种事件只留该有的，别的都丢。名字不认识的整条丢
function cleanEvent(e) {
  if (!e || typeof e !== "object") return null;
  const r = { name: e.name };
  switch (e.name) {
    case "app_open": case "post_start":
      if (e.name === "post_start") r.kind = eventKind(e.kind);
      return r;
    case "detail_view":
      r.listing = eventId(e.listing);
      if (!r.listing) return null;
      return { ...r, kind: eventKind(e.kind), cat: eventCat(e.cat), tier: eventInt(e.tier, 1, 4), seconds: eventInt(e.seconds, 0, 600) ?? 0 };
    case "search":
      r.q = scrubText(e.q).toLowerCase();
      if (!r.q) return null;
      return { ...r, kind: eventKind(e.kind), results: eventInt(e.results, 0, 100000) ?? 0 };
    case "contact":
      r.listing = eventId(e.listing);
      r.method = eventOneOf(e.method, EVENT_METHODS);
      if (!r.listing || !r.method) return null;
      return { ...r, kind: eventKind(e.kind), cat: eventCat(e.cat), tier: eventInt(e.tier, 1, 4) };
    case "post_abandon":
      r.step = eventOneOf(e.step, EVENT_STEPS);
      if (!r.step) return null;
      return { ...r, kind: eventKind(e.kind) };
    case "post_done":
      r.mode = eventOneOf(e.mode, ["single", "batch"]);
      if (!r.mode) return null;
      return { ...r, kind: eventKind(e.kind), count: eventInt(e.count, 1, 30) ?? 1 };
    case "ai_result":
      return { ...r, ai_name: scrubText(e.aiName) || null, name_edited: eventBool(e.nameEdited), ai_price: eventInt(e.aiPrice, 0, 100000), price_edited: eventBool(e.priceEdited), price_diff: eventInt(e.priceDiff, -100000, 100000) };
    default:
      return null;
  }
}

async function postEvents(req, env) {
  const raw = await req.text();
  if (raw.length > EVENT_BODY_MAX) throw new Fail(413, "too_big");
  let b;
  try { b = JSON.parse(raw); } catch (e) { throw new Fail(400, "bad_json"); }
  const install = b && b.install;
  if (typeof install !== "string" || !/^[0-9a-f-]{32,36}$/.test(install)) throw new Fail(400, "bad_install");
  if (!Array.isArray(b.events) || b.events.length > EVENT_BATCH) throw new Fail(400, "bad_count");
  const rows = b.events.map(cleanEvent).filter(Boolean);
  if (!rows.length) return json({ kept: 0 });
  const used = (await env.DB.prepare("SELECT user_id, n FROM daily_counts WHERE day = ? AND what = 'event' AND user_id IN (?, '*')").bind(today(), install).all()).results;
  const usedBy = id => (used.find(r => r.user_id === id) || { n: 0 }).n;
  if (usedBy(install) + rows.length > EVENTS_PER_DEVICE) throw new Fail(429, "daily_limit");
  // 全站封顶：有人换编号乱写时，到顶就不收
  if (usedBy("*") + rows.length > EVENTS_PER_SITE) return json({ kept: 0 });
  const now = Date.now();
  const insert = env.DB.prepare(`INSERT INTO events (install, name, at, listing, kind, cat, tier, seconds, q, results, method, step, mode, count, ai_name, name_edited, ai_price, price_edited, price_diff)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  const v = x => x === undefined ? null : x;
  await env.DB.batch(rows.map(r => insert.bind(install, r.name, now, v(r.listing), v(r.kind), v(r.cat), v(r.tier), v(r.seconds), v(r.q), v(r.results), v(r.method), v(r.step), v(r.mode), v(r.count), v(r.ai_name), v(r.name_edited), v(r.ai_price), v(r.price_edited), v(r.price_diff))));
  await bumpBy(env, install, "event", rows.length);
  await bumpBy(env, "*", "event", rows.length);
  return json({ kept: rows.length });
}

function median(list) {
  const s = list.filter(x => x !== null && x !== undefined).sort((a, b) => a - b);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
const ratio = (a, b) => b ? Math.round(a / b * 1000) / 1000 : null;
const hoursOf = ms => ms === null ? null : Math.round(ms / 360000) / 10;

// ADMIN_TOKEN 能读。days 默认 30，最多 90
async function eventStats(req, env, url) {
  await needStaff(req, env);
  const days = Math.min(90, Math.max(1, Number(url.searchParams.get("days")) || 30));
  const since = Date.now() - days * 86400000;
  const all = async (sql, ...args) => (await env.DB.prepare(sql).bind(...args).all()).results;

  // 1、7 联系率：看过详情的设备里，有多少联系了。按类别、按蜜蜂分档
  const rates = async dim => {
    const views = await all(`SELECT ${dim} AS k, COUNT(DISTINCT install) AS n FROM events WHERE name = 'detail_view' AND at >= ? GROUP BY k`, since);
    const contacts = await all(`SELECT ${dim} AS k, COUNT(DISTINCT install) AS n FROM events WHERE name = 'contact' AND at >= ? GROUP BY k`, since);
    return views.map(r => {
      const c = (contacts.find(x => x.k === r.k) || { n: 0 }).n;
      return { key: r.k, viewers: r.n, contacted: c, rate: ratio(c, r.n) };
    });
  };
  const viewers = (await env.DB.prepare("SELECT COUNT(DISTINCT install) AS n FROM events WHERE name = 'detail_view' AND at >= ?").bind(since).first()).n;
  const contacted = (await env.DB.prepare("SELECT COUNT(DISTINCT install) AS n FROM events WHERE name = 'contact' AND at >= ? AND install IN (SELECT install FROM events WHERE name = 'detail_view' AND at >= ?)").bind(since, since).first()).n;

  // 2 搜索词
  const topSearches = await all("SELECT q, COUNT(*) AS n FROM events WHERE name = 'search' AND at >= ? GROUP BY q ORDER BY n DESC, q LIMIT 30", since);
  const zeroSearches = await all("SELECT q, COUNT(*) AS n FROM events WHERE name = 'search' AND results = 0 AND at >= ? GROUP BY q ORDER BY n DESC, q LIMIT 30", since);

  // 3 发布到首次联系、发布到卖出。联系 = 想要留言或联系事件里最早的。内部示例号不算
  const listings = await all(`SELECT l.created_at AS c, l.sold_at AS sold,
      (SELECT MIN(w.created_at) FROM wants w WHERE w.listing_id = l.id) AS want,
      (SELECT MIN(e.at) FROM events e WHERE e.listing = l.id AND e.name = 'contact') AS ev
    FROM listings l WHERE l.created_at >= ? AND l.user_id NOT LIKE 'ffffffff%'`, since);
  const firstContact = listings.map(r => {
    const t = [r.want, r.ev].filter(Boolean);
    return t.length ? Math.max(0, Math.min(...t) - r.c) : null;
  });
  const toSold = listings.map(r => r.sold ? Math.max(0, r.sold - r.c) : null);

  // 4 回访：首次打开当天算第 1 天，第 2 天是次日，第 7 天是六天后。按美东算日子；日子还没到的设备不算进分母
  const dayOf = "((at - 18000000) / 86400000)";
  const firsts = await all(`SELECT install, MIN(${dayOf}) AS d FROM events WHERE name = 'app_open' GROUP BY install`);
  const visits = await all(`SELECT DISTINCT install, ${dayOf} AS d FROM events WHERE name = 'app_open'`);
  const todayNo = Math.floor((Date.now() - 18000000) / 86400000);
  const seen = new Set(visits.map(r => r.install + "#" + r.d));
  const retained = gap => {
    const due = firsts.filter(r => r.d + gap <= todayNo);
    const back = due.filter(r => seen.has(r.install + "#" + (r.d + gap))).length;
    return { devices: due.length, back, rate: ratio(back, due.length) };
  };

  // 5 发布漏斗
  const funnelRows = await all("SELECT name, COUNT(*) AS n, COALESCE(SUM(count), 0) AS items FROM events WHERE name IN ('post_start', 'post_abandon', 'post_done') AND at >= ? GROUP BY name", since);
  const funnelOf = n => funnelRows.find(r => r.name === n) || { n: 0, items: 0 };
  const abandonSteps = await all("SELECT step, COUNT(*) AS n FROM events WHERE name = 'post_abandon' AND at >= ? GROUP BY step ORDER BY n DESC", since);

  // 6 AI 改了多少
  const ai = await all("SELECT name_edited, price_edited, price_diff FROM events WHERE name = 'ai_result' AND at >= ?", since);
  const named = ai.filter(r => r.name_edited !== null), priced = ai.filter(r => r.price_edited !== null);

  // 8 各大类停留，用中位数
  const stays = await all("SELECT COALESCE(cat, kind) AS k, seconds FROM events WHERE name = 'detail_view' AND at >= ?", since);
  const stayBy = {};
  for (const r of stays) (stayBy[r.k ?? ""] ||= []).push(r.seconds);

  // 复制微信算到每条帖子
  const contactsByListing = await all("SELECT listing, method, COUNT(*) AS n FROM events WHERE name = 'contact' AND at >= ? GROUP BY listing, method ORDER BY n DESC LIMIT 50", since);

  // 9 举报
  const reports = await all("SELECT status, created_at, done_at FROM reports WHERE created_at >= ?", since);
  const handled = reports.filter(r => r.done_at);

  return json({
    days,
    contactRate: { viewers, contacted, rate: ratio(contacted, viewers), byCat: await rates("COALESCE(cat, kind)"), byTier: await rates("tier") },
    searches: { top: topSearches, zero: zeroSearches },
    timing: { firstContactHours: hoursOf(median(firstContact)), firstContactSample: firstContact.filter(x => x !== null).length, soldHours: hoursOf(median(toSold)), soldSample: toSold.filter(x => x !== null).length },
    retention: { day2: retained(1), day7: retained(6) },
    funnel: { start: funnelOf("post_start").n, abandon: funnelOf("post_abandon").n, done: funnelOf("post_done").n, items: funnelOf("post_done").items, abandonSteps },
    ai: { total: ai.length, nameEditedRate: ratio(named.filter(r => r.name_edited).length, named.length), priceEditedRate: ratio(priced.filter(r => r.price_edited).length, priced.length), medianPriceDiff: median(ai.map(r => r.price_diff)) },
    staySeconds: Object.entries(stayBy).map(([key, list]) => ({ key, views: list.length, medianSeconds: median(list) })),
    contactsByListing,
    reports: { total: reports.length, done: reports.filter(r => r.status === "done").length, medianHandleHours: hoursOf(median(handled.map(r => Math.max(0, r.done_at - r.created_at)))) }
  });
}

// 每天：过期的原始事件并进汇总再删；设备计数只留一周
async function purgeEvents(env, keep = EVENT_KEEP) {
  const before = Date.now() - keep;
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO event_daily (day, metric, dim, n, devices)
      SELECT strftime('%Y-%m-%d', at / 1000, 'unixepoch'), name, COALESCE(q, method, step, mode, cat, kind, ''), COUNT(*), COUNT(DISTINCT install)
      FROM events WHERE at < ? GROUP BY 1, 2, 3
      ON CONFLICT (day, metric, dim) DO UPDATE SET n = n + excluded.n, devices = devices + excluded.devices`).bind(before),
    env.DB.prepare("DELETE FROM events WHERE at < ?").bind(before),
    env.DB.prepare("DELETE FROM daily_counts WHERE what = 'event' AND user_id != '*' AND day < ?").bind(new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10))
  ]);
}

// ---- “想要”留言：卖家没留微信时，买家留一句话和联系方式。只有卖家看得到 ----
const WANTS_PER_DAY = 20, SITE_WANTS_PER_DAY = 1000;

async function sendWant(req, env, id) {
  const u = await needAgreed(req, env);
  const b = await bodyOf(req);
  const message = clean(b.message, 200), contact = clean(b.contact, 60);
  if (!contact) throw new Fail(400, "need_contact");
  if (BANNED.some(r => r.test(message + " " + contact))) throw new Fail(422, "not_allowed");
  const row = await env.DB.prepare("SELECT id, user_id, title, status, source_type FROM listings WHERE id = ?").bind(id).first();
  if (!row || row.source_type === "group" || !["on", "reserved"].includes(row.status)) throw new Fail(404, "not_found");
  if (row.user_id === u.id) throw new Fail(400, "self");
  const dayAgo = Date.now() - 86400000;
  const again = await env.DB.prepare("SELECT 1 AS x FROM wants WHERE buyer_id = ? AND listing_id = ? AND created_at > ?").bind(u.id, id, dayAgo).first();
  if (again) throw new Fail(429, "want_again");
  if (await bump(env, u.id, "want") > WANTS_PER_DAY) throw new Fail(429, "daily_limit");
  if (await bump(env, "*", "want") > SITE_WANTS_PER_DAY) throw new Fail(429, "site_limit");
  // 被卖家屏蔽的人：看起来发成功了，卖家收不到
  const blocked = await env.DB.prepare("SELECT 1 AS x FROM blocks WHERE user_id = ? AND blocked_id = ?").bind(row.user_id, u.id).first();
  if (!blocked) {
    await env.DB.prepare("INSERT INTO wants (id, listing_id, seller_id, buyer_id, message, contact, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(newId(), id, row.user_id, u.id, message, contact, Date.now()).run();
    try {
      await pushToUser(env, row.user_id, "有人想要", row.title);
    } catch (e) {
      console.error("push failed", e && e.message);
    }
  }
  return json({ ok: true }, 201);
}

async function myWants(req, env, url) {
  const u = await needUser(req, env);
  const rows = (await env.DB.prepare("SELECT w.id, w.message, w.contact, w.created_at, l.id AS listing_id, l.title, l.photos FROM wants w JOIN listings l ON l.id = w.listing_id WHERE w.seller_id = ? ORDER BY w.created_at DESC LIMIT 100").bind(u.id).all()).results;
  return json({
    items: rows.map(r => {
      const first = JSON.parse(r.photos)[0];
      return { id: r.id, listingId: r.listing_id, title: r.title, photo: first ? `${url.origin}/p/${first}` : null, message: r.message, contact: r.contact, createdAt: r.created_at };
    })
  });
}

async function ownWant(req, env, id) {
  const u = await needUser(req, env);
  const w = await env.DB.prepare("SELECT * FROM wants WHERE id = ?").bind(id).first();
  if (!w || w.seller_id !== u.id) throw new Fail(404, "not_found");
  return { u, w };
}

async function deleteWant(req, env, id) {
  const { w } = await ownWant(req, env, id);
  await env.DB.prepare("DELETE FROM wants WHERE id = ?").bind(w.id).run();
  return json({ ok: true });
}

// 举报昵称：不算进条目的自动下架，管理员可以重置昵称
async function reportName(req, env, id) {
  const u = await currentUser(req, env);
  let what = "name";
  try { what = (await req.json()).what === "avatar" ? "avatar" : "name"; } catch (e) { what = "name"; }
  const row = await env.DB.prepare(`SELECT l.user_id, l.source_type, ${SELLER_COLUMNS} FROM listings l WHERE l.id = ?`).bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  if (row.source_type === "group") throw new Fail(400, "bad_reason");
  await env.DB.prepare("INSERT OR IGNORE INTO reports (id, listing_id, reporter_id, reason, note, reported_user, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(newId(), id, what + ":" + (u ? u.id : newId()), what === "avatar" ? "头像不当" : "昵称不当", what === "avatar" ? (row.seller_avatar || "") : (row.seller_nick || ""), row.user_id, Date.now()).run();
  return json({ ok: true });
}

async function adminResetName(req, env, id) {
  await needStaff(req, env);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET nickname = NULL WHERE id = ?").bind(id),
    env.DB.prepare("UPDATE reports SET status = 'done', done_at = unixepoch() * 1000 WHERE reported_user = ? AND reason = '昵称不当' AND status != 'done'").bind(id)
  ]);
  return json({ ok: true });
}

async function uploadAvatar(req, env) {
  const u = await needUser(req, env);
  const buf = await req.arrayBuffer();
  if (buf.byteLength > MAX_AVATAR_BYTES) throw new Fail(413, "photo_too_big");
  const head = new Uint8Array(buf.slice(0, 3));
  if (!(head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff)) throw new Fail(415, "not_jpeg");
  if (await bump(env, u.id, "avatar") > 10) throw new Fail(429, "daily_limit");
  const key = `${u.id}/${newId()}.jpg`;
  await env.PHOTOS.put(key, buf, { httpMetadata: { contentType: "image/jpeg", cacheControl: "public, max-age=31536000, immutable" } });
  if (u.avatar_key) await removePhotos(env, [u.avatar_key]);
  await env.DB.prepare("UPDATE users SET avatar_key = ? WHERE id = ?").bind(key, u.id).run();
  return json(meOf({ ...u, avatar_key: key }));
}

async function removeAvatar(req, env) {
  const u = await needUser(req, env);
  if (u.avatar_key) await removePhotos(env, [u.avatar_key]);
  await env.DB.prepare("UPDATE users SET avatar_key = NULL WHERE id = ?").bind(u.id).run();
  return json(meOf({ ...u, avatar_key: null }));
}

// 头像被举报：撤掉换回默认
async function adminRemoveAvatar(req, env, id) {
  await needStaff(req, env);
  const row = await env.DB.prepare("SELECT avatar_key FROM users WHERE id = ?").bind(id).first();
  if (row?.avatar_key) await removePhotos(env, [row.avatar_key]);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET avatar_key = NULL WHERE id = ?").bind(id),
    env.DB.prepare("UPDATE reports SET status = 'done', done_at = unixepoch() * 1000 WHERE reported_user = ? AND reason = '头像不当' AND status != 'done'").bind(id)
  ]);
  return json({ ok: true });
}

async function updateProfile(req, env) {
  const u = await needUser(req, env);
  const b = await bodyOf(req);
  let nickname = u.nickname;
  if (typeof b.nickname === "string") {
    nickname = clean(b.nickname, 12) || null;
    if (nickname && (BANNED.some(r => r.test(nickname)) || NAME_NOT_ALLOWED.test(nickname))) throw new Fail(422, "bad_name");
  }
  let color = u.avatar_color;
  if (b.color !== undefined) {
    if (!Number.isInteger(b.color) || b.color < 0 || b.color > 5) throw new Fail(400, "bad_color");
    color = b.color;
  }
  await env.DB.prepare("UPDATE users SET nickname = ?, avatar_color = ? WHERE id = ?").bind(nickname, color, u.id).run();
  return json(meOf({ ...u, nickname, avatar_color: color }));
}

async function reportWant(req, env, id) {
  const { w } = await ownWant(req, env, id);
  const { reason } = await bodyOf(req);
  if (!REASONS.includes(reason)) throw new Fail(400, "bad_reason");
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO reports (id, listing_id, reporter_id, reason, note, reported_user, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(newId(), w.listing_id, "want:" + w.id, reason, "想要留言：" + w.message, w.buyer_id, Date.now()),
    env.DB.prepare("DELETE FROM wants WHERE id = ?").bind(w.id)
  ]);
  return json({ ok: true });
}

async function blockWant(req, env, id) {
  const { u, w } = await ownWant(req, env, id);
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO blocks (user_id, blocked_id, created_at) VALUES (?, ?, ?)").bind(u.id, w.buyer_id, Date.now()),
    env.DB.prepare("DELETE FROM wants WHERE seller_id = ? AND buyer_id = ?").bind(u.id, w.buyer_id)
  ]);
  return json({ ok: true });
}

async function saveDevice(req, env) {
  const u = await needUser(req, env);
  const token = String((await bodyOf(req)).token || "");
  if (!/^[0-9a-f]{32,200}$/.test(token)) throw new Fail(400, "bad_token");
  await env.DB.prepare("INSERT OR REPLACE INTO devices (token, user_id, updated_at) VALUES (?, ?, ?)").bind(token, u.id, Date.now()).run();
  return json({ ok: true });
}

// ---- 发布时 AI 看照片。Worker 变量 AI_DESCRIBE 关掉，App 自动变手填 ----
// 每人每月 50 条，按自然月；一张照片算一条（11-01 用户定）。用完照样能发，只是 AI 不帮忙填
const AI_PER_MONTH = 50;
async function userMonthCount(env, userId, what) {
  const r = await env.DB.prepare("SELECT COALESCE(SUM(n), 0) AS n FROM daily_counts WHERE user_id = ? AND what = ? AND day LIKE ?").bind(userId, what, today().slice(0, 7) + "%").first();
  return r.n;
}
const aiLeftOf = async (env, userId) => Math.max(0, AI_PER_MONTH - await userMonthCount(env, userId, "ai_describe"));
let priceRefs = null;  // 参考表不常变，存在实例里
const aiEnabled = env => env.AI_DESCRIBE === "on" && (!!env.ANTHROPIC_API_KEY || env.AI_MOCK === "1");

async function bumpBy(env, userId, what, by) {
  await env.DB.prepare("INSERT INTO daily_counts (day, user_id, what, n) VALUES (?, ?, ?, ?) ON CONFLICT (day, user_id, what) DO UPDATE SET n = n + excluded.n").bind(today(), userId, what, by).run();
}

async function monthSum(env, what) {
  const r = await env.DB.prepare("SELECT COALESCE(SUM(n), 0) AS n FROM daily_counts WHERE user_id = '*' AND what = ? AND day LIKE ?").bind(what, today().slice(0, 7) + "%").first();
  return r.n;
}

async function dailyCount(env, userId, what) {
  const r = await env.DB.prepare("SELECT n FROM daily_counts WHERE day = ? AND user_id = ? AND what = ?").bind(today(), userId, what).first();
  return r ? r.n : 0;
}

// 一次传多张：AI 分成一件一件。按张数算进每人每天的 AI 次数；超了返回 ai_limit，App 退回“每张一件”
async function aiGroup(req, env, url) {
  if (!aiEnabled(env)) throw new Fail(503, "ai_off");
  const u = await needAgreed(req, env);
  if (!u.ai_consent_at) {
    if (url.searchParams.get("consent") !== "1") throw new Fail(400, "need_ai_consent");
    await env.DB.prepare("UPDATE users SET ai_consent_at = ? WHERE id = ?").bind(Date.now(), u.id).run();
  }
  const b = await bodyOf(req);
  const list = Array.isArray(b.photos) ? b.photos : [];
  if (list.length < 2 || list.length > MAX_GROUP_PHOTOS) throw new Fail(400, "bad_count");
  const images = list.map(x => {
    let bytes;
    try { bytes = Uint8Array.from(atob(String(x)), c => c.charCodeAt(0)); } catch (e) { throw new Fail(400, "bad_photo"); }
    if (bytes.length > MAX_GROUP_PHOTO_BYTES) throw new Fail(413, "photo_too_big");
    if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw new Fail(415, "not_jpeg");
    return bytes;
  });
  if (await userMonthCount(env, u.id, "ai_describe") + images.length > AI_PER_MONTH) throw new Fail(429, "ai_limit");
  if (await monthSum(env, "ai_microusd") >= Number(env.AI_MONTHLY_USD || 40) * 1e6) throw new Fail(503, "ai_budget");
  let r;
  try {
    if (!priceRefs) priceRefs = (await env.DB.prepare("SELECT item, cat, n, median, low, high FROM price_refs ORDER BY n DESC, item").all()).results;
    const recent = (await env.DB.prepare("SELECT title, price FROM listings WHERE kind = 'goods' AND title NOT LIKE '示例%' ORDER BY bumped_at DESC LIMIT 40").all()).results;
    r = await groupPhotos(env, images, CATS, CONDS, priceRefs, recent);
  } catch (e) {
    console.error("ai group failed", e && e.message);
    throw new Fail(503, "ai_failed");
  }
  await bumpBy(env, "*", "ai_microusd", r.microUsd);
  await bumpBy(env, u.id, "ai_describe", images.length);
  await bump(env, "*", "ai_describe");
  // 收拾 AI 的结果：编号要在范围内、每张只用一次；漏掉的每张自成一件，名字空着让卖家填
  const used = new Set(), items = [];
  for (const it of r.items || []) {
    const photos = [...new Set(it.photos || [])].filter(i => Number.isInteger(i) && i >= 0 && i < images.length && !used.has(i));
    if (!photos.length) continue;
    photos.forEach(i => used.add(i));
    const price = Number.isInteger(it.price) && it.price >= 0 && it.price <= 100000 ? it.price : null;
    items.push({ photos: photos.sort((a, b2) => a - b2), title: clean(it.name, 40), price, cat: CATS.includes(it.cat) ? it.cat : null, cond: CONDS.includes(it.cond) ? it.cond : null });
  }
  for (let i = 0; i < images.length; i++) {
    if (!used.has(i)) items.push({ photos: [i], title: "", price: null, cat: null, cond: null });
  }
  items.sort((a, b2) => a.photos[0] - b2.photos[0]);
  return json({ items, aiLeft: await aiLeftOf(env, u.id) });
}

// 一次发好几件：先逐件检查，全过了才一起写进去。任何一件不行，返回是第几件
async function createBatch(req, env, url) {
  const u = await needAgreed(req, env);
  const body = await bodyOf(req);
  const list = Array.isArray(body.items) ? body.items : [];
  if (!list.length || list.length > MAX_GROUP_PHOTOS) throw new Fail(400, "bad_count");
  const checked = [], seen = new Set();
  for (let i = 0; i < list.length; i++) {
    try {
      const v = checkListing(list[i], u.id);
      if (v.kind !== "goods") throw new Fail(400, "bad_kind");
      for (const k of JSON.parse(v.photos)) {
        if (seen.has(k)) throw new Fail(400, "bad_photo");
        seen.add(k);
      }
      checked.push(v);
    } catch (e) {
      if (e instanceof Fail) return json({ error: e.code, index: i }, e.status);
      throw e;
    }
  }
  if (!u.ai_consent_at) {
    if (body.aiConsent !== true) throw new Fail(400, "need_ai_consent");
    await env.DB.prepare("UPDATE users SET ai_consent_at = ? WHERE id = ?").bind(Date.now(), u.id).run();
  }
  const live = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND status = 'on'").bind(u.id).first();
  if (live.n + checked.length > MAX_LIVE_LISTINGS) throw new Fail(429, "too_many_listings");
  if (await dailyCount(env, u.id, "post") + checked.length > LIMITS.post) throw new Fail(429, "daily_limit");
  const now = Date.now(), ids = [];
  const stmts = checked.map((v, i) => {
    const id = newId();
    ids.push(id);
    // 同一批里按顺序排，第一件在最前
    const t = now - i;
    return env.DB.prepare("INSERT INTO listings (id, user_id, kind, title, price, cat, cond, from_date, to_date, lease_end, from_prec, to_prec, utilities, private_bath, delivery, delivery_fee, pickup_before, pickup_after, long_term, furnished, room_type, unit_type, furniture, internet, deposit, app_fee, parking, pets, roommates, place, descr, contact, avail_time, photos, status, created_at, updated_at, bumped_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'on', ?, ?, ?)")
      .bind(id, u.id, v.kind, v.title, v.price, v.cat, v.cond, v.from_date, v.to_date, v.lease_end, v.from_prec, v.to_prec, v.utilities, v.private_bath, v.delivery, v.delivery_fee, v.pickup_before, v.pickup_after, v.long_term, v.furnished, v.room_type, v.unit_type, v.furniture, v.internet, v.deposit, v.app_fee, v.parking, v.pets, v.roommates, v.place, v.descr, v.contact, v.avail_time, v.photos, t, t, t);
  });
  await env.DB.batch(stmts);
  await bumpBy(env, u.id, "post", checked.length);
  await bumpBy(env, "*", "post", checked.length);
  const rows = (await env.DB.prepare(`SELECT * FROM listings WHERE id IN (${ids.map(() => "?").join(",")})`).bind(...ids).all()).results;
  const byId = new Map(rows.map(r => [r.id, r]));
  await later(req, (async () => { for (const id of ids) await tagListing(env, id).catch(e => console.error("tag", id, e && e.message)); })());
  return json({ items: ids.map(id => view(byId.get(id), url.origin, u)) }, 201);
}

async function aiDescribe(req, env, url) {
  if (!aiEnabled(env)) throw new Fail(503, "ai_off");
  const u = await needAgreed(req, env);
  // 发给 AI 之前要有同意（5.1.2(i)）
  if (!u.ai_consent_at) {
    if (url.searchParams.get("consent") !== "1") throw new Fail(400, "need_ai_consent");
    await env.DB.prepare("UPDATE users SET ai_consent_at = ? WHERE id = ?").bind(Date.now(), u.id).run();
  }
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > 500_000) throw new Fail(413, "photo_too_big");
  if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw new Fail(415, "not_jpeg");
  if (await userMonthCount(env, u.id, "ai_describe") >= AI_PER_MONTH) throw new Fail(429, "ai_limit");
  await bump(env, u.id, "ai_describe");
  if (await monthSum(env, "ai_microusd") >= Number(env.AI_MONTHLY_USD || 40) * 1e6) throw new Fail(503, "ai_budget");
  let r;
  try {
    if (!priceRefs) priceRefs = (await env.DB.prepare("SELECT item, cat, n, median, low, high FROM price_refs ORDER BY n DESC, item").all()).results;
    // 站内最近的同类价，示例帖不算
    const recent = (await env.DB.prepare("SELECT title, price FROM listings WHERE kind = 'goods' AND title NOT LIKE '示例%' ORDER BY bumped_at DESC LIMIT 40").all()).results;
    r = await describePhoto(env, bytes, CATS, CONDS, priceRefs, recent);
  } catch (e) {
    console.error("ai failed", e && e.message);
    throw new Fail(503, "ai_failed");
  }
  await bumpBy(env, "*", "ai_microusd", r.microUsd);
  await bump(env, "*", "ai_describe");
  const price = Number.isInteger(r.price) && r.price >= 0 && r.price <= 100000 ? r.price : null;
  return json({ name: clean(r.name, 40), cat: r.cat, cond: r.cond, price, aiLeft: await aiLeftOf(env, u.id) });
}

async function aiCost(req, env) {
  needOperator(req, env);
  const calls = await monthSum(env, "ai_describe"), micro = await monthSum(env, "ai_microusd");
  return json({ month: today().slice(0, 7), calls, usd: micro / 1e6, perCallUsd: calls ? micro / 1e6 / calls : null, budgetUsd: Number(env.AI_MONTHLY_USD || 40) });
}

// ---- 后台接口：导入、打分。用 ADMIN_TOKEN，不走用户登录 ----
function needOperator(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  if (!env.ADMIN_TOKEN || !m || m[1] !== env.ADMIN_TOKEN) throw new Fail(403, "forbidden");
}

function decodeJpeg(b64) {
  let bytes;
  try { bytes = Uint8Array.from(atob(String(b64)), c => c.charCodeAt(0)); } catch (e) { throw new Fail(400, "bad_photo"); }
  if (bytes.length > MAX_PHOTO_BYTES) throw new Fail(413, "photo_too_big");
  if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw new Fail(415, "not_jpeg");
  return bytes;
}

// 发送者的带密钥哈希：明文微信 ID 只在这一步经过，不落库、不打日志
async function senderHashOf(env, senderId) {
  if (!env.SENDER_HASH_KEY) throw new Fail(500, "no_hash_key");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.SENDER_HASH_KEY), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(String(senderId)));
  return [...new Uint8Array(sig)].map(x => x.toString(16).padStart(2, "0")).join("");
}

// 同一人同一物品：发送者（没有就用昵称）+ 去掉空格标点的名字
const mergeKeyOf = (who, title) => who.toLowerCase() + "|" + title.toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, "");

// 群里搬来的：不存微信号、电话、门牌。照片要导入方先按内容筛过（人脸、二维码、微信截图、门牌），用 photosChecked 表明。
// 一条多件：body 里放 items，公共字段放外面，每件可覆盖。
async function importOne(env, b) {
  const sourceId = clean(b.sourceId, 80);
  if (!sourceId) throw new Fail(400, "need_source_id");
  const kind = b.kind;
  if (kind !== "goods" && kind !== "rent") throw new Fail(400, "bad_kind");
  const title = clean(b.title, 40), place = clean(b.place, 40), descr = clean(b.desc, 500);
  const group = clean(b.group, 40), poster = clean(b.poster, 40);
  const price = Number(b.price), postedAt = Number(b.postedAt), now = Date.now();
  if (!title || !group || !poster) throw new Fail(400, "need_fields");
  if (!Number.isInteger(price) || price < 0 || price > 1_000_000) throw new Fail(400, "bad_price");
  if (!Number.isFinite(postedAt) || postedAt <= 0 || postedAt > now + 3600 * 1000) throw new Fail(400, "bad_posted_at");
  if (b.backfill === true ? postedAt < GROUP_BACKFILL_SINCE : now - postedAt > GROUP_MAX_AGE) throw new Fail(422, "too_old");
  const text = [title, place, descr].join(" ");
  if (BANNED.some(r => r.test(text))) throw new Fail(422, "not_allowed");
  if (CONTACT_PATTERNS.some(r => r.test(text))) throw new Fail(422, "has_contact");
  if (kind === "rent" && ADDRESS_PATTERN.test(text)) throw new Fail(422, "has_address");
  if (kind === "goods" && !CATS.includes(b.cat)) throw new Fail(400, "bad_cat");

  const senderHash = b.senderId ? await senderHashOf(env, b.senderId) : null;
  const mergeKey = mergeKeyOf(senderHash || poster, title);
  const dead = await env.DB.prepare("SELECT 1 AS x FROM import_tombstones WHERE source_id IN (?, ?, ?)").bind(sourceId, "key:" + mergeKey, "sender:" + senderHash).first();
  if (dead) return { status: 200, data: { skipped: "taken_down" } };
  const dup = await env.DB.prepare("SELECT id FROM listings WHERE source_id = ?").bind(sourceId).first();
  if (dup) return { status: 200, data: { id: dup.id, duplicate: true } };
  const same = await env.DB.prepare("SELECT * FROM listings WHERE merge_key = ? AND source_type IN ('group', 'claimed')").bind(mergeKey).first();
  // 已认领的条目归本人管，群里再发也不改
  if (same && (same.source_type === "claimed" || postedAt <= same.source_posted_at)) return { status: 200, data: { id: same.id, merged: true, stale: true } };
  // 这个人已经认领过：新帖直接进他账号
  const owner = senderHash ? await env.DB.prepare("SELECT id, contact, banned FROM users WHERE sender_hash = ?").bind(senderHash).first() : null;
  if (owner && owner.banned) return { status: 200, data: { skipped: "banned" } };

  const shots = Array.isArray(b.photos) ? b.photos : [];
  if (shots.length > (kind === "rent" ? MAX_RENT_PHOTOS : MAX_PHOTOS)) throw new Fail(400, "too_many_photos");
  if (shots.length && b.photosChecked !== true) throw new Fail(400, "photos_not_checked");
  const decoded = shots.map(decodeJpeg);
  const keys = [];
  for (const bytes of decoded) {
    const key = `${GROUP_UID}/${newId()}.jpg`;
    await env.PHOTOS.put(key, bytes, { httpMetadata: { contentType: "image/jpeg", cacheControl: "public, max-age=31536000, immutable" } });
    keys.push(key);
  }

  // 同一人又发了同一件：留最新的价和时间；新帖没带照片就用旧照片
  if (same) {
    const photos = keys.length ? keys : JSON.parse(same.photos);
    await env.DB.prepare("UPDATE listings SET price=?, place=?, descr=?, source_group=?, source_id=?, source_posted_at=?, bumped_at=?, photos=?, updated_at=? WHERE id=?")
      .bind(price, place || same.place, descr || same.descr, group, sourceId, postedAt, postedAt, JSON.stringify(photos), now, same.id).run();
    if (keys.length) await removePhotos(env, JSON.parse(same.photos));
    if (price !== same.price) await clearScore(env, same.id);
    return { status: 200, data: { id: same.id, merged: true } };
  }

  const id = newId();
  await env.DB.prepare("INSERT INTO listings (id, user_id, kind, title, price, cat, unit_type, place, descr, contact, photos, status, created_at, updated_at, bumped_at, source_type, source_id, source_group, source_poster, source_posted_at, merge_key, sender_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?, 'on', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    .bind(id, owner ? owner.id : GROUP_UID, kind, title, price, kind === "goods" ? b.cat : null, kind === "rent" && ["whole", "room", "both"].includes(b.unitType) ? b.unitType : null, place, descr, owner?.contact || "", JSON.stringify(keys), now, now, postedAt, owner ? "claimed" : "group", sourceId, group, poster, postedAt, mergeKey, senderHash).run();
  return { status: 201, data: { id } };
}

async function importListing(req, env) {
  needOperator(req, env);
  const b = await bodyOf(req);
  if (!Array.isArray(b.items)) {
    const r = await importOne(env, b);
    return json(r.data, r.status);
  }
  if (!b.items.length || b.items.length > 30) throw new Fail(400, "bad_items");
  const { items, ...common } = b;
  const results = [];
  for (let i = 0; i < items.length; i++) {
    try {
      results.push((await importOne(env, { ...common, ...items[i], sourceId: `${clean(common.sourceId, 70)}#${i}` })).data);
    } catch (e) {
      if (!(e instanceof Fail)) throw e;
      results.push({ error: e.code });
    }
  }
  return json({ results });
}

// 每天清掉过期的群里搬来的条目和照片，不留着
async function purgeExpired(env) {
  // 群帖不再到期删除（10-31 用户定）。删掉的帖子照片留 30 天，过了只留小图
  const old = (await env.DB.prepare("SELECT id, photos FROM listings WHERE status = 'deleted' AND deleted_at < ? AND photos != '[]' LIMIT 200").bind(Date.now() - DELETED_KEEP).all()).results;
  for (const r of old) {
    await removePhotos(env, JSON.parse(r.photos));
    await env.DB.prepare("UPDATE listings SET photos = '[]' WHERE id = ?").bind(r.id).run();
  }
  await env.DB.prepare("DELETE FROM claim_codes WHERE expires_at < ?").bind(Date.now()).run();
}

// 最接近成交的两个动作，只记每日总数
async function countClick(req, env) {
  const { what } = await bodyOf(req);
  if (what !== "copy" && what !== "group") throw new Fail(400, "bad_click");
  await bump(env, "*", what === "copy" ? "copy" : "group_click");
  return json({ ok: true });
}

// 本机定时任务：取没打分的（改过价的分已清空），打完批量写回
async function unscored(req, env) {
  needOperator(req, env);
  const now = Date.now();
  const rows = (await env.DB.prepare("SELECT * FROM listings WHERE kind = 'goods' AND status IN ('on','reserved') AND score IS NULL ORDER BY bumped_at DESC LIMIT 100").all()).results;
  const origin = new URL(req.url).origin;
  const comps = {};
  for (const cat of new Set(rows.map(r => r.cat))) {
    comps[cat] = (await env.DB.prepare("SELECT id, title, price, sold_price FROM listings WHERE kind = 'goods' AND cat = ? AND status IN ('on', 'reserved', 'off') AND bumped_at >= ? ORDER BY sold_price IS NOT NULL DESC, bumped_at DESC LIMIT 30").bind(cat, now - 90 * 86400000).all()).results;
  }
  return json({
    items: rows.map(r => {
      const first = JSON.parse(r.photos)[0];
      return {
        id: r.id, title: r.title, price: r.price, cat: r.cat, cond: r.cond, place: r.place,
        photo: first ? `${origin}/p/${first}` : null,
        comps: comps[r.cat].filter(c => c.id !== r.id).map(c => c.sold_price === null ? { title: c.title, price: c.price, sold: false } : { title: c.title, price: c.sold_price, listed: c.price, sold: true })
      };
    })
  });
}

async function setScores(req, env) {
  needOperator(req, env);
  const b = await bodyOf(req);
  const list = Array.isArray(b) ? b : b.scores;
  if (!Array.isArray(list) || !list.length || list.length > 200) throw new Fail(400, "bad_scores");
  for (const x of list) {
    if (typeof x?.id !== "string" || !Number.isInteger(x.score) || x.score < 1 || x.score > 4) throw new Fail(400, "bad_score");
  }
  const now = Date.now();
  const done = await env.DB.batch(list.map(x => env.DB.prepare("UPDATE listings SET score = ?, scored_at = ? WHERE id = ? AND kind = 'goods'").bind(x.score, now, x.id)));
  return json({ updated: done.reduce((n, r) => n + r.meta.changes, 0) });
}

// 群帖下架：只有管理员能做（10-31 用户定：原帖人来找我们，由管理员删）。照片一起删，留编号防再导入
async function takedown(req, env, id) {
  await needStaff(req, env);
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ? AND source_type = 'group'").bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  await env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind(row.source_id, Date.now()).run();
  await deleteRows(env, [row]);
  return json({ ok: true });
}

// ---- 认领：用自己的微信把验证码发出来，导入流程核对发送者 ----
const CODE_CHARS = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
// 卖家先加运营微信，等通过好友再私聊发代码；运营每小时读一次，所以给 24 小时
const CODE_TTL = 24 * 3600 * 1000, CODE_PER_DAY = 10, FAILS_PER_HOUR = 5, SITE_FAILS_PER_HOUR = 200;

async function newClaimCode(req, env) {
  const u = await needAgreed(req, env);
  if (u.sender_hash) throw new Fail(409, "already_claimed");
  if (await bump(env, u.id, "claim_code") > CODE_PER_DAY) throw new Fail(429, "daily_limit");
  const raw = crypto.getRandomValues(new Uint8Array(32));
  let code = "";
  for (const x of raw) {
    if (x >= 248) continue;  // 248 = 31 × 8，丢掉尾数才均匀
    code += CODE_CHARS[x % 31];
    if (code.length === 6) break;
  }
  const expiresAt = Date.now() + CODE_TTL;
  // 再取新码时旧码不作废：已经发出去的那个可能还在等核对
  await env.DB.prepare("INSERT INTO claim_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)").bind(await sha256(code), u.id, expiresAt).run();
  return json({ code, expiresAt }, 201);
}

async function claimStatus(req, env) {
  const u = await needUser(req, env);
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND source_type = 'claimed'").bind(u.id).first();
  return json({ claimed: !!u.sender_hash, count: c.n, contact: u.contact || null });
}

// 导入流程读到“发送者 + 验证码”后调这里
async function verifyClaim(req, env) {
  needOperator(req, env);
  const b = await bodyOf(req);
  if (!b.senderId) throw new Fail(400, "need_sender");
  const senderHash = await senderHashOf(env, b.senderId);
  const hour = Math.floor(Date.now() / 3600000);
  const tried = await env.DB.prepare("SELECT sender_hash, n FROM claim_attempts WHERE hour = ? AND sender_hash IN (?, '*')").bind(hour, senderHash).all();
  for (const r of tried.results) {
    if (r.n >= (r.sender_hash === "*" ? SITE_FAILS_PER_HOUR : FAILS_PER_HOUR)) throw new Fail(429, "too_many_tries");
  }
  const code = String(b.code || "").trim().toUpperCase();
  // 删除并返回，保证一次性
  const hit = await env.DB.prepare("DELETE FROM claim_codes WHERE code_hash = ? AND expires_at > ? RETURNING user_id").bind(await sha256(code), Date.now()).first();
  if (!hit) {
    const up = "INSERT INTO claim_attempts (sender_hash, hour, n) VALUES (?, ?, 1) ON CONFLICT (sender_hash, hour) DO UPDATE SET n = n + 1";
    await env.DB.batch([env.DB.prepare(up).bind(senderHash, hour), env.DB.prepare(up).bind("*", hour)]);
    throw new Fail(404, "bad_code");
  }
  const taken = await env.DB.prepare("SELECT id FROM users WHERE sender_hash = ?").bind(senderHash).first();
  if (taken && taken.id !== hit.user_id) throw new Fail(409, "sender_taken");
  const u = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(hit.user_id).first();
  if (!u || u.banned) throw new Fail(404, "bad_code");
  const now = Date.now();
  const done = await env.DB.batch([
    env.DB.prepare("UPDATE users SET sender_hash = ? WHERE id = ?").bind(senderHash, u.id),
    // 过期的不转，等定时清理
    env.DB.prepare("UPDATE listings SET user_id = ?, contact = ?, source_type = 'claimed', updated_at = ? WHERE sender_hash = ? AND source_type = 'group'").bind(u.id, u.contact || "", now, senderHash),
    // 认领好了，他手里别的码都没用了
    env.DB.prepare("DELETE FROM claim_codes WHERE user_id = ?").bind(u.id)
  ]);
  const moved = done[1].meta.changes;
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND source_type = 'claimed'").bind(u.id).first();
  // 开了通知才收得到；推送失败不影响认领
  await pushToUser(env, u.id, "认领好了", `${moved} 件已转到你名下`).catch(() => 0);
  return json({ ok: true, count: c.n, moved });
}

// 认领后填愿意公开的微信号；只进他认领来的条目，不碰他自己发的
async function setPublicContact(req, env) {
  const u = await needUser(req, env);
  if (!u.sender_hash) throw new Fail(403, "not_claimed");
  const contact = clean((await bodyOf(req)).contact, 40);
  if (contact) checkWechat(contact);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET contact = ? WHERE id = ?").bind(contact || null, u.id),
    env.DB.prepare("UPDATE listings SET contact = ?, updated_at = ? WHERE user_id = ? AND source_type = 'claimed'").bind(contact, Date.now(), u.id)
  ]);
  return json({ ok: true });
}

// ---- 路由 ----
async function route(req, env) {
  const url = new URL(req.url), path = url.pathname, method = req.method;
  let m;
  if (method === "GET" && path === "/health") return json({ ok: true });
  if (method === "GET" && path === "/v1/config") return json({ opsWechat: env.OPS_WECHAT || null, contactWechat: env.CONTACT_WECHAT || null, aiDescribe: aiEnabled(env) });
  if (method === "GET" && path === "/privacy") return privacyPage(env);
  if (method === "GET" && path === "/support") return supportPage(env);
  if (method === "GET" && path === "/rules") return rulesPage(env);
  if (method === "GET" && (m = /^\/l\/([0-9a-f]+)$/.exec(path))) return listingPage(env, url, m[1]);
  if (method === "GET" && (m = /^\/p\/(.+)$/.exec(path))) return servePhoto(env, m[1]);

  if (method === "POST" && path === "/v1/auth/apple") return login(req, env);
  if (method === "POST" && path === "/v1/auth/dev") return devLogin(req, env);
  if (method === "POST" && path === "/v1/auth/logout") return logout(req, env);
  if (method === "POST" && path === "/v1/me/agree") return agree(req, env);
  if (method === "GET" && path === "/v1/me") {
    const u = await needUser(req, env);
    return json({ ...meOf(u), aiLeft: await aiLeftOf(env, u.id) });
  }
  if (method === "PATCH" && path === "/v1/me") return updateProfile(req, env);
  if (method === "POST" && path === "/v1/me/avatar") return uploadAvatar(req, env);
  if (method === "DELETE" && path === "/v1/me/avatar") return removeAvatar(req, env);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/report-name$/.exec(path))) return reportName(req, env, m[1]);
  if (method === "DELETE" && path === "/v1/me") return deleteAccount(req, env);
  if (method === "GET" && path === "/v1/me/listings") return mine(req, env, url);
  if (method === "GET" && path === "/v1/me/blocks") return blockList(req, env);
  if (method === "GET" && path === "/v1/me/claim") return claimStatus(req, env);
  if (method === "POST" && path === "/v1/me/contact") return setPublicContact(req, env);
  if (method === "POST" && path === "/v1/claim/code") return newClaimCode(req, env);

  if (method === "GET" && path === "/v1/listings") return feed(req, env, url);
  if (method === "GET" && (m = /^\/v1\/users\/([0-9a-f]+)\/listings$/.exec(path))) return sellerPage(req, env, url, m[1]);
  if (method === "GET" && (m = /^\/v1\/listings\/([0-9a-f]+)\/poster$/.exec(path))) return posterPage(req, env, url, m[1]);
  if (method === "POST" && path === "/v1/listings") return createListing(req, env, url);
  if ((m = /^\/v1\/listings\/([0-9a-f]+)$/.exec(path))) {
    if (method === "GET") return oneListing(req, env, url, m[1]);
    if (method === "PUT") return updateListing(req, env, url, m[1]);
    if (method === "DELETE") return deleteListing(req, env, m[1]);
  }
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/status$/.exec(path))) return setStatus(req, env, url, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/want$/.exec(path))) return sendWant(req, env, m[1]);
  if (method === "GET" && path === "/v1/me/wants") return myWants(req, env, url);
  if (method === "POST" && path === "/v1/me/device") return saveDevice(req, env);
  if ((m = /^\/v1\/wants\/([0-9a-f]+)$/.exec(path)) && method === "DELETE") return deleteWant(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/wants\/([0-9a-f]+)\/report$/.exec(path))) return reportWant(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/wants\/([0-9a-f]+)\/block$/.exec(path))) return blockWant(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/price$/.exec(path))) return setPrice(req, env, url, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/takedown$/.exec(path))) return takedown(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/bump$/.exec(path))) return bumpListing(req, env, url, m[1]);
  if (method === "POST" && /^\/v1\/listings\/[0-9a-f]+\/click$/.test(path)) return countClick(req, env);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/view$/.exec(path))) return countView(env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/report$/.exec(path))) return report(req, env, m[1]);

  if (method === "POST" && path === "/v1/photos") return uploadPhoto(req, env);
  if (method === "POST" && path === "/v1/ai/describe") return aiDescribe(req, env, url);
  if (method === "POST" && path === "/v1/ai/group") return aiGroup(req, env, url);
  if (method === "POST" && path === "/v1/listings/batch") return createBatch(req, env, url);
  if (method === "GET" && path === "/v1/admin/ai-cost") return aiCost(req, env);

  if ((m = /^\/v1\/blocks\/([0-9a-f]+)$/.exec(path))) {
    if (method === "POST") return block(req, env, m[1]);
    if (method === "DELETE") return unblock(req, env, m[1]);
  }

  if (method === "POST" && path === "/v1/admin/import") return importListing(req, env);
  if (method === "GET" && path === "/v1/admin/unscored") return unscored(req, env);
  if (method === "POST" && path === "/v1/admin/scores") return setScores(req, env);
  if (method === "POST" && path === "/v1/admin/claim/verify") return verifyClaim(req, env);
  if (method === "GET" && path === "/v1/admin/stats") return adminStats(req, env);
  if (method === "GET" && path === "/v1/admin/event-stats") return eventStats(req, env, url);
  if (method === "POST" && path === "/v1/admin/tags/backfill") return backfillTags(req, env, url);
  if (method === "POST" && path === "/v1/events") return postEvents(req, env);
  if (method === "GET" && path === "/v1/admin/reports") return adminReports(req, env, url);
  if (method === "POST" && (m = /^\/v1\/admin\/reports\/([0-9a-f]+)\/close$/.exec(path))) return adminCloseReport(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/listings\/([0-9a-f]+)\/restore$/.exec(path))) return adminRestore(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/listings\/([0-9a-f]+)\/remove$/.exec(path))) return adminRemove(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/ban$/.exec(path))) return adminBan(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/reset-name$/.exec(path))) return adminResetName(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/remove-avatar$/.exec(path))) return adminRemoveAvatar(req, env, m[1]);

  throw new Fail(404, "not_found");
}

export default {
  async scheduled(event, env) {
    await purgeExpired(env);
    await purgeEvents(env);
    // 群帖导入和漏掉的，每天补一点标签
    await tagMissing(env, 30);
  },
  async fetch(req, env, ctx) {
    if (ctx) CTX.set(req, ctx);
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof Fail) return json({ error: e.code }, e.status);
      console.error(e && e.stack || e);
      return json({ error: "server_error" }, 500);
    }
  }
};
