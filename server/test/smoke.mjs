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
const goods = { kind: "goods", title: "宜家书桌", price: 40, cat: "furn", cond: "几乎全新", place: "学校门口", desc: "九成新", contact: "wx_seller", delivery: "pickup", aiConsent: true, photos: [] };
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

r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], aiConsent: undefined } });
ok("第一次发东西要同意 AI", r.status === 400 && r.data.error === "need_ai_consent", r);
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
r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [key], delivery: "x" } });
ok("取货方式要对", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: a.token, body: { kind: "goods", title: "最少字段", price: 5, contact: "wx_seller", aiConsent: true, photos: [key] } });
ok("只要照片、名字、价格、微信号", r.status === 201 && r.data.cat === "other" && r.data.cond === null && r.data.delivery === null && r.data.place === "", r);
await call("DELETE", "/v1/listings/" + r.data.id, { token: a.token });
r = await call("POST", "/v1/photos", { token: a.token, raw: jpeg });
const keyBack = r.data.key;

r = await call("POST", "/v1/listings", { token: a.token, body: { ...goods, photos: [keyBack] } });
ok("发布", r.status === 201 && r.data.photos[0].key === keyBack, r);
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
ok("分享页能在蜂集里打开", Buffer.from(r.data).toString().includes("fengji://l/" + id));
r = await call("GET", "/privacy");
ok("隐私政策页", r.status === 200 && Buffer.from(r.data).toString().includes("隐私"), r.status);
r = await call("GET", "/support");
ok("支持页", r.status === 200, r.status);
r = await call("GET", "/v1/listings?kind=goods&cat=art");
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
ok("已卖的买页里还在，标已卖出", r.data.items.find(x => x.id === id)?.status === "off");
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
const rentPhoto = async () => [(await call("POST", "/v1/photos", { token: b.token, raw: jpeg })).data.key];
const rent = { kind: "rent", title: "一室一厅", price: 800, unitType: "room", from: "2027-01-01", to: "2027-05-01", leaseEnd: "2027-06-30", utilities: true, privateBath: true, place: "Starland", contact: "wx_rent", photos: await rentPhoto() };
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, from: "2027-06-01" } });
ok("起止日期反了拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, utilities: undefined } });
ok("水电必须选", r.status === 400 && r.data.error === "need_utilities", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, to: "" } });
ok("没结束日期又不是长租拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, unitType: "both", place: "都可以样品" } });
ok("整套单间可以都选", r.status === 201 && r.data.unitType === "both", r);
const bothId = r.data.id;
r = await call("GET", "/v1/listings?kind=rent&unit=whole");
ok("都选的在整套里", r.data.items.some(x => x.id === bothId), r);
r = await call("GET", "/v1/listings?kind=rent&unit=room");
ok("都选的在单间里", r.data.items.some(x => x.id === bothId), r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, unitType: undefined } });
ok("整套或单间必选", r.status === 400 && r.data.error === "need_unit", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, photos: [] } });
ok("房源要有照片", r.status === 400 && r.data.error === "need_photo", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, photos: Array(31).fill(rent.photos[0]) } });
ok("房源最多 30 张", r.status === 400 && r.data.error === "too_many_photos", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...goods, photos: Array(31).fill(rent.photos[0]) } });
ok("东西最多 30 张", r.status === 400 && r.data.error === "too_many_photos", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...goods, photos: Array(30).fill(rent.photos[0]) } });
ok("同一件能放 30 张", r.status === 201 && r.data.photos.length === 30, r);
r = await call("PUT", "/v1/listings/" + r.data.id, { token: b.token, body: { ...goods, title: "改过的 30 张", photos: Array(30).fill(rent.photos[0]) } });
ok("30 张也能改", r.status === 200 && r.data.title === "改过的 30 张", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, photos: await rentPhoto(), to: "", longTerm: true, furnished: true } });
ok("长租", r.status === 201 && r.data.longTerm === true && r.data.furnished === true && r.data.to === null, r);
await call("DELETE", "/v1/listings/" + r.data.id, { token: b.token });
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, price: 0 } });
ok("租金 0 拒", r.status === 400, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, desc: "长".repeat(3500), roomType: "2室1卫", unitType: "room", internet: false, furniture: "部分有", deposit: 500, appFee: 30, parking: "路边", pets: "可养猫", roommates: "两位同学" } });
ok("房源详细字段", r.data.roomType === "2室1卫" && r.data.unitType === "room" && r.data.internet === false && r.data.furniture === "部分有" && r.data.deposit === 500 && r.data.appFee === 30 && r.data.parking === "路边" && r.data.pets === "可养猫" && r.data.roommates === "两位同学" && r.data.desc.length === 3500, r.data);
ok("发房源", r.status === 201 && !("rtype" in r.data) && r.data.utilities === true && r.data.privateBath === true && r.data.leaseEnd === "2027-06-30", r);
const rid = r.data.id;
r = await call("GET", "/v1/listings?kind=rent");
ok("房源在列表", r.data.items.some(x => x.id === rid));
r = await call("GET", "/v1/listings?kind=rent&unit=room");
ok("都可的也算单间", r.data.items.some(x => x.id === rid));
r = await call("POST", `/v1/listings/${rid}/bump`, { token: b.token });
ok("刚发不能擦亮", r.status === 429 && r.data.error === "too_soon", r);
r = await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "厨具一套", cat: "kitchen" } });
const older = r.data.id;
ok("厨具分类", r.status === 201 && r.data.cat === "kitchen", r);
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
r = await call("POST", "/v1/admin/scores", { token: c.token, body: [{ id: scored.id, score: 4 }] });
ok("普通登录不能打分", r.status === 403, r);
r = await call("POST", "/v1/admin/scores", { token: ADMIN, body: [{ id: scored.id, score: 4 }, { id: scored.id, score: 9 }] });
ok("分要 1～4，一个不对全不写", r.status === 400, r);
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
const toScore = r.data.items.find(x => x.id === scored.id);
ok("待打分能取，带照片和同类价", !!toScore && toScore.title === "打分样品" && toScore.photo.includes("/p/") && Array.isArray(toScore.comps), toScore);
ok("待打分不带微信", !JSON.stringify(toScore).includes("wx_seller"));
r = await call("POST", "/v1/admin/scores", { token: ADMIN, body: [{ id: scored.id, score: 4 }] });
ok("打分", r.data.updated === 1, r);
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
ok("打过分不再取", !r.data.items.some(x => x.id === scored.id));
r = await call("GET", "/v1/listings?kind=goods");
ok("买家看到分、排最前", r.data.items[0].id === scored.id && r.data.items[0].score === 4, r.data.items[0]);
r = await call("GET", "/v1/listings/" + scored.id, { token: c.token });
ok("卖家看不到自己的分", r.data.score === null, r);
await call("POST", `/v1/listings/${scored.id}/price`, { token: c.token, body: { price: 3 } });
r = await call("GET", "/v1/listings/" + scored.id);
ok("改价后分作废", r.data.score === null, r);
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
ok("改价后重新进待打分", r.data.items.some(x => x.id === scored.id));

// 群里搬来
const imp = { sourceId: "test-" + stamp, kind: "goods", title: "搬来的台灯" + stamp, price: 8, cat: "furn", place: "downtown", group: "二手群 3", poster: "小林", postedAt: Date.now() - 2 * 86400000 };
r = await call("POST", "/v1/admin/import", { token: c.token, body: imp });
ok("普通登录不能导入", r.status === 403, r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, desc: "微信 abc12345" } });
ok("带微信号拒", r.status === 422 && r.data.error === "has_contact", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, desc: "打 912-555-0123" } });
ok("带电话拒", r.status === 422 && r.data.error === "has_contact", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, kind: "rent", place: "123 Abercorn St" } });
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
ok("分享页写去哪个群找", Buffer.from(r.data).toString().includes("群找"), r.status);
await call("POST", `/v1/listings/${gid}/takedown`, { token: ADMIN });
const imp2 = { ...imp, sourceId: "test2-" + stamp, title: "搬来的台灯二" + stamp };
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp2, photos: [b64], photosChecked: true } });
const gid2 = r.data.id;
const gp2 = (await call("GET", "/v1/listings/" + gid2)).data.photos[0].key;
r = await call("POST", `/v1/listings/${gid2}/takedown`);
ok("不登录不能下架群帖", r.status === 401, r);
r = await call("POST", `/v1/listings/${gid2}/takedown`, { token: b.token });
ok("普通人不能下架群帖", r.status === 403, r);
r = await call("POST", `/v1/listings/${gid2}/takedown`, { token: ADMIN });
ok("管理员能下架群帖", r.status === 200, r);
r = await call("GET", "/v1/listings/" + gid2);
ok("下架立刻生效", r.status === 404, r);
r = await call("GET", "/p/" + gp2);
ok("下架删照片", r.status === 404, r.status);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: imp2 });
ok("下架的不能再导入", r.data.skipped === "taken_down", r);
r = await call("POST", `/v1/listings/${scored.id}/takedown`, { token: ADMIN });
ok("自己发的不能被要求下架", r.status === 404, r);

