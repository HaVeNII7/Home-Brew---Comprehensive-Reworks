-- Cheap, read-only gate for HomeBrew's menu-only client systems.
-- Called by existing Tick listeners at coarse intervals; it does no deep
-- Noesis traversal, static-data enumeration, or diagnostic file writes.
local Scope = {}
local groups = {
    -- This widget is already created by the Paused state in both input modes.
    -- Use it only as a cheap presence check; do not modify its game-over logic.
    Pause = { HB_NormalGameOverBridge = true },
    Difficulty = {
        DMSettings=true, NewGameSettings=true, NewGameSettings_c=true,
        HB_HonouredMyth_NewGameSettings=true, HB_HonouredMyth_NewGameSettings_c=true,
    },
    Character = {
        CharacterCreation=true, CharacterCreation_c=true,
        CharacterLevelUp=true, CharacterLevelUp_c=true,
        CharacterRespec=true, CharacterRespec_c=true,
    },
    Presets = {
        CharacterCreation=true, CharacterCreation_c=true,
        CharacterLevelUp=true, CharacterLevelUp_c=true,
        CharacterRespec=true, CharacterRespec_c=true,
        CharacterChangeAppearance=true, CharacterChangeAppearance_c=true,
        MagicMirror=true, MagicMirror_c=true,
    },
    Respec = { CharacterRespec=true, CharacterRespec_c=true },
    Save = {
        SaveGame=true, SaveGame_c=true,
        HB_SaveTitles_SaveGame=true, HB_SaveTitles_SaveGame_c=true,
    },
    SaveLoad = {
        SaveGame=true, SaveGame_c=true, LoadGame=true, LoadGame_c=true,
        HB_SaveTitles_SaveGame=true, HB_SaveTitles_SaveGame_c=true,
        HB_SaveTitles_LoadGame=true, HB_SaveTitles_LoadGame_c=true,
    },
}
local function Read(o, key)
    if not o then return nil end
    local ok, value = pcall(function() return o[key] end)
    if ok then return value end
end
local function FilePage(name)
    if type(name) ~= 'string' then return nil end
    return name:gsub('\\', '/'):match('([^/]+)%.xaml$')
end
function Scope.IsOpen(group)
    local names = groups[group]
    if not names or not Ext or not Ext.UI or not Ext.UI.GetRoot then return false end
    local ok, root = pcall(Ext.UI.GetRoot)
    if not ok or not root then return false end
    local found, content = pcall(function() return root:Find('ContentRoot') end)
    if not found or not content then return false end
    local count = math.min(tonumber(Read(content, 'ChildrenCount')) or 0, 120)
    for index = 1, count do
        local safe, node = pcall(function() return content:Child(index) end)
        if safe and node and Read(node, 'IsVisible') ~= false then
            local name, file = Read(node, 'Name'), FilePage(Read(node, 'FileName'))
            if names[name] or names[file] then return true end
        end
    end
    return false
end
return Scope
