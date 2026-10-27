-- HomeBrew character-creation Guardian handoff audit (read-only).
-- No UI mutation, game commands, entity writes, or deferred actions.
-- Activated only while the native character-creation UI is mounted.
local REPORT = 'HomeBrew/Diagnostics/HB_GuardianTransition_Diagnostics.txt'
local lines = {'HomeBrew Guardian transition probe v1 (read only). Capture this file immediately after a stuck Guardian screen.'}
local lastSignature, lastEntitySummary, active, lastProbe, lastEntityProbe, lastHeartbeat = nil, nil, false, -10000, -10000, -10000
local lastSeen, lastClosedAt = nil, nil
local bootTime = Ext.Timer.MonotonicTime()

local function Read(obj, key)
    if not obj then return nil end
    local ok, value = pcall(function() return obj[key] end)
    if ok then return value end
    return nil
end
local function Label(value, depth)
    depth=depth or 0
    if depth>=3 then return '<native>' end
    if value == nil then return '-' end
    if type(value) == 'boolean' or type(value) == 'number' or type(value) == 'string' then
        return tostring(value):gsub('[\r\n]+', ' '):sub(1,120)
    end
    -- Do not retain native proxies or use their volatile addresses in signatures.
    local content = Read(value,'Content')
    if content~=nil and content~=value then return Label(content,depth+1) end
    local name = Read(value,'Name')
    if name~=nil and name~=value then return Label(name,depth+1) end
    local ok, text = pcall(tostring,value)
    if ok and type(text)=='string' and #text<65 and not text:find('0x',1,true) then return text end
    return '<native>'
end
local function FileLabel(node)
    local file=Read(node,'FileName')
    if type(file)=='string' then return (file:gsub('\\','/'):match('([^/]+)%.xaml$') or file) end
    return Label(Read(node,'Name'))
end
local function Find(root, name)
    if not root then return nil end
    local ok,result=pcall(function() return root:Find(name) end)
    return ok and result or nil
end
local function Child(node,index)
    local ok, value=pcall(function() return node:Child(index) end)
    return ok and value or nil
