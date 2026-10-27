PartialRespecSnapshot = PartialRespecSnapshot or {}

local ComponentSpecs = {
    -- MulticlassSpellSlotOverride/field_50 are C++ maps, assigning the JSON table back throws an error
    { name = "ProgressionMeta",                key = "meta",               skip = { Owner = true, MulticlassSpellSlotOverride = true, field_50 = true } },
    { name = "ProgressionAbilityImprovements", key = "abilityImprovements" },
    { name = "ProgressionFeat",                key = "feat" },
    { name = "ProgressionSpells",              key = "spells" },
    { name = "ProgressionSkills",              key = "skills" },
    { name = "ProgressionPassives",            key = "passives" },
    { name = "ProgressionReplicatedFeat",      key = "replicatedFeat" },
    { name = "LevelUp",                        key = "levelUp" },
}

local CharacterComponentSpecs = {
    { name = "Classes",           key = "classes" },
    { name = "SpellBook",         key = "spellBook" },
    { name = "SpellBookPrepares", key = "spellBookPrepares" },
    { name = "LearnedSpells",     key = "learnedSpells" },
    { name = "CCLevelUp",         key = "ccLevelUp" },
}

--- Serializes a live component into plain data for the snapshot; restore re-applies it via Unserialize.
---@param component table|nil
---@param skip table<string, boolean>|nil
---@param label string
---@return table|nil
local function SerializeComponent(component, skip, label)
    if not component then
        return nil
    end

    local data = Ext.Types.Serialize(component)
    if type(data) ~= "table" then
        error(("Could not serialize %s: %s"):format(label, tostring(data)))
    end

    for key in pairs(skip or {}) do
        data[key] = nil
    end
    data.Entity = nil
    return data
end

--- Marks a component changed and replicates it so the engine and peers pick up restored data.
---@param entity EntityHandle
---@param componentName ExtComponentType
local function MarkComponentChanged(entity, componentName, replicate)
    entity:MarkChanged(componentName)

    if replicate == false then return end

    -- expects ExtComponentType here
    entity:Replicate(componentName)
end

--- Captures one progression entity (meta, feat, spells, skills, ...) into serializable form.
---@param entity EntityHandle
---@return table
local function SnapshotProgressionEntry(entity)
    local entry = {}

    for _, spec in ipairs(ComponentSpecs) do
        local component = entity[spec.name]
        local serialized = SerializeComponent(component, spec.skip, spec.name)
        if serialized then
            entry[spec.key] = serialized
        end
    end

    return entry
end

--- Captures the character state (components + progression buckets) before the vanilla respec wipes it.
---@param character EntityHandle
---@return table
local function SnapshotCharacter(character)
    local snapshot = {
        schemaVersion = 2,
        components = {},
        progressions = { buckets = {} },
    }

    for _, spec in ipairs(CharacterComponentSpecs) do
        snapshot.components[spec.key] = SerializeComponent(character[spec.name], nil, spec.name)
    end

    local container = character.ProgressionContainer
    if container and container.Progressions then
        for level, bucket in ipairs(container.Progressions) do
            snapshot.progressions.buckets[level] = {}

            for _, progressionEntity in ipairs(bucket) do
                table.insert(snapshot.progressions.buckets[level], SnapshotProgressionEntry(progressionEntity))
            end
        end
    end

    return snapshot
end

---@param characterRef string|EntityHandle|nil
---@return EntityHandle
local function ResolveCharacter(characterRef)
    local ref = characterRef or Osi.GetHostCharacter()
    if not characterRef then
        PRWarn(0, "PartialRespecSnapshot: no character given, falling back to host %s", tostring(ref))
    end
    local character = Ext.Entity.Get(ref)
    if not character then
        error("Could not resolve character: " .. tostring(ref))
    end
    return character
end

---@param path string
---@param snapshot table
function PartialRespecSnapshot.Save(path, snapshot)
    if PRPrinter.DebugLevel < 1 then return end

    local json = Ext.Json.Stringify(snapshot, { Beautify = true, StringifyInternalTypes = false })
    if not Ext.IO.SaveFile(path, json) then
        error("Failed to save snapshot: " .. path)
    end
    PRPrint(1, "PartialRespecSnapshot saved %s", path)
end

