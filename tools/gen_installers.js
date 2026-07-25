#!/usr/bin/env node
// Generates the three self-extracting EasyKey installers (one per role). Each
// installer embeds ONLY the files that role needs (base64), writes them on the
// target computer, sets role.txt, and — for the pocket only — downloads Basalt.
//
//   node tools/gen_installers.js
//
// Output: install_easykey_pocket.lua / _server.lua / _control.lua at repo root.
//
// The vendored crypto libs (ecnet2 + ccryptolib) are embedded rather than fetched:
// an installer that half-downloads its crypto is worse than one that's a bit bigger,
// and embedding pins the exact reviewed version. They live under vendor/ here but
// must land at /ecnet2 and /ccryptolib on the computer (their own require() paths),
// hence the src -> dst mapping below.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..");

/**
 * Read a source file as the exact bytes that must land on a CC computer: LF only.
 *
 * This is load-bearing for easykey_suite.lua. The updater checksums the file on the computer
 * against manifest.lua and refetches from raw.githubusercontent.com, which serves git's
 * normalized (LF) copy. If an installer embedded CRLF from a working copy, a freshly installed
 * computer would report those files as permanently outdated. `.gitattributes` keeps the working
 * copy LF; this makes the generator independent of that anyway.
 */
function readNormalized(relPath) {
  return fs.readFileSync(path.join(ROOT, relPath), "utf8").replace(/\r\n/g, "\n");
}

/** Recursively list .lua files under a directory, as repo-relative paths. */
function luaFilesUnder(dir) {
  const out = [];
  (function walk(d) {
    for (const entry of fs.readdirSync(path.join(ROOT, d), { withFileTypes: true })) {
      const rel = `${d}/${entry.name}`;
      if (entry.isDirectory()) walk(rel);
      else if (entry.name.endsWith(".lua")) out.push(rel);
    }
  })(dir);
  return out.sort();
}

