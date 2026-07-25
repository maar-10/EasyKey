--- Cross-version compatibility: an OLD release's code against the CURRENT release's code.
---
--- This is the test behind the claim "only the server needs updating". Both trees are deployed
--- side by side (/old and /cur) and modules are loaded from each by switching package.path and
--- clearing package.loaded between requires — a reference already captured stays valid, so two
--- generations of the same module can be held at once.
---
--- What it has to establish, in both directions:
---   * things expected to WORK: an old pocket renders a NEW elevator's floors; an old manual is
---     still trusted by the new server; the wire version never moved, so nothing is rejected.
---   * things expected to BREAK: an old server cannot know the elevator roles exist, which is
---     precisely why the server is the one computer that must be updated.
---
--- A test that only proved the happy path would be worth much less: "the old server silently
--- treats an elevator controller as a pocket" is the failure a user would actually hit, and it
--- should be pinned down rather than discovered in-game.
local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end
local failures = 0
local function check(cond, msg)
    if cond then log("  ok  " .. msg) else failures = failures + 1; log("  FAIL " .. msg) end
end

local BASE_PATH = "/?.lua;/?/init.lua"

--- Load a module from one of the two trees, ignoring anything already cached.
local function loadFrom(tree, name)
    for k in pairs(package.loaded) do
        if k:match("^easykey") or k:match("^shared") then package.loaded[k] = nil end
    end
    package.path = ("/%s/?.lua;/%s/?/init.lua;%s"):format(tree, tree, BASE_PATH)
    return require(name)
end

