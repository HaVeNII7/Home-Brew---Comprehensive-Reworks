local Files=Ext.Require('Shared/PresetFiles.lua')
local Builds=Ext.Require('Shared/BuildPresetData.lua')
local DIR='HomeBrew/BuildPresets'
local channel=Ext.Net.CreateChannel(ModuleUUID,'HB_LevelUpBuild_v1')
local loneWolfChannel=Ext.Net.CreateChannel(ModuleUUID,'HB_LoneWolf_LevelUp_v1')
local registered=false
local generation=0
local selectedFiles={}
local deleteArmed=nil
local pending=nil
local finishPending=false
local applyWhenComplete=false
local autoFill=nil
local finishingHandoff=false
local pendingNativeExit=nil
local lastActor=nil
local lastLevel=nil
local lastNativeToken=nil
local log={'HomeBrew level-up build UI v4 - native picker and history state'}
local lastProbe=nil
local lastNativeLevelProbe=nil
local function Trace(s)
    log[#log+1]=tostring(s)
    if #log>200 then table.remove(log,2) end
    if _G.HB_DebugDiagnostics == true or tostring(s):find('ERROR',1,true)
        or tostring(s):find('FAILED',1,true) then
        pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_LevelUpBuild_UI.txt',table.concat(log,'\n')..'\n')
    end
end
local function Probe(message)
    message=tostring(message)
    if lastProbe~=message then lastProbe=message; Trace('MOUNT '..message) end
end
local function Read(obj,key)
    if not obj then return nil end
    local ok,result=pcall(function() return obj[key] end)
    return ok and result or nil
end
-- Noesis objects are only inspected during the UI update. Gameplay/network
-- actions originating from UI callbacks are returned to the normal Tick.
local mainThreadWork={}
local function QueueMain(work)
    mainThreadWork[#mainThreadWork+1]=work
end
local function QueueUI(work)
    if not Ext.UI or not Ext.UI.Defer then return false end
    local ok,why=pcall(Ext.UI.Defer,function()
        local worked,err=pcall(work)
        if not worked then Trace('SAFE_UI_ERROR '..tostring(err)) end
    end)
    if not ok then Trace('SAFE_UI_QUEUE_ERROR '..tostring(why)) end
    return ok
end
local function FindWidget(name, alternate)
    if not Ext.UI or not Ext.UI.GetRoot then return nil end
    local root=Ext.UI.GetRoot()
    local start=root and (Read(root,'ContentRoot') or (function()
        local ok,result=pcall(function() return root:Find('ContentRoot') end)
        return ok and result or nil
    end)())
    if not start then return nil end
    local nodes={start};local n=1
    local fallback=nil
    while n<=#nodes and n<=2500 do
        local node=nodes[n];n=n+1
        local current=Read(node,'Name')
        if current==name then return node end
        if alternate and current==alternate and not fallback then fallback=node end
        local count=math.min(tonumber(Read(node,'VisualChildrenCount')) or 0,120)
        for i=1,count do
            local ok,child=pcall(function() return node:VisualChild(i) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    return fallback
end
local function Native()
    local w=FindWidget('CharacterLevelUp','CharacterLevelUp_c')
    local vm=w and Read(w,'DataContext')
    if tostring(Read(vm,'Type') or '')~='gui::DCCharacterLevelUp' then return nil end
    return vm
end
local function RequestNativeExitForDirect()
    local info=pendingNativeExit
    if not info or info.sent then return end
    local native=Native()
    if not native then
        info.sent=true
        Trace('DIRECT_LEVEL_NATIVE_EXIT_CONFIRMED actor='..tostring(info.actor)
            ..' target='..tostring(info.target))
        local actor,target=info.actor,info.target
        QueueMain(function()
            channel:SendToServer({Operation='NativeClosed',Character=actor,
                TargetLevel=target})
        end)
        pendingNativeExit=nil
        return
    end
    if not info.injected then
        info.injected=true
        QueueMain(function()
            local ok,why=pcall(function()
                if not Ext.Input or not Ext.Input.InjectKeyPress then
                    error('Input API does not expose InjectKeyPress')
                end
                Ext.Input.InjectKeyPress('ESCAPE')
            end)
            Trace('DIRECT_LEVEL_NATIVE_EXIT_INJECT sent='..tostring(ok)
                ..' reason='..tostring(why))
        end)
        -- The watchdog will not send NativeClosed until the actual native
        -- VM disappears, regardless of whether the injected key was accepted.
    end
end
local function Character(vm)
    local owner=Read(vm,'LevelUpCharacter')
    local uuid=Read(owner,'Uuid') or Read(owner,'UUID')
    local candidates={Read(uuid,'EntityUuid'),Read(owner,'Guid'),Read(owner,'CharacterGuid'),
        Read(uuid,'Uuid'),uuid,Read(owner,'Id')}
    for i=1,6 do
        local raw=candidates[i]
        local text=tostring(raw or '')
        local value=text:match('(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)')
        if value then return value end
    end
    return nil
end
local function Register()
    if registered then return end
    Ext.UI.RegisterType('HB_LevelUpBuildRow_v1',{
        Name={Type='String'},Detail={Type='String'}})
    Ext.UI.RegisterType('HB_LevelUpBuildVM_v1',{
        HB_Visible={Type='Bool',Notify=true},HB_Open={Type='Bool',Notify=true},
        HB_SaveMode={Type='Bool',Notify=true},HB_LoadMode={Type='Bool',Notify=true},
        HB_Name={Type='String',Notify=true},HB_Status={Type='String',Notify=true},
        HB_Assigned={Type='String',Notify=true},HB_CanApply={Type='Bool',Notify=true},
        HB_CanLoad={Type='Bool',Notify=true},HB_Busy={Type='Bool',Notify=true},
        HB_DialogTitle={Type='String',Notify=true},HB_SaveLabel={Type='String',Notify=true},
        HB_CanSave={Type='Bool',Notify=true},HB_CanDelete={Type='Bool',Notify=true},
        HB_Selected={Type='Int32',Notify=true},HB_Rows={Type='Collection'},
        HB_BoundLevel={Type='Int32'},HB_BoundActor={Type='String'},
        HB_OpenSave={Type='Command'},HB_OpenLoad={Type='Command'},
        HB_Close={Type='Command'},HB_Save={Type='Command'},HB_Load={Type='Command'},
        HB_Delete={Type='Command'},
        HB_Apply={Type='Command'},HB_SelectionChanged={Type='Command'},
    })
    registered=true
end
local function Live()
    local widget=FindWidget('HB_LevelUpBuild','HB_LevelUpBuild_c')
    return widget and Read(widget,'DataContext'),widget
end
-- Use the same display-only starting class/subclass labels shown by the
-- established respec build picker. GUIDs still drive server compatibility.
local displayNames={}
local function ClassLabel(uuid,kind)
    uuid=tostring(uuid or '')
    if uuid=='' or uuid=='00000000-0000-0000-0000-000000000000' then
        return kind=='subclass' and 'No Subclass' or 'Unknown Class'
    end
    if displayNames[uuid] then return displayNames[uuid] end
    local label=nil
    if Ext.StaticData and Ext.StaticData.Get then
        local ok,data=pcall(Ext.StaticData.Get,uuid,'ClassDescription')
        if ok and data then
            local handle=nil
            pcall(function()
                local name=data.DisplayName
                local raw=name and name.Handle
                handle=raw and tostring(raw.Handle or raw) or nil
            end)
            if handle and handle~='' and not handle:find('^ResStr_')
                and Ext.Loca and Ext.Loca.GetTranslatedString then
                local good,text=pcall(Ext.Loca.GetTranslatedString,handle)
                if good and type(text)=='string' and text~='' and text~=handle then label=text end
            end
            if not label then
                local good,name=pcall(function() return data.Name end)
                if good and name then
                    local text=tostring(name)
                    if not text:match('^%x%x%x%x%x%x%x%x%-') then
                        text=text:gsub('^ProgressionSubClass_','')
                            :gsub('^ProgressionClass_',''):gsub('^SubClass_','')
                            :gsub('^Class_',''):gsub('([a-z])([A-Z])','%1 %2'):gsub('_',' ')
                        if text~='' then label=text end
                    end
                end
            end
        end
    end
    label=label or (kind=='subclass' and 'Unknown Subclass' or 'Unknown Class')
    displayNames[uuid]=label
    return label
end
local function PresetDetail(preset)
    local starting=preset and preset.Levels and preset.Levels[1]
    if type(starting)~='table' then return 'Unknown Class / No Subclass / Level '..tostring(preset and preset.LevelCount or '?') end
    return ClassLabel(starting.Class,'class')..' / '
        ..ClassLabel(starting.SubClass,'subclass')..' / Level '..tostring(preset.LevelCount)
end
local function Discover(vm)
    selectedFiles={}
    local files,why=Files.Discover(DIR)
    if not files then vm.HB_Status=tostring(why);return end
    local seen={}
    for _,file in ipairs(files) do
        local key=tostring(file):lower()
        if not seen[key] then
        seen[key]=true
        local preset=Files.Read(DIR,file)
        if preset and Builds.Validate(preset) and preset.Version==2 then
            selectedFiles[#selectedFiles+1]=file
            local row=Ext.UI.Instantiate('HB_LevelUpBuildRow_v1')
            row.Name=preset.Name
            row.Detail=PresetDetail(preset)
            vm.HB_Rows[#vm.HB_Rows+1]=row
        end
        end
    end
    Trace('PICKER_ROWS count='..#selectedFiles..' discovery='..tostring(Files.LastDiscoveryReport()))
    vm.HB_Selected=-1
    vm.HB_CanLoad=false
    vm.HB_CanDelete=false
    deleteArmed=nil
end
local function Request(vm,operation,details)
    if not lastLevel or (not lastActor and operation~='State') then
        vm.HB_Status='Character identity has not been verified; no changes were made.'
        return
    end
    if pending then return end
    pending=operation
    vm.HB_Busy=true
    vm.HB_CanApply=false
    vm.HB_Status='Checking '..operation:lower()..'…'
    local message={Character=lastActor,TargetLevel=lastLevel,Operation=operation}
    for k,v in pairs(details or {}) do message[k]=v end
    Trace('REQUEST op='..operation..' actor='..tostring(lastActor or 'unresolved')
        ..' level='..tostring(lastLevel))
    QueueMain(function() channel:SendToServer(message) end)
end
local function FinishNativeLevel()
    local vm=Native()
    local current=tonumber(Read(vm,'CurrentCharacterLevel'))
    local target=tonumber(Read(vm,'AvailableCharacterLevel'))
    if not vm or current~=lastLevel-1 or target~=lastLevel then
        return false,'The original level-up screen is no longer active.'
    end
    -- CanExecute(true) is not a completion guarantee in BG3.
    -- Live testing showed that invoking it with 0/2 choices puts the VM
    -- into Finishing but does not commit the level or its history.
    if Read(vm,'IsLevelUpComplete')~=true then
        Trace('FINISH_GUARD blocked incomplete native level '..tostring(current)..'->'..tostring(target))
        return false,'Complete the required level-up choices before restoring your build.'
    end
    local command=Read(vm,'FinishLevelUp')
    if not command then return false,'Native FinishLevelUp command is unavailable.' end
    local ok,can=pcall(function() return command:CanExecute(nil) end)
    if not ok or can~=true then return false,'Native level-up cannot be confirmed.' end
    local worked,err=pcall(function() command:Execute(nil) end)
    Trace('FINISH_NATIVE executed='..tostring(worked)
        ..' complete='..tostring(Read(vm,'IsLevelUpComplete'))
        ..' level='..tostring(current)..'->'..tostring(target)
        ..' error='..tostring(err))
    return worked,err
end
-- Temporary native choices are only used to complete the actual BG3 transaction.
-- Never force FinishLevelUp on an incomplete VM. The preset restoration later
-- replaces every temporary selection through its existing verified replay.
local function AutoCollectionCount(collection)
    if not collection then return 0 end
    -- BG3's native ls/UI collections expose Count. Their Lua # operator is
    -- not guaranteed to work, unlike the synthetic tables in our first mocks.
    local value=tonumber(Read(collection,'Count'))
    if value==nil then
        local ok,length=pcall(function() return #collection end)
        if ok then value=tonumber(length) end
    end
    if not value or value<0 or value>512 or value%1~=0 then return 0 end
    return value
end
local function AutoCollectionItem(collection,index)
    if not collection then return nil end
    -- Native Noesis collections are zero-indexed; ordinary Lua tables are not.
    -- Preserve the native method fallbacks used in NativeHistoricalPreview.
    local attempts={}
    if type(collection)=='table' then
        attempts={
            function() return collection[index+1] end,
            function() return collection[index] end,
        }
    else
        attempts={
            function() return collection[index] end,
            function() return collection[index+1] end,
            function() return collection:Get(index) end,
            function() return collection:GetItem(index) end,
        }
    end
    for _,get in ipairs(attempts) do
        local ok,item=pcall(get)
        if ok and item~=nil then return item end
    end
    return nil
end
-- Spell selectors exist in both the class/subclass collections and the
-- progression details. The UI can expose the same selector in two places.
-- Enumerate both without sending duplicate clicks to that selector.
local spellSources={
    {'ClassSpellSelectors'}, {'SubClassSpellSelectors'},
    {'RaceSpellSelectors'}, {'SubRaceSpellSelectors'},
    {'ClassProgressionDetails','SpellSelectors'},
    {'SubClassProgressionDetails','SpellSelectors'},
    {'RaceProgressionDetails','SpellSelectors'},
    {'SubRaceProgressionDetails','SpellSelectors'},
    {'FeatDetails','SpellSelectors'},
}
local function AutoSpellGroups(native)
    local result,seen={},{}
    for _,path in ipairs(spellSources) do
        local parent=#path==2 and Read(native,path[1]) or native
        local collection=Read(parent,path[#path])
        local count=AutoCollectionCount(collection)
        for index=0,count-1 do
            local selector=AutoCollectionItem(collection,index)
            if selector then
                local key=tostring(selector)
                if not seen[key] then
                    seen[key]=true
                    result[#result+1]={selector=selector,path=path,index=index,
                        label=table.concat(path,'.')..'['..index..']'}
                end
            end
        end
    end
    return result
end
local function AutoSpellStatus(native)
    local groups=AutoSpellGroups(native)
    local details={}
    for i,entry in ipairs(groups) do
        if i>12 then break end
        local selector=entry.selector
        details[#details+1]=entry.label..' '..tostring(Read(selector,'Type'))
            ..' selected='..tostring(Read(selector,'AddedCount'))
            ..' slots='..AutoCollectionCount(Read(selector,'Additions'))
            ..' available='..AutoCollectionCount(Read(selector,'Available'))
            ..' complete='..tostring(Read(selector,'IsComplete'))
    end
    return #groups,table.concat(details,';')
end
local function AutoSpellGroupAt(native,path,index)
    local parent=#path==2 and Read(native,path[1]) or native
    return AutoCollectionItem(Read(parent,path[#path]),index)
end
-- Reuse the *real* native spell button's converted command parameter.
-- Noesis' PassThroughConverter creates a native pair from the active
-- VMSpellSelector and VMSpellReference. Lua tables, or new Object properties
-- on the HomeBrew picker VM, cannot substitute for this pair.
local function AutoNativeSpellWidgets()
    local root=FindWidget('CharacterLevelUp','CharacterLevelUp_c')
    if not root then return nil,{}, {},nil end
    local panels,buttons={},{}
    local subTabs,mainTabs=nil,nil
    local subTabItems=-1
    -- The live BG3 templates use different names on keyboard and controller.
    -- Only consider buttons beneath the actual *available* spell collection.
    -- A selected-spell tile would execute DeselectSpell instead.
    local availableList={
        availableSpells=true,
        ClassSpellAvailableItemsControl=true,
        HB_SchoolAvailableItemsControl=true,
    }
    local selectNames={
        SelectAvailableSpell=true,SelectSpell=true,
        spellButton=true,spell=true,
    }
    local nodes={{node=root,available=false}}
    local nextNode=1
    while nextNode<=#nodes and nextNode<=10000 do
        local entry=nodes[nextNode]
        nextNode=nextNode+1
        local node=entry.node
        local name=Read(node,'Name')
        local available=entry.available or availableList[name]==true
        if name=='gameplayTabs' and not mainTabs then mainTabs=node end
        if name=='subTabsSpellsList' then
            local items=Read(node,'ItemsSource') or Read(node,'Items')
            local count=AutoCollectionCount(items)
            if not subTabs or count>subTabItems then
                subTabs=node
                subTabItems=count
            end
        end
        if name=='gameplaySubPanel' then panels[#panels+1]=node end
        if available and selectNames[name]==true then
            buttons[#buttons+1]=node
        end
        local count=math.min(tonumber(Read(node,'VisualChildrenCount')) or 0,180)
        for i=1,count do
            local ok,child=pcall(function() return node:VisualChild(i) end)
            if ok and child then nodes[#nodes+1]={node=child,available=available} end
        end
    end
    return subTabs,panels,buttons,mainTabs
end

local function AutoSameNoesisObject(a,b)
    if not a or not b then return false end
    -- Comparing the stringified Noesis *type* makes every VMSpellSelector
    -- appear equal. Prefer native proxy equality; never match by type alone.
    local ok,equal=pcall(function() return a==b end)
    if ok and equal==true then return true end
    local first,second=tostring(a),tostring(b)
    if first==second and first:find('0x',1,true) then return true end
    return false
end
local function AutoSelectMainSpellTab(mainTabs)
    if not mainTabs then return false,'native gameplayTabs unavailable' end
    -- The keyboard/controller templates select the real levelupTab item,
    -- NOT a numbered item from gameplayTabs.Items. A Noesis ListBox can
    -- expose zero Lua-readable Items even though its named tabs exist.
    local nativeRoot=FindWidget('CharacterLevelUp','CharacterLevelUp_c')
    local tab=FindWidget('levelupTab')
    if not tab and nativeRoot then
        local ok,found=pcall(function() return nativeRoot:Find('levelupTab') end)
        if ok then tab=found end
    end
    if not tab then return false,'native levelupTab not found' end
    local previous=Read(mainTabs,'SelectedItem')
    local selected=AutoSameNoesisObject(previous,tab)
    -- If the tab is already selected but its spell subtabs did not mount,
    -- allow one native re-selection to re-fire BG3's own DataTriggers.
    if selected and autoFill.mainSpellTabRefreshed then
        return true,'native levelupTab already refreshed'
    end
    local ok,err=pcall(function()
        if selected then mainTabs.SelectedIndex=-1 end
        mainTabs.SelectedItem=tab
    end)
    if selected then autoFill.mainSpellTabRefreshed=true end
    Trace('AUTO_FILL_SPELL_MAIN_NATIVE_SELECT level='..tostring(lastLevel)
        ..' selected='..tostring(selected)
        ..' previousTag='..tostring(Read(previous,'Tag'))
        ..' targetTag='..tostring(Read(tab,'Tag'))
        ..' ok='..tostring(ok)
        ..' selectedTag='..tostring(Read(Read(mainTabs,'SelectedItem'),'Tag'))
        ..' error='..tostring(not ok and err or nil))
    return ok,ok and 'native levelupTab selected' or tostring(err)
end

-- The ordinary level-up has multiple templated subTabsSpellsList controls.
-- Only the one with a materialized VMSpellSelector item belongs to the live
-- visible Spells sidebar. A bare ItemsSource/Items.Count can be zero even
-- while that native ListBoxItem is rendered and selectable.
local function AutoFindRenderedSpellSubtab(selector)
    local root=FindWidget('CharacterLevelUp','CharacterLevelUp_c')
    if not root then return nil,nil,'native root missing' end
    local queue={{node=root,depth=0,levelup=false}}
    local nextNode=1
    local candidates={}
    while nextNode<=#queue and nextNode<=12500 do
        local e=queue[nextNode];nextNode=nextNode+1
        local node=e.node
        local name=tostring(Read(node,'Name') or '')
        local tag=tostring(Read(node,'Tag') or '')
        local inLevelup=e.levelup or name=='levelupTab' or tag=='levelup'
        if name=='subTabsSpellsList' then
            local itemData=nil
            local matched=false
            local seen={node}
            local pos=1
            while pos<=#seen and pos<=650 do
                local child=seen[pos];pos=pos+1
                local context=Read(child,'DataContext')
                if tostring(Read(context,'Type') or '')=='ls.VMSpellSelector' then
                    itemData=context
                    if AutoSameNoesisObject(context,selector) then
                        matched=true
                    end
                end
                local c=math.min(tonumber(Read(child,'VisualChildrenCount')) or 0,120)
                for i=1,c do
                    local ok,descendant=pcall(function() return child:VisualChild(i) end)
                    if ok and descendant then seen[#seen+1]=descendant end
                end
            end
            local items=Read(node,'ItemsSource') or Read(node,'Items')
            local count=AutoCollectionCount(items)
            local visible=Read(node,'IsVisible')==true
            local score=(matched and 1000 or 0)+(itemData and 300 or 0)
                +(inLevelup and 100 or 0)+(visible and 35 or 0)
                +(count>0 and 20 or 0)
            candidates[#candidates+1]={node=node,data=itemData,score=score,
                matched=matched,count=count,selected=Read(node,'SelectedIndex'),
                visible=visible,levelup=inLevelup,visual=#seen}
        end
        local n=math.min(tonumber(Read(node,'VisualChildrenCount')) or 0,120)
        for i=1,n do
            local ok,child=pcall(function() return node:VisualChild(i) end)
            if ok and child then queue[#queue+1]={node=child,depth=e.depth+1,levelup=inLevelup} end
        end
    end
    table.sort(candidates,function(a,b) return a.score>b.score end)
    local report={}
    for i,c in ipairs(candidates) do
        if i>8 then break end
        report[#report+1]=i..':score='..c.score..',matched='..tostring(c.matched)
            ..',item='..tostring(c.data~=nil)..',count='..c.count
            ..',index='..tostring(c.selected)..',visible='..tostring(c.visible)
            ..',levelup='..tostring(c.levelup)..',visual='..c.visual
    end
    local best=candidates[1]
    if not best or not best.data then
        return nil,nil,table.concat(report,';')
    end
    return best.node,best.data,table.concat(report,';')
end

-- Read the *existing* XAML MultiBinding result. Noesis can expose a
-- dependency property's effective value via GetProperty even when a Lua
-- field lookup returns nil. Never assemble a Lua substitute for this pair.
local function AutoSpellCommandParameter(button)
    local parameter=Read(button,'CommandParameter')
    if parameter~=nil then return parameter,'direct' end
    local ok,result=pcall(function() return button:GetProperty('CommandParameter') end)
    if ok and result~=nil then return result,'dependency' end
    return nil,ok and 'unbound' or 'property-unavailable'
end

-- A native Noesis collection is not a Lua table. BG3's original XAML
-- MultiBinding supplies an ordered selector/reference pair to SelectSpell.
-- Test whether the engine command accepts this independent native collection;
-- leave the level-up untouched if its CanExecute refuses the payload.
local nativeSpellPairTypeRegistered=false
local function AutoNativeSpellPair(selector,reference)
    if not nativeSpellPairTypeRegistered then
        local ok,err=pcall(function()
            Ext.UI.RegisterType('HB_AutoNativeSpellPair_v1',{
                Values={Type='Collection'}
            })
        end)
        if not ok then return nil,'register: '..tostring(err) end
        nativeSpellPairTypeRegistered=true
    end
    local ok,result=pcall(function()
        local holder=Ext.UI.Instantiate('HB_AutoNativeSpellPair_v1')
        local values=holder.Values
        values[1]=selector
        values[2]=reference
        return {Holder=holder,Values=values}
    end)
    if not ok then return nil,'create: '..tostring(result) end
    if not result or not result.Values or AutoCollectionCount(result.Values)~=2 then
        return nil,'native pair did not contain two objects'
    end
    -- Ext.UI.RegisterType Collection uses Lua-style *one-based* indexing.
    -- AutoCollectionItem is for BG3's zero-based native VM collections and
    -- would compare Values[1] twice, falsely rejecting every constructed pair.
    -- Noesis may return distinct Lua proxies for the same original object, so
    -- verify both native object slots exist and keep the engine CanExecute
    -- preflight as the authoritative test of the pair's validity.
    local first,second=Read(result.Values,1),Read(result.Values,2)
    if first==nil or second==nil then
        return nil,'native pair missing indexed selector or reference'
    end
    local firstType,secondType=Read(first,'Type'),Read(second,'Type')
    local selectorType,referenceType=Read(selector,'Type'),Read(reference,'Type')
    if firstType~=nil and selectorType~=nil and tostring(firstType)~=tostring(selectorType) then
        return nil,'native pair selector type mismatch'
    end
    if secondType~=nil and referenceType~=nil and tostring(secondType)~=tostring(referenceType) then
        return nil,'native pair reference type mismatch'
    end
    return result,nil
end

local function AutoFillNextSpell(native)
    local groups,status=AutoSpellStatus(native)
    if groups==0 then return false,'no native spell selector currently available' end
    local all=AutoSpellGroups(native)
    local needed={}
    local unresolved=0
    for _,entry in ipairs(all) do
        local selector=entry.selector
        local added=tonumber(Read(selector,'AddedCount'))
        local slots=AutoCollectionCount(Read(selector,'Additions'))
        if Read(selector,'IsComplete')~=true
            and (not added or slots==0 or added<slots) then
            unresolved=unresolved+1
            if AutoCollectionCount(Read(selector,'Available'))>0 then
                needed[#needed+1]=entry
            end
        end
    end
    if #needed==0 then
        if unresolved==0 then
            -- Native validity can update one or more UI frames after the
            -- last spell was accepted. Do not report a false failure here.
            return false,'native completion pending ('..status..')'
        end
        return false,'no eligible native spell group ('..status..')'
    end

    local subTabs,panels,buttons,mainTabs=AutoNativeSpellWidgets()
    local active=nil
    for _,panel in ipairs(panels or {}) do
        local ctx=Read(panel,'DataContext')
        for _,entry in ipairs(needed) do
            if AutoSameNoesisObject(ctx,entry.selector) then
                active=entry
                break
            end
        end
        if active then break end
    end
    -- With exactly one required group, the native engine-owned selector is
    -- unambiguous even when Lua wraps it in a different C++ proxy.
    if not active and #needed==1 then
        for _,panel in ipairs(panels or {}) do
            if tostring(Read(Read(panel,'DataContext'),'Type') or '')=='ls.VMSpellSelector' then
                active=needed[1]
                break
            end
        end
    end
    if not active then
        -- Open the genuine native spell subtab.  The earlier experiment
        -- assigned gameplaySubPanel.DataContext directly; that created the
        -- overlapping spell grid seen in-game and bypassed the tab actions
        -- which normally populate the SelectSpell command parameter.
        -- The tab owns its original game ViewModel and must make the change.
        if #needed~=1 then
            return false,'native spell tab is not unambiguous ('..status..')'
        end
        if not subTabs then
            return false,'native spell panel opening (spell tabs not mounted)'
        end
        local entry=needed[1]
        -- Selecting the summary's main levelupTab does not activate the
        -- visible Spells 0/2 sidebar entry. Prefer the actual ListBoxItem
        -- with a live VMSpellSelector DataContext, not an empty duplicate
        -- template. This reproduces BG3's normal subtab IsSelected trigger.
        local rendered,renderedData,report=AutoFindRenderedSpellSubtab(entry.selector)
        if not autoFill.visibleSpellSubtabReported then
            autoFill.visibleSpellSubtabReported=true
            Trace('AUTO_FILL_SPELL_VISIBLE_SUBTAB level='..tostring(lastLevel)
                ..' group='..entry.label..' candidates='..report)
        end
        if rendered and not autoFill.visibleSpellSubtabSelected then
            autoFill.visibleSpellSubtabSelected=true
            local before=Read(rendered,'SelectedIndex')
            local ok,err=pcall(function()
                rendered.SelectedItem=renderedData
            end)
            local after=Read(rendered,'SelectedIndex')
            -- Native ListBox.SelectedItem may use a different C++ proxy for
            -- the same selector. Only try SelectedIndex=0 if an actual
            -- native VMSpellSelector item was found in this specific list.
            if ok and (after==nil or tonumber(after)==-1) then
                ok,err=pcall(function() rendered.SelectedIndex=0 end)
                after=Read(rendered,'SelectedIndex')
            end
            Trace('AUTO_FILL_SPELL_VISIBLE_SELECT level='..tostring(lastLevel)
                ..' before='..tostring(before)..' after='..tostring(after)
                ..' ok='..tostring(ok)..' error='..tostring(not ok and err or nil))
            if not ok then return false,'native visible spell tab refused selection' end
            return false,'native spell panel opening (visible spell subtab selected)'
        end
        -- When a matching rendered spell tab exists, inspect only that tab.
        -- Scanning the first generic subTabsSpellsList selected an empty
        -- template even though Spells 0/2 was visible in the sidebar.
        if rendered then subTabs=rendered end
        local items=Read(subTabs,'ItemsSource') or Read(subTabs,'Items')
        local tabCount=AutoCollectionCount(items)
        local wanted=nil
        for i=0,tabCount-1 do
            if AutoSameNoesisObject(AutoCollectionItem(items,i),entry.selector) then
                wanted=i
                break
            end
        end
        if wanted==nil and tabCount==1 then wanted=0 end
        -- The native main tab publishes the spell subtab ItemsSource via
        -- its existing XAML triggers. Never set ItemsSource directly: Noesis
        -- rejects BaseCollection here, and assigning gameplaySubPanel's
        -- DataContext directly also overlays the normal summary.
        if wanted==nil and tabCount==0 then
            if not autoFill.mainSpellTabRequested then
                autoFill.mainSpellTabRequested=true
                local ok,reason=AutoSelectMainSpellTab(mainTabs)
                if not ok then return false,'native main spell tab unavailable: '..reason end
                return false,'native spell panel opening (main tab selected)'
            end
            if not autoFill.lastPanelNote or generation-autoFill.lastPanelNote>=120 then
                autoFill.lastPanelNote=generation
                Trace('AUTO_FILL_SPELL_MAIN_NATIVE_WAIT level='..tostring(lastLevel)
                    ..' mainSelectedTag='..tostring(Read(Read(mainTabs,'SelectedItem'),'Tag'))
                    ..' spellItems='..tostring(tabCount)
                    ..' selectorCount='..tostring(AutoCollectionCount(Read(Read(native,'ClassProgressionDetails'),'SpellSelectors'))))
            end
            return false,'native spell panel opening (awaiting native subtabs)'
        end
        if wanted==nil then
            return false,'native spell panel opening (selector tab not available)'
        end
        local selected=tonumber(Read(subTabs,'SelectedIndex'))
        if selected~=wanted and autoFill.nativeSpellTabSelected~=entry.label then
            autoFill.nativeSpellTabSelected=entry.label
            local ok,err=pcall(function()
                subTabs.SelectedIndex=-1
                subTabs.SelectedIndex=wanted
            end)
            Trace('AUTO_FILL_SPELL_NATIVE_TAB_SELECT level='..tostring(lastLevel)
                ..' group='..entry.label
                ..' target='..tostring(wanted)
                ..' previous='..tostring(selected)
                ..' ok='..tostring(ok)
                ..' error='..tostring(not ok and err or nil))
            if not ok then return false,'native spell tab selection failed: '..tostring(err) end
            return false,'native spell panel opening (native subtab selected)'
        end
        if not autoFill.lastPanelNote or generation-autoFill.lastPanelNote>=120 then
            autoFill.lastPanelNote=generation
            local ctx=panels and panels[1] and Read(panels[1],'DataContext')
            Trace('AUTO_FILL_SPELL_PANEL level='..tostring(lastLevel)
                ..' tabItems='..tabCount
                ..' tabSelected='..tostring(Read(subTabs,'SelectedIndex'))
                ..' panelType='..tostring(Read(ctx,'Type'))
                ..' panelButtons='..#buttons)
        end
        return false,'native spell panel opening (waiting for native tab context)'
    end
    if #buttons==0 then
        return false,'native spell panel opening (selected '..active.label..', buttons=0)'
    end
    local command=Read(native,'SelectSpell')
    if not command then return false,'native SelectSpell command unavailable' end
    local considered,withParameter,executable=0,0,0
    local boundPropertyCount=0
    local sampleType=nil
    for _,button in ipairs(buttons) do
        considered=considered+1
        local parameter,parameterSource=AutoSpellCommandParameter(button)
        if not sampleType then
            local data=Read(button,'DataContext')
            sampleType=tostring(Read(data,'Type') or 'unknown')
        end
        if parameter~=nil and Read(button,'IsEnabled')~=false then
            withParameter=withParameter+1
            if parameterSource=='dependency' then boundPropertyCount=boundPropertyCount+1 end
            -- Use the actual tile's bound command if present. Both the command
            -- and its PassThroughConverter parameter are supplied by BG3.
            local bound=Read(button,'Command') or command
            local canOk,can=pcall(function() return bound:CanExecute(parameter) end)
            if canOk and can==true then
                executable=executable+1
                local before=tonumber(Read(active.selector,'AddedCount')) or 0
                local done,err=pcall(function() bound:Execute(parameter) end)
                Trace('AUTO_FILL_SPELL_NATIVE_SENT level='..tostring(lastLevel)
                    ..' group='..active.label..' buttons='..tostring(#buttons)
                    ..' before='..tostring(before)..' ok='..tostring(done)
                    ..' error='..tostring(not done and err or nil))
                if not done then return false,'native SelectSpell refused: '..tostring(err) end
                return true,{kind='spell',path=active.path,index=active.index,
                    before=before,groupName=active.label,started=generation}
            end
        end
    end
    -- After the confirmed failed direct/dependency-property reads, test one
    -- native two-object collection as an ICommand parameter. Never use a Lua
    -- table or bypass CanExecute, and never report success before AddedCount
    -- advances. This path does not write any native UI properties.
    if withParameter==0 and not autoFill.nativePairChecked then
        autoFill.nativePairChecked=true
        local available=Read(active.selector,'Available')
        local candidateCount=math.min(AutoCollectionCount(available),12)
        local made,canRun=0,0
        local firstError=nil
        for index=0,candidateCount-1 do
            local spell=AutoCollectionItem(available,index)
            if spell then
                local pair,err=AutoNativeSpellPair(active.selector,spell)
                if pair then
                    made=made+1
                    local canOk,can=pcall(function() return command:CanExecute(pair.Values) end)
                    if canOk and can==true then
                        canRun=canRun+1
                        local before=tonumber(Read(active.selector,'AddedCount')) or 0
                        local done,executeErr=pcall(function() command:Execute(pair.Values) end)
                        Trace('AUTO_FILL_SPELL_NATIVE_PAIR_SENT level='..tostring(lastLevel)
                            ..' group='..active.label..' candidate='..index
                            ..' before='..before..' ok='..tostring(done)
                            ..' error='..tostring(not done and executeErr or nil))
                        if not done then return false,'native pair command refused: '..tostring(executeErr) end
                        return true,{kind='spell',path=active.path,index=active.index,
                            before=before,groupName=active.label,started=generation}
                    elseif not firstError then
                        firstError=canOk and 'CanExecute=false' or tostring(can)
                    end
                elseif not firstError then firstError=err end
            end
        end
        Trace('AUTO_FILL_SPELL_NATIVE_PAIR_PROBE level='..tostring(lastLevel)
            ..' group='..active.label..' candidates='..candidateCount
            ..' built='..made..' accepted='..canRun
            ..' firstError='..tostring(firstError))
    end
    if not autoFill.lastParameterNote or generation-autoFill.lastParameterNote>=120 then
        autoFill.lastParameterNote=generation
        Trace('AUTO_FILL_SPELL_NATIVE_PARAMETERS level='..tostring(lastLevel)
            ..' group='..active.label..' buttons='..tostring(considered)
            ..' bound='..tostring(withParameter)..' dependency='..tostring(boundPropertyCount)
            ..' executable='..tostring(executable)..' firstContext='..tostring(sampleType))
    end
    -- The selected native subtab can materialize tiles before its MultiBinding
    -- finishes producing the two-object command argument. Keep the level-up
    -- open for a bounded settling window; do not force an incomplete finish.
    if withParameter==0 and generation-autoFill.started<240 then
        return false,'native spell panel opening (awaiting bound command parameters)'
    end
    Trace('AUTO_FILL_SPELL_NATIVE_NO_EXECUTABLE level='..tostring(lastLevel)
        ..' group='..active.label..' buttons='..tostring(considered)
        ..' withParameter='..tostring(withParameter)
        ..' executable='..tostring(executable))
    return false,'native spell tiles provided no executable command parameters'
end

local function AutoSelectorStatus(native)
    local parts={}
    for _,name in ipairs({'ClassPassives','SubClassPassives','ClassAndSubClassPassives'}) do
        local collection=Read(native,name)
        for index=0,AutoCollectionCount(collection)-1 do
            local group=AutoCollectionItem(collection,index)
            if group then
                parts[#parts+1]=name..'['..index..']='..
                    tostring(Read(group,'SelectedPassiveCount'))..'/'..
                    tostring(Read(group,'MaxSelectedPassiveCount'))
            end
        end
    end
    parts[#parts+1]='feats='..AutoCollectionCount(Read(native,'SelectableFeats'))
    local progression=Read(native,'ClassProgressionDetails')
    parts[#parts+1]='spellSelectors='..
        AutoCollectionCount(Read(progression,'SpellSelectors'))
    local spellCount=AutoSpellStatus(native)
    parts[#parts+1]='nativeSpellGroups='..spellCount
    return table.concat(parts,',')
end
local function AutoFillStop(model,reason)
    Trace('AUTO_FILL_STOP level='..tostring(lastLevel)
        ..' reason='..tostring(reason))
    autoFill=nil
    if model then
        model.HB_Busy=false
        model.HB_CanApply=true
        model.HB_Status='BG3 could not automatically finish this level: '..tostring(reason)
    end
end
local function AutoFillNextPassive(native)
    local cmd=Read(native,'TogglePassive')
    if not cmd then return false,'native TogglePassive unavailable' end
    -- ClassPassives and ClassAndSubClassPassives can reference the *same*
    -- selector. Re-read selection counts each pass, and perform ONE click only.
    for _,name in ipairs({'ClassPassives','SubClassPassives','ClassAndSubClassPassives'}) do
        local groups=Read(native,name)
        for index=0,AutoCollectionCount(groups)-1 do
            local group=AutoCollectionItem(groups,index)
            local selected=tonumber(Read(group,'SelectedPassiveCount'))
            local maximum=tonumber(Read(group,'MaxSelectedPassiveCount'))
            if selected and maximum and maximum>selected and maximum>0 then
                local passives=Read(group,'Passives')
                for optionIndex=0,AutoCollectionCount(passives)-1 do
                    local option=AutoCollectionItem(passives,optionIndex)
                    local active=tonumber(Read(option,'Value')) or 0
                    if option and active<0.5 and Read(option,'Enabled')==true
                        and Read(option,'Blocked')~=true and Read(option,'Replaced')~=true then
                        local ok,can=pcall(function() return cmd:CanExecute(option) end)
                        if ok and can==true then
                            local done,err=pcall(function() cmd:Execute(option) end)
                            if not done then
                                return false,'native TogglePassive refused: '..tostring(err)
                            end
                            Trace('AUTO_FILL_PASSIVE_SENT level='..tostring(lastLevel)
                                ..' group='..name..'['..index..']'
                                ..' option='..optionIndex..' selected='..selected..'/'..maximum)
                            return true,{group=group,before=selected,started=generation,
                                groupName=name,index=index,optionIndex=optionIndex}
                        end
                    end
                end
                return false,'no executable choice in '..name..'['..index..']'
            end
        end
    end
    return false,'no eligible passive group ('..AutoSelectorStatus(native)..')'
end
local function AutoFillStep(native,model)
    if not autoFill then return end
    if Read(native,'IsLevelUpComplete')==true then
        Trace('AUTO_FILL_NATIVE_COMPLETE level='..tostring(lastLevel)
            ..' clicks='..tostring(autoFill.clicks))
        autoFill=nil
        if lastActor and not pending and not finishingHandoff then Request(model,'Apply') end
        return
    end
    if autoFill.waiting then
        local wait=autoFill.waiting
        if wait.kind=='spell' then
            local selector=AutoSpellGroupAt(native,wait.path,wait.index)
            local count=tonumber(Read(selector,'AddedCount')) or 0
            if (selector and count>wait.before) or Read(selector,'IsComplete')==true then
                Trace('AUTO_FILL_SPELL_CONFIRMED level='..tostring(lastLevel)
                    ..' group='..wait.groupName..' selected='..count)
                autoFill.waiting=nil
                return
            end
            if generation-wait.started<96 then return end
            AutoFillStop(model,'native spell selection was not acknowledged by BG3')
            return
        end
        local currentGroup=AutoCollectionItem(Read(native,wait.groupName),wait.index) or wait.group
        local count=tonumber(Read(currentGroup,'SelectedPassiveCount'))
        if count and count>wait.before then
            Trace('AUTO_FILL_PASSIVE_CONFIRMED level='..tostring(lastLevel)
                ..' group='..wait.groupName..'['..wait.index..']'
                ..' selected='..count)
            autoFill.waiting=nil
            return
        end
        if generation-wait.started<96 then return end
        AutoFillStop(model,'passive selection was not acknowledged by BG3')
        return
    end
    if autoFill.clicks>=32 then
        AutoFillStop(model,'too many temporary selections')
        return
    end
    local ok,details=AutoFillNextPassive(native)
    if not ok and tostring(details):find('no eligible passive group',1,true) then
        ok,details=AutoFillNextSpell(native)
        if not ok and generation-autoFill.started<720 then
            -- Wait for BG3 to instantiate the actual spell tab and its buttons.
            if tostring(details):find('native spell panel opening',1,true)
                or tostring(details):find('native completion pending',1,true)
                or tostring(details):find('no native spell selector',1,true) then return end
        end
    end
    if not ok then
        AutoFillStop(model,details);return
    end
    autoFill.clicks=autoFill.clicks+1
    autoFill.waiting=details
    if model then model.HB_Status='Completing temporary BG3 selections automatically…' end
end
local function AutoFillStart(model)
    if not lastActor or not lastLevel then return end
    autoFill={level=lastLevel,actor=lastActor,clicks=0,started=generation}
    applyWhenComplete=false
    if model then
        model.HB_Busy=false
        model.HB_Status='Completing temporary BG3 selections automatically…'
    end
    Trace('AUTO_FILL_START level='..tostring(lastLevel)
        ..' actor='..lastActor..' selectors='..AutoSelectorStatus(Native()))
end
local function Bind(vm)
    vm.HB_BoundLevel=lastLevel or 0
    vm.HB_BoundActor=lastActor or ''
    vm.HB_Visible=true;vm.HB_Open=false;vm.HB_SaveMode=false;vm.HB_LoadMode=false
    vm.HB_Name='';vm.HB_Status='';vm.HB_Assigned='No build assigned'
    vm.HB_CanApply=false;vm.HB_CanLoad=false;vm.HB_CanDelete=false
    vm.HB_CanSave=true;vm.HB_SaveLabel='Save';vm.HB_DialogTitle='Build Presets'
    vm.HB_Busy=false;vm.HB_Selected=-1
    vm.HB_OpenSave:SetHandler(function()
        local current=Live()
        if not current or pending then return end
        current.HB_Open=true;current.HB_SaveMode=true;current.HB_LoadMode=false
        current.HB_DialogTitle='Save Character Build'
        current.HB_Status='Save committed levels only.'
    end)
    vm.HB_OpenLoad:SetHandler(function()
        local current=Live()
        if not current or pending then return end
        -- The native Collection cannot safely be replaced with a Lua table.
        -- Instantiate a fresh typed VM on each open, so old rows are never retained.
        local _,host=Live()
        if not host then return end
        local ok,new=pcall(function()
            local replacement=Ext.UI.Instantiate('se::HB_LevelUpBuildVM_v1')
            Bind(replacement)
            replacement.HB_Assigned=tostring(Read(current,'HB_Assigned') or 'No build assigned')
            replacement.HB_CanApply=Read(current,'HB_CanApply')==true
            replacement.HB_Open=true;replacement.HB_SaveMode=false;replacement.HB_LoadMode=true
            replacement.HB_DialogTitle='Select Build'
            replacement.HB_Status='Choose a saved build to assign and apply.'
            host.DataContext=replacement
            return replacement
        end)
        if not ok then Trace('PICKER_REBIND_FAILED '..tostring(new));return end
        Discover(new)
    end)
    vm.HB_Close:SetHandler(function()
        local current=Live()
        if not current or pending then return end
        current.HB_Open=false;current.HB_SaveMode=false;current.HB_LoadMode=false
        current.HB_Status=Read(current,'HB_Assigned')~='No build assigned'
            and 'Applies saved choices through your available level.'
            or 'Select a build under Builds to apply its choices.'
        deleteArmed=nil
    end)
    vm.HB_Save:SetHandler(function()
        local current=Live()
        if not current or not Read(current,'HB_SaveMode') or pending then return end
        Request(current,'Save',{Name=tostring(Read(current,'HB_Name') or '')})
    end)
    vm.HB_SelectionChanged:SetHandler(function()
        local current=Live()
        if not current then return end
        local index=tonumber(Read(current,'HB_Selected'))
        local selected=not pending and index~=nil and index>=0
            and selectedFiles[index+1]~=nil or false
        current.HB_CanLoad=selected
        current.HB_CanDelete=selected
        deleteArmed=nil
    end)
    vm.HB_Load:SetHandler(function()
        local current=Live()
        if not current or not Read(current,'HB_LoadMode') or pending then return end
        local file=selectedFiles[(tonumber(Read(current,'HB_Selected')) or -1)+1]
        if file then Request(current,'Assign',{File=file}) end
    end)
    vm.HB_Delete:SetHandler(function()
        local current=Live()
        if not current or not Read(current,'HB_LoadMode') or pending then return end
        local file=selectedFiles[(tonumber(Read(current,'HB_Selected')) or -1)+1]
        if not file then return end
        if deleteArmed~=file then
            deleteArmed=file
            current.HB_Status='Select Delete again to hide this preset. The original JSON remains recoverable.'
            return
        end
        local ok,why=Files.Tombstone(DIR,file)
        if not ok then current.HB_Status=tostring(why);return end
        current.HB_Status='Preset hidden. Close and reopen the Builds menu to refresh the list.'
        selectedFiles[(tonumber(Read(current,'HB_Selected')) or -1)+1]=nil
        current.HB_CanDelete=false;current.HB_CanLoad=false
        deleteArmed=nil
        Trace('PRESET_HIDDEN file='..tostring(file))
    end)
    vm.HB_Apply:SetHandler(function()
        local current=Live()
        if not current or pending or finishingHandoff or Read(current,'HB_CanApply')~=true then return end
        local native=Native()
        -- Direct engine-owned level completion experiment: request the server
        -- to auto-level rather than staging temporary passives or spells.
        -- The server refuses unsafe target/party-level combinations.
        autoFill=nil;applyWhenComplete=false
        Trace('DIRECT_LEVEL_REQUEST target='..tostring(lastLevel)
            ..' nativeComplete='..tostring(Read(native,'IsLevelUpComplete')))
        Request(current,'Apply')
    end)
end
-- The overlay is part of the level-up state, not of the selected character.
-- Mount its ViewModel first; resolve a character afterward. In v1 both were
-- prerequisites, leaving an entirely invisible UI whenever the native character
-- proxy exposed no UUID. Do not guess a character or send a server command.
local function Poll()
    if not PartialRespecEnabled then
        Probe('disabled by PartialRespecEnabled')
        return
    end
    local native=Native()
    local widget=FindWidget('HB_LevelUpBuild','HB_LevelUpBuild_c')
    if not native or not widget then
        Probe('native='..tostring(native~=nil)..' overlay='..tostring(widget~=nil))
        if not native then lastNativeLevelProbe=nil end
        if not native and lastActor and lastLevel then
            local finishedActor=lastActor
            QueueMain(function()
                loneWolfChannel:SendToServer({Phase='NativeLevelUpClosed',Character=finishedActor})
            end)
        end
        if lastActor or lastLevel then
            Trace('SCREEN_CLOSED')
            lastActor=nil;lastLevel=nil;finishPending=false;pending=nil
            applyWhenComplete=false;finishingHandoff=false;autoFill=nil;lastNativeToken=nil
        end
        return
    end
    local nextLevel=tonumber(Read(native,'AvailableCharacterLevel'))
    local current=tonumber(Read(native,'CurrentCharacterLevel'))
    if not nextLevel or not current or nextLevel~=current+1 then
        Probe('native level not ready current='..tostring(current)..' target='..tostring(nextLevel))
        return
    end
    local nativeState=tostring(current)..'->'..tostring(nextLevel)
        ..' complete='..tostring(Read(native,'IsLevelUpComplete'))
        ..' step='..tostring(Read(native,'CurrentStep'))
    if lastNativeLevelProbe~=nativeState then
        lastNativeLevelProbe=nativeState
        Trace('NATIVE_LEVELUP_STATE '..nativeState)
    end
    local actor=Character(native)
    local nativeToken=tostring(native)
    local model=Read(widget,'DataContext')
    local attachedLevel=tonumber(Read(model,'HB_BoundLevel'))
    local attachedActor=tostring(Read(model,'HB_BoundActor') or '')
    if not model or attachedLevel~=nextLevel or nativeToken~=lastNativeToken
        or (actor and attachedActor~=actor) then
        lastNativeToken=nativeToken
        generation=generation+1
        lastActor=actor;lastLevel=nextLevel;pending=nil;finishPending=false
        applyWhenComplete=false;finishingHandoff=false;autoFill=nil
        local ok,created=pcall(function()
            Register()
            local newModel=Ext.UI.Instantiate('se::HB_LevelUpBuildVM_v1')
            Bind(newModel)
            if not actor then
                newModel.HB_Status='Waiting for BG3 character identification. Buttons will become available once identified.'
                newModel.HB_CanApply=false
            end
            widget.DataContext=newModel
            return newModel
        end)
        if not ok then
            Probe('BIND_ERROR level='..nextLevel..' reason='..tostring(created))
            return
        end
        model=created
        Probe('BOUND level='..current..'->'..nextLevel..' actor='..tostring(actor or 'unresolved'))
        -- ls.Character in the level-up ViewModel does not expose an EntityUuid.
        -- Ask the server to resolve its current controlled character, check
        -- ownership and level, and return the verified GUID before enabling actions.
        Request(model,'State')
        if not actor then
            local owner=Read(native,'LevelUpCharacter')
            local keys={}
            if Ext.Types and Ext.Types.GetObjectProperties and owner then
                local good,props=pcall(Ext.Types.GetObjectProperties,owner)
                if good and type(props)=='table' then
                    for key in pairs(props) do keys[#keys+1]=tostring(key) end
                    table.sort(keys)
                end
            end
            Trace('ACTOR_FIELDS type='..tostring(Read(owner,'Type'))
                ..' keys='..table.concat(keys,','))
        end
    else
        lastLevel=nextLevel
        if actor then lastActor=actor end
        Probe('ACTIVE level='..current..'->'..nextLevel..' actor='..tostring(actor or 'unresolved'))
    end
    if autoFill and not pending and not finishingHandoff then
        if autoFill.level~=lastLevel or autoFill.actor~=lastActor then
            AutoFillStop(model,'character or level changed')
        else
            AutoFillStep(native,model)
        end
    end
    if applyWhenComplete and not pending and not finishingHandoff
        and lastActor and Read(native,'IsLevelUpComplete')==true then
        applyWhenComplete=false
        Trace('QUEUED_CHOICES_COMPLETE level='..tostring(lastLevel))
        Request(model,'Apply')
    end
    if model and Read(model,'HB_LoadMode')==true and not pending then
        local index=tonumber(Read(model,'HB_Selected'))
        model.HB_CanLoad=index~=nil and index>=0 and selectedFiles[index+1]~=nil or false
        if not model.HB_CanLoad then model.HB_CanDelete=false end
    end
end

-- Compare the replicated character level against the authoritative server
-- after its guarded recovery. No gameplay components or UI state are changed.
local function ClientLevelSyncProbe(message)
    local actor=tostring(message.Character or '')
    local worked,errorText=pcall(function()
        local live=Ext.Entity and Ext.Entity.Get and Ext.Entity.Get(actor)
        local eoc=tonumber(Read(Read(live,'EocLevel'),'Level'))
        local available=tonumber(Read(Read(live,'AvailableLevel'),'Level'))
        local rows=Read(Read(live,'Classes'),'Classes')
        local classes,total=0,0
        if rows then
            pcall(function()
                for _,row in pairs(rows) do
                    classes=classes+1
                    total=total+(tonumber(Read(row,'Level')) or 0)
                end
            end)
        end
        local historyRows=Read(Read(live,'CCLevelUp'),'LevelUps')
        local history=nil
        if historyRows then
            local success,count=pcall(function() return #historyRows end)
            if success then history=count end
        end
        local health=Read(live,'Health')
        local hp=tonumber(Read(health,'Hp'))
        local maxHp=tonumber(Read(health,'MaxHp'))
        Trace('CLIENT_LEVEL_SYNC actor='..actor
            ..' clientHp='..tostring(hp)..'/'..tostring(maxHp)
            ..' serverHp='..tostring(message.ServerHp)..'/'..tostring(message.ServerMaxHp)
            ..' afterMs='..tostring(message.AfterMs)
            ..' phase='..tostring(message.Phase or 'reconcile')
            ..' clientEntity='..tostring(live~=nil)
            ..' clientEoc='..tostring(eoc)
            ..' clientAvailable='..tostring(available)
            ..' clientClassCount='..classes
            ..' clientClassTotal='..total
            ..' clientHistory='..tostring(history)
            ..' serverEoc='..tostring(message.ServerLevel)
            ..' serverClasses='..tostring(message.ServerClassLevel)
            ..' serverHistory='..tostring(message.ServerHistory))
    end)
    if not worked then Trace('CLIENT_LEVEL_SYNC_ERROR actor='..actor
        ..' reason='..tostring(errorText)) end
end
channel:SetHandler(function(message)
    if type(message)~='table' then return end
    local operation=tostring(message.Operation or '')
    if operation=='LevelSyncProbe' then
        ClientLevelSyncProbe(message)
        return
    end
    if operation=='RestoreResult' then
        Trace('RESTORE_FINAL_RESPONSE success='..tostring(message.Success)
            ..' actor='..tostring(message.Character)
            ..' actualLevel='..tostring(message.ActualLevel)
            ..' target='..tostring(message.TargetLevel)
            ..' detail='..tostring(message.Status))
    end
    if message.Character and message.Character~=lastActor
        and not (operation=='State' and pending=='State' and lastActor==nil)
        and operation~='RestoreResult' then return end
    if message.TargetLevel and tonumber(message.TargetLevel)~=lastLevel
        and operation~='RestoreResult' then return end
    if not QueueUI(function()
    local vm=Live()
    if operation=='RestoreResult' then
        if message.Character~=lastActor
            or tonumber(message.TargetLevel)~=tonumber(lastLevel) then return end
        Trace('RESTORE_RESULT success='..tostring(message.Success)
            ..' actualLevel='..tostring(message.ActualLevel)
            ..' target='..tostring(message.TargetLevel)
            ..' detail='..tostring(message.Status))
        finishingHandoff=false;applyWhenComplete=false
        if vm then
            vm.HB_Busy=false
            vm.HB_Status=tostring(message.Status or '')
            vm.HB_CanApply=message.Success==true and Read(vm,'HB_Assigned')~='No build assigned'
        end
        return
    end
    if operation=='Failure' then
        Trace('ERROR '..tostring(message.Status))
        finishPending=false;finishingHandoff=false;applyWhenComplete=false
        pendingNativeExit=nil
        if vm then
            vm.HB_Status=tostring(message.Status);vm.HB_Busy=false
            vm.HB_CanApply=Read(vm,'HB_Assigned')~='No build assigned'
        end
        return
    end
    if pending~=operation then return end
    pending=nil
    Trace('RESULT op='..operation..' ok='..tostring(message.Success)
        ..' reason='..tostring(message.Status))
    if vm then vm.HB_Busy=false;vm.HB_Status=tostring(message.Status or '') end
    if message.Success~=true then
        if vm then vm.HB_CanApply=vm.HB_Assigned~='No build assigned' end
        return
    end
    if operation=='State' or operation=='Assign' then
        if operation=='State' and type(message.Character)=='string'
            and message.Character:match('^[%x%-]+$') and #message.Character==36 then
            lastActor=message.Character
            if vm then vm.HB_BoundActor=lastActor end
            Trace('ACTOR_VERIFIED actor='..lastActor..' level='..tostring(lastLevel))
        end
        if vm then
            vm.HB_Assigned=message.Name and message.Name~=''
                and ('Selected Build: '..message.Name) or 'No build assigned'
            vm.HB_CanApply=message.File~=nil and message.File~='' and not finishingHandoff
            vm.HB_Status=message.File~=nil and message.File~=''
                and 'Applies saved choices through your available level.'
                or 'Select a build under Builds to apply its choices.'
            if operation=='Assign' then vm.HB_Open=false end
        end
        if operation=='Assign' and vm then
            autoFill=nil;applyWhenComplete=false
            Trace('ASSIGNED_READY target='..tostring(lastLevel))
        end
    elseif operation=='Save' then
        if vm then vm.HB_Open=false end
    elseif operation=='Apply' then
        -- Acknowledge the guarded RequestAutoLevel attempt; do NOT execute
        -- FinishLevelUp on an incomplete native level-up ViewModel.
        finishingHandoff=true
        if vm then
            vm.HB_Open=false
            vm.HB_Busy=true
            vm.HB_CanApply=false
            vm.HB_Status='Asking BG3 to complete this level automatically…'
        end
        pendingNativeExit={actor=lastActor,target=lastLevel,injected=false,sent=false}
        Trace('DIRECT_LEVEL_NATIVE_EXIT_PENDING target='..tostring(lastLevel))
        RequestNativeExitForDirect()
    end
    end) then Trace('LEVELUP_RESPONSE_UI_UNAVAILABLE') end
end)
local uiPollQueued=false
local MenuScope=Ext.Require('Client/MenuScope.lua')
Ext.Events.Tick:Subscribe(function()
    -- No allocation and no empty-loop traversal on ordinary world ticks.
    -- Actions enqueue into a fresh table before the old batch runs, so work
    -- generated by a callback is still safely deferred to a future tick.
    if #mainThreadWork>0 then
        local work=mainThreadWork
        mainThreadWork={}
        for _,action in ipairs(work) do
            local ok,why=pcall(action)
            if not ok then Trace('MAIN_THREAD_ACTION_ERROR '..tostring(why)) end
        end
    end
    generation=generation+1
    -- Keep the original 24-tick cadence while a build handoff is active.
    -- Idle world monitoring needs only a 48-tick check, plus the existing
    -- 1800-tick nonstandard-page fallback inside the deferred worker.
    local active=lastActor or lastLevel or pending or pendingNativeExit
    -- No level-up UI work at all in normal exploration. The shared lightweight
    -- page sampler detects native level-up; active handoffs retain full cadence.
    -- An explicit compatibility flag can re-enable deep fallback scans for
    -- atypically nested third-party level-up interfaces.
    local fallback = _G.HB_EnableNestedMenuFallback == true and generation%1800==0
    if generation%24==0 and (active or MenuScope.MaybeOpen('LevelUp') or fallback)
        and not uiPollQueued then
        uiPollQueued=true
        if not QueueUI(function()
            uiPollQueued=false
            -- Normal level-up pages are direct ContentRoot children, so the
            -- cheap scope check is sufficient outside a level-up. Keep a much
            -- rarer full probe for nonstandard deeply nested modded layouts.
            if not (lastActor or lastLevel or pending or pendingNativeExit)
                and not MenuScope.IsOpen('LevelUp')
                and not (_G.HB_EnableNestedMenuFallback == true and generation%1800==0) then
                return
            end
            local ok,why=pcall(Poll)
            if not ok then Trace('POLL_ERROR '..tostring(why)) end
            if pendingNativeExit then
                local okay,errorText=pcall(RequestNativeExitForDirect)
                if not okay then Trace('DIRECT_LEVEL_NATIVE_EXIT_ERROR '..tostring(errorText)) end
            end
        end) then uiPollQueued=false end
    end
end)
Trace('READY')
