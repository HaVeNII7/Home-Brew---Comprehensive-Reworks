-- HarderDifficulty.lua
-- HomeBrew difficulty scaling (server-side)
--
-- NPCs:
--   * Hit Points: Normal / Dangerous / Fatal encounter dropdowns
--   * Resources: Actions / Bonus Actions / Reactions
--   * Stats: AC / Attack / Damage / Damage Resistance / Saves / Spell Save DC
--
-- Players:
--   * Hit Points: Normal / Doubled / Tripled / Quadrupled / Quintupled
--   * Resources: Actions / Bonus Actions / Reactions
--   * Stats: AC / Attack / Damage / Damage Resistance / Saves / Spell Save DC

local MOD_UUID = "486d1526-3505-4b09-9790-0f6a60f5ac0f"

-- Encounter classification passives
local PASSIVE_DANGEROUS = "Dangerous_Encounter"
local PASSIVE_FATAL     = "Fatal_Encounter"

-- Summons carrying any of these statuses are excluded from both systems.
local SUMMON_EXCLUSION_STATUSES = {
    "SHADOWCURSE_SUMMON_CHECK",
    "UNSUMMON_ABLE",
}

-- Late combat joiners are processed after a short delay.
local pendingEnteredCombat = {}

-- MCM SETTING IDS

local DIFFICULTY_PRESET = "hb_difficulty_preset"

local NPC_HP_MODE = {
    normal    = "hb_hp_mode_normal",
    dangerous = "hb_hp_mode_dangerous",
    fatal     = "hb_hp_mode_fatal",
}

local NPC_STATS = {
    normal = {
        AC               = "hb_stats_AC",
        Attack           = "hb_stats_Attack",
        Damage           = "hb_stats_Damage",
        DamageResistance = "hb_stats_DamageResistance",
        Saves            = "hb_stats_Saves",
        SaveDC           = "hb_stats_SaveDC",
    },
    dangerous = {
        AC               = "hb_stats_dangerous_AC",
        Attack           = "hb_stats_dangerous_Attack",
        Damage           = "hb_stats_dangerous_Damage",
        DamageResistance = "hb_stats_dangerous_DamageResistance",
        Saves            = "hb_stats_dangerous_Saves",
        SaveDC           = "hb_stats_dangerous_SaveDC",
    },
    fatal = {
        AC               = "hb_stats_fatal_AC",
        Attack           = "hb_stats_fatal_Attack",
        Damage           = "hb_stats_fatal_Damage",
        DamageResistance = "hb_stats_fatal_DamageResistance",
        Saves            = "hb_stats_fatal_Saves",
        SaveDC           = "hb_stats_fatal_SaveDC",
    },
}

local NPC_PROFICIENCY = {
    normal = {
        AC               = "hb_stats_prof_AC",
        Attack           = "hb_stats_prof_Attack",
        Damage           = "hb_stats_prof_Damage",
        DamageResistance = "hb_stats_prof_DamageResistance",
        Saves            = "hb_stats_prof_Saves",
        SaveDC           = "hb_stats_prof_SaveDC",
    },
    dangerous = {
        AC               = "hb_stats_prof_dangerous_AC",
        Attack           = "hb_stats_prof_dangerous_Attack",
        Damage           = "hb_stats_prof_dangerous_Damage",
        DamageResistance = "hb_stats_prof_dangerous_DamageResistance",
        Saves            = "hb_stats_prof_dangerous_Saves",
        SaveDC           = "hb_stats_prof_dangerous_SaveDC",
    },
    fatal = {
        AC               = "hb_stats_prof_fatal_AC",
        Attack           = "hb_stats_prof_fatal_Attack",
        Damage           = "hb_stats_prof_fatal_Damage",
        DamageResistance = "hb_stats_prof_fatal_DamageResistance",
        Saves            = "hb_stats_prof_fatal_Saves",
        SaveDC           = "hb_stats_prof_fatal_SaveDC",
    },
}

local NPC_RESOURCES = {
    normal = {
        actions      = "hb_res_normal_actions",
        bonusactions = "hb_res_normal_bonusactions",
        reactions    = "hb_res_normal_reactions",
    },
    dangerous = {
        actions      = "hb_res_dangerous_actions",
        bonusactions = "hb_res_dangerous_bonusactions",
        reactions    = "hb_res_dangerous_reactions",
    },
    fatal = {
        actions      = "hb_res_fatal_actions",
        bonusactions = "hb_res_fatal_bonusactions",
        reactions    = "hb_res_fatal_reactions",
    },
}

local PLAYER_HP_MODE = "hb_player_hp_mode"

local PLAYER_STATS = {
    AC               = "hb_player_stats_AC",
    Attack           = "hb_player_stats_Attack",
    Damage           = "hb_player_stats_Damage",
    DamageResistance = "hb_player_stats_DamageResistance",
    Saves            = "hb_player_stats_Saves",
    SaveDC           = "hb_player_stats_SaveDC",
}

local PLAYER_PROFICIENCY = {
    AC               = "hb_player_stats_prof_AC",
    Attack           = "hb_player_stats_prof_Attack",
    Damage           = "hb_player_stats_prof_Damage",
    DamageResistance = "hb_player_stats_prof_DamageResistance",
    Saves            = "hb_player_stats_prof_Saves",
    SaveDC           = "hb_player_stats_prof_SaveDC",
}

local PLAYER_RESOURCES = {
    actions      = "hb_player_res_actions",
    bonusactions = "hb_player_res_bonusactions",
    reactions    = "hb_player_res_reactions",
}

-- STATUS NAMES

local NPC_HP_STATUS = {
    normal = {
        veryeasy  = "HEALTHBOOST_VERYEASY",
        easy      = "HEALTHBOOST_EASY",
        normal    = "HEALTHBOOST_NORMAL",
        hard      = "HEALTHBOOST_HARD",
        veryhard  = "HEALTHBOOST_VERYHARD",
        nightmare = "HEALTHBOOST_NIGHTMARE",
        infernal  = "HEALTHBOOST_INFERNAL",
        legendary = "HEALTHBOOST_LEGENDARY",
        ascendant = "HEALTHBOOST_ASCENDANT",
        impossible = "HEALTHBOOST_IMPOSSIBLE",
    },
    dangerous = {
        veryeasy  = "HEALTHBOOST_VERYEASY_DANGEROUS",
        easy      = "HEALTHBOOST_EASY_DANGEROUS",
        normal    = "HEALTHBOOST_NORMAL_DANGEROUS",
        hard      = "HEALTHBOOST_HARD_DANGEROUS",
        veryhard  = "HEALTHBOOST_VERYHARD_DANGEROUS",
        nightmare = "HEALTHBOOST_NIGHTMARE_DANGEROUS",
        infernal  = "HEALTHBOOST_INFERNAL_DANGEROUS",
        legendary = "HEALTHBOOST_LEGENDARY_DANGEROUS",
        ascendant = "HEALTHBOOST_ASCENDANT_DANGEROUS",
        impossible = "HEALTHBOOST_IMPOSSIBLE_DANGEROUS",
    },
    fatal = {
        veryeasy  = "HEALTHBOOST_VERYEASY_FATAL",
        easy      = "HEALTHBOOST_EASY_FATAL",
        normal    = "HEALTHBOOST_NORMAL_FATAL",
        hard      = "HEALTHBOOST_HARD_FATAL",
        veryhard  = "HEALTHBOOST_VERYHARD_FATAL",
        nightmare = "HEALTHBOOST_NIGHTMARE_FATAL",
        infernal  = "HEALTHBOOST_INFERNAL_FATAL",
        legendary = "HEALTHBOOST_LEGENDARY_FATAL",
        ascendant = "HEALTHBOOST_ASCENDANT_FATAL",
        impossible = "HEALTHBOOST_IMPOSSIBLE_FATAL",
    },
}

