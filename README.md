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
| Out of range | `AntiCheatService.IsNearZone(player, "Quirks")` | three units in a row hitting the stuck limit with zero accepted rolls stops the farm immediately with a notification (measured: ~20s instead of a full rotation) |
| Insufficient funds | money < roll cost | farm stops with a notification |
| Debounce | last roll < 0.2s ago | interval is always respected |

Success detection is **dual-signal**: a roll succeeded when the unit's quirk string
**changes**, or money visibly **decreases**. Money comparison alone is unreliable — on
rich accounts (`~1e26`) a double's ULP is far larger than a Common roll cost (~5), and
passive income muddies the direction, so every success would read as a refusal. Before
declaring a refusal the script re-reads the quirk for up to ~300ms (first two refusals of
each unit), so a late replication is not mistaken for a rejected roll.

One unit is rolled **continuously until the target lands** — it only moves on after a hit,
when money runs out, or after `stuckLimit` (default 10) consecutive refusals. Skipped units
are not blacklisted: they come back in the next rotation, which starts as soon as every
candidate has been visited once.

On a hit: the unit is dropped from the candidate list (target is already protected since
start), the Discord embed fires, and the loop moves to the next unit. `stop()` restores
the protection map captured at start, leaving the target protected.

### Auto-walk to the machine (chunked teleport)

`start()` no longer needs you to stand at the machine. If the character is more than
`WALK_NEAR_DIST` (40 studs) from the centre of `Workspace.Zones.Quirks`, it is moved there
first, then rolling starts.

The first attempt is a **chunked teleport** (`TELEPORT_WALK = true`). Pathfinding is only a
fallback: the map has conveyor belts that drag the character faster than the waypoint
logic expects, so a path across them keeps "stalling" and recomputing. Teleporting is not
affected by moving surfaces at all.

Why chunking is required (measured on the live client):

| Attempt | Result |
|---|---|
| single `PivotTo` 150 studs | accepted |
| single `PivotTo` 160 / 175 / 183 / 190 / 200 studs | snapped back to the previous position |
| 30 × 6 studs @0.05s (180 studs total) | accepted, no revert (checked 2s later) |
| 2 × 90 studs with a 1.2s pause | both accepted |
| 3 × 100 studs @0.08s (265 studs in ~0.25s) | **reverted** ~0.5s later |
| 2 × 100 studs @0.45s (222 studs/s) | accepted at first, **reverted** ~1s later |
| 12 studs @0.1s (120 studs/s), 234 → 29 studs | accepted, still there 3s later |

So the anti-cheat limits **net displacement per unit time (~150 studs/s)**, not the size of a
single step and not the per-frame delta. Chunking only works while the sustained rate stays
under that limit; sending 100-stud chunks every 0.45s is already too fast.

The script therefore uses 12-stud steps every 0.1s (~120 studs/s). Measured on the live
client: **234 → 29 studs from the centre in 2.5s**, and the position was still correct
3 seconds later. If a step does not land where it was put (rejected), or 15 steps in a row
make no progress (conveyor or wall), the loop gives up and `walkToMachine`
(PathfindingService + `Humanoid:MoveTo`) takes over.

- Ground height for every step is taken from a downward raycast, so slopes, stairs and the
  conveyor surface are handled; the character keeps its current height offset.
- Tunables: `TELEPORT_WALK`, `TELEPORT_STEP` (12), `TELEPORT_DELAY` (0.1),
  `TELEPORT_STOP_DIST` (28), `TELEPORT_MAX_CHUNKS` (150), `TELEPORT_STALL_LIMIT` (15),
  plus `AUTO_WALK`, `WALK_NEAR_DIST`, `WALK_TIMEOUT` for the fallback.
- The fallback recomputes the path when a waypoint is blocked or not reached within 12s,
  with jumps on `Jump` waypoints and on stalls; at most 6 path attempts, 150s total.
- If neither arrives, `start()` aborts with a notification instead of rolling from far
  away (which the server would refuse anyway).
- Rolling only begins after arrival, so no rolls are wasted on the walk.
- Exposed for diagnostics: `getgenv().quirkFarm.teleportToMachine()` and
  `getgenv().quirkFarm.distanceToMachine()`.
