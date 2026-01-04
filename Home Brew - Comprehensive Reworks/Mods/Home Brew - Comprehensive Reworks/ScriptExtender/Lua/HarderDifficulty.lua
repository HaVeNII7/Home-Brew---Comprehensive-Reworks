-- HarderDifficulty.lua
-- NPC encounter scaling systems (server-side)
-- Applies statuses based on MCM settings:
--   Tab 1: NPC Hit Points (dropdown enum per encounter type)
--   Tab 2: NPC Rolls (independent toggles per encounter type)
--   Tab 3: NPC Resources (sliders 0–3 per encounter type; 0 = none)
--
-- UPDATED BEHAVIOR (2026-01-03):
--  - "Missing-only" refresh: only applies a system if the creature is missing that system's status.
--  - "Force" refresh (MCM changes / difficulty swaps): removes relevant statuses then reapplies.
--  - CombatStarted triggers a missing-only refresh (useful for combat start without thrash).
--
-- PARTY-JOIN BEHAVIOR (kept from your file):
--  - Difficulty statuses are ONLY REMOVED when a creature joins the party IF it has the NonLethal passive.
--  - When a creature joins the party IF it does NOT have NonLethal, difficulty statuses are applied.

local MOD_UUID = "486d1526-3505-4b09-9790-0f6a60f5ac0f"

-- Passives used to categorize encounters
local PASSIVE_DANGEROUS = "Dangerous_Encounter"
local PASSIVE_FATAL     = "Fatal_Encounter"

-- Main party marker passive
local PASSIVE_NONLETHAL = "NonLethal"

local STATUS_UNSUMMONABLE = "UNSUMMON_ABLE"

-- Queue for combat joiners (reinforcements / late spawns)
local pendingEnteredCombat = {}

-- =========================================================
-- MCM SETTING IDS
-- =========================================================

-- HP dropdown enums (Normal/Dangerous/Fatal)
local HP_MODE = {
    normal    = "hb_hp_mode_normal",
    dangerous = "hb_hp_mode_dangerous",
    fatal     = "hb_hp_mode_fatal",
}

-- Rolls / stats (Normal/Dangerous/Fatal)
local STATS_NORMAL = {
    AC     = "hb_stats_AC",
    Attack = "hb_stats_Attack",
    Saves  = "hb_stats_Saves",
    SaveDC = "hb_stats_SaveDC",
}

local STATS_DANGEROUS = {
    AC     = "hb_stats_dangerous_AC",
    Attack = "hb_stats_dangerous_Attack",
    Saves  = "hb_stats_dangerous_Saves",
    SaveDC = "hb_stats_dangerous_SaveDC",
}

local STATS_FATAL = {
    AC     = "hb_stats_fatal_AC",
    Attack = "hb_stats_fatal_Attack",
    Saves  = "hb_stats_fatal_Saves",
    SaveDC = "hb_stats_fatal_SaveDC",
}

-- Resources (sliders 0–3)
local RES_NORMAL = {
    actions      = "hb_res_normal_actions",
    bonusactions = "hb_res_normal_bonusactions",
    reactions    = "hb_res_normal_reactions",
}
local RES_DANGEROUS = {
    actions      = "hb_res_dangerous_actions",
    bonusactions = "hb_res_dangerous_bonusactions",
    reactions    = "hb_res_dangerous_reactions",
}
local RES_FATAL = {
    actions      = "hb_res_fatal_actions",
    bonusactions = "hb_res_fatal_bonusactions",
    reactions    = "hb_res_fatal_reactions",
}

-- =========================================================
-- STATUS NAMES
-- =========================================================

-- HP scaling statuses (15 total: 5 per encounter type)
local HP_STATUS_NORMAL = {
    easy      = "HEALTHBOOST_EASY",
    normal    = "HEALTHBOOST_NORMAL",
    hard      = "HEALTHBOOST_HARD",
    veryhard  = "HEALTHBOOST_VERYHARD",
    nightmare = "HEALTHBOOST_NIGHTMARE",
}

local HP_STATUS_DANGEROUS = {
    easy      = "HEALTHBOOST_EASY_DANGEROUS",
    normal    = "HEALTHBOOST_NORMAL_DANGEROUS",
    hard      = "HEALTHBOOST_HARD_DANGEROUS",
    veryhard  = "HEALTHBOOST_VERYHARD_DANGEROUS",
    nightmare = "HEALTHBOOST_NIGHTMARE_DANGEROUS",
}