-- IMPORTANT:
-- Normal intentionally applies no status.
local PLAYER_HP_STATUS = {
    doubled    = "PLAYER_HEALTHBOOST_DOUBLED",
    tripled    = "PLAYER_HEALTHBOOST_TRIPLED",
    quadrupled = "PLAYER_HEALTHBOOST_QUADRUPLED",
    quintupled = "PLAYER_HEALTHBOOST_QUINTUPLED",
}

local STAT_STATUS = {
    AC = {},
    Attack = {},
    Damage = {},
    DamageResistance = {},
    Saves = {},
    SaveDC = {},
}

for i = 1, 10 do
    STAT_STATUS.AC[i]               = "STATBOOST_AC_" .. i
    STAT_STATUS.Attack[i]           = "STATBOOST_ATTACK_" .. i
    STAT_STATUS.Damage[i]           = "STATBOOST_DAMAGE_" .. i
    STAT_STATUS.DamageResistance[i] = "STATBOOST_DAMAGERESISTANCE_" .. i
    STAT_STATUS.Saves[i]            = "STATBOOST_SAVINGTHROWS_" .. i
    STAT_STATUS.SaveDC[i]           = "STATBOOST_SPELLSAVEDC_" .. i
end

local PROFICIENCY_STAT_STATUS = {
    AC               = "STATBOOST_PROFICIENCY_AC",
    Attack           = "STATBOOST_PROFICIENCY_ATTACK",
    Damage           = "STATBOOST_PROFICIENCY_DAMAGE",
    DamageResistance = "STATBOOST_PROFICIENCY_DAMAGERESISTANCE",
    Saves            = "STATBOOST_PROFICIENCY_SAVINGTHROWS",
    SaveDC           = "STATBOOST_PROFICIENCY_SPELLSAVEDC",
}

local ACTION_STATUS = {
    [1] = "ACTION_1",
    [2] = "ACTION_2",
    [3] = "ACTION_3",
}

local BONUS_STATUS = {
    [1] = "BONUSACTION_1",
    [2] = "BONUSACTION_2",
    [3] = "BONUSACTION_3",
}

local REACTION_STATUS = {
    [1] = "REACTIONACTION_1",
    [2] = "REACTIONACTION_2",
    [3] = "REACTIONACTION_3",
}

-- FLAT STATUS LISTS

local ALL_NPC_HP_STATUSES = {}
for _, encounterStatuses in pairs(NPC_HP_STATUS) do
    for _, status in pairs(encounterStatuses) do
        table.insert(ALL_NPC_HP_STATUSES, status)
    end
end

local ALL_PLAYER_HP_STATUSES = {}
for _, status in pairs(PLAYER_HP_STATUS) do
    table.insert(ALL_PLAYER_HP_STATUSES, status)
end

local ALL_STAT_STATUSES = {}
for _, statuses in pairs(STAT_STATUS) do
    for i = 1, 10 do
        table.insert(ALL_STAT_STATUSES, statuses[i])
    end
end

for _, status in pairs(PROFICIENCY_STAT_STATUS) do
    table.insert(ALL_STAT_STATUSES, status)
end

local ALL_RESOURCE_STATUSES = {
    "ACTION_1", "ACTION_2", "ACTION_3",
    "BONUSACTION_1", "BONUSACTION_2", "BONUSACTION_3",
    "REACTIONACTION_1", "REACTIONACTION_2", "REACTIONACTION_3",
}

-- INTERNAL STATE

local didInitialRefresh = false
local warnedMissingStats = {}
local isApplyingPreset = false

