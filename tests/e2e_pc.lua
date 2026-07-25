--- One simulated EasyKey computer, driven through a phase of the end-to-end matrix.
---
--- The point of this test is the mixed-version fleet: some computers installed from an OLD
--- release's self-extracting installer, some installed fresh by the Suite, all then brought up to
--- date by the Suite. What has to hold is that the operator's settings — keys, approved devices,
--- panel controls, redstone outputs, lift definitions — come out the other side intact and still
--- readable by the NEW code.
---
--- Configs are written with the REAL logic modules, not hand-rolled strings, so the round trip
--- exercises the actual exportConfig/loadConfig pair. A key is added through the real KeyStore and
--- re-verified afterwards: "the key you memorised still opens the door" is the only form of
--- config persistence that actually matters to a user.
---
--- Driven by files the harness writes:
---   /pc_role.txt    the role this computer is
---   /pc_phase.txt   "install" | "check" | "update" | "reverify"
---   /mirror.txt     base URL of the local release mirror
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end
local failures = 0
local function check(cond, msg)
    if cond then log("  ok  " .. msg) else failures = failures + 1; log("  FAIL " .. msg) end
end

local function readFile(p)
    if not fs.exists(p) or fs.isDir(p) then return nil end
    local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
end
local function writeFile(p, s)
    local d = fs.getDir(p)
    if d ~= "" and d ~= "/" and not fs.exists(d) then fs.makeDir(d) end
    local f = fs.open(p, "w"); f.write(s); f.close()
end

local ROLE  = (readFile("/pc_role.txt") or "?"):gsub("%s", "")
local PHASE = (readFile("/pc_phase.txt") or "?"):gsub("%s", "")
local MIRROR = (readFile("/mirror.txt") or ""):gsub("%s", "")

local function flush()
    local r = fs.open("/pc_result.txt", "w")
    r.writeLine(table.concat(out, "\n"))
    r.close()
end

log(("=== %s / %s ==="):format(ROLE, PHASE))

--- Run the Suite, capturing its output. `answers` feeds the role prompt (see suite_probe.lua for
--- why read() is stubbed rather than fed through the event queue).
local function runSuite(answers, ...)
    local args = { ... }
    local queue = {}
    for i, v in ipairs(answers or {}) do queue[i] = v end
    local native = term.current()
    local win = window.create(native, 1, 1, 80, 40, false)
    local realRead = _G.read
    _G.read = function()
        if #queue == 0 then error("unexpected prompt", 0) end
        return table.remove(queue, 1)
    end
    term.redirect(win)
    local ok, err = pcall(function() shell.run("/easykey_suite.lua", table.unpack(args)) end)
    term.redirect(native)
    _G.read = realRead
    local lines = {}
    for y = 1, 40 do local l = win.getLine(y); if l then lines[#lines + 1] = (l:gsub("%s+$", "")) end end
    return table.concat(lines, "\n"), ok, err
end

local function contains(h, n) return h:find(n, 1, true) ~= nil end

-- Fresh module state; the phases load the same module names from different trees over time.
local function fresh(name)
    package.loaded[name] = nil
    return require(name)
end

-- ---------------------------------------------------------------------------
-- per-role config: write it with the real logic, then prove it survived
-- ---------------------------------------------------------------------------
local SETUP = {}
local VERIFY = {}

-- ----- server: a real hashed key + real approvals -----
SETUP.server = function()
    local Config  = fresh("easykey.config")
    require("ccryptolib.random").initWithTiming() -- salts need it
    local KeyStore = fresh("easykey.keystore")
    local Devices  = fresh("easykey.devices")
    -- Iterations are dropped to keep the test quick; the stored shape is identical.
    local keys = KeyStore.load(Config.keysFile, nil, { iters = 32 })
    keys:add("9182", "e2e-operator")
    keys:add("4477", "e2e-spare")
    local pockets = Devices.load(Config.pocketsFile)
    pockets:approve("POCKET-ADDRESS-e2e-0000000000000000000000", "pocket-e2e")
    local controls = Devices.load(Config.controlsFile)
    controls:approve("MANUAL-ADDRESS-e2e-0000000000000000000000", "manual-e2e")
    controls:approve("ELEVATR-ADDRESS-e2e-000000000000000000000", "elevator-e2e")
    log("  set up: 2 keys, 1 pocket, 2 controls")
end
VERIFY.server = function()
    local Config = fresh("easykey.config")
    require("ccryptolib.random").initWithTiming()
    local KeyStore = fresh("easykey.keystore")
    local Devices  = fresh("easykey.devices")
    local keys = KeyStore.load(Config.keysFile, nil, { iters = 32 })
    check(keys:count() == 2, "both keys survived (" .. keys:count() .. ")")
    -- The one that matters: the key the operator memorised still verifies.
    local entry = keys:verify("9182")
    check(entry ~= nil, "the custom key still verifies after the update")
    check(entry and entry.label == "e2e-operator", "...with its label intact")
    check(keys:verify("0000") == nil, "a wrong key is still refused")
    local pockets = Devices.load(Config.pocketsFile)
    local controls = Devices.load(Config.controlsFile)
    check(pockets:isApproved("POCKET-ADDRESS-e2e-0000000000000000000000"),
        "the approved pocket is still approved")
    check(controls:count() == 2, "both approved controls survived (" .. controls:count() .. ")")
    -- New in the current release: monitors get their own store, and it must start EMPTY rather
    -- than inheriting anything.
    if Config.monitorsFile then
        local monitors = Devices.load(Config.monitorsFile)
        check(monitors:count() == 0, "the new monitor store starts empty")
    end
end

-- ----- manual: real panel controls -----
SETUP.manual = function()
    local Config  = fresh("easykey.config")
    local Panel   = fresh("easykey.logic.panel")
    local KVStore = fresh("shared.ui.kvstore")
    local panel = Panel.new({ defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 } })
    panel:add({ name = "Main Gate", type = "button", use = "gate", target = "self/back" })
    panel:add({ name = "Hangar", type = "switch", use = "gate", target = "self/top", fallback = "on" })
    panel:add({ name = "Cargo Lift", type = "latch", use = "elevator", target = "self/left:pink",
                invert = true, cooldown = 4 })
    local store = KVStore.load(Config.panelFile)
    for id, cfg in pairs(panel:exportConfig()) do store:set(id, cfg) end
    local settings = KVStore.load(Config.panelFile .. ".set")
    settings:set("range", 64); settings:set("grace", 5)
    KVStore.load(Config.sidesFile):set("self/left", { bundled = true })
    log("  set up: 3 panel controls, range 64, one bundled side")
