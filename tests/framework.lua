--- Minimal test framework. Collects pass/fail and a log of failures.
local Util = require("shared.util")

local F = {}
F.__index = F

function F.new()
    return setmetatable({ passed = 0, failed = 0, log = {}, group = "" }, F)
end

function F:describe(name) self.group = name end

function F:_fail(msg)
    self.failed = self.failed + 1
    self.log[#self.log + 1] = "FAIL [" .. self.group .. "] " .. msg
end

function F:ok(cond, msg)
    if cond then self.passed = self.passed + 1 else self:_fail(msg or "expected truthy") end
end

function F:eq(a, b, msg)
    if Util.deepEqual(a, b) then
        self.passed = self.passed + 1
    else
        self:_fail((msg or "values differ") ..
            " (got " .. textutils.serialize(a) .. ", want " .. textutils.serialize(b) .. ")")
    end
end

function F:near(a, b, tol, msg)
    tol = tol or 1e-6
    if type(a) == "number" and math.abs(a - b) <= tol then
        self.passed = self.passed + 1
    else
        self:_fail((msg or "not near") .. " (got " .. tostring(a) .. ", want ~" .. tostring(b) .. ")")
    end
end

function F:summary()
    return ("%d passed, %d failed"):format(self.passed, self.failed)
end

return F