// 超过 10 天
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, sourceId: "old-" + stamp, title: "旧帖", postedAt: Date.now() - 11 * 86400000 } });
ok("超过 10 天不导入", r.status === 422 && r.data.error === "too_old", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, sourceId: "nodate-" + stamp, title: "没时间", postedAt: undefined } });
ok("要发帖时间", r.status === 400, r);

// 一条多件拆开
const poster = "拆分" + stamp;
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { sourceId: "multi-" + stamp, kind: "goods", place: "monty", group: "二手群 1", poster, postedAt: Date.now() - 86400000, cat: "furn", items: [{ title: "小桌子", price: 10 }, { title: "小 椅子！", price: 5, cat: "furn" }, { title: "代考", price: 1 }] } });
ok("一条拆多条", r.data.results.length === 3 && r.data.results[0].id && r.data.results[1].id && r.data.results[2].error === "not_allowed", r);
const [desk, chair] = r.data.results.map(x => x.id);
r = await call("GET", "/v1/listings/" + chair);
ok("拆出来的带发帖时间", r.data.sourcePostedAt > 0 && r.data.price === 5, r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { sourceId: "again-" + stamp, kind: "goods", title: "小椅子", price: 3, cat: "furn", place: "monty", group: "二手群 2", poster, postedAt: Date.now() - 3600000 } });
ok("同人同物合并", r.data.merged === true && r.data.id === chair, r);
r = await call("GET", "/v1/listings/" + chair);
ok("留最新价", r.data.price === 3 && r.data.sourceGroup === "二手群 2", r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { sourceId: "older-" + stamp, kind: "goods", title: "小椅子", price: 99, cat: "furn", place: "monty", group: "二手群 2", poster, postedAt: Date.now() - 5 * 86400000 } });
ok("更旧的不覆盖", r.data.stale === true, r);
r = await call("GET", "/v1/listings/" + chair);
ok("价没变", r.data.price === 3, r);
r = await call("POST", `/v1/listings/${chair}/takedown`, { token: ADMIN });
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { sourceId: "repost-" + stamp, kind: "goods", title: "小椅子", price: 2, cat: "furn", place: "monty", group: "二手群 2", poster, postedAt: Date.now() } });
ok("下架只记这条的编号，同物换编号还能导入", r.status < 300 && r.data.skipped !== "taken_down", r);

// 群帖不再过期：过了 10 天照样在
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { sourceId: "exp-" + stamp, kind: "goods", title: "快过期", price: 7, cat: "furn", place: "monty", group: "二手群 1", poster, postedAt: Date.now() - 86400000, photos: [b64], photosChecked: true } });
const exp = r.data.id;
const expPhoto = (await call("GET", "/v1/listings/" + exp)).data.photos[0].key;
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET source_posted_at = ${Date.now() - 11 * 86400000} WHERE id = '${exp}'"`, { stdio: "ignore" });
r = await call("GET", "/v1/listings?kind=goods&cat=furn");
ok("过 10 天还在列表", r.data.items.some(x => x.id === exp));
r = await call("GET", "/v1/listings/" + exp);
ok("过 10 天详情还在", r.status === 200, r);
r = await call("GET", "/l/" + exp);
ok("过 10 天分享页还在", r.status === 200, r.status);
r = await call("GET", "/l/" + "0".repeat(31) + "1");
ok("没了的分享页写已下架", r.status === 404 && Buffer.from(r.data).toString().includes("已下架"));
await call("GET", "/__scheduled");
await call("GET", "/cdn-cgi/handler/scheduled");
r = await call("GET", "/p/" + expPhoto);
ok("定时任务不再删群帖照片", r.status === 200, r.status);

// 认领：验证码
const owner = await login("owner");
await call("POST", "/v1/me/agree", { token: owner.token });
const sender = { senderId: "wxid_" + stamp };
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, ...sender, sourceId: "own1-" + stamp, title: "认领样品一", poster: "昵称甲", postedAt: Date.now() - 3600000 } });
const own1 = r.data.id;
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, ...sender, sourceId: "own2-" + stamp, title: "认领样品二", poster: "昵称乙", postedAt: Date.now() - 3600000 } });
const own2 = r.data.id;
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, ...sender, sourceId: "own3-" + stamp, title: "认领样品一", poster: "昵称乙", price: 6, postedAt: Date.now() - 1800000 } });
ok("换了昵称也算同一人", r.data.merged === true && r.data.id === own1, r);
r = await call("GET", "/v1/listings/" + own1);
ok("不返回微信 ID", !JSON.stringify(r.data).includes(sender.senderId) && !("senderHash" in r.data) && !("sender_hash" in r.data), r);
r = await call("POST", "/v1/claim/code");
ok("要登录才给验证码", r.status === 401, r);
r = await call("POST", "/v1/claim/code", { token: owner.token });
ok("验证码", r.status === 201 && /^[2-9A-HJKMNP-Z]{6}$/.test(r.data.code), r);
const code = r.data.code;
r = await call("POST", "/v1/claim/code", { token: owner.token });
ok("再取一个码，24 小时有效", r.status === 201 && r.data.code !== code && r.data.expiresAt - Date.now() > 23 * 3600000, r);
r = await call("POST", "/v1/admin/claim/verify", { token: owner.token, body: { ...sender, code } });
ok("普通登录不能核对", r.status === 403, r);
const guesser = { senderId: "guesser_" + stamp };
for (let i = 0; i < 5; i++) {
  r = await call("POST", "/v1/admin/claim/verify", { token: ADMIN, body: { ...guesser, code: "AAAAAA" } });
  ok("猜错" + (i + 1), r.status === 404, r);
}
r = await call("POST", "/v1/admin/claim/verify", { token: ADMIN, body: { ...guesser, code } });
ok("猜多了封一小时，对的也不行", r.status === 429, r);
r = await call("POST", "/v1/admin/claim/verify", { token: ADMIN, body: { ...sender, code: code.toLowerCase() } });
ok("核对通过，一次转走", r.status === 200 && r.data.count === 2, r);
r = await call("POST", "/v1/admin/claim/verify", { token: ADMIN, body: { ...sender, code } });
ok("验证码一次性", r.status === 404, r);
r = await call("GET", "/v1/listings/" + own1, { token: owner.token });
ok("归他，还没公开微信号", r.data.mine === true && r.data.sourceType === "claimed" && r.data.contact === null && r.data.sourceGroup === "二手群 3", r);
r = await call("POST", `/v1/listings/${own2}/price`, { token: owner.token, body: { price: 1 } });
ok("认领后能改价", r.data.price === 1, r);
r = await call("POST", `/v1/listings/${own2}/status`, { token: owner.token, body: { status: "off" } });
ok("认领后能标已售", r.data.status === "off", r);
r = await call("GET", "/v1/listings/" + own1);
const ownPhotos = r.data.photos.map(p => p.key);
r = await call("POST", `/v1/listings/${own1}/takedown`, { token: ADMIN });
ok("认领后的不算群帖，不能这样下架", r.status === 404, r);
r = await call("POST", "/v1/me/contact", { token: b.token, body: { contact: "x" } });
ok("没认领不能设公开微信", r.status === 403, r);
r = await call("POST", "/v1/me/contact", { token: owner.token, body: { contact: "wx_public" } });
r = await call("GET", "/v1/listings/" + own1);
ok("填了才公开", r.data.contact === "wx_public", r);
r = await call("GET", "/v1/me/claim", { token: owner.token });
ok("认领状态", r.data.claimed === true && r.data.count === 2 && r.data.contact === "wx_public", r);
r = await call("POST", "/v1/claim/code", { token: owner.token });
ok("认领过不再发验证码", r.status === 409, r);
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, ...sender, sourceId: "own4-" + stamp, title: "认领后新帖", postedAt: Date.now() } });
const own4 = r.data.id;
r = await call("GET", "/v1/listings/" + own4, { token: owner.token });
ok("认领后的新帖直接进账号", r.data.mine === true && r.data.contact === "wx_public", r);
const other = await login("other");
await call("POST", "/v1/me/agree", { token: other.token });
r = await call("POST", "/v1/claim/code", { token: other.token });
r = await call("POST", "/v1/admin/claim/verify", { token: ADMIN, body: { ...sender, code: r.data.code } });
ok("一个微信不能认领两次", r.status === 409 && r.data.error === "sender_taken", r);
r = await call("DELETE", "/v1/me", { token: owner.token });
r = await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, ...sender, sourceId: "own5-" + stamp, title: "删号后新帖", postedAt: Date.now() } });
ok("删号后不再搬他的", r.data.skipped === "taken_down", r);
r = await call("GET", "/v1/listings/" + own4);
ok("删号带走认领的条目", r.status === 404, r);