-- HomeBrew difficulty state is saved with the campaign, not with MCM's global profile.
-- MCM is still the editor and stat application backend. This state is restored
-- *before* the first difficulty status refresh for each loaded session.
local HB_diagnosticHistory = {}
local function Log(message)
    local value=tostring(message)
    Ext.Utils.Print(string.format("[HarderDifficulty] %s", value))
    if value:find("save-scoped",1,true) or value:find("Save-specific",1,true)
        or value:find("BG3 difficulty",1,true) or value:find("Deific",1,true)
        or value:find("Legacy save",1,true) or value:find("per-save",1,true)
        or value:find("Custom-only",1,true) or value:find("Difficulty mod-variable",1,true)
        or value:find("Setting locked",1,true) or value:find("Difficulty asset",1,true)
        or value:find("Native asset",1,true) or value:find("Net asset",1,true)
        or value:find("In-game preset",1,true) or value:find("Pending new-game",1,true)
        or value:find("Single Save",1,true) then
        HB_diagnosticHistory[#HB_diagnosticHistory+1]=value
        if #HB_diagnosticHistory>80 then table.remove(HB_diagnosticHistory,1) end
        if Ext.IO and Ext.IO.SaveFile then
            pcall(Ext.IO.SaveFile,"HomeBrew/Diagnostics/HB_DifficultyIntegration_Diagnostics.txt",
                table.concat(HB_diagnosticHistory,"\n").."\n")
        end
    end
end
local HB_SAVE_KEY = "HB_DifficultySave_V1"
local HB_DIFFICULTY_ASSETS = {
    difficulty_01 = "Default", difficulty_02 = "Hard",
    difficulty_04 = "Custom",
    difficulty_03 = "Very Hard", difficulty_05 = "Ultra Hard",
    difficulty_06 = "HellBrew", difficulty_07 = "HellBrew",
}
local HB_settingIDs, HB_cachedSnapshot = {}, nil
local HB_sessionRestored, HB_restorePending = false, true
local HB_lastGameAsset, HB_saveSyncing = nil, false
local HB_pendingNewGameAsset = nil
local HB_pendingNewGamePreset = nil
-- The front-end preview is a provisional local hint, never a committed save
-- setting. Only a real native character-creation lifecycle event can arm it.
local HB_MAIN_MENU_PREVIEW_FILE = "HomeBrew/Diagnostics/HB_MainMenuDifficultyPreview.txt"
local HB_creationStarted = false
local HB_creationFinishedPending = false
local HB_creationAppliedAsset = nil
local HB_creationFileError = nil
-- A verified explicit main-menu Adjust Difficulty selection may override the
-- default asset mapping; unrecognized text must never become an MCM setting.
local HB_MAIN_MENU_ALLOWED_PRESETS={
    ["Default"]=true,["Hard"]=true,["Very Hard"]=true,["Ultra Hard"]=true,
    ["HellBrew"]=true,["Expanded Party Size (Default)"]=true,
    ["Expanded Party Size (Hard)"]=true,["Expanded Party Size (Raid)"]=true,
    ["Maximum Difficulty"]=true,["Endurance"]=true,["Custom"]=true,
}
local function HB_ReadMainMenuPreview()
    if not (Ext.IO and Ext.IO.LoadFile) then return nil end
    local ok,raw=pcall(Ext.IO.LoadFile,HB_MAIN_MENU_PREVIEW_FILE)
    if not ok or type(raw)~="string" then return nil end
    -- Accept the original asset-only preview for backwards compatibility.
    local asset,chosen=raw:match("^(difficulty_%d%d)|(.+)$")
    if asset then
        if HB_DIFFICULTY_ASSETS[asset] and HB_MAIN_MENU_ALLOWED_PRESETS[chosen] then
            return asset,chosen
        end
        return nil
    end
    return HB_DIFFICULTY_ASSETS[raw] and raw or nil
end
-- A game-committed mapping may emit an MCM_Setting_Saved event. Its preset
-- effects are applied on the next Tick, so don't process the same selection
-- a second time or treat the echo as a manual Single Save edit.
local HB_mappedPresetEcho = nil
local function HB_AddId(id) if type(id)=="string" then HB_settingIDs[#HB_settingIDs+1]=id end end
HB_AddId(DIFFICULTY_PRESET)
for _, table1 in ipairs({NPC_HP_MODE,NPC_STATS,NPC_PROFICIENCY,NPC_RESOURCES,
                         PLAYER_STATS,PLAYER_PROFICIENCY,PLAYER_RESOURCES}) do
    for _, child in pairs(table1) do
        if type(child)=="string" then HB_AddId(child)
        elseif type(child)=="table" then for _, id in pairs(child) do HB_AddId(id) end end
    end
end
HB_AddId(PLAYER_HP_MODE)
local function HB_SaveVariables()
    if not Ext.Vars or not Ext.Vars.GetModVariables then return nil end
    local ok, vars = pcall(Ext.Vars.GetModVariables, MOD_UUID)
    return ok and vars or nil
end
local function HB_Snapshot()
    if not (MCM and MCM.Get) then return nil end
    local vals = {}
    for _, id in ipairs(HB_settingIDs) do
        local ok, val = pcall(MCM.Get, id)
        if ok and (type(val)=="string" or type(val)=="number" or type(val)=="boolean") then
            vals[id]=val
        end
    end
    return vals
end
local function HB_ReadSaved()
    local vars = HB_SaveVariables()
    if not vars then return nil end
    local ok, data = pcall(function() return vars[HB_SAVE_KEY] end)
    if ok and type(data)=="table" and data.Version==1 and type(data.Values)=="table" then return data end
end
local function HB_WriteSaved(reason)
    if HB_saveSyncing or not HB_sessionRestored then return end
    local vars=HB_SaveVariables()
    local vals=HB_Snapshot()
    if not vars or not vals then return end
    local data={Version=1, Asset=HB_lastGameAsset or "", Values=vals}
    local ok,err=pcall(function() vars[HB_SAVE_KEY]=data end)
    if ok then HB_cachedSnapshot=data
    else Log("Save-specific difficulty write failed: "..tostring(err)) end
end
local function HB_ApplySnapshot(data,reason)
    if not (MCM and MCM.Set) or type(data)~="table" or type(data.Values)~="table" then return false end
    HB_saveSyncing=true
    local count=0
    for _, id in ipairs(HB_settingIDs) do
        local val=data.Values[id]
        if type(val)=="string" or type(val)=="number" or type(val)=="boolean" then
            local ok,result=pcall(MCM.Set,id,val,nil,false)
            if ok and result~=false then count=count+1 end
        end
    end
    HB_saveSyncing=false
    HB_cachedSnapshot=data
    HB_lastGameAsset=data.Asset~="" and data.Asset or nil
    Log("Restored save-scoped difficulty: "..tostring(reason).." settings="..count.." asset="..tostring(HB_lastGameAsset))
    return count>0
end

local HB_IRONMAN_MODIFIER = "IRONMAN_MODE_338450d9-d77d-4950-9e1e-0e7f12210bb3"
local HB_didLogUnknownIronman = false
local function HB_IsSingleSave()
    if Osi then
        for _,method in ipairs({"GetRulesetModifierBool", "CheckRulesetModifierBool"}) do
            local fn=Osi[method]
            if fn then
                local ok,result
                if method=="CheckRulesetModifierBool" then
                    ok,result=pcall(fn,HB_IRONMAN_MODIFIER,1)
                else
                    ok,result=pcall(fn,HB_IRONMAN_MODIFIER)
                end
                if ok and (result==true or tonumber(result)==1) then return true end
                if ok and (result==false or tonumber(result)==0) then return false end
            end
        end
    end
    if not HB_didLogUnknownIronman then
        HB_didLogUnknownIronman=true
        Log("Single Save ruleset query unavailable; preserving existing MCM behaviour until it can be verified")
    end
    return nil
end

local HB_MCM_PRESET_CHOICES={
    "Default", "Hard", "Very Hard", "Ultra Hard", "HellBrew",
    "Expanded Party Size (Default)", "Expanded Party Size (Hard)",
    "Expanded Party Size (Raid)", "Maximum Difficulty", "Endurance", "Custom",
}
local HB_mcmLastChoiceState=nil
local HB_mcmChoiceTick=0
local HB_mcmChoiceWarned=false
local function HB_HasPlayingHost()
    if not (Osi and Osi.GetHostCharacter and Osi.GetLevel) then return false end
    local okChar,host=pcall(Osi.GetHostCharacter)
    if not okChar or type(host)~="string" or host=="" then return false end
    local okLevel,level=pcall(Osi.GetLevel,host)
    return okLevel and type(level)=="number" and level>=1
end
local function HB_MCMPresetUIState()
    -- N is no verified running campaign. Never unlock the MCM tabs here.
    if not HB_sessionRestored or not HB_HasPlayingHost() then return "N" end
    if HB_IsSingleSave()==false then return "U" end
    local values=HB_cachedSnapshot and HB_cachedSnapshot.Values
    local preset=values and values[DIFFICULTY_PRESET]
    if not HB_MAIN_MENU_ALLOWED_PRESETS[preset] then
        local ok,val=pcall(MCM.Get,DIFFICULTY_PRESET)
        if ok and HB_MAIN_MENU_ALLOWED_PRESETS[val] then preset=val end
    end
    if not HB_MAIN_MENU_ALLOWED_PRESETS[preset] then
        -- Do not create an invalid empty enum. The server guard remains active.
        return nil
    end
    return "L|"..preset
end
local function HB_PublishMCMPresetUI(force)
    local state=HB_MCMPresetUIState()
    if not state then return end
    if state==HB_mcmLastChoiceState and not force then return end
    -- Publish the campaign-state gate even if MCM itself is not yet ready.
    -- This is independently needed to hide all HB configuration tabs on
    -- the main menu, and it must not depend on the enum API being available.
    if MCM and MCM.Enum and MCM.Enum.SetChoices then
        local choices=(state=="N" or state=="U") and HB_MCM_PRESET_CHOICES or {state:sub(3)}
        local ok,result=pcall(MCM.Enum.SetChoices,DIFFICULTY_PRESET,choices)
        if not ok or result==false then
            Log("Single Save MCM enum update failed: "..tostring(result))
        end
    elseif not HB_mcmChoiceWarned then
        HB_mcmChoiceWarned=true
        Log("Single Save enum API unavailable; server guard and MCM menu gate still active")
    end
    if Ext.Net and Ext.Net.BroadcastMessage then
        local sent,err=pcall(Ext.Net.BroadcastMessage,"HB_Difficulty_MCMPresetChoices_V1",state)
        if not sent or err==false then
            Log("Single Save MCM enum client sync unavailable: "..tostring(err))
        end
    end
    if state~=HB_mcmLastChoiceState then
        Log("Single Save MCM choices "..(state=="N" and "no active campaign" or
            state=="U" and "unlocked" or "locked to "..state:sub(3)))
    end
    HB_mcmLastChoiceState=state
end
if Ext.RegisterNetListener then
    Ext.RegisterNetListener("HB_Difficulty_MCMPresetChoices_Request_V1",function(_,_,userId)
        -- Read-only request: the server independently checks its game-owned
        -- ruleset before broadcasting; the sender never supplies a lock value.
        HB_PublishMCMPresetUI(true)
    end)
end
if Ext.Vars and Ext.Vars.RegisterModVariable then
    local ok,err=pcall(Ext.Vars.RegisterModVariable,MOD_UUID,HB_SAVE_KEY,
        {Server=true, Client=false, Persistent=true, WriteableOnServer=true, SyncToClient=false})
    if not ok then Log("Difficulty mod-variable registration failed: "..tostring(err)) end
end
-- A new campaign fires this native creation lifecycle. Do not infer a new
-- game from a main-menu highlight or from a level-one character alone.
if Ext.Osiris and Ext.Osiris.RegisterListener then
    Ext.Osiris.RegisterListener("CharacterCreationStarted",0,"after",function()
        HB_creationStarted=true
        Log("Pending new-game character creation started")
    end)
    Ext.Osiris.RegisterListener("CharacterCreationFinished",0,"after",function()
        HB_creationFinishedPending=true
        Log("Pending new-game character creation finished; started="..tostring(HB_creationStarted))
    end)
end
-- Game-owned Osiris exports can be callable userdata (rather than Lua
-- functions). Guard their *presence*, then invoke using pcall; never reject
-- valid native functions solely because type(value) ~= "function".
local function HB_AuthenticatedHost(userId, event)
    if not Osi or not Osi.GetHostCharacter or not Osi.GetReservedUserID then
        Log(event .. " host functions unavailable: GetHostCharacter="
            .. tostring(Osi and Osi.GetHostCharacter ~= nil)
            .. " GetReservedUserID=" .. tostring(Osi and Osi.GetReservedUserID ~= nil)
            .. " sender=" .. tostring(userId))
        return nil
    end
    local okChar, host = pcall(Osi.GetHostCharacter)
    if not okChar or not host or host == "" then
        Log(event .. " host not available: " .. tostring(host))
        return nil
    end
    local okUser, reserved = pcall(Osi.GetReservedUserID, host)
    local function normalized(number)
        local n=tonumber(number)
        return n and (n - n % 0x10000 + 1) or nil
    end
    if not okUser or not normalized(reserved) or normalized(reserved) ~= normalized(userId) then
        Log(event .. " host-user mismatch: expected=" .. tostring(reserved)
            .. " received=" .. tostring(userId))
        return nil
    end
    return host
end
-- The client sends the authoritative game-owned RulesetSelectionPreset asset from
-- the native difficulty page; this is NOT based on guessed combat modifiers.
if Ext.RegisterNetListener then
    Ext.RegisterNetListener("HB_Difficulty_GameAsset_V1",function(_,message,userId)
        if type(message)~="string" then return end
        local origin,asset=message:match("^(%a+):(.+)$")
        if (origin~="new" and origin~="live") or not HB_DIFFICULTY_ASSETS[asset] then
            Log("Net asset rejected: malformed asset="..tostring(asset))
            return
        end
        if not HB_sessionRestored or not (MCM and MCM.Set) then
            if origin=="new" then
                HB_pendingNewGameAsset=asset
                local previewAsset,previewPreset=HB_ReadMainMenuPreview()
                HB_pendingNewGamePreset=previewAsset==asset and previewPreset or nil
                Log("Pending new-game difficulty captured before session restore: "..tostring(asset))
            else
                Log("Net asset not ready: "..tostring(asset).." session="..tostring(HB_sessionRestored))
            end
            return
        end
        -- Only a verified host sender may alter the campaign difficulty.
        local host=HB_AuthenticatedHost(userId,"Net asset "..asset)
        if not host then return end
        if origin=="new" then
            -- Never overwrite existing saved difficulty state with an old
            -- main-menu selection from another campaign.
            local prior=HB_ReadSaved()
            if prior and prior.Asset and prior.Asset~="" then
                Log("Net asset existing-save protected: "..asset)
                return
            end
            if not Osi or not Osi.GetLevel then
                Log("Net asset level API unavailable: "..asset)
                return
            end
            local levelOK, level=pcall(Osi.GetLevel,host)
            if not levelOK or level~=1 then
                Log("Net asset not first-level host: "..asset.." level="..tostring(level))
                return
            end
        end
        if HB_lastGameAsset==asset then
            Log("Net asset already current: "..asset)
            return
        end
        -- An active Single Save campaign cannot manually change native difficulty.
        -- Initial new-game mapping must still be allowed for Single Save starts.
        if origin~="new" and HB_IsSingleSave() ~= false then
            Log("Net asset Single Save/unknown ruleset lock refused live change: "..asset)
            return
        end
        local preset=HB_DIFFICULTY_ASSETS[asset]
        if origin=="new" then
            local previewAsset,previewPreset=HB_ReadMainMenuPreview()
            if previewAsset==asset and previewPreset then preset=previewPreset end
        end
        HB_mappedPresetEcho=preset
        HB_saveSyncing=true
        local applied,result=pcall(MCM.Set,DIFFICULTY_PRESET,preset)
        HB_saveSyncing=false
        if not applied or result==false then
            -- Never run scaling for a preset that the MCM backend refused to select.
            HB_mappedPresetEcho=nil
            Log("Net asset MCM.Set failed: "..asset.." -> "..preset.." result="..tostring(result))
            return
        end
        -- The existing preset-applier is declared later; we run it from the
        -- existing event loop via this pending asset to preserve declaration order.
        local verified,live=pcall(MCM.Get,DIFFICULTY_PRESET)
        if not verified or live~=preset then
            HB_mappedPresetEcho=nil
            Log("Net asset preset readback failed: asset="..asset.." wanted="..preset.." got="..tostring(live))
            return
        end
        HB_lastGameAsset=asset
        _G.HB_DifficultyAssetToApply=preset
        Log("BG3 difficulty asset received: "..asset.." maps to "..preset)
    end)
end
if Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        -- A preset request deferred from an old campaign must never reach a
        -- newly loaded save. This global pending value is not save-scoped.
        _G.HB_DifficultyAssetToApply=nil
        HB_mappedPresetEcho=nil
        HB_mcmLastChoiceState=nil; HB_mcmChoiceTick=0
        HB_sessionRestored=false; HB_restorePending=true; HB_lastGameAsset=nil
        HB_cachedSnapshot=nil; didInitialRefresh=false; HB_diagnosticHistory={}
        HB_creationStarted=false; HB_creationFinishedPending=false
        HB_creationAppliedAsset=nil; HB_creationFileError=nil
        HB_pendingNewGamePreset=nil
    end)
end

-- Complete difficulty preset definitions.
-- Any setting omitted from a preset is reset to its neutral value.
-- Custom intentionally changes nothing.
local DIFFICULTY_PRESETS = Ext.Require("Shared/DifficultyPresetDetails.lua").Presets

-- The in-game HomeBrew preset list uses the SAME MCM setting and
-- ApplyDifficultyPreset path as the ordinary dropdown. No parallel scaling.
local function HB_IsKnownPreset(preset)
    return type(preset)=="string" and (preset=="Custom" or DIFFICULTY_PRESETS[preset]~=nil)
end
if Ext.RegisterNetListener then
    Ext.RegisterNetListener("HB_Difficulty_PresetChoice_V1",function(_,preset,userId)
        if not HB_IsKnownPreset(preset) then
            Log("In-game preset rejected: unknown value="..tostring(preset))
            return
        end
        if not HB_sessionRestored or not MCM or not MCM.Set then
            Log("In-game preset not ready: "..preset)
            return
        end
        local host=HB_AuthenticatedHost(userId,"In-game preset "..preset)
        if not host then return end
        -- The lock follows the actual campaign Single Save modifier, not Deific.
        if HB_IsSingleSave() ~= false then
            Log("Single Save/unverified ruleset rejected in-game preset: "..preset)
            return
        end
        HB_mappedPresetEcho=preset
        HB_saveSyncing=true
        local ok,err=pcall(MCM.Set,DIFFICULTY_PRESET,preset)
        HB_saveSyncing=false
        if not ok or err==false then
            HB_mappedPresetEcho=nil
            Log("In-game preset MCM.Set failed: "..tostring(err))
            return
        end
        _G.HB_DifficultyAssetToApply=preset
        Log("In-game preset requested: "..preset)
    end)
end

-- HELPERS

-- Log defined before save-scoped difficulty support.

local function IsCharacter(guid)
    return guid ~= nil and guid ~= "" and Osi.IsCharacter(guid) == 1
end

local function IsPlayerCharacter(guid)
    return IsCharacter(guid) and Osi.IsPlayer(guid) == 1
end

local function IsExcludedSummon(guid)
    for _, status in ipairs(SUMMON_EXCLUSION_STATUSES) do
        if Osi.HasActiveStatus(guid, status) == 1 then
            return true
        end
    end

    return false
end

local function IsValidNPCTarget(guid)
    return IsCharacter(guid)
        and not IsPlayerCharacter(guid)
        and not IsExcludedSummon(guid)
end

local function IsValidPlayerTarget(guid)
    return IsPlayerCharacter(guid)
        and not IsExcludedSummon(guid)
end

local function HasStatus(guid, status)
    return status ~= nil
        and status ~= ""
        and Osi.HasActiveStatus(guid, status) == 1
end

local function StatusExists(status)
    if status == nil or status == "" then
        return false
    end

    -- Ext.Stats.Get returns nil when the status is not defined.
    return Ext.Stats.Get(status) ~= nil
end

local function ApplyStatusPermanent(guid, status)
    if not status or status == "" then
        return
    end

    if not StatusExists(status) then
        if not warnedMissingStats[status] then
            warnedMissingStats[status] = true
            Log("Missing status definition: " .. status)
        end
        return
    end

    if not HasStatus(guid, status) then
        Osi.ApplyStatus(guid, status, -1, 1, guid)
    end
end

local function RemoveStatusIfPresent(guid, status)
    if status and status ~= "" and HasStatus(guid, status) then
        Osi.RemoveStatus(guid, status)
    end
end

local function RemoveStatuses(guid, statuses)
    for _, status in ipairs(statuses) do
        RemoveStatusIfPresent(guid, status)
    end
end

local function HasPassive(guid, passive)
    return Osi.HasPassive(guid, passive) == 1
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

local function GetInt(settingId, defaultValue)
    if not (MCM and MCM.Get) then
        return defaultValue
    end

    local value = MCM.Get(settingId)
    if type(value) == "number" then
        return math.floor(value)
    end

    return defaultValue
end

local function GetBool(settingId, defaultValue)
    if not (MCM and MCM.Get) then
        return defaultValue
    end

    local value = MCM.Get(settingId)

    if type(value) == "boolean" then
        return value
    end

    if type(value) == "number" then
        return value ~= 0
    end

    if type(value) == "string" then
        local normalized = value:lower()
        if normalized == "true" or normalized == "1" then
            return true
        end
        if normalized == "false" or normalized == "0" then
            return false
        end
    end

    return defaultValue
end

local function GetString(settingId, defaultValue)
    if not (MCM and MCM.Get) then
        return defaultValue
    end

    local value = MCM.Get(settingId)
    if type(value) == "string" and value ~= "" then
        return value
    end

    return defaultValue
end

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function NormalizeNPCMode(value)
    local mode = tostring(value or "Extreme")
    mode = mode:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    mode = mode:gsub("%s+", "")

    local modeToStatusKey = {
        standard = "veryeasy",
        formidable = "easy",
        extreme = "normal",
        overwhelming = "hard",
        nightmare = "veryhard",
        infernal = "nightmare",
        titanic = "infernal",
        legendary = "legendary",
        ascendant = "ascendant",
        impossible = "impossible",
    }

    if modeToStatusKey[mode] then
        return modeToStatusKey[mode]
    end

    return "normal"
end

local function NormalizePlayerHPMode(value)
    local mode = tostring(value or "Normal")
    mode = mode:gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if mode == "doubled" then return "doubled" end
    if mode == "tripled" then return "tripled" end
    if mode == "quadrupled" then return "quadrupled" end
    if mode == "quintupled" then return "quintupled" end

    return "normal"
end

local function HasAnyStatus(guid, statuses)
    for _, status in ipairs(statuses) do
        if HasStatus(guid, status) then
            return true
        end
    end

    return false
end

-- NPC SYSTEMS

local function ApplyNPCHP(guid, force)
    if not IsValidNPCTarget(guid) then
        RemoveStatuses(guid, ALL_NPC_HP_STATUSES)
        return
    end

    if not force and HasAnyStatus(guid, ALL_NPC_HP_STATUSES) then
        return
    end

    local encounter = EncounterType(guid)
    local mode = NormalizeNPCMode(GetString(NPC_HP_MODE[encounter], "Extreme"))
    local status = NPC_HP_STATUS[encounter][mode]

    RemoveStatuses(guid, ALL_NPC_HP_STATUSES)
    ApplyStatusPermanent(guid, status)
end

local function ApplyNPCStats(guid, force)
    if not IsValidNPCTarget(guid) then
        RemoveStatuses(guid, ALL_STAT_STATUSES)
        return
    end

    local encounter = EncounterType(guid)
    local settings = NPC_STATS[encounter]
    local proficiencySettings = NPC_PROFICIENCY[encounter]

    -- Always rebuild this category. This correctly restores individual
    -- statuses if one was removed while others remained.
    RemoveStatuses(guid, ALL_STAT_STATUSES)

    for statKey, settingId in pairs(settings) do
        if GetBool(proficiencySettings[statKey], false) then
            ApplyStatusPermanent(guid, PROFICIENCY_STAT_STATUS[statKey])
        else
            local value = Clamp(GetInt(settingId, 0), 0, 10)
            if value > 0 then
                ApplyStatusPermanent(guid, STAT_STATUS[statKey][value])
            end
        end
    end
end

local function ApplyNPCResources(guid, force)
    if not IsValidNPCTarget(guid) then
        RemoveStatuses(guid, ALL_RESOURCE_STATUSES)
        return
    end

    local encounter = EncounterType(guid)
    local settings = NPC_RESOURCES[encounter]

    local actions = Clamp(GetInt(settings.actions, 0), 0, 3)
    local bonusActions = Clamp(GetInt(settings.bonusactions, 0), 0, 3)
    local reactions = Clamp(GetInt(settings.reactions, 0), 0, 3)

    RemoveStatuses(guid, ALL_RESOURCE_STATUSES)

    if actions > 0 then
        ApplyStatusPermanent(guid, ACTION_STATUS[actions])
    end

    if bonusActions > 0 then
        ApplyStatusPermanent(guid, BONUS_STATUS[bonusActions])
    end

    if reactions > 0 then
        ApplyStatusPermanent(guid, REACTION_STATUS[reactions])
    end
end

-- PLAYER SYSTEMS

local function ApplyPlayerHP(guid, force)
    if not IsValidPlayerTarget(guid) then
        RemoveStatuses(guid, ALL_PLAYER_HP_STATUSES)
        return
    end

    if not force and HasAnyStatus(guid, ALL_PLAYER_HP_STATUSES) then
        return
    end

    local mode = NormalizePlayerHPMode(GetString(PLAYER_HP_MODE, "Normal"))

    RemoveStatuses(guid, ALL_PLAYER_HP_STATUSES)

    -- Normal means no multiplier status.
    if mode ~= "normal" then
        ApplyStatusPermanent(guid, PLAYER_HP_STATUS[mode])
    end
end

local function ApplyPlayerStats(guid, force)
    if not IsValidPlayerTarget(guid) then
        RemoveStatuses(guid, ALL_STAT_STATUSES)
        return
    end

    RemoveStatuses(guid, ALL_STAT_STATUSES)

    for statKey, settingId in pairs(PLAYER_STATS) do
        if GetBool(PLAYER_PROFICIENCY[statKey], false) then
            ApplyStatusPermanent(guid, PROFICIENCY_STAT_STATUS[statKey])
        else
            local value = Clamp(GetInt(settingId, 0), 0, 10)
            if value > 0 then
                ApplyStatusPermanent(guid, STAT_STATUS[statKey][value])
            end
        end
    end
end

local function ApplyPlayerResources(guid, force)
    if not IsValidPlayerTarget(guid) then
        RemoveStatuses(guid, ALL_RESOURCE_STATUSES)
        return
    end

    local actions = Clamp(GetInt(PLAYER_RESOURCES.actions, 0), 0, 3)
    local bonusActions = Clamp(GetInt(PLAYER_RESOURCES.bonusactions, 0), 0, 3)
    local reactions = Clamp(GetInt(PLAYER_RESOURCES.reactions, 0), 0, 3)

    RemoveStatuses(guid, ALL_RESOURCE_STATUSES)

    if actions > 0 then
        ApplyStatusPermanent(guid, ACTION_STATUS[actions])
    end

    if bonusActions > 0 then
        ApplyStatusPermanent(guid, BONUS_STATUS[bonusActions])
    end

    if reactions > 0 then
        ApplyStatusPermanent(guid, REACTION_STATUS[reactions])
    end
end

-- ROUTING

local function ApplyHP(guid, force)
    if IsPlayerCharacter(guid) then
        RemoveStatuses(guid, ALL_NPC_HP_STATUSES)
        ApplyPlayerHP(guid, force)
    else
        RemoveStatuses(guid, ALL_PLAYER_HP_STATUSES)
        ApplyNPCHP(guid, force)
    end
end

local function ApplyStats(guid, force)
    if IsPlayerCharacter(guid) then
        ApplyPlayerStats(guid, force)
    else
        ApplyNPCStats(guid, force)
    end
end

local function ApplyResources(guid, force)
    if IsPlayerCharacter(guid) then
        ApplyPlayerResources(guid, force)
    else
        ApplyNPCResources(guid, force)
    end
end

local function ApplyAllSystems(guid, force)
    if not IsCharacter(guid) then
        return
    end

    if IsExcludedSummon(guid) then
        RemoveStatuses(guid, ALL_NPC_HP_STATUSES)
        RemoveStatuses(guid, ALL_PLAYER_HP_STATUSES)
        RemoveStatuses(guid, ALL_STAT_STATUSES)
        RemoveStatuses(guid, ALL_RESOURCE_STATUSES)
        return
    end

    ApplyHP(guid, force)
    ApplyStats(guid, force)
    ApplyResources(guid, force)
end

-- REFRESH

local function ForEachLoadedCharacter(callback)
    local seen = 0

    for _, entity in pairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
        local guid = entity.Uuid and entity.Uuid.EntityUuid
        if IsCharacter(guid) then
            seen = seen + 1
            callback(guid)
        end
    end

    return seen
end

local function RefreshAllLoaded(reason, force)
    local seen = ForEachLoadedCharacter(function(guid)
        ApplyAllSystems(guid, force == true)
    end)

    Log(string.format(
        "%s refresh (force=%s, characters=%d)",
        tostring(reason),
        tostring(force == true),
        seen
    ))
end

local function RefreshHPOnly(reason)
    local seen = ForEachLoadedCharacter(function(guid)
        ApplyHP(guid, true)
    end)

    Log(string.format("%s HP refresh (characters=%d)", tostring(reason), seen))
end

local function RefreshStatsOnly(reason)
    local seen = ForEachLoadedCharacter(function(guid)
        ApplyStats(guid, true)
    end)

    Log(string.format("%s stats refresh (characters=%d)", tostring(reason), seen))
end

local function RefreshResourcesOnly(reason)
    local seen = ForEachLoadedCharacter(function(guid)
        ApplyResources(guid, true)
    end)

    Log(string.format("%s resources refresh (characters=%d)", tostring(reason), seen))
end

local function ApplyDifficultyPreset(presetName)
    if presetName == nil or presetName == "" or presetName == "Custom" then
        Log("Difficulty preset set to Custom; manual settings preserved.")
        return
    end

    local preset = DIFFICULTY_PRESETS[presetName]
    if preset == nil then
        Log("Unknown difficulty preset: " .. tostring(presetName))
        return
    end

    if not (MCM and MCM.Set) then
        Log("Cannot apply preset because MCM.Set is unavailable.")
        return
    end

    isApplyingPreset = true

    -- Reset every configurable difficulty setting to neutral values first.
    for _, settingId in pairs(NPC_HP_MODE) do
        MCM.Set(settingId, "Extreme")
    end

    for _, encounterSettings in pairs(NPC_STATS) do
        for _, settingId in pairs(encounterSettings) do
            MCM.Set(settingId, 0)
        end
    end

    for _, encounterSettings in pairs(NPC_PROFICIENCY) do
        for _, settingId in pairs(encounterSettings) do
            MCM.Set(settingId, false)
        end
    end

    for _, encounterSettings in pairs(NPC_RESOURCES) do
        for _, settingId in pairs(encounterSettings) do
            MCM.Set(settingId, 0)
        end
    end

    MCM.Set(PLAYER_HP_MODE, "Normal")

    for _, settingId in pairs(PLAYER_STATS) do
        MCM.Set(settingId, 0)
    end

    for _, settingId in pairs(PLAYER_PROFICIENCY) do
        MCM.Set(settingId, false)
    end

    for _, settingId in pairs(PLAYER_RESOURCES) do
        MCM.Set(settingId, 0)
    end

    -- NPC Hit Points
    local npcHPMode = preset.npcHP or "Extreme"
    for _, settingId in pairs(NPC_HP_MODE) do
        MCM.Set(settingId, npcHPMode)
    end

    -- NPC flat stat bonuses
    local npcStatValue = Clamp(tonumber(preset.npcStats) or 0, 0, 10)
    if npcStatValue > 0 then
        for _, encounterSettings in pairs(NPC_STATS) do
            for _, settingId in pairs(encounterSettings) do
                MCM.Set(settingId, npcStatValue)
            end
        end
    end

    -- NPC proficiency scaling
    if preset.npcProficiency == true then
        for _, encounterSettings in pairs(NPC_PROFICIENCY) do
            for _, settingId in pairs(encounterSettings) do
                MCM.Set(settingId, true)
            end
        end
    end

    -- NPC resources by encounter category
    if type(preset.npcResources) == "table" then
        for encounter, value in pairs(preset.npcResources) do
            local encounterSettings = NPC_RESOURCES[encounter]
            if encounterSettings ~= nil then
                local resourceValue = Clamp(tonumber(value) or 0, 0, 3)
                for _, settingId in pairs(encounterSettings) do
                    MCM.Set(settingId, resourceValue)
                end
            end
        end
    end

    -- Player Hit Points
    MCM.Set(PLAYER_HP_MODE, preset.playerHP or "Normal")

    -- Player proficiency scaling
    if preset.playerProficiency == true then
        for _, settingId in pairs(PLAYER_PROFICIENCY) do
            MCM.Set(settingId, true)
        end
    end

    -- Player resources
    local playerResourceValue = Clamp(tonumber(preset.playerResources) or 0, 0, 3)
    if playerResourceValue > 0 then
        for _, settingId in pairs(PLAYER_RESOURCES) do
            MCM.Set(settingId, playerResourceValue)
        end
    end

    isApplyingPreset = false
    HB_WriteSaved("preset: " .. tostring(presetName))

    RefreshAllLoaded("Difficulty preset applied: " .. presetName, true)
    Log("Applied complete difficulty preset: " .. tostring(presetName))
end

local PROFICIENCY_SLIDER = {}

for encounter, proficiencySettings in pairs(NPC_PROFICIENCY) do
    for statKey, proficiencySettingId in pairs(proficiencySettings) do
        PROFICIENCY_SLIDER[proficiencySettingId] = NPC_STATS[encounter][statKey]
    end
end

for statKey, proficiencySettingId in pairs(PLAYER_PROFICIENCY) do
    PROFICIENCY_SLIDER[proficiencySettingId] = PLAYER_STATS[statKey]
end

local SLIDER_PROFICIENCY = {}
for proficiencySettingId, sliderSettingId in pairs(PROFICIENCY_SLIDER) do
    SLIDER_PROFICIENCY[sliderSettingId] = proficiencySettingId
end

local function EnforceProficiencyOverride(settingId)
    local sliderSettingId = PROFICIENCY_SLIDER[settingId]
    if sliderSettingId == nil or not GetBool(settingId, false) then
        return
    end

    if MCM and MCM.Set and GetInt(sliderSettingId, 0) ~= 0 then
        isApplyingPreset = true
        MCM.Set(sliderSettingId, 0)
        isApplyingPreset = false

        Log(
            "Proficiency enabled for " .. tostring(settingId)
            .. "; reset " .. tostring(sliderSettingId) .. " to 0."
        )
    end
end

local function DisableProficiencyForSlider(settingId)
    local proficiencySettingId = SLIDER_PROFICIENCY[settingId]
    if proficiencySettingId == nil then
        return
    end

    local sliderValue = GetInt(settingId, 0)
    if sliderValue <= 0 or not GetBool(proficiencySettingId, false) then
        return
    end

    if MCM and MCM.Set then
        isApplyingPreset = true
        MCM.Set(proficiencySettingId, false)
        isApplyingPreset = false

        Log(
            "Slider " .. tostring(settingId)
            .. " changed above 0; disabled " .. tostring(proficiencySettingId) .. "."
        )
    end
end

local function RefreshForSetting(settingId)
    if type(settingId) ~= "string" then
        RefreshAllLoaded("MCM changed", true)
        return
    end

    if settingId == PLAYER_HP_MODE or settingId:find("^hb_hp_mode_") then
        RefreshHPOnly("MCM changed: " .. settingId)
        return
    end

    if settingId:find("^hb_res_") or settingId:find("^hb_player_res_") then
        RefreshResourcesOnly("MCM changed: " .. settingId)
        return
    end

    if settingId:find("^hb_stats_") or settingId:find("^hb_player_stats_") then
        RefreshStatsOnly("MCM changed: " .. settingId)
        return
    end

    RefreshAllLoaded("MCM changed: " .. settingId, true)
end

-- EVENTS

Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(guid)
    -- A newly joined companion must be moved from the NPC route to
    -- the player route immediately.
    if IsCharacter(guid) then
        ApplyAllSystems(guid, true)
    end
end)

