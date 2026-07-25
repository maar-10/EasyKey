--- Headless render + interaction test for the elevator controller's monitor UI (83x32, a 5x3
--- monitor at text scale 0.5).
---
--- Checks all three layers that past bugs taught us to check: it renders, it's READABLE (no
--- black-on-black), and its buttons actually reach `emit` with the right payload. The third
--- one matters most here — this screen is almost entirely buttons acting on a selection, and a
--- render test cannot see a dead button.
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
    local basalt   = require("basalt")
    local Config   = require("easykey.config")
    local App      = require("easykey.ui.elevator_app")
    local Elevator = require("easykey.logic.elevator")

    local W, H = 83, 32
    local win = window.create(term.current(), 1, 1, W, H, true)
    local main = basalt.createFrame(); main:setTerm(win)
    log("frame size = " .. main.get("width") .. "x" .. main.get("height"))

    local events = {}
    local app = App.build(main, Config, "ELEVATFP", function(action, payload)
        events[#events + 1] = { action = action, payload = payload }
    end)
    local function lastEvent() return events[#events] end
    local MON = "monitorAddress0000000000000000000000000000000"

    app.log("elevator control started - fp ELEVATFP", "note")
    app.log("attaching to monitor monitorA", "note")
    app.log("Main arrived at F1", "good")
    app.log("Tower: no arrival reported for F3", "warn")

    -- ---------- the Lifts tab ----------
    app.ops.setLifts({
        { id = "e1", name = "Main Lift", monitor = MON, floors = 3, at = "F1",
          recall = 2, timeout = 20 },
        { id = "e2", name = "Tower", monitor = nil, floors = 4, at = nil, calling = "F3",
          recall = 2, timeout = 30 },
        { id = "e3", name = "Broken", monitor = nil, floors = 1, needsMonitor = true },
    })
    app.ops.setOutputs({
        { id = "self/back", input = false, output = true },
        { id = "self/left", input = true, output = false },
        { id = "redstone_relay_3/left", input = false, output = false },
        { id = "redstone_relay_3/right:pink", input = true, output = false },
        { id = "redstone_relay_3/right:lime", input = false, output = false },
    })
    app.ops.setDevices({
        { address = "aliceAddress0000", distance = 4, secure = true, inRange = true },
        { address = "bobAddress000000", distance = 30, secure = false, inRange = true },
        { address = "farAddress000000", distance = 400, secure = true, inRange = false },
    }, { { address = "aliceAddress0000", remaining = 240 } }, 100)
    app.ops.setAlert("Devices", colors.blue)
    app.tick()

    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_lifts.txt")

    check(app.ops.tabNames[1] == "Lifts" and app.ops.tabNames[2] == "Floors",
        "elevator tabs use full names")
    check(app.ops.setAlert("Devices", colors.blue), "Devices tab accepts an alert")
    check(not app.ops.setAlert("Nope", colors.red), "unknown tab name rejected")
    check(UIAssert.containsText(win, H, "Main Lift"), "a long lift name is not truncated")
    check(UIAssert.containsText(win, H, "3fl"), "the row says how many floors it has")
    check(UIAssert.containsText(win, H, "F1"), "the row says where the cabin is")

    -- selecting a lift shows its detail line AND tells the program (the Floors tab needs it)
    events = {}
    app.ops.rows.lifts.clickRow(1)
    check(app.ops.rows.lifts.selected() == "e1", "tapping a lift row selects it")
    check(lastEvent() and lastEvent().action == "select_lift" and lastEvent().payload == "e1",
        "selecting a lift emits select_lift (so the Floors tab follows)")
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "mon monitorA"), "the detail line shows its monitor")
    check(UIAssert.containsText(win, H, "at F1"), "the detail line shows the cabin position")
    dump(win, W, H, "/ui_elev_lifts_row.txt")

    app.ops.rows.lifts.clickRow(2)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "no monitor"),
        "a lift with no monitor says so rather than looking configured")
    check(UIAssert.containsText(win, H, "-> F3"), "an outstanding call shows on the detail line")

    -- ---------- the Floors tab ----------
    app.ops.showTab(2)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "pick a lift"),
        "the Floors tab explains itself before a lift is chosen")
    dump(win, W, H, "/ui_elev_floors_empty.txt")

    app.ops.setFloors("Main Lift", {
        { id = "f1", name = "Ground", call = "mon:self/back", at = "mon:self/left",
          isAt = false, isCalling = false },
        { id = "f2", name = "Floor 1", call = "self/top", at = "self/right",
          isAt = true, isCalling = false },
        { id = "f3", name = "Floor 2", call = "self/back:pink", at = nil,
          isAt = false, isCalling = true, callMissing = true },
        { id = "f4", name = "Roof", call = nil, at = nil },
    })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_floors.txt")
    check(UIAssert.containsText(win, H, "Floors of Main Lift"), "the Floors tab names its lift")
    check(UIAssert.containsText(win, H, "Ground"), "a floor is listed")
    check(UIAssert.containsText(win, H, "mon"), "a monitor-side channel is marked 'mon'")
    check(UIAssert.containsText(win, H, "loc"), "a local channel is marked 'loc'")
    check(UIAssert.containsText(win, H, "MOVE UP") and UIAssert.containsText(win, H, "MOVE DOWN"),
        "floors can be reordered from the panel")

    -- A channel that stopped existing must look wrong, not normal. Bundling a side redefines
    -- its channels and a revoked monitor takes its channels away; either way the floor is a
    -- button that cannot do anything.
    app.ops.rows.floors.clickRow(3)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "MISSING"), "a call channel that no longer exists is flagged")
    dump(win, W, H, "/ui_elev_floors_missing.txt")

    app.ops.rows.floors.clickRow(4)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "NO CALL OUTPUT"), "a floor with no call output is flagged")

    app.ops.rows.floors.clickRow(1)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "mon:self/back"),
        "selecting a floor shows its real call channel")
    check(UIAssert.containsText(win, H, "mon:self/left"),
        "...and its real arrival channel")

    -- ---------- interaction: the buttons must reach emit with the selection ----------
    events = {}
    app.ops.showTab(1)
    app.ops.rows.lifts.clickRow(1)
    events = {}
    -- Drive the row selection, then assert the emitted actions carry it. (Real clicks on
    -- Basalt buttons cannot be simulated headless — basalt.update("mouse_click",...) does not
    -- route to a window-backed frame — so tests drive the same seams the handlers use.)
    check(app.ops.selectedLift() == "e1", "the program can read which lift is selected")
    check(app.ops.selectLift("e2"), "the program can preselect a lift (after NEW)")
    check(app.ops.selectedLift() == "e2", "...and it takes")
    check(not app.ops.selectLift("nosuch"), "preselecting a lift that isn't listed is refused")

    app.ops.showTab(2)
    app.ops.rows.floors.clickRow(2)
    check(app.ops.selectedFloor() == "f2", "the program can read which floor is selected")

    -- ---------- the Outs tab: both directions on one row ----------
    app.ops.showTab(3)
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_outs.txt")
    check(UIAssert.containsText(win, H, "redstone_relay_3/left"), "a wired relay's side is listed")
    check(UIAssert.containsText(win, H, "redstone_relay_3/right:pink"),
        "a bundled colour is listed (IE interface connector)")
    check(UIAssert.containsText(win, H, "BUNDLE"), "the bundle control is findable")
    check(UIAssert.containsText(win, H, "I=arrival in"), "the Outs tab explains its two columns")
    app.ops.rows.outputs.clickRow(4)
    check(app.ops.rows.outputs.selected() == "redstone_relay_3/right:pink",
        "a bundled colour row selects like any other channel")

    -- ---------- the Devices tab ----------
    app.ops.showTab(4)
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_devices.txt")
    check(UIAssert.containsText(win, H, "CLEARED"), "a cleared pocket is marked")
    check(UIAssert.containsText(win, H, "denied"), "an uncleared pocket is marked")
    check(UIAssert.containsText(win, H, "far"), "an out-of-range pocket is marked")
    check(UIAssert.containsText(win, H, "1 cleared"), "the session count is shown")
    check(UIAssert.containsText(win, H, "range 100"), "the range setting is shown")

    -- nobody cleared must read as a statement, not a blank
    app.ops.setDevices({}, {}, 100)
    basalt.update("timer", -1)
    check(UIAssert.containsText(win, H, "nobody is cleared"), "an empty session list says so")
    check(UIAssert.containsText(win, H, "no pockets seen"), "an empty device list says so")

    -- ---------- the lift form ----------
    app.openLiftForm(nil, { MON })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_lift_form_new.txt")
    check(UIAssert.containsText(win, H, "New lift"), "the new-lift form is titled")
    check(UIAssert.containsText(win, H, "Position monitor"), "the form offers a monitor")
    check(UIAssert.containsText(win, H, "no position feedback"),
        "picking no monitor says what it costs")

    app.openLiftForm({ id = "e1", name = "Main Lift", monitor = MON, recall = 3, timeout = 45 },
        { MON })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_lift_form_edit.txt")
    check(app.edit.currentMonitor() == MON,
        "editing preselects the lift's monitor (so EDIT can't silently clear it)")
    check(app.edit.currentRecall() == 3, "editing preselects the recall lock")
    check(app.edit.currentTimeout() == 45, "editing preselects the call timeout")
    check(UIAssert.containsText(win, H, "3s"), "the recall lock is shown")
    check(UIAssert.containsText(win, H, "45s"), "the call timeout is shown")

    -- A monitor the operator has since revoked must not silently look unconfigured.
    app.openLiftForm({ id = "e1", name = "Main Lift", monitor = MON, recall = 2, timeout = 20 }, {})
    basalt.update("timer", -1)
    check(app.edit.currentMonitor() == MON, "a revoked monitor keeps its address")
    check(UIAssert.containsText(win, H, "REVOKED"), "...and is shown as revoked")
    dump(win, W, H, "/ui_elev_lift_form_revoked.txt")

    -- SUBMITTING the overlays must apply the value. (This is the self-reference trap that once
    -- crashed the server's key-add: an overlay whose callback closes over ITSELF resolves to a
    -- nil global unless it was forward-declared.)
    app.openLiftForm({ id = "e9", name = "Old", monitor = nil, recall = 2, timeout = 20 }, { MON })
    app.edit.nameKb.show("")
    app.edit.nameKb.type("HANGAR")
    app.edit.nameKb.submit()
    check(app.edit.currentName() == "HANGAR", "lift form: the naming keyboard applies (no crash)")
    app.edit.recallKp.testSubmit("7")
    check(app.edit.currentRecall() == 7, "lift form: the recall keypad applies (no crash)")
    app.edit.timeoutKp.testSubmit("33")
    check(app.edit.currentTimeout() == 33, "lift form: the timeout keypad applies (no crash)")
    -- and it refuses nonsense rather than storing it
    app.edit.timeoutKp.testSubmit("0")
    check(app.edit.currentTimeout() == 33, "lift form: a timeout of 0 is refused")

    app.edit.nameKb.show("KB")
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_lift_form_kbd.txt")
    check(UIAssert.containsText(win, H, "Space"), "the on-screen keyboard shows its keys")
    app.edit.nameKb.hide()
    app.edit.recallKp.show()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_lift_form_kp.txt")
    app.edit.recallKp.hide()
    app.closeForm()
    basalt.update("timer", -1)

    -- ---------- the floor form ----------
    local CHANNELS = { "self/back", "self/top", "redstone_relay_3/left",
                       "mon:self/back", "mon:self/left", "mon:self/right:pink" }
    app.openFloorForm(nil, CHANNELS)
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_floor_form_new.txt")
    check(UIAssert.containsText(win, H, "New floor"), "the new-floor form is titled")
    check(UIAssert.containsText(win, H, "Call output"), "the form asks for a call output")
    check(UIAssert.containsText(win, H, "Arrival input"), "the form asks for an arrival input")
    check(UIAssert.containsText(win, H, "no arrival input"),
        "leaving the arrival input out says what it costs")

    app.openFloorForm({ id = "f1", name = "Ground", call = "mon:self/back", at = "self/right" },
        CHANNELS)
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_floor_form_edit.txt")
    check(app.floorEdit.currentCall() == "mon:self/back",
        "editing preselects the floor's call channel")
    -- "self/right" is NOT in CHANNELS: a channel can vanish under a floor (a side gets bundled,
    -- a monitor gets revoked), and EDIT must not silently blank it.
    check(app.floorEdit.currentAt() == "self/right",
        "editing keeps an arrival channel that no longer exists")

    app.floorEdit.nameKb.show("")
    app.floorEdit.nameKb.type("GROUND")
    app.floorEdit.nameKb.submit()
    check(app.floorEdit.currentName() == "GROUND",
        "floor form: the naming keyboard applies (no crash)")
    app.closeForm()
    basalt.update("timer", -1)

    -- ---------- the operator's own floor buttons (the failsafe) ----------
    app.openPanel()
    app.usePanel.set({ {
        address = "@local", status = "ok",
        controls = {
            { id = "e1.f1", name = "Main Ground", type = "button", use = "elevator",
              fired = false, cooldown = 0 },
            { id = "e1.f2", name = "Main Floor 1", type = "button", use = "elevator",
              fired = true, cooldown = 0 },
            { id = "e1.f3", name = "Main Floor 2", type = "button", use = "elevator",
              fired = false, cooldown = 2 },
        },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_use.txt")
    check(UIAssert.containsText(win, H, "Floors (backup)"), "backup mode is titled")
    check(UIAssert.containsText(win, H, "Main Floor 1"), "a floor button is rendered")

    -- Backup mode must be unmistakable: the frame goes red. (The button LIST sits on a dark
    -- strip so the green "cabin here" glyph reads — a coloured glyph on red would vanish — but
    -- the red frame around it still shouts "backup".) Check the COLOUR layer, not the text.
    local redCells, opsX = 0, 50
    for y = 4, 20 do
        local _t, _f, b = win.getLine(y)
        for x = opsX, W do
            if (b or ""):sub(x, x) == "e" then redCells = redCells + 1 end -- e = red
        end
    end
    check(redCells > 40, "backup panel frame stays red (" .. redCells .. " cells)")

    -- an unapproved controller is dead on its own monitor too, and says so
    app.usePanel.set({ {
        address = "@local", status = "denied",
        controls = { { id = "e1.f1", name = "Main Ground", type = "button", use = "elevator" } },
    } })
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_elev_use_denied.txt")
    check(UIAssert.containsText(win, H, "access denied"),
        "a revoked controller says so on its own panel")

    -- tapping a floor on the operator's own panel must reach emit (this is the failsafe; a
    -- dead button here is indistinguishable from a broken lift)
    app.usePanel.set({ {
        address = "@local", status = "ok",
        controls = { { id = "e1.f2", name = "Main Floor 1", type = "button", use = "elevator" } },
    } })
    events = {}
    check(app.useFloors.clickRow(1), "the operator's panel has a tappable floor")
    check(lastEvent() and lastEvent().action == "panel_tap"
        and lastEvent().payload.id == "e1.f2" and lastEvent().payload.address == "@local",
        "tapping it emits panel_tap for that floor")

    app.closePanel()
    basalt.update("timer", -1)

    -- ---------- what the pocket would actually be sent ----------
    -- The whole point of the design: the elevator publishes ORDINARY panel buttons, so the
    -- pocket renders lifts with no idea elevators exist. If this shape ever drifts, the pocket
    -- silently stops showing floors — and the pocket cannot be changed without a reinstall.
    local elev = Elevator.new({ defaults = { range = 100, stale = 2, pressSeconds = 0.5 } })
    local lid = elev:add({ name = "Main" })
    elev:addFloor(lid, { name = "G", call = "self/back" })
    local published = elev:listForPocket()
    check(#published == 1, "a floor is published to the pocket")
    check(published[1].type == "button" and published[1].use == "elevator",
        "...as a button on the pocket's Lifts tab")
    check(published[1].call == nil and published[1].at == nil,
        "...with the wiring stripped out")
    -- and the pocket's own view accepts it verbatim
    local PanelView = require("easykey.ui.views.panel_view")
    local probe = basalt.createFrame()
    local pv = PanelView.build(probe, { x = 1, y = 1, w = 26, h = 18 }, function() end,
        { filter = "elevator", emptyText = "no lifts nearby" })
    pv.set({ { address = "elevAddr", status = "ok", controls = published } })
    check(pv.count() == 1, "the pocket's Lifts view renders an elevator floor unchanged")

    log("rendered lifts/floors/outs/devices/forms/use")
    log("invisible-text problems = " .. invisible)
    if invisible > 0 then error(invisible .. " cells render fg==bg (unreadable)", 0) end
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)); failures = failures + 1 end
log(failures == 0 and "ELEVATOR_UI_OK" or ("ELEVATOR_UI_FAIL (" .. failures .. ")"))
local r = fs.open("/results.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
