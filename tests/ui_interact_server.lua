--- Interaction test for the server's operations panel.
---
--- Render tests proved the UI *looked* right while APPROVE did nothing at all: the
--- selection was tracked through `onSelect`, whose callback actually fires as
--- (self, index, item) — so the handler bound `item` to a number, errored on
--- `item.address`, and the selection stayed nil forever. Nothing rendered wrong; the
--- button was simply dead.
---
--- So this test drives the real path: put items in a list, select one the way a click
--- does, invoke the exact function the button calls, and assert the right action and
--- payload reach `emit`.
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end
local failures = 0
local function check(cond, msg)
    if cond then log("  ok  " .. msg) else failures = failures + 1; log("  FAIL " .. msg) end
end

local ok, err = pcall(function()
    local basalt = require("basalt")
    local Config = require("easykey.config")
    local App    = require("easykey.ui.server_app")

    local W, H = 83, 32
    local win = window.create(term.current(), 1, 1, W, H, true)
    local main = basalt.createFrame(); main:setTerm(win)

    local events = {}
    local app = App.build(main, Config, "TESTFPRT", function(action, payload)
        events[#events + 1] = { action = action, payload = payload }
    end)
    local function lastEvent() return events[#events] end

    local ADDR = "m6wlfbEA73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA="
    local CTRL = "AABBCCDD73LFlF0lLtrJfpkTMqlyQgLlvdRIa2qj2GTA="

    -- ---------- pressing a button with nothing selected ----------
    app.ops.setPending({ { address = ADDR, role = "pocket" } })
    app.ops.actions.approve()
    check(lastEvent() and lastEvent().action == "need_selection",
        "APPROVE with no selection reports need_selection (not silence)")

    -- ---------- tap the row, then approve: the exact flow that was broken ----------
    check(app.ops.rows.pending.count() == 1, "the pending row is in the list")
    check(app.ops.rows.pending.clickRow(1), "tapping row 1 is handled")
    check(app.ops.rows.pending.selected() == ADDR, "tapping a row selects that device")

    app.ops.actions.approve()
    check(lastEvent().action == "approve", "APPROVE emits 'approve'")
    check(lastEvent().payload == ADDR, "APPROVE emits the selected device's address")

    app.ops.actions.reject()
    check(lastEvent().action == "reject" and lastEvent().payload == ADDR, "REJECT emits the address")

    -- ---------- keys ----------
    app.ops.setKeys({ { id = "k1", label = "michael" }, { id = "k2", label = "guest" } })
    app.ops.actions.key_remove()
    check(lastEvent().action == "need_selection", "REMOVE with no key selected asks for one")
    app.ops.rows.keys.clickRow(2)
    app.ops.actions.key_remove()
    check(lastEvent().action == "key_remove" and lastEvent().payload == "k2",
        "REMOVE emits the selected key's id")

    -- ---------- devices ----------
    app.ops.setDevices({ { address = ADDR, name = "pocket-x" } }, { { address = CTRL, name = "ctrl-y" } })
    app.ops.rows.devices.clickRow(2) -- the control (listed after pockets)
    app.ops.actions.revoke_device()
    check(lastEvent().action == "revoke_device" and lastEvent().payload == CTRL,
        "REVOKE DEVICE emits the selected control's address")

    -- ---------- sessions ----------
    app.ops.setSessions({ { address = ADDR, name = "pocket-x", remaining = 250 } })
    app.ops.rows.sessions.clickRow(1)
    app.ops.actions.revoke_session()
    check(lastEvent().action == "revoke_session" and lastEvent().payload == ADDR,
        "REVOKE SESSION emits the selected session's address")

    -- ---------- refreshing a list must drop a stale selection ----------
    app.ops.setPending({}) -- device approved -> list refreshed empty
    app.ops.actions.approve()
    check(lastEvent().action == "need_selection",
        "after the list refreshes, the old selection is gone (no ghost approvals)")

    -- ---------- tabs: names + alerts ----------
    check(app.ops.tabNames[1] == "Pending" and app.ops.tabNames[4] == "Sessions",
        "tabs use full names")
    check(app.ops.setAlert("Pending", colors.yellow), "Pending tab accepts an alert")
    check(app.ops.setAlert("Sessions", colors.blue), "Sessions tab accepts an alert")
    check(not app.ops.setAlert("Nope", colors.red), "an unknown tab name is rejected")
    app.ops.setAlert("Pending", nil)

    -- ---------- tab switching must not break selection wiring ----------
    for i = 1, 4 do app.ops.showTab(i) end
    app.ops.showTab(1)
    app.ops.setPending({ { address = ADDR, role = "pocket" } })
    app.ops.rows.pending.clickRow(1)
    app.ops.actions.approve()
    check(lastEvent().action == "approve" and lastEvent().payload == ADDR,
        "selection still works after switching tabs")

    -- ---------- keypad add-key path ----------
    app.ops.openKeypad()
    basalt.update("timer", -1)
    app.ops.closeKeypad()
    basalt.update("timer", -1)
    log("keypad opened + closed cleanly")

    -- ---------- add-key: keypad (value) -> keyboard (name) -> emit (the crash regression) ----------
    -- The keypad's onSubmit used to index a nil GLOBAL `keypad` and crash the server. Drive
    -- the real chain: enter a value, which must hand off to the naming keyboard, then submit
    -- a name, and assert the emitted payload carries BOTH.
    app.ops.openKeypad()
    app.ops.keypad.testSubmit("2468")
    basalt.update("timer", -1)
    check(app.ops.keyName.frame.get("visible"), "entering the key value opens the naming keyboard")
    app.ops.keyName.type("BOSS")
    app.ops.keyName.submit()
    local e = lastEvent()
    check(e.action == "key_add" and type(e.payload) == "table"
        and e.payload.value == "2468" and e.payload.label == "BOSS",
        "add-key emits { value, label } from keypad + keyboard")
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)); failures = failures + 1 end
log(failures == 0 and "INTERACT_OK" or ("INTERACT_FAIL (" .. failures .. ")"))
local r = fs.open("/results.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
