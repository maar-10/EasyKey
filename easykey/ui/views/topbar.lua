--- Top bar for the monitor UIs (server + manual panel): identity on the left,
--- Minecraft day/time in the middle, real-life date + time on the right. Refreshed
--- once a second by the app's tick.
---
--- The device's fingerprint used to live here, but it crowded the identity line; it now
--- has its own lime "ID = ..." label in the bottom-left corner (under the console), which
--- is what you read off this screen when pairing a device.
local Util = require("shared.util")

local TopBar = {}

function TopBar.build(parent, region, config, title)
    local w = region.w
    local bar = parent:addFrame({ x = region.x, y = region.y, width = w, height = region.h,
        background = colors.gray })

    local ident = bar:addLabel({ x = 2, y = 1, text = "", foreground = colors.white,
        background = colors.gray })
    local mc    = bar:addLabel({ x = 1, y = 1, text = "", foreground = colors.white,
        background = colors.gray })
    local irl   = bar:addLabel({ x = 1, y = 1, text = "", foreground = colors.white,
        background = colors.gray })

    ident:setText("EasyKey " .. (title or ""))
    ident:setForeground(colors.yellow)

    local self = { frame = bar }

    function self.update()
        -- Minecraft time (centre)
        local t, day = os.time(), os.day()
        local hh = math.floor(t)
        local mm = math.floor((t - hh) * 60)
        local isDay = t >= 6 and t < 18
        local mcText = ("MC Day %d  %02d:%02d %s"):format(day, hh, mm, isDay and "\7" or "\186")
        mc:setText(mcText)
        mc:setX(math.max(1, math.floor((w - #mcText) / 2)))
        mc:setForeground(isDay and colors.yellow or colors.lightBlue)

        -- real-life date + time (right), timezone per config.ui.clock
        local mode = config and config.ui and config.ui.clock
        local secs
        if mode == "local" then
            secs = math.floor(os.epoch("local") / 1000)
        elseif type(mode) == "number" then
            secs = math.floor(os.epoch("utc") / 1000) + mode * 3600
        else
            secs = math.floor(os.epoch("utc") / 1000) + Util.germanOffsetHours(os.epoch("utc")) * 3600
        end
        local irlText = os.date("!%Y-%m-%d %H:%M:%S", secs)
        irl:setText(irlText)
        irl:setX(math.max(1, w - #irlText))
    end

    self.update()
    return self
end

return TopBar
