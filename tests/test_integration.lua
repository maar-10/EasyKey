--- End-to-end logic test: drives the server session store and a control PC's
--- proximity machine through the ACTUAL v2 protocol messages, proving the
--- grant -> secure-set -> presence -> door-open -> expiry -> close flow that
--- server.lua and control.lua wire together over encrypted tunnels.
---
--- Identities here are ecnet2-style addresses. In production they arrive as the
--- authenticated `sender` of a tunnel, never as message content — so the "attacker"
--- cases below are exactly what the transport makes impossible to forge.
return function(t)
    local Sessions  = require("easykey.logic.sessions")
    local Outputs   = require("easykey.logic.outputs")
    local Protocol  = require("easykey.protocol")
    t:describe("integration")

    local nowMs = 2000000
    local function now() return nowMs end

    local ALICE = "aliceAddress0000000000000000000000000000000="
    local MALLORY = "malloryAddress00000000000000000000000000000="

    local sessions = Sessions.new({ now = now, sessionSeconds = 300 })
    local control = Outputs.new({
        now = now,
        defaults = { range = 4, stale = 2, pressSeconds = 0.5 },
    })
    control:ensure("self/back", { device = "self", side = "back" })
    control:configure("self/back", { name = "Main", type = "toggle", range = 5 })

    -- alice submits the correct key -> server grants her address a session
    local s = sessions:grant(ALICE, "alice")
    t:eq(s.address, ALICE, "session keyed by address")

    -- server pushes the secure-set; control ingests it (via the real message)
    local setMsg = Protocol.secureSet(sessions:snapshot())
    t:ok(Protocol.validate(setMsg), "secure-set is a valid v2 message")
    control:setSecureSet(setMsg.sessions)

    -- alice pings from 2 blocks away; her address comes from the tunnel's sender
    local ping = Protocol.presence()
    t:ok(Protocol.validate(ping), "presence is a valid v2 message")
    t:ok(control:onPresence(ALICE, 2, nowMs), "in-range ping from secure address accepted")
    t:ok(control:tick(nowMs)["self/back"], "output turns on for the secure pocket")

    -- an unapproved address cannot open anything, at any distance
    control:onPresence(MALLORY, 1, nowMs) -- tracked, but it holds no session
    t:ok(control:tick(nowMs)["self/back"], "alice still holds it on")
    control:setSecureSet({})
    t:ok(not control:tick(nowMs)["self/back"], "with no live sessions nothing emits")
    control:setSecureSet(setMsg.sessions)

    -- out of range: no open (distance is measured by the receiving control PC)
    local far = Outputs.new({ now = now, defaults = { range = 3, stale = 2, pressSeconds = 0.5 } })
    far:ensure("self/back", { device = "self", side = "back" })
    far:configure("self/back", { type = "toggle", range = 3 })
    far:setSecureSet(setMsg.sessions)
    far:onPresence(ALICE, 10, nowMs)
    t:ok(not far:tick(nowMs)["self/back"], "secure but far away -> output stays off")

    -- time passes past the session; server expires + re-pushes an empty set
    nowMs = nowMs + 301 * 1000
    local removed = sessions:expireDue()
    t:eq(#removed, 1, "server expires the session")
    t:eq(removed[1], ALICE, "expiry reports the address")
    local setMsg2 = Protocol.secureSet(sessions:snapshot())
    t:eq(#setMsg2.sessions, 0, "re-pushed secure-set is empty")
    control:setSecureSet(setMsg2.sessions)

    -- the output locks the moment the session is gone
    control:onPresence(ALICE, 2, nowMs)
    t:ok(not control:tick(nowMs)["self/back"], "output locks once the session expired")

    -- alice can re-authenticate afterwards and re-open the door
    nowMs = nowMs + 1000
    sessions:grant(ALICE, "alice")
    control:setSecureSet(Protocol.secureSet(sessions:snapshot()).sessions)
    t:ok(control:onPresence(ALICE, 1, nowMs), "new session ping accepted")
    t:ok(control:tick(nowMs)["self/back"], "output turns on again under the new session")

    -- a revoked (lost) pocket loses access immediately on the next push
    sessions:revoke(ALICE)
    control:setSecureSet(Protocol.secureSet(sessions:snapshot()).sessions)
    control:onPresence(ALICE, 1, nowMs)
    t:ok(not control:tick(nowMs)["self/back"], "revoked pocket loses the output at once")
end
