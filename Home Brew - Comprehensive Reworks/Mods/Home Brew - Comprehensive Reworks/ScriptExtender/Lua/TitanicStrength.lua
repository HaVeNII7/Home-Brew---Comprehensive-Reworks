-- Barebones: allow dual wielding 2H melee weapons if you have the passive
local PASSIVE = "TitanicStrength"
local modified = {} -- modified[itemUuid] = true

-- Bit flags used by the script you shared:
-- TwoHanded: 1024, Versatile: 2048, Melee: 4096
local TWO_HANDED = 1024
local VERSATILE  = 2048
local MELEE      = 4096

local function ModifyWeapon(item)
    local entity = item
    if type(item) == "string" then
        entity = Ext.Entity.Get(item)
    end
    if not entity or not entity.Weapon then return end

    local uuid = entity.Uuid.EntityUuid

    -- Only melee + two-handed weapons
    local props = entity.Weapon.WeaponProperties
    if (props & MELEE) ~= MELEE then return end
    if (props & TWO_HANDED) ~= TWO_HANDED then return end
    if modified[uuid] then return end

    modified[uuid] = true

    -- Flip TwoHanded -> Versatile
    entity.Weapon.WeaponProperties = props ~ TWO_HANDED ~ VERSATILE

    -- Provide versatile damage data
    entity.Weapon.Rolls2 = entity.Weapon.Rolls
    entity.Weapon.VersatileDamageDice = entity.Weapon.DamageDice

    entity:Replicate("Weapon")

    -- Optional tooltip refresh
    Osi.SetCanExamine(uuid, 0)
end

local function RestoreWeapon(item)
    local entity = item
    if type(item) == "string" then
        entity = Ext.Entity.Get(item)
    end
    if not entity or not entity.Weapon then return end

    local uuid = entity.Uuid.EntityUuid
    if not modified[uuid] then return end
    modified[uuid] = nil

    -- Flip back Versatile -> TwoHanded
    entity.Weapon.WeaponProperties = entity.Weapon.WeaponProperties ~ TWO_HANDED ~ VERSATILE

    entity.Weapon.Rolls2 = {}
    entity.Weapon.VersatileDamageDice = "Default"

    entity:Replicate("Weapon")
    Osi.SetCanExamine(uuid, 1)
end

-- engine check sees the modified props
Ext.Osiris.RegisterListener("RequestCanUse", 3, "before", function(character, item, requestID)
    if Osi.HasPassive(character, PASSIVE) == 1 then
        ModifyWeapon(item)
    end
end)

Ext.Osiris.RegisterListener("Equipped", 2, "before", function(item, character)
    if Osi.HasPassive(character, PASSIVE) == 1 then
        ModifyWeapon(item)
    end
end)

Ext.Osiris.RegisterListener("Unequipped", 2, "before", function(item, character)
    if Osi.HasPassive(character, PASSIVE) == 1 then
        RestoreWeapon(item)
    end
end)
