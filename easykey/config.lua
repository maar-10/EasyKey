--- EasyKey configuration. Keep the timing/keypad values identical on every EasyKey
--- computer. Per-computer specifics (the server's keys/devices, a control PC's doors,
--- each device's pinned server address) live in the persisted files named below.
---
--- v2 note: there are no modem channels to configure any more. All traffic rides
--- encrypted ecnet2 tunnels, and ecnet2 derives its channel from the protocol name
--- (see easykey/protocol.lua -> Protocol.NAMES).
local Config = {}

Config.timing = {
    session_seconds      = 300,  -- how long a pocket stays secure after a valid key (5 min)
    ping_interval        = 1.0,  -- pocket presence-ping cadence while secure
    secure_push          = 5.0,  -- server re-pushes the secure-set this often (also heartbeat)
    server_offline_after = 15.0, -- pocket/control treat the server as down after this silence
    retry_cooldown       = 3.0,  -- after a wrong key, the pocket must wait this long
    ui_tick              = 1.0,  -- pocket clock/countdown refresh (seconds tick)
    reconnect_after      = 10.0, -- retry a dropped tunnel this often
}

--- Keypad layout. `chars` is the button grid in row-major order across `cols`.
--- Reserved action tokens are in `actions`; everything else is appended to the entry.
--- All entries are plain ASCII so they type, display and transmit cleanly.
Config.keypad = {
    cols = 3,
    chars = {
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        "*", "0", "#",
        "X", "<", "OK", -- X = cancel, < = backspace, OK = submit
    },
    actions = { submit = "OK", backspace = "<", cancel = "X" },
    mask = "\7",   -- entered characters are shown as this bullet
    maxLen = 24,   -- entry length cap
}

--- Defaults for a control PC's outputs. Range is per-output and set from its console;
--- these are only what a NEWLY discovered output starts with.
Config.proximity = {
    range        = 4,   -- blocks: how close a secure pocket must be
    stale        = 2.0, -- seconds: a pocket not heard from this long counts as gone
    pressSeconds = 0.5, -- length of a "press" pulse (a button tap)
}

--- Where each device keeps its own ecnet2 identity (its private key). Readable by
--- anyone holding the device — which is exactly why no authorisation secret lives
--- here; the key stays in the user's head and the vault stays on the server.
Config.identityPath = "/.easykey_id"

--- The pinned server address, written during pairing (fingerprint-confirmed).
Config.serverFile = "/easykey_server.txt"

--- The pocket's chosen cosmetic background style id. Purely local eye-candy; never sent
--- anywhere. Absent/empty = the plain default.
Config.pocketBgFile = "/easykey_bg.cfg"

--- Manual control PC (the remote panel). Range/grace are adjustable in its UI.
Config.manual = {
    range           = 100, -- blocks: pockets this close are shown the panel
    graceSeconds    = 3,   -- range-exceed / connection blips tolerated before a switch resets
                           -- (a session ENDING is never graced - that resets instantly)
    pressSeconds    = 0.5, -- button pulse length
    statePush       = 1.0, -- how often panel state is pushed to pockets (also a heartbeat)
    feedbackTimeout = 3.0, -- pocket: no state within this -> show "signal error"
}

--- The manual PC's buttons/switches:
---   id -> { name, type, use, target, fallback, invert, cooldown }
Config.panelFile = "/easykey_panel.cfg"

--- Control-PC state. Both are written by its console UI, not edited by hand.
Config.outputsFile = "/easykey_outputs.cfg" -- id -> { name, type, range }
Config.sidesFile   = "/easykey_sides.cfg"   -- "<device>/<side>" -> { bundled = true }

--- Server-only vaults.
Config.keysFile     = "/easykey_keys.cfg"     -- salted+iterated hashes, never plaintext
Config.pocketsFile  = "/easykey_pockets.cfg"  -- approved pocket addresses
Config.controlsFile = "/easykey_controls.cfg" -- approved control addresses

--- Cost of the salted key hash. Raise for more brute-force resistance; it only runs
--- on the server, once per key entry (~0.2s per 4096 iters on a fast host, more
--- in-game). Prefer a longer key over a huge number here.
Config.keyHashIterations = 4096

--- Seed key(s) hashed into keysFile on first server run if it doesn't exist yet.
--- CHANGE THIS before deploying. The plaintext seed never reaches disk.
Config.seedKeys = {
    ["1234"] = { label = "default" },
}

--- `clock`  : real-life clock timezone: "auto-de" | "local" | <offset hours>
--- `osSign` : the glyph shown next to the real-life clock on the pocket, standing in for
---            "IRL". Keep it plain ASCII (32-126): CC:Tweaked's in-game font differs from
---            CraftOS-PC's for extended chars, so anything above ASCII may render wrong.
Config.ui = { clock = "auto-de", osSign = "@" }

return Config
