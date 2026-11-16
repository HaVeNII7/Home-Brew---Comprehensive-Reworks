-- HomeBrew | Region-scoped XP caps (BG3 Script Extender, server only)
-- All three caps come from the active difficulty's integer ruleset modifiers.
-- Load once from BootstrapServer.lua: Ext.Require("Server/ActXPLevelCaps.lua")
-- Event-driven: no Tick subscriptions, gameplay polling, or repeating timers.
-- IMPORTANT: This corrects server XP AFTER the vanilla XP award; the combat-log
-- reward message may still appear. Inspect TotalExperience to verify the cap.

local M = { Version = "2.6-RulesetFloatCaps-Diagnostic" }

-- These sliders are RulesetModifierType=2 (FLOAT), Step=1, range 1-20.
-- Their displayed values are whole numbers, but the native Osiris query and
-- change event are GetRulesetModifierFloat / RulesetModifierChangedFloat.
-- Never infer caps from difficulty names or change the ruleset definitions.
local ACT_MODIFIER = {
    [1] = "MAX_LEVEL_ACT_1_2661c101-4f1f-46f9-86fd-ac21bc85611c",
    [2] = "MAX_LEVEL_ACT_2_8bfb10d9-de41-4c89-9912-76f22cac71fe",
    [3] = "MAX_LEVEL_ACT_3_69c018a6-a20e-4cd2-a18e-d37065097cf9",
}

-- The native event can report either a typed Name_UUID token or the bare
-- modifier UUID. Retain both spellings and never infer a cap from difficulty.
local ACT_UUID = {
    [1] = "2661c101-4f1f-46f9-86fd-ac21bc85611c",
    [2] = "8bfb10d9-de41-4c89-9912-76f22cac71fe",
    [3] = "69c018a6-a20e-4cd2-a18e-d37065097cf9",
}
local function validCap(raw)
    local v = tonumber(raw)
    if v and v == v and v >= 1 and v <= 20 and v % 1 == 0 then return v end
    return nil
end
local function changedAct(modifier)
    if modifier == nil then return nil end
    local v = tostring(modifier):lower()
    for act = 1, 3 do
        if v == ACT_MODIFIER[act]:lower() or v == ACT_UUID[act] then return act end
    end
    return nil
end

local REGION_ACT = {
    WLD_Main_A = 1, -- Wilderness, Underdark, Grymforge
    CRE_Main_A = 1, -- Mountain Pass / Creche
    SCL_Main_A = 2, -- Shadow-Cursed Lands
    BGO_Main_A = 3, -- Rivington, Wyrm's Crossing
    CTY_Main_A = 3, -- Lower City
}

local COLLECT_MS = 60
local VERIFY_MS = 90
local MAX_VERIFY_RETRIES = 1
-- Keep only a short-lived record of an actual positive XP award immediately
-- preceding a level unlock. Do not mistake level-up UI/respec for an XP award.
local CAP_AWARD_EVIDENCE_MS = 2000
local CAP_OVERFLOW_SETTLE_MS = 110
local CAP_OVERFLOW_RETRY_MS = 130
local CAP_OVERFLOW_MAX_RETRIES = 2

