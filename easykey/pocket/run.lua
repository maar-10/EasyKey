--- Pocket entry point (advanced pocket computer).
---
--- Holds no secret worth stealing: the key lives in the user's head, the vault lives on
--- the server. This device only has its own ecnet2 identity (which a thief can read —
--- and which gets them nothing without the key) and, while secure, a session expiry.
---
--- Three coroutines run under `parallel`, because each needs its own blocking loop:
---   * basalt.run  — renders the UI and handles taps,
---   * net.daemon  — ecnet2's transport pump,
---   * netLoop     — pairing, tunnels and the state machine (below).
--- Basalt callbacks never touch the modem; they `emit` events that netLoop consumes.
local basalt    = require("basalt")
local Util      = require("shared.util")
local SecureNet = require("easykey.secure_net")
local Config    = require("easykey.config")
local Protocol  = require("easykey.protocol")
local Discovery = require("easykey.discovery")
local App       = require("easykey.pocket.app")
local Link      = require("easykey.link")
local PanelFeed = require("easykey.logic.panel_feed")

local net         = SecureNet.open({ identityPath = Config.identityPath })
local serverProto = net:protocol(Protocol.NAMES.SERVER)
local ctrlProto   = net:protocol(Protocol.NAMES.CONTROL)

-- ----- state -----
local S = {
    PAIRING = "pairing", CONNECTING = "connecting", PENDING = "pending",
    LOCKED = "locked", REQUESTING = "requesting", KEYPAD = "keypad",
    VERIFYING = "verifying", SECURE = "secure",
}
local state       = S.PAIRING
local session     = nil   -- { expiresAt } while secure
local serverLink  = nil
local serverAddr  = nil
local lastServer  = 0
local deadline    = 0     -- guards a lost grant/verify reply
local controlAddrs = {}   -- trusted control/panel addresses (from the server)
local controlLinks = {}   -- address -> Link
-- What the manual panels have told us. Pure + tested (easykey/logic/panel_feed.lua):
-- this merge dropped a published field twice while it lived inline here.
local feed = PanelFeed.new({ timeout = Config.manual.feedbackTimeout })

local main = basalt.createFrame()

local DENY_TEXT = {
    [Protocol.REASONS.NOT_APPROVED]   = "not approved yet",
    [Protocol.REASONS.ALREADY_SECURE] = "already secure",
    [Protocol.REASONS.COOLDOWN]       = "wait a moment...",
    [Protocol.REASONS.BAD_KEY]        = "wrong key",
}

-- UI actions arrive as events so the modem stays off Basalt's coroutine.
local app = App.build(main, Config, function(action, payload)
    os.queueEvent("easykey_ui", action, payload)
end)

-- ---------- helpers ----------
local function connectServer()
    state = S.CONNECTING
    app.showMain()
    app.status.setBusy("connecting...")
    local conn, err = serverProto:connect(serverAddr)
    if not conn then
        app.status.setDenied("bad server pin")
        return false
    end
    -- Queued until the server's reply completes the tunnel (ecnet2 refuses sends
    -- before that); Link flushes it for us the moment it lands.
    serverLink = Link.new(conn)
    serverLink:send(Protocol.hello(Protocol.ROLES.POCKET))
    return true
end

--- Open a tunnel to each trusted control PC. Kept up whenever we are APPROVED, not
--- just while secure: a manual panel has to be able to tell a locked pocket "access
--- denied", and to show it the buttons at all. Door controls ignore pings from pockets
--- without a session, so this grants nothing.
local function connectControls()
    for _, addr in ipairs(controlAddrs) do
        if not controlLinks[addr] then
            local conn = ctrlProto:connect(addr)
            if conn then controlLinks[addr] = Link.new(conn) end
        end
    end
end

local function pingControls()
    -- sendIfReady, not send: a queued ping would just replay a stale position when
    -- the tunnel finally opens. Dropping it is correct - another follows in 1s.
    for _, link in pairs(controlLinks) do
        link:sendIfReady(Protocol.presence())
    end
end

--- Rebuild the PANEL tab from what the manual PCs have told us. Nothing here is our
--- own opinion: a control only appears or moves because a panel reported it.
local function refreshPanels()
    app.setPanels(feed:list())
end

-- ---------- pairing ----------
local function doPairing()
    state = S.PAIRING
    app.showPairing()
    app.pairing.setSearching()
    local found = Discovery.find(net.side, 3)
    if #found == 0 then app.pairing.setNone() else app.pairing.setCandidates(found) end
end

