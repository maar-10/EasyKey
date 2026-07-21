--- Control-side output state machine (PURE — clock injected, no CC side effects).
--- Replaces the old door/closeDelay model: an output is no longer "a door that opens",
--- it's a redstone channel with a behaviour.
---
--- Each output is one redstone channel — a side of this computer, a side of a wired
--- redstone relay, or one colour on a bundled cable — and carries its own:
---   * name  : whatever the operator calls it
---   * type  : "off" | "toggle" | "press"
---   * range : how close a secure pocket must be, in blocks
---
--- Behaviour, per output:
---   off    -> never emits. New outputs start here, so a side with something wired to
---             it can't fire until you deliberately arm it.
---   toggle -> ON for exactly as long as a secure pocket is within `range` (a lever).
---   press  -> ONE pulse when a secure pocket ENTERS range (a button). It will not fire
---             again until EVERY secure pocket has left range and someone re-enters.
---             That re-arm rule is the point: a complex door driven by repeated pulses
---             would otherwise be left in a half-open state.
---
--- Locking is absolute: with nobody secure in range, every output is off. There is no
--- path that emits redstone without a live, authenticated, in-range secure session.
---
--- Identity note: `address` is a pocket's ecnet2 address taken from the authenticated
--- `sender` of an encrypted message, and `distance` is measured by the receiving
--- computer — neither is attacker-supplied data. A pocket without a secure session is
--- tracked but can never make anything occupied.
---@class Outputs
local Outputs = {}
Outputs.__index = Outputs

local TYPES = { off = true, toggle = true, press = true }
Outputs.TYPES = { "off", "toggle", "press" }

--- @param opts table {
---   now = function()->ms,
---   defaults = { range = number, stale = number, pressSeconds = number },
--- }
function Outputs.new(opts)
    opts = opts or {}
    local d = opts.defaults or {}
    local self = setmetatable({}, Outputs)
    self._now = opts.now or function() return os.epoch("utc") end
    self._defRange = d.range or 4
    self._stale = d.stale or 2.0
    self._pressSeconds = d.pressSeconds or 0.5

    self._secure = {}   -- address -> expiresAt
    self._presence = {} -- address -> { distance, lastSeen }
    self.outputs = {}   -- id -> { id, name, type, range, meta, on, armed, pulseUntil, occupied }
    self.order = {}     -- ids in discovery order
    return self
end

-- ---------- server state ----------

--- Replace the secure-set pushed by the server.
--- `sessions` is an array of { address, expiresAt }.
function Outputs:setSecureSet(sessions)
    local m = {}
    for _, s in ipairs(sessions or {}) do m[s.address] = s.expiresAt end
    self._secure = m
end

function Outputs:_isSecure(address, now)
    local expiresAt = self._secure[address]
    if not expiresAt then return false end
    return (now or self._now()) < expiresAt
end

--- Handle a presence ping from an AUTHENTICATED address. Distance is recorded even when
--- it's far away — that's how we know someone has LEFT rather than just gone quiet.
--- Returns true if the ping was usable.
function Outputs:onPresence(address, distance, now)
    now = now or self._now()
    if distance == nil then return false end -- cross-dimension: never opens anything
    self._presence[address] = { distance = distance, lastSeen = now }
    return true
end

-- ---------- outputs ----------

