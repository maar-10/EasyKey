--- End-to-end logic test for the elevator roles, driven through the ACTUAL v2 protocol
--- messages that server.lua, elevator.lua, elevmon.lua and the pocket wire together.
---
--- Two things this proves that the pure tests cannot:
---   1. The FULL loop works with nothing but real messages between the four parties:
---      approval -> secure-set -> monitor list -> presence -> panel list -> tap -> pulse ->
---      the monitor's redstone -> position -> the pocket's Lifts tab lighting up.
---   2. The pocket needs NO change. The elevator's PANEL_LIST/PANEL_STATE are fed to the real
---      PanelFeed the pocket runs, and if the shape ever drifts the pocket silently stops
---      showing floors — and the pocket is the one role that cannot be patched without a
---      reinstall, so this is the guard that matters most.
return function(t)
    local Sessions  = require("easykey.logic.sessions")
    local Elevator  = require("easykey.logic.elevator")
    local PanelFeed = require("easykey.logic.panel_feed")
    local Protocol  = require("easykey.protocol")
    local Devices   = require("easykey.devices")
    t:describe("elevator flow")

    local nowMs = 3000000
    local function now() return nowMs end

    local ALICE   = "aliceAddress0000000000000000000000000000000="
    local MALLORY = "malloryAddress00000000000000000000000000000="
    local MON     = "monitorAddress00000000000000000000000000000="
    local ROGUE   = "rogueMonAddress0000000000000000000000000000="

    -- ---------- the server side ----------
    local sessions = Sessions.new({ now = now, sessionSeconds = 300 })
    -- The stores are the real thing, on scratch files, because "which list did it land in" is
    -- the whole security decision for the two new roles.
    local controls = Devices.load("/test_flow_controls.cfg")
    local monitors = Devices.load("/test_flow_monitors.cfg")
    local CTRL = "elevCtrlAddress00000000000000000000000000000="
    controls:approve(CTRL, "elevator-elevCtrl")
    monitors:approve(MON, "elevmon-monitorA")

    -- A monitor must NOT end up in the control list: that list is what pockets are told to open
    -- tunnels to, and a pocket has no business talking to a shaft monitor.
    local ctrlList = Protocol.controlList(controls:addresses())
    t:eq(#ctrlList.addresses, 1, "the control list has just the controller")
    t:eq(ctrlList.addresses[1], CTRL, "...which is the controller")
    local monList = Protocol.monitorList(monitors:addresses())
    t:eq(#monList.addresses, 1, "the monitor list has just the monitor")
    t:eq(monList.addresses[1], MON, "...which is the monitor")

    -- ---------- the controller ----------
    local elev = Elevator.new({
        now = now,
        defaults = { range = 100, stale = 2, pressSeconds = 0.5,
                     recallSeconds = 0, timeoutSeconds = 20 },
    })

    -- It only believes monitors the server named. This is the check the message exists for.
    local trustedMons = {}
    for _, a in ipairs(monList.addresses) do trustedMons[a] = true end
    t:ok(trustedMons[MON], "the server's monitor list is what the controller trusts")
    t:ok(not trustedMons[ROGUE], "a monitor the server never named is not trusted")

    -- STATUS/SECURE_SET is what marks the controller approved
    t:ok(not elev:isApproved(), "a controller starts unapproved")
    local secure = Protocol.secureSet(sessions:snapshot())
    elev:setApproved(true)
    elev:setSecureSet(secure.sessions)

    -- one lift, three floors, wired entirely through the monitor
    local lid = elev:add({ name = "Main", monitor = MON, recall = 0, timeout = 20 })
    local fG = elev:addFloor(lid, { name = "G", call = "mon:self/back", at = "mon:self/left" })
    local f1 = elev:addFloor(lid, { name = "F1", call = "mon:self/top", at = "mon:self/right" })
    local f2 = elev:addFloor(lid, { name = "F2", call = "mon:self/front", at = "mon:self/bottom" })
    t:eq(elev:monitors(), { MON }, "the controller knows which monitor to attach to")

    -- ---------- the monitor reports its channels ----------
    -- (elevmon.lua builds this from RedstoneIO:enumerate; here it is the message itself)
    local ioMsg = Protocol.elevIo({ "self/back", "self/top", "self/front",
                                    "self/left", "self/right", "self/bottom" })
    t:ok(Protocol.validate(ioMsg), "elev-io is a valid v2 message")
    local valid = {}
    for _, id in ipairs(ioMsg.channels) do valid[Elevator.monChannel(id)] = true end
    t:eq(#elev:orphanedFloors(valid), 0, "every floor is wired to a channel the monitor has")

    -- ---------- the pocket appears ----------
    local feed = PanelFeed.new({ now = now, timeout = 3 })
    local ELEV_ADDR = CTRL

    -- presence: the tunnel's authenticated sender + the distance WE measured
    t:ok(elev:onPresence(ALICE, 8, nowMs), "an in-range ping is accepted")
    local listMsg = Protocol.panelList(elev:listForPocket())
    t:ok(Protocol.validate(listMsg), "panel-list is a valid v2 message")
    feed:onList(ELEV_ADDR, listMsg.controls)

    -- An uncleared pocket must still be SHOWN the floors and told why it cannot use them —
    -- otherwise a locked pocket next to a lift looks broken rather than locked.
    local status, rows = elev:stateFor(ALICE, nowMs)
    t:eq(status, Elevator.DENIED, "no session yet -> denied")
    feed:onState(ELEV_ADDR, Protocol.panelState(status, rows).status,
        Protocol.panelState(status, rows).controls)
    local shown = feed:list()
    t:eq(#shown, 1, "the pocket has one panel")
    t:eq(#shown[1].controls, 3, "...showing all three floors even while denied")
    t:eq(shown[1].status, "denied", "...and told exactly why it cannot use them")
    for _, c in ipairs(shown[1].controls) do
        t:eq(c.use, "elevator", "a floor lands on the pocket's Lifts tab (" .. c.name .. ")")
        t:eq(c.type, "button", "...as a button")
    end
    t:eq(shown[1].controls[1].name, "Main G", "the pocket sees the lift+floor name")

    -- ---------- alice gets a session ----------
    sessions:grant(ALICE, "alice")
    elev:setSecureSet(Protocol.secureSet(sessions:snapshot()).sessions)
    t:eq(elev:statusFor(ALICE, nowMs), Elevator.OK, "cleared + in range -> ok")

    -- ---------- alice calls F2 ----------
    local tap = Protocol.panelInput(Elevator.controlId(lid, f2))
    t:ok(Protocol.validate(tap), "panel-input is a valid v2 message")
    local ok, reason = elev:input(ALICE, tap.controlId, nowMs)
    t:ok(ok, "the call is accepted (" .. tostring(reason) .. ")")

    local states, pulses = elev:tick(nowMs)
    t:eq(next(states), nil, "no local redstone: the whole lift is wired through the monitor")
    t:eq(#pulses, 1, "exactly one pulse to dispatch")
    local pulseMsg = Protocol.elevPulse(pulses[1].target, pulses[1].seconds)
    t:ok(Protocol.validate(pulseMsg), "elev-pulse is a valid v2 message")
    t:eq(pulseMsg.target, "self/front", "it names F2's call channel on the monitor")
    t:eq(pulses[1].monitor, MON, "addressed to the lift's monitor")

    -- ---------- the monitor obeys, but only the right sender ----------
    -- elevmon.lua's rule: a pulse is obeyed only from an address in the server's control list.
    local monTrusts = {}
    for _, a in ipairs(ctrlList.addresses) do monTrusts[a] = true end
    t:ok(monTrusts[CTRL], "the monitor obeys the approved controller")
    t:ok(not monTrusts[MALLORY], "the monitor ignores a PC the server never approved")

    -- `monStates` is persistent and keyed by monitor address, exactly as elevator.lua keeps it:
    -- observeFeedback is a full recompute, so it must be handed everything we currently believe,
    -- not just the latest message.
    local monStates = {}
    local function ingestState(fromAddr, msg)
        -- elevator.lua's rule: a report is stored ONLY if the server vouches for the sender.
        if not trustedMons[fromAddr] then return false end
        monStates[fromAddr] = { inputs = msg.inputs, outputs = msg.outputs }
        return true
    end

    -- it drives the channel, then reports BOTH directions back
    t:ok(ingestState(MON, Protocol.elevState({}, { [pulseMsg.target] = true })),
        "the approved monitor's report is accepted")
    elev:observeFeedback({}, monStates, nowMs)
    local _, movingRows = elev:stateFor(ALICE, nowMs)
    for _, r in ipairs(movingRows) do
        t:ok(not r.fired, "while the cabin is in transit no floor claims it")
    end

    -- ---------- the cabin arrives ----------
    nowMs = nowMs + 6000
    ingestState(MON, Protocol.elevState({ ["self/bottom"] = true }, {})) -- F2's arrival contact
    local moved = elev:observeFeedback({}, monStates, nowMs)
    t:eq(#moved, 1, "the position change is reported")
    local _, _, changes = elev:tick(nowMs)
    t:eq(#changes, 1, "arriving is logged")
    t:eq(changes[1].kind, "arrived", "...as an arrival")
    t:eq(changes[1].floor, "F2", "...at the floor alice called")

    -- ...and the pocket's own feed lights that floor up, through the real messages
    elev:onPresence(ALICE, 8, nowMs) -- presence goes stale after 2s
    local st2, rows2 = elev:stateFor(ALICE, nowMs)
    local psm = Protocol.panelState(st2, rows2)
    feed:onState(ELEV_ADDR, psm.status, psm.controls)
    local lit = feed:list()[1]
    t:eq(lit.status, "ok", "a cleared pocket is told it may use the lift")
    t:ok(lit.controls[3].fired, "the pocket's F2 button reads 'the cabin is here'")
    t:ok(not lit.controls[1].fired and not lit.controls[2].fired,
        "...and no other floor does")

    -- ---------- a rogue monitor cannot move the cabin's reported position ----------
    -- Two layers, and both are tested: the report is never stored (the server never named that
    -- address), and even if it somehow were, the lift only reads its OWN monitor's entry.
    t:ok(not ingestState(ROGUE, Protocol.elevState({ ["self/left"] = true }, {})),
        "a report from a monitor the server never approved is dropped")
    t:eq(monStates[ROGUE], nil, "...and never stored")
    monStates[ROGUE] = { inputs = { ["self/left"] = true }, outputs = {} } -- force it in anyway
    elev:observeFeedback({}, monStates, nowMs)
    local _, spoofRows = elev:stateFor(ALICE, nowMs)
    t:ok(spoofRows[3].fired, "the real monitor's position stands")
    t:ok(not spoofRows[1].fired, "a report from an unrelated address changes nothing")
    monStates[ROGUE] = nil

    -- ---------- losing the session stops calls at once ----------
    sessions:revoke(ALICE)
    elev:setSecureSet(Protocol.secureSet(sessions:snapshot()).sessions)
    local okR, whyR = elev:input(ALICE, Elevator.controlId(lid, fG), nowMs)
    t:ok(not okR and whyR == Elevator.DENIED, "a revoked pocket cannot call a floor")
    t:eq(#select(2, elev:tick(nowMs)), 0, "...and no pulse was produced")

    -- the pocket is told, rather than left on a stale screen
    local st3, rows3 = elev:stateFor(ALICE, nowMs)
    local psm3 = Protocol.panelState(st3, rows3)
    feed:onState(ELEV_ADDR, psm3.status, psm3.controls)
    t:eq(feed:list()[1].status, "denied", "the pocket is told it lost access")
    -- but it still knows where the cabin is: seeing is not using
    t:ok(feed:list()[1].controls[3].fired, "...while still being shown where the cabin is")

    -- ---------- revoking the CONTROLLER kills it entirely ----------
    sessions:grant(ALICE, "alice")
    elev:setSecureSet(Protocol.secureSet(sessions:snapshot()).sessions)
    elev:onPresence(ALICE, 8, nowMs)
    t:ok(elev:input(ALICE, Elevator.controlId(lid, fG), nowMs), "working again with a new session")
    elev:tick(nowMs) -- drain
    controls:revoke(CTRL)
    elev:setApproved(false)
    elev:setSecureSet({})
    local okC, whyC = elev:input(ALICE, Elevator.controlId(lid, f1), nowMs)
    t:ok(not okC and whyC == Elevator.DENIED, "a revoked controller refuses every call")
    local okL, whyL = elev:input(Elevator.LOCAL, Elevator.controlId(lid, f1), nowMs)
    t:ok(not okL and whyL == Elevator.DENIED, "...including from its own monitor")

    -- ---------- revoking the MONITOR loses the position, not just the tunnel ----------
    -- Stale position data is worse than none: a floor would keep showing a cabin that has gone.
    monitors:revoke(MON)
    local monList2 = Protocol.monitorList(monitors:addresses())
    t:eq(#monList2.addresses, 0, "the monitor is off the list")
    -- what elevator.lua does on a shrunken list: drop the monitor's state entirely
    local stillTrusted = {}
    for _, a in ipairs(monList2.addresses) do stillTrusted[a] = true end
    for addr in pairs(monStates) do
        if not stillTrusted[addr] then monStates[addr] = nil end
    end
    t:eq(monStates[MON], nil, "the revoked monitor's state is dropped")
    elev:observeFeedback({}, monStates, nowMs)
    local _, goneRows = elev:stateFor(ALICE, nowMs)
    for _, r in ipairs(goneRows) do
        t:ok(not r.fired, "a revoked monitor's position is forgotten, not kept")
    end

    -- ---------- cleanup ----------
    if fs.exists("/test_flow_controls.cfg") then fs.delete("/test_flow_controls.cfg") end
    if fs.exists("/test_flow_monitors.cfg") then fs.delete("/test_flow_monitors.cfg") end
end
