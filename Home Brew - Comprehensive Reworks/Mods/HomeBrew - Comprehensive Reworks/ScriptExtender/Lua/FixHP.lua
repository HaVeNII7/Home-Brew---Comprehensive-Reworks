local Listeners = {}

local function FixHp(Entity)

    local reservations = Entity
        and Entity.ShapeshiftHealthReservation
        and Entity.ShapeshiftHealthReservation.Reservations

    if reservations and reservations["00000000-0000-0000-0000-000000000000"] then
        local guid = Entity.Uuid and Entity.Uuid.EntityUuid
        if not guid or not Entity.Health then return end
        if Osi.IsPlayer(guid) == 1 or Osi.IsInCombat(guid) == 1 then return end
        local Hp = Entity.Health.Hp
        local MaxHp = Entity.Health.MaxHp

        if Hp == MaxHp then
            Entity.ShapeshiftHealthReservation.Reservations["00000000-0000-0000-0000-000000000000"] = 9999
            Entity:Replicate("ShapeshiftReplicatedChanges")
        end
    end
end

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "before", function(level, isEditor)

    for subscriptionId, _ in pairs(Listeners) do
        Ext.Entity.Unsubscribe(subscriptionId)
    end

    Listeners = {}

end)

Ext.Osiris.RegisterListener("LevelGameplayReady", 2, "after", function(level, isEditor)
	if level == "SYS_CC_I" then return end

    local subscriptionId = Ext.Entity.OnCreateDeferred("ServerCharacter", function(Entity, character)
		FixHp(Entity)
	end)

	local Characters = Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter")

    for _, Entity in pairs(Characters) do
        FixHp(Entity)
	end

	Listeners[subscriptionId] = true
end)
