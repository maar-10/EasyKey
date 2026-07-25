--- Who may drive a panel right now. PURE — clock injected, no CC calls.
---
--- Three questions, one answer, in one place:
---   * has the SERVER approved this PC at all? (an unapproved panel is dead, its own
---     monitor included)
---   * is this pocket in the server's secure-set? (a live, key-verified session)
---   * is it close enough, and have we heard from it recently?
--- `statusFor` folds those into the single value the pocket is told. The pocket never
--- works this out for itself.
---
--- Why this is a module and not just part of easykey/logic/panel.lua: the elevator
--- controller needs exactly this gate and nothing else from Panel (no switches, no
--- ownership, no fallback — a floor call is momentary). Panel keeps its own copy of these
--- rules deliberately: refactoring Panel to use this module would change a file already
--- shipped and verified in-game on the manual role, for no behavioural gain. If Panel is
--- ever revisited, folding it onto this module is the obvious cleanup.
---@class Access
local Access = {}
Access.__index = Access

--- Mirrors Protocol.PANEL_STATUS — the pocket renders these verbatim.
Access.OK           = "ok"
Access.OUT_OF_RANGE = "out_of_range" -- too far from this PC, or gone quiet
Access.DENIED       = "denied"       -- in range, but the server has not cleared it

--- The operator standing at this machine, using the panel on its own monitor.
---
--- No pocket, no session, no distance: this PC is hidden and protected like the server, so
--- anyone who can touch its monitor could pull the redstone out of the wall anyway. It is
--- the failsafe for when a pocket can't be used. What it still respects: this PC must
--- itself be APPROVED by the server, so a panel the operator revoked goes dead here too.
Access.LOCAL = "@local"

--- @param opts table { now = function()->ms, defaults = { range, stale } }
function Access.new(opts)
    opts = opts or {}
    local d = opts.defaults or {}
    local self = setmetatable({}, Access)
    self._now = opts.now or function() return os.epoch("utc") end
    self.range = d.range or 100
    self._stale = d.stale or 2.0
    self._secure = {}      -- address -> expiresAt
    self._presence = {}    -- address -> { distance, lastSeen }
    self._approved = false -- has the SERVER approved this PC?
    return self
end

--- Whether the server has approved this PC.
function Access:setApproved(v) self._approved = v and true or false end
function Access:isApproved() return self._approved end

--- The server's secure-set: `sessions` is an array of { address, expiresAt }.
function Access:setSecureSet(sessions)
    local m = {}
    for _, s in ipairs(sessions or {}) do m[s.address] = s.expiresAt end
    self._secure = m
end

--- Does this address hold a live server-granted session?
function Access:isSecure(address, now)
    -- The local operator's "session" is this PC's own approval by the server.
    if address == Access.LOCAL then return self._approved end
    local expiresAt = self._secure[address]
    if not expiresAt then return false end
    return (now or self._now()) < expiresAt
end

--- Record a presence ping. Accepted from ANY pocket, cleared or not: an uncleared pocket
--- still has to be told "denied" rather than ignored, or a locked pocket next to a panel
--- looks broken instead of locked.
function Access:onPresence(address, distance, now)
    now = now or self._now()
    if distance == nil then return false end -- cross-dimension: not "in range" of anything
    self._presence[address] = { distance = distance, lastSeen = now }
    return true
end

--- Close enough, and heard from recently enough to believe it.
function Access:inRange(address, now)
    -- The operator is standing at the machine: always in range, never goes quiet.
    if address == Access.LOCAL then return true end
    now = now or self._now()
    local p = self._presence[address]
    if not p then return false end
    if (now - p.lastSeen) > self._stale * 1000 then return false end
    return p.distance <= self.range
end

--- The single source of truth a pocket is told about its own access.
function Access:statusFor(address, now)
    now = now or self._now()
    if not self:inRange(address, now) then return Access.OUT_OF_RANGE end
    if not self:isSecure(address, now) then return Access.DENIED end
    return Access.OK
end

--- Everyone the SERVER currently has cleared, whether or not they are near this PC.
--- @return array of { address, remaining } sorted by address
function Access:sessions(now)
    now = now or self._now()
    local out = {}
    for address, expiresAt in pairs(self._secure) do
        if now < expiresAt then
            out[#out + 1] = {
                address = address,
                remaining = math.max(0, math.floor((expiresAt - now) / 1000 + 0.5)),
            }
        end
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

--- Pockets we have heard from lately, nearest first, for the operator's list.
--- @return array of { address, distance, secure, inRange }
function Access:pockets(now)
    now = now or self._now()
    local out = {}
    for address, p in pairs(self._presence) do
        if (now - p.lastSeen) <= self._stale * 1000 then
            out[#out + 1] = {
                address = address, distance = p.distance,
                secure = self:isSecure(address, now),
                inRange = p.distance <= self.range,
            }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

return Access
