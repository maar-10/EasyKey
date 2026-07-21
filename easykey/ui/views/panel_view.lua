--- A panel of buttons/switches/latches, exactly as published by a manual control PC.
---
--- Shared by the pocket (its Gates + Lifts tabs) and the manual PC's own backup panel, so
--- the operator's copy looks and behaves like everyone else's.
---
--- Non-optimism is the whole point: the pocket NEVER predicts. Every state comes from the
--- manual PC, which reports what its redstone is ACTUALLY doing. A tap only sends a request;
--- the widget doesn't move until the manual confirms it fired.
---
--- Each control takes TWO rows so the full name fits and the open/closed word shows. The
--- widgets are TRANSPARENT (the wallpaper shows through); only the GLYPH colour changes, never
--- a blocky background. Columns line up across a mixed list:
---
---   button  Name....   [>] o          tap fires; the circle fills (\7, green) once CONFIRMED
---           ..name      ~cd
---   switch  Name....            [.\7.] tap the slider; it slides/recolours only on feedback
---           ..name      ~cd     Open
---   latch   Name....   [>] o    [.\7.] tap the button; the slider shows the CONFIRMED state
---           ..name      ~cd     Open
---
--- Colour is the language: a gate reads RED = open, GREEN = closed (a lift Up/Down), flipped by
--- `invert`. The word underneath spells it out. Buttons get an immediate client-side press
--- flash; everything else waits for the feedback.
---
--- Glyphs are ASCII + \7 only: CC:Tweaked's in-game font differs from CraftOS-PC's, and only
--- those render identically and legibly in both.
local Palette = require("easykey.ui.palette")

local Panel = {}

local KNOB = "\7"                                          -- the ball on a slider (renders in-game)
local TRACK = { "[" .. KNOB .. "..]", "[." .. KNOB .. ".]", "[.." .. KNOB .. "]" } -- step 1..3
local BTN, BTN_HIT = "[>]", "[*]"                         -- momentary button: idle / pressed flash
local DOT, RING = KNOB, "o"                               -- confirm circle: fired (green) / not
local COOL = "~"                                          -- cooldown marker (ASCII placeholder)

local FLASH = 4 -- animate() frames a button stays "pressed" after a tap (~0.5s at 0.12s/frame)

local STATUS_TEXT = { ok = "", out_of_range = "out of range", denied = "access denied",
                      signal_error = "signal error" }
local STATUS_COLOR = { out_of_range = Palette.muted, denied = Palette.warn,
                       signal_error = Palette.error }

--- Whether a control reads as "open" (red) vs "closed" (green): the reported on-state, flipped
--- by `invert` for a control wired the other way.
local function isOpen(on, invert)
    if invert then return not on end
    return on and true or false
end

--- The word under a slider: gates read Open/Closed, lifts Up/Down.
local function stateWord(use, open)
    if use == "elevator" then return open and "Up" or "Down" end
    return open and "Open" or "Closed"
end

