// 对本机 wrangler dev 跑一遍接口（要 .dev.vars 里 DEV_LOGIN=1）：node test/smoke.mjs
import assert from "node:assert/strict";

const BASE = process.env.BASE || "http://127.0.0.1:8799";
const call = async (method, path, { token, body, raw } = {}) => {
  const r = await fetch(BASE + path, {
    method,
    headers: { ...(token ? { authorization: "Bearer " + token } : {}), ...(raw ? { "content-type": "image/jpeg" } : body ? { "content-type": "application/json" } : {}) },
    body: raw || (body ? JSON.stringify(body) : undefined)
  });
  const isJson = (r.headers.get("content-type") || "").includes("json");
  return { status: r.status, data: isJson ? await r.json() : await r.arrayBuffer(), type: r.headers.get("content-type") };
};
const stamp = Date.now().toString(36);
const login = async n => (await call("POST", "/v1/auth/dev", { body: { name: n + stamp } })).data;
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const goods = { kind: "goods", title: "宜家书桌", price: 40, cat: "furn", cond: "几乎全新", place: "学校门口", desc: "九成新", contact: "wx_seller", delivery: "pickup", photos: [] };
const ADMIN = process.env.ADMIN_TOKEN || "dev-admin";
let n = 0;
const ok = (name, cond, extra) => { n++; assert.ok(cond, name + " " + JSON.stringify(extra ?? "")); console.log("ok", name); };

const a = await login("a"), b = await login("b"), c = await login("c"), d = await login("d");

let r = await call("POST", "/v1/listings", { token: a.token, body: goods });
ok("没同意协议不能发", r.status === 403 && r.data.error === "terms_required", r);
r = await call("POST", "/v1/listings", { body: goods });
ok("没登录不能发", r.status === 401, r);
for (const u of [a, b, c, d]) await call("POST", "/v1/me/agree", { token: u.token });

r = await call("POST", "/v1/photos", { token: a.token, raw: new Uint8Array([1, 2, 3, 4]) });
ok("不是 jpeg 拒", r.status === 415, r);
r = await call("POST", "/v1/photos", { token: a.token, raw: jpeg });
ok("传照片", r.status === 201 && r.data.key.startsWith(a.me.id + "/"), r);
const key = r.data.key;
r = await call("GET", "/p/" + key);
ok("照片能取", r.status === 200 && r.type === "image/jpeg" && r.data.byteLength === jpeg.length, r.status);

r = await call("POST", "/v1/listings", { token: a.token, body: goods });
ok("东西要有照片", r.status === 400 && r.data.error === "need_photo", r);
r = await call("POST", "/v1/photos", { token: a.token, raw: jpeg });
const key2 = r.data.key;
r = await call("POST", "/v1/photos", { token: a.token, raw: jpeg });
const key3 = r.data.key;
r = await call("POST", "/v1/listings", { token: b.token, body: { ...goods, photos: [key] } });
ok("不能用别人的照片", r.status === 400 && r.data.error === "bad_photo", r);
r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], title: "代考服务" } });
ok("违禁词拒", r.status === 422, r);
r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], price: 1.5 } });
ok("价格要整数", r.status === 400, r);
for (const word of ["代办成绩单", "学历认证", "毕业证", "换汇 7.2", "人民币换美元"]) {
  r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], title: word } });
  ok("拦下：" + word, r.status === 422, r);
}
r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], delivery: undefined } });
ok("要选自取或配送", r.status === 400, r);

r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key] } });
ok("发布", r.status === 201 && r.data.photos[0].key === key, r);
const id = r.data.id;

r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("宜家"));
ok("游客能搜到", r.data.items.some(x => x.id === id), r.data);
ok("游客能看微信号", r.data.items.find(x => x.id === id).contact === "wx_seller");
r = await call("POST", `/v1/listings/${id}/view`);
ok("记一次浏览", r.status === 200, r);
r = await call("POST", `/v1/listings/${id}/report`, { body: { reason: "其他" } });
ok("匿名能举报", r.status === 200, r);
r = await call("GET", "/l/" + id);
ok("分享页", r.status === 200 && Buffer.from(r.data).toString().includes("宜家书桌"), r.status);
r = await call("GET", "/privacy");
ok("隐私政策页", r.status === 200 && Buffer.from(r.data).toString().includes("隐私"), r.status);
r = await call("GET", "/support");
ok("支持页", r.status === 200, r.status);
r = await call("GET", "/v1/listings?kind=goods&cat=book");
ok("分类过滤", !r.data.items.some(x => x.id === id));
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("%"));
ok("搜 % 不当通配符", !r.data.items.some(x => x.id === id));

