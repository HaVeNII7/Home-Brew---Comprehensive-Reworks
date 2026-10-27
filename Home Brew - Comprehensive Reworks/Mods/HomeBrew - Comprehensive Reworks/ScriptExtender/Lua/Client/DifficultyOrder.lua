local REPORT = "HomeBrew/Diagnostics/HB_DifficultyMenu_Diagnostics.txt"
local function SaveReport(text)
    if Ext.IO and Ext.IO.SaveFile then pcall(Ext.IO.SaveFile, REPORT, text) end
end
SaveReport("HomeBrew difficulty menu v37: client module entered\nUI API: " .. tostring(Ext.UI ~= nil))




if _G.HB_DifficultyOrderLoaded then return end
if not Ext.UI or not Ext.UI.GetRoot then
    SaveReport("HomeBrew difficulty menu v37: Noesis UI API unavailable")
    Ext.Utils.Print("[HB Difficulty Order] Noesis UI API unavailable; ordering was not changed.")
    return
end
_G.HB_DifficultyOrderLoaded = true

local interval = 75
local lastUpdate = -interval
local queued = false
local states = {}
local updateWarning = false
local lastFailure = ""
local lastAction = ""
local defer = Ext.UI.Defer
local browserAvailable = Ext.UI.RegisterType and Ext.UI.Instantiate and Ext.StaticData
local browserStates, catalog, generation, nextCatalog = {}, {}, 0, 0
-- Noesis Lua proxies may stringify differently between traversals of the same
-- live widget. Use an identity owned by the HomeBrew VM instead.
local HB_nextViewId = 0
local function HB_NewViewId()
    HB_nextViewId = HB_nextViewId + 1
    return "HB_DifficultyView_" .. tostring(HB_nextViewId)
end
local BROWSER = "HB_DifficultyBrowser_v5"
local CARD = "HB_DifficultyBrowserCard_v1"
local TEXT = "HB_DifficultyBrowserText_v1"
local MCM_ITEM = "HB_MCMPresetOption_v1"
local CUSTOM_CATEGORY = "HB_CustomCategory_v1"
local CUSTOM_SETTING = "HB_CustomSetting_v1"
local HB_ReconcileCustomSelection -- assigned after the editor helpers exist
local HB_CustomCatalog=Ext.Require("Shared/DifficultyCustomCatalog.lua")
local HB_PresetDetails=Ext.Require("Shared/DifficultyPresetDetails.lua")
local HB_MCM_names={
    "Default", "Hard", "Very Hard", "Ultra Hard", "HellBrew",
    "Expanded Party Size (Default)", "Expanded Party Size (Hard)",
    "Expanded Party Size (Raid)", "Maximum Difficulty", "Endurance", "Custom"
}
-- MCM has no general enum IsEnabled API. The server provides the real
-- campaign Single Save status; the UI exposes exactly the current preset
-- while locked, and restores the original 11 choices when unlocked.
-- Changing the MCM blueprint enum to Options.Dynamic=true is required.
local HB_Trace
local HB_mcmChoicesState=nil
local HB_mcmChoicesLastApplied=nil
local HB_mcmChoiceSyncWarned=false
-- The blueprint's seven HB tabs are gated behind this internal checkbox.
-- Hide by default and enable only after server-confirmed active campaign.
-- This does not interfere with other mods' MCM pages.
local HB_mcmCampaignConfirmed=false
-- SessionLoaded is authoritative even if the MCM campaign-choice reply has
-- not yet arrived; avoid traversing New Game UI during an active save.
local HB_activeGameSession=false
local HB_mcmAccessApplied=nil
local HB_MCM_ACCESS_SETTING="hb_mcm_campaign_active"
local function HB_ApplyMCMAccess()
    if not (MCM and MCM.Set) then return end
    if HB_mcmAccessApplied==HB_mcmCampaignConfirmed then return end
    -- No event: internal presentation flag is never a difficulty change.
    local ok,result=pcall(MCM.Set,HB_MCM_ACCESS_SETTING,HB_mcmCampaignConfirmed,nil,false)
    if ok and result~=false then
        HB_mcmAccessApplied=HB_mcmCampaignConfirmed
    end
end
local function HB_InvalidateMCMAccess()
    HB_mcmCampaignConfirmed=false
    HB_mcmAccessApplied=nil
    HB_mcmChoicesState="N"
    HB_mcmChoicesLastApplied=nil
    HB_ApplyMCMAccess()
end
local function HB_ApplyMCMChoiceState()
    if not HB_mcmChoicesState then return end
    HB_ApplyMCMAccess()
    if not (MCM and MCM.Enum and MCM.Enum.SetChoices) then
        if not HB_mcmChoiceSyncWarned then
            HB_mcmChoiceSyncWarned=true
            HB_Trace("MCM choices API unavailable; server edit guard still active")
        end
        return
    end
    if HB_mcmChoicesLastApplied==HB_mcmChoicesState then return end
    local choices=(HB_mcmChoicesState=="N" or HB_mcmChoicesState=="U") and HB_MCM_names
        or {HB_mcmChoicesState:sub(3)}
    local ok,result=pcall(MCM.Enum.SetChoices,"hb_difficulty_preset",choices)
    if ok and result~=false then
        HB_mcmChoicesLastApplied=HB_mcmChoicesState
        HB_Trace("MCM preset UI "..(HB_mcmChoicesState=="U" and "unlocked" or "locked"))
    else
        HB_Trace("MCM preset choices update failed "..tostring(result))
    end
end
if Ext.RegisterNetListener then
    Ext.RegisterNetListener("HB_Difficulty_MCMPresetChoices_V1",function(_,payload)
        if type(payload)~="string" then return end
        if payload~="U" and payload~="N" and not (payload:sub(1,2)=="L|"
            and #payload<=100 and (function()
                local name=payload:sub(3)
                for _,choice in ipairs(HB_MCM_names) do if name==choice then return true end end
                return false
            end)()) then return end
        HB_mcmChoicesState=payload
        HB_mcmCampaignConfirmed=(payload~="N")
        HB_mcmAccessApplied=nil
        HB_mcmChoicesLastApplied=nil
        HB_ApplyMCMAccess()
        HB_ApplyMCMChoiceState()
    end)
end
local function HB_RequestMCMChoiceState()
    if Ext.Net and Ext.Net.PostMessageToServer then
        pcall(Ext.Net.PostMessageToServer,"HB_Difficulty_MCMPresetChoices_Request_V1", "")
    end
end
if Ext.ModEvents and Ext.ModEvents.BG3MCM and Ext.ModEvents.BG3MCM.MCM_Window_Opened then
    Ext.ModEvents.BG3MCM.MCM_Window_Opened:Subscribe(function()
        HB_mcmAccessApplied=nil
        HB_ApplyMCMAccess()
        HB_mcmChoicesLastApplied=nil
        HB_ApplyMCMChoiceState()
        HB_RequestMCMChoiceState()
    end)
end
-- GameStateChanged is the documented SE lifecycle event for returning
-- to the main menu. Revoke when leaving a session, never wait for a new save.
if Ext.Events.GameStateChanged then
    Ext.Events.GameStateChanged:Subscribe(function(event)
        local nextState=tostring(event and event.ToState or "")
        if nextState=="UnloadSession" or nextState=="UnloadModule"
            or nextState=="Disconnect" or nextState=="LoadModule"
            or nextState=="MainMenu" then
            HB_activeGameSession=false
            HB_InvalidateMCMAccess()
            HB_ApplyMCMChoiceState()
        end
    end)
end
-- The client module can load before MCM is ready. Apply the safe default
-- as soon as the public MCM API becomes available, on a bounded cadence.
HB_InvalidateMCMAccess()
local HB_mcmAccessNextRetry=0
if Ext.Events.Tick and Ext.Timer and Ext.Timer.MonotonicTime then
    Ext.Events.Tick:Subscribe(function()
        local now=Ext.Timer.MonotonicTime()
        if now<HB_mcmAccessNextRetry then return end
        HB_mcmAccessNextRetry=now+1500
        HB_ApplyMCMAccess()
    end)
end
local HB_assetSent = nil
local HB_newGameCandidate = nil
local HB_mainMenuHighlighted = nil
local HB_mainMenuHighlightAt = 0
local HB_pendingNewGameArmed = false
local HB_startedGameAsset=nil
local HB_creationHiddenSince=nil
local HB_postCreationSent=false
local HB_difficultyTrace = {}
local HB_newGameAudit={}
local function HB_NewGameAudit(message)
    local line=tostring(message)
    HB_newGameAudit[#HB_newGameAudit+1]=line
    if #HB_newGameAudit>100 then table.remove(HB_newGameAudit,1) end
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile,"HomeBrew/Diagnostics/HB_NewGameCapture_Diagnostics.txt",
            table.concat(HB_newGameAudit,"\n").."\n")
    end
