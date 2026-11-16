-- HomeBrew Scroll Transmog: original reversible same-slot equipment field trial.
-- On failure, reusable scroll tools and both equipment ingredients remain untouched.

local PREFIX = '[HB Scroll Transmog] '
local SavedGameplay = Ext.Require('Server/HBPersistentGameplay.lua')
local LOG_PATH = 'HomeBrew/Diagnostics/HB_ScrollTransmog_Test.txt'
local RESOURCE_STAT = 'OBJ_Scroll_ScrollofTransmogrification'
local REVERSION_STAT = 'OBJ_Scroll_ScrollofReversion'
local RESULT_STAT = 'OBJ_Scroll_TransmogToken'  -- The same ordinary native success item for BOTH recipes
local WAIT_MS = 9000
-- All native recipe input Transform fields MUST be None. Both scroll inputs
-- are REUSABLE tools: neither is consumed. Native transmog-token results provide the
-- BG3 success display, but are verified and retired by unique ID so crafting
-- does not multiply either reusable tool. The generated OBJ_Scroll_TransmogToken must be
-- unstacked, quantity 1; never delete any pre-existing transmog token.
local records = { 'HomeBrew Scroll Transmog; reusable tools, transmog-token native-result readback v18' }
local waiting = nil
local sequence = 0
-- Only like-for-like wearable equipment is supported. Weapons, jewelry, rings
-- and potentially special quest items are intentionally excluded for now.
local ALLOWED_SLOTS = {
    Breast=true, Helmet=true, Gloves=true, Boots=true, Cloak=true,
    -- Camp equipment is restricted to its own native slot, never mixed with armor.
    VanityBody=true, VanityBoots=true,
}
local function supportedSlot(slot)
    return ALLOWED_SLOTS[tostring(slot)] == true
end



