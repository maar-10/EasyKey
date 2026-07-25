--- Tests for the elevator controller's logic (easykey/logic/elevator.lua).
---
--- The rules under test are the ones that would be maddening to debug in-game: that a call is
--- ONE short pulse and never a held level, that position is only ever what the hardware said,
--- that a remote pulse is dispatched exactly once, and that every refusal path leaves the lift
--- untouched rather than half-locked.
return function(t)
    local Elevator = require("easykey.logic.elevator")
    t:describe("elevator")

    local nowMs = 1000000
    local function now() return nowMs end
    local ALICE, BOB = "aliceAddr", "bobAddr"
    local MON = "monitorAddr"

    local function make()
        local e = Elevator.new({
            now = now,
            defaults = { range = 100, stale = 2, pressSeconds = 0.5,
                         recallSeconds = 2, timeoutSeconds = 20 },
        })
        e:setSecureSet({ { address = ALICE, expiresAt = nowMs + 300000 } })
        e:onPresence(ALICE, 5, nowMs)
        return e
    end

    --- A lift with three local floors, wired to three of this PC's channels.
    local function makeLocal()
        local e = make()
        local lid = e:add({ name = "Main", recall = 2, timeout = 20 })
        local f1 = e:addFloor(lid, { name = "G", call = "self/back", at = "self/left" })
        local f2 = e:addFloor(lid, { name = "F1", call = "self/top", at = "self/right" })
        local f3 = e:addFloor(lid, { name = "F2", call = "self/bottom", at = "self/front" })
        return e, lid, f1, f2, f3
    end

    -- ---------- channel helpers ----------
    t:ok(Elevator.isRemote("mon:self/back"), "a mon: channel is remote")
    t:ok(not Elevator.isRemote("self/back"), "a plain id is local")
    t:eq(Elevator.remoteId("mon:redstone_relay_3/left:pink"), "redstone_relay_3/left:pink",
        "the bare id is recovered from a remote channel")
    t:eq(Elevator.remoteId("self/back"), nil, "a local channel has no remote id")
    t:eq(Elevator.monChannel("self/back"), "mon:self/back", "a local id wraps to a mon: channel")
    t:eq(Elevator.controlId("e1", "f2"), "e1.f2", "a floor's published id joins both halves")
    local lp, fp = Elevator.splitControlId("e1.f2")
    t:ok(lp == "e1" and fp == "f2", "...and splits back cleanly")

    -- ---------- what the pocket is shown ----------
    local e, lid, f1, f2, f3 = makeLocal()
    local list = e:listForPocket()
    t:eq(#list, 3, "every floor is published")
    t:eq(list[1].id, Elevator.controlId(lid, f1), "published under the stable floor id")
    t:eq(list[1].name, "Main G", "the lift name prefixes the floor name")
    t:eq(list[1].type, "button", "a floor is always a momentary button")
    t:eq(list[1].use, "elevator", "...on the pocket's Lifts tab")
    -- The wiring must never leave this computer: a pocket has no business knowing which
    -- channel a floor pulses (and nothing it could do with it).
    t:eq(list[1].call, nil, "the call channel is not published")
    t:eq(list[1].at, nil, "the arrival channel is not published")

    -- ---------- a call is ONE short pulse ----------
    local ok, reason = e:input(ALICE, Elevator.controlId(lid, f2), nowMs)
    t:ok(ok, "a cleared pocket in range may call a floor")
    local states, pulses = e:tick(nowMs)
    t:ok(states["self/top"], "the floor's call output is energised")
    t:eq(#pulses, 0, "a local floor sends no message")
    t:ok(not states["self/back"], "...and only that floor's output")

    nowMs = nowMs + 400
    t:ok(e:tick(nowMs)["self/top"], "still pulsing inside pressSeconds")
    nowMs = nowMs + 200 -- 600ms total, past the 500ms pulse
    t:ok(not e:tick(nowMs)["self/top"], "the pulse ends on its own - a call is never held")

    -- ---------- position is READ, never assumed ----------
    local _, rows = e:stateFor(ALICE, nowMs)
    t:eq(#rows, 3, "one row per floor")
    for _, r in ipairs(rows) do t:ok(not r.fired, "no floor claims the cabin before any readback") end

    -- the arrival contact for F1 goes high
    local moved = e:observeFeedback({ ["self/right"] = true }, nil, nowMs)
    t:eq(#moved, 1, "a position change is reported to the caller")
    local _, rows2 = e:stateFor(ALICE, nowMs)
    t:ok(rows2[2].fired, "the floor whose arrival contact is high reads as 'cabin here'")
    t:ok(not rows2[1].fired and not rows2[3].fired, "...and no other floor does")

    -- ...and it stops claiming it the moment the contact drops
    e:observeFeedback({}, nil, nowMs)
    local _, rows3 = e:stateFor(ALICE, nowMs)
    for _, r in ipairs(rows3) do t:ok(not r.fired, "in transit, no floor claims the cabin") end

    -- ---------- arrival clears the outstanding call ----------
    nowMs = 2000000
    local ar, alid, _, af2 = makeLocal()
    ar:input(ALICE, Elevator.controlId(alid, af2), nowMs)
    t:eq(ar:snapshot(nowMs)[1].calling, "F1", "an accepted call shows as outstanding")
    ar:observeFeedback({ ["self/right"] = true }, nil, nowMs)
    local _, _, changes = ar:tick(nowMs)
    t:eq(#changes, 1, "arriving is a reportable event")
    t:eq(changes[1].kind, "arrived", "...named 'arrived'")
    t:eq(changes[1].floor, "F1", "...at the floor we called")
    t:eq(ar:snapshot(nowMs)[1].calling, nil, "the call is no longer outstanding")

    -- ---------- a call the cabin never answers times out (rather than sticking forever) ----------
    nowMs = 3000000
    local to, tlid, _, tf2 = makeLocal()
    to:input(ALICE, Elevator.controlId(tlid, tf2), nowMs)
    nowMs = nowMs + 19000
    local _, _, ch19 = to:tick(nowMs)
    t:eq(#ch19, 0, "still waiting inside the timeout")
    nowMs = nowMs + 2000 -- 21s, past the 20s timeout
    local _, _, ch21 = to:tick(nowMs)
    t:eq(#ch21, 1, "the timeout is reported")
    t:eq(ch21[1].kind, "no_arrival", "...as a missing arrival, not a success")
    t:eq(to:snapshot(nowMs)[1].calling, nil, "and the lift stops claiming to be calling")

    -- ---------- the recall lock ----------
    nowMs = 4000000
    local rl, rlid, rf1, rf2 = makeLocal()
    t:ok(rl:input(ALICE, Elevator.controlId(rlid, rf1), nowMs), "first call accepted")
    local ok2, why = rl:input(ALICE, Elevator.controlId(rlid, rf2), nowMs)
    t:ok(not ok2 and why == Elevator.COOLDOWN, "a second call inside the lock is refused")
    local _, lockRows = rl:stateFor(ALICE, nowMs)
    t:eq(lockRows[1].cooldown, 2, "the lock is reported to the pocket, on every floor")
    t:eq(lockRows[2].cooldown, 2, "...including the one that was refused")
    -- A refused call must not have moved anything: no pulse, no new outstanding call.
    t:eq(rl.lifts[rlid].callFloor, rf1, "the refused call did not retarget the lift")
    nowMs = nowMs + 2100
    rl:onPresence(ALICE, 5, nowMs) -- still standing there; presence goes stale after 2s
    t:ok(rl:input(ALICE, Elevator.controlId(rlid, rf2), nowMs), "once the lock lapses, calls work")

    -- recall = 0 means no lock at all
    nowMs = 5000000
    local nl = make()
    local nlid = nl:add({ name = "Fast", recall = 0 })
    local nf1 = nl:addFloor(nlid, { name = "G", call = "self/back" })
    local nf2 = nl:addFloor(nlid, { name = "F1", call = "self/top" })
    t:ok(nl:input(ALICE, Elevator.controlId(nlid, nf1), nowMs), "unlocked lift: first call")
    t:ok(nl:input(ALICE, Elevator.controlId(nlid, nf2), nowMs), "unlocked lift: immediate second call")
    local _, nlRows = nl:stateFor(ALICE, nowMs)
    t:eq(nlRows[1].cooldown, 0, "and nothing is reported as locked")

    -- ---------- access gating ----------
    nowMs = 6000000
    local g, glid, gf1 = makeLocal()
    local cid = Elevator.controlId(glid, gf1)
    g:onPresence(ALICE, 500, nowMs) -- walked away
    local okA, whyA = g:input(ALICE, cid, nowMs)
    t:ok(not okA and whyA == Elevator.OUT_OF_RANGE, "a call from out of range is refused")
    t:ok(not g:tick(nowMs)["self/back"], "...and nothing was energised")

    g:onPresence(ALICE, 5, nowMs)
    g:onPresence(BOB, 5, nowMs)
    local okB, whyB = g:input(BOB, cid, nowMs)
    t:ok(not okB and whyB == Elevator.DENIED, "a call from an uncleared pocket is refused")
    t:ok(not g:tick(nowMs)["self/back"], "...and still nothing was energised")

    local okU, whyU = g:input(ALICE, "nosuch.floor", nowMs)
    t:ok(not okU and whyU == Elevator.UNKNOWN, "an unknown floor id is refused")

    -- a session ending must stop calls immediately, presence notwithstanding
    g:setSecureSet({})
    local okS, whyS = g:input(ALICE, cid, nowMs)
    t:ok(not okS and whyS == Elevator.DENIED, "no session -> no calls, standing right there")

    -- ---------- the local operator's failsafe ----------
    nowMs = 7000000
    local lo, llid, lf1 = makeLocal()
    local lcid = Elevator.controlId(llid, lf1)
    local okL, whyL = lo:input(Elevator.LOCAL, lcid, nowMs)
    t:ok(not okL and whyL == Elevator.DENIED, "an unapproved controller denies its own operator")
    lo:setApproved(true)
    t:ok(lo:input(Elevator.LOCAL, lcid, nowMs), "an approved controller lets its operator call")
    t:ok(lo:tick(nowMs)["self/back"], "...and that really drives the call output")

    -- ---------- wiring errors are named, not silent ----------
    nowMs = 8000000
    local w = make()
    local wlid = w:add({ name = "Broken" })
    local wf = w:addFloor(wlid, { name = "G" }) -- no call channel at all
    local okW, whyW = w:input(ALICE, Elevator.controlId(wlid, wf), nowMs)
    t:ok(not okW and whyW == Elevator.NO_TARGET, "a floor with no call output is refused by name")
    t:eq(w.lifts[wlid].callFloor, nil, "...leaving the lift untouched")

    local rf = w:addFloor(wlid, { name = "F1", call = "mon:self/back" }) -- but no monitor set
    local okM, whyM = w:input(ALICE, Elevator.controlId(wlid, rf), nowMs)
    t:ok(not okM and whyM == Elevator.NO_MONITOR, "a mon: floor with no monitor is refused by name")
    t:eq(w.lifts[wlid].callFloor, nil, "...also leaving the lift untouched")

    -- ---------- remote (monitor) wiring ----------
    nowMs = 9000000
    local r = make()
    local rlid2 = r:add({ name = "Shaft", monitor = MON, recall = 0 })
    local rgf = r:addFloor(rlid2, { name = "G", call = "mon:self/back", at = "mon:self/left" })
    local rtf = r:addFloor(rlid2, { name = "Top", call = "mon:self/top", at = "mon:self/right" })
    t:eq(r:monitors(), { MON }, "the lift's monitor is reported for tunnel keep-alive")

    t:ok(r:input(ALICE, Elevator.controlId(rlid2, rtf), nowMs), "a mon: floor accepts a call")
    local rStates, rPulses = r:tick(nowMs)
    t:eq(next(rStates), nil, "a remote call drives NO local redstone")
    t:eq(#rPulses, 1, "it produces exactly one pulse to dispatch")
    t:eq(rPulses[1].monitor, MON, "...addressed to the lift's monitor")
    t:eq(rPulses[1].target, "self/top", "...naming the bare channel on that monitor")
    t:near(rPulses[1].seconds, 0.5, 1e-6, "...for the configured pulse length")

    -- Dispatched ONCE. A message per tick would flood the tunnel, and the monitor times the
    -- pulse itself, so repeating it is not just wasteful but wrong.
    local _, again = r:tick(nowMs)
    t:eq(#again, 0, "the outbox is drained: a remote pulse is never re-sent")

    -- position comes from the monitor's inputs, keyed by the monitor's address
    r:observeFeedback({}, { [MON] = { inputs = { ["self/right"] = true }, outputs = {} } }, nowMs)
    local _, rRows = r:stateFor(ALICE, nowMs)
    t:ok(rRows[2].fired, "the monitor's arrival contact positions the cabin")
    -- ...and a report from some OTHER monitor must not move this lift
    r:observeFeedback({}, { ["someoneElse"] = { inputs = { ["self/left"] = true }, outputs = {} } },
        nowMs)
    local _, rRows2 = r:stateFor(ALICE, nowMs)
    t:ok(not rRows2[1].fired and not rRows2[2].fired,
        "another monitor's inputs are ignored for this lift")

    -- a local input id that happens to match a remote channel's bare id must NOT position it
    r:observeFeedback({ ["self/left"] = true }, nil, nowMs)
    local _, rRows3 = r:stateFor(ALICE, nowMs)
    t:ok(not rRows3[1].fired, "a mon: arrival is never satisfied by a local input of the same name")

    -- ---------- changing the monitor comes up cold ----------
    nowMs = 9500000
    r:observeFeedback({}, { [MON] = { inputs = { ["self/left"] = true }, outputs = {} } }, nowMs)
    t:eq(r.lifts[rlid2].at, rgf, "position known before the change")
    r:update(rlid2, { monitor = "differentMonitor" })
    t:eq(r.lifts[rlid2].at, nil, "changing the monitor forgets the position (stale is worse than none)")

    -- ---------- floors: order, reorder, delete ----------
    nowMs = 10000000
    local o, olid, of1, of2, of3 = makeLocal()
    local function names()
        local out = {}
        for _, row in ipairs(o:floorRows(olid)) do out[#out + 1] = row.name end
        return out
    end
    t:eq(names(), { "G", "F1", "F2" }, "floors list in creation order")
    t:ok(o:moveFloor(olid, of3, -1), "a floor moves up")
    t:eq(names(), { "G", "F2", "F1" }, "...and the order follows")
    t:ok(not o:moveFloor(olid, of1, -1), "the top floor cannot move up")
    t:eq(names(), { "G", "F2", "F1" }, "...and a refused move changes nothing")
    t:ok(not o:moveFloor(olid, "nosuch", 1), "an unknown floor cannot move")

    -- reordering changes what the pocket is shown, in order, but never the ids
    local ordered = o:listForPocket()
    t:eq(ordered[2].id, Elevator.controlId(olid, of3), "the published order follows the reorder")
    t:eq(ordered[2].name, "Main F2", "...with its own name intact")

    -- deleting the floor the cabin is on must not leave it "there"
    o:observeFeedback({ ["self/right"] = true }, nil, nowMs) -- F1's arrival contact
    t:eq(o.lifts[olid].at, of2, "cabin is at F1")
    o:removeFloor(olid, of2)
    t:eq(o.lifts[olid].at, nil, "deleting that floor clears the position")
    t:eq(#o:floorRows(olid), 2, "...and the floor is gone")
    t:eq(#o:listForPocket(), 2, "...including from what the pocket sees")

    -- deleting a lift takes its floors with it
    o:remove(olid)
    t:eq(#o:listForPocket(), 0, "deleting a lift removes all its floors from the pocket")
    t:eq(o:floorRows(olid), {}, "...and asking for its floors is empty, not an error")

    -- ---------- persistence round-trips definitions and nothing else ----------
    nowMs = 11000000
    local p = make()
    local plid = p:add({ name = "Tower", monitor = MON, recall = 3, timeout = 45 })
    p:addFloor(plid, { name = "G", call = "mon:self/back", at = "mon:self/left" })
    p:addFloor(plid, { name = "F1", call = "self/top", at = nil })
    p:addFloor(plid, { name = "F2", call = "self/bottom", at = "self/front" })
    p:moveFloor(plid, p:floorRows(plid)[3].id, -1) -- F2 above F1
    -- live state that must NOT survive a reboot
    p:input(ALICE, Elevator.controlId(plid, p:floorRows(plid)[1].id), nowMs)
    p:observeFeedback({}, { [MON] = { inputs = { ["self/left"] = true }, outputs = {} } }, nowMs)

    local saved = p:exportConfig()
    local q = Elevator.new({ now = now, defaults = { range = 100, stale = 2, pressSeconds = 0.5 } })
    q:loadConfig(saved)
    local ql = q.lifts[plid]
    t:ok(ql ~= nil, "the lift id is stable across a reload")
    t:eq(ql.name, "Tower", "name survives")
    t:eq(ql.monitor, MON, "monitor survives")
    t:eq(ql.recall, 3, "recall survives")
    t:eq(ql.timeout, 45, "timeout survives")
    local qnames = {}
    for _, row in ipairs(q:floorRows(plid)) do qnames[#qnames + 1] = row.name end
    t:eq(qnames, { "G", "F2", "F1" }, "the operator's floor order survives")
    t:eq(q:floorRows(plid)[1].call, "mon:self/back", "a remote channel survives verbatim")
    t:eq(q:floorRows(plid)[3].at, nil, "a floor with no arrival input stays that way")
    -- A reboot must come up cold: no cabin claimed, no call outstanding, nothing energised.
    t:eq(ql.at, nil, "a reload does not claim to know where the cabin is")
    t:eq(ql.callFloor, nil, "a reload has no outstanding call")
    -- the extra parentheses matter: tick() returns three values, and next() would take the
    -- second one as a key into the first
    t:eq(next((q:tick(nowMs))), nil, "a reload drives no redstone")

    -- a second lift added after a reload must not collide with the loaded ids
    local newLid = q:add({ name = "Extra" })
    t:ok(newLid ~= plid, "a new lift gets a fresh id after a reload")
    local newFid = q:addFloor(plid, { name = "F3", call = "self/back" })
    local existing = {}
    for _, row in ipairs(q:floorRows(plid)) do
        t:ok(not existing[row.id], "floor ids stay unique after a reload (" .. row.id .. ")")
        existing[row.id] = true
    end
    t:ok(newFid ~= nil, "a floor can be added to a reloaded lift")

    -- ---------- clearing a channel from the form ----------
    -- The forms send "" for "(none)", because a nil field is indistinguishable from "unchanged".
    local c = make()
    local clid = c:add({ name = "C" })
    local cfid = c:addFloor(clid, { name = "G", call = "self/back", at = "self/left" })
    c:updateFloor(clid, cfid, { at = "" })
    t:eq(c:floorRows(clid)[1].at, nil, "an empty string clears the arrival channel")
    t:eq(c:floorRows(clid)[1].call, "self/back", "...without touching the call channel")
    c:updateFloor(clid, cfid, { name = "Ground" })
    t:eq(c:floorRows(clid)[1].call, "self/back", "a name-only edit leaves the wiring alone")

    -- ---------- "" means none, everywhere ----------
    -- The forms send "" for a cleared dropdown, because an ABSENT field has to keep meaning
    -- "leave it alone". A stored "" would look configured, match no channel, and read as a
    -- mysteriously dead button.
    local z = make()
    local zlid = z:add({ name = "Z", monitor = "" })
    t:eq(z.lifts[zlid].monitor, nil, "an empty monitor on add is nil, not \"\"")
    local zf = z:addFloor(zlid, { name = "G", call = "self/back", at = "" })
    t:eq(z:floorRows(zlid)[1].at, nil, "an empty arrival channel on add is nil, not \"\"")
    -- ...and a monitor can be UN-set again, which nil could never express
    z:update(zlid, { monitor = MON })
    t:eq(z.lifts[zlid].monitor, MON, "a monitor can be set")
    z:update(zlid, { monitor = "" })
    t:eq(z.lifts[zlid].monitor, nil, "...and cleared again")
    z:update(zlid, { name = "ZZ" })
    t:eq(z.lifts[zlid].monitor, nil, "a name-only edit leaves the monitor alone")
    z:update(zlid, { monitor = MON })
    z:update(zlid, { recall = 4 })
    t:eq(z.lifts[zlid].monitor, MON, "a timing-only edit does not clear the monitor")
    t:ok(zf ~= nil, "the floor was created")

    -- ---------- orphaned floors ----------
    local orf = make()
    local olid2 = orf:add({ name = "Main", monitor = MON })
    orf:addFloor(olid2, { name = "G", call = "self/back" })
    orf:addFloor(olid2, { name = "F1", call = "self/back:pink" }) -- side later un-bundled
    orf:addFloor(olid2, { name = "F2" })                          -- never wired
    local orphans = orf:orphanedFloors({ ["self/back"] = true })
    t:eq(orphans, { "Main F1", "Main F2" },
        "floors calling a channel that no longer exists are named, and so are unwired ones")
    t:eq(#orf:orphanedFloors({ ["self/back"] = true, ["self/back:pink"] = true }), 1,
        "a channel that exists again is no longer orphaned")

    -- Resolved PER LIFT when given a function, because "mon:" means *that lift's* monitor. A
    -- flat union across every lift would call a floor valid because some OTHER lift's monitor
    -- happens to have a channel by the same name — and that floor still calls nothing.
    local pl = make()
    local liftA = pl:add({ name = "A", monitor = MON })
    local liftB = pl:add({ name = "B", monitor = "otherMonitor" })
    pl:addFloor(liftA, { name = "G", call = "mon:self/back" }) -- A's monitor HAS self/back
    pl:addFloor(liftB, { name = "G", call = "mon:self/back" }) -- B's monitor does NOT
    local perLift = function(liftId)
        if liftId == liftA then return { ["mon:self/back"] = true } end
        return {} -- B's monitor has reported nothing
    end
    t:eq(pl:orphanedFloors(perLift), { "B G" },
        "only the lift whose own monitor lacks the channel is flagged")
    t:eq(#pl:orphanedFloors({ ["mon:self/back"] = true }), 0,
        "a flat set cannot tell them apart (which is why the function form exists)")

    -- ---------- two lifts are independent ----------
    nowMs = 12000000
    local m = make()
    local a1 = m:add({ name = "A", recall = 5 })
    local b1 = m:add({ name = "B", recall = 5 })
    local af = m:addFloor(a1, { name = "G", call = "self/back", at = "self/left" })
    local bf = m:addFloor(b1, { name = "G", call = "self/top", at = "self/right" })
    t:ok(m:input(ALICE, Elevator.controlId(a1, af), nowMs), "lift A accepts a call")
    t:ok(m:input(ALICE, Elevator.controlId(b1, bf), nowMs),
        "lift B is not locked by lift A's call")
    local mStates = m:tick(nowMs)
    t:ok(mStates["self/back"] and mStates["self/top"], "both call outputs fire")
    m:observeFeedback({ ["self/left"] = true }, nil, nowMs)
    t:eq(m:snapshot(nowMs)[1].at, "G", "A knows where its cabin is")
    t:eq(m:snapshot(nowMs)[2].at, nil, "...and B does not borrow it")

    -- ---------- snapshot / range ----------
    local sn = make()
    t:eq(sn:getRange(), 100, "range starts from the config default")
    t:ok(sn:setRange(60), "range accepts a positive number")
    t:eq(sn:getRange(), 60, "...and keeps it")
    t:ok(not sn:setRange(0), "range refuses zero")
    t:ok(not sn:setRange("abc"), "range refuses nonsense")
    t:eq(sn:getRange(), 60, "...leaving the old value alone")
end
