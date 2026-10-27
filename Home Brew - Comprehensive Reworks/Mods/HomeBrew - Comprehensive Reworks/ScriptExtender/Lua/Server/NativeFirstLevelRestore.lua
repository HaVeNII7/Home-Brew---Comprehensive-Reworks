-- HomeBrew: restore saved levels 2-X on a freshly created, engine-owned
-- first level. No first-level progression entity is ever manufactured.
-- Table-only preparation is intentionally separate from the irreversible
-- engine write, so failures in provenance/eligibility cannot partially replay.
HB_NativeFirstLevelRestore = HB_NativeFirstLevelRestore or {}
local Bridge=HB_NativeFirstLevelRestore
-- The Script Extender module loader is not a stable data service during a
-- post-native-Confirm callback. Resolve the generated, read-only source feat
-- catalog while this server script is loaded, then retain the exact module
-- reference for the later destructive-restoration preflight. No feat or spell
-- ownership is inferred when the module really is unavailable.
local SourceFeatCatalog=nil
local SourceFeatCatalogNote="not loaded"
local function RequestSourceFeatCatalog()
    if not Ext or type(Ext.Require)~="function" then
        return nil,"Ext.Require unavailable"
    end
    local ok,catalog=pcall(Ext.Require,"Shared/HB_FeatDefinitionCatalog.lua")
    if ok and type(catalog)=="table" and type(catalog.Find)=="function"
        and type(catalog.ByUUID)=="table" then
        return catalog,"direct catalog"
    end
    -- This is the same contracts module used by the feat replay validator.
    -- It retains a source-backed Catalog as a stable field when available.
    local otherOk,contracts=pcall(Ext.Require,"Shared/HB_GenericFeatContracts.lua")
    if otherOk and type(contracts)=="table" and type(contracts.Catalog)=="table"
        and type(contracts.Catalog.Find)=="function"
        and type(contracts.Catalog.ByUUID)=="table" then
        return contracts.Catalog,"feat contracts catalog"
    end
    return nil,(not ok and tostring(catalog) or
        not otherOk and tostring(contracts) or "catalog module not returned")
end
SourceFeatCatalog,SourceFeatCatalogNote=RequestSourceFeatCatalog()
local EMPTY="00000000-0000-0000-0000-000000000000"
local function Copy(value)
    if type(value)~="table" then return value end
    local out={}
    for key,item in pairs(value) do out[key]=Copy(item) end
    return out
end
local function Id(value)
    local result=tostring(value or ""):lower()
    if result=="" or result=="nil" or result==EMPTY then return EMPTY end
    return result
end
local function UpOne(snapshot)
    local parts=type(snapshot)=="table" and snapshot.components
    local ups=parts and parts.ccLevelUp and parts.ccLevelUp.LevelUps
    return type(ups)=="table" and ups[1] or nil
end
function Bridge.FirstClass(snapshot)
    local row=UpOne(snapshot)
    if type(row)~="table" or Id(row.Class)==EMPTY then
        return nil,"Recorded first-level class is unavailable"
    end
    return {Class=Id(row.Class),SubClass=Id(row.SubClass)}
end
function Bridge.CheckFirstClass(saved,current)
    local old,why=Bridge.FirstClass(saved)
    if not old then return false,why end
    local new,reason=Bridge.FirstClass(current)
    if not new then return false,reason end
    if old.Class~=new.Class then
        return false,"Starting class differs from saved build (saved="..old.Class
            ..", selected="..new.Class..")"
    end
    if old.SubClass~=new.SubClass then
        return false,"Starting subclass differs from saved build (saved="..old.SubClass
            ..", selected="..new.SubClass..")"
    end
    return true,nil
end
local function Dense(t)
    if type(t)~="table" then return false end
    local n,max=0,0
    for i in pairs(t) do
        if type(i)~="number" or i<1 or i~=math.floor(i) then return false end
        n=n+1;if i>max then max=i end
    end
    return n==max
end
local function Empty(t)
    if t==nil then return true end
    if type(t)~="table" then return false end
    return next(t)==nil
end
function Bridge.PreflightOriginal(saved,target)
    if type(saved)~="table" or saved.schemaVersion~=2
        or type(saved.components)~="table" or type(saved.progressions)~="table"
        or type(saved.progressions.buckets)~="table" then
        return false,"Incomplete saved build"
    end
    local one,why=Bridge.FirstClass(saved)
    if not one then return false,why end
    local ups=saved.components.ccLevelUp and saved.components.ccLevelUp.LevelUps
    if not Dense(ups) or #ups~=target then
        return false,"Historical level-up rows are incomplete"
    end
    local classTotals={}
    for level=1,target do
        local row=ups[level]
        if type(row)~="table" or Id(row.Class)==EMPTY then
            return false,"Unverified class history at level "..level
        end
        local id=Id(row.Class)
        classTotals[id]=(classTotals[id] or 0)+1
        if level>1 and not Dense(saved.progressions.buckets[level]) then
            return false,"Unverified progression bucket at level "..level
        end
    end
    local classRows=saved.components.classes and saved.components.classes.Classes
    if not Dense(classRows) then return false,"Saved class composition is incomplete" end
    local counted={};local sum=0
    for _,row in ipairs(classRows) do
        local id=Id(row.ClassUUID);local lvl=tonumber(row.Level)
        if id==EMPTY or not lvl or lvl<1 or lvl~=math.floor(lvl) then
            return false,"Malformed recorded class composition"
        end
        counted[id]=(counted[id] or 0)+lvl;sum=sum+lvl
    end
    if sum~=target then return false,"Saved class levels do not total character level" end
    for id,count in pairs(classTotals) do
        if counted[id]~=count then return false,"Saved classes disagree with level history" end
    end
    for id,count in pairs(counted) do
        if classTotals[id]~=count then return false,"Unrecorded class in saved composition" end
    end
    -- Learned-spell ownership is not recoverable from the spellbook's
    -- class-level source alone. Do not overwrite native level-one learned
    -- spells on Wizard/similar builds until its source mapping is proven.
    local learned=saved.components.learnedSpells
    if learned and (not Empty(learned.ClassSpells) or not Empty(learned.SpellSchools)) then
        return false,"Recorded learned-spell ownership requires a dedicated higher-level merger"
    end
    return true,nil
end
local function SpellId(entry)
    return type(entry)=="table" and type(entry.Id)=="table" and entry.Id or nil
end
local function SpellKey(id)
    if type(id)~="table" then return nil end
    local proto=tostring(id.Prototype or id.OriginatorPrototype or "")
    if proto=="" then return nil end
    return table.concat({proto,tostring(id.SourceType or ""),Id(id.ProgressionSource),Id(id.Source)},"|")
end
local function PreparedKey(id)
    if type(id)~="table" then return nil end
    local proto=tostring(id.OriginatorPrototype or id.Prototype or "")
    if proto=="" then return nil end
    return table.concat({proto,tostring(id.SourceType or ""),Id(id.ProgressionSource),Id(id.Source)},"|")
end
local function SourcesForLevel(saved,startAt,stopAt)
    local result={Direct={},Passives={}}
    local buckets=saved.progressions.buckets
    for i=startAt,stopAt do
        local bucket=buckets[i]
        if type(bucket)~="table" then return nil,"Missing spell ownership bucket at level "..i end
        for _,entry in ipairs(bucket) do
            for _,spell in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                local s=type(spell)=="table" and tostring(spell.SpellId or "") or ""
                if s~="" then result.Direct[s]=true end
            end
            for _,passive in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                local s=tostring(passive or "")
                if s~="" then result.Passives[s]=true end
            end
        end
        -- The CC selection records are a second exact spell ownership source.
        local cc=saved.components.ccLevelUp.LevelUps[i]
        local spells=cc and cc.Upgrades and cc.Upgrades.Spells or {}
        for _,selector in ipairs(spells) do
            for _,spell in ipairs(selector.Spells or {}) do
                result.Direct[tostring(type(spell)=="table" and spell.SpellId or spell)]=true
            end
        end
    end
    return result
