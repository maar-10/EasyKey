--- Tests for the pocket's view of nearby manual panels.
---
--- This module exists because the merge it replaces dropped a field twice while living
--- inside the event loop, where nothing could test it. The most important test here is
--- the boring one: every property a panel publishes must survive the trip, because
--- losing `use` silently put a lift on the Gates tab and looked like a UI bug.
return function(t)
    local PanelFeed = require("easykey.logic.panel_feed")
    t:describe("panel_feed")

    local nowMs = 1000000
    local function now() return nowMs end
    local function make() return PanelFeed.new({ now = now, timeout = 3 }) end

    local A, B = "panelA", "panelB"

    -- ---------- definitions survive the trip ----------
    local f = make()
    f:onList(A, {
        { id = "c1", name = "Hangar Lift", type = "switch", use = "elevator" },
        { id = "c2", name = "Main Gate",   type = "button", use = "gate" },
    })
    local list = f:list()
    t:eq(#list, 1, "one panel")
    t:eq(#list[1].controls, 2, "both controls")
    t:eq(list[1].controls[1].name, "Hangar Lift", "name survives")
    t:eq(list[1].controls[1].type, "switch", "type survives")
    t:eq(list[1].controls[1].use, "elevator", "USE survives (a lift must not land on Gates)")
    t:eq(list[1].controls[2].use, "gate", "the other control's use survives too")
    t:eq(list[1].controls[1].on, false, "a newly listed control starts off")

    -- ---------- state updates on/err, keyed by id ----------
    f:onState(A, "ok", { { id = "c1", on = true }, { id = "c2", on = false, err = true } })
    list = f:list()
    t:eq(list[1].status, "ok", "status comes from the state message")
    t:eq(list[1].controls[1].on, true, "state turns a control on")
    t:eq(list[1].controls[2].err, true, "state flags a hardware disagreement")
    t:eq(list[1].controls[1].use, "elevator", "state does not clobber the definition")
    t:eq(list[1].controls[1].name, "Hangar Lift", "state does not clobber the name")

    -- a state for something we were never told about is ignored: the list defines what exists
    f:onState(A, "ok", { { id = "ghost", on = true } })
    t:eq(#f:list()[1].controls, 2, "unknown control ids in a state are ignored")

    -- ---------- republishing the list keeps live state ----------
    f:onList(A, {
        { id = "c1", name = "Hangar Lift", type = "switch", use = "elevator" },
        { id = "c2", name = "Main Gate",   type = "button", use = "gate" },
    })
    list = f:list()
    t:eq(list[1].controls[1].on, true, "a republished list does not blink controls off")
    t:eq(list[1].controls[2].err, true, "a republished list keeps the error flag")

    -- ---------- deletions propagate ----------
    f:onList(A, { { id = "c2", name = "Main Gate", type = "button", use = "gate" } })
    list = f:list()
    t:eq(#list[1].controls, 1, "a control the panel stopped listing disappears")
    t:eq(list[1].controls[1].id, "c2", "the right one survived")

    -- ---------- renames + retargets flow through ----------
    f:onList(A, { { id = "c2", name = "Front Gate", type = "switch", use = "elevator" } })
    list = f:list()
    t:eq(list[1].controls[1].name, "Front Gate", "a rename reaches the pocket")
    t:eq(list[1].controls[1].type, "switch", "a type change reaches the pocket")
    t:eq(list[1].controls[1].use, "elevator", "moving it to another tab reaches the pocket")

    -- ---------- silence is an error, never 'probably fine' ----------
    local s = make()
    s:onList(A, { { id = "c1", name = "X", type = "button", use = "gate" } })
    s:onState(A, "ok", { { id = "c1", on = false } })
    t:eq(s:list()[1].status, "ok", "fresh panel is ok")
    nowMs = nowMs + 2000
    t:ok(not s:tick(nowMs), "no change inside the timeout")
    t:eq(s:list()[1].status, "ok", "still ok inside the timeout")
    nowMs = nowMs + 2000 -- past 3s
    t:ok(s:tick(nowMs), "tick reports the change")
    t:eq(s:list()[1].status, "signal_error", "a quiet panel goes to signal error")
    t:ok(not s:tick(nowMs), "already flagged: no repeat change")

    -- talking again clears it
    s:onState(A, "ok", { { id = "c1", on = false } })
    t:eq(s:list()[1].status, "ok", "a panel that comes back is ok again")

    -- ---------- several panels ----------
    local m = make()
    m:onList(B, { { id = "b1", name = "B", type = "button", use = "gate" } })
    m:onList(A, { { id = "a1", name = "A", type = "button", use = "gate" } })
    m:onState(A, "ok", {})
    m:onState(B, "denied", {})
    local ml = m:list()
    t:eq(#ml, 2, "both panels listed")
    t:eq(ml[1].address, A, "sorted by address for a stable order")
    t:eq(ml[2].status, "denied", "each panel keeps its own status")

    m:clear()
    t:eq(#m:list(), 0, "clear forgets everything")

    -- ---------- a state before any list ----------
    local e = make()
    e:onState(A, "ok", { { id = "c1", on = true } })
    t:eq(#e:list()[1].controls, 0, "state alone creates no controls")
end
