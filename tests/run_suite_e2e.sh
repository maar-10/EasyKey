#!/usr/bin/env bash
# Full end-to-end confirmation of the EasyKey Suite across a MIXED-VERSION fleet.
#
# Six simulated computers, each its own CraftOS-PC data directory (so each has its own disk and
# its own idea of what version it is on):
#
#   installed by the SUITE, from the current release
#     elevmon    via the interactive role prompt   (exercises first-time setup with no arguments)
#     elevator   via `easykey_suite.lua elevator`
#
#   installed by an OLD release's self-extracting installer (v18, the release before elevators)
#     server     -- the one that MUST be updated: an old server cannot approve an elevator
#     manual     -- expected to keep working untouched
#     control    -- expected to keep working untouched
#     pocket     -- expected to keep working untouched, elevator floors included
#
# Each computer then gets a realistic configuration written with the REAL logic modules (a hashed
# key through KeyStore, panel controls through Panel, lifts through Elevator, ...), is booted, and
# is asked what the Suite thinks of it. Then everything outdated is updated and all of it is
# re-checked: configs intact, key still verifies, still boots, now up to date.
#
# A separate pass loads the old and current trees side by side to pin down what genuinely breaks
# across versions and what does not.
#
# Needs: CraftOS-PC, python (to serve the release mirror), and the v18 backup folder.
set -euo pipefail

EASYKEY="$(cd "$(dirname "$0")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="${TMPDIR:-/tmp}/easykey_e2e"
SERVE="$WORK/serve"
PORT="${EASYKEY_E2E_PORT:-8741}"

# The "old release" the outdated computers get installed from. v18 predates the elevator work,
# which is what makes it a meaningful old version rather than a cosmetic one.
OLD="$EASYKEY/backup/2026-07-19_EasyKey_v18_tworow_transparent_widgets_contrast"
[ -d "$OLD" ] || { echo "old backup not found: $OLD"; exit 1; }

rm -rf "$WORK"
mkdir -p "$SERVE"

# ---------- the release mirror (what the Suite fetches from) ----------
cp "$EASYKEY/manifest.lua" "$EASYKEY/startup.lua" "$EASYKEY/easykey_suite.lua" "$SERVE/"
for d in easykey shared vendor; do mkdir -p "$SERVE/$d"; cp -r "$EASYKEY/$d/." "$SERVE/$d/"; done

port_free() { ! curl -fsS --max-time 1 "http://127.0.0.1:$1/" -o /dev/null 2>/dev/null; }
for _ in $(seq 1 20); do port_free "$PORT" && break; PORT=$((PORT + 1)); done
port_free "$PORT" || { echo "no free port near $PORT"; exit 1; }
python -m http.server "$PORT" --directory "$SERVE" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
for _ in $(seq 1 40); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null 2>/dev/null && break
  sleep 0.25
done
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null \
  || { echo "mirror did not come up"; exit 1; }
MIRROR="http://127.0.0.1:$PORT"

# Iterating on one computer is much faster than the whole fleet: E2E_ROLES="control" limits it.
ALL_SUITE_ROLES="elevator elevmon"
ALL_OLD_ROLES="server manual control pocket"
if [ -n "${E2E_ROLES:-}" ]; then
  keep() { for r in $E2E_ROLES; do [ "$r" = "$1" ] && return 0; done; return 1; }
  f=""; for r in $ALL_SUITE_ROLES; do keep "$r" && f="$f $r"; done; ALL_SUITE_ROLES="${f# }"
  f=""; for r in $ALL_OLD_ROLES; do keep "$r" && f="$f $r"; done; ALL_OLD_ROLES="${f# }"
  echo "(limited to: $E2E_ROLES)"
fi
FLEET="$ALL_SUITE_ROLES $ALL_OLD_ROLES"
echo "release mirror: $MIRROR   old release: $(basename "$OLD")"
echo ""

