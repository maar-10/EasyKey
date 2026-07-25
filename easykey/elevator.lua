--- EasyKey elevator controller (advanced computer + monitor).
---
--- The third control type, and a specialist. The manual panel can already drive a simple
--- one-shot lift as an ordinary control; this exists for the case it handles badly — a shaft
--- with many floors, where every floor is a call button and the interesting question is not
--- "is it on" but "where is the cabin".
---
--- It publishes each floor to the pocket as a plain panel button with `use = "elevator"`, on
--- the same tunnel and in the same shape the manual panel uses. The pocket therefore renders
--- lift floors on its Lifts tab without knowing elevators exist, and two fields it already
--- draws carry the extra meaning: the confirm circle fills green on the floor the cabin is
--- AT, and the "~Ns" marker is the lift's recall lock.
---
--- Every floor's call output and arrival input may live on THIS computer or on that lift's
--- elevator monitor (a PC at the shaft). A "mon:" channel is pulsed by an encrypted message
--- rather than a wire, which is what removes the cable run to the top of the shaft. Nothing
--- else in the system has to care which it is.
---
--- Trust is the server's, in both directions: this PC must be approved before it accepts any
--- input, and it believes position reports only from monitor addresses the server sent it.
---
--- Three coroutines under `parallel`: basalt.run (monitor), net.daemon (transport), and main
--- (below). UI callbacks never touch the modem — they queue events main consumes.
local basalt     = require("basalt")
local SecureNet  = require("easykey.secure_net")
local Util       = require("shared.util")
local Config     = require("easykey.config")
local Protocol   = require("easykey.protocol")
local Elevator   = require("easykey.logic.elevator")
local RedstoneIO = require("easykey.redstone_io")
local Discovery  = require("easykey.discovery")
local Link       = require("easykey.link")
local App        = require("easykey.ui.elevator_app")
local Palette    = require("easykey.ui.palette")
local KVStore    = require("shared.ui.kvstore")

local net = SecureNet.open({ identityPath = Config.identityPath })

-- ---------- pairing (same flow as every other EasyKey device) ----------
local function pair()
    term.clear(); term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan); print("EasyKey Elevator Control - pairing")
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

local elev = Elevator.new({
    defaults = {
        range = Config.elevator.range,
        stale = Config.proximity.stale,
        pressSeconds = Config.elevator.pressSeconds,
        recallSeconds = Config.elevator.recallSeconds,
        timeoutSeconds = Config.elevator.timeoutSeconds,
    },
})
local elevStore = KVStore.load(Config.elevatorFile)
elev:loadConfig(elevStore:all())

-- range is operator-tunable and persisted alongside the lifts
local settings = KVStore.load(Config.elevatorFile .. ".set")
elev:setRange(settings:get("range"))

-- ---------- UI ----------
local monitor = peripheral.find("monitor")
local main = basalt.createFrame()
if monitor then
    monitor.setTextScale(0.5)
    main:setTerm(monitor)
end

local app = App.build(main, Config, net:myFingerprint(), function(action, payload)
    os.queueEvent("easykey_ui", action, payload)
end)
local function log(text, level) app.log(text, level) end
local function short(a) return SecureNet.fingerprint(a) end

-- ---------- tunnels ----------
local serverProto = net:protocol(Protocol.NAMES.SERVER)
local pocketProto = net:protocol(Protocol.NAMES.CONTROL)
local monProto    = net:protocol(Protocol.NAMES.ELEVATOR)
pocketProto:listen()

local serverLink   = nil
local lastServer   = 0
local pockets      = {}   -- connId -> { link, address }
local monLinks     = {}   -- monitor address -> Link
local monChannels  = {}   -- monitor address -> array of channel ids it reported
local monStates    = {}   -- monitor address -> { inputs = { id -> bool }, outputs = ... }
local monLastSeen  = {}   -- monitor address -> epoch ms of its last report
local trustedMons  = {}   -- monitor address -> true, straight from the server
local localInputs  = {}   -- id -> bool, what this PC reads
local localOutputs = {}   -- id -> bool, read back from this PC's own hardware
local editingLift  = nil  -- lift id being edited, or false for "new"
local editingFloor = nil  -- floor id being edited, or false for "new"

