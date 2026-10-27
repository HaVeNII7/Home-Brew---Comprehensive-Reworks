
local Diagnostic = Ext.Require("Shared/AbilityBaseDiagnostics.lua")
local channel = Diagnostic.Channel()
local REPORT = "HomeBrew/Diagnostics/HB_AbilityBase_Server_Diagnostics.txt"
local watches, lastPoll, dirty = {}, -100, true
local lines = { "HB shared ability dropdown v0.1: SERVER READ-ONLY TRACE; no score, save or budget writes." }

local function Log(message)
    lines[#lines + 1] = message
    if #lines > 180 then table.remove(lines, 2) end
    dirty = true
end

local function Capture(user, watch, reason)
    local ok, snapshot = pcall(Diagnostic.Snapshot)
    if not ok then snapshot = { Errors = { tostring(snapshot) } } end
    local signature = Diagnostic.Encode(snapshot)
    if reason or signature ~= watch.last then
        watch.last = signature
        local message = { Kind = "Snapshot", Request = watch.request, Reason = reason or "server change",
            Time = Ext.Timer.MonotonicTime(), Snapshot = snapshot }
        Log("user=" .. tostring(user) .. "; " .. Diagnostic.Encode(message))
        channel:SendToClient(message, user)
    end
end

channel:SetHandler(function(message, user)
    if type(message) ~= "table" or message.Kind ~= "Capture" or type(user) ~= "number" then return end
    local now = Ext.Timer.MonotonicTime()
    if type(message.Request) ~= "number" or message.Request % 1 ~= 0 then return end
    local watch = watches[user] or {}
    watch.request, watch.untilTime = message.Request, now + 12000
    watches[user] = watch
    
    local reason = type(message.Reason) == "string" and message.Reason:sub(1, 180) or "capture"
    Capture(user, watch, reason)
end)



local eventSnapshots = {}
local hookWarnings = {}
if Ext.Entity.Subscribe then
    for _, component in ipairs({ "CCCharacterDefinition", "CCRespecDefinition", "CCFullRespecDefinition", "CCDefinitionCommon", "ServerCCUpdates" }) do
        local name = component
        local ok, result = pcall(Ext.Entity.Subscribe, name, function()
            if next(watches) == nil then return end
            local read, snapshot = pcall(Diagnostic.Snapshot)
            if read then
                eventSnapshots[#eventSnapshots + 1] = { Reason = "component notification: " .. name, Snapshot = snapshot }
                if #eventSnapshots > 16 then table.remove(eventSnapshots, 1) end
            end
        end)
        if not ok then hookWarnings[#hookWarnings + 1] = name .. ": " .. tostring(result) end
    end
end
for _, warning in ipairs(hookWarnings) do Log("Optional notification hook unavailable: " .. warning) end

Ext.Events.Tick:Subscribe(function()
    local now = Ext.Timer.MonotonicTime()
    if now - lastPoll >= 100 then
        lastPoll = now
        for user, watch in pairs(watches) do
            if now >= watch.untilTime then
                channel:SendToClient({ Kind = "Done", Request = watch.request }, user)
                watches[user] = nil
            else
                for _, event in ipairs(eventSnapshots) do
                    local signature = Diagnostic.Encode(event.Snapshot)
                    if signature ~= watch.last then
                        watch.last = signature
                        local reply = { Kind = "Snapshot", Request = watch.request, Reason = event.Reason,
                            Time = now, Snapshot = event.Snapshot }
                        Log("user=" .. tostring(user) .. "; " .. Diagnostic.Encode(reply))
                        channel:SendToClient(reply, user)
                    end
                end
                Capture(user, watch)
            end
        end
        eventSnapshots = {}
    end
    if dirty then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(lines, "\n") .. "\n")
        if not ok or result == false then Ext.Utils.Print("[HB Ability Base] Could not save server report.") end
    end
end)
Ext.Utils.Print("[HB Ability Base] Server read-only trace loaded.")


Ext.Require("Server/AbilityBaseServerProbe.lua")
