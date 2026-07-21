--- EasyKey manual control PC (advanced computer + monitor).
---
--- The second control type. A door control fires from walking past; this one fires only
--- when a pocket the SERVER has cleared deliberately taps a button or switch in its UI,
--- from inside range. Same trust model, same tunnels, same "holds nothing worth
--- stealing" — only the trigger differs.
---
--- Feedback is the interesting part: the pocket is never allowed to assume anything. We
--- apply redstone, READ IT BACK, and tell the pocket what the hardware is actually doing.
--- If the hardware disagrees with us, the pocket shows "signal error" rather than a
--- button that looks like it worked.
---
--- Three coroutines under `parallel`: basalt.run (monitor), net.daemon (transport), and
--- main (below). UI callbacks never touch the modem — they queue events main consumes.
local basalt     = require("basalt")
local SecureNet  = require("easykey.secure_net")
local Util       = require("shared.util")
local Config     = require("easykey.config")
local Protocol   = require("easykey.protocol")
local Panel      = require("easykey.logic.panel")
local RedstoneIO = require("easykey.redstone_io")
local Discovery  = require("easykey.discovery")
local Link       = require("easykey.link")
local App        = require("easykey.ui.manual_app")
local Palette    = require("easykey.ui.palette")
local KVStore    = require("shared.ui.kvstore")

local net = SecureNet.open({ identityPath = Config.identityPath })

-- ---------- pairing (same flow as the door control) ----------
local function pair()
    term.clear(); term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan); print("EasyKey Manual Control - pairing")
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
io_:allOff(sides) -- boot cold: a reboot must never re-energise anything

local panel = Panel.new({
    defaults = {
        range = Config.manual.range,
        graceSeconds = Config.manual.graceSeconds,
        pressSeconds = Config.manual.pressSeconds,
        stale = Config.proximity.stale,
    },
})
local panelStore = KVStore.load(Config.panelFile)
panel:loadConfig(panelStore:all())

-- range/grace are operator-tunable and persisted alongside the controls
local settings = KVStore.load(Config.panelFile .. ".set")
panel.range = tonumber(settings:get("range")) or panel.range
panel.graceSeconds = tonumber(settings:get("grace")) or panel.graceSeconds

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
pocketProto:listen()

local serverLink = nil
local lastServer = 0
local approved   = false
local pockets    = {}   -- connId -> { link, address }
local feedback   = {}   -- outputId -> bool, what the redstone REALLY says
local editing    = nil  -- control id being edited, or false for "new"

local function connectServer()
    local conn = serverProto:connect(serverAddress)
    if not conn then return nil end
    serverLink = Link.new(conn)
    serverLink:send(Protocol.hello(Protocol.ROLES.MANUAL))
    return conn
end

local function savePanel()
    -- definitions only; live state is never persisted (see Panel:exportConfig)
    for id, cfg in pairs(panel:exportConfig()) do panelStore:set(id, cfg) end
    for id in pairs(panelStore:all()) do
        if not panel.controls[id] then panelStore:set(id, nil) end
    end
end

--- Tell one pocket the truth about the panel: its access, and what the redstone is
--- actually doing (never what we merely intended).
local function pushState(entry)
    if not entry or not entry.address then return end
    local status, controls = panel:stateFor(entry.address, feedback)
    entry.link:send(Protocol.panelState(status, controls))
end

local function pushListTo(entry)
    if not entry or not entry.address then return end
    entry.link:send(Protocol.panelList(panel:listForPocket()))
end

--- The control list changed: everyone's UI must follow, including dropping controls we
--- deleted.
local function pushListAll()
    for _, e in pairs(pockets) do pushListTo(e); pushState(e) end
end

local function pushStateAll()
    for _, e in pairs(pockets) do pushState(e) end
end

