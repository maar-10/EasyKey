--- The pocket's status bar: one row, above the tabs.
---
--- Short forms only — the pocket is 26 columns and the tabs below need every row:
---
---     D6477 16:59*        ╬ 20:59:46
---     └ MC day + time ┘   └ your PC's clock ┘
---
--- Day/night isn't spelled out: the little circle next to the MC time is yellow by day
--- and pale blue by night, which says it faster than a word does and costs 1 column.
--- The real-life clock is marked with an OS glyph (Config.ui.osSign) rather than "IRL".
local Util    = require("shared.util")
local Palette = require("easykey.ui.palette")

local Clock = {}

--- @param parent table Basalt frame
--- @param region table { x, y, w, h } (h = 1)
--- @param config table system config
function Clock.build(parent, region, config)
    local w = region.w
    local bar = parent:addFrame({ x = region.x, y = region.y, width = w, height = 1,
        background = Palette.bg })

    local mc  = bar:addLabel({ x = 1, y = 1, text = "", foreground = Palette.text,
        background = Palette.bg })
    local irl = bar:addLabel({ x = 1, y = 1, text = "", foreground = Palette.dim,
        background = Palette.bg })

    local osSign = (config and config.ui and config.ui.osSign) or "@"

    -- auto-contrast: on a LIGHT wallpaper we recolour the CHARACTERS dark, never their
    -- background. Both clocks go black — a warm/cool day/night tint can't be guaranteed to
    -- contrast with an arbitrary light wallpaper (yellow-on-orange etc.), and the time itself
    -- still reads day vs night.
    local light = false

    local self = {}
    function self.update()
        local t, day = os.time(), os.day()
        local hh = math.floor(t)
        local mm = math.floor((t - hh) * 60)
        local isDay = t >= 6 and t < 18

        -- "D6477 16:59" + the day/night dot, which carries the meaning by colour alone
        local mcText = ("D%d %02d:%02d\7"):format(day, hh, mm)
        mc:setText(mcText)
        if light then mc:setForeground(colors.black)
        elseif isDay then mc:setForeground(colors.yellow)
        else mc:setForeground(colors.lightBlue) end

        local irlText = osSign .. " " .. Util.clockString(config and config.ui and config.ui.clock)
        irl:setText(irlText)
        irl:setForeground(light and colors.black or Palette.dim)
        irl:setX(math.max(#mcText + 2, w - #irlText + 1))
    end

    --- Auto-contrast: recolour the characters for a light vs dark wallpaper (see above), never
    --- their background. Re-runs update() to re-apply the day/night + IRL colours.
    function self.retheme(isLight)
        light = isLight and true or false
        self.update()
    end

    self.frame = bar
    self.update()
    return self
end

return Clock