Ext.Osiris.RegisterListener(
    "LevelGameplayStarted",
    2,
    "after",
    function(levelName, isEditorMode)
        RefreshAllLoaded("Level started: " .. tostring(levelName), false)
    end
)

Ext.ModEvents.BG3MCM["MCM_Setting_Saved"]:Subscribe(function(payload)
    if not payload or payload.modUUID ~= MOD_UUID or type(payload.settingId)~="string" then return end
    if isApplyingPreset or HB_saveSyncing or not HB_sessionRestored then return end
    -- NEVER block the original MCM preset/scaling path just because BG3's
    -- game difficulty asset was not reported. The prior experiment caused all
    -- preset changes and HP refreshes to fail in newly created campaigns.
    -- The Single Save lock is checked separately against the ruleset modifier.
    if not HB_lastGameAsset and payload.settingId == DIFFICULTY_PRESET then
        Log("Difficulty asset pending: permitting original preset editor to operate")
    end

    -- This is the automatic/native preset already validated by the server.
    -- The dedicated Tick path will apply the complete preset once.
    if payload.settingId==DIFFICULTY_PRESET and HB_mappedPresetEcho == payload.value then
        HB_mappedPresetEcho=nil
        return
    end
    -- In-game button and direct MCM both obey the actual Single Save modifier.
    if HB_IsSingleSave() ~= false then
        if HB_cachedSnapshot then
            HB_ApplySnapshot(HB_cachedSnapshot,"Single Save lock")
            -- MCM saves its value before broadcasting this event. Restore any
            -- already-applied status effects as well as the setting values.
            RefreshAllLoaded("Single Save rejected MCM edit",true)
        end
        Log("Single Save/unverified ruleset rejected MCM change: "..payload.settingId)
        return
    end
    if payload.settingId == DIFFICULTY_PRESET and not HB_MAIN_MENU_ALLOWED_PRESETS[payload.value] then
        if HB_cachedSnapshot then HB_ApplySnapshot(HB_cachedSnapshot,"invalid preset rejection") end
        Log("Single Save MCM rejected unrecognized difficulty preset: "..tostring(payload.value))
        return
    end
    if payload.settingId == DIFFICULTY_PRESET then
        local preset=GetString(DIFFICULTY_PRESET,"Default")
        ApplyDifficultyPreset(preset)
        HB_WriteSaved("preset dropdown")
        return
    end
    -- A named preset is read-only. The user must explicitly choose Custom.
    if GetString(DIFFICULTY_PRESET,"Default") ~= "Custom" then
        if HB_cachedSnapshot then HB_ApplySnapshot(HB_cachedSnapshot,"Custom-only setting lock") end
        Log("Setting locked until Custom selected: "..payload.settingId)
        return
    end
    EnforceProficiencyOverride(payload.settingId)
    DisableProficiencyForSlider(payload.settingId)
    HB_WriteSaved("custom setting: "..payload.settingId)
    RefreshForSetting(payload.settingId)
end)

