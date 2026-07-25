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

    -- ---------- elevators ----------
    -- The new roles are additive: a device already in the field has an older protocol.lua
    -- that simply lacks these names, and the version must NOT move or every existing pocket
    -- would start rejecting the server.
    t:eq(P.VERSION, 2, "adding elevator messages did not bump the wire version")
    t:eq(P.ROLES.ELEVATOR, "elevator", "the elevator controller has its own role")
    t:eq(P.ROLES.ELEVMON, "elevmon", "the shaft monitor has its own role")
    t:ok(P.NAMES.ELEVATOR ~= P.NAMES.CONTROL and P.NAMES.ELEVATOR ~= P.NAMES.SERVER,
        "controller<->monitor traffic gets its own protocol name (hence its own channel)")

    local ml = P.monitorList({ "m1", "m2" })
    t:eq(ml.type, P.TYPES.MONITOR_LIST, "monitor-list type")
    t:eq(#ml.addresses, 2, "monitor list carries addresses")
    t:eq(#P.monitorList().addresses, 0, "an empty monitor list is an empty table, never nil")
    t:ok(P.validate(ml), "monitor list validates")

    local at = P.elevAttach()
    t:eq(at.type, P.TYPES.ELEV_ATTACH, "attach type")
    t:eq(at.address, nil, "attach claims no identity (the tunnel proves it)")

    local eio = P.elevIo({ "self/back", "self/left:pink" })
    t:eq(eio.type, P.TYPES.ELEV_IO, "elev-io type")
    t:eq(eio.channels[2], "self/left:pink", "a bundled colour survives the wire")
    t:eq(#P.elevIo().channels, 0, "an empty channel list is an empty table")

    local est = P.elevState({ ["self/left"] = true }, { ["self/back"] = false })
    t:eq(est.type, P.TYPES.ELEV_STATE, "elev-state type")
    t:eq(est.inputs["self/left"], true, "state carries the inputs it read")
    t:eq(est.outputs["self/back"], false, "state carries its own output readback")
    t:ok(P.validate(est), "elev state validates")

    local ep = P.elevPulse("self/top", 0.5)
    t:eq(ep.type, P.TYPES.ELEV_PULSE, "elev-pulse type")
    t:eq(ep.target, "self/top", "pulse names the channel")
    t:near(ep.seconds, 0.5, 1e-6, "pulse carries its length")

    -- validation rejects junk / version skew
    t:ok(not P.validate(nil), "nil rejected")
    t:ok(not P.validate({}), "empty rejected")
    t:ok(not P.validate({ v = 1, type = "x" }), "old v1 message rejected")
    t:ok(not P.validate({ v = P.VERSION }), "missing type rejected")
end
