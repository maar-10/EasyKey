--- Custom on-screen keypad (Basalt), shared by the pocket and the server UI.
---
--- A grid of buttons built from config.keypad.chars; taps drive a pure Keypad model
--- (entry buffer). The entered value is masked, so a key is never shown on screen -
--- which matters on the server, whose monitor may be visible to whoever walks past.
--- Submit/backspace/cancel are the reserved action tokens in the config. Lives as a
--- hidden overlay the host app shows/hides.
local Keypad = require("easykey.logic.keypad_model")

local View = {}

--- @param parent table Basalt frame (the app root)
--- @param region table { x, y, w, h } (usually the full screen)
--- @param config table system config (config.keypad)
--- @param cb table { onSubmit=function(value), onCancel=function(), title=string }
function View.build(parent, region, config, cb)
    local kp = config.keypad
    local w, h = region.w, region.h
    local model = Keypad.new({ maxLen = kp.maxLen, actions = kp.actions })

    local panel = parent:addFrame({ x = region.x, y = region.y, width = w, height = h,
        background = colors.black })

    panel:addLabel({ x = 2, y = 1, text = (cb.title or "Enter key:"),
        foreground = colors.cyan, background = colors.black })
    local entry = panel:addLabel({ x = 2, y = 2, text = "", foreground = colors.white, background = colors.gray })
    local msg   = panel:addLabel({ x = 2, y = h, text = "", foreground = colors.lightGray, background = colors.black })

    local cols = kp.cols
    local rows = math.ceil(#kp.chars / cols)
    local gridY = 4
    local cellW = math.floor(w / cols)
    local gridH = (h - 1) - gridY + 1
    local cellH = math.max(1, math.floor(gridH / rows))

    local function colorFor(char)
        if char == kp.actions.submit then return colors.green, colors.white end
        if char == kp.actions.cancel then return colors.red, colors.white end
        if char == kp.actions.backspace then return colors.orange, colors.black end
        return colors.blue, colors.white
    end

    -- Keys are masked (a monitor may be overlooked); a plain number (a bar duration) is shown
    -- as typed. `kp.mask` being falsy means "reveal".
    local function refreshEntry()
        local shown = kp.mask and model:masked(kp.mask) or model:value()
        if shown == "" then shown = " " end
        entry:setText(" " .. shown .. string.rep(" ", math.max(0, w - 4 - #shown)))
    end

    local function press(char)
        local r = model:press(char)
        if r == "submit" then
            if model:len() > 0 then
                cb.onSubmit(model:value())
            else
                msg:setText("enter a key first"); msg:setForeground(colors.orange)
            end
        elseif r == "cancel" then
            cb.onCancel()
        elseif r == "full" then
            msg:setText("max length"); msg:setForeground(colors.orange)
        else
            msg:setText(""); refreshEntry()
        end
    end

    -- leave a 1-cell gap between buttons when there is room to breathe
    local btnW = math.max(1, cellW - 1)
    local btnH = cellH > 1 and (cellH - 1) or cellH

    for i, char in ipairs(kp.chars) do
        local idx = i - 1
        local c = idx % cols
        local rrow = math.floor(idx / cols)
        local bg, fg = colorFor(char)
        local b = panel:addButton({
            x = c * cellW + 1, y = gridY + rrow * cellH,
            width = btnW, height = btnH,
            text = char, background = bg, foreground = fg,
        })
        b:onClick(function() press(char) end)
    end

    local self = {}

    function self.show()
        model:clear()
        msg:setText(""); msg:setForeground(colors.lightGray)
        refreshEntry()
        panel:setVisible(true)
    end

    function self.hide()
        panel:setVisible(false)
    end

    function self.setMessage(text, color)
        msg:setText(text or ""); msg:setForeground(color or colors.lightGray)
    end

    --- Test seam: enter a value and submit, exactly as tapping the digits + OK would (real
    --- taps can't be simulated headless).
    function self.testSubmit(value)
        model:clear()
        local s = tostring(value)
        for i = 1, #s do press(s:sub(i, i)) end
        press(kp.actions.submit)
    end

    panel:setVisible(false)
    self.frame = panel
    return self
end

return View
