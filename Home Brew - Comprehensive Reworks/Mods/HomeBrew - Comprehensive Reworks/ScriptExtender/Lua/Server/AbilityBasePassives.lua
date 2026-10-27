


local Base = Ext.Require("Shared/AbilityBasePassives.lua")
local channel, sessions = Base.Channel(), {}
local REPORT = "HomeBrew/Diagnostics/HB_AbilityBase_ServerPassives.txt"
local reports, dirty, lastPoll = { "HB ability baseline passives v0.16: scaled costs; maximum base value 20." }, true, -250
local LEDGER = "AbilityBasePending_v1"
local SINGLE_SAVE_RULE = "IRONMAN_MODE_338450d9-d77d-4950-9e1e-0e7f12210bb3"
local function SingleSaveActive()
    if Osi then
        for _, method in ipairs({ "GetRulesetModifierBool", "CheckRulesetModifierBool" }) do
            local fn = Osi[method]
            if fn then
                local ok, result
                if method == "CheckRulesetModifierBool" then
                    ok, result = pcall(fn, SINGLE_SAVE_RULE, 1)
                else
                    ok, result = pcall(fn, SINGLE_SAVE_RULE)
                end
                if ok and (result == true or tonumber(result) == 1) then return true end
                if ok and (result == false or tonumber(result) == 0) then return false end
            end
        end
    end
    return nil
end
Ext.Vars.RegisterModVariable(ModuleUUID, LEDGER, {
    Server = true, Client = false, Persistent = true, WriteableOnServer = true,
})

local function Remember(session, remove)
    
    if session.Scope ~= "Creation" then return end
    local vars = Ext.Vars.GetModVariables(ModuleUUID)
    local ledger = vars[LEDGER] or {}
    local nextLedger = {}
    for key, value in pairs(ledger) do nextLedger[key] = value end
    nextLedger[tostring(session.User)] = not remove and {
        Source = session.Source, Scope = session.Scope, User = session.User,
        Choices = Base.Choices(session.Choices), Touched = session.Touched,
        Actor = session.Actor, Before = session.Before, Phase = session.Phase,
    } or nil
    vars[LEDGER] = nextLedger
end

local function Log(message)
    reports[#reports + 1] = message
    if #reports > 160 then table.remove(reports, 2) end
    dirty = true
    Ext.Utils.Print("[HB Ability Passives] " .. message)
end

local function Component(entity, name)
    if not entity then return nil end
    return entity:GetComponent(name)
end

local function UUID(entity)
    local component = Component(entity, "Uuid")
    return component and tostring(component.EntityUuid) or nil
end

local function User(value)
    return type(value) == "number" and value - value % 0x10000 + 1 or nil
end

local function Owned(entity, user)
    local uuid = UUID(entity)
    if not uuid or not Component(entity, "ServerCharacter") then return false end
    local avatar, reserved = Component(entity, "UserAvatar"), Component(entity, "UserReservedFor")
    if avatar and User(avatar.UserID) == User(user) or reserved and User(reserved.UserID) == User(user) then return true end
    local ok, owner = pcall(Osi.GetReservedUserID, uuid)
    if ok and owner ~= 0 and User(owner) == User(user) then return true end
    for _, party in ipairs(Ext.Entity.GetAllEntitiesWithComponent("PartyView")) do
        for _, view in pairs(party.PartyView.Views) do
            if User(view.UserID) == User(user) then
                for _, character in pairs(view.Characters) do if UUID(character) == uuid then return true end end
            end
        end
    end
    return false
end

local function Avatar(user)
    local match, count = nil, 0
    for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent("UserAvatar")) do
        if Owned(entity, user) then match, count = entity, count + 1 end
    end
    if count == 1 then return match end
    return nil
end

local function Choices(entity)
    return Base.Choices(entity and entity.Vars[Base.Variable])
end

local function OwnPassives(uuid)
    local result = {}
    for index = 1, 6 do
        for value = Base.Minimum, Base.Maximum do
            local id = Base.Passive(index, value)
            if Osi.HasPassive(uuid, id) == 1 then result[id] = true end
        end
    end
    return result
end

local function Restore(uuid, before)
    if not Ext.Entity.Get(uuid) then return end
    local current = OwnPassives(uuid)
    for id in pairs(current) do if not before[id] then Osi.RemovePassive(uuid, id) end end
    for id in pairs(before) do if not current[id] then Osi.AddPassive(uuid, id) end end
end

