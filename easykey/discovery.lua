--- Server discovery for pairing (bootstrap only).
---
--- A fresh pocket/control has to learn the server's 44-char address, and typing that on
--- a pocket keypad is not realistic. So we do the SSH trick: discover candidates over a
--- plain broadcast, then have the human verify an 8-char **fingerprint** against the
--- server's screen before pinning it forever.
---
--- This broadcast is deliberately unauthenticated — it carries only a public key, which
--- is not a secret. It is NOT the security boundary: the fingerprint check is. An
--- attacker can answer a discovery, but to be trusted they would have to produce an
--- address whose first 8 base64 chars match the ones on your server screen, which is
--- infeasible here. Everything after pairing runs over authenticated ecnet2 tunnels.
---
--- Uses the raw modem directly on one well-known channel. ecnet2 has its own channels
--- and ignores this one, so the two coexist on the same modem.
local Discovery = {}

--- Well-known bootstrap channel. Not configurable: a device must be able to find the
--- server before it has any config.
Discovery.CHANNEL = 4410

local QUERY = "easykey_discover"
local REPLY = "easykey_server_is"

local function wrap(side)
    local m = peripheral.wrap(side)
    if not m then error("No modem on side '" .. tostring(side) .. "'", 0) end
    return m
end

--- Server side: start answering discovery queries.
function Discovery.serve(side)
    wrap(side).open(Discovery.CHANNEL)
end

--- Server side: if this event is a discovery query, answer it with our address.
--- Returns true if the event was handled.
function Discovery.handle(side, address, event, evSide, channel, replyChannel, message)
    if event ~= "modem_message" then return false end
    if channel ~= Discovery.CHANNEL then return false end
    if type(message) ~= "table" or message.q ~= QUERY then return false end
    wrap(side).transmit(replyChannel or Discovery.CHANNEL, Discovery.CHANNEL,
        { q = REPLY, address = address })
    return true
end

--- Device side: broadcast a query and collect answers for `timeout` seconds.
--- Returns an array of { address, distance } sorted by distance (nearest first) —
--- the nearest answer is usually your own server, but the human still confirms.
function Discovery.find(side, timeout)
    local m = wrap(side)
    m.open(Discovery.CHANNEL)
    m.transmit(Discovery.CHANNEL, Discovery.CHANNEL, { q = QUERY })

    local seen, out = {}, {}
    local timer = os.startTimer(timeout or 2)
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == timer then break end
        if ev[1] == "modem_message" and ev[3] == Discovery.CHANNEL then
            local msg, dist = ev[5], ev[6]
            if type(msg) == "table" and msg.q == REPLY and type(msg.address) == "string"
                and not seen[msg.address] then
                seen[msg.address] = true
                out[#out + 1] = { address = msg.address, distance = dist }
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.distance or math.huge) < (b.distance or math.huge)
    end)
    return out
end

--- Read the pinned server address, or nil if this device hasn't paired yet.
function Discovery.readPinned(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local addr = (f.readLine() or ""):gsub("%s+", "")
    f.close()
    if addr == "" then return nil end
    return addr
end

--- Pin a server address permanently (after the human confirmed its fingerprint).
function Discovery.pin(path, address)
    local f = fs.open(path, "w")
    f.write(address)
    f.close()
end

--- Forget the pinned server (re-pair from scratch).
function Discovery.unpin(path)
    if fs.exists(path) then fs.delete(path) end
end

return Discovery
