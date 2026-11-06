// 首页排序（10-31 用户定，11-06 改）：
// 1. 所有在卖的都按 划算系数 × 新鲜度 × 随机系数 排，新帖不单独置前，靠新鲜度自然靠前；没打分的算 1.0；
// 2. 同一个卖家最多连着 2 件，第 3 件往后挪；
// 3. 卖完的（7 天内）放在全部在卖的后面，按卖出时间。
// 分数随时间变，每次刷新换一个种子，所以第一页记下 now 和种子，编进 next，后面几页照用，翻页不错位。
// 搜索不传种子：照旧，不随机，同一层里 6 小时内的在前。
export const FRESH_TOP = 6 * 3600000, HALF_LIFE_HOURS = 60;
export const DEAL = { 4: 1.6, 3: 1.3, 2: 1.0, 1: 0.7 };
// 拿线上 287 条试的（11-06）：新鲜度每 4 天减半、不低于 0.25，随机 0.5～2。模拟结果记在 进度.md
export const SHUFFLE = { halfLifeHours: 96, floor: 0.25, low: 0.5, high: 2 };

// next = (分钟数 × 1000 + 种子) × 10000 + 偏移。老版本 App 只把它当数字传回来，不用改。
// 现在约 3e14，在 2^53 以内。上线时老格式（分钟数 × 10000 + 偏移，约 3e11）的翻页还认，照老算法排。
const NEW_FORMAT = 1e13;
export const SEEDS = 1000;
export const newSeed = () => Math.floor(Math.random() * SEEDS);
export const floorMinute = ms => Math.floor(ms / 60000) * 60000;
export const encodeNext = (nowMs, seed, offset) => seed === null
  ? Math.floor(nowMs / 60000) * 10000 + offset
  : (Math.floor(nowMs / 60000) * SEEDS + seed) * 10000 + offset;
export function decodeNext(n) {
  if (n >= NEW_FORMAT) {
    const head = Math.floor(n / 10000);
    return { now: Math.floor(head / SEEDS) * 60000, seed: head % SEEDS, offset: n % 10000 };
  }
  return n >= 10000 ? { now: Math.floor(n / 10000) * 60000, seed: null, offset: n % 10000 } : { now: null, seed: null, offset: n };
}

export const sellerKey = r => r.source_type === "group" ? "g:" + (r.sender_hash || (r.source_poster || "") + "\u0000" + (r.source_group || "")) : "u:" + r.user_id;

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

// 同一个种子、同一条帖子，永远是同一个 0～1 的数；每条各算各的
export function unit(seed, id) {
  let h = 0x811c9dc5;
  const s = seed + ":" + id;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  h ^= h >>> 16; h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13; h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

export function rankFeed(rows, now, seed = null, shuffle = SHUFFLE) {
  const byNewest = (a, b) => b.bumped_at - a.bumped_at || (a.id < b.id ? 1 : -1);
  const live = rows.filter(r => r.status !== "off"), sold = rows.filter(r => r.status === "off");
  // 有种子（首页）：全部进同一个排序；没种子（搜索）：6 小时内的还是在前
  const fresh = seed === null ? live.filter(r => now - r.bumped_at < FRESH_TOP).sort(byNewest) : [];
  const hours = r => Math.max(0, now - r.bumped_at) / 3600000;
  const score = seed === null
    ? r => (DEAL[r.score] ?? 1.0) * Math.pow(0.5, hours(r) / HALF_LIFE_HOURS)
    : r => (DEAL[r.score] ?? 1.0)
      * Math.max(shuffle.floor, Math.pow(0.5, hours(r) / shuffle.halfLifeHours))
      * (shuffle.low + (shuffle.high - shuffle.low) * unit(seed, r.id));
  const older = live.filter(r => seed !== null || now - r.bumped_at >= FRESH_TOP).map(r => ({ r, s: score(r) }))
    .sort((a, b) => b.s - a.s || (a.r.id < b.r.id ? 1 : -1)).map(x => x.r);
  sold.sort((a, b) => (b.sold_at || 0) - (a.sold_at || 0) || (a.id < b.id ? 1 : -1));
  return [...spreadSellers([...fresh, ...older]), ...sold];
}
