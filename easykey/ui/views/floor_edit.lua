--- The "define a floor" form on the elevator controller: its name and its two redstone
--- channels. A full-panel overlay.
---
--- A Create Elevator Contact gives us exactly two hooks, and this form is those two hooks:
---   Call output   - pulsed to summon the cabin to this floor. Required; a floor without one
---                   is a button that cannot do anything, and the Floors list paints it red.
---   Arrival input - the signal the contact emits while the cabin is stopped here. Optional,
---                   but without it nothing can ever light up as "the cabin is here".
---
--- Both dropdowns list this computer's channels AND the lift monitor's, in one place, because
--- from the operator's point of view there is no difference: pick the channel the wire is on.
--- A "mon:" prefix means it lives on the monitor and the pulse rides an encrypted message
--- instead of a wire. If the monitor hasn't reported its channels yet (or the lift has none),
--- only the local ones appear, and the form says so rather than looking mysteriously short.
local Palette  = require("easykey.ui.palette")
local Keyboard = require("easykey.ui.keyboard")

local FloorEdit = {}

local NO_INPUT = "(none - no position feedback)"

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
function FloorEdit.build(parent, region, emit)
    local w, h = region.w, region.h
    local half = math.floor(w / 2)
    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = Palette.bg,
    })

    local state = { id = nil, name = "", call = nil, at = nil }
    local refreshLabels -- forward-declared: the keyboard's callback closes over it

    local function label(x, y, text)
        return root:addLabel({ x = x, y = y, text = text,
            foreground = Palette.dim, background = Palette.bg })
    end

    local title = root:addLabel({ x = 1, y = 1, text = "New floor",
        foreground = Palette.accent, background = Palette.bg })

    -- ----- name -----
    label(1, 3, "Name (shown on the pocket)")
    local nameBtn = root:addButton({ x = 1, y = 4, width = w - 1, height = 1,
        text = "", background = colors.gray, foreground = colors.white })

    -- ----- call output -----
    label(1, 6, "Call output (pulse = come here)")
    local callDD = root:addDropDown({
        x = 1, y = 7, width = w - 1, height = 1, dropdownHeight = math.min(8, math.max(3, h - 18)),
        background = colors.gray, foreground = colors.white,
        selectedText = "(pick a channel)",
        selectedBackground = Palette.selected, selectedForeground = colors.white,
    })
    -- The call list must sit above the arrival list when open; the arrival list expands well
    -- below this row, so a closed call dropdown never steals its taps.
    callDD.set("z", 9)
    callDD:onSelect(function(_, _, item)
        state.call = (type(item) == "table") and item.text or item
        refreshLabels()
    end)

    -- ----- arrival input -----
    label(1, 9, "Arrival input (cabin is here)")
    local atDD = root:addDropDown({
        x = 1, y = 10, width = w - 1, height = 1, dropdownHeight = math.min(8, math.max(3, h - 18)),
        background = colors.gray, foreground = colors.white,
        selectedText = NO_INPUT,
        selectedBackground = Palette.selected, selectedForeground = colors.white,
    })
    atDD.set("z", 8)
    atDD:onSelect(function(_, _, item)
        local text = (type(item) == "table") and item.text or item
        state.at = (text ~= NO_INPUT) and text or nil
        refreshLabels()
    end)

    local hint = label(1, 12, "")

    -- ----- save / cancel -----
    root:addButton({ x = 1, y = h - 2, width = half - 1, height = 3,
        text = "SAVE", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function()
        if state.name == nil or state.name == "" then emit("form_error", "give it a name"); return end
        if not state.call then emit("form_error", "pick a call output"); return end
        emit("save_floor", { id = state.id, name = state.name, call = state.call,
            at = state.at or "" })
    end)
    root:addButton({ x = half + 1, y = h - 2, width = w - half - 1, height = 3,
        text = "CANCEL", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() emit("cancel_form") end)

    -- ----- overlay: the on-screen keyboard -----
    local nameKb -- forward-declared: its own callbacks close over it
    nameKb = Keyboard.build(root, { x = 1, y = 1, w = w, h = h },
        { title = "Floor name (tap letters):", maxLen = 12,
          onSubmit = function(text) state.name = text; nameKb.hide(); refreshLabels() end,
          onCancel = function() nameKb.hide() end })
    nameKb.frame.set("z", 50) -- above both dropdowns

    local monCount = 0
    refreshLabels = function()
        nameBtn:setText(state.name ~= "" and state.name or "(tap to name)")
        -- Two different "you are missing something" cases, and they matter differently.
        if not state.at then
            hint:setText("no arrival input: floor never lights up")
            hint:setForeground(Palette.warn)
        elseif monCount == 0 then
            hint:setText("monitor has not reported channels yet")
            hint:setForeground(Palette.dim)
        else
            hint:setText("mon: = on the lift's monitor")
            hint:setForeground(Palette.dim)
        end
    end

    nameBtn:onClick(function() nameKb.show(state.name) end)

    local self = { frame = root }

    --- @param floor table|nil existing floor to edit, or nil for a new one
    --- @param channels table array of channel id strings (local ids, plus "mon:<id>" ones)
    function self.open(floor, channels)
        state.id = floor and floor.id or nil
        state.name = (floor and floor.name) or ""
        state.call = floor and floor.call or nil
        state.at = floor and floor.at or nil
        title:setText(floor and ("Edit: " .. tostring(floor.name)) or "New floor")

        monCount = 0
        local callItems, atItems = {}, { { text = NO_INPUT, selected = (state.at == nil) } }
        local sawCall, sawAt = false, false
        for _, id in ipairs(channels or {}) do
            if tostring(id):sub(1, 4) == "mon:" then monCount = monCount + 1 end
            if id == state.call then sawCall = true end
            if id == state.at then sawAt = true end
            callItems[#callItems + 1] = { text = id, selected = (id == state.call) }
            atItems[#atItems + 1] = { text = id, selected = (id == state.at) }
        end
        -- A channel can stop existing without this floor being touched: bundling a side
        -- redefines it, and a revoked monitor takes all of its channels away. Keep the value
        -- and show it as missing, so EDIT can never silently blank the wiring.
        if state.call and not sawCall then
            callItems[#callItems + 1] = { text = state.call, selected = true }
        end
        if state.at and not sawAt then
            atItems[#atItems + 1] = { text = state.at, selected = true }
        end
        callDD.set("items", callItems)
        atDD.set("items", atItems)

        nameKb.hide()
        refreshLabels()
        root:setVisible(true)
    end

    function self.hide() root:setVisible(false) end

    -- ----- test seams -----
    function self.currentName() return state.name end
    function self.currentCall() return state.call end
    function self.currentAt() return state.at end
    self.nameKb = nameKb

    root:setVisible(false)
    return self
end

return FloorEdit