end
local function write(now,text)
    local elapsed=math.floor((now-bootTime)/1000)
    lines[#lines+1]=string.format('[+%ds] %s', elapsed,text)
    if #lines>190 then table.remove(lines,2) end
    pcall(function() Ext.IO.SaveFile(REPORT,table.concat(lines,'\n')..'\n') end)
end
local function pageSummary(page,host)
    local native=Read(page,'DataContext')
    local step=Label(Read(native,'CharacterCreationStep'))
    local flow=Find(page,'flowPage')
    local selected=Read(flow,'SelectedItem')
    local flowName=Label(Read(selected,'Content'))
    if flowName=='-' then flowName=Label(selected) end
    local naming=Find(page,'namingPageButtons')
    local title=Find(page,'namingPage')
    local player=Read(native,'CurrentPlayer')
    local playerUI=Read(player,'UIData')
    local hostVM=Read(host,'DataContext')
    local description={
        'page='..FileLabel(page),
        'pageVisible='..Label(Read(page,'IsVisible')),
        'vmType='..Label(Read(native,'Type')),
        'initialized='..Label(Read(native,'IsInitialized')),
        'creation='..Label(Read(native,'IsCreation')),
        'locked='..Label(Read(native,'IsLocked')),
        'creationStep='..step,
        'flow='..flowName,
        'flowIndex='..Label(Read(flow,'SelectedIndex')),
        'namingButtons='..Label(Read(naming,'IsVisible')),
        'namingPage='..Label(Read(title,'IsVisible')),
        'playerMode='..Label(Read(playerUI,'CharacterCreationMode')),
        'originLocked='..Label(Read(Read(native,'SelectedOrigin'),'IsLockedAppearance')),
        'presetHost='..tostring(host~=nil),
        'presetVisible='..Label(Read(hostVM,'HB_Visible')),
        'presetOpen='..Label(Read(hostVM,'HB_Open')),
        'gearVisible='..Label(Read(hostVM,'HB_Gear_Visible')),
        'gearOpen='..Label(Read(hostVM,'HB_Gear_Open')),
        'footerEnabled='..Label(Read(hostVM,'HB_FooterEnabled')),
    }
    return table.concat(description,' ')
end
local function EntitySummary()
    if not Ext.Entity or type(Ext.Entity.GetAllEntitiesWithComponent)~='function' then return 'entityAPI=unavailable' end
    local function Entities(name)
        local ok, value=pcall(Ext.Entity.GetAllEntitiesWithComponent,name)
        return ok and type(value)=='table' and value or {}
    end
    local roots,definitions=Entities('CCCreation'),Entities('CCCharacterDefinition')
    local output={'CCCreation='..#roots,'CCCharacterDefinition='..#definitions}
    if #roots==1 then
        local ok, root=pcall(function() return roots[1]:GetComponent('CCCreation') end)
        local ref=ok and Read(root,'CharacterDefinitions') or nil
        output[#output+1]='rootDefCount='..Label(Read(ref,'Size') or Read(ref,'Length'))
        output[#output+1]='rootFirstDef='..tostring(Read(ref,1)~=nil)
    end
    for i=1,math.min(#definitions,3) do
        local entity=definitions[i]
        local ok,component=pcall(function() return entity:GetComponent('ClientCCDummyDefinition') end)
        local dummy=ok and Read(component,'Dummy') or nil
        local reference=Read(component,'field_18_Map_unk_FS')
        output[#output+1]='def'..i..':dummyRef='..tostring(dummy~=nil)..',equipmentMap='..tostring(reference~=nil)
        if dummy then
            local dummyObj=dummy
            local hasMethod=pcall(function() return dummy:GetComponent('Stats') end)
            if not hasMethod then
                local available,got=pcall(Ext.Entity.Get,dummy)
                if available then dummyObj=got end
            end
            local found,stats=pcall(function() return dummyObj and dummyObj:GetComponent('Stats') end)
            local foundVisual,visual=pcall(function() return dummyObj and dummyObj:GetComponent('CharacterVisual') end)
            output[#output+1]='def'..i..':dummyResolved='..tostring(dummyObj~=nil)
                ..',stats='..tostring(found and stats~=nil)..',visual='..tostring(foundVisual and visual~=nil)
        end
    end
    return table.concat(output,' ')
end
local function Probe(now)
    local ok,root=pcall(Ext.UI.GetRoot)
    if not ok or not root then return false,'UIRoot=missing' end
    local content=Find(root,'ContentRoot')
    if not content then return false,'ContentRoot=missing' end
    local count=math.min(tonumber(Read(content,'ChildrenCount')) or 0,110)
    local pages,hosts,other={}, {}, {}
    for i=1,count do
        local node=Child(content,i)
        if node and Read(node,'IsVisible')~=false then
            local name=FileLabel(node)
            if name=='CharacterCreation' or name=='CharacterCreation_c' then
                pages[#pages+1]=node
            elseif name=='HB_VisualPresets' then
                hosts[#hosts+1]=node
            elseif name:find('Character',1,true) or name:find('Guardian',1,true) or name:find('Naming',1,true) then
                other[#other+1]=name
            end
        end
    end
    if #pages==0 then return false,'creationPage=0 presetHosts='..#hosts..' other='..table.concat(other,',') end
    local parts={'creationPages='..#pages,'presetHosts='..#hosts}
    for i=1,math.min(#pages,2) do parts[#parts+1]=pageSummary(pages[i],hosts[1]) end
    if #other>0 then parts[#parts+1]='other='..table.concat(other,',') end
    return true, table.concat(parts,' | ')
end
Ext.Events.Tick:Subscribe(function()
    local now=Ext.Timer.MonotonicTime()
    if now-lastProbe<750 then return end
    lastProbe=now
    local ok,isOpen,summary=pcall(Probe,now)
    if not ok then
        if active and (lastSignature~= 'ERROR:'..tostring(isOpen) or now-lastHeartbeat>5000) then
            write(now,'PROBE_ERROR '..tostring(isOpen));lastHeartbeat=now;lastSignature='ERROR:'..tostring(isOpen)
        end
        return
    end
    if isOpen then
        lastSeen=now
        lastClosedAt=nil
        if not active then
            active=true;write(now,'CREATION_UI_ENTERED')
            lastSignature=nil
            lastEntityProbe=-10000
        end
        if summary~=lastSignature then
            lastSignature=summary;write(now,'UI_CHANGE '..summary);lastHeartbeat=now
        elseif now-lastHeartbeat>=4000 then
            write(now,'UI_STILL '..summary);lastHeartbeat=now
        end
        if now-lastEntityProbe>=2400 then
            lastEntityProbe=now
            local got,entities=pcall(EntitySummary)
            if not got then entities='ENTITY_ERROR '..tostring(entities) end
            if entities~=lastEntitySummary then
                lastEntitySummary=entities;write(now,'ENTITY_CHANGE '..entities)
            elseif now-lastHeartbeat<1100 then
                write(now,'ENTITY_STILL '..entities)
            end
        end
    elseif active then
        if not lastClosedAt then lastClosedAt=now;write(now,'CREATION_UI_UNSEEN '..summary) end
        if now-lastClosedAt>=5000 then
            write(now,'CREATION_UI_EXITED '..summary)
            active=false;lastSignature=nil;lastEntitySummary=nil;lastClosedAt=nil
        end
    end
end)
