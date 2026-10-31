// 蜂集后端：买、卖、租房的条目，登录，照片，举报、屏蔽、删号、管理。
import { exchangeCode, fetchAppleKeys, revokeToken, verifyIdentityToken } from "./apple.js";
import { listingPage, privacyPage, supportPage } from "./pages.js";

const CATS = ["furn", "kitchen", "elec", "art", "book", "wear", "other"];
const CONDS = ["全新", "几乎全新", "有使用痕迹", "有点旧"];
const RTYPES = ["整租", "单间", "寒假短租", "转租"];
const BUMP_EVERY = 24 * 3600 * 1000;
const REASONS = ["违规内容", "虚假信息", "骚扰或诈骗", "其他"];
const MAX_PHOTOS = 3, MAX_PHOTO_BYTES = 1_500_000;
const AUTO_HIDE_REPORTS = 3;
const LIMITS = { post: 10, photo: 30 }, SITE_PHOTO_LIMIT = 2000;
const MAX_LIVE_LISTINGS = 50;
const PAGE = 40;

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

const meOf = u => ({ id: u.id, isAdmin: !!u.is_admin, agreed: !!u.agreed_at });

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

function checkListing(b, userId) {
  const kind = b.kind;
  if (kind !== "goods" && kind !== "rent") throw new Fail(400, "bad_kind");
  const title = clean(b.title, 40), place = clean(b.place, 40), descr = clean(b.desc, 500), contact = clean(b.contact, 40);
  const price = Number(b.price);
  if (!title) throw new Fail(400, "need_title");
  if (!Number.isInteger(price) || price < 0 || price > 1_000_000) throw new Fail(400, "bad_price");
  if (kind === "rent" && price === 0) throw new Fail(400, "bad_price");
  if (!place) throw new Fail(400, "need_place");
  if (!contact) throw new Fail(400, "need_contact");
  const text = [title, place, descr].join(" ");
  if (BANNED.some(r => r.test(text))) throw new Fail(422, "not_allowed");

  const photos = Array.isArray(b.photos) ? b.photos : [];
  if (photos.length > MAX_PHOTOS) throw new Fail(400, "too_many_photos");
  for (const k of photos) {
    if (typeof k !== "string" || !k.startsWith(userId + "/") || !/^[0-9a-f]+\/[0-9a-f]+\.jpg$/.test(k)) throw new Fail(400, "bad_photo");
  }

  const out = { kind, title, price, place, descr, contact, photos: JSON.stringify(photos), cat: null, cond: null, rtype: null, from_date: null, to_date: null, lease_end: null, utilities: 0, private_bath: 0, delivery: null };
  if (kind === "goods") {
    if (!CATS.includes(b.cat)) throw new Fail(400, "bad_cat");
    if (!CONDS.includes(b.cond)) throw new Fail(400, "bad_cond");
    if (b.delivery !== "pickup" && b.delivery !== "deliver") throw new Fail(400, "bad_delivery");
    out.cat = b.cat; out.cond = b.cond; out.delivery = b.delivery;
  } else {
    if (!RTYPES.includes(b.rtype)) throw new Fail(400, "bad_rtype");
    const date = v => (v === "" || v == null) ? null : (/^\d{4}-\d{2}-\d{2}$/.test(v) ? v : (() => { throw new Fail(400, "bad_date"); })());
    out.rtype = b.rtype; out.from_date = date(b.from); out.to_date = date(b.to); out.lease_end = date(b.leaseEnd);
    out.utilities = b.utilities ? 1 : 0; out.private_bath = b.privateBath ? 1 : 0;
    if (out.from_date && out.to_date && out.from_date > out.to_date) throw new Fail(400, "bad_date");
  }
  return out;
}

function view(row, origin, viewer) {
  const mine = !!viewer && viewer.id === row.user_id;
  return {
    id: row.id, uid: row.user_id, kind: row.kind, title: row.title, price: row.price,
    cat: row.cat, cond: row.cond, rtype: row.rtype, from: row.from_date, to: row.to_date,
    leaseEnd: row.lease_end, utilities: !!row.utilities, privateBath: !!row.private_bath, delivery: row.delivery,
    place: row.place, desc: row.descr, status: row.status,
    contact: row.contact,
    photos: JSON.parse(row.photos).map(k => ({ key: k, url: `${origin}/p/${k}` })),
    createdAt: row.created_at, bumpedAt: row.bumped_at, mine
  };
}

