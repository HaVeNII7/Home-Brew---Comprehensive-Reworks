-- HomeBrew Save/Load *identity-only* probe, v2.
-- Temporary, read-only. Never loads, saves, or modifies an actual BG3 save.
-- Deliberately does NOT load Client/SaveLoadDiagnostics.lua (the old v50
-- probe that walked 1,000+ UI nodes and was associated with a crash).
-- Each UI tick limits access to direct named pages, direct ContentRoot children
-- (at most 12), and the SelectedSave object's scalar properties.
local OUTPUT = 'HomeBrew/Diagnostics/HB_SaveDifficultyIdentity_Probe.txt'
local marker = nil
local lastTick = 0
local active = false
local busy = false
local function read(o, name)
    if o == nil then return nil end
    local ok, value = pcall(function() return o[name] end)
    return ok and value or nil
end
local function scalar(value)
    local ty = type(value)
    if ty == 'nil' then return 'nil' end
    if ty == 'string' or ty == 'number' or ty == 'boolean' then
        local s = tostring(value)
        if #s > 220 then return s:sub(1,220)..'[truncated]' end
        return s:gsub('[\r\n]', ' ')
    end
    return '('..ty..')'
end
local lines = {'HB selected-save identity probe v2; bounded/direct lookup; never traverses the whole UI.'}
local function record(message)
    if message == marker then return end
    marker = message
    lines[#lines + 1] = message
    while #lines > 45 do table.remove(lines,2) end
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, OUTPUT, table.concat(lines, '\n')..'\n')
    end
end
record('Loaded client identity probe. UI available='..tostring(Ext.UI and Ext.UI.GetRoot ~= nil))
if not (Ext.UI and Ext.UI.GetRoot and Ext.Events and Ext.Events.Tick) then return end
local names = {
    'LoadGame', 'HB_SaveTitles_LoadGame', 'SaveGame', 'HB_SaveTitles_SaveGame',
    'LoadGame_c', 'HB_SaveTitles_LoadGame_c', 'SaveGame_c', 'HB_SaveTitles_SaveGame_c',
}
local function pageKind(node)
    local name = tostring(read(node,'Name') or '')
    if name == 'LoadGame' or name == 'SaveGame' or
        name == 'HB_SaveTitles_LoadGame' or name == 'HB_SaveTitles_SaveGame' or
        name == 'LoadGame_c' or name == 'SaveGame_c' or
        name == 'HB_SaveTitles_LoadGame_c' or name == 'HB_SaveTitles_SaveGame_c' then
        return name
    end
    local file = tostring(read(node,'FileName') or ''):lower():gsub('\\', '/')
    if file:find('hb_savetitles_loadgame',1,true) then return 'LoadGame' end
    if file:find('hb_savetitles_savegame',1,true) then return 'SaveGame' end
    if file:find('pages/loadgame',1,true) then return 'LoadGame' end
    if file:find('pages/savegame',1,true) then return 'SaveGame' end
    return nil
end
local function findPage()
    local ok, root = pcall(Ext.UI.GetRoot)
    if not ok or root == nil then return nil end
    if Ext.UI.GetByName then
        for _, name in ipairs(names) do
            local success,node = pcall(Ext.UI.GetByName,name)
            if success and node and pageKind(node) and read(node,'IsVisible') ~= false then
                return node
            end
        end
    end
    -- Direct Find for the page name only, NOT a traversal of the UI tree.
    for _, name in ipairs({'LoadGame','SaveGame'}) do
        local found,node = pcall(function() return root:Find(name) end)
        if found and node and pageKind(node) and read(node,'IsVisible') ~= false then return node end
    end
    -- Root -> ContentRoot -> immediate mounted pages, capped at 12.
    local success,content = pcall(function() return root:Find('ContentRoot') end)
    if not success or not content then return nil end
    local count=math.min(tonumber(read(content,'ChildrenCount')) or 0,12)
    for i=0,count do
        local found,node=pcall(function() return content:Child(i) end)
        if found and node and pageKind(node) and read(node,'IsVisible') ~= false then
            return node
        end
    end
    return nil
end
local keys = {
    'Title','SaveID','Difficulty','FileName','Filename','SaveName','SaveFileName',
    'FilePath','SavePath','SaveFilePath','FolderName','SlotID','SaveUUID','UUID',
    'PlaythroughID','PlaythroughId','PlaythroughString','CampaignID','CampaignId',
    'TimeString','PlayTimeString','Time','SaveTime','CreationTime',
    'DateTime','SaveDate','LevelName','IsHonourMode','Type',
}
local function check()
    local page = findPage()
    if not page then
        if active then record('Save/Load page closed') end
        active=false
        return
    end
    active=true
    local dc=read(page,'DataContext')
    local save=read(dc,'SelectedSave')
    local selected=read(dc,'SelectedPlaythrough')
    local out={'Page='..tostring(pageKind(page)),
               'CurrentPlaythroughID='..scalar(read(dc,'CurrentPlaythroughID')),
               'SelectedPlaythrough.PlaythroughString='..scalar(read(selected,'PlaythroughString'))}
    if save then
        for _,key in ipairs(keys) do
            local val=read(save,key)
            if val ~= nil then out[#out+1]='Save.'..key..'='..scalar(val) end
        end
    else
        out[#out+1]='SelectedSave=nil'
    end
    record(table.concat(out,' | '))
end
Ext.Events.Tick:Subscribe(function()
    if busy then return end
    local now=(Ext.Timer and Ext.Timer.MonotonicTime and Ext.Timer.MonotonicTime()) or 0
    if now<lastTick then lastTick=now end
    if now-lastTick<(active and 700 or 1300) then return end
    lastTick=now
    busy=true
    local function finish()
        local ok,err=pcall(check)
        busy=false
        if not ok then record('Direct lookup failed (no UI changes): '..scalar(err)) end
    end
    if Ext.UI.Defer then
        local ok=pcall(Ext.UI.Defer,finish)
        if not ok then finish() end
    else
        finish()
    end
end)
