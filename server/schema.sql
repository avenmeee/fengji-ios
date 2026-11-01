-- 蜂集数据库。线上：npx wrangler d1 execute fengji --remote --file schema.sql
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  apple_refresh TEXT,            -- 删号时撤销苹果令牌用；没配 Sign in with Apple 密钥时为空
  is_admin INTEGER NOT NULL DEFAULT 0,
  banned INTEGER NOT NULL DEFAULT 0,
  agreed_at INTEGER,             -- 同意用户协议的时间
  ai_consent_at INTEGER,         -- 同意把东西的信息发给 AI 打分的时间
  sender_hash TEXT,              -- 认领后：他在微信群里的发送者哈希
  contact TEXT,                  -- 认领后：他愿意公开的微信号
  nickname TEXT,                 -- 没改过是空，显示“同学 xxx”
  avatar_color INTEGER,
  avatar_key TEXT,               -- 自己传的头像，R2 里的键；没传是空          -- 0～5，没选过是空，按账号 id 算
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS listings (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,            -- goods / rent
  title TEXT NOT NULL,
  price INTEGER NOT NULL,        -- 美元，goods 填 0 是免费送；rent 是每月租金
  cat TEXT,                      -- goods：furn elec art book wear other
  cond TEXT,                     -- goods：成色
  rtype TEXT,                    -- 不再使用：租房不分类型
  from_date TEXT,                -- rent：YYYY-MM-DD
  to_date TEXT,
  lease_end TEXT,                -- rent：租约到期日
  utilities INTEGER NOT NULL DEFAULT 0,     -- rent：包水电
  private_bath INTEGER NOT NULL DEFAULT 0,  -- rent：0 没填，1 独卫，2 没有
  delivery TEXT,                 -- goods：pickup 自取；deliver 可配送；both 都可
  delivery_fee INTEGER,          -- goods：配送费，选填
  pickup_before TEXT,            -- goods：几号前取走，选填
  pickup_after TEXT,             -- goods：几号后可取，选填
  long_term INTEGER NOT NULL DEFAULT 0,     -- rent：长租，没有结束日期
  room_type TEXT,                -- rent：房型，比如 2室1卫
  unit_type TEXT,                -- rent：whole 整套；room 单间；both 都可
  internet INTEGER NOT NULL DEFAULT 0,      -- rent：0 没填，1 包网，2 不包
  furniture TEXT,                -- rent：有、部分有、没有
  deposit INTEGER,               -- rent：押金
  app_fee INTEGER,               -- rent：申请费
  parking TEXT,                  -- rent：停车
  pets TEXT,                     -- rent：宠物
  roommates TEXT,                -- rent：室友情况
  furnished INTEGER NOT NULL DEFAULT 0,     -- rent：可拎包入住
  score INTEGER,                 -- 四档：1 偏贵 2 价格合理 3 有性价比 4 捡漏，后台打；没打是空。卖家看不到自己的
  scored_at INTEGER,
  from_prec TEXT,                -- 起的精度：空是具体日期，xun 是上中下旬（存该旬第一天）
  to_prec TEXT,                  -- 止的精度：xun 时存该旬最后一天
  sold_price INTEGER,
  deleted_at INTEGER,            -- 卖家删了：对外消失，只留一张小缩略图和文字给本人看记录            -- 卖家选填的成交价，只用于比价和汇总，不公开
  source_type TEXT NOT NULL DEFAULT 'self', -- self 自己发；group 群里搬来
  source_id TEXT,                -- 群里搬来的去重编号
  tags TEXT,                     -- AI 写的搜索词，空格隔开、两头带空格；空是还没做
  source_group TEXT,             -- 去哪个群找
  source_poster TEXT,            -- 找谁（群昵称）
  source_posted_at INTEGER,      -- 发在群里的时间，超过 10 天隐藏
  merge_key TEXT,                -- 同一人同一物品合并用
  sender_hash TEXT,              -- 发送者的带密钥哈希，只用来匹配，不存不显示明文
  sold_at INTEGER,
  thumb TEXT,
  avail_time TEXT,               -- 方便的时间：取货或看房                    -- 删掉后留给本人记录的小图               -- 标记卖完的时间；列表里只留 7 天
  place TEXT NOT NULL,
  descr TEXT NOT NULL DEFAULT '',
  contact TEXT NOT NULL,         -- 微信号，只给登录的人看
  photos TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'on',  -- on 在售；reserved 已预订；off 已卖 / 已租；hidden 被举报下架
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  bumped_at INTEGER NOT NULL DEFAULT 0      -- 擦亮时间，列表按它排
);
CREATE INDEX IF NOT EXISTS listings_feed ON listings(kind, status, bumped_at DESC);
CREATE INDEX IF NOT EXISTS listings_user ON listings(user_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS listings_source ON listings(source_id) WHERE source_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS listings_sender ON listings(sender_hash) WHERE sender_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS listings_merge ON listings(merge_key) WHERE merge_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  listing_id TEXT NOT NULL,
  reporter_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  reported_user TEXT,            -- 举报想要留言时是留言人；举报条目时为空
  status TEXT NOT NULL DEFAULT 'open',  -- open / done
  created_at INTEGER NOT NULL,
  done_at INTEGER,               -- 处理的时间，算处理时长
  UNIQUE (listing_id, reporter_id)
);
CREATE INDEX IF NOT EXISTS reports_open ON reports(status, created_at DESC);

