-- HomeBrew equipment previews on the character-creation mannequin.
-- This updates client creation presentation only; the verified server grant is separate.
local Preview = {}
local Catalog = Ext.Require('Shared/StartingGearCatalog.lua')
local REPORT = 'HomeBrew/Diagnostics/HB_EquipmentPreview.txt'
local lines = {'HomeBrew creation equipment preview v1; slot-based client visuals'}
local last = {}
local desired = {}
local applied = {}
local jobs = {}
local nextCheck = 0
local nextWrite = 0

local function log(key, message)
    if last[key] == message then return end
    last[key] = message
    lines[#lines + 1] = message
    if #lines > 100 then table.remove(lines, 2) end
    pcall(function() Ext.IO.SaveFile(REPORT, table.concat(lines, '\n') .. '\n') end)
end

local function read(value, key)
    if not value then return nil end
    local ok, result = pcall(function() return value[key] end)
    if ok then return result end
end

local function component(entity, key)
    if not entity then return nil end
    local ok, value = pcall(function() return entity:GetComponent(key) end)
    return ok and value or nil
end

local function instances(name)
    if not Ext.Entity or type(Ext.Entity.GetAllEntitiesWithComponent) ~= 'function' then return nil end
    local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
    if ok and type(entities) == 'table' then return entities end
end

-- Creation definitions are replicated to multiplayer clients. The local native
-- character-creation ViewModel, not the global order of those definitions,
-- supplies the identity of the mannequin which this user is editing.
local function getEntity(reference)
    if not reference then return nil end
    local ok, method = pcall(function() return reference.GetComponent end)
    if ok and type(method) == 'function' then return reference end
    if Ext.Entity and type(Ext.Entity.Get) == 'function' then
        local success, entity = pcall(Ext.Entity.Get, reference)
        if success then return entity end
    end
end

local function handle(value)
    if value == nil then return nil end
    local ok, display = pcall(tostring, value)
    if not ok or type(display) ~= 'string' then return nil end
    -- Comparing full 64-bit handles avoids matching an unrelated dummy.
    local id = display:match('^Entity %((%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%)$')
        or display:match('^EntityHandle %((%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%)$')
        or display:match('^EntityHandle%((%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%)$')
    return id and id:lower() or nil
end

local function uuid(value)
    if value == nil then return nil end
    local ok, display = pcall(tostring, value)
    if not ok or type(display) ~= 'string' then return nil end
    local id = display:match('(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)')
    return id and id:lower() or nil
end

local function sameEntity(reference, entity)
    if not reference or not entity then return false end
    if rawequal(reference, entity) or tostring(reference) == tostring(entity) then return true end
    local resolved = getEntity(reference)
    if resolved and tostring(resolved) == tostring(entity) then return true end
    local a, b = handle(reference), handle(entity)
    if a and b and a == b then return true end
    if type(reference) == 'number' then
        local ok, netID = pcall(function() return entity:GetNetId() end)
        if ok and netID == reference and reference > 0 then return true end
    end
    return false
end

local function rootLinkedDefinitions(roots, definitions)
    local candidates, seen = {}, {}
    for _, rootEntity in ipairs(roots) do
        local root = component(rootEntity, 'CCCreation')
        local references = read(root, 'CharacterDefinitions')
        if references then
            for index = 1, math.min(32, math.max(#definitions + 4, 8)) do
                local reference = read(references, index)
                if reference == nil then break end
                for _, candidate in ipairs(definitions) do
                    local key = tostring(candidate)
                    if not seen[key] and sameEntity(reference, candidate) then
                        seen[key] = true
                        candidates[#candidates + 1] = candidate
                    end
                end
            end
        end
    end
    return candidates
end

local function mannequinOf(owner, isMultiplayer)
    local definition = component(owner, 'ClientCCDummyDefinition')
    if not definition then return nil, 'Active character definition lacks its client dummy' end
    local reference = read(definition, 'Dummy')
    if not reference then return nil, 'Active character dummy is missing' end
    local actor = getEntity(reference)
    if not actor then return nil, 'Active mannequin entity could not be resolved' end
    if not component(actor, 'Stats') and not component(actor, 'ClientCharacter')
        and not component(actor, 'ClientEquipmentVisuals') and not component(actor, 'CharacterVisual') then
        return nil, 'Active mannequin has no character visuals or stats'
    end
    local map = read(definition, 'field_18_Map_unk_FS')
    if not map then return nil, 'Mannequin equipment map is missing' end
    return {owner=tostring(owner), actor=tostring(actor), entity=actor,
        definition=definition, map=map, multiplayer=isMultiplayer == true}
end

local function exactLocalMatch(dummy, target)
    if not dummy or not target then return false end
    local actor = target.entity
    -- Prefer actual entity resolution. EntityHandle is exposed by the native
    -- VMDummyCharacter on multiplayer character-creation pages.
    for _, field in ipairs({'EntityHandle', 'CharacterEntity', 'Entity'}) do
        local identity = read(dummy, field)
        if identity ~= nil and sameEntity(identity, actor) then return true end
    end
    -- EntityUUID can identify the same entity even when the native handle
    -- wrapper cannot be passed directly to Ext.Entity.Get.
    for _, field in ipairs({'EntityUUID', 'EntityUuid', 'UUID', 'Uuid'}) do
        local identity = read(dummy, field)
        if identity ~= nil then
            if sameEntity(identity, actor) then return true end
            local expected = uuid(identity)
            local actual = component(actor, 'Uuid')
            local actualID = uuid(read(actual, 'EntityUuid'))
                or uuid(read(actual, 'EntityUUID')) or uuid(read(actual, 'Uuid'))
            if expected and actualID and expected == actualID then return true end
        end
    end
    return false
end

local function mannequin(context)
    local roots, definitions = instances('CCCreation'), instances('CCCharacterDefinition')
    if not roots or not definitions or #roots == 0 or #definitions == 0 then
        return nil, 'Creation entities are not ready'
    end
    local candidates = rootLinkedDefinitions(roots, definitions)
    -- Deliberately permissive EXPERIMENT: if the replicated creation roots
    -- don't expose a link, try the visible CC definitions anyway.
    if #candidates == 0 then
        candidates = definitions
        log('link_fallback', 'PREVIEW_PROBE_UNLINKED roots='..#roots..' definitions='..#definitions
            ..'; using available definitions')
    end
    local dummy = read(context, 'DummyCharacter')
    -- Preserve the exact, known-working single-player path. In multiplayer
    -- even ONE replicated definition may belong to a different player.
    if #roots == 1 and #definitions == 1 and #candidates == 1
        and read(dummy, 'IsMultiplayerCharacter') ~= true then
        return mannequinOf(candidates[1], false)
    end
    -- Do not block the experiment when DummyCharacter is missing.
    -- The probe below will choose a real active creation definition.
    local matched, matchCount = nil, 0
    local descriptions = {}
    for _, candidate in ipairs(candidates) do
        local target, reason = mannequinOf(candidate, true)
        if target then
            local isMatch = exactLocalMatch(dummy, target)
            descriptions[#descriptions+1] = target.owner..'/'..target.actor..'='..tostring(isMatch)
            if isMatch then matched = target; matchCount = matchCount+1 end
        else
            descriptions[#descriptions+1] = tostring(candidate)..'=unavailable:'..tostring(reason)
        end
    end
    if matchCount == 1 then
        log('local_resolution', 'PREVIEW_PROBE_EXACT owner='..matched.owner..' actor='..matched.actor
            ..'; roots='..#roots..'; linked='..#candidates)
        return matched
    end
    -- Intentionally no ownership gate during this one-off probe. Try one
    -- deterministic available definition and record who it really touched.
    -- This may be the *wrong player*; that's what the two-PC test is for.
    local fallback, reason
    table.sort(candidates, function(a,b) return tostring(a) < tostring(b) end)
    for _, candidate in ipairs(candidates) do
        local target, why = mannequinOf(candidate, true)
        if target then fallback = target; break end
        reason = why
    end
    local localHandle = read(dummy, 'EntityHandle')
    local localUUID = read(dummy, 'EntityUUID')
    log('local_resolution', 'PREVIEW_PROBE_FORCED roots='..#roots
        ..' definitions='..#definitions..' linked='..#candidates..' matched='..matchCount
        ..' localHandle='..tostring(localHandle)..' localUUID='..tostring(localUUID)
        ..' candidates='..table.concat(descriptions, ', ')
        ..' chosenOwner='..tostring(fallback and fallback.owner)
        ..' chosenActor='..tostring(fallback and fallback.actor)
        ..' failure='..tostring(reason))
    if fallback then return fallback end
    return nil, 'No live creation definition exposes an equipment preview map'
end

local function keyFor(slot, map)
    local itemSlots = Ext.Enums and Ext.Enums.ItemSlot
    local key = itemSlots and read(itemSlots, slot.preview or slot.equip)
    if key == nil then return nil, 'ItemSlot enum not available for '..slot.id..' ('..tostring(slot.preview or slot.equip)..')' end
    local ok = pcall(function() return map[key] end)
    if not ok then return nil, 'Equipment map does not accept '..slot.id..' key' end
    return key
end

-- Preview-only equipment stats keep both hand visuals independent.
-- Original equipment stats remain authoritative for character-creation grants.
local offhandPreviewStats = {}
local function offhandVisualStat(slotID, source)
    if slotID ~= 'OffHand' or source == 'Weapon_NoValue_Shield' then return source end
    if offhandPreviewStats[source] then return offhandPreviewStats[source] end
    if not Ext.Stats or type(Ext.Stats.Get) ~= 'function'
        or type(Ext.Stats.Create) ~= 'function' then
        return nil, 'Client equipment-stat creation is unavailable'
    end
    local statName = 'HB_CC_OffhandVisual_' .. source:gsub('[^%w_]', '_')
    local ok, value = pcall(function()
        local base = Ext.Stats.Get(source)
        if not base then error('Original weapon stat is unavailable') end
        local existing = Ext.Stats.Get(statName)
        if existing then
            if tostring(existing.Slot) ~= 'Melee Offhand Weapon' then
                error('Existing preview stat has the wrong equipment slot')
            end
            if tostring(existing.RootTemplate) ~= tostring(base.RootTemplate) then
                error('Existing preview stat has mismatched item visuals')
            end
        else
            local created = Ext.Stats.Create(statName, 'Weapon', source)
            if not created then error('Could not create client-only off-hand preview stat') end
            created.Slot = 'Melee Offhand Weapon'
            created:Sync()
            existing = Ext.Stats.Get(statName)
            if not existing or tostring(existing.Slot) ~= 'Melee Offhand Weapon' then
                error('Client-only off-hand stat did not retain its slot')
            end
            if tostring(existing.RootTemplate) ~= tostring(base.RootTemplate) then
                error('Client-only off-hand stat did not retain item visuals')
            end
        end
        return statName
    end)
    if not ok then return nil, tostring(value) end
    offhandPreviewStats[source] = value
    log('offhandStat_' .. source, 'OFFHAND_PREVIEW_STAT source='..source..' visual='..value)
    return value
end

local function increment(definition)
    local change = read(definition, 'ChangeId')
    if type(change) == 'number' then definition.ChangeId = change + 1 end
end

local function restore(slot, current, target)
    if not current then return true end
    if not target or current.owner ~= target.owner or current.actor ~= target.actor then
        log('restore_'..slot.id, 'RESTORE_SKIPPED '..slot.id..' mannequin changed')
        return false
    end
    local ok, observed = pcall(function() return target.map[current.key] end)
    if not ok or tostring(observed) ~= current.stat then
        log('restore_'..slot.id, 'RESTORE_SKIPPED '..slot.id..' equipment changed outside HomeBrew')
        return false
    end
    local succeeded, err = pcall(function()
        target.map[current.key] = current.previous
        increment(target.definition)
    end)
    log('restore_'..slot.id, succeeded and ('RESTORED '..slot.id..' previous='..tostring(current.previous))
        or ('RESTORE_FAILED '..slot.id..' '..tostring(err)))
    return succeeded
end

local function queue(slotID)
    jobs[slotID] = {attempts = 0, due = 0}
    nextCheck = 0
end

function Preview.Choose(slotID, stat)
    local slot = Catalog.BySlot[slotID]
    if not slot then return false end
    if stat == '' then stat = nil end
    if stat ~= nil then
        local found = Catalog.Find(slotID, stat)
        if not found or not Catalog.Available(stat) or not Catalog.RootTemplate(stat) then
            log('invalid_'..slotID, 'REFUSED '..slotID..' unknown or unavailable stat')
            return false
        end
    end
    if desired[slotID] == stat then
        if not jobs[slotID] and ((stat and not applied[slotID])
            or (not stat and applied[slotID])) then queue(slotID) end
        return true
    end
    desired[slotID] = stat
    queue(slotID)
    return true
end

local function hasWork()
    for _,slot in ipairs(Catalog.Slots) do
        if jobs[slot.id] or desired[slot.id] then return true end
    end
    return false
end

function Preview.Update(now, context)
    if not hasWork() or now < nextCheck or now < nextWrite then return end
    nextCheck = now + 800
    local target, why = mannequin(context)
    if not target then
        for _,slot in ipairs(Catalog.Slots) do
            local job = jobs[slot.id]
            if job and now >= job.due then
                job.attempts = job.attempts + 1
                job.due = now + 300
                if job.attempts >= 5 then
                    jobs[slot.id] = nil
                    log('wait_'..slot.id, 'PREVIEW_UNAVAILABLE '..slot.id..' '..tostring(why))
                end
            end
        end
        return
    end
    for _,slot in ipairs(Catalog.Slots) do
        local id, want = slot.id, desired[slot.id]
        local record = applied[id]
        if record and (record.owner ~= target.owner or record.actor ~= target.actor) then
            -- An appearance edit may replace the mannequin. Never write to the old one.
            applied[id] = nil
            record = nil
            if want then queue(id) end
        end
        if record and not jobs[id] and want == record.source then
            local ok, current = pcall(function() return target.map[record.key] end)
            if not ok or tostring(current) ~= record.stat then
                if record.multiplayer then
                    applied[id] = nil
                    log('external_'..id, 'PREVIEW_PROBE_EXTERNAL_CHANGE '..id
                        ..'; previousOwner='..record.owner..'; previousActor='..record.actor
                        ..'; observed='..tostring(current)..'; expected='..tostring(record.stat)
                        ..'; selection retained; select again to reapply')
                else
                    queue(id)
                end
            end
        end
        local job = jobs[id]
        if job and now >= job.due then
            local key, errorText = keyFor(slot, target.map)
            if key == nil then
                jobs[id] = nil
                log('slot_'..id, 'PREVIEW_UNAVAILABLE '..id..' '..tostring(errorText))
            else
                local ok, observed = pcall(function() return target.map[key] end)
                if not ok then
                    jobs[id] = nil
                    log('slot_'..id, 'PREVIEW_UNAVAILABLE '..id..' unreadable slot')
                else
                    if record and (record.key ~= key or tostring(observed) ~= record.stat) then
                        -- Preserve native edits made after the last HomeBrew selection.
                        record = nil
                        applied[id] = nil
                    end
                    if not want then
                        if record then restore(slot, record, target) end
                        applied[id] = nil
                        jobs[id] = nil
                        nextWrite = now + 280
                        return
                    end
                    local visualStat, visualError = offhandVisualStat(id, want)
                    if not visualStat then
                        jobs[id] = nil
                        log('visual_'..id, 'PREVIEW_UNAVAILABLE '..id..' '..tostring(visualError))
                        nextWrite = now + 280
                        return
                    end
                    local previous = observed
                    if record then previous = record.previous end
                    local changed, err = pcall(function()
                        target.map[key] = visualStat
                        increment(target.definition)
                    end)
                    if not changed then
                        job.attempts = job.attempts + 1
                        job.due = now + 300
                        if job.attempts >= 5 then
                            jobs[id] = nil
                            log('slot_'..id, 'PREVIEW_FAILED '..id..' '..tostring(err))
                        end
                    else
                        local verified, stored = pcall(function() return target.map[key] end)
                        if verified and tostring(stored) == visualStat then
                            applied[id] = {owner=target.owner, actor=target.actor, key=key,
                                previous=previous, stat=visualStat, source=want,
                                multiplayer=target.multiplayer}
                            jobs[id] = nil
                            log('slot_'..id, 'PREVIEW_PROBE_WRITTEN '..id..'='..want
                                ..'; previous='..tostring(previous)..'; owner='..target.owner
                                ..'; actor='..target.actor..'; multiplayer='..tostring(target.multiplayer))
                        else
                            jobs[id] = nil
                            log('slot_'..id, 'PREVIEW_UNCONFIRMED '..id..' assignment not retained')
                        end
                    end
                    nextWrite = now + 280
                    return
                end
            end
        end
    end
end

function Preview.Reset()
    -- A global UI transition is not an explicit request to select Default.
    -- Do not restore multiplayer mannequin maps when their ownership could
    -- have changed. Explicit Default selections still restore verified slots.
    local target = nil
    local liveDefinitions = instances('CCCharacterDefinition')
    local isMultiplayerNow = liveDefinitions and #liveDefinitions > 1
    for _,slot in ipairs(Catalog.Slots) do
        local record = applied[slot.id]
        if record and not record.multiplayer and not isMultiplayerNow then
            if not target then target = mannequin() end
            restore(slot, record, target)
        elseif record then
            log('release_'..slot.id, 'PREVIEW_RELEASED '..slot.id
                ..' multiplayer visual released without cross-character restore')
        end
    end
    desired = {}
    applied = {}
    jobs = {}
    nextCheck = 0
    nextWrite = 0
end

return Preview
