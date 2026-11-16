-- HomeBrew: main-menu Continue difficulty display (native template lookup).
-- Honour/Single Save makes the game's MainMenu ControlTemplate replace
-- SelectedSave.Difficulty with the Honour label. Correct ONLY the live
-- TextBlock in that template; leave the save VM and every save/load page alone.
-- No widget scans during a loaded gameplay session.
if _G.HB_MainMenuContinueDifficultyLoaded then return end
_G.HB_MainMenuContinueDifficultyLoaded = true
if not (Ext.UI and Ext.UI.GetRoot and Ext.UI.Defer and Ext.Events
    and Ext.Events.Tick and Ext.Timer and Ext.Timer.MonotonicTime) then return end

local PAGE = {MainMenu=true, MainMenu_c=true}
local INDEX = {explorer='Explorer', adventurer='Adventurer', veteran='Veteran',
    heroic='Heroic', mythic='Mythic', deific='Deific', custom='Custom'}
local ASSETS = {difficulty_01='Explorer', difficulty_02='Adventurer',
    difficulty_03='Veteran', difficulty_04='Custom',
    difficulty_05='Heroic', difficulty_06='Mythic', difficulty_07='Deific'}
local PATH = 'HomeBrew/Diagnostics/HB_MainMenuContinue_Diagnostics.txt'
local inMenu, queued, nextCheck = true, false, 0
local lastDiagnostic, logCount = nil, 0
local lines = {'Main-menu Continue difficulty v4 (localized save value, native template child)'}

local function read(o, key)
    if o == nil then return nil end
    local ok, value = pcall(function() return o[key] end)
    if ok then return value end
end
local function try(o, method, ...)
    if o == nil then return nil end
    local args={...}
    local ok, result = pcall(function() return o[method](o, table.unpack(args)) end)
    if ok then return result end
end
local function name(o)
    local value = read(o, 'Name')
    return type(value)=='string' and value or ''
end
local function nameOfPage(o)
    if PAGE[name(o)] then return name(o) end
    local filename = read(o, 'FileName')
    if type(filename) ~= 'string' then return nil end
    local base = filename:gsub('\\','/'):match('([^/]+)%.xaml$')
    if PAGE[base] then return base end
end
local function active(o)
    return o ~= nil and read(o, 'IsVisible') ~= false
end
local function mountedMenu()
    local root = Ext.UI.GetRoot()
    if not root then return nil end
    local content = try(root,'Find','ContentRoot') or read(root,'ContentRoot')
    if content then
        local count = math.min(tonumber(read(content,'ChildrenCount')) or 0, 24)
        for i=0,count do
            local child=try(content,'Child',i)
            if active(child) and nameOfPage(child) then
                return child, 'ContentRoot:Child('..i..')'
            end
        end
    end
    for _,n in ipairs({'MainMenu','MainMenu_c'}) do
        local child
        if Ext.UI.GetByName then
            local ok,v=pcall(Ext.UI.GetByName,n)
            if ok then child=v end
        end
        if active(child) and nameOfPage(child) then return child,'GetByName' end
        child=try(root,'Find',n)
        if active(child) and nameOfPage(child) then return child,'root:Find' end
    end
end