local function Apply(uuid, choices, touched)
    if Base.Available(choices) < 0 then error("Ability increases require matching reductions.") end
    local before, wanted = OwnPassives(uuid), {}
    for index = 1, 6 do
        local any = false
        for value = Base.Minimum, Base.Maximum do if before[Base.Passive(index, value)] then any = true end end
        
        
        if choices[index] ~= 8 or touched[index] or any then
            local id = Base.Passive(index, choices[index])
            if not Ext.Stats.Get(id) then error("Passive definition missing: " .. id .. ". Install HB_AbilityBase_Passives.txt under Public/<HB folder>/Stats/Generated/Data.") end
            wanted[id] = true
        end
    end
    local ok, error = pcall(function()
        for id in pairs(before) do if not wanted[id] then Osi.RemovePassive(uuid, id) end end
        for id in pairs(wanted) do if not before[id] then Osi.AddPassive(uuid, id) end end
    end)
    if not ok then pcall(Restore, uuid, before); return nil, tostring(error) end
    return wanted
end

local function Confirm(uuid, wanted)
    local actual = OwnPassives(uuid)
    for id in pairs(wanted) do if not actual[id] then return false end end
    for id in pairs(actual) do if not wanted[id] then return false end end
    return true
end

local function Reply(user, session, request, status, detail, success)
    local message = { Kind = "Result", Source = session.Source, Request = request,
        Choices = Base.Choices(session.Choices), Status = status, Detail = detail,
        Success = success ~= false, Actor = session.Actor,
        Locked = SingleSaveActive() ~= false }
    Log("user=" .. tostring(user) .. "; " .. Ext.Json.Stringify(message))
    local ok, error = pcall(channel.SendToClient, channel, message, user)
    if not ok then Log("Reply unavailable: " .. tostring(error)) end
end

local function Preview(session, message)
    if session.Scope == "Respec" then return Ext.Entity.Get(session.Actor) end
    
    
    if Base.Integer(message.Preview, 1, 0x7fffffffffffffff) then
        local entity = Ext.Entity.Get(message.Preview)
        local character = Component(entity, "ServerCharacter")
        if character and character.CharCreationInProgress and Owned(entity, session.User) then return entity end
    end
    local entity = Avatar(session.User)
    local character = Component(entity, "ServerCharacter")
    if character and character.CharCreationInProgress then return entity end
    return nil
end

local function Context(message, user)
    local existing = sessions[message.Source]
    if existing then
        if existing.User ~= user or existing.Scope ~= message.Scope then error("Creation session belongs to another player.") end
        if not Ext.Entity.Get(message.Source) then error("That creation page has closed.") end
        return existing
    end
    local entity = Ext.Entity.Get(message.Source)
    if not entity then error("Active creation definition is unavailable.") end
    local session = { Source = message.Source, Scope = message.Scope, User = user, Touched = {} }
    if message.Scope == "Creation" then
        local definitions = Ext.Entity.GetAllEntitiesWithComponent("CCCharacterDefinition")
        local roots = Ext.Entity.GetAllEntitiesWithComponent("CCCreation")
        if not Component(entity, "CCCharacterDefinition") or #definitions ~= 1 or #roots ~= 1
            or tostring(definitions[1]) ~= tostring(entity)
            or tostring(roots[1].CCCreation.CharacterDefinitions[1]) ~= tostring(entity) then
            error("Could not identify one active creation avatar; no guardian or other character was changed.")
        end
    elseif message.Scope == "Respec" then
        local actor
        for _, name in ipairs({ "CCRespec", "CCFullRespec" }) do
            for _, root in ipairs(Ext.Entity.GetAllEntitiesWithComponent(name)) do
                local link = root:GetComponent(name)
                if tostring(link.Respec) == tostring(entity) then
                    if actor and tostring(actor) ~= tostring(link.Character) then error("Ambiguous respec character.") end
                    actor = link.Character
                end
            end
        end
        if not actor or not Owned(actor, user) then error("Respec character could not be verified for this player.") end
        session.Actor = UUID(actor)
    else error("Unknown creation page.") end
    local preview = Preview(session, message)
    session.Choices = Choices(preview)
    if preview then
        session.Actor, session.Before = UUID(preview), OwnPassives(UUID(preview))
    end
    sessions[message.Source] = session
    return session
end

local function Cancel(source, session)
    
    
    if session.Pending then session.CancelRequested = true; return end
    if session.Actor and session.Before then pcall(Restore, session.Actor, session.Before) end
    Remember(session, true)
    sessions[source] = nil
    Log("Discarded uncommitted " .. session.Scope .. " choices; source=" .. source)
