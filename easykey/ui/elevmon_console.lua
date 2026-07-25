--- The elevator monitor's terminal UI.
---
--- A plain console, not Basalt — same reasoning as the door control (easykey/ui/control_console.lua):
--- a monitor is a normal computer with no mouse, and you want to be able to drop one at the
--- bottom of every lift shaft cheaply. Everything is keyboard-driven.
---
--- What you read off this screen: whether the server has approved this PC, its fingerprint
--- (for approving it), which elevator controllers are attached, and — the part you actually
--- watch while wiring — the live IN and OUT state of every redstone channel. Wire an arrival
--- contact, ride the lift, and the `I` marker tells you which channel to name in the floor
--- form. That is the whole setup workflow.
---
--- Text entry is a small state machine rather than read(), because read() would block this
--- coroutine and swallow the pulse commands arriving meanwhile — a lift could miss a call
--- mid-keystroke.
local ElevmonConsole = {}

--- @param opts table|nil (reserved)
function ElevmonConsole.new(opts)
    local self = setmetatable({}, { __index = ElevmonConsole })
    self.sel = 1
    self.scroll = 0
    self.message = nil
    self.filter = false -- true = only show channels that are doing something
    return self
end

--- Show a transient hint (e.g. why a key press did nothing).
function ElevmonConsole:say(text) self.message = text end

function ElevmonConsole:_clamp(rowCount, rows)
    if self.sel < 1 then self.sel = 1 end
    if self.sel > rowCount then self.sel = math.max(1, rowCount) end
    if self.sel <= self.scroll then self.scroll = self.sel - 1 end
    if self.sel > self.scroll + rows then self.scroll = self.sel - rows end
    if self.scroll < 0 then self.scroll = 0 end
end

--- The channels to show, honouring the "busy only" filter. Returned rather than filtered in
--- place so the selection index always refers to what is actually on screen.
--- @param st table see :draw
function ElevmonConsole:rowsFor(st)
    local all = st.channels or {}
    if not self.filter then return all end
    local out = {}
    for _, c in ipairs(all) do
        if c.input or c.output then out[#out + 1] = c end
    end
    return out
end

--- Draw everything.
--- @param st table {
---   serverFp, serverUp, approved, myFp,   -- header
---   controllers,                          -- how many elevator controllers are attached
---   channels,                             -- array of { id, input, output, pulsing }
--- }
function ElevmonConsole:draw(st)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    local w, h = term.getSize()

    term.setTextColor(colors.cyan); print("EasyKey Elevator Monitor")
    term.setTextColor(st.serverUp and colors.lime or colors.red)
    print("server " .. tostring(st.serverFp) .. ": " .. (st.serverUp and "OK" or "DOWN")
        .. (st.approved and "" or " (awaiting approval)"))
    term.setTextColor(colors.lightGray)
    print("me: " .. tostring(st.myFp) .. "   lifts: " .. tostring(st.controllers or 0))

    term.setTextColor(colors.gray)
    print("up/dn sel  b:bundle side  f:busy only")

    term.setTextColor(colors.white)
    print(("%-24s %3s %3s"):format("CHANNEL", "IN", "OUT"))

    local headerRows = 5
    local footRows = self.message and 1 or 0
    local rows = h - headerRows - footRows
    local list = self:rowsFor(st)
    self:_clamp(#list, rows)

    if #list == 0 then
        term.setTextColor(colors.gray)
        print(self.filter and " (nothing active - press f)" or " (no redstone channels found)")
    end

    for i = self.scroll + 1, math.min(#list, self.scroll + rows) do
        local c = list[i]
        local selected = (i == self.sel)
        -- IN is what the world drives into us (an arrival contact); OUT is our own call pulse
        -- read back from the hardware, so a write that silently failed shows here.
        local fg = colors.white
        if c.input then fg = colors.lime          -- the cabin is at this contact
        elseif c.output then fg = colors.cyan end -- we are calling through this contact
        term.setTextColor(selected and colors.yellow or fg)
        print(("%s%-23s %3s %3s"):format(
            selected and ">" or " ",
            tostring(c.id):sub(1, 23),
            c.input and "ON" or "..",
            c.output and "ON" or ".."))
    end

    if self.message then
        term.setCursorPos(1, h)
        term.setTextColor(colors.orange); term.clearLine()
        term.write(tostring(self.message):sub(1, w))
    end
end

--- Handle a key event. Returns an action for the caller, or nil.
---   { kind = "bundle" }  flip the selected channel's SIDE between plain and 16 colours
---   { kind = "redraw" }  selection or filter changed
function ElevmonConsole:onInput(event, p1, rowCount)
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
    elseif p1 == keys.f then
        -- 96 channels once a few sides are bundled; "show me only what is live" is how you
        -- find the arrival contact you just wired.
        self.filter = not self.filter
        self.sel = 1; self.scroll = 0
        return { kind = "redraw" }
    elseif p1 == keys.b then
        return { kind = "bundle" }
    end
    return nil
end

return ElevmonConsole
