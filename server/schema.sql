-- 蜂集数据库。线上：npx wrangler d1 execute fengji --remote --file schema.sql
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  apple_refresh TEXT,            -- 删号时撤销苹果令牌用；没配 Sign in with Apple 密钥时为空
  is_admin INTEGER NOT NULL DEFAULT 0,
  banned INTEGER NOT NULL DEFAULT 0,
  agreed_at INTEGER,             -- 同意用户协议的时间
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
  rtype TEXT,                    -- rent：整租 合租 转租
  from_date TEXT,                -- rent：YYYY-MM-DD
  to_date TEXT,
  place TEXT NOT NULL,
  descr TEXT NOT NULL DEFAULT '',
  contact TEXT NOT NULL,         -- 微信号，只给登录的人看
  photos TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'on',  -- on 在架；off 已卖 / 已租；hidden 被举报下架
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS listings_feed ON listings(kind, status, created_at DESC);
CREATE INDEX IF NOT EXISTS listings_user ON listings(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  listing_id TEXT NOT NULL,
  reporter_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',  -- open / done
  created_at INTEGER NOT NULL,
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
CREATE TABLE IF NOT EXISTS daily_counts (
  day TEXT NOT NULL,
  user_id TEXT NOT NULL,
  what TEXT NOT NULL,            -- post / photo
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, user_id, what)
);