end

channel:SetHandler(function(message, user)
    if type(message) ~= "table" or type(user) ~= "number" or not Base.Integer(message.Source, 1, 0x7fffffffffffffff)
        or not Base.Integer(message.Request, 1, 0x7fffffff) then return end
    if message.Kind == "Close" then
        local session = sessions[message.Source]
        if session and session.User == user and session.Phase ~= "Commit" then
            session.CloseAt = Ext.Timer.MonotonicTime() + 1500
        end
        return
    end
    if message.Kind ~= "Get" and message.Kind ~= "Set" then return end
    local session
    local ok, error = pcall(function()
        session = Context(message, user)
        if session.Phase == "Commit" then error("Character creation is finishing.") end
        if session.CancelRequested then error("That creation session was cancelled.") end
        session.CloseAt = nil
        local singleSave = SingleSaveActive()
        if singleSave ~= false then
            local reason = singleSave == true
                and "Custom ability scores are disabled in Single Save / Honour Mode."
                or "Single Save status could not be verified; custom ability scores remain disabled."
            if message.Kind == "Get" then
                Reply(user, session, message.Request, "Locked", reason); return
            end
            error(reason)
        end
        if message.Kind == "Get" then
            Reply(user, session, message.Request, "Ready", "Select a baseline to apply its hidden ability passive."); return
        end
        if not Base.Integer(message.Index, 1, 6) or not Base.Integer(message.Value, Base.Minimum, Base.Maximum) then error("Invalid ability or base value.") end
        
        
        if not Base.CanChoose(session.Choices, message.Index, message.Value) then
            error("Lower another base value first to free points for this change.")
        end
        local id = Base.Passive(message.Index, message.Value)
        if not Ext.Stats.Get(id) then error("Passive definition missing: " .. id .. ". Check HB_AbilityBase_Passives.txt.") end
        session.Choices[message.Index], session.Touched[message.Index] = message.Value, true
        session.Request = message.Request
        local preview = Preview(session, message)
        if preview then
            local uuid = UUID(preview)
            if not session.Before then session.Before = OwnPassives(uuid) end
            session.Actor = uuid
            
            
            session.PreviewDirty = true
            Reply(user, session, message.Request, "Applying", "Applying " .. id .. " to the server character.")
        else
            Reply(user, session, message.Request, "Queued", id .. " selected. The creation preview is client-local; the passive will be applied when character creation finishes.")
        end
        Remember(session)
    end)
    if not ok then
        local result = session or { Source = message.Source, Choices = { 8, 8, 8, 8, 8, 8 } }
        Reply(user, result, message.Request, "Error", tostring(error), false)
    end
end)

local function StartCommit(session)
    session.Phase, session.CloseAt = "Commit", nil
    session.Deadline = Ext.Timer.MonotonicTime() + 120000
    Remember(session)
end

Ext.Osiris.RegisterListener("CharacterCreationFinished", 0, "after", function()
    for _, session in pairs(sessions) do if session.Scope == "Creation" then StartCommit(session) end end
    Log("CharacterCreationFinished: committing selected ability passives.")
end)

Ext.Osiris.RegisterListener("RespecCompleted", 1, "after", function(character)
    local uuid = tostring(character):sub(-36)
    local found = false
    for _, session in pairs(sessions) do
        if session.Scope == "Respec" and session.Actor == uuid then StartCommit(session); found = true end
    end
    if not found then
        local entity = Ext.Entity.Get(uuid)
        if entity and entity.Vars[Base.Variable] then
            local choices, adjusted = Choices(entity)
            local ok, wanted, failure = pcall(Apply, uuid, choices, {})
            if not ok or not wanted then Log("Respec restore error: " .. tostring(failure or wanted))
            elseif adjusted then entity.Vars[Base.Variable] = choices end
        end
    end
end)

Ext.Osiris.RegisterListener("RespecCancelled", 1, "after", function(character)
    local uuid = tostring(character):sub(-36)
    for source, session in pairs(sessions) do
        if session.Scope == "Respec" and session.Actor == uuid then Cancel(source, session) end
    end
end)