-- Exact custom field catalog shared with the native in-game editor.
-- Validate a whole request before changing any MCM value. Session-scoped and
-- authenticated, with no dependency on client-selected input ranges.
local HB_CUSTOM_CATALOG=Ext.Require("Shared/DifficultyCustomCatalog.lua")
local HB_CUSTOM_FIELDS={}
for _,tab in ipairs(HB_CUSTOM_CATALOG) do
    for _,field in ipairs(tab.settings) do HB_CUSTOM_FIELDS[field.id]=field end
end
local function HB_ValidateCustomValue(field,value)
    if field.kind=="checkbox" then return type(value)=="boolean" end
    if field.kind=="slider_int" then
        return type(value)=="number" and value==math.floor(value)
            and value>=field.min and value<=field.max
    end
    if field.kind=="enum" then
        if type(value)~="string" then return false end
        for _,choice in ipairs(field.choices) do if choice==value then return true end end
    end
    return false
end
-- A New Game Custom editor has no live server session while the player edits.
-- Its fields are read only after a paired native character creation, and only
-- for the same BG3 difficulty card/preset that passed the normal handoff.
local HB_MAIN_MENU_CUSTOM_FILE="HomeBrew/Diagnostics/HB_MainMenuCustomPreview.json"
local function HB_ReadNewGameCustom(asset)
    if not (Ext.IO and Ext.IO.LoadFile and Ext.Json and Ext.Json.Parse) then return nil end
    local ok,raw=pcall(Ext.IO.LoadFile,HB_MAIN_MENU_CUSTOM_FILE)
    if not ok or type(raw)~="string" or #raw<2 or #raw>12000 then return nil end
    local decoded,data=pcall(Ext.Json.Parse,raw)
    if not decoded or type(data)~="table" or data.Version~=1
        or data.Asset~=asset or data.Preset~="Custom" or type(data.Values)~="table" then
        Log("New Game Custom preview refused: mismatch or invalid payload")
        return nil
    end
    local count=0
    for id,value in pairs(data.Values) do
        if not HB_ValidateCustomValue(HB_CUSTOM_FIELDS[id],value) then
            Log("New Game Custom preview rejected field "..tostring(id))
            return nil
        end
        count=count+1
    end
    if count<1 or count>64 then return nil end
    return data.Values,count
