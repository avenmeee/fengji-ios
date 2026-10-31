// 蜂集后端：买、卖、租房的条目，登录，照片，举报、屏蔽、删号、管理。
import { describePhoto } from "./ai.js";
import { exchangeCode, fetchAppleKeys, revokeToken, verifyIdentityToken } from "./apple.js";
import { listingPage, privacyPage, supportPage } from "./pages.js";
import { pushToUser } from "./push.js";

const CATS = ["furn", "elec", "kitchen", "art", "other"];
const CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"];
const BUMP_EVERY = 24 * 3600 * 1000;
const REASONS = ["违规内容", "虚假信息", "骚扰或诈骗", "其他"];
const MAX_PHOTOS = 3, MAX_RENT_PHOTOS = 9, MAX_RENT_DESC = 5000, MAX_PHOTO_BYTES = 1_500_000;
const AUTO_HIDE_REPORTS = 3;
const LIMITS = { post: 10, photo: 30 }, SITE_PHOTO_LIMIT = 2000;
const MAX_LIVE_LISTINGS = 50;
const PAGE = 40;
const GROUP_MAX_AGE = 10 * 86400 * 1000;  // 群里搬来的超过 10 天隐藏：旧帖多半卖掉了
const GROUP_UID = "0".repeat(32);  // 群里搬来的条目挂在这个编号下，不对应真人
// 导入时拦下联系方式和门牌：这类信息不能存
const CONTACT_PATTERNS = [/微信号?\s*[:：]?\s*[A-Za-z][-_A-Za-z0-9]{5,}/, /\b(wx|vx|wechat)\s*[:：]?\s*[-_A-Za-z0-9]{5,}/i, /(?<!\d)1\d{10}(?!\d)/, /(?<!\d)(\+?1[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}(?!\d)/];
const ADDRESS_PATTERN = /\b\d{1,5}\s+[A-Za-z][A-Za-z. ]*\b(st|street|ave|avenue|rd|road|dr|drive|ln|lane|blvd|ct|court|way|pl|place|hwy)\b/i;

// 发布前过滤。命中就不让发（规则 1.2：要有过滤）。
const BANNED = [/约炮/, /裸聊/, /援交/, /代孕/, /枪支/, /冰毒/, /大麻/, /代写/, /代考/, /假证/, /办证/, /毕业证/, /学位证/, /学历认证/, /学位认证/, /留服认证/, /代办/, /成绩单/, /换汇/, /代换/, /换美元/, /换美金/, /换人民币/, /美元换/, /美金换/, /人民币换/, /\bdiploma\b/i, /赌博/, /博彩/, /\bescort\b/i, /\bcocaine\b/i, /\bfentanyl\b/i];

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
const meOf = u => ({ id: u.id, isAdmin: !!u.is_admin, agreed: !!u.agreed_at, name: u.nickname || defaultName(u.id), color: u.avatar_color ?? defaultColor(u.id), named: !!u.nickname });
const NAME_NOT_ALLOWED = /官方|管理员|客服|蜂集|admin|apple|微信|weixin|\bvx\b|\bwx\b|\d{6,}/i;
const SELLER_COLUMNS = "(SELECT nickname FROM users u WHERE u.id = l.user_id) AS seller_nick, (SELECT avatar_color FROM users u WHERE u.id = l.user_id) AS seller_color";

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
  const refresh = await exchangeCode(env, b.authorizationCode).catch(() => null);
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

function checkListing(b, userId, existing = []) {
  const kind = b.kind;
  if (kind !== "goods" && kind !== "rent") throw new Fail(400, "bad_kind");
  const title = clean(b.title, 40), place = clean(b.place, 40), descr = clean(b.desc, kind === "rent" ? MAX_RENT_DESC : 500), contact = clean(b.contact, 40);
  const price = Number(b.price);
  if (!title) throw new Fail(400, "need_title");
  if (!Number.isInteger(price) || price < 0 || price > 1_000_000) throw new Fail(400, "bad_price");
  if (kind === "rent" && price === 0) throw new Fail(400, "bad_price");
  if (kind === "rent" && !place) throw new Fail(400, "need_place");
  const text = [title, place, descr].join(" ");
  if (BANNED.some(r => r.test(text))) throw new Fail(422, "not_allowed");

  const photos = Array.isArray(b.photos) ? b.photos : [];
  if (photos.length > (kind === "rent" ? MAX_RENT_PHOTOS : MAX_PHOTOS)) throw new Fail(400, "too_many_photos");
  for (const k of photos) {
    if (existing.includes(k)) continue;
    if (typeof k !== "string" || !k.startsWith(userId + "/") || !/^[0-9a-f]+\/[0-9a-f]+\.jpg$/.test(k)) throw new Fail(400, "bad_photo");
  }

  const out = { kind, title, price, place, descr, contact, photos: JSON.stringify(photos), cat: null, cond: null, from_date: null, to_date: null, lease_end: null, utilities: 0, private_bath: 0, delivery: null, delivery_fee: null, pickup_before: null, pickup_after: null, long_term: 0, furnished: 0, room_type: null, unit_type: null, furniture: null, internet: 0, deposit: null, app_fee: null, parking: null, pets: null, roommates: null };
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
  return {
    id: row.id, uid: row.user_id, kind: row.kind, title: row.title, price: row.price,
    cat: row.cat, cond: row.cond, from: row.from_date,
    roomType: row.room_type || null, unitType: row.unit_type || null, internet: triView(row.internet), furniture: row.furniture || null, deposit: row.deposit ?? null, appFee: row.app_fee ?? null,
    parking: row.parking || null, pets: row.pets || null, roommates: row.roommates || null, to: row.to_date,
    leaseEnd: row.lease_end, utilities: !!row.utilities, privateBath: triView(row.private_bath), delivery: row.delivery,
    place: row.place, desc: row.descr, status: row.status,
    contact: group || !row.contact ? null : row.contact,
    sellerName: group ? (row.source_poster || null) : (nick || defaultName(row.user_id)),
    sellerColor: group ? null : (color ?? defaultColor(row.user_id)),
    sellerNamed: group ? true : !!nick,
    sourceType: row.source_type || "self", sourceGroup: row.source_group || null, sourcePoster: row.source_poster || null, sourcePostedAt: row.source_posted_at ?? null,
    score: mine ? null : (row.score ?? null),  // 卖家看不到自己的分
    deliveryFee: row.delivery_fee ?? null, pickupBefore: row.pickup_before || null, pickupAfter: row.pickup_after || null,
    longTerm: !!row.long_term, furnished: !!row.furnished,
    photos: JSON.parse(row.photos).map(k => ({ key: k, url: `${origin}/p/${k}` })),
    createdAt: row.created_at, bumpedAt: row.bumped_at, mine
  };
}

async function feed(req, env, url) {
  const viewer = await currentUser(req, env);
  const p = url.searchParams, kind = p.get("kind") === "rent" ? "rent" : "goods";
  const where = ["l.kind = ?", "l.status IN ('on', 'reserved')", "(l.source_type != 'group' OR l.source_posted_at >= ?)"], args = [kind, Date.now() - GROUP_MAX_AGE];
  if (kind === "goods" && CATS.includes(p.get("cat"))) { where.push("l.cat = ?"); args.push(p.get("cat")); }
  const unit = p.get("unit");
  if (kind === "rent" && (unit === "whole" || unit === "room")) { where.push("l.unit_type IN (?, 'both')"); args.push(unit); }
  const q = clean(p.get("q"), 40);
  if (q) {
    const like = "%" + q.replace(/[\\%_]/g, c => "\\" + c) + "%";
    where.push("(l.title LIKE ? ESCAPE '\\' OR l.descr LIKE ? ESCAPE '\\' OR l.place LIKE ? ESCAPE '\\')");
    args.push(like, like, like);
  }
  const offset = Math.max(0, Math.floor(Number(p.get("offset")) || 0));
  if (viewer) { where.push("l.user_id NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?)"); args.push(viewer.id); }
  const rows = (await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE ${where.join(" AND ")} ORDER BY COALESCE(l.score, 3) DESC, l.bumped_at DESC LIMIT ? OFFSET ?`).bind(...args, PAGE, offset).all()).results;
  return json({ items: rows.map(r => view(r, url.origin, viewer)), next: rows.length === PAGE ? offset + PAGE : null });
}

const groupExpired = row => row.source_type === "group" && !(row.source_posted_at >= Date.now() - GROUP_MAX_AGE);

async function oneListing(req, env, url, id) {
  const viewer = await currentUser(req, env);
  const row = await env.DB.prepare(`SELECT l.*, ${SELLER_COLUMNS} FROM listings l WHERE l.id = ?`).bind(id).first();
  const canSeeHidden = viewer && row && (viewer.id === row.user_id || viewer.is_admin);
  if (!row || (row.status === "hidden" && !canSeeHidden) || groupExpired(row)) throw new Fail(404, "not_found");
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
  await env.DB.prepare("INSERT INTO listings (id, user_id, kind, title, price, cat, cond, from_date, to_date, lease_end, utilities, private_bath, delivery, delivery_fee, pickup_before, pickup_after, long_term, furnished, room_type, unit_type, furniture, internet, deposit, app_fee, parking, pets, roommates, place, descr, contact, photos, status, created_at, updated_at, bumped_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'on', ?, ?, ?)")
    .bind(id, u.id, v.kind, v.title, v.price, v.cat, v.cond, v.from_date, v.to_date, v.lease_end, v.utilities, v.private_bath, v.delivery, v.delivery_fee, v.pickup_before, v.pickup_after, v.long_term, v.furnished, v.room_type, v.unit_type, v.furniture, v.internet, v.deposit, v.app_fee, v.parking, v.pets, v.roommates, v.place, v.descr, v.contact, v.photos, now, now, now).run();
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
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
  const v = checkListing(await bodyOf(req), u.id, JSON.parse(row.photos));
  if (v.kind !== row.kind) throw new Fail(400, "bad_kind");
  await env.DB.prepare("UPDATE listings SET title=?, price=?, cat=?, cond=?, from_date=?, to_date=?, lease_end=?, utilities=?, private_bath=?, delivery=?, delivery_fee=?, pickup_before=?, pickup_after=?, long_term=?, furnished=?, room_type=?, unit_type=?, furniture=?, internet=?, deposit=?, app_fee=?, parking=?, pets=?, roommates=?, place=?, descr=?, contact=?, photos=?, updated_at=? WHERE id=?")
    .bind(v.title, v.price, v.cat, v.cond, v.from_date, v.to_date, v.lease_end, v.utilities, v.private_bath, v.delivery, v.delivery_fee, v.pickup_before, v.pickup_after, v.long_term, v.furnished, v.room_type, v.unit_type, v.furniture, v.internet, v.deposit, v.app_fee, v.parking, v.pets, v.roommates, v.place, v.descr, v.contact, v.photos, Date.now(), id).run();
  if (v.price !== row.price) await clearScore(env, id);
  const kept = new Set(JSON.parse(v.photos));
  await removePhotos(env, JSON.parse(row.photos).filter(k => !kept.has(k)));
  const next = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  return json(view(next, url.origin, u));
}

async function setStatus(req, env, url, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status === "hidden") throw new Fail(403, "hidden");
  const { status } = await bodyOf(req);
  if (!["on", "reserved", "off"].includes(status)) throw new Fail(400, "bad_status");
  await env.DB.prepare("UPDATE listings SET status=?, updated_at=? WHERE id=?").bind(status, Date.now(), id).run();
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
  if (keys.length) await env.PHOTOS.delete(keys);
}

async function deleteRows(env, rows) {
  await removePhotos(env, rows.flatMap(r => JSON.parse(r.photos)));
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
  await deleteRows(env, [row]);
  return json({ ok: true });
}

async function mine(req, env, url) {
  const u = await needUser(req, env);
  const rows = (await env.DB.prepare("SELECT * FROM listings WHERE user_id = ? ORDER BY created_at DESC LIMIT 200").bind(u.id).all()).results;
  return json({ items: rows.map(r => view(r, url.origin, u)) });
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
  await env.DB.prepare("INSERT OR IGNORE INTO reports (id, listing_id, reporter_id, reason, note, created_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(newId(), id, u ? u.id : "anon:" + newId(), b.reason, clean(b.note, 300), Date.now()).run();
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE listing_id = ? AND status = 'open' AND reporter_id NOT LIKE 'anon:%' AND reporter_id NOT LIKE 'want:%' AND reporter_id NOT LIKE 'name:%'").bind(id).first();
  if (c.n >= AUTO_HIDE_REPORTS) await env.DB.prepare("UPDATE listings SET status = 'hidden' WHERE id = ? AND status = 'on'").bind(id).run();
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
  const rows = (await env.DB.prepare("SELECT blocked_id AS id, created_at AS at FROM blocks WHERE user_id = ? ORDER BY created_at DESC").bind(u.id).all()).results;
  return json({ items: rows });
}

// ---- 账号 ----
async function agree(req, env) {
  const u = await needUser(req, env);
  const now = Date.now();
  await env.DB.prepare("UPDATE users SET agreed_at = COALESCE(agreed_at, ?) WHERE id = ?").bind(now, u.id).run();
  return json(meOf({ ...u, agreed_at: u.agreed_at || now }));
}

async function wipeUser(env, u) {
  const rows = (await env.DB.prepare("SELECT id, photos FROM listings WHERE user_id = ?").bind(u.id).all()).results;
  await deleteRows(env, rows);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM blocks WHERE user_id = ? OR blocked_id = ?").bind(u.id, u.id),
    env.DB.prepare("DELETE FROM claim_codes WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM wants WHERE seller_id = ? OR buyer_id = ?").bind(u.id, u.id),
    env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id),
    // 删过号的人，之后群里的帖子也不再搬
    ...(u.sender_hash ? [env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind("sender:" + u.sender_hash, Date.now())] : []),
    env.DB.prepare("DELETE FROM reports WHERE reporter_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM daily_counts WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(u.id)
  ]);
}

async function deleteAccount(req, env) {
  const u = await needUser(req, env);
  await revokeToken(env, u.apple_refresh).catch(() => false);
  await wipeUser(env, u);
  return json({ ok: true });
}

async function logout(req, env) {
  const m = /^Bearer (\S+)$/.exec(req.headers.get("authorization") || "");
  if (m) {
    const u = await currentUser(req, env);
    if (u) await env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id).run();
    await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(m[1])).run();
  }
  return json({ ok: true });
}

// ---- 管理 ----
async function adminReports(req, env, url) {
  await needAdmin(req, env);
  const rows = (await env.DB.prepare(`SELECT r.id, r.reason, r.note, r.created_at AS at, r.reporter_id AS reporter, r.reported_user, (SELECT nickname FROM users u WHERE u.id = l.user_id) AS seller_nick, l.id AS lid, l.user_id, l.kind, l.title, l.price, l.cat, l.cond, l.from_date, l.to_date, l.lease_end, l.utilities, l.private_bath, l.delivery, l.delivery_fee, l.pickup_before, l.pickup_after, l.long_term, l.furnished, l.room_type, l.unit_type, l.furniture, l.internet, l.deposit, l.app_fee, l.parking, l.pets, l.roommates, l.score, l.source_type, l.source_group, l.source_poster, l.source_posted_at, l.bumped_at, l.place, l.descr, l.contact, l.photos, l.status, l.created_at
    FROM reports r JOIN listings l ON l.id = r.listing_id WHERE r.status = 'open' ORDER BY r.created_at DESC LIMIT 100`).all()).results;
  return json({ items: rows.map(r => ({ id: r.id, reason: r.reason, note: r.note, at: r.at, reporter: r.reporter, reportedUser: r.reported_user || null, listing: view({ ...r, id: r.lid }, url.origin, { id: "admin" }) })) });
}
async function adminCloseReport(req, env, id) {
  await needAdmin(req, env);
  await env.DB.prepare("UPDATE reports SET status = 'done' WHERE id = ?").bind(id).run();
  return json({ ok: true });
}
// 忽略举报后恢复上架
async function adminRestore(req, env, id) {
  await needAdmin(req, env);
  await env.DB.batch([
    env.DB.prepare("UPDATE reports SET status = 'done' WHERE listing_id = ?").bind(id),
    env.DB.prepare("UPDATE listings SET status = 'on' WHERE id = ? AND status = 'hidden'").bind(id)
  ]);
  return json({ ok: true });
}
async function adminBan(req, env, id) {
  const admin = await needAdmin(req, env);
  if (id === admin.id) throw new Fail(400, "self");
  const rows = (await env.DB.prepare("SELECT id, photos FROM listings WHERE user_id = ?").bind(id).all()).results;
  await deleteRows(env, rows);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET banned = 1 WHERE id = ?").bind(id),
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
  const row = await env.DB.prepare(`SELECT l.user_id, l.source_type, ${SELLER_COLUMNS} FROM listings l WHERE l.id = ?`).bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  if (row.source_type === "group") throw new Fail(400, "bad_reason");
  await env.DB.prepare("INSERT OR IGNORE INTO reports (id, listing_id, reporter_id, reason, note, reported_user, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .bind(newId(), id, "name:" + (u ? u.id : newId()), "昵称不当", row.seller_nick || "", row.user_id, Date.now()).run();
  return json({ ok: true });
}

async function adminResetName(req, env, id) {
  await needAdmin(req, env);
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET nickname = NULL WHERE id = ?").bind(id),
    env.DB.prepare("UPDATE reports SET status = 'done' WHERE reported_user = ? AND reason = '昵称不当'").bind(id)
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
const AI_PER_DAY = 30;
let priceRefs = null;  // 参考表不常变，存在实例里
const aiEnabled = env => env.AI_DESCRIBE === "on" && (!!env.ANTHROPIC_API_KEY || env.AI_MOCK === "1");

async function bumpBy(env, userId, what, by) {
  await env.DB.prepare("INSERT INTO daily_counts (day, user_id, what, n) VALUES (?, ?, ?, ?) ON CONFLICT (day, user_id, what) DO UPDATE SET n = n + excluded.n").bind(today(), userId, what, by).run();
}

async function monthSum(env, what) {
  const r = await env.DB.prepare("SELECT COALESCE(SUM(n), 0) AS n FROM daily_counts WHERE user_id = '*' AND what = ? AND day LIKE ?").bind(what, today().slice(0, 7) + "%").first();
  return r.n;
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
  if (await bump(env, u.id, "ai_describe") > AI_PER_DAY) throw new Fail(429, "ai_limit");
  if (await monthSum(env, "ai_microusd") >= Number(env.AI_MONTHLY_USD || 5) * 1e6) throw new Fail(503, "ai_budget");
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
  return json({ name: clean(r.name, 40), cat: r.cat, cond: r.cond, price });
}

async function aiCost(req, env) {
  needOperator(req, env);
  const calls = await monthSum(env, "ai_describe"), micro = await monthSum(env, "ai_microusd");
  return json({ month: today().slice(0, 7), calls, usd: micro / 1e6, perCallUsd: calls ? micro / 1e6 / calls : null, budgetUsd: Number(env.AI_MONTHLY_USD || 5) });
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
  if (now - postedAt > GROUP_MAX_AGE) throw new Fail(422, "too_old");
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
  const rows = (await env.DB.prepare("SELECT id, photos FROM listings WHERE source_type = 'group' AND (source_posted_at IS NULL OR source_posted_at < ?) LIMIT 200").bind(Date.now() - GROUP_MAX_AGE).all()).results;
  await deleteRows(env, rows);
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
  const rows = (await env.DB.prepare("SELECT * FROM listings WHERE kind = 'goods' AND status IN ('on','reserved') AND score IS NULL AND (source_type != 'group' OR source_posted_at >= ?) ORDER BY bumped_at DESC LIMIT 100").bind(now - GROUP_MAX_AGE).all()).results;
  const origin = new URL(req.url).origin;
  const comps = {};
  for (const cat of new Set(rows.map(r => r.cat))) {
    comps[cat] = (await env.DB.prepare("SELECT id, title, price FROM listings WHERE kind = 'goods' AND cat = ? AND bumped_at >= ? ORDER BY bumped_at DESC LIMIT 30").bind(cat, now - 90 * 86400000).all()).results;
  }
  return json({
    items: rows.map(r => {
      const first = JSON.parse(r.photos)[0];
      return {
        id: r.id, title: r.title, price: r.price, cat: r.cat, cond: r.cond, place: r.place,
        photo: first ? `${origin}/p/${first}` : null,
        comps: comps[r.cat].filter(c => c.id !== r.id).map(c => ({ title: c.title, price: c.price }))
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
    if (typeof x?.id !== "string" || !Number.isInteger(x.score) || x.score < 1 || x.score > 5) throw new Fail(400, "bad_score");
  }
  const now = Date.now();
  const done = await env.DB.batch(list.map(x => env.DB.prepare("UPDATE listings SET score = ?, scored_at = ? WHERE id = ? AND kind = 'goods'").bind(x.score, now, x.id)));
  return json({ updated: done.reduce((n, r) => n + r.meta.changes, 0) });
}

// 要求下架：不用登录，立刻生效，照片一起删，留编号防再导入
async function takedown(env, id) {
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ? AND source_type = 'group'").bind(id).first();
  if (!row) throw new Fail(404, "not_found");
  await env.DB.batch([
    env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind(row.source_id, Date.now()),
    env.DB.prepare("INSERT OR IGNORE INTO import_tombstones (source_id, created_at) VALUES (?, ?)").bind("key:" + row.merge_key, Date.now())
  ]);
  await deleteRows(env, [row]);
  return json({ ok: true });
}

// ---- 认领：用自己的微信把验证码发出来，导入流程核对发送者 ----
const CODE_CHARS = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
const CODE_TTL = 15 * 60 * 1000, CODE_PER_DAY = 10, FAILS_PER_HOUR = 5, SITE_FAILS_PER_HOUR = 200;

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
  await env.DB.batch([
    env.DB.prepare("DELETE FROM claim_codes WHERE user_id = ?").bind(u.id),
    env.DB.prepare("DELETE FROM wants WHERE seller_id = ? OR buyer_id = ?").bind(u.id, u.id),
    env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id),
    env.DB.prepare("INSERT INTO claim_codes (code_hash, user_id, expires_at) VALUES (?, ?, ?)").bind(await sha256(code), u.id, expiresAt)
  ]);
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
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET sender_hash = ? WHERE id = ?").bind(senderHash, u.id),
    // 过期的不转，等定时清理
    env.DB.prepare("UPDATE listings SET user_id = ?, contact = ?, source_type = 'claimed', updated_at = ? WHERE sender_hash = ? AND source_type = 'group' AND source_posted_at >= ?").bind(u.id, u.contact || "", now, senderHash, now - GROUP_MAX_AGE)
  ]);
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND source_type = 'claimed'").bind(u.id).first();
  return json({ ok: true, count: c.n });
}

// 认领后填愿意公开的微信号；只进他认领来的条目，不碰他自己发的
async function setPublicContact(req, env) {
  const u = await needUser(req, env);
  if (!u.sender_hash) throw new Fail(403, "not_claimed");
  const contact = clean((await bodyOf(req)).contact, 40);
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
  if (method === "GET" && path === "/v1/config") return json({ opsWechat: env.OPS_WECHAT || null, aiDescribe: aiEnabled(env) });
  if (method === "GET" && path === "/privacy") return privacyPage(env);
  if (method === "GET" && path === "/support") return supportPage(env);
  if (method === "GET" && (m = /^\/l\/([0-9a-f]+)$/.exec(path))) return listingPage(env, url, m[1]);
  if (method === "GET" && (m = /^\/p\/(.+)$/.exec(path))) return servePhoto(env, m[1]);

  if (method === "POST" && path === "/v1/auth/apple") return login(req, env);
  if (method === "POST" && path === "/v1/auth/dev") return devLogin(req, env);
  if (method === "POST" && path === "/v1/auth/logout") return logout(req, env);
  if (method === "POST" && path === "/v1/me/agree") return agree(req, env);
  if (method === "GET" && path === "/v1/me") return json(meOf(await needUser(req, env)));
  if (method === "PATCH" && path === "/v1/me") return updateProfile(req, env);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/report-name$/.exec(path))) return reportName(req, env, m[1]);
  if (method === "DELETE" && path === "/v1/me") return deleteAccount(req, env);
  if (method === "GET" && path === "/v1/me/listings") return mine(req, env, url);
  if (method === "GET" && path === "/v1/me/blocks") return blockList(req, env);
  if (method === "GET" && path === "/v1/me/claim") return claimStatus(req, env);
  if (method === "POST" && path === "/v1/me/contact") return setPublicContact(req, env);
  if (method === "POST" && path === "/v1/claim/code") return newClaimCode(req, env);

  if (method === "GET" && path === "/v1/listings") return feed(req, env, url);
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
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/takedown$/.exec(path))) return takedown(env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/bump$/.exec(path))) return bumpListing(req, env, url, m[1]);
  if (method === "POST" && /^\/v1\/listings\/[0-9a-f]+\/click$/.test(path)) return countClick(req, env);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/view$/.exec(path))) return countView(env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/report$/.exec(path))) return report(req, env, m[1]);

  if (method === "POST" && path === "/v1/photos") return uploadPhoto(req, env);
  if (method === "POST" && path === "/v1/ai/describe") return aiDescribe(req, env, url);
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
  if (method === "GET" && path === "/v1/admin/reports") return adminReports(req, env, url);
  if (method === "POST" && (m = /^\/v1\/admin\/reports\/([0-9a-f]+)\/close$/.exec(path))) return adminCloseReport(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/listings\/([0-9a-f]+)\/restore$/.exec(path))) return adminRestore(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/ban$/.exec(path))) return adminBan(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/reset-name$/.exec(path))) return adminResetName(req, env, m[1]);

  throw new Fail(404, "not_found");
}

export default {
  async scheduled(event, env) {
    await purgeExpired(env);
  },
  async fetch(req, env) {
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof Fail) return json({ error: e.code }, e.status);
      console.error(e && e.stack || e);
      return json({ error: "server_error" }, 500);
    }
  }
};
