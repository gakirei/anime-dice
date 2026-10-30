--// Anime Dice - Trade Auto (web dashboard -> game) \\--
-- Menjalankan trade dengan pemain yang dipilih dari dashboard web, hanya
-- menawarkan unit yang quirk-nya cocok, lalu Ready -> Accept otomatis dari sisi
-- kita. Trade tetap diselesaikan oleh server lewat remote TradeService resmi.
--
-- Alur dashboard:
--   Browser -> Supabase  : tabel trade_controls (config)   (di luar script ini)
--   Script  -> Supabase  : POST /functions/v1/trade { action = "pull", userId }
--                          POST /functions/v1/trade { action = "status", userId, status }
--   Cadence              : pull tiap 15 s, status tiap 30 s, config diterapkan
--                          HANYA saat config.rev berubah.
--
-- Catatan penting:
--   * Tidak ada GUI, tidak ada dependensi ke script repo lain (standalone).
--   * Hanya remote TradeService yang ditembak. Tidak ada hook/memory patch.
--   * Sisi partner TIDAK pernah diotomasi; hanya trade milik kita.
--   * Nama unit/quirk tidak pernah di-hardcode: quirk target datang dari config,
--     daftar unit dibaca dari Inventory + EntryRegistry + TradeConfig game.
--
-- API console:
--   getgenv().tradeAuto.start()       -- mulai lokal (mengalahkan config sampai rev baru)
--   getgenv().tradeAuto.stop()        -- stop lokal + cancel trade yang aktif
--   getgenv().tradeAuto.state         -- tabel state live
--   getgenv().tradeAuto.pull()        -- tarik config sekarang
--   getgenv().tradeAuto.pushStatus()  -- push status sekarang
--
-- Usage:
--   loadstring(readfile("trade-auto.luau"))()

--// Teardown instance lama (idempotent) \\--
local ENV = (type(getgenv) == "function") and getgenv() or _G

if type(ENV.tradeAuto) == "table" and type(ENV.tradeAuto.stop) == "function" then
	pcall(ENV.tradeAuto.stop)
end
ENV.__tradeAutoGen = (tonumber(ENV.__tradeAutoGen) or 0) + 1
if ENV.__tradeAutoConn then
	pcall(function()
		ENV.__tradeAutoConn:Disconnect()
	end)
	ENV.__tradeAutoConn = nil
end

local runGen = ENV.__tradeAutoGen

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

--// Konfigurasi remote \\--
local TRADE_REMOTE = {
	ENABLED       = true,
	URL           = "https://rlbmftsefonfdqfhyjij.supabase.co/functions/v1/trade",
	POLL          = 15,
	STATUS_EVERY  = 30,
	VERSION       = "trade-1.0.0",
	RETRY_EVERY   = 8,    -- request baru paling cepat tiap 8 s (server cooldown 6 s)
	PENDING_TTL   = 7,    -- request server kedaluwarsa setelah 6 s; beri margin 1 s
	OFFER_GAP     = 0.15, -- debounce ChangeOffer server 0.1 s
	OFFER_TIMEOUT = 8,    -- lanjut Ready setelah 8 s walau belum semua offer terkonfirmasi
	ACCEPT_DELAY  = 0.6,  -- jeda sebelum Accept di phase Confirm
}

--// Dependensi game (semua di-guard; script tetap hidup walau salah satu gagal) \\--
local function tryRequire(fn)
	local ok, mod = pcall(fn)
	return ok and mod or nil
end

local Network = tryRequire(function()
	return require(RS.Packages.Network)
end)
local DataController = tryRequire(function()
	return require(RS.Framework.Features.Data.DataController)
end)
local EntryRegistry = tryRequire(function()
	return require(RS.Framework.Features.Inventory.EntryRegistry)
end)
local TradeConfig = tryRequire(function()
	return require(RS.Framework.Features.Trading.TradeConfig)
end)

local MAX_UNITS = 20
if type(TradeConfig) == "table" and type(TradeConfig.MAX_UNIQUE_ENTRIES) == "number" then
	MAX_UNITS = TradeConfig.MAX_UNIQUE_ENTRIES
end

local comm = Network and tryRequire(function()
	return Network.ClientComm.new(RS.Network, false, "TradeService")
end) or nil

