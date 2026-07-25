--- EasyKey elevator monitor (headless, terminal UI) — the PC at the lift shaft.
---
--- The fourth kind of controller, and the simplest: it has no opinions. It does exactly two
--- things for the elevator controllers the server has approved:
---   * REPORTS what its redstone reads. A Create Elevator Contact emits a signal while the
---     cabin is stopped at its floor, so "which floor is the cabin on" is just an input on
---     this computer, and the controller turns that into a position.
---   * PULSES an output when told to. That is what calls a Create elevator to a floor, and
---     doing it from here means the controller needs no cable run to the shaft at all — the
---     call rides an encrypted ecnet2 tunnel instead of a wire.
---
--- Trust runs both ways and neither end decides for itself:
---   * this PC must be APPROVED by the server, or it reports nothing and drives nothing;
---   * a pulse is obeyed only from an address in the server's CONTROL list, so a rogue PC
---     that opens a tunnel to us cannot summon lifts.
---
--- The pulse is TIMED HERE, not by the controller. A controller that dies mid-call, or a
--- message that arrives late, can therefore only ever cost you a call that doesn't happen —
--- never a call contact stuck energised with a lift permanently summoned.
local SecureNet  = require("easykey.secure_net")
local Util       = require("shared.util")
local Config     = require("easykey.config")
local Protocol   = require("easykey.protocol")
local RedstoneIO = require("easykey.redstone_io")
local Console    = require("easykey.ui.elevmon_console")
local Discovery  = require("easykey.discovery")
local Link       = require("easykey.link")
local KVStore    = require("shared.ui.kvstore")

local net = SecureNet.open({ identityPath = Config.identityPath })

-- ---------- pairing (same flow as every other EasyKey device) ----------
local function pair()
    term.clear(); term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan); print("EasyKey Elevator Monitor - pairing")
    term.setTextColor(colors.lightGray); print("Searching for the server...")
    local found = Discovery.find(net.side, 3)
    if #found == 0 then
        term.setTextColor(colors.red)
        print("No server answered. Is it running + has an ender modem?")
        print("Retrying in 5s..."); sleep(5); return nil
    end
    term.setTextColor(colors.white)
    print("Check the fingerprint against your SERVER screen:")
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
    term.setTextColor(colors.lime); print("Pinned server " .. SecureNet.fingerprint(pick.address))
    return pick.address
end

local serverAddress = Discovery.readPinned(Config.serverFile)
while not serverAddress do serverAddress = pair() end

-- ---------- hardware ----------
local io_ = RedstoneIO.new()
io_:discover()

local sideStore = KVStore.load(Config.sidesFile)
local function bundledSides()
    local set = {}
    for key, v in pairs(sideStore:all()) do if v and v.bundled then set[key] = true end end
    return set
end
local sides = bundledSides()
io_:allOff(sides) -- boot cold: a reboot must never leave a lift summoned

local console = Console.new()

-- ---------- state ----------
local serverLink  = nil
local lastServer  = 0
local approved    = false
local trusted     = {}   -- address -> true: elevator controllers the SERVER approved
local ctrls       = {}   -- connId -> { link, address }
local pulses      = {}   -- output id -> epoch ms the pulse ends
local inputs      = {}   -- id -> bool, what the world drives into us
local outputs     = {}   -- id -> bool, read back from our own hardware
local dirty       = true -- report at once when anything changes

-- ---------- tunnels ----------
local serverProto = net:protocol(Protocol.NAMES.SERVER)
local elevProto   = net:protocol(Protocol.NAMES.ELEVATOR)
elevProto:listen()

local function connectServer()
    local conn = serverProto:connect(serverAddress)
    if not conn then return nil end
    serverLink = Link.new(conn)
    serverLink:send(Protocol.hello(Protocol.ROLES.ELEVMON))
    return conn
end

