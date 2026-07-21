--- Cosmetic background styles for the pocket UI. PURELY local eye-candy: nothing here
--- talks to another computer, and it only ever draws behind the UI.
---
--- How it stays out of the way: the pocket's content frames are made transparent and a
--- full-screen Display sits behind them (see pocket/app.lua). Basalt labels are transparent
--- too, so their TEXT lands straight on this background. To keep every element readable, all
--- styles therefore keep a DARK (black) base and paint only coloured *glyphs* on top — light
--- text on a dark base always reads, and the decoration simply shows in the empty cells.
---
--- A style is `{ id, name, render = function(win, W, H) }`, where `win` is a CraftOS window
--- and render draws the decoration (the base is already cleared to black). The same render
--- runs for the full screen and for the little menu preview swatches — it's size-driven.
local Backgrounds = {}

local toBlit = colors.toBlit
local BLACK = toBlit(colors.black) -- "f"

--- Deterministic hash -> 0..1 (the classic sin-fract trick). Same (x,y,salt) always gives
--- the same value, so the art never flickers and the render tests are stable.
local function rnd(x, y, salt)
    local n = math.sin(x * 12.9898 + y * 78.233 + (salt or 0) * 37.719) * 43758.5453
    return n - math.floor(n)
end

local function put(win, x, y, ch, fg)
    win.setCursorPos(x, y)
    win.blit(ch, toBlit(fg), BLACK)
end

-- `dark` says whether the base is dark (so light UI text reads straight on it). A LIGHT base
-- (orange/lime/white) instead gets `dark = false`, and the pocket auto-contrasts by giving its
-- text opaque dark backing (see pocket/app.lua). Plain colours carry a `fill`; the two art
-- styles keep a black base and paint glyphs (kept dark on purpose so text always reads on them).
Backgrounds.STYLES = {
    -- a calm starfield: sparse dust, a few brighter stars, the odd twinkle
    {
        id = "starlit", name = "Starlit", dark = true,
        render = function(win, W, H)
            for y = 1, H do
                for x = 1, W do
                    local r = rnd(x, y, 1)
                    if r > 0.992 then put(win, x, y, "+", colors.white)
                    elseif r > 0.975 then put(win, x, y, "*", colors.lightGray)
                    elseif r > 0.94 then put(win, x, y, ".", colors.gray) end
                end
            end
        end,
    },
    -- deep sea: wavy cyan ripples near the top fading to blue below, stray bubbles
    {
        id = "deepsea", name = "Deep Sea", dark = true,
        render = function(win, W, H)
            for y = 1, H do
                for x = 1, W do
                    local s = math.sin((x + y * 2) / 3.0)
                    if s > 0.6 then
                        put(win, x, y, "~", (y <= H / 2) and colors.cyan or colors.blue)
                    elseif rnd(x, y, 3) > 0.986 then
                        put(win, x, y, "o", colors.lightBlue)
                    end
                end
            end
        end,
    },
    -- plain solid colours. blue/gray are dark enough for light text; orange/lime/white are
    -- light, so the pocket flips to dark-backed text on them.
    { id = "orange", name = "Orange", dark = false, fill = colors.orange },
    { id = "blue",   name = "Blue",   dark = true,  fill = colors.blue },
    { id = "lime",   name = "Lime",   dark = false, fill = colors.lime },
    { id = "gray",   name = "Gray",   dark = true,  fill = colors.gray },
    { id = "white",  name = "White",  dark = false, fill = colors.white },
}

--- Does this style need dark-backed text to stay readable? nil (plain black) is dark.
function Backgrounds.isLight(style) return style ~= nil and style.dark == false end

--- Paint `win` (W x H) with the given style (a STYLES entry, or nil for a plain dark base).
function Backgrounds.paint(win, style, W, H)
    win.setBackgroundColor((style and style.fill) or colors.black)
    win.clear()
    if style and style.render then
        local ok = pcall(style.render, win, W, H)
        if not ok then win.setBackgroundColor(colors.black); win.clear() end -- never crash the UI over decor
    end
end

--- Find a style by id, or nil.
function Backgrounds.byId(id)
    for _, s in ipairs(Backgrounds.STYLES) do
        if s.id == id then return s end
    end
    return nil
end

--- Persist the chosen style id at `path` (a pocket-local file). A nil id means "plain", so
--- the file is removed and the next boot comes up with no background.
function Backgrounds.save(id, path)
    if not path then return end
    if id then
        local f = fs.open(path, "w"); if f then f.write(id); f.close() end
    elseif fs.exists(path) then
        fs.delete(path)
    end
end

--- Load the saved style from `path`, or nil (no file / plain / unknown id).
function Backgrounds.load(path)
    if not path or not fs.exists(path) then return nil end
    local f = fs.open(path, "r"); if not f then return nil end
    local id = f.readAll(); f.close()
    return Backgrounds.byId(id and id:gsub("%s+", ""))
end

return Backgrounds
