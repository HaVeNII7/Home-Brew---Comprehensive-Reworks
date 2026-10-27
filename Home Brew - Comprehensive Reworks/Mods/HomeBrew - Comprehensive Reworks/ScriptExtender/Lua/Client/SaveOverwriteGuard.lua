-- HomeBrew cross-campaign save protection. This script never edits a save or
-- sends a save command: it only unlocks the native Overwrite control after
-- the game reports matching, verifiable playthrough identifiers.
if _G.HB_SaveOverwriteGuardLoaded then return end
_G.HB_SaveOverwriteGuardLoaded=true
if not Ext.UI or not Ext.UI.GetRoot or not Ext.Events or not Ext.Events.Tick then return end

local last, nextScan, busy, lastLog=nil,0,false,nil
local savePageActive=false
local function Read(o,k)
    if not o then return nil end
    local ok,v=pcall(function() return o[k] end)
    return ok and v or nil
end
-- SaveGame.xaml itself compares CurrentPlaythroughID with PlaythroughString.
-- These are BG3's *playthrough keys*, not necessarily canonical GUID text.
-- Do not parse substrings as GUIDs, accept a save-slot ID or guess via the
-- protagonist name: compare only those two exact native campaign values.
local function CampaignKey(value)
    if value==nil then return nil end
    local kind=type(value)
    if kind~='string' and kind~='userdata' then return nil end
    local s=tostring(value)
    if s=='' or s:find('[\r\n]') or s:find('^%s*$') then return nil end
    if #s<8 or #s>256 or s:match('^0[xX]%x+$') or
        s:match('^userdata:') or s:match('^table:') or s:match('^gui::') then
        return nil
    end
    -- Native equality uses the full key, not a GUID fragment; avoid
    -- substring collisions and treat casing as significant.
    return s
end
local function Find(widget,name)
    if not widget then return nil end
    local ok,v=pcall(function() return widget:Find(name) end)
    if ok and v then return v end
    return nil
