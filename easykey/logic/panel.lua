--- The manual control PC's panel: buttons and switches a pocket taps from its UI.
--- PURE — clock injected, no CC calls, so the awkward rules below are actually testable.
---
--- Sibling of easykey/logic/outputs.lua (the proximity door controller). Same discipline,
--- different trigger: nothing here fires from walking past. A control only moves because
--- a pocket the SERVER has cleared deliberately tapped it, from inside range.
---
--- Controls:
---   button -> one pulse of `pressSeconds` per tap (a button)
---   switch -> flips on/off and stays (a lever)
---
--- Switch ownership, which is the subtle part:
---   A switch is owned by the pocket that turned it on. If that pocket's session ends or
---   is revoked, it resets IMMEDIATELY — authority is gone, so the signal goes with it.
---   If the owner merely walks out of range or its tunnel goes quiet, we wait
---   `graceSeconds` first, so a brief step past the boundary or a hiccup doesn't drop a
---   machine you're standing next to. Coming back inside the grace window cancels it.
---   Once reset, nothing is remembered: walking back in re-energises nothing.
---
--- What a pocket may do is decided here, per pocket, and reported to it — the pocket
--- never decides for itself.
---@class Panel
local Panel = {}
Panel.__index = Panel

--- What a control DOES on the redstone:
---   button - a momentary pulse per tap.
---   switch - flips a level and holds it (a lever).
---   latch  - a momentary pulse per tap like a button, but it REMEMBERS an on/off state
---            (for a Create powered toggle latch, which flips on each pulse). It carries a
---            switch's wording + fallback; on a fallback it pulses ONCE to reach the target
---            state. So: a latch is a switch whose output is a pulse-on-change, not a level.
local TYPES = { button = true, switch = true, latch = true }
Panel.TYPES = { "button", "switch", "latch" }

--- What a control is FOR: which tab of the pocket it appears on. Deliberately separate
--- from the type, because the two are independent - a gate can be a momentary button
--- and a lift can be a latching switch.
local USES = { gate = true, elevator = true }
Panel.USES = { "gate", "elevator" }

--- What a switch does when its controlling pocket's authority lapses (session ends, or it
--- leaves range past the grace):
---   off  -> reverts to off (default; fail-closed; preserves "no redstone without a session")
---   on   -> reverts to ON — a "normally-open" control that rests energised and is only
---           held OFF while a pocket is present. NOTE: this deliberately drives redstone
---           with nobody secure nearby; it's an explicit per-control opt-out of the lock.
---   hold -> keeps whatever state it was in until a different input is given.
--- Only meaningful for switches; a button is momentary and has no lingering state.
local FALLBACKS = { off = true, on = true, hold = true }
Panel.FALLBACKS = { "off", "on", "hold" }

--- The state an UNOWNED switch rests at: false (off), true (on), or nil for "hold"
--- (no resting drive — it keeps whatever it had).
local function restOf(c)
    if c.fallback == "on" then return true end
    if c.fallback == "off" then return false end
    return nil -- hold
end

--- Apply a switch's fallback when its controlling pocket's authority lapses: drop
--- ownership and move it to its resting state (off/on), or leave it as-is for "hold".
local function applyFallback(c)
    c.owner = nil
    c.graceFrom = nil
    local rest = restOf(c)
    if rest ~= nil then c.on = rest end
end

--- Is this control locked by a cooldown right now? While locked it takes no input and its
--- redstone is frozen (see tick): a gate driving a Create sequenced gearshift must not be
--- re-fired mid-sequence.
local function onCooldown(c, now)
    return c.cooldownUntil ~= nil and now < c.cooldownUntil
end

--- Access outcomes, mirrored to the pocket (see Protocol.PANEL_STATUS).
Panel.OK           = "ok"
Panel.OUT_OF_RANGE = "out_of_range"
Panel.DENIED       = "denied"
Panel.UNKNOWN      = "unknown"  -- no such control
Panel.COOLDOWN     = "cooldown" -- locked, still ticking down

--- The operator standing at this machine, using the panel on its own monitor.
---
--- They get no pocket, no session and no distance: this PC is hidden and protected
--- exactly like the server, so someone who can touch its monitor could pull the redstone
--- out of the wall anyway. It exists as the failsafe for when a pocket can't be used.
--- What it still respects: this PC must itself be APPROVED by the server (setApproved),
--- so a panel the operator has revoked goes dead here too — and a switch the operator
--- turned on drops the instant that approval is withdrawn, exactly like a pocket's does.
Panel.LOCAL = "@local"

