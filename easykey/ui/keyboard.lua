--- On-screen alphanumeric keyboard for the monitor UIs (server + manual PC).
---
--- Monitors have no keyboard, and typing a name blind on the PC's keyboard was the clunky
--- part of naming a control. This is a tap-only ABC+123 keyboard with a live preview, so a
--- name is entered entirely at the monitor and you can see it as you build it. Numbers-only
--- entry (keys, ranges) keeps using the numeric keypad; this is for free text.
---
--- Lives as a hidden overlay the host shows/hides. Returns the text through `onSubmit`.
local Palette = require("easykey.ui.palette")

local Keyboard = {}

-- Letters/digits, row-major. The last two rows carry a couple of name-friendly symbols.
local ROWS = {
    { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
    { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
    { "A", "S", "D", "F", "G", "H", "J", "K", "L", "-" },
    { "Z", "X", "C", "V", "B", "N", "M", "_" },
}

--- @param parent table Basalt frame (the app root or an overlay host)
--- @param region table { x, y, w, h }
--- @param cb table { onSubmit=function(text), onCancel=function(), title=string, maxLen=number }
function Keyboard.build(parent, region, cb)
    local w, h = region.w, region.h
    local maxLen = cb.maxLen or 20

    local panel = parent:addFrame({ x = region.x, y = region.y, width = w, height = h,
        background = colors.black })
    panel:addLabel({ x = 2, y = 1, text = cb.title or "Type a name:",
        foreground = Palette.accent, background = colors.black })
    local entry = panel:addLabel({ x = 2, y = 2, text = "",
        foreground = colors.white, background = colors.gray })

    local buffer = ""
    local caps = true -- names usually read better capitalised; Shift flips it
    local letterBtns = {}

    local function shown(ch)
        if caps then return ch else return ch:lower() end
    end

    local function refresh()
        local field = w - 4
        local s = buffer
        if #s > field - 1 then s = "\26" .. s:sub(#s - field + 3) end -- keep the tail visible
        entry:setText(" " .. s .. "_" .. string.rep(" ", math.max(0, field - #s - 1)))
    end

    local function type_(ch)
        if #buffer < maxLen then buffer = buffer .. ch; refresh() end
    end

    -- ----- letter / digit grid -----
    local cols = 10
    local cellW = math.max(2, math.floor(w / cols))
    local gridY, rowStep = 4, 2
    for r, row in ipairs(ROWS) do
        local y = gridY + (r - 1) * rowStep
        for c, ch in ipairs(row) do
            local isLetter = ch:match("%a") ~= nil
            local b = panel:addButton({
                x = (c - 1) * cellW + 1, y = y, width = cellW - 1, height = 1,
                text = shown(ch), background = Palette.normalBg, foreground = Palette.onNormal,
            })
            b:onClick(function() type_(shown(ch)) end)
            if isLetter then letterBtns[#letterBtns + 1] = { btn = b, ch = ch } end
        end
    end

    -- ----- action row: Shift | Space | Del | OK | X -----
    local ay = gridY + #ROWS * rowStep + 1
    local function relabelLetters()
        for _, e in ipairs(letterBtns) do e.btn:setText(shown(e.ch)) end
    end
    local x = 1
    local function action(label, width, bg, fg, fn)
        local b = panel:addButton({ x = x, y = ay, width = width, height = 1,
            text = label, background = bg, foreground = fg })
        b:onClick(fn)
        x = x + width + 1
        return b
    end
    local shiftBtn = action("aA", 3, Palette.bar, Palette.text, function()
        caps = not caps; relabelLetters()
    end)
    action("Space", math.max(5, w - 22), Palette.bar, Palette.text, function() type_(" ") end)
    action("Del", 4, Palette.warnBg, Palette.onWarn, function()
        buffer = buffer:sub(1, -2); refresh()
    end)
    action("OK", 4, Palette.okBg, Palette.onOk, function()
        if buffer ~= "" then cb.onSubmit(buffer) else cb.onCancel() end
    end)
    action("X", 3, Palette.errorBg, Palette.onError, function() cb.onCancel() end)

    panel:setVisible(false)
    local self = { frame = panel }

    --- Open the keyboard, optionally editing an existing value.
    function self.show(initial)
        buffer = tostring(initial or "")
        caps = true; relabelLetters()
        refresh()
        panel:setVisible(true)
    end
    function self.hide() panel:setVisible(false) end

    -- ----- test seams (real taps can't be simulated headless) -----
    function self.type(s) for i = 1, #s do type_(s:sub(i, i)) end end
    function self.value() return buffer end
    function self.submit() if buffer ~= "" then cb.onSubmit(buffer) else cb.onCancel() end end

    return self
end

return Keyboard
