-- HomeBrew equipment menu for initial character creation.
local Catalog=Ext.Require('Shared/StartingGearCatalog.lua')
local Preview=Ext.Require('Client/StartingGearPreview.lua')
local Gear={}
local SLOT='HB_StartingGearSlot_v4'
local ITEM='HB_StartingGearItem_v4'
local state={owner=nil,open=false,slot=1,item=1,choices={},status='',warning='',source=nil,waiting=false,refresh=false}
local request=nil
local availableCache={}
local iconCache={}
local channel=Ext.Net.CreateChannel(ModuleUUID,'HBStartingEquipment')
local ticket=0
local function Read(object,key)
    if not object then return nil end
    local ok,value=pcall(function() return object[key] end)
    if ok then return value end
end
-- Resolve item labels opportunistically, away from the shared preset UI constructor.
-- Failure or missing localization must not interfere with appearance or equipment controls.
local nameCache = {}
local nameAttempts = {}
local nameRetryAt = {}
local nameDiag = {'HomeBrew equipment item-name lookup v2'}
local nameDiagCount=0
local nameDiagDirty=false
local function LocalName(stat, fallback)
    return nameCache[stat] or fallback
end
-- Item templates may expose translated strings as Lua values or native wrapper proxies.
-- Resolve only when the menu is open, and leave a label intact if the engine
-- does not expose a usable translated string for a particular installed item.
-- Display-only weight labels for every starting chest piece in HomeBrew.
-- Robes/clothing count as Light (L), regardless of vanilla clothing rules.
-- This map follows the StartingGearItems catalogue; equipment grants are unchanged.
local chestArmorGrade={
    ['Armour_NoValue_1']='L', -- Studded Leather
    ['Armour_NoValue_2']='M', -- Scale Mail
    ['Armour_NoValue_3']='H', -- Chain Mail
    ['Armour_NoValue_4']='M', -- Chain Shirt
    ['Armour_NoValue_5']='L', -- Robe
    ['Armour_NoValue_6']='L', -- Leather Armour
    ['Armour_NoValue_7']='L', -- Padded Armour
    ['Armour_NoValue_8']='L', -- Leather Armour
    ['Armour_NoValue_9']='M', -- Scale Mail
    ['Armour_NoValue_10']='M', -- Scale Mail
    ['Armour_NoValue_11']='M', -- Hide Armour
    ['Armour_NoValue_12']='L', -- Leather Armour
    ['Armour_NoValue_13']='L', -- Padded Armour
    ['Armour_NoValue_14']='H', -- Ring Mail
    ['Armour_NoValue_15']='L', -- Robe
    ['Armour_NoValue_16']='M', -- Scale Mail
    ['Armour_NoValue_17']='L', -- Robe
    ['Armour_NoValue_18']='L', -- Robe
    ['Armour_NoValue_19']='H', -- Ring Mail
    ['Armour_NoValue_20']='L', -- Studded Leather
}
local function DisplayChoice(slotID,stat,fallback)
    local label=LocalName(stat,fallback)
    if slotID~='Chest' or stat=='' then return label end
    local grade=chestArmorGrade[stat]
    return grade and (label..' ('..grade..')') or label
end
local function TryString(value)
    if value==nil then return nil end
    local ok,result=pcall(tostring,value)
    if ok and type(result)=='string' then return result end
end
local function HandleFrom(value,depth,visited)
    if value==nil or depth>9 then return nil end
    local asString=TryString(value)
    if asString then
        local handle=asString:match('(h[%da-fgA-FG]+)')
        if handle and #handle>=30 then return handle end
    end
    if type(value)~='table' and type(value)~='userdata' then return nil end
    if visited[value] then return nil end
    visited[value]=true
    for _,key in ipairs({'Handle','Value','Text','String','DisplayName','LocalizedString','TranslatedString','TextHandle','Name','Id'}) do
        local inner=Read(value,key)
        if inner~=nil and not rawequal(inner,value) then
            local handle=HandleFrom(inner,depth+1,visited)
            if handle then return handle end
        end
    end