--- @param opts table {
---   now = function()->ms,
---   defaults = { range, graceSeconds, pressSeconds, stale },
--- }
function Panel.new(opts)
    opts = opts or {}
    local d = opts.defaults or {}
    local self = setmetatable({}, Panel)
    self._now = opts.now or function() return os.epoch("utc") end
    self.range = d.range or 100
    self.graceSeconds = d.graceSeconds or 3
    self._pressSeconds = d.pressSeconds or 0.5
    self._stale = d.stale or 2.0

    self._secure = {}   -- address -> expiresAt
    self._presence = {} -- address -> { distance, lastSeen }
    -- id -> { id, name, type, use, target, fallback, invert, cooldown,
    --         on, owner, pulseUntil, graceFrom, cooldownUntil, fired, confirmed }
    -- `fired` (button) = its last pulse was seen high on readback; `confirmed` (latch) = the
    -- state its last CONFIRMED pulse left it in; `cooldownUntil` = a lock that freezes it.
    self.controls = {}
    self.order = {}     -- ids, creation order
    self._nextId = 0
    self._approved = false -- has the SERVER approved this manual PC?
    return self
end

--- Whether the server has approved this manual PC. Gates the local operator panel: an
--- unapproved panel is dead, on its own monitor too.
function Panel:setApproved(v)
    self._approved = v and true or false
end

function Panel:isApproved() return self._approved end

-- ---------- inputs from the server / pockets ----------

function Panel:setSecureSet(sessions)
    local m = {}
    for _, s in ipairs(sessions or {}) do m[s.address] = s.expiresAt end
    self._secure = m
end

function Panel:_isSecure(address, now)
    -- The local operator's "session" is this PC's own approval by the server.
    if address == Panel.LOCAL then return self._approved end
    local expiresAt = self._secure[address]
    if not expiresAt then return false end
    return (now or self._now()) < expiresAt
end

--- Record a presence ping (any pocket, cleared or not — an uncleared pocket still needs to
--- be told "denied" rather than ignored).
function Panel:onPresence(address, distance, now)
    now = now or self._now()
    if distance == nil then return false end -- cross-dimension: not "in range" of anything
    self._presence[address] = { distance = distance, lastSeen = now }
    return true
end

--- Is this pocket close enough, and have we heard from it recently?
function Panel:inRange(address, now)
    -- The operator is standing at the machine: always in range, never goes quiet, so a
    -- switch they set is never dropped by the grace timer.
    if address == Panel.LOCAL then return true end
    now = now or self._now()
    local p = self._presence[address]
    if not p then return false end
    if (now - p.lastSeen) > self._stale * 1000 then return false end
    return p.distance <= self.range
end

--- What this pocket may do right now. This is the single source of truth the pocket is
--- told; it never works it out itself.
function Panel:statusFor(address, now)
    now = now or self._now()
    if not self:inRange(address, now) then return Panel.OUT_OF_RANGE end
    if not self:_isSecure(address, now) then return Panel.DENIED end
    return Panel.OK
end

--- Everyone the SERVER currently has cleared, whether or not they're near this panel.
--- This is the manual PC's Sessions tab; `pockets()` below is its Devices tab.
--- @return array of { address, remaining } sorted by address
function Panel:sessions(now)
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

--- Pockets we've heard from lately, for the operator's list.
--- @return array of { address, distance, secure }
function Panel:pockets(now)
    now = now or self._now()
    local out = {}
    for address, p in pairs(self._presence) do
        if (now - p.lastSeen) <= self._stale * 1000 then
            out[#out + 1] = {
                address = address, distance = p.distance,
                secure = self:_isSecure(address, now),
                inRange = p.distance <= self.range,
            }
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

-- ---------- control definitions ----------

