-- db.lua — database layer using Fullmoon's makeStorage (lsqlite3 wrapper)
-- The storage handle is opened once via M.init() and reused across all requests.
-- makeStorage handles WAL pragmas and fork-safety automatically.
--
-- NOTE: FTS5 full-text search is intentionally omitted.
-- The redbean.com binary shipped does not include SQLite's FTS5 extension.
-- When a custom APE fatbin with FTS5 is available, replace M.search() with
-- the FTS5 implementation and add the virtual table + triggers back to SCHEMA.
--
-- Tags are stored as a comma-separated string in the `tags` column.
-- Splitting, filtering, and counting are done in Lua at query time.

local fm = require "fm"

local M = {}

-- ── Schema ────────────────────────────────────────────────────────────────
-- Pragmas must come first; makeStorage extracts them for re-application
-- after a fork.  All DDL uses IF NOT EXISTS so init() is idempotent.
local SCHEMA = [[
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS content (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    kind        TEXT    NOT NULL CHECK(kind IN ('blog','wiki','docs')),
    slug        TEXT    NOT NULL,
    title       TEXT    NOT NULL,
    body        TEXT    NOT NULL,
    summary     TEXT    NOT NULL DEFAULT '',
    tags        TEXT    NOT NULL DEFAULT '',
    published   INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(kind, slug)
);

CREATE TABLE IF NOT EXISTS contact_messages (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    name    TEXT    NOT NULL,
    email   TEXT    NOT NULL,
    message TEXT    NOT NULL,
    sent_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT    PRIMARY KEY,
    expires_at INTEGER NOT NULL
);
]]

-- ── Module-level storage handle ───────────────────────────────────────────
local store  -- set by M.init()

-- Convert NONE sentinel → nil (single-row lookups).
local function one(row)
  if row == store.NONE then return nil end
  return row
end

-- Convert NONE sentinel → {} (list queries).
local function many(rows)
  if rows == store.NONE then return {} end
  return rows
end

-- Columns returned by general content queries.
-- file_data is intentionally excluded: blobs are only fetched by get_doc().
local CONTENT_COLS =
  "id, kind, slug, title, body, summary, tags, published, created_at, updated_at, mime_type"

-- ── Initialisation ────────────────────────────────────────────────────────

--- Open blog.db and apply the schema.  Safe to call multiple times.
--- path defaults to "blog.db" in the current working directory.
function M.init(path)
  store = fm.makeStorage(path or "blog.db", SCHEMA)
  -- Migrations: ALTER TABLE ignores duplicate-column errors via pcall.
  pcall(function()
    store:execute("ALTER TABLE content ADD COLUMN tags TEXT NOT NULL DEFAULT ''")
  end)
  pcall(function()
    store:execute("ALTER TABLE content ADD COLUMN file_data BLOB")
  end)
  pcall(function()
    store:execute("ALTER TABLE content ADD COLUMN mime_type TEXT NOT NULL DEFAULT ''")
  end)
end

-- ── Content CRUD ──────────────────────────────────────────────────────────

--- Fetch one row by kind + slug (published or draft).  Returns nil if missing.
--- Does NOT include file_data; use get_doc() for binary blobs.
function M.get_content(kind, slug)
  return one(store:fetchOne(
    "SELECT " .. CONTENT_COLS .. " FROM content WHERE kind=? AND slug=?", kind, slug))
end

--- All rows for a kind, newest first (drafts included).
function M.list_content(kind)
  return many(store:fetchAll(
    "SELECT " .. CONTENT_COLS .. " FROM content WHERE kind=? ORDER BY created_at DESC", kind))
end

--- Published-only rows for a kind, newest first.
function M.list_published(kind)
  return many(store:fetchAll(
    "SELECT " .. CONTENT_COLS .. " FROM content WHERE kind=? AND published=1 ORDER BY created_at DESC",
    kind))
end

--- Fetch a single content row by its primary key.  Returns nil if missing.
--- Does NOT include file_data; use get_doc() for binary blobs.
function M.get_by_id(id)
  return one(store:fetchOne(
    "SELECT " .. CONTENT_COLS .. " FROM content WHERE id=?", id))
end

--- Every row across all kinds (admin dashboard).
function M.list_all()
  return many(store:fetchAll(
    "SELECT " .. CONTENT_COLS .. " FROM content ORDER BY kind, created_at DESC"))
end

--- Most recently updated published rows across all kinds, newest first.
function M.list_recent(n)
  return many(store:fetchAll(
    "SELECT " .. CONTENT_COLS .. " FROM content WHERE published=1 ORDER BY updated_at DESC LIMIT ?", n or 5))
end

--- Fetch a docs entry including its binary blob.  Returns nil if missing.
--- Only call this when you actually need to serve the file.
function M.get_doc(slug)
  return one(store:fetchOne(
    "SELECT id, kind, slug, title, mime_type, file_data, created_at, updated_at"
    .. " FROM content WHERE kind='docs' AND slug=?", slug))
end

--- Insert a new docs entry (binary file).  Returns the new row id.
function M.insert_doc(slug, title, mime_type, file_data, published)
  local id, err = store:execute([[
    INSERT INTO content (kind, slug, title, body, mime_type, file_data, published)
    VALUES ('docs', ?, ?, '', ?, ?, ?)
  ]], slug, title, mime_type or "", file_data or "", published == 1 and 1 or 0)
  assert(id, err)
  return id
end

