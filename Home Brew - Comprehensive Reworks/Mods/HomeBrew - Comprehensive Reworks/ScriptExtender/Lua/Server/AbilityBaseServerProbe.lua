


local Diagnostic = Ext.Require("Shared/AbilityBaseDiagnostics.lua")
local channel = Diagnostic.ProbeChannel()
local REPORT = "HomeBrew/Diagnostics/HB_AbilityBase_ServerProbe.txt"
local pending, dirty = {}, true
local lines = { "HB ability server round-trip v0.6: full positive integer network IDs; temporary, automatically restored; not the completed allocator." }
local costs = { [0] = 0, 1, 2, 3, 4, 5, 7, 9 }

local function Log(message)
    lines[#lines + 1] = message
    if #lines > 120 then table.remove(lines, 2) end
    dirty = true
    Ext.Utils.Print("[HB Ability Base Probe] " .. message)
end

local function Integer(value, minimum, maximum)
    return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

local function Component(entity, name)
    if not entity then return nil end
    return entity:GetComponent(name)
end

local function Copy(values)
    local result = {}
    for index = 1, 7 do result[index] = values[index] end
    return result
end

local function Same(a, b)
    for index = 1, 7 do if a[index] ~= b[index] then return false end end
    return true
end

local function Reply(user, data)
    Log("user=" .. tostring(user) .. "; " .. Diagnostic.Encode(data))
    local ok, error = pcall(channel.SendToClient, channel, data, user)
    if not ok then Log("Reply failed: " .. tostring(error)) end
end

local function Target(test)
    local entity = Ext.Entity.Get(test.NetId)
    if not entity then return nil end
    local definition = Component(entity, "CCCharacterDefinition")
    local common = Component(entity, "CCDefinitionCommon")
    if not definition or not common then return nil end
    return entity, definition, common
end

local function Propagate(entity, common)
    
    
    common.ChangeId = common.ChangeId + 1
    entity:MarkChanged("CCCharacterDefinition")
    entity:MarkChanged("CCDefinitionCommon")
    entity:Replicate("CCCharacterDefinition")
    entity:Replicate("CCDefinitionCommon")
end

local function Restore(test)
    local entity, definition, common = Target(test)
    if not entity then return "definition no longer exists" end
    local values, slot = definition.Definition.Abilities, test.Index + 1
    if values[slot] == test.Before[slot] then return "already restored" end
    
    
    if values[slot] ~= test.Expected[slot] then return "native change preserved" end
    values[slot] = test.Before[slot]
    Propagate(entity, common)
    return "original selected score restored; other scores preserved"
end

local function Finish(user, test, success, reason)
    pending[user] = nil
    local ok, restored = pcall(Restore, test)
    Reply(user, { Kind = "Result", Request = test.Request, Success = success,
        Status = reason, Restore = ok and restored or "RESTORE ERROR: " .. tostring(restored) })
end

local function Stage(user, test, name, offset)
    local entity, definition, common = Target(test)
    if not entity then Finish(user, test, false, "Character creation closed."); return end
    if not Same(definition.Definition.Abilities, test.Expected) then
        Finish(user, test, false, "Native allocation changed during the test; the test stopped."); return
    end
    test.Stage, test.Sequence = name, test.Sequence + 1
    test.Expected = Copy(test.Before)
    test.Expected[test.Index + 1] = offset
    definition.Definition.Abilities[test.Index + 1] = offset
    Propagate(entity, common)
    test.Deadline = Ext.Timer.MonotonicTime() + 2000
    Reply(user, { Kind = "Phase", Request = test.Request, Sequence = test.Sequence,
        Stage = name, NetId = test.NetId, Index = test.Index, Revision = common.ChangeId,
        Abilities = Copy(test.Expected), Base = 8 + offset,
        Used = test.Used + offset, Unused = test.Unused - offset, Total = test.Total })
end

local function Reject(user, request, reason)
    Reply(user, { Kind = "Result", Request = request, Success = false, Status = reason, Restore = "no score was written" })
end

local function Start(message, user)
    if pending[user] or next(pending) then Reject(user, message.Request, "Another score test is still running."); return end
    
    
    if not Integer(message.NetId, 1, 0x7fffffffffffffff) then
        Reject(user, message.Request, "Avatar network ID is missing or invalid."); return
    end
    if not Integer(message.Index, 1, 6)
        or not Integer(message.Revision, 0, 0x7ffffffe) or type(message.Abilities) ~= "table"
        or not Integer(message.Used, 0, 27) or not Integer(message.Unused, 1, 27)
        or message.Total ~= 27 or message.Used + message.Unused ~= 27 then
        Reject(user, message.Request, "Invalid or unavailable native allocation information."); return
    end
    local total = 0
    for index = 1, 7 do
        if not Integer(message.Abilities[index], 0, 7) then Reject(user, message.Request, "Native scores are outside this test's range."); return end
        if index > 1 then total = total + costs[message.Abilities[index]] end
    end
    if total ~= message.Used or message.Abilities[1] ~= 0 or message.Abilities[message.Index + 1] ~= 0 then
        Reject(user, message.Request, "Set the selected ability to 8 and leave at least one point unspent first."); return
    end
    local test = { Request = message.Request, Index = message.Index, NetId = message.NetId,
        Before = Copy(message.Abilities), Expected = Copy(message.Abilities), Sequence = 0,
        Used = message.Used, Unused = message.Unused, Total = message.Total }
    local entity, definition, common = Target(test)
    
    
    local definitions = Ext.Entity.GetAllEntitiesWithComponent("CCCharacterDefinition")
    local sessions = Ext.Entity.GetAllEntitiesWithComponent("CCCreation")
    if not entity or #definitions ~= 1 or #sessions ~= 1 or tostring(definitions[1]) ~= tostring(entity) then
        Reject(user, message.Request, "This first server test requires one active character-creation avatar."); return
    end
    local creation = Component(sessions[1], "CCCreation")
    if not creation or tostring(creation.CharacterDefinitions[1]) ~= tostring(entity) then
        Reject(user, message.Request, "The selected definition is not the active creation avatar."); return
    end
    if common.ChangeId ~= message.Revision or not Same(definition.Definition.Abilities, test.Before) then
        Reject(user, message.Request, "Native allocation is still syncing. Wait briefly, then choose 7 again."); return
    end
    pending[user] = test
    Stage(user, test, "Legal9", 1)
end

channel:SetHandler(function(message, user)
    if type(message) ~= "table" or type(user) ~= "number" or not Integer(message.Request, 1, 0x7fffffff) then return end
    local test = pending[user]
    if message.Kind == "Start" then
        local ok, error = pcall(Start, message, user)
        if not ok then
            test = pending[user]
            if test then Finish(user, test, false, "Server test error: " .. tostring(error))
            else Reject(user, message.Request, "Server test error: " .. tostring(error)) end
        end
    elseif test and test.Request == message.Request then
        if message.Kind == "Cancel" then
            Finish(user, test, false, "Test canceled; original value restored where still owned by the test.")
        elseif message.Kind == "Ack" and message.Sequence == test.Sequence then
            local ok, error = pcall(function()
                Log("Native UI acknowledged " .. test.Stage .. "; request=" .. test.Request)
                if test.Stage == "Legal9" then Stage(user, test, "Restore9", 0)
                elseif test.Stage == "Restore9" then Stage(user, test, "Below7", -1)
                elseif test.Stage == "Below7" then Stage(user, test, "Restore7", 0)
                elseif test.Stage == "Restore7" then
                    Finish(user, test, true, "Native UI accepted 7 and refunded one point; original value restored. Persistence is not implemented yet.")
                elseif test.Stage == "FailedRestore" then
                    Finish(user, test, false, test.Failure .. " Original value restored in the native UI.")
                end
            end)
            if not ok and pending[user] then Finish(user, test, false, "Server test error: " .. tostring(error)) end
        end
    end
end)

Ext.Events.Tick:Subscribe(function()
    local now = Ext.Timer.MonotonicTime()
    for user, test in pairs(pending) do
        local ok, error = pcall(function()
            local entity, definition = Target(test)
            if not entity then Finish(user, test, false, "Character creation closed.")
            elseif not Same(definition.Definition.Abilities, test.Expected) then
                Finish(user, test, false, "Native allocation changed during the test; the test stopped.")
            elseif now >= test.Deadline then
                if test.Stage == "FailedRestore" then
                    Finish(user, test, false, test.Failure .. " Server restored the source; native UI restoration was not confirmed.")
                else
                    test.Failure = test.Stage == "Legal9"
                        and "Legal 8->9 did not update the native score/counter/cache. No below-8 write was attempted."
                        or "Native score/counter/cache did not acknowledge stage " .. test.Stage .. "."
                    Stage(user, test, "FailedRestore", 0)
                end
            end
        end)
        if not ok and pending[user] then Finish(user, test, false, "Server test error: " .. tostring(error)) end
    end
    if dirty then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(lines, "\n") .. "\n")
        if not ok or result == false then Ext.Utils.Print("[HB Ability Base Probe] Could not save server test report.") end
    end
end)
Log("Choose 7 on a native score of 8 to run the temporary server round-trip test.")
