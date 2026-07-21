--- Composes the server's monitor UI: top bar across the top, the raw console on the
--- left (it's what you actually watch), and the operations panel on the right.
---
--- Layout is proportional and computed from the real screen size, so it adapts to
--- whatever monitor is attached rather than assuming a 5x3 one.
---
--- Like the pocket, this holds NO logic: user intent goes out through `emit` and the
--- server's own loop decides what to do.
local TopBar  = require("easykey.ui.views.topbar")
local Console = require("easykey.ui.views.console")
local Ops     = require("easykey.ui.views.ops")

local App = {}

--- Ops panel width: enough for a keypad, readable buttons, and four full-word tabs
--- ("Sessions" is 8 chars, so each tab needs 9 columns), but never more than half the
--- screen — the console deserves the space on a wide monitor.
local OPS_MIN, OPS_MAX = 28, 40

--- @param main table Basalt root frame (bound to the monitor, or the terminal)
--- @param config table system config
--- @param fingerprint string this server's short fingerprint (shown for pairing)
--- @param emit function(action, payload)
function App.build(main, config, fingerprint, emit)
    local W, H = main.get("width"), main.get("height")
    main:setBackground(colors.black)

    -- A blank row under the top bar: text butted straight against the bar was hard to
    -- read, so content starts one row lower and gives back the height.
    local topH = 1
    local opsW = math.max(OPS_MIN, math.min(OPS_MAX, math.floor(W * 0.44)))
    local consoleW = W - opsW - 1
    local contentY = topH + 2
    local contentH = H - contentY + 1

    local self = {}
    self.topbar  = TopBar.build(main, { x = 1, y = 1, w = W, h = topH }, config, "Server")
    self.console = Console.build(main, { x = 1, y = contentY, w = consoleW, h = contentH },
        { fingerprint = fingerprint })
    self.ops     = Ops.build(main, { x = consoleW + 2, y = contentY, w = opsW, h = contentH },
        config, emit)

    --- Called once a second: only the clock is time-driven. Lists are refreshed on
    --- change by the server, not on a tick, so a scrolled-up console stays put.
    function self.tick() self.topbar.update() end

    function self.log(text, level) self.console.log(text, level) end

    return self
end

return App