---@param path string
---@param characterRef string|EntityHandle|nil
---@return table snapshot
function PartialRespecSnapshot.SaveCharacter(path, characterRef)
    local character = ResolveCharacter(characterRef)
    local snapshot = SnapshotCharacter(character)
    PartialRespecSnapshot.Save(path, snapshot)
    return snapshot
end

-- Level-one historical editing MUST NEVER reconstruct the first-level bucket.
-- The vanilla engine owns those progression entities and has already applied
-- starting +3/+1 bonuses. Re-creating snapshot entries duplicates those bonuses.
local function L1Equal(a,b,depth)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    if (depth or 0)>24 then return false end
    for k,v in pairs(a) do if not L1Equal(v,b[k],(depth or 0)+1) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function L1MetaKey(meta)
    if type(meta)~="table" or tonumber(meta.Level)~=1 then return nil end
    local progression=tostring(meta.Progression or "")
    local source=tostring(meta.Source or "")
    local kind=tostring(meta.SpellSourceType or "")
    if progression=="" or source=="" or kind=="" then return nil end
    return table.concat({progression,source,kind,tostring(meta.ClassLevel or "")},"|")
end
local function L1ChoiceFieldsValid(before,after,kind)
    if type(before)~="table" or type(after)~="table" then
        return false,"missing serialized choice component"
    end
    local fields=kind=="passives" and {AddPassives=true}
        or kind=="skills" and {Proficiencies=true,Expertise=true}
        or kind=="spells" and {AddSpells=true} or nil
    if not fields then return false,"unsupported component kind" end
    for k,v in pairs(before) do
        if not fields[k] and not L1Equal(v,after[k]) then
            return false,"protected component property changed: "..tostring(k)
        end
    end
    for k in pairs(after) do
        if before[k]==nil then return false,"new component property: "..tostring(k) end
    end
    for field in pairs(fields) do
        local original=before[field] or {}
        local revised=after[field] or {}
        if type(original)~="table" or type(revised)~="table"
            or #original~=#revised then
            return false,"selection count changed: "..field
        end
        for i,value in ipairs(original) do
            local nextValue=revised[i]
            if kind=="spells" and field=="AddSpells" then
                if type(value)~="table" or type(nextValue)~="table" then
                    return false,"malformed spell entry: "..field
                end
                if type(value.SpellId)~="string" or type(nextValue.SpellId)~="string"
                    or nextValue.SpellId=="" then
                    return false,"invalid spell identifier: "..field
                end
                local saved=value.SpellId
                value.SpellId=nextValue.SpellId
                local same=L1Equal(value,nextValue)
                value.SpellId=saved
                if not same then return false,"protected spell metadata changed: "..field end
            else
                local function PlainChoiceId(candidate)
                    local kind=type(candidate)
                    if kind~="string" and kind~="userdata" then return nil end
                    local id=tostring(candidate)
                    if id=="" or not id:match("^[%a_][%w_]*$") then return nil end
                    return id
                end
                if not PlainChoiceId(value) or not PlainChoiceId(nextValue) then
                    return false,"invalid chosen ID: "..field.."["..i.."]"
                        .." originalType="..type(value)
                        .." newType="..type(nextValue)
                end
            end
        end
    end
    return true
end

