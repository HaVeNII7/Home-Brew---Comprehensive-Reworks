-- HomeBrew armour appearance inspection for Magic Mirror testing.
-- Read-only rendered-visual inspection after server-owned same-item equipment refresh.
-- The client NEVER overwrites desired visual IDs, render IDs, or reload flags.
local Probe={}
local channel=Ext.Net.CreateChannel(ModuleUUID,'HBTransmogProbe')
local request=0
local waiting=false
local pendingKind=nil
local status=''
local report='HomeBrew/Diagnostics/HB_TransmogProbe.json'
-- Compare the installed item's race-specific visual map against live rendered IDs.
-- Never overwrite character visual state: inspect UI and ECS read-only on explicit clicks.
local LIVE_REPORT='HomeBrew/Diagnostics/HB_TransmogLiveVisuals.json'
local liveHistory={Version=9,Kind='HomeBrewChestMirrorCandidateReadback',Snapshots={},ClientRequests={},NetworkEvents={},EngineRequests={}}
local manualInspections=0
local expectedReadback=nil
local function SafeRead(obj,key)
    if obj==nil then return nil end
    local ok,value=pcall(function() return obj[key] end)
    if ok then return value end
end
local function SafeComponent(entity,name)
    if not entity then return nil end
    local ok,result=pcall(function() return entity:GetComponent(name) end)
    if ok then return result end
end
local function SafeString(value)
    if value==nil then return nil end
    local ok,result=pcall(tostring,value)
    if ok and type(result)=='string' then return result:sub(1,150) end
