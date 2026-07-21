--- The server's operations panel: every manual job the operator has to do, as tabs.
---
---   Pending  - approve/reject devices that have paired but aren't trusted yet
---   Keys     - add a key on the keypad, or remove one
---   Devices  - see approved pockets/controls/panels, revoke a lost one
---   Sessions - see who's cleared right now, revoke a session immediately
---
--- Tabs light up when they want you: Pending goes yellow while a device waits, Sessions
--- goes blue while anyone is cleared. Colours mean the same thing here as everywhere
--- else in EasyKey (see easykey/ui/palette.lua).
---
--- Pattern throughout: pick a row, then press the action button. That beats typing
--- 44-character addresses, and taps are all a monitor really supports.
---
--- Built from plain Frames + Buttons rather than Basalt's TabControl/List. Both of those
--- mis-handle clicks here: a TabControl renders its children offset by the tab header but
--- hit-tests them without it, so everything inside a tab was a row out — the action
--- buttons (3 tall) absorbed the shift and worked, while 1-tall list rows never selected.
--- Frames/Buttons/ScrollFrames are the combination proven to work on monitors in-game, so
--- the tab strip and the row selection are both done here (see rowlist.lua).
---
--- The panel is pure UI: it never touches the vault or the network. Every action goes out
--- through `emit` and the server's own loop decides what to do.
local Keypad   = require("easykey.ui.keypad")
local Keyboard = require("easykey.ui.keyboard")
local RowList  = require("easykey.ui.views.rowlist")
local Palette  = require("easykey.ui.palette")

local Ops = {}

--- Shorten an address for display: the fingerprint is what humans compare anyway.
local function short(address)
    return tostring(address):sub(1, 8)
end