- Measured: 234 studs away → 29 studs from centre in 2.5s; pathfinding
  fallback: 107 studs → arrived in 4.6s, then 9/10 rolls accepted.

### UI (LightScriptHub, local)

The script builds its own **LightScriptHub** window — no external UI library and no
`HttpGet`, so it works even when the executor blocks HTTP. It is a draggable 420×250
window with a floating `HUB` button, toast notifications, and auto-scale for split-screen
/ HP with a manual override:

| Tab | Element | What it does |
|---|---|---|
| Farm | **Target Quirk** dropdown | all 20 quirks, rarest first (`Prodigy` is the default); warns when the pick has `weight >= 100` because the server refuses to protect those. Re-applies protections + blacklist immediately when switched while running |
| Farm | **Auto Farm Quirk** toggle | ON starts (protect target → blacklist → roll), OFF stops and restores the old protection map |
| Farm | **Blacklist unit langka** toggle | ON = units already holding a rare quirk (`weight < 100`) at start are skipped for the whole session |
| Farm | **Stats** | 3 lines updated live: `rolls · accepted · hits` / `rare dibuang · money spent` / `current unit · target` |
| Info | live status | distance to the machine, remote channel (`ON/OFF · key · applied rev`), candidate count, blacklisted units, running state and target. Refreshes every 2 s while the window exists |
| Info | buttons | **Cek jarak ke mesin Quirk**, **Tes HIT relay (Discord)** |
| Misc | **Anti-AFK Otomatis** | blocks the game's 18-minute AFK rejoin via a `TeleportService.Teleport` hook, plus the `VirtualUser` idle bypass, on by default |
| Misc | **Matikan 3D Render** | `RunService:Set3dRenderingEnabled(false)` |
| Misc | **Skala GUI (%)** slider | manual window scale, 40–150 %; the default follows the auto scale. **Kembali ke Auto Scale** clears the override |
| Misc | **Tes toast notification** | fires a sample toast |

`AUTO_START = false` by default (enable in the config block if you want it to begin on
load). If GUI creation fails, the script logs an error and continues **headless** — the
farm still works via `getgenv().quirkFarm`, just without the window.

### Game AFK (18-minute rejoin)

The game ships its own AFK handler as a LocalScript (`PlayerScripts.AFK`). It does **not**
use Roblox's `Player.Idled`:

```lua
task.delay(1080, function()                                  -- 18 minutes
    for _ = 1, 20 do
        TeleportService:Teleport(game.PlaceId, LocalPlayer)   -- rejoin the same place
        task.wait(0.5)
    end
end)
```

- The timer is re-armed only by **real `UserInputService.InputBegan` / `TouchStarted`**.
- Roblox's idle event fires at 20 minutes, so an `Idled`-based anti-AFK is both too late
  and watching the wrong event.
- `VirtualUser:ClickButton2` does **not** raise `InputBegan` (measured: 0 events), so the
  classic exploit anti-AFK does nothing against this script.

**Anti-AFK Otomatis (Misc)** therefore hooks `TeleportService.Teleport`: while enabled,
client-side teleport calls are dropped, so the 18-minute rejoin never happens. The toggle
enables/disables the guard at runtime; Roblox's own idle (20 min) is still handled by the
`VirtualUser` click. If the executor has no `hookfunction`, the script destroys
`PlayerScripts.AFK` instead and logs a warning.

```lua
print(getgenv().quirkFarm.antiAfk())   -- { enabled = true, guarded = true }
```

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

Discord webhook: **nothing is hardcoded** (the repo is public). There are two ways to get
HIT notifications:

1. **Dashboard (server-side).** With the remote channel on, the URL is stored in Supabase and
   the **server** posts the embed — the URL never reaches the game client. Nothing
   webhook-related is on the device in this mode.
2. **In-game (local).** **Misc → Discord Webhook** has a textbox plus **Simpan Webhook**.
   Paste the URL, press save: it applies immediately and is written to
   `webhook_url.txt` in the executor workspace, so the next time the script loads the field
   is already filled and you do not have to type it again. Saving an empty field deletes it
   (the file is emptied). If the executor has no `writefile`, it still applies for the
   current session and the toast says so.

The local URL is resolved in this order (first non-empty wins) and is used whenever the
relay is unavailable **or** the server has no webhook stored (`delivered=false`):

