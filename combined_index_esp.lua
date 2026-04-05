--[[
    Index Viewer V2 - Optimized SAB Index Enhancement
    
    Features:
    - Mutation side panel with scrollable buttons
    - Search bar for animal name lookup
    - Filter: All / Unindexed / Indexed
    - "Show All" toggle to display all brainrots
    - NOT INDEXED indicator on cards
    - Shadow fix for unindexed animals
    
    V2 Optimizations:
    - No Heartbeat loops (event-driven only)
    - Minimal GetDescendants calls
    - Cached references
    - Lazy initialization
]] -- Quick place check FIRST (instant exit for other games)
-- ============================================================================
-- PLACE CHECK
-- ============================================================================
local PLACE_ID = 109983668079237
if game.PlaceId ~= PLACE_ID then
    return
end

-- ============================================================================
-- PATCH EARLY: Unlock time-limited mutations and hidden animals
-- Must run BEFORE game creates Index UI, but AFTER dependencies exist!
-- ============================================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- CACHE: Animals that were originally hidden (Admin animals etc.) - for "Show Admin"
local OriginallyHiddenAnimals = {}
-- CACHE: All animals from AnimalsData - for "Show All" to inject missing ones
local AllAnimalsFromData = {}

-- Wait for required folders to exist
local Datas = ReplicatedStorage:WaitForChild("Datas", 30)
local Shared = ReplicatedStorage:WaitForChild("Shared", 30)

if Datas and Shared then

    -- Patch IndexData ONLY (it has no complex dependencies)
    local IndexDataModule = Datas:WaitForChild("Index", 5)
    if IndexDataModule then
        local success, IndexData = pcall(require, IndexDataModule)
        if success and IndexData then
            local patchCount = 0
            for mutName, mutData in pairs(IndexData) do
                if type(mutData) == "table" then
                    if mutData.LimitedMutation then
                        mutData.LimitedMutation = nil
                        print("[IndexV2] EARLY: Patched mutation '" .. mutName .. "'")
                        patchCount = patchCount + 1
                    end
                    if mutData.ShowInSettings == false then
                        mutData.ShowInSettings = true
                    end
                end
            end
            print("[IndexV2] EARLY: Unlocked " .. patchCount .. " time-limited mutations")
        end
    end

    -- AnimalsData has complex dependencies - DON'T require it early!
    -- Instead, we'll cache hidden animals LATER when modules are safe to load
