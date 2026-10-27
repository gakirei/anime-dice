--// Anime Dice — Quirk Auto Farm (semua quirk bisa jadi target) \\--
-- Me-roll mesin Quirk di unit Common milik player sampai tiap unit mendapat
-- quirk target (pilih dari semua quirk di dropdown). Server QUIRKSERVICE:
--   • Roll: Network.QuirkService.RE.Roll — FireServer(unitKey) SAJA.
--     Argumen kedua (force=true) melewati proteksi — DILARANG dipakai script ini.
--   • Proteksi: Network.QuirkService.RE.SetQuirkProtected — FireServer(quirk, bool).
--     Server hanya menerima quirk dengan config weight < 100. Proteksi bersifat
--     GLOBAL per NAMA quirk dan tersimpan di profile — bukan per unit, dan TIDAK
--     mempengaruhi odds roll (LuckyWeights.Roll tidak melihat daftar proteksi).
--   • Debounce server 0.2s per pemain -> interval client ROLL_INTERVAL = 0.25s.
--   • Server MENOLAK DIAM-DIAM (tanpa error) bila: quirk unit sedang diproteksi
--     (butuh arg force), uang kurang, kena debounce, atau pemain TIDAK berada di
--     zona "Quirks" (AntiCheatService.IsNearZone). Semua roll ditolak = tidak ada
--     yang berubah -> dideteksi oleh guard "rotasi tanpa roll diterima".
--
--// Kebijakan proteksi (PENTING) \\--
-- HANYA quirk target yang ditahan. Saat start:
--   1. Semua quirk langka lain (weight < 100: Midas Touch, Fortune's Favor,
--      Sovereign, Tycoon) DILEPAS proteksinya, supaya unit yang kebetulan
--      mendarat di sana bisa di-reroll lagi — unit tidak "nyangkut" memegang
--      quirk non-target.
--   2. Quirk target justru DIPROTEKSI SEBELUM roll pertama, jadi begitu mendarat
--      langsung terkunci (tidak ada window 0.25s antara hit dan protect).
--   3. Inventori lama diselamatkan lewat BLACKLIST PER UNIT KEY: setiap unit yang
--      sudah memegang quirk langka (weight < 100) selain target tidak pernah
--      dijadikan kandidat, walau proteksi nama quirk-nya dilepas.
-- Saat stop, snapshot proteksi awal dipulihkan (target tetap terkunci).
-- Konsekuensi yang diterima: quirk langka non-target yang MENDARAT SELAMA FARM
-- akan di-reroll dan hilang (dihitung di stats.rareLost + log).
--
-- Odds: total weight pool ≈ 5556. Sovereign 0.15 (≈1/37.041), Fortune's Favor 0.5
-- (≈1/11.112), Midas Touch 1 (≈1/5.556), Prodigy 2 (≈1/2.778), Tycoon 2.5, lalu
-- tier III weight 10. Quirk weight >= 100 bisa dicari tapi tidak bisa diproteksi.
-- Script INI MEMAKAI UANG IN-GAME — AUTO_START = false, start manual saja.
--
-- Usage : loadstring(readfile("quirk-auto-farm.luau"))()
-- UI    : LightScriptHub — GUI LOKAL (tanpa HttpGet/dependensi jaringan), SATU window
--           "QUIRK AUTO FARM" dengan tab Farm / Info / Misc: dropdown target, toggle
--           Auto Farm Quirk, toggle Blacklist unit langka, stats live, anti-AFK.
--           Toggle ON = start, OFF = stop. AUTO_START = false: tidak jalan otomatis.
--           Bila pembuatan GUI gagal, script TETAP jalan tanpa UI (headless) —
--           kontrol via API di bawah.
-- API   : getgenv().quirkFarm = { stats, start, stop, isRunning, setTarget,
--             blacklist, rebuildBlacklist, webhookUrl }
--             stats          -- { rolls, accepted, hits, rareLost, moneySpent } akumulatif
--             start()        -- true = berjalan, false = gagal (recoverable)
--             stop()         -- hentikan loop + pulihkan snapshot proteksi
--             isRunning()    -- status running sekarang
--             setTarget(name)-- nama quirk apa pun dari config game; proteksi +
--                               blacklist langsung diterapkan ulang bila berjalan
--             blacklist      -- set unitKey -> true (unit yang tidak boleh di-reroll)
--             rebuildBlacklist() -- hitung ulang blacklist dari inventori sekarang
--             pullConfig()   -- tarik config dari dashboard sekarang (true, code | false, err)
--             pushStatus()   -- kirim status ke dashboard sekarang
--             relayHit(unit, quirk) -- kirim HIT lewat server (Discord diposting server)
--             testHit()      -- kirim HIT percobaan lewat relay (cek cepat dari console)
--             distanceToMachine() -- jarak (studs) ke pusat zona Quirks, nil kalau tak terbaca
--             teleportToMachine() -- pindah ke mesin pakai chunked teleport (juga saat stop)
--             remote         -- { enabled, keySet, lastError, lastPullAt, appliedRev }
-- Remote : OPEN CHANNEL — sync key TIDAK wajib, jadi device tidak menyimpan rahasia.
--          Kalau key diisi, ia tetap dikirim sebagai x-sync-key (opsional, untuk
--          pengetatan nanti): getgenv().QUIRK_SYNC_KEY -> REMOTE_CONFIG.SYNC_KEY ->
--          file "quirk_sync_key.txt". Webhook Discord TIDAK PERNAH diterima device:
--          server men-strip nilainya dari config dan yang memposting ke Discord.
-- Idempotent: re-running stops the previous instance first (yang juga memulihkan
-- proteksi), destroys the previous LightScriptHub GUI by name, then builds exactly
-- one new window — no stacked windows, no double loops. Lifecycle memakai generation
-- token (runId): setiap start/stop menaikkan runId, semua loop membawa id
-- generasinya dan keluar saat id ~= runId.

--// Teardown instance lama — urutan di bawah WAJIB urut (window/loop bocor kalau tidak) \\--
local ENV = (type(getgenv) == "function") and getgenv() or _G

-- (1) Hentikan farm generasi lama dulu -> stop() juga memulihkan proteksi yang
--     sempat diubah generasi itu, jadi re-run tidak meninggalkan state aneh.
if type(ENV.quirkFarm) == "table" and type(ENV.quirkFarm.stop) == "function" then
	pcall(ENV.quirkFarm.stop)
end

-- (1a) Loop remote generasi lama (bila ada) keluar lewat generation token —
-- stop() tidak menyentuhnya, jadi tanpa ini re-run bisa meninggalkan poller kedua.
ENV.__quirkFarmRemoteGen = (tonumber(ENV.__quirkFarmRemoteGen) or 0) + 1

-- (2) GUI generasi lama tidak perlu ditutup manual di sini: blok UI di jalur load
--     menghancurkan ScreenGui bernama "LightScriptHub" lebih dulu (nama unik, jadi
--     re-run tidak pernah menghasilkan dua window bertumpuk).

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer

--// Config \\--
local AUTO_START = false -- script MEMAKAI uang in-game: jangan start otomatis
local ROLL_INTERVAL = 0.25 -- server debounce 0.2s per pemain -> 0.25s ambang aman
local REFUSAL_CONFIRM_READS = 6 -- baca ulang quirk sebelum menyimpulkan roll ditolak (replikasi bisa > interval roll); hanya 2 refusal pertama per unit
local REFUSAL_CONFIRM_DELAY = 0.05 -- jeda tiap baca ulang; total ~0.3s
local WEBHOOK_URL = "" -- HANYA untuk mode lokal / fallback. JANGAN hardcode: getgenv().QUIRK_WEBHOOK atau file "webhook_url.txt"
-- Webhook dashboard TIDAK ikut ke device (server men-strip-nya) — kalau remote
-- aktif, notifikasi HIT dikirim lewat relay server. Urutan sumber lokal:
-- getgenv().quirkFarm.webhookUrl -> getgenv().QUIRK_WEBHOOK -> file "webhook_url.txt".
-- Kosong semua = tanpa notifikasi lokal (farm tetap jalan). URL tidak pernah di-log.
do
	local function trimHook(value)
		return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
	end
	local candidate = ENV.QUIRK_WEBHOOK
	if type(candidate) ~= "string" or trimHook(candidate) == "" then
		candidate = WEBHOOK_URL
	end
	if trimHook(candidate) == "" and type(readfile) == "function" then
		local ok, data = pcall(readfile, "webhook_url.txt")
		if ok and type(data) == "string" then
			candidate = data
		end
	end
	WEBHOOK_URL = trimHook(candidate)
end
local STUCK_LIMIT = 10 -- ambigu berturut-turut (quirk tak berubah + uang tak turun) sebelum unit dilewati; 10 menutup roll sukses yang kebetulan mendarat di quirk sama (~0.18^10)
local EARLY_ABORT_UNITS = 3 -- unit berturut-turut ditolak tanpa satu pun accepted -> farm stop (indikasi di luar zona)
local AUTO_WALK = true -- jalan sendiri ke mesin Quirk saat start kalau masih jauh
local WALK_NEAR_DIST = 40 -- sudah dianggap "di mesin" bila jarak ke pusat zona <= ini
local WALK_TIMEOUT = 150 -- batas total berjalan; lewat ini = gagal, arahkan manual
local WALK_WAYPOINT_TIMEOUT = 12 -- batas per waypoint sebelum path dihitung ulang
local WALK_RECOMPUTE_LIMIT = 6 -- jumlah path yang boleh dihitung ulang
-- Chunked teleport: anti-cheat memvalidasi PERPINDAHAN BERSIH per jendela waktu
-- (~1s), ambang ~150 studs. Terukur di client:
--   • 1 lompatan 150 studs = lolos; 160/175/183/190/200 = snap balik
--   • 100 studs tiap 0,45s (222/s) = diterima sesaat, lalu di-revert ~1s kemudian
--   • 12 studs tiap 0,1s (120/s) = 234 -> 29 studs dalam 2,5s, stabil 3s+
-- Jadi batasnya LAJU (~<=150 studs/s), bukan ukuran per langkah. Ini juga
-- melewati conveyor yang membuat pathfinding kebingungan (tanpa path sama sekali).
local TELEPORT_WALK = true -- coba chunked teleport dulu, fallback ke pathfinding
local TELEPORT_STEP = 12 -- studs per langkah (dengan jeda di bawah = 120 studs/s)
local TELEPORT_DELAY = 0.1 -- jeda per langkah (detik)
local TELEPORT_STOP_DIST = 28 -- berhenti sedekat ini ke pusat zona Quirks
local TELEPORT_MAX_CHUNKS = 150 -- batas langkah per start (jaga-jaga kalau posisi ditolak)
local TELEPORT_STALL_LIMIT = 15 -- langkah tanpa progres sebelum menyerah ke pathfinding
local PROTECT_SETTLE_TIMEOUT = 3 -- detik menunggu replikasi SetQuirkProtected dikonfirmasi client
local BLACKLIST_RARE_UNITS = true -- blacklist unit lama yang sudah pegang quirk langka (weight < 100) selain target

--// Remote config (Supabase edge function) \\--
-- OPEN CHANNEL: device tidak menyimpan rahasia apa pun. Sync key opsional; kalau
-- diisi tetap dikirim sebagai x-sync-key (untuk pengetatan nanti). Webhook Discord
-- hanya hidup di server (lihat blok WEBHOOK_URL di bawah).
local REMOTE_CONFIG = {
	ENABLED      = true,
	URL          = "https://rlbmftsefonfdqfhyjij.supabase.co/functions/v1/quirk",
	SYNC_KEY     = "",   -- empty = disabled (local-only mode); fill from the dashboard
	POLL         = 15,   -- seconds between config pulls
	STATUS_EVERY = 30,   -- seconds between status pushes
}

--// Sync key resolution (key TIDAK pernah di-log / ditulis ke disk) \\--
-- Urutan: getgenv().QUIRK_SYNC_KEY -> REMOTE_CONFIG.SYNC_KEY -> file "quirk_sync_key.txt".
-- Tujuannya: key bisa disimpan di LUAR file ini, jadi aman walau script di-load dari
-- raw GitHub URL (jangan pernah commit key asli ke repo publik).
local SYNC_KEY = ""
do
	local function trimKey(value)
		return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
	end
	local sources = {
		function() -- 1. runtime override, diset sebelum load / dari executor console
			local value = ENV.QUIRK_SYNC_KEY
			return type(value) == "string" and value or nil
		end,
		function() -- 2. konstanta di file (hanya untuk pemakaian lokal/private)
			return REMOTE_CONFIG.SYNC_KEY
		end,
		function() -- 3. file teks di workspace executor
			if type(readfile) ~= "function" then
				return nil
			end
			local ok, data = pcall(readfile, "quirk_sync_key.txt")
			return (ok and type(data) == "string") and data or nil
		end,
	}
	for _, read in ipairs(sources) do
		local ok, value = pcall(read)
		local key = ok and trimKey(value) or ""
		if key ~= "" then
			SYNC_KEY = key
			break
		end
	end
end