--- Substring search across title and body using LIKE.
--- Pass kind to restrict to one section, or omit for a global search.
--- Pass tag to restrict to rows whose tags comma-list contains that tag exactly.
--- Returns rows with an `excerpt` column (first 200 chars of body).
--- TODO: replace with FTS5 snippet() once a build with FTS5 is available.
function M.search(q, kind, tag)
  local has_q = q and not q:match("^%s*$")
  if not has_q and not tag then return {} end

  local wheres = {"published=1", "kind!='docs'"}
  local vals   = {}

  if has_q then
    local pattern = "%" .. q:gsub("[%%_]", "%%%1") .. "%"
    wheres[#wheres+1] = "(title LIKE ? OR body LIKE ?)"
    vals[#vals+1] = pattern
    vals[#vals+1] = pattern
  end

  if kind then
    wheres[#wheres+1] = "kind=?"
    vals[#vals+1] = kind
  end

  if tag then
    -- Exact comma-boundary match: `,tag,` inside `,tags_string,`
    wheres[#wheres+1] = "(',' || tags || ',') LIKE ?"
    vals[#vals+1] = "%," .. tag .. ",%"
  end

  local sql = "SELECT id, kind, slug, title, summary, tags, published, created_at,"
    .. " substr(body, 1, 200) AS excerpt"
    .. " FROM content WHERE " .. table.concat(wheres, " AND ")
    .. " ORDER BY created_at DESC"

  return many(store:fetchAll(sql, table.unpack(vals)))
end

--- Return a sorted list of {tag, count} pairs for published content.
--- Pass kind to restrict to one section, or omit for all kinds.
function M.list_tags(kind)
  local rows
  if kind then
    rows = many(store:fetchAll(
      "SELECT tags FROM content WHERE kind=? AND published=1 AND tags!=''", kind))
  else
    rows = many(store:fetchAll(
      "SELECT tags FROM content WHERE published=1 AND tags!=''"))
  end
  local counts = {}
  for _, row in ipairs(rows) do
    for tag in row.tags:gmatch("[^,]+") do
      tag = tag:match("^%s*(.-)%s*$")
      if tag ~= "" then
        counts[tag] = (counts[tag] or 0) + 1
      end
    end
  end
  local list = {}
  for tag, count in pairs(counts) do
    list[#list+1] = { tag=tag, count=count }
  end
  table.sort(list, function(a, b) return a.tag < b.tag end)
  return list
end

--- Insert a new content row.  Returns the new row id.
--- tags is an optional comma-separated string (e.g. "lua,web,programming").
function M.insert_content(kind, slug, title, body, summary, published, tags)
  local id, err = store:execute([[
    INSERT INTO content (kind, slug, title, body, summary, published, tags)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  ]], kind, slug, title, body, summary or "", published == 1 and 1 or 0, tags or "")
  assert(id, err)
  return id
end

--- Update fields on an existing row by id.
--- Accepted field keys: kind, slug, title, body, summary, published, tags, mime_type, file_data.
function M.update_content(id, fields)
  local allowed = { kind=1, slug=1, title=1, body=1, summary=1, published=1, tags=1,
                    mime_type=1, file_data=1 }
  local sets, vals = {}, {}
  for k, v in pairs(fields) do
    if allowed[k] then
      sets[#sets + 1] = k .. "=?"
      vals[#vals + 1] = v
    end
  end
  if #sets == 0 then return end
  sets[#sets + 1] = "updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')"
  vals[#vals + 1] = id
  local ok, err = store:execute(
    "UPDATE content SET " .. table.concat(sets, ", ") .. " WHERE id=?",
    table.unpack(vals))
  assert(ok, err)
end

--- Delete a content row by id.
function M.delete_content(id)
  local ok, err = store:execute("DELETE FROM content WHERE id=?", id)
  assert(ok, err)
end

-- ── Contact messages ──────────────────────────────────────────────────────

--- Persist a contact form submission.  Returns the new row id.
function M.insert_message(name, email, message)
  local id, err = store:execute([[
    INSERT INTO contact_messages (name, email, message) VALUES (?, ?, ?)
  ]], name, email, message)
  assert(id, err)
  return id
end

-- ── Settings ───────────────────────────────────────────────────────────

--- Fetch a setting value by key.  Returns the string value, or nil if missing.
function M.get_setting(key)
  local row = one(store:fetchOne("SELECT value FROM settings WHERE key=?", key))
  return row and row.value or nil
end

--- Insert or update a setting by key.
function M.set_setting(key, value)
  local ok, err = store:execute([[
    INSERT INTO settings(key, value) VALUES(?, ?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value
  ]], key, value)
  assert(ok, err)
end

-- ── Sessions ───────────────────────────────────────────────────────────

--- Persist a new session token with its expiry (unix timestamp).
function M.create_session(token, expires_at)
  local ok, err = store:execute(
    "INSERT INTO sessions(token, expires_at) VALUES(?, ?)", token, expires_at)
  assert(ok, err)
end

--- Fetch a session by token, checking that it has not expired.
--- Returns the row (with .token and .expires_at), or nil.
function M.get_session(token)
  return one(store:fetchOne(
    "SELECT token, expires_at FROM sessions WHERE token=? AND expires_at > ?",
    token, os.time()))
end

--- Remove a session by token (logout).
function M.delete_session(token)
  store:execute("DELETE FROM sessions WHERE token=?", token)
end

--- Remove all expired sessions (housekeeping; cheap to call on each login).
function M.prune_sessions()
  store:execute("DELETE FROM sessions WHERE expires_at <= ?", os.time())
end

return M
