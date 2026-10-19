# anime-dice

Auto-complete script for the **Anime Dice** Roblox tutorial — drives the game's own
remotes to finish all 13 onboarding steps (up to unlocking **Auto Roll**), then applies
post-tutorial settings.

## What it does

The game's tutorial is server-authoritative: some steps advance automatically when the
player's server state matches a condition, while "forced" steps (2, 9, 10, 13) require
firing `OnboardingService.Advance`. The script polls the client data controller and fires
the correct remote at each step.

Flow:

| Step | Action | How |
|---|---|---|
| 1 | Roll a unit | `RollService.RF.RollDice` |
| 2 | Open Backpack | `OnboardingService.RE.Advance` (forced) |
| 3 | Equip unit | `UnitService.RF.Equip(unitKey)` |
| 4 | Place in slot | `PlotService.RE.InteractSlot(1)` |
| 5 | Collect cash | `PlotService.RE.CollectBalance(1)` |
| 6 | Go to shop area | teleport character |
| 7 | Go to Dice Shop | teleport character |
| 8 | Buy first dice | `DiceShopService.RE.BuyDice("Normal")` |
| 9 | Close Dice Shop | `OnboardingService.RE.Advance` (forced) |
| 10 | Press Home | `OnboardingService.RE.Advance` (forced) |
| 11 | Roll again | `RollService.RF.RollDice` |
| 12 | Turn on Auto Roll | `RollService.RE.SetAutoRoll(true)` |
| 13 | Hide rolls | `OnboardingService.RE.Advance` (forced) |

After the tutorial finishes it also applies:

