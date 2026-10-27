

local Diagnostic = {}
local definitions = {
    "CCCharacterDefinition", "CCRespecDefinition", "CCFullRespecDefinition",
    "CCLevelUpDefinition", "ClientCCBaseDefinitionState",
}

local function Array(values)
    if not values then return end
    local result = {}
    for index = 1, 7 do
        local value = values[index]
        if type(value) ~= "number" then return end
        result[index] = value
    end
    return result
end

local function Component(entity, name)
    local ok, value = pcall(entity.GetComponent, entity, name)
    if ok then return value end
end

local function Record(entity)
    local record = { Entity = tostring(entity), Definitions = {} }
    
    
    local ok, netId = pcall(entity.GetNetId, entity)
    if ok then record.NetId = netId end
    for _, name in ipairs(definitions) do
        local component = Component(entity, name)
        if component then
            
            
            local item = { Abilities = Array(component.Definition.Abilities) }
            if name == "CCCharacterDefinition" then
                item.ChangeId, item.Synced = component.ChangeId, component.Synced
            elseif name == "CCLevelUpDefinition" then
                item.ChangeId, item.NeedsSync = component.ChangeId, component.NeedsSync
                item.Character = tostring(component.Character)
            end
            record.Definitions[name] = item
        end
    end
    local common = Component(entity, "CCDefinitionCommon")
    if common then
        record.Common = { ChangeId = common.ChangeId, PendingChoices = common.PendingChoices,
            ErrorFlags = common.Error.Flags }
    end
    local session = Component(entity, "CCSessionCommon")
    if session then record.SessionNetId = session.NetId end
    local state = Component(entity, "CCState")
    if state then record.State = { HasDummy = state.HasDummy, Canceled = state.Canceled } end
    local derived = Component(entity, "ClientCCDefinitionState")
    if derived then
        record.ClientState = { ChangeId = derived.ChangeId, Entity = tostring(derived.Entity) }
    end
    local extended = Component(entity, "ClientCCDefinitionStateEx")
    if extended then record.ClientStateEx = { ChangeId = extended.ChangeId, NeedsSync = extended.NeedsSync } end
    local dummy = Component(entity, "ClientCCDummyDefinition")
    if dummy then
        record.Dummy = { Entity = tostring(dummy.Dummy), ChangeId = dummy.ChangeId, ChangeId2 = dummy.ChangeId2 }
    end
    return record
end

function Diagnostic.Snapshot()
    local snapshot = { Definitions = {}, Links = {}, UpdateQueues = {}, Errors = {} }
    local seen = {}
    for _, name in ipairs(definitions) do
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
        if not ok then
            snapshot.Errors[#snapshot.Errors + 1] = name .. ": " .. tostring(entities)
        else
            for _, entity in ipairs(entities) do
                local token = tostring(entity)
                if not seen[token] and #snapshot.Definitions < 32 then
                    seen[token] = true
                    local read, record = pcall(Record, entity)
                    if read then snapshot.Definitions[#snapshot.Definitions + 1] = record
                    else snapshot.Errors[#snapshot.Errors + 1] = token .. ": " .. tostring(record) end
                end
            end
        end
    end
    table.sort(snapshot.Definitions, function(a, b) return a.Entity < b.Entity end)
    for _, name in ipairs({ "CCCreation", "CCRespec", "CCFullRespec" }) do
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, name)
        if ok then
            for _, entity in ipairs(entities) do
                local component = Component(entity, name)
                local item = { Type = name, Entity = tostring(entity) }
                if name == "CCCreation" then
                    item.CharacterDefinitions = {}
                    for _, definition in ipairs(component.CharacterDefinitions) do
                        item.CharacterDefinitions[#item.CharacterDefinitions + 1] = tostring(definition)
                    end
                else
                    item.Character, item.Respec = tostring(component.Character), tostring(component.Respec)
                end
                snapshot.Links[#snapshot.Links + 1] = item
            end
        end
    end
    if Ext.IsServer() then
        local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "ServerCCUpdates")
        if ok then
            for _, entity in ipairs(entities) do
                local component = Component(entity, "ServerCCUpdates")
                local item = { Entity = tostring(entity), Entries = {} }
                for target, revision in pairs(component.Updates) do
                    item.Entries[#item.Entries + 1] = { Entity = tostring(target), Revision = revision }
                end
                table.sort(item.Entries, function(a, b) return a.Entity < b.Entity end)
                snapshot.UpdateQueues[#snapshot.UpdateQueues + 1] = item
            end
        else snapshot.Errors[#snapshot.Errors + 1] = "ServerCCUpdates: " .. tostring(entities) end
    end
    return snapshot
end

function Diagnostic.Encode(value) return Ext.Json.Stringify(value) end
function Diagnostic.Channel() return Ext.Net.CreateChannel(ModuleUUID, "HB_AbilityBaseReadOnlyTrace_v1") end
function Diagnostic.ProbeChannel() return Ext.Net.CreateChannel(ModuleUUID, "HB_AbilityBaseServerProbe_v1") end
return Diagnostic