// AI 填名字（本机是模拟返回）
r = await call("GET", "/v1/config");
ok("配置报 AI 开着", r.data.aiDescribe === true, r);
const aiUser = await login("ai");
await call("POST", "/v1/me/agree", { token: aiUser.token });
const describe = (token, q = "") => call("POST", "/v1/ai/describe" + q, { token, raw: jpeg });
r = await describe();
ok("AI 要登录", r.status === 401, r);
r = await describe(aiUser.token);
ok("AI 要先同意", r.status === 400 && r.data.error === "need_ai_consent", r);
r = await describe(aiUser.token, "?consent=1");
ok("AI 返回三项，分类成色在范围内", r.status === 200 && r.data.name && r.data.cat === "furn" && r.data.cond === "几乎全新" && r.data.price === 25, r);
r = await describe(aiUser.token);
ok("同意过不用再带", r.status === 200, r);
r = await call("GET", "/v1/admin/ai-cost", { token: ADMIN });
ok("费用有记录", r.data.calls >= 2 && r.data.usd > 0 && r.data.perCallUsd > 0, r);
r = await call("GET", "/v1/me", { token: aiUser.token });
ok("我的信息带本月 AI 还剩几条", r.data.aiLeft === 48, r);
for (let i = 0; i < 48; i++) await describe(aiUser.token);
r = await describe(aiUser.token);
ok("每人每月 50 条，用完 ai_limit", r.status === 429 && r.data.error === "ai_limit", r);
r = await call("GET", "/v1/me", { token: aiUser.token });
ok("用完了剩 0", r.data.aiLeft === 0, r);
r = await call("POST", "/v1/listings", { token: aiUser.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: aiUser.token, raw: jpeg })).data.key], title: "AI 用完照样能发" } });
ok("AI 用完照样能发", r.status === 201, r);
// 多张照片 AI 分组
const ai3 = await login("ai3");
await call("POST", "/v1/me/agree", { token: ai3.token });
const b64jpeg = Buffer.from(jpeg).toString("base64");
const group = (token, n, q = "?consent=1") => call("POST", "/v1/ai/group" + q, { token, body: { photos: Array(n).fill(b64jpeg) } });
r = await group(ai3.token, 5, "");
ok("分组要先同意", r.status === 400 && r.data.error === "need_ai_consent", r);
r = await group(ai3.token, 1);
ok("分组至少两张", r.status === 400 && r.data.error === "bad_count", r);
r = await group(ai3.token, 31);
ok("分组最多 30 张", r.status === 400 && r.data.error === "bad_count", r);
r = await group(ai3.token, 5);
ok("分组返回格式", r.status === 200 && Array.isArray(r.data.items) && r.data.items.length === 3 && r.data.items[0].photos.join() === "0,1" && r.data.items[2].photos.join() === "4" && typeof r.data.items[0].title === "string" && r.data.items[0].cat === "furn", r);
ok("每张只出现一次", r.data.items.flatMap(x => x.photos).sort().join() === "0,1,2,3,4", r);
r = await group(ai3.token, 30);
ok("分组按张数算额度，返回还剩几条", r.status === 200 && r.data.aiLeft === 15, r);
r = await group(ai3.token, 16);
ok("这个月不够了返回 ai_limit", r.status === 429 && r.data.error === "ai_limit", r);

// 批量发布
const bt = await login("bt");
await call("POST", "/v1/me/agree", { token: bt.token });
const btPhoto = async () => [(await call("POST", "/v1/photos", { token: bt.token, raw: jpeg })).data.key];
const btItems = [];
for (let i = 0; i < 3; i++) btItems.push({ ...goods, title: "批量" + i + stamp, price: 10 + i, photos: await btPhoto() });
r = await call("POST", "/v1/listings/batch", { token: bt.token, body: { items: [btItems[0], { ...btItems[1], title: "代考" }, btItems[2]], aiConsent: true } });
ok("违禁词逐件检查，告诉是第几件", r.status === 422 && r.data.error === "not_allowed" && r.data.index === 1, r);
r = await call("GET", "/v1/me/listings", { token: bt.token });
ok("有一件不行就一件都不发", r.data.items.length === 0, r);
r = await call("POST", "/v1/listings/batch", { token: bt.token, body: { items: [btItems[0], { ...btItems[1], photos: btItems[0].photos }], aiConsent: true } });
ok("同一张照片不能用在两件里", r.status === 400 && r.data.index === 1, r);
r = await call("POST", "/v1/listings/batch", { token: bt.token, body: { items: btItems, aiConsent: true } });
ok("批量发布 3 件", r.status === 201 && r.data.items.length === 3 && r.data.items[0].title === "批量0" + stamp, r);
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
ok("批量发的进打分队列", btItems.every(it => JSON.stringify(r.data).includes(it.title)), r.status);
const many = [];
for (let i = 0; i < 28; i++) many.push({ ...goods, title: "多" + i + stamp, price: 5, photos: await btPhoto() });
r = await call("POST", "/v1/listings/batch", { token: bt.token, body: { items: many } });
ok("每天总数有上限（3 + 28 > 30）", r.status === 429 && r.data.error === "daily_limit", r);
r = await call("POST", "/v1/listings/batch", { token: bt.token, body: { items: many.slice(0, 27) } });
ok("刚好到上限能发", r.status === 201 && r.data.items.length === 27, r);

const ai2 = await login("ai2");
await call("POST", "/v1/me/agree", { token: ai2.token });
const day = new Date().toISOString().slice(0, 10);
execSync(`npx wrangler d1 execute fengji --local --command "INSERT INTO daily_counts (day, user_id, what, n) VALUES ('${day}', '*', 'ai_microusd', 99000000) ON CONFLICT (day, user_id, what) DO UPDATE SET n = n + 99000000"`, { stdio: "ignore" });
r = await describe(ai2.token, "?consent=1");
ok("超预算走兜底", r.status === 503 && r.data.error === "ai_budget", r);
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE daily_counts SET n = 0 WHERE day = '${day}' AND user_id = '*' AND what = 'ai_microusd'"`, { stdio: "ignore" });

