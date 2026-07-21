# EasyKey — encrypted proximity door-key system (CC:Tweaked + Basalt 2.0)

A carry-around **pocket key tool** for your Minecraft base. Enter the right key on a
custom on-screen keypad and your pocket computer becomes **secure for 5 minutes** —
while secure, base doors open automatically as you walk up to them, and lock again when
you leave or the timer runs out.

**All radio traffic is encrypted and replay-protected** ([ecnet2](https://github.com/migeyel/ecnet):
Noise XK, X25519 + AEAD). Nothing worth stealing lives on a pocket or a door
controller — the keys live only on the server, stored hashed.

Built for Minecraft 1.21.1 (CC:Tweaked, Basalt 2.0, Create / Create: Aeronautics /
Immersive Engineering). Self-contained under `EasyKey/`; it reuses the first project's
building blocks by copying them in, and never touches the other systems.

```
  pocket(s) ──encrypted tunnel──► server (VAULT: keys, approvals, sessions)
       │                             │
       │                             └──encrypted tunnel──► control PC(s) + manual PC(s)
       └────encrypted tunnels────────────────────────────►  (secure-set)
              (presence + distance)      → control: doors open by proximity
              (panel taps + feedback)    → manual: redstone on button/switch taps
```

## Computers & parts

| Role | Computer | Modem | Count |
|------|----------|-------|-------|
| **pocket** | **Advanced Pocket Computer** (needs colour + a clickable screen) | **ender modem** pocket upgrade | one per person |
| **server** | **advanced** computer + **advanced monitor** (for the operations UI) | ender modem | exactly one |
| **control** | normal computer is enough (proximity doors) | ender modem | one per door area |
| **manual** | **advanced** computer + **advanced monitor** (remote panel) | ender modem | as many as you like |

There are two kinds of control PC, and they differ only in what pulls the trigger:

- **control** — fires on **proximity**: walk up with a secure pocket and the door opens.
- **manual** — fires on **intent**: a secure pocket taps a button or flips a switch in its
  own `PANEL` tab. Nothing opens by walking past.

Why advanced pocket: the keypad is a touch UI, and only advanced pocket computers fire
click events. Why ender modems: unlimited range **and** they report block `distance`,
which is how a control PC knows a pocket is close enough. A message from another
dimension reports no distance and never opens a door.

> **Placement:** a control PC measures distance to **itself**, so put each control PC
> near the door(s) it drives. Each door's trigger range is tunable.
>
> **Put the server somewhere protected.** It is the only machine holding anything worth
> stealing.

## Install (per computer)

Host the installers on pastebin or your GitHub, then on each computer:

```
wget run <raw-url-of-the-matching-installer>
```

- `install_easykey_pocket.lua`  → advanced pocket computers (also downloads Basalt)
- `install_easykey_server.lua`  → the one server
- `install_easykey_control.lua` → each proximity door controller
- `install_easykey_manual.lua`  → each manual panel PC

Each installer is self-contained (~300 KB): it embeds only the files that role needs
**plus the pinned ecnet2 + ccryptolib crypto libraries**, so there is no half-downloaded
install. It sets `role.txt` for you. Attach the ender modem, then reboot — `startup.lua`
launches the right program automatically. Unpacking the crypto libs takes a few seconds.

## First-time setup

### 1. Start the server
Attach a monitor (any side — it's auto-detected; a **5x3** gives a comfortable 83x32).
With no monitor it falls back to the computer's own screen, so you can still set it up.

The UI is:
- **top bar** — the server's **fingerprint** (what you confirm when pairing), Minecraft
  day + time, and the real-life date + time,
- **console** (left) — a scrollable, timestamped log of what the server actually *did*.
  Routine housekeeping (the secure-set push, clock ticks) is deliberately **not** logged;
  if it were, real events would scroll past in seconds,
- **tabs** (right) — every manual job: `Pend` / `Keys` / `Devs` / `Live`.

The first run seeds `/easykey_keys.cfg` from `Config.seedKeys` (default key `1234`).

### 2. Pair each device (once)
A fresh pocket/control searches for the server and shows the candidates' fingerprints.
**Check one against the server's top bar and tap it.** That comparison is the security
step — it's what stops an impostor from becoming your server. Once confirmed, the
address is pinned forever (`/easykey_server.txt`).

### 3. Approve each device (once)
A newly paired device appears on the server's **`Pend`** tab. **Tap the row** (it
highlights blue), then tap **APPROVE** (or **REJECT**). There is no auto-trust — approval
is the only way in. The device shows "awaiting approval" until you do.

Approve your control PCs too; the server then tells each approved pocket which controls
to ping.

### 3b. Set your own key
On the **`Keys`** tab tap **ADD KEY**, type it on the keypad, press **OK**. It is hashed
immediately — masked as you type, never logged or shown. Select a key and tap **REMOVE**
to delete it (the server refuses to remove the last one, so you can't lock yourself out).

Keys must be typeable on the pocket keypad: **digits, `*` and `#`**. Each key gets a
label, which is what the console shows as "who unlocked".

Once your own key works, remove the default `1234` **and** clear `Config.seedKeys` in
`easykey/config.lua`, so no plaintext key is left sitting in a config file.

### 3c. Revoking (takes effect immediately, no reboot)
- **`Devs`** → select a device → **REVOKE DEVICE**: drops its approval *and* any live
  session at once. The device's screen flips to "awaiting approval" and it reappears
  under `Pend`, so you can re-approve it live (REJECT clears it until it reconnects).
- **`Live`** → select a session → **REVOKE SESSION**: ends someone's 5 minutes now
  without un-trusting their device. Their pocket returns to LOCKED immediately.

### 4. Set up each control PC's outputs (on its own screen)
A control PC drives **every redstone channel it can reach**, discovered automatically:

- all 6 sides of the computer itself — `self/back`
- all 6 sides of every **redstone relay** on its wired network — `redstone_relay_3/left`
- the **16 colours** of any side you flip to bundled mode — `self/back:pink`

An IE interface/redstone connector just reads the signal on that side (or bundled
colour), so it needs no special setup: point it at a side and pick a type.

Its console lists every output with its type, range and live redstone state — read back
from the hardware, so a write that didn't take shows up. Keys:

| Key | Does |
|-----|------|
| `up`/`down` | select an output (`pageUp`/`pageDown` jumps) |
| `t` | cycle type: **off → toggle → press → off** |
| `n` | rename it (Enter commits, Tab cancels) |
| `r` | set its range in blocks (Enter commits) |
| `b` | flip that side between plain and **bundled** (16 colour channels) |

**Types**
- **off** — never emits. Every newly discovered output starts here, so a side that
  already has something wired to it can't fire until you deliberately arm it.
- **toggle** — ON for exactly as long as a secure pocket is within range (a lever).
- **press** — ONE pulse when a secure pocket **enters** range (a button). It will not
  fire again until **every** secure pocket has left range and someone re-enters. That
  re-arm rule is deliberate: repeated pulses would leave a complex Create door stuck
  half-open.

**Range** is per output, so a single PC can run an outer gate at 6 blocks and an inner
vault at 2. It's measured to the **control PC**, so place it near the doors it drives.

Nothing emits unless an authenticated pocket with a live, server-granted session is in
range — there is no code path from "no session" to "redstone on", and everything is
driven off at boot.

Settings persist in `/easykey_outputs.cfg` and `/easykey_sides.cfg`, both written by the
console rather than hand-edited.

### 5. Set up a manual panel PC (on its monitor)
Pair + approve it like any device (it appears under `Pend` as **manual**). Its UI is the
same shape as the server's — console on the left, tabs on the right:

- **Panel** — your buttons/switches with live state. **NEW** opens a form: type a name on
  the PC's keyboard, tap the type (button/switch), tap a target output, **SAVE**.
  **EDIT** / **DELETE** act on the selected row.
- **Outs** — every redstone channel found (same discovery as the door control);
  **BUNDLED ON/OFF** flips a side to its 16 colour channels.
- **Pock** — pockets nearby: distance, and `SECURE` / `denied` / `far`. **RANGE** and
  **GRACE** are set here (defaults: 100 blocks, 3s).

**button** = one pulse per tap. **switch** = flips and stays.

Whatever you define shows up in the **PANEL** tab of every pocket in range — including
pockets that aren't cleared, which see the buttons but get "access denied" if they tap.

**How a switch turns off.** A switch is *owned* by the pocket that turned it on:
- their **session ends or is revoked** → it drops **instantly** (authority is gone);
- they **walk out of range or their link hiccups** → it drops after the **3s grace**, so a
  brief step past the boundary doesn't kill a machine you're standing next to;
- once dropped, nothing is remembered — walking back in re-energises nothing;
- a **reboot** comes up cold.

**Feedback is real.** The pocket never moves a control by itself. The manual PC applies
the redstone, **reads it back**, and reports what the hardware is *actually* doing. So a
control that didn't fire visibly doesn't move, and you get a reason instead of a shrug:

| On the pocket | Means |
|---------------|-------|
| `out of range` | you're beyond that panel's range |
| `access denied` | in range, but the server hasn't cleared you |
| `signal error` | cleared and in range, but the redstone didn't do as asked — or the panel went quiet |

## Using it

1. The pocket shows Minecraft **day + time** (sun/moon indicator), the **real-life
   clock** (ticks every second), and a **LOCKED** status.
2. Tap **REQUEST KEY CHECK** → the server opens the **keypad** (digits `0–9`, `*`, `#`,
   plus `<` backspace, `X` cancel, `OK` submit; entry is masked). Layout is
   `Config.keypad.chars`.
3. Enter the key, press **OK**. Correct → **SECURE** with a live `MM:SS` countdown;
   wrong → "wrong key" plus a short retry cooldown.
4. While secure, walk up to any door — it opens within range and auto-closes as you
   leave. After 5 minutes the pocket relocks and you can request again.

Multiple people, multiple pockets and several valid keys all work at once.

## Security model — what's protected, and what isn't

**Protected**
- **Sniffing the radio gets nothing.** Every message rides an encrypted tunnel. The
  typed key never travels in the clear.
- **Replay is rejected** by the transport — you cannot record a door-opening ping and
  replay it later.
- **Identity can't be forged.** Every message's sender is a cryptographically
  authenticated address (a public key), not a claimed computer id. There are no bearer
  tokens to steal: v1 had them, v2 deletes the entire class of attack.
- **Reading the server's disk doesn't hand over the keys** — only salted, iterated
  SHA-256 hashes are stored (`Config.keyHashIterations`, default 4096).
- **Lost a pocket?** Revoke it on the server; it loses access on the next push (≤5s).

**Accepted limits (be honest with yourself about these)**
- **CC storage is plaintext.** Anyone holding a device can read its files. That's *why*
  the design puts no authorisation secret on a pocket: the real secret is the key in
  your head. A stolen **locked** pocket is worthless — its identity key alone opens
  nothing.
- A stolen **currently-secure** pocket is a stolen keycard: it works for the rest of its
  ≤5 minutes, unless you revoke it. Shorten `session_seconds` if that bothers you.
- **Short keys are guessable** regardless of hashing. Iterations buy time, not immunity —
  prefer a longer key.
- Anyone who can physically reach the **server** has already won. Protect it in-world.
- Discovery (pairing) is deliberately unauthenticated — it only carries a public key.
  The **fingerprint check is the security boundary**, so actually compare it.
- `random.initWithTiming()` seeds from VM timing noise (CC has no hardware entropy);
  this is ecnet2's own recommended approach, with its documented caveats.

## Tuning

`easykey/config.lua` (keep identical on every EasyKey computer):

- `timing.session_seconds` — how long "secure" lasts (default `300` = 5 min).
- `timing.ping_interval` / `secure_push` — presence + push cadence.
- `proximity.range` / `closeDelay` — door defaults (per-door overrides win).
- `keypad.chars` / `keypad.cols` — keypad buttons and grid width.
- `keyHashIterations` — key-hash cost.

There are **no modem channels to configure**: ecnet2 derives channels from the protocol
name.

## Running the tests (on your PC)

Requires CraftOS-PC (and Node to regenerate installers).

```bash
bash tests/run_headless.sh      # 363 tests: pure logic + a REAL encrypted handshake
bash tests/run_ui_pocket.sh     # renders every pocket screen (+ asserts nothing is invisible)
bash tests/run_ui_server.sh     # renders the server UI @ 83x32 (a 5x3 monitor)
bash tests/run_ui_interact.sh   # drives the server's buttons: selection -> action -> payload
bash tests/run_ui_manual.sh     # renders + drives the manual panel PC's UI
bash tests/run_boot_smoke.sh    # boots all 3 roles with an emulated modem
node tools/gen_installers.js    # regenerate installers (refuses to ship an incomplete one)
bash tests/verify_installers.sh # installs, compiles AND boots each role from its installer
```

The suite drives a genuine ecnet2 handshake between two identities over loopback modems,
asserting that the sender address is authenticated and that `distance` survives the
tunnel. The UI is tested in three layers, each one added after a bug that a shallower
layer couldn't see: **render** (layout), **colour** (readable — text-only dumps once
showed a "perfect" console that was black-on-black in-game), and **interaction**
(selection actually reaches the action).

**Not covered headless, verify in-game:** a true 3-computer round-trip (one CraftOS
computer can't be three), and click routing on a real monitor —
`basalt.update("mouse_click", …)` does not reach a window-backed frame, so clicks cannot
be simulated in this harness.

## File layout

```
startup.lua                 role launcher (reads role.txt "easykey:<role>")
shared/                     copies reused from project 1 (util, ui/kvstore)
easykey/
  config.lua                timing, keypad, proximity, file paths
  protocol.lua              v2 message types (no from/to/seq/tokens — the tunnel does it)
  secure_net.lua            encrypted transport wrapper over ecnet2
  discovery.lua             pairing: find the server, confirm its fingerprint
  launch.lua                role dispatch (requires only the active role)
  keystore.lua              THE VAULT: salted+iterated key hashes
  devices.lua               approved device addresses
  logic/                    PURE, unit-tested
    sessions.lua            server sessions, keyed by authenticated address
    outputs.lua             door-control machine (off/toggle/press, range, re-arm)
    panel.lua               manual-panel machine (button/switch, ownership, grace)
    keypad_model.lua        keypad entry buffer
  redstone_io.lua           control-PC hardware: sides, relays, bundled masks, feedback
  link.lua                  queues sends until an ecnet2 tunnel completes
  server.lua                vault + approvals + secure-set push (+ monitor UI)
  control.lua               proximity door driver + its console UI
  manual.lua                manual panel PC (redstone from pocket taps) + its UI
  pocket/                   Basalt pocket UI: run.lua, app.lua, views/
  ui/                       Basalt server UI: server_app.lua, keypad.lua (shared), views/
vendor/                     pinned ecnet2 + ccryptolib (MIT) — see vendor/README.md
tools/gen_installers.js     installer generator
tests/                      headless CraftOS-PC test + render + boot harness
```
