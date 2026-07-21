--- Tests for the manual control PC's panel logic.
---
--- The rules under test are the ones a user would find maddening to debug in-game:
--- who owns a switch, when it drops, and exactly how long a blip is tolerated. The
--- asymmetry is deliberate and load-bearing: losing your SESSION drops a switch
--- instantly (authority gone), while losing RANGE or connectivity is graced for 3s.
return function(t)
    local Panel = require("easykey.logic.panel")
    t:describe("panel")

    local nowMs = 1000000
    local function now() return nowMs end
    local ALICE, BOB = "aliceAddr", "bobAddr"

    local function make()
        local p = Panel.new({
            now = now,
            defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 },
        })
        p:setSecureSet({ { address = ALICE, expiresAt = nowMs + 300000 } })
        return p
    end

    -- ---------- status ----------
    local p = make()
    t:eq(p:statusFor(ALICE), Panel.OUT_OF_RANGE, "never heard from -> out of range")
    p:onPresence(ALICE, 200, nowMs)
    t:eq(p:statusFor(ALICE), Panel.OUT_OF_RANGE, "beyond range -> out of range")
    p:onPresence(ALICE, 50, nowMs)
    t:eq(p:statusFor(ALICE), Panel.OK, "secure + in range -> ok")
    p:onPresence(BOB, 5, nowMs)
    t:eq(p:statusFor(BOB), Panel.DENIED, "in range but not cleared -> denied")
    nowMs = nowMs + 3000 -- no pings: gone quiet
    t:eq(p:statusFor(ALICE), Panel.OUT_OF_RANGE, "gone quiet -> out of range")

    -- ---------- inputs are gated ----------
    nowMs = 2000000
    local g = make()
    local sw = g:add({ name = "Lights", type = "switch", target = "self/back" })
    local ok, reason = g:input(ALICE, sw, nowMs)
    t:ok(not ok and reason == Panel.OUT_OF_RANGE, "input from out of range is refused")

    g:onPresence(BOB, 5, nowMs)
    ok, reason = g:input(BOB, sw, nowMs)
    t:ok(not ok and reason == Panel.DENIED, "input from an uncleared pocket is refused")
    t:ok(not g:tick(nowMs)["self/back"], "...and nothing was energised")

    g:onPresence(ALICE, 5, nowMs)
    ok, reason = g:input(ALICE, "nosuch", nowMs)
    t:ok(not ok and reason == Panel.UNKNOWN, "unknown control id is refused")

    ok = g:input(ALICE, sw, nowMs)
    t:ok(ok, "cleared pocket in range may flip a switch")
    t:ok(g:tick(nowMs)["self/back"], "switch energises its target")

    -- ---------- switch: flip back off ----------
    g:input(ALICE, sw, nowMs)
    t:ok(not g:tick(nowMs)["self/back"], "tapping again turns it off")
    t:eq(g.controls[sw].owner, nil, "an off switch has no owner")

    -- ---------- session end drops a switch INSTANTLY (no grace) ----------
    nowMs = 3000000
    local se = make()
    local s2 = se:add({ name = "Pump", type = "switch", target = "self/top" })
    se:onPresence(ALICE, 5, nowMs)
    se:input(ALICE, s2, nowMs)
    t:ok(se:tick(nowMs)["self/top"], "on while cleared")
    se:setSecureSet({}) -- revoked / expired
    se:onPresence(ALICE, 5, nowMs) -- still standing right there
    t:ok(not se:tick(nowMs)["self/top"], "session gone -> resets instantly, no grace")
    t:eq(se.controls[s2].owner, nil, "owner cleared on reset")

    -- ---------- out of range is graced for exactly 3s ----------
    nowMs = 4000000
    local gr = make()
    local s3 = gr:add({ name = "Door", type = "switch", target = "self/left" })
    gr:onPresence(ALICE, 5, nowMs)
    gr:input(ALICE, s3, nowMs)
    t:ok(gr:tick(nowMs)["self/left"], "on")

    nowMs = nowMs + 500
    gr:onPresence(ALICE, 500, nowMs) -- stepped out of range
    t:ok(gr:tick(nowMs)["self/left"], "still on immediately after leaving (grace)")
    nowMs = nowMs + 2000 -- 2s into the grace
    t:ok(gr:tick(nowMs)["self/left"], "still on 2s into the 3s grace")
    nowMs = nowMs + 1100 -- ~3.1s: grace lapsed
    t:ok(not gr:tick(nowMs)["self/left"], "drops once the 3s grace lapses")

    -- coming back inside the window cancels the grace
    nowMs = 5000000
    local back = make()
    local s4 = back:add({ name = "Door", type = "switch", target = "self/right" })
    back:onPresence(ALICE, 5, nowMs)
    back:input(ALICE, s4, nowMs)
    nowMs = nowMs + 1000
    back:onPresence(ALICE, 500, nowMs); back:tick(nowMs) -- out: grace starts
    nowMs = nowMs + 1000
    back:onPresence(ALICE, 5, nowMs); back:tick(nowMs)   -- back in: cancels
    t:ok(back:tick(nowMs)["self/right"], "still on after returning inside the grace")
    nowMs = nowMs + 2500 -- would have lapsed if the grace hadn't reset
    back:onPresence(ALICE, 5, nowMs)
    t:ok(back:tick(nowMs)["self/right"], "grace was cancelled, not merely postponed")

    -- a silent pocket (tunnel died) is graced the same way, then dropped
    nowMs = 6000000
    local sil = make()
    local s5 = sil:add({ name = "X", type = "switch", target = "self/front" })
    sil:onPresence(ALICE, 5, nowMs)
    sil:input(ALICE, s5, nowMs)
    nowMs = nowMs + 2500 -- silent past `stale` but inside grace
    t:ok(sil:tick(nowMs)["self/front"], "connection blip is tolerated during grace")
    nowMs = nowMs + 3000
    t:ok(not sil:tick(nowMs)["self/front"], "a pocket that never comes back drops it")

    -- ---------- ownership: only the owner's fate matters ----------
    nowMs = 7000000
    local own = make()
    own:setSecureSet({
        { address = ALICE, expiresAt = nowMs + 300000 },
        { address = BOB, expiresAt = nowMs + 300000 },
    })
    local s6 = own:add({ name = "Shared", type = "switch", target = "self/bottom" })
    own:onPresence(ALICE, 5, nowMs); own:onPresence(BOB, 5, nowMs)
    own:input(ALICE, s6, nowMs) -- alice owns it
    t:ok(own:tick(nowMs)["self/bottom"], "on, owned by alice")
    t:eq(own.controls[s6].owner, ALICE, "alice owns the switch she turned on")

    -- Alice leaves; bob (also cleared) stays. It is ALICE's switch, so it must still go
    -- out - but her leaving is a RANGE loss, so it gets the 3s grace first.
    nowMs = nowMs + 4000
    own:onPresence(BOB, 5, nowMs) -- only bob is still pinging
    t:ok(own:tick(nowMs)["self/bottom"], "owner's absence is graced, not instant")
    nowMs = nowMs + 3100
    own:onPresence(BOB, 5, nowMs)
    t:ok(not own:tick(nowMs)["self/bottom"],
        "owner gone past the grace -> drops even though bob is standing there")

    -- bob may turn it on himself, and then he owns it
    nowMs = nowMs + 1000
    own:onPresence(BOB, 5, nowMs)
    own:input(BOB, s6, nowMs)
    t:eq(own.controls[s6].owner, BOB, "whoever turns it on owns it")
    t:ok(own:tick(nowMs)["self/bottom"], "bob's switch is on")

    -- ---------- button: one pulse, then off ----------
    nowMs = 8000000
    local b = make()
    local btn = b:add({ name = "Bell", type = "button", target = "self/back" })
    b:onPresence(ALICE, 5, nowMs)
    b:input(ALICE, btn, nowMs)
    t:ok(b:tick(nowMs)["self/back"], "button pulses on tap")
    nowMs = nowMs + 300
    t:ok(b:tick(nowMs)["self/back"], "still high mid-pulse")
    nowMs = nowMs + 400 -- past 0.5s
    t:ok(not b:tick(nowMs)["self/back"], "pulse ends by itself")
    -- unlike proximity 'press', a button may be tapped again without leaving
    b:input(ALICE, btn, nowMs)
    t:ok(b:tick(nowMs)["self/back"], "tapping again fires again (it is a button)")

    -- ---------- use (gate/elevator) is independent of type (switch/button) ----------
    -- The pocket sorts its tabs by USE; the redstone behaviour comes from TYPE. Mixing
    -- them up would put a lift on the Gates tab or make a gate latch when it shouldn't.
    local u = make()
    local gateBtn  = u:add({ name = "Side Gate", type = "button", use = "gate" })
    local liftSw   = u:add({ name = "Lift Hold", type = "switch", use = "elevator" })
    local plain    = u:add({ name = "Plain" })
    t:eq(u.controls[gateBtn].use, "gate", "a gate can be a momentary button")
    t:eq(u.controls[liftSw].use, "elevator", "a lift can be a latching switch")
    t:eq(u.controls[plain].use, "gate", "use defaults to gate")
    t:eq(u.controls[plain].type, "button", "type still defaults to button")

    u:update(gateBtn, { use = "elevator" })
    t:eq(u.controls[gateBtn].use, "elevator", "use can be changed")
    u:update(gateBtn, { use = "nonsense" })
    t:eq(u.controls[gateBtn].use, "elevator", "an unknown use is rejected")

    -- moving a control between tabs must not disturb its live output
    nowMs = 9400000
    local mv = make()
    local mid = mv:add({ name = "Gate", type = "switch", use = "gate", target = "self/back" })
    mv:onPresence(ALICE, 5, nowMs); mv:input(ALICE, mid, nowMs)
    t:ok(mv:tick(nowMs)["self/back"], "on before the move")
    mv:update(mid, { use = "elevator" })
    t:ok(mv:tick(nowMs)["self/back"], "changing which tab it shows on does not drop it")

    -- the pocket is told the use, so it knows which tab to draw it on
    local forPocket = u:listForPocket()
    t:eq(forPocket[1].use, "elevator", "pocket list carries the use")
    t:eq(forPocket[1].type, "button", "pocket list still carries the type")
    t:eq(forPocket[1].target, nil, "pocket list still hides the wiring")

    -- and it survives a reboot
    local ucfg = u:exportConfig()
    t:eq(ucfg[liftSw].use, "elevator", "export keeps the use")
    local ufresh = make()
    ufresh:loadConfig(ucfg)
    t:eq(ufresh.controls[liftSw].use, "elevator", "use survives a reload")

    -- ---------- CRUD ----------
    local c = make()
    local id1 = c:add({ name = "One", type = "switch", target = "self/back" })
    local id2 = c:add({ name = "Two", type = "button", target = "self/top" })
    t:eq(#c.order, 2, "two controls")
    t:eq(c:listForPocket()[1].name, "One", "pocket list carries names")
    t:eq(c:listForPocket()[1].target, nil, "pocket list does NOT leak the wiring")

    c:update(id1, { name = "Renamed" })
    t:eq(c.controls[id1].name, "Renamed", "rename works")
    c:update(id1, { type = "bogus" })
    t:eq(c.controls[id1].type, "switch", "an unknown type is rejected")

    -- retargeting must not strand the old output on
    c:onPresence(ALICE, 5, nowMs); c:input(ALICE, id1, nowMs)
    t:ok(c:tick(nowMs)["self/back"], "on before retarget")
    c:update(id1, { target = "self/left" })
    local st = c:tick(nowMs)
    t:ok(not st["self/back"], "old target released on retarget")
    t:ok(not st["self/left"], "new target starts off, not inherited")

    t:ok(c:remove(id2), "remove works")
    t:eq(#c.order, 1, "order shrinks")
    t:ok(not c:remove(id2), "removing twice is false")

    -- ---------- persistence: definitions only, never state ----------
    local pc = make()
    local pid = pc:add({ name = "Gate", type = "switch", target = "self/back" })
    pc:onPresence(ALICE, 5, nowMs); pc:input(ALICE, pid, nowMs)
    local cfg = pc:exportConfig()
    t:eq(cfg[pid].name, "Gate", "export keeps the name")
    t:eq(cfg[pid].type, "switch", "export keeps the type")
    t:eq(cfg[pid].target, "self/back", "export keeps the target")
    t:eq(cfg[pid].on, nil, "export does NOT save on/off state")

    local fresh = make()
    fresh:loadConfig(cfg)
    t:eq(fresh.controls[pid].name, "Gate", "definitions survive a reboot")
    t:ok(not fresh:tick(nowMs)["self/back"], "a reboot comes up cold, switch off")
    -- ids stay stable, and new ones don't collide with reloaded ones
    local newId = fresh:add({ name = "Extra", type = "button" })
    t:ok(newId ~= pid, "a new control gets a fresh id after reload")

    -- ---------- stateFor: feedback drives the pocket ----------
    nowMs = 9000000
    local f = make()
    local fid = f:add({ name = "L", type = "switch", target = "self/back" })
    f:onPresence(ALICE, 5, nowMs)
    f:input(ALICE, fid, nowMs)
    f:tick(nowMs)

    -- hardware agrees -> no error
    local status, rows = f:stateFor(ALICE, { ["self/back"] = true }, nowMs)
    t:eq(status, Panel.OK, "cleared + in range -> ok")
    t:eq(rows[1].on, true, "state reports what the redstone actually does")
    t:eq(rows[1].err, nil, "no error when hardware agrees")

    -- hardware disagrees -> err (this is the pocket's "signal error")
    local _st, rows2 = f:stateFor(ALICE, { ["self/back"] = false }, nowMs)
    t:eq(rows2[1].on, false, "state reports the hardware, not our intent")
    t:eq(rows2[1].err, true, "hardware disagreeing with us is flagged as an error")

    -- an uncleared pocket still gets the list + real states, just no access
    local st3 = f:stateFor(BOB, { ["self/back"] = true }, nowMs)
    t:eq(st3, Panel.OUT_OF_RANGE, "bob hasn't pinged -> out of range")
    f:onPresence(BOB, 5, nowMs)
    t:eq(f:stateFor(BOB, { ["self/back"] = true }, nowMs), Panel.DENIED, "bob in range -> denied")

    -- ---------- pockets list for the operator ----------
    local pl = f:pockets(nowMs)
    t:eq(#pl, 2, "both pockets listed")
    t:eq(pl[1].distance, 5, "sorted by distance")
    local secureCount = 0
    for _, x in ipairs(pl) do if x.secure then secureCount = secureCount + 1 end end
    t:eq(secureCount, 1, "only alice is secure")

    -- ---------- the operator's own panel (Panel.LOCAL failsafe) ----------
    -- This PC is hidden like the server, so the operator at its monitor needs no pocket
    -- and no session. What it DOES still respect is this PC's own approval.
    nowMs = 9500000
    local lo = make()
    local lid = lo:add({ name = "Backup", type = "switch", target = "self/back" })

    lo:setApproved(false)
    t:eq(lo:statusFor(Panel.LOCAL), Panel.DENIED, "an unapproved panel is dead on its own monitor")
    local ok2, reason2 = lo:input(Panel.LOCAL, lid, nowMs)
    t:ok(not ok2 and reason2 == Panel.DENIED, "local tap refused while unapproved")
    t:ok(not lo:tick(nowMs)["self/back"], "...and nothing energised")

    lo:setApproved(true)
    t:eq(lo:statusFor(Panel.LOCAL), Panel.OK, "an approved panel works locally")
    t:ok(lo:input(Panel.LOCAL, lid, nowMs), "local tap accepted once approved")
    t:ok(lo:tick(nowMs)["self/back"], "local switch energises")

    -- the operator never "leaves range" or times out: their switch just stays on
    nowMs = nowMs + 60000 -- a minute later, no pings from anyone
    t:ok(lo:tick(nowMs)["self/back"], "a local switch is not dropped by range/grace")
    t:ok(lo:inRange(Panel.LOCAL), "the operator is always in range")

    -- but revoking the PANEL itself drops it at once, like a session ending
    lo:setApproved(false)
    t:ok(not lo:tick(nowMs)["self/back"], "revoking the panel drops the operator's switch too")

    -- local access does not depend on any pocket being cleared
    nowMs = 9600000
    local lo2 = make()
    lo2:setSecureSet({}) -- nobody is cleared at all
    lo2:setApproved(true)
    local lb = lo2:add({ name = "Bell", type = "button", target = "self/top" })
    t:ok(lo2:input(Panel.LOCAL, lb, nowMs), "the operator works with zero cleared pockets")
    t:ok(lo2:tick(nowMs)["self/top"], "local button pulses")
    nowMs = nowMs + 600
    t:ok(not lo2:tick(nowMs)["self/top"], "local button pulse expires like any other")

    -- the operator is not a pocket: they must not appear in the devices list
    t:eq(#lo2:pockets(nowMs), 0, "the local operator is not listed as a pocket")

    -- ---------- sessions list (the manual PC's Sessions tab) ----------
    nowMs = 9700000
    local ss = make()
    ss:setSecureSet({
        { address = "zz", expiresAt = nowMs + 10000 },
        { address = "aa", expiresAt = nowMs + 20000 },
        { address = "old", expiresAt = nowMs - 1 }, -- already lapsed
    })
    local list = ss:sessions(nowMs)
    t:eq(#list, 2, "sessions lists only live ones")
    t:eq(list[1].address, "aa", "sessions sorted by address")
    t:eq(list[1].remaining, 20, "sessions report seconds remaining")

    -- ---------- fallback modes: normally-on and hold ----------
    -- Default (off) is the fail-closed behaviour every test above relied on. These cover the
    -- two new resting behaviours a switch can be configured for.
    nowMs = 10000000
    local fb = make()
    fb:onPresence(ALICE, 5, nowMs)

    -- normally-ON: rests energised with nobody around; a pocket holds it OFF; it reverts.
    local no = fb:add({ name = "Open Gate", type = "switch", target = "self/back", fallback = "on" })
    t:ok(fb:tick(nowMs)["self/back"], "a normally-on switch rests ENERGISED (no pocket needed)")
    t:eq(fb.controls[no].owner, nil, "resting-on has no owner")
    fb:input(ALICE, no, nowMs)                      -- tap to hold it off
    t:ok(not fb:tick(nowMs)["self/back"], "tapping a normally-on switch holds it OFF")
    t:eq(fb.controls[no].owner, ALICE, "held off -> alice owns it (a switch owned while OFF)")
    fb:setSecureSet({})                             -- alice's session ends
    t:ok(fb:tick(nowMs)["self/back"], "losing authority reverts a normally-on switch to ON")
    t:eq(fb.controls[no].owner, nil, "and releases ownership")

    -- HOLD: keeps whatever state it was in when authority lapses.
    nowMs = 10100000
    local hd = make()
    hd:onPresence(ALICE, 5, nowMs)
    local ho = hd:add({ name = "Latch", type = "switch", target = "self/top", fallback = "hold" })
    t:ok(not hd:tick(nowMs)["self/top"], "a hold switch starts off (no resting drive)")
    hd:input(ALICE, ho, nowMs)
    t:ok(hd:tick(nowMs)["self/top"], "on after a tap")
    hd:setSecureSet({})                             -- session ends
    t:ok(hd:tick(nowMs)["self/top"], "HOLD keeps it on despite losing authority")
    t:eq(hd.controls[ho].owner, nil, "ownership released, but the state is kept")
    hd:setSecureSet({ { address = ALICE, expiresAt = nowMs + 300000 } })
    hd:onPresence(ALICE, 5, nowMs)
    hd:input(ALICE, ho, nowMs)
    t:ok(not hd:tick(nowMs)["self/top"], "a different input still turns a held switch off")

    -- ---------- cooldown: a per-control lock that freezes it while ticking ----------
    nowMs = 10200000
    local cd = make()
    cd:onPresence(ALICE, 5, nowMs)
    local cs = cd:add({ name = "Gate", type = "latch", target = "self/left", cooldown = 5 })
    t:ok(cd:input(ALICE, cs, nowMs), "first tap is accepted")
    t:ok(cd:tick(nowMs)["self/left"], "...and it still pulses (the fire that armed the cooldown)")
    local ok_, reason_ = cd:input(ALICE, cs, nowMs + 1000)
    t:ok(not ok_ and reason_ == Panel.COOLDOWN, "a tap during the cooldown is refused")
    local _, cr = cd:stateFor(ALICE, {}, nowMs + 2000)
    t:eq(cr[1].cooldown, 3, "the remaining cooldown is reported to the pocket")
    cd:onPresence(ALICE, 5, nowMs + 6000)
    t:ok(cd:input(ALICE, cs, nowMs + 6000), "after the cooldown lapses, taps work again")

    -- a cooldown freezes fallback too: a switch mid-cooldown holds despite losing authority
    nowMs = 10250000
    local cf = make()
    cf:onPresence(ALICE, 5, nowMs)
    local cfs = cf:add({ name = "Hold", type = "switch", target = "self/right", cooldown = 5 })
    cf:input(ALICE, cfs, nowMs)
    t:ok(cf:tick(nowMs)["self/right"], "on, mid-cooldown")
    cf:setSecureSet({}) -- authority lost
    t:ok(cf:tick(nowMs + 1000)["self/right"], "the cooldown freezes it on despite the loss")
    t:ok(not cf:tick(nowMs + 6000)["self/right"], "once the cooldown lapses, the deferred fallback drops it")

    -- ---------- button feedback: `fired` only lights on a CONFIRMED pulse ----------
    nowMs = 10300000
    local bf = make()
    bf:onPresence(ALICE, 5, nowMs)
    local bbtn = bf:add({ name = "Ping", type = "button", target = "self/front" })
    bf:input(ALICE, bbtn, nowMs)
    local _, b0 = bf:stateFor(ALICE, {}, nowMs)
    t:eq(b0[1].fired, false, "a fresh press hasn't been confirmed yet")
    bf:tick(nowMs); bf:observeFeedback({ ["self/front"] = true }, nowMs)
    local _, b1 = bf:stateFor(ALICE, {}, nowMs)
    t:eq(b1[1].fired, true, "seeing the pulse high confirms the fire")
    bf:onPresence(ALICE, 5, nowMs); bf:input(ALICE, bbtn, nowMs) -- a new press resets the confirm
    local _, b2 = bf:stateFor(ALICE, {}, nowMs)
    t:eq(b2[1].fired, false, "a new press clears the confirm until it fires again")

    -- ---------- new fields survive a reboot; the pocket learns invert ----------
    local ex = make()
    local eid = ex:add({ name = "G", type = "switch", use = "gate", target = "self/back",
                         fallback = "on", invert = true, cooldown = 20 })
    local ecfg = ex:exportConfig()
    t:eq(ecfg[eid].fallback, "on", "export keeps fallback")
    t:eq(ecfg[eid].invert, true, "export keeps invert")
    t:eq(ecfg[eid].cooldown, 20, "export keeps cooldown")
    local efresh = make()
    efresh:loadConfig(ecfg)
    t:eq(efresh.controls[eid].fallback, "on", "fallback survives a reload")
    t:eq(efresh.controls[eid].cooldown, 20, "cooldown survives a reload")
    t:eq(ex:listForPocket()[1].invert, true, "the pocket is told invert (to word the state)")
    t:eq(ex:listForPocket()[1].fallback, nil, "but NOT the fallback (that's manual-side only)")

    -- ---------- latch: a button-style pulse that remembers an on/off state ----------
    nowMs = 10400000
    local lt = make()
    lt:onPresence(ALICE, 5, nowMs)
    local la = lt:add({ name = "Gate", type = "latch", use = "gate", target = "self/back" })
    lt:input(ALICE, la, nowMs)
    t:ok(lt:tick(nowMs)["self/back"], "a latch tap PULSES its output")
    t:eq(lt.controls[la].on, true, "...and remembers it is now ON")
    nowMs = nowMs + 700 -- past the 0.5s pulse
    t:ok(not lt:tick(nowMs)["self/back"], "the pulse ends by itself (momentary, like a button)")
    t:eq(lt.controls[la].on, true, "but the remembered state stays ON")
    lt:onPresence(ALICE, 5, nowMs)
    lt:input(ALICE, la, nowMs)
    t:ok(lt:tick(nowMs)["self/back"], "tapping again pulses to flip it")
    t:eq(lt.controls[la].on, false, "...and remembers it is now OFF")

    -- stateFor reports the CONFIRMED state: only a pulse actually seen high advances it, so a
    -- dropped pulse never moves the pocket UI (non-optimistic).
    nowMs = 10450000
    local ls = make()
    ls:onPresence(ALICE, 5, nowMs)
    local lsid = ls:add({ name = "L", type = "latch", target = "self/top" })
    ls:input(ALICE, lsid, nowMs)
    local _, l0 = ls:stateFor(ALICE, {}, nowMs)
    t:eq(l0[1].on, false, "the tracked flip is NOT shown until the pulse is confirmed")
    ls:tick(nowMs); ls:observeFeedback({ ["self/top"] = true }, nowMs) -- pulse seen high
    local _, l1 = ls:stateFor(ALICE, {}, nowMs)
    t:eq(l1[1].on, true, "once the pulse fires, the confirmed state advances")
    t:eq(l1[1].err, nil, "a latch never flags a signal error")

    -- fallback OFF: losing authority PULSES it back off
    nowMs = 10500000
    local lf = make()
    lf:onPresence(ALICE, 5, nowMs)
    local lfid = lf:add({ name = "G", type = "latch", target = "self/left", fallback = "off" })
    lf:input(ALICE, lfid, nowMs); lf:tick(nowMs + 700)
    t:eq(lf.controls[lfid].on, true, "latch on, owned")
    lf:setSecureSet({})
    t:ok(lf:tick(nowMs + 700)["self/left"], "losing authority PULSES the latch toward fallback")
    t:eq(lf.controls[lfid].on, false, "...and remembers it is now off")
    t:eq(lf.controls[lfid].owner, nil, "ownership released")

    -- fallback ON (normally-open latch): rests on, is held off, reverts on loss
    nowMs = 10600000
    local ln = make()
    ln:onPresence(ALICE, 5, nowMs)
    local lnid = ln:add({ name = "Open", type = "latch", target = "self/right", fallback = "on" })
    t:ok(ln:tick(nowMs)["self/right"], "a normally-on latch pulses ITSELF on at rest")
    t:eq(ln.controls[lnid].on, true, "...and remembers on")
    nowMs = nowMs + 700
    ln:tick(nowMs) -- let the resting pulse age out
    ln:onPresence(ALICE, 5, nowMs)
    ln:input(ALICE, lnid, nowMs)
    t:eq(ln.controls[lnid].on, false, "tapping holds it off")
    ln:setSecureSet({})
    t:ok(ln:tick(nowMs)["self/right"], "losing authority pulses it back to its resting ON")
    t:eq(ln.controls[lnid].on, true, "remembered on again")
end