r = await call("PUT", "/v1/listings/" + id, { token: b.token, body: goods });
ok("别人不能改", r.status === 403, r);
r = await call("PUT", "/v1/listings/" + id, { token: a.token, body: { ...goods, price: 35, photos: [key2] } });
ok("自己能改", r.status === 200 && r.data.price === 35, r);
r = await call("GET", "/p/" + key);
ok("改掉的照片从存储删了", r.status === 404, r.status);

r = await call("POST", `/v1/listings/${id}/status`, { token: a.token, body: { status: "reserved" } });
ok("已预订", r.data.status === "reserved", r);
r = await call("GET", "/v1/listings?kind=goods");
ok("已预订还在买页", r.data.items.some(x => x.id === id));
r = await call("POST", `/v1/listings/${id}/price`, { token: a.token, body: { price: 30 } });
ok("一步改价", r.status === 200 && r.data.price === 30, r);
r = await call("POST", `/v1/listings/${id}/price`, { token: b.token, body: { price: 1 } });
ok("别人不能改价", r.status === 403, r);
r = await call("POST", `/v1/listings/${id}/status`, { token: a.token, body: { status: "off" } });
ok("标记已卖", r.data.status === "off", r);
r = await call("GET", "/v1/listings?kind=goods");
ok("已卖不在买页", !r.data.items.some(x => x.id === id));
r = await call("GET", "/v1/me/listings", { token: a.token });
ok("我发的里还在", r.data.items.some(x => x.id === id));
await call("POST", `/v1/listings/${id}/status`, { token: a.token, body: { status: "on" } });

r = await call("POST", `/v1/blocks/${a.me.id}`, { token: b.token });
r = await call("GET", "/v1/listings?kind=goods", { token: b.token });
ok("屏蔽后看不到", !r.data.items.some(x => x.id === id));
await call("DELETE", `/v1/blocks/${a.me.id}`, { token: b.token });
r = await call("GET", "/v1/listings?kind=goods", { token: b.token });
ok("解除屏蔽能看到", r.data.items.some(x => x.id === id));

for (const u of [b, c]) await call("POST", `/v1/listings/${id}/report`, { token: u.token, body: { reason: "虚假信息" } });
await call("POST", `/v1/listings/${id}/report`, { token: b.token, body: { reason: "虚假信息" } });
r = await call("GET", "/v1/listings?kind=goods");
ok("同一人重复举报不算，还在架上", r.data.items.some(x => x.id === id));
await call("POST", `/v1/listings/${id}/report`, { token: d.token, body: { reason: "其他" } });
r = await call("GET", "/v1/listings?kind=goods");
ok("三人举报自动下架", !r.data.items.some(x => x.id === id));
r = await call("GET", "/v1/admin/reports", { token: a.token });
ok("普通人进不了管理", r.status === 403, r);

const cPhoto = async () => [(await call("POST", "/v1/photos", { token: c.token, raw: jpeg })).data.key];
const rent = { kind: "rent", title: "一室一厅", price: 800, rtype: "寒假短租", from: "2027-01-01", to: "2027-05-01", leaseEnd: "2027-06-30", utilities: true, privateBath: true, place: "Starland", contact: "wx_rent", photos: [] };
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, from: "2027-06-01" } });
ok("起止日期反了拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, utilities: undefined } });
ok("水电必须选", r.status === 400 && r.data.error === "need_utilities", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, to: "" } });
ok("没结束日期又不是长租拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, to: "", longTerm: true, furnished: true } });
ok("长租", r.status === 201 && r.data.longTerm === true && r.data.furnished === true && r.data.to === null, r);
await call("DELETE", "/v1/listings/" + r.data.id, { token: b.token });
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, price: 0 } });
ok("租金 0 拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: rent });
ok("发房源", r.status === 201 && r.data.rtype === "寒假短租" && r.data.utilities === true && r.data.privateBath === true && r.data.leaseEnd === "2027-06-30", r);
const rid = r.data.id;
r = await call("GET", "/v1/listings?kind=rent&rtype=" + encodeURIComponent("寒假短租"));
ok("房源能筛", r.data.items.some(x => x.id === rid));
r = await call("GET", "/v1/listings?kind=rent&rtype=" + encodeURIComponent("整租"));
ok("房源筛掉别的", !r.data.items.some(x => x.id === rid));
r = await call("POST", `/v1/listings/${rid}/bump`, { token: b.token });
ok("刚发不能擦亮", r.status === 429 && r.data.error === "too_soon", r);
r = await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "厨具一套", cat: "kitchen" } });
const older = r.data.id;
ok("厨具家电分类", r.status === 201 && r.data.cat === "kitchen", r);
r = await call("POST", `/v1/listings/${older}/bump`, { token: a.token });
ok("别人不能擦亮", r.status === 401 || r.status === 403, r);
r = await call("DELETE", "/v1/listings/" + rid, { token: c.token });
ok("别人不能删", r.status === 403, r);
r = await call("DELETE", "/v1/listings/" + rid, { token: b.token });
ok("自己能删", r.status === 200, r);

