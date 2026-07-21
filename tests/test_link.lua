--- Regression tests for Link — the fix for the bug that broke pairing in-game.
---
--- ecnet2's Connection:send() THROWS "can't send on an incomplete connection" until at
--- least one message has been received. The pocket did `connect()` then immediately
--- `send(HELLO)`, the throw was swallowed by a pcall, and the server never heard from
--- it: the pocket sat on "connecting..." forever with no error anywhere.
---
--- The fake connection below reproduces exactly that throwing behaviour, so this stays
--- caught if anyone reintroduces a bare send-before-ready.
return function(t)
    local Link = require("easykey.link")
    t:describe("link")

    --- Mimics ecnet2.Connection: refuses to send until it has received something.
    local function fakeConn(id)
        local c = { id = id or "c1", sent = {}, complete = false }
        function c:send(message)
            assert(self.complete, "can't send on an incomplete connection")
            self.sent[#self.sent + 1] = message
        end
        return c
    end

    -- the exact in-game failure: send immediately after connect
    local conn = fakeConn()
    local link = Link.new(conn)
    t:ok(not link:isReady(), "a fresh link is not ready")
    t:ok(link:send({ type = "hello" }), "send before the tunnel is up is accepted")
    t:eq(#conn.sent, 0, "nothing hits the wire while incomplete")
    t:eq(link:queued(), 1, "the message is queued, not lost")

    -- the peer's reply completes the tunnel -> queue flushes
    conn.complete = true
    link:onInbound()
    t:ok(link:isReady(), "link is ready after the first inbound message")
    t:eq(#conn.sent, 1, "queued message is flushed on completion")
    t:eq(conn.sent[1], { type = "hello" }, "the flushed message is intact")
    t:eq(link:queued(), 0, "queue is drained")

    -- subsequent sends go straight out, in order
    link:send({ n = 1 })
    link:send({ n = 2 })
    t:eq(#conn.sent, 3, "later sends go out immediately")
    t:eq(conn.sent[2], { n = 1 }, "order preserved 1")
    t:eq(conn.sent[3], { n = 2 }, "order preserved 2")

    -- multiple queued messages flush in order
    local c2 = fakeConn("c2")
    local l2 = Link.new(c2)
    l2:send({ n = "a" }); l2:send({ n = "b" }); l2:send({ n = "c" })
    t:eq(l2:queued(), 3, "three queued")
    c2.complete = true
    l2:onInbound()
    t:eq(#c2.sent, 3, "all three flushed")
    t:eq(c2.sent[1], { n = "a" }, "flush order 1")
    t:eq(c2.sent[3], { n = "c" }, "flush order 3")

    -- onInbound is idempotent (every message calls it; only the first matters)
    l2:onInbound(); l2:onInbound()
    t:eq(#c2.sent, 3, "repeat onInbound does not resend")

    -- sendIfReady DROPS while incomplete (stale pings must not queue up)
    local c3 = fakeConn("c3")
    local l3 = Link.new(c3)
    t:ok(not l3:sendIfReady({ type = "presence" }), "sendIfReady drops while incomplete")
    t:eq(l3:queued(), 0, "dropped, not queued")
    c3.complete = true
    l3:onInbound()
    t:ok(l3:sendIfReady({ type = "presence" }), "sendIfReady sends once ready")
    t:eq(#c3.sent, 1, "presence reached the wire")

    -- connection ownership routing
    t:ok(l3:owns("c3"), "owns its own connection id")
    t:ok(not l3:owns("other"), "does not own a foreign id")
    t:ok(not l3:owns(nil), "nil id is not owned")

    -- a dead link (no connection) must not blow up
    local dead = Link.new(nil)
    t:ok(not dead:send({ x = 1 }), "send on a dead link returns false")
    t:ok(not dead:sendIfReady({ x = 1 }), "sendIfReady on a dead link returns false")
    t:ok(not dead:owns("c1"), "dead link owns nothing")

    -- a genuine send failure is recorded, not silently swallowed
    local c4 = fakeConn("c4")
    local l4 = Link.new(c4)
    c4.complete = true
    l4:onInbound()
    c4.send = function() error("modem exploded", 0) end
    t:ok(not l4:send({ x = 1 }), "failed send reports false")
    t:ok(l4.lastError ~= nil, "failure is recorded for diagnostics")
end
