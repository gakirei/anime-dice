--// Anime Dice — All-in-One (Tutorial → AutoRoll → Reach 1000 Total Rolls) \\--
-- Does: complete tutorial (1→14), apply post-tutorial (AutoSell=1qd, Performance ON),
--       spawn aggressive perf optimizer in background, enable Auto Roll, farm until
--       total Rolls >= TARGET_ROLLS (default 1000) to unlock Trade.
-- All changes are client-side, official remotes only. Idempotent + self-healing.
--
-- Usage: loadstring(readfile("anime-dice-all-in-one.luau"))()

local TARGET_ROLLS = 1000

--// Services \\--
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

--// Remotes / Modules \\--
local Network = ReplicatedStorage:WaitForChild("Network")
local RollService = Network:WaitForChild("Rolling"):WaitForChild("RollService")
local RF_RollDice = RollService:WaitForChild("RF"):WaitForChild("RollDice")
local RE_SetAutoRoll = RollService:WaitForChild("RE"):WaitForChild("SetAutoRoll")

local OnboardingService = Network:WaitForChild("Onboarding"):WaitForChild("OnboardingService")
local RE_Advance = OnboardingService:WaitForChild("RE"):WaitForChild("Advance")

local UnitService = Network:WaitForChild("Units"):WaitForChild("UnitService")
local RF_Equip = UnitService:WaitForChild("RF"):WaitForChild("Equip")

local PlotService = Network:WaitForChild("Plots"):WaitForChild("PlotService")
local RE_InteractSlot = PlotService:WaitForChild("RE"):WaitForChild("InteractSlot")
local RE_CollectBalance = PlotService:WaitForChild("RE"):WaitForChild("CollectBalance")

local DiceShopService = Network:WaitForChild("Shops"):WaitForChild("DiceShopService")
local RE_BuyDice = DiceShopService:WaitForChild("RE"):WaitForChild("BuyDice")

local SettingsService = Network:WaitForChild("SettingsService")
local RE_SetSetting = SettingsService:WaitForChild("RE"):WaitForChild("SetSetting")

-- Data controller (for read-only state)
local DataFolder = ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Features"):WaitForChild("Data")
local DataController = require(DataFolder:WaitForChild("DataController"))

--// State helpers \\--
local function getState()
	local ok, s = pcall(function()
		return DataController:GetState()
	end)
	if ok and type(s) == "table" then
		return s
	end
	return {}
end

local function charPos()
	local c = LocalPlayer.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp.Position
	end
	return Vector3.new(0, 0, 0)
end

local function teleportTo(p)
	local c = LocalPlayer.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CFrame = CFrame.new(p + Vector3.new(0, 3, 0))
	end
end

local function hasNormalDice()
	local st = getState()
	local od = st.OwnedDice or {}
	return od.Normal == true
end

local function rollsTotal()
	local st = getState()
	local r = st.Rolls
	if type(r) == "number" then
		return r
	end
	return 0
end

local function onboardingStep()
	local st = getState()
	local v = st.OnboardingStep
	if type(v) == "number" then
		return v
	end
	return 0
end

local function money()
	local st = getState()
	local m = st.Money
	if type(m) == "number" then
		return m
	end
	return 0
end

local function autoRollOn()
	local st = getState()
	local ar = st.AutoRoll
	if type(ar) == "boolean" then
		return ar
	end
	return false
end

local function equipNormal()
	pcall(function()
		RF_Equip:InvokeServer("Normal")
	end)
end

local function buyNormal()
	pcall(function()
		RE_BuyDice:FireServer("Normal")
	end)
end

local function rollOnce()
	pcall(function()
		RF_RollDice:InvokeServer()
	end)
end

local function setAutoRoll(v)
	pcall(function()
		RE_SetAutoRoll:FireServer(v)
	end)
end

local function advance()
	pcall(function()
		RE_Advance:FireServer()
	end)
end

local function interactSlot1()
	pcall(function()
		RE_InteractSlot:FireServer(1)
	end)
end

local function collectSlot1()
	pcall(function()
		RE_CollectBalance:FireServer(1)
	end)
end

local function applyPostTutorial()
	pcall(function()
		RE_SetSetting:FireServer("AutoSell", 1000000000000000)
	end)
	pcall(function()
		RE_SetSetting:FireServer("Performance", true)
	end)
	pcall(function()
		RE_SetSetting:FireServer("Music", 0)
	end)
	pcall(function()
		RE_SetSetting:FireServer("HideGears", true)
	end)
end

-- Zones
local Z_SHOP_AREA = Vector3.new(285.52, 4.04, -272.57)
local Z_DICE_SHOP = Vector3.new(285.48, 10.97, -304.35)