async function feed(req, env, url) {
  const viewer = await currentUser(req, env);
  const p = url.searchParams, kind = p.get("kind") === "rent" ? "rent" : "goods";
  const where = ["l.kind = ?", "l.status = 'on'"], args = [kind];
  if (kind === "goods" && CATS.includes(p.get("cat"))) { where.push("l.cat = ?"); args.push(p.get("cat")); }
  if (kind === "rent" && RTYPES.includes(p.get("rtype"))) { where.push("l.rtype = ?"); args.push(p.get("rtype")); }
  const q = clean(p.get("q"), 40);
  if (q) {
    const like = "%" + q.replace(/[\\%_]/g, c => "\\" + c) + "%";
    where.push("(l.title LIKE ? ESCAPE '\\' OR l.descr LIKE ? ESCAPE '\\' OR l.place LIKE ? ESCAPE '\\')");
    args.push(like, like, like);
  }
  const before = Number(p.get("before"));
  if (before > 0) { where.push("l.bumped_at < ?"); args.push(before); }
  if (viewer) { where.push("l.user_id NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?)"); args.push(viewer.id); }
  const rows = (await env.DB.prepare(`SELECT l.* FROM listings l WHERE ${where.join(" AND ")} ORDER BY l.bumped_at DESC LIMIT ?`).bind(...args, PAGE).all()).results;
  return json({ items: rows.map(r => view(r, url.origin, viewer)), next: rows.length === PAGE ? rows[rows.length - 1].bumped_at : null });
}

async function oneListing(req, env, url, id) {
  const viewer = await currentUser(req, env);
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  const canSeeHidden = viewer && row && (viewer.id === row.user_id || viewer.is_admin);
  if (!row || (row.status === "hidden" && !canSeeHidden)) throw new Fail(404, "not_found");
  return json(view(row, url.origin, viewer));
}

async function bump(env, userId, what) {
  const day = today();
  const r = await env.DB.prepare("INSERT INTO daily_counts (day, user_id, what, n) VALUES (?, ?, ?, 1) ON CONFLICT (day, user_id, what) DO UPDATE SET n = n + 1 RETURNING n").bind(day, userId, what).first();
  return r.n;
}

async function createListing(req, env, url) {
  const u = await needAgreed(req, env);
  const v = checkListing(await bodyOf(req), u.id);
  const live = await env.DB.prepare("SELECT COUNT(*) AS n FROM listings WHERE user_id = ? AND status = 'on'").bind(u.id).first();
  if (live.n >= MAX_LIVE_LISTINGS) throw new Fail(429, "too_many_listings");
  if (await bump(env, u.id, "post") > LIMITS.post) throw new Fail(429, "daily_limit");
  const id = newId(), now = Date.now();
  await bump(env, "*", "post");
  await env.DB.prepare("INSERT INTO listings (id, user_id, kind, title, price, cat, cond, rtype, from_date, to_date, lease_end, utilities, private_bath, delivery, place, descr, contact, photos, status, created_at, updated_at, bumped_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'on', ?, ?, ?)")
    .bind(id, u.id, v.kind, v.title, v.price, v.cat, v.cond, v.rtype, v.from_date, v.to_date, v.lease_end, v.utilities, v.private_bath, v.delivery, v.place, v.descr, v.contact, v.photos, now, now, now).run();
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
  const v = checkListing(await bodyOf(req), u.id);
  if (v.kind !== row.kind) throw new Fail(400, "bad_kind");
  await env.DB.prepare("UPDATE listings SET title=?, price=?, cat=?, cond=?, rtype=?, from_date=?, to_date=?, lease_end=?, utilities=?, private_bath=?, delivery=?, place=?, descr=?, contact=?, photos=?, updated_at=? WHERE id=?")
    .bind(v.title, v.price, v.cat, v.cond, v.rtype, v.from_date, v.to_date, v.lease_end, v.utilities, v.private_bath, v.delivery, v.place, v.descr, v.contact, v.photos, Date.now(), id).run();
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
  if (status !== "on" && status !== "off") throw new Fail(400, "bad_status");
  await env.DB.prepare("UPDATE listings SET status=?, updated_at=? WHERE id=?").bind(status, Date.now(), id).run();
  if (status === "off" && row.status === "on") await bump(env, "*", "sold");
  const next = await env.DB.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first();
  return json(view(next, url.origin, u));
}