--- A tiny text bar for a list row: "[####--]". Drawn as characters inside the row's own
--- text (not a ProgressBar element on top), so RowList's click-to-select stays untouched.
local function miniBar(remaining, total, cells)
    local frac = (total and total > 0) and math.max(0, math.min(1, (remaining or 0) / total)) or 0
    local filled = math.floor(frac * cells + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep("-", cells - filled) .. "]"
end

--- @param parent table Basalt container
--- @param region table { x, y, w, h }
--- @param config table system config
--- @param emit function(action, payload)
function Ops.build(parent, region, config, emit)
    local w, h = region.w, region.h

    local root = parent:addFrame({
        x = region.x, y = region.y, width = w, height = h, background = colors.black,
    })

    -- ---------- tab strip ----------
    local TABS = { "Pending", "Keys", "Devices", "Sessions" }
    local tabW = math.floor(w / #TABS)
    local tabButtons, panels = {}, {}
    local activeTab = 1
    local alerts = {} -- tab index -> colour, or nil

    --- An inactive tab wearing its alert colour is how you notice there's work waiting
    --- without opening every tab. The active tab always reads as selected.
    local function paintTabs()
        for n = 1, #TABS do
            if n == activeTab then
                tabButtons[n]:setBackground(colors.white)
                tabButtons[n]:setForeground(colors.black)
            elseif alerts[n] then
                tabButtons[n]:setBackground(alerts[n])
                tabButtons[n]:setForeground(colors.black)
            else
                tabButtons[n]:setBackground(Palette.bar)
                tabButtons[n]:setForeground(Palette.text)
            end
        end
    end

    local function showTab(i)
        activeTab = i
        for n = 1, #TABS do panels[n]:setVisible(n == i) end
        paintTabs()
    end

    for i, name in ipairs(TABS) do
        tabButtons[i] = root:addButton({
            x = (i - 1) * tabW + 1, y = 1, width = tabW - 1, height = 1,
            text = name, background = Palette.bar, foreground = Palette.text,
        })
        tabButtons[i]:onClick(function() showTab(i) end)
    end

    -- Panels live below the strip. Everything inside is positioned relative to its own
    -- frame, so what you see is what gets hit.
    local panelY, panelH = 2, h - 1
    for i = 1, #TABS do
        panels[i] = root:addFrame({
            x = 1, y = panelY, width = w, height = panelH, background = colors.black,
        })
    end

    local listH = panelH - 3      -- leave room for the (now 2-tall) action buttons
    local btnY  = panelH - 1
    local self = {}

    --- Wire a button to "act on whatever is selected". If nothing is picked we say so:
    --- a button that silently does nothing is indistinguishable from a broken one.
    local function actOnSelection(rowlist, action, noun)
        return function()
            local key = rowlist.selected()
            if key then emit(action, key) else emit("need_selection", noun) end
        end
    end

    -- =================== Pend ===================
    local pend = RowList.build(panels[1], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "no devices waiting" })
    local approveSelected = actOnSelection(pend, "approve", "a device")
    local rejectSelected  = actOnSelection(pend, "reject", "a device")
    panels[1]:addButton({
        x = 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "APPROVE", background = Palette.okBg, foreground = Palette.onOk,
    }):onClick(approveSelected)
    panels[1]:addButton({
        x = math.floor(w / 2) + 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "REJECT", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(rejectSelected)

    --- @param list table array of { address, role }
    function self.setPending(list)
        local items = {}
        for _, d in ipairs(list or {}) do
            items[#items + 1] = {
                key = d.address,
                text = short(d.address) .. "  " .. tostring(d.role),
                fg = Palette.warn, -- pending: wants attention
            }
        end
        pend.set(items)
    end

    -- =================== Keys ===================
    local keys = RowList.build(panels[2], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "no keys set!" })
    local removeSelectedKey = actOnSelection(keys, "key_remove", "a key")
    local btnAddKey = panels[2]:addButton({
        x = 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "ADD KEY", background = Palette.normalBg, foreground = Palette.onNormal,
    })
    panels[2]:addButton({
        x = math.floor(w / 2) + 1, y = btnY, width = math.floor(w / 2) - 1, height = 2,
        text = "REMOVE", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(removeSelectedKey)

    -- Adding a key is two steps: the (masked) keypad for the secret value, then the on-screen
    -- keyboard to NAME it. The name is just an operator label — never secret, never sent to a
    -- device — so it's entered in the clear on the alphabet keyboard.
    local pendingKeyValue = nil
    local keyName = Keyboard.build(parent, { x = region.x, y = region.y, w = w, h = h }, {
        title = "Name this key:", maxLen = 16,
        onSubmit = function(label)
            emit("key_add", { value = pendingKeyValue, label = label })
            pendingKeyValue = nil
            self.closeKeypad()
        end,
        onCancel = function() pendingKeyValue = nil; self.closeKeypad() end,
    })
    -- Keypad overlay for a new key: full panel, so the digits are big enough to tap, and
    -- masked so a key is never shown on a monitor anyone can walk past.
    local keypad -- forward-declared: its own onSubmit closes over it
    keypad = Keypad.build(parent, { x = region.x, y = region.y, w = w, h = h }, config, {
        title = "New key:",
        onSubmit = function(value)
            pendingKeyValue = value
            keypad.hide()
            keyName.show() -- step 2: give it a name
        end,
        onCancel = function() self.closeKeypad() end,
    })
    function self.openKeypad()
        root:setVisible(false)
        keypad.show()
    end
    function self.closeKeypad()
        keypad.hide(); keyName.hide()
        root:setVisible(true)
    end
    btnAddKey:onClick(function() self.openKeypad() end)
    self.keypad, self.keyName = keypad, keyName -- test seams

    --- @param list table array of { id, label }
    function self.setKeys(list)
        local items = {}
        for _, k in ipairs(list or {}) do
            items[#items + 1] = { key = k.id, text = tostring(k.label), fg = Palette.text }
        end
        keys.set(items)
    end

    -- =================== Devs ===================
    local devs = RowList.build(panels[3], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "no approved devices" })
    local revokeSelectedDevice = actOnSelection(devs, "revoke_device", "a device")
    panels[3]:addButton({
        x = 1, y = btnY, width = w - 1, height = 2,
        text = "REVOKE DEVICE", background = Palette.errorBg, foreground = Palette.onError,
    }):onClick(revokeSelectedDevice)

    --- @param pockets table array of { address, name }
    --- @param controls table array of { address, name }
    function self.setDevices(pockets, controls)
        local items = {}
        for _, d in ipairs(pockets or {}) do
            items[#items + 1] = {
                key = d.address,
                text = "P " .. short(d.address) .. " " .. tostring(d.name),
                fg = Palette.ok,
            }
        end
        for _, d in ipairs(controls or {}) do
            items[#items + 1] = {
                key = d.address,
                text = "C " .. short(d.address) .. " " .. tostring(d.name),
                fg = Palette.normal, -- control/panel: running normally
            }
        end
        devs.set(items)
    end

    -- =================== Live ===================
    local live = RowList.build(panels[4], { x = 1, y = 1, w = w, h = listH },
        { emptyText = "nobody is secure" })
    local revokeSelectedSession = actOnSelection(live, "revoke_session", "a session")
    panels[4]:addButton({
        x = 1, y = btnY, width = w - 1, height = 2,
        text = "REVOKE SESSION", background = Palette.warnBg, foreground = Palette.onWarn,
    }):onClick(revokeSelectedSession)

    --- @param list table array of { address, name, remaining }
    local sessionTotal = (config and config.session_seconds) or 300
    function self.setSessions(list)
        local items = {}
        for _, s in ipairs(list or {}) do
            items[#items + 1] = {
                key = s.address,
                text = ("%-8s %s %3ds"):format(
                    tostring(s.name):sub(1, 8), miniBar(s.remaining, sessionTotal, 6), s.remaining),
                fg = Palette.ok,
            }
        end
        live.set(items)
    end

    showTab(1)

    --- Light a tab up (or clear it) so work waiting is visible without hunting.
    --- @param name string one of TABS, e.g. "Pending" / "Sessions"
    --- @param colour number|nil colour, or nil for no alert
    function self.setAlert(name, colour)
        for i, n in ipairs(TABS) do
            if n == name then
                alerts[i] = colour
                paintTabs()
                return true
            end
        end
        return false
    end

    self.showTab = showTab
    self.tabNames = TABS
    self.rows = { pending = pend, keys = keys, devices = devs, sessions = live }
    -- Exposed for tests: the exact functions the buttons call, so a test drives the real
    -- selection -> emit path rather than a lookalike.
    self.actions = {
        approve = approveSelected,
        reject = rejectSelected,
        key_remove = removeSelectedKey,
        revoke_device = revokeSelectedDevice,
        revoke_session = revokeSelectedSession,
    }
    return self
end

return Ops