--- Register a discovered output. No-op if it already exists, so rediscovery on reboot
--- never clobbers the operator's settings.
--- `meta` describes the hardware: { device = "self"|<relay>, side = , color = <number|nil> }
function Outputs:ensure(id, meta)
    if not self.outputs[id] then
        self.outputs[id] = {
            id = id, name = "", type = "off", range = self._defRange,
            meta = meta or {}, on = false, armed = true, pulseUntil = nil, occupied = false,
        }
        self.order[#self.order + 1] = id
    elseif meta then
        self.outputs[id].meta = meta
    end
    return self.outputs[id]
end

--- Forget an output (e.g. a side switched to bundled mode).
function Outputs:remove(id)
    if not self.outputs[id] then return false end
    self.outputs[id] = nil
    for i, oid in ipairs(self.order) do
        if oid == id then table.remove(self.order, i); break end
    end
    return true
end

--- Apply operator settings. Unknown types are rejected rather than silently stored.
function Outputs:configure(id, cfg)
    local o = self.outputs[id]
    if not o then return false end
    if cfg.name ~= nil then o.name = tostring(cfg.name) end
    if cfg.type ~= nil and TYPES[cfg.type] then
        o.type = cfg.type
        -- changing type must not leave a stale pulse energised
        o.pulseUntil = nil
        o.on = false
    end
    if cfg.range ~= nil then
        local r = tonumber(cfg.range)
        if r and r >= 0 then o.range = r end
    end
    return true
end

--- Step the type: off -> toggle -> press -> off.
function Outputs:cycleType(id)
    local o = self.outputs[id]
    if not o then return nil end
    local next_ = (o.type == "off" and "toggle") or (o.type == "toggle" and "press") or "off"
    self:configure(id, { type = next_ })
    return next_
end

--- Settings to persist: id -> { name, type, range }.
function Outputs:exportConfig()
    local out = {}
    for id, o in pairs(self.outputs) do
        out[id] = { name = o.name, type = o.type, range = o.range }
    end
    return out
end

--- Apply saved settings, ignoring ids that no longer exist.
function Outputs:loadConfig(byId)
    for id, cfg in pairs(byId or {}) do
        if self.outputs[id] then self:configure(id, cfg) end
    end
end

-- ---------- the state machine ----------

--- Is any SECURE pocket within `range` right now? A pocket we haven't heard from within
--- the stale window counts as gone, so a pocket that dies/leaves silently can't hold an
--- output on forever.
function Outputs:occupied(range, now)
    now = now or self._now()
    for address, p in pairs(self._presence) do
        if (now - p.lastSeen) <= self._stale * 1000
            and p.distance <= range
            and self:_isSecure(address, now) then
            return true
        end
    end
    return false
end

--- Recompute every output. Returns the state map (id -> bool) and the list of changes
--- ({ id, name, on }) so the caller can drive redstone only on transitions.
function Outputs:tick(now)
    now = now or self._now()
    local states, changes = {}, {}

    for _, id in ipairs(self.order) do
        local o = self.outputs[id]
        local occupied = (o.type ~= "off") and self:occupied(o.range, now) or false
        local before = o.on

        if not occupied then
            -- Locked: nothing is emitted, and a press re-arms for next time.
            o.on = false
            o.pulseUntil = nil
            o.armed = true
        elseif o.type == "toggle" then
            o.on = true
        elseif o.type == "press" then
            if o.armed then
                -- rising edge: fire exactly one pulse, then stay quiet until they leave
                o.pulseUntil = now + self._pressSeconds * 1000
                o.armed = false
            end
            o.on = (o.pulseUntil ~= nil) and now < o.pulseUntil
            if o.pulseUntil and now >= o.pulseUntil then o.pulseUntil = nil end
        end

        o.occupied = occupied
        states[id] = o.on
        if o.on ~= before then
            changes[#changes + 1] = { id = id, name = o.name, on = o.on }
        end
    end

    return states, changes
end

--- How many secure pockets are currently being heard from (any distance). Dashboard only.
function Outputs:nearbyCount(now)
    now = now or self._now()
    local n = 0
    for address, p in pairs(self._presence) do
        if (now - p.lastSeen) <= self._stale * 1000 and self:_isSecure(address, now) then
            n = n + 1
        end
    end
    return n
end

--- Rows for the UI, in discovery order.
function Outputs:snapshot()
    local out = {}
    for i, id in ipairs(self.order) do
        local o = self.outputs[id]
        out[i] = {
            id = id, name = o.name, type = o.type, range = o.range,
            on = o.on, occupied = o.occupied, meta = o.meta,
        }
    end
    return out
end

return Outputs
