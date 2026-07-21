--- Tests for the server key vault. Uses the REAL ccryptolib sha256 (available under
--- CraftOS), with a low iteration count so the suite stays fast.
return function(t)
    local KeyStore = require("easykey.keystore")
    t:describe("keystore")

    -- Salt generation needs a seeded RNG. In production this is a boot-time job done
    -- once by SecureNet.open(); here we do the same before touching the vault.
    require("ccryptolib.random").initWithTiming()

    local opts = { iters = 4 } -- real sha256/random, cheap iterations for tests
    local path = "/test_keys.cfg"
    fs.delete(path)

    local ks = KeyStore.load(path, { ["1234"] = { label = "default" } }, opts)
    t:eq(ks:count(), 1, "seeded one key")

    -- correct key verifies and returns its label
    local e = ks:verify("1234")
    t:ok(e ~= nil, "correct key verifies")
    t:eq(e.label, "default", "verify returns the key's label")

    -- wrong keys never verify
    t:ok(not ks:verify("1235"), "wrong key rejected")
    t:ok(not ks:verify(""), "empty key rejected")
    t:ok(not ks:verify(nil), "nil key rejected")
    t:ok(not ks:verify("12345"), "longer key rejected")

    -- THE property: the plaintext key is never written to disk
    local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
    t:ok(not raw:find("1234", 1, true), "plaintext key is NOT on disk")
    t:ok(raw:find("salt", 1, true) ~= nil, "entry stores a salt")
    t:ok(raw:find("hash", 1, true) ~= nil, "entry stores a hash")

    -- multiple keys, each with its own label ("who unlocked")
    ks:add("9999", "bob")
    t:eq(ks:count(), 2, "second key added")
    t:eq(ks:verify("9999").label, "bob", "second key verifies with its label")
    t:eq(ks:verify("1234").label, "default", "first key still verifies")

    -- same key added twice gets a DIFFERENT salt -> different hash (no rainbow reuse)
    local ks2 = KeyStore.load("/test_keys2.cfg", nil, opts)
    fs.delete("/test_keys2.cfg")
    ks2 = KeyStore.load("/test_keys2.cfg", nil, opts)
    ks2:add("samekey", "a")
    ks2:add("samekey", "b")
    local entries = {}
    for _, item in ipairs(ks2:list()) do entries[#entries + 1] = item.id end
    t:eq(#entries, 2, "two entries with the same key")
    local f2 = fs.open("/test_keys2.cfg", "r"); local raw2 = f2.readAll(); f2.close()
    local hashes = {}
    for h in raw2:gmatch('hash = "([0-9a-f]+)"') do hashes[#hashes + 1] = h end
    t:eq(#hashes, 2, "two hashes stored")
    t:ok(hashes[1] ~= hashes[2], "identical keys hash differently (salted)")

    -- persistence across reload
    local reloaded = KeyStore.load(path, nil, opts)
    t:ok(reloaded:verify("1234") ~= nil, "key still verifies after reload")
    t:eq(reloaded:count(), 2, "both keys persisted")

    -- removal
    local list = reloaded:list()
    t:ok(reloaded:remove(list[1].id), "remove returns true for a real id")
    t:eq(reloaded:count(), 1, "count drops after removal")
    t:ok(not reloaded:remove("nope"), "remove returns false for unknown id")

    fs.delete(path); fs.delete("/test_keys2.cfg")
end
