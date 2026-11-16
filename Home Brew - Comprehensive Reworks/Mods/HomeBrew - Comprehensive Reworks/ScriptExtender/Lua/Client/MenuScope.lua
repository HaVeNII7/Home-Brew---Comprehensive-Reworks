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
    LevelUp = { CharacterLevelUp=true, CharacterLevelUp_c=true },
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
local pageGroups = {}
for group, names in pairs(groups) do
    for name in pairs(names) do
        local groupSet = pageGroups[name]
        if not groupSet then groupSet = {}; pageGroups[name] = groupSet end
        groupSet[group] = true
    end
end
local function Read(o, key)
    if not o then return nil end
    local ok, value = pcall(function() return o[key] end)
    if ok then return value end
end
local function FilePage(name)
    if type(name) ~= 'string' then return nil end
    return name:match('([^/\\]+)%.xaml$')
end
-- Several independent UI workers can ask for different menu scopes in the
-- same Noesis frame. Share only a very short-lived *boolean* snapshot; never
-- retain native widget proxies across frames or cache game authority state.
local sampledAt, sampled = nil, {}
local SAMPLE_MS = 25
local sampleReady, started, sampling = false, false, false
local nextSample = 0
local activeGroup = false
-- Main-thread readers may consult only the last boolean snapshot. The native
-- Noesis root is NEVER accessed outside Ext.UI.Defer.
function Scope.MaybeOpen(group)
    if not groups[group] then return true end
    if not sampleReady then return true end
    return sampled[group] == true
end

function Scope.IsOpen(group)
    if not groups[group] or not Ext or not Ext.UI or not Ext.UI.GetRoot then return false end
    local timer = Ext.Timer and Ext.Timer.MonotonicTime
    local now = timer and timer()
    if now and sampledAt and now >= sampledAt and now - sampledAt <= SAMPLE_MS then
        return sampled[group] == true
    end
    local visible = {}
    local ok, root = pcall(Ext.UI.GetRoot)
    if ok and root then
        local content = Read(root, 'ContentRoot')
        if not content then
            local found, fallback = pcall(function() return root:Find('ContentRoot') end)
            if found then content = fallback end
        end
        if content then
            local count = math.min(tonumber(Read(content, 'ChildrenCount')) or 0, 120)
            for index = 1, count do
                local safe, node = pcall(function() return content:Child(index) end)
                if safe and node then
                    local name = Read(node, 'Name')
                    local file = FilePage(Read(node, 'FileName'))
                    local fromName, fromFile = pageGroups[name], pageGroups[file]
                    if (fromName or fromFile) and Read(node, 'IsVisible') ~= false then
                        for group in pairs(fromName or {}) do visible[group] = true end
                        for group in pairs(fromFile or {}) do visible[group] = true end
                    end
                end
            end
        end
    end
    sampledAt, sampled = now, visible
    sampleReady = true
    activeGroup = next(visible) ~= nil
    return visible[group] == true
end
-- Called once, from the client bootstrap. Poll one shallow set of mounted
-- pages rather than running separate deferred discovery callbacks for each
-- menu-only module while exploring. No application or spell/feat work here.
function Scope.Start()
    if started or not (Ext.Events and Ext.Events.Tick and Ext.UI
        and Ext.UI.Defer and Ext.Timer and Ext.Timer.MonotonicTime) then return end
    started = true
    Ext.Events.Tick:Subscribe(function()
        local now = Ext.Timer.MonotonicTime()
        if sampling or now < nextSample then return end
        nextSample = now + (activeGroup and 120 or 400)
        sampling = true
        local ok = pcall(Ext.UI.Defer, function()
            sampling = false
            -- IsOpen refreshes its short-lived cache on the UI thread. It
            -- samples all groups at once and retains only booleans.
            local sampledOk = pcall(Scope.IsOpen, 'Character')
            if not sampledOk then sampleReady = false end
        end)
        if not ok then sampling = false; sampleReady = false end
    end)
end
return Scope