// 想要：卖家没留微信
const w1 = await login("wantseller"), w2 = await login("wantbuyer"), w3 = await login("wantother");
for (const u of [w1, w2, w3]) await call("POST", "/v1/me/agree", { token: u.token });
const sellerPhoto = (await call("POST", "/v1/photos", { token: w1.token, raw: jpeg })).data.key;
r = await call("POST", "/v1/listings", { token: w1.token, body: { kind: "goods", title: "没留微信", price: 9, aiConsent: true, photos: [sellerPhoto] } });
ok("微信号选填", r.status === 201 && r.data.contact === null, r);
const wl = r.data.id;
r = await call("POST", `/v1/listings/${wl}/want`, { body: { contact: "x" } });
ok("想要要登录", r.status === 401, r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w2.token, body: { message: "还在吗" } });
ok("联系方式必填", r.status === 400 && r.data.error === "need_contact", r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w2.token, body: { message: "代考", contact: "x" } });
ok("留言走违禁词", r.status === 422, r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w1.token, body: { contact: "x" } });
ok("不能想要自己的", r.status === 400, r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w2.token, body: { message: "还在吗", contact: "wx_buyer" } });
ok("发想要", r.status === 201, r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w2.token, body: { contact: "wx_buyer" } });
ok("一天只能发一次", r.status === 429 && r.data.error === "want_again", r);
r = await call("GET", "/v1/me/wants", { token: w1.token });
ok("卖家看到留言和联系方式", r.data.items.length === 1 && r.data.items[0].contact === "wx_buyer" && r.data.items[0].message === "还在吗" && r.data.items[0].title === "没留微信", r);
const wid = r.data.items[0].id;
r = await call("GET", "/v1/me/wants", { token: w2.token });
ok("买家看不到", r.data.items.length === 0, r);
r = await call("DELETE", "/v1/wants/" + wid, { token: w3.token });
ok("别人不能删", r.status === 404, r);
r = await call("GET", "/v1/listings/" + wl);
ok("详情不带买家联系方式", !JSON.stringify(r.data).includes("wx_buyer"), r);
r = await call("POST", `/v1/wants/${wid}/report`, { token: w1.token, body: { reason: "骚扰或诈骗" } });
ok("举报留言", r.status === 200, r);
r = await call("GET", "/v1/admin/reports", { token: c.token });
const wr = r.data.items.find(x => x.note.includes("还在吗"));
ok("管理员看到留言举报和被举报人", !!wr && wr.reportedUser === w2.me.id, r);
r = await call("POST", `/v1/listings/${wl}/want`, { token: w3.token, body: { contact: "wx_three" } });
r = await call("GET", "/v1/me/wants", { token: w1.token });
const w3id = r.data.items[0].id;
r = await call("POST", `/v1/wants/${w3id}/block`, { token: w1.token });
ok("屏蔽留言人", r.status === 200, r);
r = await call("GET", "/v1/me/wants", { token: w1.token });
ok("屏蔽后留言没了", r.data.items.length === 0, r);
execSync(`npx wrangler d1 execute fengji --local --command "DELETE FROM wants WHERE listing_id = '${wl}'"`, { stdio: "ignore" });
r = await call("POST", "/v1/me/device", { token: w1.token, body: { token: "abc" } });
ok("令牌格式要对", r.status === 400, r);
r = await call("POST", "/v1/me/device", { token: w1.token, body: { token: "ab".repeat(32) } });
ok("存设备令牌", r.status === 200, r);
const w4 = await login("wantfour");
await call("POST", "/v1/me/agree", { token: w4.token });
await call("POST", `/v1/listings/${wl}/want`, { token: w4.token, body: { contact: "wx_four" } });
r = await call("DELETE", "/v1/listings/" + wl, { token: w1.token });
r = await call("GET", "/v1/me/wants", { token: w1.token });
ok("删帖带走留言", r.data.items.length === 0, r);

// 点击
const before = (await call("GET", "/v1/admin/stats", { token: c.token })).data;
await call("POST", `/v1/listings/${desk}/click`, { body: { what: "copy" } });
await call("POST", `/v1/listings/${desk}/click`, { body: { what: "group" } });
r = await call("POST", `/v1/listings/${desk}/click`, { body: { what: "other" } });
ok("点击类型要对", r.status === 400, r);
r = await call("GET", "/v1/admin/stats", { token: c.token });
ok("点击只加总数", r.data.copies === before.copies + 1 && r.data.groupClicks === before.groupClicks + 1, r);

// 昵称
r = await call("GET", "/v1/me", { token: b.token });
ok("默认昵称", /^同学 [0-9A-F]{3}$/.test(r.data.name) && r.data.named === false && r.data.color >= 0 && r.data.color <= 5, r);
const fallbackName = r.data.name;
r = await call("PATCH", "/v1/me", { token: b.token, body: { nickname: "代写" } });
ok("昵称过违禁词", r.status === 422 && r.data.error === "bad_name", r);
r = await call("PATCH", "/v1/me", { token: b.token, body: { nickname: "蜂集客服" } });
ok("不能冒充官方", r.status === 422, r);
r = await call("PATCH", "/v1/me", { token: b.token, body: { nickname: "wx 12345678" } });
ok("不能放联系方式", r.status === 422, r);
r = await call("PATCH", "/v1/me", { token: b.token, body: { color: 9 } });
ok("颜色要在范围里", r.status === 400, r);
r = await call("PATCH", "/v1/me", { token: b.token, body: { nickname: "林夏", color: 2 } });
ok("改昵称和颜色", r.data.name === "林夏" && r.data.color === 2 && r.data.named === true, r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent } });
const namedId = r.data.id;
ok("发了条带昵称的", !!namedId, r);
r = await call("GET", `/v1/listings/${namedId}`);
ok("详情显示昵称和颜色", r.data.sellerName === "林夏" && r.data.sellerColor === 2 && r.data.sellerNamed === true, r);
r = await call("GET", "/v1/listings?kind=rent");
ok("列表显示昵称", r.data.items.find(x => x.id === namedId)?.sellerName === "林夏", r);
for (const u of [c, d]) await call("POST", `/v1/listings/${namedId}/report-name`, { token: u.token });
await call("POST", `/v1/listings/${namedId}/report-name`, {});
await call("POST", `/v1/listings/${namedId}/report-name`, {});
r = await call("GET", `/v1/listings/${namedId}`);
ok("举报昵称不下架条目", r.data.status === "on", r);
r = await call("PATCH", "/v1/me", { token: b.token, body: { nickname: "" } });
ok("清空回到默认", r.data.name === fallbackName && r.data.named === false, r);

// 四档和成交价
const soldGoods = (await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "成交样品", price: 50, cat: "art" } })).data;
r = await call("POST", "/v1/admin/scores", { token: ADMIN, body: [{ id: soldGoods.id, score: 5 }] });
ok("不再收 5 档", r.status === 400 && r.data.error === "bad_score", r);
r = await call("POST", `/v1/listings/${soldGoods.id}/status`, { token: c.token, body: { status: "off", soldPrice: -1 } });
ok("成交价要对", r.status === 400, r);
r = await call("POST", `/v1/listings/${soldGoods.id}/status`, { token: c.token, body: { status: "off" } });
ok("不填也能标已卖", r.status === 200 && r.data.status === "off", r);
r = await call("POST", `/v1/listings/${soldGoods.id}/status`, { token: c.token, body: { status: "on" } });
r = await call("POST", `/v1/listings/${soldGoods.id}/status`, { token: c.token, body: { status: "off", soldPrice: 35 } });
ok("填成交价，公开数据里没有", r.status === 200 && !Object.values(r.data).includes(35) && !("soldPrice" in r.data), r);
const artWaiting = (await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "待比价", price: 60, cat: "art" } })).data;
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
const withComps = r.data.items.find(x => x.id === artWaiting.id);
ok("同类比价优先成交价并标明", withComps?.comps[0]?.sold === true && withComps.comps[0].price === 35 && withComps.comps[0].listed === 50, withComps);
r = await call("POST", `/v1/listings/${soldGoods.id}/status`, { token: c.token, body: { status: "on" } });
r = await call("GET", "/v1/admin/unscored", { token: ADMIN });
ok("重新上架成交价作废", !r.data.items.find(x => x.id === artWaiting.id).comps.some(x => x.sold), r);

// 上中下旬
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, from: "2027-11-11", fromPrec: "xun", to: "2028-05-31", toPrec: "xun" } });
ok("起止可以是旬", r.data.fromPrec === "xun" && r.data.toPrec === "xun" && r.data.from === "2027-11-11", r);
r = await call("POST", "/v1/listings", { token: b.token, body: { ...rent, from: "2027-11-11", fromPrec: "xun", to: "", toPrec: "xun", longTerm: true } });
ok("长租没有止的精度", r.data.toPrec === null && r.data.longTerm === true, r);

