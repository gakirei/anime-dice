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
loadstring(game:HttpGet("https://raw.githubusercontent.com/gakirei/anime-dice/refs/heads/main/anime-dice-all-in-one.luau?token=GHSAT0AAAAAAEI3WNFYWTAS7ZO6JO3PGVNS2WSQCIQ"))()
```

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