--// State \\--
local state = {
	running = false,
	targetQuirk = "Prodigy", -- diganti lewat dropdown / setTarget()
	currentLabel = nil, -- unit yang sedang diproses (dilaporkan ke dashboard)
	candidateCount = 0, -- jumlah kandidat rotasi terakhir
	selfProtected = {}, -- nama quirk yang proteksinya KITA nyalakan -> tetap protected setelah stop
	blacklistRare = BLACKLIST_RARE_UNITS, -- dicerminkan dari toggle UI / config remote
	rollInterval = ROLL_INTERVAL, -- live: prosesCandidate membaca ini tiap wait
	stuckLimit = STUCK_LIMIT, -- live: ambang unit dianggap stuck
	webhookUrl = "", -- override runtime (remote); kosong = pakai WEBHOOK_URL
	appliedRev = 0, -- rev config remote terakhir yang sudah diterapkan
	lateSignalSeen = false, -- sudah pernah lihat sinyal roll telat? (log sekali)
	remote = { enabled = false, keySet = false, lastError = nil, lastPullAt = 0, appliedRev = 0 },
}
local runId = 0 -- generation token: tiap start/stop naik 1 -> loop generasi lama mati bersih
local stats = { rolls = 0, accepted = 0, hits = 0, rareLost = 0, moneySpent = 0 } -- akumulatif lintas stop/start
local blacklist = {} -- unitKey -> true: unit yang TIDAK boleh di-reroll (inventori lama)
state.blacklist = blacklist -- referensi sama, dipakai untuk hitung status remote
local protectionSnapshot -- name -> bool, diambil saat start dan dipulihkan saat stop
local DC -- DataController hasil require
local RollRE, ProtectRE -- remote QuirkService
local QuirksConfig -- cache require config Quirks
local stop -- forward-declare: mainLoop memanggil stop() sebelum definisinya di bawah

--// Handle GUI (LightScriptHub) — diisi SEKALI di jalur load; semuanya nil = headless \\--
-- GUI dibuat lokal (tanpa HttpGet), jadi tidak ada dependensi jaringan. Semua referensi
-- di bawah WAJIB nil-safe: kalau pembuatan GUI gagal, farm tetap jalan lewat API.
local guiRoot -- ScreenGui "LightScriptHub"
local guiNotify -- CreateNotification(title, message, duration)
local farmToggle -- handle CreateToggle: Set(value, silent) / Get()
local statsText -- handle label stats: Set(text)
local targetDropdown -- handle CreateDropdown: Set(name, silent) / Refresh(list)

local function log(msg)
	print("[QuirkFarm] " .. msg)
end

--// Helpers \\--
-- Remote via WaitForChild berantai + timeout: aman bila Network belum ter-load.
local function waitRemote(name)
	local net = RS:WaitForChild("Network", 10)
	local svc = net and net:WaitForChild("QuirkService", 10)
	local re = svc and svc:WaitForChild("RE", 10)
	return re and re:WaitForChild(name, 10)
end

-- Baca uang dengan pcall: DC bisa melempar kapan saja (respawn / data belum siap).
local function readMoney()
	local ok, v = pcall(function()
		return DC.Money()
	end)
	if ok then
		return v
	end
	return nil
end

-- Quirk unit: entry.attributes.quirk adalah STRING live (tabel reaktif ditulis
-- in-place oleh replikasi), bukan snapshot basi. Tetap dukung bentuk callable
-- Value kalau game membungkusnya di versi lain.
local function readQuirk(entry)
	local ok, v = pcall(function()
		local q = entry.attributes.quirk
		if type(q) == "function" then
			return q()
		end
		return q
	end)
	if ok then
		return v
	end
	return nil
end

-- Config Quirks (weight tiap nama) — dipakai untuk batas "langka" = weight < 100,
-- sama persis dengan syarat server pada SetQuirkProtected.
local function getQuirks()
	if QuirksConfig then
		return QuirksConfig
	end
	local ok, mod = pcall(function()
		return require(RS.Framework.Features.Quirks.Quirks)
	end)
	if ok and type(mod) == "table" then
		QuirksConfig = mod
		return mod
	end
	return nil
end

local function isRareQuirk(name)
	local quirks = getQuirks()
	local cfg = (quirks and name) and quirks[name] or nil
	return type(cfg) == "table" and type(cfg.weight) == "number" and cfg.weight < 100
end

-- Semua quirk dari config game, urut paling langka -> paling umum. Dipakai untuk
-- isi dropdown dan validasi target. Fallback = snapshot v803 kalau require gagal.
local FALLBACK_QUIRKS = {
	{ name = "Sovereign", weight = 0.15 },
	{ name = "Fortune's Favor", weight = 0.5 },
	{ name = "Midas Touch", weight = 1 },
	{ name = "Prodigy", weight = 2 },
	{ name = "Tycoon", weight = 2.5 },
	{ name = "Fortune III", weight = 10 },
	{ name = "Gifted III", weight = 10 },
	{ name = "Refined III", weight = 10 },
	{ name = "Swift III", weight = 10 },
	{ name = "Wealth III", weight = 10 },
	{ name = "Fortune II", weight = 100 },
	{ name = "Gifted II", weight = 100 },
	{ name = "Refined II", weight = 100 },
	{ name = "Swift II", weight = 100 },
	{ name = "Wealth II", weight = 100 },
	{ name = "Fortune I", weight = 1000 },
	{ name = "Gifted I", weight = 1000 },
	{ name = "Refined I", weight = 1000 },
	{ name = "Swift I", weight = 1000 },
	{ name = "Wealth I", weight = 1000 },
}

