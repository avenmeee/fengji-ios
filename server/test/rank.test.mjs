// 首页排序：每次刷新换一批，规则不破，翻页不错位。不用起服务：node --test test/rank.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeNext, encodeNext, floorMinute, FRESH_TOP, rankFeed, sellerKey, SEEDS, unit } from "../src/rank.js";

const H = 3600000, DAY = 24 * H, NOW = floorMinute(Date.UTC(2026, 10, 6, 12));

// 持续有人发：每天 15 件，共 30 天，20 个卖家；四档比例接近线上
function supply() {
  const rows = [];
  for (let i = 0; i < 450; i++) {
    const age = 7 * H + (i / 450) * 30 * DAY;
    rows.push({ id: "a" + i, user_id: "u" + (i % 20), status: "on", source_type: "self", bumped_at: NOW - age, score: [2, 3, 2, 3, 2, 3, 4, 2, 3, 1][i % 10] });
  }
  return rows;
}
const ids = l => l.map(r => r.id);
const live = l => l.filter(r => r.status !== "off");

test("每次刷新前 20 条明显不同", () => {
  const rows = supply();
  let changed = 0, N = 200;
  for (let s = 0; s < N; s++) {
    const a = new Set(ids(rankFeed(rows, NOW, s).slice(0, 20)));
    changed += ids(rankFeed(rows, NOW, s + 1).slice(0, 20)).filter(id => !a.has(id)).length / 20;
  }
  assert.ok(changed / N >= 0.5, "平均换了 " + (changed / N));
});

test("捡漏和新帖整体仍然更靠前", () => {
  const rows = supply();
  const age = r => NOW - r.bumped_at;
  let top = [];
  for (let s = 0; s < 200; s++) top.push(...rankFeed(rows, NOW, s).slice(0, 20));
  const share = (l, f) => l.filter(f).length / l.length;
  assert.ok(share(top, r => r.score === 4) > 1.5 * share(rows, r => r.score === 4), "捡漏");
  assert.ok(share(top, r => r.score === 1) < share(rows, r => r.score === 1), "偏贵");
  const mean = l => l.reduce((s, r) => s + age(r), 0) / l.length;
  assert.ok(mean(top) < mean(rows), "新的更靠前");
});

test("老帖有机会露面", () => {
  const rows = supply();
  const seen = new Set();
  for (let s = 0; s < 300; s++) for (const r of rankFeed(rows, NOW, s).slice(0, 40)) seen.add(r.id);
  assert.ok([...seen].some(id => NOW - rows.find(r => r.id === id).bumped_at > 20 * DAY));
});

test("新帖不再置前，没打分的不被压到最后，卖完的在最后", () => {
  const rows = supply();
  rows.push({ id: "n1", user_id: "x1", status: "on", source_type: "self", bumped_at: NOW - H, score: 1 });
  rows.push({ id: "n2", user_id: "x2", status: "reserved", source_type: "self", bumped_at: NOW - H, score: null });
  rows.push({ id: "s1", user_id: "x3", status: "off", source_type: "self", bumped_at: NOW - H, sold_at: NOW - H, score: 4 });
  rows.push({ id: "s2", user_id: "x4", status: "off", source_type: "self", bumped_at: NOW - H, sold_at: NOW - 2 * H, score: 4 });
  let firstNew = 0, sumN2 = 0, N = 300;
  for (let s = 0; s < N; s++) {
    const out = rankFeed(rows, NOW, s);
    if (["n1", "n2"].includes(out[0].id)) firstNew++;
    sumN2 += ids(out).indexOf("n2");
    assert.deepEqual(ids(out.slice(-2)), ["s1", "s2"]);
  }
  assert.ok(firstNew < N, "新帖不能每次都在第一");
  assert.ok(sumN2 / N < rows.length / 4, "没打分的新帖平均名次 " + sumN2 / N);
});

test("搜索（不传种子）里 6 小时内的还在前面", () => {
  const rows = supply();
  rows.push({ id: "n1", user_id: "x1", status: "on", source_type: "self", bumped_at: NOW - H, score: 1 });
  assert.equal(rankFeed(rows, NOW)[0].id, "n1");
  assert.ok(rows.some(r => NOW - r.bumped_at >= FRESH_TOP));
});

test("同一卖家最多连 2 件", () => {
  const rows = [];
  for (let i = 0; i < 60; i++) rows.push({ id: "b" + i, user_id: i < 45 ? "big" : "u" + i, status: "on", source_type: "self", bumped_at: NOW - (7 + i) * H, score: 3 });
  for (let s = 0; s < 50; s++) {
    const out = live(rankFeed(rows, NOW, s));
    let tail = out.length;  // 其他人排完后，只剩一个人时才允许连着
    while (tail > 0 && sellerKey(out[tail - 1]) === "u:big") tail--;
    for (let i = 2; i < tail; i++) {
      assert.ok(!(sellerKey(out[i]) === sellerKey(out[i - 1]) && sellerKey(out[i]) === sellerKey(out[i - 2])), `第 ${i} 条`);
    }
  }
});

test("翻页不重复不漏：同一个种子切页和整排一样", () => {
  const rows = supply();
  for (const seed of [0, 7, 999]) {
    const got = [];
    let cursor = 0, now = NOW, s = seed;
    while (true) {
      const page = rankFeed(rows, now, s).slice(cursor, cursor + 40);
      got.push(...ids(page));
      if (cursor + 40 >= rows.length) break;
      const d = decodeNext(encodeNext(now, s, cursor + 40));
      assert.deepEqual([d.now, d.seed, d.offset], [now, s, cursor + 40]);
      cursor = d.offset; now = d.now; s = d.seed;
    }
    assert.equal(got.length, rows.length);
    assert.equal(new Set(got).size, rows.length);
  }
});

test("next 编码：新格式在安全整数内，老格式和纯偏移还认", () => {
  const big = encodeNext(NOW, SEEDS - 1, 9999);
  assert.ok(Number.isSafeInteger(big));
  assert.deepEqual(decodeNext(big), { now: NOW, seed: SEEDS - 1, offset: 9999 });
  const legacy = Math.floor(NOW / 60000) * 10000 + 40;
  assert.deepEqual(decodeNext(legacy), { now: NOW, seed: null, offset: 40 });
  assert.deepEqual(decodeNext(80), { now: null, seed: null, offset: 80 });
  assert.equal(encodeNext(NOW, null, 40), legacy);
});

test("不传种子（搜索）：不随机，和原来一样", () => {
  const rows = supply();
  assert.deepEqual(ids(rankFeed(rows, NOW)), ids(rankFeed(rows, NOW)));
  const score = r => ({ 4: 1.6, 3: 1.3, 2: 1, 1: 0.7 }[r.score]) * Math.pow(0.5, (NOW - r.bumped_at) / H / 60);
  const out = rankFeed(rows.map(r => ({ ...r, user_id: r.id })), NOW);
  for (let i = 1; i < out.length; i++) assert.ok(score(out[i - 1]) >= score(out[i]));
});

test("随机系数：同种子同帖不变，分布均匀", () => {
  assert.equal(unit(5, "abc"), unit(5, "abc"));
  assert.notEqual(unit(5, "abc"), unit(6, "abc"));
  let sum = 0, N = 5000;
  for (let i = 0; i < N; i++) {
    const u = unit(3, "id" + i);
    assert.ok(u >= 0 && u < 1);
    sum += u;
  }
  assert.ok(Math.abs(sum / N - 0.5) < 0.02, String(sum / N));
});
