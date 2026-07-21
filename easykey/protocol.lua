--- EasyKey message protocol (v2 — inside encrypted ecnet2 tunnels).
---
--- Everything now travels through an authenticated, replay-protected tunnel, which
--- removes most of what v1's envelope carried:
---   * no `from` / `to`  — the tunnel identifies both peers, and `sender` is a
---     cryptographically authenticated address rather than a claim we must trust,
---   * no `seq`          — ecnet2 rejects replays and reorders for us,
---   * no session tokens — being able to speak on the tunnel from an approved address
---     IS the proof; a bearer token would only add something stealable.
--- What's left is a version stamp, a type, and the payload.
---@class EKProtocol
local Protocol = {}

--- Wire-format version. Bump only on an incompatible message-format change.
local PROTOCOL_VERSION = 2
Protocol.VERSION = PROTOCOL_VERSION

--- Protocol names (these also select the ecnet2 channel, so the two legs are
--- separated at the transport level).
Protocol.NAMES = {
    SERVER  = "easykey_server",  -- pocket->server, control->server
    CONTROL = "easykey_control", -- pocket->control (presence)
}

--- Device roles. A device announces its role in HELLO so the server knows which
--- approval queue to put it in. This is only a *claim* and grants nothing: what a
--- device may do is decided by which approved list the operator puts its address in.
Protocol.ROLES = {
    POCKET  = "pocket",
    CONTROL = "control", -- proximity door controller
    MANUAL  = "manual",  -- remote panel: fires on button/switch taps from a pocket
}

Protocol.TYPES = {
    -- responder -> initiator: the reply that completes the handshake. ecnet2 forbids
    -- the initiator from sending until it has received this, so every accept carries it.
    PEER_HELLO       = "peer_hello",
    -- device -> server (first message on a new tunnel)
    HELLO            = "hello",            -- announce role
    -- pocket -> server
    REQUEST_KEYCHECK = "request_keycheck", -- ask permission to open the keypad
    SUBMIT_KEY       = "submit_key",       -- send the typed key for verification
    -- server -> pocket
    KEYPAD_GRANT     = "keypad_grant",
    KEYPAD_DENY      = "keypad_deny",      -- reason attached
    KEY_RESULT       = "key_result",       -- ok + expiresAt, or ok=false + reason
    SESSION_END      = "session_end",      -- your session stopped early (operator revoked)
    CONTROL_LIST     = "control_list",     -- trusted control addresses to ping
    STATUS           = "status",           -- approved / pending, for the pairing UI
    -- server -> control
    SECURE_SET       = "secure_set",       -- [{ address, expiresAt }] + heartbeat
    -- pocket -> control
    PRESENCE         = "presence",         -- proximity ping (sender is authenticated)
    -- manual control <-> pocket (same tunnel as PRESENCE; it is bidirectional)
    PANEL_LIST       = "panel_list",       -- manual -> pocket: what buttons/switches exist
    PANEL_STATE      = "panel_state",      -- manual -> pocket: what the redstone ACTUALLY does
    PANEL_INPUT      = "panel_input",      -- pocket -> manual: a control was tapped
}

--- What a pocket may do with a manual panel right now. The manual PC decides this, per
--- pocket, and the pocket only ever displays what it is told.
Protocol.PANEL_STATUS = {
    OK           = "ok",
    OUT_OF_RANGE = "out_of_range", -- too far from that manual PC
    DENIED       = "denied",       -- in range, but not cleared by the server
}

--- Stable reason codes for the UI.
Protocol.REASONS = {
    NOT_APPROVED   = "not_approved",   -- device is not (yet) approved on the server
    REVOKED        = "revoked",        -- an operator ended it from the server
    ALREADY_SECURE = "already_secure",
    COOLDOWN       = "cooldown",
    BAD_KEY        = "bad_key",
    OK             = "ok",
}

--- Device approval states (server -> device).
Protocol.STATUS = {
    PENDING  = "pending",  -- waiting for the operator to approve on the server
    APPROVED = "approved",
}

local function msg(msgType, fields)
    local m = fields or {}
    m.v = PROTOCOL_VERSION
    m.type = msgType
    return m
end