local function getSignal(name)
	if not comm then
		return nil
	end
	local ok, signal = pcall(function()
		return comm:GetSignal(name)
	end)
	if ok and signal then
		return signal
	end
	-- Fallback untuk build ClientComm lama.
	ok, signal = pcall(function()
		return comm:Get(name)
	end)
	return ok and signal or nil
end

local RequestTrade = getSignal("RequestTrade")
local RespondToRequest = getSignal("RespondToRequest")
local ChangeOffer = getSignal("ChangeOffer")
local AdvanceTrade = getSignal("AdvanceTrade")
local CancelTrade = getSignal("CancelTrade")
local SetTradeRequestsEnabled = getSignal("SetTradeRequestsEnabled")
local TradeEvent = getSignal("TradeEvent")

--// State \\--
local session = {
	running = false, -- intent lokal / config terakhir
	state = "idle",  -- idle | waiting_target | request_sent | in_trade | done | error
	phase = "",      -- phase trade dari server (Offer/Confirm/Countdown/Saving)
	cfg = {
		running = false,
		targetUserId = nil,
		targetName = "",
		quirk = "",
		maxUnits = 20,
		autoAccept = true,
		autoReady = true,
		rev = 0,
	},
	appliedRev = nil,
	targetDisplay = "",
	-- request
	pendingRequest = false,
	pendingUntil = 0,
	lastRequestAt = 0,
	lastEnableAt = 0,
	cancelSent = false,
	-- trade
	tradeActive = false,
	partnerUserId = nil,
	candidates = {},
	matched = 0,
	desired = 0,
	offersPlaced = 0,
	offered = 0,
	ownOffer = {},
	offering = false,
	stopOffering = true,
	offerToken = 0,
	offersComplete = false,
	offersConfirmed = false,
	offerStartedAt = 0,
	ownReady = false,
	ownAccepted = false,
	readyFired = false,
	acceptedFired = false,
	lastAdvanceTryAt = 0,
	confirmAt = 0,
	sessionDone = false,
	suppressEnded = 0, -- abaikan event Ended dari trade yang kita batalkan sendiri
	-- remote
	lastError = nil,
	lastStatusAt = 0,
	lastPullAt = 0,
	notRegistered = false,
	deployMissing = false,
}

local function log(msg)
	print("[Trade] " .. tostring(msg))
end

-- lastError dibatasi 120 karakter (kontrak status).
local function setError(msg)
	if msg == nil then
		session.lastError = nil
		return
	end
	local text = tostring(msg)
	if #text > 120 then
		text = text:sub(1, 117) .. "..."
	end
	session.lastError = text
end

