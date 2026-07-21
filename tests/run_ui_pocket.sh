#!/usr/bin/env bash
# Headless render smoke test for the pocket UI. Deploys EasyKey + the bundled
# Basalt build into a CraftOS-PC computer, renders the screens, prints the dumps.
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
DATA="${TMPDIR:-/tmp}/easykey_ui/data"
C0="$DATA/computer/0"

rm -rf "$C0"; mkdir -p "$C0"
for d in shared easykey tests; do cp -r "$EASYKEY/$d" "$C0/$d"; done
cp -r "$EASYKEY/vendor/ecnet2" "$C0/ecnet2"
cp -r "$EASYKEY/vendor/ccryptolib" "$C0/ccryptolib"

# Always test against the FULL Basalt build (what the pockets actually run), vendored at
# the same pinned commit the installer downloads. No fallback: a wrong build must fail loud.
BASALT="$EASYKEY/vendor/basalt-full.lua"
[ -f "$BASALT" ] || { echo "vendor/basalt-full.lua not found (UI tests need the full Basalt build)"; exit 1; }
cp "$BASALT" "$C0/basalt.lua"

cp "$EASYKEY/tests/ui_render_pocket.lua" "$C0/startup.lua"

rm -f "$C0/results.txt"
timeout 60 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true

echo "=== results.txt ==="
cat "$C0/results.txt" 2>/dev/null || echo "(no results)"
for f in ui_pocket_locked ui_pocket_secure ui_pocket_tab_controls ui_pocket_tab_use ui_pocket_switch_on ui_pocket_panel_denied; do
    echo ""; echo "=== $f ==="
    cat "$C0/$f.txt" 2>/dev/null || echo "(missing)"
done
