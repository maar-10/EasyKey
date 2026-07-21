--- Unit tests for the v2 EasyKey message protocol (inside encrypted tunnels).
return function(t)
    local P = require("easykey.protocol")
    t:describe("protocol")

    local req = P.requestKeycheck()
    t:eq(req.type, P.TYPES.REQUEST_KEYCHECK, "request type")
    t:eq(req.v, P.VERSION, "version stamped")
    t:ok(P.validate(req), "request validates")

    -- v2: no from/to/seq — the tunnel identifies the peers.
    t:eq(req.from, nil, "no forgeable 'from' field")
    t:eq(req.to, nil, "no 'to' field (point-to-point tunnel)")
    t:eq(req.seq, nil, "no seq (ecnet2 handles replay/ordering)")

    local sk = P.submitKey("12*#")
    t:eq(sk.key, "12*#", "submit carries the typed key verbatim (inside the tunnel)")

    t:eq(P.keypadGrant().type, P.TYPES.KEYPAD_GRANT, "grant type")
    t:eq(P.keypadDeny(P.REASONS.NOT_APPROVED).reason, P.REASONS.NOT_APPROVED, "deny carries reason")

    local ok = P.keyResult(true, 123456, P.REASONS.OK, "alice")
    t:eq(ok.ok, true, "result ok flag")
    t:eq(ok.expiresAt, 123456, "result expiry")
    t:eq(ok.label, "alice", "result label")
    t:eq(ok.token, nil, "no bearer token in v2")

    local bad = P.keyResult(false, nil, P.REASONS.BAD_KEY)
    t:eq(bad.ok, false, "result not-ok flag")

    local set = P.secureSet({ { address = "aaa", expiresAt = 9 } })
    t:eq(set.type, P.TYPES.SECURE_SET, "secure-set type")
    t:eq(#set.sessions, 1, "secure-set carries sessions")
    t:eq(set.sessions[1].address, "aaa", "secure-set keyed by address")
    t:ok(set.serverTime ~= nil, "secure-set stamps serverTime")

    -- session_end: how a pocket learns its session stopped early. Without it the pocket
    -- keeps counting down and believing it can open doors after an operator revoked it.
    local se = P.sessionEnd(P.REASONS.REVOKED)
    t:eq(se.type, P.TYPES.SESSION_END, "session-end type")
    t:eq(se.reason, P.REASONS.REVOKED, "session-end carries the reason")
    t:ok(P.validate(se), "session-end validates")

    local cl = P.controlList({ "c1", "c2" })
    t:eq(#cl.addresses, 2, "control list carries addresses")

    t:eq(P.status(P.STATUS.PENDING).state, P.STATUS.PENDING, "status carries state")

    -- presence carries NO identity: the tunnel's authenticated sender is the identity
    local pres = P.presence()
    t:eq(pres.type, P.TYPES.PRESENCE, "presence type")
    t:eq(pres.token, nil, "presence has no token")
    t:eq(pres.pocketId, nil, "presence claims no identity")

    -- validation rejects junk / version skew
    t:ok(not P.validate(nil), "nil rejected")
    t:ok(not P.validate({}), "empty rejected")
    t:ok(not P.validate({ v = 1, type = "x" }), "old v1 message rejected")
    t:ok(not P.validate({ v = P.VERSION }), "missing type rejected")
end