end
local HB_browserErrors={}
local function HB_BrowserError(message)
    local value=tostring(message)
    if HB_browserErrors[#HB_browserErrors]==value then return end
    HB_browserErrors[#HB_browserErrors+1]=value
    if #HB_browserErrors>30 then table.remove(HB_browserErrors,1) end
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile,"HomeBrew/Diagnostics/HB_DifficultyBrowser_Errors.txt",
            table.concat(HB_browserErrors,"\n").."\n")
    end
end
HB_Trace = function(message)
    local line="DIFFICULTY_INTEGRATION "..tostring(message)
    HB_difficultyTrace[#HB_difficultyTrace+1]=line
    if #HB_difficultyTrace>24 then table.remove(HB_difficultyTrace,1) end
    SaveReport("HomeBrew difficulty menu v37: diagnostics\n"..table.concat(HB_difficultyTrace,"\n").."\n")
    Ext.Utils.Print("[HB Difficulty Menu] "..line)
end
local function HB_SendGameAsset(asset,origin,retry)
    origin=origin or "live"
    local signature=origin..":"..tostring(asset)
    if type(asset)~="string" or asset=="difficulty_04" or (signature==HB_assetSent and not retry) then return end
    if not (asset:match("^difficulty_0[123567]$") and Ext.Net and Ext.Net.PostMessageToServer) then return end
    local ok, result=pcall(Ext.Net.PostMessageToServer,"HB_Difficulty_GameAsset_V1",signature)
    local sent=ok and result~=false
    if sent then HB_assetSent=signature end
    HB_Trace("send asset="..signature.." retry="..tostring(retry).." posted="..tostring(sent))
    if origin=="new" then HB_NewGameAudit("new-game network send "..signature.." success="..tostring(sent)) end
end
local order = { "difficulty_01", "difficulty_02", "difficulty_03", "difficulty_05", "difficulty_06", "difficulty_07", "difficulty_04" }
local titles = { difficulty_01 = "Explorer", difficulty_02 = "Adventurer", difficulty_03 = "Veteran",
    difficulty_04 = "Custom", difficulty_05 = "Heroic", difficulty_06 = "Mythic", difficulty_07 = "Deific" }
-- MCM preview follows the highlighted card only in the main-menu New Game
-- difficulty chooser. Existing loaded campaigns are never modified by browsing.
local HB_MAIN_MENU_MCM_PRESETS={
    difficulty_01="Default", difficulty_02="Hard", difficulty_03="Very Hard",
    difficulty_04="Custom", difficulty_05="Ultra Hard",
    difficulty_06="HellBrew", difficulty_07="HellBrew",
}
local HB_mainMenuLastPreview=nil
-- Explicit main-menu Adjust Difficulty choice overrides the automatic BG3
-- mapping only for the *same* highlighted difficulty card. Browsing to
-- another card discards the override, exactly like the normal preview.
local HB_mainMenuManualAsset, HB_mainMenuManualPreset=nil,nil
local HB_mainMenuLastFailure=nil
-- The front-end UI can be destroyed and its Lua VM rebuilt before gameplay.
-- Persist the verified preview so a genuine CharacterCreationFinished event can
-- promote it into a campaign's server-side, save-scoped MCM setting.
local HB_MAIN_MENU_PREVIEW_FILE="HomeBrew/Diagnostics/HB_MainMenuDifficultyPreview.txt"
-- Keep edited New Game Custom fields separate from the named-preset preview.
-- The server consumes this only after the verified new-character-creation handoff.
local HB_MAIN_MENU_CUSTOM_FILE="HomeBrew/Diagnostics/HB_MainMenuCustomPreview.json"
local HB_mainCustomFields={}
for _,category in ipairs(HB_CustomCatalog) do
    for _,field in ipairs(category.settings) do HB_mainCustomFields[field.id]=field end
end
local function HB_MainCustomValid(field,value)
    if not field then return false end
    if field.kind=="checkbox" then return type(value)=="boolean" end
    if field.kind=="slider_int" then
        return type(value)=="number" and value==math.floor(value)
            and value>=field.min and value<=field.max
    end
    if field.kind=="enum" and type(value)=="string" then
        for _,choice in ipairs(field.choices) do if choice==value then return true end end
    end
    return false
end
local function HB_ClearMainCustomPreview(reason)
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile,HB_MAIN_MENU_CUSTOM_FILE,"")
        HB_NewGameAudit("main-menu Custom edits cleared: "..tostring(reason))
    end
end
local function HB_WriteMainCustomPreview(asset,values)
    if not (Ext.IO and Ext.IO.SaveFile and Ext.IO.LoadFile and Ext.Json and Ext.Json.Stringify) then
        HB_NewGameAudit("main-menu Custom preview unavailable: IO/JSON API missing")
        return false
    end
    local count=0
    for id,value in pairs(values) do
        if not HB_MainCustomValid(HB_mainCustomFields[id],value) then
            HB_NewGameAudit("main-menu Custom preview rejected field="..tostring(id))
            return false
        end
        count=count+1
    end
    if count<1 or count>64 or not HB_MAIN_MENU_MCM_PRESETS[asset] then return false end
    local ok,payload=pcall(Ext.Json.Stringify,{Version=1,Asset=asset,Preset="Custom",Values=values})
    if not ok or type(payload)~="string" or #payload>12000 then return false end
    local wrote,result=pcall(Ext.IO.SaveFile,HB_MAIN_MENU_CUSTOM_FILE,payload)
    local readOK,readback=pcall(Ext.IO.LoadFile,HB_MAIN_MENU_CUSTOM_FILE)
    local saved=wrote and result~=false and readOK and readback==payload
    HB_NewGameAudit("main-menu Custom edit handoff staged asset="..asset
        .." count="..count.." verified="..tostring(saved))
    return saved
end
local HB_previewFileError=nil
local function HB_StoreMainMenuPreview(asset, override)
    local payload=override and (asset.."|"..override) or asset
    if not (Ext.IO and Ext.IO.SaveFile and Ext.IO.LoadFile) then
        if HB_previewFileError~="unavailable" then
            HB_NewGameAudit("front-end handoff file API unavailable")
            HB_previewFileError="unavailable"
        end
        return
    end
    local okCurrent,current=pcall(Ext.IO.LoadFile,HB_MAIN_MENU_PREVIEW_FILE)
    if okCurrent and current==payload then return end
    local wrote,result=pcall(Ext.IO.SaveFile,HB_MAIN_MENU_PREVIEW_FILE,payload)
    local readOK,observed=pcall(Ext.IO.LoadFile,HB_MAIN_MENU_PREVIEW_FILE)
    if wrote and result~=false and readOK and observed==payload then
        HB_previewFileError=nil
        HB_NewGameAudit("front-end handoff staged: "..asset)
    else
        local failure=tostring(result)..":"..tostring(observed)
        if HB_previewFileError~=failure then
            HB_NewGameAudit("front-end handoff stage FAILED: "..asset
                .." save="..tostring(wrote).." result="..tostring(result)
                .." readback="..tostring(observed))
            HB_previewFileError=failure
        end
    end
end
local function HB_ApplyMainMenuPreview(asset, source)
    local preset=HB_MAIN_MENU_MCM_PRESETS[asset]
    if not preset then return end
    if HB_mainMenuManualAsset and HB_mainMenuManualAsset~=asset then
        HB_NewGameAudit("main-menu card changed: cleared manual preset override")
        HB_ClearMainCustomPreview("difficulty card changed")
        HB_mainMenuManualAsset,HB_mainMenuManualPreset=nil,nil
    end
    if HB_mainMenuManualAsset==asset and HB_mainMenuManualPreset then
        -- A later periodic highlight probe must not silently revert the
        -- explicit Adjust Difficulty choice while this card remains selected.
        HB_StoreMainMenuPreview(asset,HB_mainMenuManualPreset)
        return
    end
    if not (MCM and MCM.Get and MCM.Set) then
        if HB_mainMenuLastFailure~="unavailable" then
            HB_NewGameAudit("main-menu MCM preview unavailable: MCM.Get/Set missing")
            HB_mainMenuLastFailure="unavailable"
        end
        return
    end
    local readOK,current=pcall(MCM.Get,"hb_difficulty_preset")
    if readOK and current==preset then
        HB_mainMenuLastPreview=asset
        HB_mainMenuLastFailure=nil
        HB_StoreMainMenuPreview(asset)
        return
    end
    -- Only write on a genuine main-menu selection; normal change events keep
    -- MCM's visible dropdown in sync. No new-game/server request is sent here.
    local wrote,result=pcall(MCM.Set,"hb_difficulty_preset",preset,nil,true)
    local checkOK,observed=pcall(MCM.Get,"hb_difficulty_preset")
    if wrote and result~=false and checkOK and observed==preset then
        HB_mainMenuLastPreview=asset
        HB_mainMenuLastFailure=nil
        HB_StoreMainMenuPreview(asset)
        HB_NewGameAudit("main-menu MCM preset preview "..asset.." -> "..preset
            .." source="..tostring(source).." verified=true")
    else
        local failure=tostring(asset)..":"..tostring(result)..":"..tostring(observed)
        if failure~=HB_mainMenuLastFailure then
            HB_NewGameAudit("main-menu MCM preset preview failed asset="..asset
                .." expected="..preset.." source="..tostring(source)
                .." call="..tostring(wrote).." result="..tostring(result)
                .." readback="..tostring(observed))
            HB_mainMenuLastFailure=failure
        end
    end
end
local pages = {
    DMSettings = true,
    NewGameSettings = true,
    NewGameSettings_c = true,
    HB_HonouredMyth_NewGameSettings = true,
    HB_HonouredMyth_NewGameSettings_c = true,
}

local function Read(object, property)
    local ok, value = pcall(function() return object[property] end)
    if ok then return value end
    return nil
end

local function FindControl(widget, name)
    -- Noesis widget handles are short-lived. An expired proxy is not a reason
    -- to abort the whole UI update before the browser state is committed.
    if not widget then return nil end
    local valid,found = pcall(function() return widget:Find(name) end)
    if valid and found then return found end
    local count = 0
    local function Search(node, depth)
        if not node or depth > 65 or count >= 5000 then return nil end
        count = count + 1
        if Read(node, "Name") == name then return node end
        for index = 1, (Read(node, "VisualChildrenCount") or 0) do
            local ok, child = pcall(function() return node:VisualChild(index) end)
            local match = ok and Search(child, depth + 1)
            if match then return match end
        end
    end
    return Search(widget, 0)
end

-- Defined after BindBrowser. Call it from UI-deferred callbacks to obtain
-- *current* handles, never the expired widget captured by a Tick probe.
local HB_FreshMainMenuPanel

-- New Game uses the live Single Save checkbox's own HB_Enabled value.
-- Deific is the one immutable native Single Save card; checking the asset here
-- covers the brief time before that checkbox's native view model is attached.
-- No HomeBrew scaling preset names are used as substitutes for Single Save.
local function HB_MainMenuSingleSaveSelected(widget,asset)
    if asset == "difficulty_07" then return true end
    local toggle=FindControl(widget,"HB_SingleSaveToggle")
    local check=Read(toggle,"DataContext")
    return Read(check,"HB_Enabled")==true
end

local function MenuWidgets()
    local root = Ext.UI.GetRoot()
    if not root then return {}, "No UI root" end
    local content = root:Find("ContentRoot") or root
    local menus, visited, nodes = {}, {}, 0
    local function Search(node, depth)
        if not node or depth > 65 or nodes >= 5000 then return end
        local key = tostring(node)
        if visited[key] then return end
        visited[key], nodes = true, nodes + 1
        if Read(node, "IsVisible") == false then return end
        local name = Read(node, "Name")
        local filename = Read(node, "FileName")
        local page = type(filename) == "string" and filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
        local context = Read(node, "DataContext")
        local typeName = tostring(Read(node, "Type"))
        if (pages[name] or pages[page] or typeName:match("UIWidget$")) and context and Read(context, "Presets") then
            menus[#menus + 1] = node
            return
        end
        for _, pair in ipairs({{"ChildrenCount", "Child"}, {"VisualChildrenCount", "VisualChild"}}) do
            local count = Read(node, pair[1])
            if type(count) == "number" then
                for index = 1, count do
                    local ok, child = pcall(function() return node[pair[2]](node, index) end)
                    if ok then Search(child, depth + 1) end
                end
            end
        end
    end
    Search(content, 0)
    return menus, "Searched UI nodes: " .. nodes
end

local function Localized(value, fallback)
    if not value or not Ext.Loca or not Ext.Loca.GetTranslatedString then return fallback end
    local handle = Read(value, "Handle")
    if handle then handle = Read(handle, "Handle") or handle end
    if not handle then return fallback end
    local result = Ext.Loca.GetTranslatedString(tostring(handle), fallback)
    return type(result) == "string" and result ~= "" and result or fallback
end



local function ScanCatalog(now)
    if not browserAvailable or now < nextCatalog then return end
    nextCatalog = now + 1000
    local get = Ext.StaticData.Get or Ext.StaticData.GetGuidResource
    local all = Ext.StaticData.GetAll or Ext.StaticData.GetAllGuidResources
    if not get or not all then return end
    local result = {}
    for _, guid in ipairs(all("RulesetSelectionPreset")) do
        local resource = get(guid, "RulesetSelectionPreset")
        local asset = resource and resource.Asset
        if titles[asset] then
            if result[asset] then error("Multiple difficulty presets use " .. asset) end
            result[asset] = { Title = Localized(resource.DisplayName, titles[asset]),
                Description = Localized(resource.Description, "") }
        end
    end
    catalog = result
end

local function OnUI(callback)
    local expected = generation
    local function Run()
        if expected ~= generation then return end
        local ok, reason = pcall(callback)
        if not ok then lastFailure = tostring(reason); Ext.Utils.Print("[HB Difficulty Browser] " .. lastFailure) end
    end
    if defer then defer(Run) else Run() end
end

local function LiveView(state, widget, context, host, vm)
    return { State = state, Widget = widget, Native = context, Host = host, Browser = vm }
end

local function WithLiveBrowser(key, callback)
    OnUI(function()
        local state = browserStates[key]
        if not state then return end
        -- Read commands against the already attached live VM first. A fresh
        -- Noesis tree traversal can miss the page intermittently, even while
        -- its controls remain visible and interactive.
        local now = Ext.Timer.MonotonicTime()
        if state.MenuKey == "in-game" and state.ActiveVM
            and state.ActiveWidget and state.ActiveHost and state.ActiveContext
            and Read(state.ActiveWidget, "IsVisible") ~= false
            and Read(state.ActiveContext, "IsMainMenu") == false
            and Read(state.ActiveVM, "HB_ViewToken") == key
            and Read(Read(state.ActiveHost, "DataContext"), "HB_ViewToken") == key then
            callback(LiveView(state, state.ActiveWidget, state.ActiveContext,
                state.ActiveHost, state.ActiveVM))
            return
        end
        for _, widget in ipairs(MenuWidgets()) do
            local context = Read(widget, "DataContext")
            if context and tostring(Read(context, "Type")):find("HB_NewGameSingleSaveSettings", 1, true) then
                context = Read(context, "HB_SingleSaveNative") or context
            end
            if Read(context, "IsMainMenu") == false and state.MenuKey == "in-game" then
                local host = FindControl(widget, "HB_DifficultyBrowserHost")
                local vm = Read(host, "DataContext")
                if vm and Read(vm, "HB_ViewToken") == key then
                    callback(LiveView(state, widget, context, host, vm))
                    return
                end
            end
        end
    end)
end

local function SelectedCard(view)
    local list = FindControl(view.Widget, "PresetList")
    local selected = Read(list, "SelectedItem")
    local asset = Read(selected, "AssetName")
    for index = 1, #view.Browser.HB_Presets do
        local card = view.Browser.HB_Presets[index]
        if card.AssetName == asset then return card, index - 1 end
    end
    local index = Read(list, "SelectedIndex")
    if type(index) == "number" then return view.Browser.HB_Presets[index + 1], index end
end

local function SyncSelection(view)
    if view.State.Initializing or view.State.MythicConfirmationPending then return end
    local vm, context = view.Browser, view.Native
    local card, index = SelectedCard(view)
    if index and Read(vm,"HB_SelectedIndex")~=index then vm.HB_SelectedIndex = index end
    if not card or not card.HB_CanApply or Read(view.Host, "Tag") == "SingleSave" then return end
    if Read(context, "IsMainMenu") ~= false or Read(context, "IsInCustomMode") == true
        or Read(context, "CanOnlyChangeCustomMode") == true then return end
    
    
    local presets = Read(context, "Presets")
    for index = 1, #presets do
        -- Distinct Lua proxy wrappers can represent the same native preset;
        -- their tostring() values are not a stable identity. The asset ID is.
        if Read(presets[index], "AssetName") == card.AssetName then
            if Read(context, "PresetSelectedIndex") ~= index - 1 then context.PresetSelectedIndex = index - 1 end
            return
        end
    end
end

if browserAvailable then
    local registered, reason = pcall(function()
    Ext.UI.RegisterType(TEXT, { Str = { Type = "String" } })
    Ext.UI.RegisterType(MCM_ITEM, { Name = { Type = "String" } })
    Ext.UI.RegisterType(CUSTOM_CATEGORY, { Name = { Type = "String" } })
    Ext.UI.RegisterType(CUSTOM_SETTING, { Name = { Type = "String" }, Display = { Type = "String", Notify = true }, Disabled = { Type = "Bool", Notify = true } })
    Ext.UI.RegisterType(CARD, {
        AssetName = { Type = "String" }, IsCustom = { Type = "Bool" },
        Title = { Type = "Object" }, Description = { Type = "Object" },
        HB_Native = { Type = "Object" }, HB_CanApply = { Type = "Bool" },
        HB_UnavailableText = { Type = "String" },
    })
    Ext.UI.RegisterType(BROWSER, {
        HB_ViewToken = { Type = "String" },
        HB_Presets = { Type = "Collection" }, HB_Ready = { Type = "Bool", Notify = true },
        HB_CustomOnly = { Type = "Bool", Notify = true },
        HB_InCustomView = { Type = "Bool", Notify = true },
        HB_OpenCustomView = { Type = "Command" },
        HB_CloseCustomView = { Type = "Command" },
        HB_MythicConfirmation = { Type = "Bool", Notify = true },
        HB_MythicConfirmationReady = { Type = "Bool", Notify = true },
        HB_CancelMythicCustom = { Type = "Command" },
        HB_ContinueMythicCustom = { Type = "Command" },
        HB_SelectionChanged = { Type = "Command" },
        HB_OpenMCM = { Type = "Command" },
        HB_OpenCustomMCM = { Type = "Command" },
        HB_OpenPresetDetails = { Type = "Command" },
        HB_ShowPresetDetails = { Type = "Bool", Notify = true },
        HB_CustomDetailMode = { Type = "Bool", Notify = true },
        HB_CustomEditMode = { Type = "Bool", Notify = true },
        HB_CustomDialogTitle = { Type = "String", Notify = true },
        HB_CustomDialogHelp = { Type = "String", Notify = true },
        HB_CustomCloseLabel = { Type = "String", Notify = true },
        HB_CustomReadOnlyValue = { Type = "String", Notify = true },
        HB_CustomOverlayOpen = { Type = "Bool", Notify = true },
        HB_CustomCategories = { Type = "Collection" },
        HB_CustomSettings = { Type = "Collection" },
        HB_CustomCategoryIndex = { Type = "Int32", Notify = true, WriteCallback = function(vm)
            local key=Read(vm,"HB_ViewToken")
            OnUI(function()
                WithLiveBrowser(key,function(view)
                    if HB_ReconcileCustomSelection then HB_ReconcileCustomSelection(view) end
                end)
            end)
        end },
        HB_CustomSettingIndex = { Type = "Int32", Notify = true, WriteCallback = function(vm)
            local key=Read(vm,"HB_ViewToken")
            OnUI(function()
                WithLiveBrowser(key,function(view)
                    if HB_ReconcileCustomSelection then HB_ReconcileCustomSelection(view) end
                end)
            end)
        end },
        HB_CustomIsSlider = { Type = "Bool", Notify = true },
        HB_CustomIsCheck = { Type = "Bool", Notify = true },
        HB_CustomIsEnum = { Type = "Bool", Notify = true },
        HB_CustomSliderEnabled = { Type = "Bool", Notify = true },
        HB_CustomSliderValue = { Type = "Double", Notify = true },
        HB_CustomSliderMin = { Type = "Double", Notify = true },
        HB_CustomSliderMax = { Type = "Double", Notify = true },
        HB_CustomCheckValue = { Type = "Bool", Notify = true },
        HB_CustomEnumName = { Type = "String", Notify = true },
        HB_CustomSelectedTitle = { Type = "String", Notify = true },
        HB_CustomSelectedDescription = { Type = "String", Notify = true },
        HB_CustomCategoryChanged = { Type = "Command" },
        HB_CustomSettingChanged = { Type = "Command" },
        HB_CustomValueChanged = { Type = "Command" },
        HB_CustomEnumPrev = { Type = "Command" },
        HB_CustomEnumNext = { Type = "Command" },
        HB_CustomConfirm = { Type = "Command" },
        HB_CustomCancel = { Type = "Command" },
        HB_MCMCancel = { Type = "Command" },
        HB_MCMConfirm = { Type = "Command" },
        HB_CaptureNewGame = { Type = "Command" },
        HB_CaptureCommittedDifficulty = { Type = "Command" },
        HB_MCMOverlayOpen = { Type = "Bool", Notify = true },
        HB_MCMPresets = { Type = "Collection" },
        HB_MCMSelectedIndex = { Type = "Int32", Notify = true },
        HB_AllowMCM = { Type = "Bool", Notify = true },
        HB_ShowMCMControls = { Type = "Bool", Notify = true },
        HB_ShowCustomMCM = { Type = "Bool", Notify = true },
        HB_SelectedIndex = { Type = "Int32", Notify = true },
    })
    end)
    if not registered then
        lastFailure = tostring(reason)
        browserAvailable = false
        Ext.Utils.Print("[HB Difficulty Browser] Using native menu: " .. tostring(reason))
    end
end

local function Text(value)
    local vm = Ext.UI.Instantiate(TEXT)
    vm.Str = value
    return vm
end

local function CardText(original, property, fallback)
    local value = Read(original, property)
    
    
    if type(value) ~= "string" then value = Read(value, "Str") end
    if type(value) ~= "string" or value == "" or value:match("^h%x%x%x%x%x%x%x%xg") then value = fallback end
    return Text(value)
end

local function CurrentMCMPreset()
    if MCM and MCM.Get then
        local ok,value=pcall(MCM.Get,"hb_difficulty_preset")
        if ok and type(value)=="string" then return value end
    end
    return "Default"
end

local function SyncCustomView(view)
    local state = view.State
    local vm, context = view.Browser, view.Native
    local nativeCustom = Read(context, "IsInCustomMode") == true
    if state.CustomRequested and nativeCustom then state.NativeCustomSeen = true end
    if state.NativeCustomSeen and not nativeCustom then
        state.CustomRequested, state.NativeCustomSeen = false, false
    end
    if Read(context, "CanOnlyChangeCustomMode") ~= true then
        vm.HB_InCustomView = state.CustomRequested == true or nativeCustom
    end
    vm.HB_CustomOnly = Read(context, "CanOnlyChangeCustomMode") == true and vm.HB_InCustomView
    if Read(view.Host, "Tag") == "SingleSave" then
        vm.HB_InCustomView, vm.HB_CustomOnly = false, false
    end
    if vm.HB_InCustomView then
        local list = FindControl(view.Widget, "PresetList")
        for index = 1, #vm.HB_Presets do
            if vm.HB_Presets[index].IsCustom then
                if state.Initializing then state.OpeningAsset, state.OpeningIndex = "difficulty_04", index - 1 end
                if list and Read(list, "SelectedIndex") ~= index - 1 then list.SelectedIndex = index - 1 end
                vm.HB_SelectedIndex = index - 1
                break
            end
        end
    end
    local mirror = FindControl(view.Widget, "HB_CustomViewMode")
    if mirror and Read(mirror, "IsChecked") ~= vm.HB_InCustomView then mirror.IsChecked = vm.HB_InCustomView end
    local customOnly = FindControl(view.Widget, "HB_CustomOnlyView")
    if customOnly and Read(customOnly, "IsChecked") ~= vm.HB_CustomOnly then customOnly.IsChecked = vm.HB_CustomOnly end
end

local function SelectOpeningCard(view)
    local state = view.State
    local list = FindControl(view.Widget, "PresetList")
    if not list then return false end
    if Read(list, "SelectedIndex") ~= state.OpeningIndex then list.SelectedIndex = state.OpeningIndex end
    view.Browser.HB_SelectedIndex = state.OpeningIndex
    local selected = Read(list, "SelectedItem")
    return Read(selected, "AssetName") == state.OpeningAsset
end

local function ChangeNativeCustomView(view, enabled)
    local command = Read(view.Native, "ChangeDisplayCustomSettingsCommand")
    if not command then error("Native Custom settings command unavailable") end
    local parameter = view.Widget:Resource(enabled and "TrueValue" or "FalseValue", true)
    if not parameter then error("Native Custom settings Boolean resource unavailable") end
    command:Execute(parameter)
    lastAction = (enabled and "Opened" or "Closed") .. " Custom; native mode: " .. tostring(Read(view.Native, "IsInCustomMode"))
end

local function CloseDifficultyMenu(view)
    local command = Read(view.Native, "CustomEvent")
    if not command then error("Native menu close command unavailable") end
    local parameter = view.Widget:Resource("HB_CloseWidgetParameter", true)
    if not parameter then error("Native menu close parameter unavailable") end
    lastAction = "Closed Custom difficulty menu"
    command:Execute(parameter)
end

local function CancelMythicConfirmation(view)
    view.State.MythicConfirmationPending = false
    view.Browser.HB_MythicConfirmation, view.Browser.HB_MythicConfirmationReady = false, false
    lastAction = "Cancelled Mythic-to-Custom confirmation"
end

local function SyncMythicConfirmation(view)
    local state, vm, context = view.State, view.Browser, view.Native
    if state.MythicConfirmationPending and (Read(view.Host, "Tag") == "SingleSave"
        or Read(context, "IsHost") == false or Read(context, "IsInCustomMode") == true
        or Read(context, "CanOnlyChangeCustomMode") == true or Read(context, "IsMainMenu") ~= false) then
        state.MythicConfirmationPending = false
    end
    vm.HB_MythicConfirmation = state.MythicConfirmationPending == true
    vm.HB_MythicConfirmationReady = vm.HB_MythicConfirmation
        and Ext.Timer.MonotonicTime() - (state.MythicConfirmationStarted or 0) >= interval
end

local function CanOpenCustom(view)
    if Read(view.Host, "Tag") == "SingleSave" or Read(view.Native, "IsHost") == false then return false end
    local card = SelectedCard(view)
    return card and card.IsCustom and card.HB_CanApply
end

local function OpenCustomView(view)
    if not CanOpenCustom(view) then return end
    local state, vm, context = view.State, view.Browser, view.Native
    state.Initializing = false
    state.CustomRequested = true
    state.NativeCustomSeen = Read(context, "IsInCustomMode") == true
    vm.HB_InCustomView = true
    SyncCustomView(view)
    if Read(context, "CanOnlyChangeCustomMode") ~= true then ChangeNativeCustomView(view, true) end
end

local function HB_ActiveCustomField(view)
    local st=view.State.CustomEditor
    if not st or not st.fields then return nil end
    return st.fields[(st.category or 1)] and st.fields[st.category].settings[st.setting or 1]
end
local function HB_CustomReadValue(field)
    if not field or not MCM or not MCM.Get then return nil end
    local ok,val=pcall(MCM.Get,field.id)
    if ok then return val end
end
local function HB_CustomPairedProfId(field)
    if not field or field.kind~="slider_int" or type(field.id)~="string" then return nil end
    if field.id:find("^hb_stats_") then
        local prof=field.id:gsub("^hb_stats_","hb_stats_prof_",1)
        if prof~=field.id and HB_mainCustomFields[prof] then return prof end
    elseif field.id:find("^hb_player_stats_") then
        local prof=field.id:gsub("^hb_player_stats_","hb_player_stats_prof_",1)
        if prof~=field.id and HB_mainCustomFields[prof] then return prof end
    end
    return nil
end
local function HB_CustomSliderActive(field, pending)
    local profId=HB_CustomPairedProfId(field)
    if not profId then return true end
    local value=pending and pending[profId]
    if value==nil then
        value=HB_CustomReadValue(HB_mainCustomFields[profId])
    end
    return value~=true
end
local function HB_CustomUpdateAvailability(view)
    local st=view.State.CustomEditor
    if not st then return end
    local cat=HB_CustomCatalog[st.category or 1]
    if not cat then return end
    local vm=view.Browser
    for i,field in ipairs(cat.settings) do
        local row=vm.HB_CustomSettings[i]
        if row then
            row.Disabled=field.kind=="slider_int" and not HB_CustomSliderActive(field,st.pending) or false
        end
    end
    local selected=HB_ActiveCustomField(view)
    -- Do not use `field and enabled or true` here: Lua replaces `false`
    -- with the fallback `true`, which kept every proficiency-locked slider live.
    if selected and selected.kind=="slider_int" then
        vm.HB_CustomSliderEnabled=HB_CustomSliderActive(selected,st.pending)
    else
        vm.HB_CustomSliderEnabled=true
    end
end
local function HB_CustomStoreVisible(view)
    local st=view.State.CustomEditor
    if not st or st.refreshing or st.readOnly then return end
    local f=HB_ActiveCustomField(view)
    if not f then return end
    local vm=view.Browser
    if f.kind=="slider_int" and not HB_CustomSliderActive(f,st.pending) then
        HB_CustomUpdateAvailability(view)
        return
    end
    local value
    if f.kind=="slider_int" then
        value=math.floor(math.max(f.min,math.min(f.max,tonumber(vm.HB_CustomSliderValue) or f.min))+0.5)
    elseif f.kind=="checkbox" then
        value=vm.HB_CustomCheckValue==true
    elseif f.kind=="enum" then
        value=f.choices[st.enumIndex or 1]
    end
    if value~=nil then
        st.pending[f.id]=value
        local shown=vm.HB_CustomSettings[st.setting or 1]
        if shown then
            shown.Display=type(value)=="boolean" and (value and "On" or "Off") or tostring(value)
        end
        if f.kind=="checkbox" then HB_CustomUpdateAvailability(view) end
    end
end
local function HB_CustomFillSettings(view)
    local st=view.State.CustomEditor
    if not st then return end
    local vm=view.Browser
    st.refreshing=true
    for i=#vm.HB_CustomSettings,1,-1 do vm.HB_CustomSettings[i]=nil end
    local cat=HB_CustomCatalog[st.category or 1]
    if cat then
        for _,field in ipairs(cat.settings) do
            local item=Ext.UI.Instantiate(CUSTOM_SETTING)
            item.Name=field.name
            local value=st.pending[field.id]
            if value==nil then value=HB_CustomReadValue(field) end
            item.Display=type(value)=="boolean" and (value and "On" or "Off") or tostring(value or "")
            item.Disabled=field.kind=="slider_int" and not HB_CustomSliderActive(field,st.pending) or false
            vm.HB_CustomSettings[#vm.HB_CustomSettings+1]=item
        end
    end
    st.setting=1
    vm.HB_CustomSettingIndex=0
    st.refreshing=false
end
local function HB_CustomLoadField(view)
    local st=view.State.CustomEditor
    if not st then return end
    local vm=view.Browser
    local field=HB_ActiveCustomField(view)
    st.refreshing=true
    vm.HB_CustomIsSlider=field and field.kind=="slider_int" or false
    vm.HB_CustomIsCheck=field and field.kind=="checkbox" or false
    vm.HB_CustomIsEnum=field and field.kind=="enum" or false
    if field and field.kind=="slider_int" then
        vm.HB_CustomSliderEnabled=HB_CustomSliderActive(field,st.pending)
    else
        vm.HB_CustomSliderEnabled=true
    end
    vm.HB_CustomSelectedTitle=field and field.name or ""
    vm.HB_CustomSelectedDescription=field and field.description or ""
    if st.readOnly then
        local value=field and st.pending[field.id]
        vm.HB_CustomReadOnlyValue=type(value)=="boolean" and (value and "On" or "Off") or tostring(value or "")
    end
    if field then
        local v=st.pending[field.id]
        if v==nil then v=HB_CustomReadValue(field) end
        if field.kind=="slider_int" then
            vm.HB_CustomSliderMin=field.min;vm.HB_CustomSliderMax=field.max
            vm.HB_CustomSliderValue=tonumber(v) or field.min
        elseif field.kind=="checkbox" then
            vm.HB_CustomCheckValue=v==true
        elseif field.kind=="enum" then
            local index=1
            for i,choice in ipairs(field.choices) do if choice==v then index=i;break end end
            st.enumIndex=index; vm.HB_CustomEnumName=field.choices[index]
        end
    end
    st.refreshing=false
end
HB_ReconcileCustomSelection=function(view)
    local st=view.State.CustomEditor
    if not st or st.refreshing or not view.Browser.HB_CustomOverlayOpen then return end
    local vm=view.Browser
    local categoryIndex=tonumber(Read(vm,"HB_CustomCategoryIndex"))
    local categoryList=FindControl(view.Widget,"HB_CustomCategoriesList")
    local liveCategory=tonumber(Read(categoryList,"SelectedIndex"))
    if liveCategory and liveCategory>=0 and HB_CustomCatalog[liveCategory+1] then
        categoryIndex=liveCategory
    end
    if categoryIndex and categoryIndex>=0 and HB_CustomCatalog[categoryIndex+1]
       and categoryIndex+1~=st.category then
        HB_CustomStoreVisible(view)
        st.category=categoryIndex+1
        HB_CustomFillSettings(view)
        HB_CustomLoadField(view)
        HB_Trace("Native Custom category selected "..tostring(st.category))
        return
    end
    local settingIndex=tonumber(Read(vm,"HB_CustomSettingIndex"))
    local settingList=FindControl(view.Widget,"HB_CustomSettingsList")
    local liveSetting=tonumber(Read(settingList,"SelectedIndex"))
    if liveSetting and liveSetting>=0 and HB_CustomCatalog[st.category].settings[liveSetting+1] then
        settingIndex=liveSetting
    end
    if settingIndex and settingIndex>=0 and HB_CustomCatalog[st.category].settings[settingIndex+1]
       and settingIndex+1~=st.setting then
        HB_CustomStoreVisible(view)
        st.setting=settingIndex+1
        HB_CustomLoadField(view)
        HB_Trace("Native Custom setting selected "..tostring(st.category)..":"..tostring(st.setting))
    end
end
local function HB_CustomStart(view, detailsPreset)
    local values=detailsPreset and HB_PresetDetails.ValuesFor(detailsPreset,HB_CustomCatalog)
    if detailsPreset and not values then return false end
    local st={pending=values or {},category=1,setting=1,refreshing=false,
        fields=HB_CustomCatalog,readOnly=detailsPreset~=nil}
    view.State.CustomEditor=st
    local vm=view.Browser
    vm.HB_CustomDetailMode=st.readOnly
    vm.HB_CustomEditMode=not st.readOnly
    vm.HB_CustomDialogTitle=st.readOnly and ("Difficulty Details - "..detailsPreset) or "Custom Difficulty Settings"
    vm.HB_CustomDialogHelp=st.readOnly and "Values are based on your currently selected difficulty preset. Select \"Custom\" to manually adjust each value."
        or "Choose a category and setting, then adjust its value. Confirm saves all changes."
    vm.HB_CustomCloseLabel=st.readOnly and "Back" or "Cancel"
    for i=#vm.HB_CustomCategories,1,-1 do vm.HB_CustomCategories[i]=nil end
    for _,cat in ipairs(HB_CustomCatalog) do
        local item=Ext.UI.Instantiate(CUSTOM_CATEGORY);item.Name=cat.name
        vm.HB_CustomCategories[#vm.HB_CustomCategories+1]=item
    end
    vm.HB_CustomCategoryIndex=0
    HB_CustomFillSettings(view)
    HB_CustomLoadField(view)
    vm.HB_CustomOverlayOpen=true
    return true
end

local function BindBrowser(state, widget, context, presets)
    if not browserAvailable then return end
    local host = FindControl(widget, "HB_DifficultyBrowserHost")
    if not host then
        if Read(context,"IsMainMenu")==true then
            HB_NewGameAudit("main-menu native panel found but HB_DifficultyBrowserHost is absent")
        end
        return
    end
    local existing = Read(host, "DataContext")
    local existingKey = Read(existing,"HB_ViewToken")
    state.MenuKey = Read(context,"IsMainMenu")==true and "main-menu" or "in-game"
    state.LastSeenAt = Ext.Timer.MonotonicTime()
    state.ActiveWidget, state.ActiveContext, state.ActiveHost = widget, context, host
    -- The XAML host can present a new Lua proxy or temporarily lose its
    -- assigned DataContext during native layout. Reattach the existing VM
    -- instead of allocating a new one and resetting the carousel every poll.
    if existingKey ~= state.BrowserKey and state.BrowserKey and state.ActiveVM
        and Read(state.ActiveVM,"HB_ViewToken") == state.BrowserKey then
        host.DataContext = state.ActiveVM
        existing = Read(host,"DataContext")
        existingKey = Read(existing,"HB_ViewToken")
        if existingKey == state.BrowserKey and not state.ReattachReported then
            state.ReattachReported = true
            HB_Trace("restored existing difficulty browser VM after native host rebind: "..existingKey)
        end
    end
    local main = Read(context, "IsMainMenu") ~= false
    if main then
        local list=FindControl(widget,"PresetList")
        local item=Read(list,"SelectedItem")
        local asset=Read(item,"AssetName")
        if type(asset)=="string" and HB_MAIN_MENU_MCM_PRESETS[asset] then
            HB_mainMenuHighlighted=asset
            HB_mainMenuHighlightAt=Ext.Timer.MonotonicTime()
            if Read(context,"IsMainMenu")==true then
                HB_ApplyMainMenuPreview(asset,"browser")
            end
        end
        local vm = existingKey and existingKey == state.BrowserKey and existing
        if not vm then
            vm = Ext.UI.Instantiate(BROWSER)
            vm.HB_ViewToken = HB_NewViewId()
            state.BrowserKey = vm.HB_ViewToken
            state.ActiveVM = vm
            host.DataContext = vm
        end
        vm.HB_CustomOnly = Read(context, "CanOnlyChangeCustomMode") == true
        state.ActiveVM = vm
        -- The same native preset dialog used in-game is available before
        -- starting a campaign. Only its final Confirm changes the preview.
        -- This branch previously created a reduced VM with no MCM handlers.
        browserStates[Read(vm,"HB_ViewToken")]=state
        -- No campaign host exists yet on some front-end New Game screens.
        -- Requiring IsHost there can suppress the picker even after its VM
        -- finally attaches. Single Save remains guarded by HB_AllowMCM.
        vm.HB_ShowMCMControls = Read(context,"IsMainMenu")==true
        -- In New Game, the host Tag is not populated by the in-game ruleset
        -- trigger. Read the actual selected checkbox instead, including Deific.
        vm.HB_AllowMCM = not HB_MainMenuSingleSaveSelected(widget,asset)
        if not vm.HB_AllowMCM then
            vm.HB_MCMOverlayOpen=false
            -- Single Save locks editing, but the preset-details viewer is read-only.
            if not (state.CustomEditor and state.CustomEditor.readOnly) then
                vm.HB_CustomOverlayOpen=false
                state.CustomEditor=nil
            end
        end
        -- Custom editing can be staged on the front end; Confirm writes it to
        -- an asset-scoped handoff, which the server verifies after new-game creation.
        vm.HB_ShowCustomMCM = vm.HB_ShowMCMControls and vm.HB_AllowMCM
            and CurrentMCMPreset()=="Custom"
        vm.HB_ShowPresetDetails = vm.HB_ShowMCMControls
            and HB_PresetDetails.Presets[CurrentMCMPreset()]~=nil
        if #vm.HB_MCMPresets==0 then
            for _,name in ipairs(HB_MCM_names) do
                local row=Ext.UI.Instantiate(MCM_ITEM)
                row.Name=name
                vm.HB_MCMPresets[#vm.HB_MCMPresets+1]=row
            end
        end
        -- A main-menu button can run before the in-game MenuWidgets traversal
        -- recognizes NewGameSettings. Keep command dispatch local to the native
        -- widget that created the command, and reject a disposed/replaced VM.
        -- Main-menu XAML widgets can expire between mouse input and the next
        -- deferred frame. These preset-dialog controls are *owned by this VM*;
        -- opening or closing the overlay needs no second native-widget scan.
        -- Commands execute only while the UI has this attached VM.
        -- Capture the identity while installing the handler. Noesis may
        -- invalidate the Lua proxy's HB_ViewToken getter even though the
        -- command is still invoked by the *current*, visible native button.
        -- The old click-time getter then returned nil and rejected every
        -- click as "VM was superseded" (verified in HB_NewGameCapture logs).
        local handlerToken=state.BrowserKey
        local function WithMainBrowser(callback)
            -- This check is entirely Lua-owned and remains valid even if the
            -- native VM proxy is rematerialized between UI frames. A genuinely
            -- superseded view still cannot operate the newly opened screen.
            if not handlerToken or state.BrowserKey~=handlerToken
                or states["main-menu"]~=state then
                HB_NewGameAudit("main-menu preset command refused: handler was replaced"
                    .." handler="..tostring(handlerToken)
                    .." active="..tostring(state.BrowserKey))
                return
            end
            local live=state.ActiveVM or vm
            if Read(live,"HB_AllowMCM")==nil or Read(live,"HB_ShowMCMControls")==nil then
                -- A command can remain callable after its originally captured
                -- native proxy expires. Reacquire the *currently attached* VM
                -- synchronously while the button is being pressed; never defer
                -- this lookup to another frame where the widget can expire.
                local freshWidget=HB_FreshMainMenuPanel and HB_FreshMainMenuPanel()
                local freshHost=freshWidget and FindControl(freshWidget,"HB_DifficultyBrowserHost")
                local attached=Read(freshHost,"DataContext")
                if Read(attached,"HB_AllowMCM")~=nil
                    and Read(attached,"HB_ShowMCMControls")~=nil then
                    live=attached
                    state.ActiveVM=attached
                    state.ActiveHost=freshHost
                    HB_NewGameAudit("main-menu preset command recovered current attached VM"
                        .." handler="..handlerToken)
                else
                    HB_NewGameAudit("main-menu preset command refused: attached VM unavailable"
                        .." handler="..handlerToken)
                    return
                end
            end
            -- Revalidate on the click, not merely at the last UI refresh.
            -- If the view was disposed, the last observed Deific asset still
            -- fails closed while the native XAML disables the button directly.
            local fresh=HB_FreshMainMenuPanel and HB_FreshMainMenuPanel()
            local currentWidget=fresh or state.ActiveWidget
            local selected=Read(Read(FindControl(currentWidget,"PresetList"),"SelectedItem"),"AssetName")
                or HB_mainMenuHighlighted
            local locked=HB_MainMenuSingleSaveSelected(currentWidget,selected)
            live.HB_AllowMCM=not locked
            if locked then
                live.HB_MCMOverlayOpen=false
                if not (state.CustomEditor and state.CustomEditor.readOnly) then
                    live.HB_CustomOverlayOpen=false
                    state.CustomEditor=nil
                end
                HB_NewGameAudit("main-menu difficulty editor locked: Single Save active")
            end
            local ok,err=pcall(callback,live,state)
            if not ok then HB_NewGameAudit("main-menu preset command failed: "..tostring(err)) end
        end
        if state.MainHandlersKey ~= handlerToken then
          state.MainHandlersKey = handlerToken
          HB_NewGameAudit("main-menu difficulty commands bound to live native widget")
          vm.HB_OpenMCM:SetHandler(function()
            HB_NewGameAudit("main-menu Adjust Difficulty pressed handler="..tostring(handlerToken)
                .." liveToken="..tostring(Read(vm,"HB_ViewToken")))
            WithMainBrowser(function(browser)
                if not browser.HB_AllowMCM or not browser.HB_ShowMCMControls then
                    HB_NewGameAudit("main-menu preset dialog refused by Single Save")
                    return
                end
                if browser.HB_MCMOverlayOpen then return end
                local current=CurrentMCMPreset()
                for i,name in ipairs(HB_MCM_names) do
                    if name==current then browser.HB_MCMSelectedIndex=i-1;break end
                end
                browser.HB_MCMOverlayOpen=true
                HB_NewGameAudit("native main-menu preset dialog opened: "..current
                    .." visible="..tostring(Read(browser,"HB_MCMOverlayOpen")))
            end)
        end)
          vm.HB_MCMCancel:SetHandler(function()
            WithMainBrowser(function(browser)
                browser.HB_MCMOverlayOpen=false
            end)
        end)
          vm.HB_MCMConfirm:SetHandler(function()
            WithMainBrowser(function(browser)
                if not browser.HB_MCMOverlayOpen or not browser.HB_AllowMCM then return end
                -- Read the selected preset from the same bound VM as the list,
                -- rather than a new (possibly expired) Noesis tree proxy.
                local index=tonumber(Read(browser,"HB_MCMSelectedIndex"))
                local selected=index and HB_MCM_names[index+1]
                local selectedCard=HB_mainMenuHighlighted
                if not HB_MAIN_MENU_MCM_PRESETS[selectedCard] or not selected then
                    HB_NewGameAudit("native main-menu preset confirm failed: card="
                        ..tostring(selectedCard).." index="..tostring(index))
                    return
                end
                if not (MCM and MCM.Set and MCM.Get) then return end
                local ok,result=pcall(MCM.Set,"hb_difficulty_preset",selected,nil,true)
                local readOK,value=pcall(MCM.Get,"hb_difficulty_preset")
                if not ok or result==false or not readOK or value~=selected then
                    HB_NewGameAudit("native main-menu MCM preset write failed: "..tostring(selected)
                        .." result="..tostring(result).." readback="..tostring(value))
                    return
                end
                HB_mainMenuManualAsset,HB_mainMenuManualPreset=selectedCard,selected
                if selected~="Custom" then HB_ClearMainCustomPreview("named preset selected") end
                HB_StoreMainMenuPreview(selectedCard,selected)
                browser.HB_MCMOverlayOpen=false
                browser.HB_ShowCustomMCM=browser.HB_ShowMCMControls
                    and browser.HB_AllowMCM and selected=="Custom"
                HB_NewGameAudit("native main-menu preset override: "..selectedCard.." -> "..selected)
            end)
        end)
          -- Main-menu Custom Settings uses the same tested native editor as
          -- in-game. Its Confirm writes validated client MCM values AND a
          -- verified handoff file; it must not send an in-game server RPC.
          local function WithMainCustom(callback)
              WithMainBrowser(function(browser,activeState)
                  local liveWidget,liveContext=HB_FreshMainMenuPanel and HB_FreshMainMenuPanel()
                  liveWidget=liveWidget or activeState.ActiveWidget
                  liveContext=liveContext or activeState.ActiveContext
                  local liveHost=liveWidget and FindControl(liveWidget,"HB_DifficultyBrowserHost")
                  liveHost=liveHost or activeState.ActiveHost
                  if not liveWidget then
                      HB_NewGameAudit("main-menu Custom editor: native panel unavailable")
                      return
                  end
                  callback(LiveView(activeState,liveWidget,liveContext,liveHost,browser))
              end)
          end
          vm.HB_OpenCustomMCM:SetHandler(function()
              WithMainCustom(function(view)
                  if not view.Browser.HB_AllowMCM or CurrentMCMPreset()~="Custom"
                      or view.Browser.HB_CustomOverlayOpen then return end
                  if not HB_MAIN_MENU_MCM_PRESETS[HB_mainMenuHighlighted] then return end
                  HB_CustomStart(view)
                  HB_NewGameAudit("main-menu Custom editor opened asset="..HB_mainMenuHighlighted)
              end)
          end)
          vm.HB_OpenPresetDetails:SetHandler(function()
              WithMainCustom(function(view)
                  local preset=CurrentMCMPreset()
                  if not view.Browser.HB_ShowMCMControls or view.Browser.HB_CustomOverlayOpen
                      or view.Browser.HB_MCMOverlayOpen or not HB_PresetDetails.Presets[preset] then return end
                  if HB_CustomStart(view,preset) then
                      HB_NewGameAudit("main-menu difficulty details viewed: "..preset)
                  end
              end)
          end)
          vm.HB_CustomCategoryChanged:SetHandler(function()
              WithMainCustom(HB_ReconcileCustomSelection)
          end)
          vm.HB_CustomSettingChanged:SetHandler(function()
              WithMainCustom(HB_ReconcileCustomSelection)
          end)
          vm.HB_CustomValueChanged:SetHandler(function()
              WithMainCustom(function(view)
                  if view.State.CustomEditor and view.Browser.HB_CustomOverlayOpen then
                      HB_CustomStoreVisible(view)
                  end
              end)
          end)
          local function MainCycleEnum(step)
              WithMainCustom(function(view)
                  local st=view.State.CustomEditor
                  local field=HB_ActiveCustomField(view)
                  if not st or st.readOnly or not field or field.kind~="enum" then return end
                  st.enumIndex=math.max(1,math.min(#field.choices,(st.enumIndex or 1)+step))
                  view.Browser.HB_CustomEnumName=field.choices[st.enumIndex]
                  HB_CustomStoreVisible(view)
              end)
          end
          vm.HB_CustomEnumPrev:SetHandler(function() MainCycleEnum(-1) end)
          vm.HB_CustomEnumNext:SetHandler(function() MainCycleEnum(1) end)
          vm.HB_CustomCancel:SetHandler(function()
              WithMainBrowser(function(browser,activeState)
                  activeState.CustomEditor=nil
                  browser.HB_CustomOverlayOpen=false
                  HB_NewGameAudit("main-menu Custom editor canceled")
              end)
          end)
          vm.HB_CustomConfirm:SetHandler(function()
              WithMainCustom(function(view)
                  local editor=view.State.CustomEditor
                  local asset=HB_mainMenuHighlighted
                  if not editor or editor.readOnly or not view.Browser.HB_CustomOverlayOpen
                      or not view.Browser.HB_AllowMCM or CurrentMCMPreset()~="Custom"
                      or not HB_MAIN_MENU_MCM_PRESETS[asset] then return end
                  HB_CustomStoreVisible(view)
                  local changes={}
                  for id,value in pairs(editor.pending) do changes[id]=value end
                  -- Match the in-game server editor's proficiency-versus-fixed
                  -- bonus exclusion immediately on the frontend as well.
                  for id,value in pairs(editor.pending) do
                      if value==true and (id:find("^hb_stats_prof_")
                          or id:find("^hb_player_stats_prof_")) then
                          local slider=id:gsub("_prof_","_",1)
                          if HB_mainCustomFields[slider] then changes[slider]=0 end
                      end
                  end
                  for id,value in pairs(editor.pending) do
                      if type(value)=="number" and value>0
                          and (id:find("^hb_stats_") or id:find("^hb_player_stats_"))
                          and not id:find("_prof_") then
                          local prof=id:gsub("_stats_","_stats_prof_",1)
                          if HB_mainCustomFields[prof] and changes[prof]~=true then
                              changes[prof]=false
                          end
                      end
                  end
                  if not next(changes) then
                      view.State.CustomEditor=nil
                      view.Browser.HB_CustomOverlayOpen=false
                      return
                  end
                  if not (MCM and MCM.Get and MCM.Set) then return end
                  -- MCM settings should reflect the confirmed choices while
                  -- still on New Game. Preserve prior values for failed writes.
                  local previous={}
                  for id,value in pairs(changes) do
                      if not HB_MainCustomValid(HB_mainCustomFields[id],value) then return end
                      local ok,old=pcall(MCM.Get,id)
                      if not ok or old==nil then
                          HB_NewGameAudit("main-menu Custom cannot read prior "..id)
                          return
                      end
                      previous[id]=old
                  end
                  -- Only stage a server handoff if the entire validated edit
                  -- fits and round-trips through the shared preview file.
                  if not HB_WriteMainCustomPreview(asset,changes) then return end
                  local success=true
                  for id,value in pairs(changes) do
                      local wrote,result=pcall(MCM.Set,id,value,nil,true)
                      local readOK,live=pcall(MCM.Get,id)
                      if not wrote or result==false or not readOK or live~=value then
                          success=false
                          HB_NewGameAudit("main-menu Custom MCM write failed: "..id)
                          break
                      end
                  end
                  if not success then
                      for id,old in pairs(previous) do pcall(MCM.Set,id,old,nil,true) end
                      HB_ClearMainCustomPreview("write failed")
                      return
                  end
                  HB_mainMenuManualAsset,HB_mainMenuManualPreset=asset,"Custom"
                  HB_StoreMainMenuPreview(asset,"Custom")
                  view.State.CustomEditor=nil
                  view.Browser.HB_CustomOverlayOpen=false
                  HB_NewGameAudit("main-menu Custom edits confirmed: "..tostring(#(Ext.Json.Stringify(changes))))
              end)
          end)
          vm.HB_CaptureNewGame:SetHandler(function()
            -- Capture synchronously: StartNewGame can dispose the menu before a
            -- deferred UI lookup runs, leaving no saved selection for SessionLoaded.
            local liveWidget,liveContext=HB_FreshMainMenuPanel and HB_FreshMainMenuPanel()
            local list=liveWidget and FindControl(liveWidget,"PresetList")
            local selected=Read(Read(list,"SelectedItem"),"AssetName")
            if not selected then
                local i=Read(liveContext,"PresetSelectedIndex")
                local items=Read(liveContext,"Presets")
                if type(i)=="number" and items then
                    selected=Read(items[i+1],"AssetName")
                end
            end
            if type(selected)=="string" and selected:match("^difficulty_0[123567]$") then
                HB_newGameCandidate=selected
                HB_Trace("new-game Start click captured "..selected)
                HB_NewGameAudit("native Start button accepted: "..selected)
            else
                HB_Trace("new-game Start click no asset="..tostring(selected))
            end
        end)
        end -- install main-menu handlers only once per live browser VM
        vm.HB_Ready = true
        return
    end
    if Read(context, "HasBeenInitialized") == false then return end
    if not state.BrowserSignature then state.OpenedInCustom = Read(context, "IsInCustomMode") == true end
    local signature, native = {}, {}
    for index = 1, #presets do
        local preset = presets[index]
        local asset = Read(preset, "AssetName")
        if titles[asset] then native[asset] = preset end
        -- UI proxy tostring() can differ between reads of the same native
        -- preset, making the browser look changed every 75ms. Only the ordered
        -- content matters; widget/VM replacement is checked separately.
        signature[#signature + 1] = tostring(asset)
    end
    -- Catalog localization may resolve after the UI opens. Descriptive text
    -- must not be part of browser identity or an otherwise identical menu
    -- will be destroyed and rebuilt while the user is navigating it.
    signature = table.concat(signature, "|")
    if state.BrowserSignature == signature and existingKey == state.BrowserKey then
        -- Observe committed native changes, not temporary selection highlights.
        local committed = Read(Read(context,"CurrentPreset"),"AssetName")
        if type(committed)=="string" and committed~=state.CampaignAsset
            and committed:match("^difficulty_0[123567]$") then
            state.CampaignAsset=committed
            existing.HB_AllowMCM = Read(host, "Tag") ~= "SingleSave"
            HB_Trace("native difficulty changed while menu open: "..committed.." (waiting for explicit Confirm)")
        end
        existing.HB_ShowMCMControls = Read(context, "IsMainMenu") == false and Read(context, "IsHost") ~= false
        existing.HB_AllowMCM = Read(host, "Tag") ~= "SingleSave"
        existing.HB_ShowCustomMCM = existing.HB_ShowMCMControls and existing.HB_AllowMCM and CurrentMCMPreset()=="Custom"
        existing.HB_ShowPresetDetails = existing.HB_ShowMCMControls
            and HB_PresetDetails.Presets[CurrentMCMPreset()]~=nil
        local view = LiveView(state, widget, context, host, existing)
        if existing.HB_CustomOverlayOpen and HB_ReconcileCustomSelection then
            HB_ReconcileCustomSelection(view)
        end
        if state.Initializing then
            -- A native list may not expose the matching selected item during
            -- its first Noesis layout passes. Never keep forcing the opening
            -- index indefinitely: that would reset scrolling and consume all
            -- player selection commands every time this update runs.
            state.OpeningAttempts = (state.OpeningAttempts or 0) + 1
            state.OpeningPasses = SelectOpeningCard(view) and state.OpeningPasses + 1 or 0
            if state.OpeningPasses >= 2 or state.OpeningAttempts >= 4 then
                if state.OpeningPasses < 2 then
                    HB_Trace("opening selection did not stabilize; releasing player navigation")
                end
                state.Initializing = false
            end
        end
        SyncMythicConfirmation(view)
        -- Only user-driven HB_SelectionChanged synchronizes the selected
        -- HomeBrew card to BG3's native preset index. Repeated polling must
        -- never force-scroll or recenter the currently browsed cards.
        SyncCustomView(view)
        return
    end
    local list = FindControl(widget, "PresetList")
    local selected = list and Read(list, "SelectedItem")
    local current = Read(context, "CurrentPreset")
    local index = Read(context, "PresetSelectedIndex")
    local selectedAsset
    if state.Initializing then selectedAsset = state.OpeningAsset
    elseif state.BrowserSignature then selectedAsset = Read(selected, "AssetName") end
    local currentAsset = Read(current, "AssetName") or Read(current, "Asset")
    if currentAsset and not native[currentAsset] then currentAsset = nil end
    selectedAsset = selectedAsset or currentAsset
        or (type(index) == "number" and Read(presets[index + 1], "AssetName")) or Read(selected, "AssetName")
    if not state.BrowserSignature then
        HB_Trace("in-game browser state opened (no prior signature), existing host token="
            ..tostring(existingKey).." previous key="..tostring(state.BrowserKey))
        -- The native committed preset takes precedence over the card highlighted
        -- by the player (which may be Custom without changing the campaign).
        state.CampaignAsset = currentAsset
    end
    -- Opening/browsing the menu must never change MCM. Only a later
    -- observed change to the committed native CurrentPreset is eligible.
    if not state.BrowserSignature and (state.OpenedInCustom or Read(context, "CanOnlyChangeCustomMode") == true) then
        selectedAsset = "difficulty_04"
    end
    if state.BrowserKey then
        if existingKey == state.BrowserKey then existing.HB_Ready = false end
        browserStates[state.BrowserKey] = nil
    end
    local vm = Ext.UI.Instantiate(BROWSER)
    local key = HB_NewViewId()
    vm.HB_ViewToken = key
    if state.BrowserKey then
        HB_Trace("rebuilding difficulty browser: previous="..state.BrowserKey
            .." host-token="..tostring(existingKey)
            .." signature-changed="..tostring(state.BrowserSignature ~= signature))
    end
    state.ActiveVM = vm
    state.BrowserKey, state.BrowserSignature = key, signature
    state.Initializing, state.OpeningPasses, state.OpeningAttempts = true, 0, 0
    state.OpeningAsset, state.OpeningIndex = selectedAsset, 0
    
    
    vm.HB_InCustomView = state.CustomRequested == true or
        (Read(context, "CanOnlyChangeCustomMode") ~= true and Read(context, "IsInCustomMode") == true)
    vm.HB_CustomOnly = false
    vm.HB_ShowMCMControls = Read(context, "IsMainMenu")==false and Read(context,"IsHost")~=false
    vm.HB_AllowMCM = Read(host, "Tag") ~= "SingleSave"
    vm.HB_ShowCustomMCM = vm.HB_ShowMCMControls and vm.HB_AllowMCM and CurrentMCMPreset()=="Custom"
    vm.HB_ShowPresetDetails = vm.HB_ShowMCMControls and HB_PresetDetails.Presets[CurrentMCMPreset()]~=nil
    vm.HB_MCMOverlayOpen = false
    vm.HB_CustomOverlayOpen = false
    vm.HB_CustomIsSlider=false;vm.HB_CustomIsCheck=false;vm.HB_CustomIsEnum=false;vm.HB_CustomSliderEnabled=true
    vm.HB_CustomDetailMode=false;vm.HB_CustomEditMode=true
    vm.HB_CustomDialogTitle="Custom Difficulty Settings"
    vm.HB_CustomDialogHelp="Choose a category and setting, then adjust its value. Confirm saves all changes."
    vm.HB_CustomCloseLabel="Cancel";vm.HB_CustomReadOnlyValue=""
    vm.HB_CustomSelectedTitle="";vm.HB_CustomSelectedDescription=""
    local currentPreset = CurrentMCMPreset()
    HB_Trace("native difficulty="..tostring(state.CampaignAsset).." client MCM preset="..tostring(currentPreset))
    for _, name in ipairs(HB_MCM_names) do
        local item=Ext.UI.Instantiate(MCM_ITEM)
        item.Name=name
        vm.HB_MCMPresets[#vm.HB_MCMPresets+1]=item
        if name==currentPreset then vm.HB_MCMSelectedIndex=#vm.HB_MCMPresets-1 end
    end
    vm.HB_CaptureCommittedDifficulty:SetHandler(function()
        WithLiveBrowser(key,function(view)
            if Read(view.Native,"IsMainMenu")~=false or Read(view.Native,"IsHost")==false then return end
            local candidate=Read(Read(FindControl(view.Widget,"PresetList"),"SelectedItem"),"AssetName")
            if type(candidate)~="string" or not candidate:match("^difficulty_0[123567]$") then return end
            local expectedGeneration=generation
            local function VerifyCommit()
                if generation~=expectedGeneration then return end
                -- Native CurrentPreset, not a highlighted card, is the authority.
                local currently=Read(Read(view.Native,"CurrentPreset"),"AssetName")
                if currently==candidate then HB_SendGameAsset(currently,"live",true)
                else HB_Trace("native Confirm not yet committed: chosen="..candidate.." current="..tostring(currently)) end
            end
            if Ext.Timer and Ext.Timer.WaitFor then Ext.Timer.WaitFor(500,VerifyCommit)
            else VerifyCommit() end
        end)
    end)
    vm.HB_OpenMCM:SetHandler(function()
        WithLiveBrowser(key, function(view)
            local main=Read(view.Native,"IsMainMenu")
            local host=Read(view.Native,"IsHost")
            local asset=view.State.CampaignAsset
            if main~=false or host==false or Read(view.Host, "Tag")=="SingleSave" then
                HB_Trace("Preset dialog refused menu/host/single-save "..tostring(asset))
                return
            end
            local current = CurrentMCMPreset()
            for i=1,#HB_MCM_names do
                if HB_MCM_names[i]==current then view.Browser.HB_MCMSelectedIndex=i-1; break end
            end
            view.Browser.HB_MCMOverlayOpen=true
            HB_Trace("Native preset dialog opened: "..tostring(current).." asset="..tostring(asset))
        end)
    end)
    vm.HB_OpenCustomMCM:SetHandler(function()
        WithLiveBrowser(key,function(view)
            if Read(view.Native,"IsMainMenu")~=false or Read(view.Native,"IsHost")==false
                or Read(view.Host,"Tag")=="SingleSave" or CurrentMCMPreset()~="Custom" then
                HB_Trace("Native Custom settings refused by menu/host/single-save/Custom guard")
                return
            end
            HB_CustomStart(view)
            HB_Trace("Native Custom editor opened")
        end)
    end)
    vm.HB_OpenPresetDetails:SetHandler(function()
        WithLiveBrowser(key,function(view)
            local preset=CurrentMCMPreset()
            if not view.Browser.HB_ShowMCMControls or view.Browser.HB_CustomOverlayOpen
                or view.Browser.HB_MCMOverlayOpen or not HB_PresetDetails.Presets[preset] then return end
            if HB_CustomStart(view,preset) then HB_Trace("Difficulty details viewed: "..preset) end
        end)
    end)
    vm.HB_CustomCategoryChanged:SetHandler(function()
        WithLiveBrowser(key,HB_ReconcileCustomSelection)
    end)
    vm.HB_CustomSettingChanged:SetHandler(function()
        WithLiveBrowser(key,HB_ReconcileCustomSelection)
    end)
    local function CycleEnum(step)
        WithLiveBrowser(key,function(view)
            local st=view.State.CustomEditor
            local field=HB_ActiveCustomField(view)
            if not field or field.kind~="enum" then return end
            st.enumIndex=math.max(1,math.min(#field.choices,(st.enumIndex or 1)+step))
            view.Browser.HB_CustomEnumName=field.choices[st.enumIndex]
            HB_CustomStoreVisible(view)
        end)
    end
    vm.HB_CustomValueChanged:SetHandler(function()
        WithLiveBrowser(key,function(view)
            if view.State.CustomEditor and view.Browser.HB_CustomOverlayOpen then
                HB_CustomStoreVisible(view)
            end
        end)
    end)
    vm.HB_CustomEnumPrev:SetHandler(function() CycleEnum(-1) end)
    vm.HB_CustomEnumNext:SetHandler(function() CycleEnum(1) end)
    vm.HB_CustomCancel:SetHandler(function()
        WithLiveBrowser(key,function(view)
            view.State.CustomEditor=nil
            view.Browser.HB_CustomOverlayOpen=false
            HB_Trace("Native Custom editor canceled; no changes sent")
        end)
    end)
    vm.HB_CustomConfirm:SetHandler(function()
        WithLiveBrowser(key,function(view)
            if not view.State.CustomEditor or view.State.CustomEditor.readOnly or Read(view.Host,"Tag")=="SingleSave"
                or CurrentMCMPreset()~="Custom" then return end
            HB_CustomStoreVisible(view)
            local changes=view.State.CustomEditor.pending
            if not next(changes) then
                view.State.CustomEditor=nil
                view.Browser.HB_CustomOverlayOpen=false
                return
            end
            if not (Ext.Net and Ext.Net.PostMessageToServer) then return end
            local okEncode,message=pcall(Ext.Json.Stringify,changes)
            if not okEncode then HB_Trace("Custom serialize failed "..tostring(message));return end
            local ok,result=pcall(Ext.Net.PostMessageToServer,"HB_Difficulty_CustomEdits_V1",message)
            if not ok or result==false then
                HB_Trace("Custom send failed "..tostring(result))
                return
            end
            view.State.CustomEditor=nil
            view.Browser.HB_CustomOverlayOpen=false
            HB_Trace("Native Custom edits submitted: "..tostring(message and #message))
        end)
    end)
    vm.HB_MCMCancel:SetHandler(function()
        WithLiveBrowser(key, function(view)
            view.Browser.HB_MCMOverlayOpen=false
            HB_Trace("Native preset dialog canceled")
        end)
    end)
    vm.HB_MCMConfirm:SetHandler(function()
        WithLiveBrowser(key, function(view)
            if not view.Browser.HB_MCMOverlayOpen then return end
            if Read(view.Native,"IsHost")==false or Read(view.Native,"IsMainMenu")~=false
               or Read(view.Host, "Tag")=="SingleSave" then
                HB_Trace("Native preset dialog confirm refused by single-save/host/UI guard")
                return
            end
            local list=FindControl(view.Widget,"HB_MCMPresetList")
            local item=Read(list,"SelectedItem")
            local choice=Read(item,"Name")
            -- Prefer the live selected item, not a stale cached index.
            if not choice then
                local index=Read(list,"SelectedIndex")
                if type(index)=="number" then choice=HB_MCM_names[index+1] end
            end
            local valid=false
            for _,name in ipairs(HB_MCM_names) do if choice==name then valid=true;break end end
            if not valid then
                HB_Trace("Native preset dialog confirm without valid selection "..tostring(choice))
                return
            end
            if not (Ext.Net and Ext.Net.PostMessageToServer) then
                HB_Trace("Native preset dialog unable to send: network API missing")
                return
            end
            local ok,result=pcall(Ext.Net.PostMessageToServer,"HB_Difficulty_PresetChoice_V1",choice)
            local sent=ok and result~=false
            HB_Trace("Native preset requested="..choice.." sent="..tostring(sent).." result="..tostring(result))
            -- This only confirms transport submission, not server application.
            -- On local send failure, keep the overlay so the user can retry.
            if sent then
                view.Browser.HB_MCMOverlayOpen=false
                view.Browser.HB_ShowCustomMCM = view.Browser.HB_ShowMCMControls and view.Browser.HB_AllowMCM and choice=="Custom"
            end
        end)
    end)
    for _, asset in ipairs(order) do
        local original, data = native[asset], catalog[asset] or { Title = titles[asset], Description = "" }
        local card = Ext.UI.Instantiate(CARD)
        card.AssetName, card.IsCustom = asset, asset == "difficulty_04"
        card.Title = CardText(original, "Title", data.Title)
        card.Description = CardText(original, "Description", data.Description)
        if original then card.HB_Native = original end
        card.HB_CanApply = (original ~= nil or card.IsCustom) and asset ~= "difficulty_07"
        card.HB_UnavailableText = asset == "difficulty_07"
            and "Deific can only be selected when starting a new campaign."
            or "This difficulty is unavailable for this campaign's ruleset."
        vm.HB_Presets[#vm.HB_Presets + 1] = card
        if asset == selectedAsset then state.OpeningIndex = #vm.HB_Presets - 1 end
    end
    vm.HB_SelectedIndex = state.OpeningIndex
    browserStates[key] = state
    vm.HB_SelectionChanged:SetHandler(function()
        WithLiveBrowser(key, SyncSelection)
    end)
    vm.HB_OpenCustomView:SetHandler(function()
        lastAction = "Customise command received"
        WithLiveBrowser(key, function(view)
            local state, vm, context = view.State, view.Browser, view.Native
            if state.MythicConfirmationPending or not CanOpenCustom(view) then return end
            if state.CampaignAsset == "difficulty_06" and not state.OpenedInCustom
                and Read(context, "IsInCustomMode") ~= true and Read(context, "CanOnlyChangeCustomMode") ~= true then
                state.Initializing = false
                state.MythicConfirmationPending = true
                state.MythicConfirmationStarted = Ext.Timer.MonotonicTime()
                vm.HB_MythicConfirmation, vm.HB_MythicConfirmationReady = true, false
                lastAction = "Mythic-to-Custom confirmation shown"
                return
            end
            OpenCustomView(view)
        end)
    end)
    vm.HB_CancelMythicCustom:SetHandler(function()
        WithLiveBrowser(key, CancelMythicConfirmation)
    end)
    vm.HB_ContinueMythicCustom:SetHandler(function()
        WithLiveBrowser(key, function(view)
            if not view.State.MythicConfirmationPending then return end
            SyncMythicConfirmation(view)
            if not view.Browser.HB_MythicConfirmationReady then return end
            view.State.MythicConfirmationPending = false
            view.Browser.HB_MythicConfirmation, view.Browser.HB_MythicConfirmationReady = false, false
            OpenCustomView(view)
        end)
    end)
    vm.HB_CloseCustomView:SetHandler(function()
        WithLiveBrowser(key, function(view)
            local state, vm, context = view.State, view.Browser, view.Native
            if state.MythicConfirmationPending then CancelMythicConfirmation(view); return end
            if Read(view.Host, "Tag") == "SingleSave" then return end
            if state.OpenedInCustom or Read(context, "CanOnlyChangeCustomMode") == true then
                CloseDifficultyMenu(view)
                return
            end
            state.CustomRequested, state.NativeCustomSeen = false, false
            vm.HB_InCustomView, vm.HB_CustomOnly = false, false
            ChangeNativeCustomView(view, false)
            SyncCustomView(view)
        end)
    end)
    host.DataContext = vm
    vm.HB_Ready = true
    HB_Trace("difficulty browser attached token="..key)
    HB_Trace("difficulty browser initialized once: "..tostring(state.CampaignAsset)
        .." native="..tostring(#presets).." HB="..tostring(#vm.HB_Presets))
    local view = LiveView(state, widget, context, host, vm)
    SelectOpeningCard(view)
    SyncMythicConfirmation(view)
    SyncCustomView(view)
end

-- The New Game Honour Mode controller already locates the native menu from
-- ContentRoot and has a working main-menu lifecycle. Let it pass that exact
-- widget into the difficulty binder rather than requiring a second traversal.
_G.HB_DifficultyOrder_BindMain = function(widget, context)
    if not browserAvailable or Read(context,"IsMainMenu") ~= true then return end
    local presets = Read(context,"Presets")
    if not presets then return end
    local state = states["main-menu"] or {}
    states["main-menu"] = state
    if not state.ExternalBinderReported then
        state.ExternalBinderReported = true
        HB_NewGameAudit("main-menu difficulty binder reached via New Game controller")
    end
    BindBrowser(state, widget, context, presets)
end

local function IsCustom(preset)
    return preset and (Read(preset, "IsCustom") == true or Read(preset, "AssetName") == "difficulty_04")
end

local function MoveCustom(context, presets, customIndex, count)
    local custom = presets[customIndex]
    local selectedIndex = Read(context, "PresetSelectedIndex")
    if type(selectedIndex) ~= "number" or selectedIndex < 0 or selectedIndex >= count then
        
        return
    end
    local selected = presets[selectedIndex + 1]
    if Read(context, "CanOnlyChangeCustomMode") == true then selected = custom end

    
    
    presets[count + 1] = custom
    if #presets ~= count + 1 then error("Native preset collection rejected insertion") end
    local removed, reason = pcall(function() presets[customIndex] = nil end)
    if not removed or #presets ~= count then
        if #presets == count + 1 then presets[count + 1] = nil end
        context.PresetSelectedIndex = selectedIndex
        error(reason or "Native preset collection rejected removal")
    end
    if presets[count] ~= custom then error("Custom was not retained at the end of the preset list") end

    
    for index = 1, count do
        if presets[index] == selected then
            context.PresetSelectedIndex = index - 1
            return
        end
    end
    error("Selected preset disappeared during ordering")
end

local function SelectNewGameDefault(state, widget, context, presets)
    if Read(context, "IsMainMenu") ~= true or Read(context, "IsInCustomMode") == true then return end
    local list = FindControl(widget, "PresetList")
    if not list then return end
    local selected = Read(list, "SelectedItem")
    if selected then
        state.NewGameAsset = Read(selected, "AssetName")
        return
    end
    if #presets == 0 then return end
    local asset = state.NewGameAsset or "difficulty_01"
    for position = 1, #presets do
        if Read(presets[position], "AssetName") == asset then
            list.SelectedItem = presets[position]
            context.PresetSelectedIndex = position - 1
            state.NewGameAsset = asset
            local actual = Read(Read(list, "SelectedItem"), "AssetName")
            lastAction = (actual == asset and "New-game default selected: " or "New-game default selection pending: ") .. asset
            return
        end
    end
end

local function Update()
    local menus = MenuWidgets()
    local seen = {}
    local processed = {}
    for _, widget in ipairs(menus) do
        if Read(widget, "IsVisible") ~= false then
            local context = Read(widget, "DataContext")
            if context and tostring(Read(context, "Type")):find("HB_NewGameSingleSaveSettings", 1, true) then
                context = Read(context, "HB_SingleSaveNative") or context
            end
            local presets = context and Read(context, "Presets")
            if presets then
                local key = Read(context,"IsMainMenu")==true and "main-menu" or "in-game"
                if not processed[key] then
                processed[key] = true
                local state = states[key] or {}
                -- This MUST precede all Noesis writes/VM handlers. Previously
                -- states=seen happened at the end, so a UI exception discarded
                -- the new state and caused another fresh Veteran VM next pass.
                states[key] = state
                seen[key] = state
                SelectNewGameDefault(state, widget, context, presets)
                local count = #presets
                local customIndex
                for item = 1, count do
                    if IsCustom(presets[item]) then customIndex = item; break end
                end
                -- The in-game XAML switches atomically to the already sorted
                -- HB_Presets collection. Reordering the *native* collection
                -- afterward creates a second visible selection/layout pass.
                -- Keep native ordering intact in-game and let SyncSelection map
                -- each HomeBrew card back to its actual native preset object.
                -- The main-menu chooser (and vanilla fallback) retain the
                -- established native Custom-last ordering behavior.
                local needNativeOrder = Read(context, "IsMainMenu") ~= false or not browserAvailable
                if needNativeOrder and customIndex and customIndex < count then
                    local assetNames={}
                    for i=1,count do assetNames[i]=tostring(Read(presets[i],"AssetName")) end
                    local signature = table.concat(assetNames,"|") .. ":" .. customIndex
                    if state.signature ~= signature then
                        state.signature = signature
                        state.ready = false
                        state.failed = false
                    elseif not state.failed then
                        
                        
                        if defer or state.ready then
                            local ok, message = pcall(MoveCustom, context, presets, customIndex, count)
                            if not ok then
                                state.failed = true
                                Ext.Utils.Print("[HB Difficulty Order] " .. tostring(message))
                            end
                        else
                            state.ready = true
                        end
                    end
                end
                SelectNewGameDefault(state, widget, context, presets)
                if browserAvailable then BindBrowser(state, widget, context, presets) end
                -- Fail visibly/usable rather than leave a blank in-game carousel
                -- if the Script Extender browser throws or is unavailable.
                if Read(context, "IsMainMenu") == false then
                    local host = FindControl(widget, "HB_DifficultyBrowserHost")
                    local ready = Read(Read(host, "DataContext"), "HB_Ready") == true
                    local fallback = FindControl(widget, "HB_NativeDifficultyFallback")
                    if fallback then
                        if ready then
                            if Read(fallback, "Tag") ~= "Prepared" then fallback.Tag = "Prepared" end
                            if not state.hbReadyReported then
                                HB_Trace("native-XAML difficulty cards prepared; released as one view")
                                state.hbReadyReported = true
                            end
                            state.hbNotReadySince = nil
                        else
                            local now = Ext.Timer.MonotonicTime()
                            state.hbNotReadySince = state.hbNotReadySince or now
                            if now - state.hbNotReadySince >= 1500
                                and Read(fallback, "Tag") ~= "Native" then
                                fallback.Tag = "Native"
                                HB_Trace("native difficulty fallback after HB preparation timeout")
                            end
                        end
                    end
                end
                end -- process at most one native widget per menu mode
            end
        end
    end
    -- A main-menu highlight is not a new campaign. Only the actual Start
    -- command arms the one-time asset capture; this prevents an old level-one
    -- save from inheriting a difficulty briefly previewed on the main menu.
    -- Don't treat one intermittent missing UI-tree sample as menu closure.
    -- Doing so previously discarded BrowserSignature and allocated a fresh
    -- view every 75ms, forcing Veteran back into the carousel continuously.
    -- Update() is reached only while DifficultyMenuVisible() is true.
    -- A failed/intermittent MenuWidgets traversal does NOT mean the native
    -- menu closed; discarding state on that basis recreated a new VM every
    -- time the traversal resumed and repeatedly forced the opening card.
    -- Keep the in-game browser until the menu scope is independently observed
    -- closed for a sustained period (handled in the Tick gate below).
    if not seen["in-game"] and states["in-game"] then
        seen["in-game"] = states["in-game"]
    end
    -- Main-menu VM can also survive a missed nested UI sample. The genuine
    -- New Game screen is explicitly identified by the main-menu probe.
    local mainState=states["main-menu"]
    if not seen["main-menu"] and mainState
        and Ext.Timer.MonotonicTime()-(mainState.LastSeenAt or -100000)<3000
        and Read(mainState.ActiveWidget,"IsVisible")~=false
        and Read(mainState.ActiveContext,"IsMainMenu")==true then
        seen["main-menu"] = mainState
    end
    states = seen
end

local lastDiagnostic = ""
local lastMenuSnapshot = ""
local nextDiagnostic = 0
local function DiagnoseMenu()
    local now = Ext.Timer.MonotonicTime()
    if now < nextDiagnostic then return end
    nextDiagnostic = now + 1000
    local menus, traversal = MenuWidgets()
    local lines = {"HomeBrew difficulty menu v36", traversal, "Last error: " .. lastFailure, "Last action: " .. lastAction,
        "Browser available: " .. tostring(not not browserAvailable), "Menus found: " .. #menus,
        "Integration trace: " .. table.concat(HB_difficultyTrace," | ")}
    for _, widget in ipairs(menus) do
        local context = Read(widget, "DataContext")
        local _, list = pcall(FindControl, widget, "PresetList")
        local _, host = pcall(FindControl, widget, "HB_DifficultyBrowserHost")
        local vm = Read(host, "DataContext")
        for _, prop in ipairs({"Name", "FileName", "Type"}) do
            lines[#lines + 1] = "Widget " .. prop .. ": " .. tostring(Read(widget, prop))
        end
        for _, prop in ipairs({"Type", "IsHost", "IsMainMenu", "HasBeenInitialized", "IsInCustomMode", "CanOnlyChangeCustomMode", "PresetSelectedIndex"}) do
            lines[#lines + 1] = prop .. ": " .. tostring(Read(context, prop))
        end
        lines[#lines + 1] = "Difficulty lock: " .. tostring(Read(host, "Tag"))
        lines[#lines + 1] = "Browser ready: " .. tostring(Read(vm, "HB_Ready"))
        lines[#lines + 1] = "Displayed cards: " .. tostring(Read(Read(list, "Items"), "Count"))
        lines[#lines + 1] = "Selected index: " .. tostring(Read(list, "SelectedIndex"))
        lines[#lines + 1] = "Selected card: " .. tostring(Read(Read(list, "SelectedItem"), "AssetName"))
        lines[#lines + 1] = "Current preset: " .. tostring(Read(Read(context, "CurrentPreset"), "AssetName"))
        lines[#lines + 1] = "Browser index: " .. tostring(Read(vm, "HB_SelectedIndex"))
        lines[#lines + 1] = "Custom view: " .. tostring(Read(vm, "HB_InCustomView"))
        lines[#lines + 1] = "Mythic confirmation: " .. tostring(Read(vm, "HB_MythicConfirmation"))
        local confirm = FindControl(widget, "ConfirmBtn") or FindControl(widget, "StartGameButton")
        lines[#lines + 1] = "Confirm enabled: " .. tostring(Read(confirm, "IsEnabled"))
        lines[#lines + 1] = "Confirm command: " .. tostring(Read(Read(confirm, "Command"), "Type"))
        local state = vm and browserStates[Read(vm,"HB_ViewToken")]
        lines[#lines + 1] = "Opening target: " .. tostring(state and state.OpeningAsset)
        lines[#lines + 1] = "Campaign difficulty: " .. tostring(state and state.CampaignAsset)
        lines[#lines + 1] = "Opening selection pending: " .. tostring(state and state.Initializing)
        for _, source in ipairs({"Presets", "HB_Presets"}) do
            local collection = Read(source == "Presets" and context or vm, source)
            if collection then
                for i = 1, #collection do
                    lines[#lines + 1] = source .. " " .. i .. ": " .. tostring(Read(collection[i], "AssetName"))
                end
            end
        end
    end
    if #menus == 0 and lastMenuSnapshot ~= "" then
        lines[#lines + 1] = "Last visible menu snapshot:\n" .. lastMenuSnapshot
    end
    local report = table.concat(lines, "\n")
    if #menus > 0 then lastMenuSnapshot = report end
    if report ~= lastDiagnostic then
        lastDiagnostic = report
        SaveReport(report)
    end
end

local MenuScope = Ext.Require("Client/MenuScope.lua")
local lastScopePoll, scopeOpen = -100000, false
local function DifficultyMenuVisible(now)
    -- Preserve the existing 160 ms idle and 80 ms visible-page cadences.
    -- The old 35 ms pause path depended exclusively on the removed
    -- HB_NormalGameOverBridge, which is not mounted in the Long Rest-safe UI.
    local cadence = scopeOpen and 80 or 160
    if now - lastScopePoll >= cadence then
        lastScopePoll, scopeOpen = now, MenuScope.IsOpen('Difficulty')
    end
    return scopeOpen
end

-- Do not poll the removed Game Over bridge as a surrogate pause signal.
-- MenuScope's Pause group only recognizes that bridge, and both current
-- state machines intentionally omit it to preserve Long Rest. The live
-- Difficulty page still calls ScanCatalog at its unchanged cadence.

local HB_nextCreationProbe=0
local HB_nextMainMenuProbe=0
local HB_probeLastReport=0
-- The ordinary in-game Difficulty MenuScope does not reliably include the
-- NEW GAME difficulty chooser. Probe that small UI scope independently.
-- Walk both logical and visual children: on some Noesis screens the native
-- DMSettings widget is nested beneath a visual container rather than being
-- a direct child of ContentRoot.
HB_FreshMainMenuPanel = function()
    local root=Ext.UI.GetRoot and Ext.UI.GetRoot()
    local content=root and (root:Find("ContentRoot") or root)
    if not content then
        return nil,nil,0,nil,nil
    end
    local visited,scanned={},0
    local observedButton=nil
    local function Search(node,depth,mainAncestor,mainNative)
        if not node or depth>16 or scanned>=1500 or Read(node,"IsVisible")==false then return nil end
        local key=tostring(node)
        if visited[key] then return nil end
        visited[key]=true;scanned=scanned+1
        local name=Read(node,"Name")
        if name=="HB_MCMDifficultyButton" then
            observedButton="found enabled="..tostring(Read(node,"IsEnabled"))
                .." command="..tostring(Read(node,"Command")~=nil)
        end
        local file=tostring(Read(node,"FileName") or ""):gsub("\\","/")
        -- On the actual New Game screen the difficulty settings panel may
        -- be nested under a dynamically generated XAML page, with neither its
        -- Name nor FileName matching the original widget. Identify it by
        -- the live native difficulty VM AND its own HomeBrew host instead.
        local native=Read(node,"DataContext")
        if tostring(Read(native,"Type")):find("HB_NewGameSingleSaveSettings",1,true) then
            native=Read(native,"HB_SingleSaveNative") or native
        end
        if Read(native,"IsMainMenu")==true and Read(native,"Presets") then
            mainAncestor,mainNative=node,native
        end
        -- On some frontend skins the live button and native difficulty VM
        -- are on different nested elements, not a named NewGameSettings root.
        -- Their nearest common native ancestor is the real binding surface.
        if name=="HB_MCMDifficultyButton" and mainAncestor and mainNative then
            return mainAncestor,mainNative
        end
        if Read(native,"IsMainMenu")==true and Read(native,"Presets") then
            local ownsHost = pages[name] or file:match("/NewGameSettings(_c)?%.xaml$")
                or file:match("/HB_HonouredMyth_NewGameSettings(_c)?%.xaml$")
                or Read(node,"Name")=="HB_SettingsRoot"
            -- Only inspect the subtree if the node has its own suitable VM.
            -- The presence of the named host distinguishes our real panel
            -- from a native ancestor inheriting a difficulty DataContext.
            if ownsHost then
                return node,native
            end
        end
        for _,pair in ipairs({{"ChildrenCount","Child"},{"VisualChildrenCount","VisualChild"}}) do
            local count=math.min(tonumber(Read(node,pair[1])) or 0,160)
            for i=1,count do
                local ok,child=pcall(function() return node[pair[2]](node,i) end)
                if ok then
                    local found,dc=Search(child,depth+1,mainAncestor,mainNative)
                    if found then return found,dc end
                end
            end
        end
    end
    local widget,native=Search(content,0)
    return widget,native,scanned,observedButton,content
end
local function HB_ProbeMainMenuHighlight(now)
    -- A server-confirmed active campaign cannot contain the New Game chooser.
    -- Avoid traversing up to 1500 UI elements every 450 ms during gameplay.
    -- Do not skip the active new-character-creation handoff, including when
    -- the server confirms a campaign before that handoff is complete.
    -- GameStateChanged invalidates the campaign flag on return to Main Menu.
    if (HB_activeGameSession or HB_mcmCampaignConfirmed) and
       (HB_postCreationSent or
        (not HB_mainMenuHighlighted and not HB_pendingNewGameArmed)) then
        return
    end
    if now<HB_nextMainMenuProbe then return end
    HB_nextMainMenuProbe=now+450
    local widget,native,scanned,observedButton,content=HB_FreshMainMenuPanel()
    if not widget then
        if now-HB_probeLastReport>=15000 then
            HB_probeLastReport=now
            HB_NewGameAudit("main-menu probe: no difficulty panel found; scanned="..scanned
                .." content children="..tostring(Read(content,"ChildrenCount"))
                .." AdjustButton="..tostring(observedButton))
        end
        return
    end
    -- A later return to the main menu starts a *new* selection cycle.
    -- Don't let the previous campaign's one-shot creation state block it.
    if HB_postCreationSent then
        HB_postCreationSent=false
        HB_pendingNewGameArmed=false
        HB_startedGameAsset=nil
        HB_newGameCandidate=nil
        HB_creationHiddenSince=nil
        HB_mainMenuManualAsset,HB_mainMenuManualPreset=nil,nil
        HB_NewGameAudit("returned to main menu; reset old new-game handoff state")
    end
    local list=FindControl(widget,"PresetList")
    local selected=Read(Read(list,"SelectedItem"),"AssetName")
    if not selected then
        local index=Read(native,"PresetSelectedIndex")
        local presets=Read(native,"Presets")
        if type(index)=="number" and presets then
            selected=Read(presets[index+1],"AssetName")
        end
    end
    if type(selected)=="string" and HB_MAIN_MENU_MCM_PRESETS[selected] then
        if HB_mainMenuHighlighted~=selected then
            HB_Trace("observed main-menu new-game difficulty "..selected)
            HB_NewGameAudit("main-menu candidate="..selected.." nodes="..scanned)
        end
        HB_mainMenuHighlighted=selected
        HB_mainMenuHighlightAt=now
        HB_ApplyMainMenuPreview(selected,"main-menu probe")
    end
    if now-HB_probeLastReport>=10000 then
        HB_probeLastReport=now
        HB_NewGameAudit("main-menu widget found, selected="..tostring(selected).." nodes="..scanned
            .." browser="..tostring(browserAvailable).." vm="..tostring(Read(native,"Type")))
    end
    -- Bind the new-game Start capture command even if MenuScope.IsOpen
    -- doesn't recognise the main-menu difficulty chooser.
    if browserAvailable and Read(native,"Presets") then
        local key="main-menu"
        local state=states[key] or {}
        states[key]=state
        -- Bind while this *exact* main-menu native panel is observable.
        -- The old deferred re-scan consistently saw an expired UIWidget
        -- (confirmed in the player's capture diagnostics).
        local ok,err=pcall(BindBrowser,state,widget,native,Read(native,"Presets"))
        if not ok then
            HB_NewGameAudit("main-menu immediate bind failed: "..tostring(err))
        elseif state.MainHandlersKey and state.MainHandlersReported~=state.MainHandlersKey then
            state.MainHandlersReported=state.MainHandlersKey
            HB_NewGameAudit("main-menu immediate binder attached token="..state.MainHandlersKey)
        end
    end
end
local function HB_CharacterCreationVisible()
    local root=Ext.UI.GetRoot and Ext.UI.GetRoot()
    local content=root and (root:Find("ContentRoot") or root)
    if not content then return false end
    local inspected,visited=0,{}
    local function Search(node,depth)
        if not node or depth>14 or inspected>=1200 then return false end
        local key=tostring(node)
        if visited[key] or Read(node,"IsVisible")==false then return false end
        visited[key]=true;inspected=inspected+1
        local name=Read(node,"Name")
        local file=tostring(Read(node,"FileName") or ""):gsub("\\","/")
        if name=="CharacterCreation" or name=="CharacterCreation_c"
            or file:match("/CharacterCreation(_c)?%.xaml$") then return true end
        for _,pair in ipairs({{"ChildrenCount","Child"},{"VisualChildrenCount","VisualChild"}}) do
            local count=math.min(tonumber(Read(node,pair[1])) or 0,160)
            for i=1,count do
                local ok,child=pcall(function() return node[pair[2]](node,i) end)
                if ok and Search(child,depth+1) then return true end
            end
        end
        return false
    end
    return Search(content,0)
end
local HB_difficultyClosedSince=nil
local HB_nextMenuWorkTick=0
Ext.Events.Tick:Subscribe(function()
    local now = Ext.Timer.MonotonicTime()
    -- The listener itself remains registered, but avoid UI work each frame
    -- while no difficulty menu is visible. The 80-ms idle gate preserves the
    -- existing 160-ms MenuScope cadence and 450-ms New Game probe. When the
    -- Difficulty page is visible, leave the original 75/80-ms behavior alone.
    if now < HB_nextMenuWorkTick then return end
    HB_nextMenuWorkTick=now+(scopeOpen and 1 or 80)
    -- Observe the main-menu difficulty independently of the in-game
    -- MenuScope gate; no MCM changes are made while browsing cards.
    HB_ProbeMainMenuHighlight(now)
    -- New-game Start click can be consumed by BG3's native control. A genuine
    -- CharacterCreation page reached from the main-menu difficulty chooser is
    -- an independent, stronger signal than merely highlighting a preset.
    if HB_mainMenuHighlighted and not HB_pendingNewGameArmed
        and now-HB_mainMenuHighlightAt>90000 then
        HB_mainMenuHighlighted=nil
    end
    if HB_mainMenuHighlighted and now>=HB_nextCreationProbe then
        HB_nextCreationProbe=now+(HB_pendingNewGameArmed and 1700 or 700)
        local visible=HB_CharacterCreationVisible()
        if visible then
            HB_creationHiddenSince=nil
            if not HB_pendingNewGameArmed then
                HB_pendingNewGameArmed=true
                HB_newGameCandidate=HB_newGameCandidate or HB_mainMenuHighlighted
                HB_startedGameAsset=HB_newGameCandidate
                HB_Trace("entered new character creation, armed chosen difficulty "..tostring(HB_startedGameAsset))
                HB_NewGameAudit("character creation entered; confirmed menu candidate="..tostring(HB_startedGameAsset))
            end
        elseif HB_pendingNewGameArmed and not HB_postCreationSent then
            if not HB_creationHiddenSince then HB_creationHiddenSince=now end
            if now-HB_creationHiddenSince>=1800 then
                HB_postCreationSent=true
                -- Stop polling the character-creation UI once handoff starts.
                HB_mainMenuHighlighted=nil
                local asset=HB_startedGameAsset
                if asset then
                    HB_Trace("new character creation closed: handoff "..asset)
                    HB_NewGameAudit("character creation closed; requesting="..asset)
                    HB_SendGameAsset(asset,"new",true)
                    local expectedGeneration=generation
                    if Ext.Timer and Ext.Timer.WaitFor then
                        for _,delay in ipairs({2000,5500,11000,20000}) do
                            Ext.Timer.WaitFor(delay,function()
                                if HB_pendingNewGameArmed and expectedGeneration==generation then
                                    HB_SendGameAsset(asset,"new",true)
                                end
                            end)
                        end
                    end
                end
            end
        end
    end
    if not DifficultyMenuVisible(now) then
        -- Only a sustained *independent* closed state retires browser state.
        -- The generic widget traversal may fail while the screen is present.
        HB_difficultyClosedSince = HB_difficultyClosedSince or now
        if now-HB_difficultyClosedSince>=4000 then
            local previous=states["in-game"]
            if previous then
                HB_Trace("difficulty scope closed for 4s; retiring in-game VM "
                    ..tostring(previous.BrowserKey))
                states["in-game"]=nil
                if previous.BrowserKey then browserStates[previous.BrowserKey]=nil end
            end
        end
        return
    end
    HB_difficultyClosedSince=nil
    local scanned, reason = pcall(ScanCatalog, now)
    if not scanned and not updateWarning then
        updateWarning = true
        Ext.Utils.Print("[HB Difficulty Browser] " .. tostring(reason))
    end
    if queued or now - lastUpdate < interval then return end
    lastUpdate = now
    queued = true
    local function Run()
        queued = false
        local ok, message = pcall(Update)
        if not ok then
            lastFailure = tostring(message)
            HB_BrowserError("Update failed: "..lastFailure)
            -- Fail open to the original native card list if preparation errors.
            -- Never wait indefinitely behind a hidden carousel.
            for _,widget in ipairs(MenuWidgets()) do
                local ctx = Read(widget,"DataContext")
                if Read(ctx,"IsMainMenu") == false then
                    local fallback = FindControl(widget,"HB_NativeDifficultyFallback")
                    if fallback then pcall(function() fallback.Tag="Native" end) end
                end
            end
        end
        local diagnosed, diagnosticError = pcall(DiagnoseMenu)
        if not diagnosed then SaveReport("HomeBrew difficulty menu v37: diagnostic error\n" .. tostring(diagnosticError)) end
        if not ok and not updateWarning then
            updateWarning = true
            Ext.Utils.Print("[HB Difficulty Order] UI ordering failed: " .. tostring(message))
        end
    end
    if defer then defer(Run) else Run() end
end)

if Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        HB_activeGameSession=true
        HB_nextMenuWorkTick=0
        -- A session transition revokes UI access until the server confirms
        -- the new campaign. Previous-save permissions must never leak.
        HB_InvalidateMCMAccess()
        HB_ApplyMCMChoiceState()
        HB_RequestMCMChoiceState()
        generation = generation + 1
        lastDiagnostic, lastMenuSnapshot, lastFailure, lastAction, nextDiagnostic = "", "", "", "", 0
        states, browserStates, queued, nextCatalog = {}, {}, false, 0
        HB_difficultyClosedSince = nil
        HB_assetSent=nil
        if HB_newGameCandidate then
            local asset=HB_newGameCandidate
            HB_newGameCandidate=nil
            local expectedGeneration=generation
            HB_Trace("session loaded: last new-game selection="..asset)
            HB_NewGameAudit("SessionLoaded with new-game candidate="..asset)
            -- Initial server SessionLoaded usually precedes restoration of its
            -- Ext.Vars state. Retry a bounded number of times instead of caching
            -- one client-side send that the server discarded as not ready.
            if Ext.Timer and Ext.Timer.WaitFor then
                for _,delay in ipairs({1250,3500,7000,14000,25000,40000}) do
                    Ext.Timer.WaitFor(delay,function()
                        if expectedGeneration==generation then HB_SendGameAsset(asset,"new",true) end
                    end)
                end
            else
                HB_Trace("no client WaitFor available; cannot schedule new-game mapping")
            end
        else
            HB_Trace("session loaded without captured new-game selection")
            HB_NewGameAudit("SessionLoaded: no new-game candidate yet")
        end
        lastUpdate = -interval
    end)
end
