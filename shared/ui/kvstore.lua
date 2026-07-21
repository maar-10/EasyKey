--- Generic persistent key -> value store, serialized to a file on the UI
--- computer (survives reboot; also hand-editable). Used for the farm->relay
--- assignments and the corner category labels. Setting a value to nil clears it.
local KVStore = {}
KVStore.__index = KVStore

function KVStore.load(path)
    local self = setmetatable({}, KVStore)
    self.path = path
    self.values = {}
    if fs.exists(path) then
        local f = fs.open(path, "r")
        local raw = f.readAll(); f.close()
        local ok, data = pcall(textutils.unserialize, raw)
        if ok and type(data) == "table" then self.values = data end
    end
    return self
end

function KVStore:get(key) return self.values[key] end

function KVStore:set(key, value)
    self.values[key] = value -- nil clears
    self:save()
end

function KVStore:all() return self.values end

function KVStore:save()
    local f = fs.open(self.path, "w")
    f.write(textutils.serialize(self.values))
    f.close()
end

return KVStore
