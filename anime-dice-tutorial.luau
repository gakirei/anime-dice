--// Anime Dice — Tutorial Automation (sampai unlock Auto Roll) \\--
-- Akun baru. Tutorial bersifat server-authoritative (13 step):
--   * step dengan kondisi  -> server auto-advance sendiri lewat reconcile
--   * step "forced" (2,9,10,13) -> harus fire OnboardingService.Advance
-- Setelah tutorial: set Auto Sell = 1qd (1e15) dan nyalakan Performance.
-- Script hanya memakai remote resmi game (tidak ada state palsu).

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local NET = RS:WaitForChild("Network")
local DC  = require(RS.Framework.Features.Data.DataController)
local EntryRegistry = require(RS.Framework.Features.Inventory.EntryRegistry)

--// Remotes \\--
local RF_RollDice     = NET.RollService.RF.RollDice
local RE_SetAutoRoll  = NET.RollService.RE.SetAutoRoll
local RE_Advance      = NET.OnboardingService.RE.Advance
local RF_Equip        = NET.UnitService.RF.Equip
local RE_InteractSlot = NET.PlotService.RE.InteractSlot
local RE_Collect      = NET.PlotService.RE.CollectBalance
local RE_BuyDice      = NET.DiceShopService.RE.BuyDice
local RE_SetSetting   = NET.SettingsService.RE.SetSetting

--// Konfig \\--
local DICE_NAME = "Normal"                         -- dice pertama, harga $1
local SLOT      = 1                                -- slot pertama (unlock di rebirth 0)
local SHOP_AREA = workspace.Zones.ShopArea.Position
local DICE_SHOP = workspace.Zones.DiceShop.Position

-- Pasca-tutorial: Auto Sell = 1qd (suffix game "qd" = 10^15), Performance = ON
local AUTO_SELL_TARGET = 1e15
local PERF_TARGET      = true

--// Helpers \\--
local function log(...)
    print("[tutorial]", ...)
end

local function currentStep()
    local ok, v = pcall(function() return DC.OnboardingStep() end)
    return ok and v or -1
end

local function rootPart()
    local c = LocalPlayer.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function waitUntil(pred, timeout, label)
    local deadline = os.clock() + (timeout or 15)
    while os.clock() < deadline do
        local ok, res = pcall(pred)
        if ok and res then return true end
        task.wait(0.1)
    end
    warn(("[tutorial] timeout menunggu: %s (step=%d)"):format(tostring(label), currentStep()))
    return false
end

local function waitStep(target, timeout)
    return waitUntil(function() return currentStep() >= target end, timeout, "step >= " .. target)
end

local function firstUnitKey()
    for key, entry in DC.Inventory() do
        local cfg = EntryRegistry.getEntryConfig(entry.name)
        if cfg and cfg.kind == "Unit" then
            return key, entry.name
        end
    end
end

local function teleport(pos, label)
    local r = rootPart()
    if not r then return false end
    pcall(function()
        LocalPlayer.Character:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)))
        r.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    end)
    return waitUntil(function()
        local rp = rootPart()
        return rp ~= nil and (rp.Position - pos).Magnitude < 15
    end, 8, "teleport " .. tostring(label))
end

local function collectUntilMoney(target, timeout)
    return waitUntil(function()
        if DC.Money() >= target then return true end
        local slot = DC.Slots()[tostring(SLOT)]
        if slot and (slot.balance or 0) > 0 then
            RE_Collect:FireServer(SLOT)
        end
        return false
    end, timeout, "money >= " .. target)
end

--// Alur utama \\--
local function applyPostTutorial()
    RE_SetSetting:FireServer("AutoSell", AUTO_SELL_TARGET)
    RE_SetSetting:FireServer("Performance", PERF_TARGET)

    waitUntil(function()
        return DC.AutoSell() == AUTO_SELL_TARGET
            and DC.Settings.Performance() == PERF_TARGET
    end, 10, "AutoSell=1qd & Performance=ON")

    log(("pasca-tutorial — AutoSell = %d (1qd) | Performance = %s")
        :format(DC.AutoSell(), tostring(DC.Settings.Performance())))
end

local function run()
    -- tunggu character siap
    waitUntil(function() return rootPart() ~= nil end, 15, "character siap")
    log("mulai — step awal:", currentStep())

    -- 1. Roll a unit!
    if currentStep() <= 1 then
        waitStep(1, 10)
        RF_RollDice:InvokeServer()
        waitUntil(function() return firstUnitKey() ~= nil end, 20, "unit muncul di inventory")
        waitStep(2, 10)
        log("step 1 ok — rolled a unit")
    end

    -- 2. Open your Backpack! (forced)
    if currentStep() == 2 then
        RE_Advance:FireServer()
        waitStep(3, 10)
        log("step 2 ok — backpack")
    end

    -- 3. Click on a Unit! (equip)
    if currentStep() == 3 then
        local key, name = firstUnitKey()
        if key then
            RF_Equip:InvokeServer(key)
            waitStep(4, 10)
            log("step 3 ok — equipped", name)
        end
    end

    -- 4. Place the unit in an empty slot!
    if currentStep() == 4 then
        RE_InteractSlot:FireServer(SLOT)
        waitStep(5, 10)
        log("step 4 ok — placed in slot", SLOT)
    end

    -- 5. Collect your cash! (butuh Money > 0)
    if currentStep() == 5 then
        collectUntilMoney(1, 25)
        waitStep(6, 10)
        log("step 5 ok — collected")
    end

    -- 6. Teleport to the shop area!
    if currentStep() == 6 then
        teleport(SHOP_AREA, "ShopArea")
        waitStep(7, 10)
        log("step 6 ok — shop area")
    end

    -- 7. Walk over to the Dice Shop!
    if currentStep() == 7 then
        teleport(DICE_SHOP, "DiceShop")
        waitStep(8, 10)
        log("step 7 ok — dice shop")
    end

    -- 8. Buy your first Dice! (Normal = $1)
    if currentStep() == 8 then
        collectUntilMoney(1, 25)
        RE_BuyDice:FireServer(DICE_NAME)
        waitStep(9, 10)
        log("step 8 ok — bought", DICE_NAME)
    end

    -- 9. Close the Dice Shop! (forced)
    if currentStep() == 9 then
        RE_Advance:FireServer()
        waitStep(10, 10)
        log("step 9 ok")
    end

    -- 10. Press Home to return to your base! (forced)
    if currentStep() == 10 then
        RE_Advance:FireServer()
        waitStep(11, 10)
        log("step 10 ok — home")
    end

    -- 11. Roll with your new dice! (Rolls > 1)
    if currentStep() == 11 then
        RF_RollDice:InvokeServer()
        waitStep(12, 10)
        log("step 11 ok — rolled again")
    end

    -- 12. Turn on Auto Roll!
    if currentStep() == 12 then
        RE_SetAutoRoll:FireServer(true)
        waitStep(13, 10)
        log("step 12 ok — Auto Roll ON")
    end

    -- 13. Hide your rolls! (forced) -> tutorial selesai
    if currentStep() == 13 then
        RE_Advance:FireServer()
        waitStep(14, 10)
        log("step 13 ok")
    end

    if currentStep() >= 14 then
        log("SELESAI — tutorial tuntas, Auto Roll sudah unlocked")
        applyPostTutorial()
    else
        warn("[tutorial] belum selesai, step akhir =", currentStep())
    end
end

run()
