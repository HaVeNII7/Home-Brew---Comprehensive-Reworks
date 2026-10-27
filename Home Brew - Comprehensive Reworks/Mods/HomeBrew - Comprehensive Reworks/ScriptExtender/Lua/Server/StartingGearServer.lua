-- HomeBrew creation-only equipment selection and grant verification.
local Catalog=Ext.Require('Shared/StartingGearCatalog.lua')
local channel=Ext.Net.CreateChannel(ModuleUUID,'HBStartingEquipment')
local REPORT='HomeBrew/Diagnostics/HB_StartingEquipment.txt'
local LEDGER='HB_StartingEquipmentPending_v1'
Ext.Vars.RegisterModVariable(ModuleUUID,LEDGER,{
    Server=true,Client=false,Persistent=true,WriteableOnServer=true,
})
local sessions={}
local rangedStartupChecks={}
local report={'HomeBrew starting equipment service v5; multiplayer user-scoped creation staging'}
local dirty=true
local lastDiagnostics={}
local function TraceOnce(key,line)
    if lastDiagnostics[key]~=line then
        lastDiagnostics[key]=line
        report[#report+1]=line
        if #report>120 then table.remove(report,2) end
        dirty=true
    end
end
local function Log(line)
    report[#report+1]=tostring(line)
    if #report>100 then table.remove(report,2) end
    dirty=true
end
local function Component(e,name)
    if not e then return nil end
    local ok,value=pcall(function() return e:GetComponent(name) end)
    return ok and value or nil
end
local function UUID(entity)
    local c=Component(entity,'Uuid')
    return c and tostring(c.EntityUuid) or nil
end
local function User(id)
    return type(id)=='number' and id-id%0x10000+1 or nil
end
local function Owned(entity,user)
    if not Component(entity,'ServerCharacter') or not UUID(entity) then return false end
    local avatar=Component(entity,'UserAvatar')
    local reserved=Component(entity,'UserReservedFor')
    if avatar and User(avatar.UserID)==User(user) then return true end
    if reserved and User(reserved.UserID)==User(user) then return true end
    local ok,id=pcall(Osi.GetReservedUserID,UUID(entity))
    if ok and id~=0 and User(id)==User(user) then return true end
    -- A newly created player's avatar can be listed in its PartyView before the
    -- reservation and UserAvatar fields have completed their transition.
    -- Require a matching user-owned party view, exact avatar UUID and UserAvatar
    -- candidate; never infer the owner from the host or another party member.
    local matched,owned=pcall(function()
        local parties=Ext.Entity.GetAllEntitiesWithComponent('PartyView')
        for _,party in ipairs(parties or {}) do
            local viewComponent=Component(party,'PartyView')
            for _,view in pairs(viewComponent and viewComponent.Views or {}) do
                if User(view.UserID)==User(user) then
                    for _,character in pairs(view.Characters or {}) do
                        if UUID(character)==UUID(entity) then return true end
                    end
                end
            end
        end
        return false
    end)
    return matched and owned==true
end
local function Avatar(user,creation)
    local found,count=nil,0
    local ok,all=pcall(Ext.Entity.GetAllEntitiesWithComponent,'UserAvatar')
    if not ok or not all then return nil end
    for _,entity in ipairs(all) do
        if Owned(entity,user) then
            local cc=Component(entity,'ServerCharacter')
            if cc and (not creation or cc.CharCreationInProgress) then
                found,count=entity,count+1
            end
        end
    end
    -- Only accept a unique avatar belonging to the original creating user.
    return count==1 and found or nil
end
local function Remember()
    local snapshot={}
    for _,entry in pairs(sessions) do
        if entry.Phase~='Complete' and entry.Phase~='Cancelled' then
            local choices={}
            for slot,stat in pairs(entry.Choices or {}) do choices[slot]=stat end
            -- User ID is the ledger key; source NetIds are transient across transitions.
            -- Persist the in-flight stage as well as completed slots. If the
            -- session is saved after TemplateAddTo but before we observe the
            -- item, a reload must verify that same item, never blindly add it again.
            local pending=entry.Pending and {Root=entry.Pending.Root,Slot=entry.Pending.Slot,
                Equip=entry.Pending.Equip} or nil
            local pendingEquip=entry.PendingEquip and {Item=entry.PendingEquip.Item,
                Slot=entry.PendingEquip.Slot,Equip=entry.PendingEquip.Equip} or nil
            snapshot[tostring(entry.User)]={Source=entry.Source,User=entry.User,Choices=choices,Phase=entry.Phase,
                CompleteSlots=entry.CompleteSlots or {},FinishProof=entry.FinishProof,
                Pending=pending,PendingEquip=pendingEquip}
        end
    end
    local ok,err=pcall(function() Ext.Vars.GetModVariables(ModuleUUID)[LEDGER]=snapshot end)
    if not ok then Log('LEDGER_WRITE_FAILED '..tostring(err)) end
end
local function Reply(s,request,success,detail,slot,previous)
    local payload={Kind='Result',Source=s.Source,Request=request,Success=success,
        Detail=detail,Slot=slot,Previous=previous}
    local ok,err=pcall(channel.SendToClient,channel,payload,s.User)
    if not ok then Log('Client status unavailable: '..tostring(err)) end
end
-- Authentication comes from the network channel's `user`, never the
-- client-supplied source. A multiplayer client may not have one unique CC
-- definition; source 0 therefore means *stage only*, never grant by source.
-- All actual preview/final gameplay writes use Avatar(s.User), whose ownership
-- is independently established by the server.
local function ProveCreation(source,user)
    if not User(user) then return nil,'Unknown player.' end
    local okDefs,definitions=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCharacterDefinition')
    local okRoots,roots=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCreation')
    TraceOnce('creation_context_'..tostring(user),'CREATION_CONTEXT user='..tostring(user)
        ..' source='..tostring(source)
        ..' definitions='..tostring(okDefs and type(definitions)=='table' and #definitions or 'unavailable')
        ..' roots='..tostring(okRoots and type(roots)=='table' and #roots or 'unavailable'))
    if not okDefs or type(definitions)~='table' or #definitions==0
        or not okRoots or type(roots)~='table' or #roots==0 then
        return nil,'Initial character creation is not active on the server.'
    end
    local e=source~=0 and Ext.Entity.Get(source) or nil
    if source~=0 and (not e or not Component(e,'CCCharacterDefinition')) then
        return nil,'Creation definition is unavailable.'
    end
    local registered={}
    for _,definition in ipairs(definitions) do registered[tostring(definition)]=true end
    if e and not registered[tostring(e)] then
        return nil,'Creation definition does not belong to this creation session.'
    end
    local valid=0
    local sourceLinked=false
    for _,root in ipairs(roots) do
        local creation=Component(root,'CCCreation')
        local references=creation and creation.CharacterDefinitions
        if references then
            -- The mapped native vector can be a C++ proxy, so read indices
            -- defensively instead of assuming that Lua ipairs will iterate it.
            for index=1,math.min(math.max(#definitions+1,8),32) do
                local success,ref=pcall(function() return references[index] end)
                if not success or ref==nil then break end
                if registered[tostring(ref)] then valid=valid+1 end
                if e and tostring(ref)==tostring(e) then sourceLinked=true end
            end
        end
    end
    if valid==0 then return nil,'No verified active creation definition is linked to the creation root.' end
    if e and not sourceLinked then return nil,'The selected creation definition is not active.' end
    return e or true
end
local function Equipped(uuid,slot)
    local ok,value=pcall(Osi.GetEquippedItem,uuid,slot)
    return ok and type(value)=='string' and #value>=36 and value or nil
end
local function ItemId(value)
    if type(value)~='string' then return nil end
    local id=value:match('([0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+)$')
    return id and id:lower() or nil
end
local function SameItem(a,b)
    local x,y=ItemId(a),ItemId(b)
    return x~=nil and x==y
end
local function ReadyAvatar(s)
    local actor=Avatar(s.User,false)
    local c=Component(actor,'ServerCharacter')
    if not actor or not c then return nil,'No uniquely owned gameplay avatar' end

    -- Native creation and avatar flags do not necessarily settle in the same tick.
    -- Require proof that the creation interface is fully gone before any grant.
    local ok,roots=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCreation')
    if not ok or type(roots)~='table' then return nil,'Creation root state is unavailable' end
    if #roots~=0 then return nil,'Character creation is still active' end
    local ok2,defs=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCharacterDefinition')
    if not ok2 or type(defs)~='table' then return nil,'Creation definition state is unavailable' end
    if #defs~=0 then return nil,'Creation definition remains active' end
    if c.CharCreationInProgress or not c.CharacterCreationFinished then
        -- The engine can retain stale character-creation flags during the handoff.
        -- Only an actual server-side completion event may authorize this path;
        -- a brief delay makes sure we are out of the creation transition.
        if s.FinishProof~='CharacterCreationFinished' or not s.ProofAt then
            return nil,'Avatar has no confirmed creation completion'
        end
        if Ext.Timer.MonotonicTime()-s.ProofAt<2000 then
            return nil,'Awaiting gameplay transition after completion event'
        end
    end
    return actor,nil
end
local function Find(root,uuid)
    local ok,value=pcall(Osi.GetItemByTemplateInInventory,root,uuid)
    return ok and type(value)=='string' and #value>=36 and value or nil
end
local function RestorePreview(s,slotID)
    if s.PreviewChecks then s.PreviewChecks[slotID]=nil end
    local waiting=s.PreviewJobs and s.PreviewJobs[slotID]
    if waiting then
        local actor=Ext.Entity.Get(waiting.Actor)
        local character=Component(actor,'ServerCharacter')
        if actor and character and character.CharCreationInProgress and Owned(actor,s.User) then
            local pendingItem=Find(waiting.Root,waiting.Actor)
            if pendingItem then
                -- This was absent before the request, so it is the temporary
                -- item we added for this slot. Revoke only while creation is active.
                pcall(Osi.RequestDelete,pendingItem)
                Log('PREVIEW_PENDING_CLEANED '..tostring(slotID))
            end
        end
        s.PreviewJobs[slotID]=nil
    end
    local old=s.Preview and s.Preview[slotID]
    if not old then return end
    local actor=old.Actor and Ext.Entity.Get(old.Actor)
    local character=Component(actor,'ServerCharacter')
    if actor and character and character.CharCreationInProgress and Owned(actor,s.User) then
        if old.Previous and Ext.Entity.Get(old.Previous) then
            pcall(Osi.Equip,old.Actor,old.Previous,0,0)
        elseif old.Spawned then
            pcall(Osi.Unequip,old.Actor,old.Spawned,0,0)
        end
        if old.Spawned and Ext.Entity.Get(old.Spawned) then
            pcall(Osi.RequestDelete,old.Spawned)
        end
    end
    s.Preview[slotID]=nil
end
local function StartPreview(s,slot,stat)
    RestorePreview(s,slot.id)
    if not stat or stat=='' then return 'Original equipment restored.' end
    local actor=Avatar(s.User,true)
    if not actor or not Component(actor,'ServerCharacter').CharCreationInProgress then
        Log('PREVIEW_ACTOR_UNAVAILABLE slot='..tostring(slot.id)..' user='..tostring(s.User))
        return 'Selection saved for creation. This character model does not expose a server equipment preview.'
    end
    local root=Catalog.RootTemplate(stat)
    if not root then return 'Selection saved. The installed item has no verified equipment template for preview.' end
    local uuid=UUID(actor)
    if not uuid then return 'Selection saved. The creation character is not ready for a preview.' end
    if Find(root,uuid) then
        return 'Selection saved. A matching item already exists; preview deferred to avoid changing existing equipment.'
    end
    local previous=Equipped(uuid,slot.equip)
    local ok=pcall(Osi.TemplateAddTo,root,uuid,1,0)
    if not ok then return 'Selection saved; preview item could not be created.' end
    s.PreviewJobs=s.PreviewJobs or {}
    s.PreviewJobs[slot.id]={Root=root,Actor=uuid,Slot=slot.id,Equip=slot.equip,Previous=previous,
        Ready=Ext.Timer.MonotonicTime()+250,Deadline=Ext.Timer.MonotonicTime()+1500}
    return 'Selection saved. Updating the character preview…'
end
local function DoPreviewJobs(s,now)
    for id,job in pairs(s.PreviewJobs or {}) do
        if now>=job.Ready then
            local actor=Ext.Entity.Get(job.Actor)
            local character=Component(actor,'ServerCharacter')
            if not actor or not character or not character.CharCreationInProgress or not Owned(actor,s.User) then
                s.PreviewJobs[id]=nil
            else
                local item=Find(job.Root,job.Actor)
                if item then
                    local ok=pcall(Osi.Equip,job.Actor,item,0,0)
                    if ok then
                        s.Preview[id]={Actor=job.Actor,Previous=job.Previous,Spawned=item}
                        s.PreviewChecks=s.PreviewChecks or {}
                        s.PreviewChecks[id]={Actor=job.Actor,Equip=job.Equip,Item=item,Ready=now+350}
                        Log('PREVIEW_EQUIP_REQUESTED '..tostring(id)..' item='..tostring(item))
                    else
                        pcall(Osi.RequestDelete,item)
                    end
                    s.PreviewJobs[id]=nil
                elseif now>job.Deadline then
                    Log('PREVIEW_ITEM_NOT_OBSERVED '..tostring(id)..' template='..tostring(job.Root))
                    s.PreviewJobs[id]=nil
                end
            end
        end
    end
    for id,check in pairs(s.PreviewChecks or {}) do
        if now>=check.Ready then
            local actor=Ext.Entity.Get(check.Actor)
            local character=Component(actor,'ServerCharacter')
            if actor and character and character.CharCreationInProgress and Owned(actor,s.User) then
                local equipped=Equipped(check.Actor,check.Equip)
                if SameItem(equipped,check.Item) then
                    Log('PREVIEW_SLOT_VERIFIED '..tostring(id)..' item='..tostring(check.Item))
                else
                    Log('PREVIEW_SLOT_UNVERIFIED '..tostring(id)..' observed='..tostring(equipped))
                end
            else
                Log('PREVIEW_ACTOR_TRANSITION '..tostring(id))
            end
            s.PreviewChecks[id]=nil
        end
    end
end
local function ClearPreviews(s)
    for _,slot in ipairs(Catalog.Slots) do RestorePreview(s,slot.id) end
end
channel:SetHandler(function(message,user)
    if type(message)~='table' or type(user)~='number' or type(message.Source)~='number'
        or message.Source<0 or message.Source%1~=0 or type(message.Request)~='number' then return end
    if message.Kind~='Set' and message.Kind~='Close' then return end
    -- Key by authenticated network sender, NOT source NetId: in multiplayer
    -- several local clients can legitimately have source=0 (or see the same
    -- replicated creation definition). The network sender is authoritative.
    local s=sessions[user]
    -- A closing creation panel may send a final Close after the completion
    -- event has already committed the player's staged choices. Ignore it.
    if message.Kind=='Close' and (not s or s.Phase~='Staging') then return end
    local ok,err=pcall(function()
        local _,reason=ProveCreation(message.Source,user)
        if reason then error(reason) end
        if s and s.Source~=message.Source then error('The creation source changed while choosing equipment; reopen the menu.') end
        if not s then
            s={Source=message.Source,User=user,Choices={},Phase='Staging',Preview={},PreviewJobs={},PreviewChecks={}}
            sessions[user]=s
        end
        if s.Phase~='Staging' then error('Character creation has already finished.') end
        s.ClosingAt=nil
        if message.Kind=='Close' then s.ClosingAt=Ext.Timer.MonotonicTime()+2000;return end
        local slot,option=Catalog.Find(message.Slot,message.Stat)
        if not slot then error('Unknown equipment slot or item choice.') end
        local previous=s.Choices[slot.id]
        local nextChoices={}
        for id,stat in pairs(s.Choices) do nextChoices[id]=stat end
        if option then
            if not Catalog.Available(option[2]) then error('The selected item is not installed.') end
            if not Catalog.RootTemplate(option[2]) then error('The item template could not be verified.') end
            nextChoices[slot.id]=option[2]
        else nextChoices[slot.id]=nil end
        local conflict=Catalog.Conflict(nextChoices)
        if conflict then error(conflict) end
        s.Choices=nextChoices
        local detail=StartPreview(s,slot,option and option[2])
        Remember()
        Reply(s,message.Request,true,detail,slot.id,previous)
        Log('STAGED user='..tostring(user)..' source='..tostring(s.Source)
            ..' '..slot.id..'='..tostring(option and option[2] or 'Default'))
    end)
    if not ok then
        s=s or {Source=message.Source,User=user}
        Log('REJECTED user='..tostring(user)..' source='..tostring(message.Source)..' '..tostring(err))
        Reply(s,message.Request,false,tostring(err),message.Slot,s.Choices and s.Choices[message.Slot] or nil)
    end
end)
local function BeginCommit(s,reason)
    if s.Phase~='Staging' then return end
    s.Phase='Commit'
    s.Deadline=Ext.Timer.MonotonicTime()+120000
    if reason=='CharacterCreationFinished' then s.FinishProof='CharacterCreationFinished' end
    if s.FinishProof=='CharacterCreationFinished' then s.ProofAt=Ext.Timer.MonotonicTime() end
    s.Step=1
    s.CompleteSlots=s.CompleteSlots or {}
    s.PreviewJobs={}
    s.PreviewChecks={}
    Remember()
    Log('COMMIT_START '..reason..' user='..tostring(s.User)..' source='..tostring(s.Source))
end
Ext.Osiris.RegisterListener('CharacterCreationFinished',0,'after',function()
    local count=0
    for _,s in pairs(sessions) do
        if s.Phase=='Staging' then
            -- This is a global event, not proof that every multiplayer peer
            -- has finished. Record its server origin, but commit each sender's
            -- equipment only once their uniquely owned avatar is in gameplay.
            s.FinishProof='CharacterCreationFinished'
            s.ProofAt=Ext.Timer.MonotonicTime()
            count=count+1
        end
    end
    if count>0 then Remember() end
    Log('CREATION_FINISHED_EVENT pendingOwnedAvatars='..count)
end)
local function Commit(s,now)
    local actor,reason=ReadyAvatar(s)
    if not actor then
        TraceOnce('wait_'..tostring(s.User),'COMMIT_WAIT user='..tostring(s.User)..' reason='..tostring(reason))
        return
    end
    local uuid=UUID(actor)
    if not uuid then return end
    if s.PendingEquip then
        local job=s.PendingEquip
        if now<job.Ready then return end
        local equipped=Equipped(uuid,job.Equip)
        if SameItem(equipped,job.Item) then
            s.CompleteSlots[job.Slot]=true
            s.PendingEquip=nil
            s.Step=s.Step+1
            Remember()
            Log('FINAL_VERIFIED '..job.Slot..' item='..job.Item)
        elseif job.Restored and not job.Reissued then
            -- An equip request may not have settled before the previous save.
            -- Resume only with the identical recorded item in this avatar's
            -- inventory, never with an arbitrary matching template instance.
            local stat=s.Choices[job.Slot]
            local root=stat and Catalog.RootTemplate(stat)
            local inventoryItem=root and Find(root,uuid)
            if not SameItem(inventoryItem,job.Item) then
                Log('RECOVER_EQUIP_REFUSED '..tostring(job.Slot)..' recorded item not found in owned inventory')
                s.Phase='Error';Remember();return
            end
            local ok=pcall(Osi.Equip,uuid,inventoryItem,0,0)
            if not ok then
                Log('RECOVER_EQUIP_FAILED '..tostring(job.Slot))
                s.Phase='Error';Remember();return
            end
            job.Reissued=true
            job.Ready=now+250
            job.Deadline=now+3000
            Remember()
            Log('RECOVER_EQUIP_REQUESTED '..tostring(job.Slot)..' item='..tostring(inventoryItem))
        elseif now>job.Deadline then
            local stat=s.Choices[job.Slot]
            local root=stat and Catalog.RootTemplate(stat)
            local nativeRemoved=(job.Slot=='Ranged' or job.Slot=='RangedOff')
                and root and not Find(root,uuid)
            s.RangedCommitRetried=s.RangedCommitRetried or {}
            if nativeRemoved and not s.RangedCommitRetried[job.Slot] then
                s.RangedCommitRetried[job.Slot]=true
                s.PendingEquip=nil
                Remember()
                Log('RANGED_STARTUP_RETRY_DURING_COMMIT slot='..job.Slot..' user='..tostring(s.User))
            else
                Log('FINAL_EQUIP_UNVERIFIED '..job.Slot..' expected='..tostring(job.Item)..' observed='..tostring(equipped))
                s.Phase='Error';Remember()
            end
        end
        return
    end
    if s.Pending then
        if now<s.Pending.Ready then return end
        local job=s.Pending
        local found=Find(job.Root,uuid)
        if not found then
            if now<job.Deadline then return end
            s.RangedCommitRetried=s.RangedCommitRetried or {}
            if (job.Slot=='Ranged' or job.Slot=='RangedOff')
                and not job.Restored and not s.RangedCommitRetried[job.Slot] then
                s.RangedCommitRetried[job.Slot]=true
                s.Pending=nil
                Remember()
                Log('RANGED_STARTUP_RETRY_MISSING_GRANT slot='..job.Slot..' user='..tostring(s.User))
                return
            end
            Log('FINAL_GRANT_UNVERIFIED '..job.Slot..' template='..job.Root
                ..(job.Restored and ' (reloaded pending operation; no second creation attempted)' or ''))
            s.Phase='Error';Remember();return
        end
        local ok=pcall(Osi.Equip,uuid,found,0,0)
        if not ok then Log('FINAL_EQUIP_FAILED '..job.Slot);s.Phase='Error';Remember();return end
        s.PendingEquip={Item=found,Slot=job.Slot,Equip=job.Equip,Ready=now+250,Deadline=now+2400}
        s.Pending=nil
        Remember()
        return
    end
    while s.Step<=#Catalog.Slots do
        local slot=Catalog.Slots[s.Step]
        local stat=s.Choices[slot.id]
        if stat and stat~='' and not s.CompleteSlots[slot.id] then
            local root=Catalog.RootTemplate(stat)
            if not root then Log('FINAL_MISSING_TEMPLATE '..slot.id);s.Phase='Error';Remember();return end
            local found=Find(root,uuid)
            if found then
                local ok=pcall(Osi.Equip,uuid,found,0,0)
                if not ok then Log('FINAL_EQUIP_FAILED '..slot.id);s.Phase='Error';Remember();return end
                s.PendingEquip={Item=found,Slot=slot.id,Equip=slot.equip,Ready=now+250,Deadline=now+2400}
                Remember()
                Log('FINAL_REUSED '..slot.id..' template='..root)
                return
            else
                local ok=pcall(Osi.TemplateAddTo,root,uuid,1,0)
                if not ok then Log('FINAL_CREATE_FAILED '..slot.id);s.Phase='Error';Remember();return end
                s.Pending={Root=root,Slot=slot.id,Equip=slot.equip,Ready=now+250,Deadline=now+2000}
                Remember()
                return
            end
        end
        s.Step=s.Step+1
    end
    s.Phase='Complete'
    -- BG3's TUT_Start intro can subsequently move an equipped ranged weapon
    -- out of a non-Bard/non-Ranger player's inventory. Observe ONLY recorded,
    -- fully verified HomeBrew ranged selections during the initial handoff.
    local watched={}
    for _,id in ipairs({'Ranged','RangedOff'}) do
        local stat=s.Choices[id]
        local slot=Catalog.BySlot[id]
        if stat and slot and s.CompleteSlots[id] then
            local root=Catalog.RootTemplate(stat)
            if root then watched[id]={Root=root,Equip=slot.equip,Restored=false,Pending=false} end
        end
    end
    if next(watched) then
        rangedStartupChecks[s.User]={Actor=uuid,User=s.User,Slots=watched,
            Next=now+1500,Expires=now+45000}
        Log('RANGED_STARTUP_WATCH user='..tostring(s.User)..' actor='..uuid)
    end
    sessions[s.Source]=nil
    Remember()
    Log('COMPLETE source='..tostring(s.Source)..' actor='..uuid)
end
-- The base-game tutorial's starting-weapon cleanup runs independently of our
-- character-creation equipment commit. This bounded observer only replaces a
-- selected ranged item if the verified owner's inventory no longer contains it.
-- It never adds an item merely because an equipment slot is empty, and never
-- alters a melee slot or another user's avatar. Limit to one replacement per
-- slot to avoid generating duplicates if the user deliberately removes gear.
local function CheckRangedStartup(now)
    for user,watch in pairs(rangedStartupChecks) do
        if now>=watch.Expires then
            rangedStartupChecks[user]=nil
            Log('RANGED_STARTUP_WATCH_END user='..tostring(user))
        elseif now>=watch.Next then
            watch.Next=now+1500
            local actor=Ext.Entity.Get(watch.Actor)
            if not actor or not Owned(actor,user) then
                rangedStartupChecks[user]=nil
                Log('RANGED_STARTUP_OWNER_LOST user='..tostring(user))
            else
                local rootsOK,roots=pcall(Ext.Entity.GetAllEntitiesWithComponent,'CCCreation')
                if rootsOK and type(roots)=='table' and #roots==0 then
                    for id,slot in pairs(watch.Slots) do
                        local found=Find(slot.Root,watch.Actor)
                        if found then
                            if slot.Pending then
                                slot.Pending=false
                                slot.Recovered=true
                                local current=Equipped(watch.Actor,slot.Equip)
                                if not current then
                                    local ok,err=pcall(Osi.Equip,watch.Actor,found,0,0)
                                    Log('RANGED_STARTUP_REEQUIP slot='..id..' user='..tostring(user)
                                        ..' success='..tostring(ok)..(ok and '' or ' error='..tostring(err)))
                                else
                                    Log('RANGED_STARTUP_INVENTORY_ONLY slot='..id..' user='..tostring(user)
                                        ..' occupied='..tostring(current))
                                end
                            end
                        elseif not slot.Restored then
                            slot.Restored=true
                            slot.Pending=true
                            local ok,err=pcall(Osi.TemplateAddTo,slot.Root,watch.Actor,1,0)
                            Log('RANGED_STARTUP_REPLACED slot='..id..' user='..tostring(user)
                                ..' success='..tostring(ok)..(ok and '' or ' error='..tostring(err)))
                        elseif slot.Pending and not slot.PendingFailedAt and now>=watch.Expires-1500 then
                            slot.PendingFailedAt=now
                            Log('RANGED_STARTUP_REPLACEMENT_NOT_OBSERVED slot='..id
                                ..' user='..tostring(user))
                        end
                    end
                end
            end
        end
    end
end
local lastTick=-500
Ext.Events.Tick:Subscribe(function()
    local now=Ext.Timer.MonotonicTime()
    if next(sessions) and now-lastTick>=200 then
        lastTick=now
        for user,s in pairs(sessions) do
            local ok,err=pcall(function()
                if s.Phase=='Staging' then
                    -- Never begin a grant until the network sender's own unique
                    -- avatar has left creation. Other peers can still be editing.
                    local actor=ReadyAvatar(s)
                    if actor then BeginCommit(s,'VerifiedGameplayAvatar')
                    else
                        DoPreviewJobs(s,now)
                        -- An explicit source=0 has no specific entity to check.
                        -- Keep its user-scoped selections until verified gameplay
                        -- (or until the server itself leaves this campaign).
                        if s.Source~=0 and s.ClosingAt and now>s.ClosingAt
                            and not Ext.Entity.Get(s.Source) then
                            ClearPreviews(s);sessions[user]=nil;Remember()
                        end
                    end
                elseif s.Phase=='Commit' then
                    if now>s.Deadline then s.Phase='Error';Remember();Log('FINAL_TIMEOUT user='..tostring(user))
                    else Commit(s,now) end
                end
            end)
            if not ok then Log('ERROR user='..tostring(user)..' '..tostring(err)) end
        end
    end
    if next(rangedStartupChecks) then
        local ok,err=pcall(CheckRangedStartup,now)
        if not ok then Log('RANGED_STARTUP_CHECK_FAILED '..tostring(err)) end
    end
    if dirty then
        dirty=false
        pcall(Ext.IO.SaveFile,REPORT,table.concat(report,'\n')..'\n')
    end
end)
Ext.Events.SessionLoaded:Subscribe(function()
    local ok,saved=pcall(function() return Ext.Vars.GetModVariables(ModuleUUID)[LEDGER] end)
    if not ok then Log('LEDGER_READ_FAILED '..tostring(saved));return end
    local restored=0
    if type(saved)=='table' then
        for _,entry in pairs(saved) do
            if type(entry)=='table' and (entry.Phase=='Commit' or entry.Phase=='Staging')
                and type(entry.Source)=='number' and type(entry.User)=='number'
                and type(entry.Choices)=='table' and not sessions[entry.User] then
                local valid={}
                for id,stat in pairs(entry.Choices) do
                    if Catalog.Find(id,stat) and Catalog.RootTemplate(stat) then valid[id]=stat end
                end
                if next(valid) then
                    local restoredSession={Source=entry.Source,User=entry.User,Choices=valid,
                        Phase='Staging',CompleteSlots=type(entry.CompleteSlots)=='table' and entry.CompleteSlots or {},
                        FinishProof=entry.FinishProof=='CharacterCreationFinished' and 'CharacterCreationFinished' or nil,
                        Preview={},PreviewJobs={},PreviewChecks={}}
                    sessions[entry.User]=restoredSession
                    restored=restored+1
                    if entry.Phase=='Commit' then
                        BeginCommit(restoredSession,'SessionLoadedRecovery')
                        local now=Ext.Timer.MonotonicTime()
                        local pending=entry.Pending
                        local pendingEquip=entry.PendingEquip
                        if type(pending)=='table' and type(pending.Slot)=='string' then
                            local slot=Catalog.BySlot[pending.Slot]
                            local stat=restoredSession.Choices[pending.Slot]
                            local root=stat and Catalog.RootTemplate(stat)
                            if slot and root and root==pending.Root and slot.equip==pending.Equip
                                and not restoredSession.CompleteSlots[pending.Slot] then
                                restoredSession.Pending={Root=root,Slot=slot.id,Equip=slot.equip,
                                    Ready=now+250,Deadline=now+3500,Restored=true}
                                Log('RECOVER_PENDING_GRANT slot='..slot.id)
                            else
                                restoredSession.Phase='Error'
                                Log('RECOVERY_REFUSED invalid pending grant')
                            end
                        elseif type(pendingEquip)=='table' and type(pendingEquip.Slot)=='string' then
                            local slot=Catalog.BySlot[pendingEquip.Slot]
                            local stat=restoredSession.Choices[pendingEquip.Slot]
                            if slot and stat and Catalog.RootTemplate(stat) and slot.equip==pendingEquip.Equip
                                and ItemId(pendingEquip.Item) and not restoredSession.CompleteSlots[slot.id] then
                                restoredSession.PendingEquip={Item=pendingEquip.Item,Slot=slot.id,
                                    Equip=slot.equip,Ready=now+250,Deadline=now+3500,Restored=true}
                                Log('RECOVER_PENDING_EQUIP slot='..slot.id)
                            else
                                restoredSession.Phase='Error'
                                Log('RECOVERY_REFUSED invalid pending equip')
                            end
                        end
                        Remember()
                    else
                        local actor=ReadyAvatar(restoredSession)
                        if actor then BeginCommit(restoredSession,'SessionLoadedFinishedAvatar') end
                    end
                end
            end
        end
    end
    Log('SESSION_LOADED restored='..restored..' liveSessions='..tostring(next(sessions)~=nil))
end)
Log('Creation equipment grant service ready.')
