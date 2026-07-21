--- Phase-1 de-risk: proves the vendored crypto libs actually work under CraftOS-PC.
--- Loads ccryptolib + ecnet2, seeds the RNG, generates an identity, and reports the
--- address + fingerprint. Also times the crypto ops we care about (identity creation
--- and a sha256 key-hash round) so we can size the pairing UX and key iterations.
package.path = "/?.lua;/?/init.lua;" .. package.path

local out = {}
local function log(...) out[#out + 1] = table.concat({ ... }, " ") end

local ok, err = pcall(function()
    local t0 = os.clock()
    local random = require("ccryptolib.random")
    local sha256 = require("ccryptolib.sha256")
    log("ccryptolib loaded in " .. ("%.2fs"):format(os.clock() - t0))

    -- CC has no real entropy source; ecnet2's examples use timing noise.
    random.initWithTiming()
    log("random seeded (initWithTiming)")

    local t1 = os.clock()
    local ecnet2 = require("ecnet2")
    log("ecnet2 loaded in " .. ("%.2fs"):format(os.clock() - t1))

    -- identity generation (this is what each device does on first boot)
    local t2 = os.clock()
    local id = ecnet2.Identity("/.ecnet2_test")
    local dt = os.clock() - t2
    log("identity created in " .. ("%.2fs"):format(dt))
    log("address = " .. tostring(id.address))
    log("address len = " .. #tostring(id.address))
    log("fingerprint(8) = " .. tostring(id.address):sub(1, 8))

    -- reloading an existing identity must be stable (same address)
    local id2 = ecnet2.Identity("/.ecnet2_test")
    log("reload stable = " .. tostring(id2.address == id.address))

    -- protocol creation (no modem needed to build the object)
    local proto = id:Protocol {
        name = "easykey",
        serialize = textutils.serialize,
        deserialize = textutils.unserialize,
    }
    log("protocol built = " .. tostring(proto ~= nil))

    -- sha256 timing: sizes our salted+iterated key hashing
    local t3 = os.clock()
    local h = sha256.digest("salt" .. "1234")
    log("sha256 single = " .. ("%.4fs"):format(os.clock() - t3) .. " len=" .. #h)

    local N = 1000
    local t4 = os.clock()
    local acc = "seed"
    for _ = 1, N do acc = sha256.digest(acc) end
    local per = (os.clock() - t4) / N
    log(("sha256 x%d = %.2fs  (%.5fs each)"):format(N, os.clock() - t4, per))
    log(("=> 4096 iterations would cost ~%.2fs"):format(per * 4096))
end)

log("ok=" .. tostring(ok))
if not ok then log("ERROR=" .. tostring(err)) end
local f = fs.open("/lib_smoke.txt", "w"); f.writeLine(table.concat(out, "\n")); f.close()
os.shutdown()
