local SIF_KeepInitiativeStatus = "SIF_NEVER_SHARE"

local function SyncInitiative(summon)
    local owner = Osi.CharacterGetOwner(summon)
    if not owner or owner == "00000000-0000-0000-0000-000000000000" then return end
    local summonEntity = Ext.Entity.Get(summon)
    local ownerEntity = Ext.Entity.Get(owner)
    local joinEvent = summonEntity and summonEntity.CombatantJoinEvent
    local combatState = joinEvent and joinEvent.Combat and joinEvent.Combat.CombatState
    if not ownerEntity or not combatState then return end
    local summonCombat = combatState.MyGuid
    if not summonCombat then return end
    local ownerCombat
    local joiningMidCombat

    local ownerJoinEvent = ownerEntity.CombatantJoinEvent
    local ownerCombatState = ownerJoinEvent and ownerJoinEvent.Combat and ownerJoinEvent.Combat.CombatState
    if ownerCombatState then
        ownerCombat = ownerCombatState.MyGuid
        joiningMidCombat = false
    else
        ownerCombat = Osi.CombatGetGuidFor(owner)
        joiningMidCombat = true
    end

    if not ownerCombat or ownerCombat ~= summonCombat then
        return
    end

    local summonRoll = summonEntity.CombatantJoinEvent.Initiative
    local ownerRoll

    if joiningMidCombat then
        if not ownerEntity.CombatParticipant then return end
        ownerRoll = ownerEntity.CombatParticipant.InitiativeRoll
    else
        ownerRoll = ownerEntity.CombatantJoinEvent.Initiative
    end

    if ownerRoll ~= nil and summonRoll ~= nil and ownerRoll ~= summonRoll then
        print("Adjusting " .. Osi.ResolveTranslatedString(Osi.GetDisplayName(summon)) .. "'s initiative roll from " .. summonRoll .. " to " .. ownerRoll .. ".")
        summonEntity.CombatantJoinEvent.Initiative = ownerRoll
    end
end

Ext.Entity.OnCreateDeferred("CombatantJoinEvent", function(entity)
    local entityUuid = entity and entity.Uuid and entity.Uuid.EntityUuid
    if not entityUuid then return end
    if Osi.IsSummon(entityUuid) == 1 and (Osi.HasActiveStatus(entityUuid, SIF_KeepInitiativeStatus) == 0 and Osi.HasActiveStatus(entityUuid, "ALWAYS_USE_OWN_INITIATIVE") == 0) then
        SyncInitiative(entityUuid)

        if Osi.HasActiveStatus(entityUuid, "ALWAYS_USE_OWN_INITIATIVE") == 1 then Ext.Utils.PrintWarning("[Summon Initiative Fixer] ALWAYS_USE_OWN_INITIATIVE status is deprecated; use SIF_NEVER_SHARE status.") end
    end
end)
