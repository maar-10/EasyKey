--- Scenario test for easykey_suite.lua, driven against a REAL http server.
---
--- The updater is the one program whose whole job is touching other files, so the things worth
--- proving are all about restraint: that it leaves config alone, that a failed download changes
--- nothing at all, and that it warns before it costs you an edit. A unit test cannot show any of
--- that — it needs a real fs and a real http.get, which is why this runs in CraftOS against a
--- local mirror of the repo (tests/run_suite.sh serves it).
---
--- `/mirror_base.txt` is written by the harness with the localhost base URL.
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

local BASE = (readFile("/mirror_base.txt") or ""):gsub("%s+$", "")
log("mirror = " .. BASE)

--- Write whatever we have, whenever we stop. Without this a mid-probe error produced NO results
--- file at all, which reads identically to "the harness never started" and is miserable to debug.
local function flush(note)
    if note then log(note) end
    local r = fs.open("/results.txt", "w")
    r.writeLine(table.concat(out, "\n"))
    r.close()
end
--- Run the Suite, capturing everything it prints (its output IS its interface).
---
--- `typed` supplies the answers to the role prompt, one per read(). It is fed by STUBBING the
--- global `read` rather than queueing char events: http.get's own wait loop pulls every event and
--- discards the ones it doesn't recognise, so pre-queued keystrokes are swallowed by the manifest
--- fetch long before the prompt is reached. (That cost an afternoon of "why does this hang".)
---
--- The stub also catches the opposite bug: if the Suite asks for input the test did not expect,
--- it throws instead of blocking until the harness times out with no output at all.
local function runSuite(typed, ...)
    local args = { ... }
    local answers = {}
    for i, v in ipairs(typed or {}) do answers[i] = v end
    local asked = 0
    local captured = {}
    local nativeTerm = term.current()
    local w, h = term.getSize()
    local win = window.create(nativeTerm, 1, 1, math.max(w, 60), math.max(h, 40), false)

    local realRead = _G.read
    _G.read = function()
        asked = asked + 1
        if #answers == 0 then
            error("the Suite prompted for input " .. asked .. " time(s); the test supplied "
                .. #(typed or {}), 0)
        end
        return table.remove(answers, 1)
    end

    term.redirect(win)
    local ok, err = pcall(function() shell.run("/easykey_suite.lua", table.unpack(args)) end)
    term.redirect(nativeTerm)
    _G.read = realRead

    for y = 1, math.max(h, 40) do
        local line = win.getLine(y)
        if line then captured[#captured + 1] = (line:gsub("%s+$", "")) end
    end
    return table.concat(captured, "\n"), asked, ok, err
end

--- The common case: no prompt expected.
local function runUpdater(...) return runSuite(nil, ...) end

local function contains(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

local bodyOk, bodyErr = pcall(function()
    -- =====================================================================
    -- Scenario 0: nothing installed -> the Suite ASKS which role, then installs it
    -- =====================================================================
    log("")
    log("SCENARIO 0a  --check on a bare computer -> never blocks on a prompt")
    if fs.exists("/role.txt") then fs.delete("/role.txt") end
    -- --check has to be safe to run blind. Note NO keystrokes are queued: if it asked anyway it
    -- would hang here until the CraftOS timeout, and the whole probe would produce no results.
    local o0c, asked0c = runUpdater("--check")
    check(contains(o0c, "No EasyKey install found"), "says nothing is installed")
    check(contains(o0c, "not asking"), "--check declines to prompt")
    check(asked0c == 0, "--check never called read() at all")
    check(not fs.exists("/easykey"), "--check wrote nothing")

    log("")
    log("SCENARIO 0b  bare computer -> quitting the prompt installs nothing")
    local o0q = runSuite({ "q" })
    check(contains(o0q, "What should this computer be?"), "asks what the computer should be")
    check(contains(o0q, "1) pocket"), "offers every role, numbered")
    check(contains(o0q, "6) elevmon"), "...all six of them")
    check(contains(o0q, "ADVANCED POCKET"), "says what hardware each role needs")
    check(contains(o0q, "Nothing was installed"), "q backs out cleanly")
    check(not fs.exists("/easykey"), "...and really wrote nothing")

    log("")
    log("SCENARIO 0c  bare computer -> a bad answer is re-asked, then a name is accepted")
    -- "9" is out of range and "wat" is not a role; both must be rejected without giving up, and
    -- typing the NAME must work as well as the number.
    local o0n = runSuite({ "9", "wat", "elevmon" })
    check(contains(o0n, "Not one of the choices"), "rejects a bad answer")
    check(contains(o0n, "Installing elevmon"), "accepts a role typed by name")
    check(fs.exists("/easykey/elevmon.lua"), "installed the role it was told to")
    check(readFile("/role.txt") == "easykey:elevmon", "wrote role.txt for an interactive install")
    check(fs.exists("/easykey_version.txt"), "recorded the version")

    -- back to bare for the next scenario
    fs.delete("/easykey"); fs.delete("/role.txt"); fs.delete("/easykey_version.txt")
    if fs.exists("/ecnet2") then fs.delete("/ecnet2") end
    if fs.exists("/ccryptolib") then fs.delete("/ccryptolib") end
    if fs.exists("/shared") then fs.delete("/shared") end

    -- =====================================================================
    -- Scenario 1: fresh install by naming a role on the command line
    -- =====================================================================
    log("")
    log("SCENARIO 1  named role -> full fresh install, no prompt")
    local o1 = runUpdater("elevmon")
    check(not contains(o1, "What should this computer be?"), "a named role skips the prompt")
    check(contains(o1, "role elevmon"), "identifies the role")
    check(fs.exists("/easykey/elevmon.lua"), "installed the role's own program")
    check(fs.exists("/easykey/redstone_io.lua"), "installed its dependencies")
    check(fs.exists("/ecnet2/init.lua"), "installed the vendored crypto")
    check(readFile("/role.txt") == "easykey:elevmon", "wrote role.txt for a named role")
    check(fs.exists("/easykey_version.txt"), "recorded the installed version")
    local ver1 = (readFile("/easykey_version.txt") or ""):match("version=(%w+)")
    check(ver1 ~= nil and #ver1 > 0, "the version stamp has a version (" .. tostring(ver1) .. ")")
    check(not fs.exists("/basalt.lua"), "elevmon needs no Basalt, so none was fetched")
    -- A FRESH install has no config.lua to have hand-edited, so telling the operator to re-apply
    -- their edits is noise -- and noise is how a warning gets ignored the day it matters.
    check(not contains(o1, "Re-apply any hand-edits"),
        "a fresh install does not warn about hand-edits that cannot exist")
    -- staging files must never be left behind
    local leftovers = 0
    local function sweep(dir)
        for _, n in ipairs(fs.list(dir)) do
            local p = (dir == "/") and ("/" .. n) or (dir .. "/" .. n)
            if fs.isDir(p) then if p ~= "/rom" then sweep(p) end
            elseif p:sub(-6) == ".eknew" then leftovers = leftovers + 1 end
        end
    end
    sweep("/")
    check(leftovers == 0, "no .eknew staging files were left behind")

    -- =====================================================================
    -- Scenario 2: already up to date
    -- =====================================================================
    log("")
    log("SCENARIO 2  run again -> up to date, no work")
    local o2 = runUpdater()
    check(contains(o2, "Already up to date"), "reports up to date")
    check(contains(o2, "version matches"), "took the fast path (no re-checksumming)")

    -- =====================================================================
    -- Scenario 3: a stale file and a missing file are both repaired
    -- =====================================================================
    log("")
    log("SCENARIO 3  tampered + deleted file -> both restored")
    local goodBody = readFile("/easykey/redstone_io.lua")
    writeFile("/easykey/redstone_io.lua", "-- LOCAL TAMPERING\nreturn {}\n")
    fs.delete("/easykey/elevmon.lua")
    -- the version stamp still says "current", so only --verify can notice
    local o3check = runUpdater("--verify", "--check")
    check(contains(o3check, "changed") and contains(o3check, "missing"),
        "--verify spots both a changed and a missing file")
    check(contains(o3check, "nothing was written"), "--check writes nothing")
    check(readFile("/easykey/redstone_io.lua"):find("LOCAL TAMPERING", 1, true) ~= nil,
        "...and really did leave the tampered file alone")
    check(not fs.exists("/easykey/elevmon.lua"), "...and did not restore the deleted one")

    local o3 = runUpdater("--verify")
    check(readFile("/easykey/redstone_io.lua") == goodBody, "--verify restored the tampered file")
    check(fs.exists("/easykey/elevmon.lua"), "--verify restored the deleted file")
    check(contains(o3, "2 file(s) updated"), "reported exactly two files")

    -- =====================================================================
    -- Scenario 4: config files are never touched
    -- =====================================================================
    log("")
    log("SCENARIO 4  config + identity survive an update")
    local sentinels = {
        ["/.easykey_id"]              = "PRETEND-PRIVATE-KEY",
        ["/easykey_server.txt"]       = "PRETEND-PINNED-SERVER",
        ["/easykey_sides.cfg"]        = '{ ["self/back"] = { bundled = true } }',
        ["/easykey_elevators.cfg"]    = '{ e1 = { name = "Main" } }',
        ["/easykey_keys.cfg"]         = '{ k1 = { salt = "aa" } }',
        ["/easykey_bg.cfg"]           = "starlit",
    }
    for p, v in pairs(sentinels) do writeFile(p, v) end
    -- force a full update by wiping the version stamp
    fs.delete("/easykey_version.txt")
    fs.delete("/easykey/link.lua")
    local o4 = runUpdater()
    check(contains(o4, "1 file(s) updated"), "updated just the missing file")
    local kept = 0
    for p, v in pairs(sentinels) do
        if readFile(p) == v then kept = kept + 1 else log("      LOST: " .. p) end
    end
    check(kept == 6, "all 6 config/identity files untouched (" .. kept .. "/6)")

    -- =====================================================================
    -- Scenario 5: a hand-edited easykey/config.lua is backed up and announced
    -- =====================================================================
    log("")
    log("SCENARIO 5  hand-edited config.lua -> warned + backed up")
    local realCfg = readFile("/easykey/config.lua")
    writeFile("/easykey/config.lua", "-- MY HAND EDIT MARKER\n" .. realCfg)
    local o5 = runUpdater("--verify")
    check(contains(o5, "easykey/config.lua is being replaced"), "warns before replacing it")
    check(contains(o5, "Re-apply any hand-edits"), "tells you what to do about it")
    check(readFile("/easykey/config.lua") == realCfg, "the shipped version is now in place")
    -- and the edit is recoverable
    local foundBackup = false
    if fs.exists("/easykey_backup") then
        for _, stamp in ipairs(fs.list("/easykey_backup")) do
            local p = "/easykey_backup/" .. stamp .. "/easykey_config.lua"
            local b = readFile(p)
            if b and b:find("MY HAND EDIT MARKER", 1, true) then foundBackup = true end
        end
    end
    check(foundBackup, "the hand-edited copy is recoverable from the backup folder")

    -- =====================================================================
    -- Scenario 6: a corrupted download aborts WITHOUT touching the live tree
    -- =====================================================================
    log("")
    log("SCENARIO 6  corrupt download -> all-or-nothing abort")
    -- The harness serves a second mirror whose easykey/link.lua has been tampered with, so its
    -- bytes no longer match the manifest checksum. Nothing at all may be written.
    local corruptBase = (readFile("/mirror_corrupt.txt") or ""):gsub("%s+$", "")
    local beforeLink = readFile("/easykey/link.lua")
    local beforeUtil = readFile("/shared/util.lua")
    fs.delete("/easykey/link.lua")   -- so it is in the change set
    fs.delete("/shared/util.lua")    -- a second file, to prove the batch is atomic
    writeFile("/easykey_suite_src.txt", corruptBase)
    local o6, ok6 = runUpdater("--verify")
    writeFile("/easykey_suite_src.txt", BASE)
    check(contains(o6, "checksum mismatch"), "detects the tampered file")
    check(contains(o6, "NOTHING was changed"), "says nothing was changed")
    check(not fs.exists("/easykey/link.lua"), "the live tree was NOT half-written")
    check(not fs.exists("/shared/util.lua"), "...for any file in the batch")
    leftovers = 0; sweep("/")
    check(leftovers == 0, "and no .eknew staging files survive the abort")

    -- recover from a good mirror
    local o6b = runUpdater("--verify")
    check(readFile("/easykey/link.lua") == beforeLink, "a good mirror then restores it")
    check(readFile("/shared/util.lua") == beforeUtil, "...and the rest of the batch")

    -- =====================================================================
    -- Scenario 7: a config-schema bump backs up every saved setting
    -- =====================================================================
    log("")
    log("SCENARIO 7  schema bump -> every .cfg backed up, loudly")
    -- Pretend this computer was installed under an older config generation.
    writeFile("/easykey_version.txt", "version=oldversion\nschema=0\nrole=elevmon\n")
    writeFile("/easykey_sides.cfg", "SIDES-BEFORE-BUMP")
    writeFile("/easykey_elevators.cfg", "LIFTS-BEFORE-BUMP")
    fs.delete("/easykey/link.lua") -- give it something to do
    local o7 = runUpdater()
    check(contains(o7, "CHANGES THE CONFIG FORMAT"), "shouts about the schema change")
    check(contains(o7, "generation 0 -> 1"), "names both generations")
    check(contains(o7, "may need re-entering"), "says what it means for you")
    check(readFile("/easykey_sides.cfg") == "SIDES-BEFORE-BUMP", "the live config is still untouched")
    local bumpBackups = 0
    if fs.exists("/easykey_backup") then
        for _, stamp in ipairs(fs.list("/easykey_backup")) do
            for _, n in ipairs(fs.list("/easykey_backup/" .. stamp)) do
                local b = readFile("/easykey_backup/" .. stamp .. "/" .. n)
                if b == "SIDES-BEFORE-BUMP" or b == "LIFTS-BEFORE-BUMP" then
                    bumpBackups = bumpBackups + 1
                end
            end
        end
    end
    check(bumpBackups == 2, "both saved configs were copied aside (" .. bumpBackups .. "/2)")

    -- =====================================================================
    -- Scenario 8: switching role, and a Basalt role
    -- =====================================================================
    log("")
    log("SCENARIO 8  switch to a Basalt role")
    local o8 = runUpdater("elevator")
    check(contains(o8, "role.txt: elevmon -> elevator"), "announces the role change")
    check(readFile("/role.txt") == "easykey:elevator", "rewrote role.txt")
    check(fs.exists("/easykey/elevator.lua"), "installed the new role's program")
    check(fs.exists("/easykey/ui/views/elev_ops.lua"), "...and its UI")
    check(fs.exists("/basalt.lua"), "fetched Basalt for a UI role")
    check(contains(o8, "basalt.lua ("), "reported the Basalt download")
    check(readFile("/easykey_basalt_url.txt") ~= nil, "recorded which Basalt URL it used")
    -- elevmon's files are still around (nothing is deleted), but the ROLE is what matters
    check(fs.exists("/easykey/elevmon.lua"), "the old role's files are left in place")

    log("")
    log("SCENARIO 9  Basalt is not re-downloaded when the URL is unchanged")
    local basaltBefore = readFile("/basalt.lua")
    writeFile("/basalt.lua", basaltBefore .. "\n-- LOCAL MARKER\n")
    fs.delete("/easykey/link.lua")
    local o9 = runUpdater("--verify")
    check(not contains(o9, "fetching Basalt"), "did not re-fetch a 300KB file needlessly")
    check(readFile("/basalt.lua"):find("LOCAL MARKER", 1, true) ~= nil,
        "left the existing basalt.lua alone")

    -- =====================================================================
    -- Scenario 10: the checksum agrees with the generator
    -- =====================================================================
    log("")
    log("SCENARIO 10  Lua checksum agrees with the Node generator")
    -- The harness precomputed sums for known strings with tools/gen_installers.js's fnv1a.
    -- If these two implementations ever drift, every file looks permanently outdated.
    local vectors = textutils.unserialise(readFile("/fnv_vectors.txt") or "{}")
    local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261
    local function checksum(s)
        local h, n, i = FNV_OFFSET, #s, 1
        while i <= n do
            local j = i + 255; if j > n then j = n end
            local b = { string.byte(s, i, j) }
            for k = 1, #b do
                h = bit32.bxor(h, b[k])
                local lo = h % 65536
                local hi = (h - lo) / 65536
                h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
            end
            i = j + 1
        end
        return ("%08x"):format(h)
    end
    local agree = 0
    for _, v in ipairs(vectors or {}) do
        local got = checksum(v.text)
        if got == v.sum then agree = agree + 1
        else log("      MISMATCH on " .. #v.text .. " bytes: lua=" .. got .. " node=" .. v.sum) end
    end
    check(vectors and #vectors > 0, "got test vectors from the generator")
    check(agree == #(vectors or {}), ("all %d vectors agree"):format(#(vectors or {})))

    -- and the real manifest parses as data
    log("")
    log("SCENARIO 11  the manifest parses as data, comments and all")
    local mBody = nil
    do
        local h = http.get(BASE .. "/manifest.lua")
        if h then mBody = h.readAll(); h.close() end
    end
    local parsed = mBody and textutils.unserialise(mBody)
    check(type(parsed) == "table", "textutils.unserialise handles the leading comment block")
    check(parsed and type(parsed.roles) == "table" and parsed.roles.elevator ~= nil,
        "the parsed manifest has the roles in it")
    check(parsed and parsed.version ~= nil and parsed.schema ~= nil,
        "...and its version + schema")

    -- =====================================================================
    -- Scenario 12: the tree the updater produced actually BOOTS
    -- =====================================================================
    -- The point of the whole exercise. Every check above is about files being in the right state;
    -- this is the one that says the result is a working install. A manifest that shipped a role
    -- without one of its modules would pass all of the above and die on `require` here.
    log("")
    log("SCENARIO 12  the updated tree boots the role")
    -- role is `elevator` by now (scenario 8), which needs a modem and a pinned server to get past
    -- pairing -- same setup tests/boot_smoke.lua uses.
    --
    -- Scenario 4 planted a FAKE /.easykey_id to prove the updater leaves an identity alone. It did
    -- its job; it is not a real ecnet2 key, so ecnet2.Identity chokes on it. Clear it and let the
    -- role mint a real one, which is what a genuine first boot does anyway.
    if fs.exists("/.easykey_id") then fs.delete("/.easykey_id") end
    if periphemu then pcall(function() periphemu.create("back", "modem") end) end
    do
        local ok, Config = pcall(dofile, "/easykey/config.lua")
        if ok and Config and not fs.exists(Config.serverFile) then
            pcall(function()
                package.path = "/?.lua;/?/init.lua;" .. package.path
                require("ccryptolib.random").initWithTiming()
                local id = require("ecnet2").Identity("/.probe_server_id")
                writeFile(Config.serverFile, id.address)
            end)
        end
    end
    local bootErr = nil
    parallel.waitForAny(
        function()
            local ok, err = pcall(function()
                package.path = "/?.lua;/?/init.lua;" .. package.path
                local launch = require("easykey.launch")
                local raw = readFile("/role.txt") or ""
                local _, r = raw:match("^%s*([%w_]+)%s*:%s*([%w_]+)")
                launch(r) -- blocks in the role's event loop if healthy
            end)
            if not ok then bootErr = tostring(err) end
        end,
        function() sleep(2.5) end -- a healthy role never returns; this ends the run
    )
    if bootErr then log("      boot error: " .. bootErr) end
    check(bootErr == nil, "the role installed by the updater boots and runs its loop")


end)
if not bodyOk then
    failures = failures + 1
    log("")
    log("PROBE ERROR: " .. tostring(bodyErr))
end

log("")
log("failures = " .. failures)
log(failures == 0 and "SUITE_OK" or ("SUITE_FAIL (" .. failures .. ")"))
flush()
os.shutdown()