--- A table, or an empty one. Every list/map field that arrives over the wire goes through this:
--- Protocol.validate only checks the version and the type, so the payload is still whatever the
--- peer sent, and a number where a table belongs would take the main loop down on the next
--- `ipairs` or index.
local function asTable(v)
    if type(v) == "table" then return v end
    return {}
end

local function connectServer()
    local conn = serverProto:connect(serverAddress)
    if not conn then return nil end
    serverLink = Link.new(conn)
    serverLink:send(Protocol.hello(Protocol.ROLES.ELEVATOR))
    return conn
end

local function saveLifts()
    -- definitions only; live state is never persisted (see Elevator:exportConfig)
    local cfg = elev:exportConfig()
    for id, l in pairs(cfg) do elevStore:set(id, l) end
    for id in pairs(elevStore:all()) do
        if not cfg[id] then elevStore:set(id, nil) end
    end
end

-- ---------- monitor tunnels ----------
--- Keep one tunnel up per monitor any lift depends on, and only to monitors the SERVER has
--- approved. A monitor we were never told about is not connected to at all — that is what
--- stops a rogue PC at the shaft from being wired in by a typo'd config.
local function connectMonitors()
    for _, addr in ipairs(elev:monitors()) do
        if trustedMons[addr] and not monLinks[addr] then
            local conn = monProto:connect(addr)
            if conn then
                monLinks[addr] = Link.new(conn)
                -- start the silence clock now, so a tunnel that never completes its handshake
                -- is reaped and retried instead of sitting dead forever
                monLastSeen[addr] = Util.now()
                monLinks[addr]:send(Protocol.elevAttach())
                log("attaching to monitor " .. short(addr), "note")
            end
        end
    end
end

--- Forget a monitor entirely: no tunnel, no channel list, and — importantly — no remembered
--- position. Stale position data is worse than none, because a floor would keep showing the
--- cabin sitting there.
local function dropMonitor(addr)
    monLinks[addr] = nil
    monChannels[addr] = nil
    monStates[addr] = nil
    monLastSeen[addr] = nil
end

--- Drop and re-open any monitor tunnel that has gone quiet.
---
--- A monitor reports every second, so silence means it rebooted, lost its modem, or was chunk-
--- unloaded. Without this a dead Link would sit in `monLinks` forever — `connectMonitors` skips
--- an address it already has one for — so a monitor reboot would cost the position readout
--- until the CONTROLLER was rebooted too. The same clock covers a tunnel that never completed
--- its handshake at all, which is the other way to get permanently stuck.
---
--- Dropping also clears the last known position, which is the honest answer: we no longer know
--- where that cabin is, and a floor still claiming it would be a lie.
local function reapMonitors()
    local cutoff = Config.timing.server_offline_after * 1000
    for addr in pairs(monLinks) do
        local seen = monLastSeen[addr] or 0
        if (Util.now() - seen) > cutoff then
            log("monitor " .. short(addr) .. " went quiet - reconnecting", "warn")
            dropMonitor(addr)
        end
    end
    connectMonitors()
end