end
local function HB_ApplyNewGameCustom(asset)
    local changes,count=HB_ReadNewGameCustom(asset)
    if not changes then return end
    local previous=HB_Snapshot()
    HB_saveSyncing=true
    local successful=true
    for id,value in pairs(changes) do
        local ok,result=pcall(MCM.Set,id,value,nil,false)
        local readOK,actual=pcall(MCM.Get,id)
        if not ok or result==false or not readOK or actual~=value then
            successful=false
            Log("New Game Custom setting write/readback failed: "..tostring(id))
            break
        end
    end
    if successful then
        for id in pairs(changes) do
            EnforceProficiencyOverride(id)
            DisableProficiencyForSlider(id)
        end
    end
    HB_saveSyncing=false
    if not successful then
        if previous then HB_ApplySnapshot({Version=1,Asset=asset,Values=previous},"failed new-game Custom edits") end
        return
    end
    Log("New Game Custom settings restored after character creation: "..count)
end
if Ext.RegisterNetListener then
    Ext.RegisterNetListener("HB_Difficulty_CustomEdits_V1",function(_,message,userId)
        if not HB_sessionRestored or not MCM or not MCM.Set then return end
        if not HB_AuthenticatedHost(userId,"In-game custom edits") then return end
        if HB_IsSingleSave()~=false or GetString(DIFFICULTY_PRESET,"Default")~="Custom" then
            Log("In-game custom edits refused: Single Save or non-Custom preset")
            return
        end
        if type(message)~="string" or #message>16000 then return end
        local ok,data=pcall(Ext.Json.Parse,message)
        if not ok or type(data)~="table" then return end
        local count=0
        for id,value in pairs(data) do
            local field=HB_CUSTOM_FIELDS[id]
            if not field or not HB_ValidateCustomValue(field,value) then
                Log("In-game custom edits rejected invalid field: "..tostring(id))
                return
            end
            count=count+1
        end
        if count==0 or count>64 then return end
        local prior=HB_Snapshot()
        HB_saveSyncing=true
        local successful=true
        for id,value in pairs(data) do
            local worked,result=pcall(MCM.Set,id,value,nil,false)
            if not worked or result==false then
                successful=false
                Log("In-game custom MCM.Set failed for "..tostring(id)..": "..tostring(result))
                break
            end
        end
        if successful then
            -- Mirror the built-in Custom editor's mutually-exclusive
            -- proficiency-checkbox versus numeric-slider handling.
            for id in pairs(data) do
                EnforceProficiencyOverride(id)
                DisableProficiencyForSlider(id)
            end
        end
        HB_saveSyncing=false
        if not successful then
            if prior then HB_ApplySnapshot({Version=1,Asset=HB_lastGameAsset or "",Values=prior},"failed custom edit rollback") end
            return
        end
        HB_WriteSaved("native custom edits")
        RefreshAllLoaded("Native Custom settings",true)
        Log("In-game custom edits committed: "..tostring(count))
    end)