local function report(message)
    records[#records + 1] = tostring(message)
    if #records > 110 then table.remove(records, 2) end
    local value=tostring(message):lower()
    if _G.HB_DebugDiagnostics == true or value:find('error',1,true)
        or value:find('failed',1,true) or value:find('refused',1,true)
        or value:find('timeout',1,true) then
        pcall(function() Ext.IO.SaveFile(LOG_PATH, table.concat(records, '\n') .. '\n') end)
    end
end

local function read(container, field)
    if not container then return nil end
    local ok, value = pcall(function() return container[field] end)
    if ok then return value end
end

local function component(entity, name)
    if not entity then return nil end
    local ok, value = pcall(function() return entity:GetComponent(name) end)
    if ok then return value end
end

local function entityFor(id)
    local ok, value = pcall(Ext.Entity.Get, id)
    if ok then return value end
end
local function itemSlot(id)
    local e = entityFor(id)
    local slot = e and component(e, 'Equipable')
    return slot and tostring(read(slot, 'Slot')) or nil
end

local function root(id)
    local ok, value = pcall(Osi.GetTemplate, id)
    if not ok or type(value) ~= 'string' then return nil end
    return value:match('(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$')
end

local function stat(id)
    local templateRoot = root(id)
    if not templateRoot then return nil end
    local ok, template = pcall(Ext.Template.GetRootTemplate, templateRoot)
    if ok and template then return tostring(read(template, 'Stats') or ''), template end
end

local function installedStat(id)
    local ok, result = pcall(Osi.GetStatString, id)
    if not ok or type(result) ~= 'string' or result == '' then return nil end
    return result
end

local function itemExists(id)
    if type(id) ~= 'string' then return false end
    local ok, exists = pcall(Osi.Exists, id)
    return ok and exists == 1
end

local function inventoryOwner(id)
    local ok, owner = pcall(Osi.GetInventoryOwner, id)
    return ok and owner or nil
end

-- Osiris NameGUIDs can have different names but refer to the same UUID.
-- The first-character-owner query resolves the actual character holding an
-- item, including items inside a container, without relying on item theft
-- ownership metadata or UI selection state.
local function uuidSuffix(id)
    if type(id) ~= 'string' then return nil end
    local uuid = id:match('(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$')
    return uuid and uuid:lower() or nil
end

local function sameEntity(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    if a == b then return true end
    local x, y = uuidSuffix(a), uuidSuffix(b)
    return x ~= nil and y ~= nil and x == y
end

local function firstCharacterOwner(id)
    local ok, owner = pcall(Osi.GetFirstInventoryOwnerCharacter, id)
    return ok and owner or nil
end

local function ownedBy(actor, item)
    return sameEntity(inventoryOwner(item), actor)
        or sameEntity(firstCharacterOwner(item), actor)
end

local function scrollMatches(id)
    if not itemExists(id) then return false end
    return installedStat(id) == RESOURCE_STAT and stat(id) == RESOURCE_STAT
end

local function reversionMatches(id)
    if not itemExists(id) then return false end
    return installedStat(id) == REVERSION_STAT and stat(id) == REVERSION_STAT
end

local function singleItem(id)
    local ok, amount = pcall(Osi.GetStackAmount, id)
    return ok and amount == 1
end

local function nativeTokenMatches(id)
    return itemExists(id) and installedStat(id) == RESULT_STAT and stat(id) == RESULT_STAT
end

local function snapshot(value)
    local ok, result = pcall(Ext.Types.Serialize, value)
    if ok and type(result) == 'table' then return result end
end

local function scalarSignature(value, level, seen)
    level, seen = level or 0, seen or {}
    if level > 10 then return nil end
    local t = type(value)
    if t == 'string' then return 's' .. value end
    if t == 'number' then return 'n' .. tostring(value) end
    if t == 'boolean' then return tostring(value) end
    if t == 'nil' then return 'nil' end
    if t ~= 'table' or seen[value] then return nil end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= 'string' and type(key) ~= 'number' then return nil end
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, key in ipairs(keys) do
        local v = scalarSignature(value[key], level + 1, seen)
        if not v then seen[value] = nil return nil end
        out[#out + 1] = tostring(key) .. '=' .. v
    end
    seen[value] = nil
    return '{' .. table.concat(out, ';') .. '}'
end

-- Visual-only replacement v1. A disposable replacement MUST be spawned from the
-- SOURCE root. The donor supplies ONLY its serialized Equipment.Visuals.
-- `CreateCacheTemplate` is called on the destination first; never write a shared
-- root template or mutate the donor's own visual object/proxy.
local function donorVisualData(donorRoot)
    if type(donorRoot) ~= 'string' then return nil, 'no-donor-root' end
    local ok, template = pcall(Ext.Template.GetRootTemplate, donorRoot)
    if not ok or not template then return nil, 'donor-root-unavailable' end
    local equipment = read(template, 'Equipment')
    local visualData = snapshot(read(equipment, 'Visuals'))
    if not visualData or not scalarSignature(visualData) then
        return nil, 'donor-visuals-not-serializable'
    end
    return visualData
end

local function itemVisualSignature(item)
    local entity = entityFor(item)
    local serverItem = component(entity, 'ServerItem')
    local visualData = snapshot(read(read(read(serverItem, 'Template'), 'Equipment'), 'Visuals'))
    return visualData and scalarSignature(visualData) or nil
end

local function transplantDonorVisuals(cache, donorRoot)
    local equipment = read(cache, 'Equipment')
    if not equipment then return false, 'source-equipment-template-missing' end
    local sourceEquipment = snapshot(equipment)
    if not sourceEquipment or not scalarSignature(sourceEquipment) then
        return false, 'source-equipment-unserializable'
    end
    local originalVisuals = sourceEquipment.Visuals
    if type(originalVisuals) ~= 'table' then
        return false, 'source-visuals-not-in-serialized-equipment'
    end
    local donorVisuals, err = donorVisualData(donorRoot)
    if not donorVisuals then return false, err end
    local expectedSignature = scalarSignature(donorVisuals)
    if not expectedSignature then return false, 'donor-visual-signature-invalid' end
    -- Serialize creates standalone Lua tables; do not assign a live C++ donor
    -- proxy, and do not alter other Equipment fields. A full parent readback
    -- proves that only the Visuals child changed.
    local desired = snapshot(equipment)
    if not desired or not scalarSignature(desired) then
        return false, 'source-equipment-resnapshot-failed'
    end
    desired.Visuals = donorVisuals
    local ok, result = pcall(Ext.Types.Unserialize, equipment, desired)
    if not ok or result == false then return false, 'instance-visual-write-refused:' .. tostring(result) end
    local after = snapshot(read(cache, 'Equipment'))
    if not after or scalarSignature(after) ~= scalarSignature(desired) then
        return false, 'instance-equipment-readback-differs'
    end
    local visualNow = snapshot(read(read(cache, 'Equipment'), 'Visuals'))
    if not visualNow or scalarSignature(visualNow) ~= expectedSignature then
        return false, 'donor-visual-readback-mismatch'
    end
    -- Do not mistake an unmodified source visual for a successful donor change.
    -- Identical source/donor visual data is allowed; it is already visually exact.
    return true, expectedSignature
end

-- BG3 builds equipped visuals from its live visual ECS state, not merely
-- ServerItem.Template.Equipment.Visuals. Keep the mechanical source item/root
-- unchanged; change only the visual component's presentation template and
-- replicate that one component. This is an experimental renderer cue, not a
-- claim that template readback proves the on-screen model has changed.
local function cueDonorVisualRoot(itemId, sourceRoot, donorRoot)
    local e = entityFor(itemId)
    if not e then return false, 'visual-owner-not-resolved' end
    local visual = component(e, 'GameObjectVisual')
    if not visual then return false, 'game-object-visual-not-present' end
    local old = snapshot(visual)
    if not old or not scalarSignature(old) then
        return false, 'game-object-visual-not-serializable'
    end
    local originalVisualRoot = tostring(read(visual, 'RootTemplateId') or '')
    -- Refuse foreign presentation overrides. Source item and donor appearance
    -- are the only two identities that may be present in this transaction.
    if originalVisualRoot ~= sourceRoot and originalVisualRoot ~= donorRoot then
        return false, 'unexpected-current-visual-root:' .. originalVisualRoot
    end
    if originalVisualRoot ~= donorRoot then
        local wrote, err = pcall(function() visual.RootTemplateId = donorRoot end)
        if not wrote or tostring(read(visual, 'RootTemplateId')) ~= donorRoot then
            return false, 'visual-root-write-refused:' .. tostring(err)
        end
    end
    local after = snapshot(visual)
    if not after or tostring(after.RootTemplateId) ~= donorRoot then
        return false, 'visual-root-readback-failed'
    end
    old.RootTemplateId = donorRoot
    if scalarSignature(old) ~= scalarSignature(after) then
        return false, 'other-visual-component-fields-changed'
    end
    local replicated, reason = pcall(function() e:Replicate('GameObjectVisual') end)
    if not replicated then return false, 'visual-component-replication-failed:' .. tostring(reason) end
    -- Mechanical root and stat are validated by the outer transaction before
    -- and after this cue, independently of GameObjectVisual.RootTemplateId.
    return true, originalVisualRoot
end

local function sourceRootIdentityMatches(item, sourceRoot, sourceStat)
    return type(sourceRoot) == 'string' and sourceRoot ~= ''
        and root(item) == sourceRoot
        and stat(item) == sourceStat
        and installedStat(item) == sourceStat
end

-- The item Stats entry defines the expected proficiency group, but the donor
-- root may leave the runtime ECS proficiency component in its donor category.
-- Osiris IsEquipmentWithProficiency is a query that can fail when a group is
-- not matched; it is NOT a reliable four-category fingerprint, and MUST NOT
-- be used to gate the recipe. Use the authoritative source stat plus its
-- actual native item components instead. Do not clone engine-owned components.
-- BG3SE exposes ProficiencyGroupFlags stat fields as Lua arrays of flag names,
-- not necessarily strings. tostring(table) produces a different pointer-like
-- value on separate reads; comparing those pointers previously caused every
-- recipe to be rolled back as "source-group-drift" even when the flags matched.
-- Canonicalize the actual enum values, independent of table identity and order.
local function normalizeProficiencyFlags(value)
    if value == nil then return '', nil end
    local kind = type(value)
    if kind == 'userdata' then
        value = snapshot(value)
        kind = type(value)
    end
    local names = {}
    local count = 0
    local function add(name)
        if type(name) ~= 'string' then return false end
        name = name:match('^%s*(.-)%s*$')
        if name == '' or name == 'None' then return true end
        if not name:match('^[%a_][%w_]*$') then return false end
        if not names[name] then
            count = count + 1
            if count > 64 then return false end
            names[name] = true
        end
        return true
    end
    if kind == 'string' then
        for name in (value .. ';'):gmatch('(.-);') do
            if not add(name) then return nil, 'invalid-proficiency-flag-string' end
        end
    elseif kind == 'table' then
        for key, flag in pairs(value) do
            if type(key) == 'number' and type(flag) == 'string' then
                if not add(flag) then return nil, 'invalid-proficiency-array-entry' end
            elseif type(key) == 'string' and type(flag) == 'boolean' then
                if flag and not add(key) then return nil, 'invalid-proficiency-set-entry' end
            else
                return nil, 'unknown-proficiency-flag-representation'
            end
        end
    else
        return nil, 'unreadable-proficiency-flags:' .. kind
    end
    local sorted = {}
    for name in pairs(names) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    return table.concat(sorted, ';'), nil
end

local function statsProficiency(statsId)
    if type(statsId) ~= 'string' or statsId == '' then
        return nil, 'missing-item-stat'
    end
    local ok, object = pcall(Ext.Stats.Get, statsId)
    if not ok or not object then return nil, 'item-stats-unavailable:' .. statsId end
    local value = read(object, 'Proficiency Group')
    return normalizeProficiencyFlags(value)
end

local function proficiencySignature(item)
    if not itemExists(item) then return nil, 'item-unavailable' end
    local itemStat = installedStat(item)
    if not itemStat then return nil, 'item-runtime-stat-unavailable' end
    return statsProficiency(itemStat)
end

-- Fingerprint only scalar/serializable flag data. If the native type cannot be
-- meaningfully read, refuse rather than claim we proved item classification.
local function nativeFlagsSignature(flags)
    if flags == nil then return nil end
    local kind = type(flags)
    if kind == 'string' or kind == 'number' or kind == 'boolean' then
        return kind .. ':' .. tostring(flags)
    end
    local serialized = snapshot(flags)
    if serialized then return scalarSignature(serialized) end
    local value = tostring(flags)
    -- Avoid comparing heap pointer strings from opaque userdata proxies.
    if value:find('0x%x+') then return nil end
    if value ~= '' then return value end
end

local function sameProficiency(original, replacement, expected)
    local source, sourceErr = proficiencySignature(original)
    if not source then return false, 'source:' .. tostring(sourceErr) end
    if expected and source ~= expected then return false, 'source-group-drift:' .. source end
    local target, targetErr = proficiencySignature(replacement)
    if not target then return false, 'output:' .. tostring(targetErr) end
    if source ~= target then
        return false, 'stat-proficiency-mismatch:source=' .. source .. ':output=' .. target
    end
    local oldEntity, newEntity = entityFor(original), entityFor(replacement)
    local oldComponent = component(oldEntity, 'ProficiencyGroup')
    local newComponent = component(newEntity, 'ProficiencyGroup')
    if (oldComponent == nil) ~= (newComponent == nil) then
        return false, 'native-proficiency-component-presence-mismatch'
    end
    if oldComponent and newComponent then
        local oldSig = nativeFlagsSignature(read(oldComponent, 'Flags'))
        local newSig = nativeFlagsSignature(read(newComponent, 'Flags'))
        if not oldSig or not newSig then return false, 'native-proficiency-flags-unreadable' end
        if oldSig ~= newSig then
            return false, 'native-proficiency-flags-mismatch:source=' .. oldSig .. ':output=' .. newSig
        end
    end
    local originalServer = component(oldEntity, 'ServerProficiencyGroupStats')
    local outputServer = component(newEntity, 'ServerProficiencyGroupStats')
    if (originalServer == nil) ~= (outputServer == nil) then
        return false, 'native-proficiency-stats-component-presence-mismatch'
    end
    if originalServer and outputServer then
        local sourceServerStat = read(originalServer, 'Stats')
        local outputServerStat = read(outputServer, 'Stats')
        if tostring(sourceServerStat) ~= tostring(outputServerStat) then
            return false, 'native-proficiency-stats-mismatch'
        end
    end
    return true, source
end

local function synchronizeNativeProficiency(original, replacement, statsId)
    if not original or not replacement or type(statsId) ~= 'string' then
        return false, 'missing-source-target-or-stat'
    end
    local sourceGroup, groupErr = statsProficiency(statsId)
    if not sourceGroup then return false, groupErr end
    local originalGroup = component(original, 'ProficiencyGroup')
    local outputGroup = component(replacement, 'ProficiencyGroup')
    if (originalGroup == nil) ~= (outputGroup == nil) then
        return false, 'required-native-proficiency-component-missing'
    end
    if originalGroup then
        local sourceFlags = read(originalGroup, 'Flags')
        local expectedSig = nativeFlagsSignature(sourceFlags)
        if not expectedSig then return false, 'source-proficiency-flags-unreadable' end
        -- Assign individual scalar/flag field; do not Unserialize the component.
        local written, writeErr = pcall(function() outputGroup.Flags = sourceFlags end)
        local currentSig = nativeFlagsSignature(read(outputGroup, 'Flags'))
        if not written or currentSig ~= expectedSig then
            return false, 'native-proficiency-flags-write-refused:' .. tostring(writeErr)
        end
        local replicated, replicateErr = pcall(function()
            replacement:Replicate('ProficiencyGroup')
        end)
        if not replicated then
            return false, 'native-proficiency-replication-failed:' .. tostring(replicateErr)
        end
    elseif sourceGroup ~= '' then
        return false, 'armour-proficiency-component-missing'
    end
    local oldServerStats = component(original, 'ServerProficiencyGroupStats')
    local newServerStats = component(replacement, 'ServerProficiencyGroupStats')
    if (oldServerStats == nil) ~= (newServerStats == nil) then
        return false, 'native-proficiency-stat-component-missing'
    end
    if newServerStats then
        local sourceValue = read(oldServerStats, 'Stats')
        if sourceValue == nil then return false, 'source-native-proficiency-stat-unreadable' end
        local ok, err = pcall(function() newServerStats.Stats = sourceValue end)
        if not ok or tostring(read(newServerStats, 'Stats')) ~= tostring(sourceValue) then
            return false, 'native-proficiency-stat-write-refused:' .. tostring(err)
        end
    end
    return true, 'native-proficiency-fields-synchronized:' .. tostring(sourceGroup)
end

local function donorRootIdentityMatches(item, donorRoot, sourceStat)
    local e = entityFor(item)
    local template = read(component(e, 'ServerItem'), 'Template')
    return root(item) == donorRoot and installedStat(item) == sourceStat
        and template and tostring(read(template, 'Stats')) == sourceStat
end

-- Clone only explicit gameplay components, not identity, template, physics or owner records.
-- A component that cannot be read back exactly causes the entire craft to be refused.
local REQUIRED = {'Data', 'Equipable', 'Armor'}
local OPTIONAL = {'ItemBoosts', 'PassiveContainer', 'StatusImmunities', 'Value', 'DisplayName'}

-- Engine components can contain opaque, scoped proxies and references that are
-- not portable Lua table values. Never attempt to serialize the entire Equipable
-- component or copy an engine-owned entity pointer into a newly spawned item.
-- Instead, validate its shared chest slot and reconcile readable ordinary fields
-- individually. Refuse unknown *different* opaque properties rather than silently
-- losing mechanics. This implementation is HomeBrew-specific and independent.
local ENGINE_FIELDS = {
    Entity=true, Template=true, OriginalTemplate=true, Parent=true,
    Owner=true, GetReplicationFlags=true,
}
local function copyEquipable(source, destination)
    local original = component(source, 'Equipable')
    local target = component(destination, 'Equipable')
    if not original or not target then return false, 'equipable-component-missing' end
    local slotBefore = tostring(read(original, 'Slot'))
    if not supportedSlot(slotBefore) or tostring(read(target, 'Slot')) ~= slotBefore then
        return false, 'equipable-unsupported-or-mismatched-slot'
    end
    local fieldNames, count = {}, 0
    local ok, fail = pcall(function()
        for key, value in pairs(original) do
            if type(key) == 'string' then
                count = count + 1
                if count > 96 then error('equipable-field-limit') end
                local kind = type(value)
                fieldNames[#fieldNames + 1] = key .. ':' .. kind
                if not ENGINE_FIELDS[key] and key ~= 'Slot' and kind ~= 'function' then
                    local prior = read(target, key)
                    if kind == 'string' or kind == 'number' or kind == 'boolean' then
                        if prior ~= value then
                            local wrote, message = pcall(function() target[key] = value end)
                            if not wrote or read(target, key) ~= value then
                                error('equipable-scalar-write:' .. key .. ':' .. tostring(message))
                            end
                        end
                    else
                        -- Compare read-only complex data without moving live proxies
                        -- between entities. A mismatch must be investigated before use.
                        local sourceSerialized = snapshot(value)
                        local targetSerialized = snapshot(prior)
                        local sourceSignature = sourceSerialized and scalarSignature(sourceSerialized)
                        local targetSignature = targetSerialized and scalarSignature(targetSerialized)
                        local equalSafe = sourceSignature and targetSignature
                            and sourceSignature == targetSignature
                        local equalEnum = kind == 'userdata' and prior ~= nil
                            and tostring(value) == tostring(prior)
                            and not tostring(value):find('Entity %(')
                        if not equalSafe and not equalEnum then
                            error('equipable-opaque-difference:' .. key .. ':' .. kind)
                        end
                    end
                end
            end
        end
    end)
    report('EQUIPABLE_V5 fields=' .. table.concat(fieldNames, ',')
        .. ' slot=' .. slotBefore .. ' count=' .. tostring(count)
        .. ' inspected=' .. tostring(ok))
    if not ok then return false, 'equipable-field-audit-failed:' .. tostring(fail) end
    if tostring(read(target, 'Slot')) ~= slotBefore then
        return false, 'equipable-slot-drift'
    end
    local replicated = pcall(function() destination:Replicate('Equipable') end)
    if not replicated then return false, 'equipable-replication-refused' end
    return true, 'field-verified-matching-slot'
end

local function syncComponent(source, destination, name)
    if name == 'Equipable' then return copyEquipable(source, destination) end
    local original = component(source, name)
    if not original then return true, 'absent' end
    local target = component(destination, name)
    if not target then
        local ok, made = pcall(function() return destination:CreateComponent(name) end)
        if not ok then return false, 'component-create-failed:' .. name end
        target = made or component(destination, name)
        if not target then return false, 'component-missing:' .. name end
    end
    local old = snapshot(original)
    if not old then return false, 'component-unreadable:' .. name end
    local signature = scalarSignature(old)
    if not signature then return false, 'component-unserializable:' .. name end
    local ok, result = pcall(Ext.Types.Unserialize, target, old)
    if not ok or result == false then return false, 'component-write-failed:' .. name end
    local now = snapshot(component(destination, name))
    if not now or scalarSignature(now) ~= signature then
        return false, 'component-readback-mismatch:' .. name
    end
    local replicateOk = pcall(function() destination:Replicate(name) end)
    if not replicateOk then return false, 'component-replication-failed:' .. name end
    return true, 'matched'
end

local function equippedSlot(actor, item, slot)
    slot = slot or itemSlot(item) or 'Breast'
    local ok, equipped = pcall(Osi.GetEquippedItem, actor, slot)
    return ok and sameEntity(equipped, item)
end

local function liveChestItem(actor, slot)
    local ok, equipped = pcall(Osi.GetEquippedItem, actor, slot or 'Breast')
    if ok then return equipped end
end

local function sameOwner(owner, first, second, third)
    return ownedBy(owner, first)
        and ownedBy(owner, second)
        and ownedBy(owner, third)
end

local function respond(actor, requestID, allowed)
    local ok, err = pcall(Osi.RequestProcessed, actor, requestID, allowed and 1 or 0)
    report('COMBINE_RESULT request=' .. tostring(requestID) .. ' approved=' .. tostring(allowed)
        .. ' dispatched=' .. tostring(ok) .. (ok and '' or ' error=' .. tostring(err)))
    return ok
end

-- Native combine permissions must be answered promptly: unanswered requests are
-- allowed by the engine after ~1 second. Native recipe results are generated
-- by BG3, but only this guarded transaction moves the original, creates the
-- appearance copy, and retires the NEW transmog-token result. The input tools remain. A later failure
-- must never be sent as a second/stale RequestProcessed response.
local function replyOnce(tx, allowed)
    if tx.nativeReplied then return end
    tx.nativeReplied = true
    local dispatched = respond(tx.actor, tx.request, allowed)
    tx.nativeAccepted = allowed == true and dispatched
    return dispatched
end

local function isNullItem(id)
    if id == nil or id == '' then return true end
    if type(id) ~= 'string' then return false end
    -- The engine represents unused input positions as NULL_<zero-guid>.
    return id:match('^NULL_0+%-0+%-0+%-0+%-0+$') ~= nil
end

-- Only newly created, unstacked OBJ_Scroll_TransmogToken results observed during this
-- transaction may be cleaned up. Both input scrolls remain reusable. Never
-- scan inventory for an existing token or remove either input scroll.
local function nativeResultMatches(tx, item)
    if not sameEntity(tx.nativeCandidate, item) then return false end
    if type(item) ~= 'string' or isNullItem(item) or not itemExists(item)
        or not ownedBy(tx.actor, item) or not singleItem(item) then return false end
    if sameEntity(item, tx.scroll) or sameEntity(item, tx.original)
        or sameEntity(item, tx.appearance) or sameEntity(item, tx.output) then return false end
    if tx.kind == 'craft' or tx.kind == 'revert' then return nativeTokenMatches(item) end
    return false
end

local function recordNativeResult(tx, item, source)
    if not tx or not tx.kind or not nativeResultMatches(tx, item) then return false end
    if tx.nativeResult and not sameEntity(tx.nativeResult, item) then
        tx.rewardConflict = true
        report('NATIVE_RESULT_CONFLICT_V12 request=' .. tostring(tx.request)
            .. ' first=' .. tostring(tx.nativeResult) .. ' extra=' .. tostring(item)
            .. ' source=' .. tostring(source))
        return false
    end
    tx.nativeResult = item
    tx.nativeResultSource = source
    report('NATIVE_RESULT_CAPTURED_V12 request=' .. tostring(tx.request)
        .. ' kind=' .. tostring(tx.kind) .. ' item=' .. tostring(item)
        .. ' stat=' .. tostring(installedStat(item)) .. ' source=' .. tostring(source))
    return true
end

local function nativeExpectedStat(tx)
    if tx.kind == 'craft' or tx.kind == 'revert' then return RESULT_STAT end
end

local function stageNativeCandidate(tx, item, origin)
    if not tx or not tx.kind or type(item) ~= 'string' or isNullItem(item) then return false end
    -- Transmog tokens are ordinary loot. A TemplateAddedTo/AddedTo event alone
    -- does NOT prove that this token is our combination's generated result.
    -- Require the actual native combination's result ID; v14 in-game logging
    -- confirmed both Combined and TemplatesCombined supply it.
    if origin ~= 'Combined' and origin ~= 'TemplatesCombined' then return false end
    if sameEntity(item, tx.scroll) or sameEntity(item, tx.original)
        or sameEntity(item, tx.appearance) or sameEntity(item, tx.output) then return false end
    local expected = nativeExpectedStat(tx)
    if installedStat(item) ~= expected and stat(item) ~= expected then
        report('NATIVE_RESULT_WRONG_STAT_V14 request=' .. tostring(tx.request)
            .. ' from=' .. tostring(origin)
            .. ' item=' .. tostring(item)
            .. ' expected=' .. tostring(expected)
            .. ' installed=' .. tostring(installedStat(item))
            .. ' rootStat=' .. tostring(stat(item)))
        return false
    end
    if tx.nativeCandidate and not sameEntity(tx.nativeCandidate, item) then
        tx.rewardConflict = true
        report('NATIVE_CANDIDATE_CONFLICT_V12 request=' .. tostring(tx.request)
            .. ' first=' .. tostring(tx.nativeCandidate) .. ' next=' .. tostring(item))
        return false
    end
    tx.nativeCandidate = item
    report('NATIVE_RESULT_STAGED_V12 request=' .. tostring(tx.request)
        .. ' item=' .. tostring(item) .. ' from=' .. tostring(origin))
    if recordNativeResult(tx, item, origin) then return true end
    -- A freshly generated recipe output can appear in TemplateAddedTo before
    -- its final inventory ownership has propagated. Only retry this EXACT ID.
    local scheduled = pcall(Ext.Timer.WaitFor, 200, function()
        if waiting == tx and tx.nativeCandidate == item then
            recordNativeResult(tx, item, origin .. '-settled')
        end
    end)
    if not scheduled then
        report('NATIVE_RESULT_STAGE_TIMER_FAILED_V12 request=' .. tostring(tx.request))
    end
    return true
end

local function verifiedNativeResult(tx)
    -- Native Combined/TemplatesCombined can announce the exact freshly
    -- generated result before BG3 has finished attaching it to the character.
    -- The initial event and the one-shot 200ms callback may therefore fail
    -- ownership/Exists checks. Re-read ONLY the captured combination-result ID
    -- at the actual transaction gate (the rollback path already proved that
    -- the same ID is valid at this point in a live v16 save). No inventory scan.
    if not tx.nativeResult and tx.nativeCandidate and not tx.rewardConflict then
        if recordNativeResult(tx, tx.nativeCandidate, 'transaction-gate-readback') then
            report('NATIVE_RESULT_LATE_CONFIRMED_V17 request=' .. tostring(tx.request)
                .. ' kind=' .. tostring(tx.kind)
                .. ' item=' .. tostring(tx.nativeCandidate))
        end
    end
    return tx.nativeResult ~= nil and not tx.rewardConflict
        and nativeResultMatches(tx, tx.nativeResult)
end

local function revokeNativeResult(tx, reason)
    if not tx.nativeResult and tx.nativeCandidate then
        recordNativeResult(tx, tx.nativeCandidate, 'rollback-readback')
    end
    if not tx.nativeResult then return end
    local result = tx.nativeResult
    if nativeResultMatches(tx, result) then
        local ok = pcall(Osi.RequestDelete, result)
        report('NATIVE_RESULT_ROLLBACK_V12 request=' .. tostring(tx.request)
            .. ' item=' .. tostring(result) .. ' sent=' .. tostring(ok)
            .. ' reason=' .. tostring(reason))
    else
        report('NATIVE_RESULT_ROLLBACK_UNSAFE_V12 request=' .. tostring(tx.request)
            .. ' item=' .. tostring(result) .. ' reason=' .. tostring(reason))
    end
end

local function discard(item)
    if itemExists(item) then
        local ok = pcall(Osi.RequestDelete, item)
        return ok
    end
    return true
end

-- Storage is discovered only from the base game's character-creation-dummy
-- database. No hardcoded reference-mod container GUIDs, custom assets, or
-- player-accessible chests are used. If no loaded game-owned holder is
-- available, refuse the transaction *before* it begins.
local function escrowHolder(actor)
    local ok, rows = pcall(function() return Osi.DB_CharacterCreationDummy:Get(nil) end)
    if not ok or type(rows) ~= 'table' then return nil, 'dummy-database-unavailable' end
    local ids, seen = {}, {}
    for _, row in pairs(rows) do
        local candidate = type(row) == 'table' and row[1] or nil
        if type(candidate) == 'string' and uuidSuffix(candidate)
            and not sameEntity(candidate, actor) and not seen[uuidSuffix(candidate)]
            and itemExists(candidate) and entityFor(candidate) then
            seen[uuidSuffix(candidate)] = true
            ids[#ids + 1] = candidate
        end
    end
    table.sort(ids)
    if #ids == 0 then return nil, 'no-loaded-character-creation-dummy' end
    return ids[1], 'game-dummy-database'
end

local function heldBy(holder, item)
    return sameEntity(inventoryOwner(item), holder)
        or sameEntity(firstCharacterOwner(item), holder)
end

-- If a move to escrow has been dispatched, NEVER destroy the replacement
-- until the source has actually been returned to the player's inventory.
-- In an unrecoverable situation retain the replacement, source, and scroll
-- and block further crafts until the test save is reloaded.
local function recoverEscrow(tx, reason)
    if tx.recovering then return end
    tx.recovering = true
    report('ESCROW_RECOVERY_BEGIN_V8 request=' .. tostring(tx.request)
        .. ' reason=' .. tostring(reason) .. ' source=' .. tostring(tx.original))
    local moved = itemExists(tx.original) and pcall(Osi.ToInventory, tx.original, tx.actor, 1, 0, 0)
    report('ESCROW_RECOVERY_DISPATCH_V8 request=' .. tostring(tx.request)
        .. ' sent=' .. tostring(moved))
    pcall(Ext.Timer.WaitFor, 450, function()
        local restored = itemExists(tx.original) and ownedBy(tx.actor, tx.original)
        report('ESCROW_RECOVERY_READBACK_V8 request=' .. tostring(tx.request)
            .. ' restored=' .. tostring(restored)
            .. ' owner=' .. tostring(inventoryOwner(tx.original)))
        if not restored then
            report('ESCROW_CRITICAL_V8 source-not-returned; clone-kept; scroll-preserved; reload-disposable-save')
            -- Keep waiting set: do not permit a second craft in an unsafe state.
            return
        end
        if tx.spawn and itemExists(tx.spawn) then
            if equippedSlot(tx.actor, tx.spawn) then pcall(Osi.Unequip, tx.actor, tx.spawn) end
            -- Native equipment updates may settle later. Only delete after
            -- the source has been safely returned to its character.
            discard(tx.spawn)
        end
        if tx.oldEquipped and not equippedSlot(tx.actor, tx.original) then
            local chest = liveChestItem(tx.actor, tx.slot)
            if not chest or chest == '' or isNullItem(chest)
                or (tx.spawn and sameEntity(chest, tx.spawn)) then
                pcall(Osi.Equip, tx.actor, tx.original)
            end
        end
        revokeNativeResult(tx, 'escrow-recovered')
        report('ESCROW_RECOVERY_FINISHED_V8 request=' .. tostring(tx.request))
        if waiting == tx then waiting = nil end
    end)
end

local function finishDenied(tx, reason)
    report('REFUSED request=' .. tostring(tx.request) .. ' reason=' .. tostring(reason))
    if tx.escrowMoveRequested then
        if tx.nativeReplied and tx.nativeAccepted then
            report('POST_APPROVAL_RECOVERY request=' .. tostring(tx.request)
                .. ' reason=' .. tostring(reason) .. ' native-inputs-preserved=true')
        else
            replyOnce(tx, false)
        end
        return recoverEscrow(tx, reason)
    end
    if tx.spawn and itemExists(tx.spawn) then
        if equippedSlot(tx.actor, tx.spawn) then pcall(Osi.Unequip, tx.actor, tx.spawn) end
        discard(tx.spawn)
    end
    revokeNativeResult(tx, reason)
    if tx.oldEquipped and itemExists(tx.original) and not equippedSlot(tx.actor, tx.original) then
        local chest = liveChestItem(tx.actor, tx.slot)
        if not chest or chest == '' or isNullItem(chest)
            or (tx.spawn and sameEntity(chest, tx.spawn)) then
            pcall(Osi.Equip, tx.actor, tx.original)
        else
            report('RECOVERY_PRESERVED_FOREIGN_CHEST request=' .. tostring(tx.request)
                .. ' chest=' .. tostring(chest))
        end
    end
    if tx.nativeReplied and tx.nativeAccepted then
        report('POST_APPROVAL_RECOVERY request=' .. tostring(tx.request)
            .. ' reason=' .. tostring(reason) .. ' native-inputs-preserved=true')
    else
        replyOnce(tx, false)
    end
    if waiting == tx then waiting = nil end
end

-- The game's native combine may still finish moving inventory/equipment after
-- TemplateAddedTo has returned. Never spend the scroll or declare success in
-- that callback. A late, persistent equipped-state readback is authoritative.
local function settleCraft(tx, spawnedId)
    if waiting ~= tx or tx.spawn ~= spawnedId then return end
    if not itemExists(spawnedId) or not itemExists(tx.original)
        or not itemExists(tx.appearance) or not itemExists(tx.scroll) then
        return finishDenied(tx, 'settle-ingredient-or-output-missing')
    end
    if not ownedBy(tx.actor, spawnedId)
        or not sameOwner(tx.actor, tx.scroll, tx.original, tx.appearance) then
        return finishDenied(tx, 'settle-owner-mismatch')
    end
    if not donorRootIdentityMatches(spawnedId, tx.donorRoot, tx.originalStat) then
        return finishDenied(tx, 'settle-source-root-or-stats-drift')
    end
    if itemVisualSignature(spawnedId) ~= tx.appliedVisualSignature then
        return finishDenied(tx, 'settle-appearance-not-retained')
    end
    if not verifiedNativeResult(tx) then
        return finishDenied(tx, 'native-transmog-token-result-not-confirmed')
    end
    local current = liveChestItem(tx.actor, tx.slot)
    report('EQUIP_SETTLE_V7 request=' .. tostring(tx.request)
        .. ' initiallyEquipped=' .. tostring(tx.oldEquipped)
        .. ' chest=' .. tostring(current)
        .. ' replacementEquipped=' .. tostring(equippedSlot(tx.actor, spawnedId)))
    if current and current ~= '' and not isNullItem(current)
        and not sameEntity(current, tx.original)
        and not sameEntity(current, spawnedId) then
        return finishDenied(tx, 'chest-now-holds-unrelated-equipment')
    end
    if not equippedSlot(tx.actor, spawnedId) then
        -- One bounded retry after native combine, never unbounded polling.
        local ok, errorMessage = pcall(Osi.Equip, tx.actor, spawnedId)
        report('EQUIP_RETRY_V7 request=' .. tostring(tx.request)
            .. ' dispatched=' .. tostring(ok)
            .. ' error=' .. (ok and 'none' or tostring(errorMessage)))
        if not ok then return finishDenied(tx, 'settle-equip-dispatch-failed') end
    end
    local scheduled, why = pcall(Ext.Timer.WaitFor, 350, function()
        if waiting ~= tx then return end
        report('EQUIP_FINAL_V7 request=' .. tostring(tx.request)
            .. ' equipped=' .. tostring(equippedSlot(tx.actor, spawnedId))
            .. ' chest=' .. tostring(liveChestItem(tx.actor, tx.slot))
            .. ' sourcePresent=' .. tostring(itemExists(tx.original))
            .. ' donorPresent=' .. tostring(itemExists(tx.appearance))
            .. ' scrollPresent=' .. tostring(itemExists(tx.scroll))
            .. ' outputStat=' .. tostring(installedStat(spawnedId)))
        if not equippedSlot(tx.actor, spawnedId) then
            return finishDenied(tx, 'replacement-not-stably-equipped')
        end
        if not itemExists(tx.original) or not itemExists(tx.appearance)
            or not itemExists(tx.scroll) or not ownedBy(tx.actor, spawnedId)
            or not donorRootIdentityMatches(spawnedId, tx.donorRoot, tx.originalStat)
            or itemVisualSignature(spawnedId) ~= tx.appliedVisualSignature then
            return finishDenied(tx, 'final-readback-failed')
        end
        local groupOK, groupWhy = sameProficiency(tx.original, spawnedId, tx.sourceProficiency)
        if not groupOK then return finishDenied(tx, 'equipped-proficiency-mismatch:' .. tostring(groupWhy)) end
        -- Treat original-item storage as a separate, audited phase. Never
        -- retire the native result until the protected original is stored.
        if not verifiedNativeResult(tx) then
            return finishDenied(tx, 'native-transmog-token-result-missing-before-escrow')
        end
        if not tx.escrow or not itemExists(tx.escrow) then
            return finishDenied(tx, 'escrow-holder-disappeared-before-move')
        end
        if not ownedBy(tx.actor, tx.original) then
            return finishDenied(tx, 'original-not-held-before-escrow')
        end
        tx.escrowMoveRequested = true
        local moved, moveError = pcall(Osi.ToInventory, tx.original, tx.escrow, 1, 0, 0)
        report('ESCROW_MOVE_V8 request=' .. tostring(tx.request)
            .. ' dispatched=' .. tostring(moved)
            .. ' holder=' .. tostring(tx.escrow)
            .. (moved and '' or ' error=' .. tostring(moveError)))
        if not moved then return finishDenied(tx, 'escrow-move-command-failed') end
        local escrowTimer, escrowError = pcall(Ext.Timer.WaitFor, 450, function()
            if waiting ~= tx then return end
            local stored = itemExists(tx.original) and heldBy(tx.escrow, tx.original)
                and not ownedBy(tx.actor, tx.original)
            local equipped = equippedSlot(tx.actor, spawnedId)
            report('ESCROW_SETTLE_V8 request=' .. tostring(tx.request)
                .. ' stored=' .. tostring(stored)
                .. ' originalOwner=' .. tostring(inventoryOwner(tx.original))
                .. ' cloneEquipped=' .. tostring(equipped)
                .. ' donorPresent=' .. tostring(itemExists(tx.appearance))
                .. ' scrollPresent=' .. tostring(itemExists(tx.scroll)))
            if not stored or not equipped or not itemExists(tx.appearance)
                or not verifiedNativeResult(tx)
                or not itemExists(tx.scroll) or not ownedBy(tx.actor, spawnedId)
                or not donorRootIdentityMatches(spawnedId, tx.donorRoot, tx.originalStat)
                or itemVisualSignature(spawnedId) ~= tx.appliedVisualSignature then
                return finishDenied(tx, 'escrow-or-equipment-settlement-failed')
            end
            local groupOK, groupWhy = sameProficiency(tx.original, spawnedId, tx.sourceProficiency)
            if not groupOK then return finishDenied(tx, 'escrow-proficiency-mismatch:' .. tostring(groupWhy)) end
            -- The native result is a UI-success artifact, NOT a new free tool.
            -- Delete only its exact captured entity, never an existing token or scroll.
            if not verifiedNativeResult(tx) or not itemExists(tx.scroll)
                or not scrollMatches(tx.scroll) or not ownedBy(tx.actor, tx.scroll) then
                return finishDenied(tx, 'reusable-tool-or-native-result-lost-before-cleanup')
            end
            local retired = discard(tx.nativeResult)
            report('NATIVE_RESULT_RETIRE_V15 request=' .. tostring(tx.request)
                .. ' item=' .. tostring(tx.nativeResult)
                .. ' sent=' .. tostring(retired) .. ' tool=' .. tostring(tx.scroll))
            if not retired then return finishDenied(tx, 'native-result-retire-command-failed') end
            local payTimer, payError = pcall(Ext.Timer.WaitFor, 400, function()
                if waiting ~= tx then return end
                local resultRemoved = not itemExists(tx.nativeResult)
                local toolRetained = itemExists(tx.scroll) and scrollMatches(tx.scroll)
                    and ownedBy(tx.actor, tx.scroll)
                local sourceStored = itemExists(tx.original) and heldBy(tx.escrow, tx.original)
                local stillEquipped = itemExists(spawnedId) and equippedSlot(tx.actor, spawnedId)
                report('POSTCRAFT_REUSABLE_V15 request=' .. tostring(tx.request)
                    .. ' nativeResultRemoved=' .. tostring(resultRemoved)
                    .. ' toolRetained=' .. tostring(toolRetained)
                    .. ' sourceInEscrow=' .. tostring(sourceStored)
                    .. ' donorPresent=' .. tostring(itemExists(tx.appearance))
                    .. ' cloneEquipped=' .. tostring(stillEquipped)
                    .. ' cloneStat=' .. tostring(installedStat(spawnedId)))
                if not resultRemoved then return finishDenied(tx, 'native-result-remains-after-cleanup') end
                if not donorRootIdentityMatches(spawnedId, tx.donorRoot, tx.originalStat)
                    or itemVisualSignature(spawnedId) ~= tx.appliedVisualSignature then
                    return finishDenied(tx, 'post-craft-source-identity-or-appearance-drift')
                end
                if not toolRetained or not sourceStored or not stillEquipped
                    or not itemExists(tx.appearance) then
                    -- The original remains recoverable in escrow, and the
                    -- input tool was never deliberately consumed.
                    report('ESCROW_CRITICAL_V15 post-result-cleanup-integrity-failed; do-not-save')
                    return
                end
                local groupOK, groupWhy = sameProficiency(tx.original, spawnedId, tx.sourceProficiency)
                if not groupOK then return finishDenied(tx, 'final-proficiency-mismatch:' .. tostring(groupWhy)) end
                local saved, saveReason = SavedGameplay.AddTransmog(spawnedId, {
                    Original=tx.original, DonorRoot=tx.donorRoot, SourceRoot=tx.sourceRoot,
                    VisualMode='DonorRootProficiencyV2',
                    SourceStats=tx.originalStat, SourceProficiency=tx.sourceProficiency,
                    Actor=tx.actor, Escrow=tx.escrow, Slot=tx.slot, Trial=true
                })
                if not saved then
                    -- Critical: a verified native transmog must have a saved
                    -- provenance record to permit future safe reversal.
                    -- Do not clear the transaction or advertise completion.
                    report('ESCROW_CRITICAL_V19 ledger-persist-failed:' .. tostring(saveReason) .. ';do-not-save')
                    return
                end
                report('CRAFT_REUSABLE_VERIFIED_V15 request=' .. tostring(tx.request)
                    .. ' tool=' .. tostring(tx.scroll)
                    .. ' nativeResultRetired=' .. tostring(tx.nativeResult)
                    .. ' source=' .. tostring(tx.nativeResultSource))
                report('CRAFT_VERIFIED_ESCROW_V8 original=' .. tx.original
                    .. ' transformed=' .. spawnedId .. ' donor=' .. tx.appearance
                    .. ' holder=' .. tx.escrow)
                if waiting == tx then waiting = nil end
            end)
            if not payTimer then
                report('ESCROW_CRITICAL_V15 native-result-verification-timer-failed:' .. tostring(payError))
            end
        end)
        if not escrowTimer then return finishDenied(tx, 'escrow-verification-timer-failed:' .. tostring(escrowError)) end
    end)
    if not scheduled then finishDenied(tx, 'final-timer-failed:' .. tostring(why)) end
end

local function applyCraft(tx, spawnedId)
    if waiting ~= tx then return end
    tx.spawn = spawnedId
    local original = entityFor(tx.original)
    local newItem = entityFor(spawnedId)
    if not original or not newItem then return finishDenied(tx, 'entity-not-resolved') end
    if not itemExists(tx.scroll) or not itemExists(tx.appearance) or not itemExists(tx.original) then
        return finishDenied(tx, 'ingredient-disappeared')
    end
    if not sameOwner(tx.actor, tx.scroll, tx.original, tx.appearance) then
        return finishDenied(tx, 'inventory-ownership-changed')
    end
    local sourceRootStats = stat(tx.original)
    if sourceRootStats ~= tx.originalStat then return finishDenied(tx, 'source-stats-drift') end
    local serverItem = component(newItem, 'ServerItem')
    if not serverItem then return finishDenied(tx, 'spawned-server-item-missing') end
    local create = read(serverItem, 'CreateCacheTemplate')
    if type(create) ~= 'function' then return finishDenied(tx, 'per-instance-template-unavailable') end
    local made = pcall(function() serverItem:CreateCacheTemplate() end)
    if not made then return finishDenied(tx, 'per-instance-template-refused') end
    local cache = read(serverItem, 'Template')
    if not cache then return finishDenied(tx, 'per-instance-template-missing') end
    -- Use the donor's actual root for its original worn visuals, as in the
    -- previously in-game-proven transmog path. The cache is item-specific.
    local donorBefore = snapshot(read(read(cache, 'Equipment'), 'Visuals'))
    tx.appliedVisualSignature = donorBefore and scalarSignature(donorBefore)
    if not tx.appliedVisualSignature or root(spawnedId) ~= tx.donorRoot then
        return finishDenied(tx, 'donor-root-appearance-or-template-unavailable')
    end
    local wrote, statErr = pcall(function() cache.Stats = tx.originalStat end)
    if not wrote or tostring(read(cache, 'Stats')) ~= tx.originalStat then
        return finishDenied(tx, 'source-stat-instance-override-refused:' .. tostring(statErr))
    end
    if not donorRootIdentityMatches(spawnedId, tx.donorRoot, tx.originalStat)
        or itemVisualSignature(spawnedId) ~= tx.appliedVisualSignature then
        return finishDenied(tx, 'donor-visual-or-source-stat-readback-failed')
    end
    for _, name in ipairs(REQUIRED) do
        local componentIsPresent = component(original, name) ~= nil
        if not componentIsPresent then return finishDenied(tx, 'source-critical-component-missing:' .. name) end
        local ok, why = syncComponent(original, newItem, name)
        report('COMPONENT ' .. name .. '=' .. why)
        if not ok then return finishDenied(tx, why) end
    end
    for _, name in ipairs(OPTIONAL) do
        local ok, why = syncComponent(original, newItem, name)
        report('COMPONENT ' .. name .. '=' .. why)
        if not ok then return finishDenied(tx, why) end
    end
    local profOk, profWhy = synchronizeNativeProficiency(original, newItem, tx.originalStat)
    if not profOk then return finishDenied(tx, 'proficiency-sync-refused:' .. tostring(profWhy)) end
    local groupsOk, groupsWhy = sameProficiency(tx.original, spawnedId, tx.sourceProficiency)
    if not groupsOk then return finishDenied(tx, 'proficiency-pre-equip:' .. tostring(groupsWhy)) end
    report('PROFICIENCY_NATIVE_PREFLIGHT source=' .. tx.sourceProficiency
        .. ' output=' .. tostring(groupsWhy))
    if tx.oldEquipped then
        local un = pcall(Osi.Unequip, tx.actor, tx.original)
        if not un then return finishDenied(tx, 'unequip-refused') end
    end
    local toOwner = pcall(Osi.ToInventory, spawnedId, tx.actor, 1, 1, 1)
    if not toOwner or not ownedBy(tx.actor, spawnedId) then
        return finishDenied(tx, 'spawned-item-not-in-inventory')
    end
    -- The Osiris Equip command dispatches work to BG3; GetEquippedItem is
    -- not guaranteed to reflect it in the same Lua callback. Never refuse
    -- an item merely because synchronous readback still shows the old slot.
    local installed = installedStat(spawnedId)
    report('ENGINE_STAT_READBACK cloned=' .. tostring(installed) .. ' expected=' .. tx.originalStat)
    if installed ~= tx.originalStat then
        return finishDenied(tx, 'engine-did-not-adopt-source-stats')
    end
    if not itemExists(tx.original) or not itemExists(tx.appearance) then
        return finishDenied(tx, 'original-or-donor-missing-post-equip')
    end
    if not itemExists(tx.scroll) then return finishDenied(tx, 'reusable-scroll-missing-before-equip') end
    report('OUTPUT_READY_V7 request=' .. tostring(tx.request)
        .. ' originalEquippedAtStart=' .. tostring(tx.oldEquipped)
        .. ' chestImmediately=' .. tostring(liveChestItem(tx.actor, tx.slot))
        .. ' sourceStillPresent=' .. tostring(itemExists(tx.original)))
    -- Allow native inventory/unequip callbacks to finish before dispatching
    -- the new equip command. Validate the slot again to avoid displacing gear
    -- equipped by the player or another mod in the intervening interval.
    local scheduled, why = pcall(Ext.Timer.WaitFor, 350, function()
        if waiting ~= tx then return end
        local before = liveChestItem(tx.actor, tx.slot)
        if before and not isNullItem(before)
            and not sameEntity(before, tx.original)
            and not sameEntity(before, spawnedId) then
            return finishDenied(tx, 'foreign-equipment-after-spawn')
        end
        if not itemExists(spawnedId) or not ownedBy(tx.actor, spawnedId)
            or not itemExists(tx.original) or not itemExists(tx.appearance)
            or not itemExists(tx.scroll) then
            return finishDenied(tx, 'missing-before-deferred-equip')
        end
        local ok, err = pcall(Osi.Equip, tx.actor, spawnedId)
        report('EQUIP_DISPATCH_V7 request=' .. tostring(tx.request)
            .. ' sent=' .. tostring(ok)
            .. ' priorChest=' .. tostring(before)
            .. ' immediateChest=' .. tostring(liveChestItem(tx.actor, tx.slot))
            .. (ok and '' or ' error=' .. tostring(err)))
        if not ok then return finishDenied(tx, 'deferred-equip-dispatch-failed') end
        local timerOk, timerError = pcall(Ext.Timer.WaitFor, 400, function()
            settleCraft(tx, spawnedId)
        end)
        if not timerOk then return finishDenied(tx, 'settle-timer-failed:' .. tostring(timerError)) end
    end)
    if not scheduled then
        return finishDenied(tx, 'first-equip-timer-failed:' .. tostring(why))
    end
end

local function startCraft(actor, scroll, target, donor, request)
    if waiting then return respond(actor, request, false) end
    -- Treat the equipped chest piece as the mechanical source, regardless of
    -- which of the two armor boxes it occupies. Refuse ambiguous/unworn pairs.
    local originallySecond = equippedSlot(actor, target)
    local originallyThird = equippedSlot(actor, donor)
    if not originallySecond and originallyThird then
        target, donor = donor, target
        report('INGREDIENT_ROLES_V7 request=' .. tostring(request)
            .. ' sourcePosition=3 appearancePosition=2')
    else
        report('INGREDIENT_ROLES_V7 request=' .. tostring(request)
            .. ' sourcePosition=2 appearancePosition=3')
    end
    if not Ext.Timer or type(Ext.Timer.WaitFor) ~= 'function' then
        report('REFUSED request=' .. tostring(request) .. ' reason=server-timer-unavailable')
        return respond(actor, request, false)
    end
    local tx = {actor=actor, scroll=scroll, original=target, appearance=donor,
        request=request, kind='craft', oldEquipped=equippedSlot(actor, target)}
    report('INITIAL_EQUIP_V7 request=' .. tostring(request)
        .. ' chest=' .. tostring(liveChestItem(actor, itemSlot(target)))
        .. ' targetWasEquipped=' .. tostring(tx.oldEquipped))
    if scroll == target or scroll == donor or target == donor then
        return finishDenied(tx, 'ingredients-not-distinct')
    end
    -- Keep the v10 verified assumption: only replace equipment already worn by
    -- the actor, so a change is observable and no unrelated slot is displaced.
    if not tx.oldEquipped then
        return finishDenied(tx, 'target-must-be-equipped-for-trial')
    end
    -- Audit each ingredient independently, so a failed preflight can identify
    -- precisely which engine lookup failed on the live server.
    local actorExists = itemExists(actor)
    local scrollExists = itemExists(scroll)
    local targetExists = itemExists(target)
    local donorExists = itemExists(donor)
    local scrollRoot = root(scroll)
    local scrollStat = stat(scroll)
    local scrollMatch = scrollMatches(scroll)
    local ownedScroll = ownedBy(actor, scroll)
    local ownedTarget = ownedBy(actor, target)
    local ownedDonor = ownedBy(actor, donor)
    report('PREFLIGHT_V7 request=' .. tostring(request)
        .. ' actorExists=' .. tostring(actorExists)
        .. ' scrollExists=' .. tostring(scrollExists)
        .. ' targetExists=' .. tostring(targetExists)
        .. ' donorExists=' .. tostring(donorExists)
        .. ' scrollRoot=' .. tostring(scrollRoot)
        .. ' scrollStat=' .. tostring(scrollStat)
        .. ' scrollMatch=' .. tostring(scrollMatch)
        .. ' ownersDirect=[' .. tostring(inventoryOwner(scroll)) .. '|'
            .. tostring(inventoryOwner(target)) .. '|' .. tostring(inventoryOwner(donor)) .. ']'
        .. ' ownersCharacter=[' .. tostring(firstCharacterOwner(scroll)) .. '|'
            .. tostring(firstCharacterOwner(target)) .. '|' .. tostring(firstCharacterOwner(donor)) .. ']'
        .. ' owned=[' .. tostring(ownedScroll) .. '|'
            .. tostring(ownedTarget) .. '|' .. tostring(ownedDonor) .. ']')
    if not actorExists then return finishDenied(tx, 'actor-not-present') end
    if not scrollExists then return finishDenied(tx, 'scroll-not-present') end
    if not targetExists then return finishDenied(tx, 'target-not-present') end
    if not donorExists then return finishDenied(tx, 'donor-not-present') end
    if not scrollMatch then return finishDenied(tx, 'scroll-template-or-stat-mismatch') end
    if not ownedScroll then return finishDenied(tx, 'scroll-not-owned-by-crafting-character') end
    if not ownedTarget then return finishDenied(tx, 'target-not-owned-by-crafting-character') end
    if not ownedDonor then return finishDenied(tx, 'donor-not-owned-by-crafting-character') end
    local countOk, count = pcall(Osi.GetStackAmount, scroll)
    if not countOk or count ~= 1 then return finishDenied(tx, 'scroll-must-be-single-item-stack') end
    local a, b = entityFor(target), entityFor(donor)
    if not a or not b or component(a, 'IsSummon') or component(b, 'IsSummon') then
        return finishDenied(tx, 'unavailable-or-summoned-equipment')
    end
    local targetSlot = read(component(a, 'Equipable'), 'Slot')
    local donorSlot = read(component(b, 'Equipable'), 'Slot')
    if not supportedSlot(targetSlot) or tostring(targetSlot) ~= tostring(donorSlot) then
        return finishDenied(tx, 'unsupported-or-mismatched-equipment-slots')
    end
    tx.slot = tostring(targetSlot)
    report('SLOT_PREFLIGHT_V11 request=' .. tostring(request) .. ' slot=' .. tx.slot)
    if not component(a, 'Armor') then return finishDenied(tx, 'original-is-not-armor') end
    local originalStat = installedStat(target)
    local donorStat = installedStat(donor)
    if not originalStat or not donorStat then
        return finishDenied(tx, 'equipment-stats-unavailable')
    end
    if originalStat ~= stat(target) or donorStat ~= stat(donor) then
        return finishDenied(tx, 'runtime-and-root-stats-disagree')
    end
    tx.originalStat = originalStat
    tx.sourceProficiency = proficiencySignature(target)
    if not tx.sourceProficiency then
        return finishDenied(tx, 'source-proficiency-stats-unavailable')
    end
    tx.sourceRoot = root(target)
    tx.donorRoot = root(donor)
    if not tx.sourceRoot or not tx.donorRoot or tx.donorRoot == tx.sourceRoot then
        return finishDenied(tx, 'same-appearance-or-invalid-template')
    end
    -- Require donor visuals before approving the native recipe, avoiding
    -- an avoidable post-approval failure on exotic/modded armor.
    local visuals, visualReason = donorVisualData(tx.donorRoot)
    if not visuals then return finishDenied(tx, 'donor-visual-preflight:' .. tostring(visualReason)) end
    local escrow, escrowReason = escrowHolder(actor)
    report('ESCROW_PREFLIGHT_V8 request=' .. tostring(request)
        .. ' holder=' .. tostring(escrow) .. ' source=' .. tostring(escrowReason))
    if not escrow then return finishDenied(tx, 'no-verified-escrow-holder:' .. tostring(escrowReason)) end
    tx.escrow = escrow
    local ledger = SavedGameplay.TransmogRecords()
    if ledger then
        if ledger[target] or ledger[donor] then
            return finishDenied(tx, 'already-transmogged-item-used-as-ingredient')
        end
        for transformed, record in pairs(ledger) do
            if itemExists(transformed) and type(record) == 'table'
                and record.Original == target then
                return finishDenied(tx, 'source-already-has-a-test-copy')
            end
        end
    end
    waiting = tx
    -- Arm cancellation BEFORE permitting native combine or spawning anything.
    sequence = sequence + 1
    local ticket = sequence
    local timerOk, timerErr = pcall(Ext.Timer.WaitFor, WAIT_MS, function()
        if waiting == tx and sequence == ticket then finishDenied(tx, 'spawn-timeout') end
    end)
    if not timerOk then return finishDenied(tx, 'timer-registration-failed:' .. tostring(timerErr)) end
    report('CRAFT_BEGIN request=' .. tostring(request) .. ' scroll=' .. scroll
        .. ' original=' .. target .. ' donor=' .. donor .. ' baseStat=' .. originalStat)
    -- The original Scroll of Transmogrification remains with its owner.
    if not replyOnce(tx, true) then
        return finishDenied(tx, 'native-permission-dispatch-failed')
    end
    report('NATIVE_REAL_RESULT_RECIPE_APPROVED_V12 request=' .. tostring(request))
    -- Yield until after the native combination's synchronous processing has
    -- returned, so it cannot subsequently undo the new item's equip state.
    -- A native OBJ_Scroll_TransmogToken recipe result may arrive after RequestProcessed, and
    -- equipment/inventory ownership can settle after the result event itself.
    -- Poll ONLY a captured result ID; never infer success from a pre-existing
    -- inventory stack or synthesize the native reward. Bound the wait to 2.65s.
    local function afterNativeResult(attempt)
        if waiting ~= tx then return end
        if not sameOwner(tx.actor, tx.scroll, tx.original, tx.appearance)
            or not itemExists(tx.scroll) then
            return finishDenied(tx, 'postnative-ingredient-drift')
        end
        if not verifiedNativeResult(tx) and tx.nativeCandidate then
            recordNativeResult(tx, tx.nativeCandidate, 'bounded-inventory-settlement')
        end
        if verifiedNativeResult(tx) then
            report('SPAWN_DEFERRED_V14 request=' .. tostring(tx.request)
                .. ' attempts=' .. tostring(attempt)
                .. ' nativeResult=' .. tostring(tx.nativeResult))
            local ok, errorMessage = pcall(Osi.TemplateAddTo, tx.donorRoot, actor, 1, 0)
            if not ok then finishDenied(tx, 'spawn-dispatch-failed:' .. tostring(errorMessage)) end
            return
        end
        report('NATIVE_RESULT_PENDING_V14 request=' .. tostring(tx.request)
            .. ' attempt=' .. tostring(attempt)
            .. ' candidate=' .. tostring(tx.nativeCandidate)
            .. ' nativeResult=' .. tostring(tx.nativeResult)
            .. ' conflict=' .. tostring(tx.rewardConflict))
        if tx.rewardConflict then return finishDenied(tx, 'conflicting-native-results') end
        if attempt >= 6 then
            return finishDenied(tx, 'native-transmog-token-ui-result-not-seen')
        end
        local scheduled, why = pcall(Ext.Timer.WaitFor, 440, function()
            afterNativeResult(attempt + 1)
        end)
        if not scheduled then return finishDenied(tx, 'native-result-follow-up-timer-failed:' .. tostring(why)) end
    end
    local scheduled, why = pcall(Ext.Timer.WaitFor, 450, function()
        afterNativeResult(1)
    end)
    if not scheduled then return finishDenied(tx, 'spawn-timer-failed:' .. tostring(why)) end
end

-- Reversal uses the original physical item held in escrow, never a fresh
-- reconstruction. ANY independently verified Scroll of Reversion (one item,
-- currently held by the wearer) can revert ANY valid recorded transmog;
-- tokens are fungible, not tied to an item, actor, or prior craft. The input
-- Scroll of Reversion is NEVER consumed. The native recipe creates a
-- temporary OBJ_Scroll_TransmogToken for a genuine success message; after
-- the original equipment has been safely returned, HomeBrew retires ONLY that
-- newly generated result. Both scroll types stay reusable and interchangeable.
-- All input Transform values MUST be None in the author's ItemCombos.txt.
local function startRevert(actor, scroll, output, request)
    if waiting then return respond(actor, request, false) end
    local ledger = SavedGameplay.TransmogRecords()
    local record = type(ledger) == 'table' and ledger[output] or nil
    if not record then
        report('REVERT_REFUSED_V12 reason=not-a-recorded-transmog')
        return respond(actor, request, false)
    end
    if not reversionMatches(scroll) or not singleItem(scroll)
        or not ownedBy(actor, scroll)
        or not ownedBy(actor, output) or not itemExists(actor)
        or not itemExists(record.Original) or not itemExists(record.Escrow)
        or not heldBy(record.Escrow, record.Original)
        or (record.VisualMode == 'SourceRootVisualOnlyV1'
            and (not record.SourceRoot or root(output) ~= record.SourceRoot))
        or (record.VisualMode ~= 'SourceRootVisualOnlyV1'
            and tostring(root(output)):lower() ~= tostring(record.DonorRoot):lower())
    then
        report('REVERT_REFUSED_V13 reason=token-type-count-owner-or-escrow-invalid')
        return respond(actor, request, false)
    end
    local slot = itemSlot(output)
    if not supportedSlot(slot) or slot ~= itemSlot(record.Original)
        or (record.Slot and record.Slot ~= slot)
        or stat(record.Original) ~= record.SourceStats
        or installedStat(record.Original) ~= record.SourceStats then
        report('REVERT_REFUSED_V11 reason=slot-or-source-mechanics-invalid')
        return respond(actor, request, false)
    end
    local worn = equippedSlot(actor, output, slot)
    local current = liveChestItem(actor, slot)
    if current and current ~= '' and not isNullItem(current)
        and not sameEntity(current, output) then
        -- It is still safe to revert an unequipped item; no equipment is moved.
        if worn then return respond(actor, request, false) end
    end
    local tx = {actor=actor, scroll=scroll, output=output, original=record.Original,
        escrow=record.Escrow, request=request, slot=slot, oldEquipped=worn,
        kind='revert', record=record, originalMoved=false}
    waiting = tx
    local function rollback(reason)
        report('REVERT_ROLLBACK_V11 request=' .. tostring(request)
            .. ' reason=' .. tostring(reason))
        if tx.originalMoved and not itemExists(output)
            and itemExists(record.Original) and ownedBy(actor, record.Original) then
            -- If the disposable replacement vanished unexpectedly after the
            -- source was recovered, never hide the only surviving real item.
            report('REVERT_CRITICAL_V11 output-already-absent; source-kept-with-actor; review-ledger-before-saving')
            return
        end
        if not tx.originalMoved then
            revokeNativeResult(tx, reason)
            if tx.oldEquipped and itemExists(output) and not equippedSlot(actor, output, slot)
                and (not liveChestItem(actor, slot) or isNullItem(liveChestItem(actor, slot))) then
                pcall(Osi.Equip, actor, output)
            end
            if waiting == tx then waiting = nil end
            return
        end
        local move = pcall(Osi.ToInventory, record.Original, record.Escrow, 1, 0, 0)
        report('REVERT_ROLLBACK_RETURN_V11 dispatched=' .. tostring(move))
        local timerOk = pcall(Ext.Timer.WaitFor, 450, function()
            if not itemExists(record.Original) or not heldBy(record.Escrow, record.Original) then
                report('REVERT_CRITICAL_V11 original-not-returned; output-kept; do-not-save')
                return -- Keep the global transaction lock until reload.
            end
            revokeNativeResult(tx, reason)
            if tx.oldEquipped and itemExists(output) and not equippedSlot(actor, output, slot)
                and (not liveChestItem(actor, slot) or isNullItem(liveChestItem(actor, slot))) then
                pcall(Osi.Equip, actor, output)
            end
            if waiting == tx then waiting = nil end
        end)
        if not timerOk then report('REVERT_CRITICAL_V11 rollback-timer-unavailable; do-not-save') end
    end
    report('REVERT_BEGIN_V13 request=' .. tostring(request)
        .. ' original=' .. record.Original .. ' output=' .. output
        .. ' slot=' .. slot .. ' originallyEquipped=' .. tostring(worn)
        .. ' scroll=' .. tostring(scroll) .. ' fungible=true')
    -- Do not leave a locked transaction indefinitely if native inventory
    -- callbacks are swallowed by another mod or interrupted by travel.
    local deadline = pcall(Ext.Timer.WaitFor, WAIT_MS, function()
        if waiting == tx then rollback('revert-transaction-timeout') end
    end)
    if not deadline then waiting = nil return respond(actor, request, false) end
    if not replyOnce(tx, true) then
        waiting = nil
        return
    end
    local scheduled = pcall(Ext.Timer.WaitFor, 450, function()
        if waiting ~= tx then return end
        if not itemExists(output) or not ownedBy(actor, output)
            or not reversionMatches(scroll) or not ownedBy(actor, scroll)
            or not heldBy(record.Escrow, record.Original) then return rollback('post-native-input-drift') end
        if worn and not pcall(Osi.Unequip, actor, output) then return rollback('unequip-dispatch-failed') end
        local timerOk = pcall(Ext.Timer.WaitFor, 350, function()
            if waiting ~= tx then return end
            local now = liveChestItem(actor, slot)
            if worn and now and now ~= '' and not isNullItem(now) then
                return rollback('output-did-not-unequip')
            end
            if not heldBy(record.Escrow, record.Original) or not ownedBy(actor, output) then
                return rollback('source-or-output-owner-changed') end
            if not verifiedNativeResult(tx) then
                return rollback('native-transmog-token-ui-result-not-confirmed')
            end
            local transferred = pcall(Osi.ToInventory, record.Original, actor, 1, 0, 0)
            if not transferred then return rollback('escrow-release-dispatch-failed') end
            tx.originalMoved = true
            local moveTimer = pcall(Ext.Timer.WaitFor, 450, function()
                if waiting ~= tx then return end
                if not itemExists(record.Original) or not ownedBy(actor, record.Original)
                    or not itemExists(output) or not ownedBy(actor, output) then
                    return rollback('source-not-delivered-or-output-lost')
                end
                if worn then
                    local slotNow = liveChestItem(actor, slot)
                    if slotNow and slotNow ~= '' and not isNullItem(slotNow) then
                        return rollback('different-item-equipped')
                    end
                    if not pcall(Osi.Equip, actor, record.Original) then
                        return rollback('source-equip-dispatch-failed')
                    end
                end
                local equipTimer = pcall(Ext.Timer.WaitFor, 450, function()
                    if waiting ~= tx then return end
                    local restored = itemExists(record.Original) and ownedBy(actor, record.Original)
                        and (not worn or equippedSlot(actor, record.Original, slot))
                    if not restored or not itemExists(output) or not ownedBy(actor, output)
                        or not itemExists(scroll) or not reversionMatches(scroll)
                        or not verifiedNativeResult(tx) then
                        return rollback('restore-verification-or-native-ui-result-failed') end
                    -- The original is back in circulation before retiring its
                    -- disposable appearance copy. Don't delete on uncertainty.
                    local deleted = discard(output)
                    if not deleted then return rollback('output-delete-failed') end
                    local deleteTimer = pcall(Ext.Timer.WaitFor, 400, function()
                        if waiting ~= tx then return end
                        if itemExists(output) then return rollback('output-still-present') end
                        if not verifiedNativeResult(tx)
                            or not itemExists(record.Original) or not ownedBy(actor, record.Original) then
                            report('REVERT_CRITICAL_V15 original-or-native-result-drift-after-output-deletion; do-not-save')
                            return
                        end
                        -- Keep the original, interchangeable Reversion tool.
                        -- The NEW native recipe result only exists for UI success;
                        -- its exact entity ID was captured by the engine event.
                        if not itemExists(scroll) or not reversionMatches(scroll)
                            or not ownedBy(actor, scroll) then
                            report('REVERT_CRITICAL_V15 reusable-tool-lost-after-output-removal; do-not-save')
                            return
                        end
                        local retired = discard(tx.nativeResult)
                        report('REVERT_NATIVE_RESULT_RETIRE_V15 request=' .. tostring(request)
                            .. ' item=' .. tostring(tx.nativeResult)
                            .. ' sent=' .. tostring(retired)
                            .. ' reusableTool=' .. tostring(scroll))
                        if not retired then
                            report('REVERT_CRITICAL_V15 native-result-retirement-refused; do-not-save')
                            return
                        end
                        local finalTimer = pcall(Ext.Timer.WaitFor, 400, function()
                            if waiting ~= tx then return end
                            if itemExists(tx.nativeResult)
                                or not itemExists(scroll) or not reversionMatches(scroll)
                                or not ownedBy(actor, scroll)
                                or not itemExists(record.Original) or not ownedBy(actor, record.Original)
                                or (worn and not equippedSlot(actor, record.Original, slot)) then
                                report('REVERT_CRITICAL_V15 native-result-or-tool-or-original-check-failed; do-not-save')
                                return
                            end
                            ledger[output] = nil
                            report('REVERT_VERIFIED_REUSABLE_V15 original=' .. record.Original
                                .. ' outputRemoved=' .. output
                                .. ' toolRetained=true nativeResultRetired=' .. tostring(tx.nativeResult)
                                .. ' sourceEquipped=' .. tostring(equippedSlot(actor, record.Original, slot)))
                            if waiting == tx then waiting = nil end
                        end)
                        if not finalTimer then report('REVERT_CRITICAL_V12 final-verification-timer-failed') end
                    end)
                    if not deleteTimer then
                        report('REVERT_CRITICAL_V11 output-delete-verification-timer-failed; do-not-save')
                    end
                end)
                if not equipTimer then rollback('source-equip-check-timer-unavailable') end
            end)
            if not moveTimer then rollback('source-transfer-timer-unavailable') end
        end)
        if not timerOk then rollback('unequip-check-timer-unavailable') end
    end)
    if not scheduled then
        report('REVERT_CRITICAL_V11 unable-to-schedule-after-native-approval')
    end
end

-- Diagnose native-combination routing without assuming that a loaded Lua module
-- means the separate ItemCombos.txt was packed into the active game mod.
local function shortInput(id)
    if not id or id == '' then return '<empty>' end
    local engineStat = installedStat(id)
    local templateStat = stat(id)
    local slot = read(component(entityFor(id), 'Equipable'), 'Slot')
    return tostring(id) .. '[engine=' .. tostring(engineStat)
        .. ',rootStat=' .. tostring(templateStat) .. ',slot=' .. tostring(slot) .. ']'
end

Ext.Osiris.RegisterListener('RequestCanCombine', 7, 'before', function(actor, a, b, c, d, e, requestID)
    -- Requests are user-triggered; this does no ongoing polling or global search.
    -- Check all five inputs because the native UI may reorder recipe ingredients.
    local inputs = {a, b, c, d, e}
    local sawScroll = false
    for i = 1, 5 do
        local id = inputs[i]
        if id and not isNullItem(id) and (installedStat(id) == RESOURCE_STAT or stat(id) == RESOURCE_STAT
            or installedStat(id) == REVERSION_STAT or stat(id) == REVERSION_STAT) then
            sawScroll = true
            break
        end
    end
    if not sawScroll then return end
    report('NATIVE_COMBINE_REQUEST request=' .. tostring(requestID)
        .. ' actor=' .. tostring(actor)
        .. ' slot1=' .. shortInput(a) .. ' slot2=' .. shortInput(b)
        .. ' slot3=' .. shortInput(c) .. ' slot4=' .. shortInput(d)
        .. ' slot5=' .. shortInput(e))
    if reversionMatches(a) and isNullItem(c) and isNullItem(d) and isNullItem(e) then
        report('REVERT_ROUTE_TWO_ITEMS_V13 request=' .. tostring(requestID))
        return startRevert(actor, a, b, requestID)
    end
    if not scrollMatches(a) then
        report('RECIPE_ROUTE_NOT_HANDLED_V12 reason=unexpected-scroll-or-ingredient-order')
        return
    end
    report('RECIPE_ROUTE_MATCHED request=' .. tostring(requestID))
    if isNullItem(c) and isNullItem(d) and isNullItem(e) then
        report('REVERT_LEGACY_UNAVAILABLE_V13 reason=use-scroll-of-reversion-to-revert')
        return respond(actor, requestID, false)
    end
    if not isNullItem(d) or not isNullItem(e) then
        report('RECIPE_ROUTE_REJECTED request=' .. tostring(requestID)
            .. ' reason=unexpected-fourth-or-fifth-ingredient')
        return respond(actor, requestID, false)
    end
    report('RECIPE_ROUTE_THREE_ITEMS request=' .. tostring(requestID)
        .. ' unused-slots-normalized=true')
    startCraft(actor, a, b, c, requestID)
end)

Ext.Osiris.RegisterListener('TemplateAddedTo', 4, 'after', function(template, spawned, owner, _)
    local tx = waiting
    if not tx then return end
    local expected = nativeExpectedStat(tx)
    if expected and (installedStat(spawned) == expected or stat(spawned) == expected) then
        report('NATIVE_TEMPLATE_ADDED_V14 request=' .. tostring(tx.request)
            .. ' result=' .. tostring(spawned) .. ' owner=' .. tostring(owner)
            .. ' stat=' .. tostring(installedStat(spawned))
            .. ' rootStat=' .. tostring(stat(spawned)))
        -- A newly added item may temporarily be in the native crafting holder.
        -- Stage its exact ID, but require verified character ownership before
        -- accepting it as the recipe result. Never scan existing inventory.
        if stageNativeCandidate(tx, spawned, 'TemplateAddedTo') then return end
    end
    if not sameEntity(owner, tx.actor) then return end
    if tx.kind ~= 'craft' or root(spawned) ~= tx.donorRoot
        or sameEntity(spawned, tx.original) or sameEntity(spawned, tx.appearance) then return end
    if not itemExists(spawned) then return end
    local ok, err = pcall(applyCraft, tx, spawned)
    if not ok then
        report('CRAFT_CALLBACK_ERROR request=' .. tostring(tx.request) .. ' error=' .. tostring(err))
        if waiting == tx then
            tx.spawn = spawned
            finishDenied(tx, 'unexpected-craft-callback-error')
        end
    end
end)

-- A genuine ItemCombinationResult may report its actual result through this
-- engine event. Treat it as a second exact-ID source, never as permission to
-- infer a reward from preexisting inventory stacks.
Ext.Osiris.RegisterListener('TemplatesCombined', 7, 'after', function(a, b, c, d, e, actor, result)
    local tx = waiting
    if not tx or not sameEntity(actor, tx.actor) then return end
    report('NATIVE_TEMPLATES_COMBINED_V14 request=' .. tostring(tx.request)
        .. ' kind=' .. tostring(tx.kind) .. ' result=' .. tostring(result)
        .. ' resultStat=' .. tostring(installedStat(result)))
    stageNativeCandidate(tx, result, 'TemplatesCombined')
end)

-- Native crafting can emit Combined instead of, or alongside, the
-- template-specific variant. Both provide an exact newly created result ID.
Ext.Osiris.RegisterListener('Combined', 7, 'after', function(a, b, c, d, e, actor, result)
    local tx = waiting
    if not tx or not sameEntity(actor, tx.actor) then return end
    report('NATIVE_COMBINED_V14 request=' .. tostring(tx.request)
        .. ' kind=' .. tostring(tx.kind) .. ' result=' .. tostring(result)
        .. ' resultStat=' .. tostring(installedStat(result)))
    stageNativeCandidate(tx, result, 'Combined')
end)

-- When the generated result is added directly to the crafter's inventory,
-- inspect that event even if the engine did not emit TemplatesCombined.
-- This is an event for an item added NOW, not a scan of existing inventory.
Ext.Osiris.RegisterListener('AddedTo', 3, 'after', function(item, owner, _)
    local tx = waiting
    if not tx or not sameEntity(owner, tx.actor) then return end
    local expected = nativeExpectedStat(tx)
    if expected and (installedStat(item) == expected or stat(item) == expected) then
        report('NATIVE_ADDED_TO_V14 request=' .. tostring(tx.request)
            .. ' item=' .. tostring(item) .. ' stat=' .. tostring(installedStat(item)))
        stageNativeCandidate(tx, item, 'AddedTo')
    elseif tx.nativeCandidate and sameEntity(tx.nativeCandidate, item) then
        recordNativeResult(tx, item, 'AddedTo-candidate')
    end
end)

-- Version 8 used a transient per-item cache-template stat override, which is
-- not sufficient as a save-load restoration strategy. The original item in
-- protected escrow is the canonical gameplay source. Never derive mechanics
-- from the donor's root template after reload. Do not create a second item.
-- This routine also accepts existing v8 records, without changing their schema.
local restoreInFlight = {}
local function restoreOutputFromSource(output, record, origin)
    if type(output) ~= 'string' or type(record) ~= 'table' then return false, 'invalid-ledger-record' end
    if type(record.Original) ~= 'string' or type(record.DonorRoot) ~= 'string'
        or type(record.SourceStats) ~= 'string' or type(record.Actor) ~= 'string'
        or type(record.Escrow) ~= 'string' or record.SourceStats == '' then
        return false, 'incomplete-record'
    end
    if not uuidSuffix(output) or not uuidSuffix(record.Original) or not uuidSuffix(record.Actor) then
        return false, 'unrecognized-item-identity'
    end
    if sameEntity(output, record.Original) then return false, 'output-is-original' end
    if not itemExists(output) or not itemExists(record.Original) or not itemExists(record.Actor) then
        return false, 'saved-item-or-character-not-loaded'
    end
    if not itemExists(record.Escrow) or not heldBy(record.Escrow, record.Original) then
        return false, 'protected-original-not-in-escrow'
    end
    local visualOnly = record.VisualMode == 'SourceRootVisualOnlyV1'
    if visualOnly then
        if type(record.SourceRoot) ~= 'string' or root(output) ~= record.SourceRoot
            or root(record.Original) ~= record.SourceRoot then
            return false, 'source-root-record-identity-mismatch'
        end
    elseif root(output) ~= record.DonorRoot then
        return false, 'legacy-output-no-longer-donor-root'
    end
    local oldRootStat = stat(record.Original)
    if oldRootStat ~= record.SourceStats or installedStat(record.Original) ~= record.SourceStats then
        return false, 'protected-original-stat-disagrees-with-ledger'
    end
    -- A replacement may legitimately move between party characters while its
    -- original remains in escrow. Bind the current actor only through the
    -- engine's verified inventory-character ownership query.
    local actor = record.Actor
    if not ownedBy(actor, output) then
        local currentOwner = firstCharacterOwner(output)
        if not currentOwner or not itemExists(currentOwner)
            or sameEntity(currentOwner, record.Escrow)
            or not ownedBy(currentOwner, output) then
            return false, 'replacement-holder-not-a-verified-character'
        end
        report('TRANSFER_OWNER_V11 output=' .. output .. ' previous=' .. tostring(actor)
            .. ' current=' .. tostring(currentOwner))
        record.Actor = currentOwner
        actor = currentOwner
    end
    local original = entityFor(record.Original)
    local replacement = entityFor(output)
    if not original or not replacement then return false, 'saved-components-not-available' end
    local actualSlot = itemSlot(output)
    if not supportedSlot(actualSlot) or itemSlot(record.Original) ~= actualSlot
        or (record.Slot and record.Slot ~= actualSlot)
        or not component(original, 'Armor') then
        return false, 'saved-armour-slot-or-type-mismatch'
    end
    -- Compatibility: pre-v1 donor-root records are not safe by the new
    -- mechanical standard. Preserve their EXACT previous restoration behavior
    -- and their verified Scroll of Reversion, rather than silently damaging
    -- an existing campaign. They must be reverted/retransmogged to gain the
    -- new source-root mechanics. Do not claim they have been converted.
    if not visualOnly then
        if record.VisualMode ~= 'DonorRootProficiencyV2' then
            report('LEGACY_DONOR_ROOT_NEEDS_REVERSION output=' .. tostring(output)
                .. ' retainedOldRestore=true mechanicsNotGuaranteed=true')
        end
        -- Only repair the naturally reverted donor stat or the already-restored
        -- original stat. A third stat suggests an unrelated edit; fail closed.
        local donorBaseStat = stat(output)
        local before = installedStat(output)
        if before ~= donorBaseStat and before ~= record.SourceStats then
            return false, 'replacement-has-unrecognized-runtime-stat:' .. tostring(before)
        end
        local serverItem = component(replacement, 'ServerItem')
        if not serverItem or type(read(serverItem, 'CreateCacheTemplate')) ~= 'function' then
            return false, 'saved-server-item-cannot-create-instance-template'
        end
        local made, makeError = pcall(function() serverItem:CreateCacheTemplate() end)
        if not made then return false, 'saved-template-create-failed:' .. tostring(makeError) end
        local cache = read(serverItem, 'Template')
        if not cache then return false, 'saved-instance-template-missing' end
        -- Preserve the donor's visuals unchanged. Only restore the source stats.
        local visuals = snapshot(read(read(cache, 'Equipment'), 'Visuals'))
        local signature = visuals and scalarSignature(visuals)
        if not signature then return false, 'saved-donor-visuals-unreadable' end
        local wrote, writeError = pcall(function() cache.Stats = record.SourceStats end)
        if not wrote or tostring(read(cache, 'Stats')) ~= record.SourceStats then
            return false, 'saved-stat-override-refused:' .. tostring(writeError)
        end
        local after = snapshot(read(read(cache, 'Equipment'), 'Visuals'))
        if not after or scalarSignature(after) ~= signature then
            return false, 'saved-visuals-changed-while-restoring-stats'
        end
        for _, name in ipairs(REQUIRED) do
            if not component(original, name) then return false, 'protected-original-lacks:' .. name end
            local ok, why = syncComponent(original, replacement, name)
            if not ok then return false, 'restore-' .. name .. ':' .. tostring(why) end
        end
        for _, name in ipairs(OPTIONAL) do
            local ok, why = syncComponent(original, replacement, name)
            if not ok then return false, 'restore-' .. name .. ':' .. tostring(why) end
        end
        if record.VisualMode == 'DonorRootProficiencyV2' then
            if type(record.SourceProficiency) ~= 'string' then
                return false, 'new-record-missing-source-group'
            end
            local profOk, profWhy = synchronizeNativeProficiency(original, replacement, record.SourceStats)
            if not profOk then return false, 'saved-proficiency-sync-refused:' .. tostring(profWhy) end
            local matchOK, matchWhy = sameProficiency(record.Original, output, record.SourceProficiency)
            if not matchOK then return false, 'saved-proficiency-mismatch:' .. tostring(matchWhy) end
        end
        local got = installedStat(output)
        report('LOAD_COMPONENTS_V10 origin=' .. tostring(origin)
            .. ' output=' .. output .. ' previousStat=' .. tostring(before)
            .. ' donorStat=' .. tostring(donorBaseStat)
            .. ' restoredStat=' .. tostring(got)
            .. ' originalStat=' .. record.SourceStats)
        if got ~= record.SourceStats then return false, 'restored-stat-engine-readback-mismatch' end
        return true, before ~= record.SourceStats
    end
    -- New source-root output is mechanically the original equipment. Never
    -- overwrite Stats or any gameplay component on load. A source-root stat
    -- mismatch is a genuine integrity failure, not an invitation to patch it.
    local before = installedStat(output)
    if before ~= record.SourceStats or stat(output) ~= record.SourceStats then
        return false, 'source-root-output-stat-drift'
    end
    local serverItem = component(replacement, 'ServerItem')
    if not serverItem or type(read(serverItem, 'CreateCacheTemplate')) ~= 'function' then
        return false, 'saved-server-item-cannot-create-instance-template'
    end
    local made, makeError = pcall(function() serverItem:CreateCacheTemplate() end)
    if not made then return false, 'saved-template-create-failed:' .. tostring(makeError) end
    local cache = read(serverItem, 'Template')
    if not cache then return false, 'saved-instance-template-missing' end
    local visualOK, signature = transplantDonorVisuals(cache, record.DonorRoot)
    if not visualOK then return false, 'saved-visual-only-transfer-refused:' .. tostring(signature) end
    if not sourceRootIdentityMatches(output, record.SourceRoot, record.SourceStats)
        or itemVisualSignature(output) ~= signature then
        return false, 'saved-visual-only-readback-mismatch'
    end
    local cueOK, cueResult = cueDonorVisualRoot(output, record.SourceRoot, record.DonorRoot)
    if not cueOK then return false, 'saved-visual-renderer-cue-refused:' .. tostring(cueResult) end
    if not sourceRootIdentityMatches(output, record.SourceRoot, record.SourceStats) then
        return false, 'saved-visual-cue-changed-mechanical-identity'
    end
    report('LOAD_SOURCE_ROOT_VISUAL_ONLY_V1 origin=' .. tostring(origin)
        .. ' output=' .. tostring(output) .. ' stat=' .. tostring(before)
        .. ' sourceRoot=' .. tostring(record.SourceRoot)
        .. ' appearanceRoot=' .. tostring(record.DonorRoot))
    return true, false
end

-- Applying stat and component values restores the item's saved mechanics, but
-- does not itself reenact BG3's equipment passive/status grant lifecycle.
-- A restored stat can already match its source while those grants are absent.
-- Therefore every VERIFIED and CURRENTLY WORN transmog must be refreshed on
-- load, regardless of whether its stat ID was reverted. No other equipment is
-- ever unequipped, and an unequipped transmog is left alone until worn normally.
local function performRestore(recordId, record, trigger)
    if restoreInFlight[recordId] then
        report('LOAD_REFRESH_COALESCED_V10 output=' .. tostring(recordId)
            .. ' trigger=' .. tostring(trigger))
        return
    end
    restoreInFlight[recordId] = true
    local ok, outcome, statWasReverted = pcall(restoreOutputFromSource, recordId, record, trigger)
    if not ok or not outcome then
        restoreInFlight[recordId] = nil
        report('LOAD_RESTORE_REFUSED_V10 output=' .. tostring(recordId)
            .. ' trigger=' .. tostring(trigger)
            .. ' reason=' .. tostring(ok and statWasReverted or outcome)
            .. ' originalOwner=' .. tostring(type(record)=='table' and inventoryOwner(record.Original) or nil)
            .. ' originalCharacterOwner=' .. tostring(type(record)=='table' and firstCharacterOwner(record.Original) or nil)
            .. ' outputStat=' .. tostring(installedStat(recordId))
            .. (type(record)=='table' and record.VisualMode ~= 'SourceRootVisualOnlyV1'
                and record.VisualMode ~= 'DonorRootProficiencyV2'
                and ' action=legacy-donor-root-please-revert' or ' action=do-not-overwrite-this-save'))
        return
    end
    if not equippedSlot(record.Actor, recordId) then
        report('LOAD_RESTORED_V10 output=' .. recordId .. ' stat=' .. record.SourceStats
            .. ' equipped=false refreshed=false reason=item-not-worn')
        restoreInFlight[recordId] = nil
        return
    end
    report('LOAD_PASSIVES_REFRESH_V10 output=' .. recordId
        .. ' sourceStat=' .. tostring(record.SourceStats)
        .. ' statWasReverted=' .. tostring(statWasReverted)
        .. ' equippedAtStart=true refreshRequired=true')
    -- Validate immediately before disturbing the player's equipment.
    if not itemExists(recordId) or not ownedBy(record.Actor, recordId)
        or not itemExists(record.Original) or not heldBy(record.Escrow, record.Original)
        or installedStat(recordId) ~= record.SourceStats then
        restoreInFlight[recordId] = nil
        report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId
            .. ' reason=provenance-changed-before-unequip')
        return
    end
    local dispatched = pcall(Osi.Unequip, record.Actor, recordId)
    report('LOAD_REEQUIP_DISPATCH_V10 output=' .. recordId .. ' unequip=' .. tostring(dispatched))
    if not dispatched then
        restoreInFlight[recordId] = nil
        report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=unequip-dispatch-failed')
        return
    end
    local function attemptReequip(attempt)
        if not restoreInFlight[recordId] then return end
        local current = liveChestItem(record.Actor, record.Slot or 'Breast')
        if not itemExists(recordId) or not ownedBy(record.Actor, recordId)
            or not itemExists(record.Original) or not heldBy(record.Escrow, record.Original)
            or installedStat(recordId) ~= record.SourceStats then
            report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=pre-equip-provenance-or-stat-drift')
            restoreInFlight[recordId] = nil
            return
        end
        if current and current ~= '' and not isNullItem(current) then
            if sameEntity(current, recordId) then
                -- The unequip operation is still settling. Never send Equip
                -- against a still-worn item; BG3 may consider it a no-op and
                -- fail to reapply equipment-granted effects.
                if attempt < 3 then
                    report('LOAD_WAIT_UNEQUIP_V10 output=' .. recordId
                        .. ' attempt=' .. tostring(attempt) .. ' stillEquipped=true')
                    local scheduled = pcall(Ext.Timer.WaitFor, 250, function() attemptReequip(attempt + 1) end)
                    if scheduled then return end
                    report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=unequip-retry-timer-failed')
                else
                    report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=unequip-not-settled')
                end
            else
                report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId
                    .. ' reason=unrelated-chest-equipped chest=' .. tostring(current))
            end
            restoreInFlight[recordId] = nil
            return
        end
        local sent = pcall(Osi.Equip, record.Actor, recordId)
        report('LOAD_EQUIP_DISPATCH_V10 output=' .. recordId
            .. ' sent=' .. tostring(sent) .. ' attempt=' .. tostring(attempt))
        if not sent then
            restoreInFlight[recordId] = nil
            report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=reequip-dispatch-failed')
            return
        end
        local timerOk = pcall(Ext.Timer.WaitFor, 450, function()
            local verified = itemExists(recordId) and equippedSlot(record.Actor, recordId)
                and installedStat(recordId) == record.SourceStats
                and itemExists(record.Original) and heldBy(record.Escrow, record.Original)
                and ownedBy(record.Actor, recordId)
                and (record.VisualMode ~= 'SourceRootVisualOnlyV1'
                    or sourceRootIdentityMatches(recordId, record.SourceRoot, record.SourceStats))
                and (record.VisualMode ~= 'DonorRootProficiencyV2'
                    or (select(1, sameProficiency(record.Original, recordId, record.SourceProficiency))))
            report('LOAD_RESTORED_V10 output=' .. recordId
                .. ' stat=' .. tostring(installedStat(recordId))
                .. ' equipped=' .. tostring(equippedSlot(record.Actor, recordId))
                .. ' sourceInEscrow=' .. tostring(heldBy(record.Escrow, record.Original))
                .. ' refreshed=' .. tostring(verified)
                .. ' equipLifecycleCompleted=' .. tostring(verified))
            if not verified then
                report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId
                    .. ' reason=post-reequip-validation-failed')
            end
            restoreInFlight[recordId] = nil
        end)
        if not timerOk then
            restoreInFlight[recordId] = nil
            report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=post-reequip-timer-failed')
        end
    end
    local scheduled = pcall(Ext.Timer.WaitFor, 250, function() attemptReequip(1) end)
    if not scheduled then
        restoreInFlight[recordId] = nil
        report('LOAD_RESTORE_UNSAFE_V10 output=' .. recordId .. ' reason=reequip-timer-failed')
    end
end

-- SessionLoaded and SavegameLoaded can both fire for one actual load. The
-- engine can re-run equipped-passive lifecycle twice if each event starts an
-- independent restore. Combine events into one bounded per-load batch. A
-- subsequent load is not permanently suppressed: the gate reopens after a
-- short interval and, when available, on SessionUnloading.
local loadBatchPending = false
local loadBatchClosed = false
local loadBatchSerial = 0
local function reopenLoadBatch(serial)
    if loadBatchSerial == serial then
        loadBatchClosed = false
        loadBatchPending = false
    end
end
-- SE v33 has no SessionUnloading event. The Lua VM resets at unload,
-- and the existing 5.5-second gate reopens across repeated load notifications.
-- Do not subscribe to an unavailable lifecycle event.

local function queueLoadRestore(trigger)
    if loadBatchPending or loadBatchClosed then
        report('LOAD_EVENT_COALESCED_V11 trigger=' .. tostring(trigger))
        return
    end
    loadBatchPending = true
    loadBatchSerial = loadBatchSerial + 1
    local serial = loadBatchSerial
    local scheduled, timerError = pcall(Ext.Timer.WaitFor, 700, function()
        if serial ~= loadBatchSerial then return end
        loadBatchPending = false
        loadBatchClosed = true
        -- No always-on polling. The gate is bounded so a later genuine reload
        -- can restore once again even if SessionUnloading was not available.
        local reopen = pcall(Ext.Timer.WaitFor, 5500, function() reopenLoadBatch(serial) end)
        if not reopen then report('LOAD_BATCH_GATE_TIMER_FAILED_V11') end
        if waiting then
            report('LOAD_RESTORE_SKIPPED_V11 reason=craft-or-revert-active trigger=' .. tostring(trigger))
            return
        end
        local ledger = SavedGameplay.TransmogRecords()
        local count = 0
        if type(ledger) == 'table' then for _ in pairs(ledger) do count = count + 1 end end
        report('LOAD_LEDGER_V11 trigger=' .. tostring(trigger)
            .. ' storage=' .. (SavedGameplay.Ready() and 'ModVars' or 'legacy-fallback')
            .. ' ledger=' .. type(ledger)
            .. ' records=' .. tostring(count))
        if type(ledger) ~= 'table' then return end
        for output, record in pairs(ledger) do performRestore(output, record, trigger) end
    end)
    if not scheduled then
        loadBatchPending = false
        report('LOAD_RESTORE_UNSAFE_V11 reason=unable-to-schedule:' .. tostring(timerError))
    end
end

Ext.Osiris.RegisterListener('SavegameLoaded', 0, 'after', function()
    queueLoadRestore('SavegameLoaded')
end)
-- The mod's bootstrap can run before the persistent table is restored. The
-- extender guarantees it is available by SessionLoaded, so listen there too.
if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function() queueLoadRestore('SessionLoaded') end)
end

report('HANDLERS_REGISTERED recipeRoute=v18 scroll=' .. RESOURCE_STAT .. ' revert=' .. REVERSION_STAT .. ' nativeResult=' .. RESULT_STAT .. ' reusable=true rootUUIDs=author-defined')
report('RECIPE_ROUTE_V18 reusable inputs; both native recipes -> OBJ_Scroll_TransmogToken; exact newly generated token retired after verification')
