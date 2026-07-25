# EasyKey — encrypted proximity door-key system (CC:Tweaked + Basalt 2.0)

A carry-around **pocket key tool** for your Minecraft base. Enter the right key on a
custom on-screen keypad and your pocket computer becomes **secure for 5 minutes** —
while secure, base doors open automatically as you walk up to them, and lock again when
you leave or the timer runs out.

The same clearance drives two panels from the pocket's own screen: a **manual panel** of
buttons, switches and latches for gates and machinery, and an **elevator controller** that
turns a multi-floor Create lift into one call button per floor, showing you where the cabin
is.

**All radio traffic is encrypted and replay-protected** ([ecnet2](https://github.com/migeyel/ecnet):
Noise XK, X25519 + AEAD). Nothing worth stealing lives on a pocket or a door
controller — the keys live only on the server, stored hashed.

Built for Minecraft 1.21.1 (CC:Tweaked, Basalt 2.0, Create / Create: Aeronautics /
Immersive Engineering). Self-contained under `EasyKey/`; it reuses the first project's
building blocks by copying them in, and never touches the other systems.

```
  pocket(s) ──encrypted tunnel──► server (VAULT: keys, approvals, sessions)
       │                             │
       │                             ├─encrypted tunnel─► control / manual / elevator PC(s)
       │                             │                     (secure-set)
       │                             └─encrypted tunnel─► elevator monitor(s)
       │                                                   (which controllers to obey)
       └────encrypted tunnels────────────────────────────►
              (presence + distance)      → control:  doors open by proximity
              (panel taps + feedback)    → manual:   redstone on button/switch taps
              (panel taps + feedback)    → elevator: multi-floor lift calls
                                              │
                                              └─encrypted tunnel─► elevator monitor
                                                  (call pulses out, cabin position back)
```

## Computers & parts

| Role | Computer | Modem | Count |
|------|----------|-------|-------|
| **pocket** | **Advanced Pocket Computer** (needs colour + a clickable screen) | **ender modem** pocket upgrade | one per person |
| **server** | **advanced** computer + **advanced monitor** (for the operations UI) | ender modem | exactly one |
| **control** | normal computer is enough (proximity doors) | ender modem | one per door area |
| **manual** | **advanced** computer + **advanced monitor** (remote panel) | ender modem | as many as you like |
| **elevator** | **advanced** computer + **advanced monitor** (multi-floor lifts) | ender modem | as many as you like |
| **elevmon** | normal computer is enough (sits at a lift shaft) | ender modem | one per lift |

There are three kinds of control PC, and they differ only in what pulls the trigger:

- **control** — fires on **proximity**: walk up with a secure pocket and the door opens.
- **manual** — fires on **intent**: a secure pocket taps a button or flips a switch in its
  own `Gates`/`Lifts` tab. Nothing opens by walking past.
- **elevator** — fires on intent too, but is built for a **shaft with many floors**: every
  floor is one call button, and it knows *where the cabin is*. Use the manual panel for a
  simple one-shot lift; use this when there are floors to choose between.

**elevmon** is not a control at all — it is a reporter that also does the wiring. See
[Elevators](#elevators-multi-floor-lifts) below.

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

- `install_easykey_pocket.lua`   → advanced pocket computers (also downloads Basalt)
- `install_easykey_server.lua`   → the one server
- `install_easykey_control.lua`  → each proximity door controller
- `install_easykey_manual.lua`   → each manual panel PC
- `install_easykey_elevator.lua` → each multi-floor elevator controller
- `install_easykey_elevmon.lua`  → the PC at each lift shaft

Each installer is self-contained (~300 KB): it embeds only the files that role needs
**plus the pinned ecnet2 + ccryptolib crypto libraries**, so there is no half-downloaded
install. It sets `role.txt` for you. Attach the ender modem, then reboot — `startup.lua`
launches the right program automatically. Unpacking the crypto libs takes a few seconds.

> **Re-running an installer is safe for your data.** It writes code files and `role.txt`
> only; every `/easykey_*.cfg` (the server's keys, approvals and monitor list; a control's
> outputs; a panel's controls; an elevator's lifts) and the pinned server address in
> `/easykey_server.txt` are left alone. Upgrading the server does **not** cost you a
> re-pair, a re-approval, or your keys.

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
to ping. The row says which kind of device is asking (`pocket` / `control` / `manual` /
`elevator` / `elevmon`), so you always know what you are trusting.

Where each kind lands, and what it is then told:

| Approved as | Goes in | The server then pushes it |
|---|---|---|
| `pocket` | pockets | the **control list** — who to open panel/presence tunnels to |
| `control` / `manual` / `elevator` | controls | the **secure-set** — who is currently cleared |
| `elevator` (additionally) | — | the **monitor list** — which shaft monitors to believe |
| `elevmon` | monitors | the **control list** — which controllers may order it to pulse |

An `elevmon` deliberately does **not** join the control list, because no pocket should ever
open a tunnel to a shaft monitor. On the **`Devs`** tab the prefix tells you which store a
row is in: `P` pocket, `C` control/manual/elevator, `M` elevator monitor.

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

## Elevators (multi-floor lifts)

The manual panel can already drive a simple one-shot lift as an ordinary control. The
**elevator** role is for the case it handles badly: a shaft with several floors, where every
floor is a call button and the interesting question isn't "is it on" but **where is the
cabin**.

### What the mod actually allows

Worth knowing up front, because it shapes everything below. Create's ComputerCraft
integration covers Train Station, Train Schedule, Display Link, Rotation Speed Controller,
Sequenced Gearshift, Speedometer and Stressometer. **The Elevator Pulley is not a
peripheral** — there is no way to move a cabin or read its floor from Lua with Create +
Create: Aeronautics + Immersive Engineering alone.

What an **Elevator Contact** does give us is exactly two redstone hooks, and they are the
whole design:

- give a contact a redstone signal → **the cabin comes to that floor**;
- a contact **emits** a redstone signal while the cabin is stopped at its floor.

So calls are redstone-out and position is redstone-in, at both ends, always. (If you ever
install an addon that exposes the pulley to CC — *Create: Avionics* does — the **elevmon**
role is the single file that would need swapping; nothing else in EasyKey assumes redstone.)

### The two roles

- **elevator** — the controller. Advanced computer + monitor. Holds the lifts and floors,
  publishes them to pockets, decides who may call.
- **elevmon** — a normal computer at the shaft. It does two things and has no opinions:
  **pulses** a call contact when its controller asks, and **reports** which arrival contacts
  are live. Because it is already down there with an ender modem, the controller needs **no
  cable run to the shaft at all** — a call rides an encrypted tunnel instead of a wire.

Trust runs both ways and neither end decides for itself: the controller believes position
reports only from monitors the **server** approved, and a monitor obeys a pulse only from a
controller the **server** approved. A revoked monitor is dropped immediately, position and
all — stale position data is worse than none.

### Wiring one up

1. **Install + approve both.** `install_easykey_elevmon.lua` on the shaft PC,
   `install_easykey_elevator.lua` on the controller. Pair each to the server and approve
   them under `Pend` (they show as **elevmon** and **elevator**).
2. **Find your channels on the monitor.** Its console lists every redstone channel it can
   reach, with an **IN** and an **OUT** column. Press **b** to flip a side to its 16 bundled
   colours (IE interface connectors). Press **f** for *busy only* — then ride the lift: the
   one row that lights up under **IN** is that floor's arrival contact. That is the wiring
   workflow; write the ids down as you go.
3. **Create the lift** on the controller's **Lifts** tab → **NEW**. Name it, pick its
   **position monitor** from the dropdown (only server-approved monitors are offered), and
   set two timings:
   - **Recall** — how long the lift refuses further calls after one is accepted. The
     anti-double-tap lock, and what the pocket shows as `~Ns`. Default 2s.
   - **Timeout** — how long a call counts as outstanding before the console stops waiting
     for an arrival. Roughly "how long the longest ride takes". Default 20s. It never holds
     redstone.
4. **Add the floors.** With the lift selected, go to **Floors** → **NEW** per floor:
   - **Name** — short; the pocket shows `<lift> <floor>`, e.g. `Main Ground`.
   - **Call output** — the channel pulsed to summon the cabin here. Required.
   - **Arrival input** — the channel that floor's contact drives. Optional, but without it
     nothing can ever light up as "the cabin is here".

   Both dropdowns list the controller's own channels **and** the monitor's in one place; a
   `mon:` prefix means it lives on the monitor. Pick the channel the wire is on and forget
   which computer it belongs to. **MOVE UP** / **MOVE DOWN** put the list in shaft order.
5. **Tap a floor** from any cleared pocket in range. Bottom floors, top floors, IE bundled
   colours and relay sides all work the same way.

### What you see

Every floor appears as an ordinary button on the **Lifts** tab of every pocket in range —
including pockets that aren't cleared, which see the buttons and get "access denied" if they
tap. Two things the pocket already draws carry the extra meaning:

| On the pocket | Means |
|---------------|-------|
| the confirm circle **filled green** | the cabin is **at that floor**, read from its arrival contact |
| `~Ns` next to a floor | that lift is in its recall lock; wait, then call again |
| nothing lit on any floor | the cabin is between floors, or that floor has no arrival input |

On the controller's own monitor: **Lifts** shows each lift with its floor count and current
floor; **Floors** shows the selected lift's floors with `loc`/`mon` per channel and the full
ids on the detail lines; **Outs** shows this PC's channels in both directions; **Devices**
shows nearby pockets and the range. **USE** opens the operator's own copy of the floor
buttons — the same view a pocket gets, gated on this PC's approval instead of a session, for
when a pocket can't be used. The whole panel goes **red** in there so you never forget you
are driving the base by hand.

A floor wired to a channel that has stopped existing (a side got bundled, a monitor got
revoked) is painted **red** and says `MISSING`. Bundling a side redefines its channels, so
the console names every floor that just lost its wiring rather than leaving you with a
button that quietly does nothing.

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
- **A rogue PC at a lift shaft can neither move a cabin nor lie about one.** An elevator
  controller obeys position reports only from monitors the server named, and a monitor obeys
  call pulses only from controllers the server named — both checked against the tunnel's
  authenticated sender, so neither side can be impersonated. Revoke a monitor and the
  controller drops its tunnel *and* its last known position on the next push.
- **A lost message can't leave a lift summoned.** A call pulse is timed by the *monitor*, not
  by the controller that asked, and clamped to `elevmon.maxPulse`. A controller that dies
  mid-call costs you a call that didn't happen — never a call contact stuck on.

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
- `elevator.*` — lift defaults: `range`, `pressSeconds` (call pulse length),
  `recallSeconds` and `timeoutSeconds` (per-lift overrides win).
- `elevmon.maxPulse` — the longest pulse a shaft monitor will obey, whoever asks. A call
  contact held down would leave a lift permanently summoned, so this is clamped hard.

There are **no modem channels to configure**: ecnet2 derives channels from the protocol
name.

## Running the tests (on your PC)

Requires CraftOS-PC (and Node to regenerate installers).

```bash
bash tests/run_headless.sh      # 770 tests: pure logic + a REAL encrypted handshake
bash tests/run_ui_pocket.sh     # renders every pocket screen (+ asserts nothing is invisible)
bash tests/run_ui_server.sh     # renders the server UI @ 83x32 (a 5x3 monitor)
bash tests/run_ui_interact.sh   # drives the server's buttons: selection -> action -> payload
bash tests/run_ui_manual.sh     # renders + drives the manual panel PC's UI
bash tests/run_ui_elevator.sh   # renders + drives the elevator controller's UI
bash tests/run_boot_smoke.sh    # boots all 6 roles with an emulated modem
node tools/gen_installers.js    # regenerate installers (refuses to ship an incomplete one)
bash tests/verify_installers.sh # installs, compiles AND boots each role from its installer
```

The suite drives a genuine ecnet2 handshake between two identities over loopback modems,
asserting that the sender address is authenticated and that `distance` survives the
tunnel. The UI is tested in three layers, each one added after a bug that a shallower
layer couldn't see: **render** (layout), **colour** (readable — text-only dumps once
showed a "perfect" console that was black-on-black in-game), and **interaction**
(selection actually reaches the action).

Every Basalt test runs against the **vendored full build** (`vendor/basalt-full.lua`) —
the same one the installers fetch. `DropDown` and `ProgressBar` are full-only, so a test
against a smaller build could pass while the real thing is missing an element.

**Not covered headless, verify in-game:** a true 3-computer round-trip (one CraftOS
computer can't be three) — so for elevators, the controller↔monitor tunnel is exercised at
the message level (`tests/test_elevator_flow.lua` drives the real protocol messages between
all four parties) but not over two real modems. Also not covered: click routing on a real
monitor — `basalt.update("mouse_click", …)` does not reach a window-backed frame, so clicks
cannot be simulated in this harness, and a real Create Elevator Contact's exact redstone
timing.

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
    panel.lua               manual-panel machine (button/switch/latch, ownership, grace)
    access.lua              the shared gate: approval + secure-set + range + presence
    elevator.lua            lift machine (floors, call pulses, position, local or "mon:")
    panel_feed.lua          the pocket's view of the panels around it
    keypad_model.lua        keypad entry buffer
  redstone_io.lua           control-PC hardware: sides, relays, bundled masks, both directions
  link.lua                  queues sends until an ecnet2 tunnel completes
  server.lua                vault + approvals + secure-set/control/monitor push (+ monitor UI)
  control.lua               proximity door driver + its console UI
  manual.lua                manual panel PC (redstone from pocket taps) + its UI
  elevator.lua              elevator controller (floors as panel buttons) + its UI
  elevmon.lua               the PC at a lift shaft: pulses calls, reports arrivals
  pocket/                   Basalt pocket UI: run.lua, app.lua, views/
  ui/                       Basalt monitor UIs: server_app, manual_app, elevator_app,
                            elevmon_console (terminal), keypad/keyboard (shared), views/
vendor/                     pinned ecnet2 + ccryptolib (MIT) — see vendor/README.md
tools/gen_installers.js     installer generator
tests/                      headless CraftOS-PC test + render + boot harness
```