1. `getgenv().quirkFarm.webhookUrl` at runtime (this is what the textbox sets),
2. `getgenv().QUIRK_WEBHOOK` set before loading the script,
3. a `webhook_url.txt` file in the executor workspace.

```lua
getgenv().quirkFarm.webhookUrl = "https://discord.com/api/webhooks/..."
```

The UI accepts only `https://discord.com/api/webhooks/...` (and the legacy
`discordapp.com` host) and rejects anything else with a toast. The URL is never logged;
the only time it is written to disk is when you press **Simpan Webhook**.

Notes:

- Burns real in-game money — every accepted roll costs (Common roll cost ranges roughly
  5–2000 depending on the unit).
- You no longer have to stand at the **Quirk machine**: `start()` teleports there in small
  steps (falling back to walking — see *Auto-walk to the machine*). Rolls are accepted from
  a fairly loose range
  (verified ~31 studs from the zone centre); if the server still refuses them, the farm
  stops after three refused units instead of spinning (verified: 99 studs away → 30 rolls,
  0 accepted, stopped after ~20s). Set `AUTO_WALK = false` to keep it fully manual.
- Units already holding the **target** quirk are excluded from candidates. Units holding a
  rare quirk are excluded too *while the blacklist is on* — with it off, their quirk can
  be rerolled away.
- A rare quirk that isn't the target (e.g. Fortune's Favor while hunting Prodigy) is
  **not kept** — it is logged/webhooked as "rare dibuang" and the unit keeps rolling.
  This is deliberate: protecting a non-target quirk globally would stall every holder.
- On stop, the protection map from start is restored (the target stays protected), so
  other rare quirks return to whatever state they had before the session.
- Idempotent: re-running stops the previous instance, destroys the previous
  `LightScriptHub` window (by name), then builds exactly one new window.
- Only official remotes are fired (`Roll` with the unit key, `SetQuirkProtected`) —
  no force flag, no memory/state patching.
- The target list is built from the game's own `Quirks` config when the script loads, so
  new quirks show up automatically; a v803 snapshot is used only if that module cannot be
  required.
- Tested against `[🎃] Anime Dice` v803.

### Remote control from the web dashboard

