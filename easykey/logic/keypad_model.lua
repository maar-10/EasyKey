--- Keypad entry buffer (PURE — no CC/Basalt deps, unit-testable). Interprets
--- button presses: normal characters append to the buffer; the three reserved
--- action tokens (submit / backspace / cancel) drive the flow. Kept separate
--- from the view so the entry rules can be tested without rendering.
---@class Keypad
local Keypad = {}
Keypad.__index = Keypad

--- @param opts table { maxLen=number, actions={ submit=, backspace=, cancel= } }
function Keypad.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Keypad)
    self._maxLen = opts.maxLen or 24
    local a = opts.actions or {}
    self._submit = a.submit or "OK"
    self._backspace = a.backspace or "<"
    self._cancel = a.cancel or "X"
    self._buf = {}
    return self
end

--- Handle a button. Returns one of:
---   "append" | "backspace" | "cancel" | "submit" | "full" | "noop"
function Keypad:press(char)
    if char == self._submit then
        return "submit"
    elseif char == self._backspace then
        if #self._buf > 0 then table.remove(self._buf) ; return "backspace" end
        return "noop"
    elseif char == self._cancel then
        self:clear()
        return "cancel"
    else
        if #self._buf >= self._maxLen then return "full" end
        self._buf[#self._buf + 1] = char
        return "append"
    end
end

--- The entered value.
function Keypad:value()
    return table.concat(self._buf)
end

--- Number of entered characters.
function Keypad:len()
    return #self._buf
end

--- Reset the buffer.
function Keypad:clear()
    self._buf = {}
end

--- The buffer rendered with a mask character (for display).
function Keypad:masked(maskChar)
    maskChar = maskChar or "\7"
    return string.rep(maskChar, #self._buf)
end

return Keypad
