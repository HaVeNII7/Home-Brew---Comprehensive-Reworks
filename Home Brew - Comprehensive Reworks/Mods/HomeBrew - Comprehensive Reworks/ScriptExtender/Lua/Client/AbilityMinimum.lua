

local REPORT = "HomeBrew/Diagnostics/HB_AbilityBase_Diagnostics.txt"
local HOST = "HB_AbilityBaseMenu"
local NAME_TYPE, MENU_TYPE = "HB_AbilityBaseName_v2", "HB_AbilityBaseMenu_v4"
local PAGES = { CharacterCreation = true, CharacterCreation_c = true,
    CharacterRespec = true, CharacterRespec_c = true }
local Base = Ext.Require("Shared/AbilityBasePassives.lua")
local DerivedPreview = Ext.Require("Client/AbilityBasePreview.lua")
local channel = Base.Channel()
local states, metadata, jobs, requests = {}, {}, {}, {}
local active, request, lastUpdate, queued = nil, 0, -150, false
local reports = { "HB ability baseline passives v0.27: tooltip opening events and hidden text priming; native TitleValue and split Base rows; signed bonuses, formatted scores and Constitution HP; base values 1-20; scaled costs." }
local dirty, warning = true, nil
local observations = {}

local function Log(message)
    reports[#reports + 1] = message
    if #reports > 180 then table.remove(reports, 2) end
    dirty = true
    Ext.Utils.Print("[HB Ability Base] " .. message)
end

local function Read(object, name)
    if not object or (type(object) ~= "userdata" and type(object) ~= "table") or not object.Type then return nil end
    local fields = metadata[object.Type]
    if not fields then
        fields = {}
        local info = object:TypeInfo()
        while info do
            for _, property in ipairs(info.Properties or {}) do fields[property.Name] = true end
            for _, property in ipairs(info.DependencyProperties or {}) do fields[property.Name] = true end
            info = info.Base
        end
        metadata[object.Type] = fields
    end
    if fields[name] then return object[name] end
    
    
    return nil
end

local function Observe(key, message)
    if observations[key] == message then return end
    observations[key] = message
    Log(message)
end

local function Walk(node, callback, depth, budget, includeHidden)
    if not node or depth > 70 or budget.count >= 4500 then return end
    budget.count = budget.count + 1
    if not includeHidden and Read(node, "IsVisible") == false then return end
    if callback(node) == false then return end
    for index = 1, node.VisualChildrenCount do Walk(node:VisualChild(index), callback, depth + 1, budget, includeHidden) end
end

local function Index(row)
    local index = Read(row, "AbilityValue")
    if type(index) == "number" and index % 1 == 0 and index >= 1 and index <= 6
        and type(Read(row, "BaseValue")) == "number" then return index end
end

local function ScoreIndex(row)
    local index = Read(row, "AbilityValue")
    if Base.Integer(index, 1, 6) and tostring(Read(row, "Ability")) == Base.Abilities[index] then return index end
    return nil
end

local function Numeric(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local score = tonumber(value)
    if score and score % 1 == 0 then return score end
    return nil
end

local function DummySnapshot(component)
    local result = { Applied = { 0, 0, 0, 0, 0, 0 }, Scores = {} }
    if not component or not component.Dummy then return nil, result end
    local ok, netId, snapshot = pcall(function()
        local dummy = component.Dummy
        local data = { Applied = { 0, 0, 0, 0, 0, 0 }, Scores = {} }
        local stats = dummy:GetComponent("Stats")
        if stats then
            for index = 1, 6 do data.Scores[index] = stats.Abilities[index + 1] end
        end
        
        
        local healthOK, health = pcall(function()
            local level = dummy:GetComponent("EocLevel")
            local baseHP = dummy:GetComponent("BaseHp")
            local hp = dummy:GetComponent("Health")
            local details = { Level = level and level.Level,
                Base = baseHP and baseHP.Vitality, Percent = baseHP and baseHP.VitalityBoost,
                Max = hp and hp.MaxHp }
            details.Multiplier = math.max(0.01, 1 + (details.Percent or 0) / 100)
            
            
            
            local con = data.Scores[3]
            if details.Base and details.Level and details.Max and con then
                local raw = details.Base + math.floor((con - 10) / 2) * details.Level
                if raw > 0 then
                    for _, scale in ipairs({ 1, 1.5, 2, 3, 4, 5 }) do
                        if scale >= details.Multiplier and math.floor(raw * scale + 0.000001) == details.Max then
                            details.Multiplier = scale; break
                        end
                    end
                end
            end
            return details
        end)
        if healthOK then
            data.Health = health
            Observe("dummy-health", "Native HP snapshot: level=" .. tostring(health.Level)
                .. "; base=" .. tostring(health.Base) .. "; percent=" .. tostring(health.Percent)
                .. "; max=" .. tostring(health.Max) .. "; multiplier=" .. health.Multiplier)
        end
        local container = dummy:GetComponent("PassiveContainer")
        if container then
            for _, passiveEntity in pairs(container.Passives) do
                local passive = passiveEntity:GetComponent("Passive")
                if passive and not passive.Disabled then
                    local ability, value = tostring(passive.PassiveId):match("^HB_AbilityBase_(%a+)_(%d+)$")
                    value = tonumber(value)
                    if Base.Integer(value, Base.Minimum, Base.Maximum) then
                        for index = 1, 6 do
                            if ability == Base.Abilities[index] then data.Applied[index] = data.Applied[index] + value - 8 end
                        end
                    end
                end
            end
        end
        return dummy:GetNetId(), data
    end)
    if ok then return netId, snapshot end
    Observe("dummy-preview", "Dummy passive/stat snapshot unavailable; using allocation-only preview.")
    return nil, result
end

local function SnapshotUI(rows, native)
    local snapshot = { Rows = {}, Used = Read(native, "UsedAbilityPoints"),
        Unused = Read(native, "UnusedAbilityPoints"), Total = Read(native, "TotalAbilityPoints") }
    for index = 1, 6 do
        local row = rows[index]
        if not row then return end
        snapshot.Rows[index] = { Ability = Read(row, "Ability"), Base = Read(row, "BaseValue"),
            Value = tostring(Read(row, "Value")), CanDecrease = Read(row, "CanDecrease"),
            CanIncrease = Read(row, "CanIncrease") }
    end
    return snapshot
end



local function Source(page, ui)
    local scope = (page == "CharacterCreation" or page == "CharacterCreation_c") and "Creation" or "Respec"
    local names = scope == "Creation" and { "CCCharacterDefinition" } or { "CCFullRespecDefinition", "CCRespecDefinition" }
    local found, count, offsets = nil, 0, nil
    local seen = {}
    for _, name in ipairs(names) do
        for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent(name)) do
            local component, matches = entity:GetComponent(name), true
            for index = 1, 6 do
                if component.Definition.Abilities[index + 1] ~= ui.Rows[index].Base - 8 then matches = false end
            end
            if matches and not seen[tostring(entity)] then
                seen[tostring(entity)] = true
                local netId = entity:GetNetId()
                if type(netId) == "number" then
                    local descriptor = { Source = netId, Scope = scope }
                    local dummy = entity:GetComponent("ClientCCDummyDefinition")
                    local preview, adjustments = DummySnapshot(dummy)
                    descriptor.Preview = preview
                    found, count, offsets = descriptor, count + 1, adjustments
                end
            end
        end
    end
    if count == 1 then return found, offsets end
    return nil
end

local function Send(key, state, kind, index, value)
    local source = kind == "Close" and state.lastSource or state.source
    if not source then
        state.status = "The active character definition could not be resolved. No passive was applied."
        Log(state.status); return
    end
    request = request + 1
    local message = { Kind = kind, Request = request, Source = source.Source, Scope = source.Scope,
        Preview = source.Preview, Index = index, Value = value }
    requests[request], state.request, state.sentAt = key, request, Ext.Timer.MonotonicTime()
    for ticket in pairs(requests) do if ticket < request - 100 then requests[ticket] = nil end end
    state.status = "Waiting for the server..."
    Log("CLIENT PASSIVE " .. Ext.Json.Stringify(message))
    local ok, error = pcall(channel.SendToServer, channel, message)
    if not ok then state.status = "Passive backend unavailable: " .. tostring(error); Log(state.status) end
    return ok
end

channel:SetHandler(function(message)
    if type(message) ~= "table" or message.Kind ~= "Result" or type(message.Request) ~= "number" then return end
    Log("SERVER PASSIVE " .. Ext.Json.Stringify(message))
    local key = requests[message.Request]
    local state = key and states[key]
    if state and state.source and state.source.Source == message.Source and state.request == message.Request then
        state.choices = Base.Choices(message.Choices)
        state.locked = message.Locked ~= false
        if state.locked and active and active.Key == key then active = nil end
        if message.Success ~= false then state.ackSource = message.Source end
        
        
        state.status = message.Status == "Ready" and "" or tostring(message.Detail)
        state.reply = true
    end
    lastUpdate = -150
end)

local function PreviewScores(widget, key, state, rows)
    local mounted, budget = 0, { count = 0 }
    local accepted = state.ackSource and state.lastSource and state.ackSource == state.lastSource.Source
    Walk(widget, function(node)
        local native = Read(node, "DataContext")
        local isModifier = DerivedPreview.IsProjected(node, state, Read)
        local index = ScoreIndex(native)
        local allocation = index and tostring(native) == tostring(rows[index])
        local summary = index and Read(native, "BaseValue") == nil
        local eligible = not isModifier and index and (allocation or summary) and Read(node, "Name") == "value"
        local original = eligible and Numeric(Read(native, "Value")) or nil
        if original then
            local adjustment = accepted and state.choices[index] - 8 or 0
            
            
            
            local included = 0
            if accepted and state.offsets and original == state.offsets.Scores[index] then
                included = state.offsets.Applied[index]
            end
            local value = math.max(1, original - included + adjustment)
            local changed, mode = DerivedPreview.Score(node, state, index, original, value, Read)
            if changed then
                mounted = mounted + 1
                Observe("preview:" .. key .. ":" .. tostring(node), "Ability preview: index=" .. index
                    .. "; native=" .. original .. "; existing adjustment=" .. included
                    .. "; selected adjustment=" .. adjustment .. "; shown=" .. value .. "; content=" .. mode)
            end
            
            
            if changed or Read(node, "Text") ~= nil then return false end
        end
        if Read(node, "Text") ~= nil then return false end
    end, 0, budget)
    Observe("preview-count:" .. key, "Ability score preview widgets=" .. mounted)
end

local function NewNameVM(key, index, row)
    local vm = Ext.UI.Instantiate(NAME_TYPE)
    vm.HB_NativeAbility, vm.HB_Owner = row, key
    vm.HB_AbilityIndex, vm.HB_RowToken = index, tostring(row)
    vm.HB_Ready = true
    vm.HB_Open:SetHandler(function()
        
        jobs[#jobs + 1] = { Kind = "Open", Key = key, Index = index }
        lastUpdate = -150
    end)
    return vm
end

local function NewMenuVM()
    local vm = Ext.UI.Instantiate(MENU_TYPE)
    
    
    vm.HB_MenuOpen, vm.HB_Title, vm.HB_Status, vm.HB_Selected = false, "Base Value", "", "Base Value: 8"
    vm.HB_TransferPoints = "Points to Spend: 0"
    vm.HB_Close:SetHandler(function() active = nil; lastUpdate = -150 end)
    for value = Base.Minimum, Base.Maximum do
        vm["HB_CanChoose_" .. value] = false
        local choice = value
        vm["HB_Choose_" .. value]:SetHandler(function()
            if active then
                jobs[#jobs + 1] = { Kind = "Choose", Key = active.Key, Index = active.Index, Value = choice }
                lastUpdate = -150
            end
        end)
    end
    return vm
end



local function Collect(widget, menuTemplate)
    local rows, candidates, labels, allocationButtons = {}, {}, {}, 0
    local budget = { count = 0 }
    local nativeTemplate = widget:Resource("AbilityDisplayName", true)
    Walk(widget, function(node)
        local row = Read(node, "DataContext")
        local index = Index(row)
        if index then
            local sound = Read(node, "SoundID")
            if sound == "UI_HUD_CC_DecreaseAbility" or sound == "UI_HUD_CC_IncreaseAbility" then
                rows[index], allocationButtons = row, allocationButtons + 1
            end
            local name, template = Read(node, "Name"), Read(node, "Template")
            local isLabel = name == "AbilityName" or template and (
                nativeTemplate and tostring(template) == tostring(nativeTemplate)
                or menuTemplate and tostring(template) == tostring(menuTemplate))
            if isLabel and name ~= "HB_BaseNativeName" then
                candidates[#candidates + 1] = { Node = node, Row = row, Index = index }
                return false
            end
        end
    end, 0, budget)
    local present = {}
    for index = 1, 6 do present[index] = index .. ":" .. tostring(rows[index] ~= nil) end
    Observe("scan:" .. tostring(widget), "UI scan: nodes=" .. budget.count .. "; rows="
        .. table.concat(present, ",") .. "; allocation buttons=" .. allocationButtons .. "; labels=" .. #candidates)
    
    
    for index = 1, 6 do if not rows[index] then return end end
    if allocationButtons < 12 then return end
    for _, label in ipairs(candidates) do
        
        
        if tostring(label.Row) == tostring(rows[label.Index]) then labels[#labels + 1] = label end
    end
    return rows, labels
end

local function PatchNames(key, labels, template, canEdit)
    local mounted = 0
    for _, label in ipairs(labels) do
        local ok, error = pcall(function()
            if tostring(Read(label.Node, "Template")) ~= tostring(template) then label.Node.Template = template end
            
            
            Walk(label.Node, function(node)
                if Read(node, "Name") == "HB_AbilityBaseButton" then
                    local vm = Read(node, "DataContext")
                    if Read(vm, "HB_Owner") ~= key or Read(vm, "HB_AbilityIndex") ~= label.Index
                        or Read(vm, "HB_RowToken") ~= tostring(label.Row) then
                        vm = NewNameVM(key, label.Index, label.Row)
                        node.DataContext = vm
                    end
                    vm.HB_Ready = canEdit
                    
                    
                    
                    local command = Read(vm, "HB_Open")
                    if tostring(Read(node, "Command")) ~= tostring(command) then node.Command = command end
                    mounted = mounted + 1
                    return false
                end
            end, 0, { count = 0 }, true)
        end)
        if not ok then Observe("label-recovery:" .. key .. ":" .. label.Index,
            "Stat label rebuild in progress; retrying index=" .. label.Index .. ": " .. tostring(error)) end
    end
    Observe("labels:" .. key, "Stat label buttons mounted=" .. mounted .. "; page=" .. states[key].page)
end

local function RestoreNativeNames(widget, labels, customTemplate)
    local nativeTemplate = widget:Resource("AbilityDisplayName", true)
    if not nativeTemplate then return end
    for _, label in ipairs(labels) do
        if tostring(Read(label.Node, "Template")) == tostring(customTemplate) then
            local ok, error = pcall(function() label.Node.Template = nativeTemplate end)
            if not ok then
                Observe("native-name-recovery:" .. tostring(label.Node),
                    "Native ability name restore will retry: " .. tostring(error))
            end
        end
    end
end

local function PageName(widget)
    local filename = Read(widget, "FileName")
    if type(filename) == "string" then
        local name = filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
        if PAGES[name] or name == HOST then return name end
    end
    return Read(widget, "Name")
end



local function Update(now)
    local root = Ext.UI.GetRoot()
    local content = root and root:Find("ContentRoot")
    if not content then DerivedPreview.Prune({}); return end
    local pages, hosts = {}, {}
    for index = 1, content.ChildrenCount do
        local child = content:Child(index)
        local name = child and PageName(child)
        if PAGES[name] then pages[#pages + 1] = { Node = child, Name = name }
        elseif name == HOST then hosts[#hosts + 1] = child end
    end
    Observe("root", "UI discovery: character pages=" .. #pages .. "; shared menu hosts=" .. #hosts)
    DerivedPreview.Prune(pages)
    local seen, visible, anchors, sources = {}, {}, {}, {}
    for _, page in ipairs(pages) do
        local widget, native = page.Node, Read(page.Node, "DataContext")
        local player = Read(widget, "PlayerId") or Read(native, "PlayerId")
        local key = tostring(widget) .. ":" .. tostring(native) .. ":" .. tostring(player)
        seen[key] = true
        local host
        for _, candidate in ipairs(hosts) do if Read(candidate, "PlayerId") == player then host = candidate; break end end
        if not host and #hosts == 1 and #pages == 1 then host = hosts[1] end
        local template = host and host:Resource("HB_AbilityBaseNameTemplate", true)
        local state = states[key]
        local rows, labels = Collect(widget, template)
        if rows then
            if not state then
                state = { page = page.Name, player = player, choices = Base.Choices(), status = "", locked = true }
                states[key] = state
            end
            local nativeCanEdit = Read(native, "CanEditAbilities") ~= false
            visible[key], anchors[key] = true, {}
            for _, label in ipairs(labels) do anchors[key][label.Index] = label.Node end
            state.ui = SnapshotUI(rows, native)
            local resolved, descriptor, offsets = pcall(Source, state.page, state.ui)
            if not resolved then
                Observe("source-recovery:" .. key, "Character definition rebuild in progress; menu remains available: " .. tostring(descriptor))
                descriptor, offsets = nil, nil
            end
            if descriptor and state.lastSource and descriptor.Source ~= state.lastSource.Source then
                state.choices, state.reply, state.ackSource = Base.Choices(), false, nil
                state.locked = true
            end
            state.source = descriptor
            if descriptor then
                state.lastSource, state.offsets = descriptor, offsets
                if state.fetchedSource ~= descriptor.Source then
                    state.reply = false
                    if Send(key, state, "Get") then state.fetchedSource = descriptor.Source end
                end
            end
            state.canEdit = nativeCanEdit and state.locked == false and descriptor ~= nil
                and state.ackSource == descriptor.Source
            if not state.canEdit and active and active.Key == key then active = nil end
            if template and state.locked then RestoreNativeNames(widget, labels, template)
            elseif template then PatchNames(key, labels, template, state.canEdit)
            else Observe("host:" .. key, "Shared menu host/template unavailable.") end
            if state.lastSource then sources[state.lastSource.Source] = true end
            if state.sentAt and not state.reply and now - state.sentAt > 3000 then
                state.status = "No server reply. Check Server/_Init.lua and HB_AbilityBase_ServerPassives.txt."
            end
            local projected, failure = pcall(DerivedPreview.Update, widget, native, key, state, rows, Base, Read, Walk, Observe)
            if not projected then Observe("derived-recovery:" .. key, "Derived preview will retry: " .. tostring(failure)) end
            PreviewScores(widget, key, state, rows)
        elseif state and state.lastSource then sources[state.lastSource.Source] = true end
    end
    local pending = jobs
    jobs = {}
    for _, job in ipairs(pending) do
        local state = states[job.Key]
        if state and visible[job.Key] and state.canEdit then
            state.reply = false
            if job.Kind == "Open" then
                active = { Key = job.Key, Index = job.Index }
                Send(job.Key, state, "Get")
            elseif job.Kind == "Choose" and active and active.Key == job.Key and active.Index == job.Index then
                if Base.CanChoose(state.choices, job.Index, job.Value) then
                    Log("Selected " .. Base.Passive(job.Index, job.Value) .. "; adjustment=" .. (job.Value - 8))
                    if Send(job.Key, state, "Set", job.Index, job.Value) then active = nil end
                else Log("Blocked unfunded ability change; index=" .. job.Index .. "; value=" .. job.Value) end
            end
        end
    end
    if active and not visible[active.Key] then active = nil end
    for _, host in ipairs(hosts) do
        local vm = Read(host, "DataContext")
        if Read(vm, "HB_IsMenu") ~= true then vm = NewMenuVM(); vm.HB_IsMenu = true; host.DataContext = vm end
        local state = active and states[active.Key]
        local anchor = active and anchors[active.Key] and anchors[active.Key][active.Index]
        local show = state ~= nil and anchor ~= nil and (Read(host, "PlayerId") == state.player or #hosts == 1 and #pages == 1)
        if show then
            if tostring(Read(vm, "HB_Anchor")) ~= tostring(anchor) then vm.HB_Anchor = anchor end
            local value = state.choices[active.Index]
            vm.HB_Title = tostring(state.ui.Rows[active.Index].Ability)
            vm.HB_Selected = "Base Value: " .. value
            vm.HB_TransferPoints = "Points to Spend: " .. Base.Available(state.choices)
            local acknowledged = state.source and state.ackSource == state.source.Source
            for choice = Base.Minimum, Base.Maximum do
                vm["HB_CanChoose_" .. choice] = acknowledged == true
                    and Base.CanChoose(state.choices, active.Index, choice)
            end
            vm.HB_Status, vm.HB_MenuOpen = state.status, true
        else
            vm.HB_MenuOpen = false
            if Read(vm, "HB_Anchor") ~= nil then
                local fresh = NewMenuVM()
                fresh.HB_IsMenu = true
                host.DataContext = fresh
            end
        end
    end
    local closed = {}
    for key, state in pairs(states) do
        if not seen[key] then
            if state.lastSource and not sources[state.lastSource.Source] and not closed[state.lastSource.Source] then
                closed[state.lastSource.Source] = true
                Send(key, state, "Close")
            end
            states[key] = nil
        end
    end
    for ticket, key in pairs(requests) do if not seen[key] then requests[ticket] = nil end end
end

if not Ext.UI or not Ext.UI.RegisterType or not Ext.UI.Instantiate then
    Log("Required Script Extender UI APIs unavailable."); return
end
Ext.UI.RegisterType(NAME_TYPE, {
    HB_NativeAbility = { Type = "Object", Notify = true }, HB_Owner = { Type = "String" },
    HB_AbilityIndex = { Type = "Int32" }, HB_RowToken = { Type = "String" },
    HB_Ready = { Type = "Bool", Notify = true }, HB_Open = { Type = "Command" },
})
local menuFields = {
    HB_IsMenu = { Type = "Bool" }, HB_MenuOpen = { Type = "Bool", Notify = true },
    HB_Anchor = { Type = "Object", Notify = true },
    HB_Title = { Type = "String", Notify = true }, HB_Selected = { Type = "String", Notify = true },
    HB_TransferPoints = { Type = "String", Notify = true },
    HB_Status = { Type = "String", Notify = true }, HB_Close = { Type = "Command" },
}
for value = Base.Minimum, Base.Maximum do
    menuFields["HB_Choose_" .. value] = { Type = "Command" }
    menuFields["HB_CanChoose_" .. value] = { Type = "Bool", Notify = true }
end
Ext.UI.RegisterType(MENU_TYPE, menuFields)

local MenuScope = Ext.Require("Client/MenuScope.lua")
local lastScopePoll, scopeOpen = -100000, false
local function CharacterMenuVisible(now)
    if now - lastScopePoll >= (scopeOpen and 250 or 950) then
        lastScopePoll, scopeOpen = now, MenuScope.IsOpen('Character')
    end
    return scopeOpen
end

Ext.Events.Tick:Subscribe(function()
    if dirty then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(reports, "\n") .. "\n")
        if not ok or result == false then Ext.Utils.Print("[HB Ability Base] Could not save client report.") end
    end
    local now = Ext.Timer.MonotonicTime()
    -- The ability-score menu does not exist during normal exploration.
    if not CharacterMenuVisible(now) then return end
    if queued or now - lastUpdate < 150 then return end
    lastUpdate = now
    local function Run()
        queued = false
        local ok, message = pcall(Update, now)
        if not ok and warning ~= tostring(message) then warning = tostring(message); Log("UI trace error: " .. warning) end
    end
    if Ext.UI.Defer then queued = true; Ext.UI.Defer(Run) else Run() end
end)
Log("Passive dropdown loaded with character-creation score preview.")

