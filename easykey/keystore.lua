--- Persistent store of valid keys for the server — the vault.
---
--- Keys are NEVER stored in the clear. Each entry keeps a random per-key salt and a
--- salted, iterated SHA-256 digest:  H_n(salt .. key). Verification re-derives and
--- compares. So reading the server's disk (or a world backup) does not hand over the
--- keys — it hands over hashes that must be brute-forced, and the salt kills shared
--- rainbow tables across entries.
---
--- Honest limits: an attacker who can read this file is already standing in your base,
--- and short numeric keys are guessable regardless of iteration count. Iterations buy
--- time, not immunity — prefer longer keys. The digest is only computed on the server,
--- once per key entry, so we can afford a healthy iteration count.
---
--- Entry shape:  key-id -> { salt=hex, hash=hex, iters=number, label=string }
--- The map key is an opaque id, not the key itself.
local KVStore = require("shared.ui.kvstore")

local KeyStore = {}
KeyStore.__index = KeyStore

local DEFAULT_ITERS = 4096

--- @param opts table|nil { sha256=table, random=table, iters=number } (injectable for tests)
local function deps(opts)
    opts = opts or {}
    return opts.sha256 or require("ccryptolib.sha256"),
           opts.random or require("ccryptolib.random"),
           opts.iters or DEFAULT_ITERS
end

local function toHex(s)
    return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

--- Salted, iterated digest. Iterating over the previous digest (plus the salt) makes
--- each guess cost `iters` hashes instead of one.
local function derive(sha256, salt, key, iters)
    local h = sha256.digest(salt .. key)
    for _ = 2, iters do h = sha256.digest(salt .. h) end
    return toHex(h)
end

--- Constant-ish time compare, so a wrong key can't be narrowed down by timing.
--- (Lua string == would early-exit; this always walks the whole string.)
local function equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit32.bor(diff, bit32.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

--- Load from `path`, seeding from `seed` (map key -> {label}) if the file is absent,
--- so a fresh server has at least one working key. Seeds are hashed on the way in —
--- the plaintext seed never reaches disk.
--- @param opts table|nil injectable deps (tests)
function KeyStore.load(path, seed, opts)
    local sha256, random, iters = deps(opts)
    local self = setmetatable({}, KeyStore)
    self._kv = KVStore.load(path)
    self._sha256, self._random, self._iters = sha256, random, iters
    self._nextId = 0
    for id in pairs(self._kv:all()) do
        local n = tonumber(tostring(id):match("^k(%d+)$") or 0) or 0
        if n > self._nextId then self._nextId = n end
    end
    if next(self._kv:all()) == nil and seed then
        for k, v in pairs(seed) do
            self:add(k, (v and v.label) or "key")
        end
    end
    return self
end

--- Add (or re-add) a key with an optional label. Returns the entry id.
function KeyStore:add(key, label)
    self._nextId = self._nextId + 1
    local id = "k" .. self._nextId
    local salt = toHex(self._random.random(16))
    self._kv:set(id, {
        salt  = salt,
        hash  = derive(self._sha256, salt, key, self._iters),
        iters = self._iters,
        label = label or "key",
    })
    return id
end

--- Returns the matching entry { label, ... } if `key` is valid, else nil.
--- Every entry is checked (no early exit) so timing doesn't leak which key matched.
function KeyStore:verify(key)
    if type(key) ~= "string" or key == "" then return nil end
    local found = nil
    for _, entry in pairs(self._kv:all()) do
        local candidate = derive(self._sha256, entry.salt, key, entry.iters or self._iters)
        if equals(candidate, entry.hash) then found = entry end
    end
    return found
end

--- Remove a key by its entry id. Returns true if it existed.
function KeyStore:remove(id)
    if self._kv:get(id) ~= nil then
        self._kv:set(id, nil)
        return true
    end
    return false
end

--- Entry ids + labels, for the server dashboard (never exposes hashes).
function KeyStore:list()
    local out = {}
    for id, e in pairs(self._kv:all()) do
        out[#out + 1] = { id = id, label = e.label or "key" }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function KeyStore:count()
    local n = 0
    for _ in pairs(self._kv:all()) do n = n + 1 end
    return n
end

return KeyStore
