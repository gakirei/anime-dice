--// Anime Dice — Performance & Thermal Optimizer \\--
-- Target: cloud phone Android 12, 4GB RAM, 3-4 instance Roblox bersamaan.
-- Fokus: FPS & thermal (GPU/CPU load), mode agresif (cull efek, UI, animasi jauh).
--
-- Sifat: SEMUA perubahan lokal saja (client) — tidak menyentuh server/state game.
-- Executor target: Delta (Android). Setiap API Roblox dibungkus pcall + readback,
-- jadi kalau satu fitur tidak tersedia di versi client, sisanya tetap jalan.
--
-- Pakai bersama anime-dice-tutorial.luau (tutorial + Auto Roll).

--// Guard: jangan jalankan dua kali (mencegah loop ganda = malah boros) \\--
local ENV = (type(getgenv) == "function") and getgenv() or _G

-- Kalau versi lama masih berjalan, hentikan dulu -> re-run = ganti, bukan menumpuk
if type(ENV.animeDicePerf) == "table" and type(ENV.animeDicePerf.stop) == "function" then
	pcall(ENV.animeDicePerf.stop)
end

if ENV.__animeDicePerfLoaded then
	return
end
ENV.__animeDicePerfLoaded = true

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RS = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

--// Konfig \\--
local CFG = {
	-- render / thermal
	qualityLevel = Enum.QualityLevel.Level01, -- kualitas terendah
	fixQuality = true, -- matikan FRM supaya kualitas tidak dinaikkan otomatis
	fpsCap = 30, -- 0 = coba semua API yang ada; kalau nol semua, skip
	globalShadows = false,
	environmentScale = 0, -- EnvironmentDiffuse/SpecularScale
	disablePostFx = true, -- Bloom/DOF/SunRays/ColorCorrection
	disableAtmosphere = false, -- ubah tampilan langit cukup drastis

	-- streaming / RAM
	streamEnabled = true,
	streamTargetRadius = 384, -- default 1024; wajib > streamMinRadius
	streamMinRadius = 64,
	-- Opportunistic = client agresif membuang konten di luar radius (RAM turun
	-- drastis). Rekomendasi resmi Roblox; lebih baik dari LowMemory untuk HP 4GB.
	streamOutBehavior = Enum.StreamOutBehavior.Opportunistic,

	-- culling agresif
	killLights = true, -- PointLight/SpotLight/SurfaceLight
	killParticles = true, -- ParticleEmitter
	destroyBeamsTrails = true, -- Beam/Trail tidak punya properti Enabled
	destroyLegacyFx = true, -- Fire/Smoke/Sparkles
	gameMusicVolume = 0, -- lewat remote resmi game (0-100)
	enableGameToggles = true, -- set Music/HideGears/Performance lewat remote resmi

	-- jarak cull
	cullGuiDistance = 160, -- BillboardGui/SurfaceGui lebih jauh dari ini -> mati
	freezeAnimations = true, -- jeda animasi idle unit yang jauh (AdjustSpeed 0)
	freezeDistance = 160,

	-- interval (dalam detik; jangan dibuat terlalu kecil = justru boros CPU)
	reapplySeconds = 5,
	sweepSeconds = 3,
}

--// Override opsional (berguna untuk test tanpa edit file) \\--
-- Contoh: getgenv().__animeDicePerfConfig = { enableGameToggles = false }
local OVERRIDE = (type(ENV.__animeDicePerfConfig) == "table") and ENV.__animeDicePerfConfig or nil
if OVERRIDE then
	for k, v in pairs(OVERRIDE) do
		if CFG[k] ~= nil then
			CFG[k] = v
		end
	end
end

--// Util \\--
local function log(...)
	print("[perf]", ...)
end

