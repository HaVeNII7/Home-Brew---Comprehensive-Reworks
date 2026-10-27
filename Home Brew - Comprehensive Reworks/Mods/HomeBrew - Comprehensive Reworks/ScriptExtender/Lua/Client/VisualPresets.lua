local Data=Ext.Require('Shared/VisualPresetData.lua')
local Gear=Ext.Require('Client/StartingGearMenu.lua')
local Files=Ext.Require('Shared/PresetFiles.lua')
local DIR='HomeBrew/AppearancePresets'
local REPORT='HomeBrew/Diagnostics/HB_VisualPresets_Diagnostics.txt'
local TYPE='HB_VisualPresetMenu_v2'
local ROW='HB_VisualPresetRow_v1'
local presets,storageError={},nil
local nextNumber=1
local raw,revision,queued,nextUpdate=nil,0,false,0
local request,pendingWrite,verification
local state={Mode='',Name='',Selected=-1,Status='',Confirm=false,Notice='',NoticeUntil=0}
local messages={'HomeBrew visual presets v53 - Magic Mirror host + native page discovery'}
local defer=Ext.UI and Ext.UI.Defer
local settledOwner,settledPasses,lastDiscovery=nil,0,nil
local presetPageActive=false
local lastGearVisibility=nil

local function Log(message,context)
    message=tostring(message)
    if messages[#messages]==message and not context then return end
    messages[#messages+1]=message
    if context then
        for _,pair in ipairs(Data.Selections) do
            local selected=Data.Read(context,pair[1])
            if selected then
                local names={};for key in pairs(Data.Properties(selected)) do names[#names+1]=tostring(key) end;table.sort(names)
                messages[#messages+1]=pair[1]..' ('..tostring(Data.Read(selected,'Type'))..'): '..table.concat(names,', ')
            end
        end
    end
    while #messages>100 do table.remove(messages,2) end
    pcall(Ext.IO.SaveFile,REPORT,table.concat(messages,'\n'))
end

local function ChinTrace(context)
    local selected=Data.Read(context,'SelectedChin')
    local options=Data.Read(context,'SelectableChin')
    local nullOptions=0
    for i=1,math.min(Data.Count(options),256) do
        if Data.Read(Data.Read(options,i),'IsNull')==true then nullOptions=nullOptions+1 end
    end
    local id=Data.Identity(selected) or {}
    return 'selected='..(selected==nil and 'nil' or
        (Data.Read(selected,'IsNull')==true and 'IsNull' or 'nonempty'))
        ..'; identity='..tostring(id.Guid or id.UUID or id.Name or id.Text or '?')
        ..'; options='..tostring(Data.Count(options))..'; nullOptions='..tostring(nullOptions)
end

-- Only individual, shareable JSON files are supported. The former
-- randomized-test VisualPresets.json bundle is deliberately not read.
local function LoadIndividual()
    local names,err=Files.Discover(DIR)
    if not names then return false,err end
    local existing,ids,tombstones={},{},{}
    for _,file in ipairs(names) do
        local item=Files.Read(DIR,file)
        if type(item)=='table' and item.Kind=='HomeBrewAppearance'
            and item.Version==1 and item.Deleted==true
            and type(item.Preset)=='table' and type(item.Preset.Name)=='string' then
            tombstones[item.Preset.Name:lower()]=true
        end
        if type(item)=='table' and item.Kind=='HomeBrewAppearance' and
            item.Version==1 and item.Deleted~=true and type(item.Preset)=='table' then
            local p=item.Preset
            local valid=pcall(function()
                Data.CleanName(p.Name)
                assert(type(p.Appearance)=='table' and type(p.Name)=='string')
            end)
            if valid and not existing[p.Name:lower()] then
                if type(p.Id)~='number' or p.Id<1 or p.Id%1~=0 or ids[p.Id] then
                    local available=1
                    while ids[available] do available=available+1 end
                    p.Id=available
                end
                ids[p.Id]=true
                p.File=file
                existing[p.Name:lower()]=p
            end
        end
    end
    local nextList={}
    for _,p in pairs(existing) do nextList[#nextList+1]=p end
    presets=nextList
    return true
end
local discovered,discoveryError=LoadIndividual()
if not discovered then
    -- Fail safely instead of letting saves overwrite unknown shared files.
    storageError=discoveryError or 'Cannot enumerate appearance presets.'
end
Log('Loaded '..#presets..' presets from individual files. '..tostring(Files.LastDiscoveryReport()))

local missing={}
for _,name in ipairs({'GetRoot','RegisterType','Instantiate'}) do
    if not Ext.UI or type(Ext.UI[name])~='function' then missing[#missing+1]='Ext.UI.'..name end
end
if #missing>0 then Log('Preset controls cannot start; missing: '..table.concat(missing,', '));return end
Log(defer and 'Using deferred UI updates.' or 'Using SE32 client-tick UI updates (same scheduling as HB difficulty controls).')

local function Walk(root)
    local pages,hosts,footers,visited,count={},{},{},{},0
    local function Visit(node,depth)
        if not node or depth>65 or count>6500 then return end
        local key=tostring(node)
        if visited[key] then return end
        visited[key]=true;count=count+1
        if Data.Read(node,'IsVisible')==false then return end
        local name=Data.Read(node,'Name')
        if name=='HB_VisualPresets' then hosts[#hosts+1]=node;return end
        if name=='HB_VisualPresetFooter' then footers[#footers+1]=node;return end
        if name=='CharacterCreation' or name=='CharacterCreation_c'
            or name=='CharacterChangeAppearance' or name=='CharacterChangeAppearance_c' then
            pages[#pages+1]=node;return
        end
        for _,pair in ipairs({{'ChildrenCount','Child'},{'VisualChildrenCount','VisualChild'}}) do
            local length=Data.Read(node,pair[1]) or 0
            for index=1,length do
                local got,child=pcall(function() return node[pair[2]](node,index) end)
                if got then Visit(child,depth+1) end
            end
        end
    end
    Visit(root,0)
    local discovery='Appearance editor pages='..#pages..'; preset hosts='..#hosts..'; footer hosts='..#footers
    if discovery~=lastDiscovery then
        lastDiscovery=discovery;Log(discovery)
        if #pages==0 then
            -- Log recognizable top-level pages only, never each tree element.
            local content=Data.Read(root,'ContentRoot')
            if not content and root then
                local ok,found=pcall(function() return root:Find('ContentRoot') end)
                if ok then content=found end
            end
            local count=math.min(40,Data.Read(content,'ChildrenCount') or 0)
            local names={}
            for i=1,count do
                local ok,child=pcall(function() return content:Child(i) end)
                if ok and child then
                    local filename=Data.Read(child,'FileName') or Data.Read(child,'Name')
                    if type(filename)=='string' and
                       (filename:find('Character') or filename:find('Appearance')) then
                        names[#names+1]=filename
                    end
                end
            end
            if #names>0 then Log('Active character/appearance pages: '..table.concat(names,', ')) end
        end
    end
    if #pages~=1 or #hosts~=1 or #footers>1 then return nil,nil,nil end
    return pages[1],hosts[1],footers[1]
end

local function Sorted()
    local list={}
    for _,entry in ipairs(presets) do list[#list+1]=entry end
    table.sort(list,function(a,b)
        if a.Name:lower()==b.Name:lower() then return a.Id<b.Id end
        return a.Name:lower()<b.Name:lower()
    end)
    return list
end

local function PresetSelected()
    return Sorted()[state.Selected+1]
end

local function Named(name)
    for _,entry in ipairs(presets) do if entry.Name:lower()==name:lower() then return entry end end
end

local function Notice(text)
    state.Notice=text;state.NoticeUntil=Ext.Timer.MonotonicTime()+3000
end

-- Store readable labels alongside identity descriptors; do not change matching semantics.
local function Translated(value)
    if type(value)~='string' or value=='' then return nil end
    local ok,translated=pcall(Ext.Loca.GetTranslatedString,value,value)
    return ok and type(translated)=='string' and translated~='' and translated or value
end

local function DisplayLabel(item)
    if not item then return nil end
    local label=Data.Read(item,'Name') or Data.Read(item,'DisplayName')
    if type(label)=='string' then return Translated(label) end
    local handle=Data.Read(label,'Handle')
    if type(handle)~='string' then handle=Data.Read(handle,'Handle') end
    return Translated(handle)
end

local function PresetSubRace(entry)
    if type(entry.SubRaceLabel)=='string' and entry.SubRaceLabel~='' then return entry.SubRaceLabel end
    local appearance=entry.Appearance or {}
    if not appearance.SubRace then return 'No subrace' end
    -- Existing saved presets already contain subrace identities. Extract a label
    -- where available, without rewriting or invalidating the stored preset.
    for _,key in ipairs({'Name','DisplayName','Text'}) do
        local label=Translated(appearance.SubRace[key])
        if label then return label end
    end
    return 'Subrace saved (name unavailable)'
end

local function QueueWrite(context)
    local name=state.Name:gsub('^%s+',''):gsub('%s+$','')
    local number=nextNumber
    if name=='' then
        while Named('Preset '..number) do number=number+1 end
        name='Preset '..number
    end
    name=Data.CleanName(name)
    local namedNumber=name:match('^Preset (%d+)$')
    local following=namedNumber and math.max(nextNumber,tonumber(namedNumber)+1) or nextNumber
    local old=Named(name)
    if old and (not state.Confirm or state.ConfirmId~=old.Id or state.ConfirmName~=name) then
        state.Confirm=true;state.ConfirmId=old.Id;state.ConfirmName=name
        state.Status='Replace the saved preset named '..name..'?';return
    end
    if not old and #presets>=200 then error('The preset list is full.') end
    local id=old and old.Id or 1
    if not old then for _,entry in ipairs(presets) do id=math.max(id,entry.Id+1) end end
    local appearance=Data.Capture(context)
    local entry={Id=id,Name=name,RaceLabel=DisplayLabel(Data.Read(context,'SelectedRace')) or '',
        SubRaceLabel=DisplayLabel(Data.Read(context,'SelectedSubRace')) or '',Appearance=appearance}
    local nextList={}
    for _,existing in ipairs(presets) do if existing.Id~=id then nextList[#nextList+1]=existing end end
    nextList[#nextList+1]=entry
    pendingWrite={Presets=nextList,Name=name,NextNumber=following,Kind='Save',Entry=entry,File=old and old.File or Files.FileFor(name,'appearance')}
    state.Confirm=false;state.Status='Saving preset…'
end

local function Act(action,page,context)
    if action=='Back' then
        if state.DeleteId then state.DeleteId=nil;state.Status='';return end
        if state.Confirm then state.Confirm=false;state.Status='';return end
        state.Mode='';state.Name='';state.ClearName=true;state.Status='';return
    end
    if pendingWrite or verification then return end
    if storageError then error(storageError) end
    if action=='OpenSave' or action=='OpenLoad' then
        state.Mode=action=='OpenSave' and 'Save' or 'Load'
        state.Owner=tostring(page);state.Confirm=false;state.DeleteId=nil;state.Status='';state.Notice=''
        state.Name='';state.ClearName=true
        if state.Mode=='Load' or state.Mode=='Save' then
            local refreshed,why=LoadIndividual()
            if not refreshed then error(why) end
            revision=revision+1
            state.Selected=#presets>0 and 0 or -1
            if #presets==0 and state.Mode=='Load' then state.Status='No presets saved yet.' end
            Log('PRESET_DISCOVERY '..tostring(Files.LastDiscoveryReport()))
        end
        return
    end
    if state.Mode=='' or state.Owner~=tostring(page) then return end
    if action=='Save' and state.Mode=='Save' then QueueWrite(context)
    elseif action=='Delete' and state.Mode=='Load' then
        local entry=PresetSelected()
        if not entry then error('Choose a saved preset.') end
        if state.DeleteId~=entry.Id then
            state.DeleteId=entry.Id;state.Status='Delete "'..entry.Name..'"?';return
        end
        local remaining={}
        for _,existing in ipairs(presets) do if existing.Id~=entry.Id then remaining[#remaining+1]=existing end end
        pendingWrite={Presets=remaining,Name=entry.Name,NextNumber=nextNumber,Kind='Delete',Entry=entry,File=entry.File}
        state.DeleteId=nil;state.Status='Deleting preset…'
    elseif action=='Load' and state.Mode=='Load' then
        if state.DeleteId then return end
        local entry=PresetSelected()
        if not entry then error('Choose a saved preset.') end
        local savedChin=entry.Appearance.Selections and entry.Appearance.Selections.SelectedChin
        Log('CHIN_PRELOAD preset='..entry.Name..'; saved='..(savedChin==nil and 'legacy missing' or
            (savedChin.None==true and 'None' or 'identity'))..'; '..ChinTrace(context))
        local applied=Data.ApplyAvailable(context,entry.Appearance)
        Log('CHIN_POSTAPPLY '..ChinTrace(context))
        verification={Owner=tostring(page),Result=applied,Name=entry.Name,
            Due=Ext.Timer.MonotonicTime()+750}
        state.Status='Applying preset…'
    end
end

Ext.UI.RegisterType(ROW,{Name={Type='String'},Detail={Type='String'}})
local fields={
    HB_Menu={Type='Bool'},HB_Visible={Type='Bool',Notify=true},HB_Open={Type='Bool',Notify=true},HB_IsMirror={Type='Bool',Notify=true},
    HB_SaveMode={Type='Bool',Notify=true},HB_LoadMode={Type='Bool',Notify=true},HB_Confirm={Type='Bool',Notify=true},
    HB_Busy={Type='Bool',Notify=true},HB_CanSave={Type='Bool',Notify=true},HB_CanLoad={Type='Bool',Notify=true},
    HB_Status={Type='String',Notify=true},HB_Title={Type='String',Notify=true},
    HB_Name={Type='String',Notify=true},
    HB_SelectedIndex={Type='Int32',Notify=true},
    HB_Notice={Type='String',Notify=true},HB_DeleteConfirm={Type='Bool',Notify=true},
    HB_DeleteLabel={Type='String',Notify=true},HB_CanDelete={Type='Bool',Notify=true},
    HB_Rows={Type='Collection'},HB_Stamp={Type='Int32'},
}
for _,action in ipairs({'OpenSave','OpenLoad','Save','Load','Delete','Back'}) do fields['HB_'..action]={Type='Command'} end
Gear.Install(fields)
Ext.UI.RegisterType(TYPE,fields)

local function NewVM()
    local vm=Ext.UI.Instantiate(TYPE)
    vm.HB_Menu=true;vm.HB_Stamp=revision
    for _,action in ipairs({'OpenSave','OpenLoad','Save','Load','Delete','Back'}) do
        local selected=action
        vm['HB_'..selected]:SetHandler(function()request=selected end)
    end
    for _,entry in ipairs(Sorted()) do
        local row=Ext.UI.Instantiate(ROW)
        row.Name=entry.Name;row.Detail=(entry.RaceLabel or '')..' / '..PresetSubRace(entry)..' / '..Data.BodyLabel(entry.Appearance.Body)
        vm.HB_Rows[#vm.HB_Rows+1]=row
    end
    vm.HB_Name=state.Name;vm.HB_SelectedIndex=state.Selected
    Gear.Populate(vm)
    return vm
end

local function Update()
    local page,host,footer=Walk(Ext.UI.GetRoot())
    presetPageActive=(page~=nil)
    if not page then
        Gear.Reset()
        state.Mode='';state.Name='';state.ClearName=true;state.Notice='';state.Owner=nil;request=nil;verification=nil
        settledOwner=nil;settledPasses=0;return
    end
    Gear.Owner(page)
    local context=Data.Read(page,'DataContext')
    -- SE32 has no Defer. Follow HB's existing client-tick UI compatibility path,
    -- waiting for the native creation context to initialize and settle first.
    -- Retain only a string identity between updates, never a live UI reference.
    if not defer then
        local owner=tostring(page)..':'..tostring(context)
        if Data.Read(context,'IsInitialized')~=true then
            local waiting='Waiting for character-creation initialization; IsInitialized='..tostring(Data.Read(context,'IsInitialized'))
            if state.WaitingLog~=waiting then state.WaitingLog=waiting;Log(waiting) end
            settledOwner=nil;settledPasses=0;return
        end
        if settledOwner~=owner then settledOwner=owner;settledPasses=0 end
        settledPasses=settledPasses+1
        if settledPasses<3 then return end
    end
    if verification and Ext.Timer.MonotonicTime()>=verification.Due then
        local pending=verification;verification=nil
        if pending.Owner==tostring(page) then
            local success,retained,skipped=pcall(Data.VerifyAvailable,context,pending.Result)
            Log('CHIN_DELAYED_VERIFY '..ChinTrace(context))
            if success and retained>0 then
                state.Mode='';state.Status='';Notice('Preset Loaded')
                Log('Loaded preset '..pending.Name..'; retained settings='..retained
                    ..'; skipped='..#skipped..(#skipped>0 and '\n'..table.concat(skipped,'\n') or ''))
            else
                state.Status='No saved appearance settings could be verified. Available changes were kept.'
                Log('Preset verification: '..tostring(success and table.concat(skipped,'; ') or retained),context)
            end
            pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_VisualPresets_LastLoad.txt',table.concat(messages,'\n'))
        end
    end
    -- Keep presets available on EVERY character-creation step before Naming,
    -- including Origin, Gameplay and the separate Companion/Guardian step.
    -- Only hide them on Naming / Finished, as requested. The Magic Mirror
    -- has no such flow, and retains presets throughout its session.
    local pageNameNow=Data.Read(page,'Name')
    local pageFileNow=Data.Read(page,'FileName')
    local isMirrorNow=(pageNameNow=='CharacterChangeAppearance' or pageNameNow=='CharacterChangeAppearance_c'
        or (type(pageFileNow)=='string' and pageFileNow:find('CharacterChangeAppearance',1,true)~=nil))
    local flowStep=nil
    if not isMirrorNow then
        local flow=nil
        pcall(function() flow=page:Find('flowPage') end)
        local current=Data.Read(flow,'SelectedItem')
        flowStep=Data.Read(current,'Content')
        if type(flowStep)=='userdata' then flowStep=Data.Read(flowStep,'Content') end
        if flowStep~=nil then flowStep=tostring(flowStep) end
        -- Some CC templates leave the Appearance flow item selected while
        -- transitioning to Naming. The actual visible naming footer takes
        -- precedence over stale flow-selection state.
        local naming=nil
        pcall(function() naming=page:Find('namingPageButtons') end)
        if Data.Read(naming,'IsVisible')==true then flowStep='Naming' end
        -- Companion is a genuine appearance-editing context. Do not hide
        -- the preset controls merely because we're editing the guardian.
        if flowStep==nil and Data.Read(context,'CharacterCreationStep')=='Companion' then
            flowStep='Companion'
        end
    end
    local beforeNaming=isMirrorNow or (flowStep~='Naming' and flowStep~='Finished')
    local visible=Data.CanEdit(context) and beforeNaming
    if not beforeNaming then
        state.Mode='';state.Confirm=false;state.Owner=nil
    end
    if state.Owner and state.Owner~=tostring(page) then state.Mode='';state.Confirm=false;state.Owner=nil;verification=nil end
    local vm=Data.Read(host,'DataContext')
    if Data.Read(vm,'HB_Menu')~=true or Data.Read(vm,'HB_Stamp')~=revision then
        vm=NewVM();host.DataContext=vm
        Log('Preset controls attached to '..tostring(Data.Read(page,'FileName') or Data.Read(page,'Name'))..'.')
    end
    -- Footer is on HUDTop, beneath native Inspect tooltips. Both widgets use
    -- the existing shared request/gear handlers, but only the modal's VM
    -- owns editable preset fields and the equipment dialog.
    local footerVM=nil
    if footer then
        footerVM=Data.Read(footer,'DataContext')
        if Data.Read(footerVM,'HB_Menu')~=true or Data.Read(footerVM,'HB_Stamp')~=revision then
            footerVM=NewVM();footer.DataContext=footerVM
        end
    end
    local gearVisible=visible and not isMirrorNow and flowStep~='Companion'
    local gearAllowed=gearVisible and state.Mode==''
    local gearObservation='Starting Equipment visible='..tostring(gearAllowed)..'; creation step='..tostring(flowStep)
    if gearObservation~=lastGearVisibility then lastGearVisibility=gearObservation;Log(gearObservation) end
    local gearFlowIndex=nil
    if not isMirrorNow then
        local flowControl=nil
        pcall(function() flowControl=page:Find('flowPage') end)
        gearFlowIndex=Data.Read(flowControl,'SelectedIndex')
    end
    if Gear.Process(vm,gearAllowed,gearFlowIndex,context) then
        vm=NewVM();host.DataContext=vm
    end
    -- Read the bound values before handling a click. Do not rewrite Text while typing:
    -- doing so resets the caret/selection and can interfere with Backspace.
    if not state.ClearName then
        local input=Data.Read(vm,'HB_Name')
        if type(input)=='string' then state.Name=input end
    end
    local selected=Data.Read(vm,'HB_SelectedIndex')
    if type(selected)=='number' and selected%1==0 and selected>=-1 then state.Selected=selected end
    if request then
        local action=request;request=nil
        if visible or action=='Back' then
            local success,err=pcall(Act,action,page,context)
            if not success then
                state.Status=tostring(err):gsub('^.-:%d+: ','')
                Log(state.Status,context)
            end
        end
    end
    local visibility='Appearance buttons visible='..tostring(visible)
        ..'; IsCreation='..tostring(Data.Read(context,'IsCreation'))
        ..'; IsInitialized='..tostring(Data.Read(context,'IsInitialized'))
        ..'; IsLocked='..tostring(Data.Read(context,'IsLocked'))
        ..'; OriginLocked='..tostring(Data.Read(Data.Read(context,'SelectedOrigin'),'IsLockedAppearance'))
    if state.VisibilityLog~=visibility then state.VisibilityLog=visibility;Log(visibility) end
    if state.ClearName then vm.HB_Name='';state.ClearName=false end
    if Ext.Timer.MonotonicTime()>=state.NoticeUntil then state.Notice='' end
    vm.HB_Notice=state.Notice
    vm.HB_DeleteConfirm=state.DeleteId~=nil
    vm.HB_DeleteLabel=state.DeleteId and 'Confirm Delete' or 'Delete'
    vm.HB_Open=visible and state.Mode~=''
    vm.HB_Visible=visible
    vm.HB_Gear_Visible=gearVisible
    vm.HB_Gear_Open=gearAllowed and Gear.IsOpen()
    vm.HB_FooterEnabled=not vm.HB_Open and not vm.HB_Gear_Open
    if footerVM then
        footerVM.HB_Visible=visible
        footerVM.HB_Gear_Visible=gearVisible
        footerVM.HB_FooterEnabled=not vm.HB_Open and not vm.HB_Gear_Open
    end
    local pageName=Data.Read(page,'Name')
    local pageFile=Data.Read(page,'FileName')
    vm.HB_IsMirror=(pageName=='CharacterChangeAppearance' or pageName=='CharacterChangeAppearance_c'
        or (type(pageFile)=='string' and pageFile:find('CharacterChangeAppearance',1,true)~=nil))
    if footerVM then footerVM.HB_IsMirror=vm.HB_IsMirror end
    if type(state.Selected)~='number' then state.Selected=-1 end
    vm.HB_SelectedIndex=state.Selected
    vm.HB_SaveMode=state.Mode=='Save';vm.HB_LoadMode=state.Mode=='Load'
    vm.HB_Confirm=state.Confirm;vm.HB_Busy=pendingWrite~=nil or verification~=nil
    vm.HB_CanSave=not storageError and not pendingWrite and not verification
    vm.HB_CanDelete=not storageError and not pendingWrite and not verification and PresetSelected()~=nil
    local canLoad=false
    local incompatibility=nil
    if vm.HB_CanDelete and not state.DeleteId then
        local entry=PresetSelected()
        local ok,err=pcall(Data.ValidateAvailable,context,entry.Appearance)
        canLoad=ok
        if not ok then
            incompatibility=tostring(err):gsub('^.-:%d+: ','')
            local summary='PRESET_LOAD_UNAVAILABLE name='..tostring(entry.Name)
                ..'; reason='..incompatibility..'; '..Data.CompatibilityTrace(context,entry.Appearance)
            if state.LastCompatibilityLog~=summary then
                state.LastCompatibilityLog=summary;Log(summary)
            end
        else
            state.LastCompatibilityLog=nil
        end
    else
        state.LastCompatibilityLog=nil
    end
    vm.HB_CanLoad=canLoad
    vm.HB_Status=storageError or (state.Status~='' and state.Status or
        (state.Mode=='Load' and incompatibility or ''))
    vm.HB_Title=state.Mode=='Save' and 'Save Character Appearance' or 'Load Character Appearance'
end

local function Persist()
    if not pendingWrite then return end
    local write=pendingWrite;pendingWrite=nil
    local saved,err=pcall(function()
        if not write.File then error('Original preset filename unavailable.') end
        local file=write.File
        local old=Ext.IO.LoadFile(DIR..'/'..file)
        if write.Kind=='Save' then
            -- A checked .bak protects overwriting a shared or personal preset.
            if old and old~='' then
                if Ext.IO.SaveFile(DIR..'/'..file..'.bak',old)==false then
                    error('Could not back up the existing preset.')
                end
            end
            local entry=write.Entry
            local ok,why=Files.Write(DIR,file,
                {Kind='HomeBrewAppearance',Version=1,Preset=entry})
            if not ok then error(why) end
            entry.File=file
        else
            local ok,why=Files.Tombstone(DIR,file)
            if not ok then error(why) end
        end
        presets=write.Presets;nextNumber=write.NextNumber;revision=revision+1
    end)
    if saved then
        state.Name='';state.ClearName=true;state.Status=''
        if write.Kind=='Delete' then
            state.Selected=#presets>0 and 0 or -1
            if #presets==0 then state.Status='No presets saved yet.' end
        else state.Mode='';Notice('Preset Saved') end
        Log(write.Kind..' completed: '..write.Name)
    else
        state.Status=write.Kind=='Delete' and 'The preset could not be deleted. Try again.' or 'The preset could not be saved. Try again.'
        Log(err)
    end
end

local MenuScope = Ext.Require("Client/MenuScope.lua")
local lastScopePoll, scopeOpen = -100000, false
local function PresetMenuVisible(now)
    if now - lastScopePoll >= (scopeOpen and 250 or 950) then
        lastScopePoll, scopeOpen = now, MenuScope.IsOpen('Presets')
    end
    return scopeOpen
end

Ext.Events.Tick:Subscribe(function()
    Persist()
    local now=Ext.Timer.MonotonicTime()
    -- Leave pending explicit save/delete writes intact, but don't mount/
    -- inspect creation presets during unrelated in-world gameplay.
    local visible=PresetMenuVisible(now)
    if not visible and not presetPageActive then return end
    if queued or now<nextUpdate then return end
    -- Preset controls only exist in creation/Mirror. Outside those screens,
    -- avoid repeated whole-UI traversal in ordinary gameplay.
    nextUpdate=now+(presetPageActive and 150 or 1400);queued=true
    local function Run()
        queued=false
        local success,err=pcall(Update)
        if not success then
            -- Release the blocking modal if any unexpected refresh error occurs.
            state.Mode='';state.Confirm=false;state.Selected=-1;request=nil
            pcall(function()
                local _,host=Walk(Ext.UI.GetRoot())
                local vm=Data.Read(host,'DataContext')
                if vm then vm.HB_Open=false end
            end)
            Log('UI update error (preset window closed): '..tostring(err))
        end
    end
    if defer then defer(Run) else Run() end
end)
