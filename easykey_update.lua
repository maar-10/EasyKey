-- ===================================================================
-- EasyKey updater  --  one program, every role, straight from GitHub
--
--   wget run https://raw.githubusercontent.com/maar-10/EasyKey/main/easykey_update.lua
--
-- Unlike the install_easykey_*.lua files, this carries no payload. It works out which role this
-- computer is running, asks GitHub what the current release contains, and fetches only the files
-- that actually differ. Your configuration is never touched.
--
--   easykey_update.lua              update whatever role is installed here
--   easykey_update.lua --check      say what WOULD change; write nothing
--   easykey_update.lua --verify     re-check every file's checksum (repairs local corruption)
--   easykey_update.lua <role>       install/switch to a role (pocket|server|control|manual|
--                                   elevator|elevmon) -- this one DOES rewrite role.txt
--
-- Three properties worth knowing about, because they are why this is safer than re-running an
-- installer:
--
--   * ALL-OR-NOTHING. Every replacement is downloaded and checksum-verified into a `.eknew`
--     staging file first. Only once every single one has arrived intact are they moved into
--     place. A dropped connection, a chunk unload or a 404 half way through leaves your install
--     exactly as it was — the failure mode of the self-extracting installers, which overwrite
--     as they unpack, cannot happen here.
--   * CONFIG IS SACRED. Nothing matching the protected list below is ever written, moved or
--     deleted. Not your keys, not your approvals, not your panel or lift definitions, not your
--     device identity, not the server you paired with.
--   * IT TELLS YOU BEFORE IT COSTS YOU ANYTHING. If a release needs your saved settings
--     migrated (a config-schema bump), or if it is about to replace an easykey/config.lua you
--     have hand-edited, it backs the file up first and says so.
--
-- Trust model: HTTPS to a pinned raw.githubusercontent.com URL is the trust root, exactly as it
-- is for `wget run`. The checksums answer "did this change" and "did the download arrive
-- intact" -- they are not a signature, and this does not defend against a hostile GitHub.
-- ===================================================================

local DEFAULT_BASE = "https://raw.githubusercontent.com/maar-10/EasyKey/main"

--- A computer may point itself at a fork or a local mirror. One line, the base URL, no trailing
--- slash. This is also how the test harness serves the repo from localhost.
local SOURCE_FILE  = "/easykey_update_src.txt"

--- Where the updater records what generation is installed. Written by the installers too.
local VERSION_FILE = "/easykey_version.txt"

--- Backups land here, one timestamped folder per run that needed them.
local BACKUP_DIR   = "/easykey_backup"

--- NEVER written, moved or deleted. Everything the operator owns rather than the release.
--- Anything matching one of these Lua patterns is untouchable, and `protect` is asserted right
--- before each write as a belt-and-braces check rather than trusted to the manifest.
local PROTECTED = {
    "^/role%.txt$",              -- which role this computer is (only an explicit role arg moves it)
    "^/%.easykey_id$",           -- this device's ecnet2 identity == its approval on the server
    "^/easykey_[%w_]*%.cfg",     -- every persisted config: keys, approvals, panels, lifts, outputs
    "^/easykey_server%.txt$",    -- the pinned server address
    "^/easykey_bg%.cfg$",        -- pocket wallpaper
    "^/easykey_error%.txt$",     -- the error log
    "^/easykey_update_src%.txt$",-- the source override itself
    "^/easykey_backup/",         -- our own backups
}

local ROLE_NAMES = { "pocket", "server", "control", "manual", "elevator", "elevmon" }

-- ---------- output ----------
local function colour(c) if term.isColour and term.isColour() then term.setTextColour(c) end end
local function say(text, c) colour(c or colours.white); print(text) end
local function warn(text) say(text, colours.yellow) end
local function bad(text) say(text, colours.red) end
local function good(text) say(text, colours.lime) end
local function dim(text) say(text, colours.lightGrey) end

local function die(text)
    bad(text)
    colour(colours.white)
    error("", 0)
end

-- ---------- checksum ----------
-- FNV-1a, 32 bit, lower-case hex. MUST agree byte for byte with fnv1a() in
-- tools/gen_installers.js; tests/run_updater.sh asserts that it does.
local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261

local function checksum(s)
    local h, n, i = FNV_OFFSET, #s, 1
    while i <= n do
        local j = i + 255
        if j > n then j = n end
        -- string.byte in 256-value batches: one call per byte is many times slower, and this
        -- runs over ~250 KB of vendored crypto on a --verify pass.
        local b = { string.byte(s, i, j) }
        for k = 1, #b do
            h = bit32.bxor(h, b[k])
            -- 32-bit multiply, split into 16-bit halves. The naive product reaches ~7.2e16,
            -- past the 2^53 exact-integer limit of a double, and would silently lose precision.
            local lo = h % 65536
            local hi = (h - lo) / 65536
            h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
        end
        i = j + 1
    end
    return ("%08x"):format(h)
