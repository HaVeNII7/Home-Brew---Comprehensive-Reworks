

if _G.HB_NewGameSingleSaveLoaded then return end
if not Ext.UI or not Ext.UI.RegisterType or not Ext.UI.Instantiate or not Ext.StaticData then
    Ext.Utils.Print("[HB Single Save] Required UI/static-data APIs are unavailable.")
    return
end
_G.HB_NewGameSingleSaveLoaded = true

local SINGLE_SAVE = "8ed1fb00-91a5-437e-864d-6fb8113bc37e"
local CHECK_TYPE = "HB_NewGameSingleSaveCheck_v2"
local HOST_TYPE = "HB_NewGameSingleSaveActions_v3"
local pages = { DMSettings = true, NewGameSettings = true, NewGameSettings_c = true, HB_HonouredMyth_NewGameSettings = true,
    HB_HonouredMyth_NewGameSettings_c = true }
local metadata, resources, choices, applied, states = {}, {}, {}, {}, {}
local liveChecks, errors = {}, {}
local jobs, nextScan, lastUpdate, generation = {}, 0, -150, 0
local queued, warning, scanReady = false, nil, false
local getData = Ext.StaticData.Get or Ext.StaticData.GetGuidResource
local getAll = Ext.StaticData.GetAll or Ext.StaticData.GetAllGuidResources

local function Report(message)
    if warning == message then return end
    warning = message
    Ext.Utils.Print("[HB Single Save] " .. message)
end

local function OnUI(callback)
    local expected = generation
    local function Run()
        if expected ~= generation then return end
        local ok, reason = pcall(callback)
        if not ok then Report(tostring(reason)) end
    end
    if Ext.UI.Defer then Ext.UI.Defer(Run) else Run() end
end

local function Read(object, property)
    if not object then return nil end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return nil end
    if kind == "table" and not object.Type then return object[property] end
    local name = object.Type
    local fields = metadata[name]
    if not fields then
        fields = {}
        local info = object:TypeInfo()
        while info do
            for _, item in ipairs(info.Properties or {}) do fields[item.Name] = true end
            for _, item in ipairs(info.DependencyProperties or {}) do fields[item.Name] = true end
            info = info.Base
        end
        metadata[name] = fields
    end
    if fields[property] then return object[property] end
    return nil
end



local function PageName(widget)
    local filename = Read(widget, "FileName")
    if type(filename) == "string" then
        local name = filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
        if pages[name] then return name end
    end
    return Read(widget, "Name")
end

local function FindControl(widget, name)
    local found = widget:Find(name)
    if found then return found end
    local count = 0
    local function Search(node, depth)
        if not node or depth > 65 or count >= 5000 then return nil end
        count = count + 1
        if Read(node, "Name") == name then return node end
        for index = 1, node.VisualChildrenCount do
            local match = Search(node:VisualChild(index), depth + 1)
            if match then return match end
        end
        return nil
    end
    return Search(widget, 0)
end

local function Copy(values)
    local copy = {}
    for index = 1, #values do copy[index] = tostring(values[index]):lower() end
    return copy
end

local function Contains(values, guid)
    for index = 1, #values do if tostring(values[index]):lower() == guid then return true end end
    return false
end

local function ScanResources(now)
    if scanReady or now < nextScan then return end
    nextScan = now + 1000
    if not getData or not getAll or not getData(SINGLE_SAVE, "Ruleset") then return end
    local found = {}
    for _, guid in ipairs(getAll("RulesetSelectionPreset")) do
        local preset = getData(guid, "RulesetSelectionPreset")
        local asset = preset and preset.Asset
        if type(asset) == "string" and asset:match("^difficulty_0[1-7]$") then
            if found[asset] then error("Multiple presets use " .. asset .. "; refusing to change the wrong preset.") end
            local original = Copy(preset.Rulesets)
            found[asset] = { Guid = tostring(guid), Original = original, IsCustom = preset.IsCustom }
            if choices[asset] == nil then choices[asset] = asset == "difficulty_07" or Contains(original, SINGLE_SAVE) end
            applied[asset] = Contains(original, SINGLE_SAVE)
        end
    end
    if not found.difficulty_07 then return end
    resources, scanReady = found, true
end

