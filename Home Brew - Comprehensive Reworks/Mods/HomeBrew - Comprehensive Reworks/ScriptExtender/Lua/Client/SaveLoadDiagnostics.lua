-- Read-only inspection: no command handlers or native data contexts are replaced.
local FILE='HomeBrew/Diagnostics/HB_SaveLoad_Diagnostics.txt'
local lines={'HB saved-game menu diagnostics v50'}
local previous,nextCheck,queued='',0,false
local function Read(o,k)
    if not o then return nil end
    local ok,v=pcall(function()return o[k]end)
    if ok then return v end
    return nil
end
local function Record(s)
    if s==previous then return end
    previous=s;lines[#lines+1]=s
    while #lines>50 do table.remove(lines,2)end
    pcall(Ext.IO.SaveFile,FILE,table.concat(lines,'\n'))
end
Record('Started; waiting for Load Game. UI API='..tostring(Ext.UI and Ext.UI.GetRoot~=nil))
if not Ext.UI or not Ext.UI.GetRoot then return end
-- Diagnostic-only: do not traverse thousands of HUD controls every second
-- while there is no Save/Load page. This probe never controls saves.
local function VisibleSaveOrLoad()
    local root=Ext.UI.GetRoot()
    if not root then return false end
    local function Live(node)
        return node and Read(node,'IsVisible')~=false
    end
    local names={'SaveGame','SaveGame_c','LoadGame','LoadGame_c',
        'HB_SaveTitles_SaveGame','HB_SaveTitles_SaveGame_c',
        'HB_SaveTitles_LoadGame','HB_SaveTitles_LoadGame_c'}
    for _,name in ipairs(names) do
        if Ext.UI.GetByName then
            local ok,node=pcall(Ext.UI.GetByName,name)
            if ok and Live(node) then return true end
        end
        local ok,node=pcall(function()return root:Find(name) end)
        if ok and Live(node) then return true end
    end
    local content=Read(root,'ContentRoot')
    if not content then
        local ok,node=pcall(function()return root:Find('ContentRoot')end)
        if ok then content=node end
    end
    local count=math.min(tonumber(Read(content,'ChildrenCount')) or 0,100)
    for i=1,count do
        local ok,child=pcall(function()return content:Child(i)end)
        if ok and Live(child) then
            local file=tostring(Read(child,'FileName') or ''):lower():gsub('\\','/')
            if file:find('pages/savegame',1,true) or file:find('pages/loadgame',1,true)
                or file:find('pages/hb_savetitles_savegame',1,true)
                or file:find('pages/hb_savetitles_loadgame',1,true) then return true end
        end
    end
    return false
end
local function Scan()
    local found,inventory,visited,queue={}, {}, {}, {Ext.UI.GetRoot()}
    local index=1
    while index<=#queue and index<=8000 do
        local node=queue[index];index=index+1
        if node and not visited[node] then
            visited[node]=true
            local name=Read(node,'Name')
            local filename=Read(node,'FileName')
            local dc=Read(node,'DataContext')
            local kind=tostring(Read(dc,'Type'))
            local label=tostring(name)..' ['..tostring(filename)..']; visible='..tostring(Read(node,'IsVisible'))
            local candidate=(tostring(name)..' '..tostring(filename)..' '..kind):lower()
            if (filename or (name and name~='')) and #inventory<90 then inventory[#inventory+1]=label end
            if candidate:find('loadgame',1,true) or candidate:find('savegames',1,true)
                or name=='LoadSaveBtn' or name=='PlaythroughSavegames' then
                local details={label..'; context='..kind}
                for _,k in ipairs({'DoLoad','UseSavefileCommand','ShowModValidationWindow','RefreshSaveGames','IsSaving','IsMainMenu','CurrentPlaythroughID'}) do
                    details[#details+1]=k..'='..tostring(Read(dc,k))
                end
                details[#details+1]='ControlEnabled='..tostring(Read(node,'IsEnabled'))
                details[#details+1]='HitTest='..tostring(Read(node,'IsHitTestVisible'))
                details[#details+1]='Command='..tostring(Read(node,'Command'))
                local save=Read(dc,'SelectedSave')
                details[#details+1]='SelectedSave='..tostring(save)
                for _,k in ipairs({'Title','SaveID','Validity','Type','IsHonourMode','CloudStatus','CrossStatus'}) do
                    details[#details+1]='Save.'..k..'='..tostring(Read(save,k))
                end
                if #found<30 then found[#found+1]=table.concat(details,'; ') end
            end
            for _,pair in ipairs({{'ChildrenCount','Child'},{'VisualChildrenCount','VisualChild'}}) do
                for i=1,(Read(node,pair[1]) or 0) do
                    local ok,child=pcall(function()return node[pair[2]](node,i)end)
                    if ok and child and not visited[child] and #queue<12000 then queue[#queue+1]=child end
                end
            end
        end
    end
    Record('Inspected '..(index-1)..' nodes; queued '..#queue..'\n'
        ..(#found>0 and table.concat(found,'\n') or 'No load screen match; UI inventory:\n'..table.concat(inventory,'\n')))

end
Ext.Events.Tick:Subscribe(function()
    local now=Ext.Timer.MonotonicTime()
    if queued or now<nextCheck then return end
    nextCheck=now+1000
    if not VisibleSaveOrLoad() then return end
    queued=true
    local function Run()
        queued=false
        local ok,err=pcall(Scan)
        if not ok then Record('Inspection error: '..tostring(err))end
    end
    if Ext.UI.Defer then Ext.UI.Defer(Run) else Run()end
end)
