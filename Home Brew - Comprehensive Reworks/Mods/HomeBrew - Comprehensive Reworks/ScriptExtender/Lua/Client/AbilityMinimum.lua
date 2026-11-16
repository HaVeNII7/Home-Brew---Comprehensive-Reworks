

local REPORT = "HomeBrew/Diagnostics/HB_AbilityBase_Diagnostics.txt"
local HOST = "HB_AbilityBaseMenu"
local NAME_TYPE, MENU_TYPE = "HB_AbilityBaseName_v2", "HB_AbilityBaseMenu_v4"
local PAGES = { CharacterCreation = true, CharacterCreation_c = true,
    CharacterRespec = true, CharacterRespec_c = true }
local Base = Ext.Require("Shared/AbilityBasePassives.lua")
local DerivedPreview = Ext.Require("Client/AbilityBasePreview.lua")
local channel = Base.Channel()
local states, metadata, jobs, requests = {}, {}, {}, {}
-- Native character-section navigation now controls idle traversal.
-- Do not suppress ability-row discovery after a failed scan: BG3 rebuilds
-- these controls during tab changes, and delayed retries hurt usability.
local COLLECTION_PATH_RECHECK_MS = 12000
local active, request, lastUpdate, queued = nil, 0, -150, false
local reports = { "HB ability baseline passives v0.27: tooltip opening events and hidden text priming; native TitleValue and split Base rows; signed bonuses, formatted scores and Constitution HP; base values 1-20; scaled costs." }
local dirty, warning = false, nil
local observations = {}
-- Measure active UI work without changing its 150ms responsiveness cadence.
-- Only scalar timing totals are retained; no UI proxies are cached.
local profileCurrent, profileTotals = nil, { calls = 0, total = 0, max = 0 }
local function ProfilePart(name, started)
    if _G.HB_DebugProfiler == true and profileCurrent and started then
        profileCurrent[name] = (profileCurrent[name] or 0)
            + math.max(0, Ext.Timer.MonotonicTime() - started)
    end
end
local function FinishProfile()
    if _G.HB_DebugProfiler ~= true or profileTotals.calls == 0 then
        profileTotals = { calls = 0, total = 0, max = 0 }
        return nil
    end
    local p = profileTotals
    local avg = function(name) return (p[name] or 0) / p.calls end
    local note = string.format('ABILITY_COST calls=%d avg=%.2fms max=%.2fms collect=%.2fms names=%.2fms source=%.2fms preview=%.2fms',
        p.calls, avg('total'), p.max, avg('collect'), avg('names'), avg('source'), avg('preview'))
    profileTotals = { calls = 0, total = 0, max = 0 }
    return note
end

