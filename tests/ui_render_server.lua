--- Headless render test for the server's monitor UI, at the size of a 5x3 advanced
--- monitor at text scale 0.5 (83x32 = 17*W-2 by 11*H-1). Builds the app, feeds it
--- realistic data, renders each tab, and dumps the character grid so the layout can be
--- inspected on the host. Asserts nothing errors.
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end

local UIAssert = require("tests.ui_assert")
local invisible = 0

--- Dump the text layer AND check the colour layer. The colour check is the point: a
--- text-only dump once showed a perfect console that was entirely invisible in-game.
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
    local App    = require("easykey.ui.server_app")

    local W, H = 83, 32 -- 5x3 monitor @ text scale 0.5
    local win = window.create(term.current(), 1, 1, W, H, true)
    local main = basalt.createFrame()
    main:setTerm(win)
    log("frame size = " .. main.get("width") .. "x" .. main.get("height"))

    local emitted = {}
    local app = App.build(main, Config, "CMcFDWV7", function(action, payload)
        emitted[#emitted + 1] = { action = action, payload = payload }
    end)

    -- realistic console traffic
    app.log("server started - fingerprint CMcFDWV7", "note")
    app.log("PENDING pocket ZZtestZZ - approve it", "warn")
    app.log("APPROVED pocket ZZtestZZ", "good")
    app.log("pocket online pocket-ZZtestZZ", "note")
    app.log("keypad opened by pocket-ZZtestZZ")
    app.log("WRONG key from pocket-ZZtestZZ", "bad")
    app.log("SECURE pocket-ZZtestZZ (michael) for 300s", "good")
    app.log("control online AABBCCDD", "note")
    app.log("session expired: pocket-ZZtestZZ", "warn")

    app.ops.setPending({
        { address = "ZZtestZZ73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", role = "pocket" },
        { address = "QQrstUUV73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", role = "control" },
    })
    app.ops.setKeys({ { id = "k1", label = "michael" }, { id = "k2", label = "guest" } })
    app.ops.setDevices(
        { { address = "ZZtestZZ73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", name = "pocket-ZZtest" } },
        { { address = "AABBCCDD73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", name = "control-AABBCC" } })
    app.ops.setSessions({
        { address = "ZZtestZZ73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA=", name = "pocket-ZZtest", remaining = 287 },
    })
    app.tick()

    basalt.update("timer", -1)
    dump(win, W, H, "/ui_server_pending.txt")

    -- each tab in turn
    local tabNames = { "pending", "keys", "devices", "sessions" }
    for i = 2, 4 do
        app.ops.showTab(i)
        basalt.update("timer", -1)
        dump(win, W, H, "/ui_server_" .. tabNames[i] .. ".txt")
    end

    -- keypad overlay: how a new key is entered (masked, never shown on the monitor).
    -- Same path the ADD KEY button takes.
    app.ops.openKeypad()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_server_keypad.txt")

    -- and closing it must bring the tabs back
    app.ops.closeKeypad()
    basalt.update("timer", -1)
    dump(win, W, H, "/ui_server_keypad_closed.txt")

    -- the console and lists must actually be readable, not just present
    if not UIAssert.containsText(win, H, "server started") then
        error("console text missing from screen", 0)
    end
    log("rendered all tabs + keypad")
    log("invisible-text problems = " .. invisible)
    if invisible > 0 then error(invisible .. " cells render fg==bg (unreadable)", 0) end
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)) end
local r = fs.open("/results.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
