local Files=Ext.Require('Shared/PresetFiles.lua')
local Builds=Ext.Require('Shared/BuildPresetData.lua')
local DIR='HomeBrew/BuildPresets'
local VAR='HB_LevelUpAssignedBuild_v1'
local channel=Ext.Net.CreateChannel(ModuleUUID,'HB_LevelUpBuild_v1')
local pending={}
local PostCommittedLevel
local log={ 'HomeBrew level-up build handoff v1' }
local function Trace(s)
    log[#log+1]=tostring(s)
    if #log>300 then table.remove(log,2) end
    pcall(Ext.IO.SaveFile,'HomeBrew/Diagnostics/HB_LevelUpBuild_Apply.txt',table.concat(log,'\n')..'\n')
end

-- Diagnostic only: native respec can reset the game's available-level/XP
-- state independently of EocLevel and CCLevelUp. The historical replay audit
-- does not cover those counters. Observe them before attempting any repair.
local observedCharacters={}
local function Scalar(obj,key)
    if not obj then return nil end
    local ok,val=pcall(function() return obj[key] end)
    return ok and val or nil
end
local function ProbeLevelState(actor,phase)
    local okay,why=pcall(function()
        local entity=Ext.Entity.Get(actor)
        if not entity then Trace('LEVEL_STATE phase='..tostring(phase)..' actor='..actor..' missing_entity') return end
        local eoc=tonumber(Scalar(entity.EocLevel,'Level'))
        local available=tonumber(Scalar(entity.AvailableLevel,'Level'))
        local cc=Scalar(entity,'CCLevelUp')
        local records=Scalar(cc,'LevelUps')
        local count=nil
        if records then local good,n=pcall(function() return #records end);if good then count=n end end
        local classes=Scalar(Scalar(entity,'Classes'),'Classes')
        local classCount,classLevels=0,0
        if classes then pcall(function()
            for _,item in pairs(classes) do
                classCount=classCount+1
                classLevels=classLevels+(tonumber(Scalar(item,'Level')) or 0)
            end
        end) end
        local xp=Scalar(entity,'Experience')
        local xpFields={}
        for _,key in ipairs({'CurrentLevelExperience','NextLevelExperience','TotalExperience','Level'}) do
            local v=Scalar(xp,key)
            if type(v)=='number' or type(v)=='string' then xpFields[#xpFields+1]=key..':'..tostring(v) end
        end
        local osiLevel=nil
        if Osi and Osi.GetLevel then
            local ok,value=pcall(Osi.GetLevel,actor)
            if ok and type(value)=='number' then osiLevel=value end
        end
        local health=Scalar(entity,'Health')
        local hp=tonumber(Scalar(health,'Hp'))
        local maxHp=tonumber(Scalar(health,'MaxHp'))
        Trace('LEVEL_STATE phase='..tostring(phase)..' actor='..actor
            ..' hp='..tostring(hp)..'/'..tostring(maxHp)
            ..' eoc='..tostring(eoc)..' available='..tostring(available)
            ..' history='..tostring(count)..' classCount='..tostring(classCount)
            ..' classLevels='..tostring(classLevels)..' osiris='..tostring(osiLevel)
            ..' experience='..(#xpFields>0 and table.concat(xpFields,',') or (xp and 'unmapped' or 'missing')))
    end)
    if not okay then Trace('LEVEL_STATE_ERROR phase='..tostring(phase)..' reason='..tostring(why)) end
end

local function Guid(value) return tostring(value or ''):sub(-36) end
local function User(peer) return peer-(peer%0x10000)+1 end
local function Owned(actor,peer)
    if type(peer)~='number' then return false end
    local expected=User(peer)
    local ok,assigned=pcall(Osi.GetReservedUserID,actor)
    if not ok then return false end
    assigned=tonumber(assigned) or 0
    if assigned~=0 then return assigned==expected end
    local valid,all=pcall(Ext.Entity.GetAllEntitiesWithComponent,'PartyView')
    if not valid then return false end
    for _,party in pairs(all or {}) do
        for _,view in pairs((party.PartyView and party.PartyView.Views) or {}) do
            if tonumber(view.UserID)==expected then
                for _,member in pairs(view.Characters or {}) do
                    if member.Uuid and Guid(member.Uuid.EntityUuid)==actor then return true end
                end
            end
        end
    end
    return false
end
local function Answer(peer,operation,success,status,extra)
    local reply={Operation=operation,Success=success==true,Status=tostring(status or '')}
    for k,v in pairs(extra or {}) do reply[k]=v end
    channel:SendToClient(reply,User(peer))
end
local function Saved(actor)
    local entity=Ext.Entity.Get(actor)
    if not entity then error('Character unavailable.') end
    local result=PartialRespecSnapshot.SaveCharacter(
        'HomeBrew/Backups/HB_LevelUpBuild_Snapshot.json',actor)
    if type(result)~='table' then error('Could not capture the committed build.') end
    return entity,result
end
local function Assigned(entity)
    local raw=entity and entity.Vars and entity.Vars[VAR]
    if type(raw)~='table' or type(raw.File)~='string' then return nil end
    return raw
end
local function VerifyPreset(file,snapshot,target)
    local data,why=Files.Read(DIR,file)
    if not data then error(tostring(why)) end
    if data.Version~=2 then error('Re-save this preset as Version 2 before applying it during level-up.') end
    local compatible,why=Builds.Compatible(data,snapshot)
    if not compatible then error(tostring(why)) end
    if target>data.LevelCount then error('Assigned build stops at level '..data.LevelCount..'.') end
    local installed,reason=Builds.CheckInstalled(data,target)
    if not installed then error(tostring(reason)) end
    return data
end
local function PendingLevel(actor,claimed,snapshot)
    local entity=Ext.Entity.Get(actor)
    local engine=entity and entity.EocLevel and tonumber(entity.EocLevel.Level)
    if type(claimed)~='number' or claimed%1~=0 or claimed<2 or claimed>40
        or not engine or engine<1 or engine>40 then
        error('Current level-up no longer matches the requested level.')
    end
    -- EocLevel can expose the available level while an ordinary level-up is
    -- pending. A level is actually committed only when CCLevelUp records it.
    -- Require exact contiguous history before trusting the UI's next level.
    local saved=snapshot
    if not saved then local _,value=Saved(actor); saved=value end
    local rows=saved and saved.components and saved.components.ccLevelUp
        and saved.components.ccLevelUp.LevelUps
    local recorded=type(rows)=='table' and #rows or nil
    if recorded~=claimed-1 or (engine~=recorded and engine~=claimed) then
        Trace('LEVEL_CHECK_REFUSED actor='..actor..' requested='..tostring(claimed)
            ..' engine='..tostring(engine)..' recorded='..tostring(recorded))
        error('Current level-up no longer matches the recorded progression.')
    end
    Trace('LEVEL_CHECK actor='..actor..' requested='..tostring(claimed)
        ..' engine='..tostring(engine)..' recorded='..recorded)
    return recorded
end
-- RequestAutoLevel chooses native defaults. The user's available XP level is
-- the final destination; the native screen's next-level label is only the
-- initial pending step. No level counters or history records are fabricated.
local function DirectAutoLevelPreflight(actor,current,target)
    if not Osi or not Osi.RequestAutoLevel then
        error('BG3 RequestAutoLevel is unavailable in this session.')
    end
    local entity=Ext.Entity.Get(actor)
    local engine=tonumber(Scalar(Scalar(entity,'EocLevel'),'Level'))
    local available=tonumber(Scalar(Scalar(entity,'AvailableLevel'),'Level'))
    if engine~=current or not available or available~=target
        or target<=current or target>40 or target%1~=0 then
        error('Available level changed while preparing direct completion.')
    end
    -- Auto-level does not accept an exact target. Reject a party with a
    -- higher committed OR available level so it cannot pull the actor past
    -- the level covered by the assigned build.
    local found=false
    local highestCommitted,highestAvailable=0,0
    local worked,parties=pcall(Ext.Entity.GetAllEntitiesWithComponent,'PartyView')
    if not worked or not parties then error('Party level cannot be verified for safe auto-level.') end
    for _,party in pairs(parties) do
        for _,view in pairs(Scalar(Scalar(party,'PartyView'),'Views') or {}) do
            for _,member in pairs(Scalar(view,'Characters') or {}) do
                local uuid=Guid(Scalar(Scalar(member,'Uuid'),'EntityUuid'))
                if uuid==actor then found=true end
                local other=uuid~='' and Ext.Entity.Get(uuid) or nil
                local otherLevel=tonumber(Scalar(Scalar(other,'EocLevel'),'Level'))
                local otherAvailable=tonumber(Scalar(Scalar(other,'AvailableLevel'),'Level'))
                if otherLevel and otherLevel>highestCommitted then highestCommitted=otherLevel end
                if otherAvailable and otherAvailable>highestAvailable then highestAvailable=otherAvailable end
                if (otherLevel and otherLevel>target) or (otherAvailable and otherAvailable>target) then
                    error('Party progression above level '..target..' makes automatic completion unsafe.')
                end
            end
        end
    end
    if not found then error('The character was not found in the verified party for direct auto-level.') end
    Trace('DIRECT_LEVEL_PREFLIGHT actor='..actor..' current='..current
        ..' target='..target..' available='..available
        ..' steps='..(target-current)
        ..' party=verified maxPartyCommitted='..highestCommitted
        ..' maxPartyAvailable='..highestAvailable)
end
local RequestDirectAutoLevel
RequestDirectAutoLevel=function(actor,txn)
    Ext.Timer.WaitFor(120,function()
        if pending[actor]~=txn or txn.Stage~='levelup' or not txn.NativeClosed then return end
        local ok,why=pcall(function()
            local entity=Ext.Entity.Get(actor)
            local rows=Scalar(Scalar(entity,'CCLevelUp'),'LevelUps')
            local history=nil
            if rows then local good,n=pcall(function() return #rows end); if good then history=n end end
            local current=tonumber(Scalar(Scalar(entity,'EocLevel'),'Level'))
            local available=tonumber(Scalar(Scalar(entity,'AvailableLevel'),'Level'))
            if current~=txn.LastConfirmed or history~=txn.LastConfirmed
                or available~=txn.Target or current>=txn.Target then
                error('Character level, available level or history changed before auto-level.')
            end
            if txn.AutoCalls >= txn.Target-txn.Current then
                error('Automatic level-up retry limit reached.')
            end
            txn.AutoCalls=txn.AutoCalls+1
            Trace('DIRECT_LEVEL_CALL actor='..actor..' current='..current
                ..' target='..txn.Target..' attempt='..txn.AutoCalls)
            Osi.RequestAutoLevel(actor)
            Trace('DIRECT_LEVEL_CALL_RETURN actor='..actor..' target='..txn.Target
                ..' attempt='..txn.AutoCalls)
        end)
        if not ok then
            if pending[actor]==txn then pending[actor]=nil end
            Trace('DIRECT_LEVEL_ERROR actor='..actor..' '..tostring(why))
            Answer(txn.Peer,'Failure',false,'Direct auto-level refused: '..tostring(why),
                {Character=actor,TargetLevel=txn.Target})
            return
        end
        -- Usually one engine request advances every available level. If it
        -- instead commits a smaller contiguous prefix and stays there, make
        -- another request only after a second stable, history-matched check.
        -- Never call again when no new level was committed.
        Ext.Timer.WaitFor(3000,function()
            if pending[actor]~=txn or txn.Stage~='levelup' then return end
            local live=Ext.Entity.Get(actor)
            local current=tonumber(Scalar(Scalar(live,'EocLevel'),'Level'))
            local historyRows=Scalar(Scalar(live,'CCLevelUp'),'LevelUps')
            local history=nil
            if historyRows then local valid,n=pcall(function() return #historyRows end); if valid then history=n end end
            if not current or not history or current~=history
                or current<=txn.LastConfirmed or current>=txn.Target then return end
            local stable=current
            Ext.Timer.WaitFor(900,function()
                if pending[actor]~=txn or txn.Stage~='levelup' then return end
                local after=Ext.Entity.Get(actor)
                local againLevel=tonumber(Scalar(Scalar(after,'EocLevel'),'Level'))
                local againRows=Scalar(Scalar(after,'CCLevelUp'),'LevelUps')
                local againHistory=nil
                if againRows then local valid,n=pcall(function() return #againRows end); if valid then againHistory=n end end
                if againLevel~=stable or againHistory~=stable then return end
                txn.LastConfirmed=stable
                Trace('DIRECT_LEVEL_PARTIAL actor='..actor..' committed='..stable
                    ..' target='..txn.Target..' requesting_next_native_step=true')
                RequestDirectAutoLevel(actor,txn)
            end)
        end)
    end)
end
local function Arm(actor,peer,file,initialTarget)
    if pending[actor] then error('A build restoration is already in progress.') end
    local _,snapshot=Saved(actor)
    observedCharacters[actor]=true
    ProbeLevelState(actor,'before_pending_level')
    local current=PendingLevel(actor,initialTarget,snapshot)
    local entity=Ext.Entity.Get(actor)
    local target=tonumber(Scalar(Scalar(entity,'AvailableLevel'),'Level'))
    if not target or target%1~=0 or target<initialTarget or target>40 then
        error('Character has no valid XP-based target for direct completion.')
    end
    -- Fail before touching the character if the preset does not contain all
    -- levels required by the current XP, or if later choices are unavailable.
    VerifyPreset(file,snapshot,target)
    DirectAutoLevelPreflight(actor,current,target)
    -- A durable untouched copy is required before the level-up/respec handoff.
    local recovery='HomeBrew/Backups/HB_LevelUpBuild_Before_'..actor..'.json'
    local json=Ext.Json.Stringify(snapshot,{Beautify=false,StringifyInternalTypes=false})
    if type(json)~='string' or Ext.IO.SaveFile(recovery,json)==false then
        error('Could not save the original character before applying a build.')
    end
    local txn={Peer=peer,File=file,Target=target,InitialTarget=initialTarget,Current=current,
        LastConfirmed=current,AutoCalls=0,Stage='levelup',Recovery=recovery}
    pending[actor]=txn
    local function ProbeCommittedLevel()
        if pending[actor]~=txn or txn.Stage~='levelup' then return end
        local live=Ext.Entity.Get(actor)
        local level=live and live.EocLevel and tonumber(live.EocLevel.Level)
        if level==txn.Target then
            local worked,snapshot=pcall(PartialRespecSnapshot.SaveCharacter,
                'HomeBrew/Backups/HB_LevelUpBuild_Committed_'..actor..'.json',actor)
            local choices=worked and snapshot and snapshot.components
                and snapshot.components.ccLevelUp and snapshot.components.ccLevelUp.LevelUps
            if type(choices)=='table' and #choices==txn.Target then
                PostCommittedLevel(actor,txn)
                return
            end
        end
        Ext.Timer.WaitFor(450,ProbeCommittedLevel)
    end
    Ext.Timer.WaitFor(450,ProbeCommittedLevel)
    -- RequestAutoLevel is deferred until the client has actually exited the
    -- native level-up UI. Running it while the native transaction is open
    -- returned successfully without committing any history.
    Trace('DIRECT_LEVEL_WAIT_NATIVE_EXIT actor='..actor..' target='..target)
    Ext.Timer.WaitFor(math.min(90000,16000+(target-current-1)*6500),function()
        if pending[actor]==txn and txn.Stage=='levelup' then
            pending[actor]=nil
            ProbeLevelState(actor,'direct_auto_level_timeout')
            Trace('TIMEOUT actor='..actor..' phase=direct-autolevel; committed level/history not observed')
            Answer(txn.Peer,'Failure',false,
                'Direct level completion did not produce a verified native level-up; build restoration was not started.',
                {Character=actor,TargetLevel=txn.Target})
        end
    end)
    Trace('ARM actor='..actor..' level='..current..'->'..target
        ..' initialNativeLevel='..initialTarget..' preset='..file)
    return txn
end
channel:SetHandler(function(message,peer)
    if not PartialRespecEnabled or type(message)~='table' or type(peer)~='number' then return end
    local op=tostring(message.Operation or '')
    if op~='State' and op~='Save' and op~='Assign' and op~='Apply'
        and op~='Disarm' and op~='NativeClosed' then return end
    local actor=Guid(message.Character)
    -- The level-up native ls.Character proxy exposes no UUID to client Lua.
    -- Resolve only the controlling user's current character on the server.
    -- Never infer a party member by level or fall back to the host in multiplayer.
    if (not actor:match('^[%x%-]+$') or #actor~=36)
        and op=='State' then
        local ok,result=pcall(function()
            if not Osi or not Osi.GetCurrentCharacter then return nil end
            return Osi.GetCurrentCharacter(User(peer))
        end)
        actor=ok and Guid(result) or ''
        Trace('RESOLVE_ACTIVE peerUser='..tostring(User(peer))
            ..' candidate='..tostring(actor)..' lookup='..tostring(ok))
    end
    if not actor:match('^[%x%-]+$') or #actor~=36 or not Owned(actor,peer) then
        Trace('REJECT actor='..actor..' op='..op..' ownership')
        Answer(peer,op,false,'Unable to identify the currently controlled character. Select the character and reopen level-up.')
        return
    end
    if op=='NativeClosed' then
        local txn=pending[actor]
        if not txn or txn.Peer~=peer or txn.Stage~='levelup'
            or txn.NativeClosed or tonumber(message.TargetLevel)~=txn.InitialTarget then
            Trace('DIRECT_LEVEL_NATIVE_EXIT_REJECT actor='..actor..' target='..tostring(message.TargetLevel))
            return
        end
        local live=Ext.Entity.Get(actor)
        local level=tonumber(Scalar(Scalar(live,'EocLevel'),'Level'))
        local rows=Scalar(Scalar(live,'CCLevelUp'),'LevelUps')
        local count=nil
        if rows then local ok,n=pcall(function() return #rows end);if ok then count=n end end
        if level~=txn.Current or count~=txn.Current then
            Trace('DIRECT_LEVEL_NATIVE_EXIT_STALE actor='..actor..' level='..tostring(level)
                ..' history='..tostring(count))
            pending[actor]=nil
            Answer(peer,'Failure',false,'Level-up changed while closing; no auto-level was requested.',
                {Character=actor,TargetLevel=txn.Target})
            return
        end
        txn.NativeClosed=true
        Trace('DIRECT_LEVEL_NATIVE_EXIT_ACK actor='..actor..' initial='..txn.InitialTarget
            ..' final='..txn.Target)
        RequestDirectAutoLevel(actor,txn)
        return
    end
    if op=='Disarm' then
        local txn=pending[actor]
        if txn and txn.Stage=='levelup' and txn.Peer==peer then
            pending[actor]=nil
            Trace('DISARM actor='..actor..' stage=levelup, native finish refused')
        end
        return
    end
    local success,status,extra=pcall(function()
        local entity,snapshot=Saved(actor)
        local assigned=Assigned(entity)
        -- State is a read-only identity and build-assignment query. Do not
        -- reject it simply because BG3 already exposes the next available
        -- level. That previously hid a successfully restored assignment.
        if op=='State' then
            ProbeLevelState(actor,'native_levelup_state_request_'..tostring(message.TargetLevel))
            Trace('STATE actor='..actor..' requested='..tostring(message.TargetLevel)
                ..' assigned='..tostring(assigned and assigned.File))
            return assigned and ('Assigned: '..assigned.Name) or 'No build assigned.',
                {Name=assigned and assigned.Name or '',File=assigned and assigned.File or ''}
        end
        local current=PendingLevel(actor,tonumber(message.TargetLevel),snapshot)
        if op=='Save' then
            local name=Files.CleanName(message.Name)
            local preset=Builds.Extract(snapshot,name)
            local file=Files.FileFor(name,'build')
            if Ext.IO.LoadFile(DIR..'/'..file) then
                error('A build with this name already exists. Use a different name or save through Respec to replace it.')
            end
            local ok,why=Files.Write(DIR,file,preset)
            if not ok then error(tostring(why)) end
            Trace('SAVE actor='..actor..' level='..current..' preset='..file)
            return 'Saved '..name..' through level '..current..'.', {Name=name}
        end
        if op=='Assign' then
            local file=message.File
            if type(file)~='string' then error('Invalid preset filename.') end
            local preset=VerifyPreset(file,snapshot,current+1)
            entity.Vars[VAR]={File=file,Name=preset.Name}
            assigned=Assigned(entity)
            Trace('ASSIGN actor='..actor..' preset='..file)
            return 'Assigned '..preset.Name..'.', {Name=preset.Name,File=file}
        end
        if not assigned then error('Select a build with Load Build first.') end
        local transaction=Arm(actor,peer,assigned.File,current+1)
        return 'Requesting BG3 direct auto-level to '..transaction.Target..' before applying '..assigned.Name..'…',
            {Name=assigned.Name,File=assigned.File,Target=transaction.Target}
    end)
    if not success then
        Trace('REJECT actor='..actor..' op='..op..' reason='..tostring(status))
        Answer(peer,op,false,tostring(status):gsub('^.-:%d+: ',''),
            {Character=actor,TargetLevel=message.TargetLevel})
    else
        extra=extra or {}
        extra.Character=actor
        extra.TargetLevel=message.TargetLevel
        Answer(peer,op,true,status,extra)
    end
end)
PostCommittedLevel=function(actor,txn)
    if pending[actor]~=txn or txn.Stage~='levelup' then return end
    txn.Stage='verifying'
    Trace('LEVEL_COMMITTED actor='..actor..' target='..txn.Target)
    ProbeLevelState(actor,'normal_level_committed')
    Ext.Timer.WaitFor(30000,function()
        if pending[actor]==txn and (txn.Stage=='verifying'
            or txn.Stage=='respec-starting') then
            pending[actor]=nil
            Trace('TIMEOUT actor='..actor..' phase='..txn.Stage..', handoff not completed')
            Answer(txn.Peer,'Failure',false,
                'Build handoff did not start correctly. Use normal respec or reload your save.',
                {Character=actor,TargetLevel=txn.Target})
        end
    end)
    Ext.Timer.WaitFor(1100,function()
        if pending[actor]~=txn then return end
        local ok,reason=pcall(function()
            local entity,snapshot=Saved(actor)
            if tonumber(entity.EocLevel and entity.EocLevel.Level)~=txn.Target
                or #snapshot.components.ccLevelUp.LevelUps~=txn.Target then
                error('BG3 did not commit the intended character level.')
            end
            local preset=VerifyPreset(txn.File,snapshot,txn.Target)
            local composed,why=Builds.Compose(preset,snapshot)
            if not composed then error('Build reconstruction refused: '..tostring(why)) end
            local matched,matchReason=Builds.MatchesSelections(preset,composed)
            if not matched then error('Preset coverage failed: '..tostring(matchReason)) end
            txn.Stage='respec-starting'
            ProbeLevelState(actor,'before_start_respec')
            Trace('RESPEC_START actor='..actor..' preset='..txn.File)
            Osi.StartRespec(actor)
        end)
        if not ok then
            Trace('HANDOFF_STOP actor='..actor..' after normal levelup: '..tostring(reason))
            pending[actor]=nil
            channel:SendToClient({Operation='Failure',Success=false,
                Character=actor,TargetLevel=txn.Target,
                Status='Level-up completed but build was not applied: '..tostring(reason)},User(txn.Peer))
        end
    end)
end
_G.HB_LevelUpBuildHandoff={
    TakeRespec=function(actor,respecLevel)
        local txn=pending[actor]
        if txn and txn.Stage=='respec-ready' then return {AlreadySent=true} end
        if not txn or txn.Stage~='respec-starting' then return nil end
        if tonumber(respecLevel)~=txn.Target then
            Trace('RESPEC_LEVEL_MISMATCH actor='..actor
                ..' captured='..tostring(respecLevel)..' target='..txn.Target)
            pending[actor]=nil
            return nil
        end
        txn.Stage='respec-ready'
        ProbeLevelState(actor,'native_respec_ready')
        Ext.Timer.WaitFor(120000,function()
            if pending[actor]==txn and txn.Stage=='respec-ready' then
                pending[actor]=nil
                Trace('TIMEOUT actor='..actor..' phase=respec-ready')
            end
        end)
        Trace('RESPEC_READY actor='..actor..' preset='..txn.File)
        return {File=txn.File,RequestId=actor..':levelup-build:'..tostring(txn.Target)}
    end,
    Abort=function(actor,reason)
        local txn=pending[actor]
        if not txn then return end
        pending[actor]=nil
        Trace('RESPEC_ABORT actor='..actor..' reason='..tostring(reason))
    end,
    NativeRespecCommitted=function(actor)
        local txn=pending[actor]
        if not txn or txn.Stage~='respec-ready' then return end
        txn.Stage='replay-audit'
        ProbeLevelState(actor,'native_respec_committed_level1')
        Trace('RESPEC_NATIVE_L1_COMMITTED actor='..actor
            ..' expectedRestoredLevel='..tostring(txn.Target)
            ..' waitingForAudit=true')
        Ext.Timer.WaitFor(45000,function()
            if pending[actor]==txn and txn.Stage=='replay-audit' then
                pending[actor]=nil
                Trace('RESTORE_TIMEOUT actor='..actor..' target='..txn.Target
                    ..' result=unverified')
                Answer(txn.Peer,'Failure',false,
                    'Build replay never completed verification; character may still be at level one. Reload to the original save.',
                    {Character=actor,TargetLevel=txn.Target})
            end
        end)
    end,
    ReplayResult=function(actor,success,reason)
        local txn=pending[actor]
        if not txn or (txn.Stage~='replay-audit' and txn.Stage~='respec-ready') then return end
        local level=nil
        local live=Ext.Entity.Get(actor)
        if live and live.EocLevel then level=tonumber(live.EocLevel.Level) end
        local passed=success==true and level==txn.Target
        ProbeLevelState(actor,'final_replay_audit')
        for _,delay in ipairs({500,3000,10000,25000,60000}) do
            Ext.Timer.WaitFor(delay,function() ProbeLevelState(actor,'post_replay_'..delay..'ms') end)
        end
        Trace('RESTORE_FINAL actor='..actor..' passed='..tostring(passed)
            ..' actualLevel='..tostring(level)..' target='..txn.Target
            ..' reason='..tostring(reason))
        pending[actor]=nil
        Answer(txn.Peer,'RestoreResult',passed,
            passed and ('Saved build restored through level '..txn.Target..'.')
                or ('Saved build was not restored to level '..txn.Target
                    ..' (actual level '..tostring(level or 'unknown')..'). '
                    ..tostring(reason or 'Restoration audit failed')
                    ..'. Reload the original save.'),
            {Character=actor,TargetLevel=txn.Target,ActualLevel=level})
    end,
}

-- After a successful preset import, capture the ONLY class composition that
-- has passed the complete native audit. The next XP event can cause BG3 to
-- revert EocLevel and Classes to its level-one respec foundation without
-- deleting the reconstructed level-up history. A correction may only use
-- these exact saved class rows, never infer a class from the preset file.
local classReconcileConsumed={}
local function CountHistoryAndClasses(entity)
    local rows=Scalar(Scalar(entity,'CCLevelUp'),'LevelUps')
    local history=0
    if rows then
        local ok,value=pcall(function() return #rows end)
        if ok then history=tonumber(value) or 0 end
    end
    local raw=Scalar(Scalar(entity,'Classes'),'Classes')
    local total,count=0,0
    if raw then
        pcall(function()
            for _,item in pairs(raw) do
                total=total+(tonumber(Scalar(item,'Level')) or 0)
                count=count+1
            end
        end)
    end
    return history,total,count
end
local function ValidClassData(data,target)
    if type(data)~='table' or type(data.Classes)~='table' then return false end
    local sum,count,seen=0,0,{}
    for _,row in pairs(data.Classes) do
        if type(row)~='table' then return false end
        local level=tonumber(row.Level)
        local id=tostring(row.ClassUUID or '')
        if not level or level<1 or level%1~=0 or id=='' or seen[id] then return false end
        sum=sum+level;count=count+1;seen[id]=true
    end
    return sum==target and count>0 and count<=target
end
local function CaptureVerifiedNativeClass(actor,target)
    local ok,reason=pcall(function()
        local entity=Ext.Entity.Get(actor)
        if not entity or not entity.Vars then error('Character missing') end
        local assigned=Assigned(entity)
        if not assigned then error('No assigned preset') end
        local eoc=tonumber(Scalar(Scalar(entity,'EocLevel'),'Level'))
        local history,classTotal=CountHistoryAndClasses(entity)
        if target<2 or target>40 or eoc~=target or history~=target or classTotal~=target then
            error('Final native state not completely verified')
        end
        local raw=Ext.Types.Serialize(entity.Classes)
        if not ValidClassData(raw,target) then error('Serialized classes invalid') end
        entity.Vars[VAR]={File=assigned.File,Name=assigned.Name,
            VerifiedLevel=target,VerifiedClasses=raw}
        classReconcileConsumed[actor]=nil
        Trace('ENGINE_CLASS_BASELINE actor='..actor..' level='..target
            ..' classTotal='..classTotal..' history='..history)
    end)
    if not ok then
        Trace('ENGINE_CLASS_BASELINE_REFUSED actor='..actor..' level='..tostring(target)
            ..' reason='..tostring(reason))
    end
    return ok
end
local function MaybeReconcileVerifiedClass(actor,oldAvailable,newAvailable)
    local entity=Ext.Entity.Get(actor)
    if not entity or not entity.Vars then return end
    local saved=Assigned(entity)
    if not saved then return end
    local target=tonumber(saved.VerifiedLevel)
    if not target or target<2 or target>40 or target%1~=0
        or not ValidClassData(saved.VerifiedClasses,target)
        or tonumber(oldAvailable)~=target or tonumber(newAvailable)~=target+1 then
        return
    end
    -- Capture health *before* BG3's delayed level-one fallback. A successful
    -- preset replay already repaired HP; the later engine reset discards that
    -- corrected Health component independently of CCLevelUp/class history.
    -- Never restore from the original preset's HP or assume a class's hit die.
    local beforeHealth=nil
    local captureOK,captureError=pcall(function()
        local recorded,classTotal=CountHistoryAndClasses(entity)
        local health=Scalar(entity,'Health')
        local hp=tonumber(Scalar(health,'Hp'))
        local maximum=tonumber(Scalar(health,'MaxHp'))
        local scores=Scalar(Scalar(entity,'Stats'),'Abilities')
        local abilities={}
        if not scores then return end
        for i=1,7 do
            abilities[i]=tonumber(Scalar(scores,i))
            if not abilities[i] then return end
        end
        if tonumber(Scalar(Scalar(entity,'EocLevel'),'Level'))~=target
            or recorded~=target or classTotal~=target
            or not hp or not maximum or maximum<1 or maximum>100000
            or hp<0 or hp>maximum then return end
        local proficiency=tonumber(Scalar(Scalar(entity,'Stats'),'ProficiencyBonus'))
        beforeHealth={Hp=hp,MaxHp=maximum,Abilities=abilities,
            Proficiency=proficiency and proficiency%1==0 and proficiency>2
                and proficiency<=20 and proficiency or nil}
    end)
    Trace('ENGINE_HEALTH_BASELINE actor='..actor
        ..' target='..target
        ..' hp='..tostring(beforeHealth and beforeHealth.Hp)
        ..' max='..tostring(beforeHealth and beforeHealth.MaxHp)
        ..' proficiency='..tostring(beforeHealth and beforeHealth.Proficiency)
        ..' valid='..tostring(captureOK and beforeHealth~=nil)
        ..(captureOK and '' or ' error='..tostring(captureError)))
    local key=tostring(target)..':'..tostring(newAvailable)
    if classReconcileConsumed[actor]==key then return end
    -- This consumes precisely one potential correction for this XP event.
    -- No loop or repeated engine writes are permitted.
    classReconcileConsumed[actor]=key
    Ext.Timer.WaitFor(330,function()
        local live=Ext.Entity.Get(actor)
        if not live or not live.EocLevel or not live.Classes then return end
        local eoc=tonumber(Scalar(live.EocLevel,'Level'))
        local available=tonumber(Scalar(Scalar(live,'AvailableLevel'),'Level'))
        local history,classTotal,classCount=CountHistoryAndClasses(live)
        Trace('ENGINE_CLASS_GUARD actor='..actor..' eoc='..tostring(eoc)
            ..' available='..tostring(available)..' history='..history
            ..' classTotal='..classTotal..' classCount='..classCount
            ..' target='..target)
        if eoc==target and classTotal==target then
            Trace('ENGINE_CLASS_GUARD_SKIPPED actor='..actor..' reason=no_reset')
            return
        end
        -- A very specific BG3 fallback was observed: Classes/EocLevel=1 but
        -- the full validated CCLevelUp history remains intact. Reject every
        -- other mismatch and never touch XP or available-level counters.
        if eoc~=1 or classTotal~=1 or history~=target or available~=target+1 then
            Trace('ENGINE_CLASS_GUARD_REFUSED actor='..actor..' reason=mismatch')
            return
        end
        local recheck=Assigned(live)
        if not recheck or recheck.File~=saved.File
            or recheck.VerifiedLevel~=target
            or not ValidClassData(recheck.VerifiedClasses,target) then
            Trace('ENGINE_CLASS_GUARD_REFUSED actor='..actor..' reason=assignment_changed')
            return
        end
        local before=Ext.Types.Serialize(live.Classes)
        local worked,err=pcall(function()
            Ext.Types.Unserialize(live.Classes,recheck.VerifiedClasses)
            live:MarkChanged('Classes')
            live:Replicate('Classes')
            live.EocLevel.Level=target
            live:MarkChanged('EocLevel')
            live:Replicate('EocLevel')
        end)
        if not worked then
            -- Preserve the engine's current class rows if partial restore failed.
            pcall(function()
                Ext.Types.Unserialize(live.Classes,before)
                live:MarkChanged('Classes'); live:Replicate('Classes')
            end)
            Trace('ENGINE_CLASS_RECONCILE_FAILED actor='..actor..' error='..tostring(err))
            return
        end
        Trace('ENGINE_CLASS_RECONCILE_ATTEMPT actor='..actor..' target='..target
            ..' method=verified_components XP=untouched')
        -- BG3 also replaces Health with the level-one maximum during this
        -- event (88/88 -> 36/36 in the confirmed Barbarian test). Reconcile
        -- once after native class replication has settled. Preserve the exact
        -- pre-event current HP, not only its maximum, and replicate to the UI.
        Ext.Timer.WaitFor(150,function()
            local safe,problem=pcall(function()
                local updated=Ext.Entity.Get(actor)
                if not updated then return 'entity_unavailable' end
                local currentLevel=tonumber(Scalar(Scalar(updated,'EocLevel'),'Level'))
                local availableLevel=tonumber(Scalar(Scalar(updated,'AvailableLevel'),'Level'))
                local historyNow,classesNow=CountHistoryAndClasses(updated)
                if not beforeHealth then return 'pre_event_health_not_verified' end
                if currentLevel~=target or availableLevel~=target+1
                    or historyNow~=target or classesNow~=target then
                    return 'level_or_history_changed'
                end
                local current=Scalar(updated,'Health')
                local hp=tonumber(Scalar(current,'Hp'))
                local maximum=tonumber(Scalar(current,'MaxHp'))
                if not hp or not maximum or maximum<1 or hp<0 or hp>maximum then
                    return 'invalid_live_health'
                end
                local scores=Scalar(Scalar(updated,'Stats'),'Abilities')
                if not scores then return 'abilities_missing' end
                for i=1,7 do
                    if tonumber(Scalar(scores,i))~=beforeHealth.Abilities[i] then
                        return 'abilities_changed'
                    end
                end
                -- If the engine has already recovered HP, replicate the known
                -- correct value to refresh the native HUD; never heal damage.
                local needsRestore=maximum<beforeHealth.MaxHp
                if not needsRestore and (maximum~=beforeHealth.MaxHp
                    or hp~=beforeHealth.Hp) then return 'health_changed_independently' end
                -- A lower max must have clamped the old HP and cannot include
                -- an additional, untracked HP change within this event.
                if needsRestore and hp~=math.min(beforeHealth.Hp,maximum) then
                    return 'unexpected_hp_at_lower_max'
                end
                if needsRestore then
                    current.MaxHp=beforeHealth.MaxHp
                    current.Hp=beforeHealth.Hp
                end
                updated:MarkChanged('Health')
                updated:Replicate('Health')
                Trace('ENGINE_HEALTH_RECONCILE actor='..actor
                    ..' applied='..tostring(needsRestore)
                    ..' replicated=true before='..tostring(hp)..'/'..tostring(maximum)
                    ..' after='..tostring(beforeHealth.Hp)..'/'..tostring(beforeHealth.MaxHp)
                    ..' XP=untouched')
                return nil
            end)
            if not safe or problem then
                Trace('ENGINE_HEALTH_RECONCILE_REFUSED actor='..actor
                    ..' reason='..tostring(safe and problem or problem))
            end
            -- The same delayed native fallback may replace the computed
            -- proficiency with its level-one +2. Refresh only that residue;
            -- never modify level counters, class history or stat templates.
            local profOK,profWhy=pcall(function()
                local restored=Ext.Entity.Get(actor)
                local expected=beforeHealth and beforeHealth.Proficiency
                if not expected then return 'pre_event_proficiency_not_verified' end
                if not restored then return 'entity_unavailable' end
                local eoc=tonumber(Scalar(Scalar(restored,'EocLevel'),'Level'))
                local avail=tonumber(Scalar(Scalar(restored,'AvailableLevel'),'Level'))
                local historyNow,classesNow=CountHistoryAndClasses(restored)
                if eoc~=target or avail~=target+1 or historyNow~=target
                    or classesNow~=target then return 'level_or_history_changed' end
                local stats=Scalar(restored,'Stats')
                local scores=Scalar(stats,'Abilities')
                if not stats or not scores then return 'stats_unavailable' end
                for i=1,7 do
                    if tonumber(Scalar(scores,i))~=beforeHealth.Abilities[i] then
                        return 'abilities_changed'
                    end
                end
                local current=tonumber(Scalar(stats,'ProficiencyBonus'))
                if not current or current%1~=0 or current<1 or current>20 then
                    return 'live_proficiency_invalid'
                end
                if current~=expected and current~=2 then
                    return 'proficiency_changed_independently'
                end
                local applied=current==2
                if applied then
                    stats.ProficiencyBonus=expected
                    if tonumber(Scalar(stats,'ProficiencyBonus'))~=expected then
                        return 'proficiency_write_not_accepted'
                    end
                end
                restored:MarkChanged('Stats')
                restored:Replicate('Stats')
                Trace('ENGINE_PROFICIENCY_RECONCILE actor='..actor
                    ..' applied='..tostring(applied)
                    ..' before='..tostring(current)..' after='..tostring(expected)
                    ..' replicated=true')
                return nil
            end)
            if not profOK or profWhy then
                Trace('ENGINE_PROFICIENCY_RECONCILE_REFUSED actor='..actor
                    ..' reason='..tostring(profWhy))
            end
        end)
        for _,delay in ipairs({250,1200,4000}) do
            Ext.Timer.WaitFor(delay,function()
                local updated=Ext.Entity.Get(actor)
                if not updated then return end
                local now=tonumber(Scalar(Scalar(updated,'EocLevel'),'Level'))
                local cc,sum=CountHistoryAndClasses(updated)
                local health=Scalar(updated,'Health')
                local hp=tonumber(Scalar(health,'Hp'))
                local maxHp=tonumber(Scalar(health,'MaxHp'))
                Trace('ENGINE_CLASS_RECONCILE_VERIFY actor='..actor
                    ..' afterMs='..delay..' eoc='..tostring(now)
                    ..' classTotal='..sum..' history='..cc
                    ..' hp='..tostring(hp)..'/'..tostring(maxHp)
                    ..' proficiency='..tostring(Scalar(Scalar(updated,'Stats'),'ProficiencyBonus'))
                    ..' success='..tostring(now==target and sum==target and cc==target))
                -- Read-only client comparison, not a UI refresh or a level write.
                local ok,peer=pcall(Osi.GetReservedUserID,actor)
                if ok then
                    peer=tonumber(peer)
                    if peer and peer>0 then
                        local sent,err=pcall(function()
                            channel:SendToClient({Operation='LevelSyncProbe',Character=actor,
                                ServerLevel=now,ServerClassLevel=sum,ServerHistory=cc,
                                TargetLevel=target,AfterMs=delay,
                                ServerHp=hp,ServerMaxHp=maxHp},User(peer))
                        end)
                        Trace('LEVEL_SYNC_CLIENT_SEND actor='..actor
                            ..' afterMs='..delay..' ok='..tostring(sent)
                            ..' error='..tostring(err))
                    else
                        Trace('LEVEL_SYNC_CLIENT_UNAVAILABLE actor='..actor
                            ..' afterMs='..delay..' reason=no_owner')
                    end
                end
            end)
        end
    end)
end

-- The comparison remains enabled to check the engine state before and after.
-- Comparative observation only. This code never attempts SetLevel or changes
-- XP/classes: we need to distinguish the native level-up-to-respec handoff
-- from a standard, manually initiated respec build import.
local function IsTrackedImport(actor)
    if observedCharacters[actor] then return true,'level-up handoff' end
    local ok,owner=pcall(Ext.Entity.Get,actor)
    if not ok or not owner then return false,'no entity' end
    local ok2,assigned=pcall(function()
        return owner.Vars and owner.Vars[VAR]
    end)
    if ok2 and type(assigned)=='table' and type(assigned.File)=='string'
        and assigned.File~='' then
        return true,'assigned build'
    end
    return false,'not assigned'
end
local function ObserveLevelChange(actor,oldLevel,newLevel)
    local tracked,origin=IsTrackedImport(actor)
    if not tracked then return end
    Trace('COMPARE_AVAILABLE actor='..actor..' origin='..origin
        ..' old='..tostring(oldLevel)..' new='..tostring(newLevel))
    ProbeLevelState(actor,'compare_available_immediate')
    local ok,peer=pcall(Osi.GetReservedUserID,actor)
    if ok then
        peer=tonumber(peer)
        if peer and peer>0 then
            pcall(function() channel:SendToClient({Operation='LevelSyncProbe',
                Character=actor,AfterMs=0,TargetLevel=oldLevel,
                ServerLevel=tonumber(Scalar(Scalar(Ext.Entity.Get(actor),'EocLevel'),'Level')),
                Phase='available_change'},User(peer)) end)
        end
    end
    MaybeReconcileVerifiedClass(actor,oldLevel,newLevel)
    for _,ms in ipairs({250,1000,4000,10000}) do
        local delay=ms
        Ext.Timer.WaitFor(delay,function()
            local still=IsTrackedImport(actor)
            if still then ProbeLevelState(actor,'compare_available_plus_'..delay) end
        end)
    end
end
if Ext.Osiris and Ext.Osiris.RegisterListener then
    pcall(Ext.Osiris.RegisterListener,'ObjectAvailableLevelChanged',3,'after',
        function(character,oldLevel,newLevel)
            ObserveLevelChange(Guid(character),oldLevel,newLevel)
        end)
end
_G.HB_LevelUpBuildVerifiedNativeClasses=CaptureVerifiedNativeClass
Trace('READY: verified native class replay guard; SetLevel disabled')
