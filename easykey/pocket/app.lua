--- Composes the pocket UI.
---
---     row 1     D6477 16:59*        ╬ 20:59:46     (status bar)
---     row 2     [EasyKey][ Gates ][ Lifts ]        (tabs)
---     rows 3+   the active tab
---
---   EasyKey - your clearance: state, countdown, and the Request clearance button
---   Gates   - the controls a manual PC marked as gates
---   Lifts   - the controls a manual PC marked as elevators
---
--- The split is by what a control is FOR (its use), not what it does: a gate might be a
--- momentary button and a lift a latching switch. Sorting them by purpose is what makes
--- the tabs worth having on a 26-column screen.
---
--- The app holds NO networking logic. Every user action is reported through `emit`,
--- which the network coroutine in run.lua consumes — so Basalt callbacks never touch
--- the modem, and the two run independently under `parallel`.
local Clock       = require("easykey.pocket.views.clock")
local Status      = require("easykey.pocket.views.status")
local Pairing     = require("easykey.pocket.views.pairing")
local PanelView   = require("easykey.ui.views.panel_view")
local Keypad      = require("easykey.ui.keypad")
local Palette     = require("easykey.ui.palette")
local Backgrounds = require("easykey.pocket.views.backgrounds")
local BgMenu      = require("easykey.pocket.views.bg_menu")

local App = {}