Ext.Events.SessionLoaded:Subscribe(function()
    local ledger = Ext.Vars.GetModVariables(ModuleUUID)[LEDGER] or {}
    for _, saved in pairs(ledger) do
        local avatar = Avatar(saved.User)
        local character = Component(avatar, "ServerCharacter")
        local finished = character and character.CharacterCreationFinished and not character.CharCreationInProgress
            and #Ext.Entity.GetAllEntitiesWithComponent("CCCreation") == 0
            and #Ext.Entity.GetAllEntitiesWithComponent("CCCharacterDefinition") == 0
        if (saved.Phase == "Commit" or finished) and not sessions[saved.Source] then
            saved.Choices, saved.Touched = Base.Choices(saved.Choices), saved.Touched or {}
            sessions[saved.Source] = saved
            StartCommit(saved)
        end
    end
    for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")) do
        local uuid = UUID(entity)
        if uuid and entity.Vars[Base.Variable] then
            local choices, adjusted = Choices(entity)
            local ok, wanted, failure = pcall(Apply, uuid, choices, {})
            if not ok or not wanted then Log("Saved passive restore error: " .. tostring(failure or wanted))
            elseif adjusted then
                entity.Vars[Base.Variable] = choices
                Log("Saved transfer adjusted to the scaled cost budget: " .. uuid .. "; " .. Ext.Json.Stringify(choices))
            end
        end
    end
end)

Ext.Events.Tick:Subscribe(function()
    local now = Ext.Timer.MonotonicTime()
    if now - lastPoll >= 250 then
        lastPoll = now
        for source, session in pairs(sessions) do
            local ok, error = pcall(function()
                if session.Pending then
                    if Confirm(session.Actor, session.Pending.Wanted) then
                        if not session.PreviewDirty and not session.CancelRequested and session.Phase ~= "Commit" then
                            Reply(session.User, session, session.Pending.Request, "Applied", "Selected ability passive applied. Changes will be saved when creation/respec completes.")
                        end
                        session.Pending = nil
                    elseif now > session.Pending.Deadline then
                        session.Pending = nil
                        Reply(session.User, session, session.Request or 1, "Error", "Passive application was not confirmed; original baseline choices are being restored.", false)
                        Cancel(source, session)
                        return
                    else return end
                end
                if session.CancelRequested then Cancel(source, session); return end
                if session.Phase == "Commit" then
                    local entity
                    if session.Scope == "Creation" then entity = Avatar(session.User)
                    else entity = session.Actor and Ext.Entity.Get(session.Actor) end
                    local character = Component(entity, "ServerCharacter")
                    if entity and Owned(entity, session.User) and character and not character.CharCreationInProgress then
                        local uuid = UUID(entity)
                        if session.Actor and session.Actor ~= uuid and session.Before then
                            Restore(session.Actor, session.Before)
                            session.Before = nil
                        end
                        if not session.CommitWanted then
                            local wanted, failure = Apply(uuid, session.Choices, session.Touched)
                            if not wanted then error(failure) end
                            session.Actor, session.CommitWanted = uuid, wanted
                        end
                        if Confirm(uuid, session.CommitWanted) then
                            entity.Vars[Base.Variable] = Base.Choices(session.Choices)
                            Reply(session.User, session, session.Request or 1, "Saved", "Ability passives applied and baseline choices saved.")
                            Remember(session, true)
                            sessions[source] = nil
                        end
                    end
                    if sessions[source] and now > session.Deadline then
                        Reply(session.User, session, session.Request or 1, "Error", "Could not confirm the created character's passives; see the server passive report.", false)
                        Cancel(source, session)
                    end
                elseif session.CloseAt and now >= session.CloseAt then Cancel(source, session)
                elseif not Ext.Entity.Get(source) then
                    
                    session.CloseAt = session.CloseAt or now + 1500
                elseif session.PreviewDirty then
                    local entity = session.Actor and Ext.Entity.Get(session.Actor)
                    if not entity or not Owned(entity, session.User) then error("Preview character is unavailable for this player.") end
                    local wanted, failure = Apply(session.Actor, session.Choices, session.Touched)
                    if not wanted then error(failure) end
                    session.Pending = { Wanted = wanted, Deadline = now + 3000, Request = session.Request }
                    session.PreviewDirty = false
                end
            end)
            if not ok then
                Reply(session.User, session, session.Request or 1, "Error", tostring(error), false)
                Cancel(source, session)
            end
        end
    end
    if dirty then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(reports, "\n") .. "\n")
        if not ok or result == false then Ext.Utils.Print("[HB Ability Passives] Could not save server report.") end
    end
end)
Log("Passive backend loaded; native score-write probes are disabled by the new loader.")