end
local function Shape(value,limit)
    if value==nil then return {Present=false} end
    local obj={Present=true,Type=type(value)}
    local ok,serialized=pcall(function() return Ext.Types.Serialize(value) end)
    if not ok or type(serialized)~='table' then
        obj.Text=SafeString(value)
        return obj
    end
    local keys={}
    for key in pairs(serialized) do keys[#keys+1]=tostring(key) end
    table.sort(keys)
    obj.Keys={}
    for i=1,math.min(#keys,limit or 25) do obj.Keys[i]=keys[i] end
    return obj
end
-- Never serialize an entire live VisualData/native proxy graph. Bound each
-- piece to a handful of small scalar fields for diagnosing partial overlays.
local function Compact(value,depth)
    if depth>3 then return '[depth]' end
    local valueType=type(value)
    if valueType=='string' then return value:sub(1,160) end
    if valueType=='number' or valueType=='boolean' then return value end
    if valueType~='table' then
        local ok,serialized=pcall(function() return Ext.Types.Serialize(value) end)
        if not ok or type(serialized)~='table' then return SafeString(value) end
        value=serialized
    end
    local result,amount={},0
    for key,item in pairs(value) do
        amount=amount+1
        if amount>14 then result._truncated=true;break end
        local keyType=type(key)
        if keyType=='string' or keyType=='number' then
            local k=tostring(key):sub(1,80)
            if type(item)=='string' or type(item)=='number' or type(item)=='boolean' or type(item)=='table' then
                result[k]=Compact(item,depth+1)
            else
                local ok,serialized=pcall(function() return Ext.Types.Serialize(item) end)
                if ok and type(serialized)=='table' then result[k]=Compact(serialized,depth+1)
                else result[k]=SafeString(item) end
            end
        end
    end
    return result
end
local function ReadGUIDs(value)
    if not value then return nil end
    local ok,values=pcall(function() return Ext.Types.Serialize(value) end)
    if not ok or type(values)~='table' then return nil end
    local ids={}
    for i=1,math.min(#values,12) do ids[i]=SafeString(values[i]) end
    return ids
end
local function SlotVisualSummary(slots,name,slotKey)
    local native=slotKey and SafeRead(slots,slotKey) or nil
    local slot=native or SafeRead(slots,name)
    if not slot then return nil end
    local data=SafeRead(slot,'VisualData')
    return {
        Loaded=SafeRead(slot,'Loaded'),
        Item=SafeString(SafeRead(slot,'Item')),
        Templates=ReadGUIDs(SafeRead(data,'VisualTemplates')),
        SubVisuals=Compact(SafeRead(slot,'SubVisuals'),0),
        Slot=SafeString(SafeRead(data,'Slot')),
        HairType=SafeString(SafeRead(data,'HairType')),
        VisualFlags=SafeString(SafeRead(data,'VisualFlags')),
        RequestFlags=SafeString(SafeRead(data,'RequestFlags')),
    }
end
local function UniqueClientAvatar()
    if not Ext.Entity or not Ext.Entity.GetAllEntitiesWithComponent then return nil end
    local ok,entities=pcall(Ext.Entity.GetAllEntitiesWithComponent,'UserAvatar')
    if not ok or type(entities)~='table' then return nil end
    local chosen,count=nil,0
    for _,entity in ipairs(entities) do
        if SafeComponent(entity,'ClientEquipmentVisuals') and SafeComponent(entity,'ClientCharacter') then
            count=count+1
            chosen=entity
        end
    end
    return count==1 and chosen or nil
end
local function CaptureLive(stage,character,item)
    local record={Stage=stage,Character=character,Item=item}
    local entity=nil
    if character and Ext.Entity and Ext.Entity.Get then
        local ok,found=pcall(Ext.Entity.Get,character)
        if ok then entity=found end
    end
    if not entity then
        entity=UniqueClientAvatar()
        record.UsedUniqueAvatarFallback=entity~=nil
    end
    if not entity then
        record.Reason='Client gameplay avatar unavailable or ambiguous'
        return record
    end
    local uuid=SafeComponent(entity,'Uuid')
    record.ActualCharacter=SafeString(SafeRead(uuid,'EntityUuid'))
    local visuals=SafeComponent(entity,'ClientEquipmentVisuals')
    if not visuals then
        record.Reason='Character does not expose ClientEquipmentVisuals'
        return record
    end
    record.VisualComponent=Shape(visuals,25)
    local equipped=SafeRead(visuals,'Equipment')
    record.Equipment=Shape(equipped,30)
    local slotKey=Ext.Enums and Ext.Enums.ItemSlot and SafeRead(Ext.Enums.ItemSlot,'Breast')
    local slot=slotKey and SafeRead(equipped,slotKey)
    if not slot then slot=SafeRead(equipped,'Breast') end
    -- Inspect other visible equipment slots in addition to the chest. This
    -- distinguishes a replaced chest visual from a duplicate/layered visual
    -- attached to underwear, cloak, or another slot after reopening Mirror.
    record.SlotVisuals={}
    for _,name in ipairs({'Breast','Underwear','CampBreast','Helmet','Cloak','Gloves','Boots'}) do
        local key=Ext.Enums and Ext.Enums.ItemSlot and SafeRead(Ext.Enums.ItemSlot,name)
        local summary=SlotVisualSummary(equipped,name,key)
        if summary then record.SlotVisuals[name]=summary end
    end
    record.ChestSlotFound=slot~=nil
    if slot then
        record.ChestSlot=Shape(slot,25)
        record.ChestItem=SafeString(SafeRead(slot,'Item'))
        record.ChestLoaded=SafeRead(slot,'Loaded')
        record.ChestSubVisuals=Shape(SafeRead(slot,'SubVisuals'),20)
        record.ChestSubVisualDetails=Compact(SafeRead(slot,'SubVisuals'),0)
        local data=SafeRead(slot,'VisualData')
        record.ChestVisualData=Shape(data,25)
        if data then
            record.VisualDataItem=SafeString(SafeRead(data,'Item'))
            record.VisualDataSlot=SafeString(SafeRead(data,'Slot'))
            record.VisualTemplates=Shape(SafeRead(data,'VisualTemplates'),20)
            -- This is bounded and contains GUIDs only, never native proxy snapshots.
            local names={}
            local templateList=SafeRead(data,'VisualTemplates')
            if templateList then
                local ok,serialized=pcall(Ext.Types.Serialize,templateList)
                if ok and type(serialized)=='table' then
                    for i=1,math.min(12,#serialized) do names[i]=SafeString(serialized[i]) end
                end
            end
            record.VisualTemplateIDs=names
        end
    end
    local desiredComponent=SafeComponent(entity,'ClientVisualsDesiredState')
    local desiredSlots=SafeRead(desiredComponent,'Slots')
    local desiredChest=SafeRead(desiredSlots,slotKey) or SafeRead(desiredSlots,'Breast')
    if desiredChest then
        local ids=nil
        -- Capture native fixed-string IDs; do not retain ephemeral game-object proxies.
        local ok,values=pcall(Ext.Types.Serialize,SafeRead(desiredChest,'VisualTemplates'))
        if ok and type(values)=='table' then
            ids={}
            for i=1,math.min(#values,12) do ids[i]=SafeString(values[i]) end
        end
        record.DesiredVisualTemplateIDs=ids
        record.DesiredChestDetails=Compact(desiredChest,0)
    end
    return record
end
-- Manual-action-only discovery of the entity that MAY render the Magic Mirror
-- character. The previous logs proved that gameplay UserAvatar visual-template
-- arrays become empty across *all* equipped slots on mirror re-entry.
-- No selected entity is assumed, no native proxy graph is serialized, and no
-- component, item, appearance property, or UI ViewModel is modified.
local function QueryComponent(name)
    if not Ext.Entity or type(Ext.Entity.GetAllEntitiesWithComponent)~='function' then
        return nil,'Component query not available'
    end
    local ok,entities=pcall(Ext.Entity.GetAllEntitiesWithComponent,name)
    if not ok or type(entities)~='table' then return nil,'Component query failed' end
    return entities
end
local function SafeLength(value)
    if value==nil then return 0 end
    local ok,count=pcall(function() return #value end)
    return ok and type(count)=='number' and count or 0
end
-- Snapshot both the live render graph and the separate native desired-state graph.
-- Neither indicates by itself which meshes the GPU draws; the two are compared
-- only so that a delayed native visual rebuild is not misclassified as success.
local function BriefVisualActor(entity,source)
    local result={Source=source,Handle=SafeString(entity)}
    local uuid=SafeComponent(entity,'Uuid')
    result.UUID=SafeString(SafeRead(uuid,'EntityUuid'))
    local visual=SafeComponent(entity,'ClientEquipmentVisuals')
    result.HasClientEquipmentVisuals=visual~=nil
    result.HasClientCharacter=SafeComponent(entity,'ClientCharacter')~=nil
    result.HasUserAvatar=SafeComponent(entity,'UserAvatar')~=nil
    result.HasCharacterVisual=SafeComponent(entity,'CharacterVisual')~=nil
    result.HasClientCCDummy=SafeComponent(entity,'ClientCCDummy')~=nil
    local desired=SafeComponent(entity,'ClientVisualsDesiredState')
    result.HasClientVisualsDesiredState=desired~=nil
    local equipment=SafeRead(visual,'Equipment')
    local desiredSlots=SafeRead(desired,'Slots')
    for _,name in ipairs({'Breast','Underwear','CampBreast'}) do
        local key=Ext.Enums and Ext.Enums.ItemSlot and SafeRead(Ext.Enums.ItemSlot,name)
        local summary=SlotVisualSummary(equipment,name,key)
        local desiredSlot=SafeRead(desiredSlots,key) or SafeRead(desiredSlots,name)
        if summary or desiredSlot then
            result.Slots=result.Slots or {}
            local slot={}
            if summary then
                slot.Item=summary.Item
                slot.Loaded=summary.Loaded
                slot.Templates=summary.Templates
                local native=SafeRead(equipment,key) or SafeRead(equipment,name)
                slot.SubVisualCount=SafeLength(SafeRead(native,'SubVisuals'))
                slot.VisualFlags=summary.VisualFlags
                slot.RequestFlags=summary.RequestFlags
                -- A matching Item handle is evidence of an ordinary equipment
                -- reference; a self-reference may instead be a visual proxy.
                slot.ItemReferencesOwner=(slot.Item~=nil and slot.Item==result.Handle)
            end
            if desiredSlot then
                slot.DesiredTemplates=ReadGUIDs(SafeRead(desiredSlot,'VisualTemplates'))
                slot.DesiredSlot=SafeString(SafeRead(desiredSlot,'Slot'))
                slot.DesiredRequestFlags=SafeString(SafeRead(desiredSlot,'RequestFlags'))
            end
            result.Slots[name]=slot
        end
    end
    return result
end
local function BriefVMRef(obj)
    if obj==nil then return nil end
    local out={Type=type(obj),Display=SafeString(obj)}
    -- Never walk/serialize the bound native UI object or any descendants.
    for _,name in ipairs({'EntityUuid','Uuid','Guid','UUID','CharacterId','CharacterUUID',
        'Character','Entity','Id','Handle','Name','IsCreation','IsInitialized','IsLocked'}) do
        local value=SafeRead(obj,name)
        if value~=nil then
            local kind=type(value)
            if kind=='string' or kind=='number' or kind=='boolean' then
                out[name]=kind=='string' and value:sub(1,100) or value
            elseif name~='Character' and name~='Entity' then
                out[name..'Type']=kind
            end
        end
    end
    return out
end
local function CaptureMirrorCandidates(page,context)
    local diag={ReadOnly=true,Trigger='User-clicked Inspect / Preview / Restore',
        MirrorPage=BriefVMRef(page),MirrorContext=BriefVMRef(context),
        VMReferences={},EntitySources={},Candidates={}}
    for _,name in ipairs({'CurrentPlayer','CurrentCharacter','Character','CharacterEntity',
        'SelectedCharacter','CharacterDefinition','CurrentCharacterDefinition',
        'CurrentOrigin','SelectedOrigin','CharacterCreationStep','PreviewCharacter'}) do
        local obj=SafeRead(context,name)
        if obj~=nil then diag.VMReferences[name]=BriefVMRef(obj) end
    end
    local seen={}
    local function Include(entity,source)
        if not entity or #diag.Candidates>=14 then return end
        local key=SafeString(entity) or tostring(entity)
        if seen[key] then return end
        seen[key]=true
        diag.Candidates[#diag.Candidates+1]=BriefVisualActor(entity,source)
    end
    local function ResolveReference(ref)
        if ref==nil then return nil end
        -- An Ext.Entity handle proxy may expose GetComponent directly.
        local ok,member=pcall(function() return ref.GetComponent end)
        if ok and type(member)=='function' then return ref end
        if Ext.Entity and Ext.Entity.Get then
            local valid,entity=pcall(Ext.Entity.Get,ref)
            if valid then return entity end
        end
    end
    local roots,rootErr=QueryComponent('CCCreation')
    local definitions,defErr=QueryComponent('CCCharacterDefinition')
    local dummies,dummyErr=QueryComponent('ClientCCDummyDefinition')
    diag.EntitySources.CCCreation={Count=roots and #roots or nil,Error=rootErr}
    diag.EntitySources.CCCharacterDefinition={Count=definitions and #definitions or nil,Error=defErr}
    diag.EntitySources.ClientCCDummyDefinition={Count=dummies and #dummies or nil,Error=dummyErr}
    -- A native CC root -> definition -> ClientCCDummyDefinition.Dummy is the
    -- only authoritative link we know from the existing HomeBrew mannequin.
    -- Mirror may use a separate mechanism; if so, report it without guessing.
    local selectedDefs={}
    if roots and #roots==1 then
        local creation=SafeComponent(roots[1],'CCCreation')
        local references=SafeRead(creation,'CharacterDefinitions')
        diag.EntitySources.CCCreation.References={}
        for i=1,math.min(8,SafeLength(references)) do
            local ref=SafeRead(references,i)
            diag.EntitySources.CCCreation.References[i]=SafeString(ref)
            if definitions then
                for j=1,math.min(#definitions,12) do
                    if tostring(definitions[j])==tostring(ref) then
                        selectedDefs[tostring(definitions[j])]=true
                    end
                end
            end
        end
    end
    local function InspectDefinition(def,origin,isActive)
        local cc=SafeComponent(def,'ClientCCDummyDefinition')
        local dummyRef=SafeRead(cc,'Dummy')
        local entry={Definition=SafeString(def),Origin=origin,
            LinkedToUniqueCCRoot=isActive,HasClientCCDummyDefinition=cc~=nil,
            DummyReference=SafeString(dummyRef)}
        diag.EntitySources.Definitions=diag.EntitySources.Definitions or {}
        if #diag.EntitySources.Definitions<12 then
            diag.EntitySources.Definitions[#diag.EntitySources.Definitions+1]=entry
        end
        if dummyRef then Include(ResolveReference(dummyRef),origin..'.Dummy') end
    end
    if definitions then
        for i=1,math.min(#definitions,12) do
            local def=definitions[i]
            if selectedDefs[tostring(def)] then
                InspectDefinition(def,'CCCreation.LinkedDefinition',true)
            end
        end
        for i=1,math.min(#definitions,12) do
            local def=definitions[i]
            if not selectedDefs[tostring(def)] then
                InspectDefinition(def,'CCCharacterDefinition.UnlinkedCandidate',false)
            end
        end
    end
    if dummies then
        for i=1,math.min(#dummies,10) do
            if #diag.Candidates>=14 then break end
            local def=dummies[i]
            local direct=SafeComponent(def,'ClientCCDummyDefinition')
            Include(ResolveReference(SafeRead(direct,'Dummy')),'ClientCCDummyDefinition.Dummy')
        end
    end
    local actors,actorErr=QueryComponent('ClientEquipmentVisuals')
    diag.EntitySources.ClientEquipmentVisuals={Count=actors and #actors or nil,
        Error=actorErr,Scanned=0,Limit=192}
    if actors then
        local source=diag.EntitySources.ClientEquipmentVisuals
        for i=1,math.min(#actors,192) do
            source.Scanned=i
            local entity=actors[i]
            -- Relevant/rare entities only, not every ordinary NPC in the area.
            -- Non-UUID entities may be the creation preview; log at most 14.
            if (not SafeComponent(entity,'Uuid') or
                SafeComponent(entity,'UserAvatar') or SafeComponent(entity,'ClientCCDummy')) then
                Include(entity,'ClientEquipmentVisuals.PossiblePreview')
            end
        end
        source.Truncated=#actors>192
    end
    -- Correlate candidate visual IDs only against the saved original item
    -- and the verified preview/restore request. Never infer render ownership.
    local requested=expectedReadback and expectedReadback.ids or nil
    if type(requested)=='table' then
        diag.RequestedChestVisualTemplateIDs=requested
        for _,candidate in ipairs(diag.Candidates) do
            local actual=candidate.Slots and candidate.Slots.Breast
            local rendered=actual and actual.Templates or nil
            local desired=actual and actual.DesiredTemplates or nil
            local function Matches(ids)
                if type(ids)~='table' or #ids~=#requested then return false end
                for i=1,#requested do if ids[i]~=requested[i] then return false end end
                return true
            end
            if rendered then candidate.MatchesRequestedRender=Matches(rendered) end
            if desired then candidate.MatchesRequestedDesired=Matches(desired) end
        end
    end
    return diag
end
local function SaveLive()
    if not (Ext.Json and Ext.Json.Stringify and Ext.IO and Ext.IO.SaveFile) then return end
    pcall(function()
        Ext.IO.SaveFile(LIVE_REPORT,Ext.Json.Stringify(liveHistory,{Beautify=true}))
    end)
end
local function RecordLive(stage,character,item,page,context)
    local ok,result=pcall(CaptureLive,stage,character,item)
    if ok and expectedReadback and character==expectedReadback.character
        and type(result)=='table' and type(result.VisualTemplateIDs)=='table' then
        local wanted=expectedReadback.ids
        if type(wanted)=='table' then
            local equal=#result.VisualTemplateIDs==#wanted
            if equal then
                for i=1,#wanted do if result.VisualTemplateIDs[i]~=wanted[i] then equal=false;break end end
            end
            result.MatchesExpectedChestVisualIDs=equal
            result.ExpectedChestVisualTemplateIDs=wanted
        end
    end
    -- Also check the native dummy and independent visual candidates at the
    -- existing one-shot server-response and delayed readback checkpoints.
    -- UI objects are only sampled on the original button click; no native
    -- Noesis userdata is retained into an asynchronous callback.
    if ok and type(result)=='table' then
        local inspected,mirror=pcall(CaptureMirrorCandidates,page,context)
        result.MirrorEntityDiscovery=inspected and mirror or {Error=tostring(mirror)}
    end
    liveHistory.Snapshots[#liveHistory.Snapshots+1]=ok and result or {Stage=stage,Error=tostring(result)}
    if #liveHistory.Snapshots>22 then table.remove(liveHistory.Snapshots,1) end
    SaveLive()
end
-- Only compare the source/donor installed template IDs to the pre-click
-- rendered IDs. No direct writes to ClientVisualsDesiredState/ClientEquipmentVisuals.
local function VisualIDs(value)
    if type(value)~='table' then return nil end
    local result={}
    for i=1,#value do
        local v=value[i]
        if type(v)~='string' or #v~=36 or not v:match('^[%da-fA-F%-]+$') then return nil end
        result[i]=v
    end
    return #result>0 and #result<=12 and result or nil
end
local function EqualIDs(a,b)
    if type(a)~='table' or type(b)~='table' or #a~=#b then return false end
    for i=1,#a do if a[i]~=b[i] then return false end end
    return true
end
local function ExpectedFromMaps(stage,info)
    local before=nil
    for i=#liveHistory.Snapshots,1,-1 do
        local entry=liveHistory.Snapshots[i]
        if entry.Stage=='Before '..stage then before=entry;break end
    end
    local old=before and before.VisualTemplateIDs
    if type(old)~='table' then return nil,'Before-click visual IDs missing' end
    local original=SafeRead(info,'OriginalVisuals')
    local donor=SafeRead(info,'DonorVisuals')
    if type(original)~='table' or type(donor)~='table' then
        return nil,'No donor maps in result'
    end
    local matchingRace=nil
    for race,map in pairs(original) do
        if EqualIDs(VisualIDs(map),old) then
            if matchingRace then return nil,'Multiple matching race maps' end
            matchingRace=race
        end
    end
    if not matchingRace then return nil,'No race map matched original rendered IDs' end
    return VisualIDs(donor[matchingRace]),'Selected verified race '..tostring(matchingRace)
end
local function RecordClientResult(stage,info)
    local refresh=SafeRead(info,'Refresh')
    local actor=UniqueClientAvatar()
    local owner=actor and SafeString(SafeRead(SafeComponent(actor,'Uuid'),'EntityUuid'))
    local character=SafeRead(info,'Character')
    local good=character~=nil and character==owner and type(refresh)=='table'
        and SafeRead(refresh,'Mode')=='SameInstanceUnequipEquip' and SafeRead(refresh,'Verified')==true
    local note=good and 'Server re-equipped same item; client is read-only' or 'Client owner/server equipment verification mismatch'
    local ids,why=nil,nil
    if good and stage=='ChestPreview' then ids,why=ExpectedFromMaps(stage,info) end
    if stage=='ChestRestore' then
        -- For a verified restore, the pre-preview original is remembered for comparison.
        ids=expectedReadback and expectedReadback.original or nil
        why='Expected original render after restoring cached map'
    end
    if good then
        local original=nil
        if stage=='ChestPreview' then
            for i=#liveHistory.Snapshots,1,-1 do
                local s=liveHistory.Snapshots[i]
                if s.Stage=='Before ChestPreview' then original=s.VisualTemplateIDs;break end
            end
        elseif expectedReadback then original=expectedReadback.original end
        expectedReadback={character=character,ids=ids,original=original}
    end
    local entry={Stage=stage,Mode='ServerSameItemEquipmentLifecycle',Success=good,
        Note=note,ServerRefresh=refresh,ExpectedReason=why,
        Character=character,Item=SafeRead(info,'Item'),ExpectedIDs=ids}
    liveHistory.ClientRequests[#liveHistory.ClientRequests+1]=entry
    if #liveHistory.ClientRequests>12 then table.remove(liveHistory.ClientRequests,1) end
    SaveLive()
    if good then
        local timer=SafeRead(SafeRead(Ext,'Timer'),'WaitFor')
        if type(timer)=='function' then
            local token=request
            for _,delay in ipairs({250,1000,2000}) do
                pcall(timer,delay,function()
                    if token==request then
                        RecordLive(tostring(delay)..'ms '..stage,character,SafeRead(info,'Item'))
                    end
                end)
            end
        else
            entry.DelayedReadback='Client timer unavailable'
        end
    end
    return good,note
end

local function RecordNetwork(kind,statusText,other)
    liveHistory.NetworkEvents[#liveHistory.NetworkEvents+1]={Kind=kind,Status=statusText,Detail=other}
    if #liveHistory.NetworkEvents>18 then table.remove(liveHistory.NetworkEvents,1) end
    SaveLive()
end
local function Store(data)
    if not Ext.Json or type(Ext.Json.Stringify)~='function' then return false end
    local ok,encoded=pcall(Ext.Json.Stringify,data,{Beautify=true,StringifyInternalTypes=false})
    if not ok or type(encoded)~='string' or not Ext.IO or not Ext.IO.SaveFile then return false end
    local saved,result=pcall(Ext.IO.SaveFile,report,encoded)
    return saved and result~=false
end
function Probe.Inspect(page,context)
    if waiting then return end
    -- A user-driven Inspect during the REOPENED Mirror is the critical sample.
    -- It must be captured before the request/any subsequent Restore click.
    manualInspections=manualInspections+1
    RecordLive('Manual Inspect '..tostring(manualInspections)..' (current Mirror)',nil,nil,page,context)
    request=request+1
    waiting=true
    pendingKind='Inspect'
    status='Inspecting equipped armour visuals…'
    local ok=pcall(function() channel:SendToServer({Kind='Inspect',Request=request}) end)
    if not ok then waiting=false;pendingKind=nil;status='Unable to reach the armour inspection service.' end
end
local function RequestChest(kind,page,context)
    if waiting then return end
    request=request+1
    waiting=true
    pendingKind=kind
    RecordLive('Before '..kind,nil,nil,page,context)
    status=kind=='ChestPreview' and 'Testing appearance with a one-time same-item chest refresh…'
        or 'Restoring original chest appearance…'
    local ok=pcall(function() channel:SendToServer({Kind=kind,Request=request}) end)
    RecordNetwork(kind,ok and 'Sent' or 'SendFailure','Request='..tostring(request))
    if not ok then
        waiting=false
        pendingKind=nil
        status='Unable to reach the chest visual test service.'
    end
end
function Probe.ChestPreview(page,context) RequestChest('ChestPreview',page,context) end
function Probe.ChestRestore(page,context) RequestChest('ChestRestore',page,context) end
function Probe.Status() return status end
channel:SetHandler(function(message)
    if type(message)~='table' or message.Kind~='InspectResult'
        or message.Request~=request or not waiting then return end
    local kind=pendingKind
    waiting=false
    pendingKind=nil
    if kind=='Inspect' then
        RecordLive('Manual Inspect '..tostring(manualInspections)..' (server reply)',nil,nil)
    end
    if kind=='Inspect' and message.Success==true and type(message.Data)=='table' then
        status=Store(message.Data) and 'Inspection saved to HB_TransmogProbe.json.'
            or 'Armour inspected, but the diagnostic file could not be saved.'
    else
        status=tostring(message.Notice or 'Armour inspection could not be completed.')
    end
    if kind=='ChestPreview' or kind=='ChestRestore' then
        local info=type(message.VisualInspection)=='table' and message.VisualInspection or {}
        RecordNetwork(kind,message.Success==true and 'ServerSuccess' or 'ServerRefused',
            tostring(message.Notice))
        if message.Success==true then
            local applied,note=RecordClientResult(kind,info)
            status=(applied and 'Equipment refresh verified; check chest appearance: ' or
                'Chest refresh not verified: ')..note
        else
            liveHistory.ClientRequests[#liveHistory.ClientRequests+1]={Stage=kind,Success=false,Note='Server refused visual operation'}
            SaveLive()
        end
        RecordLive('After '..kind,info.Character,info.Item)
        if Ext.OnNextTick then
            Ext.OnNextTick(function()
                RecordLive('Next tick '..kind,info.Character,info.Item)
            end)
        end
    end
end)
return Probe
