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
- The trade-ready Discord notification is **off by default** — no webhook is stored in this
  public repo. Provide one via `getgenv().ANIME_DICE_WEBHOOK = "..."` or a
  `webhook_url.txt` file in the executor workspace. Without it the script skips the
  notification and prints a single `OFF` line.

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

## Quirk Auto Farm (any quirk as target)

[`quirk-auto-farm.luau`](./quirk-auto-farm.luau) spams the **Quirk machine** on your
**Common-rarity** units until each one lands the chosen target quirk — **every quirk in the
game is selectable** (20 of them, listed from rarest to most common). On a hit it sends a
**Discord notification** and moves to the next unit.

### Protection model (why units never get stuck)

Quirk protection is **global per quirk name**, not per unit. Protecting a non-target
quirk makes *every* unit holding it unrollable, which stalls the farm. So the script
uses **one protected quirk only — the target**:

1. **At start** — fires `SetQuirkProtected(target, true)` and waits for replication
   (up to 3s) *before* the first roll, so a target can never be rolled away.
2. **At start** — unprotects every other quirk with `weight < 100` (Fortune's Favor,
   Midas Touch, Tycoon, Sovereign, …) so those units become rollable again. The original
   protection map is snapshotted and **restored on stop**.
3. **Blacklist** — units that *already* hold a rare quirk (`weight < 100`) at start are
   recorded **per unit key** and skipped for the whole session, so existing rare
   inventory is never rerolled. Default ON (`BLACKLIST_RARE_UNITS`), toggleable in the UI,
   rebuilt automatically on start / on target change.
