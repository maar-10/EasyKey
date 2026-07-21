--- Server-side session store (PURE — no CC side effects; the clock is injected so it
--- is fully unit-testable). Tracks which pockets are currently "secure" and for how
--- long, one independent session per pocket so many people can be secure at once.
---
--- Sessions are keyed by the pocket's **ecnet2 address** (a public key). v1 keyed by
--- computer id and handed out a random bearer token; both are gone — the encrypted
--- tunnel authenticates the sender's address on every message, so a token would just
--- be one more secret to steal and prove nothing extra.
---@class Sessions
local Sessions = {}
Sessions.__index = Sessions

--- @param opts table { now=function()->ms, sessionSeconds=number }
function Sessions.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Sessions)
    self._now = opts.now or function() return os.epoch("utc") end
    self._sessionSeconds = opts.sessionSeconds or 300
    self._sessions = {} -- address -> { address, expiresAt, label, startedAt }
    return self
end

--- Grant (or refresh) a session for a pocket address. Returns the session table.
--- `label` is the friendly label of the key that matched (for logging).
function Sessions:grant(address, label)
    local now = self._now()
    local s = {
        address   = address,
        startedAt = now,
        expiresAt = now + self._sessionSeconds * 1000,
        label     = label,
    }
    self._sessions[address] = s
    return s
end

--- Live (non-expired) session for an address, or nil.
function Sessions:get(address)
    local s = self._sessions[address]
    if not s then return nil end
    if self._now() >= s.expiresAt then return nil end
    return s
end

--- Is this address currently secure?
function Sessions:isSecure(address)
    return self:get(address) ~= nil
end

--- Seconds remaining for an address's session (0 if none/expired).
function Sessions:remaining(address)
    local s = self:get(address)
    if not s then return 0 end
    return math.max(0, math.floor((s.expiresAt - self._now()) / 1000 + 0.5))
end

--- Explicitly revoke a session (e.g. a pocket was lost). Returns true if removed.
function Sessions:revoke(address)
    if self._sessions[address] then
        self._sessions[address] = nil
        return true
    end
    return false
end

--- Remove all expired sessions. Returns the list of removed addresses.
function Sessions:expireDue()
    local now = self._now()
    local removed = {}
    for addr, s in pairs(self._sessions) do
        if now >= s.expiresAt then
            removed[#removed + 1] = addr
            self._sessions[addr] = nil
        end
    end
    return removed
end

--- Number of live sessions.
function Sessions:count()
    local n = 0
    local now = self._now()
    for _, s in pairs(self._sessions) do
        if now < s.expiresAt then n = n + 1 end
    end
    return n
end

--- Snapshot of live sessions for pushing to control PCs:
--- array of { address, expiresAt } sorted by address (stable ordering).
function Sessions:snapshot()
    local now = self._now()
    local out = {}
    for _, s in pairs(self._sessions) do
        if now < s.expiresAt then
            out[#out + 1] = { address = s.address, expiresAt = s.expiresAt }
        end
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

return Sessions
