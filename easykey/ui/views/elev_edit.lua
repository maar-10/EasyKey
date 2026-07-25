--- The "define a lift" form on the elevator controller: its name, which elevator monitor
--- reports its position, and its two timings. A full-panel overlay.
---
--- Everything is done AT THE MONITOR: the name on an on-screen keyboard, the seconds on a
--- numeric keypad, the monitor from a dropdown of the addresses the SERVER has approved. The
--- controller never lets you type an address by hand — a monitor you invented is a monitor
--- that isn't approved, and it would silently never report.
---
--- The two timings, because they are easy to confuse:
---   Recall  - how long this lift refuses further calls after one is accepted. This is the
---             anti-double-tap lock, and it is what the pocket shows as "~Ns". Small.
---   Timeout - how long a call counts as outstanding before we stop waiting for the cabin to
---             report arriving. This only affects what the console says; it never holds
---             redstone. Roughly "how long the longest ride takes".
local Palette  = require("easykey.ui.palette")
local Keyboard = require("easykey.ui.keyboard")
local Keypad   = require("easykey.ui.keypad")

local ElevEdit = {}

local NO_MONITOR = "(none - wired to this PC)"

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
--- @param config table system config (for the numeric keypad)
function ElevEdit.build(parent, region, emit, config)
    local w, h = region.w, region.h
    local half = math.floor(w / 2)
    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = Palette.bg,
    })

    local state = { id = nil, name = "", monitor = nil,
                    recall = (config.elevator and config.elevator.recallSeconds) or 2,
                    timeout = (config.elevator and config.elevator.timeoutSeconds) or 20 }
    -- address -> label and back, so the dropdown can show fingerprints while we keep the
    -- full 44-char address
    local byLabel = {}
    local refreshLabels -- forward-declared: the overlays' callbacks close over it

    local function label(x, y, text)
        return root:addLabel({ x = x, y = y, text = text,
            foreground = Palette.dim, background = Palette.bg })
    end
    local function valueBtn(x, y, wdt)
        return root:addButton({ x = x, y = y, width = wdt, height = 1,
            text = "", background = Palette.normalBg, foreground = Palette.onNormal })
    end

    local title = root:addLabel({ x = 1, y = 1, text = "New lift",
        foreground = Palette.accent, background = Palette.bg })

    -- ----- name (opens the on-screen keyboard) -----
    label(1, 3, "Name")
    local nameBtn = root:addButton({ x = 1, y = 4, width = w - 1, height = 1,
        text = "", background = colors.gray, foreground = colors.white })

    -- ----- the elevator monitor (dropdown of server-approved addresses) -----
    label(1, 6, "Position monitor")
    local monDD = root:addDropDown({
        x = 1, y = 7, width = w - 1, height = 1, dropdownHeight = math.min(6, h - 12),
        background = colors.gray, foreground = colors.white,
        selectedText = NO_MONITOR,
        selectedBackground = Palette.selected, selectedForeground = colors.white,
    })
    monDD:onSelect(function(_, _, item)
        local text = (type(item) == "table") and item.text or item
        state.monitor = byLabel[text] -- nil for the "(none)" row
        refreshLabels()
    end)
    local monHint = label(1, 8, "")

    -- ----- timings -----
    label(1, 10, "Recall")
    local recallBtn = valueBtn(11, 10, w - 12)
    label(1, 11, "Timeout")
    local timeoutBtn = valueBtn(11, 11, w - 12)

    -- ----- save / cancel -----
    root:addButton({ x = 1, y = h - 2, width = half - 1, height = 3,
        text = "SAVE", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function()
        if state.name == nil or state.name == "" then emit("form_error", "give it a name"); return end
        -- "" rather than nil for "no monitor": an absent field means "leave it alone", so a nil
        -- here would make it impossible to ever un-set a monitor once one was chosen.
        emit("save_lift", { id = state.id, name = state.name, monitor = state.monitor or "",
            recall = state.recall, timeout = state.timeout })
    end)
    root:addButton({ x = half + 1, y = h - 2, width = w - half - 1, height = 3,
        text = "CANCEL", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() emit("cancel_form") end)

    -- ----- overlays -----
    local nameKb -- forward-declared: its own callbacks close over it
    nameKb = Keyboard.build(root, { x = 1, y = 1, w = w, h = h },
        { title = "Lift name (tap letters):", maxLen = 14,
          onSubmit = function(text) state.name = text; nameKb.hide(); refreshLabels() end,
          onCancel = function() nameKb.hide() end })
    nameKb.frame.set("z", 50) -- above the dropdown (z=8) and everything else

    -- revealed, numeric-only keypads for the two second values
    local numCfg = { keypad = {} }
    for k, v in pairs(config.keypad) do numCfg.keypad[k] = v end
    numCfg.keypad.mask = nil -- show the number as typed
    numCfg.keypad.maxLen = 4

    local recallKp
    recallKp = Keypad.build(root, { x = 1, y = 1, w = w, h = h }, numCfg, {
        title = "Recall lock seconds (0 = off):",
        onSubmit = function(v)
            local n = tonumber(v)
            if n and n >= 0 then state.recall = math.floor(n); recallKp.hide(); refreshLabels()
            else recallKp.setMessage("digits only", colors.orange) end
        end,
        onCancel = function() recallKp.hide() end,
    })
    recallKp.frame.set("z", 50)

    local timeoutKp
    timeoutKp = Keypad.build(root, { x = 1, y = 1, w = w, h = h }, numCfg, {
        title = "Call timeout seconds (min 1):",
        onSubmit = function(v)
            local n = tonumber(v)
            if n and n >= 1 then state.timeout = math.floor(n); timeoutKp.hide(); refreshLabels()
            else timeoutKp.setMessage("1 or more", colors.orange) end
        end,
        onCancel = function() timeoutKp.hide() end,
    })
    timeoutKp.frame.set("z", 50)

    refreshLabels = function()
        nameBtn:setText(state.name ~= "" and state.name or "(tap to name)")
        recallBtn:setText(state.recall > 0 and (state.recall .. "s") or "off")
        timeoutBtn:setText(state.timeout .. "s")
        -- Say what picking no monitor actually costs, since it is not obvious: without one you
        -- can still call floors from this PC's own redstone, you just never learn where the
        -- cabin is, so no floor ever lights up as "here".
        monHint:setText(state.monitor and "position reported by that PC"
            or "no position feedback")
        monHint:setForeground(state.monitor and Palette.dim or Palette.warn)
    end

    nameBtn:onClick(function() nameKb.show(state.name) end)
    recallBtn:onClick(function() recallKp.show() end)
    timeoutBtn:onClick(function() timeoutKp.show() end)

    local self = { frame = root }

    --- @param lift table|nil existing lift to edit, or nil for a new one
    --- @param monitorAddrs table array of approved monitor addresses to choose from
    function self.open(lift, monitorAddrs)
        state.id = lift and lift.id or nil
        state.name = (lift and lift.name) or ""
        state.monitor = lift and lift.monitor or nil
        state.recall = (lift and lift.recall)
            or (config.elevator and config.elevator.recallSeconds) or 2
        state.timeout = (lift and lift.timeout)
            or (config.elevator and config.elevator.timeoutSeconds) or 20
        title:setText(lift and ("Edit: " .. tostring(lift.name)) or "New lift")

        -- Fingerprints in the list, full addresses behind it. An operator compares 8
        -- characters against the monitor's own screen; nobody reads 44.
        byLabel = { [NO_MONITOR] = nil }
        local items = { { text = NO_MONITOR, selected = (state.monitor == nil) } }
        local keptSelection = (state.monitor == nil)
        for _, a in ipairs(monitorAddrs or {}) do
            local lbl = "monitor " .. tostring(a):sub(1, 8)
            byLabel[lbl] = a
            local sel = (a == state.monitor)
            if sel then keptSelection = true end
            items[#items + 1] = { text = lbl, selected = sel }
        end
        -- A lift whose monitor has since been revoked must not silently look unconfigured:
        -- keep the address, and show it as the missing thing it is.
        if not keptSelection and state.monitor then
            local lbl = "monitor " .. tostring(state.monitor):sub(1, 8) .. " (REVOKED)"
            byLabel[lbl] = state.monitor
            items[#items + 1] = { text = lbl, selected = true }
        end
        monDD.set("items", items)

        nameKb.hide(); recallKp.hide(); timeoutKp.hide()
        refreshLabels()
        root:setVisible(true)
    end

    function self.hide() root:setVisible(false) end

    -- ----- test seams -----
    function self.currentName() return state.name end
    function self.currentMonitor() return state.monitor end
    function self.currentRecall() return state.recall end
    function self.currentTimeout() return state.timeout end
    self.nameKb = nameKb
    self.recallKp = recallKp
    self.timeoutKp = timeoutKp

    root:setVisible(false)
    return self
end

return ElevEdit
