--- Redstone hardware for the control PC: what exists, how to drive it, what it's
--- actually doing. Everything CC-specific lives here so the state machine
--- (easykey/logic/outputs.lua) stays pure.
---
--- Targets, all driven the same way because the `redstone_relay` peripheral mirrors the
--- global `redstone` API exactly (setOutput/getOutput/setBundledOutput/getBundledOutput):
---   * this computer's 6 sides           -> id "self/back"
---   * every wired redstone relay's sides -> id "redstone_relay_3/left"
---   * one colour on a bundled cable      -> id "self/back:pink"
---
--- An IE interface/redstone connector just reads the signal on that side, so it needs no
--- special handling: point it at a side (or a bundled colour) and set the type.
---
--- Bundled cables carry 16 independent channels on ONE side, so a side is either plain
--- or bundled — never both. The operator flips a side into bundled mode, which swaps its
--- single plain output for 16 colour outputs. Listing all 16 colours for all 6 sides up
--- front would mean ~100 rows per device to scroll past; this way you only pay for the
--- cables you actually wired.
---
--- The bundled write is a bitmask: setBundledOutput(side, mask) where mask is the SUM of
--- the ON colour values. Colours are powers of two, so summing distinct ones is the same
--- as OR-ing them.
local RedstoneIO = {}
RedstoneIO.__index = RedstoneIO

RedstoneIO.SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- Fixed order so the UI and the config file stay stable between reboots.
RedstoneIO.COLORS = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink",
    "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }

--- id helpers — one place that knows the format.
function RedstoneIO.plainId(device, side) return device .. "/" .. side end
function RedstoneIO.colorId(device, side, color) return device .. "/" .. side .. ":" .. color end
function RedstoneIO.sideKey(device, side) return device .. "/" .. side end

--- @param env table|nil { peripheral = , redstone = } (injectable for tests)
function RedstoneIO.new(env)
    env = env or {}
    local self = setmetatable({}, RedstoneIO)
    self._peripheral = env.peripheral or peripheral
    self._redstone = env.redstone or redstone
    self.devices = {} -- name -> api
    return self
end

