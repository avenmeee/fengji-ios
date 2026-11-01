// 网页：分享出去的条目页、隐私政策、支持页（App Store 要后两个网址）。
const esc = v => String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const page = (title, body, head = "") => new Response(`<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>${head}<style>
body{margin:0;background:#fff;color:#1C1C1E;font:16px/1.65 -apple-system,"PingFang SC",system-ui,sans-serif}
main{max-width:560px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:22px;line-height:1.3;margin:12px 0}h2{font-size:17px;margin:22px 0 4px}p{margin:6px 0}
img{width:100%;border-radius:14px;display:block;margin-bottom:8px}
.price{font-size:26px;font-weight:700}.sub{color:#6E6E73;font-size:14px}
.btn{display:block;text-align:center;background:#F5B800;color:#1C1C1E;font-weight:600;border-radius:12px;padding:12px;text-decoration:none;margin-top:16px}
@media (prefers-color-scheme:dark){body{background:#262524;color:#F2EFE9}.sub{color:#AAA7A1}}
</style></head><body><main>${body}</main></body></html>`, { headers: { "content-type": "text/html; charset=utf-8" } });

const contactLine = env => env.CONTACT_EMAIL ? `<a href="mailto:${esc(env.CONTACT_EMAIL)}">${esc(env.CONTACT_EMAIL)}</a>` : "（待公布）";

function daysAgo(t) {
  const d = Math.floor((Date.now() - t) / 86400000);
  return d < 1 ? "今天" : `${d} 天前`;
}

function facts(row) {
  if (row.kind !== "rent") return [row.place, { pickup: "自取", deliver: "可配送", both: "自取或配送" }[row.delivery] || ""].filter(Boolean).join(" · ");
  return [row.place, { whole: "整套", room: "单间", both: "可整套可单间" }[row.unit_type] || "", row.room_type, row.utilities ? "包水电" : "不包水电", row.internet === 1 ? "包网" : row.internet === 2 ? "不包网" : "", row.private_bath === 1 ? "独卫" : row.private_bath === 2 ? "没有独卫" : "", row.furniture ? `家具：${row.furniture}` : "", row.lease_end ? `租约到 ${row.lease_end}` : "", row.deposit != null ? `押金 $${row.deposit}` : "", row.app_fee != null ? `申请费 $${row.app_fee}` : "", row.parking ? `停车：${row.parking}` : "", row.pets ? `宠物：${row.pets}` : "", row.roommates ? `室友：${row.roommates}` : ""].filter(Boolean).join(" · ");
}

export async function listingPage(env, url, id) {
  let row = await env.DB.prepare("SELECT * FROM listings WHERE id = ? AND status IN ('on', 'reserved')").bind(id).first();
  if (!row) return new Response(page("蜂集", "<h1>已下架</h1><p class=\"sub\">这条已经没有了。</p>").body, { status: 404, headers: { "content-type": "text/html; charset=utf-8" } });
  const photos = JSON.parse(row.photos).map(k => `${url.origin}/p/${k}`);
  const price = row.price === 0 ? "免费" : "$" + row.price.toLocaleString("en-US") + (row.kind === "rent" ? " /月" : "");
  const head = `<meta property="og:title" content="${esc(row.title)} ${esc(price)}"><meta property="og:description" content="${esc(row.place)}">${photos[0] ? `<meta property="og:image" content="${esc(photos[0])}">` : ""}`;
  // 装了 App 的点“在蜂集里打开”直接进这条；没装的有商店链接时再给下载
  const app = `<a class="btn" href="fengji://l/${esc(row.id)}">在蜂集里打开</a>` + (env.APPSTORE_URL ? ` <a class="btn" href="${esc(env.APPSTORE_URL)}">下载蜂集</a>` : "");
  return page(`${row.title} - 蜂集`, `${photos.map(p => `<img src="${esc(p)}" alt="">`).join("")}
    <h1>${esc(row.title)}</h1><div class="price">${esc(price)}</div>
    <p class="sub">${esc(facts(row))}</p>
    ${row.descr ? `<p>${esc(row.descr)}</p>` : ""}
    ${row.source_type === "group"
      ? `<p>去 <b>${esc(row.source_group)}</b> 群找 <b>${esc(row.source_poster)}</b></p><p class="sub">${daysAgo(row.source_posted_at)}发在群里。</p>`
      : row.contact ? `<p>微信号：<b>${esc(row.contact)}</b></p>` : `<p>在蜂集里点“想要”留言。</p>`}
    <p class="sub">同学自办，非学校官方。不经手钱，当面看过再付。</p>${app}`, head);
}