local quirkListCache
local function quirkOptions()
	if quirkListCache then
		return quirkListCache
	end
	local list = {}
	local quirks = getQuirks()
	if quirks then
		for name, cfg in pairs(quirks) do
			if type(cfg) == "table" and type(cfg.weight) == "number" then
				list[#list + 1] = { name = name, weight = cfg.weight }
			end
		end
	end
	if #list == 0 then
		for _, entry in ipairs(FALLBACK_QUIRKS) do
			list[#list + 1] = { name = entry.name, weight = entry.weight }
		end
	end
	table.sort(list, function(a, b)
		if a.weight ~= b.weight then
			return a.weight < b.weight
		end
		return a.name < b.name
	end)
	quirkListCache = list
	return list
end

local function quirkWeight(name)
	for _, option in ipairs(quirkOptions()) do
		if option.name == name then
			return option.weight
		end
	end
	return nil
end

local function isKnownQuirk(name)
	return type(name) == "string" and quirkWeight(name) ~= nil
end

-- Server menolak SetQuirkProtected untuk weight >= 100, jadi target seperti itu
-- tetap bisa dicari tapi tidak akan tertahan.
local function canProtectQuirk(name)
	local weight = quirkWeight(name)
	return weight ~= nil and weight < 100
end

local function quirkNames()
	local names = {}
	for _, option in ipairs(quirkOptions()) do
		names[#names + 1] = option.name
	end
	return names
end

-- Map proteksi global (nama quirk -> boolean) dibaca live dari data client.
local function protectedMap()
	local ok, map = pcall(function()
		return DC.ProtectedQuirks()
	end)
	if ok and type(map) == "table" then
		return map
	end
	return {}
end

local function isProtected(name)
	if name == nil then
		return false
	end
	local v = protectedMap()[name]
	if type(v) == "function" then
		local ok, r = pcall(v)
		return ok and r == true
	end
	return v == true
end

local function fireProtect(name, desired)
	pcall(function()
		ProtectRE:FireServer(name, desired == true)
	end)
end

--// Proteksi: snapshot / terapkan / pulihkan \\--
local function snapshotProtections()
	local snap = {}
	for name, v in pairs(protectedMap()) do
		local value = v
		if type(v) == "function" then
			local ok, r = pcall(v)
			value = ok and r or false
		end
		snap[name] = value == true
	end
	return snap
end

-- Terapkan kebijakan: target = protected, semua quirk langka lain = UNPROTECTED.
-- Menunggu konfirmasi replikasi supaya tidak lanjut roll dengan state proteksi
-- yang belum sinkron (roll-nya akan ditolak server).
local function applyProtections(target)
	local quirks = getQuirks()
	if not quirks then
		log("WARN: config Quirks tidak terbaca — proteksi tidak diubah")
		return false
	end

	local desired = {}
	for name, cfg in pairs(quirks) do
		if type(cfg) == "table" and type(cfg.weight) == "number" and cfg.weight < 100 then
			desired[name] = (name == target)
		end
	end
	if canProtectQuirk(target) then
		desired[target] = true
	end

	for name, want in pairs(desired) do
		if isProtected(name) ~= want then
			fireProtect(name, want)
			if want then
				state.selfProtected[name] = true
			end
			log(string.format("proteksi %s -> %s", name, tostring(want)))
			task.wait(0.05)
		elseif want then
			state.selfProtected[name] = true
		end
	end

	local deadline = os.clock() + PROTECT_SETTLE_TIMEOUT
	while os.clock() < deadline do
		local allOk = true
		for name, want in pairs(desired) do
			if isProtected(name) ~= want then
				allOk = false
				break
			end
		end
		if allOk then
			return true
		end
		task.wait(0.1)
	end

	for name, want in pairs(desired) do
		if isProtected(name) ~= want then
			log(string.format("WARN: proteksi %s tidak terkonfirmasi (harus %s)", name, tostring(want)))
		end
	end
	return false
end

-- Pulihkan snapshot proteksi awal. Quirk yang proteksinya KITA nyalakan tetap
-- protected (target hasil farm tidak boleh ikut dilepas).
local function restoreProtections()
	local snap = protectionSnapshot
	protectionSnapshot = nil
	if type(snap) ~= "table" then
		return
	end
	for name, wasProtected in pairs(snap) do
		local desired = state.selfProtected[name] or wasProtected
		if isProtected(name) ~= desired then
			fireProtect(name, desired)
			task.wait(0.05)
		end
	end
	local target = state.targetQuirk
	if canProtectQuirk(target) and not isProtected(target) then
		fireProtect(target, true)
	end
	log("proteksi dipulihkan")
end

--// Blacklist per unit \\--
-- Unit yang SUDAH memegang quirk langka (weight < 100) selain target tidak pernah
-- dijadikan kandidat, jadi proteksi nama quirk-nya aman dilepas tanpa kehilangan
-- inventori lama. Dihitung ulang saat start / ganti target / toggle blacklist.
local function rebuildBlacklist()
	table.clear(blacklist)
	if not state.blacklistRare then
		return 0
	end
	local okInv, inventory = pcall(function()
		return DC.Inventory()
	end)
	if not okInv or type(inventory) ~= "table" then
		return 0
	end
	local count = 0
	for key, entry in pairs(inventory) do
		local quirk = readQuirk(entry)
		if quirk ~= nil and quirk ~= state.targetQuirk and isRareQuirk(quirk) then
			blacklist[key] = true
			count += 1
		end
	end
	return count
end

--// Stats UI sink \\--
local function updateStatsText(unitLabel)
	state.currentLabel = unitLabel or state.currentLabel
	pcall(function()
		if statsText then
			statsText:Set(string.format(
				"rolls: %d · accepted: %d · hits: %d\nrare dibuang: %d · money spent: %d\ncurrent: %s · target: %s",
				stats.rolls, stats.accepted, stats.hits, stats.rareLost, stats.moneySpent,
				unitLabel or "-", state.targetQuirk
			))
		end
	end)
end

--// Lifecycle utils \\--
local function isRunning()
	return state.running
end

-- Refleksi state ke toggle GUI TANPA callback: Set(v, true) = skip callback,
-- jadi stop()/start() tidak pernah saling re-enter lewat UI (anti-recursion).
local function syncToggle(desiredRunning)
	if not farmToggle then
		return
	end
	pcall(function()
		farmToggle:Set(desiredRunning, true)
	end)
end

-- Notifikasi aman: GUI bisa sudah dihancurkan (re-run / user tekan X) saat dipanggil.
local function notify(title, content)
	if not guiNotify then
		return
	end
	pcall(guiNotify, title, content, 3)
end

--// Webhook \\--
-- HTTP POST lintas-executor (request/http_request/syn/fluxus/krnl/HttpService)
-- untuk Discord — pola yang sama dengan anime-dice-all-in-one.luau.
local function httpPost(url, payload)
	local okEnc, body = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not okEnc then
		return false, "JSONEncode: " .. tostring(body)
	end

	local candidates = {}
	local function add(name, f)
		if type(f) == "function" then
			table.insert(candidates, { name = name, fn = f })
		end
	end
	for _, n in ipairs({ "request", "http_request", "http_post", "HttpPost", "httpRequest" }) do
		add(n, ENV[n])
		if ENV ~= _G then
			add(n, _G[n])
		end
	end
	if type(syn) == "table" then
		add("syn.request", syn.request)
	end
	if type(http) == "table" then
		add("http.request", http.request)
	end
	if type(fluxus) == "table" then
		add("fluxus.request", fluxus.request)
	end
	if type(krnl) == "table" then
		add("krnl.request", krnl.request)
	end
	add("HttpService:RequestAsync", function(opts)
		return HttpService:RequestAsync(opts)
	end)

	local lastErr
	for _, c in ipairs(candidates) do
		local ok, res = pcall(c.fn, {
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
		if ok and type(res) == "table" then
			local code = res.StatusCode or res.status or res.Status
			if res.Success == true or (type(code) == "number" and code >= 200 and code < 300) then
				return true, c.name .. " " .. tostring(code or "")
			end
			lastErr = c.name .. " HTTP " .. tostring(code)
		else
			lastErr = c.name .. ": " .. tostring(res)
		end
	end
	return false, tostring(lastErr)
end

local function getWebhookUrl()
	if type(state.webhookUrl) == "string" and state.webhookUrl ~= "" then
		return state.webhookUrl
	end
	local api = ENV.quirkFarm
	if type(api) == "table" and type(api.webhookUrl) == "string" and api.webhookUrl ~= "" then
		return api.webhookUrl
	end
	return WEBHOOK_URL
end

-- Notifikasi Discord untuk HIT target saja (rare yang dibuang cukup di log —
-- tidak di-webhook supaya tidak spam saat farming panjang).
local function sendWebhook(unitName, quirk)
	local url = getWebhookUrl()
	if type(url) ~= "string" or url == "" then
		return
	end
	local payload = {
		username = "Quirk Farm",
		embeds = {
			{
				title = "🎯 " .. quirk .. " → " .. unitName,
				description = ("**%s** mendapat quirk **%s** di unit **%s** (langsung diproteksi)."):format(
					tostring(LocalPlayer.Name), quirk, unitName
				),
				color = 15105570, -- ember/orange, sewarna tema window
				fields = {
					{ name = "Rolls", value = tostring(stats.rolls), inline = true },
					{ name = "Hits", value = tostring(stats.hits), inline = true },
					{ name = "Rare dibuang", value = tostring(stats.rareLost), inline = true },
					{ name = "Money spent", value = tostring(stats.moneySpent), inline = true },
					{ name = "Time", value = os.date("!%H:%M:%S UTC"), inline = true },
				},
				timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			},
		},
	}
	local ok, info = httpPost(url, payload)
	log("discord webhook " .. (ok and "OK" or "GAGAL") .. ": " .. tostring(info))
end

-- notifyHit = satu-satunya jalur notifikasi HIT. Default-nya webhook lokal; di
-- bawah nanti di-reassign ke relay server (device tidak pernah pegang URL webhook).
local notifyHit = sendWebhook

--// Farm loop \\--
-- Snapshot inventory -> filter unit Common yang quirknya BELUM target, tidak
-- di-blacklist, dan tidak sedang memegang quirk terproteksi (target holders
-- otomatis gugur lewat perbandingan quirk).
local function computeCandidates(id)
	local candidates = {}
	state.candidateCount = 0
	local skippedBlack, skippedProtected = 0, 0
	local okInv, inventory = pcall(function()
		return DC.Inventory()
	end)
	if not okInv or type(inventory) ~= "table" then
		log("WARN: gagal membaca Inventory — rotasi dilewati")
		return candidates
	end
	for key, entry in pairs(inventory) do
		if id ~= runId then
			break
		end
		-- Lookup config entry per unit; gagal = lewati entry ini (non-fatal).
		local okCfg, entryConfig = pcall(function()
			return require(RS.Framework.Features.Inventory.EntryRegistry).getEntryConfig(entry.name)
		end)
		if okCfg and type(entryConfig) == "table" then
			if entryConfig.kind == "Unit" and entryConfig.rarity == "Common" then
				local quirk = readQuirk(entry)
				if quirk ~= state.targetQuirk then
					if blacklist[key] then
						skippedBlack += 1
					elseif isProtected(quirk) then
						-- Seharusnya hanya target yang protected; kalau ada nama lain
						-- yang masih protected, server akan menolak roll di unit ini.
						skippedProtected += 1
					else
						local okCost, cost = pcall(function()
							return require(RS.Framework.Features.Quirks.QuirkUtil)
								.GetRollCost(entry.name, entry.attributes)
						end)
						candidates[#candidates + 1] = {
							key = key,
							entry = entry,
							name = tostring(entry.name),
							cost = (okCost and type(cost) == "number") and cost or 0,
						}
					end
				end
			end
		end
	end
	if skippedBlack > 0 or skippedProtected > 0 then
		log(string.format(
			"kandidat: %d unit (blacklist: %d, protected lain: %d)",
			#candidates, skippedBlack, skippedProtected
		))
	end
	state.candidateCount = #candidates
	return candidates
end

-- Satu unit: roll terus sampai quirk = target, uang habis, atau ditolak server
-- STUCK_LIMIT kali berturut-turut. id = token generasi pemanggil.
local function processCandidate(id, cand)
	local refusals = 0 -- penolakan diam-diam berturut-turut -> indikasi unit stuck
	while state.running and id == runId do
		local money = readMoney()
		if money == nil then
			log("WARN: gagal membaca uang — menunggu interval")
			refusals += 1
			if refusals >= state.stuckLimit then
				log("WARN: unit stuck (data tidak terbaca?), skip: " .. cand.name)
				return "REFUSED"
			end
			task.wait(state.rollInterval)
			continue
		end
		if money < cand.cost then
			log(string.format("uang kurang (punya %d, butuh %d) — farm dihentikan", money, cand.cost))
			notify("Quirk Farm", "Uang kurang untuk roll — farming dihentikan")
			return "STOP"
		end

		local before = money
		local quirkBefore = readQuirk(cand.entry)
		-- Fire Roll dengan SATU argumen (unitKey) saja. Argumen kedua = force,
		-- melewati proteksi server — tidak pernah dipakai.
		pcall(function()
			RollRE:FireServer(cand.key)
		end)
		-- Selalu tunggu interval: jaga di atas debounce server 0.2s.
		task.wait(state.rollInterval)

		local after = readMoney() or before
		local quirkNow = readQuirk(cand.entry)
		stats.rolls += 1

		if quirkNow == quirkBefore and after >= before and refusals < 2 then
			for _ = 1, REFUSAL_CONFIRM_READS do
				task.wait(REFUSAL_CONFIRM_DELAY)
				if not (state.running and id == runId) then
					return
				end
				local retryMoney = readMoney() or after
				local retryQuirk = readQuirk(cand.entry)
				if retryQuirk ~= quirkBefore or retryMoney < before then
					quirkNow = retryQuirk
					after = retryMoney
					if not state.lateSignalSeen then
						state.lateSignalSeen = true
						log("sinyal roll datang terlambat - skip ditahan (replikasi lambat)")
					end
					break
				end
			end
		end

		if quirkNow == state.targetQuirk then
			-- HIT: target sudah diproteksi sejak start -> tidak ada yang perlu difire.
			stats.accepted += 1
			stats.hits += 1
			stats.moneySpent += math.max(before - after, 0)
			notifyHit(cand.name, state.targetQuirk)
			log(string.format("HIT: %s dapat %s (rolls=%d hits=%d)", cand.name, state.targetQuirk, stats.rolls, stats.hits))
			notify("Quirk Farm", cand.name .. " dapat " .. state.targetQuirk .. "!")
			return "HIT"
		end

		-- Dual-signal "roll diterima server": quirk unit BERUBAH adalah sinyal
		-- utama; uang turun yang terlihat hanya pelengkap. Di akun kaya (1e17+)
		-- ULP double (~64+) lebih besar dari roll cost Common, jadi uang sering
		-- terbaca tidak berubah walau roll sukses.
		if quirkNow ~= quirkBefore or after < before then
			stats.accepted += 1
			if after < before then
				stats.moneySpent += (before - after)
			end
			if quirkNow ~= nil and quirkNow ~= quirkBefore and isRareQuirk(quirkNow) then
				-- Kebijakan: hanya target yang ditahan. Rare non-target yang baru
				-- mendarat dibuang (akan di-reroll pada iterasi berikutnya).
				stats.rareLost += 1
				log(string.format("buang %s di %s (bukan target, tidak ditahan)", quirkNow, cand.name))
			end
			refusals = 0
		else
			-- Kedua sinyal diam: server tolak diam-diam (zona/proteksi/debounce),
			-- ATAU roll sukses yang kebetulan mendarat di quirk SAMA persis
			-- (probabilitas rendah; STUCK_LIMIT=10 membuatnya ~0.18^10 ≈ 1e-8).
			refusals += 1
			if refusals >= state.stuckLimit then
				log("WARN: unit stuck (di luar zona / protected / debounce?), skip: " .. cand.name)
				return "REFUSED"
			end
		end
		updateStatsText(cand.name)
	end
	return
end

-- Outer loop: satu rotasi penuh lewat semua kandidat, lalu recompute.
-- Guard "rotasi tanpa roll diterima": kalau satu rotasi penuh tidak ada satu pun
-- roll yang diterima server (mis. karakter di luar zona Quirks), farm dihentikan
-- daripada berputar selamanya tanpa hasil.
local function mainLoop(id)
	while state.running and id == runId do
		local candidates = computeCandidates(id)
		if id ~= runId then
			return -- stop/restart terjadi selagi snapshot
		end
		if #candidates == 0 then
			log("tidak ada kandidat unit Common tanpa " .. state.targetQuirk .. " — farm dihentikan")
			notify("Quirk Farm", "Tidak ada kandidat unit — farming dihentikan")
			stop()
			return
		end
		local acceptedBefore = stats.accepted
		local refusedStreak = 0
		for _, cand in ipairs(candidates) do
			if not (state.running and id == runId) then
				return
			end
			updateStatsText(cand.name)
			local outcome = processCandidate(id, cand)
			if outcome == "STOP" then
				stop()
				return
			end
			if outcome == "REFUSED" then
				refusedStreak += 1
				if stats.accepted == acceptedBefore and refusedStreak >= EARLY_ABORT_UNITS then
					log(string.format("WARN: %d unit ditolak berturut-turut tanpa satu roll pun diterima - farm dihentikan", refusedStreak))
					notify("Quirk Farm", "Tidak ada roll yang diterima server. Berdiri di area mesin Quirk (zona Quirks), lalu start lagi.")
					stop()
					return
				end
			else
				refusedStreak = 0
			end
		end
		if state.running and id == runId and stats.accepted == acceptedBefore then
			log("WARN: satu rotasi penuh tanpa roll yang diterima server — farm dihentikan")
			notify("Quirk Farm",
				"Tidak ada roll yang diterima server. Pastikan karakter berdiri di area mesin Quirk (zona Quirks), lalu nyalakan ulang.")
			stop()
			return
		end
	end
end

--// Lifecycle: stop \\--
-- Aman dipanggil saat belum pernah start, tanpa UI (headless), atau dari API getgenv.
function stop()
	runId += 1 -- invalidasi SEMUA loop generasi sekarang
	state.running = false
	restoreProtections() -- kembalikan proteksi ke snapshot awal (target tetap terkunci)
	syncToggle(false) -- toggle OFF dua-argumen tanpa callback -> tidak memicu start() lagi
	notify("Quirk Farm", string.format(
		"Farming dihentikan — rolls: %d, hits: %d, rare dibuang: %d, money spent: %d",
		stats.rolls, stats.hits, stats.rareLost, stats.moneySpent
	))
	log(string.format("stopped (rolls=%d accepted=%d hits=%d rareLost=%d moneySpent=%d)",
		stats.rolls, stats.accepted, stats.hits, stats.rareLost, stats.moneySpent))
end

--// Zona Quirk: helper jarak \\--
local function getQuirksZone()
	local zones = workspace:FindFirstChild("Zones")
	return zones and zones:FindFirstChild("Quirks") or nil
end

local function distanceToMachine()
	local zone = getQuirksZone()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (zone and root) then
		return nil
	end
	return (root.Position - zone.Position).Magnitude
end

--// Auto-walk ke mesin Quirk: chunked teleport dulu, pathfinding sebagai fallback \\--
-- Ambang anti-cheat adalah LAJU perpindahan (~150 studs/detik), bukan ukuran satu
-- langkah: 12 studs tiap 0,1s (120/s) stabil, sedangkan 100 studs tiap 0,45s
-- (222/s) di-revert ~1s kemudian. Tanpa pathfinding, conveyor tidak mengganggu.
local function teleportToMachine(id, force)
	local zone = getQuirksZone()
	if not zone then
		log("WARN: zona Quirks tidak ditemukan - arahkan manual")
		return false
	end

	local hum, root
	local function resolveCharacter()
		local char = LocalPlayer.Character
		hum = char and char:FindFirstChildOfClass("Humanoid")
		root = char and char:FindFirstChild("HumanoidRootPart")
		return char, hum, root
	end
	local char = resolveCharacter()
	if not (hum and root) or hum.Health <= 0 then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }

	-- Lantai di titik tujuan: jaga Y tetap di atas permukaan (tangga/slope/conveyor).
	local function groundY(x, z, refY)
		local hit = workspace:Raycast(Vector3.new(x, refY + 100, z), Vector3.new(0, -400, 0), params)
		return hit and hit.Position.Y or nil
	end

	local refGround = groundY(root.Position.X, root.Position.Z, root.Position.Y)
	local yOffset = root.Position.Y - (refGround or root.Position.Y)

	local chunks = 0
	local lastDist = math.huge
	local stall = 0
	while (force or state.running) and id == runId do
		char = resolveCharacter()
		if not (hum and root) or hum.Health <= 0 then
			return false
		end
		params.FilterDescendantsInstances = { char }

		local flat = Vector3.new(zone.Position.X - root.Position.X, 0, zone.Position.Z - root.Position.Z)
		local dist = flat.Magnitude
		if dist <= TELEPORT_STOP_DIST then
			break
		end
		if chunks >= TELEPORT_MAX_CHUNKS then
			log("WARN: chunk teleport berhenti di batas " .. tostring(TELEPORT_MAX_CHUNKS) .. " chunk")
			break
		end

		local len = math.min(TELEPORT_STEP, dist - TELEPORT_STOP_DIST)
		local targetFlat = root.Position + flat.Unit * len
		local gy = groundY(targetFlat.X, targetFlat.Z, root.Position.Y)
		local target = Vector3.new(targetFlat.X, (gy and (gy + yOffset)) or root.Position.Y, targetFlat.Z)

		local rot = root.CFrame - root.CFrame.Position
		char:PivotTo(CFrame.new(target) * rot)
		chunks += 1
		task.wait(TELEPORT_DELAY)

		-- Revert guard: satu langkah yang tidak mendarat di target = server menolak.
		local err = (root.Position - target).Magnitude
		if err > math.max(6, len * 0.75) then
			log(string.format("WARN: chunk teleport ditolak server (err %.0f studs) setelah %d langkah", err, chunks))
			return false
		end

		-- Stall guard: conveyor/dinding bisa menahan progres walau PivotTo diterima.
		if dist >= lastDist - 0.5 then
			stall += 1
			if stall >= TELEPORT_STALL_LIMIT then
				log(string.format("WARN: teleport tidak ada progres %d langkah - fallback pathfinding", stall))
				return false
			end
		else
			stall = 0
		end
		lastDist = dist
	end

	task.wait(0.2)
	local finalDist = distanceToMachine()
	log(string.format("chunk teleport selesai: %d chunk, jarak akhir %s studs",
		chunks, finalDist and string.format("%.0f", finalDist) or "?"))
	return finalDist ~= nil and finalDist <= WALK_NEAR_DIST
end

-- Berjalan sungguhan lewat Humanoid:MoveTo. Dipakai sebagai fallback bila chunked
-- teleport ditolak server. Gerakan normal selalu diizinkan anti-cheat.
local function walkToMachine(id)
	local zone = getQuirksZone()
	if not zone then
		log("WARN: zona Quirks tidak ditemukan - arahkan manual")
		return false
	end
	local goal = zone.Position
	local deadline = os.clock() + WALK_TIMEOUT
	local attempts = 0
	while state.running and id == runId and os.clock() < deadline do
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not (hum and root) or hum.Health <= 0 then
			task.wait(1) -- menunggu respawn
			continue
		end
		local dist = (root.Position - goal).Magnitude
		if dist <= WALK_NEAR_DIST then
			log(string.format("tiba di mesin Quirk (%.0f studs dari pusat zona)", dist))
			return true
		end
		if attempts >= WALK_RECOMPUTE_LIMIT then
			break
		end
		attempts += 1

		local path = PathfindingService:CreatePath({
			AgentRadius = 2.5,
			AgentHeight = 5,
			AgentCanJump = true,
			WaypointSpacing = 6,
		})
		local okCompute = pcall(function()
			path:ComputeAsync(root.Position, goal)
		end)
		if not okCompute or path.Status ~= Enum.PathStatus.Success then
			log(string.format("WARN: path ke mesin gagal (%s), coba lagi", tostring(path.Status)))
			task.wait(1)
			continue
		end

		local blocked = false
		local conn = path.Blocked:Connect(function()
			blocked = true
		end)
		for index, wp in ipairs(path:GetWaypoints()) do
			if index == 1 then
				continue
			end
			if blocked or not (state.running and id == runId) then
				break
			end
			if wp.Action == Enum.PathWaypointAction.Jump then
				hum.Jump = true
			end
			hum:MoveTo(wp.Position)
			local wpDeadline = os.clock() + WALK_WAYPOINT_TIMEOUT
			local lastPos = root.Position
			local stalled = 0
			while (root.Position - wp.Position).Magnitude > 4.5 do
				if blocked or not (state.running and id == runId) or os.clock() > wpDeadline then
					break
				end
				task.wait(0.15)
				if (root.Position - lastPos).Magnitude < 0.6 then
					stalled += 0.15
					if stalled > 1.5 then
						hum.Jump = true
						stalled = 0
					end
				else
					lastPos = root.Position
					stalled = 0
				end
			end
		end
		conn:Disconnect()
		hum:MoveTo(root.Position)
		task.wait(0.3)
	end

	local okNow = false
	local charNow = LocalPlayer.Character
	local rootNow = charNow and charNow:FindFirstChild("HumanoidRootPart")
	local zoneNow = getQuirksZone()
	if state.running and id == runId and rootNow and zoneNow then
		okNow = (rootNow.Position - zoneNow.Position).Magnitude <= WALK_NEAR_DIST
	end
	if not okNow then
		log(string.format("WARN: auto-walk gagal, sisa %.0f studs dari mesin (%d path dicoba)",
			distanceToMachine() or -1, attempts))
	end
	return okNow
end

--// Lifecycle: start \\--
-- start(): no-op kalau sudah jalan; kegagalan apa pun recoverable (log + notify,
-- toggle dipaksa OFF, window tetap hidup). Return true = berjalan.
local function start()
	if state.running then
		return true -- sudah berjalan: no-op
	end

	-- Resolve DataController: wajib ada, tanpa itu tidak ada data unit/uang/proteksi.
	local okDC, dcMod = pcall(function()
		return require(RS.Framework.Features.Data.DataController)
	end)
	if not okDC or type(dcMod) ~= "table" then
		log("ERROR: DataController tidak tersedia — start ulang nanti")
		notify("Quirk Farm", "Gagal start: DataController tidak tersedia")
		return false
	end
	DC = dcMod

	-- Resolve remotes. Keduanya wajib: proteksi target adalah bagian dari kebijakan.
	local okRem, rollRemote, protectRemote = pcall(function()
		return waitRemote("Roll"), waitRemote("SetQuirkProtected")
	end)
	if not okRem then
		log("ERROR: gagal resolve remotes QuirkService — start ulang nanti")
		notify("Quirk Farm", "Gagal start: remote QuirkService tidak ditemukan")
		return false
	end
	if not (rollRemote and rollRemote:IsA("RemoteEvent")) then
		log("ERROR: RE.Roll tidak ditemukan — start ulang nanti")
		notify("Quirk Farm", "Gagal start: RE.Roll tidak ditemukan")
		return false
	end
	if not (protectRemote and protectRemote:IsA("RemoteEvent")) then
		log("ERROR: RE.SetQuirkProtected tidak ditemukan — start ulang nanti")
		notify("Quirk Farm", "Gagal start: RE.SetQuirkProtected tidak ditemukan")
		return false
	end
	RollRE = rollRemote
	ProtectRE = protectRemote

	-- Config Quirks wajib: batas "langka" (weight < 100) dipakai untuk proteksi
	-- dan blacklist, sama dengan validasi server.
	if not getQuirks() then
		log("ERROR: config Quirks tidak terbaca — start ulang nanti")
		notify("Quirk Farm", "Gagal start: config Quirks tidak terbaca")
		return false
	end

	-- Snapshot cepat: pastikan uang terbaca sebelum menyentuh state proteksi.
	local money0 = readMoney()
	if money0 == nil then
		log("ERROR: gagal membaca uang — start ulang nanti")
		notify("Quirk Farm", "Gagal start: data uang tidak terbaca")
		return false
	end

	-- Snapshot proteksi LAMA dulu, baru blacklist, baru ubah proteksi.
	protectionSnapshot = snapshotProtections()
	state.selfProtected = {}
	local blacklisted = rebuildBlacklist()

	if not applyProtections(state.targetQuirk) then
		log("WARN: proteksi target belum terkonfirmasi server — farm tetap jalan, proteksi manual disarankan")
		notify("Quirk Farm", "Proteksi target belum terkonfirmasi — cek shield di mesin Quirk")
	end

	state.running = true
	runId += 1
	local id = runId

	if AUTO_WALK then
		local dist = distanceToMachine()
		if dist ~= nil and dist > WALK_NEAR_DIST then
			log(string.format("jarak ke mesin Quirk %.0f studs - menuju mesin otomatis", dist))

			local arrived = false
			if TELEPORT_WALK then
				notify("Quirk Farm", string.format("Teleport chunked ke mesin Quirk (%.0f studs)...", dist))
				arrived = teleportToMachine(id)
				if arrived then
					notify("Quirk Farm", "Tiba di mesin Quirk (chunked teleport)")
				else
					log("WARN: chunked teleport gagal - fallback ke pathfinding")
					notify("Quirk Farm", "Teleport chunked gagal — beralih ke jalan kaki...")
				end
			end

			if not arrived then
				if not walkToMachine(id) then
					notify("Quirk Farm", "Tidak bisa mencapai mesin Quirk otomatis - dekatkan karakter lalu start lagi.")
					stop()
					return false
				end
			end
		end
	end

	task.spawn(mainLoop, id)
	syncToggle(true) -- toggle ON dua-argumen tanpa callback -> tidak re-enter stop()
	notify("Quirk Farm", string.format(
		"Farming dimulai — target %s%s, %d unit di-blacklist",
		state.targetQuirk,
		canProtectQuirk(state.targetQuirk) and " (diproteksi)" or " (tidak bisa diproteksi)",
		blacklisted
	))
	log(string.format(
		"aktif — target %s%s, rare lain dilepas, blacklist %d unit",
		state.targetQuirk,
		canProtectQuirk(state.targetQuirk) and " diproteksi" or " (proteksi tidak tersedia)",
		blacklisted
	))
	return true
end

--// Remote config: Supabase edge function (opsional) \\--
-- Probe fungsi HTTP SEKALI per load, urutan sama dengan web/public/collector.luau.
-- Tanpa salah satu fungsi ini mode remote mematikan diri (satu baris log di bawah).
local REMOTE_HTTP
do
	local okPick, fn = pcall(function()
		if type(request) == "function" then
			return request
		end
		if type(http_request) == "function" then
			return http_request
		end
		if type(syn) == "table" and type(syn.request) == "function" then
			return syn.request
		end
		if type(http) == "table" and type(http.request) == "function" then
			return http.request
		end
		return nil
	end)
	REMOTE_HTTP = (okPick and type(fn) == "function") and fn or nil
end

local remoteInfo = state.remote
local remoteOn = REMOTE_CONFIG.ENABLED and REMOTE_HTTP ~= nil -- open channel: sync key opsional
remoteInfo.enabled = remoteOn
remoteInfo.keySet = SYNC_KEY ~= ""
local remoteLifecyclePending = false -- guard: start/stop remote tidak boleh dobel
local remoteLifecycleWanted = nil -- keinginan running terbaru dari dashboard

-- Satu POST JSON ke edge function. Tidak pernah mencatat URL key / body respons.
local function remoteCall(payload)
	if not REMOTE_HTTP then
		return false, "http tidak tersedia"
	end
	local okEnc, body = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not okEnc then
		return false, "JSONEncode gagal"
	end
	local headers = { ["Content-Type"] = "application/json" }
	if SYNC_KEY ~= "" then
		headers["x-sync-key"] = SYNC_KEY
	end
	local okReq, res = pcall(REMOTE_HTTP, {
		Url = REMOTE_CONFIG.URL,
		Method = "POST",
		Headers = headers,
		Body = body,
	})
	if not okReq then
		return false, "request error"
	end
	local code = type(res) == "table" and (res.StatusCode or res.status or res.Status) or nil
	local raw = type(res) == "table" and (res.Body or res.body) or nil
	if type(code) ~= "number" then
		return false, "respons tidak valid"
	end
	return code >= 200 and code < 300, code, raw
end

-- Antrian transisi start/stop remote: satu transisi pada satu waktu, dan
-- keinginan TERBARU menang (mis. stop datang saat start masih berjalan).
local pumpRemoteLifecycle
pumpRemoteLifecycle = function()
	if remoteLifecyclePending then
		return
	end
	local want = remoteLifecycleWanted
	if want == nil then
		return
	end
	remoteLifecycleWanted = nil
	if want == isRunning() then
		return
	end
	remoteLifecyclePending = true
	task.spawn(function()
		-- stop() WAJIB lewat lifecycle resmi (memulihkan proteksi).
		local okRun, errRun = pcall(function()
			if want then
				start()
			else
				stop()
			end
		end)
		remoteLifecyclePending = false
		if not okRun then
			log("WARN: remote " .. (want and "start" or "stop") .. " gagal: " .. tostring(errRun))
		end
		pumpRemoteLifecycle()
	end)
end

-- Terapkan config remote HANYA saat rev berubah. Field bertipe salah dilewati
-- (dicatat sekali) tanpa membatalkan field lain. state.appliedRev baru di-set
-- setelah semua field selesai; kegagalan apa pun cuma WARN sekali.
local function applyRemoteConfig(cfg)
	if type(cfg) ~= "table" or type(cfg.rev) ~= "number" then
		return false
	end
	if cfg.rev == state.appliedRev then
		return false
	end

	local ignored = {}
	local ok, err = pcall(function()
		if cfg.target ~= nil then
			if type(cfg.target) == "string" and isKnownQuirk(cfg.target) then
				if cfg.target ~= state.targetQuirk then
					local api = ENV.quirkFarm
					local applied = type(api) == "table" and type(api.setTarget) == "function"
						and api.setTarget(cfg.target) or false
					if not applied then
						ignored[#ignored + 1] = "target"
					end
				end
			else
				ignored[#ignored + 1] = "target"
			end
		end

		if cfg.blacklistRare ~= nil then
			if type(cfg.blacklistRare) == "boolean" then
				state.blacklistRare = cfg.blacklistRare
				BLACKLIST_RARE_UNITS = cfg.blacklistRare -- jaga toggle UI tetap sinkron
				if isRunning() then
					rebuildBlacklist()
				end
			else
				ignored[#ignored + 1] = "blacklistRare"
			end
		end

		if cfg.rollInterval ~= nil then
			if type(cfg.rollInterval) == "number"
				and cfg.rollInterval >= 0.25 and cfg.rollInterval <= 5 then
				state.rollInterval = cfg.rollInterval
			else
				ignored[#ignored + 1] = "rollInterval"
			end
		end

		if cfg.stuckLimit ~= nil then
			if type(cfg.stuckLimit) == "number"
				and cfg.stuckLimit >= 3 and cfg.stuckLimit <= 100 then
				state.stuckLimit = cfg.stuckLimit
			else
				ignored[#ignored + 1] = "stuckLimit"
			end
		end

		if cfg.webhookUrl ~= nil then
			if type(cfg.webhookUrl) == "string"
				and (cfg.webhookUrl == ""
					or cfg.webhookUrl:find("^https://discord%.com/api/webhooks/") ~= nil) then
				state.webhookUrl = cfg.webhookUrl
			else
				ignored[#ignored + 1] = "webhookUrl"
			end
		end

		if cfg.running ~= nil then
			if type(cfg.running) == "boolean" then
				if cfg.running ~= isRunning() then
					remoteLifecycleWanted = cfg.running
					pumpRemoteLifecycle()
				end
			else
				ignored[#ignored + 1] = "running"
			end
		end

		state.appliedRev = cfg.rev
		remoteInfo.appliedRev = cfg.rev
	end)

	if not ok then
		remoteInfo.lastError = tostring(err)
		log("WARN: applyRemoteConfig gagal: " .. tostring(err))
		return false
	end
	if #ignored > 0 then
		log("WARN: config remote: field diabaikan (" .. table.concat(ignored, ", ") .. ")")
	end
	return true
end

local function buildStatus()
	local blackCount = 0
	for _ in pairs(blacklist) do
		blackCount += 1
	end
	return {
		running = isRunning(),
		target = state.targetQuirk,
		rolls = stats.rolls,
		accepted = stats.accepted,
		hits = stats.hits,
		rareLost = stats.rareLost,
		moneySpent = stats.moneySpent,
		current = state.currentLabel or "",
		candidates = state.candidateCount or 0,
		blacklisted = blackCount,
		appliedRev = state.appliedRev or 0,
		lastSeenAt = os.time(),
		version = "v803",
	}
end

-- Pull config sekarang (dipanggil loop / API). Body tidak pernah di-log.
local function pullConfig()
	if not remoteOn then
		return false, "remote nonaktif"
	end
	local ok, code, raw = remoteCall({
		action = "pull",
		userId = LocalPlayer.UserId,
	})
	remoteInfo.lastPullAt = os.time()
	if not ok then
		return false, code
	end
	local okDec, data = pcall(function()
		return HttpService:JSONDecode(raw or "{}")
	end)
	if not okDec or type(data) ~= "table" then
		return false, "JSONDecode gagal"
	end
	if data.ok ~= true then
		return false, "ok=false"
	end
	if type(data.config) == "table" then
		applyRemoteConfig(data.config)
	end
	return true, code
end

-- Push status walau farm sedang berhenti, supaya dashboard bisa menampilkan
-- "offline since" dari lastSeenAt.
local function pushStatus()
	if not remoteOn then
		return false, "remote nonaktif"
	end
	local ok, code = remoteCall({
		action = "status",
		userId = LocalPlayer.UserId,
		status = buildStatus(),
	})
	if not ok then
		remoteInfo.lastError = tostring(code)
	end
	return ok, code
end

-- HIT lewat server: webhook Discord disimpan di Supabase, jadi device TIDAK
-- pernah memegang URL-nya. Server yang menyusun embed + rate-limit 15s.
local function relayHit(unitName, quirk)
	if not remoteOn then
		return false, { code = "remote nonaktif" }
	end
	local ok, code, raw = remoteCall({
		action = "hit",
		userId = LocalPlayer.UserId,
		player = LocalPlayer.Name,
		unit = tostring(unitName or ""),
		quirk = tostring(quirk or ""),
		rolls = stats.rolls,
		hits = stats.hits,
		rareLost = stats.rareLost,
		moneySpent = stats.moneySpent,
	})
	if not ok then
		remoteInfo.lastError = tostring(code)
		return false, { code = code }
	end
	local delivered = nil
	if type(raw) == "string" then
		local okDec, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if okDec and type(data) == "table" then
			delivered = data.delivered == true
		end
	end
	return true, { code = code, delivered = delivered }
end

-- HIT: relay server kalau remote aktif; kalau transport-nya gagal, coba webhook
-- lokal (kalau ada). Tidak pernah menggagalkan farm.
notifyHit = function(unitName, quirk)
	if not remoteOn then
		sendWebhook(unitName, quirk)
		return
	end
	local ok, info = relayHit(unitName, quirk)
	if ok then
		if info.delivered then
			log("discord relay OK (server)")
			return
		end
		-- Server tidak punya webhook tersimpan (delivered=false): pakai URL lokal
		-- yang diisi lewat tab Misc, kalau ada. Tanpa URL lokal ini tidak melakukan apa-apa.
		log("discord relay dilewati server (tanpa webhook) — coba webhook lokal")
		sendWebhook(unitName, quirk)
		return
	end
	log("WARN: relay HIT gagal (" .. tostring(info.code) .. "), fallback webhook lokal")
	sendWebhook(unitName, quirk)
end

-- Kirim HIT percobaan lewat jalur relay yang sama (untuk cek dari console).
local function testHit()
	local ok, info = relayHit("TestUnit", state.targetQuirk)
	if ok then
		log("testHit: terkirim ke server (delivered=" .. tostring(info.delivered) .. ")")
	else
		log("testHit: gagal (" .. tostring(info.code) .. ")")
	end
	return ok, info
end

-- Satu loop: tick 1s, pull tiap POLL, push tiap STATUS_EVERY.
local function startRemoteLoop()
	local gen = tonumber(ENV.__quirkFarmRemoteGen) or 0
	task.spawn(function()
		local pullElapsed = REMOTE_CONFIG.POLL -- pull pertama setelah POLL detik
		local pushElapsed = REMOTE_CONFIG.STATUS_EVERY -- status pertama langsung
		local failStreak = 0
		while remoteOn and gen == (tonumber(ENV.__quirkFarmRemoteGen) or 0) do
			if pullElapsed >= REMOTE_CONFIG.POLL then
				pullElapsed = 0
				local okCall, ok, code = pcall(pullConfig)
				if not okCall then
					ok, code = false, "pull error"
				end
				if ok then
					if failStreak >= 5 then
						log("remote: tersambung kembali (setelah " .. tostring(failStreak) .. " gagal)")
					end
					failStreak = 0
					remoteInfo.lastError = nil
				else
					failStreak += 1
					remoteInfo.lastError = tostring(code)
					if failStreak % 5 == 0 then
						log("WARN: remote pull gagal " .. tostring(failStreak) .. "x (" .. tostring(code) .. ")")
					end
				end
			end
			if pushElapsed >= REMOTE_CONFIG.STATUS_EVERY then
				pushElapsed = 0
				pcall(pushStatus)
			end
			task.wait(1)
			pullElapsed += 1
			pushElapsed += 1
		end
	end)
end

--// Jalur load \\--
-- API di-assign DI SINI (bukan di start()) supaya stats/start/stop/isRunning/
-- setTarget selalu bisa diakses walau start() gagal, AUTO_START = false, atau
-- pembuatan GUI gagal (mode headless).
ENV.quirkFarm = {
	stats = stats,
	stop = stop,
	start = start,
	isRunning = isRunning,
	pullConfig = pullConfig,
	pushStatus = pushStatus,
	relayHit = relayHit,
	testHit = testHit,
	distanceToMachine = distanceToMachine,
	teleportToMachine = function()
		-- Diagnostik/manual: force=true supaya tetap jalan walau farm sedang stop.
		return teleportToMachine(runId, true)
	end,
	remote = remoteInfo,
	setTarget = function(name)
		if not isKnownQuirk(name) then
			log("WARN: setTarget ditolak, quirk tidak dikenal: " .. tostring(name))
			return false
		end
		if not canProtectQuirk(name) then
			log("WARN: " .. name .. " (weight " .. tostring(quirkWeight(name)) .. ") tidak bisa diproteksi server (butuh < 100) - hit tidak akan ditahan")
		end
		state.targetQuirk = name
		-- Sinkron dropdown TANPA callback (dua argumen Set) -> tidak re-enter.
		if targetDropdown then
			pcall(function()
				targetDropdown:Set(name, true)
			end)
		end
		if state.running then
			-- Terapkan langsung: target baru diproteksi, rare lain dilepas lagi,
			-- dan blacklist dihitung ulang terhadap target baru.
			local blacklisted = rebuildBlacklist()
			applyProtections(name)
			log(string.format("target -> %s (proteksi & blacklist diterapkan, %d unit blacklist)", name, blacklisted))
		else
			log("target diganti -> " .. name .. " (diterapkan saat start berikutnya)")
		end
		return true
	end,
	blacklist = blacklist,
	rebuildBlacklist = function()
		if not DC then
			return 0
		end
		local n = rebuildBlacklist()
		log(string.format("blacklist dihitung ulang: %d unit", n))
		return n
	end,
	webhookUrl = WEBHOOK_URL, -- field override runtime: ENV.quirkFarm.webhookUrl = "https://..."
}

--// UI: LightScriptHub — GUI LOKAL (tanpa HttpGet), dibangun SEKALI di jalur load \\--
-- Semua pembuatan elemen di dalam satu pcall: kegagalan UI tidak boleh membunuh
-- logika headless (start/stop via getgenv().quirkFarm tetap hidup).
do
	local okUI, errUI = pcall(function()
		local UserInputService = game:GetService("UserInputService")
		local TweenService = game:GetService("TweenService")
		local RunService = game:GetService("RunService")
		local VirtualUser = game:GetService("VirtualUser")
		local okCoreGui, CoreGui = pcall(function()
			return game:GetService("CoreGui")
		end)
		if not okCoreGui then
			CoreGui = nil -- executor yang menolak CoreGui: pakai gethui/PlayerGui di bawah
		end
		local Workspace = game:GetService("Workspace")
		local Camera = Workspace.CurrentCamera

		local ParentGui = (gethui and gethui()) or CoreGui or LocalPlayer:WaitForChild("PlayerGui")
		local oldGui = ParentGui:FindFirstChild("LightScriptHub")
		if oldGui then
			oldGui:Destroy()
		end

		-- 1. ScreenGui utama
		local ScreenGui = Instance.new("ScreenGui")
		ScreenGui.Name = "LightScriptHub"
		ScreenGui.ResetOnSpawn = false
		ScreenGui.IgnoreGuiInset = true
		ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		ScreenGui.Parent = ParentGui
		guiRoot = ScreenGui

		-- // Toast notification (pojok kanan bawah) //
		local ToastContainer = Instance.new("Frame")
		ToastContainer.Name = "ToastContainer"
		ToastContainer.Size = UDim2.new(0, 230, 1, -20)
		ToastContainer.AnchorPoint = Vector2.new(1, 1)
		ToastContainer.Position = UDim2.new(1, -10, 1, -10)
		ToastContainer.BackgroundTransparency = 1
		ToastContainer.ZIndex = 20
		ToastContainer.Parent = ScreenGui

		local ToastScale = Instance.new("UIScale")
		ToastScale.Parent = ToastContainer

		local ToastLayout = Instance.new("UIListLayout")
		ToastLayout.Padding = UDim.new(0, 6)
		ToastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		ToastLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		ToastLayout.SortOrder = Enum.SortOrder.LayoutOrder
		ToastLayout.Parent = ToastContainer

		local function CreateNotification(titleText, messageText, duration)
			duration = duration or 3

			local ToastFrame = Instance.new("Frame")
			ToastFrame.Size = UDim2.new(1, 0, 0, 52)
			ToastFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
			ToastFrame.BorderSizePixel = 0
			ToastFrame.ClipsDescendants = true
			ToastFrame.ZIndex = 21
			ToastFrame.Parent = ToastContainer

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 6)
			Corner.Parent = ToastFrame

			local Stroke = Instance.new("UIStroke")
			Stroke.Color = Color3.fromRGB(60, 120, 220)
			Stroke.Thickness = 1
			Stroke.Parent = ToastFrame

			local Title = Instance.new("TextLabel")
			Title.Size = UDim2.new(1, -16, 0, 18)
			Title.Position = UDim2.new(0, 8, 0, 4)
			Title.BackgroundTransparency = 1
			Title.Text = tostring(titleText)
			Title.TextColor3 = Color3.fromRGB(60, 150, 255)
			Title.Font = Enum.Font.GothamBold
			Title.TextSize = 12
			Title.TextXAlignment = Enum.TextXAlignment.Left
			Title.TextTruncate = Enum.TextTruncate.AtEnd
			Title.ZIndex = 22
			Title.Parent = ToastFrame

			local Msg = Instance.new("TextLabel")
			Msg.Size = UDim2.new(1, -16, 0, 22)
			Msg.Position = UDim2.new(0, 8, 0, 22)
			Msg.BackgroundTransparency = 1
			Msg.Text = tostring(messageText)
			Msg.TextColor3 = Color3.fromRGB(230, 230, 240)
			Msg.Font = Enum.Font.Gotham
			Msg.TextSize = 11
			Msg.TextWrapped = true
			Msg.TextXAlignment = Enum.TextXAlignment.Left
			Msg.TextYAlignment = Enum.TextYAlignment.Top
			Msg.ZIndex = 22
			Msg.Parent = ToastFrame

			local ProgressBar = Instance.new("Frame")
			ProgressBar.Size = UDim2.new(1, 0, 0, 3)
			ProgressBar.Position = UDim2.new(0, 0, 1, -3)
			ProgressBar.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
			ProgressBar.BorderSizePixel = 0
			ProgressBar.ZIndex = 22
			ProgressBar.Parent = ToastFrame

			ToastFrame.BackgroundTransparency = 1
			Title.TextTransparency = 1
			Msg.TextTransparency = 1
			TweenService:Create(ToastFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 0.05
			}):Play()
			TweenService:Create(Title, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
			TweenService:Create(Msg, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
			TweenService:Create(ProgressBar, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
				Size = UDim2.new(0, 0, 0, 3)
			}):Play()

			task.delay(duration, function()
				if not ToastFrame or not ToastFrame.Parent then
					return
				end
				local fadeOut = TweenService:Create(ToastFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 0)
				})
				pcall(function()
					TweenService:Create(Title, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
					TweenService:Create(Msg, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
					Stroke:Destroy()
				end)
				fadeOut:Play()
				fadeOut.Completed:Wait()
				ToastFrame:Destroy()
			end)
		end

		guiNotify = CreateNotification

		-- // Draggable presisi + batas layar //
		local function MakeDraggable(dragTrigger, targetFrame, scaleObj, onTapCallback)
			local dragging = false
			local dragInput, dragStart
			local startAnchorPos
			local isMoved = false

			dragTrigger.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					dragging = true
					isMoved = false
					dragStart = input.Position

					local vp = Camera.ViewportSize
					local currentX = (targetFrame.Position.X.Scale * vp.X) + targetFrame.Position.X.Offset
					local currentY = (targetFrame.Position.Y.Scale * vp.Y) + targetFrame.Position.Y.Offset
					startAnchorPos = Vector2.new(currentX, currentY)

					input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then
							dragging = false
							if not isMoved and onTapCallback then
								onTapCallback()
							end
						end
					end)
				end
			end)

			dragTrigger.InputChanged:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
					dragInput = input
				end
			end)

			UserInputService.InputChanged:Connect(function(input)
				if input == dragInput and dragging then
					local delta = input.Position - dragStart
					if delta.Magnitude > 6 then
						isMoved = true
					end

					local vp = Camera.ViewportSize
					local currentScale = scaleObj and scaleObj.Scale or 1
					local scaledSize = targetFrame.Size
					local width = scaledSize.X.Offset * currentScale
					local height = scaledSize.Y.Offset * currentScale

					local anchor = targetFrame.AnchorPoint
					local minX = width * anchor.X
					local maxX = vp.X - (width * (1 - anchor.X))
					local minY = height * anchor.Y
					local maxY = vp.Y - (height * (1 - anchor.Y))

					local newX = math.clamp(startAnchorPos.X + delta.X, math.min(minX, maxX), math.max(minX, maxX))
					local newY = math.clamp(startAnchorPos.Y + delta.Y, math.min(minY, maxY), math.max(minY, maxY))

					targetFrame.Position = UDim2.new(newX / vp.X, 0, newY / vp.Y, 0)
				end
			end)
		end

		-- 2. Floating button
		local FloatBtn = Instance.new("TextButton")
		FloatBtn.Name = "FloatingButton"
		FloatBtn.Size = UDim2.new(0, 44, 0, 44)
		FloatBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		FloatBtn.Position = UDim2.new(0.08, 0, 0.25, 0)
		FloatBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
		FloatBtn.Text = "HUB"
		FloatBtn.TextColor3 = Color3.fromRGB(60, 150, 255)
		FloatBtn.Font = Enum.Font.GothamBold
		FloatBtn.TextSize = 12
		FloatBtn.AutoButtonColor = false
		FloatBtn.ZIndex = 10
		FloatBtn.Parent = ScreenGui

		local FloatCorner = Instance.new("UICorner")
		FloatCorner.CornerRadius = UDim.new(1, 0)
		FloatCorner.Parent = FloatBtn

		local FloatStroke = Instance.new("UIStroke")
		FloatStroke.Color = Color3.fromRGB(60, 120, 220)
		FloatStroke.Thickness = 2
		FloatStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		FloatStroke.Parent = FloatBtn

		local FloatScale = Instance.new("UIScale")
		FloatScale.Parent = FloatBtn

		-- 3. Main window
		local BASE_WIDTH = 420
		local BASE_HEIGHT = 250

		local MainFrame = Instance.new("Frame")
		MainFrame.Name = "MainFrame"
		MainFrame.Size = UDim2.new(0, BASE_WIDTH, 0, BASE_HEIGHT)
		MainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		MainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
		MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
		MainFrame.BorderSizePixel = 0
		MainFrame.ClipsDescendants = true
		MainFrame.Parent = ScreenGui

		local MainCorner = Instance.new("UICorner")
		MainCorner.CornerRadius = UDim.new(0, 8)
		MainCorner.Parent = MainFrame

		local MainStroke = Instance.new("UIStroke")
		MainStroke.Color = Color3.fromRGB(45, 45, 55)
		MainStroke.Thickness = 1
		MainStroke.Parent = MainFrame

		-- // Auto-scale (split screen & HP) + override manual dari tab Misc //
		local UIScale = Instance.new("UIScale")
		UIScale.Parent = MainFrame

		local manualScale = nil -- nil = ikut auto; angka (0.5-1.5) = skala manual

		local function UpdateScale()
			local viewport = Camera.ViewportSize
			local scaleX = (viewport.X * 0.85) / BASE_WIDTH
			local scaleY = (viewport.Y * 0.80) / BASE_HEIGHT

			local finalScale = math.min(scaleX, scaleY, 1.1)
			local clampedScale = math.max(finalScale, 0.4)

			UIScale.Scale = manualScale or clampedScale
			FloatScale.Scale = math.clamp(finalScale, 0.65, 1)
			ToastScale.Scale = math.clamp(finalScale, 0.6, 1)
		end

		Camera:GetPropertyChangedSignal("ViewportSize"):Connect(UpdateScale)
		UpdateScale()

		MakeDraggable(FloatBtn, FloatBtn, FloatScale, function()
			MainFrame.Visible = not MainFrame.Visible
			if MainFrame.Visible then
				FloatStroke.Color = Color3.fromRGB(60, 120, 220)
				FloatBtn.TextColor3 = Color3.fromRGB(60, 150, 255)
			else
				FloatStroke.Color = Color3.fromRGB(90, 90, 100)
				FloatBtn.TextColor3 = Color3.fromRGB(150, 150, 160)
			end
		end)

		-- 4. Top bar
		local TopBar = Instance.new("Frame")
		TopBar.Name = "TopBar"
		TopBar.Size = UDim2.new(1, 0, 0, 34)
		TopBar.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
		TopBar.BorderSizePixel = 0
		TopBar.Parent = MainFrame

		local TopCorner = Instance.new("UICorner")
		TopCorner.CornerRadius = UDim.new(0, 8)
		TopCorner.Parent = TopBar

		local TopBarFix = Instance.new("Frame")
		TopBarFix.Size = UDim2.new(1, 0, 0, 8)
		TopBarFix.Position = UDim2.new(0, 0, 1, -8)
		TopBarFix.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
		TopBarFix.BorderSizePixel = 0
		TopBarFix.Parent = TopBar

		local TitleLabel = Instance.new("TextLabel")
		TitleLabel.Name = "Title"
		TitleLabel.Size = UDim2.new(1, -80, 1, 0)
		TitleLabel.Position = UDim2.new(0, 12, 0, 0)
		TitleLabel.BackgroundTransparency = 1
		TitleLabel.Text = "QUIRK AUTO FARM"
		TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		TitleLabel.Font = Enum.Font.GothamBold
		TitleLabel.TextSize = 13
		TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
		TitleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		TitleLabel.Parent = TopBar

		MakeDraggable(TopBar, MainFrame, UIScale, nil)

		local isMinimized = false
		local MinBtn = Instance.new("TextButton")
		MinBtn.Size = UDim2.new(0, 34, 0, 34)
		MinBtn.Position = UDim2.new(1, -68, 0, 0)
		MinBtn.BackgroundTransparency = 1
		MinBtn.Text = "-"
		MinBtn.TextColor3 = Color3.fromRGB(200, 200, 200)
		MinBtn.Font = Enum.Font.GothamBold
		MinBtn.TextSize = 16
		MinBtn.Parent = TopBar

		MinBtn.MouseButton1Click:Connect(function()
			isMinimized = not isMinimized
			if isMinimized then
				MainFrame.Size = UDim2.new(0, BASE_WIDTH, 0, 34)
				MinBtn.Text = "+"
			else
				MainFrame.Size = UDim2.new(0, BASE_WIDTH, 0, BASE_HEIGHT)
				MinBtn.Text = "-"
			end
		end)

		local CloseBtn = Instance.new("TextButton")
		CloseBtn.Size = UDim2.new(0, 34, 0, 34)
		CloseBtn.Position = UDim2.new(1, -34, 0, 0)
		CloseBtn.BackgroundTransparency = 1
		CloseBtn.Text = "X"
		CloseBtn.TextColor3 = Color3.fromRGB(220, 80, 80)
		CloseBtn.Font = Enum.Font.GothamBold
		CloseBtn.TextSize = 13
		CloseBtn.Parent = TopBar

		CloseBtn.MouseButton1Click:Connect(function()
			-- Lepas handle dulu: farm tetap jalan, tapi UI tidak menyentuh instance mati.
			guiRoot, guiNotify, farmToggle, statsText, targetDropdown = nil, nil, nil, nil, nil
			ScreenGui:Destroy()
		end)

		-- 5. Sidebar (tab menu)
		local Sidebar = Instance.new("ScrollingFrame")
		Sidebar.Name = "Sidebar"
		Sidebar.Size = UDim2.new(0.3, -8, 1, -42)
		Sidebar.Position = UDim2.new(0, 5, 0, 38)
		Sidebar.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
		Sidebar.BorderSizePixel = 0
		Sidebar.ScrollBarThickness = 2
		Sidebar.AutomaticCanvasSize = Enum.AutomaticSize.Y
		Sidebar.CanvasSize = UDim2.new(0, 0, 0, 0)
		Sidebar.Parent = MainFrame

		local SidebarCorner = Instance.new("UICorner")
		SidebarCorner.CornerRadius = UDim.new(0, 6)
		SidebarCorner.Parent = Sidebar

		local SidebarLayout = Instance.new("UIListLayout")
		SidebarLayout.Padding = UDim.new(0, 4)
		SidebarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		SidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
		SidebarLayout.Parent = Sidebar

		local SidebarPadding = Instance.new("UIPadding")
		SidebarPadding.PaddingTop = UDim.new(0, 5)
		SidebarPadding.PaddingBottom = UDim.new(0, 5)
		SidebarPadding.Parent = Sidebar

		-- 6. Content area
		local ContentContainer = Instance.new("Frame")
		ContentContainer.Name = "ContentContainer"
		ContentContainer.Size = UDim2.new(0.7, -8, 1, -42)
		ContentContainer.Position = UDim2.new(0.3, 3, 0, 38)
		ContentContainer.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
		ContentContainer.BorderSizePixel = 0
		ContentContainer.Parent = MainFrame

		local ContentCorner = Instance.new("UICorner")
		ContentCorner.CornerRadius = UDim.new(0, 6)
		ContentCorner.Parent = ContentContainer

		-- // Anti-AFK hybrid (getconnections + VirtualUser) //
		local antiAfkEnabled = true

		local function EnableAntiAfk()
			if type(getconnections) == "function" then
				pcall(function()
					for _, conn in pairs(getconnections(LocalPlayer.Idled)) do
						if conn.Disable then
							conn:Disable()
						elseif conn.Disconnect then
							conn:Disconnect()
						end
					end
				end)
			end
		end

		-- Satu koneksi Idled per load: putuskan milik generasi lama dulu (re-run).
		if ENV.__quirkFarmIdledConn then
			pcall(function()
				ENV.__quirkFarmIdledConn:Disconnect()
			end)
		end
		ENV.__quirkFarmIdledConn = LocalPlayer.Idled:Connect(function()
			if antiAfkEnabled then
				pcall(function()
					VirtualUser:CaptureController()
					VirtualUser:ClickButton2(Vector2.new())
				end)
			end
		end)

		EnableAntiAfk()

		-- // Factory komponen //
		local Tabs = {}
		local FirstTab = true

		local function CreateTab(tabName)
			local TabButton = Instance.new("TextButton")
			TabButton.Size = UDim2.new(1, -10, 0, 28)
			TabButton.BackgroundColor3 = FirstTab and Color3.fromRGB(60, 120, 220) or Color3.fromRGB(40, 40, 48)
			TabButton.Text = tabName
			TabButton.TextColor3 = FirstTab and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(180, 180, 180)
			TabButton.Font = Enum.Font.GothamSemibold
			TabButton.TextSize = 12
			TabButton.AutoButtonColor = false
			TabButton.Parent = Sidebar

			local BtnCorner = Instance.new("UICorner")
			BtnCorner.CornerRadius = UDim.new(0, 5)
			BtnCorner.Parent = TabButton

			local ContentPage = Instance.new("ScrollingFrame")
			ContentPage.Name = tabName .. "_Page"
			ContentPage.Size = UDim2.new(1, 0, 1, 0)
			ContentPage.BackgroundTransparency = 1
			ContentPage.BorderSizePixel = 0
			ContentPage.ScrollBarThickness = 3
			ContentPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
			ContentPage.CanvasSize = UDim2.new(0, 0, 0, 0)
			ContentPage.Visible = FirstTab
			ContentPage.Parent = ContentContainer

			local PageLayout = Instance.new("UIListLayout")
			PageLayout.Padding = UDim.new(0, 5)
			PageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			PageLayout.SortOrder = Enum.SortOrder.LayoutOrder
			PageLayout.Parent = ContentPage

			local PagePadding = Instance.new("UIPadding")
			PagePadding.PaddingTop = UDim.new(0, 6)
			PagePadding.PaddingBottom = UDim.new(0, 6)
			PagePadding.Parent = ContentPage

			TabButton.MouseButton1Click:Connect(function()
				for _, tab in pairs(Tabs) do
					tab.Page.Visible = false
					tab.Button.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
					tab.Button.TextColor3 = Color3.fromRGB(180, 180, 180)
				end
				ContentPage.Visible = true
				TabButton.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
				TabButton.TextColor3 = Color3.fromRGB(255, 255, 255)
			end)

			FirstTab = false
			table.insert(Tabs, { Button = TabButton, Page = ContentPage })

			return ContentPage
		end

		local function CreateLabel(parentPage, text)
			local Label = Instance.new("TextLabel")
			Label.Size = UDim2.new(1, -12, 0, 22)
			Label.BackgroundTransparency = 1
			Label.Text = "  " .. text
			Label.TextColor3 = Color3.fromRGB(150, 160, 180)
			Label.Font = Enum.Font.GothamBold
			Label.TextSize = 11
			Label.TextXAlignment = Enum.TextXAlignment.Left
			Label.Parent = parentPage
			return Label
		end

		local function CreateButton(parentPage, text, callback)
			local Button = Instance.new("TextButton")
			Button.Size = UDim2.new(1, -12, 0, 32)
			Button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			Button.Text = text
			Button.TextColor3 = Color3.fromRGB(240, 240, 240)
			Button.Font = Enum.Font.GothamMedium
			Button.TextSize = 12
			Button.TextTruncate = Enum.TextTruncate.AtEnd
			Button.AutoButtonColor = false
			Button.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = Button

			Button.MouseButton1Click:Connect(function()
				pcall(callback)
			end)
			return Button
		end

		-- Toggle dengan handle Set(value, silent) / Get() -> syncToggle() tidak re-enter.
		local function CreateToggle(parentPage, text, defaultState, callback)
			local value = defaultState == true

			local ToggleBtn = Instance.new("TextButton")
			ToggleBtn.Size = UDim2.new(1, -12, 0, 32)
			ToggleBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			ToggleBtn.Text = "  " .. text
			ToggleBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
			ToggleBtn.Font = Enum.Font.GothamMedium
			ToggleBtn.TextSize = 12
			ToggleBtn.TextXAlignment = Enum.TextXAlignment.Left
			ToggleBtn.TextTruncate = Enum.TextTruncate.AtEnd
			ToggleBtn.AutoButtonColor = false
			ToggleBtn.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = ToggleBtn

			local StatusIndicator = Instance.new("Frame")
			StatusIndicator.Size = UDim2.new(0, 16, 0, 16)
			StatusIndicator.Position = UDim2.new(1, -24, 0.5, -8)
			StatusIndicator.BackgroundColor3 = value and Color3.fromRGB(60, 200, 100) or Color3.fromRGB(80, 80, 90)
			StatusIndicator.Parent = ToggleBtn

			local IndCorner = Instance.new("UICorner")
			IndCorner.CornerRadius = UDim.new(0, 4)
			IndCorner.Parent = StatusIndicator

			local function Apply(newValue, silent)
				value = newValue == true
				StatusIndicator.BackgroundColor3 = value and Color3.fromRGB(60, 200, 100) or Color3.fromRGB(80, 80, 90)
				if not silent then
					pcall(callback, value)
				end
			end

			ToggleBtn.MouseButton1Click:Connect(function()
				Apply(not value, false)
			end)

			-- Set dipanggil dengan colon (farmToggle:Set(v, true)) -> parameter pertama self.
			return {
				Set = function(_, newValue, silent)
					Apply(newValue, silent)
				end,
				Get = function()
					return value
				end,
			}
		end

		-- Dropdown dengan handle Set(value, silent) / Refresh(list).
		local function CreateDropdown(parentPage, text, optionsList, callback)
			local isExpanded = false
			local selectedOption = optionsList[1] or "-"

			local DropContainer = Instance.new("Frame")
			DropContainer.Size = UDim2.new(1, -12, 0, 32)
			DropContainer.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			DropContainer.ClipsDescendants = true
			DropContainer.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = DropContainer

			local HeaderBtn = Instance.new("TextButton")
			HeaderBtn.Size = UDim2.new(1, 0, 0, 32)
			HeaderBtn.BackgroundTransparency = 1
			HeaderBtn.Text = "  " .. text .. ": " .. tostring(selectedOption)
			HeaderBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
			HeaderBtn.Font = Enum.Font.GothamMedium
			HeaderBtn.TextSize = 12
			HeaderBtn.TextXAlignment = Enum.TextXAlignment.Left
			HeaderBtn.TextTruncate = Enum.TextTruncate.AtEnd
			HeaderBtn.AutoButtonColor = false
			HeaderBtn.Parent = DropContainer

			local ArrowLabel = Instance.new("TextLabel")
			ArrowLabel.Size = UDim2.new(0, 24, 0, 32)
			ArrowLabel.Position = UDim2.new(1, -26, 0, 0)
			ArrowLabel.BackgroundTransparency = 1
			ArrowLabel.Text = "v"
			ArrowLabel.TextColor3 = Color3.fromRGB(180, 180, 190)
			ArrowLabel.Font = Enum.Font.GothamBold
			ArrowLabel.TextSize = 12
			ArrowLabel.Parent = HeaderBtn

			local OptionHolder = Instance.new("Frame")
			OptionHolder.Size = UDim2.new(1, -10, 1, -36)
			OptionHolder.Position = UDim2.new(0, 5, 0, 32)
			OptionHolder.BackgroundTransparency = 1
			OptionHolder.Parent = DropContainer

			local OptionLayout = Instance.new("UIListLayout")
			OptionLayout.Padding = UDim.new(0, 3)
			OptionLayout.SortOrder = Enum.SortOrder.LayoutOrder
			OptionLayout.Parent = OptionHolder

			local function Collapse()
				isExpanded = false
				ArrowLabel.Text = "v"
				DropContainer.Size = UDim2.new(1, -12, 0, 32)
			end

			local function SelectOption(option, silent)
				selectedOption = option
				HeaderBtn.Text = "  " .. text .. ": " .. tostring(selectedOption)
				Collapse()
				if not silent then
					pcall(callback, option)
				end
			end

			local function RebuildOptions(newList)
				optionsList = newList
				for _, child in ipairs(OptionHolder:GetChildren()) do
					if child:IsA("TextButton") then
						child:Destroy()
					end
				end

				for _, option in ipairs(optionsList) do
					local OptBtn = Instance.new("TextButton")
					OptBtn.Size = UDim2.new(1, 0, 0, 24)
					OptBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 43)
					OptBtn.Text = tostring(option)
					OptBtn.TextColor3 = Color3.fromRGB(210, 210, 220)
					OptBtn.Font = Enum.Font.Gotham
					OptBtn.TextSize = 11
					OptBtn.TextTruncate = Enum.TextTruncate.AtEnd
					OptBtn.AutoButtonColor = false
					OptBtn.Parent = OptionHolder

					local OptCorner = Instance.new("UICorner")
					OptCorner.CornerRadius = UDim.new(0, 4)
					OptCorner.Parent = OptBtn

					OptBtn.MouseButton1Click:Connect(function()
						SelectOption(option, false)
					end)
				end

				if isExpanded then
					DropContainer.Size = UDim2.new(1, -12, 0, 36 + (#optionsList * 27))
				end
			end

			HeaderBtn.MouseButton1Click:Connect(function()
				isExpanded = not isExpanded
				if isExpanded then
					ArrowLabel.Text = "^"
					DropContainer.Size = UDim2.new(1, -12, 0, 36 + (#optionsList * 27))
				else
					Collapse()
				end
			end)

			RebuildOptions(optionsList)

			return {
				Refresh = RebuildOptions,
				-- Dipanggil dengan colon (targetDropdown:Set(v, true)) -> parameter pertama self.
				Set = function(_, option, silent)
					SelectOption(option, silent)
				end,
				Get = function()
					return selectedOption
				end,
			}
		end

		-- Label multi-baris (stats) dengan handle Set(text).
		local function CreateStatsLabel(parentPage, initialText)
			local Label = Instance.new("TextLabel")
			Label.Size = UDim2.new(1, -12, 0, 0)
			Label.AutomaticSize = Enum.AutomaticSize.Y
			Label.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			Label.BorderSizePixel = 0
			Label.Text = initialText or ""
			Label.TextColor3 = Color3.fromRGB(215, 220, 235)
			Label.Font = Enum.Font.Code
			Label.TextSize = 11
			Label.TextWrapped = true
			Label.TextXAlignment = Enum.TextXAlignment.Left
			Label.TextYAlignment = Enum.TextYAlignment.Top
			Label.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = Label

			local Padding = Instance.new("UIPadding")
			Padding.PaddingTop = UDim.new(0, 6)
			Padding.PaddingBottom = UDim.new(0, 6)
			Padding.PaddingLeft = UDim.new(0, 8)
			Padding.PaddingRight = UDim.new(0, 8)
			Padding.Parent = Label

			return {
				-- Dipanggil dengan colon (statsText:Set(text)) -> parameter pertama self.
				Set = function(_, newText)
					Label.Text = tostring(newText or "")
				end,
			}
		end

		-- Slider integer dengan handle Set(value, silent) / Get().
		local function CreateSlider(parentPage, text, minVal, maxVal, defaultVal, callback)
			local value = math.clamp(defaultVal or minVal, minVal, maxVal)

			local SliderFrame = Instance.new("Frame")
			SliderFrame.Size = UDim2.new(1, -12, 0, 44)
			SliderFrame.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			SliderFrame.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = SliderFrame

			local Title = Instance.new("TextLabel")
			Title.Size = UDim2.new(1, -16, 0, 20)
			Title.Position = UDim2.new(0, 8, 0, 2)
			Title.BackgroundTransparency = 1
			Title.Text = text .. ": " .. tostring(value)
			Title.TextColor3 = Color3.fromRGB(240, 240, 240)
			Title.Font = Enum.Font.GothamMedium
			Title.TextSize = 12
			Title.TextXAlignment = Enum.TextXAlignment.Left
			Title.Parent = SliderFrame

			local TrackBar = Instance.new("Frame")
			TrackBar.Size = UDim2.new(1, -16, 0, 10)
			TrackBar.Position = UDim2.new(0, 8, 0, 26)
			TrackBar.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
			TrackBar.BorderSizePixel = 0
			TrackBar.Parent = SliderFrame

			local TrackCorner = Instance.new("UICorner")
			TrackCorner.CornerRadius = UDim.new(1, 0)
			TrackCorner.Parent = TrackBar

			local FillBar = Instance.new("Frame")
			local initialPercent = (value - minVal) / (maxVal - minVal)
			FillBar.Size = UDim2.new(initialPercent, 0, 1, 0)
			FillBar.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
			FillBar.BorderSizePixel = 0
			FillBar.Parent = TrackBar

			local FillCorner = Instance.new("UICorner")
			FillCorner.CornerRadius = UDim.new(1, 0)
			FillCorner.Parent = FillBar

			local isSliding = false

			local function Apply(newValue, silent)
				newValue = math.clamp(math.floor((tonumber(newValue) or value) + 0.5), minVal, maxVal)
				local percent = (newValue - minVal) / (maxVal - minVal)
				value = newValue
				Title.Text = text .. ": " .. tostring(value)
				FillBar.Size = UDim2.new(percent, 0, 1, 0)
				if not silent then
					pcall(callback, value)
				end
			end

			local function UpdateFromInput(input)
				local width = TrackBar.AbsoluteSize.X
				if width <= 0 then
					return
				end
				local pos = math.clamp((input.Position.X - TrackBar.AbsolutePosition.X) / width, 0, 1)
				local newValue = minVal + (maxVal - minVal) * pos
				if math.abs(newValue - value) >= 1 then
					Apply(newValue, false)
				end
			end

			TrackBar.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					isSliding = true
					UpdateFromInput(input)
					input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then
							isSliding = false
						end
					end)
				end
			end)

			UserInputService.InputChanged:Connect(function(input)
				if isSliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
					UpdateFromInput(input)
				end
			end)

			return {
				-- Dipanggil dengan colon (slider:Set(v, true)) -> parameter pertama self.
				Set = function(_, newValue, silent)
					Apply(newValue, silent)
				end,
				Get = function()
					return value
				end,
			}
		end

		-- TextBox satu baris (label di atas, input full-width) + handle Set/Get.
		local function CreateTextBox(parentPage, text, placeholder, initialValue)
			local BoxFrame = Instance.new("Frame")
			BoxFrame.Size = UDim2.new(1, -12, 0, 56)
			BoxFrame.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
			BoxFrame.Parent = parentPage

			local Corner = Instance.new("UICorner")
			Corner.CornerRadius = UDim.new(0, 5)
			Corner.Parent = BoxFrame

			local Label = Instance.new("TextLabel")
			Label.Size = UDim2.new(1, -16, 0, 16)
			Label.Position = UDim2.new(0, 8, 0, 4)
			Label.BackgroundTransparency = 1
			Label.Text = text
			Label.TextColor3 = Color3.fromRGB(240, 240, 240)
			Label.Font = Enum.Font.GothamMedium
			Label.TextSize = 11
			Label.TextXAlignment = Enum.TextXAlignment.Left
			Label.TextTruncate = Enum.TextTruncate.AtEnd
			Label.Parent = BoxFrame

			local InputBox = Instance.new("TextBox")
			InputBox.Size = UDim2.new(1, -16, 0, 26)
			InputBox.Position = UDim2.new(0, 8, 0, 24)
			InputBox.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
			InputBox.Text = tostring(initialValue or "")
			InputBox.PlaceholderText = placeholder or "Ketik..."
			InputBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
			InputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
			InputBox.Font = Enum.Font.Code
			InputBox.TextSize = 11
			InputBox.ClearTextOnFocus = false
			InputBox.TextXAlignment = Enum.TextXAlignment.Left
			InputBox.Parent = BoxFrame

			local BoxCorner = Instance.new("UICorner")
			BoxCorner.CornerRadius = UDim.new(0, 4)
			BoxCorner.Parent = InputBox

			return {
				-- Dipanggil dengan colon (box:Set(v)) -> parameter pertama self.
				Set = function(_, newValue)
					InputBox.Text = tostring(newValue or "")
				end,
				Get = function()
					return InputBox.Text
				end,
				Focus = function(_)
					InputBox:CaptureFocus()
				end,
			}
		end

		-- // Tab Farm //
		local FarmPage = CreateTab("Farm")
		local InfoPage = CreateTab("Info")
		local MiscPage = CreateTab("Misc")

		CreateLabel(FarmPage, "Target & Kontrol")

		-- Dropdown: callback dapat string polos (bukan tabel).
		targetDropdown = CreateDropdown(FarmPage, "Target Quirk", quirkNames(), function(selected)
			if not isKnownQuirk(selected) then
				return
			end
			if not canProtectQuirk(selected) then
				log("WARN: " .. selected .. " tidak bisa diproteksi (weight >= 100) - hit tidak ditahan")
				notify("Target Quirk", selected .. " tidak bisa diproteksi server — hit tidak akan ditahan")
			end
			state.targetQuirk = selected
			if state.running then
				local blacklisted = rebuildBlacklist()
				applyProtections(selected)
				log(string.format("target -> %s (proteksi & blacklist diterapkan, %d unit blacklist)", selected, blacklisted))
			else
				log("target diganti -> " .. selected .. " (diterapkan saat start berikutnya)")
			end
			updateStatsText()
		end)

		-- Header dropdown harus menunjukkan target AKTIF (state.targetQuirk), bukan opsi
		-- pertama daftar. Silent = hanya tampilan, tanpa memicu callback.
		targetDropdown:Set(state.targetQuirk, true)

		-- Toggle: SATU-SATUNYA jalur start()/stop() dari UI.
		farmToggle = CreateToggle(FarmPage, "Auto Farm Quirk", false, function(value)
			if value then
				start()
			else
				stop()
			end
		end)

		CreateToggle(FarmPage, "Blacklist unit langka", BLACKLIST_RARE_UNITS, function(value)
			BLACKLIST_RARE_UNITS = value
			state.blacklistRare = value
			if state.running and DC then
				local n = rebuildBlacklist()
				log(string.format("blacklist %s — %d unit", value and "ON" or "OFF", n))
			end
			notify("Blacklist", value and "Unit langka lama tidak di-reroll" or "Unit langka lama ikut di-reroll")
		end)

		CreateLabel(FarmPage, "Stats")
		statsText = CreateStatsLabel(FarmPage,
			"rolls: 0 · accepted: 0 · hits: 0\nrare dibuang: 0 · money spent: 0\ncurrent: - · target: " .. tostring(state.targetQuirk))

		-- // Tab Info //
		CreateLabel(InfoPage, "Status Runtime")

		local InfoStats = CreateStatsLabel(InfoPage, "membaca status...")

		CreateButton(InfoPage, "Cek jarak ke mesin Quirk", function()
			local dist = distanceToMachine()
			if dist then
				notify("Jarak ke Mesin", string.format("%.0f studs dari pusat zona Quirks", dist))
			else
				notify("Jarak ke Mesin", "Tidak terbaca (zona/karakter belum siap)")
			end
		end)

		CreateButton(InfoPage, "Tes HIT relay (Discord)", function()
			local ok, info = testHit()
			notify("Tes Relay", ok and ("terkirim (delivered=" .. tostring(info.delivered) .. ")") or ("gagal: " .. tostring(info.code)))
		end)

		-- Loop ringan: hanya hidup selama GUI ada.
		task.spawn(function()
			while guiRoot and guiRoot.Parent do
				pcall(function()
					local dist = distanceToMachine()
					local blackCount = 0
					for _ in pairs(blacklist) do
						blackCount += 1
					end
					InfoStats:Set(string.format(
						"jarak mesin: %s\nremote: %s · key: %s · rev: %s\nkandidat: %d · blacklist: %d\nrunning: %s · target: %s",
						dist and string.format("%.0f studs", dist) or "tidak terbaca",
						state.remote.enabled and "ON" or "OFF",
						state.remote.keySet and "ada" or "-",
						tostring(state.remote.appliedRev or 0),
						state.candidateCount or 0,
						blackCount,
						tostring(isRunning()),
						tostring(state.targetQuirk)
					))
				end)
				task.wait(2)
			end
		end)

		-- // Tab Misc //
		CreateLabel(MiscPage, "Sistem & Optimasi")

		CreateToggle(MiscPage, "Anti-AFK Otomatis", true, function(value)
			antiAfkEnabled = value
			if value then
				EnableAntiAfk()
			end
			notify("Anti-AFK", value and "Aktif" or "Nonaktif")
		end)

		CreateToggle(MiscPage, "Matikan 3D Render (hemat)", false, function(value)
			pcall(function()
				RunService:Set3dRenderingEnabled(not value)
			end)
			notify("Optimasi Layar", value and "Render 3D dimatikan" or "Render 3D menyala")
		end)

		CreateLabel(MiscPage, "Skala Tampilan")

		-- Skala manual: default = skala auto saat GUI dibuat. Begitu slider digeser,
		-- nilainya menimpa auto-scale (tetap dipakai walau layar diputar/di-split).
		local scaleSlider = CreateSlider(
			MiscPage,
			"Skala GUI (%)",
			40,
			150,
			math.floor((UIScale.Scale * 100) + 0.5),
			function(newPercent)
				manualScale = newPercent / 100
				UpdateScale()
				log(string.format("skala GUI manual: %d%%", newPercent))
			end
		)

		CreateButton(MiscPage, "Kembali ke Auto Scale", function()
			manualScale = nil
			UpdateScale()
			if scaleSlider then
				scaleSlider:Set(math.floor((UIScale.Scale * 100) + 0.5), true)
			end
			notify("Skala GUI", "Kembali ke auto scale")
		end)

		CreateButton(MiscPage, "Tes toast notification", function()
			notify("Halo!", "Toast notification berjalan normal.")
		end)

		CreateLabel(MiscPage, "Discord Webhook")

		-- Prefill dari nilai aktif: state.webhookUrl -> ENV.quirkFarm.webhookUrl -> file
		-- (WEBHOOK_URL sudah di-resolve saat load dari webhook_url.txt).
		local webhookBox = CreateTextBox(
			MiscPage,
			"URL webhook (disimpan ke webhook_url.txt)",
			"https://discord.com/api/webhooks/...",
			getWebhookUrl()
		)

		CreateButton(MiscPage, "Simpan Webhook", function()
			local url = tostring(webhookBox:Get() or ""):gsub("^%s+", ""):gsub("%s+$", "")
			local valid = url == ""
				or url:match("^https://discord%.com/api/webhooks/") ~= nil
				or url:match("^https://discordapp%.com/api/webhooks/") ~= nil
			if not valid then
				notify("Webhook", "URL tidak valid — harus https://discord.com/api/webhooks/...")
				return
			end

			-- Berlaku langsung tanpa reload.
			state.webhookUrl = url
			WEBHOOK_URL = url
			ENV.quirkFarm.webhookUrl = url
			webhookBox:Set(url)

			-- Persisten: file ini dibaca otomatis saat script dimuat berikutnya.
			if type(writefile) ~= "function" then
				notify("Webhook", "Berlaku untuk sesi ini — executor tidak punya writefile")
				log("webhook " .. (url == "" and "dibersihkan" or "disimpan") .. " (writefile tidak tersedia)")
				return
			end
			local okWrite = pcall(writefile, "webhook_url.txt", url)
			if okWrite then
				notify("Webhook", url == ""
					and "Webhook dihapus (webhook_url.txt dikosongkan)"
					or "Webhook disimpan — tidak perlu isi ulang saat load")
				log("webhook " .. (url == "" and "dibersihkan" or "disimpan") .. " ke webhook_url.txt")
			else
				notify("Webhook", "Berlaku sekarang, tapi gagal menulis webhook_url.txt")
				log("WARN: gagal menulis webhook_url.txt")
			end
		end)

		CreateNotification("Quirk Farm Siap", "Pilih target lalu nyalakan Auto Farm di tab Farm.", 4)
	end)
	if not okUI then
		-- Jangan tinggalkan GUI setengah jadi; handle di-reset supaya farm tetap headless.
		if guiRoot then
			pcall(function()
				guiRoot:Destroy()
			end)
		end
		guiRoot, guiNotify, farmToggle, statsText, targetDropdown = nil, nil, nil, nil, nil
		log("ERROR: GUI gagal dibuat (" .. tostring(errUI) .. ") — lanjut headless, pakai getgenv().quirkFarm.{start,stop}")
	end
end

--// Remote config: satu baris status saat load \\--
-- Mode ON bila ENABLED + fungsi HTTP tersedia (open channel, key opsional).
-- Matikan lewat REMOTE_CONFIG.ENABLED = false kalau mau mode lokal murni.
if not REMOTE_CONFIG.ENABLED then
	log("remote config: OFF (nonaktif)")
elseif not REMOTE_HTTP then
	log("remote config: OFF (fungsi HTTP tidak tersedia)")
elseif SYNC_KEY ~= "" then
	log(string.format("remote config: ON (poll %ss, key)", tostring(REMOTE_CONFIG.POLL)))
else
	log(string.format("remote config: ON (poll %ss, open channel)", tostring(REMOTE_CONFIG.POLL)))
end

if not remoteOn and WEBHOOK_URL == "" then
	log("discord webhook: OFF (isi dari dashboard / getgenv().QUIRK_WEBHOOK / webhook_url.txt)")
end

if remoteOn then
	startRemoteLoop() -- menunggu running=true dari dashboard, tidak auto-start lokal
end

-- AUTO_START = false: script MEMAKAI uang in-game, jadi jangan pernah mulai
-- otomatis. User menyalakan lewat toggle GUI atau getgenv().quirkFarm.start().
-- Saat mode remote ON, start/stop sepenuhnya dari dashboard (running=true).
if AUTO_START and not remoteOn then
	local okStart, errStart = pcall(start)
	if not okStart then
		log("ERROR: start() threw: " .. tostring(errStart))
	end
end

-- Sinkron toggle dengan kenyataan APA PUN yang terjadi di atas
syncToggle(isRunning())