--- @param parent table Basalt frame
--- @param region table { x, y, w, h }
--- @param emit function(action, payload)
--- @param opts table|nil { emptyText, filter = "gate"|"elevator"|nil, background, transparent }
function Panel.build(parent, region, emit, opts)
    opts = opts or {}
    local filter = opts.filter
    local bg = opts.background or Palette.bg
    local w, h = region.w, region.h

    local root = parent:addFrame({ x = region.x, y = region.y, width = w, height = h, background = bg })
    local scroll = root:addScrollFrame({ x = 1, y = 1, width = w, height = h - 1,
        background = bg, scrollBarColor = Palette.muted })
    if opts.transparent then
        root.set("backgroundEnabled", false)
        scroll.set("backgroundEnabled", false)
    end
    local empty = root:addLabel({ x = 1, y = 1, text = opts.emptyText or "nothing here",
        foreground = Palette.text, background = bg })
    local msg = root:addLabel({ x = 1, y = h, text = "", foreground = Palette.muted, background = bg })

    local widgets, ordered = {}, {}
    -- auto-contrast: on a LIGHT wallpaper we recolour the CHARACTER, never its background. Every
    -- glyph has a dark-background colour and a light-background one. The meaning survives the
    -- swap: red=open works on both; "closed" green just gets darker; the neutral bits go black.
    -- (Bright lime on a lime wallpaper, or grey on grey, would otherwise vanish.)
    local light = false
    local function nameC()   return light and colors.black or Palette.text end
    local function openC()   return light and colors.red   or Palette.error end -- red reads on both
    local function closedC() return light and colors.green or Palette.ok end     -- lime->dark green
    local function btnC()    return light and colors.blue  or Palette.normal end
    local function ringC()   return light and colors.black or Palette.dim end    -- empty circle
    local function firedC()  return light and colors.green or Palette.ok end     -- lit circle
    local function coolC()   return light and colors.black or colors.orange end
    local function mutedC()  return light and colors.black or Palette.muted end  -- disabled control
    local self = { frame = root }

    -- Two-row grid. The widget zone is a fixed strip on the right so every kind lines up:
    --   name (both rows) | button [>] + cooldown | circle | slider [.\7.] + word
    local ROW_H = 2
    local COOLW = 4                              -- room for "~123"
    local nameW = math.max(6, w - 14)            -- names wrap across the two rows
    local bx = nameW + 2                         -- momentary button (row 1) / cooldown (row 2)
    local cx = bx + 4                            -- confirm circle (row 1)
    local sx = cx + 2                            -- slider (row 1) / open-closed word (row 2)
    local wordW = math.max(4, w - sx)            -- word reaches toward the scrollbar column

    --- Split a name across the two rows (no truncation glyph: ASCII-only, and two rows of
    --- `nameW` is plenty for real names).
    local function wrapName(name)
        name = tostring(name or "")
        if #name <= nameW then return name, "" end
        return name:sub(1, nameW), name:sub(nameW + 1, nameW * 2)
    end

    --- Red = open, green = closed; muted when the control can't be used right now.
    local function stateColour(wgt, open)
        if not wgt.usable then return mutedC() end
        return open and openC() or closedC()
    end

    local function paint(wgt)
        local l1, l2 = wrapName(wgt.rawName)
        local nfg = wgt.usable and nameC() or mutedC()
        wgt.name1:setText(l1); wgt.name1:setForeground(nfg)
        wgt.name2:setText(l2); wgt.name2:setForeground(nfg)

        local open = isOpen(wgt.on, wgt.invert)
        -- the slider (a switch's is clickable = tap-to-toggle; a latch's is display-only)
        if wgt.kind == "switch" or wgt.kind == "latch" then
            wgt.slider:setText(TRACK[wgt.step] or TRACK[1])
            wgt.slider:setForeground(stateColour(wgt, open))
            wgt.word:setText(stateWord(wgt.use, open))
            wgt.word:setForeground(stateColour(wgt, open))
        end
        -- the momentary button (button + latch): a client-side press flash while `flash` > 0
        if wgt.kind == "button" or wgt.kind == "latch" then
            local hit = (wgt.flash or 0) > 0
            wgt.btn:setText(hit and BTN_HIT or BTN)
            wgt.btn:setForeground(not wgt.usable and mutedC() or (hit and Palette.accent or btnC()))
            -- the confirm circle: fills once the pulse was actually seen
            wgt.circle:setText(wgt.fired and DOT or RING)
            wgt.circle:setForeground(wgt.fired and firedC() or ringC())
        end
        -- the cooldown, only while it's locked (sits under the button, row 2)
        local cd = wgt.cooldown or 0
        if cd > 0 then
            wgt.cool:setText(COOL .. cd); wgt.cool:setForeground(coolC()); wgt.cool:setVisible(true)
        else
            wgt.cool:setVisible(false)
        end
    end

    --- Slide any slider knob toward its confirmed target, and decay a button's press flash.
    --- Driven by the host tick; it only ever animates towards what the manual reported.
    function self.animate()
        local moved = false
        for _, wgt in pairs(widgets) do
            local m = false
            if wgt.kind == "switch" or wgt.kind == "latch" then
                local target = isOpen(wgt.on, wgt.invert) and 3 or 1
                if wgt.step ~= target then
                    wgt.step = wgt.step + (target > wgt.step and 1 or -1); m = true
                end
            end
            if (wgt.flash or 0) > 0 then wgt.flash = wgt.flash - 1; m = true end
            if m then paint(wgt); moved = true end
        end
        return moved
    end

    --- @param panels table array of { address, status, controls = { { id, name, type, use,
    ---        invert, on, err, fired, cooldown } } }
    function self.set(panels)
        local seen, worst, row = {}, nil, 1
        ordered = {}

        for _, p in ipairs(panels or {}) do
            local usable = (p.status == "ok")
            if not usable and not worst then worst = p.status end

            for _, c in ipairs(p.controls or {}) do
                local kind = (c.type == "switch" and "switch")
                    or (c.type == "latch" and "latch") or "button"
                local use = (c.use == "elevator") and "elevator" or "gate"
                if not filter or filter == use then
                    local key = p.address .. "|" .. c.id
                    seen[key] = true
                    local wgt = widgets[key]
                    if not wgt then
                        wgt = {}
                        wgt.name1 = scroll:addLabel({ x = 1, y = 1, text = "", foreground = nameC() })
                        wgt.name2 = scroll:addLabel({ x = 1, y = 2, text = "", foreground = nameC() })
                        wgt.btn = scroll:addButton({ x = bx, y = 1, width = 3, height = 1,
                            text = BTN, foreground = btnC() })
                        wgt.circle = scroll:addLabel({ x = cx, y = 1, text = RING, foreground = ringC() })
                        wgt.slider = scroll:addButton({ x = sx, y = 1, width = 5, height = 1,
                            text = TRACK[1], foreground = closedC() })
                        wgt.word = scroll:addLabel({ x = sx, y = 2, width = wordW, text = "",
                            foreground = closedC() })
                        wgt.cool = scroll:addLabel({ x = bx, y = 2, text = "", foreground = coolC() })
                        -- transparent widgets: the wallpaper shows through, only the glyph is coloured
                        for _, el in ipairs({ wgt.btn, wgt.slider }) do el.set("backgroundEnabled", false) end
                        -- a button/latch taps via its button; a switch taps via its slider
                        wgt.btn:onClick(function()
                            if wgt.kind == "switch" then return end
                            emit("panel_tap", { address = wgt.address, id = wgt.id })
                            wgt.flash = FLASH; paint(wgt)
                        end)
                        wgt.slider:onClick(function()
                            if wgt.kind ~= "switch" then return end -- a latch's slider is display-only
                            emit("panel_tap", { address = wgt.address, id = wgt.id })
                        end)
                        widgets[key] = wgt
                    end

                    wgt.kind = kind
                    wgt.use = use
                    wgt.rawName = c.name
                    wgt.usable = usable
                    wgt.on = c.on and true or false
                    wgt.err = c.err
                    wgt.fired = c.fired and true or false
                    wgt.invert = c.invert and true or false
                    wgt.cooldown = tonumber(c.cooldown) or 0
                    wgt.address, wgt.id = p.address, c.id
                    wgt.step = wgt.step or (isOpen(wgt.on, wgt.invert) and 3 or 1)

                    -- position this control's two rows
                    local y = (row - 1) * ROW_H + 1
                    wgt.name1:setY(y);     wgt.name1:setWidth(nameW); wgt.name1:setVisible(true)
                    wgt.name2:setY(y + 1); wgt.name2:setWidth(nameW); wgt.name2:setVisible(true)
                    wgt.cool:setY(y + 1)
                    -- momentary button + confirm circle: button and latch only
                    local hasBtn = (kind ~= "switch")
                    wgt.btn:setY(y); wgt.btn:setVisible(hasBtn)
                    wgt.circle:setY(y); wgt.circle:setVisible(hasBtn)
                    -- slider + word: switch and latch only
                    local hasSlider = (kind ~= "button")
                    wgt.slider:setY(y); wgt.slider:setVisible(hasSlider)
                    wgt.word:setY(y + 1); wgt.word:setVisible(hasSlider)

                    paint(wgt)
                    ordered[row] = wgt
                    row = row + 1
                end
            end
        end

        for key, wgt in pairs(widgets) do
            if not seen[key] then
                for _, el in pairs({ wgt.name1, wgt.name2, wgt.btn, wgt.circle,
                                     wgt.slider, wgt.word, wgt.cool }) do el:destroy() end
                widgets[key] = nil
            end
        end

        local count = row - 1
        empty:setVisible(count == 0)
        scroll:setVisible(count > 0)
        if count == 0 or not worst then msg:setText("")
        else
            msg:setText(STATUS_TEXT[worst] or tostring(worst))
            msg:setForeground(STATUS_COLOR[worst] or Palette.error)
        end
    end

    --- Show why a tap did nothing (the manual PC's answer), or clear it.
    function self.say(status)
        if not status or status == "ok" then msg:setText(""); return end
        msg:setText(STATUS_TEXT[status] or tostring(status))
        msg:setForeground(STATUS_COLOR[status] or Palette.error)
    end

    --- Auto-contrast: on a LIGHT wallpaper the neutral name text is drawn dark so it reads; on a
    --- dark one it's white. We recolour the CHARACTER, not its background (the widgets stay
    --- transparent either way). Semantic glyphs keep their red/green meaning-colours.
    function self.retheme(isLight)
        light = isLight and true or false
        empty:setForeground(nameC())
        for _, wgt in pairs(widgets) do paint(wgt) end
    end

    function self.show() root:setVisible(true) end
    function self.hide() root:setVisible(false) end

    --- Test seam: tap the i-th shown control, exactly as its widget's handler does.
    function self.clickRow(i)
        local wgt = ordered[i]
        if not wgt then return false end
        emit("panel_tap", { address = wgt.address, id = wgt.id })
        return true
    end

    function self.count() return #ordered end

    root:setVisible(false)
    self.widgets = widgets -- test seam
    return self
end

return Panel