end
local function Children(widget)
    local items,seen={},{}
    for _,spec in ipairs({{'ChildrenCount','Child'},{'VisualChildrenCount','VisualChild'}}) do
        local n=math.min(tonumber(Read(widget,spec[1])) or 0,150)
        for i=0,n do
            local ok,child=pcall(function() return widget[spec[2]](widget,i) end)
            if ok and child and not seen[child] then
                seen[child]=true;items[#items+1]=child
            end
        end
    end
    return items
end
local function Walk(widget,limit)
    local queue={widget};local seen={};local result={}
    local i=1
    while i<=#queue and i<=(limit or 2800) do
        local node=queue[i];i=i+1
        if node and not seen[node] then
            seen[node]=true;result[#result+1]=node
            for _,child in ipairs(Children(node)) do
                if #queue<(limit or 2800) then queue[#queue+1]=child end
            end
        end
    end
    return result
end
local function FindDeep(widget,name)
    local found=Find(widget,name)
    if found then return found end
    for _,child in ipairs(Walk(widget,2500)) do
        if tostring(Read(child,'Name') or '')==name then return child end
    end
end
-- The Save UI is not present during gameplay. Never walk the entire live
-- Noesis tree simply to discover that no save dialog exists. BG3 mounts these
-- pages under ContentRoot, and its native direct lookups can find them cheaply.
local SAVE_NAMES={'SaveGame','SaveGame_c','HB_SaveTitles_SaveGame','HB_SaveTitles_SaveGame_c'}
local function IsSavePage(node)
    if not node or Read(node,'IsVisible')==false then return false end
    local name=tostring(Read(node,'Name') or '')
    for _,expected in ipairs(SAVE_NAMES) do
        if name==expected then return true end
    end
    local file=tostring(Read(node,'FileName') or ''):gsub('\\','/'):lower()
    return file:match('pages/savegame[_%.]')~=nil
        or file:match('pages/hb_savetitles_savegame[_%.]')~=nil
end
local function SaveWidget()
    local root=Ext.UI.GetRoot()
    if not root then return nil end
    for _,name in ipairs(SAVE_NAMES) do
        if Ext.UI.GetByName then
            local ok,node=pcall(Ext.UI.GetByName,name)
            if ok and IsSavePage(node) then return node end
        end
        local found=Find(root,name)
        if IsSavePage(found) then return found end
    end
    local content=Find(root,'ContentRoot') or Read(root,'ContentRoot')
    -- Only visit direct mounted content pages, not descendants of the
    -- entire HUD/inventory/dialog tree. A missed page fails closed because
    -- native overwrite controls are initially disabled in XAML.
    if content then
        for _,node in ipairs(Children(content)) do
            if IsSavePage(node) then return node end
        end
    end
    return nil
end
local function CurrentId(dc)
    -- CurrentPlaythroughID is explicitly compared to PlaythroughString by
    -- BG3's own playthrough expander triggers in SaveGame.xaml.
    for _,field in ipairs({'CurrentPlaythroughID','CurrentPlaythroughId'}) do
        local value=CampaignKey(Read(dc,field))
        if value then return value,field end
    end
    return nil,'current playthrough key unavailable'
end
-- Noesis/C++ collections are not always Lua-indexable with [i].
-- Resolve items through available native accessors, including zero- and
-- one-based implementations; never infer ownership from names.
local function Enumerate(collection)
    if not collection then return {} end
    local n=tonumber(Read(collection,'Count'))
    if n==nil then pcall(function() n=#collection end) end
    if not n or n<0 or n>2000 then return {} end
    local values,seen={},{}
    local function Append(v)
        if v and not seen[v] then seen[v]=true;values[#values+1]=v end
    end
    for i=0,n do
        Append(Read(collection,i))
        for _,method in ipairs({'Get','GetItem','Item','At'}) do
            local ok,v=pcall(function() return collection[method](collection,i) end)
            if ok then Append(v) end
        end
    end
    return values
end
local function SameSave(left,right)
    if left==nil or right==nil then return false end
    if left==right then return true end
    -- Identical, nonempty native SaveID identifies a slot. Save names and
    -- timestamps are NOT sufficient because they can repeat across campaigns.
    local a,b=Read(left,'SaveID'),Read(right,'SaveID')
    if a~=nil and b~=nil then
        a,b=tostring(a),tostring(b)
        if #a>=8 and a==b and not a:match('^userdata:') then return true end
    end
    return false
end
local function OwningPlaythrough(dc,save)
    local matches,owner={},nil
    for _,playthrough in ipairs(Enumerate(Read(dc,'ExistingPlaythroughs'))) do
        local key=CampaignKey(Read(playthrough,'PlaythroughString'))
        if key then
            for _,candidate in ipairs(Enumerate(Read(playthrough,'Saves'))) do
                if SameSave(candidate,save) then
                    if not matches[key] then matches[key]=true;owner=playthrough end
                    break
                end
            end
        end
    end
    local count=0
    for _ in pairs(matches) do count=count+1 end
    if count==1 then return owner,'selected save contained in campaign saves' end
    if count>1 then return nil,'save matched more than one campaign' end
    return nil,'selected save owner not found in ExistingPlaythroughs'
end
-- The visible list already has the selected Save and its owning campaign
-- as its DataContext. Reading it avoids relying on a potentially expired
-- ExistingPlaythroughs proxy or on SelectedPlaythrough, which is often nil.
local function RenderedOwner(widget,selected)
    local matches={};local sawList=0
    for _,node in ipairs(Walk(widget,3000)) do
        if tostring(Read(node,'Name') or '')=='PlaythroughSavegames' then
            sawList=sawList+1
            local selectedItem=Read(node,'SelectedItem')
            -- Only trust the exact selected slot. The visual list for another
            -- campaign can coexist in the UI and must not authorize overwrite.
            if SameSave(selectedItem,selected) then
                local key=CampaignKey(Read(Read(node,'DataContext'),'PlaythroughString'))
                if key then matches[key]=true end
            end
        end
    end
    local count,key=0,nil
    for k in pairs(matches) do count=count+1;key=k end
    if count==1 then return key,'selected native list item; rendered campaign owner' end
    if count>1 then return nil,'ambiguous rendered selected-save owner' end
    return nil,'no matching rendered selected-save list (lists='..sawList..')'
end
local function TargetId(dc,widget)
    local save=Read(dc,'SelectedSave')
    if not save then return nil,'no selected save' end
    local visualKey,visualReason=RenderedOwner(widget,save)
    local playthrough,why=OwningPlaythrough(dc,save)
    local key=CampaignKey(Read(playthrough,'PlaythroughString'))
    if key and visualKey and key~=visualKey then
        return nil,'rendered owner and collection owner disagree'
    end
    local target=key or visualKey
    if not target then
        -- A selected playthrough is a possible owner only when the selected
        -- save is confirmed to belong to its Saves collection.
        local selected=Read(dc,'SelectedPlaythrough')
        local selectedKey=CampaignKey(Read(selected,'PlaythroughString'))
        if selectedKey then
            for _,candidate in ipairs(Enumerate(Read(selected,'Saves'))) do
                if SameSave(candidate,save) then target=selectedKey;break end
            end
        end
    end
    if not target then return nil,(why or 'owner missing')..'; '..visualReason end
    for _,field in ipairs({'PlaythroughID','PlaythroughId','CampaignID','CampaignId'}) do
        local recorded=CampaignKey(Read(save,field))
        if recorded and recorded~=target then
            return nil,'selected save declares a conflicting campaign key'
        end
    end
    return target,key and why or visualReason
end
local function Scan()
    local widget=SaveWidget()
    if not widget then last=nil;savePageActive=false;return end
    savePageActive=true
    local button=FindDeep(widget,'OverwriteSaveBtn') or FindDeep(widget,'OverwriteBtn')
    if not button then
        if last~='overwrite button not found' then
            last='overwrite button not found';pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_SaveOverwriteGuard_Diagnostics.txt',last)
        end
        return
    end
    local dc=Read(widget,'DataContext')
    local current,field=CurrentId(dc)
    local target,why=TargetId(dc,widget)
    -- On controller BG3 reuses OverwriteBtn for the separate NEW SAVE action.
    -- Never disable new-save creation just because no existing slot is selected.
    local focus=Read(dc,'FocusedElement')
    local focusTag=Read(focus,'Tag')
    local newSave=(Read(widget,'Name')=='SaveGame_c' or Read(widget,'Name')=='HB_SaveTitles_SaveGame_c')
        and tostring(focusTag)=='NewSave'
    -- DCSavegames.IsSaving indicates that this is the SAVE screen (instead of
    -- the LOAD screen). It remains true while browsing saved slots, so it must
    -- NOT be interpreted as "save operation in progress". The previous gate
    -- blocked even proven same-campaign overwrites on every normal save screen.
    local allow=newSave or (current~=nil and target~=nil and current==target
        and Read(dc,'SelectedSave')~=nil)
    local status=newSave and 'native new save action' or
        (allow and 'same campaign' or (current and target and 'cross-campaign' or 'identity unavailable'))
    -- XAML initializes these buttons as disabled. Each refresh is rechecked;
    -- when provenance is missing, refuse to authorize an overwrite.
    button.IsEnabled=allow
    button.IsHitTestVisible=allow
    local signature=table.concat({status,tostring(current),tostring(target),tostring(field),tostring(why),
        'SelectedSave='..tostring(Read(dc,'SelectedSave')~=nil),
        'IsSavingMode='..tostring(Read(dc,'IsSaving')),
        'widget='..tostring(Read(widget,'Name')),
        'btnEnabled='..tostring(Read(button,'IsEnabled'))},' | ')
    if signature~=last then
        last=signature
        local detail='HB overwrite guard: '..signature
        pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_SaveOverwriteGuard_Diagnostics.txt',detail)
        if Ext.Utils and Ext.Utils.Print then Ext.Utils.Print('[HB Save] '..detail) end
    end
end
Ext.Events.Tick:Subscribe(function()
    local now=Ext.Timer and Ext.Timer.MonotonicTime and Ext.Timer.MonotonicTime() or 0
    if busy or now<nextScan then return end
    -- No gameplay-wide UI walk: check for an opening dialog about once a
    -- second, and refresh an active save dialog only a few times per second.
    nextScan=now+(savePageActive and 350 or 1100)
    busy=true
    local function Execute()
        local ok,err=pcall(Scan)
        busy=false
        if not ok and tostring(err)~=lastLog then
            lastLog=tostring(err)
            pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_SaveOverwriteGuard_Diagnostics.txt','Guard error (overwrite kept locked): '..lastLog)
        end
    end
    if Ext.UI.Defer then
        local ok=pcall(Ext.UI.Defer,Execute)
        if not ok then Execute() end
    else
        Execute()
    end
end)
