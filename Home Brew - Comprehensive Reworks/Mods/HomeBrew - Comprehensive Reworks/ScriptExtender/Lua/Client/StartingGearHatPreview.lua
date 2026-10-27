-- HomeBrew creation mannequin head-slot preview. Client presentation only.
-- The live gameplay grant path is intentionally independent from this preview.
local Preview = {}
local Catalog = Ext.Require('Shared/StartingGearCatalog.lua')
local REPORT = 'HomeBrew/Diagnostics/HB_EquipmentHatPreview.txt'
local selected = false
local current = nil
local attemptAt = 0
local attempts = 0
local lines = {'HomeBrew head equipment preview v3; fixed-string equipment stat'}
local signature = nil

local function note(message)
    if message == signature then return end
    signature = message
    lines[#lines + 1] = message
    if #lines > 40 then table.remove(lines, 2) end
    pcall(function() Ext.IO.SaveFile(REPORT, table.concat(lines, '\n') .. '\n') end)
end

local function read(object, key)
    if not object then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
end

local function component(entity, name)
    if not entity then return nil end
    local ok, value = pcall(function() return entity:GetComponent(name) end)
    return ok and value or nil
end

local function instances(name)
    if not Ext.Entity or type(Ext.Entity.GetAllEntitiesWithComponent) ~= 'function' then return nil end
    local ok, result = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
    if ok and type(result) == 'table' then return result end
end

local function activeDefinition()
    local roots = instances('CCCreation')
    local definitions = instances('CCCharacterDefinition')
    if not roots or not definitions or #roots ~= 1 or #definitions ~= 1 then return nil end
    local root = component(roots[1], 'CCCreation')
    local refs = read(root, 'CharacterDefinitions')
    local owner = refs and read(refs, 1)
    if not owner or tostring(owner) ~= tostring(definitions[1]) then return nil end
    return definitions[1]
end

local function validDummy()
    local owner = activeDefinition()
    if not owner then return nil, 'No unique initial character-creation definition' end
    -- The preview belongs to the active CC definition. Do not select a dummy
    -- from a global component query: stale or auxiliary dummies may coexist.
    local definition = component(owner, 'ClientCCDummyDefinition')
    if not definition then
        local all = instances('ClientCCDummyDefinition')
        return nil, 'Active CC definition lacks ClientCCDummyDefinition; global matches=' .. tostring(all and #all or 'unavailable')
    end
    local targetRef = read(definition, 'Dummy')
    if not targetRef then return nil, 'Active CC dummy reference is missing' end
    -- A dummy reference may already be an entity proxy, as with the native
    -- ability preview. Ext.Entity.Get expects a GUID, net id or entity handle.
    local mannequin = nil
    local memberOk, getComponent = pcall(function() return targetRef.GetComponent end)
    if memberOk and type(getComponent) == 'function' then
        mannequin = targetRef
    else
        local ok, entity = pcall(Ext.Entity.Get, targetRef)
        if ok then mannequin = entity end
    end
    if not mannequin then return nil, 'Active CC dummy could not be resolved to an entity' end
    local stats = component(mannequin, 'Stats')
    local visuals = component(mannequin, 'ClientCharacter')
        or component(mannequin, 'ClientEquipmentVisuals')
        or component(mannequin, 'CharacterVisual')
    if not stats and not visuals then
        return nil, 'Active CC dummy lacks character stats and expected visual components'
    end
    local map = read(definition, 'field_18_Map_unk_FS')
    if not map then return nil, 'Active CC dummy data map is unavailable' end
    return {owner=owner,definition=definition,mannequin=mannequin,map=map}
end

local function slotKey(map)
    -- Only use a real installed ItemSlot enum value. The string fallback used
    -- previously could address an unrelated key in an untyped native map.
    local enums = Ext.Enums and Ext.Enums.ItemSlot
    local key = enums and read(enums, 'Helmet')
    if key == nil then return nil, 'ItemSlot.Helmet enum unavailable' end
    local ok = pcall(function() return map[key] end)
    if not ok then return nil, 'Helmet enum is not a readable equipment-map key' end
    return key
end

local function resolveTemplate()
    return Catalog.RootTemplate('ARM_Hat')
end

local function restore()
    if not current then return end
    local old = current
    current = nil
    -- Never touch the mannequin after initial creation has disappeared.
    if not activeDefinition() then return end
    local found, reason = validDummy()
    if not found or tostring(found.owner) ~= old.owner or tostring(found.mannequin) ~= old.mannequin then
        note('RESTORE_SKIPPED ' .. tostring(reason or 'Creation mannequin changed'))
        return
    end
    local map = found.map
    local ok, value = pcall(function() return map[old.key] end)
    if not ok or tostring(value) ~= old.applied then
        note('RESTORE_SKIPPED Equipment slot was changed by BG3')
        return
    end
    local restored, err = pcall(function()
        map[old.key] = old.previous
        local change = read(found.definition, 'ChangeId')
        if type(change) == 'number' then found.definition.ChangeId = change + 1 end
    end)
    note(restored and 'RESTORE_REQUESTED Original head visual restored' or
        ('RESTORE_FAILED ' .. tostring(err)))
end

function Preview.Choose(stat)
    local desired = stat == 'ARM_Hat'
    if desired == selected then return end
    selected = desired
    if not desired then restore() end
    attempts = 0
    attemptAt = 0
end

function Preview.Update(now)
    if not selected or current or now < attemptAt or attempts >= 5 then return end
    attempts = attempts + 1
    attemptAt = now + 280
    local found, reason = validDummy()
    if not found then
        note('WAIT_' .. tostring(attempts) .. ' ' .. tostring(reason))
        return
    end
    local root = resolveTemplate()
    if not root then note('UNAVAILABLE Simple Hat equipment template not installed'); return end
    -- The CC dummy map holds FixedString equipment IDs. The item template
    -- is verified above, but the slot assignment uses the installed stat ID.
    local equipmentId = 'ARM_Hat'
    local key, keyWhy = slotKey(found.map)
    if key == nil then note('UNAVAILABLE ' .. tostring(keyWhy)); return end
    local ok, previous = pcall(function() return found.map[key] end)
    if not ok then note('UNAVAILABLE Cannot read mannequin head slot'); return end
    note('HEAD_SLOT_BEFORE value=' .. tostring(previous) .. '; type=' .. type(previous) .. '; template=' .. tostring(root))
    local changed, err = pcall(function()
        found.map[key] = equipmentId
        local change = read(found.definition, 'ChangeId')
        if type(change) == 'number' then found.definition.ChangeId = change + 1 end
    end)
    if not changed then note('PREVIEW_FAILED ' .. tostring(err)); return end
    local verified, present = pcall(function() return found.map[key] end)
    if not verified or tostring(present) ~= equipmentId then
        note('PREVIEW_UNCONFIRMED Mannequin equipment stat assignment not retained')
        return
    end
    current = {owner=tostring(found.owner),mannequin=tostring(found.mannequin),
        key=key,previous=previous,applied=equipmentId}
    note('PREVIEW_STAT_UPDATED Head=ARM_Hat; map value=' .. tostring(present) .. '; mannequin render unverified')
end

function Preview.Reset()
    selected = false
    restore()
    attempts = 0
    attemptAt = 0
end

return Preview