--- How many controllers we have actually identified (a tunnel that never spoke doesn't count).
local function controllerCount()
    local n = 0
    for _, e in pairs(ctrls) do if e.address and trusted[e.address] then n = n + 1 end end
    return n
end

local function channelRows()
    local rows = {}
    for _, e in ipairs(io_:enumerate(sides)) do
        rows[#rows + 1] = { id = e.id, input = inputs[e.id] or false,
                            output = outputs[e.id] or false, pulsing = pulses[e.id] ~= nil,
                            device = e.device, side = e.side }
    end
    return rows
end

local function draw()
    local ok, err = pcall(function()
        console:draw({
            serverFp = SecureNet.fingerprint(serverAddress),
            serverUp = (Util.now() - lastServer) < (Config.timing.server_offline_after * 1000),
            approved = approved,
            myFp = net:myFingerprint(),
            controllers = controllerCount(),
            channels = channelRows(),
        })
    end)
    if not ok then
        local f = fs.open("/easykey_error.txt", "a")
        if f then f.writeLine(os.date("%H:%M:%S") .. "  " .. tostring(err)); f.close() end
    end
end

-- ---------- redstone ----------
--- Drive the outputs from the live pulse set, then read BOTH directions back. Idempotent, so
--- it is safe to call every tick; a pulse whose time is up simply stops being in the map.
local function applyAndRead(now)
    local states = {}
    for id, expires in pairs(pulses) do
        if now >= expires then pulses[id] = nil else states[id] = true end
    end
    io_:apply(states, sides)
    local newIn = io_:readInputs(sides)
    local newOut = io_:readBack(sides)
    -- Only report on an actual change: a lift shaft is idle almost all the time, and a
    -- heartbeat covers the "still alive" case.
    for id, v in pairs(newIn) do if (inputs[id] or false) ~= v then dirty = true end end
    for id, v in pairs(newOut) do if (outputs[id] or false) ~= v then dirty = true end end
    inputs, outputs = newIn, newOut
end

--- Refuse to drive anything at all. Used when the server withdraws approval: an unapproved
--- monitor is dead, exactly like an unapproved panel.
local function goCold()
    pulses = {}
    io_:allOff(sides)
    inputs = io_:readInputs(sides)
    outputs = io_:readBack(sides)
    dirty = true
end

-- ---------- reporting ----------
--- May we talk to this peer at all? Both halves matter: WE must be approved (a revoked monitor
--- goes silent, not just inert), and the peer must be a controller the server named.
local function mayServe(entry)
    return approved and entry ~= nil and entry.address ~= nil and trusted[entry.address] == true
end

local function reportTo(entry)
    if not mayServe(entry) then return end
    entry.link:send(Protocol.elevState(inputs, outputs))
end

local function reportAll()
    for _, e in pairs(ctrls) do reportTo(e) end
end

local function sendIoTo(entry)
    if not mayServe(entry) then return end
    local ids = {}
    for _, e in ipairs(io_:enumerate(sides)) do ids[#ids + 1] = e.id end
    entry.link:send(Protocol.elevIo(ids))
end

--- Bundling a side redefines its channels, so every controller's floor form is now looking at
--- a stale list. Re-publish rather than let a floor point at a channel that no longer exists.
local function sendIoAll()
    for _, e in pairs(ctrls) do sendIoTo(e) end
end

-- ---------- a controller asked for a pulse ----------
local function onPulse(address, message)
    if not approved then console:say("refused a call: not approved"); return end
    if not trusted[address] then
        console:say("refused a call from " .. SecureNet.fingerprint(address) .. " (not approved)")
        return
    end
    local target = message.target
    if type(target) ~= "string" then return end
    -- The channel must exist on THIS computer. A controller working from a stale channel list
    -- would otherwise silently "call" a floor that isn't wired.
    local exists = false
    for _, e in ipairs(io_:enumerate(sides)) do
        if e.id == target then exists = true; break end
    end
    if not exists then
        console:say("no such channel: " .. target)
        return
    end
    local seconds = tonumber(message.seconds) or Config.elevator.pressSeconds
    -- Clamp, whoever asked and however they asked: a call contact held down would leave the
    -- lift permanently summoned, and no legitimate call needs more than a moment.
    seconds = math.max(0.1, math.min(Config.elevmon.maxPulse, seconds))
    local now = Util.now()
    local expires = now + seconds * 1000
    -- extend rather than shorten, so overlapping calls can't cut a pulse short
    if not pulses[target] or pulses[target] < expires then pulses[target] = expires end
    applyAndRead(now)
    dirty = true
end

-- ---------- operator input ----------
local function onAction(action)
    if not action or action.kind == "redraw" then return end
    if action.kind == "bundle" then
        local rows = console:rowsFor({ channels = channelRows() })
        local row = rows[console.sel]
        if not row then console:say("nothing selected"); return end
        local key = RedstoneIO.sideKey(row.device, row.side)
        local cur = sideStore:get(key)
        -- everything on the side goes off first: its channels are about to be redefined
        io_:allOff(sides)
        pulses = {}
        sideStore:set(key, { bundled = not (cur and cur.bundled) })
        sides = bundledSides()
        io_:allOff(sides)
        console.sel = 1; console.scroll = 0
        console:say(key .. ((cur and cur.bundled) and " -> plain side" or " -> bundled (16 colours)"))
        applyAndRead(Util.now())
        sendIoAll() -- the controllers' channel lists just changed underneath them
    end
end

-- ---------- main ----------
local function main()
    connectServer()
    applyAndRead(Util.now())
    draw()

    local tick = os.startTimer(0.25)
    local push = os.startTimer(Config.elevmon.statePush)
    local retry = os.startTimer(Config.timing.reconnect_after)

    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == tick then
            applyAndRead(Util.now())
            if dirty then dirty = false; reportAll() end
            draw()
            tick = os.startTimer(0.25)

        elseif e1 == "timer" and ev[2] == push then
            -- heartbeat: a controller treats silence as "no position data", so this must be
            -- steady even when the shaft has been idle for an hour
            reportAll()
            push = os.startTimer(Config.elevmon.statePush)

        elseif e1 == "timer" and ev[2] == retry then
            if (Util.now() - lastServer) >= (Config.timing.server_offline_after * 1000) then
                connectServer()
            end
            retry = os.startTimer(Config.timing.reconnect_after)

        elseif e1 == "key" or e1 == "char" then
            local rows = console:rowsFor({ channels = channelRows() })
            onAction(console:onInput(e1, ev[2], #rows))
            draw()

        else
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and elevProto:isMine(e) then
                -- Accept any tunnel; being connected grants nothing. What matters is whether
                -- the authenticated address is on the server's control list.
                local conn = elevProto:accept(e.request, Protocol.peerHello())
                ctrls[conn.id] = { link = Link.new(conn), address = nil }
            elseif kind == "message" and Protocol.validate(e.message) then
                local t = e.message.type
                if serverLink and serverLink:owns(e.connId) then
                    serverLink:onInbound()
                    lastServer = Util.now()
                    if t == Protocol.TYPES.STATUS then
                        local was = approved
                        approved = (e.message.state == Protocol.STATUS.APPROVED)
                        if not approved then
                            -- Forget who we were told to trust as well as going cold. The list
                            -- came with an approval we no longer have, and a re-approval will
                            -- bring a fresh one.
                            trusted = {}
                            goCold()
                            console:say("not approved by the server - calls refused")
                        elseif not was then
                            console:say("approved")
                        end
                        draw()
                    elseif t == Protocol.TYPES.CONTROL_LIST then
                        -- Who may order us to pulse. The server decides; we only obey.
                        -- The shape is checked, not assumed: Protocol.validate only guards the
                        -- version and the type, so a non-table here would kill the main loop
                        -- on `ipairs` and take the shaft's whole reporting with it.
                        trusted = {}
                        local addrs = e.message.addresses
                        if type(addrs) ~= "table" then addrs = {} end
                        for _, a in ipairs(addrs) do
                            if type(a) == "string" then trusted[a] = true end
                        end
                        approved = true -- the server only pushes lists to approved devices
                        sendIoAll(); reportAll()
                        draw()
                    end
                else
                    local entry = ctrls[e.connId]
                    if entry then
                        entry.link:onInbound()
                        if e.sender then entry.address = e.sender end
                        if t == Protocol.TYPES.ELEV_ATTACH then
                            if trusted[e.sender] then
                                console:say("lift controller " .. SecureNet.fingerprint(e.sender)
                                    .. " attached")
                                sendIoTo(entry); reportTo(entry)
                            else
                                console:say("ignored " .. SecureNet.fingerprint(e.sender)
                                    .. " (not an approved controller)")
                            end
                            draw()
                        elseif t == Protocol.TYPES.ELEV_PULSE then
                            onPulse(e.sender, e.message)
                            reportTo(entry)
                            draw()
                        end
                    end
                end
            end
        end
    end
end

parallel.waitForAny(main, net.daemon)
