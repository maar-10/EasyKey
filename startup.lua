--- Root launcher for EasyKey. The per-role installer deploys these files and
--- writes "role.txt" containing "easykey:<role>", e.g.
---     easykey:pocket
--- The launcher wires up the module path and hands off to EasyKey's launch.
local running = shell.getRunningProgram()
local root = fs.getDir(running)
local base = (root == "" or root == ".") and "" or ("/" .. root)
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local rolePath = base .. "/role.txt"
local raw
if fs.exists(rolePath) then
    local f = fs.open(rolePath, "r")
    raw = f.readLine() or ""
    f.close()
end

local system, role
if raw then system, role = raw:match("^%s*([%w_]+)%s*:%s*([%w_]+)") end

if not system or not role then
    print("EasyKey launcher")
    print("----------------")
    print("role.txt must contain  easykey:<role>")
    print("(the installer normally sets this for you)")
    print("roles: pocket | server | control | manual")
    print("       elevator | elevmon")
    print("Current value: " .. tostring(raw))
    return
end

if system ~= "easykey" then
    printError("role.txt system is '" .. system .. "', expected 'easykey'")
    return
end

local ok, launch = pcall(require, "easykey.launch")
if not ok then
    printError("Failed to load EasyKey launcher: " .. tostring(launch))
    return
end
local ok2, err = pcall(launch, role)
if not ok2 then
    printError("Failed to start easykey:" .. role .. " -> " .. tostring(err))
end
