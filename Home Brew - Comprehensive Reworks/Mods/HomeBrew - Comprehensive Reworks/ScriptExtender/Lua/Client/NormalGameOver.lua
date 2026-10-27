

if _G.HB_NormalGameOverClientLoaded then return end
if not Ext.UI or not Ext.UI.GetRoot then
    Ext.Utils.Print("[HB Game Over] Noesis UI API unavailable. Use Esc > Load Game after a non-Ironman wipe.")
    return
end
_G.HB_NormalGameOverClientLoaded = true

local pending = false
local started = 0
local lastPayload
local lastUpdate = -100
local queued = false
local signalled = false
local generation = 0
local defer = Ext.UI.Defer
local channel = "HB_NormalGameOver_v3"

local function Read(object, property)
    local ok, value = pcall(function() return object[property] end)
    if ok then return value end
end

local function PageName(widget)
    local filename = Read(widget, "FileName")
    if type(filename) == "string" then
        return filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
    end
    return Read(widget, "Name")
end

local function Scan()
    local root = Ext.UI.GetRoot()
    local content = root and root:Find("ContentRoot")
    local signals = {}
    local panelOpen = false
    if not content then return signals, panelOpen end
    for index = 1, content.ChildrenCount do
        local widget = content:Child(index)
        local name = widget and PageName(widget)
        if (name == "HB_NormalGameOver" or name == "HB_NormalGameOver_c")
            and Read(widget, "IsVisible") ~= false then
            panelOpen = true
        elseif name == "HB_NormalGameOverBridge" then
            signals[#signals + 1] = {
                element = widget,
                visible = Read(widget, "IsVisible") == true,
            }
        end
    end
    return signals, panelOpen
end

local function Reset(signals)
    for _, signal in ipairs(signals) do
        
        pcall(function() signal.element.Opacity = 0 end)
    end
    pending = false
    signalled = false
end

local function Update()
    local signals, panelOpen = Scan()
    if panelOpen then
        Reset(signals)
        Ext.Utils.Print("[HB Game Over] Normal defeat panel opened.")
        return
    end
    local now = Ext.Timer.MonotonicTime()
    if now - started > 10000 then
        Reset(signals)
        Ext.Utils.Print("[HB Game Over] Defeat panel did not open. Check GUI/state-machine installation; use Esc > Load Game.")
        return
    end
    if signalled then return end

    
    local selected
    for _, signal in ipairs(signals) do
        if signal.visible then selected = signal end
    end
    if not selected then selected = signals[#signals] end
    if selected then
        selected.element.Opacity = 1
        signalled = true
        Ext.Utils.Print("[HB Game Over] Sent HB_OpenNormalGameOver UI event.")
    end
end

Ext.RegisterNetListener(channel, function(_, payload)
    if payload == lastPayload then return end
    lastPayload = payload
    if pending then return end
    pending = true
    signalled = false
    generation = generation + 1
    started = Ext.Timer.MonotonicTime()
    Ext.Utils.Print("[HB Game Over] Client received non-Ironman defeat request.")
end)

Ext.Events.SessionLoaded:Subscribe(function()
    pending = false
    signalled = false
    lastPayload = nil
    generation = generation + 1
end)

Ext.Events.Tick:Subscribe(function()
    if not pending or queued then return end
    local now = Ext.Timer.MonotonicTime()
    if now - lastUpdate < 100 then return end
    lastUpdate = now
    queued = true
    local requestGeneration = generation
    local function Run()
        queued = false
        
        if not pending or generation ~= requestGeneration then return end
        local ok, message = pcall(Update)
        if not ok then
            pending = false
            signalled = false
            Ext.Utils.Print("[HB Game Over] UI request failed: " .. tostring(message) .. ". Use Esc > Load Game.")
        end
    end
    
    if defer then defer(Run) else Run() end
end)
Ext.Utils.Print("[HB Game Over] Client panel listener loaded.")