# CraftOS-PC blocks private ranges by default; allow localhost.
craftos_config() {
  mkdir -p "$1/config"
  printf '{ "http_enable": true, "http_whitelist": ["*"], "http_blacklist": [] }' > "$1/config/global.json"
}

# ---------- run one phase on one computer ----------
FAILED=0
run_phase() {
  local role="$1" phase="$2" probe="$3"
  local data="$WORK/$role/data" c0="$WORK/$role/data/computer/0"
  printf '%s' "$phase" > "$c0/pc_phase.txt"
  # --script, NOT /startup.lua. Overwriting startup.lua would make the probe itself a modified
  # release file, and the Suite would then correctly report the computer as outdated -- a test
  # artefact that looked exactly like a real bug for a while.
  cp "$EASYKEY/tests/$probe" "$c0/e2e_probe.lua"
  rm -f "$c0/pc_result.txt"
  timeout 240 "$CRAFTOS" --headless -d "$data" --script "$c0/e2e_probe.lua" >/dev/null 2>&1 || true
  if [ -f "$c0/pc_result.txt" ]; then
    cat "$c0/pc_result.txt"
    if grep -q "FAIL" "$c0/pc_result.txt"; then FAILED=$((FAILED + 1)); fi
  else
    echo "=== $role / $phase === (NO RESULT -- hung or crashed)"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

# ---------- lay out a computer ----------
prepare_pc() {
  local role="$1" expect_outdated="$2"
  local data="$WORK/$role/data" c0="$WORK/$role/data/computer/0"
  mkdir -p "$c0"
  craftos_config "$data"
  printf '%s' "$role"    > "$c0/pc_role.txt"
  printf '%s' "$MIRROR"  > "$c0/mirror.txt"
  printf '%s' "$MIRROR"  > "$c0/easykey_suite_src.txt"
  printf '%s' "$expect_outdated" > "$c0/pc_expect_outdated.txt"
  cp "$EASYKEY/easykey_suite.lua" "$c0/easykey_suite.lua"
  # Basalt is pre-seeded for the UI roles: it comes from its own third-party pinned URL, and
  # pulling 300 KB per computer from the real internet would make this slow and flaky. Recording
  # the URL as well keeps the Suite from deciding it needs re-fetching. (The Basalt download path
  # itself is covered by tests/run_suite.sh scenarios 8-9.)
  case "$role" in
    pocket|server|manual|elevator)
      cp "$EASYKEY/vendor/basalt-full.lua" "$c0/basalt.lua"
      grep -o '"basalt"\] = "[^"]*"' "$EASYKEY/manifest.lua" | head -1 \
        | sed 's/.*= "//; s/"$//' > "$c0/easykey_basalt_url.txt"
      ;;
  esac
}

