--// Anime Dice — Halloween Auto Candy (Trick-or-Treat) \\--
-- Walks the 7 haunted-house doors on Haunted Island and knocks on each one on a
-- timing schedule that satisfies the SERVER's TrickOrTreatService re-validation
-- (it re-checks every 0.2s and silently refuses invalid knocks):
--   • range: horizontal (XZ) distance to the door < 14 and |dy| < 20
--   • per-door cooldown: knockable again at the server-issued readyAt (= +30s)
--   • global gap (spans ALL doors): >= max(2s, distToLastKnockedDoor / 60)
--   • re-arm: server disarms a door on knock; it re-arms only after the player
--     stands > 17 studs away from it for >= one server tick
-- The script ONLY teleports the character (PivotTo) and LISTENS to the game's
-- Knocked/Landed events — the game's own client code performs the actual knock.
-- No remotes fired, no WalkSpeed/Jump/noclip, no memory or state patching.
--
-- Reward math: outcomes average ≈ 17.8 candy/knock; 7 doors × 30s cooldown ⇒
-- steady state ≈ 7 knocks / 30s ≈ 250 candy/min. A "Trick!" outcome is purely
-- cosmetic (pumpkin on the head for 20s, ROLL_TIME 1.6s) — no penalty.
--
-- Usage : loadstring(readfile("halloween-auto-candy.luau"))()
-- UI    : Rayfield Gen 2 (dependensi: https://sirius.menu/gen2) — SATU window
--           "Halloween Auto Candy" berisi SATU toggle "Auto Farm Candy"
--           (+ satu elemen Stats). Toggle ON = start, OFF = stop.
--           AUTO_START (config di bawah) = true: langsung farming saat load;
--           set false kalau mau start manual lewat toggle saja.
--           Bila load Rayfield gagal (tanpa HttpGet / tanpa jaringan) script
--           TETAP jalan tanpa UI (headless) — kontrol via API di bawah.
-- API   : getgenv().halloweenFarm = { stats, start, stop, isRunning }
--             stats       -- { knocks = n, candy = n } — akumulatif, tidak di-reset
--             start()     -- true = berjalan, false = gagal (recoverable, UI tetap)
--             stop()      -- hentikan loop & disconnect event generasi sekarang
--             isRunning() -- status running sekarang
-- Idempotent: re-running stops the previous instance first, unloads the previous
-- Rayfield window and destroys any leftover legacy custom GUI, then builds
-- exactly one new window — no stacked windows, no double loops.
-- Lifecycle memakai generation token (runId): setiap start/stop menaikkan runId,
-- semua loop membawa id generasinya dan keluar saat id ~= runId — restart bersih,
-- tidak pernah ada dua mainLoop hidup bersamaan.

--// Teardown instance lama — urutan di bawah WAJIB urut (window/loop bocor kalau tidak) \\--
local ENV = (type(getgenv) == "function") and getgenv() or _G

-- (1) Hentikan farm generasi lama dulu -> re-run = ganti, bukan menumpuk loop.
if type(ENV.halloweenFarm) == "table" and type(ENV.halloweenFarm.stop) == "function" then
	pcall(ENV.halloweenFarm.stop)
end

-- (2) Tutup window Rayfield generasi lama (handle disimpan di ENV saat build).
do
	local oldWindow = ENV.__halloweenRayfield
	if type(oldWindow) == "table" and oldWindow.unloaded == false then
		pcall(function()
			oldWindow:Unload()
		end)
	end
	ENV.__halloweenRayfield = nil
end

-- (3) Migrasi versi lama: buang ScreenGui kustom "HalloweenFarmGui" yang tertinggal.
do
	local lp = game:GetService("Players").LocalPlayer
	local playerGui = lp and lp:FindFirstChild("PlayerGui")
	local oldGui = playerGui and playerGui:FindFirstChild("HalloweenFarmGui")
	if oldGui then
		oldGui:Destroy()
	end
end

-- Catatan: early-return guard versi lama (cegah re-run) sudah DIHAPUS — teardown
-- di atas yang menjamin idempotensi, jadi re-run selalu membangun satu window baru.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

--// Config \\--
local AUTO_START = true -- true: farming langsung saat load; false: start manual lewat toggle Rayfield / getgenv().halloweenFarm.start()
local VERBOSE = false -- log per-knock lines (default off: avoid spam)
local KNOCK_RANGE = 14 -- rule 1: server rejects knocks farther than this (XZ)
local DY_TOLERANCE = 20 -- rule 1: |doorY - hrpY| must stay under this
local REARM_RANGE = 17 -- rule 4: stand farther than this to re-arm a knocked door
local COOLDOWN = 30 -- rule 2: per-door cooldown the server enforces
local GAP_MIN_SECONDS = 2 -- rule 3: floor of the global inter-knock gap
local GAP_SPEED = 60 -- rule 3: gap grows with distance-to-last-door / 60
local SAFETY_MARGIN = 0.35 -- rule 5: shave off this much on every wait
local KNOCK_OFFSET = 4 -- rule 8: knock stand-off distance in front of the door
local STAGE_OFFSET = 19 -- rule 8: staging distance (> 17 re-arms own door)
local STAGE_SCAN_MAX = 40 -- rule 8: outer bound when scanning for a safe staging point
local WINDOW_DEADLINE = 90 -- rule 10b: never hang longer than this on one door
local KNOCK_TIMEOUT = 2.5 -- rule 10d: wait for the Knocked event after stepping in
local STATUS_INTERVAL = 15 -- rule 13: status line cadence
local DOOR_POLL_SECONDS = 10 -- rule 7: how long to wait for TrickOrTreatDoor tags

--// State \\--
local RUNNING = false -- awalnya mati; start() yang menyalakan (lihat AUTO_START)
local runId = 0 -- generation token: tiap start/stop naik 1 -> loop generasi lama mati bersih
local stats = { knocks = 0, candy = 0 } -- akumulatif lintas stop/start (tidak pernah di-reset)
local readyAt = {} -- door part -> server-issued knock-ready timestamp
local lastKnockTime = nil -- server-time of our last successful knock (nil = never)
local lastKnockPos = nil -- XZ position of the last knocked door
local knockConfirmed = nil -- part the Knocked event reported for the in-flight attempt
local route = {} -- nearest-neighbour order over the 7 doors, computed once per start
local routeIndex = 1
local stagePos = {} -- door -> staging point (re-arms own door, clears others)
local knockPos = {} -- door -> valid knock stand-off point
local knockedConn, landedConn

--// Rayfield Gen 2 handles — dibuat sekali di jalur load; semuanya nil = tanpa UI \\--
local Rayfield -- hasil loader (nil = gagal dimuat -> mode headless, API tetap jalan)
local rayfieldWindow, farmToggle, statsText

local function log(msg)
	print("[HalloweenFarm] " .. msg)
end

--// Helpers \\--
-- Rule 1/3/4/8 all validate horizontal (XZ) distance only.
local function horizontalDistXZ(a, b)
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Rule 12: character can vanish (respawn) at any point — never error out of the loop.
local function getHRP()
	local char = LocalPlayer.Character
	if not char then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health <= 0 then
		return nil
	end
	return hrp
end

-- Rule 12: block (without erroring) until a live character exists again.
-- id = token generasi pemanggil; keluar lebih awal begitu id ~= runId.
local function ensureCharacter(id)
	while RUNNING and id == runId do
		local hrp = getHRP()
		if hrp then
			return hrp
		end
		task.wait(0.25)
	end
	return nil
end

-- Rule 11: teleport ONLY via PivotTo — no WalkSpeed/Jump/noclip side effects.
local function pivotTo(pos)
	local char = LocalPlayer.Character
	if not char then
		return
	end
	char:PivotTo(CFrame.new(pos))
end

-- Rule 7: outward-facing unit vector of a door.
local function computeFront(door)
	local attr = door:GetAttribute("TrickOrTreatFront")
	if typeof(attr) == "Vector3" and Vector3.new(attr.X, 0, attr.Z).Magnitude > 1e-3 then
		return Vector3.new(attr.X, 0, attr.Z).Unit
	end
	-- Attribute missing/zero: derive from the knocker mesh's side of the door plane.
	local model = door:FindFirstAncestorWhichIsA("Model")
	if model then
		for _, inst in ipairs(model:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Name:lower():find("knocker") then
				local sign = (door.CFrame:PointToObjectSpace(inst.Position).Z > 0) and 1 or -1
				local v = door.CFrame.ZVector * sign
				local flat = Vector3.new(v.X, 0, v.Z)
				if flat.Magnitude > 1e-3 then
					return flat.Unit
				end
			end
		end
	end
	-- Last resort: the door's own Z axis (flat fallback guards degenerate CFrames).
	local z = door.CFrame.ZVector
	local flatZ = Vector3.new(z.X, 0, z.Z)
	if flatZ.Magnitude > 1e-3 then
		return flatZ.Unit
	end
	return Vector3.new(0, 0, -1)
end

-- Rule 8: staging point must re-arm its own door (> 17) and clear every other
-- door (> 14), because we wait there during the cooldown/gap window.
local function stagingIsClear(own, pos, allDoors)
	if horizontalDistXZ(pos, own.Position) <= REARM_RANGE then
		return false
	end
	for _, other in ipairs(allDoors) do
		if horizontalDistXZ(pos, other.Position) <= KNOCK_RANGE then
			return false
		end
	end
	return true
end

-- Rule 8: staging = door + front*19, with a runtime safety scan along front.
local function computeStagePos(door, front, allDoors)
	local base = Vector3.new(
		door.Position.X + front.X * STAGE_OFFSET,
		door.Position.Y, -- rule 1's 20-stud dy tolerance makes exact floor Y unnecessary
		door.Position.Z + front.Z * STAGE_OFFSET
	)
	if stagingIsClear(door, base, allDoors) then
		return base
	end
	-- Verified layout has ~26 studs clearance, so this scan is a safety net only.
	local fallback, fallbackScore = base, -1
	for dist = STAGE_OFFSET, STAGE_SCAN_MAX do
		local p = Vector3.new(
			door.Position.X + front.X * dist,
			door.Position.Y,
			door.Position.Z + front.Z * dist
		)
		if stagingIsClear(door, p, allDoors) then
			return p
		end
		-- Remember the candidate with the widest min-clearance for the no-solution case.
		local score = math.huge
		for _, other in ipairs(allDoors) do
			local d = horizontalDistXZ(p, other.Position)
			if d < score then
				score = d
			end
		end
		if score > fallbackScore then
			fallback, fallbackScore = p, score
		end
	end
	log("WARN: no fully-clear staging point for a door; using farthest-usable candidate")
	return fallback
end

-- Rule 8: knock point = 4 studs in front, Y pinned to the door's own Y.
local function computeKnockPos(door, front)
	return Vector3.new(
		door.Position.X + front.X * KNOCK_OFFSET,
		door.Position.Y,
		door.Position.Z + front.Z * KNOCK_OFFSET
	)
end

-- Rule 9: nearest-neighbour tour seeded from the character's current XZ.
local function buildRoute(doors, startPos)
	local remaining = {}
	for _, d in ipairs(doors) do
		remaining[#remaining + 1] = d
	end
	local tour = {}
	local cur = startPos
	while #remaining > 0 do
		local bestI, bestD
		for i, d in ipairs(remaining) do
			local dist = horizontalDistXZ(cur, d.Position)
			if not bestD or dist < bestD then
				bestI, bestD = i, dist
			end
		end
		local d = table.remove(remaining, bestI)
		tour[#tour + 1] = d
		cur = d.Position
	end
	return tour
end

-- Rules 2+3+5 combined: seconds until THIS door becomes knockable (<= 0 = now).
local function waitRemainingFor(door)
	local now = Workspace:GetServerTimeNow()
	local need = (readyAt[door] or 0) + SAFETY_MARGIN - now
	if lastKnockTime then
		-- Rule 3: gap spans all doors; distance is from the last knocked door to this one.
		local req = GAP_MIN_SECONDS
		if lastKnockPos then
			req = math.max(GAP_MIN_SECONDS, horizontalDistXZ(lastKnockPos, door.Position) / GAP_SPEED)
		end
		local gapNeed = lastKnockTime + req + SAFETY_MARGIN - now
		if gapNeed > need then
			need = gapNeed
		end
	end
	return need
end

-- Rule 10b: poll until both the per-door cooldown AND the global gap are clear.
-- id = generation token: polling berhenti segera bila id sudah basi (stop/restart).
local function waitForWindow(id, door)
	local deadline = Workspace:GetServerTimeNow() + WINDOW_DEADLINE
	while RUNNING and id == runId do
		if waitRemainingFor(door) <= 0 then
			return true
		end
		if Workspace:GetServerTimeNow() >= deadline then
			return false
		end
		task.wait(0.1)
	end
	return false
end

-- Rule 10d: wait for Knocked to echo back the door we just stepped up to.
-- id = generation token: sama seperti waitForWindow, keluar saat id basi.
local function waitForKnock(id, door, timeout)
	local deadline = Workspace:GetServerTimeNow() + timeout
	while RUNNING and id == runId do
		if knockConfirmed == door then
			return true
		end
		if Workspace:GetServerTimeNow() >= deadline then
			return false
		end
		task.wait(0.05)
	end
	return false
end

--// Rule 6: event handlers — absorb echoes for ANY door, update shared state \\--
local function onKnocked(part, outcomeIndex, serverReadyAt)
	if typeof(part) ~= "Instance" then
		return
	end
	-- readyAt from the server is authoritative; lastKnockTime is derived from it
	-- (readyAt = knockTime + 30) so our gap math matches the server's clock exactly.
	if type(serverReadyAt) == "number" then
		readyAt[part] = serverReadyAt
		lastKnockTime = serverReadyAt - COOLDOWN
	elseif lastKnockTime == nil or Workspace:GetServerTimeNow() > lastKnockTime then
		-- Defensive fallback only: event shape changed upstream. Keep looping.
		lastKnockTime = Workspace:GetServerTimeNow()
		log("WARN: Knocked event had no readyAt number; using server now instead")
	end
	if part:IsA("BasePart") then
		lastKnockPos = part.Position
	end
	knockConfirmed = part
	if VERBOSE then
		log(string.format("Knocked echo (outcome=%s)", tostring(outcomeIndex)))
	end
end

local function onLanded(part, candyAmount)
	if type(candyAmount) ~= "number" then
		return
	end
	stats.candy = stats.candy + candyAmount -- rule 6: Landed arrives ~1.6s after Knocked
	if VERBOSE then
		log(string.format("Landed: +%d candy (total %d)", candyAmount, stats.candy))
	end
end

--// Lifecycle state \\--
local function isRunning()
	return RUNNING
end

-- Refleksi state ke toggle Rayfield TANPA callback: Set(v, true) = skip callback,
-- jadi stop()/start() tidak pernah saling re-enter lewat UI (anti-recursion).
-- No-op bila Rayfield gagal dimuat (farmToggle nil) -> mode headless tetap jalan.
local function syncToggle(desiredRunning)
	if not farmToggle then
		return
	end
	pcall(function()
		farmToggle:Set(desiredRunning, true)
	end)
end

-- Notifikasi aman: window bisa sudah di-Unload (re-run / user tutup) saat dipanggil.
local function notify(title, content)
	local win = rayfieldWindow
	if not win or win.unloaded then
		return
	end
	pcall(function()
		win:Notify({ title = title, content = content })
	end)
end

local function stop()
	runId += 1 -- invalidasi SEMUA loop/printer generasi sekarang (rule 10/13)
	RUNNING = false
	if knockedConn then
		knockedConn:Disconnect()
		knockedConn = nil
	end
	if landedConn then
		landedConn:Disconnect()
		landedConn = nil
	end
	syncToggle(false) -- toggle OFF tanpa callback -> tidak memicu start() lagi
	notify("Halloween Farm", "Farming dihentikan")
	log("stopped (loops and event connections released)")
end

--// Rule 10: one knock attempt on one door, with a single retry on timeout \\--
-- id = token generasi pemanggil; semua yield point dicek, id basi = keluar.
local function attemptDoor(id, door)
	for try = 1, 2 do
		if id ~= runId then
			return false
		end
		if not ensureCharacter(id) then
			return false
		end
		pivotTo(stagePos[door]) -- 10a: stage first (also re-arms this door if needed)
		local windowOk = waitForWindow(id, door) -- 10b
		if id ~= runId then
			return false
		end
		if not windowOk then
			log(string.format("WARN: 90s window deadline breached on route #%d — skipping door", routeIndex))
			return false -- rule 10b: move to the next door instead of hanging
		end
		knockConfirmed = nil -- clear BEFORE stepping in; the echo can arrive instantly
		pivotTo(knockPos[door]) -- 10c
		if waitForKnock(id, door, KNOCK_TIMEOUT) then -- 10e
			stats.knocks = stats.knocks + 1
			if VERBOSE then
				log(string.format("knock ok on route #%d (knocks=%d)", routeIndex, stats.knocks))
			end
			return true
		end
		if id ~= runId then
			return false -- stop/restart di tengah: jangan pivot/log pakai state generasi lama
		end
		-- 10d: timed out — fall back to staging, log, retry the whole sequence once.
		pivotTo(stagePos[door])
		log(string.format("WARN: Knocked timeout on route #%d (try %d/2)", routeIndex, try))
	end
	return false
end

-- Rule 10: outer farming loop — hidup tepat selama generasi id-nya masih aktif.
local function mainLoop(id)
	while RUNNING and id == runId do
		for i, door in ipairs(route) do
			if id ~= runId then
				break
			end
			routeIndex = i
			attemptDoor(id, door) -- false = logged already; cycle to the next door
		end
	end
end

--// Setup \\--
local function findDoors()
	-- Rule 7: tags can lag behind the island load — poll briefly, then give up
	-- (caller logs a recoverable error; tidak lagi mematikan script).
	local deadline = os.clock() + DOOR_POLL_SECONDS
	repeat
		local list = {}
		for _, inst in ipairs(CollectionService:GetTagged("TrickOrTreatDoor")) do
			if inst:IsA("BasePart") then
				list[#list + 1] = inst
			end
		end
		if #list > 0 then
			return list
		end
		task.wait(0.25)
	until os.clock() >= deadline
	return {}
end

local function waitRemote(name)
	local net = RS:WaitForChild("Network", 10)
	local svc = net and net:WaitForChild("TrickOrTreatService", 10)
	local re = svc and svc:WaitForChild("RE", 10)
	return re and re:WaitForChild(name, 10)
end

--// Setup per-START (dulu `main()`) — aman dijalankan berulang kali \\--
-- Tiap start(): discover pintu ulang, hitung ulang fronts/knockPos/stagePos/route,
-- re-seed cooldown dari attribute server, reconnect Knocked/Landed (handle basi
-- diputus dulu), respawn status printer + mainLoop. SEMUA kegagalan non-fatal:
-- log + return false -> toggle dipaksa OFF, window Rayfield tetap hidup
-- (rule 7/6/9/2/13).
local function runSetup(id)
	local doors = findDoors()
	if id ~= runId then
		return false -- sudah stop/restart selagi menunggu tag pintu (rule 7)
	end
	if #doors == 0 then
		-- Dulu kegagalan di sini mematikan seluruh script; sekarang recoverable.
		log("ERROR: no TrickOrTreatDoor parts found after " .. DOOR_POLL_SECONDS .. "s — pindah ke Haunted Island lalu start ulang")
		return false
	end

	local Knocked = waitRemote("Knocked")
	local Landed = waitRemote("Landed")
	if id ~= runId then
		return false
	end
	if not (Knocked and Landed and Knocked:IsA("RemoteEvent") and Landed:IsA("RemoteEvent")) then
		log("ERROR: TrickOrTreatService RE.Knocked/RE.Landed not found — start ulang nanti")
		return false
	end

	-- Rule 7: resolve fronts + per-door positions up front.
	-- Kumpulan per-run sudah di-reset di start() -> tidak ada pintu island lawas.
	local fronts = {}
	for _, door in ipairs(doors) do
		fronts[door] = computeFront(door)
		knockPos[door] = computeKnockPos(door, fronts[door])
	end
	for _, door in ipairs(doors) do
		stagePos[door] = computeStagePos(door, fronts[door], doors)
	end

	-- Rule 2: seed every door's cooldown from the server's join-time value.
	local initialReady = LocalPlayer:GetAttribute("TrickOrTreatReadyAt")
	if type(initialReady) ~= "number" then
		initialReady = Workspace:GetServerTimeNow() + COOLDOWN
	end
	for _, door in ipairs(doors) do
		readyAt[door] = initialReady
	end

	-- Rule 9: route seeded from where the character currently stands.
	local hrp = ensureCharacter(id) -- returns nil only when stopped/superseded
	if id ~= runId then
		return false
	end
	if not hrp then
		log("ERROR: no live character available — start ulang setelah respawn")
		return false
	end
	route = buildRoute(doors, hrp.Position)
	routeIndex = 1

	-- Rule 6: listen-only connections; pcall so a missing hook is reported, not silent.
	-- Putuskan sisa handle generasi lama dulu -> restart tidak pernah dobel-connect.
	if knockedConn then
		knockedConn:Disconnect()
		knockedConn = nil
	end
	if landedConn then
		landedConn:Disconnect()
		landedConn = nil
	end
	local okK, errK = pcall(function()
		knockedConn = Knocked.OnClientEvent:Connect(onKnocked)
	end)
	if not okK then
		log("ERROR: could not connect Knocked.OnClientEvent: " .. tostring(errK))
		return false
	end
	local okL, errL = pcall(function()
		landedConn = Landed.OnClientEvent:Connect(onLanded)
	end)
	if not okL then
		-- Candy tracking is optional; the farm still works without it.
		log("WARN: could not connect Landed.OnClientEvent (candy totals will stay 0): " .. tostring(errL))
	end

	-- Rule 13: periodic status line (respawn tiap start; mati saat id basi).
	task.spawn(function()
		while RUNNING and id == runId do
			task.wait(STATUS_INTERVAL)
			if not RUNNING or id ~= runId then
				break
			end
			local nextIn = math.huge
			for _, door in ipairs(route) do
				local rem = waitRemainingFor(door)
				if rem < nextIn then
					nextIn = rem
				end
			end
			nextIn = math.max(0, nextIn)
			log(string.format(
				"knocks=%d candy=%d route=%d/%d nextKnock~%.1fs",
				stats.knocks, stats.candy, routeIndex, #route,
				nextIn
			))
			-- Sinkron elemen Stats di window Rayfield. pcall karena window bisa
			-- saja sudah di-Unload saat printer ini bangun dari wait di atas.
			pcall(function()
				if statsText then
					statsText:Set(string.format(
						"knocks: %d · candy: %d\nroute %d/%d · next ~%.1fs",
						stats.knocks, stats.candy, routeIndex, #route, nextIn
					))
				end
			end)
		end
	end)

	task.spawn(mainLoop, id)
	log(string.format("aktif — %d doors, route seeded, farming candy", #doors))
	return true
end

--// Lifecycle: start \\--
-- start(): no-op kalau sudah jalan; selain itu seluruh setup di bawah pcall.
-- Return true = berjalan, false = gagal (sudah di-log, state dibersihkan, UI tetap).
local function start()
	if RUNNING then
		return true -- sudah berjalan: no-op
	end
	RUNNING = true
	runId += 1
	local id = runId

	-- Kumpulan per-run dibuang total -> referensi pintu island lawas tidak nyangkut,
	-- dan tiap mulai ulang benar-benar recompute (rule 7/9/2) dari nol.
	readyAt = {}
	lastKnockTime = nil
	lastKnockPos = nil
	knockConfirmed = nil
	route = {}
	routeIndex = 1
	stagePos = {}
	knockPos = {}
	if knockedConn then
		knockedConn:Disconnect()
		knockedConn = nil
	end
	if landedConn then
		landedConn:Disconnect()
		landedConn = nil
	end

	local ok, res = pcall(runSetup, id)
	if id ~= runId then
		return false -- digantikan stop()/start() lain; generasi baru yang pegang state
	end
	if not ok or res ~= true then
		-- Kegagalan setup: bersihkan state parsial, toggle dipaksa OFF (recoverable).
		runId += 1
		RUNNING = false
		if knockedConn then
			knockedConn:Disconnect()
			knockedConn = nil
		end
		if landedConn then
			landedConn:Disconnect()
			landedConn = nil
		end
		local reason
		if not ok then
			-- error tak terduga di luar jalur yang sudah di-log sendiri
			reason = tostring(res)
			log("ERROR: setup failed: " .. reason)
		else
			reason = "setup gagal — detail error ada di console"
		end
		syncToggle(false)
		notify("Halloween Farm", "Farming gagal dimulai: " .. reason)
		return false
	end
	syncToggle(true) -- toggle ON tanpa callback -> tidak re-enter stop()
	notify("Halloween Farm", "Farming dimulai")
	return true
end

--// Jalur load \\--
-- API di-assign DI SINI (bukan di start()) supaya stats/start/stop/isRunning
-- selalu bisa diakses walau start() gagal, AUTO_START = false, atau Rayfield
-- gagal dimuat.
ENV.halloweenFarm = {
	stats = stats,
	stop = stop,
	start = start,
	isRunning = isRunning,
}

--// UI: Rayfield Gen 2 — dimuat + dibangun SEKALI per eksekusi, di jalur load \\--
-- Loader dibungkus pcall: gagal (tanpa HttpGet / tanpa jaringan) = lanjut tanpa
-- UI (headless), script tidak pernah gagal fatal keluar — kontrol tetap via API.
do
	local okRF, resRF = pcall(function()
		return loadstring(game:HttpGet("https://sirius.menu/gen2"))()
	end)
	if okRF and type(resRF) == "table" then
		Rayfield = resRF
	else
		log("ERROR: Rayfield gagal dimuat (" .. tostring(resRF) .. ") — lanjut tanpa UI, pakai getgenv().halloweenFarm.{start,stop}")
	end
end

if Rayfield then
	local okUI, errUI = pcall(function()
		local window = Rayfield:CreateWindow({
			name = "Halloween Auto Candy",
			subtitle = "Anime Dice — Trick-or-Treat",
			theme = "ember",
			showName = "Candy Farm",
		})
		rayfieldWindow = window
		-- Handle disimpan global SEBELUM build elemen: walau build setengah jadi
		-- gagal, re-run berikutnya tetap bisa Unload -> tidak ada window bocor.
		ENV.__halloweenRayfield = window

		local tab = window:CreateTab({ name = "Farm" })

		-- Toggle SATU-SATUNYA kontrol UI; callback = jalur satu-satunya yang
		-- memanggil start()/stop() dari UI (start/stop sudah terdefinisi di atas).
		farmToggle = tab:CreateToggle({
			name = "Auto Farm Candy",
			description = "Jalan 7 pintu haunted house, knock sesuai cooldown server.",
			flag = "AutoFarmCandy",
			value = false,
			forgetState = true, -- tidak ada persistensi: AUTO_START = satu-satunya sumber kebenaran load
			callback = function(value)
				if value then
					start()
				else
					stop()
				end
			end,
		})

		tab:CreateDivider()

		statsText = tab:CreateText({
			name = "Stats",
			text = "knocks: 0 · candy: 0",
		})
	end)
	if not okUI then
		log("ERROR: Rayfield UI gagal dibuat: " .. tostring(errUI))
	end
end

-- AUTO_START = true -> langsung farming saat script di-load. Ganti false di blok
-- config kalau mau mode start-manual lewat toggle / API.
if AUTO_START then
	local okStart, errStart = pcall(start)
	if not okStart then
		log("ERROR: start() threw: " .. tostring(errStart))
	end
end

-- Sinkron toggle dengan kenyataan APA PUN yang terjadi di atas (start sukses,
-- start gagal, AUTO_START false, atau Rayfield gagal dimuat -> no-op).
syncToggle(isRunning())