// 记录：软删除、彻底删除
const keep = (await call("POST", "/v1/listings", { token: c.token, body: { ...goods, photos: await cPhoto(), title: "要删的", price: 33, cat: "art" } })).data;
r = await fetch(`${BASE}/v1/listings/${keep.id}`, { method: "DELETE", headers: { authorization: `Bearer ${c.token}`, "content-type": "image/jpeg" }, body: jpeg });
ok("删除带缩略图", r.status === 200);
r = await call("GET", `/v1/listings/${keep.id}`);
ok("删了别人看不到", r.status === 404, r);
r = await call("GET", "/v1/listings?kind=goods&q=要删的");
ok("删了不在列表", !r.data.items.some(x => x.id === keep.id), r);
r = await call("GET", "/v1/me/listings", { token: c.token });
let rec = r.data.items.find(x => x.id === keep.id);
ok("本人记录里有，带删除时间和一张缩略图", rec?.status === "deleted" && rec.deletedAt > 0 && rec.photos.length === 1, rec);
r = await call("POST", `/v1/listings/${keep.id}/status`, { token: c.token, body: { status: "on" } });
ok("删了的不能直接改状态", r.status === 400 && r.data.error === "deleted", r);
r = await call("DELETE", `/v1/listings/${keep.id}?purge=1`, { token: c.token });
r = await call("GET", "/v1/me/listings", { token: c.token });
ok("彻底删除", !r.data.items.some(x => x.id === keep.id), r);

// 头像
const e = await login("e");
await call("POST", "/v1/me/agree", { token: e.token });
r = await fetch(`${BASE}/v1/me/avatar`, { method: "POST", headers: { authorization: `Bearer ${e.token}`, "content-type": "image/jpeg" }, body: jpeg });
let av = await r.json();
ok("传头像", r.status === 200 && av.avatar?.startsWith("/p/"), av);
r = await fetch(BASE + av.avatar);
ok("头像能取", r.status === 200);
r = await fetch(`${BASE}/v1/me/avatar`, { method: "POST", headers: { authorization: `Bearer ${e.token}`, "content-type": "image/jpeg" }, body: new Uint8Array([1, 2, 3]) });
ok("头像要是 jpeg", r.status === 415);
const dPost = (await call("POST", "/v1/listings", { token: e.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: e.token, raw: jpeg })).data.key], title: "有头像的" } })).data;
r = await call("GET", `/v1/listings/${dPost.id}`);
ok("详情带头像", r.data.sellerAvatar?.includes("/p/"), r);
await call("POST", `/v1/listings/${dPost.id}/report-name`, { token: b.token, body: { what: "avatar" } });
r = await call("GET", "/v1/admin/reports", { token: c.token });
ok("头像能被举报", r.data.items.some(x => x.reason === "头像不当"), r);
r = await call("POST", `/v1/admin/users/${dPost.uid}/remove-avatar`, { token: c.token });
r = await call("GET", `/v1/listings/${dPost.id}`);
ok("管理员撤头像", r.data.sellerAvatar === null, r);
r = await fetch(BASE + av.avatar);
ok("撤掉的头像也删了", r.status === 404);
r = await fetch(BASE + "/rules");
ok("举报规则页", r.status === 200 && (await r.text()).includes("24 小时"));

// 取认领码不能误删留言和推送设备
const g = await login("g");
await call("POST", "/v1/me/agree", { token: g.token });
await call("POST", "/v1/me/device", { token: g.token, body: { token: "ab".repeat(32) } });
r = await call("POST", "/v1/claim/code", { token: g.token });
const devs = execSync(`npx wrangler d1 execute fengji --local --json --command "SELECT COUNT(*) AS n FROM devices WHERE user_id = '${g.me.id}'"`).toString();
ok("取认领码不删设备", /"n":\s*1/.test(devs), devs);

// 定时任务用 ADMIN_TOKEN 处理举报：四种举报都列得出来
const h = await login("h"), k = await login("k");
for (const u of [h, k]) await call("POST", "/v1/me/agree", { token: u.token });
await call("PATCH", "/v1/me", { token: h.token, body: { nickname: "测试昵称" } });
await fetch(`${BASE}/v1/me/avatar`, { method: "POST", headers: { authorization: `Bearer ${h.token}`, "content-type": "image/jpeg" }, body: jpeg });
const hPost = (await call("POST", "/v1/listings", { token: h.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: h.token, raw: jpeg })).data.key], title: "被举报的" } })).data;
await call("POST", `/v1/listings/${hPost.id}/want`, { token: k.token, body: { message: "留言原文", contact: "wx_k" } });
const hWant = (await call("GET", "/v1/me/wants", { token: h.token })).data.items[0];
await call("POST", `/v1/wants/${hWant.id}/report`, { token: h.token, body: { reason: "骚扰或诈骗" } });
await call("POST", `/v1/listings/${hPost.id}/report-name`, { token: k.token });
await call("POST", `/v1/listings/${hPost.id}/report-name`, { token: k.token, body: { what: "avatar" } });
await call("POST", `/v1/listings/${hPost.id}/report`, { token: k.token, body: { reason: "虚假信息" } });
r = await call("GET", "/v1/admin/reports", { token: ADMIN });
const mine = r.data.items.filter(x => x.listingId === hPost.id);
const byType = t => mine.find(x => x.type === t);
ok("ADMIN_TOKEN 能看举报", r.status === 200, r);
ok("帖子举报带帖子和被举报人", byType("listing")?.listing?.id === hPost.id && byType("listing").reportedUser === h.me.id, mine);
ok("留言举报带原文和留言人", byType("want")?.content === "留言原文" && byType("want").reportedUser === k.me.id, mine);
ok("昵称举报带昵称", byType("name")?.content === "测试昵称" && byType("name").current === "测试昵称" && byType("name").reportedUser === h.me.id, mine);
ok("头像举报带网址", byType("avatar")?.content?.includes("/p/" + h.me.id + "/") && byType("avatar").reportedUser === h.me.id, mine);
r = await call("POST", `/v1/admin/reports/${byType("want").id}/close`, { token: ADMIN });
ok("ADMIN_TOKEN 关举报", r.status === 200, r);
r = await call("POST", `/v1/admin/users/${h.me.id}/reset-name`, { token: ADMIN });
ok("ADMIN_TOKEN 重置昵称", r.status === 200, r);
r = await call("POST", `/v1/admin/users/${h.me.id}/remove-avatar`, { token: ADMIN });
ok("ADMIN_TOKEN 撤头像", r.status === 200, r);
r = await call("POST", `/v1/admin/listings/${hPost.id}/restore`, { token: ADMIN });
ok("ADMIN_TOKEN 恢复", r.status === 200, r);
r = await call("POST", `/v1/admin/users/${c.me.id}/ban`, { token: ADMIN });
ok("不能封管理员", r.status === 400 && r.data.error === "is_admin", r);
r = await call("POST", `/v1/admin/users/${c.me.id}/ban`, { token: c.token });
ok("不能封自己", r.status === 400, r);
r = await call("POST", `/v1/admin/listings/${hPost.id}/remove`, { token: h.token });
ok("普通人不能下架", r.status === 403, r);
await call("POST", `/v1/listings/${hPost.id}/report`, { token: k.token, body: { reason: "其他" } });
r = await call("POST", `/v1/admin/listings/${hPost.id}/remove`, { token: ADMIN });
ok("ADMIN_TOKEN 下架", r.status === 200, r);
r = await call("GET", "/v1/listings/" + hPost.id, { token: h.token });
ok("下架后本人也看不到", r.status === 404, r);
r = await call("GET", "/v1/admin/reports", { token: ADMIN });
ok("下架后举报清掉", !r.data.items.some(x => x.listingId === hPost.id), r);
r = await call("POST", `/v1/admin/users/${k.me.id}/ban`, { token: ADMIN });
ok("ADMIN_TOKEN 封号", r.status === 200, r);
r = await call("GET", "/v1/me", { token: k.token });
ok("封后令牌失效", r.status === 401, r);
r = await call("POST", `/v1/admin/users/${k.me.id}/ban`, { token: "wrong" });
ok("错的令牌不行", r.status === 401 || r.status === 403, r);

