#!/usr/bin/env bash
# Boots the server and control roles headless (with an emulated modem) to catch
# runtime init errors the pure tests + compile checks can't.
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"

boot_one() {
  local role="$1"
  local data="${TMPDIR:-/tmp}/easykey_boot_${role}/data"
  local c0="$data/computer/0"
  rm -rf "$c0"; mkdir -p "$c0"
  for d in shared easykey; do cp -r "$EASYKEY/$d" "$c0/$d"; done
  cp -r "$EASYKEY/vendor/ecnet2" "$c0/ecnet2"
  cp -r "$EASYKEY/vendor/ccryptolib" "$c0/ccryptolib"
  cp "$EASYKEY/tests/boot_smoke.lua" "$c0/startup.lua"
  printf '%s' "$role" > "$c0/which_role.txt"

  # pocket + server both render Basalt UIs
  if [ "$role" = "pocket" ] || [ "$role" = "server" ] || [ "$role" = "manual" ]; then
    if [ -f "$EASYKEY/basalt.lua" ]; then cp "$EASYKEY/basalt.lua" "$c0/basalt.lua"
    elif [ -f "$EASYKEY/../basalt.lua" ]; then cp "$EASYKEY/../basalt.lua" "$c0/basalt.lua"
    else echo "basalt.lua not found (pocket boot needs it)"; return; fi
  fi

  rm -f "$c0/boot_result.txt"
  timeout 60 "$CRAFTOS" --headless -d "$data" >/dev/null 2>&1 || true
  echo "=== boot ${role} ==="
  cat "$c0/boot_result.txt" 2>/dev/null || echo "(no result)"
  echo ""
}

boot_one server
boot_one control
boot_one pocket
boot_one manual
