--- EasyKey door controller (headless, terminal UI).
---
--- Holds nothing worth stealing: no keys, no master secrets — just its own wiring and
--- whatever the server currently says is secure. It keeps two encrypted tunnels open:
--- one *to* the server (to receive the secure-set) and one *listening* for pockets (to
--- receive proximity pings and measure their distance).
---
--- Every redstone channel it can reach is an output: this computer's sides, any wired
--- redstone relay's sides, and the 16 colours of any side flipped to bundled mode. Each
--- output has its own name, type (off/toggle/press) and range, all set from the console.
---
--- Nothing emits unless an authenticated pocket with a live server-granted session is
--- within that output's range. There is no code path from "no session" to "redstone on".
local SecureNet   = require("easykey.secure_net")
local Util        = require("shared.util")
local Config      = require("easykey.config")
local Protocol    = require("easykey.protocol")
local Outputs     = require("easykey.logic.outputs")
local RedstoneIO  = require("easykey.redstone_io")
local Console     = require("easykey.ui.control_console")
local Discovery   = require("easykey.discovery")
local Link        = require("easykey.link")
local KVStore     = require("shared.ui.kvstore")

local net = SecureNet.open({ identityPath = Config.identityPath })

-- ---------- pairing (unchanged) ----------
--- Find the server and have the operator confirm its fingerprint before pinning it.
local function pair()
    term.clear(); term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan); print("EasyKey Control - pairing")
    term.setTextColor(colors.lightGray)
    print("Searching for the server...")
    local found = Discovery.find(net.side, 3)
    if #found == 0 then
        term.setTextColor(colors.red)
        print("No server answered. Is it running + has an ender modem?")
        print("Retrying in 5s...")
        sleep(5)
        return nil
    end
    term.setTextColor(colors.white)
    print("Found " .. #found .. " server(s). Check the fingerprint")
    print("against your SERVER screen:")
    for i, s in ipairs(found) do
        term.setTextColor(colors.yellow)
        print(("  %d) %s   (%s blocks)"):format(i, SecureNet.fingerprint(s.address),
            tostring(s.distance or "?")))
    end
    term.setTextColor(colors.white)
    write("Type the number to trust (or q to rescan): ")
    local answer = read()
    if answer == "q" then return nil end
    local pick = found[tonumber(answer) or 0]
    if not pick then return nil end
    Discovery.pin(Config.serverFile, pick.address)
    term.setTextColor(colors.lime)
    print("Pinned server " .. SecureNet.fingerprint(pick.address))
    return pick.address
end

local serverAddress = Discovery.readPinned(Config.serverFile)
while not serverAddress do serverAddress = pair() end

-- ---------- hardware + state ----------
local io_ = RedstoneIO.new()
io_:discover()

-- Which sides carry a bundled cable. Persisted, because it changes what exists.
local sideStore = KVStore.load(Config.sidesFile)
local function bundledSides()
    local set = {}
    for key, v in pairs(sideStore:all()) do if v and v.bundled then set[key] = true end end
    return set
end

local outputs = Outputs.new({
    defaults = {
        range = Config.proximity.range,
        stale = Config.proximity.stale,
        pressSeconds = Config.proximity.pressSeconds,
    },
})

local cfgStore = KVStore.load(Config.outputsFile)

--- (Re)build the output list from the hardware + which sides are bundled, then re-apply
--- the operator's saved settings. Called at boot and whenever a side is flipped.
local function rebuild()
    local sides = bundledSides()
    local wanted = {}
    for _, e in ipairs(io_:enumerate(sides)) do
        wanted[e.id] = true
        outputs:ensure(e.id, { device = e.device, side = e.side, color = e.color })
    end
    -- drop outputs that no longer exist (a side flipped to bundled, a relay unplugged)
    for _, id in ipairs({ table.unpack(outputs.order) }) do
        if not wanted[id] then outputs:remove(id) end
    end
    outputs:loadConfig(cfgStore:all())
    return sides
end

local sides = rebuild()
io_:allOff(sides) -- boot with everything cold, before anything else can happen

local console = Console.new()
local approved = false
local lastServer = 0
local feedback = {}

local function saveOutput(id)
    local o = outputs.outputs[id]
    if o then cfgStore:set(id, { name = o.name, type = o.type, range = o.range }) end
end

-- ---------- tunnels (unchanged backend) ----------
local serverProto = net:protocol(Protocol.NAMES.SERVER)   -- we connect to the server
local pocketProto = net:protocol(Protocol.NAMES.CONTROL)  -- pockets connect to us
pocketProto:listen()

local serverLink  = nil
local pocketConns = {}

local function connectServer()
    local conn, err = serverProto:connect(serverAddress)
    if not conn then return nil, err end
    -- Queued until the server's reply completes the tunnel; ecnet2 forbids sending
    -- before that, and Link makes the wait invisible here.
    serverLink = Link.new(conn)
    serverLink:send(Protocol.hello(Protocol.ROLES.CONTROL))
    return conn
end

-- ---------- rendering ----------
local function draw()
    local ok, err = pcall(function()
        console:draw({
            serverFp = SecureNet.fingerprint(serverAddress),
            serverUp = (Util.now() - lastServer) < (Config.timing.server_offline_after * 1000),
            approved = approved,
            myFp = net:myFingerprint(),
            nearby = outputs:nearbyCount(),
            rows = outputs:snapshot(),
            feedback = feedback,
            bundledSides = sides,
        })
    end)
    if not ok then
        local f = fs.open("/easykey_error.txt", "a")
        if f then f.writeLine(os.date("%H:%M:%S") .. "  " .. tostring(err)); f.close() end
    end
end

-- ---------- operator input ----------
local function selectedId()
    local rows = outputs:snapshot()
    local row = rows[console.sel]
    return row and row.id or nil, row
end

local function onAction(action)
    if not action or action.kind == "redraw" then return end
    local id, row = selectedId()
    if not id then console:say("nothing selected"); return end

    if action.kind == "type" then
        local newType = outputs:cycleType(id)
        saveOutput(id)
        console:say((row.name ~= "" and row.name or id) .. " -> " .. tostring(newType))

    elseif action.kind == "name" then
        outputs:configure(id, { name = action.value })
        saveOutput(id)

    elseif action.kind == "range" then
        outputs:configure(id, { range = action.value })
        saveOutput(id)
        console:say("range " .. action.value .. " blocks")

    elseif action.kind == "bundle" then
        -- Flip this SIDE between plain and 16 bundled colours. Everything on the side is
        -- turned off first: the channels are about to be redefined underneath it.
        local meta = row.meta or {}
        if not meta.device or not meta.side then console:say("no side for this row"); return end
        local key = RedstoneIO.sideKey(meta.device, meta.side)
        local now = sideStore:get(key)
        local isBundled = now and now.bundled
        io_:allOff(sides)
        sideStore:set(key, { bundled = not isBundled })
        sides = rebuild()
        io_:allOff(sides)
        console.sel = 1
        console:say(key .. (isBundled and " -> plain side" or " -> bundled (16 colours)"))
    end
end

-- ---------- main loop ----------
local function main()
    connectServer()
    draw()

    local tick = os.startTimer(0.25)
    local retry = os.startTimer(Config.timing.reconnect_after)
    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == tick then
            local states = outputs:tick()
            io_:apply(states, sides)
            feedback = io_:readBack(sides) -- show what the hardware really does
            draw()
            tick = os.startTimer(0.25)

        elseif e1 == "timer" and ev[2] == retry then
            if (Util.now() - lastServer) >= (Config.timing.server_offline_after * 1000) then
                connectServer()
            end
            retry = os.startTimer(Config.timing.reconnect_after)

        elseif e1 == "key" or e1 == "char" then
            local rows = outputs:snapshot()
            onAction(console:onInput(e1, ev[2], #rows))
            draw()

        else
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and pocketProto:isMine(e) then
                -- Accept any pocket tunnel; being connected grants nothing. What matters
                -- is whether its authenticated address is in the server's secure-set.
                local conn = pocketProto:accept(e.request, Protocol.peerHello())
                pocketConns[conn.id] = true
            elseif kind == "message" and Protocol.validate(e.message) then
                local t = e.message.type
                if serverLink and serverLink:owns(e.connId) then
                    serverLink:onInbound()
                    lastServer = Util.now()
                    if t == Protocol.TYPES.SECURE_SET then
                        approved = true
                        outputs:setSecureSet(e.message.sessions)
                    elseif t == Protocol.TYPES.STATUS then
                        approved = (e.message.state == Protocol.STATUS.APPROVED)
                        if not approved then
                            -- trust withdrawn: forget every session at once
                            outputs:setSecureSet({})
                            io_:apply(outputs:tick(), sides)
                        end
                    end
                elseif pocketConns[e.connId] and t == Protocol.TYPES.PRESENCE then
                    -- `sender` is authenticated by the tunnel; `distance` is measured by
                    -- THIS computer, so neither can be claimed by the pocket.
                    if outputs:onPresence(e.sender, e.distance) then
                        local states = outputs:tick()
                        io_:apply(states, sides)
                    end
                end
            end
        end
    end
end

parallel.waitForAny(main, net.daemon)
