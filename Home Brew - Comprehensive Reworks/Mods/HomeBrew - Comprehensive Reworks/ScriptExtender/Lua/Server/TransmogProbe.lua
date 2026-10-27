-- HomeBrew armour appearance discovery. Read-only: never edits items, templates or actors.
local channel=Ext.Net.CreateChannel(ModuleUUID,'HBTransmogProbe')
local SLOTS={
    {id='Head',equip='Helmet'},
    {id='Cloak',equip='Cloak'},
    {id='Chest',equip='Breast'},
    {id='Gloves',equip='Gloves'},
    {id='Boots',equip='Boots'},
}
local REPORT='HomeBrew/Diagnostics/HB_TransmogProbe_Server.txt'
local function Read(value,key)
    if value==nil then return nil end
    local ok,result=pcall(function() return value[key] end)
    return ok and result or nil
end
local function Component(entity,name)
    if not entity then return nil end
    local ok,result=pcall(function() return entity:GetComponent(name) end)
    return ok and result or nil
end
local function UUID(entity)
    local component=Component(entity,'Uuid')
    return component and tostring(Read(component,'EntityUuid')) or nil
end
local function User(id)
    return type(id)=='number' and id-id%0x10000+1 or nil
end
local function Owned(entity,user)
    local uuid=UUID(entity)
    if not uuid or not Component(entity,'ServerCharacter') then return false end
    for _,field in ipairs({'UserAvatar','UserReservedFor'}) do
        local component=Component(entity,field)
        if component and User(Read(component,'UserID'))==User(user) then return true end
    end
    local ok,owner=pcall(Osi.GetReservedUserID,uuid)
    return ok and type(owner)=='number' and owner~=0 and User(owner)==User(user)
end
local function Avatar(user)
    if not User(user) then return nil end
    local ok,entities=pcall(Ext.Entity.GetAllEntitiesWithComponent,'UserAvatar')
    if not ok or type(entities)~='table' then return nil end
    local candidate,count=nil,0
    for _,entity in ipairs(entities) do
        if Owned(entity,user) then candidate,count=entity,count+1 end
    end
    return count==1 and candidate or nil
end
local function String(value)
    if value==nil then return nil end
    local ok,s=pcall(tostring,value)
    if ok and type(s)=='string' and #s<=220 then return s end
end
local function Sample(value,depth)
    if depth>3 then return '(nested)' end
    if type(value)=='string' then return #value<=200 and value or value:sub(1,200) end
    if type(value)=='number' or type(value)=='boolean' then return value end
    if type(value)~='table' then return String(value) or type(value) end
    local result,count={},0
    for key,entry in pairs(value) do
        if count>=12 then break end
        local label=tostring(key)
        if #label<=80 then
            result[label]=Sample(entry,depth+1)
            count=count+1
        end
    end
    return result
