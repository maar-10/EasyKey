--- Registry of APPROVED devices, keyed by **ecnet2 address** (a public key).
---
--- v1 keyed this by computer id, which any attacker could simply claim. An address is
--- proven by the encrypted tunnel, so an entry here is a real authorisation decision.
---
--- Used twice on the server, with different files:
---   * pockets  -> may open the keypad / hold sessions
---   * controls -> may receive the secure-set and be pinged for presence
---
--- Only approved devices live here. Unknown devices that connect are held as pending
--- by the server (in memory, never persisted) until the operator approves them on the
--- server screen — approval is the only way in, there is no auto-trust.
local KVStore = require("shared.ui.kvstore")

local Devices = {}
Devices.__index = Devices

function Devices.load(path)
    local self = setmetatable({}, Devices)
    self._kv = KVStore.load(path)
    return self
end

--- Is this address approved?
function Devices:isApproved(address)
    return self._kv:get(address) ~= nil
end

--- Friendly name for an approved address, or nil.
function Devices:nameOf(address)
    local e = self._kv:get(address)
    return e and e.name or nil
end

--- Approve an address and persist it.
function Devices:approve(address, name)
    self._kv:set(address, { name = name or ("device-" .. address:sub(1, 6)) })
end

--- Revoke a previously approved device (e.g. a pocket was lost). The caller should
--- also revoke any live session for it.
function Devices:revoke(address)
    if self._kv:get(address) ~= nil then
        self._kv:set(address, nil)
        return true
    end
    return false
end

--- Approved entries: array of { address, name }, sorted.
function Devices:list()
    local out = {}
    for address, e in pairs(self._kv:all()) do
        out[#out + 1] = { address = address, name = (e and e.name) or "?" }
    end
    table.sort(out, function(a, b) return a.address < b.address end)
    return out
end

--- Approved addresses only (e.g. the control list handed to pockets).
function Devices:addresses()
    local out = {}
    for _, e in ipairs(self:list()) do out[#out + 1] = e.address end
    return out
end

function Devices:isEmpty() return next(self._kv:all()) == nil end

function Devices:count()
    local n = 0
    for _ in pairs(self._kv:all()) do n = n + 1 end
    return n
end

return Devices