local function ApplyRuleset(asset, enabled)
    local definition = resources[asset]
    if not definition then error("The selected difficulty has no matching preset resource.") end
    
    if asset == "difficulty_04" or asset == "difficulty_07" then return end
    local resource = getData(definition.Guid, "RulesetSelectionPreset")
    if not resource then error("The selected difficulty resource is unavailable.") end
    
    
    local rulesets = resource.Rulesets
    for index = #rulesets, 1, -1 do
        if tostring(rulesets[index]):lower() == SINGLE_SAVE then rulesets[index] = nil end
    end
    if enabled then rulesets[#rulesets + 1] = SINGLE_SAVE end
    if Contains(rulesets, SINGLE_SAVE) ~= enabled then
        error("The preset did not retain the requested Honour Mode setting.")
    end
end

local function QueueChoice(asset)
    if asset == "difficulty_04" or asset == "difficulty_07" or not resources[asset] then return end
    local enabled = choices[asset] == true
    if applied[asset] ~= enabled then
        
        
        jobs[asset] = { Asset = asset, Enabled = enabled, Generation = generation }
    else
        jobs[asset], errors[asset] = nil, nil
    end
end

local function CaptureFooter(state)
    local toggle = FindControl(state.Widget, "HB_SingleSaveToggle")
    local vm = toggle and Read(toggle, "DataContext")
    local asset = Read(vm, "HB_Asset")
    if type(asset) ~= "string" or not asset:match("^difficulty_0[1-7]$") or asset == "difficulty_04" or asset == "difficulty_07" then return end
    local enabled = Read(vm, "HB_Enabled") == true
    choices[asset] = enabled
    QueueChoice(asset)
end

local function SelectedPreset(state, fallback)
    local list = FindControl(state.Widget, "PresetList")
    local selected = list and Read(list, "SelectedItem")
    if selected then return selected end
    local presets = Read(state.Native, "Presets")
    local index = Read(state.Native, "PresetSelectedIndex")
    if presets and type(index) == "number" then return presets[index + 1] end
    return fallback
end

local function RefreshFooter(state, fallback, captured)
    if not captured then CaptureFooter(state) end
    local toggle = FindControl(state.Widget, "HB_SingleSaveToggle")
    if not toggle then return end
    local preset = SelectedPreset(state, fallback)
    local asset = Read(state.Native, "IsInCustomMode") == true and "difficulty_04" or Read(preset, "AssetName")
    local current = Read(toggle, "DataContext")
    if type(asset) ~= "string" or not asset:match("^difficulty_0[1-7]$") then
        if Read(current, "HB_Asset") then current.HB_Ready = false end
        return
    end
    local vm = state.Checks[asset]
    if not vm then
        vm = Ext.UI.Instantiate(CHECK_TYPE)
        vm.HB_Asset = asset
        state.Checks[asset] = vm
        liveChecks[tostring(vm)] = generation
    end
    
    vm.HB_Enabled = asset == "difficulty_07" or (asset ~= "difficulty_04" and choices[asset] == true)
    vm.HB_Ready = asset ~= "difficulty_04" and asset ~= "difficulty_07"
    vm.HB_Applied = asset == "difficulty_07" or (asset ~= "difficulty_04" and applied[asset] == true)
    if tostring(current) ~= tostring(vm) then toggle.DataContext = vm end
    if Read(state.Native, "IsInCustomMode") == true or vm.HB_Enabled == vm.HB_Applied then
        state.ViewModel.HB_SingleSaveStatus = ""
    else
        -- Normal asynchronous rule application is silent; real errors remain visible.
        state.ViewModel.HB_SingleSaveStatus = errors[asset] or ""
    end
end

Ext.UI.RegisterType(CHECK_TYPE, {
    HB_Asset = { Type = "String" }, HB_Ready = { Type = "Bool", Notify = true },
    HB_Applied = { Type = "Bool", Notify = true },
    HB_Enabled = { Type = "Bool", Notify = true, WriteCallback = function(vm)
        OnUI(function()
            if liveChecks[tostring(vm)] ~= generation then return end
            local asset = Read(vm, "HB_Asset")
            if type(asset) ~= "string" or asset == "difficulty_04" or asset == "difficulty_07" then return end
            choices[asset] = Read(vm, "HB_Enabled") == true
            QueueChoice(asset)
        end)
    end },
})

Ext.UI.RegisterType(HOST_TYPE, {
    HB_SelectSingleSave = { Type = "Command" }, HB_ToggleSingleSave = { Type = "Command" },
    HB_SingleSaveStatus = { Type = "String", Notify = true },
    HB_SingleSaveNative = { Type = "Object" },
})

local function BindActions(widget, native, host)
    local vm = Ext.UI.Instantiate(HOST_TYPE)
    local state = { Widget = widget, Native = native, Host = host, ViewModel = vm, Checks = {} }
    vm.HB_SingleSaveNative = native
    vm.HB_SingleSaveStatus = ""
    vm.HB_SelectSingleSave:SetHandler(function(_, preset)
        OnUI(function()
            if Read(widget, "IsVisible") == false or Read(native, "IsMainMenu") ~= true then return end
            RefreshFooter(state, preset)
        end)
    end)
    vm.HB_ToggleSingleSave:SetHandler(function(_, preset)
        OnUI(function()
            if Read(native, "IsMainMenu") ~= true or Read(native, "IsInCustomMode") == true then return end
            RefreshFooter(state, preset)
            local toggle = FindControl(widget, "HB_SingleSaveToggle")
            local check = toggle and Read(toggle, "DataContext")
            if Read(check, "HB_Ready") == true then
                check.HB_Enabled = not check.HB_Enabled
                CaptureFooter(state)
            end
        end)
    end)
    
    
    host.DataContext = vm
    return state
end

local function Update()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find("ContentRoot")
    if not content then states = {}; return end
    local seen = {}
    for index = 1, content.ChildrenCount do
        local widget = content:Child(index)
        local name = PageName(widget)
        if pages[name] and Read(widget, "IsVisible") ~= false then
            local key = tostring(widget)
            local context = Read(widget, "DataContext")
            local host = FindControl(widget, "HB_SingleSaveHost")
            local state = states[key]
            if state and (tostring(context) ~= tostring(state.Native)
                or not host or tostring(Read(host, "DataContext")) ~= tostring(state.ViewModel)) then state = nil end
            if context and host and Read(context, "IsMainMenu") == true then
                if not state then state = BindActions(widget, context, host) end
                seen[key] = state
                -- The same native New Game widget is the authoritative
                -- attachment point for the HomeBrew preset-picker command.
                -- DifficultyOrder's generic UI scan may miss this menu.
                if _G.HB_DifficultyOrder_BindMain then
                    local bound,reason=pcall(_G.HB_DifficultyOrder_BindMain,widget,context)
                    if not bound then Report("difficulty Adjust binding: "..tostring(reason)) end
                end
                CaptureFooter(state)
                RefreshFooter(state, nil, true)
            end
        end
    end
    states = seen
end

local MenuScope = Ext.Require("Client/MenuScope.lua")
local lastScopePoll, scopeOpen = -100000, false
local function DifficultyMenuVisible(now)
    if now - lastScopePoll >= (scopeOpen and 250 or 950) then
        lastScopePoll, scopeOpen = now, MenuScope.IsOpen('Difficulty')
    end
    return scopeOpen
end

Ext.Events.Tick:Subscribe(function()
    local now = Ext.Timer.MonotonicTime()
    -- Apply already queued explicit clicks, but do not poll static resources
    -- or refresh the new-game UI while that screen is closed.
    local menuVisible = DifficultyMenuVisible(now)
    if not menuVisible and next(jobs)==nil then return end
    if menuVisible then
        local ok, reason = pcall(ScanResources, now)
        if not ok then Report(tostring(reason)) end
    end
    -- Keep user-triggered jobs from being lost during a screen transition.
    local batch = jobs
    jobs = {}
    for _, job in pairs(batch) do
        if job.Generation == generation then
            local changed, failure = pcall(ApplyRuleset, job.Asset, job.Enabled)
            if not changed then
                Report(tostring(failure))
                errors[job.Asset] = "Honour Mode could not be applied. Toggle it off to keep the current setting."
            else
                applied[job.Asset], errors[job.Asset] = job.Enabled, nil
                OnUI(function()
                    for _, state in pairs(states) do
                        local check = state.Checks[job.Asset]
                        if check then check.HB_Applied = job.Enabled end
                    end
                end)
            end
        end
    end
    if not menuVisible then return end
    if queued or now - lastUpdate < 150 then return end
    lastUpdate, queued = now, true
    local expected = generation
    local function Run()
        if expected ~= generation then return end
        queued = false
        local updated, failure = pcall(Update)
        if not updated then Report(tostring(failure)) end
    end
    if Ext.UI.Defer then Ext.UI.Defer(Run) else Run() end
end)

Ext.Events.SessionLoaded:Subscribe(function()
    generation = generation + 1
    states, metadata, jobs, liveChecks, queued = {}, {}, {}, {}, false
    lastUpdate = -150
end)
