-- ============================================================
-- Lone Wolf (party-size based)
-- ============================================================

local LONE_WOLF_PASSIVE = "CT_LoneWolf"
local SOLO_STATUS       = "CT_LONEWOLF_1"
local DUO_STATUS        = "CT_LONEWOLF_2"
local PARTY_LIMIT       = 2

local LOG_PREFIX = "[LoneWolf] "
local function Log(msg) Ext.Utils.Print(LOG_PREFIX .. msg) end

-- ------------------------------------------------------------
-- Party counting (DB_Players)
-- ------------------------------------------------------------
local function GetValidParty()
    local valid = {}
    local players = Osi.DB_Players:Get(nil) or {}

    for _, entry in pairs(players) do
        local charID = entry[1]
        if Osi.IsPlayer(charID) == 1 then
            table.insert(valid, charID)
        end
    end

    return valid
end

-- ------------------------------------------------------------
-- Apply/remove Lone Wolf statuses
-- ------------------------------------------------------------
local function ClearStatuses(charID)
    Osi.RemoveStatus(charID, SOLO_STATUS)
    Osi.RemoveStatus(charID, DUO_STATUS)
end

local function ApplyForPartySize(charID, partySize)
    ClearStatuses(charID)

    if partySize == 1 then
        Osi.ApplyStatus(charID, SOLO_STATUS, -1, 100, charID)
    elseif partySize == 2 and PARTY_LIMIT >= 2 then
        Osi.ApplyStatus(charID, DUO_STATUS, -1, 100, charID)
    end
end

-- ------------------------------------------------------------
-- Main update
-- ------------------------------------------------------------
local function UpdateLoneWolf(reason)
    local valid = GetValidParty()
    local partySize = #valid

    Log(string.format("Update (%s) | valid players=%d", reason or "?", partySize))

    for _, charID in ipairs(valid) do
        local hasPassive = (Osi.HasPassive(charID, LONE_WOLF_PASSIVE) == 1)

        if hasPassive and partySize <= PARTY_LIMIT then
            ApplyForPartySize(charID, partySize)
        else
            ClearStatuses(charID)
        end
    end
end

-- ------------------------------------------------------------
-- Listeners
-- ------------------------------------------------------------
Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    UpdateLoneWolf("LevelGameplayStarted")
end)

Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function()
    UpdateLoneWolf("CharacterJoinedParty")
end)

Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", function()
    UpdateLoneWolf("CharacterLeftParty")
end)

Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(character)
    if Osi.IsPlayer(character) == 1 then
        Ext.Timer.WaitFor(500, function()
            UpdateLoneWolf("LeveledUpDelayed")
        end)
    end
end)

-- ------------------------------------------------------------
-- Passive-change detector (fixes respec selecting it)
-- ------------------------------------------------------------
local didInitialRefresh = false
local lastPassiveState = {}   -- charID -> boolean
local tickCounter = 0
local TICK_INTERVAL = 30      -- about twice/sec at 60fps

Ext.Events.Tick:Subscribe(function()
    tickCounter = tickCounter + 1

    if not didInitialRefresh then
        didInitialRefresh = true
        UpdateLoneWolf("InitialTick")
    end

    if (tickCounter % TICK_INTERVAL) ~= 0 then
        return
    end

    local valid = GetValidParty()
    local newState = {}
    local changed = false

    for _, charID in ipairs(valid) do
        local has = (Osi.HasPassive(charID, LONE_WOLF_PASSIVE) == 1)
        newState[charID] = has

        if lastPassiveState[charID] == nil then
            lastPassiveState[charID] = has
        elseif lastPassiveState[charID] ~= has then
            changed = true
        end
    end

    for charID, _ in pairs(lastPassiveState) do
        if newState[charID] == nil then
            changed = true
        end
    end

    if changed then
        lastPassiveState = newState
        UpdateLoneWolf("PassiveChanged")
    else
        lastPassiveState = newState
    end
end)

Log("LoneWolf.lua loaded (DB_Players + respec detector, no sit-out filter)")
