--- The elevator controller's lifts and floors. PURE — clock injected, no CC calls.
---
--- Third sibling of easykey/logic/outputs.lua (proximity doors) and easykey/logic/panel.lua
--- (the manual panel). Same discipline — nothing moves unless a pocket the SERVER has
--- cleared deliberately asks, from inside range — but the shape of the thing is different:
---
---   * A lift is a GROUP of floors, not one control. Every floor is a momentary button and
---     nothing else, because that is all a Create Elevator Contact accepts: give a contact
---     a redstone pulse and the cabin comes to that floor. There is no level to hold and no
---     state to latch, so there are no switches here.
---   * Position is READ, never assumed. An Elevator Contact emits redstone while the cabin
---     is stopped at its floor, so a floor may name an input channel to watch. `at` is
---     whatever the hardware says, or nil while the cabin is between floors.
---   * A channel may live on THIS computer or on the lift's monitor (a PC at the shaft).
---     `"mon:self/back"` means "self/back on this lift's monitor"; anything else is local.
---     That is the whole remote-wiring abstraction — a floor's call pulse either drives our
---     own redstone or rides an encrypted message to the monitor, and nothing else in the
---     system has to care which.
---
--- Published to the pocket as ordinary panel buttons with `use = "elevator"`, so the pocket
--- renders them on its Lifts tab with no idea elevators exist. Two of the fields it already
--- draws carry the extra meaning:
---   * `fired`    -> the cabin is AT this floor (its confirm circle fills green)
---   * `cooldown` -> this lift is locked after a call (its "~Ns" marker)
---@class Elevator
local Elevator = {}
Elevator.__index = Elevator

local Access = require("easykey.logic.access")

--- Access outcomes, mirrored to the pocket (see Protocol.PANEL_STATUS).
Elevator.OK           = Access.OK
Elevator.OUT_OF_RANGE = Access.OUT_OF_RANGE
Elevator.DENIED       = Access.DENIED
Elevator.LOCAL        = Access.LOCAL
Elevator.UNKNOWN      = "unknown"    -- no such lift/floor
Elevator.COOLDOWN     = "cooldown"   -- locked after a recent call
Elevator.NO_TARGET    = "no_target"  -- the floor has no call channel configured
Elevator.NO_MONITOR   = "no_monitor" -- the floor calls via the monitor, but none is set

--- The prefix marking a channel as living on the lift's monitor rather than on this PC.
Elevator.MON = "mon:"