// 卖家主页
const s1 = await login("s1"), s2 = await login("s2");
for (const u of [s1, s2]) await call("POST", "/v1/me/agree", { token: u.token });
await call("PATCH", "/v1/me", { token: s1.token, body: { nickname: "主页卖家" } });
const sPhoto = async () => [(await call("POST", "/v1/photos", { token: s1.token, raw: jpeg })).data.key];
const sOn = (await call("POST", "/v1/listings", { token: s1.token, body: { ...goods, photos: await sPhoto(), title: "在卖的" } })).data;
const sSold = (await call("POST", "/v1/listings", { token: s1.token, body: { ...goods, photos: await sPhoto(), title: "卖掉的" } })).data;
await call("POST", `/v1/listings/${sSold.id}/status`, { token: s1.token, body: { status: "off" } });
const sGone = (await call("POST", "/v1/listings", { token: s1.token, body: { ...goods, photos: await sPhoto(), title: "删掉的" } })).data;
await call("DELETE", `/v1/listings/${sGone.id}`, { token: s1.token });
r = await call("GET", `/v1/users/${s1.me.id}/listings`);
ok("主页有在卖的和卖完的，卖完的在后", r.status === 200 && r.data.items.length === 2 && r.data.items[0].id === sOn.id && r.data.items[1].id === sSold.id, r);
ok("主页带昵称和头像信息", r.data.seller.name === "主页卖家" && r.data.seller.named === true && r.data.seller.group === false, r);
ok("主页不带删掉的", !JSON.stringify(r.data).includes("删掉的"), r);
r = await call("GET", `/v1/listings/${sOn.id}/poster`);
ok("从帖子找到卖家主页", r.status === 200 && r.data.seller.id === s1.me.id && r.data.items.length === 2, r);
await call("POST", `/v1/blocks/${s1.me.id}`, { token: s2.token });
r = await call("GET", `/v1/users/${s1.me.id}/listings`, { token: s2.token });
ok("屏蔽了打不开", r.status === 404, r);
r = await call("GET", "/v1/users/" + "0".repeat(32) + "/listings");
ok("群帖的占位账号没有主页", r.status === 404, r);
r = await call("GET", `/v1/users/${k.me.id}/listings`);
ok("封了的打不开", r.status === 404, r);
const gp = { kind: "goods", cat: "furn", place: "monty", group: "主页群", poster: "群友甲", postedAt: Date.now() - 3600000 };
const g1 = (await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...gp, sourceId: "pg1-" + stamp, title: "群帖一", price: 5 } })).data;
const g2 = (await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...gp, sourceId: "pg2-" + stamp, title: "群帖二", price: 6 } })).data;
await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...gp, poster: "群友乙", sourceId: "pg3-" + stamp, title: "别人的群帖", price: 7 } });
r = await call("GET", `/v1/listings/${g1.id}/poster`);
ok("群帖主页按群昵称加群找", r.status === 200 && r.data.seller.group === true && r.data.seller.name === "群友甲" && r.data.seller.groupName === "主页群" && r.data.items.length === 2 && r.data.items.some(x => x.id === g2.id), r);
ok("群帖主页不露 sender_hash", !JSON.stringify(r.data).includes("sender"), r);

// 卖完了：列表照样显示 7 天，排在后面，别人看不到微信号；卖家主页也有，放最后
const sv = await login("sv");
await call("POST", "/v1/me/agree", { token: sv.token });
const svPhoto = async () => [(await call("POST", "/v1/photos", { token: sv.token, raw: jpeg })).data.key];
const svOn = (await call("POST", "/v1/listings", { token: sv.token, body: { ...goods, photos: await svPhoto(), title: "还在卖" + stamp } })).data;
const svOff = (await call("POST", "/v1/listings", { token: sv.token, body: { ...goods, photos: await svPhoto(), title: "卖完了" + stamp } })).data;
r = await call("POST", `/v1/listings/${svOff.id}/status`, { token: sv.token, body: { status: "off", soldPrice: 30 } });
ok("标卖完了带卖出时间", r.status === 200 && r.data.status === "off" && r.data.soldAt > 0, r);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent(stamp));
const svIds = r.data.items.map(x => x.id);
ok("卖完的还在列表里，排在在卖的后面", svIds.includes(svOff.id) && svIds.indexOf(svOff.id) > svIds.indexOf(svOn.id), svIds);
ok("卖完的别人看不到微信号", r.data.items.find(x => x.id === svOff.id).contact === null, r);
r = await call("GET", `/v1/users/${sv.me.id}/listings`);
ok("卖家主页有卖完的，放最后", r.data.items.length === 2 && r.data.items[1].id === svOff.id, r);
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET sold_at = 1000 WHERE id = '${svOff.id}'"`, { stdio: "ignore" });
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent(stamp));
ok("卖出 7 天后列表里没了", !r.data.items.some(x => x.id === svOff.id), r);
r = await call("POST", `/v1/listings/${svOff.id}/status`, { token: sv.token, body: { status: "on" } });
ok("重新上架清掉卖出时间", r.data.status === "on" && r.data.soldAt === null, r);

// 检查员那一批
const q1 = await login("q1"), q2 = await login("q2"), q3 = await login("q3"), q4 = await login("q4");
for (const u of [q1, q2, q3, q4]) await call("POST", "/v1/me/agree", { token: u.token });
const qPhoto = async () => [(await call("POST", "/v1/photos", { token: q1.token, raw: jpeg })).data.key];
r = await call("POST", "/v1/listings", { token: q1.token, body: { ...goods, photos: await qPhoto(), contact: "示例，无联系方式" } });
ok("微信号要像微信号", r.status === 422 && r.data.error === "bad_wechat", r);
r = await call("POST", "/v1/listings", { token: q1.token, body: { ...goods, photos: await qPhoto(), contact: "" } });
ok("微信号可以不填", r.status === 201, r);
const qp = (await call("POST", "/v1/listings", { token: q1.token, body: { ...goods, photos: await qPhoto(), title: "会被举报的" } })).data;
await call("POST", `/v1/listings/${qp.id}/status`, { token: q1.token, body: { status: "reserved" } });
for (const u of [q2, q3, q4]) await call("POST", `/v1/listings/${qp.id}/report`, { token: u.token, body: { reason: "虚假信息" } });
r = await call("GET", "/v1/listings/" + qp.id, { token: q1.token });
ok("已预订的也会被自动隐藏", r.data.status === "hidden", r);
for (let i = 0; i < 6; i++) await call("POST", `/v1/listings/${qp.id}/report`, { body: { reason: "其他" } });
r = await call("GET", "/v1/admin/reports", { token: ADMIN });
const qr = r.data.items.filter(x => x.listingId === qp.id);
ok("管理列表按条目合并，匿名最多 3 条", qr.length === 1 && qr[0].count === 6, qr);
await call("DELETE", `/v1/listings/${qp.id}`, { token: q1.token });
r = await call("GET", "/v1/me/listings", { token: q1.token });
ok("被隐藏的删掉后不进记录", !r.data.items.some(x => x.id === qp.id), r);
r = await call("GET", "/v1/admin/reports", { token: ADMIN });
ok("被隐藏的删掉后举报还在", r.data.items.some(x => x.listingId === qp.id), r);
r = await call("GET", "/v1/me", { token: q1.token });
ok("同意过 AI 跟着账号", r.data.aiConsent === true, r);
await call("POST", "/v1/me/device", { token: q1.token, body: { token: "cd".repeat(32) } });
await call("POST", "/v1/me/device", { token: q1.token, body: { token: "ef".repeat(32) } });
r = await call("POST", "/v1/auth/logout", { token: q1.token, body: { deviceToken: "cd".repeat(32) } });
const qdev = execSync(`npx wrangler d1 execute fengji --local --json --command "SELECT COUNT(*) AS n FROM devices WHERE user_id = '${q1.me.id}'"`).toString();
ok("退出登录只删本机的令牌", /"n":\s*1/.test(qdev), qdev);
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE users SET banned = 1 WHERE id = '${q2.me.id}'"`, { stdio: "ignore" });
r = await call("DELETE", "/v1/me", { token: q2.token });
ok("被封的也能自己删号", r.status === 200, r);

