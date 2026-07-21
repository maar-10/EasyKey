--- The pocket's appearance menu. Two tabs:
---   BGs    - cosmetic backgrounds: a swatch + name per style (tap to apply), plus "Plain".
---   Themes - placeholder for later: full colour + contrast themes, not just the wallpaper.
--- Purely local — nothing here touches the network.
---
--- Each swatch is a little Display painted by the SAME render the full-screen background uses
--- (it's size-driven), so the preview is honest about what you'll get.
local Palette     = require("easykey.ui.palette")
local Backgrounds = require("easykey.pocket.views.backgrounds")

local BgMenu = {}

--- @param parent table Basalt frame (the app root)
--- @param region table { x, y, w, h } (usually the full screen)
--- @param cb table { onPick = function(style|nil), onBack = function() }
function BgMenu.build(parent, region, cb)
    local w, h = region.w, region.h
    local panel = parent:addFrame({ x = region.x, y = region.y, width = w, height = h,
        background = colors.black })

    -- ----- tab strip -----
    local TABS = { "BGs", "Themes" }
    local tabW = math.floor(w / #TABS)
    local tabBtns, frames, active = {}, {}, 1

    frames[1] = panel:addFrame({ x = 1, y = 2, width = w, height = h - 3, background = colors.black })
    frames[2] = panel:addFrame({ x = 1, y = 2, width = w, height = h - 3, background = colors.black })

    local function paintTabs()
        for i = 1, #TABS do
            tabBtns[i]:setBackground(i == active and colors.white or Palette.bar)
            tabBtns[i]:setForeground(i == active and colors.black or Palette.text)
        end
    end
    local function showTab(i)
        active = i
        for n = 1, #TABS do frames[n]:setVisible(n == i) end
        paintTabs()
    end
    for i, name in ipairs(TABS) do
        local width = (i == #TABS) and (w - tabW * (i - 1)) or tabW
        tabBtns[i] = panel:addButton({ x = (i - 1) * tabW + 1, y = 1, width = width, height = 1,
            text = name, background = Palette.bar, foreground = Palette.text })
        tabBtns[i]:onClick(function() showTab(i) end)
    end

    -- ----- BGs tab: one row per style (swatch + name), then Plain -----
    local bgs, SW = frames[1], 6
    for i, style in ipairs(Backgrounds.STYLES) do
        local swatch = bgs:addDisplay({ x = 2, y = i, width = SW, height = 1 })
        Backgrounds.paint(swatch:getWindow(), style, SW, 1)
        bgs:addButton({ x = 2 + SW + 1, y = i, width = w - (SW + 3), height = 1,
            text = style.name, background = Palette.bar, foreground = Palette.text,
        }):onClick(function() cb.onPick(style) end)
    end
    bgs:addButton({ x = 2, y = #Backgrounds.STYLES + 2, width = w - 3, height = 1,
        text = "Plain (none)", background = Palette.bar, foreground = Palette.text,
    }):onClick(function() cb.onPick(nil) end)

    -- ----- Themes tab: placeholder -----
    local th = frames[2]
    th:addLabel({ x = 2, y = 2, text = "Themes", foreground = Palette.accent, background = colors.black })
    th:addLabel({ x = 2, y = 4, text = "Coming soon: full", foreground = Palette.dim, background = colors.black })
    th:addLabel({ x = 2, y = 5, text = "colour + contrast", foreground = Palette.dim, background = colors.black })
    th:addLabel({ x = 2, y = 6, text = "presets, not just", foreground = Palette.dim, background = colors.black })
    th:addLabel({ x = 2, y = 7, text = "the wallpaper.", foreground = Palette.dim, background = colors.black })

    -- ----- shared Back -----
    panel:addButton({ x = 2, y = h - 1, width = w - 3, height = 1,
        text = "Back", background = Palette.normalBg, foreground = Palette.onNormal,
    }):onClick(function() cb.onBack() end)

    panel:setVisible(false)
    local self = { frame = panel }
    function self.show() showTab(1); panel:setVisible(true) end
    function self.hide() panel:setVisible(false) end
    return self
end

return BgMenu