local function knownName(value)
    if type(value)~='string' or #value>128 then return nil end
    local s=value:match('^%s*(.-)%s*$')
    local lower=s:lower()
    if INDEX[lower] then return INDEX[lower] end
    if ASSETS[lower] then return ASSETS[lower] end
    -- Boundaries allow "Mythic - HellBrew" but reject arbitrary substrings.
    for id,v in pairs(INDEX) do
        if lower:sub(1,#id)==id then
            local rest=lower:sub(#id+1)
            if rest:match('^%s+[%(%-%:]') then return v end
        end
    end
end
local function scalar(value)
    if value==nil then return 'nil' end
    if type(value)=='string' then
        return string.format('%q',value:sub(1,120))
    end
    return '('..type(value)..')'
end

-- SelectedSave.Difficulty is ordinarily a localized *handle*, NOT the
-- rendered difficulty name. Let the game's localization table resolve it.
-- Do not assume IsHonourMode means Heroic: Mythic/Deific can be Single Save.
local function resolveDifficulty(raw)
    local value=knownName(raw)
    if value then return value, nil end
    for _,field in ipairs({'Handle','Str','Text','Value'}) do
        local candidate=read(raw,field)
        value=knownName(candidate)
        if value then return value, nil end
    end
    local handle=type(raw)=='string' and raw
        or read(raw,'Handle') or read(raw,'Str')
    if type(handle)=='string' and #handle<140 and Ext.Loca
        and Ext.Loca.GetTranslatedString then
        local ok, translated=pcall(Ext.Loca.GetTranslatedString, handle)
        if ok then
            value=knownName(translated)
            if value then return value, translated end
            return nil, translated
        end
        return nil, '(localization threw)'
    end
    return nil, '(translation unavailable)'
end

-- The native MainMenu.xaml / MainMenu_c.xaml defines Difficulty inside
-- UIWidget.Template (ControlTemplate). Its namescope is NOT reachable with
-- widget:Find('Difficulty') nor a shallow visual-child traversal.
-- Noesis FrameworkElement.GetTemplateChild and FrameworkTemplate.FindName
-- explicitly resolve names in the instantiated ControlTemplate.
local function difficultyControl(menu)
    local node=try(menu,'GetTemplateChild','Difficulty')
    if node and read(node,'Text')~=nil then return node, 'GetTemplateChild' end
    local template=read(menu,'Template') or try(menu,'GetFrameworkTemplate')
    if template then
        node=try(template,'FindName','Difficulty',menu)
        if node and read(node,'Text')~=nil then return node,'Template:FindName(instance)' end
        node=try(template,'FindName','Difficulty')
        if node and read(node,'Text')~=nil then return node,'Template:FindName' end
    end
    local root=try(menu,'GetTemplateRoot')
    if root then
        node=try(root,'Find','Difficulty') or try(root,'FindName','Difficulty')
        if node and read(node,'Text')~=nil then return node,'TemplateRoot' end
    end
    node=try(menu,'Find','Difficulty') or try(menu,'FindName','Difficulty')
    if node and read(node,'Text')~=nil then return node,'direct' end
    -- Never replace MCM's MainMenu XAML or perform an unrestricted UI walk.
    return nil,'not in applied template (Template='..tostring(template~=nil)
        ..'; GetTemplateChild='..tostring(read(menu,'GetTemplateChild')~=nil)
        ..'; templateRoot='..tostring(root~=nil)..')'
end
local function note(message)
    if message==lastDiagnostic then return end
    lastDiagnostic=message
    logCount=logCount+1
    if logCount>8 then return end
    lines[#lines+1]=message
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, PATH, table.concat(lines,'\n')..'\n')
    end
end
local function refresh()
    if not inMenu then return end
    local menu, route=mountedMenu()
    if not menu then return end
    local save=read(read(menu,'DataContext'),'SelectedSave')
    if not save then return end
    local raw=read(save,'Difficulty')
    local intended,translated=resolveDifficulty(raw)
    if not intended then
        note('UNRESOLVED raw='..scalar(raw)..' translated='..scalar(translated)
            ..' honour='..tostring(read(save,'IsHonourMode'))..'; '..route)
        return
    end
    local label,source=difficultyControl(menu)
    if not label then
        note('CONTROL_NOT_FOUND resolved='..intended..' raw='..scalar(raw)
            ..' translated='..scalar(translated)..'; '..route..'; '..source)
        return
    end
    local before=read(label,'Text')
    if before==intended then return end
    local ok,err=pcall(function() label.Text=intended end)
    local after=read(label,'Text')
    if not ok or after~=intended then
        note('WRITE_FAILED resolved='..intended..' raw='..scalar(raw)
            ..' before='..scalar(before)..' after='..scalar(after)
            ..' source='..source..' err='..tostring(err))
    end
end
if Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function() inMenu=false end)
end
if Ext.Events.GameStateChanged then
    Ext.Events.GameStateChanged:Subscribe(function(event)
        local state=tostring(read(event,'ToState') or '')
        if state=='MainMenu' or state=='UnloadSession' or state=='UnloadModule'
            or state=='Disconnect' or state=='LoadModule' then
            inMenu=true
            nextCheck=0
        end
    end)
end
Ext.Events.Tick:Subscribe(function()
    if not inMenu or queued then return end
    local now=Ext.Timer.MonotonicTime()
    if now<nextCheck then return end
    nextCheck=now+1100
    queued=true
    local ok=pcall(Ext.UI.Defer,function()
        queued=false
        local success,err=pcall(refresh)
        if not success then note('REFRESH_ERROR '..tostring(err)) end
    end)
    if not ok then queued=false end
end)
