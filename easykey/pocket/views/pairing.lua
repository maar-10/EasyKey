--- Pairing screen: the one-time trust decision.
---
--- Shows the servers that answered discovery as 8-char fingerprints. The user checks
--- one against the fingerprint printed on the SERVER's own screen and taps it. That
--- comparison IS the security step — it's what stops an impostor from becoming your
--- server — so the UI leads with it rather than burying it.
---
--- Taps are reported as events (not direct calls) so the network coroutine owns all
--- pairing logic; the view stays dumb.
local Pairing = {}

local MAX_SHOWN = 3

local function centre(label, text, w, y)
    label:setText(text):setX(math.max(1, math.floor((w - #text) / 2) + 1)):setY(y)
end

--- @param parent table Basalt frame
--- @param region table { x, y, w, h }
--- @param emit function(action, payload) reports user intent
function Pairing.build(parent, region, emit)
    local w, h = region.w, region.h
    local panel = parent:addFrame({ x = region.x, y = region.y, width = w, height = h,
        background = colors.black })

    local title = panel:addLabel({ x = 1, y = 1, text = "", foreground = colors.cyan,
        background = colors.black })
    local hint1 = panel:addLabel({ x = 1, y = 3, text = "", foreground = colors.white,
        background = colors.black })
    local hint2 = panel:addLabel({ x = 1, y = 4, text = "", foreground = colors.white,
        background = colors.black })

    local buttons = {}
    for i = 1, MAX_SHOWN do
        local b = panel:addButton({
            x = 2, y = 5 + (i - 1) * 3, width = w - 2, height = 2,
            text = "", background = colors.blue, foreground = colors.white,
        })
        b:setVisible(false)
        buttons[i] = b
    end

    local rescan = panel:addButton({
        x = 2, y = h - 2, width = w - 2, height = 3,
        text = "RESCAN", background = colors.gray, foreground = colors.white,
    })
    rescan:onClick(function() emit("rescan") end)

    local self = { frame = panel }

    function self.setSearching()
        centre(title, "Pairing", w, 1); title:setForeground(colors.cyan)
        centre(hint1, "searching for", w, 3)
        centre(hint2, "the server...", w, 4)
        for _, b in ipairs(buttons) do b:setVisible(false) end
        rescan:setVisible(false)
    end

    function self.setNone()
        centre(title, "Pairing", w, 1); title:setForeground(colors.red)
        centre(hint1, "no server found", w, 3)
        centre(hint2, "check it's running", w, 4)
        for _, b in ipairs(buttons) do b:setVisible(false) end
        rescan:setVisible(true)
    end

    --- @param found table array of { address, distance }
    function self.setCandidates(found)
        centre(title, "Trust this server?", w, 1); title:setForeground(colors.yellow)
        centre(hint1, "match against the", w, 3)
        centre(hint2, "SERVER screen:", w, 4)
        for i, b in ipairs(buttons) do
            local cand = found[i]
            if cand then
                b:setText(cand.address:sub(1, 8))
                b:setBackground(colors.blue)
                b:setVisible(true)
                b:onClick(function() emit("pair_choice", cand.address) end)
            else
                b:setVisible(false)
            end
        end
        rescan:setVisible(true)
    end

    panel:setVisible(false)
    function self.show() panel:setVisible(true) end
    function self.hide() panel:setVisible(false) end

    return self
end

return Pairing
