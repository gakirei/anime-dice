--// Anime Dice — All-in-One \\--
-- Tutorial (1→14) → pasca-tutorial (AutoSell=1qd, Perf ON, Music=0, HideGears ON)
-- → perf optimizer → Auto Roll → farm sampai Rolls >= 1000 (unlock Trade).
-- Remote resmi saja. Idempotent, self-healing, re-run = restart (tidak menumpuk).
--
-- Usage: loadstring(readfile("anime-dice-all-in-one.luau"))()
-- Stop  : getgenv().animeDiceAllInOne.stop()
-- Test  : getgenv().animeDiceAllInOne.notify(true)  -- kirim webhook percobaan ke Discord
-- Note  : Rolls >= 1000 → notifikasi Discord; Rolls >= 1001 → disconnect dari game
-- Guard : cek PlaceId (113290951185459) / struktur game; abort kalau bukan Anime Dice

local TARGET_ROLLS = 1000 -- TradeConfig.MIN_ROLLS

--// Services & modules \\--
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")

--// Game guard: pastikan ini Anime Dice SEBELUM apa pun yang bisa hang/error \\--
local EXPECTED_PLACE_ID = 113290951185459

local function detectAnimeDice()
	if game.PlaceId == EXPECTED_PLACE_ID then
		return true, "PlaceId"
	end
	-- fallback struktural (kalau place di-republish / PlaceId berubah)
	local fw = RS:FindFirstChild("Framework")
	if fw and RS:FindFirstChild("Network") and fw:FindFirstChild("Features") and fw.Features:FindFirstChild("Data") then
		return true, "struktur"
	end
	return false, "tidak ada tanda-tanda Anime Dice"
end

local okGame, gameWhy = detectAnimeDice()
if not okGame then
	warn(("[aio] ABORT: bukan Anime Dice (PlaceId=%s, name=%s) — %s. Script tidak dijalankan.")
		:format(tostring(game.PlaceId), tostring(game.Name), tostring(gameWhy)))
	return
end
print(("[aio] game ok (deteksi: %s)"):format(tostring(gameWhy)))

local LocalPlayer = Players.LocalPlayer

local NET = RS:WaitForChild("Network", 30)
if not NET then
	warn("[aio] ABORT: Network tidak ketemu setelah 30s — game belum termuat?")
	return
end

local okDC, DC = pcall(function()
	return require(RS.Framework.Features.Data.DataController)
end)
if not okDC then
	warn("[aio] ABORT: DataController gagal dimuat — " .. tostring(DC))
	return
end

local okER, EntryRegistry = pcall(function()
	return require(RS.Framework.Features.Inventory.EntryRegistry)
end)
if not okER then
	warn("[aio] ABORT: EntryRegistry gagal dimuat — " .. tostring(EntryRegistry))
	return
end

--// Remotes (struktur FLAT: Network.<Service>.RE|RF.<Signal>) \\--
local RF_RollDice = NET:WaitForChild("RollService"):WaitForChild("RF"):WaitForChild("RollDice")
local RE_SetAutoRoll = NET:WaitForChild("RollService"):WaitForChild("RE"):WaitForChild("SetAutoRoll")
local RE_Advance = NET:WaitForChild("OnboardingService"):WaitForChild("RE"):WaitForChild("Advance")
local RF_Equip = NET:WaitForChild("UnitService"):WaitForChild("RF"):WaitForChild("Equip")
local RE_InteractSlot = NET:WaitForChild("PlotService"):WaitForChild("RE"):WaitForChild("InteractSlot")
local RE_Collect = NET:WaitForChild("PlotService"):WaitForChild("RE"):WaitForChild("CollectBalance")
local RE_BuyDice = NET:WaitForChild("DiceShopService"):WaitForChild("RE"):WaitForChild("BuyDice")
local RE_SetSetting = NET:WaitForChild("SettingsService"):WaitForChild("RE"):WaitForChild("SetSetting")

--// Config \\--
local DICE_NAME = "Normal"
local SLOT = 1
local AUTO_SELL_TARGET = 1e15 -- 1qd
local FORCED = { [2] = true, [9] = true, [10] = true, [13] = true }

-- Discord webhook: dikirim sekali saat Rolls mencapai TARGET_ROLLS
local WEBHOOK_ENABLED = true
local DISCORD_WEBHOOK = "https://discord.com/api/webhooks/1422109131006808156/FzTcL84FAs4hfeBXUXnEad0RQrWXiVzd8bZwlqnc2IKq-W1zVZVFIhP66IPJi1yuhkR8"