// 首页排序
const o1 = await login("o1"), o2 = await login("o2");
for (const u of [o1, o2]) await call("POST", "/v1/me/agree", { token: u.token });
const oPost = async (u, title) => (await call("POST", "/v1/listings", { token: u.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: u.token, raw: jpeg })).data.key], title: title + stamp } })).data;
const oa = [];
for (let i = 0; i < 4; i++) oa.push(await oPost(o1, "排序甲" + i));
const ob = await oPost(o2, "排序乙");
const oOld = await oPost(o2, "排序旧");
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET bumped_at = ${Date.now() - 3 * 86400000}, score = 4 WHERE id = '${oOld.id}'"`, { stdio: "ignore" });
await call("POST", `/v1/listings/${oa[0].id}/status`, { token: o1.token, body: { status: "off" } });
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("排序"));
const oIds = r.data.items.map(x => x.id), oUids = r.data.items.map(x => x.uid);
ok("新帖在旧帖前面", oIds.indexOf(ob.id) < oIds.indexOf(oOld.id) && oIds.indexOf(oa[3].id) < oIds.indexOf(oOld.id), oIds);
ok("同一卖家不超过 2 件连着", !oUids.some((u, i) => i >= 2 && u === oUids[i - 1] && u === oUids[i - 2] && r.data.items[i].status !== "off"), oUids);
ok("卖完的在最后", oIds[oIds.length - 1] === oa[0].id, oIds);
const pages = [];
let off = null;
for (let i = 0; i < 50; i++) {
  r = await call("GET", "/v1/listings?kind=goods&n=5" + (off !== null ? "&offset=" + off : ""));
  pages.push(...r.data.items.map(x => x.id));
  off = r.data.next;
  if (off === null) break;
}
r = await call("GET", "/v1/listings?kind=goods");
const all = [];
off = null;
for (let i = 0; i < 50; i++) {
  r = await call("GET", "/v1/listings?kind=goods" + (off !== null ? "&offset=" + off : ""));
  all.push(...r.data.items.map(x => x.id));
  off = r.data.next;
  if (off === null) break;
}
ok("翻页不重复不漏", pages.length === new Set(pages).size && pages.length === all.length && pages.every(id => all.includes(id)), { pages: pages.length, all: all.length });

// 原帖人申请删除：进举报列表，不自动隐藏
const ownerAsk = (await call("POST", "/v1/admin/import", { token: ADMIN, body: { ...imp, sourceId: "ask-" + stamp, title: "原帖人要删的" + stamp } })).data;
for (const u of [o1, o2, s1]) await call("POST", `/v1/listings/${ownerAsk.id}/report`, { token: u.token, body: { reason: "原帖人申请删除" } });
r = await call("GET", "/v1/listings/" + ownerAsk.id);
ok("原帖人申请删除不自动隐藏", r.status === 200 && r.data.status === "on", r);
r = await call("GET", "/v1/admin/reports", { token: ADMIN });
ok("原帖人申请删除进举报列表", r.data.items.some(x => x.listingId === ownerAsk.id && x.reasons.includes("原帖人申请删除")), r);

// 违禁词补的：电子烟拦，烟雾报警器不拦
r = await call("POST", "/v1/listings", { token: o2.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: o2.token, raw: jpeg })).data.key], title: "电子烟" } });
ok("电子烟拦下", r.status === 422 && r.data.error === "not_allowed", r);
r = await call("POST", "/v1/listings", { token: o2.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: o2.token, raw: jpeg })).data.key], title: "烟雾报警器" } });
ok("烟雾报警器不误伤", r.status === 201, r);
r = await call("POST", "/v1/listings", { token: o2.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: o2.token, raw: jpeg })).data.key], title: "Juul pods" } });
ok("英文 juul 拦下", r.status === 422, r);

// 删掉的 30 天内一步重新上架
const rl = await login("rl");
await call("POST", "/v1/me/agree", { token: rl.token });
const rlKey = (await call("POST", "/v1/photos", { token: rl.token, raw: jpeg })).data.key;
const rlPost = (await call("POST", "/v1/listings", { token: rl.token, body: { ...goods, photos: [rlKey], title: "删了再发" } })).data;
await fetch(`${BASE}/v1/listings/${rlPost.id}`, { method: "DELETE", headers: { authorization: `Bearer ${rl.token}`, "content-type": "image/jpeg" }, body: jpeg });
r = await fetch(BASE + "/p/" + rlKey);
ok("删了旧照片网址马上失效", r.status === 404);
r = await call("GET", "/v1/me/listings", { token: rl.token });
const rlRec = r.data.items.find(x => x.id === rlPost.id);
ok("记录里照片还在，另有小图", rlRec.status === "deleted" && rlRec.photos.length === 1 && rlRec.photos[0].key !== rlKey && !!rlRec.thumb, rlRec);
r = await call("GET", "/v1/listings/" + rlPost.id);
ok("删了别人看不到", r.status === 404, r);
r = await call("PUT", "/v1/listings/" + rlPost.id, { token: rl.token, body: { ...goods, title: "删了再发", photos: rlRec.photos.map(p => p.key) } });
ok("不带 relist 不能改删掉的", r.status === 400, r);
r = await call("PUT", "/v1/listings/" + rlPost.id, { token: rl.token, body: { ...goods, title: "删了再发", photos: rlRec.photos.map(p => p.key), relist: true } });
ok("一步重新上架", r.status === 200 && r.data.status === "on" && r.data.photos.length === 1, r);
r = await fetch(BASE + "/p/" + rlRec.photos[0].key);
ok("重新上架后照片能看", r.status === 200);
await fetch(`${BASE}/v1/listings/${rlPost.id}`, { method: "DELETE", headers: { authorization: `Bearer ${rl.token}` } });
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET deleted_at = 1000 WHERE id = '${rlPost.id}'"`, { stdio: "ignore" });
await call("GET", "/cdn-cgi/handler/scheduled");
r = await call("GET", "/v1/me/listings", { token: rl.token });
ok("30 天后照片清掉", r.data.items.find(x => x.id === rlPost.id).photos.length === 0, r);

// 方便的时间
r = await call("POST", "/v1/listings", { token: o2.token, body: { ...goods, photos: [(await call("POST", "/v1/photos", { token: o2.token, raw: jpeg })).data.key], title: "台灯带时间", availTime: "工作日晚上" } });
ok("方便的时间存得上", r.status === 201, r);
r = await call("GET", "/v1/listings/" + r.data.id);
ok("方便的时间读得到", r.data.availTime === "工作日晚上", r);

// 屏蔽名单带昵称
await call("POST", `/v1/blocks/${s1.me.id}`, { token: o1.token });
r = await call("GET", "/v1/me/blocks", { token: o1.token });
ok("屏蔽名单带昵称和颜色", r.data.items.some(x => x.id === s1.me.id && x.name === "主页卖家" && Number.isInteger(x.color)), r);