function Elevator.isRemote(channel)
    return type(channel) == "string" and channel:sub(1, #Elevator.MON) == Elevator.MON
end

--- The bare RedstoneIO id inside a remote channel ("mon:self/back" -> "self/back").
function Elevator.remoteId(channel)
    if not Elevator.isRemote(channel) then return nil end
    return channel:sub(#Elevator.MON + 1)
end

--- Wrap a monitor-side RedstoneIO id as a channel.
function Elevator.monChannel(id) return Elevator.MON .. tostring(id) end

--- The id a floor is published to the pocket under. Both halves are stable across
--- reordering and deletion, so a pocket's cached widget never lands on a different floor.
function Elevator.controlId(liftId, floorId) return tostring(liftId) .. "." .. tostring(floorId) end

function Elevator.splitControlId(controlId)
    local lift, floor = tostring(controlId):match("^([^.]+)%.([^.]+)$")
    return lift, floor
end

--- @param opts table {
---   now = function()->ms,
---   defaults = { range, stale, pressSeconds, recallSeconds, timeoutSeconds },
--- }
function Elevator.new(opts)
    opts = opts or {}
    local d = opts.defaults or {}
    local self = setmetatable({}, Elevator)
    self._now = opts.now or function() return os.epoch("utc") end
    self.access = Access.new({ now = self._now, defaults = { range = d.range, stale = d.stale } })
    self._pressSeconds = d.pressSeconds or 0.5
    self._recall = d.recallSeconds or 2
    self._timeout = d.timeoutSeconds or 20
    self.lifts = {}
    self.order = {}
    self._nextId = 0
    -- Remote pulses waiting to be put on the wire. Drained by tick() so the role can send
    -- them; a pulse is dispatched ONCE and timed by the monitor, never re-sent per tick.
    self._outbox = {}
    return self
end

-- ---------- access (delegated; see easykey/logic/access.lua) ----------
function Elevator:setApproved(v) self.access:setApproved(v) end
function Elevator:isApproved() return self.access:isApproved() end
function Elevator:setSecureSet(list) self.access:setSecureSet(list) end
function Elevator:onPresence(a, d, now) return self.access:onPresence(a, d, now) end
function Elevator:inRange(a, now) return self.access:inRange(a, now) end
function Elevator:statusFor(a, now) return self.access:statusFor(a, now) end
function Elevator:sessions(now) return self.access:sessions(now) end
function Elevator:pockets(now) return self.access:pockets(now) end
function Elevator:getRange() return self.access.range end
function Elevator:setRange(n)
    local v = tonumber(n)
    if v and v > 0 then self.access.range = v; return true end
    return false
end

-- ---------- lifts ----------

--- "" is how a form says "none". Every channel/address field goes through this, because a
--- stored "" is a value that looks set, matches nothing, and reads as a mysteriously dead
--- control rather than an unconfigured one.
local function orNil(v)
    if v == nil or v == "" then return nil end
    return v
end

--- Add a lift. `monitor` is the ecnet2 address of its elevator monitor, or nil for a lift
--- wired entirely to this computer.
function Elevator:add(cfg)
    cfg = cfg or {}
    self._nextId = self._nextId + 1
    local id = cfg.id or ("e" .. self._nextId)
    self.lifts[id] = {
        id = id,
        name = cfg.name or ("lift " .. self._nextId),
        monitor = orNil(cfg.monitor),
        recall = math.max(0, tonumber(cfg.recall) or self._recall),
        timeout = math.max(1, tonumber(cfg.timeout) or self._timeout),
        floors = {}, floorOrder = {}, _nextFloor = 0,
        at = nil, callFloor = nil, callUntil = nil, lockUntil = nil, pulse = nil,
    }
    self.order[#self.order + 1] = id
    return id
end

function Elevator:update(id, cfg)
    local l = self.lifts[id]
    if not l then return false end
    if cfg.name ~= nil then l.name = tostring(cfg.name) end
    if cfg.monitor ~= nil then
        -- The monitor is where half the wiring lives, so changing it invalidates every
        -- position reading and any pulse in flight. Come up cold rather than reporting a
        -- floor the new monitor never told us about. ("" clears it — which is how the form
        -- says "wired to this PC instead"; without that you could never un-set a monitor.)
        l.monitor = orNil(cfg.monitor)
        l.at = nil; l.callFloor = nil; l.callUntil = nil; l.pulse = nil
    end
    if cfg.recall ~= nil then
        local n = tonumber(cfg.recall)
        if n and n >= 0 then l.recall = n end
    end
    if cfg.timeout ~= nil then
        local n = tonumber(cfg.timeout)
        if n and n >= 1 then l.timeout = n end
    end
    return true
end

function Elevator:remove(id)
    if not self.lifts[id] then return false end
    self.lifts[id] = nil
    for i, lid in ipairs(self.order) do
        if lid == id then table.remove(self.order, i); break end
    end
    return true
end

-- ---------- floors ----------

--- Add a floor to a lift. `call` is the channel pulsed to summon the cabin here; `at` is
--- the channel the arrival contact drives (optional — without it the cabin's position is
--- simply unknown, which is reported honestly rather than guessed).
function Elevator:addFloor(liftId, cfg)
    local l = self.lifts[liftId]
    if not l then return nil end
    cfg = cfg or {}
    l._nextFloor = l._nextFloor + 1
    local fid = cfg.id or ("f" .. l._nextFloor)
    l.floors[fid] = {
        id = fid,
        name = cfg.name or ("floor " .. l._nextFloor),
        call = orNil(cfg.call),
        at = orNil(cfg.at),
    }
    l.floorOrder[#l.floorOrder + 1] = fid
    -- keep the counter ahead of hand-picked ids so a reload can't collide
    local n = tonumber(tostring(fid):match("^f(%d+)$") or 0) or 0
    if n > l._nextFloor then l._nextFloor = n end
    return fid
end

function Elevator:updateFloor(liftId, floorId, cfg)
    local l = self.lifts[liftId]
    local f = l and l.floors[floorId]
    if not f then return false end
    if cfg.name ~= nil then f.name = tostring(cfg.name) end
    -- "" from a form's "(none)" choice clears a channel; absent means "leave it alone"
    if cfg.call ~= nil then f.call = orNil(cfg.call) end
    if cfg.at ~= nil then f.at = orNil(cfg.at) end
    return true
end

function Elevator:removeFloor(liftId, floorId)
    local l = self.lifts[liftId]
    if not l or not l.floors[floorId] then return false end
    l.floors[floorId] = nil
    for i, fid in ipairs(l.floorOrder) do
        if fid == floorId then table.remove(l.floorOrder, i); break end
    end
    -- a deleted floor must not stay "where the cabin is" or "what we called"
    if l.at == floorId then l.at = nil end
    if l.callFloor == floorId then l.callFloor = nil; l.callUntil = nil end
    return true
end

--- Move a floor up (-1) or down (+1) the published order. Floors are listed the way the
--- shaft is stacked, and the order is the operator's, not the creation sequence.
function Elevator:moveFloor(liftId, floorId, delta)
    local l = self.lifts[liftId]
    if not l then return false end
    for i, fid in ipairs(l.floorOrder) do
        if fid == floorId then
            local j = i + (delta or 0)
            if j < 1 or j > #l.floorOrder then return false end
            table.remove(l.floorOrder, i)
            table.insert(l.floorOrder, j, floorId)
            return true
        end
    end
    return false
end

-- ---------- persistence ----------

--- Persisted shape: liftId -> { name, monitor, recall, timeout, floors = ordered array }.
--- Live state (position, calls, pulses) is never saved: a reboot must come up cold and
--- learn where the cabin is from the hardware.
function Elevator:exportConfig()
    local out = {}
    for id, l in pairs(self.lifts) do
        local floors = {}
        for _, fid in ipairs(l.floorOrder) do
            local f = l.floors[fid]
            floors[#floors + 1] = { id = f.id, name = f.name, call = f.call, at = f.at }
        end
        out[id] = { name = l.name, monitor = l.monitor, recall = l.recall,
                    timeout = l.timeout, floors = floors }
    end
    return out
end

function Elevator:loadConfig(byId)
    local ids = {}
    for id in pairs(byId or {}) do ids[#ids + 1] = id end
    table.sort(ids) -- stable order across reboots
    for _, id in ipairs(ids) do
        local cfg = byId[id] or {}
        self:add({ id = id, name = cfg.name, monitor = cfg.monitor,
                   recall = cfg.recall, timeout = cfg.timeout })
        for _, f in ipairs(cfg.floors or {}) do
            self:addFloor(id, { id = f.id, name = f.name, call = f.call, at = f.at })
        end
        local n = tonumber(tostring(id):match("^e(%d+)$") or 0) or 0
        if n > self._nextId then self._nextId = n end
    end
end

-- ---------- lookups ----------

function Elevator:_find(controlId)
    local liftId, floorId = Elevator.splitControlId(controlId)
    if not liftId then return nil end
    local l = self.lifts[liftId]
    if not l then return nil end
    return l, l.floors[floorId]
end

--- Every monitor address any lift depends on (so the role knows which tunnels to keep up).
function Elevator:monitors()
    local seen, out = {}, {}
    for _, id in ipairs(self.order) do
        local m = self.lifts[id].monitor
        if m and not seen[m] then seen[m] = true; out[#out + 1] = m end
    end
    table.sort(out)
    return out
end

--- Is this lift refusing input right now, and for how much longer (seconds)?
local function lockSeconds(l, now)
    if not l.lockUntil or now >= l.lockUntil then return 0 end
    return math.max(0, math.ceil((l.lockUntil - now) / 1000))
end

-- ---------- what the pocket sees ----------

--- Floors as ordinary panel buttons. The wiring never leaves this computer: a pocket has no
--- business knowing which channel a floor pulses.
function Elevator:listForPocket()
    local out = {}
    for _, lid in ipairs(self.order) do
        local l = self.lifts[lid]
        for _, fid in ipairs(l.floorOrder) do
            local f = l.floors[fid]
            out[#out + 1] = {
                id = Elevator.controlId(lid, fid),
                name = l.name .. " " .. f.name,
                type = "button",
                use = "elevator",
                invert = false,
            }
        end
    end
    return out
end

--- Panel state for one pocket. `fired` means the cabin is AT that floor (read from the
--- arrival contact, never inferred from what we asked for); `cooldown` is the lift's recall
--- lock. The pocket renders exactly this and predicts nothing.
function Elevator:stateFor(address, now)
    now = now or self._now()
    local status = self.access:statusFor(address, now)
    local out = {}
    for _, lid in ipairs(self.order) do
        local l = self.lifts[lid]
        local cd = lockSeconds(l, now)
        for _, fid in ipairs(l.floorOrder) do
            out[#out + 1] = {
                id = Elevator.controlId(lid, fid),
                fired = (l.at == fid),
                cooldown = cd,
            }
        end
    end
    return status, out
end

-- ---------- the input ----------

--- A pocket (or the local operator) called a floor. Returns accepted(bool), reason.
--- Every rejection is explicit and named, because "nothing happened" is the one outcome a
--- user cannot debug.
function Elevator:input(address, controlId, now)
    now = now or self._now()
    local l, f = self:_find(controlId)
    if not l or not f then return false, Elevator.UNKNOWN end

    local status = self.access:statusFor(address, now)
    if status ~= Access.OK then return false, status end
    if lockSeconds(l, now) > 0 then return false, Elevator.COOLDOWN end

    -- Validate the wiring BEFORE touching any state: a refused call must leave the lift
    -- exactly as it was, not half-locked with no pulse to show for it.
    if not f.call then return false, Elevator.NO_TARGET end
    local remote = Elevator.isRemote(f.call)
    if remote and not l.monitor then return false, Elevator.NO_MONITOR end

    if remote then
        self._outbox[#self._outbox + 1] = {
            monitor = l.monitor,
            target = Elevator.remoteId(f.call),
            seconds = self._pressSeconds,
        }
    else
        l.pulse = { target = f.call, expires = now + self._pressSeconds * 1000 }
    end

    l.callFloor = f.id
    l.callUntil = now + l.timeout * 1000
    if l.recall > 0 then l.lockUntil = now + l.recall * 1000 end
    return true, Elevator.OK
end

-- ---------- the tick ----------

--- Recompute everything. Returns:
---   states  : local channel id -> true, for RedstoneIO:apply (absent = drive it off)
---   pulses  : remote pulses to dispatch NOW, each { monitor, target, seconds } (drained)
---   changes : notable events for the console, each { lift, name, floor, kind }
function Elevator:tick(now)
    now = now or self._now()
    local states, changes = {}, {}

    for _, lid in ipairs(self.order) do
        local l = self.lifts[lid]

        -- a local call pulse ages out on its own
        if l.pulse and now >= l.pulse.expires then l.pulse = nil end

        if l.callFloor then
            if l.at == l.callFloor then
                local f = l.floors[l.callFloor]
                changes[#changes + 1] = { lift = lid, name = l.name,
                    floor = f and f.name or l.callFloor, kind = "arrived" }
                l.callFloor = nil; l.callUntil = nil
            elseif now >= (l.callUntil or 0) then
                -- The cabin never reported arriving. That is either a long shaft, a missing
                -- arrival contact, or a call that was never received — all worth saying out
                -- loud rather than leaving the lift "calling" forever.
                local f = l.floors[l.callFloor]
                changes[#changes + 1] = { lift = lid, name = l.name,
                    floor = f and f.name or l.callFloor, kind = "no_arrival" }
                l.callFloor = nil; l.callUntil = nil
            end
        end

        if l.pulse then states[l.pulse.target] = true end
    end

    local pulses = self._outbox
    self._outbox = {}
    return states, pulses, changes
end

--- Where every cabin is, from what the hardware actually reports.
--- @param localInputs table|nil id -> bool, this computer's redstone INPUTS
--- @param remoteStates table|nil monitorAddress -> { inputs = { id -> bool }, outputs = ... }
--- Returns the ids of lifts whose position changed, so the caller can log/push at once.
function Elevator:observeFeedback(localInputs, remoteStates, now)
    now = now or self._now()
    local moved = {}
    for _, lid in ipairs(self.order) do
        local l = self.lifts[lid]
        local found = nil
        for _, fid in ipairs(l.floorOrder) do
            local f = l.floors[fid]
            if f.at and not found then
                local high
                if Elevator.isRemote(f.at) then
                    local rs = l.monitor and remoteStates and remoteStates[l.monitor]
                    high = (rs and rs.inputs and rs.inputs[Elevator.remoteId(f.at)]) or false
                else
                    high = (localInputs and localInputs[f.at]) or false
                end
                if high then found = fid end
            end
        end
        if l.at ~= found then l.at = found; moved[#moved + 1] = lid end
    end
    return moved
end

-- ---------- what the operator's own screen sees ----------

--- One row per lift for the Lifts tab.
--- @return array of { id, name, monitor, recall, timeout, floors, at, calling, locked }
function Elevator:snapshot(now)
    now = now or self._now()
    local out = {}
    for i, lid in ipairs(self.order) do
        local l = self.lifts[lid]
        local atF = l.at and l.floors[l.at]
        local callF = l.callFloor and l.floors[l.callFloor]
        out[i] = {
            id = lid, name = l.name, monitor = l.monitor,
            recall = l.recall, timeout = l.timeout,
            floors = #l.floorOrder,
            at = atF and atF.name or nil,
            calling = callF and callF.name or nil,
            locked = lockSeconds(l, now),
        }
    end
    return out
end

--- One row per floor of one lift, for the Floors tab (includes the wiring — this is the
--- operator's own screen, unlike listForPocket).
--- @return array of { id, name, call, at, isAt, isCalling }
function Elevator:floorRows(liftId)
    local l = self.lifts[liftId]
    if not l then return {} end
    local out = {}
    for i, fid in ipairs(l.floorOrder) do
        local f = l.floors[fid]
        out[i] = { id = fid, name = f.name, call = f.call, at = f.at,
                   isAt = (l.at == fid), isCalling = (l.callFloor == fid) }
    end
    return out
end

--- Floors whose call channel doesn't exist, by "<lift> <floor>" name.
---
--- Bundling a side redefines its channels ("self/back" becomes "self/back:pink" & co.), and a
--- monitor going away takes all of its channels with it — either way a floor can stop being
--- wired to anything without anyone touching it. The same trap the manual panel hit; saying it
--- plainly beats a call that silently does nothing.
---
--- @param validFor table|function either a flat set of channel -> true, or a
---        function(liftId) -> set. Prefer the function: "mon:" is resolved against the lift's
---        OWN monitor, so a flat union across every lift would call a floor valid because some
---        *other* lift's monitor happens to have a channel by that name.
function Elevator:orphanedFloors(validFor)
    local isFn = (type(validFor) == "function")
    local flat = (not isFn) and (validFor or {}) or nil
    local out = {}
    for _, lid in ipairs(self.order) do
        local l = self.lifts[lid]
        local valid = isFn and (validFor(lid) or {}) or flat
        for _, fid in ipairs(l.floorOrder) do
            local f = l.floors[fid]
            if not f.call or not valid[f.call] then
                out[#out + 1] = l.name .. " " .. f.name
            end
        end
    end
    return out
end

return Elevator
