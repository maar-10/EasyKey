--- Screen assertions for the headless render tests.
---
--- Exists because a render test that only dumps TEXT is a trap: the server's console and
--- lists once rendered perfectly in the dump while being completely invisible in-game
--- (black text on a black background — Basalt's List foreground doesn't default to white,
--- and per-item `foreground`/`background` are ignored in favour of `fg`/`bg`). The text
--- layer looked flawless; the colour layer was the whole bug.
---
--- So: always check the colour layer too. `window.getLine(y)` returns text, fg and bg as
--- parallel hex strings, one char per cell.
local UIAssert = {}

--- Every cell that draws a visible glyph must have fg ~= bg.
--- Returns ok, list-of-problems (each { y, x, char, colour }).
--- @param win table a window created with window.create(..., true)
--- @param W number
--- @param H number
function UIAssert.noInvisibleText(win, W, H)
    local problems = {}
    for y = 1, H do
        local text, fg, bg = win.getLine(y)
        text, fg, bg = text or "", fg or "", bg or ""
        for x = 1, #text do
            local ch = text:sub(x, x)
            -- only glyphs matter; a space is invisible either way and that's fine
            if ch ~= " " and ch ~= "" then
                local f, b = fg:sub(x, x), bg:sub(x, x)
                if f == b and f ~= "" then
                    problems[#problems + 1] = { y = y, x = x, char = ch, colour = f }
                end
            end
        end
    end
    return #problems == 0, problems
end

--- Compact, readable summary of the first few problems (for the results file).
function UIAssert.describe(problems, limit)
    limit = limit or 5
    local out = {}
    for i = 1, math.min(#problems, limit) do
        local p = problems[i]
        out[#out + 1] = ("row %d col %d: '%s' fg==bg=%s"):format(p.y, p.x, p.char, p.colour)
    end
    if #problems > limit then
        out[#out + 1] = ("... and %d more"):format(#problems - limit)
    end
    return table.concat(out, "; ")
end

--- Assert some text actually appears on screen (guards against "rendered nothing").
--- @param needle string
function UIAssert.containsText(win, H, needle)
    for y = 1, H do
        local text = win.getLine(y) or ""
        if text:find(needle, 1, true) then return true end
    end
    return false
end

return UIAssert
