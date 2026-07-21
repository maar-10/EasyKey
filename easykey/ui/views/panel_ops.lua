--- The manual control PC's operations panel.
---
---   Controls - the buttons/switches a pocket sees. NEW / EDIT / DELETE, plus USE PANEL
---              (the operator's own copy of the panel, see below).
---   Outs     - every redstone channel this PC can reach (its sides, each wired relay's
---              sides, and the 16 colours of any side flipped to bundled).
---   Devices  - every pocket that has pinged this panel: distance and whether it's in
---              range / cleared.
---   Sessions - the pockets the SERVER currently has cleared (blue while any exist).
---
--- Pattern throughout: pick a row, press the action button. Built from Frames + Buttons +
--- RowList only, because Basalt's TabControl/List hit-test their children a row above
--- where they draw them, which makes rows unclickable on a monitor.
---
--- Colours mean the same thing here as on every other EasyKey screen (ui/palette.lua).
local RowList = require("easykey.ui.views.rowlist")
local Palette = require("easykey.ui.palette")

local PanelOps = {}

local function short(a) return tostring(a):sub(1, 8) end

--- A tiny text bar for a list row: "[####--]". Characters inside the row's own text (not a
--- ProgressBar element on top), so RowList's click-to-select behaviour is left untouched.
local function miniBar(remaining, total, cells)
    local frac = (total and total > 0) and math.max(0, math.min(1, (remaining or 0) / total)) or 0
    local filled = math.floor(frac * cells + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep("-", cells - filled) .. "]"
end

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
function PanelOps.build(parent, region, emit, config)
    local w, h = region.w, region.h
    local sessionTotal = (config and config.session_seconds) or 300
    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = Palette.bg,
    })

    local TABS = { "Controls", "Outs", "Devices", "Sessions" }
    local tabW = math.floor(w / #TABS)
    local tabButtons, panels = {}, {}
    local activeTab = 1
    local alerts = {}

    --- An inactive tab wearing its alert colour is how you notice something without
    --- opening every tab.
    local function paintTabs()
        for n = 1, #TABS do
            if n == activeTab then
                tabButtons[n]:setBackground(colors.white)
                tabButtons[n]:setForeground(colors.black)
            elseif alerts[n] then
                tabButtons[n]:setBackground(alerts[n])
                tabButtons[n]:setForeground(colors.black)
            else
                tabButtons[n]:setBackground(Palette.bar)
                tabButtons[n]:setForeground(Palette.text)
            end
        end
    end

    local function showTab(i)
        activeTab = i
        for n = 1, #TABS do panels[n]:setVisible(n == i) end
        paintTabs()
    end

    for i, name in ipairs(TABS) do
        tabButtons[i] = root:addButton({
            x = (i - 1) * tabW + 1, y = 1, width = tabW - 1, height = 1,
            text = name, background = Palette.bar, foreground = Palette.text,
        })
        tabButtons[i]:onClick(function() showTab(i) end)
    end

    local panelY, panelH = 2, h - 1
    for i = 1, #TABS do
        panels[i] = root:addFrame({
            x = 1, y = panelY, width = w, height = panelH, background = Palette.bg,
        })
    end

    local listH = panelH - 3   -- action buttons are 2-tall now, so lists get one more row
    local btnY = panelH - 1
    local self = {}

    -- =================== Controls ===================
    -- One row per control: name | what it does | what it's for. The target is NOT in the
    -- row - ids like "redstone_relay_3/left" are longer than the whole panel, and cramming
    -- them in is what chopped the names. It shows on the detail line for the selected row
    -- instead, which is when you actually care about the wiring.
    local ctrlRows = RowList.build(panels[1], { x = 1, y = 1, w = w, h = listH - 1 },
        { emptyText = "no controls yet - NEW" })
    local ctrlDetail = panels[1]:addLabel({
        x = 1, y = listH, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    local ctrlById, ctrlMissing = {}, {}

    local function showDetail(id)
        local c = ctrlById[id]
        if not c then ctrlDetail:setText(""); return end
        local target = c.target or "NO TARGET"
        -- A target can stop existing without the control changing (bundling a side
        -- redefines its channels), so say MISSING rather than show wiring that is gone.
        if c.target and ctrlMissing[id] then target = target .. " MISSING" end
        ctrlDetail:setText(("-> %s"):format(target):sub(1, w - 1))
        ctrlDetail:setForeground(ctrlMissing[id] and Palette.error or Palette.dim)
    end
    ctrlRows.onTap(showDetail)

    local quarter = math.floor(w / 4)
    panels[1]:addButton({
        x = 1, y = btnY, width = quarter - 1, height = 2,
        text = "NEW", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function() emit("new_control") end)
    panels[1]:addButton({
        x = quarter + 1, y = btnY, width = quarter - 1, height = 2,
        text = "EDIT", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function()
        local id = ctrlRows.selected()
        if id then emit("edit_control", id) else emit("need_selection", "a control") end
    end)
    panels[1]:addButton({
        x = quarter * 2 + 1, y = btnY, width = quarter - 1, height = 2,
        text = "DEL", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(function()
        local id = ctrlRows.selected()
        if id then emit("delete_control", id) else emit("need_selection", "a control") end
    end)
    -- The operator's own copy of the panel. This PC is as protected as the server, so it
    -- doesn't need a pocket session - it's the failsafe for when a pocket can't be used.
    panels[1]:addButton({
        x = quarter * 3 + 1, y = btnY, width = w - quarter * 3 - 1, height = 2,
        text = "USE", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() emit("use_panel") end)

    --- @param list table from Panel:snapshot()
    --- @param valid table|nil set of output ids that currently exist; a control aimed
    ---        outside it is wired to nothing and is flagged rather than looking normal
    function self.setControls(list, valid)
        local items = {}
        ctrlById, ctrlMissing = {}, {}
        -- The name gets whatever the fixed columns don't need, so it stops being chopped.
        -- Budget: RowList rows are (w-1) wide and it prepends one space of its own, so we
        -- have (w-2) to spend, and the trimmings cost 15:
        --   mark(1) + space(1) + name(N) + " | "(3) + type(3) + " | "(3) + use(4)
        local nameW = math.max(6, (w - 2) - 15)
        for _, c in ipairs(list or {}) do
            ctrlById[c.id] = c
            local missing = (not c.target) or (valid and not valid[c.target]) or false
            ctrlMissing[c.id] = missing
            items[#items + 1] = {
                key = c.id,
                text = ("%s %-" .. nameW .. "s | %-3s | %-4s"):format(
                    c.on and "\7" or " ",
                    tostring(c.name):sub(1, nameW),
                    (c.type == "switch" and "sw") or (c.type == "latch" and "lat") or "btn",
                    (c.use == "elevator") and "lift" or "gate"),
                -- wiring that goes nowhere is an error you should fix, and it outranks
                -- "energised" - a control that can't drive anything isn't operational
                fg = missing and Palette.error or (c.on and Palette.ok or Palette.text),
            }
        end
        ctrlRows.set(items)
        showDetail(ctrlRows.selected())
    end

    -- =================== Outs ===================
    -- Every redstone channel this PC can reach: its own sides, every wired relay's sides,
    -- and - once you bundle a side - that side's 16 colours. Bundling is opt-in per side
    -- because listing 16 colours for all 6 sides of every device would be ~100 rows to
    -- scroll before you found anything.
    local outRows = RowList.build(panels[2], { x = 1, y = 1, w = w, h = listH - 1 },
        { emptyText = "no redstone found" })
    panels[2]:addLabel({
        x = 1, y = listH, text = "tap a side -> BUNDLE = 16 IE colours",
        foreground = Palette.dim, background = Palette.bg,
    })
    panels[2]:addButton({
        x = 1, y = btnY, width = w - 1, height = 2,
        text = "BUNDLE / UNBUNDLE SIDE",
        background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function()
        local id = outRows.selected()
        if id then emit("toggle_bundled", id) else emit("need_selection", "an output") end
    end)

    --- @param list table array of { id, on }
    function self.setOutputs(list)
        local items = {}
        for _, o in ipairs(list or {}) do
            items[#items + 1] = {
                key = o.id,
                text = ("%s %s"):format(o.on and "\7" or " ", o.id),
                fg = o.on and Palette.ok or Palette.dim,
            }
        end
        outRows.set(items)
    end

    function self.selectedOutput() return outRows.selected() end

    -- =================== Devices ===================
    local devRows = RowList.build(panels[3], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "no pockets seen" })
    local rangeLabel = panels[3]:addLabel({
        x = 1, y = listH + 1, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    panels[3]:addButton({
        x = 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "RANGE", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() emit("edit_range") end)
    panels[3]:addButton({
        x = math.floor(w / 2) + 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "GRACE", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() emit("edit_grace") end)

    --- Every pocket this panel has heard from, cleared or not.
    --- @param list table from Panel:pockets()
    function self.setDevices(list, range, grace)
        local items = {}
        for _, p in ipairs(list or {}) do
            local state, fg
            if not p.inRange then
                state, fg = "far", Palette.muted
            elseif p.secure then
                state, fg = "CLEARED", Palette.ok
            else
                state, fg = "denied", Palette.warn
            end
            items[#items + 1] = {
                key = p.address,
                text = ("%-8s %4.0fm %s"):format(short(p.address), p.distance, state),
                fg = fg,
            }
        end
        devRows.set(items)
        rangeLabel:setText(("range %d   grace %ds"):format(range or 0, grace or 0))
    end

    -- =================== Sessions ===================
    local sesRows = RowList.build(panels[4], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "nobody is cleared" })

    --- The server's secure-set: who is cleared right now (whether or not they're nearby).
    --- @param list table array of { address, remaining }
    function self.setSessions(list)
        local items = {}
        for _, s in ipairs(list or {}) do
            items[#items + 1] = {
                key = s.address,
                text = ("%-8s %s %3ds"):format(
                    short(s.address), miniBar(s.remaining or 0, sessionTotal, 6), s.remaining or 0),
                fg = Palette.ok,
            }
        end
        sesRows.set(items)
    end

    --- Light a tab up (or clear it).
    function self.setAlert(name, colour)
        for i, n in ipairs(TABS) do
            if n == name then alerts[i] = colour; paintTabs(); return true end
        end
        return false
    end

    self.root = root -- so the app can hide the tabs behind an overlay
    self.showTab = showTab
    self.tabNames = TABS
    self.rows = { controls = ctrlRows, outputs = outRows, devices = devRows, sessions = sesRows }
    showTab(1)
    return self
end

return PanelOps