CREATE TABLE IF NOT EXISTS blocks (
  user_id TEXT NOT NULL,
  blocked_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, blocked_id)
);

-- 发布和传照片的每日计数，防刷爆存储账单。user_id 用 '*' 记全站总数。
-- 匿名使用记录：只有本机随机的安装编号，不跟账号挂。留 90 天
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  install TEXT NOT NULL,
  name TEXT NOT NULL,
  at INTEGER NOT NULL,
  listing TEXT,
  kind TEXT,
  cat TEXT,
  tier INTEGER,
  seconds INTEGER,
  q TEXT,
  results INTEGER,
  method TEXT,
  step TEXT,
  mode TEXT,
  count INTEGER,
  ai_name TEXT,
  name_edited INTEGER,
  ai_price INTEGER,
  price_edited INTEGER,
  price_diff INTEGER
);
CREATE INDEX IF NOT EXISTS events_name ON events(name, at);
CREATE INDEX IF NOT EXISTS events_listing ON events(listing, name);
CREATE INDEX IF NOT EXISTS events_at ON events(at);

-- 过了 90 天只留每天的汇总
CREATE TABLE IF NOT EXISTS event_daily (
  day TEXT NOT NULL,
  metric TEXT NOT NULL,
  dim TEXT NOT NULL,
  n INTEGER NOT NULL,
  devices INTEGER NOT NULL,
  PRIMARY KEY (day, metric, dim)
);

CREATE TABLE IF NOT EXISTS daily_counts (
  day TEXT NOT NULL,
  user_id TEXT NOT NULL,
  what TEXT NOT NULL,            -- post / photo
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, user_id, what)
);

-- 群里搬来的条目被要求下架后留下编号和合并键（key: 开头），防止再次导入
CREATE TABLE IF NOT EXISTS import_tombstones (
  source_id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);

-- 认领验证码：只存哈希，一次性，15 分钟过期
CREATE TABLE IF NOT EXISTS claim_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS claim_codes_user ON claim_codes(user_id);

-- 猜验证码的失败次数，按发送者和小时算；sender_hash 为 '*' 是全站
CREATE TABLE IF NOT EXISTS claim_attempts (
  sender_hash TEXT NOT NULL,
  hour INTEGER NOT NULL,
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (sender_hash, hour)
);
CREATE UNIQUE INDEX IF NOT EXISTS users_sender ON users(sender_hash) WHERE sender_hash IS NOT NULL;

-- AI 建议价的参考表：群数据汇总的中位价和高低价。内容不进仓库，单独导入。
CREATE TABLE IF NOT EXISTS price_refs (
  item TEXT NOT NULL,
  cat TEXT NOT NULL DEFAULT '',
  n INTEGER,
  median INTEGER,
  low INTEGER,
  high INTEGER,
  PRIMARY KEY (item, cat)
);

-- “想要”留言：只有卖家能看到买家的联系方式
CREATE TABLE IF NOT EXISTS wants (
  id TEXT PRIMARY KEY,
  listing_id TEXT NOT NULL,
  seller_id TEXT NOT NULL,
  buyer_id TEXT NOT NULL,
  message TEXT NOT NULL DEFAULT '',
  contact TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS wants_seller ON wants(seller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS wants_buyer ON wants(buyer_id, listing_id, created_at DESC);

-- 推送的设备令牌，退出登录和删号时删
CREATE TABLE IF NOT EXISTS devices (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