end

Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combatGuid)
    RefreshAllLoaded("Combat started: " .. tostring(combatGuid), false)
end)

Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(guid, combatGuid)
    if IsCharacter(guid) then
        pendingEnteredCombat[guid] = 2
    end
end)

Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(object, status, causee, storyActionID)
    if IsCharacter(object) then
        for _, exclusionStatus in ipairs(SUMMON_EXCLUSION_STATUSES) do
            if status == exclusionStatus then
                ApplyAllSystems(object, true)
                return
            end
        end
    end
end)

Ext.Events.Tick:Subscribe(function()
    if HB_restorePending and MCM and MCM.Get and MCM.Set then
        HB_restorePending=false
        local saved=HB_ReadSaved()
        if saved then
            HB_ApplySnapshot(saved,"SessionLoaded")
        else
            -- Do not apply an arbitrary preset to a pre-existing save. An
            -- unclassified old Deific campaign must never be downgraded to
            -- Default while waiting for its native difficulty to be checked.
            HB_cachedSnapshot={Version=1,Asset="",Values=HB_Snapshot() or {}}
            Log("Legacy save: preserving current effects until native difficulty identification")
        end
        HB_sessionRestored=true
        Log(saved and "Loaded per-save MCM settings" or "No per-save record yet: original MCM/scaling remains active")
    end
    if HB_sessionRestored and HB_creationFinishedPending then
        HB_creationFinishedPending=false
        local saved=HB_ReadSaved()
        if saved and saved.Asset and saved.Asset~="" then
            Log("Pending new-game creation ignored: campaign already has save-scoped asset="..saved.Asset)
        elseif not HB_creationStarted then
            -- Existing character-creation editors must not consume a stale
            -- front-end preview without a matching native creation start.
            Log("Pending new-game creation finish had no matching start; preview untouched")
        else
            local asset,explicitPreset=HB_ReadMainMenuPreview()
            if asset then
                HB_pendingNewGameAsset=asset
                HB_pendingNewGamePreset=explicitPreset
                HB_creationAppliedAsset=asset
                Log("Pending new-game verified character creation maps "..asset
                    .." to "..(explicitPreset or HB_DIFFICULTY_ASSETS[asset]))
            else
                Log("Pending new-game front-end preview unavailable after creation")
            end
        end
        HB_creationStarted=false
    end
    if HB_sessionRestored and HB_pendingNewGameAsset and not HB_lastGameAsset then
        local saved=HB_ReadSaved()
        if saved and saved.Asset and saved.Asset~="" then
            Log("Pending new-game difficulty discarded for existing save: "..tostring(HB_pendingNewGameAsset))
            HB_pendingNewGameAsset=nil
            HB_pendingNewGamePreset=nil
        elseif Osi and Osi.GetHostCharacter and Osi.GetLevel then
            local okHost,host=pcall(Osi.GetHostCharacter)
            local okLevel,level=false,nil
            if okHost and host and host~="" then okLevel,level=pcall(Osi.GetLevel,host) end
            level = okLevel and level or nil
            if level==1 then
                local asset=HB_pendingNewGameAsset
                HB_pendingNewGameAsset=nil
                local preset=HB_pendingNewGamePreset or HB_DIFFICULTY_ASSETS[asset]
                HB_pendingNewGamePreset=nil
                HB_mappedPresetEcho=preset
                HB_saveSyncing=true
                local ok,result=pcall(MCM.Set,DIFFICULTY_PRESET,preset)
                HB_saveSyncing=false
                local verified,live=pcall(MCM.Get,DIFFICULTY_PRESET)
                if ok and result~=false and verified and live==preset then
                    HB_lastGameAsset=asset
                    _G.HB_DifficultyAssetToApply=preset
                    Log("Pending new-game difficulty applied after session restore: "..tostring(asset))
                else
                    HB_mappedPresetEcho=nil
                    Log("Pending new-game difficulty MCM.Set/readback failed: "..tostring(asset).." error="..tostring(result).." actual="..tostring(live))
                end
            elseif level and level~=1 then
                Log("Pending new-game difficulty discarded because host level is "..tostring(level))
                HB_pendingNewGameAsset=nil
                HB_pendingNewGamePreset=nil
            end
        end
    end
    if HB_sessionRestored and _G.HB_DifficultyAssetToApply then
        local preset=_G.HB_DifficultyAssetToApply
        _G.HB_DifficultyAssetToApply=nil
        ApplyDifficultyPreset(preset)
        if preset=="Custom" and HB_creationAppliedAsset and HB_lastGameAsset==HB_creationAppliedAsset then
            HB_ApplyNewGameCustom(HB_creationAppliedAsset)
        end
        HB_WriteSaved("BG3 difficulty mapping")
        if HB_creationAppliedAsset and HB_lastGameAsset==HB_creationAppliedAsset then
            local saved=HB_ReadSaved()
            if saved and saved.Asset==HB_creationAppliedAsset then
                local cleared,result=pcall(Ext.IO.SaveFile,HB_MAIN_MENU_PREVIEW_FILE,"")
                if preset=="Custom" then
                    pcall(Ext.IO.SaveFile,HB_MAIN_MENU_CUSTOM_FILE,"")
                end
                Log("Pending new-game handoff committed to save; cleared preview="
                    ..tostring(cleared and result~=false))
                HB_creationAppliedAsset=nil
            end
        end
    end
    if HB_sessionRestored and not didInitialRefresh and MCM and MCM.Get then
        RefreshAllLoaded("Initial", false)
        didInitialRefresh = true
    end

    -- Reconcile on a bounded cadence, never on every frame. Session changes
    -- and MCM-window requests also force a fresh client sync.
    HB_mcmChoiceTick=HB_mcmChoiceTick+1
    if HB_mcmChoiceTick>=90 then
        HB_mcmChoiceTick=0
        HB_PublishMCMPresetUI(false)
    end

    for guid, ticksRemaining in pairs(pendingEnteredCombat) do
        ticksRemaining = ticksRemaining - 1

        if ticksRemaining <= 0 then
            pendingEnteredCombat[guid] = nil
            ApplyAllSystems(guid, false)
        else
            pendingEnteredCombat[guid] = ticksRemaining
        end
    end
end)

Log("Loaded: NPC and player HP, stats, resources, and proficiency overrides are active.")
