-- Five explicit HomeBrew spell-list filters.
-- Exact SpellList IDs and exact spell names were extracted from the supplied
-- SpellLists.lsx. No class identity, subclass, or progression inference.
-- Changing a checkbox ONLY alters display of native available spell tiles.
local M={}
local OPTIONS={
    { Guid="63c89951-2cc1-4597-9d4b-b80d90b56803", Name="Cleric / Paladin", DisplayName="Cleric / Paladin", Spells={
        ["Target_AbsorbElements"]=true, ["Target_AegisProtection"]=true, ["Shout_Aid"]=true, ["Target_AnimateDead"]=true, ["Teleportation_ArcaneGate"]=true,
        ["Target_ArcaneLock"]=true, ["Shout_ArmsOfHadar"]=true, ["Shout_AuraOfLife"]=true, ["Target_Banishment"]=true, ["Shout_BarrierOfHolding"]=true,
        ["Target_BeaconOfHope"]=true, ["Target_Bless"]=true, ["Target_BloodBroker"]=true, ["Target_BloodOffering"]=true, ["Target_CallLightning"]=true,
        ["Target_CalmEmotions"]=true, ["Projectile_ChainLightning"]=true, ["Target_CircleOfDeath"]=true, ["Target_Cloudkill"]=true, ["Target_Command_Container"]=true,
        ["Target_CompelledDuel"]=true, ["Shout_CorpseBinder"]=true, ["Shout_CrusadersMantle"]=true, ["Target_CureWounds"]=true, ["Target_DeathWard"]=true,
        ["Target_DispelEvilAndGood"]=true, ["Target_DivineFavor"]=true, ["Target_FlameStrike"]=true, ["Target_EnhanceAbility"]=true, ["Target_FaerieFire"]=true,
        ["Shout_FalseLife"]=true, ["Shout_FeatherFall"]=true, ["Target_ForceField"]=true, ["Shout_FrostflameArmament"]=true, ["Target_GlobeOfInvulnerability"]=true,
        ["Target_Goodberry"]=true, ["Target_Invisibility_Greater"]=true, ["Target_GreaterRestoration"]=true, ["Target_GuardianOfFaith"]=true, ["Projectile_GuidingBolt"]=true,
        ["Projectile_Harm"]=true, ["Target_Haste"]=true, ["Target_Heal"]=true, ["Target_HealingSpirit"]=true, ["Target_HealingWord"]=true,
        ["Shout_HellishRebuke"]=true, ["Target_HeroesFeast"]=true, ["Target_Heroism"]=true, ["Target_Hex"]=true, ["Target_HoldMonster"]=true,
        ["Target_InflictWounds"]=true, ["Target_InvictusAeterna"]=true, ["Target_LesserRestoration"]=true, ["Shout_CureWounds_Mass"]=true, ["Shout_HealingWord_Mass"]=true,
        ["Target_NaturesEmbrace"]=true, ["Target_ResilientSphere"]=true, ["Target_RemoveCurse"]=true, ["Projectile_RendLife"]=true, ["Teleportation_Revivify"]=true,
        ["Target_Sanctuary"]=true, ["Shout_ShadowBlade"]=true, ["Target_ShieldOfFaith"]=true, ["Target_Silence"]=true, ["Target_Slow"]=true,
        ["Projectile_SolarFlare"]=true, ["Target_SoulPrism"]=true, ["Zone_SoulReaver"]=true, ["Shout_SpiritGuardians"]=true, ["Zone_SpiritBlade"]=true,
        ["Shout_SpiritualShroud"]=true, ["Target_SpiritualWeapon"]=true, ["Zone_Sunbeam"]=true, ["Projectile_TearsofUmberlee"]=true, ["Target_Transposition"]=true,
        ["Target_VampiricTouch"]=true, ["Target_VitriolicTouch"]=true, ["Target_AuraOfVitality"]=true, ["Target_WardingBond"]=true, ["Target_WitherAndBloom"]=true,
    }, Count=80 },
    { Guid="4174e244-89fb-46f8-a953-c73cad0a8c56", Name="Druid / Ranger", DisplayName="Druid / Ranger", Spells={
        ["Target_AbsorbElements"]=true, ["Shout_AcidicPheromones"]=true, ["Shout_Aid"]=true, ["Shout_AuraOfLife"]=true, ["Target_Barkskin"]=true,
        ["Target_BeaconOfHope"]=true, ["Target_BladeStorm"]=true, ["Target_Bless"]=true, ["Target_Blight"]=true, ["Target_Blindness"]=true,
        ["Shout_Catnap"]=true, ["Target_CharmPerson"]=true, ["Target_Cloudkill"]=true, ["Zone_ConeOfCold"]=true, ["Zone_ConjureBarrage"]=true,
        ["Shout_WillOWisp"]=true, ["Target_Contagion"]=true, ["Shout_CrusadersMantle"]=true, ["Target_CureWounds"]=true, ["Target_Darkness"]=true,
        ["Target_Darkvision"]=true, ["Shout_EarthTremor"]=true, ["Wall_ElementalWalls"]=true, ["Target_ElementalWeapon"]=true, ["Target_EnhanceAbility"]=true,
        ["Shout_LongJump"]=true, ["Projectile_EnsnaringStrike_Container"]=true, ["Target_Entangle"]=true, ["Target_EruptingEarth"]=true, ["Shout_FelineFrenzy"]=true,
        ["Target_FindFamiliar"]=true, ["Target_FlamingSphere"]=true, ["Target_FreedomOfMovement"]=true, ["Target_Goodberry"]=true, ["Target_Fly"]=true,
        ["Target_GraspingVine"]=true, ["Target_GreaterRestoration"]=true, ["Zone_GustOfWind"]=true, ["Projectile_HailOfThorns"]=true, ["Projectile_Harm"]=true,
        ["Target_Haste"]=true, ["Target_Heal"]=true, ["Target_HealingSpirit"]=true, ["Target_HealingWord"]=true, ["Target_HeroesFeast"]=true,
        ["Target_HuntersMark"]=true, ["Target_LesserRestoration"]=true, ["Projectile_LightningArrow"]=true, ["Shout_Longstrider"]=true, ["Shout_CureWounds_Mass"]=true,
        ["Shout_HealingWord_Mass"]=true, ["Target_MaximiliansEarthenGrasp"]=true, ["Target_Moonbeam"]=true, ["Target_NaturesEmbrace"]=true, ["Target_NaturesGrasp"]=true,
        ["Target_Polymorph"]=true, ["Projectile_RayOfSickness"]=true, ["Teleportation_Revivify"]=true, ["Target_SandCoffin"]=true, ["Target_Sanctuary"]=true,
        ["Zone_ScatterShot"]=true, ["Target_SeismicEruption"]=true, ["Shout_Sleep"]=true, ["Target_SleetStorm"]=true, ["Shout_SnillocsSnowballStorm"]=true,
        ["Projectile_SolarFlare"]=true, ["Target_SoulPrism"]=true, ["Target_SpikeGrowth"]=true, ["Zone_SpiritBlade"]=true, ["Target_Stoneskin"]=true,
        ["Zone_Sunbeam"]=true, ["Projectile_TearsofUmberlee"]=true, ["Zone_TidalWave"]=true, ["Zone_TorrentialSpear"]=true, ["Target_AuraOfVitality"]=true,
        ["Target_WardingBond"]=true, ["Shout_WaterWalk"]=true, ["Shout_Whirlpool"]=true, ["Target_WitherAndBloom"]=true, ["Shout_ZephyrStrike"]=true,
    }, Count=80 },
    { Guid="a3c79518-7d3b-416c-8c78-470fb1a23c28", Name="Sorcerer / Barbarian", DisplayName="Sorcerer / Barbarian", Spells={
        ["Target_StinkingCloud"]=true, ["Target_ArcaneVisage"]=true, ["Target_ArcaneVortex"]=true, ["Target_Banishment"]=true, ["Target_Barkskin"]=true,
        ["Target_Blindness"]=true, ["Target_Blink"]=true, ["Target_Blur"]=true, ["Target_CallLightning"]=true, ["Target_CalmEmotions"]=true,
        ["Shout_Catnap"]=true, ["Target_CauseFear"]=true, ["Projectile_ChainLightning"]=true, ["Target_CharmPerson"]=true, ["Projectile_ChromaticOrb"]=true,
        ["Zone_ColorSpray"]=true, ["Target_Confusion"]=true, ["Target_Counterspell"]=true, ["Target_CrownOfMadness"]=true, ["Target_Darkvision"]=true,
        ["Shout_DestructiveWave"]=true, ["Projectile_Disintegrate"]=true, ["Shout_DetectMagic"]=true, ["Target_DissonantWhispers"]=true, ["Target_DominatePerson"]=true,
        ["Wall_ElementalWalls"]=true, ["Target_ElementalWeapon"]=true, ["Target_EnlargeReduce"]=true, ["Target_Entangle"]=true, ["Target_EruptingEarth"]=true,
        ["Target_BlackTentacles"]=true, ["Target_Eyebite"]=true, ["Target_FaerieFire"]=true, ["Zone_Fear"]=true, ["Shout_FelineFrenzy"]=true,
        ["Projectile_Fireball"]=true, ["Shout_FireShield"]=true, ["Target_FlameBlade"]=true, ["Target_FlamingSphere"]=true, ["Target_FleshToStone"]=true,
        ["Target_Fly"]=true, ["Target_Grease"]=true, ["Target_HoldMonster"]=true, ["Target_HypnoticPattern"]=true, ["Projectile_IceKnife"]=true,
        ["Projectile_Implode"]=true, ["Target_IntellectFortress"]=true, ["Target_Invisibility"]=true, ["Shout_KineticJaunt"]=true, ["Zone_LightningBolt"]=true,
        ["Target_MageArmor"]=true, ["Projectile_MagicMissile"]=true, ["Target_MaximiliansEarthenGrasp"]=true, ["Projectile_AcidArrow"]=true, ["Shout_MinuteMeteors"]=true,
        ["Shout_MirrorImage"]=true, ["Projectile_FreezingSphere"]=true, ["Target_Polymorph"]=true, ["Target_RemoveCurse"]=true, ["Target_RimesBindingIce"]=true,
        ["Target_SandCoffin"]=true, ["Target_SeismicEruption"]=true, ["Shout_ShadowBlade"]=true, ["Target_Shatter"]=true, ["Target_Silence"]=true,
        ["Shout_Sleep"]=true, ["Target_SleetStorm"]=true, ["Target_Slow"]=true, ["Shout_SnillocsSnowballStorm"]=true, ["Zone_SpewAcid"]=true,
        ["Throw_Telekinesis"]=true, ["Target_TelekineticTethers"]=true, ["Zone_TelekineticWave"]=true, ["Zone_Thunderwave"]=true, ["Target_ThunderStep"]=true,
        ["Zone_TidalWave"]=true, ["Zone_TorrentialSpear"]=true, ["Target_Transposition"]=true, ["Target_VitriolicTouch"]=true, ["Shout_Whirlpool"]=true,
    }, Count=80 },
    { Guid="f33b1b19-43c6-4f61-a001-cd55e516791c", Name="Warlock / Fighter", DisplayName="Warlock / Fighter", Spells={
        ["Target_StinkingCloud"]=true, ["Shout_AcidicPheromones"]=true, ["Shout_ArmorOfAgathys"]=true, ["Shout_ArmsOfHadar"]=true, ["Target_BladeStorm"]=true,
        ["Target_Blight"]=true, ["Target_BloodBroker"]=true, ["Target_BloodOffering"]=true, ["Zone_BurningHands"]=true, ["Target_CauseFear"]=true,
        ["Target_CircleOfDeath"]=true, ["Target_CloudOfDaggers"]=true, ["Target_Command_Container"]=true, ["Target_CompelledDuel"]=true, ["Target_Confusion"]=true,
        ["Zone_ConjureBarrage"]=true, ["Target_Contagion"]=true, ["Target_CrownOfMadness"]=true, ["Target_Darkness"]=true, ["Projectile_Disintegrate"]=true,
        ["Target_DispelEvilAndGood"]=true, ["Target_DissonantWhispers"]=true, ["Target_DivineFavor"]=true, ["Target_FlameStrike"]=true, ["Target_DominatePerson"]=true,
        ["Projectile_EnsnaringStrike_Container"]=true, ["Target_BlackTentacles"]=true, ["Target_Eyebite"]=true, ["Shout_FalseLife"]=true, ["Zone_Fear"]=true,
        ["Shout_FireShield"]=true, ["Target_FlameBlade"]=true, ["Target_FleshToStone"]=true, ["Target_FrostFingers"]=true, ["Shout_FrostflameArmament"]=true,
        ["Zone_Gilgamesh"]=true, ["Target_GraspingVine"]=true, ["Target_GuardianOfFaith"]=true, ["Projectile_GuidingBolt"]=true, ["Projectile_HailOfThorns"]=true,
        ["Target_Hellfire"]=true, ["Shout_HellishRebuke"]=true, ["Target_Heroism"]=true, ["Target_Hex"]=true, ["Target_HungerOfHadar"]=true,
        ["Target_HuntersMark"]=true, ["Target_IceStorm"]=true, ["Target_InflictWounds"]=true, ["Target_InvictusAeterna"]=true, ["Projectile_LightningArrow"]=true,
        ["Projectile_AcidArrow"]=true, ["Shout_MindguardSurge"]=true, ["Target_MindPiercer"]=true, ["Target_MindSpike"]=true, ["Target_MistyStep"]=true,
        ["Target_Moonbeam"]=true, ["Target_NathairsMischief"]=true, ["Projectile_FreezingSphere"]=true, ["Target_IrresistibleDance"]=true, ["Target_PhantasmalForce"]=true,
        ["Target_PhantasmalKiller"]=true, ["Target_PsionicLockdown"]=true, ["Target_PsionicSwordfall"]=true, ["Projectile_RayOfEnfeeblement"]=true, ["Projectile_RayOfSickness"]=true,
        ["Target_Antagonize"]=true, ["Projectile_RendLife"]=true, ["Target_RimesBindingIce"]=true, ["Projectile_ScorchingRay"]=true, ["Target_Shatter"]=true,
        ["Shout_Shield_Wizard"]=true, ["Zone_SoulReaver"]=true, ["Target_SpikeGrowth"]=true, ["Shout_SpiritGuardians"]=true, ["Shout_SpiritualShroud"]=true,
        ["Zone_TashasCausticBrew"]=true, ["Target_HideousLaughter"]=true, ["Target_ThunderStep"]=true, ["Target_VampiricTouch"]=true, ["Projectile_WitchBolt"]=true,
    }, Count=80 },
    { Guid="8e57e7e8-af23-4621-a64a-3cf34b57676c", Name="Wizard / Rogue", DisplayName="Wizard / Rogue", Spells={
        ["Target_AegisProtection"]=true, ["Target_AnimateDead"]=true, ["Teleportation_ArcaneGate"]=true, ["Target_ArcaneLock"]=true, ["Target_ArcaneVisage"]=true,
        ["Target_ArcaneVortex"]=true, ["Shout_ArmorOfAgathys"]=true, ["Shout_BarrierOfHolding"]=true, ["Target_Blink"]=true, ["Target_Blur"]=true,
        ["Zone_BurningHands"]=true, ["Projectile_ChromaticOrb"]=true, ["Target_CloudOfDaggers"]=true, ["Zone_ColorSpray"]=true, ["Zone_ConeOfCold"]=true,
        ["Shout_WillOWisp"]=true, ["Shout_CorpseBinder"]=true, ["Target_Counterspell"]=true, ["Target_DeathWard"]=true, ["Shout_DestructiveWave"]=true,
        ["Shout_DetectMagic"]=true, ["Shout_EarthTremor"]=true, ["Shout_LongJump"]=true, ["Target_EnlargeReduce"]=true, ["Shout_FeatherFall"]=true,
        ["Target_FindFamiliar"]=true, ["Projectile_Fireball"]=true, ["Target_ForceField"]=true, ["Target_FreedomOfMovement"]=true, ["Target_FrostFingers"]=true,
        ["Target_GlobeOfInvulnerability"]=true, ["Zone_Gilgamesh"]=true, ["Target_Grease"]=true, ["Target_Invisibility_Greater"]=true, ["Zone_GustOfWind"]=true,
        ["Target_Hellfire"]=true, ["Target_HungerOfHadar"]=true, ["Target_HypnoticPattern"]=true, ["Projectile_IceKnife"]=true, ["Target_IceStorm"]=true,
        ["Projectile_Implode"]=true, ["Target_IntellectFortress"]=true, ["Target_Invisibility"]=true, ["Shout_KineticJaunt"]=true, ["Zone_LightningBolt"]=true,
        ["Shout_Longstrider"]=true, ["Target_MageArmor"]=true, ["Projectile_MagicMissile"]=true, ["Shout_MindguardSurge"]=true, ["Target_MindPiercer"]=true,
        ["Shout_MinuteMeteors"]=true, ["Target_MindSpike"]=true, ["Shout_MirrorImage"]=true, ["Target_MistyStep"]=true, ["Target_NathairsMischief"]=true,
        ["Target_NaturesGrasp"]=true, ["Target_ResilientSphere"]=true, ["Target_IrresistibleDance"]=true, ["Target_PhantasmalForce"]=true, ["Target_PhantasmalKiller"]=true,
        ["Target_PsionicLockdown"]=true, ["Target_PsionicSwordfall"]=true, ["Projectile_RayOfEnfeeblement"]=true, ["Target_Antagonize"]=true, ["Zone_ScatterShot"]=true,
        ["Projectile_ScorchingRay"]=true, ["Shout_Shield_Wizard"]=true, ["Target_ShieldOfFaith"]=true, ["Zone_SpewAcid"]=true, ["Target_SpiritualWeapon"]=true,
        ["Target_Stoneskin"]=true, ["Zone_TashasCausticBrew"]=true, ["Target_HideousLaughter"]=true, ["Throw_Telekinesis"]=true, ["Target_TelekineticTethers"]=true,
        ["Zone_TelekineticWave"]=true, ["Zone_Thunderwave"]=true, ["Shout_WaterWalk"]=true, ["Projectile_WitchBolt"]=true, ["Shout_ZephyrStrike"]=true,
    }, Count=80 },
}
function M.Build()
    return M.Summary()
end
function M.Reset() end
function M.GetOptions()
    return OPTIONS
end
function M.Summary()
    local unique={}
    for _,option in ipairs(OPTIONS) do
        for id in pairs(option.Spells) do unique[id]=true end
    end
    local total=0
    for _ in pairs(unique) do total=total+1 end
    return {Classes=5, Lists=5, Spells=total, HBPools=5}
end
return M
