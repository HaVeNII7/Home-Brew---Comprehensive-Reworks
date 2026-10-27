


local REPORT = "HomeBrew/Diagnostics/HB_AbilityAllocator_Diagnostics.txt"
local PAGE_NAMES = {
    CharacterCreation = true, CharacterCreation_c = true,
    CharacterRespec = true, CharacterRespec_c = true,
}
local COMMAND_NAMES = {
    IncreaseAbility = true, DecreaseAbility = true, ResetAbilities = true,
    UseRecommendedAbilities = true, SelectAbility = true, DeselectAbility = true,
}
local lines = {
    "HB Ability Allocator Probe v3",
    "Requested rule: base minimum 6; 8->7 refunds 1; 7->6 refunds 1.",
    "This probe does not change ability scores, commands, or point totals.",
}
local dirty, stopped, queued = true, false, false
local lastPoll = -1000
local capturedPages, capturedRows, capturedCounts, metadata = {}, {}, {}, {}
local capturedBackend = false

local function Log(text)
    lines[#lines + 1] = text
    dirty = true
end

local function Properties(object)
    if object == nil then return {} end
    local kind = type(object)
    if kind ~= "table" and kind ~= "userdata" then return {} end
    local name = object.Type
    if name == nil then return {} end
    if metadata[name] then return metadata[name] end
    local fields, info = {}, object:TypeInfo()
    while info do
        for _, property in ipairs(info.Properties or {}) do
            if not fields[property.Name] then
                fields[property.Name] = {
                    readOnly = property.IsReadOnly,
                }
            end
        end
        for _, property in ipairs(info.DependencyProperties or {}) do
            if not fields[property.Name] then
                fields[property.Name] = { readOnly = property.IsReadOnly }
            end
        end
        info = info.Base
    end
    metadata[name] = fields
    return fields
end

local function Read(object, field)
    if object and Properties(object)[field] then return object[field] end
end

local function Dump(label, object)
    if not object then Log(label .. ": unavailable"); return end
    Log(label .. " type=" .. tostring(object.Type))
    local fields, names = Properties(object), {}
    for name in pairs(fields) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local field = fields[name]
        local line = "  " .. name .. " [readOnly=" .. tostring(field.readOnly) .. "]"
        
        local lower = name:lower()
        if not COMMAND_NAMES[name] and not lower:find("command", 1, true) and (
            lower:find("ability", 1, true) or lower:find("point", 1, true)
            or lower:find("cost", 1, true) or lower:find("minimum", 1, true)
            or lower:find("maximum", 1, true) or lower:find("base", 1, true)
            or name == "CanDecrease" or name == "CanIncrease"
            or name == "Value" or name == "RaceBonus" or name == "Name"
            or name == "Min" or name == "Max") then
            local ok, value = pcall(function() return object[name] end)
            if not ok then
                line = line .. " <getter unavailable>"
            elseif type(value) ~= "table" and type(value) ~= "userdata" then
                line = line .. " = " .. tostring(value)
            else
                line = line .. " = <model/collection>"
            end
        end
        Log(line)
    end
end

local function DescribeDefinition(label, object)
    local fields = {}
    for name, value in pairs(object) do
        if name == "Abilities" then
            local values = {}
            for index, score in ipairs(value) do
                values[#values + 1] = tostring(index) .. "=" .. tostring(score)
            end
            Log(label .. ".Abilities: " .. table.concat(values, ", "))
        elseif name == "Definition" then
            
            
            for field, item in pairs(value) do
                if field == "Abilities" then
                    local values = {}
                    for index, score in ipairs(item) do
                        values[#values + 1] = tostring(index) .. "=" .. tostring(score)
                    end
                    Log(label .. ".Definition.Abilities: " .. table.concat(values, ", "))
                end
            end
            fields[#fields + 1] = name .. "=<definition>"
        elseif name == "ChangeId" or name == "Version" or name == "Synced"
            or name == "NeedsSync" or name == "Character" or name == "Entity" then
            fields[#fields + 1] = tostring(name) .. "=" .. tostring(value)
        end
    end
    table.sort(fields)
    Log(label .. " state: " .. table.concat(fields, ", "))
end

local function InspectBackend()
    if capturedBackend then return end
    capturedBackend = true
    Log("Backend inspection (client; read-only)")
    local ok, message = pcall(function()
        local extra = Ext.Stats and Ext.Stats.ExtraData or Ext.ExtraData
        if not extra then Log("ExtraData unavailable"); return end
        local matches = {}
        for name, value in pairs(extra) do
            local lower = tostring(name):lower()
            if lower:find("ability", 1, true) or lower:find("attribute", 1, true)
                or lower:find("pointbuy", 1, true) or lower:find("point_buy", 1, true)
                or lower:find("creation", 1, true) then
                matches[#matches + 1] = tostring(name) .. "=" .. tostring(value)
            end
        end
        table.sort(matches)
        Log("Relevant ExtraData entries: " .. #matches)
        for _, entry in ipairs(matches) do Log("  " .. entry) end
    end)
    if not ok then Log("ExtraData enumeration unavailable: " .. tostring(message)) end

    if not Ext.Entity or not Ext.Entity.GetAllEntitiesWithComponent then
        Log("Entity enumeration API unavailable"); return
    end
    for _, name in ipairs({
        "ClientCCBaseDefinitionState", "CCCharacterDefinition",
        "CCRespecDefinition", "CCFullRespecDefinition", "ClientCCDefinitionState",
    }) do
        local available, errorMessage = pcall(function()
            local entities = Ext.Entity.GetAllEntitiesWithComponent(name)
            Log(name .. " entities=" .. #entities)
            for index = 1, math.min(6, #entities) do
                local entity = entities[index]
                local component = entity:GetComponent(name)
                if component then
                    DescribeDefinition(name .. "[" .. index .. "] " .. tostring(entity), component)
                end
            end
        end)
        if not available then Log(name .. " inspection unavailable: " .. tostring(errorMessage)) end
    end
end

local function InspectPage(widget, pageName)
    local dc = Read(widget, "DataContext")
    if not dc then return end
    if not capturedPages[pageName] then
        capturedPages[pageName] = true
        Dump(pageName .. " root", dc)
    end
    InspectBackend()
    if (capturedCounts[pageName] or 0) >= 6 then return end
    local remaining = 2500
    local function Walk(node, depth)
        if not node or depth > 70 or remaining <= 0 then return end
        remaining = remaining - 1
        local context = Read(node, "DataContext")
        local fields = Properties(context)
        if fields.CanDecrease and fields.CanIncrease and fields.Ability then
            local ability = Read(context, "Ability")
            local key = pageName .. ":" .. tostring(ability)
            if not capturedRows[key] then
                capturedRows[key] = true
                capturedCounts[pageName] = (capturedCounts[pageName] or 0) + 1
                Dump(key .. " row", context)
                Ext.Utils.Print("[HB Ability Probe] Captured " .. key)
            end
        end
        for index = 1, node.VisualChildrenCount do
            Walk(node:VisualChild(index), depth + 1)
        end
    end
    Walk(widget, 0)
end

local function Inspect()
    local root = Ext.UI.GetRoot()
    if not root then return end
    local content = root:Find("ContentRoot")
    if not content then return end
    for index = 1, content.ChildrenCount do
        local widget = content:Child(index)
        if widget then
            local name = Read(widget, "Name")
            if widget.Type:match("UIWidget$") then
                local filename = Read(widget, "FileName")
                if type(filename) == "string" then
                    local fromFile = filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
                    if PAGE_NAMES[fromFile] then name = fromFile end
                end
            end
            if PAGE_NAMES[name] then InspectPage(widget, name) end
        end
    end
end

if not Ext.UI or not Ext.UI.GetRoot then
    Ext.Utils.Print("[HB Ability Probe] UI API unavailable; SE 32 is required.")
    return
end

Ext.Events.Tick:Subscribe(function()
    if dirty and Ext.IO and Ext.IO.SaveFile then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(lines, "\n") .. "\n")
        if not ok or result == false then
            Ext.Utils.Print("[HB Ability Probe] Could not save " .. REPORT)
        end
    end
    if stopped or queued then return end
    local now = Ext.Timer.MonotonicTime()
    if now - lastPoll < 1000 then return end
    lastPoll = now
    local function Run()
        queued = false
        local ok, message = pcall(Inspect)
        if not ok then
            stopped = true
            Log("Inspection stopped: " .. tostring(message))
            Ext.Utils.Print("[HB Ability Probe] Inspection stopped; send " .. REPORT)
        end
    end
    if Ext.UI.Defer then queued = true; Ext.UI.Defer(Run) else Run() end
end)

Ext.Utils.Print("[HB Ability Probe] Loaded. Open the Abilities panel; report saves automatically to " .. REPORT)