-- Disconnect client saat target tercapai (1001 = lewat 1000, supaya server pasti mencatat)
local LEAVE_ON_TARGET = true
local LEAVE_AFTER_ROLLS = TARGET_ROLLS + 1

local ZONES_OK, ZONES_SHOP, ZONES_DICE = pcall(function()
	return true, Workspace.Zones.ShopArea.Position, Workspace.Zones.DiceShop.Position
end)
if not ZONES_OK then
	ZONES_SHOP = Vector3.new(285.52, 4.04, -272.57)
	ZONES_DICE = Vector3.new(285.48, 10.97, -304.35)
end

--// State readers (pcall-safe; aksesor langsung pola DataController) \\--
local function readNum(fn)
	local ok, v = pcall(fn)
	return ok and tonumber(v) or nil
end

local function stepNow()
	return readNum(function()
		return DC.OnboardingStep()
	end) or -1
end

local function rollsNow()
	local v = readNum(function()
		return DC.Rolls()
	end)
	if v then
		return v
	end
	-- fallback: leaderstats
	return readNum(function()
		return LocalPlayer.leaderstats.Rolls.Value
	end) or 0
end

local function moneyNow()
	return readNum(function()
		return DC.Money()
	end) or 0
end

local function autoRollNow()
	local ok, v = pcall(function()
		return DC.AutoRoll()
	end)
	return ok and v == true
end

local function ownNormal()
	local ok, v = pcall(function()
		return DC.OwnedDice[DICE_NAME]()
	end)
	return ok and v == true
end

local function firstUnitKey()
	local ok, inv = pcall(function()
		return DC.Inventory()
	end)
	if not ok or type(inv) ~= "table" then
		return nil
	end
	for key, entry in inv do
		local cfg = EntryRegistry.getEntryConfig(entry.name)
		if cfg and cfg.kind == "Unit" then
			return key, entry.name
		end
	end
	return nil
end

local function slotBalance()
	return readNum(function()
		local s = DC.Slots()[tostring(SLOT)]
		return s and s.balance
	end) or 0
end

local function charRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function safe(fn, ...)
	pcall(fn, ...)
end

-- HTTP POST lintas-executor (request/http_request/syn/fluxus/krnl/HttpService) untuk Discord
local function httpPost(url, payload)
	local okEnc, body = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not okEnc then
		return false, "JSONEncode: " .. tostring(body)
	end

	local env = (type(getgenv) == "function") and getgenv() or _G
	local candidates = {}
	local function add(name, f)
		if type(f) == "function" then
			table.insert(candidates, { name = name, fn = f })
		end
	end
	for _, n in ipairs({ "request", "http_request", "http_post", "HttpPost", "httpRequest" }) do
		add(n, env[n])
		if env ~= _G then
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

local function notifyTradeReady(rolls, isTest)
	local acc = LocalPlayer
	local payload = {
		username = "Anime Dice Auto-Farm",
		embeds = {
			{
				title = (isTest and "[TEST] " or "") .. "Rolls target reached",
				description = ("**%s** reached **%d / %d** rolls (Trade roll-gate)."):format(acc.Name, rolls, TARGET_ROLLS),
				color = isTest and 8421504 or 5763719,
				fields = {
					{ name = "Account", value = tostring(acc.Name), inline = true },
					{ name = "Display name", value = tostring(acc.DisplayName), inline = true },
					{ name = "User ID", value = tostring(acc.UserId), inline = true },
					{ name = "Rolls", value = ("%d / %d"):format(rolls, TARGET_ROLLS), inline = true },
					{ name = "Account age", value = tostring(acc.AccountAge) .. " days", inline = true },
					{ name = "Money", value = tostring(moneyNow()), inline = true },
					{ name = "Place ID", value = tostring(game.PlaceId), inline = true },
					{ name = "Job ID", value = tostring(game.JobId), inline = true },
				},
				timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			},
		},
	}
	local ok, info = httpPost(DISCORD_WEBHOOK, payload)
	print(("[aio] discord webhook %s: %s"):format(ok and "OK" or "GAGAL", tostring(info)))
	return ok, info
end

-- Keluar dari game (disconnect). game:Shutdown() = metode standar; fallback ke global executor.
local function leaveGame()
	local env = (type(getgenv) == "function") and getgenv() or _G
	local attempts = {}
	for _, n in ipairs({ "leaveGame", "leave", "exitgame", "Exit" }) do
		if type(env[n]) == "function" then
			table.insert(attempts, { name = n, fn = env[n] })
		end
	end
	table.insert(attempts, { name = "game:Shutdown", fn = function()
		game:Shutdown()
	end })
	table.insert(attempts, { name = "LocalPlayer:Kick", fn = function()
		LocalPlayer:Kick("[aio] target reached")
	end })
	for _, a in ipairs(attempts) do
		local ok, err = pcall(a.fn)
		print(("[aio] leave via %s -> %s"):format(a.name, ok and "ok" or tostring(err)))
		if ok then
			return true, a.name
		end
	end
	return false
