--- A selectable list of rows, built from Buttons inside a ScrollFrame.
---
--- Why not Basalt's `List`? Its hit-testing mis-maps inside a TabControl: children are
--- RENDERED offset by the tab header but POSITIONED (and hit-tested) without it, so the
--- list believed its first row was one line above where it was drawn. Tapping the only
--- visible row computed row 2 of a 1-row list and selected nothing — a dead list, while
--- the 3-tall action buttons absorbed the same shift and kept working.
---
--- Buttons in a ScrollFrame are the pattern already proven to work on monitors in the
--- first project, so selection is done here rather than trusting List's internals:
--- each row is a real Button, and we track the selection ourselves.
---
--- Rows are keyed by an opaque `key` (an address, a key id...) which is what the caller
--- gets back from `selected()` — never an index, so a refresh can't shift it onto a
--- different device.
local Palette = require("easykey.ui.palette")

local RowList = {}

local SELECTED_BG = Palette.selected

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param opts table|nil { emptyText = string }
function RowList.build(parent, region, opts)
    opts = opts or {}
    local emptyText = opts.emptyText or "empty"

    local frame = parent:addFrame({
        x = region.x, y = region.y, width = region.w, height = region.h,
        background = colors.black,
    })
    local empty = frame:addLabel({
        x = 1, y = 1, text = emptyText,
        foreground = Palette.muted, background = Palette.bg,
    })
    local scroll = frame:addScrollFrame({
        x = 1, y = 1, width = region.w, height = region.h,
        background = colors.black, scrollBarColor = colors.gray,
    })

    local rows = {}          -- array of { key, button, fg }
    local selectedKey = nil
    local rowW = region.w - 1
    local tapHandler = nil   -- optional: act on tap as well as select

    --- Buttons centre their text, which reads wrong in a list. Padding each row to the
    --- full button width makes centring a no-op, so rows line up on the left.
    local function fitRow(text)
        text = " " .. tostring(text)
        if #text > rowW then return text:sub(1, rowW - 1) .. "\26" end -- 26 = truncation arrow
        return text .. string.rep(" ", rowW - #text)
    end

    local self = {}

    local function paint()
        for _, r in ipairs(rows) do
            local isSel = (r.key == selectedKey)
            r.button:setBackground(isSel and SELECTED_BG or Palette.bg)
            r.button:setForeground(isSel and Palette.onSelected or r.fg)
        end
    end

    --- Replace every row. `items` is an array of { key, text, fg }.
    --- A selection that no longer exists is dropped, so a stale pick can never act on
    --- the wrong device after a refresh.
    function self.set(items)
        items = items or {}
        for _, r in ipairs(rows) do r.button:destroy() end
        rows = {}

        local stillThere = false
        for i, item in ipairs(items) do
            local key = item.key
            local btn = scroll:addButton({
                x = 1, y = i, width = rowW, height = 1,
                text = fitRow(item.text),
                background = colors.black,
                foreground = item.fg or colors.white,
            })
            btn:onClick(function()
                selectedKey = key
                paint()
                if tapHandler then tapHandler(key) end
            end)
            rows[#rows + 1] = { key = key, button = btn, fg = item.fg or colors.white }
            if key == selectedKey then stillThere = true end
        end
        if not stillThere then selectedKey = nil end

        empty:setVisible(#items == 0)
        scroll:setVisible(#items > 0)
        paint()
    end

    --- The selected row's key, or nil.
    function self.selected() return selectedKey end

    --- Select a row by key (e.g. preselecting a form's current value). Ignores keys that
    --- aren't present, so a stale value can't select something else by accident.
    function self.select(key)
        for _, r in ipairs(rows) do
            if r.key == key then selectedKey = key; paint(); return true end
        end
        return false
    end

    --- Clear any selection (e.g. after the action was carried out).
    function self.clearSelection()
        selectedKey = nil
        paint()
    end

    --- Act on a tap, not just select. Used where a row IS the action (the pocket's panel);
    --- lists that use a separate action button simply don't set this.
    function self.onTap(fn) tapHandler = fn end

    --- Test seam: pretend row `i` was tapped, exactly as its Button's handler does.
    function self.clickRow(i)
        local r = rows[i]
        if not r then return false end
        selectedKey = r.key
        paint()
        if tapHandler then tapHandler(r.key) end
        return true
    end

    function self.count() return #rows end

    self.frame = frame
    return self
end

return RowList
