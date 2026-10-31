// 审核版的群帖样子：假群名、假昵称、自己的图，标题写“示例”。群帖过 10 天会隐藏并清掉，提审前再跑一次续期。
// node tools/seed-group-example.mjs
import { execSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const token = fs.readFileSync("server/.admin-token", "utf8").trim();
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fengji-"));
const head = path.join(dir, "h.txt"), bodyFile = path.join(dir, "b.json");
fs.writeFileSync(head, `authorization: Bearer ${token}\ncontent-type: application/json\n`);
fs.writeFileSync(bodyFile, JSON.stringify({
  sourceId: "example-group-" + Date.now(),
  kind: "goods",
  title: "示例：落地灯（群帖样子）",
  price: 15,
  cat: "furn",
  place: "示例地点",
  desc: "这是示例帖，不是真实商品，群名和昵称都是假的。",
  group: "示例群",
  poster: "示例昵称",
  postedAt: Date.now(),
  photos: [fs.readFileSync("视觉/素材/lamp.jpg").toString("base64")],
  photosChecked: true
}));
try {
  console.log(execSync(`curl -s -m 40 --doh-url https://1.1.1.1/dns-query -H @"${head}" --data-binary @"${bodyFile}" https://fengji.sinantrails.com/v1/admin/import`, { encoding: "utf8" }));
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