-- Validate both snapshots first, then map EVERY vanilla level-one entity by
-- immutable ProgressionMeta identity. All four originals must be present once;
-- any missing/duplicated entry or changed starting ability component aborts.
-- No C++ references are carried between ticks.
local function L1SurgeryPlan(character,original,patched)
    local old=original and original.progressions and original.progressions.buckets[1]
    local new=patched and patched.progressions and patched.progressions.buckets[1]
    local live=character and character.ProgressionContainer
        and character.ProgressionContainer.Progressions
        and character.ProgressionContainer.Progressions[1]
    if type(old)~="table" or type(new)~="table" or not live or #old==0
        or #old~=#new or #live~=#old then
        return nil,"Level-one vanilla progression count differs from the original snapshot"
    end
    local oldMap,changes={},{}
    for i,row in ipairs(old) do
        local after=new[i]
        local key=L1MetaKey(row.meta)
        if not key or oldMap[key] or not after or L1MetaKey(after.meta)~=key
            or not L1Equal(row.meta,after.meta) then
            return nil,"Level-one progression owner is missing, reordered or duplicated"
        end
        oldMap[key]=row
        -- A protected level-one component must remain exactly unchanged.
        for k,v in pairs(row) do
            if k~="passives" and k~="skills" and k~="spells"
                and not L1Equal(v,after[k]) then
                return nil,"Protected starting progression component was changed: "..k
            end
        end
        for k in pairs(after) do if row[k]==nil then
            return nil,"Unexpected new level-one progression component: "..k
        end end
        for _,kind in ipairs({"passives","skills","spells"}) do
            if not L1Equal(row[kind],after[kind]) then
                local role=tostring((row.meta or {}).SpellSourceType or "")
                if role~="ProgressionClass" and role~="ProgressionSubClass" then
                    return nil,"Level-one edit has a foreign progression owner: "..kind
                end
                local safe,reason=L1ChoiceFieldsValid(row[kind],after[kind],kind)
                if not safe then
                    return nil,"Level-one "..kind.." choice component mismatch: "..tostring(reason)
                end
                changes[#changes+1]={Key=key,Kind=kind,Before=row[kind],After=after[kind]}
            end
        end
    end
    if #changes==0 then return nil,"No verified level-one choice effect was changed" end
    local mapped={}
    for _,entity in ipairs(live) do
        local meta=entity and entity.ProgressionMeta
        local key=meta and L1MetaKey(Ext.Types.Serialize(meta))
        if not key or not oldMap[key] or mapped[key] then
            return nil,"Vanilla level-one progression has unexpected or duplicate ownership"
        end
        mapped[key]=entity
        local ability=entity.ProgressionAbilityImprovements
        if not L1Equal(ability and Ext.Types.Serialize(ability) or nil,
            oldMap[key].abilityImprovements) then
            return nil,"Starting ability bonuses are not identical to the original"
        end
    end
    for key in pairs(oldMap) do if not mapped[key] then
        return nil,"A verified starting progression owner is absent"
    end end
    for _,change in ipairs(changes) do
        local target=mapped[change.Key]
        local field=({passives="ProgressionPassives",skills="ProgressionSkills",
            spells="ProgressionSpells"})[change.Kind]
        local component=target and target[field]
        if not component or not L1Equal(Ext.Types.Serialize(component),change.Before) then
            return nil,"Starting choice component no longer matches its original grant"
        end
    end
    return changes,nil
end

function PartialRespecSnapshot.ValidateLevelOneSurgery(characterRef,original,patched)
    return L1SurgeryPlan(ResolveCharacter(characterRef),original,patched)
end

-- Post-replay observation. Never reapply or reconstruct level-one records
-- during the audit: a failed check is diagnostic and requires a known-good
-- save, not another destructive replay.
function PartialRespecSnapshot.AuditLevelOneSurgery(characterRef,original,patched)
    local character=ResolveCharacter(characterRef)
    local expected=patched and patched.progressions
        and patched.progressions.buckets[1]
    local previous=original and original.progressions
        and original.progressions.buckets[1]
    local live=character and character.ProgressionContainer
        and character.ProgressionContainer.Progressions
        and character.ProgressionContainer.Progressions[1]
    if type(expected)~="table" or type(previous)~="table" or not live
        or #expected~=#previous or #live~=#previous then
        return false,"Level-one progression entity count differs from the original"
    end
    local indexed={}
    for _,entity in ipairs(live) do
        local key=entity.ProgressionMeta and
            L1MetaKey(Ext.Types.Serialize(entity.ProgressionMeta))
        if not key or indexed[key] then return false,"Repeated/unrecognized level-one owner" end
        indexed[key]=entity
    end
    for i,row in ipairs(previous) do
        local updated=expected[i]
        local key=L1MetaKey(row.meta)
        local entity=key and indexed[key]
        if not entity or not updated or L1MetaKey(updated.meta)~=key then
            return false,"Original level-one owner absent after replay"
        end
        if not L1Equal(entity.ProgressionAbilityImprovements
                and Ext.Types.Serialize(entity.ProgressionAbilityImprovements) or nil,
                row.abilityImprovements) then
            return false,"Original level-one ability bonuses changed"
        end
        for _,spec in ipairs({{name="ProgressionPassives",key="passives"},
            {name="ProgressionSpells",key="spells"},
            {name="ProgressionSkills",key="skills"}}) do
            local component=entity[spec.name]
            if not L1Equal(component and Ext.Types.Serialize(component) or nil,
                    updated[spec.key]) then
                return false,"Level-one choice effects differ from committed "..spec.key
            end
        end
    end
    return true,nil
end

function PartialRespecSnapshot.ApplyLevelOneSurgery(characterRef,original,patched)
    local character=ResolveCharacter(characterRef)
    local changes,err=L1SurgeryPlan(character,original,patched)
    if not changes then error("Level-one choice replay refused: "..tostring(err)) end
    -- Re-identify native entities afresh and never mutate progression metadata,
    -- ability-improvement components or character base stats.
    local live=character.ProgressionContainer.Progressions[1]
    local entities={}
    for _,entity in ipairs(live) do
        entities[L1MetaKey(Ext.Types.Serialize(entity.ProgressionMeta))]=entity
    end
    local written={}
    for _,change in ipairs(changes) do
        local entity=entities[change.Key]
        local field=({passives="ProgressionPassives",skills="ProgressionSkills",
            spells="ProgressionSpells"})[change.Kind]
        local component=entity[field]
        local ok,why=pcall(function()
            Ext.Types.Unserialize(component,change.After)
            entity:MarkChanged(field)
            -- Progression entities are native-owned; component MarkChanged is
            -- the same update contract as ordinary progression replay.
        end)
        if not ok then
            -- Best-effort rollback of every choice component touched so far.
            pcall(function() Ext.Types.Unserialize(component,change.Before);entity:MarkChanged(field) end)
            for i=#written,1,-1 do
                local prior=written[i]
                pcall(function()
                    Ext.Types.Unserialize(prior.Component,prior.Change.Before)
                    prior.Entity:MarkChanged(prior.Field)
                end)
            end
            error("Level-one component update failed: "..tostring(why))
        end
        written[#written+1]={Component=component,Change=change,Entity=entity,Field=field}
    end
    return #written
end

-- Best-effort surgical undo, only if the exact freshly staged choices still
-- belong to the same live progression owner. This must not create or destroy
-- any progression entity or modify ability bonuses. If the native objects
-- have disappeared or changed, it intentionally refuses instead of guessing.
function PartialRespecSnapshot.RestoreLevelOneChoices(characterRef,original,patched)
    return PartialRespecSnapshot.ApplyLevelOneSurgery(characterRef,patched,original)
end

-- Level-one progression component mutation alone does not necessarily
-- update the *active* passive inventory. The game-owned respec regenerates
-- those effects when CCLevelUp is restored. Use the existing Osiris passive
-- APIs, with exact grant ownership, only AFTER the native restoration settles.
-- This is generic for simple passive replacements; it does not recreate
-- progressions or touch AbilityImprovements, Classes, Skills, or SpellBook.
local function L1PassiveDelta(original,patched)
    local old=original and original.progressions and original.progressions.buckets
    local new=patched and patched.progressions and patched.progressions.buckets
    if type(old)~="table" or type(new)~="table" or type(old[1])~="table"
        or type(new[1])~="table" or #old[1]~=#new[1] then
        error("Level-one passive ownership history missing")
    end
    local removal,addition={},{}
    local oldSourceCounts={}
    for _,bucket in pairs(old) do
        if type(bucket)=="table" then
            for _,row in ipairs(bucket) do
                for _,id in ipairs(row.passives and row.passives.AddPassives or {}) do
                    id=tostring(id)
                    oldSourceCounts[id]=(oldSourceCounts[id] or 0)+1
                end
            end
        end
    end
    for i,before in ipairs(old[1]) do
        local after=new[1][i]
        if not after or not L1Equal(before.meta,after.meta) then
            error("Level-one passive progression owner mismatch")
        end
        local lhs=before.passives and before.passives.AddPassives or {}
        local rhs=after.passives and after.passives.AddPassives or {}
        if #lhs~=#rhs then error("Level-one passive slot count changed") end
        local oldSlots,newSlots={},{}
        for _,value in ipairs(lhs) do
            value=tostring(value); oldSlots[value]=(oldSlots[value] or 0)+1
        end
        for _,value in ipairs(rhs) do
            value=tostring(value); newSlots[value]=(newSlots[value] or 0)+1
        end
        for id,count in pairs(oldSlots) do
            local diff=count-(newSlots[id] or 0)
            if diff>0 then
                if oldSourceCounts[id]~=1 or diff~=1 then
                    error("Starting passive has overlapping progression ownership: "..id)
                end
                removal[id]=true
            end
        end
        for id,count in pairs(newSlots) do
            local diff=count-(oldSlots[id] or 0)
            if diff>0 then
                if diff~=1 or (oldSourceCounts[id] or 0)~=0 then
                    error("Replacement passive is already granted by progression: "..id)
                end
                addition[id]=true
            end
        end
    end
    for id in pairs(removal) do if addition[id] then
        error("Same passive simultaneously removed and added: "..id)
    end end
    local gone,added=0,0
    for _ in pairs(removal) do gone=gone+1 end
    for _ in pairs(addition) do added=added+1 end
    if gone~=added then error("Inconsistent level-one passive replacement cardinality") end
    return removal,addition,gone
end

function PartialRespecSnapshot.AuditLevelOnePassiveEffects(characterRef,original,patched)
    local removed,added=L1PassiveDelta(original,patched)
    local entity=ResolveCharacter(characterRef)
    local characterGuid=(type(characterRef)=="string" and characterRef)
        or tostring(entity.Uuid and entity.Uuid.EntityUuid or "")
    if characterGuid=="" then return false,"Cannot resolve passive owner GUID" end
    if not Osi or not Osi.HasPassive then return false,"Osiris passive inspection unavailable" end
    for id in pairs(removed) do
        if Osi.HasPassive(characterGuid,id)~=0 then
            return false,"Previous passive remains active: "..id
        end
    end
    for id in pairs(added) do
        if Osi.HasPassive(characterGuid,id)~=1 then
            return false,"Replacement passive is not active: "..id
        end
    end
    return true,"active passives match"
end

function PartialRespecSnapshot.ApplyLevelOnePassiveEffects(characterRef,original,patched)
    local removed,added,count=L1PassiveDelta(original,patched)
    if count==0 then return 0 end
    local character=ResolveCharacter(characterRef)
    local characterGuid=(type(characterRef)=="string" and characterRef)
        or tostring(character.Uuid and character.Uuid.EntityUuid or "")
    if characterGuid=="" or not Osi or not Osi.HasPassive or not Osi.RemovePassive
        or not Osi.AddPassive then
        error("Osiris passive mutation is unavailable for this character")
    end
    for id in pairs(removed) do
        if Osi.HasPassive(characterGuid,id)~=1 then
            error("Original passive is not active: "..id)
        end
    end
    for id in pairs(added) do
        if Osi.HasPassive(characterGuid,id)~=0 then
            error("Replacement passive already active from another owner: "..id)
        end
    end
    local removedDone,addedDone={},{}
    local ok,reason=pcall(function()
        for id in pairs(removed) do
            Osi.RemovePassive(characterGuid,id)
            removedDone[#removedDone+1]=id
        end
        for id in pairs(added) do
            Osi.AddPassive(characterGuid,id)
            addedDone[#addedDone+1]=id
        end
    end)
    if not ok then
        for _,id in ipairs(addedDone) do pcall(Osi.RemovePassive,characterGuid,id) end
        for _,id in ipairs(removedDone) do pcall(Osi.AddPassive,characterGuid,id) end
        error("Could not update starting passives: "..tostring(reason))
    end
    return count
end

-- Pilot: the original level-one PushingAttack grants are two spellbook
-- entries owned by the Fighter's ProgressionClass source. RemovePassive does
-- not remove those grants. Test the documented Osiris RemoveSpell call only
-- after proving the *exact original progression source* owns each spell.
-- This is intentionally a narrow diagnostic of engine behavior, not a generic
-- SpellBook mutation or a new level-one reconstruction strategy.
function PartialRespecSnapshot.TryRemoveLevelOneProgressionSpellGrants(characterRef,original,patched)
    local removed,added,count=L1PassiveDelta(original,patched)
    if count~=1 or not removed.PushingAttack or not added.Rally then
        return 0,"pilot skipped: not the exact PushingAttack to Rally delta"
    end
    local old=original and original.progressions and original.progressions.buckets
    local bucket=old and old[1]
    local ownerSource=nil
    for _,row in ipairs(bucket or {}) do
        local found=0
        for _,id in ipairs(row.passives and row.passives.AddPassives or {}) do
            if tostring(id)=="PushingAttack" then found=found+1 end
        end
        if found>0 then
            if found~=1 or ownerSource then
                return nil,"old passive progression ownership is ambiguous"
            end
            local meta=row.meta
            if not meta or tostring(meta.SpellSourceType or "")~="ProgressionClass" then
                return nil,"old passive is not a class progression grant"
            end
            ownerSource=tostring(meta.Source or "")
        end
    end
    if not ownerSource or ownerSource=="" then
        return nil,"old passive owner source is missing"
    end
    local ids={Projectile_PushingAttack=true,Target_PushingAttack=true}
    local found={}
    local function CheckBook(entries,label)
        if type(entries)~="table" then
            return nil,label.." spellbook unavailable"
        end
        local seen={}
        for _,spell in ipairs(entries) do
            local sid=spell and spell.Id
            if sid then
                local prototype=tostring(sid.Prototype or "")
                if ids[prototype] then
                    seen[prototype]=(seen[prototype] or 0)+1
                    if seen[prototype]>1
                        or tostring(sid.ProgressionSource or "")~=ownerSource
                        or tostring(sid.SourceType or "")~="ProgressionClass"
                        or tostring(sid.OriginatorPrototype or "")~=prototype then
                        return nil,label.." spell has ambiguous or foreign owner: "..prototype
                    end
                end
            end
        end
        if seen.Projectile_PushingAttack~=1 or seen.Target_PushingAttack~=1 then
            return nil,label.." does not contain both uniquely-owned PushingAttack spells"
        end
        return true
    end
    local originalBook=original and original.components and original.components.spellBook
    local ok,reason=CheckBook(originalBook and originalBook.Spells,"original")
    if not ok then return nil,reason end
    local character=ResolveCharacter(characterRef)
    local characterGuid=(type(characterRef)=="string" and characterRef)
        or tostring(character and character.Uuid and character.Uuid.EntityUuid or "")
    if characterGuid=="" or not Osi or not Osi.RemoveSpell then
        return nil,"Osiris RemoveSpell is unavailable"
    end
    -- Live spells are inspected in the same script tick. Never hold C++ spell
    -- references across scheduled callbacks.
    local liveBook=character and character.SpellBook and character.SpellBook.Spells
    if not liveBook then return nil,"live spellbook unavailable" end
    local live={}
    for _,row in ipairs(liveBook) do
        local sid=row and row.Id
        if sid then
            local proto=tostring(sid.Prototype or "")
            if ids[proto] then
                live[proto]=(live[proto] or 0)+1
                if live[proto]>1
                    or tostring(sid.ProgressionSource or "")~=ownerSource
                    or tostring(sid.SourceType or "")~="ProgressionClass"
                    or tostring(sid.OriginatorPrototype or "")~=proto then
                    return nil,"live spell grant is shared or foreign: "..proto
                end
            end
        end
    end
    if live.Projectile_PushingAttack~=1 or live.Target_PushingAttack~=1 then
        return nil,"live spellbook does not have two uniquely-owned class grants"
    end
    -- Use source-specific Osiris removal. Never manipulate native spellbook
    -- collection indices or directly write arbitrary C++ spell metadata.
    for _,spell in ipairs({"Projectile_PushingAttack","Target_PushingAttack"}) do
        Osi.RemoveSpell(characterGuid,spell,0)
    end
    local after=ResolveCharacter(characterRef)
    local remaining={}
    for _,entry in ipairs(after and after.SpellBook and after.SpellBook.Spells or {}) do
        local proto=tostring(entry and entry.Id and entry.Id.Prototype or "")
        if ids[proto] then remaining[proto]=(remaining[proto] or 0)+1 end
    end
    return 2,"RemoveSpell called; remaining Projectile="
        ..tostring(remaining.Projectile_PushingAttack or 0)
        .." Target="..tostring(remaining.Target_PushingAttack or 0)
        .." PushingPassive="..tostring(Osi.HasPassive(characterGuid,"PushingAttack"))
        .." RallyPassive="..tostring(Osi.HasPassive(characterGuid,"Rally"))
end

-- A strictly bounded, source-verified reassertion after a native refresh.
-- The first Osiris call can be overwritten or deferred by BG3. Do not
-- attempt to reconstruct level one or refresh progression entities here.
function PartialRespecSnapshot.ReconcileLevelOnePassiveEffects(characterRef,original,patched)
    local removed,added=L1PassiveDelta(original,patched)
    local entity=ResolveCharacter(characterRef)
    local characterGuid=(type(characterRef)=="string" and characterRef)
        or tostring(entity and entity.Uuid and entity.Uuid.EntityUuid or "")
    if characterGuid=="" or not Osi or not Osi.HasPassive
        or not Osi.RemovePassive or not Osi.AddPassive then
        error("Osiris passive APIs unavailable")
    end
    local before,actions={},{}
    local function Read(id)
        local value=Osi.HasPassive(characterGuid,id)
        if value~=0 and value~=1 then
            error("Invalid Osiris passive state for "..id..": "..tostring(value))
        end
        return value
    end
    for id in pairs(removed) do
        local status=Read(id)
        before[#before+1]=id.."="..status
        if status==1 then actions[#actions+1]={kind="remove",id=id} end
    end
    for id in pairs(added) do
        local status=Read(id)
        before[#before+1]=id.."="..status
        if status==0 then actions[#actions+1]={kind="add",id=id} end
    end
    -- The caller verifies exact level-one progression owners immediately
    -- before invoking this function; this is a one-shot, never a watcher.
    for _,action in ipairs(actions) do
        if action.kind=="remove" then
            Osi.RemovePassive(characterGuid,action.id)
        else
            Osi.AddPassive(characterGuid,action.id)
        end
    end
    local after={}
    for id in pairs(removed) do after[#after+1]=id.."="..Read(id) end
    for id in pairs(added) do after[#after+1]=id.."="..Read(id) end
    table.sort(before);table.sort(after)
    return #actions,table.concat(before,","),table.concat(after,",")
end

-- Fail-closed cleanup when post-replay owner matching refuses an edit.
-- Do not touch the native level-one progression or class identity.
function PartialRespecSnapshot.RestoreLevelOneHistory(characterRef,original)
    local character=ResolveCharacter(characterRef)
    local old=original and original.components and original.components.ccLevelUp
    if type(old)~="table" or not character.CCLevelUp then
        error("Original level-one choice history unavailable")
    end
    Ext.Types.Unserialize(character.CCLevelUp,old)
    MarkComponentChanged(character,"CCLevelUp")
    return true
end

--- Captures the character's serialized history for read-only diagnostics.
--- Unlike SaveCharacter, this does not create a backup or modify any entity.
--- The caller must use the result immediately; never retain live C++ proxies.
---@param characterRef string|EntityHandle
---@return table
function PartialRespecSnapshot.InspectCharacter(characterRef)
    return SnapshotCharacter(ResolveCharacter(characterRef))
end

--- Resolves the character's localized display name, or nil when unavailable.
---@param characterGuid string
---@return string|nil
local function CharacterDisplayName(characterGuid)
    local nameKey = Osi.GetDisplayName(characterGuid)
    if not nameKey then return nil end

    local handle = tostring(nameKey)
    if handle == "" then return nil end

    return Ext.Loca.GetTranslatedString(handle)
end

--- Writes a recovery dump of the state the destructive replay is about to replace.
--- Always writes, regardless of debug level
---@param character EntityHandle
---@param characterGuid string
---@param targetLevel integer
---@param pendingSnapshot table|nil
function PartialRespecSnapshot.SaveRecoveryDump(character, characterGuid, targetLevel, pendingSnapshot)
    local ok, err = pcall(function()
        local state = SnapshotCharacter(character)
        -- Bounded safety snapshots: two versions per character, not a
        -- new unbounded recovery file for each destructive replay.
        local path = ("HomeBrew/Backups/HB_Recovery_%s.json"):format(characterGuid)
        local previous = ("HomeBrew/Backups/HB_Recovery_%s_Previous.json"):format(characterGuid)

        local dump = {
            kind = "partial_respec_recovery",
            timestamp = Ext.Timer.ClockTime(),
            characterGuid = characterGuid,
            characterName = CharacterDisplayName(characterGuid),
            currentLevel = character.EocLevel and character.EocLevel.Level,
            targetLevel = targetLevel,
            eocLevel = SerializeComponent(character.EocLevel, nil, "EocLevel"),
            components = state.components,
            progressions = state.progressions,
            pendingSnapshot = pendingSnapshot,
        }

        local json = Ext.Json.Stringify(dump, { Beautify = true, StringifyInternalTypes = false })
        if not json then error("Could not serialize recovery dump " .. path) end
        local loaded, old = pcall(Ext.IO.LoadFile, path)
        if loaded and type(old) == "string" and #old > 0 then
            if not Ext.IO.SaveFile(previous, old) then
                error("Could not preserve prior recovery dump " .. previous)
            end
        end
        if not Ext.IO.SaveFile(path, json) then
            error("Could not write recovery dump " .. path)
        end

        PRPrint(1, "Recovery dump saved %s", path)
    end)

    if not ok then
        PRWarn(0, "Recovery dump failed for %s: %s", tostring(characterGuid), tostring(err))
        return false,tostring(err)
    end
    return true,nil
end

--- Recreates a progression entity from snapshot data, reattaching ProgressionMeta.Owner to the character.
---@param target EntityHandle
---@param entry table
---@return EntityHandle
local function CreateProgressionEntity(target, entry)
    local entity = Ext.Entity.Create()

    for _, spec in ipairs(ComponentSpecs) do
        local data = entry[spec.key]
        if data then
            local component = entity:CreateComponentImmediate(spec.name)
            Ext.Types.Unserialize(component, data)

            if spec.name == "ProgressionMeta" then
                component.Owner = target
            end

            MarkComponentChanged(entity, spec.name, false)
        end
    end

    return entity
end

--- Restores saved progression entities above level 1.
---@param character EntityHandle
---@param snapshot table
---@param restoreThroughLevel integer
---@return table plan
local function ApplyProgressions(character, snapshot, restoreThroughLevel)
    if snapshot.schemaVersion ~= 2 then
        error("Snapshot is from an incompatible build; start a new respec")
    end

    local snapshotBuckets = snapshot.progressions and snapshot.progressions.buckets or {}
    local bucketCount = restoreThroughLevel or #snapshotBuckets
    local plan = { newBuckets = 0, newEntries = 0 }

    if not character.ProgressionContainer then
        character:CreateComponentImmediate("ProgressionContainer")
    end

    -- Never recreate level-one progression entities: BG3 itself constructs them.
    for level = 2, bucketCount do
        local bucket = snapshotBuckets[level]
        if not bucket then
            error(("Snapshot has no progression bucket for level %d"):format(level))
        end

        plan.newBuckets = plan.newBuckets + 1
        for _, entry in ipairs(bucket) do
            CreateProgressionEntity(character, entry)
            plan.newEntries = plan.newEntries + 1
        end
    end

    return plan
end

--- Restores snapshot character components (classes, spellbook, level-up data) onto the character.
---@param character EntityHandle
---@param snapshot table
local function ApplyCharacterComponents(character, snapshot, options)
    for _, spec in ipairs(CharacterComponentSpecs) do
        local data = snapshot.components and snapshot.components[spec.key]
        if data and not (options and options.KeepNativeSpellBook
            and (spec.name=="SpellBook" or spec.name=="SpellBookPrepares")) then
            local component = character[spec.name] or character:CreateComponentImmediate(spec.name)
            Ext.Types.Unserialize(component, data)
            MarkComponentChanged(character, spec.name)
        end
    end
end

--- Entry point: replays the snapshot onto a character through the chosen cutoff level.
--- Returns the progressions plan (newBuckets, newEntries) for caller logging.
---@param characterRef string|EntityHandle|nil
---@param snapshot table
---@param restoreThroughLevel integer
---@return table plan
function PartialRespecSnapshot.ApplySnapshotToCharacter(characterRef, snapshot, restoreThroughLevel, options)
    local character = ResolveCharacter(characterRef)
    local plan = ApplyProgressions(character, snapshot, restoreThroughLevel)
    ApplyCharacterComponents(character, snapshot, options)
    return plan
end

return PartialRespecSnapshot