end

-- ---------- files ----------
local function readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s or ""
end

local function writeFile(path, content)
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(content)
    f.close()
    return true
end

--- Is this path the operator's rather than the release's?
local function isProtected(path)
    for _, pattern in ipairs(PROTECTED) do
        if path:match(pattern) then return true end
    end
    return false
end

--- The last line of defence. Every write goes through here, so a manifest that somehow named a
--- config file still could not clobber it — the guarantee does not depend on the manifest being
--- correct.
local function guard(path)
    if isProtected(path) then
        die("REFUSED to write a protected path: " .. path .. "\nThis is a bug; nothing was changed.")
    end
end

-- ---------- http ----------
--- One attempt. Note the THREE return values from pcall: http.get signals failure as
--- `nil, message`, so pcall gives back ok, handle, message — and capturing only the first two
--- throws away the one piece of information the user actually needs when a fetch fails.
local function fetchOnce(url)
    if not http then return nil, "this computer has no HTTP API (enable it in the CC config)" end
    local ok, handle, httpErr = pcall(http.get, url)
    if not ok then return nil, tostring(handle) end
    if not handle then return nil, tostring(httpErr or "no response") end
    local body = handle.readAll()
    local code = handle.getResponseCode and handle.getResponseCode() or 200
    handle.close()
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    if type(body) ~= "string" or #body == 0 then return nil, "empty response" end
    return body
end

--- Fetch with a couple of retries. An update pulls dozens of files in a row, and a single
--- transient hiccup part way through would otherwise abandon the whole run — correct, but
--- needlessly fragile when waiting a second usually fixes it.
local function fetch(url)
    local lastErr
    for attempt = 1, 3 do
        local body, err = fetchOnce(url)
        if body then return body end
        lastErr = err
        -- don't burn retries on something that will never succeed
        if type(err) == "string" and (err:find("HTTP 4", 1, true) or err:find("no HTTP API", 1, true)) then
            break
        end
        if attempt < 3 then sleep(1) end
    end
    return nil, lastErr
end

-- ---------- start ----------
term.clear(); term.setCursorPos(1, 1)
say("EasyKey updater", colours.cyan)

local args = { ... }
-- Two INDEPENDENT switches, not one mode. `--verify` says how hard to look; `--check` says don't
-- write. `easykey_update.lua --verify --check` is the useful combination — "tell me what a full
-- re-check would repair" — and a single `mode` variable silently threw one of them away.
local dryRun, forceVerify, wantRole = false, false, nil
for _, a in ipairs(args) do
    if a == "--check" or a == "-n" then dryRun = true
    elseif a == "--verify" then forceVerify = true
    elseif a:sub(1, 1) == "-" then die("unknown option: " .. a)
    else
        local found = false
        for _, r in ipairs(ROLE_NAMES) do if r == a then found = true end end
        if not found then
            die("unknown role: " .. a .. "\nroles: " .. table.concat(ROLE_NAMES, " | "))
        end
        wantRole = a
    end
end

local base = (readFile(SOURCE_FILE) or ""):gsub("%s+$", ""):gsub("^%s+", "")
if base == "" then base = DEFAULT_BASE else dim("source: " .. base) end

-- ---------- the release manifest ----------
local manifestBody, err = fetch(base .. "/manifest.lua")
if not manifestBody then die("could not reach the release manifest: " .. tostring(err)) end

