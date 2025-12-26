-- HarderDifficulty.lua
-- NPC encounter scaling systems (server-side)
-- Applies statuses based on MCM settings:
--   Tab 1: NPC Hit Points (dropdown enum per encounter type)
--   Tab 2: NPC Rolls (independent toggles per encounter type)
--   Tab 3: NPC Resources (sliders 0–3 per encounter type; 0 = none)
--
-- UPDATED PARTY-JOIN BEHAVIOR:
--  - Difficulty statuses are ONLY REMOVED when a creature joins the party IF it has the NonLethal passive.
--  - When a creature joins the party IF it does NOT have NonLethal, difficulty statuses are applied.

local MOD_UUID = "486d1526-3505-4b09-9790-0f6a60f5ac0f"

-- Passives used to categorize encounters
local PASSIVE_DANGEROUS = "Dangerous_Encounter"
local PASSIVE_FATAL     = "Fatal_Encounter"

-- Main party marker passive
local PASSIVE_NONLETHAL = "NonLethal"

local STATUS_UNSUMMONABLE = "UNSUMMON_ABLE"

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

-- Stat scaling statuses (edit if your names differ)
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
--  - If NonLethal: NEVER apply scaling (main party)
--  - Otherwise: OK to apply scaling (enemies + temp companions like Us/Nightsong)

local function ShouldApplyDifficulty(guid)
    -- Never scale party (NonLethal)
    if HasPassive(guid, PASSIVE_NONLETHAL) and Osi.IsPlayer(guid) == 1 then
        return false
    end

    -- Never scale summons
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
-- OR the display strings:
--   "Easy"/"Normal"/"Hard"/"Very Hard"/"Nightmare"
local function NormalizeHPMode(value)
    if not value then return "normal" end
    local v = tostring(value)

    -- Trim + lowercase
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if v == "easy" then return "easy" end
    if v == "normal" then return "normal" end
    if v == "hard" then return "hard" end
    if v == "very hard" then return "veryhard" end
    if v == "veryhard" then return "veryhard" end
    if v == "nightmare" then return "nightmare" end

    -- Fallback safeguard
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
-- APPLY SYSTEMS
-- =========================================================

local function ApplyHP(guid)
    if not ShouldApplyDifficulty(guid) then
        -- optional: ensure nothing lingers if something applied earlier
        RemoveStatuses(guid, ALL_HP_STATUSES)
        return
    end

    local encType = EncounterType(guid)

    -- Read dropdown enum from MCM
    local settingId = HP_MODE[encType] or HP_MODE.normal
    local raw = GetString(settingId, "normal")
    local mode = NormalizeHPMode(raw)

    -- Always keep exactly one HP status per target (based on dropdown)
    RemoveStatuses(guid, ALL_HP_STATUSES)

    local status = HPStatusFor(encType, mode)
    if status then
        ApplyStatusPermanent(guid, status)
    end
end

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

local function ApplyResources(guid)
    if not ShouldApplyDifficulty(guid) then
        return
    end

    local encType = EncounterType(guid)
    local settings = (encType == "fatal" and RES_FATAL) or (encType == "dangerous" and RES_DANGEROUS) or RES_NORMAL

    -- Sliders are 0–3 (0 = none)
    local a = math.max(0, math.min(3, GetInt(settings.actions, 0)))
    local b = math.max(0, math.min(3, GetInt(settings.bonusactions, 0)))
    local r = math.max(0, math.min(3, GetInt(settings.reactions, 0)))

    RemoveStatuses(guid, ALL_RESOURCE_STATUSES)

    if a > 0 then ApplyStatusPermanent(guid, ACTION_STATUS[a]) end
    if b > 0 then ApplyStatusPermanent(guid, BONUS_STATUS[b]) end
    if r > 0 then ApplyStatusPermanent(guid, REACT_STATUS[r]) end
end

local function ApplyAllSystems(guid)
    if not guid or guid == "" or Osi.IsCharacter(guid) ~= 1 then
        return
    end

    ApplyHP(guid)
    ApplyStats(guid)
    ApplyResources(guid)
end

local function RefreshAllLoaded(reason)
    local seen = 0
    local difficultyCandidates = 0

    for _, e in pairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
        local guid = e.Uuid and e.Uuid.EntityUuid
        if guid and guid ~= "" then
            seen = seen + 1
            if ShouldApplyDifficulty(guid) then difficultyCandidates = difficultyCandidates + 1 end
            ApplyAllSystems(guid)
        end
    end

    Log(string.format("%s refresh: seen=%d difficultyCandidates=%d", reason, seen, difficultyCandidates))
end

-- =========================================================
-- EVENT HOOKS
-- =========================================================

Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(guid)
    -- Rule 1: remove ONLY if they have NonLethal
    if HasPassive(guid, PASSIVE_NONLETHAL) and Osi.IsPlayer(guid) == 1 then
        RemoveStatuses(guid, ALL_HP_STATUSES)
        RemoveStatuses(guid, ALL_STAT_STATUSES)
        RemoveStatuses(guid, ALL_RESOURCE_STATUSES)
        return
    end

    -- Rule 2: otherwise APPLY when they join (temp companions)
    ApplyAllSystems(guid)
end)

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    checked = {}
    RefreshAllLoaded("Level start")
end)

Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
    if not payload or payload.modUUID ~= MOD_UUID then
        return
    end

    checked = {}
    RefreshAllLoaded("MCM changed")
end)

Ext.Events.Tick:Subscribe(function()
    if didInitialRefresh then return end
    if not (MCM and MCM.Get) then return end

    RefreshAllLoaded("Initial")
    didInitialRefresh = true
end)

Log("Loaded (HP + Rolls + Resources systems active; party-join NonLethal removal + non-NonLethal apply enabled).")