local HP_STATUS_FATAL = {
    easy      = "HEALTHBOOST_EASY_FATAL",
    normal    = "HEALTHBOOST_NORMAL_FATAL",
    hard      = "HEALTHBOOST_HARD_FATAL",
    veryhard  = "HEALTHBOOST_VERYHARD_FATAL",
    nightmare = "HEALTHBOOST_NIGHTMARE_FATAL",
}

local ALL_HP_STATUSES = {
    -- Normal
    HP_STATUS_NORMAL.easy, HP_STATUS_NORMAL.normal, HP_STATUS_NORMAL.hard, HP_STATUS_NORMAL.veryhard, HP_STATUS_NORMAL.nightmare,
    -- Dangerous
    HP_STATUS_DANGEROUS.easy, HP_STATUS_DANGEROUS.normal, HP_STATUS_DANGEROUS.hard, HP_STATUS_DANGEROUS.veryhard, HP_STATUS_DANGEROUS.nightmare,
    -- Fatal
    HP_STATUS_FATAL.easy, HP_STATUS_FATAL.normal, HP_STATUS_FATAL.hard, HP_STATUS_FATAL.veryhard, HP_STATUS_FATAL.nightmare,
}

-- Stat scaling statuses
local STAT_STATUS = {
    AC     = "STATBOOST_AC",
    Attack = "STATBOOST_ATTACK",
    Saves  = "STATBOOST_SAVES",
    SaveDC = "STATBOOST_SAVEDC",
}

local ALL_STAT_STATUSES = {
    STAT_STATUS.AC, STAT_STATUS.Attack, STAT_STATUS.Saves, STAT_STATUS.SaveDC
}

-- Resource statuses (0..3)
local ACTION_STATUS = { [1] = "ACTION_1",      [2] = "ACTION_2",      [3] = "ACTION_3" }
local BONUS_STATUS  = { [1] = "BONUSACTION_1", [2] = "BONUSACTION_2", [3] = "BONUSACTION_3" }
local REACT_STATUS  = { [1] = "REACTIONACTION_1", [2] = "REACTIONACTION_2", [3] = "REACTIONACTION_3" }

local ALL_RESOURCE_STATUSES = {
    "ACTION_1","ACTION_2","ACTION_3",
    "BONUSACTION_1","BONUSACTION_2","BONUSACTION_3",
    "REACTIONACTION_1","REACTIONACTION_2","REACTIONACTION_3",
}

-- =========================================================
-- INTERNAL STATE
-- =========================================================

local didInitialRefresh = false
local checked = {}

-- =========================================================
-- HELPERS
-- =========================================================

local function Log(msg)
    Ext.Utils.Print(string.format("[HarderDifficulty] %s", msg))
end

local function HasStatus(guid, status)
    return Osi.HasActiveStatus(guid, status) == 1
end

local function ApplyStatusPermanent(guid, status)
    if status and status ~= "" and not HasStatus(guid, status) then
        Osi.ApplyStatus(guid, status, -1, 1, guid)
    end
end

local function RemoveStatusIfPresent(guid, status)
    if status and status ~= "" and HasStatus(guid, status) then
        Osi.RemoveStatus(guid, status)
    end
end

local function RemoveStatuses(guid, statuses)
    for _, s in ipairs(statuses) do
        RemoveStatusIfPresent(guid, s)
    end
end

local function HasPassive(guid, passive)
    return Osi.HasPassive(guid, passive) == 1
end

-- Scaling target rule:
--  - If NonLethal AND IsPlayer: NEVER apply scaling (main party)
--  - Otherwise: OK to apply scaling (enemies + temp companions like Us/Nightsong)
local function ShouldApplyDifficulty(guid)
    if HasPassive(guid, PASSIVE_NONLETHAL) and Osi.IsPlayer(guid) == 1 then
        return false
    end

    -- Never scale summons (your existing behavior)
    if HasStatus(guid, STATUS_UNSUMMONABLE) then
        return false
    end

    return true
end

local function EncounterType(guid)
    if HasPassive(guid, PASSIVE_FATAL) then
        return "fatal"
    end
    if HasPassive(guid, PASSIVE_DANGEROUS) then
        return "dangerous"
    end
    return "normal"
end

local function GetBool(settingId)
    return MCM and MCM.Get and (MCM.Get(settingId) == true)
end

local function GetInt(settingId, defaultValue)
    if not (MCM and MCM.Get) then return defaultValue end
    local v = MCM.Get(settingId)
    if type(v) == "number" then return v end
    return defaultValue