--- Find everything we can drive: this computer plus any wired redstone relays.
--- Returns the device names in a stable order ("self" first).
function RedstoneIO:discover()
    self.devices = { self = self._redstone }
    local names = { "self" }
    local found = {}
    for _, name in ipairs(self._peripheral.getNames()) do
        if self._peripheral.getType(name) == "redstone_relay" then
            local api = self._peripheral.wrap(name)
            if api then found[#found + 1] = name; self.devices[name] = api end
        end
    end
    table.sort(found)
    for _, n in ipairs(found) do names[#names + 1] = n end
    self.order = names
    return names
end

--- Every output id this hardware currently offers, in a stable order, given which sides
--- the operator has flipped to bundled mode.
--- @param bundledSides table set of sideKey -> true
--- @return table array of { id, device, side, color } (color is nil for plain sides)
function RedstoneIO:enumerate(bundledSides)
    bundledSides = bundledSides or {}
    local out = {}
    for _, device in ipairs(self.order or {}) do
        for _, side in ipairs(RedstoneIO.SIDES) do
            if bundledSides[RedstoneIO.sideKey(device, side)] then
                for _, color in ipairs(RedstoneIO.COLORS) do
                    out[#out + 1] = {
                        id = RedstoneIO.colorId(device, side, color),
                        device = device, side = side, color = color,
                    }
                end
            else
                out[#out + 1] = {
                    id = RedstoneIO.plainId(device, side),
                    device = device, side = side,
                }
            end
        end
    end
    return out
end

--- Drive the hardware from a state map (id -> bool). Idempotent: safe to call every tick.
--- @param states table id -> bool
--- @param bundledSides table set of sideKey -> true
function RedstoneIO:apply(states, bundledSides)
    bundledSides = bundledSides or {}
    for _, device in ipairs(self.order or {}) do
        local api = self.devices[device]
        if api then
            for _, side in ipairs(RedstoneIO.SIDES) do
                local key = RedstoneIO.sideKey(device, side)
                if bundledSides[key] then
                    -- one write per side: the mask is the sum of that side's ON colours
                    local mask = 0
                    for _, color in ipairs(RedstoneIO.COLORS) do
                        if states[RedstoneIO.colorId(device, side, color)] then
                            mask = mask + (colors[color] or 0)
                        end
                    end
                    pcall(api.setBundledOutput, side, mask)
                else
                    pcall(api.setOutput, side, states[key] and true or false)
                end
            end
        end
    end
end

--- Read back what the hardware is ACTUALLY emitting, rather than what we asked for.
--- This is the feedback the UI shows: if a write silently failed, it shows here.
--- @return table id -> bool
function RedstoneIO:readBack(bundledSides)
    bundledSides = bundledSides or {}
    local out = {}
    for _, device in ipairs(self.order or {}) do
        local api = self.devices[device]
        if api then
            for _, side in ipairs(RedstoneIO.SIDES) do
                local key = RedstoneIO.sideKey(device, side)
                if bundledSides[key] then
                    local ok, mask = pcall(api.getBundledOutput, side)
                    mask = (ok and type(mask) == "number") and mask or 0
                    for _, color in ipairs(RedstoneIO.COLORS) do
                        local bit = colors[color] or 0
                        -- bit is a power of two, so this is a plain membership test
                        out[RedstoneIO.colorId(device, side, color)] =
                            (bit > 0) and (mask % (bit * 2)) >= bit or false
                    end
                else
                    local ok, on = pcall(api.getOutput, side)
                    out[key] = (ok and on) and true or false
                end
            end
        end
    end
    return out
end

--- Read what the world is driving INTO us, on the same channel ids `readBack` uses for
--- outputs. Needed by the elevator monitor: a Create Elevator Contact emits a redstone
--- signal while the cabin is stopped at its floor, so "where is the cabin" is an input.
---
--- Inputs and outputs are separate on the same side, so a side can be read and written
--- without the two interfering — which is why this mirrors readBack instead of replacing
--- it. `redstone_relay` exposes getInput/getBundledInput exactly like the global API, so
--- relays and IE bundled cables come along for free.
--- @return table id -> bool
function RedstoneIO:readInputs(bundledSides)
    bundledSides = bundledSides or {}
    local out = {}
    for _, device in ipairs(self.order or {}) do
        local api = self.devices[device]
        if api then
            for _, side in ipairs(RedstoneIO.SIDES) do
                local key = RedstoneIO.sideKey(device, side)
                if bundledSides[key] then
                    local ok, mask = pcall(api.getBundledInput, side)
                    mask = (ok and type(mask) == "number") and mask or 0
                    for _, color in ipairs(RedstoneIO.COLORS) do
                        local bit = colors[color] or 0
                        -- bit is a power of two, so this is a plain membership test
                        out[RedstoneIO.colorId(device, side, color)] =
                            (bit > 0) and (mask % (bit * 2)) >= bit or false
                    end
                else
                    local ok, on = pcall(api.getInput, side)
                    out[key] = (ok and on) and true or false
                end
            end
        end
    end
    return out
end

--- Turn absolutely everything off. Used at boot and whenever the door controller can't
--- justify emitting: no session, no signal.
function RedstoneIO:allOff(bundledSides)
    bundledSides = bundledSides or {}
    for _, device in ipairs(self.order or {}) do
        local api = self.devices[device]
        if api then
            for _, side in ipairs(RedstoneIO.SIDES) do
                if bundledSides[RedstoneIO.sideKey(device, side)] then
                    pcall(api.setBundledOutput, side, 0)
                else
                    pcall(api.setOutput, side, false)
                end
            end
        end
    end
end

return RedstoneIO