-- Parsed as DATA, not run as code: unserialise evaluates a table constructor in an empty
-- environment, so the manifest cannot do anything but describe files. (Its leading `--` comment
-- block is fine — Lua's own parser skips comments, and tests/run_updater.sh checks that.)
local manifest = textutils.unserialise(manifestBody)
if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
    die("the release manifest is not readable (is the source URL right?)")
end

-- ---------- which role ----------
local role = wantRole
if not role then
    local raw = readFile("/role.txt") or ""
    local system, detected = raw:match("^%s*([%w_]+)%s*:%s*([%w_]+)")
    if system ~= "easykey" or not detected then
        bad("No EasyKey role is installed on this computer.")
        print("")
        dim("This is an updater, not a first-time installer: it needs to know")
        dim("which role to update. Either run one of the full installers, or")
        dim("name a role and this will fetch it fresh:")
        print("")
        say("  easykey_update.lua <role>", colours.white)
        dim("  roles: " .. table.concat(ROLE_NAMES, " | "))
        return
    end
    role = detected
end

local spec = manifest.roles[role]
if not spec then
    die("this release has no role called '" .. role .. "'\nroles: " .. table.concat(ROLE_NAMES, " | "))
end

-- ---------- what is installed here ----------
local localVersion, localSchema, localRole
do
    local raw = readFile(VERSION_FILE) or ""
    localVersion = raw:match("version=([%w]+)")
    localSchema = tonumber(raw:match("schema=(%d+)"))
    localRole = raw:match("role=([%w_]+)")
end

say(("role %s  (%s)"):format(role, spec.title or role), colours.white)
dim(("installed %s -> release %s"):format(localVersion or "unknown", manifest.version))

local freshInstall = (wantRole ~= nil and (localVersion == nil or localRole ~= role))

-- ---------- decide what to fetch ----------
--- The fast path: if the recorded version already matches the release, nothing can have changed
--- and there is no reason to checksum ~250 KB of vendored crypto.
---
--- It only holds for the SAME role. A version stamp says "the files of role X are current", and
--- switching to role Y needs a different file set entirely — trusting the stamp across a role
--- change installed nothing at all and still declared success.
--- `--verify` opts out on purpose: that is the mode for "something on disk looks wrong", which
--- no version stamp can detect.
local upToDateByVersion = (localVersion == manifest.version)
    and (localRole == role)
    and not forceVerify

local changes, verified = {}, 0
if upToDateByVersion then
    dim("version matches; use --verify to re-check every file")
else
    write("checking files")
    for i, entry in ipairs(spec.files) do
        local path = "/" .. entry.dst
        local body = readFile(path)
        local reason
        if body == nil then
            reason = "missing"
        elseif #body ~= entry.size then
            -- a size mismatch is conclusive on its own, so skip the checksum
            reason = "changed"
        elseif checksum(body) ~= entry.sum then
            reason = "changed"
        end
        verified = verified + 1
        if reason then
            changes[#changes + 1] = { entry = entry, path = path, reason = reason }
        end
        if i % 40 == 0 then write(".") end
    end
    print("")
end

-- Basalt is a third-party file fetched from its own pinned URL, so it is not in the file list
-- and gets no checksum. Re-download it only when it is absent or the pinned URL moved —
-- pulling 300 KB on every update would make this unusable.
local needBasalt = false
if spec.basalt then
    local recordedUrl = (readFile("/easykey_basalt_url.txt") or ""):gsub("%s+$", "")
    if not fs.exists("/basalt.lua") then
        needBasalt = true
    elseif recordedUrl ~= (manifest.basalt or "") then
        needBasalt = true
    end
end

-- ---------- is the updater itself current? ----------
--- Reported, never acted on: rewriting the file you are currently executing is a good way to end
--- up with neither version working. Under `wget run` there is no local copy to compare, so this
--- simply stays quiet.
local updaterStale = false
do
    local u = manifest.updater
    local me = nil
    if shell and shell.getRunningProgram then
        local ok, p = pcall(shell.getRunningProgram)
        if ok and type(p) == "string" and p ~= "" then me = readFile("/" .. p) end
    end
    if type(u) == "table" and type(u.size) == "number" and u.size > 0 and me then
        updaterStale = (#me ~= u.size) or (checksum(me) ~= u.sum)
    end
end

-- ---------- report ----------
print("")
if #changes == 0 and not needBasalt then
    good("Already up to date.")
    if updaterStale then
        print("")
        warn("The updater itself is out of date. Re-fetch it with:")
        dim("  wget " .. base .. "/easykey_update.lua easykey_update.lua")
    end
    colour(colours.white)
    if not upToDateByVersion then
        -- the files were right but the stamp was not; fix the stamp so the fast path works
        writeFile(VERSION_FILE, ("version=%s\nschema=%d\nrole=%s\n")
            :format(manifest.version, manifest.schema or 1, role))
    end
    return
end

say(("%d file(s) to update%s"):format(#changes, needBasalt and ", plus Basalt" or ""),
    colours.yellow)
local shown = 0
for _, c in ipairs(changes) do
    if shown < 8 then
        dim(("  %-8s %s"):format(c.reason, c.entry.dst))
        shown = shown + 1
    end
end
if #changes > shown then dim(("  ... and %d more"):format(#changes - shown)) end

if dryRun then
    print("")
    dim("--check: nothing was written.")
    colour(colours.white)
    return
end

-- ---------- safety: back up anything this could cost the operator ----------
local stamp = os.date("!%Y%m%d-%H%M%S")
local backupInto = BACKUP_DIR .. "/" .. stamp
local backedUp = {}

local function backup(path)
    local body = readFile(path)
    if body == nil then return false end
    local name = path:gsub("^/", ""):gsub("/", "_")
    if writeFile(backupInto .. "/" .. name, body) then
        backedUp[#backedUp + 1] = path
        return true
    end
    return false
end

-- 1. A config-SCHEMA bump means this release cannot read your saved settings as they are. Copy
--    every persisted config aside before anything else happens, and say so plainly.
local schemaBump = (manifest.schema or 1) > (localSchema or 0) and not freshInstall
if schemaBump and localSchema ~= nil then
    print("")
    warn("=== THIS RELEASE CHANGES THE CONFIG FORMAT ===")
    warn(("saved-settings generation %d -> %d"):format(localSchema, manifest.schema))
    for _, name in ipairs(fs.list("/")) do
        local p = "/" .. name
        if not fs.isDir(p) and name:match("^easykey_.*%.cfg") then backup(p) end
    end
    warn("Your settings may need re-entering after this update.")
end

-- 2. easykey/config.lua is a SHIPPED file, so an update replaces it — and it is also the one
--    shipped file people hand-edit (seedKeys, session length, ranges). Always copy it aside, so
--    an edit is recoverable instead of silently gone.
for _, c in ipairs(changes) do
    if c.entry.dst == "easykey/config.lua" then
        print("")
        warn("easykey/config.lua is being replaced.")
        if backup("/easykey/config.lua") then
            dim("  a copy is in " .. backupInto)
        end
        warn("Re-apply any hand-edits (seedKeys, timings) afterwards.")
    end
end

-- ---------- stage: download and verify EVERYTHING before touching anything ----------
print("")
write("downloading")
local staged = {}

local function discardStaged()
    for _, s in ipairs(staged) do
        if fs.exists(s.tmp) then pcall(fs.delete, s.tmp) end
    end
end

for i, c in ipairs(changes) do
    local url = base .. "/" .. c.entry.src
    local body, ferr = fetch(url)
    if not body then
        print("")
        discardStaged()
        bad("failed to fetch " .. c.entry.src .. ": " .. tostring(ferr))
        die("NOTHING was changed. Your install is exactly as it was.")
    end
    -- Verify against the manifest before it is allowed anywhere near the live tree.
    if #body ~= c.entry.size or checksum(body) ~= c.entry.sum then
        print("")
        discardStaged()
        bad(("checksum mismatch on %s (got %d bytes / %s, expected %d / %s)")
            :format(c.entry.src, #body, checksum(body), c.entry.size, c.entry.sum))
        die("NOTHING was changed. Retry; if it persists the release is mid-publish.")
    end
    local tmp = c.path .. ".eknew"
    guard(c.path) -- a protected path must never even be staged
    if not writeFile(tmp, body) then
        print("")
        discardStaged()
        die("could not write " .. tmp .. " (disk full?)  NOTHING was changed.")
    end
    staged[#staged + 1] = { tmp = tmp, path = c.path }
    if i % 20 == 0 then write(".") end
end
print("")

-- ---------- commit: every file arrived intact, so move them all into place ----------
local committed = 0
for _, s in ipairs(staged) do
    guard(s.path)
    if fs.exists(s.path) then pcall(fs.delete, s.path) end
    local ok = pcall(fs.move, s.tmp, s.path)
    if ok then committed = committed + 1 else bad("could not replace " .. s.path) end
end
good(("%d file(s) updated"):format(committed))

-- ---------- basalt ----------
if needBasalt then
    write("fetching Basalt (full build)")
    local body = fetch(manifest.basalt)
    -- Compile-check before replacing a working copy: a truncated download that still writes
    -- would take the UI down on the next boot, and this role cannot start without it.
    local compiles = type(body) == "string" and #body > 1000 and (load or loadstring)(body) ~= nil
    if compiles then
        writeFile("/basalt.lua", body)
        writeFile("/easykey_basalt_url.txt", manifest.basalt)
        print("")
        good(("basalt.lua (%d bytes)"):format(#body))
    else
        print("")
        warn("Basalt download failed or was incomplete; the existing copy was kept.")
        dim("  retry, or: wget " .. tostring(manifest.basalt) .. " basalt.lua")
    end
end

-- ---------- role.txt, only when a role was named explicitly ----------
if wantRole then
    local raw = readFile("/role.txt") or ""
    local _, current = raw:match("^%s*([%w_]+)%s*:%s*([%w_]+)")
    if current ~= wantRole then
        writeFile("/role.txt", "easykey:" .. wantRole)
        print("")
        warn(("role.txt: %s -> %s"):format(current or "(none)", wantRole))
    end
end

-- ---------- record what is now installed ----------
writeFile(VERSION_FILE, ("version=%s\nschema=%d\nrole=%s\n")
    :format(manifest.version, manifest.schema or 1, role))

print("")
if #backedUp > 0 then
    warn(("%d file(s) backed up in %s"):format(#backedUp, backupInto))
end
good("Now at " .. manifest.version .. ". Reboot to run it.")
if updaterStale then
    print("")
    warn("The updater itself is out of date. Re-fetch it with:")
    dim("  wget " .. base .. "/easykey_update.lua easykey_update.lua")
end
colour(colours.white)
