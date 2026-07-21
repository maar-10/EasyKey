#!/usr/bin/env bash
# Copies EasyKey into a headless CraftOS-PC computer and runs the test suite.
# Requires CraftOS-PC installed (console build for stdout/file output).
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
DATA="${TMPDIR:-/tmp}/easykey_test/data"
C0="$DATA/computer/0"

rm -rf "$C0"
mkdir -p "$C0"

# Deploy EasyKey sources into the computer root (shared + easykey + tests).
for d in shared easykey tests; do
    cp -r "$EASYKEY/$d" "$C0/$d"
done

# Vendored crypto libs must sit at the root: their own require() paths are
# "ecnet2.x" / "ccryptolib.x" (same mapping the installers apply).
cp -r "$EASYKEY/vendor/ecnet2" "$C0/ecnet2"
cp -r "$EASYKEY/vendor/ccryptolib" "$C0/ccryptolib"

# Test bootstrap: set module path, run tests, power off.
cat > "$C0/startup.lua" <<'EOF'
package.path = "/?.lua;/?/init.lua;" .. package.path
local ok, err = pcall(function() require("tests.run_all") end)
if not ok then
    local f = fs.open("/test_results.txt", "w")
    f.writeLine("HARNESS ERROR: " .. tostring(err))
    f.close()
end
os.shutdown()
EOF

rm -f "$C0/test_results.txt"
timeout 60 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true

echo "=== test_results.txt ==="
cat "$C0/test_results.txt" 2>/dev/null || echo "(no results — harness did not produce output)"