- **Auto Sell = 1qd** (`1e15`, using the game's own compact suffix `qd`) via `SettingsService.RE.SetSetting`
- **Performance = ON** via `SettingsService.RE.SetSetting`

## Usage

Run the script in a Roblox executor connected to an **Anime Dice** client
(the auto-execute / `autoexec` folder works too):

```lua
loadstring(readfile("anime-dice-tutorial.luau"))()
```
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/gakirei/anime-dice/main/anime-dice-all-in-one.luau"))()
```

> Requires the repo to be **Public**. If it is private, `raw.githubusercontent.com`
> returns **HTTP 404** (a `?token=` link is only a short-lived copy link and will
> expire). Public repos need no token.

Or paste the contents of [`anime-dice-tutorial.luau`](./anime-dice-tutorial.luau)
directly into your executor.

## Notes

- Uses only the game's official remotes — no fabricated or memory-patched state.
- Idempotent: safe to re-run. Once `OnboardingStep >= 14` it only re-applies the
  post-tutorial settings.
- Tested against `[🎉UPD 8] Anime Dice`.

## Performance (Thermal/Resource Saver)

[`anime-dice-perf.luau`](./anime-dice-perf.luau) is an aggressive, local-only client optimizer
designed to reduce GPU/CPU load on mobile/cloudphone runs (FPS/thermal focus). All changes
are client-side and wrapped with `pcall`.

What it does (Delta/Android friendly):

- Forces lowest quality: `QualityLevel = Level01` and disables FRM if needed (read-back
  guard to avoid regressions).
- Attempts FPS cap via `setfpscap`/`debug.setfpscap` probe (Delta has it).
- Disables shadows, environment diffuse/specular, and all PostEffects; optionally destroys
  legacy FX (Beams/Trails/Fire/Smoke/Sparkles).
- Disables ~all `ParticleEmitter`s (bulk + DescendantAdded) and culls distant
  `BillboardGui`/`SurfaceGui` (>160 studs).
- Freezes far unit animations (`Animator:AdjustSpeed(0)` for distance >160 studs).
- Applies official settings: `Music = 0`, `HideGears = true`, `Performance = true`
  (once, via `SettingsService.RE.SetSetting`).

Notes:

- Streaming radius levers are game-dependent and may be unavailable in Anime Dice (detected
  automatically and safely skipped).
- Particles are the biggest measured lever: **~+31% FPS** in test (5.57 → 7.29).
- Beams/Trails/legacy FX that are destroyed cannot be restored live (rejoin to reset).
- Provides `ENV.animeDicePerf.stop()` to stop loops without rejoining.
- Idempotent and self-replacing on re-run.

Usage:

```lua
loadstring(readfile("anime-dice-perf.luau"))()
```

## Halloween Auto Candy (Trick-or-Treat)

[`halloween-auto-candy.luau`](./halloween-auto-candy.luau) farms the Halloween event's
Candy by walking the **7 haunted-house doors on Haunted Island** and knocking on each one
on a schedule the server accepts.

The knock is server-authoritative — `TrickOrTreatService` re-validates **every 0.2s** and
silently refuses anything that fails. The script does not fire remotes; it only teleports
the character and listens for the game's own `Knocked` / `Landed` echoes, so the game's
client code performs the actual knock. To satisfy validation it encodes all four rules:

| Rule | Server check | What the script does |
|---|---|---|
| Range | horizontal (XZ) distance to door `< 14` and `\|dy\| < 20` | stands 4 studs in front, Y pinned to the door |
| Cooldown | per-door `readyAt = knock + 30s` | waits for server-issued `readyAt` (from the `Knocked` echo) |
| Gap | `>= max(2s, distToLastKnockedDoor / 60)` across **all** doors | waits out the global gap using `workspace:GetServerTimeNow()` |
| Re-arm | door disarms on knock, re-arms only when player is `> 17` studs away | stages 19 studs out and dwells there ≥ one server tick |

It discovers doors at runtime via `CollectionService:GetTagged("TrickOrTreatDoor")`
(nothing is hardcoded), orders them nearest-neighbour from wherever the character stands,
and teleports with `PivotTo` only — no `WalkSpeed`/`Jump`/noclip changes.

### UI (Rayfield Gen 2)

The script opens a **[Rayfield Gen 2](https://docs.sirius.menu/rayfield-gen2)** window
(loaded from the official `https://sirius.menu/gen2` loader) with a **Farm** tab:

| Element | What it does |
|---|---|
| **Auto Farm Candy** toggle | ON starts the farm (re-discovers doors, recomputes route, reconnects events); OFF stops it — loops exit, events disconnect, stats kept |
| **Stats** line | live counters: knocks, candy, current route position, next-knock ETA |

Restart happens in-place via the toggle, without re-executing the script. Setup
failures (not on the island yet, remotes missing, character dead) are recoverable: the
toggle flips back OFF and the window stays alive, so you can teleport over and retry.

`AUTO_START = true` in the script's config block makes it begin farming on load. Set it
to `false` if you prefer manual-only start. If Rayfield fails to load (no network /
HttpGet blocked), the script logs an error and continues **headless** — the farm still
works via `getgenv().halloweenFarm.{start,stop}`, just without the window.

Measured on `[🎃] Anime Dice` v742: **28 knocks / 117s** (≈14.4 per minute, right at the
theoretical 7-doors-per-30s cap) for **809 candy**, matching the in-game HUD counter
exactly. Expect ≈ 17.8 candy/knock on average → roughly **250 candy/min** at steady state.

Notes:

- Listens only — no remotes fired, no memory/state patching.
- Idempotent: re-running stops the previous instance first, Unloads the previous
  Rayfield window, then builds exactly one new window (no double loop, no stacked UI).
- Provides `getgenv().halloweenFarm.{start,stop,stats,isRunning}` (the Rayfield toggle
  is the intended control surface; the console API is there for scripting/inspection).
- Requires the character to already be on **Haunted Island** (use the game's
  `HalloweenService.RF.Teleport` → `"Island"` first).
- A "Trick!" outcome is purely cosmetic (pumpkin on the head for 20s) — no penalty.

Usage:

```lua
loadstring(readfile("halloween-auto-candy.luau"))()
```

Stop / inspect:

```lua
getgenv().halloweenFarm.stop()
print(getgenv().halloweenFarm.stats.knocks, getgenv().halloweenFarm.stats.candy)
```

## Quirk Auto Farm (Prodigy / Fortune's Favor hunter)

[`quirk-auto-farm.luau`](./quirk-auto-farm.luau) spams the **Quirk machine** on your
**Common-rarity** units until each one lands the chosen target quirk — **Prodigy** or
**Fortune's Favor** (selectable via dropdown). On a hit it auto-protects the quirk,
pings a **Discord webhook**, and moves to the next unit.

Odds per roll (total pool weight 5556): **Prodigy = 2/5556 ≈ 1/2778**,
**Fortune's Favor = 0.5/5556 ≈ 1/11112**. A full rotation over every Common unit is
expected to take hours — this is an idle farm.

The roll (`QuirkService.RE.Roll`) takes the unit key only and is re-validated by the
server with a **0.2s debounce** — the script keeps a 0.25s interval. The server
**silently refuses** rolls (no error, no refund) when:

| Refusal | Server check | Script behavior |
|---|---|---|
| Protected quirk | unit's current quirk name is in `ProtectedQuirks` (global per quirk name) | such units are excluded from candidates up front — no wasted rolls |
| Insufficient funds | money < roll cost | farm stops with a notification |
| Debounce | last roll < 0.2s ago | interval is always respected |

Success detection is **dual-signal**: a roll succeeded when the unit's quirk string
**changes**, or money visibly **decreases**. Money comparison alone is unreliable — on
rich accounts (`~1e17+`) a double's ULP (~64+) is larger than a Common roll cost (~5),
and passive income muddies the direction, so every success would read as a refusal.

On a hit: fires `SetQuirkProtected(target, true)` once per session (protection is
global per quirk name, so one fire covers every holder), sends the Discord embed, and
the unit drops out of the candidate list on the next rotation.

### UI (Rayfield Gen 2)

The script opens a **[Rayfield Gen 2](https://docs.sirius.menu/rayfield-gen2)** window
(loaded from the official `https://sirius.menu/gen2` loader) with a **Farm** tab:

| Element | What it does |
|---|---|
| **Target Quirk** dropdown | `Prodigy` (default) or `Fortune's Favor`; applies from the next rotation |
| **Auto Farm Quirk** toggle | ON starts, OFF stops — loops exit, stats kept |
| **Protect on hit** toggle | fires the global quirk protection on the first hit of each session |
| **Stats** line | rolls, hits, money spent, current unit, target |

`AUTO_START = false` by default (enable in the config block if you want it to begin on
load). If Rayfield fails to load, the script logs an error and continues **headless** —
the farm still works via `getgenv().quirkFarm`, just without the window.

Usage:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/gakirei/anime-dice/main/quirk-auto-farm.luau"))()
```

Stop / inspect / switch target:

```lua
getgenv().quirkFarm.stop()
print(getgenv().quirkFarm.stats.rolls, getgenv().quirkFarm.stats.hits)
getgenv().quirkFarm.setTarget("Fortune's Favor")
```

Discord webhook: set `WEBHOOK_URL` in the script's config block, or at runtime:

```lua
getgenv().quirkFarm.webhookUrl = "https://discord.com/api/webhooks/..."
```

Notes:

- Burns real in-game money — every accepted roll costs (Common roll cost ranges roughly
  5–2000 depending on the unit).
- Units already holding the target quirk, and units holding any **protected** quirk,
  are excluded from the candidate list (protected units cannot be rerolled at all).
- If a roll lands a **protected quirk that isn't the target** (e.g. Fortune's Favor
  while hunting Prodigy), the unit **keeps it** — the server blocks further rerolls, so
  the script stops rolling that unit immediately (no wasted rolls) and logs/webhooks a
  "disimpan" notification.
- Idempotent: re-running stops the previous instance, Unloads the previous Rayfield
  window, then builds exactly one new window.
- Only official remotes are fired (`Roll` with the unit key, `SetQuirkProtected`) —
  no force flag, no memory/state patching.
- Tested against `[🎃] Anime Dice` v746.
