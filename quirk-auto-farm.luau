--// Anime Dice — Quirk Auto Farm (Prodigy / Fortune's Favor hunter) \\--
-- Me-roll mesin Quirk di unit Common milik player sampai tiap unit mendapat
-- quirk target (Prodigy atau Fortune's Favor). Server QUIRKSERVICE:
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
-- Odds: Prodigy weight 2 (≈1/2778), Fortune's Favor weight 0.5 (≈1/11112).
-- Script INI MEMAKAI UANG IN-GAME — AUTO_START = false, start manual saja.
--
-- Usage : loadstring(readfile("quirk-auto-farm.luau"))()
-- UI    : Rayfield Gen 2 (dependensi: https://sirius.menu/gen2) — SATU window
--           "Quirk Auto Farm" berisi dropdown target, toggle Auto Farm Quirk,
--           toggle Blacklist unit langka, dan Stats. Toggle ON = start, OFF = stop.
--           AUTO_START = false: tidak jalan otomatis saat load.
--           Bila load Rayfield gagal (tanpa HttpGet / tanpa jaringan) script
--           TETAP jalan tanpa UI (headless) — kontrol via API di bawah.
-- API   : getgenv().quirkFarm = { stats, start, stop, isRunning, setTarget,
--             blacklist, rebuildBlacklist, webhookUrl }
--             stats          -- { rolls, accepted, hits, rareLost, moneySpent } akumulatif
--             start()        -- true = berjalan, false = gagal (recoverable)
--             stop()         -- hentikan loop + pulihkan snapshot proteksi
--             isRunning()    -- status running sekarang
--             setTarget(name)-- "Prodigy" | "Fortune's Favor"; proteksi + blacklist
--                               langsung diterapkan ulang bila sedang berjalan
--             blacklist      -- set unitKey -> true (unit yang tidak boleh di-reroll)
--             rebuildBlacklist() -- hitung ulang blacklist dari inventori sekarang
--             pullConfig()   -- tarik config dari dashboard sekarang (true, code | false, err)
--             pushStatus()   -- kirim status ke dashboard sekarang
--             remote         -- { enabled, keySet, lastError, lastPullAt, appliedRev }
-- Remote : sync key diambil dari getgenv().QUIRK_SYNC_KEY, lalu REMOTE_CONFIG.SYNC_KEY,
--          lalu file "quirk_sync_key.txt" (readfile). Kosong semua = mode lokal murni.
--          Key tidak pernah di-log dan tidak pernah ditulis ke disk oleh script ini.
-- Idempotent: re-running stops the previous instance first (yang juga memulihkan
-- proteksi), unloads the previous Rayfield window, then builds exactly one new
-- window — no stacked windows, no double loops. Lifecycle memakai generation
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

-- (2) Tutup window Rayfield generasi lama (handle disimpan di ENV saat build).
do
	local oldWindow = ENV.__quirkFarmRayfield
	if type(oldWindow) == "table" and oldWindow.unloaded == false then
		pcall(function()
			oldWindow:Unload()
		end)
	end
	ENV.__quirkFarmRayfield = nil
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

--// Config \\--
local AUTO_START = false -- script MEMAKAI uang in-game: jangan start otomatis
local ROLL_INTERVAL = 0.25 -- server debounce 0.2s per pemain -> 0.25s ambang aman
local WEBHOOK_URL = "" -- JANGAN hardcode: isi dari dashboard (card Quirk Farm), getgenv().QUIRK_WEBHOOK, atau file "webhook_url.txt"
-- Urutan sumber webhook: config dashboard -> getgenv().quirkFarm.webhookUrl ->
-- getgenv().QUIRK_WEBHOOK -> file "webhook_url.txt". Kosong semua = tanpa notifikasi
-- (farm tetap jalan, hanya Discord yang dilewati). URL tidak pernah di-log.
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
local PROTECT_SETTLE_TIMEOUT = 3 -- detik menunggu replikasi SetQuirkProtected dikonfirmasi client
local BLACKLIST_RARE_UNITS = true -- blacklist unit lama yang sudah pegang quirk langka (weight < 100) selain target

--// Remote config (Supabase edge function) — opsional \\--
-- SYNC_KEY kosong = mode lokal: tidak ada timer/HTTP, perilaku persis seperti
-- sebelumnya. Isi key dari dashboard; JANGAN pernah hardcode key asli di sini.
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

--// Rayfield Gen 2 handles — dibuat sekali di jalur load; semuanya nil = tanpa UI \\--
local Rayfield -- hasil loader (nil = gagal dimuat -> mode headless, API tetap jalan)
local rayfieldWindow, farmToggle, statsText, targetDropdown

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
	desired[target] = true

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
	if not isProtected(target) then
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

-- Refleksi state ke toggle Rayfield TANPA callback: Set(v, true) = skip callback,
-- jadi stop()/start() tidak pernah saling re-enter lewat UI (anti-recursion).
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
				return
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

		if quirkNow == state.targetQuirk then
			-- HIT: target sudah diproteksi sejak start -> tidak ada yang perlu difire.
			stats.accepted += 1
			stats.hits += 1
			stats.moneySpent += math.max(before - after, 0)
			sendWebhook(cand.name, state.targetQuirk)
			log(string.format("HIT: %s dapat %s (rolls=%d hits=%d)", cand.name, state.targetQuirk, stats.rolls, stats.hits))
			notify("Quirk Farm", cand.name .. " dapat " .. state.targetQuirk .. "!")
			return
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
				return
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

	task.spawn(mainLoop, id)
	syncToggle(true) -- toggle ON dua-argumen tanpa callback -> tidak re-enter stop()
	notify("Quirk Farm", string.format(
		"Farming dimulai — target %s (diproteksi), %d unit di-blacklist", state.targetQuirk, blacklisted
	))
	log(string.format("aktif — target %s diproteksi, rare lain dilepas, blacklist %d unit", state.targetQuirk, blacklisted))
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
local remoteOn = REMOTE_CONFIG.ENABLED and SYNC_KEY ~= "" and REMOTE_HTTP ~= nil
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
			if type(cfg.target) == "string" and isRareQuirk(cfg.target) then
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
-- Rayfield gagal dimuat.
ENV.quirkFarm = {
	stats = stats,
	stop = stop,
	start = start,
	isRunning = isRunning,
	pullConfig = pullConfig,
	pushStatus = pushStatus,
	remote = remoteInfo,
	setTarget = function(name)
		if name ~= "Prodigy" and name ~= "Fortune's Favor" then
			log("WARN: setTarget ditolak, target tidak dikenal: " .. tostring(name))
			return false
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

--// UI: Rayfield Gen 2 — dimuat + dibangun SEKALI per eksekusi, di jalur load \\--
do
	local okRF, resRF = pcall(function()
		return loadstring(game:HttpGet("https://sirius.menu/gen2"))()
	end)
	if okRF and type(resRF) == "table" then
		Rayfield = resRF
	else
		log("ERROR: Rayfield gagal dimuat (" .. tostring(resRF) .. ") — lanjut tanpa UI, pakai getgenv().quirkFarm.{start,stop}")
	end
end

-- SEMUA pembuatan elemen di dalam satu pcall: kegagalan UI tidak boleh membunuh
-- logika headless (start/stop via getgenv API tetap hidup).
if Rayfield then
	local okUI, errUI = pcall(function()
		local window = Rayfield:CreateWindow({
			name = "Quirk Auto Farm",
			subtitle = "Anime Dice — Prodigy / Fortune's Favor hunter",
			theme = "ember",
			showName = "Quirk Auto Farm", -- WAJIB string (truthy), bukan boolean
		})
		rayfieldWindow = window
		-- Handle disimpan global SEBELUM build elemen: walau build setengah jadi
		-- gagal, re-run berikutnya tetap bisa Unload -> tidak ada window bocor.
		ENV.__quirkFarmRayfield = window

		local tab = window:CreateTab({ name = "Farm" })

		-- Dropdown single-mode: callback dapat string polos; handle .value SELALU
		-- table bahkan di single mode — jangan pernah membaca .value sebagai string.
		targetDropdown = tab:CreateDropdown({
			name = "Target Quirk",
			description = "Prodigy (~1/2778) atau Fortune's Favor (~1/11112). Langsung diterapkan bila farm sedang jalan.",
			options = { "Prodigy", "Fortune's Favor" },
			value = "Prodigy",
			forgetState = true, -- tidak ada persistensi target antar load
			callback = function(selected)
				if selected == "Prodigy" or selected == "Fortune's Favor" then
					state.targetQuirk = selected
					if state.running then
						local blacklisted = rebuildBlacklist()
						applyProtections(selected)
						log(string.format("target -> %s (proteksi & blacklist diterapkan, %d unit blacklist)", selected, blacklisted))
					else
						log("target diganti -> " .. selected .. " (diterapkan saat start berikutnya)")
					end
				end
			end,
		})

		-- Toggle: callback = JALUR SATU-SATUNYA start()/stop() dari UI.
		farmToggle = tab:CreateToggle({
			name = "Auto Farm Quirk",
			description = "Roll unit Common sampai quirk target tercapai. Target diproteksi otomatis. Pakai uang in-game!",
			value = false,
			forgetState = true, -- tidak ada persistensi: AUTO_START = false, start manual
			callback = function(value)
				if value then
					start()
				else
					stop()
				end
			end,
		})

		tab:CreateToggle({
			name = "Blacklist unit langka",
			description = "Unit yang sudah pegang quirk langka (selain target) tidak di-reroll, jadi inventori lama aman.",
			value = true,
			forgetState = true,
			callback = function(value)
				BLACKLIST_RARE_UNITS = value
				state.blacklistRare = value
				if state.running and DC then
					local n = rebuildBlacklist()
					log(string.format("blacklist %s — %d unit", value and "ON" or "OFF", n))
				end
			end,
		})

		tab:CreateDivider()

		statsText = tab:CreateText({
			name = "Stats",
			text = "rolls: 0 · accepted: 0 · hits: 0\nrare dibuang: 0 · money spent: 0\ncurrent: - · target: Prodigy",
		})
	end)
	if not okUI then
		log("ERROR: Rayfield UI gagal dibuat: " .. tostring(errUI))
	end
end

--// Remote config: satu baris status saat load \\--
-- Mode ON hanya bila ENABLED + sync key terisi + fungsi HTTP tersedia. Tanpa
-- key, mode lokal berjalan persis seperti sebelumnya (tanpa timer/HTTP).
if not REMOTE_CONFIG.ENABLED then
	log("remote config: OFF (nonaktif)")
elseif SYNC_KEY == "" then
	log("remote config: OFF (sync key kosong)")
elseif not REMOTE_HTTP then
	log("remote config: OFF (fungsi HTTP tidak tersedia)")
else
	log(string.format("remote config: ON (poll %ss)", tostring(REMOTE_CONFIG.POLL)))
end

if WEBHOOK_URL == "" then
	log("discord webhook: OFF (isi dari dashboard / getgenv().QUIRK_WEBHOOK / webhook_url.txt)")
end

if remoteOn then
	startRemoteLoop() -- menunggu running=true dari dashboard, tidak auto-start lokal
end

-- AUTO_START = false: script MEMAKAI uang in-game, jadi jangan pernah mulai
-- otomatis. User menyalakan lewat toggle Rayfield atau getgenv().quirkFarm.start().
-- Saat mode remote ON, start/stop sepenuhnya dari dashboard (running=true).
if AUTO_START and not remoteOn then
	local okStart, errStart = pcall(start)
	if not okStart then
		log("ERROR: start() threw: " .. tostring(errStart))
	end
end

-- Sinkron toggle dengan kenyataan APA PUN yang terjadi di atas
syncToggle(isRunning())
