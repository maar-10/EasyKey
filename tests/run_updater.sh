#!/usr/bin/env bash
# Scenario test for easykey_update.lua.
#
# The updater talks HTTP, so this serves the repo from localhost and points the updater at it
# with /easykey_update_src.txt. Two mirrors are served:
#
#   good/     an exact copy of the repo
#   corrupt/  the same, except easykey/link.lua has been tampered with so its bytes no longer
#             match the manifest checksum -- that is how the all-or-nothing abort gets tested
#
# CraftOS-PC needs HTTP enabled and localhost allowed; the config written below does both.
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="${TMPDIR:-/tmp}/easykey_updater"
DATA="$WORK/data"
C0="$DATA/computer/0"
SERVE="$WORK/serve"
PORT="${EASYKEY_TEST_PORT:-8731}"

rm -rf "$WORK"
mkdir -p "$C0" "$SERVE"

# ---------- build the two mirrors ----------
for m in good corrupt; do
  mkdir -p "$SERVE/$m"
  cp "$EASYKEY/manifest.lua" "$SERVE/$m/"
  cp "$EASYKEY/startup.lua" "$SERVE/$m/"
  cp "$EASYKEY/easykey_update.lua" "$SERVE/$m/"
  for d in easykey shared vendor; do
    mkdir -p "$SERVE/$m/$d"
    cp -r "$EASYKEY/$d/." "$SERVE/$m/$d/"
  done
done
# the tamper: same path, different bytes, so the manifest checksum no longer matches
printf '%s\n' '-- TAMPERED IN TRANSIT' >> "$SERVE/corrupt/easykey/link.lua"

# ---------- serve them ----------
# A stray server from an earlier interrupted run (e.g. this script's output piped into `head`,
# which SIGPIPEs it before the trap fires) would still answer on this port while serving a
# directory that has since been deleted -- so the readiness check below would pass and every
# fetch would 404. Find a port nobody is listening on instead of assuming one.
port_free() {
  ! curl -fsS --max-time 1 "http://127.0.0.1:$1/" -o /dev/null 2>/dev/null
}
for _ in $(seq 1 20); do
  if port_free "$PORT"; then break; fi
  echo "port $PORT is already in use; trying $((PORT + 1))"
  PORT=$((PORT + 1))
done
port_free "$PORT" || { echo "could not find a free port near $PORT"; exit 1; }

python -m http.server "$PORT" --directory "$SERVE" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
# INT/TERM as well as EXIT, so a SIGPIPE'd or Ctrl-C'd run still takes its server down
trap cleanup EXIT INT TERM

# Wait for OUR server, and prove it is ours by fetching a path only this mirror has.
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/good/manifest.lua" -o /dev/null 2>/dev/null
  then break; fi
  sleep 0.25
done
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/good/manifest.lua" -o /dev/null \
  || { echo "local mirror did not come up on port $PORT"; exit 1; }
echo "serving both mirrors on 127.0.0.1:$PORT"

# ---------- checksum agreement vectors (Node side) ----------
# If the generator's fnv1a and the updater's Lua checksum ever drift, every file would look
# permanently outdated. Generate the expected sums here from the SAME function the manifest uses.
node -e '
const fs = require("fs");
const path = require("path");
const ROOT = process.argv[1];
// exercise the exact fnv1a from the generator by re-deriving it the same way
function fnv1a(text) {
  const buf = Buffer.from(text, "utf8");
  let h = 2166136261;
  for (const b of buf) {
    h = (h ^ b) >>> 0;
    const lo = h % 65536;
    const hi = (h - lo) / 65536;
    h = (((hi * 16777619) % 65536) * 65536 + lo * 16777619) % 4294967296;
  }
  return h.toString(16).padStart(8, "0");
}
const cases = [
  "",
  "a",
  "hello world",
  "\n",
  "-- a Lua comment\nreturn {}\n",
  "äöü — non-ascii bytes",
  "x".repeat(300),              // crosses the 256-byte batching boundary
  "y".repeat(256),              // exactly one batch
  "z".repeat(257),              // one batch plus one
  fs.readFileSync(path.join(ROOT, "easykey/protocol.lua"), "utf8").replace(/\r\n/g, "\n"),
  fs.readFileSync(path.join(ROOT, "easykey/logic/elevator.lua"), "utf8").replace(/\r\n/g, "\n"),
];
const luaStr = (s) => JSON.stringify(s)
  .replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => "\\" + parseInt(h, 16));
const rows = cases.map((c) => `  { text = ${luaStr(c)}, sum = "${fnv1a(c)}" },`);
process.stdout.write("{\n" + rows.join("\n") + "\n}\n");
' "$EASYKEY" > "$C0/fnv_vectors.txt"

# ---------- lay out the computer ----------
printf 'http://127.0.0.1:%s/good' "$PORT"    > "$C0/mirror_base.txt"
printf 'http://127.0.0.1:%s/corrupt' "$PORT" > "$C0/mirror_corrupt.txt"
printf 'http://127.0.0.1:%s/good' "$PORT"    > "$C0/easykey_update_src.txt"
cp "$EASYKEY/easykey_update.lua" "$C0/easykey_update.lua"
cp "$EASYKEY/tests/updater_probe.lua" "$C0/startup.lua"

# CraftOS-PC: allow HTTP to localhost (blocked by default as a private range).
mkdir -p "$DATA/config"
cat > "$DATA/config/global.json" <<'EOF'
{
  "http_enable": true,
  "http_whitelist": ["*"],
  "http_blacklist": [],
  "httpEnable": true,
  "http": { "enabled": true, "rules": [ { "host": "*", "action": "allow" } ] }
}
EOF

rm -f "$C0/results.txt"
timeout 180 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true

echo "=== results.txt ==="
cat "$C0/results.txt" 2>/dev/null || echo "(no results -- did the probe run?)"