-- Tutorial reconcile
local function reconcile()
	local st = getState()
	local step = onboardingStep()
	local ok = true

	if step == 1 then
		if st.Units and st.Units.Normal then
			ok = false
		end
	elseif step == 3 then
		if st.Equipped and st.Equipped == "Normal" then
			ok = false
		end
	elseif step == 4 then
		local slots = st.Slots or {}
		if slots[1] and slots[1].Unit and slots[1].Unit.Key == "Normal" then
			ok = false
		end
	elseif step == 5 then
		if money() > 0 then
			ok = false
		end
	elseif step == 6 then
		local p = charPos()
		if (p - Z_SHOP_AREA).Magnitude < 6 then
			ok = false
		end
	elseif step == 7 then
		local p = charPos()
		if (p - Z_DICE_SHOP).Magnitude < 15 then
			ok = false
		end
	elseif step == 8 then
		if hasNormalDice() then
			ok = false
		end
	elseif step == 11 then
		if rollsTotal() > 1 then
			ok = false
		end
	elseif step == 12 then
		if autoRollOn() then
			ok = false
		end
	end
	return ok
end

local forced = { [2] = true, [9] = true, [10] = true, [13] = true }

--// PERF OPTIMIZER (inlined, safe, with stop API + self-replace) \\--
do
	local ENV = (type(getgenv) == "function") and getgenv() or _G
	if type(ENV.animeDicePerf) == "table" and type(ENV.animeDicePerf.stop) == "function" then
		pcall(ENV.animeDicePerf.stop)
	end
	if ENV.__animeDicePerfLoaded then
		-- already loaded; don't spawn duplicate loops here
	else
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
			gameMusicVolume = 0,
			enableGameToggles = false, -- we apply toggles ourselves in main flow
			cullGuiDistance = 160,
			freezeAnimations = true,
			freezeDistance = 160,
			reapplySeconds = 5,
			sweepSeconds = 3,
		}

		local OVERRIDE = (type(ENV.__animeDicePerfConfig) == "table") and ENV.__animeDicePerfConfig or nil
		if OVERRIDE then
			for k, v in pairs(OVERRIDE) do
				if CFG[k] ~= nil then
					CFG[k] = v
				end
			end
		end

		local function log(...)
			print("[perf]", ...)
		end
		local function try(label, fn)
			local ok, err = pcall(fn)
			if not ok then
				log(("gagal %s: %s"):format(label, tostring(err)))
			end
			return ok
		end
		local function root()
			local c = LocalPlayer.Character
			return c and c:FindFirstChild("HumanoidRootPart")
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
				log(("QualityLevel = %s (ingin %s)"):format(cur, tostring(CFG.qualityLevel)))
			end
			if CFG.globalShadows ~= nil then
				try("GlobalShadows", function()
					Lighting.GlobalShadows = CFG.globalShadows
				end)
			end
			if CFG.environmentScale then
				try("EnvironmentScale", function()
					Lighting.EnvironmentDiffuseScale = CFG.environmentScale
					Lighting.EnvironmentSpecularScale = CFG.environmentScale
				end)
			end
			if CFG.disablePostFx then
				for _, e in Lighting:GetChildren() do
					if e:IsA("PostEffect") or e:IsA("SunRaysEffect") then
						try("disable " .. e.ClassName, function()
							e.Enabled = false
						end)
					end
				end
			end
			if CFG.disableAtmosphere then
				local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
				if atmo then
					try("destroy Atmosphere", function()
						atmo:Destroy()
					end)
				end
			end
		end

		local function applyFpsCap()
			if not CFG.fpsCap or CFG.fpsCap <= 0 then
				return
			end
			local cap = CFG.fpsCap
			local candidates = {}
			local function add(name, fn)
				table.insert(candidates, { name = name, fn = fn })
			end
			if type(debug) == "table" and type(debug.setfpscap) == "function" then
				add("debug.setfpscap", function()
					debug.setfpscap(cap)
				end)
			end
			local envs = {}
			pcall(function()
				envs[#envs + 1] = getgenv()
			end)
			pcall(function()
				envs[#envs + 1] = _G
			end)
			for _, env in envs do
				for _, name in { "setfpscap", "setFpsCap", "set_fps_cap", "setFPS" } do
					local f = env[name]
					if type(f) == "function" then
						add(name, function()
							f(cap)
						end)
					end
				end
			end
			if #candidates == 0 then
				return
			end
			for _, c in candidates do
				if try("fpsCap via " .. c.name, c.fn) then
					return
				end
			end
		end

		local function applyStreaming()
			if not CFG.streamEnabled then
				return
			end
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

		local function applyGameSettings()
			if not CFG.enableGameToggles then
				return
			end
			pcall(function()
				local setSetting = Network.SettingsService.RE.SetSetting
				setSetting:FireServer("Music", CFG.gameMusicVolume)
				setSetting:FireServer("HideGears", true)
				setSetting:FireServer("Performance", true)
			end)
		end

		local guis, animators = {}, {}
		local function destroyLater(inst)
			task.defer(function()
				if inst.Parent then
					pcall(function()
						inst:Destroy()
					end)
				end
			end)
		end
		local function onAdded(d)
			if CFG.killLights and d:IsA("Light") then
				pcall(function()
					d.Enabled = false
				end)
			elseif CFG.killParticles and d:IsA("ParticleEmitter") then
				pcall(function()
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
		local function bulkPass()
			pcall(function()
				for _, d in Workspace:GetDescendants() do
					onAdded(d)
				end
			end)
			applyRender()
			applyStreaming()
		end
		local function sweep()
			local hrp = root()
			if not hrp then
				return
			end
			local p = hrp.Position
			for i = #guis, 1, -1 do
				local g = guis[i]
				if not g.Parent then
					table.remove(guis, i)
				else
					local gp = posOf(g.Adornee or g.Parent)
					if gp then
						local want = (gp - p).Magnitude <= CFG.cullGuiDistance
						if g.Enabled ~= want then
							pcall(function()
								g.Enabled = want
							end)
						end
					end
				end
			end
			if CFG.freezeAnimations then
				for i = #animators, 1, -1 do
					local a = animators[i]
					if not a.Parent then
						table.remove(animators, i)
					else
						local mp = posOf(a:FindFirstAncestorOfClass("Model"))
						if mp then
							local speed = ((mp - p).Magnitude > CFG.freezeDistance) and 0 or 1
							pcall(function()
								for _, track in a:GetPlayingAnimationTracks() do
									track:AdjustSpeed(speed)
								end
							end)
						end
					end
				end
			end
		end

		task.spawn(function()
			local RUNNING = true
			applyFpsCap()
			bulkPass()
			applyGameSettings()
			Workspace.DescendantAdded:Connect(onAdded)
			task.spawn(function()
				while RUNNING do
					applyRender()
					task.wait(CFG.reapplySeconds)
				end
			end)
			task.spawn(function()
				while RUNNING do
					sweep()
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
			log("aktif (all-in-one)")
		end)
	end
end

--// Main flow \\--
local PHASE = "TUTORIAL"
local lastLog = 0
local farmReenable = 0

task.spawn(function()
	while true do
		local now = os.clock()

		if PHASE == "TUTORIAL" then
			local step = onboardingStep()
			if step >= 14 then
				PHASE = "FARM"
				applyPostTutorial()
				setAutoRoll(true)
				if now - lastLog > 2 then
					lastLog = now
					print(("[aio] tutorial selesai (step=%d), masuk FARM | Rolls=%d"):format(step, rollsTotal()))
				end
			else
				if now - lastLog > 1.5 then
					lastLog = now
					print(("[aio] tutorial step=%d | Rolls=%d Money=%.0f AR=%s"):format(step, rollsTotal(), money(), tostring(autoRollOn())))
				end
				if reconcile() then
					if forced[step] then
						advance()
						task.wait(0.4)
					else
						if step == 1 then
							rollOnce()
							task.wait(0.5)
						elseif step == 3 then
							equipNormal()
							task.wait(0.4)
						elseif step == 4 then
							interactSlot1()
							task.wait(0.5)
						elseif step == 5 then
							collectSlot1()
							task.wait(0.4)
						elseif step == 6 then
							teleportTo(Z_SHOP_AREA)
							task.wait(0.6)
						elseif step == 7 then
							teleportTo(Z_DICE_SHOP)
							task.wait(0.8)
						elseif step == 8 then
							if not hasNormalDice() then
								buyNormal()
							end
							task.wait(0.6)
						elseif step == 11 then
							rollOnce()
							task.wait(0.5)
						elseif step == 12 then
							setAutoRoll(true)
							task.wait(0.4)
						else
							task.wait(0.4)
						end
					end
				else
					task.wait(0.4)
				end
			end

		elseif PHASE == "FARM" then
			local r = rollsTotal()
			if r >= TARGET_ROLLS then
				PHASE = "DONE"
				if now - lastLog > 1 then
					lastLog = now
					print(("[aio] DONE — Rolls=%d >= %d (Trade siap)"):format(r, TARGET_ROLLS))
				end
			else
				if now - lastLog > 3 then
					lastLog = now
					print(("[aio] FARM Rolls=%d/%d | AR=%s Money=%.0f"):format(r, TARGET_ROLLS, tostring(autoRollOn()), money()))
				end
				if not autoRollOn() and now - farmReenable > 5 then
					farmReenable = now
					setAutoRoll(true)
				end
				task.wait(2)
			end

		elseif PHASE == "DONE" then
			if now - lastLog > 10 then
				lastLog = now
				local r = rollsTotal()
				print(("[aio] IDLE — Rolls=%d/%d (Trade siap)"):format(r, TARGET_ROLLS))
			end
			task.wait(5)
		end

		task.wait(0.25)
	end
end)

print(("[aio] dimulai — target Rolls >= %d"):format(TARGET_ROLLS))
