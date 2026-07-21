--- EasyKey server (the vault) with a Basalt monitor UI.
---
--- The single authority: it holds the keys (salted+iterated hashes, never plaintext),
--- decides which device addresses are trusted, verifies typed keys, grants time-limited
--- sessions, and pushes the secure-set to control PCs. Everything arrives over
--- encrypted ecnet2 tunnels, so a message's `sender` is a proven address rather than a
--- claim. Put this computer somewhere physically protected — it is the only machine
--- holding anything worth stealing.
---
--- Three coroutines under `parallel`, each needing its own blocking loop:
---   * basalt.run  — renders the monitor UI and handles touches,
---   * net.daemon  — ecnet2's transport pump,
---   * main        — the server logic below.
--- UI callbacks never touch the vault or the modem: they queue an event that `main`
--- consumes, so all state changes happen in one place.
local basalt    = require("basalt")
local SecureNet = require("easykey.secure_net")
local Util      = require("shared.util")
local Config    = require("easykey.config")
local Protocol  = require("easykey.protocol")
local Sessions  = require("easykey.logic.sessions")
local KeyStore  = require("easykey.keystore")
local Devices   = require("easykey.devices")
local Discovery = require("easykey.discovery")
local Link      = require("easykey.link")
local App       = require("easykey.ui.server_app")
local Palette   = require("easykey.ui.palette")

local net   = SecureNet.open({ identityPath = Config.identityPath })
local proto = net:protocol(Protocol.NAMES.SERVER)
proto:listen()

-- Answer pairing discovery. Only ever hands out our public address; the human
-- confirms the fingerprint on the device before it is trusted.
Discovery.serve(net.side)

local sessions = Sessions.new({ sessionSeconds = Config.timing.session_seconds })
local keys     = KeyStore.load(Config.keysFile, Config.seedKeys, { iters = Config.keyHashIterations })
local pockets  = Devices.load(Config.pocketsFile)
local controls = Devices.load(Config.controlsFile)

local conns     = {}  -- connId -> { conn, link, address, role }
local pending   = {}  -- address -> { role, link, firstSeen }
local cooldowns = {}  -- address -> epoch ms until retry allowed

-- ---------- UI ----------
--- Render on a monitor wherever it's attached; fall back to this computer's own screen
--- so the server still works (and can be set up) with no monitor present.
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

local function short(address) return SecureNet.fingerprint(address) end

local function nameOf(address)
    return pockets:nameOf(address) or controls:nameOf(address) or ("pocket-" .. short(address))
end