--- Validates an incoming table is one of ours at the right version.
--- Note: authenticity is the tunnel's job — this only guards against version skew
--- and malformed payloads, never against forgery.
function Protocol.validate(m)
    if type(m) ~= "table" then return false, "not a table" end
    if m.v ~= PROTOCOL_VERSION then
        return false, "protocol version mismatch (" .. tostring(m.v) .. ")"
    end
    if type(m.type) ~= "string" then return false, "missing type" end
    return true
end

-- ---------- responder -> initiator ----------
--- Sent as the `accept` reply. Its arrival is what completes the tunnel and lets the
--- initiator start sending (see easykey/link.lua).
function Protocol.peerHello() return msg(Protocol.TYPES.PEER_HELLO) end

-- ---------- device -> server ----------
--- First message on a fresh tunnel. `role` only routes the device to the right
--- approval queue; it confers no privilege by itself.
function Protocol.hello(role) return msg(Protocol.TYPES.HELLO, { role = role }) end

-- ---------- pocket -> server ----------
function Protocol.requestKeycheck() return msg(Protocol.TYPES.REQUEST_KEYCHECK) end
function Protocol.submitKey(key) return msg(Protocol.TYPES.SUBMIT_KEY, { key = key }) end

-- ---------- server -> pocket ----------
function Protocol.keypadGrant() return msg(Protocol.TYPES.KEYPAD_GRANT) end
function Protocol.keypadDeny(reason) return msg(Protocol.TYPES.KEYPAD_DENY, { reason = reason }) end

--- Verification outcome. On ok, carries the session expiry (utc ms) and the label of
--- the key that matched (for the server's log / "who unlocked").
function Protocol.keyResult(ok, expiresAt, reason, label)
    return msg(Protocol.TYPES.KEY_RESULT, {
        ok = ok and true or false, expiresAt = expiresAt, reason = reason, label = label,
    })
end

--- Tell a pocket its session stopped before its timer ran out. Without this the pocket
--- would keep showing a countdown (and believing it can open doors) until the clock ran
--- down, even though the server already dropped it.
function Protocol.sessionEnd(reason)
    return msg(Protocol.TYPES.SESSION_END, { reason = reason })
end

--- Trusted control addresses the pocket should open presence tunnels to.
function Protocol.controlList(addresses)
    return msg(Protocol.TYPES.CONTROL_LIST, { addresses = addresses or {} })
end

--- Approval state, so the pocket can show "awaiting approval" during pairing.
function Protocol.status(state) return msg(Protocol.TYPES.STATUS, { state = state }) end

-- ---------- server -> control ----------
--- `sessions` is an array of { address, expiresAt }. Doubles as the server heartbeat.
function Protocol.secureSet(sessions)
    return msg(Protocol.TYPES.SECURE_SET, { sessions = sessions or {}, serverTime = os.epoch("utc") })
end

-- ---------- pocket -> control ----------
--- Presence carries no identity: the tunnel's authenticated `sender` IS the identity.
function Protocol.presence() return msg(Protocol.TYPES.PRESENCE) end

-- ---------- manual control <-> pocket ----------
--- What controls exist. Sent to any pocket in range, cleared or not — you can see the
--- panel without being able to use it.
--- `controls` = array of { id, name, type = "button"|"switch" }.
function Protocol.panelList(controls)
    return msg(Protocol.TYPES.PANEL_LIST, { controls = controls or {} })
end

--- The truth about the panel, for one specific pocket.
--- `status` is that pocket's access right now; `controls` = { { id, on, err }, ... } where
--- `on` is READ BACK FROM THE REDSTONE, not what we intended, and `err` flags a control
--- whose hardware disagreed with us. The pocket renders this and nothing else — it never
--- moves a control optimistically.
function Protocol.panelState(status, controls)
    return msg(Protocol.TYPES.PANEL_STATE, { status = status, controls = controls or {} })
end

--- A pocket tapped a control. Carries no identity or authority: the tunnel proves who
--- sent it, and the manual PC decides whether it counts.
function Protocol.panelInput(controlId)
    return msg(Protocol.TYPES.PANEL_INPUT, { controlId = controlId })
end

return Protocol