local function Log(message)
    reports[#reports + 1] = message
    if #reports > 180 then table.remove(reports, 2) end
    dirty = dirty or _G.HB_DebugDiagnostics == true
        or message:find('error',1,true) ~= nil
        or message:find('ERROR',1,true) ~= nil
    if _G.HB_DebugConsole == true or message:find('error',1,true)
        or message:find('ERROR',1,true) then
        Ext.Utils.Print("[HB Ability Base] " .. message)
    end
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

local function Walk(node, callback, depth, budget, includeHidden, path)
    if not node or depth > 70 or budget.count >= 4500 then return end
    budget.count = budget.count + 1
    if not includeHidden and Read(node, "IsVisible") == false then return end
    if callback(node, path) == false then return end
    for index = 1, node.VisualChildrenCount do
        if path then path[#path + 1] = index end
        Walk(node:VisualChild(index), callback, depth + 1, budget, includeHidden, path)
        if path then path[#path] = nil end
    end
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



-- Only Lua scalars are kept in these signatures, never Noesis proxies.
-- Native character definitions can be rematerialized without a visible
-- ability change, so even an unchanged signature is periodically rechecked.
local function AbilityInputSignature(state)
    local ui=state.ui
    if not ui then return nil end
    local parts={tostring(state.page),tostring(ui.Used),tostring(ui.Unused),tostring(ui.Total)}
    for index=1,6 do
        local row=ui.Rows[index]
        if not row then return nil end
        parts[#parts+1]=tostring(row.Ability)
        parts[#parts+1]=tostring(row.Base)
        parts[#parts+1]=tostring(row.Value)
        parts[#parts+1]=tostring(row.CanIncrease)
        parts[#parts+1]=tostring(row.CanDecrease)
    end
    return table.concat(parts,'|')
end

local function PresentationSignature(state, sourceKey, activeIndex)
    local parts={sourceKey or '', tostring(state.source and state.source.Source),
        tostring(state.ackSource), tostring(state.locked), tostring(state.canEdit),
        tostring(state.status), tostring(activeIndex or 0)}
    for index=1,6 do
        parts[#parts+1]=tostring(state.choices[index])
        parts[#parts+1]=tostring(state.offsets and state.offsets.Applied[index])
        parts[#parts+1]=tostring(state.offsets and state.offsets.Scores[index])
    end
    local health=state.offsets and state.offsets.Health
    if health then
        parts[#parts+1]=tostring(health.Level)
        parts[#parts+1]=tostring(health.Max)
        parts[#parts+1]=tostring(health.Multiplier)
    end
    return table.concat(parts,'|')
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
    state.timeoutNotified = nil
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
        state.timeoutNotified = nil
        state.sourceProbeAt = nil
        -- The server reply is the authoritative completion of a selection;
        -- refresh both existing tooltip content and ability previews on the
        -- next deferred UI pass, with no periodic redraw required.
        state.presentationSignature = nil
        state.presentationAt = nil
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

local function NewNameVM(key, index, row, canEdit)
    local vm = Ext.UI.Instantiate(NAME_TYPE)
    vm.HB_NativeAbility, vm.HB_Owner = row, key
    vm.HB_AbilityIndex, vm.HB_RowToken = index, tostring(row)
    -- Avoid a brief enabled-then-disabled change while constructing a
    -- button before the server has acknowledged its source.
    vm.HB_Ready = canEdit == true
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
    vm.HB_Close:SetHandler(function()
        -- The popup is closed by the existing command, not by a background
        -- redraw. Refresh the native derived/hover presentation on closure.
        local closed = active
        active = nil
        if closed and states[closed.Key] then
            states[closed.Key].presentationSignature = nil
            states[closed.Key].presentationAt = nil
        end
        lastUpdate = -150
    end)
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



-- Only numeric child paths and scalar identity strings survive between
-- deferred UI callbacks. No Noesis userdata or UIWidget proxy is retained.
local function RecordAbilityPath(path, node)
    local indices = {}
    for i = 1, #path do indices[i] = path[i] end
    return { Indices = indices, Identity = tostring(node), Type = tostring(node.Type) }
end

local function ResolveAbilityPath(widget, record)
    if not record then return nil end
    local node = widget
    for _, index in ipairs(record.Indices) do
        if not node or Read(node, "IsVisible") == false then return nil end
        local count = node.VisualChildrenCount
        if type(count) ~= "number" or count < index then return nil end
        node = node:VisualChild(index)
    end
    if node and Read(node, "IsVisible") ~= false
        and tostring(node) == record.Identity and tostring(node.Type) == record.Type then return node end
    return nil
end

local function CachedAbilityCollection(widget, cache)
    if not cache then return nil end
    local rows, labels = {}, {}
    for index = 1, 6 do
        local node = ResolveAbilityPath(widget, cache.Rows[index])
        if not node then return nil end
        local row = Read(node, "DataContext")
        if Index(row) ~= index then return nil end
        local sound = Read(node, "SoundID")
        if sound ~= "UI_HUD_CC_DecreaseAbility" and sound ~= "UI_HUD_CC_IncreaseAbility" then return nil end
        rows[index] = row
    end
    -- Both native +/- controls must remain mounted; if the UI reflows or
    -- one disappears, force a fresh full collection before applying edits.
    for _, record in ipairs(cache.Buttons or {}) do
        local node = ResolveAbilityPath(widget, record.Path)
        local row = node and Read(node, "DataContext")
        local sound = node and Read(node, "SoundID")
        if not row or Index(row) ~= record.Index
            or tostring(row) ~= tostring(rows[record.Index])
            or (sound ~= "UI_HUD_CC_DecreaseAbility" and sound ~= "UI_HUD_CC_IncreaseAbility") then return nil end
    end
    for _, record in ipairs(cache.Labels) do
        local node = ResolveAbilityPath(widget, record.Path)
        if not node then return nil end
        local row = Read(node, "DataContext")
        if Index(row) ~= record.Index or tostring(row) ~= tostring(rows[record.Index]) then return nil end
        labels[#labels + 1] = { Node = node, Row = row, Index = record.Index }
    end
    if #labels == 0 then return nil end
    return rows, labels
end

local function Collect(widget, menuTemplate, readOnlyTemplate, state, now)
    -- Rehydrate references from validated paths inside THIS deferred call.
    -- The expensive walk happens only if the visual structure has changed,
    -- rather than every 150-450ms while the editor remains unchanged.
    if state and state.collectionCache and state.collectionAt
        and now - state.collectionAt < COLLECTION_PATH_RECHECK_MS then
        local ok, rows, labels = pcall(CachedAbilityCollection, widget, state.collectionCache)
        if ok and rows then return rows, labels end
        state.collectionCache = nil
    end
    local rows, rowPaths, buttonPaths, candidates, labels, allocationButtons = {}, {}, {}, {}, {}, 0
    local budget = { count = 0 }
    local nativeTemplate = widget:Resource("AbilityDisplayName", true)
    Walk(widget, function(node, path)
        local row = Read(node, "DataContext")
        local index = Index(row)
        if index then
            local sound = Read(node, "SoundID")
            if sound == "UI_HUD_CC_DecreaseAbility" or sound == "UI_HUD_CC_IncreaseAbility" then
                local record = RecordAbilityPath(path, node)
                rows[index], rowPaths[index] = row, record
                buttonPaths[#buttonPaths + 1] = { Index = index, Path = record }
                allocationButtons = allocationButtons + 1
            end
            local name, template = Read(node, "Name"), Read(node, "Template")
            local isLabel = name == "AbilityName" or template and (
                nativeTemplate and tostring(template) == tostring(nativeTemplate)
                or menuTemplate and tostring(template) == tostring(menuTemplate)
                or readOnlyTemplate and tostring(template) == tostring(readOnlyTemplate))
            if isLabel and name ~= "HB_BaseNativeName" then
                candidates[#candidates + 1] = { Node = node, Row = row, Index = index,
                    Path = RecordAbilityPath(path, node) }
                return false
            end
        end
    end, 0, budget, false, {})
    local present = {}
    for index = 1, 6 do present[index] = index .. ":" .. tostring(rows[index] ~= nil) end
    Observe("scan:" .. tostring(widget), "UI scan: nodes=" .. budget.count .. "; rows="
        .. table.concat(present, ",") .. "; allocation buttons=" .. allocationButtons .. "; labels=" .. #candidates)
    for index = 1, 6 do if not rows[index] then
        if state then state.collectionCache = nil end
        return
    end end
    if allocationButtons < 12 then
        if state then state.collectionCache = nil end
        return
    end
    local labelPaths = {}
    for _, label in ipairs(candidates) do
        if tostring(label.Row) == tostring(rows[label.Index]) then
            labels[#labels + 1] = label
            labelPaths[#labelPaths + 1] = { Index = label.Index, Path = label.Path }
        end
    end
    if state and #labels > 0 then
        state.collectionCache = { Rows = rowPaths, Buttons = buttonPaths, Labels = labelPaths }
        state.collectionAt = now
    end
    return rows, labels
end

local function PatchNames(key, labels, template, canEdit, pendingApproval)
    local mounted = 0
    local state = states[key]
    if not state.nameButtonPaths then state.nameButtonPaths = {} end
    for _, label in ipairs(labels) do
        local ok, error = pcall(function()
            local labelId, rowId = tostring(label.Node), tostring(label.Row)
            local replaced = tostring(Read(label.Node, "Template")) ~= tostring(template)
            if replaced then label.Node.Template = template end
            local cached = not replaced and state.nameButtonPaths[label.Index]
            local button
            if cached and cached.Label == labelId and cached.Row == rowId then
                button = ResolveAbilityPath(label.Node, cached.Button)
                if button and Read(button, "Name") ~= "HB_AbilityBaseButton" then button = nil end
            end
            if not button then
                -- A rebuilt Noesis template invalidates this path; re-discover
                -- only the affected label's clickable control, never trust a
                -- missing button just because its old parent identity matched.
                Walk(label.Node, function(node, path)
                    if Read(node, "Name") == "HB_AbilityBaseButton" then
                        button = node
                        state.nameButtonPaths[label.Index] = {
                            Label = labelId, Row = rowId, Button = RecordAbilityPath(path, node)
                        }
                        return false
                    end
                end, 0, { count = 0 }, true, {})
            end
            if button then
                local vm = Read(button, "DataContext")
                if Read(vm, "HB_Owner") ~= key or Read(vm, "HB_AbilityIndex") ~= label.Index
                    or Read(vm, "HB_RowToken") ~= rowId then
                    vm = NewNameVM(key, label.Index, label.Row, canEdit)
                    button.DataContext = vm
                end
                if Read(vm, "HB_Ready") ~= canEdit then vm.HB_Ready = canEdit end
                if pendingApproval then
                    pcall(function()
                        if Read(button, "Opacity") ~= 1 then button.Opacity = 1 end
                    end)
                end
                mounted = mounted + 1
            else
                state.nameButtonPaths[label.Index] = nil
            end
        end)
        if not ok then
            state.nameButtonPaths[label.Index] = nil
            Observe("label-recovery:" .. key .. ":" .. label.Index,
                "Stat label rebuild in progress; retrying index=" .. label.Index .. ": " .. tostring(error))
        end
    end
    Observe("labels:" .. key, "Stat label buttons mounted=" .. mounted .. "; page=" .. state.page)
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

local function MountReadOnlyNames(widget, labels, customTemplate, readOnlyTemplate, state)
    if not readOnlyTemplate then
        -- Fail safe if a host is being rebuilt: keep BG3's native template
        -- instead of attempting to use an unavailable fallback resource.
        RestoreNativeNames(widget, labels, customTemplate)
        return
    end
    for _, label in ipairs(labels) do
        if tostring(Read(label.Node, "Template")) ~= tostring(readOnlyTemplate) then
            local ok, error = pcall(function() label.Node.Template = readOnlyTemplate end)
            if not ok then
                Observe("readonly-name-recovery:" .. tostring(label.Node),
                    "Read-only ability label will retry: " .. tostring(error))
            end
        end
        -- The native row still owns the DataContext; no extra VM or command
        -- is ever installed while locked. Discard any previous button path.
        if state.nameButtonPaths then state.nameButtonPaths[label.Index] = nil end
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



-- A tooltip-opening event is a better refresh trigger than idle polling.
-- It carries only scalar scheduling signals; the normal Update() resolves
-- the live widget/rows in Ext.UI.Defer before drawing the current tooltip.
local tooltipRefreshFollowupAt = nil
local function RequestNativeTooltipRefresh()
    lastUpdate = -150
    for _, state in pairs(states) do
        state.presentationSignature = nil
        state.presentationAt = nil
    end
    -- Native ToolTipOpening may precede the actual tooltip visual mount.
    -- One short event-bound follow-up covers that transition; no idle timer.
    local later = Ext.Timer.MonotonicTime() + 120
    if not tooltipRefreshFollowupAt or tooltipRefreshFollowupAt < later then
        tooltipRefreshFollowupAt = later
    end
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
        local readOnlyTemplate = host and host:Resource("HB_AbilityBaseReadOnlyNameTemplate", true)
        local state = states[key]
        local rows, labels
        -- Run the original collector whenever an update is permitted.
        -- The light native section gate below eliminates off-tab scans.
        local collectStarted = profileCurrent and Ext.Timer.MonotonicTime() or nil
        rows, labels = Collect(widget, template, readOnlyTemplate, state, now)
        ProfilePart('collect', collectStarted)
        if rows then
            if not state then
                state = { page = page.Name, player = player, choices = Base.Choices(), status = "", locked = true }
                states[key] = state
            end
            local nativeCanEdit = Read(native, "CanEditAbilities") ~= false
            visible[key], anchors[key] = true, {}
            for _, label in ipairs(labels) do anchors[key][label.Index] = label.Node end
            state.ui = SnapshotUI(rows, native)
            local sourceKey=AbilityInputSignature(state)
            local activeHere=active and active.Key==key
            local sourceInterval=activeHere and 550 or 900
            local usePrevious=state.lastSource and sourceKey and
                state.sourceSignature==sourceKey and state.sourceProbeAt and
                now-state.sourceProbeAt<sourceInterval and #jobs==0
            local resolved, descriptor, offsets
            if usePrevious then
                resolved, descriptor, offsets=true,state.lastSource,state.offsets
            else
                local sourceStarted = profileCurrent and Ext.Timer.MonotonicTime() or nil
                resolved, descriptor, offsets=pcall(Source, state.page, state.ui)
                ProfilePart('source', sourceStarted)
                if resolved and descriptor then
                    state.sourceSignature, state.sourceProbeAt=sourceKey,now
                else
                    state.sourceProbeAt=nil
                end
            end
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
            -- The server begins in an unverified/locked state. Previously
            -- all six native labels were replaced by HB templates only when
            -- the Get reply arrived, making the labels visibly flash.
            -- Mount the same template while that Get is in flight, but keep
            -- its command disabled until the verified reply. An actual
            -- Locked reply still restores vanilla names unchanged.
            local pendingApproval = state.locked and state.reply == false
                and descriptor ~= nil and nativeCanEdit
                and state.fetchedSource == descriptor.Source
            local nameStarted = profileCurrent and Ext.Timer.MonotonicTime() or nil
            -- A locked native ability editor (including Honour Mode) can
            -- expose all six rows but leave BG3's native name text blank on
            -- its FIRST visit. Restoring AbilityDisplayName alone is not
            -- enough: the same empty native binding remains until a tab
            -- change remounts the widget. Use a direct read-only template
            -- bound to each existing VMAbility.Ability while locked. The
            -- original clickable template remains unchanged when editable.
            if template and (not nativeCanEdit or (state.locked and not pendingApproval)) then
                MountReadOnlyNames(widget, labels, template, readOnlyTemplate, state)
            elseif template then PatchNames(key, labels, template, state.canEdit, pendingApproval)
            else Observe("host:" .. key, "Shared menu host/template unavailable.") end
            ProfilePart('names', nameStarted)
            if state.lastSource then sources[state.lastSource.Source] = true end
            if state.sentAt and not state.reply and now - state.sentAt > 3000 then
                state.status = "No server reply. Check Server/_Init.lua and HB_AbilityBase_ServerPassives.txt."
            end
            -- Derived previews traverse the native character's stats and
            -- visual tree. Recompute immediately whenever an input, choice,
            -- server reply or editor state changes, otherwise keep the
            -- rendered result for a short heartbeat. Tooltip-open hooks in
            -- DerivedPreview still refresh their own content immediately.
            local activeIndex=active and active.Key==key and active.Index or nil
            local presentation=PresentationSignature(state,sourceKey,activeIndex)
            local previewInterval=activeIndex and 550 or 950
            if state.presentationSignature~=presentation or
                not state.presentationAt or now-state.presentationAt>=previewInterval then
                local previewStarted = profileCurrent and Ext.Timer.MonotonicTime() or nil
                local projected, failure = pcall(DerivedPreview.Update, widget, native, key, state, rows, Base, Read, Walk, Observe,
                    nil, RequestNativeTooltipRefresh)
                if not projected then
                    state.presentationSignature=nil
                    Observe("derived-recovery:" .. key, "Derived preview will retry: " .. tostring(failure))
                else
                    state.presentationSignature, state.presentationAt=presentation,now
                end
                PreviewScores(widget, key, state, rows)
                ProfilePart('preview', previewStarted)
            end
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

-- The installed CCLib keyboard/controller templates select main sections
-- through the native gameplayTabs ListBox. Its SelectedItem.Tag uses "ability"
-- for the Abilities section. Observe selection, not mouse clicks, so keyboard,
-- controller, and automatic navigation take the same path.
-- Cache only numeric paths and scalar widget identities, NEVER Noesis proxies.
local abilityNavigation = {}
local lastSection, nextSectionCheck = 'unknown', -1
local SECTION_IDLE_MS, SECTION_ACTIVE_MS = 85, 150
local NAV_NAMES = {
    gameplayTabs = 'tabs', gameplaySubPanel = 'panel',
    subTabsSpellsList = 'spells', subTabsPassivesList = 'passives',
    subTabsEquipmentList = 'equipment',
}
local function NativeAbilitySection(widget, key)
    local records = abilityNavigation[key]
    local tabs = records and ResolveAbilityPath(widget, records.tabs)
    if not tabs or Read(tabs, 'Name') ~= 'gameplayTabs' then
        local discovered = {}
        Walk(widget, function(node, path)
            local field = NAV_NAMES[Read(node, 'Name')]
            if field and not discovered[field] then
                discovered[field] = RecordAbilityPath(path, node)
            end
        end, 0, { count = 0 }, true, {})
        records = discovered.tabs and discovered or nil
        abilityNavigation[key] = records
        tabs = records and ResolveAbilityPath(widget, records.tabs)
    end
    if not tabs then return nil, 'no-tabs' end
    local selected = Read(tabs, 'SelectedItem')
    local tag = Read(selected, 'Tag')
    if type(tag) == 'string' and tag ~= '' then
        return tag == 'ability' and 'ability' or 'other', tag
    end
    -- BG3 deselects the main ListBox when opening a Spells/Cantrips,
    -- Passives or Equipment subtab. Those native selectors are independently
    -- sufficient proof that the Abilities pane is not selected.
    local index = Read(tabs, 'SelectedIndex')
    if index == -1 and records then
        local panel = ResolveAbilityPath(widget, records.panel)
        local selector = panel and Read(panel, 'DataContext')
        local cantrips = Read(selector, 'IsCantrips')
        local actions = Read(selector, 'IsActions')
        if (cantrips == true or cantrips == false) and actions == false then
            return 'other', 'spell-selector'
        end
        for _, field in ipairs({ 'spells', 'passives', 'equipment' }) do
            local list = ResolveAbilityPath(widget, records[field])
            local tab = list and Read(list, 'SelectedIndex')
            if type(tab) == 'number' and tab >= 0 then
                return 'other', field .. '-subtab'
            end
        end
    end
    -- Missing/rebuilt native data must NEVER suppress the original editor.
    -- In particular, do not interpret the numeric main-tab index as a
    -- reliable identity (its ordering can vary by character and mode).
    return nil, 'tag-unavailable:' .. tostring(index)
end

local function SelectedAbilitySections()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find('ContentRoot')
    if not content then return 'unknown', 'no-content' end
    local pages, abilityCount, otherCount, details = 0, 0, 0, {}
    local seen = {}
    for index = 1, content.ChildrenCount do
        local page = content:Child(index)
        if page and PAGES[PageName(page)] and Read(page, 'IsVisible') ~= false then
            pages = pages + 1
            local key = tostring(page)
            seen[key] = true
            local ok, mode, label = pcall(NativeAbilitySection, page, key)
            if not ok then mode, label = nil, 'navigation-unavailable' end
            if mode == 'ability' then abilityCount = abilityCount + 1
            elseif mode == 'other' then otherCount = otherCount + 1 end
            details[#details + 1] = tostring(label)
        end
    end
    for key in pairs(abilityNavigation) do
        if not seen[key] then abilityNavigation[key] = nil end
    end
    if abilityCount > 0 then return 'ability', table.concat(details, ',') end
    if pages > 0 and otherCount == pages then return 'other', table.concat(details, ',') end
    return 'unknown', pages == 0 and 'no-pages' or table.concat(details, ',')
end

-- The native page VM exposes point totals directly. Reading those scalars
-- is much cheaper than revalidating every ability label and allocation
-- button. An actual vanilla +/- action changes this fingerprint and triggers
-- the original full update on the next short check. HB button actions and
-- server replies already request an immediate update independently.
-- The bounded integrity pass still handles invisible native UI rebuilds.
local lastInputPulse, nextIntegrityAt = nil, -1
local ABILITY_IDLE_INTEGRITY_MS = 450
local function NativeAbilityInputPulse()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find('ContentRoot')
    if not content then return nil end
    local parts, count = {}, 0
    for index = 1, content.ChildrenCount do
        local page = content:Child(index)
        local name = page and PageName(page)
        if PAGES[name] then
            local native = Read(page, 'DataContext')
            count = count + 1
            parts[#parts + 1] = table.concat({
                tostring(page), tostring(native), tostring(Read(page, 'PlayerId')),
                tostring(Read(native, 'UsedAbilityPoints')),
                tostring(Read(native, 'UnusedAbilityPoints')),
                tostring(Read(native, 'TotalAbilityPoints')),
                tostring(Read(native, 'CanEditAbilities'))
            }, ':')
        end
    end
    if count == 0 then return nil end
    return table.concat(parts, '|')
end

-- The main point-total fingerprint is inexpensive but is not enough to
-- detect all score changes. In particular, late native changes and balancing
-- one score against another can leave Used/Unused/Total unchanged.
-- Only on the *input follow-up* do we compare the actual six native rows with
-- the last full Update snapshot. Re-resolve cached numeric paths inside the
-- current deferred UI callback; never retain a Noesis object between frames.
-- Unknown/rebuilt rows fail open and request the original full Update.
local function NativeAbilityRowsChanged()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find('ContentRoot')
    if not content then return true end
    local found = 0
    for index = 1, content.ChildrenCount do
        local page = content:Child(index)
        local name = page and PageName(page)
        if PAGES[name] and Read(page, 'IsVisible') ~= false then
            found = found + 1
            local native = Read(page, 'DataContext')
            local player = Read(page, 'PlayerId') or Read(native, 'PlayerId')
            local key = tostring(page) .. ':' .. tostring(native) .. ':' .. tostring(player)
            local state = states[key]
            local records = state and state.collectionCache and state.collectionCache.Rows
            local uiRows = state and state.ui and state.ui.Rows
            if not records or not uiRows then return true, key end
            for ability = 1, 6 do
                local node = ResolveAbilityPath(page, records[ability])
                local row = node and Read(node, 'DataContext')
                local snapshot = uiRows[ability]
                if not row or Index(row) ~= ability or not snapshot then return true, key end
                if tostring(Read(row, 'Value')) ~= snapshot.Value
                    or Read(row, 'BaseValue') ~= snapshot.Base
                    or Read(row, 'CanIncrease') ~= snapshot.CanIncrease
                    or Read(row, 'CanDecrease') ~= snapshot.CanDecrease then
                    return true, key
                end
            end
        end
    end
    return found == 0
end

-- A rare, read-only safety audit replaces the unconditional 12-second full
-- Update. Native score changes and UI remounts still force the ORIGINAL
-- update; unchanged, correctly mounted controls never do. Re-resolve only
-- saved numeric visual paths inside Ext.UI.Defer, never retain UI proxies.
local function NativeAbilityControlsChanged()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find('ContentRoot')
    if not content then return true end
    local found = 0
    for index = 1, content.ChildrenCount do
        local page = content:Child(index)
        local name = page and PageName(page)
        if PAGES[name] and Read(page, 'IsVisible') ~= false then
            found = found + 1
            local native = Read(page, 'DataContext')
            local player = Read(page, 'PlayerId') or Read(native, 'PlayerId')
            local key = tostring(page) .. ':' .. tostring(native) .. ':' .. tostring(player)
            local state = states[key]
            if not state or not state.collectionCache or not state.ui then return true, key end
            local ok, rows, labels = pcall(CachedAbilityCollection, page, state.collectionCache)
            if not ok or not rows or not labels or #labels < 6 then return true, key end
            -- A rebuilt label can leave unchanged native scores but remove
            -- HB's clickable button. Detect that without re-running previews.
            local host, hostCount, pageCount = nil, 0, 0
            local onlyHost
            for child = 1, content.ChildrenCount do
                local candidate = content:Child(child)
                local candidateName = candidate and PageName(candidate)
                if candidateName == HOST then
                    hostCount, onlyHost = hostCount + 1, candidate
                    if Read(candidate, 'PlayerId') == player then host = candidate end
                elseif PAGES[candidateName] then
                    pageCount = pageCount + 1
                end
            end
            -- Match the working Update() logic for a single-player menu,
            -- where the host sometimes does not expose a PlayerId.
            if not host and hostCount == 1 and pageCount == 1 then host = onlyHost end
            if not host then return true, key end
            local custom = host:Resource('HB_AbilityBaseNameTemplate', true)
            local readOnly = host:Resource('HB_AbilityBaseReadOnlyNameTemplate', true)
            if Read(Read(host, 'DataContext'), 'HB_IsMenu') ~= true then return true, key end
            local nativeCanEdit = Read(native, 'CanEditAbilities') ~= false
            local pendingApproval = state.locked and state.reply == false
                and state.fetchedSource and state.lastSource
                and state.fetchedSource == state.lastSource.Source
            local shouldUseHB = nativeCanEdit and (not state.locked or pendingApproval)
            for _, label in ipairs(labels) do
                if shouldUseHB then
                    if not custom or tostring(Read(label.Node, 'Template')) ~= tostring(custom) then
                        return true, key
                    end
                    local cache = state.nameButtonPaths and state.nameButtonPaths[label.Index]
                    if not cache or cache.Label ~= tostring(label.Node)
                        or cache.Row ~= tostring(label.Row) then return true, key end
                    local button = ResolveAbilityPath(label.Node, cache.Button)
                    local vm = button and Read(button, 'DataContext')
                    if not button or Read(button, 'Name') ~= 'HB_AbilityBaseButton'
                        or Read(vm, 'HB_Owner') ~= key
                        or Read(vm, 'HB_AbilityIndex') ~= label.Index
                        or Read(vm, 'HB_RowToken') ~= tostring(label.Row) then return true, key end
                else
                    -- A stable locked screen should NOT trigger unnecessary
                    -- full UI rebuilds every time the integrity audit runs.
                    if not readOnly or tostring(Read(label.Node, 'Template')) ~= tostring(readOnly) then
                        return true, key
                    end
                end
            end
        end
    end
    return found == 0
end

-- During the initial 900ms native layout warm-up, keep inspecting the
-- mounted controls, but do not perform a full stats/source/preview rebuild
-- repeatedly once the server source and all original HB controls are settled.
-- If collection is incomplete, a reply is pending, or native UI templates
-- have been rebuilt, retain the original immediate full-update behavior.
-- This uses only scalars and resolves any UI path inside Ext.UI.Defer.
local function NativeAbilityWarmupNeedsRebuild()
    if next(states) == nil then return true end
    for _, state in pairs(states) do
        if not state.ui or not state.source or state.reply == false then
            return true
        end
    end
    local ok, changed = pcall(NativeAbilityControlsChanged)
    return not ok or changed ~= false
end

-- Input-driven scheduling for the native Abilities editor.
-- The game's mouse, keyboard and controller input notifications request a
-- deferred refresh; HB's own commands/server responses also request one.
-- Inactivity never triggers a full refresh by itself. A rare read-only
-- integrity audit handles silent UI rebuilds and unannounced native changes.
-- Never access Noesis from an input callback; Ext.UI.Defer owns all UI access.
local INPUT_SETTLE_MS = 45
local INPUT_FOLLOWUP_MS = 230
local INPUT_LATE_FOLLOWUP_MS = 550
local IDLE_NAV_AUDIT_MS = 2100
local OTHER_NAV_AUDIT_MS = 3000
local UNKNOWN_NAV_RETRY_MS = 175
local POPUP_AUDIT_MS = 450
local SAFETY_AUDIT_MS = 12000
local ACTIVATION_WARMUP_MS = 900
local activationWarmupUntil = -1
local inputDue, inputFollowupAt, inputLateFollowupAt, lastInputEventAt = nil, nil, nil, -1
local lastSafetyAuditAt, wasMenuOpen = -1, false
local inputDrivenAvailable = false

local function OnNativeInput(now)
    if not inputDrivenAvailable then return end
    if type(now) ~= 'number' then now = Ext.Timer.MonotonicTime() end
    -- No native UI work here. Leave the event time open during key-repeat or
    -- rapid presses, but never keep postponing the first pending refresh.
    local first = now + INPUT_SETTLE_MS
    if not inputDue or first < inputDue then inputDue = first end
    local follow = now + INPUT_FOLLOWUP_MS
    if not inputFollowupAt or follow > inputFollowupAt then inputFollowupAt = follow end
    local late = now + INPUT_LATE_FOLLOWUP_MS
    if not inputLateFollowupAt or late > inputLateFollowupAt then inputLateFollowupAt = late end
    lastInputEventAt = now
    if nextSectionCheck > first then nextSectionCheck = first end
end

local function InstallInputHook(name, callback)
    local ev = Ext.Events and Ext.Events[name]
    if not ev or not ev.Subscribe then return false end
    local ok, result = pcall(function() return ev:Subscribe(callback) end)
    return ok and result ~= false
end

if Ext.Timer and Ext.Timer.MonotonicTime then
    local mouse = InstallInputHook('MouseButtonInput', function(e)
        -- Click release is the reliable point after native button handling.
        if e.Pressed == false then OnNativeInput() end
    end)
    local keyboard = InstallInputHook('KeyInput', function(e)
        if e.Pressed == true then OnNativeInput() end
    end)
    local controller = InstallInputHook('ControllerButtonInput', function(e)
        if e.Pressed == true then OnNativeInput() end
    end)
    -- Axis changes can navigate gamepad menus, but are high frequency. Only
    -- meaningful stick/trigger motion is sampled, never every SDL axis frame.
    local axis = InstallInputHook('ControllerAxisInput', function(e)
        if type(e.Value) == 'number' and math.abs(e.Value) >= 0.60 then
            local now = Ext.Timer.MonotonicTime()
            if now - lastInputEventAt >= 175 then OnNativeInput(now) end
        end
    end)
    -- If a runtime lacks the relevant event API, preserve the old working
    -- cadence rather than silently compromising native input responsiveness.
    inputDrivenAvailable = mouse and keyboard and controller and axis
    if not inputDrivenAvailable and _G.HB_DebugDiagnostics == true then
        Log('ABILITY_INPUT legacy polling fallback (missing input event)')
    end
end

local function ScheduleNextCheck(now, detected)
    if not inputDrivenAvailable then
        nextSectionCheck = now + (detected == 'other' and SECTION_IDLE_MS or SECTION_ACTIVE_MS)
    elseif detected == 'ability' then
        local warmup = now < activationWarmupUntil
        nextSectionCheck = now + (warmup and SECTION_ACTIVE_MS
            or active and POPUP_AUDIT_MS or IDLE_NAV_AUDIT_MS)
    elseif detected == 'other' then
        nextSectionCheck = now + OTHER_NAV_AUDIT_MS
    else
        -- The game can be between layouts during a character/page transition.
        nextSectionCheck = now + UNKNOWN_NAV_RETRY_MS
    end
end

Ext.Events.Tick:Subscribe(function()
    if dirty then
        dirty = false
        local ok, result = pcall(Ext.IO.SaveFile, REPORT, table.concat(reports, "\n") .. "\n")
        if not ok or result == false then Ext.Utils.Print("[HB Ability Base] Could not save client report.") end
    end
    if not MenuScope.MaybeOpen('Character') then
        wasMenuOpen = false
        lastSection = 'unknown'
        tooltipRefreshFollowupAt = nil
        lastInputPulse, nextIntegrityAt = nil, -1
        lastSafetyAuditAt = -1
        activationWarmupUntil = -1
        -- Do not drop the input signal; an input can be the one that opened
        -- the menu just before MenuScope's shallow snapshot becomes visible.
        return
    end
    local now = Ext.Timer.MonotonicTime()
    if not wasMenuOpen then
        wasMenuOpen = true
        nextSectionCheck = -1
        lastUpdate = -150
    end
    -- HB commands and acknowledged server replies set lastUpdate negative.
    -- Respond at once independently of the background audit deadline.
    local urgent = lastUpdate < 0 or #jobs > 0
    local dueTooltip = tooltipRefreshFollowupAt and now >= tooltipRefreshFollowupAt
    local dueInput = inputDrivenAvailable and inputDue and now >= inputDue
    local dueFollowup = inputDrivenAvailable and inputFollowupAt and now >= inputFollowupAt
    local dueLate = inputDrivenAvailable and inputLateFollowupAt and now >= inputLateFollowupAt
    if not urgent and not dueTooltip and not dueInput and not dueFollowup and not dueLate
        and now < nextSectionCheck then return end
    if queued or not (Ext.UI and Ext.UI.Defer) then return end
    -- Capture and consume events only when successfully queueing a callback;
    -- input arriving while queued is retained for the following UI frame.
    if dueTooltip then tooltipRefreshFollowupAt = nil end
    if dueInput then inputDue = nil end
    if dueFollowup then inputFollowupAt = nil end
    if dueLate then inputLateFollowupAt = nil end
    queued = true
    local ok, why = pcall(Ext.UI.Defer, function()
        queued = false
        local safe, err = pcall(function()
            if not MenuScope.IsOpen('Character') then
                lastSection = 'unknown'
                wasMenuOpen = false
                return
            end
            local detected, detail = SelectedAbilitySections()
            local was = lastSection
            if detected ~= was then
                if was == 'ability' then
                    local report = FinishProfile()
                    if report then
                        Log(report)
                        dirty = true -- explicit opt-in profile to diagnostic file only
                    end
                end
                lastSection = detected
                if detected ~= 'ability' then tooltipRefreshFollowupAt = nil end
                lastInputPulse, nextIntegrityAt = nil, -1
                lastSafetyAuditAt = -1
                activationWarmupUntil = detected == 'ability'
                    and now + ACTIVATION_WARMUP_MS or -1
                lastUpdate = -150 -- reentry initializes without a timer delay
                if _G.HB_DebugDiagnostics == true then
                    Log('ABILITY_SECTION ' .. detected .. ' (' .. tostring(detail) .. ')')
                end
            end
            ScheduleNextCheck(now, detected)
            -- If a new event was received while we were in the deferred UI
            -- callback, its deadline still wins over the idle audit.
            if inputDue and nextSectionCheck > inputDue then nextSectionCheck = inputDue end
            if inputFollowupAt and nextSectionCheck > inputFollowupAt then nextSectionCheck = inputFollowupAt end
            if inputLateFollowupAt and nextSectionCheck > inputLateFollowupAt then
                nextSectionCheck = inputLateFollowupAt
            end
            -- One cleanup update when exiting Abilities, never idle page walks.
            if detected == 'other' and was == 'other' and not active and #jobs == 0 then return end
            if not inputDrivenAvailable and now - lastUpdate < SECTION_ACTIVE_MS
                and detected == was and #jobs == 0 then return end
            -- Input alone is not an instruction to repaint everything.
            -- Run the original editor update when the native totals or one
            -- of six actual ability rows changed. HB commands and server
            -- replies independently force full updates via lastUpdate/jobs.
            local pulseOK, pulse
            if detected == 'ability' then
                pulseOK, pulse = pcall(NativeAbilityInputPulse)
            end
            local sameInput = pulseOK and pulse and pulse == lastInputPulse
            local changedRows, changedKey = false, nil
            if inputDrivenAvailable and detected == 'ability'
                and (dueInput or dueFollowup or dueLate) then
                local checkOK, changed, key = pcall(NativeAbilityRowsChanged)
                changedRows = not checkOK or changed == true
                changedKey = key
            end
            local serverTimedOut = false
            if detected == 'ability' then
                for _, state in pairs(states) do
                    if state.sentAt and not state.reply and not state.timeoutNotified
                        and now - state.sentAt > 3000 then
                        state.timeoutNotified = true
                        serverTimedOut = true
                    end
                end
            end
            -- A mounted, server-settled ability pane need not redraw all
            -- stats six more times merely because the native warm-up window
            -- is still open. Validate its actual controls instead; an
            -- incomplete/rebuilt/pending pane still follows the old cadence.
            local warmingUp = detected == 'ability' and now < activationWarmupUntil
            local warmupRepair = warmingUp and sameInput and not changedRows
                and not urgent and not dueTooltip and not serverTimedOut
                and NativeAbilityWarmupNeedsRebuild()
            -- Retain a final native/source reconciliation near the end of the
            -- original warm-up window: rare late definition materialization
            -- must not be deferred to the subsequent 12-second safety audit.
            local warmupFinalPass = warmingUp
                and now >= activationWarmupUntil - SECTION_ACTIVE_MS
                and lastUpdate < activationWarmupUntil - SECTION_ACTIVE_MS
            local needsFull = detected ~= 'ability' or detected ~= was
                or dueTooltip or lastUpdate < 0 or #jobs > 0 or serverTimedOut
                or warmupRepair or warmupFinalPass or changedRows
                or (detected == 'ability' and not sameInput)
            -- Menus stay interactive through their own command callbacks;
            -- simply leaving a dropdown open no longer triggers redraws.
            -- Every 12 seconds audit the live UI, never update it just due
            -- to time. An unexpected score change or missing/rebuilt HB
            -- control still causes the original update immediately.
            if inputDrivenAvailable and detected == 'ability' and not needsFull
                and (lastSafetyAuditAt < 0 or now-lastSafetyAuditAt >= SAFETY_AUDIT_MS) then
                lastSafetyAuditAt = now
                local rowsOK, rowsChanged, key = pcall(NativeAbilityRowsChanged)
                changedRows = not rowsOK or rowsChanged == true
                changedKey = key
                if not changedRows then
                    local controlsOK, controlsChanged, controlKey = pcall(NativeAbilityControlsChanged)
                    changedRows = not controlsOK or controlsChanged == true
                    changedKey = controlKey
                end
                needsFull = changedRows
            end
            if changedRows then
                if changedKey and states[changedKey] then
                    states[changedKey].presentationSignature = nil
                    states[changedKey].presentationAt = nil
                else
                    for _, state in pairs(states) do
                        state.presentationSignature = nil
                        state.presentationAt = nil
                    end
                end
            end
            if not inputDrivenAvailable and detected == 'ability' and was == 'ability'
                and not active and #jobs == 0 and lastUpdate >= 0 then
                if sameInput and now < nextIntegrityAt then return end
                needsFull = true
            end
            if not needsFull then return end
            lastUpdate = now
            if detected == 'ability' then
                lastInputPulse = pulseOK and pulse or nil
                nextIntegrityAt = now + ABILITY_IDLE_INTEGRITY_MS
                lastSafetyAuditAt = now
            end
            local measure = detected == 'ability' and _G.HB_DebugProfiler == true
            profileCurrent = measure and {} or nil
            local workStarted = measure and Ext.Timer.MonotonicTime() or nil
            local updated, reason = pcall(Update, now)
            if measure and updated and profileCurrent then
                local p = profileTotals
                local elapsed = math.max(0, Ext.Timer.MonotonicTime() - workStarted)
                p.calls, p.total, p.max = p.calls + 1, p.total + elapsed, math.max(p.max, elapsed)
                for name, ms in pairs(profileCurrent) do p[name] = (p[name] or 0) + ms end
            end
            profileCurrent = nil
            if not updated then
                lastSafetyAuditAt = -1
                lastInputPulse = nil
                -- An actual failed UI pass must retry promptly, not wait for
                -- the ordinary idle audit. The warning remains deduplicated.
                nextSectionCheck = now + SECTION_ACTIVE_MS
            end
            if not updated and warning ~= tostring(reason) then
                warning = tostring(reason)
                Log('UI trace error: ' .. warning)
            end
        end)
        if not safe then
            lastSafetyAuditAt = -1
            Log('SAFE_UI_POLL_ERROR ' .. tostring(err))
        end
    end)
    if not ok then
        queued = false
        lastSafetyAuditAt = -1
        Log('SAFE_UI_QUEUE_ERROR ' .. tostring(why))
    end
end)
Log("Passive dropdown loaded with character-creation score preview.")