end
local function Shape(value)
    if value==nil then return {Available=false} end
    local shape={Available=true,Type=type(value)}
    if Ext.Types and type(Ext.Types.Serialize)=='function' then
        local ok,serial=pcall(Ext.Types.Serialize,value)
        if ok and type(serial)=='table' then
            local keys={}
            for key in pairs(serial) do keys[#keys+1]=tostring(key) end
            table.sort(keys)
            shape.Fields={}
            for i=1,math.min(#keys,50) do shape.Fields[i]=keys[i] end
            shape.Sample=Sample(serial,0)
        end
    end
    return shape
end
local function Root(item)
    local ok,value=pcall(Osi.GetTemplate,item)
    if not ok or type(value)~='string' then return nil end
    return value:match('([%da-fA-F]+%-[%da-fA-F]+%-[%da-fA-F]+%-[%da-fA-F]+%-[%da-fA-F]+)$')
end
local function Item(slot,character)
    local record={Slot=slot.id,EquipSlot=slot.equip,Equipped=false}
    local ok,item=pcall(Osi.GetEquippedItem,character,slot.equip)
    if not ok then record.Error='Equipment lookup unavailable';return record end
    if type(item)~='string' or not item:find('%x%x%x%x%x%x%x%x%-') then return record end
    record.Equipped=true
    record.Item=item
    record.RootTemplate=Root(item)
    if not record.RootTemplate then record.Error='Could not determine item template';return record end
    if not Ext.Template or type(Ext.Template.GetRootTemplate)~='function' then
        record.Error='Template API unavailable';return record
    end
    local got,template=pcall(Ext.Template.GetRootTemplate,record.RootTemplate)
    if not got or not template then record.Error='Installed root template unavailable';return record end
    record.TemplateName=String(Read(template,'TemplateName'))
    record.Stats=String(Read(template,'Stats'))
    record.VisualTemplate=String(Read(template,'VisualTemplate'))
    local equipment=Read(template,'Equipment')
    record.EquipmentShape=Shape(equipment)
    if equipment then
        record.VisualsShape=Shape(Read(equipment,'Visuals'))
        record.VisualSetShape=Shape(Read(equipment,'VisualSet'))
        record.SlotsShape=Shape(Read(equipment,'Slot'))
    end
    local entityOk,entity=pcall(Ext.Entity.Get,item)
    if entityOk and entity then
        local serverItem=Component(entity,'ServerItem')
        record.ServerItemAvailable=serverItem~=nil
        record.CacheTemplateMethod=serverItem and type(Read(serverItem,'CreateCacheTemplate'))=='function' or false
        record.ItemTemplateField=String(Read(serverItem,'Template'))
    end
    return record
end
local function Capture(user)
    local actor=Avatar(user)
    if not actor then return nil,'No unique player-owned gameplay avatar. The probe will not inspect another character.' end
    local character=UUID(actor)
    if not character then return nil,'The controlled avatar has no UUID.' end
    local result={Kind='HomeBrewTransmogInspection',Version=1,Character=character,Slots={},ReadOnly=true}
    for _,slot in ipairs(SLOTS) do
        result.Slots[#result.Slots+1]=Item(slot,character)
    end
    return result
end
local function Reply(user,request,success,notice,data,visualInspection)
    pcall(function() channel:SendToClient({Kind='InspectResult',Request=request,Success=success,
        Notice=notice,Data=data,VisualInspection=visualInspection},user) end)
end
-- v3: Safely call Osiris callable proxies; never rely on their Lua type.
-- No replacement item, item deletion, root-template change, or client ECS writes.
local experiment=nil
local TRANSLOG='HomeBrew/Diagnostics/HB_TransmogChest_Test.txt'
local loglines={'HomeBrew chest-only Osiris-proxy-safe equipment lifecycle experiment v3'}
local function Log(message)
    loglines[#loglines+1]=message
    if #loglines>65 then table.remove(loglines,2) end
    pcall(function() Ext.IO.SaveFile(TRANSLOG,table.concat(loglines,'\n')..'\n') end)
end
local function Serialize(object)
    if object==nil or not Ext.Types or type(Ext.Types.Serialize)~='function' then return nil end
    local ok,result=pcall(Ext.Types.Serialize,object)
    if ok and type(result)=='table' then return result end
end
local function HasEntries(data)
    return type(data)=='table' and next(data)~=nil
end
local function Fingerprint(obj,depth)
    if depth>6 then return '*' end
    if type(obj)~='table' then return tostring(obj) end
    local keys={}
    for k in pairs(obj) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    local parts={}
    for _,k in ipairs(keys) do parts[#parts+1]=tostring(k)..'='..Fingerprint(obj[k],depth+1) end
    return '{'..table.concat(parts,',')..'}'
end
local function EquipSource(stat)
    if not Ext.Stats or not Ext.Stats.Get or not Ext.Template then return nil end
    local name=stat
    for _=1,10 do
        local ok,entry=pcall(Ext.Stats.Get,name)
        if not ok or not entry then return nil end
        local root=Read(entry,'RootTemplate')
        if type(root)=='string' and root:match('^[%da-fA-F%-]+$') and #root==36 then
            local success,template=pcall(Ext.Template.GetRootTemplate,root)
            if success and template then
                local equip=Read(template,'Equipment')
                local visuals=Serialize(Read(equip,'Visuals'))
                local slots=Serialize(Read(equip,'Slot'))
                if HasEntries(visuals) and HasEntries(slots) and tostring(slots[1])=='Body' then
                    return {root=root,stat=stat,visuals=visuals}
                end
            end
            return nil
        end
        local parent=Read(entry,'Using')
        if type(parent)~='string' or parent=='' or parent==name then return nil end
        name=parent
    end
end
local SOURCES={'Armour_NoValue_5','Armour_NoValue_12','ARM_Leather_Body','ARM_Padded_Body'}
local function Target(user)
    local actor=Avatar(user)
    if not actor then return nil,'No unique player-owned gameplay avatar.' end
    local character=UUID(actor)
    if not character then return nil,'Player avatar UUID is unavailable.' end
    local ok,item=pcall(Osi.GetEquippedItem,character,'Breast')
    if not ok or type(item)~='string' or not item:find('%x%x%x%x%x%x%x%x%-') then
        return nil,'Equip chest armour before testing.'
    end
    local entityOk,entity=pcall(Ext.Entity.Get,item)
    local serverItem=entityOk and Component(entity,'ServerItem') or nil
    if not serverItem then return nil,'Equipped chest item is not accessible.' end
    local current=Read(serverItem,'Template')
    if not current or not Read(current,'Equipment') then
        return nil,'The chest item has no accessible equipment template.'
    end
    return {actor=character,item=item,entity=entity,serverItem=serverItem,current=current}
end
local function PreviewChest(user)
    if experiment then return false,'A chest preview is active. Restore it before starting another.' end
    local target,err=Target(user)
    if not target then return false,err end
    local originalVisuals=Serialize(Read(Read(target.current,'Equipment'),'Visuals'))
    if not HasEntries(originalVisuals) then return false,'Cannot capture original chest visuals.' end
    local oldSignature=Fingerprint(originalVisuals,0)
    local selected=nil
    for _,stat in ipairs(SOURCES) do
        local candidate=EquipSource(stat)
        if candidate and Fingerprint(candidate.visuals,0)~=oldSignature then
            selected=candidate
            break
        end
    end
    if not selected then return false,'No distinct installed chest appearance was available; nothing changed.' end
    if type(Read(target.serverItem,'CreateCacheTemplate'))~='function' then
        return false,'This Script Extender does not support per-item cache templates.'
    end
    local created,result=pcall(function() return target.serverItem:CreateCacheTemplate() end)
    if not created then
        Log('CACHE_CREATE_REFUSED '..tostring(result))
        return false,'Could not create an independent item template; no visuals changed.'
    end
    local cached=Read(target.serverItem,'Template')
    if tostring(Read(cached,'Stats'))~=tostring(Read(target.current,'Stats')) then
        Log('CACHE_STAT_GUARD_REFUSED chest item stats field changed while making cache')
        return false,'Cannot verify unchanged chest equipment stats; preview refused.'
    end
    local equipment=Read(cached,'Equipment')
    local map=Read(equipment,'Visuals')
    local before=Serialize(map)
    if not HasEntries(before) or Fingerprint(before,0)~=oldSignature then
        Log('CACHE_VALIDATION_REFUSED original_map_changed=true; result='..tostring(result))
        return false,'Unable to verify the isolated item template; preview refused.'
    end
    local applyOk,applyResult=pcall(Ext.Types.Unserialize,map,selected.visuals)
    local after=Serialize(map)
    local changed=HasEntries(after) and Fingerprint(after,0)==Fingerprint(selected.visuals,0)
    if not applyOk or applyResult==false or not changed then
        local undone=pcall(Ext.Types.Unserialize,map,before)
        Log('PREVIEW_REFUSED apply='..tostring(applyOk)..'; value='..tostring(applyResult)..'; verified='..tostring(changed)..'; rollback='..tostring(undone))
        return false,'The game did not accept a verified chest visual override; no transmog confirmed.'
    end
    experiment={user=User(user),item=target.item,character=target.actor,original=before,
        target=selected.stat,sourceTemplate=selected.root,signature=Fingerprint(selected.visuals,0),
        donorVisuals=selected.visuals}
    Log('PREVIEW_MAP_CHANGED item='..target.item..' original='..tostring(Root(target.item))
        ..' target='..selected.stat..' donor='..selected.root..'; stats/item not modified')
    return true,'Chest visual mapping changed to '..selected.stat..'. Check appearance; use Restore Chest (TEST).'
end
local function RestoreChest(user)
    if not experiment then return false,'No chest appearance test is active in this session.' end
    if experiment.user~=User(user) then return false,'Only the original player can restore this test.' end
    local target,err=Target(user)
    if not target then return false,err end
    if target.item~=experiment.item or target.actor~=experiment.character then
        return false,'Re-equip the original chest item before restoring its visual template.'
    end
    local map=Read(Read(Read(target.serverItem,'Template'),'Equipment'),'Visuals')
    local current=Serialize(map)
    if not HasEntries(current) or Fingerprint(current,0)~=experiment.signature then
        return false,'Chest visuals changed independently; refusing to overwrite them.'
    end
    local ok,result=pcall(Ext.Types.Unserialize,map,experiment.original)
    local now=Serialize(map)
    if not ok or result==false or Fingerprint(now,0)~=Fingerprint(experiment.original,0) then
        Log('RESTORE_FAILED '..tostring(ok)..' '..tostring(result))
        return false,'Chest appearance restore could not be verified. Reload the original test save.'
    end
    Log('RESTORED item='..target.item..' original visual mapping confirmed')
    experiment=nil
    return true,'Original chest visual mapping restored. Check the character model.'
end

-- The cached item-template map can change while the live equipment renderer stays
-- unchanged. Request the game's NORMAL equipment lifecycle for this SAME instance.
-- This is intentionally one-shot on button click, NEVER a polling/event listener.
local lifecycleBusy=false
local function Equipped(character)
    -- Osiris query results may be nil, an empty string, or a null UUID.
    -- Distinguish a legitimately empty slot from an unavailable query:
    -- after unequipping, silently interpreting a failed query as an empty
    -- slot could lead to equipping over somebody else's equipment.
    local ok,item=pcall(Osi.GetEquippedItem,character,'Breast')
    if not ok then return nil,false end
    if item==nil or item=='' or item=='00000000-0000-0000-0000-000000000000' then
        return nil,true
    end
    return item,true
end
local function Schedule(delay,cb)
    if not Ext.Timer or type(Ext.Timer.WaitFor)~='function' then return false end
    local ok,result=pcall(Ext.Timer.WaitFor,delay,cb)
    return ok and result~=false
end
local function UndoCachedMap()
    if not experiment then return true,'No active map' end
    local exp=experiment
    local got,entity=pcall(Ext.Entity.Get,exp.item)
    local serverItem=got and Component(entity,'ServerItem') or nil
    local map=Read(Read(Read(serverItem,'Template'),'Equipment'),'Visuals')
    if not map then return false,'Original item cache is unavailable; reload test save' end
    local existing=Serialize(map)
    if not HasEntries(existing) then return false,'Cached map is unreadable; reload test save' end
    if Fingerprint(existing,0)~=exp.signature then
        if Fingerprint(existing,0)==Fingerprint(exp.original,0) then
            experiment=nil
            return true,'Game already restored original map'
        end
        return false,'Other code changed the item visual map; reload test save'
    end
    local ok,result=pcall(Ext.Types.Unserialize,map,exp.original)
    local verified=ok and result~=false and Fingerprint(Serialize(map),0)==Fingerprint(exp.original,0)
    if verified then experiment=nil end
    return verified,verified and 'Original map restored' or 'Map restore was not verified; reload test save'
end
local function RefreshEquippedSameItem(character,item,stage,complete)
    -- Osi.* values are callable Osiris proxies, not Lua functions. Their type
    -- does NOT indicate whether an Osiris call exists. A previous type guard
    -- falsely refused every refresh before Unequip could run.
    if not Ext.Timer or type(Ext.Timer.WaitFor)~='function' then
        complete(false,'Equipment refresh timer unavailable; no item moved')
        return
    end
    -- Read-only preflight; no item is moved unless the equipped chest UUID
    -- can be verified through a successful Osiris query.
    local before,queryOk=Equipped(character)
    Log('CYCLE_PREFLIGHT stage='..stage..' query='..tostring(queryOk)
        ..' matchingItem='..tostring(before==item)
        ..' OsiEquipType='..tostring(type(Osi.Equip))
        ..' OsiUnequipType='..tostring(type(Osi.Unequip)))
    if not queryOk or before~=item then
        complete(false,'Original chest item could not be verified as equipped; no item moved')
        return
    end
    Log('CYCLE_START stage='..stage..' item='..item..' equipped=true')
    local un,err=pcall(Osi.Unequip,character,item)
    if not un or err==false then
        Log('CYCLE_UNEQUIP_ERROR '..tostring(err))
        complete(false,'Engine rejected unequip: '..tostring(err))
        return
    end
    local scheduled=Schedule(140,function()
        local current,readable=Equipped(character)
        if not readable then
            Log('CYCLE_UNEQUIP_QUERY_FAILED stage='..stage)
            complete(false,'Cannot verify the chest slot after unequip; reload disposable save')
            return
        end
        if current==item then
            Log('CYCLE_UNEQUIP_NOT_OBSERVED stage='..stage)
            complete(false,'Mirror/game did not unequip the chest item; reload disposable save if appearance is unusual')
            return
        end
        if current~=nil then
            Log('CYCLE_SLOT_OCCUPIED stage='..stage..' current='..tostring(current))
            complete(false,'Another chest item occupies the slot; original was not replaced')
            return
        end
        local got,entity=pcall(Ext.Entity.Get,item)
        if not got or not Component(entity,'ServerItem') then
            Log('CYCLE_ITEM_MISSING stage='..stage)
            complete(false,'Original chest instance cannot be verified; reload disposable save')
            return
        end
        -- ClearOriginalOwner=0: do not change ownership for a visual test.
        local eq,e=pcall(Osi.Equip,character,item,1,0,0)
        Log('CYCLE_REEQUIP stage='..stage..' dispatched='..tostring(eq)
            ..' error='..tostring(not eq and e or 'none'))
        if not eq or e==false then
            complete(false,'Original item re-equip raised an error; reload disposable save')
            return
        end
        if not Schedule(550,function()
            local final,verifiedQuery=Equipped(character)
            local valid=verifiedQuery and final==item
            Log('CYCLE_VERIFY stage='..stage..' query='..tostring(verifiedQuery)
                ..' sameItem='..tostring(valid)..' current='..tostring(final))
            complete(valid,valid and 'Original item re-equipped; engine visual rebuild can now be observed'
                or 'Original item was not verified re-equipped; recover it manually or reload disposable save')
        end) then
            complete(false,'Post-equip verification timer failed; reload disposable save')
        end
    end)
    if not scheduled then
        Log('CYCLE_TIMER_REFUSED stage='..stage)
        -- Unequip may already have happened; only a save reload guarantees
        -- that the complete original equipment state is restored.
        complete(false,'Equipment refresh timer unavailable after unequip; reload disposable save')
    end
end
local function VisualReply(character,item,stage,notice)
    local data={Character=character,Item=item,
        Refresh={Mode='SameInstanceUnequipEquip',Stage=stage,Verified=true,Note=notice}}
    if stage=='ChestPreview' and experiment then
        data.OriginalVisuals=experiment.original
        data.DonorVisuals=experiment.donorVisuals
    end
    return data
end

channel:SetHandler(function(message,user)
    if type(message)~='table' or type(message.Request)~='number' or type(user)~='number' then return end
    if message.Kind=='Inspect' then
        local ok,data,err=pcall(Capture,user)
        if not ok then err='Runtime inspection failed safely: '..tostring(data);data=nil end
        local success=type(data)=='table'
        local notice=success and 'Armour visuals inspected. See HB_TransmogProbe.json.' or tostring(err or 'Inspection unavailable.')
        pcall(Ext.IO.SaveFile,REPORT,'HomeBrew Transmog read-only probe v1\n'..notice..'\n')
        Reply(user,message.Request,success,notice,data)
        return
    end
    if message.Kind~='ChestPreview' and message.Kind~='ChestRestore' then return end
    if lifecycleBusy then
        Reply(user,message.Request,false,'Chest item refresh is still running. Try again after it completes.')
        return
    end
    lifecycleBusy=true
    local kind=message.Kind
    local function Complete(success,notice,info)
        lifecycleBusy=false
        Log('REQUEST '..kind..' success='..tostring(success==true)..' notice='..tostring(notice))
        Reply(user,message.Request,success==true,notice or 'Chest item test unavailable.',nil,info)
    end
    local ok,success,notice=pcall(function()
        if kind=='ChestPreview' then return PreviewChest(user) end
        return RestoreChest(user)
    end)
    if not ok or success~=true then
        if not ok then Log('ACTION_ERROR '..tostring(success)) end
        Complete(false,ok and tostring(notice) or 'Chest visual test encountered an error. Reload the disposable save.')
        return
    end
    -- RestoreChest clears experiment on success; the owner and item were verified
    -- BEFORE the operation. Target(user) also revalidates original equipment now.
    local target,err=Target(user)
    if not target then
        if kind=='ChestPreview' then
            local undone,why=UndoCachedMap()
            Log('PREVIEW_ROLLBACK noTarget='..tostring(undone)..' '..tostring(why))
        end
        Complete(false,'Chest equipment verification failed: '..tostring(err)..'. Reload disposable save if needed.')
        return
    end
    local expectedFingerprint=nil
    if kind=='ChestPreview' and experiment then expectedFingerprint=experiment.signature end
    if kind=='ChestRestore' then
        local map=Read(Read(target.serverItem.Template,'Equipment'),'Visuals')
        expectedFingerprint=Fingerprint(Serialize(map),0)
    end
    RefreshEquippedSameItem(target.actor,target.item,kind,function(refreshed,explanation)
        if refreshed then
            local got,itemEntity=pcall(Ext.Entity.Get,target.item)
            local currentItem=got and Component(itemEntity,'ServerItem') or nil
            local liveMap=Read(Read(Read(currentItem,'Template'),'Equipment'),'Visuals')
            local liveFingerprint=liveMap and Fingerprint(Serialize(liveMap),0) or nil
            local mapStays=expectedFingerprint~=nil and expectedFingerprint==liveFingerprint
            Log('CYCLE_MAP_VERIFY stage='..kind..' preserved='..tostring(mapStays))
            if not mapStays then
                refreshed=false
                explanation='Engine reset or replaced the cached visual map during equipment refresh'
            end
        end
        if not refreshed then
            if kind=='ChestPreview' then
                local undone,why=UndoCachedMap()
                Log('PREVIEW_ROLLBACK success='..tostring(undone)..' '..tostring(why))
                explanation=explanation..'; visual map rollback: '..tostring(why)
            end
            Complete(false,explanation)
            return
        end
        -- A successful same-item equipment cycle proves only that the engine
        -- accepted the refresh. The live rendered appearance still needs testing.
        local info=VisualReply(target.actor,target.item,kind,explanation)
        Complete(true,(kind=='ChestPreview' and 'Chest item cycled using the original item. Check whether the robe now appears; then Restore Chest (TEST).'
                or 'Original chest appearance mapping restored and original item re-equipped. Check the model.'),info)
    end)
end)