/** Vendored libs: vendor/ecnet2/x.lua -> ecnet2/x.lua (root of the CC computer). */
const VENDOR = [...luaFilesUnder("vendor/ecnet2"), ...luaFilesUnder("vendor/ccryptolib")]
  .map((src) => ({ src, dst: src.replace(/^vendor\//, "") }));

/** Our own files map 1:1. */
const own = (p) => ({ src: p, dst: p });

// Every role needs: the launcher, the encrypted transport, pairing, protocol, config.
const COMMON = [
  "startup.lua",
  "shared/util.lua",
  "easykey/config.lua",
  "easykey/protocol.lua",
  "easykey/launch.lua",
  "easykey/secure_net.lua",
  "easykey/discovery.lua",
  "easykey/link.lua",
].map(own);

const ROLES = {
  pocket: {
    title: "Pocket Key Tool",
    basalt: true,
    files: [
      ...COMMON,
      ...[
        "easykey/logic/keypad_model.lua",
        "easykey/logic/panel_feed.lua",
        "easykey/pocket/run.lua",
        "easykey/pocket/app.lua",
        "easykey/ui/keypad.lua",
        "easykey/pocket/views/clock.lua",
        "easykey/pocket/views/status.lua",
        "easykey/pocket/views/pairing.lua",
        "easykey/pocket/views/backgrounds.lua",
        "easykey/pocket/views/bg_menu.lua",
        "easykey/ui/views/panel_view.lua",
        "easykey/ui/views/rowlist.lua",
        "easykey/ui/palette.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
  server: {
    title: "Key Server (vault)",
    basalt: true, // the vault now renders an operations UI on a monitor
    files: [
      ...COMMON,
      ...[
        "shared/ui/kvstore.lua",
        "easykey/logic/sessions.lua",
        "easykey/keystore.lua",
        "easykey/devices.lua",
        "easykey/server.lua",
        "easykey/logic/keypad_model.lua", // the Keys tab's keypad uses it
        "easykey/ui/keypad.lua",
        "easykey/ui/keyboard.lua", // naming a key on the on-screen keyboard
        "easykey/ui/server_app.lua",
        "easykey/ui/views/topbar.lua",
        "easykey/ui/views/console.lua",
        "easykey/ui/views/ops.lua",
        "easykey/ui/views/rowlist.lua",
        "easykey/ui/palette.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
  manual: {
    title: "Manual Control (panel)",
    basalt: true,
    files: [
      ...COMMON,
      ...[
        "shared/ui/kvstore.lua",
        "easykey/logic/panel.lua",
        "easykey/redstone_io.lua",
        "easykey/manual.lua",
        "easykey/ui/manual_app.lua",
        "easykey/ui/views/topbar.lua",
        "easykey/ui/views/console.lua",
        "easykey/ui/views/panel_ops.lua",
        "easykey/ui/views/panel_edit.lua",
        "easykey/ui/views/panel_view.lua",
        "easykey/ui/views/rowlist.lua",
        "easykey/ui/keyboard.lua",
        "easykey/ui/keypad.lua",           // the edit form's bar-fill numeric entry
        "easykey/logic/keypad_model.lua",  // ...which the keypad drives
        "easykey/ui/palette.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
  control: {
    title: "Door Control",
    basalt: false,
    files: [
      ...COMMON,
      ...[
        "shared/ui/kvstore.lua",
        "easykey/logic/outputs.lua",
        "easykey/redstone_io.lua",
        "easykey/ui/control_console.lua",
        "easykey/control.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
  elevator: {
    title: "Elevator Control (multi-floor lifts)",
    basalt: true,
    files: [
      ...COMMON,
      ...[
        "shared/ui/kvstore.lua",
        "easykey/logic/access.lua",
        "easykey/logic/elevator.lua",
        "easykey/redstone_io.lua",
        "easykey/elevator.lua",
        "easykey/ui/elevator_app.lua",
        "easykey/ui/views/topbar.lua",
        "easykey/ui/views/console.lua",
        "easykey/ui/views/elev_ops.lua",
        "easykey/ui/views/elev_edit.lua",
        "easykey/ui/views/floor_edit.lua",
        "easykey/ui/views/panel_view.lua", // the operator's own copy of the floor buttons
        "easykey/ui/views/rowlist.lua",
        "easykey/ui/keyboard.lua",
        "easykey/ui/keypad.lua", // the lift form's numeric second values
        "easykey/logic/keypad_model.lua", // ...which the keypad drives
        "easykey/ui/palette.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
  elevmon: {
    title: "Elevator Monitor (at the shaft)",
    basalt: false,
    files: [
      ...COMMON,
      ...[
        "shared/ui/kvstore.lua",
        "easykey/redstone_io.lua",
        "easykey/ui/elevmon_console.lua",
        "easykey/elevmon.lua",
      ].map(own),
      ...VENDOR,
    ],
  },
};

// Full build (basalt-full.lua) — the user runs the full element set in-game, so that is
// what installs. Pinned to the same commit vendored for the tests (vendor/basalt-full.lua).
const BASALT_URL =
  "https://raw.githubusercontent.com/Pyroxenium/Basalt2/f6cde73ad4ee4fc5a6bf256f7fd0dbbb5b1da928/release/basalt-full.lua";

// ---------------------------------------------------------------------------
// manifest.lua — what easykey_suite.lua reads to decide what to fetch
// ---------------------------------------------------------------------------

/**
 * Bump ONLY when the shape of a persisted config file (an /easykey_*.cfg) changes in a way an
 * older file cannot satisfy — i.e. when an update genuinely requires the operator's saved
 * settings to be migrated or re-entered. Code changes do not touch this.
 *
 * The updater compares this against the number recorded on the computer, and on a bump it backs
 * up every /easykey_*.cfg before writing anything and says so loudly. Adding an OPTIONAL field
 * (which is what every change so far has been — loadConfig tolerates a missing one) is not a
 * bump; removing or repurposing a field is.
 */
const CONFIG_SCHEMA = 1;

/** Where the updater fetches from. A fork can override it per-computer; see the updater. */
const SOURCE_BASE = "https://raw.githubusercontent.com/maar-10/EasyKey/main";

/**
 * FNV-1a, 32-bit, lower-case hex. Must match the Lua implementation in easykey_suite.lua
 * byte for byte — tests/run_suite.sh checks that they agree.
 *
 * Deliberately NOT a cryptographic hash, and it isn't pretending to be one. The trust root here
 * is HTTPS to a pinned raw.githubusercontent.com URL; this only answers "did this file change"
 * and "did the download arrive intact", and it is paired with the byte size. A 55-line pure-Lua
 * SHA-256 would be more code to get wrong for no gain against the actual threat, and — unlike
 * ccryptolib's — it has to work on a computer whose EasyKey install is broken.
 */
function fnv1a(text) {
  const buf = Buffer.from(text, "utf8");
  let h = 2166136261;
  for (const b of buf) {
    h = (h ^ b) >>> 0; // force unsigned: JS ^ yields int32, and the halves below assume unsigned
    // 32-bit multiply by 16777619 in 16-bit halves. The naive product reaches ~7.2e16, past the
    // 2^53 exact-integer limit of Lua's doubles, so both sides must split it the same way.
    const lo = h % 65536;
    const hi = (h - lo) / 65536;
    h = (((hi * 16777619) % 65536) * 65536 + lo * 16777619) % 4294967296;
  }
  return h.toString(16).padStart(8, "0");
}

/** A Lua table-constructor literal. Parsed on the computer with textutils.unserialise, so it is
 *  DATA, never executed as code — the updater must not be a remote-code-execution surface any
 *  wider than the files it is already fetching. */
function luaValue(v, indent) {
  const pad = "  ".repeat(indent);
  const padIn = "  ".repeat(indent + 1);
  if (typeof v === "string") return luaStr(v);
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) {
    if (v.length === 0) return "{}";
    return "{\n" + v.map((e) => padIn + luaValue(e, indent + 1) + ",").join("\n") + "\n" + pad + "}";
  }
  const keys = Object.keys(v);
  if (keys.length === 0) return "{}";
  return (
    "{\n" +
    keys
      .map((k) => `${padIn}[${luaStr(k)}] = ${luaValue(v[k], indent + 1)},`)
      .join("\n") +
    "\n" + pad + "}"
  );
}

/** @returns {{ version: string, text: string }} */
function buildManifest(roles) {
  const roleTable = {};
  const digestParts = [];
  for (const [role, spec] of Object.entries(roles)) {
    const files = spec.files.map(({ src, dst }) => {
      const body = readNormalized(src);
      const entry = {
        src,
        dst,
        size: Buffer.byteLength(body, "utf8"),
        sum: fnv1a(body),
      };
      digestParts.push(`${dst}:${entry.sum}:${entry.size}`);
      return entry;
    });
    roleTable[role] = { title: spec.title, basalt: !!spec.basalt, files };
  }

  // A CONTENT digest, not a timestamp: the version changes if and only if a shipped byte
  // changes. Regenerating with no source change must not make every computer look outdated.
  digestParts.sort();
  const version = crypto.createHash("sha256").update(digestParts.join("\n")).digest("hex").slice(0, 12);

  const updaterBody = fs.existsSync(path.join(ROOT, "easykey_suite.lua"))
    ? readNormalized("easykey_suite.lua")
    : null;

  const manifest = {
    version,
    schema: CONFIG_SCHEMA,
    base: SOURCE_BASE,
    basalt: BASALT_URL,
    // So the updater can tell you IT is out of date. It deliberately does not replace itself
    // mid-run — rewriting the program you are executing is a good way to end up with neither
    // version working.
    updater: updaterBody
      ? { size: Buffer.byteLength(updaterBody, "utf8"), sum: fnv1a(updaterBody) }
      : { size: 0, sum: "00000000" },
    roles: roleTable,
  };

  const text =
    "-- EasyKey release manifest. GENERATED by tools/gen_installers.js — do not edit by hand.\n" +
    "--\n" +
    "-- Read by easykey_suite.lua over HTTPS. Parsed with textutils.unserialise, so this is a\n" +
    "-- plain data table: no function calls, no `return`, nothing executable.\n" +
    "--\n" +
    "-- `sum` is FNV-1a 32-bit over the file's LF-normalised bytes, paired with `size`. It answers\n" +
    "-- \"did this change\" and \"did the download arrive intact\"; the trust root is HTTPS to the\n" +
    "-- pinned raw.githubusercontent.com URL, not this checksum.\n" +
    "--\n" +
    "-- `version` is a digest of every file's sum+size, so it moves only when shipped bytes move.\n" +
    "-- `schema` is the persisted-config generation; a bump means saved settings need backing up.\n" +
    luaValue(manifest, 0) +
    "\n";

  return { version, text };
}

function luaStr(s) {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

/**
 * Refuse to ship an installer that is missing a module its own code requires.
 *
 * This exists because a role once shipped without easykey/link.lua: the source tree had
 * it so every test passed, but the manifest didn't list it, and the installed server
 * died on boot with "module 'easykey.link' not found". Adding a file to the repo must
 * never again be enough to make it *look* installed.
 *
 * Only our own namespaces are checked; basalt/ecnet2/ccryptolib/cc.* resolve elsewhere.
 * Dynamic requires (launch.lua builds its module name at runtime) can't be seen here —
 * the boot check in tests/verify_installers.sh covers those.
 */
function missingModules(files) {
  const embedded = new Set(files.map((f) => f.dst));
  const problems = [];
  for (const { src, dst } of files) {
    if (!/^(easykey\/|shared\/|startup\.lua)/.test(dst)) continue; // skip vendored libs
    const body = readNormalized(src);
    for (const m of body.matchAll(/require\s*\(?\s*["']([\w.]+)["']/g)) {
      const mod = m[1];
      if (!/^(easykey|shared)\./.test(mod)) continue;
      const target = mod.replace(/\./g, "/") + ".lua";
      if (!embedded.has(target)) problems.push(`${dst} requires '${mod}' but ${target} is not embedded`);
    }
  }
  return problems;
}

function buildInstaller(role, spec, version) {
  const filesLua = spec.files
    .map(({ src, dst }) => {
      const b64 = Buffer.from(readNormalized(src), "utf8").toString("base64");
      return `  [${luaStr(dst)}] = ${luaStr(b64)},`;
    })
    .join("\n");

  const basaltBlock = spec.basalt
    ? `
-- Basalt (pinned build) — only the pocket UI needs it.
local BASALT_URL = ${luaStr(BASALT_URL)}
local ok, body = pcall(function()
  local h = http and http.get(BASALT_URL); if not h then return nil end
  local b = h.readAll(); h.close(); return b
end)
local compiles = ok and type(body) == "string" and #body > 1000 and (load or loadstring)(body) ~= nil
if compiles then
  writeFile("/basalt.lua", body)
  print(" + basalt.lua (" .. #body .. " bytes)")
else
  print(" ! basalt.lua download failed/incomplete (the UI needs it)")
  print("   retry the installer, or:  wget " .. BASALT_URL .. " basalt.lua")
end
`
    : `
-- (this role does not use Basalt)
`;

  const modemNote =
    role === "pocket"
      ? "Attach an ENDER MODEM pocket upgrade before running."
      : (role === "server" || role === "manual" || role === "elevator")
        ? "Attach an ENDER MODEM, and a MONITOR for the UI (optional)."
        : "Attach an ENDER MODEM to this computer before running.";

  return `-- ===================================================================
-- EasyKey -- ${spec.title} installer  (role: easykey:${role})
-- Generated ${new Date().toISOString()}
--
-- Usage:  run this file on the target computer (pastebin run / wget run).
-- ${modemNote}
-- Writes only the files this role needs (including the bundled ecnet2 +
-- ccryptolib crypto libraries) and sets role.txt automatically.
-- ===================================================================

local SYSTEM  = "easykey"
local ROLE    = ${luaStr(role)}
local TITLE   = ${luaStr(spec.title)}
-- Recorded on the computer so easykey_suite.lua knows what generation is installed. Not a
-- config file: it is the updater's bookkeeping and is safe to delete (you just lose the ability
-- to detect a config-schema bump, and the next update will assume the worst and back up).
local VERSION = ${luaStr(version)}
local SCHEMA  = ${CONFIG_SCHEMA}

local FILES = {
${filesLua}
}

-- Base64 decoder. Table-driven: this installer carries ~200KB of embedded crypto,
-- and a naive gsub-per-char decoder makes that painfully slow in CC.
local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, #B do DEC[B:sub(i, i)] = i - 1 end

local function b64decode(data)
  data = data:gsub("[^" .. B .. "=]", "")
  local out, n = {}, 0
  local acc, bits = 0, 0
  for i = 1, #data do
    local c = data:sub(i, i)
    if c ~= "=" then
      acc = acc * 64 + DEC[c]
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local byte = math.floor(acc / 2 ^ bits) % 256
        acc = acc % 2 ^ bits -- keep only the leftover bits, or acc overflows to
                             -- float imprecision partway through a large file
        n = n + 1
        out[n] = string.char(byte)
      end
    end
  end
  return table.concat(out)
end

local function writeFile(p, content)
  local dir = fs.getDir(p)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(p, "w"); f.write(content); f.close()
end

term.clear(); term.setCursorPos(1, 1)
print("Installing EasyKey: " .. TITLE)
print("(unpacking encrypted-networking libs, please wait)")
local n = 0
for p, data in pairs(FILES) do writeFile("/" .. p, b64decode(data)); n = n + 1 end
print(" + " .. n .. " files written")
${basaltBlock}
do
  local f = fs.open("/easykey_version.txt", "w")
  f.write(("version=%s\\nschema=%d\\nrole=%s\\n"):format(VERSION, SCHEMA, ROLE))
  f.close()
end

if fs.exists("/role.txt") then
  local f = fs.open("/role.txt", "r"); local cur = f.readLine(); f.close()
  print("role.txt already set to: " .. tostring(cur) .. " (delete it to change)")
else
  local f = fs.open("/role.txt", "w"); f.write(SYSTEM .. ":" .. ROLE); f.close()
  print("Wrote role.txt = " .. SYSTEM .. ":" .. ROLE)
end
print("Version " .. VERSION .. " (schema " .. SCHEMA .. ")")
print("Reboot to start EasyKey (" .. ROLE .. ").")
print("Later: run easykey_suite.lua to update in place.")
`;
}

// The completeness check runs BEFORE anything is written, for every role. A manifest that
// promised a file the installer didn't ship would send the updater chasing a 404, so the guard
// now protects both outputs — and it fails the whole run rather than writing a good manifest
// alongside a broken installer.
let failed = false;
for (const [role, spec] of Object.entries(ROLES)) {
  const problems = missingModules(spec.files);
  if (problems.length) {
    failed = true;
    console.error(`\nERROR: role '${role}' would be incomplete:`);
    for (const p of problems) console.error("  - " + p);
  }
}
if (failed) {
  console.error("\nNothing written. Add the missing file(s) to the manifest in this file.");
  process.exit(1);
}

const { version, text: manifestText } = buildManifest(ROLES);

for (const [role, spec] of Object.entries(ROLES)) {
  const outPath = path.join(ROOT, `install_easykey_${role}.lua`);
  const body = buildInstaller(role, spec, version);
  fs.writeFileSync(outPath, body);
  console.log(
    `wrote ${path.basename(outPath)}  (${spec.files.length} files${spec.basalt ? " + basalt" : ""}, ${(body.length / 1024).toFixed(0)} KB)`
  );
}

fs.writeFileSync(path.join(ROOT, "manifest.lua"), manifestText);
const fileCount = Object.values(ROLES).reduce((n, s) => n + s.files.length, 0);
console.log(
  `wrote manifest.lua       (version ${version}, schema ${CONFIG_SCHEMA}, ` +
    `${Object.keys(ROLES).length} roles / ${fileCount} entries)`
);