--- @param main table Basalt root frame (bound to the pocket terminal)
--- @param config table system config
--- @param emit function(action, payload) reports user intent to the net coroutine
function App.build(main, config, emit)
    local W, H = main.get("width"), main.get("height")
    main:setBackground(Palette.bg)

    -- ----- cosmetic background layer (pocket-only, purely local) -----
    -- A full-screen Display at the very back; the tab content below is made transparent so
    -- this shows through the empty cells. Starts plain black = the classic look, until the
    -- user picks a style from the Background menu (the little icon on the EasyKey tab).
    local bgDisplay = main:addDisplay({ x = 1, y = 1, width = W, height = H, z = 1 })
    local bgWin = bgDisplay:getWindow()
    local BG_FILE = (config and config.pocketBgFile) or "/easykey_bg.cfg"
    local currentBg = Backgrounds.load(BG_FILE) -- restore the last chosen style across reboots
    Backgrounds.paint(bgWin, currentBg, W, H)

    -- ----- status bar (row 1) -----
    local clock = Clock.build(main, { x = 1, y = 1, w = W, h = 1 }, config)

    -- ----- tabs (row 2) -----
    local TABS = { "EasyKey", "Gates", "Lifts" }
    local tabW = math.floor(W / #TABS)
    local tabButtons = {}
    local activeTab = 1

    local contentY, contentH = 3, H - 2

    -- ----- tab 1: clearance -----
    local screen = main:addFrame({ x = 1, y = contentY, width = W, height = contentH,
        background = Palette.bg })
    local status = Status.build(screen, { x = 1, y = 1, w = W, h = contentH },
        function() emit("request") end, config)

    -- Make the tab content transparent so the background layer shows through the empty
    -- cells. Labels are transparent already; buttons/chips/bars keep their own bg and stay
    -- readable. The tab strip and overlays (keypad/pairing) stay opaque on purpose.
    clock.frame.set("backgroundEnabled", false)
    screen.set("backgroundEnabled", false)
    status.frame.set("backgroundEnabled", false)

    -- ----- tabs 2 + 3: the manual panels, split by what they are FOR -----
    -- Dropped one row below the tab strip so the first control detaches from the tabs
    -- instead of butting straight up against them.
    local panelY, panelH = contentY + 1, contentH - 1
    local controls = PanelView.build(main, { x = 1, y = panelY, w = W, h = panelH }, emit,
        { filter = "gate", emptyText = "no gates nearby", transparent = true })
    local use = PanelView.build(main, { x = 1, y = panelY, w = W, h = panelH }, emit,
        { filter = "elevator", emptyText = "no lifts nearby", transparent = true })

    -- ----- overlays cover everything, tabs included -----
    local pairing = Pairing.build(main, { x = 1, y = 1, w = W, h = H }, emit)
    local keypad = Keypad.build(main, { x = 1, y = 1, w = W, h = H }, config, {
        onSubmit = function(value) emit("submit", value) end,
        onCancel = function() emit("cancel") end,
    })

    local self = { clock = clock, status = status, keypad = keypad, pairing = pairing,
                   controls = controls, use = use, screen = screen }

    -- The background-picker overlay + its icon are built lower down (they need the show*
    -- helpers), so forward-declare them and the apply helper here.
    local bgMenu, bgIcon
    --- Auto-contrast: a LIGHT background makes the pocket's transparent light text vanish, so
    --- tell every text-on-wallpaper view to recolour its neutral characters dark instead (the
    --- character, never its background).
    local function rethemeText(style)
        local light = Backgrounds.isLight(style)
        clock.retheme(light); status.retheme(light)
        controls.retheme(light); use.retheme(light)
    end
    local function applyBackground(style)
        currentBg = style
        Backgrounds.paint(bgWin, style, W, H)
        Backgrounds.save(style and style.id, BG_FILE) -- remember it for next boot (nil = plain)
        rethemeText(style)
    end

    local function paintTabs()
        for i = 1, #TABS do
            tabButtons[i]:setBackground(i == activeTab and colors.white or Palette.bar)
            tabButtons[i]:setForeground(i == activeTab and colors.black or Palette.text)
        end
    end

    local function showTabs(visible)
        clock.frame:setVisible(visible)
        for _, b in ipairs(tabButtons) do b:setVisible(visible) end
        if bgIcon then bgIcon:setVisible(false) end -- showTab re-reveals it on the EasyKey tab
    end

    local function showTab(i)
        activeTab = i
        screen:setVisible(i == 1)
        if i == 2 then controls.show() else controls.hide() end
        if i == 3 then use.show() else use.hide() end
        if bgIcon then bgIcon:setVisible(i == 1) end -- the bg-menu icon lives on the EasyKey tab
        paintTabs()
    end

    for i, name in ipairs(TABS) do
        local width = (i == #TABS) and (W - tabW * (i - 1)) or tabW
        tabButtons[i] = main:addButton({
            x = (i - 1) * tabW + 1, y = 2, width = width, height = 1,
            text = name, background = Palette.bar, foreground = Palette.text,
        })
        tabButtons[i]:onClick(function() showTab(i) end)
    end

    function self.showMain()
        pairing.hide(); keypad.hide(); if bgMenu then bgMenu.hide() end
        showTabs(true)
        showTab(activeTab)
    end
    function self.showKeypad()
        pairing.hide(); if bgMenu then bgMenu.hide() end
        screen:setVisible(false); controls.hide(); use.hide()
        showTabs(false)
        keypad.show()
    end
    function self.showPairing()
        keypad.hide(); if bgMenu then bgMenu.hide() end
        screen:setVisible(false); controls.hide(); use.hide()
        showTabs(false)
        pairing.show()
    end
    function self.showTab(i) showTab(i) end
    function self.tickClock() clock.update() end

    --- Both panel tabs share one feed; each renders only its own kind.
    function self.setPanels(list)
        controls.set(list)
        use.set(list)
    end

    --- Step any in-flight switch animation. Called from the net coroutine's tick.
    function self.animate()
        controls.animate()
        use.animate()
    end

    --- Report why a tap did nothing, on whichever panel tab is showing.
    function self.sayPanel(status_)
        controls.say(status_)
        use.say(status_)
    end

    -- ----- background picker (overlay + the icon that opens it) -----
    bgMenu = BgMenu.build(main, { x = 1, y = 1, w = W, h = H }, {
        onPick = function(style) applyBackground(style); self.showMain() end,
        onBack = function() self.showMain() end,
    })
    self.bgMenu = bgMenu -- test seam

    function self.showBgMenu()
        pairing.hide(); keypad.hide()
        screen:setVisible(false); controls.hide(); use.hide()
        showTabs(false)
        bgMenu.show()
    end
    --- Test seam: apply a style by id without going through the menu.
    function self.applyBackgroundById(id) applyBackground(Backgrounds.byId(id)) end
    --- Test seam: the id of the currently applied style, or nil for plain.
    function self.currentBgId() return currentBg and currentBg.id or nil end

    -- The single-character icon in the bottom-left of the EasyKey tab. It lives on `main` (a
    -- proven event root, like the tab strip) at a high z, so its tap is never swallowed by the
    -- transparent content frames; showTab reveals it only on the EasyKey tab.
    bgIcon = main:addButton({
        x = 1, y = H, width = 1, height = 1,
        text = "#", background = Palette.accent, foreground = colors.black,
    })
    bgIcon.set("z", 10)
    bgIcon:onClick(function() self.showBgMenu() end)
    bgIcon:setVisible(false) -- showTab(1) below reveals it on the EasyKey tab

    clock.update()
    status.setLocked("")
    rethemeText(currentBg) -- match a background restored from disk (light ones need dark text)
    showTab(1)
    return self
end

return App