r = await call("POST", "/v1/photos", { token: d.token, raw: jpeg });
const dKey = r.data.key;
r = await call("POST", "/v1/listings", { token: d.token, body: { ...goods, photos: [dKey] } });
const did = r.data.id;
r = await call("DELETE", "/v1/me", { token: d.token });
ok("删号", r.status === 200, r);
r = await call("GET", "/v1/me", { token: d.token });
ok("删号后令牌失效", r.status === 401, r);
r = await call("GET", "/p/" + dKey);
ok("删号带走照片", r.status === 404, r.status);
r = await call("GET", "/v1/listings?kind=goods");
ok("删号带走条目", !r.data.items.some(x => x.id === did));

// 管理：本机库里把 c 设成管理员
import { execSync } from "node:child_process";
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE users SET is_admin = 1 WHERE id = '${c.me.id}'"`, { stdio: "ignore" });
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET bumped_at = 1000 WHERE id = '${older}'"`, { stdio: "ignore" });
r = await call("GET", "/v1/listings?kind=goods&cat=kitchen");
const beforeBump = r.data.items.find(x => x.id === older).bumpedAt;
r = await call("POST", `/v1/listings/${older}/bump`, { token: c.token });
ok("过了一天能擦亮", r.status === 200 && r.data.bumpedAt > beforeBump, r);
r = await call("POST", `/v1/listings/${older}/bump`, { token: c.token });
ok("擦亮限频", r.status === 429, r);
r = await call("GET", "/v1/me", { token: c.token });
ok("管理员身份", r.data.isAdmin === true, r);
r = await call("GET", "/v1/admin/reports", { token: c.token });
ok("能看举报", r.status === 200 && r.data.items.some(x => x.listing.id === id), r);
r = await call("GET", "/v1/listings/" + id);
ok("下架的游客看不到", r.status === 404, r);
r = await call("GET", "/v1/listings/" + id, { token: a.token });
ok("下架的本人能看", r.status === 200 && r.data.status === "hidden", r);
r = await call("GET", "/v1/admin/stats", { token: c.token });
ok("统计有数", r.data.posts >= 1 && r.data.views >= 1 && r.data.sold >= 1, r);
r = await call("POST", `/v1/admin/listings/${id}/restore`, { token: c.token });
r = await call("GET", "/v1/listings?kind=goods");
ok("恢复后回到买页", r.data.items.some(x => x.id === id));
r = await call("GET", "/v1/admin/reports", { token: c.token });
ok("举报处理完", !r.data.items.some(x => x.listing.id === id));
r = await call("POST", `/v1/admin/users/${a.me.id}/ban`, { token: c.token });
ok("封号", r.status === 200, r);
r = await call("GET", "/v1/me", { token: a.token });
ok("封号后令牌失效", r.status === 401, r);
r = await call("POST", "/v1/auth/dev", { body: { name: "a" + stamp } });
ok("封号后登不回来", r.status === 403 && r.data.error === "banned", r);
r = await call("GET", "/v1/listings?kind=goods");
ok("封号带走条目", !r.data.items.some(x => x.id === id));
// 打分：卖家看不到自己的，买家看到；改价作废
const scored = (await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "打分样品", delivery: "both", deliveryFee: 5, pickupBefore: "2027-01-10" } })).data;
ok("取货字段", scored.delivery === "both" && scored.deliveryFee === 5 && scored.pickupBefore === "2027-01-10", scored);
r = await call("POST", `/v1/admin/listings/${scored.id}/score`, { token: c.token, body: { score: 5 } });
ok("普通登录不能打分", r.status === 403, r);
r = await call("POST", `/v1/admin/listings/${scored.id}/score`, { token: ADMIN, body: { score: 9 } });
ok("分要 1～5", r.status === 400, r);
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
ok("待打分能取", r.data.items.some(x => x.id === scored.id), r);
r = await call("POST", `/v1/admin/listings/${scored.id}/score`, { token: ADMIN, body: { score: 5 } });
ok("打分", r.status === 200, r);
r = await call("GET", "/v1/listings?kind=goods");
ok("买家看到分、排最前", r.data.items[0].id === scored.id && r.data.items[0].score === 5, r.data.items[0]);
r = await call("GET", "/v1/listings/" + scored.id, { token: c.token });
ok("卖家看不到自己的分", r.data.score === null, r);
await call("POST", `/v1/listings/${scored.id}/price`, { token: c.token, body: { price: 3 } });
r = await call("GET", "/v1/listings/" + scored.id);
ok("改价后分作废", r.data.score === null, r);