-- ---------- UI refresh ----------
local function outputRows()
    local rows = {}
    for _, e in ipairs(io_:enumerate(sides)) do
        rows[#rows + 1] = { id = e.id, on = feedback[e.id] }
    end
    return rows
end

--- The operator's own copy of the panel, rendered exactly like a pocket's. Its access
--- is this PC's approval rather than a pocket session, and its feedback is the same
--- redstone readback everyone else gets.
local function refreshLocalPanel()
    local status, controls = panel:stateFor(Panel.LOCAL, feedback)
    local named = {}
    for i, c in ipairs(controls) do
        local def = panel.controls[c.id]
        named[i] = { id = c.id, name = def and def.name or c.id,
                     type = def and def.type or "button",
                     use = def and def.use or "gate",
                     invert = def and def.invert or false,
                     on = c.on, err = c.err, fired = c.fired, cooldown = c.cooldown }
    end
    app.usePanel.set({ { address = Panel.LOCAL, status = status, controls = named } })
end

--- The ids that exist right now. Bundling a side swaps its single id for 16 colour ids,
--- so a control's target can stop existing without the control ever being touched.
local function validTargets()
    local set = {}
    for _, e in ipairs(io_:enumerate(sides)) do set[e.id] = true end
    return set
end

--- Controls aimed at an output that isn't there any more.
local function orphanedControls()
    local valid, out = validTargets(), {}
    for _, c in ipairs(panel:snapshot()) do
        if c.target and not valid[c.target] then out[#out + 1] = c.name end
    end
    return out
end

local function refreshAll()
    app.ops.setControls(panel:snapshot(), validTargets())
    app.ops.setOutputs(outputRows())
    app.ops.setDevices(panel:pockets(), panel.range, panel.graceSeconds)
    local sessions = panel:sessions()
    app.ops.setSessions(sessions)
    -- blue while anyone is cleared: visible from any tab
    app.ops.setAlert("Sessions", #sessions > 0 and Palette.alert.active or nil)
    refreshLocalPanel()
end

-- ---------- operator actions ----------
local function onUiAction(action, payload)
    if action == "need_selection" then
        log("pick " .. tostring(payload) .. " in the list first", "warn")

    elseif action == "new_control" then
        editing = false
        app.openForm(nil, outputRows())

    elseif action == "edit_control" then
        local c = panel.controls[payload]
        if not c then return end
        editing = payload
        app.openForm(c, outputRows())

    elseif action == "delete_control" then
        local c = panel.controls[payload]
        if not c then return end
        panel:remove(payload)
        savePanel()
        -- the output it drove must not be left energised
        io_:apply(panel:tick(), sides)
        feedback = io_:readBack(sides); panel:observeFeedback(feedback)
        log("deleted control " .. tostring(c.name), "warn")
        refreshAll(); pushListAll()

    elseif action == "save_control" then
        if editing then
            panel:update(editing, payload)
            log("updated " .. tostring(payload.name), "good")
        else
            panel:add(payload)
            log("added " .. tostring(payload.type) .. " " .. tostring(payload.name), "good")
        end
        editing = nil
        savePanel()
        app.closeForm()
        refreshAll(); pushListAll()

    elseif action == "use_panel" then
        app.openPanel()
        refreshLocalPanel()

    elseif action == "close_panel" then
        app.closePanel()

    elseif action == "panel_tap" then
        -- The operator tapped their own copy. Same code path as a pocket's tap, with
        -- Panel.LOCAL standing in for the address: it is always "in range", and its
        -- "session" is this PC's approval by the server.
        local ok, reason = panel:input(Panel.LOCAL, payload.id)
        if ok then
            local states = panel:tick()
            io_:apply(states, sides)
            feedback = io_:readBack(sides); panel:observeFeedback(feedback)
            local c = panel.controls[payload.id]
            log("tap " .. tostring(c and c.name) .. " (this PC)", "good")
            refreshAll(); pushStateAll()
        else
            log("local tap refused (" .. tostring(reason) .. ")", "warn")
            refreshLocalPanel()
        end

    elseif action == "cancel_form" then
        editing = nil
        app.closeForm()

    elseif action == "form_error" then
        log(tostring(payload), "warn")

    elseif action == "toggle_bundled" then
        -- flip a SIDE between plain and 16 bundled colours; everything on it goes off
        -- first because the channels are about to be redefined underneath it
        local e = nil
        for _, o in ipairs(io_:enumerate(sides)) do if o.id == payload then e = o end end
        if not e then return end
        local key = RedstoneIO.sideKey(e.device, e.side)
        local cur = sideStore:get(key)
        io_:allOff(sides)
        sideStore:set(key, { bundled = not (cur and cur.bundled) })
        sides = bundledSides()
        io_:allOff(sides)
        feedback = io_:readBack(sides); panel:observeFeedback(feedback)
        log(key .. ((cur and cur.bundled) and " -> plain side" or " -> bundled (16 colours)"))
        -- Bundling REDEFINES a side's channels: "self/back" becomes "self/back:pink" & co.
        -- Anything still aimed at the old id now drives nothing, and the pocket would just
        -- report "signal error" with no clue why. Say it plainly instead.
        local orphans = orphanedControls()
        if #orphans > 0 then
            log(("%d control(s) now aim at a missing output - re-target: %s")
                :format(#orphans, table.concat(orphans, ", ")), "warn")
        end
        refreshAll()

    elseif action == "set_range" then
        panel.range = payload
        settings:set("range", payload)
        log("range " .. payload .. " blocks", "note")
        refreshAll(); pushStateAll()

    elseif action == "set_grace" then
        panel.graceSeconds = payload
        settings:set("grace", payload)
        log("grace " .. payload .. "s", "note")
        refreshAll()

    elseif action == "edit_range" or action == "edit_grace" then
        -- numbers are typed on this PC's keyboard; keep it to one line
        log("type a number then Enter (" .. (action == "edit_range" and "range" or "grace") .. ")")
        os.queueEvent("easykey_prompt", action == "edit_range" and "range" or "grace")
    end
end

-- ---------- number prompt (non-blocking) ----------
local prompt = nil -- { field = "range"|"grace", buffer = "" }

local function onPromptKey(event, p1)
    if not prompt then return false end
    if event == "char" then
        prompt.buffer = prompt.buffer .. p1
    elseif event == "key" then
        if p1 == keys.enter then
            local n = tonumber(prompt.buffer)
            local field = prompt.field
            prompt = nil
            if n and n > 0 then
                onUiAction(field == "range" and "set_range" or "set_grace", n)
            else
                log("not a number", "warn")
            end
        elseif p1 == keys.backspace then
            prompt.buffer = prompt.buffer:sub(1, -2)
        elseif p1 == keys.tab then
            prompt = nil; log("cancelled")
        end
    end
    return true
end

-- ---------- main ----------
local function main_loop()
    log("manual control started - fp " .. net:myFingerprint(), "note")
    if not monitor then log("no monitor found - using this screen", "warn") end
    connectServer()
    refreshAll()

    local tick = os.startTimer(0.25)
    local push = os.startTimer(Config.manual.statePush)
    local retry = os.startTimer(Config.timing.reconnect_after)

    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == tick then
            -- step any switch knob still crossing its track on the operator's own panel
            pcall(function() app.usePanel.animate() end)
            local states, changes = panel:tick()
            io_:apply(states, sides)
            feedback = io_:readBack(sides); panel:observeFeedback(feedback)
            app.tick()
            if #changes > 0 then
                for _, c in ipairs(changes) do
                    log((c.on and "ON  " or "off ") .. tostring(c.name))
                end
                refreshAll(); pushStateAll() -- state changed: tell the pockets at once
            end
            tick = os.startTimer(0.25)

        elseif e1 == "timer" and ev[2] == push then
            -- heartbeat: pockets treat silence as "signal error", so this must be steady
            refreshAll(); pushStateAll()
            push = os.startTimer(Config.manual.statePush)

        elseif e1 == "timer" and ev[2] == retry then
            if (Util.now() - lastServer) >= (Config.timing.server_offline_after * 1000) then
                connectServer()
            end
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
                    lastServer = Util.now()
                    if t == Protocol.TYPES.SECURE_SET then
                        approved = true
                        panel:setApproved(true) -- the server only pushes to approved panels
                        panel:setSecureSet(e.message.sessions)
                        -- a session ending must drop its switches now, not on the next tick
                        io_:apply(panel:tick(), sides)
                        feedback = io_:readBack(sides); panel:observeFeedback(feedback)
                        pushStateAll()
                    elseif t == Protocol.TYPES.STATUS then
                        approved = (e.message.state == Protocol.STATUS.APPROVED)
                        -- The operator's own panel is gated on this too: a revoked
                        -- panel is dead on its own monitor as well.
                        panel:setApproved(approved)
                        if not approved then
                            panel:setSecureSet({})
                            io_:apply(panel:tick(), sides)
                            feedback = io_:readBack(sides); panel:observeFeedback(feedback)
                            log("not approved by the server - inputs refused", "warn")
                        end
                        refreshAll()
                    end
                else
                    local entry = pockets[e.connId]
                    if entry then
                        entry.link:onInbound()
                        -- the tunnel proves who this is; distance is measured by US
                        if e.sender then entry.address = e.sender end

                        if t == Protocol.TYPES.PRESENCE then
                            panel:onPresence(e.sender, e.distance)
                            -- any pocket in range gets the panel, cleared or not: you can
                            -- see the controls without being able to use them
                            pushListTo(entry); pushState(entry)

                        elseif t == Protocol.TYPES.PANEL_INPUT then
                            local ok, reason = panel:input(e.sender, e.message.controlId)
                            if ok then
                                local states = panel:tick()
                                io_:apply(states, sides)
                                feedback = io_:readBack(sides); panel:observeFeedback(feedback)
                                local c = panel.controls[e.message.controlId]
                                log("tap " .. tostring(c and c.name) .. " by " .. short(e.sender),
                                    "good")
                                refreshAll()
                            else
                                log("refused (" .. tostring(reason) .. ") from " .. short(e.sender),
                                    "warn")
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

parallel.waitForAny(basalt.run, net.daemon, main_loop)