The farm can be driven from the [`web/`](./web) dashboard instead of the in-game
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
- `Start`/`Stop` from the web behaves exactly like the in-game toggle (protections are
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

## All-in-one hub (Collector + Quirk Farm)

[`quirk-auto-farm.luau`](./quirk-auto-farm.luau) is now the single-window hub. The
existing Quirk Farm is unchanged; a **Collector** tab was added that snapshots the
account's owned resources and POSTs them to the dashboard ingest function.

| Tab | Element | What it does |
|---|---|---|
| Collector | **Auto Sync** toggle | ON = snapshot on profile load and every `COLLECTOR.INTERVAL` (120 s). OFF = manual only |
| Collector | **Sync sekarang** | fires one snapshot immediately (works with Auto Sync OFF) |
| Collector | **status / items** | last HTTP result, age, and a per-kind item count (`Token 5 · Boost 12 · …`) |
| Collector | **Sync key** textbox + **Simpan Sync Key** | applies immediately and persists to `collector_sync_key.txt` (same pattern as the webhook field) |

Snapshots are read-only — the collector never fires a game remote. Payload shape is
unchanged from `web/public/collector.luau`: `{ account, place, items, stats }`, with
`Boost` and `Gear` nested by rarity and every other kind flat. Units are not indexed.

Three collector bugs were fixed during the port:

- **Gear double count.** An equipped piece also exists in its inventory stack
  (verified v809: `Pumpkin Head` x1 in `Inventory` + `Head` slot), so the equipped
  slot is only counted when the name is not already stacked.
- **Non-finite stats.** `money`/`rolls`/`rebirth` are dropped when they are `inf`/`NaN`
  instead of poisoning the JSON body.
- **Hung HTTP.** The POST runs in its own thread with a 20 s deadline, so one stalled
  `request` can no longer leave the sync loop permanently "busy".

Console API:

```lua
getgenv().animeDiceHub.collector.sync()        -- force a snapshot now
getgenv().animeDiceHub.collector.status()      -- { enabled, running, lastAt, lastOk, lastCode, summary, keySet }
getgenv().animeDiceHub.collector.setKey("adsk_...")
getgenv().animeDiceHub.collector.setEnabled(false)
getgenv().AnimeDiceSync()                      -- legacy alias
```

> Do not run the standalone `collector.luau` at the same time as the hub — both would
> sync the same account and you would get duplicate interval traffic.

## Tower control (web → game)

The hub can farm towers from the dashboard. The browser writes `public.tower_controls`,
the script polls it every 15 s and drives the run; telemetry goes back every 30 s.

| Direction | Path | Cadence |
|---|---|---|
| Browser → Supabase | PostgREST write to `public.tower_controls.config` (RLS: `owner_id = auth.uid()`) | on Save / Start / Stop (`rev` bumps) |
| Script → Supabase | `POST /functions/v1/tower` `{action:"pull", userId}` | every 15 s, applies only when `rev` changed |
| Script → Supabase | `POST /functions/v1/tower` `{action:"status", userId, status}` | every 30 s (server enforces 5 s) |
| Script → Supabase | `POST /functions/v1/tower` `{action:"event", userId, kind, …}` on clear/defeat | server relays the Discord embed (30 s floor) |
| Supabase → Browser | realtime on `tower_controls` (15 s polling fallback) | live |

### How the script drives it (and why)

The game's own `TowerController` is the **only** caller of `CompleteTowerFloor`. Its floor
loop is already running after a start; the server accepts at most one call per sequence, so
a second caller would make the controller read "empty" five times and cancel the tower. The
hub therefore:

1. starts through `TowerController.startTower(name)` (the game's own flow, animations and
   reward handling), never through a duplicated floor loop;
2. uses only the official remotes for everything else — `SetAutoTower`,
   `EquipBestTowerTeam`, `CancelTower`;
3. wraps `TowerController.startTower` in the module table so the **automatic restart that
   follows `CancelTower`** (~3 s later) can be vetoed. Without that guard `Stop` never
   sticks — the game restarts the tower at floor 1;
4. keeps a 1 s monitor: `Hidden.Visible` / `Screen.Visible` is "in tower", `Floor.Text` is
   the floor. An end is classified after 2 s without the pill (the restart fires at 3 s), and
   an open menu is ignored because it hides the pill while the run continues.

A cancel requested by the web (Stop, or switching tower) is **not** counted as a defeat and
does not fire a Discord event. Runs that reach `maxFloors` count as **clears**; anything else
counts as a **defeat**. With "Retry after defeat" on, the script re-equips the best team and
restarts the same tower after `retryDelay` seconds.

### Web card

`Tower farm` on the account detail page:

| Element | What it does |
|---|---|
| Tower dropdown | all 14 towers, grouped Halloween event / permanent, with floor counts |
| Start farm / Stop farm | writes `config.running`; the script applies it on the next pull |
| Auto-equip best team | `EquipBestTowerTeam` (server sorts units by damage, slots 1–4) before each start |
| Retry after defeat + delay | restart the same tower, 3–300 s delay |
| Discord on defeat / clear | relayed by the edge function; the webhook URL never reaches the client |
| Status panel | Live/Stale, tower, floor/max, attempts, defeats, clears, team, applied rev |

The in-game **Tower** tab is read-only (status, team, `Tarik config sekarang`, manual
`Equip Best`) so the dashboard stays the single source of truth.

### Setup

1. Run `web/supabase/migrations/20261027000000_tower_control.sql` in the Supabase SQL editor.
2. Deploy the function: `supabase functions deploy tower --no-verify-jwt`.
3. Open the account's Tower card and press **Save** once — that creates the row. Before it
   exists, `pull` returns `config: null` and `status`/`event` answer `404 not registered`.

Console API:

```lua
getgenv().animeDiceHub.tower.state()      -- intent, running, floor, target, attempts, defeats, clears, appliedRev
getgenv().animeDiceHub.tower.pull()       -- pull config now
getgenv().animeDiceHub.tower.start("Attic")
getgenv().animeDiceHub.tower.stop()
getgenv().animeDiceHub.tower.equipBest()
getgenv().animeDiceHub.tower.status()     -- push status now
```

## Trade automation (web → game)

[`trade-auto.luau`](./trade-auto.luau) trades from the dashboard: you pick a **target player**
and a **quirk**, the script sends the trade request, offers every matching unit, and presses
**Ready → Accept** on our side. The partner still accepts manually — only our half is
automated. There is **no in-game GUI**; the card on the account detail page is the whole
control surface.

| Direction | Path | Cadence |
|---|---|---|
| Browser → Supabase | PostgREST write to `public.trade_controls.config` (RLS: `owner_id = auth.uid()`) | on Save / Start / Stop (`rev` bumps) |
| Script → Supabase | `POST /functions/v1/trade` `{action:"pull", userId}` | every 15 s, applies only when `rev` changed |
| Script → Supabase | `POST /functions/v1/trade` `{action:"status", userId, status}` | every 30 s (server enforces 5 s) |
| Supabase → Browser | realtime on `trade_controls` (15 s polling fallback) | live |

### Setup

1. Run `web/supabase/migrations/20261028000000_trade_control.sql` in the Supabase SQL editor
   (after the tower migration; idempotent).
2. Deploy the function: `supabase functions deploy trade --no-verify-jwt` (or paste
   `web/supabase/functions/trade/index.ts` in the dashboard and disable JWT verification).
3. Load the script, then press **Save** once in the Trade card — that creates the row.
   Until it exists, `pull` returns `config: null` and `status` answers `404 not registered`.
4. Pick the target from the live player list (**Players** come from the script's status
   push, so allow up to ~30 s after the first Save), pick the quirk, press **Start trade**.

### What the script does

- **Candidates** are read from the live inventory: entries whose `EntryRegistry` kind is
  `Unit`, that `TradeConfig.IsTradeable` accepts, and whose `attributes.quirk` equals the
  configured quirk. Sorted by `level` descending, capped at `maxUnits` (1–20, default 20).
- **Offers** go out with `ChangeOffer(key, 1)` every 0.15 s (server debounce is 0.1 s).
  After 8 s — or as soon as every unit is confirmed — it stops and presses **Ready** once.
- **Confirm** arrives only after both sides are ready; the script accepts 0.6 s later.
  Any offer change resets both sides' ready/accept, so it never touches offers again once
  it starts readying.
- A trade that starts with **someone other than the target** is cancelled immediately, and
  `Stop` / a target switch cancels the live trade once (the script ignores the resulting
  `Ended` so it does not mark the session as finished).
- **No matching unit** → the trade is cancelled with `state: "error"` and the reason in
  `lastError` instead of offering an empty trade; change the quirk (which bumps `rev`) to
  retry.
- After a trade ends (`Completed` or not) the session stops until `rev` changes, so the
  script does not immediately re-request the same player. The end reason is reported as
  `lastError` for anything but `Completed`.

Server rules it has to live with (all verified from the game's own `TradeService`): account
age ≥ 14 days, ≥ 1000 rolls, target has requests enabled, 6 s request cooldown, 6 s request
expiry, 20 unique entries per trade, `Tickets` untradeable.

### Config / status contract

`config` (written by the browser): `running`, `targetUserId`, `targetName`, `quirk`,
`maxUnits` (1–20), `autoAccept`, `autoReady`, `rev`.

`status` (written by the script, fixed whitelist): `running`, `state`
(`idle|waiting_target|request_sent|in_trade|done|error`), `phase`, `target`, `targetUserId`,
`quirk`, `matched`, `offered`, `maxUnits`, `players` (≤ 30 × `{id, name}`), `appliedRev`,
`lastSeenAt`, `lastError`, `version`.

### Console API

```lua
getgenv().tradeAuto.start()        -- local start (overrides config until the next rev)
getgenv().tradeAuto.stop()         -- stop + cancel the live trade
getgenv().tradeAuto.state          -- live state table
getgenv().tradeAuto.pull()         -- pull config now
getgenv().tradeAuto.pushStatus()   -- push status now
```

Notes:

- Only official `TradeService` remotes are fired (`RequestTrade`, `RespondToRequest`,
  `ChangeOffer`, `AdvanceTrade`, `CancelTrade`, `SetTradeRequestsEnabled`) — no hook, no
  memory patching, and the partner's side is never automated.
- `autoAccept` only accepts an **incoming** request from the configured target; it never
  fires requests for anyone else.
- Diagnostics: the console distinguishes a 404 from Supabase ("function not deployed") from
  the edge function's own `404 not registered` (row missing → press Save in the web card).

