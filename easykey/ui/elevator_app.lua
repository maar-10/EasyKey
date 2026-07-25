--- Composes the elevator controller's monitor UI: the same shape as the server's and the
--- manual panel's (top bar, console on the left, operations on the right), because the
--- console is what you actually watch and the layout is already proven on a monitor in-game.
---
--- Holds no logic: user intent goes out through `emit` and the program decides.
local TopBar    = require("easykey.ui.views.topbar")
local Console   = require("easykey.ui.views.console")
local ElevOps   = require("easykey.ui.views.elev_ops")
local ElevEdit  = require("easykey.ui.views.elev_edit")
local FloorEdit = require("easykey.ui.views.floor_edit")
local PanelView = require("easykey.ui.views.panel_view")
local Palette   = require("easykey.ui.palette")

local App = {}

--- Wide enough for four full-word tabs ("Devices" is 7 chars, so each tab needs 9 columns).
--- Matches the server and the manual panel so all three screens feel like one system.
local OPS_MIN, OPS_MAX = 28, 40

--- @param main table Basalt root frame (monitor, or this PC's screen)
--- @param config table system config
--- @param fingerprint string this PC's short fingerprint (for pairing/approval)
--- @param emit function(action, payload)
function App.build(main, config, fingerprint, emit)
    local W, H = main.get("width"), main.get("height")
    main:setBackground(colors.black)

    -- A blank row under the top bar, matching the other screens: text touching the bar was
    -- hard to read.
    local topH = 1
    local opsW = math.max(OPS_MIN, math.min(OPS_MAX, math.floor(W * 0.44)))
    local consoleW = W - opsW - 1
    local contentY = topH + 2
    local contentH = H - contentY + 1

    local self = {}
    self.topbar  = TopBar.build(main, { x = 1, y = 1, w = W, h = topH }, config, "Elevators")
    self.console = Console.build(main, { x = 1, y = contentY, w = consoleW, h = contentH },
        { fingerprint = fingerprint })
    self.ops     = ElevOps.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        emit, config)
    -- Both forms overlay the ops area only, so the console stays readable while you wire a
    -- floor up — which is exactly when you want to see the arrival contacts firing.
    self.edit      = ElevEdit.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        emit, config)
    self.floorEdit = FloorEdit.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        emit)

    -- ----- the operator's own copy of the floor buttons (the failsafe) -----
    -- Rendered with the SAME view the pockets use, so it looks and behaves identically; only
    -- the access rule differs (this PC's approval instead of a pocket session).
    --
    -- The whole surface goes RED while you're in here. This is backup mode: driving lifts from
    -- the controller itself rather than from a pocket, and you should never be doing it by
    -- accident or forget you're doing it. The button LIST sits on a dark strip inside the red
    -- frame, because the controls colour their GLYPHS (green = the cabin is here) and a
    -- coloured glyph on red would vanish.
    local BACKUP_BG   = Palette.errorBg
    local CONTROLS_BG = Palette.bg
    local useFrame = main:addFrame({
        x = consoleW + 2, y = contentY, width = opsW, height = contentH,
        background = BACKUP_BG,
    })
    useFrame:addLabel({ x = 1, y = 1, text = "Floors (backup):",
        foreground = colors.white, background = BACKUP_BG })
    useFrame:addLabel({ x = 1, y = 2, text = "tap a floor to call the lift",
        foreground = colors.white, background = BACKUP_BG })
    -- Inset by a column on each side so the red frame is actually VISIBLE around the dark strip.
    -- Filling the whole width left a single red column, which reads as a rendering artefact
    -- rather than as "you are driving the base by hand".
    self.useFloors = PanelView.build(useFrame,
        { x = 2, y = 3, w = opsW - 4, h = contentH - 6 }, emit,
        { emptyText = "no floors defined", filter = "elevator", background = CONTROLS_BG })
    useFrame:addButton({
        x = 1, y = contentH - 2, width = opsW - 1, height = 3,
        text = "BACK", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() emit("close_panel") end)
    useFrame:setVisible(false)

    --- One handle, so the program drives this exactly like the manual panel's.
    self.usePanel = {
        set = function(list) self.useFloors.set(list) end,
        animate = function() self.useFloors.animate() end,
        say = function(s) self.useFloors.say(s) end,
        show = function() self.useFloors.show() end,
        hide = function() self.useFloors.hide() end,
    }

    --- Only one overlay may be up at a time: two forms on top of each other would leave the
    --- hidden one's SAVE reachable through the gaps.
    local function hideOverlays()
        self.edit.hide(); self.floorEdit.hide()
    end

    function self.openLiftForm(lift, monitorAddrs)
        useFrame:setVisible(false)
        hideOverlays()
        self.ops.showTab(1)
        self.edit.open(lift, monitorAddrs)
    end

    function self.openFloorForm(floor, channels)
        useFrame:setVisible(false)
        hideOverlays()
        self.ops.showTab(2)
        self.floorEdit.open(floor, channels)
    end

    function self.closeForm() hideOverlays() end

    --- Show/hide the operator's own floor buttons over the ops tabs.
    function self.openPanel()
        hideOverlays()
        self.ops.root:setVisible(false)
        useFrame:setVisible(true)
        self.usePanel.show()
    end
    function self.closePanel()
        useFrame:setVisible(false)
        self.ops.root:setVisible(true)
    end

    function self.tick() self.topbar.update() end
    function self.log(text, level) self.console.log(text, level) end

    return self
end

return App
