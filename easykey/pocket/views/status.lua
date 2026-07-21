--- The pocket's EasyKey tab: your clearance, and how to ask for it.
---
--- Layout, top to bottom: the clearance state, the countdown, a little key animation, a
--- message line, and the Request clearance button.
---
--- The key animation earns its place: this is a tool you glance at, and a frozen screen
--- and a working-but-idle screen look identical otherwise. While you're locked the key
--- hunts back and forth; once you're cleared it settles into the lock and turns green. It
--- also proves the UI coroutine is alive — if the key stops, something is wrong even if
--- the text looks fine.
---
--- Uses Basalt's animation API (`element:animate():move(...)`) on a *Label*. Deliberately
--- not on anything clickable: moving interactive elements around is exactly where this
--- project has had hit-testing trouble.
local Palette = require("easykey.ui.palette")

local Status = {}

local function centre(label, text, w, y)
    label:setText(text):setX(math.max(1, math.floor((w - #text) / 2) + 1)):setY(y)
end

--- @param parent table Basalt frame
--- @param region table { x, y, w, h }
--- @param onRequest function() called when the request button is pressed
--- @param config table|nil system config (for session_seconds, so the bar knows its full)
function Status.build(parent, region, onRequest, config)
    local w, h = region.w, region.h
    local sessionSeconds = (config and config.session_seconds) or 300

    -- auto-contrast: on a LIGHT wallpaper the neutral greys/whites vanish, so we draw them dark.
    -- We change the CHARACTER colour, never its background. Semantic colours (red/green/yellow)
    -- keep their meaning.
    local light = false
    local function dimText()   return light and colors.black or Palette.dim end
    local function mutedText() return light and colors.black or Palette.muted end
    local panel = parent:addFrame({ x = region.x, y = region.y, width = w, height = h,
        background = Palette.bg })

    local state   = panel:addLabel({ x = 1, y = 2, text = "", background = Palette.bg })
    local count   = panel:addLabel({ x = 1, y = 4, text = "", background = Palette.bg })

    -- A slim bar under the countdown: the clock tells you the exact seconds, the bar tells
    -- you at a glance how much of the session is left. Not interactive (a ProgressBar has no
    -- click handler), so it stays clear of the hit-testing this project is careful about.
    local BAR_W = math.min(20, w - 6)
    local bar = panel:addProgressBar({
        x = math.floor((w - BAR_W) / 2) + 1, y = 6, width = BAR_W, height = 1,
        progress = 0, progressColor = Palette.okBg, background = Palette.muted,
        foreground = Palette.muted,
    })
    bar:setVisible(false)

    local message = panel:addLabel({ x = 1, y = 11, text = "", foreground = Palette.dim,
        background = Palette.bg })

    -- ---------- the key animation ----------
    -- A short, centred track: key hunts left<->right while locked, then sinks into the
    -- lock when cleared. The "sinking" is the shaft getting shorter (o--- becomes o-) as
    -- the key parks against the keyhole, which reads as the key going in.
    local KEY_LOCKED = "o---" -- head + 3 shaft (ASCII: \196 renders wrong in CC:T's font)
    local KEY_IN     = "o-"   -- head + 1 shaft: the rest is inside the lock
    local KEY_Y   = 8
    local LOCK_X  = math.floor(w / 2) + 3   -- lock sits just right of centre
    local LEFT_X  = LOCK_X - 8              -- half the old span: a tighter, calmer hunt
    local RIGHT_X = LOCK_X - #KEY_LOCKED    -- hunting stops with the key touching the lock
    local IN_X    = LOCK_X - #KEY_IN        -- inserted: only the head + a stub show

    local lock = panel:addLabel({
        x = LOCK_X, y = KEY_Y, text = "[|]",
        foreground = mutedText(), background = Palette.bg,
    })
    local key = panel:addLabel({
        x = LEFT_X, y = KEY_Y, text = KEY_LOCKED,
        foreground = Palette.error, background = Palette.bg,
    })

    local animating = false
    local goingRight = true

    --- Ping-pong the key along its track. Each leg re-arms the next on completion, so it
    --- loops for as long as the pocket is running.
    local function hunt()
        if not animating then return end
        local target = goingRight and RIGHT_X or LEFT_X
        local ok = pcall(function()
            key:animate()
                :move(target, KEY_Y, 1.1, "easeInOutQuad")
                :onComplete(function()
                    goingRight = not goingRight
                    hunt()
                end)
                :start()
        end)
        -- If the animation API ever misbehaves, the UI must still work: park the key.
        if not ok then animating = false; key:setX(LEFT_X) end
    end

    local function startHunting()
        if animating then return end
        animating = true
        hunt()
    end

    --- Cleared: stop hunting and sink the key into the keyhole. The shaft shortens and
    --- the head parks against the lock, so it reads as inserted rather than just parked.
    local function settle()
        animating = false
        pcall(function() key:stopAnimation() end)
        key:setText(KEY_IN)
        key:setX(IN_X)
        key:setForeground(Palette.ok)
        lock:setText("[/]"):setForeground(Palette.ok) -- turned
    end

    --- Back to hunting: the key comes out again (full shaft) and the lock re-closes.
    local function unsettle(colour)
        key:setText(KEY_LOCKED)
        key:setForeground(colour or Palette.error)
        lock:setText("[|]"):setForeground(mutedText())
        startHunting()
    end

    -- ---------- the request button ----------
    -- Smaller than the panel and centred: it's an action you take rarely, and the screen
    -- reads better when the button isn't shouting.
    local BTN_W = math.min(20, w - 4)
    local btn = panel:addButton({
        x = math.floor((w - BTN_W) / 2) + 1, y = h - 3, width = BTN_W, height = 3,
        text = "Request clearance",
        background = Palette.errorBg, foreground = Palette.onError,
    })
    btn:onClick(function() onRequest() end)

    --- The button stays put in every state and just re-labels itself. Hiding it made the
    --- screen jump around, and a button that's always in the same place is easier to hit
    --- without looking. While cleared it reads "Access granted!" and does nothing —
    --- run.lua ignores a request unless we're actually locked.
    local function askButton()
        btn:setText("Request clearance")
            :setBackground(Palette.errorBg):setForeground(Palette.onError):setVisible(true)
    end

    local self = {}

    local function bigState(text, colour)
        centre(state, text, w, 2)
        state:setForeground(colour)
    end

    --- Locked (idle) — button available.
    function self.setLocked(msg)
        bigState("* LOCKED *", Palette.error)
        count:setText("")
        bar:setVisible(false)
        centre(message, msg or "", w, 11)
        message:setForeground(dimText())
        askButton()
        unsettle(Palette.error)
    end

    --- Busy waiting on the server.
    function self.setBusy(msg)
        bigState("...", Palette.warn)
        count:setText("")
        bar:setVisible(false)
        centre(message, msg or "working...", w, 11)
        message:setForeground(Palette.warn)
        btn:setVisible(false)
        unsettle(Palette.warn)
    end

    --- Denied — reason shown, button available again.
    function self.setDenied(msg)
        bigState("DENIED", Palette.error)
        count:setText("")
        bar:setVisible(false)
        centre(message, msg or "", w, 11)
        message:setForeground(Palette.error)
        askButton()
        unsettle(Palette.error)
    end

    --- Cleared — countdown, key resting in the lock, button says so.
    function self.setSecure(remainingSeconds)
        bigState("# CLEARED #", Palette.ok)
        local mm = math.floor(remainingSeconds / 60)
        local ss = remainingSeconds % 60
        centre(count, ("%02d:%02d"):format(mm, ss), w, 4)
        count:setForeground(Palette.ok)
        bar:setProgress(math.max(0, math.min(100,
            math.floor(remainingSeconds / sessionSeconds * 100))))
        bar:setVisible(true)
        centre(message, "Cleared secure!", w, 11)
        message:setForeground(Palette.ok)
        btn:setText("Access granted!")
            :setBackground(Palette.normalBg):setForeground(Palette.onNormal):setVisible(true)
        settle()
    end

    --- Auto-contrast for a light background: draw the NEUTRAL text (the idle keyhole, the idle
    --- message) dark so it doesn't vanish, recolouring the CHARACTER, not its background. The
    --- keyhole is the one the user flagged: grey-on-white is invisible. Semantic colours (the
    --- red/green key, the clearance state) keep their meaning either way.
    function self.retheme(isLight)
        light = isLight and true or false
        -- the keyhole is only a neutral grey while LOCKED ("[|]"); cleared ("[/]") it's green
        if lock.get("text") == "[|]" then lock:setForeground(mutedText()) end
        -- the idle message is dim only in the LOCKED state; other states colour it semantically
        if state.get("text") == "* LOCKED *" then message:setForeground(dimText()) end
    end

    self.frame = panel
    self.key = key -- test seam
    return self
end

return Status