--- Add a control. `target` is a redstone output id from RedstoneIO (e.g. "self/back").
--- `type` = switch|button (what it does), `use` = gate|elevator (where it shows).
function Panel:add(cfg)
    cfg = cfg or {}
    self._nextId = self._nextId + 1
    local id = cfg.id or ("c" .. self._nextId)
    self.controls[id] = {
        id = id,
        name = cfg.name or ("control " .. self._nextId),
        type = TYPES[cfg.type] and cfg.type or "button",
        use = USES[cfg.use] and cfg.use or "gate",
        target = cfg.target,
        fallback = FALLBACKS[cfg.fallback] and cfg.fallback or "off",
        invert = cfg.invert and true or false,
        cooldown = math.max(0, tonumber(cfg.cooldown) or 0),
        on = false, owner = nil, pulseUntil = nil, graceFrom = nil,
        cooldownUntil = nil, fired = false, confirmed = false,
    }
    self.order[#self.order + 1] = id
    return id
end

function Panel:update(id, cfg)
    local c = self.controls[id]
    if not c then return false end
    if cfg.name ~= nil then c.name = tostring(cfg.name) end
    local function reset()
        c.on = false; c.owner = nil; c.pulseUntil = nil; c.graceFrom = nil
        c.cooldownUntil = nil; c.fired = false; c.confirmed = false
    end
    if cfg.type ~= nil and TYPES[cfg.type] then
        c.type = cfg.type
        reset() -- redefining a control must not strand its output on
    end
    -- `use` only moves which tab it appears on, so it never touches the live state
    if cfg.use ~= nil and USES[cfg.use] then c.use = cfg.use end
    if cfg.target ~= nil then c.target = cfg.target; reset() end
    -- fallback/invert are display + settle behaviour: the next tick moves the switch to any
    -- new resting state on its own, so they don't force a reset here.
    if cfg.fallback ~= nil and FALLBACKS[cfg.fallback] then c.fallback = cfg.fallback end
    if cfg.invert ~= nil then c.invert = cfg.invert and true or false end
    if cfg.cooldown ~= nil then
        local n = tonumber(cfg.cooldown)
        if n and n >= 0 then c.cooldown = n end
    end
    return true
end

function Panel:remove(id)
    if not self.controls[id] then return false end
    self.controls[id] = nil
    for i, cid in ipairs(self.order) do
        if cid == id then table.remove(self.order, i); break end
    end
    return true
end

--- Persisted shape: id -> { name, type, target }. State is never saved: a reboot must
--- come up cold.
function Panel:exportConfig()
    local out = {}
    for id, c in pairs(self.controls) do
        out[id] = { name = c.name, type = c.type, use = c.use, target = c.target,
                    fallback = c.fallback, invert = c.invert, cooldown = c.cooldown }
    end
    return out
end

function Panel:loadConfig(byId)
    -- keep ids stable across reboots, and keep _nextId ahead of them
    local ids = {}
    for id in pairs(byId or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local cfg = byId[id]
        self:add({ id = id, name = cfg.name, type = cfg.type, use = cfg.use, target = cfg.target,
                   fallback = cfg.fallback, invert = cfg.invert, cooldown = cfg.cooldown })
        local n = tonumber(tostring(id):match("^c(%d+)$") or 0) or 0
        if n > self._nextId then self._nextId = n end
    end
end

--- What the pocket is shown: id, name, type. Never the target — a pocket has no business
--- knowing the wiring.
function Panel:listForPocket()
    local out = {}
    for _, id in ipairs(self.order) do
        local c = self.controls[id]
        -- `invert` rides along so the pocket can word the state (Open/Closed, Up/Down)
        -- correctly for a control wired the other way. The wiring (target) still never leaks.
        out[#out + 1] = { id = c.id, name = c.name, type = c.type, use = c.use, invert = c.invert }
    end
    return out
end

--- Rows for the manual PC's own UI (includes the target).
function Panel:snapshot()
    local out = {}
    for i, id in ipairs(self.order) do
        local c = self.controls[id]
        out[i] = { id = c.id, name = c.name, type = c.type, use = c.use, target = c.target,
                   fallback = c.fallback, invert = c.invert, cooldown = c.cooldown,
                   on = c.on, owner = c.owner }
    end
    return out
end

-- ---------- the input ----------

--- A pocket tapped a control. Returns accepted(bool), reason.
--- Every rejection path is explicit, because "nothing happened" is the one outcome a
--- user can't debug.
function Panel:input(address, controlId, now)
    now = now or self._now()
    local c = self.controls[controlId]
    if not c then return false, Panel.UNKNOWN end

    local status = self:statusFor(address, now)
    if status ~= Panel.OK then return false, status end
    if onCooldown(c, now) then return false, Panel.COOLDOWN end -- frozen: ignore the tap

    if c.type == "button" then
        c.pulseUntil = now + self._pressSeconds * 1000
        c.owner = address
        c.on = true
        c.fired = false -- this press hasn't been seen on the redstone yet
    else -- switch or latch: toggle a remembered state, owned while held away from rest
        local newOn = not c.on
        c.on = newOn
        c.graceFrom = nil
        -- Own it only while it's held AWAY from its resting state. Tapping it back to rest
        -- releases ownership (nobody needs to hold it there). For "hold" there is no resting
        -- state, so any deviation keeps ownership until authority lapses.
        local rest = restOf(c)
        if rest ~= nil and newOn == rest then
            c.owner = nil
        else
            c.owner = address
        end
        -- a latch is pulsed to FLIP the physical toggle latch; a switch just holds its level
        if c.type == "latch" then c.pulseUntil = now + self._pressSeconds * 1000 end
    end
    -- an accepted tap starts the cooldown (if any): no re-fire until it lapses
    if c.cooldown and c.cooldown > 0 then c.cooldownUntil = now + c.cooldown * 1000 end
    return true, Panel.OK
end

--- Recompute every control. Returns target-state map (outputId -> bool) and changes.
function Panel:tick(now)
    now = now or self._now()
    local states, changes = {}, {}

    for _, id in ipairs(self.order) do
        local c = self.controls[id]
        local before = c.on
        -- Frozen by a cooldown: no NEW state changes (fallback + resting wait), but a pulse
        -- already in flight still completes the fire that started the cooldown.
        local frozen = onCooldown(c, now)

        if c.type == "button" then
            if c.pulseUntil and now >= c.pulseUntil then
                c.pulseUntil = nil; c.on = false; c.owner = nil -- pulse over: the redstone drops
            end
        elseif frozen then
            -- held exactly where it is; the deferred fallback/resting runs once the lock lapses
        elseif c.owner then
            -- a pocket is actively holding this switch away from its resting state
            if not self:_isSecure(c.owner, now) then
                applyFallback(c)                 -- authority gone: no grace
            elseif not self:inRange(c.owner, now) then
                c.graceFrom = c.graceFrom or now -- range/connection blip: grace it first
                if (now - c.graceFrom) >= self.graceSeconds * 1000 then
                    applyFallback(c)
                end
            else
                c.graceFrom = nil                -- came back inside the window
            end
        else
            -- unowned: settle to the resting state. A "normally-on" switch energises here
            -- with nobody around (deliberate); a normally-off one stays off; "hold" keeps
            -- whatever it had.
            local rest = restOf(c)
            if rest == true and not c.on then c.on = true
            elseif rest == false and c.on then c.on = false end
        end

        -- A latch turns each state change (from a tap, a fallback, or resting) into ONE short
        -- pulse; the remembered state lives in c.on, and the redstone is momentary. A frozen
        -- latch never STARTS a new pulse, but a running one still ages out.
        if c.type == "latch" then
            if c.on ~= before and not frozen then c.pulseUntil = now + self._pressSeconds * 1000 end
            if c.pulseUntil and now >= c.pulseUntil then c.pulseUntil = nil end
        end

        -- Redstone: a latch drives only its brief pulse; a button/switch drive the level c.on.
        local redstone = c.on
        if c.type == "latch" then redstone = (c.pulseUntil ~= nil) and (now < c.pulseUntil) or false end
        if c.target then states[c.target] = states[c.target] or redstone end
        if c.on ~= before then
            changes[#changes + 1] = { id = id, name = c.name, on = c.on }
        end
    end

    return states, changes
end

--- After the manual PC drives its redstone and reads it BACK, confirm what actually fired.
--- A button's `fired` flag lights once its pulse is seen high; a latch's `confirmed` state only
--- advances when its pulse is seen high — so a pulse the hardware dropped never moves the
--- pocket UI. Switches need nothing here: their readback IS their reported state.
function Panel:observeFeedback(feedback, now)
    now = now or self._now()
    for _, id in ipairs(self.order) do
        local c = self.controls[id]
        local high = (c.target and feedback and feedback[c.target]) or false
        local pulsing = c.pulseUntil ~= nil and now < c.pulseUntil
        if pulsing and high then
            if c.type == "button" then c.fired = true
            elseif c.type == "latch" then c.confirmed = c.on end
        end
    end
end

--- Panel state for one pocket, given what the hardware ACTUALLY reports. Per control:
---   switch : { on = actual redstone, err = hardware disagreed with us }
---   latch  : { on = confirmed state (only a real pulse advances it) }
---   button : { fired = its last pulse was confirmed on the redstone }
---   all    : { cooldown = seconds still locked, 0 = none }
--- The pocket renders exactly this and never predicts.
function Panel:stateFor(address, feedback, now)
    now = now or self._now()
    local status = self:statusFor(address, now)
    local out = {}
    for _, id in ipairs(self.order) do
        local c = self.controls[id]
        local actual = (c.target and feedback and feedback[c.target]) or false
        local row = { id = c.id }
        if c.type == "button" then
            row.fired = c.fired and true or false
        elseif c.type == "latch" then
            row.on = c.confirmed and true or false
        else -- switch
            row.on = actual
            row.err = (actual ~= c.on) or nil
        end
        row.cooldown = c.cooldownUntil and math.max(0, math.ceil((c.cooldownUntil - now) / 1000)) or 0
        out[#out + 1] = row
    end
    return status, out
end

return Panel
