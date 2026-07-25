--- Runtime boot smoke for the headless roles. Emulates a modem (periphemu), then
--- launches the role for ~1.5s: this exercises real initialization — Net.open,
--- keystore/devices/doors loading, the first dashboard draw and secure-set
--- broadcast — and catches runtime errors that a compile check cannot. The role
--- normally blocks in its event loop, so a watchdog ends the run cleanly.
package.path = "/?.lua;/?/init.lua;" .. package.path

local role = "server"
if fs.exists("/which_role.txt") then
    local f = fs.open("/which_role.txt", "r"); role = f.readLine() or "server"; f.close()
end

-- Give the computer a modem so Net.open() finds one.
if periphemu then pcall(function() periphemu.create("back", "modem") end) end

-- Pin a server address so the roles that pair interactively (control/manual/elevator/elevmon)
-- get PAST pairing and actually initialize. Without this they block in Discovery.find + read()
-- and this smoke only ever proved the module parsed — it would happily pass while a role's UI
-- crashed on its first draw. The address is a real ecnet2 identity so it is well-formed; there
-- is nothing on the other end, which is fine (the roles must survive an absent server anyway).
do
    local Config = dofile("/easykey/config.lua")
    if not fs.exists(Config.serverFile) then
        pcall(function()
            require("ccryptolib.random").initWithTiming()
            local id = require("ecnet2").Identity("/.probe_server_id")
            local f = fs.open(Config.serverFile, "w"); f.write(id.address); f.close()
        end)
    end
end

local errFile = "/boot_err.txt"
local mod = "easykey.server"
if role == "control" then mod = "easykey.control"
elseif role == "pocket" then mod = "easykey.pocket.run"
elseif role == "manual" then mod = "easykey.manual"
elseif role == "elevator" then mod = "easykey.elevator"
elseif role == "elevmon" then mod = "easykey.elevmon" end

local function runRole()
    local ok, err = pcall(function() require(mod) end)
    if not ok then
        local f = fs.open(errFile, "w"); f.writeLine("ERR " .. tostring(err)); f.close()
    end
end

-- Long enough for a role to finish init, draw, and take at least a couple of its own 0.25s
-- ticks — which is where a bad refresh path shows up.
parallel.waitForAny(runRole, function() sleep(2.5) end)

local out = fs.open("/boot_result.txt", "w")
if fs.exists(errFile) then
    local f = fs.open(errFile, "r"); out.writeLine(f.readAll()); f.close()
    out.writeLine("BOOT_FAIL")
else
    out.writeLine("role " .. role .. " initialized and ran its loop")
    out.writeLine("BOOT_OK")
end
out.close()
os.shutdown()
