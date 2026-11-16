-- Lone Wolf (party-size based)

local LONE_WOLF_PASSIVE = "CT_LoneWolf"
local SOLO_STATUS       = "CT_LONEWOLF_1"
local DUO_STATUS        = "CT_LONEWOLF_2"
local PARTY_LIMIT       = 2

local LOG_PREFIX = "[LoneWolf] "
local function Log(msg)
    if _G.HB_DebugConsole == true then Ext.Utils.Print(LOG_PREFIX .. msg) end
end

-- Party counting (DB_Players)
local function GetValidParty()
    -- SessionLoaded/Tick can fire before Osiris databases are available.
    -- Retry later rather than throwing every time story initialization lags.
    local database = Osi and Osi.DB_Players
    if not database then return nil end
    local ok, players = pcall(function() return database:Get(nil) end)
    if not ok then return nil end
    local valid = {}

    for _, entry in pairs(players or {}) do
        local charID = entry[1]
        local queried, isPlayer = pcall(Osi.IsPlayer, charID)
        if not queried then return nil end
        if isPlayer == 1 then
            table.insert(valid, charID)
        end
    end

    return valid
end

-- Apply/remove Lone Wolf statuses
-- Party events can fire repeatedly during CC, respec and multiplayer joins.
-- Only change a character's statuses when the real status state differs.
local function SetStatuses(charID, wanted)
    local solo = Osi.HasActiveStatus(charID, SOLO_STATUS) == 1
    local duo = Osi.HasActiveStatus(charID, DUO_STATUS) == 1
    if solo and wanted ~= SOLO_STATUS then Osi.RemoveStatus(charID, SOLO_STATUS) end
    if duo and wanted ~= DUO_STATUS then Osi.RemoveStatus(charID, DUO_STATUS) end
    if wanted == SOLO_STATUS and not solo then
        Osi.ApplyStatus(charID, SOLO_STATUS, -1, 100, charID)
    elseif wanted == DUO_STATUS and not duo then
        Osi.ApplyStatus(charID, DUO_STATUS, -1, 100, charID)
    end
end

-- Main update
local function UpdateLoneWolf(reason)
    local valid = GetValidParty()
    if not valid then return false end
    local partySize = #valid

    Log(string.format("Update (%s) | valid players=%d", reason or "?", partySize))

    for _, charID in ipairs(valid) do
        local hasPassive = (Osi.HasPassive(charID, LONE_WOLF_PASSIVE) == 1)

        local wanted = nil
        if hasPassive and partySize <= PARTY_LIMIT then
            if partySize == 1 then wanted = SOLO_STATUS
            elseif partySize == 2 then wanted = DUO_STATUS end
        end
        SetStatuses(charID, wanted)
    end
    return true
end

-- Listeners
Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    UpdateLoneWolf("LevelGameplayStarted")
end)

Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function()
    UpdateLoneWolf("CharacterJoinedParty")
end)

Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", function()
    UpdateLoneWolf("CharacterLeftParty")
end)

-- BG3's LeveledUp event represents XP eligibility, not necessarily the
-- completion of the native level-up UI. The existing client watcher sends
-- an authoritative server refresh request when that UI closes instead.
local function AfterTransition(reason)
    Ext.Timer.WaitFor(250,function() UpdateLoneWolf(reason) end)
    Ext.Timer.WaitFor(1450,function() UpdateLoneWolf(reason.."Settled") end)
end

-- The vanilla completion event may precede HomeBrew's level-one restoration;
-- PartialRespecFlow additionally signals Lone Wolf after its verified replay.
Ext.Osiris.RegisterListener("RespecCompleted",1,"after",function()
    AfterTransition("RespecCompleted")
end)

_G.HB_LoneWolfRefresh=function(actor,reason)
    AfterTransition(tostring(reason or "Handoff"))
end

local levelUpChannel=Ext.Net.CreateChannel(ModuleUUID,"HB_LoneWolf_LevelUp_v1")
levelUpChannel:SetHandler(function(message,peer)
    if type(message)~="table" or message.Phase~="NativeLevelUpClosed" then return end
    local actor=message.Character
    if type(actor)~="string" or #actor~=36
        or not actor:match("^[%x%-]+$") then return end
    local valid=GetValidParty()
    if not valid then return end
    local found=false
    for _,id in ipairs(valid) do
        if tostring(id):sub(-36)==actor then found=true;break end
    end
    if not found then return end
    -- This is only a read/reconcile request; still reject a foreign player's
    -- notification when BG3 exposes an explicit reserved owner.
    local ok,owner=pcall(Osi.GetReservedUserID,actor)
    if ok and tonumber(owner) and tonumber(owner)~=0 then
        local sender=tonumber(peer)
        if not sender then return end
        local user=sender-(sender%0x10000)+1
        if tonumber(owner)~=user then return end
    end
    AfterTransition("NativeLevelUpClosed")
end)

-- Retain startup retries until story databases are usable. Once successful,
-- Tick does not query any party or passives during ordinary gameplay.
local didInitialRefresh=false
Ext.Events.Tick:Subscribe(function()
    if not didInitialRefresh then
        didInitialRefresh=UpdateLoneWolf("InitialTick")
    end
end)

Log("LoneWolf.lua loaded (event-driven level-up/respec/party; startup retry)")
