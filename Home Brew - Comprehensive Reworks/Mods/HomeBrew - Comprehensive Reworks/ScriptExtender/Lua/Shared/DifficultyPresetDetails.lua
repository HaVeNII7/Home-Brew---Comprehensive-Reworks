-- Canonical named difficulty presets used by both the server and the read-only UI.
local DIFFICULTY_PRESETS = {
    Default = {
        npcHP = "Standard",
    },
    Hard = {
        npcHP = "Formidable",
    },
    ["Very Hard"] = {
        npcHP = "Extreme",
    },
    ["Ultra Hard"] = {
        npcHP = "Extreme",
        npcProficiency = true,
    },
    HellBrew = {
        npcHP = "Extreme",
        npcProficiency = true,
        npcResources = {
            dangerous = 1,
            fatal = 2,
        },
    },
    ["Expanded Party Size (Default)"] = {
        npcHP = "Infernal",
    },
    ["Expanded Party Size (Hard)"] = {
        npcHP = "Infernal",
        npcProficiency = true,
    },
    ["Expanded Party Size (Raid)"] = {
        npcHP = "Infernal",
        npcProficiency = true,
        npcResources = {
            dangerous = 1,
            fatal = 2,
        },
    },
    ["Maximum Difficulty"] = {
        npcHP = "Impossible",
        npcResources = {
            normal = 3,
            dangerous = 3,
            fatal = 3,
        },
        npcStats = 10,
    },
    Endurance = {
        npcHP = "Nightmare",
        playerHP = "Quintupled",
        npcProficiency = true,
        playerProficiency = true,
        npcResources = {
            normal = 1,
            dangerous = 1,
            fatal = 1,
        },
        playerResources = 1,
    },
}

-- Mirrors the setting IDs and neutral defaults in HarderDifficulty.ApplyDifficultyPreset.
-- This is pure presentation data: no MCM.Set, game state, or networking.
local function ValuesFor(presetName, catalog)
    local preset=DIFFICULTY_PRESETS[presetName]
    if not preset or type(catalog)~="table" then return nil end
    local values={}
    for _,category in ipairs(catalog) do
        for _,field in ipairs(category.settings) do
            local id=field.id
            local value=nil
            if (id=="hb_hp_mode_normal" or id=="hb_hp_mode_dangerous" or id=="hb_hp_mode_fatal") then
                value=preset.npcHP or "Extreme"
            elseif id=="hb_player_hp_mode" then
                value=preset.playerHP or "Normal"
            elseif id:match("^hb_stats_prof_") then
                value=preset.npcProficiency==true
            elseif id:match("^hb_player_stats_prof_") then
                value=preset.playerProficiency==true
            elseif id:match("^hb_stats_") then
                value=preset.npcStats or 0
            elseif id:match("^hb_player_stats_") then
                value=0
            elseif id:match("^hb_res_") then
                local encounter=id:match("^hb_res_([^_]+)_")
                value=(preset.npcResources and preset.npcResources[encounter]) or 0
            elseif id:match("^hb_player_res_") then
                value=preset.playerResources or 0
            end
            if value==nil then return nil end
            values[id]=value
        end
    end
    return values
end
return {Presets=DIFFICULTY_PRESETS, ValuesFor=ValuesFor}