end

local function teleportTo(pos)
	local r = charRoot()
	if not r then
		return
	end
	if (r.Position - pos).Magnitude < 8 then
		return -- sudah di tempat, jangan jitter
	end
	pcall(function()
		LocalPlayer.Character:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)))
	end)
end

--// PERF OPTIMIZER (inline, dari anime-dice-perf.luau yang sudah teruji) \\--
do
	local ENV = (type(getgenv) == "function") and getgenv() or _G
	if type(ENV.animeDicePerf) == "table" and type(ENV.animeDicePerf.stop) == "function" then
		pcall(ENV.animeDicePerf.stop)
	end
	if not ENV.__animeDicePerfLoaded then
		ENV.__animeDicePerfLoaded = true

		local CFG = {
			qualityLevel = Enum.QualityLevel.Level01,
			fixQuality = false,
			fpsCap = 30,
			globalShadows = false,
			environmentScale = 0,
			disablePostFx = true,
			disableAtmosphere = false,
			streamEnabled = true,
			streamTargetRadius = 384,
			streamMinRadius = 64,
			streamOutBehavior = Enum.StreamOutBehavior.Opportunistic,
			killLights = true,
			killParticles = true,
			destroyBeamsTrails = true,
			destroyLegacyFx = true,
			enableGameToggles = false, -- toggle diapply oleh flow utama (applyPostTutorial)
			cullGuiDistance = 160,
			freezeAnimations = true,
			freezeDistance = 160,
			reapplySeconds = 5,
			sweepSeconds = 3,
		}

		local function plog(...)
			print("[perf]", ...)
		end
		local function try(label, fn)
			local ok, err = pcall(fn)
			if not ok then
				plog(("gagal %s: %s"):format(label, tostring(err)))
			end
			return ok
		end
		local function posOf(inst)
			if not inst then
				return nil
			end
			local ok, p = pcall(function()
				if inst:IsA("PVInstance") then
					return inst:GetPivot().Position
				end
				return nil
			end)
			return ok and p or nil
		end

		local lastQuality = nil
		local function applyRender()
			local okQ, curQ = pcall(function()
				return settings().Rendering.QualityLevel
			end)
			local cur = okQ and tostring(curQ) or "ERR"
			if not (okQ and curQ == CFG.qualityLevel) then
				try("QualityLevel", function()
					settings().Rendering.QualityLevel = CFG.qualityLevel
				end)
				if CFG.fixQuality then
					try("EnableFRM=false", function()
						settings().Rendering.EnableFRM = false
					end)
				end
			end
			if cur ~= lastQuality then
				lastQuality = cur
				plog(("QualityLevel = %s (ingin %s)"):format(cur, tostring(CFG.qualityLevel)))
			end
			try("GlobalShadows", function()
				Lighting.GlobalShadows = CFG.globalShadows
			end)
			try("EnvironmentScale", function()
				Lighting.EnvironmentDiffuseScale = CFG.environmentScale
				Lighting.EnvironmentSpecularScale = CFG.environmentScale
			end)
			if CFG.disablePostFx then
				for _, e in Lighting:GetChildren() do
					if e:IsA("PostEffect") or e:IsA("SunRaysEffect") then
						try("disable " .. e.ClassName, function()
							e.Enabled = false
						end)
					end
				end
			end
		end

		local function applyFpsCap()
			if not CFG.fpsCap or CFG.fpsCap <= 0 then
				return
			end
			local cap = CFG.fpsCap
			local candidates = {}
			if type(debug) == "table" and type(debug.setfpscap) == "function" then
				table.insert(candidates, { name = "debug.setfpscap", fn = function()
					debug.setfpscap(cap)
				end })
			end
			for _, env in { (pcall(getgenv) and getgenv() or _G), _G } do
				for _, name in { "setfpscap", "setFpsCap", "set_fps_cap" } do
					local f = env[name]
					if type(f) == "function" then
						table.insert(candidates, { name = name, fn = function()
							f(cap)
						end })
					end
				end
			end
			for _, c in candidates do
				if try("fpsCap via " .. c.name, c.fn) then
					return
				end
			end
		end

		local function applyStreaming()
			local available = pcall(function()
				return Workspace.StreamingTargetRadius
			end)
			if not available then
				return
			end
			try("StreamOutBehavior", function()
				Workspace.StreamOutBehavior = CFG.streamOutBehavior
			end)
			try("StreamingMinRadius", function()
				Workspace.StreamingMinRadius = CFG.streamMinRadius
			end)
			try("StreamingTargetRadius", function()
				Workspace.StreamingTargetRadius = CFG.streamTargetRadius
			end)
			try("ModelStreamingBehavior", function()
				if Enum.ModelStreamingBehavior and Enum.ModelStreamingBehavior.Improved then
					Workspace.ModelStreamingBehavior = Enum.ModelStreamingBehavior.Improved
				end
			end)
		end

		local guis, animators = {}, {}
		local function destroyLater(inst)
			task.defer(function()
				if inst.Parent then
					safe(function()
						inst:Destroy()
					end)
				end
			end)
		end
		local function onAdded(d)
			if CFG.killLights and d:IsA("Light") then
				safe(function()
					d.Enabled = false
				end)
			elseif CFG.killParticles and d:IsA("ParticleEmitter") then
				safe(function()
					d.Enabled = false
					d:Clear()
				end)
			elseif CFG.destroyBeamsTrails and (d:IsA("Beam") or d:IsA("Trail")) then
				destroyLater(d)
			elseif CFG.destroyLegacyFx and (d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles")) then
				destroyLater(d)
			end
			local cn = d.ClassName
			if cn == "BillboardGui" or cn == "SurfaceGui" then
				table.insert(guis, d)
			elseif CFG.freezeAnimations and d:IsA("Animator") then
				table.insert(animators, d)
			end
		end

		task.spawn(function()
			local RUNNING = true
			applyFpsCap()
			pcall(function()
				for _, d in Workspace:GetDescendants() do
					onAdded(d)
				end
			end)
			applyRender()
			applyStreaming()
			Workspace.DescendantAdded:Connect(onAdded)
			task.spawn(function()
				while RUNNING do
					applyRender()
					task.wait(CFG.reapplySeconds)
				end
			end)
			task.spawn(function()
				while RUNNING do
					local hrp = charRoot()
					local p = hrp and hrp.Position
					if p then
						for i = #guis, 1, -1 do
							local g = guis[i]
							if not g.Parent then
								table.remove(guis, i)
							else
								local gp = posOf(g.Adornee or g.Parent)
								if gp then
									local want = (gp - p).Magnitude <= CFG.cullGuiDistance
									if g.Enabled ~= want then
										safe(function()
											g.Enabled = want
										end)
									end
								end
							end
						end
						for i = #animators, 1, -1 do
							local a = animators[i]
							if not a.Parent then
								table.remove(animators, i)
							else
								local mp = posOf(a:FindFirstAncestorOfClass("Model"))
								if mp then
									local speed = ((mp - p).Magnitude > CFG.freezeDistance) and 0 or 1
									safe(function()
										for _, track in a:GetPlayingAnimationTracks() do
											track:AdjustSpeed(speed)
										end
									end)
								end
							end
						end
					end
					task.wait(CFG.sweepSeconds)
				end
			end)
			ENV.animeDicePerf = {
				config = CFG,
				stop = function()
					RUNNING = false
					ENV.__animeDicePerfLoaded = nil
				end,
			}
			plog("aktif (all-in-one)")
		end)
	end
end

--// MAIN FLOW \\--
local PHASE = "TUTORIAL"
local lastFire = {} -- throttle aksi per step
local lastLog = 0
local RUNNING = true
local ENV = (type(getgenv) == "function") and getgenv() or _G

-- guard terhadap instance all-in-one lama
if type(ENV.animeDiceAllInOne) == "table" and type(ENV.animeDiceAllInOne.stop) == "function" then
	pcall(ENV.animeDiceAllInOne.stop)
end
ENV.animeDiceAllInOne = {
	stop = function()
		RUNNING = false
	end,
	notify = function(isTest)
		return notifyTradeReady(rollsNow(), isTest == true)
	end,
	leave = function()
		return leaveGame()
	end,
	webhookUrl = DISCORD_WEBHOOK,
}

local function throttle(step, interval)
	local now = os.clock()
	if (lastFire[step] or 0) + (interval or 0.8) <= now then
		lastFire[step] = now
		return true
	end
	return false
end

local function applyPostTutorial()
	safe(function()
		RE_SetSetting:FireServer("AutoSell", AUTO_SELL_TARGET)
	end)
	safe(function()
		RE_SetSetting:FireServer("Performance", true)
	end)
	safe(function()
		RE_SetSetting:FireServer("Music", 0)
	end)
	safe(function()
		RE_SetSetting:FireServer("HideGears", true)
	end)
end

local function stepAction(step)
	-- aksi per step (pola persis tutorial teruji); throttle agar tidak spam remote
	if FORCED[step] then
		if throttle(step, 0.9) then
			safe(function()
				RE_Advance:FireServer()
			end)
		end
		return
	end

	if step == 1 then
		if firstUnitKey() == nil and throttle(step, 1.2) then
			safe(function()
				RF_RollDice:InvokeServer()
			end)
		end
	elseif step == 3 then
		local key = firstUnitKey()
		if key and throttle(step, 1.0) then
			safe(function()
				RF_Equip:InvokeServer(key)
			end)
		end
	elseif step == 4 then
		if throttle(step, 1.2) then
			safe(function()
				RE_InteractSlot:FireServer(SLOT)
			end)
		end
	elseif step == 5 then
		if slotBalance() > 0 and throttle(step, 1.0) then
			safe(function()
				RE_Collect:FireServer(SLOT)
			end)
		end
	elseif step == 6 then
		teleportTo(ZONES_SHOP)
	elseif step == 7 then
		teleportTo(ZONES_DICE)
	elseif step == 8 then
		if not ownNormal() and moneyNow() >= 1 and throttle(step, 1.5) then
			safe(function()
				RE_BuyDice:FireServer(DICE_NAME)
			end)
		elseif slotBalance() > 0 and throttle(step, 1.0) then
			safe(function()
				RE_Collect:FireServer(SLOT)
			end)
		end
	elseif step == 11 then
		if throttle(step, 1.2) then
			safe(function()
				RF_RollDice:InvokeServer()
			end)
		end
	elseif step == 12 then
		if not autoRollNow() and throttle(step, 1.0) then
			safe(function()
				RE_SetAutoRoll:FireServer(true)
			end)
		end
	end
end

task.spawn(function()
	while RUNNING do
		local now = os.clock()
		local ok, step = pcall(stepNow)
		step = ok and step or -1

		if PHASE == "TUTORIAL" then
			if step >= 14 then
				PHASE = "POST"
				lastLog = 0
			else
				stepAction(step)
				if now - lastLog > 2 then
					lastLog = now
					print(("[aio] TUTORIAL step=%d | Rolls=%d Money=%d"):format(step, rollsNow(), moneyNow()))
				end
			end

		elseif PHASE == "POST" then
			applyPostTutorial()
			PHASE = "FARM"
			print("[aio] pasca-tutorial: AutoSell=1qd Perf=ON Music=0 HideGears=ON -> FARM")

		elseif PHASE == "FARM" then
			local r = rollsNow()
			if r >= TARGET_ROLLS then
				PHASE = "DONE"
				print(("[aio] DONE — Rolls=%d >= %d, Trade UNLOCKED"):format(r, TARGET_ROLLS))
				if WEBHOOK_ENABLED and not ENV.__aioNotified then
					ENV.__aioNotified = true
					task.spawn(function()
						notifyTradeReady(r, false)
					end)
				end
				lastLog = 0
			else
				-- pastikan Auto Roll tetap nyala
				if not autoRollNow() and throttle(999, 10) then
					safe(function()
						RE_SetAutoRoll:FireServer(true)
					end)
				end
				if now - lastLog > 5 then
					lastLog = now
					print(("[aio] FARM %d/%d | AutoRoll=%s Money=%d"):format(r, TARGET_ROLLS, tostring(autoRollNow()), moneyNow()))
				end
				task.wait(2)
			end

		elseif PHASE == "DONE" then
			local r2 = rollsNow()
			if LEAVE_ON_TARGET and r2 >= LEAVE_AFTER_ROLLS then
				print(("[aio] Rolls=%d >= %d — keluar dari game (disconnect)"):format(r2, LEAVE_AFTER_ROLLS))
				task.wait(2) -- beri waktu webhook terkirim
				leaveGame()
				RUNNING = false
				return
			end
			if not autoRollNow() and throttle(999, 15) then
				safe(function()
					RE_SetAutoRoll:FireServer(true)
				end)
			end
			if now - lastLog > 15 then
				lastLog = now
				print(("[aio] IDLE — Rolls=%d/%d (menunggu %d utk disconnect)"):format(r2, TARGET_ROLLS, LEAVE_AFTER_ROLLS))
			end
			task.wait(5)
		end

		task.wait(0.3)
	end
	print("[aio] dihentikan")
end)

print(("[aio] mulai — target Rolls >= %d (Trade unlock; butuh akun >= 14 hari)"):format(TARGET_ROLLS))