local ok, err = pcall(function()
    log("=== cross-version compatibility ===")

    -- ---------- the wire version ----------
    local OldProto = loadFrom("old", "easykey.protocol")
    local oldVersion = OldProto.VERSION
    local oldRoles, oldTypes = OldProto.ROLES, OldProto.TYPES
    -- capture what we need BEFORE swapping trees; the table itself stays valid either way
    local oldHasElevator = oldRoles.ELEVATOR ~= nil
    local oldHasElevmon  = oldRoles.ELEVMON ~= nil
    local oldHasMonList  = oldTypes.MONITOR_LIST ~= nil
    local oldManualRole  = oldRoles.MANUAL
    local oldHelloManual = OldProto.hello(oldRoles.MANUAL)
    local oldPresence    = OldProto.presence()
    local oldPanelInput  = OldProto.panelInput("e1.f2")

    local NewProto = loadFrom("cur", "easykey.protocol")
    log(("  old protocol v%s / new protocol v%s"):format(tostring(oldVersion), tostring(NewProto.VERSION)))

    -- ---------- EXPECTED TO WORK ----------
    log("")
    log("EXPECTED TO WORK")
    check(oldVersion == NewProto.VERSION,
        "the wire version never moved, so no message is rejected for version skew")
    -- an old device's messages validate against the new protocol, and vice versa
    check(NewProto.validate(oldHelloManual), "an OLD manual's HELLO validates on the new code")
    check(NewProto.validate(oldPresence), "an OLD pocket's presence ping validates")
    check(NewProto.validate(oldPanelInput), "an OLD pocket's panel tap validates")
    check(OldProto.validate(NewProto.secureSet({})), "a NEW secure-set validates on OLD code")
    check(OldProto.validate(NewProto.panelList({})), "a NEW panel list validates on OLD code")
    check(OldProto.validate(NewProto.panelState("ok", {})), "a NEW panel state validates on OLD code")
    -- ...and a message type the old code has never heard of is simply ignored, not fatal
    check(OldProto.validate(NewProto.monitorList({ "m" })),
        "a NEW monitor-list message is still structurally valid to OLD code (it just ignores it)")
    check(oldManualRole == NewProto.ROLES.MANUAL, "the manual role string is unchanged")

    -- ---------- an OLD pocket renders a NEW elevator's floors ----------
    -- The load-bearing claim of the elevator design: the pocket needed no change. Prove it by
    -- feeding a CURRENT elevator controller's real published output into the OLD pocket's feed.
    local NewElevator = loadFrom("cur", "easykey.logic.elevator")
    local elev = NewElevator.new({ defaults = { range = 100, stale = 2, pressSeconds = 0.5 } })
    local lid = elev:add({ name = "Main" })
    local f1 = elev:addFloor(lid, { name = "Ground", call = "self/back", at = "self/left" })
    elev:addFloor(lid, { name = "F1", call = "self/top" })
    local published = elev:listForPocket()
    elev:setApproved(true)
    elev:onPresence("ALICE", 5)
    elev:setSecureSet({ { address = "ALICE", expiresAt = os.epoch("utc") + 60000 } })
    elev:observeFeedback({ ["self/left"] = true }, nil)
    local status, rows = elev:stateFor("ALICE")

    local OldFeed = loadFrom("old", "easykey.logic.panel_feed")
    local feed = OldFeed.new({ timeout = 3 })
    feed:onList("ELEVADDR", published)
    feed:onState("ELEVADDR", status, rows)
    local shown = feed:list()
    check(#shown == 1 and #shown[1].controls == 2,
        "an OLD pocket's feed accepts a NEW elevator's floor list")
    local lift = shown[1].controls[1]
    check(lift and lift.use == "elevator",
        "...and carries `use` through, so the floors land on its Lifts tab")
    check(lift and lift.type == "button", "...as buttons")
    check(lift and lift.name == "Main Ground", "...with the lift+floor name")
    check(shown[1].status == "ok", "...and the pocket is told it may use them")
    check(shown[1].controls[1].fired == true,
        "...and the cabin's floor lights up on the OLD pocket (fired came through)")

    -- ---------- an OLD manual panel is still trusted by the NEW server ----------
    -- The new server's own predicate, applied to the role string an old manual actually sends.
    -- (isControlRole lives inline in server.lua, so this mirrors it against the real constants.)
    local function newIsControlRole(r)
        return r == NewProto.ROLES.CONTROL or r == NewProto.ROLES.MANUAL or r == NewProto.ROLES.ELEVATOR
    end
    check(newIsControlRole(oldHelloManual.role),
        "the NEW server treats an OLD manual's announced role as a control")
    check(not newIsControlRole("pocket"), "...and still does not treat a pocket as one")

    -- ---------- EXPECTED TO BREAK ----------
    log("")
    log("EXPECTED TO BREAK (this is why the server must be updated)")
    check(not oldHasElevator,
        "an OLD release has no `elevator` role at all, so an old server cannot recognise one")
    check(not oldHasElevmon, "...nor `elevmon`")
    check(not oldHasMonList,
        "...and no MONITOR_LIST message, so it could never tell a controller which monitors to trust")
    -- What an old server would actually DO with an elevator: its isControlRole knew only
    -- control|manual, so an "elevator" hello falls through to the pocket branch — approved into
    -- the wrong store, never sent the secure-set, and therefore permanently unable to accept a
    -- floor call. Silent, and exactly the bug the server update prevents.
    local function oldIsControlRole(r)
        return r == oldRoles.CONTROL or r == oldRoles.MANUAL
    end
    check(not oldIsControlRole("elevator"),
        "an OLD server would NOT treat an elevator controller as a control")
    check(not oldIsControlRole("elevmon"), "...nor a shaft monitor")
    log("      => an old server files an elevator under 'pockets', never sends it the")
    log("         secure-set, and every floor call is refused. Hence: update the server.")

    -- ---------- config forward-compatibility ----------
    log("")
    log("CONFIG WRITTEN BY OLD CODE, READ BY NEW")
    -- An old manual wrote its panel with the old exportConfig; the new Panel must load it.
    local OldPanel = loadFrom("old", "easykey.logic.panel")
    local oldPanel = OldPanel.new({ defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 } })
    oldPanel:add({ name = "Gate", type = "switch", use = "gate", target = "self/back", fallback = "on" })
    oldPanel:add({ name = "Lift", type = "latch", use = "elevator", target = "self/top:pink", cooldown = 6 })
    local oldCfg = oldPanel:exportConfig()

    local NewPanel = loadFrom("cur", "easykey.logic.panel")
    local newPanel = NewPanel.new({ defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 } })
    newPanel:loadConfig(oldCfg)
    local rows2 = newPanel:snapshot()
    check(#rows2 == 2, "the NEW panel loads a config an OLD panel wrote (" .. #rows2 .. " controls)")
    local byName = {}
    for _, c in ipairs(rows2) do byName[c.name] = c end
    check(byName["Gate"] and byName["Gate"].fallback == "on", "the fallback carried across versions")
    check(byName["Lift"] and byName["Lift"].cooldown == 6, "the cooldown carried across versions")
    check(byName["Lift"] and byName["Lift"].target == "self/top:pink",
        "a bundled-colour target carried across versions")

    -- ...and the reverse, which is what makes a rollback survivable: new config, old reader.
    local newCfg = newPanel:exportConfig()
    local OldPanel2 = loadFrom("old", "easykey.logic.panel")
    local rb = OldPanel2.new({ defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 } })
    rb:loadConfig(newCfg)
    check(#rb:snapshot() == 2, "an OLD panel can still read a config the NEW panel wrote")
end)

if not ok then
    failures = failures + 1
    log("  FAIL compat threw: " .. tostring(err))
end

log("")
log(("RESULT compat %s (%d failures)"):format(failures == 0 and "OK" or "FAIL", failures))
local r = fs.open("/pc_result.txt", "w"); r.writeLine(table.concat(out, "\n")); r.close()
os.shutdown()