end

local function GetString(settingId, defaultValue)
    if not (MCM and MCM.Get) then return defaultValue end
    local v = MCM.Get(settingId)
    if type(v) == "string" and v ~= "" then
        return v
    end
    return defaultValue
end

-- Accepts either:
--   "easy"/"normal"/"hard"/"veryhard"/"nightmare"
-- OR display strings:
--   "Easy"/"Normal"/"Hard"/"Very Hard"/"Nightmare"
local function NormalizeHPMode(value)
    if not value then return "normal" end
    local v = tostring(value)
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if v == "easy" then return "easy" end
    if v == "normal" then return "normal" end
    if v == "hard" then return "hard" end
    if v == "very hard" then return "veryhard" end
    if v == "veryhard" then return "veryhard" end
    if v == "nightmare" then return "nightmare" end
    return "normal"
end

local function HPStatusFor(encType, mode)
    if encType == "fatal" then
        return HP_STATUS_FATAL[mode]
    elseif encType == "dangerous" then
        return HP_STATUS_DANGEROUS[mode]
    else
        return HP_STATUS_NORMAL[mode]
    end
end

-- =========================================================
-- "MISSING" DETECTION (for non-destructive refresh)
-- =========================================================

local function HasAnyHPBoost(guid)
    for _, s in ipairs(ALL_HP_STATUSES) do
        if HasStatus(guid, s) then return true end
    end
    return false
end

local function HasAnyRollBoost(guid)
    -- If any of the 4 stat statuses are present, we treat "stats system" as present
    return HasStatus(guid, STAT_STATUS.AC)
        or HasStatus(guid, STAT_STATUS.Attack)
        or HasStatus(guid, STAT_STATUS.Saves)
        or HasStatus(guid, STAT_STATUS.SaveDC)
end

local function HasAnyResBoost(guid)
    for _, s in ipairs(ALL_RESOURCE_STATUSES) do
        if HasStatus(guid, s) then return true end
    end
    return false
end

-- =========================================================
-- APPLY SYSTEMS (force vs missing-only)
-- =========================================================

-- FORCE HP: remove all HP statuses then apply exactly one matching current MCM.
local function ApplyHP_Force(guid)
    if not ShouldApplyDifficulty(guid) then
        RemoveStatuses(guid, ALL_HP_STATUSES)
        return
    end

    local encType = EncounterType(guid)
    local settingId = HP_MODE[encType] or HP_MODE.normal
    local raw = GetString(settingId, "normal")
    local mode = NormalizeHPMode(raw)

    RemoveStatuses(guid, ALL_HP_STATUSES)

    local status = HPStatusFor(encType, mode)
    if status then
        ApplyStatusPermanent(guid, status)
    end
end

-- MISSING-ONLY HP: only apply if no HP boost is present at all.
local function ApplyHP_MissingOnly(guid)
    if not ShouldApplyDifficulty(guid) then return end
    if HasAnyHPBoost(guid) then return end
    -- Safe to call force (it won't thrash because we're missing)
    ApplyHP_Force(guid)
end

-- Stats apply already toggles per setting (it removes per-stat when disabled).
-- For missing-only, we only run it if no statboost exists at all.
local function ApplyStats(guid)
    if not ShouldApplyDifficulty(guid) then
        return
    end

    local encType = EncounterType(guid)
    local settings = (encType == "fatal" and STATS_FATAL) or (encType == "dangerous" and STATS_DANGEROUS) or STATS_NORMAL

    for statKey, settingId in pairs(settings) do
        if GetBool(settingId) then
            ApplyStatusPermanent(guid, STAT_STATUS[statKey])
        else
            RemoveStatusIfPresent(guid, STAT_STATUS[statKey])
        end
    end
end

local function ApplyStats_MissingOnly(guid)
    if not ShouldApplyDifficulty(guid) then return end
    if HasAnyRollBoost(guid) then return end
    ApplyStats(guid)
end

-- Resources: always removes + reapplies based on slider.
local function ApplyResources_Force(guid)
    if not ShouldApplyDifficulty(guid) then
        return
    end

    local encType = EncounterType(guid)
    local settings = (encType == "fatal" and RES_FATAL) or (encType == "dangerous" and RES_DANGEROUS) or RES_NORMAL

    local a = math.max(0, math.min(3, GetInt(settings.actions, 0)))
    local b = math.max(0, math.min(3, GetInt(settings.bonusactions, 0)))
    local r = math.max(0, math.min(3, GetInt(settings.reactions, 0)))

    RemoveStatuses(guid, ALL_RESOURCE_STATUSES)

    if a > 0 then ApplyStatusPermanent(guid, ACTION_STATUS[a]) end
    if b > 0 then ApplyStatusPermanent(guid, BONUS_STATUS[b]) end
    if r > 0 then ApplyStatusPermanent(guid, REACT_STATUS[r]) end
