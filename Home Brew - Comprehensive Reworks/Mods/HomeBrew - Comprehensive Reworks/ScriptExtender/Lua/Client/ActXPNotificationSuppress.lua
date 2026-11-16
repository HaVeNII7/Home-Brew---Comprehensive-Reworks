-- HomeBrew | XP notifications; SE v33, MainUI-path experiment v0.6.
-- Presentation only: no XP edits, no native combat-log collection mutation.
-- Keyboard CombatLog XAML is activated via the mod's IUI_CombatLog StateMachine override.
-- Client-side cap state comes from the already-working server XP script.
-- Uses only event-driven, bounded one-shot UI searches. No Tick listeners.

local M = { Version = '0.7-CombatLogStateOverride-Reference', Enabled = true }
local CHANNEL = 'HB_ActXP_BlockedReward_UI'
local OUT = 'HomeBrew/Diagnostics/HB_ActXPNotification_Experimental.txt'
local WAVE = {0, 85, 210, 470, 880, 1520}
local MAX_ROOT_NODES, MAX_WIDGET_NODES = 192, 650
local session, waveId = 0, 0
local capActive, region, cap = false, 'unknown', 0
local signals, capUpdates, uiPasses = 0, 0, 0
local tagWrites, tagFailures, foundGates, xpFound = 0, 0, 0, 0
local firstError, firstReadback, firstWidget, firstGate
local lines, seenErrors = {}, {}
local pendingWave, reported = false, false

local function safe(f)
    local ok, val = pcall(f)
    return ok and val or nil
end
local function get(obj, field)
    if obj == nil then return nil end
    return safe(function() return obj[field] end)
end
local function getType(obj) return tostring(get(obj,'Type') or 'nil') end
local function note(s)
    if #lines < 35 then lines[#lines+1] = s end
end
local function rememberError(label, err)
    if firstError == nil then firstError=label..': '..tostring(err) end
    if not seenErrors[label] then
        seenErrors[label]=true
        note('native error '..label..': '..tostring(err))
    end
