--- Tests for the shared access gate (easykey/logic/access.lua).
---
--- These are the rules that decide whether ANY redstone is allowed to move, so they get
--- tested on their own rather than only through a panel. The ones that matter:
--- approval is separate from a session, going quiet counts as out of range, and the local
--- operator is gated on this PC's own approval and nothing else.
return function(t)
    local Access = require("easykey.logic.access")
    t:describe("access")

    local nowMs = 1000000
    local function now() return nowMs end
    local ALICE, BOB = "aliceAddr", "bobAddr"

    local function make()
        local a = Access.new({ now = now, defaults = { range = 100, stale = 2 } })
        a:setSecureSet({ { address = ALICE, expiresAt = nowMs + 300000 } })
        return a
    end

    -- ---------- status ----------
    local a = make()
    t:eq(a:statusFor(ALICE), Access.OUT_OF_RANGE, "never heard from -> out of range")
    a:onPresence(ALICE, 200, nowMs)
    t:eq(a:statusFor(ALICE), Access.OUT_OF_RANGE, "beyond range -> out of range")
    a:onPresence(ALICE, 50, nowMs)
    t:eq(a:statusFor(ALICE), Access.OK, "secure + in range -> ok")
    a:onPresence(BOB, 5, nowMs)
    t:eq(a:statusFor(BOB), Access.DENIED, "in range but not cleared -> denied")

    -- Silence is never read as "still there": a pocket that stopped pinging may have been
    -- carried away, and range is the only thing stopping a distant tap.
    nowMs = nowMs + 3000
    t:eq(a:statusFor(ALICE), Access.OUT_OF_RANGE, "gone quiet -> out of range")
    nowMs = nowMs - 3000

    -- ---------- a cross-dimension ping is not "in range" of anything ----------
    local x = make()
    t:ok(not x:onPresence(ALICE, nil, nowMs), "a distance-less ping is rejected")
    t:eq(x:statusFor(ALICE), Access.OUT_OF_RANGE, "...and does not make it in range")

    -- ---------- an expired session is not a session ----------
    local e = Access.new({ now = now, defaults = { range = 100, stale = 2 } })
    e:setSecureSet({ { address = ALICE, expiresAt = nowMs + 1000 } })
    e:onPresence(ALICE, 5, nowMs)
    t:eq(e:statusFor(ALICE), Access.OK, "live session -> ok")
    nowMs = nowMs + 1500
    e:onPresence(ALICE, 5, nowMs) -- still standing right there
    t:eq(e:statusFor(ALICE), Access.DENIED, "expired session -> denied, presence notwithstanding")
    nowMs = nowMs - 1500

    -- ---------- the local operator ----------
    -- Their "session" is this PC's approval by the server, and they are always in range: the
    -- failsafe has to work when no pocket can be used, but must still die when revoked.
    local l = make()
    t:ok(l:inRange(Access.LOCAL), "the local operator is always in range")
    t:eq(l:statusFor(Access.LOCAL), Access.DENIED, "an unapproved PC denies its own operator")
    l:setApproved(true)
    t:eq(l:statusFor(Access.LOCAL), Access.OK, "an approved PC lets its operator in")
    l:setApproved(false)
    t:eq(l:statusFor(Access.LOCAL), Access.DENIED, "revoking approval kills the local panel")

    -- ---------- the lists the operator's screen shows ----------
    local s = make()
    s:setSecureSet({
        { address = ALICE, expiresAt = nowMs + 60000 },
        { address = BOB, expiresAt = nowMs - 1 },      -- already lapsed
    })
    local sessions = s:sessions(nowMs)
    t:eq(#sessions, 1, "only live sessions are listed")
    t:eq(sessions[1].address, ALICE, "...and it is the live one")
    t:eq(sessions[1].remaining, 60, "remaining seconds are rounded, not truncated to 59")

    s:onPresence(ALICE, 40, nowMs)
    s:onPresence(BOB, 5, nowMs)
    s:onPresence("farAddr", 400, nowMs)
    local seen = s:pockets(nowMs)
    t:eq(#seen, 3, "every pocket heard from lately is listed")
    t:eq(seen[1].address, BOB, "nearest first")
    t:ok(seen[1].inRange and not seen[1].secure, "BOB is near but not cleared")
    t:ok(seen[2].secure, "ALICE is cleared")
    t:ok(not seen[3].inRange, "the far one is flagged out of range, not dropped")

    nowMs = nowMs + 3000
    t:eq(#s:pockets(nowMs), 0, "pockets that went quiet drop off the list")
end
