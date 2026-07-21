--- The control PC's terminal UI.
---
--- Deliberately a plain console, not Basalt: a control PC is a normal computer with no
--- mouse, so everything here is keyboard-driven and it stays cheap to build one per door
--- area. The top three lines are unchanged from the version that was verified in-game
--- (role, server link, own fingerprint + nearby count); everything below is the output
--- list.
---
--- Text entry (name/range) is handled as a small state machine rather than by calling
--- read(): read() would block this coroutine and swallow the presence pings arriving
--- meanwhile, so a door could stall mid-rename. Here, typing never stops the doors.
local ControlConsole = {}

local TYPE_COLOR = {
    off    = colors.gray,
    toggle = colors.lime,
    press  = colors.cyan,
}

--- @param opts table { title = string }
function ControlConsole.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = ControlConsole })
    self.sel = 1
    self.scroll = 0
    self.editing = nil   -- nil | { field = "name"|"range", buffer = string }
    self.message = nil
    return self
end

--- Show a transient hint (e.g. why a key press did nothing).
function ControlConsole:say(text) self.message = text end

--- Clamp the selection and keep it on screen.
function ControlConsole:_clamp(rowCount, rows)
    if self.sel < 1 then self.sel = 1 end
    if self.sel > rowCount then self.sel = math.max(1, rowCount) end
    if self.sel <= self.scroll then self.scroll = self.sel - 1 end
    if self.sel > self.scroll + rows then self.scroll = self.sel - rows end
    if self.scroll < 0 then self.scroll = 0 end
end

--- Draw everything.
--- @param st table {
---   serverFp, serverUp, myFp, nearby,   -- the three header lines
---   rows,                                -- from Outputs:snapshot()
---   feedback,                            -- id -> bool, read back from the hardware
---   bundledSides,                        -- sideKey -> true
--- }
function ControlConsole:draw(st)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    local w, h = term.getSize()

    -- ---- the three header lines (unchanged) ----
    term.setTextColor(colors.cyan); print("EasyKey Door Control")
    term.setTextColor(st.serverUp and colors.lime or colors.red)
    print("server " .. tostring(st.serverFp) .. ": " .. (st.serverUp and "OK" or "DOWN")
        .. (st.approved and "" or " (awaiting approval)"))
    term.setTextColor(colors.lightGray)
    print("me: " .. tostring(st.myFp) .. "   nearby: " .. tostring(st.nearby))

    -- ---- controls help ----
    term.setTextColor(colors.gray)
    print("up/dn sel  t:type  n:name  r:range  b:bundle")

    -- ---- column header ----
    term.setTextColor(colors.white)
    print(("%-20s %-6s %4s %s"):format("OUTPUT", "TYPE", "RNG", "RS"))

    local headerRows = 5
    local footRows = self.editing and 2 or (self.message and 1 or 0)
    local rows = h - headerRows - footRows
    local list = st.rows or {}
    self:_clamp(#list, rows)

    if #list == 0 then
        term.setTextColor(colors.gray)
        print(" (no redstone outputs found)")
    end

    for i = self.scroll + 1, math.min(#list, self.scroll + rows) do
        local o = list[i]
        local selected = (i == self.sel)
        -- Show what the HARDWARE reports, not what we asked for: a failed write shows up.
        local live = st.feedback and st.feedback[o.id]
        local label = (o.name ~= "" and o.name ~= nil) and o.name or o.id
        term.setTextColor(selected and colors.yellow or TYPE_COLOR[o.type] or colors.white)
        local line = ("%s%-19s %-6s %4d %s"):format(
            selected and ">" or " ",
            label:sub(1, 19),
            o.type,
            o.range,
            live and "ON" or "..")
        print(line)
    end

    -- ---- the selected row's id, so a renamed output is still identifiable ----
    local cur = list[self.sel]
    if cur and (cur.name ~= "" and cur.name ~= nil) then
        term.setTextColor(colors.gray)
        local _, cy = term.getCursorPos()
        if cy <= h then term.write(" id: " .. cur.id:sub(1, w - 6)) end
    end

    -- ---- editor / message footer ----
    if self.editing then
        term.setCursorPos(1, h)
        term.setBackgroundColor(colors.gray); term.clearLine()
        term.setTextColor(colors.white)
        term.write((self.editing.field == "name" and "Name: " or "Range: ") .. self.editing.buffer .. "_")
        term.setBackgroundColor(colors.black)
    elseif self.message then
        term.setCursorPos(1, h)
        term.setTextColor(colors.orange); term.clearLine()
        term.write(self.message:sub(1, w))
    end
end

--- Handle a key/char event. Returns an action table for the caller to apply, or nil.
---   { kind = "type" }                 cycle the selected output's type
---   { kind = "bundle" }               flip the selected side between plain and bundled
---   { kind = "name",  value = "..." } commit a new name
---   { kind = "range", value = 4 }     commit a new range
---   { kind = "redraw" }               selection moved / editing state changed
--- @param event string "key" or "char"
function ControlConsole:onInput(event, p1, rowCount)
    -- ----- text entry mode -----
    if self.editing then
        if event == "char" then
            self.editing.buffer = self.editing.buffer .. p1
            return { kind = "redraw" }
        elseif event == "key" then
            if p1 == keys.enter then
                local field, value = self.editing.field, self.editing.buffer
                self.editing = nil
                if field == "range" then
                    local n = tonumber(value)
                    if not n or n < 0 then
                        self:say("range must be a number >= 0")
                        return { kind = "redraw" }
                    end
                    return { kind = "range", value = n }
                end
                return { kind = "name", value = value }
            elseif p1 == keys.backspace then
                self.editing.buffer = self.editing.buffer:sub(1, -2)
                return { kind = "redraw" }
            elseif p1 == keys.tab then -- escape is grabbed by the shell; tab cancels
                self.editing = nil
                return { kind = "redraw" }
            end
        end
        return nil
    end

    -- ----- normal mode -----
    if event ~= "key" then return nil end
    self.message = nil

    if p1 == keys.up then
        self.sel = math.max(1, self.sel - 1); return { kind = "redraw" }
    elseif p1 == keys.down then
        self.sel = math.min(math.max(1, rowCount), self.sel + 1); return { kind = "redraw" }
    elseif p1 == keys.pageUp then
        self.sel = math.max(1, self.sel - 10); return { kind = "redraw" }
    elseif p1 == keys.pageDown then
        self.sel = math.min(math.max(1, rowCount), self.sel + 10); return { kind = "redraw" }
    elseif p1 == keys.t then
        return { kind = "type" }
    elseif p1 == keys.b then
        return { kind = "bundle" }
    elseif p1 == keys.n then
        self.editing = { field = "name", buffer = "" }
        return { kind = "redraw" }
    elseif p1 == keys.r then
        self.editing = { field = "range", buffer = "" }
        return { kind = "redraw" }
    end
    return nil
end

return ControlConsole