end
task.spawn(function()

    -- Services
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local RunService = game:GetService("RunService")
    local SoundService = game:GetService("SoundService")
    local HttpService = game:GetService("HttpService")

    -- Wait for LocalPlayer (critical for auto-exec!)
    local LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then
        LocalPlayer = Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
        LocalPlayer = Players.LocalPlayer
    end
    if not LocalPlayer then
        repeat
            task.wait()
        until Players.LocalPlayer
        LocalPlayer = Players.LocalPlayer
    end

    -- Config file for spawn panel position
    local SPAWN_PANEL_CONFIG_FILE = "IndexV2SpawnPanelConfig.json"
    local AUDIO_CONFIG_FILE = "IndexV2AudioConfig.json"

    -- Wait for game
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(0.3)

    -- Require modules (game should be ready now)
    local Packages = ReplicatedStorage:WaitForChild("Packages", 10)
    if not Packages or not Datas or not Shared then
        return
    end

    local Synchronizer = require(Packages.Synchronizer)
    local IndexData = require(Datas.Index)
    local AnimalsData = require(Datas.Animals)
    local SharedIndex = require(Shared.Index)
    local SharedAnimals = require(Shared.Animals)
    local Gradients = require(Packages.Gradients)
    local Trove = require(Packages.Trove)
    local RaritiesData = require(Datas.Rarities)
    local MutationsData = require(Datas.Mutations)
    local TraitsData = require(Datas.Traits)
    local NumberUtils = require(ReplicatedStorage:WaitForChild("Utils").NumberUtils)
    local GameData = require(Datas.Game)

    -- Game's templates for overhead display (used for Index cards, not spawning)
    local AnimalOverheadTemplate = ReplicatedStorage:WaitForChild("Overheads"):WaitForChild("AnimalOverhead")
    local AnimalAnimations = ReplicatedStorage:WaitForChild("Animations"):WaitForChild("Animals")
    local AnimalModels = ReplicatedStorage:WaitForChild("Models"):WaitForChild("Animals")

    -- Animation sync controller (for proper animation playback)
    local AnimationSyncController = Controllers and require(Controllers.AnimationSyncController)

    -- Use game's SoundController for proper sound playback (same as game uses)
    local Controllers = ReplicatedStorage:WaitForChild("Controllers", 5)
    local SoundController = Controllers and require(Controllers.SoundController)

    -- Animal sounds folder (where the game stores brainrot name audio)
    local AnimalSounds = ReplicatedStorage:WaitForChild("Sounds", 5)
    AnimalSounds = AnimalSounds and AnimalSounds:WaitForChild("Animals", 5)

    -- Sound state tracking
    local currentPlayingSound = nil
    local lastSoundTime = 0
    local SOUND_COOLDOWN = 0.3 -- Minimum time between sounds to prevent overlap
    local audioEnabled = true -- Toggle for name audio
    local copyNameEnabled = false -- Toggle for copying name on click

    -- Load audio config
    local function loadAudioConfig()
        pcall(function()
            if isfile and isfile(AUDIO_CONFIG_FILE) then
                local content = readfile(AUDIO_CONFIG_FILE)
                local data = HttpService:JSONDecode(content)
                if data.audioEnabled ~= nil then
                    audioEnabled = data.audioEnabled
                end
            end
        end)
    end

    local function saveAudioConfig()
        pcall(function()
            if writefile then
                writefile(AUDIO_CONFIG_FILE, HttpService:JSONEncode({
                    audioEnabled = audioEnabled
                }))
            end
        end)
    end

    -- Load audio config on start
    loadAudioConfig()

    -- Play the animal's name sound (same as when you grab a brainrot)
    local function playAnimalSound(animalName)
        -- Check if audio is enabled
        if not audioEnabled then
            return
        end

        -- Cooldown check to prevent double-click overlap
        local now = tick()
        if now - lastSoundTime < SOUND_COOLDOWN then
            return
        end
        lastSoundTime = now

        -- Stop any currently playing sound
        if currentPlayingSound and currentPlayingSound.Parent then
            pcall(function()
                currentPlayingSound:Stop()
                currentPlayingSound:Destroy()
            end)
            currentPlayingSound = nil
        end

        -- Get display name for sound lookup
        local displayName = animalName
        local animalData = AnimalsData[animalName]
        if animalData and animalData.DisplayName then
            displayName = animalData.DisplayName
        end

        -- Method 1: Try using game's SoundController (most reliable)
        if SoundController then
            -- Try display name first (how AnimalService does it for rare animals)
            local success = pcall(function()
                currentPlayingSound = SoundController:PlaySound("Sounds.Animals." .. displayName)
            end)

            -- Fallback to internal name (how StealService does it)
            if not success or not currentPlayingSound then
                pcall(function()
                    currentPlayingSound = SoundController:PlaySound("Sounds.Animals." .. animalName)
                end)
            end

            if currentPlayingSound then
                return
            end
        end

        -- Method 2: Manual fallback if SoundController didn't work
        if not AnimalSounds then
            return
        end

        -- Find the sound - try display name first, then internal name
        local sound = AnimalSounds:FindFirstChild(displayName)
        if not sound then
            sound = AnimalSounds:FindFirstChild(animalName)
        end

        -- Fallback: try case-insensitive search
        if not sound then
            local lowerDisplay = displayName:lower()
            local lowerInternal = animalName:lower()
            for _, s in pairs(AnimalSounds:GetChildren()) do
                local lowerName = s.Name:lower()
                if lowerName == lowerDisplay or lowerName == lowerInternal then
                    sound = s
                    break
                end
            end
        end

        if sound then
            -- Clone and play properly
            local soundClone = sound:Clone()
            soundClone.Parent = SoundService
            soundClone:Play()
            currentPlayingSound = soundClone

            -- Clean up after playing
            soundClone.Ended:Once(function()
                if soundClone and soundClone.Parent then
                    soundClone:Destroy()
                end
                if currentPlayingSound == soundClone then
                    currentPlayingSound = nil
                end
            end)
        end
    end

    print("[IndexV2] Modules loaded")

    -- ============================================================================
    -- PATCH ANIMALS DATA: Cache hidden animals + ALL animals for Show All
    -- Done HERE after modules are loaded safely
    -- ============================================================================
    do
        local hiddenCount = 0
        local totalCount = 0
        for animalName, animalData in pairs(AnimalsData) do
            if type(animalData) == "table" then
                -- Track ALL animals for Show All injection
                AllAnimalsFromData[animalName] = true
                totalCount = totalCount + 1

                -- Track hidden animals for Show Admin
                if animalData.HideFromIndex then
                    OriginallyHiddenAnimals[animalName] = true
                    hiddenCount = hiddenCount + 1
                end
            end
        end
        -- Export to _G so other scripts can check original hidden state
        _G.IndexV2_OriginallyHiddenAnimals = OriginallyHiddenAnimals
        _G.IndexV2_AllAnimalsFromData = AllAnimalsFromData
        print("[IndexV2] Found " .. totalCount .. " total animals, " .. hiddenCount .. " hidden (Admin)")
    end

    -- ============================================================================
    -- SPAWN PANEL POSITION SAVE/LOAD
    -- ============================================================================
    local function loadSpawnPanelPosition()
        local success, result = pcall(function()
            if isfile and isfile(SPAWN_PANEL_CONFIG_FILE) then
                local content = readfile(SPAWN_PANEL_CONFIG_FILE)
                return HttpService:JSONDecode(content)
            end
        end)
        if success and result then
            return result
        end
        return nil
    end

    local function saveSpawnPanelPosition(position)
        pcall(function()
            local data = {
                X = position.X.Offset,
                Y = position.Y.Offset
            }
            if writefile then
                writefile(SPAWN_PANEL_CONFIG_FILE, HttpService:JSONEncode(data))
            end
        end)
    end

    -- ============================================================================
    -- CONFIG
    -- ============================================================================
    local ACCENT_COLOR = Color3.fromRGB(255, 170, 50)
    local BG_COLOR = Color3.fromRGB(20, 20, 25)
    local FILTER_ALL = "All"
    local FILTER_UNINDEXED = "Unindexed"
    local FILTER_INDEXED = "Indexed"

    -- ============================================================================
    -- SIMPLE SIGNAL CLASS (like game's signal pattern)
    -- ============================================================================
    local Signal = {}
    Signal.__index = Signal

    function Signal.new()
        return setmetatable({
            _listeners = {}
        }, Signal)
    end

    function Signal:Connect(callback)
        local connection = {
            _callback = callback,
            _connected = true
        }
        function connection:Disconnect()
            self._connected = false
        end
        table.insert(self._listeners, connection)
        return connection
    end

    function Signal:Fire(...)
        for _, conn in ipairs(self._listeners) do
            if conn._connected then
                task.spawn(conn._callback, ...)
            end
        end
    end

    -- ============================================================================
    -- STATE
    -- ============================================================================
    local currentMutation = "Default"
    local currentFilter = FILTER_ALL
    local currentSearch = ""
    local showAllMode = false
    local showAdminAnimals = false -- Show Admin animals toggle (OFF by default)
    local isInitialized = false
    local lastIndexVisible = false -- Track when Index UI visibility changes

    -- MUTATION SIGNAL - fires when mutation selection changes (like game's v_u_38)
    local MutationChanged = Signal.new()

    -- ============================================================================
    -- ANIMAL SPAWN SYSTEM STATE (Client-Side)
    -- ============================================================================
    local spawnModeEnabled = false
    local selectedPodiumIndex = 1 -- First podium by default (legacy, used when single slot)
    local selectedPodiumIndices = {} -- Table of selected podium indices for multi-select
    local spawnAllPodiums = false -- Spawn on all podiums at once
    local spawnedAnimalModels = {} -- Track spawned models for cleanup: [podiumIndex] = model
    local spawnPanelUI = nil -- Reference to spawn panel UI
    local selectedTraits = {} -- Table of selected trait names: {"Fire", "Nyan", etc.}

    -- SHARED GLOBAL: Track client-spawned podiums so PetInventoryTracker skips them
    if not _G.ClientSpawnedPodiums then
        _G.ClientSpawnedPodiums = {}
    end
    -- SHARED GLOBAL: Store original pet data so PetInventoryTracker can still count real pets
    if not _G.ClientSpawnedOriginalData then
        _G.ClientSpawnedOriginalData = {}
    end
    -- SHARED GLOBAL: Store what we actually spawned, so we can detect when server replaces it
    if not _G.ClientSpawnedFakeData then
        _G.ClientSpawnedFakeData = {}
    end

    -- Filtered counts for counter display
    local filteredIndexedCount = 0
    local filteredUnindexedCount = 0
    local filteredTotalVisible = 0

    -- Cache
    local cardCache = {} -- card -> {name, indicator, originalVisible}
    local mutationButtons = {}
    local cardTroves = {} -- card -> Trove (manages mutation cleanup per card, like game does)
    local appliedMutations = {} -- card -> mutationName (tracks which mutation is currently applied)
    local heartbeatConnection = nil -- Heartbeat loop for mutation apply/cleanup
    local selectedMutationLabel = nil -- Label showing current selected mutation
    local selectedMutationGradient = nil -- Gradient cleanup for rainbow text
    local viewportCache = {} -- card -> ViewportFrame (track viewports before game unparents them!)

    -- ============================================================================
    -- OCCLUSION SYSTEM - Imitates game's viewport culling for performance
    -- ============================================================================
    -- viewport -> {targetParent = card, state = bool, scheduledUpdate = function}
    local viewportTracking = {}
    -- card -> layout index (for calculating row position)
    local cardLayoutIndex = {}
    -- Scroll/layout tracking
    local occlusionState = {
        listTop = 0, -- v_u_86: List AbsolutePosition.Y
        listBottom = 0, -- v_u_87: listTop + size.Y
        scrollOffset = 0, -- v_u_88: listTop - CanvasPosition.Y
        cellPaddingY = 0, -- v_u_90: Cell padding Y
        cellSize = Vector2.new(100, 100), -- v_u_98: AbsoluteCellSize
        cellCount = Vector2.new(4, 1), -- v_u_97: AbsoluteCellCount (columns)
        isVisible = false, -- v_u_94: Index visible flag
        enabled = true -- Toggle occlusion on/off
    }

    -- Counter UI element references (for heartbeat to force-update)
    local counterElements = {
        barNumber = nil,
        barLoading = nil,
        descLabel = nil,
        headerTotal = nil
    }

    -- Last known counter text (to detect game overwriting our values)
    local lastCounterState = {
        barText = nil,
        descText = nil
    }

    -- Forward declarations for functions defined later
    local hookViewport
    local hookMutationLabel

    -- ============================================================================
    -- UTILITY FUNCTIONS
    -- ============================================================================
    local function isAnimalIndexed(animalName, mutation)
        local playerData = Synchronizer:Get(LocalPlayer)
        if not playerData then
            return false
        end

        local indexData = playerData:Get("Index")
        if not indexData or not indexData[animalName] then
            return false
        end

        local animalIndex = indexData[animalName]
        local mutInfo = IndexData[mutation]

        -- Determine the index key - SAME LOGIC AS LINE 3428-3435
        local indexKey = "Default"
        if mutInfo then
            if mutInfo.CustomIndex then
                indexKey = mutInfo.CustomIndex.Name
            elseif mutInfo.IsMutation then
                indexKey = mutation
            end
        end

        return animalIndex[indexKey] ~= nil
    end

    -- Check if animal was originally hidden (cached during early patch)
    -- This catches ALL hidden animals, not just "Admin" rarity ones
    local function wasOriginallyHidden(animalName)
        return OriginallyHiddenAnimals[animalName] == true
    end

    -- Check if a card is an admin animal (checks all detection methods)
    local function isCardAdminAnimal(card, animalName)
        animalName = animalName or card.Name
        return wasOriginallyHidden(animalName) or (cardCache[card] and cardCache[card].isAdminAnimal) or
                   card:GetAttribute("IndexV2_AdminAnimal")
    end

    -- Check if animal EXISTS in the mutation's Index data (what game shows in UI)
    -- This is different from isAnimalIndexed which checks PLAYER's collection
    local function animalExistsInMutationIndex(animalName, mutation)
        local mutInfo = IndexData[mutation]
        if not mutInfo then
            -- Default mutation - animal exists if it's in AnimalsData
            return AnimalsData[animalName] ~= nil
        end

        if mutInfo.Index then
            -- Mutation has Index table - check if animal is in it
            return mutInfo.Index[animalName] ~= nil
        end

        -- Fallback - assume animal exists
        return true
    end

    -- ============================================================================
    -- CARD INJECTION HELPER - Creates cards for missing animals
    -- ============================================================================
    local injectedShowAllCards = {} -- Track cards injected by Show All (not Admin)

    local function injectAnimalCard(list, template, animalName, isAdmin)
        -- Check if card already exists
        local existingCard = list:FindFirstChild(animalName)
        if existingCard then
            return existingCard, false -- Card exists, not new
        end

        local animalData = AnimalsData[animalName]
        if not animalData then
            return nil, false
        end

        -- Clone template and set up the card
        local newCard = template:Clone()
        newCard.Name = animalName
        newCard.Visible = false -- Start hidden
        newCard.LayoutOrder = isAdmin and -1 or 1000 -- Admin at TOP, Show All at bottom

        -- Set name label
        local nameLabel = newCard:FindFirstChild("NameLabel")
        if nameLabel then
            nameLabel.Text = animalData.DisplayName or animalName
            nameLabel.Visible = true -- Always show name
        end

        -- Set rarity label with proper color/gradient
        local rarityLabel = newCard:FindFirstChild("RarityLabel")
        if rarityLabel then
            local rarity = animalData.Rarity or "Common"
            rarityLabel.Text = rarity

            local rarityInfo = RaritiesData[rarity]
            if rarityInfo then
                if rarityInfo.GradientPreset then
                    rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
                    pcall(function()
                        Gradients.apply(rarityLabel, rarityInfo.GradientPreset)
                    end)
                else
                    rarityLabel.TextColor3 = rarityInfo.Color or Color3.fromRGB(255, 255, 255)
                end
            end
        end

        -- Set mutation label
        local mutLabel = newCard:FindFirstChild("MutationLabel")
        if mutLabel then
            mutLabel.Text = "Default"
        end

        -- Set up viewport with animal model
        local viewport = newCard:FindFirstChild("ViewportFrame")
        if viewport then
            viewport.ImageColor3 = Color3.fromRGB(255, 255, 255) -- White = visible
            pcall(function()
                SharedAnimals:AttachOnViewport(animalName, viewport, true, nil, true)
            end)
        end

        -- Mark as injected
        newCard:SetAttribute("IndexV2_Injected", true)
        if isAdmin then
            newCard:SetAttribute("IndexV2_AdminAnimal", true)
        else
            newCard:SetAttribute("IndexV2_ShowAllAnimal", true)
        end

        newCard.Parent = list

        -- Cache with proper flags
        cardCache[newCard] = {
            name = animalName,
            originalVisible = false,
            isInjected = true,
            isAdminAnimal = isAdmin,
            isShowAllAnimal = not isAdmin
        }

        -- Track Show All cards separately for cleanup
        if not isAdmin then
            injectedShowAllCards[newCard] = true
        end

        return newCard, true -- Card created, is new
    end

    -- ============================================================================
    -- ANIMAL SPAWN SYSTEM FUNCTIONS (Client-Side via Channel)
    -- ============================================================================

    -- Get the local player's plot
    local function getMyPlot()
        local plots = workspace:FindFirstChild("Plots")
        if not plots then
            return nil
        end

        -- Method 1: YourBase GUI enabled (most reliable - same as game uses)
        for _, plot in ipairs(plots:GetChildren()) do
            local plotSign = plot:FindFirstChild("PlotSign")
            if plotSign then
                local yourBase = plotSign:FindFirstChild("YourBase")
                if yourBase and yourBase:IsA("BillboardGui") and yourBase.Enabled then
                    return plot
                end
            end
        end

        -- Method 2: Fallback to Owner attribute (Name check)
        for _, plot in ipairs(plots:GetChildren()) do
            local owner = plot:GetAttribute("Owner")
            if owner == LocalPlayer.Name then
                return plot
            end
        end

        -- Method 3: Fallback to Owner attribute (UserId check)
        for _, plot in ipairs(plots:GetChildren()) do
            local owner = plot:GetAttribute("Owner")
            if owner == LocalPlayer.UserId then
                return plot
            end
        end

        return nil
    end

    -- Get the plot's Synchronizer channel
    local function getPlotChannel()
        local plot = getMyPlot()
        if not plot then
            return nil
        end

        local channel = nil
        pcall(function()
            channel = Synchronizer:Wait(plot.Name)
        end)
        return channel
    end

    -- Get all podiums from player's plot
    local function getMyPodiums()
        local plot = getMyPlot()
        if not plot then
            return {}
        end

        -- Game uses "AnimalPodiums" not "Podiums"!
        local podiumsFolder = plot:FindFirstChild("AnimalPodiums")
        if not podiumsFolder then
            -- Fallback: try "Podiums" just in case
            podiumsFolder = plot:FindFirstChild("Podiums")
        end
        if not podiumsFolder then
            return {}
        end

        local podiums = {}
        for _, child in ipairs(podiumsFolder:GetChildren()) do
            -- Podiums are named like "1", "2", "3" etc
            local podiumNum = tonumber(child.Name)
            if podiumNum then
                table.insert(podiums, {
                    index = podiumNum,
                    model = child
                })
            end
        end

        -- Sort by index
        table.sort(podiums, function(a, b)
            return a.index < b.index
        end)
        return podiums
    end

    -- Get podium by index
    local function getPodiumByIndex(index)
        local podiums = getMyPodiums()
        for _, p in ipairs(podiums) do
            if p.index == index then
                return p.model
            end
        end
        return nil
    end

    -- Store original AnimalList data so we can restore it
    local originalAnimalListData = {}

    -- Clean up a spawned animal on a specific podium (restore original data)
    local function cleanupSpawnedAnimal(podiumIndex)
        -- Restore original channel data for this podium
        local channel = getPlotChannel()
        if channel and originalAnimalListData[podiumIndex] ~= nil then
            pcall(function()
                channel:Set(string.format("AnimalList.%d", podiumIndex), originalAnimalListData[podiumIndex])
            end)
            originalAnimalListData[podiumIndex] = nil
        end
        spawnedAnimalModels[podiumIndex] = true -- Just mark as was spawned
    end

    -- Clean up ALL spawned animals
    local function cleanupAllSpawnedAnimals()
        local channel = getPlotChannel()
        if channel then
            for podiumIndex, originalData in pairs(originalAnimalListData) do
                pcall(function()
                    channel:Set(string.format("AnimalList.%d", podiumIndex), originalData)
                end)
                -- Clear from shared globals when restoring
                if _G.ClientSpawnedPodiums then
                    _G.ClientSpawnedPodiums[podiumIndex] = nil
                    _G.ClientSpawnedPodiums[tostring(podiumIndex)] = nil
                end
                if _G.ClientSpawnedOriginalData then
                    _G.ClientSpawnedOriginalData[podiumIndex] = nil
                    _G.ClientSpawnedOriginalData[tostring(podiumIndex)] = nil
                end
                if _G.ClientSpawnedFakeData then
                    _G.ClientSpawnedFakeData[podiumIndex] = nil
                    _G.ClientSpawnedFakeData[tostring(podiumIndex)] = nil
                end
            end
        end
        originalAnimalListData = {}
        spawnedAnimalModels = {}
    end

    -- Spawn an animal on a podium by setting channel data (game will render it!)
    local function spawnAnimalOnPodium(animalName, mutation, traits, podiumIndex)
        -- Check for mutations that don't work with spawning - spawn as normal instead
        if mutation == "Aquatic" or mutation == "Christmas" then
            mutation = "Default"
        end

        local podium = getPodiumByIndex(podiumIndex)
        if not podium then
            warn("[IndexV2 Spawn] Podium " .. podiumIndex .. " not found")
            return nil
        end

        local channel = getPlotChannel()
        if not channel then
            warn("[IndexV2 Spawn] Could not get plot channel")
            return nil
        end

        -- Save original data before overwriting (so we can restore later)
        if originalAnimalListData[podiumIndex] == nil then
            local currentData = nil
            pcall(function()
                currentData = channel:Get(string.format("AnimalList.%d", podiumIndex))
            end)
            originalAnimalListData[podiumIndex] = currentData or "Empty"
            -- Also store in shared global so PetInventoryTracker can read the REAL pet
            _G.ClientSpawnedOriginalData[podiumIndex] = currentData
            _G.ClientSpawnedOriginalData[tostring(podiumIndex)] = currentData
        end

        -- Build animal data structure like the game uses
        -- IMPORTANT: Copy traits table to avoid reference issues (changing selectedTraits shouldn't affect already-spawned animals)
        local traitsCopy = nil
        if traits and #traits > 0 then
            traitsCopy = {}
            for _, t in ipairs(traits) do
                table.insert(traitsCopy, t)
            end
        end

        local animalData = {
            Index = animalName,
            Mutation = (mutation and mutation ~= "Default" and mutation ~= "Normal") and mutation or nil,
            Traits = traitsCopy,
            LastCollect = workspace:GetServerTimeNow() -- Start collecting from now
        }

        -- Set the channel data - this triggers PlotClient to render the animal!
        pcall(function()
            channel:Set(string.format("AnimalList.%d", podiumIndex), animalData)
        end)

        spawnedAnimalModels[podiumIndex] = true
        -- Mark in SHARED GLOBAL so PetInventoryTracker skips this podium!
        _G.ClientSpawnedPodiums[podiumIndex] = true
        _G.ClientSpawnedPodiums[tostring(podiumIndex)] = true
        -- Store what we spawned so we can detect when server replaces it with real pet
        _G.ClientSpawnedFakeData[podiumIndex] = animalData.Index
        _G.ClientSpawnedFakeData[tostring(podiumIndex)] = animalData.Index
        print("[IndexV2 Spawn] Set channel data for podium", podiumIndex, ":", animalName, mutation, traits)

        -- Notify BrainrotAnimController of the spawn (for auto-animation)
        if _G.BrainrotAnimController and _G.BrainrotAnimController.notifySpawn then
            _G.BrainrotAnimController.notifySpawn(animalName, podiumIndex, mutation)
        end

        return true
    end

    -- Spawn animal on selected podium(s)
    local function spawnAnimalFromCard(animalName)
        if not spawnModeEnabled then
            return
        end

        local mutation = currentMutation
        local traits = selectedTraits -- Use selected traits from spawn panel

        -- Get display name for status
        local displayName = animalName
        local animalData = AnimalsData[animalName]
        if animalData and animalData.DisplayName then
            displayName = animalData.DisplayName
        end

        local mutationText = mutation == "Default" and "" or (" [" .. mutation .. "]")
        local traitsText = #traits > 0 and (" +" .. #traits .. " traits") or ""

        if spawnAllPodiums then
            -- Spawn on all podiums
            local podiums = getMyPodiums()
            for _, p in ipairs(podiums) do
                spawnAnimalOnPodium(animalName, mutation, traits, p.index)
            end
            -- Update spawn panel status
            if spawnPanelUI and spawnPanelUI.updateStatus then
                spawnPanelUI.updateStatus("✅ " .. displayName .. mutationText .. traitsText .. " on ALL!")
            end
            print("[IndexV2 Spawn] Spawned " .. animalName .. " with " .. #traits .. " traits on ALL " .. #podiums ..
                      " podiums!")
        elseif #selectedPodiumIndices > 1 then
            -- Multi-select: spawn on all selected podiums
            for _, podiumIdx in ipairs(selectedPodiumIndices) do
                spawnAnimalOnPodium(animalName, mutation, traits, podiumIdx)
            end
            -- Update spawn panel status
            if spawnPanelUI and spawnPanelUI.updateStatus then
                spawnPanelUI.updateStatus("✅ " .. displayName .. mutationText .. traitsText .. " on " ..
                                              #selectedPodiumIndices .. " slots!")
            end
            print("[IndexV2 Spawn] Spawned " .. animalName .. " with " .. #traits .. " traits on " ..
                      #selectedPodiumIndices .. " selected podiums!")
        else
            -- Spawn on single selected podium
            local targetPodium = (#selectedPodiumIndices > 0) and selectedPodiumIndices[1] or selectedPodiumIndex
            spawnAnimalOnPodium(animalName, mutation, traits, targetPodium)
            -- Update spawn panel status
            if spawnPanelUI and spawnPanelUI.updateStatus then
                spawnPanelUI.updateStatus("✅ " .. displayName .. mutationText .. traitsText .. " on #" .. targetPodium)
            end
        end

        -- Update money generation display
        if spawnPanelUI and spawnPanelUI.updateMoneyGeneration then
            local mutForCalc = (mutation == "Default" or mutation == "Normal") and nil or mutation
            spawnPanelUI.updateMoneyGeneration(animalName, mutForCalc, traits)
        end

        -- Play the animal sound
        playAnimalSound(animalName)
    end

    -- ============================================================================
    -- COUNTER UPDATE FUNCTIONS (Module-level for heartbeat access)
    -- ============================================================================

    -- Get CORRECT index counts using GAME's SharedIndex module
    local function getCorrectIndexCounts(mutation)
        local indexed, required, total = SharedIndex:GetIndexAnimals(LocalPlayer, mutation)
        if not indexed then
            return 0, 0, 0
        end
        return indexed, required, total
    end

    -- Force update the counter display - called by heartbeat to overwrite game's values
    local function updateIndexCounter()
        local barNumber = counterElements.barNumber
        local barLoading = counterElements.barLoading
        local descLabel = counterElements.descLabel
        local headerTotal = counterElements.headerTotal

        if not barNumber then
            return
        end -- Elements not captured yet

        local indexed, required, total = getCorrectIndexCounts(currentMutation)

        local targetBarText, targetBarColor
        local targetBarSize, targetBarBgColor
        local targetHeaderText = nil -- Only set if we want to override header

        -- Determine what to show based on filter
        if currentFilter == FILTER_INDEXED then
            -- Show only indexed count - use filteredTotalVisible since those are the visible indexed cards
            targetBarText = string.format("Indexed: %d", filteredTotalVisible)
            targetBarColor = Color3.fromRGB(100, 255, 100)
            targetBarSize = UDim2.new(1, 0, 1, 0)
            targetBarBgColor = Color3.fromRGB(100, 200, 100)
            -- Just show total indexed, no redundant "X/X"
            targetHeaderText = string.format("%d", filteredTotalVisible)
        elseif currentFilter == FILTER_UNINDEXED then
            -- Show only unindexed count - use filteredTotalVisible since those are the visible unindexed cards
            targetBarText = string.format("Missing: %d", filteredTotalVisible)
            targetBarColor = Color3.fromRGB(255, 100, 100)
            targetBarSize = UDim2.new(1, 0, 1, 0) -- Full bar in red for missing
            targetBarBgColor = Color3.fromRGB(200, 100, 100)
            -- Just show total missing, no "0/" prefix
            targetHeaderText = string.format("%d", filteredTotalVisible)
        elseif currentSearch ~= "" then
            -- Search active: just show found count
            targetBarText = string.format("Found: %d", filteredTotalVisible)
            targetBarColor = Color3.fromRGB(100, 180, 255)
            local searchPct = filteredTotalVisible > 0 and (filteredIndexedCount / filteredTotalVisible) or 0
            targetBarSize = UDim2.new(searchPct, 0, 1, 0)
            targetBarBgColor = Color3.fromRGB(100, 150, 200)
            -- Just show found count
            targetHeaderText = string.format("%d", filteredTotalVisible)
        else
            -- All filter: check ACTUAL milestone completion using game's required count
            -- indexed = how many you've indexed, required = how many needed for milestone
            if indexed >= required and required > 0 then
                targetBarText = "Milestone Completed"
                targetBarColor = Color3.fromRGB(15, 255, 83)
                targetBarSize = UDim2.new(1, 0, 1, 0)
                targetBarBgColor = Color3.fromRGB(125, 240, 112)
            else
                -- Show progress, hide "0 left" by showing mutation name instead
                local missing = required - indexed
                if missing <= 0 then
                    -- Show current mutation name instead of "0 left"
                    local mutInfo = IndexData[currentMutation]
                    local mutName = currentMutation == "Default" and "Normal" or currentMutation
                    local displayName = mutInfo and mutInfo.DisplayText or mutName
                    targetBarText = displayName
                else
                    targetBarText = string.format("%d left", missing)
                end
                targetBarColor = Color3.new(1, 1, 1)
                targetBarSize = UDim2.new(math.clamp(indexed / math.max(required, 1), 0, 1), 0, 1, 0)
                targetBarBgColor = Color3.fromRGB(240, 186, 123)
            end
            -- Header shows indexed / total (not required)
            targetHeaderText = string.format("%d/%d", indexed, total)
        end

        -- FORCE apply bar values (game controller overwrites constantly)
        if barNumber.Text ~= targetBarText then
            barNumber.Text = targetBarText
        end
        barNumber.TextColor3 = targetBarColor

        if barLoading then
            barLoading.Size = targetBarSize
            barLoading.BackgroundColor3 = targetBarBgColor
        end

        -- FORCE apply header value if we have one
        if headerTotal and targetHeaderText and headerTotal.Text ~= targetHeaderText then
            headerTotal.Text = targetHeaderText
        end

        -- Fix description percentage - use math.floor for accurate % (75% not 76%)
        if descLabel then
            local mutInfo = IndexData[currentMutation]
            -- Calculate REAL percentage: required / total * 100, use FLOOR for accuracy
            local realPct = total > 0 and math.floor((required / total) * 100) or 100
            local mutName = currentMutation == "Default" and "Normal" or currentMutation
            local displayName = mutInfo and mutInfo.DisplayWithRichText or mutName
            local mainColor = mutInfo and mutInfo.MainColor or Color3.new(1, 1, 1)
            local isLimited = mutInfo and mutInfo.LimitedMutation

            local targetDesc
            if currentMutation == "Default" then
                targetDesc = string.format("Collect %d%% Normal Brainrots for +0.5x Base Multi", realPct)
            elseif currentMutation == "Halloween" then
                targetDesc = string.format("Collect %d%% %s Brainrots for a <font color=\"#%s\">%s Base</font>",
                    realPct, displayName, mainColor:ToHex(), displayName)
            else
                local multiText = (not isLimited) and "+0.5x Base Multi and " or ""
                targetDesc = string.format("Collect %d%% %s Brainrots for %sa <font color=\"#%s\">%s Base</font>",
                    realPct, displayName, multiText, mainColor:ToHex(), displayName)
            end

            -- Force update if game overwrote it
            if descLabel.Text ~= targetDesc then
                descLabel.Text = targetDesc
            end
        end
    end

    local function createCorner(parent, radius)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, radius or 8)
        corner.Parent = parent
        return corner
    end

    local function createStroke(parent, color, thickness)
        local stroke = Instance.new("UIStroke")
        stroke.Color = color or ACCENT_COLOR
        stroke.Thickness = thickness or 2
        stroke.Parent = parent
        return stroke
    end

    -- Update the selected mutation indicator label by cloning from button's TextLabel
    local function updateSelectedMutationLabel(mutationName, sourceTextLabel)
        if not selectedMutationLabel then
            return
        end

        -- Clean up old gradient animation
        if selectedMutationGradient then
            pcall(function()
                selectedMutationGradient()
            end)
            selectedMutationGradient = nil
        end

        -- Clean up any existing UIGradient child
        for _, child in pairs(selectedMutationLabel:GetChildren()) do
            if child:IsA("UIGradient") then
                child:Destroy()
            end
        end

        -- Default case
        if mutationName == "Default" then
            selectedMutationLabel.Text = "Normal"
            selectedMutationLabel.TextColor3 = Color3.new(1, 1, 1)
            return
        end

        -- Copy text from source TextLabel (RichText formatting with proper spacing)
        if sourceTextLabel then
            selectedMutationLabel.Text = sourceTextLabel.Text
            selectedMutationLabel.TextColor3 = sourceTextLabel.TextColor3
            selectedMutationLabel.RichText = sourceTextLabel.RichText
        else
            selectedMutationLabel.Text = mutationName
            selectedMutationLabel.TextColor3 = Color3.new(1, 1, 1)
        end

        -- Apply ANIMATED gradient using the game's Gradients module
        local mutInfo = IndexData[mutationName]
        if mutationName == "Rainbow" then
            pcall(function()
                selectedMutationGradient = Gradients.apply(selectedMutationLabel, "Rainbow")
            end)
        elseif mutationName == "Christmas" then
            -- Christmas uses GreenRed gradient (red/green animated)
            pcall(function()
                selectedMutationGradient = Gradients.apply(selectedMutationLabel, "GreenRed")
            end)
        elseif mutInfo and mutInfo.GradientPreset then
            pcall(function()
                selectedMutationGradient = Gradients.apply(selectedMutationLabel, mutInfo.GradientPreset)
            end)
        end
    end

    -- ============================================================================
    -- INDICATOR MANAGEMENT
    -- ============================================================================
    local function updateCardIndicator(card, animalName)
        if not card then
            return false
        end

        local indexed = isAnimalIndexed(animalName, currentMutation)

        -- ALWAYS show ALL labels (game hides them when not indexed)
        local nameLabel = card:FindFirstChild("NameLabel")
        if nameLabel then
            nameLabel.Visible = true
        end
        local mutationLabel = card:FindFirstChild("MutationLabel")
        if mutationLabel then
            mutationLabel.Visible = true
        end
        -- RarityLabel shows animal rarity (Common, Festive, etc.) - always visible
        local rarityLabel = card:FindFirstChild("RarityLabel")
        if rarityLabel then
            rarityLabel.Visible = true
        end

        -- "NOT INDEXED" indicator at TOP of card - SIMPLE RED
        local indicator = card:FindFirstChild("NotIndexedIndicator")
        if indexed then
            if indicator then
                indicator.Visible = false
            end
        else
            if not indicator then
                indicator = Instance.new("TextLabel")
                indicator.Name = "NotIndexedIndicator"
                indicator.Size = UDim2.new(1, 0, 0, 20)
                indicator.Position = UDim2.new(0, 0, 0, 0)
                indicator.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
                indicator.BackgroundTransparency = 0.15
                indicator.Text = "NOT INDEXED"
                indicator.TextColor3 = Color3.new(1, 1, 1)
                indicator.TextSize = 11
                indicator.Font = Enum.Font.GothamBold
                indicator.ZIndex = 100
                indicator.Parent = card
                createCorner(indicator, 3)
            end
            indicator.Visible = true
        end

        -- FORCE FIX BLACK SILHOUETTE - set ImageColor3 to WHITE on viewport
        local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
        if viewport then
            viewport.ImageColor3 = Color3.new(1, 1, 1)
        end

        return indexed
    end

    -- Get or create a Trove for a card (like game's v38 per card)
    local function getCardTrove(card)
        if not cardTroves[card] then
            cardTroves[card] = Trove.new()
        end
        return cardTroves[card]
    end

    -- Clean up mutation on a card using Trove (like game does with v38:Remove)
    local function cleanupMutationOnCard(card)
        if cardTroves[card] then
            pcall(function()
                cardTroves[card]:Clean()
            end)
            cardTroves[card] = nil
        end
        appliedMutations[card] = nil
    end

    -- Clean up ALL mutations on all cards
    local function cleanupAllMutations()
        for card, trove in pairs(cardTroves) do
            pcall(function()
                trove:Clean()
            end)
        end
        cardTroves = {}
        appliedMutations = {}
    end

    -- Forward declaration
    local applyMutationToAllVisibleCards

    -- Force apply mutation to all visible cards (fires the signal)
    local function forceApplyMutationToAllCards()
        if currentMutation == "Default" or currentMutation == "Normal" then
            return
        end
        -- Fire signal - all connected cards will update themselves
        MutationChanged:Fire(currentMutation)
    end

    -- STORE MODEL REFERENCES like the game does (v_u_58 in IndexController)
    -- Key: card, Value: model reference from AttachOnViewport
    local cardModelCache = setmetatable({}, {
        __mode = "k"
    }) -- Weak keys

    -- SCHEDULED UPDATES for cards that aren't visible when mutation changes
    -- Like game's scheduledUpdate mechanism in v_u_36
    -- Key: card, Value: function to call when card becomes visible
    local scheduledCardUpdates = setmetatable({}, {
        __mode = "k"
    }) -- Weak keys

    -- Apply mutation skin to a card's model using SharedAnimals:ApplyMutation
    -- Track pending mutations to debounce rapid calls (game has a bug with rapid re-applies)
    local pendingMutations = {}

    local function applyMutationToCard(card, animalName, mutation)
        -- DEBOUNCE: Prevent rapid re-applies which trigger game bug
        -- If this card already has a pending mutation, skip
        if pendingMutations[card] then
            return
        end

        -- Cleanup previous mutation trove if exists
        if cardTroves[card] then
            pcall(function()
                cardTroves[card]:Clean()
            end)
            cardTroves[card] = nil
        end

        -- UPDATE MUTATION LABEL TEXT (always, even for Default)
        local mutLabel = card:FindFirstChild("MutationLabel")
        if mutLabel then
            -- Clear existing gradient
            local existingGradient = mutLabel:FindFirstChildOfClass("UIGradient")
            if existingGradient then
                existingGradient:Destroy()
            end

            local mutData = IndexData[mutation]

            -- Apply styling like the game does (line 140-147 in IndexController)
            if mutation == "Rainbow" then
                mutLabel.RichText = false
                mutLabel.Text = "Rainbow"
                mutLabel.TextColor3 = Color3.new(1, 1, 1)
                pcall(function()
                    Gradients.apply(mutLabel, "Rainbow")
                end)
            elseif mutation == "Christmas" then
                mutLabel.RichText = false
                mutLabel.Text = "Christmas"
                mutLabel.TextColor3 = Color3.new(1, 1, 1)
                pcall(function()
                    Gradients.apply(mutLabel, "SlowGreenRed")
                end)
            elseif mutData and mutData.GradientPreset then
                mutLabel.RichText = false
                mutLabel.Text = mutData.DisplayText or mutation
                mutLabel.TextColor3 = Color3.new(1, 1, 1)
                pcall(function()
                    Gradients.apply(mutLabel, mutData.GradientPreset)
                end)
            elseif mutData and mutData.DisplayWithRichText then
                mutLabel.RichText = true
                mutLabel.Text = mutData.DisplayWithRichText
                mutLabel.TextColor3 = Color3.new(1, 1, 1)
            elseif mutData and mutData.MainColor then
                mutLabel.RichText = false
                mutLabel.Text = mutData.DisplayText or mutation
                mutLabel.TextColor3 = mutData.MainColor
            else
                mutLabel.RichText = false
                mutLabel.Text = (mutation == "Default" or mutation == "Normal") and "Normal" or mutation
                mutLabel.TextColor3 = Color3.new(1, 1, 1)
            end
        end

        -- ALWAYS ensure labels are visible (game sets NameLabel.Visible = v63 based on indexed)
        -- We override this to always show
        local nameLabel = card:FindFirstChild("NameLabel")
        if nameLabel then
            nameLabel.Visible = true
        end

        -- ALWAYS ensure viewport is WHITE (game sets ImageColor3 based on indexed - line 121)
        -- We override this to always be white
        local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
        if viewport then
            viewport.ImageColor3 = Color3.new(1, 1, 1) -- WHITE, not black silhouette
        end

        -- Don't apply visual mutation if Default/Normal
        if not card or mutation == "Default" or mutation == "Normal" then
            scheduledCardUpdates[card] = nil -- Clear any scheduled update
            return
        end

        if not viewport then
            -- No viewport at all - schedule update for when viewport is added
            scheduledCardUpdates[card] = function()
                applyMutationToCard(card, animalName, mutation)
            end
            return
        end

        -- Check if viewport is visible (parented to card) - game's culling system
        -- If not visible, schedule update for when it becomes visible
        if viewport.Parent ~= card then
            scheduledCardUpdates[card] = function()
                applyMutationToCard(card, animalName, mutation)
            end
            return
        end

        -- Clear scheduled update since we're applying now
        scheduledCardUpdates[card] = nil

        -- Get the STORED model reference (like game's v_u_58)
        -- If we don't have it cached, try to find it
        local model = cardModelCache[card]
        if not model or not model.Parent then
            -- Find model in viewport (could be in WorldModel or directly)
            local worldModel = viewport:FindFirstChildWhichIsA("WorldModel")
            if worldModel then
                model = worldModel:FindFirstChildWhichIsA("Model")
            else
                model = viewport:FindFirstChildWhichIsA("Model")
            end

            -- Cache it for future use
            if model then
                cardModelCache[card] = model
            end
        end

        -- If no model yet, the game might still be loading it async
        -- Wait for it briefly (game's AttachOnViewport is async)
        if not model then
            -- Try waiting for model to be added (up to 0.5 seconds)
            local waitStart = tick()
            local maxWait = 0.5
            while not model and (tick() - waitStart) < maxWait do
                task.wait(0.05)
                -- Check again
                local worldModel = viewport:FindFirstChildWhichIsA("WorldModel")
                if worldModel then
                    model = worldModel:FindFirstChildWhichIsA("Model")
                else
                    model = viewport:FindFirstChildWhichIsA("Model")
                end
                if model then
                    cardModelCache[card] = model
                end
            end
        end

        if not model then
            return
        end

        -- Get trove for this card (like game's v_u_39)
        local trove = getCardTrove(card)

        -- Mark as pending to debounce
        pendingMutations[card] = true

        -- Call SharedAnimals:ApplyMutation (like game's line 149)
        -- Game: v_u_54 = v_u_39:Add(v_u_16:ApplyMutation(v_u_58, v_u_47, v60, true))
        pcall(function()
            local cleanup = SharedAnimals:ApplyMutation(model, animalName, mutation, true)
            if cleanup then
                trove:Add(cleanup)
            end
        end)

        -- Clear pending after brief delay to allow next mutation
        task.delay(0.1, function()
            pendingMutations[card] = nil
        end)
    end

    -- Apply mutation to ALL visible cards - matches game behavior
    local function applyMutationToAllVisibleCards(mutationName)
        if not indexFrame then
            return
        end

        local mutData = IndexData[mutationName]
        local main = indexFrame:FindFirstChild("Main")
        if not main then
            return
        end

        local list = main:FindFirstChild("Content")
        if list then
            list = list:FindFirstChild("Holder")
        end
        if list then
            list = list:FindFirstChild("List")
        end
        if not list then
            return
        end

        for _, card in pairs(list:GetChildren()) do
            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                local animalName = card.Name
                -- ALWAYS apply - no caching, game resets models constantly
                applyMutationToCard(card, animalName, mutationName)
            end
        end
    end
    local function updateAllIndicators()
        for card, info in pairs(cardCache) do
            if card and card.Parent then
                updateCardIndicator(card, info.name)
                -- Also apply mutation if in Show All mode
                if showAllMode then
                    applyMutationToCard(card, info.name, currentMutation)
                end
            else
                cardCache[card] = nil
            end
        end
    end

    -- ============================================================================
    -- CARD VISIBILITY (for filters)
    -- ============================================================================
    local function shouldCardBeVisible(animalName)
        -- Admin animals (hidden by default in Index) - ONLY show if Show Admin is ON
        -- Show All does NOT affect admin animals - they need Show Admin specifically
        if wasOriginallyHidden(animalName) then
            return showAdminAnimals
        end

        -- Search filter
        if currentSearch ~= "" then
            local searchLower = currentSearch:lower()
            if not animalName:lower():find(searchLower, 1, true) then
                return false
            end
        end

        -- Index filter
        if currentFilter == FILTER_ALL then
            return true
        end

        local indexed = isAnimalIndexed(animalName, currentMutation)
        if currentFilter == FILTER_INDEXED then
            return indexed
        else -- UNINDEXED
            return not indexed
        end
    end

    local function applyFilters(list)
        if not list then
            return
        end

        local visibleCount = 0
        local visibleIndexedCount = 0
        local visibleUnindexedCount = 0
        local totalPassingBaseFilters = 0

        for _, card in pairs(list:GetChildren()) do
            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                local animalName = card.Name

                -- EARLY VIEWPORT CACHING: Grab viewport ref BEFORE game can unparent it!
                local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
                if viewport and not viewportCache[card] then
                    viewportCache[card] = viewport
                end

                -- Cache card if not cached (also store original visibility)
                -- IMPORTANT: Only cache originalVisible on FIRST encounter before we modify it
                if not cardCache[card] then
                    -- First time seeing this card - get its TRUE original visibility from game
                    cardCache[card] = {
                        name = animalName,
                        originalVisible = card.Visible
                    }
                elseif cardCache[card].originalVisible == nil then
                    -- Cache exists but no visibility stored yet
                    cardCache[card].originalVisible = card.Visible
                end

                -- Update indicator (includes shadow fix and NameLabel visibility)
                local indexed = updateCardIndicator(card, animalName)
                -- Ensure indexed is boolean
                indexed = indexed == true

                -- Check if this is an admin animal (multiple ways to detect)
                local isAdminAnimal = (cardCache[card] and cardCache[card].isAdminAnimal) or
                                          wasOriginallyHidden(animalName) or card:GetAttribute("IndexV2_AdminAnimal")

                -- Update cache if we detected it's an admin animal
                if isAdminAnimal and cardCache[card] then
                    cardCache[card].isAdminAnimal = true
                end

                -- ADMIN ANIMALS: Only show if showAdminAnimals is ON (independent of Show All!)
                if isAdminAnimal then
                    if showAdminAnimals then
                        -- Admin animal: show ALL, only filter by search
                        local shouldShow = true

                        -- Apply search filter only
                        if currentSearch and currentSearch ~= "" then
                            local searchLower = currentSearch:lower()
                            local displayName = animalName
                            local nameLabel = card:FindFirstChild("NameLabel")
                            if nameLabel and nameLabel:IsA("TextLabel") then
                                displayName = nameLabel.Text
                            end
                            if not animalName:lower():find(searchLower, 1, true) and
                                not displayName:lower():find(searchLower, 1, true) then
                                shouldShow = false
                            end
                        end

                        card.Visible = shouldShow
                    else
                        -- Hide admin animals when Show Admin is OFF
                        card.Visible = false
                    end
                    -- Count visible admin animals
                    if card.Visible then
                        visibleCount = visibleCount + 1
                    end
                else
                    -- REGULAR ANIMALS - normal filter logic
                    -- Determine base visibility (before index filter)
                    local passesBaseFilters = true

                    -- SEARCH: Hide cards that don't match search text
                    if passesBaseFilters and currentSearch and currentSearch ~= "" then
                        local searchLower = currentSearch:lower()
                        local displayName = animalName
                        -- Also check NameLabel for display name
                        local nameLabel = card:FindFirstChild("NameLabel")
                        if nameLabel and nameLabel:IsA("TextLabel") then
                            displayName = nameLabel.Text
                        end
                        -- Match against both internal name and display name
                        if not animalName:lower():find(searchLower, 1, true) and
                            not displayName:lower():find(searchLower, 1, true) then
                            passesBaseFilters = false
                        end
                    end

                    -- Count cards that pass base filters (for reference)
                    if passesBaseFilters then
                        totalPassingBaseFilters = totalPassingBaseFilters + 1
                    end

                    -- Determine final visibility (after index filter)
                    local shouldShow = passesBaseFilters

                    -- INDEX FILTER: Apply in ALL modes (not just Show All)
                    if shouldShow and currentFilter ~= FILTER_ALL then
                        if currentFilter == FILTER_INDEXED then
                            shouldShow = indexed
                        elseif currentFilter == FILTER_UNINDEXED then
                            shouldShow = not indexed
                        end
                    end

                    -- Apply visibility
                    if showAllMode then
                        -- Show All mode: we control everything, show all cards that match filters
                        card.Visible = shouldShow
                        if shouldShow and currentMutation ~= "Default" and currentMutation ~= "Normal" then
                            applyMutationToCard(card, animalName, currentMutation)
                        end
                    else
                        -- Normal mode: act like the game
                        local isInjected = cardCache[card] and cardCache[card].isInjected

                        -- Determine visibility
                        if isInjected then
                            -- Injected cards only show when Show All is ON
                            card.Visible = false
                        elseif showAllMode then
                            -- Show All ON: show ALL animals in database
                            card.Visible = shouldShow
                        else
                            -- Show All OFF: Game behavior - only show animals that exist in mutation's Index
                            local existsInMutation = animalExistsInMutationIndex(animalName, currentMutation)
                            -- Must exist in mutation AND pass filters
                            card.Visible = existsInMutation and shouldShow
                        end
                    end

                    -- Count VISIBLE cards by indexed state
                    if card.Visible then
                        visibleCount = visibleCount + 1
                        if indexed then
                            visibleIndexedCount = visibleIndexedCount + 1
                        else
                            visibleUnindexedCount = visibleUnindexedCount + 1
                        end
                    end
                end -- end REGULAR ANIMALS else block
            end
        end

        -- Update global filtered counts for counter display
        -- These now reflect VISIBLE cards only!
        filteredIndexedCount = visibleIndexedCount
        filteredUnindexedCount = visibleUnindexedCount
        filteredTotalVisible = visibleCount

        return visibleCount, totalPassingBaseFilters, visibleIndexedCount, visibleUnindexedCount
    end

    -- ============================================================================
    -- CREATE TOP BAR (Title + Search + Filters) - ABOVE the Index UI
    -- ============================================================================
    local function createTopBar(indexFrame)
        if indexFrame:FindFirstChild("IndexV2TopBar") then
            return indexFrame:FindFirstChild("IndexV2TopBar")
        end

        local main = indexFrame:FindFirstChild("Main")
        if not main then
            return nil
        end

        local bar = Instance.new("Frame")
        bar.Name = "IndexV2TopBar"
        bar.Size = UDim2.new(1, 0, 0, 50)
        bar.Position = UDim2.new(0, 0, 0, -55)
        bar.BackgroundColor3 = BG_COLOR
        bar.BorderSizePixel = 0
        bar.ZIndex = 100
        bar.Parent = indexFrame
        createCorner(bar, 10)
        createStroke(bar, ACCENT_COLOR, 2)

        -- UNLOAD button (X) - leftmost for quick access
        local unloadBtn = Instance.new("TextButton")
        unloadBtn.Name = "UnloadBtn"
        unloadBtn.Size = UDim2.new(0, 36, 0, 36)
        unloadBtn.Position = UDim2.new(0, 8, 0.5, 0)
        unloadBtn.AnchorPoint = Vector2.new(0, 0.5)
        unloadBtn.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
        unloadBtn.BorderSizePixel = 0
        unloadBtn.Text = "✕"
        unloadBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
        unloadBtn.TextSize = 20
        unloadBtn.Font = Enum.Font.GothamBold
        unloadBtn.ZIndex = 101
        unloadBtn.Parent = bar
        createCorner(unloadBtn, 6)

        -- Unload the entire Index V2 system
        unloadBtn.MouseButton1Click:Connect(function()
            print("[Index V2] 🚫 Unloading...")
            -- Clean up spawned animals
            cleanupAllSpawnedAnimals()
            -- Clean up spawn panel
            if spawnPanelUI and spawnPanelUI.screenGui then
                spawnPanelUI.screenGui:Destroy()
                spawnPanelUI = nil
            end
            spawnModeEnabled = false
            -- Destroy the top bar and modifications
            if bar then
                bar:Destroy()
            end
            -- Restore original Index UI if needed
            local mutPanel = main:FindFirstChild("MutationSidePanel")
            if mutPanel then
                mutPanel:Destroy()
            end
            -- Reset filters
            currentFilter = FILTER_ALL
            currentSearch = ""
            -- Reset visibility of all items
            local list = main:FindFirstChild("Content")
            if list then
                list = list:FindFirstChild("Holder")
            end
            if list then
                list = list:FindFirstChild("List")
            end
            if list then
                for _, child in ipairs(list:GetChildren()) do
                    if child:IsA("GuiObject") then
                        child.Visible = true
                    end
                end
            end
            print("[Index V2] ✅ Unloaded!")
        end)

        -- Title "Index V2 by"
        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.Size = UDim2.new(0, 110, 1, 0)
        title.Position = UDim2.new(0, 52, 0, 0)
        title.BackgroundTransparency = 1
        title.Text = "📚 Index V2 by"
        title.TextColor3 = ACCENT_COLOR
        title.TextSize = 18
        title.Font = Enum.Font.GothamBlack
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.ZIndex = 101
        title.Parent = bar

        -- "xAstroBoy" with Admin gradient (game style!)
        local authorLabel = Instance.new("TextLabel")
        authorLabel.Name = "Author"
        authorLabel.Size = UDim2.new(0, 75, 1, 0)
        authorLabel.Position = UDim2.new(0, 162, 0, 0)
        authorLabel.BackgroundTransparency = 1
        authorLabel.Text = "xAstroBoy"
        authorLabel.TextColor3 = Color3.new(1, 1, 1)
        authorLabel.TextSize = 18
        authorLabel.Font = Enum.Font.GothamBlack
        authorLabel.TextXAlignment = Enum.TextXAlignment.Left
        authorLabel.ZIndex = 101
        authorLabel.Parent = bar

        -- Add UIStroke like game does for rarity labels with gradients
        local authorStroke = Instance.new("UIStroke")
        authorStroke.Thickness = 1.5
        authorStroke.Color = Color3.new(0, 0, 0)
        authorStroke.Parent = authorLabel

        -- Apply Admin gradient using game's RaritiesData.Admin.GradientPreset
        local authorGradient
        pcall(function()
            local adminRarity = RaritiesData.Admin
            if adminRarity and adminRarity.GradientPreset then
                authorGradient = Gradients.apply(authorLabel, adminRarity.GradientPreset)
            end
        end)

        -- Search box - fills space between author label and filter buttons
        local searchBox = Instance.new("TextBox")
        searchBox.Name = "SearchBox"
        -- Position after xAstroBoy (250), leave room for 3 filter buttons
        searchBox.Size = UDim2.new(1, -250 - 280, 0, 34)
        searchBox.Position = UDim2.new(0, 250, 0.5, 0)
        searchBox.AnchorPoint = Vector2.new(0, 0.5)
        searchBox.BackgroundColor3 = Color3.fromRGB(45, 45, 50)
        searchBox.BorderSizePixel = 0
        searchBox.Text = ""
        searchBox.PlaceholderText = "🔍 Search animals..."
        searchBox.TextColor3 = Color3.new(1, 1, 1)
        searchBox.PlaceholderColor3 = Color3.fromRGB(140, 140, 140)
        searchBox.TextSize = 15
        searchBox.Font = Enum.Font.Gotham
        searchBox.TextXAlignment = Enum.TextXAlignment.Left
        searchBox.ClearTextOnFocus = false
        searchBox.ZIndex = 101
        searchBox.Parent = bar
        createCorner(searchBox, 8)
        createStroke(searchBox, Color3.fromRGB(80, 80, 90), 1)

        -- Add padding for text
        local searchPadding = Instance.new("UIPadding")
        searchPadding.PaddingLeft = UDim.new(0, 8)
        searchPadding.Parent = searchBox

        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            currentSearch = searchBox.Text
            local list = main:FindFirstChild("Content")
            if list then
                list = list:FindFirstChild("Holder")
            end
            if list then
                list = list:FindFirstChild("List")
            end
            if list then
                applyFilters(list)
            end
        end)

        -- Filter buttons (right side) with colored text
        local filters = {FILTER_ALL, FILTER_UNINDEXED, FILTER_INDEXED}
        local filterTextColors = {
            [FILTER_ALL] = Color3.fromRGB(100, 180, 255), -- Blue
            [FILTER_UNINDEXED] = Color3.fromRGB(255, 100, 100), -- Red
            [FILTER_INDEXED] = Color3.fromRGB(100, 255, 100) -- Green
        }
        local filterBtns = {}

        for i, filterName in ipairs(filters) do
            local btn = Instance.new("TextButton")
            btn.Name = filterName
            btn.Size = UDim2.new(0, 85, 0, 30)
            -- Position from right: Indexed at -8, Unindexed at -98, All at -188
            btn.Position = UDim2.new(1, -8 - (3 - i) * 90, 0.5, 0)
            btn.AnchorPoint = Vector2.new(1, 0.5)
            btn.BackgroundColor3 = filterName == FILTER_ALL and Color3.fromRGB(60, 80, 60) or Color3.fromRGB(45, 50, 55)
            btn.BorderSizePixel = 0
            btn.Text = filterName
            btn.TextColor3 = filterTextColors[filterName]
            btn.TextScaled = false
            btn.TextSize = 15
            btn.Font = Enum.Font.GothamBold
            btn.ZIndex = 101
            btn.Parent = bar
            createCorner(btn, 6)

            filterBtns[filterName] = btn

            btn.MouseButton1Click:Connect(function()
                currentFilter = filterName
                for name, b in pairs(filterBtns) do
                    b.BackgroundColor3 = name == filterName and Color3.fromRGB(60, 80, 60) or Color3.fromRGB(45, 50, 55)
                end
                local list = main:FindFirstChild("Content")
                if list then
                    list = list:FindFirstChild("Holder")
                end
                if list then
                    list = list:FindFirstChild("List")
                end
                if list then
                    applyFilters(list)
                end
            end)
        end

        return bar
    end

    -- ============================================================================
    -- CREATE SPAWN PANEL (Client-Side Animal Spawner)
    -- ============================================================================
    local function createSpawnPanel(indexFrame)
        -- Check if we already have a REAL spawn panel (with .panel property)
        if spawnPanelUI and spawnPanelUI.panel then
            return spawnPanelUI
        end

        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not playerGui then
            return nil
        end

        -- Create ScreenGui for spawn panel (separate from Index UI for dragging)
        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = "IndexV2_SpawnPanel"
        screenGui.ResetOnSpawn = false
        screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        screenGui.Parent = playerGui

        -- Main panel frame
        local panel = Instance.new("Frame")
        panel.Name = "SpawnPanel"
        panel.Size = UDim2.new(0, 310, 0, 620) -- Wider and taller for better layout

        -- Load saved position or use default center
        local savedPos = loadSpawnPanelPosition()
        if savedPos and savedPos.X and savedPos.Y then
            panel.Position = UDim2.new(0, savedPos.X, 0, savedPos.Y)
            panel.AnchorPoint = Vector2.new(0, 0)
        else
            panel.Position = UDim2.new(0.5, 0, 0.5, 0)
            panel.AnchorPoint = Vector2.new(0.5, 0.5)
        end

        panel.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        panel.BorderSizePixel = 0
        panel.Visible = false -- Hidden by default
        panel.ZIndex = 200
        panel.Parent = screenGui
        createCorner(panel, 12)
        createStroke(panel, Color3.fromRGB(100, 200, 100), 3)

        -- Make panel draggable
        local dragging = false
        local dragStart, startPos

        panel.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                dragStart = input.Position
                startPos = panel.Position
            end
        end)

        panel.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = false
                -- Save position when drag ends
                saveSpawnPanelPosition(panel.Position)
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local delta = input.Position - dragStart
                -- Switch to absolute positioning when dragging
                panel.AnchorPoint = Vector2.new(0, 0)
                panel.Position = UDim2.new(0, startPos.X.Offset + delta.X +
                    (startPos.X.Scale * panel.Parent.AbsoluteSize.X), 0, startPos.Y.Offset + delta.Y +
                    (startPos.Y.Scale * panel.Parent.AbsoluteSize.Y))
            end
        end)

        -- Header
        local header = Instance.new("Frame")
        header.Name = "Header"
        header.Size = UDim2.new(1, 0, 0, 40)
        header.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
        header.BorderSizePixel = 0
        header.ZIndex = 201
        header.Parent = panel
        createCorner(header, 12)

        -- Header bottom fix
        local headerFix = Instance.new("Frame")
        headerFix.Size = UDim2.new(1, 0, 0, 12)
        headerFix.Position = UDim2.new(0, 0, 1, -12)
        headerFix.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
        headerFix.BorderSizePixel = 0
        headerFix.ZIndex = 201
        headerFix.Parent = header

        local headerLabel = Instance.new("TextLabel")
        headerLabel.Size = UDim2.new(1, -40, 1, 0)
        headerLabel.BackgroundTransparency = 1
        headerLabel.Text = "🐾 SPAWN IN BASE"
        headerLabel.TextColor3 = Color3.new(0, 0, 0)
        headerLabel.TextSize = 16
        headerLabel.Font = Enum.Font.GothamBlack
        headerLabel.ZIndex = 202
        headerLabel.Parent = header

        -- Close button
        local closeBtn = Instance.new("TextButton")
        closeBtn.Name = "CloseBtn"
        closeBtn.Size = UDim2.new(0, 30, 0, 30)
        closeBtn.Position = UDim2.new(1, -35, 0.5, 0)
        closeBtn.AnchorPoint = Vector2.new(0, 0.5)
        closeBtn.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
        closeBtn.BorderSizePixel = 0
        closeBtn.Text = "✕"
        closeBtn.TextColor3 = Color3.new(1, 1, 1)
        closeBtn.TextSize = 18
        closeBtn.Font = Enum.Font.GothamBold
        closeBtn.ZIndex = 203
        closeBtn.Parent = header
        createCorner(closeBtn, 6)

        closeBtn.MouseButton1Click:Connect(function()
            panel.Visible = false
            spawnModeEnabled = false
        end)

        -- Content container
        local content = Instance.new("Frame")
        content.Name = "Content"
        content.Size = UDim2.new(1, -16, 1, -56)
        content.Position = UDim2.new(0.5, 0, 0, 48)
        content.AnchorPoint = Vector2.new(0.5, 0)
        content.BackgroundTransparency = 1
        content.ZIndex = 201
        content.Parent = panel

        -- Status label
        local statusLabel = Instance.new("TextLabel")
        statusLabel.Name = "StatusLabel"
        statusLabel.Size = UDim2.new(1, 0, 0, 25)
        statusLabel.Position = UDim2.new(0, 0, 0, 0)
        statusLabel.BackgroundTransparency = 1
        statusLabel.Text = "Click any card to spawn!"
        statusLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
        statusLabel.TextSize = 14
        statusLabel.Font = Enum.Font.GothamBold
        statusLabel.ZIndex = 202
        statusLabel.Parent = content

        -- Podium selection label
        local podiumLabel = Instance.new("TextLabel")
        podiumLabel.Name = "PodiumLabel"
        podiumLabel.Size = UDim2.new(1, 0, 0, 20)
        podiumLabel.Position = UDim2.new(0, 0, 0, 30)
        podiumLabel.BackgroundTransparency = 1
        podiumLabel.Text = "Select Podiums (click to toggle):"
        podiumLabel.TextColor3 = Color3.new(1, 1, 1)
        podiumLabel.TextSize = 13
        podiumLabel.Font = Enum.Font.GothamBold
        podiumLabel.TextXAlignment = Enum.TextXAlignment.Left
        podiumLabel.ZIndex = 202
        podiumLabel.Parent = content

        -- Podium scroll frame
        local podiumScroll = Instance.new("ScrollingFrame")
        podiumScroll.Name = "PodiumScroll"
        podiumScroll.Size = UDim2.new(1, 0, 0, 42)
        podiumScroll.Position = UDim2.new(0, 0, 0, 52)
        podiumScroll.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        podiumScroll.BorderSizePixel = 0
        podiumScroll.ScrollBarThickness = 4
        podiumScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 200, 100)
        podiumScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        podiumScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
        podiumScroll.ScrollingDirection = Enum.ScrollingDirection.X
        podiumScroll.ZIndex = 202
        podiumScroll.Parent = content
        createCorner(podiumScroll, 6)

        local podiumLayout = Instance.new("UIListLayout")
        podiumLayout.FillDirection = Enum.FillDirection.Horizontal
        podiumLayout.SortOrder = Enum.SortOrder.LayoutOrder
        podiumLayout.Padding = UDim.new(0, 4)
        podiumLayout.Parent = podiumScroll

        local podiumPadding = Instance.new("UIPadding")
        podiumPadding.PaddingLeft = UDim.new(0, 4)
        podiumPadding.PaddingTop = UDim.new(0, 4)
        podiumPadding.PaddingBottom = UDim.new(0, 4)
        podiumPadding.Parent = podiumScroll

        -- Podium buttons storage
        local podiumButtons = {}

        -- Function to check if a podium is selected
        local function isPodiumSelected(idx)
            for _, selIdx in ipairs(selectedPodiumIndices) do
                if selIdx == idx then
                    return true
                end
            end
            return false
        end

        -- Function to update podium button styles
        local function updatePodiumButtonStyles()
            for idx, btn in pairs(podiumButtons) do
                if spawnAllPodiums then
                    btn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
                    btn.TextColor3 = Color3.new(0, 0, 0)
                elseif isPodiumSelected(idx) then
                    btn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
                    btn.TextColor3 = Color3.new(0, 0, 0)
                else
                    btn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                    btn.TextColor3 = Color3.new(1, 1, 1)
                end
            end
        end

        -- Function to refresh podium list
        local function refreshPodiumList()
            -- Clear existing buttons
            for _, btn in pairs(podiumButtons) do
                btn:Destroy()
            end
            podiumButtons = {}

            -- Debug: Print plot info
            local plot = getMyPlot()
            if plot then
                print("[IndexV2 Spawn] Found plot:", plot.Name, "Owner:", plot:GetAttribute("Owner"))
                local animalPodiums = plot:FindFirstChild("AnimalPodiums")
                if animalPodiums then
                    print("[IndexV2 Spawn] Found AnimalPodiums with", #animalPodiums:GetChildren(), "children")
                else
                    print("[IndexV2 Spawn] No AnimalPodiums folder found in plot!")
                    -- List what's in the plot
                    for _, child in ipairs(plot:GetChildren()) do
                        print("[IndexV2 Spawn]   - " .. child.Name .. " (" .. child.ClassName .. ")")
                    end
                end
            else
                print("[IndexV2 Spawn] No plot found! Looking for owner:", LocalPlayer.Name)
            end

            local podiums = getMyPodiums()
            print("[IndexV2 Spawn] Found", #podiums, "podiums")

            if #podiums == 0 then
                local noPodimsLabel = Instance.new("TextLabel")
                noPodimsLabel.Name = "NoPodiums"
                noPodimsLabel.Size = UDim2.new(0, 200, 0, 30)
                noPodimsLabel.BackgroundTransparency = 1
                noPodimsLabel.Text = "No podiums! Go to your base."
                noPodimsLabel.TextColor3 = Color3.fromRGB(255, 150, 150)
                noPodimsLabel.TextSize = 11
                noPodimsLabel.Font = Enum.Font.GothamBold
                noPodimsLabel.ZIndex = 203
                noPodimsLabel.Parent = podiumScroll
                podiumButtons[0] = noPodimsLabel
                return
            end

            -- Clean up invalid selections from multi-select array
            local validIndices = {}
            for _, selIdx in ipairs(selectedPodiumIndices) do
                for _, p in ipairs(podiums) do
                    if p.index == selIdx then
                        table.insert(validIndices, selIdx)
                        break
                    end
                end
            end
            selectedPodiumIndices = validIndices

            -- Default to first podium if nothing selected
            if #selectedPodiumIndices == 0 and #podiums > 0 then
                table.insert(selectedPodiumIndices, podiums[1].index)
                selectedPodiumIndex = podiums[1].index -- Keep legacy var in sync
            end

            -- Create buttons for each podium
            for i, p in ipairs(podiums) do
                local btn = Instance.new("TextButton")
                btn.Name = "Podium_" .. p.index
                btn.Size = UDim2.new(0, 40, 0, 30)
                btn.LayoutOrder = i
                btn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                btn.BorderSizePixel = 0
                btn.Text = tostring(p.index)
                btn.TextColor3 = Color3.new(1, 1, 1)
                btn.TextSize = 14
                btn.Font = Enum.Font.GothamBold
                btn.ZIndex = 203
                btn.Parent = podiumScroll
                createCorner(btn, 6)

                podiumButtons[p.index] = btn

                btn.MouseButton1Click:Connect(function()
                    spawnAllPodiums = false

                    -- Toggle this podium in the selection (click to add/remove)
                    local found = false
                    for i, selIdx in ipairs(selectedPodiumIndices) do
                        if selIdx == p.index then
                            table.remove(selectedPodiumIndices, i)
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(selectedPodiumIndices, p.index)
                    end

                    -- Update legacy var to last selected
                    if #selectedPodiumIndices > 0 then
                        selectedPodiumIndex = selectedPodiumIndices[#selectedPodiumIndices]
                    end

                    updatePodiumButtonStyles()
                end)
            end

            updatePodiumButtonStyles()
        end

        -- Select All / Deselect All toggle button for podiums
        local selectAllPodimsBtn = Instance.new("TextButton")
        selectAllPodimsBtn.Name = "SelectAllPodimsBtn"
        selectAllPodimsBtn.Size = UDim2.new(1, 0, 0, 24)
        selectAllPodimsBtn.Position = UDim2.new(0, 0, 0, 96)
        selectAllPodimsBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
        selectAllPodimsBtn.BorderSizePixel = 0
        selectAllPodimsBtn.Text = "☑️ Select All Podiums"
        selectAllPodimsBtn.TextColor3 = Color3.new(1, 1, 1)
        selectAllPodimsBtn.TextSize = 12
        selectAllPodimsBtn.Font = Enum.Font.GothamBold
        selectAllPodimsBtn.ZIndex = 202
        selectAllPodimsBtn.Parent = content
        createCorner(selectAllPodimsBtn, 6)

        local function updateSelectAllPodimsBtn()
            local podiums = getMyPodiums()
            local allSelected = #selectedPodiumIndices >= #podiums and #podiums > 0
            if allSelected then
                selectAllPodimsBtn.Text = "☐ Deselect All Podiums"
                selectAllPodimsBtn.BackgroundColor3 = Color3.fromRGB(120, 80, 60)
            else
                selectAllPodimsBtn.Text = "☑️ Select All Podiums"
                selectAllPodimsBtn.BackgroundColor3 = Color3.fromRGB(60, 80, 120)
            end
        end

        selectAllPodimsBtn.MouseButton1Click:Connect(function()
            local podiums = getMyPodiums()
            local allSelected = #selectedPodiumIndices >= #podiums and #podiums > 0
            if allSelected then
                -- Deselect all
                selectedPodiumIndices = {}
            else
                -- Select all
                selectedPodiumIndices = {}
                for _, p in ipairs(podiums) do
                    table.insert(selectedPodiumIndices, p.index)
                end
            end
            updatePodiumButtonStyles()
            updateSelectAllPodimsBtn()
        end)

        -- Spawn All toggle
        local spawnAllBtn = Instance.new("TextButton")
        spawnAllBtn.Name = "SpawnAllToggle"
        spawnAllBtn.Size = UDim2.new(1, 0, 0, 28)
        spawnAllBtn.Position = UDim2.new(0, 0, 0, 124)
        spawnAllBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
        spawnAllBtn.BorderSizePixel = 0
        spawnAllBtn.Text = "📍 Spawn on ALL Podiums"
        spawnAllBtn.TextColor3 = Color3.new(1, 1, 1)
        spawnAllBtn.TextSize = 13
        spawnAllBtn.Font = Enum.Font.GothamBold
        spawnAllBtn.ZIndex = 202
        spawnAllBtn.Parent = content
        createCorner(spawnAllBtn, 6)

        local function updateSpawnAllButton()
            if spawnAllPodiums then
                spawnAllBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
                spawnAllBtn.TextColor3 = Color3.new(0, 0, 0)
                spawnAllBtn.Text = "📍 Spawn on ALL Podiums ✓"
            else
                spawnAllBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                spawnAllBtn.TextColor3 = Color3.new(1, 1, 1)
                spawnAllBtn.Text = "📍 Spawn on ALL Podiums"
            end
            updatePodiumButtonStyles()
        end

        spawnAllBtn.MouseButton1Click:Connect(function()
            spawnAllPodiums = not spawnAllPodiums
            updateSpawnAllButton()
        end)

        -- Clear All button
        local clearBtn = Instance.new("TextButton")
        clearBtn.Name = "ClearAllBtn"
        clearBtn.Size = UDim2.new(1, 0, 0, 28)
        clearBtn.Position = UDim2.new(0, 0, 0, 158)
        clearBtn.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
        clearBtn.BorderSizePixel = 0
        clearBtn.Text = "🗑️ Clear All Spawned"
        clearBtn.TextColor3 = Color3.new(1, 1, 1)
        clearBtn.TextSize = 13
        clearBtn.Font = Enum.Font.GothamBold
        clearBtn.ZIndex = 202
        clearBtn.Parent = content
        createCorner(clearBtn, 6)

        clearBtn.MouseButton1Click:Connect(function()
            cleanupAllSpawnedAnimals()
            clearBtn.Text = "✅ Cleared!"
            task.delay(1, function()
                clearBtn.Text = "🗑️ Clear All Spawned"
            end)
        end)

        -- Refresh podiums button
        local refreshBtn = Instance.new("TextButton")
        refreshBtn.Name = "RefreshBtn"
        refreshBtn.Size = UDim2.new(1, 0, 0, 28)
        refreshBtn.Position = UDim2.new(0, 0, 0, 192)
        refreshBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 200)
        refreshBtn.BorderSizePixel = 0
        refreshBtn.Text = "🔄 Refresh Podiums"
        refreshBtn.TextColor3 = Color3.new(1, 1, 1)
        refreshBtn.TextSize = 13
        refreshBtn.Font = Enum.Font.GothamBold
        refreshBtn.ZIndex = 202
        refreshBtn.Parent = content
        createCorner(refreshBtn, 6)

        refreshBtn.MouseButton1Click:Connect(function()
            refreshPodiumList()
            refreshBtn.Text = "✅ Refreshed!"
            task.delay(1, function()
                refreshBtn.Text = "🔄 Refresh Podiums"
            end)
        end)

        -- ====== TRAITS SECTION ======
        local traitsLabel = Instance.new("TextLabel")
        traitsLabel.Name = "TraitsLabel"
        traitsLabel.Size = UDim2.new(1, 0, 0, 18)
        traitsLabel.Position = UDim2.new(0, 0, 0, 230)
        traitsLabel.BackgroundTransparency = 1
        traitsLabel.Text = "🔮 TRAITS (click to toggle):"
        traitsLabel.TextColor3 = Color3.fromRGB(200, 150, 255)
        traitsLabel.TextSize = 13
        traitsLabel.TextXAlignment = Enum.TextXAlignment.Left
        traitsLabel.Font = Enum.Font.GothamBold
        traitsLabel.ZIndex = 202
        traitsLabel.Parent = content

        -- Traits scroll frame
        local traitsScroll = Instance.new("ScrollingFrame")
        traitsScroll.Name = "TraitsScroll"
        traitsScroll.Size = UDim2.new(1, 0, 0, 200) -- Taller for bigger icon buttons
        traitsScroll.Position = UDim2.new(0, 0, 0, 252)
        traitsScroll.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        traitsScroll.BorderSizePixel = 0
        traitsScroll.ScrollBarThickness = 6
        traitsScroll.ScrollBarImageColor3 = Color3.fromRGB(150, 100, 200)
        traitsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        traitsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        traitsScroll.ZIndex = 202
        traitsScroll.Parent = content
        createCorner(traitsScroll, 6)

        local traitsGrid = Instance.new("UIGridLayout")
        traitsGrid.CellSize = UDim2.new(0.23, 0, 0, 78) -- 23% width = ~4 per row with padding
        traitsGrid.CellPadding = UDim2.new(0.01, 0, 0, 6) -- 1% horizontal padding
        traitsGrid.FillDirection = Enum.FillDirection.Horizontal
        traitsGrid.HorizontalAlignment = Enum.HorizontalAlignment.Center
        traitsGrid.SortOrder = Enum.SortOrder.Name
        traitsGrid.Parent = traitsScroll

        local traitsPadding = Instance.new("UIPadding")
        traitsPadding.PaddingTop = UDim.new(0, 5)
        traitsPadding.PaddingLeft = UDim.new(0, 5)
        traitsPadding.PaddingRight = UDim.new(0, 5)
        traitsPadding.PaddingBottom = UDim.new(0, 5)
        traitsPadding.Parent = traitsScroll

        -- Get traits data from game
        local TraitsData = nil
        pcall(function()
            TraitsData = require(game:GetService("ReplicatedStorage").Datas.Traits)
        end)

        local traitButtons = {}

        local function updateTraitButtonStyle(traitName, btn)
            local isSelected = false
            for _, t in ipairs(selectedTraits) do
                if t == traitName then
                    isSelected = true
                    break
                end
            end

            local traitInfo = TraitsData and TraitsData[traitName]
            local traitColor = (traitInfo and traitInfo.Color) or Color3.fromRGB(150, 150, 150)

            -- Update background and selection indicator
            if isSelected then
                btn.BackgroundColor3 = traitColor
                btn.ImageColor3 = Color3.new(1, 1, 1) -- Keep icon white/visible when selected
                -- Show checkmark on selection
                local checkmark = btn:FindFirstChild("Checkmark")
                if checkmark then
                    checkmark.Visible = true
                end
                local nameLabel = btn:FindFirstChild("TraitName")
                if nameLabel then
                    nameLabel.TextColor3 = Color3.new(1, 1, 1)
                end -- White text on colored bg
            else
                btn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                btn.ImageColor3 = Color3.new(1, 1, 1) -- Normal white icon
                local checkmark = btn:FindFirstChild("Checkmark")
                if checkmark then
                    checkmark.Visible = false
                end
                local nameLabel = btn:FindFirstChild("TraitName")
                if nameLabel then
                    nameLabel.TextColor3 = traitColor
                end
            end
        end

        local function updateAllTraitButtons()
            for traitName, btn in pairs(traitButtons) do
                updateTraitButtonStyle(traitName, btn)
            end
            -- Update label to show count
            if #selectedTraits > 0 then
                traitsLabel.Text = "🔮 TRAITS (" .. #selectedTraits .. " selected):"
            else
                traitsLabel.Text = "🔮 TRAITS (click to toggle):"
            end
        end

        -- Forward declaration for select all button update
        local updateSelectAllButton

        local function toggleTrait(traitName)
            local found = false
            for i, t in ipairs(selectedTraits) do
                if t == traitName then
                    table.remove(selectedTraits, i)
                    found = true
                    break
                end
            end
            if not found then
                table.insert(selectedTraits, traitName)
            end
            updateAllTraitButtons()
            if updateSelectAllButton then
                updateSelectAllButton()
            end
        end

        -- Create trait buttons with icons
        if TraitsData then
            local sortedTraits = {}
            for traitName, _ in pairs(TraitsData) do
                table.insert(sortedTraits, traitName)
            end
            table.sort(sortedTraits)

            for _, traitName in ipairs(sortedTraits) do
                local traitInfo = TraitsData[traitName]
                local traitColor = traitInfo.Color or Color3.new(1, 1, 1)

                -- ImageButton with trait icon
                local btn = Instance.new("ImageButton")
                btn.Name = "Trait_" .. traitName
                btn.Size = UDim2.new(1, 0, 1, 0) -- Fill the grid cell
                btn.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
                btn.BorderSizePixel = 0
                btn.Image = traitInfo.Icon or ""
                btn.ImageColor3 = Color3.new(1, 1, 1)
                btn.ScaleType = Enum.ScaleType.Fit
                btn.ImageRectSize = Vector2.new(0, 0) -- Use full image
                btn.ZIndex = 203
                btn.Parent = traitsScroll
                createCorner(btn, 8)

                -- Trait name label at bottom
                local nameLabel = Instance.new("TextLabel")
                nameLabel.Name = "TraitName"
                nameLabel.Size = UDim2.new(1, 4, 0, 18)
                nameLabel.Position = UDim2.new(0, -2, 1, -18)
                nameLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
                nameLabel.BackgroundTransparency = 0.3
                nameLabel.Text = traitInfo.Display or traitName
                nameLabel.TextColor3 = traitColor
                nameLabel.TextSize = 10
                nameLabel.TextScaled = false
                nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
                nameLabel.Font = Enum.Font.GothamBold
                nameLabel.ZIndex = 204
                nameLabel.Parent = btn
                createCorner(nameLabel, 4)

                -- Checkmark indicator (hidden by default)
                local checkmark = Instance.new("TextLabel")
                checkmark.Name = "Checkmark"
                checkmark.Size = UDim2.new(0, 20, 0, 20)
                checkmark.Position = UDim2.new(1, -3, 0, 3)
                checkmark.AnchorPoint = Vector2.new(1, 0)
                checkmark.BackgroundColor3 = Color3.fromRGB(50, 200, 50)
                checkmark.Text = "✓"
                checkmark.TextColor3 = Color3.new(1, 1, 1)
                checkmark.TextSize = 14
                checkmark.Font = Enum.Font.GothamBold
                checkmark.ZIndex = 206
                checkmark.Visible = false
                checkmark.Parent = btn
                createCorner(checkmark, 10)

                -- Multiplier badge showing trait value
                local multBadge = Instance.new("TextLabel")
                multBadge.Name = "MultBadge"
                multBadge.Size = UDim2.new(0, 28, 0, 14)
                multBadge.Position = UDim2.new(0, 3, 0, 3)
                multBadge.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
                multBadge.BackgroundTransparency = 0.3
                multBadge.Text = "+" .. (traitInfo.MultiplierModifier or 0)
                multBadge.TextColor3 = Color3.fromRGB(100, 255, 100) -- Green for multiplier
                multBadge.TextSize = 10
                multBadge.Font = Enum.Font.GothamBold
                multBadge.ZIndex = 206
                multBadge.Parent = btn
                createCorner(multBadge, 4)

                traitButtons[traitName] = btn

                btn.MouseButton1Click:Connect(function()
                    toggleTrait(traitName)
                end)
            end
        end

        -- Select All / Deselect All toggle button
        local selectAllTraitsBtn = Instance.new("TextButton")
        selectAllTraitsBtn.Name = "SelectAllTraitsBtn"
        selectAllTraitsBtn.Size = UDim2.new(1, 0, 0, 32)
        selectAllTraitsBtn.Position = UDim2.new(0, 0, 0, 462)
        selectAllTraitsBtn.BackgroundColor3 = Color3.fromRGB(80, 120, 180)
        selectAllTraitsBtn.BorderSizePixel = 0
        selectAllTraitsBtn.Text = "✅ Select All Traits"
        selectAllTraitsBtn.TextColor3 = Color3.new(1, 1, 1)
        selectAllTraitsBtn.TextSize = 12
        selectAllTraitsBtn.Font = Enum.Font.GothamBold
        selectAllTraitsBtn.ZIndex = 202
        selectAllTraitsBtn.Parent = content
        createCorner(selectAllTraitsBtn, 6)

        updateSelectAllButton = function()
            local totalTraits = 0
            if TraitsData then
                for _ in pairs(TraitsData) do
                    totalTraits = totalTraits + 1
                end
            end

            if #selectedTraits >= totalTraits and totalTraits > 0 then
                selectAllTraitsBtn.BackgroundColor3 = Color3.fromRGB(200, 100, 80)
                selectAllTraitsBtn.Text = "❌ Deselect All Traits"
            else
                selectAllTraitsBtn.BackgroundColor3 = Color3.fromRGB(80, 120, 180)
                selectAllTraitsBtn.Text = "✅ Select All Traits"
            end
        end

        selectAllTraitsBtn.MouseButton1Click:Connect(function()
            local totalTraits = 0
            if TraitsData then
                for _ in pairs(TraitsData) do
                    totalTraits = totalTraits + 1
                end
            end

            if #selectedTraits >= totalTraits and totalTraits > 0 then
                -- Deselect all
                selectedTraits = {}
            else
                -- Select all
                selectedTraits = {}
                if TraitsData then
                    for traitName, _ in pairs(TraitsData) do
                        table.insert(selectedTraits, traitName)
                    end
                end
            end
            updateAllTraitButtons()
            updateSelectAllButton()
        end)

        -- Clear all traits button
        local clearTraitsBtn = Instance.new("TextButton")
        clearTraitsBtn.Name = "ClearTraitsBtn"
        clearTraitsBtn.Size = UDim2.new(1, 0, 0, 32)
        clearTraitsBtn.Position = UDim2.new(0, 0, 0, 500)
        clearTraitsBtn.BackgroundColor3 = Color3.fromRGB(120, 60, 120)
        clearTraitsBtn.BorderSizePixel = 0
        clearTraitsBtn.Text = "🧹 Clear All Traits"
        clearTraitsBtn.TextColor3 = Color3.new(1, 1, 1)
        clearTraitsBtn.TextSize = 12
        clearTraitsBtn.Font = Enum.Font.GothamBold
        clearTraitsBtn.ZIndex = 202
        clearTraitsBtn.Parent = content
        createCorner(clearTraitsBtn, 6)

        clearTraitsBtn.MouseButton1Click:Connect(function()
            selectedTraits = {}
            updateAllTraitButtons()
            updateSelectAllButton()
            clearTraitsBtn.Text = "✅ Cleared!"
            task.delay(0.5, function()
                clearTraitsBtn.Text = "🧹 Clear All Traits"
            end)
        end)

        -- ====== MONEY GENERATION DISPLAY ======
        local moneyFrame = Instance.new("Frame")
        moneyFrame.Name = "MoneyGenFrame"
        moneyFrame.Size = UDim2.new(1, 0, 0, 52)
        moneyFrame.Position = UDim2.new(0, 0, 0, 538)
        moneyFrame.BackgroundColor3 = Color3.fromRGB(35, 45, 35)
        moneyFrame.BorderSizePixel = 0
        moneyFrame.ZIndex = 202
        moneyFrame.Parent = content
        createCorner(moneyFrame, 6)
        createStroke(moneyFrame, Color3.fromRGB(100, 200, 100), 1)

        local moneyIcon = Instance.new("TextLabel")
        moneyIcon.Name = "MoneyIcon"
        moneyIcon.Size = UDim2.new(0, 30, 1, 0)
        moneyIcon.Position = UDim2.new(0, 4, 0, 0)
        moneyIcon.BackgroundTransparency = 1
        moneyIcon.Text = "💵"
        moneyIcon.TextSize = 20
        moneyIcon.ZIndex = 203
        moneyIcon.Parent = moneyFrame

        local moneyTitleLabel = Instance.new("TextLabel")
        moneyTitleLabel.Name = "MoneyTitle"
        moneyTitleLabel.Size = UDim2.new(1, -40, 0, 16)
        moneyTitleLabel.Position = UDim2.new(0, 36, 0, 2)
        moneyTitleLabel.BackgroundTransparency = 1
        moneyTitleLabel.Text = "Est. Generation:"
        moneyTitleLabel.TextColor3 = Color3.fromRGB(150, 200, 150)
        moneyTitleLabel.TextSize = 11
        moneyTitleLabel.Font = Enum.Font.GothamBold
        moneyTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
        moneyTitleLabel.ZIndex = 203
        moneyTitleLabel.Parent = moneyFrame

        local moneyValueLabel = Instance.new("TextLabel")
        moneyValueLabel.Name = "MoneyValue"
        moneyValueLabel.Size = UDim2.new(1, -40, 0, 22)
        moneyValueLabel.Position = UDim2.new(0, 36, 0, 18)
        moneyValueLabel.BackgroundTransparency = 1
        moneyValueLabel.Text = "Spawn to calculate..."
        moneyValueLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        moneyValueLabel.TextSize = 14
        moneyValueLabel.Font = Enum.Font.GothamBlack
        moneyValueLabel.TextXAlignment = Enum.TextXAlignment.Left
        moneyValueLabel.ZIndex = 203
        moneyValueLabel.Parent = moneyFrame

        -- Initialize select all button state
        updateSelectAllButton()

        -- Initial refresh
        refreshPodiumList()

        -- Preserve the resetSpawnButton function if it was set earlier
        local existingResetFn = spawnPanelUI and spawnPanelUI.resetSpawnButton
        local existingSpawnBtn = spawnPanelUI and spawnPanelUI.spawnButton

        -- Store reference and return
        spawnPanelUI = {
            screenGui = screenGui,
            panel = panel,
            refreshPodiums = refreshPodiumList,
            -- Preserve the reset function from enhanceIndexPanel
            resetSpawnButton = existingResetFn,
            spawnButton = existingSpawnBtn,
            updateStatus = function(text)
                statusLabel.Text = text
            end,
            updateMoneyGeneration = function(animalName, mutation, traits)
                -- Calculate money generation using robust method like Highest ESP
                local generation = 0

                -- TRY 1: Use the game's SharedAnimals:GetGeneration directly (pass nil for player like Highest ESP)
                local success, result = pcall(function()
                    return SharedAnimals:GetGeneration(animalName, mutation, traits, nil)
                end)

                if success and result and result > 0 then
                    generation = math.round(result)
                else
                    -- TRY 2: Manual calculation matching game logic EXACTLY
                    -- From SharedAnimals.lua GetGeneration:
                    --   baseIncome = Generation or (Price * AnimalGanerationModifier)
                    --   multiplier = 1 + mutation.Modifier + sum(trait.MultiplierModifier)
                    --   if Sleepy: income *= 0.5

                    local animalData = AnimalsData[animalName]
                    if animalData then
                        -- Get the generation modifier from GameData.Game.AnimalGanerationModifier (game has typo)
                        local generationModifier = 0.1
                        pcall(function()
                            generationModifier = GameData.Game.AnimalGanerationModifier or 0.1
                        end)

                        -- Base generation (use Generation if defined, otherwise Price * generationModifier)
                        local baseGen = animalData.Generation or (animalData.Price * generationModifier)

                        -- Multiplier starts at 1
                        local multiplier = 1

                        -- Add mutation modifier
                        if mutation and mutation ~= "" and mutation ~= "Default" and MutationsData[mutation] then
                            local mutMod = MutationsData[mutation].Modifier
                            if mutMod then
                                multiplier = multiplier + mutMod
                            end
                        end

                        -- Add trait modifiers (Sleepy is special - halves income at end)
                        local isSleepy = false
                        if traits and type(traits) == "table" then
                            for _, traitName in ipairs(traits) do
                                if traitName == "Sleepy" then
                                    isSleepy = true
                                elseif TraitsData[traitName] and TraitsData[traitName].MultiplierModifier then
                                    multiplier = multiplier + TraitsData[traitName].MultiplierModifier
                                end
                            end
                        end

                        -- Calculate final income
                        generation = baseGen * multiplier

                        -- Sleepy halves income
                        if isSleepy then
                            generation = generation * 0.5
                        end

                        generation = math.round(generation)
                    end
                end

                -- Format with NumberUtils like game does
                local formatted = "$0/s"
                if generation > 0 then
                    pcall(function()
                        formatted = "$" .. NumberUtils:ToString(generation) .. "/s"
                    end)
                end

                moneyValueLabel.Text = formatted

                -- Color based on value
                if generation >= 100000000 then -- 100M+
                    moneyValueLabel.TextColor3 = Color3.fromRGB(255, 200, 50) -- Gold
                elseif generation >= 10000000 then -- 10M+
                    moneyValueLabel.TextColor3 = Color3.fromRGB(200, 100, 255) -- Purple
                elseif generation >= 1000000 then -- 1M+
                    moneyValueLabel.TextColor3 = Color3.fromRGB(100, 200, 255) -- Blue
                else
                    moneyValueLabel.TextColor3 = Color3.fromRGB(100, 255, 100) -- Green
                end
            end
        }

        return spawnPanelUI
    end

    -- ============================================================================
    -- CREATE MUTATION SIDE PANEL
    -- ============================================================================
    local function createMutationPanel(main, originalMutations, indexFrame)
        if main:FindFirstChild("MutationSidePanel") then
            return main:FindFirstChild("MutationSidePanel")
        end

        -- ========================================================================
        -- LAYOUT CONSTANTS (all heights in pixels, positions calculated dynamically)
        -- ========================================================================
        local LAYOUT = {
            headerHeight = 45,
            selectedHeight = 40,
            selectedOffset = 45,
            scrollTopOffset = 50,
            bottomPadding = 8,
            elementGap = 6,
            -- Bottom elements
            spawnHeight = 50,
            animControllerHeight = 32,
            audioHeight = 32,
            toggleHeight = 36,
            buttonContainerHeight = 130,
            -- Button sizes
            copyBtnHeight = 26,
            toggleBtnHeight = 32
        }

        -- Calculate total bottom area height upfront
        local totalBottomHeight = LAYOUT.bottomPadding + LAYOUT.spawnHeight + LAYOUT.elementGap +
                                      LAYOUT.animControllerHeight + LAYOUT.elementGap + LAYOUT.audioHeight +
                                      LAYOUT.elementGap + (LAYOUT.toggleHeight + 10) + LAYOUT.elementGap -- +10 for padding
        + LAYOUT.buttonContainerHeight + LAYOUT.elementGap + 10 -- buffer

        -- Create panel (EXPANDED SIZE)
        local panel = Instance.new("Frame")
        panel.Name = "MutationSidePanel"
        panel.Size = UDim2.new(0.23, 0, 1.15, 0)
        panel.Position = UDim2.new(-0.137, 0, 0.58, 0)
        panel.AnchorPoint = Vector2.new(0.5, 0.5)
        panel.BackgroundColor3 = BG_COLOR
        panel.BackgroundTransparency = 0.05
        panel.BorderSizePixel = 0
        panel.ZIndex = 50
        panel.Parent = main
        createCorner(panel, 12)
        createStroke(panel, ACCENT_COLOR, 3)

        -- Header
        local header = Instance.new("Frame")
        header.Name = "Header"
        header.Size = UDim2.new(1, 0, 0, LAYOUT.headerHeight)
        header.BackgroundColor3 = ACCENT_COLOR
        header.BorderSizePixel = 0
        header.ZIndex = 51
        header.Parent = panel
        createCorner(header, 12)

        -- Header bottom fix (square corners at bottom)
        local headerFix = Instance.new("Frame")
        headerFix.Size = UDim2.new(1, 0, 0, 12)
        headerFix.Position = UDim2.new(0, 0, 1, -12)
        headerFix.BackgroundColor3 = ACCENT_COLOR
        headerFix.BorderSizePixel = 0
        headerFix.ZIndex = 51
        headerFix.Parent = header

        local headerLabel = Instance.new("TextLabel")
        headerLabel.Size = UDim2.new(1, 0, 1, 0)
        headerLabel.BackgroundTransparency = 1
        headerLabel.Text = "MUTATIONS"
        headerLabel.TextColor3 = Color3.new(0, 0, 0)
        headerLabel.TextSize = 18
        headerLabel.Font = Enum.Font.GothamBlack
        headerLabel.ZIndex = 52
        headerLabel.Parent = header

        -- Selected Mutation Indicator (above header)
        local selectedContainer = Instance.new("Frame")
        selectedContainer.Name = "SelectedContainer"
        selectedContainer.Size = UDim2.new(1, 0, 0, LAYOUT.selectedHeight)
        selectedContainer.Position = UDim2.new(0, 0, 0, -LAYOUT.selectedOffset)
        selectedContainer.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        selectedContainer.BorderSizePixel = 0
        selectedContainer.ZIndex = 51
        selectedContainer.Parent = panel
        createCorner(selectedContainer, 8)
        createStroke(selectedContainer, ACCENT_COLOR, 2)

        local selectedLabel = Instance.new("TextLabel")
        selectedLabel.Name = "SelectedLabel"
        selectedLabel.Size = UDim2.new(1, -10, 1, 0)
        selectedLabel.Position = UDim2.new(0.5, 0, 0, 0)
        selectedLabel.AnchorPoint = Vector2.new(0.5, 0)
        selectedLabel.BackgroundTransparency = 1
        selectedLabel.Text = "Normal"
        selectedLabel.TextColor3 = Color3.new(1, 1, 1)
        selectedLabel.TextSize = 18
        selectedLabel.Font = Enum.Font.GothamBold
        selectedLabel.RichText = true
        selectedLabel.ZIndex = 52
        selectedLabel.Parent = selectedContainer

        selectedMutationLabel = selectedLabel

        -- Scroll frame (uses calculated totalBottomHeight)
        local scroll = Instance.new("ScrollingFrame")
        scroll.Name = "MutationScroll"
        scroll.Size = UDim2.new(1, -12, 1, -(LAYOUT.scrollTopOffset + totalBottomHeight))
        scroll.Position = UDim2.new(0.5, 0, 0, LAYOUT.scrollTopOffset)
        scroll.AnchorPoint = Vector2.new(0.5, 0)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 6
        scroll.ScrollBarImageColor3 = ACCENT_COLOR
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.ZIndex = 51
        scroll.Parent = panel

        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Padding = UDim.new(0, 6)
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.Parent = scroll

        local padding = Instance.new("UIPadding")
        padding.PaddingTop = UDim.new(0, 6)
        padding.PaddingBottom = UDim.new(0, 6)
        padding.Parent = scroll

        -- Wait for original buttons
        local buttons = {}
        local waitTime = 0
        while #buttons == 0 and waitTime < 3 do
            task.wait(0.1)
            waitTime = waitTime + 0.1
            for _, child in pairs(originalMutations:GetChildren()) do
                if child:IsA("TextButton") and child.Name ~= "Template" then
                    table.insert(buttons, child)
                end
            end
        end

        -- Get template for creating new buttons (for hidden mutations)
        local btnTemplate = originalMutations:FindFirstChild("Template")

        -- Track which mutations we already have buttons for
        local existingMutations = {}
        for _, btn in ipairs(buttons) do
            existingMutations[btn.Name] = true
        end

        -- INJECT HIDDEN MUTATIONS: Create buttons for mutations that don't have UI elements
        local injectedCount = 0
        for mutationName, mutData in pairs(IndexData) do
            if type(mutData) == "table" and mutData.IsMutation and not existingMutations[mutationName] then
                -- This mutation exists in IndexData but game didn't create a button (hidden/expired)
                if btnTemplate then
                    local newBtn = btnTemplate:Clone()
                    newBtn.Name = mutationName
                    newBtn.Visible = true
                    newBtn.LayoutOrder = mutData.Order or 99

                    -- Set text and color from MutationsData if available
                    local textLabel = newBtn:FindFirstChild("TextLabel")
                    if textLabel then
                        if mutData.DisplayWithRichText then
                            textLabel.RichText = true
                            textLabel.Text = mutData.DisplayWithRichText
                        elseif mutData.DisplayText then
                            textLabel.Text = mutData.DisplayText
                        else
                            textLabel.Text = mutationName
                        end

                        if mutData.MainColor then
                            textLabel.TextColor3 = mutData.MainColor
                        end

                        -- Apply rainbow gradient for Rainbow mutation
                        if mutationName == "Rainbow" then
                            pcall(function()
                                Gradients.apply(textLabel, "Rainbow")
                            end)
                        end
                    end

                    -- Hide the timer if it exists (we're showing expired mutations)
                    local timer = newBtn:FindFirstChild("Timer")
                    if timer then
                        timer.Visible = false
                    end

                    -- Add to buttons list (will be processed below)
                    table.insert(buttons, newBtn)
                    existingMutations[mutationName] = true
                    injectedCount = injectedCount + 1
                end
            end
        end

        if injectedCount > 0 then
            print("[IndexV2] Injected " .. injectedCount .. " hidden mutation buttons")
        end

        if #buttons == 0 then
            panel:Destroy()
            return nil
        end

        print("[IndexV2] Found " .. #buttons .. " mutation buttons")

        -- Sort: Default first
        table.sort(buttons, function(a, b)
            if a.Name == "Default" then
                return true
            end
            if b.Name == "Default" then
                return false
            end
            return a.Name < b.Name
        end)

        -- Create mirror buttons
        for i, origBtn in ipairs(buttons) do
            local mutationName = origBtn.Name
            local isInjectedButton = not origBtn.Parent or origBtn.Parent == nil -- Injected buttons aren't parented yet

            local mirror = origBtn:Clone()
            mirror.Name = "Mirror_" .. mutationName
            mirror.LayoutOrder = mutationName == "Default" and 0 or i
            mirror.Size = UDim2.new(0.92, 0, 0, 32)
            mirror.ZIndex = 52
            mirror.Parent = scroll

            for _, desc in pairs(mirror:GetDescendants()) do
                if desc:IsA("GuiObject") then
                    desc.ZIndex = 53
                end
            end

            local origBg = mirror.BackgroundColor3
            mirror.MouseEnter:Connect(function()
                mirror.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
            end)
            mirror.MouseLeave:Connect(function()
                mirror.BackgroundColor3 = origBg
            end)

            mirror.MouseButton1Click:Connect(function()
                -- Clean up ALL existing mutations first (restore all cards to default)
                cleanupAllMutations()

                currentMutation = mutationName
                -- Don't reset filter - keep user's filter choice
                -- Reset search only
                currentSearch = ""

                -- Get source TextLabel from button (has RichText, colors, and animated gradient)
                local sourceTextLabel = origBtn:FindFirstChild("TextLabel")

                -- Update selected mutation indicator by cloning from source
                updateSelectedMutationLabel(mutationName, sourceTextLabel)

                -- Clear search box text
                local topBar = indexFrame:FindFirstChild("IndexV2TopBar")
                if topBar then
                    local searchBox = topBar:FindFirstChild("SearchBox")
                    if searchBox then
                        searchBox.Text = ""
                    end
                end

                -- ALWAYS manually set visibility - don't rely on game's broken signal system
                local mutData = IndexData[mutationName]
                local list = main:FindFirstChild("Content")
                if list then
                    list = list:FindFirstChild("Holder")
                end
                if list then
                    list = list:FindFirstChild("List")
                end

                if list then
                    -- FIRST PASS: Set visibility only (don't apply mutations yet)
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            local animalName = card.Name
                            -- Check if this is an admin animal (use helper for all detection methods)
                            local isAdminAnimal = isCardAdminAnimal(card, animalName)
                            local isInjected = cardCache[card] and cardCache[card].isInjected

                            -- Determine visibility based on mode
                            local shouldBeVisible
                            if isAdminAnimal then
                                -- Admin animals: ONLY controlled by showAdminAnimals toggle
                                shouldBeVisible = showAdminAnimals
                            elseif isInjected then
                                -- Injected cards only show in Show All mode
                                shouldBeVisible = showAllMode
                            elseif showAllMode then
                                -- Show All ON: show ALL animals in database
                                shouldBeVisible = true
                            else
                                -- Show All OFF: Game behavior - show what EXISTS in mutation's Index
                                shouldBeVisible = animalExistsInMutationIndex(animalName, mutationName)
                            end

                            card.Visible = shouldBeVisible

                            -- DON'T overwrite originalVisible here - that should only reflect game's original state
                            -- Just ensure card is in cache
                            if not cardCache[card] then
                                cardCache[card] = {
                                    name = card.Name,
                                    originalVisible = false -- Injected by us, not game
                                }
                            end
                        end
                    end

                    -- Apply filters (this may change visibility)
                    applyFilters(list)

                    -- DIRECTLY apply mutation to ALL cards NOW (not just visible - game recycles them)
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            applyMutationToCard(card, card.Name, mutationName)
                            -- Also update the NOT INDEXED indicator for this mutation
                            updateCardIndicator(card, card.Name)
                        end
                    end
                end

                -- FIRE SIGNAL - for any future cards that get created from scrolling
                MutationChanged:Fire(mutationName)

                -- Re-apply after delays to counter any game signal interference
                -- The game's signal might fire AFTER our handler, so we need to override it
                for i = 1, 5 do
                    task.delay(0.05 * i, function()
                        if currentMutation == mutationName and list then
                            for _, card in pairs(list:GetChildren()) do
                                if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                    applyMutationToCard(card, card.Name, mutationName)
                                    updateCardIndicator(card, card.Name)
                                end
                            end
                        end
                    end)
                end
            end)

            -- Apply rainbow animation to Rainbow button text
            if origBtn.Name == "Rainbow" then
                local textLabel = mirror:FindFirstChild("TextLabel")
                if textLabel then
                    textLabel.TextColor3 = Color3.new(1, 1, 1)
                    pcall(function()
                        Gradients.apply(textLabel, "Rainbow")
                    end)
                end
            elseif origBtn.Name == "Christmas" then
                local textLabel = mirror:FindFirstChild("TextLabel")
                if textLabel then
                    textLabel.TextColor3 = Color3.new(1, 1, 1)
                    pcall(function()
                        Gradients.apply(textLabel, "SlowGreenRed")
                    end)
                end
            end

            mutationButtons[origBtn.Name] = mirror
        end

        -- Watch for new buttons
        originalMutations.ChildAdded:Connect(function(child)
            if child:IsA("TextButton") and child.Name ~= "Template" and not mutationButtons[child.Name] then
                task.wait(0.1)
                local mutationName = child.Name
                local mirror = child:Clone()
                mirror.Name = "Mirror_" .. mutationName
                mirror.LayoutOrder = 100
                mirror.Size = UDim2.new(0.92, 0, 0, 32)
                mirror.ZIndex = 52
                mirror.Parent = scroll

                mirror.MouseButton1Click:Connect(function()
                    cleanupAllMutations()
                    currentMutation = mutationName
                    currentSearch = ""
                    updateSelectedMutationLabel(mutationName)

                    -- ALWAYS manually set visibility
                    local mutData = IndexData[mutationName]
                    local list = main:FindFirstChild("Content")
                    if list then
                        list = list:FindFirstChild("Holder")
                    end
                    if list then
                        list = list:FindFirstChild("List")
                    end

                    if list then
                        -- FIRST PASS: Set visibility only (don't apply mutations yet)
                        for _, card in pairs(list:GetChildren()) do
                            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                local animalName = card.Name
                                -- Check if this is an admin animal (use helper for all detection methods)
                                local isAdminAnimal = isCardAdminAnimal(card, animalName)
                                local isInjected = cardCache[card] and cardCache[card].isInjected

                                -- Determine visibility based on mode
                                local shouldBeVisible
                                if isAdminAnimal then
                                    -- Admin animals: ONLY controlled by showAdminAnimals toggle
                                    shouldBeVisible = showAdminAnimals
                                elseif isInjected then
                                    -- Injected cards only show in Show All mode
                                    shouldBeVisible = showAllMode
                                elseif showAllMode then
                                    -- Show All ON: show ALL animals in database
                                    shouldBeVisible = true
                                else
                                    -- Show All OFF: Game behavior - show what EXISTS in mutation's Index
                                    shouldBeVisible = animalExistsInMutationIndex(animalName, mutationName)
                                end

                                card.Visible = shouldBeVisible

                                -- DON'T overwrite originalVisible here - that should only reflect game's original state
                                -- Just ensure card is in cache
                                if not cardCache[card] then
                                    cardCache[card] = {
                                        name = card.Name,
                                        originalVisible = false -- Injected by us, not game
                                    }
                                end
                            end
                        end

                        -- Apply filters (this may change visibility)
                        applyFilters(list)

                        -- DIRECTLY apply mutation to ALL cards NOW
                        for _, card in pairs(list:GetChildren()) do
                            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                applyMutationToCard(card, card.Name, mutationName)
                                updateCardIndicator(card, card.Name)
                            end
                        end
                    end

                    -- FIRE SIGNAL - for any future cards that get created from scrolling
                    MutationChanged:Fire(mutationName)

                    -- Re-apply after delays to counter any game signal interference
                    for i = 1, 5 do
                        task.delay(0.05 * i, function()
                            if currentMutation == mutationName and list then
                                for _, card in pairs(list:GetChildren()) do
                                    if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                        applyMutationToCard(card, card.Name, mutationName)
                                        updateCardIndicator(card, card.Name)
                                    end
                                end
                            end
                        end)
                    end
                end)

                -- Apply rainbow animation to Rainbow button
                if child.Name == "Rainbow" then
                    local textLabel = mirror:FindFirstChild("TextLabel")
                    if textLabel then
                        textLabel.TextColor3 = Color3.new(1, 1, 1)
                        pcall(function()
                            Gradients.apply(textLabel, "Rainbow")
                        end)
                    end
                elseif child.Name == "Christmas" then
                    local textLabel = mirror:FindFirstChild("TextLabel")
                    if textLabel then
                        textLabel.TextColor3 = Color3.new(1, 1, 1)
                        pcall(function()
                            Gradients.apply(textLabel, "SlowGreenRed")
                        end)
                    end
                end

                mutationButtons[child.Name] = mirror
            end
        end)

        -- ========================================================================
        -- TOGGLE BUTTONS CONTAINER - Show All & Show Admin
        -- ========================================================================
        local toggleContainer = Instance.new("Frame")
        toggleContainer.Name = "ToggleContainer"
        toggleContainer.Size = UDim2.new(1, -12, 0, LAYOUT.toggleHeight + 10) -- +10 for padding
        toggleContainer.Position = UDim2.new(0.5, 0, 1, -50) -- Placeholder, set by smart layout
        toggleContainer.AnchorPoint = Vector2.new(0.5, 0)
        toggleContainer.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        toggleContainer.BorderSizePixel = 0
        toggleContainer.ZIndex = 52
        toggleContainer.Parent = panel
        createCorner(toggleContainer, 6)

        -- Show All Toggle Button
        local showAllBtn = Instance.new("TextButton")
        showAllBtn.Name = "ShowAllToggle"
        showAllBtn.Size = UDim2.new(0.47, 0, 0, LAYOUT.toggleBtnHeight)
        showAllBtn.Position = UDim2.new(0.015, 0, 0.5, 0)
        showAllBtn.AnchorPoint = Vector2.new(0, 0.5)
        showAllBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
        showAllBtn.BorderSizePixel = 0
        showAllBtn.Text = "👁 Show All"
        showAllBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
        showAllBtn.TextSize = 11
        showAllBtn.Font = Enum.Font.GothamBold
        showAllBtn.ZIndex = 53
        showAllBtn.Parent = toggleContainer
        createCorner(showAllBtn, 5)

        -- Show Admin Toggle Button (separate from Show All!)
        local showAdminBtn = Instance.new("TextButton")
        showAdminBtn.Name = "ShowAdminToggle"
        showAdminBtn.Size = UDim2.new(0.47, 0, 0, LAYOUT.toggleBtnHeight)
        showAdminBtn.Position = UDim2.new(0.985, 0, 0.5, 0)
        showAdminBtn.AnchorPoint = Vector2.new(1, 0.5)
        showAdminBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 40) -- OFF by default
        showAdminBtn.BorderSizePixel = 0
        showAdminBtn.Text = "👑 Show Admin"
        showAdminBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
        showAdminBtn.TextSize = 11
        showAdminBtn.Font = Enum.Font.GothamBold
        showAdminBtn.ZIndex = 53
        showAdminBtn.Parent = toggleContainer
        createCorner(showAdminBtn, 5)
        -- Toggle button update function
        local function updateToggleButton(btn, isOn, onText, offText)
            if isOn then
                btn.BackgroundColor3 = ACCENT_COLOR
                btn.TextColor3 = Color3.new(0, 0, 0)
                btn.Text = onText
            else
                btn.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
                btn.TextColor3 = Color3.fromRGB(180, 180, 180)
                btn.Text = offText
            end
        end

        -- Show All button click - INJECTS ALL MISSING ANIMALS
        showAllBtn.MouseButton1Click:Connect(function()
            showAllMode = not showAllMode
            updateToggleButton(showAllBtn, showAllMode, "👁 Show All ✓", "👁 Show All")

            local list = main:FindFirstChild("Content")
            if list then
                list = list:FindFirstChild("Holder")
            end
            if list then
                list = list:FindFirstChild("List")
            end
            if list then
                local template = list:FindFirstChild("Template")

                if showAllMode and template then
                    -- INJECT ALL MISSING ANIMALS (not just HideFromIndex ones)
                    local injectedCount = 0
                    for animalName, _ in pairs(AllAnimalsFromData) do
                        -- Skip Admin animals (those go in Show Admin)
                        if not OriginallyHiddenAnimals[animalName] then
                            local card, isNew = injectAnimalCard(list, template, animalName, false)
                            if isNew then
                                injectedCount = injectedCount + 1
                            end
                            if card then
                                card.Visible = true
                            end
                        end
                    end
                    if injectedCount > 0 then
                        print("[IndexV2] Show All: Injected " .. injectedCount .. " missing animal cards")
                    end

                    -- Show all existing REGULAR cards (not admin)
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            local isAdmin = isCardAdminAnimal(card)
                            if not isAdmin then
                                card.Visible = true
                            end
                        end
                    end
                else
                    -- Show All OFF - hide injected Show All cards (but keep them for next time)
                    for card, _ in pairs(injectedShowAllCards) do
                        if card and card.Parent then
                            card.Visible = false
                        end
                    end
                end
                applyFilters(list)

                -- Fire signal to apply mutation to all cards
                if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                    task.defer(function()
                        MutationChanged:Fire(currentMutation)
                    end)
                end
            end
        end)

        -- Show Admin button click (separate toggle for admin animals)
        showAdminBtn.MouseButton1Click:Connect(function()
            showAdminAnimals = not showAdminAnimals
            updateToggleButton(showAdminBtn, showAdminAnimals, "👑 Show Admin ✓", "👑 Show Admin")

            -- Refresh card visibility when toggle changes
            local list = main:FindFirstChild("Content")
            if list then
                list = list:FindFirstChild("Holder")
            end
            if list then
                list = list:FindFirstChild("List")
            end
            if list then
                local template = list:FindFirstChild("Template")

                if showAdminAnimals and template then
                    -- INJECT admin animal cards when Show Admin is ON
                    local injectedCount = 0
                    for animalName, _ in pairs(OriginallyHiddenAnimals) do
                        local card, isNew = injectAnimalCard(list, template, animalName, true)
                        if isNew then
                            injectedCount = injectedCount + 1
                        end
                        if card then
                            -- Check if this animal should be visible with current mutation
                            local mutData = IndexData[currentMutation]
                            local shouldShow = true
                            if currentMutation ~= "Default" and mutData and mutData.Index then
                                shouldShow = mutData.Index[animalName] ~= nil
                            end
                            card.Visible = shouldShow
                            -- DON'T update originalVisible - admin cards are injected, not from game
                        end
                    end
                    if injectedCount > 0 then
                        print("[IndexV2] Show Admin: Injected " .. injectedCount .. " admin animal cards")
                    end

                    -- Show all existing admin cards (respecting current mutation filter)
                    local mutData = IndexData[currentMutation]
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            local isAdmin = isCardAdminAnimal(card)
                            if isAdmin then
                                local shouldShow = true
                                if currentMutation ~= "Default" and mutData and mutData.Index then
                                    shouldShow = mutData.Index[card.Name] ~= nil
                                end
                                card.Visible = shouldShow
                            end
                        end
                    end
                else
                    -- Show Admin OFF - hide admin cards
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            local isAdmin = isCardAdminAnimal(card)
                            if isAdmin then
                                card.Visible = false
                            end
                        end
                    end
                end
                applyFilters(list)

                -- Fire signal to apply mutation to newly visible admin cards
                if showAdminAnimals and currentMutation ~= "Default" and currentMutation ~= "Normal" then
                    task.defer(function()
                        MutationChanged:Fire(currentMutation)
                    end)
                end
            end
        end)

        -- Show Admin starts OFF (admin animals hidden by default)
        -- No initialization needed - button already starts in OFF state

        -- ========================================================================
        -- COPY/DUMP BUTTONS - Below Show All checkbox
        -- ========================================================================

        -- Helper: Get all animals for current mutation organized by index status
        -- Only includes animals that COUNT toward completion (respects IgnoreIndexCounter flag)
        local function getAnimalsForCurrentMutation()
            local indexed = {}
            local unindexed = {}

            local playerData = Synchronizer:Get(LocalPlayer)
            if not playerData then
                return indexed, unindexed
            end

            local playerIndex = playerData:Get("Index") or {}
            local mutation = currentMutation
            local mutInfo = IndexData[mutation]

            -- Get the index key to check in player data
            local indexKey = "Default"
            if mutInfo then
                if mutInfo.CustomIndex then
                    indexKey = mutInfo.CustomIndex.Name
                elseif mutInfo.IsMutation then
                    indexKey = mutation
                end
            end

            -- Get the list of animals required for this mutation's index
            local requiredAnimals = {}
            if mutInfo and mutInfo.Index then
                -- Has specific Index table - use it
                for animalName, animalEntry in pairs(mutInfo.Index) do
                    -- IMPORTANT: Skip animals with IgnoreIndexCounter = true (they don't count toward completion)
                    if not (animalEntry and animalEntry.IgnoreIndexCounter) then
                        -- Filter Admin animals if Show Admin is OFF
                        if showAdminAnimals or not wasOriginallyHidden(animalName) then
                            table.insert(requiredAnimals, animalName)
                        end
                    end
                end
            else
                -- No specific Index = uses all indexable animals
                for animalName, animalData in pairs(AnimalsData) do
                    if not animalData.HideFromIndex then
                        -- Filter Admin animals if Show Admin is OFF
                        if showAdminAnimals or not wasOriginallyHidden(animalName) then
                            table.insert(requiredAnimals, animalName)
                        end
                    end
                end
            end

            -- Check each required animal against player's index
            for _, animalName in ipairs(requiredAnimals) do
                local animalIndex = playerIndex[animalName]
                local isIndexed = false
                if animalIndex then
                    isIndexed = animalIndex[indexKey] ~= nil
                end

                if isIndexed then
                    table.insert(indexed, animalName)
                else
                    table.insert(unindexed, animalName)
                end
            end

            -- Sort alphabetically
            table.sort(indexed)
            table.sort(unindexed)

            return indexed, unindexed
        end

        -- Helper: Format animals for clipboard (elegant - one per line, sorted)
        local function formatAnimalList(animals, indexName)
            if #animals == 0 then
                return ""
            end

            -- Sort alphabetically
            local sorted = {}
            for _, name in ipairs(animals) do
                table.insert(sorted, name)
            end
            table.sort(sorted)

            -- Build elegant list with header
            local lines = {}
            table.insert(lines, "=== " .. indexName .. " - " .. #sorted .. " Missing ===")
            table.insert(lines, "")
            for i, name in ipairs(sorted) do
                table.insert(lines, string.format("%d. %s", i, name))
            end

            return table.concat(lines, "\n")
        end

        -- Create button container below Show All
        local buttonContainer = Instance.new("Frame")
        buttonContainer.Name = "CopyButtonsContainer"
        buttonContainer.Size = UDim2.new(1, -12, 0, LAYOUT.buttonContainerHeight)
        buttonContainer.Position = UDim2.new(0.5, 0, 1, -195) -- Placeholder, set by smart layout
        buttonContainer.AnchorPoint = Vector2.new(0.5, 0)
        buttonContainer.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        buttonContainer.BorderSizePixel = 0
        buttonContainer.ZIndex = 52
        buttonContainer.Parent = panel
        createCorner(buttonContainer, 6)

        local btnLayout = Instance.new("UIListLayout")
        btnLayout.SortOrder = Enum.SortOrder.LayoutOrder
        btnLayout.Padding = UDim.new(0, 4)
        btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        btnLayout.Parent = buttonContainer

        local btnPadding = Instance.new("UIPadding")
        btnPadding.PaddingTop = UDim.new(0, 6)
        btnPadding.PaddingBottom = UDim.new(0, 6)
        btnPadding.Parent = buttonContainer

        -- Button 1: Copy Indexed Requirements
        local copyIndexedBtn = Instance.new("TextButton")
        copyIndexedBtn.Name = "CopyIndexedBtn"
        copyIndexedBtn.Size = UDim2.new(0.92, 0, 0, LAYOUT.copyBtnHeight)
        copyIndexedBtn.LayoutOrder = 1
        copyIndexedBtn.BackgroundColor3 = Color3.fromRGB(45, 75, 45)
        copyIndexedBtn.BorderSizePixel = 0
        copyIndexedBtn.Text = "📋 Copy Indexed"
        copyIndexedBtn.TextColor3 = Color3.fromRGB(100, 255, 100)
        copyIndexedBtn.TextSize = 13
        copyIndexedBtn.Font = Enum.Font.GothamBold
        copyIndexedBtn.ZIndex = 53
        copyIndexedBtn.Parent = buttonContainer
        createCorner(copyIndexedBtn, 5)

        copyIndexedBtn.MouseButton1Click:Connect(function()
            local indexed, _ = getAnimalsForCurrentMutation()
            local indexName = currentMutation == "Default" and "Default" or currentMutation
            local text = formatAnimalList(indexed, indexName)
            if text ~= "" then
                setclipboard(text)
                copyIndexedBtn.Text = "✅ Copied " .. #indexed .. "!"
                task.delay(1.5, function()
                    copyIndexedBtn.Text = "📋 Copy Indexed"
                end)
            else
                copyIndexedBtn.Text = "❌ None indexed"
                task.delay(1.5, function()
                    copyIndexedBtn.Text = "📋 Copy Indexed"
                end)
            end
        end)

        -- Button 2: Copy Missing Index Requirements (Non-Indexed)
        local copyMissingBtn = Instance.new("TextButton")
        copyMissingBtn.Name = "CopyMissingBtn"
        copyMissingBtn.Size = UDim2.new(0.92, 0, 0, LAYOUT.copyBtnHeight)
        copyMissingBtn.LayoutOrder = 2
        copyMissingBtn.BackgroundColor3 = Color3.fromRGB(85, 45, 45)
        copyMissingBtn.BorderSizePixel = 0
        copyMissingBtn.Text = "📋 Copy Missing"
        copyMissingBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
        copyMissingBtn.TextSize = 13
        copyMissingBtn.Font = Enum.Font.GothamBold
        copyMissingBtn.ZIndex = 53
        copyMissingBtn.Parent = buttonContainer
        createCorner(copyMissingBtn, 5)

        copyMissingBtn.MouseButton1Click:Connect(function()
            local _, unindexed = getAnimalsForCurrentMutation()
            local indexName = currentMutation == "Default" and "Default" or currentMutation
            local text = formatAnimalList(unindexed, indexName)
            if text ~= "" then
                setclipboard(text)
                copyMissingBtn.Text = "✅ Copied " .. #unindexed .. "!"
                task.delay(1.5, function()
                    copyMissingBtn.Text = "📋 Copy Missing"
                end)
            else
                copyMissingBtn.Text = "✅ All indexed!"
                task.delay(1.5, function()
                    copyMissingBtn.Text = "📋 Copy Missing"
                end)
            end
        end)

        -- Button 3: Dump All Index Requirements to file
        local dumpAllBtn = Instance.new("TextButton")
        dumpAllBtn.Name = "DumpAllBtn"
        dumpAllBtn.Size = UDim2.new(0.92, 0, 0, LAYOUT.copyBtnHeight)
        dumpAllBtn.LayoutOrder = 3
        dumpAllBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 80)
        dumpAllBtn.BorderSizePixel = 0
        dumpAllBtn.Text = "💾 Dump All Indexes"
        dumpAllBtn.TextColor3 = Color3.fromRGB(150, 150, 255)
        dumpAllBtn.TextSize = 13
        dumpAllBtn.Font = Enum.Font.GothamBold
        dumpAllBtn.ZIndex = 53
        dumpAllBtn.Parent = buttonContainer
        createCorner(dumpAllBtn, 5)

        dumpAllBtn.MouseButton1Click:Connect(function()
            -- Dump ALL mutation Index tables from IndexData
            local lines = {}
            table.insert(lines, "=== ALL INDEX REQUIREMENTS ===")
            table.insert(lines, "Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
            table.insert(lines, "")

            -- Get all indexable animals (for mutations without specific Index table)
            -- ALWAYS exclude hidden animals - they're not part of index requirements
            local allIndexableAnimals = {}
            for animalName, animalData in pairs(AnimalsData) do
                if not animalData.HideFromIndex and not wasOriginallyHidden(animalName) then
                    table.insert(allIndexableAnimals, animalName)
                end
            end
            table.sort(allIndexableAnimals)

            -- Sort mutation names
            local mutationNames = {}
            for mutName, _ in pairs(IndexData) do
                table.insert(mutationNames, mutName)
            end
            table.sort(mutationNames)

            -- Dump each mutation's Index table
            for _, mutName in ipairs(mutationNames) do
                local mutData = IndexData[mutName]
                if type(mutData) == "table" then
                    local animals = {}

                    if mutData.Index then
                        -- Has specific Index table - exclude hidden animals
                        for animalName, _ in pairs(mutData.Index) do
                            if not wasOriginallyHidden(animalName) then
                                table.insert(animals, animalName)
                            end
                        end
                    else
                        -- No specific Index = uses all indexable animals
                        for _, name in ipairs(allIndexableAnimals) do
                            table.insert(animals, name)
                        end
                    end
                    table.sort(animals)

                    if #animals > 0 then
                        -- Get percentage from game's calculation
                        local indexed, required, total = SharedIndex:GetIndexAnimals(LocalPlayer, mutName)
                        local pct = total > 0 and math.floor((required / total) * 100) or 100
                        table.insert(lines, string.format("=== %s (%d animals, %d required [%d%%]) ===", mutName,
                            #animals, required, pct))
                        table.insert(lines, "")
                        for i, name in ipairs(animals) do
                            table.insert(lines, string.format("%d. %s", i, name))
                        end
                        table.insert(lines, "")
                    end
                end
            end

            local content = table.concat(lines, "\n")
            local filename = "IndexV2_AllIndexes_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

            pcall(function()
                if not isfolder("IndexV2Dumps") then
                    makefolder("IndexV2Dumps")
                end
                writefile("IndexV2Dumps/" .. filename, content)
            end)

            dumpAllBtn.Text = "✅ Saved!"
            task.delay(2, function()
                dumpAllBtn.Text = "💾 Dump All Indexes"
            end)
        end)

        -- Button 4: Dump Current Mutation Index to file
        local dumpCurrentBtn = Instance.new("TextButton")
        dumpCurrentBtn.Name = "DumpCurrentBtn"
        dumpCurrentBtn.Size = UDim2.new(0.92, 0, 0, LAYOUT.copyBtnHeight)
        dumpCurrentBtn.LayoutOrder = 4
        dumpCurrentBtn.BackgroundColor3 = Color3.fromRGB(80, 50, 80)
        dumpCurrentBtn.BorderSizePixel = 0
        dumpCurrentBtn.Text = "💾 Dump This Index"
        dumpCurrentBtn.TextColor3 = Color3.fromRGB(200, 150, 255)
        dumpCurrentBtn.TextSize = 13
        dumpCurrentBtn.Font = Enum.Font.GothamBold
        dumpCurrentBtn.ZIndex = 53
        dumpCurrentBtn.Parent = buttonContainer
        createCorner(dumpCurrentBtn, 5)

        dumpCurrentBtn.MouseButton1Click:Connect(function()
            -- Dump current mutation's Index table
            local indexName = currentMutation == "Default" and "Default" or currentMutation
            local mutData = IndexData[currentMutation]

            local lines = {}
            table.insert(lines, "=== " .. indexName .. " INDEX ===")
            table.insert(lines, "Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
            table.insert(lines, "")

            -- ALWAYS exclude hidden animals - they're not part of index requirements
            local animals = {}
            if mutData and mutData.Index then
                -- Has specific Index table
                for animalName, _ in pairs(mutData.Index) do
                    if not wasOriginallyHidden(animalName) then
                        table.insert(animals, animalName)
                    end
                end
            else
                -- No specific Index = uses all indexable animals
                for animalName, animalData in pairs(AnimalsData) do
                    if not animalData.HideFromIndex and not wasOriginallyHidden(animalName) then
                        table.insert(animals, animalName)
                    end
                end
            end
            table.sort(animals)

            -- Get percentage from game's calculation
            local indexed, required, total = SharedIndex:GetIndexAnimals(LocalPlayer, currentMutation)
            local pct = total > 0 and math.floor((required / total) * 100) or 100

            table.insert(lines, string.format("Required: %d animals (%d%% of total)", #animals, pct))
            table.insert(lines, string.format("Progress: %d/%d indexed", indexed, required))
            table.insert(lines, "")
            for i, name in ipairs(animals) do
                table.insert(lines, string.format("%d. %s", i, name))
            end

            local content = table.concat(lines, "\n")
            local filename = "IndexV2_" .. indexName .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

            pcall(function()
                if not isfolder("IndexV2Dumps") then
                    makefolder("IndexV2Dumps")
                end
                writefile("IndexV2Dumps/" .. filename, content)
            end)

            dumpCurrentBtn.Text = "✅ Saved!"
            task.delay(2, function()
                dumpCurrentBtn.Text = "💾 Dump This Index"
            end)
        end)

        -- ========================================================================
        -- AUDIO TOGGLE BUTTON - Above spawn button (single button style)
        -- ========================================================================
        local audioToggleBtn = Instance.new("TextButton")
        audioToggleBtn.Name = "AudioToggleBtn"
        audioToggleBtn.Size = UDim2.new(0.48, 0, 0, LAYOUT.audioHeight)
        audioToggleBtn.AnchorPoint = Vector2.new(0, 0)
        audioToggleBtn.BackgroundColor3 = audioEnabled and Color3.fromRGB(50, 90, 130) or Color3.fromRGB(70, 45, 45)
        audioToggleBtn.BorderSizePixel = 0
        audioToggleBtn.Text = audioEnabled and "🔊 Audio: ON" or "🔇 Audio: OFF"
        audioToggleBtn.TextColor3 = Color3.new(1, 1, 1)
        audioToggleBtn.TextSize = 11
        audioToggleBtn.Font = Enum.Font.GothamBold
        audioToggleBtn.ZIndex = 52
        audioToggleBtn.Parent = panel
        createCorner(audioToggleBtn, 6)

        audioToggleBtn.MouseButton1Click:Connect(function()
            audioEnabled = not audioEnabled
            audioToggleBtn.Text = audioEnabled and "🔊 Audio: ON" or "🔇 Audio: OFF"
            audioToggleBtn.BackgroundColor3 = audioEnabled and Color3.fromRGB(50, 90, 130) or Color3.fromRGB(70, 45, 45)
            saveAudioConfig()
        end)

        -- ========================================================================
        -- COPY NAME TOGGLE BUTTON - Next to audio toggle
        -- ========================================================================
        local copyNameBtn = Instance.new("TextButton")
        copyNameBtn.Name = "CopyNameBtn"
        copyNameBtn.Size = UDim2.new(0.48, 0, 0, LAYOUT.audioHeight)
        copyNameBtn.AnchorPoint = Vector2.new(1, 0)
        copyNameBtn.BackgroundColor3 = copyNameEnabled and Color3.fromRGB(90, 50, 130) or Color3.fromRGB(45, 45, 70)
        copyNameBtn.BorderSizePixel = 0
        copyNameBtn.Text = copyNameEnabled and "📋 Copy: ON" or "📋 Copy: OFF"
        copyNameBtn.TextColor3 = Color3.new(1, 1, 1)
        copyNameBtn.TextSize = 11
        copyNameBtn.Font = Enum.Font.GothamBold
        copyNameBtn.ZIndex = 52
        copyNameBtn.Parent = panel
        createCorner(copyNameBtn, 6)

        copyNameBtn.MouseButton1Click:Connect(function()
            copyNameEnabled = not copyNameEnabled
            copyNameBtn.Text = copyNameEnabled and "📋 Copy: ON" or "📋 Copy: OFF"
            copyNameBtn.BackgroundColor3 = copyNameEnabled and Color3.fromRGB(90, 50, 130) or Color3.fromRGB(45, 45, 70)
        end)

        -- ========================================================================
        -- ANIMATION SWAP - Swap all podium animals to various animations
        -- ========================================================================
        local animSwapFrame = Instance.new("Frame")
        animSwapFrame.Name = "AnimSwapFrame"
        animSwapFrame.Size = UDim2.new(1, -12, 0, LAYOUT.animControllerHeight)
        animSwapFrame.AnchorPoint = Vector2.new(0.5, 0)
        animSwapFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        animSwapFrame.BorderSizePixel = 0
        animSwapFrame.ZIndex = 52
        animSwapFrame.Parent = panel
        createCorner(animSwapFrame, 6)

        -- Scan AnimalAnimations to find ALL unique animation names
        local function getAllAnimations()
            local animSet = {} -- Use set to avoid duplicates

            for _, folder in ipairs(AnimalAnimations:GetChildren()) do
                if folder:IsA("Folder") then
                    for _, anim in ipairs(folder:GetChildren()) do
                        if anim:IsA("Animation") then
                            animSet[anim.Name] = true
                        end
                    end
                end
            end

            -- Convert to array
            local anims = {}
            for name in pairs(animSet) do
                table.insert(anims, name)
            end

            -- Sort with Idle first, then Walk, then alphabetical
            table.sort(anims, function(a, b)
                if a == "Idle" then
                    return true
                end
                if b == "Idle" then
                    return false
                end
                if a == "Walk" then
                    return true
                end
                if b == "Walk" then
                    return false
                end
                return a < b
            end)

            return anims
        end

        local animPresets = getAllAnimations()
        if #animPresets == 0 then
            animPresets = {"Idle", "Walk"} -- Fallback
        end
        local currentAnimIndex = 1

        -- Animation speed state
        local currentAnimSpeed = 1.0

        -- Animation override state - tracks what animation ALL cards should play
        -- nil = default Idle, string = custom animation name
        local activeAnimOverride = nil

        -- Expose state globally so occlusion system can access it
        _G.IndexV2_AnimState = {
            getOverride = function()
                return activeAnimOverride, currentAnimSpeed
            end,
            setOverride = function(anim, speed)
                activeAnimOverride = anim;
                if speed then
                    currentAnimSpeed = speed
                end
            end
        }

        -- Dropdown button
        local animDropdown = Instance.new("TextButton")
        animDropdown.Size = UDim2.new(0.42, 0, 0.85, 0)
        animDropdown.Position = UDim2.new(0.01, 0, 0.5, 0)
        animDropdown.AnchorPoint = Vector2.new(0, 0.5)
        animDropdown.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
        animDropdown.BorderSizePixel = 0
        animDropdown.Text = "🎬 " .. animPresets[1] .. " ▼"
        animDropdown.TextColor3 = Color3.new(1, 1, 1)
        animDropdown.TextSize = 12
        animDropdown.Font = Enum.Font.GothamBold
        animDropdown.ZIndex = 53
        animDropdown.Parent = animSwapFrame
        createCorner(animDropdown, 4)

        -- Speed input
        local animSpeedInput = Instance.new("TextBox")
        animSpeedInput.Size = UDim2.new(0.14, 0, 0.85, 0)
        animSpeedInput.Position = UDim2.new(0.44, 0, 0.5, 0)
        animSpeedInput.AnchorPoint = Vector2.new(0, 0.5)
        animSpeedInput.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
        animSpeedInput.BorderSizePixel = 0
        animSpeedInput.Text = "1"
        animSpeedInput.PlaceholderText = "Spd"
        animSpeedInput.TextColor3 = Color3.new(1, 1, 1)
        animSpeedInput.TextSize = 11
        animSpeedInput.Font = Enum.Font.GothamBold
        animSpeedInput.ZIndex = 53
        animSpeedInput.ClearTextOnFocus = false
        animSpeedInput.Parent = animSwapFrame
        createCorner(animSpeedInput, 4)

        animSpeedInput.FocusLost:Connect(function()
            local num = tonumber(animSpeedInput.Text)
            if num and num >= 0 then
                currentAnimSpeed = num
                animSpeedInput.BackgroundColor3 = Color3.fromRGB(30, 55, 30)
                task.delay(0.3, function()
                    if animSpeedInput.Parent then
                        animSpeedInput.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
                    end
                end)
            else
                animSpeedInput.Text = tostring(currentAnimSpeed)
                animSpeedInput.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
                task.delay(0.3, function()
                    if animSpeedInput.Parent then
                        animSpeedInput.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
                    end
                end)
            end
        end)

        -- Play button
        local animPlayBtn = Instance.new("TextButton")
        animPlayBtn.Size = UDim2.new(0.19, 0, 0.85, 0)
        animPlayBtn.Position = UDim2.new(0.59, 0, 0.5, 0)
        animPlayBtn.AnchorPoint = Vector2.new(0, 0.5)
        animPlayBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 50)
        animPlayBtn.BorderSizePixel = 0
        animPlayBtn.Text = "▶️"
        animPlayBtn.TextColor3 = Color3.new(1, 1, 1)
        animPlayBtn.TextSize = 14
        animPlayBtn.Font = Enum.Font.GothamBold
        animPlayBtn.ZIndex = 53
        animPlayBtn.Parent = animSwapFrame
        createCorner(animPlayBtn, 4)

        -- Stop button
        local animStopBtn = Instance.new("TextButton")
        animStopBtn.Size = UDim2.new(0.19, 0, 0.85, 0)
        animStopBtn.Position = UDim2.new(0.99, 0, 0.5, 0)
        animStopBtn.AnchorPoint = Vector2.new(1, 0.5)
        animStopBtn.BackgroundColor3 = Color3.fromRGB(100, 45, 45)
        animStopBtn.BorderSizePixel = 0
        animStopBtn.Text = "⏹️"
        animStopBtn.TextColor3 = Color3.new(1, 1, 1)
        animStopBtn.TextSize = 14
        animStopBtn.Font = Enum.Font.GothamBold
        animStopBtn.ZIndex = 53
        animStopBtn.Parent = animSwapFrame
        createCorner(animStopBtn, 4)

        -- Dropdown menu (hidden by default) - parented to panel to avoid clipping
        local maxVisibleAnims = 8
        local menuHeight = math.min(#animPresets, maxVisibleAnims) * 24 + 6
        local animDropdownMenu = Instance.new("Frame")
        animDropdownMenu.Name = "AnimDropdownMenu"
        animDropdownMenu.Size = UDim2.new(0, 160, 0, menuHeight)
        animDropdownMenu.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
        animDropdownMenu.BorderSizePixel = 0
        animDropdownMenu.ZIndex = 200 -- High ZIndex to be on top
        animDropdownMenu.Visible = false
        animDropdownMenu.Parent = panel -- Parent to panel, not animSwapFrame
        createCorner(animDropdownMenu, 4)
        createStroke(animDropdownMenu, Color3.fromRGB(100, 80, 150), 1)

        -- Position dropdown below the animSwapFrame when shown
        local function positionDropdown()
            local framePos = animSwapFrame.AbsolutePosition
            local panelPos = panel.AbsolutePosition
            animDropdownMenu.Position = UDim2.new(0, framePos.X - panelPos.X + 2, 0,
                framePos.Y - panelPos.Y + animSwapFrame.AbsoluteSize.Y + 2)
        end

        local dropdownScroll = Instance.new("ScrollingFrame")
        dropdownScroll.Size = UDim2.new(1, 0, 1, 0)
        dropdownScroll.BackgroundTransparency = 1
        dropdownScroll.ScrollBarThickness = #animPresets > maxVisibleAnims and 4 or 0
        dropdownScroll.ScrollBarImageColor3 = Color3.fromRGB(150, 100, 200)
        dropdownScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        dropdownScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        dropdownScroll.ZIndex = 201
        dropdownScroll.Parent = animDropdownMenu

        local dropdownLayout = Instance.new("UIListLayout")
        dropdownLayout.Padding = UDim.new(0, 2)
        dropdownLayout.Parent = dropdownScroll

        local dropdownPad = Instance.new("UIPadding")
        dropdownPad.PaddingTop = UDim.new(0, 2)
        dropdownPad.PaddingLeft = UDim.new(0, 2)
        dropdownPad.PaddingRight = UDim.new(0, 2)
        dropdownPad.Parent = dropdownScroll

        for i, animName in ipairs(animPresets) do
            local optBtn = Instance.new("TextButton")
            optBtn.Size = UDim2.new(1, -8, 0, 22)
            optBtn.BackgroundColor3 = i == currentAnimIndex and Color3.fromRGB(50, 35, 80) or Color3.fromRGB(30, 30, 40)
            optBtn.BorderSizePixel = 0
            optBtn.Text = animName
            optBtn.TextColor3 = Color3.new(1, 1, 1)
            optBtn.TextSize = 11
            optBtn.Font = Enum.Font.GothamBold
            optBtn.ZIndex = 202
            optBtn.LayoutOrder = i
            optBtn.Parent = dropdownScroll
            createCorner(optBtn, 3)

            optBtn.MouseButton1Click:Connect(function()
                currentAnimIndex = i
                animDropdown.Text = "🎬 " .. animName .. " ▼"
                animDropdownMenu.Visible = false
                -- Update highlight
                for _, child in ipairs(dropdownScroll:GetChildren()) do
                    if child:IsA("TextButton") then
                        child.BackgroundColor3 = child.LayoutOrder == i and Color3.fromRGB(50, 35, 80) or
                                                     Color3.fromRGB(30, 30, 40)
                    end
                end
            end)
        end

        animDropdown.MouseButton1Click:Connect(function()
            positionDropdown()
            animDropdownMenu.Visible = not animDropdownMenu.Visible
        end)

        -- Helper: Get ALL VISIBLE card models in the Index panel
        -- Game uses: Model > AnimationController > Animator (NOT Humanoid!)
        local function getVisibleCardModels(includeHidden)
            local models = {}

            -- Iterate through cardModelCache which tracks card -> model
            for card, model in pairs(cardModelCache) do
                -- includeHidden = true: get ALL cards (for state tracking)
                -- includeHidden = false/nil: only visible cards with parented model
                local shouldInclude = includeHidden or (card and card.Parent and model and model.Parent)
                if shouldInclude and card and model then
                    -- Get animator from model (game uses AnimationController, not Humanoid)
                    local ac = model:FindFirstChildOfClass("AnimationController")
                    if ac then
                        local animator = ac:FindFirstChildOfClass("Animator")
                        if animator then
                            table.insert(models, {
                                model = model,
                                animator = animator,
                                name = card.Name, -- Card name = animal name
                                card = card,
                                isVisible = model.Parent ~= nil
                            })
                        end
                    end
                end
            end

            return models
        end

        -- Apply animation to a single model
        local function applyAnimToModel(data, animName, speed)
            local folder = AnimalAnimations:FindFirstChild(data.name)
            if not folder then
                return false
            end

            local animObj = folder:FindFirstChild(animName)
            if not animObj then
                for _, child in ipairs(folder:GetChildren()) do
                    if child:IsA("Animation") and child.Name:lower() == animName:lower() then
                        animObj = child
                        break
                    end
                end
            end

            if animObj then
                pcall(function()
                    for _, track in ipairs(data.animator:GetPlayingAnimationTracks()) do
                        track:Stop(0)
                    end
                    local track = data.animator:LoadAnimation(animObj)
                    track.Looped = true
                    track:Play(0)
                    track:AdjustSpeed(speed or 1.0)
                end)
                return true
            end
            return false
        end

        -- Play animation on all visible card models
        local function playAnimOnCards(animName)
            -- Set override state - affects ALL cards including hidden ones when they become visible
            activeAnimOverride = animName

            local models = getVisibleCardModels(false) -- Only visible cards
            local successCount = 0

            for _, data in ipairs(models) do
                if applyAnimToModel(data, animName, currentAnimSpeed) then
                    successCount = successCount + 1
                end
            end

            return successCount, #models
        end

        -- Stop all card animations (Index cards only, NOT podium animals)
        local function stopCardAnims()
            -- Clear override state - hidden cards will stay stopped when visible
            activeAnimOverride = "STOPPED"

            local models = getVisibleCardModels(false) -- Only visible cards
            local count = 0

            -- Stop all animations (freeze the model)
            for _, data in ipairs(models) do
                pcall(function()
                    for _, track in ipairs(data.animator:GetPlayingAnimationTracks()) do
                        track:Stop(0)
                    end
                    count = count + 1
                end)
            end

            return count
        end

        animPlayBtn.MouseButton1Click:Connect(function()
            local animName = animPresets[currentAnimIndex]
            local success, total = playAnimOnCards(animName)
            animPlayBtn.Text = "✅" .. success
            animPlayBtn.BackgroundColor3 = success > 0 and Color3.fromRGB(40, 120, 40) or Color3.fromRGB(120, 60, 40)
            task.delay(1.5, function()
                animPlayBtn.Text = "▶️"
                animPlayBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 50)
            end)
        end)

        animStopBtn.MouseButton1Click:Connect(function()
            local count = stopCardAnims()
            animStopBtn.Text = "⏹️" .. count
            animStopBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            task.delay(1, function()
                animStopBtn.Text = "⏹️"
                animStopBtn.BackgroundColor3 = Color3.fromRGB(100, 45, 45)
            end)
        end)

        -- ========================================================================
        -- SPAWN IN BASE BUTTON - Opens spawn panel
        -- ========================================================================
        local spawnBtnContainer = Instance.new("Frame")
        spawnBtnContainer.Name = "SpawnBtnContainer"
        spawnBtnContainer.Size = UDim2.new(1, -12, 0, LAYOUT.spawnHeight)
        spawnBtnContainer.Position = UDim2.new(0.5, 0, 1, -5) -- Placeholder, set by smart layout
        spawnBtnContainer.AnchorPoint = Vector2.new(0.5, 0)
        spawnBtnContainer.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
        spawnBtnContainer.BorderSizePixel = 0
        spawnBtnContainer.ZIndex = 52
        spawnBtnContainer.Parent = panel
        createCorner(spawnBtnContainer, 6)
        createStroke(spawnBtnContainer, Color3.fromRGB(100, 200, 100), 2)

        local spawnBaseBtn = Instance.new("TextButton")
        spawnBaseBtn.Name = "SpawnInBaseBtn"
        spawnBaseBtn.Size = UDim2.new(1, -8, 0, 36)
        spawnBaseBtn.Position = UDim2.new(0.5, 0, 0.5, 0)
        spawnBaseBtn.AnchorPoint = Vector2.new(0.5, 0.5)
        spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
        spawnBaseBtn.BorderSizePixel = 0
        spawnBaseBtn.Text = "🐾 SPAWN IN BASE (CLIENT)"
        spawnBaseBtn.TextColor3 = Color3.new(1, 1, 1)
        spawnBaseBtn.TextSize = 13
        spawnBaseBtn.Font = Enum.Font.GothamBlack
        spawnBaseBtn.ZIndex = 53
        spawnBaseBtn.Parent = spawnBtnContainer
        createCorner(spawnBaseBtn, 6)

        -- Hover effect for spawn button
        spawnBaseBtn.MouseEnter:Connect(function()
            spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(80, 180, 80)
        end)
        spawnBaseBtn.MouseLeave:Connect(function()
            if spawnModeEnabled then
                spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
            else
                spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
            end
        end)

        spawnBaseBtn.MouseButton1Click:Connect(function()
            spawnModeEnabled = not spawnModeEnabled

            -- Create spawn panel if it doesn't exist
            local spawnPanel = createSpawnPanel(indexFrame)

            if spawnModeEnabled then
                spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
                spawnBaseBtn.Text = "🐾 SPAWN MODE: ON ✓"
                if spawnPanel then
                    spawnPanel.panel.Visible = true
                    spawnPanel.refreshPodiums()
                end
            else
                spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
                spawnBaseBtn.Text = "🐾 SPAWN IN BASE (CLIENT)"
                if spawnPanel then
                    spawnPanel.panel.Visible = false
                end
            end
        end)

        -- Store reference to spawn button for reset when Index closes
        -- Create spawnPanelUI early if it doesn't exist
        if not spawnPanelUI then
            spawnPanelUI = {}
        end
        spawnPanelUI.spawnButton = spawnBaseBtn
        spawnPanelUI.resetSpawnButton = function()
            spawnModeEnabled = false
            spawnBaseBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
            spawnBaseBtn.Text = "🐾 SPAWN IN BASE (CLIENT)"
        end

        -- ========================================================================
        -- SMART LAYOUT - Position elements from bottom up using LAYOUT constants
        -- ========================================================================
        local currentY = LAYOUT.bottomPadding

        -- Spawn button container (bottom-most)
        spawnBtnContainer.Position = UDim2.new(0.5, 0, 1, -currentY - LAYOUT.spawnHeight)
        currentY = currentY + LAYOUT.spawnHeight + LAYOUT.elementGap

        -- Animation Swap buttons frame
        animSwapFrame.Position = UDim2.new(0.5, 0, 1, -currentY - LAYOUT.animControllerHeight)
        currentY = currentY + LAYOUT.animControllerHeight + LAYOUT.elementGap

        -- Audio and Copy Name toggle buttons (side by side)
        audioToggleBtn.Position = UDim2.new(0.02, 0, 1, -currentY - LAYOUT.audioHeight)
        copyNameBtn.Position = UDim2.new(0.98, 0, 1, -currentY - LAYOUT.audioHeight)
        currentY = currentY + LAYOUT.audioHeight + LAYOUT.elementGap

        -- Toggle container (Show All / Hide Admin)
        local actualToggleHeight = LAYOUT.toggleHeight + 10 -- includes padding
        toggleContainer.Position = UDim2.new(0.5, 0, 1, -currentY - actualToggleHeight)
        currentY = currentY + actualToggleHeight + LAYOUT.elementGap

        -- Button container (Copy/Dump buttons)
        buttonContainer.Position = UDim2.new(0.5, 0, 1, -currentY - LAYOUT.buttonContainerHeight)
        currentY = currentY + LAYOUT.buttonContainerHeight + LAYOUT.elementGap

        -- Hide original mutations (move off-screen)
        originalMutations.Position = UDim2.new(10, 0, 10, 0)

        return panel
    end

    -- ============================================================================
    -- MAIN INITIALIZATION
    -- ============================================================================
    local function initialize()
        if isInitialized then
            return true
        end

        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        if not playerGui then
            return false
        end

        local indexUI = playerGui:FindFirstChild("Index")
        if not indexUI then
            return false
        end

        local indexFrame = indexUI:FindFirstChild("Index")
        if not indexFrame then
            return false
        end

        local main = indexFrame:FindFirstChild("Main")
        if not main then
            return false
        end

        local mutations = main:FindFirstChild("Mutations")
        if not mutations then
            return false
        end

        local content = main:FindFirstChild("Content")
        if not content then
            return false
        end

        local holder = content:FindFirstChild("Holder")
        if not holder then
            return false
        end

        local list = holder:FindFirstChild("List")
        if not list then
            return false
        end

        -- ========================================================================
        -- INJECT HIDDEN ANIMAL CARDS - Create cards for animals the game hides
        -- Renders EXACTLY like the game does - proper gradients, colors, etc.
        -- ========================================================================
        local template = list:FindFirstChild("Template")
        if template then
            local injectedCount = 0
            local skippedCount = 0
            print("[IndexV2] Attempting to inject hidden animals. OriginallyHiddenAnimals count: " .. (function()
                local c = 0
                for _ in pairs(OriginallyHiddenAnimals) do
                    c = c + 1
                end
                return c
            end)())

            for animalName, _ in pairs(OriginallyHiddenAnimals) do
                -- Game never creates admin cards - always inject them
                local existingCard = list:FindFirstChild(animalName)
                if existingCard then
                    -- Should never happen, but just in case
                    skippedCount = skippedCount + 1
                else
                    local animalData = AnimalsData[animalName]
                    if animalData then
                        -- Clone template and set up the card
                        local newCard = template:Clone()
                        newCard.Name = animalName
                        newCard.Visible = false -- Start hidden, "Show Admin" will reveal
                        newCard.LayoutOrder = -1 -- PUT AT TOP (negative = before regular cards)

                        -- === RENDER EXACTLY LIKE GAME DOES ===

                        -- Set name label (same as game)
                        local nameLabel = newCard:FindFirstChild("NameLabel")
                        if nameLabel then
                            nameLabel.Text = animalData.DisplayName or animalName
                            nameLabel.Visible = false -- Not indexed = hidden name
                        end

                        -- Set rarity label with PROPER color/gradient (same as game)
                        local rarityLabel = newCard:FindFirstChild("RarityLabel")
                        if rarityLabel then
                            local rarity = animalData.Rarity or "Common"
                            rarityLabel.Text = rarity

                            -- Apply rarity color/gradient EXACTLY like game does
                            local rarityInfo = RaritiesData[rarity]
                            if rarityInfo then
                                if rarityInfo.GradientPreset then
                                    -- Has gradient - apply it
                                    rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
                                    pcall(function()
                                        Gradients.apply(rarityLabel, rarityInfo.GradientPreset)
                                    end)
                                else
                                    -- No gradient - use solid color
                                    rarityLabel.TextColor3 = rarityInfo.Color or Color3.fromRGB(255, 255, 255)
                                end
                            end
                        end

                        -- Set mutation label (Default for admin animals)
                        local mutLabel = newCard:FindFirstChild("MutationLabel")
                        if mutLabel then
                            mutLabel.Text = "Default"
                        end

                        -- Set up viewport with animal model (same as game)
                        local viewport = newCard:FindFirstChild("ViewportFrame")
                        if viewport then
                            viewport.ImageColor3 = Color3.fromRGB(0, 0, 0) -- Dark = not indexed
                            pcall(function()
                                SharedAnimals:AttachOnViewport(animalName, viewport, true, nil, true)
                            end)
                        end

                        -- Mark as injected admin animal
                        newCard:SetAttribute("IndexV2_Injected", true)
                        newCard:SetAttribute("IndexV2_AdminAnimal", true)

                        newCard.Parent = list
                        injectedCount = injectedCount + 1

                        -- Cache with isInjected flag
                        cardCache[newCard] = {
                            name = animalName,
                            originalVisible = false,
                            isInjected = true,
                            isAdminAnimal = true
                        }
                    else
                        print("[IndexV2] WARNING: No AnimalsData for hidden animal: " .. animalName)
                    end
                end
            end

            if injectedCount > 0 then
                print("[IndexV2] ✅ Injected " .. injectedCount ..
                          " admin animal cards at TOP (click 'Show Admin' to see)")
            end
            if skippedCount > 0 then
                print("[IndexV2] Skipped " .. skippedCount .. " cards (already existed)")
            end
        else
            warn("[IndexV2] Template not found in list!")
        end

        -- Create UI components - Top bar goes on the Index frame, not Main
        local topBar = createTopBar(indexFrame)
        local mutationPanel = createMutationPanel(main, mutations, indexFrame)

        if not topBar or not mutationPanel then
            return false
        end

        -- ========================================================================
        -- NUCLEAR OPTION: DESTROY ALL GAME CARDS AND REBUILD FROM SCRATCH
        -- The game's virtualization is too aggressive to fight.
        -- We will: 1. Destroy ALL game-created cards (NOT template)
        --          2. Create our OWN cards with NO virtualization
        --          3. Respect the game's index order using SharedAnimals:GetList
        --          4. Handle admin animals separately
        -- ========================================================================
        local function destroyAndRebuildCards(indexList, template)
            print("[IndexV2] ☢️ =====================================")
            print("[IndexV2] ☢️ DESTROYING ALL GAME CARDS AND REBUILDING")
            print("[IndexV2] ☢️ indexList: " .. tostring(indexList))
            print("[IndexV2] ☢️ template: " .. tostring(template))
            print("[IndexV2] ☢️ =====================================")

            if not indexList then
                warn("[IndexV2] ☢️ ERROR: indexList is nil!")
                return 0
            end

            if not template then
                -- Try to find template ourselves
                template = indexList:FindFirstChild("Template")
                if not template then
                    warn("[IndexV2] ☢️ ERROR: No template found! Cannot rebuild.")
                    return 0
                end
                print("[IndexV2] ☢️ Found template ourselves: " .. tostring(template))
            end

            -- Step 1: Disable game's Heartbeat culling FIRST
            local disabledCount = 0
            pcall(function()
                for _, conn in pairs(getconnections(RunService.Heartbeat)) do
                    local info = getinfo(conn.Function)
                    if info and info.source and string.find(info.source, "Index") then
                        conn:Disable()
                        disabledCount = disabledCount + 1
                    end
                end
            end)
            print("[IndexV2] ☢️ Disabled " .. disabledCount .. " game Heartbeat connections")

            -- Step 2: Get the PROPER animal list order from game (like IndexController does)
            -- Game uses: local v45 = v_u_16:GetList("Generation", true)
            local orderedAnimals = {}
            pcall(function()
                orderedAnimals = SharedAnimals:GetList("Generation", true)
            end)
            print("[IndexV2] ☢️ GetList returned " .. #orderedAnimals .. " animals")

            if #orderedAnimals == 0 then
                -- Fallback: collect from existing cards
                print("[IndexV2] ☢️ Fallback: collecting from existing cards...")
                for _, card in pairs(indexList:GetChildren()) do
                    if card:IsA("ImageLabel") and card.Name ~= "Template" then
                        table.insert(orderedAnimals, card.Name)
                    end
                end
                print("[IndexV2] ☢️ Fallback collected " .. #orderedAnimals .. " animals")
            end

            if #orderedAnimals == 0 then
                warn("[IndexV2] ☢️ ERROR: No animals found! Cannot rebuild.")
                return 0
            end

            -- Step 3: DESTROY all game-created cards (but NOT Template!)
            print("[IndexV2] ☢️ Step 3: Finding cards to destroy...")
            local cardsToDestroy = {}
            for _, card in pairs(indexList:GetChildren()) do
                if card:IsA("ImageLabel") and card.Name ~= "Template" then
                    table.insert(cardsToDestroy, card)
                end
            end
            print("[IndexV2] ☢️ Found " .. #cardsToDestroy .. " cards to destroy")

            for i, card in ipairs(cardsToDestroy) do
                card:Destroy()
                if i % 50 == 0 then
                    print("[IndexV2] ☢️ Destroyed " .. i .. "/" .. #cardsToDestroy .. " cards...")
                end
            end
            task.wait(0.2) -- Let destruction complete
            print("[IndexV2] ☢️ ✅ Destroyed ALL " .. #cardsToDestroy .. " game cards!")

            -- Step 4: CREATE NEW CARDS from scratch in proper order
            print("[IndexV2] ☢️ Step 4: Creating " .. #orderedAnimals .. " new cards...")
            local createdCount = 0
            local adminCount = 0

            for layoutOrder, animalName in ipairs(orderedAnimals) do
                local animalData = AnimalsData[animalName]
                if animalData then
                    -- Check if this animal can show in index (game uses SharedIndex:CanShowInIndex)
                    local canShow = true
                    pcall(function()
                        canShow = SharedIndex:CanShowInIndex(animalName)
                    end)

                    -- Check if it's an admin/hidden animal
                    local isAdminAnimal = OriginallyHiddenAnimals[animalName] ~= nil

                    -- Clone template
                    local newCard = template:Clone()
                    newCard.Name = animalName
                    newCard.LayoutOrder = layoutOrder

                    -- Admin animals start hidden (user can toggle with "Show Admin")
                    -- Regular animals that can't show also start hidden
                    if isAdminAnimal then
                        newCard.Visible = false
                        newCard:SetAttribute("IndexV2_AdminAnimal", true)
                        adminCount = adminCount + 1
                    else
                        newCard.Visible = canShow
                    end

                    -- Set name label
                    local nameLabel = newCard:FindFirstChild("NameLabel")
                    if nameLabel then
                        nameLabel.Text = animalData.DisplayName or animalName
                        nameLabel.Visible = true -- ALWAYS VISIBLE (we override game's indexed check)
                    end

                    -- Set rarity label with proper color/gradient
                    local rarityLabel = newCard:FindFirstChild("RarityLabel")
                    if rarityLabel then
                        local rarity = animalData.Rarity or "Common"
                        rarityLabel.Text = rarity
                        local rarityInfo = RaritiesData[rarity]
                        if rarityInfo then
                            if rarityInfo.GradientPreset then
                                rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
                                pcall(function()
                                    Gradients.apply(rarityLabel, rarityInfo.GradientPreset)
                                end)
                            else
                                rarityLabel.TextColor3 = rarityInfo.Color or Color3.fromRGB(255, 255, 255)
                            end
                        end
                    end

                    -- Set mutation label (Normal by default)
                    local mutLabel = newCard:FindFirstChild("MutationLabel")
                    if mutLabel then
                        mutLabel.Text = "Normal"
                    end

                    -- Set up viewport with animal model
                    local viewport = newCard:FindFirstChild("ViewportFrame")
                    if viewport then
                        viewport.ImageColor3 = Color3.fromRGB(255, 255, 255) -- WHITE, not black!
                        pcall(function()
                            SharedAnimals:AttachOnViewport(animalName, viewport, true, nil, true)
                        end)
                    end

                    -- Mark as our card
                    newCard:SetAttribute("IndexV2_OurCard", true)

                    -- Add to list
                    newCard.Parent = indexList

                    -- Cache it
                    cardCache[newCard] = {
                        name = animalName,
                        isAdminAnimal = isAdminAnimal
                    }

                    createdCount = createdCount + 1
                end
            end

            -- Also add hidden/admin animals that might not be in the ordered list
            for animalName, _ in pairs(OriginallyHiddenAnimals) do
                -- Check if we already created this card
                if not indexList:FindFirstChild(animalName) then
                    local animalData = AnimalsData[animalName]
                    if animalData then
                        local newCard = template:Clone()
                        newCard.Name = animalName
                        newCard.LayoutOrder = 99999 -- Put at end
                        newCard.Visible = false -- Hidden by default
                        newCard:SetAttribute("IndexV2_AdminAnimal", true)
                        newCard:SetAttribute("IndexV2_OurCard", true)

                        local nameLabel = newCard:FindFirstChild("NameLabel")
                        if nameLabel then
                            nameLabel.Text = animalData.DisplayName or animalName
                            nameLabel.Visible = true
                        end

                        local rarityLabel = newCard:FindFirstChild("RarityLabel")
                        if rarityLabel then
                            local rarity = animalData.Rarity or "Common"
                            rarityLabel.Text = rarity
                            local rarityInfo = RaritiesData[rarity]
                            if rarityInfo then
                                if rarityInfo.GradientPreset then
                                    rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
                                    pcall(function()
                                        Gradients.apply(rarityLabel, rarityInfo.GradientPreset)
                                    end)
                                else
                                    rarityLabel.TextColor3 = rarityInfo.Color or Color3.fromRGB(255, 255, 255)
                                end
                            end
                        end

                        local mutLabel = newCard:FindFirstChild("MutationLabel")
                        if mutLabel then
                            mutLabel.Text = "Normal"
                        end

                        local viewport = newCard:FindFirstChild("ViewportFrame")
                        if viewport then
                            viewport.ImageColor3 = Color3.fromRGB(255, 255, 255)
                            pcall(function()
                                SharedAnimals:AttachOnViewport(animalName, viewport, true, nil, true)
                            end)
                        end

                        newCard.Parent = indexList
                        cardCache[newCard] = {
                            name = animalName,
                            isAdminAnimal = true
                        }
                        adminCount = adminCount + 1
                    end
                end
            end

            print("[IndexV2] ☢️ Created " .. createdCount .. " cards + " .. adminCount .. " admin cards!")
            return createdCount
        end

        -- DISCONNECT GAME'S ORIGINAL SIGNAL CONNECTIONS ON CARDS
        -- The game connects each card to its internal signal (v_u_38) which overrides our mutations
        -- We need to disconnect those so our mutations stick
        local function disconnectGameSignals(card)
            if card:GetAttribute("IndexV2_GameDisconnected") then
                return
            end
            card:SetAttribute("IndexV2_GameDisconnected", true)

            -- Disconnect connections on the card's viewport (game connects mutation update here)
            local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
            if viewport then
                pcall(function()
                    for _, conn in pairs(getconnections(viewport:GetPropertyChangedSignal("ImageColor3"))) do
                        if conn.Function and not string.find(tostring(conn.Function), "IndexV2") then
                            conn:Disable()
                        end
                    end
                end)
            end

            -- Disconnect connections on MutationLabel (game updates this)
            local mutLabel = card:FindFirstChild("MutationLabel")
            if mutLabel then
                pcall(function()
                    for _, conn in pairs(getconnections(mutLabel:GetPropertyChangedSignal("Text"))) do
                        -- Disable game's connections but not ours
                        conn:Disable()
                    end
                end)
            end

            -- Disconnect connections on NameLabel.Visible (game sets this based on indexed status)
            local nameLabel = card:FindFirstChild("NameLabel")
            if nameLabel then
                pcall(function()
                    for _, conn in pairs(getconnections(nameLabel:GetPropertyChangedSignal("Visible"))) do
                        conn:Disable()
                    end
                end)
            end
        end

        -- Initial indicator setup - CONNECT ALL EXISTING CARDS TO SIGNAL
        local initialCardCount = 0
        for _, card in pairs(list:GetChildren()) do
            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                initialCardCount = initialCardCount + 1
                local animalName = card.Name
                cardCache[card] = {
                    name = animalName
                }

                -- DISCONNECT GAME'S HANDLERS FIRST
                disconnectGameSignals(card)

                -- HOOK VIEWPORT (or hook card to catch when viewport is added)
                local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
                if viewport then
                    hookViewport(viewport)
                    viewport.ImageColor3 = Color3.new(1, 1, 1)
                else
                    -- Hook card to catch when viewport is added
                    card.ChildAdded:Connect(function(child)
                        if child:IsA("ViewportFrame") then
                            hookViewport(child)
                            child.ImageColor3 = Color3.new(1, 1, 1)
                            -- Apply current mutation when viewport is added
                            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                                applyMutationToCard(card, animalName, currentMutation)
                            end
                        end
                    end)
                end

                -- Hook the mutation label
                local mutLabel = card:FindFirstChild("MutationLabel")
                if mutLabel then
                    hookMutationLabel(mutLabel, card)
                end

                updateCardIndicator(card, animalName)

                -- Mark as connected so we don't double-connect later
                card:SetAttribute("IndexV2_SignalConnected", true)

                -- CONNECT CARD TO MUTATION SIGNAL (like game does with v_u_38)
                local mutationConn = MutationChanged:Connect(function(newMutation)
                    if card and card.Parent then
                        applyMutationToCard(card, animalName, newMutation)
                        updateCardIndicator(card, animalName)
                    end
                end)

                -- Cleanup connection when card is removed (recycled by virtualization)
                card.AncestryChanged:Connect(function(_, parent)
                    if not parent then
                        mutationConn:Disconnect()
                    end
                end)

                -- Make the ENTIRE card clickable (not just the button inside)
                -- Create invisible button overlay if needed
                local clickOverlay = card:FindFirstChild("IndexV2_ClickOverlay")
                if not clickOverlay then
                    clickOverlay = Instance.new("TextButton")
                    clickOverlay.Name = "IndexV2_ClickOverlay"
                    clickOverlay.Size = UDim2.new(1, 0, 1, 0)
                    clickOverlay.Position = UDim2.new(0, 0, 0, 0)
                    clickOverlay.BackgroundTransparency = 1
                    clickOverlay.Text = ""
                    clickOverlay.ZIndex = 100
                    clickOverlay.Parent = card
                end

                -- Always connect click handler (use attribute to prevent double-connect)
                if not card:GetAttribute("IndexV2_ClickConnected") then
                    card:SetAttribute("IndexV2_ClickConnected", true)
                    clickOverlay.MouseButton1Click:Connect(function()
                        if copyNameEnabled then
                            if setclipboard then
                                local animalData = AnimalsData[card.Name]
                                local displayName = animalData and animalData.DisplayName or card.Name
                                setclipboard(displayName)
                                print("[IndexV2] 📋 Copied: " .. displayName)
                            end
                        elseif spawnModeEnabled then
                            spawnAnimalFromCard(card.Name)
                        else
                            playAnimalSound(card.Name)
                        end
                    end)
                end
            end
        end
        print("[IndexV2] ✅ Connected " .. initialCardCount .. " EXISTING cards to MutationChanged signal")

        -- ☢️ DESTROY AND REBUILD ALL CARDS
        -- This completely replaces the game's virtualized cards with our own
        destroyAndRebuildCards(list, template)

        -- Wait for rebuild to complete
        task.wait(0.5)

        -- Now connect OUR new cards to the mutation system
        print("[IndexV2] Connecting rebuilt cards to mutation system...")
        for _, card in pairs(list:GetChildren()) do
            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                local animalName = card.Name

                -- Cache if not already
                if not cardCache[card] then
                    cardCache[card] = {
                        name = animalName
                    }
                end

                -- Connect to mutation signal
                if not card:GetAttribute("IndexV2_SignalConnected") then
                    card:SetAttribute("IndexV2_SignalConnected", true)

                    local mutationConn = MutationChanged:Connect(function(newMutation)
                        if card and card.Parent then
                            applyMutationToCard(card, animalName, newMutation)
                            updateCardIndicator(card, animalName)
                        end
                    end)

                    card.AncestryChanged:Connect(function(_, parent)
                        if not parent then
                            mutationConn:Disconnect()
                        end
                    end)
                end

                -- Add click handler
                local clickOverlay = card:FindFirstChild("IndexV2_ClickOverlay")
                if not clickOverlay then
                    clickOverlay = Instance.new("TextButton")
                    clickOverlay.Name = "IndexV2_ClickOverlay"
                    clickOverlay.Size = UDim2.new(1, 0, 1, 0)
                    clickOverlay.Position = UDim2.new(0, 0, 0, 0)
                    clickOverlay.BackgroundTransparency = 1
                    clickOverlay.Text = ""
                    clickOverlay.ZIndex = 100
                    clickOverlay.Parent = card
                end

                -- Always connect click handler (use attribute to prevent double-connect)
                if not card:GetAttribute("IndexV2_ClickConnected") then
                    card:SetAttribute("IndexV2_ClickConnected", true)
                    clickOverlay.MouseButton1Click:Connect(function()
                        if copyNameEnabled then
                            if setclipboard then
                                local animalData = AnimalsData[card.Name]
                                local displayName = animalData and animalData.DisplayName or card.Name
                                setclipboard(displayName)
                                print("[IndexV2] 📋 Copied: " .. displayName)
                            end
                        elseif spawnModeEnabled then
                            spawnAnimalFromCard(card.Name)
                        else
                            playAnimalSound(card.Name)
                        end
                    end)
                end

                -- Update indicator
                updateCardIndicator(card, animalName)
            end
        end
        print("[IndexV2] ✅ Rebuilt cards connected to mutation system")

        -- SCAN AND HOOK ALL VIEWPORTS in the entire Index GUI hierarchy
        -- The game may store viewports separately and reparent them on demand
        local viewportCount = 0
        for _, descendant in pairs(indexFrame:GetDescendants()) do
            if descendant:IsA("ViewportFrame") then
                hookViewport(descendant)
                descendant.ImageColor3 = Color3.new(1, 1, 1) -- Force white
                viewportCount = viewportCount + 1

                -- FORCE PARENT to card if not already
                local parent = descendant.Parent
                if parent and parent:IsA("ImageLabel") and parent.Name ~= "Template" then
                    -- Already parented correctly
                else
                    -- Find the card this viewport belongs to and parent it
                    -- Check all cards for one missing a viewport
                    for _, card in pairs(list:GetChildren()) do
                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                            if not card:FindFirstChildWhichIsA("ViewportFrame") then
                                descendant.Parent = card
                                break
                            end
                        end
                    end
                end
            end
        end
        print("[IndexV2] ✅ Hooked " .. viewportCount .. " ViewportFrames")

        -- Also watch for new ViewportFrames being added anywhere in the Index
        indexFrame.DescendantAdded:Connect(function(descendant)
            if descendant:IsA("ViewportFrame") then
                hookViewport(descendant)
                descendant.ImageColor3 = Color3.new(1, 1, 1)
            end
        end)

        -- Watch for new cards (game creates them as you scroll - virtualization)
        list.ChildAdded:Connect(function(card)
            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                local animalName = card.Name
                cardCache[card] = {
                    name = animalName
                }

                -- DISCONNECT GAME'S HANDLERS FIRST (before they can fire)
                disconnectGameSignals(card)

                -- Hook viewport FIRST to catch model when it's added
                local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
                if viewport then
                    hookViewport(viewport)
                    viewport.ImageColor3 = Color3.new(1, 1, 1)
                else
                    -- Hook card to catch when viewport is added
                    card.ChildAdded:Connect(function(child)
                        if child:IsA("ViewportFrame") then
                            hookViewport(child)
                            child.ImageColor3 = Color3.new(1, 1, 1)
                            -- Apply current mutation when viewport is added
                            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                                applyMutationToCard(card, animalName, currentMutation)
                            end
                        end
                    end)
                end

                -- Hook the mutation label immediately
                local mutLabel = card:FindFirstChild("MutationLabel")
                if mutLabel then
                    hookMutationLabel(mutLabel, card)
                end

                -- Skip if already connected (prevents double connection)
                if card:GetAttribute("IndexV2_SignalConnected") then
                    return
                end
                card:SetAttribute("IndexV2_SignalConnected", true)

                -- CONNECT CARD TO MUTATION SIGNAL (like game does with v_u_38)
                -- This card will update itself whenever mutation changes
                local mutationConn = MutationChanged:Connect(function(newMutation)
                    if card and card.Parent then
                        applyMutationToCard(card, animalName, newMutation)
                        updateCardIndicator(card, animalName)
                    end
                end)

                -- Cleanup connection when card is removed
                card.AncestryChanged:Connect(function(_, parent)
                    if not parent then
                        mutationConn:Disconnect()
                    end
                end)

                -- Apply current mutation NOW if not Default
                if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                    applyMutationToCard(card, animalName, currentMutation)
                end

                updateCardIndicator(card, animalName)

                -- Make the ENTIRE card clickable (not just the button inside)
                -- Create invisible button overlay if needed
                local clickOverlay = card:FindFirstChild("IndexV2_ClickOverlay")
                if not clickOverlay then
                    clickOverlay = Instance.new("TextButton")
                    clickOverlay.Name = "IndexV2_ClickOverlay"
                    clickOverlay.Size = UDim2.new(1, 0, 1, 0)
                    clickOverlay.Position = UDim2.new(0, 0, 0, 0)
                    clickOverlay.BackgroundTransparency = 1
                    clickOverlay.Text = ""
                    clickOverlay.ZIndex = 100
                    clickOverlay.Parent = card
                end

                clickOverlay.MouseButton1Click:Connect(function()
                    if spawnModeEnabled then
                        spawnAnimalFromCard(card.Name)
                    else
                        playAnimalSound(card.Name)
                    end
                end)
            end
        end)

        -- Listen for index data changes
        local playerData = Synchronizer:Get(LocalPlayer)
        if playerData then
            pcall(function()
                playerData:Listen("Index", updateAllIndicators)
            end)
            pcall(function()
                playerData:ListenDeep("Index", updateAllIndicators)
            end)
        end

        isInitialized = true
        print("[IndexV2] Initialized successfully!")

        -- Apply initial filters (especially Hide Admin Animals which is ON by default)
        task.delay(0.2, function()
            applyFilters(list)
        end)

        -- ========================================================================
        -- TAKE OVER INDEX COUNTER - Fix the misleading "132/162" to show actual required
        -- ========================================================================
        local progressFrame = indexFrame:FindFirstChild("Progress")
        local headerFrame = main:FindFirstChild("Header")

        -- Get and STORE the counter elements for heartbeat access
        local barFrame = progressFrame and progressFrame:FindFirstChild("Bar")
        counterElements.headerTotal = headerFrame and headerFrame:FindFirstChild("Total")
        counterElements.barNumber = barFrame and barFrame:FindFirstChild("Number")
        counterElements.barLoading = barFrame and barFrame:FindFirstChild("Loading")
        counterElements.descLabel = progressFrame and progressFrame:FindFirstChild("Description")

        print("[IndexV2] Counter elements captured for heartbeat")

        -- Initial update
        updateIndexCounter()

        return true
    end

    -- ============================================================================
    -- HOOK: Block game from setting black shadows on ViewportFrames
    -- Instead of racing the game's heartbeat, we hook __newindex to block it
    -- ============================================================================
    local WHITE = Color3.new(1, 1, 1)
    local BLACK = Color3.new(0, 0, 0)
    local hookedViewports = setmetatable({}, {
        __mode = "k"
    }) -- Weak keys for GC

    hookViewport = function(viewport)
        if hookedViewports[viewport] then
            return
        end
        hookedViewports[viewport] = true

        -- Use a connection to override any color change
        local conn
        conn = viewport:GetPropertyChangedSignal("ImageColor3"):Connect(function()
            if viewport.ImageColor3 == BLACK then
                viewport.ImageColor3 = WHITE
            end
        end)

        -- Hook model changes - game creates ViewportFrame > WorldModel > Model
        -- We need DescendantAdded to catch the Model inside WorldModel
        local modelConn
        modelConn = viewport.DescendantAdded:Connect(function(child)
            if child:IsA("Model") then
                -- Game just added the model - cache it and apply mutation
                local card = viewport.Parent
                if card and card:IsA("ImageLabel") then
                    -- Cache model reference like game's v_u_58
                    cardModelCache[card] = child

                    if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                        appliedMutations[card] = nil
                        applyMutationToCard(card, card.Name, currentMutation)
                        updateCardIndicator(card, card.Name)
                    end
                end
            elseif child:IsA("WorldModel") then
                -- WorldModel was added - hook its children too
                child.ChildAdded:Connect(function(modelChild)
                    if modelChild:IsA("Model") then
                        local card = viewport.Parent
                        if card and card:IsA("ImageLabel") then
                            cardModelCache[card] = modelChild
                            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                                appliedMutations[card] = nil
                                applyMutationToCard(card, card.Name, currentMutation)
                                updateCardIndicator(card, card.Name)
                            end
                        end
                    end
                end)
                -- Check if WorldModel already has a model
                local existingModel = child:FindFirstChildWhichIsA("Model")
                if existingModel then
                    local card = viewport.Parent
                    if card and card:IsA("ImageLabel") then
                        cardModelCache[card] = existingModel
                        if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                            task.defer(function()
                                applyMutationToCard(card, card.Name, currentMutation)
                                updateCardIndicator(card, card.Name)
                            end)
                        end
                    end
                end
            end
        end)

        -- Hook WorldModel's that ALREADY exist in viewport
        for _, child in ipairs(viewport:GetChildren()) do
            if child:IsA("WorldModel") then
                child.ChildAdded:Connect(function(modelChild)
                    if modelChild:IsA("Model") then
                        local card = viewport.Parent
                        if card and card:IsA("ImageLabel") then
                            cardModelCache[card] = modelChild
                            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                                appliedMutations[card] = nil
                                applyMutationToCard(card, card.Name, currentMutation)
                                updateCardIndicator(card, card.Name)
                            end
                        end
                    end
                end)
            end
        end

        -- Check for EXISTING model in viewport (already loaded from previous use)
        -- This is critical for virtualized cards that come back into view
        local card = viewport.Parent
        if card and card:IsA("ImageLabel") then
            local existingModel = nil
            local worldModel = viewport:FindFirstChildWhichIsA("WorldModel")
            if worldModel then
                existingModel = worldModel:FindFirstChildWhichIsA("Model")
            else
                existingModel = viewport:FindFirstChildWhichIsA("Model")
            end
            if existingModel then
                cardModelCache[card] = existingModel
                -- Apply mutation immediately if we have one selected
                if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                    task.defer(function()
                        applyMutationToCard(card, card.Name, currentMutation)
                        updateCardIndicator(card, card.Name)
                    end)
                end
            end
        end

        -- CRITICAL: Hook when viewport is RE-PARENTED (game's culling system activates it)
        -- This is how the game's virtualization works - viewport.Parent changes when scrolled into view
        local parentConn
        parentConn = viewport:GetPropertyChangedSignal("Parent"):Connect(function()
            local card = viewport.Parent
            if card and card:IsA("ImageLabel") then
                -- Viewport just got activated (parented to card) - apply mutation!
                viewport.ImageColor3 = WHITE -- Force white immediately

                -- Force name label visible
                local nameLabel = card:FindFirstChild("NameLabel")
                if nameLabel then
                    nameLabel.Visible = true
                end

                -- Check if there's a SCHEDULED UPDATE for this card (like game's scheduledUpdate)
                -- This happens when mutation changed while card was not visible
                if scheduledCardUpdates[card] then
                    local scheduledFn = scheduledCardUpdates[card]
                    scheduledCardUpdates[card] = nil
                    task.defer(scheduledFn)
                    -- Otherwise apply current mutation if we have one selected
                elseif currentMutation ~= "Default" and currentMutation ~= "Normal" then
                    task.defer(function()
                        if viewport.Parent == card then -- Still parented
                            applyMutationToCard(card, card.Name, currentMutation)
                            updateCardIndicator(card, card.Name)
                        end
                    end)
                end
            end
        end)

        -- Clean up when viewport is destroyed
        viewport.AncestryChanged:Connect(function(_, parent)
            if not parent then
                conn:Disconnect()
                modelConn:Disconnect()
                parentConn:Disconnect()
                hookedViewports[viewport] = nil
            end
        end)
    end

    local function hookNameLabel(label)
        -- Force NameLabel to always be visible
        local conn
        conn = label:GetPropertyChangedSignal("Visible"):Connect(function()
            if not label.Visible then
                label.Visible = true
            end
        end)

        label.AncestryChanged:Connect(function(_, parent)
            if not parent then
                conn:Disconnect()
            end
        end)
    end

    -- Hook MutationLabel to prevent game from overwriting our text
    local hookedMutationLabels = setmetatable({}, {
        __mode = "k"
    })

    hookMutationLabel = function(label, card)
        if hookedMutationLabels[label] then
            return
        end
        hookedMutationLabels[label] = true

        local conn
        conn = label:GetPropertyChangedSignal("Text"):Connect(function()
            -- If game tries to set it back to "Default" or "Normal" when we have a mutation selected
            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                local newText = label.Text
                if newText == "Default" or newText == "Normal" then
                    -- Game is trying to reset it - reapply our mutation IMMEDIATELY
                    appliedMutations[card] = nil
                    applyMutationToCard(card, card.Name, currentMutation)
                end
            end
        end)

        label.AncestryChanged:Connect(function(_, parent)
            if not parent then
                conn:Disconnect()
                hookedMutationLabels[label] = nil
            end
        end)
    end

    -- ============================================================================
    -- OCCLUSION SYSTEM - Imitates game's Heartbeat-based viewport culling
    -- This improves performance by only rendering visible cards
    -- ============================================================================

    -- Register a viewport for occlusion tracking (like game's v_u_36)
    local function registerViewportForOcclusion(viewport, card, layoutOrder)
        if not viewport or not card then
            return
        end

        viewportTracking[viewport] = {
            targetParent = card,
            state = nil, -- nil = unknown, true = visible, false = hidden
            scheduledUpdate = nil
        }
        cardLayoutIndex[card] = layoutOrder or card.LayoutOrder or 0
    end

    -- Unregister viewport from occlusion
    local function unregisterViewportFromOcclusion(viewport)
        if viewport then
            viewportTracking[viewport] = nil
        end
    end

    -- Update layout indices for all cards (called when layout changes)
    local function updateLayoutIndices(list)
        if not list then
            return
        end

        -- Get all visible cards sorted by layout order
        local cards = {}
        for _, child in pairs(list:GetChildren()) do
            if child:IsA("ImageLabel") and child.Name ~= "Template" and child.Visible then
                table.insert(cards, child)
            end
        end

        -- Sort by LayoutOrder, then by Name
        table.sort(cards, function(a, b)
            if a.LayoutOrder == b.LayoutOrder then
                return a.Name < b.Name
            end
            return a.LayoutOrder < b.LayoutOrder
        end)

        -- Assign indices
        table.clear(cardLayoutIndex)
        for i, card in ipairs(cards) do
            cardLayoutIndex[card] = i
        end
    end

    -- Update occlusion state from UI layout (like game's scroll/position tracking)
    local function updateOcclusionState(list, gridLayout, indexFrame)
        if not list then
            return
        end

        occlusionState.listTop = list.AbsolutePosition.Y
        occlusionState.listBottom = occlusionState.listTop + list.AbsoluteSize.Y
        occlusionState.scrollOffset = occlusionState.listTop - list.CanvasPosition.Y

        if gridLayout then
            occlusionState.cellSize = gridLayout.AbsoluteCellSize
            occlusionState.cellCount = gridLayout.AbsoluteCellCount
            local padding = gridLayout.CellPadding
            occlusionState.cellPaddingY = padding.Y.Scale * list.AbsoluteSize.Y + padding.Y.Offset
        end

        occlusionState.isVisible = indexFrame and indexFrame.Visible or false
    end

    -- Main occlusion culling function (like game's Heartbeat cull loop)
    local function performOcclusionCull()
        if not occlusionState.enabled then
            return
        end

        local buffer = occlusionState.cellSize.Y * 2 -- v_u_98.Y * 2 - render 2 rows ahead
        local columnsPerRow = occlusionState.cellCount.X
        if columnsPerRow < 1 then
            columnsPerRow = 1
        end

        for viewport, tracking in pairs(viewportTracking) do
            local card = tracking.targetParent
            if card then
                local layoutIndex = cardLayoutIndex[card]
                local shouldBeVisible = false

                if layoutIndex and occlusionState.isVisible then
                    -- Calculate which row this card is in (0-indexed)
                    local rowIndex = math.ceil(layoutIndex / columnsPerRow) - 1

                    -- Calculate Y position of this row
                    local rowTop = occlusionState.scrollOffset +
                                       (occlusionState.cellSize.Y + occlusionState.cellPaddingY) * rowIndex -
                                       occlusionState.cellPaddingY
                    local rowBottom = rowTop + occlusionState.cellSize.Y

                    -- Check if row is within visible area (with buffer)
                    if occlusionState.listTop < rowBottom then
                        shouldBeVisible = rowTop < occlusionState.listBottom + buffer
                    end
                end

                -- State changed?
                if tracking.state ~= shouldBeVisible then
                    -- Update viewport parent
                    if shouldBeVisible then
                        viewport.Parent = card

                        -- Apply animation override if set when card becomes visible
                        if _G.IndexV2_AnimState then
                            task.defer(function()
                                -- Wait longer for game's default animation to start, then override
                                task.wait(0.1)
                                local animOverride, animSpeed = _G.IndexV2_AnimState.getOverride()
                                local model = cardModelCache[card]
                                if model then
                                    local ac = model:FindFirstChildOfClass("AnimationController")
                                    if ac then
                                        local animator = ac:FindFirstChildOfClass("Animator")
                                        if animator then
                                            -- Re-check state in case it changed
                                            animOverride, animSpeed = _G.IndexV2_AnimState.getOverride()

                                            -- Stop all current tracks first
                                            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                                                track:Stop(0)
                                            end
                                            -- If STOPPED, don't play any animation (freeze)
                                            if animOverride == "STOPPED" then
                                                -- Do nothing, keep frozen
                                            else
                                                -- Apply override or default Idle
                                                local animName = animOverride or "Idle"
                                                local folder = AnimalAnimations:FindFirstChild(card.Name)
                                                if folder then
                                                    local animObj = folder:FindFirstChild(animName)
                                                    if animObj then
                                                        local track = animator:LoadAnimation(animObj)
                                                        track.Looped = true
                                                        track:Play(0)
                                                        if animOverride then
                                                            track:AdjustSpeed(animSpeed or 1.0)
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end)
                        end
                    else
                        viewport.Parent = nil
                    end
                    tracking.state = shouldBeVisible

                    -- If becoming visible and has scheduled update, run it
                    if shouldBeVisible and tracking.scheduledUpdate then
                        local updateFn = tracking.scheduledUpdate
                        tracking.scheduledUpdate = nil
                        task.defer(updateFn)
                    end
                end
            end -- end if card
        end
    end

    -- Schedule an update for when viewport becomes visible
    local function scheduleViewportUpdate(viewport, updateFn)
        local tracking = viewportTracking[viewport]
        if tracking then
            if tracking.state == true then
                -- Already visible, run immediately
                task.defer(updateFn)
            else
                -- Schedule for when it becomes visible
                tracking.scheduledUpdate = updateFn
            end
        else
            -- Not tracked, run immediately
            task.defer(updateFn)
        end
    end

    -- ============================================================================
    -- HEARTBEAT LOOP - Only for counter updates and hooks, NOT mutation reapply
    -- Mutations are applied ONCE via signal pattern like the game does
    -- ============================================================================
    local counterThrottle = 0
    local COUNTER_INTERVAL = 2.0 -- Counter every 2 seconds

    local function startHeartbeat()
        if heartbeatConnection then
            heartbeatConnection:Disconnect()
        end

        heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
            counterThrottle = counterThrottle + deltaTime

            -- Update counter less frequently
            if counterThrottle >= COUNTER_INTERVAL then
                counterThrottle = 0
                task.defer(updateIndexCounter)
            end

            if not isInitialized then
                return
            end

            local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
            if not playerGui then
                return
            end

            local indexUI = playerGui:FindFirstChild("Index")
            if not indexUI then
                return
            end

            local indexFrame = indexUI:FindFirstChild("Index")
            if not indexFrame or not indexFrame.Visible then
                lastIndexVisible = false
                -- Close spawn panel when Index is not visible
                if spawnPanelUI and spawnPanelUI.panel then
                    spawnPanelUI.panel.Visible = false
                end
                -- Always reset spawn mode and button when Index closes
                spawnModeEnabled = false
                if spawnPanelUI and spawnPanelUI.resetSpawnButton then
                    spawnPanelUI.resetSpawnButton()
                end
                -- Reset occlusion tracking states so cards re-trigger visibility handler when Index reopens
                for viewport, tracking in pairs(viewportTracking) do
                    tracking.state = nil
                end
                return
            end

            -- Detect when Index UI becomes visible - RESTORE FULL STATE (mutation, search, filters)
            if not lastIndexVisible then
                lastIndexVisible = true
                task.defer(function()
                    local main = indexFrame:FindFirstChild("Main")
                    if main then
                        -- Restore search text in search box
                        local topBar = indexFrame:FindFirstChild("IndexV2TopBar")
                        if topBar then
                            local searchBox = topBar:FindFirstChild("SearchBox")
                            if searchBox and currentSearch ~= "" then
                                searchBox.Text = currentSearch
                            end
                        end

                        local content = main:FindFirstChild("Content")
                        if content then
                            local holder = content:FindFirstChild("Holder")
                            if holder then
                                local list = holder:FindFirstChild("List")
                                if list then
                                    -- CONNECT ALL CARDS TO SIGNAL (they may not be connected yet!)
                                    local connectedCount = 0
                                    for _, card in pairs(list:GetChildren()) do
                                        if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                            local animalName = card.Name

                                            -- DISCONNECT GAME'S HANDLERS
                                            disconnectGameSignals(card)

                                            -- Skip if already connected (check for attribute)
                                            if not card:GetAttribute("IndexV2_SignalConnected") then
                                                card:SetAttribute("IndexV2_SignalConnected", true)
                                                connectedCount = connectedCount + 1

                                                -- Add to cache if not already
                                                if not cardCache[card] then
                                                    cardCache[card] = {
                                                        name = animalName
                                                    }
                                                end

                                                -- CONNECT to signal
                                                local mutationConn =
                                                    MutationChanged:Connect(function(newMutation)
                                                        if card and card.Parent then
                                                            applyMutationToCard(card, animalName, newMutation)
                                                            updateCardIndicator(card, animalName)
                                                        end
                                                    end)

                                                -- Cleanup when removed
                                                card.AncestryChanged:Connect(function(_, parent)
                                                    if not parent then
                                                        mutationConn:Disconnect()
                                                    end
                                                end)
                                            end
                                        end
                                    end
                                    if connectedCount > 0 then
                                        print("[IndexV2] Connected " .. connectedCount ..
                                                  " cards to signal on Index open")
                                    end

                                    -- Apply filters (uses currentFilter state)
                                    applyFilters(list)

                                    -- Apply mutation to ALL cards if we have one selected
                                    if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                                        for _, card in pairs(list:GetChildren()) do
                                            if card:IsA("ImageLabel") and card.Name ~= "Template" then
                                                applyMutationToCard(card, card.Name, currentMutation)
                                            end
                                        end
                                        -- Also fire signal for any future scrolling
                                        MutationChanged:Fire(currentMutation)
                                    end
                                end
                            end
                        end
                    end
                end)
            end

            local main = indexFrame:FindFirstChild("Main")
            if not main then
                return
            end

            local content = main:FindFirstChild("Content")
            if not content then
                return
            end

            local holder = content:FindFirstChild("Holder")
            if not holder then
                return
            end

            local list = holder:FindFirstChild("List")
            if not list then
                return
            end

            -- ================================================================
            -- OCCLUSION-BASED CULLING - Imitates game's system for performance
            -- Only renders viewports that are visible in scroll area
            -- ================================================================
            local gridLayout = list:FindFirstChildWhichIsA("UIGridLayout")

            -- Update occlusion state
            updateOcclusionState(list, gridLayout, indexFrame)

            -- Register any new cards/viewports for occlusion tracking
            for _, card in pairs(list:GetChildren()) do
                if card:IsA("ImageLabel") and card.Name ~= "Template" then
                    local viewport = card:FindFirstChildWhichIsA("ViewportFrame")

                    -- Try to find viewport in descendants if not direct child
                    if not viewport then
                        for _, desc in pairs(card:GetDescendants()) do
                            if desc:IsA("ViewportFrame") then
                                viewport = desc
                                break
                            end
                        end
                    end

                    if viewport then
                        -- Register for occlusion if not already
                        if not viewportTracking[viewport] then
                            registerViewportForOcclusion(viewport, card, card.LayoutOrder)
                        end

                        -- Cache viewport reference
                        if not viewportCache[card] then
                            viewportCache[card] = viewport
                        end

                        -- Force WHITE (no black silhouettes!) for visible viewports
                        if viewport.Parent and viewport.ImageColor3 ~= WHITE then
                            viewport.ImageColor3 = WHITE
                        end
                    end

                    -- Force labels visible on visible cards
                    local nameLabel = card:FindFirstChild("NameLabel")
                    if nameLabel and not nameLabel.Visible then
                        nameLabel.Visible = true
                    end

                    local mutationLabel = card:FindFirstChild("MutationLabel")
                    if mutationLabel and not mutationLabel.Visible then
                        mutationLabel.Visible = true
                    end

                    local rarityLabel = card:FindFirstChild("RarityLabel")
                    if rarityLabel and not rarityLabel.Visible then
                        rarityLabel.Visible = true
                    end
                end
            end

            -- Update layout indices when cards change
            updateLayoutIndices(list)

            -- Perform the actual occlusion culling
            performOcclusionCull()

            -- ================================================================
            -- CATCH BLACK SILHOUETTES - Apply mutation to newly visible cards
            -- ================================================================
            if currentMutation ~= "Default" and currentMutation ~= "Normal" then
                for _, card in pairs(list:GetChildren()) do
                    if card:IsA("ImageLabel") and card.Name ~= "Template" then
                        local viewport = card:FindFirstChildWhichIsA("ViewportFrame")
                        if viewport and viewport.Parent then -- Is visible (parented by occlusion)
                            -- Check if it's a black silhouette
                            if viewport.ImageColor3 == BLACK then
                                -- Force white immediately
                                viewport.ImageColor3 = WHITE
                                -- Try to apply mutation
                                task.spawn(function()
                                    applyMutationToCard(card, card.Name, currentMutation)
                                end)
                            end
                        end
                    end
                end
            end

            -- Mutations applied via SIGNAL pattern (like game's v_u_38):
            -- 1. Mutation button click -> MutationChanged:Fire() -> all connected cards update
            -- 2. ChildAdded -> connects card to signal, applies current mutation
            -- 3. MutationLabel hook -> reapply when game resets text to "Default"
            -- 4. Viewport hook -> reapply when game replaces model
            -- 5. Occlusion -> scheduleViewportUpdate runs when viewport becomes visible
        end)

        print("[IndexV2] Heartbeat started - occlusion-based culling like game!")
    end

    -- ============================================================================
    -- SETUP WATCHERS
    -- ============================================================================
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
    if not playerGui then
        return
    end

    -- Watch for Index UI
    playerGui.ChildAdded:Connect(function(child)
        if child.Name == "Index" then
            isInitialized = false
            lastIndexVisible = false
            cardCache = {}
            mutationButtons = {}
            viewportCache = {} -- Clear viewport cache on Index UI reset
            -- Clean up all card troves properly
            for card, trove in pairs(cardTroves) do
                pcall(function()
                    trove:Clean()
                end)
            end
            cardTroves = {}
            appliedMutations = {}
            selectedMutationLabel = nil
            if selectedMutationGradient then
                pcall(function()
                    selectedMutationGradient()
                end)
                selectedMutationGradient = nil
            end
            -- Clean up spawned animals on reset
            cleanupAllSpawnedAnimals()
            -- Clean up spawn panel on reset
            if spawnPanelUI and spawnPanelUI.screenGui then
                spawnPanelUI.screenGui:Destroy()
                spawnPanelUI = nil
            end
            spawnModeEnabled = false
            -- Reset search and filter but KEEP showAdminAnimals setting
            currentSearch = ""
            currentFilter = FILTER_ALL
            currentMutation = "Default"
            showAllMode = false
            task.delay(0.3, function()
                initialize()
                startHeartbeat()
            end)
            task.delay(0.6, function()
                initialize()
                startHeartbeat()
            end)
            task.delay(1.0, function()
                initialize()
                startHeartbeat()
            end)
        end
    end)

    -- Check if already exists
    if playerGui:FindFirstChild("Index") then
        initialize()
        startHeartbeat()
    end

    -- Backup watcher
    playerGui.DescendantAdded:Connect(function(desc)
        if desc.Name == "Mutations" and desc:IsA("Frame") and not isInitialized then
            task.delay(0.5, function()
                initialize()
                startHeartbeat()
            end)
        end
    end)

    print("[IndexV2] Ready!")



-- ============================================================================
-- BRAINROT INDEX ESP
-- ============================================================================
-- ============================================================================
-- BRAINROT INDEX ESP (combined)
-- ============================================================================
local CollectionService = game:GetService("CollectionService")
local Workspace = game.Workspace

-- ============================================================================
-- CONFIG SYSTEM - Save/Load UI positions
-- ============================================================================
local CONFIG_PATH = "astroconfig/indexesp.json"
local Config = {
    statusPosition = {scale = {x = 1, y = 0}, offset = {x = -15, y = 15}},
    statusExpanded = true, -- INDEX PROGRESS expanded by default
    toIndexPosition = {scale = {x = 1, y = 0}, offset = {x = -310, y = 15}}, -- TO INDEX list position
    toIndexExpanded = true -- TO INDEX expanded by default
}

local function ensureConfigFolder()
    if not isfolder("astroconfig") then
        makefolder("astroconfig")
    end
end

local function loadConfig()
    pcall(function()
        if isfile(CONFIG_PATH) then
            local data = readfile(CONFIG_PATH)
            local loaded = HttpService:JSONDecode(data)
            if loaded then
                if loaded.statusPosition then Config.statusPosition = loaded.statusPosition end
                if loaded.statusExpanded ~= nil then Config.statusExpanded = loaded.statusExpanded end
                if loaded.toIndexPosition then Config.toIndexPosition = loaded.toIndexPosition end
                if loaded.toIndexExpanded ~= nil then Config.toIndexExpanded = loaded.toIndexExpanded end
            end
        end
    end)
end

local function saveConfig()
    pcall(function()
        ensureConfigFolder()
        local data = HttpService:JSONEncode(Config)
        writefile(CONFIG_PATH, data)
    end)
end

-- Load config on startup (fast, file read only)
loadConfig()

-- Wait for game to load before requiring modules
if not game:IsLoaded() then
    game.Loaded:Wait()
end

-- Small delay to let other scripts initialize
task.wait(0.3)

-- Require the game modules (EXACTLY like the game does)
local Packages = ReplicatedStorage:WaitForChild("Packages", 10)
if not Packages then return end

local Synchronizer = require(Packages.Synchronizer)
local Observers = require(Packages.Observers) -- Same observer pattern the game uses
local Gradients = require(Packages.Gradients) -- For animated gradient text

local Datas = ReplicatedStorage:WaitForChild("Datas", 10)
if not Datas then return end

local AnimalsData = require(Datas.Animals)      -- Animal info: DisplayName, Rarity, HideFromIndex, IsEnabled
local IndexData = require(Datas.Index)          -- Mutation info: IsMutation, CustomIndex, LimitedMutation
local MutationsData = require(Datas.Mutations)  -- Mutation visual configs
local RaritiesData = require(Datas.Rarities)    -- Rarity colors/gradients

-- SharedIndex for accurate index counts
local SharedIndex = require(ReplicatedStorage.Shared.Index)

-- ============================================================================
-- HOOK INTO GAME'S ANIMAL CONTROLLER FOR INSTANT UPDATES
-- ============================================================================
local Controllers = ReplicatedStorage:WaitForChild("Controllers", 10)
if not Controllers then return end

local AnimalController = require(Controllers.AnimalController)

-- ============================================================================
-- ANIMAL INDEX CHECKER - Uses EXACT game logic from StudyThis.lua lines 5904-5918
-- ============================================================================
-- Game logic explained:
-- v63 = mutation type (e.g., "Albino", "Gold", "Default")
-- v64 = IsMutation flag from IndexData[mutation]
-- v65 = playerData.Index[animalName] (the animal's index entry)
-- v66 = indexed check result
--
-- if CustomIndex exists: check v65[CustomIndex.Name]
-- elseif IsMutation: check v65[mutationName] 
-- else (Default): check next(v65) ~= nil (any entry exists)
-- ============================================================================
local AnimalIndexChecker = {}

-- Debug flag - set to true to see detailed logging for all index checks
AnimalIndexChecker.DebugMode = false

function AnimalIndexChecker:IsAnimalIndexed(player, animalName, mutationType)
    -- Get player data via Synchronizer (same as game)
    local playerData = Synchronizer:Get(player)
    if not playerData then 
        if self.DebugMode then print("[IndexCheck] No playerData") end
        return false 
    end
    
    -- Get index data (same as game: v42:Get({"Index", animalName}))
    local indexData = playerData:Get("Index")
    if not indexData then 
        if self.DebugMode then print("[IndexCheck] No indexData") end
        return false 
    end
    
    -- Get this animal's index entry (v65 in game)
    local animalIndex = indexData[animalName]
    if not animalIndex then 
        if self.DebugMode then print("[IndexCheck]", animalName, "not in player's index at all") end
        return false 
    end
    
    -- Normalize mutation variant (nil, empty string, "Normal" -> "Default")
    local variant = self:NormalizeMutation(mutationType)
    
    -- Get mutation info from IndexData (only mutations have entries, "Default" returns nil)
    local mutationInfo = IndexData[variant]
    
    if self.DebugMode then
        print("[IndexCheck] Checking:", animalName, "Mutation:", variant)
        print("[IndexCheck] AnimalIndex contents:", HttpService:JSONEncode(animalIndex))
        if mutationInfo then
            print("[IndexCheck] MutationInfo: IsMutation=", mutationInfo.IsMutation, "CustomIndex=", mutationInfo.CustomIndex and mutationInfo.CustomIndex.Name or "nil")
        else
            print("[IndexCheck] MutationInfo: nil (Default or unknown mutation)")
        end
    end
    
    -- ========================================================================
    -- GAME LOGIC from IndexController.lua and Shared_Index.lua:
    -- 
    -- The game checks: playerIndex[animalName][mutationKey]
    -- 
    -- For CustomIndex mutations (rare): check animalIndex[CustomIndex.Name]
    -- For normal mutations (Gold, Diamond, etc): check animalIndex[mutationName]
    -- For Default (no mutation / nil mutationInfo): check animalIndex["Default"]
    -- ========================================================================
    
    if mutationInfo and mutationInfo.CustomIndex then
        -- CustomIndex mutations (special handling like Aquatic)
        local customKey = mutationInfo.CustomIndex.Name
        local value = animalIndex[customKey]
        if self.DebugMode then print("[IndexCheck] CustomIndex key:", customKey, "value:", value) end
        return value ~= nil
    elseif mutationInfo and mutationInfo.IsMutation then
        -- Normal mutation check - look for specific mutation entry
        local value = animalIndex[variant]
        if self.DebugMode then print("[IndexCheck] Mutation key:", variant, "value:", value) end
        return value ~= nil
    else
        -- Default/unknown mutation - check for "Default" key
        -- This matches game logic: v22[v13 and v13 or "Default"]
        local value = animalIndex["Default"]
        if self.DebugMode then print("[IndexCheck] Default key value:", value) end
        return value ~= nil
    end
end

-- Normalize mutation name (nil, empty, "Normal" -> "Default")
function AnimalIndexChecker:NormalizeMutation(mutation)
    if not mutation or mutation == "" or mutation == "Normal" then
        return "Default"
    end
    return mutation
end

-- Get the proper animal name (internal name, not display name)
function AnimalIndexChecker:GetInternalName(displayName)
    -- Search AnimalsData for matching DisplayName
    for internalName, animalData in pairs(AnimalsData) do
        if animalData.DisplayName == displayName then
            return internalName
        end
    end
    -- If no match found, return the display name as-is (might already be internal)
    return displayName
end

-- Check if an animal can be shown in the index (same logic as game's SharedIndex:CanShowInIndex)
-- This filters out:
-- 1. Animals with HideFromIndex = true (Lucky Blocks, etc.)
-- 2. Animals with IsEnabled() returning false (new animals not yet added to index like Los Gattitos)
-- 3. Animals not in AnimalsData at all
function AnimalIndexChecker:CanShowInIndex(animalName)
    -- Use the game's actual SharedIndex method which handles all the complex logic
    return SharedIndex:CanShowInIndex(animalName)
end

-- Check if an animal counts toward index completion (excludes admin/hidden animals)
-- Admin animals have HideFromIndex = true - they don't count for milestone
-- NOTE: Index V2 may have set HideFromIndex = false, so we also check the cached original state
function AnimalIndexChecker:CountsTowardIndex(animalName)
    local animalData = AnimalsData[animalName]
    if not animalData then return false end
    
    -- Check HideFromIndex flag - this is what excludes admin animals from counting
    if animalData.HideFromIndex then
        return false
    end
    
    -- ALSO check if Index V2 cached this as originally hidden (it may have unhidden it for display)
    if _G.IndexV2_OriginallyHiddenAnimals and _G.IndexV2_OriginallyHiddenAnimals[animalName] then
        return false
    end
    
    -- Also check IsEnabled if it exists (some animals not yet added to game)
    if animalData.IsEnabled and type(animalData.IsEnabled) == "function" then
        if not animalData:IsEnabled() then
            return false
        end
    end
    
    return true
end

-- Check if an animal is required for a specific mutation's index
-- Some mutations (Bloodrot, Candy, Lava, Galaxy, etc.) have a specific list of required animals
-- If no specific list exists, falls back to CountsTowardIndex check (excludes admin animals)
function AnimalIndexChecker:IsAnimalRequiredForMutation(animalName, mutation)
    local normalizedMutation = self:NormalizeMutation(mutation)
    local mutationInfo = IndexData[normalizedMutation]
    
    if mutationInfo and mutationInfo.Index then
        -- This mutation has a specific list of required animals
        -- Check if our animal is in that list
        return mutationInfo.Index[animalName] ~= nil
    else
        -- No specific list - use CountsTowardIndex which excludes admin/hidden animals
        -- This applies to Gold, Diamond, Rainbow, Default, etc.
        return self:CountsTowardIndex(animalName)
    end
end

-- Get remaining count for a mutation using SharedIndex (same as Index Viewer)
function AnimalIndexChecker:GetRemainingForMutation(mutation)
    local normalizedMutation = self:NormalizeMutation(mutation)
    local collected, needed, total = SharedIndex:GetIndexAnimals(LocalPlayer, normalizedMutation)
    if collected and needed then
        -- Never return negative (player may have collected bonus animals)
        return math.max(0, needed - collected)
    end
    return 0
end

-- Scanner Functions
local Scanner = {}

-- Helper: Check if animal is stealable based on game code logic
-- From PlotClient.lua:
-- From PlotClient.lua line 520:
--   elseif v107 and (not v107.Machine or not v107.Machine.Active) then
-- This means: Animal is stealable if NO Machine OR Machine.Active = false
-- Only Machine.Active = true blocks stealing!
function Scanner:GetAnimalStatus(plot, animalIndex)
    if not plot then return "stealable", nil end
    
    local status = "stealable"
    local statusInfo = nil
    
    pcall(function()
        local channel = Synchronizer:Wait(plot.Name)
        if channel then
            local animalList = channel:Get("AnimalList")
            if animalList then
                for slotKey, animalData in pairs(animalList) do
                    if type(animalData) == "table" and animalData.Index == animalIndex then
                        -- Only ACTIVE machine processing blocks stealing!
                        -- Machine.Active = false (FUSING READY/CRAFTING READY) is STILL STEALABLE!
                        if animalData.Machine and animalData.Machine.Active == true then
                            local machineType = animalData.Machine.Type
                            
                            if machineType == "Fuse" then
                                status = "fusing"  -- Actively fusing = can't steal
                            elseif machineType == "Crafting" then
                                status = "crafting"  -- Actively crafting = can't steal
                            else
                                status = "processing"  -- In any active machine = can't steal
                            end
                            statusInfo = animalData.Machine
                        end
                        -- Machine.Active = false or no Machine = STEALABLE!
                        break
                    end
                end
            end
        end
    end)
    
    return status, statusInfo
end

-- Helper to check if a plot belongs to the local player
function Scanner:IsLocalPlayerPlot(plot)
    -- The game sets PlotSign.YourBase.Enabled = true for the local player's plot
    -- See PlotClient.lua line 870: v187.PlotModel.PlotSign.YourBase.Enabled = v187:GetOwner() == l_LocalPlayer_0;
    local plotSign = plot:FindFirstChild("PlotSign")
    if plotSign then
        local yourBase = plotSign:FindFirstChild("YourBase")
        if yourBase then
            -- Check if it's a BillboardGui and is enabled
            if yourBase:IsA("BillboardGui") and yourBase.Enabled == true then
                return true
            end
        end
    end
    
    return false
end

function Scanner:FindAllAnimalOverheads()
    local overheads = {}
    local skippedOwnPlot = false
    local seenModels = {} -- Track models we've already added to prevent duplicates
    
    -- Search in Plots folder (animals on bases/podiums)
    local plots = Workspace:FindFirstChild("Plots")
    if plots then
        for _, plot in ipairs(plots:GetChildren()) do
            -- SKIP LOCAL PLAYER'S PLOT - you don't need to index your own animals!
            if Scanner:IsLocalPlayerPlot(plot) then
                skippedOwnPlot = true
                continue
            end
            
            -- Find animal MODELS directly on the plot
            -- The game clones models from ReplicatedStorage.Models.Animals and parents them to plot
            -- Model.Name = internal animal name (e.g., "1x1x1x1")
            for _, child in ipairs(plot:GetChildren()) do
                if child:IsA("Model") and child.Name ~= "AnimalPodiums" then
                    local primaryPart = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
                    if primaryPart then
                        local internalName = child.Name
                        
                        -- FILTER: Only include if it's a known animal in AnimalsData
                        if not AnimalsData[internalName] then
                            continue
                        end
                        
                        local mutation = child:GetAttribute("Mutation")
                        
                        -- Try to find the overhead attachment (quick non-recursive first)
                        local overheadAttachment = child:FindFirstChild("OVERHEAD_ATTACHMENT")
                        if not overheadAttachment then
                            -- Try one level deeper (common structure: Model > Head > OVERHEAD_ATTACHMENT)
                            local head = child:FindFirstChild("Head")
                            if head then
                                overheadAttachment = head:FindFirstChild("OVERHEAD_ATTACHMENT")
                            end
                        end
                        local overhead = nil
                        if overheadAttachment then
                            overhead = overheadAttachment:FindFirstChild("AnimalOverhead")
                        end
                        
                        -- Find matching podium by position
                        local podiums = plot:FindFirstChild("AnimalPodiums")
                        local matchingPodium = nil
                        if podiums then
                            for _, podium in ipairs(podiums:GetChildren()) do
                                local base = podium:FindFirstChild("Base")
                                if base then
                                    local spawn = base:FindFirstChild("Spawn")
                                    if spawn then
                                        local spawnPos = spawn:GetPivot().Position
                                        local modelPos = child:GetPivot().Position
                                        if (modelPos - spawnPos).Magnitude < 10 then
                                            matchingPodium = podium
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        
                        -- Mark this model as seen to prevent duplicates
                        seenModels[child] = true
                        
                        -- Check if animal is stealable (only Machine.Active = true is NOT stealable)
                        local status, statusInfo = Scanner:GetAnimalStatus(plot, internalName)
                        
                        table.insert(overheads, {
                            overhead = overhead,
                            podium = matchingPodium,
                            plot = plot,
                            spawn = primaryPart,
                            animalModel = child,
                            source = "Podium",
                            internalName = internalName,
                            mutation = mutation,
                            status = status,
                            statusInfo = statusInfo
                        })
                    end
                end
            end
        end
    end
    
    -- Search in RenderedMovingAnimals (animals walking in the world)
    local renderedAnimals = Workspace:FindFirstChild("RenderedMovingAnimals")
    if renderedAnimals then
        for _, animalModel in ipairs(renderedAnimals:GetChildren()) do
            -- Skip if we already added this model from the Plots scan
            if seenModels[animalModel] then
                continue
            end
            -- Use the Index attribute for internal name (same as AnimalController uses)
            local internalName = animalModel:GetAttribute("Index") or animalModel.Name
            local mutation = animalModel:GetAttribute("Mutation")
            
            -- FILTER: Only include if it's a known animal in AnimalsData
            if not AnimalsData[internalName] then
                continue
            end
            
            -- Find the overhead attachment (quick non-recursive search first)
            local overheadAttachment = animalModel:FindFirstChild("OVERHEAD_ATTACHMENT")
            if not overheadAttachment then
                -- Try one level deeper (common structure: Model > Head > OVERHEAD_ATTACHMENT)
                local head = animalModel:FindFirstChild("Head")
                if head then
                    overheadAttachment = head:FindFirstChild("OVERHEAD_ATTACHMENT")
                end
            end
            
            local overhead = nil
            if overheadAttachment then
                overhead = overheadAttachment:FindFirstChild("AnimalOverhead")
            end
            
            -- Get mutation from overhead UI if not set as attribute
            local displayMutation = mutation
            if not displayMutation and overhead then
                local mutationLabel = overhead:FindFirstChild("Mutation")
                if mutationLabel and mutationLabel:IsA("TextLabel") and mutationLabel.Visible then
                    local mutText = mutationLabel.Text:gsub("<.->", ""):match("^%s*(.-)%s*$") or ""
                    if mutText ~= "" then
                        displayMutation = mutText
                    end
                end
            end
            
            -- ALWAYS add world animals to the list (don't skip based on overhead)
            -- World animals are walking around, so they're always stealable (no machine check needed)
            local primaryPart = animalModel.PrimaryPart or animalModel:FindFirstChildWhichIsA("BasePart")
            if primaryPart then
                table.insert(overheads, {
                    overhead = overhead,
                    animalModel = animalModel,
                    spawn = primaryPart,
                    attachment = overheadAttachment,
                    source = "World",
                    internalName = internalName,
                    mutation = displayMutation,
                    status = "stealable" -- World animals are always stealable
                })
            end
        end
    end
    
    return overheads
end

function Scanner:PrintOverheadInfo(overheadData)
    -- Debug function - only prints when AnimalIndexChecker.DebugMode is enabled
    if not AnimalIndexChecker.DebugMode then return end
    print("[DEBUG] Animal:", overheadData.source, overheadData.internalName or "?")
end

function Scanner:GetAnimalNameFromOverhead(overhead)
    local displayName = overhead:FindFirstChild("DisplayName")
    if displayName and displayName:IsA("TextLabel") then
        -- Clean up the text (remove "Creature" or other suffixes if needed)
        local text = displayName.Text
        return text
    end
    return nil
end

function Scanner:GetMutationFromOverhead(overhead)
    local mutation = overhead:FindFirstChild("Mutation")
    if mutation and mutation:IsA("TextLabel") then
        -- IMPORTANT: Check if mutation label is visible first!
        -- If not visible, the animal has no mutation (Default)
        if not mutation.Visible then
            return "Default"
        end
        
        local mutationText = mutation.Text
        
        -- Clean up rich text tags like <stroke>Gold</stroke>
        if mutationText and mutationText ~= "" then
            mutationText = mutationText:gsub("<.->", "")
            -- Trim whitespace
            mutationText = mutationText:match("^%s*(.-)%s*$") or ""
            
            if mutationText ~= "" then
                return mutationText
            end
        end
    end
    
    return "Default"
end

function Scanner:GetAnimalInfo(overheadData)
    local info = {}
    local overhead = overheadData.overhead
    
    -- PRIORITY: Use attributes from model if available (most accurate)
    -- Both podium and world animals have attributes set on their models
    if overheadData.internalName then
        info.internalName = overheadData.internalName
        info.mutation = overheadData.mutation or "Default"
        
        -- Get display name and rarity from AnimalsData using internal name
        if AnimalsData[info.internalName] then
            info.displayName = AnimalsData[info.internalName].DisplayName
            info.rarity = AnimalsData[info.internalName].Rarity
        else
            -- Fallback: use internal name as display name
            info.displayName = info.internalName
        end
    elseif overhead then
        -- Fallback: Parse from overhead UI (less accurate, may have rich text issues)
        info.displayName = Scanner:GetAnimalNameFromOverhead(overhead)
        info.mutation = Scanner:GetMutationFromOverhead(overhead)
        
        local rarity = overhead:FindFirstChild("Rarity")
        if rarity and rarity:IsA("TextLabel") then
            info.rarity = rarity.Text
        end
    end
    
    -- Get additional info from overhead if available
    if overhead then
        local generation = overhead:FindFirstChild("Generation")
        if generation and generation:IsA("TextLabel") then
            info.generation = generation.Text
        end
        
        local price = overhead:FindFirstChild("Price")
        if price and price:IsA("TextLabel") then
            info.price = price.Text
        end
        
        local stolen = overhead:FindFirstChild("Stolen")
        if stolen and stolen:IsA("TextLabel") then
            info.isStolen = stolen.Visible and stolen.Text == "STOLEN"
        end
    end
    
    return info
end

-- ESP System
local ESP = {}
ESP.ActiveESPs = {}
ESP.Enabled = false
ESP.Stats = {
    byRarity = {},      -- Count of NOT indexed animals by rarity
    byMutation = {},    -- Count of NOT indexed animals by mutation
    total = 0,          -- Total NOT indexed count
    animals = {}        -- List of animals that need indexing (for TO INDEX HUD)
}

-- ============================================================================
-- NOTIFICATION UI - Bottom left corner showing count to index
-- ============================================================================
local NotificationUI = {}
NotificationUI.ScreenGui = nil
NotificationUI.Label = nil

function NotificationUI:Create()
    -- Only create if it doesn't exist
    if self.ScreenGui and self.ScreenGui.Parent then
        return
    end
    
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    
    -- Create ScreenGui
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "IndexNotification"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 999
    screenGui.Parent = playerGui
    self.ScreenGui = screenGui
    
    -- ========================================================================
    -- TO INDEX HUD - Collapsible scrollable list of animals needing indexing
    -- ========================================================================
    local TOINDEX_COLLAPSED_SIZE = UDim2.new(0, 280, 0, 40)
    local TOINDEX_EXPANDED_SIZE = UDim2.new(0, 280, 0, 300)
    
    local toIndexFrame = Instance.new("Frame")
    toIndexFrame.Name = "NotifFrame"
    toIndexFrame.Size = Config.toIndexExpanded and TOINDEX_EXPANDED_SIZE or TOINDEX_COLLAPSED_SIZE
    toIndexFrame.AnchorPoint = Vector2.new(1, 0)
    toIndexFrame.Position = UDim2.new(
        Config.toIndexPosition.scale.x, Config.toIndexPosition.offset.x,
        Config.toIndexPosition.scale.y, Config.toIndexPosition.offset.y
    )
    toIndexFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    toIndexFrame.BackgroundTransparency = 0
    toIndexFrame.BorderSizePixel = 0
    toIndexFrame.ClipsDescendants = true
    toIndexFrame.Parent = screenGui
    
    local toIndexCorner = Instance.new("UICorner")
    toIndexCorner.CornerRadius = UDim.new(0, 8)
    toIndexCorner.Parent = toIndexFrame
    
    local toIndexStroke = Instance.new("UIStroke")
    toIndexStroke.Name = "UIStroke"
    toIndexStroke.Color = Color3.fromRGB(180, 60, 60)
    toIndexStroke.Thickness = 2
    toIndexStroke.Transparency = 0
    toIndexStroke.Parent = toIndexFrame
    
    -- Title bar (for dragging and collapse button)
    local toIndexTitleBar = Instance.new("Frame")
    toIndexTitleBar.Name = "TitleBar"
    toIndexTitleBar.Size = UDim2.new(1, 0, 0, 36)
    toIndexTitleBar.Position = UDim2.new(0, 0, 0, 0)
    toIndexTitleBar.BackgroundTransparency = 1
    toIndexTitleBar.Parent = toIndexFrame
    
    -- Emoji label (separate so gradient doesn't affect it)
    local toIndexEmoji = Instance.new("TextLabel")
    toIndexEmoji.Name = "TitleEmoji"
    toIndexEmoji.Size = UDim2.new(0, 20, 0, 30)
    toIndexEmoji.Position = UDim2.new(0, 8, 0, 5)
    toIndexEmoji.BackgroundTransparency = 1
    toIndexEmoji.Text = "🔍"
    toIndexEmoji.TextSize = 16
    toIndexEmoji.Font = Enum.Font.GothamBold
    toIndexEmoji.TextXAlignment = Enum.TextXAlignment.Left
    toIndexEmoji.Parent = toIndexTitleBar
    
    -- Title label with Gold color
    local toIndexTitle = Instance.new("TextLabel")
    toIndexTitle.Name = "Title"
    toIndexTitle.Size = UDim2.new(1, -70, 0, 30)
    toIndexTitle.Position = UDim2.new(0, 32, 0, 5)
    toIndexTitle.BackgroundTransparency = 1
    toIndexTitle.Text = "TO INDEX"
    toIndexTitle.TextColor3 = Color3.fromRGB(255, 215, 0)
    toIndexTitle.TextSize = 16
    toIndexTitle.Font = Enum.Font.GothamBlack
    toIndexTitle.TextXAlignment = Enum.TextXAlignment.Left
    toIndexTitle.Parent = toIndexTitleBar
    
    -- Add UIStroke for readability
    local toIndexTitleStroke = Instance.new("UIStroke")
    toIndexTitleStroke.Thickness = 1.5
    toIndexTitleStroke.Color = Color3.new(0, 0, 0)
    toIndexTitleStroke.Parent = toIndexTitle
    
    -- Count label (shows total count in title bar)
    local toIndexCount = Instance.new("TextLabel")
    toIndexCount.Name = "CountLabel"
    toIndexCount.Size = UDim2.new(0, 60, 0, 30)
    toIndexCount.Position = UDim2.new(1, -100, 0, 5)
    toIndexCount.BackgroundTransparency = 1
    toIndexCount.RichText = true
    toIndexCount.Text = "0"
    toIndexCount.TextColor3 = Color3.fromRGB(255, 100, 100)
    toIndexCount.TextSize = 16
    toIndexCount.Font = Enum.Font.GothamBold
    toIndexCount.TextXAlignment = Enum.TextXAlignment.Right
    toIndexCount.Parent = toIndexTitleBar
    self.Label = toIndexCount
    
    -- Expand/Collapse button
    local toIndexExpandBtn = Instance.new("TextButton")
    toIndexExpandBtn.Name = "ExpandBtn"
    toIndexExpandBtn.Size = UDim2.new(0, 30, 0, 30)
    toIndexExpandBtn.Position = UDim2.new(1, -35, 0, 4)
    toIndexExpandBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    toIndexExpandBtn.Text = Config.toIndexExpanded and "▲" or "▼"
    toIndexExpandBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
    toIndexExpandBtn.TextSize = 14
    toIndexExpandBtn.Font = Enum.Font.GothamBold
    toIndexExpandBtn.AutoButtonColor = true
    toIndexExpandBtn.Parent = toIndexTitleBar
    
    local toIndexExpandCorner = Instance.new("UICorner")
    toIndexExpandCorner.CornerRadius = UDim.new(0, 6)
    toIndexExpandCorner.Parent = toIndexExpandBtn
    
    -- Scrolling frame for animal list
    local toIndexScrollFrame = Instance.new("ScrollingFrame")
    toIndexScrollFrame.Name = "AnimalList"
    toIndexScrollFrame.Size = UDim2.new(1, -10, 1, -42)
    toIndexScrollFrame.Position = UDim2.new(0, 5, 0, 38)
    toIndexScrollFrame.BackgroundTransparency = 1
    toIndexScrollFrame.BorderSizePixel = 0
    toIndexScrollFrame.ScrollBarThickness = 6
    toIndexScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
    toIndexScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    toIndexScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    toIndexScrollFrame.Visible = Config.toIndexExpanded
    toIndexScrollFrame.Parent = toIndexFrame
    self.AnimalListScroll = toIndexScrollFrame
    self.ToIndexFrame = toIndexFrame  -- Store reference for dynamic height
    self.ToIndexListLayout = nil  -- Will be set below
    
    local toIndexListLayout = Instance.new("UIListLayout")
    toIndexListLayout.FillDirection = Enum.FillDirection.Vertical
    toIndexListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    toIndexListLayout.Padding = UDim.new(0, 2)
    toIndexListLayout.Parent = toIndexScrollFrame
    self.ToIndexListLayout = toIndexListLayout  -- Store reference
    
    -- Store collapsed size constant for dynamic sizing
    self.TOINDEX_COLLAPSED_SIZE = TOINDEX_COLLAPSED_SIZE
    self.TOINDEX_TITLE_HEIGHT = 42  -- Title bar + padding
    self.TOINDEX_MAX_HEIGHT = 400   -- Maximum height when expanded
    self.TOINDEX_MIN_CONTENT_HEIGHT = 60  -- Minimum content area
    
    -- Expand/Collapse toggle
    toIndexExpandBtn.MouseButton1Click:Connect(function()
        Config.toIndexExpanded = not Config.toIndexExpanded
        toIndexExpandBtn.Text = Config.toIndexExpanded and "▲" or "▼"
        
        if Config.toIndexExpanded then
            -- When expanding, calculate dynamic height
            self:AdjustToIndexHeight()
        else
            toIndexFrame.Size = TOINDEX_COLLAPSED_SIZE
        end
        
        toIndexScrollFrame.Visible = Config.toIndexExpanded
        saveConfig()
    end)
    
    -- Make it draggable via title bar
    local toIndexDragging, toIndexDragInput, toIndexDragStart, toIndexStartPos
    
    toIndexTitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            -- Bring to front
            screenGui.DisplayOrder = 10000
            toIndexDragging = true
            toIndexDragStart = input.Position
            toIndexStartPos = toIndexFrame.Position
            
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    toIndexDragging = false
                    screenGui.DisplayOrder = 999 -- Reset to normal
                    Config.toIndexPosition = {
                        scale = {x = toIndexFrame.Position.X.Scale, y = toIndexFrame.Position.Y.Scale},
                        offset = {x = toIndexFrame.Position.X.Offset, y = toIndexFrame.Position.Y.Offset}
                    }
                    saveConfig()
                end
            end)
        end
    end)
    
    toIndexTitleBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            toIndexDragInput = input
        end
    end)
    
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if input == toIndexDragInput and toIndexDragging then
            local delta = input.Position - toIndexDragStart
            toIndexFrame.Position = UDim2.new(toIndexStartPos.X.Scale, toIndexStartPos.X.Offset + delta.X, toIndexStartPos.Y.Scale, toIndexStartPos.Y.Offset + delta.Y)
        end
    end)
    
    -- ========================================================================
    -- STATUS BOX - Shows progress for ALL mutations (SCROLLABLE + COLLAPSIBLE)
    -- ========================================================================
    local STATUS_COLLAPSED_SIZE = UDim2.new(0, 280, 0, 40)
    local STATUS_EXPANDED_SIZE = UDim2.new(0, 280, 0, 350)
    
    local statusFrame = Instance.new("Frame")
    statusFrame.Name = "StatusFrame"
    statusFrame.Size = Config.statusExpanded and STATUS_EXPANDED_SIZE or STATUS_COLLAPSED_SIZE
    statusFrame.AnchorPoint = Vector2.new(1, 0)
    -- Load saved position
    statusFrame.Position = UDim2.new(
        Config.statusPosition.scale.x, Config.statusPosition.offset.x,
        Config.statusPosition.scale.y, Config.statusPosition.offset.y
    )
    statusFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    statusFrame.BackgroundTransparency = 0
    statusFrame.BorderSizePixel = 0
    statusFrame.ClipsDescendants = true
    statusFrame.Parent = screenGui
    
    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(0, 8)
    statusCorner.Parent = statusFrame
    
    local statusStroke = Instance.new("UIStroke")
    statusStroke.Name = "UIStroke"
    statusStroke.Color = Color3.fromRGB(80, 80, 100)
    statusStroke.Thickness = 2
    statusStroke.Transparency = 0
    statusStroke.Parent = statusFrame
    
    -- Title bar (for dragging and buttons)
    local statusTitleBar = Instance.new("Frame")
    statusTitleBar.Name = "TitleBar"
    statusTitleBar.Size = UDim2.new(1, 0, 0, 36)
    statusTitleBar.Position = UDim2.new(0, 0, 0, 0)
    statusTitleBar.BackgroundTransparency = 1
    statusTitleBar.Parent = statusFrame
    
    -- Emoji label (separate so gradient doesn't affect it)
    local statusEmoji = Instance.new("TextLabel")
    statusEmoji.Name = "StatusEmoji"
    statusEmoji.Size = UDim2.new(0, 20, 0, 30)
    statusEmoji.Position = UDim2.new(0, 8, 0, 5)
    statusEmoji.BackgroundTransparency = 1
    statusEmoji.Text = "📊"
    statusEmoji.TextSize = 14
    statusEmoji.Font = Enum.Font.GothamBlack
    statusEmoji.TextXAlignment = Enum.TextXAlignment.Left
    statusEmoji.Parent = statusTitleBar
    
    -- Status title at top (fixed, not scrolling) with Admin gradient
    local statusTitle = Instance.new("TextLabel")
    statusTitle.Name = "StatusTitle"
    statusTitle.Size = UDim2.new(1, -90, 0, 30)
    statusTitle.Position = UDim2.new(0, 28, 0, 5)
    statusTitle.BackgroundTransparency = 1
    statusTitle.Text = "INDEX PROGRESS"
    statusTitle.TextColor3 = Color3.new(1, 1, 1)
    statusTitle.TextSize = 14
    statusTitle.Font = Enum.Font.GothamBlack
    statusTitle.TextXAlignment = Enum.TextXAlignment.Left
    statusTitle.Parent = statusTitleBar
    
    -- Add UIStroke like game does for rarity labels with gradients
    local statusTitleStroke = Instance.new("UIStroke")
    statusTitleStroke.Thickness = 1.5
    statusTitleStroke.Color = Color3.new(0, 0, 0)
    statusTitleStroke.Parent = statusTitle
    
    -- Apply Admin gradient using game's RaritiesData.Admin.GradientPreset
    pcall(function()
        local adminRarity = RaritiesData.Admin
        if adminRarity and adminRarity.GradientPreset then
            Gradients.apply(statusTitle, adminRarity.GradientPreset)
        end
    end)
    
    -- UNLOAD button (X) - rightmost
    local statusUnloadBtn = Instance.new("TextButton")
    statusUnloadBtn.Name = "UnloadBtn"
    statusUnloadBtn.Size = UDim2.new(0, 28, 0, 28)
    statusUnloadBtn.Position = UDim2.new(1, -34, 0, 4)
    statusUnloadBtn.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
    statusUnloadBtn.BorderSizePixel = 0
    statusUnloadBtn.Text = "✕"
    statusUnloadBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
    statusUnloadBtn.TextSize = 16
    statusUnloadBtn.Font = Enum.Font.GothamBold
    statusUnloadBtn.Parent = statusTitleBar
    
    local statusUnloadCorner = Instance.new("UICorner")
    statusUnloadCorner.CornerRadius = UDim.new(0, 4)
    statusUnloadCorner.Parent = statusUnloadBtn
    
    -- Expand/Collapse button - next to unload
    local statusExpandBtn = Instance.new("TextButton")
    statusExpandBtn.Name = "ExpandBtn"
    statusExpandBtn.Size = UDim2.new(0, 28, 0, 28)
    statusExpandBtn.Position = UDim2.new(1, -66, 0, 4)
    statusExpandBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    statusExpandBtn.BorderSizePixel = 0
    statusExpandBtn.Text = Config.statusExpanded and "▲" or "▼"
    statusExpandBtn.TextColor3 = Color3.fromRGB(140, 140, 160)
    statusExpandBtn.TextSize = 12
    statusExpandBtn.Font = Enum.Font.GothamBold
    statusExpandBtn.Parent = statusTitleBar
    
    local statusExpandCorner = Instance.new("UICorner")
    statusExpandCorner.CornerRadius = UDim.new(0, 4)
    statusExpandCorner.Parent = statusExpandBtn
    
    -- Scrolling frame for mutation list
    local scrollFrame = Instance.new("ScrollingFrame")
    scrollFrame.Name = "ScrollContent"
    scrollFrame.Size = UDim2.new(1, -10, 1, -42)
    scrollFrame.Position = UDim2.new(0, 5, 0, 38)
    scrollFrame.BackgroundTransparency = 1
    scrollFrame.BorderSizePixel = 0
    scrollFrame.ScrollBarThickness = 4
    scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 120)
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scrollFrame.Visible = Config.statusExpanded
    scrollFrame.Parent = statusFrame
    
    local statusLayout = Instance.new("UIListLayout")
    statusLayout.FillDirection = Enum.FillDirection.Vertical
    statusLayout.SortOrder = Enum.SortOrder.LayoutOrder
    statusLayout.Padding = UDim.new(0, 1)
    statusLayout.Parent = scrollFrame
    
    local statusPadding = Instance.new("UIPadding")
    statusPadding.PaddingLeft = UDim.new(0, 6)
    statusPadding.PaddingRight = UDim.new(0, 10)
    statusPadding.PaddingTop = UDim.new(0, 2)
    statusPadding.PaddingBottom = UDim.new(0, 4)
    statusPadding.Parent = scrollFrame
    
    -- Toggle expand/collapse for STATUS
    statusExpandBtn.MouseButton1Click:Connect(function()
        Config.statusExpanded = not Config.statusExpanded
        statusExpandBtn.Text = Config.statusExpanded and "▲" or "▼"
        statusFrame.Size = Config.statusExpanded and STATUS_EXPANDED_SIZE or STATUS_COLLAPSED_SIZE
        scrollFrame.Visible = Config.statusExpanded
        saveConfig()
    end)
    
    -- Unload button for STATUS - destroys the entire ESP system
    statusUnloadBtn.MouseButton1Click:Connect(function()
        print("[IndexESP] 🚫 Unloading...")
        ESP:Disable()
        if self.ScreenGui then
            self.ScreenGui:Destroy()
            self.ScreenGui = nil
        end
        print("[IndexESP] ✅ Unloaded!")
    end)
    
    self.StatusFrame = statusFrame
    self.ScrollContent = scrollFrame
    self.StatusTitle = statusTitle
    
    -- Make status frame draggable from title bar
    local statusDragging, statusDragInput, statusDragStart, statusStartPos
    
    statusTitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            -- Bring to front
            screenGui.DisplayOrder = 10000
            statusDragging = true
            statusDragStart = input.Position
            statusStartPos = statusFrame.Position
            
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    statusDragging = false
                    screenGui.DisplayOrder = 999 -- Reset to normal
                    -- Save position when drag ends
                    Config.statusPosition = {
                        scale = {x = statusFrame.Position.X.Scale, y = statusFrame.Position.Y.Scale},
                        offset = {x = statusFrame.Position.X.Offset, y = statusFrame.Position.Y.Offset}
                    }
                    saveConfig()
                end
            end)
        end
    end)
    
    statusTitleBar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            statusDragInput = input
        end
    end)
    
    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if input == statusDragInput and statusDragging then
            local delta = input.Position - statusDragStart
            statusFrame.Position = UDim2.new(statusStartPos.X.Scale, statusStartPos.X.Offset + delta.X, statusStartPos.Y.Scale, statusStartPos.Y.Offset + delta.Y)
        end
    end)
end

-- Get the proper color for a mutation (uses game's color system)
local function getMutationColor(mutationName)
    -- Default/Normal is gray
    if mutationName == "Default" then
        return Color3.fromRGB(200, 200, 200)
    end
    
    -- PRIORITY 1: MutationsData.MainColor (this is what the game displays)
    if MutationsData[mutationName] and MutationsData[mutationName].MainColor then
        return MutationsData[mutationName].MainColor
    end
    
    -- PRIORITY 2: IndexData.MainColor (some special entries like Halloween, Aquatic)
    if IndexData[mutationName] and IndexData[mutationName].MainColor then
        return IndexData[mutationName].MainColor
    end
    
    -- PRIORITY 3: RaritiesData (fallback)
    if RaritiesData[mutationName] and RaritiesData[mutationName].MainColor then
        return RaritiesData[mutationName].MainColor
    end
    
    -- Fallback
    return Color3.fromRGB(200, 200, 200)
end

-- Update the status box with all mutation progress
function NotificationUI:UpdateStatus()
    if not self.StatusFrame or not self.ScrollContent then return end
    
    -- Clear old entries from scroll content (frames and labels)
    for _, child in ipairs(self.ScrollContent:GetChildren()) do
        if child:IsA("TextLabel") or child:IsA("Frame") then
            child:Destroy()
        end
    end
    
    -- Check if player data is loaded first
    local playerData = nil
    pcall(function()
        playerData = Synchronizer:Get(LocalPlayer)
    end)
    
    if not playerData then
        -- Show loading state
        local loadingLabel = Instance.new("TextLabel")
        loadingLabel.Name = "LoadingLabel"
        loadingLabel.AutomaticSize = Enum.AutomaticSize.XY
        loadingLabel.Size = UDim2.new(0, 0, 0, 0)
        loadingLabel.LayoutOrder = 1
        loadingLabel.BackgroundTransparency = 1
        loadingLabel.RichText = true
        loadingLabel.Text = '<font color="#FFAA00">⏳ Loading player data...</font>'
        loadingLabel.TextSize = 16
        loadingLabel.Font = Enum.Font.GothamBold
        loadingLabel.TextXAlignment = Enum.TextXAlignment.Right
        loadingLabel.Parent = self.ScrollContent
        return
    end
    
    -- Collect ALL mutation data first, then sort
    local mutationData = {}
    local totalMutationsChecked = 0
    
    -- Add Default first
    local defCollected, defNeeded, defTotal = 0, 0, 0
    pcall(function()
        defCollected, defNeeded, defTotal = SharedIndex:GetIndexAnimals(LocalPlayer, "Default")
    end)
    if (defNeeded and defNeeded > 0) or (defCollected and defCollected > 0) then
        table.insert(mutationData, {
            name = "Default",
            collected = defCollected or 0,
            needed = defNeeded or 0,
            total = defTotal or 0,
            remaining = math.max(0, (defNeeded or 0) - (defCollected or 0))
        })
        totalMutationsChecked = totalMutationsChecked + 1
    end
    
    -- Get ALL entries from IndexData - check if it's a table with mutation-like properties
    for mutationName, mutationInfo in pairs(IndexData) do
        if type(mutationInfo) == "table" and mutationName ~= "Default" then
            -- Include ANY entry that looks like a mutation category
            -- Check for IsMutation, CustomIndex, LimitedMutation, or just has MainColor (mutation indicator)
            local isMutationType = mutationInfo.IsMutation or mutationInfo.CustomIndex or mutationInfo.LimitedMutation or mutationInfo.MainColor
            
            if isMutationType then
                local collected, needed, total = 0, 0, 0
                pcall(function()
                    collected, needed, total = SharedIndex:GetIndexAnimals(LocalPlayer, mutationName)
                end)
                
                -- Show if there's data for this mutation
                if (needed and needed > 0) or (collected and collected > 0) then
                    table.insert(mutationData, {
                        name = mutationName,
                        collected = collected or 0,
                        needed = needed or 0,
                        total = total or 0,
                        remaining = math.max(0, (needed or 0) - (collected or 0))
                    })
                    totalMutationsChecked = totalMutationsChecked + 1
                end
            end
        end
    end
    
    -- If no mutations found at all, data might still be loading
    if totalMutationsChecked == 0 then
        local loadingLabel = Instance.new("TextLabel")
        loadingLabel.Name = "LoadingLabel"
        loadingLabel.AutomaticSize = Enum.AutomaticSize.XY
        loadingLabel.Size = UDim2.new(0, 0, 0, 0)
        loadingLabel.LayoutOrder = 1
        loadingLabel.BackgroundTransparency = 1
        loadingLabel.RichText = true
        loadingLabel.Text = '<font color="#FFAA00">⏳ Loading index data...</font>'
        loadingLabel.TextSize = 16
        loadingLabel.Font = Enum.Font.GothamBold
        loadingLabel.TextXAlignment = Enum.TextXAlignment.Right
        loadingLabel.Parent = self.ScrollContent
        return
    end
    
    -- SORT: Closest to completion at top, done at bottom
    table.sort(mutationData, function(a, b)
        local aDone = a.remaining <= 0
        local bDone = b.remaining <= 0
        
        -- Done ones go to BOTTOM
        if aDone and not bDone then return false end
        if bDone and not aDone then return true end
        
        -- If both not done, sort by remaining (ascending = closest to completion first)
        if not aDone and not bDone then
            return a.remaining < b.remaining
        end
        
        -- Both done - alphabetical
        return a.name < b.name
    end)
    
    local layoutOrder = 1
    local hasAnyRemaining = false
    local totalNeededForMilestones = 0  -- Track total animals needed across all mutations
    local totalMissingAcrossAll = 0  -- Track total missing animals across all mutations for title
    
    for _, data in ipairs(mutationData) do
        local mutation = data.name
        local collected = data.collected
        local needed = data.needed
        local total = data.total or 0
        local remaining = data.remaining
        local totalMissing = math.max(0, total - collected) -- How many until 100%
        totalMissingAcrossAll = totalMissingAcrossAll + totalMissing
        
        -- Get mutation info for display
        local mutInfo = MutationsData[mutation] or IndexData[mutation]
        
        -- Create a row frame to hold mutation name + stats
        local row = Instance.new("Frame")
        row.Name = "Row_" .. mutation
        row.Size = UDim2.new(1, 0, 0, 22)
        row.LayoutOrder = layoutOrder
        row.BackgroundTransparency = 1
        row.Parent = self.ScrollContent
        
        -- Mutation name label with RichText support (like the game)
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "Name"
        nameLabel.Size = UDim2.new(0, 120, 1, 0)
        nameLabel.Position = UDim2.new(0, 0, 0, 0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextColor3 = Color3.new(1, 1, 1)
        nameLabel.TextSize = 17
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = row
        
        -- Apply text and color EXACTLY like the game does (IndexController.lua lines 280-291)
        if mutation == "Default" then
            nameLabel.Text = "Normal"
            nameLabel.RichText = false
            nameLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
        elseif mutInfo and mutInfo.UseRichText and mutInfo.DisplayWithRichText then
            -- Use RichText display (YinYang, etc.)
            nameLabel.Text = mutInfo.DisplayWithRichText
            nameLabel.RichText = true
        elseif mutInfo and mutInfo.DisplayWithRichText then
            -- Use DisplayWithRichText for colored text (has <font color> tags)
            nameLabel.Text = mutInfo.DisplayWithRichText
            nameLabel.RichText = true
        elseif mutInfo and mutInfo.DisplayText then
            nameLabel.Text = mutInfo.DisplayText
            nameLabel.RichText = false
        else
            nameLabel.Text = mutation
            nameLabel.RichText = false
        end
        
        -- Apply gradient if mutation has GradientPreset (like Rainbow, Christmas)
        if mutation == "Rainbow" then
            nameLabel.Text = "Rainbow"
            nameLabel.RichText = false
            nameLabel.TextColor3 = Color3.new(1, 1, 1) -- White for gradient
            pcall(function()
                Gradients.apply(nameLabel, "Rainbow")
            end)
        elseif mutation == "Christmas" then
            nameLabel.Text = "Christmas"
            nameLabel.RichText = false
            nameLabel.TextColor3 = Color3.new(1, 1, 1) -- White for gradient
            pcall(function()
                Gradients.apply(nameLabel, "SlowGreenRed")
            end)
        elseif mutInfo and mutInfo.GradientPreset then
            nameLabel.TextColor3 = Color3.new(1, 1, 1) -- White for gradient
            pcall(function()
                Gradients.apply(nameLabel, mutInfo.GradientPreset)
            end)
        elseif not nameLabel.RichText and mutInfo and mutInfo.MainColor then
            -- Only set color if not using RichText (RichText has colors built in)
            nameLabel.TextColor3 = mutInfo.MainColor
        end
        
        -- Stats label (progress info)
        local statsLabel = Instance.new("TextLabel")
        statsLabel.Name = "Stats"
        statsLabel.Size = UDim2.new(1, -125, 1, 0)
        statsLabel.Position = UDim2.new(0, 125, 0, 0)
        statsLabel.BackgroundTransparency = 1
        statsLabel.RichText = true
        statsLabel.TextSize = 14
        statsLabel.Font = Enum.Font.GothamBold
        statsLabel.TextXAlignment = Enum.TextXAlignment.Right
        statsLabel.Parent = row
        
        if remaining > 0 then
            -- Not at milestone yet - show how many left for milestone
            local progressColor = remaining <= 3 and "#FFCC00" or "#FF8888"
            statsLabel.Text = string.format('<font color="%s">%d left</font>', progressColor, remaining)
            hasAnyRemaining = true
            totalNeededForMilestones = totalNeededForMilestones + remaining
        else
            -- Milestone reached - show checkmark + how many left for full 100%
            if totalMissing > 0 then
                statsLabel.Text = string.format('<font color="#50C850">✓</font> <font color="#888888">(%d left)</font>', totalMissing)
            else
                statsLabel.Text = '<font color="#50C850">✓</font>'
            end
        end
        
        layoutOrder = layoutOrder + 1
    end
    
    -- Update status frame border color based on completion
    local statusStroke = self.StatusFrame:FindFirstChild("UIStroke")
    if statusStroke then
        if hasAnyRemaining then
            statusStroke.Color = Color3.fromRGB(80, 80, 100)
        else
            statusStroke.Color = Color3.fromRGB(60, 140, 60)
        end
    end
    
    -- Update the title with total animals needed for milestones
    if self.StatusTitle then
        if totalNeededForMilestones > 0 then
            self.StatusTitle.Text = "INDEX PROGRESS (" .. totalNeededForMilestones .. " left)"
        else
            self.StatusTitle.Text = "INDEX PROGRESS ✓"
        end
    end
end

-- Update the TO INDEX animal list with all animals that need indexing
function NotificationUI:AdjustToIndexHeight()
    -- Dynamically adjust TO INDEX HUD height based on content
    if not self.ToIndexFrame or not self.ToIndexListLayout then return end
    if not Config.toIndexExpanded then return end
    
    -- Get the content height from the UIListLayout
    local contentHeight = self.ToIndexListLayout.AbsoluteContentSize.Y
    
    -- Calculate total height: title bar + content + padding
    local totalHeight = self.TOINDEX_TITLE_HEIGHT + contentHeight + 10
    
    -- Use a smaller minimum when content is small (e.g., just "All indexed!" message)
    local minContentNeeded = math.max(35, contentHeight + 5)  -- At least 35px or actual content
    local minHeight = self.TOINDEX_TITLE_HEIGHT + minContentNeeded
    local maxHeight = self.TOINDEX_MAX_HEIGHT
    totalHeight = math.max(minHeight, math.min(totalHeight, maxHeight))
    
    -- Apply the dynamic size
    self.ToIndexFrame.Size = UDim2.new(0, 280, 0, totalHeight)
end

function NotificationUI:UpdateAnimalList(animalsList)
    if not self.AnimalListScroll then return end
    
    -- Clear old entries
    for _, child in ipairs(self.AnimalListScroll:GetChildren()) do
        if child:IsA("TextLabel") or child:IsA("Frame") then
            child:Destroy()
        end
    end
    
    -- If no animals, show message
    if not animalsList or #animalsList == 0 then
        local emptyLabel = Instance.new("TextLabel")
        emptyLabel.Name = "EmptyLabel"
        emptyLabel.Size = UDim2.new(1, -10, 0, 30)
        emptyLabel.BackgroundTransparency = 1
        emptyLabel.RichText = true
        emptyLabel.Text = '<font color="#50C850">✓All animals indexed!</font>'
        emptyLabel.TextSize = 14
        emptyLabel.Font = Enum.Font.GothamBold
        emptyLabel.TextXAlignment = Enum.TextXAlignment.Center
        emptyLabel.Parent = self.AnimalListScroll
        
        -- Directly set compact size for empty state (title bar + message + padding)
        if self.ToIndexFrame and Config.toIndexExpanded then
            self.ToIndexFrame.Size = UDim2.new(0, 280, 0, 80)
        end
        return
    end
    
    -- Group animals by mutation for better organization
    local byMutation = {}
    for _, animal in ipairs(animalsList) do
        local mut = animal.mutation or "Default"
        if not byMutation[mut] then
            byMutation[mut] = {}
        end
        table.insert(byMutation[mut], animal)
    end
    
    -- Sort mutations (Default first, then alphabetically)
    local sortedMutations = {}
    for mutation in pairs(byMutation) do
        table.insert(sortedMutations, mutation)
    end
    table.sort(sortedMutations, function(a, b)
        if a == "Default" then return true end
        if b == "Default" then return false end
        return a < b
    end)
    
    local layoutOrder = 1
    
    for _, mutation in ipairs(sortedMutations) do
        local animals = byMutation[mutation]
        local mutInfo = MutationsData[mutation] or IndexData[mutation]
        
        -- Get mutation color
        local mutColor = getMutationColor(mutation)
        local colorHex = string.format("#%02X%02X%02X", 
            math.floor(mutColor.R * 255), 
            math.floor(mutColor.G * 255), 
            math.floor(mutColor.B * 255))
        
        -- Create mutation header
        local header = Instance.new("TextLabel")
        header.Name = "Header_" .. mutation
        header.Size = UDim2.new(1, -10, 0, 22)
        header.LayoutOrder = layoutOrder
        header.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
        header.BackgroundTransparency = 0.5
        header.RichText = true
        header.TextSize = 13
        header.Font = Enum.Font.GothamBold
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.Parent = self.AnimalListScroll
        
        local headerCorner = Instance.new("UICorner")
        headerCorner.CornerRadius = UDim.new(0, 4)
        headerCorner.Parent = header
        
        local headerPadding = Instance.new("UIPadding")
        headerPadding.PaddingLeft = UDim.new(0, 6)
        headerPadding.Parent = header
        
        -- Format mutation name
        local displayName = mutation
        if mutation == "Default" then
            displayName = "Normal"
        elseif mutInfo and mutInfo.DisplayText then
            displayName = mutInfo.DisplayText
        end
        
        -- Apply text with color
        if mutInfo and mutInfo.DisplayWithRichText then
            header.Text = mutInfo.DisplayWithRichText .. string.format(' <font color="#888888">(%d)</font>', #animals)
        else
            header.Text = string.format('<font color="%s">%s</font> <font color="#888888">(%d)</font>', colorHex, displayName, #animals)
        end
        
        layoutOrder = layoutOrder + 1
        
        -- Sort animals alphabetically within mutation
        table.sort(animals, function(a, b)
            return (a.displayName or a.name) < (b.displayName or b.name)
        end)
        
        -- Add each animal
        for _, animal in ipairs(animals) do
            local animalRow = Instance.new("TextLabel")
            animalRow.Name = "Animal_" .. (animal.name or "Unknown")
            animalRow.Size = UDim2.new(1, -10, 0, 18)
            animalRow.LayoutOrder = layoutOrder
            animalRow.BackgroundTransparency = 1
            animalRow.RichText = true
            animalRow.TextSize = 12
            animalRow.Font = Enum.Font.Gotham
            animalRow.TextXAlignment = Enum.TextXAlignment.Left
            animalRow.Parent = self.AnimalListScroll
            
            local animalPadding = Instance.new("UIPadding")
            animalPadding.PaddingLeft = UDim.new(0, 16)
            animalPadding.Parent = animalRow
            
            -- Get rarity color for the animal
            local animalData = AnimalsData[animal.name]
            local rarityColor = Color3.fromRGB(180, 180, 180)
            if animalData and animalData.Rarity and RaritiesData[animalData.Rarity] then
                rarityColor = RaritiesData[animalData.Rarity].MainColor or rarityColor
            end
            local rarityHex = string.format("#%02X%02X%02X", 
                math.floor(rarityColor.R * 255), 
                math.floor(rarityColor.G * 255), 
                math.floor(rarityColor.B * 255))
            
            animalRow.Text = string.format('<font color="%s">• %s</font>', rarityHex, animal.displayName or animal.name)
            
            layoutOrder = layoutOrder + 1
        end
    end
    
    -- Adjust height dynamically after populating content
    task.defer(function()
        self:AdjustToIndexHeight()
    end)
end

function NotificationUI:Update(total, byMutation, animalsList)
    if not self.Label then return end
    
    local frame = self.ScreenGui and self.ScreenGui:FindFirstChild("NotifFrame")
    local stroke = frame and frame:FindFirstChild("UIStroke")
    
    -- Check if player data is loaded first
    local playerData = nil
    pcall(function()
        playerData = Synchronizer:Get(LocalPlayer)
    end)
    
    if not playerData then
        -- Show loading state
        self.Label.Text = '<font color="#FFAA00">⏳</font>'
        if stroke then
            stroke.Color = Color3.fromRGB(180, 140, 60)
        end
        -- Still update status box (it has its own loading check)
        self:UpdateStatus()
        return
    end
    
    if total == 0 then
        self.Label.Text = '<font color="#50C850">✓</font>'
        if stroke then
            stroke.Color = Color3.fromRGB(60, 140, 60)
        end
    else
        -- Just show the total count in the title bar
        self.Label.Text = string.format('<font color="#FF8888">%d</font>', total)
        
        if stroke then
            stroke.Color = Color3.fromRGB(140, 50, 50)
        end
    end
    
    -- Update the scrollable animal list
    self:UpdateAnimalList(animalsList)
    
    -- Also update the status box
    self:UpdateStatus()
end

-- Show spawn alert when a new animal that needs indexing appears
function NotificationUI:ShowSpawnAlert(animalName, mutation)
    if not self.ScreenGui then return end
    
    local frame = self.ScreenGui:FindFirstChild("NotifFrame")
    if not frame then return end
    
    -- Create or get spawn alert label
    local spawnLabel = frame:FindFirstChild("SpawnAlert")
    if not spawnLabel then
        spawnLabel = Instance.new("TextLabel")
        spawnLabel.Name = "SpawnAlert"
        spawnLabel.AutomaticSize = Enum.AutomaticSize.XY
        spawnLabel.Size = UDim2.new(0, 0, 0, 0)
        spawnLabel.LayoutOrder = 3
        spawnLabel.BackgroundTransparency = 1
        spawnLabel.RichText = true
        spawnLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
        spawnLabel.TextSize = 16
        spawnLabel.Font = Enum.Font.GothamBold
        spawnLabel.TextXAlignment = Enum.TextXAlignment.Right
        spawnLabel.Parent = frame
    end
    
    -- Get mutation color for the spawn alert
    local color = Color3.fromRGB(255, 220, 80)
    if mutation and mutation ~= "Default" then
        if IndexData[mutation] and IndexData[mutation].MainColor then
            color = IndexData[mutation].MainColor
        elseif MutationsData[mutation] and MutationsData[mutation].MainColor then
            color = MutationsData[mutation].MainColor
        end
    end
    local hex = string.format("#%02X%02X%02X", 
        math.floor(color.R * 255), 
        math.floor(color.G * 255), 
        math.floor(color.B * 255))
    
    -- Update spawn alert text with colored mutation
    local mutationText = ""
    if mutation and mutation ~= "Default" then
        mutationText = string.format(' <font color="%s">%s</font>', hex, mutation)
    end
    spawnLabel.Text = string.format('<font color="#FFE050">⚡</font> %s%s', animalName, mutationText)
    spawnLabel.Visible = true
    
    -- Flash effect on the frame
    task.spawn(function()
        local stroke = frame:FindFirstChild("UIStroke")
        if stroke then
            -- Flash with mutation color then back to normal
            for i = 1, 3 do
                stroke.Color = color
                stroke.Thickness = 2
                stroke.Transparency = 0
                task.wait(0.12)
                stroke.Color = Color3.fromRGB(140, 50, 50)
                stroke.Thickness = 1
                stroke.Transparency = 0.3
                task.wait(0.12)
            end
        end
        
        -- Hide spawn alert after 3 seconds
        task.wait(2.5)
        if spawnLabel and spawnLabel.Parent then
            spawnLabel.Visible = false
        end
    end)
end

function NotificationUI:SetVisible(visible)
    if self.ScreenGui then
        self.ScreenGui.Enabled = visible
    end
    if self.StatusFrame then
        self.StatusFrame.Visible = visible
    end
end

function NotificationUI:Destroy()
    if self.ScreenGui then
        self.ScreenGui:Destroy()
        self.ScreenGui = nil
        self.StatusFrame = nil
        self.Label = nil
        self.AnimalListScroll = nil
        self.ScrollContent = nil
    end
end

function ESP:CreateHighlight(part)
    local highlight = Instance.new("Highlight")
    highlight.FillColor = Color3.fromRGB(0, 255, 0)
    highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
    highlight.FillTransparency = 0.5
    highlight.OutlineTransparency = 0
    highlight.Parent = part
    return highlight
end

-- Update the counter text on an existing ESP billboard
function ESP:UpdateBillboardCounter(billboard, mutation)
    if not billboard then return end
    
    local frame = billboard:FindFirstChild("Frame")
    if not frame then return end
    
    local countLabel = frame:FindFirstChild("CountLabel")
    if not countLabel then return end
    
    -- Get fresh remaining count
    local remaining = AnimalIndexChecker:GetRemainingForMutation(mutation)
    local remainingNum = tonumber(remaining) or 10
    
    -- If milestone is complete (0 remaining), hide the text entirely
    if remainingNum <= 0 then
        countLabel.Text = ""
    elseif remainingNum <= 2 then
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    elseif remainingNum <= 5 then
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(255, 200, 50)
    else
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    end
end

-- Update ALL existing ESP billboards with fresh counter values
function ESP:UpdateAllBillboardCounters()
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant.Name == "IndexESP" and descendant:IsA("BillboardGui") then
            local frame = descendant:FindFirstChild("Frame")
            if frame then
                -- Use stored Mutation attribute (fast lookup)
                local mutation = frame:GetAttribute("Mutation") or "Default"
                ESP:UpdateBillboardCounter(descendant, mutation)
            end
        end
    end
end

function ESP:CreateBillboardGui(attachment, animalName, mutation, remaining)
    -- Check if ESP already exists
    local existing = attachment:FindFirstChild("IndexESP")
    if existing then
        existing:Destroy()
    end
    
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "IndexESP"
    billboard.Adornee = attachment.Parent
    billboard.Size = UDim2.new(0, 280, 0, 90) -- Larger size for better visibility
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Parent = attachment
    
    local frame = Instance.new("Frame")
    frame.Name = "Frame"
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Parent = billboard
    
    -- Store mutation for easy lookup when updating counters
    frame:SetAttribute("Mutation", mutation)
    
    -- Animal name label (simple white text with stroke)
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "AnimalName"
    nameLabel.Size = UDim2.new(1, 0, 0.38, 0)
    nameLabel.Position = UDim2.new(0, 0, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = animalName
    nameLabel.TextColor3 = Color3.new(1, 1, 1)
    nameLabel.TextScaled = true
    nameLabel.Font = Enum.Font.FredokaOne
    nameLabel.Parent = frame
    
    local nameStroke = Instance.new("UIStroke")
    nameStroke.Thickness = 2
    nameStroke.Color = Color3.new(0, 0, 0)
    nameStroke.Parent = nameLabel
    
    -- Mutation label (styled like the game with RichText)
    local mutLabel = Instance.new("TextLabel")
    mutLabel.Name = "MutationLabel"
    mutLabel.Size = UDim2.new(1, 0, 0.32, 0)
    mutLabel.Position = UDim2.new(0, 0, 0.38, 0)
    mutLabel.BackgroundTransparency = 1
    mutLabel.TextScaled = true
    mutLabel.Font = Enum.Font.GothamBold
    mutLabel.Parent = frame
    
    -- Get mutation info and apply styling like the game
    local mutInfo = MutationsData[mutation] or IndexData[mutation]
    
    if mutation == "Default" then
        mutLabel.Text = "Normal"
        mutLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
        mutLabel.RichText = false
    elseif mutation == "Rainbow" then
        -- Rainbow - animated gradient
        mutLabel.Text = "Rainbow"
        mutLabel.TextColor3 = Color3.new(1, 1, 1)
        mutLabel.RichText = false
        pcall(function()
            Gradients.apply(mutLabel, "Rainbow")
        end)
    elseif mutation == "Christmas" then
        -- Christmas uses GreenRed gradient (red/green animated)
        mutLabel.Text = "Christmas"
        mutLabel.TextColor3 = Color3.new(1, 1, 1)
        mutLabel.RichText = false
        pcall(function()
            Gradients.apply(mutLabel, "SlowGreenRed")
        end)
    elseif mutInfo and mutInfo.GradientPreset then
        -- Has gradient preset - apply animated gradient
        mutLabel.Text = mutInfo.DisplayText or mutation
        mutLabel.TextColor3 = Color3.new(1, 1, 1)
        mutLabel.RichText = false
        pcall(function()
            Gradients.apply(mutLabel, mutInfo.GradientPreset)
        end)
    elseif mutInfo and mutInfo.DisplayWithRichText then
        -- Use DisplayWithRichText for proper styling (YinYang, colored text, etc.)
        mutLabel.Text = mutInfo.DisplayWithRichText
        mutLabel.RichText = true
        mutLabel.TextColor3 = Color3.new(1, 1, 1)
    elseif mutInfo and mutInfo.MainColor then
        -- Fallback to MainColor
        mutLabel.Text = mutInfo.DisplayText or mutation
        mutLabel.TextColor3 = mutInfo.MainColor
        mutLabel.RichText = false
    else
        mutLabel.Text = mutation
        mutLabel.TextColor3 = Color3.new(1, 1, 1)
        mutLabel.RichText = false
    end
    
    local mutStroke = Instance.new("UIStroke")
    mutStroke.Thickness = 1.5
    mutStroke.Color = Color3.new(0, 0, 0)
    mutStroke.Parent = mutLabel
    
    -- Remaining count label - color based on progress (green = close, red = far)
    local countLabel = Instance.new("TextLabel")
    countLabel.Name = "CountLabel"
    countLabel.Size = UDim2.new(1, 0, 0.30, 0)
    countLabel.Position = UDim2.new(0, 0, 0.70, 0)
    countLabel.BackgroundTransparency = 1
    countLabel.TextScaled = true
    countLabel.Font = Enum.Font.GothamBold
    countLabel.Parent = frame
    
    -- Color based on how close to completion (1-2 = green, 3-5 = yellow, 6+ = red)
    local remainingNum = tonumber(remaining) or 10
    if remainingNum <= 0 then
        -- Milestone complete! Hide the text
        countLabel.Text = ""
    elseif remainingNum <= 2 then
        -- Very close! Green
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    elseif remainingNum <= 5 then
        -- Getting close - Yellow/Orange
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(255, 200, 50)
    else
        -- Far from completion - Red
        countLabel.Text = remaining .. " left"
        countLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    end
    
    local countStroke = Instance.new("UIStroke")
    countStroke.Thickness = 1.5
    countStroke.Color = Color3.new(0, 0, 0)
    countStroke.Parent = countLabel
    
    return billboard
end

function ESP:UpdateESP(overheadData)
    local info = Scanner:GetAnimalInfo(overheadData)
    
    if not info.displayName and not info.internalName then return end
    
    -- SKIP non-stealable animals (in fuse machine, crafting, etc) - they're locked!
    local status = overheadData.status
    if status and status ~= "stealable" then
        return
    end
    
    -- Get internal name - for world animals it's already available, for podium animals we convert
    local internalName = info.internalName or AnimalIndexChecker:GetInternalName(info.displayName)
    if not internalName then 
        -- Animal not found in database, skip
        return
    end
    
    -- Normalize mutation FIRST - we need it for the requirement check
    local mutation = AnimalIndexChecker:NormalizeMutation(info.mutation)
    
    -- IMPORTANT: Check if animal is required for this mutation's index
    -- This filters out:
    -- 1. New animals (IsEnabled() = false) for mutations without specific lists
    -- 2. Animals not in the mutation's required list (for Bloodrot, Candy, Lava, Galaxy, etc.)
    if not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then
        -- Animal is not required for this mutation's index - skip entirely
        return
    end
    
    -- Check if ESP already exists on this model to prevent duplicates
    local animalModel = overheadData.animalModel
    if animalModel then
        local existingESP = animalModel:FindFirstChild("IndexESP", true)
        if existingESP then
            -- ESP already exists, don't create another one
            return
        end
    end
    
    -- FIRST: Clear any existing ESPs on this animal to prevent duplicates
    ESP:ClearESP(overheadData)
    
    -- CHECK IF THIS SPECIFIC ANIMAL IS INDEXED FIRST - this is the real check!
    local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
    
    -- DEBUG: Only log Secret/Rainbow animals when debug mode is enabled
    local animalData = AnimalsData[internalName]
    if AnimalIndexChecker.DebugMode then
        local isSecretOrRainbow = (animalData and animalData.Rarity == "Secret") or mutation == "Rainbow"
        if isSecretOrRainbow then
            print("========================================")
            print("[ESP DEBUG] CHECKING:", info.displayName or internalName)
            print("  Source:", overheadData.source)
            print("  Internal Name:", internalName)
            print("  Mutation:", mutation)
            print("  Rarity:", animalData and animalData.Rarity or "Unknown")
            print("  IsIndexed Result:", isIndexed)
            
            local mutInfo = IndexData[mutation]
            if mutInfo then
                local mutType = "Unknown"
                if mutInfo.CustomIndex then
                    mutType = "CustomIndex:" .. tostring(mutInfo.CustomIndex.Name)
                elseif mutInfo.IsMutation then
                    mutType = "IsMutation=true"
                end
                print("  MutationInfo:", mutType)
            else
                print("  MutationInfo: nil (will use mutation-based check since not in IndexData)")
            end
            
            local playerData = Synchronizer:Get(LocalPlayer)
            if playerData then
                local fullIndexData = playerData:Get("Index")
                if fullIndexData then
                    local animalIndex = fullIndexData[internalName]
                    if animalIndex then
                        print("  Player Index[" .. internalName .. "]:", HttpService:JSONEncode(animalIndex))
                        local mutValue = animalIndex[mutation]
                        print("  Value at ['" .. mutation .. "']:", mutValue)
                    else
                        print("  Player Index[" .. internalName .. "]: nil (animal NOT in your index at all)")
                    end
                else
                    print("  Player has no Index data!")
                end
            else
                print("  No player data!")
            end
            print("========================================")
        end
    end
    
    -- Get remaining count for the ESP text (but don't use it to skip)
    local remaining = AnimalIndexChecker:GetRemainingForMutation(mutation)
    
    local spawn = overheadData.spawn
    if not spawn then return end
    
    -- If already indexed, clear any existing ESP and skip
    if isIndexed then
        -- Already cleared above, just return
        return
    end
    
    -- Get or create attachment for ESP - use consistent name to prevent duplicates
    -- Priority: existing IndexESPAttachment > OVERHEAD_ATTACHMENT > create new
    local animalModel = overheadData.animalModel
    local attachment = nil
    
    if animalModel then
        -- Check for our dedicated ESP attachment first (non-recursive for performance)
        attachment = animalModel:FindFirstChild("IndexESPAttachment")
        if not attachment then
            -- Try Head (common structure)
            local head = animalModel:FindFirstChild("Head")
            if head then
                attachment = head:FindFirstChild("IndexESPAttachment") or head:FindFirstChild("OVERHEAD_ATTACHMENT")
            end
        end
        if not attachment then
            -- Use OVERHEAD_ATTACHMENT if it exists
            attachment = animalModel:FindFirstChild("OVERHEAD_ATTACHMENT")
        end
        if not attachment and spawn then
            -- Create our own attachment on the spawn part
            attachment = Instance.new("Attachment")
            attachment.Name = "IndexESPAttachment"
            attachment.Parent = spawn
        end
    elseif spawn then
        attachment = spawn:FindFirstChild("IndexESPAttachment") or spawn:FindFirstChild("Attachment")
        if not attachment then
            attachment = Instance.new("Attachment")
            attachment.Name = "IndexESPAttachment"
            attachment.Parent = spawn
        end
    end
    
    if not attachment then return end
    
    -- Get mutation color from game modules
    local mutationColor = Color3.fromRGB(255, 255, 255) -- Default white
    if mutation ~= "Default" then
        -- Check IndexData module first (mutation info with colors)
        if IndexData[mutation] and IndexData[mutation].MainColor then
            mutationColor = IndexData[mutation].MainColor
        -- Then check MutationsData module
        elseif MutationsData[mutation] and MutationsData[mutation].MainColor then
            mutationColor = MutationsData[mutation].MainColor
        end
    end
    
    -- Build ESP text - clean and simple
    local espText = ""
    local highlightColor = Color3.fromRGB(255, 0, 0) -- Red for highlight
    
    -- Add animal name (use display name if available, otherwise internal name)
    local displayName = info.displayName or internalName
    
    -- Create ESP with proper mutation styling
    ESP:CreateBillboardGui(attachment, displayName, mutation, remaining)
    
    -- Add highlight to the spawn part (for world animals, highlight the whole model)
    local highlightTarget = overheadData.animalModel or spawn
    local existingHighlight = highlightTarget:FindFirstChild("IndexHighlight")
    if existingHighlight then
        existingHighlight.FillColor = Color3.fromRGB(255, 0, 0)
    else
        local highlight = ESP:CreateHighlight(highlightTarget)
        highlight.Name = "IndexHighlight"
        highlight.FillColor = Color3.fromRGB(255, 0, 0)
    end
end

function ESP:ClearESP(overheadData)
    local spawn = overheadData.spawn
    local animalModel = overheadData.animalModel
    
    -- Clear ESP from all possible attachment locations
    local attachmentsToCheck = {}
    
    if animalModel then
        local espAttachment = animalModel:FindFirstChild("IndexESPAttachment", true)
        if espAttachment then table.insert(attachmentsToCheck, espAttachment) end
        
        local overheadAttachment = animalModel:FindFirstChild("OVERHEAD_ATTACHMENT", true)
        if overheadAttachment then table.insert(attachmentsToCheck, overheadAttachment) end
    end
    
    if spawn then
        local espAttachment = spawn:FindFirstChild("IndexESPAttachment")
        if espAttachment then table.insert(attachmentsToCheck, espAttachment) end
        
        local attachment = spawn:FindFirstChild("Attachment")
        if attachment then table.insert(attachmentsToCheck, attachment) end
    end
    
    if overheadData.attachment then
        table.insert(attachmentsToCheck, overheadData.attachment)
    end
    
    -- Destroy IndexESP from all attachments
    for _, attachment in ipairs(attachmentsToCheck) do
        local esp = attachment:FindFirstChild("IndexESP")
        if esp then
            esp:Destroy()
        end
    end
    
    -- Clear highlight from spawn
    if spawn then
        local highlight = spawn:FindFirstChild("IndexHighlight")
        if highlight then
            highlight:Destroy()
        end
    end
    
    -- Clear highlight from animal model (for world animals)
    if animalModel then
        local highlight = animalModel:FindFirstChild("IndexHighlight")
        if highlight then
            highlight:Destroy()
        end
    end
end

function ESP:CalculateStats(overheads)
    -- Reset stats
    ESP.Stats = {
        byRarity = {},
        byMutation = {},
        total = 0,
        animals = {} -- List of animals that need indexing
    }
    
    for _, overheadData in ipairs(overheads) do
        local info = Scanner:GetAnimalInfo(overheadData)
        if not info.displayName and not info.internalName then continue end
        
        local internalName = info.internalName or AnimalIndexChecker:GetInternalName(info.displayName)
        if not internalName then continue end
        
        local mutation = AnimalIndexChecker:NormalizeMutation(info.mutation)
        
        -- Skip animals not required for this mutation's index
        if not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then continue end
        
        local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
        
        if not isIndexed then
            -- SKIP non-stealable animals entirely - they're not important!
            local status = overheadData.status
            if status and status ~= "stealable" then
                continue
            end
            
            ESP.Stats.total = ESP.Stats.total + 1
            
            -- Count by rarity
            local rarity = info.rarity or "Unknown"
            ESP.Stats.byRarity[rarity] = (ESP.Stats.byRarity[rarity] or 0) + 1
            
            -- Count by mutation
            ESP.Stats.byMutation[mutation] = (ESP.Stats.byMutation[mutation] or 0) + 1
            
            -- Add to animals list for the TO INDEX HUD
            table.insert(ESP.Stats.animals, {
                name = internalName,
                displayName = info.displayName or internalName,
                mutation = mutation,
                rarity = rarity,
                model = overheadData.animalModel,  -- Include model for teleporting
                source = overheadData.source  -- "World" or "Podium"
            })
        end
    end
end

function ESP:PrintStats()
    -- Silent - stats shown in UI instead
    -- Use /espstats chat command if you want to see this
end

function ESP:RefreshAll()
    local overheads = Scanner:FindAllAnimalOverheads()
    
    -- Calculate stats first
    ESP:CalculateStats(overheads)
    
    -- Update notification UI with current stats and animals list
    NotificationUI:Update(ESP.Stats.total, ESP.Stats.byMutation, ESP.Stats.animals)
    
    -- Update ALL existing billboard counters with fresh values
    ESP:UpdateAllBillboardCounters()
    
    -- Then update ESPs with frame budget (process some each frame to avoid stutters)
    local batchSize = 10
    local index = 1
    local total = #overheads
    
    while index <= total do
        local endIndex = math.min(index + batchSize - 1, total)
        for i = index, endIndex do
            local overheadData = overheads[i]
            if ESP.Enabled then
                ESP:UpdateESP(overheadData)
            else
                ESP:ClearESP(overheadData)
            end
        end
        index = endIndex + 1
        if index <= total then
            task.wait() -- Yield between batches to prevent freezing
        end
    end
end

-- Clear all ESPs for animals that are now indexed (runs after index change)
function ESP:ClearIndexedAnimalESPs()
    -- Search through workspace and destroy any IndexESP whose animal is now indexed
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant.Name == "IndexESP" and descendant:IsA("BillboardGui") then
            local frame = descendant:FindFirstChild("Frame")
            if frame then
                local nameLabel = frame:FindFirstChild("NameLabel")
                local mutLabel = frame:FindFirstChild("MutationLabel")
                if nameLabel and mutLabel then
                    -- Extract animal name and mutation from ESP
                    local displayName = nameLabel.Text:gsub("📖 ", "")
                    local mutation = mutLabel.Text:gsub("✨ ", "")
                    
                    -- Convert display name to internal name
                    local internalName = AnimalIndexChecker:GetInternalName(displayName)
                    if internalName then
                        local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
                        if isIndexed then
                            -- This animal is now indexed - remove its ESP!
                            pcall(function() descendant:Destroy() end)
                            print("[IndexESP] 🗑️ Removed ESP for indexed animal:", displayName, mutation)
                        end
                    end
                end
            end
        end
    end
end

function ESP:Toggle()
    ESP.Enabled = not ESP.Enabled
    
    -- Create notification UI if enabling, show/hide based on state
    if ESP.Enabled then
        NotificationUI:Create()
        NotificationUI:SetVisible(true)
    else
        NotificationUI:SetVisible(false)
    end
    
    ESP:RefreshAll()
end

-- Completely disable and clean up all ESP elements
function ESP:Disable()
    ESP.Enabled = false
    
    -- Clear ALL active ESPs in the world
    -- Search for and destroy all IndexESP and IndexHighlight objects
    for _, descendant in ipairs(Workspace:GetDescendants()) do
        if descendant.Name == "IndexESP" or descendant.Name == "IndexHighlight" or descendant.Name == "IndexESPAttachment" then
            pcall(function() descendant:Destroy() end)
        end
    end
    
    -- Clear any tracked ESPs
    for key, _ in pairs(ESP.ActiveESPs) do
        ESP.ActiveESPs[key] = nil
    end
    
    -- Hide/destroy notification UI
    if NotificationUI.ScreenGui then
        pcall(function() NotificationUI.ScreenGui:Destroy() end)
        NotificationUI.ScreenGui = nil
    end
    
    print("[IndexESP] All ESPs cleared and disabled")
end

-- Enable ESP after game fully loads
task.spawn(function()
    -- Wait for PlayerGui to be ready
    local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
    if not playerGui then return end
    
    -- Wait for player data to be available
    local maxWait = 30
    local waited = 0
    while waited < maxWait do
        local playerData = nil
        pcall(function()
            playerData = Synchronizer:Get(LocalPlayer)
        end)
        if playerData and playerData:Get("Index") then
            break
        end
        task.wait(0.5)
        waited = waited + 0.5
    end
    
    -- Small extra delay for game to stabilize
    task.wait(1)
    
    -- Now enable ESP
    ESP:Toggle()
end)

-- Listen for index data changes via Synchronizer (FAST refresh for immediate feedback)
local lastIndexChange = 0
pcall(function()
    local playerData = Synchronizer:Get(LocalPlayer)
    if playerData then
        -- Watch for changes to the Index data using OnChanged (correct method)
        playerData:OnChanged("Index", function()
            if ESP.Enabled then
                local now = tick()
                if now - lastIndexChange > 0.2 then -- Fast debounce: update quickly after indexing!
                    lastIndexChange = now
                    -- IMMEDIATELY clear any ESPs for newly indexed animals
                    ESP:ClearIndexedAnimalESPs()
                    task.delay(0.1, function()
                        ESP:RefreshAll()
                    end)
                end
            end
        end, false) -- false = don't fire immediately, we init separately
    end
end)

-- ============================================================================
-- LOCAL PLAYER PLOT WATCHER - Detects when YOU place/steal animals
-- ============================================================================
local function watchLocalPlayerPlot()
    local plots = Workspace:FindFirstChild("Plots")
    if not plots then return end
    
    for _, plot in ipairs(plots:GetChildren()) do
        if Scanner:IsLocalPlayerPlot(plot) then
            print("[IndexESP] 👤 Found local player plot, watching for index changes...")
            
            -- Watch Synchronizer channel for AnimalList changes on MY plot
            local channel = nil
            pcall(function()
                channel = Synchronizer:Wait(plot.Name)
            end)
            
            if channel then
                pcall(function()
                    channel:OnChanged("AnimalList", function()
                        if ESP.Enabled then
                            -- When animal placed on MY plot = indexed! Refresh immediately
                            task.delay(0.1, function()
                                print("[IndexESP] 🔄 Local plot AnimalList changed - refreshing!")
                                ESP:RefreshAll()
                            end)
                        end
                    end, false)
                end)
            end
            
            -- Also watch for descendant additions (models being added)
            plot.DescendantAdded:Connect(function(desc)
                if ESP.Enabled and desc:IsA("Model") and desc:GetAttribute("Index") then
                    task.delay(0.2, function()
                        ESP:RefreshAll()
                    end)
                end
            end)
            
            break
        end
    end
end

-- Run plot watcher
task.spawn(function()
    task.wait(2) -- Wait for plots to load
    watchLocalPlayerPlot()
end)


-- ============================================================================
-- PLAYER JOIN CRASH FIX
-- When a new player joins, their plot fires multiple events simultaneously.
-- This guard prevents concurrent RefreshAll calls from stacking up.
-- ============================================================================
local _refreshPending = false
local _refreshDebounce = 0
local _MIN_REFRESH_INTERVAL = 1.5 -- seconds between full refreshes triggered by player join

local _originalRefreshAll = ESP.RefreshAll
function ESP:RefreshAll()
    -- Prevent concurrent runs
    if _refreshPending then return end
    _refreshPending = true
    local ok, err = pcall(function()
        _originalRefreshAll(self)
    end)
    _refreshPending = false
    if not ok then
        warn("[IndexESP] RefreshAll error:", tostring(err))
    end
end

-- Safe debounced version for player-join triggered refreshes
local function safeRefreshDebounced()
    local now = tick()
    if now - _refreshDebounce < _MIN_REFRESH_INTERVAL then return end
    _refreshDebounce = now
    task.defer(function()
        if ESP.Enabled then
            ESP:RefreshAll()
        end
    end)
end

-- Override PlayerRemoving to use debounced refresh
Players.PlayerRemoving:Connect(function(player)
    task.delay(0.5, safeRefreshDebounced)
end)

-- New: PlayerAdded - debounce refresh so joining players don't spike
Players.PlayerAdded:Connect(function(player)
    task.delay(2, safeRefreshDebounced) -- Wait 2s for their plot to load
end)



-- ============================================================================
-- PLOT OBSERVER - Uses the SAME pattern as the game (Synchronizer channels)
-- The game uses Channel:OnChanged("AnimalList", ...) to detect animal changes
-- ============================================================================

-- Track watched plots to avoid duplicate watchers
local watchedPlots = {}

-- Function to watch a plot for animal changes using Synchronizer
local function watchPlot(plot)
    local plotUID = plot.Name
    
    -- Avoid duplicate watchers
    if watchedPlots[plotUID] then
        return
    end
    watchedPlots[plotUID] = true
    
    -- Wait for plot to be loaded (same as game does) with timeout
    task.spawn(function()
        local timeout = 30
        local waited = 0
        while not plot:GetAttribute("Loaded") and waited < timeout do
            task.wait(0.1)
            waited = waited + 0.1
        end
        
        if not plot:GetAttribute("Loaded") then
            watchedPlots[plotUID] = nil -- Allow retry later
            return
        end
        
        -- Get the Synchronizer channel for this plot (same as game: v5:Wait(v187.UID))
        local channel = nil
        pcall(function()
            channel = Synchronizer:Wait(plotUID)
        end)
        
        if channel then
            -- Watch for AnimalList changes (EXACTLY like game does)
            pcall(function()
                channel:OnChanged("AnimalList", function()
                    if ESP.Enabled then
                        task.delay(0.1, function()
                            ESP:RefreshAll()
                        end)
                    end
                end, true) -- true = fire immediately
            end)
        end
        
        -- Refresh immediately when plot loads
        if ESP.Enabled then
            ESP:RefreshAll()
        end
        
        -- Fallback: Watch for any descendant additions (animals, overheads, etc)
        plot.DescendantAdded:Connect(function(desc)
            if ESP.Enabled then
                -- Check if this is an animal model with Index attribute
                if desc:IsA("Model") and desc:GetAttribute("Index") then
                    task.delay(0.3, function()
                        local internalName = desc:GetAttribute("Index")
                        local mutation = AnimalIndexChecker:NormalizeMutation(desc:GetAttribute("Mutation"))
                        
                        -- Skip animals not required for this mutation's index
                        if internalName and not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then
                            return
                        end
                        
                        if internalName then
                            local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
                            
                            if not isIndexed then
                                local displayName = internalName
                                if AnimalsData[internalName] and AnimalsData[internalName].DisplayName then
                                    displayName = AnimalsData[internalName].DisplayName
                                end
                                
                                NotificationUI:ShowSpawnAlert(displayName, mutation)
                            end
                        end
                        
                        ESP:RefreshAll()
                    end)
                elseif desc.Name == "AnimalOverhead" or desc.Name == "Spawn" then
                    task.delay(0.2, function()
                        ESP:RefreshAll()
                    end)
                end
            end
        end)
        
        -- Throttled attribute change watcher
        local _lastAttrRefresh = 0
        plot.AttributeChanged:Connect(function()
            if ESP.Enabled then
                local _n = tick()
                if _n - _lastAttrRefresh > 1 then
                    _lastAttrRefresh = _n
                    task.delay(0.5, safeRefreshDebounced)
                end
            end
        end)
    end)
end

-- Use Observers to watch for Plot tags (SAME as game)
pcall(function()
    Observers.observeTag("Plot", function(plot)
        watchPlot(plot)
        
        -- Return cleanup function
        return function()
            watchedPlots[plot.Name] = nil -- Clear from tracking
            if ESP.Enabled then
                ESP:RefreshAll()
            end
        end
    end)
end)

-- ALSO watch via CollectionService directly as backup
for _, plot in ipairs(CollectionService:GetTagged("Plot")) do
    watchPlot(plot)
end

CollectionService:GetInstanceAddedSignal("Plot"):Connect(function(plot)
    watchPlot(plot)
end)

-- Watch RenderedMovingAnimals for world animals
local function watchRenderedAnimals(container)
    container.ChildAdded:Connect(function(animalModel)
        if ESP.Enabled then
            task.delay(0.2, function()
                -- Check if this animal needs to be indexed
                local internalName = animalModel:GetAttribute("Index")
                local mutation = AnimalIndexChecker:NormalizeMutation(animalModel:GetAttribute("Mutation"))
                
                -- Skip animals not required for this mutation's index
                if internalName and not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then
                    return
                end
                
                if internalName then
                    local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
                    
                    if not isIndexed then
                        -- Get display name for the alert
                        local displayName = internalName
                        if AnimalsData[internalName] and AnimalsData[internalName].DisplayName then
                            displayName = AnimalsData[internalName].DisplayName
                        end
                        
                        -- Show spawn alert!
                        NotificationUI:ShowSpawnAlert(displayName, mutation)
                    end
                end
                
                ESP:RefreshAll()
            end)
        end
    end)
    
    container.ChildRemoved:Connect(function(animalModel)
        if ESP.Enabled then
            task.delay(0.1, function()
                ESP:RefreshAll()
            end)
        end
    end)
end

local renderedAnimals = Workspace:FindFirstChild("RenderedMovingAnimals")
if renderedAnimals then
    watchRenderedAnimals(renderedAnimals)
else
    -- Watch for RenderedMovingAnimals to be created
    Workspace.ChildAdded:Connect(function(child)
        if child.Name == "RenderedMovingAnimals" then
            watchRenderedAnimals(child)
        end
    end)
end

-- CONTINUOUS refresh - throttled for performance (backup only, events are primary)
local espLastUpdate = 0
local ESP_UPDATE_INTERVAL = 5.0  -- 5 seconds since we have event hooks now
local isRefreshing = false

-- Use a slower loop instead of Heartbeat to reduce overhead
task.spawn(function()
    while true do
        task.wait(1) -- Check every second, but only refresh at interval
        if ESP.Enabled and not isRefreshing then
            local now = tick()
            if now - espLastUpdate > ESP_UPDATE_INTERVAL then
                espLastUpdate = now
                isRefreshing = true
                ESP:RefreshAll()
                isRefreshing = false
            end
        end
    end
end)

-- ============================================================================
-- HOOK INTO GAME'S AnimalController FOR INSTANT DETECTION
-- This is the SAME system the game uses - way more efficient than scanning!
-- ============================================================================

-- Track ESP instances by animal UID for quick removal
local animalESPByUID = {}

-- When a NEW animal spawns anywhere in the world
AnimalController.OnAnimalSpawn:Connect(function(animalClient)
    if not ESP.Enabled then return end
    
    local internalName = animalClient.Index
    local mutation = AnimalIndexChecker:NormalizeMutation(animalClient.Mutation)
    local uid = animalClient.UID
    
    if not internalName then return end
    
    -- Skip animals not required for this mutation's index
    if not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then return end
    
    -- Check if we need to index this
    local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
    
    if not isIndexed then
        -- Get display name for alert
        local displayName = internalName
        if AnimalsData[internalName] and AnimalsData[internalName].DisplayName then
            displayName = AnimalsData[internalName].DisplayName
        end
        
        -- Show spawn alert instantly!
        NotificationUI:ShowSpawnAlert(displayName, mutation)
        
        -- Create ESP for this animal
        local overheadData = {
            animalModel = animalClient.AnimalModel or animalClient.Instance,
            internalName = internalName,
            mutation = mutation,
            source = "World"
        }
        
        -- Find the overhead
        if animalClient.Instance then
            local attachment = animalClient.Instance:FindFirstChild("OVERHEAD_ATTACHMENT", true)
            if attachment then
                overheadData.overhead = attachment:FindFirstChild("AnimalOverhead")
            end
            overheadData.spawn = animalClient.Instance.PrimaryPart
        end
        
        ESP:UpdateESP(overheadData)
        animalESPByUID[uid] = overheadData
    end
    
    -- Update stats
    ESP:RefreshAll()
end)

-- When an animal despawns - remove its ESP instantly
AnimalController.OnAnimalDestroyed:Connect(function(uid)
    if animalESPByUID[uid] then
        ESP:ClearESP(animalESPByUID[uid])
        animalESPByUID[uid] = nil
    end
    
    -- Update stats
    if ESP.Enabled then
        task.defer(function()
            ESP:RefreshAll()
        end)
    end
end)

-- Get ALL currently loaded animals from AnimalController on startup
task.defer(function()
    local allAnimals = AnimalController:GetAnimals()
    if allAnimals then
        for uid, animalClient in pairs(allAnimals) do
            if ESP.Enabled then
                local internalName = animalClient.Index
                local mutation = AnimalIndexChecker:NormalizeMutation(animalClient.Mutation)
                
                -- Skip animals not required for this mutation's index
                if internalName and not AnimalIndexChecker:IsAnimalRequiredForMutation(internalName, mutation) then
                    continue
                end
                
                if internalName then
                    local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
                    
                    if not isIndexed then
                        local overheadData = {
                            animalModel = animalClient.AnimalModel or animalClient.Instance,
                            internalName = internalName,
                            mutation = mutation,
                            source = "World"
                        }
                        
                        if animalClient.Instance then
                            local attachment = animalClient.Instance:FindFirstChild("OVERHEAD_ATTACHMENT", true)
                            if attachment then
                                overheadData.overhead = attachment:FindFirstChild("AnimalOverhead")
                            end
                            overheadData.spawn = animalClient.Instance.PrimaryPart
                        end
                        
                        ESP:UpdateESP(overheadData)
                        animalESPByUID[uid] = overheadData
                    end
                end
            end
        end
    end
end)

-- print("[ESP] Hooked into AnimalController - INSTANT animal detection enabled!")

-- ============================================================================
-- DEBUG COMMANDS - Type in chat to control debug mode
-- ============================================================================
local function onChatMessage(msg)
    local lowerMsg = msg:lower()
    if lowerMsg == "/espdebug" then
        AnimalIndexChecker.DebugMode = not AnimalIndexChecker.DebugMode
        print("[ESP] Debug mode:", AnimalIndexChecker.DebugMode and "ON" or "OFF")
        if AnimalIndexChecker.DebugMode then
            print("[ESP] Next index check will print detailed info")
            -- Force a refresh to see debug output
            ESP:RefreshAll()
        end
    elseif lowerMsg == "/espcheck" then
        -- Manual check - print all current animals and their index status
        print("\n=== MANUAL ESP CHECK ===")
        local overheads = Scanner:FindAllAnimalOverheads()
        for i, overheadData in ipairs(overheads) do
            local info = Scanner:GetAnimalInfo(overheadData)
            local internalName = info.internalName or AnimalIndexChecker:GetInternalName(info.displayName)
            local mutation = AnimalIndexChecker:NormalizeMutation(info.mutation)
            
            if internalName then
                -- Enable debug for this check
                local oldDebug = AnimalIndexChecker.DebugMode
                AnimalIndexChecker.DebugMode = true
                local isIndexed = AnimalIndexChecker:IsAnimalIndexed(LocalPlayer, internalName, mutation)
                AnimalIndexChecker.DebugMode = oldDebug
                
                print(string.format("[%d] %s (%s) - %s - Indexed: %s", 
                    i, info.displayName or internalName, mutation, info.rarity or "?", tostring(isIndexed)))
            end
        end
        print("=== END CHECK ===\n")
    end
end

-- Hook to player chat
LocalPlayer.Chatted:Connect(onChatMessage)
-- print("[ESP] Debug commands: /espdebug (toggle debug), /espcheck (check all animals)")

-- ============================================================================
-- GLOBAL API FOR OTHER SCRIPTS (like Joiner auto-hop)
-- ============================================================================
_G.IndexESP = {
    -- Get count of animals that need indexing in current server
    GetToIndexCount = function()
        return ESP.Stats and ESP.Stats.total or 0
    end,
    -- Get list of animals that need indexing
    GetToIndexAnimals = function()
        return ESP.Stats and ESP.Stats.animals or {}
    end,
    -- Check if ESP is enabled
    IsEnabled = function()
        return ESP.Enabled
    end,
    -- Force refresh
    Refresh = function()
        if ESP.Enabled then
            ESP:RefreshAll()
        end
    end
}
print("[IndexESP] Global API exposed: _G.IndexESP.GetToIndexCount(), _G.IndexESP.GetToIndexAnimals()")

-- Return modules for external use
return {
    Scanner = Scanner,
    ESP = ESP,
    AnimalIndexChecker = AnimalIndexChecker
}



end) -- End task.spawn
