--- The elevator controller's operations panel.
---
---   Lifts   - the elevators this PC drives. NEW / EDIT / DELETE, plus USE PANEL (the
---             operator's own copy of the floor buttons — the failsafe for when a pocket
---             can't be used).
---   Floors  - the floors of the lift selected on the Lifts tab: add, edit, delete, and
---             reorder them so the list matches the way the shaft is actually stacked.
---   Outs    - every redstone channel THIS computer can reach, showing both directions: OUT
---             is a call pulse we are driving, IN is an arrival contact reporting a cabin.
---             (A lift's monitor has its own channels; those are offered in the floor form.)
---   Devices - every pocket that has pinged this controller, and the range setting.
---
--- Same construction rules as every other EasyKey monitor screen: Frames + Buttons + RowList
--- only, never Basalt's TabControl/List, because those hit-test their children a row above
--- where they draw them and 1-tall list rows become unclickable (see ui/views/rowlist.lua).
---
--- Colours mean what they mean everywhere else in EasyKey (ui/palette.lua). Here that is:
--- green = the cabin is there, blue = idle and healthy, red = wired to nothing.
local RowList = require("easykey.ui.views.rowlist")
local Palette = require("easykey.ui.palette")

local ElevOps = {}

local function short(a) return tostring(a):sub(1, 8) end

--- A tiny text bar for a list row: "[####--]". Characters inside the row's own text (not a
--- ProgressBar element on top), so RowList's click-to-select behaviour is left untouched.
local function miniBar(remaining, total, cells)
    local frac = (total and total > 0) and math.max(0, math.min(1, (remaining or 0) / total)) or 0
    local filled = math.floor(frac * cells + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep("-", cells - filled) .. "]"
end

--- Where a channel lives, in three characters. The full id goes on the detail line — ids like
--- "mon:redstone_relay_3/right:pink" are longer than the whole panel.
local function whereOf(channel)
    if not channel or channel == "" then return "---" end
    if tostring(channel):sub(1, 4) == "mon:" then return "mon" end
    return "loc"
end

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
--- @param config table system config
function ElevOps.build(parent, region, emit, config)
    local w, h = region.w, region.h
    local sessionTotal = (config and config.timing and config.timing.session_seconds) or 300
    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = Palette.bg,
    })

    local TABS = { "Lifts", "Floors", "Outs", "Devices" }
    local tabW = math.floor(w / #TABS)
    local tabButtons, panels = {}, {}
    local activeTab = 1
    local alerts = {}

    --- An inactive tab wearing its alert colour is how you notice something without opening
    --- every tab.
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

    local listH = panelH - 3   -- one row of 2-tall action buttons
    local btnY = panelH - 1
    local quarter = math.floor(w / 4)
    local self = {}

    -- =================== Lifts ===================
    local liftRows = RowList.build(panels[1], { x = 1, y = 1, w = w, h = listH - 1 },
        { emptyText = "no lifts yet - NEW" })
    local liftDetail = panels[1]:addLabel({
        x = 1, y = listH, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    local liftById = {}

    local function showLiftDetail(id)
        local l = liftById[id]
        if not l then liftDetail:setText(""); return end
        local bits = {}
        bits[#bits + 1] = l.monitor and ("mon " .. short(l.monitor)) or "no monitor"
        bits[#bits + 1] = tostring(l.floors) .. "fl"
        bits[#bits + 1] = "at " .. (l.at or "?")
        if l.calling then bits[#bits + 1] = "-> " .. l.calling end
        liftDetail:setText(table.concat(bits, "  "):sub(1, w - 1))
        -- A lift that calls through a monitor it hasn't got can never move; that is a wiring
        -- error, not an idle state.
        liftDetail:setForeground(l.needsMonitor and Palette.error or Palette.dim)
    end
    -- Selecting a lift is also what the Floors tab is about, so tell the program at once
    -- rather than making the operator press something else first.
    liftRows.onTap(function(id) showLiftDetail(id); emit("select_lift", id) end)

    panels[1]:addButton({
        x = 1, y = btnY, width = quarter - 1, height = 2,
        text = "NEW", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function() emit("new_lift") end)
    panels[1]:addButton({
        x = quarter + 1, y = btnY, width = quarter - 1, height = 2,
        text = "EDIT", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function()
        local id = liftRows.selected()
        if id then emit("edit_lift", id) else emit("need_selection", "a lift") end
    end)
    panels[1]:addButton({
        x = quarter * 2 + 1, y = btnY, width = quarter - 1, height = 2,
        text = "DEL", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(function()
        local id = liftRows.selected()
        if id then emit("delete_lift", id) else emit("need_selection", "a lift") end
    end)
    panels[1]:addButton({
        x = quarter * 3 + 1, y = btnY, width = w - quarter * 3 - 1, height = 2,
        text = "USE", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() emit("use_panel") end)

    --- @param list table from Elevator:snapshot()
    function self.setLifts(list)
        local items = {}
        liftById = {}
        -- Budget: RowList rows are (w-1) wide and prepend one space, leaving (w-2). The fixed
        -- columns cost 14: mark(1) sp(1) name(N) " | "(3) "99fl"(4) " "(1) at(4)
        local nameW = math.max(6, (w - 2) - 14)
        for _, l in ipairs(list or {}) do
            liftById[l.id] = l
            local fg = Palette.text
            if l.needsMonitor then fg = Palette.error   -- calls a monitor it hasn't got
            elseif l.at then fg = Palette.ok            -- the cabin is at a known floor
            elseif l.calling then fg = Palette.normal end
            items[#items + 1] = {
                key = l.id,
                text = ("%s %-" .. nameW .. "s | %2dfl %-4s"):format(
                    l.at and "\7" or (l.calling and "\26" or " "),
                    tostring(l.name):sub(1, nameW),
                    l.floors or 0,
                    tostring(l.at or "-"):sub(1, 4)),
                fg = fg,
            }
        end
        liftRows.set(items)
        showLiftDetail(liftRows.selected())
    end

    function self.selectedLift() return liftRows.selected() end
    function self.selectLift(id) return liftRows.select(id) end

    -- =================== Floors ===================
    -- Two rows of action buttons here, because reordering needs its own pair and cramming six
    -- buttons into one row leaves them too narrow to label.
    local floorTitle = panels[2]:addLabel({
        x = 1, y = 1, text = "pick a lift on the Lifts tab",
        foreground = Palette.accent, background = Palette.bg,
    })
    local listH2 = math.max(3, panelH - 7)
    local floorRows = RowList.build(panels[2], { x = 1, y = 2, w = w, h = listH2 },
        { emptyText = "no floors yet - NEW" })
    -- Two detail lines, one per direction. They were one line, and a floor wired to a monitor
    -- lost its arrival channel off the end: "call mon:self/back | at mon:self/left" is 39
    -- characters and the panel is 36 wide, so the thing you were checking was the thing cut off.
    local floorCallLine = panels[2]:addLabel({
        x = 1, y = listH2 + 2, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    local floorAtLine = panels[2]:addLabel({
        x = 1, y = listH2 + 3, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    local floorById = {}
    local rowAY, rowBY = panelH - 3, panelH - 1
    local third = math.floor(w / 3)
    local halfW = math.floor(w / 2)

    local function showFloorDetail(id)
        local f = floorById[id]
        if not f then floorCallLine:setText(""); floorAtLine:setText(""); return end
        local call = f.call or "NO CALL OUTPUT"
        if f.call and f.callMissing then call = call .. " MISSING" end
        local at = f.at or "no arrival input"
        if f.at and f.atMissing then at = at .. " MISSING" end
        floorCallLine:setText(("call " .. call):sub(1, w - 1))
        floorAtLine:setText(("at   " .. at):sub(1, w - 1))
        floorCallLine:setForeground((f.callMissing or not f.call) and Palette.error or Palette.dim)
        floorAtLine:setForeground(f.atMissing and Palette.error or Palette.dim)
    end
    floorRows.onTap(showFloorDetail)

    panels[2]:addButton({
        x = 1, y = rowAY, width = third - 1, height = 2,
        text = "NEW", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(function() emit("new_floor") end)
    panels[2]:addButton({
        x = third + 1, y = rowAY, width = third - 1, height = 2,
        text = "EDIT", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function()
        local id = floorRows.selected()
        if id then emit("edit_floor", id) else emit("need_selection", "a floor") end
    end)
    panels[2]:addButton({
        x = third * 2 + 1, y = rowAY, width = w - third * 2 - 1, height = 2,
        text = "DEL", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(function()
        local id = floorRows.selected()
        if id then emit("delete_floor", id) else emit("need_selection", "a floor") end
    end)
    panels[2]:addButton({
        x = 1, y = rowBY, width = halfW - 1, height = 2,
        text = "MOVE UP", background = Palette.bar, foreground = Palette.text,
    }):onClick(function()
        local id = floorRows.selected()
        if id then emit("move_floor", { id = id, delta = -1 }) else emit("need_selection", "a floor") end
    end)
    panels[2]:addButton({
        x = halfW + 1, y = rowBY, width = w - halfW - 1, height = 2,
        text = "MOVE DOWN", background = Palette.bar, foreground = Palette.text,
    }):onClick(function()
        local id = floorRows.selected()
        if id then emit("move_floor", { id = id, delta = 1 }) else emit("need_selection", "a floor") end
    end)

    --- @param liftName string|nil the lift these floors belong to
    --- @param list table from Elevator:floorRows(), each row also carrying
    ---        callMissing/atMissing (a channel that has stopped existing)
    function self.setFloors(liftName, list)
        floorTitle:setText(liftName and ("Floors of " .. liftName):sub(1, w - 1)
            or "pick a lift on the Lifts tab")
        local items = {}
        floorById = {}
        -- mark(1) sp(1) name(N) " | "(3) "loc"(3) " "(1) "loc"(3) = 12
        local nameW = math.max(5, (w - 2) - 12)
        for _, f in ipairs(list or {}) do
            floorById[f.id] = f
            local broken = (not f.call) or f.callMissing or f.atMissing
            local fg = Palette.text
            if broken then fg = Palette.error       -- wired to nothing: not operational
            elseif f.isAt then fg = Palette.ok      -- the cabin is here
            elseif f.isCalling then fg = Palette.normal end
            items[#items + 1] = {
                key = f.id,
                text = ("%s %-" .. nameW .. "s | %-3s %-3s"):format(
                    f.isAt and "\7" or (f.isCalling and "\26" or " "),
                    tostring(f.name):sub(1, nameW),
                    whereOf(f.call), whereOf(f.at)),
                fg = fg,
            }
        end
        floorRows.set(items)
        showFloorDetail(floorRows.selected())
    end

    function self.selectedFloor() return floorRows.selected() end

    -- =================== Outs ===================
    -- Both directions on one row, because wiring a lift means watching both: you pulse an
    -- output to call the cabin and read an input to know it arrived.
    local outRows = RowList.build(panels[3], { x = 1, y = 1, w = w, h = listH - 1 },
        { emptyText = "no redstone found" })
    panels[3]:addLabel({
        x = 1, y = listH, text = "I=arrival in  O=call out  BUNDLE=16 IE",
        foreground = Palette.dim, background = Palette.bg,
    })
    panels[3]:addButton({
        x = 1, y = btnY, width = w - 1, height = 2,
        text = "BUNDLE / UNBUNDLE SIDE",
        background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function()
        local id = outRows.selected()
        if id then emit("toggle_bundled", id) else emit("need_selection", "a channel") end
    end)

    --- @param list table array of { id, input, output }
    function self.setOutputs(list)
        local items = {}
        for _, o in ipairs(list or {}) do
            local fg = Palette.dim
            if o.input then fg = Palette.ok        -- a cabin is sitting on this contact
            elseif o.output then fg = Palette.normal end
            items[#items + 1] = {
                key = o.id,
                text = ("%s%s %s"):format(o.input and "I" or " ", o.output and "O" or " ", o.id),
                fg = fg,
            }
        end
        outRows.set(items)
    end

    -- =================== Devices ===================
    -- Pockets and sessions share this tab: on a lift controller there is nothing to do to a
    -- session except see it, and four tabs already fill the strip.
    local devRows = RowList.build(panels[4], { x = 1, y = 1, w = w, h = listH - 2 },
        { emptyText = "no pockets seen" })
    local sesLabel = panels[4]:addLabel({
        x = 1, y = listH - 1, text = "", foreground = Palette.ok, background = Palette.bg,
    })
    local rangeLabel = panels[4]:addLabel({
        x = 1, y = listH, text = "", foreground = Palette.dim, background = Palette.bg,
    })
    panels[4]:addButton({
        x = 1, y = btnY, width = w - 1, height = 2,
        text = "RANGE", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() emit("edit_range") end)

    --- @param list table from Elevator:pockets()
    --- @param sessions table from Elevator:sessions()
    function self.setDevices(list, sessions, range)
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

        local n = #(sessions or {})
        if n == 0 then
            sesLabel:setText("nobody is cleared"); sesLabel:setForeground(Palette.muted)
        else
            local s = sessions[1]
            sesLabel:setText(("%d cleared  %s %3ds"):format(
                n, miniBar(s.remaining or 0, sessionTotal, 6), s.remaining or 0))
            sesLabel:setForeground(Palette.ok)
        end
        rangeLabel:setText(("range %d blocks"):format(range or 0))
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
    self.rows = { lifts = liftRows, floors = floorRows, outputs = outRows, devices = devRows }
    showTab(1)
    return self
end

return ElevOps
