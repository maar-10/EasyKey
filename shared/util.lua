--- Small shared helpers with no CC-specific side effects (except now()).
--- Pure functions here are covered by tests/test_util.lua.
---@class Util
local Util = {}

--- Real-world timestamp in milliseconds. Wrapped so tests can stub it.
--- os.epoch("utc") is provided by CC:Tweaked and CraftOS-PC.
function Util.now()
    return os.epoch("utc")
end

--- Stable key for an item stack: name plus an nbt discriminator when present.
--- list() returns nbt as a hash string, so equal stacks share a key.
---@param name string
---@param nbt string|nil
---@return string
function Util.itemKey(name, nbt)
    if nbt ~= nil and nbt ~= "" then
        return name .. "#" .. nbt
    end
    return name
end

--- Shallow-copy a table (one level).
function Util.shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Deep-copy a plain data table (no metatables / functions).
function Util.deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = Util.deepCopy(val)
    end
    return out
end

--- Count keys in a map-like table.
function Util.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Deep equality for plain data tables (order-independent for maps).
function Util.deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not Util.deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Human-friendly number: 1234 -> "1.2k", 1500000 -> "1.5M".
function Util.formatCount(n)
    n = n or 0
    if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

--- Format a signed rate for display, e.g. +12.5 or -3.0.
function Util.formatRate(r)
    r = r or 0
    local sign = r >= 0 and "+" or ""
    if math.abs(r) >= 100 then
        return sign .. string.format("%.0f", r)
    end
    return sign .. string.format("%.1f", r)
end

--- Day-of-month of the last Sunday, for a 31-day month (March/October), via
--- Zeller's congruence. Used for EU daylight-saving boundaries.
function Util._lastSunday31(year, month)
    local q, m = 31, month
    local K = year % 100
    local J = math.floor(year / 100)
    -- h: 0=Saturday, 1=Sunday, ... 6=Friday
    local h = (q + math.floor(13 * (m + 1) / 5) + K + math.floor(K / 4) + math.floor(J / 4) + 5 * J) % 7
    local daysAfterSunday = (h - 1 + 7) % 7
    return 31 - daysAfterSunday
end

--- Europe/Berlin UTC offset in hours for a given UTC timestamp (ms):
--- +2 during CEST, +1 during CET. DST runs from 01:00 UTC on the last Sunday
--- of March to 01:00 UTC on the last Sunday of October.
function Util.germanOffsetHours(utcMs)
    local t = os.date("!*t", math.floor(utcMs / 1000))
    local m = t.month
    if m < 3 or m > 10 then return 1 end
    if m > 3 and m < 10 then return 2 end
    local lastSun = Util._lastSunday31(t.year, m)
    if m == 3 then
        if t.day > lastSun or (t.day == lastSun and t.hour >= 1) then return 2 else return 1 end
    else -- October
        if t.day < lastSun or (t.day == lastSun and t.hour < 1) then return 2 else return 1 end
    end
end

--- Formatted wall clock (HH:MM:SS) for a clock mode:
---   "auto-de"  -> Europe/Berlin with automatic DST (default)
---   "local"    -> the computer/server machine's local time
---   <number>   -> fixed offset hours from UTC
function Util.clockString(mode)
    if mode == nil then mode = "auto-de" end
    local secs
    if mode == "local" then
        secs = math.floor(os.epoch("local") / 1000)
    elseif type(mode) == "number" then
        secs = math.floor(os.epoch("utc") / 1000) + mode * 3600
    else
        secs = math.floor(os.epoch("utc") / 1000) + Util.germanOffsetHours(os.epoch("utc")) * 3600
    end
    return os.date("!%H:%M:%S", secs)
end

--- Clamp a number into [lo, hi].
function Util.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

return Util