// 擦亮：顶回最新，一条一天一次
async function bumpListing(req, env, url, id) {
  const u = await needUser(req, env);
  const row = await ownedOrFail(env, id, u);
  if (row.status !== "on") throw new Fail(400, "not_on");
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
  const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE listing_id = ? AND status = 'open' AND reporter_id NOT LIKE 'anon:%'").bind(id).first();
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
  if (m) await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256(m[1])).run();
  return json({ ok: true });
}

// ---- 管理 ----
async function adminReports(req, env, url) {
  await needAdmin(req, env);
  const rows = (await env.DB.prepare(`SELECT r.id, r.reason, r.note, r.created_at AS at, r.reporter_id AS reporter, l.id AS lid, l.user_id, l.kind, l.title, l.price, l.cat, l.cond, l.rtype, l.from_date, l.to_date, l.lease_end, l.utilities, l.private_bath, l.delivery, l.bumped_at, l.place, l.descr, l.contact, l.photos, l.status, l.created_at
    FROM reports r JOIN listings l ON l.id = r.listing_id WHERE r.status = 'open' ORDER BY r.created_at DESC LIMIT 100`).all()).results;
  return json({ items: rows.map(r => ({ id: r.id, reason: r.reason, note: r.note, at: r.at, reporter: r.reporter, listing: view({ ...r, id: r.lid }, url.origin, { id: "admin" }) })) });
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
  return json({ posts: of("post"), views: of("view"), sold: of("sold") });
}

// ---- 路由 ----
async function route(req, env) {
  const url = new URL(req.url), path = url.pathname, method = req.method;
  let m;
  if (method === "GET" && path === "/health") return json({ ok: true });
  if (method === "GET" && path === "/privacy") return privacyPage(env);
  if (method === "GET" && path === "/support") return supportPage(env);
  if (method === "GET" && (m = /^\/l\/([0-9a-f]+)$/.exec(path))) return listingPage(env, url, m[1]);
  if (method === "GET" && (m = /^\/p\/(.+)$/.exec(path))) return servePhoto(env, m[1]);

  if (method === "POST" && path === "/v1/auth/apple") return login(req, env);
  if (method === "POST" && path === "/v1/auth/dev") return devLogin(req, env);
  if (method === "POST" && path === "/v1/auth/logout") return logout(req, env);
  if (method === "POST" && path === "/v1/me/agree") return agree(req, env);
  if (method === "GET" && path === "/v1/me") return json(meOf(await needUser(req, env)));
  if (method === "DELETE" && path === "/v1/me") return deleteAccount(req, env);
  if (method === "GET" && path === "/v1/me/listings") return mine(req, env, url);
  if (method === "GET" && path === "/v1/me/blocks") return blockList(req, env);

  if (method === "GET" && path === "/v1/listings") return feed(req, env, url);
  if (method === "POST" && path === "/v1/listings") return createListing(req, env, url);
  if ((m = /^\/v1\/listings\/([0-9a-f]+)$/.exec(path))) {
    if (method === "GET") return oneListing(req, env, url, m[1]);
    if (method === "PUT") return updateListing(req, env, url, m[1]);
    if (method === "DELETE") return deleteListing(req, env, m[1]);
  }
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/status$/.exec(path))) return setStatus(req, env, url, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/bump$/.exec(path))) return bumpListing(req, env, url, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/view$/.exec(path))) return countView(env, m[1]);
  if (method === "POST" && (m = /^\/v1\/listings\/([0-9a-f]+)\/report$/.exec(path))) return report(req, env, m[1]);

  if (method === "POST" && path === "/v1/photos") return uploadPhoto(req, env);

  if ((m = /^\/v1\/blocks\/([0-9a-f]+)$/.exec(path))) {
    if (method === "POST") return block(req, env, m[1]);
    if (method === "DELETE") return unblock(req, env, m[1]);
  }

  if (method === "GET" && path === "/v1/admin/stats") return adminStats(req, env);
  if (method === "GET" && path === "/v1/admin/reports") return adminReports(req, env, url);
  if (method === "POST" && (m = /^\/v1\/admin\/reports\/([0-9a-f]+)\/close$/.exec(path))) return adminCloseReport(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/listings\/([0-9a-f]+)\/restore$/.exec(path))) return adminRestore(req, env, m[1]);
  if (method === "POST" && (m = /^\/v1\/admin\/users\/([0-9a-f]+)\/ban$/.exec(path))) return adminBan(req, env, m[1]);

  throw new Fail(404, "not_found");
}

export default {
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