--// Helper data game \\--
local function uidOf(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "table" then
		return tonumber(value.UserId or value.userId or value.id)
	end
	local ok, id = pcall(function()
		return value.UserId
	end)
	return ok and tonumber(id) or nil
end

local function displayName(value)
	if value == nil then
		return "?"
	end
	local ok, name = pcall(function()
		return value.DisplayName
	end)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	ok, name = pcall(function()
		return value.Name
	end)
	return (ok and type(name) == "string" and name ~= "") and name or tostring(value)
end

-- Entry inventory bisa berupa node reaktif: guard dengan typeof(v) == "function".
local function snapEntry(entry)
	local amount = entry.amount
	if typeof(amount) == "function" then
		amount = amount()
	end
	local attrs = {}
	local rawAttrs = entry.attributes
	if typeof(rawAttrs) == "function" then
		rawAttrs = rawAttrs()
	end
	if typeof(rawAttrs) == "table" then
		for key, value in pairs(rawAttrs) do
			if typeof(value) == "function" then
				value = value()
			end
			local kind = typeof(value)
			if kind == "number" or kind == "string" or kind == "boolean" then
				attrs[key] = value
			end
		end
	end
	if typeof(amount) ~= "number" then
		amount = tonumber(amount) or 1
	end
	return amount, attrs
end

local function readInventory()
	if not DataController then
		return nil
	end
	local ok, node = pcall(function()
		return DataController.Inventory
	end)
	if not ok or node == nil then
		return nil
	end
	local inventory = node
	if type(inventory) == "function" then
		local okCall, value = pcall(inventory)
		if okCall then
			inventory = value
		end
	elseif type(inventory) == "table" then
		-- Node reaktif bisa berupa tabel yang callable.
		local okCall, value = pcall(function()
			return inventory()
		end)
		if okCall and type(value) == "table" then
			inventory = value
		end
	end
	if type(inventory) == "table" then
		return inventory
	end
	return nil
end

local function getEntryConfig(name)
	if not EntryRegistry then
		return nil
	end
	local ok, config = pcall(function()
		return EntryRegistry.getEntryConfig(name)
	end)
	return ok and config or nil
end

local function isTradeable(name)
	if not TradeConfig then
		return false
	end
	local ok, value = pcall(function()
		return TradeConfig.IsTradeable({ name = name })
	end)
	return ok and value == true
end

-- Kandidat: unit, tradeable, quirk == target. Urut level desc lalu nama.
local function computeCandidates(quirk)
	local result = {}
	if type(quirk) ~= "string" or quirk == "" then
		return result
	end
	local inventory = readInventory()
	if not inventory then
		return result
	end
	for key, entry in pairs(inventory) do
		if type(entry) == "table" then
			local name = entry.name
			if typeof(name) == "function" then
				name = name()
			end
			if type(name) == "string" then
				local config = getEntryConfig(name)
				if config and config.kind == "Unit" and isTradeable(name) then
					local _, attrs = snapEntry(entry)
					if attrs.quirk == quirk then
						result[#result + 1] = {
							key = key,
							name = name,
							level = tonumber(attrs.level) or 0,
						}
					end
				end
			end
		end
	end
	table.sort(result, function(a, b)
		if a.level ~= b.level then
			return a.level > b.level
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return tostring(a.key) < tostring(b.key)
	end)
	return result
end

local function countKeys(tbl)
	local count = 0
	for _ in pairs(tbl) do
		count += 1
	end
	return count
end

local function readTradeRequestsEnabled()
	if not DataController then
		return nil
	end
	local ok, node = pcall(function()
		return DataController.TradeRequestsEnabled
	end)
	if not ok then
		return nil
	end
	local value = node
	if type(value) == "function" then
		local okCall, result = pcall(value)
		return okCall and result or nil
	elseif type(value) == "table" then
		local okCall, result = pcall(function()
			return value()
		end)
		if okCall then
			return result
		end
	end
	return value
end

--// Fire helper: satu-satunya jalur menembak remote \\--
-- Arity tetap (0/1/2 argumen) supaya tidak bergantung pada vararg di closure.
local function fireSignal(signal, label, arg1, arg2)
	if not signal then
		setError("remote " .. label .. " tidak tersedia")
		return false
	end
	local ok, err
	if arg2 ~= nil then
		ok, err = pcall(function()
			return signal:Fire(arg1, arg2)
		end)
	elseif arg1 ~= nil then
		ok, err = pcall(function()
			return signal:Fire(arg1)
		end)
	else
		ok, err = pcall(function()
			return signal:Fire()
		end)
	end
	if not ok then
		setError(label .. ": " .. tostring(err))
		log(label .. " gagal: " .. tostring(err))
		return false
	end
	return true
end

--// Reset state trade (sessionDone TIDAK direset di sini) \\--
local function resetTrade()
	session.offerToken += 1
	session.tradeActive = false
	session.phase = ""
	session.partnerUserId = nil
	session.candidates = {}
	session.matched = 0
	session.desired = 0
	session.offersPlaced = 0
	session.offered = 0
	session.ownOffer = {}
	session.offering = false
	session.stopOffering = true
	session.offersComplete = false
	session.offersConfirmed = false
	session.offerStartedAt = 0
	session.ownReady = false
	session.ownAccepted = false
	session.readyFired = false
	session.acceptedFired = false
	session.lastAdvanceTryAt = 0
	session.confirmAt = 0
	session.cancelSent = false
end

--// Penawaran unit (task terpisah supaya tick tetap jalan) \\--
local function startOffering()
	session.offering = true
	local token = session.offerToken
	task.spawn(function()
		local index = 1
		while session.offerToken == token
			and session.tradeActive
			and session.phase == "Offer"
			and not session.stopOffering
			and index <= #session.candidates
			and session.offersPlaced < session.desired
		do
			local candidate = session.candidates[index]
			index += 1
			if fireSignal(ChangeOffer, "ChangeOffer", candidate.key, 1) then
				session.offersPlaced += 1
			end
			task.wait(TRADE_REMOTE.OFFER_GAP)
		end
		if session.offerToken == token then
			session.offering = false
			if session.tradeActive then
				log(string.format("offers placed %d/%d", session.offersPlaced, session.desired))
			end
		end
	end)
end

--// Event handler TradeService \\--
local function onStarted(payload)
	if not session.running then
		fireSignal(CancelTrade, "CancelTrade")
		return
	end
	local partner = payload and payload.partner or nil
	local partnerId = uidOf(partner)
	local targetId = session.cfg.targetUserId
	if targetId and partnerId and partnerId ~= targetId then
		log("trade started with non-target " .. displayName(partner) .. " -> cancel")
		fireSignal(CancelTrade, "CancelTrade")
		return
	end

	resetTrade()
	session.cancelSent = false
	session.tradeActive = true
	session.stopOffering = false
	session.phase = "Offer"
	session.partnerUserId = partnerId
	session.state = "in_trade"
	session.lastError = nil
	session.pendingRequest = false
	session.pendingUntil = 0
	session.candidates = computeCandidates(session.cfg.quirk)
	session.matched = #session.candidates
	local limit = math.clamp(session.cfg.maxUnits or MAX_UNITS, 1, MAX_UNITS)
	session.desired = math.min(#session.candidates, limit)
	session.offerStartedAt = os.clock()
	session.offersPlaced = 0
	log(string.format(
		"trade started with %s; %d unit cocok, menawarkan %d",
		displayName(partner), session.matched, session.desired
	))
	-- Tidak ada unit yang cocok: jangan kirim trade kosong (server tidak akan
	-- bisa lanjut ke Confirm). Batalkan sekali, laporkan, dan tunggu rev baru.
	if session.desired == 0 then
		local reason = "tidak ada unit dengan quirk " .. (session.cfg.quirk ~= "" and session.cfg.quirk or "(belum dipilih)")
		session.sessionDone = true
		session.suppressEnded += 1
		fireSignal(CancelTrade, "CancelTrade")
		resetTrade()
		setError(reason)
		session.state = "error"
		log(reason .. " -> trade dibatalkan")
		return
	end
	startOffering()
end

local function onUpdated(payload)
	payload = payload or {}
	if not session.running then
		if not session.cancelSent then
			session.cancelSent = true
			fireSignal(CancelTrade, "CancelTrade")
		end
		return
	end
	-- Jangan hidupkan lagi trade lama setelah sesi selesai / target berganti.
	if session.sessionDone then
		return
	end
	if payload.partner ~= nil and session.cfg.targetUserId ~= nil then
		local partnerId = uidOf(payload.partner)
		if partnerId ~= nil and partnerId ~= session.cfg.targetUserId then
			if not session.cancelSent then
				session.cancelSent = true
				fireSignal(CancelTrade, "CancelTrade")
			end
			return
		end
	end

	local phase = type(payload.phase) == "string" and payload.phase or session.phase
	local previous = session.phase
	session.tradeActive = true
	session.state = "in_trade"
	if payload.partner ~= nil then
		session.partnerUserId = uidOf(payload.partner) or session.partnerUserId
	end

	-- Flag ready/accepted di-reset saat phase berubah, bukan tiap update.
	session.phase = phase
	if phase ~= previous then
		if phase == "Offer" then
			session.readyFired = false
			session.acceptedFired = false
			session.confirmAt = 0
		elseif phase == "Confirm" then
			session.confirmAt = os.clock()
		end
	end

	session.ownReady = payload.ownReady == true
	session.ownAccepted = payload.ownAccepted == true
	local offered = {}
	if type(payload.ownOffer) == "table" then
		for key, amount in pairs(payload.ownOffer) do
			local value = tonumber(amount)
			if value and value > 0 then
				offered[key] = value
			end
		end
	end
	session.ownOffer = offered
	session.offered = countKeys(offered)
end

local function onRequestClosed(payload, kind)
	local who = uidOf(payload and payload.player)
	local targetId = session.cfg.targetUserId
	local partner = session.partnerUserId
	if who ~= nil and who ~= targetId and who ~= partner then
		return
	end
	session.pendingRequest = false
	session.pendingUntil = 0
	if session.tradeActive and (who == partner or who == targetId) then
		log(kind .. " dari partner -> reset trade")
		resetTrade()
		session.state = session.sessionDone and "done" or "idle"
	elseif session.state == "request_sent" then
		session.state = session.sessionDone and "done" or "idle"
	end
end

local function onEnded(payload)
	local reason = tostring((payload and payload.reason) or "Unknown")
	local wasActive = session.tradeActive
	if session.suppressEnded > 0 then
		-- Trade ini dibatalkan oleh stop / rev baru: jangan tandai sesi selesai.
		session.suppressEnded -= 1
		resetTrade()
		session.pendingRequest = false
		session.pendingUntil = 0
		log("ended " .. reason .. " (diabaikan)")
		return
	end
	if not wasActive then
		-- Event sisa dari instance/trade lama; jangan mengunci sesi baru.
		session.pendingRequest = false
		session.pendingUntil = 0
		log("ended " .. reason .. " (tanpa trade aktif, diabaikan)")
		return
	end
	resetTrade()
	session.pendingRequest = false
	session.pendingUntil = 0
	session.sessionDone = true
	session.state = "done"
	if reason == "Completed" then
		session.lastError = nil
	else
		setError(reason)
	end
	log("ended " .. reason)
end

local function onTradeEvent(kind, payload)
	if runGen ~= ENV.__tradeAutoGen then
		return
	end
	if kind == "RequestSent" then
		local who = uidOf(payload and payload.player)
		if who == nil or who == session.cfg.targetUserId then
			session.pendingRequest = true
			session.pendingUntil = os.clock() + TRADE_REMOTE.PENDING_TTL
			if session.running then
				session.state = "request_sent"
			end
		end
	elseif kind == "RequestReceived" then
		if not session.running then
			return
		end
		local who = uidOf(payload and payload.player)
		if who ~= nil and who == session.cfg.targetUserId and session.cfg.autoAccept then
			session.pendingRequest = true
			session.pendingUntil = os.clock() + TRADE_REMOTE.PENDING_TTL
			if fireSignal(RespondToRequest, "RespondToRequest", true) then
				log("auto-accept request from " .. displayName(payload.player))
			end
		end
	elseif kind == "RequestClosed" then
		onRequestClosed(payload, "RequestClosed")
	elseif kind == "RequestExpired" then
		onRequestClosed(payload, "RequestExpired")
	elseif kind == "Started" then
		onStarted(payload)
	elseif kind == "Updated" then
		onUpdated(payload)
	elseif kind == "Ended" then
		onEnded(payload)
	end
end

if TradeEvent then
	local okConnect, connection = pcall(function()
		return TradeEvent:Connect(function(kind, payload)
			local ok, err = pcall(onTradeEvent, kind, payload)
			if not ok then
				setError(err)
				log("event error: " .. tostring(err))
			end
		end)
	end)
	if okConnect then
		ENV.__tradeAutoConn = connection
	else
		log("WARN: gagal connect TradeEvent: " .. tostring(connection))
	end
else
	log("WARN: signal TradeEvent tidak tersedia")
end

--// HTTP POST JSON (request-based, sama seperti quirk-auto-farm) \\--
local function httpPostJson(url, body)
	local okEnc, encoded = pcall(function()
		return HttpService:JSONEncode(body)
	end)
	if not okEnc then
		return false, nil, "JSONEncode: " .. tostring(encoded)
	end

	local headers = { ["Content-Type"] = "application/json" }
	local candidates = {}
	local function add(name, fn)
		if type(fn) == "function" then
			candidates[#candidates + 1] = { name = name, fn = fn }
		end
	end
	for _, name in ipairs({ "request", "http_request", "http_post", "HttpPost", "httpRequest" }) do
		add(name, ENV[name])
		if ENV ~= _G then
			add(name, _G[name])
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
	add("HttpService:RequestAsync", function(options)
		return HttpService:RequestAsync(options)
	end)

	local lastError
	for _, candidate in ipairs(candidates) do
		local ok, response = pcall(candidate.fn, {
			Url = url,
			Method = "POST",
			Headers = headers,
			Body = encoded,
		})
		if ok and type(response) == "table" then
			local code = response.StatusCode or response.status or response.Status
			if type(code) == "number" and code >= 200 and code < 300 then
				return true, code, response.Body
			end
			-- Transport berhasil: jawaban non-2xx adalah jawaban server asli.
			if type(code) == "number" then
				return false, code, response.Body
			end
			if response.Success == true then
				return true, code, response.Body
			end
			lastError = candidate.name .. ": respons tidak dikenal"
		else
			lastError = candidate.name .. ": " .. tostring(response)
		end
	end
	return false, nil, tostring(lastError or "http tidak tersedia")
end

--// Status payload (kontrak tetap, 14 key) \\--
local function buildStatus()
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			players[#players + 1] = {
				id = player.UserId,
				name = (player.DisplayName ~= "" and player.DisplayName) or player.Name,
			}
		end
	end
	local matched = session.matched
	if not session.tradeActive then
		matched = #computeCandidates(session.cfg.quirk)
	end
	local targetUserId = session.cfg.targetUserId
	return {
		running = session.running,
		state = session.state,
		phase = session.phase or "",
		target = session.cfg.targetName ~= "" and session.cfg.targetName or session.targetDisplay or "",
		targetUserId = type(targetUserId) == "number" and targetUserId or 0,
		quirk = session.cfg.quirk or "",
		matched = matched,
		offered = session.offered,
		maxUnits = session.cfg.maxUnits or 20,
		players = players,
		appliedRev = session.appliedRev or 0,
		lastSeenAt = os.time(),
		lastError = session.lastError or "",
		version = TRADE_REMOTE.VERSION,
	}
end

-- 404 dari Supabase punya dua arti berbeda: fungsi belum di-deploy
-- ({"code":"NOT_FOUND","message":"Requested function was not found"}) atau
-- akun belum punya baris trade_controls ("not registered" dari edge function).
local function missingFunction(body)
	if type(body) ~= "string" then
		return false
	end
	return body:find("Requested function was not found", 1, true) ~= nil
		or body:find("NOT_FOUND", 1, true) ~= nil
end

local function noteRemoteFailure(code, body)
	if code ~= 404 then
		return
	end
	if missingFunction(body) then
		if not session.deployMissing then
			session.deployMissing = true
			log("WARN: fungsi 'trade' belum di-deploy (supabase functions deploy trade --no-verify-jwt)")
		end
		return
	end
	session.deployMissing = false
	if not session.notRegistered then
		session.notRegistered = true
		log("status 404 - akun belum terdaftar (buka kartu Trade di web lalu Save sekali)")
	end
end

local function pushStatus()
	if not TRADE_REMOTE.ENABLED then
		return false, "disabled"
	end
	local ok, code, body = httpPostJson(TRADE_REMOTE.URL, {
		action = "status",
		userId = LocalPlayer.UserId,
		status = buildStatus(),
	})
	session.lastStatusAt = os.clock()
	if not ok then
		noteRemoteFailure(code, body)
	end
	return ok, code
end

--// Config: diterapkan hanya saat rev berubah \\--
local function applyConfig(config)
	if type(config) ~= "table" or type(config.rev) ~= "number" then
		return false
	end
	if session.appliedRev ~= nil and config.rev == session.appliedRev then
		return false
	end

	local cfg = session.cfg
	local oldTarget = cfg.targetUserId
	cfg.running = (type(config.running) == "boolean") and config.running or cfg.running
	session.running = cfg.running

	local rawTarget = config.targetUserId
	if type(rawTarget) == "number" then
		cfg.targetUserId = rawTarget
	elseif type(rawTarget) == "string" and rawTarget ~= "" then
		cfg.targetUserId = tonumber(rawTarget)
	else
		cfg.targetUserId = nil
	end

	cfg.targetName = (type(config.targetName) == "string") and config.targetName or ""
	cfg.quirk = (type(config.quirk) == "string") and config.quirk or ""
	cfg.maxUnits = math.clamp(tonumber(config.maxUnits) or cfg.maxUnits or MAX_UNITS, 1, MAX_UNITS)
	cfg.autoAccept = (type(config.autoAccept) == "boolean") and config.autoAccept or cfg.autoAccept
	cfg.autoReady = (type(config.autoReady) == "boolean") and config.autoReady or cfg.autoReady
	cfg.rev = config.rev

	session.appliedRev = config.rev
	session.sessionDone = false -- user menekan Start/Save lagi: sesi baru boleh mulai
	session.cancelSent = false
	session.lastError = nil
	session.pendingRequest = false
	session.pendingUntil = 0
	session.notRegistered = false

	-- Target berganti / Stop saat trade berjalan: batalkan sekali, mulai bersih.
	if session.tradeActive and (cfg.targetUserId ~= oldTarget or not cfg.running) then
		session.suppressEnded += 1
		fireSignal(CancelTrade, "CancelTrade")
		resetTrade()
	end

	if not cfg.running then
		session.state = "idle"
	elseif not session.tradeActive then
		session.state = "idle"
	end
	log("config applied (rev " .. tostring(config.rev) .. ")")
	return true
end

--// Pull config dari edge function \\--
local function pull()
	if not TRADE_REMOTE.ENABLED then
		return false, "disabled"
	end
	local ok, code, raw = httpPostJson(TRADE_REMOTE.URL, {
		action = "pull",
		userId = LocalPlayer.UserId,
	})
	session.lastPullAt = os.clock()
	if not ok then
		noteRemoteFailure(code, raw)
		return false, code
	end
	local okDec, decoded = pcall(function()
		return HttpService:JSONDecode(raw or "{}")
	end)
	if not okDec or type(decoded) ~= "table" then
		return false, "JSONDecode gagal"
	end
	if decoded.ok ~= true then
		return false, "ok=false"
	end
	if type(decoded.config) == "table" then
		applyConfig(decoded.config)
	end
	return true, code
end

--// Tick state machine (0.25 s) \\--
local function tickBody()
	-- a. tidak running -> idle, batalkan trade sekali
	if not session.running then
		if session.tradeActive then
			if not session.cancelSent then
				session.cancelSent = true
				session.suppressEnded += 1
				fireSignal(CancelTrade, "CancelTrade")
				log("cancel (tidak running)")
			end
			resetTrade()
		end
		session.pendingRequest = false
		session.pendingUntil = 0
		session.state = "idle"
		return
	end

	-- i. sesi selesai: jangan mulai trade baru sampai rev berubah
	if session.sessionDone then
		-- Pertahankan "error" kalau sesi berakhir karena masalah (mis. tanpa unit
		-- yang cocok), supaya dashboard tidak menampilkan "done" seolah sukses.
		session.state = session.lastError and "error" or "done"
		return
	end

	-- f/g/h. trade aktif
	if session.tradeActive then
		session.state = "in_trade"
		local now = os.clock()
		local observed = countKeys(session.ownOffer)
		session.offered = observed

		-- g. verifikasi ownOffer: penuh, atau timeout 8 s dengan minimal 1 unit
		if not session.offersComplete then
			if observed >= session.desired then
				session.offersComplete = true
				if not session.offersConfirmed and session.desired > 0 then
					session.offersConfirmed = true
					log(string.format("offers confirmed %d/%d", observed, session.desired))
				end
			elseif session.offerStartedAt > 0
				and now - session.offerStartedAt >= TRADE_REMOTE.OFFER_TIMEOUT
			then
				if observed >= 1 or session.desired == 0 then
					session.offersComplete = true
					session.stopOffering = true
					log(string.format("offer timeout (%d/%d) -> lanjut", observed, session.desired))
				end
			end
		end

		if session.phase == "Offer" then
			-- h. Ready sekali per phase, hanya setelah offer selesai.
			-- Flag hanya "latch" kalau fire berhasil; kalau gagal, coba lagi
			-- maksimal tiap 2 s (bukan tiap tick) supaya tidak spam.
			if session.offersComplete
				and not session.offering
				and session.cfg.autoReady
				and not session.ownReady
				and not session.readyFired
				and (now - session.lastAdvanceTryAt) >= 2
			then
				session.lastAdvanceTryAt = now
				if fireSignal(AdvanceTrade, "AdvanceTrade") then
					session.readyFired = true
					log("ready")
				end
			end
		elseif session.phase == "Confirm" then
			-- h. Accept sekali, setelah jeda 0.6 s
			if session.confirmAt == 0 then
				session.confirmAt = now
			end
			if session.cfg.autoReady
				and not session.ownAccepted
				and not session.acceptedFired
				and now - session.confirmAt >= TRADE_REMOTE.ACCEPT_DELAY
				and (now - session.lastAdvanceTryAt) >= 2
			then
				session.lastAdvanceTryAt = now
				if fireSignal(AdvanceTrade, "AdvanceTrade") then
					session.acceptedFired = true
					log("accepted")
				end
			end
		end
		-- Countdown/Saving: tidak ada aksi, hanya dilaporkan.
		return
	end

	-- b. resolusi target (mahal? tidak: GetPlayerByUserId murah, tiap tick)
	local targetUserId = session.cfg.targetUserId
	if type(targetUserId) ~= "number" then
		session.state = "waiting_target"
		session.lastError = nil
		return
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then
		session.state = "waiting_target"
		session.lastError = nil
		return
	end
	session.targetDisplay = displayName(target)

	-- c. pastikan trade request kita menyala
	local requestsEnabled = readTradeRequestsEnabled()
	if requestsEnabled == false and (os.clock() - session.lastEnableAt) >= 5 then
		session.lastEnableAt = os.clock()
		if fireSignal(SetTradeRequestsEnabled, "SetTradeRequestsEnabled", true) then
			log("trade requests diaktifkan")
		end
	end

	-- e. tunggu request yang masih pending
	if session.pendingRequest then
		if os.clock() < session.pendingUntil then
			session.state = "request_sent"
			return
		end
		session.pendingRequest = false
		session.pendingUntil = 0
		session.state = "idle"
	end

	-- e. kirim request baru, maksimal sekali per 8 s
	if (os.clock() - session.lastRequestAt) >= TRADE_REMOTE.RETRY_EVERY then
		session.lastRequestAt = os.clock()
		session.pendingRequest = true
		session.pendingUntil = os.clock() + TRADE_REMOTE.PENDING_TTL
		session.state = "request_sent"
		if fireSignal(RequestTrade, "RequestTrade", target) then
			session.lastError = nil
			log("request sent to " .. displayName(target))
		end
	else
		session.state = "idle"
	end
end

--// Lifecycle lokal \\--
local function start()
	session.running = true
	session.cfg.running = true
	session.sessionDone = false
	session.cancelSent = false
	session.lastError = nil
	if not session.tradeActive then
		session.state = "idle"
	end
	log("start (lokal)")
	return true
end

local function stop()
	local wasActive = session.tradeActive
	session.running = false
	session.cfg.running = false
	session.sessionDone = false
	session.pendingRequest = false
	session.pendingUntil = 0
	if wasActive and not session.cancelSent then
		session.cancelSent = true
		session.suppressEnded += 1
		fireSignal(CancelTrade, "CancelTrade")
	end
	resetTrade()
	session.state = "idle"
	log("stop (lokal)")
	return true
end

--// Loop tick \\--
local function startTradeLoop()
	task.spawn(function()
		task.wait(0.25)
		while runGen == ENV.__tradeAutoGen do
			local ok, err = pcall(tickBody)
			if not ok then
				setError(err)
				log(tostring(err))
				if not session.tradeActive then
					session.state = "error"
				end
			end
			task.wait(0.25)
		end
	end)
end

-- Loop remote: pull tiap 15 s, push status tiap 30 s (pull pertama langsung).
local function startRemoteLoop()
	task.spawn(function()
		local pullElapsed = TRADE_REMOTE.POLL
		local pushElapsed = TRADE_REMOTE.STATUS_EVERY
		local failStreak = 0
		while runGen == ENV.__tradeAutoGen do
			if pullElapsed >= TRADE_REMOTE.POLL then
				pullElapsed = 0
				local okCall, ok, code = pcall(pull)
				if not okCall then
					ok, code = false, "pull error"
				end
				if ok then
					if failStreak >= 5 then
						log("remote tersambung kembali setelah " .. failStreak .. " gagal")
					end
					failStreak = 0
				else
					failStreak += 1
					if failStreak % 5 == 0 then
						log("WARN: pull gagal " .. failStreak .. "x (" .. tostring(code) .. ")")
					end
				end
			end
			if pushElapsed >= TRADE_REMOTE.STATUS_EVERY then
				pushElapsed = 0
				pcall(pushStatus)
			end
			task.wait(1)
			pullElapsed += 1
			pushElapsed += 1
		end
	end)
end

--// API publik \\--
ENV.tradeAuto = {
	start = start,
	stop = stop,
	state = session,
	pushStatus = pushStatus,
	pull = pull,
}

--// Jalur load \\--
log("remote " .. (TRADE_REMOTE.ENABLED and "ON" or "OFF") .. " (poll 15s, status 30s, open channel)")
if not comm then
	log("WARN: Network.ClientComm tidak tersedia - remote trade tidak bisa dipakai")
end
startTradeLoop()
startRemoteLoop()