4. **During the run** — a rare quirk that is *not* the target is **not** kept: the unit
   keeps being rolled (that's the "only hold the chosen quirk" rule). Each one is logged
   and counted as `rareLost`.

Odds per roll (total pool weight 5556): **Sovereign = 0.15/5556 ≈ 1/37,041**,
**Fortune's Favor ≈ 1/11,112**, **Midas Touch ≈ 1/5,556**, **Prodigy = 2/5556 ≈ 1/2,778**,
**Tycoon ≈ 1/2,222**, then the tier-III quirks at `10/5556 ≈ 1/556`. A full rotation over
every Common unit is expected to take hours — this is an idle farm.

Only quirks with `weight < 100` can be **protected** by the server (the ten rarest). The
ten tier-II/I quirks are still selectable as a target so you can farm them, but the
dropdown and the dashboard both warn: a hit will be found and counted, then rerolled in a
later session because the server refuses to hold it.

The roll (`QuirkService.RE.Roll`) takes the unit key only and is re-validated by the
server with a **0.2s debounce** — the script keeps a 0.25s interval. The server
**silently refuses** rolls (no error, no refund) when:

| Refusal | Server check | Script behavior |
|---|---|---|
| Protected quirk | unit's current quirk name is in `ProtectedQuirks` (global per quirk name) | only the target stays protected, so target holders are excluded and every other unit stays rollable |
| Out of range | `AntiCheatService.IsNearZone(player, "Quirks")` | a full rotation with zero accepted rolls auto-stops the farm with a notification (no infinite spin) |
| Insufficient funds | money < roll cost | farm stops with a notification |
| Debounce | last roll < 0.2s ago | interval is always respected |

Success detection is **dual-signal**: a roll succeeded when the unit's quirk string
**changes**, or money visibly **decreases**. Money comparison alone is unreliable — on
rich accounts (`~1e26`) a double's ULP is far larger than a Common roll cost (~5), and
passive income muddies the direction, so every success would read as a refusal.

On a hit: the unit is dropped from the candidate list (target is already protected since
start), the Discord embed fires, and the loop moves to the next unit. `stop()` restores
the protection map captured at start, leaving the target protected.

### UI (Rayfield Gen 2)

The script opens a **[Rayfield Gen 2](https://docs.sirius.menu/rayfield-gen2)** window
(loaded from the official `https://sirius.menu/gen2` loader) with a **Farm** tab:

| Element | What it does |
|---|---|
| **Target Quirk** dropdown | all 20 quirks, rarest first (`Prodigy` is the default); warns when the pick has `weight >= 100` because the server refuses to protect those. Re-applies protections + blacklist immediately when switched while running |
| **Auto Farm Quirk** toggle | ON starts (protect target → blacklist → roll), OFF stops and restores the old protection map |
| **Blacklist unit langka** toggle | ON = units already holding a rare quirk (`weight < 100`) at start are skipped for the whole session |
| **Stats** | 3 lines: `rolls · accepted · hits` / `rare dibuang · money spent` / `current unit · target` |

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
print(getgenv().quirkFarm.stats.rolls, getgenv().quirkFarm.stats.hits, getgenv().quirkFarm.stats.rareLost)
getgenv().quirkFarm.setTarget("Fortune's Favor")
getgenv().quirkFarm.rebuildBlacklist()
```

Discord webhook: **nothing is hardcoded** (the repo is public) and, with the remote channel on,
**nothing webhook-related is on the device either** — the dashboard stores the URL in Supabase
and the server posts the embed. The device only falls back to a local URL if the relay itself
fails, resolved in this order (first non-empty wins):

1. `getgenv().quirkFarm.webhookUrl` at runtime,
2. `getgenv().QUIRK_WEBHOOK` set before loading the script,
3. a `webhook_url.txt` file in the executor workspace.

```lua
getgenv().quirkFarm.webhookUrl = "https://discord.com/api/webhooks/..."
```

With no local webhook, a failed relay is simply logged. The URL is never logged and never
written to disk by the script.

Notes:

- Burns real in-game money — every accepted roll costs (Common roll cost ranges roughly
  5–2000 depending on the unit).
- Keep your character near the **Quirk machine** while farming. Rolls are accepted from a
  fairly loose range (verified ~31 studs from the zone center), but if the server stops
  accepting them the farm auto-stops after one empty rotation instead of spinning.
- Units already holding the **target** quirk are excluded from candidates. Units holding a
  rare quirk are excluded too *while the blacklist is on* — with it off, their quirk can
  be rerolled away.
- A rare quirk that isn't the target (e.g. Fortune's Favor while hunting Prodigy) is
  **not kept** — it is logged/webhooked as "rare dibuang" and the unit keeps rolling.
  This is deliberate: protecting a non-target quirk globally would stall every holder.
- On stop, the protection map from start is restored (the target stays protected), so
  other rare quirks return to whatever state they had before the session.
- Idempotent: re-running stops the previous instance, Unloads the previous Rayfield
  window, then builds exactly one new window.
- Only official remotes are fired (`Roll` with the unit key, `SetQuirkProtected`) —
  no force flag, no memory/state patching.
- The target list is built from the game's own `Quirks` config when the script loads, so
  new quirks show up automatically; a v803 snapshot is used only if that module cannot be
  required.
- Tested against `[🎃] Anime Dice` v803.

### Remote control from the web dashboard

The farm can be driven from the [`web/`](./web) dashboard instead of the Rayfield
window: settings are stored in Supabase, **Start/Stop** is a button in the browser, and
the script streams live stats back.

**No secret is stored on the device.** The channel is open: requests are keyed by your
Roblox user id, the sync key is optional, and the Discord webhook URL never reaches the
game client (the server relays the notification). Setup:

1. Run both migrations in the Supabase SQL editor, in order (idempotent):
   `web/supabase/migrations/20261026000000_quirk_control.sql`, then
   `web/supabase/migrations/20261026010000_quirk_control_open_channel.sql`.
2. Deploy the edge function: `supabase functions deploy quirk --no-verify-jwt`
   (or paste `web/supabase/functions/quirk/index.ts` in the dashboard and disable JWT
   verification). Full steps: [`web/supabase/README.md`](./web/supabase/README.md).
3. Load the script. The console shows `remote config: ON (poll 15s, open channel)` — no
   key, no file, nothing to paste. Mode is off only if HTTP is unavailable
   (`OFF (fungsi HTTP tidak tersedia)`).
4. **Save the settings once** in the dashboard. That creates the `quirk_controls` row and
   bumps `rev`; before it exists, `pull` returns `config: null` and `status`/`hit` answer
   `404 not registered`.
5. Open the account's detail page — the **Quirk Farm** card shows the same settings as the
   in-game window (target, blacklist, roll interval, stuck limit, webhook URL) plus
   **Start/Stop** and the live counters (updates within ~15s for config, ~30s for stats).

How it works:

| Direction | Path | Cadence |
|---|---|---|
| Browser → Supabase | direct PostgREST write to `public.quirk_controls.config` (RLS: `owner_id = auth.uid()`) | on save / on toggle (`rev` bumps) |
| Script → Supabase | `POST /functions/v1/quirk` `{action:"pull", userId}` | every 15s, applies only when `rev` changed |
| Script → Supabase | `POST /functions/v1/quirk` `{action:"status", userId, status}` | every 30s (server enforces 5s) |
| Script → Supabase | `POST /functions/v1/quirk` `{action:"hit", userId, unit, quirk}` on a hit | server posts the Discord embed (15s floor) |
| Supabase → Browser | realtime on `quirk_controls` (polling fallback) | live |

Notes:

- The dashboard **never** rolls anything itself — it only writes config. The script
  remains the only actor that fires game remotes, so a stale browser tab cannot roll.
- `Start`/`Stop` from the web behaves exactly like the Rayfield toggle (protections are
  applied on start, restored on stop).
- Local UI still works while remote mode is on; the last applied remote `rev` wins on the
  next pull.
- The function **never accepts config writes** — only the signed-in browser can change
  settings through RLS. It writes `status` and stamps `last_hit_at`.
- Webhook notifications are posted **by the server**. `pull` strips every key containing
  `webhook`, so the URL is not on the device even in memory.
- Status is a fixed 13-key whitelist (`running`, `target`, `rolls`, `accepted`, `hits`,
  `rareLost`, `moneySpent`, `current`, `candidates`, `blacklisted`, `appliedRev`,
  `lastSeenAt`, `version`); anything else is dropped server-side.
- **Open-channel tradeoff:** anyone who knows your Roblox user id can read these settings
  (never the webhook URL) and can spoof the telemetry numbers. They cannot change config,
  stop the farm, or post to your webhook beyond the 15s rate limit. To tighten later, set
  a sync key on the device — the function already accepts `x-sync-key` when present.
