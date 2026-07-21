--- A connection wrapper that makes ecnet2's handshake timing safe to ignore.
---
--- Why this exists: ecnet2's `Connection:send()` throws
---   "can't send on an incomplete connection"
--- until at least one message has been received on that connection. That's inherent to
--- the Noise XK handshake — the initiator must get the responder's reply before it can
--- encrypt anything. So the natural-looking
---     local conn = proto:connect(addr); conn:send(hello)
--- always fails, and if the caller wrapped it in pcall the failure is *silent*: the
--- peer simply never hears from you.
---
--- A Link removes that trap. Send whenever you like; anything sent before the tunnel is
--- up is queued and flushed automatically the moment it completes. Call `onInbound()`
--- for every message that arrives on the connection — the first one means the handshake
--- finished.
---@class Link
local Link = {}
Link.__index = Link

--- @param conn table|nil an ecnet2 Connection (nil is tolerated: a dead link)
function Link.new(conn)
    return setmetatable({
        conn = conn,
        ready = false,
        queue = {},
        lastError = nil,
    }, Link)
end

--- Is the tunnel established (i.e. has the peer replied)?
function Link:isReady() return self.ready end

--- Does this link own the given ecnet2 connection id?
function Link:owns(connId)
    return self.conn ~= nil and connId ~= nil and self.conn.id == connId
end

--- Raw send; records rather than hides failures.
function Link:_raw(message)
    local ok, err = pcall(function() self.conn:send(message) end)
    if not ok then self.lastError = tostring(err) end
    return ok
end

--- Send, queueing until the tunnel is up. Use for messages that MUST arrive
--- (e.g. HELLO). Returns false only if there is no connection at all.
function Link:send(message)
    if not self.conn then return false end
    if not self.ready then
        self.queue[#self.queue + 1] = message
        return true
    end
    return self:_raw(message)
end

--- Send only if the tunnel is already up, otherwise drop. Use for messages that go
--- stale instantly (e.g. a proximity ping) — queueing those would just replay old
--- positions the moment the tunnel opens.
function Link:sendIfReady(message)
    if not self.conn or not self.ready then return false end
    return self:_raw(message)
end

--- Call for EVERY message received on this connection. The first one means the
--- handshake completed, so anything queued is flushed in order.
function Link:onInbound()
    if self.ready then return end
    self.ready = true
    local queued = self.queue
    self.queue = {}
    for _, message in ipairs(queued) do self:_raw(message) end
end

--- Number of messages waiting for the tunnel to come up (diagnostics/tests).
function Link:queued() return #self.queue end

return Link
