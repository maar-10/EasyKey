# Vendored third-party libraries

These are **not our code**. They are vendored (copied in, pinned to an exact commit) so the
EasyKey installers are self-contained and reproducible — no install-time dependency on
GitHub being up, and no risk of a moving `main` branch silently changing our crypto.

| Library | Purpose | Upstream | Pinned commit | Licence |
|---------|---------|----------|---------------|---------|
| `ecnet2/` | Encrypted, authenticated, replay-protected transport (Noise XK, X25519 + AEAD) | https://github.com/migeyel/ecnet | `15dcf3e6d396523f7273d67e00cc24e5bc52c8c8` | MIT |
| `ccryptolib/` | Crypto primitives used by ecnet2, plus `sha256` for our hashed key storage | https://github.com/migeyel/ccryptolib | `95da416fcd07afc92f5e209ee6d7addf9b96d69e` | MIT |

Each library keeps its upstream `LICENSE` file alongside its sources.

## Deployment note

On a CC computer these must live at the **root** as `/ecnet2/…` and `/ccryptolib/…`,
because that is what their internal `require("ecnet2.x")` / `require("ccryptolib.x")` calls
resolve to. In this repo they live under `vendor/` to keep our own code separate, and
`tools/gen_installers.js` maps `vendor/ecnet2/**` → `/ecnet2/**` (and likewise for
ccryptolib) when embedding them into the installers. The test harnesses do the same when
deploying into a CraftOS-PC computer.

## Updating

Re-download at a new commit, update the table above, then regenerate + re-verify the
installers:

```bash
node tools/gen_installers.js
bash tests/verify_installers.sh
```

Do not edit these files locally — any local change would be silently lost on the next
update and would invalidate the pinned-commit provenance.
