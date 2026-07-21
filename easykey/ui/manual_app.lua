--- Composes the manual control PC's monitor UI: same shape as the server's (top bar,
--- console on the left, operations on the right), because the console is what you
--- actually watch and the layout is already proven on a monitor.
---
--- Holds no logic: user intent goes out through `emit` and the program decides.
local TopBar    = require("easykey.ui.views.topbar")
local Console   = require("easykey.ui.views.console")
local PanelOps  = require("easykey.ui.views.panel_ops")
local PanelEdit = require("easykey.ui.views.panel_edit")
local PanelView = require("easykey.ui.views.panel_view")
local Palette   = require("easykey.ui.palette")

local App = {}

--- Wide enough for four full-word tabs ("Controls"/"Sessions" are 8 chars, so each tab
--- needs 9 columns). Matches the server so the two screens feel like one system.
local OPS_MIN, OPS_MAX = 28, 40

--- @param main table Basalt root frame (monitor, or this PC's screen)
--- @param config table system config
--- @param fingerprint string this PC's short fingerprint (for pairing/approval)
--- @param emit function(action, payload)
function App.build(main, config, fingerprint, emit)
    local W, H = main.get("width"), main.get("height")
    main:setBackground(colors.black)

    -- A blank row under the top bar, matching the server: text touching the bar was hard
    -- to read.
    local topH = 1
    local opsW = math.max(OPS_MIN, math.min(OPS_MAX, math.floor(W * 0.44)))
    local consoleW = W - opsW - 1
    local contentY = topH + 2
    local contentH = H - contentY + 1

    local self = {}
    self.topbar  = TopBar.build(main, { x = 1, y = 1, w = W, h = topH }, config, "Remote Controls")
    self.console = Console.build(main, { x = 1, y = contentY, w = consoleW, h = contentH },
        { fingerprint = fingerprint })
    self.ops     = PanelOps.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        emit, config)
    -- the edit form overlays the ops area only, so the console stays readable while you
    -- define a control
    self.edit    = PanelEdit.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        emit, config)

    -- ----- the operator's own copy of the panel (the failsafe) -----
    -- Rendered with the SAME view the pockets use, so it looks and behaves identically;
    -- only the access rule differs (this PC's approval instead of a pocket session).
    --
    -- The whole surface goes RED while you're in here. This is backup mode: driving the
    -- base from the panel itself rather than from a pocket, and you should never be doing
    -- it by accident or forget you're doing it. Gates and lifts are split, same as the
    -- pocket, so a glance tells you which is which.
    --
    -- The control LISTS sit on a dark strip inside the red frame: the controls now colour their
    -- glyphs (red = open) instead of their background, and a red glyph on a red surface would
    -- vanish. The red frame + headers still shout "backup mode"; the rows just stay readable.
    local BACKUP_BG   = Palette.errorBg
    local CONTROLS_BG = Palette.bg
    local useFrame = main:addFrame({
        x = consoleW + 2, y = contentY, width = opsW, height = contentH,
        background = BACKUP_BG,
    })
    useFrame:addLabel({ x = 1, y = 1, text = "Controls:",
        foreground = colors.white, background = BACKUP_BG })

    local half = math.floor((contentH - 5) / 2)
    useFrame:addLabel({ x = 1, y = 2, text = "Gates",
        foreground = colors.white, background = BACKUP_BG })
    self.useGates = PanelView.build(useFrame, { x = 1, y = 3, w = opsW, h = half }, emit,
        { emptyText = "no gates defined", filter = "gate", background = CONTROLS_BG })

    useFrame:addLabel({ x = 1, y = 3 + half, text = "Elevators",
        foreground = colors.white, background = BACKUP_BG })
    self.useLifts = PanelView.build(useFrame, { x = 1, y = 4 + half, w = opsW, h = half }, emit,
        { emptyText = "no elevators defined", filter = "elevator", background = CONTROLS_BG })

    useFrame:addButton({
        x = 1, y = contentH - 2, width = opsW - 1, height = 3,
        text = "BACK", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() emit("close_panel") end)
    useFrame:setVisible(false)

    --- One handle over both sections; each renders only its own kind.
    self.usePanel = {
        set = function(list) self.useGates.set(list); self.useLifts.set(list) end,
        animate = function() self.useGates.animate(); self.useLifts.animate() end,
        say = function(s) self.useGates.say(s); self.useLifts.say(s) end,
        show = function() self.useGates.show(); self.useLifts.show() end,
        hide = function() self.useGates.hide(); self.useLifts.hide() end,
    }

    function self.openForm(control, outputs)
        useFrame:setVisible(false)
        self.ops.showTab(1)
        self.edit.open(control, outputs)
    end
    function self.closeForm() self.edit.hide() end

    --- Show/hide the operator's panel over the ops tabs.
    function self.openPanel()
        self.edit.hide()
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
