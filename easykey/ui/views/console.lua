--- Raw server console: a scrollable, timestamped log of what the server actually DID.
---
--- Deliberately event-driven, not a status mirror. Periodic housekeeping (the secure-set
--- push every few seconds, the clock tick) is invisible here — if it appeared, real
--- events would scroll away within seconds and the log would be useless for working out
--- what happened. Only things worth reading later get a line: devices appearing,
--- approvals, key attempts, sessions starting/ending, keys changing, errors.
---
--- Backed by a Basalt List, so scrolling and the scroll bar come for free; it auto-sticks
--- to the newest line unless you've scrolled up to read something.
local Palette = require("easykey.ui.palette")

local Console = {}

--- Severity -> colour comes from the shared palette, so a red line in the log means
--- the same thing as a red tab or a red control.
local LEVEL_COLOR = Palette.level

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param opts table|nil { max = number, fingerprint = string }
---   `fingerprint` puts an "ID = ..." label in the bottom-left footer row (for pairing).
function Console.build(parent, region, opts)
    opts = opts or {}
    local maxLines = opts.max or 200
    local fingerprint = opts.fingerprint

    parent:addLabel({ x = region.x, y = region.y, text = "CONSOLE",
        foreground = Palette.accent, background = Palette.bg })

    -- header (1) + list (h-2) + footer (1): the footer holds the device ID and the clear
    -- buttons, so the list stops one row above the very bottom.
    local list = parent:addList({
        x = region.x, y = region.y + 1,
        width = region.w, height = region.h - 2,
        background = Palette.bg,
        -- Set foreground EXPLICITLY. A List's foreground does not default to white the
        -- way you'd expect (it resolved to black here), and items that don't carry
        -- their own colour fall back to it -> black-on-black, i.e. invisible.
        foreground = Palette.dim,
        emptyText = "(no activity yet)",
        showScrollBar = true,
        scrollBarColor = colors.gray,
        scrollBarBackgroundColor = colors.black,
    })

    local self = { list = list }
    local stuckToBottom = true

    --- Add a line. `level` is one of LEVEL_COLOR's keys (default "info").
    function self.log(text, level)
        local stamp = os.date("%H:%M:%S")
        -- NB: the List renders per-item colours from `fg`/`bg`. `foreground`/
        -- `background` are silently ignored on an item.
        list:addItem({
            text = stamp .. " " .. tostring(text),
            fg = LEVEL_COLOR[level or "info"] or Palette.dim,
            bg = Palette.bg,
        })
        -- cap the scrollback so a long-running server can't grow without bound
        local items = list.get("items")
        while #items > maxLines do list:removeItem(1) end
        if stuckToBottom then
            pcall(function() list:scrollToBottom() end)
        end
    end

    --- Follow the newest line again (after the user scrolled up).
    function self.follow()
        stuckToBottom = true
        pcall(function() list:scrollToBottom() end)
    end

    --- Wipe the whole log.
    function self.clear()
        while #list.get("items") > 0 do list:removeItem(1) end
    end

    --- Wipe everything EXCEPT the red error lines, so a fault you still need to see survives
    --- a tidy-up. "Red" is exactly the error colour (Palette.error / LEVEL_COLOR.bad).
    function self.clearExceptErrors()
        local kept = {}
        for _, it in ipairs(list.get("items")) do
            if it.fg == LEVEL_COLOR.bad then
                kept[#kept + 1] = { text = it.text, fg = it.fg, bg = it.bg }
            end
        end
        while #list.get("items") > 0 do list:removeItem(1) end
        for _, it in ipairs(kept) do list:addItem(it) end
        if stuckToBottom then pcall(function() list:scrollToBottom() end) end
    end

    -- ---------- footer: device ID (left) + clear buttons (right) ----------
    local footerY = region.y + region.h - 1
    parent:addLabel({
        x = region.x, y = footerY,
        text = "ID = " .. tostring(fingerprint or "?"),
        foreground = colors.lime, background = Palette.bg,
    })
    local B1, B2 = "Clear all", "Clear non-err" -- full wipe / wipe all but the red errors
    local right = region.x + region.w - 1
    local b2x = math.max(region.x, right - #B2 + 1)
    local b1x = math.max(region.x, b2x - 1 - #B1)
    parent:addButton({
        x = b1x, y = footerY, width = #B1, height = 1,
        text = B1, background = Palette.bar, foreground = Palette.text,
    }):onClick(function() self.clear() end)
    parent:addButton({
        x = b2x, y = footerY, width = #B2, height = 1,
        text = B2, background = Palette.bar, foreground = Palette.text,
    }):onClick(function() self.clearExceptErrors() end)

    return self
end

return Console
