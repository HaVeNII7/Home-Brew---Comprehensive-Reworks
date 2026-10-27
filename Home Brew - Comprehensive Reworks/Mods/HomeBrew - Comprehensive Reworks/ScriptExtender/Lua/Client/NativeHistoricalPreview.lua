-- HB: experiment 4. Historical progression choices rendered over
-- the actual respec screen using HB's recorded level-up choices. Native
-- progression ViewModels remain read-only; staged replacements are routed to
-- the proven HB historical editor and its normal server-side validation.
-- Preserves the tested historical Edit Build replay workflow.
local TYPE = "HB_NativeHistoricalPreviewVM_RestoreV1"
local ROW_TYPE = "HB_HistoricalPassiveOptionVM"
local WIDGET = "HB_NativeHistoricalPreview"
local FILE = "HomeBrew/Diagnostics/HB_NativeLevelScreen_Diagnostics.txt"
local vmTypeRegistered = false
local snapshot, maximum, currentLevel, previewOpen = {}, 1, 1, false
local onReturn = nil
local onStagePassive, onStageResource, onStageOther = nil, nil, nil
local onNativeConfirm = nil
-- One slider, two game-owned contexts. L1 uses the original C++ ViewModel;
-- L2+ uses HB's existing staged historical wrapper. The state is kept in a
-- table to avoid Lua's per-function local limit in this large client script.
HB_NATIVE_L1_SLIDER={Screen=false,Touched=false,Pending=false,AutoConfirm=false,
    Prepared=false,OnPrepare=nil,FullRespecChanged=false,DisplacedSpellSlots={},
    PassiveDuplicateLevels={},DisplacedPassiveSlots={},
    UnrepresentedSpellConflicts={},
    LiveFirstPassiveIds={},PassiveCandidateIndex={},
    ObservedOriginalPassiveGroups={},
    PassiveSelectionsByGroup={},PassiveActiveGroups={}}
-- A vanilla level-one spell may displace a *recorded* higher-level pick.
-- These pending slots belong to Selective Respec, not BG3's C++ completeness VM.
function HB_NATIVE_L1_SLIDER.HasDisplacedSpellSlots()
    for _,choices in pairs(HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}) do
        for _,pending in pairs(choices) do if pending==true then return true end end
    end
    return false
end
function HB_NATIVE_L1_SLIDER.HasDisplacedPassiveSlots()
    for _,choices in pairs(HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {}) do
        for _,pending in pairs(choices) do if pending==true then return true end end
    end
    return false
end
function HB_NATIVE_L1_SLIDER.HasLaterLevelConflicts()
    if HB_NATIVE_L1_SLIDER.HasDisplacedSpellSlots()
        or HB_NATIVE_L1_SLIDER.HasDisplacedPassiveSlots() then return true end
    for _,active in pairs(HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts or {}) do
        if active then return true end
    end
    for _,conflict in pairs(HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels or {}) do
        if conflict==true then return true end
    end
    return false
end
function HB_NATIVE_L1_SLIDER.NativeLevelOneChoicesPending()
    return previewOpen and currentLevel==1 and HB_NATIVE_L1_SLIDER.Screen
        and not HB_NATIVE_L1_SLIDER.FullRespecChanged
        and HB_NATIVE_L1_SLIDER.HasLaterLevelConflicts()
end
-- A native level-one spell or passive may conflict with recorded selections
-- on several later levels. Return the earliest unresolved level.
function HB_NATIVE_L1_SLIDER.FirstPendingSpellLevel()
    local first=nil
    for level,choices in pairs(HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}) do
        local numeric=tonumber(level)
        if numeric and numeric>=2 then
            for _,pending in pairs(choices or {}) do
                if pending==true and (not first or numeric<first) then
                    first=numeric
                end
            end
        end
    end
    for level,active in pairs(HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts or {}) do
        local n=tonumber(level)
        if active and n and n>=2 and (not first or n<first) then first=n end
    end
    for level,choices in pairs(HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {}) do
        local numeric=tonumber(level)
        if numeric and numeric>=2 then
            for _,pending in pairs(choices or {}) do
                if pending==true and (not first or numeric<first) then first=numeric end
            end
        end
    end
    for level,conflict in pairs(HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels or {}) do
        local n=tonumber(level)
        if conflict==true and n and n>=2 and (not first or n<first) then first=n end
    end
    return first
end

local nativeCommitPending=false
local nativeCommitError=""
local passiveGroupIndex, armedFrom, passiveFeedback = 1, nil, ""
local passiveRows = {}
local previewResources, previewOther = {}, {}
-- Multifaceted's four feat-owned historical skill slots share one native
-- selector. An unchecked slot is UI-only until it receives its replacement;
-- never stage a partial deletion in CCLevelUp or the saved feat components.
-- Keep the ephemeral UI holes separate from the persistent CCLevelUp
-- staging callbacks. A named HB table avoids exceeding the large editor's
-- Lua top-level local-variable limit; it is cleared on each respec session.
HB_MULTIFACETED_UI={Unchecked={}}
-- Class/SubClass SelectSpells with multiple slots is one BG3 selector.
-- Virtual empty slots are UI-only until a valid replacement is staged.
HB_CLASS_SPELL_UI={Unchecked={}}
-- Match BG3's native skills panel order (abilities/skill families), not
-- alphabetical localization order. Unknown skills remain available after
-- known skills without changing the list UUID or its verified replay grants.
HB_MULTIFACETED_UI.SkillOrder={}
for i,id in ipairs({"Athletics","Acrobatics","SleightOfHand","Stealth",
    "Arcana","History","Investigation","Nature","Religion",
    "AnimalHandling","Insight","Medicine","Perception","Survival",
    "Deception","Intimidation","Performance","Persuasion"}) do
    HB_MULTIFACETED_UI.SkillOrder[id]=i
end
function HB_MULTIFACETED_UI.Clear()
    HB_MULTIFACETED_UI.Unchecked={}
end
function HB_MULTIFACETED_UI.RowKey(panel,row)
    if panel and panel.GroupedLevelOne then
        return table.concat({tostring(row.Kind),tostring(row.Source),
            tostring(row.EntryIndex),tostring(row.SlotIndex)},"|")
    end
    return tostring(row.From or "")
end
function HB_MULTIFACETED_UI.IsUnchecked(panel,row)
    return HB_MULTIFACETED_UI.Unchecked[HB_MULTIFACETED_UI.RowKey(panel,row)]==true
end
function HB_MULTIFACETED_UI.First(panel)
    -- Fill unselected skills in ORIGINAL historical slot order regardless of
    -- the order the player clicked checkboxes. This leaves replay deterministic.
    for _,row in ipairs((panel or {}).Rows or {}) do
        local original=tostring(row.From or "")
        if HB_MULTIFACETED_UI.IsUnchecked(panel,row) then return original end
    end
    return nil
end
function HB_MULTIFACETED_UI.Set(from,unchecked,panel)
    from=tostring(from or "")
    if from~="" then
        local key=from
        if panel and panel.GroupedLevelOne then
            for _,row in ipairs(panel.Rows or {}) do
                if tostring(row.From)==from then
                    key=HB_MULTIFACETED_UI.RowKey(panel,row)
                    break
                end
            end
        end
        HB_MULTIFACETED_UI.Unchecked[key]=unchecked and true or nil
    end
end
local queuedRefresh = false
local suppressSelect = false
local reported = {}
local notes = { "HB native historical UI bridge v23 (recorded spell provenance and original native selector)" }
local nativeReadout = "The native selector has not been inspected yet."
local probeCount = 0
local batchLogs = false
-- Native ViewModel proof-of-concept: a guarded interception of
-- BG3's *real* passive click command. Never alter the game's selected items.
local nativePilotActive = false
local nativePilotWrapping = false
-- Hide can arrive while Noesis is still switching between native C++ and
-- detached historical ViewModels. Do not dispose the holding overlay until
-- its original VM has been restored (or the restore has explicitly failed).
local nativeHideRequested=false
-- Original BG3 Cancel first opens its own discard-warning dialog. Preserve
-- the historical session and slider while that dialog is pending; only tear
-- down after the native screen actually closes. A No answer re-wraps the
-- still-mounted original native ViewModel after the warning is dismissed.
local nativeCancelAwaitingDecision=false
local cancelModalDiscoverySignature=nil
local nativeCancelSawDialog=false
local nativeCancelDialogGonePolls=0
local nativeCancelMissingPolls=0
-- A decline may allow BG3 to reassign its original CharacterRespec VM
-- after our deferred native rewrap. Check that the new historical wrapper
-- really remains attached rather than trusting the slider's visibility.
local nativeCancelRecoveryPending=false
local nativeCancelRecoveryChecks=0
-- Don't retain a Lua proxy to native DataContext across ticks. It expires.
-- Preserve the native object in a Noesis-owned Object property of our overlay
-- ViewModel, and fetch a new proxy from that property when stopping the test.
local nativePilotTypeRegistered = false
local nativePilotClicks = 0
-- Historical injection. Keep native game progression untouched:
-- custom selector collections live only in our temporary Noesis wrapper.
local nativePilotMode = "intercept"
local historicalGroupType = "HB_NativeHistoricalPassiveGroup_NativeProxyV2"
local historicalItemType = "HB_NativeHistoricalPassiveItem_TabV2"
local historicalDetailType = "HB_NativeHistoricalDetails_V1"
local historicalDescriptionType = "HB_NativeHistoricalDescription_V1"
local historicalTypesRegistered = false
local nativeHistoricalItems = {}
local nativePilotReport = "Native test inactive."
local nativeRefreshQueued = false
local nativeMenuGeneration = 0
local nativeFeatPreview=false
local HB_ELEMENTAL_ADEPT_FEAT="fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
local HB_ELEMENTAL_OPTIONS={}
for _,name in ipairs({"Acid","Cold","Fire","Force","Lightning","Necrotic",
    "Poison","Psychic","Radiant","Thunder"}) do
    HB_ELEMENTAL_OPTIONS[#HB_ELEMENTAL_OPTIONS+1]={PassiveId="ElementalAdept_"..name,
        DisplayNameFallback=name}
end
local previewNewElements={}

-- Generated from supplied HB Feats.lsx / FeatDescriptions.lsx and verified passive-list catalogs.
local HB_PASSIVE_PAIR_FEATS = {
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]={Name="AbilityImprovement",List="b9149c8e-52c8-46e5-9cb6-fc39301c05fe",Selector="FeatASI",
        Ids={"ASI_Strength","ASI_Dexterity","ASI_Constitution","ASI_Intelligence","ASI_Wisdom","ASI_Charisma"}},
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]={Name="ClassDivergence_Barbarian",List="d8183f3c-9c62-40b7-9418-e7ad07a8204e",Selector="",
        Ids={"BarbarousAssault","BrutalCritical","DangerSense","DeathGlare","Faceoff","FuriousCriticals","LandsStride","OverwhelmingPower","PeakPhysicality","RageoftheMountain","RageoftheUndefeated","RagingVitality","RelentlessRage","RipandTear","RootedinAnger","TemperedRetaliation","TerrifyingBellow","UnrelentingRampage","UnarmouredBeast","UnstoppableForce"}},
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]={Name="ClassDivergence_Bard",List="2e8c5dba-f49c-4f24-a850-05e61aefb4ef",Selector="",
        Ids={"Aggressive_Rhythm","Discerning_Insult","Distracting_Dissonance","Dueling_Ditties","Echoes_of_Fortitude","Encouraging_Momentum","Engaging_Composition","Guiding_Performance","Harmonious_Aura","Infuriating_Amplification","Inspirational_Resonance","Inspiring_Crescendo","Insufferable_Discord","Melodic_Precision","Mobile_Maestro","Mocksmith","Silver_Tongued_Savant","Soothing_Words","Unprecedented_Encore","Vigorously_Tuned"}},
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]={Name="ClassDivergence_Cleric",List="137c5bd5-c5a9-4185-aec9-70a583191f17",Selector="",
        Ids={"Aegis","Blessed_Resolve","BloodforBlood","Consecrative_Sacrifice","Divine_Resiliance","Divine_Restoration","Ethereal_Intuition","Flames_of_Repentance","Holy_Fortitude","Guided_Strikes","Holy_Retribution","Immaculate_Ward","Martyrdom","Paradisiacal_Gift","Sacral_Bulwark","Sanctified_Presence","Sanctifying_Aura","Stalwart","Stout_Believer","Venerational_Strikes"}},
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]={Name="ClassDivergence_Druid",List="82745b68-e0f8-49a2-a147-7ccac142b7d9",Selector="",
        Ids={"Armour_of_Thorns","Combats_Harvest","Earthern_Sentinel","Feral_Precision","Feral_Resiliance","Ferocious_Stand","Instinctive_Transformation","Kindred_Instinct","WildShape_Combat","Natural_Bounty","Natural_Resurgence","Natures_Mercy","Natures_Wrath","Pack_Leader","Primal_Bloodletter","Primal_Surge","Primal_Takedown","Shapechangers_Versatility","Territorial_Dominance","Wild_Stride"}},
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]={Name="ClassDivergence_Fighter",List="da3203d8-750a-4de1-b8eb-1eccfccddf46",Selector="",
        Ids={"Aspect_of_Defiance","Challengers_Call","Charge_of_the_Collective","Duellist","Full_Arsenal","Heavy_Assault","Intuitive_Warning","Ironclad","Iron_Will","Leaders_Momentum","Martial_Fortress","Martial_Reclaim","Merciless","Natural_Born_Leader","Opportunist","Proper_Form","Reckless_Abandon","Sentinels_Protection","Tactical_Retreat","Tunnel_Fighter"}},
    ["b441c722-e4d4-4702-861a-039bfd77c124"]={Name="ClassDivergence_Monk",List="1cafd528-b848-477b-9a3e-adfe4a989970",Selector="",
        Ids={"Counterflow","Critical_Flow","Dance_of_Flowing_Water","Deflective_Reflex","Dexterous_Ward","Fist_of_Crushing_Rock","Focused_Stream","Fortified_Psyche","Harmonious_Barrage","Harmonious_Defense","Martial_Empowerment","Mystic_Strikes","Opportune_Reversal","Resonance_of_Body","Sagacious_Resilience","Soused_Rampart","Tempestuous_Reprise","Tranquil_Fortitude","Windwaker","Zen_Accuracy"}},
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]={Name="ClassDivergence_Paladin",List="27e37640-a012-40f0-8ced-a398640dac75",Selector="",
        Ids={"Attonement","Critical_Oath","Death_Sentence","Divine_Health","Divine_Resurgence","Divine_Sense","Divine_Shielding","Holy_Bulwark","Holy_Wrath","Infallible_Beacon","Lay_On_Hands","Oathbound_Renewal","Oath_Channeling","Principle_of_Belief","Repel_the_Damned","Resplendent_Reverb","Smite_Makes_Right","Stalwart_Eruption","Stalwart_Resolve","Visage_of_Sanctity"}},
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]={Name="ClassDivergence_Ranger",List="fed4c4e9-fbe0-41d6-abc1-ee3dc5b80302",Selector="",
        Ids={"Ambush_Breaker","Ballistic_Infusion","Beastbonds_Precision","Beastial_Recovery","Blood_Bond","Bounty_Hunter","Close_Quarters_Shooter","Escapist","Explosive_Arrowheads","Hidden_Inventory","Marksmans_Edge","Multiattack_Defense","Natural_Huntsman","Natural_Opportunity","Protective_Bond","Sniper","Superior_Technique","Sure_Shot","Two_Weapon_Fighting","Wanton_Synergy"}},
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]={Name="ClassDivergence_Rogue",List="da3203d8-750a-4de1-b8eb-1eccfcc6a911",Selector="",
        Ids={"Cunning_Strikes","Cutthroat","Elusive_Retreat","Elusive_Shadow","Fast_Hands","Fatal_Manoeuvre","Grievous_Wounds","Illusory_Advantage","Light_Footwork","Low_Visibility","Manipulator","Now_You_See_Me","Quick_Reflexes","Reactive_Movement","Sharp_Eyes","CSpectre","Spectral_Hunter","Umbral_Sight","Vanishing_Act","Venomous"}},
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]={Name="ClassDivergence_Sorcerer",List="c3506532-36eb-4d18-823e-497a537a9619",Selector="",
        Ids={"ArcaneOverflow","ArcaneOppression","ArcaneReservoir","CharismaticInfusion","CharismaticShield","DormantCharge","ElementalAfterglow","EnchantingInfluence","EphemeralBarrier","EssentialEpiphany","EvasiveWarp","LatentAcuity","MistyEscape","MysticEmpowerment","NaturalVortex","ReactiveReprise","SharedCreation","SorcerousAcumen","SorcerousFocus","VeiledSynergy"}},
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]={Name="ClassDivergence_Warlock",List="fd7736fa-5c64-475e-a4c9-f4061690d8c4",Selector="",
        Ids={"BaneofthePact","BindingTransposition","BoundElements","BoundCompulsion","CurseofHellfire","DarkRetaliation","CDevilsSight","EldritchEnervation","EldritchLethargy","EldritchPull","HellishRebuttal","HellboundVision","LuckoftheDevil","MasterofChaos","OneWithShadows","PactProtection","PactStricken","RepellingBlast","ResiliantServitude","ShadeWalker"}},
    ["93d41226-d7af-495c-b023-08a6af077962"]={Name="ClassDivergence_Wizard",List="e5ab4424-e30b-4752-b280-51a5c77bc9c3",Selector="",
        Ids={"Arcane_Interruption","Arcane_Reverb","Arcane_Shield","Boon_of_Plumes","Edict_of_Divinity","Elemental_Countercharge","Enchanted_Safeguard","Flames_Riposte","Illusory_Phantasm","Magical_Insight","Mystic_Override","Potent_Cantrips","Potent_Spells","Spellblade","Spellbound_Rebirth","Spell_Surge","Telekinetic_Command","CWarMagic","Wizards_Clarity","Woven_Precision"}},
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={Name="ClassDivergence_Artificer",List="a8257cf3-7c6b-4627-a77c-760a064fc201",Selector="",
        Ids={"AdaptivePlating","ArcaneCalibrationMatrix","AutomatedArcaneSuppression","CastleDefense","DeadZoneCalibration","ElementalPayload","EmergencyPowerCell","FailsafeInjection","IncendiaryRounds","KineticFeedbackLoop","LikeClockwork","ModularAugmentation","NaniteDispersionField","Overclocked","PrecisionRifling","RecoilCompensation","Safeguard","SpeedLoader","SyntheticActionEconomy","VitalAim"}},
}

-- A new Multifaceted uses separate native choices but only one staged feat
-- transaction. These source catalogs are the exact HB PassiveLists.lsx rows.
HB_MULTIFACETED_NEW={Feat="be0889d2-f9aa-472d-b942-592bff0f1ef3"}
HB_MULTIFACETED_NEW.Catalog={
    Archetype={"AT_None","AT_ArcanePrecision","AT_ChaoticFortune","AT_CombatMastery","AT_ControlledAggro","AT_DeepenedResolve","AT_EmpoweredSummons","AT_FortifiedArmour","AT_ImposingWill","AT_IronBreaker","AT_IronFists","AT_MartialBalance","AT_MartialPrecision","AT_MeasuredArcana","AT_QuickReflexes","AT_ReactiveRetribution","AT_RestorativeTouch","AT_TemperedBody","AT_TemperedMind","AT_UncheckedForce","AT_WeaveBreaker"},
    Trait={"CT_None","CT_AdrenalineSurge","CT_BlindEmotions","CT_BloodyResults","CT_BorrowedTime","CT_BreatheDeep","CT_ConfidentlyIncorrect","CT_CriticalLoss","CT_Crybaby","CT_DelusionsintheDark","CT_Gambler","CT_GentleGiant","CT_GildedPilfer","CT_GlassCannon","CT_HandsofCalamity","CT_HastyReflexes","CT_Haymaker","CT_HealthyChills","CT_HeavyHanded","CT_Hyperfixation","CT_Ironbourne","CT_ImmovableBoulder","CT_Lefty","CT_LetMeSoloThem","CT_LoneWolf","CT_Narcoleptic","CT_NaturalMedium","CT_Overcharged","CT_OverlyDifficult","CT_Packing","CT_PlanarSkipping","CT_ReactiveLoss","CT_Reckless","CT_SlowRoller","CT_SplitFocus","CT_Stinky","CT_SunlightAversion","CT_Unhinged","CT_UnstableSource","CT_WaningImmortality","CT_Wretch"},
    Skills={"Athletics","Acrobatics","SleightOfHand","Stealth","Arcana",
        "History","Investigation","Nature","Religion","AnimalHandling",
        "Insight","Medicine","Perception","Survival","Deception",
        "Intimidation","Performance","Persuasion"},
}
HB_MULTIFACETED_NEW.Accord={
    Feat="cdcbc538-883b-401c-a8ed-1373fb6d1720",
    List="ffad33d2-e725-4655-ba80-0bc91e8002b3",
    Catalog={"Projectile_AcidSplash","Projectile_ArcaneBarrage","Projectile_ArcaneSpheres","Shout_BladeSurge","Shout_BladeWard","Target_ChillTouch","Projectile_Cragrain","Target_CreateorDestroyWater","Target_CreateorExtinguishFlames","Shout_DisguiseSelf","Shout_Druidcraft","Projectile_FireBolt","Target_Friends","Target_Frostbite","Target_GreenFlameBlade","Target_Guidance","Target_Light","Target_MageHand","Target_MindSliver","Projectile_PiercingTorrent","Projectile_PoisonSpray","Shout_Prestidigitation","Target_PrimalSavagery","Shout_ProduceFlame","Rush_PsionicCharge","Projectile_RayOfFrost","Target_Resistance","Target_SacredFlame","Target_ShockingGrasp","Target_SpareTheDying","Target_SparkSurge","Shout_Shillelagh","Throw_TelekineticHurl","Target_ThornWhip","Shout_Thunderclap","Target_ThunderousStrike","Target_TollTheDead","Target_TrueStrike","Projectile_Warpstone","Shout_WordOfRadiance"},
    Preview={}, Unchecked={}
}
function HB_MULTIFACETED_NEW.Accord.Options()
    local result,seen={},{}
    local function Add(id)
        id=tostring(id or "")
        if id=="" or seen[id] then return end
        local ok,stat=pcall(Ext.Stats.Get,id)
        local got,rank=pcall(function() return stat.Level or stat.SpellLevel end)
        rank=ok and got and tonumber(rank) or nil
        if rank~=0 then return end
        seen[id]=true
        result[#result+1]={PassiveId=id,DisplayNameFallback=id}
    end
    local got,list=pcall(Ext.StaticData.Get,HB_MULTIFACETED_NEW.Accord.List,"SpellList")
    if got and list then
        local found,available=pcall(function() return list.Spells end)
        if not found then available=nil end
        if type(available)=="string" then
            for id in available:gmatch("[^,;]+") do Add(id) end
        elseif type(available)=="table" then
            for _,id in ipairs(available) do Add(id) end
        end
    end
    if #result==0 then
        for _,id in ipairs(HB_MULTIFACETED_NEW.Accord.Catalog) do Add(id) end
    end
    return result
end
-- A naturally recorded Accord stores two independent CCLevelUp cantrip rows.
-- Combine only verified rows in the native selector, NEVER their replay keys.
function HB_MULTIFACETED_NEW.Accord.RecordedRows(choices)
    local rows,seen={},{}
    for _,row in ipairs(choices or {}) do
        if row.Kind=="Cantrip" and tostring(row.FeatOwnerId or "")
            ==HB_MULTIFACETED_NEW.Accord.Feat then
            if row.Editable~=true or tostring(row.From or "")==""
                or not row.Source or row.EntryIndex==nil or row.SlotIndex==nil
                or #(row.Options or {})==0 then return nil end
            local key=table.concat({tostring(row.Kind),tostring(row.Source),
                tostring(row.EntryIndex),tostring(row.SlotIndex)},"|")
            if seen[key] then return nil end
            seen[key]=true
            rows[#rows+1]=row
        end
    end
    if #rows~=2 or rows[1].From==rows[2].From then return nil end
    table.sort(rows,function(a,b)
        local ai,bi=tonumber(a.SlotIndex),tonumber(b.SlotIndex)
        if ai and bi and ai~=bi then return ai<bi end
        local ae,be=tonumber(a.EntryIndex),tonumber(b.EntryIndex)
        if ae and be and ae~=be then return ae<be end
        return tostring(a.From)<tostring(b.From)
    end)
    return rows
end
function HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,level)
    local visible={}
    local skipped=HB_MULTIFACETED_NEW.Accord.Unchecked[level] or {}
    local edits=previewOther[level] or {}
    for _,row in ipairs(panel.Rows or {}) do
        local key=table.concat({tostring(row.Kind),tostring(row.Source),
            tostring(row.EntryIndex),tostring(row.SlotIndex)},"|")
        if not skipped[key] then
            visible[#visible+1]=tostring(edits[key] or row.From)
        end
    end
    return visible
end
HB_MULTIFACETED_NEW.Preview={}
function HB_MULTIFACETED_NEW.Options(section)
    local options={}
    for _,id in ipairs(HB_MULTIFACETED_NEW.Catalog[section] or {}) do
        local handle=nil
        if section~="Skills" and Ext.Stats and Ext.Stats.Get then
            local ok,stat=pcall(Ext.Stats.Get,id)
            if ok and stat then
                local found,raw=pcall(function() return stat.DisplayName end)
                if found and type(raw)=="string" then handle=raw:match("^([^;]+)") end
            end
        end
        options[#options+1]={PassiveId=id,DisplayNameHandle=handle,
            DisplayNameFallback=id:gsub("_"," "):gsub("(%l)(%u)","%1 %2")}
    end
    return options
end
function HB_MULTIFACETED_NEW.Selections(level,section)
    local staged=HB_MULTIFACETED_NEW.Preview[level] or {}
    return staged[section] or {}
end

HB_GENERIC_FEATS=(function()
    local ok,value=pcall(Ext.Require,"Shared/HB_GenericFeatContracts.lua")
    if ok and type(value)=="table" then return value end
    return {PassiveSelectors=function() return nil end,
        SpellSelectors=function() return nil end,
        Definition=function() return nil end, RequiredClass=function() return nil end,
        IsKnownFixedOnly=function() return false end}
end)()
HB_GENERIC_OPTION_IDS=(function()
    local ok,value=pcall(Ext.Require,"Shared/HB_GenericPassiveOptions.lua")
    return ok and type(value)=="table" and value or {}
end)()
previewGenericChoices={}
HB_GENERIC_OPTION_CACHE={}
function HBGenericOptions(list)
    if HB_GENERIC_OPTION_CACHE[list] then return HB_GENERIC_OPTION_CACHE[list] end
    local ids=HB_GENERIC_OPTION_IDS[list]
    if not ids then return {} end
    local options={}
    for _,id in ipairs(ids) do
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            local got,name=pcall(function() return stat.DisplayName end)
            local handle=got and type(name)=="string" and name:match("^([^;]+)") or nil
            options[#options+1]={PassiveId=id,DisplayNameHandle=handle,
                DisplayNameFallback=(id:gsub("_"," "):gsub("(%l)(%u)","%1 %2"))}
        end
    end
    HB_GENERIC_OPTION_CACHE[list]=options
    return options
end
-- The same source-aware spell list reader is used by the server and client.
-- All native tab creation and confirmed historical spell paths remain unchanged.
local Log
HB_GENERIC_SPELL_OPTIONS={}
HB_GENERIC_SPELL_READER=Ext.Require("Shared/HB_GenericSpellCandidateReader.lua")
function HBGenericSpellOptions(listId,cantrip)
    local key=tostring(listId).."|"..tostring(cantrip)
    if HB_GENERIC_SPELL_OPTIONS[key] then return HB_GENERIC_SPELL_OPTIONS[key] end
    local ids,info=HB_GENERIC_SPELL_READER.Ids(listId,cantrip)
    local options={}
    for _,id in ipairs(ids) do
        options[#options+1]={PassiveId=id,DisplayNameFallback=id}
    end
    Log("NATIVE_GENERIC_SPELL_LIST list="..tostring(listId)
        .." cantrip="..tostring(cantrip)
        .." source="..tostring(info.Source)
        .." liveRaw="..tostring(info.LiveRaw)
        .." liveEligible="..tostring(info.LiveEligible)
        .." pinnedRaw="..tostring(info.PinnedRaw)
        .." pinnedEligible="..tostring(info.PinnedEligible)
        .." eligible="..#options)
    if #options>0 then HB_GENERIC_SPELL_OPTIONS[key]=options end
    return options
end
local previewPairChoices={}
local previewPairFeatIds={}
local HB_PAIR_OPTIONS_CACHE={}
local function HBPairOptions(config)
    local cached=HB_PAIR_OPTIONS_CACHE[config.List]
    if cached then return cached end
    local options={}
    for _,id in ipairs(config.Ids) do
        local handle=nil
        -- Resolve actual localized HB passive names from the installed mod.
        -- Presentation only; the server always validates IDs against the
        -- source-defined passive list and progression owner independently.
        local got,stat=pcall(Ext.Stats.Get,id)
        if got and stat then
            local read,raw=pcall(function() return stat.DisplayName end)
            if read and type(raw)=="string" then
                local candidate=raw:match("^([^;]+)")
                if candidate and candidate~="" then handle=candidate end
            end
        end
        options[#options+1]={PassiveId=id,DisplayNameHandle=handle,
            DisplayNameFallback=(id:gsub("_"," "):gsub("(%l)(%u)","%1 %2"))}
    end
    HB_PAIR_OPTIONS_CACHE[config.List]=options
    return options
end

local nativeSpellPreview=false
local nativeSpellAllowStage=false -- Explicit opt-in; never enable for inferred spellbook data.
local nativeSpellPilotClicks=0
-- A temporarily emptied historical spell slot is UI-only. The real spellbook
-- never loses its recorded choice; native Confirm refuses half-complete picks.
local nativeSpellArmed=nil
local historicalSpellType="HB_HistoricalSpellEntry_V2"
local historicalSpellRootType="HB_HistoricalSpellSelection_V2"
local historicalSpellIconType="HB_HistoricalSpellIcon_V1"
-- Local presentation state only. Each historical spell tab has independent
-- filters, reset on a NEW editor session; never change its recorded catalog.
local historicalSpellFilters={}
local HB_SPELL_SCHOOLS={"All Schools","Abjuration","Conjuration","Divination",
    "Enchantment","Evocation","Illusion","Necromancy","Transmutation"}
local HB_SPELL_DAMAGE_TYPES={"All Damage Types","Acid","Bludgeoning","Cold",
    "Fire","Force","Lightning","Necrotic","Piercing","Poison","Psychic",
    "Radiant","Slashing","Thunder"}
local historicalFeatDetailType="HB_HistoricalFeatDetail_V1"
local historicalFeatInnerType="HB_HistoricalFeatInner_V1"
local historicalFeatSkillsType="HB_HistoricalFeatSkills_V1"
local historicalTextType="HB_HistoricalFeatText_V1"
local historicalFeatType="HB_HistoricalNativeFeatOption_V2"
local historicalFeatRootType="HB_HistoricalFeatPanelVM_V1"
local nativeKnownTagsLogged = false
local featTextCache=nil
local featTitleCache=nil
local featRuleCache=nil
local LoadFeatTextCache
-- Generated from HB Localization/English/Feats Reworked.xml (localization handles, not guessed vanilla feat behavior).
-- These hints are an ADDITIONAL fail-closed guard: static Feat.Selectors/Requirements and server provenance still govern replay.
local HB_FEAT_XML_RULES = {
    ["04be25f8-996d-4928-85c1-02dfa3ff73d9"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Spores
    ["05478564-5c49-4750-b86e-46f0fcd8fd03"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of the Chain
    ["05a2aeca-12db-4811-a3d9-f308ee20c5f9"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Hematic Monarch
    ["06fa774e-2936-4727-b36f-c170d4ca897f"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Hunter
    ["09829dfe-f2df-4dec-aa42-4f5eef04a9d4"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Death Domain
    ["0bfdc937-3a62-449d-8b3f-29812adf32a1"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Arcane Trickster
    ["0df1b7d5-e045-4944-b1d7-2wse68se7ef5"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of the Primordial
    ["0df1b7d5-e045-4944-b1d7-54ab25513520"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of Penumbra
    ["0e03571b-171b-438f-8925-1865e9159fe2"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Tempered Steel
    ["17b4e26e-6836-48c3-86f6-184a2b348426"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Nostalgia
    ["1a9d3485-d1ed-4672-86e1-427bff9b0658"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Striker
    ["1aa795e0-afec-40a3-bc5c-836f1c1c68bb"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Gauntlet
    ["1b0b93e3-5a59-435e-a438-f33c487c85a8"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Swarmkeeper
    ["2a397244-bb9b-4f9d-889c-8f3e9a348229"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Shadows
    ["2c6ccaad-4531-4810-ac93-1f785aca9e6a"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Crowned Phoenix
    ["30029def-0935-44c3-8f65-75663c750a16"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Illusory Domain
    ["303a48f2-f718-4893-b1da-7ce8b7e4b5d3"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Elementalist
    ["3703a8f9-0db1-44ab-8766-4c5027e0a3ef"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Steel
    ["3ce50dbe-92b5-43e5-8d90-1102c4056cf9"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Valour
    ["3edf898e-4341-4681-8ba1-2we5fe65f545"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Elements
    ["3edf898e-4341-4681-8ba1-a29540337ebb"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Land
    ["4498ba54-55e6-452d-a2db-b3d34420699f"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Shadow Arts
    ["462a81da-b40b-47a3-88da-303b2b548119"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Life Domain
    ["46742ca9-a65f-4c00-8055-bc30221b3c6e"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Venom
    ["47526eef-46d6-4976-948e-753f4790b427"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of the Tome
    ["47709b48-6124-44dc-8792-1ba94cb81915"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Beastheart
    ["4a3405a5-4735-47b1-ba4f-4b847fe0d2f4"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Frostbreaker
    ["4a3405a5-4735-47b1-ba4f-4b847fe16f52"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Berserker
    ["502ca0fa-586c-4b22-a50e-3af8b8a24e34"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Soul of the Tundral
    ["5af5fd0f-ef26-42ce-aeed-3c1c25507529"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Open Hand
    ["5e8347bc-3658-427b-8ff4-38f44bfec08f"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Mire Mist
    ["5f53f9c9-b42a-4e56-9fba-d45cba561f06"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Captivation
    ["60a729fb-da09-413d-b69b-4cce00cf9c08"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Frontier Knight
    ["6db46327-0802-4cdd-9936-6277cba143d7"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Giant's Blood
    ["7bd6ea09-9e0b-44bc-8d11-8b5dddf94853"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Grenadier
    ["806aa51a-dff0-41f5-be15-4b5121c75ebe"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Palisade
    ["8a87461fd8dd4f5b9098ded714f6c8aa00001"]={Kind="AbilityChoices",Choices="two passively enhanced abilities (each increased by proficiency bonus)"}, -- Ability Improvement
    ["8a87461fd8dd4f5b9098ded714f6c8aa00002"]={Kind="CantripChoices",Choices="two selected cantrips"}, -- Accord of the Arcane
    ["8a87461fd8dd4f5b9098ded714f6c8aa00006"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Barbarian
    ["8a87461fd8dd4f5b9098ded714f6c8aa00007"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Bard
    ["8a87461fd8dd4f5b9098ded714f6c8aa00008"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Cleric
    ["8a87461fd8dd4f5b9098ded714f6c8aa00009"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Druid
    ["8a87461fd8dd4f5b9098ded714f6c8aa00010"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Fighter
    ["8a87461fd8dd4f5b9098ded714f6c8aa00011"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Monk
    ["8a87461fd8dd4f5b9098ded714f6c8aa00012"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Paladin
    ["8a87461fd8dd4f5b9098ded714f6c8aa00013"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Ranger
    ["8a87461fd8dd4f5b9098ded714f6c8aa00014"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Rogue
    ["8a87461fd8dd4f5b9098ded714f6c8aa00015"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Sorcerer
    ["8a87461fd8dd4f5b9098ded714f6c8aa00016"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Warlock
    ["8a87461fd8dd4f5b9098ded714f6c8aa00017"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Wizard
    ["8a87461fd8dd4f5b9098ded714f6c8aa00023"]={Kind="ElementChoices",Choices="two selected elemental damage types"}, -- Elemental Adept
    ["8a87461fd8dd4f5b9098ded714f6c8aa2d1f2"]={Kind="PassiveChoices",Choices="two class passives"}, -- Class Specialist: Zetherist
    ["8a87461fd8dd4f5b9098ded714sdf68878d07"]={Kind="MixedChoices",Choices="an archetype, a character trait, and four skill proficiencies"}, -- Multifaceted
    ["9280d9ee-964f-4d64-bed7-4f12394c4546"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Arcane
    ["94c029af-fb65-4fbe-b723-613f9b0d233e"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Moriendi
    ["97d0cd5c-578a-4801-8d05-b8abd2eb0370"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Totemic
    ["994daae4-a665-4cce-8665-82206ff8cc3c"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Rosemourn
    ["9da16729-7582-4650-8eb2-d88abf644be2"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Moon
    ["9e28af48-f32a-49f4-923e-68f95eb653cd"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Wild Magic
    ["a05f596f-a10f-4c5e-b8f6-405ad37a146c"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Mercenary
    ["a479076a-adcc-4ee3-b608-6ad09ade3061"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: War Domain
    ["a8334ef2-a1f9-48be-95aa-603dcf047827"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Drunken Fist
    ["ae030679-dbd0-414d-ab31-36c9e39ca5c7"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Evoker
    ["b39c06f9-6b73-4115-99ea-67307a8def8b"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Gloomstalker
    ["b63eed90-3cc9-4f2c-ac67-de5383244749"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Ancient Warden
    ["b6546edd-2929-405e-90c0-a1a44494080b"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of Severance
    ["b8521733-fde0-4025-bd90-2d5ef1f5e4f5"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Hidden Toxicant
    ["b8521733-fde0-4025-bd90-9d73358819f9"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Assassin
    ["b982ecd5-a889-4fe9-b81f-b8c8a3580397"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Necromancy
    ["ba6dd9aa-f5c4-4d65-ba06-b415e0f424d4"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Volcanist
    ["bdb436c7-daf0-43d9-944f-4ddbf08befe0"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Shade Walker
    ["be31014b-2a27-4970-b6d6-c95bde200001"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Arcanist
    ["be31014b-2a27-4970-b6d6-c95bde200002"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Artillerist
    ["be31014b-2a27-4970-b6d6-c95bde200003"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Battle Synthetic
    ["be31014b-2a27-4970-b6d6-c95bde200004"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Infused Arcsmith
    ["c09b13fa-d82c-4b47-ad5a-00a8d05a8fd6"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Oathbound Crusader
    ["c09b13fa-d82c-4b47-ad5a-6a5sd4fe2f41"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Oathbreaker
    ["c5e31ade-84b3-4b74-856b-af58833764fa"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Circle of the Stars
    ["ca949a0b-505e-4553-8ee3-0876f7c5c3e0"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Pact of the Blade
    ["cb163eef-6fd9-49c3-95ea-6cc3582f1423"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Tempest Domain
    ["d0c1e4ac-08cf-468b-ae1b-56e06840a278"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Forge Domain
    ["d26f0798-0c95-4208-b5b2-894kjd8943ff"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Dragoon
    ["d26f0798-0c95-4208-b5b2-ec4c595cd156"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Champion
    ["d2b32777-c2ee-46bf-8530-097243ac2ea6"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Twinfang
    ["d6521329-2633-4ef7-9198-222173557313"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Virulence
    ["dca9c5f8-868a-4cd0-bdca-fc6443a9117f"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Thief
    ["dec3cc55-896b-4bde-9f1a-7981f452ce9b"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Wild Soul
    ["e032fd36-033e-4e44-b45b-e8cd5676ab0d"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Radiant Bloom
    ["e32bb8fb-b52f-4e75-a2d5-f753713b32e6"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Arcane Warden
    ["e4c32443-a174-4fd1-93d8-9f91148ffe30"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Draconic Bloodline
    ["e63cefa5-efd4-40d4-8dad-2430d3ba04ed"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Beastmaster
    ["eb3922d2-0eec-43fb-99d5-884203c0af97"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Tyrant
    ["f022fa94-4036-4c94-ac2c-1bee32f4d1a4"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Luminal Confluence
    ["f0a857c0-fd0d-422f-b11a-9a66b897e3db"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Devout Paragon
    ["f1fb71a7-7f9a-4afd-8fcc-71dda4bd71d1"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Arcane Archer
    ["f313b0ab-01ec-40a2-93ec-e053f9a23652"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Arcblade
    ["f64893a4-9722-48d5-aa76-90bd1c2ad3ab"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Eldritch Knight
    ["fb171ab4-8b71-4736-ac30-0214883122a5"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: Way of the Gentle Fist
    ["fde3ac3a-eedd-4b43-8f27-e60d0860e923"]={Kind="SubclassGrant",Choices="a chosen subclass feature package and a base-class prerequisite"}, -- Yokebreaker: College of Lore
}

local NativePilotStop, NativePilotStart, NativeHistoricalStart
local ApplyHistoricalSliderFromModel
local SyncHistoricalConfirmEnabled, ResetDetachedHistoricalView

local function FlushLog()
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, FILE, table.concat(notes, "\n") .. "\n")
    end
end
Log = function(message)
    notes[#notes + 1] = tostring(message)
    if #notes > 360 then table.remove(notes, 2) end
    if not batchLogs then FlushLog() end
end
local function Read(obj, name)
    if not obj then return nil end
    local ok, value = pcall(function() return obj[name] end)
    return ok and value or nil
end
local function UIWidget()
    if not Ext.UI or not Ext.UI.GetRoot then return nil end
    local ok, root = pcall(Ext.UI.GetRoot)
    if not ok or not root then return nil end
    local container = Read(root, "ContentRoot")
    if not container then
        local worked, result = pcall(function() return root:Find("ContentRoot") end)
        if worked then container = result end
    end
    if not container then return nil end
    local nodes = {container}
    local cursor = 1
    while cursor <= #nodes and cursor < 1500 do
        local node = nodes[cursor]
        cursor = cursor + 1
        if Read(node, "Name") == WIDGET then return node end
        local count = tonumber(Read(node, "VisualChildrenCount")) or 0
        for i = 1, math.min(count, 120) do
            local worked, child = pcall(function() return node:VisualChild(i) end)
            if worked and child then nodes[#nodes+1] = child end
        end
    end
    return nil
end
local function CurrentVM()
    local node = UIWidget()
    return node and Read(node, "DataContext") or nil
end
local function Label(entry)
    if type(entry) == "string" then return entry end
    if type(entry) ~= "table" then return tostring(entry or "?") end
    if entry.DisplayNameHandle and Ext.Loca then
        local worked, localized = pcall(Ext.Loca.GetTranslatedString, entry.DisplayNameHandle)
        if worked and localized and localized ~= "" and localized ~= entry.DisplayNameHandle then return localized end
    end
    return entry.DisplayNameFallback or entry.Name or entry.PassiveId or entry.Id or "?"
end
local function DescribeLevel(level)
    local row = snapshot[level] or {}
    local choice = row.LevelChoices or {}
    local lines = {}
    if choice.Class then lines[#lines+1] = "Class: " .. Label(choice.Class) end
    if choice.SubClass then lines[#lines+1] = "Subclass: " .. Label(choice.SubClass) end
    if choice.Feat then lines[#lines+1] = "Feat: " .. Label(choice.Feat) end
    local passiveNames = {}
    for _, item in ipairs(choice.ClassPassives or {}) do passiveNames[#passiveNames+1] = Label(item) end
    if #passiveNames > 0 then lines[#lines+1] = "Class choices: " .. table.concat(passiveNames, ", ") end
    local extra = {ExtraActions_Action="Action", ExtraActions_BonusAction="Bonus Action", ExtraActions_Reaction="Reaction"}
    for _, id in ipairs(choice.ExtraResources or {}) do
        lines[#lines+1] = "Extra Resource: " .. (extra[tostring(id)] or tostring(id))
    end
    local kinds = {}
    for _, item in ipairs(choice.OtherChoices or {}) do
        local kind = tostring(item.Kind or "Choice")
        kinds[#kinds+1] = kind .. ": " .. Label(item.From)
        if #kinds >= 6 then break end
    end
    for _, text in ipairs(kinds) do lines[#lines+1] = text end
    if choice.HistoryAvailable==false then
        lines[#lines+1]="Original player-choice history unavailable at this level."
        local current={}
        for _,entry in ipairs(choice.CurrentClasses or {}) do
            current[#current+1]=Label(entry.Name).." "..tostring(entry.Level or "?")
        end
        if #current>0 then
            lines[#lines+1]="Present-day classes (not level history): "..table.concat(current,", ")
        end
    end
    local observations=choice.ObservedSpells or {}
    if #observations>0 then
        lines[#lines+1]=("Observed progression spells: %d (view only; may be automatic grants)."):format(#observations)
    end
    local currentSpellbook=choice.CurrentSpellbook or {}
    if #currentSpellbook>0 then
        lines[#lines+1]=("Current spellbook: %d spells (level of acquisition unknown; view only)."):format(#currentSpellbook)
    end
    if #lines == 0 then lines[#lines+1] = "No recorded selectable choices at this level." end
    return table.concat(lines, "\n")
end
local RESOURCE_OPTIONS = {
    {PassiveId="ExtraActions_Action", DisplayNameFallback="Extra Action"},
    {PassiveId="ExtraActions_BonusAction", DisplayNameFallback="Extra Bonus Action"},
    {PassiveId="ExtraActions_Reaction", DisplayNameFallback="Extra Reaction"}
}
local function Pretty(text)
    text=tostring(text or "")
    text=text:gsub("_"," "):gsub("(%l)(%u)","%1 %2")
    return text
end
local function ChoiceKey(row)
    return table.concat({tostring(row.Kind),tostring(row.Source),tostring(row.EntryIndex),tostring(row.SlotIndex)},"|")
end
-- One native four-choice sidebar group for a naturally recorded
-- Multifaceted skill selector. All four original CCLevelUp slot identities
-- remain intact for the existing strict historical replay RPC.
local function AllPanels()
    local HB_MULTIFACETED_SKILL_OWNER="be0889d2-f9aa-472d-b942-592bff0f1ef3"
    local function RecordedMultifacetedSkillRows(choices)
        local rows={}
        local baseList,baseSource,baseEntry=nil,nil,nil
        local total=0
        for _,row in ipairs(choices or {}) do
            if row.Kind=="Skill" and tostring(row.FeatOwnerId or "")==HB_MULTIFACETED_SKILL_OWNER then
                total=total+1
                local slot=tonumber(row.SlotIndex)
                if row.Editable~=true or row.Source~="Skills" or not slot
                    or slot~=math.floor(slot) or slot<1 or slot>4
                    or rows[slot] or tostring(row.From or "")=="" then return nil end
                if baseList~=nil and (baseList~=tostring(row.List or "")
                    or baseSource~=tostring(row.Source or "")
                    or baseEntry~=tonumber(row.EntryIndex)) then return nil end
                baseList=tostring(row.List or "")
                baseSource=tostring(row.Source or "")
                baseEntry=tonumber(row.EntryIndex)
                if not baseEntry then return nil end
                rows[slot]=row
            end
        end
        if total~=4 then return nil end
        local known={}
        for i=1,4 do
            local row=rows[i]
            if not row or known[tostring(row.From)] then return nil end
            known[tostring(row.From)]=true
        end
        return rows
    end
    local choice=(snapshot[currentLevel] or {}).LevelChoices or {}
    local panels={}
    -- Level one exposes only verified selectable choices; starting class,
    -- subclass, identity, ability scores and observational widgets never
    -- become sidebar entries. Uneditable levels get the existing N/A tab.
    -- Determine the effective feat after staging, never the original alone.
    -- Otherwise a feat-owned tab from the original CCLevelUp remains visible
    -- after the player switches that feat to Alert or a different complex feat.
    local recordedFeatId=nil
    local effectiveFeatId=nil
    local featCount=0
    for _,choiceRow in ipairs(choice.OtherChoices or {}) do
        if choiceRow.Kind=="Feat" then
            featCount=featCount+1
            recordedFeatId=tostring(choiceRow.From or "")
            effectiveFeatId=tostring((previewOther[currentLevel] or {})[ChoiceKey(choiceRow)]
                or choiceRow.From or "")
        end
    end
    if featCount~=1 then
        recordedFeatId=nil
        effectiveFeatId=nil
    end
    for _,group in ipairs(choice.EditablePassiveGroups or {}) do
        if currentLevel~=1 or group.LevelOneVerified==true then
        local owner=tostring(group.FeatOwnerId or "")
        local belongsToReplacedFeat=(group.FeatOwnerVerified or group.FeatChoiceProtected)
            and recordedFeatId~=nil
            and (owner=="" or owner==recordedFeatId)
            and effectiveFeatId~=recordedFeatId
        if not belongsToReplacedFeat then
        -- Proven feat-owned secondary choices use the normal BG3 passive
        -- selector subtab. This keeps native click/checkmark behavior and the
        -- already-tested replay path; no secondary choices are invented.
        local featName=tostring(group.FeatOwnerName or "Feat")
        local pair=HB_PASSIVE_PAIR_FEATS[tostring(group.FeatOwnerId or "")]
        if pair then
            if pair.Name=="AbilityImprovement" then
                featName="Ability Improvement"
            else
                local class=pair.Name:match("^ClassDivergence_(.+)$")
                if class then featName="Class Specialist: "..class end
            end
        end
        -- A saved Class Specialist group may have SelectorId="". In Lua an
        -- empty string is truthy, so the previous `SelectorId or featName`
        -- yielded a blank left-sidebar title despite a fully recorded pair.
        -- Preserve exact verified ownership; this changes display text only.
        local selectorId=tostring(group.SelectorId or "")
        local label=selectorId~="" and Pretty(selectorId) or ""
        if pair and pair.Name:match("^ClassDivergence_") then
            label="Class Passives"
        elseif label=="" then
            local sourceTitle=tostring(group.Title or group.FeatOwnerName or "")
            label=sourceTitle~="" and Pretty(sourceTitle) or "Passive Choices"
        end
        -- Display native-facing names, not internal SelectPassives selector tokens.
        if selectorId=="FeatASI" then
            label="Ability Improvement"
        elseif label=="Learned Spell" then
            label="Spells"
        end
        panels[#panels+1]={Kind="Passive",Group=group,
            Title=label,DescriptionText=group.DescriptionText or group.Description,
            Options=group.Options or {},
            CurrentIds=group.Picked or {},Editable=(group.Editable~=false
                and (currentLevel>1 or ((snapshot[1] or {}).LevelChoices or {}).HistoryAvailable==true)
                and (currentLevel>1 or not group.FeatOwnerVerified))}
        end
        end -- verified level-one passive group
    end
    local extra=currentLevel>1 and (choice.ExtraResources or {}) or {}
    if #extra==1 then
        panels[#panels+1]={Kind="Resource",Title="Extra Resource",Options=RESOURCE_OPTIONS,
            CurrentIds={tostring(extra[1])},Editable=currentLevel>1}
    elseif #extra>1 then
        -- The existing server replay callback is keyed by character level,
        -- not by resource slot. Expose each historical choice read-only rather
        -- than silently hiding it or staging an ambiguous replacement.
        for index,id in ipairs(extra) do
            panels[#panels+1]={Kind="Resource",Title="Extra Resource "..index,
                Options=RESOURCE_OPTIONS,CurrentIds={tostring(id)},Editable=false}
        end
    end
    local multifacetedRows=recordedFeatId==effectiveFeatId
        and RecordedMultifacetedSkillRows(choice.OtherChoices) or nil
    local accordRows=recordedFeatId==effectiveFeatId
        and recordedFeatId==HB_MULTIFACETED_NEW.Accord.Feat
        and HB_MULTIFACETED_NEW.Accord.RecordedRows(choice.OtherChoices) or nil
    -- Group recorded feat-owned spells by their original SelectSpells
    -- definitions. Previously BG3's saved 2+2+1 spell IDs were displayed as
    -- five unrelated read-only 1/1 tabs. Only recognize a complete exact
    -- source-owned package: never combine class/subclass spell selections.
    -- Reconstruct recorded multi-spell Class/SubClass selectors by original
    -- CC row identity, never by title or level alone. Multiple 1/1 historical
    -- rows belonging to the SAME original SelectSpells row become one n/n tab.
    local classSpellGroups,classSpellRecognized={},{}
    if currentLevel>1 then
        local candidates={}
        for _,record in ipairs(choice.OtherChoices or {}) do
            if (record.Kind=="Spell" or record.Kind=="Cantrip")
                and tostring(record.Source or "")=="Upgrades.Spells"
                and tostring(record.FeatOwnerId or "")==""
                and tonumber(record.EntryIndex)~=nil then
                local key=table.concat({tostring(record.EntryIndex),
                    tostring(record.DefinitionIndex),tostring(record.SelectorId),
                    tostring(record.List),tostring(record.Kind)},"|")
                candidates[key]=candidates[key] or {}
                candidates[key][#candidates[key]+1]=record
            end
        end
        for _,records in pairs(candidates) do
            if #records>1 then
                local valid=true
                local slots={}
                for _,record in ipairs(records) do
                    local slot=tonumber(record.SlotIndex)
                    if not slot or slot<1 or slot>#records or slots[slot]
                        or record.Editable~=true then valid=false;break end
                    slots[slot]=record
                end
                if valid then
                    local rows,options,allowed={}, {}, {}
                    for i=1,#records do
                        if not slots[i] then valid=false;break end
                        rows[i]=slots[i]
                        for _,option in ipairs(slots[i].Options or {}) do
                            local id=tostring(option.Id or "")
                            if id~="" and not allowed[id] then
                                allowed[id]=true
                                options[#options+1]={PassiveId=id,
                                    DisplayNameHandle=option.DisplayNameHandle,
                                    DisplayNameFallback=option.Name or id}
                            end
                        end
                    end
                    if valid then
                        local ids={}
                        for i,row in ipairs(rows) do ids[i]=tostring(row.From) end
                        local group={Kind="ClassSpellGroup",
                            Title=rows[1].Kind=="Cantrip" and "Cantrips" or "Spells",
                            GroupSpellCantrip=rows[1].Kind=="Cantrip",
                            Rows=rows,Options=options,CurrentIds=ids,
                            Editable=true,MaxChoices=#rows}
                        classSpellGroups[rows[1]]=group
                        for _,row in ipairs(rows) do classSpellRecognized[row]=true end
                        Log("NATIVE_CLASS_SPELL_GROUP level="..currentLevel
                            .." slots="..#rows.." source="..tostring(rows[1].Source)
                            .." selector="..tostring(rows[1].SelectorId))
                    end
                end
            end
        end
    end
    local recordedGenericSpellRows={}
    local recognizedGenericSpellRows={}
    if recordedFeatId and effectiveFeatId==recordedFeatId then
        local definitions=HB_GENERIC_FEATS.SpellSelectors(recordedFeatId)
        if definitions then
            local matched,used,ownerCount={}, {},0
            local valid=true
            for index,g in ipairs(definitions) do matched[index]={} end
            for _,spellRow in ipairs(choice.OtherChoices or {}) do
                if (spellRow.Kind=="Spell" or spellRow.Kind=="Cantrip")
                    and tostring(spellRow.FeatOwnerId or "")==recordedFeatId then
                    ownerCount=ownerCount+1
                    local found=nil
                    for index,g in ipairs(definitions) do
                        if tostring(spellRow.List or "")==g.List
                            and tostring(spellRow.SelectorId or "")==g.Selector
                            and tonumber(spellRow.DefinitionIndex)==g.Index-1
                            and ((spellRow.Kind=="Cantrip")==g.Cantrip)
                            and tostring(spellRow.Source or "")=="Upgrades.Spells" then
                            if found then valid=false end
                            found=index
                        end
                    end
                    if not found or used[spellRow] then valid=false
                    else
                        used[spellRow]=true
                        matched[found][#matched[found]+1]=spellRow
                    end
                end
            end
            local count=0
            for index,g in ipairs(definitions) do
                local rows=matched[index]
                count=count+#rows
                if #rows~=g.Count then valid=false end
                local seen,slots={},{}
                for _,spellRow in ipairs(rows) do
                    local id=tostring(spellRow.From or "")
                    if id=="" or seen[id] then valid=false end
                    seen[id]=true
                    local slot=tonumber(spellRow.SlotIndex)
                    if not slot or slot<1 or slot>g.Count or slots[slot] then valid=false end
                    slots[slot]=spellRow
                end
                table.sort(rows,function(a,b)
                    if a.EntryIndex~=b.EntryIndex then return a.EntryIndex<b.EntryIndex end
                    return a.SlotIndex<b.SlotIndex
                end)
            end
            if not valid or count~=ownerCount or ownerCount==0 then matched={} end
            if #matched==#definitions then
                for index,g in ipairs(definitions) do
                    local rows=matched[index]
                    local ids={}
                    local available=HBGenericSpellOptions(g.List,g.Cantrip)
                    local catalog={}
                    for _,option in ipairs(available) do catalog[tostring(option.PassiveId)]=true end
                    local writable=currentLevel>1 and #available>0
                    for _,spellRow in ipairs(rows) do
                        ids[#ids+1]=tostring(spellRow.From)
                        if not catalog[tostring(spellRow.From)] then writable=false end
                        recognizedGenericSpellRows[spellRow]=true
                    end
                    recordedGenericSpellRows[#recordedGenericSpellRows+1]={
                        Kind="GenericSpellRecorded",Title=(g.Cantrip and "Cantrips" or "Spells"),
                        Rows=rows,Options=available,CurrentIds=ids,Editable=writable,
                        MaxChoices=g.Count,FeatId=recordedFeatId,SelectorIndex=index,
                        List=g.List,SpellCantrip=g.Cantrip}
                end
            end
        end
    end
    local addedAccord=false
    local addedMultifaceted=false
    local insertedRecordedSpellGroups=false
    local levelOneGroups={}
    if currentLevel==1 then
        for _,row in ipairs(choice.OtherChoices or {}) do
            if row.LevelOneVerified==true and row.Editable==true
                and ({Skill=true,Expertise=true,Spell=true,Cantrip=true})[row.Kind] then
                local key=table.concat({tostring(row.Kind),tostring(row.Source),
                    tostring(row.EntryIndex),tostring(row.List)},"|")
                local group=levelOneGroups[key]
                if not group then
                    local title=({Skill="Skill Proficiencies",Expertise="Expertise",
                        Spell="Spells",Cantrip="Cantrips"})[row.Kind]
                    group={Kind=(row.Kind=="Skill" or row.Kind=="Expertise")
                        and "MultifacetedSkills" or "AccordRecorded",
                        GroupedLevelOne=true,GroupKind=row.Kind,
                        GroupSpellCantrip=(row.Kind=="Cantrip"),
                        Title=title,Rows={},Options={},CurrentIds={},
                        Editable=true,MaxChoices=0,GroupKey=key}
                    levelOneGroups[key]=group
                end
                group.Rows[#group.Rows+1]=row
                group.CurrentIds[#group.CurrentIds+1]=tostring(row.From)
                group.MaxChoices=group.MaxChoices+1
                local seen={}
                for _,option in ipairs(group.Options) do
                    seen[tostring(option.PassiveId)]=true
                end
                for _,option in ipairs(row.Options or {}) do
                    local id=tostring(option.Id or "")
                    if id~="" and not seen[id] then
                        group.Options[#group.Options+1]={PassiveId=id,
                            DisplayNameHandle=option.DisplayNameHandle,
                            DisplayNameFallback=option.Name or id}
                        seen[id]=true
                    end
                end
            end
        end
    end
    if currentLevel==1 then
        local skillsByList={}
        local ambiguous={}
        for _,group in pairs(levelOneGroups) do
            if group.GroupKind=="Skill" then
                local id=tostring((group.Rows[1] or {}).List or "")
                if skillsByList[id] then ambiguous[id]=true end
                skillsByList[id]=group
            end
            if group.GroupKind=="Skill" or group.GroupKind=="Expertise" then
                table.sort(group.Options,function(a,b)
                    local left=tostring(a.PassiveId or "")
                    local right=tostring(b.PassiveId or "")
                    local li=HB_MULTIFACETED_UI.SkillOrder[left] or 1000
                    local ri=HB_MULTIFACETED_UI.SkillOrder[right] or 1000
                    if li~=ri then return li<ri end
                    return left<right
                end)
            end
        end
        for _,group in pairs(levelOneGroups) do
            if group.GroupKind=="Expertise" then
                local list=tostring((group.Rows[1] or {}).List or "")
                if not ambiguous[list] then group.ProficiencyGroup=skillsByList[list] end
                -- If a matching recorded proficiency selector is absent, do
                -- not invent eligible expertise: the server will fail closed.
                if not group.ProficiencyGroup then group.Editable=false end
            end
        end
    end
    local levelOneAdded={}
    for _,row in ipairs(choice.OtherChoices or {}) do
        if not insertedRecordedSpellGroups and row.Kind=="Feat" and #recordedGenericSpellRows>0 then
            insertedRecordedSpellGroups=true
            -- The feat selector itself remains in its normal native position.
        end
        if classSpellRecognized[row] then
            if classSpellGroups[row] then panels[#panels+1]=classSpellGroups[row] end
        elseif recognizedGenericSpellRows[row] then
            -- Its grouped native spell selector is added after the original
            -- feat row rather than five individual historical spell rows.
        elseif recordedFeatId==HB_MULTIFACETED_NEW.Accord.Feat
            and effectiveFeatId~=recordedFeatId and row.Kind=="Cantrip"
            and tostring(row.FeatOwnerId or "")==recordedFeatId then
            -- Swapping Accord away removes its two feat-owned cantrip rows.
            -- Do not show orphaned original cantrip selectors.
        elseif accordRows and row.Kind=="Cantrip"
            and tostring(row.FeatOwnerId or "")==HB_MULTIFACETED_NEW.Accord.Feat then
            if not addedAccord then
                addedAccord=true
                -- A single native 2/2 cantrip selector with distinct original
                -- slot IDs behind it. A candidate must belong to BOTH exact
                -- original catalogs to be safely assigned to either slot.
                local options,common={},{}
                for _,candidate in ipairs(accordRows[1].Options or {}) do
                    local id=tostring(candidate.Id or "")
                    if id~="" then common[id]=candidate end
                end
                local included={}
                for _,candidate in ipairs(accordRows[2].Options or {}) do
                    local id=tostring(candidate.Id or "")
                    if common[id] and not included[id] then
                        included[id]=true
                        local source=common[id]
                        options[#options+1]={PassiveId=id,
                            DisplayNameHandle=source.DisplayNameHandle,
                            DisplayNameFallback=source.Name or id}
                    end
                end
                -- Original choices must also be renderable as Selected; an
                -- unverified original never silently widens the writable list.
                for _,source in ipairs(accordRows) do
                    local id=tostring(source.From or "")
                    if not included[id] then
                        included[id]=true
                        options[#options+1]={PassiveId=id,DisplayNameFallback=id,
                            HB_OriginalOnly=true}
                    end
                end
                panels[#panels+1]={Kind="AccordRecorded",
                    Title="Cantrips",
                    Rows=accordRows, Options=options,
                    CurrentIds={tostring(accordRows[1].From),tostring(accordRows[2].From)},
                    Editable=currentLevel>1,MaxChoices=2}
            end
        elseif recordedFeatId==HB_MULTIFACETED_SKILL_OWNER
            and effectiveFeatId~=recordedFeatId and row.Kind=="Skill"
            and tostring(row.FeatOwnerId or "")==HB_MULTIFACETED_SKILL_OWNER then
            -- An entirely removed feat has no historical skill tabs.
        elseif multifacetedRows and row.Kind=="Skill"
            and tostring(row.FeatOwnerId or "")==HB_MULTIFACETED_SKILL_OWNER then
            if not addedMultifaceted then
                addedMultifaceted=true
                local options,current={},{}
                local seen={}
                for _,skillRow in ipairs(multifacetedRows) do
                    current[#current+1]=tostring(skillRow.From)
                    for _,option in ipairs(skillRow.Options or {}) do
                        local id=tostring(option.Id or "")
                        if id~="" and not seen[id] then
                            seen[id]=true
                            options[#options+1]={PassiveId=id,
                                DisplayNameHandle=option.DisplayNameHandle,
                                DisplayNameFallback=option.Name or id}
                        end
                    end
                end
                table.sort(options,function(a,b)
                    local left=tostring(a.PassiveId or "")
                    local right=tostring(b.PassiveId or "")
                    local li=HB_MULTIFACETED_UI.SkillOrder[left] or 1000
                    local ri=HB_MULTIFACETED_UI.SkillOrder[right] or 1000
                    if li~=ri then return li<ri end
                    return left<right
                end)
                panels[#panels+1]={Kind="MultifacetedSkills",
                    Title="Feat Skills: Multifaceted",Rows=multifacetedRows,
                    Options=options,CurrentIds=current,Editable=(currentLevel>1),
                    MaxChoices=4}
            end
        elseif currentLevel==1 and not (row.LevelOneVerified==true and row.Editable==true) then
            -- Level-one sidebar intentionally omits everything uneditable.
        elseif currentLevel==1 and ({Skill=true,Expertise=true,Spell=true,Cantrip=true})[row.Kind] then
            local key=table.concat({tostring(row.Kind),tostring(row.Source),
                tostring(row.EntryIndex),tostring(row.List)},"|")
            if not levelOneAdded[key] and levelOneGroups[key] then
                levelOneAdded[key]=true
                panels[#panels+1]=levelOneGroups[key]
            end
        else
        local options={}
        for _,option in ipairs(row.Options or {}) do
            options[#options+1]={PassiveId=option.Id,
                DisplayNameHandle=option.DisplayNameHandle,
                DisplayNameFallback=option.Name or option.Id}
        end
        local title=({Feat="Feat",Ability="Ability Choice",Spell="Spells",
            Cantrip="Cantrips",Skill="Skill Proficiency",Expertise="Skill Expertise"})[row.Kind]
            or Pretty(row.Kind)
        -- The recorded secondary feat owner, when present, is carried by
        -- the server's exact CCLevelUp row rather than inferred from the
        -- character level. Unverified historical rows retain independent tabs.
        local owner=tostring(row.FeatOwnerId or "")
        if owner=="cdcbc538-883b-401c-a8ed-1373fb6d1720" and row.Kind=="Cantrip" then
            title="Cantrips"
        elseif owner=="be0889d2-f9aa-472d-b942-592bff0f1ef3" and row.Kind=="Skill" then
            title="Feat Skill: Multifaceted "..tostring(row.SlotIndex or "")
        end
        panels[#panels+1]={Kind="Other",Other=row,Title=title,Options=options,
            CurrentIds={tostring(row.From)},Editable=(row.Editable==true and (currentLevel>1 or row.LevelOneVerified==true))}
        end
    end
    for _,groupPanel in ipairs(recordedGenericSpellRows) do
        panels[#panels+1]=groupPanel
    end
    -- A recorded simple feat staged to become Elemental Adept gains the
    -- same genuine BG3 passive-selector sidebar treatment as other choices.
    -- Never pretend the source Alert already had two elemental slots.
    for _,row in ipairs(choice.OtherChoices or {}) do
        if row.Kind=="Feat" and tostring(row.From or "")~=HB_ELEMENTAL_ADEPT_FEAT
            and tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
                ==HB_ELEMENTAL_ADEPT_FEAT then
            panels[#panels+1]={Kind="ElementAdd",Title="Elements",
                Options=HB_ELEMENTAL_OPTIONS,
                CurrentIds=previewNewElements[currentLevel] or {},
                Editable=currentLevel>1,MaxChoices=2}
            break
        end
    end
    for _,row in ipairs(choice.OtherChoices or {}) do
        local target=tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
        local config=HB_PASSIVE_PAIR_FEATS[target]
        if row.Kind=="Feat" and config and tostring(row.From or "")~=target then
            panels[#panels+1]={Kind="PassivePairAdd",Title=(config.Name=="AbilityImprovement"
                    and "Ability Scores" or "Class Passives"),
                Options=HBPairOptions(config),
                CurrentIds=(previewPairFeatIds[currentLevel]==target
                    and previewPairChoices[currentLevel] or {}),
                Editable=currentLevel>1,MaxChoices=2,FeatId=target}
            break
        end
    end
    for _,row in ipairs(choice.OtherChoices or {}) do
        if row.Kind=="Feat" then
            local target=tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
            if target~="" and target~=tostring(row.From or "") then
                local groups=HB_GENERIC_FEATS.PassiveSelectors(target)
                if groups and not HB_PASSIVE_PAIR_FEATS[target]
                    and target~=HB_ELEMENTAL_ADEPT_FEAT and target~=HB_MULTIFACETED_NEW.Feat then
                    for index,group in ipairs(groups) do
                        panels[#panels+1]={Kind="GenericPassiveAdd",Title=Pretty(
                            group.Selector~="" and group.Selector
                                or ("Passive Choices"..(#groups>1 and (" "..index) or ""))),
                            Options=HBGenericOptions(group.List),
                            CurrentIds=((previewGenericChoices[currentLevel] or {})[index] or {}),
                            Editable=currentLevel>1,MaxChoices=group.Count,
                            FeatId=target,SelectorIndex=index,List=group.List}
                    end
                end
            end
        end
    end
    for _,row in ipairs(choice.OtherChoices or {}) do
        if row.Kind=="Feat" then
            local target=tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
            if target~="" and target~=tostring(row.From or "")
                and target~=HB_MULTIFACETED_NEW.Accord.Feat then
                local groups=HB_GENERIC_FEATS.SpellSelectors(target)
                if groups then
                    for index,group in ipairs(groups) do
                        local options=HBGenericSpellOptions(group.List,group.Cantrip)
                        if #options<group.Count then
                            Log("NATIVE_GENERIC_FEAT_SPELL_LIST_UNAVAILABLE feat="..target
                                .." list="..tostring(group.List)
                                .." selector="..tostring(group.Selector)
                                .." cantrip="..tostring(group.Cantrip)
                                .." required="..tostring(group.Count)
                                .." eligible="..tostring(#options))
                        end
                        panels[#panels+1]={Kind="GenericSpellAdd",
                            Title=(group.Cantrip and "Cantrips" or "Spells"),
                            Options=options,
                            CurrentIds=((previewGenericChoices[currentLevel] or {})[index] or {}),
                            Editable=currentLevel>1,MaxChoices=group.Count,
                            FeatId=target,SelectorIndex=index,List=group.List,
                            SpellCantrip=group.Cantrip}
                    end
                end
            end
        end
    end
    for _,row in ipairs(choice.OtherChoices or {}) do
        if row.Kind=="Feat" and tostring(row.From or "")~=HB_MULTIFACETED_NEW.Feat
            and tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
                ==HB_MULTIFACETED_NEW.Feat then
            for _,section in ipairs({"Archetype","Trait","Skills"}) do
                local n=section=="Skills" and 4 or 1
                panels[#panels+1]={Kind="MultifacetedAdd",Section=section,
                    Title=section=="Skills" and "Skills" or Pretty(section),
                    Options=HB_MULTIFACETED_NEW.Options(section),
                    CurrentIds=HB_MULTIFACETED_NEW.Selections(currentLevel,section),
                    Editable=currentLevel>1,MaxChoices=n}
            end
            break
        end
    end
    for _,row in ipairs(choice.OtherChoices or {}) do
        if row.Kind=="Feat" and tostring(row.From or "")~=HB_MULTIFACETED_NEW.Accord.Feat
            and tostring((previewOther[currentLevel] or {})[ChoiceKey(row)] or "")
                ==HB_MULTIFACETED_NEW.Accord.Feat then
            panels[#panels+1]={Kind="AccordAdd",Title="Cantrips",
                Options=HB_MULTIFACETED_NEW.Accord.Options(),
                CurrentIds=HB_MULTIFACETED_NEW.Accord.Preview[currentLevel] or {},
                Editable=currentLevel>1,MaxChoices=2}
            break
        end
    end
    local observed=choice.ObservedSpells or {}
    if currentLevel>1 and #observed>0 then
        local options,ids={},{}
        local historical={}
        for _,row in ipairs(choice.OtherChoices or {}) do
            if row.Kind=="Spell" or row.Kind=="Cantrip" then
                historical[tostring(row.From)]=true
            end
        end
        for _,row in ipairs(observed) do
            local id=tostring(row.Id or "")
            if id~="" and not historical[id] then
                options[#options+1]={PassiveId=id,DisplayNameFallback=row.Name or id}
                ids[#ids+1]=id
            end
        end
        if #options>0 then
            panels[#panels+1]={Kind="ObservedSpell",
                Title="Progression Spells (Read Only)",Options=options,
                CurrentIds=ids,Editable=false}
        end
    end
    local book=choice.CurrentSpellbook or {}
    if currentLevel>1 and #book>0 then
        local opts,ids={},{}
        for _,row in ipairs(book) do
            local id=tostring(row.Id or "")
            if id~="" then
                opts[#opts+1]={PassiveId=id,DisplayNameFallback=row.Name or id}
                ids[#ids+1]=id
            end
        end
        if #opts>0 then
            panels[#panels+1]={Kind="ObservedSpell",
                Title="Current Spellbook (Level Unknown)",
                Options=opts,CurrentIds=ids,Editable=false}
        end
    end
    -- A genuine native subtab is needed even for a level without choices.
    -- BG3 otherwise keeps the previous level's selected passive presenter:
    -- assigning an orphan content DataContext cannot clear the live tab.
    if #panels==0 then
        panels[1]={Kind="Empty",Title=choice.HistoryAvailable==false
            and "History unavailable" or "N/A", Options={},CurrentIds={},Editable=false}
    end
    return panels
end
-- Build a navigation index without interpreting observed spells as editable
-- player choices. A Wizard with missing CCLevelUp can still browse any exact
-- spell IDs that were recovered, but this NEVER enables replay/staging.
local function LevelDataKinds(level)
    local choices=(snapshot[level] or {}).LevelChoices or {}
    local recorded=false
    for _,group in ipairs(choices.EditablePassiveGroups or {}) do
        if #(group.Options or {})>0 then recorded=true;break end
    end
    if #(choices.ExtraResources or {})>0 or #(choices.OtherChoices or {})>0 then
        recorded=true
    end
    local observed=(#(choices.ObservedSpells or {})>0 or
        #(choices.CurrentSpellbook or {})>0)
    return recorded,observed
end

local function ChoiceLevels()
    local recorded,observed,available={},{},{}
    for level=1,maximum do
        local hasRecorded,hasObserved=LevelDataKinds(level)
        if hasRecorded then recorded[#recorded+1]=level end
        if hasObserved then observed[#observed+1]=level end
        if hasRecorded or hasObserved then available[#available+1]=level end
    end
    return available,recorded,observed
end

local function NearestChoiceLevel(direction)
    for level=currentLevel+direction,(direction>0 and maximum or 1),direction do
        local recorded,observed=LevelDataKinds(level)
        if recorded or observed then return level end
    end
    return nil
end

local function FormatLevelRanges(levels)
    if #levels==0 then return "none" end
    local result={}
    local first,last=levels[1],levels[1]
    for i=2,#levels+1 do
        local level=levels[i]
        if level and level==last+1 then
            last=level
        else
            result[#result+1]=(first==last) and tostring(first) or (tostring(first).."-"..tostring(last))
            first,last=level,level
        end
    end
    return table.concat(result,", ")
end

local function EditedHistoricalLevels()
    local found={}
    for level,row in pairs(snapshot) do
        if type(level)=="number" and type(row)=="table" then
            for _,replacement in pairs(row._HB_PreviewStaged or {}) do
                if replacement then found[level]=true; break end
            end
        end
    end
    for level,value in pairs(previewResources) do
        if value and type(level)=="number" then found[level]=true end
    end
    for level,rows in pairs(previewOther) do
        if type(level)=="number" and type(rows)=="table" then
            for _,replacement in pairs(rows) do
                if replacement then found[level]=true; break end
            end
        end
    end
    local result={}
    for level in pairs(found) do result[#result+1]=level end
    table.sort(result)
    return result
end

local function ChoiceLevelMap()
    local available,recorded,observed=ChoiceLevels()
    local edited=EditedHistoricalLevels()
    if #available==0 then
        return "No historical choice data was recovered. See caster history diagnostics."
    end
    local result="Levels with choices: "..FormatLevelRanges(recorded)
    if #observed>0 then
        result=result.." | Spell observations (view only): "..FormatLevelRanges(observed)
    end
    if #edited>0 then
        result=result.." | Edited: "..FormatLevelRanges(edited)
    end
    return result
end

local function ActivePanel()
    local panels=AllPanels()
    if #panels==0 then return nil,panels end
    passiveGroupIndex=math.max(1,math.min(passiveGroupIndex,#panels))
    return panels[passiveGroupIndex],panels
end
local function IsRecordedFeatPanel(panel)
    return panel and panel.Kind=="Other" and panel.Other and panel.Other.Kind=="Feat"
end
local function IsNativeFeatPreview(panel)
    return nativeFeatPreview and IsRecordedFeatPanel(panel)
end
local function IsRecordedSpellPanel(panel)
    return panel and ((panel.Kind=="Other" and panel.Other
        and (panel.Other.Kind=="Spell" or panel.Other.Kind=="Cantrip"))
        or panel.Kind=="ObservedSpell" or panel.Kind=="AccordAdd"
        or panel.Kind=="AccordRecorded" or panel.Kind=="GenericSpellAdd"
        or panel.Kind=="GenericSpellRecorded" or panel.Kind=="ClassSpellGroup")
end
local function IsNativeSpellPreview(panel)
    -- Historical spell tabs already use the native FeatSpellSelector template.
    -- The preview flag is diagnostic only; observations are never selectable.
    return panel and panel.Editable==true and (
        (panel.Kind=="Other" and panel.Other
            and (panel.Other.Kind=="Spell" or panel.Other.Kind=="Cantrip"))
        or panel.Kind=="AccordAdd" or panel.Kind=="AccordRecorded"
        or panel.Kind=="GenericSpellAdd" or panel.Kind=="GenericSpellRecorded"
        or panel.Kind=="ClassSpellGroup")
end
local function IsCurrentSpellbookObservation(panel)
    return panel and panel.Kind=="ObservedSpell" and
        tostring(panel.Title or ""):find("Current Spellbook",1,true)~=nil
end
local function CurrentEffectivePicks(panel)
    local ids={}
    if not panel then return ids end
    for _,id in ipairs(panel.CurrentIds or {}) do ids[#ids+1]=tostring(id) end
    if panel.Kind=="Passive" then
        local group=panel.Group
        local stages=(snapshot[currentLevel] or {})._HB_PreviewStaged or {}
        local pending=currentLevel>=2
            and (HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {})[currentLevel] or {}
        local effective={}
        for _,id in ipairs(ids) do
            local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..id
            if not pending[key] then
                effective[#effective+1]=tostring(stages[key] or id)
            end
        end
        ids=effective
    elseif panel.Kind=="Resource" then
        local edited=previewResources[currentLevel]
        if edited then ids[1]=tostring(edited) end
    elseif panel.Kind=="PassivePairAdd" then
        -- A newly chosen Class Specialist/Ability Improvement feat does not
        -- have historical picked IDs. Its displayed panel is a snapshot made
        -- BEFORE the click; read the successful staged pair instead so the
        -- clicked checkbox and counter immediately show 1/2, then 2/2.
        -- Do not inherit selections from a different feat on this level.
        ids={}
        if previewPairFeatIds[currentLevel]==panel.FeatId then
            for _,id in ipairs(previewPairChoices[currentLevel] or {}) do
                ids[#ids+1]=tostring(id)
            end
        end
    elseif panel.Kind=="ElementAdd" then
        -- The same stale-panel problem affects a newly added Elemental Adept:
        -- read the current two-element transaction, not panel.CurrentIds.
        ids={}
        for _,id in ipairs(previewNewElements[currentLevel] or {}) do
            ids[#ids+1]=tostring(id)
        end
    elseif panel.Kind=="AccordAdd" then
        ids={}
        for _,id in ipairs(HB_MULTIFACETED_NEW.Accord.Preview[currentLevel] or {}) do
            ids[#ids+1]=tostring(id)
        end
    elseif panel.Kind=="AccordRecorded" then
        ids={}
        local edits=previewOther[currentLevel] or {}
        for _,row in ipairs(panel.Rows or {}) do
            ids[#ids+1]=tostring(edits[ChoiceKey(row)] or row.From or "")
        end
    elseif panel.Kind=="GenericPassiveAdd" or panel.Kind=="GenericSpellAdd"
        or panel.Kind=="GenericSpellRecorded" then
        -- New feat secondary choices are staged in independent selector
        -- groups, NOT the original level's recorded passive list. Read back
        -- exactly the same state StageChoice updates after a native click.
        ids={}
        local staged=(previewGenericChoices[currentLevel] or {})[panel.SelectorIndex]
        for _,id in ipairs(staged or (panel.Kind=="GenericSpellRecorded" and panel.CurrentIds or {})) do
            ids[#ids+1]=tostring(id)
        end
    elseif panel.Kind=="MultifacetedAdd" then
        ids={}
        for _,id in ipairs(HB_MULTIFACETED_NEW.Selections(currentLevel,panel.Section)) do ids[#ids+1]=id end
    elseif panel.Kind=="MultifacetedSkills" then
        local edits=previewOther[currentLevel] or {}
        ids={}
        for _,row in ipairs(panel.Rows or {}) do
            ids[#ids+1]=tostring(edits[ChoiceKey(row)] or row.From or "")
        end
    elseif panel.Kind=="ClassSpellGroup" then
        ids={}
        local staged=previewOther[currentLevel] or {}
        local pending=HB_CLASS_SPELL_UI.Unchecked[currentLevel] or {}
        local displaced=(HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {})[currentLevel] or {}
        for _,row in ipairs(panel.Rows or {}) do
            local key=ChoiceKey(row)
            if not pending[key] and not displaced[key] then
                ids[#ids+1]=tostring(staged[key] or row.From or "")
            end
        end
    elseif panel.Kind=="Other" then
        local level=previewOther[currentLevel] or {}
        local edited=level[ChoiceKey(panel.Other)]
        -- A newly native-owned L1 spell invalidates a later pick even if
        -- that later choice had already been staged. Keep the stage record
        -- until manually replaced, but NEVER present it as filled.
        local cleared=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
        if currentLevel>=2 and (panel.Other.Kind=="Spell"
            or panel.Other.Kind=="Cantrip") and cleared[currentLevel]
            and cleared[currentLevel][ChoiceKey(panel.Other)] then
            ids={}
        elseif edited then
            ids[1]=tostring(edited)
        end
    end
    return ids
end
function HB_MULTIFACETED_UI.LevelOneExpertiseEligible(panel,id)
    if not panel or not panel.GroupedLevelOne
        or panel.GroupKind~="Expertise" then return true end
    if not panel.ProficiencyGroup then return false end
    for slot,skill in ipairs(CurrentEffectivePicks(panel.ProficiencyGroup)) do
        local source=(panel.ProficiencyGroup.Rows or {})[slot]
        if tostring(skill)==tostring(id) and source
            and not HB_MULTIFACETED_UI.IsUnchecked(panel.ProficiencyGroup,source) then
            return true
        end
    end
    return false
end
-- Pending unchecked skills are not committed changes: the authoritative
-- four choices remain intact until a matching replacement is staged. Visual
-- selection alone excludes the unchecked slots, including all four at once.
function HB_MULTIFACETED_UI.VisiblePicks(panel)
    local effective=CurrentEffectivePicks(panel)
    if not panel or panel.Kind~="MultifacetedSkills" then return effective end
    local visible={}
    for slot,id in ipairs(effective) do
        local row=(panel.Rows or {})[slot]
        local eligible=not (panel.GroupedLevelOne and panel.GroupKind=="Expertise")
            or HB_MULTIFACETED_UI.LevelOneExpertiseEligible(panel,id)
        if row and eligible and not HB_MULTIFACETED_UI.IsUnchecked(panel,row) then
            visible[#visible+1]=id
        end
    end
    return visible
end
local function PassiveOptionName(item)
    return Label(item)
end
local function CreateRow(option, selected, pending, editable)
    local row=Ext.UI.Instantiate(ROW_TYPE)
    row.Name=PassiveOptionName(option)
    row.PassiveId=tostring(option.PassiveId or "")
    row.Mark=selected and "✓" or "□"
    row.Detail=not editable and "View only" or pending and "Modified" or selected and "Selected" or "Available"
    return row
end
local function BuildPassiveRows(vm)
    passiveRows={}
    local panel,panels=ActivePanel()
    vm.HB_PassiveAvailable=(panel~=nil)
    vm.HB_PassiveGroupName=panel and (panel.Title.."  ("..passiveGroupIndex.."/"..#panels..")")
        or "No editable historical selections at this level"
    vm.HB_PassiveCanPrevious=panel~=nil and #panels>1
    vm.HB_PassiveCanNext=panel~=nil and #panels>1
    vm.HB_NativePanelTitle=panel and panel.Title or "Class Progression"
    if not panel then
        vm.HB_PassiveGuide="Move the level slider to review your historical choices."
        return
    end
    local effective=panel.Kind=="AccordRecorded"
        and HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel)
        or HB_MULTIFACETED_UI.VisiblePicks(panel)
    local original={}
    for _,id in ipairs(panel.CurrentIds or {}) do original[tostring(id)]=true end
    local selected={}
    for _,id in ipairs(effective) do selected[id]=true end
    local pickedCount=0
    for _,option in ipairs(panel.Options or {}) do
        local id=tostring(option.PassiveId or "")
        if id~="" then
            local active=selected[id] or false
            local row=CreateRow(option,active,active and not original[id],panel.Editable)
            vm.HB_PassiveRows[#vm.HB_PassiveRows+1]=row
            passiveRows[#passiveRows+1]={Id=id,Name=PassiveOptionName(option)}
            if active then pickedCount=pickedCount+1 end
        end
    end
    if not panel.Editable then
        vm.HB_PassiveGuide=panel.Kind=="ObservedSpell" and
            (IsCurrentSpellbookObservation(panel)
                and "Current spellbook: acquisition level and source unknown. View only; these are NOT verified historical selections."
                or "Read-only progression spells. These may be automatic class grants and are NOT verified player choices.")
            or "Recorded selection (view only). This option has no verified editing path."
    elseif panel.Kind=="MultifacetedAdd" then
        vm.HB_PassiveGuide=("%d/%d Multifaceted %s choices selected."):format(
            pickedCount,panel.MaxChoices,panel.Section)
    elseif panel.Kind=="MultifacetedSkills" then
        local max=panel.MaxChoices or 4
        vm.HB_PassiveGuide=armedFrom and
            ("%d/%d selected. Choose a replacement."):format(pickedCount,max)
            or ("%d/%d selected."):format(pickedCount,max)
    elseif panel.Kind=="Passive" then
        vm.HB_PassiveGuide=armedFrom and ("Select the replacement for "..Pretty(armedFrom)..".")
            or ("%d selected. Click a checked passive, then click its replacement."):format(pickedCount)
    else
        vm.HB_PassiveGuide=("%d selected. Click another option to stage a change."):format(pickedCount)
    end
end
local function ClearPreviewStaged()
    for _,row in pairs(snapshot) do
        if type(row)=="table" then row._HB_PreviewStaged=nil end
    end
    previewResources={}
    previewOther={}
    HB_NATIVE_L1_SLIDER.DisplacedSpellSlots={}
    HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts={}
    HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots={}
    HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels={}
    HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds={}
    HB_NATIVE_L1_SLIDER.PassiveCandidateIndex={}
    HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups={}
    HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup={}
    HB_NATIVE_L1_SLIDER.PassiveActiveGroups={}
    HB_MULTIFACETED_NEW.Preview={}
    HB_MULTIFACETED_NEW.Accord.Unchecked={}
    HB_CLASS_SPELL_UI.Unchecked={}
    HB_MULTIFACETED_UI.Clear()
end
-- A preflight for contradictions already provable from recorded historical
-- choices. Keep the authoritative replay validator on the SERVER; this only
-- prevents staging an obvious duplicate and explains it immediately.
-- Exact feat GUID flags from the user's supplied Feats.lsx; these are
-- additional negative safety evidence when Script Extender's runtime Feat
-- selectors/requirements accessor throws or omits its LSX member.
-- Treat unrecognized feats with unavailable runtime fields as PROTECTED.
local HB_SOURCE_FEAT_CONTRACTS={
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]={s=true,r=false}, -- AbilityImprovement
    ["cdcbc538-883b-401c-a8ed-1373fb6d1720"]={s=true,r=false}, -- AccordoftheArcane
    ["f57bd72c-be64-4855-9e3a-bb7d7665e656"]={s=false,r=false}, -- Alchemist
    ["d674aa33-8633-4b67-8623-b6788f0d5fc4"]={s=false,r=false}, -- Alert
    ["eab25714-15d6-4e26-b809-3fad832d0484"]={s=false,r=false}, -- AnchoredFocus
    ["94a78b4c-a8f2-404f-8cdc-2d454c13cb97"]={s=false,r=false}, -- ArcaneEchoes
    ["661eee63-ff91-4f29-9f21-3a974c9d6fe5"]={s=false,r=false}, -- Athleticism
    ["f692f7b5-ffd5-4942-91a1-a71ebb2f5e7c"]={s=false,r=false}, -- BlessingsoftheMoon
    ["71b65667-0eac-4e62-b878-fa862e88ebbf"]={s=false,r=false}, -- Charger
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]={s=true,r=false}, -- ClassDivergence_Barbarian
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]={s=true,r=false}, -- ClassDivergence_Bard
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]={s=true,r=false}, -- ClassDivergence_Cleric
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]={s=true,r=false}, -- ClassDivergence_Druid
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]={s=true,r=false}, -- ClassDivergence_Fighter
    ["b441c722-e4d4-4702-861a-039bfd77c124"]={s=true,r=false}, -- ClassDivergence_Monk
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]={s=true,r=false}, -- ClassDivergence_Paladin
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]={s=true,r=false}, -- ClassDivergence_Ranger
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]={s=true,r=false}, -- ClassDivergence_Rogue
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]={s=true,r=false}, -- ClassDivergence_Sorcerer
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]={s=true,r=false}, -- ClassDivergence_Warlock
    ["93d41226-d7af-495c-b023-08a6af077962"]={s=true,r=false}, -- ClassDivergence_Wizard
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={s=true,r=false}, -- ClassDivergence_Artificer
    ["26c6990b-d9f0-41a2-8108-209789fafc18"]={s=false,r=false}, -- CombatMedic
    ["455fc2d5-1c77-40e7-a010-0b51044ae74b"]={s=false,r=false}, -- Composed
    ["17ac3605-9a8a-41f3-9504-ffc17fffa03e"]={s=false,r=false}, -- DefensiveDuelist
    ["0a3b07bf-a806-4c77-9c8f-6e7c0965f9dd"]={s=false,r=false}, -- DualWielder
    ["681d5307-f0ed-4c94-8cf0-db0c51116f56"]={s=false,r=false}, -- Dunesis
    ["60dfd716-3ba8-4611-90ee-018b59775b1d"]={s=false,r=false}, -- Durable
    ["fdf0be80-cc1e-4501-bd2e-7a1ea737362c"]={s=true,r=false}, -- ElementalAdept
    ["b13c4744-1d45-42da-b92c-e09f598ab1c3"]={s=false,r=false}, -- GalvanizedStormsoul
    ["f3370916-6b35-4c5b-af36-19ca888cb43e"]={s=false,r=false}, -- GreaterImpact
    ["e061a323-3430-4cff-88d3-5eae7a1779a4"]={s=false,r=false}, -- IntrinsicArmoury
    ["816b1554-9384-49e9-aaa0-05dd622e60f7"]={s=false,r=false}, -- Lucky
    ["010f717e-c6e2-45cf-bbf9-298a72db4cad"]={s=false,r=false}, -- MageSlayer
    ["3fe71254-d1b2-44c7-886c-927552fe5f2e"]={s=false,r=false}, -- MartialAdept
    ["019564a0-f136-4139-94ea-040f94bbaf19"]={s=false,r=false}, -- MasonryofChaos
    ["c02f22c9-9a06-4001-b917-4d5cf09be399"]={s=false,r=false}, -- MeleeExpertise
    ["be0889d2-f9aa-472d-b942-592bff0f1ef3"]={s=true,r=false}, -- Multifaceted
    ["e8d1e7f6-d841-48ff-a83c-f1aaa16597ff"]={s=false,r=false}, -- Performer
    ["ed4e367d-d136-4285-abac-077147e84cf2"]={s=false,r=false}, -- PsionicDominance
    ["b153e75c-27a2-4412-95cd-60b477121679"]={s=false,r=false}, -- ReactiveAssault
    ["d7940fdc-44c6-4d0d-8997-56eb6e606587"]={s=false,r=false}, -- Resilient
    ["c06a8f0b-fbb8-4558-aa99-6985d45dfcad"]={s=false,r=false}, -- RestrictedTerritory
    ["922c48ff-8fe5-4212-b6ee-e48122ee67ef"]={s=false,r=false}, -- SavageAssault
    ["68f1ec15-2449-4ff1-aa72-6e35a0929091"]={s=false,r=false}, -- Sentinel
    ["0ef8204b-59c9-4ea2-adfb-fc984a7d3eb1"]={s=false,r=false}, -- Sharpshooter
    ["b29807ee-5cdd-4a5b-960c-1d1457488676"]={s=false,r=false}, -- Shieldbearer
    ["daed512b-e063-4c69-8b8c-ee0d1439266f"]={s=false,r=false}, -- Spellbreak
    ["46f6c764-44e0-4e58-8a3c-eb7ea0c0d887"]={s=false,r=false}, -- TavernBrawler
    ["a6e8c0dd-5389-4f62-ba97-2908e0bbb56b"]={s=false,r=false}, -- TogetherInTorment
    ["c760fcc0-c67a-4eea-a903-f051559b421f"]={s=false,r=false}, -- Tough
    ["dcd89533-e8ab-4660-a101-53bb14a920ca"]={s=false,r=false}, -- VisageofReflection
    ["47d60615-6d46-49ef-b993-1fa90274a90e"]={s=false,r=false}, -- WarCaster
    ["03777635-ef87-4d19-a859-92b8dd69f6dc"]={s=true,r=true}, -- ArtificerArcanist
    ["ce450c0d-a9d0-44a9-af97-2f2e8e990958"]={s=false,r=true}, -- ArtificerArtillerist
    ["2cbd8b96-78f0-4b29-ac6f-c59cb6d126c0"]={s=false,r=true}, -- ArtificerBattleSynthetic
    ["8dfca7e9-16a1-419c-bb92-faae1eed1bff"]={s=false,r=true}, -- ArtificerGrenadier
    ["35e99c06-63f9-429c-8064-25bc2e22e730"]={s=true,r=true}, -- ArtificerInfusedArcsmith
    ["c531fa20-17f2-4943-89e0-adf4f7a120b4"]={s=false,r=true}, -- ArtificerStriker
    ["4ffa557b-2ad4-4a8c-abe6-1d1965c07dd3"]={s=false,r=true}, -- BarbarianBeastheart
    ["75ce4c3a-884b-4c57-bec4-3e1cd0308523"]={s=false,r=true}, -- BarbarianBerserker
    ["f9fa2010-40ff-4d31-91cc-d72b150967fb"]={s=false,r=true}, -- BarbarianFrostbreaker
    ["de609f5b-bd4a-4155-b113-3e55093fc533"]={s=false,r=true}, -- BarbarianGiantsBlood
    ["6919302f-f2b9-44f5-8562-ec4315527292"]={s=false,r=true}, -- BarbarianRosemourn
    ["ae844b62-4b26-413d-8fce-20ca687f789a"]={s=true,r=true}, -- BarbarianWildSoul
    ["694647d6-2a79-4161-9bf0-d973e1ec2558"]={s=false,r=true}, -- BardCollegeOfCaptivation
    ["010dd210-461e-4aa8-b567-42f3ae52e2bd"]={s=true,r=true}, -- BardCollegeOfLore
    ["b296fca6-a2ad-4687-ac54-a359a65aed86"]={s=false,r=true}, -- BardCollegeofMoriendi
    ["3ce91e99-57d9-4c44-b80f-80e4c4952866"]={s=false,r=true}, -- BardCollegeofNostalgia
    ["e1b012c1-051a-4202-84cd-b037fc2ac6f8"]={s=false,r=true}, -- BardCollegeOfSteel
    ["43a56c6e-54b1-4151-97fc-0cc970fde672"]={s=false,r=true}, -- BardCollegeOfValour
    ["2544f577-59ed-47ae-868c-22ab0eab59a1"]={s=true,r=true}, -- ClericDeathDomain
    ["038aa39c-d4ca-41f0-8b25-8ca7b4356bc4"]={s=true,r=true}, -- ClericForgeDomain
    ["18586891-4b5f-4f08-879f-0960e202af11"]={s=true,r=true}, -- ClericIllusoryDomain
    ["abcb215a-f411-4b10-a804-f511467b956e"]={s=true,r=true}, -- ClericLifeDomain
    ["18659104-48f2-47d7-a4d5-87e3274f3308"]={s=true,r=true}, -- ClericTempestDomain
    ["ca55540b-9bf0-461d-936f-f4660b505775"]={s=true,r=true}, -- ClericWarDomain
    ["d88b9883-f310-404a-8f33-7fbc551049e3"]={s=false,r=true}, -- DruidCircleOfTheElements
    ["d3734a53-6c64-4280-b499-f8ab4dfbce46"]={s=false,r=true}, -- DruidCircleOfTheLand
    ["f6a8994c-0351-4d3c-bba1-dee3c188f6c8"]={s=true,r=true}, -- DruidCircleOfTheMoon
    ["9c6edc2f-24ab-42a6-acdf-0879efc5f41f"]={s=false,r=true}, -- DruidCircleOfTheShadows
    ["15f43f0e-f065-4307-b50c-247005a293da"]={s=false,r=true}, -- DruidCircleOfTheSpores
    ["e139d9a4-1bd9-4dd4-8db8-7cedf707ee13"]={s=false,r=true}, -- DruidCircleOfTheStars
    ["51b7587d-966a-4f3b-b7c4-4e9fe8cf86f0"]={s=true,r=true}, -- DruidTotemist
    ["07845122-15ec-4c3a-8724-ef9c8fb72f48"]={s=false,r=true}, -- DruidCircleoftheVenom
    ["c759cc6b-f4d7-4d69-a52e-5a65b9ffc612"]={s=true,r=true}, -- FighterArcaneArcher
    ["415dc709-9944-4f49-ac97-d63081a338ac"]={s=false,r=true}, -- FighterChampion
    ["0bd9516c-195e-4012-bced-cb7528cbbc63"]={s=false,r=true}, -- FighterDraconicSentinel
    ["9715353b-13b3-4cbc-ae1d-db99b7f6cc67"]={s=true,r=true}, -- FighterEldritchKnight
    ["e39d5a46-c03a-4ee4-89f8-e522c86085a8"]={s=true,r=true}, -- FighterFrontierKnight
    ["30498f77-3440-42dc-a61a-cb05ac49b248"]={s=false,r=true}, -- FighterPalisade
    ["c9cffeb1-2cb0-44a2-a090-9db2026d549c"]={s=true,r=true}, -- MonkWayOfTheArcane
    ["c4b9ac83-eccc-4118-b851-302ceea16584"]={s=false,r=true}, -- MonkWayOfTheDrunkenFist
    ["1124cc40-5703-4516-8a5a-9ba3bdc52d45"]={s=false,r=true}, -- MonkWayOfTheGentleFist
    ["b62b79dc-a53b-481e-95af-6e3d3b8e0908"]={s=false,r=true}, -- MonkWayOfTheOpenHand
    ["924ca4a7-755d-42c3-9c5f-02fd64ea46c0"]={s=false,r=true}, -- MonkWayOfTheShadowArts
    ["8f0ee646-0114-4f46-8ff3-d2b5bcaf1ca7"]={s=false,r=true}, -- MonkWayOfTheTemperedSteel
    ["4c9def45-b180-4bf3-81e8-ec924d9a629a"]={s=false,r=true}, -- PaladinOathOfTheAncients
    ["b143df54-0b4f-48bf-9ddc-308168bc86f8"]={s=false,r=true}, -- PaladinOathOfTheCrown
    ["e38341cb-f364-468b-9862-67dcadba72db"]={s=false,r=true}, -- PaladinOathOfDevotion
    ["750c4922-f381-4f37-bf26-1d0a91a7a797"]={s=false,r=true}, -- PaladinOathOfVengeance
    ["3998987c-004f-4913-b7a7-62610e3cb45e"]={s=true,r=true}, -- PaladinOathbreaker
    ["6b4bdec0-9753-46c1-967d-0c7e7b5ef039"]={s=false,r=true}, -- PaladinMystflame
    ["47ab16a3-7f3e-4fa3-9ad2-0e884c2f8384"]={s=false,r=true}, -- PaladinTyrant
    ["d8db4bce-a761-4c74-aaf6-ce62ffd7576a"]={s=false,r=true}, -- RangerBeastmaster
    ["07e4218c-fe07-473a-914a-6e53c4e911a0"]={s=false,r=true}, -- RangerGloomstalker
    ["0d28f4d0-30e2-4948-8b9c-137778929a4a"]={s=false,r=true}, -- RangerHunter
    ["287ca7d6-c056-4366-b340-2e9acb1000a7"]={s=false,r=true}, -- RangerMireMist
    ["2fbf3785-a116-41bc-b696-a50432ec46e2"]={s=true,r=true}, -- RangerSwarmkeeper
    ["bfe6f78a-6dde-40e5-9982-2ed2a471f518"]={s=false,r=true}, -- RangerTwinfang
    ["32700827-6d27-40a2-b0a1-b176875af5a7"]={s=true,r=true}, -- RogueArcaneTrickster
    ["f1d35a6c-9c64-4431-862b-972e1004b628"]={s=false,r=true}, -- RogueAssassin
    ["34539fe0-ef9f-4ae1-a218-95f431ef67da"]={s=false,r=true}, -- RogueGauntlet
    ["a434fbc2-676c-4123-8d9a-24dd2e5d6898"]={s=false,r=true}, -- RogueHiddenToxicant
    ["719ecbac-b1db-4dcc-a845-0fd44d17152c"]={s=false,r=true}, -- RogueSwashbuckler
    ["3ae7b1ea-be32-4cd2-8a36-545e4a40a3b9"]={s=false,r=true}, -- RogueThief
    ["42a995f6-fc5e-4577-b21b-eb7fa6c773ec"]={s=false,r=true}, -- RogueVirulence
    ["ba1c505b-a3a8-483a-a061-a8b120c45c00"]={s=true,r=true}, -- SorcererDraconicBloodline
    ["335d2999-28e5-4bfa-a107-534f5824748f"]={s=false,r=true}, -- SorcererHematicMonarch
    ["35e6f8f0-01d4-4273-ad6b-994b287fabd1"]={s=false,r=true}, -- SorcererRadiantBloom
    ["4df54b62-d011-4a95-8f97-e52f823b553d"]={s=false,r=true}, -- SorcererShadeWalker
    ["9c24e1ca-bfe6-4252-a1d7-31e288e23f38"]={s=false,r=true}, -- SorcererSouloftheFrenziedTundra
    ["10a9438c-a01e-4822-a6d9-537a6ce8bb17"]={s=false,r=true}, -- SorcererVolcanist
    ["219431d8-c164-454a-b274-0fbf01a7ad2d"]={s=false,r=true}, -- SorcererWildMagic
    ["4f136e0d-6548-44e3-ad1c-fcbe28ce58b4"]={s=false,r=true}, -- WarlockPactOfTheBlade
    ["71c0b76e-3c66-45f8-80ac-98ba0f272fdb"]={s=false,r=true}, -- WarlockPactOfTheChain
    ["0d17dbdd-57d6-4779-9d76-ebbdb2459b95"]={s=false,r=true}, -- WarlockPactOfThePenumbra
    ["656cdba8-d560-42f2-8776-a7c575115fbd"]={s=false,r=true}, -- WarlockPactOfThePrimordialDemon
    ["866befae-74b3-45a0-9da4-bdec17a3a63d"]={s=false,r=true}, -- WarlockPactOfSeverance
    ["525212a2-e568-483d-994f-4c7eeee7fe94"]={s=false,r=true}, -- WarlockPactOfTheTome
    ["84240516-b152-4008-a28a-39e1a6fd4693"]={s=false,r=true}, -- WizardArcblade
    ["00ffa9e2-c8be-44b5-bc72-25293a715430"]={s=false,r=true}, -- WizardArcaneWarden
    ["ae7218f2-90bb-4f90-8acb-a9946fe85a24"]={s=false,r=true}, -- WizardElementalist
    ["2f5710ec-6ad4-4060-97a4-99b701455dac"]={s=false,r=true}, -- WizardEvoker
    ["95dce8e9-bdd9-4951-8a05-8c5480f60352"]={s=false,r=true}, -- WizardLuminalConfluence
    ["f86e70f9-7936-442c-b335-e1e77bb65d8a"]={s=false,r=true}, -- WizardNecromancy
}

-- Feat skill choices must not duplicate a proficiency already selected
-- at another historical level. The server independently rejects these
-- targets during replay. Checking the recorded history here makes them
-- visibly unavailable rather than permitting a doomed Confirm.
local function HistoricalSkillTakenOnOtherLevel(skill,excludedLevel)
    skill=tostring(skill or "")
    if skill=="" then return nil end
    for level=1,maximum do
        if level~=excludedLevel then
            local choices=(snapshot[level] or {}).LevelChoices or {}
            for _,row in ipairs(choices.OtherChoices or {}) do
                if tostring(row.Kind or "")=="Skill" then
                    local picked=tostring((previewOther[level] or {})[ChoiceKey(row)]
                        or row.From or "")
                    if picked==skill then return level end
                end
            end
        end
    end
    return nil
end

-- EXPERIMENT ONLY: expose every feat target regardless of historical
-- selector/prerequisite/duplicate restrictions. Does not add replay handlers.
local HB_UNRESTRICTED_FEAT_TEST=true
-- TEMPORARY FEAT AUDIT ONLY: allow Yokebreaker subclass-style feats to be
-- selected from any class so every candidate can be tested. Restore this
-- to false when feat testing is complete. Does NOT synthesize missing
-- subclass grants, native selectors, or bypass replay ownership checks.
HB_YOKEBREAKER_ALL_CLASSES_TEST=false

HB_HISTORICAL_FEAT_CLASS_REQUIREMENTS={
    ["00ffa9e2-c8be-44b5-bc72-25293a715430"]="Wizard",
    ["010dd210-461e-4aa8-b567-42f3ae52e2bd"]="Bard",
    ["03777635-ef87-4d19-a859-92b8dd69f6dc"]="Artificer",
    ["038aa39c-d4ca-41f0-8b25-8ca7b4356bc4"]="Cleric",
    ["07845122-15ec-4c3a-8724-ef9c8fb72f48"]="Druid",
    ["07e4218c-fe07-473a-914a-6e53c4e911a0"]="Ranger",
    ["0bd9516c-195e-4012-bced-cb7528cbbc63"]="Fighter",
    ["0d17dbdd-57d6-4779-9d76-ebbdb2459b95"]="Warlock",
    ["0d28f4d0-30e2-4948-8b9c-137778929a4a"]="Ranger",
    ["10a9438c-a01e-4822-a6d9-537a6ce8bb17"]="Sorcerer",
    ["1124cc40-5703-4516-8a5a-9ba3bdc52d45"]="Monk",
    ["15f43f0e-f065-4307-b50c-247005a293da"]="Druid",
    ["18586891-4b5f-4f08-879f-0960e202af11"]="Cleric",
    ["18659104-48f2-47d7-a4d5-87e3274f3308"]="Cleric",
    ["219431d8-c164-454a-b274-0fbf01a7ad2d"]="Sorcerer",
    ["2544f577-59ed-47ae-868c-22ab0eab59a1"]="Cleric",
    ["287ca7d6-c056-4366-b340-2e9acb1000a7"]="Ranger",
    ["2cbd8b96-78f0-4b29-ac6f-c59cb6d126c0"]="Artificer",
    ["2f5710ec-6ad4-4060-97a4-99b701455dac"]="Wizard",
    ["2fbf3785-a116-41bc-b696-a50432ec46e2"]="Ranger",
    ["30498f77-3440-42dc-a61a-cb05ac49b248"]="Fighter",
    ["32700827-6d27-40a2-b0a1-b176875af5a7"]="Rogue",
    ["335d2999-28e5-4bfa-a107-534f5824748f"]="Sorcerer",
    ["34539fe0-ef9f-4ae1-a218-95f431ef67da"]="Rogue",
    ["35e6f8f0-01d4-4273-ad6b-994b287fabd1"]="Sorcerer",
    ["35e99c06-63f9-429c-8064-25bc2e22e730"]="Artificer",
    ["3998987c-004f-4913-b7a7-62610e3cb45e"]="Paladin",
    ["3ae7b1ea-be32-4cd2-8a36-545e4a40a3b9"]="Rogue",
    ["3ce91e99-57d9-4c44-b80f-80e4c4952866"]="Bard",
    ["415dc709-9944-4f49-ac97-d63081a338ac"]="Fighter",
    ["42a995f6-fc5e-4577-b21b-eb7fa6c773ec"]="Rogue",
    ["43a56c6e-54b1-4151-97fc-0cc970fde672"]="Bard",
    ["47ab16a3-7f3e-4fa3-9ad2-0e884c2f8384"]="Paladin",
    ["4c9def45-b180-4bf3-81e8-ec924d9a629a"]="Paladin",
    ["4df54b62-d011-4a95-8f97-e52f823b553d"]="Sorcerer",
    ["4f136e0d-6548-44e3-ad1c-fcbe28ce58b4"]="Warlock",
    ["4ffa557b-2ad4-4a8c-abe6-1d1965c07dd3"]="Barbarian",
    ["51b7587d-966a-4f3b-b7c4-4e9fe8cf86f0"]="Druid",
    ["525212a2-e568-483d-994f-4c7eeee7fe94"]="Warlock",
    ["656cdba8-d560-42f2-8776-a7c575115fbd"]="Warlock",
    ["6919302f-f2b9-44f5-8562-ec4315527292"]="Barbarian",
    ["694647d6-2a79-4161-9bf0-d973e1ec2558"]="Bard",
    ["6b4bdec0-9753-46c1-967d-0c7e7b5ef039"]="Paladin",
    ["719ecbac-b1db-4dcc-a845-0fd44d17152c"]="Rogue",
    ["71c0b76e-3c66-45f8-80ac-98ba0f272fdb"]="Warlock",
    ["750c4922-f381-4f37-bf26-1d0a91a7a797"]="Paladin",
    ["75ce4c3a-884b-4c57-bec4-3e1cd0308523"]="Barbarian",
    ["84240516-b152-4008-a28a-39e1a6fd4693"]="Wizard",
    ["866befae-74b3-45a0-9da4-bdec17a3a63d"]="Warlock",
    ["8dfca7e9-16a1-419c-bb92-faae1eed1bff"]="Artificer",
    ["8f0ee646-0114-4f46-8ff3-d2b5bcaf1ca7"]="Monk",
    ["924ca4a7-755d-42c3-9c5f-02fd64ea46c0"]="Monk",
    ["95dce8e9-bdd9-4951-8a05-8c5480f60352"]="Wizard",
    ["9715353b-13b3-4cbc-ae1d-db99b7f6cc67"]="Fighter",
    ["9c24e1ca-bfe6-4252-a1d7-31e288e23f38"]="Sorcerer",
    ["9c6edc2f-24ab-42a6-acdf-0879efc5f41f"]="Druid",
    ["a434fbc2-676c-4123-8d9a-24dd2e5d6898"]="Rogue",
    ["abcb215a-f411-4b10-a804-f511467b956e"]="Cleric",
    ["ae7218f2-90bb-4f90-8acb-a9946fe85a24"]="Wizard",
    ["ae844b62-4b26-413d-8fce-20ca687f789a"]="Barbarian",
    ["b143df54-0b4f-48bf-9ddc-308168bc86f8"]="Paladin",
    ["b296fca6-a2ad-4687-ac54-a359a65aed86"]="Bard",
    ["b62b79dc-a53b-481e-95af-6e3d3b8e0908"]="Monk",
    ["ba1c505b-a3a8-483a-a061-a8b120c45c00"]="Sorcerer",
    ["bfe6f78a-6dde-40e5-9982-2ed2a471f518"]="Ranger",
    ["c4b9ac83-eccc-4118-b851-302ceea16584"]="Monk",
    ["c531fa20-17f2-4943-89e0-adf4f7a120b4"]="Artificer",
    ["c759cc6b-f4d7-4d69-a52e-5a65b9ffc612"]="Fighter",
    ["c9cffeb1-2cb0-44a2-a090-9db2026d549c"]="Monk",
    ["ca55540b-9bf0-461d-936f-f4660b505775"]="Cleric",
    ["ce450c0d-a9d0-44a9-af97-2f2e8e990958"]="Artificer",
    ["d3734a53-6c64-4280-b499-f8ab4dfbce46"]="Druid",
    ["d88b9883-f310-404a-8f33-7fbc551049e3"]="Druid",
    ["d8db4bce-a761-4c74-aaf6-ce62ffd7576a"]="Ranger",
    ["de609f5b-bd4a-4155-b113-3e55093fc533"]="Barbarian",
    ["e139d9a4-1bd9-4dd4-8db8-7cedf707ee13"]="Druid",
    ["e1b012c1-051a-4202-84cd-b037fc2ac6f8"]="Bard",
    ["e38341cb-f364-468b-9862-67dcadba72db"]="Paladin",
    ["e39d5a46-c03a-4ee4-89f8-e522c86085a8"]="Fighter",
    ["f1d35a6c-9c64-4431-862b-972e1004b628"]="Rogue",
    ["f6a8994c-0351-4d3c-bba1-dee3c188f6c8"]="Druid",
    ["f86e70f9-7936-442c-b335-e1e77bb65d8a"]="Wizard",
    ["f9fa2010-40ff-4d31-91cc-d72b150967fb"]="Barbarian",
}

function HBHistoricalRequiredClass(featId,level)
    local cls=HB_HISTORICAL_FEAT_CLASS_REQUIREMENTS[tostring(featId or ""):lower()]
    if not cls then return nil end
    -- Only the catalogued Yokebreaker class gate is suspended for the audit;
    -- genuine historical feat provenance is still validated separately.
    if HB_YOKEBREAKER_ALL_CLASSES_TEST then return nil end
    for i=1,level do
        local row=((snapshot[i] or {}).LevelChoices or {})
        local id=tostring((row.Source or {}).ClassId or "")
        if row.HistoryAvailable~=false and id~="" then
            local name=nil
            if Ext.StaticData and Ext.StaticData.Get then
                local ok,record=pcall(Ext.StaticData.Get,id,"ClassDescription")
                if ok and record then name=tostring(Read(record,"Name") or "") end
            end
            if not name or name=="" then
                local display=row.Class
                if type(display)=="table" then
                    name=tostring(display.DisplayNameFallback or display.Name or "")
                else name=tostring(display or "") end
            end
            if name:lower()==cls:lower() then return nil end
        end
    end
    return "Requires at least one "..cls.." level at or before historical level "..tostring(level).."."
end

-- Localized Class Specialist labels have placeholder IDs. Their real
-- ClassDivergence equivalents have distinct UUIDs and selector lists in the
-- installed catalog; a localized placeholder must NEVER inherit one of those
-- lists. Keep the placeholders visible but explicitly unselectable.
function HB_SPECIALIST_MISSING_SELECTOR(id)
    id=tostring(id or ""):lower()
    local suffix=id:match("^8a87461fd8dd4f5b9098ded714f6c8aa(%d%d%d%d%d)$")
    local variant=suffix and tonumber(suffix)
    if not ((variant and variant>=6 and variant<=17)
        or id=="8a87461fd8dd4f5b9098ded714f6c8aa2d1f2") then
        return false
    end
    local definition=HB_GENERIC_FEATS.Definition(id)
    local groups=HB_GENERIC_FEATS.PassiveSelectors(id)
    if not definition or not groups or #groups~=1 or not groups[1].List then
        return true
    end
    local options=HBGenericOptions(groups[1].List)
    return #options<tonumber(groups[1].Count or 1)
end

local function LocalChoiceConflict(panel,id)
    if not panel or panel.Kind~="Other" or not panel.Other then return nil end
    local origin=panel.Other
    id=tostring(id or "")
    if id==tostring(origin.From or "") then return nil end -- restore original
    local kind=tostring(origin.Kind or "")
    -- The temporary unrestricted feat audit must never bypass an absent
    -- source-owned selector contract. Zetherist and other unsupported Class
    -- Specialist variants may be listed by FeatDescription localization
    -- without their actual selectable passive-list definition in this mod.
    if kind=="Feat" then
        -- Placeholder FeatDescription handles are not feat UUIDs. Only an
        -- exact installed catalog entry with its own populated selector can
        -- be staged; never re-use the previously opened class's passive VM.
        if HB_SPECIALIST_MISSING_SELECTOR(id) then
            return "Class Specialist: no verified class-specific passive list exists for this feat. Selection unavailable."
        end
        LoadFeatTextCache()
        local rule=featRuleCache and featRuleCache[id]
        if rule and rule.Kind=="PassiveChoices"
            and not HB_PASSIVE_PAIR_FEATS[id]
            and not HB_GENERIC_FEATS.PassiveSelectors(id) then
            return "This Class Specialist feat has no verified passive selector. No edit staged."
        end
    end
    if kind=="Feat" then
        local classError=HBHistoricalRequiredClass(id,currentLevel)
        if classError then return classError end
    end
    if kind=="Ability" then
        -- HB Ability Improvement is a pair of passive ability choices, not
        -- vanilla + / - controls. Never create two identical selections in
        -- the very same recorded AbilityBonuses row. Another independent
        -- upgrade at the same character level is not assumed feat-owned.
        local rows=((snapshot[currentLevel] or {}).LevelChoices or {}).OtherChoices or {}
        for _,other in ipairs(rows) do
            if other~=origin and other.Kind=="Ability"
                and other.Source==origin.Source
                and other.EntryIndex==origin.EntryIndex
                and other.SlotIndex~=origin.SlotIndex then
                local edits=previewOther[currentLevel] or {}
                local picked=tostring(edits[ChoiceKey(other)] or other.From or "")
                if picked==id then
                    return "This ability is already selected in the same recorded ability-choice group."
                end
            end
        end
    elseif kind=="Spell" or kind=="Cantrip" or kind=="Skill" or kind=="Expertise" then
        if kind=="Skill" and tostring(origin.FeatOwnerId or "")
            =="be0889d2-f9aa-472d-b942-592bff0f1ef3" then
            local otherLevel=HistoricalSkillTakenOnOtherLevel(id,currentLevel)
            if otherLevel then
                return "This skill is already selected at level "..tostring(otherLevel)
                    .."; Multifaceted cannot grant it again."
            end
        end
        local rows=((snapshot[currentLevel] or {}).LevelChoices or {}).OtherChoices or {}
        for _,other in ipairs(rows) do
            if other~=origin and ChoiceKey(other)~=ChoiceKey(origin)
                and tostring(other.Kind)==kind
                and (tostring(other.List or "")==tostring(origin.List or "")
                    or (tostring(origin.FeatOwnerId or "")~=""
                        and tostring(other.FeatOwnerId or "")
                            ==tostring(origin.FeatOwnerId))) then
                local edits=previewOther[currentLevel] or {}
                local current=tostring(edits[ChoiceKey(other)] or other.From or "")
                if current==id then
                    return "That "..kind.." is already selected at this historical level. Choose a different option."
                end
            end
        end
    elseif kind=="Feat" then
        local wasTaken=false
        for level=1,maximum do
            if level~=currentLevel then
            local choices=(snapshot[level] or {}).LevelChoices or {}
            local foundRecorded=false
            for _,other in ipairs(choices.OtherChoices or {}) do
                if other.Kind=="Feat" then
                    foundRecorded=true
                    local effective=tostring((previewOther[level] or {})[ChoiceKey(other)] or other.From or "")
                    if effective==id then wasTaken=true;break end
                end
            end
            if not foundRecorded and choices.Source and tostring(choices.Source.FeatId or "")==id then
                wasTaken=true
            end
            if wasTaken then break end
            end
        end
        if wasTaken then
            local repeatable=false
            if Ext.StaticData and Ext.StaticData.Get then
                local ok,feat=pcall(Ext.StaticData.Get,id,"Feat")
                repeatable=ok and feat and Read(feat,"CanBeTakenMultipleTimes")==true
            end
            if not repeatable then
                return "This nonrepeatable feat is already selected at another historical level."
            end
        end
        -- Experimental unrestricted feat testing must never permit a
        -- nonrepeatable feat at two historical levels. Duplicate ownership
        -- is checked above even when prereq auditing is temporarily relaxed.
        if HB_UNRESTRICTED_FEAT_TEST then return nil end
        -- Match the conservative server replay guard *before* staging an
        -- attractive but unsafe feat. These values describe FEAT metadata,
        -- not BG3's historical eligibility; requirements cannot be evaluated
        -- merely because the currently high-level character satisfies them.
        if not Ext.StaticData or not Ext.StaticData.Get then
            return "Cannot verify the historical feat's static data. No edit staged."
        end
        local ok,feat=pcall(Ext.StaticData.Get,id,"Feat")
        if not ok or not feat then
            return "Replacement feat metadata is unavailable; no edit staged."
        end
        local currentFeatId=tostring(origin.From or "")
        local oldOK,oldFeat=pcall(Ext.StaticData.Get,currentFeatId,"Feat")
        if not oldOK or not oldFeat then
            return "Original feat metadata is unavailable; no edit staged."
        end
        local function RequiresSecondary(record,field,id)
            local source=HB_SOURCE_FEAT_CONTRACTS[tostring(id or ""):lower()]
            local sourceProtected=source and (field=="Selectors" and source.s
                or field=="Requirements" and source.r)
            local value=Read(record,field)
            if value==nil or value==false then
                if source then return sourceProtected==true end
                return true -- unknown feat and unreadable runtime metadata
            end
            if type(value)=="string" then
                return sourceProtected==true or value:match("%S")~=nil
            end
            if type(value)=="table" then
                return sourceProtected==true or next(value)~=nil
            end
            return sourceProtected==true or tostring(value)~=""
        end
        -- HB changes many vanilla feat mechanics. Use the actual feat's
        -- linked FeatDescription localization handle as an independent guard.
        -- Missing static name links do not imply that any unknown feat is safe.
        LoadFeatTextCache()
        local oldRule=featRuleCache and featRuleCache[currentFeatId]
        local newRule=featRuleCache and featRuleCache[id]
        local removingExistingElementalAdept=currentFeatId=="fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
            and oldRule and oldRule.Kind=="ElementChoices"
        local removingAccord=currentFeatId==HB_MULTIFACETED_NEW.Accord.Feat
            and oldRule and oldRule.Kind=="CantripChoices"
        local removingPair=HB_PASSIVE_PAIR_FEATS[currentFeatId]~=nil
        local originalKnownFixed=HB_GENERIC_FEATS.IsKnownFixedOnly(currentFeatId)
        local targetKnownFixed=HB_GENERIC_FEATS.IsKnownFixedOnly(id)
        local removingGeneric=HB_GENERIC_FEATS.PassiveSelectors(currentFeatId)~=nil
            and not HB_PASSIVE_PAIR_FEATS[currentFeatId]
            and currentFeatId~=HB_ELEMENTAL_ADEPT_FEAT
            and currentFeatId~=HB_MULTIFACETED_NEW.Feat
        local addingGeneric=HB_GENERIC_FEATS.PassiveSelectors(id)~=nil
            and not HB_PASSIVE_PAIR_FEATS[id] and id~=HB_ELEMENTAL_ADEPT_FEAT
            and id~=HB_MULTIFACETED_NEW.Feat
        local removingMultifaceted=currentFeatId=="be0889d2-f9aa-472d-b942-592bff0f1ef3"
            and oldRule and oldRule.Kind=="MixedChoices"
        if oldRule and not removingExistingElementalAdept and not removingPair
            and not removingMultifaceted and not removingAccord and not removingGeneric
            and not originalKnownFixed then
            return "The original HB feat grants "..oldRule.Choices
                ..". Its historical choices cannot be removed by a feat ID swap."
        end
        local addingAccord=id==HB_MULTIFACETED_NEW.Accord.Feat
            and not oldRule and newRule and newRule.Kind=="CantripChoices"
        local addingElementalAdept=id==HB_ELEMENTAL_ADEPT_FEAT
            and (not oldRule or removingPair) and newRule and newRule.Kind=="ElementChoices"
        local addingMultifaceted=id==HB_MULTIFACETED_NEW.Feat
            and not oldRule and newRule and newRule.Kind=="MixedChoices"
        local addingPair=HB_PASSIVE_PAIR_FEATS[id]~=nil
            and (not oldRule or removingPair or removingExistingElementalAdept)
        if newRule and not addingElementalAdept and not addingPair
            and not addingMultifaceted and not addingAccord and not addingGeneric
            and not targetKnownFixed then
            return "This HB feat grants "..newRule.Choices
                ..". Its choices require faithful native historical selection and replay."
        end
        if not removingExistingElementalAdept and not removingPair
            and not removingMultifaceted and not removingAccord and not removingGeneric
            and RequiresSecondary(oldFeat,"Selectors",currentFeatId) then
            return "The original feat has secondary allocations that a feat ID swap cannot reconstruct safely."
        end
        if not addingElementalAdept and not addingPair and not addingMultifaceted
            and not addingAccord and not addingGeneric and RequiresSecondary(feat,"Selectors",id) then
            return "This feat requires secondary selections that cannot yet be reconstructed safely."
        end
        if RequiresSecondary(feat,"Requirements",id)
            and HB_GENERIC_FEATS.RequiredClass(id)==nil then
            return "This feat has prerequisites that cannot yet be evaluated at the historical level."
        end
    end
    return nil
end

-- An original L1 passive is no longer owned at L1 ONLY when the exact
-- editable selector that originally granted it has been observed actively
-- in BG3's native L1 screen with a different complete selection. No missing
-- or hidden VM evidence is treated as proof of removal. This never changes
-- serialized CCLevelUp; the server verifies the committed L1 before replay.
function HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed(id)
    id=tostring(id or "")
    if id=="" then return false end
    local observed=HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups or {}
    local found=false
    for _,group in ipairs((((snapshot[1] or {}).LevelChoices or {}).EditablePassiveGroups or {})) do
        for _,old in ipairs(group.Picked or {}) do
            if tostring(old)==id then
                found=true
                local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList)
                local choices=observed[key]
                if not choices or choices[id] then return false end
            end
        end
    end
    return found
end

local function HistoricalPassiveTakenOnOtherLevel(id,excludedLevel)
    id=tostring(id or "")
    if id=="" then return nil end
    -- Exact native L1 selections take priority over the original saved
    -- L1 choice: a displaced later row may not reselect its conflict.
    if excludedLevel~=1 and (HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds or {})[id]
        and not HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed(id) then
        return 1
    end
    for level=1,maximum do
        if level~=excludedLevel then
            local data=(snapshot[level] or {}).LevelChoices or {}
            local stages=(snapshot[level] or {})._HB_PreviewStaged or {}
            for _,group in ipairs(data.EditablePassiveGroups or {}) do
                for _,old in ipairs(group.Picked or {}) do
                    local original=tostring(old)
                    local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..original
                    local empty=level>=2
                        and ((HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {})[level] or {})[key]
                    if not empty and tostring(stages[key] or original)==id
                        and not (level==1 and HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed(id)) then
                        return level
                    end
                end
            end
        end
    end
    return nil
end

local function StageChoice(index)
    if not previewOpen then return end
    local panel=ActivePanel()
    local row=passiveRows[index]
    if not panel or not row then return end
    local id=row.Id
    local stagedSuccessfully=false
    if not panel.Editable then
        passiveFeedback="This recorded choice isn't editable yet."
    elseif panel.Kind=="Passive" then
        local group=panel.Group
        local effectiveToOriginal={}
        local staged=(snapshot[currentLevel] or {})._HB_PreviewStaged or {}
        local pending=(HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {})[currentLevel] or {}
        local pendingFrom=nil
        for _,old in ipairs(group.Picked or {}) do
            old=tostring(old)
            local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..old
            if currentLevel>=2 and pending[key] then
                pendingFrom=pendingFrom or old
            else
                effectiveToOriginal[staged[key] or old]=old
            end
        end
        if effectiveToOriginal[id] then
            if armedFrom~=nil and armedFrom~=effectiveToOriginal[id] then
                -- A different checked passive is NOT an available replacement.
                -- Keep the originally emptied slot armed; never silently move
                -- that slot to another original choice. A second click on the
                -- same checked passive is deliberately ignored in this state.
                passiveFeedback="That passive is already selected. Choose an unchecked replacement."
                Log("NATIVE_PASSIVE_SELECTED_WHILE_ARMED level="..currentLevel
                    .." pending="..tostring(armedFrom).." selected="..tostring(id))
            elseif armedFrom==effectiveToOriginal[id] then
                armedFrom=nil
                passiveFeedback="Selection unchanged."
            else
                armedFrom=effectiveToOriginal[id]
                passiveFeedback="Choose another option to replace "..row.Name.."."
            end
        elseif armedFrom or pendingFrom then
            -- A displaced passive is already visually unchecked (0/1).
            -- Its next valid selection fills the original recorded slot;
            -- no preliminary click on an invisible checked row is needed.
            local from=armedFrom or pendingFrom
            -- Selecting an option already checked in this independent group
            -- must not create a second copy of that passive. The server also
            -- verifies final cross-level uniqueness on the replay snapshot.
            local picked=CurrentEffectivePicks(panel)
            local duplicate=false
            for _,selectedId in ipairs(picked) do
                if tostring(selectedId)==id then duplicate=true;break end
            end
            if duplicate then
                passiveFeedback="That passive is already selected in this group."
            elseif not onStagePassive then
                passiveFeedback="Editor staging callback unavailable."
            else
                local ok, success, message=pcall(onStagePassive,currentLevel,group.SelectorId,group.PassiveList,from,id)
                if not ok then passiveFeedback="Stage failed: "..tostring(success)
                else
                    passiveFeedback=tostring(message or (success and "Edit staged." or "Edit rejected."))
                    if success then
                        stagedSuccessfully=true
                        local level=snapshot[currentLevel]
                        level._HB_PreviewStaged=level._HB_PreviewStaged or {}
                        local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..from
                        level._HB_PreviewStaged[key]=id==from and nil or id
                        local emptied=(HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {})[currentLevel]
                        if emptied and emptied[key] then
                            emptied[key]=nil
                            if not next(emptied) then
                                HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots[currentLevel]=nil
                            end
                            Log("NATIVE_L1_PASSIVE_SLOT_FILLED level="..currentLevel
                                .." from="..from.." to="..id)
                        end
                        armedFrom=nil
                        Log("Historical passive staged: level="..currentLevel.." ["..tostring(group.SelectorId).."] "..from.." -> "..id)
                    end
                end
            end
        else
            passiveFeedback="First click a checked passive, then an available replacement."
        end
    elseif panel.Kind=="GenericPassiveAdd" then
        if not onStageOther then
            passiveFeedback="Historical feat selector staging unavailable."
        elseif HistoricalPassiveTakenOnOtherLevel(id,currentLevel) then
            passiveFeedback="Passive already belongs to another historical level."
        else
            local ok,success,message=pcall(onStageOther,currentLevel,
                {Kind="HB_GenericPassiveAdd",FeatId=panel.FeatId,
                    SelectorIndex=panel.SelectorIndex,List=panel.List},id)
            passiveFeedback=ok and tostring(message or (success and "Choice updated." or "Choice rejected."))
                or ("Feat selector callback error: "..tostring(success))
            if ok and success then
                previewGenericChoices[currentLevel]=previewGenericChoices[currentLevel] or {}
                local groups=previewGenericChoices[currentLevel]
                local current=groups[panel.SelectorIndex] or {}
                local updated,found={},false
                for _,picked in ipairs(current) do
                    if picked==id then found=true else updated[#updated+1]=picked end
                end
                if not found then updated[#updated+1]=id end
                groups[panel.SelectorIndex]=updated
                stagedSuccessfully=true
            end
        end
    elseif panel.Kind=="PassivePairAdd" then
        if not onStageOther then
            passiveFeedback="Two-passive feat staging callback unavailable."
        else
            local ok,success,message=pcall(onStageOther,currentLevel,
                {Kind="HB_PassiveFeatAdd",FeatId=panel.FeatId},id)
            passiveFeedback=ok and tostring(message or (success and "Feat choice staged." or "Choice rejected."))
                or ("Feat choice callback error: "..tostring(success))
            if ok and success then
                stagedSuccessfully=true
                local selected=previewPairFeatIds[currentLevel]==panel.FeatId
                    and (previewPairChoices[currentLevel] or {}) or {}
                local updated,removed={},false
                for _,picked in ipairs(selected) do
                    if tostring(picked)==id then removed=true
                    else updated[#updated+1]=picked end
                end
                if not removed and #updated<2 then updated[#updated+1]=id end
                previewPairChoices[currentLevel]=updated
                previewPairFeatIds[currentLevel]=panel.FeatId
                Log("NATIVE_PASSIVE_PAIR_ACCEPT level="..currentLevel
                    .." feat="..tostring(panel.FeatId)
                    .." ids="..table.concat(updated,","))
            else
                Log("NATIVE_PASSIVE_PAIR_REJECT level="..currentLevel
                    .." feat="..tostring(panel.FeatId)
                    .." id="..id.." reason="..passiveFeedback)
            end
        end
    elseif panel.Kind=="MultifacetedAdd" then
        if not onStageOther then
            passiveFeedback="New Multifaceted choice callback is unavailable."
        else
            local ok,success,message=pcall(onStageOther,currentLevel,
                {Kind="HB_MultifacetedAdd",Section=panel.Section},id)
            passiveFeedback=ok and tostring(message or (success and "Choice updated." or "Choice rejected."))
                or ("Multifaceted selection error: "..tostring(success))
            if ok and success then
                local levelChoices=HB_MULTIFACETED_NEW.Preview[currentLevel] or {}
                local remaining,had={},false
                for _,value in ipairs(levelChoices[panel.Section] or {}) do
                    if value==id then had=true else remaining[#remaining+1]=value end
                end
                if not had then remaining[#remaining+1]=id end
                levelChoices[panel.Section]=remaining
                HB_MULTIFACETED_NEW.Preview[currentLevel]=levelChoices
                stagedSuccessfully=true
                Log("NATIVE_MULTIFACETED_ADD_CHOICE level="..currentLevel
                    .." group="..tostring(panel.Section).." selected="..table.concat(remaining,","))
            end
        end
    elseif panel.Kind=="ElementAdd" then
        -- This route must stage into the SAME source-feat transaction that
        -- selected Elemental Adept. It is not a normal passive replacement.
        Log("NATIVE_ELEMENTAL_CLICK level="..currentLevel
            .." tab="..passiveGroupIndex.." passive="..tostring(id)
            .." previous="..table.concat(previewNewElements[currentLevel] or {},","))
        if not onStageOther then
            passiveFeedback="Elemental Adept selection callback unavailable."
            Log("NATIVE_ELEMENTAL_REJECT callback_missing")
        else
            local ok,success,message=pcall(onStageOther,currentLevel,
                {Kind="HB_ElementalAdeptAdd"},id)
            passiveFeedback=ok and tostring(message or (success and "Element updated." or "Element rejected."))
                or ("Elemental choice staging error: "..tostring(success))
            if ok and success then
                stagedSuccessfully=true
                local selections=previewNewElements[currentLevel] or {}
                local updated={}
                local removed=false
                for _,selected in ipairs(selections) do
                    if tostring(selected)==id then removed=true else updated[#updated+1]=selected end
                end
                if not removed and #updated<2 then updated[#updated+1]=id end
                previewNewElements[currentLevel]=updated
                Log("NATIVE_ELEMENTAL_ACCEPT level="..currentLevel
                    .." choices="..table.concat(updated,",")
                    .." feedback="..passiveFeedback)
            else
                Log("NATIVE_ELEMENTAL_REJECT level="..currentLevel
                    .." callbackOK="..tostring(ok)
                    .." success="..tostring(success)
                    .." feedback="..passiveFeedback)
            end
        end
    elseif panel.Kind=="Resource" then
        -- A resource tab has exactly one historical slot. Do not attempt a
        -- one-click exclusive swap: the old checked item lives on a different
        -- Noesis proxy, whose retained reference can expire at any moment.
        -- Match the working passive editor: uncheck the current resource first,
        -- then select an available replacement. Only the second click stages.
        local effective=tostring(CurrentEffectivePicks(panel)[1] or "")
        if armedFrom==effective and id==effective then
            armedFrom=nil
            passiveFeedback="Selection unchanged."
        elseif armedFrom==nil then
            if id==effective then
                armedFrom=effective
                passiveFeedback="Choose an Extra Resource replacement."
                Log("NATIVE_RESOURCE_UNCHECK level="..currentLevel.." id="..id)
            else
                passiveFeedback="First uncheck the current Extra Resource, then select its replacement."
            end
        elseif id==effective then
            armedFrom=nil
            passiveFeedback="Selection unchanged."
        elseif not onStageResource then
            passiveFeedback="Extra Resource staging unavailable."
        else
            local ok,success,message=pcall(onStageResource,currentLevel,id)
            passiveFeedback=ok and tostring(message or (success and "Resource staged." or "Resource rejected."))
                or ("Resource staging error: "..tostring(success))
            if ok and success then
                stagedSuccessfully=true
                local original=tostring(panel.CurrentIds[1])
                if id==original then
                    previewResources[currentLevel]=nil
                else
                    previewResources[currentLevel]=id
                end
                armedFrom=nil
                Log("Historical resource staged at level "..currentLevel..": "..id)
            end
        end
    elseif panel.Kind=="MultifacetedSkills" then
        local effective=CurrentEffectivePicks(panel)
        if panel.GroupedLevelOne and panel.GroupKind=="Expertise"
            and not HB_MULTIFACETED_UI.LevelOneExpertiseEligible(panel,id) then
            passiveFeedback="Choose a skill proficiency before selecting its Expertise."
            Log("NATIVE_L1_EXPERTISE_BLOCKED level="..tostring(currentLevel)
                .." choice="..tostring(id))
            return false
        end
        local activeSlot,pendingSlot=nil,nil
        -- Resolve by historical slot, not by the item's current visual Value.
        -- The ordinary Noesis checkbox command can arrive after it has
        -- toggled Value, and several skill rows share a single native list.
        for slot,skill in ipairs(effective) do
            if tostring(skill)==tostring(id) then
                local source=(panel.Rows or {})[slot]
                local from=source and tostring(source.From or "") or ""
                if source and HB_MULTIFACETED_UI.IsUnchecked(panel,source) then
                    pendingSlot=from
                else
                    activeSlot=from
                end
                break
            end
        end
        if pendingSlot then
            -- Clicking an empty/unfilled choice again rechecks that skill.
            HB_MULTIFACETED_UI.Set(pendingSlot,false,panel)
            armedFrom=HB_MULTIFACETED_UI.First(panel)
            passiveFeedback="Skill restored: "..row.Name.."."
            Log("NATIVE_MULTIFACETED_SKILL_RECHECK level="..currentLevel
                .." original="..pendingSlot.." choice="..tostring(id))
        elseif activeSlot then
            -- Multiple independent slots may be unchecked before any are
            -- filled, exactly like an ordinary four-choice native selector.
            HB_MULTIFACETED_UI.Set(activeSlot,true,panel)
            armedFrom=HB_MULTIFACETED_UI.First(panel)
            passiveFeedback="Skill unchecked: "..row.Name..". Select a replacement."
            Log("NATIVE_MULTIFACETED_SKILL_UNCHECK level="..currentLevel
                .." original="..activeSlot.." choice="..tostring(id))
        elseif not HB_MULTIFACETED_UI.First(panel) then
            passiveFeedback="Uncheck one or more of your four skills before choosing replacements."
        else
            -- Fill the first unchecked historical slot in its original
            -- selection order. Its row/slot ID remains the same for replay.
            local original=HB_MULTIFACETED_UI.First(panel)
            local originalRow=nil
            for _,source in ipairs(panel.Rows or {}) do
                if tostring(source.From)==original then originalRow=source;break end
            end
            if not originalRow then
                passiveFeedback="Original Multifaceted skill slot could not be found."
                HB_MULTIFACETED_UI.Clear()
                armedFrom=nil
            else
                local conflict=LocalChoiceConflict({Kind="Other",Other=originalRow},id)
                if conflict then
                    passiveFeedback=conflict
                elseif not onStageOther then
                    passiveFeedback="Historical skill staging callback unavailable."
                else
                    local ok,success,message=pcall(onStageOther,currentLevel,originalRow,id)
                    passiveFeedback=ok and tostring(message or (success and "Skill staged." or "Choice rejected."))
                        or ("Multifaceted staging error: "..tostring(success))
                    if ok and success then
                        previewOther[currentLevel]=previewOther[currentLevel] or {}
                        previewOther[currentLevel][ChoiceKey(originalRow)]=
                            id==tostring(originalRow.From) and nil or id
                        HB_MULTIFACETED_UI.Set(original,false,panel)
                        armedFrom=HB_MULTIFACETED_UI.First(panel)
                        stagedSuccessfully=true
                        if panel.GroupedLevelOne and panel.GroupKind=="Skill" then
                            -- Proficiency edits invalidate Expertise allocations.
                            -- Undo pending Expertise replacements in the real
                            -- client stage store and require both slots to be
                            -- reselected. Reopening a tab must not resurrect
                            -- the original now-ineligible checkmarks.
                            local cleared=0
                            for _,expertisePanel in ipairs(AllPanels()) do
                                if expertisePanel.GroupedLevelOne
                                    and expertisePanel.GroupKind=="Expertise"
                                    and expertisePanel.ProficiencyGroup
                                    and expertisePanel.ProficiencyGroup.GroupKey==panel.GroupKey then
                                    for _,expertRow in ipairs(expertisePanel.Rows or {}) do
                                        local key=ChoiceKey(expertRow)
                                        if (previewOther[currentLevel] or {})[key] then
                                            local undone,success,why=pcall(onStageOther,
                                                currentLevel,expertRow,tostring(expertRow.From))
                                            if undone and success then
                                                previewOther[currentLevel][key]=nil
                                            else
                                                passiveFeedback="Expertise must be reset before editing skills: "
                                                    ..tostring(undone and why or success)
                                                Log("NATIVE_L1_EXPERTISE_RESET_FAILED "..passiveFeedback)
                                                return false
                                            end
                                        end
                                        HB_MULTIFACETED_UI.Set(expertRow.From,true,expertisePanel)
                                        cleared=cleared+1
                                    end
                                end
                            end
                            Log("NATIVE_L1_EXPERTISE_RESET level="..tostring(currentLevel)
                                .." slots="..tostring(cleared))
                        end
                        Log("NATIVE_MULTIFACETED_SKILL_STAGE level="..tostring(currentLevel)
                            .." original="..tostring(originalRow.From).." to="..tostring(id)
                            .." slot="..tostring(originalRow.SlotIndex)
                            .." nextUnfilled="..tostring(armedFrom))
                    end
                end
            end
        end
    elseif panel.Kind=="Other" then
        local conflict=LocalChoiceConflict(panel,id)
        if conflict then
            passiveFeedback=conflict
            Log("NATIVE_HISTORICAL_PREFLIGHT_BLOCK level="..currentLevel
                .." kind="..tostring(panel.Other.Kind).." option="..id
                .." reason="..conflict)
        elseif not onStageOther then
            passiveFeedback="Choice staging unavailable."
        else
            local ok,success,message=pcall(onStageOther,currentLevel,panel.Other,id)
            passiveFeedback=ok and tostring(message or (success and "Choice staged." or "Choice rejected."))
                or ("Choice staging error: "..tostring(success))
            if ok and success then
                stagedSuccessfully=true
                previewOther[currentLevel]=previewOther[currentLevel] or {}
                local key=ChoiceKey(panel.Other)
                previewOther[currentLevel][key]=id==tostring(panel.Other.From) and nil or id
                -- Manually selecting even the original spell fills a cleared
                -- slot; it is not an automatic restoration from a L1 change.
                if panel.Other.Kind=="Spell" or panel.Other.Kind=="Cantrip" then
                    local cleared=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
                    if cleared[currentLevel] then cleared[currentLevel][key]=nil end
                end
                if panel.Other.Kind=="Feat" then
                    -- Clear any pending historical edits OWNED by the
                    -- original complex feat when switching it away. Its
                    -- selector tab vanishes, so retaining invisible staging
                    -- would make a later Confirm inconsistent or unsafe.
                    if id~=tostring(panel.Other.From or "") then
                        local row=snapshot[currentLevel] or {}
                        local levels=row.LevelChoices or {}
                        local oldStaged=row._HB_PreviewStaged or {}
                        for _,group in ipairs(levels.EditablePassiveGroups or {}) do
                            if group.FeatOwnerVerified and
                                tostring(group.FeatOwnerId or "")==tostring(panel.Other.From or "") then
                                for _,picked in ipairs(group.Picked or {}) do
                                    local groupKey=tostring(group.SelectorId).."|"..
                                        tostring(group.PassiveList).."|"..tostring(picked)
                                    oldStaged[groupKey]=nil
                                end
                            end
                        end
                    end
                    -- A different feat at the same level has a different
                    -- selector and an independent pending choice transaction.
                    -- Never carry the previous feat's two picks across.
                    previewNewElements[currentLevel]={}
                    HB_MULTIFACETED_NEW.Accord.Preview[currentLevel]={}
                    HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel]=nil
                    HB_MULTIFACETED_NEW.Preview[currentLevel]={}
                    previewPairChoices[currentLevel]={}
                    previewGenericChoices[currentLevel]={}
                    previewPairFeatIds[currentLevel]=HB_PASSIVE_PAIR_FEATS[id] and id or nil
                    Log("NATIVE_FEAT_SELECTOR_RESET level="..currentLevel
                        .." feat="..tostring(id))
                end
                Log("Historical "..tostring(panel.Other.Kind).." staged at level "..currentLevel..": "..id)
            end
        end
    end
    -- Native checkboxes are updated in place by SyncNativeHistoricalCheckmarks.
    -- Do NOT queue a fresh overlay DataContext from native click handling:
    -- the queued tick could execute just after the native menu is restored,
    -- destroying a live Noesis ViewModel while its controls are changing.
    if stagedSuccessfully and currentLevel>=2
        and HB_NATIVE_L1_SLIDER.RefreshPassiveDuplicateLevels then
        HB_NATIVE_L1_SLIDER.RefreshPassiveDuplicateLevels()
    end
    if not nativePilotActive and not nativePilotWrapping then
        queuedRefresh=true
    end
    return stagedSuccessfully
end
-- This count reflects changes staged during the currently open native preview,
-- including changes staged earlier in Edit Build. The authoritative pending list
-- remains in the Edit Build review popup.
local function LocalHistoricalStageCount()
    local count=0
    for _,level in pairs(snapshot) do
        if type(level)=="table" then
            for _,replacement in pairs(level._HB_PreviewStaged or {}) do
                if replacement then count=count+1 end
            end
        end
    end
    for _,value in pairs(previewResources) do
        if value then count=count+1 end
    end
    for _,rows in pairs(previewOther) do
        if type(rows)=="table" then
            for _,value in pairs(rows) do
                if value then count=count+1 end
            end
        end
    end
    return count
end

-- Count changes in the CURRENT selector rather than the entire historical
-- build. Multiple separate Maneuvers and Honed Techniques groups can exist at
-- the same character level; only the group's own original slots qualify.
local function StagedCountForPanel(panel)
    if not panel then return 0 end
    local stagedLevel=(snapshot[currentLevel] or {})._HB_PreviewStaged or {}
    if panel.Kind=="Passive" and panel.Group then
        local count=0
        local group=panel.Group
        for _,original in ipairs(group.Picked or {}) do
            local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..tostring(original)
            if stagedLevel[key] then count=count+1 end
        end
        return count
    elseif panel.Kind=="Resource" then
        return (panel.Editable and previewResources[currentLevel]) and 1 or 0
    elseif panel.Kind=="AccordRecorded" then
        local edits=previewOther[currentLevel] or {}
        local n=0
        for _,row in ipairs(panel.Rows or {}) do
            if edits[ChoiceKey(row)] then n=n+1 end
        end
        return n
    elseif panel.Kind=="MultifacetedSkills" then
        local edits=previewOther[currentLevel] or {}
        local n=0
        for _,row in ipairs(panel.Rows or {}) do
            if edits[ChoiceKey(row)] then n=n+1 end
        end
        return n
    elseif panel.Kind=="Other" and panel.Other then
        local edited=previewOther[currentLevel] or {}
        return edited[ChoiceKey(panel.Other)] and 1 or 0
    end
    return 0
end

-- An undo always routes through the SAME validated stage callbacks as an edit.
-- Never clear only the preview tables: the Edit Build backend would otherwise
-- retain the change and apply it later despite the native UI showing 'original'.
local function RevertCurrentHistoricalGroup()
    local panel=ActivePanel()
    if not panel then return false,"No recorded historical choice to revert." end
    local level=currentLevel
    local reverted,issues=0,{}
    local function Attempt(callback,...)
        if type(callback)~="function" then
            issues[#issues+1]="Editor staging callback is unavailable."
            return false
        end
        local called,ok,message=pcall(callback,...)
        if not called or not ok then
            issues[#issues+1]=tostring(message or ok or "staging error")
            return false
        end
        reverted=reverted+1
        return true
    end
    if panel.Kind=="Passive" and panel.Group then
        local group=panel.Group
        local saved=(snapshot[level] or {})._HB_PreviewStaged or {}
        for _,original in ipairs(group.Picked or {}) do
            local from=tostring(original)
            local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..from
            if saved[key] and Attempt(onStagePassive,level,group.SelectorId,group.PassiveList,from,from) then
                saved[key]=nil
            end
        end
    elseif panel.Kind=="Resource" and panel.Editable and previewResources[level] then
        local original=tostring((panel.CurrentIds or {})[1] or "")
        if original~="" and Attempt(onStageResource,level,original) then
            previewResources[level]=nil
        end
    elseif panel.Kind=="AccordRecorded" then
        local previous=previewOther[level] or {}
        for _,row in ipairs(panel.Rows or {}) do
            local key=ChoiceKey(row)
            if previous[key] and Attempt(onStageOther,level,row,tostring(row.From)) then
                previous[key]=nil
            end
        end
        HB_MULTIFACETED_NEW.Accord.Unchecked[level]=nil
    elseif panel.Kind=="MultifacetedSkills" then
        local previous=previewOther[level] or {}
        for _,row in ipairs(panel.Rows or {}) do
            local key=ChoiceKey(row)
            if previous[key] and Attempt(onStageOther,level,row,tostring(row.From)) then
                previous[key]=nil
            end
        end
    elseif panel.Kind=="Other" and panel.Other then
        local previous=previewOther[level] or {}
        local key=ChoiceKey(panel.Other)
        if previous[key] and Attempt(onStageOther,level,panel.Other,tostring(panel.Other.From)) then
            previous[key]=nil
        end
    end
    armedFrom=nil
    HB_MULTIFACETED_UI.Clear()
    if #issues>0 then
        return false,("Reverted %d edit(s); %d rejected: %s"):format(reverted,#issues,table.concat(issues,"; "))
    end
    if reverted==0 then return true,"No staged changes in this group; selection reset." end
    return true,("Reverted %d staged edit(s) in %s."):format(reverted,tostring(panel.Title))
end

local function HistoricalSpellRankClient(id)
    if not Ext.Stats or not Ext.Stats.Get then return nil end
    local ok,stat=pcall(Ext.Stats.Get,tostring(id or ""))
    if not ok or not stat then return nil end
    local rank=tonumber(Read(stat,"Level") or Read(stat,"SpellLevel"))
    if rank and rank>=0 and rank<=9 and rank==math.floor(rank) then return rank end
    return nil
end
local function CanStageNativeSpell(panel)
    return panel and panel.Editable==true and IsRecordedSpellPanel(panel)
        and (panel.Kind=="AccordAdd" or panel.Kind=="AccordRecorded"
            or (panel.Kind=="Other" and panel.Other) or panel.Kind=="GenericSpellAdd"
            or panel.Kind=="GenericSpellRecorded" or panel.Kind=="ClassSpellGroup")
        and onStageOther~=nil
end

local function CurrentNativeModeNotice(panel)
    if not panel then
        local choices=(snapshot[currentLevel] or {}).LevelChoices or {}
        if choices.HistoryAvailable==false then
            return "Level-up history unavailable · no historical edits can be safely staged"
        end
        return "No selectable choices were recorded at this level."
    end
    if panel.Kind=="ObservedSpell" then
        return IsCurrentSpellbookObservation(panel)
            and "Current spellbook · acquisition level unknown · view only"
            or "Progression spells · observed game records · view only (not proven selections)"
    end
    if not panel.Editable then return "Recorded choices are view-only at this level." end
    if nativeFeatPreview and IsRecordedFeatPanel(panel) then
        return "Genuine feat preview · eligibility unverified · view only"
    elseif IsNativeSpellPreview(panel) then
        return "Recorded spell choice · native selector · server checks rank and provenance"
    elseif panel.Kind=="MultifacetedSkills" then
        return "Choose four distinct feat skills. Click any checked skill to uncheck it; click it again to restore it, or choose new skills to fill the empty slots."
    elseif panel.Kind=="AccordAdd" then
        return "Choose two different cantrips for the new Accord feat. Checked cantrips can be removed."
    elseif panel.Kind=="AccordRecorded" then
        return "Edit both Accord cantrips in one native selector. Remove selected cantrips, then fill both slots."
    elseif panel.Kind=="MultifacetedAdd" then
        return "Select the new Multifaceted archetype, trait and four skills."
    elseif panel.Kind=="GenericPassiveAdd" then
        return "Choose all secondary passives required by the new feat."
    elseif panel.Kind=="GenericSpellAdd" then
        return "Choose the spells granted by the selected feat."
    elseif panel.Kind=="PassivePairAdd" then
        return "Select two different passives for the new feat."
    elseif panel.Kind=="ElementAdd" then
        return "Select two different elements for the new Elemental Adept feat."
    elseif panel.Kind=="Passive" then
        return "Select a checked choice, then its replacement."
    elseif IsRecordedFeatPanel(panel) then
        return "Feat edits are staged for server validation; some choices may be rejected."
    elseif IsRecordedSpellPanel(panel) then
        return "Spell edits are staged for server validation; unknown choices may be rejected."
    end
    return "Choose a replacement to stage a historical edit."
end

local function UpdateVM()
    local vm = CurrentVM()
    if not vm then return end
    -- The old full-screen historical editor was retired. Even if a native
    -- Noesis bind fails, never expose its obsolete developer/fallback panel.
    vm.HB_NativeVisible = false
    vm.HB_NativeMaxLevel = maximum
    vm.HB_NativeSelectedLevel = currentLevel
    vm.HB_NativeTitle = HB_NATIVE_L1_SLIDER.FullRespecChanged
        and "Class/Subclass Changed - Switching to Full Respec"
        or ("Level: %d/%d"):format(currentLevel, maximum)
    vm.HB_NativeSliderEnabled = not HB_NATIVE_L1_SLIDER.FullRespecChanged
    vm.HB_NativeFullRespecChanged = HB_NATIVE_L1_SLIDER.FullRespecChanged
    vm.HB_NativeNormalLevelLabelVisible = not HB_NATIVE_L1_SLIDER.FullRespecChanged
    local levelChoices=(snapshot[currentLevel] or {}).LevelChoices or {}
    local cls=levelChoices.Class and Label(levelChoices.Class) or "Not recorded"
    vm.HB_NativeLevelSummary="Recorded class at this level: "..tostring(cls)
    if levelChoices.HistoryAvailable==false then
        local present={}
        for _,entry in ipairs(levelChoices.CurrentClasses or {}) do
            present[#present+1]=Label(entry.Name).." "..tostring(entry.Level or "?")
        end
        vm.HB_NativeLevelSummary="Level-up history unavailable"
            ..(#present>0 and (" · Current build: "..table.concat(present,", ")) or "")
    end
    vm.HB_NativeChoices = DescribeLevel(currentLevel)
    vm.HB_NativeHelp = "Historical selections are staged here; apply them together in Edit Build."
    vm.HB_NativeReadout = nativeReadout
    vm.HB_NativeHostTestActive = nativePilotActive or HB_NATIVE_L1_SLIDER.Screen
        or HB_NATIVE_L1_SLIDER.Pending or (previewOpen and nativeCancelAwaitingDecision)
    vm.HB_NativeLevelOneChoicesPending = HB_NATIVE_L1_SLIDER.NativeLevelOneChoicesPending()
    local conflictLevel=HB_NATIVE_L1_SLIDER.FirstPendingSpellLevel()
    -- One warning for every recorded choice family, including maneuvers and
    -- metamagic. Multiple unresolved levels share the same concise message.
    vm.HB_NativeLevelOnePendingWarning = conflictLevel
        and "Choices Pending at Later Level" or ""
    vm.HB_NativeCommitErrorVisible = (nativeCommitError~="")
    vm.HB_NativeCommitError = nativeCommitError
    vm.HB_NativeHostTestReport = nativePilotReport
    vm.HB_PassiveFeedback = passiveFeedback
    local panel,panels=ActivePanel()
    local countStaged=LocalHistoricalStageCount()
    vm.HB_NativePendingSummary = ("%d pending edits · Review before applying"):format(countStaged)
    vm.HB_NativeCanRevertGroup=(StagedCountForPanel(panel)>0 or armedFrom~=nil)
    vm.HB_NativeModeNotice = CurrentNativeModeNotice(panel)
    vm.HB_NativeCanPreviousLevel = currentLevel>1
    vm.HB_NativeCanNextLevel = currentLevel<maximum
    vm.HB_NativeCanPreviousChoiceLevel = NearestChoiceLevel(-1)~=nil
    vm.HB_NativeCanNextChoiceLevel = NearestChoiceLevel(1)~=nil
    vm.HB_NativeChoiceLevelMap = ChoiceLevelMap()
    vm.HB_NativeFeatPreviewAvailable=nativePilotActive and IsRecordedFeatPanel(panel)
    vm.HB_NativeFeatPreviewText=nativeFeatPreview and "Use Tested Checkbox Menu" or "Preview BG3 Feat Menu"
    -- Exact CCLevelUp spell choices render directly in the original BG3
    -- native spell selector. Unverified spellbook/progression observations
    -- remain read-only; no developer-only activation controls are displayed.
    vm.HB_NativeSpellPreviewAvailable=false
    vm.HB_NativeSpellPreviewText=""
    vm.HB_NativeSpellEditAvailable=false
    vm.HB_NativeSpellEditText=""
    local count=#panels
    vm.HB_NativeGroupNavVisible=false -- every group is a native left-side subtab
    vm.HB_PassiveGroupName=panel and (panel.Title.." ("..passiveGroupIndex.."/"..count..")")
        or (levelChoices.HistoryAvailable==false and "Original level-up history unavailable"
            or "No editable historical selections at this level")
    vm.HB_PassiveCanPrevious=count>1 and passiveGroupIndex>1
    vm.HB_PassiveCanNext=count>1 and passiveGroupIndex<count
    vm.HB_NativePanelTitle=panel and panel.Title
        or (levelChoices.HistoryAvailable==false and "History unavailable" or "No editable selections")
end
local function Register()
    if vmTypeRegistered then return true end
    if not Ext.UI or not Ext.UI.RegisterType then return false end
    Ext.UI.RegisterType(ROW_TYPE, {
        Name={Type="String"},PassiveId={Type="String"},Mark={Type="String"},Detail={Type="String"}
    })
    Ext.UI.RegisterType(TYPE, {
        HB_NativeVisible={Type="Bool", Notify=true},
        HB_NativeSelectedLevel={Type="Double", Notify=true},
        HB_NativeMaxLevel={Type="Double", Notify=true},
        HB_NativeTitle={Type="String", Notify=true},
        HB_NativeSliderEnabled={Type="Bool", Notify=true},
        HB_NativeFullRespecChanged={Type="Bool", Notify=true},
        HB_NativeNormalLevelLabelVisible={Type="Bool", Notify=true},
        HB_NativeLevelSummary={Type="String", Notify=true},
        HB_NativePendingSummary={Type="String", Notify=true},
        HB_NativeCanRevertGroup={Type="Bool", Notify=true},
        HB_NativeRevertGroup={Type="Command"},
        HB_NativeModeNotice={Type="String", Notify=true},
        HB_NativeCanPreviousLevel={Type="Bool", Notify=true},
        HB_NativeCanNextLevel={Type="Bool", Notify=true},
        HB_NativeCanPreviousChoiceLevel={Type="Bool", Notify=true},
        HB_NativeCanNextChoiceLevel={Type="Bool", Notify=true},
        HB_NativeChoiceLevelMap={Type="String", Notify=true},
        HB_NativePreviousLevel={Type="Command"},
        HB_NativeNextLevel={Type="Command"},
        HB_NativePreviousChoiceLevel={Type="Command"},
        HB_NativeNextChoiceLevel={Type="Command"},
        HB_NativeShowHelp={Type="Bool", Notify=true},
        HB_NativeHelpToggle={Type="Command"},
        HB_NativeChoices={Type="String", Notify=true},
        HB_NativeHelp={Type="String", Notify=true},
        HB_NativePanelTitle={Type="String", Notify=true},
        HB_NativeReadout={Type="String", Notify=true},
        HB_NativeOriginalContext={Type="Object"},
        HB_NativeTemplatedTarget={Type="Object"},
        HB_NativeOriginalTemplate={Type="Object"},
        HB_NativeTemplateWasEmpty={Type="Bool"},
        HB_NativeHostTestActive={Type="Bool", Notify=true},
        HB_NativeLevelOneChoicesPending={Type="Bool", Notify=true},
        HB_NativeLevelOnePendingWarning={Type="String", Notify=true},
        HB_NativePendingConfirmBlock={Type="Command"},
        HB_NativeHostTestReport={Type="String", Notify=true},
        HB_NativeHostTestStart={Type="Command"},
        HB_NativeHistoricalStart={Type="Command"},
        HB_NativeHostTestStop={Type="Command"},
        HB_NativeGroupNavVisible={Type="Bool",Notify=true},
        HB_NativeCommitErrorVisible={Type="Bool",Notify=true},
        HB_NativeCommitError={Type="String",Notify=true},
        HB_NativeReview={Type="Command"},
        HB_NativeFeatPreviewAvailable={Type="Bool", Notify=true},
        HB_NativeFeatPreviewText={Type="String", Notify=true},
        HB_NativeFeatPreviewToggle={Type="Command"},
        HB_NativeSpellPreviewAvailable={Type="Bool", Notify=true},
        HB_NativeSpellPreviewText={Type="String", Notify=true},
        HB_NativeSpellPreviewToggle={Type="Command"},
        HB_NativeSpellEditAvailable={Type="Bool",Notify=true},
        HB_NativeSpellEditText={Type="String",Notify=true},
        HB_NativeSpellEditToggle={Type="Command"},
        HB_PassiveAvailable={Type="Bool", Notify=true},
        HB_PassiveGroupName={Type="String", Notify=true},
        HB_PassiveCanPrevious={Type="Bool", Notify=true},
        HB_PassiveCanNext={Type="Bool", Notify=true},
        HB_PassiveGuide={Type="String", Notify=true},
        HB_PassiveFeedback={Type="String", Notify=true},
        HB_PassiveRows={Type="Collection"},
        HB_PassiveSelectedIndex={Type="Int32", Notify=true},
        HB_PassiveGroupPrevious={Type="Command"},
        HB_PassiveGroupNext={Type="Command"},
        HB_PassiveChoiceClicked={Type="Command"},
        HB_PassiveChooseSelected={Type="Command"},
        HB_NativeProbe={Type="Command"},
        HB_NativeSliderChanged={Type="Command"},
        HB_NativeBack={Type="Command"},
        HB_NativeEdit={Type="Command"},
    })
    vmTypeRegistered = true
    return true
end
local CaptureNative
local function RequestNativeHistoricalRefresh(reason)
    if not previewOpen then return end
    if nativePilotActive and nativePilotMode=="historical" then
        -- Keep the native menu alive at every level, including empty levels.
        queuedRefresh=false
        nativePilotReport="Switching historical "..tostring(reason or "selection").."..."
        UpdateVM()
        nativeRefreshQueued=true
        if not nativePilotWrapping and NativePilotStart then NativePilotStart(true) end
    elseif not nativePilotWrapping then
        queuedRefresh=true
    end
end

local function Bind()
    local node = UIWidget()
    if not node then return false end
    local existing = Read(node, "DataContext")
    if existing then
        local ok, ready = pcall(function() return existing.HB_NativeMaxLevel end)
        if ok and ready and not queuedRefresh then return true end
    end
    if not Register() then return false end
    local vm = Ext.UI.Instantiate("se::" .. TYPE)
    vm.HB_NativeVisible = false
    vm.HB_NativeMaxLevel = maximum
    vm.HB_NativeSelectedLevel = currentLevel
    vm.HB_NativeShowHelp = false
    vm.HB_NativeCanPreviousLevel = currentLevel>1
    vm.HB_NativeCanNextLevel = currentLevel<maximum
    vm.HB_NativeCanPreviousChoiceLevel = NearestChoiceLevel(-1)~=nil
    vm.HB_NativeCanNextChoiceLevel = NearestChoiceLevel(1)~=nil
    vm.HB_NativeChoiceLevelMap = ChoiceLevelMap()
    vm.HB_NativePendingSummary = "0 pending edits · Review before applying"
    vm.HB_NativeCanRevertGroup = false
    vm.HB_NativeModeNotice = "Recorded historical selections"
    vm.HB_NativeTitle = "Level: 1/1"
    vm.HB_NativeSliderEnabled = true
    vm.HB_NativeFullRespecChanged = false
    vm.HB_NativeNormalLevelLabelVisible = true
    vm.HB_NativeLevelSummary=""
    vm.HB_NativeChoices = ""
    vm.HB_NativeHelp = ""
    vm.HB_NativePanelTitle = "Class Progression"
    vm.HB_NativeReadout = nativeReadout
    vm.HB_NativeHostTestActive = nativePilotActive or HB_NATIVE_L1_SLIDER.Screen
        or HB_NATIVE_L1_SLIDER.Pending or (previewOpen and nativeCancelAwaitingDecision)
    vm.HB_NativeLevelOneChoicesPending=false
    vm.HB_NativeLevelOnePendingWarning=""
    vm.HB_NativeGroupNavVisible=false
    vm.HB_NativeCommitErrorVisible=false
    vm.HB_NativeCommitError=""
    vm.HB_NativeHostTestReport = nativePilotReport
    vm.HB_PassiveFeedback = passiveFeedback
    vm.HB_PassiveSelectedIndex = -1
    BuildPassiveRows(vm)
    -- The overlay is a real, active Noesis button with a deliberately inert
    -- command. Mouse clicks above BG3's vanilla Confirm go here, not to its
    -- game-owned FinishCreating command; historical selections remain intact.
    vm.HB_NativePendingConfirmBlock:SetHandler(function()
        if HB_NATIVE_L1_SLIDER.NativeLevelOneChoicesPending() then
            Log("NATIVE_L1_CONFIRM_OVERLAY_BLOCKED level="
                ..tostring(HB_NATIVE_L1_SLIDER.FirstPendingSpellLevel() or "unknown"))
        end
    end)
    vm.HB_PassiveGroupPrevious:SetHandler(function()
        if not previewOpen then return end
        if passiveGroupIndex<=1 then return end
        passiveGroupIndex=passiveGroupIndex-1
        armedFrom=nil;passiveFeedback=""
        if currentLevel~=1 then HB_MULTIFACETED_UI.Clear() end
        nativeFeatPreview=false;nativeSpellPreview=false;nativeSpellAllowStage=false
        RequestNativeHistoricalRefresh("previous group")
    end)
    vm.HB_PassiveGroupNext:SetHandler(function()
        if not previewOpen then return end
        local _,panels=ActivePanel()
        if passiveGroupIndex>=#panels then return end
        passiveGroupIndex=passiveGroupIndex+1
        armedFrom=nil;passiveFeedback=""
        if currentLevel~=1 then HB_MULTIFACETED_UI.Clear() end
        nativeFeatPreview=false;nativeSpellPreview=false;nativeSpellAllowStage=false
        RequestNativeHistoricalRefresh("next group")
    end)
    local function PickCurrentRow()
        if suppressSelect then return end
        local live=CurrentVM()
        local idx=tonumber(Read(live,"HB_PassiveSelectedIndex"))
        if not idx or idx<0 then return end
        StageChoice(idx+1)
    end
    vm.HB_PassiveChoiceClicked:SetHandler(PickCurrentRow)
    vm.HB_PassiveChooseSelected:SetHandler(PickCurrentRow)
    local function ChangeNativeLevel(delta)
        if not previewOpen or nativePilotWrapping or nativeCommitPending then return end
        local target=math.max(1,math.min(maximum,currentLevel+delta))
        if target==currentLevel then return end
        -- The arrows / jump buttons are a second entry path into the same
        -- slider. NEVER directly increment currentLevel: that would bypass
        -- the native L1 backup/restore transaction and leave the historical
        -- wrapper rendering level one.
        local holder=CurrentVM()
        if not holder or not ApplyHistoricalSliderFromModel then return end
        holder.HB_NativeSelectedLevel=target
        local moved=ApplyHistoricalSliderFromModel("level navigation command")
        if not moved then
            holder.HB_NativeSelectedLevel=currentLevel
            UpdateVM()
        end
    end
    vm.HB_NativePreviousLevel:SetHandler(function() ChangeNativeLevel(-1) end)
    vm.HB_NativeNextLevel:SetHandler(function() ChangeNativeLevel(1) end)
    vm.HB_NativePreviousChoiceLevel:SetHandler(function()
        local target=NearestChoiceLevel(-1)
        if target then
            Log("NATIVE_CHOICE_JUMP from="..currentLevel.." to="..target.." direction=previous")
            ChangeNativeLevel(target-currentLevel)
        end
    end)
    vm.HB_NativeNextChoiceLevel:SetHandler(function()
        local target=NearestChoiceLevel(1)
        if target then
            Log("NATIVE_CHOICE_JUMP from="..currentLevel.." to="..target.." direction=next")
            ChangeNativeLevel(target-currentLevel)
        end
    end)
    vm.HB_NativeRevertGroup:SetHandler(function()
        if not previewOpen or nativePilotWrapping then return end
        local didRevert,notice=RevertCurrentHistoricalGroup()
        passiveFeedback=notice
        nativePilotReport=notice
        Log("NATIVE_HISTORICAL_REVERT level="..tostring(currentLevel)
            .." group="..tostring((ActivePanel() or {}).Title)
            .." successful="..tostring(didRevert).." message="..tostring(notice))
        if nativePilotActive and nativePilotMode=="historical" then
            -- A hot refresh updates only HB's temporary models; the original
            -- game's character/respec ViewModel remains untouched.
            RequestNativeHistoricalRefresh("reverted group")
        else
            queuedRefresh=true
        end
        UpdateVM()
    end)
    vm.HB_NativeHelpToggle:SetHandler(function()
        local holder=CurrentVM()
        if holder then holder.HB_NativeShowHelp=not (Read(holder,"HB_NativeShowHelp")==true) end
    end)
    vm.HB_NativeSliderChanged:SetHandler(function()
        -- A cancel warning can detach/recreate this Noesis command source.
        -- The independent value watcher below also calls the same guarded
        -- routine, so slider movement still changes the actual native level.
        if ApplyHistoricalSliderFromModel then
            ApplyHistoricalSliderFromModel("slider event")
        end
    end)
    vm.HB_NativeProbe:SetHandler(function()
        if CaptureNative then CaptureNative("manual", true) end
    end)
    vm.HB_NativeHostTestStart:SetHandler(function()
        nativePilotMode="intercept"
        if NativePilotStart then NativePilotStart() end
    end)
    vm.HB_NativeHistoricalStart:SetHandler(function()
        nativePilotMode="historical"
        if NativeHistoricalStart then NativeHistoricalStart() end
    end)
    vm.HB_NativeFeatPreviewToggle:SetHandler(function()
        if not previewOpen or nativePilotWrapping or not nativePilotActive then return end
        if not IsRecordedFeatPanel(ActivePanel()) then return end
        nativeFeatPreview=not nativeFeatPreview
        nativeSpellPreview=false;nativeSpellAllowStage=false
        Log("NATIVE_FEAT_VISUAL_TOGGLE level="..currentLevel.." enabled="..tostring(nativeFeatPreview))
        RequestNativeHistoricalRefresh("feat layout")
    end)
    vm.HB_NativeSpellPreviewToggle:SetHandler(function()
        if not previewOpen or nativePilotWrapping or not nativePilotActive then return end
        if not IsRecordedSpellPanel(ActivePanel()) then return end
        nativeSpellPreview=not nativeSpellPreview
        nativeSpellAllowStage=false
        nativeFeatPreview=false
        Log("NATIVE_SPELL_VISUAL_TOGGLE level="..currentLevel.." enabled="..tostring(nativeSpellPreview))
        RequestNativeHistoricalRefresh("spell layout")
    end)
    vm.HB_NativeSpellEditToggle:SetHandler(function()
        if not previewOpen or nativePilotWrapping or not nativePilotActive
            or not nativeSpellPreview or not CanStageNativeSpell(ActivePanel()) then return end
        nativeSpellAllowStage=not nativeSpellAllowStage
        Log("NATIVE_SPELL_STAGE_TOGGLE level="..tostring(currentLevel)
            .." enabled="..tostring(nativeSpellAllowStage))
        nativePilotReport=nativeSpellAllowStage and
            "TEST MODE: native spell clicks may stage edits. Server can reject unverified historical choices."
            or "Native spell editing disabled; preview is read-only."
        UpdateVM()
        -- Recreate option ViewModels so unavailable-rank icons immediately
        -- reflect the explicit TEST-mode toggle, not a stale preview state.
        RequestNativeHistoricalRefresh("spell staging state")
    end)
    vm.HB_NativeHostTestStop:SetHandler(function()
        if NativePilotStop then NativePilotStop(true) end
    end)
    local function CompleteReturn(openAtSelectedLevel)
        previewOpen=false
        queuedRefresh=false
        UpdateVM()
        Log(openAtSelectedLevel and ("Edit requested for character level " .. tostring(currentLevel))
            or "Native preview closed: returning to Edit Build")
        local resume=onReturn
        onReturn=nil
        onStagePassive=nil
        onStageResource=nil
        onStageOther=nil
        if resume then
            local ok,err=pcall(resume,openAtSelectedLevel and currentLevel or nil)
            if not ok then Log("Return callback error: "..tostring(err)) end
        end
    end
    local function ReturnToEditor(openAtSelectedLevel)
        if nativePilotWrapping then
            nativePilotReport="Finish the current native level transition before returning."
            UpdateVM()
            return
        end
        if nativePilotActive and NativePilotStop then
            -- Wait for the game-owned native DataContext to be restored
            -- before invoking Edit Build. Previously these were concurrent.
            NativePilotStop(false,function(restored)
                if restored then CompleteReturn(openAtSelectedLevel) end
            end)
            return
        end
        CompleteReturn(openAtSelectedLevel)
    end
    vm.HB_NativeBack:SetHandler(function() ReturnToEditor(false) end)
    vm.HB_NativeEdit:SetHandler(function() ReturnToEditor(true) end)
    vm.HB_NativeReview:SetHandler(function() ReturnToEditor(true) end)
    suppressSelect=true
    node.DataContext = vm
    suppressSelect=false
    queuedRefresh=false
    Log("Native preview ViewModel attached")
    return true
end
local function GetProperties(obj)
    if not obj then return {} end
    local worked, info = pcall(function() return obj:TypeInfo() end)
    if not worked then return {} end
    local props, seen = {}, {}
    local depth = 0
    while info and depth < 6 do
        depth = depth + 1
        for _, collection in ipairs({Read(info,"Properties") or {}, Read(info,"DependencyProperties") or {}}) do
            local ok, values = pcall(function()
                local found = {}
                for _, property in ipairs(collection) do
                    local name = Read(property,"Name")
                    if name and not seen[name] then
                        seen[name] = true
                        found[#found+1] = tostring(name) .. (Read(property,"IsReadOnly") and " [ro]" or "")
                    end
                end
                return found
            end)
            if ok then for _, name in ipairs(values) do props[#props+1] = name end end
        end
        info = Read(info,"Base")
    end
    table.sort(props)
    return props
end

-- The native character creation widgets expose read-only collections of
-- VMCharacterCreationPassive, VMSpellSelector, VMFeat etc. These live objects
-- must never be retained: Noesis invalidates them as the UI changes.
local NATIVE_COLLECTIONS = {
    "ClassPassives", "SubClassPassives", "ClassAndSubClassPassives",
    "ClassProgressionDetails", "SubClassProgressionDetails",
    "ClassSkills", "SelectableFeats", "ProgressionCantrips",
    "ProgressionSpells", "ProgressionFinalSpells", "PassiveFeatures"
}
local ITEM_FIELDS = {
    "Name", "DisplayName", "Description", "Id", "ID", "UUID", "PassiveId",
    "SpellId", "Feat", "SelectorId", "IsSelected", "Selected", "IsComplete",
    "SelectedPassiveCount", "MaxSelectedPassiveCount", "SelectedSpellCount",
    "MaxSelectedSpellCount", "IsRequirementsMet", "IsAlreadyTaken",
    "Passives", "Spells", "SubPassiveSelectors", "ClassPassiveSelectors",
    "SpellSelectors", "SelectedSkillCount", "MaxSelectedSkillCount"
}
local function ValueLabel(value)
    if value == nil then return "nil" end
    local t = type(value)
    if t == "string" or t == "number" or t == "boolean" then
        return tostring(value):sub(1, 120)
    end
    for _, field in ipairs({"Name", "DisplayName", "Id", "ID", "UUID", "PassiveId", "SpellId"}) do
        local item = Read(value, field)
        if item and type(item) ~= "userdata" and type(item) ~= "table" then
            return field .. "=" .. tostring(item):sub(1, 70)
        end
    end
    return "[" .. tostring(Read(value, "Type") or t):sub(1, 90) .. "]"
end
local function CollectionCount(col)
    if col == nil then return nil end
    local count = tonumber(Read(col, "Count"))
    if count then return count end
    local ok, size = pcall(function() return #col end)
    if ok and type(size) == "number" then return size end
    return nil
end
local function GetCollectionItem(col, offset)
    if not col then return nil end
    -- Different Noesis collections are 0-indexed and Lua tables 1-indexed.
    local tries
    if type(col) == "table" then
        tries = { function() return col[offset+1] end, function() return col[offset] end }
    else
        tries = {
            function() return col[offset] end,
            function() return col[offset+1] end,
            function() return col:Get(offset) end,
            function() return col:GetItem(offset) end
        }
    end
    for _, get in ipairs(tries) do
        local ok, item = pcall(get)
        if ok and item ~= nil then return item end
    end
    return nil
end
local function NativeVM()
    if not Ext.UI or not Ext.UI.GetRoot then return nil, nil end
    local ok, root = pcall(Ext.UI.GetRoot)
    if not ok or not root then return nil, nil end
    local container = Read(root, "ContentRoot")
    if not container then
        local okFind, result = pcall(function() return root:Find("ContentRoot") end)
        if okFind then container = result end
    end
    if not container then return nil, nil end
    local nodes, n = {container}, 1
    while n <= #nodes and n <= 2000 do
        local node = nodes[n]; n=n+1
        local name = Read(node, "Name")
        if name == "CharacterRespec" or name == "CharacterRespec_c"
            or name == "CharacterLevelUp" or name == "CharacterLevelUp_c" then
            local dc = Read(node, "DataContext")
            if dc then return dc, name, node end
        end
        local num = math.min(tonumber(Read(node, "VisualChildrenCount")) or 0, 140)
        for i=1,num do
            local okChild, child = pcall(function() return node:VisualChild(i) end)
            if okChild and child then nodes[#nodes+1]=child end
        end
    end
    return nil, nil
end

-- Correlate a live native VMCharacterCreationSpell's localization handle with
-- exact *installed* spell stat identities. This probe does NOT infer identity
-- from display name when several choices share a name, and never stages edits.
function HB_NATIVE_L1_SLIDER.ProbeLiveSpellStatIdentity(spell, selector, source, reason)
    if not spell or not Ext.Stats or not Ext.Stats.Get then return end
    local handle=tostring(Read(spell,"Name") or "")
    if handle=="" then return end
    local count=0;local matched={};local visited={};local candidates={}
    for _,level in ipairs({1}) do
        local rows=(((snapshot[level] or {}).LevelChoices or {}).OtherChoices or {})
        for _,row in ipairs(rows) do
            if row.Kind=="Spell" or row.Kind=="Cantrip" then
                for _,opt in ipairs(row.Options or {}) do
                    local id=tostring(opt.Id or opt.PassiveId or "")
                    if id~="" and not visited[id] and #candidates<300 then
                        visited[id]=true;candidates[#candidates+1]=id
                    end
                end
            end
        end
    end
    for _,id in ipairs(candidates) do
        local ok,stats=pcall(Ext.Stats.Get,id)
        if ok and stats then
            count=count+1
            local localized=tostring(Read(stats,"DisplayName") or "")
            if localized==handle then matched[#matched+1]=id end
        end
    end
    local list=(#matched>0) and table.concat(matched,",") or "none"
    local resolved=#matched==1 and matched[1] or "unresolved"
    local localized=""
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok,result=pcall(Ext.Loca.GetTranslatedString,handle)
        if ok and result then localized=tostring(result) end
    end
    local extra=Read(spell,"ExtenderData")
    local extraFields={}
    if extra then
        for _,field in ipairs(GetProperties(extra)) do
            if #extraFields>=16 then break end
            local value=Read(extra,field)
            if type(value)=="string" or type(value)=="number" then
                extraFields[#extraFields+1]=tostring(field).."="..tostring(value):sub(1,80)
            end
        end
    end
    if (reason=="vanilla-to-historical" or reason=="native-level-one-live")
        and source=="node.gameplaySubPanel.DataContext"
        and #matched==1 and Read(selector,"IsCantrips")~=true
        and (CollectionCount(Read(selector,"Additions")) or -1)==1 then
        local originals={}
        for _,row in ipairs((((snapshot[1] or {}).LevelChoices or {}).OtherChoices or {})) do
            if row.Kind=="Spell" and row.Editable==true then originals[#originals+1]=row end
        end
        -- Initial scope: one uniquely owned, same-rank first-level spell.
        -- Never guess ownership across two independent spell selectors.
        if #originals==1 and tostring(originals[1].From or "")~=resolved
            and HistoricalSpellRankClient(resolved)==HistoricalSpellRankClient(originals[1].From)
            and HistoricalSpellRankClient(resolved)==1 then
            HB_NATIVE_L1_SLIDER.LiveSpellSwap={
                From=tostring(originals[1].From),To=resolved}
            -- Clear every *recorded* later occurrence of the native pick.
            -- The original snapshot is not edited, and cleared slots cannot
            -- be committed without manually supplied replacements.
            local empty=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
            for later=2,maximum do
                for _,record in ipairs((((snapshot[later] or {}).LevelChoices or {}).OtherChoices or {})) do
                    local key=ChoiceKey(record)
                    if record.Kind=="Spell" and tostring(
                        ((previewOther[later] or {})[key]) or record.From or "")==resolved then
                        empty[later]=empty[later] or {}
                        empty[later][key]=true
                        Log("NATIVE_L1_SPELL_SLOT_CLEARED level="..later.." key="..key
                            .." spell="..resolved)
                    end
                end
            end
            HB_NATIVE_L1_SLIDER.DisplacedSpellSlots=empty
            Log("NATIVE_L1_VERIFIED_SPELL_SWAP from="..tostring(originals[1].From)
                .." to="..resolved.." source="..source)
        elseif #originals==1 and tostring(originals[1].From or "")==resolved then
            HB_NATIVE_L1_SLIDER.LiveSpellSwap=nil
            Log("NATIVE_L1_ORIGINAL_SPELL_RESTORED id="..resolved)
        else
            Log("NATIVE_L1_SPELL_SWAP_UNSUPPORTED originals="..#originals
                .." resolved="..resolved)
        end
    end
    Log("L1_SPELL_IDENTITY source="..tostring(source)
        .." handle="..handle.." translated="..localized:sub(1,90)
        .." checked="..count.." exactMatches="..#matched
        .." resolved="..resolved.." matches="..list
        .." cantrips="..tostring(Read(selector,"IsCantrips"))
        .." extenderType="..tostring(Read(extra,"Type"))
        .." extenderFields="..table.concat(extraFields,";"))
end

-- Observe the *active Noesis visual tree* in addition to native VM fields.
-- BG3's feat- and subclass-owned spells may be exposed only through a
-- templated content-panel DataContext, not a direct character VM property.
-- This is a bounded, one-shot diagnostic only, invoked on L1 entry/departure.
local function ProbeLiveSpellVisualTree(screenRoot, reason)
    if not screenRoot then return end
    local nodes={screenRoot}; local cursor=1
    local matches,selectors,examples,loggedTypes={},{},{},{}
    local matchedKeys,checkedKeys={},{};local examined=0
    local function Props(obj, maxCount)
        local p=GetProperties(obj)
        if #p>maxCount then
            local reduced={};for i=1,maxCount do reduced[i]=p[i] end
            return table.concat(reduced,",")..",+"..(#p-maxCount)
        end
        return table.concat(p,",")
    end
    local function ReportObject(obj, source)
        if not obj then return end
        -- Most native panels share the same DataContext across hundreds of
        -- visual children; inspect each transient object at most once.
        local key=tostring(obj)
        if checkedKeys[key] then return end
        checkedKeys[key]=true
        local typ=tostring(Read(obj,"Type") or type(obj))
        local observed=(typ:find("SpellSelector",1,true)~=nil
            or typ:find("SpellReference",1,true)~=nil
            or typ:find("FeatDetails",1,true)~=nil)
        local lists={}
        for _,field in ipairs({"Additions","SelectedSpells","SelectedItems",
            "SpellSelectors","Spells"}) do
            local collection=Read(obj,field)
            local count=CollectionCount(collection)
            if count and count>0 then
                lists[#lists+1]={Field=field,Collection=collection,Count=count}
                observed=true
            end
        end
        if not observed then return end
        local key=tostring(obj)
        if matchedKeys[key] then return end
        matchedKeys[key]=true
        if #matches>=22 then return end
        matches[#matches+1]={Type=typ,Source=source}
        Log("L1_SPELL_TREE_OBJECT source="..source
            .." type="..typ.." fields="..Props(obj,28)
            .." title="..tostring(Read(obj,"Title") or ""))
        for _,list in ipairs(lists) do
            if #selectors>=28 then break end
            Log("L1_SPELL_TREE_COLLECTION source="..source.." field="..list.Field
                .." count="..list.Count)
            for i=0,math.min(list.Count,4)-1 do
                local item=GetCollectionItem(list.Collection,i)
                local spell=Read(item,"Spell")
                local bits={}
                for _,candidate in ipairs({{"ref",item},{"spell",spell}}) do
                    local val=candidate[2]
                    if val then
                        for _,property in ipairs({"SpellId","StatsId","StatsName",
                            "SpellName","Id","Name","DisplayName","UUID","SourceId"}) do
                            local a=Read(val,property)
                            if a~=nil and (type(a)=="string" or type(a)=="number") then
                                bits[#bits+1]=candidate[1].."."..property.."="..tostring(a):sub(1,95)
                            end
                        end
                        if not loggedTypes[tostring(Read(val,"Type"))] then
                            loggedTypes[tostring(Read(val,"Type"))]=true
                            Log("L1_SPELL_TREE_ITEM_TYPE type="..tostring(Read(val,"Type"))
                                .." fields="..Props(val,45))
                        end
                    end
                end
                if #selectors>=28 then break end
                selectors[#selectors+1]=true
                if list.Field=="Additions" and spell and
                    typ:find("SpellSelector",1,true) then
                    local ok,err=pcall(HB_NATIVE_L1_SLIDER.ProbeLiveSpellStatIdentity,spell,obj,source,reason)
                    if not ok then Log("L1_SPELL_IDENTITY_ERROR "..tostring(err)) end
                end
                Log("L1_SPELL_TREE_PICK source="..source.." field="..list.Field
                    .." slot="..i.." data="..(#bits>0 and table.concat(bits,";") or "no-readable-spell-id"))
            end
        end
    end
    while cursor<=#nodes and cursor<=3000 and #matches<22 do
        local node=nodes[cursor];cursor=cursor+1;examined=examined+1
        local name=tostring(Read(node,"Name") or "")
        local typ=tostring(Read(node,"Type") or "")
        if (name=="gameplaySubPanel" or name=="subTabsSpellsList"
            or name=="spellSelectorData" or name=="selectedSpells"
            or name=="availableSpells" or name=="ClassSpellSelectors"
            or name=="SubClassSpellSelectors") and #examples<12 then
            local dc=Read(node,"DataContext")
            local content=Read(node,"Content")
            local items=Read(node,"ItemsSource")
            examples[#examples+1]=name
            Log("L1_SPELL_TREE_ANCHOR name="..name.." type="..typ
                .." dc="..tostring(Read(dc,"Type"))
                .." content="..tostring(Read(content,"Type"))
                .." items="..tostring(CollectionCount(items)))
        end
        -- Sample the instantiated native selector from its owning visual
        -- subtree. Do not inspect thousands of generic Item/Template proxies.
        local dc=Read(node,"DataContext")
        local item=Read(node,"Content")
        ReportObject(dc,"node."..name..".DataContext")
        if name=="gameplaySubPanel" or name=="spellSelectorData"
            or typ:find("ContentControl",1,true) then
            ReportObject(item,"node."..name..".Content")
        end
        local n=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,100)
        for j=1,n do
            local ok,child=pcall(function() return node:VisualChild(j) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    Log("L1_SPELL_TREE_SUMMARY reason="..tostring(reason)
        .." visited="..examined.." matches="..#matches
        .." picks="..#selectors.." anchors="..#examples)
end

-- Single-gesture read-only evidence for live vanilla level-one spell choices.
-- The saved historical choices are intentionally NOT changed here: that
-- would require authoritative validation against the eventual native commit.
-- Access the live game-owned ViewModel only synchronously; never cache C++
-- proxies across UI frames or walk a large selector collection per tick.
function HB_NATIVE_L1_SLIDER.ProbeNativeSpellPicks(reason)
    if not previewOpen or nativePilotActive or nativePilotWrapping then return end
    local native,screen,root=NativeVM()
    if (screen~="CharacterRespec" and screen~="CharacterRespec_c")
        or Read(native,"Type")~="gui::DCCharacterCreation" then return end
    if reason=="vanilla-to-historical" then
        -- Never retain an obsolete selection from an earlier slider visit.
        HB_NATIVE_L1_SLIDER.LiveSpellSwap=nil
    end
    local work,seen,scans={},{},0
    local function Add(value,label,depth)
        if value==nil or depth>4 or #work>=180 then return end
        work[#work+1]={Obj=value,Label=label,Depth=depth}
    end
    for _,name in ipairs({"ClassSpellSelectors","SubClassSpellSelectors",
        "ProgressionSpells","ProgressionCantrips","ProgressionFinalSpells",
        "ClassAndSubClassPassives","ClassPassives","SubClassPassives",
        "ClassProgressionDetails","SubClassProgressionDetails",
        "SelectedFeatDetails"}) do
        Add(Read(native,name),"vm."..name,0)
    end
    if root then
        for _,name in ipairs({"subTabsSpellsList","ClassSpellSelectors",
            "SubClassSpellSelectors","ClassSpellAvailableItemsControl",
            "spellSelectorData","gameplaySubPanel"}) do
            local ok,node=pcall(function() return root:Find(name) end)
            if ok and node then
                Add(Read(node,"ItemsSource"),"ui."..name..".ItemsSource",0)
                Add(Read(node,"DataContext"),"ui."..name..".DataContext",0)
            end
        end
    end
    local lines,found,selected={},0,0
    local cursor=1
    while cursor<=#work do
        local entry=work[cursor];cursor=cursor+1
        local obj=entry.Obj
        -- Visiting a container through multiple bindings is expected.
        -- Do not hold these ephemeral references beyond this function.
        local key=tostring(obj)
        if not seen[key] and scans<150 then
            seen[key]=true;scans=scans+1
            local additions=Read(obj,"Additions")
            local typ=tostring(Read(obj,"Type") or "")
            if additions~=nil and found<24 then
                found=found+1
                local count=math.min(CollectionCount(additions) or 0,12)
                lines[#lines+1]="L1_LIVE_SPELL_SELECTOR source="..entry.Label
                    .." type="..typ.." title="..tostring(Read(obj,"Title") or "")
                    .." additions="..tostring(CollectionCount(additions))
                    .." slots="..tostring(Read(obj,"Count"))
                    .." cantrips="..tostring(Read(obj,"IsCantrips"))
                for j=0,count-1 do
                    local ref=GetCollectionItem(additions,j)
                    local spell=Read(ref,"Spell")
                    local ids={}
                    for _,pair in ipairs({{"SpellId",ref},{"StatsId",ref},
                        {"Id",ref},{"SpellId",spell},{"StatsId",spell},
                        {"Id",spell},{"Name",spell}}) do
                        local value=Read(pair[2],pair[1])
                        if type(value)=="string" and value~="" then
                            ids[#ids+1]=pair[1].."="..value
                        end
                    end
                    selected=selected+1
                    lines[#lines+1]="L1_LIVE_SPELL_PICK source="..entry.Label
                        .." slot="..j.." refType="..tostring(Read(ref,"Type"))
                        .." spellType="..tostring(Read(spell,"Type"))
                        .." ids="..(#ids>0 and table.concat(ids,",") or "unresolved")
                end
            end
            if entry.Depth<4 and #work<160 then
                for _,name in ipairs({"SpellSelectors","ClassSpellSelectors",
                    "SubClassSpellSelectors","FeatDetails","SelectedFeatDetails",
                    "Passives","SubPassiveSelectors","ClassPassiveSelectors",
                    "ClassPassives","Spell","Details"}) do
                    Add(Read(obj,name),entry.Label.."."..name,entry.Depth+1)
                end
                local length=CollectionCount(obj)
                if length and length>0 and length<=32 then
                    for index=0,math.min(length,24)-1 do
                        Add(GetCollectionItem(obj,index),entry.Label.."["..index.."]",entry.Depth+1)
                    end
                end
            end
        end
    end
    HB_NATIVE_L1_SLIDER.ObserveAllFirstLevelSpellConflicts(native,root)
    Log("L1_LIVE_SPELL_PROBE reason="..tostring(reason)
        .." objects="..scans.." selectors="..found.." selected="..selected)
    for _,line in ipairs(lines) do Log(line) end
    local ok,err=pcall(ProbeLiveSpellVisualTree,root,reason)
    if not ok then Log("L1_SPELL_TREE_ERROR reason="..tostring(reason).." error="..tostring(err)) end
end

-- All native first-level spell selectors must be checked for duplicates,
-- not only the single-spell subclass exchange. Keep Noesis objects local to
-- this call; retain only exact installed spell IDs across UI frames.
function HB_NATIVE_L1_SLIDER.ObserveAllFirstLevelSpellConflicts(native,root)
    if not previewOpen or currentLevel~=1 or not HB_NATIVE_L1_SLIDER.Screen
        or HB_NATIVE_L1_SLIDER.FullRespecChanged then return end
    if Read(native,"Type")~="gui::DCCharacterCreation" then return end
    local handleIDs=HB_NATIVE_L1_SLIDER.FirstLevelSpellHandleIDs
    if not handleIDs then
        handleIDs={}
        local candidates={}
        for level=1,maximum do
            local historical=(snapshot[level] or {}).LevelChoices or {}
            for _,record in ipairs(historical.OtherChoices or {}) do
                if record.Kind=="Spell" or record.Kind=="Cantrip" then
                    local from=tostring(record.From or "")
                    if from~="" then candidates[from]=true end
                    if level==1 then
                        for _,option in ipairs(record.Options or {}) do
                            local id=tostring(option.Id or option.PassiveId or "")
                            if id~="" then candidates[id]=true end
                        end
                    end
                end
            end
            -- The server's duplicate guard reads native CCLevelUp, including
            -- spell rows omitted from the editable historical choice catalog.
            -- Source.SpellIds is derived from those exact recorded selections.
            for _,id in ipairs((historical.Source or {}).SpellIds or {}) do
                if type(id)=="string" and id~="" then candidates[id]=true end
            end
        end
        if Ext.Stats and Ext.Stats.Get then
            for id in pairs(candidates) do
                local ok,stat=pcall(Ext.Stats.Get,id)
                if ok and stat then
                    local raw=tostring(Read(stat,"DisplayName") or "")
                    local handle=raw:match("^([^;]+)")
                    if handle and handle~="" then
                        if handleIDs[handle] and handleIDs[handle]~=id then
                            handleIDs[handle]=false
                        elseif handleIDs[handle]==nil then
                            handleIDs[handle]=id
                        end
                    end
                end
            end
        end
        HB_NATIVE_L1_SLIDER.FirstLevelSpellHandleIDs=handleIDs
    end
    local selected={}
    local inspected={}
    local selectorCount=0
    local unresolved=0
    local visualSelected={}
    local scanningVisual=false
    local function Inspect(selector)
        if not selector or Read(selector,"Type")~="ls.VMSpellSelector" then return end
        local token=tostring(selector)
        if inspected[token] then return end
        inspected[token]=true
        selectorCount=selectorCount+1
        local picks=Read(selector,"Additions")
        local count=CollectionCount(picks)
        if not count or count<1 or count>24 then return end
        for i=0,count-1 do
            local reference=GetCollectionItem(picks,i)
            local spell=Read(reference,"Spell")
            local direct=Read(reference,"SpellId") or Read(spell,"SpellId")
            local id=(type(direct)=="string" and direct~="" and direct)
                or handleIDs[tostring(Read(spell,"Name") or "")]
            if type(id)=="string" and id~="" then
                selected[id]=true
                if scanningVisual then visualSelected[id]=true end
            else
                unresolved=unresolved+1
            end
        end
    end
    local function InspectCollection(collection)
        local count=CollectionCount(collection)
        if not count or count>32 then return end
        for i=0,count-1 do Inspect(GetCollectionItem(collection,i)) end
    end
    for _,name in ipairs({"ClassProgressionDetails","SubClassProgressionDetails"}) do
        local info=Read(native,name)
        InspectCollection(Read(info,"SpellSelectors"))
    end
    for _,name in ipairs({"ProgressionSpells","ProgressionCantrips","ProgressionFinalSpells"}) do
        InspectCollection(Read(native,name))
    end
    if root then
        local ok,panel=pcall(function() return root:Find("gameplaySubPanel") end)
        if ok and panel then Inspect(Read(panel,"DataContext")) end
        -- BG3 exposes some spell selectors only through instantiated native
        -- content templates. Prior Wizard diagnostics proved this: both spell
        -- selectors appeared in node.DataContext, whereas the direct class
        -- progression list reported only one. Read those actual widgets, never
        -- guess from localized names or modify the game-owned C++ ViewModel.
        -- Scan on L1 entry and every second observation, without keeping a
        -- Noesis proxy across frames. The traversal is bounded and L1-only.
        local sequence=(HB_NATIVE_L1_SLIDER.LevelOneVisualScanSequence or 0)+1
        HB_NATIVE_L1_SLIDER.LevelOneVisualScanSequence=sequence
        if sequence==1 or sequence%2==0 then
            scanningVisual=true
            local nodes={root};local cursor=1
            while cursor<=#nodes and cursor<=1800 and selectorCount<40 do
                local node=nodes[cursor];cursor=cursor+1
                Inspect(Read(node,"DataContext"))
                local typ=tostring(Read(node,"Type") or "")
                if typ:find("ContentControl",1,true) then
                    Inspect(Read(node,"Content"))
                end
                local n=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,100)
                for i=1,n do
                    local okChild,child=pcall(function() return node:VisualChild(i) end)
                    if okChild and child then nodes[#nodes+1]=child end
                end
            end
            scanningVisual=false
            -- Cache only identified spell IDs (never live Noesis objects).
            -- A skipped visual scan must not momentarily clear a genuine
            -- Choices Pending warning, and a later scan replaces this cache.
            HB_NATIVE_L1_SLIDER.LastVisualSelectedSpellIds=visualSelected
        else
            for id in pairs(HB_NATIVE_L1_SLIDER.LastVisualSelectedSpellIds or {}) do
                selected[id]=true
            end
        end
    end
    local holes=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
    local unrepresented={}
    local changed=false
    for level=2,maximum do
        local historical=(snapshot[level] or {}).LevelChoices or {}
        local represented={}
        for _,record in ipairs(historical.OtherChoices or {}) do
            if record.Kind=="Spell" or record.Kind=="Cantrip" then
                local original=tostring(record.From or "")
                local key=ChoiceKey(record)
                local effective=tostring((previewOther[level] or {})[key] or original)
                represented[original]=true
                represented[effective]=true
                if selected[effective] and not (holes[level] and holes[level][key]) then
                    holes[level]=holes[level] or {}
                    holes[level][key]=true
                    changed=true
                    Log("NATIVE_L1_SPELL_SLOT_CLEARED level="..level
                        .." key="..key.." spell="..effective.." source=all-native-selectors")
                end
            end
        end
        -- A recorded source-only spell still needs a guard even when the UI
        -- cannot expose an editable slot. It may be unresolvable until the
        -- native L1 selection changes; never invent a later choice to fill it.
        for _,id in ipairs((historical.Source or {}).SpellIds or {}) do
            if selected[id] and not represented[id] then
                unrepresented[level]=true
                Log("NATIVE_L1_UNREPRESENTED_SPELL_CONFLICT level="..level
                    .." spell="..id)
            end
        end
    end
    local oldUnrepresented=HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts or {}
    for level in pairs(unrepresented) do
        if not oldUnrepresented[level] then changed=true end
    end
    for level in pairs(oldUnrepresented) do
        if not unrepresented[level] then changed=true end
    end
    HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts=unrepresented
    if changed then
        HB_NATIVE_L1_SLIDER.DisplacedSpellSlots=holes
        HB_NATIVE_L1_SLIDER.LastLevelOnePending=nil
        Log("NATIVE_L1_ALL_SPELL_CONFLICTS pending="
            ..tostring(HB_NATIVE_L1_SLIDER.HasLaterLevelConflicts())
            .." selectors="..selectorCount.." unresolved="..unresolved)
        UpdateVM()
    end
end

-- BG3's SelectedClass/SelectedSubClass.Name may be a localization source
-- string rather than the already-translated name in our recorded history.
-- Those two representations MUST NOT be compared. Anchor the original
-- unmodified native selection on first entry and compare later native picks
-- against that same-session identity; reverting restores the slider.
-- The original CCLevelUp record is still required as a safety prerequisite.
function HB_NATIVE_L1_SLIDER.CheckChanged(native)
    if not native or Read(native,"Type")~="gui::DCCharacterCreation" then return nil end
    local original=((snapshot[1] or {}).LevelChoices or {})
    local source=original.Source or {}
    if original.HistoryAvailable~=true or not source.ClassId then return nil end
    local function Canonical(value)
        if type(value)~="string" or value=="" then return nil end
        local result=value:lower():gsub("[%s%p]+","")
        return result~="" and result or nil
    end
    local function Identity(obj)
        if obj==nil then return nil end
        if type(obj)=="string" then return {Name=Canonical(obj)} end
        local id=Canonical(Read(obj,"IDString"))
        local name=Canonical(Read(obj,"Name"))
        return (id or name) and {Id=id,Name=name} or nil
    end
    local function Different(saved,current)
        if saved==nil or current==nil then
            return saved~=nil or current~=nil
        end
        if saved.Id and current.Id then return saved.Id~=current.Id end
        if saved.Name and current.Name then return saved.Name~=current.Name end
        return nil
    end
    local class=Identity(Read(native,"SelectedClass"))
    local subclass=Identity(Read(native,"SelectedSubClass")
        or Read(native,"SelectedSubclass"))
    if not class then return nil end
    local baseline=HB_NATIVE_L1_SLIDER.OriginalNativeChoice
    if not baseline then
        -- Wait for both native selections if the recorded L1 had a subclass.
        -- The first GUI frame sometimes populates SelectedClass before
        -- SelectedSubClass; a missing selection is NOT a user change.
        if source.SubClassId and not subclass then return nil end
        HB_NATIVE_L1_SLIDER.OriginalNativeChoice={Class=class,Subclass=subclass}
        Log("NATIVE_L1_ORIGINAL_CHOICE_BASELINE class="
            ..tostring(class.Id or class.Name)
            .." subclass="..tostring(subclass and (subclass.Id or subclass.Name) or "none")
            .." savedClass="..tostring(source.ClassId)
            .." savedSubclass="..tostring(source.SubClassId))
        return false
    end
    local classChanged=Different(baseline.Class,class)
    if classChanged==true then return true end
    if classChanged==nil then return nil end
    return Different(baseline.Subclass,subclass)
end

function HB_NATIVE_L1_SLIDER.RefreshChanged()
    if not previewOpen or not HB_NATIVE_L1_SLIDER.Screen
        or currentLevel~=1 or nativePilotWrapping or nativeCommitPending then return end
    local live,screen=NativeVM()
    if (screen~="CharacterRespec" and screen~="CharacterRespec_c") then return end
    local changed=HB_NATIVE_L1_SLIDER.CheckChanged(live)
    if changed==nil then return end
    if changed~=HB_NATIVE_L1_SLIDER.FullRespecChanged then
        HB_NATIVE_L1_SLIDER.FullRespecChanged=changed
        Log("NATIVE_L1_FULL_RESPEC_CHANGE changed="..tostring(changed)
            .." class="..ValueLabel(Read(live,"SelectedClass"))
            .." subclass="..ValueLabel(Read(live,"SelectedSubClass")))
        UpdateVM()
    end
end

local function QueueOnUI(callback)
    if Ext.UI and Ext.UI.Defer then
        local ok, err = pcall(Ext.UI.Defer, callback)
        if ok then return end
        Log("Native pilot cannot queue safe UI action: " .. tostring(err))
    else
        Log("Native pilot unavailable: Ext.UI.Defer is required for safe UI changes.")
    end
end

-- Build a minimal model with the exact field names used by the native
-- PassiveSelectorItemTemplate/SelectableEnhancement in CCLib_k.xaml.
-- The game owns the actual visual templates and native click triggers.
-- We do not modify CCLevelUp, character data, or native respec progression.
-- For native historical passive rows only: look up the installed stat's
-- localization handle rather than showing the raw identifier on hover.
-- The original BG3 tooltip remains active on unmodified native rows.
local historicalPassiveDescriptions={}
local function HistoricalPassiveDescription(id)
    if historicalPassiveDescriptions[id]~=nil then return historicalPassiveDescriptions[id] end
    local description=""
    if Ext.Stats and Ext.Stats.Get then
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            local raw=Read(stat,"Description")
            if raw then
                local handle=tostring(Read(raw,"Handle") or raw):match("^([^;]+)")
                if handle and Ext.Loca and Ext.Loca.GetTranslatedString then
                    local got,localized=pcall(Ext.Loca.GetTranslatedString,handle)
                    if got and type(localized)=="string" and localized~="" and localized~=handle
                        and not localized:match("^h[%da-fg]+$") then
                        description=localized
                    end
                end
            end
        end
    end
    historicalPassiveDescriptions[id]=description
    return description
end

local function RegisterHistoricalModels()
    if historicalTypesRegistered then return true end
    if not Ext.UI or not Ext.UI.RegisterType then return false end
    Ext.UI.RegisterType(historicalDescriptionType, {Text={Type="String",Notify=true}})
    Ext.UI.RegisterType(historicalFeatType, {
        FeatId={Type="String"}, HB_HistoricalPanelIndex={Type="Int32"},
        HB_HistoricalLevel={Type="Int32"}, HB_HistoricalGeneration={Type="Int32"},
        Name={Type="String",Notify=true},
        Description={Type="String",Notify=true}, Requirements={Type="Collection"},
        IsRequirementsMet={Type="Bool",Notify=true},
        IsAlreadyTaken={Type="Bool",Notify=true}
    })
    -- Own an independent feat-selection ViewModel. Never override the game's
    -- SelectedFeat setter, which could alter the active respec transaction.
    Ext.UI.RegisterType(historicalFeatRootType, {
        SelectableFeats={Type="Collection"},
        SelectedFeat={Type="Object",Notify=true},
        SelectedFeatDetails={Type="Object",Notify=true}
    })
    -- Supply the fields that the ORIGINAL featsPanel detail renderer reads.
    -- Empty secondary-selection lists suppress spurious ability/skill/spell
    -- pickers. They cannot be reconstructed safely from just the feat ID.
    Ext.UI.RegisterType(historicalTextType, {Text={Type="String",Notify=true}})
    Ext.UI.RegisterType(historicalFeatInnerType, {
        Progressions={Type="Collection"},AbilitySelection={Type="Collection"},
        SpellSelectors={Type="Collection"},SelectedAbilityCount={Type="Int32",Notify=true},
        MaxSelectedAbilityCount={Type="Int32",Notify=true}
    })
    Ext.UI.RegisterType(historicalFeatSkillsType, {
        Skills={Type="Collection"}, SelectedSkillCount={Type="Int32",Notify=true},
        MaxSelectedSkillCount={Type="Int32",Notify=true}
    })
    Ext.UI.RegisterType(historicalFeatDetailType, {
        HasFeat={Type="Bool",Notify=true},Name={Type="String",Notify=true},
        Description={Type="Object"},FeatDetails={Type="Object"},
        FeatSkills={Type="Object"},FeatPassives={Type="Collection"}
    })
    Ext.UI.RegisterType(historicalSpellIconType, {
        Level={Type="Int32",Notify=true},Icon={Type="Object"},
        DisplayName={Type="String",Notify=true}
    })
    Ext.UI.RegisterType(historicalSpellType, {
        SpellId={Type="String"}, HB_HistoricalPanelIndex={Type="Int32"},
        HB_HistoricalLevel={Type="Int32"}, HB_HistoricalGeneration={Type="Int32"},
        HB_HistoricalPanelKind={Type="String"},
        Name={Type="String",Notify=true},
        Spell={Type="Object"},Selected={Type="Bool",Notify=true},
        NotAvailable={Type="Bool",Notify=true},
        HB_HistoricalSelectable={Type="Bool",Notify=true},
        HB_HistoricalAvailableSelectable={Type="Bool",Notify=true},
        HB_HistoricalTextOnly={Type="Bool",Notify=true},
        -- BG3's character-creation spell icon brushes are absent in
        -- replayed historical VMs. The installed spell stats instead
        -- provide the same icon IDs used by the game's tooltip assets.
        -- Never substitute a guessed image path into a live VMSpellReference.
        HB_HistoricalIconId={Type="String",Notify=true},
        HB_HistoricalMissingIcon={Type="Bool",Notify=true},
        HB_HistoricalFilterVisible={Type="Bool",Notify=true},
        HB_HistoricalRankText={Type="String",Notify=true},
        HB_HistoricalTooltip={Type="String",Notify=true},
        HB_HistoricalSchoolRank={Type="String",Notify=true},
        HB_HistoricalDescription={Type="String",Notify=true},
        HB_HistoricalDescriptionWithUnits={Type="Bool",Notify=true},
        HB_HistoricalDescriptionOneUnit={Type="Bool",Notify=true},
        HB_HistoricalDescriptionTwoUnits={Type="Bool",Notify=true},
        HB_HistoricalDescriptionPrefix={Type="String",Notify=true},
        HB_HistoricalDescriptionMiddle={Type="String",Notify=true},
        HB_HistoricalDescriptionSuffix={Type="String",Notify=true},
        HB_HistoricalDescriptionMeters1={Type="Double",Notify=true},
        HB_HistoricalDescriptionMeters2={Type="Double",Notify=true},
        HB_HistoricalRangeMeters={Type="Double",Notify=true},
        HB_HistoricalRadiusMeters={Type="Double",Notify=true},
        HB_HistoricalHasRange={Type="Bool",Notify=true},
        HB_HistoricalHasRadius={Type="Bool",Notify=true},
        HB_HistoricalDetails={Type="String",Notify=true},
        HB_HistoricalUpcast={Type="String",Notify=true},
        HB_HistoricalRestriction={Type="String",Notify=true},
        -- Use BG3's real tooltip ViewModel when the original respec VM has
        -- an EXACT same-spell reference; otherwise use the localized fallback.
        HB_HistoricalTooltipContent={Type="Object",Notify=true},
        HB_HistoricalNativeTooltip={Type="Bool",Notify=true}
    })
    local filterProperties={
        Title={Type="String",Notify=true},Description={Type="String",Notify=true},
        Available={Type="Collection"},Additions={Type="Collection"},
        IsCantrips={Type="Bool",Notify=true},IsActions={Type="Bool",Notify=true},
        AddedCount={Type="Int32",Notify=true},MaxAddedCount={Type="Int32",Notify=true},
        IsComplete={Type="Bool",Notify=true},
        HB_HistoricalAllowClick={Type="Bool",Notify=true},
        -- Existing vanilla-compatible school / damage dropdown controls.
        -- Commands are only registered on HB's temporary historical model.
        HB_Ready={Type="Bool",Notify=true},
        HB_Header={Type="String",Notify=true},HB_DamageHeader={Type="String",Notify=true},
        HB_Status={Type="String",Notify=true},
        HB_MenuOpen={Type="Bool",Notify=true},HB_DamageMenuOpen={Type="Bool",Notify=true},
        HB_Toggle={Type="Command"},HB_ToggleDamage={Type="Command"}
    }
    for i=1,#HB_SPELL_SCHOOLS do filterProperties["HB_School_"..i]={Type="Command"} end
    for i=1,#HB_SPELL_DAMAGE_TYPES do filterProperties["HB_Damage_"..i]={Type="Command"} end
    Ext.UI.RegisterType(historicalSpellRootType,filterProperties)
    Ext.UI.RegisterType(historicalItemType, {
        Name={Type="String",Notify=true}, PassiveId={Type="String"},
        HB_HistoricalPanelIndex={Type="Int32"},
        HB_HistoricalLevel={Type="Int32"}, HB_HistoricalGeneration={Type="Int32"},
        Value={Type="Double",Notify=true}, Enabled={Type="Bool",Notify=true},
        Blocked={Type="Bool",Notify=true}, Replaced={Type="Bool",Notify=true},
        IconName={Type="String",Notify=true},
        HB_HistoricalTakenElsewhere={Type="Bool",Notify=true},
        HB_HistoricalTakenNotice={Type="String",Notify=true},
        HB_HistoricalPassiveDescription={Type="String",Notify=true},
    })
    -- Unlike the previous plain se:: model, the native type is needed for
    -- the implicit DataTemplate<DataType=ls:VMCharacterCreationPassives>.
    Ext.UI.RegisterType(historicalGroupType, {
        Name={Type="String",Notify=true}, Description={Type="Object"},
        HB_HistoricalRenderKind={Type="String",Notify=true},
        HB_HistoricalFeatModel={Type="Object"},
        HB_HistoricalSpellModel={Type="Object"},
        HB_HistoricalSpellSummary={Type="String",Notify=true},
        HB_HistoricalGeneration={Type="Int32"},
        Passives={Type="Collection"}, IsComplete={Type="Bool",Notify=true},
        UpdateState={Type="String",Notify=true},
        MaxSelectedPassiveCount={Type="Int32",Notify=true},
        SelectedPassiveCount={Type="Int32",Notify=true},
        HB_HistoricalPanelIndex={Type="Int32"}
    }, "ls.VMCharacterCreationPassives")
    Ext.UI.RegisterType(historicalDetailType, {
        NotSubPassiveSelectors={Type="Collection"},
        SubPassiveSelectors={Type="Collection"},
        SpellSelectors={Type="Collection"},
        NotSubEquipmentSelectors={Type="Collection"},
        SubEquipmentSelectors={Type="Collection"}
    })
    historicalTypesRegistered=true
    return true
end

local function HBFeatTextHandle(value)
    local nested=Read(value,"Handle")
    return tostring(Read(nested,"Handle") or nested or (type(value)=="string" and value or ""))
end

local function HBTranslateFeat(value)
    local handle=HBFeatTextHandle(value)
    if handle=="" or not Ext.Loca or not Ext.Loca.GetTranslatedString then return nil,handle end
    local ok,localized=pcall(Ext.Loca.GetTranslatedString,handle)
    if ok and type(localized)=="string" and localized~="" and localized~=handle
        and not localized:match("^h[%da-fg]+$") then
        return localized,handle
    end
    return nil,handle
end

-- Read only static FeatDescription localization. The static feat record
-- supplies text, not a historical prerequisite verdict. Missing fields or
-- expansion/mod-specific descriptions fall back to a clear warning.
LoadFeatTextCache=function()
    if featTextCache then return featTextCache end
    local data={}
    featTextCache=data
    featTitleCache={}
    featRuleCache={}
    if not Ext.StaticData or not Ext.StaticData.GetAll then return data end
    local ok,list=pcall(Ext.StaticData.GetAll,"FeatDescription")
    if not ok or type(list)~="table" then return data end
    for _,guid in ipairs(list) do
        local present,record=pcall(Ext.StaticData.Get,guid,"FeatDescription")
        if present and record then
            local id=tostring(Read(record,"FeatId") or "")
            local handle=Read(record,"Description")
            local title,titleHandle=HBTranslateFeat(Read(record,"DisplayName"))
            if id~="" then
                if title then featTitleCache[id]=title end
                if HB_FEAT_XML_RULES[titleHandle] then
                    featRuleCache[id]=HB_FEAT_XML_RULES[titleHandle]
                end
            end
            if id~="" and handle then
                local localized=HBTranslateFeat(handle)
                -- For true plain-text descriptions only, preserve the source text.
                if not localized and type(handle)=="string" and not handle:match("^h[%da-fg]+$") then
                    localized=handle
                end
                if localized then data[id]=localized end
            end
        end
    end
    Log("NATIVE_FEAT_STATIC_TEXT indexed="..tostring(#list).." descriptions")
    return data
end

-- One historically provable eligibility rule: a feat already selected at
-- an EARLIER character level is already taken. Respect previous staged edits
-- as well, without treating the current level-12 abilities as level-4 state.
local function EarlierHistoricalFeatSelections()
    local result={}
    for level=1,currentLevel-1 do
        local choices=(snapshot[level] or {}).LevelChoices or {}
        local prior=choices.OtherChoices or {}
        local any=false
        for _,row in ipairs(prior) do
            if row.Kind=="Feat" then
                any=true
                local edits=previewOther[level] or {}
                local effective=tostring(edits[ChoiceKey(row)] or row.From or "")
                if effective~="" then result[effective]=true end
            end
        end
        if not any then
            local featId=choices.Source and choices.Source.FeatId
            if featId and tostring(featId)~="" then result[tostring(featId)]=true end
        end
    end
    return result
end

-- Static feat metadata can tell us if a feat is repeatable; this is
-- different from checking its current-level prereqs. Never lock genuine
-- repeatable feats solely because they appeared at an earlier level.
local function CanTakeFeatMultipleTimes(id)
    if not Ext.StaticData or not Ext.StaticData.Get then return false end
    local ok,feat=pcall(Ext.StaticData.Get,tostring(id),"Feat")
    if not ok or not feat then return false end
    return Read(feat,"CanBeTakenMultipleTimes")==true
end

local function HistoricalFeatTakenOnOtherLevel(id,excludedLevel)
    id=tostring(id or "")
    if id=="" then return nil end
    for level=1,maximum do
        if level~=excludedLevel then
            local choices=(snapshot[level] or {}).LevelChoices or {}
            local hasRows=false
            for _,row in ipairs(choices.OtherChoices or {}) do
                if row.Kind=="Feat" then
                    hasRows=true
                    local effective=tostring((previewOther[level] or {})[ChoiceKey(row)] or row.From or "")
                    if effective==id then return level end
                end
            end
            if not hasRows and choices.Source and tostring(choices.Source.FeatId or "")==id then
                return level
            end
        end
    end
    return nil
end

-- Source-order table generated from the exact 136 entries in the supplied Feats.lsx.
-- A feat absent from that file keeps its ORIGINAL catalog order after known HB entries.
local HB_FEAT_SOURCE_ORDER={
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]=1, -- AbilityImprovement
    ["cdcbc538-883b-401c-a8ed-1373fb6d1720"]=2, -- AccordoftheArcane
    ["f57bd72c-be64-4855-9e3a-bb7d7665e656"]=3, -- Alchemist
    ["d674aa33-8633-4b67-8623-b6788f0d5fc4"]=4, -- Alert
    ["eab25714-15d6-4e26-b809-3fad832d0484"]=5, -- AnchoredFocus
    ["94a78b4c-a8f2-404f-8cdc-2d454c13cb97"]=6, -- ArcaneEchoes
    ["661eee63-ff91-4f29-9f21-3a974c9d6fe5"]=7, -- Athleticism
    ["f692f7b5-ffd5-4942-91a1-a71ebb2f5e7c"]=8, -- BlessingsoftheMoon
    ["71b65667-0eac-4e62-b878-fa862e88ebbf"]=9, -- Charger
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]=10, -- ClassDivergence_Barbarian
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]=11, -- ClassDivergence_Bard
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]=12, -- ClassDivergence_Cleric
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]=13, -- ClassDivergence_Druid
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]=14, -- ClassDivergence_Fighter
    ["b441c722-e4d4-4702-861a-039bfd77c124"]=15, -- ClassDivergence_Monk
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]=16, -- ClassDivergence_Paladin
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]=17, -- ClassDivergence_Ranger
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]=18, -- ClassDivergence_Rogue
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]=19, -- ClassDivergence_Sorcerer
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]=20, -- ClassDivergence_Warlock
    ["93d41226-d7af-495c-b023-08a6af077962"]=21, -- ClassDivergence_Wizard
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]=22, -- ClassDivergence_Artificer
    ["26c6990b-d9f0-41a2-8108-209789fafc18"]=23, -- CombatMedic
    ["455fc2d5-1c77-40e7-a010-0b51044ae74b"]=24, -- Composed
    ["17ac3605-9a8a-41f3-9504-ffc17fffa03e"]=25, -- DefensiveDuelist
    ["0a3b07bf-a806-4c77-9c8f-6e7c0965f9dd"]=26, -- DualWielder
    ["681d5307-f0ed-4c94-8cf0-db0c51116f56"]=27, -- Dunesis
    ["60dfd716-3ba8-4611-90ee-018b59775b1d"]=28, -- Durable
    ["fdf0be80-cc1e-4501-bd2e-7a1ea737362c"]=29, -- ElementalAdept
    ["b13c4744-1d45-42da-b92c-e09f598ab1c3"]=30, -- GalvanizedStormsoul
    ["f3370916-6b35-4c5b-af36-19ca888cb43e"]=31, -- GreaterImpact
    ["e061a323-3430-4cff-88d3-5eae7a1779a4"]=32, -- IntrinsicArmoury
    ["816b1554-9384-49e9-aaa0-05dd622e60f7"]=33, -- Lucky
    ["010f717e-c6e2-45cf-bbf9-298a72db4cad"]=34, -- MageSlayer
    ["3fe71254-d1b2-44c7-886c-927552fe5f2e"]=35, -- MartialAdept
    ["019564a0-f136-4139-94ea-040f94bbaf19"]=36, -- MasonryofChaos
    ["c02f22c9-9a06-4001-b917-4d5cf09be399"]=37, -- MeleeExpertise
    ["be0889d2-f9aa-472d-b942-592bff0f1ef3"]=38, -- Multifaceted
    ["e8d1e7f6-d841-48ff-a83c-f1aaa16597ff"]=39, -- Performer
    ["ed4e367d-d136-4285-abac-077147e84cf2"]=40, -- PsionicDominance
    ["b153e75c-27a2-4412-95cd-60b477121679"]=41, -- ReactiveAssault
    ["d7940fdc-44c6-4d0d-8997-56eb6e606587"]=42, -- Resilient
    ["c06a8f0b-fbb8-4558-aa99-6985d45dfcad"]=43, -- RestrictedTerritory
    ["922c48ff-8fe5-4212-b6ee-e48122ee67ef"]=44, -- SavageAssault
    ["68f1ec15-2449-4ff1-aa72-6e35a0929091"]=45, -- Sentinel
    ["0ef8204b-59c9-4ea2-adfb-fc984a7d3eb1"]=46, -- Sharpshooter
    ["b29807ee-5cdd-4a5b-960c-1d1457488676"]=47, -- Shieldbearer
    ["daed512b-e063-4c69-8b8c-ee0d1439266f"]=48, -- Spellbreak
    ["46f6c764-44e0-4e58-8a3c-eb7ea0c0d887"]=49, -- TavernBrawler
    ["a6e8c0dd-5389-4f62-ba97-2908e0bbb56b"]=50, -- TogetherInTorment
    ["c760fcc0-c67a-4eea-a903-f051559b421f"]=51, -- Tough
    ["dcd89533-e8ab-4660-a101-53bb14a920ca"]=52, -- VisageofReflection
    ["47d60615-6d46-49ef-b993-1fa90274a90e"]=53, -- WarCaster
    ["03777635-ef87-4d19-a859-92b8dd69f6dc"]=54, -- ArtificerArcanist
    ["ce450c0d-a9d0-44a9-af97-2f2e8e990958"]=55, -- ArtificerArtillerist
    ["2cbd8b96-78f0-4b29-ac6f-c59cb6d126c0"]=56, -- ArtificerBattleSynthetic
    ["8dfca7e9-16a1-419c-bb92-faae1eed1bff"]=57, -- ArtificerGrenadier
    ["35e99c06-63f9-429c-8064-25bc2e22e730"]=58, -- ArtificerInfusedArcsmith
    ["c531fa20-17f2-4943-89e0-adf4f7a120b4"]=59, -- ArtificerStriker
    ["4ffa557b-2ad4-4a8c-abe6-1d1965c07dd3"]=60, -- BarbarianBeastheart
    ["75ce4c3a-884b-4c57-bec4-3e1cd0308523"]=61, -- BarbarianBerserker
    ["f9fa2010-40ff-4d31-91cc-d72b150967fb"]=62, -- BarbarianFrostbreaker
    ["de609f5b-bd4a-4155-b113-3e55093fc533"]=63, -- BarbarianGiantsBlood
    ["6919302f-f2b9-44f5-8562-ec4315527292"]=64, -- BarbarianRosemourn
    ["ae844b62-4b26-413d-8fce-20ca687f789a"]=65, -- BarbarianWildSoul
    ["694647d6-2a79-4161-9bf0-d973e1ec2558"]=66, -- BardCollegeOfCaptivation
    ["010dd210-461e-4aa8-b567-42f3ae52e2bd"]=67, -- BardCollegeOfLore
    ["b296fca6-a2ad-4687-ac54-a359a65aed86"]=68, -- BardCollegeofMoriendi
    ["3ce91e99-57d9-4c44-b80f-80e4c4952866"]=69, -- BardCollegeofNostalgia
    ["e1b012c1-051a-4202-84cd-b037fc2ac6f8"]=70, -- BardCollegeOfSteel
    ["43a56c6e-54b1-4151-97fc-0cc970fde672"]=71, -- BardCollegeOfValour
    ["2544f577-59ed-47ae-868c-22ab0eab59a1"]=72, -- ClericDeathDomain
    ["038aa39c-d4ca-41f0-8b25-8ca7b4356bc4"]=73, -- ClericForgeDomain
    ["18586891-4b5f-4f08-879f-0960e202af11"]=74, -- ClericIllusoryDomain
    ["abcb215a-f411-4b10-a804-f511467b956e"]=75, -- ClericLifeDomain
    ["18659104-48f2-47d7-a4d5-87e3274f3308"]=76, -- ClericTempestDomain
    ["ca55540b-9bf0-461d-936f-f4660b505775"]=77, -- ClericWarDomain
    ["d88b9883-f310-404a-8f33-7fbc551049e3"]=78, -- DruidCircleOfTheElements
    ["d3734a53-6c64-4280-b499-f8ab4dfbce46"]=79, -- DruidCircleOfTheLand
    ["f6a8994c-0351-4d3c-bba1-dee3c188f6c8"]=80, -- DruidCircleOfTheMoon
    ["9c6edc2f-24ab-42a6-acdf-0879efc5f41f"]=81, -- DruidCircleOfTheShadows
    ["15f43f0e-f065-4307-b50c-247005a293da"]=82, -- DruidCircleOfTheSpores
    ["e139d9a4-1bd9-4dd4-8db8-7cedf707ee13"]=83, -- DruidCircleOfTheStars
    ["51b7587d-966a-4f3b-b7c4-4e9fe8cf86f0"]=84, -- DruidTotemist
    ["07845122-15ec-4c3a-8724-ef9c8fb72f48"]=85, -- DruidCircleoftheVenom
    ["c759cc6b-f4d7-4d69-a52e-5a65b9ffc612"]=86, -- FighterArcaneArcher
    ["415dc709-9944-4f49-ac97-d63081a338ac"]=87, -- FighterChampion
    ["0bd9516c-195e-4012-bced-cb7528cbbc63"]=88, -- FighterDraconicSentinel
    ["9715353b-13b3-4cbc-ae1d-db99b7f6cc67"]=89, -- FighterEldritchKnight
    ["e39d5a46-c03a-4ee4-89f8-e522c86085a8"]=90, -- FighterFrontierKnight
    ["30498f77-3440-42dc-a61a-cb05ac49b248"]=91, -- FighterPalisade
    ["c9cffeb1-2cb0-44a2-a090-9db2026d549c"]=92, -- MonkWayOfTheArcane
    ["c4b9ac83-eccc-4118-b851-302ceea16584"]=93, -- MonkWayOfTheDrunkenFist
    ["1124cc40-5703-4516-8a5a-9ba3bdc52d45"]=94, -- MonkWayOfTheGentleFist
    ["b62b79dc-a53b-481e-95af-6e3d3b8e0908"]=95, -- MonkWayOfTheOpenHand
    ["924ca4a7-755d-42c3-9c5f-02fd64ea46c0"]=96, -- MonkWayOfTheShadowArts
    ["8f0ee646-0114-4f46-8ff3-d2b5bcaf1ca7"]=97, -- MonkWayOfTheTemperedSteel
    ["4c9def45-b180-4bf3-81e8-ec924d9a629a"]=98, -- PaladinOathOfTheAncients
    ["b143df54-0b4f-48bf-9ddc-308168bc86f8"]=99, -- PaladinOathOfTheCrown
    ["e38341cb-f364-468b-9862-67dcadba72db"]=100, -- PaladinOathOfDevotion
    ["750c4922-f381-4f37-bf26-1d0a91a7a797"]=101, -- PaladinOathOfVengeance
    ["3998987c-004f-4913-b7a7-62610e3cb45e"]=102, -- PaladinOathbreaker
    ["6b4bdec0-9753-46c1-967d-0c7e7b5ef039"]=103, -- PaladinMystflame
    ["47ab16a3-7f3e-4fa3-9ad2-0e884c2f8384"]=104, -- PaladinTyrant
    ["d8db4bce-a761-4c74-aaf6-ce62ffd7576a"]=105, -- RangerBeastmaster
    ["07e4218c-fe07-473a-914a-6e53c4e911a0"]=106, -- RangerGloomstalker
    ["0d28f4d0-30e2-4948-8b9c-137778929a4a"]=107, -- RangerHunter
    ["287ca7d6-c056-4366-b340-2e9acb1000a7"]=108, -- RangerMireMist
    ["2fbf3785-a116-41bc-b696-a50432ec46e2"]=109, -- RangerSwarmkeeper
    ["bfe6f78a-6dde-40e5-9982-2ed2a471f518"]=110, -- RangerTwinfang
    ["32700827-6d27-40a2-b0a1-b176875af5a7"]=111, -- RogueArcaneTrickster
    ["f1d35a6c-9c64-4431-862b-972e1004b628"]=112, -- RogueAssassin
    ["34539fe0-ef9f-4ae1-a218-95f431ef67da"]=113, -- RogueGauntlet
    ["a434fbc2-676c-4123-8d9a-24dd2e5d6898"]=114, -- RogueHiddenToxicant
    ["719ecbac-b1db-4dcc-a845-0fd44d17152c"]=115, -- RogueSwashbuckler
    ["3ae7b1ea-be32-4cd2-8a36-545e4a40a3b9"]=116, -- RogueThief
    ["42a995f6-fc5e-4577-b21b-eb7fa6c773ec"]=117, -- RogueVirulence
    ["ba1c505b-a3a8-483a-a061-a8b120c45c00"]=118, -- SorcererDraconicBloodline
    ["335d2999-28e5-4bfa-a107-534f5824748f"]=119, -- SorcererHematicMonarch
    ["35e6f8f0-01d4-4273-ad6b-994b287fabd1"]=120, -- SorcererRadiantBloom
    ["4df54b62-d011-4a95-8f97-e52f823b553d"]=121, -- SorcererShadeWalker
    ["9c24e1ca-bfe6-4252-a1d7-31e288e23f38"]=122, -- SorcererSouloftheFrenziedTundra
    ["10a9438c-a01e-4822-a6d9-537a6ce8bb17"]=123, -- SorcererVolcanist
    ["219431d8-c164-454a-b274-0fbf01a7ad2d"]=124, -- SorcererWildMagic
    ["4f136e0d-6548-44e3-ad1c-fcbe28ce58b4"]=125, -- WarlockPactOfTheBlade
    ["71c0b76e-3c66-45f8-80ac-98ba0f272fdb"]=126, -- WarlockPactOfTheChain
    ["0d17dbdd-57d6-4779-9d76-ebbdb2459b95"]=127, -- WarlockPactOfThePenumbra
    ["656cdba8-d560-42f2-8776-a7c575115fbd"]=128, -- WarlockPactOfThePrimordialDemon
    ["866befae-74b3-45a0-9da4-bdec17a3a63d"]=129, -- WarlockPactOfSeverance
    ["525212a2-e568-483d-994f-4c7eeee7fe94"]=130, -- WarlockPactOfTheTome
    ["84240516-b152-4008-a28a-39e1a6fd4693"]=131, -- WizardArcblade
    ["00ffa9e2-c8be-44b5-bc72-25293a715430"]=132, -- WizardArcaneWarden
    ["ae7218f2-90bb-4f90-8acb-a9946fe85a24"]=133, -- WizardElementalist
    ["2f5710ec-6ad4-4060-97a4-99b701455dac"]=134, -- WizardEvoker
    ["95dce8e9-bdd9-4951-8a05-8c5480f60352"]=135, -- WizardLuminalConfluence
    ["f86e70f9-7936-442c-b335-e1e77bb65d8a"]=136, -- WizardNecromancy
}

local function BuildNativeHistoricalFeatChoices(wrapper,panel,panelIndex)
    -- The recorded history only contains feat IDs and names. There is no
    -- historical evaluator for the *prior-level* ability/feature prerequisites.
    -- Never claim candidates are eligible based on the current respec VM.
    local root=Ext.UI.Instantiate("se::"..historicalFeatRootType)
    if not root then error("Historical feat panel model unavailable") end
    Log("NATIVE_FEAT_VISUAL_BEGIN level="..tostring(currentLevel)
        .." featType="..historicalFeatType.." optionCount="..tostring(#(panel.Options or {})))
    local current=CurrentEffectivePicks(panel)
    local currentId=tostring(current[1] or "")
    local chosen=nil
    local count=0
    local descriptions=LoadFeatTextCache()
    local previouslyTaken=EarlierHistoricalFeatSelections()
    local pastCount=0
    for _ in pairs(previouslyTaken) do pastCount=pastCount+1 end
    -- Preserve the AUTHOR'S order from Feats.lsx, independent of language or
    -- localized title. BG3's FeatsPanel preserves ItemsSource order. Unknown
    -- feats from other mods follow in their original option-list order.
    local ordered={}
    for catalogIndex,option in ipairs(panel.Options or {}) do
        local id=tostring(option.PassiveId or "")
        if id~="" then
            ordered[#ordered+1]={option=option,id=id,
                sourceOrder=HB_FEAT_SOURCE_ORDER[id:lower()],
                catalogOrder=catalogIndex}
        end
    end
    table.sort(ordered,function(a,b)
        if a.sourceOrder and b.sourceOrder then
            return a.sourceOrder<b.sourceOrder
        end
        if not a.sourceOrder and not b.sourceOrder then
            return a.catalogOrder<b.catalogOrder
        end
        return a.sourceOrder~=nil
    end)
    for _,record in ipairs(ordered) do
        local option,id=record.option,record.id
        if id~="" then
            local item=Ext.UI.Instantiate("se::"..historicalFeatType)
            item.FeatId=id
            item.HB_HistoricalPanelIndex=panelIndex
            item.HB_HistoricalLevel=currentLevel
            item.HB_HistoricalGeneration=nativeMenuGeneration+1
            local takenLevel=id~=currentId and HistoricalFeatTakenOnOtherLevel(id,currentLevel) or nil
            if takenLevel and CanTakeFeatMultipleTimes(id) then takenLevel=nil end
            item.Name=Label(option)..(takenLevel and ("  [Lv. "..tostring(takenLevel).."]") or "")
            local desc=descriptions[id]
            local hbRule=featRuleCache and featRuleCache[id]
            -- Only candidates the client AND authoritative server can
            -- safely replay are enabled. This is not an approximation of a
            -- feat's historical prerequisites: anything with requirements or
            -- secondary selectors remains locked until full replay exists.
            local alreadyTaken=takenLevel~=nil
            local denied=(id~=currentId) and (not panel.Editable and
                "Historical feat choice is not editable." or LocalChoiceConflict(panel,id)) or nil
            item.IsAlreadyTaken=alreadyTaken
            item.IsRequirementsMet=(id==currentId or denied==nil)
            if HB_SPECIALIST_MISSING_SELECTOR(id) and id~=currentId then
                item.IsRequirementsMet=false
                item.Description=(desc or "").."\nClass Specialist selections unavailable: missing verified passive list."
            end
            -- Show the feat's actual localized description, even when
            -- another client/server prerequisite disables selection.
            if item.Description==nil or item.Description=="" then
                item.Description=desc or ""
            end
            root.SelectableFeats[#root.SelectableFeats+1]=item
            count=count+1
            if id==currentId then chosen=item end
        end
    end
    if chosen then root.SelectedFeat=chosen end
    -- The native detail renderer expects a nested VM, not the feat option.
    -- Populate the recorded feat's title/description and leave unverified
    -- secondary choices empty rather than displaying bogus red selectors.
    -- The saved level-up history sometimes contains explicit ability, skill,
    -- or spell selections alongside the feat. Those are useful provenance for
    -- a future *native* feat-secondary editor, but do NOT prove the feat
    -- granted them. Display the original recorded choices inside BG3's
    -- existing feat detail area; never synthesize ability values or connect
    -- native SelectAbility/ToggleSkill to the real respec transaction.
    local detail=Ext.UI.Instantiate("se::"..historicalFeatDetailType)
    detail.HasFeat=chosen~=nil
    detail.Name=chosen and tostring(Read(chosen,"Name") or "") or ""
    local description=Ext.UI.Instantiate("se::"..historicalTextType)
    description.Text=descriptions[currentId] or ""
    detail.Description=description
    detail.FeatDetails=Ext.UI.Instantiate("se::"..historicalFeatInnerType)
    detail.FeatSkills=Ext.UI.Instantiate("se::"..historicalFeatSkillsType)
    -- Empty historical secondary-choice arrays keep those editors hidden.
    -- We never invent feat-specific skills or ability allocations.
    root.SelectedFeatDetails=detail
    wrapper.HB_HistoricalFeatModel=root
    Log("NATIVE_FEAT_VISUAL_MODEL level="..tostring(currentLevel)
        .." options="..tostring(count).." selected="..tostring(currentId)
        .." earlierFeats="..tostring(pastCount)
        .." prereqStatus="..(HB_UNRESTRICTED_FEAT_TEST and "UNRESTRICTED_EXPERIMENT" or "UNVERIFIED_FAIL_CLOSED"))
end


local function BuildNativeSpellDisplayLookup(originalDC)
    -- One bounded scan per page; repeated per-candidate lookups would stall
    -- Noesis on larger spell catalogs. Never persist native proxies across
    -- UI callbacks. This is presentation only, not eligibility evaluation.
    local refs={}
    local checked=0
    for _,field in ipairs({"ProgressionSpells","ProgressionCantrips","ProgressionFinalSpells"}) do
        local selectors=Read(originalDC,field)
        for a=0,math.min(CollectionCount(selectors) or 0,25)-1 do
            local sel=GetCollectionItem(selectors,a)
            for _,part in ipairs({"Available","Additions"}) do
                local list=Read(sel,part)
                for b=0,math.min(CollectionCount(list) or 0,100)-1 do
                    local ref=GetCollectionItem(list,b)
                    local spell=Read(ref,"Spell")
                    if spell then
                        for _,id in ipairs({Read(ref,"SpellId"),Read(ref,"StatsId"),
                            Read(spell,"SpellId"),Read(spell,"StatsId"),Read(spell,"Id")}) do
                            local key=tostring(id or "")
                            if key~="" and not refs[key] then refs[key]=spell end
                        end
                    end
                    checked=checked+1
                    if checked>=650 then return refs,checked end
                end
            end
        end
    end
    return refs,checked
end

-- Use BG3's FeatSpellSelector and original selected/available spell slot
-- templates for each historical spell group. Selection commands reach HB's
-- guarded historical choice replay, NEVER the active C++ respec transaction.
-- Spell IDs from observational progression/spellbook data remain read-only.
-- Unmatched icons may lack the live game's VMSpellReference brush.
-- Warn in the native BG3 spell list when the *exact same spell* is
-- already a player-recorded historical choice elsewhere. Never scan the
-- current spellbook for this: its acquisition level may be unprovable.
-- Edits staged at another level are included in the effective history.
local function SpellChosenAtOtherHistoricalLevel(id,excludedLevel)
    id=tostring(id or "")
    if id=="" then return nil end
    for level=1,maximum do
        if level~=excludedLevel then
            local choices=(snapshot[level] or {}).LevelChoices or {}
            for _,row in ipairs(choices.OtherChoices or {}) do
                if row.Kind=="Spell" or row.Kind=="Cantrip" then
                    local replacements=previewOther[level] or {}
                    local effective=tostring(replacements[ChoiceKey(row)] or row.From or "")
                    -- Only a verified live native first-level spell may
                    -- replace its original historical identity in the UI.
                    -- The authoritative server still rechecks BG3's commit.
                    local live=HB_NATIVE_L1_SLIDER.LiveSpellSwap
                    if level==1 and row.Kind=="Spell" and live
                        and tostring(row.From)==live.From then effective=live.To end
                    -- A cleared historical slot has no selected spell.
                    local cleared=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
                    if not (level>=2 and cleared[level] and cleared[level][ChoiceKey(row)])
                        and effective==id then
                        return level
                    end
                end
            end
        end
    end
    return nil
end

-- Render spell names from their actual installed stats, instead of using
-- internal IDs such as StinkingCloud or ArmorOfAgathys. A missing
-- localization entry is never treated as a real name.
local historicalSpellNameCache={}
-- Resolve the installed spell's actual icon identifier, not a name-derived
-- guess. The XAML converter looks it up in BG3's own tooltip icon atlas.
-- Missing stats/icons stay readable as text; this is presentation only.
local historicalSpellIconCache={}
-- The two edited icon textures are now provided as genuine GUI assets in
-- GUI/Assets/Tooltips/Icons, with their source-backed identifiers registered
-- in GUI/metadata.lsx. Tasha's icon is a vanilla asset: its apostrophe was
-- previously rejected by the validation below before lookup was attempted.
-- Keep the table for future *verified* atlas failures, not guessed aliases.
HB_HISTORICAL_UNRESOLVED_ART={}
local function HistoricalSpellIconId(id)
    id=tostring(id or "")
    if historicalSpellIconCache[id]~=nil then
        return historicalSpellIconCache[id] or ""
    end
    local icon=""
    if id~="" and Ext.Stats and Ext.Stats.Get then
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            local value=Read(stat,"Icon")
            -- The vanilla Tasha's Hideous Laughter atlas ID contains an
            -- apostrophe. Allow exactly that installed ID alongside the
            -- standard conservative icon-ID pattern.
            if type(value)=="string" and #value<=128
                and (value:match("^[%w_%-]+$")
                    or value=="Spell_Enchantment_Tasha'sHideousLaughter") then
                icon=value
            end
        end
    end
    historicalSpellIconCache[id]=icon
    return icon
end
local function HistoricalSpellDisplayName(id,originalFallback)
    id=tostring(id or "")
    if historicalSpellNameCache[id] then return historicalSpellNameCache[id] end
    if Ext.Stats and Ext.Stats.Get then
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            local handle=Read(stat,"DisplayName")
            if handle and Ext.Loca and Ext.Loca.GetTranslatedString then
                local translated,localized=pcall(Ext.Loca.GetTranslatedString,tostring(handle))
                if translated and type(localized)=="string" and localized~=""
                    and localized~=tostring(handle) and not localized:match("^h%x+$") then
                    historicalSpellNameCache[id]=localized
                    return localized
                end
            end
        end
    end
    local value=id:gsub("^[^_]+_",""):gsub("_"," ")
    value=value:gsub("(%l)(%u)","%1 %2"):gsub("(%u)(%u%l)","%1 %2")
    if value=="" then value=tostring(originalFallback or id) end
    historicalSpellNameCache[id]=value
    return value
end

-- No C++ VMSpellReference object is available for most historical entries,
-- so CCSpellTooltip cannot receive its normal engine-owned content. Resolve
-- installed localization handles for a styled spell tooltip without inventing
-- numerical effects or affecting historical selection eligibility.
local historicalSpellDescriptionCache={}
local function HBHistoricalSpellDescription(id)
    id=tostring(id or "")
    if historicalSpellDescriptionCache[id]~=nil then
        return historicalSpellDescriptionCache[id]
    end
    local desc=""
    if Ext.Stats and Ext.Stats.Get then
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            for _,key in ipairs({"Description","TooltipDescription"}) do
                local handle=Read(stat,key)
                if handle and Ext.Loca and Ext.Loca.GetTranslatedString then
                    local got,value=pcall(Ext.Loca.GetTranslatedString,tostring(handle))
                    if got and type(value)=="string" and value~=""
                        and value~=tostring(handle) and not value:match("^h[%x]+$") then
                        -- Some localized descriptions have engine-substituted
                        -- placeholders; retain text rather than guessing values.
                        desc=value
                        break
                    end
                end
            end
        end
    end
    historicalSpellDescriptionCache[id]=desc
    return desc
end

-- Historical tooltip detail resolver. Installed Ext.Stats data is authoritative:
-- the user's spell-list/SpellData files describe these fields, but mods may
-- override them. Never manufacture a native BG3 tooltip ViewModel, execute
-- spell functors, or run this on a gameplay tick. Results are cached per ID.
local historicalSpellRichTooltipCache={}
local function HBLocalizedStatField(raw)
    if raw==nil then return "" end
    local source=Read(raw,"Handle") or raw
    local handle=tostring(source or "")
    if handle=="" or not (Ext.Loca and Ext.Loca.GetTranslatedString) then return "" end
    for _,candidate in ipairs({handle,handle:match("^([^;]+)") or handle}) do
        local ok,translated=pcall(Ext.Loca.GetTranslatedString,candidate)
        if ok and type(translated)=="string" and translated~=""
            and translated~=candidate and translated~=handle
            and not translated:match("^h[%da-fg]+$") then
            return translated
        end
    end
    return ""
end

-- Split stat arguments only at top-level separators. Damage expressions can
-- contain nested functions like LevelMapValue(...), so a plain comma split
-- would produce an incorrect damage formula.
local function HBTopLevelParts(text,separator)
    local parts,depth,start={},0,1
    for i=1,#text do
        local char=text:sub(i,i)
        if char=="(" then depth=depth+1
        elseif char==")" then depth=math.max(0,depth-1)
        elseif char==separator and depth==0 then
            parts[#parts+1]=text:sub(start,i-1)
            start=i+1
        end
    end
    parts[#parts+1]=text:sub(start)
    for i,part in ipairs(parts) do
        parts[i]=part:match("^%s*(.-)%s*$") or ""
    end
    return parts
end

local function HBCalls(text,callName,maxItems)
    local results={}
    if type(text)~="string" or #text>8192 then return results end
    local offset=1
    while #results<(maxItems or 3) do
        local first,last=text:find(callName.."%s*%(",offset)
        if not first then break end
        local balanced=text:sub(last):match("^%b()")
        if not balanced then break end
        results[#results+1]=HBTopLevelParts(balanced:sub(2,-2),",")
        offset=last+#balanced
    end
    return results
end

local function HBDamagePhrase(expression,damageType)
    expression=tostring(expression or "")
    damageType=tostring(damageType or "")
    if damageType~="" and not damageType:match("^[%a]+$") then damageType="" end
    if expression:match("^[%d%dDd%s%+%-%*/%(%)]+$") and #expression<=50 then
        -- These are actual installed SpellData dice, not an estimated roll.
        local pretty=expression:gsub("%s*%+%s*", " + "):gsub("%s*%-%s*", " - ")
        return pretty..(damageType~="" and (" "..damageType) or "")
    end
    if expression:find("LevelMapValue",1,true) then
        -- Preserve the die denomination without inventing the number of dice
        -- at a different historical character level.
        local die=expression:match("[Dd](%d+)Cantrip")
        return (die and ("d"..die.." (scales with character level)") or
            "Scales with character level")
            ..(damageType~="" and (" ("..damageType..")") or "")
    end
    -- Weapon and special damage formulas are character- or equipment-dependent.
    -- Showing a fabricated fixed dice expression here would be misleading.
    if expression~="" then
        return "Character-dependent"..(damageType~="" and (" ("..damageType..")") or "")
    end
    return ""
end

-- Keep localized descriptions in their original rich-text form. Some of
-- BG3's LSTag markup includes linked status/tooltips; splitting that markup
-- into separate visual Runs would lose the native formatting. Instead expose
-- text fragments and metre values to one native TextBlockFormatter SourceText
-- MultiBinding, which inserts BG3's settings-aware UnitConverter output.
-- Never concatenate both metric and imperial distances into the tooltip.
local function HBTooltipNormalizeDistances(text)
    if type(text)~="string" or text=="" then return text end
    -- Earlier experimental previews could contain dual-unit text. Normalize
    -- it back to metres before letting the native converter choose one unit.
    text=text:gsub("(%d+%.?%d*)%s*m%s*/%s*%d+%s*ft",function(metres)
        return string.format("%gm",tonumber(metres) or 0)
    end)
    return (text:gsub("(%d+%.?%d*)%s*m%f[^%a]",function(metres)
        local number=tonumber(metres)
        return (number and string.format("%gm",number)) or (metres.."m")
    end))
end

local function HBTooltipDescriptionRuns(text)
    if type(text)~="string" or text=="" then return nil end
    local parts,from={},1
    while #parts<3 do
        local first,last,metres=text:find("(%d+%.?%d*)m%f[^%a]",from)
        if not first then break end
        local n=tonumber(metres)
        if not n or n<=0 or n>10000 then return nil end
        parts[#parts+1]={Before=text:sub(from,first-1),Metres=n}
        from=last+1
    end
    if #parts<1 or #parts>2 then return nil end
    local rest=text:sub(from)
    -- More than two distances retain the original localized single-unit
    -- string rather than risk truncating or breaking source markup.
    if rest:find("%d+%.?%d*m%f[^%a]") then return nil end
    return {Count=#parts,First=parts[1].Before,Metres1=parts[1].Metres,
        Middle=parts[2] and parts[2].Before or rest,
        Metres2=parts[2] and parts[2].Metres or 0,Last=rest}
end

local function HBTooltipParamValue(part)
    local damage=HBCalls(part,"DealDamage",1)
    if damage[1] then
        local phrase=HBDamagePhrase(damage[1][1],damage[1][2])
        return phrase~="" and (phrase.." damage") or nil
    end
    local distance=part:match("^Distance%(([%d%.]+)%)$")
    if distance then return distance.."m" end
    if part:match("^[%d%.]+$") then return part end
    return nil
end

local function HBRenderTooltipParams(text,params)
    if type(text)~="string" or text=="" or not text:find("%[%d+%]") then return text end
    local args=HBTopLevelParts(tostring(params or ""),";")
    if #args==0 then return text end
    local rendered=text:gsub("%[(%d+)%]",function(index)
        local raw=args[tonumber(index)]
        if not raw then return "["..index.."]" end
        return HBTooltipParamValue(raw) or ("["..index.."]")
    end)
    -- Avoid exposing uninterpreted engine placeholders in a supplementary
    -- upcast description. The main localized spell description is unchanged.
    if rendered:find("%[%d+%]") then return "" end
    return rendered
end

local function HBRichHistoricalSpellTooltip(id)
    id=tostring(id or "")
    if historicalSpellRichTooltipCache[id] then
        local value=historicalSpellRichTooltipCache[id]
        return value.Details,value.Upcast,value.Description,value.DescriptionRuns,
            value.RangeMeters,value.RadiusMeters
    end
    local value={Details="",Upcast="",Description="",DescriptionRuns=nil,
        RangeMeters=0,RadiusMeters=0}
    if id=="" or not (Ext.Stats and Ext.Stats.Get) then
        return "","",""
    end
    local ok,stat=pcall(Ext.Stats.Get,id)
    if not ok or not stat then return "","","" end
    local rows={}
    local function Add(label,text)
        if text and text~="" and #rows<9 then
            rows[#rows+1]=label..": "..text
        end
    end
    -- BG3's installed spells do not uniformly populate TooltipDamageList.
    -- When the tooltip field is empty, consult the spell's successful-hit
    -- functors, then its direct SpellProperties. Do not infer from SpellFail:
    -- a saving throw's half damage is not the spell's normal damage dice.
    -- Never execute functors; all these expressions are read-only text.
    local damages={}
    local function StatText(field)
        local raw=Read(stat,field)
        if type(raw)=="string" then return raw end
        if raw==nil then return "" end
        local ok,text=pcall(tostring,raw)
        if ok and type(text)=="string" and #text<8192 then return text end
        return ""
    end
    for _,field in ipairs({"TooltipDamageList","SpellSuccess","SpellProperties"}) do
        local unique={}
        for _,args in ipairs(HBCalls(StatText(field),"DealDamage",3)) do
            local phrase=HBDamagePhrase(args[1],args[2])
            if phrase~="" and not unique[phrase] then
                unique[phrase]=true
                damages[#damages+1]=phrase
            end
        end
        -- Never combine alternative sources: TooltipDamageList is the
        -- authoritative displayed value when present; otherwise use the
        -- actual successful-hit damage, not all nested status effects.
        if #damages>0 then break end
    end
    if #damages>0 then Add("Damage",table.concat(damages," + ")) end

    local attackAndSave=tostring(Read(stat,"TooltipAttackSave") or "")
    local saves,attacks={},{}
    for token in attackAndSave:gmatch("[^;]+") do
        token=token:match("^%s*(.-)%s*$") or ""
        if token=="Strength" or token=="Dexterity" or token=="Constitution"
            or token=="Intelligence" or token=="Wisdom" or token=="Charisma" then
            saves[#saves+1]=token
        elseif token=="MeleeSpellAttack" then attacks[#attacks+1]="Melee Spell"
        elseif token=="RangedSpellAttack" then attacks[#attacks+1]="Ranged Spell"
        elseif token=="MeleeWeaponAttack" then attacks[#attacks+1]="Melee Weapon"
        elseif token=="RangedWeaponAttack" then attacks[#attacks+1]="Ranged Weapon"
        end
    end
    if #attacks>0 then Add("Attack",table.concat(attacks,", ")) end
    if #saves>0 then Add("Save",table.concat(saves,", ")) end

    -- Spell slots are implicit in this spell-picker view. Show the action
    -- economy alone, avoiding wrapped "Level X Spell Slot" text. Preserve
    -- distinct non-slot action costs for modded spells.
    local costs,seenCosts={},{}
    for part in tostring(Read(stat,"UseCosts") or ""):gmatch("[^;]+") do
        local cost
        if part:match("^ActionPoint:") then cost="Action"
        elseif part:match("^BonusActionPoint:") then cost="Bonus Action"
        elseif part:match("^ReactionActionPoint:") then cost="Reaction"
        end
        if cost and not seenCosts[cost] then
            seenCosts[cost]=true
            costs[#costs+1]=cost
        end
    end
    if #costs>0 then Add("Cost",table.concat(costs," · ")) end
    -- Native BG3 settings-aware metric/imperial presentation is done in XAML.
    local range=tostring(Read(stat,"TargetRadius") or Read(stat,"Range") or "")
    if range:match("^%d+%.?%d*$") then
        value.RangeMeters=math.max(0,tonumber(range) or 0)
    end
    local area=tostring(Read(stat,"AreaRadius") or "")
    if area:match("^%d+%.?%d*$") then
        value.RadiusMeters=math.max(0,tonumber(area) or 0)
    end
    local flags=tostring(Read(stat,"SpellFlags") or "")
    if (";"..flags..";"):find(";IsConcentration;",1,true) then
        rows[#rows+1]="Concentration"
    end

    local statuses,seen={},{}
    local rawStatuses=Read(stat,"TooltipStatusApply")
    for _,args in ipairs(HBCalls(rawStatuses,"ApplyStatus",3)) do
        local statusId=args[1]
        if statusId and statusId:match("^[%w_]+$") and not seen[statusId] then
            seen[statusId]=true
            local label=""
            local sOk,status=pcall(Ext.Stats.Get,statusId)
            if sOk and status then label=HBLocalizedStatField(Read(status,"DisplayName")) end
            if label=="" then
                label=statusId:gsub("_"," "):lower():gsub("^%l",string.upper)
            end
            statuses[#statuses+1]=label
        end
    end
    if #statuses>0 then Add("Status",table.concat(statuses,", ")) end
    value.Details=table.concat(rows,"\n")

    local upcast=""
    for _,pair in ipairs({{"TooltipUpcastDescription","TooltipUpcastDescriptionParams"},
                          {"ExtraDescription","ExtraDescriptionParams"}}) do
        local locale=HBLocalizedStatField(Read(stat,pair[1]))
        if locale~="" then
            local text=HBRenderTooltipParams(locale,Read(stat,pair[2]))
            if text~="" then upcast=HBTooltipNormalizeDistances(text);break end
        end
    end
    value.Upcast=upcast
    local desc=HBHistoricalSpellDescription(id)
    local descWithParams=HBRenderTooltipParams(desc,Read(stat,"DescriptionParams"))
    if descWithParams~="" then
        value.Description=HBTooltipNormalizeDistances(descWithParams)
        value.DescriptionRuns=HBTooltipDescriptionRuns(value.Description)
    end
    historicalSpellRichTooltipCache[id]=value
    return value.Details,value.Upcast,value.Description,value.DescriptionRuns,
        value.RangeMeters,value.RadiusMeters
end

-- The stats metadata is PRESENTATION ONLY. A blank/unknown school or damage
-- type must never make a spell selectable or bypass the normal rank/ownership
-- validators. BG3 spell stats are not guaranteed to carry DamageType directly.
local historicalSpellCategoryCache={}
-- Read multiple *explicit* damage types from installed spell stats. Several
-- BG3 spells store their damage in TooltipDamageList/OnSave/OnMiss instead of
-- the main DamageType field. This is display/filter metadata ONLY, and never
-- broadens the historical option list or bypasses server eligibility.
local function HistoricalSpellCategory(id)
    id=tostring(id or "")
    local cached=historicalSpellCategoryCache[id]
    if cached then return cached.School,cached.Damage,cached.Types end
    local result={School="",Damage="",Types={}}
    local function MatchCategory(value,labels)
        if type(value)~="string" then return "" end
        local normalized=value:lower():gsub("[^%a]","")
        for index=2,#labels do
            local label=labels[index]
            if normalized==label:lower():gsub("[^%a]","") then return label end
        end
        return ""
    end
    local function AddDamage(value)
        local name=MatchCategory(value,HB_SPELL_DAMAGE_TYPES)
        if name~="" then result.Types[name]=true end
    end
    local function ReadTooltipDamage(text)
        if type(text)~="string" then return end
        local startAt=1
        while true do
            local first,last=text:find("DealDamage%s*%b()",startAt)
            if not first then break end
            local content=text:sub(first,last):match("%((.*)%)") or ""
            -- Split outer comma arguments only: damage amounts may contain
            -- nested expressions with their own commas.
            local args,depth,begin={},0,1
            for index=1,#content do
                local char=content:sub(index,index)
                if char=="(" then depth=depth+1
                elseif char==")" then depth=depth-1
                elseif char=="," and depth==0 then
                    args[#args+1]=content:sub(begin,index-1)
                    begin=index+1
                end
            end
            args[#args+1]=content:sub(begin)
            AddDamage(args[2])
            startAt=last+1
        end
    end
    if Ext.Stats and Ext.Stats.Get then
        local ok,stat=pcall(Ext.Stats.Get,id)
        if ok and stat then
            result.School=MatchCategory(Read(stat,"SpellSchool") or Read(stat,"School"),HB_SPELL_SCHOOLS)
            AddDamage(Read(stat,"DamageType"))
            for _,field in ipairs({"TooltipDamageList","TooltipOnSave","TooltipOnMiss"}) do
                ReadTooltipDamage(Read(stat,field))
            end
        end
    end
    local damageLabels={}
    for index=2,#HB_SPELL_DAMAGE_TYPES do
        local name=HB_SPELL_DAMAGE_TYPES[index]
        if result.Types[name] then damageLabels[#damageLabels+1]=name end
    end
    result.Damage=table.concat(damageLabels,", ")
    historicalSpellCategoryCache[id]=result
    return result.School,result.Damage,result.Types
end

-- Descriptions below are exact HB localized progression-choice text, not
-- inferred descriptions from selected passive stats. Unknown groups stay
-- blank until their selector's original description metadata is available.
HB_MULTIFACETED_UI.SourceSelectorDescriptionHandles={
    ["Honed Techniques"]="9b7b811b9c3043e189f945540bf5116e0000e",
    ["Metamagic"]="h8039e28cgdf1dg4d77g86f3ga1e05869a69c",
}
function HB_MULTIFACETED_UI.SelectorDescription(panel)
    if not panel then return "" end
    local existing=panel.DescriptionText
    if type(existing)=="string" and existing~="" then return existing end
    local name=tostring(panel.Title or "")
    if name=="Maneuvers" then
        return "Maneuvers are powerful attacks that utilize your Superiority Dice."
    end
    local handle=HB_MULTIFACETED_UI.SourceSelectorDescriptionHandles[name]
    if handle and Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok,value=pcall(Ext.Loca.GetTranslatedString,handle)
        if ok and type(value)=="string" and value~="" and value~=handle then
            return value
        end
    end
    return ""
end

local function BuildNativeHistoricalSpellChoices(wrapper,panel,originalDC,panelIndex,displayRefs,displayScanned,modelGeneration)
    local root=Ext.UI.Instantiate("se::"..historicalSpellRootType)
    if not root then error("Historical spell selector model unavailable") end
    local observedMode=panel.Kind=="ObservedSpell"
    local currentBook=IsCurrentSpellbookObservation(panel)
    local accordAdd=panel.Kind=="AccordAdd"
    local accordRecorded=panel.Kind=="AccordRecorded"
    local genericSpell=panel.Kind=="GenericSpellAdd" or panel.Kind=="GenericSpellRecorded"
    local classSpellGroup=panel.Kind=="ClassSpellGroup"
    local accordMulti=accordAdd or accordRecorded
    local isCantrip=(accordRecorded and panel.GroupedLevelOne and panel.GroupSpellCantrip)
        or (accordMulti and not panel.GroupedLevelOne)
        or (genericSpell and panel.SpellCantrip==true)
        or (classSpellGroup and panel.GroupSpellCantrip)
        or (not observedMode and not genericSpell and not accordMulti
            and panel.Other and panel.Other.Kind=="Cantrip") or false
    local expectedLevel=currentLevel
    -- In-place feat tab appends use the *current* UI generation; normal
    -- full rebuilds use the next one. Stamp the spell tile with the exact
    -- generation passed to its owning selector model, not an assumed +1.
    local expectedGeneration=modelGeneration or (nativeMenuGeneration+1)
    local key=table.concat({expectedLevel,panelIndex,panel.Kind,
        panel.Other and ChoiceKey(panel.Other) or panel.Title or "Observed"},"|")
    local filters=historicalSpellFilters[key]
    -- Model-local entries can be filtered in place without replacing BG3's
    -- gameplaySubPanel or its selected historical tab.
    local allFilterEntries={}
    local ApplyFilterInPlace=nil
    local disableHistoricalSpellFilters=true
    if not filters then
        filters={School=HB_SPELL_SCHOOLS[1],Damage=HB_SPELL_DAMAGE_TYPES[1]}
        historicalSpellFilters[key]=filters
    end
    -- Observed grants appear in Additions, never Available; their filters
    -- would be cosmetic dead controls. Disable them in view-only mode.
    root.HB_Ready=(not disableHistoricalSpellFilters) and not observedMode and #(panel.Options or {})>0
    root.HB_MenuOpen=false
    root.HB_DamageMenuOpen=false
    root.HB_Header=""
    root.HB_DamageHeader=""
    root.HB_Status=""
    local function LiveFilterContext()
        -- The historical slider rebuilds its panel table on every UI refresh;
        -- comparing an old panel object with a regenerated entry can reject
        -- a perfectly current filter click. Guard by level, generation and
        -- the active tab instead. No gameplay or spell staging occurs here.
        return previewOpen and nativePilotActive and not nativePilotWrapping
            and nativePilotMode=="historical" and currentLevel==expectedLevel
            and nativeMenuGeneration==expectedGeneration
            -- The native sidebar may lag the visible game-owned tab index.
            -- This command belongs to the currently mounted generation and
            -- cannot be invoked from an unmounted panel. Do not reject it
            -- solely because passiveGroupIndex hasn't caught up.
    end
    local function RefreshHistoricalFilter(reason)
        -- Noesis can fail to notify visibility changes inside recycled
        -- ItemsControl containers. Recreate only the historical view using
        -- the saved school/damage selections; construct a truly filtered
        -- Available collection rather than depending on visibility triggers.
        QueueOnUI(function()
            if LiveFilterContext() then
                RequestNativeHistoricalRefresh(reason)
            end
        end)
    end
    root.HB_Toggle:SetHandler(function()
        Log("NATIVE_SPELL_FILTER_EVENT type=school_menu level="..expectedLevel
            .." tab="..panelIndex.." generation="..nativeMenuGeneration
            .." activeTab="..tostring(passiveGroupIndex))
        if not LiveFilterContext() then
            Log("NATIVE_SPELL_FILTER_REJECT toggle=school level="..expectedLevel
                .." tab="..panelIndex.." generation="..nativeMenuGeneration)
            return
        end
        root.HB_MenuOpen=not root.HB_MenuOpen
        if root.HB_MenuOpen then root.HB_DamageMenuOpen=false end
    end)
    root.HB_ToggleDamage:SetHandler(function()
        Log("NATIVE_SPELL_FILTER_EVENT type=damage_menu level="..expectedLevel
            .." tab="..panelIndex.." generation="..nativeMenuGeneration
            .." activeTab="..tostring(passiveGroupIndex))
        if not LiveFilterContext() then
            Log("NATIVE_SPELL_FILTER_REJECT toggle=damage level="..expectedLevel
                .." tab="..panelIndex.." generation="..nativeMenuGeneration)
            return
        end
        root.HB_DamageMenuOpen=not root.HB_DamageMenuOpen
        if root.HB_DamageMenuOpen then root.HB_MenuOpen=false end
    end)
    for i,label in ipairs(HB_SPELL_SCHOOLS) do
        root["HB_School_"..i]:SetHandler(function()
            Log("NATIVE_SPELL_FILTER_SELECT_EVENT type=school level="..expectedLevel
                .." tab="..panelIndex.." picked="..label
                .." generation="..nativeMenuGeneration
                .." activeTab="..tostring(passiveGroupIndex))
            if not LiveFilterContext() then
                Log("NATIVE_SPELL_FILTER_REJECT select=school level="..expectedLevel)
                return
            end
            filters.School=label
            root.HB_MenuOpen=false
            root.HB_Header="Spell School: "..label
            Log("NATIVE_SPELL_FILTER level="..expectedLevel.." tab="..panelIndex
                .." school="..label.." damage="..filters.Damage)
            if ApplyFilterInPlace then ApplyFilterInPlace() end
            RefreshHistoricalFilter("spell school filter")
        end)
    end
    for i,label in ipairs(HB_SPELL_DAMAGE_TYPES) do
        root["HB_Damage_"..i]:SetHandler(function()
            Log("NATIVE_SPELL_FILTER_SELECT_EVENT type=damage level="..expectedLevel
                .." tab="..panelIndex.." picked="..label
                .." generation="..nativeMenuGeneration
                .." activeTab="..tostring(passiveGroupIndex))
            if not LiveFilterContext() then
                Log("NATIVE_SPELL_FILTER_REJECT select=damage level="..expectedLevel)
                return
            end
            filters.Damage=label
            root.HB_DamageMenuOpen=false
            root.HB_DamageHeader="Damage Type: "..label
            Log("NATIVE_SPELL_FILTER level="..expectedLevel.." tab="..panelIndex
                .." school="..filters.School.." damage="..label)
            if ApplyFilterInPlace then ApplyFilterInPlace() end
            RefreshHistoricalFilter("spell damage filter")
        end)
    end
    root.Title=observedMode and (panel.Title or "Observed Spells (View Only)")
        or (isCantrip and "Choose a Cantrip" or "Choose a Spell")
    root.Description=(genericSpell or classSpellGroup or panel.GroupedLevelOne) and "" or (observedMode and (currentBook
        and "Current spellbook spells. Their acquisition level and original source cannot be determined from this list. View only; not historical choices."
        or "These IDs occur in progression records at this level. They may be automatic class or subclass grants, not player choices. View only.")
        or (CanStageNativeSpell(panel)
            and HB_MULTIFACETED_UI.SelectorDescription(panel)
            or "Historical spell selection is read-only until its recorded source can be verified."))
    root.IsCantrips=isCantrip
    root.IsActions=false
    root.MaxAddedCount=(classSpellGroup and panel.MaxChoices)
        or (genericSpell and panel.MaxChoices)
        or (accordRecorded and panel.GroupedLevelOne and panel.MaxChoices)
        or (accordMulti and 2)
        or (observedMode and #(panel.CurrentIds or {}) or 1)
    root.AddedCount=(classSpellGroup and #CurrentEffectivePicks(panel))
        or (genericSpell and #CurrentEffectivePicks(panel))
        or (accordMulti and #(accordRecorded
            and HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel)
            or CurrentEffectivePicks(panel)))
        or (observedMode and #(panel.CurrentIds or {}) or 1)
    root.IsComplete=true
    local chosen=accordRecorded
        and HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel)
        or CurrentEffectivePicks(panel)
    local selected=tostring(chosen[1] or "")
    local pickedSet={}
    for _,id in ipairs(chosen) do pickedSet[tostring(id)]=true end
    local seen={}
    local availableCount=0
    local filteredCount=0
    local visibleFilterCount=0
    local eligibleCount=0
    local unavailableCount=0
    local labelFallbackCount=0
    local statsIconIds=0
    local reusedIcons=0
    displayRefs=displayRefs or {}
    displayScanned=displayScanned or 0
    local currentOriginalRank=(classSpellGroup
        and HistoricalSpellRankClient(tostring((panel.Rows[1] or {}).From or "")))
        or (accordRecorded and panel.GroupedLevelOne
        and HistoricalSpellRankClient(tostring((panel.Rows[1] or {}).From or "")))
        or (accordMulti and 0)
        or (genericSpell and (panel.SpellCantrip and 0 or -1))
        or (not observedMode and panel.Other
            and HistoricalSpellRankClient(tostring(panel.Other.From or "")) or nil)
    -- Native spell templates are shared with vanilla character creation.
    -- Disable *both* select and deselect on observation-only or unverified
    -- historical groups, rather than presenting an inert clickable spell.
    root.HB_HistoricalAllowClick=(not observedMode and CanStageNativeSpell(panel)
        and currentOriginalRank~=nil
        and ((isCantrip and currentOriginalRank==0)
            or (not isCantrip and (currentOriginalRank>0 or genericSpell)))) or false
    local armed=nativeSpellArmed and nativeSpellArmed.level==currentLevel
        and nativeSpellArmed.panelIndex==panelIndex
    local orderedOptions={}
    local listed={}
    local observedOnly={}
    local observedAdded=0
    for _,option in ipairs(panel.Options or {}) do
        orderedOptions[#orderedOptions+1]=option
        listed[tostring(option.PassiveId or "")]=true
    end
    -- Display catalog and replay catalog serve different purposes. A staged
    -- replacement has already passed StageChoice() against panel.Options,
    -- but some reconstructed historical panels replace/restrict their option
    -- collection during a deferred native refresh. The selected row must
    -- therefore come from CurrentEffectivePicks(), not solely Options.
    -- The original recorded choice is a second, independently proven source
    -- for a grey/available reference. These entries NEVER expand the replay
    -- candidate set used by TryStageNativeSpell/StageChoice.
    if not observedMode then
        local function DisplayRecordedSpell(id)
            id=tostring(id or "")
            if id~="" and not listed[id] then
                listed[id]=true
                orderedOptions[#orderedOptions+1]={PassiveId=id,Name=id}
            end
        end
        DisplayRecordedSpell(panel.Other and panel.Other.From)
        for _,id in ipairs(panel.CurrentIds or {}) do DisplayRecordedSpell(id) end
        for _,id in ipairs(chosen) do DisplayRecordedSpell(id) end
    end
    -- Natural BG3 spell screens briefly display the already learned spells
    -- as dimmed tiles before HB's historical ViewModel is attached. Retain
    -- their exact recorded choices after HB refreshes the page. Do not use
    -- an inferred current spellbook here: only genuinely recorded historical
    -- Spell/Cantrip rows with matching verified rank may join this display.
    -- These additions remain disabled by cross-level ownership checks.
    if not observedMode and currentOriginalRank~=nil then
        for recordedLevel=1,maximum do
            if recordedLevel~=currentLevel then
                local history=(snapshot[recordedLevel] or {}).LevelChoices or {}
                for _,recorded in ipairs(history.OtherChoices or {}) do
                    if recorded.Kind=="Spell" or recorded.Kind=="Cantrip" then
                        local mapped=(previewOther[recordedLevel] or {})[ChoiceKey(recorded)]
                        local known=tostring(mapped or recorded.From or "")
                        if known~="" and not listed[known]
                            and HistoricalSpellRankClient(known)==currentOriginalRank then
                            orderedOptions[#orderedOptions+1]={PassiveId=known, Name=known}
                            listed[known]=true
                        end
                    end
                end
            end
        end
    end
    -- The original native spell screen briefly includes known spells when
    -- entering a level, but the historical catalog is rebuilt asynchronously.
    -- Preserve *recorded* spellbook and progression observations as disabled
    -- reference tiles, never as writable historical choices. The source
    -- records supply exact IDs, not inferred acquisition levels or selectors.
    -- This intentionally does not add them to panel.Options/StageChoice.
    if not observedMode and currentOriginalRank~=nil then
        for recordedLevel=1,maximum do
            local recorded=(snapshot[recordedLevel] or {}).LevelChoices or {}
            for _,source in ipairs({"ObservedSpells","CurrentSpellbook"}) do
                for _,record in ipairs(recorded[source] or {}) do
                    local id=tostring(record.Id or "")
                    if id~="" and not listed[id]
                        and HistoricalSpellRankClient(id)==currentOriginalRank then
                        listed[id]=true
                        observedOnly[id]=source
                        orderedOptions[#orderedOptions+1]={PassiveId=id,
                            Name=tostring(record.Name or id)}
                        observedAdded=observedAdded+1
                    end
                end
            end
        end
    end
    table.sort(orderedOptions,function(a,b)
        local left=HistoricalSpellDisplayName(a.PassiveId,Label(a)):lower()
        local right=HistoricalSpellDisplayName(b.PassiveId,Label(b)):lower()
        if left==right then return tostring(a.PassiveId or "")<tostring(b.PassiveId or "") end
        return left<right
    end)
    for _,option in ipairs(orderedOptions) do
        local id=tostring(option.PassiveId or "")
        if id~="" and not seen[id] then
            seen[id]=true
            local entry=Ext.UI.Instantiate("se::"..historicalSpellType)
            entry.SpellId=id
            entry.HB_HistoricalPanelIndex=panelIndex
            -- The UI holds references across deferred Noesis transitions.
            -- A click on an old level or recycled sidebar index must never
            -- stage into a new level that happens to offer the same spell.
            entry.HB_HistoricalLevel=currentLevel
            entry.HB_HistoricalGeneration=expectedGeneration
            entry.HB_HistoricalPanelKind=tostring(panel.Kind or "")
            local takenLevel=not observedMode and not pickedSet[id]
                and SpellChosenAtOtherHistoricalLevel(id,currentLevel) or nil
            local cleanName=HistoricalSpellDisplayName(id,Label(option))
            entry.Name=cleanName
            local iconId=HistoricalSpellIconId(id)
            local unresolved=HB_HISTORICAL_UNRESOLVED_ART[id]
            -- A nonempty stat Icon isn't enough when that ID has no matching
            -- tooltip atlas asset. Hide only the confirmed non-rendering art,
            -- not a guessed substitute, and expose a readable name instead.
            local knownBlank=unresolved~=nil and iconId==unresolved
            if id=="Target_Invisibility_Greater" or id=="Target_InflictWounds"
                or id=="Target_HideousLaughter" then
                Log("NATIVE_HISTORICAL_SPELL_ART_ROUTE id="..id
                    .." icon="..tostring(iconId).." level="..currentLevel
                    .." fallback="..tostring(knownBlank or iconId==""))
            end
            entry.HB_HistoricalIconId=knownBlank and "" or iconId
            entry.HB_HistoricalMissingIcon=(iconId=="" or knownBlank)
            if knownBlank then
                Log("NATIVE_SPELL_ICON_ATLAS_UNRESOLVED id="..id
                    .." icon="..iconId.." level="..currentLevel)
            elseif iconId~="" then statsIconIds=statsIconIds+1
            else
                Log("NATIVE_SPELL_ICON_STAT_MISSING id="..id.." level="..currentLevel)
            end
            local school,damage,damageTypes=HistoricalSpellCategory(id)
            local tooltipFacts,tooltipUpcast,formattedDescription,descriptionRuns,
                rangeMeters,radiusMeters=HBRichHistoricalSpellTooltip(id)
            entry.HB_HistoricalDescription=(formattedDescription~="" and formattedDescription)
                or HBHistoricalSpellDescription(id)
            local nativeRuns=descriptionRuns
            entry.HB_HistoricalDescriptionWithUnits=(nativeRuns~=nil)
            entry.HB_HistoricalDescriptionOneUnit=(nativeRuns~=nil and nativeRuns.Count==1)
            entry.HB_HistoricalDescriptionTwoUnits=(nativeRuns~=nil and nativeRuns.Count==2)
            entry.HB_HistoricalDescriptionPrefix=nativeRuns and nativeRuns.First or ""
            entry.HB_HistoricalDescriptionMiddle=nativeRuns and nativeRuns.Middle or ""
            entry.HB_HistoricalDescriptionSuffix=nativeRuns and nativeRuns.Last or ""
            entry.HB_HistoricalDescriptionMeters1=nativeRuns and nativeRuns.Metres1 or 0
            entry.HB_HistoricalDescriptionMeters2=nativeRuns and nativeRuns.Metres2 or 0
            entry.HB_HistoricalRangeMeters=rangeMeters or 0
            entry.HB_HistoricalRadiusMeters=radiusMeters or 0
            entry.HB_HistoricalHasRange=(rangeMeters or 0)>0
            entry.HB_HistoricalHasRadius=(radiusMeters or 0)>0
            entry.HB_HistoricalDetails=tooltipFacts
            entry.HB_HistoricalUpcast=tooltipUpcast
            entry.HB_HistoricalRestriction=""
            entry.HB_HistoricalTooltip=cleanName..(takenLevel and
                ("  (already chosen at level "..tostring(takenLevel)..")") or "")
            if school~="" then entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                .." · "..school end
            if damage~="" then entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                .." · "..damage end
            -- Ext.UI Bool properties reject nil. An unselected spell used to
            -- evaluate to nil here, aborting native page construction and
            -- exposing the obsolete editor panel on the host widget.
            entry.Selected=(observedMode==true or pickedSet[id]==true) and not (armed==true)
            local rank=HistoricalSpellRankClient(id)
            entry.HB_HistoricalRankText=(rank and rank>0) and tostring(rank) or ""
            local rankLabel=(rank==0 and "Cantrip") or
                (rank and ("Level "..tostring(rank).." Spell")) or "Spell rank unknown"
            entry.HB_HistoricalSchoolRank=rankLabel..
                (school~="" and (" · "..school) or "")
            if tooltipFacts=="" and damage~="" then
                entry.HB_HistoricalDetails="Damage type: "..damage
            end
            if rank~=nil then
                entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                    ..(rank==0 and " · Cantrip" or (" · Spell level "..tostring(rank)))
            else
                entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                    .." · Spell rank not verified (view only if unavailable)"
            end
            -- A spell's static spell rank is not the historical caster level.
            -- We can safely display a verified rank, but cannot infer a
            -- previously available slot or feat-specific prerequisites.
            -- Unlike vanilla level-up's hidden unavailable entries, HB's
            -- historical spell list keeps incompatible candidates visible
            -- but clearly disabled, matching historical passive/feat locks.
            -- Unknown ranks cannot be staged safely: fail closed here rather
            -- than presenting a clickable entry that rejects on selection.
            local rankMismatch=rank==nil or currentOriginalRank==nil
                or (genericSpell and ((isCantrip and rank~=0) or (not isCantrip and rank==0)))
                or (not genericSpell and rank~=currentOriginalRank)
            -- Keep an already chosen spell in the available grid as a
            -- disabled/dimmed reference, like vanilla's taken spell tiles.
            -- Its separate Selected-strip button must remain removable.
            local alreadySelected=(not observedMode and pickedSet[id] and not armed)
            local isObservedOnly=(observedOnly[id]~=nil)
            entry.NotAvailable=not observedMode and
                (rankMismatch or takenLevel~=nil or alreadySelected or isObservedOnly) or false
            entry.HB_HistoricalSelectable=root.HB_HistoricalAllowClick
                and not rankMismatch and takenLevel==nil and not isObservedOnly
            entry.HB_HistoricalAvailableSelectable=entry.HB_HistoricalSelectable
                and not alreadySelected
            if entry.NotAvailable then
                unavailableCount=unavailableCount+1
                if alreadySelected then
                    entry.HB_HistoricalRestriction="Currently Selected"
                elseif isObservedOnly then
                    entry.HB_HistoricalRestriction="Known spell ("..observedOnly[id]..") · acquisition level not verified; view only"
                elseif takenLevel then
                    entry.HB_HistoricalRestriction="Selected at Level "..tostring(takenLevel)
                elseif rank==nil or currentOriginalRank==nil then
                    entry.HB_HistoricalRestriction="Unavailable: spell rank cannot be verified"
                else
                    entry.HB_HistoricalRestriction="Unavailable: different spell rank"
                end
                if alreadySelected then
                    entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                        .." · Already selected; use the selected tile to remove"
                elseif isObservedOnly then
                    entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                        .." · Known spell, historical acquisition unverified (view only)"
                elseif takenLevel then
                    entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                        .." · Unavailable: already chosen at another level"
                elseif rank==nil or currentOriginalRank==nil then
                    entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                        .." · Unavailable: spell rank could not be verified"
                else
                    entry.HB_HistoricalTooltip=entry.HB_HistoricalTooltip
                        .." · Unavailable: different spell rank"
                end
            end
            local spell=Ext.UI.Instantiate("se::"..historicalSpellIconType)
            spell.Level=rank or 0
            spell.DisplayName=cleanName
            local displaySpell=displayRefs[id]
            entry.HB_HistoricalTooltipContent=entry
            entry.HB_HistoricalNativeTooltip=false
            if displaySpell then
                local accepted=pcall(function() entry.Spell=displaySpell end)
                if accepted then
                    reusedIcons=reusedIcons+1
                    entry.HB_HistoricalTextOnly=false
                    -- A real original game object can invoke the game's
                    -- native tooltip template. The detached synthetic entry
                    -- itself cannot, despite having an identical spell ID.
                    local typeName=tostring(Read(displaySpell,"Type") or "")
                    if typeName:find("VMCharacterCreationSpell",1,true)
                        or typeName:find("VMTooltipSpell",1,true)
                        or typeName:find("VMFeatureSpell",1,true)
                        or typeName:find("VMCharacterAction",1,true) then
                        entry.HB_HistoricalTooltipContent=displaySpell
                        entry.HB_HistoricalNativeTooltip=true
                    end
                else
                    entry.Spell=spell
                    entry.HB_HistoricalTextOnly=true
                end
            else
                entry.Spell=spell
                entry.HB_HistoricalTextOnly=true
            end
            if entry.HB_HistoricalTextOnly then labelFallbackCount=labelFallbackCount+1 end
            if (observedMode or pickedSet[id]) and not armed then
                -- Noesis can recycle an item that appears in two different
                -- ItemsControls during deferred CharacterRespec refreshes.
                -- Give Selected its own historical entry: the available-grid
                -- copy is disabled while this independent copy stays removable.
                local picked=Ext.UI.Instantiate("se::"..historicalSpellType)
                for _,field in ipairs({"SpellId","HB_HistoricalPanelIndex",
                    "HB_HistoricalLevel","HB_HistoricalGeneration","HB_HistoricalPanelKind","Name",
                    "Spell","Selected","HB_HistoricalSelectable",
                    "HB_HistoricalTextOnly","HB_HistoricalIconId",
                    "HB_HistoricalMissingIcon","HB_HistoricalRankText",
                    "HB_HistoricalTooltip","HB_HistoricalSchoolRank",
                    "HB_HistoricalDescriptionWithUnits","HB_HistoricalDescriptionOneUnit",
                    "HB_HistoricalDescriptionTwoUnits","HB_HistoricalDescriptionPrefix",
                    "HB_HistoricalDescriptionMiddle","HB_HistoricalDescriptionSuffix",
                    "HB_HistoricalDescriptionMeters1","HB_HistoricalDescriptionMeters2",
                    "HB_HistoricalRangeMeters","HB_HistoricalRadiusMeters",
                    "HB_HistoricalHasRange","HB_HistoricalHasRadius",
                    "HB_HistoricalDescription","HB_HistoricalDetails",
                    "HB_HistoricalUpcast","HB_HistoricalRestriction","HB_HistoricalTooltipContent",
                    "HB_HistoricalNativeTooltip"}) do
                    local value=Read(entry,field)
                    if value~=nil then picked[field]=value end
                end
                picked.NotAvailable=false
                picked.HB_HistoricalAvailableSelectable=false
                root.Additions[#root.Additions+1]=picked
            end
            -- In editable historical groups, keep the chosen option in the
            -- same sorted available list, disabled and dimmed instead of
            -- removing it after the native data model refreshes. Reuse the
            -- entry safely with distinct per-button enable properties.
            if not observedMode then
                availableCount=availableCount+1
                if not entry.NotAvailable then eligibleCount=eligibleCount+1 end
                allFilterEntries[#allFilterEntries+1]={Entry=entry,School=school,DamageTypes=damageTypes}
                -- Historical level 2+ spell panels no longer expose school/
                -- damage sorting. Keep every verified candidate visible and
                -- preserve the original level-one/vanilla filter UI elsewhere.
                entry.HB_HistoricalFilterVisible=true
                root.Available[#root.Available+1]=entry
                visibleFilterCount=visibleFilterCount+1
                if not entry.NotAvailable then filteredCount=filteredCount+1 end
            end
        end
    end
    -- Keep the ItemsSource stable and mutate notify-enabled per-tile visibility
    -- instead. Unlike Clear()/refill, this works with a Noesis ItemsControl
    -- already bound to a historical level's generated spell selector.
    ApplyFilterInPlace=function()
        root.HB_Status=""
        return true
    end
    root.AddedCount=#root.Additions
    if not observedMode and panel.Kind=="Other" and panel.Other
        and panel.Other.Kind=="Spell" and root.AddedCount==0 then
        local live=HB_NATIVE_L1_SLIDER.LiveSpellSwap
        local cleared=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
        if cleared[currentLevel] and cleared[currentLevel][ChoiceKey(panel.Other)] then
            Log("NATIVE_L1_SPELL_DISPLACED_EMPTY level="..tostring(currentLevel)
                .." newL1="..tostring(live and live.To)
                .." original="..tostring(panel.Other.From).." selected=0/1")
        end
    end
    root.IsComplete=observedMode
        or root.AddedCount==(classSpellGroup and panel.MaxChoices
            or (genericSpell and panel.MaxChoices)
            or (accordRecorded and panel.GroupedLevelOne and panel.MaxChoices)
            or (accordMulti and 2 or 1))
    -- The sidebar and selected-tile row already communicate completeness.
    -- Keep the filter's useful empty-result notice, not the noisy counts.
    root.HB_Status=""
    -- Native sidebar marks a half-finished historical selector as incomplete.
    wrapper.IsComplete=root.IsComplete
    wrapper.HB_HistoricalSpellModel=root
    local selectedName=HistoricalSpellDisplayName(selected,selected)
    wrapper.HB_HistoricalSpellSummary=classSpellGroup and
        (tostring(root.AddedCount).."/"..tostring(panel.MaxChoices).." selected")
        or genericSpell and
        (("%d/%d selected"):format(root.AddedCount,panel.MaxChoices))
        or accordMulti and
        (("Accord of the Arcane: %d/2 cantrips selected"):format(root.AddedCount))
        or observedMode and
        ((currentBook and "Current spellbook" or "Observed progression spells")
        ..": "..#root.Additions.." (view only; not proven historical choices).")
        or ((root.AddedCount==0 and "Choose a replacement spell (0/1 selected).")
            or ("Previously selected: "..tostring(selectedName)
                ..". Native spell images may be missing when the active respec offers no matching reference."))
    Log("NATIVE_SPELL_VISUAL_MODEL level="..tostring(currentLevel)
        .." kind="..tostring(panel.Kind == "Other" and panel.Other and panel.Other.Kind or panel.Kind)
        .." selected="..selected.." additions="..#root.Additions
        .." available="..availableCount.." visibleFiltered="..filteredCount
        .." totalEligible="..eligibleCount.." school="..filters.School
        .." damage="..filters.Damage.." nativeIcons="..reusedIcons
        .." statIconIds="..statsIconIds
        .." unavailable="..unavailableCount.." textFallback="..labelFallbackCount
        .." observedReadonly="..tostring(observedAdded)
        .." originalRank="..tostring(currentOriginalRank)
        .." enabled="..tostring(root.HB_HistoricalAllowClick)
        .." scanned="..displayScanned.." mode="
        ..(observedMode and "READ_ONLY_OBSERVED" or
          CanStageNativeSpell(panel) and "RANK_GUARDED_EDIT" or "READ_ONLY_UNVERIFIED"))
end

local function NativePanelDisplayName(panel)
    if panel then return tostring(panel.Title or "Historical Choices") end
    local choice=(snapshot[currentLevel] or {}).LevelChoices or {}
    return choice.HistoryAvailable==false and "History unavailable"
        or "Nothing to select at this level"
end
local function FindNativeBasePassiveGroup(originalDC)
    for _,field in ipairs({"ClassPassives","ClassAndSubClassPassives"}) do
        local col=Read(originalDC,field)
        local count=CollectionCount(col) or 0
        for i=0,count-1 do
            local item=GetCollectionItem(col,i)
            if Read(item,"Type")=="ls.VMCharacterCreationPassives" then
                return item,field,i
            end
        end
    end
    return nil
end
-- Every independent historical selection on a character level is exposed as
-- a genuine BG3 passive subtab. The game's original left sidebar selects the
-- tabs; there is no separate HB group carousel or group navigation button.
-- The engine rejects duplicate nonrepeatable passives across historical
-- levels, including LATER ones. Expose that constraint to the player before
-- they click; the backend remains authoritative. Resolve staged replacements
-- from the recorded selector key rather than inspecting the live character.

-- The resource selector uses one globally unique pick of each resource type
-- across historical levels. Include staged edits; never infer a missing grant.
local function HistoricalResourceTakenOnOtherLevel(id,excludedLevel)
    id=tostring(id or "")
    if id=="" then return nil end
    for level=1,maximum do
        if level~=excludedLevel then
            local data=(snapshot[level] or {}).LevelChoices or {}
            for _,original in ipairs(data.ExtraResources or {}) do
                local effective=tostring(previewResources[level] or original)
                if effective==id then return level end
            end
        end
    end
    return nil
end

-- Compute the checkbox marks and the sidebar count from the SAME staged
-- historical state.  A click can temporarily empty one passive slot without
-- changing its original recorded selection (the replacement is not committed
-- until the player picks the new passive).
function HB_MULTIFACETED_UI.HistoricalPassiveVisualSelection(panel,panelIndex)
    local visible=panel and panel.Kind=="AccordRecorded"
        and HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel)
        or HB_MULTIFACETED_UI.VisiblePicks(panel)
    local picked={}
    for _,id in ipairs(visible) do picked[tostring(id)]=true end
    if panel and panelIndex==passiveGroupIndex and armedFrom~=nil then
        if panel.Kind=="Passive" then
            local staged=(snapshot[currentLevel] or {})._HB_PreviewStaged or {}
            local from=tostring(armedFrom)
            local group=panel.Group or {}
            local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..from
            picked[tostring(staged[key] or from)]=nil
        elseif panel.Kind=="Resource" then
            -- UI-only empty 0/1 slot. The last committed resource is kept
            -- unchanged until an eligible replacement is staged successfully.
            picked[tostring(armedFrom)]=nil
        end
    end
    local count=0
    for _ in pairs(picked) do count=count+1 end
    return picked,count
end

local function BuildHistoricalModels(originalDC,modelGeneration)
    local _,panels=ActivePanel()
    if not RegisterHistoricalModels() then error("Noesis model registration unavailable") end
    nativeHistoricalItems={}
    local nativeBase,field,index=FindNativeBasePassiveGroup(originalDC)
    if not nativeBase then error("Native ClassPassives template host unavailable") end
    local details=Ext.UI.Instantiate("se::"..historicalDetailType)
    if not details then error("Native historical progression details unavailable") end
    local selections={}
    local models=#panels>0 and panels or {false}
    local displayRefs,displayScanned=nil,nil
    passiveRows={}
    for panelIndex,panelValue in ipairs(models) do
        local panel=panelValue or nil
        local selection=Ext.UI.Instantiate("se::"..historicalGroupType,nativeBase)
        if not selection then error("Native passive subtab instantiation failed at "..panelIndex) end
        local name=NativePanelDisplayName(panel)
        selection.Name=name
        selection.HB_HistoricalPanelIndex=panelIndex
        selection.HB_HistoricalGeneration=modelGeneration or (nativeMenuGeneration+1)
        selection.HB_HistoricalRenderKind=(panel and IsRecordedFeatPanel(panel)) and "Feat"
            or (panel and IsRecordedSpellPanel(panel)) and "Spell" or "Selections"
        selection.UpdateState="New"
        selection.IsComplete=true
        local description=Ext.UI.Instantiate("se::"..historicalDescriptionType)
        local editable=panel and panel.Editable
        -- The ordinary BG3 selector has a name, count and selectable items;
        -- it does not display instructions about HB's historical implementation.
        -- Retain only meaningful context where no editable choice exists.
        if panel and panel.Kind=="Origin" then
            description.Text=tostring(panel.DescriptionText or "")
        elseif panel and panel.Kind=="Empty" then
            description.Text=panel.Title=="History unavailable"
                and "Original choices unavailable." or "There are no choices to be made for this level."
        else
            description.Text=HB_MULTIFACETED_UI.SelectorDescription(panel)
        end
        selection.Description=description
        local chosen=CurrentEffectivePicks(panel)
        local picked,displayCount=HB_MULTIFACETED_UI.HistoricalPassiveVisualSelection(panel,panelIndex)
        local expectedSlots=#chosen
        selection.MaxSelectedPassiveCount=panel and
            (panel.Kind=="GenericPassiveAdd" or panel.Kind=="GenericSpellAdd"
                or panel.Kind=="GenericSpellRecorded") and panel.MaxChoices
            or (panel and (panel.Kind=="ElementAdd" or panel.Kind=="PassivePairAdd") and 2)
            or ((panel.Kind=="AccordAdd" or panel.Kind=="AccordRecorded")
                and (panel.MaxChoices or 2))
            or (panel.Kind=="MultifacetedAdd" and panel.MaxChoices)
            or (panel and panel.Kind=="MultifacetedSkills" and (panel.MaxChoices or 4))
            or math.max(expectedSlots,panel and #panel.CurrentIds or 0)
        selection.SelectedPassiveCount=displayCount
        selection.IsComplete=displayCount==selection.MaxSelectedPassiveCount
        local seen={}
        local optionCount=0
        for _,option in ipairs(panel and panel.Options or {}) do
            local id=tostring(option.PassiveId or "")
            if id~="" and not seen[id] then
                seen[id]=true
                local item=Ext.UI.Instantiate("se::"..historicalItemType)
                item.PassiveId=id
                item.HB_HistoricalPanelIndex=panelIndex
                item.HB_HistoricalLevel=currentLevel
                item.HB_HistoricalGeneration=modelGeneration or (nativeMenuGeneration+1)
                item.Value=picked[id] and 1 or 0
                local takenElsewhere=panel and not picked[id]
                    and (((panel.Kind=="Passive" or panel.Kind=="PassivePairAdd"
                        or panel.Kind=="GenericPassiveAdd"
                        or (panel.Kind=="MultifacetedAdd" and panel.Section~="Skills"))
                        and HistoricalPassiveTakenOnOtherLevel(id,currentLevel))
                        or (panel.Kind=="MultifacetedAdd" and panel.Section=="Skills"
                            and HistoricalSkillTakenOnOtherLevel(id,currentLevel))
                        or (panel.Kind=="Resource" and HistoricalResourceTakenOnOtherLevel(id,currentLevel))
                        or (panel.Kind=="MultifacetedSkills"
                            and HistoricalSkillTakenOnOtherLevel(id,currentLevel))
                        or (panel.Kind=="Other" and panel.Other
                            and tostring(panel.Other.Kind)=="Skill"
                            and tostring(panel.Other.FeatOwnerId or "")
                                =="be0889d2-f9aa-472d-b942-592bff0f1ef3"
                            and HistoricalSkillTakenOnOtherLevel(id,currentLevel)))
                item.Name=Label(option)..(takenElsewhere and
                    ("  [Lv. "..tostring(takenElsewhere).."]") or "")
                item.HB_HistoricalPassiveDescription=HistoricalPassiveDescription(id)
                item.HB_HistoricalTakenElsewhere=(takenElsewhere~=nil and takenElsewhere~=false)
                item.HB_HistoricalTakenNotice=takenElsewhere and
                    ("Already selected at level "..tostring(takenElsewhere)) or ""
                local invalidExpertise=panel and panel.GroupedLevelOne
                    and panel.GroupKind=="Expertise"
                    and not HB_MULTIFACETED_UI.LevelOneExpertiseEligible(panel,id)
                item.Enabled=(editable==true and not takenElsewhere and not invalidExpertise)
                item.Blocked=(editable~=true or not not takenElsewhere
                    or invalidExpertise==true)
                item.Replaced=false
                item.IconName=""
                selection.Passives[#selection.Passives+1]=item
                nativeHistoricalItems[id]=nativeHistoricalItems[id] or {}
                nativeHistoricalItems[id][panelIndex]=true
                optionCount=optionCount+1
            end
        end
        -- Each left-hand entry owns its own real-game template adapter. Do
        -- not make every entry show the same global feat/spell panel.
        if panel and IsRecordedFeatPanel(panel) then
            BuildNativeHistoricalFeatChoices(selection,panel,panelIndex)
        elseif panel and IsRecordedSpellPanel(panel) then
            if displayRefs==nil then
                displayRefs,displayScanned=BuildNativeSpellDisplayLookup(originalDC)
            end
            BuildNativeHistoricalSpellChoices(selection,panel,originalDC,panelIndex,
                displayRefs,displayScanned,modelGeneration)
        end
        details.NotSubPassiveSelectors[#details.NotSubPassiveSelectors+1]=selection
        selections[#selections+1]=selection
        Log("NATIVE_HISTORICAL_MODEL level="..currentLevel
            .." tab="..panelIndex.."/"..#models
            .." kind="..tostring(panel and panel.Kind or "Empty")
            .." group="..name.." options="..optionCount.." selected="..#chosen
            .." host="..tostring(field).."["..tostring(index).."]")
    end
    return selections,details,panels[passiveGroupIndex],panels
end

-- Native selector template is now attached by the pre-existing XAML
-- gameplayTabPassiveSelectorTemplate. We inspect the live presenter afterward.
local function NativeHistoricalFindVisual()
    local _,name,widget=NativeVM()
    if not widget then return nil,"Native widget missing" end
    local nodes={widget};local n=1;local seen=0
    while n<=#nodes and seen<3600 do
        local node=nodes[n];n=n+1;seen=seen+1
        if Read(node,"Name")=="gameplaySubPanel" then
            return node,"nodes="..seen.." widget="..tostring(name)
        end
        local count=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,160)
        for i=1,count do
            local ok,child=pcall(function() return node:VisualChild(i) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    return nil,"nodes="..seen.." widget="..tostring(name)
end

-- Empty levels have no genuine native choice tab to fire a selection
-- change. Assign their one generated no-choices proxy explicitly to the
-- existing BG3 gameplaySubPanel; do not leave the previous level rendered.
-- The fresh proxy is read from the *current* wrapper and never stored in a
-- long-lived Lua upvalue (Noesis proxies are generation-sensitive).
local function HasEmptyHistoricalPanel()
    local panels=AllPanels()
    return #panels==1 and panels[1].Kind=="Empty"
end
local function BindEmptyHistoricalContent(expectedLevel,expectedGeneration,context)
    if not HasEmptyHistoricalPanel() or currentLevel~=expectedLevel
        or nativeMenuGeneration~=expectedGeneration
        or not nativePilotActive or nativePilotWrapping then return false end
    local live=NativeVM()
    local empty=Read(live,"HB_HistoricalEmptyGroup")
    -- There is deliberately no fallback to NotSubPassiveSelectors[0]:
    -- live Noesis indexed reads returned a previous group in BG3.
    local details=Read(live,"ClassProgressionDetails")
    local groups=Read(details,"NotSubPassiveSelectors")
    local title=tostring(Read(empty,"Name") or "")
    if title~="N/A" and title~="History unavailable" then
        Log("NATIVE_EMPTY_BIND_REFUSED origin="..tostring(context)
            .." level="..tostring(expectedLevel)
            .." title="..title.." groupCount="..tostring(CollectionCount(groups)))
        return false
    end
    local content=NativeHistoricalFindVisual()
    if not content then
        Log("NATIVE_EMPTY_BIND_PENDING origin="..tostring(context)
            .." level="..tostring(expectedLevel).." reason=missing_content_panel")
        return false
    end
    -- Force the existing native ContentPresenter to use a new, verified
    -- no-choice group. Simply switching the Level slider leaves the former
    -- genuine BG3 passive template visible when the new level has no tab.
    local ok,why=pcall(function() content.DataContext=empty end)
    Log("NATIVE_EMPTY_BIND origin="..tostring(context)
        .." level="..tostring(expectedLevel).." ok="..tostring(ok)
        .." error="..tostring(why)
        .." rendered="..tostring(Read(Read(content,"DataContext"),"Name")))
    return ok
end

local nativeHistoricalTemplateWasActive=false
local function ActivateNativeHistoricalTab(expectedLevel,expectedGeneration)
    if not previewOpen or not nativePilotActive or nativePilotMode~="historical"
       or nativePilotWrapping or currentLevel~=expectedLevel
       or nativeMenuGeneration~=expectedGeneration then return end
    local _,name,root=NativeVM()
    if not root then return end
    if HasEmptyHistoricalPanel() then
        -- This also handles native screens where the subtab ListBox has
        -- no visible container for a historical level with zero choices.
        BindEmptyHistoricalContent(expectedLevel,expectedGeneration,"activate_begin")
    end
    local nodes={root};local cursor=1
    while cursor<=#nodes and cursor<2600 do
        local node=nodes[cursor];cursor=cursor+1
        if Read(node,"Name")=="subTabsPassivesList" then
            local idx=tonumber(Read(node,"SelectedIndex"))
            -- The native passive subtab's IsSelected trigger populates the
            -- main content panel. Re-selecting it is safe: it changes only
            -- the UI selection, never an in-game class/passive choice.
            local count=CollectionCount(Read(node,"ItemsSource"))
            local target=math.max(0,math.min(#AllPanels()-1,passiveGroupIndex-1))
            local ok,err=pcall(function()
                -- On a level change, a newly-created historical proxy may
                -- reuse the same ListBox index as the old level. Always
                -- deselect then reselect so Noesis rebinds gameplaySubPanel,
                -- including when the destination level has no choices.
                node.SelectedIndex=-1
                node.SelectedIndex=target
            end)
            Log("NATIVE_HISTORY_TAB_SELECT level="..expectedLevel
                .." native="..tostring(name).." previous="..tostring(idx)
                .." items="..tostring(count).." selected="..tostring(target).." ok="..tostring(ok)
                .." error="..tostring(err))
            -- Read back the game's actual ContentTemplate AFTER the native
            -- sidebar selection trigger has run. This is a harmless visual
            -- diagnostic, not a UI mutation: it distinguishes a rendered
            -- feat/spell template from a successfully-created but unused VM.
            QueueOnUI(function()
                if not previewOpen or not nativePilotActive or nativePilotWrapping
                    or nativeMenuGeneration~=expectedGeneration
                    or currentLevel~=expectedLevel then return end
                local content=NativeHistoricalFindVisual()
                local dc=Read(content,"DataContext")
                local expected=AllPanels()[target+1]
                if HasEmptyHistoricalPanel() then
                    BindEmptyHistoricalContent(expectedLevel,expectedGeneration,"tab_reselected")
                    dc=Read(content,"DataContext")
                elseif expected and IsRecordedSpellPanel(expected) then
                    -- A Noesis spell presenter can retain its prior view while
                    -- the wrapper and its staged count move to the next
                    -- generation. Rebind ONLY if the visible presenter is
                    -- provably old, using a group owned by this live wrapper.
                    local live=NativeVM()
                    local exact=Read(live,"HB_HistoricalCurrentSpellGroup")
                    local displayed=tonumber(Read(dc,"HB_HistoricalGeneration"))
                    local targetGeneration=tonumber(Read(exact,"HB_HistoricalGeneration"))
                    local targetIndex=tonumber(Read(exact,"HB_HistoricalPanelIndex"))
                    if exact and targetGeneration==expectedGeneration
                        and targetIndex==target+1
                        and displayed~=expectedGeneration then
                        local success,why=pcall(function() content.DataContext=exact end)
                        Log("NATIVE_SPELL_PRESENTER_REBIND level="..expectedLevel
                            .." tab="..(target+1).." previousGeneration="..tostring(displayed)
                            .." expectedGeneration="..expectedGeneration
                            .." ok="..tostring(success).." error="..tostring(why))
                        if success then dc=Read(content,"DataContext") end
                    end
                end
                Log("NATIVE_HISTORICAL_CONTENT_ROUTE level="..tostring(expectedLevel)
                    .." tab="..tostring(target+1)
                    .." expected="..tostring(expected and expected.Kind or "Empty")
                    .." renderedKind="..tostring(Read(dc,"HB_HistoricalRenderKind"))
                    .." renderedName="..tostring(Read(dc,"Name"))
                    .." templateType="..tostring(Read(Read(content,"ContentTemplate"),"Type"))
                    .." panelType="..tostring(Read(content,"Type")))
            end)
            return
        end
        local childCount=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,140)
        for j=1,childCount do
            local ok,child=pcall(function() return node:VisualChild(j) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    Log("NATIVE_HISTORY_TAB_MISSING level="..expectedLevel.." traversed="..tostring(cursor-1))
    if HasEmptyHistoricalPanel() then
        BindEmptyHistoricalContent(expectedLevel,expectedGeneration,"missing_tab")
    end
end

local function DiagnoseNativeTabTags()
    if nativeKnownTagsLogged then return end
    local _,screen,widget=NativeVM()
    if not widget then return end
    local nodes={widget}; local i=1; local printed=0; local seen={}
    while i<=#nodes and i<1600 do
        local item=nodes[i]; i=i+1
        local t=tostring(Read(item,"Type") or "")
        local tag=Read(item,"Tag")
        if tag~=nil and (t:find("ListBoxItem",1,true) or t:find("ContentControl",1,true)) then
            local key=tostring(tag)
            if not seen[key] and printed<35 then
                seen[key]=true;printed=printed+1
                Log("NATIVE_SIDEBAR_TAG tag="..key.." type="..t
                    .." visibility="..tostring(Read(item,"Visibility")))
            end
        end
        local n=math.min(tonumber(Read(item,"VisualChildrenCount")) or 0,160)
        for k=1,n do
            local ok,child=pcall(function() return item:VisualChild(k) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    nativeKnownTagsLogged=true
    Log("NATIVE_SIDEBAR_SCAN nodes="..tostring(i-1).." tags="..tostring(printed))
end

local function NativeHistoricalApplyTemplate()
    if not nativePilotActive or nativePilotWrapping or nativePilotMode~="historical" then return end
    local subpanel,stats=NativeHistoricalFindVisual()
    if not subpanel then
        Log("NATIVE_DIRECT_TRIGGER_PANEL_MISSING "..tostring(stats))
        return
    end
    local templ=Read(subpanel,"ContentTemplate")
    DiagnoseNativeTabTags()
    nativeHistoricalTemplateWasActive=(templ~=nil)
    Log("NATIVE_DIRECT_TRIGGER_CHECK "..tostring(stats)
        .." panel="..tostring(Read(subpanel,"Type"))
        .." template="..tostring(Read(templ,"Type"))
        .." templateNil="..tostring(templ==nil)
        .." dataContext="..tostring(Read(Read(subpanel,"DataContext"),"Type")))
end


-- Read the native sidebar selection rather than assigning a separate
-- selection control. On template transitions the ListBox index can briefly be
-- -1, so the selected content group's Name is the secondary source.
local function NativeHistoricalSelectedTabIndex()
    local _,_,widget=NativeVM()
    if not widget then return nil end
    local nodes={widget};local cursor=1
    local panelName=nil
    while cursor<=#nodes and cursor<3500 do
        local node=nodes[cursor];cursor=cursor+1
        local name=Read(node,"Name")
        if name=="subTabsPassivesList" then
            local index=tonumber(Read(node,"SelectedIndex"))
            if index and index>=0 then return index+1 end
        elseif name=="gameplaySubPanel" then
            local active=Read(node,"DataContext")
            local activeIndex=tonumber(Read(active,"HB_HistoricalPanelIndex"))
            if activeIndex and AllPanels()[activeIndex] then return activeIndex end
            panelName=Read(active,"Name")
        end
        local count=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,120)
        for j=1,count do
            local ok,child=pcall(function() return node:VisualChild(j) end)
            if ok and child then nodes[#nodes+1]=child end
        end
    end
    if panelName~=nil then
        local panels=AllPanels()
        local match=nil
        for index,panel in ipairs(panels) do
            if tostring(panel.Title)==tostring(panelName) then
                -- Multiple recorded spells or feats often share a title.
                -- Never guess the selected tab from a non-unique label.
                if match then
                    Log("NATIVE_HISTORY_TAB_AMBIGUOUS_NAME level="..tostring(currentLevel)
                        .." name="..tostring(panelName))
                    return nil
                end
                match=index
            end
        end
        return match
    end
    return nil
end

local function ResolveNativeHistoricalClickGroup(id,param)
    -- Stale Noesis items can fire after the slider or original C++ content
    -- changes. Historical IDs alone do not identify the *generation* of a
    -- choice. Fail closed on an item from any detached screen or prior level.
    local stampedLevel=tonumber(Read(param,"HB_HistoricalLevel"))
    local stampedGeneration=tonumber(Read(param,"HB_HistoricalGeneration"))
    if stampedLevel~=currentLevel or stampedGeneration~=nativeMenuGeneration then
        return nil,"historical item belongs to a different level or menu generation"
    end
    local members=nativeHistoricalItems[tostring(id)]
    if not members then return nil,"unknown historical option" end
    local declared=tonumber(Read(param,"HB_HistoricalPanelIndex"))
    if declared then
        -- An explicit historical tab ID must agree with the option's actual
        -- membership. Falling back to a nearby tab could stage the wrong
        -- selection after a delayed native UI click or refresh.
        if members[declared] then return declared end
        return nil,"option's declared historical tab does not match its catalog"
    end
    local selected=NativeHistoricalSelectedTabIndex()
    if selected and members[selected] then return selected end
    -- Some native UI events fire after SelectedIndex is reset to -1.
    -- Only resolve from ID alone if exactly one historical tab offers it.
    local single=nil
    for index in pairs(members) do
        if single then return nil,"ambiguous option belongs to several tabs" end
        single=index
    end
    return single,nil
end

-- Keep the real native checkbox renderer in sync with HB's *staged* state.
-- The historical click command stages edits, but BG3's native C++ model no
-- longer owns these se:: checkbox items. Without a manual refresh, their
-- Value properties keep the checkmarks from when the panel was constructed.
-- Do not retain live se:: checkbox proxies across wrapper generations. BG3's
-- Noesis collection indexed reads have returned the wrong group and sometimes
-- the same item twice. Rebuild the detached historical VM from staged IDs
-- instead. This is the same safe, generation-guarded refresh path used for
-- native historical feats; it never touches a character's live progression.
local function SyncNativeHistoricalCheckmarks(reason)
    if not nativePilotActive or nativePilotWrapping
        or nativePilotMode~="historical" then return end
    Log("NATIVE_HISTORICAL_REFRESH_AFTER_CLICK reason="..tostring(reason)
        .." level="..tostring(currentLevel)
        .." group="..tostring(passiveGroupIndex)
        .." armed="..tostring(armedFrom))
    RequestNativeHistoricalRefresh("native passive selection")
end

local function HandleHistoricalNativeClick(param)
    local id=Read(param,"PassiveId")
    local display=Read(param,"Name")
    nativePilotClicks=nativePilotClicks+1
    Log("NATIVE_HISTORICAL_CLICK count="..nativePilotClicks
        .." level="..currentLevel
        .." itemType="..tostring(Read(param,"Type") or type(param))
        .." passiveId="..tostring(id).." name="..tostring(display))
    local panelIndex,groupError=nil,"missing option ID"
    if id then panelIndex,groupError=ResolveNativeHistoricalClickGroup(id,param) end
    if not panelIndex then
        nativePilotReport="Native click could not identify its historical choice tab: "..tostring(groupError)
        Log("NATIVE_HISTORICAL_CLICK_REJECT reason="..tostring(groupError).." id="..tostring(id))
        return
    end
    -- The choice item already carries its own validated historical panel,
    -- generation and level. Never traverse CharacterRespec's changing visual
    -- tree during a click: its sidebar may be half-rebound, and an exception
    -- here previously aborted clicks before the staging result was logged.
    Log("NATIVE_HISTORICAL_ROUTE level="..currentLevel
        .." tab="..panelIndex.." id="..tostring(id))
    if passiveGroupIndex~=panelIndex then
        -- Never carry a half-armed passive change from one native tab to another.
        passiveGroupIndex=panelIndex
        armedFrom=nil
        -- Level-one grouped Skills/Expertise may have pending slots in a
        -- different tab. Do not erase them when changing native subtabs.
        if currentLevel~=1 then HB_MULTIFACETED_UI.Clear() end
        passiveFeedback=""
        Log("NATIVE_HISTORICAL_TAB_SWITCH level="..currentLevel.." tab="..panelIndex)
    end
    local panel=ActivePanel()
    if not panel then
        nativePilotReport="No recorded choices at this level."
        return
    end
    -- Rebuild the row index from this historical level/group, never reuse
    -- rows created for the previous level by the old preview overlay.
    local index
    passiveRows={}
    for _,option in ipairs(panel.Options or {}) do
        local optionId=tostring(option.PassiveId or "")
        if optionId~="" then
            passiveRows[#passiveRows+1]={Id=optionId,Name=Label(option)}
            if optionId==tostring(id) then index=#passiveRows end
        end
    end
    if not index then
        nativePilotReport="Passive found but historical row mapping missing."
        return
    end
    Log("NATIVE_HISTORICAL_STAGE_BEGIN level="..currentLevel
        .." tab="..panelIndex.." id="..tostring(id)
        .." kind="..tostring(panel.Kind))
    local didStage=StageChoice(index)
    if panel.Kind=="ElementAdd" or panel.Kind=="PassivePairAdd"
        or panel.Kind=="GenericPassiveAdd" then
        -- Unlike ordinary half-armed passive edits, failure to attach an
        -- element to its staged feat is unexpected and must be visible. A
        -- missing callback otherwise looks exactly like a dead checkbox.
        nativeCommitError=didStage and "" or
            (tostring(panel.Kind=="ElementAdd" and "Elemental Adept" or panel.Title)
                ..": "..tostring(passiveFeedback))
    end
    Log("NATIVE_HISTORICAL_STAGE_RESULT level="..currentLevel
        .." tab="..panelIndex.." id="..tostring(id)
        .." accepted="..tostring(didStage)
        .." armed="..tostring(armedFrom)
        .." feedback="..tostring(passiveFeedback))
    nativePilotReport=tostring(display or id)..": "..tostring(passiveFeedback)
    SyncHistoricalConfirmEnabled("passive choice")
    -- Update the actual clicked Noesis item (Value is a Notify=true Double)
    -- and its currently mounted selector count. This is the same working
    -- in-place approach formerly limited to GenericPassiveAdd, extended to
    -- the checkbox-style passive groups whose clicks change only that item's
    -- checked state. One-click replacement rows beyond Resource can change a
    -- *different* item too, so they retain the existing full-refresh path.
    -- Refreshing the
    -- entire character creation wrapper for each click can update the 1/2
    -- count while leaving a stale checked item presenter on screen. That also
    -- makes the next replacement click appear unresponsive.
    --
    -- Only ever write the exact item passed to the current generation's
    -- callback. Never index into BG3's Noesis Passives collection: those
    -- indexed reads have returned unrelated items in previous live tests.
    -- All Extra Resource transitions now change only the clicked item.
    -- Never retain/dereference the synthetic resource proxies for OTHER rows:
    -- those expired proxies caused NATIVE_RESOURCE_LIVE_SYNC_FALLBACK,
    -- rebuilding the entire screen and rejecting subsequent valid clicks.
    local liveCheckboxGroup=panel.Kind=="Resource" or panel.Kind=="Passive"
        or panel.Kind=="GenericPassiveAdd"
        or panel.Kind=="PassivePairAdd" or panel.Kind=="ElementAdd"
        or panel.Kind=="MultifacetedAdd" or panel.Kind=="MultifacetedSkills"
    if liveCheckboxGroup then
        local updated,err=pcall(function()
            local selected,count=HB_MULTIFACETED_UI.HistoricalPassiveVisualSelection(panel,panelIndex)
            local value=selected[tostring(id)] and 1.0 or 0.0
            if panel.Kind=="Resource" then param.Value=value end
            local presenter=NativeHistoricalFindVisual()
            local liveGroup=Read(presenter,"DataContext")
            local visibleIndex=tonumber(Read(liveGroup,"HB_HistoricalPanelIndex"))
            if visibleIndex~=panelIndex then
                error("live selector group mismatch: "..tostring(visibleIndex)
                    .." expected "..tostring(panelIndex))
            end
            param.Value=value
            liveGroup.SelectedPassiveCount=count
            local maximum=tonumber(Read(liveGroup,"MaxSelectedPassiveCount"))
            if not maximum then error("live selector maximum unavailable") end
            liveGroup.IsComplete=count==maximum
            if tonumber(Read(param,"Value"))~=value
                or tonumber(Read(liveGroup,"SelectedPassiveCount"))~=count then
                error("live selector update did not persist")
            end
            Log((panel.Kind=="Resource" and "NATIVE_RESOURCE_TWO_CLICK_SYNC" or "NATIVE_PASSIVE_LIVE_SYNC")
                .." level="..currentLevel
                .." tab="..panelIndex.." kind="..tostring(panel.Kind)
                .." id="..tostring(id).." checked="..tostring(value)
                .." count="..count.."/"..maximum
                .." accepted="..tostring(didStage)
                .." armed="..tostring(armedFrom))
        end)
        if updated then return end
        Log("NATIVE_PASSIVE_LIVE_SYNC_FALLBACK level="..currentLevel
            .." tab="..panelIndex.." kind="..tostring(panel.Kind)
            .." error="..tostring(err))
        if panel.Kind=="Resource" then
            -- Preserve the live command/selection generation on failure.
            -- Rebuilding from a checkbox callback left the currently rendered
            -- items stale (the user's observed second-click rejection).
            -- An explicit tab visit can rebind the display safely.
            Log("NATIVE_RESOURCE_NO_AUTO_REBUILD level="..currentLevel
                .." armed="..tostring(armedFrom))
            return
        end
    end
    -- Older recorded historical replacements retain their validated guarded
    -- refresh when no suitable live group can be identified.
    local sourceGeneration=nativeMenuGeneration
    QueueOnUI(function()
        if not nativePilotActive or nativeMenuGeneration~=sourceGeneration then return end
        local ok,err=pcall(SyncNativeHistoricalCheckmarks,"native_click")
        if not ok then Log("NATIVE_HISTORICAL_SYNC_ERROR "..tostring(err)) end
    end)
end

-- Vanilla's FeatSpellSelector sends PassThroughConverter arguments:
-- typically [selector, VMSpellReference], not the reference alone. Resolve
-- only an explicit historical entry; never infer an ID from the live caster.
local function ResolveHistoricalSpellClick(param)
    local candidates={}
    local function Add(value)
        if value~=nil then candidates[#candidates+1]=value end
    end
    Add(param)
    Add(Read(param,"Item")); Add(Read(param,"Value"))
    if type(param)=="table" then
        Add(param[1]); Add(param[2]); Add(param[0])
    end
    for index=0,2 do Add(GetCollectionItem(param,index)) end
    local panels=AllPanels()
    local mismatch="missing stamped spell entry"
    for _,candidate in ipairs(candidates) do
        local id=tostring(Read(candidate,"SpellId") or "")
        local group=tonumber(Read(candidate,"HB_HistoricalPanelIndex"))
        local stampedLevel=tonumber(Read(candidate,"HB_HistoricalLevel"))
        local stampedGeneration=tonumber(Read(candidate,"HB_HistoricalGeneration"))
        local stampedKind=tostring(Read(candidate,"HB_HistoricalPanelKind") or "")
        local panel=group and panels[group] or nil
        if id~="" then
            mismatch="level/tab/kind/generation no longer matches current selector"
            -- BG3 may retain the old displayed ItemsControl after HomeBrew
            -- refreshes the wrapper. The new wrapper's command receives an
            -- old spell entry even though it still belongs to this exact
            -- level, selected tab, and selector. Do not repeatedly rebuild
            -- an unchanged page just because its tile is one generation old.
            -- Identity, catalog, level and tab are mandatory; a stale click
            -- from a different selector can NEVER be reinterpreted.
            if panel and stampedLevel==currentLevel
                and group==passiveGroupIndex
                and stampedKind==tostring(panel.Kind or "")
                and stampedGeneration and stampedGeneration<=nativeMenuGeneration
                and stampedGeneration>=nativeMenuGeneration-16
                and IsRecordedSpellPanel(panel) then
                for _,option in ipairs(panel.Options or {}) do
                    if tostring(option.PassiveId or "")==id then
                        if stampedGeneration~=nativeMenuGeneration then
                            Log("NATIVE_SPELL_STALE_ENTRY_REVALIDATED level="..currentLevel
                                .." tab="..group.." id="..id
                                .." entryGeneration="..stampedGeneration
                                .." currentGeneration="..nativeMenuGeneration
                                .." kind="..stampedKind)
                        end
                        return id,group
                    end
                end
                mismatch="spell not in current selector's legal catalog"
            end
        end
    end
    Log("NATIVE_SPELL_CLICK_CONTEXT_REJECT level="..currentLevel
        .." tab="..tostring(passiveGroupIndex)
        .." generation="..nativeMenuGeneration.." reason="..mismatch)
    return nil,nil
end

local function TryStageNativeSpell(param,allowSelectedToggle)
    local id,group=ResolveHistoricalSpellClick(param)
    if not id then
        Log("NATIVE_SPELL_CLICK_UNRESOLVED level="..tostring(currentLevel)
            .." generation="..tostring(nativeMenuGeneration)
            .." payload="..tostring(Read(param,"Type") or type(param)))
        return false,"native spell click lacks a matching current-level historical option"
    end
    local panel=AllPanels()[group]
    if not CanStageNativeSpell(panel) then
        return false,"historical spell is observational or otherwise read-only"
    end
    passiveGroupIndex=group
    if panel.Kind=="ClassSpellGroup" then
        local rank=HistoricalSpellRankClient(id)
        local originalRank=HistoricalSpellRankClient(tostring((panel.Rows[1] or {}).From or ""))
        if rank==nil or originalRank==nil or rank~=originalRank then
            return false,"Historical spell rank differs from the recorded class selector"
        end
        local visible={}
        for _,existing in ipairs(CurrentEffectivePicks(panel)) do visible[existing]=true end
        if visible[id] then return false,"Remove a selected spell before choosing a replacement." end
        local holes=HB_CLASS_SPELL_UI.Unchecked[currentLevel] or {}
        local displaced=(HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {})[currentLevel] or {}
        local target=nil
        for _,row in ipairs(panel.Rows or {}) do
            local key=ChoiceKey(row)
            if holes[key] or displaced[key] then
                for _,option in ipairs(row.Options or {}) do
                    if tostring(option.Id or "")==id then target=row;break end
                end
                if target then break end
            end
        end
        if not target then return false,"Remove one of the two selected spells before choosing a replacement." end
        local conflict=LocalChoiceConflict({Kind="Other",Other=target},id)
        if conflict then return false,conflict end
        local ok,success,message=pcall(onStageOther,currentLevel,target,id)
        if not ok or not success then return false,ok and tostring(message) or tostring(success) end
        previewOther[currentLevel]=previewOther[currentLevel] or {}
        local key=ChoiceKey(target)
        previewOther[currentLevel][key]=id==tostring(target.From) and nil or id
        holes[key]=nil
        HB_CLASS_SPELL_UI.Unchecked[currentLevel]=holes
        if displaced[key] then displaced[key]=nil end
        local n=#CurrentEffectivePicks(panel)
        Log("NATIVE_CLASS_SPELL_GROUP_STAGE level="..currentLevel.." slot="..key
            .." count="..n.." max="..tostring(panel.MaxChoices))
        return true,tostring(n).."/"..tostring(panel.MaxChoices).." spells selected"
    end
    if panel.Kind=="GenericSpellAdd" or panel.Kind=="GenericSpellRecorded" then
        local rank=HistoricalSpellRankClient(id)
        if rank==nil or (panel.SpellCantrip and rank~=0)
            or (not panel.SpellCantrip and rank==0) then
            return false,"Spell rank differs from the feat selector category"
        end
        local allowed=false
        for _,option in ipairs(panel.Options or {}) do
            if option.PassiveId==id then allowed=true;break end
        end
        if not allowed then return false,"Spell is not in the feat selector's installed list" end
        local ok,success,reason=pcall(onStageOther,currentLevel,
            {Kind=(panel.Kind=="GenericSpellRecorded" and "HB_GenericSpellRecorded"
                or "HB_GenericSpellAdd"),FeatId=panel.FeatId,
                SelectorIndex=panel.SelectorIndex,List=panel.List},id)
        if not ok or not success then return false,ok and tostring(reason) or tostring(success) end
        previewGenericChoices[currentLevel]=previewGenericChoices[currentLevel] or {}
        local groups=previewGenericChoices[currentLevel]
        local updated,found={},false
        for _,old in ipairs(groups[panel.SelectorIndex] or {}) do
            if old==id then found=true else updated[#updated+1]=old end
        end
        if not found then updated[#updated+1]=id end
        groups[panel.SelectorIndex]=updated
        return true,tostring(#updated).."/"..tostring(panel.MaxChoices).." spells selected"
    end
    if panel.Kind=="AccordAdd" then
        -- An old available-grid button may remain live during a Noesis
        -- refresh. Once a spell is selected, another SelectSpell click must
        -- not undo it; only the Selected-strip DeselectSpell may remove it.
        if not allowSelectedToggle then
            for _,picked in ipairs(CurrentEffectivePicks(panel)) do
                if tostring(picked)==id then
                    return false,"Already selected; use the selected tile to remove it."
                end
            end
        end
        local rank=HistoricalSpellRankClient(id)
        if rank==nil or (panel.GroupedLevelOne and
                ((panel.GroupSpellCantrip and rank~=0)
                or (not panel.GroupSpellCantrip and rank==0)))
            or (not panel.GroupedLevelOne and rank~=0) then
            return false,"Replacement has the wrong spell category"
        end
        local ok,success,message=pcall(onStageOther,currentLevel,{Kind="HB_AccordAdd"},id)
        if not ok or not success then
            return false,ok and tostring(message) or tostring(success)
        end
        local picked=HB_MULTIFACETED_NEW.Accord.Preview[currentLevel] or {}
        local updated,wasChecked={},false
        for _,old in ipairs(picked) do
            if old==id then wasChecked=true else updated[#updated+1]=old end
        end
        if not wasChecked then updated[#updated+1]=id end
        HB_MULTIFACETED_NEW.Accord.Preview[currentLevel]=updated
        return true,tostring(#updated).."/2 Accord cantrips selected"
    end
    if panel.Kind=="AccordRecorded" then
        local rank=HistoricalSpellRankClient(id)
        if rank==nil or (panel.GroupedLevelOne and
                ((panel.GroupSpellCantrip and rank~=0)
                or (not panel.GroupSpellCantrip and rank==0)))
            or (not panel.GroupedLevelOne and rank~=0) then
            return false,"Replacement has the wrong spell category"
        end
        local states=HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel] or {}
        local current=CurrentEffectivePicks(panel)
        for slot,selected in ipairs(current) do
            if selected==id then
                local key=ChoiceKey(panel.Rows[slot])
                if states[key] then
                    states[key]=nil
                    HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel]=states
                    return true,"Accord cantrip restored ("..#HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel).."/2)"
                end
                return false,"Remove a currently selected cantrip from Selected before replacing it."
            end
        end
        local target=nil
        for _,row in ipairs(panel.Rows or {}) do
            if states[ChoiceKey(row)] then target=row;break end
        end
        if not target then return false,"Remove one of the two selected Accord cantrips first." end
        local valid=false
        for _,option in ipairs(target.Options or {}) do
            if tostring(option.Id or "")==id then valid=true;break end
        end
        if not valid then return false,"Cantrip unavailable in the original recorded selection list." end
        local conflict=LocalChoiceConflict({Kind="Other",Other=target},id)
        if conflict then return false,conflict end
        local ok,success,reason=pcall(onStageOther,currentLevel,target,id)
        if not ok or not success then
            return false,ok and tostring(reason) or tostring(success)
        end
        local key=ChoiceKey(target)
        previewOther[currentLevel]=previewOther[currentLevel] or {}
        previewOther[currentLevel][key]=id==tostring(target.From) and nil or id
        states[key]=nil
        HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel]=states
        Log("NATIVE_ACCORD_RECORDED_STAGE level="..tostring(currentLevel)
            .." slot="..key.." to="..id)
        return true,"Accord cantrip selected ("..#HB_MULTIFACETED_NEW.Accord.VisiblePicks(panel,currentLevel).."/2)"
    end
    local from=tostring(panel.Other.From or "")
    local a,b=HistoricalSpellRankClient(from),HistoricalSpellRankClient(id)
    if a==nil or b==nil or a~=b
        or (panel.Other.Kind=="Cantrip" and a~=0)
        or (panel.Other.Kind=="Spell" and a==0) then
        return false,"spell rank or recorded spell/cantrip category is unavailable or incompatible"
    end
    -- Keep an emptied spell slot armed until the replacement has actually
    -- passed both client preflight and the editor staging callback. Clearing
    -- it prematurely permitted Confirm after a rejected click, even though
    -- the native panel still appeared to have an unfilled selection.
    passiveRows={}
    local seen={}
    for _,option in ipairs(panel.Options or {}) do
        local optionId=tostring(option.PassiveId or "")
        if optionId~="" and not seen[optionId] then
            seen[optionId]=true
            passiveRows[#passiveRows+1]={Id=optionId,Name=Label(option)}
        end
    end
    for i,row in ipairs(passiveRows) do
        if row.Id==id then
            local accepted=StageChoice(i)
            local current=CurrentEffectivePicks(panel)
            if not accepted or tostring(current[1] or "")~=id then
                return false,passiveFeedback or "Historical spell staging rejected"
            end
            if nativeSpellArmed and nativeSpellArmed.level==currentLevel
                and nativeSpellArmed.panelIndex==group then
                nativeSpellArmed=nil
            end
            return true,passiveFeedback
        end
    end
    return false,"selected spell isn't in the historical option list"
end

-- A close request is deferred until the native UI transition completes.
-- Defer a single bridge.Hide retry rather than rebinding or clearing the
-- Noesis-owned original ViewModel while a C++/se:: swap is in flight.
local function RetryPendingNativeHide()
    if not nativeHideRequested then return end
    QueueOnUI(function()
        local bridge=_G.HB_NativeLevelBridge
        if nativeHideRequested and bridge and bridge.Hide then bridge.Hide() end
    end)
end

-- A half-armed passive or spell replacement must disable the *real* BG3
-- Confirm button. This covers unfinished choices on other slider levels too.
-- No cancellation or replay action is executed here.
local function HistoricalConfirmIsComplete(ignoreLiveSwap)
    if armedFrom~=nil or nativeSpellArmed~=nil or nativeCommitPending then return false end
    for _,pending in pairs(HB_MULTIFACETED_UI.Unchecked or {}) do
        if pending==true then return false end
    end
    for _,slots in pairs(HB_CLASS_SPELL_UI.Unchecked or {}) do
        for _,pending in pairs(slots) do if pending then return false end end
    end
    for _,slots in pairs(HB_MULTIFACETED_NEW.Accord.Unchecked) do
        for _,pending in pairs(slots) do if pending then return false end end
    end
    -- Never confirm while a later selector is empty. Historical edits stay
    -- intact, but L1's newer choice invalidates any duplicate recorded pick.
    -- Even if L1 is changed again, an emptied slot needs a manual selection.
    local cleared=HB_NATIVE_L1_SLIDER.DisplacedSpellSlots or {}
    if not ignoreLiveSwap then
        for _,slots in pairs(HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {}) do
            for _,empty in pairs(slots) do if empty then return false end end
        end
        for _,isDuplicate in pairs(HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels or {}) do
            if isDuplicate==true then return false end
        end
        for level,keys in pairs(cleared) do
            for key,empty in pairs(keys) do
                if empty then return false end
            end
        end
    end
    local liveSwap=HB_NATIVE_L1_SLIDER.LiveSpellSwap
    if liveSwap and not ignoreLiveSwap then
        for level=2,maximum do
            for _,row in ipairs((((snapshot[level] or {}).LevelChoices or {}).OtherChoices or {})) do
                if row.Kind=="Spell" then
                    local selected=tostring((previewOther[level] or {})[ChoiceKey(row)] or row.From or "")
                    if selected==liveSwap.To then return false end
                end
            end
        end
    end
    for level,edits in pairs(previewOther) do
        if type(edits)~="table" then return false end
        local catalogKeys={}
        for _,row in ipairs(((snapshot[level] or {}).LevelChoices or {}).OtherChoices or {}) do
            catalogKeys[ChoiceKey(row)]=true
            local id=edits[ChoiceKey(row)]
            if row.Kind=="Feat" and id then
                local spellGroups=HB_GENERIC_FEATS.SpellSelectors(id)
                if spellGroups and id~=HB_MULTIFACETED_NEW.Accord.Feat then
                    local selected=previewGenericChoices[level] or {}
                    local globallySeen={}
                    for index,g in ipairs(spellGroups) do
                        local picks=selected[index] or {}
                        if #picks~=g.Count then return false end
                        local available={}
                        for _,option in ipairs(HBGenericSpellOptions(g.List,g.Cantrip)) do
                            available[tostring(option.PassiveId)]=true
                        end
                        for _,pick in ipairs(picks) do
                            if not available[pick] or globallySeen[pick]
                                or SpellChosenAtOtherHistoricalLevel(pick,level) then return false end
                            globallySeen[pick]=true
                        end
                    end
                end
                local groups=HB_GENERIC_FEATS.PassiveSelectors(id)
                if groups and not HB_PASSIVE_PAIR_FEATS[id]
                    and id~=HB_ELEMENTAL_ADEPT_FEAT and id~=HB_MULTIFACETED_NEW.Feat then
                    for n,g in ipairs(groups) do
                        local picked=(previewGenericChoices[level] or {})[n] or {}
                        if #picked~=g.Count then return false end
                        local options,legal,seen=HBGenericOptions(g.List),{},{}
                        for _,option in ipairs(options) do legal[tostring(option.PassiveId)]=true end
                        for _,passive in ipairs(picked) do
                            if not legal[passive] or seen[passive]
                                or HistoricalPassiveTakenOnOtherLevel(passive,level) then return false end
                            seen[passive]=true
                        end
                    end
                end
                if id==HB_ELEMENTAL_ADEPT_FEAT then
                    local picks=previewNewElements[level] or {}
                    if #picks~=2 or picks[1]==picks[2] then return false end
                    local valid={}
                    for _,option in ipairs(HB_ELEMENTAL_OPTIONS) do
                        valid[tostring(option.PassiveId)]=true
                    end
                    if not valid[picks[1]] or not valid[picks[2]] then return false end
                end
                if id==HB_MULTIFACETED_NEW.Accord.Feat then
                    local picks=HB_MULTIFACETED_NEW.Accord.Preview[level] or {}
                    if #picks~=2 or picks[1]==picks[2] then return false end
                    local known={}
                    for _,option in ipairs(HB_MULTIFACETED_NEW.Accord.Options()) do
                        known[tostring(option.PassiveId)]=true
                    end
                    for _,pick in ipairs(picks) do
                        if not known[pick] or HistoricalSpellRankClient(pick)~=0
                            or SpellChosenAtOtherHistoricalLevel(pick,level) then
                            return false
                        end
                    end
                end
                if id==HB_MULTIFACETED_NEW.Feat then
                    local groups=HB_MULTIFACETED_NEW.Preview[level] or {}
                    if #(groups.Archetype or {})~=1 or #(groups.Trait or {})~=1
                        or #(groups.Skills or {})~=4 then return false end
                    for _,section in ipairs({"Archetype","Trait","Skills"}) do
                        local known,seen={},{}
                        for _,valid in ipairs(HB_MULTIFACETED_NEW.Catalog[section]) do known[valid]=true end
                        for _,picked in ipairs(groups[section] or {}) do
                            if not known[picked] or seen[picked] then return false end
                            seen[picked]=true
                            if (section=="Skills" and HistoricalSkillTakenOnOtherLevel(picked,level))
                                or (section~="Skills" and HistoricalPassiveTakenOnOtherLevel(picked,level)) then
                                return false
                            end
                        end
                    end
                end
                local pair=HB_PASSIVE_PAIR_FEATS[id]
                if pair then
                    local picks=previewPairChoices[level] or {}
                    if previewPairFeatIds[level]~=id or #picks~=2
                        or picks[1]==picks[2] then return false end
                    local valid={}
                    for _,optionId in ipairs(pair.Ids or {}) do valid[optionId]=true end
                    if not valid[picks[1]] or not valid[picks[2]] then return false end
                end
            elseif (row.Kind=="Spell" or row.Kind=="Cantrip") and id then
                -- A stale saved edit referencing a deleted candidate must
                -- not make native Confirm appear enabled. The server remains
                -- authoritative for source/progression/spellbook ownership.
                local inCatalog=false
                for _,option in ipairs(row.Options or {}) do
                    if tostring(option.Id or "")==tostring(id) then
                        inCatalog=true;break
                    end
                end
                if not inCatalog then return false end
                local oldRank=HistoricalSpellRankClient(tostring(row.From or ""))
                local newRank=HistoricalSpellRankClient(tostring(id))
                if oldRank==nil or newRank==nil or oldRank~=newRank
                    or (row.Kind=="Cantrip" and newRank~=0)
                    or (row.Kind=="Spell" and newRank==0)
                    or SpellChosenAtOtherHistoricalLevel(id,level) then
                    return false
                end
            end
        end
        -- A restored snapshot or changed feat may no longer contain a
        -- previously staged choice key. Don't enable Confirm for an orphan.
        for key,value in pairs(edits) do
            if value~=nil and not catalogKeys[key] then return false end
        end
    end
    -- Expertise must be drawn from the CURRENT staged level-one skill picks.
    -- A change to proficiencies must not silently preserve illegal expertise.
    local first=(snapshot[1] or {}).LevelChoices or {}
    local staged=(previewOther[1] or {})
    local levelOneProficient,hasProficiencies={},false
    local levelOneExpertise={}
    for _,choice in ipairs(first.OtherChoices or {}) do
        if choice.LevelOneVerified==true then
            local id=tostring(staged[ChoiceKey(choice)] or choice.From or "")
            if choice.Kind=="Skill" then
                hasProficiencies=true
                levelOneProficient[id]=true
            elseif choice.Kind=="Expertise" then
                levelOneExpertise[#levelOneExpertise+1]=id
            end
        end
    end
    if #levelOneExpertise>0 then
        if not hasProficiencies then return false end
        for _,skill in ipairs(levelOneExpertise) do
            if not levelOneProficient[skill] then return false end
        end
    end
    -- Re-editing an ALREADY recorded spell feat need not change its feat ID.
    -- The staged full-group replacement still has to satisfy all native
    -- selection requirements, even if previewOther contains no feat swap.
    for level,stagedGroups in pairs(previewGenericChoices) do
        local levelRow=(snapshot[level] or {}).LevelChoices or {}
        local recordedFeat=nil
        for _,choice in ipairs(levelRow.OtherChoices or {}) do
            if choice.Kind=="Feat" then recordedFeat=tostring(choice.From or ""); break end
        end
        local effectiveFeat=recordedFeat
        for _,choice in ipairs(levelRow.OtherChoices or {}) do
            if choice.Kind=="Feat" then
                effectiveFeat=tostring((previewOther[level] or {})[ChoiceKey(choice)]
                    or choice.From or "")
                break
            end
        end
        local definitions=(effectiveFeat==recordedFeat and recordedFeat)
            and HB_GENERIC_FEATS.SpellSelectors(recordedFeat) or nil
        if definitions and type(stagedGroups)=="table"
            and next(stagedGroups)~=nil then
            local globallySeen={}
            for index,g in ipairs(definitions) do
                local ids=stagedGroups[index]
                if type(ids)~="table" or #ids~=g.Count then return false end
                local valid={}
                for _,option in ipairs(HBGenericSpellOptions(g.List,g.Cantrip)) do
                    valid[tostring(option.PassiveId)]=true
                end
                for _,id in ipairs(ids) do
                    if not valid[id] or globallySeen[id]
                        or SpellChosenAtOtherHistoricalLevel(id,level) then return false end
                    globallySeen[id]=true
                end
            end
        end
    end
    return true
end

-- The game's native Confirm is bound to IsCharacterComplete. Some BG3
-- templates bind before the detached proxy has finished refreshing; update
-- the LIVE historical proxy immediately as well as on every new page.
SyncHistoricalConfirmEnabled = function(reason)
    if not previewOpen or not nativePilotActive or nativePilotWrapping then return end
    local live,name,node=NativeVM()
    if not live or (name~="CharacterRespec" and name~="CharacterRespec_c") then return end
    if not tostring(Read(live,"Type") or ""):find("HB_HistoricalNativeCommandPilot",1,true) then return end
    local complete=HistoricalConfirmIsComplete()
    local ok,err=pcall(function()
        live.IsCharacterComplete=complete
        live.IsCharacterCompleteExceptName=complete
    end)
    Log("NATIVE_CONFIRM_SYNC level="..tostring(currentLevel).." enabled="..tostring(complete)
        .." exceptName="..tostring(Read(live,"IsCharacterCompleteExceptName"))
        .." reason="..tostring(reason).." ok="..tostring(ok)
        ..(ok and "" or " error="..tostring(err)))
    if node then
        -- IsEnabled normally follows the binding above. Some runtime builds
        -- keep an old enabled value; mirror the safe completeness state on
        -- the button and re-enable when the player completes the choice.
        local found,button=pcall(function() return node:Find("ventureForth") end)
        if not (found and button) then
            -- Some CharacterRespec layouts do not implement :Find() on the
            -- child widget proxy. Walk only this live screen, once per
            -- historical change, to locate the *actual* named BG3 control.
            local nodes={node}; local scan=1
            while scan<=#nodes and scan<=1600 do
                local candidate=nodes[scan];scan=scan+1
                if Read(candidate,"Name")=="ventureForth" then
                    button=candidate;break
                end
                local count=math.min(tonumber(Read(candidate,"VisualChildrenCount")) or 0,120)
                for i=1,count do
                    local okChild,child=pcall(function() return candidate:VisualChild(i) end)
                    if okChild and child then nodes[#nodes+1]=child end
                end
            end
            if button then
                Log("NATIVE_CONFIRM_VISUAL_GUARD_FOUND_TRAVERSAL scanned="..tostring(scan))
            end
        end
        if button then
            local applied,err=pcall(function() button.IsEnabled=complete end)
            Log("NATIVE_CONFIRM_VISUAL_GUARD button=ventureForth enabled="
                ..tostring(complete).." ok="..tostring(applied)
                ..(applied and "" or " error="..tostring(err)))
        else
            Log("NATIVE_CONFIRM_VISUAL_GUARD button=ventureForth not_found"
                .." enabled="..tostring(complete))
        end
    end
end

-- Keep L1's actual native tab selection when switching to a historical
-- wrapper. The native ContentControl is shared between both contexts and can
-- retain an old historical subtab after its owner has been detached. These
-- helpers run ONLY during explicit L1 transitions, never every UI tick.
function HB_NATIVE_L1_SLIDER.FindNativeControl(root,name)
    if not root then return nil end
    local ok,control=pcall(function() return root:Find(name) end)
    if ok and control then return control end
    -- Some game builds omit Find for nested template children. Bounded
    -- fallback, and only during the L1 transition, not a background scan.
    local nodes={root};local n=1
    while n<=#nodes and n<=2200 do
        local node=nodes[n];n=n+1
        if Read(node,"Name")==name then return node end
        local count=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,100)
        for i=1,count do
            local childOk,child=pcall(function() return node:VisualChild(i) end)
            if childOk and child then nodes[#nodes+1]=child end
        end
    end
    return nil
end
-- Level-one maneuver/metamagic selectors use VMCharacterCreationPassive
-- entries (Value=1 for a selected option), not VMSpellSelector.Additions.
-- Match ONLY exact installed stat handles in the verified L1 option catalog
-- that are ALSO originally recorded at a later level. Never infer identity
-- from translated text or one ambiguous localized passive name.
function HB_NATIVE_L1_SLIDER.BuildPassiveCandidateIndex()
    local levelOneAllowed={}
    for _,group in ipairs((((snapshot[1] or {}).LevelChoices or {}).EditablePassiveGroups or {})) do
        for _,option in ipairs(group.Options or {}) do
            local id=tostring(option.PassiveId or option.Id or "")
            if id~="" then levelOneAllowed[id]=true end
        end
    end
    -- Resolve every option of a recorded L1 player-choice selector, not just
    -- passives recorded at later levels. Otherwise the original L1 passive
    -- (e.g. PushingAttack) never enters the live identity set and cannot be
    -- distinguished from its replacement when navigating back to level 2.
    local candidateIds=levelOneAllowed
    local handles={}
    for id in pairs(candidateIds) do
        local stats=nil
        if Ext.Stats and Ext.Stats.Get then
            local ok,value=pcall(Ext.Stats.Get,id)
            if ok then stats=value end
        end
        local raw=tostring(Read(stats,"DisplayName") or "")
        local handle=raw:match("^([^;]+)")
        if handle and handle~="" then
            if handles[handle]==nil then handles[handle]=id
            elseif handles[handle]~=id then handles[handle]=false end
        end
    end
    HB_NATIVE_L1_SLIDER.PassiveCandidateIndex={Ids=candidateIds,Handles=handles}
    Log("NATIVE_L1_PASSIVE_CANDIDATES count="..tostring((function()
        local n=0;for _ in pairs(candidateIds) do n=n+1 end;return n
    end)()))
end

-- Recaculate on both live L1 selection changes and successful later stages;
-- this does not delete historical passives or stage a replacement on its own.
function HB_NATIVE_L1_SLIDER.RefreshPassiveDuplicateLevels()
    local updated={}
    local live=HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds or {}
    -- Identical to the verified spell rule: when native L1 owns a selected
    -- passive from a later level, its recorded later slot becomes EMPTY.
    -- Preserve the original CCLevelUp history until a valid replacement is
    -- explicitly staged; never synthesize an incomplete server transaction.
    local cleared=HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots or {}
    local newHoles=0
    for level=2,maximum do
        local stages=(snapshot[level] or {})._HB_PreviewStaged or {}
        for _,group in ipairs((((snapshot[level] or {}).LevelChoices or {}).EditablePassiveGroups or {})) do
            for _,id in ipairs(group.Picked or {}) do
                local from=tostring(id)
                local key=tostring(group.SelectorId).."|"..tostring(group.PassiveList).."|"..from
                local effective=tostring(stages[key] or from)
                if live[effective]
                    and not HB_NATIVE_L1_SLIDER.OriginalFirstPassiveFreed(effective) then
                    updated[level]=true
                    cleared[level]=cleared[level] or {}
                    if not cleared[level][key] then
                        cleared[level][key]=true
                        newHoles=newHoles+1
                        Log("NATIVE_L1_PASSIVE_SLOT_CLEARED level="..level
                            .." key="..key.." passive="..effective)
                    end
                end
            end
        end
    end
    local before=HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels or {}
    HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots=cleared
    local function Signature(levels)
        local parts={};for level,active in pairs(levels) do
            if active then parts[#parts+1]=tostring(level) end
        end
        table.sort(parts);return table.concat(parts,",")
    end
    local oldSig,newSig=Signature(before),Signature(updated)
    HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels=updated
    if oldSig~=newSig or newHoles>0 then
        Log("NATIVE_L1_PASSIVE_CONFLICT levels="..(newSig~="" and newSig or "none")
            .." newEmptySlots="..newHoles)
    end
    return oldSig~=newSig or newHoles>0
end

-- Inspect only BG3's existing passive collections, no UI-tree traversal,
-- no Execute() calls and no writes to native C++ selection objects.
-- The native level-one maneuver/metamagic page lives in the active
-- gameplaySubPanel.DataContext, not necessarily in ClassProgressionDetails.
-- Scan the selected page plus its recorded class progression collections.
-- Keep a per-group last observed selection so merely visiting Spells/Class
-- cannot silently erase a real earlier passive conflict.
function HB_NATIVE_L1_SLIDER.ObserveLivePassivePending(live, panel)
    local catalog=HB_NATIVE_L1_SLIDER.PassiveCandidateIndex or {}
    local known=catalog.Ids or {}
    if not next(known) then return end
    local details=Read(live,"ClassProgressionDetails")
    local groups={};local seen={}
    local function AddGroup(group,active,source)
        if not group or Read(group,"Type")~="ls.VMCharacterCreationPassives" then return end
        local name=tostring(Read(group,"Name") or "")
        if name=="" then return end -- no trustworthy stable group identity
        if not seen[name] or active then
            seen[name]={Group=group,Active=active,Source=source}
        end
    end
    for _,field in ipairs({"NotSubPassiveSelectors","SubPassiveSelectors"}) do
        local collection=Read(details,field)
        for i=0,math.min(CollectionCount(collection) or 0,40)-1 do
            AddGroup(GetCollectionItem(collection,i),false,"details."..field)
        end
    end
    for _,field in ipairs({"ClassPassives","ClassAndSubClassPassives"}) do
        local collection=Read(live,field)
        for i=0,math.min(CollectionCount(collection) or 0,40)-1 do
            AddGroup(GetCollectionItem(collection,i),false,"vm."..field)
        end
    end
    -- This is the missing Bait and Switch source in the user's live trace.
    -- Reuse the panel already found by ObserveLiveSpellPending; no second
    -- costly visual-tree traversal or writes to game-owned controls.
    AddGroup(Read(panel,"DataContext"),true,"gameplaySubPanel")

    local observed=HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups or {}
    local byGroup=HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup or {}
    local activeGroups=HB_NATIVE_L1_SLIDER.PassiveActiveGroups or {}
    local changedGroup=false
    local activeSummary=nil
    for key,info in pairs(seen) do
        local list=Read(info.Group,"Passives")
        if list then
            local selected={};local selectedRaw={};local positives=0
            for i=0,math.min(CollectionCount(list) or 0,160)-1 do
                local passive=GetCollectionItem(list,i)
                if passive and tonumber(Read(passive,"Value"))==1 then
                    positives=positives+1
                    local direct=tostring(Read(passive,"PassiveId") or Read(passive,"Id") or "")
                    local handle=tostring(Read(passive,"Name") or ""):match("^([^;]+)") or ""
                    local id=known[direct] and direct or (catalog.Handles or {})[handle]
                    if type(id)=="string" then selected[id]=true end
                    if #selectedRaw<5 then selectedRaw[#selectedRaw+1]=handle end
                end
            end
            -- Bind this ACTIVE native selector to exactly one recorded L1
            -- selector by its selected IDs and the original option catalog.
            -- Identical option IDs in multiple L1 selectors are ambiguous:
            -- never free a saved passive without unique group ownership.
            if info.Active and positives>0 and next(selected) then
                local matched={}
                for _,recorded in ipairs((((snapshot[1] or {}).LevelChoices or {}).EditablePassiveGroups or {})) do
                    local allowed={}
                    for _,option in ipairs(recorded.Options or {}) do
                        allowed[tostring(option.PassiveId or option.Id or "")]=true
                    end
                    local all=true
                    for picked in pairs(selected) do
                        if not allowed[picked] then all=false;break end
                    end
                    if all then matched[#matched+1]=recorded end
                end
                if #matched==1 then
                    local recorded=matched[1]
                    local key=tostring(recorded.SelectorId).."|"..tostring(recorded.PassiveList)
                    -- Only a fully populated native selector proves that a
                    -- previous choice was actually removed, not just pending.
                    if (function()
                        local count=0;for _ in pairs(selected) do count=count+1 end
                        return count>=#(recorded.Picked or {})
                    end)() then
                        local old=observed[key] or {}
                        local changed=false
                        for id in pairs(selected) do if not old[id] then changed=true end end
                        for id in pairs(old) do if not selected[id] then changed=true end end
                        observed[key]=selected
                        if changed then
                            Log("NATIVE_L1_PASSIVE_ORIGIN_SYNC selector="..key
                                .." selected="..(function()
                                    local out={};for id in pairs(selected) do out[#out+1]=id end
                                    table.sort(out);return table.concat(out,",")
                                end)())
                        end
                    end
                end
            end
            -- Always trust a visible native group, including an empty one.
            -- For hidden collections, only revise a previously observed group
            -- if BG3 supplies positive selection evidence.
            if info.Active or (positives>0 and not activeGroups[key]) then
                if info.Active then activeGroups[key]=true end
                local prior=byGroup[key] or {}
                local differs=false
                for id in pairs(selected) do if not prior[id] then differs=true end end
                for id in pairs(prior) do if not selected[id] then differs=true end end
                if differs then changedGroup=true end
                byGroup[key]=selected
                if info.Active then
                    activeSummary="group="..key:sub(1,90).." picks="..positives
                        .." names="..table.concat(selectedRaw,","):sub(1,230)
                        .." matched="..(function()
                            local ids={};for id in pairs(selected) do ids[#ids+1]=id end
                            table.sort(ids);return table.concat(ids,",")
                        end)()
                end
            end
        end
    end
    HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups=observed
    HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup=byGroup
    HB_NATIVE_L1_SLIDER.PassiveActiveGroups=activeGroups
    if activeSummary and activeSummary~=HB_NATIVE_L1_SLIDER.LastNativePassivePanel then
        HB_NATIVE_L1_SLIDER.LastNativePassivePanel=activeSummary
        Log("NATIVE_L1_PASSIVE_ACTIVE_PANEL "..activeSummary)
    end
    if not changedGroup then return end
    local selected={}
    for _,ids in pairs(byGroup) do
        for id in pairs(ids) do selected[id]=true end
    end
    local old=HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds or {}
    local changed=false
    for id in pairs(selected) do if not old[id] then changed=true end end
    for id in pairs(old) do if not selected[id] then changed=true end end
    if changed then
        HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds=selected
        local names={};for id in pairs(selected) do names[#names+1]=id end
        table.sort(names)
        Log("NATIVE_L1_PASSIVE_SELECTED matched="..table.concat(names,","))
        HB_NATIVE_L1_SLIDER.RefreshPassiveDuplicateLevels()
    end
end

-- Recheck only the current, real BG3 first-level spell selector. Historical
-- provenance is intentionally never inferred from a localized spell *name*:
-- ProbeLiveSpellStatIdentity maps the exact installed DisplayName handle
-- uniquely to a stat ID and rejects ambiguous/missing results.
-- The ordinary vanilla native ViewModel is C++; its IsCharacterComplete
-- cannot be patched. A separate Noesis overlay blocks its Confirm click.
function HB_NATIVE_L1_SLIDER.ObserveLiveSpellPending()
    if not previewOpen or currentLevel~=1 or not HB_NATIVE_L1_SLIDER.Screen
        or nativePilotActive or nativePilotWrapping or nativeCommitPending
        or nativeCancelAwaitingDecision or HB_NATIVE_L1_SLIDER.Pending then return end
    local live,screen,root=NativeVM()
    if (screen~="CharacterRespec" and screen~="CharacterRespec_c")
        or Read(live,"Type")~="gui::DCCharacterCreation" or not root then return end
    -- Do not traverse the C++ spellbook or execute any of its commands.
    local panel=HB_NATIVE_L1_SLIDER.FindNativeControl(root,"gameplaySubPanel")
    HB_NATIVE_L1_SLIDER.ObserveLivePassivePending(live,panel)
    HB_NATIVE_L1_SLIDER.ObserveAllFirstLevelSpellConflicts(live,root)
    local selector=Read(panel,"DataContext")
    if Read(selector,"Type")=="ls.VMSpellSelector"
        and Read(selector,"IsCantrips")~=true then
        local picks=Read(selector,"Additions")
        if CollectionCount(picks)==1 then
            local ref=GetCollectionItem(picks,0)
            local spell=Read(ref,"Spell")
            local handle=tostring(Read(spell,"Name") or "")
            if handle~="" and handle~=HB_NATIVE_L1_SLIDER.LiveSpellHandleSeen then
                HB_NATIVE_L1_SLIDER.LiveSpellHandleSeen=handle
                HB_NATIVE_L1_SLIDER.ProbeLiveSpellStatIdentity(spell,selector,
                    "node.gameplaySubPanel.DataContext","native-level-one-live")
            end
        end
    end
    local pending=HB_NATIVE_L1_SLIDER.NativeLevelOneChoicesPending()
    local conflictLevel=HB_NATIVE_L1_SLIDER.FirstPendingSpellLevel()
    if pending~=HB_NATIVE_L1_SLIDER.LastLevelOnePending
        or conflictLevel~=HB_NATIVE_L1_SLIDER.LastLevelOnePendingConflict then
        HB_NATIVE_L1_SLIDER.LastLevelOnePending=pending
        HB_NATIVE_L1_SLIDER.LastLevelOnePendingConflict=conflictLevel
        Log("NATIVE_L1_CHOICES_PENDING changed="..tostring(pending)
            .." unresolved="..tostring(HB_NATIVE_L1_SLIDER.HasDisplacedSpellSlots())
            .." conflictLevel="..tostring(conflictLevel))
        UpdateVM()
    end
    -- Apply a second, direct native-button guard if the exact FinishCreating
    -- command can be identified. Never guess among ordinary action buttons.
    -- The independent XAML hit-test shield handles layouts whose native
    -- Confirm button is not accessible through Ext.UI.
    -- Button scanning is a one-shot transition check, not a frame loop.
    -- The overlay remains mounted for the entire pending state.
    if pending~=HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard then
        local command=Read(live,"FinishCreating")
        local button=nil
        for _,name in ipairs({"ventureForth","confirmButton","ConfirmButton","confirmBtn"}) do
            local ok,found=pcall(function() return root:Find(name) end)
            if ok and found then
                local bound=Read(found,"Command")
                if command and bound and bound==command then button=found;break end
            end
        end
        if not button and command then
            local nodes={root};local i=1
            while i<=#nodes and i<=1300 do
                local node=nodes[i];i=i+1
                local bound=Read(node,"Command")
                if bound and bound==command then button=node;break end
                local count=math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,100)
                for j=1,count do
                    local ok,child=pcall(function() return node:VisualChild(j) end)
                    if ok and child then nodes[#nodes+1]=child end
                end
            end
        end
        if button then
            local originalComplete=Read(live,"IsCharacterComplete")==true
            local enabled=not pending and originalComplete
            local ok,err=pcall(function() button.IsEnabled=enabled end)
            if not HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard or not pending then
                Log("NATIVE_L1_CONFIRM_GUARD pending="..tostring(pending)
                    .." name="..tostring(Read(button,"Name"))
                    .." enabled="..tostring(enabled).." ok="..tostring(ok)
                    ..(ok and "" or " err="..tostring(err)))
            end
        elseif not HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard then
            Log("NATIVE_L1_CONFIRM_GUARD button=not_found overlay=required")
        end
        HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard=pending
    end
end

function HB_NATIVE_L1_SLIDER.CaptureNativeTabs(root)
    local state={}
    for _,name in ipairs({"gameplayTabs","subTabsSpellsList",
        "subTabsPassivesList","subTabsEquipmentList"}) do
        local tab=HB_NATIVE_L1_SLIDER.FindNativeControl(root,name)
        local index=tonumber(Read(tab,"SelectedIndex"))
        -- Never infer a tab from an outdated historical sidebar. Native
        -- captures only occur while the C++ ViewModel owns CharacterRespec.
        state[name]=(index and index>=0) and math.floor(index) or -1
    end
    local content=HB_NATIVE_L1_SLIDER.FindNativeControl(root,"gameplaySubPanel")
    state.Tag=tostring(Read(content,"Tag") or "")
    HB_NATIVE_L1_SLIDER.OriginalNavigation=state
    Log("NATIVE_L1_TAB_CAPTURE main="..state.gameplayTabs
        .." spells="..state.subTabsSpellsList
        .." passives="..state.subTabsPassivesList
        .." equipment="..state.subTabsEquipmentList
        .." tag="..state.Tag)
end
function HB_NATIVE_L1_SLIDER.RebindNativeTabs(expectedGeneration)
    if not previewOpen or currentLevel~=1 or nativePilotActive
        or nativePilotWrapping or nativeCancelAwaitingDecision
        or nativeCommitPending or not HB_NATIVE_L1_SLIDER.Screen
        or nativeMenuGeneration~=expectedGeneration then return end
    local live,name,root=NativeVM()
    if (name~="CharacterRespec" and name~="CharacterRespec_c")
        or Read(live,"Type")~="gui::DCCharacterCreation" or not root then return end
    local state=HB_NATIVE_L1_SLIDER.OriginalNavigation or {}
    local controls={}
    for _,field in ipairs({"gameplayTabs","subTabsSpellsList",
        "subTabsPassivesList","subTabsEquipmentList"}) do
        controls[field]=HB_NATIVE_L1_SLIDER.FindNativeControl(root,field)
    end
    -- Only one of BG3's mutually exclusive ListBoxes should have a selected
    -- item. A subtab takes priority over its parent. Re-selecting the same
    -- index forces the game's own DataContext binding to fire again.
    local chosen,index=nil,nil
    for _,field in ipairs({"subTabsSpellsList","subTabsPassivesList",
        "subTabsEquipmentList","gameplayTabs"}) do
        local control=controls[field]
        local saved=tonumber(state[field]) or -1
        local now=tonumber(Read(control,"SelectedIndex")) or -1
        local wanted=saved>=0 and saved or now
        if wanted>=0 and control then
            chosen=field;index=math.floor(wanted);break
        end
    end
    local rebound,why=false,"no native selected ListBox"
    if chosen then
        rebound,why=pcall(function()
            local list=controls[chosen]
            list.SelectedIndex=-1
            list.SelectedIndex=index
        end)
    end
    local panel=HB_NATIVE_L1_SLIDER.FindNativeControl(root,"gameplaySubPanel")
    local template=Read(panel,"ContentTemplate")
    local data=Read(panel,"DataContext")
    Log("NATIVE_L1_TABS_REBOUND list="..tostring(chosen)
        .." index="..tostring(index).." success="..tostring(rebound)
        .." reason="..tostring(why)
        .." template="..tostring(Read(template,"Type"))
        .." content="..tostring(Read(data,"Type"))
        .." historicalKind="..tostring(Read(data,"HB_HistoricalRenderKind")))
end

-- Launches from the small native preview. This only redirects data used by
-- the live native passive menu; its actual rendered XAML is not duplicated.
NativeHistoricalStart = function()
    nativePilotMode="historical"
    if NativePilotStart then NativePilotStart() end
end

-- Use the slider's bound *value*, not merely the UI event. BG3 can replace
-- Noesis command instances during the Cancel -> No modal transition. A
-- low-rate watcher runs this exact same guarded path if ValueChanged ends up
-- bound to a detached command; never apply anything while the modal is open.
ApplyHistoricalSliderFromModel = function(source)
    if not previewOpen or nativePilotWrapping or nativeCancelAwaitingDecision
        or nativeCommitPending or HB_NATIVE_L1_SLIDER.FullRespecChanged then return false end
    local holder=CurrentVM()
    local requested=tonumber(Read(holder,"HB_NativeSelectedLevel"))
    if not requested then return false end
    requested=math.max(1,math.min(maximum,math.floor(requested+0.5)))
    if requested==currentLevel then return false end
    local old=currentLevel
    currentLevel=requested
    passiveGroupIndex=1; armedFrom=nil; nativeSpellArmed=nil
    if old~=1 and requested~=1 then HB_MULTIFACETED_UI.Clear() end
    passiveFeedback=""; nativeCommitError=""
    nativeFeatPreview=false; nativeSpellPreview=false; nativeSpellAllowStage=false
    local live,name=NativeVM()
    local attachedProbe=tonumber(Read(live,"HB_HistoricalProbeLevel"))
    local hasLiveWrapper=nativePilotActive and attachedProbe==old
    Log("NATIVE_HISTORICAL_SLIDER_MOVE source="..tostring(source)
        .." from="..old.." to="..requested
        .." active="..tostring(nativePilotActive)
        .." host="..tostring(name).." probe="..tostring(attachedProbe)
        .." recovery="..tostring(nativeCancelRecoveryPending))
    if old==1 and requested>1 then
        -- Capture the real native choices before installing historical UI;
        -- snapshots used for cross-level checks still describe the ORIGINAL L1.
        HB_NATIVE_L1_SLIDER.ProbeNativeSpellPicks("vanilla-to-historical")
    end
    if requested==1 then
        -- Returning to vanilla L1 must remain possible to undo a changed
        -- native spell; only an actual Confirm requires completing the
        -- inverse higher-level exchange.
        if not HistoricalConfirmIsComplete(true) then
            -- Pending historical slots cannot silently disappear when the
            -- player switches to the native page and presses Confirm.
            currentLevel=old
            nativeCommitError="Finish selecting the staged higher-level choices before opening level one."
            Log("NATIVE_SLIDER_L1_INCOMPLETE_HIGHER_EDITS")
            UpdateVM()
            return false
        end
        -- Never show a live vanilla Confirm before the server has backed up
        -- and validated all currently staged L2+ edits.
        HB_NATIVE_L1_SLIDER.Screen=false
        HB_NATIVE_L1_SLIDER.FullRespecChanged=false
        HB_NATIVE_L1_SLIDER.Prepared=false
        HB_NATIVE_L1_SLIDER.Pending=true
        nativeCancelRecoveryPending=false
        nativeCancelRecoveryChecks=0
        nativeRefreshQueued=false
        queuedRefresh=false
        if not HB_NATIVE_L1_SLIDER.OnPrepare then
            HB_NATIVE_L1_SLIDER.Pending=false
            nativeCommitError="Native level-one restoration is unavailable."
            -- Leave the historical wrapper mounted, with its Confirm blocked
            -- by the unverified L1 history guard.
        else
            local ok,result,why=pcall(HB_NATIVE_L1_SLIDER.OnPrepare)
            if not ok or result~=true then
                HB_NATIVE_L1_SLIDER.Pending=false
                nativeCommitError=tostring(why or result or "Build preparation failed")
                Log("NATIVE_SLIDER_L1_PREPARE_FAILED "..nativeCommitError)
            else
                Log("NATIVE_SLIDER_L1_PREPARE_SENT from="..old)
            end
        end
    elseif HB_NATIVE_L1_SLIDER.Screen or (not nativePilotActive
        and Read(live,"Type")=="gui::DCCharacterCreation") then
        -- Leaving vanilla L1 never commits it. The original engine VM stays
        -- alive and retains its real selection state underneath the wrapper.
        if Read(live,"Type")=="gui::DCCharacterCreation" then
            local _,_,root=NativeVM()
            HB_NATIVE_L1_SLIDER.CaptureNativeTabs(root)
        end
        HB_NATIVE_L1_SLIDER.Screen=false
        HB_NATIVE_L1_SLIDER.FullRespecChanged=false
        HB_NATIVE_L1_SLIDER.Pending=false
        HB_NATIVE_L1_SLIDER.Prepared=false
        HB_NATIVE_L1_SLIDER.AutoConfirm=false
        nativePilotMode="historical"
        queuedRefresh=true
        QueueOnUI(function()
            if not previewOpen or currentLevel<2 or nativePilotWrapping
                or nativeCancelAwaitingDecision or nativePilotActive then return end
            local native,screen=NativeVM()
            if (screen=="CharacterRespec" or screen=="CharacterRespec_c")
                and Read(native,"Type")=="gui::DCCharacterCreation" then
                local ok,why=pcall(Bind)
                if not ok then Log("NATIVE_SLIDER_REBIND_ERROR "..tostring(why)) end
                NativeHistoricalStart()
            end
        end)
    elseif hasLiveWrapper and nativePilotMode=="historical" then
        RequestNativeHistoricalRefresh("level "..currentLevel)
    else
        -- The original C++ ViewModel may still own CharacterRespec after No.
        -- A visible slider is not proof of a mounted historical wrapper.
        -- Don't assume a missing wrapper is alive: request a guarded rewrap.
        nativePilotActive=false
        nativePilotMode="historical"
        queuedRefresh=true
        QueueOnUI(function()
            if not previewOpen or nativePilotWrapping or nativeCancelAwaitingDecision
                or nativePilotActive then return end
            local native,screen=NativeVM()
            if (screen=="CharacterRespec" or screen=="CharacterRespec_c")
                and Read(native,"Type")=="gui::DCCharacterCreation" then
                -- Keep the game's restored original C++ DC; Bind refreshes
                -- only the separate historical slider's command source.
                local ok,reason=pcall(Bind)
                if not ok then Log("NATIVE_SLIDER_REBIND_ERROR "..tostring(reason)) end
                NativeHistoricalStart()
            else
                Log("NATIVE_SLIDER_REATTACH_WAIT nativeType="
                    ..tostring(Read(native,"Type")).." screen="..tostring(screen))
            end
        end)
    end
    UpdateVM()
    return true
end


-- Feat scroll position belongs to the live Feats ListBox, not a detached
-- scrollbar thumb. Never attempt to assign scroll.Value on a rebuilt view.
-- Passive-secondary tabs are appended on the LIVE historical VM below.

-- Keep the original feat selection VM and its ListBox/scroll position alive
-- when a feat's secondary groups are added, replaced, or removed.  A
-- ClassDivergence/Ability Improvement selector is a PassivePairAdd, not a
-- GenericPassiveAdd; otherwise changing between Class Specialist feats
-- rebuilds the entire historical host and can leave the old passive panel
-- mounted with the previous class's options.
function HB_MULTIFACETED_UI.HBFeatSecondaryKind(kind)
    return kind=="GenericPassiveAdd" or kind=="GenericSpellAdd"
        or kind=="PassivePairAdd"
end
function HB_MULTIFACETED_UI.HBGenericBaseCount(panels)
    local n=#panels
    while n>0 and panels[n] and HB_MULTIFACETED_UI.HBFeatSecondaryKind(panels[n].Kind) do
        n=n-1
    end
    return n
end

-- Unlike assigning a ScrollBar.Value, these calls operate on the scroll
-- *content* and cannot detach the thumb from the actual list position.
HB_MULTIFACETED_UI.FeatScrollRestore=nil
function HB_MULTIFACETED_UI.HBFeatScrollWidget()
    local _,name,widget=NativeVM()
    if name~="CharacterRespec" and name~="CharacterRespec_c" then return nil end
    if not widget then return nil end
    local ok,view=pcall(function() return widget:Find("HB_HistoricalFeatScrollViewer") end)
    return ok and view or nil
end
function HB_MULTIFACETED_UI.HBCaptureFeatScrollOffset()
    local view=HB_MULTIFACETED_UI.HBFeatScrollWidget()
    local offset=tonumber(Read(view,"VerticalOffset"))
    if offset and offset>=0 then
        HB_MULTIFACETED_UI.FeatScrollRestore={level=currentLevel,offset=offset}
        Log("NATIVE_FEAT_CONTENT_SCROLL_CAPTURE level="..currentLevel.." offset="..offset)
    end
end
function HB_MULTIFACETED_UI.HBRestoreFeatContentScroll()
    local pending=HB_MULTIFACETED_UI.FeatScrollRestore
    if not pending or pending.level~=currentLevel then return end
    local view=HB_MULTIFACETED_UI.HBFeatScrollWidget()
    if not view then return end
    local ok,error=pcall(function() view:ScrollToVerticalOffset(pending.offset) end)
    local now=tonumber(Read(view,"VerticalOffset"))
    Log("NATIVE_FEAT_CONTENT_SCROLL_RESTORE level="..currentLevel
        .." requested="..tostring(pending.offset).." actual="..tostring(now)
        .." ok="..tostring(ok)..(ok and "" or " error="..tostring(error)))
    -- Never set ScrollBar.Value; if the scroll-view API is unavailable leave
    -- normal scrolling intact rather than leaving a frozen scrollbar thumb.
    HB_MULTIFACETED_UI.FeatScrollRestore=nil
end

function HB_MULTIFACETED_UI.HBRemoveLastNativeGroup(collection)
    local before=CollectionCount(collection)
    if type(before)~="number" or before<=0 then return false,"invalid count" end
    local attempts={
        function() collection:RemoveAt(before-1) end,
        function() collection:RemoveAt(before) end,
        function() table.remove(collection,before) end,
        function() collection[before]=nil end
    }
    for _,remove in ipairs(attempts) do
        local ok=pcall(remove)
        if ok and CollectionCount(collection)==before-1 then return true end
    end
    return false,"native collection does not support removal"
end

-- Reuse the *existing* selector VM when replacing one generic group with
-- another.  The presentation model is a Notify-enabled Noesis instance, so
-- update the fields rather than swapping CharacterRespec's DataContext.
function HB_MULTIFACETED_UI.HBCopyGenericGroupModel(dst,src)
    local properties={"Name","Description","Passives","MaxSelectedPassiveCount",
        "SelectedPassiveCount","IsComplete","UpdateState","HB_HistoricalRenderKind",
        "HB_HistoricalPanelIndex"}
    for _,field in ipairs(properties) do
        local value=Read(src,field)
        if value~=nil then dst[field]=value end
    end
end

function HB_MULTIFACETED_UI.TryAppendFeatTabsInPlace(previousPanels,featIndex,option,id)
    local afterPanels=AllPanels()
    local oldBase=HB_MULTIFACETED_UI.HBGenericBaseCount(previousPanels)
    local newBase=HB_MULTIFACETED_UI.HBGenericBaseCount(afterPanels)
    if oldBase~=newBase then return false,"non-generic tab layout changed" end
    for i=1,oldBase do
        local a,b=previousPanels[i],afterPanels[i]
        if not a or not b or a.Kind~=b.Kind or a.Title~=b.Title then
            return false,"base tab layout changed"
        end
    end
    -- All modified tabs must be attached to one selected feat. Never hijack
    -- unrelated class, spell, or secondary-feature tabs.
    for i=oldBase+1,#previousPanels do
        if not HB_MULTIFACETED_UI.HBFeatSecondaryKind(previousPanels[i].Kind) then
            return false,"old non-feat-secondary suffix"
        end
    end
    for i=oldBase+1,#afterPanels do
        if not HB_MULTIFACETED_UI.HBFeatSecondaryKind(afterPanels[i].Kind) then
            return false,"new non-feat-secondary suffix"
        end
    end
    if not nativePilotActive or nativePilotWrapping then return false,"native editor not active" end
    local live,screen=NativeVM()
    local original=Read(CurrentVM(),"HB_NativeOriginalContext")
    if (screen~="CharacterRespec" and screen~="CharacterRespec_c")
        or not live or not original then return false,"native host unavailable" end
    local classTabs=Read(live,"ClassPassives")
    local secondaryTabs=Read(live,"ClassAndSubClassPassives")
    local details=Read(live,"ClassProgressionDetails")
    local otherTabs=Read(details,"NotSubPassiveSelectors")
    if not classTabs or not secondaryTabs or not otherTabs then
        return false,"native tab collections unavailable"
    end
    if CollectionCount(classTabs)~=#previousPanels
        or CollectionCount(secondaryTabs)~=#previousPanels
        or CollectionCount(otherTabs)~=#previousPanels then
        return false,"native collection counts mismatch"
    end
    local featTab=GetCollectionItem(classTabs,featIndex-1)
    if tonumber(Read(featTab,"HB_HistoricalPanelIndex"))~=featIndex then
        local content=NativeHistoricalFindVisual()
        local rendered=Read(content,"DataContext")
        if tonumber(Read(rendered,"HB_HistoricalPanelIndex"))==featIndex then
            featTab=rendered
        end
    end
    local featModel=featTab and Read(featTab,"HB_HistoricalFeatModel")
    local featDetails=featModel and Read(featModel,"SelectedFeatDetails")
    if not featModel or not featDetails then return false,"original feat selection model missing" end
    local generated=BuildHistoricalModels(original,nativeMenuGeneration)
    if #generated~=#afterPanels then return false,"new group count mismatch" end
    -- Preserve the actual SelectableFeats model and its selection, not just
    -- the rendered scrollbar. The current feat ListBox remains mounted.
    featModel.SelectedFeat=option
    featDetails.HasFeat=true
    featDetails.Name=tostring(Read(option,"Name") or "")
    local detailText=Read(featDetails,"Description")
    if detailText then
        local names=LoadFeatTextCache()
        detailText.Text=names[id] or tostring(Read(option,"Description") or "")
    end
    -- Noesis group view-models are stateful.  Copying Passives/Name onto an
    -- existing selector group is not equivalent to replacing the group: the
    -- native visual presenter may retain its old data template/selection.
    -- Use the two operations already exercised independently in BG3:
    -- complex -> simple removes the trailing selector groups, while simple
    -- -> complex appends the freshly generated groups.  Compose those here
    -- WITHOUT replacing the feat ListBox (or writing its scrollbar value).
    -- This also covers different numbers of groups between two complex feats.
    local oldGeneric=#previousPanels-oldBase
    local newGeneric=#afterPanels-newBase
    local replaceExisting=oldGeneric>0 and newGeneric>0
    -- Reuse the original feat ListBox but replace every secondary group as
    -- a new ViewModel. Noesis may retain the previous passive group after a
    -- same-size specialist-to-specialist selection if it is edited in place.
    local retain=replaceExisting and oldBase or math.min(#previousPanels,#afterPanels)
    local priorSecondary=oldGeneric>0 and previousPanels[oldBase+1] or nil
    local nextSecondary=newGeneric>0 and afterPanels[newBase+1] or nil
    if (priorSecondary and priorSecondary.Kind=="PassivePairAdd")
        or (nextSecondary and nextSecondary.Kind=="PassivePairAdd") then
        Log("NATIVE_SPECIALIST_SWITCH level="..tostring(currentLevel)
            .." oldFeat="..tostring(priorSecondary and priorSecondary.FeatId or "")
            .." newFeat="..tostring(nextSecondary and nextSecondary.FeatId or "")
            .." oldOptions="..tostring(priorSecondary and #(priorSecondary.Options or {}) or 0)
            .." newOptions="..tostring(nextSecondary and #(nextSecondary.Options or {}) or 0)
            .." retained="..tostring(retain))
    end
    -- Remove first, then append.  The old implementation appended only when
    -- counts grew and tried an in-place property copy for a 1:1 swap.  That
    -- path forced an expensive full VM rebuild for Frontier <-> Arcane Archer.
    for i=#previousPanels,retain+1,-1 do
        local ok1,why1=HB_MULTIFACETED_UI.HBRemoveLastNativeGroup(classTabs)
        local ok2,why2=HB_MULTIFACETED_UI.HBRemoveLastNativeGroup(secondaryTabs)
        local ok3,why3=HB_MULTIFACETED_UI.HBRemoveLastNativeGroup(otherTabs)
        if not (ok1 and ok2 and ok3) then
            return false,"native selector removal unsupported: "
                ..tostring(why1 or why2 or why3)
        end
    end
    for i=retain+1,#afterPanels do
        local group=generated[i]
        classTabs[#classTabs+1]=group
        secondaryTabs[#secondaryTabs+1]=group
        otherTabs[#otherTabs+1]=group
    end
    if CollectionCount(classTabs)~=#afterPanels
        or CollectionCount(secondaryTabs)~=#afterPanels
        or CollectionCount(otherTabs)~=#afterPanels then
        return false,"native tab reconciliation count mismatch"
    end
    if passiveGroupIndex>#afterPanels then passiveGroupIndex=featIndex end
    Log("NATIVE_FEAT_TABS_RECONCILED level="..currentLevel.." feat="..id
        .." before="..#previousPanels.." after="..#afterPanels
        .." mode="..(replaceExisting and "replace-secondary" or
            (newGeneric>oldGeneric and "append-secondary" or "remove-secondary"))
        .." retained="..(retain-oldBase))
    return true,"native feat tabs reconciled"
end

-- Read-only bridge discovery: inspect the *actual* game-owned level-one
-- selector models before the historical wrapper replaces their presentation.
-- Do not call TogglePassive/SelectSpell here: their native command parameter
-- contract is not yet validated and may commit unrelated respec changes.
HB_L1_NATIVE_BRIDGE={Captured=false,File="HomeBrew/Diagnostics/HB_LevelOne_NativeGrantBridge.txt"}
function HB_L1_NATIVE_BRIDGE.Inspect(original,requestedLevel)
    if HB_L1_NATIVE_BRIDGE.Captured or requestedLevel~=1 then return end
    HB_L1_NATIVE_BRIDGE.Captured=true
    local rows={"HB level-one original native grant bridge (read-only)",
        "screen=CharacterRespec nativeType="..tostring(Read(original,"Type")),
        "selectedClass="..ValueLabel(Read(original,"SelectedClass")),
        "selectedSubClass="..ValueLabel(Read(original,"SelectedSubClass")),
        "creationStep="..ValueLabel(Read(original,"CharacterCreationStep"))}
    local function Line(text) rows[#rows+1]=tostring(text) end
    for _,command in ipairs({"TogglePassive","ToggleSkill","SelectSpell",
        "DeselectSpell","FinishCreating"}) do
        local value=Read(original,command)
        Line("command."..command.."=present:"..tostring(value~=nil)
            .." type:"..tostring(value and (Read(value,"Type") or type(value)) or "nil"))
    end
    local groups={"ClassPassives","ClassAndSubClassPassives","SubClassPassives",
        "ClassSkills","ProgressionSpells","ProgressionCantrips"}
    local found=0
    local function InspectOption(item,label)
        local parts={}
        for _,field in ipairs({"Type","Name","DisplayName","PassiveId","SpellId",
            "Id","ID","UUID","IsSelected","Selected","IsChecked",
            "IsAvailable","IsEnabled","CanSelect"}) do
            local v=Read(item,field)
            if v~=nil and type(v)~="table" and type(v)~="userdata" then
                parts[#parts+1]=field.."="..tostring(v):sub(1,90)
            end
        end
        Line(label.." {"..table.concat(parts,", ").."}")
    end
    for _,name in ipairs(groups) do
        local col=Read(original,name)
        local count=CollectionCount(col)
        Line("group."..name.." count="..tostring(count)
            .." type="..tostring(Read(col,"Type") or type(col)))
        if count and count>0 then
            for n=0,math.min(count,5)-1 do
                local item=GetCollectionItem(col,n)
                InspectOption(item,name.."["..n.."]")
                if item then
                    for _,childField in ipairs({"Passives","ClassPassiveSelectors",
                        "SubPassiveSelectors","Spells","SpellSelectors","Skills"}) do
                        local children=Read(item,childField)
                        local c=CollectionCount(children)
                        if c~=nil then
                            Line("  "..childField.." count="..tostring(c))
                            for i=0,math.min(c,8)-1 do
                                InspectOption(GetCollectionItem(children,i),
                                    "  "..childField.."["..i.."]")
                            end
                        end
                    end
                end
                found=found+1
            end
        end
    end
    Line("inspectedTopLevelGroups="..found)
    local report=table.concat(rows,"\n").."\n"
    local saved=false
    if Ext.IO and Ext.IO.SaveFile then
        local ok,result=pcall(Ext.IO.SaveFile,HB_L1_NATIVE_BRIDGE.File,report)
        saved=ok and result~=false and result~=nil
    end
    -- Log only compact evidence, never dump the full C++ ViewModel in a Tick.
    Log("NATIVE_LEVEL_ONE_BRIDGE_DISCOVERY selected="..tostring(found)
        .." reportSaved="..tostring(saved)
        .." native="..tostring(Read(original,"Type")))
    if not saved then
        for i=1,math.min(#rows,35) do Log("NATIVE_L1_BRIDGE "..rows[i]) end
    end
end

NativePilotStart = function(isRefresh)
    if not previewOpen or nativePilotWrapping or (nativePilotActive and not isRefresh) then return end
    queuedRefresh=false
    nativeRefreshQueued=false
    nativePilotWrapping=true
    local wasActive=nativePilotActive
    local requestedLevel=currentLevel
    local requestedIndex=passiveGroupIndex
    if not wasActive then
        nativePilotReport="Connecting native historical menu..."
        UpdateVM()
    end
    QueueOnUI(function()
        if not previewOpen then
            nativePilotWrapping=false
            return
        end
        -- Use the latest slider/group values when the deferred UI callback
        -- actually executes, not an obsolete intermediate slider tick.
        requestedLevel=currentLevel
        requestedIndex=passiveGroupIndex
        local ok,err=pcall(function()
            local live,name,node=NativeVM()
            if name~="CharacterRespec" and name~="CharacterRespec_c" then
                error("Native CharacterRespec screen not found")
            end
            if not live or not node then error("Native respec widget is unavailable") end
            local holder=CurrentVM()
            if not holder then error("Historical overlay ViewModel unavailable") end
            -- Only ever wrap the original C++ character creation VM, not a
            -- previous se:: proxy. Keep the original in a Noesis-owned Object.
            local original=wasActive and Read(holder,"HB_NativeOriginalContext") or live
            if Read(original,"Type")~="gui::DCCharacterCreation" then
                error("Original native ViewModel missing or invalid: "..tostring(Read(original,"Type")))
            end
            if requestedLevel==1 then
                local safe,why=pcall(HB_L1_NATIVE_BRIDGE.Inspect,original,requestedLevel)
                if not safe then
                    Log("NATIVE_LEVEL_ONE_BRIDGE_PROBE_ERROR "..tostring(why))
                end
            end
            if not nativePilotTypeRegistered then
                Ext.UI.RegisterType("HB_HistoricalNativeCommandPilot_GroupProxyV5", {
                    TogglePassive={Type="Command"},
                    -- The game's Confirm button must not commit a real respec
                    -- while the screen is displaying historical, staged data.
                    FinishCreating={Type="Command"},
                    -- A cancel must restore the ORIGINAL C++ ViewModel before
                    -- its C++ Exit command runs. Letting an inherited exit
                    -- execute against the historical se:: wrapper left the
                    -- game's modal input / load-game state unusable.
                    ExitCharacterRespec={Type="Command"},
                    ExitCharacterCreation={Type="Command"},
                    ActionCancelCommand={Type="Command"},
                    CancelTaskCommand={Type="Command"},
                    IsCharacterComplete={Type="Bool", Notify=true},
                    -- BG3's gameplay/appearance 'Continue' buttons check
                    -- IsCharacterCompleteExceptName, NOT IsCharacterComplete.
                    -- Both must reflect HB's unfinished historical selection.
                    IsCharacterCompleteExceptName={Type="Bool", Notify=true},
                    HB_HistoricalProbeLevel={Type="Int32", Notify=true},
                    HB_NativeHistoricalOnlyPassives={Type="Bool", Notify=true},
                    HB_NativeReleaseHistoricalPanel={Type="Bool", Notify=true},
                    ClassPassives={Type="Collection"},
                    ClassAndSubClassPassives={Type="Collection"},
                    ClassProgressionDetails={Type="Object"},
                    HB_HistoricalRenderKind={Type="String",Notify=true},
                    HB_HistoricalFeatModel={Type="Object"},
                    HB_HistoricalSpellModel={Type="Object"},
                    HB_HistoricalSpellSummary={Type="String",Notify=true},
                    SelectSpell={Type="Command"},
                    DeselectSpell={Type="Command"},
                    HB_HistoricalSelectFeat={Type="Command"},
                    HB_HistoricalSetActiveTab={Type="Command"},
                    HB_HistoricalEmptyGroup={Type="Object"},
                    HB_HistoricalCurrentSpellGroup={Type="Object"},
                }, "gui::DCCharacterCreation")
                nativePilotTypeRegistered=true
            end
            local wrapper=Ext.UI.Instantiate("se::HB_HistoricalNativeCommandPilot_GroupProxyV5",original)
            if not wrapper then error("Native wrapper instantiation returned nil") end
            -- Intercept native exit BEFORE the C++ respec screen is destroyed.
            -- Unlike post-unmount UI cleanup, this can restore the owned
            -- DataContext while both the host widget and its saved C++ VM
            -- still exist. Only then may BG3 execute its own exit command.
            local cancelGeneration=nativeMenuGeneration+1
            local function HandleHistoricalCancel(nativeCommand,parameter)
                if cancelGeneration~=nativeMenuGeneration
                    or not previewOpen or not nativePilotActive or nativePilotWrapping
                    or nativeCommitPending then
                    Log("NATIVE_CANCEL_INTERCEPT_BLOCKED command="..tostring(nativeCommand)
                        .." wrapping="..tostring(nativePilotWrapping))
                    return
                end
                Log("NATIVE_CANCEL_INTERCEPT command="..tostring(nativeCommand)
                    .." level="..tostring(currentLevel))
                nativeCancelAwaitingDecision=true
                cancelModalDiscoverySignature=nil
                nativeCancelSawDialog=false
                nativeCancelDialogGonePolls=0
                nativeCancelMissingPolls=0
                NativePilotStop(false,function(restored)
                    if not restored then
                        nativeCancelAwaitingDecision=false
                        Log("NATIVE_CANCEL_RESTORE_FAILED command="..tostring(nativeCommand)
                            .." no C++ cancellation dispatched")
                        return
                    end
                    -- Do not reuse a detached se:: wrapper command. Read the
                    -- freshly restored native DC after its Noesis transition.
                    local live,screen=NativeVM()
                    if (screen~="CharacterRespec" and screen~="CharacterRespec_c")
                        or Read(live,"Type")~="gui::DCCharacterCreation" then
                        nativeCancelAwaitingDecision=false
                        Log("NATIVE_CANCEL_NATIVE_MISSING command="..tostring(nativeCommand))
                        return
                    end
                    local command=Read(live,nativeCommand)
                    if not command then
                        nativeCancelAwaitingDecision=false
                        Log("NATIVE_CANCEL_COMMAND_MISSING command="..tostring(nativeCommand))
                        return
                    end
                    local ready,allowed=pcall(function() return command:CanExecute(parameter) end)
                    if not ready or allowed~=true then
                        nativeCancelAwaitingDecision=false
                        Log("NATIVE_CANCEL_COMMAND_DENIED command="..tostring(nativeCommand)
                            .." ready="..tostring(ready).." allowed="..tostring(allowed))
                        return
                    end
                    -- The old historical preview is a recovery-only control.
                    -- Once the real native VM has been restored and BG3 accepts
                    -- Cancel, hide that panel *before* BG3's discard-warning
                    -- modal opens. Otherwise it appears behind the warning.
                    local historicalHolder=CurrentVM()
                    if historicalHolder then historicalHolder.HB_NativeVisible=false end
                    local sent,reason=pcall(function() command:Execute(parameter) end)
                    Log("NATIVE_CANCEL_NATIVE_EXECUTED command="..tostring(nativeCommand)
                        .." success="..tostring(sent)
                        ..(sent and "" or " error="..tostring(reason)))
                    if sent then
                        -- Do NOT call bridge.Hide() at this point: Execute
                        -- usually opens BG3's unsaved-changes Yes/No prompt.
                        -- No must return to the same historical editor. The
                        -- periodic guard below distinguishes that from Yes,
                        -- which unmounts CharacterRespec and ends the session.
                        Log("NATIVE_CANCEL_WARNING_PENDING original session retained")
                        UpdateVM()
                    else
                        nativeCancelAwaitingDecision=false
                        UpdateVM()
                    end
                end)
            end
            for _,commandName in ipairs({"ExitCharacterRespec","ExitCharacterCreation",
                "ActionCancelCommand","CancelTaskCommand"}) do
                local callbackName=commandName
                wrapper[callbackName]:SetHandler(function(_,parameter)
                    HandleHistoricalCancel(callbackName,parameter)
                end)
            end
            local boundPanel=nil
            wrapper.HB_HistoricalProbeLevel=requestedLevel
            local featMode=(nativePilotMode=="historical" and IsRecordedFeatPanel(ActivePanel()))
            local spellMode=(nativePilotMode=="historical" and IsRecordedSpellPanel(ActivePanel()))
            -- Per-entry kind and model are carried by each native passive
            -- subtab; the wrapper never picks one template for the level.
            wrapper.HB_NativeHistoricalOnlyPassives=(nativePilotMode=="historical")
            wrapper.HB_NativeReleaseHistoricalPanel=false
            -- Genuine BG3 native spell templates issue SelectSpell/DeselectSpell
            -- commands. Intercept rather than letting them reach C++ respec.
            local clickGeneration=nativeMenuGeneration+1
            wrapper.HB_HistoricalSetActiveTab:SetHandler(function(command,param)
                if clickGeneration~=nativeMenuGeneration or not nativePilotActive
                    or nativePilotWrapping or nativePilotMode~="historical" then return end
                local tab=tonumber(Read(param,"HB_HistoricalPanelIndex"))
                if not tab or not AllPanels()[tab] then return end
                if passiveGroupIndex~=tab then
                    Log("NATIVE_HISTORICAL_TAB_SELECTED level="..currentLevel
                        .." from="..passiveGroupIndex.." to="..tab)
                    passiveGroupIndex=tab
                    armedFrom=nil
                    if currentLevel~=1 then HB_MULTIFACETED_UI.Clear() end
                    nativeSpellArmed=nil
                    passiveFeedback=""
                end
            end)
            wrapper.HB_HistoricalSelectFeat:SetHandler(function(command,param)
                if clickGeneration~=nativeMenuGeneration or not nativePilotActive
                    or nativePilotWrapping or nativePilotMode~="historical" then return end
                local id=tostring(Read(param,"FeatId") or "")
                local index=tonumber(Read(param,"HB_HistoricalPanelIndex"))
                local stampedLevel=tonumber(Read(param,"HB_HistoricalLevel"))
                local stampedGeneration=tonumber(Read(param,"HB_HistoricalGeneration"))
                local panels=AllPanels()
                local panel=index and panels[index] or nil
                if stampedLevel~=currentLevel or stampedGeneration~=nativeMenuGeneration
                    or id=="" or not IsRecordedFeatPanel(panel) then
                    Log("NATIVE_FEAT_SELECT_IGNORED missing native option context")
                    return
                end
                passiveGroupIndex=index
                if HB_SPECIALIST_MISSING_SELECTOR(id) then
                    local message="Class Specialist passive choices are not available without an exact feat selector."
                    nativeCommitError=""
                    passiveFeedback=message
                    local featGroup=(Read(Read(CurrentVM(),"ClassProgressionDetails"),
                        "NotSubPassiveSelectors"))
                    local featProxy=GetCollectionItem(featGroup,index-1)
                    if not featProxy or tonumber(Read(featProxy,"HB_HistoricalPanelIndex"))~=index then
                        local center=NativeHistoricalFindVisual()
                        featProxy=Read(center,"DataContext")
                    end
                    local featModel=Read(featProxy,"HB_HistoricalFeatModel")
                    local originalId=tostring(CurrentEffectivePicks(panel)[1] or "")
                    local options=Read(featModel,"SelectableFeats")
                    for n=0,math.min(CollectionCount(options) or 0,600)-1 do
                        local option=GetCollectionItem(options,n)
                        if tostring(Read(option,"FeatId") or "")==originalId then
                            pcall(function() featModel.SelectedFeat=option end)
                            break
                        end
                    end
                    Log("NATIVE_SPECIALIST_PLACEHOLDER_BLOCKED feat="..id
                        .." retained="..originalId.." level="..currentLevel)
                    SyncHistoricalConfirmEnabled("specialist selection blocked")
                    return
                end
                local selected=CurrentEffectivePicks(panel)
                if tostring(selected[1] or "")==id then return end
                local previousPanels=panels
                -- The underlying SelectedFeat here is a temporary se::
                -- model. Only HB's strict server-checked staging is allowed.
                passiveRows={}
                local target=nil
                for _,option in ipairs(panel.Options or {}) do
                    local oid=tostring(option.PassiveId or "")
                    if oid~="" then
                        passiveRows[#passiveRows+1]={Id=oid,Name=Label(option)}
                        if oid==id then target=#passiveRows end
                    end
                end
                if not target then return end
                local accepted=StageChoice(target)
                local after=CurrentEffectivePicks(panel)
                if not accepted or tostring(after[1] or "")~=id then
                    nativeCommitError="Feat selection was not staged: "..tostring(passiveFeedback)
                else
                    nativeCommitError=""
                end
                Log("NATIVE_FEAT_SELECT level="..currentLevel.." tab="..index
                    .." feat="..id.." result="..tostring(passiveFeedback))
                -- The single reconciliation path keeps the same Feats ListBox
                -- mounted for simple -> complex, complex -> simple and
                -- complex -> complex swaps. Avoid a second fixed-feat model
                -- updater: it previously tried to access a nonexistent detail.
                local reason=""
                local canStay=false
                if accepted and tostring(after[1] or "")==id then
                    local worked,success,why=pcall(HB_MULTIFACETED_UI.TryAppendFeatTabsInPlace,
                        previousPanels,index,param,id)
                    canStay=worked and success==true
                    reason=worked and tostring(why) or tostring(success)
                end
                if canStay then
                    HB_MULTIFACETED_UI.FeatScrollRestore=nil
                    Log("NATIVE_FEAT_SELECT_IN_PLACE level="..currentLevel
                        .." feat="..id.." reason="..tostring(reason))
                    SyncHistoricalConfirmEnabled("feat selected in place")
                    QueueOnUI(UpdateVM)
                else
                    Log("NATIVE_FEAT_REBUILD_REQUIRED level="..currentLevel
                        .." feat="..id.." reason="..tostring(reason))
                    HB_MULTIFACETED_UI.HBCaptureFeatScrollOffset()
                    RequestNativeHistoricalRefresh("native feat choice: layout changed")
                    local generation=nativeMenuGeneration
                    QueueOnUI(function()
                        QueueOnUI(function()
                            if nativeMenuGeneration>=generation and previewOpen then
                                HB_MULTIFACETED_UI.HBRestoreFeatContentScroll()
                            end
                        end)
                    end)
                end
            end)
            wrapper.SelectSpell:SetHandler(function(command,param)
                nativeSpellPilotClicks=nativeSpellPilotClicks+1
                Log("NATIVE_SPELL_VISUAL_CLICK action=select level="..currentLevel
                    .." click="..nativeSpellPilotClicks
                    .." paramType="..tostring(Read(param,"Type") or type(param)))
                if clickGeneration~=nativeMenuGeneration or not previewOpen
                    or not nativePilotActive or nativePilotWrapping
                    or nativePilotMode~="historical" then return end
                local didStage,reason=TryStageNativeSpell(param or command)
                nativePilotReport=tostring(reason)
                nativeCommitError=didStage and "" or tostring(reason or "Historical spell selection rejected")
                -- A click that cannot be resolved has NOT changed staging.
                -- Rebuilding for that click advances the UI generation while
                -- Noesis still displays the prior tiles, making the next click
                -- stale again. Only rebuild if a choice was processed or a
                -- legitimate current-selector command requires visual reset.
                if didStage or (reason~="native spell click lacks a matching current-level historical option"
                    and reason~="Already selected; use the selected tile to remove it.") then
                    RequestNativeHistoricalRefresh(didStage and "staged native historical spell"
                        or "rejected native spell choice")
                end
                QueueOnUI(UpdateVM)
            end)
            wrapper.DeselectSpell:SetHandler(function(command,param)
                nativeSpellPilotClicks=nativeSpellPilotClicks+1
                Log("NATIVE_SPELL_VISUAL_CLICK action=deselect level="..currentLevel
                    .." click="..nativeSpellPilotClicks
                    .." paramType="..tostring(Read(param,"Type") or type(param)))
                if clickGeneration~=nativeMenuGeneration or not previewOpen
                    or not nativePilotActive or nativePilotWrapping
                    or nativePilotMode~="historical" then return end
                local id,group=ResolveHistoricalSpellClick(param or command)
                local panel=group and AllPanels()[group] or nil
                if not id or not CanStageNativeSpell(panel)
                    or (panel.Kind~="AccordAdd" and panel.Kind~="AccordRecorded"
                        and panel.Kind~="GenericSpellAdd" and panel.Kind~="GenericSpellRecorded"
                        and panel.Kind~="ClassSpellGroup"
                        and HistoricalSpellRankClient(tostring(panel.Other.From or ""))==nil) then
                    nativePilotReport="Historical spell selection is view-only."
                elseif panel.Kind=="GenericSpellAdd" or panel.Kind=="GenericSpellRecorded" then
                    local accepted,why=TryStageNativeSpell(param or command)
                    nativeCommitError=accepted and "" or tostring(why)
                    nativePilotReport=tostring(why or "Spell choice updated")
                    RequestNativeHistoricalRefresh(accepted and "feat spell unchecked" or "feat spell uncheck rejected")
                elseif panel.Kind=="AccordAdd" then
                    local accepted,why=TryStageNativeSpell(param or command,true)
                    nativeCommitError=accepted and "" or tostring(why)
                    nativePilotReport=tostring(why or "Accord choice updated")
                    RequestNativeHistoricalRefresh(accepted and "Accord cantrip unchecked" or "Accord uncheck rejected")
                elseif panel.Kind=="ClassSpellGroup" then
                    local holes=HB_CLASS_SPELL_UI.Unchecked[currentLevel] or {}
                    local edits=previewOther[currentLevel] or {}
                    local found=false
                    for _,row in ipairs(panel.Rows or {}) do
                        local key=ChoiceKey(row)
                        local effective=tostring(edits[key] or row.From or "")
                        if effective==id and not holes[key] then
                            holes[key]=true
                            found=true
                            break
                        end
                    end
                    HB_CLASS_SPELL_UI.Unchecked[currentLevel]=holes
                    local n=#CurrentEffectivePicks(panel)
                    nativeCommitError=found and "" or "Selected class spell did not match its original slot."
                    nativePilotReport=found and ("Choose a replacement spell ("..n.."/"..panel.MaxChoices..").") or nativeCommitError
                    Log("NATIVE_CLASS_SPELL_GROUP_UNCHECK level="..currentLevel
                        .." count="..n.." max="..panel.MaxChoices)
                    RequestNativeHistoricalRefresh(found and "class spell deselected" or "class spell uncheck rejected")
                elseif panel.Kind=="AccordRecorded" then
                    local state=HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel] or {}
                    local found=false
                    local chosen=CurrentEffectivePicks(panel)
                    for slot,selected in ipairs(chosen) do
                        if selected==id then
                            local key=ChoiceKey(panel.Rows[slot])
                            state[key]=true
                            HB_MULTIFACETED_NEW.Accord.Unchecked[currentLevel]=state
                            found=true
                            Log("NATIVE_ACCORD_RECORDED_UNCHECK level="..currentLevel.." slot="..key)
                            break
                        end
                    end
                    nativeCommitError=found and "" or "Accord selection could not be matched to its original slot."
                    nativePilotReport=found and "Choose a replacement Accord cantrip before confirming." or nativeCommitError
                    RequestNativeHistoricalRefresh(found and "Accord recorded cantrip unchecked" or "Accord recorded uncheck rejected")
                else
                    local chosen=CurrentEffectivePicks(panel)
                    if tostring(chosen[1] or "")~=id then
                        nativePilotReport="Only the currently selected spell can be removed."
                    else
                        passiveGroupIndex=group
                        nativeSpellArmed={level=currentLevel,panelIndex=group}
                        nativeCommitError=""
                        nativePilotReport="Choose a replacement before confirming."
                        RequestNativeHistoricalRefresh("native spell slot deselected")
                    end
                end
                QueueOnUI(UpdateVM)
            end)
            -- The native Confirm button is the single Selective Respec commit.
            -- It NEVER executes the wrapped C++ transaction. Only the proven
            -- replay RPC may proceed, after the original VM is safely restored.
            -- The ordinary BG3 Confirm button already binds its enabled
            -- state to IsCharacterComplete. Reuse it: no extra button or
            -- error-message panel for an intentionally half-armed choice.
            local nativeCanConfirm=HistoricalConfirmIsComplete()
            wrapper.IsCharacterComplete=nativeCanConfirm
            wrapper.IsCharacterCompleteExceptName=nativeCanConfirm
            Log("NATIVE_CONFIRM_AVAILABILITY level="..tostring(requestedLevel)
                .." enabled="..tostring(wrapper.IsCharacterComplete)
                .." exceptName="..tostring(wrapper.IsCharacterCompleteExceptName)
                .." armed="..tostring(armedFrom))
            wrapper.FinishCreating:SetHandler(function()
                if nativeCommitPending or not previewOpen or not nativePilotActive
                    or nativePilotWrapping or nativePilotMode~="historical" then return end
                if not HistoricalConfirmIsComplete() then
                    Log("NATIVE_LEVEL_RESPEC_CONFIRM_BLOCKED incomplete_selection")
                    SyncHistoricalConfirmEnabled("blocked click")
                    return
                end
                nativeCommitError=""
                if HB_NATIVE_L1_SLIDER.Touched then
                    -- A real native L1 selector was visited: commit must be
                    -- performed by the original C++ VM, never HB's historical
                    -- RPC which would discard the L1 choices.
                    if not HB_NATIVE_L1_SLIDER.OnPrepare then
                        nativeCommitError="Native level-one commit handoff is unavailable."
                        UpdateVM();return
                    end
                    HB_NATIVE_L1_SLIDER.AutoConfirm=true
                    HB_NATIVE_L1_SLIDER.Pending=true
                    local ok,ready,reason=pcall(HB_NATIVE_L1_SLIDER.OnPrepare)
                    if not ok or ready~=true then
                        HB_NATIVE_L1_SLIDER.Pending=false
                        HB_NATIVE_L1_SLIDER.AutoConfirm=false
                        nativeCommitError=tostring(reason or ready or "Unable to prepare native Confirm")
                        UpdateVM()
                    else
                        Log("NATIVE_SLIDER_L1_AUTO_CONFIRM_PREPARING level="..currentLevel)
                    end
                    return
                end
                nativeCommitPending=true
                Log("NATIVE_LEVEL_RESPEC_CONFIRM_REQUEST level="..currentLevel
                    .." edits="..LocalHistoricalStageCount())
                if not onNativeConfirm then
                    nativeCommitError="Selective Respec commit callback is unavailable."
                    nativeCommitPending=false
                    QueueOnUI(UpdateVM)
                    return
                end
                NativePilotStop(false,function(restored)
                    if not restored then
                        nativeCommitPending=false
                        nativeCommitError="Cannot restore the original respec interface. No changes were sent."
                        UpdateVM()
                        return
                    end
                    local ok,result,why=pcall(onNativeConfirm)
                    if not ok or result~=true then
                        nativeCommitPending=false
                        nativeCommitError=tostring(why or result or "Unable to confirm Selective Respec")
                        Log("NATIVE_LEVEL_RESPEC_CONFIRM_ERROR "..nativeCommitError)
                        if previewOpen and NativePilotStart then NativePilotStart() end
                    else
                        Log("NATIVE_LEVEL_RESPEC_CONFIRM_SENT")
                    end
                    UpdateVM()
                end)
            end)
            if nativePilotMode=="historical" then
                local groups,details,panel=BuildHistoricalModels(original)
                boundPanel=panel
                for _,group in ipairs(groups) do
                    wrapper.ClassPassives[#wrapper.ClassPassives+1]=group
                    wrapper.ClassAndSubClassPassives[#wrapper.ClassAndSubClassPassives+1]=group
                end
                wrapper.ClassProgressionDetails=details
                -- Pin only the verified, currently active spell tab on the
                -- current Noesis wrapper. Indexed native Collection reads may
                -- return the preceding generation, so the presenter should
                -- never resolve its own replacement group from an index.
                if panel and IsRecordedSpellPanel(panel) then
                    wrapper.HB_HistoricalCurrentSpellGroup=groups[requestedIndex]
                end
                if HasEmptyHistoricalPanel() then
                    -- Owned by the native wrapper, not a Lua global or an
                    -- unreliable indexed collection read during an empty page.
                    wrapper.HB_HistoricalEmptyGroup=groups[1]
                end
            end
            local sourceGeneration=nativeMenuGeneration+1
            wrapper.TogglePassive:SetHandler(function(command,param)
                Log("NATIVE_HISTORICAL_TOGGLE_RECEIVED generation="..sourceGeneration
                    .." current="..nativeMenuGeneration
                    .." active="..tostring(nativePilotActive)
                    .." wrapping="..tostring(nativePilotWrapping)
                    .." paramType="..tostring(Read(param,"Type") or type(param))
                    .." id="..tostring(Read(param,"PassiveId")))
                if not nativePilotActive or nativePilotWrapping
                    or sourceGeneration~=nativeMenuGeneration then
                    Log("NATIVE_HISTORICAL_STALE_CLICK_IGNORED generation="..sourceGeneration)
                    return
                end
                if nativePilotMode=="historical" then
                    -- Never let a Noesis command callback fail silently: when
                    -- an unprotected error occurred between CLICK and STAGE,
                    -- the user saw a permanently empty 0/2 selector. Catch
                    -- it here and keep the Confirm action fail-closed.
                    local ok,err=pcall(HandleHistoricalNativeClick,param or command)
                    if not ok then
                        nativeCommitError="Historical selection failed; please retry or Cancel."
                        Log("NATIVE_HISTORICAL_CLICK_EXCEPTION level="..tostring(currentLevel)
                            .." generation="..tostring(sourceGeneration)
                            .." id="..tostring(Read(param,"PassiveId"))
                            .." error="..tostring(err))
                        SyncHistoricalConfirmEnabled("historical click exception")
                    end
                else
                    nativePilotClicks=nativePilotClicks+1
                    nativePilotReport="Intercepted native click "..nativePilotClicks
                    Log("NATIVE_TOGGLE_INTERCEPT click="..nativePilotClicks)
                end
                QueueOnUI(UpdateVM)
            end)
            if not wasActive then
                -- Observe the native content template BEFORE any historical
                -- XAML triggers run. We cannot safely clear a DataTemplate by
                -- assigning nil through Script Extender; this capture tells
                -- us whether a real restore target already exists.
                local originalPanel=NativeHistoricalFindVisual()
                local originalTemplate=Read(originalPanel,"ContentTemplate")
                local staleKind=Read(Read(originalPanel,"DataContext"),"HB_HistoricalRenderKind")
                local staleHistorical=(staleKind=="Selections" or staleKind=="Feat"
                    or staleKind=="Spell")
                -- An earlier native->historical roundtrip can leave a
                -- historical presenter briefly on screen before the native
                -- XAML reset. Never save that old historical template as the
                -- game's original template for a subsequent transition.
                holder.HB_NativeTemplateWasEmpty=(originalTemplate==nil or staleHistorical)
                if originalTemplate and not staleHistorical then
                    holder.HB_NativeOriginalTemplate=originalTemplate
                end
                Log("NATIVE_ORIGINAL_CONTENT_TEMPLATE empty="
                    ..tostring(originalTemplate==nil)
                    .." staleHistorical="..tostring(staleHistorical)
                    .." type="..tostring(Read(originalTemplate,"Type")))
                holder.HB_NativeOriginalContext=original
                if Read(Read(holder,"HB_NativeOriginalContext"),"Type")~="gui::DCCharacterCreation" then
                    error("Could not retain original native ViewModel")
                end
            end
            -- The native wrapper replacement is deferred and atomic at the UI
            -- thread boundary. It does not execute the risky restore operation.
            node.DataContext=wrapper
            nativePilotActive=true
            nativeMenuGeneration=sourceGeneration
            nativePilotReport=boundPanel and ("Level "..requestedLevel..": "..boundPanel.Title
                .." ("..requestedIndex.."/"..#AllPanels()..")")
                or ("Level "..requestedLevel..": no editable choices")
            Log("NATIVE_HISTORICAL_PAGE generation="..nativeMenuGeneration
                .." level="..requestedLevel.." group="..requestedIndex
                .." kind="..tostring(boundPanel and boundPanel.Kind or "Empty")
                .." mode="..nativePilotMode.." hotRefresh="..tostring(wasActive)
                .." featPreview="..tostring(featMode).." spellPreview="..tostring(spellMode))
            if nativePilotMode=="historical" then
                local generation=nativeMenuGeneration
                QueueOnUI(function()
                    NativeHistoricalApplyTemplate()
                    QueueOnUI(function()
                        ActivateNativeHistoricalTab(requestedLevel,generation)
                        if HasEmptyHistoricalPanel() then
                            QueueOnUI(function()
                                BindEmptyHistoricalContent(requestedLevel,generation,"late_rebind")
                            end)
                        end
                    end)
                end)
            end
        end)
        nativePilotWrapping=false
        if ok and nativePilotActive then
            SyncHistoricalConfirmEnabled("native page bound")
        end
        if not ok then
            nativePilotReport="Native page failed: "..tostring(err)
            Log("NATIVE_HISTORICAL_PAGE_ERROR level="..currentLevel.." "..tostring(err))
            -- Fail closed on initial binding errors: leave the game-owned
            -- CharacterRespec ViewModel untouched, hide the retired overlay,
            -- and return to the three-mode respec chooser for a safe retry.
            -- Never expose Review/Restore, developer arrows or Apply fallback.
            if not nativePilotActive and not wasActive then
                previewOpen=false
                queuedRefresh=false
                nativeRefreshQueued=false
                nativeSpellArmed=nil
                HB_MULTIFACETED_UI.Clear()
                local resume=onReturn
                onReturn=nil
                onStagePassive=nil
                onStageResource=nil
                onStageOther=nil
                onNativeConfirm=nil
                if resume then
                    local returned,returnError=pcall(resume,nil)
                    if not returned then
                        Log("NATIVE_HISTORICAL_SAFE_RETURN_ERROR "..tostring(returnError))
                    end
                end
                Log("NATIVE_HISTORICAL_SAFE_RETURN cause=initial_page_error")
            end
        end
        UpdateVM()
        if nativeHideRequested then
            nativeRefreshQueued=false
            RetryPendingNativeHide()
        elseif nativeRefreshQueued and previewOpen and nativePilotActive then
            nativeRefreshQueued=false
            NativePilotStart(true)
        end
    end)
end


NativePilotStop = function(showPreview,afterRestore)
    if nativePilotWrapping or not nativePilotActive then return end
    -- BG3's original respec screen and our historical proxy share the same
    -- gameplaySubPanel instance. Historical XAML writes a *local* DataTemplate
    -- on that control. Restoring the original native DataContext does NOT
    -- remove that local template (confirmed in live diagnostics). The Lua
    -- Noesis bridge also rejects assigning nil to a DataTemplate property.
    -- Therefore release the template while the historical proxy still owns
    -- the widget, using XAML's x:Null, then verify the live readback BEFORE
    -- passing the widget back to the game-owned C++ ViewModel.
    nativeRefreshQueued=false
    queuedRefresh=false
    nativePilotWrapping=true
    local requestedGeneration=nativeMenuGeneration
    local restoring=false
    local function finishStop(success,reason)
        if success then
            nativePilotActive=false
            nativeHistoricalItems={}
            nativePilotReport=(showPreview and previewOpen)
                and ("Test stopped; native ViewModel restored ("..nativePilotClicks.." clicks observed).")
                or "Native test inactive."
        else
            -- Never return a vanilla-looking widget with a historical
            -- ContentTemplate attached. The historical wrapper remains the
            -- owner and the native respec has NOT been confirmed/restored.
            nativePilotActive=true
            nativePilotReport="Vanilla panel restoration could not be verified. Do not confirm; cancel and reopen respec."
            Log("NATIVE_PILOT_RESTORE_ERROR "..tostring(reason or "historical template not released"))
            local attached=NativeVM()
            if Read(attached,"HB_NativeReleaseHistoricalPanel")==true then
                pcall(function() attached.HB_NativeReleaseHistoricalPanel=false end)
            end
        end
        queuedRefresh=false
        nativePilotWrapping=false
        UpdateVM()
        if afterRestore then
            local worked,e=pcall(afterRestore,success)
            if not worked then Log("NATIVE_RESTORE_COMPLETION_ERROR "..tostring(e)) end
        end
        if success then RetryPendingNativeHide() end
    end
    local function restoreOriginal()
        if restoring then return end
        restoring=true
        local restored=false
        local ok,err=pcall(function()
            if requestedGeneration~=nativeMenuGeneration then
                error("historical UI generation changed during native restore")
            end
            local current,screen,node=NativeVM()
            if not node or (screen~="CharacterRespec" and screen~="CharacterRespec_c") then
                error("Native respec widget is no longer mounted")
            end
            local holder=CurrentVM()
            if not holder then error("Historical overlay is not mounted") end
            local original=Read(holder,"HB_NativeOriginalContext")
            if Read(original,"Type")~="gui::DCCharacterCreation" then
                error("The game-owned native ViewModel was not retained")
            end
            local panel=NativeHistoricalFindVisual()
            if nativePilotMode=="historical" and not panel then
                error("Native content panel missing before vanilla restoration")
            end
            if nativePilotMode=="historical" and Read(panel,"ContentTemplate")~=nil then
                error("Historical DataTemplate remains attached; refusing unsafe native restoration")
            end
            -- If the *original* game-owned panel had a nonempty explicit
            -- template, put that back. Normally it was nil. For nil, XAML
            -- already cleared the old historical local value above.
            local saved=Read(holder,"HB_NativeOriginalTemplate")
            if saved and Read(holder,"HB_NativeTemplateWasEmpty")~=true then
                panel.ContentTemplate=saved
            end
            node.DataContext=original
            local attached=Read(node,"DataContext")
            if Read(attached,"Type")~="gui::DCCharacterCreation" then
                error("Native DataContext readback did not return the original C++ ViewModel")
            end
            local ready=Read(original,"IsCharacterComplete")
            if type(ready)=="boolean" then
                local found,button=pcall(function() return node:Find("ventureForth") end)
                if found and button then pcall(function() button.IsEnabled=ready end) end
            end
            nativeHistoricalTemplateWasActive=false
            Log("NATIVE_VANILLA_PANEL_HANDOFF_OK screen="..tostring(screen)
                .." template="..tostring(Read(Read(panel,"ContentTemplate"),"Type"))
                .." originalTemplateEmpty="..tostring(Read(holder,"HB_NativeTemplateWasEmpty")))
            restored=true
        end)
        finishStop(restored,restored and nil or err)
    end
    local function verifyHistoricalRelease(remaining)
        QueueOnUI(function()
            if requestedGeneration~=nativeMenuGeneration or not nativePilotActive
                or not nativePilotWrapping then
                finishStop(false,"stale or interrupted historical release")
                return
            end
            local panel=NativeHistoricalFindVisual()
            local template=Read(panel,"ContentTemplate")
            local data=Read(panel,"DataContext")
            if panel and template==nil and Read(data,"HB_HistoricalRenderKind")==nil then
                Log("NATIVE_VANILLA_PANEL_RELEASE_VERIFIED remaining="..remaining
                    .." dataType="..tostring(Read(data,"Type")))
                restoreOriginal()
            elseif remaining>0 then
                verifyHistoricalRelease(remaining-1)
            else
                Log("NATIVE_VANILLA_PANEL_RELEASE_FAILED template="
                    ..tostring(Read(template,"Type"))
                    .." historicalKind="..tostring(Read(data,"HB_HistoricalRenderKind")))
                finishStop(false,"XAML did not clear the historical content panel")
            end
        end)
    end
    QueueOnUI(function()
        if requestedGeneration~=nativeMenuGeneration or not nativePilotActive
            or not nativePilotWrapping then
            finishStop(false,"historical restoration interrupted")
            return
        end
        local live,_,node=NativeVM()
        if not node then
            finishStop(false,"native respec widget disappeared")
            return
        end
        local panel=NativeHistoricalFindVisual()
        local template=Read(panel,"ContentTemplate")
        local kind=Read(Read(panel,"DataContext"),"HB_HistoricalRenderKind")
        if nativePilotMode=="historical" and panel
            and (template~=nil or kind~=nil) then
            if Read(live,"HB_NativeHistoricalOnlyPassives")~=true then
                finishStop(false,"historical wrapper missing its native release property")
                return
            end
            local triggered,reason=pcall(function()
                live.HB_NativeReleaseHistoricalPanel=true
            end)
            Log("NATIVE_VANILLA_PANEL_RELEASE_REQUEST ok="..tostring(triggered)
                .." flag="..tostring(Read(live,"HB_NativeReleaseHistoricalPanel"))
                .." template="..tostring(Read(template,"Type"))
                .." kind="..tostring(kind)
                .." error="..tostring(reason))
            if not triggered or Read(live,"HB_NativeReleaseHistoricalPanel")~=true then
                finishStop(false,"historical XAML release notification unavailable")
                return
            end
            verifyHistoricalRelease(5)
        elseif nativePilotMode=="historical" and not panel then
            finishStop(false,"historical center panel not found")
        else
            -- Initial L1 entry and paths that never installed a historical
            -- template still return immediately, as before.
            restoreOriginal()
        end
    end)
end

local function CollectionSummary(col)
    local count = CollectionCount(col)
    if count == nil then return col and "exists; count unknown" or "nil" end
    return tostring(count) .. " item(s)"
end
local function LogItem(label, item, depth)
    if not item then Log("  " .. label .. " = [unreadable]"); return end
    local props = GetProperties(item)
    Log("  " .. label .. " = " .. ValueLabel(item) .. "; type=" .. tostring(Read(item, "Type") or type(item)))
    if #props > 0 then
        local reduced={}
        for _,p in ipairs(props) do
            if #reduced >= 38 then break end
            reduced[#reduced+1]=p
        end
        Log("   properties (first 38): " .. table.concat(reduced, ", "))
    end
    local fields={}
    for _,k in ipairs(ITEM_FIELDS) do
        local value=Read(item, k)
        if value ~= nil then
            local count=CollectionCount(value)
            if (k=="Passives" or k=="Spells" or k=="SubPassiveSelectors"
                or k=="ClassPassiveSelectors" or k=="SpellSelectors") then
                fields[#fields+1]=k .. ":" .. CollectionSummary(value)
            elseif type(value)=="string" or type(value)=="number" or type(value)=="boolean" then
                fields[#fields+1]=k .. "=" .. tostring(value):sub(1,60)
            end
        end
    end
    Log("   observed fields: " .. (#fields>0 and table.concat(fields, "; ") or "none of the expected names"))
    if depth == 0 then
        for _, sub in ipairs({"Passives", "Spells", "SubPassiveSelectors", "ClassPassiveSelectors", "SpellSelectors"}) do
            local list=Read(item, sub)
            local n=CollectionCount(list)
            if n and n>0 then
                for i=0,math.min(n,2)-1 do
                    LogItem(label .. "." .. sub .. "[" .. i .. "]", GetCollectionItem(list,i), 1)
                end
            end
        end
    end
end
local function InspectVisualSelectors()
    if not Ext.UI or not Ext.UI.GetRoot then return end
    local ok, root=pcall(Ext.UI.GetRoot)
    if not ok or not root then return end
    local container=Read(root, "ContentRoot")
    if not container then
        local found, value=pcall(function() return root:Find("ContentRoot") end)
        if found then container=value end
    end
    if not container then return end
    local nodes={{node=container,depth=0}}; local n=1; local matches=0
    while n<=#nodes and n<3200 and matches<20 do
        local entry=nodes[n]; n=n+1
        local name=tostring(Read(entry.node,"Name") or "")
        local lower=name:lower()
        if name ~= WIDGET and
            (lower:find("feat",1,true) or lower:find("passive",1,true)
             or lower:find("spellselector",1,true) or lower:find("skills",1,true)) then
            local typeName=tostring(Read(entry.node,"Type") or "")
            if typeName:find("ItemsControl",1,true) or typeName:find("ListBox",1,true)
                or name=="CharacterPassives" or name=="featsList" then
                matches=matches+1
                Log("VISUAL: " .. name .. " (" .. typeName .. ") depth=" .. tostring(entry.depth)
                    .. " ItemsSource=" .. CollectionSummary(Read(entry.node,"ItemsSource"))
                    .. " SelectedItem=" .. ValueLabel(Read(entry.node,"SelectedItem")))
            end
        end
        if entry.depth < 22 then
            local num=math.min(tonumber(Read(entry.node,"VisualChildrenCount")) or 0,140)
            for i=1,num do
                local okChild,child=pcall(function() return entry.node:VisualChild(i) end)
                if okChild and child then nodes[#nodes+1]={node=child,depth=entry.depth+1} end
            end
        end
    end
    Log("Visual selector scan: " .. matches .. " candidates / " .. tostring(math.min(n-1,3200)) .. " nodes")
end
CaptureNative = function(source, detailed)
    local vm, screen=NativeVM()
    if not vm then
        nativeReadout = "Native respec/level-up ViewModel was not found."
        if detailed then Log("PROBE " .. tostring(source) .. ": native VM unavailable") end
        UpdateVM()
        return
    end
    local fields={}
    for _,name in ipairs({"ClassPassives","ClassAndSubClassPassives","SelectableFeats","ClassSkills","ProgressionSpells","ProgressionCantrips"}) do
        fields[#fields+1] = name .. "=" .. CollectionSummary(Read(vm,name))
    end
    local stage = ValueLabel(Read(vm,"CharacterCreationStep"))
    local cls = ValueLabel(Read(vm,"SelectedClass"))
    local feat = ValueLabel(Read(vm,"SelectedFeat"))
    nativeReadout = "Native " .. tostring(screen) .. ": step " .. stage
        .. "; class " .. cls .. "; feat " .. feat .. "\n"
        .. "Passives " .. CollectionSummary(Read(vm,"ClassPassives"))
        .. " | Feats " .. CollectionSummary(Read(vm,"SelectableFeats"))
        .. " | Spells " .. CollectionSummary(Read(vm,"ProgressionSpells"))
        .. " | Skills " .. CollectionSummary(Read(vm,"ClassSkills"))
    local active=CurrentVM()
    if active then active.HB_NativeReadout=nativeReadout end
    if not detailed then
        Log(("Slider historical level=%d; native step=%s; class=%s; feat=%s")
            :format(currentLevel, stage, cls, feat))
        return
    end
    probeCount=probeCount+1
    batchLogs=true
    local inspectOK, inspectError=pcall(function()
    Log("=== NATIVE INSPECTION #" .. probeCount .. " (" .. tostring(source)
        .. "; historical level " .. currentLevel .. " / " .. maximum .. ") ===")
    Log("Native page=" .. tostring(screen) .. "; VM Type=" .. tostring(Read(vm,"Type")))
    Log("Native step=" .. stage .. "; creation mode="
        .. ValueLabel(Read(Read(Read(vm,"CurrentPlayer"),"UIData"),"CharacterCreationMode")))
    Log("Native SelectedClass=" .. cls .. "; SelectedSubClass=" .. ValueLabel(Read(vm,"SelectedSubClass"))
        .. "; SelectedFeat=" .. feat)
    Log("Compare saved level: " .. DescribeLevel(currentLevel):gsub("\n", " | "))
    for _, name in ipairs(NATIVE_COLLECTIONS) do
        local value=Read(vm,name)
        local n=CollectionCount(value)
        Log("GROUP " .. name .. ": " .. CollectionSummary(value) .. "; model=" .. ValueLabel(value))
        if n and n>0 then
            for i=0,math.min(n,3)-1 do
                LogItem(name .. "[" .. tostring(i) .. "]", GetCollectionItem(value,i),0)
            end
        elseif value and n == nil then
            LogItem(name, value,0)
        end
    end
    for _, key in ipairs({"SelectedFeatDetails", "ProgressionData", "SelectedClass", "SelectedSubClass"}) do
        local value=Read(vm,key)
        Log("OBJECT " .. key .. "=" .. ValueLabel(value))
        if value then LogItem(key,value,0) end
    end
    InspectVisualSelectors()
    Log("=== END NATIVE INSPECTION #" .. probeCount .. " ===")
    end)
    batchLogs=false
    if not inspectOK then Log("NATIVE INSPECTION FAILED: " .. tostring(inspectError))
    else FlushLog() end
end

local function ScanNative()
    if not Ext.UI or not Ext.UI.GetRoot then return end
    local ok, root = pcall(Ext.UI.GetRoot)
    if not ok or not root then return end
    local ok2, content = pcall(function() return root:Find("ContentRoot") end)
    if not ok2 or not content then return end
    local nodes = {{node=content,depth=0}}
    local pageSeen = {}
    local captures = {}
    local index = 1
    while index <= #nodes and index <= 2200 do
        local pair = nodes[index]; index=index+1
        local node, depth = pair.node, pair.depth
        local name = tostring(Read(node,"Name") or "")
        local path = tostring(Read(node,"XamlSource") or Read(node,"Source") or "")
        local display = name:lower()
        local nativeType
        if name == "CharacterRespec" or name == "CharacterRespec_c"
            or name == "CharacterLevelUp" or name == "CharacterLevelUp_c" then
            nativeType = name
        end
        if nativeType and not pageSeen[nativeType] then
            pageSeen[nativeType] = true
            local vm = Read(node,"DataContext")
            local details = GetProperties(vm)
            local heading = "NATIVE " .. nativeType .. " / " .. path .. " / DC=" .. tostring(Read(vm,"Type"))
            captures[#captures+1] = heading
            captures[#captures+1] = " Native VM fields: " .. table.concat(details, ", ")
        end
        if (display:find("selector",1,true) or display:find("levelup",1,true)
            or display:find("feat",1,true) or display:find("passive",1,true)
            or display:find("spell",1,true) or display:find("skill",1,true)
            or display:find("subclass",1,true)) and #captures < 75
            and name ~= WIDGET then
            local dc=Read(node,"DataContext")
            captures[#captures+1] = (" UI %s [%s] DC=%s"):format(name,tostring(Read(node,"Type")),tostring(Read(dc,"Type")))
            if dc and #captures < 65 then
                local props=GetProperties(dc)
                if #props > 0 then captures[#captures+1] = "  VM fields: " .. table.concat(props, ", ") end
            end
        end
        if depth < 12 then
            local childCount = math.min(tonumber(Read(node,"VisualChildrenCount")) or 0,160)
            for i=1,childCount do
                local valid,child=pcall(function() return node:VisualChild(i) end)
                if valid and child then nodes[#nodes+1]={node=child,depth=depth+1} end
            end
        end
    end
    for native in pairs(pageSeen) do
        if not reported[native] then
            reported[native] = true
            Log("Native screen discovered: " .. native)
            for _,line in ipairs(captures) do Log(line) end
            Log("Visited UI nodes: " .. tostring(math.min(index-1,2200)))
        end
    end
end
_G.HB_NativeLevelBridge = {
    ShowPreview = function(levels,maxLevel,level,resume,stagePassive,stagedRows,
        stageResource,stageOther,stagedResources,stagedOtherRows,confirmLevelRespec,prepareNativeLevelOne)
        snapshot=levels or {}
        nativeFeatPreview=false
        nativeSpellPreview=false
        nativeSpellAllowStage=false
        nativePilotMode="historical"
        nativeHideRequested=false
        nativeCancelAwaitingDecision=false
        nativeCancelSawDialog=false
        nativeCancelDialogGonePolls=0
        nativeCancelMissingPolls=0
        nativeCancelRecoveryPending=false
        nativeCancelRecoveryChecks=0
        historicalSpellFilters={}
        ClearPreviewStaged()
        for _,edit in ipairs(stagedRows or {}) do
            local index=tonumber(edit.Level)
            local levelRow=index and snapshot[index]
            if levelRow and edit.SelectorId and edit.PassiveList and edit.From and edit.To then
                levelRow._HB_PreviewStaged=levelRow._HB_PreviewStaged or {}
                local key=tostring(edit.SelectorId).."|"..tostring(edit.PassiveList).."|"..tostring(edit.From)
                levelRow._HB_PreviewStaged[key]=tostring(edit.To)
            end
        end
        previewGenericChoices={}
        for _,edit in ipairs(stagedOtherRows or {}) do
            if edit.Kind=="Feat" and edit.GenericFeatChoices then
                local at=tonumber(edit.Level)
                if at then
                    previewGenericChoices[at]={}
                    for index,group in ipairs(edit.GenericFeatChoices) do
                        local nextGroup={}
                        for _,id in ipairs(group or {}) do nextGroup[#nextGroup+1]=tostring(id) end
                        previewGenericChoices[at][index]=nextGroup
                    end
                end
            end
        end
        previewPairChoices={}
        previewPairFeatIds={}
        for _,edit in ipairs(stagedOtherRows or {}) do
            local featId=tostring(edit.To or "")
            if edit.Kind=="Feat" and HB_PASSIVE_PAIR_FEATS[featId] then
                local picked={}
                for _,id in ipairs(edit.PassiveFeatChoices or {}) do picked[#picked+1]=tostring(id) end
                local level=tonumber(edit.Level)
                if level then previewPairChoices[level]=picked;previewPairFeatIds[level]=featId end
            end
        end
        HB_MULTIFACETED_NEW.Accord.Preview={}
        HB_MULTIFACETED_NEW.Accord.Unchecked={}
        HB_CLASS_SPELL_UI.Unchecked={}
        for _,edit in ipairs(stagedOtherRows or {}) do
            if edit.Kind=="Feat" and tostring(edit.To or "")
                ==HB_MULTIFACETED_NEW.Accord.Feat then
                local ids={}
                for _,id in ipairs(edit.AccordChoices or {}) do ids[#ids+1]=tostring(id) end
                HB_MULTIFACETED_NEW.Accord.Preview[tonumber(edit.Level)]=ids
            end
        end
        HB_MULTIFACETED_NEW.Preview={}
        for _,edit in ipairs(stagedOtherRows or {}) do
            if edit.Kind=="Feat" and tostring(edit.To or "")==HB_MULTIFACETED_NEW.Feat then
                local sets={}
                for _,section in ipairs({"Archetype","Trait","Skills"}) do
                    local selections={}
                    for _,id in ipairs((edit.MultifacetedChoices or {})[section] or {}) do
                        selections[#selections+1]=tostring(id)
                    end
                    sets[section]=selections
                end
                HB_MULTIFACETED_NEW.Preview[tonumber(edit.Level)]=sets
            end
        end
        previewNewElements={}
        for _,edit in ipairs(stagedOtherRows or {}) do
            if edit.Kind=="Feat" and tostring(edit.To or "")==HB_ELEMENTAL_ADEPT_FEAT then
                local added={}
                for _,id in ipairs(edit.ElementChoices or {}) do added[#added+1]=tostring(id) end
                previewNewElements[tonumber(edit.Level)]=added
            end
        end
        onStagePassive=stagePassive
        onStageResource=stageResource
        onStageOther=stageOther
        onNativeConfirm=confirmLevelRespec
        HB_NATIVE_L1_SLIDER.Screen=false
        HB_NATIVE_L1_SLIDER.FullRespecChanged=false
        HB_NATIVE_L1_SLIDER.OriginalNativeChoice=nil
        HB_NATIVE_L1_SLIDER.LiveSpellSwap=nil
        HB_NATIVE_L1_SLIDER.FirstLevelSpellHandleIDs=nil
        HB_NATIVE_L1_SLIDER.LevelOneVisualScanSequence=nil
        HB_NATIVE_L1_SLIDER.LastVisualSelectedSpellIds=nil
        HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts={}
        HB_NATIVE_L1_SLIDER.OriginalNavigation=nil
        HB_NATIVE_L1_SLIDER.LiveSpellHandleSeen=nil
        HB_NATIVE_L1_SLIDER.LastPassiveNativeSignature=nil
        HB_NATIVE_L1_SLIDER.LastNativePassivePanel=nil
        HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups={}
        HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup={}
        HB_NATIVE_L1_SLIDER.PassiveActiveGroups={}
        HB_NATIVE_L1_SLIDER.LastLevelOnePending=nil
        HB_NATIVE_L1_SLIDER.LastLevelOnePendingConflict=nil
        HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard=false
        HB_NATIVE_L1_SLIDER.Touched=false
        HB_NATIVE_L1_SLIDER.Pending=false
        HB_NATIVE_L1_SLIDER.AutoConfirm=false
        HB_NATIVE_L1_SLIDER.Prepared=false
        HB_NATIVE_L1_SLIDER.OnPrepare=prepareNativeLevelOne
        HB_L1_NATIVE_BRIDGE.Captured=false
        nativeCommitPending=false
        nativeCommitError=""
        for level,edit in pairs(stagedResources or {}) do
            if type(edit)=="table" then previewResources[tonumber(level) or level]=edit.To end
        end
        for _,edit in ipairs(stagedOtherRows or {}) do
            local idx=tonumber(edit.Level)
            if idx then
                previewOther[idx]=previewOther[idx] or {}
                previewOther[idx][ChoiceKey(edit)]=edit.To
            end
        end
        passiveGroupIndex=1;armedFrom=nil;nativeSpellArmed=nil;passiveFeedback=""
        HB_MULTIFACETED_UI.Clear()
        queuedRefresh=true
        maximum=math.max(1,tonumber(maxLevel) or 1)
        HB_NATIVE_L1_SLIDER.BuildPassiveCandidateIndex()
        currentLevel=math.max(1,math.min(maximum, tonumber(level) or 1))
        if not Bind() then
            Log("Cannot open native preview: widget not mounted")
            return false
        end
        onReturn=resume
        previewOpen=true
        UpdateVM()
        Log("Preview activated at level " .. tostring(currentLevel))
        local available,recorded,observed=ChoiceLevels()
        Log("NATIVE_HISTORY_INDEX available="..FormatLevelRanges(available)
            .." recorded="..FormatLevelRanges(recorded)
            .." observations="..FormatLevelRanges(observed))
        ScanNative()
        CaptureNative("open", false)
        -- The historical UI is now the primary Edit Build experience: move
        -- straight into the native renderer after the host has mounted. A
        -- failed connection leaves the old preview available for retry.
        QueueOnUI(function()
            if not previewOpen or nativePilotActive or nativePilotWrapping then return end
            if currentLevel==1 then
                -- Cover the original C++ Confirm while the server prepares a
                -- backup. The historical wrapper is temporary and disabled.
                NativeHistoricalStart()
                HB_NATIVE_L1_SLIDER.Pending=true
                if HB_NATIVE_L1_SLIDER.OnPrepare then
                    local ok,result,why=pcall(HB_NATIVE_L1_SLIDER.OnPrepare)
                    if not ok or result~=true then
                        HB_NATIVE_L1_SLIDER.Pending=false
                        nativeCommitError=tostring(why or result)
                        Log("NATIVE_SLIDER_L1_INITIAL_PREPARE_FAILED "..nativeCommitError)
                        UpdateVM()
                    end
                else
                    HB_NATIVE_L1_SLIDER.Pending=false
                    nativeCommitError="Native level-one preparation handler is absent."
                    UpdateVM()
                end
            else
                NativeHistoricalStart()
            end
        end)
        return true
    end,
    NativeFirstLevelReady = function()
        if not previewOpen or not HB_NATIVE_L1_SLIDER.Pending then return end
        HB_NATIVE_L1_SLIDER.Pending=false
        HB_NATIVE_L1_SLIDER.Prepared=true
        nativeCommitError=""
        if currentLevel~=1 and not HB_NATIVE_L1_SLIDER.AutoConfirm then
            -- The user moved back to historical choices while RPC was in
            -- flight. Never show a stale native screen or commit old edits.
            Log("NATIVE_SLIDER_L1_ACK_IGNORED level="..currentLevel)
            SyncHistoricalConfirmEnabled("native level-one preparation completed off-level")
            UpdateVM();return
        end
        local commit=HB_NATIVE_L1_SLIDER.AutoConfirm
        HB_NATIVE_L1_SLIDER.AutoConfirm=false
        local function EnterOriginal(restored)
            if not restored or not previewOpen then
                nativeCommitError="Cannot restore native level-one screen safely."
                Log("NATIVE_SLIDER_L1_ORIGINAL_RESTORE_FAILED")
                UpdateVM();return
            end
            HB_NATIVE_L1_SLIDER.Screen=true
            HB_NATIVE_L1_SLIDER.FullRespecChanged=false
            HB_NATIVE_L1_SLIDER.Touched=true
            if not commit then
                -- The original native VM is back, but its presenter can still
                -- hold the historical DataContext/ContentTemplate. Allow the
                -- XAML-native null-template reset to run before reselecting
                -- the originally active native class, subclass or spell tab.
                local generation=nativeMenuGeneration
                QueueOnUI(function()
                    QueueOnUI(function()
                        HB_NATIVE_L1_SLIDER.RebindNativeTabs(generation)
                    end)
                end)
            end
            -- First sample now; subsequent native class/subclass clicks are
            -- observed by the bounded L1-only watcher below.
            HB_NATIVE_L1_SLIDER.RefreshChanged()
            if not commit then
                HB_NATIVE_L1_SLIDER.LastLevelOnePending=nil
                HB_NATIVE_L1_SLIDER.LastLevelOnePendingConflict=nil
                HB_NATIVE_L1_SLIDER.LastNativeConfirmGuard=nil
                HB_NATIVE_L1_SLIDER.ProbeNativeSpellPicks("native-level-one-opened")
            end
            nativeCancelRecoveryPending=false
            nativeCancelRecoveryChecks=0
            if commit then currentLevel=1 end
            Log("NATIVE_SLIDER_L1_NATIVE_VISIBLE level="..currentLevel
                .." commit="..tostring(commit))
            if commit then
                local live,screen=NativeVM()
                local command=Read(live,"FinishCreating")
                if (screen~="CharacterRespec" and screen~="CharacterRespec_c")
                    or Read(live,"Type")~="gui::DCCharacterCreation" or not command then
                    nativeCommitError="Original native Confirm is unavailable."
                    UpdateVM();return
                end
                local can,allowed=pcall(function() return command:CanExecute(nil) end)
                if not can or allowed~=true then
                    nativeCommitError="Complete the native level-one selections before confirming."
                    Log("NATIVE_SLIDER_L1_NATIVE_CONFIRM_BLOCKED can="..tostring(can)
                        .." allowed="..tostring(allowed))
                    UpdateVM();return
                end
                local ok,reason=pcall(function() command:Execute(nil) end)
                Log("NATIVE_SLIDER_L1_NATIVE_CONFIRM_SENT success="..tostring(ok)
                    ..(ok and "" or " error="..tostring(reason)))
                if not ok then
                    nativeCommitError="Native Confirm failed; do not save this attempt."
                else
                    nativeCommitPending=true
                    Log("NATIVE_SLIDER_L1_COMMIT_WAIT_COMPLETION")
                end
            end
            UpdateVM()
        end
        if nativePilotActive then
            NativePilotStop(false,EnterOriginal)
        elseif nativePilotWrapping then
            QueueOnUI(function()
                if previewOpen and HB_NATIVE_L1_SLIDER.Prepared then
                    if nativePilotActive then NativePilotStop(false,EnterOriginal)
                    else
                        local live,name=NativeVM()
                        EnterOriginal((name=="CharacterRespec" or name=="CharacterRespec_c")
                            and Read(live,"Type")=="gui::DCCharacterCreation")
                    end
                end
            end)
        else
            local live,name=NativeVM()
            EnterOriginal((name=="CharacterRespec" or name=="CharacterRespec_c")
                and Read(live,"Type")=="gui::DCCharacterCreation")
        end
    end,
    NativeFirstLevelRejected = function(reason)
        if not previewOpen then return end
        HB_NATIVE_L1_SLIDER.Pending=false
        HB_NATIVE_L1_SLIDER.Prepared=false
        HB_NATIVE_L1_SLIDER.AutoConfirm=false
        nativeCommitError=tostring(reason or "Cannot safely restore higher levels")
        if currentLevel>1 then SyncHistoricalConfirmEnabled("native level-one preparation refused") end
        Log("NATIVE_SLIDER_L1_PREPARE_REJECTED "..nativeCommitError)
        UpdateVM()
    end,
    CommitFailed = function(reason)
        if not previewOpen then return end
        nativeCommitPending=false
        nativeCommitError=tostring(reason or "Selective Respec validation failed")
        Log("NATIVE_LEVEL_RESPEC_SERVER_REJECTED "..nativeCommitError)
        if not nativePilotActive and not nativePilotWrapping and NativePilotStart then
            -- The prior native Confirm first restores the C++ DataContext,
            -- then sends its RPC. If the response arrives mid-transition,
            -- retry from the UI tick rather than an unsafe nested restore.
            QueueOnUI(function()
                if previewOpen and not nativePilotActive and not nativePilotWrapping then
                    local worked,reason=pcall(NativePilotStart)
                    if not worked then Log("NATIVE_REJECT_REOPEN_FAILED "..tostring(reason)) end
                end
            end)
        end
        QueueOnUI(UpdateVM)
    end,
    Hide = function()
        nativeCancelAwaitingDecision=false
        nativeCancelSawDialog=false
        if previewOpen and nativePilotActive then
            local _,name,node=NativeVM()
            if not node or (name~="CharacterRespec" and name~="CharacterRespec_c") then
                ResetDetachedHistoricalView("bridge hide after native screen unmounted")
                return
            end
        end
        nativeHideRequested=true
        queuedRefresh=false
        nativeRefreshQueued=false
        if nativePilotWrapping then
            -- NativePilotStart/Stop schedules a retry as soon as the ongoing
            -- UI transition exits. Clearing the holder now would invalidate
            -- HB_NativeOriginalContext before restoration can read it.
            Log("NATIVE_HIDE_DEFERRED reason=transition")
            return
        end
        if nativePilotActive then
            NativePilotStop(false,function(restored)
                if restored then RetryPendingNativeHide() end
            end)
            return
        end
        nativeHideRequested=false
        nativeSpellArmed=nil
        HB_CLASS_SPELL_UI.Unchecked={}
        HB_MULTIFACETED_UI.Clear()
        previewOpen=false
        HB_NATIVE_L1_SLIDER.OriginalNativeChoice=nil
        HB_NATIVE_L1_SLIDER.LiveSpellSwap=nil
        HB_NATIVE_L1_SLIDER.UnrepresentedSpellConflicts={}
        HB_NATIVE_L1_SLIDER.LevelOneVisualScanSequence=nil
        HB_NATIVE_L1_SLIDER.LastVisualSelectedSpellIds=nil
        HB_NATIVE_L1_SLIDER.LiveFirstPassiveIds={}
        HB_NATIVE_L1_SLIDER.DisplacedPassiveSlots={}
        HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups={}
        HB_NATIVE_L1_SLIDER.PassiveDuplicateLevels={}
        HB_NATIVE_L1_SLIDER.PassiveCandidateIndex={}
        HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup={}
        HB_NATIVE_L1_SLIDER.PassiveActiveGroups={}
        onReturn=nil
        onStagePassive=nil
        onStageResource=nil
        onStageOther=nil
        onNativeConfirm=nil
        HB_NATIVE_L1_SLIDER.Screen=false
        HB_NATIVE_L1_SLIDER.FullRespecChanged=false
        HB_NATIVE_L1_SLIDER.Pending=false
        HB_NATIVE_L1_SLIDER.Touched=false
        HB_NATIVE_L1_SLIDER.Prepared=false
        HB_NATIVE_L1_SLIDER.AutoConfirm=false
        HB_NATIVE_L1_SLIDER.OnPrepare=nil
        nativeCommitPending=false
        nativeCommitError=""
        local vm=CurrentVM()
        if vm then
            vm.HB_NativeLevelOneChoicesPending=false
            vm.HB_NativeHostTestActive=false
            vm.HB_NativeVisible=false
        end
    end,
}
-- BG3 can close the respec widget before a queued Noesis restoration
-- callback executes. In that case there is NO live node to restore: retrying
-- DataContext writes against a dead view leaves a stale historical session
-- that contaminates the next respec and sometimes pause-menu navigation.
-- Only reset once the native screen has been absent on consecutive polls;
-- never treat a still-mounted wrapper as safely restored.
local nativeMissingPolls=0
ResetDetachedHistoricalView = function(reason)
    HB_NATIVE_L1_SLIDER.OriginalNativeChoice=nil
    HB_NATIVE_L1_SLIDER.OriginalNavigation=nil
    HB_NATIVE_L1_SLIDER.ObservedOriginalPassiveGroups={}
    HB_NATIVE_L1_SLIDER.PassiveSelectionsByGroup={}
    HB_NATIVE_L1_SLIDER.PassiveActiveGroups={}
    Log("NATIVE_CANCEL_DETACHED_CLEANUP reason="..tostring(reason)
        .." pending="..tostring(nativeCommitPending))
    previewOpen=false
    nativePilotActive=false
    nativePilotWrapping=false
    nativeHideRequested=false
    nativeCancelAwaitingDecision=false
    nativeCancelSawDialog=false
    nativeCancelDialogGonePolls=0
    nativeCancelMissingPolls=0
    nativeCancelRecoveryPending=false
    nativeCancelRecoveryChecks=0
    nativeRefreshQueued=false
    queuedRefresh=false
    nativeSpellArmed=nil
    armedFrom=nil
    HB_CLASS_SPELL_UI.Unchecked={}
    HB_MULTIFACETED_UI.Clear()
    nativeHistoricalItems={}
    nativeCommitPending=false
    nativeCommitError=""
    nativeMissingPolls=0
    onReturn=nil
    onStagePassive=nil;onStageResource=nil;onStageOther=nil
    onNativeConfirm=nil
    HB_NATIVE_L1_SLIDER.Screen=false
    HB_NATIVE_L1_SLIDER.FullRespecChanged=false
    HB_NATIVE_L1_SLIDER.Pending=false
    HB_NATIVE_L1_SLIDER.Prepared=false
    HB_NATIVE_L1_SLIDER.Touched=false
    HB_NATIVE_L1_SLIDER.AutoConfirm=false
    HB_NATIVE_L1_SLIDER.OnPrepare=nil
    local holder=CurrentVM()
    if holder then pcall(function()
        holder.HB_NativeLevelOneChoicesPending=false
        holder.HB_NativeHostTestActive=false
        holder.HB_NativeVisible=false
    end) end
end

-- The on-screen slider survives certain BG3 modal transitions even when
-- its Noesis command and TwoWay-bound ViewModel are detached. Read its LIVE
-- visual value, never a cached Lua proxy, as a last-resort user gesture.
local function HistoricalSliderVisualValue()
    local holder=UIWidget()
    if not holder then return nil end
    local ok,node=pcall(function() return holder:Find("HB_LiveHistoricalSlider") end)
    if not ok or not node then return nil end
    return tonumber(Read(node,"Value"))
end

-- BG3 mounts the discard warning as a separate UIWidget defined in
-- Widgets/MessageBox.xaml (x:Name="Dialog_box"). Root:Find() does not always
-- traverse the live ContentRoot widget tree, so a missing Find result is NOT
-- evidence that the warning is absent. Inspect mounted widgets as well.
local function HistoricalCancelModalVisible()
    if not Ext.UI or not Ext.UI.GetRoot then return false end
    local ok,root=pcall(Ext.UI.GetRoot)
    if not ok or not root then return false end
    local seen={}
    local function Present(control,mountedInContentRoot)
        if not control then return false end
        local visible=Read(control,"IsVisible")
        if visible==nil then
            local readOK,value=pcall(function() return control.IsVisible end)
            if readOK then visible=value end
        end
        if visible==false then return false end
        local visibility=Read(control,"Visibility")
        if visibility=="Collapsed" or visibility=="Hidden" or visibility==2 then
            return false
        end
        if visible==true or visibility=="Visible" or visibility==0 then
            return true
        end
        -- A permanently allocated root lookup isn't necessarily visible.
        -- Unknown visibility is acceptable ONLY for a freshly mounted
        -- ContentRoot child; disappearance of that child then means closed.
        return mountedInContentRoot==true
    end
    for _,name in ipairs({"Dialog_box","MessageBox_c"}) do
        local found,control=pcall(function() return root:Find(name) end)
        if found and control then
            seen[control]=true
            if Present(control,false) then return true end
        end
        if Ext.UI.GetByName then
            found,control=pcall(Ext.UI.GetByName,name)
            if found and control and not seen[control] then
                seen[control]=true
                if Present(control,false) then return true end
            end
        end
    end
    local found,content=pcall(function() return root:Find("ContentRoot") end)
    if found and content then
        local count=tonumber(Read(content,"ChildrenCount"))
        if count==nil then
            local countOK,raw=pcall(function() return content.ChildrenCount end)
            if countOK then count=tonumber(raw) end
        end
        count=count or 0
        local report={}
        for i=1,math.min(count,100) do
            local childOK,child=pcall(function() return content:Child(i) end)
            if childOK and child then
                local name=tostring(Read(child,"Name") or "")
                local file=tostring(Read(child,"FileName") or "")
                if file=="" then
                    local fileOK,fileValue=pcall(function() return child.FileName end)
                    if fileOK and fileValue then file=tostring(fileValue) end
                end
                local src=file:gsub("\\","/"):lower()
                if name=="Dialog_box" or name=="MessageBox_c"
                    or src:find("/messagebox.xaml",1,true)
                    or src:find("/messagebox_c.xaml",1,true) then
                    if Present(child,true) then
                        if cancelModalDiscoverySignature~="mounted:"..name..":"..file then
                            cancelModalDiscoverySignature="mounted:"..name..":"..file
                            Log("NATIVE_CANCEL_DIALOG_FOUND name="..name.." file="..file)
                        end
                        return true
                    end
                end
                if #report<16 and (name~="" or file~="") then
                    report[#report+1]=name.." ["..file.."]"
                end
            end
        end
        if nativeCancelAwaitingDecision and cancelModalDiscoverySignature==nil then
            cancelModalDiscoverySignature="candidate-report"
            Log("NATIVE_CANCEL_DIALOG_WIDGETS count="..tostring(count)
                .." candidates="..table.concat(report,"; "))
        end
    end
    return false
end

-- Observe the unmodified native choice viewmodels. Do not call Execute() or
-- assign anything to native DataContexts: the observation must be harmless.
local tick = 0
if Ext.Events and Ext.Events.Tick and Ext.Events.Tick.Subscribe then
    Ext.Events.Tick:Subscribe(function()
        tick=tick+1
        -- Fallback for Noesis slider bindings invalidated by Cancel -> No:
        -- read its TwoWay-bound value even when the old ValueChanged command
        -- does not execute. The existing level switch and fail-closed native
        -- rewrap are shared by event and watcher, never applied twice.
        if tick % 8 == 0 and previewOpen and not nativePilotWrapping
            and not nativeCancelAwaitingDecision and not nativeCommitPending
            and ApplyHistoricalSliderFromModel then
            local holder=CurrentVM()
            local value=tonumber(Read(holder,"HB_NativeSelectedLevel"))
            local visual=HistoricalSliderVisualValue()
            if value and math.floor(value+0.5)~=currentLevel then
                ApplyHistoricalSliderFromModel("bound value watcher")
            elseif visual and math.floor(visual+0.5)~=currentLevel then
                -- The detached historical ViewModel may have stopped
                -- receiving TwoWay changes, although its slider still moves.
                local target=math.max(1,math.min(maximum,math.floor(visual+0.5)))
                Log("NATIVE_SLIDER_VISUAL_FALLBACK model="..tostring(value)
                    .." visual="..tostring(target).." current="..currentLevel)
                if holder then
                    holder.HB_NativeSelectedLevel=target
                    ApplyHistoricalSliderFromModel("visual value watcher")
                end
            end
        end
        if tick % 12 == 0 and previewOpen and HB_NATIVE_L1_SLIDER.Screen
            and not nativePilotWrapping and not nativeCommitPending then
            HB_NATIVE_L1_SLIDER.RefreshChanged()
            HB_NATIVE_L1_SLIDER.ObserveLiveSpellPending()
        end
        -- BG3's Dialog_box can be mounted outside the root search scope.
        -- If the warning has been declined, its command may never propagate
        -- into the old overlay VM. A REAL slider drag while no dialog is
        -- visible is independent proof that modal input is no longer active.
        -- Never rewrap simply because a timer expires: Yes might be pending.
        if tick % 4 == 0 and previewOpen and nativeCancelAwaitingDecision
            and not nativePilotWrapping and not nativePilotActive then
            local physicalValue=HistoricalSliderVisualValue()
            local native,screen=NativeVM()
            if physicalValue and math.floor(physicalValue+0.5)~=currentLevel
                and not HistoricalCancelModalVisible()
                and (screen=="CharacterRespec" or screen=="CharacterRespec_c")
                and Read(native,"Type")=="gui::DCCharacterCreation" then
                local target=math.max(1,math.min(maximum,math.floor(physicalValue+0.5)))
                Log("NATIVE_CANCEL_NO_GESTURE_RECOVERY from="..currentLevel
                    .." to="..target.." host="..tostring(screen))
                currentLevel=target
                passiveGroupIndex=1; armedFrom=nil; nativeSpellArmed=nil
                HB_MULTIFACETED_UI.Clear()
                nativeCancelAwaitingDecision=false
                nativeCancelSawDialog=false
                nativeCancelRecoveryPending=true
                nativeCancelRecoveryChecks=0
                -- Rebuild the overlay VM and reattach the historical screen.
                -- BG3 owns the Yes/No action and the original C++ VM remains
                -- untouched until this visible user gesture is observed.
                queuedRefresh=true
                QueueOnUI(function()
                    if previewOpen and not nativePilotActive
                        and not nativePilotWrapping and not nativeCancelAwaitingDecision then
                        local ok,err=pcall(Bind)
                        Log("NATIVE_CANCEL_NO_GESTURE_REBIND ok="..tostring(ok)
                            .." detail="..tostring(err))
                        UpdateVM()
                        NativeHistoricalStart()
                    end
                end)
            end
        end
        if tick % 120 == 0 and nativeCancelAwaitingDecision and previewOpen then
            local live,screen=NativeVM()
            Log("NATIVE_CANCEL_WAIT_PROBE modal="..tostring(HistoricalCancelModalVisible())
                .." sawDialog="..tostring(nativeCancelSawDialog)
                .." screen="..tostring(screen)
                .." nativeType="..tostring(Read(live,"Type"))
                .." sliderVisual="..tostring(HistoricalSliderVisualValue())
                .." sliderModel="..tostring(Read(CurrentVM(),"HB_NativeSelectedLevel")))
        end
        if tick % 6 == 0 and previewOpen and nativeCancelAwaitingDecision
            and not nativePilotWrapping and not nativePilotActive then
            local live,screen,node=NativeVM()
            if not node or (screen~="CharacterRespec" and screen~="CharacterRespec_c") then
                nativeCancelMissingPolls=nativeCancelMissingPolls+1
                if nativeCancelMissingPolls>=2 then
                    ResetDetachedHistoricalView("native discard accepted, respec screen closed")
                end
            else
                nativeCancelMissingPolls=0
                if HistoricalCancelModalVisible() then
                    if not nativeCancelSawDialog then Log("NATIVE_CANCEL_MODAL_SEEN") end
                    nativeCancelSawDialog=true
                    nativeCancelDialogGonePolls=0
                elseif nativeCancelSawDialog then
                    nativeCancelDialogGonePolls=nativeCancelDialogGonePolls+1
                    if nativeCancelDialogGonePolls>=2
                        and Read(live,"Type")=="gui::DCCharacterCreation" then
                        -- No was selected: the dialog vanished but native
                        -- respec remained. Reattach HB's historical wrapper.
                        nativeCancelAwaitingDecision=false
                        nativeCancelSawDialog=false
                        nativeCancelDialogGonePolls=0
                        nativeCancelRecoveryPending=true
                        nativeCancelRecoveryChecks=0
                        Log("NATIVE_CANCEL_DECLINED_RESTORE_HISTORICAL")
                        QueueOnUI(function()
                            if previewOpen and not nativePilotActive and not nativePilotWrapping then
                                -- BG3 can replace its original C++ VM and the
                                -- overlay command instance after No. Rebuild
                                -- only HB's detached control VM to refresh its
                                -- slider handlers, then reattach historical.
                                queuedRefresh=true
                                local ok,rebound=pcall(Bind)
                                Log("NATIVE_CANCEL_DECLINED_REBIND ok="..tostring(ok)
                                    .." rebound="..tostring(rebound))
                                UpdateVM()
                                NativeHistoricalStart()
                            end
                        end)
                    end
                end
            end
        end
        if tick % 12 == 0 and nativeCancelRecoveryPending and previewOpen
            and not HB_NATIVE_L1_SLIDER.Screen
            and not nativeCancelAwaitingDecision and not nativePilotWrapping then
            local live,screen,node=NativeVM()
            if node and (screen=="CharacterRespec" or screen=="CharacterRespec_c") then
                local kind=tostring(Read(live,"Type") or "")
                if kind=="gui::DCCharacterCreation" then
                    -- BG3 finished its No response AFTER our rebind, or the
                    -- first deferred rebind was too early. Do not leave an
                    -- interactive-looking slider attached to a vanilla VM.
                    nativeCancelRecoveryChecks=nativeCancelRecoveryChecks+1
                    if nativeCancelRecoveryChecks<=5 then
                        Log("NATIVE_CANCEL_REWRAP_RETRY attempt="..nativeCancelRecoveryChecks)
                        nativePilotActive=false
                        nativePilotMode="historical"
                        queuedRefresh=true
                        QueueOnUI(function()
                            if previewOpen and not nativePilotWrapping
                                and not nativeCancelAwaitingDecision then
                                local ok,err=pcall(Bind)
                                if not ok then Log("NATIVE_CANCEL_REBIND_ERROR "..tostring(err)) end
                                NativeHistoricalStart()
                            end
                        end)
                    else
                        Log("NATIVE_CANCEL_REWRAP_GAVE_UP original VM remains; leaving original menus usable")
                        nativeCancelRecoveryPending=false
                        nativePilotActive=false
                        UpdateVM()
                    end
                elseif nativePilotActive and kind~="" then
                    -- Retain the guard long enough for BG3's post-dialog
                    -- restore to settle, then stop checking this recovery.
                    nativeCancelRecoveryChecks=nativeCancelRecoveryChecks+1
                    if nativeCancelRecoveryChecks>=8 then
                        nativeCancelRecoveryPending=false
                        Log("NATIVE_CANCEL_REWRAP_STABLE type="..kind)
                    end
                end
            end
        end
        if tick % 30 == 0 and previewOpen and HB_NATIVE_L1_SLIDER.Screen
            and not nativePilotWrapping then
            local _,screen,node=NativeVM()
            if node and (screen=="CharacterRespec" or screen=="CharacterRespec_c") then
                nativeMissingPolls=0
            else
                nativeMissingPolls=nativeMissingPolls+1
                if nativeMissingPolls>=2 then
                    ResetDetachedHistoricalView("native level-one screen closed")
                end
            end
        end
        if tick % 30 == 0 and previewOpen and nativePilotActive
            and not nativePilotWrapping and not nativeCommitPending then
            local _,name,node=NativeVM()
            if node and (name=="CharacterRespec" or name=="CharacterRespec_c") then
                nativeMissingPolls=0
            else
                nativeMissingPolls=nativeMissingPolls+1
                if nativeMissingPolls>=2 then
                    ResetDetachedHistoricalView("native widget absent at 2 periodic polls")
                end
            end
        end
        if previewOpen and queuedRefresh and not nativePilotActive and not nativePilotWrapping
            and not HB_NATIVE_L1_SLIDER.Screen then
            local ok,err=pcall(Bind)
            if not ok then Log("Native passive UI refresh error: "..tostring(err));queuedRefresh=false end
            UpdateVM()
        end
        if tick % 150 == 0 and previewOpen
            and (not reported.CharacterRespec or not reported.CharacterLevelUp) then
            pcall(ScanNative)
        end
    end)
end
Log("Native bridge installed; waiting for CharacterRespec/CharacterLevelUp")
