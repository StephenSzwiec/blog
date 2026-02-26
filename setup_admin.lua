-- setup_admin.lua — one-shot script to set the admin password.
--
-- Run with:  ./redbean.com -i setup_admin.lua
-- (Redbean executes the script in the same Lua environment as the app,
--  so require "db" and the argon2 module are available.)
--
-- Uses argon2id with OWASP Password Storage Cheat Sheet parameters:
--   m_cost = 65536  (64 MiB memory)
--   t_cost = 3      (3 passes)
--   parallelism = 4
--   hash_len = 32

local db = require "db"
db.init()

io.write("Enter new admin password: ")
io.flush()
local password = io.read("*l")

if not password or password:match("^%s*$") then
  io.stderr:write("Error: password cannot be empty.\n")
  os.exit(1)
end

-- Generate a 16-byte random salt.
local salt
local ok_r, bytes = pcall(unix.getrandom, 16)
if ok_r and bytes and #bytes == 16 then
  salt = bytes
else
  local f = io.open("/dev/urandom", "rb")
  if f then
    salt = f:read(16)
    f:close()
  end
end

if not salt or #salt < 16 then
  io.stderr:write("Error: could not generate a random salt.\n")
  os.exit(1)
end

-- Hash with argon2id using OWASP-recommended parameters.
local ok_h, hash = pcall(argon2.hash_encoded, password, salt, {
  variant     = argon2.variants.argon2_id,
  m_cost      = 65536,  -- 64 MiB
  t_cost      = 3,
  parallelism = 4,
  hash_len    = 32,
})

if not ok_h or not hash then
  io.stderr:write("Error: argon2 hashing failed: " .. tostring(hash) .. "\n")
  os.exit(1)
end

db.set_setting("admin_password_hash", hash)
io.write("Admin password set successfully.\n")