end

local function ApplyResources_MissingOnly(guid)
    if not ShouldApplyDifficulty(guid) then return end
    if HasAnyResBoost(guid) then return end
    ApplyResources_Force(guid)
end

local function ApplyAllSystems(guid, force)
    if not guid or guid == "" or Osi.IsCharacter(guid) ~= 1 then
        return
    end

    if force then
        ApplyHP_Force(guid)
        ApplyStats(guid)            -- per-setting adds/removes; force is fine here
        ApplyResources_Force(guid)
    else
        ApplyHP_MissingOnly(guid)
        ApplyStats_MissingOnly(guid)
        ApplyResources_MissingOnly(guid)
    end
end

local function RefreshAllLoaded(reason, force)
    local seen = 0
    local difficultyCandidates = 0

    for _, e in pairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
        local guid = e.Uuid and e.Uuid.EntityUuid
        if guid and guid ~= "" then
            seen = seen + 1
            if ShouldApplyDifficulty(guid) then difficultyCandidates = difficultyCandidates + 1 end
            ApplyAllSystems(guid, force == true)
        end
    end

    Log(string.format("%s refresh(force=%s): seen=%d difficultyCandidates=%d", tostring(reason), tostring(force == true), seen, difficultyCandidates))
end

-- =========================================================
-- EVENT HOOKS
-- =========================================================

Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(guid)
    -- Rule 1: remove ONLY if they have NonLethal (becoming party)
    if HasPassive(guid, PASSIVE_NONLETHAL) and Osi.IsPlayer(guid) == 1 then
        RemoveStatuses(guid, ALL_HP_STATUSES)
        RemoveStatuses(guid, ALL_STAT_STATUSES)
        RemoveStatuses(guid, ALL_RESOURCE_STATUSES)
        return
    end

    -- Rule 2: otherwise apply (missing-only) when they join (temp companions)
    ApplyAllSystems(guid, false)
end)

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    checked = {}
	RefreshAllLoaded("Level start", false) -- missing-only on load: preserves existing HP/statuses
end)

Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
    if not payload or payload.modUUID ~= MOD_UUID then
        return
    end

    checked = {}
    RefreshAllLoaded("MCM changed", true) -- force when settings change (difficulty swap)
end)

-- CombatStarted: missing-only refresh to catch combat start without stripping/reapplying everyone
Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(a)
    Ext.Utils.Print("[HarderDifficulty] CombatStarted(1) fired: " .. tostring(a))
    RefreshAllLoaded("CombatStarted(1)", false)
end)

Ext.Osiris.RegisterListener("CombatStarted", 2, "after", function(a, b)
    Ext.Utils.Print("[HarderDifficulty] CombatStarted(2) fired: " .. tostring(a) .. " / " .. tostring(b))
    RefreshAllLoaded("CombatStarted(2)", false)
end)

-- EnteredCombat: apply missing-only to JUST the joining character (reinforcements / late spawns)
-- We defer a couple ticks so the entity is fully initialized (passives/statuses/template ready)
Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(guid, combatGuid)
    if guid and guid ~= "" and Osi.IsCharacter(guid) == 1 then
        pendingEnteredCombat[guid] = 2
    end
end)

-- Initial refresh once MCM is available: force so the initial world state matches MCM exactly
Ext.Events.Tick:Subscribe(function()
    -- existing initial refresh
    if not didInitialRefresh and (MCM and MCM.Get) then
		RefreshAllLoaded("Initial", false)
        didInitialRefresh = true
    end

    -- NEW: process queued combat joiners
    if next(pendingEnteredCombat) ~= nil then
        for guid, ticks in pairs(pendingEnteredCombat) do
            ticks = ticks - 1
            if ticks <= 0 then
                pendingEnteredCombat[guid] = nil
                -- missing-only apply for this one character
                ApplyAllSystems(guid, false)
            else
                pendingEnteredCombat[guid] = ticks
            end
        end
    end
end)

Log("Loaded (HP + Rolls + Resources systems active; missing-only refresh + forced refresh on MCM/level start; CombatStarted missing-only).")