// 群里搬来
const imp = { sourceId: "test-" + stamp, kind: "goods", title: "搬来的台灯", price: 8, cat: "furn", place: "downtown", group: "二手群 3", poster: "小林" };
r = await call("POST", "/v1/admin/import", { token: c.token, body: imp });
ok("普通登录不能导入", r.status === 403, r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, desc: "微信 abc12345" } });
ok("带微信号拒", r.status === 422 && r.data.error === "has_contact", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, desc: "打 912-555-0123" } });
ok("带电话拒", r.status === 422 && r.data.error === "has_contact", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, kind: "rent", rtype: "单间", place: "123 Abercorn St" } });
ok("房源带门牌拒", r.status === 422 && r.data.error === "has_address", r);
const b64 = Buffer.from(jpeg).toString("base64");
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, photos: [b64] } });
ok("照片没筛过拒", r.status === 400 && r.data.error === "photos_not_checked", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, photos: [b64], photosChecked: true } });
ok("导入", r.status === 201, r);
const gid = r.data.id;
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: imp });
ok("重复去重", r.data.duplicate === true && r.data.id === gid, r);
r = await call("GET", "/v1/listings/" + gid);
ok("详情给群和人，不给微信", r.data.sourceType === "group" && r.data.sourceGroup === "二手群 3" && r.data.sourcePoster === "小林" && r.data.contact === null, r);
const gPhoto = r.data.photos[0].key;
r = await call("GET", "/l/" + gid);
ok("分享页写明未确认", Buffer.from(r.data).toString().includes("未经发布者确认"), r.status);
r = await call("POST", `/v1/listings/${gid}/claim`, { body: { contact: "wx" } });
ok("认领要登录", r.status === 401, r);
r = await call("POST", `/v1/listings/${gid}/claim`, { token: b.token, body: { contact: "wx_b" } });
ok("认领", r.status === 200, r);
r = await call("GET", "/v1/listings/" + gid);
ok("认领确认前不变", r.data.sourceType === "group", r);
r = await call("GET", "/v1/admin/claims", { token: c.token });
const cl = r.data.items.find(x => x.listing.id === gid);
ok("管理员看到认领", !!cl && cl.contact === "wx_b", r);
r = await call("POST", `/v1/admin/claims/${cl.id}/approve`, { token: c.token });
r = await call("GET", "/v1/listings/" + gid, { token: b.token });
ok("确认后归认领人", r.data.mine === true && r.data.contact === "wx_b" && r.data.sourceType === "self", r);
await call("DELETE", "/v1/listings/" + gid, { token: b.token });
const imp2 = { ...imp, sourceId: "test2-" + stamp };
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp2, photos: [b64], photosChecked: true } });
const gid2 = r.data.id;
const gp2 = (await call("GET", "/v1/listings/" + gid2)).data.photos[0].key;
r = await call("POST", `/v1/listings/${gid2}/takedown`);
ok("要求下架不用登录", r.status === 200, r);
r = await call("GET", "/v1/listings/" + gid2);
ok("下架立刻生效", r.status === 404, r);
r = await call("GET", "/p/" + gp2);
ok("下架删照片", r.status === 404, r.status);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: imp2 });
ok("下架的不能再导入", r.data.skipped === "taken_down", r);
r = await call("POST", `/v1/listings/${scored.id}/takedown`);
ok("自己发的不能被要求下架", r.status === 404, r);

console.log(`全部通过：${n} 项`);
