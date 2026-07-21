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

local errFile = "/boot_err.txt"
local mod = "easykey.server"
if role == "control" then mod = "easykey.control"
elseif role == "pocket" then mod = "easykey.pocket.run"
elseif role == "manual" then mod = "easykey.manual" end

local function runRole()
    local ok, err = pcall(function() require(mod) end)
    if not ok then
        local f = fs.open(errFile, "w"); f.writeLine("ERR " .. tostring(err)); f.close()
    end
end

parallel.waitForAny(runRole, function() sleep(1.5) end)

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
