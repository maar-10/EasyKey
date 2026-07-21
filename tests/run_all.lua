--- Runs every EasyKey test module and writes /test_results.txt. Intended to run
--- headless under CraftOS-PC (see tests/run_headless.sh).
local F = require("tests.framework")

local modules = {
    "tests.test_util",
    "tests.test_protocol",
    "tests.test_sessions",
    "tests.test_outputs",
    "tests.test_redstone_io",
    "tests.test_panel",
    "tests.test_panel_feed",
    "tests.test_keypad",
    "tests.test_link",
    "tests.test_keystore",
    "tests.test_integration",
    -- real crypto: drives an actual ecnet2 handshake over loopback modems
    "tests.test_secure_net",
}

local t = F.new()
local errors = {}

for _, m in ipairs(modules) do
    local ok, fn = pcall(require, m)
    if not ok then
        errors[#errors + 1] = "LOAD ERROR " .. m .. ": " .. tostring(fn)
    else
        local ok2, err = pcall(fn, t)
        if not ok2 then
            errors[#errors + 1] = "RUN ERROR " .. m .. ": " .. tostring(err)
        end
    end
end

local lines = {}
lines[#lines + 1] = "SUMMARY: " .. t:summary()
for _, l in ipairs(t.log) do lines[#lines + 1] = l end
for _, e in ipairs(errors) do lines[#lines + 1] = e end
lines[#lines + 1] = (t.failed == 0 and #errors == 0) and "ALL_PASS" or "HAS_FAILURES"

local out = table.concat(lines, "\n")
local f = fs.open("/test_results.txt", "w")
f.writeLine(out)
f.close()
print(out)
return t
