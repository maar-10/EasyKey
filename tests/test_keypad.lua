--- Unit tests for the pure keypad entry model.
return function(t)
    local Keypad = require("easykey.logic.keypad_model")
    t:describe("keypad")

    local kp = Keypad.new({ maxLen = 4, actions = { submit = "OK", backspace = "<", cancel = "X" } })

    t:eq(kp:press("1"), "append", "digit appends")
    t:eq(kp:press("2"), "append", "digit appends 2")
    t:eq(kp:value(), "12", "buffer accumulates")
    t:eq(kp:len(), 2, "len tracks")
    t:eq(kp:masked("*"), "**", "masked hides value")

    t:eq(kp:press("<"), "backspace", "backspace action")
    t:eq(kp:value(), "1", "backspace removes last")

    t:eq(kp:press("*"), "append", "special char appends")
    t:eq(kp:press("#"), "append", "hash appends")
    t:eq(kp:value(), "1*#", "specials transmitted verbatim")

    -- length cap
    t:eq(kp:press("9"), "append", "fourth char ok")
    t:eq(kp:press("9"), "full", "fifth char rejected (maxLen 4)")
    t:eq(kp:len(), 4, "len capped at maxLen")

    -- submit returns action, keeps value
    t:eq(kp:press("OK"), "submit", "submit action")
    t:eq(kp:value(), "1*#9", "value intact at submit")

    -- cancel clears
    t:eq(kp:press("X"), "cancel", "cancel action")
    t:eq(kp:value(), "", "cancel clears buffer")
    t:eq(kp:len(), 0, "len zero after cancel")

    -- backspace on empty is a no-op
    t:eq(kp:press("<"), "noop", "backspace on empty is noop")
end