local function pendingList()
    local out = {}
    for address, p in pairs(pending) do
        out[#out + 1] = { address = address, role = p.role }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

--- Push the lists the operator looks at. Called on change, never on a timer, so the
--- console keeps its scroll position and lists don't flicker under your finger.
--- Each also lights its tab, so work waiting is visible from any tab.
local function refreshPending()
    local list = pendingList()
    app.ops.setPending(list)
    app.ops.setAlert("Pending", #list > 0 and Palette.alert.pending or nil)
end
local function refreshKeys()    app.ops.setKeys(keys:list()) end
local function refreshDevices() app.ops.setDevices(pockets:list(), controls:list()) end
local function refreshSessions()
    local out = {}
    for _, s in ipairs(sessions:snapshot()) do
        out[#out + 1] = {
            address = s.address, name = nameOf(s.address),
            remaining = math.max(0, math.floor((s.expiresAt - Util.now()) / 1000 + 0.5)),
        }
    end
    app.ops.setSessions(out)
    app.ops.setAlert("Sessions", #out > 0 and Palette.alert.active or nil)
end

-- ---------- net helpers ----------
local function send(link, message)
    if link then link:send(message) end
end

--- The live tunnel to a device address, if it is currently connected. Revocations have
--- to reach the device itself, not just the control PCs: pushSecureSet() only talks to
--- controls, so without this a revoked pocket would sit on a stale screen.
local function linkFor(address)
    for _, c in pairs(conns) do
        if c.address == address then return c.link end
    end
    return nil
end

--- The role a connected device announced, or nil. Used when re-queueing a revoked
--- device so a manual panel doesn't come back labelled as a door control.
local function roleFor(address)
    for _, c in pairs(conns) do
        if c.address == address then return c.role end
    end
    return nil
end

--- A manual panel PC is trusted exactly like a door control: same approval store, same
--- secure-set, and it goes in the control list pockets connect to. Only the role we SHOW
--- differs, so the operator can tell what they are approving.
local function isControlRole(role)
    return role == Protocol.ROLES.CONTROL or role == Protocol.ROLES.MANUAL
end

--- Push the current secure-set to every connected, approved control/panel PC.
--- Runs on a timer, so it is intentionally NOT logged: it would drown the console.
local function pushSecureSet()
    local m = Protocol.secureSet(sessions:snapshot())
    for _, c in pairs(conns) do
        if isControlRole(c.role) and controls:isApproved(c.address) then
            send(c.link, m)
        end
    end
end

local function pushControlList(link)
    send(link, Protocol.controlList(controls:addresses()))
end

-- ---------- message handling ----------
local function onHello(c, message)
    local claimed = message.role
    c.role = isControlRole(claimed) and claimed or Protocol.ROLES.POCKET

    local approved = isControlRole(c.role)
        and controls:isApproved(c.address) or pockets:isApproved(c.address)

    if approved then
        pending[c.address] = nil
        send(c.link, Protocol.status(Protocol.STATUS.APPROVED))
        if isControlRole(c.role) then
            send(c.link, Protocol.secureSet(sessions:snapshot()))
            log(c.role .. " online " .. short(c.address), "note")
        else
            pushControlList(c.link)
            log("pocket online " .. nameOf(c.address), "note")
        end
        refreshPending()
    else
        -- Unknown device: hold for operator approval. Never auto-trust.
        if not pending[c.address] then
            pending[c.address] = { role = c.role, link = c.link, firstSeen = Util.now() }
            log("PENDING " .. c.role .. " " .. short(c.address) .. " - approve it", "warn")
        else
            pending[c.address].link = c.link
        end
        send(c.link, Protocol.status(Protocol.STATUS.PENDING))
        refreshPending()
    end
end

local function onRequestKeycheck(c)
    if not pockets:isApproved(c.address) then
        send(c.link, Protocol.keypadDeny(Protocol.REASONS.NOT_APPROVED)); return
    end
    if sessions:isSecure(c.address) then
        send(c.link, Protocol.keypadDeny(Protocol.REASONS.ALREADY_SECURE)); return
    end
    local cd = cooldowns[c.address]
    if cd and Util.now() < cd then
        send(c.link, Protocol.keypadDeny(Protocol.REASONS.COOLDOWN)); return
    end
    send(c.link, Protocol.keypadGrant())
    log("keypad opened by " .. nameOf(c.address))
end

local function onSubmitKey(c, message)
    if not pockets:isApproved(c.address) then
        send(c.link, Protocol.keyResult(false, nil, Protocol.REASONS.NOT_APPROVED)); return
    end
    local entry = keys:verify(message.key)
    if not entry then
        cooldowns[c.address] = Util.now() + Config.timing.retry_cooldown * 1000
        send(c.link, Protocol.keyResult(false, nil, Protocol.REASONS.BAD_KEY))
        log("WRONG key from " .. nameOf(c.address), "bad")
        return
    end
    cooldowns[c.address] = nil
    local s = sessions:grant(c.address, entry.label)
    send(c.link, Protocol.keyResult(true, s.expiresAt, Protocol.REASONS.OK, entry.label))
    pushSecureSet()
    log(("SECURE %s (%s) for %ds"):format(nameOf(c.address), tostring(entry.label or "key"),
        Config.timing.session_seconds), "good")
    refreshSessions()
end

-- ---------- operator actions ----------
local function onUiAction(action, payload)
    if action == "need_selection" then
        -- A button was pressed with nothing picked. Say so: a button that silently
        -- does nothing is indistinguishable from a broken one.
        log("pick " .. tostring(payload) .. " in the list first", "warn")

    elseif action == "approve" then
        local p = pending[payload]
        if not p then return end
        pending[payload] = nil
        if isControlRole(p.role) then
            controls:approve(payload, p.role .. "-" .. short(payload))
            log("APPROVED " .. p.role .. " " .. short(payload), "good")
            if p.link then
                send(p.link, Protocol.status(Protocol.STATUS.APPROVED))
                send(p.link, Protocol.secureSet(sessions:snapshot()))
            end
            -- a new control changes who every approved pocket should ping
            for _, c in pairs(conns) do
                if c.role == Protocol.ROLES.POCKET and pockets:isApproved(c.address) then
                    pushControlList(c.link)
                end
            end
        else
            pockets:approve(payload, "pocket-" .. short(payload))
            log("APPROVED pocket " .. short(payload), "good")
            if p.link then
                send(p.link, Protocol.status(Protocol.STATUS.APPROVED))
                pushControlList(p.link)
            end
        end
        refreshPending(); refreshDevices()

    elseif action == "reject" then
        pending[payload] = nil
        log("rejected " .. short(payload), "warn")
        refreshPending()

    elseif action == "key_add" then
        -- payload = { value = <the key>, label = <operator name> }; the name is typed on
        -- the on-screen keyboard, the value on the (masked) keypad. A blank name auto-labels.
        local value = type(payload) == "table" and payload.value or payload
        if type(value) == "string" and #value > 0 then
            local label = (type(payload) == "table" and payload.label) or nil
            if not label or label == "" then label = "key-" .. (keys:count() + 1) end
            keys:add(value, label)
            -- never log the key itself, only that one now exists (with its name)
            log("key added (" .. label .. "), " .. keys:count() .. " total", "good")
            refreshKeys()
        end

    elseif action == "key_remove" then
        if keys:count() <= 1 then
            log("refused: that's the last key - add another first", "bad")
        elseif keys:remove(payload) then
            log("key removed (" .. tostring(payload) .. ")", "warn")
            refreshKeys()
        end

    elseif action == "revoke_device" then
        local wasPocket = pockets:isApproved(payload)
        -- keep its real role (control vs manual panel) for the queue + the log
        local kind = roleFor(payload)
            or (wasPocket and Protocol.ROLES.POCKET or Protocol.ROLES.CONTROL)
        pockets:revoke(payload); controls:revoke(payload)
        -- a revoked device must lose access now, not when its session lapses
        local hadSession = sessions:revoke(payload)
        if hadSession then pushSecureSet() end

        -- Tell the device itself, so its screen reflects reality immediately instead of
        -- after a reboot. It is still connected but no longer trusted, which is exactly
        -- what "pending" means - so it goes back on the queue and can be re-approved
        -- live. (Reject it to clear it; it won't return until it reconnects.)
        local link = linkFor(payload)
        if link then
            if hadSession then send(link, Protocol.sessionEnd(Protocol.REASONS.REVOKED)) end
            send(link, Protocol.status(Protocol.STATUS.PENDING))
            pending[payload] = { role = kind, link = link, firstSeen = Util.now() }
        end
        log("REVOKED " .. kind .. " " .. short(payload), "bad")
        refreshDevices(); refreshSessions(); refreshPending()

    elseif action == "revoke_session" then
        if sessions:revoke(payload) then
            pushSecureSet()
            -- the pocket is still approved; it just isn't secure any more
            send(linkFor(payload), Protocol.sessionEnd(Protocol.REASONS.REVOKED))
            log("session revoked: " .. nameOf(payload), "warn")
            refreshSessions()
        end
    end
end

-- ---------- main loop ----------
local function main_loop()
    log("server started - fingerprint " .. net:myFingerprint(), "note")
    if not monitor then log("no monitor found - using this screen", "warn") end
    if keys:count() == 0 then log("NO KEYS SET - add one on the Keys tab", "bad") end
    refreshPending(); refreshKeys(); refreshDevices(); refreshSessions()

    local tick = os.startTimer(1)
    local push = os.startTimer(Config.timing.secure_push)
    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == tick then
            app.tick() -- clock only
            if sessions:count() > 0 then refreshSessions() end -- live countdown
            tick = os.startTimer(1)

        elseif e1 == "timer" and ev[2] == push then
            local removed = sessions:expireDue()
            for _, address in ipairs(removed) do
                log("session expired: " .. nameOf(address), "warn")
            end
            pushSecureSet() -- also the control-PC heartbeat (deliberately unlogged)
            if #removed > 0 then refreshSessions() end
            push = os.startTimer(Config.timing.secure_push)

        elseif e1 == "easykey_ui" then
            local ok, err = pcall(onUiAction, ev[2], ev[3])
            if not ok then log("ui error: " .. tostring(err), "bad") end

        elseif e1 == "modem_message"
            and Discovery.handle(net.side, net:myAddress(), table.unpack(ev)) then
            -- a device is pairing; nothing else to do

        else
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "request" and proto:isMine(e) then
                -- The reply completes the tunnel: until the initiator receives it, it
                -- cannot send us anything (ecnet2 Noise XK). We do NOT mark our link
                -- ready here — only the device's first message does that.
                local conn = proto:accept(e.request, Protocol.peerHello())
                conns[conn.id] = { conn = conn, link = Link.new(conn) }
            elseif kind == "message" then
                local c = conns[e.connId]
                if c and Protocol.validate(e.message) then
                    c.link:onInbound()
                    -- `sender` is authenticated by the tunnel: safe to trust as identity
                    c.address = e.sender
                    local t = e.message.type
                    if t == Protocol.TYPES.HELLO then pcall(onHello, c, e.message)
                    elseif t == Protocol.TYPES.REQUEST_KEYCHECK then pcall(onRequestKeycheck, c)
                    elseif t == Protocol.TYPES.SUBMIT_KEY then pcall(onSubmitKey, c, e.message)
                    end
                end
            end
        end
    end
end

parallel.waitForAny(basalt.run, net.daemon, main_loop)
