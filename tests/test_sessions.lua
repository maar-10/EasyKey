--- Unit tests for the server session store (pure, injected clock + token gen).
return function(t)
    local Sessions = require("easykey.logic.sessions")
    t:describe("sessions")

    -- controllable clock
    local nowMs = 1000000
    local function now() return nowMs end
    local s = Sessions.new({ now = now, sessionSeconds = 300 })

    -- grant creates a live, secure session
    local A = "addrAAAA"
    local B = "addrBBBB"
    local a = s:grant(A, "alice")
    t:eq(a.address, A, "grant sets address")
    t:eq(a.expiresAt, nowMs + 300 * 1000, "grant expiry = now + session")
    t:ok(s:isSecure(A), "granted pocket is secure")
    t:eq(s:remaining(A), 300, "remaining is full at grant")
    t:eq(s:count(), 1, "one live session")

    -- a second, independent pocket (concurrency)
    s:grant(B, "bob")
    t:eq(s:count(), 2, "two concurrent sessions")
    t:ok(s:isSecure(B), "second pocket secure")

    -- snapshot is sorted by pocketId and only live
    local snap = s:snapshot()
    t:eq(#snap, 2, "snapshot has both")
    t:eq(snap[1].address, A, "snapshot sorted 1")
    t:eq(snap[2].address, B, "snapshot sorted 2")

    -- advance past the first pocket's expiry only... both same expiry here, so
    -- advance to just before expiry: still secure
    nowMs = nowMs + 299 * 1000
    t:ok(s:isSecure(A), "still secure just before expiry")
    t:eq(s:remaining(A), 1, "1s remaining")

    -- advance past expiry: sessions lapse
    nowMs = nowMs + 2 * 1000
    t:ok(not s:isSecure(A), "expired after timeout")
    t:eq(s:count(), 0, "no live sessions after expiry")
    t:eq(#s:snapshot(), 0, "snapshot empty after expiry")

    -- expireDue removes and reports lapsed sessions
    local s2 = Sessions.new({ now = now, sessionSeconds = 10 })
    s2:grant("c1")
    s2:grant("c2")
    nowMs = nowMs + 11 * 1000
    local removed = s2:expireDue()
    t:eq(#removed, 2, "expireDue reports both")

    -- revoke
    local s3 = Sessions.new({ now = now, sessionSeconds = 100 })
    s3:grant("z1")
    t:ok(s3:revoke("z1"), "revoke returns true when present")
    t:ok(not s3:isSecure("z1"), "revoked pocket not secure")
    t:ok(not s3:revoke("z1"), "revoke returns false when absent")

    -- re-grant refreshes the expiry window
    s3:grant("z2")
    nowMs = nowMs + 5000
    local after = s3:grant("z2")
    t:eq(after.expiresAt, nowMs + 100 * 1000, "re-grant refreshes expiry")
end