local function try(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		log(("gagal %s: %s"):format(label, tostring(err)))
		return false
	end
	return true
end

local function root()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function posOf(inst)
	if not inst then
		return nil
	end
	-- pcall: instance bisa saja sudah Destroy() -> GetPivot() melempar error
	local ok, p = pcall(function()
		if inst:IsA("PVInstance") then
			return inst:GetPivot().Position
		end
		return nil
	end)
	return ok and p or nil
end

--// 1. Render settings (dicoba ulang tiap reapplySeconds karena bisa di-reset client) \\--
local lastQuality = nil

local function applyRender()
	-- Baca dulu: hanya paksa kalau kualitas BELUM di level target. Ini mencegah
	-- regresi (mis. EnableFRM=false justru mengunci ke level lebih tinggi) DAN
	-- membuat loop re-apply sangat murah saat kualitas sudah minimal.
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

	if cur ~= lastQuality then -- hindari spam log tiap 5 detik
		lastQuality = cur
		log(("QualityLevel = %s (ingin %s)"):format(cur, tostring(CFG.qualityLevel)))
	end

	-- lighting murah
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

--// 2. FPS cap — probe banyak nama karena debug.setfpscap BUKAN API Roblox resmi \\--
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
		log("fps cap API tidak tersedia — andalkan quality/culling")
		return
	end
	for _, c in candidates do
		if try("fpsCap via " .. c.name, c.fn) then
			log(("fpsCap = %d via %s"):format(cap, c.name))
			return
		end
	end
end

--// 3. Streaming (RAM) — StreamingTargetRadius terkonfirmasi ReadWrite/security None \\--
local function applyStreaming()
	if not CFG.streamEnabled then
		return
	end
	-- Banyak game (termasuk Anime Dice) tidak mengekspos properti streaming ke
	-- client -> akses melempar "not a valid member". Cek dulu, lewati kalau tidak ada.
	local available = pcall(function()
		return Workspace.StreamingTargetRadius
	end)
	if not available then
		log("streaming tidak tersedia di game ini — dilewati")
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
	-- akses properti dengan aman: bisa "not a valid member" kalau game tidak pakai streaming
	local function prop(name)
		local ok, v = pcall(function()
			return Workspace[name]
		end)
		return ok and tostring(v) or "n/a"
	end
	log(("streaming: min=%s target=%s out=%s"):format(
		prop("StreamingMinRadius"), prop("StreamingTargetRadius"), prop("StreamOutBehavior")))
end

--// 4. Tuas resmi game (sekali saja; jangan spam remote) \\--
local function applyGameSettings()
	if not CFG.enableGameToggles then
		return
	end
	local ok, err = pcall(function()
		local setSetting = RS.Network.SettingsService.RE.SetSetting
		setSetting:FireServer("Music", CFG.gameMusicVolume)
		setSetting:FireServer("HideGears", true)
		setSetting:FireServer("Performance", true)
	end)
	if ok then
		log(("game toggles: Music=%d, HideGears=ON, Performance=ON"):format(CFG.gameMusicVolume))
	else
		log("game toggles gagal: " .. tostring(err))
	end
end

--// 5. Registry berbasis event (hemat: TIDAK GetDescendants() berulang) \\--
local guis = {} -- BillboardGui / SurfaceGui untuk cull jarak
local animators = {} -- Animator untuk jeda animasi unit jauh

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
	-- kelas berat -> matikan/hapus saat pertama muncul
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

	-- daftar untuk sweep
	local cn = d.ClassName
	if cn == "BillboardGui" or cn == "SurfaceGui" then
		table.insert(guis, d)
	elseif CFG.freezeAnimations and d:IsA("Animator") then
		table.insert(animators, d)
	end
end

local function bulkPass()
	-- satu kali saja saat start
	log("bulk pass workspace ...")
	local n = 0
	pcall(function()
		for _, d in Workspace:GetDescendants() do
			onAdded(d)
			n = n + 1
		end
	end)
	log(("bulk pass selesai, %d instance diproses"):format(n))
	applyRender()
	applyStreaming()
end

--// 6. Sweep periodik: cull GUI jauh + jeda animasi unit jauh \\--
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
			local target = g.Adornee or g.Parent
			local gp = posOf(target)
			if gp then
				local want = (gp - p).Magnitude <= CFG.cullGuiDistance
				if g.Enabled ~= want then -- hindari penulisan properti yang tidak perlu
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
				local model = a:FindFirstAncestorOfClass("Model")
				local mp = posOf(model)
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

--// Bootstrap \\--
local RUNNING = true

local function main()
	log(("mulai | quality=%s fpsCap=%s cullGui=%d freeze=%d")
		:format(tostring(CFG.qualityLevel), tostring(CFG.fpsCap),
			CFG.cullGuiDistance, CFG.freezeDistance))

	applyFpsCap()
	bulkPass() -- bulk pass + render + streaming
	applyGameSettings() -- sekali saja (remote resmi)

	Workspace.DescendantAdded:Connect(onAdded)

	task.spawn(function()
		while RUNNING do
			applyRender() -- client boleh reset kualitas; paksa lagi
			task.wait(CFG.reapplySeconds)
		end
	end)

	task.spawn(function()
		while RUNNING do
			sweep()
			task.wait(CFG.sweepSeconds)
		end
	end)

	-- API kontrol: untuk test / mematikan tanpa reload client
	ENV.animeDicePerf = {
		config = CFG,
		stop = function()
			RUNNING = false
			ENV.__animeDicePerfLoaded = nil
			log("dihentikan (loop berhenti; efek yang sudah dihapus tetap sampai rejoin)")
		end,
	}

	log("aktif — loop reapply & sweep berjalan")
end

main()
