--// Anime Dice — Quirk Auto Farm (Prodigy / Fortune's Favor hunter) \\--
-- Me-roll mesin Quirk di unit Common milik player sampai tiap unit mendapat
-- quirk target (Prodigy atau Fortune's Favor), lalu melindunginya sekali per
-- sesi dan melanjut ke unit berikutnya. Server QUIRKSERVICE:
--   • Roll: Network.QuirkService.RE.Roll — FireServer(unitKey) SAJA.
--     Argumen kedua (force=true) melewati proteksi — DILARANG dipakai script ini.
--   • Proteksi: Network.QuirkService.RE.SetQuirkProtected — FireServer(quirk, true).
--     Server hanya menerima quirk dengan config weight < 100 (kedua target lolos).
--   • Debounce server 0.2s per pemain -> interval client ROLL_INTERVAL = 0.25s.
--   • Server MENOLAK DIAM-DIAM (tanpa error) bila: quirk unit sedang diproteksi
--     (proteksi GLOBAL per nama quirk — melindungi "Prodigy" memblokir reroll di
--     unit mana pun yang sedang memegang Prodigy), uang kurang, atau kena debounce.
--     Deteksi penolakan di client (dual-signal): roll sukses = quirk unit BERUBAH
--     atau uang turun yang terlihat. Money-compare SAJA tidak cukup — di akun kaya
--     (magnitude 1e17+) ULP double ~64 sedangkan roll cost Common ~5, jadi roll
--     sukses terbaca "uang tidak berubah" = penolakan palsu; income pasif juga
--     mengaburkan arah. Roll sukses yang kebetulan mendarat di quirk SAMA persis
--     disamarkan jadi penolakan — dibatasi STUCK_LIMIT (0.18^10 ~ 1e-8, aman).
-- Odds: Prodigy weight 2 (≈1/2778), Fortune's Favor weight 0.5 (≈1/11112).
-- Script INI MEMAKAI UANG IN-GAME — AUTO_START = false, start manual saja.
--
-- Usage : loadstring(readfile("quirk-auto-farm.luau"))()
-- UI    : Rayfield Gen 2 (dependensi: https://sirius.menu/gen2) — SATU window
--           "Quirk Auto Farm" berisi dropdown target, toggle Auto Farm Quirk,
--           toggle Protect on hit, dan Stats. Toggle ON = start, OFF = stop.
--           AUTO_START = false: tidak jalan otomatis saat load.
--           Bila load Rayfield gagal (tanpa HttpGet / tanpa jaringan) script
--           TETAP jalan tanpa UI (headless) — kontrol via API di bawah.
-- API   : getgenv().quirkFarm = { stats, start, stop, isRunning, setTarget }
--             stats          -- { rolls, hits, moneySpent } — akumulatif
--             start()        -- true = berjalan, false = gagal (recoverable)
--             stop()         -- hentikan loop generasi sekarang
--             isRunning()    -- status running sekarang
--             setTarget(name)-- "Prodigy" | "Fortune's Favor"; berlaku rotasi berikutnya
-- Idempotent: re-running stops the previous instance first, unloads the previous
-- Rayfield window, then builds exactly one new window — no stacked windows, no
-- double loops. Lifecycle memakai generation token (runId): setiap start/stop
-- menaikkan runId, semua loop membawa id generasinya dan keluar saat id ~= runId.

--// Teardown instance lama — urutan di bawah WAJIB urut (window/loop bocor kalau tidak) \\--
local ENV = (type(getgenv) == "function") and getgenv() or _G

-- (1) Hentikan farm generasi lama dulu -> re-run = ganti, bukan menumpuk loop.
if type(ENV.quirkFarm) == "table" and type(ENV.quirkFarm.stop) == "function" then
	pcall(ENV.quirkFarm.stop)
end

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
local AUTO_START = false -- script MEMAKAI uang in-game: jangan start otomatis; user nyalakan manual lewat toggle/API
local ROLL_INTERVAL = 0.25 -- server debounce 0.2s per pemain -> 0.25s ambang aman
local WEBHOOK_URL = "https://discord.com/api/webhooks/1422109131006808156/FzTcL84FAs4hfeBXUXnEad0RQrWXiVzd8bZwlqnc2IKq-W1zVZVFIhP66IPJi1yuhkR8" -- URL Discord webhook; bisa dioverride runtime via getgenv().quirkFarm.webhookUrl
local STUCK_LIMIT = 10 -- ambigu berturut-turut (quirk tak berubah + uang tak turun) sebelum unit dilewati; 10 menutup roll sukses yang kebetulan mendarat di quirk sama (~0.18^10)

--// State \\--
local state = {
	running = false,
	targetQuirk = "Prodigy", -- diganti lewat dropdown / setTarget(); berlaku rotasi kandidat berikutnya
	protectOnHit = true, -- lindungi quirk target sekali per sesi begitu dapat
	protectedOnce = false, -- guard: SetQuirkProtected hanya ditembak SATU kali per sesi
}
local runId = 0 -- generation token: tiap start/stop naik 1 -> loop generasi lama mati bersih
local stats = { rolls = 0, hits = 0, moneySpent = 0 } -- akumulatif lintas stop/start (tidak pernah di-reset)
local DC -- DataController hasil require (di-resolve ulang tiap start; nil = belum/belum berhasil)
local RollRE, ProtectRE -- remote QuirkService (di-resolve ulang tiap start; nil = belum)
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

-- Quirk unit: entry.attributes.quirk adalah STRING (atau nil bila belum punya).
-- Diverifikasi live: memanggilnya sebagai function error "attempt to call a string
-- value". Tetap dukung bentuk callable Value kalau game membungkusnya di versi lain.
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

--// Stats UI sink \\--
-- Update elemen Stats di window Rayfield. pcall karena window bisa saja sudah
-- di-Unload (re-run / user tutup) atau UI memang tidak pernah ter-build.
local function updateStatsText(unitLabel)
	pcall(function()
		if statsText then
			statsText:Set(string.format(
				"rolls: %d · hits: %d · money spent: %d\ncurrent: %s · target: %s",
				stats.rolls, stats.hits, stats.moneySpent,
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

-- URL webhook: override runtime via getgenv().quirkFarm.webhookUrl mengalahkan
-- konfigurasi statis WEBHOOK_URL.
local function getWebhookUrl()
	local api = ENV.quirkFarm
	if type(api) == "table" and type(api.webhookUrl) == "string" and api.webhookUrl ~= "" then
		return api.webhookUrl
	end
	return WEBHOOK_URL
end

-- Notifikasi hit ke Discord (embed ala AIO). Diam-diam dilewati bila URL kosong.
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
				description = ("**%s** mendapat quirk **%s** di unit **%s**."):format(
					tostring(LocalPlayer.Name), quirk, unitName
				),
				color = 15105570, -- ember/orange, sewarna tema window
				fields = {
					{ name = "Rolls", value = tostring(stats.rolls), inline = true },
					{ name = "Hits", value = tostring(stats.hits), inline = true },
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

-- Cek apakah quirk sedang diproteksi (GLOBAL per nama quirk, dibaca dari data
-- client). Unit yang memegang quirk terproteksi tidak bisa di-reroll server-side
-- (QuirkService menolak diam-diam), jadi tidak perlu dijadikan kandidat.
-- Bentuk API terverifikasi live: DC.ProtectedQuirks() -> map nama -> Value callable.
local function isQuirkProtected(quirk)
	if quirk == nil then
		return false
	end
	local ok, v = pcall(function()
		local map = DC and DC.ProtectedQuirks and DC.ProtectedQuirks()
		local value = map and map[quirk]
		if type(value) == "function" then
			return value()
		end
		return value
	end)
	return ok and v == true
end

--// Farm loop \\--
-- Snapshot inventory -> filter unit Common yang quirknya BELUM target.
-- Dipanggil ulang tiap rotasi penuh: ganti target lewat dropdown berlaku di sini,
-- unit yang sudah dapat target otomatis gugur dari daftar.
local function computeCandidates(id)
	local candidates = {}
	local protectedSkipped = 0
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
					if isQuirkProtected(quirk) then
						-- Server akan menolak roll di unit ini selama quirk-nya
						-- terproteksi — lewati tanpa membuang roll.
						protectedSkipped += 1
					else
						-- Cost per unit; gagal hitung = 0 -> loop andalkan money-compare.
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
	if protectedSkipped > 0 then
		log(string.format("kandidat: %d unit; %d dilewati karena quirk terproteksi", #candidates, protectedSkipped))
	end
	return candidates
end

-- Satu unit: roll terus sampai quirk = target, uang habis, atau ditolak server
-- STUCK_LIMIT kali berturut-turut. id = token generasi pemanggil.
local function processCandidate(id, cand)
	local refusals = 0 -- penolakan diam-diam berturut-turut -> indikasi unit stuck
	while state.running and id == runId do
		local money = readMoney()
		if money == nil then
			-- Gagal baca uang: jangan fire (racun state), perlakukan sebagai penolakan.
			log("WARN: gagal membaca uang — menunggu interval")
			refusals += 1
			if refusals >= STUCK_LIMIT then
				log("WARN: unit stuck (data tidak terbaca?), skip: " .. cand.name)
				return
			end
			task.wait(ROLL_INTERVAL)
			continue
		end
		if money < cand.cost then
			-- Uang kurang untuk roll cost unit ini: hentikan seluruh farm.
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
		task.wait(ROLL_INTERVAL)

		local after = readMoney() or before
		local quirkNow = readQuirk(cand.entry)
		stats.rolls += 1

		if quirkNow == state.targetQuirk then
			-- HIT: quirk target didapat.
			stats.hits += 1
			stats.moneySpent += math.max(before - after, 0)
			if state.protectOnHit and not state.protectedOnce then
				-- Proteksi sekali per sesi: cukup melindungi nama quirk satu kali
				-- karena proteksi bersifat GLOBAL per nama quirk.
				pcall(function()
					ProtectRE:FireServer(state.targetQuirk, true)
				end)
				state.protectedOnce = true
				log("proteksi diaktifkan untuk " .. state.targetQuirk)
			end
			sendWebhook(cand.name, state.targetQuirk)
			log(string.format("HIT: %s dapat %s (rolls=%d hits=%d)", cand.name, state.targetQuirk, stats.rolls, stats.hits))
			notify("Quirk Farm", cand.name .. " dapat " .. state.targetQuirk .. "!")
			return
		end
		if after < before or quirkNow ~= quirkBefore then
			-- Roll sukses tapi quirk meleset. Dual-signal: uang turun yang TERLIHAT
			-- ATAU quirk berubah. Money-compare saja tidak cukup — di akun kaya
			-- (magnitude ~1e17) ULP double ~64 sedangkan roll cost Common ~5, jadi
			-- uang tak pernah terlihat berubah dan roll sukses dihitung penolakan.
			-- Quirk berubah adalah sinyal utama; uang hanya pelengkap.
			if after < before then
				stats.moneySpent += (before - after)
			end
			refusals = 0
			-- lanjut roll unit yang sama
		else
			-- Kedua sinyal diam: server tolak diam-diam (proteksi / debounce),
			-- ATAU roll sukses yang kebetulan mendarat di quirk SAMA persis
			-- (probabilitas rendah; STUCK_LIMIT=10 membuatnya ~0.18^10 ≈ 1e-8).
			refusals += 1
			if refusals >= STUCK_LIMIT then
				log("WARN: unit stuck (protected/debounce?), skip: " .. cand.name)
				return
			end
		end
		updateStatsText(cand.name)
	end
	return
end

-- Outer loop: satu rotasi penuh lewat semua kandidat, lalu recompute.
-- id = token generasi: hidup tepat selama generasinya masih aktif.
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
		-- Rotasi penuh selesai -> recompute kandidat (target baru / unit yang sudah
		-- dapat target sudah gugur).
	end
end

--// Lifecycle: stop \\--
-- Aman dipanggil saat belum pernah start, tanpa UI (headless), atau dari API getgenv.
function stop()
	runId += 1 -- invalidasi SEMUA loop generasi sekarang
	state.running = false
	syncToggle(false) -- toggle OFF dua-argumen tanpa callback -> tidak memicu start() lagi
	notify("Quirk Farm", string.format(
		"Farming dihentikan — rolls: %d, hits: %d, money spent: %d",
		stats.rolls, stats.hits, stats.moneySpent
	))
	log("stopped (rolls=" .. stats.rolls .. " hits=" .. stats.hits .. " moneySpent=" .. stats.moneySpent .. ")")
end

--// Lifecycle: start \\--
-- start(): no-op kalau sudah jalan; kegagalan apa pun recoverable (log + notify,
-- toggle dipaksa OFF, window tetap hidup). Return true = berjalan.
local function start()
	if state.running then
		return true -- sudah berjalan: no-op
	end

	-- Resolve DataController: wajib ada, tanpa itu tidak ada data unit/uang.
	local okDC, dcMod = pcall(function()
		return require(RS.Framework.Features.Data.DataController)
	end)
	if not okDC or type(dcMod) ~= "table" then
		log("ERROR: DataController tidak tersedia — start ulang nanti")
		notify("Quirk Farm", "Gagal start: DataController tidak tersedia")
		return false
	end
	DC = dcMod

	-- Resolve remotes. RollRE wajib; ProtectRE hanya dipakai bila Protect on hit ON.
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

	-- Snapshot cepat: pastikan Inventory dan Money terbaca sebelum loop roll.
	local money0 = readMoney()
	if money0 == nil then
		log("ERROR: gagal membaca uang — start ulang nanti")
		notify("Quirk Farm", "Gagal start: data uang tidak terbaca")
		return false
	end

	state.running = true
	state.protectedOnce = false -- guard proteksi berlaku per sesi (per start)
	runId += 1
	local id = runId

	task.spawn(mainLoop, id)
	syncToggle(true) -- toggle ON dua-argumen tanpa callback -> tidak re-enter stop()
	notify("Quirk Farm", "Farming dimulai — target: " .. state.targetQuirk)
	log(string.format("aktif — target %s, protect on hit %s", state.targetQuirk, tostring(state.protectOnHit)))
	return true
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
		log("target diganti -> " .. name .. " (berlaku rotasi kandidat berikutnya)")
		return true
	end,
	webhookUrl = WEBHOOK_URL, -- field override runtime: ENV.quirkFarm.webhookUrl = "https://..."
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
			showName = "Quirk Auto Farm", -- WAJIB string (truthy), bukan boolean: Rayfield assign langsung ke property Text
		})
		rayfieldWindow = window
		-- Handle disimpan global SEBELUM build elemen: walau build setengah jadi
		-- gagal, re-run berikutnya tetap bisa Unload -> tidak ada window bocor.
		ENV.__quirkFarmRayfield = window

		local tab = window:CreateTab({ name = "Farm" })

		-- Dropdown single-mode: callback dapat string polos; handle .value SELALU
		-- table bahkan di single mode — jangan pernah membaca .value sebagai string.
		-- Ganti target hanya berlaku di rotasi kandidat berikutnya.
		targetDropdown = tab:CreateDropdown({
			name = "Target Quirk",
			description = "Prodigy (~1/2778) atau Fortune's Favor (~1/11112). Berlaku rotasi berikutnya.",
			options = { "Prodigy", "Fortune's Favor" },
			value = "Prodigy",
			forgetState = true, -- tidak ada persistensi target antar load
			callback = function(selected)
				if selected == "Prodigy" or selected == "Fortune's Favor" then
					state.targetQuirk = selected
					log("target diganti -> " .. selected .. " (berlaku rotasi kandidat berikutnya)")
				end
			end,
		})

		-- Toggle: callback = JALUR SATU-SATUNYA start()/stop() dari UI.
		farmToggle = tab:CreateToggle({
			name = "Auto Farm Quirk",
			description = "Roll unit Common sampai quirk target tercapai. Pakai uang in-game!",
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
			name = "Protect on hit",
			description = "SetQuirkProtected(target, true) sekali per sesi saat quirk pertama didapat.",
			value = true,
			forgetState = true,
			callback = function(value)
				state.protectOnHit = value
			end,
		})

		tab:CreateDivider()

		statsText = tab:CreateText({
			name = "Stats",
			text = "rolls: 0 · hits: 0 · money spent: 0\ncurrent: - · target: Prodigy",
		})
	end)
	if not okUI then
		log("ERROR: Rayfield UI gagal dibuat: " .. tostring(errUI))
	end
end

-- AUTO_START = false: script MEMAKAI uang in-game, jadi jangan pernah mulai
-- otomatis. User menyalakan lewat toggle Rayfield atau getgenv().quirkFarm.start().
if AUTO_START then
	local okStart, errStart = pcall(start)
	if not okStart then
		log("ERROR: start() threw: " .. tostring(errStart))
	end
end

-- Sinkron toggle dengan kenyataan APA PUN yang terjadi di atas (start sukses,
-- start gagal, AUTO_START false, atau Rayfield gagal dimuat -> no-op).
syncToggle(isRunning())
