--- Headless smoke test for the pocket UI. Builds the app on an off-screen 26x20
--- window (advanced pocket size), drives the status states + opens the keypad,
--- and dumps the character grid for each so the layout can be inspected on the
--- host. Asserts nothing errors. Run via tests/run_ui_pocket.sh.
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end

local UIAssert = require("tests.ui_assert")
local invisible = 0

--- Dump the text layer AND check the colour layer (see tests/ui_assert.lua: text-only
--- dumps can't tell readable UI from black-on-black).
local function dump(win, W, H, path)
    local lines = {}
    for y = 1, H do
        local text = win.getLine(y)
        lines[y] = text or ""
    end
    local f = fs.open(path, "w"); f.writeLine(table.concat(lines, "\n")); f.close()

    local ok, problems = UIAssert.noInvisibleText(win, W, H)
    if not ok then
        invisible = invisible + #problems
        log("INVISIBLE TEXT in " .. path .. ": " .. UIAssert.describe(problems))
    end
end

local ok, err = pcall(function()
    local basalt = require("basalt")
    local Config = require("easykey.config")
    local App    = require("easykey.pocket.app")

    local W, H = 26, 20
    local win = window.create(term.current(), 1, 1, W, H, true)
    local main = basalt.createFrame()
    main:setTerm(win)
    log("frame size = " .. main.get("width") .. "x" .. main.get("height"))

    local emitted = {}
    local app = App.build(main, Config, function(action, payload)
        emitted[#emitted + 1] = { action = action, payload = payload }
    end)

    -- pairing: searching, then candidates to fingerprint-check
    app.showPairing()
    app.pairing.setSearching()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_pair_search.txt")

    app.pairing.setCandidates({
        { address = "CMcFDWV73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", distance = 3 },
        { address = "ZZtestZZ73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", distance = 41 },
    })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_pair_pick.txt")

    -- locked screen
    app.showMain()
    app.status.setLocked("")
    app.tickClock()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_locked.txt")

    -- secure screen (countdown)
    app.status.setSecure(295)
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_secure.txt")

    -- denied message
    app.status.setDenied("wrong key")
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_denied.txt")

    -- keypad overlay
    app.showKeypad()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_keypad.txt")

    -- ---------- PANEL tab ----------
    -- Every state here is reported BY a manual PC. The pocket renders what it's told and
    -- nothing else, so these four renders are the whole contract.
    app.showMain()
    app.showTab(2)

    -- usable: a switch that's on, a button idle
    app.setPanels({ {
        address = "manualAddr1", status = "ok",
        controls = {
            { id = "c1", name = "Lights", type = "switch", use = "gate", on = true },      -- open -> red
            { id = "c2", name = "Door Bell", type = "button", use = "gate", fired = true }, -- confirm circle lit
            { id = "c3", name = "Latch", type = "latch", use = "gate", on = false, cooldown = 8 },
        },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_panel_ok.txt")

    -- cleared but the redstone disagreed with the manual PC -> signal error
    app.setPanels({ {
        address = "manualAddr1", status = "ok",
        controls = { { id = "c1", name = "Lights", type = "switch", use = "gate", on = false, err = true } },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_panel_err.txt")

    -- in range, not cleared by the server
    app.setPanels({ {
        address = "manualAddr1", status = "denied",
        controls = { { id = "c1", name = "Lights", type = "switch", use = "gate", on = false } },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_panel_denied.txt")

    -- too far away
    app.setPanels({ {
        address = "manualAddr1", status = "out_of_range",
        controls = { { id = "c1", name = "Lights", type = "switch", use = "gate", on = false } },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_panel_far.txt")

    -- THE contract: a tap ASKS, it never acts. It must emit panel_tap and leave the
    -- control exactly as the manual PC last reported it, so a control that didn't
    -- actually fire never looks like it did.
    app.setPanels({ {
        address = "manualAddr1", status = "ok",
        controls = { { id = "c1", name = "Lights", type = "switch", use = "gate", on = false } },
    } })
    app.showTab(2)
    basalt.update("timer", -1)
    local rowsBefore = win.getLine(2)

    emitted = {}
    if not app.controls.clickRow(1) then error("no switch to tap on the Controls tab", 0) end
    basalt.update("timer", -1)

    local ev = emitted[1]
    if not (ev and ev.action == "panel_tap") then error("tapping a control did not emit panel_tap", 0) end
    if ev.payload.id ~= "c1" then error("panel_tap carried the wrong control id", 0) end
    if ev.payload.address ~= "manualAddr1" then error("panel_tap carried the wrong panel address", 0) end
    if win.getLine(2) ~= rowsBefore then
        error("the control MOVED on tap - the pocket must never update optimistically", 0)
    end
    log("tap emits panel_tap and does not move the control (no optimistic UI)")

    -- ---------- the tabs split by USE, not by type ----------
    -- A gate can be a momentary button and a lift a latching switch, so the tabs must
    -- sort on `use` and ignore `type` entirely.
    app.setPanels({ {
        address = "manualAddr1", status = "ok",
        controls = {
            { id = "s1", name = "Main Gate", type = "switch", use = "gate", on = false },
            { id = "b1", name = "Side Gate", type = "button", use = "gate", on = false },
            { id = "b2", name = "Lift Up",   type = "button", use = "elevator", on = false },
            { id = "s2", name = "Lift Hold", type = "switch", use = "elevator", on = false },
        },
    } })
    if app.controls.count() ~= 2 then
        error("Gates tab must show both gate controls regardless of type, got "
            .. app.controls.count(), 0)
    end
    if app.use.count() ~= 2 then
        error("Lifts tab must show both elevator controls regardless of type, got "
            .. app.use.count(), 0)
    end
    log("Gates/Lifts split by use, not by switch/button")

    app.showTab(2); basalt.update("timer", -1); dump(win, W, H, "/ui_pocket_tab_controls.txt")
    app.showTab(3); basalt.update("timer", -1); dump(win, W, H, "/ui_pocket_tab_use.txt")

    -- the knob only travels towards what the panel REPORTED, never ahead of it
    app.setPanels({ {
        address = "manualAddr1", status = "ok",
        controls = { { id = "s1", name = "Lights", type = "switch", use = "gate", on = true } },
    } })
    app.showTab(2)
    for _ = 1, 4 do app.animate() end -- let the knob finish crossing
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_switch_on.txt")

    -- ---------- cosmetic backgrounds (pocket-only) ----------
    -- Apply every style behind the (busy) secure screen; dump() runs the colour check, so a
    -- style that made any UI text unreadable (fg==bg) would trip the invisible-text counter.
    -- every style, incl. the LIGHT plain ones (white/lime/orange) — auto-contrast must keep the
    -- text readable, so dump()'s colour check would trip if a light bg swallowed any text.
    app.showMain(); app.status.setSecure(240)
    for _, id in ipairs({ "starlit", "deepsea", "orange", "blue", "lime", "gray", "white" }) do
        app.applyBackgroundById(id)
        basalt.update("timer", -1)
        dump(win, W, H, "/ui_pocket_bg_" .. id .. ".txt")
    end
    -- the picker menu opens and renders its swatches
    app.showBgMenu()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_pocket_bg_menu.txt")
    app.showMain()
    log("backgrounds: applied every style + opened the menu")

    log("dumped locked/secure/denied/keypad")
    log("invisible-text problems = " .. invisible)
    if invisible > 0 then error(invisible .. " cells render fg==bg (unreadable)", 0) end
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)) end
local r = fs.open("/results.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
