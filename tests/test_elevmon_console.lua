--- Tests for the elevator monitor's console logic (easykey/ui/elevmon_console.lua).
---
--- Only the parts that don't need a terminal: which rows are shown, and what a key press means.
--- They matter because of scale — bundle a couple of sides and this list is ~96 channels, so
--- "show me only what is live" IS the wiring workflow: hit f, ride the lift, and the one row
--- left is the arrival contact to name in the floor form. A filter that mismatched the
--- selection would silently bundle the wrong side.
return function(t)
    local Console = require("easykey.ui.elevmon_console")
    t:describe("elevmon console")

    local function channels()
        return {
            { id = "self/back",   input = false, output = false, device = "self", side = "back" },
            { id = "self/left",   input = true,  output = false, device = "self", side = "left" },
            { id = "self/top",    input = false, output = true,  device = "self", side = "top" },
            { id = "self/bottom", input = false, output = false, device = "self", side = "bottom" },
        }
    end
    local st = { channels = channels() }

    local c = Console.new()
    t:eq(c.sel, 1, "the selection starts at the top")
    t:ok(not c.filter, "the filter starts off")
    t:eq(#c:rowsFor(st), 4, "every channel is shown by default")

    -- ---------- the busy-only filter ----------
    c:onInput("key", keys.f, 4)
    t:ok(c.filter, "f turns the filter on")
    local busy = c:rowsFor(st)
    t:eq(#busy, 2, "only channels doing something are shown")
    t:eq(busy[1].id, "self/left", "an input is 'doing something'")
    t:eq(busy[2].id, "self/top", "so is an output")
    t:eq(c.sel, 1, "toggling the filter resets the selection, so it can't point at a hidden row")
    t:eq(c.scroll, 0, "...and the scroll with it")

    c:onInput("key", keys.f, 2)
    t:ok(not c.filter, "f toggles it back off")
    t:eq(#c:rowsFor(st), 4, "and everything is shown again")

    -- an idle shaft with the filter on shows nothing, and that is a legitimate state
    local idle = { channels = { { id = "self/back", input = false, output = false } } }
    c.filter = true
    t:eq(#c:rowsFor(idle), 0, "an idle shaft filters down to nothing")
    c.filter = false

    -- ---------- selection ----------
    local s = Console.new()
    t:eq(s:onInput("key", keys.down, 4).kind, "redraw", "down moves the selection")
    t:eq(s.sel, 2, "...to the next row")
    s:onInput("key", keys.up, 4)
    t:eq(s.sel, 1, "up moves it back")
    s:onInput("key", keys.up, 4)
    t:eq(s.sel, 1, "and it cannot go above the first row")
    s:onInput("key", keys.pageDown, 4)
    t:eq(s.sel, 4, "page-down clamps to the last row rather than running off the end")
    s:onInput("key", keys.down, 4)
    t:eq(s.sel, 4, "...and stays there")
    s:onInput("key", keys.pageUp, 4)
    t:eq(s.sel, 1, "page-up clamps to the first row")

    -- an empty list must not leave the selection at 0 (it indexes the row array directly)
    local e = Console.new()
    e:onInput("key", keys.down, 0)
    t:eq(e.sel, 1, "with no rows the selection stays at 1")

    -- ---------- actions ----------
    local a = Console.new()
    t:eq(a:onInput("key", keys.b, 4).kind, "bundle", "b asks to bundle the selected side")
    t:eq(a:onInput("key", keys.z, 4), nil, "an unbound key does nothing")
    t:eq(a:onInput("char", "b", 4), nil, "chars are ignored: this console has no text entry")

    -- a message is transient: it clears on the next key press, so it can't linger as a lie
    a:say("no such channel: self/back")
    t:eq(a.message, "no such channel: self/back", "say sets the footer message")
    a:onInput("key", keys.down, 4)
    t:eq(a.message, nil, "the next key press clears it")
end