end
local function count(o)
    return tonumber(safe(function() return #o end)) or 0
end

-- Direct Find() alone doesn't cross BG3's nested template namescopes.
-- This is adapted from the earlier read-only diagnostic that actually
-- located gui::DCCombatLog and the ls.VMXpGainedEntry instance in game.
local function find(root, target, limit)
    if not root then return nil,0 end
    local direct = safe(function() return root:Find(target) end)
    if direct then return direct,1 end
    local queue, head, max = {root}, 1, limit or MAX_WIDGET_NODES
    while head <= #queue and head <= max do
        local node = queue[head]; head=head+1
        if get(node,'Name') == target then return node,head-1 end
        -- No inner Find() calls on every leaf; a broad namescope lookup is
        -- both expensive and unreliable for templated descendants.
        local n = tonumber(get(node,'VisualChildrenCount') or get(node,'ChildrenCount')) or 0
        for i=1,math.min(n,32) do
            if #queue >= max then break end
            local child = safe(function() return node:VisualChild(i) end)
                or safe(function() return node:Child(i) end)
            if child then queue[#queue+1] = child end
        end
    end
    return nil,head-1
end

local function writeGate(root, label, gateName)
    local node, inspected = find(root, gateName, MAX_WIDGET_NODES)
    if not node then
        note(label..' gate=missing visited='..inspected)
        return false
    end
    foundGates=foundGates+1
    local ok,err=pcall(function()
        node.Tag = Ext.UI.Box(capActive)
    end)
    if ok then
        tagWrites=tagWrites+1
        if firstReadback==nil then
            firstReadback=label..' type='..getType(node)..' Tag='..tostring(get(node,'Tag'))
        end
    else
        tagFailures=tagFailures+1
        rememberError(label..'.Tag',err)
    end
    if firstGate==nil then firstGate=label..' visited='..inspected..' found='..tostring(node~=nil) end
    return ok
end

local function inspectXP(log)
    local ctx=get(log,'DataContext')
    local groups=get(get(get(ctx,'Data'),'CombatLog'),'EntryGroups')
    local n=count(groups)
    local xp=0
    for i=math.max(1,n-30),n do
        local group=get(groups,i)
        local entry=get(get(group,'Entries'),1) or get(get(group,'Entries'),0)
        if getType(entry)=='ls.VMXpGainedEntry' then xp=xp+1 end
    end
    xpFound=math.max(xpFound,xp)
    return n,xp
end

local function apply(gen, reason, logDetails)
    if not Ext.UI or not Ext.UI.Defer then return end
    Ext.UI.Defer(function()
        if gen~=session then return end
        uiPasses=uiPasses+1
        local root=safe(Ext.UI.GetRoot)
        if not root then
            note('ui-root=nil at '..reason)
            return
        end
        local combat, a=find(root,'CombatLog',MAX_ROOT_NODES)
        if not combat then combat,a=find(root,'CombatLog_c',MAX_ROOT_NODES) end
        local overhead,b=find(root,'OverheadInfo',MAX_ROOT_NODES)
        if not overhead then overhead,b=find(root,'OverheadInfo_c',MAX_ROOT_NODES) end
        if firstWidget==nil then
            firstWidget='combat='..tostring(combat~=nil)..' visited='..a
                ..' overhead='..tostring(overhead~=nil)..' visited='..b
                ..' rootType='..getType(root)
        end
        if combat then
            local name=tostring(get(combat,'Name') or '')
            if name=='CombatLog' then
                writeGate(combat,'keyboard-feed','CombatFeed')
            end
            if logDetails then
                local n,xp=inspectXP(combat)
                note('xp-snapshot groups='..n..' xp='..xp..' widget='..name)
            end
        end
        -- Overhead replacement is deliberately not attempted in this reference-based combat-log test.
    end)
end

local function scheduleGates()
    local gen=session
    apply(gen,'cap-state',false)
    if Ext.Timer and Ext.Timer.WaitFor then
        Ext.Timer.WaitFor(180,function() apply(gen,'cap-state-retry',false) end)
        Ext.Timer.WaitFor(620,function() apply(gen,'cap-state-retry',false) end)
    end
end
local function writeReport(gen)
    if gen~=session or reported or not Ext.IO or not Ext.IO.SaveFile then return end
    reported=true
    local routes={}
    for _,name in ipairs({'CombatLog.xaml','CombatLog_c.xaml','OverheadInfo.xaml','OverheadInfo_c.xaml'}) do
        local orig='Mods/MainUI/GUI/Pages/'..name
        routes[#routes+1]=name..'='..tostring(
            Ext.IO.GetPathOverride and safe(function() return Ext.IO.GetPathOverride(orig) end) or 'none')
    end
    local rows={
        'HomeBrew XP notification UI experiment',
        'Version='..M.Version,
        'CombatLog override installed in Mods/HomeBrew - Comprehensive Reworks/GUI/StateMachines/Keyboard.xaml',
        'No AddPathOverride, native DC replacement, or XP history mutation.',
        'Region='..region..' Cap='..cap..' Active='..tostring(capActive),
        'signals='..signals..' capUpdates='..capUpdates,
        'uiPasses='..uiPasses..' tagWrites='..tagWrites..' tagFailures='..tagFailures,
        'foundGates='..foundGates..' xpFound='..xpFound,
        'firstWidget='..tostring(firstWidget or 'none'),
        'firstGate='..tostring(firstGate or 'none'),
        'firstTagReadback='..tostring(firstReadback or 'none'),
        'firstError='..tostring(firstError or 'none'),
        'oldMainUIOverrides '..table.concat(routes,' '),
    }
    for _,line in ipairs(lines) do rows[#rows+1]=line end
    pcall(Ext.IO.SaveFile,OUT,table.concat(rows,'\n')..'\n')
end
local function blocked()
    signals=signals+1
    if not capActive then capActive=true; scheduleGates() end
    if pendingWave then return end
    pendingWave=true
    waveId=waveId+1
    local wave,gen=waveId,session
    for i,ms in ipairs(WAVE) do
        if ms==0 then apply(gen,'reward-'..i,true)
        else Ext.Timer.WaitFor(ms,function() apply(gen,'reward-'..i,i==2 or i==4) end) end
    end
    Ext.Timer.WaitFor(1800,function()
        if wave==waveId and gen==session then
            pendingWave=false
            writeReport(gen)
        end
    end)
end

if Ext.Events then
    if Ext.Events.SessionLoading then
        Ext.Events.SessionLoading:Subscribe(function()
            session=session+1;waveId=0
            region,cap,capActive='unknown',0,false
            signals,capUpdates,uiPasses=0,0,0
            tagWrites,tagFailures,foundGates,xpFound=0,0,0,0
            lines,seenErrors={},{}
            pendingWave,reported=false,false
            firstError,firstReadback,firstWidget,firstGate=nil,nil,nil,nil
        end)
    end
    if Ext.Events.SessionLoaded then
        Ext.Events.SessionLoaded:Subscribe(scheduleGates)
    end
    if Ext.Events.ResetCompleted then
        Ext.Events.ResetCompleted:Subscribe(scheduleGates)
    end
end
local channel
if Ext.Net and Ext.Net.CreateChannel and ModuleUUID then
    channel=safe(function() return Ext.Net.CreateChannel(ModuleUUID,CHANNEL) end)
end
if channel then
    channel:SetHandler(function(data)
        if not M.Enabled or type(data)~='table' then return end
        if data.Kind=='CapState' and type(data.Active)=='boolean' then
            region=tostring(data.Region or 'unknown')
            cap=tonumber(data.Cap) or 0
            capActive=data.Active
            capUpdates=capUpdates+1
            scheduleGates()
        elseif data.FullBlock==true and (tonumber(data.Amount) or 0)>0 then
            blocked()
        end
    end)
end
function M.Status()
    return {version=M.Version,enabled=M.Enabled,cap=cap,region=region,
            active=capActive,signals=signals,foundGates=foundGates,
            tagWrites=tagWrites,xpFound=xpFound,firstError=firstError}
end
_G.HB_ActXPNotificationSuppress=M
return M