end
local function ValidTranslation(text,handle)
    if type(text)~='string' then return nil end
    text=text:gsub('[%c]',' '):match('^%s*(.-)%s*$')
    if text=='' or #text>150 or text==handle or text:find('s_HandleUnknown',1,true)
        or text:find('TranslatedStringRepository',1,true) or (text:match('^h[%da-fgA-FG]+$') and #text>=30) then return nil end
    return text
end
local function NameFromHandle(value)
    if value==nil then return nil end
    local handle=HandleFrom(value,0,{})
    if not handle and Ext.Types and type(Ext.Types.Serialize)=='function' then
        local ok,serialized=pcall(Ext.Types.Serialize,value)
        if ok and serialized~=nil then handle=HandleFrom(serialized,0,{}) end
    end
    if handle and Ext.Loca and type(Ext.Loca.GetTranslatedString)=='function' then
        local ok,translated=pcall(Ext.Loca.GetTranslatedString,handle,handle)
        if ok then return ValidTranslation(translated,handle),handle end
    end
    local raw=TryString(value)
    if raw and not (raw:match('^[hH][%da-fgA-FG]+$') and #raw>=30) and not raw:find('ls::',1,true)
       and not raw:find('TranslatedString',1,true) and not raw:find('table:',1,true)
       and not raw:find('userdata:',1,true) and not raw:find('0x[%da-f]+') then
        return ValidTranslation(raw,nil),handle
    end
    return nil,handle
end
local function ResolveName(stat)
    local root=Catalog.RootTemplate(stat)
    local reason=root and 'root='..tostring(root) or 'no-stat-root'
    if root and Ext.Template then
        local visited={}
        for _=1,12 do
            if type(root)~='string' or #root~=36 or visited[root] then break end
            visited[root]=true
            local template=nil
            for _,method in ipairs({'GetRootTemplate','GetTemplate'}) do
                local getter=Read(Ext.Template,method)
                if type(getter)=='function' then
                    local ok,result=pcall(getter,root)
                    if ok and result then template=result;break end
                end
            end
            if not template then reason='template-missing '..root;break end
            local display=Read(template,'DisplayName')
            local name,handle=NameFromHandle(display)
            if name then return name end
            if handle then reason='untranslated='..handle
            elseif display==nil then reason='displayname-missing '..root
            else reason='displayname-unrecognized '..tostring(type(display))..' '..tostring(TryString(display)):sub(1,80) end
            root=Read(template,'ParentTemplateId')
            if root~=nil then root=tostring(root) end
        end
    elseif not Ext.Template then
        reason='template-API-unavailable'
    end
    local current=stat
    for _=1,12 do
        if type(current)~='string' or current=='' then break end
        local ok,stats=pcall(Ext.Stats.Get,current)
        if not ok or not stats then break end
        local name=NameFromHandle(Read(stats,'DisplayName'))
        if name then return name end
        local parent=Read(stats,'Using')
        if not parent or tostring(parent)==current then break end
        current=tostring(parent)
    end
    return nil,reason
end
local function RecordNameResult(stat,result)
    if nameDiagCount>=130 then return end
    nameDiagCount=nameDiagCount+1
    nameDiag[#nameDiag+1]=stat..' = '..(result or 'UNRESOLVED')
    nameDiagDirty=true
end
local function FlushNameDiagnostics()
    if not nameDiagDirty then return end
    nameDiagDirty=false
    if Ext.IO and type(Ext.IO.SaveFile)=='function' then
        pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_EquipmentNames.txt',table.concat(nameDiag,'\n'))
    end
end
-- Prepare all installed item names without touching the shared appearance UI model.
-- Resolve small batches while character creation is active, and finish any
-- remaining lookups before the equipment list is first made visible.
local allNameStats={}
do
    local seen={}
    for _,slot in ipairs(Catalog.Slots) do
        for _,item in ipairs(slot.items) do
            local stat=item[2]
            if type(stat)=='string' and stat~='' and not seen[stat] then
                seen[stat]=true
                allNameStats[#allNameStats+1]=stat
            end
        end
    end
end
local function WarmNames(now,limit,force)
    local attempted=0
    for _,stat in ipairs(allNameStats) do
        if attempted>=limit then break end
        if not nameCache[stat] and (nameAttempts[stat] or 0)<3 and
            (force or now>=(nameRetryAt[stat] or 0)) then
            local ok,name,why=pcall(ResolveName,stat)
            local count=(nameAttempts[stat] or 0)+1
            nameAttempts[stat]=count
            if ok and type(name)=='string' and name~='' then
                nameCache[stat]=name
                RecordNameResult(stat,name)
            else
                if count==3 then
                    RecordNameResult(stat,'UNRESOLVED ('..tostring(ok and why or name)..')')
                end
                nameRetryAt[stat]=now+2200
            end
            attempted=attempted+1
        end
    end
    -- Write diagnostics once at menu opening, not on every CC update.
    if force then FlushNameDiagnostics() end
end
-- The local client may see more than one definition in initial multiplayer
-- creation, or no replicated definition yet. Zero is an explicit *staging*
-- request: the server must independently prove that initial creation is active
-- and ultimately grant only to the authenticated sending user's owned avatar.
local SOURCE_DIAG='HomeBrew/Diagnostics/HB_StartingEquipment_Client.txt'
local sourceDiag={'HomeBrew initial creation equipment source v5'}
local lastSourceSignature=nil
local function SourceTrace(text)
    if text==lastSourceSignature then return end
    lastSourceSignature=text
    sourceDiag[#sourceDiag+1]=text
    if #sourceDiag>75 then table.remove(sourceDiag,2) end
    pcall(Ext.IO.SaveFile,SOURCE_DIAG,table.concat(sourceDiag,'\n')..'\n')
end
local function Source()
    if not Ext.Entity or type(Ext.Entity.GetAllEntitiesWithComponent)~='function' then
        SourceTrace('CLIENT_SOURCE missing entity API; server must independently validate staging')
        return 0
    end
    local ok,definitions=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCharacterDefinition')
    local okRoots,roots=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCreation')
    local defs=ok and type(definitions)=='table' and #definitions or -1
    local rootsCount=okRoots and type(roots)=='table' and #roots or -1
    if defs==1 and rootsCount==1 then
        local source=definitions[1]
        local valid,netID=pcall(function() return source:GetNetId() end)
        if valid and type(netID)=='number' and netID>0 then
            SourceTrace('CLIENT_SOURCE unique definition; netID='..tostring(netID))
            return netID
        end
    end
    SourceTrace('CLIENT_SOURCE multiplayer/pending definition; definitions='..tostring(defs)
        ..' roots='..tostring(rootsCount)..' source=0 (server-authorized staging)')
    return 0
end
local function Send(kind,slot,stat)
    local source=state.source or Source()
    if not source then
        state.warning='Equipment selection is not available until your creation character is ready.'
        state.status='The starting equipment service cannot identify this creation session yet.'
        return false
    end
    state.source=source
    ticket=ticket+1
    local ok,err=pcall(function()
        channel:SendToServer({Kind=kind,Source=source,Request=ticket,Slot=slot,Stat=stat})
    end)
    if not ok then state.warning='Unable to confirm this equipment selection.';state.status='Cannot contact starting equipment service: '..tostring(err);return false end
    state.waiting=true
    state.sentAt=Ext.Timer.MonotonicTime()
    state.status='Checking equipment selection…'
    return true
end
channel:SetHandler(function(message)
    if type(message)~='table' or message.Kind~='Result' or message.Source~=state.source then return end
    if message.Request~=ticket then return end
    state.waiting=false
    state.status=tostring(message.Detail or '')
    if message.Success==false and state.pending then
        state.warning=tostring(message.Detail or 'Equipment selection was refused.')
        state.choices[state.pending.Slot]=state.pending.Previous
    end
    if message.Success==true and state.pending then
        state.warning=''
        Preview.Choose(state.pending.Slot,state.choices[state.pending.Slot])
    end
    state.pending=nil
    state.refresh=true
end)
function Gear.Reset()
    Preview.Reset()
    Preview.Reset()
    if state.source and next(state.choices) then Send('Close') end
    state={owner=nil,open=false,slot=1,item=1,choices={},status='',warning='',source=nil,waiting=false,refresh=false}
    request=nil
end
function Gear.Owner(page)
    local owner=tostring(page)
    if owner~=state.owner then Gear.Reset();state.owner=owner end
end
function Gear.Install(fields)
    Ext.UI.RegisterType(SLOT,{Name={Type='String'},Choice={Type='String',Notify=true}})
    Ext.UI.RegisterType(ITEM,{Name={Type='String',Notify=true},Detail={Type='String'},Icon={Type='String'}})
    for name,definition in pairs({
        HB_Gear_Visible={Type='Bool',Notify=true},HB_Gear_Open={Type='Bool',Notify=true},
        HB_Gear_SlotIndex={Type='Int32',Notify=true},HB_Gear_ItemIndex={Type='Int32',Notify=true},
        HB_Gear_SlotTitle={Type='String',Notify=true},HB_Gear_Status={Type='String',Notify=true},
        HB_Gear_Warning={Type='String',Notify=true},
        HB_Gear_Slots={Type='Collection'},HB_Gear_Items={Type='Collection'},
        HB_FooterEnabled={Type='Bool',Notify=true},
        HB_Gear_Show={Type='Command'},HB_Gear_Close={Type='Command'},
        HB_Gear_Select={Type='Command'},HB_Gear_Reset={Type='Command'},
    }) do fields[name]=definition end
end
local function Options(slot)
    local result={{'Default',''}}
    for _,row in ipairs(slot.items) do
        local eligible=availableCache[row[2]]
        if eligible==nil then
            eligible=Catalog.Available(row[2]) and Catalog.RootTemplate(row[2])~=nil
            availableCache[row[2]]=eligible
        end
        if eligible then result[#result+1]=row end
    end
    return result
end
function Gear.Populate(vm)
    local slot=Catalog.Slots[state.slot]
    local options=Options(slot)
    if state.item>#options then state.item=1 end
    vm.HB_Gear_Open=state.open
    vm.HB_Gear_Visible=false
    vm.HB_Gear_SlotIndex=state.slot-1
    vm.HB_Gear_ItemIndex=state.item-1
    vm.HB_Gear_SlotTitle=slot.name
    vm.HB_Gear_Status=state.status
    vm.HB_Gear_Warning=state.warning or ''
    for _,entry in ipairs(Catalog.Slots) do
        local row=Ext.UI.Instantiate(SLOT)
        row.Name=entry.name
        row.Choice='Default'
        for _,option in ipairs(entry.items) do
            if state.choices[entry.id]==option[2] then row.Choice=DisplayChoice(entry.id,option[2],option[1]);break end
        end
        vm.HB_Gear_Slots[#vm.HB_Gear_Slots+1]=row
    end
    for _,entry in ipairs(options) do
        local row=Ext.UI.Instantiate(ITEM)
        row.Name=DisplayChoice(slot.id,entry[2],entry[1])
        row.Detail=entry[2]~='' and 'Standard equipment' or 'Keep original class equipment'
        row.Icon=''
        if entry[2]~='' then
            local icon=iconCache[entry[2]]
            if icon==nil then
                icon=''
                local ok,stats=pcall(Ext.Stats.Get,entry[2])
                if ok and stats then
                    local found,value=pcall(function() return stats.Icon end)
                    if found and type(value)=='string' then icon=value end
                end
                iconCache[entry[2]]=icon
            end
            row.Icon=icon
        end
        vm.HB_Gear_Items[#vm.HB_Gear_Items+1]=row
    end
    for name,action in pairs({HB_Gear_Show='show',HB_Gear_Close='close',HB_Gear_Select='choose',HB_Gear_Reset='clear'}) do
        vm[name]:SetHandler(function() request=action end)
    end
end
function Gear.Process(vm,allowed,flowIndex,creationContext)
    if state.open and type(flowIndex)=='number' and type(state.openFlowIndex)=='number'
        and flowIndex~=state.openFlowIndex then
        state.open=false
        state.openFlowIndex=nil
        request=nil
        return true
    end
    if allowed then Preview.Update(Ext.Timer.MonotonicTime(), creationContext) end
    if allowed and not state.open then
        -- Never rebuild or mutate the shared appearance widget during prewarming.
        pcall(WarmNames,Ext.Timer.MonotonicTime(),#allNameStats,false)
    end
    local refresh=state.refresh
    state.refresh=false
    if state.waiting and state.sentAt and Ext.Timer.MonotonicTime()-state.sentAt>4500 then
        if state.pending then state.choices[state.pending.Slot]=state.pending.Previous end
        state.waiting=false;state.pending=nil
        state.warning='Equipment selection could not be confirmed.'
        state.status='Equipment selection was not confirmed; the previous choice was restored.'
        refresh=true
    end
    if not allowed then
        request=nil
        if state.open then state.open=false;state.openFlowIndex=nil;return true end
        return refresh
    end
    if not vm then return refresh end
    local index=Read(vm,'HB_Gear_SlotIndex')
    if state.open and type(index)=='number' and index%1==0 and index>=0
        and index<#Catalog.Slots and index~=state.slot-1 then
        state.slot=index+1;state.item=1;request=nil
        state.warning=''
        local current=Catalog.Slots[state.slot]
        local chosen=state.choices[current.id]
        if chosen then
            for i,option in ipairs(Options(current)) do
                if option[2]==chosen then state.item=i;break end
            end
        end
        return true
    end
    local options=Options(Catalog.Slots[state.slot])
    local item=Read(vm,'HB_Gear_ItemIndex')
    if state.open and type(item)=='number' and item%1==0 and item>=0 and item<#options then
        state.item=item+1
    end
    local action=request;request=nil
    if action=='show' then
        -- All names are resolved before NewVM populates the visible list.
        -- Fail-closed localization must never block the menu from opening.
        pcall(WarmNames,Ext.Timer.MonotonicTime(),#allNameStats,true)
        state.warning=''
        state.open=true
        state.openFlowIndex=flowIndex
        state.source=Source()
        state.status=state.source and 'Choose a slot and item to update your starting equipment.' or
            'Selections are staged for your player; gear is granted after character creation finishes.'
        return true
    end
    if action=='close' then state.open=false;state.openFlowIndex=nil;state.warning='';return true end
    if not state.open or state.waiting then return refresh end
    if action=='clear' or action=='choose' then
        local slot=Catalog.Slots[state.slot]
        local selected=nil
        if action=='choose' then selected=options[state.item] end
        if action=='choose' and not selected then return refresh end
        local stat=selected and selected[2] or ''
        local choices={}
        for id,value in pairs(state.choices) do choices[id]=value end
        choices[slot.id]=stat~='' and stat or nil
        local conflict=Catalog.Conflict(choices)
        if conflict then state.warning=conflict;state.status=conflict;return true end
        state.warning=''
        local original=state.choices[slot.id]
        state.choices=choices
        state.pending={Slot=slot.id,Previous=original}
        if not Send('Set',slot.id,stat) then
            state.choices[slot.id]=original
            state.pending=nil
        end
        if action=='clear' then state.item=1 end
        return true
    end
    return refresh
end
function Gear.IsOpen() return state.open end
return Gear
