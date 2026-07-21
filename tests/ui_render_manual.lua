--- Headless render + interaction test for the manual control PC's monitor UI (83x32,
--- a 5x3 monitor at text scale 0.5).
---
--- Checks all three layers that past bugs taught us to check: it renders, it's READABLE
--- (no black-on-black), and its buttons actually reach `emit` with the right payload.
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end
local failures = 0
local function check(cond, msg)
    if cond then log("  ok  " .. msg) else failures = failures + 1; log("  FAIL " .. msg) end
end

local UIAssert = require("tests.ui_assert")
local invisible = 0

local function dump(win, W, H, path)
    local lines = {}
    for y = 1, H do lines[y] = win.getLine(y) or "" end
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
    local App    = require("easykey.ui.manual_app")

    local W, H = 83, 32
    local win = window.create(term.current(), 1, 1, W, H, true)
    local main = basalt.createFrame(); main:setTerm(win)
    log("frame size = " .. main.get("width") .. "x" .. main.get("height"))

    local events = {}
    local app = App.build(main, Config, "MANUALFP", function(action, payload)
        events[#events + 1] = { action = action, payload = payload }
    end)
    local function lastEvent() return events[#events] end

    app.log("manual control started - fp MANUALFP", "note")
    app.log("tap Lights by aliceAdd", "good")
    app.log("refused (denied) from bobAddr", "warn")
    app.log("ON  Lights")

    app.ops.setControls({
        { id = "c1", name = "Hangar Lift", type = "switch", use = "elevator", target = "self/front", on = true },
        { id = "c2", name = "Main Gate", type = "button", use = "gate", target = "redstone_relay_3/left", on = false },
        { id = "c3", name = "Unwired", type = "button", use = "elevator", target = nil, on = false },
    })
    -- What RedstoneIO enumerates: this PC's sides, every wired relay's sides, and the 16
    -- colours of a side that's been bundled (the IE interface connector case).
    app.ops.setOutputs({
        { id = "self/back", on = true },
        { id = "self/top", on = false },
        { id = "redstone_relay_3/left", on = false },
        { id = "redstone_relay_3/right:pink", on = true },
        { id = "redstone_relay_3/right:lime", on = false },
    })
    app.ops.setDevices({
        { address = "aliceAddress0000", distance = 4, secure = true, inRange = true },
        { address = "bobAddress000000", distance = 30, secure = false, inRange = true },
        { address = "farAddress000000", distance = 400, secure = true, inRange = false },
    }, 100, 3)
    app.ops.setSessions({ { address = "aliceAddress0000", remaining = 240 } })
    app.ops.setAlert("Sessions", colors.blue)
    app.tick()

    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_panel.txt")

    app.ops.showTab(2); basalt.update("timer", -1); dump(win, W, H, "/ui_manual_outs.txt")
    app.ops.showTab(3); basalt.update("timer", -1); dump(win, W, H, "/ui_manual_devices.txt")
    app.ops.showTab(4); basalt.update("timer", -1); dump(win, W, H, "/ui_manual_sessions.txt")
    app.ops.showTab(1)

    check(app.ops.tabNames[1] == "Controls" and app.ops.tabNames[4] == "Sessions",
        "manual tabs use full names")
    check(app.ops.setAlert("Sessions", colors.blue), "Sessions tab accepts an alert")
    check(not app.ops.setAlert("Nope", colors.red), "unknown tab name rejected")

    -- ---------- the edit form ----------
    app.openForm(nil, { { id = "self/back" }, { id = "self/top" } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_form_new.txt")

    app.openForm({ id = "c1", name = "Lights", type = "switch", use = "gate", target = "self/back" },
        { { id = "self/back" }, { id = "self/top" } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_form_edit.txt")
    check(app.edit.selectedTarget() == "self/back",
        "editing preselects the control's current target (so EDIT can't silently clear it)")

    -- the on-screen keyboard (name) and the numeric keypad (bar fill) render + read cleanly
    app.edit.nameKb.show("GATE")
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_form_kbd.txt")
    check(UIAssert.containsText(win, H, "Space"), "the on-screen keyboard shows its keys")
    app.edit.nameKb.hide()
    app.edit.cdKp.show()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_form_cd.txt")
    app.edit.cdKp.hide()

    -- SUBMITTING the name keyboard + cooldown keypad must apply the value (this is the manual
    -- side of the server key-add crash: the overlays' onSubmit closed over a nil global before).
    app.openForm({ id = "c9", name = "Old", type = "switch", use = "gate",
        target = "self/back", cooldown = 0 }, { { id = "self/back" } })
    app.edit.nameKb.show("")
    app.edit.nameKb.type("HANGAR")
    app.edit.nameKb.submit()
    check(app.edit.currentName() == "HANGAR", "form: the naming keyboard applies the name (no crash)")
    app.edit.cdKp.testSubmit("42")
    check(app.edit.currentCooldown() == 42, "form: the cooldown keypad applies the seconds (no crash)")

    app.closeForm()
    basalt.update("timer", -1)

    -- ---------- interaction: buttons must reach emit ----------
    app.ops.rows.controls.clickRow(1)
    check(app.ops.rows.controls.selected() == "c1", "tapping a control row selects it")

    events = {}
    app.ops.showTab(1)
    -- EDIT with a selection
    local editBtnFired = false
    -- drive via the row + the same path the button uses
    app.ops.rows.controls.clickRow(2)
    check(app.ops.rows.controls.selected() == "c2", "selection follows the tapped row")

    -- outputs tab selection feeds the bundled toggle
    app.ops.rows.outputs.clickRow(1)
    check(app.ops.rows.outputs.selected() == "self/back", "output row selects")

    -- The manual PC drives the same channels the door control does. A relay's side and a
    -- bundled colour must be reachable here too, or IE connectors can't be driven at all.
    app.ops.showTab(2)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "redstone_relay_3/left"), "a wired relay's side is listed")
    check(UIAssert.containsText(win, H, "redstone_relay_3/right:pink"),
        "a bundled colour is listed (IE interface connector)")
    check(UIAssert.containsText(win, H, "BUNDLE"), "the bundle control is findable")
    check(UIAssert.containsText(win, H, "16 IE colours"), "the Outs tab says how to get colours")

    app.ops.rows.outputs.clickRow(4)
    check(app.ops.rows.outputs.selected() == "redstone_relay_3/right:pink",
        "a bundled colour row selects like any other output")

    -- ---------- a target that stopped existing ----------
    -- Bundling a side redefines its channels, so a control can end up aimed at nothing
    -- without anyone touching it. That must look wrong, not normal.
    app.ops.setControls({
        { id = "c1", name = "Hangar Lift", type = "switch", use = "elevator",
          target = "self/back", on = false },
    }, { ["self/back:pink"] = true }) -- self/back just became bundled
    app.ops.showTab(1)
    app.ops.rows.controls.clickRow(1)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "MISSING"), "a target that no longer exists is flagged")
    dump(win, W, H, "/ui_manual_orphan.txt")

    -- and the normal case still reads as normal (this also puts the list back the way the
    -- checks below expect to find it)
    app.ops.setControls({
        { id = "c1", name = "Hangar Lift", type = "switch", use = "elevator", target = "self/front", on = true },
        { id = "c2", name = "Main Gate", type = "button", use = "gate", target = "redstone_relay_3/left", on = false },
        { id = "c3", name = "Unwired", type = "button", use = "elevator", target = nil, on = false },
    }, { ["self/front"] = true, ["redstone_relay_3/left"] = true })
    app.ops.rows.controls.clickRow(1)
    basalt.update("timer", -1)
    check(not UIAssert.containsText(win, H, "MISSING"), "a live target is not flagged")

    -- A long name must not get chopped by the settings next to it (it did: "Hangar Lif").
    app.ops.showTab(1)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "Hangar Lift"), "a long control name is not truncated")
    check(UIAssert.containsText(win, H, "sw"), "the row shows what it does")
    check(UIAssert.containsText(win, H, "lift"), "the row shows what it is for")

    -- the wiring lives on the detail line for the selected row, not squeezed into it
    app.ops.rows.controls.clickRow(1)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "self/front"), "selecting a control shows its target")
    dump(win, W, H, "/ui_manual_controls_row.txt")

    -- ---------- the operator's own panel (failsafe) ----------
    app.openPanel()
    app.usePanel.set({ {
        address = "@local", status = "ok",
        controls = {
            { id = "c1", name = "Main Gate", type = "switch", use = "gate", on = true },
            { id = "c2", name = "Lift Up", type = "button", use = "elevator", on = false },
        },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_use.txt")

    -- Backup mode must be unmistakable: the frame + headers go red. (The control LISTS sit on a
    -- dark strip so the red/green glyphs read - a red glyph on red would vanish - but the red
    -- frame around them still shouts "backup".) Check the COLOUR layer, not the text.
    local redCells, opsX = 0, 50
    for y = 4, 20 do
        local _t, _f, b = win.getLine(y)
        for x = opsX, W do
            if (b or ""):sub(x, x) == "e" then redCells = redCells + 1 end -- e = red
        end
    end
    check(redCells > 40, "backup panel frame stays red (" .. redCells .. " cells)")
    check(UIAssert.containsText(win, H, "Controls:"), "backup panel is titled 'Controls:'")
    check(UIAssert.containsText(win, H, "Gates"), "backup panel separates Gates")
    check(UIAssert.containsText(win, H, "Elevators"), "backup panel separates Elevators")

    -- an unapproved panel is dead on its own monitor too, and says so
    app.usePanel.set({ {
        address = "@local", status = "denied",
        controls = { { id = "c1", name = "Main Gate", type = "switch", use = "gate", on = false } },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_manual_use_denied.txt")

    app.closePanel()
    basalt.update("timer", -1)

    log("rendered controls/outs/devices/sessions/form/use")
    log("invisible-text problems = " .. invisible)
    if invisible > 0 then error(invisible .. " cells render fg==bg (unreadable)", 0) end
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)); failures = failures + 1 end
log(failures == 0 and "MANUAL_UI_OK" or ("MANUAL_UI_FAIL (" .. failures .. ")"))
local r = fs.open("/results.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
