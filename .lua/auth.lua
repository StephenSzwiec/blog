-- auth.lua — password-based session authentication using argon2id.
--
-- Sessions are stored in the `sessions` SQLite table so they survive
-- Redbean's per-request fork model (each request gets a fresh process,
-- so in-memory tables cannot be shared between requests).
--
-- The admin password hash is stored in the `settings` table under the
-- key "admin_password_hash".  Use setup_admin.lua to set it.
--
-- Public API (names kept compatible with the old mTLS module so callsites
-- in app.lua need no changes):
--   auth.has_client_cert()     → bool  (true when a valid session exists)
--   auth.require_client_cert() → nil if authorised; " " (space) + 302 otherwise
--   auth.login(password)       → token, nil  |  nil, error_string
--   auth.logout(token)         → (removes session from DB)

local db = require "db"

local M = {}

local SESSION_TTL = 7 * 24 * 3600  -- 7 days in seconds

-- ── Utilities ─────────────────────────────────────────────────────────

local function to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Generate a cryptographically random 64-char hex token (32 bytes).
local function random_token()
  local ok, bytes = pcall(unix.getrandom, 32)
  if ok and bytes and #bytes == 32 then return to_hex(bytes) end
  local f = io.open("/dev/urandom", "rb")
  if f then
    local b = f:read(32); f:close()
    if b and #b == 32 then return to_hex(b) end
  end
  -- Last resort (not cryptographically strong)
  math.randomseed(os.time())
  local parts = {}
  for i = 1, 8 do parts[i] = string.format("%08x", math.random(0, 0x7fffffff)) end
  return table.concat(parts)
end

-- Returns the raw token if the current request carries a live DB session.
local function current_token()
  local tok = GetCookie("session")
  if not tok or tok == "" then return nil end
  local row = db.get_session(tok)
  return row and tok or nil
end

-- ── Public API ────────────────────────────────────────────────────────

--- Returns true when the current request has a valid admin session.
function M.has_client_cert()
  return current_token() ~= nil
end

--- Enforce a valid admin session.
--- Returns nil when authorised.
--- When the session is missing, sets 302 headers and returns a non-empty
--- body (" ") so that Fullmoon calls Write(), which flushes SetHeader/
--- SetStatus to the socket.  (Returning "" skips Write and the headers
--- are never sent.)
function M.require_client_cert()
  if current_token() then return nil end
  SetStatus(302)
  SetHeader("Location", "/login")
  return " "
end

--- Verify a password and, if correct, create a DB-backed session.
--- Returns: token (string), nil        on success.
---          nil,            error_msg  on failure.
function M.login(password)
  if not password or password == "" then
    return nil, "Password is required."
  end

  local hash = db.get_setting("admin_password_hash")
  if not hash or hash == "" then
    return nil, "Admin account not configured. Run setup_admin.lua first."
  end

  local ok, result = pcall(function()
    return argon2.verify(hash, password)
  end)
  if not ok then
    Log(kLogWarn, "argon2.verify error: " .. tostring(result))
    return nil, "Internal error during authentication."
  end
  if not result then
    return nil, "Incorrect password."
  end

  -- Clean up stale sessions before creating a new one.
  pcall(db.prune_sessions)

  local tok = random_token()
  db.create_session(tok, os.time() + SESSION_TTL)
  return tok, nil
end

--- Invalidate a session (logout).
function M.logout(token)
  if token then pcall(db.delete_session, token) end
end

return M