export function privacyPage(env) {
  return page("蜂集隐私政策", `<h1>蜂集隐私政策</h1>
  <p class="sub">蜂集（Fengji）是同学自办的二手和租房信息平台。</p>
  <h2>收集什么</h2>
  <p>只在你发布时才要登录。登录用“通过 Apple 登录”，我们只拿到苹果给的匿名编号，拿不到你的姓名和邮箱。</p>
  <p>你主动发布的内容：照片、标题、价格、地点、备注、微信号。这些内容所有人都能看到，包括没有登录的人和看到分享链接的人。</p>
  <p>屏蔽和举报记录。不登录举报时不记录你是谁。</p>
  <p>昵称和头像：默认是“同学 xxx”和蜜蜂头像，由账号编号算出，不是真名。可以改昵称、上传自己的头像照片，所有人都能看到。昵称会经过违禁词过滤；昵称和头像都可以被举报，管理员可以撤掉换回默认。换头像时旧照片删除，删号时一起删除。</p>
  <p>删掉的帖子：对外马上消失，别人看不到。删除后 30 天内可以在“我 → 记录”里恢复，照片和文字都还在；30 天后照片彻底删除，只留一张小缩略图和文字给你本人看。也可以在记录里立即永久删除；删号时全部马上彻底删除。</p>
  <p>成交价：标记已卖时可以选填卖了多少钱。只用于同类比价和汇总，不公开显示。重新上架、删帖或删号时一起删除。</p>
  <p>“想要”留言：你留的一句话和联系方式只有卖家能看到。删帖或删号时一起删除。</p>
  <p>推送：同意通知后，我们保存设备的推送令牌，只用来告诉你有人想要。退出登录或删号时删除。</p>
  <p>部分条目来自微信群，由运营者从群里搬进来，不是发帖人自己在蜂集发的，包括物品信息、群名、群昵称和原图。不公开微信号和电话，房源不写门牌，有人脸、二维码、微信截图、门牌的图不用。原帖人想删除，加我们的微信或发邮件，说一下是哪条，我们 24 小时内删除，照片一起删除。</p>
  <p>发布、浏览、成交的每日总数，只是数字，不关联到个人。</p>
  <p>认领：把 App 给的验证码用自己的微信发出来，核对发送者后，这个人名下的条目一次转到你的账号。我们只存发送者编号的带密钥哈希用来匹配，不存也不显示微信 ID 明文。认领后你填的微信号才会公开。</p>
  <p>AI：放上照片后，照片会发给 AI（Anthropic 的 Claude）自动生成名字、分类和成色，不保存到我们这里，直到你发布。东西的名字、价格、分类、成色、地点和第一张照片（包括来自微信群的条目）也会发给 AI 打分。第一次发布东西前会征得你的同意。微信群的照片在搬进来之前也会发给同一个 AI 筛选。</p>
  <h2>不做什么</h2>
  <p>不追踪你，不放广告，不卖数据。照片上传前去掉定位信息。App 不读你的相册，只拿到你选中的照片。</p>
  <h2>存在哪</h2>
  <p>存在 Cloudflare 的服务器上。</p>
  <h2>删除</h2>
  <p>在 App 的“加号 → 我 → 设置 → 删除账号”可以随时删除账号。你发的内容和照片会马上一起删除。</p>
  <h2>联系</h2>
  <p>${contactLine(env)}</p>
  <h2 lang="en">In English</h2>
  <p lang="en">Fengji only needs sign-in to post, using Sign in with Apple; we receive an anonymous identifier, not your name or email. What you post (photos, text, location, WeChat ID if you add one) is public. A "want" message and the contact you leave are visible only to the seller. If you allow notifications we store a device push token, removed on sign-out or account deletion. We keep daily totals of posts, views and sales that are not linked to anyone. We do not track you, show ads or sell data. Some listings are copied from WeChat groups by the operator, not posted on Fengji by the original posters themselves, including group names, nicknames and original photos; posters can ask us to remove them by WeChat or email and we remove them within 24 hours, or they can claim them. Listing details and the first photo are sent to AI (Anthropic's Claude) to produce a rating; you are asked to agree before posting. Delete your account any time in the app (+ → Me → Settings → Delete account); your posts and photos are deleted immediately. Data is stored on Cloudflare.</p>`);
}

// 点开才显示邮箱：字在页面里，不开 JS 也能点开、能选中；开了 JS 多一个复制按钮
const revealedContact = env => env.CONTACT_EMAIL ? `<details><summary>点这里看邮箱 Show email</summary>
  <p>${contactLine(env)} <button id="copy" hidden>复制</button></p></details>
  <script>const b=document.getElementById("copy");if(navigator.clipboard){b.hidden=false;b.onclick=async()=>{await navigator.clipboard.writeText(${JSON.stringify(env.CONTACT_EMAIL)});b.textContent="已复制"}}</script>` : `<p>${contactLine(env)}</p>`;

export function rulesPage(env) {
  return page("蜂集举报规则", `<h1>蜂集举报规则</h1>
  <h2>可以举报什么</h2><p>违禁物品、色情、暴力、仇恨；诈骗、骚扰；假学历、代写代考、私下换汇；冒充他人、侵犯别人的照片或文字；不当的昵称和头像；虚假信息。</p>
  <h2>怎么举报</h2><p>在东西或房子的详情页，点右上角“…”→ 举报，选原因。再选举报这条帖子、昵称还是头像。想马上不再看到这个人，可以同时屏蔽。“想要”留言在“我”里点“…”举报。</p>
  <h2>多久处理</h2><p>24 小时内处理。违规的内容会下架；不当的昵称会重置，头像会撤掉换回默认；情节严重的停用账号。三个人举报同一条，会先自动下架等处理。</p>
  <h2>申诉</h2><p>觉得处理错了，写邮件说明：</p>${revealedContact(env)}`);
}

export function supportPage(env) {
  return page("蜂集帮助", `<h1>蜂集帮助</h1>
  <h2>怎么联系卖家</h2><p>卖家留了微信号：复制后去微信加对方。没留：点“想要”，写一句话和你的联系方式，只有卖家能看到。当面看过再付，看房前别转押金。</p>
  <h2>怎么举报</h2><p>详情页右上角“…”→ 举报。24 小时内处理。也可以屏蔽对方。</p>
  <h2>群里搬来的帖子想删除</h2><p>如果你是原帖人，加我们的微信或发邮件到下面的地址，说一下是哪条，我们 24 小时内删除。也可以在详情页“…”里点“我是原帖人，想删除”。</p>
  <h2>删掉的帖子还能找回吗</h2><p>删除后 30 天内可以在“我 → 记录”里恢复，之后彻底删除；也可以在记录里立即永久删除。</p>
  <h2>怎么删除账号</h2><p>加号 → 我 → 设置 → 删除账号。内容和照片一起马上删除。</p>
  <h2>联系我们 Contact</h2>${revealedContact(env)}`);
}
