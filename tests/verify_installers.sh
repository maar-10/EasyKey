#!/usr/bin/env bash
# Full installer acceptance check, per role, in a fresh headless CraftOS-PC computer:
#   1. run the real installer (base64 unpack + role.txt),
#   2. load()-compile every file it wrote,
#   3. BOOT the role from the installed files and let it run.
#
# Step 3 is the important one. Steps 1-2 once passed while the server was missing
# easykey/link.lua entirely: the source tree had it, so the test suite (which runs from
# source) was green, and compiling the files it *did* ship proved nothing about the
# files it didn't. Only booting what the installer actually produced catches that —
# including modules resolved dynamically, which no static check can see.
#
# basalt.lua is skipped for compiling (it's fetched, not ours) and pre-seeded for the
# pocket so this test never depends on the network.
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"

verify_one() {
  local role="$1"
  local installer="$EASYKEY/install_easykey_${role}.lua"
  local data="${TMPDIR:-/tmp}/easykey_verify_${role}/data"
  local c0="$data/computer/0"
  rm -rf "$c0"; mkdir -p "$c0"
  cp "$installer" "$c0/installer.lua"

  # The Basalt roles. The real installer downloads Basalt; we seed the VENDORED FULL build
  # here so this check never depends on the network AND matches what the installer fetches.
  # (Seeding a smaller build would let a boot pass while the real one is missing an element:
  # DropDown and ProgressBar are full-only.)
  case "$role" in
    pocket|server|manual|elevator)
      cp "$EASYKEY/vendor/basalt-full.lua" "$c0/basalt.lua"
      ;;
  esac

  cat > "$c0/startup.lua" <<'EOF'
local results = {}
local function say(s) results[#results + 1] = s end

-- 1. run the real installer
local okRun, runErr = pcall(function() shell.run("/installer.lua") end)
say("install_ran=" .. tostring(okRun) .. (okRun and "" or (" err=" .. tostring(runErr))))

-- 2. compile everything it wrote
local fails = {}
local function walk(dir)
  for _, name in ipairs(fs.list(dir)) do
    local p = (dir == "/") and ("/" .. name) or (dir .. "/" .. name)
    if fs.isDir(p) then
      if p ~= "/rom" then walk(p) end
    elseif p:sub(-4) == ".lua" and p ~= "/basalt.lua" and p ~= "/installer.lua" then
      local f = fs.open(p, "r"); local src = f.readAll(); f.close()
      local fn, err = load(src, "@" .. p)
      if not fn then fails[#fails + 1] = p .. " : " .. tostring(err) end
    end
  end
end
walk("/")
say("compile_fail=" .. #fails)
for _, l in ipairs(fails) do say("  " .. l) end

-- 3. boot the role from the INSTALLED files (catches missing/dynamic modules)
--
-- Deliberately NOT via shell.run("/startup.lua"): the launcher pcalls and merely
-- *prints* failures, so a missing module would look like a clean boot. We replicate
-- what it does and let the error reach us instead.
periphemu.create("back", "modem")

-- Pin a well-formed server address so the roles that pair interactively get past pairing and
-- actually initialize. Without this, control/manual/elevator/elevmon block in Discovery.find
-- and this check never reaches their UI or their event loop at all.
do
  local okCfg, Config = pcall(dofile, "/easykey/config.lua")
  if okCfg and Config and not fs.exists(Config.serverFile) then
    pcall(function()
      package.path = "/?.lua;/?/init.lua;" .. package.path
      require("ccryptolib.random").initWithTiming()
      local id = require("ecnet2").Identity("/.probe_server_id")
      local f = fs.open(Config.serverFile, "w"); f.write(id.address); f.close()
    end)
  end
end
local bootErr = nil
parallel.waitForAny(
  function()
    local ok, err = pcall(function()
      package.path = "/?.lua;/?/init.lua;" .. package.path
      local f = fs.open("/role.txt", "r"); local raw = f.readLine() or ""; f.close()
      local _sys, role = raw:match("^%s*([%w_]+)%s*:%s*([%w_]+)")
      assert(role, "role.txt not written by installer: " .. raw)
      local launch = require("easykey.launch")
      launch(role) -- blocks in the role's event loop if healthy
    end)
    if not ok then bootErr = tostring(err) end
  end,
  function() sleep(2.5) end -- healthy roles block forever; this ends the run
)

if bootErr then say("boot_error=" .. bootErr) end
local good = okRun and #fails == 0 and not bootErr
say(good and "VERIFY_OK" or "VERIFY_FAIL")

local f = fs.open("/verify.txt", "w")
f.writeLine(table.concat(results, "\n"))
f.close()
os.shutdown()
EOF

  rm -f "$c0/verify.txt"
  timeout 90 "$CRAFTOS" --headless -d "$data" >/dev/null 2>&1 || true
  echo "=== ${role} ==="
  cat "$c0/verify.txt" 2>/dev/null || echo "(no verify output)"
  echo ""
}

verify_one server
verify_one control
verify_one pocket
verify_one manual
verify_one elevator
verify_one elevmon