# ---------- install via the OLD self-extracting installer ----------
install_old() {
  local role="$1"
  local c0="$WORK/$role/data/computer/0"
  cp "$OLD/install_easykey_${role}.lua" "$c0/installer.lua"
  cat > "$c0/run_install.lua" <<'EOF'
local ok, err = pcall(function() shell.run("/installer.lua") end)
local f = fs.open("/install_log.txt", "w")
f.writeLine("ran=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
f.close()
os.shutdown()
EOF
  rm -f "$c0/install_log.txt"
  timeout 240 "$CRAFTOS" --headless -d "$WORK/$role/data" --script "$c0/run_install.lua" >/dev/null 2>&1 || true
  echo "  [$role] old installer: $(cat "$c0/install_log.txt" 2>/dev/null || echo 'NO LOG')"
}

# ---------- install via the Suite ----------
install_suite() {
  local role="$1" answers="$2"   # answers empty = pass the role as an argument
  local c0="$WORK/$role/data/computer/0"
  if [ -z "$answers" ]; then
    cat > "$c0/run_install.lua" <<EOF
local ok, err = pcall(function() shell.run("/easykey_suite.lua", "$role") end)
local f = fs.open("/install_log.txt", "w")
f.writeLine("ran=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
f.close()
os.shutdown()
EOF
  else
    # exercise the interactive first-time-setup prompt
    cat > "$c0/run_install.lua" <<EOF
local answers = { $answers }
local realRead = _G.read
_G.read = function()
  if #answers == 0 then error("unexpected prompt", 0) end
  return table.remove(answers, 1)
end
local ok, err = pcall(function() shell.run("/easykey_suite.lua") end)
_G.read = realRead
local f = fs.open("/install_log.txt", "w")
f.writeLine("ran=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))) ..
  "  prompted=" .. tostring(#answers == 0))
f.close()
os.shutdown()
EOF
  fi
  rm -f "$c0/install_log.txt"
  timeout 240 "$CRAFTOS" --headless -d "$WORK/$role/data" --script "$c0/run_install.lua" >/dev/null 2>&1 || true
  echo "  [$role] Suite install: $(cat "$c0/install_log.txt" 2>/dev/null || echo 'NO LOG')"
}

# =====================================================================
echo "### PHASE 1  build the fleet"
# =====================================================================
for role in $ALL_SUITE_ROLES; do prepare_pc "$role" "no"; done
for role in $ALL_OLD_ROLES; do prepare_pc "$role" "yes"; done

for role in $ALL_SUITE_ROLES; do
  if [ "$role" = "elevmon" ]; then
    install_suite elevmon '"6"'   # role 6 = elevmon, chosen at the interactive prompt
  else
    install_suite "$role" ""      # named on the command line
  fi
done
for role in $ALL_OLD_ROLES; do install_old "$role"; done
echo ""

# =====================================================================
echo "### PHASE 2  configure + boot each computer on the version it was installed with"
# =====================================================================
for role in $FLEET; do run_phase "$role" install e2e_pc.lua; done

# =====================================================================
echo "### PHASE 3  what does the Suite think of each computer?"
# =====================================================================
for role in $FLEET; do run_phase "$role" check e2e_pc.lua; done

# =====================================================================
echo "### PHASE 4  cross-version compatibility: what works, what breaks"
# =====================================================================
COMPAT="$WORK/compat/data/computer/0"
mkdir -p "$COMPAT/cur" "$COMPAT/old"
craftos_config "$WORK/compat/data"
for d in easykey shared; do
  mkdir -p "$COMPAT/cur/$d" "$COMPAT/old/$d"
  cp -r "$EASYKEY/$d/." "$COMPAT/cur/$d/"
  cp -r "$OLD/$d/." "$COMPAT/old/$d/"
done
cp -r "$EASYKEY/vendor/ecnet2" "$COMPAT/ecnet2"
cp -r "$EASYKEY/vendor/ccryptolib" "$COMPAT/ccryptolib"
cp "$EASYKEY/tests/e2e_compat.lua" "$COMPAT/e2e_probe.lua"
rm -f "$COMPAT/pc_result.txt"
timeout 180 "$CRAFTOS" --headless -d "$WORK/compat/data" --script "$COMPAT/e2e_probe.lua" >/dev/null 2>&1 || true
if [ -f "$COMPAT/pc_result.txt" ]; then
  cat "$COMPAT/pc_result.txt"
  grep -q "FAIL" "$COMPAT/pc_result.txt" && FAILED=$((FAILED + 1)) || true
else
  echo "=== compat === (NO RESULT)"; FAILED=$((FAILED + 1))
fi
echo ""

# =====================================================================
echo "### PHASE 5  update every computer with the Suite"
# =====================================================================
for role in $FLEET; do run_phase "$role" update e2e_pc.lua; done

# =====================================================================
echo "### PHASE 6  re-verify: configs intact, still boots, now current"
# =====================================================================
for role in $FLEET; do run_phase "$role" reverify e2e_pc.lua; done

# =====================================================================
echo "======================================================================"
if [ "$FAILED" -eq 0 ]; then
  echo "E2E_OK  -- every phase green across all six computers"
else
  echo "E2E_FAIL -- $FAILED phase(s) reported a failure"
fi
echo "======================================================================"
[ "$FAILED" -eq 0 ]
