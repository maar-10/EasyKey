--- Encrypted transport for EasyKey — a thin wrapper over ecnet2 (Noise XK, X25519 +
--- AEAD, replay protection). Replaces the old plaintext `shared/net.lua`; every byte
--- EasyKey puts on a modem now goes through here.
---
--- What ecnet2 gives us, and why the rest of EasyKey is simpler because of it:
---   * every message's `sender` is a cryptographically authenticated address (a public
---     key) — so we never need bearer tokens or forgeable computer ids,
---   * replays and tampering are rejected by the library,
---   * `distance` still rides along on each message, which is what proximity needs.
---
--- Shape: one SecureNet per computer (it owns the modem + this device's identity), and
--- one *protocol* per conversation kind. A control PC needs two — it connects to the
--- server on one and listens for pockets on the other — which is why protocols hang off
--- the transport rather than being baked into it.
---
--- Ecnet2 is point-to-point (broadcast is an explicit non-goal), so callers open one
--- connection per peer. Channels are derived from the protocol name by ecnet2 itself,
--- so EasyKey no longer configures modem channels.
---@class SecureNet
local SecureNet = {}
SecureNet.__index = SecureNet

---@class SecureProtocol
local SecureProtocol = {}
SecureProtocol.__index = SecureProtocol

--- Finds a modem side. Prefers a wireless (ender) modem, falls back to any modem —
--- the same preference the first project used, kept because tests run on emulated
--- wired modems. Returns the peripheral NAME, since ecnet2 addresses modems by side.
local function findModemSide(side)
    if side then
        if not peripheral.isPresent(side) then
            error("No modem on side '" .. side .. "'", 0)
        end
        return side
    end
    local fallback
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m.isWireless and m.isWireless() then return name end -- ender preferred
            fallback = fallback or name
        end
    end
    if fallback then return fallback end
    error("No modem attached. Attach an ender modem.", 0)
end

--- Short, human-comparable fingerprint of an address. Used for pairing: the user
--- checks these 8 characters against the server's screen instead of typing all 44.
---@param address string
---@return string
function SecureNet.fingerprint(address)
    if type(address) ~= "string" then return "????????" end
    return address:sub(1, 8)
end

--- Normalises an ecnet2 event tuple. Returns nil if the event isn't ecnet2's.
---   kind "request" -> { listenerId, request, side, channel, distance }
---   kind "message" -> { connId, sender, message, channel, distance }
--- Usage:
---   local kind, e = SecureNet.match(os.pullEvent())
--- Note: listener/connection ids are BINARY strings — compare them, never print them.
function SecureNet.match(event, a, b, c, d, e)
    if event == "ecnet2_request" then
        return "request", { listenerId = a, request = b, side = c, channel = d, distance = e }
    elseif event == "ecnet2_message" then
        return "message", { connId = a, sender = b, message = c, channel = d, distance = e }
    end
    return nil
end

--- Opens the encrypted transport: seeds the RNG, finds/opens a modem, loads or creates
--- this device's identity.
--- @param opts table { identityPath=string, modem=string|nil, ecnet2=table|nil, random=table|nil }
--- @return SecureNet
function SecureNet.open(opts)
    opts = opts or {}
    local ecnet2 = opts.ecnet2 or require("ecnet2")
    local random = opts.random or require("ccryptolib.random")

    -- CC has no hardware entropy; ecnet2's own examples seed from VM timing noise.
    -- Seed once per boot, before any key material is generated.
    random.initWithTiming()

    local self = setmetatable({}, SecureNet)
    self._ecnet2 = ecnet2
    self.side = findModemSide(opts.modem)
    ecnet2.open(self.side)

    self.identity = ecnet2.Identity(opts.identityPath or "/.easykey_id")
    self.address = self.identity.address
    -- The daemon coroutine; callers MUST run it in parallel with their own loop:
    --   parallel.waitForAny(main, net.daemon)
    self.daemon = ecnet2.daemon
    return self
end

function SecureNet:myAddress() return self.address end
function SecureNet:myFingerprint() return SecureNet.fingerprint(self.address) end

--- Creates a protocol (a named conversation). Peers must use the same name; ecnet2
--- also derives the modem channel from it, so different names stay off each other's
--- channels.
--- @param name string
--- @return SecureProtocol
function SecureNet:protocol(name)
    local p = setmetatable({}, SecureProtocol)
    p._net = self
    p._proto = self.identity:Protocol {
        name = name,
        serialize = textutils.serialize,
        deserialize = textutils.unserialize,
    }
    p.listener = nil
    return p
end

--- Start accepting incoming connections on this protocol.
function SecureProtocol:listen()
    self.listener = self._proto:listen()
    return self.listener
end

--- True if a matched "request" event belongs to this protocol's listener.
function SecureProtocol:isMine(e)
    return self.listener ~= nil and e ~= nil and e.listenerId == self.listener.id
end

--- Accept a pending request, replying with `reply`. Returns the Connection.
function SecureProtocol:accept(request, reply)
    if not self.listener then error("listen() must be called before accept()", 0) end
    return self.listener:accept(reply, request)
end

--- Open a connection to a peer address. Returns the Connection, or nil + err if the
--- address is malformed (a typo'd/garbage pin shouldn't crash the device).
function SecureProtocol:connect(address)
    local ok, conn = pcall(function()
        return self._proto:connect(address, self._net.side)
    end)
    if not ok then return nil, tostring(conn) end
    return conn
end

return SecureNet
