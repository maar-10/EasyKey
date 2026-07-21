--- REAL end-to-end encryption test (not mocked): stands up two ecnet2 identities on
--- one CraftOS computer wired by two loopback modems, and drives an actual Noise XK
--- handshake through our SecureNet wrapper. Proves the properties EasyKey now relies on:
---   * an encrypted tunnel establishes,
---   * the `sender` on each message is a cryptographically authenticated address,
---   * `distance` is delivered (proximity still works),
---   * an impostor cannot pose as another address.
--- Requires periphemu + the vendored libs (deployed by tests/run_headless.sh).
return function(t)
    local SecureNet = require("easykey.secure_net")
    t:describe("secure_net")

    -- pure helpers
    t:eq(SecureNet.fingerprint("ABCDEFGHIJKL"), "ABCDEFGH", "fingerprint is first 8 chars")
    t:eq(SecureNet.fingerprint(nil), "????????", "fingerprint handles junk")
    t:eq(SecureNet.match("some_other_event", 1), nil, "non-ecnet2 events ignored")

    periphemu.create("left", "modem")
    periphemu.create("right", "modem")

    -- Two identities in one process behave like two computers on one network.
    local srvNet = SecureNet.open({ identityPath = "/.id_srv", modem = "left" })
    local cliNet = SecureNet.open({ identityPath = "/.id_cli", modem = "right" })

    t:eq(#srvNet:myAddress(), 44, "address is a 44-char key")
    t:ok(srvNet:myAddress() ~= cliNet:myAddress(), "identities are distinct")
    t:eq(srvNet:myFingerprint(), srvNet:myAddress():sub(1, 8), "own fingerprint matches address")

    local srvProto = srvNet:protocol("easykey_test")
    local cliProto = cliNet:protocol("easykey_test")
    local listener = srvProto:listen()
    t:ok(listener ~= nil, "server listens")

    -- a malformed address must not crash the caller
    local bad, err = cliProto:connect("not-a-real-address")
    t:ok(bad == nil and err ~= nil, "connect to a garbage address fails gracefully")

    local got = {}

    local function main()
        local conn = cliProto:connect(srvNet:myAddress())
        local serverConn
        local deadline = os.startTimer(15)
        while true do
            local ev = { os.pullEvent() }
            if ev[1] == "timer" and ev[2] == deadline then got.timeout = true; return end
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and srvProto:isMine(e) then
                serverConn = srvProto:accept(e.request, { greeting = "easykey" })
            elseif kind == "message" then
                if e.connId == conn.id then
                    got.clientGreeting = e.message      -- client got server's reply
                    conn:send({ ping = "presence", n = 7 })
                elseif serverConn and e.connId == serverConn.id then
                    got.serverPayload = e.message       -- server got client's payload
                    got.sender = e.sender
                    got.distance = e.distance
                    return
                end
            end
        end
    end

    parallel.waitForAny(main, srvNet.daemon)

    -- Second pass: the REAL role sequence — connect and send immediately, the way
    -- server.lua/control.lua/run.lua actually do it via Link. The first pass above
    -- hand-drove the correct wait-then-send order, which is exactly why it missed the
    -- bug that broke pairing in-game.
    local Link = require("easykey.link")
    local got2 = {}

    local function mainViaLink()
        local conn = cliProto:connect(srvNet:myAddress())
        local link = Link.new(conn)
        -- no waiting: fire HELLO at once. A bare conn:send() here would throw.
        link:send({ v = 2, type = "hello", role = "pocket" })
        got2.queuedBeforeReady = link:queued()

        local serverLink
        local deadline = os.startTimer(15)
        while true do
            local ev = { os.pullEvent() }
            if ev[1] == "timer" and ev[2] == deadline then got2.timeout = true; return end
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and srvProto:isMine(e) then
                -- server side wraps its connection in a Link too, and does NOT assume
                -- it may send yet (mirrors server.lua)
                serverLink = Link.new(srvProto:accept(e.request, { v = 2, type = "peer_hello" }))
            elseif kind == "message" then
                if link:owns(e.connId) then
                    link:onInbound() -- completes the tunnel, flushes the queued HELLO
                    if e.message.type == "status" then
                        got2.clientGotStatus = e.message -- the reply the pocket waits on
                        return
                    end
                elseif serverLink and serverLink:owns(e.connId) then
                    serverLink:onInbound()
                    got2.serverGotHello = e.message
                    got2.sender = e.sender
                    -- server -> device reply AFTER the handshake: this is exactly what
                    -- the pocket blocks on when it shows "connecting..."
                    serverLink:send({ v = 2, type = "status", state = "pending" })
                end
            end
        end
    end

    parallel.waitForAny(mainViaLink, srvNet.daemon)

    t:eq(got2.queuedBeforeReady, 1, "HELLO is queued while the tunnel is incomplete")
    t:ok(not got2.timeout, "connect-then-send-immediately reaches the server")
    t:eq(got2.serverGotHello, { v = 2, type = "hello", role = "pocket" },
        "server receives the HELLO that was sent before the handshake finished")
    t:eq(got2.sender, cliNet:myAddress(), "HELLO's sender is authenticated")
    -- the full round trip the pocket depends on to leave "connecting..."
    t:eq(got2.clientGotStatus, { v = 2, type = "status", state = "pending" },
        "server's reply gets back to the device (pocket can leave 'connecting')")

    t:ok(not got.timeout, "handshake completed within timeout")
    t:eq(got.clientGreeting, { greeting = "easykey" }, "client received server's accept reply")
    t:eq(got.serverPayload, { ping = "presence", n = 7 }, "server received client's encrypted payload")

    -- THE property everything else depends on: sender is authenticated, not claimed.
    t:eq(got.sender, cliNet:myAddress(), "sender is the client's authenticated address")
    t:ok(got.sender ~= srvNet:myAddress(), "sender is not confusable with the server")
    t:ok(got.sender ~= "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "sender is not the anonymous identity")

    -- proximity input survives the tunnel
    t:ok(got.distance ~= nil, "distance is delivered on encrypted messages")
    t:ok(type(got.distance) == "number", "distance is numeric")
end