end
VERIFY.manual = function()
    local Config  = fresh("easykey.config")
    local Panel   = fresh("easykey.logic.panel")
    local KVStore = fresh("shared.ui.kvstore")
    local panel = Panel.new({ defaults = { range = 100, graceSeconds = 3, pressSeconds = 0.5, stale = 2 } })
    panel:loadConfig(KVStore.load(Config.panelFile):all())
    local rows = panel:snapshot()
    check(#rows == 3, "all 3 controls survived (" .. #rows .. ")")
    local byName = {}
    for _, c in ipairs(rows) do byName[c.name] = c end
    check(byName["Main Gate"] and byName["Main Gate"].type == "button", "the button survived")
    check(byName["Hangar"] and byName["Hangar"].fallback == "on",
        "the switch kept its normally-open fallback")
    check(byName["Cargo Lift"] and byName["Cargo Lift"].type == "latch", "the latch survived")
    check(byName["Cargo Lift"] and byName["Cargo Lift"].target == "self/left:pink",
        "a bundled-colour target survived verbatim")
    check(byName["Cargo Lift"] and byName["Cargo Lift"].cooldown == 4, "its cooldown survived")
    check(byName["Cargo Lift"] and byName["Cargo Lift"].invert == true, "its invert survived")
    check(byName["Cargo Lift"] and byName["Cargo Lift"].use == "elevator",
        "which tab it shows on survived")
    local settings = KVStore.load(Config.panelFile .. ".set")
    check(tonumber(settings:get("range")) == 64, "the tuned range survived")
    check(tonumber(settings:get("grace")) == 5, "the tuned grace survived")
    local sides = KVStore.load(Config.sidesFile)
    check(sides:get("self/left") and sides:get("self/left").bundled == true, "the bundled side survived")
end

-- ----- control: real door outputs -----
SETUP.control = function()
    local Config  = fresh("easykey.config")
    local Outputs = fresh("easykey.logic.outputs")
    local KVStore = fresh("shared.ui.kvstore")
    local outs = Outputs.new({ defaults = { range = 4, stale = 2, pressSeconds = 0.5 } })
    outs:ensure("self/back", { device = "self", side = "back" })
    outs:ensure("self/front", { device = "self", side = "front" })
    outs:configure("self/back", { name = "Front Door", type = "toggle", range = 6 })
    outs:configure("self/front", { name = "Airlock", type = "press", range = 3 })
    local store = KVStore.load(Config.outputsFile)
    for _, o in ipairs(outs:snapshot()) do
        store:set(o.id, { name = o.name, type = o.type, range = o.range })
    end
    KVStore.load(Config.sidesFile):set("self/right", { bundled = true })
    log("  set up: 2 door outputs, one bundled side")
end
VERIFY.control = function()
    local Config  = fresh("easykey.config")
    local KVStore = fresh("shared.ui.kvstore")
    local store = KVStore.load(Config.outputsFile)
    local back, front = store:get("self/back"), store:get("self/front")
    check(back and back.name == "Front Door", "the door's name survived")
    check(back and back.type == "toggle" and back.range == 6, "its type + range survived")
    check(front and front.type == "press" and front.range == 3, "the second output survived")
    local sides = KVStore.load(Config.sidesFile)
    check(sides:get("self/right") and sides:get("self/right").bundled == true, "the bundled side survived")
end

-- ----- pocket: only cosmetic state, but it must not be trampled -----
SETUP.pocket = function()
    local Config = fresh("easykey.config")
    writeFile(Config.pocketBgFile, "starlit")
    log("  set up: wallpaper choice")
end
VERIFY.pocket = function()
    local Config = fresh("easykey.config")
    check(readFile(Config.pocketBgFile) == "starlit", "the chosen wallpaper survived")
end

-- ----- elevator: real lifts + floors, local AND monitor-side channels -----
SETUP.elevator = function()
    local Config   = fresh("easykey.config")
    local Elevator = fresh("easykey.logic.elevator")
    local KVStore  = fresh("shared.ui.kvstore")
    local elev = Elevator.new({ defaults = { range = 100, stale = 2, pressSeconds = 0.5 } })
    local lid = elev:add({ name = "Main", monitor = "ELEVMON-ADDRESS-e2e-00000000000000000000",
                           recall = 3, timeout = 40 })
    elev:addFloor(lid, { name = "Ground", call = "mon:self/back", at = "mon:self/left" })
    elev:addFloor(lid, { name = "F1", call = "self/top", at = "self/right" })
    elev:addFloor(lid, { name = "F2", call = "self/bottom:lime", at = nil })
    local lid2 = elev:add({ name = "Service", recall = 0, timeout = 15 })
    elev:addFloor(lid2, { name = "Down", call = "self/front" })
    local store = KVStore.load(Config.elevatorFile)
    for id, cfg in pairs(elev:exportConfig()) do store:set(id, cfg) end
    KVStore.load(Config.elevatorFile .. ".set"):set("range", 80)
    KVStore.load(Config.sidesFile):set("self/bottom", { bundled = true })
    log("  set up: 2 lifts, 4 floors, local + mon: channels")
end
VERIFY.elevator = function()
    local Config   = fresh("easykey.config")
    local Elevator = fresh("easykey.logic.elevator")
    local KVStore  = fresh("shared.ui.kvstore")
    local elev = Elevator.new({ defaults = { range = 100, stale = 2, pressSeconds = 0.5 } })
    elev:loadConfig(KVStore.load(Config.elevatorFile):all())
    local lifts = elev:snapshot()
    check(#lifts == 2, "both lifts survived (" .. #lifts .. ")")
    local byName = {}
    for _, l in ipairs(lifts) do byName[l.name] = l end
    check(byName["Main"] and byName["Main"].floors == 3, "Main kept its 3 floors")
    check(byName["Main"] and byName["Main"].monitor == "ELEVMON-ADDRESS-e2e-00000000000000000000",
        "Main kept its monitor address")
    check(byName["Main"] and byName["Main"].recall == 3 and byName["Main"].timeout == 40,
        "Main kept both timings")
    check(byName["Service"] and byName["Service"].monitor == nil, "Service still has no monitor")
    local floors = elev:floorRows(byName["Main"].id)
    check(#floors == 3 and floors[1].name == "Ground", "the floor order survived")
    check(floors[1].call == "mon:self/back", "a monitor-side call channel survived verbatim")
    check(floors[1].at == "mon:self/left", "...and its arrival channel")
    check(floors[3].call == "self/bottom:lime", "a bundled-colour channel survived")
    check(floors[3].at == nil, "a floor with no arrival input stayed that way")
    check(tonumber(KVStore.load(Config.elevatorFile .. ".set"):get("range")) == 80,
        "the tuned range survived")
    -- and the whole thing still publishes to a pocket
    check(#elev:listForPocket() == 4, "all 4 floors still publish as pocket buttons")
end

-- ----- elevmon: bundled sides only -----
SETUP.elevmon = function()
    local Config = fresh("easykey.config")
    local KVStore = fresh("shared.ui.kvstore")
    KVStore.load(Config.sidesFile):set("self/back", { bundled = true })
    KVStore.load(Config.sidesFile):set("self/top", { bundled = true })
    log("  set up: 2 bundled sides")
end
VERIFY.elevmon = function()
    local Config = fresh("easykey.config")
    local KVStore = fresh("shared.ui.kvstore")
    local sides = KVStore.load(Config.sidesFile)
    check(sides:get("self/back") and sides:get("self/back").bundled == true, "first bundled side survived")
    check(sides:get("self/top") and sides:get("self/top").bundled == true, "second bundled side survived")
end

-- ---------------------------------------------------------------------------
-- shared: the device identity + pinned server must survive everything
-- ---------------------------------------------------------------------------
local function setupIdentity()
    -- A REAL ecnet2 identity, because it is the device's approval on the server: if an update
    -- replaced it the computer would have to be re-approved, which is the single worst thing an
    -- update could silently do.
    require("ccryptolib.random").initWithTiming()
    local Config = fresh("easykey.config")
    if not fs.exists(Config.identityPath) then
        require("ecnet2").Identity(Config.identityPath)
    end
    if not fs.exists(Config.serverFile) then
        local srv = require("ecnet2").Identity("/.e2e_fake_server")
        writeFile(Config.serverFile, srv.address)
    end
end

--- The device's address, as the server knows it.
---
--- `Config.identityPath` is a DIRECTORY, not a file: ecnet2 keeps address.txt, id.bin and
--- id.bin.bak inside it. Reading it as a file quietly yields nil, which made the first version of
--- this check compare nil to "" and "fail" for entirely the wrong reason. What actually matters is
--- the ADDRESS, because that is the string the server's approval is keyed on — if it changed, the
--- computer would need approving again by hand.
local function identityAddress(Config)
    return readFile(Config.identityPath .. "/address.txt")
end

--- Record the address + pinned server IMMEDIATELY before the Suite runs.
---
--- Snapshotting during install instead was wrong: booting a role legitimately rewrites parts of
--- the identity directory, so the comparison measured "did a boot happen" rather than "did the
--- update touch it". Taken here, the ONLY thing between snapshot and comparison is the Suite.
local function snapshotIdentity()
    local Config = fresh("easykey.config")
    writeFile("/e2e_identity_snapshot.txt", identityAddress(Config) or "")
    writeFile("/e2e_server_snapshot.txt", readFile(Config.serverFile) or "")
end

local function verifyIdentity()
    local Config = fresh("easykey.config")
    local now, before = identityAddress(Config), readFile("/e2e_identity_snapshot.txt")
    local same = (now ~= nil and now ~= "" and now == before)
    check(same, "the device address is unchanged (still approved on the server)")
    if not same then
        log(("      address was %q, is now %q"):format(tostring(before), tostring(now)))
    end
    check(readFile(Config.serverFile) == readFile("/e2e_server_snapshot.txt"),
        "the pinned server address is unchanged (no re-pairing)")
end

-- ---------------------------------------------------------------------------
-- boot: does the role actually start?
-- ---------------------------------------------------------------------------
local function bootRole()
    if periphemu then pcall(function() periphemu.create("back", "modem") end) end
    if ROLE == "server" or ROLE == "manual" or ROLE == "elevator" then
        pcall(function() periphemu.create("top", "monitor") end)
    end
    local bootErr = nil
    parallel.waitForAny(
        function()
            local ok, err = pcall(function()
                for name in pairs(package.loaded) do
                    if name:match("^easykey") or name:match("^shared") then package.loaded[name] = nil end
                end
                require("easykey.launch")(ROLE)
            end)
            if not ok then bootErr = tostring(err) end
        end,
        function() sleep(2.5) end
    )
    return bootErr
end

-- ---------------------------------------------------------------------------
-- phases
-- ---------------------------------------------------------------------------
local ok, err = pcall(function()
    if PHASE == "install" then
        -- The harness has already run whichever installer this PC gets (old installer or the
        -- Suite); here we only confirm it landed and then configure it like an operator would.
        check(fs.exists("/role.txt"), "role.txt exists")
        local raw = readFile("/role.txt") or ""
        check(raw:match(":%s*([%w_]+)") == ROLE, "role.txt says " .. ROLE .. " (got " .. raw .. ")")
        check(fs.exists("/easykey/launch.lua"), "the launcher is installed")
        check(fs.exists("/ecnet2/init.lua"), "the crypto libs are installed")
        local stamp = readFile("/easykey_version.txt")
        log("  version stamp: " .. tostring(stamp and stamp:gsub("\n", " ") or "NONE (old installer)"))
        setupIdentity()
        if SETUP[ROLE] then SETUP[ROLE]() end
        if VERIFY[ROLE] then VERIFY[ROLE]() end -- the config reads back with the code that wrote it
        local bootErr = bootRole()
        if bootErr then log("  boot error: " .. bootErr) end
        check(bootErr == nil, "the role boots on the version it was installed with")

    elseif PHASE == "check" then
        -- What does the Suite think of this computer BEFORE any update?
        local o = runSuite(nil, "--check")
        local n = tonumber(o:match("(%d+) file%(s%) to update")) or 0
        local upToDate = contains(o, "Already up to date")
        writeFile("/e2e_outdated.txt", tostring(n))
        log("  Suite reports: " .. (upToDate and "up to date" or (n .. " file(s) outdated")))
        local expectOutdated = (readFile("/pc_expect_outdated.txt") or ""):gsub("%s", "") == "yes"
        if expectOutdated then
            check(n > 0, "an OLD install is correctly seen as outdated (" .. n .. " files)")
        else
            check(upToDate and n == 0, "a Suite-installed computer is already up to date")
        end
        check(not contains(o, "1 file(s) updated"), "--check still wrote nothing")

    elseif PHASE == "update" then
        snapshotIdentity() -- the update is now the only thing between this and the reverify
        local o, sok = runSuite(nil)
        log("  " .. (o:match("([^\n]*file%(s%) updated[^\n]*)") or o:match("Already up to date") or "?"))
        check(sok, "the Suite ran without error")
        check(contains(o, "file(s) updated") or contains(o, "Already up to date"),
            "the Suite finished cleanly")
        local stamp = readFile("/easykey_version.txt") or ""
        check(stamp:match("version=(%w+)") ~= nil, "a version stamp was recorded")
        check(stamp:match("role=([%w_]+)") == ROLE, "the stamp names the right role")

    elseif PHASE == "reverify" then
        -- The whole point: after the update, is the operator's setup still there and still usable?
        verifyIdentity()
        if VERIFY[ROLE] then VERIFY[ROLE]() end
        local bootErr = bootRole()
        if bootErr then log("  boot error: " .. bootErr) end
        check(bootErr == nil, "the role still boots after the update")
        local o = runSuite(nil, "--check")
        check(contains(o, "Already up to date"), "and the Suite now reports it up to date")
        -- --verify is the deeper claim: every byte matches the release, not just the stamp
        local ov = runSuite(nil, "--verify", "--check")
        local verifyClean = contains(ov, "Already up to date")
        check(verifyClean, "--verify agrees: every file matches the release")
        if not verifyClean then
            -- Say WHICH files, or this failure is unactionable.
            for line in ov:gmatch("[^\n]+") do
                if line:match("^%s+%a+%s+%S") or line:match("file%(s%) to update") then
                    log("      " .. line:gsub("^%s+", ""))
                end
            end
        end
    else
        error("unknown phase: " .. PHASE, 0)
    end
end)

if not ok then
    failures = failures + 1
    log("  FAIL phase threw: " .. tostring(err))
end

log(("RESULT %s/%s %s (%d failures)"):format(ROLE, PHASE,
    failures == 0 and "OK" or "FAIL", failures))
flush()
os.shutdown()