local saved = {}  -- UUID -> last settled, observed Experience state
local session = 0
local subscribed = false
local regionAtCamp = nil
local warned = {}
-- Native change events are authoritative during a live difficulty edit. They
-- bridge the interval before GetRulesetModifierFloat exposes the new setting.
-- Cleared on SessionLoading; never persisted into the save or to disk.
local eventCaps = {}
local modifierEventCount = 0
local lastModifierChange = nil
local confirmRefreshGeneration = 0
local STATUS_ID = "LEVEL_CAP_REACHED"
-- Only a newly observed cap-level unlock produces a diagnostic. Normal XP,
-- status checks, and travel never write to disk.
local OVERFLOW_REPORT = "HomeBrew/Diagnostics/HB_ActXP_Overflow_Diagnostics.txt"
local boundaryReport = {}
local boundaryReportQueued = false
local function recordBoundary(message)
    if #boundaryReport >= 40 then return end
    boundaryReport[#boundaryReport + 1] = tostring(message)
    if boundaryReportQueued then return end
    boundaryReportQueued = true
    local generation = session
    Ext.Timer.WaitFor(850, function()
        if generation ~= session then return end
        boundaryReportQueued = false
        if Ext.IO and Ext.IO.SaveFile then
            pcall(Ext.IO.SaveFile, OVERFLOW_REPORT,
                "HomeBrew XP cap unlock diagnostic v2.3\n" .. table.concat(boundaryReport, "\n") .. "\n")
        end
        boundaryReport = {}
    end)
end
local function formatXP(x)
    if not x then return "nil" end
    return "total=" .. tostring(x.total) .. " current=" .. tostring(x.current)
        .. " next=" .. tostring(x.nextXP) .. " available=" .. tostring(x.available)
        .. " spent=" .. tostring(x.spent)
end

local function warnOnce(id, message)
    if warned[id] then return end
    warned[id] = true
    if Ext and Ext.Log and Ext.Log.PrintWarning then
        Ext.Log.PrintWarning("[HB_ActXPLevelCaps] " .. message)
    end
end

local function attempt(fn, ...)
    if type(fn) ~= "function" and type(fn) ~= "userdata" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function regionOf(uuid)
    local r = uuid and attempt(Osi.GetRegion, uuid)
    return r and tostring(r) or nil
end

local function findRegion(uuid)
    local here = regionOf(uuid)
    if REGION_ACT[here] ~= nil then return here end
    -- Only companions in a separate camp map inherit host-region context.
    if type(here) == "string" and here:sub(1, 4) == "CMP_" then
        local hostRegion = regionOf(attempt(Osi.GetHostCharacter))
        if REGION_ACT[hostRegion] ~= nil then return hostRegion end
        if REGION_ACT[regionAtCamp] ~= nil then return regionAtCamp end
    end
    return nil -- unknown is deliberately uncapped
end

local function partyEntity(entity)
    return entity ~= nil and entity.PartyMember ~= nil and entity.Experience ~= nil
end

local function entityFor(uuid)
    local e = attempt(Ext.Entity.Get, uuid)
    return partyEntity(e) and e or nil
end

local function entityUuid(entity)
    local ok, value = pcall(function() return entity.Uuid.EntityUuid end)
    return ok and value ~= nil and tostring(value) or nil
end

local function num(value)
    local n = tonumber(value)
    if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
    return nil
end

-- Resolve either form of the Osiris RULESETMODIFIER identifier. Query the
-- typed name first (used elsewhere in HomeBrew), then the bare UUID if needed.
-- Never use a preset name, guessed level, or global hardcoded default.
local function nativeActCap(act)
    local token = ACT_MODIFIER[act]
    if not token then return nil, "unknown-act" end
    local value = validCap(attempt(Osi.GetRulesetModifierFloat, token))
    if value then return value, "name-uuid" end
    value = validCap(attempt(Osi.GetRulesetModifierFloat, ACT_UUID[act]))
    if value then return value, "bare-uuid" end
    return nil, "unavailable"
end

local function readRegionCap(region)
    local act = REGION_ACT[region]
    if not act then return nil end
    local live = nativeActCap(act)
    local reported = eventCaps[act]
    if reported and reported.generation == session then
        -- If the Osiris query has caught up, return to using it exclusively.
        if live == reported.value then
            eventCaps[act] = nil
            return live
        end
        -- The engine has explicitly reported a changed integer modifier, but
        -- its Get query can lag during difficulty confirmation. Use the native
        -- event value until a matching live read or another event arrives.
        return reported.value
    end
    if live then return live end
    warnOnce("ruleset_cap_" .. tostring(act),
        "Could not read valid 1-20 ruleset cap for act " .. tostring(act)
        .. " (" .. ACT_MODIFIER[act] .. "); XP is left unchanged until it is available")
    return nil
end

local function snapshot(e)
    local exp = e.Experience
    return {
        total = num(exp.TotalExperience),
        current = num(exp.CurrentLevelExperience),
        nextXP = num(exp.NextLevelExperience),
        available = num(e.AvailableLevel and e.AvailableLevel.Level),
        spent = num(e.EocLevel and e.EocLevel.Level),
        canLevel = e.CanLevelUp ~= nil,
    }
end

local function remember(uuid, entity)
    local now = snapshot(entity)
    if not now.total then return nil end
    local state = { xp = now, generation = session }
    saved[uuid] = state
    return state
end

-- This is presentation/status state only. It does not change the tested XP
-- correction path and never creates a repeating watcher. A character is
-- considered capped as soon as the capped level is available (even before
-- completing the native level-up UI), matching _onExperience below.
local function syncCapStatus(uuid, entity)
    if not partyEntity(entity) then return end
    -- PartyMember can include temporary followers/summons; mark actual players
    -- and playable companions only, not creatures attached to the party.
    if attempt(Osi.IsPlayer, uuid) ~= 1 then return end
    local xp = snapshot(entity)
    local region = findRegion(uuid)
    local cap = region and readRegionCap(region)
    local level = math.max(xp.spent or 0, xp.available or 0)
    local required = type(cap) == "number" and level >= cap

    local active = attempt(Osi.HasActiveStatus, uuid, STATUS_ID)
    if active == nil then
        warnOnce("status_query", "Could not check " .. STATUS_ID .. " status")
        return
    end
    if required then
        if active == 1 then return end
        -- The user supplies StatusData. Do not spam invalid status applications
        -- or invent a status definition when it is not installed yet.
        if not attempt(Ext.Stats.Get, STATUS_ID) then
            warnOnce("status_missing", STATUS_ID .. " is not defined in StatusData yet")
            return
        end
        local ok, err = pcall(Osi.ApplyStatus, uuid, STATUS_ID, -1.0, 1)
        if not ok then warnOnce("status_apply", "Could not apply " .. STATUS_ID .. ": " .. tostring(err)) end
    elseif active == 1 then
        local ok, err = pcall(Osi.RemoveStatus, uuid, STATUS_ID)
        if not ok then warnOnce("status_remove", "Could not remove " .. STATUS_ID .. ": " .. tostring(err)) end
    end
end

local function syncPartyCapStatuses()
    local list = attempt(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if not list then return end
    for _, entity in pairs(list) do
        if partyEntity(entity) then
            local uuid = entityUuid(entity)
            if uuid then syncCapStatus(uuid, entity) end
        end
    end
end

local function syncCharacterCapStatus(uuid)
    local e = uuid and entityFor(uuid)
    if e then syncCapStatus(tostring(uuid), e) end
end

local statusRefreshQueued = false
local function scheduleCapStatusRefresh(delay)
    -- Coalesce multiple companions transferring together into ONE refresh.
    if statusRefreshQueued then return end
    statusRefreshQueued = true
    local generation = session
    Ext.Timer.WaitFor(delay or 120, function()
        if generation ~= session then return end
        statusRefreshQueued = false
        syncPartyCapStatuses()
    end)
end

local function seedParty()
    local list = attempt(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    if not list then return end
    for _, entity in pairs(list) do
        if partyEntity(entity) then
            local uuid = entityUuid(entity)
            if uuid and not saved[uuid] then remember(uuid, entity) end
        end
    end
end

local function ensureSubscription()
    if subscribed then return end
    local ok, result = pcall(Ext.Entity.Subscribe, "Experience", function(entity)
        local success, err = pcall(M._onExperience, entity)
        if not success then warnOnce("callback", "XP component listener failed: " .. tostring(err)) end
    end)
    if not ok or result == nil then
        warnOnce("subscribe", "Could not attach to Experience component: " .. tostring(result))
        return
    end
    subscribed = true
end

local function start()
    ensureSubscription()
    seedParty()
    syncPartyCapStatuses()
end

-- A small, precise component correction is preferable to calling
-- AddExplorationExperience(-n) for each party member: that Osiris call has
-- party-wide effects and must not be invoked once per companion.
local function repairExperience(e, target, state)
    local old = state.xp
    local now = snapshot(e)
    if not now.total or now.total <= target then return true end
    local removed = now.total - target
    local fullReversal = target == old.total

    local ok, err = pcall(function()
        e.Experience.TotalExperience = target
        if fullReversal then
            if old.current then e.Experience.CurrentLevelExperience = old.current end
            if old.nextXP then e.Experience.NextLevelExperience = old.nextXP end
        elseif now.current then
            -- For the one reward that crosses the threshold, remove only the
            -- overshoot from the game's currently observed level XP counter.
            e.Experience.CurrentLevelExperience = math.max(0, now.current - removed)
        end
        e:Replicate("Experience")
    end)
    if not ok then
        warnOnce("experience_write", "Could not correct XP component: " .. tostring(err))
        return false
    end

    if fullReversal and old.available and e.AvailableLevel then
        local available = num(e.AvailableLevel.Level)
        if available and available ~= old.available then
            local levelOK, levelErr = pcall(function()
                e.AvailableLevel.Level = old.available
                e:Replicate("AvailableLevel")
            end)
            if not levelOK then
                warnOnce("level_write", "Could not restore available level: " .. tostring(levelErr))
            end
        end
        -- Do not reset EocLevel: the script must never de-level a character.
        if old.canLevel == false and e.CanLevelUp ~= nil then
            local removeOK, removeErr = pcall(function() e:RemoveComponent("CanLevelUp") end)
            if not removeOK then warnOnce("level_marker", "Could not remove extra level-up marker: " .. tostring(removeErr)) end
        elseif old.canLevel == true and e.CanLevelUp == nil then
            local createOK, createErr = pcall(function() e:CreateComponent("CanLevelUp") end)
            if not createOK then warnOnce("level_marker", "Could not restore level-up marker: " .. tostring(createErr)) end
        end
    end
    return true
end

local function finish(uuid, state)
    if saved[uuid] ~= state or state.generation ~= session then return end
    state.pending = false
    state.target = nil
    local e = entityFor(uuid)
    if e then
        state.xp = snapshot(e)
    else
        saved[uuid] = nil
    end
end

local function verify(uuid, state, tries)
    if saved[uuid] ~= state or state.generation ~= session then return end
    local e = entityFor(uuid)
    if not e then return finish(uuid, state) end
    local actual = num(e.Experience.TotalExperience)
    if actual and state.target and actual > state.target then
        if tries < MAX_VERIFY_RETRIES and repairExperience(e, state.target, state) then
            Ext.Timer.WaitFor(VERIFY_MS, function() verify(uuid, state, tries + 1) end)
            return
        end
        warnOnce("verify_" .. uuid, "XP correction was not retained by the engine for " .. uuid)
    end
    finish(uuid, state)
end

-- A native LeveledUp event can arrive before or after the Experience
-- component notification. Only its combination with a recent positive XP
-- change from cap-1 qualifies for a one-time overflow correction.
local queueOverflowCheck

local function recordNearCapAward(uuid, state, before, after, cap, region)
    local previousLevel = math.max(before.spent or 0, before.available or 0)
    if previousLevel ~= cap - 1 or after.total <= before.total then return end
    local record = {
        before = before,
        gainedTotal = after.total,
        cap = cap,
        region = region,
    }
    state.capAward = record
    local generation = session
    Ext.Timer.WaitFor(CAP_AWARD_EVIDENCE_MS, function()
        if generation == session and saved[uuid] == state and state.capAward == record then
            state.capAward = nil
            state.capUnlockEvent = nil
        end
    end)
    if state.capUnlockEvent and state.capUnlockEvent.cap == cap then
        queueOverflowCheck(uuid, state)
    end
end

local function process(uuid, state)
    if saved[uuid] ~= state or state.generation ~= session then return end
    local e = entityFor(uuid)
    if not e then return finish(uuid, state) end
    local now = snapshot(e)
    if not now.total or now.total <= state.target then return finish(uuid, state) end
    if not repairExperience(e, state.target, state) then return finish(uuid, state) end
    Ext.Timer.WaitFor(VERIFY_MS, function() verify(uuid, state, 0) end)
end

function M._onExperience(entity)
    if not partyEntity(entity) then return end
    local uuid = entityUuid(entity)
    if not uuid then return end
    local now = snapshot(entity)
    if not now.total then return end
    syncCapStatus(uuid, entity)
    local state = saved[uuid]
    if not state then
        -- This should be rare: party seeding occurs at load and on joining.
        -- Never subtract unknown pre-existing XP without a trustworthy baseline.
        remember(uuid, entity)
        return
    end
    if state.pending then return end -- includes our own replication notifications

    local before = state.xp
    if not before.total then state.xp = now; return end
    if now.total < before.total then
        -- HomeBrew respec/level restoration may temporarily drop then restore XP.
        state.restorationFloor = math.max(state.restorationFloor or 0, before.total)
        state.xp = now
        return
    end
    if now.total == before.total then
        -- If the available level updates before the XP award, retain the
        -- original lower-level baseline for the immediately following event.
        -- This is not itself evidence of an XP reward.
        local region = findRegion(uuid)
        local cap = region and readRegionCap(region)
        if type(cap) == "number"
           and math.max(before.available or 0, before.spent or 0) == cap - 1
           and math.max(now.available or 0, now.spent or 0) >= cap then
            local candidate = {cap = cap, region = region, before = before}
            state.preUnlockBaseline = candidate
            local generation = session
            Ext.Timer.WaitFor(CAP_AWARD_EVIDENCE_MS, function()
                if generation == session and saved[uuid] == state
                   and state.preUnlockBaseline == candidate then
                    state.preUnlockBaseline = nil
                end
            end)
        end
        -- Some engine updates publish AvailableLevel separately, without an
        -- additional XP delta or reliably ordered Osiris event. We have a
        -- recent real positive award from the previous level, so this is an
        -- independent authoritative indication that the cap was unlocked.
        if state.capAward and type(cap) == "number"
           and state.capAward.cap == cap and state.capAward.region == region
           and math.max(before.available or 0, before.spent or 0) == cap - 1
           and math.max(now.available or 0, now.spent or 0) >= cap then
            state.capUnlockEvent = {cap = cap, source = "component-no-delta"}
            recordBoundary("AvailableLevel changed without XP delta for " .. uuid
                .. " now[" .. formatXP(now) .. "]")
            queueOverflowCheck(uuid, state)
        end
        state.xp = now
        return
    end
    local baseline = before.total
    if state.restorationFloor then
        if now.total <= state.restorationFloor then
            state.xp = now
            if now.total == state.restorationFloor then state.restorationFloor = nil end
            return
        end
        -- XP beyond the restored snapshot is potentially a new reward.
        baseline = state.restorationFloor
        state.restorationFloor = nil
    end

    local region = findRegion(uuid)
    local cap = region and readRegionCap(region)
    if not cap then state.xp = now; return end
    -- Preserve evidence of the actual award even if BG3 updates AvailableLevel
    -- and emits LeveledUp AFTER this XP component callback. If the level event
    -- arrived first AND a separate zero-XP component update already replaced
    -- our baseline, recover the pre-unlock snapshot from that event.
    local unlock = state.capUnlockEvent
    local crossingBefore = before
    if unlock and unlock.cap == cap and unlock.before and not state.capAward
       and math.max(before.available or 0, before.spent or 0) >= cap
       and now.total > unlock.before.total then
        crossingBefore = unlock.before
    end
    -- Never record a respec replay: restoration-floor handling above exits first.
    recordNearCapAward(uuid, state, crossingBefore, now, cap, region)

    -- In BG3 the Experience subscriber can already see AvailableLevel at the
    -- newly unlocked cap before either Osiris event is delivered. Treat that
    -- verified cap-1 -> cap XP transition as the unlock signal itself. The
    -- earlier v2.2 handler waited for an Osiris event, letting real overflow
    -- remain if no subsequent event was observed in its short evidence window.
    local crossingLevel = math.max(crossingBefore.spent or 0, crossingBefore.available or 0)
    local newLevel = math.max(now.spent or 0, now.available or 0)
    if state.capAward and state.capAward.cap == cap
       and crossingLevel == cap - 1 and newLevel == cap then
        state.capUnlockEvent = {cap = cap, source = "experience-crossing"}
        recordBoundary("Cap level observed in XP callback for " .. uuid
            .. " now[" .. formatXP(now) .. "]")
        -- Do not perform the ordinary already-capped full-award reversal on
        -- the *first* unlock: that could remove XP needed to earn the level.
        state.xp = now
        queueOverflowCheck(uuid, state)
        return
    end

    local reachedCapBefore = (before.spent or 0) >= cap or (before.available or 0) >= cap
    if crossingBefore ~= before then reachedCapBefore = false end
    local reachedCapNow = (now.spent or 0) >= cap
    local target = nil
    if reachedCapBefore or reachedCapNow then
        target = baseline -- at the cap: zero newly retained XP
    elseif (now.available or 0) >= cap then
        -- Reward that FIRST unlocks the capped level: clip only the overflow.
        -- NextLevelExperience on the PRE-reward component provides the next
        -- threshold for characters one level below the cap, including custom
        -- XP curves. Never assume vanilla 6500/42000 thresholds.
        if (crossingBefore.available or crossingBefore.spent or 0) == cap - 1
           and crossingBefore.nextXP and crossingBefore.nextXP > crossingBefore.total
           and crossingBefore.nextXP <= now.total then
            target = crossingBefore.nextXP
        end
        -- When the component does not expose a trustworthy crossing threshold,
        -- leave this ONE reward untouched; subsequent XP at the cap is blocked.
        -- Guessing a threshold could damage a custom XP progression.
    end

    if target == nil or now.total <= target then
        state.xp = now
        return
    end
    state.pending = true
    state.target = target
    Ext.Timer.WaitFor(COLLECT_MS, function() process(uuid, state) end)
end

-- The engine can report the level unlock before its Experience component
-- has settled. A bounded one-shot check gives it time to normalize.
-- We never rewrite AvailableLevel, EocLevel, NextLevelExperience or XPData.
local function attemptCapOverflow(uuid, state, retries)
    if saved[uuid] ~= state or state.generation ~= session then return end
    local reward = state.capAward
    local unlock = state.capUnlockEvent
    if not reward or not unlock or reward.cap ~= unlock.cap then
        if reward then recordBoundary("Overflow check has no matching unlock for " .. uuid) end
        return
    end
    local region = findRegion(uuid)
    local cap = region and readRegionCap(region)
    if region ~= reward.region or cap ~= reward.cap then
        recordBoundary("Overflow check region/cap changed for " .. uuid)
        return
    end
    if state.pending then
        if retries < CAP_OVERFLOW_MAX_RETRIES then
            Ext.Timer.WaitFor(CAP_OVERFLOW_RETRY_MS, function()
                attemptCapOverflow(uuid, state, retries + 1)
            end)
        end
        return
    end
    local e = entityFor(uuid)
    if not e or attempt(Osi.IsPlayer, uuid) ~= 1 then return end
    local now = snapshot(e)
    local available = math.max(now.available or 0, now.spent or 0)
    if available < cap or now.total == nil then
        recordBoundary("Waiting for cap availability " .. uuid .. " now[" .. formatXP(now) .. "]")
        if retries < CAP_OVERFLOW_MAX_RETRIES then
            Ext.Timer.WaitFor(CAP_OVERFLOW_RETRY_MS, function()
                attemptCapOverflow(uuid, state, retries + 1)
            end)
        end
        return
    end
    -- Never try to fix a multi-level unlock or a character already beyond
    -- the cap. That would require changing AvailableLevel and is not safe.
    if available ~= cap then return end
    local prior = reward.before
    if math.max(prior.available or 0, prior.spent or 0) ~= cap - 1
       or not prior.total or now.total <= prior.total then return end

    -- CurrentLevelExperience may describe either XP gained toward the next
    -- level or the cumulative XP required to reach the current level. Check
    -- both possibilities against the pre-award TotalExperience and the exact
    -- positive XP delta. Never zero a cumulative level threshold.
    local current = now.current
    local earned = now.total - prior.total
    local target, mode, rewriteCurrent
    if current ~= nil and current > 0 and current <= earned then
        local threshold = now.total - current
        if threshold > prior.total and threshold <= now.total then
            target, mode, rewriteCurrent = threshold, "progress", true
        end
    end
    if not target and current ~= nil and current > prior.total and current <= now.total then
        target, mode, rewriteCurrent = current, "cumulative-threshold", false
    end
    if not target then
        recordBoundary("Overflow component fields not yet interpretable for " .. uuid
            .. " prior[" .. formatXP(prior) .. "] now[" .. formatXP(now)
            .. "] earned=" .. tostring(earned))
        if retries < CAP_OVERFLOW_MAX_RETRIES then
            Ext.Timer.WaitFor(CAP_OVERFLOW_RETRY_MS, function()
                attemptCapOverflow(uuid, state, retries + 1)
            end)
        end
        return
    end
    if target == now.total then
        recordBoundary("Overflow already zero for " .. uuid)
        state.capAward, state.capUnlockEvent = nil, nil
        return
    end
    if prior.nextXP and prior.nextXP > prior.total and prior.nextXP <= now.total
       and prior.nextXP ~= target then
        -- A stale NextLevelExperience hint does not override an actual
        -- post-unlock reading validated by the observed positive XP award.
        recordBoundary("Pre-award NextLevelExperience disagrees for " .. uuid
            .. " hint=" .. tostring(prior.nextXP) .. " target=" .. tostring(target))
    end
    recordBoundary("CORRECT " .. uuid .. " cap=" .. tostring(cap)
        .. " mode=" .. mode .. " excess=" .. tostring(now.total - target)
        .. " total=" .. tostring(now.total) .. " target=" .. tostring(target)
        .. " via=" .. tostring(unlock.source))
    state.capAward = nil
    state.capUnlockEvent = nil
    state.pending = true
    state.target = target
    local ok, err = pcall(function()
        e.Experience.TotalExperience = target
        if rewriteCurrent then e.Experience.CurrentLevelExperience = 0 end
        e:Replicate("Experience")
    end)
    if not ok then
        warnOnce("overflow_write_" .. uuid,
            "Could not clear XP carryover for " .. uuid .. ": " .. tostring(err))
        return finish(uuid, state)
    end
    Ext.Timer.WaitFor(VERIFY_MS, function() verify(uuid, state, 0) end)
end

queueOverflowCheck = function(uuid, state)
    if state.overflowQueued then return end
    state.overflowQueued = true
    local generation = session
    Ext.Timer.WaitFor(CAP_OVERFLOW_SETTLE_MS, function()
        if generation ~= session or saved[uuid] ~= state then return end
        state.overflowQueued = false
        attemptCapOverflow(uuid, state, 0)
    end)
end

local function onCapUnlockEvent(uuid, oldLevel, newLevel)
    local e = uuid and entityFor(uuid)
    if not e or attempt(Osi.IsPlayer, uuid) ~= 1 then return end
    local region = findRegion(uuid)
    local cap = region and readRegionCap(region)
    if type(cap) ~= "number" then return end
    local state = saved[tostring(uuid)]
    if not state or state.generation ~= session then return end
    local award = state.capAward
    local now = snapshot(e)
    local observed = math.max(now.available or 0, now.spent or 0)
    local crossing = oldLevel ~= nil and newLevel ~= nil
        and oldLevel == cap - 1 and newLevel == cap
    if crossing or award then
        recordBoundary("Osiris cap event " .. tostring(uuid)
            .. " old=" .. tostring(oldLevel) .. " new=" .. tostring(newLevel)
            .. " evidence=" .. tostring(award ~= nil) .. " now[" .. formatXP(now) .. "]")
    end
    if not crossing then
        -- LeveledUp has no old/new parameters in BG3; accept it only when
        -- there is evidence of a recent award made while exactly cap-1.
        -- This event may precede the ECS AvailableLevel write. Its exact
        -- timing is not proof of a cap unlock, so the deferred correction
        -- still requires AvailableLevel == cap and a real pre-cap XP award.
        crossing = award ~= nil and award.cap == cap
            and math.max(award.before.available or 0, award.before.spent or 0) == cap - 1
    end
    if not crossing then return end
    local unlock = {cap = cap, source = oldLevel and "ObjectAvailableLevelChanged" or "LeveledUp"}
    local pre = state.preUnlockBaseline
    if crossing and pre and pre.cap == cap and pre.region == region then
        unlock.before = pre.before
    elseif crossing and state.xp and math.max(state.xp.available or 0, state.xp.spent or 0) == cap - 1 then
        unlock.before = state.xp
    end
    state.capUnlockEvent = unlock
    -- When a level becomes available without an XP award (e.g. respec), do
    -- not leave a permanent trigger that could affect a later restoration.
    local generation = session
    local id = tostring(uuid)
    Ext.Timer.WaitFor(CAP_AWARD_EVIDENCE_MS, function()
        if generation == session and saved[id] == state and state.capUnlockEvent == unlock then
            state.capUnlockEvent = nil
        end
    end)
    if award and award.cap == cap then queueOverflowCheck(id, state) end
end

-- Manual verification from server console (no routine console spam):
-- _D(Mods["HomeBrew - Comprehensive Reworks_486d1526-3505-4b09-9790-0f6a60f5ac0f"].HB_ActXPLevelCaps.Status())
function M.Status(uuid)
    local requested = uuid or attempt(Osi.GetHostCharacter)
    local e = requested and entityFor(requested)
    local data = e and snapshot(e)
    local region = requested and findRegion(requested)
    local state = requested and saved[tostring(requested)]
    return {
        loaded = true,
        version = M.Version,
        subscribed = subscribed,
        region = region or "unrecognized",
        cap = region and readRegionCap(region) or nil,
        act = region and REGION_ACT[region] or nil,
        rulesetModifier = region and ACT_MODIFIER[REGION_ACT[region]] or nil,
        rulesetRead = region and select(2, nativeActCap(REGION_ACT[region])) or nil,
        rulesetQueryType = "Float",
        rulesetLiveCap = region and select(1, nativeActCap(REGION_ACT[region])) or nil,
        rulesetEventCap = region and eventCaps[REGION_ACT[region]] and eventCaps[REGION_ACT[region]].value or nil,
        rulesetEventsSeen = modifierEventCount,
        lastRulesetEvent = lastModifierChange,
        totalXP = data and data.total,
        currentXP = data and data.current,
        nextXP = data and data.nextXP,
        spentLevel = data and data.spent,
        availableLevel = data and data.available,
        trackedXP = state and state.xp and state.xp.total,
        pendingCorrection = state and state.pending or false,
        capStatus = STATUS_ID,
        capStatusActive = requested and attempt(Osi.HasActiveStatus, requested, STATUS_ID) == 1 or false,
        capOverflowEvidence = state and state.capAward ~= nil or false,
        capOverflowUnlockSeen = state and state.capUnlockEvent ~= nil or false,
        overflowVersion = "2.3-CapUnlockComponent",
    }
end

-- Optional, event-scoped ruleset diagnostic. No polling or writes during XP
-- changes, travel, combat, rest, or ordinary status reconciliation.
-- The file is replaced after a confirmed difficulty-related event, or only
-- when explicitly requested from the server console.
local RULESET_DIAGNOSTIC_PATH = "HomeBrew/Diagnostics/HB_ActXP_Ruleset_Diagnostics.txt"
local diagnosticSnapshots = {}
local function rulesetReadForDiagnostics(identifier)
    if not (Osi and Osi.GetRulesetModifierFloat) then return "unavailable" end
    local ok, value, extra = pcall(Osi.GetRulesetModifierFloat, identifier)
    if not ok then return "ERROR:" .. tostring(value) end
    return tostring(value) .. (extra ~= nil and (" / " .. tostring(extra)) or "")
end
local function diagnosticSnapshot(label)
    local out = {"--- " .. tostring(label) .. " ---",
        "script=" .. tostring(M.Version),
        "session=" .. tostring(session),
        "experienceSubscribed=" .. tostring(subscribed),
        "rulesetChangeEvents=" .. tostring(modifierEventCount),
        "lastModifierEvent=" .. tostring(lastModifierChange),
        "difficultyRefreshGeneration=" .. tostring(confirmRefreshGeneration)}
    for act = 1, 3 do
        local reported = eventCaps[act]
        local live, source = nativeActCap(act)
        local effective = (reported and reported.generation == session
            and live ~= reported.value) and reported.value or live
        out[#out + 1] = ("act=%d token=%s typedRaw=%s uuidRaw=%s live=%s liveSource=%s event=%s effective=%s")
            :format(act, ACT_MODIFIER[act],
                rulesetReadForDiagnostics(ACT_MODIFIER[act]),
                rulesetReadForDiagnostics(ACT_UUID[act]),
                tostring(live), tostring(source),
                tostring(reported and reported.value or nil), tostring(effective))
    end
    local list = attempt(Ext.Entity.GetAllEntitiesWithComponent, "PartyMember")
    local count = 0
    if list then
        for _, entity in pairs(list) do
            if partyEntity(entity) then
                local uuid = entityUuid(entity)
                if uuid then
                    local isPlayer = attempt(Osi.IsPlayer, uuid)
                    if isPlayer == 1 then
                        count = count + 1
                        local xp = snapshot(entity)
                        local region = findRegion(uuid)
                        local act = region and REGION_ACT[region]
                        local reported = act and eventCaps[act]
                        local live = act and select(1, nativeActCap(act)) or nil
                        local cap = (reported and reported.generation == session
                            and live ~= reported.value) and reported.value or live
                        local level = math.max(xp.spent or 0, xp.available or 0)
                        local actual = attempt(Osi.HasActiveStatus, uuid, STATUS_ID)
                        out[#out + 1] = ("player=%s region=%s act=%s level=%s spent=%s available=%s cap=%s expectedStatus=%s actualStatus=%s totalXP=%s currentXP=%s")
                            :format(uuid, tostring(region), tostring(act), tostring(level),
                                tostring(xp.spent), tostring(xp.available), tostring(cap),
                                tostring(type(cap) == "number" and level >= cap),
                                tostring(actual), tostring(xp.total), tostring(xp.current))
                    end
                end
            end
        end
    end
    out[#out + 1] = "playablePartyCount=" .. tostring(count)
    return table.concat(out, "\n")
end
local function rememberDiagnosticSnapshot(label)
    -- A diagnostic must never prevent a ruleset update or status refresh.
    local ok, captured = pcall(diagnosticSnapshot, label)
    diagnosticSnapshots[#diagnosticSnapshots + 1] = ok and captured
        or ("--- " .. tostring(label) .. " ---\nDiagnosticCaptureError=" .. tostring(captured))
    if #diagnosticSnapshots > 8 then table.remove(diagnosticSnapshots, 1) end
end
local function writeRulesetDiagnostic(label)
    rememberDiagnosticSnapshot(label)
    if not (Ext.IO and (type(Ext.IO.SaveFile) == "function" or type(Ext.IO.SaveFile) == "userdata")) then
        return {ok = false, reason = "Ext.IO.SaveFile unavailable", path = RULESET_DIAGNOSTIC_PATH}
    end
    local body = "HomeBrew Regional XP Cap Ruleset Diagnostic\n"
        .. "Diagnostic only: XP and statuses unchanged by capture.\n"
        .. "No repeating timers or XP-event log writes.\n\n"
        .. table.concat(diagnosticSnapshots, "\n\n") .. "\n"
    local ok, result = pcall(Ext.IO.SaveFile, RULESET_DIAGNOSTIC_PATH, body)
    return {ok = ok and result ~= false, reason = ok and tostring(result) or tostring(result),
        path = RULESET_DIAGNOSTIC_PATH, snapshots = #diagnosticSnapshots}
end
-- Manual fallback when BG3 does not emit either modifier/difficulty event:
-- _D(Mods["HomeBrew - Comprehensive Reworks_486d1526-3505-4b09-9790-0f6a60f5ac0f"].HB_ActXPLevelCaps.WriteDiagnostic())
function M.WriteDiagnostic()
    return writeRulesetDiagnostic("manual-server-console")
end

Ext.Events.SessionLoading:Subscribe(function()
    session = session + 1
    saved = {}
    regionAtCamp = nil
    warned = {}
    eventCaps = {}
    modifierEventCount = 0
    lastModifierChange = nil
    confirmRefreshGeneration = 0
    diagnosticSnapshots = {}
    statusRefreshQueued = false
    boundaryReport = {}
    boundaryReportQueued = false
end)
Ext.Events.SessionLoaded:Subscribe(start)
Ext.Events.ResetCompleted:Subscribe(start)
Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(region)
    if REGION_ACT[region] ~= nil then regionAtCamp = region end
    start()
    -- At this early point the player's Osiris region may still be the old one.
    -- Check once more after transfer finishes, with no ongoing timer.
    scheduleCapStatusRefresh(120)
end)
Ext.Osiris.RegisterListener("LevelGameplayReady", 2, "after", function(region)
    if REGION_ACT[region] ~= nil then regionAtCamp = region end
    syncPartyCapStatuses()
end)
Ext.Osiris.RegisterListener("TeleportedToFromCamp", 1, "after", function(uuid)
    -- This also fires for nonparty NPCs. Don't scan the party for those.
    local e = entityFor(uuid)
    if e and attempt(Osi.IsPlayer, uuid) == 1 then
        syncCapStatus(tostring(uuid), e)
        scheduleCapStatusRefresh(120)
    end
end)
Ext.Osiris.RegisterListener("ObjectAvailableLevelChanged", 3, "after", function(uuid, oldLevel, newLevel)
    syncCharacterCapStatus(uuid)
    onCapUnlockEvent(uuid, num(oldLevel), num(newLevel))
end)
Ext.Osiris.RegisterListener("LeveledUp", 1, "after", function(uuid)
    syncCharacterCapStatus(uuid)
    onCapUnlockEvent(uuid)
end)
Ext.Osiris.RegisterListener("RespecCompleted", 1, "after", function(uuid)
    syncCharacterCapStatus(uuid)
    local generation = session
    Ext.Timer.WaitFor(120, function()
        if generation == session then syncCharacterCapStatus(uuid) end
    end)
end)
-- On a Custom Mode commit, native RulesetModifierChangedFloat provides the
-- *new* cap, which may arrive before the corresponding Get query is updated.
-- Capture that exact event value, apply status promptly, and run one bounded
-- post-commit reconciliation. XP correction still consults readRegionCap.
local function scheduleCommittedDifficultyRefresh()
    confirmRefreshGeneration = confirmRefreshGeneration + 1
    local ticket = confirmRefreshGeneration
    local generation = session
    Ext.Timer.WaitFor(600, function()
        if generation ~= session or ticket ~= confirmRefreshGeneration then return end
        syncPartyCapStatuses()
        writeRulesetDiagnostic("post-confirm-600ms")
    end)
end
Ext.Osiris.RegisterListener("RulesetModifierChangedFloat", 3, "after", function(modifier, oldValue, newValue)
    local act = changedAct(modifier)
    if not act then return end
    local newCap = validCap(newValue)
    if not newCap then
        warnOnce("invalid_rule_change_" .. tostring(act),
            "Ruleset event for act " .. tostring(act) .. " supplied invalid cap " .. tostring(newValue))
        return
    end
    modifierEventCount = modifierEventCount + 1
    lastModifierChange = "act=" .. tostring(act) .. " old=" .. tostring(oldValue)
        .. " new=" .. tostring(newCap) .. " id=" .. tostring(modifier)
    rememberDiagnosticSnapshot("modifier-event-before-override")
    eventCaps[act] = {value = newCap, generation = session}
    -- This event has the correct committed value, so do not wait for a second
    -- gameplay XP event to show the status. Avoid duplicate status changes.
    syncPartyCapStatuses()
    rememberDiagnosticSnapshot("modifier-event-after-sync")
    scheduleCommittedDifficultyRefresh()
end)
Ext.Osiris.RegisterListener("DifficultyChanged", 1, "after", function()
    rememberDiagnosticSnapshot("difficulty-changed-event")
    scheduleCapStatusRefresh(120)
    scheduleCommittedDifficultyRefresh()
end)

-- One-off, explicit server-console diagnostic. Never writes during ordinary XP
-- rewards, traveling, or rest. If a live difficulty change is not reflected,
-- server console: _D(Mods["HomeBrew - Comprehensive Reworks_486d1526-3505-4b09-9790-0f6a60f5ac0f"].HB_ActXPLevelCaps.Status())
function M.Refresh()
    syncPartyCapStatuses()
    return M.Status()
end

Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
    syncPartyCapStatuses()
end)
Ext.Osiris.RegisterListener("CharacterJoinedParty", 1, "after", function(uuid)
    local e = entityFor(uuid)
    if e then
        remember(tostring(uuid), e)
        syncCapStatus(tostring(uuid), e)
    end
end)
Ext.Osiris.RegisterListener("CharacterLeftParty", 1, "after", function(uuid)
    saved[tostring(uuid)] = nil
    if attempt(Osi.HasActiveStatus, uuid, STATUS_ID) == 1 then
        attempt(Osi.RemoveStatus, uuid, STATUS_ID)
    end
end)

-- Export only for explicit, one-off server-console inspection.
_G.HB_ActXPLevelCaps = M
return M