end
local function Recognized(prototype,inventory)
    if inventory.Direct[prototype] then return true end
    for stem in pairs(inventory.Direct) do
        if prototype:sub(1,#stem+1)==stem.."_" then return true end
    end
    -- The engine exposes a different SourceType for unlocked passive spells,
    -- but class-owned actions are conventionally named Target_PASSIVE etc.
    -- Require an EXACT passive name after the spell-kind prefix; do not use
    -- fuzzy substring matching (it would import stale level-one actions).
    local suffix=prototype:match("^[%w]+_(.+)$")
    return suffix~=nil and inventory.Passives[suffix]==true
end
-- A deliberately narrow set of pre-existing high-level actions whose
-- progression sources are verified in the captured HB Fighter history.
-- None of these actions appears in the same character at levels 4 or 5;
-- level 12 records the matching ProgressionClass / ProgressionSubClass source.
-- Do NOT generalise this test to arbitrary spellbook entries or SourceTypes.
local AUDITED_FIGHTER="721dfac3-92d4-41f5-b773-b7072a86232f"
local AUDITED_ELDRITCH_KNIGHT="b722614a-303f-411a-bb19-a1882ad1f4cc"
local function AuditedLaterGrant(saved,sid)
    if type(sid)~="table" or Id(sid.Source)~=EMPTY then return false end
    local proto=tostring(sid.Prototype or sid.OriginatorPrototype or "")
    local st=tostring(sid.SourceType or "")
    local source=Id(sid.ProgressionSource)
    local wanted,passive
    if proto=="Target_CommandersStrike" and st=="ProgressionClass"
        and source==AUDITED_FIGHTER then
        wanted=AUDITED_FIGHTER
        passive="CommanderStrike_Maneuver"
    elseif proto=="Shout_ActionSurge" and st=="ProgressionClass"
        and source==AUDITED_FIGHTER then
        wanted=AUDITED_FIGHTER
    elseif proto=="Target_EldritchStrike_3" and st=="ProgressionSubClass"
        and source==AUDITED_ELDRITCH_KNIGHT then
        wanted=AUDITED_ELDRITCH_KNIGHT
    else
        return false
    end
    local first=Bridge.FirstClass(saved)
    if not first or first.Class~=AUDITED_FIGHTER
        or first.SubClass~=AUDITED_ELDRITCH_KNIGHT then return false end
    local buckets=saved.progressions and saved.progressions.buckets
    local ups=saved.components and saved.components.ccLevelUp
        and saved.components.ccLevelUp.LevelUps
    if type(buckets)~="table" or type(ups)~="table" or #ups<6 then return false end
    local found=0
    for level=6,#ups do
        if type(buckets[level])~="table" then return false end
        for _,entry in ipairs(buckets[level]) do
            local meta=entry and entry.meta
            if type(meta)=="table" and Id(meta.Source)==wanted
                and tostring(meta.SpellSourceType or "")==st then
                if passive then
                    for _,recorded in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                        if recorded==passive then found=found+1 end
                    end
                else
                    found=found+1
                end
            end
        end
    end
    -- Exactly one recorded matching owner avoids conflating duplicate grants.
    return passive and found==1 or (not passive and found>=1)
end

-- A native first-level Sorcerer lacks several later conversion actions.
-- Their original spellbook identity is ProgressionClass rather than a CC
-- selected Spell. Admit ONLY the four exact level-three action prototypes
-- observed in a recorded Sorcerer progression, with their original source
-- and unique level-1/2/3 class owners. The level-1/2 sorcery-point actions
-- are intentionally NOT in this later-level allowlist: those must remain
-- governed by native first-level / ordinary provenance classification.
local AUDITED_SORCERER="784001e2-c96d-4153-beb6-2adbef5abc92"
local SORCERER_LATER_CONVERSION_ACTIONS={
    Target_CreateSpellSlot_3=true,
    Target_CreateSpellSlotLVL3=true,
    Target_CreateSorceryPoints_3=true,
    Target_CreateSorceryPointsLVL3=true
}
local function AuditedSorcererLaterConversion(saved,sid)
    if type(sid)~="table" or Id(sid.Source)~=EMPTY
        or tostring(sid.SourceType or "")~="ProgressionClass"
        or Id(sid.ProgressionSource)~=AUDITED_SORCERER then return false end
    local proto=tostring(sid.Prototype or "")
    if not SORCERER_LATER_CONVERSION_ACTIONS[proto]
        or tostring(sid.OriginatorPrototype or "")~=proto then return false end
    local first=Bridge.FirstClass(saved)
    if not first or first.Class~=AUDITED_SORCERER then return false end
    local ups=saved.components and saved.components.ccLevelUp
        and saved.components.ccLevelUp.LevelUps
    local buckets=saved.progressions and saved.progressions.buckets
    if type(ups)~="table" or type(buckets)~="table" or #ups<3 then return false end
    for level=1,3 do
        local row=ups[level]
        if type(row)~="table" or Id(row.Class)~=AUDITED_SORCERER
            or type(buckets[level])~="table" then return false end
        local found=0
        for _,entry in ipairs(buckets[level]) do
            local meta=entry.meta
            if type(meta)=="table" and Id(meta.Source)==AUDITED_SORCERER
                and meta.SpellSourceType=="ProgressionClass"
                and tonumber(meta.Level)==level and tonumber(meta.ClassLevel)==level then
                found=found+1
            end
        end
        if found~=1 then return false end
    end
    return true
end

-- Generic recorded class/subclass-grant provenance. Native level-one respec
-- rebuilds a new spellbook, while saved higher-level class actions can have
-- SourceType=ProgressionClass/ProgressionSubClass with no direct AddSpells or
-- CC choice row. Authorize ONLY an unchanged, engine-labelled owner whose
-- historical progression is still intact on both sides of the staged edit.
-- Never authorize removal of an explicitly chosen spell or newly invented
-- class/subclass owner merely because the spellbook labels it ProgressionClass.
local function AuditedClassSubclassLaterGrant(saved,original,sid)
    if type(sid)~="table" or type(original)~="table"
        or Id(sid.Source)~=EMPTY then return false end
    local proto=tostring(sid.Prototype or "")
    local origin=tostring(sid.OriginatorPrototype or "")
    local sourceType=tostring(sid.SourceType or "")
    local owner=Id(sid.ProgressionSource)
    -- BG3 can store an engine-owned ranked/derived action with a different
    -- Prototype and OriginatorPrototype (e.g. a level-specific cast variant).
    -- Identity equality is NOT an ownership rule. The original captured
    -- spellbook below must independently corroborate *both* identities,
    -- while all class/subclass, progression and selection checks still apply.
    if proto=="" or origin=="" or owner==EMPTY
        or (sourceType~="ProgressionClass" and sourceType~="ProgressionSubClass") then
        return false
    end
    local newCC=saved.components and saved.components.ccLevelUp
        and saved.components.ccLevelUp.LevelUps
    local oldCC=original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newBuckets=saved.progressions and saved.progressions.buckets
    local oldBuckets=original.progressions and original.progressions.buckets
    if type(newCC)~="table" or type(oldCC)~="table"
        or type(newBuckets)~="table" or type(oldBuckets)~="table"
        or #newCC~=#oldCC or #newCC<2 then return false end
    -- A class/subclass switch uses vanilla Full Respec, never this owner bridge.
    local selectedClasses,selectedSubclasses={},{}
    local selectedSpells={}
    for level=1,#newCC do
        local after,before=newCC[level],oldCC[level]
        if type(after)~="table" or type(before)~="table"
            or Id(after.Class)~=Id(before.Class)
            or Id(after.SubClass)~=Id(before.SubClass) then return false end
        local class=Id(after.Class)
        if class~=EMPTY then selectedClasses[class]=true end
        local subclass=Id(after.SubClass)
        if subclass~=EMPTY then selectedSubclasses[subclass]=class end
        local spellChoices=before.Upgrades and before.Upgrades.Spells or {}
        local replacementChoices=after.Upgrades and after.Upgrades.Spells or {}
        if type(spellChoices)~="table" or type(replacementChoices)~="table" then return false end
        for _,row in ipairs(spellChoices) do
            for _,value in ipairs(row.Spells or {}) do
                local id=tostring(type(value)=="table" and value.SpellId or value)
                if id==proto or id==origin or proto:sub(1,#id+1)==id.."_" then
                    selectedSpells[id]=true
                end
            end
        end
        -- Must not automatically reimport a choice deliberately removed by
        -- Selective Respec: generic handling only applies to non-choice grants.
        if next(selectedSpells) then return false end
    end
    if sourceType=="ProgressionClass" and not selectedClasses[owner] then return false end
    if sourceType=="ProgressionSubClass" and not selectedSubclasses[owner] then return false end
    local originalBook=original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if type(originalBook)~="table" then return false end
    local key=SpellKey(sid)
    local exact=0
    for _,row in ipairs(originalBook) do
        local prior=SpellId(row)
        if SpellKey(prior)==key
            and tostring(prior.OriginatorPrototype or "")==origin then
            exact=exact+1
        end
    end
    -- No invented roots, ID-prefix inference or action whitelists. A valid
    -- ranked action must have the exact engine-recorded parent identity in
    -- the original, unique class/subclass-owned spellbook entry.
    if exact~=1 then return false end
    local qualifying=0
    local classLevels={}
    for level=1,#newCC do
        local chosen=Id(newCC[level].Class)
        if chosen~=EMPTY then classLevels[chosen]=(classLevels[chosen] or 0)+1 end
        local old,now=oldBuckets[level],newBuckets[level]
        if type(old)~="table" or type(now)~="table" then return false end
        local oldFound,nowFound=nil,nil
        for _,entry in ipairs(old) do
            local meta=entry.meta
            if type(meta)=="table" and Id(meta.Source)==owner
                and tostring(meta.SpellSourceType or "")==sourceType then
                if oldFound then return false end
                oldFound=entry
            end
        end
        for _,entry in ipairs(now) do
            local meta=entry.meta
            if type(meta)=="table" and Id(meta.Source)==owner
                and tostring(meta.SpellSourceType or "")==sourceType then
                if nowFound then return false end
                nowFound=entry
            end
        end
        if (oldFound~=nil)~=(nowFound~=nil) then return false end
        if nowFound then
            local meta=nowFound.meta
            local before=oldFound.meta
            if Id(meta.Progression)~=Id(before.Progression)
                or tonumber(meta.Level)~=level or tonumber(before.Level)~=level
                or tonumber(meta.ClassLevel)~=tonumber(before.ClassLevel)
                or (sourceType=="ProgressionClass" and tonumber(meta.ClassLevel)~=classLevels[owner])
                or Id(meta.Source)~=owner then return false end
            -- Prove that the progression's automatic passive grants were not
            -- replaced in this edit. A removed passive could have owned the
            -- action; in that case a separate passive-grant verifier is needed.
            local function PassiveSignature(entry)
                local passives=entry.passives or {}
                local added=passives.AddPassives or {}
                local removed=passives.RemovePassives or {}
                if type(added)~="table" or type(removed)~="table" then return nil end
                return table.concat(added,"|").."/"..table.concat(removed,"|")
            end
            if PassiveSignature(oldFound)~=PassiveSignature(nowFound) then return false end
            if level>1 then
                if sourceType=="ProgressionClass" then
                    if Id(newCC[level].Class)~=owner then return false end
                else
                    if Id(newCC[level].Class)~=selectedSubclasses[owner] then return false end
                end
                qualifying=qualifying+1
            end
        end
    end
    return qualifying>0
end

-- The Wizard Counterspell reaction is an exact, engine-recorded live alias
-- of the selected Target_Counterspell spell. In an original Wizard 12 capture
-- the root was selected at WIZARD LEVEL ONE (not a later level). Retain only
-- the unchanged, uniquely recorded class-root grant, including level one.
-- Never infer ownership from a MAG_ prefix or ProgressionClass alone.
local AUDITED_WIZARD_COUNTERSPELL_CLASS="a865965f-501b-46e9-9eaa-7748e8c04d09"
local function VerifiedWizardCounterspellAlias(saved,original,sid)
    if type(sid)~="table" or type(original)~="table"
        or tostring(sid.Prototype or "")~="Target_MAG_CounterSpell"
        or tostring(sid.OriginatorPrototype or "")~="Target_Counterspell"
        or tostring(sid.SourceType or "")~="ProgressionClass"
        or Id(sid.ProgressionSource)~=AUDITED_WIZARD_COUNTERSPELL_CLASS
        or Id(sid.Source)~=EMPTY then return false end
    -- The precise alias must have existed exactly once in the original
    -- engine-owned SpellBook; it cannot be synthesized from CC choices alone.
    local oldBook=original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldBook) then return false end
    local exact,key=0,SpellKey(sid)
    for _,row in ipairs(oldBook) do
        local prior=SpellId(row)
        if SpellKey(prior)==key then
            if tostring(prior.OriginatorPrototype or "")~="Target_Counterspell" then
                return false
            end
            exact=exact+1
        end
    end
    if exact~=1 then return false end
    -- Both names must be real installed spells. When the engine exposes a
    -- RootSpellID on the alias, it must explicitly agree with the root.
    if not Ext or not Ext.Stats or type(Ext.Stats.Get)~="function" then
        return false
    end
    local okAlias,aliasStat=pcall(Ext.Stats.Get,"Target_MAG_CounterSpell")
    local okRoot,rootStat=pcall(Ext.Stats.Get,"Target_Counterspell")
    if not okAlias or not aliasStat or not okRoot or not rootStat then
        return false
    end
    local okStats,aliasType,rootType,linked=pcall(function()
        return tostring(aliasStat.SpellType or ""),
            tostring(rootStat.SpellType or ""),
            tostring(aliasStat.RootSpellID or "")
    end)
    if not okStats or aliasType=="" or aliasType~=rootType
        or (linked~="" and linked~="Target_Counterspell") then return false end
    local function RootChoiceAt(snapshot)
        local components=snapshot.components
        local ups=components and components.ccLevelUp
            and components.ccLevelUp.LevelUps
        local buckets=snapshot.progressions and snapshot.progressions.buckets
        if not Dense(ups) or #ups<1 or type(buckets)~="table" then return nil end
        local foundLevel=nil
        local wizardLevels=0
        for level,row in ipairs(ups) do
            if type(row)~="table" or not Dense(buckets[level]) then return nil end
            local belongs=Id(row.Class)==AUDITED_WIZARD_COUNTERSPELL_CLASS
            if belongs then wizardLevels=wizardLevels+1 end
            local selected=0
            for _,selector in ipairs(row.Upgrades and row.Upgrades.Spells or {}) do
                for _,pick in ipairs(selector.Spells or {}) do
                    local root=type(pick)=="table" and pick.SpellId or pick
                    if root=="Target_Counterspell" then
                        if not belongs or tostring(selector.Type or "")~="Class"
                            or Id(selector.Class)~=AUDITED_WIZARD_COUNTERSPELL_CLASS
                            or (selector.Level~=nil
                                and tonumber(selector.Level)~=wizardLevels) then
                            return nil
                        end
                        selected=selected+1
                    end
                end
            end
            if selected>0 then
                if selected~=1 or foundLevel then return nil end
                local progressions,rootGrants=0,0
                for _,entry in ipairs(buckets[level]) do
                    local meta=entry.meta
                    if type(meta)=="table"
                        and Id(meta.Source)==AUDITED_WIZARD_COUNTERSPELL_CLASS
                        and tostring(meta.SpellSourceType or "")=="ProgressionClass"
                        and tonumber(meta.Level)==level
                        and tonumber(meta.ClassLevel)==wizardLevels
                        and Id(meta.Progression)~=EMPTY then
                        progressions=progressions+1
                        local grants=entry.spells and entry.spells.AddSpells or {}
                        if type(grants)~="table" then return nil end
                        for _,grant in ipairs(grants) do
                            if type(grant)=="table"
                                and grant.SpellId=="Target_Counterspell" then
                                rootGrants=rootGrants+1
                            end
                        end
                    end
                end
                -- The original Wizard's CCLevelUp records Counterspell as
                -- a first-level Class spell choice, corroborated by exactly
                -- one first-level ProgressionClass.AddSpells root grant.
                -- Require the same proof on both sides of a staged edit.
                if progressions~=1 or rootGrants~=1 then return nil end
                foundLevel=level
            end
        end
        return foundLevel
    end
    local before=RootChoiceAt(original)
    local after=RootChoiceAt(saved)
    if not before or before~=after then return false end
    -- The selected root belongs to the very same native progression, even
    -- when the user edits OTHER Wizard passives/spells at this level.
    local function ProgressionAt(snapshot,level)
        local found=nil
        for _,entry in ipairs(snapshot.progressions.buckets[level]) do
            local meta=entry.meta
            if type(meta)=="table"
                and Id(meta.Source)==AUDITED_WIZARD_COUNTERSPELL_CLASS
                and tostring(meta.SpellSourceType or "")=="ProgressionClass" then
                if found then return nil end
                found=Id(meta.Progression)
            end
        end
        return found
    end
    local oldProgression=ProgressionAt(original,before)
    return oldProgression~=nil and oldProgression~=EMPTY
        and oldProgression==ProgressionAt(saved,after)
end

-- Generic, fail-closed feat-grant provenance for replaced historical feats.
-- SourceType=Feat is NOT sufficient on its own: the original feat choice,
 -- unique progression feat owner, replicated feat, class source, and either
-- an exact AddSpells grant or a proven original passive UnlockSpell grant
-- must all agree. Unknown indirect action grants remain protected.
local function FeatCatalogDefinition(id)
    local wanted=Id(id)
    -- Prefer the startup-captured version. Engine native callbacks can occur
    -- after the Lua module loader changes state, even though the script and
    -- its original catalog data are still live.
    local catalog=SourceFeatCatalog
    if not catalog then
        catalog,SourceFeatCatalogNote=RequestSourceFeatCatalog()
        if catalog then SourceFeatCatalog=catalog end
    end
    if not catalog then return nil,SourceFeatCatalogNote end
    local found=catalog.ByUUID and catalog.ByUUID[wanted]
    if type(found)~="table" and type(catalog.Find)=="function" then
        local ok,value=pcall(catalog.Find,wanted)
        if ok then found=value end
    end
    if type(found)=="table" and Id(found.UUID)==wanted then
        return found
    end
    return nil,"feat UUID absent from source-backed catalog"
end
local function SameGrant(a,b)
    if type(a)~="table" or type(b)~="table" then return false end
    for _,k in ipairs({"SpellId","SpellList","CastingAbility","Class",
        "CooldownType","PrepareType"}) do
        if tostring(a[k] or "")~=tostring(b[k] or "") then return false end
    end
    return type(a.SpellId)=="string" and a.SpellId~=""
end
-- A feat and its class may contribute spells to the SAME progression
-- entry. Feat.AddSpells identifies the feat-owned subset; any additional
-- ProgressionSpells must independently match the original same-level CLASS
-- spell selector, not be attributed to the removed feat.
local function DirectFeatGrants(entry,choice,level)
    local first=entry.feat and entry.feat.AddSpells or {}
    local second=entry.spells and entry.spells.AddSpells or {}
    if type(first)~="table" or type(second)~="table"
        or #first>8 or #second>32 then return nil end
    local ids={};local used={}
    for _,grant in ipairs(first) do
        local id=type(grant)=="table" and grant.SpellId
        if type(id)~="string" or id=="" or ids[id] then return nil end
        local match=nil
        for index,other in ipairs(second) do
            if SameGrant(grant,other) then
                if match then return nil end
                match=index
            end
        end
        if not match or used[match] then return nil end
        used[match]=true
        ids[id]=true
    end
    local classSelections={}
    local progressionClass=Id(entry.meta and entry.meta.Source)
    for _,row in ipairs(choice and choice.Upgrades and choice.Upgrades.Spells or {}) do
        if tostring(row.Type or "")=="Class"
            and Id(row.Class)==progressionClass
            and tonumber(row.Level)==level and type(row.Spells)=="table" then
            for _,pick in ipairs(row.Spells) do
                local spell=type(pick)=="table" and pick.SpellId or pick
                if type(spell)~="string" or spell=="" or classSelections[spell] then
                    return nil
                end
                classSelections[spell]=true
            end
        end
    end
    for index,grant in ipairs(second) do
        if not used[index] then
            local id=type(grant)=="table" and grant.SpellId
            if type(id)~="string" or not classSelections[id] or ids[id] then
                return nil
            end
            classSelections[id]=nil
            used[index]=true
        end
    end
    -- Every class selector spell must have a corresponding progression
    -- spell grant in this owner; this avoids explaining extra spell grants
    -- merely from a partially recorded/mismatched choice list.
    if next(classSelections)~=nil then return nil end
    return ids
end
-- Runtime passive Boosts are the only accepted indirect source. The exact
-- UnlockSpell(<prototype>) token must occur in the installed passive stat;
-- display text, similar names, or an arbitrary boost string are not proof.
local function PassiveUnlocks(definition,prototype)
    if type(definition)~="table" or type(definition.PassivesAdded)~="table"
        or not Ext or not Ext.Stats or not Ext.Stats.Get then return false end
    local matches=0;local seen={}
    for _,passive in ipairs(definition.PassivesAdded) do
        if type(passive)~="string" or passive=="" or seen[passive] then
            return false
        end
        seen[passive]=true
        local ok,stats=pcall(Ext.Stats.Get,passive)
        if not ok or not stats then return false end
        local okBoost,boosts=pcall(function() return stats.Boosts end)
        if not okBoost or type(boosts)~="string" then return false end
        for token in boosts:gmatch("UnlockSpell%s*%(%s*([%w_]+)") do
            if token==prototype then matches=matches+1 end
        end
    end
    return matches==1
end
-- A feat may unlock executable descendants of a *selected* passive or of an
-- installed automatic feat passive, without ever recording those child spells
-- as independently chosen spells. These spellbook records retain Feat origin
-- but only the class in ProgressionSource. The feat's source catalog, its
-- exact selector list/choice count and both progression passive mirrors are
-- required before using the child's structured ID as secondary evidence.
-- Never derive an element choice from a generic parent prefix: an unchosen
-- ElementalFletching_Lightning child must not be explained by the installed
-- ElementalFletching parent when only Acid/Cold/Fire were chosen.
local function FeatPassiveVariantMatch(definition,featRows,prototype)
    if type(definition)~="table" or type(definition.Selectors)~="table"
        or type(definition.PassivesAdded)~="table" or type(featRows)~="table" then
        return false
    end
    local action=prototype:match("^[%a][%w]*_(.+)$")
    if not action or action=="" then return false end
    local selectors={};local allSelected={};local count=0
    for _,selector in ipairs(definition.Selectors) do
        if selector.Kind=="SelectPassives" then
            local list=Id(selector.SpellList)
            if list==EMPTY or selectors[list] then return false end
            selectors[list]={Count=tonumber(selector.Count),Matches=0}
        end
    end
    for _,row in ipairs(featRows) do
        local owner=selectors[Id(row.PassiveList)]
        if not owner or not owner.Count or owner.Count~=#row.Passives then
            return false
        end
        owner.Matches=owner.Matches+1
        for _,passive in ipairs(row.Passives) do
            if type(passive)~="string" or passive=="" or allSelected[passive] then
                return false
            end
            allSelected[passive]=true
            if action==passive or action:sub(1,#passive+1)==passive.."_" then
                count=count+1
            end
        end
    end
    for _,selector in pairs(selectors) do
        if selector.Matches~=1 then return false end
    end
    if count~=0 then return count==1 end
    -- Automatic feat passives also generate actions. Allow an exact named
    -- action or a contiguous (non-underscore) suffix only. An underscore
    -- starts a *selection* namespace and must not be attributed to the
    -- automatic parent (e.g. unselected ElementalFletching_Lightning).
    local fixedSeen={}
    for _,passive in ipairs(definition.PassivesAdded) do
        if type(passive)~="string" or passive=="" or fixedSeen[passive] then
            return false
        end
        fixedSeen[passive]=true
        local suffix=action:sub(#passive+1)
        if action==passive or (action:sub(1,#passive)==passive
            and suffix~="" and suffix:match("^[%a%d]")~=nil) then
            count=count+1
        end
    end
    return count==1
end

-- Feat-sourced spellbook identities are produced by BG3's feat/passive
-- lifecycle, not independent learned spells. Resolve the historical owner
-- before deciding whether an original action must survive or disappear.
-- A direct installed UnlockSpell is preferred. When stats omit that metadata,
-- accept only an unambiguous namespaced selected-passive package with exact
-- CC + both progression records; never infer from SourceType=Feat alone.
local function HistoricalFeatActionOwner(original,sid)
    if type(sid)~="table" or tostring(sid.SourceType or "")~="Feat"
        or Id(sid.Source)~=EMPTY or Id(sid.ProgressionSource)==EMPTY then return nil end
    local prototype=tostring(sid.Prototype or "")
    if prototype=="" or prototype~=tostring(sid.OriginatorPrototype or "") then return nil end
    local oldUps=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local buckets=original and original.progressions and original.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldUps) or type(buckets)~="table" or not Dense(book) then return nil end
    local oldKey=SpellKey(sid)
    local identical,matchingNames=0,0
    for _,row in ipairs(book) do
        local other=SpellId(row)
        if other and tostring(other.Prototype or "")==prototype then
            matchingNames=matchingNames+1
            if SpellKey(other)==oldKey then identical=identical+1 end
        end
    end
    if identical~=1 or matchingNames~=1 then return nil end
    local namespace=prototype:match("_([%w]+)$")
    local candidates={}
    for level=2,#oldUps do
        local up=oldUps[level]
        local feat=Id(up and up.Feat)
        if feat~=EMPTY and Id(up.Class)==Id(sid.ProgressionSource) then
            local owner,count=nil,0
            for _,entry in ipairs(buckets[level] or {}) do
                if type(entry)=="table" and type(entry.feat)=="table"
                    and Id(entry.feat.Feat)==feat and type(entry.meta)=="table"
                    and Id(entry.meta.Source)==Id(sid.ProgressionSource)
                    and tonumber(entry.meta.Level)==level
                    and (entry.meta.SpellSourceType=="ProgressionClass"
                         or entry.meta.SpellSourceType=="ProgressionSubClass")
                    and Id(entry.replicatedFeat and entry.replicatedFeat.Feat)==feat then
                    owner=entry;count=count+1
                end
            end
            if count~=1 then return nil end
            local selected={};local found={};local packages=0;local featRows={}
            for _,row in ipairs(up.Upgrades and up.Upgrades.Passives or {}) do
                if Id(row.Class)==feat then
                    if row.Type~="Feat" or tonumber(row.Level)~=level
                        or Id(row.Subclass)~=Id(up.Class)
                        or type(row.SelectorId)~="string"
                        or not Dense(row.Passives) or #row.Passives<1 then return nil end
                    packages=packages+1
                    featRows[#featRows+1]=row
                    for _,passive in ipairs(row.Passives) do
                        if type(passive)~="string" or passive=="" or found[passive] then return nil end
                        found[passive]=true; selected[#selected+1]=passive
                    end
                end
            end
            if packages>0 then
                local featPassives=owner.feat.AddPassives
                local grantedPassives=owner.passives and owner.passives.AddPassives
                if not Dense(featPassives) or not Dense(grantedPassives) then return nil end
                local function ExactlyOnce(items,value)
                    local number=0
                    for _,item in ipairs(items) do if item==value then number=number+1 end end
                    return number==1
                end
                local matchedUnlock,allNamespaced=0,true
                local ns=nil
                for _,passive in ipairs(selected) do
                    if not ExactlyOnce(featPassives,passive)
                        or not ExactlyOnce(grantedPassives,passive) then return nil end
                    local prefix=passive:match("^([%w]+)_")
                    if not prefix or #prefix<4 or (ns and ns~=prefix) then
                        allNamespaced=false
                    end
                    ns=ns or prefix
                    if Ext and Ext.Stats and type(Ext.Stats.Get)=="function" then
                        local ok,stat=pcall(Ext.Stats.Get,passive)
                        if ok and stat then
                            local read,boosts=pcall(function() return stat.Boosts end)
                            if read then
                                -- Some SE environments expose boost data as
                                -- an array, others as a semicolon-separated string.
                                local function Inspect(value)
                                    if type(value)=="string" then
                                        for id in value:gmatch("UnlockSpell%s*%(%s*([%w_]+)") do
                                            if id==prototype then matchedUnlock=matchedUnlock+1 end
                                        end
                                    end
                                end
                                Inspect(boosts)
                                if type(boosts)=="table" then
                                    for _,item in ipairs(boosts) do Inspect(item) end
                                end
                            end
                        end
                    end
                end
                if matchedUnlock>1 then return nil end
                local byNamespace=namespace and #namespace>=4 and allNamespaced
                    and ns==namespace and #selected>=1
                local installedDefinition=FeatCatalogDefinition(feat)
                local byRecordedVariant=FeatPassiveVariantMatch(
                    installedDefinition,featRows,prototype)
                if matchedUnlock==1 or byNamespace or byRecordedVariant then
                    candidates[#candidates+1]={Feat=feat,Level=level,Owner=owner,
                        PassiveList=selected,Selection=up,SpellKey=oldKey}
                end
            end
        end
    end
    return #candidates==1 and candidates[1] or nil
end

-- A feat with SelectSpells (e.g. Accord) owns its selected spells through
-- the feat's recorded SpellSelector and mirrored ProgressionFeat/Spells grants.
-- This is DIFFERENT from a passive's UnlockSpell action. Neither grant should
-- be imported from a serialized SpellBook or re-added as an Osiris spell.
-- Only an unchanged, uniquely verified feat spell package may be retained;
-- RemovedFeatGrantKeys independently handles the opposite (removed) case.
local function RetainedSelectedFeatSpell(original,edited,sid)
    if type(sid)~="table" or tostring(sid.SourceType or "")~="Feat"
        or Id(sid.ProgressionSource)==EMPTY then return false end
    local proto=tostring(sid.Prototype or "")
    if proto=="" or tostring(sid.OriginatorPrototype or "")~=proto then return false end
    local oldUps=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newUps=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original and original.progressions and original.progressions.buckets
    local newBuckets=edited and edited.progressions and edited.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldUps) or not Dense(newUps) or #oldUps~=#newUps
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or not Dense(book) then return false end
    local identity=SpellKey(sid)
    local identical,sameName=0,0
    for _,row in ipairs(book) do
        local current=SpellId(row)
        if current and tostring(current.Prototype or "")==proto then
            sameName=sameName+1
            if SpellKey(current)==identity then identical=identical+1 end
        end
    end
    if identical~=1 or sameName~=1 then return false end
    local owned=0
    for level=2,#oldUps do
        local before,after=oldUps[level],newUps[level]
        local feat=Id(before and before.Feat)
        if feat~=EMPTY and Id(after and after.Feat)==feat
            and Id(before.Class)==Id(after.Class)
            and Id(before.SubClass)==Id(after.SubClass)
            and Id(before.Class)==Id(sid.ProgressionSource)
            and (Id(sid.Source)==EMPTY or Id(sid.Source)==feat) then
            local definition=FeatCatalogDefinition(feat)
            if type(definition)=="table" and type(definition.Selectors)=="table" then
                local oldRows,newRows={},{}
                local function FindRows(up,result)
                    for _,row in ipairs(up.Upgrades and up.Upgrades.Spells or {}) do
                        if Id(row.Class)==feat then
                            if tostring(row.Type or "")~="Feat" or tonumber(row.Level)~=level
                                or Id(row.Subclass)~=Id(up.Class) or not Dense(row.Spells)
                                or not Empty(row.ReplaceSpells) then return false end
                            result[#result+1]=row
                        end
                    end
                    return true
                end
                if FindRows(before,oldRows) and FindRows(after,newRows)
                    and #oldRows>0 and #oldRows==#newRows then
                    local choices,found={},{}
                    local verified=true
                    local knownSelectors={}
                    for _,selector in ipairs(definition.Selectors) do
                        if selector.Kind=="SelectSpells" then
                            local sig=tostring(selector.SpellList or "").."|"
                                ..tostring(selector.Args and selector.Args[4] or "")
                            if knownSelectors[sig] then verified=false end
                            knownSelectors[sig]=selector
                        end
                    end
                    if #oldRows==0 then verified=false end
                    local recognized={}
                    for index,row in ipairs(oldRows) do
                        local nextRow=newRows[index]
                        local selector=knownSelectors[tostring(row.SpellList or "").."|"
                            ..tostring(row.SelectorId or "")]
                        if not selector or not nextRow or not Dense(nextRow.Spells)
                            or tostring(nextRow.Type or "")~=tostring(row.Type or "")
                            or tostring(nextRow.SelectorId or "")~=tostring(row.SelectorId or "")
                            or tostring(nextRow.SpellList or "")~=tostring(row.SpellList or "")
                            or tonumber(nextRow.Level)~=level or #row.Spells~=#nextRow.Spells
                            or #row.Spells~=tonumber(selector.Count)
                            or recognized[selector] then verified=false;break end
                        recognized[selector]=true
                        for i,id in ipairs(row.Spells) do
                            if type(id)~="string" or id=="" or found[id]
                                or nextRow.Spells[i]~=id then verified=false;break end
                            found[id]=true;choices[id]=true
                        end
                        if not verified then break end
                    end
                    local selectorCount=0
                    for _ in pairs(knownSelectors) do selectorCount=selectorCount+1 end
                    if selectorCount~=#oldRows then verified=false end
                    if verified and choices[proto] then
                        local function OneOwner(entries)
                            local match=nil
                            for _,entry in ipairs(entries or {}) do
                                if Id(entry.feat and entry.feat.Feat)==feat
                                    or Id(entry.replicatedFeat and entry.replicatedFeat.Feat)==feat then
                                    if match or Id(entry.feat and entry.feat.Feat)~=feat
                                        or Id(entry.replicatedFeat and entry.replicatedFeat.Feat)~=feat
                                        or Id(entry.meta and entry.meta.Source)~=Id(before.Class)
                                        or tonumber(entry.meta and entry.meta.Level)~=level
                                        or tostring(entry.meta.SpellSourceType or "")~="ProgressionClass"
                                        then return nil end
                                    match=entry
                                end
                            end
                            return match
                        end
                        local former=OneOwner(oldBuckets[level])
                        local retained=OneOwner(newBuckets[level])
                        if former and retained
                            and Id(former.meta.Progression)==Id(retained.meta.Progression)
                            and Id(former.meta.Progression)~=EMPTY then
                            local oldGrants=DirectFeatGrants(former,before,level)
                            local newGrants=DirectFeatGrants(retained,after,level)
                            if oldGrants and newGrants then
                                for id in pairs(choices) do
                                    if not oldGrants[id] or not newGrants[id] then verified=false end
                                end
                                for id in pairs(oldGrants) do if not choices[id] then verified=false end end
                                for id in pairs(newGrants) do if not choices[id] then verified=false end end
                                -- Any feat-owned grant must still be the exact original
                                -- signed grant; class spell grants may coexist separately.
                                for _,grant in ipairs(former.feat.AddSpells or {}) do
                                    local n=0
                                    for _,other in ipairs(retained.feat.AddSpells or {}) do
                                        if SameGrant(grant,other) then n=n+1 end
                                    end
                                    if n~=1 then verified=false end
                                end
                                if #(former.feat.AddSpells or {})~=#(retained.feat.AddSpells or {})
                                    then verified=false end
                            else verified=false end
                        else verified=false end
                    else verified=false end
                    if verified then owned=owned+1 end
                end
            end
        end
    end
    -- No name-only match or spell-type-wide fallback. Two possible owners are
    -- ambiguous even if both list the same cantrip.
    return owned==1
end

-- The historical feat owner must either remain fully intact, or be fully
-- removed. A partial change is not automatically classifiable as a grant
-- that should survive or disappear; it must use more specific handling.
local function FeatActionDisposition(original,edited,sid)
    local owner=HistoricalFeatActionOwner(original,sid)
    if not owner then return nil end
    local level,feat=owner.Level,owner.Feat
    local ups=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local buckets=edited and edited.progressions and edited.progressions.buckets
    if not Dense(ups) or type(buckets)~="table" then return nil end
    local now=ups[level]
    if type(now)~="table" then return nil end
    local originalPassives=owner.Selection.Upgrades.Passives
    local currentPassives=now.Upgrades and now.Upgrades.Passives or {}
    if Id(now.Feat)==feat then
        local matches=0
        for _,row in ipairs(currentPassives) do
            if Id(row.Class)==feat then
                for _,old in ipairs(originalPassives) do
                    if Id(old.Class)==feat and row.Type==old.Type
                        and row.SelectorId==old.SelectorId
                        and Id(row.PassiveList)==Id(old.PassiveList)
                        and Dense(row.Passives) and #row.Passives==#old.Passives then
                        local equal=true
                        for k,p in ipairs(old.Passives) do
                            if row.Passives[k]~=p then equal=false end
                        end
                        if equal then matches=matches+1 end
                    end
                end
            end
        end
        local owners=0
        for _,entry in ipairs(buckets[level] or {}) do
            if Id(entry.feat and entry.feat.Feat)==feat
                and Id(entry.replicatedFeat and entry.replicatedFeat.Feat)==feat
                and Id(entry.meta and entry.meta.Source)==Id(sid.ProgressionSource)
                and tonumber(entry.meta.Level)==level then
                local ok=true
                for _,passive in ipairs(owner.PassiveList) do
                    local n=0
                    for _,p in ipairs(entry.feat.AddPassives or {}) do if p==passive then n=n+1 end end
                    local m=0
                    for _,p in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                        if p==passive then m=m+1 end
                    end
                    if n~=1 or m~=1 then ok=false end
                end
                if ok then owners=owners+1 end
            end
        end
        local originalCount=0
        for _,row in ipairs(originalPassives) do if Id(row.Class)==feat then originalCount=originalCount+1 end end
        if matches==originalCount and matches>0 and owners==1 then return "retained" end
        return nil
    end
    for i,up in ipairs(ups) do
        if Id(up.Feat)==feat then return nil end
        for _,row in ipairs(up.Upgrades and up.Upgrades.Passives or {}) do
            if Id(row.Class)==feat then return nil end
        end
        for _,entry in ipairs(buckets[i] or {}) do
            if Id(entry.feat and entry.feat.Feat)==feat
                or Id(entry.replicatedFeat and entry.replicatedFeat.Feat)==feat then return nil end
        end
    end
    for _,row in ipairs(currentPassives) do
        for _,passive in ipairs(row.Passives or {}) do
            for _,previous in ipairs(owner.PassiveList) do
                if passive==previous then return nil end
            end
        end
    end
    for _,bucket in ipairs(buckets) do
        for _,entry in ipairs(bucket) do
            for _,passive in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                for _,previous in ipairs(owner.PassiveList) do
                    if passive==previous then return nil end
                end
            end
            for _,field in ipairs({"spells","feat","replicatedFeat"}) do
                for _,grant in ipairs(entry[field] and entry[field].AddSpells or {}) do
                    if grant.SpellId==sid.Prototype then return nil end
                end
            end
        end
    end
    return "removed"
end

-- Proven unchanged AUTOMATIC feat actions: ordinary feats with zero secondary
-- selectors can provide one or more native spellbook actions from a passive
-- without recording those actions in CCLevelUp.Upgrades.Spells or in a
-- ProgressionSpells.AddSpells row. Never guess an owner from SourceType=Feat.
-- The source feat definition, both exact CC feat choices, one unique game
-- progression/replicated-feat owner, the original spellbook identity and an
-- installed passive-grant identity must all corroborate an unchanged grant.
-- Covers any catalogued automatic feat, not a hardcoded list of action IDs.
local function RetainedAutomaticFeatAction(original,edited,sid)
    if type(sid)~="table" or tostring(sid.SourceType or "")~="Feat"
        or Id(sid.ProgressionSource)==EMPTY then return false end
    local proto=tostring(sid.Prototype or "")
    if proto=="" or proto~=tostring(sid.OriginatorPrototype or "") then return false end
    local oldUps=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newUps=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original and original.progressions and original.progressions.buckets
    local newBuckets=edited and edited.progressions and edited.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldUps) or not Dense(newUps) or #oldUps~=#newUps
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or not Dense(book) then return false end
    local key=SpellKey(sid)
    if not key then return false end
    local exact,sameName=0,0
    for _,row in ipairs(book) do
        local id=SpellId(row)
        if id and tostring(id.Prototype or "")==proto then
            sameName=sameName+1
            if SpellKey(id)==key then exact=exact+1 end
        end
    end
    if exact~=1 or sameName~=1 then return false end
    local owners=0
    for level=2,#oldUps do
        local before,after=oldUps[level],newUps[level]
        local feat=Id(before and before.Feat)
        if feat~=EMPTY and Id(before.Class)==Id(sid.ProgressionSource) then
            local definition=FeatCatalogDefinition(feat)
            -- This proof is only for AUTOMATIC passives. Feats with secondary
            -- selectors use the existing exact selector-specific validators.
            if type(definition)=="table" and type(definition.Selectors)=="table"
                and #definition.Selectors==0
                and type(definition.PassivesAdded)=="table"
                and #definition.PassivesAdded>0
                and (Id(sid.Source)==EMPTY or Id(sid.Source)==feat) then
                -- An automatic feat has no FEAT-owned secondary selectors.
                -- We cannot safely infer that an edited selector is unchanged.
                local function HasFeatChoices(up)
                    for _,category in ipairs({"Passives","Spells","Skills","SkillExpertise","AbilityBonuses"}) do
                        for _,row in ipairs(up.Upgrades and up.Upgrades[category] or {}) do
                            if Id(row.Class)==feat then return true end
                        end
                    end
                    return false
                end
                if not HasFeatChoices(before) and not HasFeatChoices(after) then
                    local matching=0
                    local known={}
                    local foundPassive=nil
                    local prefix,action=proto:match("^([%a][%w]*)_(.+)$")
                    if prefix and action then
                        for _,passive in ipairs(definition.PassivesAdded) do
                            if type(passive)~="string" or passive=="" or known[passive] then
                                return false
                            end
                            known[passive]=true
                            local suffix=action:sub(#passive+1)
                            local named=action==passive
                                or (action:sub(1,#passive)==passive
                                    and suffix:match("^_[1-6]$")~=nil)
                            local explicit=PassiveUnlocks({PassivesAdded={passive}},proto)
                            if named or explicit then
                                matching=matching+1
                                foundPassive=passive
                                if named and suffix~="" then
                                    -- For numbered casts, prove the exact
                                    -- unsuffixed owner was in the ORIGINAL book.
                                    local base=prefix.."_"..passive
                                    local n=0
                                    for _,row in ipairs(book) do
                                        local id=SpellId(row)
                                        if id and tostring(id.Prototype or "")==base
                                            and tostring(id.OriginatorPrototype or "")==base
                                            and tostring(id.SourceType or "")=="Feat"
                                            and Id(id.ProgressionSource)==Id(sid.ProgressionSource)
                                            and Id(id.Source)==Id(sid.Source) then
                                            n=n+1
                                        end
                                    end
                                    if n~=1 then return false end
                                end
                            end
                        end
                    end
                    if matching==1 and foundPassive then
                        if Id(after.Feat)~=feat or Id(after.Class)~=Id(before.Class)
                            or Id(after.SubClass)~=Id(before.SubClass) then return false end
                        local function UniqueProgression(snapshotBuckets)
                            local found=nil
                            for _,entry in ipairs(snapshotBuckets[level] or {}) do
                                if Id(entry.feat and entry.feat.Feat)==feat
                                    or Id(entry.replicatedFeat and entry.replicatedFeat.Feat)==feat then
                                    if found or Id(entry.feat and entry.feat.Feat)~=feat
                                        or Id(entry.replicatedFeat and entry.replicatedFeat.Feat)~=feat
                                        or Id(entry.meta and entry.meta.Source)~=Id(before.Class)
                                        or tonumber(entry.meta and entry.meta.Level)~=level
                                        or Id(entry.meta and entry.meta.Progression)==EMPTY
                                        or tostring(entry.meta.SpellSourceType or "")~="ProgressionClass"
                                        then return nil end
                                    found=entry
                                end
                            end
                            return found
                        end
                        local former=UniqueProgression(oldBuckets)
                        local now=UniqueProgression(newBuckets)
                        if not former or not now
                            or Id(former.meta.Progression)~=Id(now.meta.Progression)
                            or type(former.feat.AddSpells)~="table"
                            or type(now.feat.AddSpells)~="table"
                            or #former.feat.AddSpells~=#now.feat.AddSpells
                            or type(former.feat.AddPassives)~="table"
                            or type(now.feat.AddPassives)~="table"
                            or #former.feat.AddPassives~=#now.feat.AddPassives then
                            return false
                        end
                        for i,grant in ipairs(former.feat.AddSpells) do
                            if not SameGrant(grant,now.feat.AddSpells[i]) then return false end
                        end
                        for i,passive in ipairs(former.feat.AddPassives) do
                            if passive~=now.feat.AddPassives[i] then return false end
                        end
                        owners=owners+1
                    end
                end
            end
        end
    end
    return owners==1
end

-- A selected Class/SubClass passive may UnlockSpell(actions) even when the
-- resulting SpellBook ID says ProgressionClass/ProgressionSubClass, rather
-- than a passive source. Never attribute by names or SourceType alone.
-- Use the installed passive's exact UnlockSpell token AND the original CC
-- choice + original progression grant. Compare that very owner in the
-- staged history to decide if the grant was retained or removed. A removed
-- grant is not transplanted and is forbidden by the final live-spell audit.
local function SelectedPassiveActionDisposition(original,edited,sid,passiveCache)
    if type(sid)~="table" or Id(sid.Source)~=EMPTY then return nil end
    local sourceType=tostring(sid.SourceType or "")
    if sourceType~="ProgressionClass" and sourceType~="ProgressionSubClass" then return nil end
    local proto=tostring(sid.Prototype or "")
    if proto=="" or proto~=tostring(sid.OriginatorPrototype or "") then return nil end
    local owner=Id(sid.ProgressionSource)
    if owner==EMPTY then return nil end
    local oldCC=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newCC=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original and original.progressions and original.progressions.buckets
    local newBuckets=edited and edited.progressions and edited.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldCC) or not Dense(newCC) or #oldCC~=#newCC
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or not Dense(book) then return nil end
    local key=SpellKey(sid)
    local matchingBook,sameProto=0,0
    for _,row in ipairs(book) do
        local id=SpellId(row)
        if id and tostring(id.Prototype or "")==proto then
            sameProto=sameProto+1
            if SpellKey(id)==key then matchingBook=matchingBook+1 end
        end
    end
    if matchingBook~=1 or sameProto~=1 then return nil end
    local sourceKind=sourceType=="ProgressionClass" and "Class" or "SubClass"
    local candidates={}
    for level=2,#oldCC do
        local before,after=oldCC[level],newCC[level]
        if type(before)~="table" or type(after)~="table"
            or Id(before.Class)~=Id(after.Class)
            or Id(before.SubClass)~=Id(after.SubClass) then return nil end
        local rows=before.Upgrades and before.Upgrades.Passives or {}
        if not Dense(rows) then return nil end
        for _,row in ipairs(rows) do
            if row.Type==sourceKind and Id(row.Class)==owner then
                if tonumber(row.Level)~=level or not Dense(row.Passives) then return nil end
                for _,passive in ipairs(row.Passives) do
                    if type(passive)~="string" or passive=="" then return nil end
                    local memo=passive.."|"..proto
                    local unlock=passiveCache and passiveCache[memo]
                    if unlock==nil then
                        unlock=PassiveUnlocks({PassivesAdded={passive}},proto)
                        if passiveCache then passiveCache[memo]=unlock end
                    end
                    if unlock then
                        candidates[#candidates+1]={Level=level,Row=row,Passive=passive}
                    end
                end
            end
        end
    end
    -- An action that can be explained by multiple class/passive choices is
    -- not uniquely owned and cannot be adjudicated safely.
    if #candidates~=1 then return nil end
    local candidate=candidates[1]
    local level=candidate.Level
    local before,after=oldCC[level],newCC[level]
    local function ProgressionOwner(buckets)
        local result=nil
        if not Dense(buckets[level]) then return nil end
        for _,entry in ipairs(buckets[level]) do
            local meta=entry.meta
            if type(meta)=="table" and Id(meta.Source)==owner
                and tostring(meta.SpellSourceType or "")==sourceType then
                if result or tonumber(meta.Level)~=level
                    or Id(meta.Progression)==EMPTY then return nil end
                result=entry
            end
        end
        return result
    end
    local oldProg=ProgressionOwner(oldBuckets)
    local newProg=ProgressionOwner(newBuckets)
    if not oldProg or not newProg
        or Id(oldProg.meta.Progression)~=Id(newProg.meta.Progression)
        or tonumber(oldProg.meta.ClassLevel)~=tonumber(newProg.meta.ClassLevel)
        or not Dense(oldProg.passives and oldProg.passives.AddPassives)
        or not Dense(newProg.passives and newProg.passives.AddPassives) then return nil end
    local passive=candidate.Passive
    local function Occurrences(items,value)
        local n=0
        for _,x in ipairs(items) do if x==value then n=n+1 end end
        return n
    end
    if Occurrences(oldProg.passives.AddPassives,passive)~=1 then return nil end
    local row=candidate.Row
    local current=nil
    for _,other in ipairs(after.Upgrades and after.Upgrades.Passives or {}) do
        if other.Type==row.Type and Id(other.Class)==Id(row.Class)
            and tostring(other.SelectorId or "")==tostring(row.SelectorId or "")
            and Id(other.PassiveList)==Id(row.PassiveList)
            and tonumber(other.DefinitionIndex)==tonumber(row.DefinitionIndex)
            and tonumber(other.Level)==level then
            if current then return nil end
            current=other
        end
    end
    if not current or not Dense(current.Passives) then return nil end
    local chosen=Occurrences(current.Passives,passive)
    local granted=Occurrences(newProg.passives.AddPassives,passive)
    if chosen==1 and granted==1 then return "retained" end
    if chosen==0 and granted==0 then
        -- If another source now grants this action, removing the old grant
        -- without exact provenance could drop legitimate newly chosen skills.
        for i,up in ipairs(newCC) do
            for _,choice in ipairs(up.Upgrades and up.Upgrades.Passives or {}) do
                for _,item in ipairs(choice.Passives or {}) do
                    if item~=passive then
                        local memo=item.."|"..proto
                        local unlock=passiveCache and passiveCache[memo]
                        if unlock==nil then
                            unlock=PassiveUnlocks({PassivesAdded={item}},proto)
                            if passiveCache then passiveCache[memo]=unlock end
                        end
                        if unlock then return nil end
                    end
                end
            end
        end
        return "removed"
    end
    return nil
end

local function RemovedFeatGrantKeys(original,edited)
    local approved={}
    if type(original)~="table" then return approved end
    local oldUps=original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newUps=edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original.progressions and original.progressions.buckets
    local newBuckets=edited.progressions and edited.progressions.buckets
    local oldBook=original.components and original.components.spellBook
    if type(oldUps)~="table" or type(newUps)~="table"
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or type(oldBook)~="table" or type(oldBook.Spells)~="table"
        or #oldUps~=#newUps then return nil,"Cannot prove removed feat history" end
    for level=2,#oldUps do
        local before,after=oldUps[level],newUps[level]
        if type(before)~="table" or type(after)~="table" then
            return nil,"Incomplete historical feat owner"
        end
        local feat=tostring(before.Feat or "")
        if Id(feat)~=EMPTY and feat~=tostring(after.Feat or "") then
            local owner,ownerCount=nil,0
            for _,entry in ipairs(oldBuckets[level] or {}) do
                if type(entry)=="table" and type(entry.feat)=="table"
                    and tostring(entry.feat.Feat or "")==feat then
                    owner,ownerCount=entry,ownerCount+1
                end
            end
            if ownerCount~=1 or type(owner.meta)~="table"
                or tonumber(owner.meta.Level)~=level
                or Id(owner.meta.Source)==EMPTY
                or not ({ProgressionClass=true,ProgressionSubClass=true})[tostring(owner.meta.SpellSourceType or "")]
                or type(owner.replicatedFeat)~="table"
                or tostring(owner.replicatedFeat.Feat or "")~=feat
                or type(owner.feat.AddSpells)~="table" then
                return nil,"Removed feat's progression owner is ambiguous: "..feat
            end
            local direct=DirectFeatGrants(owner,before,level)
            if not direct or type(owner.spells and owner.spells.RemoveSpells or {})~="table"
                or #(owner.spells and owner.spells.RemoveSpells or {})~=0 then
                return nil,"Removed feat has unverified spell grants: "..feat
            end
            -- The spellbook-removal audit is necessary only if the removed
            -- feat actually has spell/action grants to discard. A simple
            -- feat such as Alert has no AddSpells and no matching feat-owned
            -- spellbook rows; requiring its StaticData definition here would
            -- wrongly reject ordinary feat -> action-feat replacements.
            -- A source-less Feat row is *potentially* owned by any feat from
            -- the same progression owner. Treat it as requiring proof rather
            -- than guessing that it is unrelated.
            local needsGrantAudit=next(direct)~=nil
            for _,bookRow in ipairs(oldBook.Spells) do
                local sid=SpellId(bookRow)
                if sid and tostring(sid.SourceType or "")=="Feat"
                    and Id(sid.ProgressionSource)==Id(owner.meta.Source)
                    and (Id(sid.Source)==Id(feat) or Id(sid.Source)==EMPTY) then
                    if not RetainedSelectedFeatSpell(original,edited,sid)
                        and FeatActionDisposition(original,edited,sid)~="retained" then
                        needsGrantAudit=true
                        break
                    end
                end
            end
            -- Every owner must disappear from edited progression, not just
            -- the feat ID in CC history. Repeat owners are unsupported.
            for i=1,#oldUps do
                if i~=level and tostring(oldUps[i].Feat or "")==feat then
                    return nil,"Repeated original feat ownership: "..feat
                end
                if tostring(newUps[i].Feat or "")==feat then
                    return nil,"Removed feat remains selected: "..feat
                end
                for _,entry in ipairs(newBuckets[i] or {}) do
                    if (entry.feat and tostring(entry.feat.Feat or "")==feat)
                        or (entry.replicatedFeat
                            and tostring(entry.replicatedFeat.Feat or "")==feat) then
                        return nil,"Removed feat still owns progression: "..feat
                    end
                end
            end
            if needsGrantAudit then
                local definition,lookupReason=FeatCatalogDefinition(feat)
                if not definition then
                    return nil,"Removed feat spell grants lack an installed source definition: "
                        ..feat.." ("..tostring(lookupReason or "unknown lookup failure")..")"
                end
                local selections={}
                for _,row in ipairs(before.Upgrades and before.Upgrades.Spells or {}) do
                    if tostring(row.Class or "")==feat then
                        if tostring(row.Type or "")~="Feat"
                            or type(row.Spells)~="table" then
                            return nil,"Invalid original feat spell selection: "..feat
                        end
                        for _,pick in ipairs(row.Spells) do
                            local id=type(pick)=="table" and pick.SpellId or pick
                            if type(id)~="string" or id=="" or selections[id] then
                                return nil,"Ambiguous original feat spell selection"
                            end
                            selections[id]=true
                        end
                    end
                end
                for id in pairs(selections) do
                    if not direct[id] then
                        return nil,"Original feat spell selector disagrees with progression: "..id
                    end
                end
                for _,row in ipairs(after.Upgrades and after.Upgrades.Spells or {}) do
                    if tostring(row.Class or "")==feat then
                        return nil,"Removed feat spell selector still present"
                    end
                end
                local countForGrant={}
                for _,row in ipairs(oldBook.Spells) do
                    local sid=SpellId(row)
                    if sid and tostring(sid.SourceType or "")=="Feat"
                        and Id(sid.ProgressionSource)==Id(owner.meta.Source)
                        and (Id(sid.Source)==Id(feat) or Id(sid.Source)==EMPTY) then
                        -- A separately retained feat's proven spell selection
                        -- is not an obsolete grant of the feat being removed.
                        if not RetainedSelectedFeatSpell(original,edited,sid)
                            and FeatActionDisposition(original,edited,sid)~="retained" then
                        local proto=tostring(sid.Prototype or "")
                        local explicit=Id(sid.Source)==Id(feat)
                        local proven=(explicit or Id(sid.Source)==EMPTY) and direct[proto]
                            or ((explicit or Id(sid.Source)==EMPTY)
                                and PassiveUnlocks(definition,proto))
                        if proven then
                            if proto=="" or tostring(sid.OriginatorPrototype or "")~=proto
                                or countForGrant[proto] then
                                return nil,"Ambiguous feat-owned spell grant: "..proto
                            end
                            countForGrant[proto]=true
                            local key=SpellKey(sid)
                            if not key or approved[key] then
                                return nil,"Duplicate feat-owned spell identity"
                            end
                            approved[key]=true
                        end
                        end -- not an unchanged, source-verified other feat spell
                    end
                end
                for proto in pairs(direct) do
                    if not countForGrant[proto] then
                        return nil,"Missing original feat-owned spell: "..proto
                    end
                end
                -- A removed grant reused by another surviving selector is not
                -- unambiguously obsolete; block instead of deleting it.
                for key in pairs(countForGrant) do
                    for i=1,#newUps do
                        for _,row in ipairs(newUps[i].Upgrades and newUps[i].Upgrades.Spells or {}) do
                            for _,item in ipairs(row.Spells or {}) do
                                if tostring(type(item)=="table" and item.SpellId or item)==key then
                                    return nil,"Removed feat spell is selected elsewhere: "..key
                                end
                            end
                        end
                        for _,entry in ipairs(newBuckets[i] or {}) do
                            for _,field in ipairs({"feat","replicatedFeat","spells"}) do
                                for _,grant in ipairs(entry[field] and entry[field].AddSpells or {}) do
                                    if tostring(grant.SpellId or "")==key then
                                        return nil,"Removed feat spell has a surviving progression grant: "..key
                                    end
                                end
                            end
                        end
                    end
                end
            end -- needsGrantAudit: ordinary no-spell source feats need no spell-removal definition
        end
    end
    return approved
end

-- A historical selected container spell can generate distinct book entries
-- for its child actions (e.g. Absorb Elements -> the elemental variants).
-- Treat removal of those children as authorized ONLY when the installed
-- parent spell explicitly lists each child and all original history owners
-- agree. This is not a spelling-prefix or SourceType-wide exemption.
local function RemovedHistoricalContainerKeys(original,edited)
    local approved={}
    local oldUps=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newUps=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original and original.progressions and original.progressions.buckets
    local newBuckets=edited and edited.progressions and edited.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldUps) or not Dense(newUps) or #oldUps~=#newUps
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or not Dense(book) then return nil,"Container-spell history unavailable" end
    local function HasSelected(ups,spell)
        local count=0
        for _,level in ipairs(ups) do
            for _,row in ipairs(level.Upgrades and level.Upgrades.Spells or {}) do
                for _,value in ipairs(row.Spells or {}) do
                    local id=type(value)=="table" and value.SpellId or value
                    if id==spell then count=count+1 end
                end
            end
        end
        return count
    end
    for level=2,#oldUps do
        local previous=(oldUps[level].Upgrades or {}).Spells or {}
        local current=(newUps[level].Upgrades or {}).Spells or {}
        for index,row in ipairs(previous) do
            local nextRow=current[index]
            local oldPicks=row.Spells or {}
            if #oldPicks==1 and nextRow and #(nextRow.Spells or {})==1
                and tostring(row.SelectorId or "")==tostring(nextRow.SelectorId or "")
                and tostring(row.SpellList or "")==tostring(nextRow.SpellList or "")
                and Id(row.Class)==Id(nextRow.Class)
                and Id(row.Subclass)==Id(nextRow.Subclass) then
                local root=type(oldPicks[1])=="table" and oldPicks[1].SpellId or oldPicks[1]
                local replacement=nextRow.Spells[1]
                replacement=type(replacement)=="table" and replacement.SpellId or replacement
                if type(root)=="string" and type(replacement)=="string"
                    and root~=replacement and HasSelected(oldUps,root)==1
                    and HasSelected(newUps,root)==0 then
                    -- Parent/child identity must come from an installed stat,
                    -- never from splitting or prefix-matching the spell IDs.
                    local stat=nil
                    if Ext and Ext.Stats and Ext.Stats.Get then
                        local ok,value=pcall(Ext.Stats.Get,root)
                        if ok then stat=value end
                    end
                    local children={}
                    local container=stat and stat.ContainerSpells
                    if type(container)=="string" then
                        for child in container:gmatch("[%w_]+") do children[child]=true end
                    end
                    -- Also allow the parent itself to be dropped, but only
                    -- when the container relationship is verified first.
                    if next(children) then
                        children[root]=true
                        local source=Id(row.Class)
                        local ownerCount=0
                        local oldBucket=oldBuckets[level]
                        for _,entry in ipairs(type(oldBucket)=="table" and oldBucket or {}) do
                            local meta=entry.meta
                            if type(meta)=="table" and Id(meta.Source)==source
                                and (meta.SpellSourceType=="ProgressionClass"
                                    or meta.SpellSourceType=="ProgressionSubClass") then
                                for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                                    if grant.SpellId==root then ownerCount=ownerCount+1 end
                                end
                            end
                        end
                        local nowOwned=false
                        for _,bucket in pairs(newBuckets) do
                            if type(bucket)=="table" then
                                for _,entry in ipairs(bucket) do
                                    for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                                        if grant.SpellId==root then nowOwned=true end
                                    end
                                end
                            end
                        end
                        if ownerCount==1 and not nowOwned then
                            for _,bookRow in ipairs(book) do
                                local sid=SpellId(bookRow)
                                local identity=sid and tostring(sid.OriginatorPrototype or sid.Prototype or "") or ""
                                if children[identity] and sid
                                    and Id(sid.Source)==EMPTY
                                    and Id(sid.ProgressionSource)==source
                                    and (sid.SourceType=="ProgressionSubClass"
                                        or sid.SourceType=="ProgressionClass") then
                                    local key=SpellKey(sid)
                                    local prepared=PreparedKey(sid)
                                    if key then approved[key]=true end
                                    if prepared then approved[prepared]=true end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return approved
end

-- Spellbook snapshots sometimes list cast-time upcast variants as separate
-- SpellIDs even though the level-up selection/passive grants only the root.
-- The trailing level number is NOT proof of ownership: a valid numbered action
-- may be a standalone grant. Require the installed SpellData RootSpellID and
-- higher Level, an independently recorded root in the untouched book, and no
-- explicit historical choice/progression grant for the child. The root itself
-- is always processed by the normal strict feat/class provenance checks.
local function RecordedIndependentSpell(snapshot,spell)
    local ups=snapshot and snapshot.components and snapshot.components.ccLevelUp
        and snapshot.components.ccLevelUp.LevelUps
    local buckets=snapshot and snapshot.progressions and snapshot.progressions.buckets
    if not Dense(ups) or type(buckets)~="table" then return true end
    for level,row in ipairs(ups) do
        local choices=row and row.Upgrades and row.Upgrades.Spells or {}
        if type(choices)~="table" or type(buckets[level])~="table" then return true end
        for _,selector in ipairs(choices) do
            for _,pick in ipairs(selector.Spells or {}) do
                local id=type(pick)=="table" and pick.SpellId or pick
                if id==spell then return true end
            end
        end
        for _,entry in ipairs(buckets[level]) do
            for _,field in ipairs({"spells","feat","replicatedFeat"}) do
                local grants=entry[field] and entry[field].AddSpells or {}
                if type(grants)~="table" then return true end
                for _,grant in ipairs(grants) do
                    if type(grant)=="table" and grant.SpellId==spell then
                        return true
                    end
                end
            end
        end
    end
    return false
end
-- In a historical respec, numeric spell variants are cast forms of their
-- roots, not additional historical selections. Work with the unsuffixed
-- selection; leave actual engine-owned upcast creation/destruction to BG3.
-- Unlike a broad suffix-only rule, this requires a real root or installed
-- RootSpellID and does not swallow explicitly recorded numbered grants.
-- A changed OriginatorPrototype on a *stale* variant is deliberately NOT a
-- blocker: the original recorded root and progression identity are authority.
local function AutoNumberedCastVariant(saved,original,book,spellSid)
    if type(spellSid)~="table" then return false end
    local proto=tostring(spellSid.Prototype or "")
    local root,rank=proto:match("^(.-)_([2-6])$")
    if not root or root=="" then return false end
    if RecordedIndependentSpell(saved,proto)
        or (original and RecordedIndependentSpell(original,proto)) then
        return false
    end
    -- A single historical root can have multiple casting ranks, but there
    -- must be a recorded root with the SAME grant source. Its cast variants
    -- can have stale OriginatorPrototype values after changing level choices.
    for _,entry in ipairs(book or {}) do
        local candidate=SpellId(entry)
        if candidate and tostring(candidate.Prototype or "")==root
            and tostring(candidate.SourceType or "")==tostring(spellSid.SourceType or "")
            and Id(candidate.ProgressionSource)==Id(spellSid.ProgressionSource)
            and Id(candidate.Source)==Id(spellSid.Source) then
            return true
        end
    end
    -- Also handle a root already removed from the staged book, when BG3's
    -- installed spell stats unambiguously identify its numeric cast variant.
    if Ext and Ext.Stats and type(Ext.Stats.Get)=="function" then
        local ok,stat=pcall(Ext.Stats.Get,proto)
        if ok and stat then
            local got,name=pcall(function() return stat.RootSpellID end)
            if got and name==root then return true end
        end
    end
    return false
end
local function KnownIgnoredNumbered(expected,spellSid)
    local key=SpellKey(spellSid)
    return key~=nil and (expected.hbIgnoredNumberedVariantKeys or {})[key]==true
end
local function IsNumberedCastName(name)
    return type(name)=="string" and name:match("^.+_[2-6]$")~=nil
end

local function VerifiedUpcastRoot(snapshot,originalBook,childSid)
    if type(childSid)~="table" then return nil end
    local child=tostring(childSid.Prototype or "")
    local suffix=child:match("_(%d+)$")
    local rank=tonumber(suffix)
    if not rank or rank<2 or rank>9 or not Ext or not Ext.Stats
        or type(Ext.Stats.Get)~="function" then return nil end
    local ok,childStat=pcall(Ext.Stats.Get,child)
    if not ok or not childStat then return nil end
    local okRoot,root=pcall(function() return childStat.RootSpellID end)
    if not okRoot or type(root)~="string" or root==""
        or child~=root.."_"..suffix then return nil end
    local priorOrigin=tostring(childSid.OriginatorPrototype or "")
    if priorOrigin~="" and priorOrigin~=root and priorOrigin~=child then return nil end
    local rootOk,rootStat=pcall(Ext.Stats.Get,root)
    if not rootOk or not rootStat then return nil end
    local okLevels,childLevel,rootLevel,childType,rootType=pcall(function()
        return tonumber(childStat.Level),tonumber(rootStat.Level),
            tostring(childStat.SpellType or ""),tostring(rootStat.SpellType or "")
    end)
    if not okLevels or not childLevel or not rootLevel or childType==""
        or childType~=rootType or childLevel~=rank or childLevel<=rootLevel then
        return nil
    end
    local rootRows=0
    for _,row in ipairs(originalBook or {}) do
        local sid=SpellId(row)
        if sid and tostring(sid.Prototype or "")==root then
            -- Do not equate unrelated spellbook sources for the same root.
            if Id(sid.Source)~=EMPTY and Id(childSid.Source)~=EMPTY
                and Id(sid.Source)~=Id(childSid.Source) then return nil end
            if Id(sid.ProgressionSource)~=EMPTY
                and Id(childSid.ProgressionSource)~=EMPTY
                and Id(sid.ProgressionSource)~=Id(childSid.ProgressionSource) then
                return nil
            end
            rootRows=rootRows+1
        end
    end
    if rootRows~=1 or RecordedIndependentSpell(snapshot,child) then return nil end
    return root
end


-- A spell container's selectable child action is not necessarily another
-- learned spell. The relationship must be proven against the installed
-- parent's exact ContainerSpells list, not a shared name, suffix or spell
-- SourceType. Never suppress an independently chosen/granted child.
local function VerifiedContainerChild(snapshot,originalBook,childSid)
    if type(childSid)~="table" or not Ext or not Ext.Stats
        or type(Ext.Stats.Get)~="function" then return nil end
    local child=tostring(childSid.Prototype or "")
    if child=="" or RecordedIndependentSpell(snapshot,child) then return nil end
    local ok,childStat=pcall(Ext.Stats.Get,child)
    if not ok or not childStat then return nil end
    local candidates,visited={},{}
    local function AddCandidate(value,origin)
        if type(value)=="string" and value~="" and value~=child and not visited[value] then
            visited[value]=true
            candidates[#candidates+1]={Name=value,Origin=origin}
        end
    end
    local okRoot,root=pcall(function() return childStat.RootSpellID end)
    if okRoot then AddCandidate(root,"installed-root") end
    local originator=tostring(childSid.OriginatorPrototype or "")
    if originator~=child then AddCandidate(originator,"spellbook-originator") end
    -- The name is used ONLY to locate a potential installed parent. The
    -- installed ContainerSpells field must independently include the child.
    AddCandidate(child:match("^(.*)_[^_]+$"),"candidate-name")
    for _,row in ipairs(originalBook or {}) do
        local sid=SpellId(row)
        if sid then AddCandidate(sid.Prototype,"recorded-book-parent") end
    end
    local ups=snapshot and snapshot.components and snapshot.components.ccLevelUp
        and snapshot.components.ccLevelUp.LevelUps or {}
    for _,up in ipairs(ups) do
        for _,selector in ipairs(up.Upgrades and up.Upgrades.Spells or {}) do
            for _,pick in ipairs(selector.Spells or {}) do
                AddCandidate(type(pick)=="table" and pick.SpellId or pick,"recorded-choice-parent")
            end
        end
    end
    for _,candidate in ipairs(candidates) do
        local okParent,stat=pcall(Ext.Stats.Get,candidate.Name)
        if okParent and stat then
            local okContents,contents=pcall(function() return stat.ContainerSpells end)
            if okContents and (type(contents)=="string" or type(contents)=="userdata") then
                local found=false
                for member in tostring(contents):gmatch("[%w_]+") do
                    if member==child then found=true;break end
                end
                if found then
                    -- An original spellbook row for the parent must have the
                    -- same provenance as the child; a similarly named action
                    -- from another class or feat is not a valid owner.
                    local hasParent,matchingParent=false,false
                    for _,row in ipairs(originalBook or {}) do
                        local sid=SpellId(row)
                        if sid and tostring(sid.Prototype or "")==candidate.Name then
                            hasParent=true
                            if tostring(sid.SourceType or "")==tostring(childSid.SourceType or "")
                                and Id(sid.ProgressionSource)==Id(childSid.ProgressionSource)
                                and Id(sid.Source)==Id(childSid.Source) then
                                matchingParent=true
                            end
                        end
                    end
                    if matchingParent then return candidate.Name end
                    if not hasParent then
                        -- A removed/replaced parent may no longer have its
                        -- own SpellBook entry. A stat-backed root or the exact
                        -- conventional child suffix is sufficient ONLY for
                        -- progression/feat actions without a direct historical
                        -- grant. Unattributed equipment/script spells stay strict.
                        local kind=tostring(childSid.SourceType or "")
                        if (candidate.Origin=="installed-root"
                            or candidate.Origin=="spellbook-originator"
                            or candidate.Origin=="candidate-name")
                            and (kind=="ProgressionClass" or kind=="ProgressionSubClass"
                                or kind=="Feat") then
                            return candidate.Name
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- A portable class-changing preset carries no donor SpellBook. Never classify
-- the receiver's obsolete higher-level casting as a missing NEW grant. Record
-- only displaced spell identities supported by the receiving character's
-- own exact CC choice AND matching class/subclass progression. All other
-- unknown ownership remains untouched and is never auto-regranted/removed.
local function VerifiedDisplacedPresetActions(original,edited)
    local result={}
    local oldCC=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local newCC=edited and edited.components and edited.components.ccLevelUp
        and edited.components.ccLevelUp.LevelUps
    local oldBuckets=original and original.progressions and original.progressions.buckets
    local newBuckets=edited and edited.progressions and edited.progressions.buckets
    local book=original and original.components and original.components.spellBook
        and original.components.spellBook.Spells
    if not Dense(oldCC) or not Dense(newCC) or #oldCC~=#newCC
        or type(oldBuckets)~="table" or type(newBuckets)~="table"
        or not Dense(book) then return nil,"Original build spell provenance is incomplete" end
    for level=1,#oldCC do
        if not Dense(oldBuckets[level]) or not Dense(newBuckets[level]) then
            return nil,"Cannot verify imported spell provenance at level "..level
        end
    end
    local function Evidence(cc,buckets,owner,kind,root,passive)
        local choices,grants=0,0
        for level=2,#cc do
            local row=cc[level]
            local spellSelections=row.Upgrades and row.Upgrades.Spells or {}
            local passiveSelections=row.Upgrades and row.Upgrades.Passives or {}
            local expectedType=kind=="ProgressionClass" and "Class" or "SubClass"
            local classFits=kind~="ProgressionClass" or Id(row.Class)==owner
            if classFits then
                for _,selector in ipairs(spellSelections) do
                    if tostring(selector.Type or "")==expectedType
                        and Id(selector.Class)==owner then
                        for _,pick in ipairs(selector.Spells or {}) do
                            local id=type(pick)=="table" and pick.SpellId or pick
                            if id==root then choices=choices+1 end
                        end
                    end
                end
                if passive then
                    for _,selector in ipairs(passiveSelections) do
                        if tostring(selector.Type or "")==expectedType
                            and Id(selector.Class)==owner then
                            for _,pick in ipairs(selector.Passives or {}) do
                                if pick==passive then choices=choices+1 end
                            end
                        end
                    end
                end
                for _,entry in ipairs(buckets[level]) do
                    local meta=entry.meta
                    if meta and Id(meta.Source)==owner
                        and tostring(meta.SpellSourceType or "")==kind then
                        for _,pick in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                            if pick.SpellId==root then grants=grants+1 end
                        end
                        if passive then
                            for _,pick in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                                if pick==passive then grants=grants+1 end
                            end
                        end
                    end
                end
            end
        end
        return choices,grants
    end
    -- If the target selects this root via any source (including a new class),
    -- it is NOT a universally removed spell and may not use the absence rule.
    local function TargetUses(root,passive)
        for level=1,#newCC do
            local row=newCC[level]
            for _,selection in ipairs(row.Upgrades and row.Upgrades.Spells or {}) do
                for _,pick in ipairs(selection.Spells or {}) do
                    if (type(pick)=="table" and pick.SpellId or pick)==root then return true end
                end
            end
            if passive then
                for _,selection in ipairs(row.Upgrades and row.Upgrades.Passives or {}) do
                    for _,pick in ipairs(selection.Passives or {}) do
                        if pick==passive then return true end
                    end
                end
            end
            for _,entry in ipairs(newBuckets[level]) do
                for _,pick in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                    if pick.SpellId==root then return true end
                end
                if passive then
                    for _,pick in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                        if pick==passive then return true end
                    end
                end
            end
        end
        return false
    end
    for _,row in ipairs(book) do
        local sid=SpellId(row)
        local key=SpellKey(sid)
        local kind=sid and tostring(sid.SourceType or "") or ""
        local owner=sid and Id(sid.ProgressionSource) or EMPTY
        local root=sid and tostring(sid.OriginatorPrototype or "") or ""
        local proto=sid and tostring(sid.Prototype or "") or ""
        if key and owner~=EMPTY and Id(sid.Source)==EMPTY
            and (kind=="ProgressionClass" or kind=="ProgressionSubClass")
            and root~="" and (proto==root
                or proto:match("^"..root:gsub("([^%w])","%%%1").."_[2-6]$")~=nil) then
            local passive=root:match("^[%w]+_(.+)$")
            local oldChoices,oldGrants=Evidence(oldCC,oldBuckets,owner,kind,root,passive)
            local nowChoices,nowGrants=Evidence(newCC,newBuckets,owner,kind,root,passive)
            if oldChoices>0 and nowChoices==0 and nowGrants==0
                and not TargetUses(root,passive) then
                -- An originally selected grant with incomplete or duplicated
                -- progression provenance must not quietly lose its audit.
                if oldChoices~=1 or oldGrants~=1 then
                    return nil,"Ambiguous displaced build action ownership: "..proto
                end
                result[key]=proto
            end
        end
    end
    return result
end

function Bridge.MergeSpellBook(saved,native,merged,original)
    local oldBook=saved.components.spellBook
    local firstBook=native.components.spellBook
    if type(oldBook)~="table" or type(oldBook.Spells)~="table"
        or type(firstBook)~="table" or type(firstBook.Spells)~="table"
        or not Dense(oldBook.Spells) or not Dense(firstBook.Spells) then
        return nil,"Cannot safely merge native and saved spellbooks"
    end
    local one,why=SourcesForLevel(saved,1,1)
    if not one then return nil,why end
    local later,reason=SourcesForLevel(saved,2,#saved.components.ccLevelUp.LevelUps)
    if not later then return nil,reason end
    local released,releaseReason=RemovedFeatGrantKeys(original,saved)
    if not released then return nil,releaseReason end
    local retainedFeatActions,removedPassiveActions={},{}
    -- These records are engine-owned. Never import an old serialized Feat
    -- casting entry or assume that RemoveSpell is safe for an UnlockSpell.
    for _,row in ipairs(original and original.components and original.components.spellBook
            and original.components.spellBook.Spells or {}) do
        local sid=SpellId(row)
        if sid and tostring(sid.SourceType or "")=="Feat" then
            local disposition=FeatActionDisposition(original,saved,sid)
            local key=SpellKey(sid)
            if disposition=="removed" and key then
                released[key]=true
                removedPassiveActions[key]=tostring(sid.Prototype)
            elseif disposition=="retained" and key then
                retainedFeatActions[key]=true
            elseif key and (RetainedSelectedFeatSpell(original,saved,sid)
                or RetainedAutomaticFeatAction(original,saved,sid)) then
                -- Retained automatic feat actions and selected feat spells
                -- remain engine-owned and must reappear with exact grant IDs.
                retainedFeatActions[key]=true
            end
        end
    end
    local removedClassPassiveKeys={}
    local actionDispositionCache,passiveStatCache={},{}
    local function ClassPassiveDisposition(id)
        local key=SpellKey(id)
        if not key then return nil end
        if actionDispositionCache[key]==nil then
            actionDispositionCache[key]=SelectedPassiveActionDisposition(
                original,saved,id,passiveStatCache) or false
        end
        local result=actionDispositionCache[key]
        return result~=false and result or nil
    end
    for _,row in ipairs(oldBook.Spells) do
        local id=SpellId(row)
        local key=SpellKey(id)
        if key and ClassPassiveDisposition(id)=="removed" then
            removedClassPassiveKeys[key]=tostring(id.Prototype or "")
        end
    end
    local containerReleased,containerReason=RemovedHistoricalContainerKeys(original,saved)
    if not containerReleased then return nil,containerReason end
    for key in pairs(containerReleased) do released[key]=true end
    -- Same-class build imports also replace recorded spell choices. The
    -- receiver's old SpellBook is NOT the imported selection inventory: a
    -- spell selected in the old build must not be reimported after its
    -- exact historical choice and grant have been replaced by the preset.
    -- Use the same unique-selection/progression proof as class-changing
    -- imports; do not infer displacement merely from a matching spell name.
    local buildDisplaced={}
    if type(saved.hbBuildPresetImport)=="table"
        and saved.hbBuildPresetImport.ClassChange~=true then
        local displaced,why=VerifiedDisplacedPresetActions(original,saved)
        if not displaced then return nil,why end
        buildDisplaced=displaced
        for _,row in ipairs(firstBook.Spells) do
            local key=SpellKey(SpellId(row))
            if key and buildDisplaced[key] then
                return nil,"Replaced preset spell survived native level one: "
                    ..tostring(row.Id and row.Id.Prototype or "?")
            end
        end
    end
    if type(saved.hbBuildPresetImport)=="table"
        and saved.hbBuildPresetImport.ClassChange==true then
        -- The receiver's saved SpellBook belongs to its OLD class levels.
        -- Unlike an ordinary Selective Respec, the portable preset provides
        -- new progression/CC data but no donor casting or prepared entries.
        -- Keep BG3's native-first-level book, let the new class progressions
        -- supply their own actions, and audit the actual resulting owners.
        -- Never import obsolete actions under their former Fighter/etc owner.
        local receiving=original and original.components and original.components.spellBook
            and original.components.spellBook.Spells
        if not Dense(receiving) or #receiving~=#oldBook.Spells then
            return nil,"Portable build source spellbook differs from the receiver"
        end
        local formerKeys={}
        for i,row in ipairs(receiving) do
            local key=SpellKey(SpellId(row))
            if not key or formerKeys[key] then
                return nil,"Original build has ambiguous spell identities"
            end
            formerKeys[key]=true
            if key~=SpellKey(SpellId(oldBook.Spells[i])) then
                return nil,"Portable build attempted to import a foreign spellbook"
            end
        end
        local displaced,why=VerifiedDisplacedPresetActions(original,saved)
        if not displaced then return nil,why end
        local firstPrepares=native.components and native.components.spellBookPrepares
        if type(firstPrepares)~="table" or not Dense(firstPrepares.PreparedSpells or {}) then
            return nil,"Native first-level spell preparation is unavailable"
        end
        local nativeKeys={}
        for _,row in ipairs(firstBook.Spells) do
            local key=SpellKey(SpellId(row))
            if not key or nativeKeys[key] then
                return nil,"Native first-level SpellBook has unsupported duplicate IDs"
            end
            nativeKeys[key]=true
            if displaced[key] or released[key] then
                return nil,"Obsolete higher-level grant survived native respec: "
                    ..tostring(row.Id and row.Id.Prototype or "?")
            end
        end
        local nativePrepared={}
        for _,row in ipairs(firstPrepares.PreparedSpells or {}) do
            local key=PreparedKey(row)
            if not key or nativePrepared[key] then
                return nil,"Native first-level preparation has ambiguous IDs"
            end
            nativePrepared[key]=true
            if displaced[key] or released[key] then
                return nil,"Obsolete higher-level spell remains natively prepared"
            end
        end
        merged.components.spellBook=Copy(firstBook)
        merged.components.spellBookPrepares=Copy(firstPrepares)
        merged.components.learnedSpells=Copy(native.components.learnedSpells)
        merged.hbRemovedFeatSpellKeys=released
        merged.hbRetainedFeatActionKeys=retainedFeatActions
        merged.hbPassiveOwnedRemovedSpellKeys=removedPassiveActions
    merged.hbRemovedClassPassiveActionKeys=removedClassPassiveKeys
        merged.hbRemovedHistoricalContainerKeys=containerReleased
        merged.hbBuildDisplacedClassSpellKeys=displaced
        return {AddedHigherLevelSpells=0,DiscardedOldLevelOneSpells=0,
            DiscardedRemovedFeatSpells=0,DiscardedDerivedUpcasts=0,
            DiscardedDerivedContainerSpells=0,IgnoredAutomaticNumberedCasts=0}
    end
    -- A vanilla level-one respec may temporarily materialize automatic
    -- class/subclass actions that do not exist in the saved character's
    -- original spellbook. The engine can discard these when all later levels
    -- are restored. Such *native-only* entries are not original grants and
    -- must not cause a false post-replay failure, but explicit choices and
    -- original grants must still survive. Keep the proof with the merged
    -- snapshot, rather than applying a name-based exception in Audit().
    local transientNativeAutoKeys={}
    local originalSpellbook=original and original.components
        and original.components.spellBook
        and original.components.spellBook.Spells
    local originalUp=original and UpOne(original)
    local committedUp=UpOne(native)
    local firstOwner=original and Bridge.FirstClass(original)
    local function SelectedIds(up)
        local ids={}
        for _,field in ipairs({"Spells","Passives"}) do
            for _,row in ipairs(up and up.Upgrades and up.Upgrades[field] or {}) do
                for _,id in ipairs(row[field] or {}) do
                    local name=type(id)=="table" and (id.SpellId or id.PassiveId) or id
                    name=tostring(name or "")
                    if name~="" then ids[name]=(ids[name] or 0)+1 end
                end
            end
        end
        return ids
    end
    local function SameSelectedIds(a,b)
        local old,new=SelectedIds(a),SelectedIds(b)
        for id,count in pairs(old) do if new[id]~=count then return false end end
        for id,count in pairs(new) do if old[id]~=count then return false end end
        return true
    end
    local function WasHistoricalSpellChoice(proto)
        if not original or not original.components or not original.components.ccLevelUp
            then return true end
        for _,level in ipairs(original.components.ccLevelUp.LevelUps or {}) do
            for _,choice in ipairs(level.Upgrades and level.Upgrades.Spells or {}) do
                for _,id in ipairs(choice.Spells or {}) do
                    local chosen=tostring(type(id)=="table" and id.SpellId or id)
                    if chosen==proto or proto:sub(1,#chosen+1)==chosen.."_" then
                        return true
                    end
                end
            end
        end
        return false
    end
    if type(originalSpellbook)=="table" and firstOwner
        and type(originalUp)=="table" and type(committedUp)=="table"
        and SameSelectedIds(originalUp,committedUp) then
        local recorded={}
        for _,row in ipairs(originalSpellbook) do
            local key=SpellKey(SpellId(row))
            if key then recorded[key]=true end
        end
        -- Also include staged historical spells. A formerly selected grant
        -- must not be misidentified as an automatic native-only action.
        for _,row in ipairs(oldBook.Spells) do
            local key=SpellKey(SpellId(row))
            if key then recorded[key]=true end
        end
        for _,row in ipairs(firstBook.Spells) do
            local sid=SpellId(row)
            local key=SpellKey(sid)
            if key and not recorded[key] then
                local proto=tostring(sid.Prototype or "")
                local owner=Id(sid.ProgressionSource)
                local kind=tostring(sid.SourceType or "")
                local confirmed=(kind=="ProgressionClass" and owner==firstOwner.Class)
                    or (kind=="ProgressionSubClass" and owner~=EMPTY
                        and owner==firstOwner.SubClass)
                if confirmed and Id(sid.Source)==EMPTY and proto~=""
                    and tostring(sid.OriginatorPrototype or "")==proto
                    and not WasHistoricalSpellChoice(proto) then
                    transientNativeAutoKeys[key]=true
                end
            end
        end
    end
    merged.hbNativeTransientAutoGrantKeys=transientNativeAutoKeys
    -- Level-one spell ownership is a historical ROOT selection, not a
    -- particular cast rank. The vanilla native first level owns that root;
    -- after later levels are applied BG3 can normalize its SpellBook row to
    -- another casting form. Preserve only SOURCE-VERIFIED root ownership here.
    -- This map stores no ranked IDs and authorizes no spellbook writes.
    local nativeFirstLevelRootKeys={}
    if original and firstOwner and type(originalUp)=="table"
        and type(committedUp)=="table" and SameSelectedIds(originalUp,committedUp) then
        local oldBuckets=original.progressions and original.progressions.buckets
        local newBuckets=native.progressions and native.progressions.buckets
        local oldFirst=oldBuckets and oldBuckets[1]
        local newFirst=newBuckets and newBuckets[1]
        local function FirstProgressionGrants(bucket,owner,kind,root)
            if not Dense(bucket) then return 0 end
            local count=0
            for _,entry in ipairs(bucket) do
                local meta=entry.meta
                if type(meta)=="table" and Id(meta.Source)==owner
                    and tostring(meta.SpellSourceType or "")==kind then
                    for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                        if grant.SpellId==root then count=count+1 end
                    end
                end
            end
            return count
        end
        local function FirstSelectedRoot(up,owner,kind,root)
            local count=0
            for _,sel in ipairs(up.Upgrades and up.Upgrades.Spells or {}) do
                local selectKind=tostring(sel.Type or "")
                local grantKind=(selectKind=="Class" and "ProgressionClass")
                    or (selectKind=="SubClass" and "ProgressionSubClass") or ""
                for _,pick in ipairs(sel.Spells or {}) do
                    local choice=type(pick)=="table" and pick.SpellId or pick
                    if choice==root and grantKind==kind and Id(sel.Class)==owner then
                        count=count+1
                    end
                end
            end
            return count
        end
        local nativeCounts={}
        for _,row in ipairs(firstBook.Spells) do
            local sid=SpellId(row)
            local key=SpellKey(sid)
            if key then nativeCounts[key]=(nativeCounts[key] or 0)+1 end
        end
        for _,row in ipairs(firstBook.Spells) do
            local sid=SpellId(row)
            local key=SpellKey(sid)
            local root=sid and tostring(sid.Prototype or "") or ""
            local kind=sid and tostring(sid.SourceType or "") or ""
            local owner=sid and Id(sid.ProgressionSource) or EMPTY
            if key and nativeCounts[key]==1 and root~=""
                and ((kind=="ProgressionClass" and owner==firstOwner.Class)
                    or (kind=="ProgressionSubClass" and owner==firstOwner.SubClass
                        and owner~=EMPTY))
                and Id(sid.Source)==EMPTY
                and tostring(sid.OriginatorPrototype or "")==root
                and FirstSelectedRoot(originalUp,owner,kind,root)==1
                and FirstSelectedRoot(committedUp,owner,kind,root)==1
                and FirstProgressionGrants(oldFirst,owner,kind,root)==1
                and FirstProgressionGrants(newFirst,owner,kind,root)==1 then
                nativeFirstLevelRootKeys[key]=true
            end
        end
    end
    merged.hbNativeFirstLevelRootKeys=nativeFirstLevelRootKeys
    -- A derived cast is not a separate historical CHOICE, but it may still
    -- be a live executable SpellBook entry. The previous merge DROPPED all
    -- confirmed children/upcasts, even when their ROOT remained learned;
    -- consequently a spell could appear as a hotbar action without a live
    -- cast-variant entry. This is unsafe (and can invalidate UI shortcuts).
    -- Keep stat-verified derived entries only while an exactly owned parent
    -- exists in the final restored book. A child of a REMOVED parent stays
    -- absent. Never treat these as independent selectable grants.
    local derivedParentByKey,derivedKindByKey={},{}
    local ignoredNumberedKeys={}
    local originalSourceBook=(original and original.components
        and original.components.spellBook and original.components.spellBook.Spells)
        or oldBook.Spells
    for _,row in ipairs(oldBook.Spells) do
        local sid=SpellId(row)
        local key=SpellKey(sid)
        if key then
            local proto=tostring(sid.Prototype or "")
            if AutoNumberedCastVariant(saved,original,originalSourceBook,sid) then
                ignoredNumberedKeys[key]=true
            elseif not RecordedIndependentSpell(saved,proto) then
                local parent=VerifiedContainerChild(original or saved,oldBook.Spells,sid)
                if parent then
                    derivedParentByKey[key]=parent
                    derivedKindByKey[key]="container"
                else
                    parent=VerifiedUpcastRoot(original or saved,oldBook.Spells,sid)
                    if parent then
                        derivedParentByKey[key]=parent
                        derivedKindByKey[key]="upcast"
                    end
                end
            end
        end
    end
    local derivedContainerKeys,derivedUpcastKeys={},{}
    local retainedDerivedParents={}
    local deferredDerived={}
    local out=Copy(firstBook)
    local seen={};local nativeKeys={}
    for _,row in ipairs(out.Spells) do
        local key=SpellKey(SpellId(row))
        if not key or seen[key] then return nil,"Native first-level SpellBook has unsupported duplicate IDs" end
        seen[key]=true;nativeKeys[key]=true
        local id=SpellId(row)
        if AutoNumberedCastVariant(saved,original,originalSourceBook,id) then
            ignoredNumberedKeys[key]=true
        end
    end
    for key in pairs(released) do
        if nativeKeys[key] and not ignoredNumberedKeys[key] then
            return nil,"Removed feat spell remains on native level one"
        end
    end
    for key in pairs(removedClassPassiveKeys) do
        if nativeKeys[key] then return nil,"Removed selected-passive action remains on native level one" end
    end
    local added,removed,removedFeats,derived,containers=0,0,0,0,0
    local ignoredUpcasts=0
    for _,row in ipairs(oldBook.Spells) do
        local sid=SpellId(row);local key=SpellKey(sid)
        if not key then return nil,"Saved SpellBook has incomplete spell identity" end
        if ignoredNumberedKeys[key] then
            -- Never import old upcast identities into native SpellBook, and
            -- never adjudicate their saved origin/owner as an independent
            -- selection. Native BG3 manages the cast variants of roots.
            ignoredUpcasts=ignoredUpcasts+1
        elseif not seen[key] then
            if released[key] then
                removedFeats=removedFeats+1
            elseif removedClassPassiveKeys[key] then
                -- The original class passive was explicitly replaced in the
                -- target progression. Do not transplant its obsolete action.
                removed=removed+1
            elseif buildDisplaced[key] then
                -- A portable preset replaced the original exact class spell
                -- choice. Neither restore nor retain its old casting grant.
                removed=removed+1
            elseif retainedFeatActions[key] then
                -- The original feat remains; BG3 will regrant its action or
                -- directly selected feat spell. Audit requires the exact ID.
            elseif derivedParentByKey[key] then
                -- Do not decide a child's fate until independent ROOT grants
                -- have been merged and validated. The old blanket omission
                -- removed valid cast variants of unrelated retained spells.
                deferredDerived[#deferredDerived+1]={Row=row,Key=key,
                    Parent=derivedParentByKey[key],Kind=derivedKindByKey[key]}
            else
            local src=tostring(sid.SourceType or "")
            if src=="ProgressionClass" or src=="ProgressionSubClass" then
                local proto=tostring(sid.Prototype or sid.OriginatorPrototype)
                local isOne=Recognized(proto,one)
                local isLater=Recognized(proto,later)
                if isOne and not isLater then
                    -- Native BG3 already handled this old level-one grant.
                    removed=removed+1
                elseif isLater and not isOne then
                    out.Spells[#out.Spells+1]=Copy(row);seen[key]=true;added=added+1
                elseif not isOne and (AuditedLaterGrant(saved,sid)
                    or AuditedSorcererLaterConversion(saved,sid)
                    or AuditedClassSubclassLaterGrant(saved,original,sid)
                    or VerifiedWizardCounterspellAlias(saved,original,sid)
                    or ClassPassiveDisposition(sid)=="retained") then
                    -- Exact source-backed class action: never override native L1.
                    out.Spells[#out.Spells+1]=Copy(row);seen[key]=true;added=added+1
                else
                    return nil,"Unknown or overlapping spell ownership: "..proto
                        .." [origin="..tostring(sid.OriginatorPrototype or "")
                        .."; type="..src
                        .."; owner="..tostring(sid.ProgressionSource or "")
                        .."; L1="..tostring(isOne)
                        .."; higher="..tostring(isLater).."]"
                end
            else
                -- Boost/SpellSet/etc can be granted by levels, equipment,
                -- feats or scripts; their attribution is not proven here.
                -- The vanilla first level is authoritative for them.
                return nil,"Unverified non-progression spell would be overwritten: "
                    ..tostring(sid.Prototype or sid.OriginatorPrototype)
            end
            end
        end
    end
    -- A child only survives if its parent survives in the merged book with
    -- the very same grant provenance (never another class/feat's lookalike).
    -- This pass is intentionally AFTER independently owned roots are added.
    local survivingParentRows={}
    for _,row in ipairs(out.Spells) do
        local sid=SpellId(row)
        local name=sid and tostring(sid.Prototype or "") or ""
        if name~="" then
            survivingParentRows[name]=survivingParentRows[name] or {}
            survivingParentRows[name][#survivingParentRows[name]+1]=sid
        end
    end
    for _,pending in ipairs(deferredDerived) do
        local sid=SpellId(pending.Row)
        local siblings=survivingParentRows[pending.Parent] or {}
        local matching=0
        for _,rootSid in ipairs(siblings) do
            if Id(rootSid.ProgressionSource)==Id(sid.ProgressionSource)
                and Id(rootSid.Source)==Id(sid.Source)
                and tostring(rootSid.SourceType or "")==tostring(sid.SourceType or "") then
                matching=matching+1
            end
        end
        if matching>1 then
            return nil,"Ambiguous retained spell parent: "..pending.Parent
        elseif matching==1 then
            -- Parent remains a real live grant. Keep its originally owned
            -- child in the cast inventory, not a different/obsolete source.
            if seen[pending.Key] then
                return nil,"Repeated derived spell identity: "..pending.Key
            end
            out.Spells[#out.Spells+1]=Copy(pending.Row)
            seen[pending.Key]=true
            retainedDerivedParents[pending.Key]=pending.Parent
            added=added+1
        else
            -- Parent was removed with the feat/selection. Only these exact
            -- proven derived identities may be absent during final auditing.
            if pending.Kind=="container" then
                derivedContainerKeys[pending.Key]=true
                containers=containers+1
            else
                derivedUpcastKeys[pending.Key]=true
                derived=derived+1
            end
        end
    end
    merged.hbVerifiedDerivedContainerKeys=derivedContainerKeys
    merged.hbVerifiedDerivedUpcastKeys=derivedUpcastKeys
    merged.hbIgnoredNumberedVariantKeys=ignoredNumberedKeys
    -- Audit must require a retained derived cast to exist. This map is also
    -- available to the strictly provenance-gated recovery path if BG3 itself
    -- normalizes the derived variants later.
    merged.hbRetainedDerivedParents=retainedDerivedParents
    merged.components.spellBook=out
    -- Retain a read-only audit inventory; these exact feat-owned IDs must
    -- not reappear after restoring the saved higher-level progression.
    merged.hbRemovedFeatSpellKeys=released
    merged.hbRetainedFeatActionKeys=retainedFeatActions
    merged.hbPassiveOwnedRemovedSpellKeys=removedPassiveActions
    merged.hbRemovedClassPassiveActionKeys=removedClassPassiveKeys
    merged.hbRemovedHistoricalContainerKeys=containerReleased
    merged.hbBuildDisplacedClassSpellKeys=buildDisplaced
    local nativePrepares=native.components.spellBookPrepares
    local oldPrepares=saved.components.spellBookPrepares
    if type(nativePrepares)~="table" or type(oldPrepares)~="table"
        or not Dense(nativePrepares.PreparedSpells or {})
        or not Dense(oldPrepares.PreparedSpells or {}) then
        return nil,"Native spell preparation metadata is unavailable"
    end
    local prepared=Copy(nativePrepares)
    if prepared.PreparedSpells==nil then prepared.PreparedSpells={} end
    local present={}
    for _,r in ipairs(prepared.PreparedSpells or {}) do
        local key=PreparedKey(r)
        if not key then return nil,"Unrecognized native prepared spell" end
        if released[key] and not IsNumberedCastName(tostring(r.Prototype or r.OriginatorPrototype or "")) then
            return nil,"Removed feat spell remains prepared on native level one"
        end
        if removedClassPassiveKeys[key] then
            return nil,"Removed selected-passive action remains natively prepared"
        end
        present[key]=true
    end
    for _,r in ipairs(oldPrepares.PreparedSpells or {}) do
        local key=PreparedKey(r)
        if not key then return nil,"Unrecognized saved prepared spell" end
        local rProto=tostring(r.Prototype or r.OriginatorPrototype or "")
        if not IsNumberedCastName(rProto) and not present[key] and seen[key] then
            prepared.PreparedSpells[#prepared.PreparedSpells+1]=Copy(r)
            present[key]=true
        end
    end
    -- Higher-level spell capacity belongs to the original build (same
    -- starting class). The native level-one prepared spell choices survive.
    for _,key in ipairs({"ClassFallbackPreparedSpellCount","ClassPreparedSpellCount"}) do
        if oldPrepares[key] then prepared[key]=Copy(oldPrepares[key]) end
    end
    merged.components.spellBookPrepares=prepared
    merged.components.learnedSpells=Copy(native.components.learnedSpells)
    return {AddedHigherLevelSpells=added,DiscardedOldLevelOneSpells=removed,
        DiscardedRemovedFeatSpells=removedFeats,DiscardedDerivedUpcasts=derived,
        DiscardedDerivedContainerSpells=containers,
        IgnoredAutomaticNumberedCasts=ignoredUpcasts}
end
-- One verified L1 subclass spell displacement and one manually selected
-- higher-level replacement from the original same-list selector. No auto swap;
-- arbitrary targets are accepted only after checking recorded provenance.
function Bridge.PreflightInverseSpellSwap(original,swap,edits)
    if type(swap)~="table" or type(swap.From)~="string"
        or type(swap.To)~="string" or swap.From==swap.To
        or swap.From=="" or swap.To==""
        or type(swap.Replacement)~="string" or swap.Replacement==""
        or swap.Replacement==swap.To then
        return false,"Missing or invalid native spell identity"
    end
    if type(edits)~="table" then return false,"Missing higher-level choices" end
    local single=nil
    for _,edit in ipairs(edits) do
        if edit.Kind=="Spell" or edit.Kind=="Cantrip" then
            if single then return false,"Multiple simultaneous spell edits are not ownership-proven" end
            if edit.Kind~="Spell" or tonumber(edit.Level)==1
                or edit.From~=swap.To or edit.To~=swap.Replacement then
                return false,"The displaced spell's replacement does not match the recorded edit"
            end
            single=edit
        end
    end
    if not single then return false,"Fill the displaced higher-level spell before Confirm" end
    if #edits~=1 then
        return false,"Separate this first-level spell exchange from other historical edits"
    end
    local ups=original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps
    local buckets=original and original.progressions and original.progressions.buckets
    local level=tonumber(single.Level)
    if type(ups)~="table" or type(buckets)~="table" or not level
        or level<2 or level>#ups then return false,"Original level history missing" end
    local function SelectorsAt(index,id)
        local found={}
        local row=ups[index]
        for _,sel in ipairs(row and row.Upgrades and row.Upgrades.Spells or {}) do
            for _,spell in ipairs(sel.Spells or {}) do
                if tostring(type(spell)=="table" and spell.SpellId or spell)==id then
                    found[#found+1]=sel
                end
            end
        end
        return found
    end
    local old=SelectorsAt(1,swap.From)
    local later=SelectorsAt(level,swap.To)
    if #old~=1 or #later~=1 then return false,"Spell selector ownership is not unique" end
    local a,b=old[1],later[1]
    if a.Type~="SubClass" or b.Type~="SubClass"
        or a.Class~=b.Class or a.Class~=ups[1].SubClass
        or a.SpellList~=b.SpellList or a.SelectorId~="Spells"
        or b.SelectorId~="Spells" or #a.Spells~=1 or #b.Spells~=1 then
        return false,"Recorded spell selectors are not the same verified subclass list"
    end
    local function GrantCount(index,id)
        local count=0
        for _,entry in ipairs(buckets[index] or {}) do
            for _,spell in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                if tostring(spell.SpellId or spell.SpellID)==id then
                    local meta=entry.meta
                    if not meta or tonumber(meta.Level)~=index
                        or meta.Source~=a.Class or meta.SpellSourceType~="ProgressionSubClass" then
                        return -999
                    end
                    count=count+1
                end
            end
        end
        return count
    end
    if GrantCount(1,swap.From)~=1 or GrantCount(level,swap.To)~=1 then
        return false,"Spell grants do not have unique same-level progression ownership"
    end
    for index,entries in ipairs(buckets) do
        for _,entry in ipairs(entries) do
            for _,spell in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                local id=tostring(spell.SpellId or spell.SpellID or "")
                if (id==swap.From or id==swap.To)
                    and not ((index==1 and id==swap.From)
                        or (index==level and id==swap.To)) then
                    return false,"The original spell has an additional progression owner"
                end
            end
        end
    end
    for i=1,#ups do
        local row=ups[i]
        for _,sel in ipairs(row.Upgrades and row.Upgrades.Spells or {}) do
            for _,spell in ipairs(sel.Spells or {}) do
                local id=tostring(type(spell)=="table" and spell.SpellId or spell)
                if (id==swap.From or id==swap.To)
                    and not ((i==1 and sel==a) or (i==level and sel==b)) then
                    return false,"Spell occurs in another recorded selector"
                end
            end
        end
    end
    -- Do not reassign a spell that already has a recorded owner (including
    -- original first level), unless it is precisely the one being removed.
    -- The final patched history is also rechecked after validation.
    if swap.Replacement~=swap.From then
        for i=1,#ups do
            for _,sel in ipairs(ups[i].Upgrades and ups[i].Upgrades.Spells or {}) do
                for _,s in ipairs(sel.Spells or {}) do
                    if tostring(type(s)=="table" and s.SpellId or s)==swap.Replacement then
                        return false,"Replacement already has an original spell selector owner"
                    end
                end
            end
        end
    end
    return true,nil
end

local function VerifyNativeInverseSpell(original,native,swap)
    local before=UpOne(original);local now=UpOne(native)
    local count,owner=0,nil
    for _,sel in ipairs(now and now.Upgrades and now.Upgrades.Spells or {}) do
        if sel.Type=="SubClass" and sel.SelectorId=="Spells" then
            for _,id in ipairs(sel.Spells or {}) do
                if id==swap.To then count=count+1;owner=sel end
                if id==swap.From then return false,"Old spell remains selected natively" end
            end
        end
    end
    if count~=1 or not owner or owner.Class~=before.SubClass then
        return false,"Committed native level one does not match verified spell identity"
    end
    for _,sel in ipairs(before.Upgrades and before.Upgrades.Spells or {}) do
        if sel.SelectorId=="Spells" and sel.Type=="SubClass" then
            if owner.SpellList~=sel.SpellList or owner.DefinitionIndex~=sel.DefinitionIndex then
                return false,"Native spell selection list or definition changed"
            end
        end
    end
    return true,nil
end

-- Spellbook identity does not include acquisition level. Therefore classify
-- each *original* record against its original L1/L2 progression BEFORE
-- rewriting the higher spell, never replace matching IDs globally.
function Bridge.MergeInverseSpellBook(original,edited,native,merged,swap)
    local oldBook=original.components and original.components.spellBook
    local newBook=native.components and native.components.spellBook
    local oldPrepares=original.components and original.components.spellBookPrepares
    local newPrepares=native.components and native.components.spellBookPrepares
    if not oldBook or not newBook or not Dense(oldBook.Spells) or not Dense(newBook.Spells)
        or not oldPrepares or not newPrepares
        or not Dense(oldPrepares.PreparedSpells or {})
        or not Dense(newPrepares.PreparedSpells or {}) then
        return nil,"Recorded spellbook or prepared metadata is unavailable"
    end
    local one=SourcesForLevel(original,1,1)
    local later=SourcesForLevel(original,2,#original.components.ccLevelUp.LevelUps)
    local newLater=SourcesForLevel(edited,2,#edited.components.ccLevelUp.LevelUps)
    if not one or not later or not newLater or not newLater.Direct[swap.Replacement] then
        return nil,"Deferred higher-level spell grant is unavailable"
    end
    if later.Direct[swap.From] or one.Direct[swap.To] then
        return nil,"Spell provenance overlaps across recorded levels"
    end
    local out=Copy(newBook);local seen={}
    for _,row in ipairs(out.Spells) do
        local key=SpellKey(SpellId(row))
        if not key or seen[key] then return nil,"Duplicate committed native spell ownership" end
        seen[key]=true
    end
    local newCount,oldCount,addCount=0,0,0
    for _,row in ipairs(oldBook.Spells) do
        local id=SpellId(row);local key=SpellKey(id)
        if not key then return nil,"Original spellbook contains an invalid spell ID" end
        -- An original higher-level spell can now have the same key as the
        -- freshly native-owned first-level spell. It must be rewritten
        -- to the inverse target rather than silently skipped.
        if not seen[key] or tostring(id.Prototype or "")==swap.To then
            local typ=tostring(id.SourceType or "")
            local proto=tostring(id.Prototype or id.OriginatorPrototype or "")
            if typ~="ProgressionClass" and typ~="ProgressionSubClass" then
                return nil,"Cannot attribute a non-progression spell: "..proto
            end
            local isOne=Recognized(proto,one)
            local isLater=Recognized(proto,later)
            if isOne and not isLater then
                oldCount=oldCount+1
            elseif isLater and not isOne then
                local nextRow=Copy(row)
                if proto==swap.To then
                    if typ~="ProgressionSubClass"
                        or Id(id.ProgressionSource)~=Id(UpOne(original).SubClass)
                        or tostring(id.OriginatorPrototype or "")~=swap.To then
                        return nil,"Exchanged higher-level spellbook owner is not proven"
                    end
                    nextRow.Id.Prototype=swap.Replacement
                    nextRow.Id.OriginatorPrototype=swap.Replacement
                    newCount=newCount+1
                end
                local candidate=SpellId(nextRow)
                local nextProto=tostring(candidate.Prototype or "")
                local nextKey=SpellKey(candidate)
                if not Recognized(nextProto,newLater) or not nextKey or seen[nextKey] then
                    return nil,"Higher-level spell would overwrite committed native ownership: "..nextProto
                end
                out.Spells[#out.Spells+1]=nextRow
                seen[nextKey]=true;addCount=addCount+1
            else
                return nil,"Original spellbook ownership overlaps: "..proto
            end
        end
    end
    if newCount~=1 or oldCount<1 then
        return nil,"Exactly one original higher-level spellbook grant was not found"
    end
    merged.components.spellBook=out
    local prepared=Copy(newPrepares)
    prepared.PreparedSpells=prepared.PreparedSpells or {}
    local present={}
    for _,row in ipairs(prepared.PreparedSpells) do
        local key=PreparedKey(row)
        if not key or present[key] then return nil,"Invalid native prepared spell identity" end
        present[key]=true
    end
    for _,row in ipairs(oldPrepares.PreparedSpells or {}) do
        local key=PreparedKey(row)
        if not key then return nil,"Invalid historical prepared spell ID" end
        if not present[key] or tostring(row.OriginatorPrototype or row.Prototype or "")==swap.To then
            local proto=tostring(row.OriginatorPrototype or row.Prototype or "")
            local isOne=Recognized(proto,one)
            local isLater=Recognized(proto,later)
            if isLater and not isOne then
                local copy=Copy(row)
                if proto==swap.To then
                    if tostring(copy.SourceType)~="ProgressionSubClass"
                        or Id(copy.ProgressionSource)~=Id(UpOne(original).SubClass) then
                        return nil,"Higher-level prepared spell owner differs"
                    end
                    copy.OriginatorPrototype=swap.Replacement
                end
                local newKey=PreparedKey(copy)
                if seen[newKey] and not present[newKey] then
                    prepared.PreparedSpells[#prepared.PreparedSpells+1]=copy
                    present[newKey]=true
                end
            elseif not isOne then
                return nil,"Cannot attribute original prepared spell: "..proto
            end
        end
    end
    for _,key in ipairs({"ClassFallbackPreparedSpellCount","ClassPreparedSpellCount"}) do
        if oldPrepares[key] then prepared[key]=Copy(oldPrepares[key]) end
    end
    merged.components.spellBookPrepares=prepared
    merged.components.learnedSpells=Copy(native.components.learnedSpells)
    return {AddedHigherLevelSpells=addCount,DiscardedOldLevelOneSpells=oldCount}
end

function Bridge.Prepare(saved,native,target,original,swap,deferredEdits)
    local valid,why=Bridge.PreflightOriginal(saved,target)
    if not valid then return nil,why end
    local matches,reason=Bridge.CheckFirstClass(saved,native)
    if not matches then return nil,reason end
    local nativeBuckets=native.progressions and native.progressions.buckets
    local nativeUp=native.components and native.components.ccLevelUp
        and native.components.ccLevelUp.LevelUps
    if type(nativeUp)~="table" or not Dense(nativeUp) or #nativeUp~=1 then
        return nil,"BG3 has not completed exactly one native character level"
    end
    if type(nativeBuckets)~="table" or not Dense(nativeBuckets[1])
        or #nativeBuckets[1]<1 then
        return nil,"Native first-level progression owners are unavailable"
    end
    -- Native Confirm can be pressed directly on level one without ever
    -- visiting the historical slider. Re-check all actual native first-level
    -- selections against the final higher-level history here, even in the
    -- ordinary (non-exchange) path. Never replay a duplicate grant silently.
    local nativePicked={}
    local function CollectPicked(row,into)
        for _,group in ipairs({row and row.Spells or {},
            row and row.Upgrades and row.Upgrades.Spells or {}}) do
            for _,sel in ipairs(group) do
                if type(sel)=="string" then into[sel]=true
                elseif type(sel)=="table" then
                    local id=sel.SpellId or sel.SpellID
                    if id then into[tostring(id)]=true end
                    for _,item in ipairs(sel.Spells or {}) do
                        local name=type(item)=="table"
                            and (item.SpellId or item.SpellID) or item
                        if type(name)=="string" then into[name]=true end
                    end
                end
            end
        end
    end
    CollectPicked(nativeUp[1],nativePicked)
    for i=2,target do
        local laterPicked={}
        CollectPicked(saved.components.ccLevelUp.LevelUps[i],laterPicked)
        for spellId in pairs(laterPicked) do
            if nativePicked[spellId] then
                return nil,"Committed level-one spell duplicates a historical choice at level "
                    ..i..": "..spellId
            end
        end
    end
    -- Passives chosen by the player (CCLevelUp.Upgrades.Passives) are
    -- globally unique in HB. A freshly committed native L1 supersedes the
    -- original saved L1, including a passive now acquired at a later level.
    -- Audit BEFORE removing any level 2+ progression entities.
    local function SelectedPassives(upgrade)
        local rows=upgrade and upgrade.Upgrades and upgrade.Upgrades.Passives or {}
        if type(rows)~="table" then return nil end
        local ids={}
        for _,row in ipairs(rows) do
            if type(row)~="table" or type(row.Passives)~="table" then return nil end
            for _,pick in ipairs(row.Passives) do
                if type(pick)~="string" or pick=="" then return nil end
                ids[#ids+1]=pick
            end
        end
        return ids
    end
    local firstRows=SelectedPassives(nativeUp[1])
    if not firstRows then return nil,"Native level-one passive selectors are unavailable" end
    local seenPassives={}
    for _,id in ipairs(firstRows) do
        if seenPassives[id] then return nil,"Duplicate native level-one passive: "..id end
        seenPassives[id]=1
    end
    for i=2,target do
        local picks=SelectedPassives(saved.components.ccLevelUp.LevelUps[i])
        if not picks then return nil,"Historical passive selectors unavailable at level "..i end
        for _,id in ipairs(picks) do
            if seenPassives[id] then
                return nil,"Committed level-one passive conflicts with historical level "
                    ..i..": "..id
            end
            seenPassives[id]=i
        end
    end
    -- If a historical edit reuses an originally level-one passive, require
    -- BG3's committed first-level selector with the SAME source/list to
    -- account for its removal. Absence of a matching selector is not proof.
    if original and original.components and original.components.ccLevelUp
        and original.components.ccLevelUp.LevelUps then
        local oldOne=original.components.ccLevelUp.LevelUps[1]
        local oldRows=oldOne and oldOne.Upgrades and oldOne.Upgrades.Passives or {}
        for _,row in ipairs(oldRows) do
            for _,oldId in ipairs(row.Passives or {}) do
                local takenLater=seenPassives[oldId] and seenPassives[oldId]>=2
                if takenLater then
                    local matching=0
                    for _,nativeRow in ipairs(nativeUp[1].Upgrades and nativeUp[1].Upgrades.Passives or {}) do
                        if tostring(nativeRow.SelectorId or "")==tostring(row.SelectorId or "")
                            and tostring(nativeRow.PassiveList or "")==tostring(row.PassiveList or "")
                            and type(nativeRow.Passives)=="table"
                            and #nativeRow.Passives==#(row.Passives or {}) then
                            matching=matching+1
                        end
                    end
                    if matching~=1 then
                        return nil,"Native level-one passive owner could not be verified: "..oldId
                    end
                end
            end
        end
    end
    if swap then
        if not original then return nil,"Original provenance is missing" end
        local valid,why=Bridge.PreflightInverseSpellSwap(original,swap,deferredEdits)
        if not valid then return nil,why end
        valid,why=VerifyNativeInverseSpell(original,native,swap)
        if not valid then return nil,why end
        for i=2,target do
            for _,sel in ipairs(saved.components.ccLevelUp.LevelUps[i].Upgrades.Spells or {}) do
                for _,spell in ipairs(sel.Spells or {}) do
                    local id=tostring(type(spell)=="table" and spell.SpellId or spell)
                    if id==swap.To then
                        return nil,"Native level-one spell remains selected at historical level "..i
                    end
                end
            end
        end
    end
    -- At this point the engine has committed the NEW first level. Preserve
    -- that entire bucket and CC history, never the original level-one data.
    local merged=Copy(saved)
    merged.progressions.buckets[1]=Copy(nativeBuckets[1])
    merged.components.ccLevelUp.LevelUps[1]=Copy(nativeUp[1])
    -- Full-build classes still come from the recorded levels 2-X. Do not
    -- replace the verified new level-one class/subclass with an old L1 row.
    local spells,spellWhy
    if swap then
        spells,spellWhy=Bridge.MergeInverseSpellBook(original,saved,native,merged,swap)
    else
        spells,spellWhy=Bridge.MergeSpellBook(saved,native,merged,original)
    end
    if not spells then return nil,spellWhy end
    merged.hbNativeLevelOneFoundation=true
    return merged,nil,spells
end

-- BG3's CCLevelUp serializer may represent the same Upgrades row origin
-- as a literal string in a staged snapshot and as an Extender enum userdata
-- immediately after engine restoration. Compare these exact enum meanings,
-- not their Lua storage types. Never normalize arbitrary userdata or fields.
local AUDITED_UPGRADE_ORIGINS={Class=true,SubClass=true,Feat=true}
local AUDITED_UPGRADE_ROWS={
    Passives=true,Spells=true,AbilityBonuses=true,
    Skills=true,SkillExpertise=true,
}
local function SameUpgradeOrigin(a,b,path)
    local ta,tb=type(a),type(b)
    if not ((ta=="string" and tb=="userdata")
        or (ta=="userdata" and tb=="string")) then return false end
    local group=type(path)=="string"
        and path:match("^LevelUps%[%d+%]%.Upgrades%.([%a]+)%.%d+%.Type$")
    if not group or not AUDITED_UPGRADE_ROWS[group] then return false end
    local text=(ta=="string" and a or b)
    if not AUDITED_UPGRADE_ORIGINS[text] then return false end
    local ok,enumText=pcall(tostring,ta=="userdata" and a or b)
    return ok and enumText==text
end
-- Native CCLevelUp skill selections can also reappear as Extender skill
-- enum userdata after BG3 commits a respec. Normalize ONLY individual
-- proficiency/expertise values in those two recorded selection arrays,
-- and ONLY when the identity exactly matches a known skill. This is not
-- permission to ignore altered skill choices or feat-grant ownership.
local AUDITED_SKILL_NAMES={
    Acrobatics=true,AnimalHandling=true,Arcana=true,Athletics=true,
    Deception=true,History=true,Insight=true,Intimidation=true,
    Investigation=true,Medicine=true,Nature=true,Perception=true,
    Performance=true,Persuasion=true,Religion=true,SleightOfHand=true,
    Stealth=true,Survival=true,
}
local function SameUpgradeSkill(a,b,path)
    local ta,tb=type(a),type(b)
    if not ((ta=="string" and tb=="userdata")
        or (ta=="userdata" and tb=="string")) then return false end
    if type(path)~="string" or not (
        path:match("^LevelUps%[%d+%]%.Upgrades%.Skills%.%d+%.Proficiencies%.%d+$")
        or path:match("^LevelUps%[%d+%]%.Upgrades%.SkillExpertise%.%d+%.Expertise%.%d+$")) then
        return false
    end
    local skill=ta=="string" and a or b
    if not AUDITED_SKILL_NAMES[skill] then return false end
    local ok,native=pcall(tostring,ta=="userdata" and a or b)
    return ok and native==skill
end
local function DeepEqual(a,b,depth,path)
    if SameUpgradeOrigin(a,b,path) or SameUpgradeSkill(a,b,path) then return true end
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return tostring(a)==tostring(b) end
    if (depth or 0)>32 then return false end
    for k,v in pairs(a) do
        if not DeepEqual(v,b[k],(depth or 0)+1,
            (path or "").."."..tostring(k)) then return false end
    end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
-- Read-only, bounded path to the first historical mismatch. Do not relax
-- the audit: an engine-normalized field must be verified before it can be
-- excluded from equality or the restored build declared safe.
local function FirstHistoryMismatch(a,b,path,depth)
    if (depth or 0)>32 then return path.." (depth limit)" end
    if SameUpgradeOrigin(a,b,path) or SameUpgradeSkill(a,b,path) then return nil end
    if type(a)~=type(b) then
        local function Short(v)
            local ok,t=pcall(tostring,v)
            if not ok then return "<unreadable>" end
            return #t>76 and (t:sub(1,76).."...") or t
        end
        return path.." (expected "..type(a).."="..Short(a)
            ..", observed "..type(b).."="..Short(b)..")"
    end
    if type(a)~="table" then
        if tostring(a)==tostring(b) then return nil end
        local function Short(value)
            local result=tostring(value)
            return #result>76 and (result:sub(1,76).."...") or result
        end
        return path.." (expected="..Short(a).." observed="..Short(b)..")"
    end
    local keys={}
    for key in pairs(a) do keys[#keys+1]=key end
    table.sort(keys,function(x,y)
        if type(x)==type(y) then
            if type(x)=="number" then return x<y end
            return tostring(x)<tostring(y)
        end
        return type(x)<type(y)
    end)
    for _,key in ipairs(keys) do
        local child=FirstHistoryMismatch(a[key],b[key],path.."."..tostring(key),(depth or 0)+1)
        if child then return child end
    end
    for key in pairs(b) do
        if a[key]==nil then
            return path.."."..tostring(key).." (unexpected observed field)"
        end
    end
    return nil
end
-- Native level-one root choices are validated by their CC selector and
-- progression grant in MergeSpellBook. Casting rank is NOT an independent
-- choice or restoration requirement: require a live engine-owned cast of that
-- root with the same class/subclass provenance, regardless of its variant ID.
-- Never accept an Osiris/Common/foreign-source grant as a replacement.
local function NativeFirstLevelRootHasLiveCast(expected,rootSid,liveRows)
    local key=SpellKey(rootSid)
    if not key or not (expected.hbNativeFirstLevelRootKeys or {})[key] then
        return false
    end
    local root=tostring(rootSid.Prototype or "")
    local owner=Id(rootSid.ProgressionSource)
    local kind=tostring(rootSid.SourceType or "")
    local source=Id(rootSid.Source)
    if root=="" or source~=EMPTY or owner==EMPTY then return false end
    local matches=0
    for _,row in ipairs(liveRows or {}) do
        local sid=SpellId(row)
        -- The native C++ caster may normalize a spell to another live cast
        -- prototype. Its invariant OriginatorPrototype is the ROOT; do not
        -- inspect, add, remove, or demand any particular numbered variant.
        if sid and tostring(sid.OriginatorPrototype or "")==root
            and tostring(sid.SourceType or "")==kind
            and Id(sid.ProgressionSource)==owner
            and Id(sid.Source)==source then
            matches=matches+1
        end
    end
    return matches>0
end

function Bridge.Audit(expected,current,target)
    local same,why=Bridge.CheckFirstClass(expected,current)
    if not same then return false,why end
    local ups=current.components and current.components.ccLevelUp
        and current.components.ccLevelUp.LevelUps
    local expectedUps=expected.components and expected.components.ccLevelUp
        and expected.components.ccLevelUp.LevelUps
    if type(ups)~="table" or not Dense(ups) or #ups~=target then
        return false,"Post-restore level history has the wrong number of levels"
    end
    for i=1,target do
        if not DeepEqual(ups[i],expectedUps[i],0,"LevelUps["..i.."]") then
            local detail=FirstHistoryMismatch(expectedUps[i],ups[i],"LevelUps["..i.."]",0)
            return false,"Post-restore historical selections differ at level "..i
                ..(detail and ("; first difference: "..detail) or "")
        end
    end
    local buckets=current.progressions and current.progressions.buckets
    local expectedBuckets=expected.progressions and expected.progressions.buckets
    if not buckets then return false,"Live progression container is unavailable" end
    for i=1,target do
        if not Dense(buckets[i]) or not Dense(expectedBuckets[i])
            or #buckets[i]~=#expectedBuckets[i] then
            return false,"Post-restore progression entry count differs at level "..i
        end
    end
    local book=current.components and current.components.spellBook
    local original=expected.components and expected.components.spellBook
    if type(book)~="table" or type(book.Spells)~="table"
        or type(original)~="table" then
        return false,"Live spellbook missing after restore"
    end
    local keys={}
    for _,row in ipairs(book.Spells) do
        local key=SpellKey(SpellId(row))
        if not key or keys[key] then return false,"Live spellbook contains duplicate or invalid ownership" end
        keys[key]=true
    end
    for _,row in ipairs(original.Spells) do
        local key=SpellKey(SpellId(row))
        -- A verified native L1 historical root is satisfied by the live
        -- engine-owned cast of that same root, regardless of cast rank.
        if not keys[key]
            and not NativeFirstLevelRootHasLiveCast(expected,SpellId(row),book.Spells)
            and not KnownIgnoredNumbered(expected,SpellId(row))
            and not (expected.hbNativeTransientAutoGrantKeys or {})[key]
            and not (expected.hbVerifiedDerivedContainerKeys or {})[key]
            and not (expected.hbVerifiedDerivedUpcastKeys or {})[key] then
            local root=tostring(row.Id.OriginatorPrototype or row.Id.Prototype or "")
            local found={}
            for _,liveRow in ipairs(book.Spells) do
                local live=SpellId(liveRow)
                if live and (tostring(live.OriginatorPrototype or "")==root
                    or tostring(live.Prototype or "")==root) then
                    found[#found+1]=tostring(live.Prototype or "?").."/"
                        ..tostring(live.SourceType or "?").."/"
                        ..Id(live.ProgressionSource)
                end
            end
            table.sort(found)
            while #found>5 do table.remove(found) end
            return false,"Live spell grant missing after restore: "..tostring(row.Id.Prototype)
                .." [live origin matches="..(#found>0 and table.concat(found,",") or "none").."]"
        end
    end
    for key in pairs(expected.hbRemovedHistoricalContainerKeys or {}) do
        if keys[key] and not (expected.hbIgnoredNumberedVariantKeys or {})[key] then return false,"Removed historical container spell survived restoration: "..key end
    end
    for key,prototype in pairs(expected.hbRemovedClassPassiveActionKeys or {}) do
        for _,row in ipairs(book.Spells) do
            local id=SpellId(row)
            if id and (SpellKey(id)==key or tostring(id.Prototype or "")==prototype) then
                return false,"Removed selected-passive action survived restoration: "..prototype
            end
        end
    end
    for key in pairs(expected.hbRemovedFeatSpellKeys or {}) do
        if keys[key] and not (expected.hbIgnoredNumberedVariantKeys or {})[key] then return false,"Removed feat-owned spell survived restoration: "..key end
    end
    for key,prototype in pairs(expected.hbBuildDisplacedClassSpellKeys or {}) do
        if keys[key] then
            return false,"Obsolete class action survived build import: "..prototype
        end
        -- An old action reintroduced by another grant source is just as
        -- unsafe: the preset did not select this root under any owner.
        for _,row in ipairs(book.Spells) do
            local sid=SpellId(row)
            if sid and tostring(sid.Prototype or "")==prototype then
                return false,"Obsolete class action has a foreign live grant: "..prototype
            end
        end
    end
    for key in pairs(expected.hbRetainedFeatActionKeys or {}) do
        if not keys[key] then return false,"Retained feat action not regranted by engine: "..key end
    end
    for _,prototype in pairs(expected.hbPassiveOwnedRemovedSpellKeys or {}) do
        for _,row in ipairs(book.Spells) do
            local sid=SpellId(row)
            if sid and sid.Prototype==prototype then
                return false,"Removed passive action has another live grant: "..prototype
            end
        end
    end
    return true,nil
end

-- A successful historical replay can be followed by a native SpellBook
-- normalization tick which drops a legitimately chosen level-2+ class spell.
-- Before any narrowly scoped recovery, verify BOTH the saved CC selector and
-- the exact ProgressionSpells owner. Do not include containers, derived
-- upcasts, feat grants, absent historical choices, or native level-one spells.
-- Returns an isolated proposed spellbook/preparation snapshot; this method
-- never changes game-owned entities and never weakens Audit().
local function ExactLaterClassSpellOwner(expected,spellSid,target)
    if type(spellSid)~="table" or Id(spellSid.Source)~=EMPTY then return nil end
    local kind=tostring(spellSid.SourceType or "")
    if kind~="ProgressionClass" and kind~="ProgressionSubClass" then return nil end
    local proto=tostring(spellSid.Prototype or "")
    if proto=="" or tostring(spellSid.OriginatorPrototype or "")~=proto then return nil end
    local owner=Id(spellSid.ProgressionSource)
    if owner==EMPTY then return nil end
    local ups=expected.components and expected.components.ccLevelUp
        and expected.components.ccLevelUp.LevelUps
    local buckets=expected.progressions and expected.progressions.buckets
    if not Dense(ups) or #ups~=target or type(buckets)~="table" then return nil end
    local matches=0
    for level=1,target do
        local selected=0
        for _,selector in ipairs(ups[level].Upgrades and ups[level].Upgrades.Spells or {}) do
                local classField=Id(selector.Class)
            local subclassField=Id(selector.Subclass)
            local selectorKind=tostring(selector.Type or "")
            for _,pick in ipairs(selector.Spells or {}) do
                local value=type(pick)=="table" and pick.SpellId or pick
                if value==proto then
                    -- The CC layout can put the selected subclass UUID in
                    -- Class rather than Subclass (as in the saved Fighter).
                    -- Require one unambiguous field equal to the recorded
                    -- progression source AND the exact selector kind.
                    local fieldMatches=(classField==owner and 1 or 0)
                        +(subclassField==owner and 1 or 0)
                    local expectedKind=kind=="ProgressionClass" and "Class" or "SubClass"
                    if selectorKind~=expectedKind or fieldMatches~=1 then return nil end
                    selected=selected+1
                end
            end
        end
        if selected>0 then
            -- Native level one is always authoritative and must never be
            -- reconstructed as a historical higher-level spell.
            if level==1 or selected~=1 or not Dense(buckets[level]) then return nil end
            local granted=0
            for _,entry in ipairs(buckets[level]) do
                local meta=entry.meta
                if meta and Id(meta.Source)==owner
                    and tostring(meta.SpellSourceType or "")==kind then
                    for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                        if grant.SpellId==proto then granted=granted+1 end
                    end
                end
            end
            if granted~=1 then return nil end
            matches=matches+1
        end
    end
    return matches==1 and proto or nil
end
-- Native higher-level progression owns spells unlocked by class/subclass
-- passive choices. They are NOT learned spells and must never be passed to
-- Osi.AddSpell just because the native first-level book lacks them. Prove
-- the unique exact passive in both the historical CC selector and its
-- matching class/subclass ProgressionPassives owner before deferring to BG3.
-- A removed passive, foreign owner, duplicate selection, feat choice, or
-- an independent spell grant cannot use this route. Audit still requires the
-- exact original action to exist after the game regrants the passive.
local function ExactLaterPassiveActionOwner(expected,sid,target)
    if type(sid)~="table" or Id(sid.Source)~=EMPTY then return false end
    local kind=tostring(sid.SourceType or "")
    if kind~="ProgressionClass" and kind~="ProgressionSubClass" then return false end
    local proto=tostring(sid.Prototype or "")
    if proto=="" or tostring(sid.OriginatorPrototype or "")~=proto then return false end
    local selectedPassive=proto:match("^[%w]+_(.+)$")
    if not selectedPassive or selectedPassive=="" then return false end
    local owner=Id(sid.ProgressionSource)
    if owner==EMPTY then return false end
    local ups=expected.components and expected.components.ccLevelUp
        and expected.components.ccLevelUp.LevelUps
    local buckets=expected.progressions and expected.progressions.buckets
    if not Dense(ups) or #ups~=target or type(buckets)~="table" then return false end
    local totalChoices,totalProgressions=0,0
    local selectedLevel=nil
    for level=1,target do
        local up=ups[level]
        if type(up)~="table" or not Dense(buckets[level]) then return false end
        -- The same action must not be an independently chosen spell.
        for _,selector in ipairs(up.Upgrades and up.Upgrades.Spells or {}) do
            for _,pick in ipairs(selector.Spells or {}) do
                local id=type(pick)=="table" and pick.SpellId or pick
                if id==proto then return false end
            end
        end
        for _,entry in ipairs(buckets[level]) do
            for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                if grant.SpellId==proto then return false end
            end
        end
        for _,selector in ipairs(up.Upgrades and up.Upgrades.Passives or {}) do
            for _,passive in ipairs(selector.Passives or {}) do
                if passive==selectedPassive then
                    local sameOwner=tostring(selector.Type or "")==
                        (kind=="ProgressionClass" and "Class" or "SubClass")
                        and Id(selector.Class)==owner
                        and tonumber(selector.Level)==level
                        and (kind~="ProgressionClass" or Id(up.Class)==owner)
                    if not sameOwner or level==1 then return false end
                    totalChoices=totalChoices+1
                    selectedLevel=level
                end
            end
        end
        for _,entry in ipairs(buckets[level]) do
            local meta=entry.meta
            for _,passive in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                if passive==selectedPassive then
                    if type(meta)~="table" or Id(meta.Source)~=owner
                        or tostring(meta.SpellSourceType or "")~=kind
                        or tonumber(meta.Level)~=level or level==1 then return false end
                    totalProgressions=totalProgressions+1
                    if selectedLevel~=level and totalChoices>0 then return false end
                end
            end
        end
    end
    return totalChoices==1 and totalProgressions==1
end

-- Reconcile a respec removal through game-owned Osiris spell APIs rather than
-- Unserialize of an entire live SpellBook.  Vanilla's cast registration and
-- hotbar references cannot be recreated by a plain Lua component snapshot.
-- Plan construction is pure and rejects unproven grants before an Osiris call.
function Bridge.PlanEngineOwnedSpellDiff(expected, observed, target, original)
    local proposed=expected and expected.components and expected.components.spellBook
    local live=observed and observed.components and observed.components.spellBook
    if not proposed or not Dense(proposed.Spells) or not live or not Dense(live.Spells) then
        return nil,"Spell inventories unavailable for engine reconciliation"
    end
    local recorded,liveKeys,liveNames={},{},{}
    for _,row in ipairs(proposed.Spells) do
        local sid=SpellId(row);local key=SpellKey(sid)
        if not key or recorded[key] then return nil,"Repeated expected spell identity" end
        if not KnownIgnoredNumbered(expected,sid) then recorded[key]=sid end
    end
    for _,row in ipairs(live.Spells) do
        local sid=SpellId(row);local key=SpellKey(sid)
        if not key or liveKeys[key] then return nil,"Repeated current spell identity" end
        liveKeys[key]=sid
        local name=tostring(sid.Prototype or "")
        liveNames[name]=(liveNames[name] or 0)+1
    end
    local remove,removeNames={},{}
    for key,sid in pairs(liveKeys) do
        local invalid=(expected.hbRemovedFeatSpellKeys or {})[key]
            or (expected.hbRemovedHistoricalContainerKeys or {})[key]
        if invalid and not (expected.hbPassiveOwnedRemovedSpellKeys or {})[key]
            and not KnownIgnoredNumbered(expected,sid) then
            local proto=tostring(sid.Prototype or "")
            if proto=="" then return nil,"Removed spell has no prototype" end
            -- Osi.RemoveSpell affects a prototype, not one of its grant sources.
            -- It is unsafe if another grant of that prototype survives.
            for _,other in pairs(recorded) do
                if tostring(other.Prototype or "")==proto then
                    return nil,"Removed grant shares a retained prototype: "..proto
                end
            end
            if liveNames[proto]~=1 then
                return nil,"Removed grant has multiple live owners: "..proto
            end
            if not removeNames[proto] then
                removeNames[proto]=true;remove[#remove+1]=proto
            end
        end
    end
    local add,addNames,derived={},{},{}
    local allExpectedNames,expectedOwners={},{}
    for _,sid in pairs(recorded) do
        local name=tostring(sid.Prototype or "")
        allExpectedNames[name]=(allExpectedNames[name] or 0)+1
        expectedOwners[name]=sid
    end
    for key,sid in pairs(recorded) do
        if not liveKeys[key] then
            local proto=tostring(sid.Prototype or "")
            -- The native L1 spell is owned by its ROOT history, not by the
            -- selected casting rank. Do not Osiris-add root or variant when
            -- the engine already has its verified class/subclass-owned cast.
            if (expected.hbNativeFirstLevelRootKeys or {})[key] then
                if not NativeFirstLevelRootHasLiveCast(expected,sid,live.Spells) then
                    return nil,"Native level-one root has no live class-owned cast: "..proto
                end
            elseif (expected.hbRetainedFeatActionKeys or {})[key] then
                -- This is a proven native feat/passive grant, not a learned
                -- class spell. Never create an unrelated Osiris/Common grant.
                -- The final audit still requires its exact native owner.
                if (liveNames[proto] or 0)>0 then
                    return nil,"Retained feat spell has conflicting live owner: "..proto
                end
            else
            -- Do not call AddSpell for a cast variant or a child of a spell
            -- container. AddSpell(parent, 0, 1) registers container children
            -- through the game. Calling AddSpell(child) as well creates
            -- separate/duplicate learned grants and automatic hotbar tiles.
            local parent=(expected.hbRetainedDerivedParents or {})[key]
            if parent then
                if allExpectedNames[proto]~=1 or allExpectedNames[parent]~=1 then
                    return nil,"Derived spell or parent has multiple recorded owners: "..proto
                end
                local parentSid=expectedOwners[parent]
                if not parentSid
                    or Id(sid.ProgressionSource)~=Id(parentSid.ProgressionSource)
                    or Id(sid.Source)~=Id(parentSid.Source)
                    or tostring(sid.SourceType or "")~=tostring(parentSid.SourceType or "") then
                    return nil,"Derived spell parent provenance differs: "..proto
                end
                if (liveNames[proto] or 0)>0 then
                    return nil,"Live derived spell has different grant ownership: "..proto
                end
                derived[#derived+1]={Id=proto,Parent=parent}
            else
                -- Independently selected roots require a unique actual
                -- historical class/subclass selection and progression owner.
                if (liveNames[proto] or 0)>0 then
                    return nil,"Live spell source differs for "..proto
                end
                if allExpectedNames[proto]~=1 then
                    return nil,"Ambiguous missing grant prototype: "..proto
                end
                if ExactLaterPassiveActionOwner(expected,sid,target)
                    or AuditedLaterGrant(expected,sid)
                    or AuditedSorcererLaterConversion(expected,sid)
                    or AuditedClassSubclassLaterGrant(expected,original,sid)
                    or VerifiedWizardCounterspellAlias(expected,original,sid) then
                    -- Native game-owned progression/passives must regenerate
                    -- this action. Never install a duplicate Osiris grant.
                    -- The final audit requires the original owned identity.
                else
                    local chosen=ExactLaterClassSpellOwner(expected,sid,target)
                    if not chosen then
                        return nil,"Unproved native spell regrant: "..proto
                    end
                    if not addNames[proto] then
                        addNames[proto]=true
                        add[#add+1]={Id=proto,Root=true}
                    end
                end
            end
            end -- native-level-one roots are engine-owned, never Osiris-added
        end
    end
    table.sort(remove)
    table.sort(add,function(a,b) return a.Id<b.Id end)
    table.sort(derived,function(a,b) return a.Id<b.Id end)
    return {Add=add,Remove=remove,Derived=derived},nil
end

-- Preserve the exact historical-class / feat / progression guards of Audit,
-- but recognize grants created by Osiris only when their exact original
-- higher-level choice (or proven derived parent) supplied the regrant plan.
-- A second grant owner, missing original choice, or removed feat still fails.
function Bridge.AuditEngineOwnedSpells(expected,observed,target,engineAdded)
    local copy=Copy(expected)
    local observedBook=observed and observed.components and observed.components.spellBook
    if not observedBook or not Dense(observedBook.Spells) then
        return false,"Engine spell inventory unavailable"
    end
    local byProto={}
    for _,row in ipairs(observedBook.Spells) do
        local sid=SpellId(row)
        local name=sid and tostring(sid.Prototype or "") or ""
        if name=="" then return false,"Invalid live spell" end
        byProto[name]=byProto[name] or {}
        byProto[name][#byProto[name]+1]=sid
    end
    local wanted=expected.components and expected.components.spellBook
    if not wanted or not Dense(wanted.Spells) then return false,"Saved spell inventory unavailable" end
    local liveExact={}
    for _,row in ipairs(observedBook.Spells) do liveExact[SpellKey(SpellId(row))]=true end
    for _,row in ipairs(wanted.Spells) do
        local sid=SpellId(row);local key=SpellKey(sid)
        if not liveExact[key]
            and not NativeFirstLevelRootHasLiveCast(expected,sid,observedBook.Spells)
            and not KnownIgnoredNumbered(expected,sid) then
            local proto=tostring(sid.Prototype or "")
            local childParent=(expected.hbRetainedDerivedParents or {})[key]
            local candidates=byProto[proto] or {}
            if childParent then
                -- A verified child can be generated as part of AddSpell(root),
                -- without its original serialized grant identity. It still
                -- MUST exist as one engine-owned cast with a uniquely
                -- registered parent. Do not exempt missing derived casts.
                local parentRows=byProto[childParent] or {}
                if #parentRows~=1 or #candidates~=1 then
                    return false,"Engine-derived cast missing or ambiguous: "..proto
                end
                local child=candidates[1]
                if tostring(child.SourceType or "")=="Feat"
                    or Id(child.Source)~=EMPTY
                    or (Id(child.ProgressionSource)~=EMPTY
                        and Id(child.ProgressionSource)~=Id(sid.ProgressionSource)) then
                    return false,"Engine-derived cast has foreign owner: "..proto
                end
            else
                local fallback=engineAdded and engineAdded[proto]
                local permitted=ExactLaterClassSpellOwner(expected,sid,target)
                if not fallback or not permitted or #candidates~=1 then
                    return false,"Engine-owned historical spell not verified: "..proto
                end
                local existing=candidates[1]
                if tostring(existing.SourceType or "")=="Feat"
                    or Id(existing.ProgressionSource)~=EMPTY then
                    return false,"Engine regrant has unexpected source: "..proto
                end
            end
        end
    end
    -- All independent historical grants were checked above. Run the FULL
    -- existing history/progression/removed-feat audit unchanged against the
    -- current live book, rather than comparing against an Unserialize copy.
    copy.components.spellBook=Copy(observedBook)
    return Bridge.Audit(copy,observed,target)
end

function Bridge.PlanHistoricalSpellRecovery(expected,observed,target)
    local audited,why=Bridge.Audit(expected,observed,target)
    if audited then return nil,"No missing recorded spells" end
    if type(why)~="string" or why:find("Live spell grant missing after restore: ",1,true)~=1 then
        return nil,why or "Post-replay audit did not identify a missing grant"
    end
    local saved=expected.components and expected.components.spellBook
    local live=observed.components and observed.components.spellBook
    local savedPrep=expected.components and expected.components.spellBookPrepares
    local livePrep=observed.components and observed.components.spellBookPrepares
    if not saved or not Dense(saved.Spells) or not live or not Dense(live.Spells)
        or not savedPrep or not Dense(savedPrep.PreparedSpells)
        or not livePrep or not Dense(livePrep.PreparedSpells) then
        return nil,"Recovery requires complete live and recorded spell inventories"
    end
    local existing={}
    for _,row in ipairs(live.Spells) do
        local sid=SpellId(row)
        local key=SpellKey(sid)
        if not key or existing[key] then return nil,"Live grant identities are invalid or duplicated" end
        existing[key]=true
    end
    for key in pairs(expected.hbRemovedFeatSpellKeys or {}) do
        if existing[key] then return nil,"Removed feat grant is still present" end
    end
    for key in pairs(expected.hbRemovedHistoricalContainerKeys or {}) do
        if existing[key] then return nil,"Removed container grant is still present" end
    end
    local proposed=Copy(live)
    local recovered={};local wantedPrepared={}
    local previous={}
    for _,row in ipairs(saved.Spells) do
        local sid=SpellId(row)
        local key=SpellKey(sid)
        if not key or previous[key] then return nil,"Recorded spell ownership is duplicated" end
        previous[key]=true
        if not existing[key]
            and not NativeFirstLevelRootHasLiveCast(expected,sid,live.Spells)
            and not KnownIgnoredNumbered(expected,sid)
            and not (expected.hbNativeTransientAutoGrantKeys or {})[key]
            and not (expected.hbVerifiedDerivedContainerKeys or {})[key]
            and not (expected.hbVerifiedDerivedUpcastKeys or {})[key] then
            if (expected.hbNativeFirstLevelRootKeys or {})[key] then
                return nil,"Native level-one root has no live class-owned cast: "
                    ..tostring(sid.Prototype or "")
            end
            local isDerived=(expected.hbRetainedDerivedParents or {})[key]~=nil
            local chosen=not isDerived and ExactLaterClassSpellOwner(expected,sid,target) or nil
            if not chosen and not isDerived then
                return nil,"Missing spell has no uniquely proven higher-level class choice: "
                    ..tostring(sid.Prototype)
            end
            if not isDerived then
            -- Do not create a second owner for a spell already normalized to
            -- a different class/feat identity by the engine.
            for _,liveRow in ipairs(live.Spells) do
                local other=SpellId(liveRow)
                if other and tostring(other.Prototype or "")==chosen then
                    return nil,"Live spell has a conflicting owner: "..chosen
                end
            end
            proposed.Spells[#proposed.Spells+1]=Copy(row)
            recovered[#recovered+1]=chosen
            wantedPrepared[PreparedKey(sid)]=true
            existing[key]=true
            end -- independently chosen root; derived entries handled below
        end
    end
    -- Reassert derived casts only when the merged snapshot already proved
    -- their parent, and the exact parent grant survived (or was recovered)
    -- in the proposed live book. Never recover a removed feat/container child.
    local byIdentity={}
    for _,row in ipairs(proposed.Spells) do
        local id=SpellId(row)
        local name=id and tostring(id.Prototype or "") or ""
        if name~="" then
            byIdentity[name]=byIdentity[name] or {}
            byIdentity[name][#byIdentity[name]+1]=id
        end
    end
    local retained=expected.hbRetainedDerivedParents or {}
    for _,row in ipairs(saved.Spells) do
        local sid=SpellId(row)
        local key=SpellKey(sid)
        local parent=key and retained[key]
        if parent and not existing[key] and not KnownIgnoredNumbered(expected,sid) then
            local count=0
            for _,root in ipairs(byIdentity[parent] or {}) do
                if Id(root.ProgressionSource)==Id(sid.ProgressionSource)
                    and Id(root.Source)==Id(sid.Source)
                    and tostring(root.SourceType or "")==tostring(sid.SourceType or "") then
                    count=count+1
                end
            end
            if count~=1 then
                return nil,"Derived spell has no uniquely restored parent: "
                    ..tostring(sid.Prototype)
            end
            proposed.Spells[#proposed.Spells+1]=Copy(row)
            recovered[#recovered+1]=tostring(sid.Prototype)
            wantedPrepared[PreparedKey(sid)]=true
            existing[key]=true
        end
    end
    if #recovered==0 then return nil,"No independently owned historical spells can be recovered" end
    local preparations=Copy(livePrep)
    local preparedKeys={}
    for _,entry in ipairs(preparations.PreparedSpells) do
        local key=PreparedKey(entry)
        if not key or preparedKeys[key] then
            return nil,"Live spell preparations are invalid or duplicated"
        end
        preparedKeys[key]=true
    end
    for _,entry in ipairs(savedPrep.PreparedSpells) do
        local key=PreparedKey(entry)
        if wantedPrepared[key] and not preparedKeys[key] then
            preparations.PreparedSpells[#preparations.PreparedSpells+1]=Copy(entry)
            preparedKeys[key]=true
        end
    end
    return {SpellBook=proposed,SpellBookPrepares=preparations,Spells=recovered},nil
end
