-- AddCreaturetoParty.lua
-- Recruits Spore Servants / bound undead into the party while their status exists,
-- and removes them the moment that status is removed.
--
-- Important fix:
-- Cleanup no longer depends on Lua-only tracking tables surviving a reload.
-- If CCREATURE_SPORE_SERVANT is removed for any reason, cleanup always runs.

local RECRUIT_STATUSES = {
  ["CCREATURE_SPORE_SERVANT"] = true,
  ["BIND_UNDEAD"] = true,
}

local PRIMARY_STATUS = "CCREATURE_SPORE_SERVANT"

local RECRUIT_DELAY_MS = 500
local CLEANUP_RETRY_DELAYS_MS = { 0, 400, 1200, 2500 }
local SWEEP_INTERVAL_MS = 10000

local Owner = {}

local function SafeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    Ext.Utils.PrintError("[Recruit/Cleanup] Error: " .. tostring(result))
    return nil
  end
  return result
end

local function GetAllPlayers()
  local players = {}
  local rows = SafeCall(Osi.DB_Players.Get, Osi.DB_Players, nil)

  if rows then
    for _, row in pairs(rows) do
      local player = row[1]
      if player and player ~= "" then
        players[#players + 1] = player
      end
    end
  end

  return players
end

local function GetPartyFollowerRows()
  if not Osi.DB_PartyFollowers or not Osi.DB_PartyFollowers.Get then
    return nil
  end

  local ok, rows = pcall(Osi.DB_PartyFollowers.Get, Osi.DB_PartyFollowers, nil, nil)
  if not ok then
    return nil
  end

  return rows
end

local function HasRecruitStatus(target)
  if not target or target == "" then return false end

  for status, _ in pairs(RECRUIT_STATUSES) do
    local hasStatus = SafeCall(Osi.HasActiveStatus, target, status)
    if hasStatus == 1 then
      return true
    end
  end

  return false
end

local function IsDead(target)
  return SafeCall(Osi.IsDead, target) == 1
end

local function IsTrackedFollower(target)
  if not target or target == "" then return false end

  local rows = GetPartyFollowerRows()
  if not rows then return false end

  for _, row in pairs(rows) do
    local follower = row[1]
    if follower == target then
      return true
    end
  end

  return false
end

local function Recruit(owner, servant)
  if not owner or owner == "" then return end
  if not servant or servant == "" then return end
  if IsDead(servant) then return end
  if not HasRecruitStatus(servant) then return end

  SafeCall(Osi.SetFaction, servant, Osi.GetFaction(owner))
  SafeCall(Osi.AddPartyFollower, servant, owner)
  SafeCall(Osi.SetFollowCharacter, servant, owner)
  SafeCall(Osi.MakePlayerActive, servant)

  Owner[servant] = owner

  Ext.Utils.Print("[Recruit/Cleanup] Recruited " .. tostring(servant) .. " to " .. tostring(owner))
end

local function AttemptRemovePartyFollower(servant)
  if not servant or servant == "" then return end

  local owner = Owner[servant]
  if owner and owner ~= "" then
    SafeCall(Osi.RemovePartyFollower, servant, owner)
  end

  local players = GetAllPlayers()
  for _, player in ipairs(players) do
    SafeCall(Osi.RemovePartyFollower, servant, player)
  end
end

local function AttemptTidy(servant)
  if not servant or servant == "" then return end
  SafeCall(Osi.SetFaction, servant, Osi.GetBaseFaction(servant))
end

local function Cleanup(servant, reason)
  if not servant or servant == "" then return end

  Ext.Utils.Print("[Recruit/Cleanup] Cleanup started for " .. tostring(servant) .. (reason and (" (" .. reason .. ")") or ""))

  for _, delay in ipairs(CLEANUP_RETRY_DELAYS_MS) do
    Ext.Timer.WaitFor(delay, function()
      AttemptRemovePartyFollower(servant)

      if delay >= 400 then
        AttemptTidy(servant)
      end
    end)
  end

  Owner[servant] = nil
end

local function RebuildOwnersFromPartyFollowers()
  Owner = {}

  local rows = GetPartyFollowerRows()
  if not rows then
    Ext.Utils.Print("[Recruit/Cleanup] DB_PartyFollowers unavailable during rebuild; skipping.")
    return
  end

  for _, row in pairs(rows) do
    local follower = row[1]
    local owner = row[2]

    if follower and follower ~= "" and owner and owner ~= "" then
      Owner[follower] = owner
    end
  end

  Ext.Utils.Print("[Recruit/Cleanup] Rebuilt owner table from DB_PartyFollowers.")
end

local function CleanupInvalidFollowers()
  local rows = GetPartyFollowerRows()
  if not rows then return end

  for _, row in pairs(rows) do
    local follower = row[1]
    local owner = row[2]

    if follower and follower ~= "" then
      local isPlayer = (SafeCall(Osi.IsPlayer, follower) == 1)
      local isPartyMember = (SafeCall(Osi.IsPartyMember, follower) == 1)

      -- Ignore real player characters / normal party members.
      if not isPlayer and not isPartyMember then
        if owner and owner ~= "" then
          Owner[follower] = owner
        end

        local dead = IsDead(follower)
        local hasRecruit = HasRecruitStatus(follower)

        -- If it is dead OR it no longer has the recruit status, it must be removed.
        if dead or not hasRecruit then
          Cleanup(follower, dead and "Session/Sweep Dead" or "Session/Sweep MissingStatus")
        end
      end
    end
  end
end

local function Sweep()
  CleanupInvalidFollowers()
  Ext.Timer.WaitFor(SWEEP_INTERVAL_MS, Sweep)
end

Ext.Osiris.RegisterListener("StatusApplied", 4, "after",
  function(target, status, causee, storyActionID)
    if not RECRUIT_STATUSES[status] then return end
    if not target or target == "" then return end
    if not causee or causee == "" then return end

    Owner[target] = causee

    Ext.Timer.WaitFor(RECRUIT_DELAY_MS, function()
      if not IsDead(target) and HasRecruitStatus(target) then
        Recruit(causee, target)
      end
    end)
  end
)

Ext.Osiris.RegisterListener("StatusRemoved", 4, "after",
  function(target, status, causee, storyActionID)
    if not RECRUIT_STATUSES[status] then return end
    if not target or target == "" then return end

    -- Critical fix:
    -- Do NOT require Owner[target] or any Lua-tracked table entry here.
    -- After a reload, those tables are empty, but the status removal still matters.
    Cleanup(target, "StatusRemoved:" .. tostring(status))
  end
)

Ext.Osiris.RegisterListener("Died", 1, "after",
  function(target)
    if not target or target == "" then return end

    -- If they still have a recruit status, or they are in DB_PartyFollowers,
    -- force cleanup even after reload.
    if HasRecruitStatus(target) or IsTrackedFollower(target) then
      Cleanup(target, "Died")
    end
  end
)

Ext.Events.SessionLoaded:Subscribe(function()
  Ext.Timer.WaitFor(1500, function()
    RebuildOwnersFromPartyFollowers()
    CleanupInvalidFollowers()
    Sweep()
  end)
end)