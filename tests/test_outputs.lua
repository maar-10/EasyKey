--- Tests for the control PC's output state machine.
---
--- The press re-arm rule gets the most attention: a button that fires twice can leave a
--- complex Create door stuck half-open, so "exactly one pulse until EVERYONE leaves" is
--- a correctness requirement, not a nicety.
return function(t)
    local Outputs = require("easykey.logic.outputs")
    t:describe("outputs")

    local nowMs = 1000000
    local function now() return nowMs end
    local ALICE = "aliceAddress"
    local MALLORY = "malloryAddress"

    local function make(defaults)
        local o = Outputs.new({
            now = now,
            defaults = defaults or { range = 4, stale = 2, pressSeconds = 0.5 },
        })
        o:ensure("self/back", { device = "self", side = "back" })
        o:setSecureSet({ { address = ALICE, expiresAt = nowMs + 300000 } })
        return o
    end

    -- ---------- defaults ----------
    local o = make()
    t:eq(o.outputs["self/back"].type, "off", "a newly discovered output starts OFF")
    t:eq(o.outputs["self/back"].range, 4, "new output takes the default range")
    t:eq(#o.order, 1, "discovery order tracked")
    o:ensure("self/back") -- rediscovery must not reset settings
    o:configure("self/back", { name = "Main", type = "toggle", range = 6 })
    o:ensure("self/back")
    t:eq(o.outputs["self/back"].name, "Main", "rediscovery keeps the operator's name")
    t:eq(o.outputs["self/back"].type, "toggle", "rediscovery keeps the type")
    t:eq(o.outputs["self/back"].range, 6, "rediscovery keeps the range")

    -- ---------- off never emits ----------
    local off = make()
    off:onPresence(ALICE, 1, nowMs)
    local states = off:tick(nowMs)
    t:ok(not states["self/back"], "type 'off' never emits, even with a secure pocket on top of it")

    -- ---------- toggle: on WHILE in range ----------
    local tg = make()
    tg:configure("self/back", { type = "toggle" })
    t:ok(not tg:tick(nowMs)["self/back"], "toggle is off with nobody around (locked)")

    tg:onPresence(ALICE, 2, nowMs)
    t:ok(tg:tick(nowMs)["self/back"], "toggle turns on when a secure pocket is in range")

    nowMs = nowMs + 1000
    tg:onPresence(ALICE, 2, nowMs)
    t:ok(tg:tick(nowMs)["self/back"], "toggle stays on while they stay")

    -- walks out of range: the ping still arrives, just from further away
    nowMs = nowMs + 1000
    tg:onPresence(ALICE, 9, nowMs)
    t:ok(not tg:tick(nowMs)["self/back"], "toggle turns off as soon as they leave range")

    -- goes silent entirely -> stale window closes it
    nowMs = nowMs + 1000
    tg:onPresence(ALICE, 1, nowMs)
    t:ok(tg:tick(nowMs)["self/back"], "back on when they return")
    nowMs = nowMs + 3000 -- > stale (2s), no pings
    t:ok(not tg:tick(nowMs)["self/back"], "a pocket that goes silent can't hold it on forever")

    -- ---------- press: exactly one pulse per entry ----------
    nowMs = 2000000
    local pr = make()
    pr:configure("self/back", { type = "press" })

    pr:onPresence(ALICE, 1, nowMs)
    t:ok(pr:tick(nowMs)["self/back"], "press fires on entering range")

    nowMs = nowMs + 100
    pr:onPresence(ALICE, 1, nowMs)
    t:ok(pr:tick(nowMs)["self/back"], "pulse is still high mid-press")

    nowMs = nowMs + 600 -- past pressSeconds (0.5s)
    pr:onPresence(ALICE, 1, nowMs)
    t:ok(not pr:tick(nowMs)["self/back"], "pulse ends after pressSeconds")

    -- THE rule: staying in range must not fire again
    for _ = 1, 10 do
        nowMs = nowMs + 1000
        pr:onPresence(ALICE, 1, nowMs)
        t:ok(not pr:tick(nowMs)["self/back"], "press does NOT re-fire while they stay in range")
    end

    -- leaving alone does not fire
    nowMs = nowMs + 1000
    pr:onPresence(ALICE, 9, nowMs)
    t:ok(not pr:tick(nowMs)["self/back"], "leaving range does not fire a press")

    -- re-entering fires exactly once again
    nowMs = nowMs + 1000
    pr:onPresence(ALICE, 1, nowMs)
    t:ok(pr:tick(nowMs)["self/back"], "press fires again after leaving and re-entering")
    nowMs = nowMs + 600
    pr:onPresence(ALICE, 1, nowMs)
    t:ok(not pr:tick(nowMs)["self/back"], "and only once")

    -- ---------- press re-arm needs EVERYONE to leave ----------
    nowMs = 3000000
    local two = make()
    two:configure("self/back", { type = "press" })
    two:setSecureSet({
        { address = ALICE, expiresAt = nowMs + 300000 },
        { address = "bob", expiresAt = nowMs + 300000 },
    })
    two:onPresence(ALICE, 1, nowMs)
    t:ok(two:tick(nowMs)["self/back"], "fires for the first arrival")
    nowMs = nowMs + 600
    two:onPresence(ALICE, 1, nowMs); two:onPresence("bob", 1, nowMs)
    t:ok(not two:tick(nowMs)["self/back"], "a second person arriving does not re-fire")

    -- alice leaves, bob stays -> still occupied -> no re-arm
    nowMs = nowMs + 1000
    two:onPresence(ALICE, 9, nowMs); two:onPresence("bob", 1, nowMs)
    t:ok(not two:tick(nowMs)["self/back"], "one leaving while another stays does not re-arm")
    nowMs = nowMs + 1000
    two:onPresence(ALICE, 1, nowMs); two:onPresence("bob", 1, nowMs)
    t:ok(not two:tick(nowMs)["self/back"], "alice re-entering does not fire: it never re-armed")

    -- both leave -> re-arms
    nowMs = nowMs + 1000
    two:onPresence(ALICE, 9, nowMs); two:onPresence("bob", 9, nowMs)
    two:tick(nowMs)
    nowMs = nowMs + 1000
    two:onPresence("bob", 1, nowMs)
    t:ok(two:tick(nowMs)["self/back"], "fires once everyone left and someone returned")

    -- ---------- insecure pockets are invisible ----------
    nowMs = 4000000
    local ins = make()
    ins:configure("self/back", { type = "toggle" })
    ins:onPresence(MALLORY, 1, nowMs) -- authenticated, but no session
    t:ok(not ins:tick(nowMs)["self/back"], "a pocket without a secure session emits nothing")
    t:eq(ins:nearbyCount(nowMs), 0, "insecure pockets aren't counted as nearby")

    -- session expiry locks it again mid-stay
    nowMs = 5000000
    local exp = make()
    exp:configure("self/back", { type = "toggle" })
    exp:setSecureSet({ { address = ALICE, expiresAt = nowMs + 1000 } })
    exp:onPresence(ALICE, 1, nowMs)
    t:ok(exp:tick(nowMs)["self/back"], "on while the session is live")
    nowMs = nowMs + 1500 -- session lapsed
    exp:onPresence(ALICE, 1, nowMs)
    t:ok(not exp:tick(nowMs)["self/back"], "output locks the instant the session expires")

    -- revocation (server pushes an empty set) locks it immediately
    nowMs = 6000000
    local rev = make()
    rev:configure("self/back", { type = "toggle" })
    rev:onPresence(ALICE, 1, nowMs)
    t:ok(rev:tick(nowMs)["self/back"], "on before revoke")
    rev:setSecureSet({})
    t:ok(not rev:tick(nowMs)["self/back"], "revoked pocket loses the output at once")

    -- ---------- nil distance (cross-dimension) ----------
    local nd = make()
    nd:configure("self/back", { type = "toggle" })
    t:ok(not nd:onPresence(ALICE, nil, nowMs), "nil-distance ping is rejected")
    t:ok(not nd:tick(nowMs)["self/back"], "cross-dimension presence never emits")

    -- ---------- per-output range ----------
    nowMs = 7000000
    local rg = make()
    rg:ensure("self/top", { device = "self", side = "top" })
    rg:configure("self/back", { type = "toggle", range = 8 }) -- outer gate
    rg:configure("self/top", { type = "toggle", range = 2 })  -- inner vault
    rg:onPresence(ALICE, 5, nowMs)
    local st = rg:tick(nowMs)
    t:ok(st["self/back"], "far output (range 8) opens at distance 5")
    t:ok(not st["self/top"], "near output (range 2) stays shut at distance 5")

    -- ---------- type cycling + changes ----------
    local cy = make()
    t:eq(cy:cycleType("self/back"), "toggle", "cycle off -> toggle")
    t:eq(cy:cycleType("self/back"), "press", "cycle toggle -> press")
    t:eq(cy:cycleType("self/back"), "off", "cycle press -> off")

    -- changing type must not leave a pulse energised
    nowMs = 8000000
    local sw = make()
    sw:configure("self/back", { type = "press" })
    sw:onPresence(ALICE, 1, nowMs)
    t:ok(sw:tick(nowMs)["self/back"], "press high")
    sw:configure("self/back", { type = "off" })
    t:ok(not sw:tick(nowMs)["self/back"], "switching type drops the live pulse")

    -- tick reports transitions only
    nowMs = 9000000
    local ch = make()
    ch:configure("self/back", { type = "toggle" })
    local _s, c0 = ch:tick(nowMs)
    t:eq(#c0, 0, "no change when nothing happens")
    ch:onPresence(ALICE, 1, nowMs)
    local _s1, c1 = ch:tick(nowMs)
    t:eq(#c1, 1, "one change when it turns on")
    t:ok(c1[1].on, "change says on")
    local _s2, c2 = ch:tick(nowMs)
    t:eq(#c2, 0, "no change on the next tick")

    -- ---------- config persistence ----------
    local cfg = make()
    cfg:configure("self/back", { name = "Gate", type = "press", range = 7 })
    local exported = cfg:exportConfig()
    t:eq(exported["self/back"].name, "Gate", "export keeps the name")
    t:eq(exported["self/back"].type, "press", "export keeps the type")
    t:eq(exported["self/back"].range, 7, "export keeps the range")

    local fresh = make()
    fresh:loadConfig(exported)
    t:eq(fresh.outputs["self/back"].name, "Gate", "settings survive a reload")
    t:eq(fresh.outputs["self/back"].range, 7, "range survives a reload")
    fresh:loadConfig({ ["ghost/side"] = { type = "toggle" } }) -- must not crash
    t:eq(fresh.outputs["ghost/side"], nil, "config for a vanished output is ignored")

    -- garbage settings are rejected, not stored
    fresh:configure("self/back", { type = "explode" })
    t:eq(fresh.outputs["self/back"].type, "press", "an unknown type is rejected")
    fresh:configure("self/back", { range = -5 })
    t:eq(fresh.outputs["self/back"].range, 7, "a negative range is rejected")

    -- ---------- remove ----------
    local rm = make()
    t:ok(rm:remove("self/back"), "remove returns true")
    t:eq(#rm.order, 0, "removed output leaves the order")
    t:ok(not rm:remove("self/back"), "removing twice is false")
end
