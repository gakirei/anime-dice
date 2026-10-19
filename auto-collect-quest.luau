-- Auto Collect Quest Script for Anime Dice
-- Created for Main World (Daily & Weekly) & Halloween World (Hourly & Daily)

getgenv().AutoCollectQuest = true
local CHECK_INTERVAL = 15 -- Interval pemeriksaan dalam detik

local RS = game:GetService("ReplicatedStorage")
local DataController = require(RS.Framework.Features.Data.DataController)
local QuestConfig = require(RS.Framework.Features.Quests.QuestConfig)
local HalloweenQuests = require(RS.Framework.Features.Halloween.HalloweenQuests)
local Network = require(RS.Packages.Network)

-- Inisialisasi Signals melalui ClientComm
local questClaim = Network.ClientComm.new(RS.Network, false, "QuestService"):GetSignal("Claim")
local halloweenClaim = Network.ClientComm.new(RS.Network, false, "HalloweenQuestService"):GetSignal("Claim")

print("[AutoCollectQuest] Initialized! Auto-collect is running...")

local function claimMainQuests()
    local now = math.floor(workspace:GetServerTimeNow())
    for _, period in ipairs({"Daily", "Weekly"}) do
        local ok, data = pcall(function() return DataController.Quests[period]() end)
        if ok and data and data.progress and data.claimed then
            -- Lewati jika quest sedang masa kadaluwarsa / reset
            if data.expiresAt ~= 0 and data.expiresAt <= now then
                continue
            end

            local periodConfig = QuestConfig.Periods[period]
            if periodConfig and periodConfig.quests then
                for _, quest in ipairs(periodConfig.quests) do
                    local currentProgress = data.progress[quest.id] or 0
                    local isClaimed = data.claimed[quest.id] == true

                    if currentProgress >= quest.target and not isClaimed then
                        print(string.format("[AutoCollectQuest] Claiming Main %s quest: %s (%d/%d)", period, quest.id, currentProgress, quest.target))
                        questClaim:Fire(period, quest.id, data.expiresAt)
                        task.wait(0.3)
                    end
                end
            end
        end
    end
end

local function claimHalloweenQuests()
    for _, period in ipairs(HalloweenQuests.PERIODS) do -- "Hourly", "Daily"
        local periodDef = HalloweenQuests[period]
        if not periodDef then continue end

        local dataKey = periodDef.dataKey
        local ok, data = pcall(function() return DataController.Halloween[dataKey]() end)
        if ok and data and data.progress and data.claimed and data.ids then
            -- Buat lookup tabel dari pool config
            local poolLookup = {}
            for _, q in ipairs(periodDef.pool) do
                poolLookup[q.id] = q
            end

            -- Hanya proses quest yang aktif saat ini (berdasarkan ids)
            for _, questId in ipairs(data.ids) do
                local quest = poolLookup[questId]
                if quest then
                    local currentProgress = data.progress[questId] or 0
                    local isClaimed = data.claimed[questId] == true

                    if currentProgress >= quest.target and not isClaimed then
                        print(string.format("[AutoCollectQuest] Claiming Halloween %s quest: %s (%d/%d)", period, questId, currentProgress, quest.target))
                        halloweenClaim:Fire(period, questId)
                        task.wait(0.3)
                    end
                end
            end
        end
    end
end

task.spawn(function()
    while getgenv().AutoCollectQuest do
        local success, err = pcall(function()
            claimMainQuests()
            claimHalloweenQuests()
        end)

        if not success then
            warn("[AutoCollectQuest] Error checking quests:", err)
        end

        task.wait(CHECK_INTERVAL)
    end
    print("[AutoCollectQuest] Loop stopped.")
end)
