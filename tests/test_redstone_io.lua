--- Tests for the control PC's redstone hardware layer, against mock devices.
---
--- The bundled-cable bitmask gets the most attention: it bit us on the first project.
--- setBundledOutput takes ONE mask per side whose bits are the ON colours, so a bug here
--- doesn't fail loudly — it quietly drives the wrong IE channel.
return function(t)
    local RedstoneIO = require("easykey.redstone_io")
    t:describe("redstone_io")

    --- A mock that records what was written and can be read back, like the real API.
    local function mockDevice()
        local d = { plain = {}, bundled = {} }
        function d.setOutput(side, on) d.plain[side] = on and true or false end
        function d.getOutput(side) return d.plain[side] or false end
        function d.setBundledOutput(side, mask) d.bundled[side] = mask end
        function d.getBundledOutput(side) return d.bundled[side] or 0 end
        return d
    end

    local self_ = mockDevice()
    local relay = mockDevice()
    local peripheralMock = {
        getNames = function() return { "monitor_0", "redstone_relay_3" } end,
        getType = function(n)
            if n == "redstone_relay_3" then return "redstone_relay" end
            return "monitor"
        end,
        wrap = function(n) if n == "redstone_relay_3" then return relay end end,
    }

    local io_ = RedstoneIO.new({ peripheral = peripheralMock, redstone = self_ })

    -- ---------- discovery ----------
    local names = io_:discover()
    t:eq(names[1], "self", "this computer is always first")
    t:eq(names[2], "redstone_relay_3", "wired redstone relays are discovered")
    t:eq(#names, 2, "non-redstone peripherals (the monitor) are ignored")

    -- ---------- enumeration: plain sides ----------
    local list = io_:enumerate({})
    t:eq(#list, 12, "6 sides of the computer + 6 of the relay")
    local ids = {}
    for _, e in ipairs(list) do ids[e.id] = e end
    t:ok(ids["self/back"] ~= nil, "computer side is an output")
    t:ok(ids["redstone_relay_3/left"] ~= nil, "relay side is an output")
    t:eq(ids["self/back"].device, "self", "meta carries the device")
    t:eq(ids["self/back"].side, "back", "meta carries the side")
    t:eq(ids["self/back"].color, nil, "a plain side has no colour")

    -- ---------- enumeration: a bundled side swaps 1 plain for 16 colours ----------
    local bundled = { ["self/back"] = true }
    local list2 = io_:enumerate(bundled)
    t:eq(#list2, 27, "12 - 1 plain + 16 colours = 27")
    local ids2 = {}
    for _, e in ipairs(list2) do ids2[e.id] = e end
    t:eq(ids2["self/back"], nil, "the plain side is gone once it's bundled")
    t:ok(ids2["self/back:white"] ~= nil, "white channel exists")
    t:ok(ids2["self/back:black"] ~= nil, "black channel exists")
    t:eq(ids2["self/back:pink"].color, "pink", "meta carries the colour")
    t:ok(ids2["self/top"] ~= nil, "other sides stay plain")

    -- ---------- apply: plain ----------
    io_:apply({ ["self/back"] = true, ["redstone_relay_3/left"] = true }, {})
    t:eq(self_.plain.back, true, "computer side driven on")
    t:eq(self_.plain.top, false, "unset sides are driven OFF, not left alone")
    t:eq(relay.plain.left, true, "relay side driven on")
    t:eq(relay.plain.right, false, "relay's other sides off")

    -- ---------- apply: the bundled bitmask ----------
    io_:apply({ ["self/back:white"] = true }, bundled)
    t:eq(self_.bundled.back, colors.white, "one colour -> that colour's bit")

    io_:apply({ ["self/back:white"] = true, ["self/back:pink"] = true }, bundled)
    t:eq(self_.bundled.back, colors.white + colors.pink, "two colours -> summed bits")

    io_:apply({ ["self/back:black"] = true }, bundled)
    t:eq(self_.bundled.back, colors.black, "only the on colour is in the mask")

    io_:apply({}, bundled)
    t:eq(self_.bundled.back, 0, "nothing on -> mask 0 (all IE channels off)")

    -- every colour at once = all 16 bits
    local all = {}
    local expected = 0
    for _, c in ipairs(RedstoneIO.COLORS) do
        all["self/back:" .. c] = true
        expected = expected + colors[c]
    end
    io_:apply(all, bundled)
    t:eq(self_.bundled.back, expected, "all 16 colours -> full mask")
    t:eq(expected, 65535, "the full mask is 16 bits set")

    -- a bundled side must not also be driven as a plain side
    io_:apply({ ["self/back"] = true }, bundled)
    t:eq(self_.bundled.back, 0, "a plain id is ignored on a bundled side")

    -- ---------- readBack: what the hardware really reports ----------
    io_:apply({ ["self/back:pink"] = true, ["self/top"] = true }, bundled)
    local fb = io_:readBack(bundled)
    t:eq(fb["self/back:pink"], true, "readBack decodes the pink bit as on")
    t:eq(fb["self/back:white"], false, "readBack decodes an unset bit as off")
    t:eq(fb["self/top"], true, "readBack reports a plain side")
    t:eq(fb["self/bottom"], false, "readBack reports an off side")

    -- readBack must decode EVERY bit correctly, not just low ones (black = 32768)
    io_:apply(all, bundled)
    local fbAll = io_:readBack(bundled)
    for _, c in ipairs(RedstoneIO.COLORS) do
        t:eq(fbAll["self/back:" .. c], true, "readBack decodes " .. c)
    end

    -- and none when the mask is empty
    io_:apply({}, bundled)
    local fbNone = io_:readBack(bundled)
    for _, c in ipairs(RedstoneIO.COLORS) do
        t:eq(fbNone["self/back:" .. c], false, "readBack decodes " .. c .. " as off")
    end

    -- readBack reflects reality, not intent: something else changed the hardware
    self_.plain.front = true
    t:eq(io_:readBack(bundled)["self/front"], true, "readBack shows the hardware's actual state")

    -- ---------- allOff ----------
    io_:apply(all, bundled)
    io_:allOff(bundled)
    t:eq(self_.bundled.back, 0, "allOff clears the bundled mask")
    t:eq(self_.plain.top, false, "allOff clears plain sides")
    t:eq(relay.plain.left, false, "allOff clears relay sides")

    -- ---------- id helpers ----------
    t:eq(RedstoneIO.plainId("self", "back"), "self/back", "plain id format")
    t:eq(RedstoneIO.colorId("self", "back", "pink"), "self/back:pink", "colour id format")
    t:eq(RedstoneIO.sideKey("redstone_relay_3", "left"), "redstone_relay_3/left", "side key format")

    -- ---------- a device that throws must not take the loop down ----------
    local angry = mockDevice()
    angry.setOutput = function() error("relay yanked out", 0) end
    local io2 = RedstoneIO.new({
        peripheral = {
            getNames = function() return { "redstone_relay_9" } end,
            getType = function() return "redstone_relay" end,
            wrap = function() return angry end,
        },
        redstone = mockDevice(),
    })
    io2:discover()
    local ok = pcall(function() io2:apply({ ["redstone_relay_9/back"] = true }, {}) end)
    t:ok(ok, "a peripheral that errors mid-write doesn't crash the controller")
end
