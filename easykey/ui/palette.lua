--- The one place EasyKey decides what a colour MEANS.
---
--- Every screen (server, manual panel, pocket) imports this, so a colour means the same
--- thing wherever you see it. Glancing at any EasyKey screen should tell you the state
--- without reading a word:
---
---   red     - error / refused / broken. Something is wrong.
---   yellow  - warning / pending. Something wants your attention.
---   green   - operational. It is doing its job right now (secure, energised, approved).
---   blue    - running normally. Healthy and idle; nothing to do.
---
--- Neutral greys carry no meaning: they are structure and labels.
---
--- Why the fg/bg split: CC's `blue` and `green` are dark, and dark-on-black is unreadable
--- even though it technically passes the "fg ~= bg" check our render tests make. So text
--- uses the bright variants (lightBlue / lime) and BUTTON BACKGROUNDS use the dark ones,
--- with light text on top. Same meaning, readable in both places.
local Palette = {}

-- ---------- meaning: text/foreground ----------
Palette.error  = colors.red        -- error, refused, signal fault
Palette.warn   = colors.yellow     -- warning, pending approval, needs attention
Palette.ok     = colors.lime       -- operational: secure, energised, approved
Palette.normal = colors.lightBlue  -- running normally, healthy, idle

-- ---------- meaning: button/tab backgrounds (paired with `on...` text) ----------
Palette.errorBg  = colors.red
Palette.warnBg   = colors.yellow
Palette.okBg     = colors.green
Palette.normalBg = colors.blue

--- Text colour to place on top of each background above.
Palette.onError  = colors.white
Palette.onWarn   = colors.black    -- yellow is bright: black reads best on it
Palette.onOk     = colors.white
Palette.onNormal = colors.white

-- ---------- structure (no meaning attached) ----------
Palette.bg       = colors.black
Palette.text     = colors.white
Palette.dim      = colors.lightGray -- secondary text
Palette.muted    = colors.gray      -- disabled / inactive
Palette.bar      = colors.gray      -- top bar, tab strip
Palette.accent   = colors.cyan      -- headings / identity
Palette.selected = colors.blue      -- the selected row
Palette.onSelected = colors.white

--- Console severity -> colour. Keeps the log speaking the same language as the tabs.
Palette.level = {
    info = Palette.dim,
    good = Palette.ok,
    warn = Palette.warn,
    bad  = Palette.error,
    note = Palette.normal,
}

--- The colour a tab should flash to when it wants attention, or nil for none.
--- Used so you can see there's something to do without opening every tab.
Palette.alert = {
    pending = Palette.warnBg,   -- devices waiting for approval
    active  = Palette.normalBg, -- sessions running normally
}

return Palette
