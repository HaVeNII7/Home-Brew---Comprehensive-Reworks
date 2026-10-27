-- Optional HomeBrew Save/Load MCM preset suffix (experimental).
-- Disabled old SaveLoadDiagnostics.lua remains disabled. The index is built
-- externally from actual .lsv ModVars, never inferred from the current MCM.
-- No in-game save-file reads, writes, gameplay state changes, or UI walks.
if _G.HB_SavePresetLabelLoaded then return end
_G.HB_SavePresetLabelLoaded=true
if not (Ext.UI and Ext.UI.GetRoot and Ext.Events and Ext.Events.Tick) then return end
local INDEX='HomeBrew/SaveDifficultyIndex_V1.json'
local choices={
    ['Default']=true,['Hard']=true,['Very Hard']=true,['Ultra Hard']=true,
    ['HellBrew']=true,['Expanded Party Size (Default)']=true,
    ['Expanded Party Size (Hard)']=true,['Expanded Party Size (Raid)']=true,
    ['Maximum Difficulty']=true,['Endurance']=true,['Custom']=true,
}
local entries, nextRead={},0
local isOpen, nextTick, busy=false,0,false
local function read(o,name)
    if o==nil then return nil end
    local ok,result=pcall(function() return o[name] end)
    if ok then return result end
end
local function stringScalar(x)
    if type(x)~='string' and type(x)~='number' then return nil end
    local value=tostring(x)
    if #value>220 or value:find('[\r\n]') then return nil end
    return value
end
local function getPage()
    for _,name in ipairs({'LoadGame','SaveGame','LoadGame_c','SaveGame_c',
        'HB_SaveTitles_LoadGame','HB_SaveTitles_SaveGame',
        'HB_SaveTitles_LoadGame_c','HB_SaveTitles_SaveGame_c'}) do
        if Ext.UI.GetByName then
            local ok,widget=pcall(Ext.UI.GetByName,name)
            if ok and widget and read(widget,'IsVisible')~=false then
                return widget
            end
        end
    end
    local ok,root=pcall(Ext.UI.GetRoot)
    if not ok or not root then return nil end
    for _,name in ipairs({'LoadGame','SaveGame','LoadGame_c','SaveGame_c'}) do
        local found,node=pcall(function() return root:Find(name) end)
        if found and node and read(node,'IsVisible')~=false then return node end
    end
    return nil -- intentionally no full visual-tree traversal
end
local function loadIndex()
    entries={}
    if not (Ext.IO and Ext.IO.LoadFile and Ext.Json and Ext.Json.Parse) then return end
    local ok,text=pcall(Ext.IO.LoadFile,INDEX)
    if not ok or type(text)~='string' or #text>3*1024*1024 then return end
    local parsed,obj=pcall(Ext.Json.Parse,text)
    if not parsed or type(obj)~='table' or obj.Version~=1
        or type(obj.Entries)~='table' or #obj.Entries>2000 then return end
    for _,entry in ipairs(obj.Entries) do
        if type(entry)=='table' and type(entry.Title)=='string'
            and type(entry.SaveID)=='number'
            and type(entry.TimeStrings)=='table'
            and #entry.TimeStrings>=1 and #entry.TimeStrings<=24
            and (entry.Preset==nil or choices[entry.Preset]) then
            entries[#entries+1]=entry
        end
    end
end
local function playtimeMinutes(value)
    local s=stringScalar(value)
    if not s then return nil end
    local h,m=s:match('^(%d+)h%s*(%d+)m$')
    if h and m then return tonumber(h)*60+tonumber(m) end
    return nil -- unrecognized rendering fails closed
end
local function matchingPreset(save)
    if not save then return nil end
    local title=stringScalar(read(save,'Title'))
    local id=tonumber(read(save,'SaveID'))
    local time=stringScalar(read(save,'TimeString'))
    local minutes=playtimeMinutes(read(save,'PlayTimeString'))
    if not title or id==nil or not time or minutes==nil then return nil end
    -- Compare every indexed save, INCLUDING saves without HomeBrew variables;
    -- a collision with an older/foreign save must never borrow a preset.
    local found,preset=0,nil
    for _,e in ipairs(entries) do
        if e.Title==title and e.SaveID==id and e.PlayMinutes==minutes then
            for _,candidate in ipairs(e.TimeStrings) do
                if candidate==time then
                    found=found+1
                    preset=e.Preset
                    break
                end
            end
        end
    end
    if found==1 and choices[preset] then return preset end
    return nil
end
local function findSuffix(page)
    local ok,suffix=pcall(function() return page:Find('HB_PresetSuffix') end)
    if ok and suffix then return suffix end
end
local function update()
    local page=getPage()
    if not page then isOpen=false;return end
    isOpen=true
    local now=(Ext.Timer and Ext.Timer.MonotonicTime and Ext.Timer.MonotonicTime()) or 0
    if now>=nextRead then
        nextRead=now+8000
        loadIndex()
    end
    local save=read(read(page,'DataContext'),'SelectedSave')
    local suffix=findSuffix(page)
    if not suffix then return end -- don't touch native BG3 Difficulty binding
    local preset=matchingPreset(save)
    local desired=preset and (' - '..preset) or ''
    if read(suffix,'Text')~=desired then suffix.Text=desired end
end
loadIndex()
Ext.Events.Tick:Subscribe(function()
    if busy then return end
    local now=(Ext.Timer and Ext.Timer.MonotonicTime and Ext.Timer.MonotonicTime()) or 0
    if now<nextTick then nextTick=now end
    if now<nextTick then return end
    nextTick=now+(isOpen and 750 or 1800)
    busy=true
    local function run()
        local okay=pcall(update)
        busy=false
        -- Deliberately no UI debugging or repeating error log on failures.
        -- The XAML TextBlocks remain empty when the index is unavailable.
    end
    if Ext.UI.Defer then
        local ok=pcall(Ext.UI.Defer,run)
        if not ok then run() end
    else run() end
end)