// 搜索：词尾、同义词、英文、AI 标签
const sr = await login("搜索");
await call("POST", "/v1/me/agree", { token: sr.token });
const srKey = async () => (await call("POST", "/v1/photos", { token: sr.token, raw: jpeg })).data.key;
const srPost = async (title, extra = {}) => (await call("POST", "/v1/listings", { token: sr.token, body: { ...goods, title, desc: "", photos: [await srKey()], ...extra } })).data;
const srRuler = await srPost("钢尺" + stamp);
const srIpad = await srPost("iPad 九成新" + stamp, { cat: "elec" });
const srLaptop = await srPost("Dell laptop " + stamp, { cat: "elec" });
const srChair = await srPost("办公椅子" + stamp);
const ids = items => (items || []).map(x => x.id);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("尺子"));
ok("“尺子”能搜到“尺”", ids(r.data.items).includes(srRuler.id), r.data);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("电脑"));
ok("“电脑”能搜到 iPad 和 laptop", ids(r.data.items).includes(srIpad.id) && ids(r.data.items).includes(srLaptop.id), r.data);
r = await call("GET", "/v1/listings?kind=goods&q=chair");
ok("“chair”能搜到椅子", ids(r.data.items).includes(srChair.id), r.data);
r = await call("GET", "/v1/listings?kind=goods&q=LAPTOPS");
ok("英文不分大小写、单复数都算", ids(r.data.items).includes(srLaptop.id), r.data);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("i pad"));
ok("去掉空格再搜", ids(r.data.items).includes(srIpad.id), r.data);
const srSet = await srPost("直尺套装" + stamp);
const srEnglish = await srPost("metal ruler " + stamp);
const srFridge = await srPost("小冰箱" + stamp);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("尺子") + "&debug=1", { token: ADMIN });
const order = ids(r.data.items), tierAt = id => r.data.items.find(x => x.id === id)?.tier;
ok("名字直接有的排在同义词前面", order.indexOf(srSet.id) >= 0 && order.indexOf(srEnglish.id) > order.indexOf(srSet.id) && tierAt(srSet.id) === 1 && tierAt(srEnglish.id) === 2, r.data.items.map(x => [x.title, x.tier]));
ok("完全不沾边的不给", !order.includes(srFridge.id), r.data.items.map(x => [x.title, x.tier]));
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("尺子") + "&debug=1");
ok("不是管理员看不到层", r.data.items.every(x => x.tier === undefined), r.data.items[0]);
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("直尺套") + "&debug=1", { token: ADMIN });
ok("语义相近的算第三层", r.data.items.some(x => x.tier === 3) || r.data.items.every(x => x.tier <= 2), r.data.items.map(x => [x.title, x.tier, x.sim]));
r = await call("GET", "/v1/listings?kind=goods&q=" + encodeURIComponent("尺子") + "&cat=furn");
ok("同义词照样受分类筛选", !ids(r.data.items).includes(srIpad.id), r.data);
const tagOf = id => JSON.parse(execSync(`npx wrangler d1 execute fengji --local --json --command "SELECT tags FROM listings WHERE id = '${id}'"`).toString())[0].results[0].tags;
ok("发帖后在后台写了搜索标签", (tagOf(srRuler.id) || "").includes("mock"), tagOf(srRuler.id));
r = await call("GET", "/v1/listings?kind=goods&q=mock");
ok("搜索标签也能搜到", ids(r.data.items).includes(srRuler.id), r.data);
await call("PUT", "/v1/listings/" + srRuler.id, { token: sr.token, body: { ...goods, title: "不锈钢尺" + stamp, desc: "", photos: srRuler.photos.map(p => p.key) } });
ok("改了名字标签重做", (tagOf(srRuler.id) || "").includes("不锈钢尺"), tagOf(srRuler.id));
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE listings SET tags = NULL WHERE id = '${srChair.id}'"`, { stdio: "ignore" });
r = await call("POST", "/v1/admin/tags/backfill?n=50", {});
ok("补标签要管理员", r.status === 401 || r.status === 403, r);
r = await call("POST", "/v1/admin/tags/backfill?n=50", { token: ADMIN });
ok("补标签接口能补", r.status === 200 && r.data.done >= 1 && (tagOf(srChair.id) || "").includes("mock"), r.data);
const embOf = id => JSON.parse(execSync(`npx wrangler d1 execute fengji --local --json --command "SELECT length(embedding) AS n FROM listings WHERE id = '${id}'"`).toString())[0].results[0].n;
ok("向量存进去了", embOf(srChair.id) === 256, embOf(srChair.id));

// 匿名使用记录
const ev = (install, events, token) => call("POST", "/v1/events", { token, body: { install, events } });
const inst = "a1b2c3d4-e5f6-4a7b-8c9d-0123456789ab", inst2 = "b1b2c3d4-e5f6-4a7b-8c9d-0123456789ab";
const lid = "abcdef0123456789abcdef0123456789";
r = await ev("不是编号", [{ name: "app_open" }]);
ok("安装编号格式不对拒", r.status === 400 && r.data.error === "bad_install", r);
r = await ev(inst, Array(51).fill({ name: "app_open" }));
ok("一批最多 50 条", r.status === 400 && r.data.error === "bad_count", r);
r = await call("POST", "/v1/events", { raw: new TextEncoder().encode("{oops") });
ok("不是 JSON 拒", r.status === 400, r);
r = await ev(inst, [{ name: "没有这种事件" }, { name: "detail_view" }, { name: "contact", listing: lid, method: "偷看" }, { name: "post_abandon", step: "乱写" }, "字符串"]);
ok("不认识的事件和缺字段的都丢", r.status === 200 && r.data.kept === 0, r);
r = await ev(inst, [
  { name: "app_open", evil: "x".repeat(1000) },
  { name: "detail_view", listing: lid, kind: "goods", cat: "furn", tier: 3, seconds: 9999 },
  { name: "detail_view", listing: lid, kind: "goods", cat: "furn", tier: 3, seconds: 20 },
  { name: "detail_view", listing: lid, kind: "goods", cat: "elec", tier: 1, seconds: 40 },
  { name: "contact", listing: lid, kind: "goods", cat: "furn", tier: 3, method: "copy_wechat" },
  { name: "search", q: "书桌 wx_seller123 13912345678 me@example.com", results: 5 },
  { name: "search", q: "书桌", results: 5 },
  { name: "search", q: "没有的东西", results: 0 },
  { name: "search", q: "wx_seller123", results: 0 },
  { name: "search", q: "长".repeat(100), results: 1 },
  { name: "post_start", kind: "goods" },
  { name: "post_abandon", kind: "goods", step: "price" },
  { name: "post_start", kind: "goods" },
  { name: "post_done", kind: "goods", mode: "batch", count: 4 },
  { name: "ai_result", aiName: "书桌", nameEdited: true, aiPrice: 40, priceEdited: true, priceDiff: -10 },
  { name: "ai_result", aiName: "台灯", nameEdited: false, aiPrice: 15, priceEdited: false, priceDiff: 0 }
]);
ok("不用登录也能记，只记有效的", r.status === 200 && r.data.kept === 15, r);
await ev(inst2, [{ name: "detail_view", listing: lid, kind: "rent", tier: 3, seconds: 10 }]);
r = await call("GET", "/v1/admin/event-stats", {});
ok("统计要管理员", r.status === 401 || r.status === 403, r);
r = await call("GET", "/v1/admin/event-stats?days=30", { token: ADMIN });
const st = r.data;
ok("联系率按设备算", st.contactRate.viewers === 2 && st.contactRate.contacted === 1 && st.contactRate.rate === 0.5, st.contactRate);
ok("联系率按类别", st.contactRate.byCat.find(x => x.key === "furn").rate === 1 && st.contactRate.byCat.find(x => x.key === "rent").rate === 0, st.contactRate);
ok("联系率按蜜蜂分档", st.contactRate.byTier.find(x => x.key === 3).viewers === 2 && st.contactRate.byTier.find(x => x.key === 3).contacted === 1, st.contactRate);
ok("搜索词去掉微信号、电话、邮箱", st.searches.top[0].q === "书桌" && st.searches.top[0].n === 2 && !JSON.stringify(st.searches).match(/seller|139|example/), st.searches);
ok("搜索词封顶 40", st.searches.top.some(x => x.q.length === 40), st.searches);
ok("零结果词单独排", st.searches.zero.length === 1 && st.searches.zero[0].q === "没有的东西", st.searches);
ok("停留封顶 600，取中位数", st.staySeconds.find(x => x.key === "furn").medianSeconds === 310, st.staySeconds);
ok("发布漏斗", st.funnel.start === 2 && st.funnel.abandon === 1 && st.funnel.done === 1 && st.funnel.items === 4 && st.funnel.abandonSteps[0].step === "price", st.funnel);
ok("AI 修改比例", st.ai.total === 2 && st.ai.nameEditedRate === 0.5 && st.ai.priceEditedRate === 0.5, st.ai);
ok("每条帖子的联系数", st.contactsByListing[0].listing === lid && st.contactsByListing[0].method === "copy_wechat", st.contactsByListing);
ok("回访算得出", st.retention.day2.devices === 0, st.retention);
ok("举报数和处理时长", typeof st.reports.total === "number" && st.reports.total > 0 && st.reports.medianHandleHours !== undefined, st.reports);
ok("卖出和首次联系时长有字段", "firstContactHours" in st.timing && "soldHours" in st.timing, st.timing);
for (let i = 0; i < 9; i++) await ev(inst, Array(50).fill({ name: "app_open" }));
r = await ev(inst, Array(50).fill({ name: "app_open" }));
ok("每台设备每天有上限", r.status === 429 && r.data.error === "daily_limit", r);
execSync(`npx wrangler d1 execute fengji --local --command "UPDATE events SET at = ${Date.now() - 91 * 86400000} WHERE install = '${inst2}'"`, { stdio: "ignore" });
await call("GET", "/__scheduled");
const left = execSync(`npx wrangler d1 execute fengji --local --json --command "SELECT (SELECT COUNT(*) FROM events WHERE install = '${inst2}') AS raw, (SELECT COALESCE(SUM(n), 0) FROM event_daily WHERE metric = 'detail_view') AS kept"`).toString();
ok("过了 90 天原始事件删掉，只留汇总", JSON.parse(left)[0].results[0].raw === 0 && JSON.parse(left)[0].results[0].kept === 1, left);

console.log(`全部通过：${n} 项`);