-- ---------- channels ----------
--- Every channel a floor may be wired to: this computer's, plus each attached monitor's under
--- a "mon:" prefix. Note the prefix is deliberately not per-monitor — a floor belongs to a
--- lift, and a lift has exactly one monitor, so "mon:" is already unambiguous.
--- @param liftId string|nil restrict the monitor half to that lift's monitor
local function channelsFor(liftId)
    local out = {}
    for _, e in ipairs(io_:enumerate(sides)) do out[#out + 1] = e.id end
    local lift = liftId and elev.lifts[liftId]
    local addr = lift and lift.monitor
    if addr and monChannels[addr] then
        for _, id in ipairs(monChannels[addr]) do out[#out + 1] = Elevator.monChannel(id) end
    end
    return out
end

--- The set of channels that currently exist, for flagging floors wired to nothing.
local function validChannels(liftId)
    local set = {}
    for _, id in ipairs(channelsFor(liftId)) do set[id] = true end
    return set
end

--- The monitor addresses the SERVER has approved, sorted so the lift form's dropdown is
--- stable between openings. Nothing outside this list may be picked: an address the operator
--- invented is an address that will never report.
local function approvedMonitors()
    local out = {}
    for a in pairs(trustedMons) do out[#out + 1] = a end
    table.sort(out)
    return out
end

local function localChannelRows()
    local rows = {}
    for _, e in ipairs(io_:enumerate(sides)) do
        rows[#rows + 1] = { id = e.id, input = localInputs[e.id] or false,
                            output = localOutputs[e.id] or false,
                            device = e.device, side = e.side }
    end
    return rows
end

-- ---------- pushing to pockets ----------
local function pushState(entry)
    if not entry or not entry.address then return end
    local status, controls = elev:stateFor(entry.address)
    entry.link:send(Protocol.panelState(status, controls))
end

local function pushListTo(entry)
    if not entry or not entry.address then return end
    entry.link:send(Protocol.panelList(elev:listForPocket()))
end

--- The floor list changed: everyone's UI must follow, including dropping floors we deleted.
local function pushListAll()
    for _, e in pairs(pockets) do pushListTo(e); pushState(e) end
end

local function pushStateAll()
    for _, e in pairs(pockets) do pushState(e) end
end

-- ---------- UI refresh ----------
--- The operator's own copy of the floor buttons, rendered exactly like a pocket's. Its access
--- is this PC's approval rather than a pocket session, and its position data is the same
--- readback everyone else gets.
local function refreshLocalPanel()
    local status, controls = elev:stateFor(Elevator.LOCAL)
    local defs = {}
    for _, c in ipairs(elev:listForPocket()) do defs[c.id] = c end
    local named = {}
    for i, c in ipairs(controls) do
        local d = defs[c.id] or {}
        named[i] = { id = c.id, name = d.name or c.id, type = "button", use = "elevator",
                     invert = false, fired = c.fired, cooldown = c.cooldown }
    end
    app.usePanel.set({ { address = Elevator.LOCAL, status = status, controls = named } })
end

local function refreshFloors()
    local liftId = app.ops.selectedLift()
    local lift = liftId and elev.lifts[liftId]
    if not lift then app.ops.setFloors(nil, {}); return end
    local valid = validChannels(liftId)
    local rows = elev:floorRows(liftId)
    for _, r in ipairs(rows) do
        r.callMissing = (r.call ~= nil) and not valid[r.call]
        r.atMissing = (r.at ~= nil) and not valid[r.at]
    end
    app.ops.setFloors(lift.name, rows)
end

local function refreshAll()
    local lifts = elev:snapshot()
    -- A lift that reaches its floors through a monitor it hasn't got can never move. Flag it
    -- here rather than letting it sit looking merely idle.
    for _, l in ipairs(lifts) do
        if not l.monitor then
            local needs = false
            for _, f in ipairs(elev:floorRows(l.id)) do
                if Elevator.isRemote(f.call) or Elevator.isRemote(f.at) then needs = true end
            end
            l.needsMonitor = needs
        elseif not trustedMons[l.monitor] then
            l.needsMonitor = true -- configured, but the server does not vouch for it
        end
    end
    app.ops.setLifts(lifts)
    app.ops.setOutputs(localChannelRows())
    local sessions = elev:sessions()
    app.ops.setDevices(elev:pockets(), sessions, elev:getRange())
    -- blue while anyone is cleared: visible from any tab
    app.ops.setAlert("Devices", #sessions > 0 and Palette.alert.active or nil)
    refreshFloors()
    refreshLocalPanel()
end

-- ---------- the hardware step ----------
--- Drive our own redstone from the pulse windows, read BOTH directions back, then work out
--- where each cabin is. Returns the console-worthy events.
local function hardwareStep()
    local states, pulses, changes = elev:tick()
    io_:apply(states, sides)
    localOutputs = io_:readBack(sides)
    localInputs = io_:readInputs(sides)

    -- Dispatch any remote call pulses. Sent ONCE — the monitor times the pulse itself, so a
    -- controller that dies mid-call can only cost a call that didn't happen, never a call
    -- contact left energised.
    for _, p in ipairs(pulses) do
        local link = monLinks[p.monitor]
        if link and trustedMons[p.monitor] then
            link:send(Protocol.elevPulse(p.target, p.seconds))
        else
            log("no link to monitor " .. short(p.monitor) .. " - call not sent", "bad")
        end
    end

    local moved = elev:observeFeedback(localInputs, monStates)
    return changes, moved
end

-- ---------- operator actions ----------
local function onUiAction(action, payload)
    if action == "need_selection" then
        log("pick " .. tostring(payload) .. " in the list first", "warn")

    elseif action == "select_lift" then
        refreshFloors()

    -- ----- lifts -----
    elseif action == "new_lift" then
        editingLift = false
        app.openLiftForm(nil, approvedMonitors())

    elseif action == "edit_lift" then
        local l = elev.lifts[payload]
        if not l then return end
        editingLift = payload
        app.openLiftForm({ id = l.id, name = l.name, monitor = l.monitor,
                           recall = l.recall, timeout = l.timeout }, approvedMonitors())

    elseif action == "save_lift" then
        if editingLift then
            elev:update(editingLift, payload)
            log("updated lift " .. tostring(payload.name), "good")
        else
            local id = elev:add(payload)
            app.ops.selectLift(id) -- so the Floors tab is immediately about the new lift
            log("added lift " .. tostring(payload.name), "good")
        end
        editingLift = nil
        saveLifts()
        app.closeForm()
        connectMonitors()
        refreshAll(); pushListAll()

    elseif action == "delete_lift" then
        local l = elev.lifts[payload]
        if not l then return end
        elev:remove(payload)
        saveLifts()
        -- whatever it was driving must not be left energised
        hardwareStep()
        log("deleted lift " .. tostring(l.name), "warn")
        refreshAll(); pushListAll()

    -- ----- floors -----
    elseif action == "new_floor" then
        local liftId = app.ops.selectedLift()
        if not liftId then log("pick a lift on the Lifts tab first", "warn"); return end
        editingFloor = false
        app.openFloorForm(nil, channelsFor(liftId))

    elseif action == "edit_floor" then
        local liftId = app.ops.selectedLift()
        local lift = liftId and elev.lifts[liftId]
        local f = lift and lift.floors[payload]
        if not f then return end
        editingFloor = payload
        app.openFloorForm({ id = f.id, name = f.name, call = f.call, at = f.at },
            channelsFor(liftId))

    elseif action == "save_floor" then
        local liftId = app.ops.selectedLift()
        if not liftId then log("no lift selected", "warn"); return end
        if editingFloor then
            elev:updateFloor(liftId, editingFloor, payload)
            log("updated floor " .. tostring(payload.name), "good")
        else
            elev:addFloor(liftId, payload)
            log("added floor " .. tostring(payload.name), "good")
        end
        editingFloor = nil
        saveLifts()
        app.closeForm()
        refreshAll(); pushListAll()

    elseif action == "delete_floor" then
        local liftId = app.ops.selectedLift()
        local lift = liftId and elev.lifts[liftId]
        local f = lift and lift.floors[payload]
        if not f then return end
        elev:removeFloor(liftId, payload)
        saveLifts()
        hardwareStep()
        log("deleted floor " .. tostring(f.name), "warn")
        refreshAll(); pushListAll()

    elseif action == "move_floor" then
        local liftId = app.ops.selectedLift()
        if not liftId then return end
        if elev:moveFloor(liftId, payload.id, payload.delta) then
            saveLifts()
            refreshAll(); pushListAll()
        else
            log("already at the end", "warn")
        end

    -- ----- the operator's own panel -----
    elseif action == "use_panel" then
        app.openPanel()
        refreshLocalPanel()

    elseif action == "close_panel" then
        app.closePanel()

    elseif action == "panel_tap" then
        -- The operator tapped their own copy. Same code path as a pocket's tap, with
        -- Elevator.LOCAL standing in for the address: it is always "in range", and its
        -- "session" is this PC's approval by the server.
        local ok, reason = elev:input(Elevator.LOCAL, payload.id)
        if ok then
            hardwareStep()
            log("call " .. tostring(payload.id) .. " (this PC)", "good")
            refreshAll(); pushStateAll()
        else
            log("local call refused (" .. tostring(reason) .. ")", "warn")
            refreshLocalPanel()
        end

    -- ----- forms -----
    elseif action == "cancel_form" then
        editingLift = nil; editingFloor = nil
        app.closeForm()

    elseif action == "form_error" then
        log(tostring(payload), "warn")

    -- ----- hardware -----
    elseif action == "toggle_bundled" then
        -- flip a SIDE between plain and 16 bundled colours; everything on it goes off first
        -- because the channels are about to be redefined underneath it
        local e = nil
        for _, o in ipairs(localChannelRows()) do if o.id == payload then e = o end end
        if not e then return end
        local key = RedstoneIO.sideKey(e.device, e.side)
        local cur = sideStore:get(key)
        io_:allOff(sides)
        sideStore:set(key, { bundled = not (cur and cur.bundled) })
        sides = bundledSides()
        io_:allOff(sides)
        hardwareStep()
        log(key .. ((cur and cur.bundled) and " -> plain side" or " -> bundled (16 colours)"))
        -- Bundling REDEFINES a side's channels: "self/back" becomes "self/back:pink" & co.
        -- A floor still aimed at the old id now calls nothing, and the pocket would just show
        -- a button that never lights up. Say it plainly instead. Resolved PER LIFT, because
        -- "mon:" means that lift's own monitor.
        local orphans = elev:orphanedFloors(validChannels)
        if #orphans > 0 then
            log(("%d floor(s) now call a missing channel - re-wire: %s")
                :format(#orphans, table.concat(orphans, ", ")), "warn")
        end
        refreshAll()

    elseif action == "set_range" then
        elev:setRange(payload)
        settings:set("range", payload)
        log("range " .. payload .. " blocks", "note")
        refreshAll(); pushStateAll()

    elseif action == "edit_range" then
        -- numbers are typed on this PC's keyboard; keep it to one line
        log("type a number then Enter (range)")
        os.queueEvent("easykey_prompt", "range")
    end
end

-- ---------- number prompt (non-blocking) ----------
local prompt = nil -- { field = "range", buffer = "" }

local function onPromptKey(event, p1)
    if not prompt then return false end
    if event == "char" then
        prompt.buffer = prompt.buffer .. p1
    elseif event == "key" then
        if p1 == keys.enter then
            local n = tonumber(prompt.buffer)
            prompt = nil
            if n and n > 0 then onUiAction("set_range", n) else log("not a number", "warn") end
        elseif p1 == keys.backspace then
            prompt.buffer = prompt.buffer:sub(1, -2)
        elseif p1 == keys.tab then
            prompt = nil; log("cancelled")
        end
    end
    return true
end

-- ---------- the server ----------
local function onServerMessage(t, message)
    lastServer = Util.now()
    if t == Protocol.TYPES.SECURE_SET then
        elev:setApproved(true) -- the server only pushes to approved controllers
        elev:setSecureSet(asTable(message.sessions))
        hardwareStep()
        pushStateAll()

    elseif t == Protocol.TYPES.MONITOR_LIST then
        elev:setApproved(true)
        local before = trustedMons
        trustedMons = {}
        for _, a in ipairs(asTable(message.addresses)) do trustedMons[a] = true end
        -- Anything the server just stopped vouching for is dropped NOW, tunnel and position
        -- alike: a revoked monitor must not keep telling us where cabins are.
        for a in pairs(before) do
            if not trustedMons[a] then
                dropMonitor(a)
                log("monitor " .. short(a) .. " revoked - position lost", "warn")
            end
        end
        connectMonitors()
        refreshAll()

    elseif t == Protocol.TYPES.STATUS then
        local approved = (message.state == Protocol.STATUS.APPROVED)
        -- The operator's own panel is gated on this too: a revoked controller is dead on its
        -- own monitor as well.
        elev:setApproved(approved)
        if not approved then
            elev:setSecureSet({})
            hardwareStep()
            log("not approved by the server - calls refused", "warn")
        end
        refreshAll()
    end
end

-- ---------- main ----------
local function main_loop()
    log("elevator control started - fp " .. net:myFingerprint(), "note")
    if not monitor then log("no monitor found - using this screen", "warn") end
    connectServer()
    hardwareStep()
    refreshAll()

    local tick = os.startTimer(0.25)
    local push = os.startTimer(Config.elevator.statePush)
    local retry = os.startTimer(Config.timing.reconnect_after)

    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == tick then
            pcall(function() app.usePanel.animate() end)
            local changes, moved = hardwareStep()
            app.tick()
            for _, c in ipairs(changes) do
                if c.kind == "arrived" then
                    log(c.name .. " arrived at " .. c.floor, "good")
                else
                    log(c.name .. ": no arrival reported for " .. c.floor, "warn")
                end
            end
            if #changes > 0 or #moved > 0 then
                refreshAll(); pushStateAll() -- position changed: tell the pockets at once
            end
            tick = os.startTimer(0.25)

        elseif e1 == "timer" and ev[2] == push then
            -- heartbeat: pockets treat silence as "signal error", so this must be steady
            connectMonitors() -- also the monitor-tunnel retry
            refreshAll(); pushStateAll()
            push = os.startTimer(Config.elevator.statePush)

        elseif e1 == "timer" and ev[2] == retry then
            if (Util.now() - lastServer) >= (Config.timing.server_offline_after * 1000) then
                connectServer()
            end
            reapMonitors() -- a monitor that stopped reporting gets a fresh tunnel
            refreshAll()   -- ...and the screen stops claiming to know where its cabin is
            retry = os.startTimer(Config.timing.reconnect_after)

        elseif e1 == "easykey_prompt" then
            prompt = { field = ev[2], buffer = "" }

        elseif e1 == "easykey_ui" then
            local ok, err = pcall(onUiAction, ev[2], ev[3])
            if not ok then log("ui error: " .. tostring(err), "bad") end

        elseif e1 == "char" or e1 == "key" then
            onPromptKey(e1, ev[2])

        else
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and pocketProto:isMine(e) then
                local conn = pocketProto:accept(e.request, Protocol.peerHello())
                pockets[conn.id] = { link = Link.new(conn), address = nil }
            elseif kind == "message" and Protocol.validate(e.message) then
                local t = e.message.type
                if serverLink and serverLink:owns(e.connId) then
                    serverLink:onInbound()
                    pcall(onServerMessage, t, e.message)
                else
                    -- a monitor's tunnel? (we are the initiator there, so match by link)
                    local monAddr = nil
                    for addr, link in pairs(monLinks) do
                        if link:owns(e.connId) then monAddr = addr end
                    end
                    if monAddr then
                        monLinks[monAddr]:onInbound()
                        -- ANY message proves the tunnel is alive, including the peerHello that
                        -- completes the handshake, so the silence clock resets here rather than
                        -- only on a position report.
                        monLastSeen[monAddr] = Util.now()
                        -- Only from an address the SERVER vouches for. `sender` is
                        -- cryptographically authenticated, so this is a real check.
                        if trustedMons[e.sender] and e.sender == monAddr then
                            -- Payload shapes are checked, not assumed. Protocol.validate only
                            -- guards the version and the type; the fields are still whatever
                            -- arrived, and a number where a table belongs would take the main
                            -- loop down on the next ipairs/index.
                            if t == Protocol.TYPES.ELEV_IO then
                                monChannels[monAddr] = asTable(e.message.channels)
                                log("monitor " .. short(monAddr) .. " has "
                                    .. #monChannels[monAddr] .. " channels", "note")
                                refreshAll()
                            elseif t == Protocol.TYPES.ELEV_STATE then
                                monStates[monAddr] = { inputs = asTable(e.message.inputs),
                                                       outputs = asTable(e.message.outputs) }
                                local moved = elev:observeFeedback(localInputs, monStates)
                                if #moved > 0 then refreshAll(); pushStateAll() end
                            end
                        end
                    else
                        local entry = pockets[e.connId]
                        if entry then
                            entry.link:onInbound()
                            -- the tunnel proves who this is; distance is measured by US
                            if e.sender then entry.address = e.sender end

                            if t == Protocol.TYPES.PRESENCE then
                                elev:onPresence(e.sender, e.distance)
                                -- any pocket in range gets the floors, cleared or not: you can
                                -- see the buttons without being able to use them
                                pushListTo(entry); pushState(entry)

                            elseif t == Protocol.TYPES.PANEL_INPUT then
                                local ok, reason = elev:input(e.sender, e.message.controlId)
                                if ok then
                                    hardwareStep()
                                    log("call " .. tostring(e.message.controlId) .. " by "
                                        .. short(e.sender), "good")
                                    refreshAll()
                                else
                                    log("refused (" .. tostring(reason) .. ") from "
                                        .. short(e.sender), "warn")
                                end
                                -- either way the pocket is told the truth
                                pushState(entry)
                            end
                        end
                    end
                end
            end
        end
    end
end

parallel.waitForAny(basalt.run, net.daemon, main_loop)
