--- The "define a control" form on the manual PC: name, what it does, what it's for, its
--- fallback/invert/cooldown options, and which redstone output it drives. A full-panel overlay.
---
--- Everything is done AT THE MONITOR now: the name is typed on an on-screen keyboard, the
--- cooldown seconds on a numeric keypad, and the target is picked from a dropdown. No more
--- typing blind on the PC's keyboard.
---
--- type = button (momentary) | switch (a held level) | latch (a pulse that remembers a
---        state, for a Create toggle latch). switch + latch carry `invert` (which flips the
---        red/green open/closed reading) + `fallback`. Cooldown applies to every type.
--- use  = gate | elevator -> which pocket tab it shows on.
local Palette  = require("easykey.ui.palette")
local Keyboard = require("easykey.ui.keyboard")
local Keypad   = require("easykey.ui.keypad")

local PanelEdit = {}

local TYPES        = { "button", "switch", "latch" }
local FALLBACKS    = { "off", "on", "hold" }
local FALLBACK_LBL = { off = "OFF", on = "ON", hold = "HOLD" }

--- Next value after `cur` in `list`, wrapping.
local function nextIn(list, cur)
    for i, v in ipairs(list) do
        if v == cur then return list[(i % #list) + 1] end
    end
    return list[1]
end

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
--- @param config table system config (for the numeric keypad)
function PanelEdit.build(parent, region, emit, config)
    local w, h = region.w, region.h
    local half = math.floor(w / 2)
    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = Palette.bg,
    })

    local state = { id = nil, name = "", type = "button", use = "gate",
                    fallback = "off", invert = false, cooldown = 0, target = nil }
    local refreshLabels -- forward-declared: the overlays' callbacks close over it

    local function label(x, y, text)
        return root:addLabel({ x = x, y = y, text = text,
            foreground = Palette.dim, background = Palette.bg })
    end
    local function valueBtn(x, y, wdt)
        return root:addButton({ x = x, y = y, width = wdt, height = 1,
            text = "", background = Palette.normalBg, foreground = Palette.onNormal })
    end

    local title = root:addLabel({ x = 1, y = 1, text = "New control",
        foreground = Palette.accent, background = Palette.bg })

    -- ----- name (opens the on-screen keyboard) -----
    label(1, 3, "Name")
    local nameBtn = root:addButton({ x = 1, y = 4, width = w - 1, height = 1,
        text = "", background = colors.gray, foreground = colors.white })

    -- ----- type / use (side by side, labelled) -----
    label(1, 6, "Type")
    local typeBtn = valueBtn(1, 7, half - 1)
    label(half + 1, 6, "Use")
    local useBtn = valueBtn(half + 1, 7, w - half - 1)

    -- ----- switch/latch: fallback + invert (flips red/green); cooldown applies to everything --
    local fbLabel = label(1, 9, "Fallback")
    local fallbackBtn = valueBtn(11, 9, w - 12)
    local invLabel = label(1, 10, "Invert")
    local invertBtn = valueBtn(11, 10, w - 12)
    label(1, 11, "Cooldown")
    local cdBtn = valueBtn(11, 11, w - 12)

    -- ----- target output (dropdown) -----
    label(1, 13, "Target output")
    local targetDD = root:addDropDown({
        x = 1, y = 14, width = w - 1, height = 1, dropdownHeight = math.min(6, h - 17),
        background = colors.gray, foreground = colors.white,
        selectedText = "(pick an output)",
        selectedBackground = Palette.selected, selectedForeground = colors.white,
    })
    targetDD:onSelect(function(_, _, item)
        if type(item) == "table" then state.target = item.text else state.target = item end
    end)

    -- ----- save / cancel -----
    root:addButton({ x = 1, y = h - 2, width = half - 1, height = 3,
        text = "SAVE", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function()
        if state.name == nil or state.name == "" then emit("form_error", "give it a name"); return end
        if not state.target then emit("form_error", "pick a target output"); return end
        emit("save_control", { id = state.id, name = state.name, type = state.type,
            use = state.use, target = state.target, fallback = state.fallback,
            invert = state.invert, cooldown = state.cooldown })
    end)
    root:addButton({ x = half + 1, y = h - 2, width = w - half - 1, height = 3,
        text = "CANCEL", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() emit("cancel_form") end)

    -- ----- overlays: on-screen keyboard (name) + numeric keypad (bar) -----
    local nameKb -- forward-declared: its own callbacks close over it
    nameKb = Keyboard.build(root, { x = 1, y = 1, w = w, h = h },
        { title = "Name (tap letters):", maxLen = 18,
          onSubmit = function(text) state.name = text; nameKb.hide(); refreshLabels() end,
          onCancel = function() nameKb.hide() end })
    nameKb.frame.set("z", 50) -- above the dropdown (z=8) and everything else

    -- a revealed, numeric-only keypad for the cooldown seconds (0 = off)
    local cdCfg = { keypad = {} }
    for k, v in pairs(config.keypad) do cdCfg.keypad[k] = v end
    cdCfg.keypad.mask = nil   -- show the number as typed
    cdCfg.keypad.maxLen = 4
    local cdKp -- forward-declared: its own callbacks close over it
    cdKp = Keypad.build(root, { x = 1, y = 1, w = w, h = h }, cdCfg, {
        title = "Cooldown seconds (0 = off):",
        onSubmit = function(v)
            local n = tonumber(v)
            if n and n >= 0 then state.cooldown = math.floor(n); cdKp.hide(); refreshLabels()
            else cdKp.setMessage("digits only", colors.orange) end
        end,
        onCancel = function() cdKp.hide() end,
    })
    cdKp.frame.set("z", 50)

    refreshLabels = function()
        local stateful = (state.type == "switch" or state.type == "latch")
        nameBtn:setText(state.name ~= "" and state.name or "(tap to name)")
        typeBtn:setText(state.type)
        useBtn:setText(state.use)
        fbLabel:setVisible(stateful); invLabel:setVisible(stateful)
        fallbackBtn:setVisible(stateful); fallbackBtn:setText(FALLBACK_LBL[state.fallback] or "OFF")
        invertBtn:setVisible(stateful);   invertBtn:setText(state.invert and "on" or "off")
        cdBtn:setText(state.cooldown > 0 and (state.cooldown .. "s") or "off")
    end

    nameBtn:onClick(function() nameKb.show(state.name) end)
    typeBtn:onClick(function() state.type = nextIn(TYPES, state.type); refreshLabels() end)
    useBtn:onClick(function()
        state.use = (state.use == "gate") and "elevator" or "gate"; refreshLabels()
    end)
    fallbackBtn:onClick(function() state.fallback = nextIn(FALLBACKS, state.fallback); refreshLabels() end)
    invertBtn:onClick(function() state.invert = not state.invert; refreshLabels() end)
    cdBtn:onClick(function() cdKp.show() end)

    local self = { frame = root }

    --- @param control table|nil existing control to edit, or nil for a new one
    --- @param outputs table array of { id } to choose from
    function self.open(control, outputs)
        state.id = control and control.id or nil
        state.name = (control and control.name) or ""
        state.type = (control and control.type) or "button"
        state.use = (control and control.use) or "gate"
        state.fallback = (control and control.fallback) or "off"
        state.invert = (control and control.invert) or false
        state.cooldown = (control and control.cooldown) or 0
        state.target = control and control.target or nil
        title:setText(control and ("Edit: " .. tostring(control.name)) or "New control")

        local items = {}
        for _, o in ipairs(outputs or {}) do
            items[#items + 1] = { text = o.id, selected = (o.id == state.target) }
        end
        targetDD.set("items", items)

        nameKb.hide(); cdKp.hide()
        refreshLabels()
        root:setVisible(true)
    end

    function self.hide() root:setVisible(false) end

    -- ----- test seams -----
    function self.selectedTarget() return state.target end
    function self.currentName() return state.name end
    function self.currentCooldown() return state.cooldown end
    self.nameKb = nameKb
    self.cdKp = cdKp

    root:setVisible(false)
    return self
end

return PanelEdit
