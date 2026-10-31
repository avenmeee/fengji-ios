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

export async function listingPage(env, url, id) {
  const row = await env.DB.prepare("SELECT * FROM listings WHERE id = ? AND status = 'on'").bind(id).first();
  if (!row) return new Response(page("蜂集", "<h1>这条已经没有了</h1>").body, { status: 404, headers: { "content-type": "text/html; charset=utf-8" } });
  const photos = JSON.parse(row.photos).map(k => `${url.origin}/p/${k}`);
  const price = row.price === 0 ? "免费" : "$" + row.price.toLocaleString("en-US") + (row.kind === "rent" ? " /月" : "");
  const head = `<meta property="og:title" content="${esc(row.title)} ${esc(price)}"><meta property="og:description" content="${esc(row.place)}">${photos[0] ? `<meta property="og:image" content="${esc(photos[0])}">` : ""}`;
  const app = env.APPSTORE_URL ? `<a class="btn" href="${esc(env.APPSTORE_URL)}">下载蜂集</a>` : "";
  return page(`${row.title} - 蜂集`, `${photos.map(p => `<img src="${esc(p)}" alt="">`).join("")}
    <h1>${esc(row.title)}</h1><div class="price">${esc(price)}</div>
    <p class="sub">${esc(row.place)}</p>
    ${row.descr ? `<p>${esc(row.descr)}</p>` : ""}
    <p>微信号：<b>${esc(row.contact)}</b></p>
    <p class="sub">同学自办，非学校官方。不经手钱，当面看过再付。</p>${app}`, head);
}

export function privacyPage(env) {
  return page("蜂集隐私政策", `<h1>蜂集隐私政策</h1>
  <p class="sub">蜂集（Fengji）是同学自办的二手和租房信息平台。</p>
  <h2>收集什么</h2>
  <p>只在你发布时才要登录。登录用“通过 Apple 登录”，我们只拿到苹果给的匿名编号，拿不到你的姓名和邮箱。</p>
  <p>你主动发布的内容：照片、标题、价格、地点、备注、微信号。这些内容所有人都能看到，包括没有登录的人和看到分享链接的人。</p>
  <p>屏蔽和举报记录。不登录举报时不记录你是谁。</p>
  <p>发布、浏览、成交的每日总数，只是数字，不关联到个人。</p>
  <h2>不做什么</h2>
  <p>不追踪你，不放广告，不卖数据。照片上传前去掉定位信息。App 不读你的相册，只拿到你选中的照片。</p>
  <h2>存在哪</h2>
  <p>存在 Cloudflare 的服务器上。</p>
  <h2>删除</h2>
  <p>在 App 的“卖东西 → 设置 → 删除账号”可以随时删除账号。你发的内容和照片会马上一起删除。</p>
  <h2>联系</h2>
  <p>${contactLine(env)}</p>
  <h2 lang="en">In English</h2>
  <p lang="en">Fengji only needs sign-in to post, using Sign in with Apple; we receive an anonymous identifier, not your name or email. What you post (photos, text, location, WeChat ID) is public. We keep daily totals of posts, views and sales that are not linked to anyone. We do not track you, show ads or sell data. Delete your account any time in the app (Sell → Settings → Delete account); your posts and photos are deleted immediately. Data is stored on Cloudflare.</p>`);
}

export function supportPage(env) {
  return page("蜂集帮助", `<h1>蜂集帮助</h1>
  <h2>怎么联系卖家</h2><p>详情页复制微信号，去微信加对方。当面看过再付，看房前别转押金。</p>
  <h2>怎么举报</h2><p>详情页右上角“…”→ 举报。24 小时内处理。也可以屏蔽对方。</p>
  <h2>怎么删除账号</h2><p>卖东西 → 右上角设置 → 删除账号。内容和照片一起马上删除。</p>
  <h2>联系我们</h2><p>${contactLine(env)}</p>`);
}
