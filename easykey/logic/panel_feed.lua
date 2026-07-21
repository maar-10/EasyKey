--- What the pocket knows about the manual panels around it. PURE (clock injected).
---
--- Extracted from the pocket's event loop because this merge is fiddly and has now
--- dropped a field twice: it must carry EVERY property a manual PC publishes (name, type,
--- and `use` — which decides whether a control lands on Gates or Lifts) while keeping the
--- last reported on/err until fresh state arrives. In the loop it was untestable, so the
--- bugs only showed up in-game as a control on the wrong tab.
---
--- The rule this enforces: the pocket never invents state. A control exists because a
--- panel listed it, moves because a panel reported it moved, and a panel that goes quiet
--- is marked `signal_error` rather than assumed fine.
---@class PanelFeed
local PanelFeed = {}
PanelFeed.__index = PanelFeed

--- Properties copied verbatim from a PANEL_LIST entry. Adding a property to the protocol
--- means adding it here — that is the whole point of the list being explicit.
local DEFINITION_FIELDS = { "id", "name", "type", "use", "invert" }

--- @param opts table { now = function()->ms, timeout = seconds }
function PanelFeed.new(opts)
    opts = opts or {}
    local self = setmetatable({}, PanelFeed)
    self._now = opts.now or function() return os.epoch("utc") end
    self._timeout = opts.timeout or 3.0
    self.panels = {} -- address -> { status, byId, order, lastSeen }
    return self
end

local function ensure(self, address)
    local p = self.panels[address]
    if not p then
        p = { status = "signal_error", byId = {}, order = {} }
        self.panels[address] = p
    end
    return p
end

--- A manual PC published its control list (PANEL_LIST).
--- Controls it no longer lists simply vanish, which is how deletions propagate.
function PanelFeed:onList(address, controls)
    local p = ensure(self, address)
    local byId, order = {}, {}
    for _, c in ipairs(controls or {}) do
        local prev = p.byId[c.id]
        local entry = {}
        for _, field in ipairs(DEFINITION_FIELDS) do entry[field] = c[field] end
        -- hold the last reported state until the next PANEL_STATE lands, so the controls
        -- don't all blink to "off" every time the list is republished
        entry.on = prev and prev.on or false
        entry.err = prev and prev.err or nil
        entry.fired = prev and prev.fired or false
        entry.cooldown = prev and prev.cooldown or 0
        byId[c.id] = entry
        order[#order + 1] = c.id
    end
    p.byId, p.order = byId, order
    p.lastSeen = self._now()
end

--- A manual PC reported what its redstone is actually doing (PANEL_STATE).
function PanelFeed:onState(address, status, controls)
    local p = ensure(self, address)
    p.status = status
    p.lastSeen = self._now()
    for _, c in ipairs(controls or {}) do
        local existing = p.byId[c.id]
        -- a state for a control we haven't been told about yet is ignored: the list is
        -- what defines existence
        if existing then
            existing.on = c.on and true or false
            existing.err = c.err
            existing.fired = c.fired and true or false
            existing.cooldown = tonumber(c.cooldown) or 0
        end
    end
end

--- Mark panels that have gone quiet. Returns true if anything changed.
--- Silence is never treated as "still fine" — that's how a dead panel would keep showing
--- a button that looks live.
function PanelFeed:tick(now)
    now = now or self._now()
    local changed = false
    for _, p in pairs(self.panels) do
        if p.lastSeen and (now - p.lastSeen) > self._timeout * 1000
            and p.status ~= "signal_error" then
            p.status = "signal_error"
            changed = true
        end
    end
    return changed
end

--- Forget everything (e.g. this pocket lost its approval).
function PanelFeed:clear() self.panels = {} end

--- What the view renders: array of { address, status, controls }, sorted by address so
--- the order is stable between refreshes.
function PanelFeed:list()
    local out = {}
    for address, p in pairs(self.panels) do
        local controls = {}
        for _, id in ipairs(p.order or {}) do
            local c = p.byId[id]
            if c then controls[#controls + 1] = c end
        end
        out[#out + 1] = { address = address, status = p.status, controls = controls }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

return PanelFeed