-- ---------- server messages ----------
local function onServerMessage(m)
    lastServer = Util.now()
    local t = m.type

    if t == Protocol.TYPES.STATUS then
        if m.state == Protocol.STATUS.PENDING then
            -- Approval can be withdrawn at any time, including mid-session: drop
            -- everything we thought we had rather than showing a stale screen. An
            -- unapproved pocket isn't in anyone's control list, so its panels go too.
            session = nil
            controlLinks = {}
            feed:clear()
            refreshPanels()
            state = S.PENDING
            app.showMain()
            app.status.setBusy("awaiting approval")
        elseif state == S.CONNECTING or state == S.PENDING then
            state = S.LOCKED
            app.showMain()
            app.status.setLocked("")
        end

    elseif t == Protocol.TYPES.CONTROL_LIST then
        controlAddrs = m.addresses or {}

    elseif t == Protocol.TYPES.KEYPAD_GRANT then
        if state == S.REQUESTING then
            state = S.KEYPAD
            app.showKeypad()
        end

    elseif t == Protocol.TYPES.KEYPAD_DENY then
        if state == S.REQUESTING then
            if m.reason == Protocol.REASONS.ALREADY_SECURE and session then
                state = S.SECURE; app.showMain()
            else
                state = S.LOCKED; app.showMain()
                app.status.setDenied(DENY_TEXT[m.reason] or "denied")
            end
        end

    elseif t == Protocol.TYPES.SESSION_END then
        -- The operator ended our session early. We're still an approved device, so the
        -- panel tunnels stay up — they'll now report "access denied", which is exactly
        -- what should be on screen. Losing the session is enough to stop doors opening
        -- and inputs being accepted; the control PCs enforce that themselves.
        session = nil
        if state ~= S.PENDING then
            state = S.LOCKED
            app.showMain()
            app.status.setDenied(m.reason == Protocol.REASONS.REVOKED
                and "session revoked" or "session ended")
        end

    elseif t == Protocol.TYPES.KEY_RESULT then
        if state == S.VERIFYING then
            if m.ok then
                session = { expiresAt = m.expiresAt }
                state = S.SECURE
                app.showMain()
                app.status.setSecure(math.max(0, math.floor((m.expiresAt - Util.now()) / 1000)))
                connectControls()
            else
                state = S.LOCKED
                app.showMain()
                app.status.setDenied(DENY_TEXT[m.reason] or "wrong key")
            end
        end
    end
end

-- ---------- manual panel messages ----------
--- Everything the PANEL tab shows comes from here. We never invent state: if a manual
--- PC stops talking its panel goes stale and reads "signal error", rather than showing
--- a button that looks like it still works.
local function onControlMessage(address, m)
    local t = m.type
    if t == Protocol.TYPES.PANEL_LIST then
        feed:onList(address, m.controls)
        refreshPanels()
    elseif t == Protocol.TYPES.PANEL_STATE then
        feed:onState(address, m.status, m.controls)
        refreshPanels()
    end
end

-- ---------- UI actions ----------
local function onUiAction(action, payload)
    if action == "rescan" then
        doPairing()

    elseif action == "pair_choice" then
        Discovery.pin(Config.serverFile, payload)
        serverAddr = payload
        connectServer()

    elseif action == "request" then
        if state ~= S.LOCKED then return end
        state = S.REQUESTING
        deadline = Util.now() + 3000
        app.status.setBusy("requesting...")
        if not (serverLink and serverLink:send(Protocol.requestKeycheck())) then
            state = S.LOCKED
            app.status.setDenied("no server link")
        end

    elseif action == "submit" then
        state = S.VERIFYING
        deadline = Util.now() + 3000
        app.showMain()
        app.status.setBusy("checking key...")
        if serverLink then serverLink:send(Protocol.submitKey(payload)) end

    elseif action == "cancel" then
        state = S.LOCKED
        app.showMain()
        app.status.setLocked("")

    elseif action == "panel_tap" then
        -- Ask; never act. The row only moves when the manual PC reports back.
        local link = controlLinks[payload.address]
        if link and link:isReady() then
            link:send(Protocol.panelInput(payload.id))
        else
            app.sayPanel("signal_error")
        end
    end
end

-- ---------- 1s tick ----------
local function tick()
    app.tickClock()
    local now = Util.now()

    -- Panels are kept alive whenever we are approved, so a locked pocket still sees
    -- them (and is told why it cannot use them).
    if state ~= S.PAIRING and state ~= S.CONNECTING and state ~= S.PENDING then
        connectControls()
        pingControls()
    end

    -- A panel that stops reporting is NOT assumed to be fine.
    if feed:tick(now) then refreshPanels() end

    if (state == S.REQUESTING or state == S.VERIFYING) and now >= deadline then
        state = S.LOCKED
        app.showMain()
        app.status.setDenied("no server response")
    end

    if state == S.SECURE and session then
        local remaining = math.floor((session.expiresAt - now) / 1000)
        if remaining <= 0 then
            session = nil
            state = S.LOCKED
            app.status.setLocked("Not cleared!")
        else
            app.status.setSecure(remaining)
        end
    end
end

-- ---------- net coroutine ----------
local function netLoop()
    serverAddr = Discovery.readPinned(Config.serverFile)
    if serverAddr then connectServer() else doPairing() end

    local uiTimer = os.startTimer(Config.timing.ui_tick)
    -- A separate, faster beat purely for the switch knob sliding across its track. The
    -- 1s UI tick is far too slow to read as movement.
    local animTimer = os.startTimer(0.12)
    while true do
        local ev = { os.pullEvent() }
        local e1 = ev[1]

        if e1 == "timer" and ev[2] == animTimer then
            pcall(function() app.animate() end)
            animTimer = os.startTimer(0.12)

        elseif e1 == "timer" and ev[2] == uiTimer then
            local ok, err = pcall(tick)
            if not ok then
                local f = fs.open("/easykey_error.txt", "a")
                if f then f.writeLine(os.date("%H:%M:%S") .. "  " .. tostring(err)); f.close() end
            end
            uiTimer = os.startTimer(Config.timing.ui_tick)

        elseif e1 == "easykey_ui" then
            pcall(onUiAction, ev[2], ev[3])

        else
            local kind, e = SecureNet.match(table.unpack(ev))
            if kind == "message" then
                -- Any inbound message completes that tunnel and flushes what we queued.
                if serverLink and serverLink:owns(e.connId) then
                    serverLink:onInbound()
                    if Protocol.validate(e.message) then pcall(onServerMessage, e.message) end
                else
                    for address, link in pairs(controlLinks) do
                        if link:owns(e.connId) then
                            link:onInbound()
                            if Protocol.validate(e.message) then
                                pcall(onControlMessage, address, e.message)
                            end
                        end
                    end
                end
            end
        end
    end
end

parallel.waitForAny(basalt.run, net.daemon, netLoop)
