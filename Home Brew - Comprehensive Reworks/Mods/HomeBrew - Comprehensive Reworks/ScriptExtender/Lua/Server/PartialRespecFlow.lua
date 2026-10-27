---@class PendingPartialRespec
---@field level integer|nil
---@field charLevel integer
---@field snapshot table|nil

---@type table<string, PendingPartialRespec>
-- The native post-replay audit below is defined before the generic edit
-- helpers. Forward-declare the copy helper for its closure so it cannot
-- resolve to an undefined global when a build preset is imported.
local CopyPlainTable
-- Build-import validation is called from an earlier native replay closure.
-- Forward-declare its module here; a late `local` would create a different
-- variable and make the earlier callback resolve an undefined global.
local HBBuildPresetData

local pendingRespec = {}

-- Diagnostic is intentionally independent of the progression viewer. If a
-- spellcaster's saved choices cannot be summarized we must still record that
-- fact and present the safe full/partial respec choice instead of failing.
local respecStartDiagnostics = { "HB respec start diagnostics v2 (history coverage and caster recovery)" }
local function RespecStartLog(message)
    respecStartDiagnostics[#respecStartDiagnostics + 1] = tostring(message)
    if #respecStartDiagnostics > 160 then table.remove(respecStartDiagnostics, 2) end
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, "HomeBrew/Diagnostics/HB_RespecStart_Diagnostics.txt",
            table.concat(respecStartDiagnostics, "\n") .. "\n")
    end
end


-- Bounded, read-only passive-source observation for the level-one pilot.
-- No passive or progression mutation occurs here. Capture once per load and
-- on a failed level-one passive audit; never scan every frame.
local hbLevelOnePassiveProbe = { Version = 1, Observations = {} }
local function HB_SaveLevelOnePassiveSources(actor, phase)
    if not Ext.IO or not Ext.IO.SaveFile or not Ext.Json then return end
    local report = { Phase = phase, Actor = tostring(actor), Passives = {},
        CharacterPassiveComponents = {}, CharacterComponentNames = {},
        ProgressionPassiveRows = {}, SpellBookMatches = {}, Errors = {} }
    local function Error(where, reason)
        if #report.Errors < 12 then
            report.Errors[#report.Errors+1] = tostring(where)..": "..tostring(reason)
        end
    end
    local function Safe(where, fn)
        local ok, result = pcall(fn)
        if not ok then Error(where,result); return nil end
        return result
    end
    local character = Safe("entity",function() return Ext.Entity.Get(actor) end)
    if not character then return end
    for _,id in ipairs({"PushingAttack", "Rally"}) do
        report.Passives[id] = Safe("HasPassive."..id,
            function() return Osi.HasPassive(actor,id) end)
    end
    local names = Safe("GetAllComponentNames",function()
        return character:GetAllComponentNames()
    end)
    if names then
        Safe("component_names", function()
            for key,val in pairs(names) do
                local name = tostring(key)
                local nativeName = tostring(val)
                local haystack = (name.." "..nativeName):lower()
                if haystack:find("passive",1,true)
                    or haystack:find("boost",1,true)
                    or haystack:find("progression",1,true) then
                    if #report.CharacterComponentNames < 65 then
                        report.CharacterComponentNames[#report.CharacterComponentNames+1] =
                            name.." : "..tostring(val)
                    end
                end
            end
        end)
    end
    local components = Safe("GetAllComponents",function()
        return character:GetAllComponents()
    end)
    if components then
        Safe("passive_components",function()
            local visited=0
            for name,comp in pairs(components) do
                name=tostring(name)
                if name:lower():find("passive",1,true) then
                    visited=visited+1
                    if visited <= 20 then
                        local serialized = Safe("serialize."..name,
                            function() return Ext.Types.Serialize(comp) end)
                        if serialized then
                            local encoded=Safe("encode."..name,function()
                                return Ext.Json.Stringify(serialized)
                            end)
                            if encoded then
                                report.CharacterPassiveComponents[name] =
                                    #encoded<=15000 and serialized or
                                    ("TRUNCATED length="..tostring(#encoded)
                                        .." prefix="..encoded:sub(1,12000))
                            end
                        else
                            report.CharacterPassiveComponents[name] = tostring(comp)
                        end
                    end
                end
            end
        end)
    end
    Safe("level_one_progressions",function()
        local bucket = character.ProgressionContainer
            and character.ProgressionContainer.Progressions
            and character.ProgressionContainer.Progressions[1]
        if not bucket then return end
        for _,entry in ipairs(bucket) do
            if #report.ProgressionPassiveRows >= 12 then break end
            local passives = entry.ProgressionPassives
            local meta = entry.ProgressionMeta
            local row = {
                Meta = meta and Safe("progression_meta",function()
                    return Ext.Types.Serialize(meta) end) or nil,
                Passives = passives and Safe("progression_passives",function()
                    return Ext.Types.Serialize(passives) end) or nil,
            }
            report.ProgressionPassiveRows[#report.ProgressionPassiveRows+1] = row
        end
    end)
    Safe("spellbook",function()
        local spells=character.SpellBook and character.SpellBook.Spells
        if not spells then return end
        for _,entry in ipairs(spells) do
            local id=entry.Id
            local proto=id and tostring(id.Prototype or "") or ""
            if proto:find("PushingAttack",1,true) or proto:find("Rally",1,true) then
                if #report.SpellBookMatches<20 then
                    report.SpellBookMatches[#report.SpellBookMatches+1] =
                        Safe("spell_row",function() return Ext.Types.Serialize(entry) end)
                end
            end
        end
    end)
    if #hbLevelOnePassiveProbe.Observations >= 6 then
        table.remove(hbLevelOnePassiveProbe.Observations,1)
    end
    hbLevelOnePassiveProbe.Observations[#hbLevelOnePassiveProbe.Observations+1]=report
    -- The full serialized report may contain non-JSON-safe engine values.
    -- Persist a strictly primitive, bounded companion text report so failed
    -- serialization cannot conceal the source of a retained level-one passive.
    local lines = {
        "HB level-one passive source audit v2",
        "phase="..tostring(phase).." actor="..tostring(actor),
        "old="..tostring(report.Passives.PushingAttack)
            .." new="..tostring(report.Passives.Rally),
        "componentNames="..tostring(#report.CharacterComponentNames)
            .." passiveComponents="..tostring((function()
                local count=0
                for _ in pairs(report.CharacterPassiveComponents) do count=count+1 end
                return count
            end)())
            .." progressionRows="..tostring(#report.ProgressionPassiveRows)
            .." spellMatches="..tostring(#report.SpellBookMatches),
    }
    for i,name in ipairs(report.CharacterComponentNames) do
        if i>65 then break end
        lines[#lines+1]="component["..i.."]="..tostring(name)
    end
    for name,component in pairs(report.CharacterPassiveComponents) do
        local serialized=""
        local ok,result=pcall(function()
            return Ext.Json.Stringify(component)
        end)
        if ok and type(result)=="string" then
            serialized=result:sub(1,9000)
        else
            serialized="SERIALIZE_UNAVAILABLE "..tostring(result)
        end
        lines[#lines+1]="passiveComponent "..tostring(name).."="..serialized
    end
    for i,row in ipairs(report.ProgressionPassiveRows) do
        local meta=row.Meta
        local passives=row.Passives
        local add={}
        if type(passives)=="table" and type(passives.AddPassives)=="table" then
            for j,p in ipairs(passives.AddPassives) do
                if j>25 then break end
                add[#add+1]=tostring(p)
            end
        end
        local source="?"
        if type(meta)=="table" then source=tostring(meta.Source or meta.SpellSourceType or "?") end
        lines[#lines+1]="progression["..i.."] source="..source
            .." addPassives="..table.concat(add,",")
    end
    for i,spell in ipairs(report.SpellBookMatches) do
        local sid=type(spell)=="table" and spell.Id or nil
        if type(sid)=="table" then
            lines[#lines+1]="spell["..i.."]="..tostring(sid.Prototype)
                .." origin="..tostring(sid.OriginatorPrototype)
                .." sourceType="..tostring(sid.SourceType)
                .." progressionSource="..tostring(sid.ProgressionSource)
        else
            lines[#lines+1]="spell["..i.."]=UNSERIALIZABLE"
        end
    end
    for i,err in ipairs(report.Errors) do
        lines[#lines+1]="error["..i.."]="..tostring(err)
    end
    local saved, saveResult=pcall(Ext.IO.SaveFile,
        "HomeBrew/Diagnostics/HB_LevelOne_PassiveSources.txt", table.concat(lines,"\n").."\n")
    RespecStartLog("LEVEL_ONE_PASSIVE_SOURCE_TEXT phase="..tostring(phase)
        .." ok="..tostring(saved).." result="..tostring(saveResult)
        .." errorCount="..tostring(#report.Errors))
    -- Also preserve the most useful ownership rows in the known-working log.
    for i,spell in ipairs(report.SpellBookMatches) do
        local sid=type(spell)=="table" and spell.Id or nil
        if type(sid)=="table" then
            RespecStartLog("LEVEL_ONE_PASSIVE_SPELL phase="..tostring(phase)
                .." id="..tostring(sid.Prototype)
                .." source="..tostring(sid.ProgressionSource)
                .." type="..tostring(sid.SourceType))
        end
    end
    for i,err in ipairs(report.Errors) do
        RespecStartLog("LEVEL_ONE_PASSIVE_PROBE_ERROR phase="..tostring(phase)
            .." index="..tostring(i).." reason="..tostring(err))
    end
    -- Keep the original JSON probe as best-effort for compatible components.
    Safe("write_probe",function()
        return Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_LevelOne_PassiveSources.json",
            Ext.Json.Stringify(hbLevelOnePassiveProbe,{Beautify=true}))
    end)
    RespecStartLog("LEVEL_ONE_PASSIVE_SOURCE_AUDIT phase="..phase
        .." old="..tostring(report.Passives.PushingAttack)
        .." new="..tostring(report.Passives.Rally)
        .." components="..tostring(#report.CharacterComponentNames)
        .." spellMatches="..tostring(#report.SpellBookMatches)
        .." errors="..tostring(#report.Errors))
end
-- This probe is also useful on a clean original save, before any risky edit.
if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(function()
        Ext.Timer.WaitFor(1800,function()
            local host=Osi and Osi.GetHostCharacter and Osi.GetHostCharacter()
            if host and tostring(host)~="" then
                pcall(HB_SaveLevelOnePassiveSources,host,"session_loaded")
            end
        end)
    end)
end

---@param character string
---@return string
local function Guid(character)
    return string.sub(tostring(character), -36)
end

---@param peerId integer
---@return integer
local function PeerToReservedUserID(peerId)
    return peerId - (peerId % 0x10000) + 1
end

-- Only during dialog? Not sure, haven't tested
local RESPEC_START_FLAG = "6d4979bc-8e95-46be-9c27-96c6e22b0152"
local TOAST_DELAY_MS = 1000
local classDisplayNames = {}
local featDisplayNames = {}
local featDescriptionGuids = {}
local featDescriptionsLoaded = false
local hbFeatXmlRuleCache = {}
-- The optional read-only feat audit is defined below the respec-start handler.
local SaveHistoricalFeatSecondaryAudit
local SaveLevelOneAndSpellProvenance
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

local passiveDisplayNames = {}
local hbClassPassives = nil

-- Exact union of the thirteen HB class-choice PassiveLists. Embedding the IDs
-- avoids relying on PassiveList static-data exposure, which varies by SE build.
local HB_CLASS_PASSIVE_IDS = [[AdaptivePlating;ArcaneCalibrationMatrix;AutomatedArcaneSuppression;CastleDefense;DeadZoneCalibration;ElementalPayload;EmergencyPowerCell;FailsafeInjection;IncendiaryRounds;KineticFeedbackLoop;LikeClockwork;ModularAugmentation;NaniteDispersionField;Overclocked;PrecisionRifling;RecoilCompensation;Safeguard;SpeedLoader;SyntheticActionEconomy;VitalAim;BarbarousAssault;BrutalCritical;DangerSense;DeathGlare;Faceoff;FuriousCriticals;LandsStride;OverwhelmingPower;PeakPhysicality;RageoftheMountain;RageoftheUndefeated;RagingVitality;RelentlessRage;RipandTear;RootedinAnger;TemperedRetaliation;TerrifyingBellow;UnrelentingRampage;UnarmouredBeast;UnstoppableForce;Aggressive_Rhythm;Discerning_Insult;Distracting_Dissonance;Dueling_Ditties;Echoes_of_Fortitude;Encouraging_Momentum;Engaging_Composition;Guiding_Performance;Harmonious_Aura;Infuriating_Amplification;Inspirational_Resonance;Inspiring_Crescendo;Insufferable_Discord;Melodic_Precision;Mobile_Maestro;Mocksmith;Silver_Tongued_Savant;Soothing_Words;Unprecedented_Encore;Vigorously_Tuned;Aegis;Blessed_Resolve;BloodforBlood;Consecrative_Sacrifice;Divine_Resiliance;Divine_Restoration;Ethereal_Intuition;Flames_of_Repentance;Holy_Fortitude;Guided_Strikes;Holy_Retribution;Immaculate_Ward;Martyrdom;Paradisiacal_Gift;Sacral_Bulwark;Sanctified_Presence;Sanctifying_Aura;Stalwart;Stout_Believer;Venerational_Strikes;Armour_of_Thorns;Combats_Harvest;Earthern_Sentinel;Feral_Precision;Feral_Resiliance;Ferocious_Stand;Instinctive_Transformation;Kindred_Instinct;WildShape_Combat;Natural_Bounty;Natural_Resurgence;Natures_Mercy;Natures_Wrath;Pack_Leader;Primal_Bloodletter;Primal_Surge;Primal_Takedown;Shapechangers_Versatility;Territorial_Dominance;Wild_Stride;Aspect_of_Defiance;Challengers_Call;Charge_of_the_Collective;Duellist;Full_Arsenal;Heavy_Assault;Intuitive_Warning;Ironclad;Iron_Will;Leaders_Momentum;Martial_Fortress;Martial_Reclaim;Merciless;Natural_Born_Leader;Opportunist;Proper_Form;Reckless_Abandon;Sentinels_Protection;Tactical_Retreat;Tunnel_Fighter;Counterflow;Critical_Flow;Dance_of_Flowing_Water;Deflective_Reflex;Dexterous_Ward;Fist_of_Crushing_Rock;Focused_Stream;Fortified_Psyche;Harmonious_Barrage;Harmonious_Defense;Martial_Empowerment;Mystic_Strikes;Opportune_Reversal;Resonance_of_Body;Sagacious_Resilience;Soused_Rampart;Tempestuous_Reprise;Tranquil_Fortitude;Windwaker;Zen_Accuracy;Attonement;Critical_Oath;Death_Sentence;Divine_Health;Divine_Resurgence;Divine_Sense;Divine_Shielding;Holy_Bulwark;Holy_Wrath;Infallible_Beacon;Lay_On_Hands;Oathbound_Renewal;Oath_Channeling;Principle_of_Belief;Repel_the_Damned;Resplendent_Reverb;Smite_Makes_Right;Stalwart_Eruption;Stalwart_Resolve;Visage_of_Sanctity;Ambush_Breaker;Ballistic_Infusion;Beastbonds_Precision;Beastial_Recovery;Blood_Bond;Bounty_Hunter;Close_Quarters_Shooter;Escapist;Explosive_Arrowheads;Hidden_Inventory;Marksmans_Edge;Multiattack_Defense;Natural_Huntsman;Natural_Opportunity;Protective_Bond;Sniper;Superior_Technique;Sure_Shot;Two_Weapon_Fighting;Wanton_Synergy;Cunning_Strikes;Cutthroat;Elusive_Retreat;Elusive_Shadow;Fast_Hands;Fatal_Manoeuvre;Grievous_Wounds;Illusory_Advantage;Light_Footwork;Low_Visibility;Manipulator;Now_You_See_Me;Quick_Reflexes;Reactive_Movement;Sharp_Eyes;CSpectre;Spectral_Hunter;Umbral_Sight;Vanishing_Act;Venomous;ArcaneOverflow;ArcaneOppression;ArcaneReservoir;CharismaticInfusion;CharismaticShield;DormantCharge;ElementalAfterglow;EnchantingInfluence;EphemeralBarrier;EssentialEpiphany;EvasiveWarp;LatentAcuity;MistyEscape;MysticEmpowerment;NaturalVortex;ReactiveReprise;SharedCreation;SorcerousAcumen;SorcerousFocus;VeiledSynergy;BaneofthePact;BindingTransposition;BoundElements;BoundCompulsion;CurseofHellfire;DarkRetaliation;CDevilsSight;EldritchEnervation;EldritchLethargy;EldritchPull;HellishRebuttal;HellboundVision;LuckoftheDevil;MasterofChaos;OneWithShadows;PactProtection;PactStricken;RepellingBlast;ResiliantServitude;ShadeWalker;Arcane_Interruption;Arcane_Reverb;Arcane_Shield;Boon_of_Plumes;Edict_of_Divinity;Elemental_Countercharge;Enchanted_Safeguard;Flames_Riposte;Illusory_Phantasm;Magical_Insight;Mystic_Override;Potent_Cantrips;Potent_Spells;Spellblade;Spellbound_Rebirth;Spell_Surge;Telekinetic_Command;CWarMagic;Wizards_Clarity;Woven_Precision]]

local PROGRESSION_SELECTION_COMPONENTS = {
    "ProgressionPassives",
    "ProgressionMeta",
    "ProgressionFeat",
    "ProgressionReplicatedFeat",
    "LevelUp",
}

---@class PartialRespecDisplayName
---@field DisplayNameHandle string|nil
---@field DisplayNameFallback string
---@field PassiveId string|nil

---@param value string
---@return string|nil
local function HumanizeResourceName(value)
    local name = tostring(value)
    if name:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
        return nil
    end
    name = name:gsub("^ProgressionSubClass_", "")
    name = name:gsub("^ProgressionClass_", "")
    name = name:gsub("^Progression_", "")
    name = name:gsub("^Class_", "")
    name = name:gsub("^SubClass_", "")
    name = name:gsub("^Feat_", "")
    name = name:gsub("([a-z])([A-Z])", "%1 %2")
    name = name:gsub("_", " ")
    return name
end

--- Extracts a localization handle from a TranslatedString.
---@param value TranslatedString
---@return string|nil
local function TranslatedDisplayNameHandle(value)
    if not value or not value.Handle then return nil end

    local valueHandle = value.Handle
    local handle = valueHandle.Handle or valueHandle
    if handle then
        local result = tostring(handle)
        if result ~= "" and not result:find("^ResStr_") then
            return result
        end
    end
    return nil
end

local RESOURCE_TYPES_WITH_NAME = { ClassDescription = true, Feat = true }
local RESOURCE_TYPES_WITH_DISPLAY_NAME = { ClassDescription = true, FeatDescription = true }

--- Resolves a static resource's display name (localized handle + humanized fallback).
---@param resourceGuid string
---@param resourceType string
---@param fallback string
---@return PartialRespecDisplayName
local function ResourceDisplayName(resourceGuid, resourceType, fallback)
    local displayName = {
        DisplayNameHandle = nil,
        DisplayNameFallback = fallback,
    }

    local resource = Ext.StaticData.Get(resourceGuid, resourceType)
    if resource then
        -- Feat has only Name, FeatDescription only DisplayName; ClassDescription has both.
        if RESOURCE_TYPES_WITH_DISPLAY_NAME[resourceType] then
            displayName.DisplayNameHandle = TranslatedDisplayNameHandle(resource.DisplayName)
        end

        if RESOURCE_TYPES_WITH_NAME[resourceType] then
            local resourceName = resource.Name
            if resourceName then
                local name = HumanizeResourceName(resourceName)
                if name then displayName.DisplayNameFallback = name end
            end
        end

        if displayName.DisplayNameHandle then return displayName end
    end
    return displayName
end

---@param classGuid string
---@return PartialRespecDisplayName
local function ClassDisplayName(classGuid)
    if classDisplayNames[classGuid] then
        return classDisplayNames[classGuid]
    end

    classDisplayNames[classGuid] = ResourceDisplayName(classGuid, "ClassDescription", "Unknown class?")
    return classDisplayNames[classGuid]
end

---@param subclassGuid string
---@return PartialRespecDisplayName
local function SubClassDisplayName(subclassGuid)
    return ResourceDisplayName(subclassGuid, "ClassDescription", "Unknown subclass?")
end

--- Builds a FeatId -> FeatDescription guid map once to find localized feat display handles.
local function LoadFeatDescriptionGuids()
    if featDescriptionsLoaded then return end

    if not Ext.StaticData or not Ext.StaticData.GetAll then return end
    local available,descriptionGuids=pcall(Ext.StaticData.GetAll,"FeatDescription")
    if not available or type(descriptionGuids)~="table" or #descriptionGuids==0 then
        RespecStartLog("FEAT_DESCRIPTION_CATALOG_UNAVAILABLE")
        return
    end

    for _, descriptionGuid in ipairs(descriptionGuids) do
        local description = Ext.StaticData.Get(descriptionGuid, "FeatDescription")
        if description then
            local featId = description.FeatId
            if featId then
                local key = tostring(featId)
                if not featDescriptionGuids[key] then
                    featDescriptionGuids[key] = tostring(descriptionGuid)
                end
                -- Some mods register more than one FeatDescription for a
                -- single feat. Never assume the first linked description
                -- reveals its HB secondary selections. Aggregate every
                -- linked localization rule before caching an eligibility
                -- verdict; one complex variant is enough to block GUID swap.
                local handle=TranslatedDisplayNameHandle(description.DisplayName)
                local rule=handle and HB_FEAT_XML_RULES[handle]
                if rule then
                    local existing=hbFeatXmlRuleCache[key]
                    if not existing or existing==false then
                        hbFeatXmlRuleCache[key]=rule
                    elseif existing.Kind~=rule.Kind then
                        hbFeatXmlRuleCache[key]={
                            Kind="MultipleHBChoices",
                            Choices="multiple HB-defined secondary-choice packages"
                        }
                    end
                end
            end
        end
    end

    featDescriptionsLoaded = true
end

--- Feat display name with localized fallback via the linked FeatDescription resource.
---@param featGuid string
---@return PartialRespecDisplayName
local function FeatDisplayName(featGuid)
    if featDisplayNames[featGuid] then
        return featDisplayNames[featGuid]
    end

    local displayName = ResourceDisplayName(featGuid, "Feat", "Unknown feat")
    LoadFeatDescriptionGuids()

    local descriptionGuid = featDescriptionGuids[featGuid]
    if descriptionGuid then
        local descriptionName = ResourceDisplayName(
            descriptionGuid,
            "FeatDescription",
            displayName.DisplayNameFallback
        )
        if descriptionName.DisplayNameHandle then
            displayName.DisplayNameHandle = descriptionName.DisplayNameHandle
        end
    end

    featDisplayNames[featGuid] = displayName
    return displayName
end

-- Resolve a rule using the FeatDescription's exact localization HANDLE.
-- Display names and in-game English text aren't used to infer feat behavior.
local function HBFeatXmlRule(featId)
    featId=tostring(featId or "")
    if hbFeatXmlRuleCache[featId]~=nil then
        return hbFeatXmlRuleCache[featId] or nil
    end
    LoadFeatDescriptionGuids()
    if not featDescriptionsLoaded then
        -- Without the FeatDescription registry we cannot distinguish HB's
        -- custom selectors from apparently simple vanilla static feats.
        return {Kind="UnknownHBFeat",Choices="unavailable HB feat metadata"}
    end
    -- LoadFeatDescriptionGuids examined ALL descriptions and populated
    -- every linked HB rule; if none match, the feat is not proven simple.
    -- Its live StaticData selectors and requirements remain authoritative.
    local rule=hbFeatXmlRuleCache[featId]
    hbFeatXmlRuleCache[featId]=rule or false
    return rule or nil
end

--- Adds passive IDs from either an array-like value or a delimited string.
---@param destination table<string, boolean>
---@param value any
local function AddPassiveIds(destination, value)
    if type(value) == "string" then
        for passiveId in value:gmatch("[^,;]+") do
            passiveId = passiveId:match("^%s*(.-)%s*$")
            if passiveId ~= "" then destination[passiveId] = true end
        end
    elseif type(value) == "table" then
        for key, entry in pairs(value) do
            if type(key) == "string" and type(entry) == "boolean" and entry then
                destination[key] = true
            end
            AddPassiveIds(destination, entry)
        end
    end
end

--- Loads the union of the HB class-passive lists once.
---@return table<string, boolean>
local function GetHBClassPassives()
    if hbClassPassives then return hbClassPassives end

    hbClassPassives = {}
    AddPassiveIds(hbClassPassives, HB_CLASS_PASSIVE_IDS)
    return hbClassPassives
end

--- Extracts a localization handle from the PassiveData stat format.
---@param value any
---@return string|nil
local function PassiveDisplayNameHandle(value)
    if type(value) == "string" then
        local handle = value:match("^([^;]+)")
        if handle and handle ~= "" and not handle:find("^ResStr_") then
            return handle
        end
    elseif type(value) == "table" then
        return TranslatedDisplayNameHandle(value)
    end
    return nil
end

---@param passiveId string
---@return PartialRespecDisplayName
local function PassiveDisplayName(passiveId)
    if passiveDisplayNames[passiveId] then
        return passiveDisplayNames[passiveId]
    end

    local displayName = {
        DisplayNameHandle = nil,
        DisplayNameFallback = HumanizeResourceName(passiveId) or passiveId,
        PassiveId = passiveId,
    }
    local passive = Ext.Stats.Get(passiveId)
    if passive then
        displayName.DisplayNameHandle = PassiveDisplayNameHandle(passive.DisplayName)
    end

    passiveDisplayNames[passiveId] = displayName
    return displayName
end

--- Recursively finds selected passive IDs in a serialized progression component.
---@param value any
---@param allowed table<string, boolean>
---@param add fun(passiveId: string)
local function FindSelectedPassives(value, allowed, add)
    if type(value) == "string" then
        for passiveId in value:gmatch("[^,;]+") do
            passiveId = passiveId:match("^%s*(.-)%s*$")
            if allowed[passiveId] then add(passiveId) end
        end
    elseif type(value) == "table" then
        for key, entry in pairs(value) do
            if type(key) == "string" and allowed[key] then add(key) end
            FindSelectedPassives(entry, allowed, add)
        end
    end
end

--- Collects only player-selected passives belonging to HB class-choice lists.
---@param character EntityHandle
---@param levelUps table|nil
---@param cutoff integer
---@return table
local function ClassPassivesThroughLevel(character, levelUps, cutoff)
    local results = {}
    local seen = {}
    local allowed = GetHBClassPassives()
    local container = character and character.ProgressionContainer
    local buckets = container and container.Progressions
    if not buckets then return results end

    local function Add(passiveId)
        if seen[passiveId] then return end
        seen[passiveId] = true
        results[#results + 1] = PassiveDisplayName(passiveId)
    end

    for level = 1, cutoff do
        -- CCLevelUp is the most direct record of player selections on builds
        -- that replicate passive choices into the level-up history.
        FindSelectedPassives(levelUps and levelUps[level], allowed, Add)

        for _, progressionEntity in ipairs(buckets[level] or {}) do
            -- SE builds expose the choice in different progression components.
            -- Search every component capable of carrying level-up selections.
            for _, componentName in ipairs(PROGRESSION_SELECTION_COMPONENTS) do
                local component = progressionEntity[componentName]
                if component then
                    local ok, serialized = pcall(Ext.Types.Serialize, component)
                    if ok then
                        FindSelectedPassives(serialized, allowed, Add)
                    end
                end
            end
        end
    end
    return results
end

---@param guid any
---@return boolean
local function IsValidGuid(guid)
    return guid ~= nil and tostring(guid) ~= "00000000-0000-0000-0000-000000000000"
end

--- These are independent of the class-passive list: the game saves them as
--- ordinary selections under CCLevelUp.LevelUps[n].Upgrades.Passives with
--- SelectorId = "ExtraActions". The selected class level may differ from n
--- on multiclassed characters, so the containing history index is authoritative.
local function ExtraResourceSelectionsAtLevel(levelUp)
    local result = {}
    local seen = {}
    local upgrades = levelUp and levelUp.Upgrades
    local selections = upgrades and upgrades.Passives
    for _, selection in ipairs(selections or {}) do
        if tostring(selection.SelectorId or "") == "ExtraActions" then
            for _, passive in ipairs(selection.Passives or {}) do
                local id = tostring(passive)
                if id:find("^ExtraActions_") and not seen[id] then
                    seen[id] = true
                    result[#result + 1] = id
                end
            end
        end
    end
    return result
end

--- Cumulative display only; no change to how Partial Respec rebuilds a level.
local function ExtraResourcesThroughLevel(levelUps, cutoff)
    local result = {}
    for characterLevel = 1, cutoff do
        for _, passiveId in ipairs(ExtraResourceSelectionsAtLevel(levelUps and levelUps[characterLevel])) do
            result[#result + 1] = {
                Level = characterLevel,
                PassiveId = passiveId,
            }
        end
    end
    return result
end


-- Resolve the ORIGINAL choice list when the game exposes it. Some SE builds
-- return a non-Lua container/string proxy, and some modded lists are missing
-- from the runtime lookup. A narrow class-list fallback is available only for
-- GUIDs verified in HB's saved history; unknown lists are always read-only.
-- Snapshot from the supplied HomeBrew PassiveLists.lsx. All replacements are
-- still checked against the recorded selector/list and live passive stat.
-- Runtime static data wins whenever it exposes a usable list.
local HB_PASSIVE_LIST_FALLBACKS = {
    ["cf44a7c1-3fcb-4fb6-8624-45dd433c11b1"] = {
        "Personality_None", "Personality_Barbarian", "Personality_Bard", "Personality_Cleric",
        "Personality_Druid", "Personality_Fighter", "Personality_Monk", "Personality_Ranger",
        "Personality_Rogue", "Personality_Sorcerer", "Personality_Warlock", "Personality_Wizard",
    },
    ["15eff335-46df-4268-9eea-aabcb6c13025"] = {
        "CT_None", "CT_AdrenalineSurge", "CT_BlindEmotions", "CT_BloodyResults",
        "CT_BorrowedTime", "CT_BreatheDeep", "CT_ConfidentlyIncorrect", "CT_CriticalLoss",
        "CT_Crybaby", "CT_DelusionsintheDark", "CT_Gambler", "CT_GentleGiant",
        "CT_GildedPilfer", "CT_GlassCannon", "CT_HandsofCalamity", "CT_HastyReflexes",
        "CT_Haymaker", "CT_HealthyChills", "CT_HeavyHanded", "CT_Hyperfixation",
        "CT_Ironbourne", "CT_ImmovableBoulder", "CT_Lefty", "CT_LetMeSoloThem",
        "CT_LoneWolf", "CT_Narcoleptic", "CT_NaturalMedium", "CT_Overcharged",
        "CT_OverlyDifficult", "CT_Packing", "CT_PlanarSkipping", "CT_ReactiveLoss",
        "CT_Reckless", "CT_SlowRoller", "CT_SplitFocus", "CT_Stinky",
        "CT_SunlightAversion", "CT_Unhinged", "CT_UnstableSource", "CT_WaningImmortality",
        "CT_Wretch",
    },
    ["4607f9c7-335c-443f-b075-a3f068c20a0d"] = {
        "AT_None", "AT_ArcanePrecision", "AT_ChaoticFortune", "AT_CombatMastery",
        "AT_ControlledAggro", "AT_DeepenedResolve", "AT_EmpoweredSummons", "AT_FortifiedArmour",
        "AT_ImposingWill", "AT_IronBreaker", "AT_IronFists", "AT_MartialBalance",
        "AT_MartialPrecision", "AT_MeasuredArcana", "AT_QuickReflexes", "AT_ReactiveRetribution",
        "AT_RestorativeTouch", "AT_TemperedBody", "AT_TemperedMind", "AT_UncheckedForce",
        "AT_WeaveBreaker",
    },
    ["582afedf-26bb-4bdb-99f3-add25e681691"] = {
        "ExtraActions_Action", "ExtraActions_BonusAction", "ExtraActions_Reaction",
    },
    ["a8257cf3-7c6b-4627-a77c-760a064fc201"] = {
        "AdaptivePlating", "ArcaneCalibrationMatrix", "AutomatedArcaneSuppression", "CastleDefense",
        "DeadZoneCalibration", "ElementalPayload", "EmergencyPowerCell", "FailsafeInjection",
        "IncendiaryRounds", "KineticFeedbackLoop", "LikeClockwork", "ModularAugmentation",
        "NaniteDispersionField", "Overclocked", "PrecisionRifling", "RecoilCompensation",
        "Safeguard", "SpeedLoader", "SyntheticActionEconomy", "VitalAim",
    },
    ["3069a836-a0fd-467d-afaf-555ab1192d24"] = {
        "AdaptiveShielding", "ArmourReinforcement", "CalmingSubroutine", "ConcentrationLock",
        "CriticalDampener", "DamageAmplifier", "DefensiveCalibration", "EmergencyPlating",
        "EvasiveProtocol", "HealingOverride", "KineticRepulsorField", "MaximumYield",
        "OutputContingency", "PrecisionBoost", "PredictiveTargetingModule", "ReactiveOverload",
        "ResistanceOverride", "SpellCalibrationSequence", "SpellSlotBypass", "StabilityMatrix",
    },
    ["842b6948-adb0-4ce1-a55e-436eacd8693c"] = {
        "ArmourCompromise", "ConcentrationBreach", "CriticalLockout", "CyberneticPsychosis",
        "DefensiveDegredation", "DirectSystemDamage", "ExposedSystemInfo", "GraviticVortex",
        "HealingLockout", "MinimumYield", "MobilityLock", "OutputLimiter",
        "PrecisionDegredation", "ReactionSuppression", "SaveDestabilization", "ShieldCollapse",
        "SignalSilence", "SpellInterference", "TargetingDisruption", "WeaponDampening",
    },
    ["d8183f3c-9c62-40b7-9418-e7ad07a8204e"] = {
        "BarbarousAssault", "BrutalCritical", "DangerSense", "DeathGlare",
        "Faceoff", "FuriousCriticals", "LandsStride", "OverwhelmingPower",
        "PeakPhysicality", "RageoftheMountain", "RageoftheUndefeated", "RagingVitality",
        "RelentlessRage", "RipandTear", "RootedinAnger", "TemperedRetaliation",
        "TerrifyingBellow", "UnrelentingRampage", "UnarmouredBeast", "UnstoppableForce",
    },
    ["2e8c5dba-f49c-4f24-a850-05e61aefb4ef"] = {
        "Aggressive_Rhythm", "Discerning_Insult", "Distracting_Dissonance", "Dueling_Ditties",
        "Echoes_of_Fortitude", "Encouraging_Momentum", "Engaging_Composition", "Guiding_Performance",
        "Harmonious_Aura", "Infuriating_Amplification", "Inspirational_Resonance", "Inspiring_Crescendo",
        "Insufferable_Discord", "Melodic_Precision", "Mobile_Maestro", "Mocksmith",
        "Silver_Tongued_Savant", "Soothing_Words", "Unprecedented_Encore", "Vigorously_Tuned",
    },
    ["137c5bd5-c5a9-4185-aec9-70a583191f17"] = {
        "Aegis", "Blessed_Resolve", "BloodforBlood", "Consecrative_Sacrifice",
        "Divine_Resiliance", "Divine_Restoration", "Ethereal_Intuition", "Flames_of_Repentance",
        "Holy_Fortitude", "Guided_Strikes", "Holy_Retribution", "Immaculate_Ward",
        "Martyrdom", "Paradisiacal_Gift", "Sacral_Bulwark", "Sanctified_Presence",
        "Sanctifying_Aura", "Stalwart", "Stout_Believer", "Venerational_Strikes",
    },
    ["82745b68-e0f8-49a2-a147-7ccac142b7d9"] = {
        "Armour_of_Thorns", "Combats_Harvest", "Earthern_Sentinel", "Feral_Precision",
        "Feral_Resiliance", "Ferocious_Stand", "Instinctive_Transformation", "Kindred_Instinct",
        "WildShape_Combat", "Natural_Bounty", "Natural_Resurgence", "Natures_Mercy",
        "Natures_Wrath", "Pack_Leader", "Primal_Bloodletter", "Primal_Surge",
        "Primal_Takedown", "Shapechangers_Versatility", "Territorial_Dominance", "Wild_Stride",
    },
    ["da3203d8-750a-4de1-b8eb-1eccfccddf46"] = {
        "Aspect_of_Defiance", "Challengers_Call", "Charge_of_the_Collective", "Duellist",
        "Full_Arsenal", "Heavy_Assault", "Intuitive_Warning", "Ironclad",
        "Iron_Will", "Leaders_Momentum", "Martial_Fortress", "Martial_Reclaim",
        "Merciless", "Natural_Born_Leader", "Opportunist", "Proper_Form",
        "Reckless_Abandon", "Sentinels_Protection", "Tactical_Retreat", "Tunnel_Fighter",
    },
    ["76345169-ecc1-4571-bcad-e67afc96f87f"] = {
        "ElementalFletching_Acid", "ElementalFletching_Cold", "ElementalFletching_Fire", "ElementalFletching_Lightning",
        "ElementalFletching_Necrotic", "ElementalFletching_Poison", "ElementalFletching_Psychic", "ElementalFletching_Radiant",
        "ElementalFletching_Thunder",
    },
    ["e51a2ef5-3663-43f9-8e74-5e28520323f1"] = {
        "BaitAndSwitch", "Brace", "ChargeManeuver", "ChallengersStrike",
        "CommanderStrike_Maneuver", "DisarmingAttack", "DistractingStrike", "EvasiveFootwork",
        "FeintingAttack", "LungingAttack", "ManeuveringAttack", "MenacingAttack",
        "Parry", "PrecisionAttack", "PushingAttack", "QuickToss",
        "Rally", "Riposte", "SweepingAttack", "TripAttack",
    },
    ["c3a4d60a-27d2-4a13-b3fd-fd9490bee8ce"] = {
        "Frontier_AdvantageousStrike", "Frontier_Backbreaker", "Frontier_BefuddlingStrike", "Frontier_BlindingStrike",
        "Frontier_BraceMelee", "Frontier_Cleave", "Frontier_ConcussiveSmash", "Frontier_CrowningStrike",
        "Frontier_DisarmingStrike", "Frontier_Flourish", "Frontier_GrandSlam", "Frontier_Heartstopper",
        "Frontier_ThrowJavelin", "Frontier_Lacerate", "Frontier_LobotomizingStrike", "Frontier_MaimingStrike",
        "Frontier_PiercingStrike", "Frontier_PommelStrike", "Frontier_Prepare", "Frontier_RushAttack",
        "Frontier_SilencingStrike", "Frontier_TerrifyingStrikeStrike", "Frontier_Topple", "Frontier_UnarmedStrike",
        "Frontier_Vortex", "Frontier_WeakeningStrike", "Frontier_BlindingShot", "Frontier_BraceRanged",
        "Frontier_HamstringShot", "Frontier_MobileShot", "Frontier_PiercingShot",
    },
    ["1cafd528-b848-477b-9a3e-adfe4a989970"] = {
        "Counterflow", "Critical_Flow", "Dance_of_Flowing_Water", "Deflective_Reflex",
        "Dexterous_Ward", "Fist_of_Crushing_Rock", "Focused_Stream", "Fortified_Psyche",
        "Harmonious_Barrage", "Harmonious_Defense", "Martial_Empowerment", "Mystic_Strikes",
        "Opportune_Reversal", "Resonance_of_Body", "Sagacious_Resilience", "Soused_Rampart",
        "Tempestuous_Reprise", "Tranquil_Fortitude", "Windwaker", "Zen_Accuracy",
    },
    ["0cdf39f8-8098-4c6d-8741-66f1877e47ba"] = {
        "Smite_Blinding", "Smite_Branding", "Smite_Searing", "Smite_Staggering",
        "Smite_Thunderous", "Smite_Wrathful",
    },
    ["27e37640-a012-40f0-8ced-a398640dac75"] = {
        "Attonement", "Critical_Oath", "Death_Sentence", "Divine_Health",
        "Divine_Resurgence", "Divine_Sense", "Divine_Shielding", "Holy_Bulwark",
        "Holy_Wrath", "Infallible_Beacon", "Lay_On_Hands", "Oathbound_Renewal",
        "Oath_Channeling", "Principle_of_Belief", "Repel_the_Damned", "Resplendent_Reverb",
        "Smite_Makes_Right", "Stalwart_Eruption", "Stalwart_Resolve", "Visage_of_Sanctity",
    },
    ["659a1bdf-b0e3-40d7-aa6d-f64cc1f18404"] = {
        "Oath_Vengeance", "Oath_Crown", "Oath_Ancients", "Oath_Devotion",
    },
    ["fed4c4e9-fbe0-41d6-abc1-ee3dc5b80302"] = {
        "Ambush_Breaker", "Ballistic_Infusion", "Beastbonds_Precision", "Beastial_Recovery",
        "Blood_Bond", "Bounty_Hunter", "Close_Quarters_Shooter", "Escapist",
        "Explosive_Arrowheads", "Hidden_Inventory", "Marksmans_Edge", "Multiattack_Defense",
        "Natural_Huntsman", "Natural_Opportunity", "Protective_Bond", "Sniper",
        "Superior_Technique", "Sure_Shot", "Two_Weapon_Fighting", "Wanton_Synergy",
    },
    ["20a80074-ba3e-412d-8f2d-ca3ea234cb94"] = {
        "Arrow_Acid", "Arrow_FiendSlaying", "Arrow_Antimagic", "Arrow_HumanoidSlaying",
        "Arrow_MonstrositySlaying", "Arrow_Darkness", "Arrow_Fire", "Arrow_ConstructSlaying",
        "Arrow_Ice", "Arrow_WraithsEmbrace", "Arrow_Lightning", "Arrow_ElementalSlaying",
        "Arrow_Ricochet", "Arrow_Piercing", "Arrow_Detonation", "Arrow_Dispelling",
        "Arrow_AberrationSlaying", "Arrow_BeastSlaying", "Arrow_Teleportation", "Arrow_UndeadSlaying",
    },
    ["da3203d8-750a-4de1-b8eb-1eccfcc6a911"] = {
        "Cunning_Strikes", "Cutthroat", "Elusive_Retreat", "Elusive_Shadow",
        "Fast_Hands", "Fatal_Manoeuvre", "Grievous_Wounds", "Illusory_Advantage",
        "Light_Footwork", "Low_Visibility", "Manipulator", "Now_You_See_Me",
        "Quick_Reflexes", "Reactive_Movement", "Sharp_Eyes", "CSpectre",
        "Spectral_Hunter", "Umbral_Sight", "Vanishing_Act", "Venomous",
    },
    ["49704931-e47b-4ce6-abc6-dfa7ba640752"] = {
        "Metamagic_Maximized", "Metamagic_Quickened", "Metamagic_Tripled", "Metamagic_Tuned",
        "Metamagic_Absorbing", "Metamagic_Bloodied", "Metamagic_Careful", "Metamagic_Defensive",
        "Metamagic_Distant", "Metamagic_Dreadful", "Metamagic_Empowered", "Metamagic_Extended",
        "Metamagic_Favored", "Metamagic_Heightened", "Metamagic_Piercing", "Metamagic_Regenerative",
        "Metamagic_Restorative", "Metamagic_Seeking", "Metamagic_Subtle", "Metamagic_Tempestuous",
    },
    ["c3506532-36eb-4d18-823e-497a537a9619"] = {
        "ArcaneOverflow", "ArcaneOppression", "ArcaneReservoir", "CharismaticInfusion",
        "CharismaticShield", "DormantCharge", "ElementalAfterglow", "EnchantingInfluence",
        "EphemeralBarrier", "EssentialEpiphany", "EvasiveWarp", "LatentAcuity",
        "MistyEscape", "MysticEmpowerment", "NaturalVortex", "ReactiveReprise",
        "SharedCreation", "SorcerousAcumen", "SorcerousFocus", "VeiledSynergy",
    },
    ["c69c33a2-671c-46e1-a92c-656fe64ed447"] = {
        "DraconicAncestry_Black", "DraconicAncestry_Blue", "DraconicAncestry_Brass", "DraconicAncestry_Bronze",
        "DraconicAncestry_Copper", "DraconicAncestry_Gold", "DraconicAncestry_Green", "DraconicAncestry_Red",
        "DraconicAncestry_Silver", "DraconicAncestry_White", "DraconicAncestry_Amethyst", "DraconicAncestry_Crystal",
        "DraconicAncestry_Emerald", "DraconicAncestry_Sapphire", "DraconicAncestry_Topaz",
    },
    ["fd7736fa-5c64-475e-a4c9-f4061690d8c4"] = {
        "BaneofthePact", "BindingTransposition", "BoundElements", "BoundCompulsion",
        "CurseofHellfire", "DarkRetaliation", "CDevilsSight", "EldritchEnervation",
        "EldritchLethargy", "EldritchPull", "HellishRebuttal", "HellboundVision",
        "LuckoftheDevil", "MasterofChaos", "OneWithShadows", "PactProtection",
        "PactStricken", "RepellingBlast", "ResiliantServitude", "ShadeWalker",
    },
    ["ceec377d-0888-4226-a36a-9e3fa1c91d4f"] = {
        "Dialogue_Archfey", "Dialogue_Fiend", "Dialogue_OldOne", "Dialogue_HexBlade",
    },
    ["e5ab4424-e30b-4752-b280-51a5c77bc9c3"] = {
        "Arcane_Interruption", "Arcane_Reverb", "Arcane_Shield", "Boon_of_Plumes",
        "Edict_of_Divinity", "Elemental_Countercharge", "Enchanted_Safeguard", "Flames_Riposte",
        "Illusory_Phantasm", "Magical_Insight", "Mystic_Override", "Potent_Cantrips",
        "Potent_Spells", "Spellblade", "Spellbound_Rebirth", "Spell_Surge",
        "Telekinetic_Command", "CWarMagic", "Wizards_Clarity", "Woven_Precision",
    },
    ["b9149c8e-52c8-46e5-9cb6-fc39301c05fe"] = {
        "ASI_Strength", "ASI_Dexterity", "ASI_Constitution", "ASI_Intelligence",
        "ASI_Wisdom", "ASI_Charisma",
    },
    ["f6b6e71f-79b1-4ba3-8fd8-ee38a44d3d39"] = {
        "ElementalAdept_Acid", "ElementalAdept_Cold", "ElementalAdept_Fire", "ElementalAdept_Force",
        "ElementalAdept_Lightning", "ElementalAdept_Necrotic", "ElementalAdept_Poison", "ElementalAdept_Psychic",
        "ElementalAdept_Radiant", "ElementalAdept_Thunder",
    },
}
local EDITOR_PROTECTED_SELECTORS = {
    ExtraActions = true, Archetypes = true, Traits = true, Personality = true,
}
local editorPassiveListCache = {}
local editorPassiveListResolution = {}
local function ResolvePassiveList(listGuid)
    listGuid = tostring(listGuid or "")
    if listGuid == "" or listGuid == "00000000-0000-0000-0000-000000000000" then return nil end
    if editorPassiveListCache[listGuid] then return editorPassiveListCache[listGuid] end
    local ids, seen = {}, {}
    local resolution = {Source="Unavailable", StaticLookup="Not attempted", RawType="unknown"}
    local function Add(id)
        if id == nil then return end
        id = tostring(id):match("^%s*(.-)%s*$")
        if id and id ~= "" and id:match("^[%w_]+$") and not seen[id] then
            local ok, stat = pcall(Ext.Stats.Get, id)
            if ok and stat then seen[id] = true; ids[#ids+1] = id end
        end
    end
    local function AddDelimited(value)
        local text = tostring(value or "")
        for id in text:gmatch("[^,;]+") do Add(id) end
    end
    local function AddContainer(value, depth)
        depth = depth or 0
        if depth > 3 or value == nil then return end
        local kind = type(value)
        if kind == "string" then AddDelimited(value)
        elseif kind == "table" then
            for _, item in ipairs(value) do AddContainer(item, depth+1) end
            -- Support maps containing passive identifiers as keys.
            for key, item in pairs(value) do
                if type(key) == "string" and item == true then Add(key) end
            end
        elseif kind == "userdata" then
            -- Some SE versions wrap Passives in a userdata array rather than a table.
            local ok, count = pcall(function() return #value end)
            if ok and type(count) == "number" and count >= 1 and count <= 512 then
                for index = 1, count do
                    local indexed, item = pcall(function() return value[index] end)
                    if indexed then AddContainer(item, depth+1) end
                end
            else
                -- FixedString / LSString userdata often stringify to their contents.
                AddDelimited(value)
            end
        end
    end
    local ok, resource = pcall(Ext.StaticData.Get, listGuid, "PassiveList")
    if ok and resource then
        resolution.StaticLookup = "Found"
        local found, raw = pcall(function() return resource.Passives end)
        if found and raw ~= nil then
            resolution.RawType = type(raw)
            AddContainer(raw)
        else
            resolution.StaticLookup = "Missing Passives property"
        end
    else
        resolution.StaticLookup = ok and "Missing resource" or "Lookup error"
    end
    if #ids > 0 then
        resolution.Source = "StaticData"
    else
        -- This is a strictly GUID-scoped HB catalog, not a global list of passives.
        -- It handles historical selections on Script Extenders that don't expose
        -- the list. The same restricted catalog is checked again on the server.
        for _, id in ipairs(HB_PASSIVE_LIST_FALLBACKS[listGuid] or {}) do Add(id) end
        if #ids > 0 then resolution.Source = "HB supplied LSX catalog" end
    end
    resolution.CandidateCount = #ids
    editorPassiveListResolution[listGuid] = resolution
    if #ids == 0 then return nil end
    local result = {Ids=ids, Set=seen}
    editorPassiveListCache[listGuid] = result
    return result
end

-- Elemental Adept is the only known HB feat whose saved passive-choice
-- selector is BLANK. The user's read-only feat report established its exact
-- two-element list, its Feat level-up history, and matching feat progression.
-- Admit that historical row only when all of these narrow conditions hold.
-- Exact two-passive HB feat rules: Feats.lsx + FeatDescriptions.lsx.
-- Only these static selectors have a replay constructor; all others fail closed.
local HB_PASSIVE_PAIR_FEATS = {
    ["d215b9ad-9753-4d74-8ff9-24bf1dce53d6"]={Name="AbilityImprovement",List="b9149c8e-52c8-46e5-9cb6-fc39301c05fe",Selector="FeatASI",Rule="AbilityChoices"},
    ["56c3c247-35cf-4ffd-86dd-7d249cc1808f"]={Name="ClassDivergence_Barbarian",List="d8183f3c-9c62-40b7-9418-e7ad07a8204e",Selector="",Rule="PassiveChoices"},
    ["cec2d95b-451c-40f8-8e17-9e547d363e8e"]={Name="ClassDivergence_Bard",List="2e8c5dba-f49c-4f24-a850-05e61aefb4ef",Selector="",Rule="PassiveChoices"},
    ["c09815f7-282b-4ccf-bd89-a51caa1b550f"]={Name="ClassDivergence_Cleric",List="137c5bd5-c5a9-4185-aec9-70a583191f17",Selector="",Rule="PassiveChoices"},
    ["7bc235ac-7eeb-49d3-8249-c3313d87af75"]={Name="ClassDivergence_Druid",List="82745b68-e0f8-49a2-a147-7ccac142b7d9",Selector="",Rule="PassiveChoices"},
    ["0de08fff-ab18-442f-a0b1-f53e7be04c03"]={Name="ClassDivergence_Fighter",List="da3203d8-750a-4de1-b8eb-1eccfccddf46",Selector="",Rule="PassiveChoices"},
    ["b441c722-e4d4-4702-861a-039bfd77c124"]={Name="ClassDivergence_Monk",List="1cafd528-b848-477b-9a3e-adfe4a989970",Selector="",Rule="PassiveChoices"},
    ["d84c7f36-8c5b-4b17-b95a-e1da725f9004"]={Name="ClassDivergence_Paladin",List="27e37640-a012-40f0-8ced-a398640dac75",Selector="",Rule="PassiveChoices"},
    ["a533fde7-ee0a-46ce-92e2-9763201a54d2"]={Name="ClassDivergence_Ranger",List="fed4c4e9-fbe0-41d6-abc1-ee3dc5b80302",Selector="",Rule="PassiveChoices"},
    ["4f744a6e-8589-4a46-89ab-a95415a73245"]={Name="ClassDivergence_Rogue",List="da3203d8-750a-4de1-b8eb-1eccfcc6a911",Selector="",Rule="PassiveChoices"},
    ["28e5fed3-bd41-4b74-ab48-b8e824ad3443"]={Name="ClassDivergence_Sorcerer",List="c3506532-36eb-4d18-823e-497a537a9619",Selector="",Rule="PassiveChoices"},
    ["1e1a9a4d-38f4-4a05-b080-d32c2b872250"]={Name="ClassDivergence_Warlock",List="fd7736fa-5c64-475e-a4c9-f4061690d8c4",Selector="",Rule="PassiveChoices"},
    ["93d41226-d7af-495c-b023-08a6af077962"]={Name="ClassDivergence_Wizard",List="e5ab4424-e30b-4752-b280-51a5c77bc9c3",Selector="",Rule="PassiveChoices"},
    ["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={Name="ClassDivergence_Artificer",List="a8257cf3-7c6b-4627-a77c-760a064fc201",Selector="",Rule="PassiveChoices"},
}

local HB_ELEMENTAL_ADEPT_LIST = "f6b6e71f-79b1-4ba3-8fd8-ee38a44d3d39"
-- Ability Improvement uses the six HB ASI passives, not the vanilla +1/+2
-- ability selector. Its descriptor calls for exactly two distinct abilities.
-- Only inspect a blank-selector feat-owned row when the recorded list,
-- known passive IDs, and exact feat-owned progression agree. This DOES NOT
-- infer the materialized ability-bonus components for a newly added feat.
local HB_ABILITY_IMPROVEMENT_LIST = "b9149c8e-52c8-46e5-9cb6-fc39301c05fe"
local HB_ABILITY_IMPROVEMENT_IDS = {
    ASI_Strength=true, ASI_Dexterity=true, ASI_Constitution=true,
    ASI_Intelligence=true, ASI_Wisdom=true, ASI_Charisma=true,
}
local function IsRecordedAbilityImprovementRow(levelUp,selection)
    if not levelUp or not selection then return false end
    local rule=HBFeatXmlRule(levelUp.Feat)
    if not rule or rule.Kind~="AbilityChoices" or tostring(selection.Type or "")~="Feat"
        or (tostring(selection.SelectorId or "")~="" and tostring(selection.SelectorId or "")~="FeatASI")
        or tostring(selection.PassiveList or "")~=HB_ABILITY_IMPROVEMENT_LIST
        or (selection.ReplacePassives and #selection.ReplacePassives>0) then
        return false
    end
    local list=ResolvePassiveList(HB_ABILITY_IMPROVEMENT_LIST)
    if not list or #(selection.Passives or {})~=2 then return false end
    local seen={}
    for _,id in ipairs(selection.Passives) do
        id=tostring(id)
        if not HB_ABILITY_IMPROVEMENT_IDS[id] or not list.Set[id] or seen[id] then
            return false
        end
        seen[id]=true
    end
    return true
end

local function IsRecordedElementalAdeptRow(levelUp,selection)
    if not levelUp or not selection then return false end
    if tostring(selection.SelectorId or "")~=""
        or tostring(selection.PassiveList or "")~=HB_ELEMENTAL_ADEPT_LIST
        or tostring(selection.Type or "")~="Feat"
        or (selection.ReplacePassives and #selection.ReplacePassives>0) then
        return false
    end
    local rule=HBFeatXmlRule(levelUp.Feat)
    if not rule or rule.Kind~="ElementChoices" then return false end
    local list=ResolvePassiveList(HB_ELEMENTAL_ADEPT_LIST)
    if not list or #(selection.Passives or {})~=2 then return false end
    local picked={}
    for _,id in ipairs(selection.Passives) do
        id=tostring(id)
        if not id:match("^ElementalAdept_[%a]+$") or not list.Set[id] or picked[id] then
            return false
        end
        picked[id]=true
    end
    return true
end

-- Only accept an existing blank-selector Class Specialist row when its
-- exact feat/list/slot identity is verified. Feat component attribution is
-- checked independently in the level summary and authoritative replay.
local function IsRecordedPassivePairRow(levelUp,selection)
    local config=levelUp and HB_PASSIVE_PAIR_FEATS[tostring(levelUp.Feat or "")]
    if not config or not selection then return false end
    local list=ResolvePassiveList(config.List)
    if not list then return false end
    local function IsOwned(row)
        return row and tostring(row.Type or "")=="Feat"
            and tostring(row.Class or "")==tostring(levelUp.Feat)
            and tostring(row.PassiveList or "")==config.List
            and (tostring(row.SelectorId or "")==""
                or tostring(row.SelectorId or "")==config.Selector)
            and not (row.ReplacePassives and #row.ReplacePassives>0)
    end
    if not IsOwned(selection) then return false end
    local slots={}
    local total,matched=0,0
    for _,row in ipairs(levelUp.Upgrades and levelUp.Upgrades.Passives or {}) do
        if IsOwned(row) then
            local size=#(row.Passives or {})
            if size~=1 and size~=2 then return false end
            matched=matched+1
            total=total+size
            for _,id in ipairs(row.Passives or {}) do
                id=tostring(id)
                if not list.Set[id] or slots[id] then return false end
                slots[id]=true
            end
        elseif tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==tostring(levelUp.Feat) then
            return false -- secondary feat rows with unknown owner
        end
    end
    -- Accept exact 2-in-1 and split 1+1 recorded HB passive selectors.
    return total==2 and (matched==1 or matched==2)
end

local function EditablePassiveGroupsAtLevel(levelUp)
    local groups = {}
    for _, selection in ipairs(levelUp and levelUp.Upgrades and levelUp.Upgrades.Passives or {}) do
        local selector = tostring(selection.SelectorId or "")
        local listGuid = tostring(selection.PassiveList or "")
        -- Skip creation-only picks and ExtraResources (separate tested editor).
        if (selector ~= "" or IsRecordedElementalAdeptRow(levelUp,selection)
            or IsRecordedAbilityImprovementRow(levelUp,selection)
            or IsRecordedPassivePairRow(levelUp,selection))
            and not EDITOR_PROTECTED_SELECTORS[selector]
            and not (selection.ReplacePassives and #selection.ReplacePassives > 0) then
            local list = ResolvePassiveList(listGuid)
            local picked, valid = {}, list ~= nil
            for _, id in ipairs(selection.Passives or {}) do
                id = tostring(id)
                picked[#picked+1] = id
                if not (list and list.Set[id]) then valid = false end
            end
            if valid and #picked > 0 and #list.Ids > 0 then
                local options = {}
                for _, id in ipairs(list.Ids) do options[#options+1] = PassiveDisplayName(id) end
                groups[#groups+1] = {
                    SelectorId = selector, PassiveList = listGuid,
                    Picked = picked, Options = options,
                }
            end
        end
    end
    return groups
end

--- Read-only reconstruction of choices *at* one level. This deliberately does not
--- mutate the character or infer undocumented fields from progression components.
--- CCLevelUp is authoritative for class/subclass/feat history; the HB passive
--- list is searched in both CCLevelUp and the corresponding progression bucket.
---@param character EntityHandle
---@param levelUps table|nil
---@param level integer
---@return table
-- Experimental multi-category historical choices.  The original passive replay
-- remains independent; these options carry exact provenance for validation.
local HB_SKILL_NAMES = {
 "Acrobatics","AnimalHandling","Arcana","Athletics","Deception","History",
 "Insight","Intimidation","Investigation","Medicine","Nature","Perception",
 "Performance","Persuasion","Religion","SleightOfHand","Stealth","Survival"
}
-- The naturally selected Multifaceted skill selector is a single four-slot
-- SkillList. On some Script Extender builds its Skills entries are C++ structs
-- the static-data reader cannot enumerate. The HB feat explicitly offers
-- four ordinary skill proficiencies, so only this exact recorded list is
-- eligible for the 18-skill fallback. Unknown skill lists remain fail-closed.
local HB_MULTIFACETED_SKILL_LIST="f974ebd6-3725-4b90-bb5c-2b647d41615d"
local HB_MULTIFACETED_SKILL_FEAT="be0889d2-f9aa-472d-b942-592bff0f1ef3"
local HB_ABILITY_NAMES = { "Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma" }
local HB_ABILITY_INDICES = { Strength=2, Dexterity=3, Constitution=4,
    Intelligence=5, Wisdom=6, Charisma=7 }
local HB_SPELL_LIST_CATALOG = {
    ["ffad33d2-e725-4655-ba80-0bc91e8002b3"] = {"Projectile_AcidSplash","Projectile_ArcaneBarrage","Projectile_ArcaneSpheres","Shout_BladeSurge","Shout_BladeWard","Target_ChillTouch","Projectile_Cragrain","Target_CreateorDestroyWater","Target_CreateorExtinguishFlames","Shout_DisguiseSelf","Shout_Druidcraft","Projectile_FireBolt","Target_Friends","Target_Frostbite","Target_GreenFlameBlade","Target_Guidance","Target_Light","Target_MageHand","Target_MindSliver","Projectile_PiercingTorrent","Projectile_PoisonSpray","Shout_Prestidigitation","Target_PrimalSavagery","Shout_ProduceFlame","Rush_PsionicCharge","Projectile_RayOfFrost","Target_Resistance","Target_SacredFlame","Target_ShockingGrasp","Target_SpareTheDying","Target_SparkSurge","Shout_Shillelagh","Throw_TelekineticHurl","Target_ThornWhip","Shout_Thunderclap","Target_ThunderousStrike","Target_TollTheDead","Target_TrueStrike","Projectile_Warpstone","Shout_WordOfRadiance"},
    ["9ee6464d-46f1-4bce-96f8-980568bfb661"] = {"Target_DancingLights","Target_Gust","Target_MinorIllusion","Shout_MudMantle","Shout_Thaumaturgy","Target_ViciousMockery","Projectile_BallLightning_Dawnstar","Projectile_Bleed_Dawnstar","Projectile_DeathMark_Dawnstar","Projectile_HurlWater_Dawnstar","Projectile_PsychicWhip_Dawnstar","Rush_AstralDive_Dawnstar","Shout_TKShell_Dawnstar","Target_Entangle_Dawnstar","Target_FluidFooting_Dawnstar","Target_Foresight_Dawnstar","Target_PainPuppet_Dawnstar","Target_PluckLife_Dawnstar","Target_TKPushPull_Dawnstar","Zone_BoneDustTongue_Dawnstar"},
    ["4f8a545f-2a42-490b-a008-7276d5186b0a"] = {"Target_AbsorbElements","Target_StinkingCloud","Shout_AcidicPheromones","Target_AegisProtection","Shout_Aid","Target_AnimateDead","Teleportation_ArcaneGate","Target_ArcaneLock","Target_ArcaneVisage","Target_ArcaneVortex","Shout_ArmorOfAgathys","Shout_ArmsOfHadar","Shout_AuraOfLife","Target_Banishment","Target_Barkskin","Shout_BarrierOfHolding","Target_BeaconOfHope","Target_BladeStorm","Target_Bless","Target_Blight","Target_Blindness","Target_Blink","Target_BloodBroker","Target_BloodOffering","Target_Blur","Zone_BurningHands","Target_CallLightning","Target_CalmEmotions","Shout_Catnap","Target_CauseFear","Projectile_ChainLightning","Target_CharmPerson","Projectile_ChromaticOrb","Target_CircleOfDeath","Target_Cloudkill","Target_CloudOfDaggers","Zone_ColorSpray","Target_Command_Container","Target_CompelledDuel","Zone_ConeOfCold","Target_Confusion","Zone_ConjureBarrage","Shout_WillOWisp","Target_Contagion","Shout_CorpseBinder","Target_Counterspell","Target_CrownOfMadness","Shout_CrusadersMantle","Target_CureWounds","Target_Darkness","Target_Darkvision","Target_DeathWard","Shout_DestructiveWave","Projectile_Disintegrate","Target_DispelEvilAndGood","Shout_DetectMagic","Target_DissonantWhispers","Target_DivineFavor","Target_FlameStrike","Target_DominatePerson","Shout_EarthTremor","Wall_ElementalWalls","Target_ElementalWeapon","Target_EnhanceAbility","Shout_LongJump","Target_EnlargeReduce","Projectile_EnsnaringStrike_Container","Target_Entangle","Target_EruptingEarth","Target_BlackTentacles","Target_Eyebite","Target_FaerieFire","Shout_FalseLife","Zone_Fear","Shout_FeatherFall","Shout_FelineFrenzy","Target_FindFamiliar","Projectile_Fireball","Shout_FireShield","Target_FlameBlade","Target_FlamingSphere","Target_FleshToStone","Target_ForceField","Target_FreedomOfMovement","Target_FrostFingers","Shout_FrostflameArmament","Target_GlobeOfInvulnerability","Target_Goodberry","Target_Fly","Zone_Gilgamesh","Target_GraspingVine","Target_Grease","Target_GreaterRestoration","Target_Invisibility_Greater","Target_GuardianOfFaith","Projectile_GuidingBolt","Zone_GustOfWind","Projectile_HailOfThorns","Projectile_Harm","Target_Haste","Target_Heal","Target_HealingSpirit","Target_HealingWord","Target_Hellfire","Shout_HellishRebuke","Target_HeroesFeast","Target_Heroism","Target_Hex","Target_HoldMonster","Target_HungerOfHadar","Target_HuntersMark","Target_HypnoticPattern","Projectile_IceKnife","Target_IceStorm","Projectile_Implode","Target_InflictWounds","Target_IntellectFortress","Target_InvictusAeterna","Target_Invisibility","Shout_KineticJaunt","Target_LesserRestoration","Projectile_LightningArrow","Zone_LightningBolt","Shout_Longstrider","Target_MageArmor","Projectile_MagicMissile","Shout_CureWounds_Mass","Shout_HealingWord_Mass","Target_MaximiliansEarthenGrasp","Projectile_AcidArrow","Shout_MindguardSurge","Target_MindPiercer","Shout_MinuteMeteors","Target_MindSpike","Shout_MirrorImage","Target_MistyStep","Target_Moonbeam","Target_NathairsMischief","Target_NaturesEmbrace","Target_NaturesGrasp","Projectile_FreezingSphere","Target_ResilientSphere","Target_IrresistibleDance","Target_PhantasmalForce","Target_PhantasmalKiller","Target_Polymorph","Target_PsionicLockdown","Target_PsionicSwordfall","Projectile_RayOfEnfeeblement","Projectile_RayOfSickness","Target_Antagonize","Target_RemoveCurse","Projectile_RendLife","Teleportation_Revivify","Target_RimesBindingIce","Target_SandCoffin","Target_Sanctuary","Zone_ScatterShot","Projectile_ScorchingRay","Target_SeismicEruption","Shout_ShadowBlade","Target_Shatter","Shout_Shield_Wizard","Target_ShieldOfFaith","Target_Silence","Shout_Sleep","Target_SleetStorm","Target_Slow","Shout_SnillocsSnowballStorm","Projectile_SolarFlare","Target_SoulPrism","Zone_SoulReaver","Zone_SpewAcid","Target_SpikeGrowth","Shout_SpiritGuardians","Zone_SpiritBlade","Shout_SpiritualShroud","Target_SpiritualWeapon","Target_Stoneskin","Zone_Sunbeam","Zone_TashasCausticBrew","Target_HideousLaughter","Projectile_TearsofUmberlee","Throw_Telekinesis","Target_TelekineticTethers","Zone_TelekineticWave","Zone_Thunderwave","Target_ThunderStep","Zone_TidalWave","Zone_TorrentialSpear","Target_Transposition","Target_VampiricTouch","Target_VitriolicTouch","Target_AuraOfVitality","Target_WardingBond","Shout_WaterWalk","Shout_Whirlpool","Projectile_WitchBolt","Target_WitherAndBloom","Shout_ZephyrStrike"},
    ["f5c8bd5a-1417-49f4-bf6a-7b40e9fcb51e"] = {"Target_Bane","Wall_BladeBarrier","Target_BorrowedKnowledge","Target_Daylight","Shout_DetectThoughts","Teleportation_DimensionDoor","Target_Enthrall","Target_Snare","Target_ExpeditiousRetreat","Shout_FeignDeath","Shout_FlameArrows","Target_FogCloud","Shout_GuidingCeremony","Target_HeatMetal","Target_InsectPlague","Target_Knock","Target_MagicWeapon","Target_PassWithoutTrace","Target_PlantGrowth","Target_ProtectionFromEvilAndGood","Shout_PrayerOfHealing","Target_SeeInvisibility","Shout_SpeakWithAnimals","Target_SpeakWithDead","Target_UnseenServant","Wall_WallOfThorns","Shout_WardingWind","Target_Web","Shout_WindWalk","Projectile_BleedingOut_Dawnstar","Projectile_BloodLance_Dawnstar","Projectile_DeathRay_Dawnstar","Projectile_Dehydration_Dawnstar","Projectile_PsychicArrow_Dawnstar","Projectile_PsychicBomb_Dawnstar","Projectile_SeanceGhost_Dawnstar","Shout_ArcaneBinder_Dawnstar","Shout_DiscFlight_Dawnstar","Shout_Fireworks_Dawnstar","Shout_FromTheAshes_Dawnstar","Shout_PsionicBladefield_Dawnstar","Shout_RestrainingWave_Dawnstar","Shout_SelfSacrifice_Dawnstar","Shout_SoulSplit_Dawnstar","Shout_TKDebrisStorm_Dawnstar","Shout_TKMaelstrom_Dawnstar","Target_ArcanePrison_Dawnstar","Target_Blizzard_Dawnstar","Target_CrushingBubble_Dawnstar","Target_DeathEater_Dawnstar","Target_DeathMarch_Dawnstar","Target_Downpour_Dawnstar","Target_ElementalExposure_Dawnstar","Target_ExplodeCorpse_Dawnstar","Target_Geyser_Dawnstar","Target_Hydro_Resistance_Dawnstar","Target_MagicInABottle_Dawnstar","Target_PsionicAssault_Dawnstar","Target_PsychicWeapons_Dawnstar","Target_StormOfSouls_Dawnstar","Target_SummonFamiliarSpirit_Dawnstar","Target_TKFocusBeam_Dawnstar","Target_TKProtection_Dawnstar","Target_Tornado_Dawnstar","Target_WaterSpout_Dawnstar","Target_WitchStorm_Dawnstar","Throw_SoulBomb_Dawnstar","Wall_WallofSwords_Dawnstar","Zone_DrainEssence_Dawnstar","Zone_WitchSpill_Dawnstar"},
    ["63c89951-2cc1-4597-9d4b-b80d90b56803"] = {"Target_AbsorbElements","Target_AegisProtection","Shout_Aid","Target_AnimateDead","Teleportation_ArcaneGate","Target_ArcaneLock","Shout_ArmsOfHadar","Shout_AuraOfLife","Target_Banishment","Shout_BarrierOfHolding","Target_BeaconOfHope","Target_Bless","Target_BloodBroker","Target_BloodOffering","Target_CallLightning","Target_CalmEmotions","Projectile_ChainLightning","Target_CircleOfDeath","Target_Cloudkill","Target_Command_Container","Target_CompelledDuel","Shout_CorpseBinder","Shout_CrusadersMantle","Target_CureWounds","Target_DeathWard","Target_DispelEvilAndGood","Target_DivineFavor","Target_FlameStrike","Target_EnhanceAbility","Target_FaerieFire","Shout_FalseLife","Shout_FeatherFall","Target_ForceField","Shout_FrostflameArmament","Target_GlobeOfInvulnerability","Target_Goodberry","Target_Invisibility_Greater","Target_GreaterRestoration","Target_GuardianOfFaith","Projectile_GuidingBolt","Projectile_Harm","Target_Haste","Target_Heal","Target_HealingSpirit","Target_HealingWord","Shout_HellishRebuke","Target_HeroesFeast","Target_Heroism","Target_Hex","Target_HoldMonster","Target_InflictWounds","Target_InvictusAeterna","Target_LesserRestoration","Shout_CureWounds_Mass","Shout_HealingWord_Mass","Target_NaturesEmbrace","Target_ResilientSphere","Target_RemoveCurse","Projectile_RendLife","Teleportation_Revivify","Target_Sanctuary","Shout_ShadowBlade","Target_ShieldOfFaith","Target_Silence","Target_Slow","Projectile_SolarFlare","Target_SoulPrism","Zone_SoulReaver","Shout_SpiritGuardians","Zone_SpiritBlade","Shout_SpiritualShroud","Target_SpiritualWeapon","Zone_Sunbeam","Projectile_TearsofUmberlee","Target_Transposition","Target_VampiricTouch","Target_VitriolicTouch","Target_AuraOfVitality","Target_WardingBond","Target_WitherAndBloom"},
    ["4174e244-89fb-46f8-a953-c73cad0a8c56"] = {"Target_AbsorbElements","Shout_AcidicPheromones","Shout_Aid","Shout_AuraOfLife","Target_Barkskin","Target_BeaconOfHope","Target_BladeStorm","Target_Bless","Target_Blight","Target_Blindness","Shout_Catnap","Target_CharmPerson","Target_Cloudkill","Zone_ConeOfCold","Zone_ConjureBarrage","Shout_WillOWisp","Target_Contagion","Shout_CrusadersMantle","Target_CureWounds","Target_Darkness","Target_Darkvision","Shout_EarthTremor","Wall_ElementalWalls","Target_ElementalWeapon","Target_EnhanceAbility","Shout_LongJump","Projectile_EnsnaringStrike_Container","Target_Entangle","Target_EruptingEarth","Shout_FelineFrenzy","Target_FindFamiliar","Target_FlamingSphere","Target_FreedomOfMovement","Target_Goodberry","Target_Fly","Target_GraspingVine","Target_GreaterRestoration","Zone_GustOfWind","Projectile_HailOfThorns","Projectile_Harm","Target_Haste","Target_Heal","Target_HealingSpirit","Target_HealingWord","Target_HeroesFeast","Target_HuntersMark","Target_LesserRestoration","Projectile_LightningArrow","Shout_Longstrider","Shout_CureWounds_Mass","Shout_HealingWord_Mass","Target_MaximiliansEarthenGrasp","Target_Moonbeam","Target_NaturesEmbrace","Target_NaturesGrasp","Target_Polymorph","Projectile_RayOfSickness","Teleportation_Revivify","Target_SandCoffin","Target_Sanctuary","Zone_ScatterShot","Target_SeismicEruption","Shout_Sleep","Target_SleetStorm","Shout_SnillocsSnowballStorm","Projectile_SolarFlare","Target_SoulPrism","Target_SpikeGrowth","Zone_SpiritBlade","Target_Stoneskin","Zone_Sunbeam","Projectile_TearsofUmberlee","Zone_TidalWave","Zone_TorrentialSpear","Target_AuraOfVitality","Target_WardingBond","Shout_WaterWalk","Shout_Whirlpool","Target_WitherAndBloom","Shout_ZephyrStrike"},
    ["a3c79518-7d3b-416c-8c78-470fb1a23c28"] = {"Target_StinkingCloud","Target_ArcaneVisage","Target_ArcaneVortex","Target_Banishment","Target_Barkskin","Target_Blindness","Target_Blink","Target_Blur","Target_CallLightning","Target_CalmEmotions","Shout_Catnap","Target_CauseFear","Projectile_ChainLightning","Target_CharmPerson","Projectile_ChromaticOrb","Zone_ColorSpray","Target_Confusion","Target_Counterspell","Target_CrownOfMadness","Target_Darkvision","Shout_DestructiveWave","Projectile_Disintegrate","Shout_DetectMagic","Target_DissonantWhispers","Target_DominatePerson","Wall_ElementalWalls","Target_ElementalWeapon","Target_EnlargeReduce","Target_Entangle","Target_EruptingEarth","Target_BlackTentacles","Target_Eyebite","Target_FaerieFire","Zone_Fear","Shout_FelineFrenzy","Projectile_Fireball","Shout_FireShield","Target_FlameBlade","Target_FlamingSphere","Target_FleshToStone","Target_Fly","Target_Grease","Target_HoldMonster","Target_HypnoticPattern","Projectile_IceKnife","Projectile_Implode","Target_IntellectFortress","Target_Invisibility","Shout_KineticJaunt","Zone_LightningBolt","Target_MageArmor","Projectile_MagicMissile","Target_MaximiliansEarthenGrasp","Projectile_AcidArrow","Shout_MinuteMeteors","Shout_MirrorImage","Projectile_FreezingSphere","Target_Polymorph","Target_RemoveCurse","Target_RimesBindingIce","Target_SandCoffin","Target_SeismicEruption","Shout_ShadowBlade","Target_Shatter","Target_Silence","Shout_Sleep","Target_SleetStorm","Target_Slow","Shout_SnillocsSnowballStorm","Zone_SpewAcid","Throw_Telekinesis","Target_TelekineticTethers","Zone_TelekineticWave","Zone_Thunderwave","Target_ThunderStep","Zone_TidalWave","Zone_TorrentialSpear","Target_Transposition","Target_VitriolicTouch","Shout_Whirlpool"},
    ["f33b1b19-43c6-4f61-a001-cd55e516791c"] = {"Target_StinkingCloud","Shout_AcidicPheromones","Shout_ArmorOfAgathys","Shout_ArmsOfHadar","Target_BladeStorm","Target_Blight","Target_BloodBroker","Target_BloodOffering","Zone_BurningHands","Target_CauseFear","Target_CircleOfDeath","Target_CloudOfDaggers","Target_Command_Container","Target_CompelledDuel","Target_Confusion","Zone_ConjureBarrage","Target_Contagion","Target_CrownOfMadness","Target_Darkness","Projectile_Disintegrate","Target_DispelEvilAndGood","Target_DissonantWhispers","Target_DivineFavor","Target_FlameStrike","Target_DominatePerson","Projectile_EnsnaringStrike_Container","Target_BlackTentacles","Target_Eyebite","Shout_FalseLife","Zone_Fear","Shout_FireShield","Target_FlameBlade","Target_FleshToStone","Target_FrostFingers","Shout_FrostflameArmament","Zone_Gilgamesh","Target_GraspingVine","Target_GuardianOfFaith","Projectile_GuidingBolt","Projectile_HailOfThorns","Target_Hellfire","Shout_HellishRebuke","Target_Heroism","Target_Hex","Target_HungerOfHadar","Target_HuntersMark","Target_IceStorm","Target_InflictWounds","Target_InvictusAeterna","Projectile_LightningArrow","Projectile_AcidArrow","Shout_MindguardSurge","Target_MindPiercer","Target_MindSpike","Target_MistyStep","Target_Moonbeam","Target_NathairsMischief","Projectile_FreezingSphere","Target_IrresistibleDance","Target_PhantasmalForce","Target_PhantasmalKiller","Target_PsionicLockdown","Target_PsionicSwordfall","Projectile_RayOfEnfeeblement","Projectile_RayOfSickness","Target_Antagonize","Projectile_RendLife","Target_RimesBindingIce","Projectile_ScorchingRay","Target_Shatter","Shout_Shield_Wizard","Zone_SoulReaver","Target_SpikeGrowth","Shout_SpiritGuardians","Shout_SpiritualShroud","Zone_TashasCausticBrew","Target_HideousLaughter","Target_ThunderStep","Target_VampiricTouch","Projectile_WitchBolt"},
    ["8e57e7e8-af23-4621-a64a-3cf34b57676c"] = {"Target_AegisProtection","Target_AnimateDead","Teleportation_ArcaneGate","Target_ArcaneLock","Target_ArcaneVisage","Target_ArcaneVortex","Shout_ArmorOfAgathys","Shout_BarrierOfHolding","Target_Blink","Target_Blur","Zone_BurningHands","Projectile_ChromaticOrb","Target_CloudOfDaggers","Zone_ColorSpray","Zone_ConeOfCold","Shout_WillOWisp","Shout_CorpseBinder","Target_Counterspell","Target_DeathWard","Shout_DestructiveWave","Shout_DetectMagic","Shout_EarthTremor","Shout_LongJump","Target_EnlargeReduce","Shout_FeatherFall","Target_FindFamiliar","Projectile_Fireball","Target_ForceField","Target_FreedomOfMovement","Target_FrostFingers","Target_GlobeOfInvulnerability","Zone_Gilgamesh","Target_Grease","Target_Invisibility_Greater","Zone_GustOfWind","Target_Hellfire","Target_HungerOfHadar","Target_HypnoticPattern","Projectile_IceKnife","Target_IceStorm","Projectile_Implode","Target_IntellectFortress","Target_Invisibility","Shout_KineticJaunt","Zone_LightningBolt","Shout_Longstrider","Target_MageArmor","Projectile_MagicMissile","Shout_MindguardSurge","Target_MindPiercer","Shout_MinuteMeteors","Target_MindSpike","Shout_MirrorImage","Target_MistyStep","Target_NathairsMischief","Target_NaturesGrasp","Target_ResilientSphere","Target_IrresistibleDance","Target_PhantasmalForce","Target_PhantasmalKiller","Target_PsionicLockdown","Target_PsionicSwordfall","Projectile_RayOfEnfeeblement","Target_Antagonize","Zone_ScatterShot","Projectile_ScorchingRay","Shout_Shield_Wizard","Target_ShieldOfFaith","Zone_SpewAcid","Target_SpiritualWeapon","Target_Stoneskin","Zone_TashasCausticBrew","Target_HideousLaughter","Throw_Telekinesis","Target_TelekineticTethers","Zone_TelekineticWave","Zone_Thunderwave","Shout_WaterWalk","Projectile_WitchBolt","Shout_ZephyrStrike"},
    ["62b78cbc-f9df-4834-a544-d6002d44d588"] = {"Projectile_Grenadier_StolenExplosives"},
    ["239cc7cc-f642-4ddc-b091-498d81612c55"] = {"Shout_TurnUndead","Shout_DivineIntervention_Death"},
    ["0da96163-c4aa-40f9-baa8-4a23d55f8e90"] = {"Shout_TurnUndead","Shout_DivineIntervention_Forge"},
    ["b9f6f71d-2a87-4452-8357-4bac5cd2c16e"] = {"Shout_TurnUndead","Shout_DivineIntervention_Illusory"},
    ["239cc7cc-f642-4ddc-b091-498d81612c52"] = {"Shout_TurnUndead","Shout_DivineIntervention_Life"},
    ["239cc7cc-f642-4ddc-b091-498d81612c53"] = {"Shout_TurnUndead","Shout_DivineIntervention_Tempest"},
    ["239cc7cc-f642-4ddc-b091-498d81612c54"] = {"Shout_TurnUndead","Shout_DivineIntervention_War"},
    ["ae3ce10b-d32c-44df-91b9-ebf74476a9d8"] = {"Shout_WildShape"},
    ["048d3543-1ac4-4eb9-b6a8-1713d8ff5f91"] = {"Shout_WildShape_Badger","Shout_WildShape_Bear_Polar","Shout_WildShape_Cat","Shout_WildShape_DeepRothe","Shout_WildShape_Dilophosaurus","Shout_WildShape_Dire_Raven","Shout_WildShape_Dire_Wolf","Shout_Wildshape_Giant_Eagle","Shout_WildShape_Giant_Spider","Shout_WildShape_Owlbear","Shout_Wildshape_Panther"},
    ["11c23a6f-6f53-47bc-ad35-9cb7ed0c2b2e"] = {"Shout_WildShape_Badger","Shout_WildShape_Bear_Polar","Shout_WildShape_Cat","Shout_WildShape_DeepRothe","Shout_WildShape_Dilophosaurus","Shout_WildShape_Dire_Raven","Shout_WildShape_Dire_Wolf","Shout_Wildshape_Giant_Eagle","Shout_WildShape_Giant_Spider","Shout_WildShape_Owlbear","Shout_Wildshape_Panther"},
    ["28330f90-a041-4295-8933-2abcdc6cface"] = {"Projectile_Challengers_Call_Improved"},
    ["bd3770c9-1ac9-4af3-80f6-f555aeb696d1"] = {"Shout_TurnTheFaithless"},
    ["0e170ae3-56b4-487a-9690-83b722d5f846"] = {"Shout_TurnTheAberrant"},
    ["6c6e85c8-3eb5-4d18-a78b-914efb967288"] = {"Shout_TurnTheUnholy"},
    ["9696a1a4-6007-43ab-9a37-ff9ca4734848"] = {"Shout_TurnTheDamned"},
    ["cb1e5aad-26cd-4370-a179-5536bfcc3d47"] = {"Target_Subjugate","Target_SpitefulSuffering"},
    ["676813a8-f62a-48fd-b2e5-a41acd7feed9"] = {"Shout_TurnTheLiving"},
    ["34013841-cbff-4976-9b50-211894badee8"] = {"Shout_Oathcast"},
    ["85633214-a2a7-46c5-af28-d1259396ce89"] = {"Shout_Oathcast_2"},
    ["7bd2be2f-4d0c-444b-a650-e2e0dcb4015a"] = {"Shout_Oathcast_3"},
    ["1b5343b2-8f4e-4b60-83d3-ec5300ef3508"] = {"Shout_TurnTheDefiant"},
    ["0902b584-1045-4438-92e4-bc63e67240cb"] = {"Target_GatheredSwarm_Recall"},
    ["62b78cbc-f9df-4834-a544-d661e7571fc4"] = {"Target_DirtyTrick_CannonFire"},
    ["3f5482a3-5524-4f2c-80c6-c57a104fa904"] = {"Target_PactOfTheChain_4Azer","Target_PactOfTheChain_5Cambion","Target_PactOfTheChain_6Succubus"},
    ["b026cee3-48a1-4955-b621-7b43ba4e7ce8"] = {"Target_PactOfTheChain_7Orthon","Target_PactOfTheChain_8Spectator","Target_PactOfTheChain_9UndeadDragon"},
    ["40a0526a-7415-4fbb-97f1-c12342f15720"] = {"Shout_ArcaneRecoveryAI_1"},
    ["40a0526a-7415-4fbb-97f1-c12342f15721"] = {"Shout_ArcaneRecoveryAI_2"},
    ["40a0526a-7415-4fbb-97f1-c12342f15722"] = {"Shout_ArcaneRecoveryAI_3"},
    ["40a0526a-7415-4fbb-97f1-c12342f15723"] = {"Shout_ArcaneRecoveryAI_4"},
    ["40a0526a-7415-4fbb-97f1-c12342f15724"] = {"Shout_ArcaneRecoveryAI_5"},
    ["40a0526a-7415-4fbb-97f1-c12342f15725"] = {"Shout_ArcaneRecoveryAI_6"},
}
-- Exact author-defined Feats.lsx order (136 feat records). Localized
-- display names are never an ordering key. Unknown third-party feats retain
-- their catalog order after these HB entries.
local HB_FEAT_SOURCE_ORDER = {
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

-- Historical skill/spell candidates must come from the exact recorded
-- list. The old static HB catalog covered only selected SpellList GUIDs,
-- leaving Eldritch Knight learned-spell tabs visually empty. Read the live
-- installed list first, tolerating Lua arrays and engine-owned collections.
-- A missing/unreadable list NEVER becomes an all-spells/all-skills picker.
local function RecordedListOptions(listId, staticType, field)
    if not Ext.StaticData or not Ext.StaticData.Get then return {} end
    local ok,definition=pcall(Ext.StaticData.Get,tostring(listId or ""),staticType)
    if not ok or not definition then return {} end
    local got,raw=pcall(function() return definition[field] end)
    if not got or not raw then return {} end
    local result,seen={},{}
    local function Add(value)
        if type(value)~="string" then return end
        for id in value:gmatch("[^;,%s]+") do
            if id~="" and not seen[id] then
                seen[id]=true;result[#result+1]=id
            end
        end
    end
    local function Parse(value)
        if type(value)=="string" then Add(value);return end
        if value==nil then return end
        local fields={"SpellId","Spell","Skill","SkillId","StatsId","Id","Name","Value"}
        for _,name in ipairs(fields) do
            local worked,item=pcall(function() return value[name] end)
            if worked and type(item)=="string" then Add(item);return end
        end
    end
    if type(raw)=="table" then
        local count=0
        for _,value in ipairs(raw) do Parse(value);count=count+1 end
        -- Lua-serialized zero-based collections can have [0] and [1].
        -- Include index 0 independently without duplicating [1].
        if raw[0]~=nil and count<1024 then Parse(raw[0]) end
        if count==0 and raw[0]==nil then Parse(raw) end
    else
        -- C++ collections usually expose Count and zero-based [] indexing.
        local countOK,count=pcall(function() return raw.Count end)
        count=countOK and tonumber(count) or nil
        if count and count>=0 and count<=1024 then
            for i=0,count-1 do
                local itemOK,item=pcall(function() return raw[i] end)
                if itemOK then Parse(item) end
            end
        else
            Parse(raw)
            -- Some SE proxies have one-based ipairs but no Count.
            pcall(function()
                local n=0
                for _,value in ipairs(raw) do
                    Parse(value);n=n+1
                    if n>=1024 then break end
                end
            end)
        end
    end
    return result
end

local emptyHistoricalChoiceListsLogged={}
local function ChoicesOptionSet(kind, listId)
    local options = {}
    if kind == "Ability" then
        for _, name in ipairs(HB_ABILITY_NAMES) do options[#options+1] = {Id=name, Name=name} end
    elseif kind == "Skill" or kind == "Expertise" then
        -- Class restrictions are defined by SkillLists, not the 18 global
        -- skill names. Only expose options from a list that can be resolved.
        local valid={}
        local known={}
        for _,name in ipairs(HB_SKILL_NAMES) do known[name]=true end
        for _,id in ipairs(RecordedListOptions(listId,"SkillList","Skills")) do
            if known[id] then valid[id]=true end
        end
        -- This fallback is *not* global. It belongs exclusively to HB's
        -- naturally recorded Multifaceted four-skill list; foreign skill
        -- selectors are never turned into an unrestricted skill picker.
        if not next(valid) and tostring(listId)==HB_MULTIFACETED_SKILL_LIST then
            for _,name in ipairs(HB_SKILL_NAMES) do valid[name]=true end
            RespecStartLog("HISTORICAL_MULTIFACETED_SKILL_LIST_FALLBACK list="..tostring(listId)
                .." choices="..tostring(#HB_SKILL_NAMES).." reason=structured_skill_list")
        end
        for _,name in ipairs(HB_SKILL_NAMES) do
            if valid[name] then
                options[#options+1]={Id=name,Name=name:gsub("([a-z])([A-Z])", "%1 %2")}
            end
        end
    elseif kind == "Spell" or kind == "Cantrip" then
        local source=RecordedListOptions(listId,"SpellList","Spells")
        if #source==0 then source=HB_SPELL_LIST_CATALOG[tostring(listId)] or {} end
        local seen={}
        for _,id in ipairs(source) do
            local exists,stat=pcall(Ext.Stats.Get,id)
            if id~="" and not seen[id] and exists and stat then
                seen[id]=true
                options[#options+1]={Id=id,Name=id:gsub("^%w+_", ""):gsub("_", " ")}
            end
        end
    elseif kind == "Feat" then
        local ok, feats = pcall(Ext.StaticData.GetAll, "Feat")
        if ok and feats then
            for _, id in ipairs(feats) do
                id = tostring(id)
                local name = FeatDisplayName(id)
                options[#options+1] = {Id=id, Name=name.DisplayNameFallback or id,
                    DisplayNameHandle=name.DisplayNameHandle}
            end
            -- Preserve supplied Feats.lsx order through both the native
            -- feat list and the older Edit Build selector. Feats from other
            -- installed mods follow without disturbing their catalog order.
            local function Rank(entry)
                return HB_FEAT_SOURCE_ORDER[tostring(entry.Id or ""):lower()]
            end
            local ordered={}
            for i,entry in ipairs(options) do
                ordered[#ordered+1]={row=entry,rank=Rank(entry),sourceIndex=i}
            end
            table.sort(ordered,function(a,b)
                if a.rank and b.rank then return a.rank<b.rank end
                if not a.rank and not b.rank then return a.sourceIndex<b.sourceIndex end
                return a.rank~=nil
            end)
            for i,item in ipairs(ordered) do options[i]=item.row end
        end
    end
    if #options==0 and (kind=="Spell" or kind=="Cantrip"
        or kind=="Skill" or kind=="Expertise") then
        local key=tostring(kind)..":"..tostring(listId or "")
        if not emptyHistoricalChoiceListsLogged[key] then
            emptyHistoricalChoiceListsLogged[key]=true
            RespecStartLog("HISTORICAL_CHOICE_LIST_EMPTY kind="..tostring(kind)
                .." list="..tostring(listId)
                .." reason=static_list_or_installed_candidates_unavailable; view_only")
        end
    end
    return options
end
-- Original BG3 spell selections frequently store their chosen Spells as
-- plain IDs *inside* a fully structured SpellSelector row. Such IDs are not
-- unowned raw grants: the enclosing CCLevelUp selector records the source,
-- spell list, selector category, level and the exact selected slot. Do not
-- mistake this ordinary BG3 serialization for an unproven standalone ID.
-- Progression grant ownership is checked independently during replay.
local function StrictRecordedSpellGuid(value)
    local guid=tostring(value or "")
    return #guid==36 and guid~="00000000-0000-0000-0000-000000000000"
        and guid:match("^[%da-fA-F%-]+$")~=nil
        and guid:sub(9,9)=="-" and guid:sub(14,14)=="-"
        and guid:sub(19,19)=="-" and guid:sub(24,24)=="-"
end
-- CCLevelUp.LevelUps is ordered by character level, but each serialized
-- LevelUpData record does NOT necessarily have a top-level Level field.
-- The authoritative historical level is therefore its verified array index.
-- Always pass that index; do not infer a missing level from the selector row.
local function CanonicalHistoricalSpellRow(history,record,source,kind,historyIndex)
    if source~="Upgrades.Spells" or record==nil then return false end
    local function Field(key)
        local ok,value=pcall(function() return record[key] end)
        return ok and value or nil
    end
    local selector=tostring(Field("SelectorId") or "")
    if selector~=(kind=="Cantrip" and "Cantrips" or "Spells") then return false end
    local grantType=tostring(Field("Type") or "")
    local cls=tostring(Field("Class") or "")
    local list=tostring(Field("SpellList") or "")
    if not StrictRecordedSpellGuid(cls) or not StrictRecordedSpellGuid(list) then return false end
    local lvl=tonumber(Field("Level"))
    local recordedLevel=tonumber(historyIndex)
    if not recordedLevel or recordedLevel<1
        or recordedLevel~=math.floor(recordedLevel)
        or not lvl or lvl~=recordedLevel then return false end
    -- If a particular engine representation also exposes an outer Level,
    -- reject disagreement instead of trusting either field blindly.
    local historyLevelOK,historyLevel=pcall(function() return history.Level end)
    if historyLevelOK and historyLevel~=nil
        and tonumber(historyLevel)~=recordedLevel then return false end
    if grantType~="SubClass" and grantType~="Class" and grantType~="Feat" then
        return false
    end
    -- Feat spell selectors need their own proven grant owner; currently only
    -- the captured Accord of the Arcane two-cantrip configuration has one.
    if grantType=="Feat" then
        if tostring(history and history.Feat or "")~="cdcbc538-883b-401c-a8ed-1373fb6d1720"
            or cls~="cdcbc538-883b-401c-a8ed-1373fb6d1720"
            or kind~="Cantrip"
            or list~="ffad33d2-e725-4655-ba80-0bc91e8002b3" then
            return false
        end
    end
    local spells=Field("Spells")
    if type(spells)~="table" and type(spells)~="userdata" then return false end
    local seen,count={},0
    local traversed=pcall(function()
        for _,id in ipairs(spells) do
            count=count+1
            if count>8 or type(id)~="string" or id=="" or seen[id] then
                error("invalid canonical spell selector entry")
            end
            seen[id]=true
        end
    end)
    return traversed and count>0
end

-- EXPERIMENT ONLY: bypass feat type, selector, prerequisite and
-- nonrepeatability restrictions. Still require original history/progression
-- ownership and replay integrity. This is NOT universal effect reconstruction.
local HB_UNRESTRICTED_FEAT_TEST=true
-- TEMPORARY FEAT AUDIT ONLY: match the client Yokebreaker class bypass.
-- Restore false after testing; other historical replay integrity checks stay.
HB_YOKEBREAKER_ALL_CLASSES_TEST=false

local function BuildOtherHistoricalChoices(history,historicalLevel)
    local rows = {}
    if not history then return rows end
    local upgrade = history.Upgrades or {}
    local function Add(kind, from, list, entryIndex, slotIndex, source, featOwnerId,selectorId,definitionIndex)
        from = tostring(from or "")
        if from == "" then return end
        local options = ChoicesOptionSet(kind, list)
        -- Always expose the historical choice even if it no longer exists in
        -- the current catalog, but never offer edits without verified options.
        local found = false
        for _, opt in ipairs(options) do if opt.Id == from then found = true; break end end
        if not found then
            local sourceName=kind=="Feat" and FeatDisplayName(from) or nil
            table.insert(options, 1, {Id=from,
                Name=sourceName and sourceName.DisplayNameFallback or from,
                DisplayNameHandle=sourceName and sourceName.DisplayNameHandle or nil})
        end
        rows[#rows+1] = {Kind=kind, From=from, List=tostring(list or ""),
            EntryIndex=entryIndex or 1, SlotIndex=slotIndex or 1,
            Source=source or "", Options=options, Editable=#options>1,
            FeatOwnerId=featOwnerId or "",SelectorId=selectorId or "",
            DefinitionIndex=definitionIndex}
    end
    if IsValidGuid(history.Feat) then Add("Feat", history.Feat, "", 1, 1, "Feat") end
    for i, entry in ipairs(upgrade.AbilityBonuses or {}) do
        for slot, name in ipairs(entry.Bonuses or {}) do
            local featOwned=tostring(entry.Type or "")=="Feat"
            local owner=featOwned and tostring(entry.Class or "") or ""
            Add("Ability",name,tostring(entry.AbilityBonus or ""),i,slot,"AbilityBonuses",owner)
            -- A historical feat's AbilityBonuses may have effects in a
            -- ProgressionFeat component, not just ProgressionAbilityImprovements.
            -- Without that exact owner/replay contract, offering a selector
            -- would produce a misleading clickable option.
            if featOwned then rows[#rows].Editable=false end
        end
    end
    for i,entry in ipairs(upgrade.Skills or {}) do
        for slot,name in ipairs(entry.Proficiencies or {}) do
            local owner=(tostring(entry.Type or "")=="Feat"
                and tostring(entry.Class or "")==tostring(history.Feat or ""))
                and tostring(history.Feat or "") or nil
            Add("Skill",name,entry.Skill,i,slot,"Skills",owner)
            if owner and (owner~=HB_MULTIFACETED_SKILL_FEAT
                or tostring(entry.Skill or "")~=HB_MULTIFACETED_SKILL_LIST) then
                rows[#rows].Editable=false
            end
        end
    end
    for i,entry in ipairs(upgrade.SkillExpertise or {}) do
        for slot,name in ipairs(entry.Expertise or {}) do
            local owner=(tostring(entry.Type or "")=="Feat"
                and tostring(entry.Class or "")==tostring(history.Feat or ""))
                and tostring(history.Feat or "") or nil
            Add("Expertise",name,entry.Skill,i,slot,"SkillExpertise",owner)
            if owner then rows[#rows].Editable=false end
        end
    end
    -- LevelUpUpgrades::SpellSelector is a C++ userdata object on real BG3
    -- builds. Looking up a nonexistent property throws (it doesn't return
    -- nil, unlike an ordinary Lua table). A single such lookup previously
    -- converted an entire Wizard level into "History unavailable".
    local function SpellField(record,field)
        if record==nil then return nil end
        local ok,value=pcall(function() return record[field] end)
        return ok and value or nil
    end
    local function ScanSpells(selectionArray, source)
        for i,entry in ipairs(selectionArray or {}) do
            if type(entry)=="string" then
                -- Some caster upgrades contain a raw string spell ID rather
                -- than a selector row. The ID is observed but the replay
                -- engine cannot prove its provenance; keep it view-only.
                Add("Spell",entry,"",i,1,source)
                rows[#rows].Editable=false
            elseif entry then
                local list=SpellField(entry,"SpellList") or SpellField(entry,"SpellListId")
                    or SpellField(entry,"SpellListID")
                local selector=tostring(SpellField(entry,"SelectorId") or "")
                local kind=selector:lower():find("cantrip") and "Cantrip" or "Spell"
                local owner=(tostring(SpellField(entry,"Type") or "")=="Feat"
                    and tostring(SpellField(entry,"Class") or "")
                        ==tostring(history.Feat or ""))
                    and tostring(history.Feat or "") or nil
                local single=SpellField(entry,"SpellId") or SpellField(entry,"SpellID")
                if single then
                    Add(kind,single,list,i,1,source,owner,selector,SpellField(entry,"DefinitionIndex"))
                    if owner and (owner~="cdcbc538-883b-401c-a8ed-1373fb6d1720"
                        or kind~="Cantrip") then rows[#rows].Editable=false end
                else
                    -- The explicit Spells collection can contain structured
                    -- Lua values, C++ selector objects, or raw IDs.
                    local nested=SpellField(entry,"Spells")
                    local ok,err=pcall(function()
                        for j,item in ipairs(nested or {}) do
                            local itemId=SpellField(item,"SpellId") or SpellField(item,"SpellID")
                            if itemId then
                                Add(kind,itemId,list or SpellField(item,"SpellList"),i,j,source,owner,
                                    selector,SpellField(entry,"DefinitionIndex"))
                                if owner and (owner~="cdcbc538-883b-401c-a8ed-1373fb6d1720"
                                    or kind~="Cantrip") then rows[#rows].Editable=false end
                            elseif type(item)=="string" then
                                Add(kind,item,list,i,j,source,owner,selector,
                                    SpellField(entry,"DefinitionIndex"))
                                if (owner and (owner~="cdcbc538-883b-401c-a8ed-1373fb6d1720"
                                    or kind~="Cantrip"))
                                    or not CanonicalHistoricalSpellRow(history,entry,source,kind,historicalLevel) then
                                    rows[#rows].Editable=false -- unverified raw record
                                end
                            end
                        end
                    end)
                    if not ok then
                        RespecStartLog("HISTORICAL_SPELL_SELECTOR_SCAN_SKIPPED source="
                            ..tostring(source).." index="..i.." reason="..tostring(err))
                    end
                end
            end
        end
    end
    local ok1,why1=pcall(ScanSpells,history.Spells,"Spells")
    local ok2,why2=pcall(ScanSpells,upgrade.Spells,"Upgrades.Spells")
    if not ok1 or not ok2 then
        RespecStartLog("HISTORICAL_SPELL_SELECTOR_ARRAY_UNAVAILABLE first="
            ..tostring(why1).." second="..tostring(why2))
    end
    return rows
end

-- Some Spellbook/Progression containers are exposed as dense lists on one SE
-- build and as keyed proxy tables on another. The editor's confirmed replay
-- paths MUST remain untouched; this helper is used ONLY for read-only scans.
-- Cap the enumeration and return a structural status for caster diagnostics.
local function ObservedProgressionEntities(character, level)
    local progressions=character and character.ProgressionContainer
        and character.ProgressionContainer.Progressions
    local bucket=progressions and (progressions[level] or progressions[tostring(level)])
    local entities,seen={},{}
    local info={BucketPresent=bucket~=nil,Enumeration="none",Count=0}
    if not bucket then return entities,info end
    local function Add(value)
        if value==nil or #entities>=96 or seen[value] then return end
        if type(value)~="table" and type(value)~="userdata" then return end
        seen[value]=true
        entities[#entities+1]=value
    end
    local pairsOK=pcall(function()
        for _,value in pairs(bucket) do Add(value) end
    end)
    if pairsOK then info.Enumeration="pairs" end
    if not pairsOK or #entities==0 then
        local ipairsOK=pcall(function()
            for _,value in ipairs(bucket) do Add(value) end
        end)
        if ipairsOK then info.Enumeration=pairsOK and "pairs+ipairs" or "ipairs" end
    end
    if not pairsOK and info.Enumeration=="none" then info.Enumeration="failed" end
    info.Count=#entities
    return entities,info
end

-- Historical recovery is READ-ONLY. ProgressionSpells is not equivalent to
-- a player-selected spell: class/subclass grants can appear there too. Scan
-- explicit spell-bearing fields, including map-keyed spell IDs and nested
-- selector rows, without inventing editable provenance or a learning level.
local function ObservedProgressionSpells(character, level)
    local result,seen={},{}
    local entries,containerInfo=ObservedProgressionEntities(character,level)
    local inspected,failures=0,0
    local info={Container=containerInfo,Components={},TraversalTruncated=false}
    local spellPrefixes={Target=true,Projectile=true,Shout=true,Zone=true,
        Wall=true,Teleportation=true,Rush=true,Throw=true}
    local function LooksLikeSpell(id)
        return type(id)=="string" and spellPrefixes[id:match("^([%a]+)_")] == true
    end
    local function Insert(id,source)
        if not LooksLikeSpell(id) or seen[id] or #result>=120 then return end
        local ok,stat=pcall(Ext.Stats.Get,id)
        if not ok or not stat then return end
        seen[id]=true
        result[#result+1]={Id=id,Name=id:gsub("^%w+_",""):gsub("_"," "),
            Source=source,Editable=false}
    end
    for entryIndex,entity in ipairs(entries) do
        local okComponent,comp=pcall(function() return entity.ProgressionSpells end)
        if not okComponent then failures=failures+1 end
        if okComponent and comp then
            inspected=inspected+1
            local ok,serialized=pcall(Ext.Types.Serialize,comp)
            local trace={Entry=entryIndex,Serialized=ok and type(serialized)=="table",
                RootFields={},Found=0,Visited=0}
            local countBefore=#result
            if ok and type(serialized)=="table" then
                for key in pairs(serialized) do
                    if type(key)=="string" and #trace.RootFields<40 then
                        trace.RootFields[#trace.RootFields+1]=key
                    end
                end
                table.sort(trace.RootFields)
                local visited={}
                local function Scan(value,depth,source)
                    if type(value)~="table" or depth>7 or trace.Visited>=2500 then
                        if depth>7 or trace.Visited>=2500 then info.TraversalTruncated=true end
                        return
                    end
                    if visited[value] then return end
                    visited[value]=true
                    trace.Visited=trace.Visited+1
                    for field,item in pairs(value) do
                        if type(field)=="string" and LooksLikeSpell(field) then
                            Insert(field,source..".key")
                        end
                        if type(field)=="string" and (field=="SpellId" or field=="SpellID"
                            or field=="StatsId" or field=="SpellName") then
                            Insert(item,source.."."..field)
                        elseif type(item)=="table" then
                            Scan(item,depth+1,source.."."..tostring(field))
                        elseif type(item)=="string" and LooksLikeSpell(item) then
                            -- A string inside an explicit spell-bearing
                            -- component is an observation, never a choice.
                            Insert(item,source.."."..tostring(field))
                        end
                        if #result>=120 then info.TraversalTruncated=true;return end
                    end
                end
                Scan(serialized,0,"ProgressionSpells")
            else
                failures=failures+1
            end
            trace.Found=#result-countBefore
            info.Components[#info.Components+1]=trace
        end
    end
    table.sort(result,function(a,b) return a.Name<b.Name end)
    return result,inspected,failures,info
end

-- When level-up records and per-level ProgressionSpells have both been
-- lost, the current spellbook can still establish which spells a caster
-- presently knows. It CANNOT establish when, why, or how they were learned.
-- Show this at the last/current level only with an explicit warning.
local function ObserveCurrentSpellbook(character)
    local result,seen={},{}
    local scanned=0
    local inspection={}
    local visited={}
    local spellPrefixes={Target=true,Projectile=true,Shout=true,Zone=true,
        Wall=true,Teleportation=true,Rush=true,Throw=true}
    local function Append(id,source)
        if type(id)~="string" or not spellPrefixes[id:match("^([%a]+)_")]
            or seen[id] or #result>=120 then return end
        local ok,stat=pcall(Ext.Stats.Get,id)
        if not ok or not stat then return end
        seen[id]=true
        result[#result+1]={Id=id,Name=id:gsub("^%w+_",""):gsub("_"," "),
            Source=source,Editable=false}
    end
    local function Scan(value,depth,source)
        if type(value)~="table" or depth>8 or scanned>=6000 or visited[value] then return end
        visited[value]=true
        scanned=scanned+1
        for field,item in pairs(value) do
            -- Some serialized spellbook collections use the actual spell ID
            -- as the map key rather than as an item property. Never infer
            -- spell IDs from arbitrary keys: check the stat resource first.
            if type(field)=="string"
                and spellPrefixes[field:match("^([%a]+)_")] then
                Append(field,source)
            end
            if type(field)=="string" and (field=="SpellId" or field=="SpellID"
                or field=="StatsId" or field=="SpellName" or field=="Spell"
                or field=="SpellStats" or field=="SpellData") then
                if type(item)=="string" then Append(item,source) end
            elseif type(item)=="table" then
                Scan(item,depth+1,source)
            elseif type(item)=="string" then
                -- Native serialized spellbook lists can also store exact
                -- stat IDs as unlabelled array values. Only display verified
                -- spell-stat identifiers; never infer a historical choice.
                Append(item,source)
            end
        end
    end
    for _,name in ipairs({"SpellBook","LearnedSpells","SpellBookPrepares"}) do
        local before=#result
        local ok,serialized=pcall(function()
            local comp=character and character[name]
            return comp and Ext.Types.Serialize(comp)
        end)
        local fields={}
        if ok and type(serialized)=="table" then
            for key in pairs(serialized) do
                if type(key)=="string" and #fields<30 then fields[#fields+1]=key end
            end
            table.sort(fields)
            Scan(serialized,0,name)
        end
        inspection[name]={Serialized=ok and type(serialized)=="table",
            ResultType=ok and type(serialized) or "error",
            RootKeys=fields,Found=#result-before}
    end
    table.sort(result,function(a,b) return a.Name<b.Name end)
    return result,inspection
end

-- Keep a compact structural account of missing caster history. This is
-- distinct from the older large debug dump and avoids serializing spellbooks
-- inside a respec-start callback. A missing CCLevelUp history is not silently
-- treated as an ordinary level with no player choices.
local function HistoricalCoverage(character, levelUps, maximum)
    local details={ExpectedLevels=maximum,CCLevelUpPresent=character.CCLevelUp~=nil,
        RecordedLevels=0,ObservedSpellLevels=0,ObservedSpellIds=0,Levels={}}
    -- Some SE-provided collections use string keys or expose non-array
    -- proxies. Record their shape so a Wizard missing all apparent history
    -- can be diagnosed without treating that data as an editable upgrade.
    local historyShape={Present=levelUps~=nil,Kind=type(levelUps),
        KeySamples={},NumericRecords=0,StringIndexedRecords=0}
    if levelUps then
        local ok=pcall(function()
            for key in pairs(levelUps) do
                if #historyShape.KeySamples<32 then
                    historyShape.KeySamples[#historyShape.KeySamples+1]=tostring(key)
                end
            end
        end)
        historyShape.KeyEnumerationSucceeded=ok
        table.sort(historyShape.KeySamples)
        for level=1,maximum do
            local okNumber,numberValue=pcall(function() return levelUps[level] end)
            local okString,stringValue=pcall(function() return levelUps[tostring(level)] end)
            if okNumber and numberValue~=nil then
                historyShape.NumericRecords=historyShape.NumericRecords+1
            end
            if okString and stringValue~=nil then
                historyShape.StringIndexedRecords=historyShape.StringIndexedRecords+1
            end
        end
    end
    details.LevelUpCollection=historyShape
    for level=1,maximum do
        local recorded=levelUps and levelUps[level]
        local observed,count,errors,inspection=ObservedProgressionSpells(character,level)
        if recorded then details.RecordedLevels=details.RecordedLevels+1 end
        if #observed>0 then details.ObservedSpellLevels=details.ObservedSpellLevels+1 end
        details.ObservedSpellIds=details.ObservedSpellIds+#observed
        details.Levels[level]={Level=level,HasCCLevelUp=recorded~=nil,
            ClassId=recorded and tostring(recorded.Class or "") or nil,
            SpellRecords=recorded and #(recorded.Spells or {}) or 0,
            UpgradeSpellRecords=recorded and recorded.Upgrades
                and #(recorded.Upgrades.Spells or {}) or 0,
            ProgressionSpellComponents=count,SerializationFailures=errors,
            ProgressionStructure=inspection,
            ObservedSpellIds=(function()
                local ids={};for _,row in ipairs(observed) do ids[#ids+1]=row.Id end;return ids
            end)()}
    end
    if details.RecordedLevels<maximum then
        local _,spellbookInspection=ObserveCurrentSpellbook(character)
        details.CurrentSpellbookComponents=spellbookInspection
    end
    return details
end

-- Level-one edits never change the class/subclass, creation identity, ability
-- scores, or feats. Require an exact recorded selector AND uniquely owned
-- level-one progression effect before exposing any choice as editable.
local function LevelOneChoiceOwnerMatches(levelUp, row, kind, spellId, character)
    if not levelUp or not row or not character then return false end
    local owner=tostring(row.Class or "")
    local ownerType=tostring(row.Type or "")
    if tonumber(row.Level)~=1 or
        not ((ownerType=="Class" and owner==tostring(levelUp.Class or ""))
          or (ownerType=="SubClass" and owner==tostring(levelUp.SubClass or ""))) then
        return false
    end
    if not IsValidGuid(owner) then return false end
    local progressions=character.ProgressionContainer and character.ProgressionContainer.Progressions
    local bucket=progressions and progressions[1]
    if not bucket then return false end
    local matches=0
    for _,entity in ipairs(bucket) do
        local meta=entity.ProgressionMeta
        if meta and tostring(meta.Source or "")==owner
            and tonumber(meta.Level)==1
            and tostring(meta.SpellSourceType or "")== (ownerType=="Class"
                and "ProgressionClass" or "ProgressionSubClass") then
            local field=kind=="Skill" and "ProgressionSkills"
                or kind=="Expertise" and "ProgressionSkills"
                or "ProgressionSpells"
            local component=entity[field]
            if component then
                local ok,data=pcall(Ext.Types.Serialize,component)
                if ok and type(data)=="table" then
                    local grants=kind=="Skill" and data.Proficiencies
                        or kind=="Expertise" and data.Expertise
                        or data.AddSpells
                    for _,item in ipairs(grants or {}) do
                        local value=(kind=="Spell" or kind=="Cantrip")
                            and tostring(type(item)=="table" and (item.SpellId or item.SpellID) or "")
                            or tostring(item)
                        if value==spellId then matches=matches+1 end
                    end
                end
            end
        end
    end
    return matches==1
end

local function LevelOnePassiveOwnerMatches(levelUp,group,character)
    if not levelUp or not group or not character or IsValidGuid(levelUp.Feat) then return false end
    local rows=levelUp.Upgrades and levelUp.Upgrades.Passives or {}
    local selected=nil
    for _,row in ipairs(rows) do
        if tostring(row.SelectorId or "")==tostring(group.SelectorId or "")
            and tostring(row.PassiveList or "")==tostring(group.PassiveList or "") then
            if selected then return false end
            selected=row
        end
    end
    local ownerType=selected and tostring(selected.Type or "") or ""
    local owner=selected and tostring(selected.Class or "") or ""
    if not selected or not ((ownerType=="Class" and owner==tostring(levelUp.Class or ""))
        or (ownerType=="SubClass" and owner==tostring(levelUp.SubClass or "")))
        or tonumber(selected.Level)~=1
        or #((selected.Passives) or {})~=#(group.Picked or {}) then return false end
    local container=character.ProgressionContainer
    local buckets=container and container.Progressions
    local granted={}
    for _,entity in ipairs(buckets and buckets[1] or {}) do
        local meta=entity.ProgressionMeta
        if meta and tonumber(meta.Level)==1
            and tostring(meta.SpellSourceType or "")==
                (ownerType=="Class" and "ProgressionClass" or "ProgressionSubClass")
            and tostring(meta.Source or "")==owner then
            local component=entity.ProgressionPassives
            if component then
                local ok,data=pcall(Ext.Types.Serialize,component)
                if ok and type(data)=="table" then
                    for _,id in ipairs(data.AddPassives or {}) do
                        id=tostring(id);granted[id]=(granted[id] or 0)+1
                    end
                end
            end
        end
    end
    for _,id in ipairs(group.Picked or {}) do
        if granted[tostring(id)]~=1 then return false end
    end
    return true
end

local function BuildLevelChoices(character, levelUps, level)
    local levelUp = levelUps and levelUps[level]
    local currentClassSummary={}
    if not levelUp then
        for _,class in ipairs(character and character.Classes
            and character.Classes.Classes or {}) do
            local classId=tostring(class.ClassUUID or class.Class or "")
            local classLevel=tonumber(class.Level) or 0
            if classLevel>0 and IsValidGuid(classId) then
                currentClassSummary[#currentClassSummary+1]={
                    Name=ClassDisplayName(classId),Level=classLevel
                }
            end
        end
    end
    local choice = {
        Level = level,
        HistoryAvailable = levelUp ~= nil,
        CurrentClasses = currentClassSummary,
        Class = nil,
        SubClass = nil,
        Feat = nil,
        ClassPassives = {},
        ExtraResources = ExtraResourceSelectionsAtLevel(levelUp),
        EditablePassiveGroups = EditablePassiveGroupsAtLevel(levelUp),
        OtherChoices = BuildOtherHistoricalChoices(levelUp,level),
        Spells = {},
        ObservedSpells = {},
        CurrentSpellbook = {},
        CurrentSpellbookProbe = {},
        HistoryNote = levelUp and "" or "Level-up choice history is unavailable; progression spells shown separately are read-only observations, not proven selections.",
        Source = {
            ClassId = nil,
            SubClassId = nil,
            FeatId = nil,
            PassiveIds = {},
            ExtraResourceIds = {},
            SpellIds = {},
            ProgressionEntries = 0,
            SpellsComponents = 0,
            SkillsComponents = 0,
            AbilityImprovementComponents = 0,
        },
    }

    if level==1 and levelUp then
        local verifiedPassives={}
        for _,group in ipairs(choice.EditablePassiveGroups or {}) do
            if LevelOnePassiveOwnerMatches(levelUp,group,character) then
                group.LevelOneVerified=true
                verifiedPassives[#verifiedPassives+1]=group
            end
        end
        choice.EditablePassiveGroups=verifiedPassives
        local verifiedOther={}
        for _,candidate in ipairs(choice.OtherChoices or {}) do
            if candidate.Kind=="Skill" or candidate.Kind=="Expertise"
                or candidate.Kind=="Spell" or candidate.Kind=="Cantrip" then
                local rows=candidate.Source=="Skills" and levelUp.Upgrades.Skills
                    or candidate.Source=="SkillExpertise" and levelUp.Upgrades.SkillExpertise
                    or candidate.Source=="Spells" and levelUp.Spells
                    or candidate.Source=="Upgrades.Spells" and levelUp.Upgrades.Spells
                local row=rows and rows[candidate.EntryIndex]
                local valid=candidate.Editable==true and row~=nil
                if valid then
                    valid=LevelOneChoiceOwnerMatches(levelUp,row,candidate.Kind,
                        tostring(candidate.From),character)
                end
                if valid then
                    candidate.LevelOneVerified=true
                    verifiedOther[#verifiedOther+1]=candidate
                end
            end
        end
        choice.OtherChoices=verifiedOther
    end
    if levelUp then
        if IsValidGuid(levelUp.Class) then
            choice.Source.ClassId = tostring(levelUp.Class)
            choice.Class = ClassDisplayName(choice.Source.ClassId)
        end
        if IsValidGuid(levelUp.SubClass) then
            choice.Source.SubClassId = tostring(levelUp.SubClass)
            choice.SubClass = SubClassDisplayName(choice.Source.SubClassId)
        end
        if IsValidGuid(levelUp.Feat) then
            choice.Source.FeatId = tostring(levelUp.Feat)
            choice.Feat = FeatDisplayName(choice.Source.FeatId)
        end
    end

    -- Only spells explicitly in the character's level-up selection history;
    -- granted spells in ProgressionSpells are not necessarily chosen by player.
    local spellIds, seenSpells = {}, {}
    local function ScanSpellSelections(value, depth)
        if type(value) ~= "table" or depth > 10 then return end
        for key, item in pairs(value) do
            if (key == "SpellId" or key == "SpellID") and type(item) == "string" then
                if item ~= "" and not seenSpells[item] then
                    seenSpells[item] = true
                    spellIds[#spellIds + 1] = item
                end
            elseif type(item) == "table" then
                ScanSpellSelections(item, depth + 1)
            end
        end
    end
    if levelUp then
        ScanSpellSelections(levelUp.Spells, 0)
        ScanSpellSelections(levelUp.Upgrades and levelUp.Upgrades.Spells, 0)
    end
    table.sort(spellIds)
    for _, id in ipairs(spellIds) do
        choice.Spells[#choice.Spells + 1] = (id:gsub("^%w+_", ""):gsub("_", " "))
        choice.Source.SpellIds[#choice.Source.SpellIds + 1] = id
    end

    local selected = {}
    local seen = {}
    local allowed = GetHBClassPassives()
    local function Add(passiveId)
        if seen[passiveId] then return end
        seen[passiveId] = true
        selected[#selected + 1] = passiveId
    end

    FindSelectedPassives(levelUp, allowed, Add)

    local observed=ObservedProgressionSpells(character,level)
    choice.ObservedSpells=observed
    if not levelUp and level==tonumber(character and character.EocLevel
        and character.EocLevel.Level) then
        choice.CurrentSpellbook,choice.CurrentSpellbookProbe=ObserveCurrentSpellbook(character)
    end
    local container = character and character.ProgressionContainer
    local progressions = container and container.Progressions
    local bucket = progressions and progressions[level]
    for _, progressionEntity in ipairs(bucket or {}) do
        choice.Source.ProgressionEntries = choice.Source.ProgressionEntries + 1
        if progressionEntity.ProgressionSpells then
            choice.Source.SpellsComponents = choice.Source.SpellsComponents + 1
        end
        if progressionEntity.ProgressionSkills then
            choice.Source.SkillsComponents = choice.Source.SkillsComponents + 1
        end
        if progressionEntity.ProgressionAbilityImprovements then
            choice.Source.AbilityImprovementComponents = choice.Source.AbilityImprovementComponents + 1
        end
        for _, componentName in ipairs(PROGRESSION_SELECTION_COMPONENTS) do
            local component = progressionEntity[componentName]
            if component then
                local ok, serialized = pcall(Ext.Types.Serialize, component)
                if ok and serialized then
                    FindSelectedPassives(serialized, allowed, Add)
                end
            end
        end
    end

    table.sort(selected)
    -- A selected feat's secondary passive selector can use precisely the
    -- same native left-sidebar passive editor as class progression. Only
    -- label a group as FEAT-owned when EACH recorded pick occurs exactly once
    -- in a ProgressionFeat component whose Feat GUID is the recorded feat.
    -- Merely sharing a level is never evidence of ownership.
    if choice.Source.FeatId and #choice.EditablePassiveGroups>0 then
        local featMatches,replicatedMatches,foreignMatches={},{},{}
        for _,entity in ipairs(bucket or {}) do
            for _,componentName in ipairs({"ProgressionFeat","ProgressionReplicatedFeat"}) do
                local got,component=pcall(function() return entity[componentName] end)
                if got and component then
                    local serialized,data=pcall(Ext.Types.Serialize,component)
                    if serialized and type(data)=="table" then
                        local owned=tostring(data.Feat or "")==choice.Source.FeatId
                        for _,id in ipairs(data.AddPassives or {}) do
                            id=tostring(id)
                            local counts=not owned and foreignMatches
                                or (componentName=="ProgressionFeat" and featMatches or replicatedMatches)
                            counts[id]=(counts[id] or 0)+1
                        end
                    end
                end
            end
        end
        local rule=HBFeatXmlRule(choice.Source.FeatId)
        local isClassSpecialist=rule and rule.Kind=="PassiveChoices"
        local isElementalAdept=rule and rule.Kind=="ElementChoices"
        local isAbilityImprovement=rule and rule.Kind=="AbilityChoices"
        local isMultifaceted=rule and rule.Kind=="MixedChoices"
            and choice.Source.FeatId=="be0889d2-f9aa-472d-b942-592bff0f1ef3"
        -- A naturally recorded Yokebreaker may expose a single two-pick
        -- FEAT-owned passive selector. Do not hardcode the subclass/selector
        -- name: the exact owning feat, recorded selector, passive list and
        -- all selected grants are cross-checked before permitting edits.
        -- This NEVER creates/removes the Yokebreaker or changes its
        -- conditional subclass package (including ConditionId).
        local isRecordedYokebreakerPair=rule and rule.Kind=="SubclassGrant"
            and IsValidGuid(choice.Source.FeatId)
        local yokeOwnedRows,yokeOriginalRow=0,nil
        if isRecordedYokebreakerPair then
            for _,row in ipairs(levelUp and levelUp.Upgrades
                and levelUp.Upgrades.Passives or {}) do
                if tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==choice.Source.FeatId then
                    -- If a row even references this feat, it must be
                    -- structurally canonical. No partial package eligibility.
                    if tostring(row.Type or "")~="Feat"
                        or tostring(row.Class or "")~=choice.Source.FeatId then
                        yokeOwnedRows=-100;break
                    end
                    yokeOwnedRows=yokeOwnedRows+1
                    yokeOriginalRow=row
                end
            end
        end
        local mixedSkills={}
        if isMultifaceted then
            for _,row in ipairs(choice.OtherChoices or {}) do
                if row.Kind=="Skill" and row.FeatOwnerId==choice.Source.FeatId then
                    mixedSkills[tostring(row.From)]=true
                end
            end
        end
        local display=choice.Feat and choice.Feat.DisplayNameFallback
        local candidateGroups,choiceIds,matchedCount={}, {},0
        for _,group in ipairs(choice.EditablePassiveGroups) do
            local hasFeatEvidence=false
            local wasEditable=group.Editable~=false
            local verified=wasEditable and #(group.Picked or {})>0
            local elementGroup=isElementalAdept
                and tostring(group.SelectorId or "")==""
                and tostring(group.PassiveList or "")==HB_ELEMENTAL_ADEPT_LIST
                and #(group.Picked or {})==2
            -- An Elemental Adept group is only editable if ALL element
            -- passives are present in the exact recorded feat component.
            if isElementalAdept and not elementGroup then verified=false end
            local abilityGroup=isAbilityImprovement
                and (tostring(group.SelectorId or "")=="" or tostring(group.SelectorId or "")=="FeatASI")
                and tostring(group.PassiveList or "")==HB_ABILITY_IMPROVEMENT_LIST
                and #(group.Picked or {})==2
            if isAbilityImprovement and not abilityGroup then verified=false end
            local yokeTechniqueGroup=isRecordedYokebreakerPair
                and yokeOwnedRows==1 and yokeOriginalRow~=nil
                and tostring(group.SelectorId or "")~=""
                and IsValidGuid(group.PassiveList)
                and tostring(yokeOriginalRow.SelectorId or "")
                    ==tostring(group.SelectorId or "")
                and tostring(yokeOriginalRow.PassiveList or "")
                    ==tostring(group.PassiveList or "")
                and #(group.Picked or {})==2
                and #(yokeOriginalRow.Passives or {})==2
                and #(yokeOriginalRow.ReplacePassives or {})==0
            if isRecordedYokebreakerPair and not yokeTechniqueGroup then
                verified=false
            end
            for _,picked in ipairs(group.Picked or {}) do
                local id=tostring(picked)
                local primary,replica=featMatches[id] or 0,replicatedMatches[id] or 0
                if primary+replica>0 then hasFeatEvidence=true end
                if primary>1 or replica>1 or primary+replica==0
                    or (isRecordedYokebreakerPair and (primary~=1 or replica~=0))
                    or (foreignMatches[id] or 0)>0 or choiceIds[id] then
                    verified=false
                end
                if isElementalAdept and
                    (not elementGroup or not id:match("^ElementalAdept_[%a]+$")) then
                    verified=false
                end
                if isAbilityImprovement and
                    (not abilityGroup or not HB_ABILITY_IMPROVEMENT_IDS[id]) then
                    verified=false
                end
            end
            if hasFeatEvidence then
                candidateGroups[#candidateGroups+1]={Group=group,Verified=verified,
                    WasEditable=wasEditable}
                -- A partially proven feat group must NEVER fall back to the
                -- class passive editor, which could replay only some effects.
                group.FeatChoiceProtected=true
                group.FeatOwnerName=tostring(display or "Feat")
                group.Editable=false
                if verified then
                    for _,picked in ipairs(group.Picked or {}) do
                        choiceIds[tostring(picked)]=true
                        matchedCount=matchedCount+1
                    end
                end
            elseif isRecordedYokebreakerPair and yokeOriginalRow
                and tostring(group.SelectorId or "")==tostring(yokeOriginalRow.SelectorId or "")
                and tostring(group.PassiveList or "")==tostring(yokeOriginalRow.PassiveList or "") then
                -- Even when the entire feat grant is missing, the original
                -- FEAT-owned history row proves that this is NOT a class
                -- passive. Never expose it through the class editor.
                group.FeatChoiceProtected=true
                group.FeatOwnerName=tostring(display or "Yokebreaker")
                group.Editable=false
                RespecStartLog("YOKEBREAKER_PASSIVE_UNPROVEN level="..level
                    .." feat="..choice.Source.FeatId
                    .." selector="..tostring(group.SelectorId)
                    .." reason=missing_feat_grants")
            end
        end
        -- All two historical selections must be present, distinct, and
        -- attributable to this EXACT feat. A single matching passive is not
        -- sufficient evidence that the other Class Specialist choice exists.
        local mixedSkillCount=0
        for _ in pairs(mixedSkills) do mixedSkillCount=mixedSkillCount+1 end
        local complete=(isClassSpecialist or isElementalAdept or isAbilityImprovement
            or isRecordedYokebreakerPair
            or (isMultifaceted and mixedSkillCount==4))
            and matchedCount==2 and #candidateGroups>0
        if (isElementalAdept or isAbilityImprovement
            or isRecordedYokebreakerPair) and #candidateGroups~=1 then
            complete=false
        end
        for _,candidate in ipairs(candidateGroups) do
            if not candidate.Verified then complete=false end
        end
        if complete then
            for _,candidate in ipairs(candidateGroups) do
                local group=candidate.Group
                group.FeatOwnerVerified=true
                group.FeatOwnerId=choice.Source.FeatId
                group.FeatOwnerName=tostring(display or "Feat")
                group.FeatChoiceProtected=nil
                group.Editable=candidate.WasEditable
                RespecStartLog("FEAT_PASSIVE_OWNERSHIP_VERIFIED level="..level
                    .." feat="..choice.Source.FeatId
                    .." selector="..tostring(group.SelectorId)
                    .." choices="..#group.Picked.." total="..matchedCount)
            end
        elseif #candidateGroups>0 then
            RespecStartLog("FEAT_PASSIVE_OWNERSHIP_PROTECTED level="..level
                .." feat="..choice.Source.FeatId
                .." kind="..tostring(rule and rule.Kind or "unknown")
                .." matched="..matchedCount.." required=2")
        end
    end
    for _, id in ipairs(choice.ExtraResources) do
        choice.Source.ExtraResourceIds[#choice.Source.ExtraResourceIds + 1] = id
    end
    for _, id in ipairs(selected) do
        choice.ClassPassives[#choice.ClassPassives + 1] = PassiveDisplayName(id)
        choice.Source.PassiveIds[#choice.Source.PassiveIds + 1] = id
    end
    return choice
end

--- Diagnostic data only: store raw IDs and component presence for each level so
--- we can verify exactly what the game exposes before enabling historical edits.
--- This never writes to a savegame or modifies character progression.
local function SaveLevelViewerDiagnostics(characterGuid, levelChoices)
    local records = {}
    for index, choice in ipairs(levelChoices) do
        records[index] = {
            Level = index,
            HistoryAvailable = choice.HistoryAvailable,
            Source = choice.Source,
        }
    end
    local ok, err = pcall(function()
        local json = Ext.Json.Stringify({
            Version = 2,
            CharacterGuid = characterGuid,
            Levels = records,
        }, { Beautify = true, StringifyInternalTypes = false })
        if not json or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_ProgressionViewer_Diagnostics.json", json) then
            error("could not write diagnostic file")
        end
    end)
    if not ok then
        PRWarn(0, "Progression viewer diagnostic file failed: %s", tostring(err))
    end
end

--- Experimental read-only probe: the Extra Resource pick at a class's level 5/9
--- isn't in HB_CLASS_PASSIVE_IDS. Capture existing per-level choice components
--- so we can identify the actual serialized ID instead of guessing it.
--- No progression, passive, boost or character component is mutated here.
local EXTRA_RESOURCE_PROBE_COMPONENTS = {
    "ProgressionMeta", "ProgressionAbilityImprovements", "ProgressionFeat",
    "ProgressionSpells", "ProgressionSkills", "ProgressionPassives",
    "ProgressionReplicatedFeat", "LevelUp", "ProgressionBoosts",
}

local function ProbeSerialize(component, label)
    if not component then return nil end
    local ok, value = pcall(Ext.Types.Serialize, component)
    if not ok then
        return { SerializationError = tostring(value), Component = label }
    end
    if type(value) ~= "table" then
        return { SerializedValue = tostring(value), Component = label }
    end
    if label == "ProgressionMeta" then
        -- These C++ entity/map fields are not choices and can be huge or cyclic.
        value.Owner = nil
        value.MulticlassSpellSlotOverride = nil
        value.field_50 = nil
    end
    return value
end

local function SaveExtraResourceProbe(character, characterGuid, levelUps, characterLevel)
    local ok, err = pcall(function()
        local record = {
            Version = 1,
            Info = "Read-only per-level choices probe; no gameplay changes",
            CharacterLevel = characterLevel,
            CharacterGuid = characterGuid,
            LevelUpHistory = {},
            ProgressionBuckets = {},
        }

        -- Reading the whole level-up component avoids missing choices in nested
        -- fields that we haven't identified yet (including modded selections).
        record.CCLevelUp = ProbeSerialize(character.CCLevelUp, "CCLevelUp")
        local container = character.ProgressionContainer
        local buckets = container and container.Progressions
        for level = 1, characterLevel do
            local history = levelUps and levelUps[level]
            record.LevelUpHistory[level] = ProbeSerialize(history, "CCLevelUp.LevelUps[" .. level .. "]")
            local entries = {}
            for _, progressionEntity in ipairs((buckets and buckets[level]) or {}) do
                local entry = {}
                for _, componentName in ipairs(EXTRA_RESOURCE_PROBE_COMPONENTS) do
                    local accessible, component = pcall(function()
                        return progressionEntity[componentName]
                    end)
                    if accessible then
                        local serialized = ProbeSerialize(component, componentName)
                        if serialized then entry[componentName] = serialized end
                    else
                        entry[componentName .. "AccessError"] = tostring(component)
                    end
                end
                entries[#entries + 1] = entry
            end
            record.ProgressionBuckets[level] = entries
        end

        local json = Ext.Json.Stringify(record, {
            Beautify = true,
            StringifyInternalTypes = false,
        })
        if not json or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_ExtraResource_Diagnostics.json", json) then
            error("could not write HB_ExtraResource_Diagnostics.json")
        end
    end)
    if not ok then
        PRWarn(0, "Extra Resource read-only diagnostics failed: %s", tostring(err))
    end
end

--- Summarizes classes/subclasses/feats gained through the cutoff level for the popup and toast.
---@param character EntityHandle
---@param levelUps table|nil
---@param cutoff integer
---@return table
local function BuildLevelSummary(character, levelUps, cutoff)
    local classLevels = {}
    local classOrder = {}
    local feats = {}
    local featKeys = {}

    local function AddFeat(guid, name)
        local key = guid and tostring(guid) or name
        if not key or featKeys[key] then return end
        featKeys[key] = true
        feats[#feats + 1] = name and {
            DisplayNameHandle = nil,
            DisplayNameFallback = name,
        } or FeatDisplayName(key)
    end

    for level = 1, cutoff do
        local levelUp = levelUps and levelUps[level]
        if levelUp then
            if IsValidGuid(levelUp.Class) then
                local classGuid = tostring(levelUp.Class)
                if not classLevels[classGuid] then
                    classLevels[classGuid] = { Level = 0, SubClass = nil }
                    classOrder[#classOrder + 1] = classGuid
                end
                classLevels[classGuid].Level = classLevels[classGuid].Level + 1
                if IsValidGuid(levelUp.SubClass) then
                    classLevels[classGuid].SubClass = tostring(levelUp.SubClass)
                end
            end

            if IsValidGuid(levelUp.Feat) then
                AddFeat(tostring(levelUp.Feat))
            end
        end
    end

    local classes = {}
    local subclasses = {}
    for _, classGuid in ipairs(classOrder) do
        local info = classLevels[classGuid]
        classes[#classes + 1] = {
            Name = ClassDisplayName(classGuid),
            Level = info.Level,
        }
        if info.SubClass then
            subclasses[#subclasses + 1] = SubClassDisplayName(info.SubClass)
        end
    end

    return {
        Level = cutoff,
        Classes = classes,
        Subclasses = subclasses,
        Feats = feats,
        ClassPassives = ClassPassivesThroughLevel(character, levelUps, cutoff),
        ExtraResources = ExtraResourcesThroughLevel(levelUps, cutoff),
        LevelChoices = BuildLevelChoices(character, levelUps, cutoff),
    }
end

--- Resolves the numeric user id whose viewer sees the respec screen.
--- Uses PartyView ownership: the target character belongs to a view whose UserID identifies the owning player.
--- Scans every PartyView entity (MP may create one per player). Falls back to the host's reserved user.
---@param characterGuid string
---@return integer
local function RespecViewerUser(characterGuid)
    local ok,parties=pcall(Ext.Entity.GetAllEntitiesWithComponent,"PartyView")
    for _,party in pairs(ok and parties or {}) do
        for _,view in pairs((party.PartyView and party.PartyView.Views) or {}) do
            for _,char in pairs(view.Characters or {}) do
                if char.Uuid and Guid(char.Uuid.EntityUuid)==characterGuid then
                    return view.UserID
                end
            end
        end
    end
    return Osi.GetReservedUserID(Osi.GetHostCharacter())
end

--- When resolving a complex caster spell record fails, preserve the level
--- index and allow a vanilla/full respec. Never fabricate an editable choice.
local function UnavailableLevelSummary(level, reason)
    return {
        Level=level, Classes={}, Subclasses={}, Feats={},
        ClassPassives={}, ExtraResources={},
        LevelChoices={Level=level, HistoryAvailable=false,
            Class=nil,SubClass=nil,Feat=nil,Spells={},ClassPassives={},
            ExtraResources={},EditablePassiveGroups={},OtherChoices={},
            ObservedSpells={},CurrentSpellbook={},HistoryNote="Historical level failed to load; editing disabled",
            Error=tostring(reason or "History unavailable")},
    }
end

local function SendPendingPopup(characterGuid, state, reason)
    if not state or state.level or state.snapshot then return end
    if state.summaries == nil then
        RespecStartLog("POPUP_NOT_READY actor="..tostring(characterGuid)
            .." reason="..tostring(reason))
        return
    end
    local viewer=RespecViewerUser(characterGuid)
    local ok,err=pcall(function()
        PartialRespecChannel:SendToClient({Character=characterGuid,
            MaxLevel=state.charLevel,LevelSummaries=state.summaries,Visible=true},viewer)
    end)
    RespecStartLog("POPUP_SEND actor="..tostring(characterGuid)
        .." level="..tostring(state.charLevel).." user="..tostring(viewer)
        .." via="..tostring(reason).." ok="..tostring(ok)
        ..(ok and "" or " error="..tostring(err)))
end

-- Native BG3 respec is allowed to rebuild the player's level-one foundation.
-- That rebuild can also clear an entirely unrelated customized action bar and
-- leave the live Health max at its temporary level-one value until reload.
-- Capture only for the active Selective Respec transaction; no global polling,
-- game save mutations or scripts copied from another mod.
local function NativePresentationAbilityScores(character)
    local ok,values=pcall(function()
        local stats=character and character.Stats
        local abilities=stats and stats.Abilities
        if not abilities then return nil end
        local out={}
        for i=1,7 do
            local value=tonumber(abilities[i])
            if not value then return nil end
            out[i]=value
        end
        return out
    end)
    return ok and values or nil
end

local function NativePresentationCapture(character)
    if not character then return nil end
    local captured={}
    local hpOK,hp,hpMax=pcall(function()
        local health=character.Health
        return health and tonumber(health.Hp),health and tonumber(health.MaxHp)
    end)
    if hpOK and hp and hpMax and hpMax>0 and hp>=0 and hp<=hpMax then
        captured.Health={Hp=hp,MaxHp=hpMax,Abilities=NativePresentationAbilityScores(character)}
    end
    local barOK,bars=pcall(function()
        local component=character.HotbarContainer
        local holder=component and component.Containers
        local source=holder and holder.DefaultBarContainer
        return source and Ext.Types.Serialize(source)
    end)
    if barOK and type(bars)=="table" and #bars>0 and #bars<=96 then
        local entries=0
        local valid=true
        for _,bar in ipairs(bars) do
            if type(bar)~="table" or type(bar.Elements)~="table"
                or #bar.Elements>256 then valid=false;break end
            for _,element in ipairs(bar.Elements) do
                if type(element)=="table" and (
                    (type(element.SpellId)=="table" and
                        type(element.SpellId.Prototype)=="string" and
                        element.SpellId.Prototype~="") or
                    (type(element.Passive)=="string" and element.Passive~="")) then
                    entries=entries+1
                end
            end
        end
        if valid and entries>0 and entries<=1200 then
            captured.Hotbars=bars
            captured.HotbarEntries=entries
        end
    end
    return next(captured) and captured or nil
end

local function NativePresentationSpellKey(id)
    if type(id)~="table" then return nil end
    local proto=tostring(id.Prototype or "")
    if proto=="" then return nil end
    return table.concat({
        proto,tostring(id.OriginatorPrototype or ""),
        tostring(id.ProgressionSource or ""),tostring(id.Source or ""),
        tostring(id.SourceType or "")},"|")
end

-- Never restore old feat-action tiles blindly after replacing that feat.
-- The saved hotbar can contain stale powers no longer in the restored build.
-- A hotbar action is eligible only if its exact spell identity exists in
-- the current verified live SpellBook. Existing newly granted actions are
-- preserved in otherwise free slots, without replacing the owner's layout.
-- BG3 can serialize several bars with identical (or unexposed) Index and
-- field_1 values.  The earlier matcher treated all of those as corrupt and
-- skipped the restore.  Prefer a unique key when it genuinely exists.  When
-- the engine provides duplicate/missing keys, use ordinal correspondence ONLY
-- if every original and live bar has the same immutable exposed metadata.
-- This never creates/deletes a bar or changes its own native metadata.
local function NativePresentationBarKey(bar)
    if type(bar)~="table" then return nil end
    if bar.Index==nil or bar.field_1==nil then return nil end
    return tostring(bar.field_1)..":"..tostring(bar.Index)
end

local function NativePresentationBarShape(bars)
    if type(bars)~="table" then return "none" end
    local missing,duplicates,keys=0,0,{}
    local first={}
    for i,bar in ipairs(bars) do
        local key=NativePresentationBarKey(bar)
        if not key then missing=missing+1
        elseif keys[key] then duplicates=duplicates+1
        else keys[key]=true end
        if i<=4 then
            local slots,missingSlots=0,0
            for _,entry in ipairs(type(bar)=="table" and bar.Elements or {}) do
                if type(entry)=="table" then
                    if tonumber(entry.Slot) then slots=slots+1 else missingSlots=missingSlots+1 end
                end
            end
            first[#first+1]=tostring(i).."[index="..tostring(bar and bar.Index)
                ..",mode="..tostring(bar and bar.field_1)
                ..",elements="..tostring(bar and bar.Elements and #bar.Elements or 0)
                ..",slots="..slots..",noSlot="..missingSlots.."]"
        end
    end
    return "bars="..tostring(#bars).." missingKeys="..tostring(missing)
        .." duplicateKeys="..tostring(duplicates).." first="..table.concat(first,",")
end

local function NativePresentationMatchBars(priorBars,currentBars)
    if type(priorBars)~="table" or type(currentBars)~="table" then
        return nil,"missing bar data"
    end
    if #priorBars==0 or #priorBars>96 or #currentBars==0 or #currentBars>96 then
        return nil,"bar count outside limits"
    end
    local byKey={}
    local unique=true
    for _,bar in ipairs(priorBars) do
        local key=NativePresentationBarKey(bar)
        if not key or byKey[key] then unique=false;break end
        byKey[key]=bar
    end
    if unique then
        local seen={}
        local matched={}
        for i,bar in ipairs(currentBars) do
            local key=NativePresentationBarKey(bar)
            if not key or seen[key] then unique=false;break end
            seen[key]=true
            matched[i]=byKey[key]
        end
        if unique then return matched,"unique-id" end
    end
    -- Original and live bar count, ordering and stable metadata must all
    -- agree before using ordinal pairing for duplicate/missing engine IDs.
    -- Never pair different keyboard/controller layouts just by array length.
    if #priorBars~=#currentBars then
        return nil,"duplicate identifiers with unequal bar counts original="
            ..#priorBars.." live="..#currentBars
    end
    local fixed={"Index","field_1","Type","BarType","ContainerType","Id","ID","Name"}
    for i,bar in ipairs(currentBars) do
        local prior=priorBars[i]
        if type(prior)~="table" or type(bar)~="table"
            or type(prior.Elements)~="table" or type(bar.Elements)~="table"
            or #prior.Elements>256 or #bar.Elements>256 then
            return nil,"invalid bar elements at ordinal "..i
        end
        for _,field in ipairs(fixed) do
            if prior[field]~=bar[field] then
                return nil,"ordinal metadata mismatch at "..i.." field="..field
                    .." original="..tostring(prior[field])
                    .." live="..tostring(bar[field])
            end
        end
    end
    return priorBars,"ordinal-compatible"
end

-- Never restore old feat-action tiles blindly after replacing that feat.
-- The saved hotbar can contain stale powers no longer in the restored build.
-- A hotbar spell action is eligible only if its exact spell identity exists
-- in the final audited live SpellBook. Unverified nonspell entries remain in
-- their post-native state rather than re-granting a removed passive or item.
-- SpellBook.Spells is an SE native array of light C++ objects.  Do not call
-- Lua type(id)=="table" on its SpellId proxies: that made liveIds empty even
-- though the original serialized hotbar contained dozens of valid entries.
-- Read both sides through Ext.Types.Serialize before comparing identities.
local function NativePresentationLiveSpellIndex(character)
    local spells=character and character.SpellBook and character.SpellBook.Spells
    if not spells then return nil,"live spellbook unavailable" end
    local ok,rows=pcall(Ext.Types.Serialize,spells)
    if not ok or type(rows)~="table" then
        -- Some extender versions permit serializing a component but not
        -- its nested C++ array by itself.
        local fullOK,full=pcall(Ext.Types.Serialize,character.SpellBook)
        rows=fullOK and type(full)=="table" and full.Spells or nil
    end
    if type(rows)~="table" or #rows>2048 then
        return nil,"live SpellBook.Spells could not be serialized"
    end
    local exact,byPrototype,conflicted,count={},{},{},0
    for _,row in ipairs(rows) do
        local id=type(row)=="table" and row.Id
        if type(id)=="table" and type(id.Prototype)=="string" and id.Prototype~="" then
            count=count+1
            local key=NativePresentationSpellKey(id)
            if key then exact[key]=id end
            local name=id.Prototype
            if byPrototype[name] then
                -- Ambiguous ownership: do not bind an old slot to an arbitrary
                -- duplicate grant, even if a different feat happens to add it.
                conflicted[name]=true
            else
                byPrototype[name]=id
            end
        end
    end
    return {Exact=exact,ByPrototype=byPrototype,Conflict=conflicted,Count=count},nil
end

local function NativePresentationResolveSlot(id,index)
    local proto=type(id)=="table" and id.Prototype
    if type(proto)~="string" or proto=="" then return nil,"unrecognized" end
    local key=NativePresentationSpellKey(id)
    if key and index.Exact[key] then return index.Exact[key],"exact" end
    if index.Conflict[proto] then return nil,"ambiguous" end
    local match=index.ByPrototype[proto]
    if match then return match,"unique-prototype" end
    return nil,"removed"
end

local function NativePresentationRestoreHotbar(actor,character,saved)
    if type(saved)~="table" or type(saved.Hotbars)~="table" then
        return false,"no captured hotbar"
    end
    local component=character and character.HotbarContainer
    local source=component and component.Containers and component.Containers.DefaultBarContainer
    if not source then return false,"live hotbar unavailable" end
    local index,indexWhy=NativePresentationLiveSpellIndex(character)
    if not index then return false,indexWhy end
    local now=Ext.Types.Serialize(source)
    if type(now)~="table" or #now==0 or #now>96 then
        return false,"live hotbar layout is unavailable"
    end
    local matched,method=NativePresentationMatchBars(saved.Hotbars,now)
    if not matched then
        return false,tostring(method).." original={"..NativePresentationBarShape(saved.Hotbars)
            .."} live={"..NativePresentationBarShape(now).."}"
    end
    local restored,rebinding,exact,obsolete,preserved,ambiguous=0,0,0,0,0,0
    local resulting={}
    for i,bar in ipairs(now) do
        local prior=matched[i]
        if type(bar)~="table" or type(bar.Elements)~="table" or #bar.Elements>256 then
            return false,"unexpected live bar at "..i
        end
        local output={}
        local occupied={}
        local already={}
        if prior then
            for _,entry in ipairs(prior.Elements) do
                if type(entry)=="table" and type(entry.SpellId)=="table" then
                    local slot=tonumber(entry.Slot)
                    local currentId,matchKind=NativePresentationResolveSlot(entry.SpellId,index)
                    if slot and slot>=0 and slot<=255 and currentId and not occupied[slot] then
                        local replacement={}
                        for k,v in pairs(entry) do replacement[k]=v end
                        -- Source/progression grants may be rewritten by vanilla
                        -- native respec. Always use the CURRENT proven spell Id,
                        -- never reinsert the stale original feat/class source.
                        replacement.SpellId=currentId
                        output[#output+1]=replacement
                        occupied[slot]=true
                        already[NativePresentationSpellKey(currentId)]=true
                        restored=restored+1
                        if matchKind=="exact" then exact=exact+1
                        else rebinding=rebinding+1 end
                    elseif matchKind=="removed" then obsolete=obsolete+1
                    elseif matchKind=="ambiguous" then ambiguous=ambiguous+1 end
                end
            end
        end
        for _,entry in ipairs(bar.Elements) do
            local slot=type(entry)=="table" and tonumber(entry.Slot)
            local spellId=type(entry)=="table" and entry.SpellId
            local currentId=type(spellId)=="table" and NativePresentationResolveSlot(spellId,index) or nil
            local entryIsSpell=type(spellId)=="table" and type(spellId.Prototype)=="string"
                and spellId.Prototype~=""
            -- Keep unchanged native nonspell actions (items, passives, etc.).
            -- A spell not in the current book cannot be carried over from
            -- the newly generated hotbar, either.
            local valid=not entryIsSpell or currentId~=nil
            local key=currentId and NativePresentationSpellKey(currentId)
            if slot and slot>=0 and slot<=255 and valid and not occupied[slot]
                and (not key or not already[key]) then
                if entryIsSpell and currentId then
                    local replacement={}
                    for k,v in pairs(entry) do replacement[k]=v end
                    replacement.SpellId=currentId
                    output[#output+1]=replacement
                else
                    output[#output+1]=entry
                end
                occupied[slot]=true
                if key then already[key]=true end
                preserved=preserved+1
            end
        end
        local replacement={}
        for k,v in pairs(bar) do replacement[k]=v end
        if prior then replacement.Elements=output end
        resulting[#resulting+1]=replacement
    end
    if restored==0 then
        return false,"no independently verified surviving original spell slots"
            .." ("..tostring(method).." live="..index.Count
            .." original="..tostring(saved.HotbarEntries or 0)
            .." stale="..obsolete.." conflicting="..ambiguous..")"
    end
    Ext.Types.Unserialize(source,resulting)
    character:MarkChanged("HotbarContainer")
    character:Replicate("HotbarContainer")
    return true,"method="..tostring(method).." live="..index.Count
        .." restored="..restored.." exact="..exact.." rebound="..rebinding
        .." removedStale="..obsolete.." conflicting="..ambiguous
        .." retainedNew="..preserved
end

-- Read-only diagnostic for the removal-only hotbar regression.  The native
-- level-one rebuild and later historical replay may each invalidate spell
-- shortcuts. Capture WHICH phase first drops them, rather than rewriting
-- another hotbar or masking a missing class spell. Bounded and session-local.
local function NativePresentationTraceHotbar(actor,saved,phase)
    if type(saved)~="table" or type(saved.Hotbars)~="table" then return end
    local ok,why=pcall(function()
        local actorEntity=Ext.Entity.Get(actor)
        local holder=actorEntity and actorEntity.HotbarContainer
            and actorEntity.HotbarContainer.Containers
        local nativeBars=holder and holder.DefaultBarContainer
        local now=nativeBars and Ext.Types.Serialize(nativeBars)
        if type(now)~="table" then
            RespecStartLog("NATIVE_L1_HOTBAR_PHASE actor="..actor
                .." stage="..phase.." status=missing_native_layout")
            return
        end
        local index=NativePresentationLiveSpellIndex(actorEntity)
        local function Key(row)
            if type(row)~="table" then return nil end
            local sid=row.SpellId
            if type(sid)=="table" and type(sid.Prototype)=="string"
                and sid.Prototype~="" then
                return "spell:"..sid.Prototype
            end
            if type(row.Passive)=="string" and row.Passive~="" then
                return "passive:"..row.Passive
            end
            -- Non-spell entries still count as stable occupied slots.
            if row.Item or row.ItemId then return "item" end
            return "other"
        end
        local beforeTotal,nowTotal,matched,missing,changed,stillKnown,removed=0,0,0,0,0,0,0
        local first={}
        local barCounts={}
        for i,before in ipairs(saved.Hotbars) do
            local after=now[i]
            local slots={}
            if type(after)=="table" and type(after.Elements)=="table" then
                for _,row in ipairs(after.Elements) do
                    local slot=type(row)=="table" and tonumber(row.Slot)
                    if slot~=nil then slots[slot]=slots[slot] or Key(row) end
                    nowTotal=nowTotal+1
                end
            end
            local beforeCount=type(before)=="table" and type(before.Elements)=="table"
                and #before.Elements or 0
            if i<=4 then
                barCounts[#barCounts+1]=i..":"..beforeCount..">"
                    ..(after and after.Elements and #after.Elements or -1)
            end
            for _,old in ipairs(type(before)=="table" and before.Elements or {}) do
                beforeTotal=beforeTotal+1
                local slot=type(old)=="table" and tonumber(old.Slot)
                local oldKey=Key(old)
                local newKey=slot and slots[slot] or nil
                if newKey==oldKey then
                    matched=matched+1
                else
                    if not newKey then missing=missing+1 else changed=changed+1 end
                    local proto=type(old)=="table" and type(old.SpellId)=="table"
                        and old.SpellId.Prototype or nil
                    if proto then
                        if index and index.ByPrototype and index.ByPrototype[proto] then
                            stillKnown=stillKnown+1
                        else
                            removed=removed+1
                        end
                    end
                    if #first<18 then
                        first[#first+1]=i..":"..tostring(slot)..":"
                            ..tostring(oldKey)..">"..tostring(newKey or "empty")
                    end
                end
            end
        end
        RespecStartLog("NATIVE_L1_HOTBAR_PHASE actor="..actor
            .." stage="..phase.." barCounts="..table.concat(barCounts,",")
            .." old="..beforeTotal.." live="..nowTotal
            .." sameSlot="..matched.." missing="..missing
            .." replaced="..changed.." missingButStillLearned="..stillKnown
            .." missingAndNotLearned="..removed
            .." examples="..table.concat(first,","))
    end)
    if not ok then
        RespecStartLog("NATIVE_L1_HOTBAR_PHASE_ERROR actor="..actor
            .." stage="..phase.." reason="..tostring(why))
    end
end

local function NativePresentationRestoreHealth(character,saved)
    local old=type(saved)=="table" and saved.Health
    if type(old)~="table" or type(old.Abilities)~="table" then
        return false,"no verified original Health and ability scores"
    end
    local current=character and character.Health
    if not current then return false,"live health component unavailable" end
    local now=NativePresentationAbilityScores(character)
    if not now then return false,"live ability scores unavailable" end
    for i=1,7 do
        if now[i]~=old.Abilities[i] then
            return false,"an ability score legitimately changed"
        end
    end
    local maximum=tonumber(current.MaxHp)
    local hp=tonumber(current.Hp)
    local previous=tonumber(old.MaxHp)
    local original=tonumber(old.Hp)
    if not maximum or not hp or not previous or not original or maximum<=0
        or previous<=0 or previous>100000 or original<0 or original>previous then
        return false,"health maximum or original amount is invalid"
    end
    if maximum>=previous then return false,"engine HP already recalculated" end
    -- Only a LOWER maximum after restored class levels is repaired. An
    -- increased maximum, changed CON or changed class history is left alone.
    -- Reconcile actual Hp as well as MaxHp, then replicate native Health.
    current.MaxHp=previous
    current.Hp=math.max(0,math.min(previous,original))
    character:MarkChanged("Health")
    character:Replicate("Health")
    return true,"before="..maximum.."/"..hp
        .." after="..previous.."/"..original
end

-- Native respec temporarily leaves Health.MaxHp at its level-one value.
-- For an imported MULTICLASS build, the receiving character's old full
-- class HP is not the correct target. Derive a fresh maximum only when the
-- original max exactly matches the installed original classes and unchanged
-- Constitution score. Fail closed for HP-granting feats/boosts and unknown
-- custom class health rules; never guess at a new permanent HP maximum.
local function NativePresentationRestoreImportedClassHealth(character,saved,original,merged)
    local old=type(saved)=="table" and saved.Health
    local previous=old and tonumber(old.MaxHp)
    local startingHp=old and tonumber(old.Hp)
    if type(old)~="table" or type(old.Abilities)~="table"
        or not previous or not startingHp or previous<1 or startingHp<0
        or startingHp>previous then
        return false,"original health and ability scores are unavailable"
    end
    if type(merged)~="table" or type(merged.hbBuildPresetImport)~="table"
        or merged.hbBuildPresetImport.ClassChange~=true then
        return false,"not a verified class-changing build import"
    end
    local current=character and character.Health
    if not current then return false,"live health component unavailable" end
    local scores=NativePresentationAbilityScores(character)
    if not scores then return false,"live ability scores unavailable" end
    for i=1,7 do
        if scores[i]~=old.Abilities[i] then
            return false,"ability scores changed; class-only HP calculation unsafe"
        end
    end
    -- Stats.Abilities is 1-offset: Constitution is index 4, not Dexterity (3).
    -- Reuse the same verified index map as historical ability progression.
    local con=tonumber(old.Abilities[HB_ABILITY_INDICES.Constitution])
    if not con or con<1 or con>40 or con~=math.floor(con) then
        return false,"original Constitution score is not verified"
    end
    local origUps=type(original)=="table" and original.components
        and original.components.ccLevelUp and original.components.ccLevelUp.LevelUps
    local newUps=merged.components and merged.components.ccLevelUp
        and merged.components.ccLevelUp.LevelUps
    local count=type(origUps)=="table" and #origUps or 0
    if type(newUps)~="table" or count<2 or count~=#newUps
        or count~=tonumber(character.EocLevel and character.EocLevel.Level)
        or tostring(origUps[1] and origUps[1].Class or "")
            ~=tostring(newUps[1] and newUps[1].Class or "") then
        return false,"original and imported level history are incompatible"
    end
    if not Ext.StaticData or not Ext.StaticData.Get then
        return false,"installed class HP metadata is unavailable"
    end
    local cache={}
    local function ClassHP(id,field)
        id=tostring(id or "")
        if id=="" or id=="00000000-0000-0000-0000-000000000000" then
            return nil
        end
        if not cache[id] then
            local ok,data=pcall(Ext.StaticData.Get,id,"ClassDescription")
            if not ok or not data then return nil end
            cache[id]=data
        end
        local ok,value=pcall(function() return cache[id][field] end)
        local hp=ok and tonumber(value) or nil
        return hp and hp>=1 and hp<=100 and hp==math.floor(hp) and hp or nil
    end
    local base=ClassHP(origUps[1].Class,"BaseHp")
    if not base then return false,"original base-class HP is unknown" end
    local former,newTotal=base,base
    for level=2,count do
        local a=origUps[level] and ClassHP(origUps[level].Class,"HpPerLevel")
        local b=newUps[level] and ClassHP(newUps[level].Class,"HpPerLevel")
        if not a or not b then
            return false,"installed class HP-per-level metadata missing at level "..level
        end
        former=former+a
        newTotal=newTotal+b
    end
    local bonus=count*math.floor((con-10)/2)
    former=former+bonus
    newTotal=newTotal+bonus
    if former~=previous then
        return false,"original maximum includes unverified HP modifiers: expected="
            ..former.." observed="..previous
    end
    if newTotal<1 or newTotal>100000 then
        return false,"calculated imported HP is outside expected bounds"
    end
    local maximum=tonumber(current.MaxHp)
    local hp=tonumber(current.Hp)
    if not maximum or maximum<1 or not hp or hp<0 or hp>maximum then
        return false,"current health values are invalid"
    end
    if maximum==newTotal then return false,"native health already correct" end
    if maximum>newTotal then
        return false,"native health has additional modifiers; will not overwrite"
    end
    -- Preserve the original number of missing hit points. No unrelated
    -- spellbook, level, action-bar, or ability-score changes are made.
    local finalHp=math.max(0,math.min(newTotal,newTotal-(previous-startingHp)))
    current.MaxHp=newTotal
    current.Hp=finalHp
    character:MarkChanged("Health")
    character:Replicate("Health")
    return true,"before="..maximum.."/"..hp.." after="..newTotal.."/"..finalHp
        .." formula=verified_class_delta"
end

-- Diagnostic-only spell-rank provenance for class-changing build imports.
-- BG3 can keep an engine-owned numbered cast variant in SpellBook even when
-- historical CCLevelUp and ProgressionSpells record the unsuffixed root.
-- NEVER rewrite a SpellId, add/remove a spell, or interpret a bare _2.._6
-- suffix as proof of an upcast. Observe the exact live owned variant and its
-- installed RootSpellID/Level before considering a future corrective patch.
local function NativeBuildPresetSpellRankProbe(actor,merged,phase)
    if type(merged)~="table" then return end
    local ok,err=pcall(function()
        local character=Ext.Entity.Get(actor)
        if not character or not character.SpellBook then
            error("live spellbook unavailable")
        end
        local good,book=pcall(Ext.Types.Serialize,character.SpellBook)
        if not good or type(book)~="table" or type(book.Spells)~="table"
            or #book.Spells>2048 then error("live spellbook serialization failed") end
        local levelups=merged.components and merged.components.ccLevelUp
            and merged.components.ccLevelUp.LevelUps
        if type(levelups)~="table" or #levelups>30 or #levelups<1 then
            error("expected CC history unavailable")
        end
        local count,numbered,roots,missing,ambiguous=0,0,0,0,0
        local mode=type(merged.hbBuildPresetImport)=="table" and "build-preset"
            or "historical-respec"
        local prior={}
        local function GetStat(name)
            if not Ext or not Ext.Stats or not Ext.Stats.Get
                or type(name)~="string" or name=="" then return nil end
            local exists,data=pcall(Ext.Stats.Get,name)
            if not exists or not data then return nil end
            local safe,result=pcall(function()
                return {Root=tostring(data.RootSpellID or ""),
                    Level=tostring(data.Level or ""),
                    Type=tostring(data.SpellType or "")}
            end)
            return safe and result or nil
        end
        local function HasSpell(name)
            if not Osi or not Osi.HasSpell then return "n/a" end
            local success,result=pcall(function() return Osi.HasSpell(actor,name) end)
            return success and tostring(result) or "error"
        end
        for level,up in ipairs(levelups) do
            for _,selection in ipairs(up.Upgrades and up.Upgrades.Spells or {}) do
                local role=selection.Type=="Class" and "ProgressionClass"
                    or selection.Type=="SubClass" and "ProgressionSubClass"
                    or selection.Type=="Feat" and "Feat" or nil
                local owner=tostring(selection.Class or "")
                for _,picked in ipairs(selection.Spells or {}) do
                    local root=type(picked)=="table" and picked.SpellId or picked
                    if type(root)=="string" and root~="" and role and count<64 then
                        local identity=role.."/"..owner.."/"..root
                        if not prior[identity] then
                            prior[identity]=true;count=count+1
                            local matches={}
                            for _,row in ipairs(book.Spells) do
                                local id=type(row)=="table" and row.Id
                                if type(id)=="table"
                                    and (id.OriginatorPrototype==root or id.Prototype==root)
                                    and tostring(id.SourceType or "")==role
                                    and tostring(id.ProgressionSource or "")==owner then
                                    matches[#matches+1]=id
                                end
                            end
                            if #matches==0 then missing=missing+1 end
                            if #matches>1 then ambiguous=ambiguous+1 end
                            local baseStat=GetStat(root)
                            for _,id in ipairs(matches) do
                                local live=tostring(id.Prototype or "")
                                if live==root then roots=roots+1 end
                                local suffix=live:match("_([2-6])$")
                                if suffix then numbered=numbered+1 end
                                local stat=GetStat(live)
                                local text="NATIVE_BUILD_SPELL_RANK actor="..actor
                                    .." phase="..phase.." mode="..mode.." level="..level
                                    .." root="..root.." actual="..live
                                    .." role="..role.." owner="..owner
                                    .." count="..#matches
                                    .." source="..tostring(id.Source or "")
                                    .." rootLevel="..tostring(baseStat and baseStat.Level or "missing")
                                    .." actualLevel="..tostring(stat and stat.Level or "missing")
                                    .." installedRoot="..tostring(stat and stat.Root or "missing")
                                    .." rootType="..tostring(baseStat and baseStat.Type or "missing")
                                    .." actualType="..tostring(stat and stat.Type or "missing")
                                    .." hasRoot="..HasSpell(root)
                                    .." hasActual="..HasSpell(live)
                                RespecStartLog(text)
                            end
                            if #matches==0 then
                                RespecStartLog("NATIVE_BUILD_SPELL_RANK_MISSING actor="..actor
                                    .." phase="..phase.." mode="..mode.." level="..level
                                    .." root="..root.." role="..role.." owner="..owner)
                            end
                        end
                    end
                end
            end
        end
        RespecStartLog("NATIVE_BUILD_SPELL_RANK_SUMMARY actor="..actor
            .." phase="..phase.." mode="..mode.." choices="..count.." rootRows="..roots
            .." numberedRows="..numbered.." missing="..missing
            .." ambiguous="..ambiguous.." spellRows="..#book.Spells
            .." action=observe_only")
    end)
    if not ok then
        RespecStartLog("NATIVE_BUILD_SPELL_RANK_PROBE_ERROR actor="..actor
            .." phase="..phase.." reason="..tostring(err))
    end
end

local function NativePresentationAfterAudit(actor,saved,originalLevel,merged,original)
    if type(saved)~="table" then return end
    Ext.Timer.WaitFor(250,function()
        local okay,reason=pcall(function()
            local current=Ext.Entity.Get(actor)
            if not current or tonumber(current.EocLevel and current.EocLevel.Level)
                ~=tonumber(originalLevel) then
                return false,"original level was not restored"
            end
            local changingClasses=type(merged)=="table"
                and type(merged.hbBuildPresetImport)=="table"
                and merged.hbBuildPresetImport.ClassChange==true
            local healed,healthApplied,healthWhy=pcall(
                changingClasses and NativePresentationRestoreImportedClassHealth
                    or NativePresentationRestoreHealth,
                current,saved,original,merged)
            RespecStartLog("NATIVE_L1_HEALTH_RECONCILE actor="..actor
                .." classChange="..tostring(changingClasses)
                .." applied="..tostring(healed and healthApplied==true)
                .." result="..tostring(healed and healthWhy or healthApplied))
            -- Regression isolation: do NOT rewrite HotbarContainer here.
            -- The Aegis post-audit correction introduced a second full
            -- SpellBook Unserialize/Replicate; this can cause BG3 to rebuild
            -- its own hotbar. Preserve engine-managed layout and observe it.
            local hotbarCount=0
            local okBars,bars=pcall(function()
                local holder=current.HotbarContainer and current.HotbarContainer.Containers
                return holder and holder.DefaultBarContainer
                    and Ext.Types.Serialize(holder.DefaultBarContainer)
            end)
            if okBars and type(bars)=="table" then
                for _,b in ipairs(bars) do
                    if type(b)=="table" and type(b.Elements)=="table" then
                        hotbarCount=hotbarCount+#b.Elements
                    end
                end
            end
            NativePresentationTraceHotbar(actor,saved,"post-audit")
            NativeBuildPresetSpellRankProbe(actor,merged,"post-audit")
            Ext.Timer.WaitFor(1500,function()
                NativePresentationTraceHotbar(actor,saved,"post-audit-plus-1500ms")
                NativeBuildPresetSpellRankProbe(actor,merged,"post-audit-plus-1500ms")
            end)
            RespecStartLog("NATIVE_L1_HOTBAR_ENGINE_PASSTHROUGH actor="..actor
                .." captured="..tostring(saved.HotbarEntries or 0)
                .." live="..tostring(hotbarCount)
                .." operation=none")
            return true,"checked"
        end)
        if not okay then
            RespecStartLog("NATIVE_L1_PRESENTATION_ERROR actor="..actor
                .." reason="..tostring(reason))
        elseif reason==false then
            RespecStartLog("NATIVE_L1_PRESENTATION_SKIPPED actor="..actor
                .." reason=original_level_not_restored")
        end
    end)
end

--- Prepare per-level data in protected segments: optional diagnostics, caster
--- spell scans, and feat catalog failures cannot cancel the entire dialog.
local function BeginPartialRespec(character, origin)
    local characterGuid=Guid(character)
    local existing=pendingRespec[characterGuid]
    if existing and existing.historicalCommitAttempted and not existing.snapshot
        and not existing.level then
        -- A server-rejected Selective Respec leaves the original character
        -- untouched. BG3 can launch respec again WITHOUT RespecCompleted,
        -- so the old pending state survives; blindly deduplicating here
        -- causes the native screen to open with only the HUD and no menu.
        -- Rebuild summaries from the live actor on the next StartRespec.
        RespecStartLog("BEGIN_RETRY_AFTER_REJECT actor="..characterGuid
            .." origin="..tostring(origin))
        pendingRespec[characterGuid]=nil
        existing=nil
    end
    if existing then
        RespecStartLog("BEGIN_DEDUP actor="..characterGuid
            .." origin="..tostring(origin).." ready="..tostring(existing.summaries~=nil))
        return
    end
    local entity=Ext.Entity.Get(characterGuid)
    if not entity then
        RespecStartLog("BEGIN_MISSING_ENTITY actor="..tostring(characterGuid)
            .." origin="..tostring(origin))
        return
    end
    local level=math.max(1,math.min(40,tonumber(entity.EocLevel and entity.EocLevel.Level) or 1))
    local state={level=nil,charLevel=level,snapshot=nil,summaries=nil}
    pendingRespec[characterGuid]=state
    local presentOK,presentation=pcall(NativePresentationCapture,entity)
    if presentOK then state.nativePresentation=presentation end
    RespecStartLog("NATIVE_L1_PRESENTATION_CAPTURE actor="..characterGuid
        .." health="..tostring(presentation and presentation.Health and presentation.Health.MaxHp)
        .." hotbar="..tostring(presentation and presentation.HotbarEntries or 0))
    if presentation and presentation.Hotbars then
        RespecStartLog("NATIVE_L1_HOTBAR_CAPTURE_SHAPE actor="..characterGuid
            .." "..NativePresentationBarShape(presentation.Hotbars))
    end
    RespecStartLog("BEGIN actor="..characterGuid.." origin="..tostring(origin)
        .." level="..tostring(level).." levelHistory="..tostring(entity.CCLevelUp~=nil))

    local ok,err=pcall(function()
        local levelSummaries={}
        local levelUps=entity.CCLevelUp and entity.CCLevelUp.LevelUps
        local levelChoices={}
        for cutoff=1,level do
            local worked,summary=pcall(BuildLevelSummary,entity,levelUps,cutoff)
            if worked and summary and summary.LevelChoices then
                levelSummaries[cutoff]=summary
            else
                RespecStartLog("LEVEL_SUMMARY_ERROR actor="..characterGuid
                    .." at="..tostring(cutoff).." reason="..tostring(summary))
                levelSummaries[cutoff]=UnavailableLevelSummary(cutoff,summary)
            end
            levelChoices[cutoff]=levelSummaries[cutoff].LevelChoices
        end
        -- Make the respec choice available BEFORE writing diagnostics; those
        -- operations can be expensive for multiclass spellcasters.
        state.summaries=levelSummaries
        local available,observed=0,0
        for _,summary in ipairs(levelSummaries) do
            local c=summary.LevelChoices or {}
            if c.HistoryAvailable then available=available+1 end
            if #(c.ObservedSpells or {})>0 then observed=observed+1 end
        end
        RespecStartLog("HISTORY_COVERAGE actor="..characterGuid
            .." CCLevelUp="..tostring(entity.CCLevelUp~=nil)
            .." recorded="..available.."/"..level
            .." observedSpellLevels="..observed)
        RespecStartLog("SUMMARY_READY actor="..characterGuid.." levels="..tostring(level))
        Ext.Timer.WaitFor(1500,function()
            if pendingRespec[characterGuid]==state then
                SendPendingPopup(characterGuid,state,origin)
            end
        end)
        -- Keep large caster component serialization out of the respec-start
        -- callback; show the chooser before diagnostics work is performed.
        Ext.Timer.WaitFor(2500,function()
        if pendingRespec[characterGuid]~=state then return end
        local diagnosticsOK, diagnosticsError=pcall(function()
            -- Never access entity/levelUps references captured from the
            -- respec-start frame after a 2.5s timer. BG3 expires their C++
            -- proxies; reacquire them on the current tick.
            local live=Ext.Entity.Get(characterGuid)
            if not live then error("Character unavailable for delayed diagnostics") end
            local liveLevelUps=live.CCLevelUp and live.CCLevelUp.LevelUps
            SaveLevelViewerDiagnostics(characterGuid,levelChoices)
            local coverage=HistoricalCoverage(live,liveLevelUps,level)
            local okCoverage,coverageJson=pcall(Ext.Json.Stringify,coverage,
                {Beautify=true,StringifyInternalTypes=false})
            if okCoverage and coverageJson then
                pcall(Ext.IO.SaveFile,"HomeBrew/Diagnostics/HB_CasterHistory_Diagnostics.json",coverageJson)
            end
            local levels={}
            for n,choice in ipairs(levelChoices) do
                local items={}
                for _,c in ipairs(choice.OtherChoices or {}) do
                    items[#items+1]={Kind=c.Kind,From=c.From,List=c.List,
                        Source=c.Source,EntryIndex=c.EntryIndex,SlotIndex=c.SlotIndex,
                        CandidateCount=#(c.Options or {}),Editable=c.Editable}
                end
                levels[#levels+1]={Level=n,Choices=items}
            end
            Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_HistoricalChoices_Diagnostics.json",
                Ext.Json.Stringify({Version=1,CharacterGuid=characterGuid,Levels=levels},
                    {Beautify=true,StringifyInternalTypes=false}))
            SaveExtraResourceProbe(live,characterGuid,liveLevelUps,level)
            local groups={}
            for n=1,level do
                local choices={}
                for _,selection in ipairs(liveLevelUps and liveLevelUps[n] and liveLevelUps[n].Upgrades
                    and liveLevelUps[n].Upgrades.Passives or {}) do
                    local selector=tostring(selection.SelectorId or "")
                    if not EDITOR_PROTECTED_SELECTORS[selector] then
                        local guid=tostring(selection.PassiveList or "")
                        local list=ResolvePassiveList(guid)
                        local valid=list~=nil
                        local selected={}
                        for _,id in ipairs(selection.Passives or {}) do
                            id=tostring(id)
                            selected[#selected+1]=id
                            if not (list and list.Set[id]) then valid=false end
                        end
                        choices[#choices+1]={SelectorId=selector,PassiveList=guid,
                            Selected=selected,CandidateCount=list and #list.Ids or 0,
                            Resolution=editorPassiveListResolution[guid],
                            Editable=valid and #selected>0 and not (selection.ReplacePassives
                                and #selection.ReplacePassives>0) or false}
                    end
                end
                if #choices>0 then groups[#groups+1]={Level=n,Groups=choices} end
            end
            Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_PassiveEditor_Diagnostics.json",Ext.Json.Stringify({
                Version=1,CharacterLevel=level,Groups=groups},
                {Beautify=true,StringifyInternalTypes=false}))
            -- Generate feat ownership evidence WITHOUT pressing native Confirm.
            -- This diagnostic is wholly optional and cannot authorize respec.
            -- We refresh the character reference here; never retain a C++
            -- proxy across Ext.Timer.WaitFor callbacks.
            local featLevels=0
            for n=1,level do
                if liveLevelUps and liveLevelUps[n] and IsValidGuid(liveLevelUps[n].Feat) then
                    featLevels=featLevels+1
                end
            end
            if SaveLevelOneAndSpellProvenance or (featLevels>0 and SaveHistoricalFeatSecondaryAudit) then
                local got,originalPreview=pcall(PartialRespecSnapshot.InspectCharacter,live)
                if got and type(originalPreview)=="table" then
                    if featLevels>0 and SaveHistoricalFeatSecondaryAudit then
                        SaveHistoricalFeatSecondaryAudit(characterGuid,originalPreview,level)
                        RespecStartLog("FEAT_SECONDARY_PREVIEW_CAPTURE actor="..characterGuid
                            .." levels="..tostring(featLevels).." mode=read_only")
                    end
                    if SaveLevelOneAndSpellProvenance then
                        SaveLevelOneAndSpellProvenance(characterGuid,originalPreview,level)
                    end
                else
                    RespecStartLog("HISTORICAL_PREVIEW_UNAVAILABLE actor="..characterGuid
                        .." reason="..tostring(originalPreview))
                end
            end
        end)
        if not diagnosticsOK then RespecStartLog("DIAGNOSTICS_ERROR actor="..characterGuid
            .." error="..tostring(diagnosticsError)) end
        end)
    end)
    if not ok then
        RespecStartLog("BEGIN_FATAL actor="..characterGuid.." reason="..tostring(err))
        -- The choice dialog is preferable to silent full respec, but not if
        -- we cannot prove the level history. All edit categories fail closed.
        local fallback={}
        for n=1,level do fallback[n]=UnavailableLevelSummary(n,err) end
        state.summaries=fallback
        Ext.Timer.WaitFor(1500,function()
            if pendingRespec[characterGuid]==state then
                SendPendingPopup(characterGuid,state,"fallback:"..tostring(origin))
            end
        end)
    end
end

-- Only use server-owned active respec records, never a user-supplied target.
-- This recovery path is for spells/multiclass UI sequences where the usual
-- Osiris start notification may not fire or its initial message may be lost.
local function OwnedRespecActor(actor,expectedUser)
    local assigned=tonumber(Osi.GetReservedUserID(actor)) or 0
    -- A nonzero reserved user is authoritative. Do not override an
    -- explicit ownership mismatch with possibly stale PartyView data.
    if assigned~=0 then return assigned==expectedUser end
    -- Companions can belong to a player's PartyView even when the Osiris
    -- reserved-user lookup reports zero. Only accept an explicit ownership
    -- match, never the generic host-character fallback.
    local worked,parties=pcall(Ext.Entity.GetAllEntitiesWithComponent,"PartyView")
    if not worked or not parties then return false end
    for _,party in pairs(parties) do
        for _,view in pairs((party.PartyView and party.PartyView.Views) or {}) do
            if tonumber(view.UserID)==expectedUser then
                for _,character in pairs(view.Characters or {}) do
                    if character.Uuid and Guid(character.Uuid.EntityUuid)==actor then return true end
                end
            end
        end
    end
    return false
end

local function ResolveActiveOwnedRespec(peer)
    local expectedUser=PeerToReservedUserID(peer)
    local resolved=nil
    for _,componentName in ipairs({"CCRespec","CCFullRespec"}) do
        local success,roots=pcall(Ext.Entity.GetAllEntitiesWithComponent,componentName)
        if success and roots then
            for _,root in ipairs(roots) do
                local readOK,link=pcall(function()
                    return root:GetComponent(componentName)
                end)
                if readOK and link and link.Character and link.Respec then
                    local actor=Guid(link.Character)
                    local okDef,definition=pcall(Ext.Entity.Get,link.Respec)
                    if not okDef or not definition then
                        okDef,definition=pcall(Ext.Entity.Get,tostring(link.Respec))
                    end
                    if okDef and definition and OwnedRespecActor(actor,expectedUser) then
                        if resolved and resolved~=actor then
                            return nil,"ambiguous active respec records"
                        end
                        resolved=actor
                    end
                end
            end
        end
    end
    return resolved,resolved and nil or "no owned active respec record"
end

local function SafeRespecStart(character,origin)
    if not PartialRespecEnabled then return end
    local ok,err=pcall(BeginPartialRespec,character,origin)
    if not ok then RespecStartLog("EVENT_EXCEPTION source="..tostring(origin)
        .." actor="..tostring(Guid(character)).." reason="..tostring(err)) end
end

Ext.Osiris.RegisterListener("PROC_FlagReactionAfterDialog",3,"before",function(character,flag)
    if PartialRespecEnabled and Guid(flag)==RESPEC_START_FLAG then
        SafeRespecStart(character,"dialog_flag")
    end
end)
Ext.Osiris.RegisterListener("PROC_LaunchRespec",2,"before",function(character)
    SafeRespecStart(character,"PROC_LaunchRespec")
end)
Ext.Osiris.RegisterListener("StartRespec",1,"after",function(character)
    SafeRespecStart(character,"StartRespec")
end)

---@param entity EntityHandle
local function DestroyExistingProgressions(entity,preserveLevelOne)
    local container = entity.ProgressionContainer
    if not container or not container.Progressions then return 0 end
    local count = 0
    for level, bucket in ipairs(container.Progressions) do
        if not (preserveLevelOne and level==1) then
        for _, progressionHandle in ipairs(bucket) do
            if progressionHandle and progressionHandle:IsAlive() then
                Ext.Entity.Destroy(progressionHandle)
                count = count + 1
            end
        end
        end -- protected engine-owned level-one entries
    end
    return count
end

--- Replay core logic: destroys old progressions, restores snapshot 1..targetLevel, recalculates classes/EocLevel, notifies client.
---@param entity EntityHandle
---@param snapshot table
---@param targetLevel integer
---@param characterGuid string
local WriteHistoricalEditResult

-- Diagnostic only: the game's native Confirm RPC accepting a rebuild is not
-- evidence that all restored progression components survived a later Tick.
-- Observe the result after replication without touching the live build.
local function AuditLevelRespecReplay(characterGuid, snapshot, targetLevel)
    local ok,err=pcall(function()
        local live=Ext.Entity.Get(characterGuid)
        if not live then error("Character entity unavailable after replay") end
        local actualLevel=tonumber(live.EocLevel and live.EocLevel.Level)
        -- The class level SUM alone cannot detect replacing three Ranger
        -- levels with three Fighter levels. Compare the original saved class
        -- composition with what actually exists after replay; treat missing
        -- native data as 'unobservable', not a false mismatch.
        local function ReadClassComposition(rows)
            if rows==nil then return nil,nil end
            local keys,total,found={},0,0
            for _,class in pairs(rows) do
                if not class then return nil,nil end
                local id=tostring(class.ClassUUID or "")
                local amount=tonumber(class.Level)
                if id=="" or not amount or amount<0 then return nil,nil end
                local subclass=tostring(class.SubClassUUID or "")
                if subclass=="00000000-0000-0000-0000-000000000000" then subclass="" end
                local present=keys[id]
                -- A duplicate class record with conflicting subclasses must
                -- not appear to match simply because its levels add up.
                if present and present.SubClassUUID~=subclass then return nil,nil end
                keys[id]=present or {ClassUUID=id,Level=0,SubClassUUID=subclass}
                keys[id].Level=keys[id].Level+amount
                total=total+amount
                found=found+1
            end
            if found==0 then return nil,nil end
            local list={}
            for _,record in pairs(keys) do
                list[#list+1]=record
            end
            table.sort(list,function(a,b) return a.ClassUUID<b.ClassUUID end)
            return list,total
        end
        local classRows,actualClassLevel=ReadClassComposition(
            live.Classes and live.Classes.Classes)
        local expectedClasses=snapshot.components and snapshot.components.classes
        local expectedClassRows,expectedClassLevel=ReadClassComposition(
            expectedClasses and expectedClasses.Classes)
        local compositionMatches=nil
        if expectedClassRows and classRows then
            compositionMatches=#expectedClassRows==#classRows
            if compositionMatches then
                for n=1,#expectedClassRows do
                    local want,got=expectedClassRows[n],classRows[n]
                    if want.ClassUUID~=got.ClassUUID or want.Level~=got.Level
                        or want.SubClassUUID~=got.SubClassUUID then
                        compositionMatches=false;break
                    end
                end
            end
        end
        local bucketRows={}
        local targetBuckets=snapshot.progressions and snapshot.progressions.buckets or {}
        local actualBuckets=live.ProgressionContainer and live.ProgressionContainer.Progressions
        for level=1,targetLevel do
            local expected=targetBuckets[level]
            local observed=actualBuckets and actualBuckets[level]
            bucketRows[#bucketRows+1]={Level=level,
                ExpectedEntries=type(expected)=="table" and #expected or nil,
                ObservedEntries=observed and #observed or nil,
                -- Ordinary respec preserves vanilla level-one ownership.
                -- A validated level-one choice edit explicitly replays the
                -- complete original level-one progression bucket instead.
                RestoreOwner=level==1 and (snapshot.hbLevelOneSurgical==true
                    and "HBVanillaSurgicalChoice" or "VanillaLevelOne") or "HBHistoricalReplay",
                -- Missing native data may only mean it wasn't observable
                -- on this tick, not that it was actually lost.
                Observable=observed~=nil}
        end
        -- Feat choices can disappear even when class levels and progression
        -- entity counts look correct. Compare recorded feat IDs without
        -- mutating the live CCLevelUp component or inferring feat ownership.
        local expectedHistory=snapshot.components and snapshot.components.ccLevelUp
            and snapshot.components.ccLevelUp.LevelUps
        local observedHistory=live.CCLevelUp and live.CCLevelUp.LevelUps
        local featRows,featHistoryMatches={},true
        local featHistoryObservable=expectedHistory~=nil and observedHistory~=nil
        local function FeatId(row)
            local id=row and tostring(row.Feat or "") or ""
            if id=="" or id=="00000000-0000-0000-0000-000000000000" then
                return nil
            end
            return id
        end
        for level=1,targetLevel do
            local expectedRow=expectedHistory and expectedHistory[level]
            local liveRow=observedHistory and observedHistory[level]
            if not expectedRow or not liveRow then
                featHistoryObservable=false
            else
                local expectedFeat,observedFeat=FeatId(expectedRow),FeatId(liveRow)
                if expectedFeat or observedFeat then
                    local same=expectedFeat==observedFeat
                    featRows[#featRows+1]={Level=level,ExpectedFeat=expectedFeat,
                        ObservedFeat=observedFeat,Matches=same}
                    if not same then featHistoryMatches=false end
                end
            end
        end
        if not featHistoryObservable then featHistoryMatches=nil end
        -- Read-only level-one fidelity and exact historical spell history.
        -- We do not infer acquisition from a current spellbook or grant.
        -- Comparing the recorded source rows avoids a misleading "success"
        -- when a replay preserves spellbook entries but loses CCLevelUp history.
        local function Comparable(value)
            if type(value)~="table" then return tostring(value) end
            local keys={}
            for key in pairs(value) do keys[#keys+1]=key end
            table.sort(keys,function(a,b)
                if type(a)==type(b) then return a<b end
                return type(a)<type(b)
            end)
            local result={}
            for _,key in ipairs(keys) do
                result[#result+1]=tostring(key).."="..Comparable(value[key])
            end
            return "{"..table.concat(result,"|").."}"
        end
        local function LevelOneFingerprint(row)
            if not row then return nil end
            local upgrades=row.Upgrades or {}
            return Comparable({Class=row.Class,SubClass=row.SubClass,
                Abilities=row.Abilities or {},
                AbilityBonuses=upgrades.AbilityBonuses or {},
                Passives=upgrades.Passives or {},
                Skills=upgrades.Skills or {},
                SkillExpertise=upgrades.SkillExpertise or {},
                Spells=row.Spells or {},UpgradeSpells=upgrades.Spells or {}})
        end
        -- Ext.Types.Serialize copies C++ LevelUps proxies into stable, plain
        -- tables; tostring(proxy) would otherwise compare pointer addresses
        -- instead of historical selections.
        local serializedLiveHistory=nil
        local serializedOK,serializedCC=pcall(Ext.Types.Serialize,live.CCLevelUp)
        if serializedOK and type(serializedCC)=="table" then
            serializedLiveHistory=serializedCC.LevelUps
        end
        local initialExpected=LevelOneFingerprint(expectedHistory and expectedHistory[1])
        local initialObserved=LevelOneFingerprint(serializedLiveHistory and serializedLiveHistory[1])
        local initialMatches=(initialExpected and initialObserved)
            and initialExpected==initialObserved or nil
        if initialExpected and initialObserved and initialExpected~=initialObserved then
            initialMatches=false
        end
        local spellHistoryRows={}
        local spellHistoryMatches=true
        local spellHistoryObservable=(expectedHistory~=nil and serializedLiveHistory~=nil)
        for level=1,targetLevel do
            local expectedRow=expectedHistory and expectedHistory[level]
            local liveRow=serializedLiveHistory and serializedLiveHistory[level]
            if not expectedRow or not liveRow then
                spellHistoryObservable=false
            else
                local function ChoiceRows(row)
                    return {Spells=row.Spells or {},
                        UpgradeSpells=row.Upgrades and row.Upgrades.Spells or {}}
                end
                local originalRows=ChoiceRows(expectedRow)
                local restoredRows=ChoiceRows(liveRow)
                if #originalRows.Spells>0 or #originalRows.UpgradeSpells>0
                    or #restoredRows.Spells>0 or #restoredRows.UpgradeSpells>0 then
                    local equal=Comparable(originalRows)==Comparable(restoredRows)
                    spellHistoryRows[#spellHistoryRows+1]={Level=level,
                        ExpectedRows=#originalRows.Spells+#originalRows.UpgradeSpells,
                        ObservedRows=#restoredRows.Spells+#restoredRows.UpgradeSpells,
                        Matches=equal}
                    if not equal then spellHistoryMatches=false end
                end
            end
        end
        if not spellHistoryObservable then spellHistoryMatches=nil end
        local levelMatches=actualLevel==targetLevel
        local classMatches=actualClassLevel==targetLevel
        local document={Version=4,CharacterGuid=characterGuid,
            ExpectedLevel=targetLevel,ObservedLevel=actualLevel,
            OriginalLevelOneObservable=(initialExpected~=nil and initialObserved~=nil),
            OriginalLevelOneMatches=initialMatches,
            HistoricalSpellHistoryObservable=spellHistoryObservable,
            HistoricalSpellHistoryMatches=spellHistoryMatches,
            HistoricalSpellRows=spellHistoryRows,
            ExpectedClassLevelSum=expectedClassLevel,
            ObservedClassLevelSum=actualClassLevel,
            LevelMatches=levelMatches,ClassLevelsMatch=classMatches,
            ClassCompositionObservable=compositionMatches~=nil,
            ClassCompositionMatches=compositionMatches,
            ExpectedClassRows=expectedClassRows,
            ClassRows=classRows,ProgressionBuckets=bucketRows,
            FeatHistoryObservable=featHistoryObservable,
            FeatHistoryMatches=featHistoryMatches,FeatRows=featRows,
            Interpretation="Post-replay observation; bucket counts may update asynchronously"}
        local json=Ext.Json.Stringify(document,{Beautify=true,StringifyInternalTypes=false})
        if not json or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_LevelRespec_ReplayAudit.json",json) then
            error("Could not write post-replay diagnostic")
        end
        RespecStartLog("LEVEL_RESPEC_POSTREPLAY actor="..characterGuid
            .." expected="..targetLevel.." observed="..tostring(actualLevel)
            .." classes="..tostring(actualClassLevel)
            .." composition="..tostring(compositionMatches)
            .." feats="..tostring(featHistoryMatches)
            .." levelOne="..tostring(initialMatches)
            .." spellHistory="..tostring(spellHistoryMatches))
        if not levelMatches or not classMatches or compositionMatches==false
            or featHistoryMatches==false or initialMatches==false
            or spellHistoryMatches==false then
            PRWarn(0,"Selective Respec replay mismatch: level=%s classSum=%s expected=%d composition=%s feats=%s",
                tostring(actualLevel),tostring(actualClassLevel),targetLevel,
                tostring(compositionMatches),tostring(featHistoryMatches))
        end
    end)
    if not ok then
        RespecStartLog("LEVEL_RESPEC_POSTREPLAY_AUDIT_ERROR actor="..characterGuid
            .." reason="..tostring(err))
    end
end

-- This is an emergency *best-effort* recovery, not an atomic rollback. BG3's
-- entity destruction/unserialization is engine-owned and cannot be wrapped in
-- a transaction. Never substitute the edited snapshot for the pristine copy.
-- In particular, a partial failed restore may already have created some of
-- the new progressions; remove those before replaying the original snapshot.
local function AttemptOriginalLevelRecovery(characterGuid, original, targetLevel, reason)
    RespecStartLog("LEVEL_RESPEC_RECOVERY_BEGIN actor="..characterGuid
        .." target="..tostring(targetLevel).." reason="..tostring(reason))
    if type(original)~="table" then
        RespecStartLog("LEVEL_RESPEC_RECOVERY_UNAVAILABLE actor="..characterGuid
            .." missing_original_snapshot=true")
        return false
    end
    local resolved,live=pcall(Ext.Entity.Get,characterGuid)
    if not resolved or not live then
        RespecStartLog("LEVEL_RESPEC_RECOVERY_FAILED actor="..characterGuid
            .." reason=character_missing_or_unreadable detail="..tostring(live))
        return false
    end
    local removed,removeResult=pcall(DestroyExistingProgressions,live)
    if not removed then
        RespecStartLog("LEVEL_RESPEC_RECOVERY_FAILED actor="..characterGuid
            .." phase=clear_partial reason="..tostring(removeResult))
        return false
    end
    local restored,restoreResult=pcall(function()
        -- The original snapshot's class and CCLevelUp components are applied
        -- as captured; this recovery must never derive them from edited data.
        local plan=PartialRespecSnapshot.ApplySnapshotToCharacter(live,original,targetLevel)
        if not live.EocLevel then error("EocLevel component unavailable") end
        live.EocLevel.Level=targetLevel
        live:Replicate("EocLevel")
        return plan
    end)
    if not restored then
        RespecStartLog("LEVEL_RESPEC_RECOVERY_FAILED actor="..characterGuid
            .." phase=restore_original reason="..tostring(restoreResult))
        return false
    end
    RespecStartLog("LEVEL_RESPEC_RECOVERY_ATTEMPTED actor="..characterGuid
        .." restoredEntries="..tostring(restoreResult and restoreResult.newEntries)
        .." note=engine_state_must_be_verified_in_game")
    Ext.Timer.WaitFor(500,function()
        AuditLevelRespecReplay(characterGuid,original,targetLevel)
    end)
    return true
end

-- The recovery attempt can be successful according to Lua while the engine
-- still needs to replicate its components. Always distinguish attempted from
-- guaranteed, and retain the disk backup for manual recovery.
local levelReplayRecoveryPending={}
local function QueueLevelReplayRecovery(characterGuid,original,targetLevel,reason,backupPath)
    if levelReplayRecoveryPending[characterGuid] then return end
    levelReplayRecoveryPending[characterGuid]=true
    RespecStartLog("LEVEL_RESPEC_RECOVERY_QUEUED actor="..characterGuid
        .." backup="..tostring(backupPath).." reason="..tostring(reason))
    Ext.OnNextTick(function()
        local safe,result=pcall(AttemptOriginalLevelRecovery,
            characterGuid,original,targetLevel,reason)
        levelReplayRecoveryPending[characterGuid]=nil
        local attempted=safe and result==true
        RespecStartLog("LEVEL_RESPEC_RECOVERY_RESULT actor="..characterGuid
            .." attempted="..tostring(attempted)
            .." backup="..tostring(backupPath)
            .." error="..tostring(not safe and result or ""))
        PartialRespecChannel:SendToClient({ExperimentalError=attempted and
            "Selective Respec replay failed. Restoration of the unmodified build was attempted; verify in game and reload a good save if anything is missing."
            or "Selective Respec replay and recovery failed. Reload a known-good save. See HB_RespecStart_Diagnostics.txt."},
            RespecViewerUser(characterGuid))
    end)
end

local function ApplyReplay(entity, snapshot, targetLevel, characterGuid, experimentalEdits, silentCompletion, originalSnapshot, backupPath)
    -- This diagnostic dump is supplementary: the ORIGINAL snapshot has
    -- already been saved to a verified pre-confirm backup file. A failed
    -- supplementary dump should not make every Confirm fail on platforms
    -- where the PartialRespec subdirectory is unavailable.
    local dumpOK,dumpErr=PartialRespecSnapshot.SaveRecoveryDump(entity, characterGuid, targetLevel, snapshot)
    if silentCompletion and not dumpOK then
        RespecStartLog("LEVEL_RESPEC_RECOVERY_DUMP_FAILED actor="..characterGuid
            .." reason="..tostring(dumpErr).." backup="..tostring(backupPath))
    end
    if silentCompletion and (type(originalSnapshot)~="table" or not backupPath) then
        RespecStartLog("LEVEL_RESPEC_REQUIRED_BACKUP_MISSING actor="..characterGuid
            .." phase=before_destruction")
        -- No progressions have been destroyed yet. A recovery attempt here
        -- would itself delete healthy state (and may lack the very original
        -- snapshot it needs). Refuse replay and report the issue instead.
        PartialRespecChannel:SendToClient({ExperimentalError=
            "Selective Respec cannot continue without its original backup. Reload a known-good save; no custom replay was attempted."},
            RespecViewerUser(characterGuid))
        return
    end

    local surgical= snapshot.hbLevelOneSurgical==true
    if surgical then
        local ok,plan,why=pcall(PartialRespecSnapshot.ValidateLevelOneSurgery,
            entity,originalSnapshot,snapshot)
        if not ok or not plan then
            RespecStartLog("LEVEL_ONE_SURGERY_PREFLIGHT_REJECT actor="..characterGuid
                .." reason="..tostring(why or plan))
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Level-one replay refused before deleting progressions: "
                ..tostring(why or plan)..". Reload your known-good save."},
                RespecViewerUser(characterGuid))
            return
        end
        -- Fail closed for non-passive experiments until we can verify the
        -- corresponding live skill/spellbook effects, not only progression
        -- serialization. The first post-settle pilot is one passive swap.
        for _,item in ipairs(plan) do
            if item.Kind~="passives" then
                RespecStartLog("LEVEL_ONE_SURGERY_UNVERIFIED_EFFECT_KIND actor="
                    ..characterGuid.." kind="..tostring(item.Kind))
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Level-one skills and spells still require live-effect restoration. "
                    .."For this experimental build, test a Maneuver/passive change alone."},
                    RespecViewerUser(characterGuid))
                return
            end
        end
        RespecStartLog("LEVEL_ONE_SURGERY_PREFLIGHT_OK actor="..characterGuid
            .." changes="..#plan)
        -- Do not mutate BG3's first-level entities before replay. Restoring
        -- CCLevelUp/SpellBook through Unserialize causes BG3 to regenerate or
        -- overwrite their grants. The old early-write path passed an immediate
        -- audit but was replaced by the original PushingAttack on the next tick.
        -- The validated changes are applied only after component replay settles.
        end
    local destroyed,oldCount=pcall(DestroyExistingProgressions,entity,surgical)
    if not destroyed then
        RespecStartLog("RESPEC_REPLAY_DESTROY_FAILED actor="..characterGuid
            .." reason="..tostring(oldCount))
        PRWarn(0,"Replay removal failed for %s: %s",characterGuid,tostring(oldCount))
        if silentCompletion then
            -- Destruction may have succeeded for some entries before throwing.
            -- Use a later tick to avoid mutating the same engine collection
            -- while its prior destruction traversal is unwinding.
            QueueLevelReplayRecovery(characterGuid,originalSnapshot,targetLevel,
                "progression removal exception",backupPath)
        end
        return
    end
    PRPrint(1, "Destroyed %d old progression entities", oldCount)

    Ext.OnNextTick(function()
        -- The engine can reject a component during C++ Unserialize even if
        -- all captured tables pass schema preflight. Record the exact runtime
        -- error rather than losing it in an unhandled next-tick callback.
        local worked,replayError=pcall(function()
        local plan = PartialRespecSnapshot.ApplySnapshotToCharacter(entity, snapshot, targetLevel)

        if surgical then
            RespecStartLog("LEVEL_ONE_SURGERY_WAIT_NATIVE_SETTLE actor="..characterGuid)
            -- Actual in-game evidence: 700ms and 2900ms post-replay both
            -- showed the ORIGINAL first-level choice grants, not our earlier
            -- mutation. Freshly resolve all four owners only after native
            -- component restoration has stabilized; never copy C++ handles
            -- between ticks and never manufacture progression entities.
            Ext.Timer.WaitFor(1000,function()
                local accepted,changed=pcall(PartialRespecSnapshot.ApplyLevelOneSurgery,
                    characterGuid,originalSnapshot,snapshot)
                if not accepted then
                    RespecStartLog("LEVEL_ONE_SURGERY_SETTLED_REFUSED actor="..characterGuid
                        .." reason="..tostring(changed))
                    -- The update did not succeed. Restore original CCLevelUp
                    -- history so it cannot claim edits that were not granted.
                    pcall(PartialRespecSnapshot.RestoreLevelOneHistory,
                        characterGuid,originalSnapshot)
                    PartialRespecChannel:SendToClient({ExperimentalError=
                        "Level-one changes were not applied; the original choices were restored. Reload a known-good save. "
                        ..tostring(changed)},RespecViewerUser(characterGuid))
                    return
                end
                local effectsOk,effectsWhy=pcall(PartialRespecSnapshot.ApplyLevelOnePassiveEffects,
                    characterGuid,originalSnapshot,snapshot)
                if not effectsOk then
                    RespecStartLog("LEVEL_ONE_SURGERY_PASSIVE_EFFECT_REJECT actor="..characterGuid
                        .." reason="..tostring(effectsWhy))
                    pcall(PartialRespecSnapshot.RestoreLevelOneChoices,
                        characterGuid,originalSnapshot,snapshot)
                    pcall(PartialRespecSnapshot.RestoreLevelOneHistory,
                        characterGuid,originalSnapshot)
                    PartialRespecChannel:SendToClient({ExperimentalError=
                        "Level-one passive activation failed. The original choice records were restored; reload a known-good save. "
                        ..tostring(effectsWhy)},RespecViewerUser(characterGuid))
                    return
                end
                -- Source-verified pilot for progression-owned Maneuver spells.
                -- It is entirely separate from ordinary passive replay and
                -- does nothing for any other passive change.
                local spellOK,spellCount,spellWhy=pcall(
                    PartialRespecSnapshot.TryRemoveLevelOneProgressionSpellGrants,
                    characterGuid,originalSnapshot,snapshot)
                RespecStartLog("LEVEL_ONE_PROGRESSION_SPELL_REMOVAL actor="..characterGuid
                    .." call="..tostring(spellOK)
                    .." attempted="..tostring(spellCount)
                    .." result="..tostring(spellWhy))
                RespecStartLog("LEVEL_ONE_SURGERY_SETTLED_APPLIED actor="..characterGuid
                    .." components="..tostring(changed)
                    .." passiveEffects="..tostring(effectsWhy))
                local function VerifySettled(final)
                    local checked,okay,choiceReason=pcall(PartialRespecSnapshot.AuditLevelOneSurgery,
                        characterGuid,originalSnapshot,snapshot)
                    local passiveCall,passiveOkay,passiveReason=pcall(
                        PartialRespecSnapshot.AuditLevelOnePassiveEffects,
                        characterGuid,originalSnapshot,snapshot)
                    if checked and okay and passiveCall and passiveOkay then
                        RespecStartLog("LEVEL_ONE_SURGERY_POSTAUDIT_OK actor="..characterGuid
                            .." final="..tostring(final).." effects=verified")
                        return
                    end
                    -- pcall yields (callSucceeded, auditSucceeded, diagnostic).
                    -- The old code discarded the third value and logged only
                    -- 'passive=false', hiding the actual failure.
                    local failedChoice=checked and tostring(choiceReason or okay)
                        or tostring(okay)
                    local failedPassive=passiveCall and tostring(passiveReason or passiveOkay)
                        or tostring(passiveOkay)
                    RespecStartLog("LEVEL_ONE_SURGERY_POSTAUDIT_MISMATCH actor="..characterGuid
                        .." final="..tostring(final)
                        .." choice="..failedChoice.." passive="..failedPassive)
                    pcall(HB_SaveLevelOnePassiveSources,
                        characterGuid,final and "post_audit_final" or "post_audit_first")
                    if not final then
                        -- Verified live result: a repeated Osiris RemovePassive
                        -- returned PushingAttack=1,Rally=1 before and after.
                        -- Do not blindly retry an ineffective mutation.
                        RespecStartLog("LEVEL_ONE_SURGERY_PASSIVE_RETRY_SKIPPED actor="
                            ..characterGuid.." reason=original_progression_grant_persists")
                        Ext.Timer.WaitFor(2200,function() VerifySettled(true) end)
                    else
                        PartialRespecChannel:SendToClient({ExperimentalError=
                            "Level-one effects did not remain verified after replay: "
                            ..failedPassive..". Reload your known-good save."},
                            RespecViewerUser(characterGuid))
                    end
                end
                Ext.Timer.WaitFor(350,function() VerifySettled(false) end)
            end)
        end
        PRPrint(0, "Replay applied: buckets=%d entries=%d",
            plan.newBuckets, plan.newEntries)

        -- Delevel character
        local cc = entity.CCLevelUp
        if cc and cc.LevelUps and #cc.LevelUps > targetLevel then
            for i = #cc.LevelUps, targetLevel + 1, -1 do
                cc.LevelUps[i] = nil
            end
            entity:Replicate("CCLevelUp")
            PRPrint(1, "CCLevelUp truncated to %d", targetLevel)
        end

        -- Replay classes/subclasses
        local classLevels = {}
        if cc and cc.LevelUps then
            for i = 1, targetLevel do
                local lvlUp = cc.LevelUps[i]
                if lvlUp and lvlUp.Class and lvlUp.Class ~= "00000000-0000-0000-0000-000000000000" then
                    local guid = tostring(lvlUp.Class)
                    if not classLevels[guid] then
                        classLevels[guid] = { Level = 0, SubClass = "00000000-0000-0000-0000-000000000000" }
                    end
                    classLevels[guid].Level = classLevels[guid].Level + 1
                    if lvlUp.SubClass and lvlUp.SubClass ~= "00000000-0000-0000-0000-000000000000" then
                        classLevels[guid].SubClass = tostring(lvlUp.SubClass)
                    end
                end
            end
        end

        local newClasses = {}
        for guid, info in pairs(classLevels) do
            newClasses[#newClasses + 1] = {
                ClassUUID = guid,
                Level = info.Level,
                SubClassUUID = info.SubClass,
            }
        end
        entity.Classes.Classes = newClasses
        entity:Replicate("Classes")
        PRPrint(1, "Classes recalculated: %d entries summing to %d", #newClasses, targetLevel)

        local toastSummary = BuildLevelSummary(entity, cc and cc.LevelUps, targetLevel)

        entity.EocLevel.Level = targetLevel
        entity:Replicate("EocLevel")
        PRPrint(1, "EocLevel set to %d", targetLevel)

        if experimentalEdits and #experimentalEdits > 0 then
            Ext.Timer.WaitFor(2000, function()
                WriteHistoricalEditResult(characterGuid, experimentalEdits)
            end)
        end

        if silentCompletion then
            Ext.Timer.WaitFor(500,function()
                AuditLevelRespecReplay(characterGuid,snapshot,targetLevel)
            end)
        end
        if not silentCompletion then Ext.Timer.WaitFor(TOAST_DELAY_MS, function()
            PartialRespecChannel:SendToClient({
                Toast = true,
                ToastLevelCount = targetLevel,
                ToastClasses = toastSummary.Classes,
            }, RespecViewerUser(characterGuid))
        end) end
        end)
        if not worked then
            RespecStartLog("RESPEC_REPLAY_RUNTIME_ERROR actor="..characterGuid
                .." target="..tostring(targetLevel).." reason="..tostring(replayError))
            PRWarn(0,"Replay failed during restoration for %s: %s",
                characterGuid,tostring(replayError))
            if silentCompletion then
                -- Wait for a fresh Tick and entity lookup rather than trying
                -- a second Unserialize in the same failed native callback.
                QueueLevelReplayRecovery(characterGuid,originalSnapshot,targetLevel,
                    "patched progression replay exception",backupPath)
            end
        end
    end)
end

local ValidateLevelRespecReplayCoverage
-- This path intentionally DOES NOT call ApplyReplay: that legacy path
-- restores old first-level SpellBook/CCLevelUp wholesale and can delete
-- native level-one progression entities on its recovery branch.
local function FinishNativeFirstLevelRestore(actor,state)
    local target=state.charLevel
    -- Wait out vanilla's deferred SpellBook normalization BEFORE the sole
    -- historical component replay. Previously a first replay at 650 ms was
    -- followed by vanilla dropping 11 class spells at the 950 ms audit,
    -- requiring a second full spellbook write that coincided with the
    -- hotbar regression. Retain strict audit/fail-closed recovery if the
    -- later single pass is not sufficient. Do not edit any hotbar slots.
    RespecStartLog("NATIVE_L1_LATE_REPLAY_SCHEDULED actor="..actor.." delay=1800")
    Ext.Timer.WaitFor(1800,function()
        local success,why=pcall(function()
            local live=Ext.Entity.Get(actor)
            if not live then error("Native level-one actor unavailable") end
            local fresh=PartialRespecSnapshot.InspectCharacter(live)
            -- Native Confirm has already committed level one. A genuinely
            -- different original class OR subclass is the player's intentional
            -- Full Respec, not a failed historical replay. Leave the new
            -- native level-one class, progression and spell choices untouched.
            -- Do not swallow missing-history or other restoration errors.
            local same,foundationReason=HB_NativeFirstLevelRestore.CheckFirstClass(
                state.snapshot,fresh)
            if not same and type(foundationReason)=="string"
                and (foundationReason:find("Starting class differs",1,true)==1
                    or foundationReason:find("Starting subclass differs",1,true)==1) then
                RespecStartLog("NATIVE_L1_INTENTIONAL_FULL_RESPEC actor="..actor
                    .." savedLevel="..tostring(target)
                    .." reason="..foundationReason
                    .." backup="..tostring(state.backupPath))
                return -- no historic replay and NO failure toast
            end
            local merged,reason,spellCount=HB_NativeFirstLevelRestore.Prepare(
                state.snapshot,fresh,target,state.originalSnapshot,
                state.nativeSpellSwap,state.nativeSpellDeferredEdits)
            if not merged then error(reason) end
            local complete,coverage=ValidateLevelRespecReplayCoverage(merged,target)
            if not complete then error(coverage) end
            -- Diagnostic-only: prove where the RootOnly engine AddSpell call
            -- registers class-selected spells. Never alter native components.
            -- SourceType/ProgressionSource are recorded to separate preexisting
            -- class selections from new SpellSet/Common Osiris grants.
            local function ProbeNativeSpellSources(ids, stage)
                local success,problem=pcall(function()
                    local native=Ext.Entity.Get(actor)
                    if not native then error("actor unavailable") end
                    local lookup={}
                    for _,id in ipairs(ids or {}) do
                        if type(id)=="string" and id~="" then lookup[id]=true end
                    end
                    local hits={}
                    for proto in pairs(lookup) do hits[proto]={} end
                    local function capture(kind,comp,key)
                        if not comp then return end
                        local good,serialized=pcall(Ext.Types.Serialize,comp)
                        if not good or type(serialized)~="table" then
                            RespecStartLog("NATIVE_L1_OWNER_PROBE_COMPONENT actor="..actor
                                .." phase="..stage.." component="..kind
                                .." error="..tostring(serialized))
                            return
                        end
                        local rows=serialized[key]
                        if type(rows)~="table" then return end
                        for _,row in pairs(rows) do
                            if type(row)=="table" then
                                local id=row.Id or row.SpellId or row
                                if type(id)=="table" then
                                    local name=tostring(id.Prototype or "")
                                    if lookup[name] then
                                        local tag=kind..":"..tostring(id.SourceType or "?")
                                            ..":"..tostring(id.ProgressionSource or "?")
                                            ..":"..tostring(id.Source or "?")
                                        hits[name][#hits[name]+1]=tag
                                    end
                                end
                            end
                        end
                    end
                    capture("SpellBook",native.SpellBook,"Spells")
                    capture("AddedSpells",native.AddedSpells,"Spells")
                    capture("SpellContainer",native.SpellContainer,"Spells")
                    capture("SpellBookPrepares",native.SpellBookPrepares,"PreparedSpells")
                    local names={}
                    for name in pairs(lookup) do names[#names+1]=name end
                    table.sort(names)
                    for _,name in ipairs(names) do
                        local exists="unknown"
                        local ok,result=pcall(function() return Osi.HasSpell(actor,name) end)
                        if ok then exists=tostring(result) end
                        table.sort(hits[name])
                        RespecStartLog("NATIVE_L1_CLASS_GRANT_SOURCE actor="..actor
                            .." phase="..stage.." spell="..name.." has="..exists
                            .." records="..(#hits[name]>0 and table.concat(hits[name],";") or "none"))
                    end
                end)
                if not success then
                    RespecStartLog("NATIVE_L1_CLASS_GRANT_PROBE_ERROR actor="..actor
                        .." phase="..stage.." reason="..tostring(problem))
                end
            end
            local classBuildMode=type(merged.hbBuildPresetImport)=='table'
                and merged.hbBuildPresetImport.ClassChange==true
            -- Cross-class imports cannot write a foreign/obsolete SpellBook
            -- over BG3's current caster. Keep the native SpellBook and let
            -- progression grants regenerate, then audit every selected spell.
            local engineRemovalMode=classBuildMode or
                (type(merged.hbRemovedFeatSpellKeys)=="table"
                    and next(merged.hbRemovedFeatSpellKeys)~=nil)
            if engineRemovalMode and not classBuildMode then
                -- Reject unsupported missing grants while all original
                -- level-2+ progression entities are still intact.
                local pre,preReason=HB_NativeFirstLevelRestore.PlanEngineOwnedSpellDiff(
                    merged,fresh,target,state.originalSnapshot)
                if not pre then error("Pre-destruction engine spell plan refused: "
                    ..tostring(preReason)) end
                -- Osi symbols are Script Extender call proxies, NOT necessarily
                -- ordinary Lua functions. Checking type(Osi.AddSpell) against
                -- "function" wrongly rejected the valid game API after the
                -- destructive progression replay. Probe the read-only query
                -- before deleting anything, so missing Osiris context fails
                -- before character state is modified.
                if (#pre.Add>0 or #pre.Remove>0) then
                    if not Osi then error("Osiris server context unavailable before native replay") end
                    local probeSpell=(pre.Add[1] and pre.Add[1].Id) or pre.Remove[1]
                    local probeOk,probe=pcall(function()
                        return Osi.HasSpell(actor,probeSpell)
                    end)
                    if not probeOk or (probe~=0 and probe~=1
                        and probe~=true and probe~=false) then
                        error("Read-only Osiris HasSpell preflight failed: "
                            ..tostring(probe))
                    end
                    RespecStartLog("NATIVE_L1_OSIRIS_QUERY_PREFLIGHT actor="..actor
                        .." probe="..tostring(probeSpell)
                        .." has="..tostring(probe)
                        .." addProxy="..tostring(type(Osi.AddSpell))
                        .." removeProxy="..tostring(type(Osi.RemoveSpell)))
                end
                RespecStartLog("NATIVE_L1_CASTSAFE_ENGINE_REPLAY actor="..actor
                    .." mode=preserve_native_components"
                    .." preflightAdd="..#pre.Add.." preflightRemove="..#pre.Remove)
            end
            RespecStartLog("NATIVE_L1_MATCHED_PREPARED actor="..actor
                .." level="..target
                .." spellRestore="..tostring(spellCount and spellCount.AddedHigherLevelSpells)
                .." backup="..tostring(state.backupPath))
            -- Preserve BG3's freshly granted level-one class effects and all
            -- its progression entities. Only levels 2+ can be deleted.
            local cleared,count=pcall(DestroyExistingProgressions,live,true)
            if not cleared then error("Could not clear higher-level progressions: "..tostring(count)) end
            Ext.OnNextTick(function()
                local applied,reason=pcall(function()
                    local current=Ext.Entity.Get(actor)
                    if not current then error("Character disappeared before restore") end
                    local originalClass,verify=pcall(PartialRespecSnapshot.InspectCharacter,current)
                    if not originalClass then error("Cannot check native foundation: "..tostring(verify)) end
                    local matches,why=HB_NativeFirstLevelRestore.CheckFirstClass(merged,verify)
                    if not matches then error(why) end
                    local result=PartialRespecSnapshot.ApplySnapshotToCharacter(
                        current,merged,target,
                        engineRemovalMode and {KeepNativeSpellBook=true} or nil)
                    current.EocLevel.Level=target
                    current:Replicate("EocLevel")
                    NativePresentationTraceHotbar(actor,state.nativePresentation,"post-first-replay")
                    RespecStartLog("NATIVE_L1_HIGHER_LEVEL_RESTORED actor="..actor
                        .." target="..target.." newEntries="..tostring(result.newEntries))
                    Ext.Timer.WaitFor(950,function()
                        local gameGranted=nil
                        local osirisIntroduced={}
                        if engineRemovalMode and not classBuildMode then
                            local okNative,whyNative=pcall(function()
                                local currentNative=Ext.Entity.Get(actor)
                                if not currentNative then error("Actor missing for native spell sync") end
                                local stateNow=PartialRespecSnapshot.InspectCharacter(actor)
                                local plan,reason=HB_NativeFirstLevelRestore.PlanEngineOwnedSpellDiff(
                                    merged,stateNow,target,state.originalSnapshot)
                                if not plan then error(reason) end
                                -- Osiris calls are callable proxies. The
                                -- pcall enclosing this transaction is the
                                -- authoritative dispatch check; never reject
                                -- them based on Lua type()=="function".
                                if not Osi then error("Osiris server context unavailable") end
                                local observedRoots={}
                                for _,entry in ipairs(plan.Add) do
                                    observedRoots[#observedRoots+1]=entry.Id
                                end
                                ProbeNativeSpellSources(observedRoots,"before-osiris-add")
                                gameGranted={}
                                for _,id in ipairs(plan.Remove) do
                                    Osi.RemoveSpell(actor,id,1)
                                end
                                for _,entry in ipairs(plan.Add) do
                                    -- Add only a proven independent spell.
                                    -- AddSpell's last argument is
                                    -- _AddContainerSpells: 1 allows BG3 to
                                    -- register its children itself; calling
                                    -- AddSpell(child) separately causes
                                    -- duplicate spells and hotbar actions.
                                    local has=Osi.HasSpell(actor,entry.Id)
                                    if has~=0 and has~=1
                                        and has~=true and has~=false then
                                        error("Osiris HasSpell returned invalid result for "
                                            ..tostring(entry.Id)..": "..tostring(has))
                                    end
                                    if has~=1 and has~=true then
                                        Osi.AddSpell(actor,entry.Id,0,1)
                                        osirisIntroduced[entry.Id]=true
                                    end
                                    gameGranted[entry.Id]=true
                                end
                                ProbeNativeSpellSources(observedRoots,"after-osiris-add")
                                Ext.Timer.WaitFor(400,function()
                                    ProbeNativeSpellSources(observedRoots,"after-osiris-add-plus-400ms")
                                end)
                                Ext.Timer.WaitFor(1600,function()
                                    ProbeNativeSpellSources(observedRoots,"after-osiris-add-plus-1600ms")
                                end)
                                RespecStartLog("NATIVE_L1_ENGINE_SPELL_DIFF actor="..actor
                                    .." removed="..#plan.Remove.." rootGrants="..#plan.Add
                                    .." derivedNotIndependentlyGranted="..#(plan.Derived or {})
                                    .." spells="..table.concat((function()
                                        local ids={};for _,entry in ipairs(plan.Add) do
                                            ids[#ids+1]=entry.Id
                                        end;return ids
                                    end)(),","))
                            end)
                            if not okNative then
                                RespecStartLog("NATIVE_L1_ENGINE_SPELL_DIFF_REFUSED actor="..actor
                                    .." reason="..tostring(whyNative))
                                PartialRespecChannel:SendToClient({NativeFirstLevelStatus={
                                    Success=false,Text="Game-owned spell replay could not be verified. Reload the original save. "
                                        ..tostring(whyNative)}},RespecViewerUser(actor))
                                return
                            end
                        end
                        -- Class spell repair: the game confirmed that after
                        -- Osi.AddSpell(root), both the restored ProgressionClass
                        -- grant and a second, unwanted Osiris grant exist.
                        -- NEVER mutate/Unserialize SpellBook or hotbar to hide
                        -- that duplicate. Remove only the root we added via
                        -- Osiris, only after the unique recorded class grant
                        -- is present, and require class-only proof afterward.
                        local function VerifyEngineClassRoots(removeIntroduced,stage)
                            if classBuildMode then return true,'build-owned casting' end
                            if not engineRemovalMode then return true,"non-removal" end
                            if type(gameGranted)~="table" then return false,"No game spell grant inventory" end
                            local native=Ext.Entity.Get(actor)
                            if not native or not native.SpellBook then
                                return false,"Native SpellBook missing at "..stage
                            end
                            local okBook,book=pcall(Ext.Types.Serialize,native.SpellBook)
                            if not okBook or type(book)~="table"
                                or type(book.Spells)~="table" then
                                return false,"Cannot inspect live source identities at "..stage
                            end
                            local recorded=merged.components and merged.components.spellBook
                                and merged.components.spellBook.Spells
                            if type(recorded)~="table" then
                                return false,"Recorded class spell owners unavailable"
                            end
                            local targetNames={}
                            for name in pairs(gameGranted) do targetNames[name]=true end
                            local expected={}
                            for _,entry in ipairs(recorded) do
                                local sid=type(entry)=="table" and (entry.Id or entry)
                                local name=type(sid)=="table" and tostring(sid.Prototype or "") or ""
                                if targetNames[name] then
                                    if expected[name] then
                                        return false,"Multiple recorded owners for "..name
                                    end
                                    if (sid.SourceType~="ProgressionClass"
                                            and sid.SourceType~="ProgressionSubClass")
                                        or tostring(sid.ProgressionSource or "")==""
                                        or tostring(sid.ProgressionSource or "")=="00000000-0000-0000-0000-000000000000"
                                        or tostring(sid.Source or "")~="00000000-0000-0000-0000-000000000000" then
                                        return false,"Unverified historical class source for "..name
                                    end
                                    expected[name]={Type=tostring(sid.SourceType),
                                        Progression=tostring(sid.ProgressionSource):lower()}
                                end
                            end
                            local roots={}
                            for name in pairs(targetNames) do roots[#roots+1]=name end
                            table.sort(roots)
                            local toRemove={}
                            for _,name in ipairs(roots) do
                                local identity=expected[name]
                                if not identity then return false,"Missing historical owner for "..name end
                                local classCount,osirisCount=0,0
                                local classFound={}
                                for _,entry in ipairs(book.Spells) do
                                    local sid=type(entry)=="table" and (entry.Id or entry)
                                    if type(sid)=="table" and tostring(sid.Prototype or "")==name then
                                        local kind=tostring(sid.SourceType or "")
                                        local progression=tostring(sid.ProgressionSource or ""):lower()
                                        local source=tostring(sid.Source or ""):lower()
                                        if kind==identity.Type and progression==identity.Progression
                                            and source=="00000000-0000-0000-0000-000000000000" then
                                            classCount=classCount+1
                                        elseif kind=="Osiris"
                                            and progression=="00000000-0000-0000-0000-000000000000"
                                            and source=="00000000-0000-0000-0000-000000000000" then
                                            osirisCount=osirisCount+1
                                        else
                                            return false,"Unexpected additional grant source: "..name
                                                .." type="..kind
                                        end
                                    end
                                end
                                if classCount~=1 then
                                    return false,"Recorded class grant count "..classCount.." for "..name
                                end
                                if osirisCount>1 then return false,"Ambiguous Osiris grants for "..name end
                                if removeIntroduced then
                                    if osirisCount==1 then
                                        if not osirisIntroduced[name] then
                                            return false,"Preexisting Osiris grant not owned by this replay: "..name
                                        end
                                        toRemove[#toRemove+1]=name
                                    end
                                elseif osirisCount~=0 then
                                    return false,"Unwanted Common/Osiris grant remains for "..name
                                end
                            end
                            if removeIntroduced then
                                for _,name in ipairs(toRemove) do
                                    -- 0: do not remove spell-container children.
                                    -- Osiris' native implementation is used
                                    -- to retire this transaction's root grant.
                                    Osi.RemoveSpell(actor,name,0)
                                end
                            else
                                for _,name in ipairs(roots) do
                                    local has=Osi.HasSpell(actor,name)
                                    if has~=1 and has~=true then
                                        return false,"Wizard-owned cast unavailable: "..name
                                    end
                                end
                            end
                            RespecStartLog("NATIVE_L1_OSIRIS_GRANT_CLEANUP actor="..actor
                                .." phase="..stage.." roots="..#roots
                                .." cleaned="..#toRemove
                                .." classVerified="..#roots)
                            return true,nil
                        end
                        local function RefuseEngineCleanup(reason)
                            RespecStartLog("NATIVE_L1_OSIRIS_GRANT_CLEANUP_REFUSED actor="..actor
                                .." reason="..tostring(reason))
                            PartialRespecChannel:SendToClient({NativeFirstLevelStatus={
                                Success=false,Text="Historical class spell cleanup was not verified. "
                                    .."Reload your original save. "..tostring(reason)}},
                                RespecViewerUser(actor))
                        end
                        local function RunNativeAudit()
                        local audited,result,why=pcall(function()
                            local livePost=Ext.Entity.Get(actor)
                            local lvl=livePost and livePost.EocLevel
                                and tonumber(livePost.EocLevel.Level)
                            if lvl~=target then return false,"Restored character level does not match" end
                            local post=PartialRespecSnapshot.InspectCharacter(actor)
                            if classBuildMode then
                                -- Never substitute the donor's live caster or
                                -- declare the recipient's obsolete class casts
                                -- to be correct. Generic audit verifies native
                                -- history/progression; the separate import audit
                                -- requires target grants with their real owners.
                                local check=CopyPlainTable(merged)
                                check.components.spellBook=CopyPlainTable(post.components.spellBook)
                                -- Keep all strict removed/retained feat-action
                                -- proof maps from the normal native merger.
                                -- Only casting identity is supplied by BG3.
                                local same,reason=HB_NativeFirstLevelRestore.Audit(check,post,target)
                                if not same then return false,reason end
                                if not state.buildPresetDefinition then
                                    return false,'Imported build validation record vanished.'
                                end
                                return HBBuildPresetData.VerifyLiveImported(
                                    state.buildPresetDefinition,merged,post,state.originalSnapshot,actor)
                            end
                            if engineRemovalMode then
                                local ownersOk,ownerWhy=VerifyEngineClassRoots(false,"final-audit")
                                if not ownersOk then return false,ownerWhy end
                                -- Once extra Osiris roots are removed, the
                                -- historical owner itself must pass the full
                                -- original spell audit (not just a prototype
                                -- / Osiris-sourced casting fallback).
                                local originalOk,originalWhy=HB_NativeFirstLevelRestore.Audit(
                                    merged,post,target)
                                if not originalOk then return false,originalWhy end
                                local passedNative,nativeReason=HB_NativeFirstLevelRestore.AuditEngineOwnedSpells(
                                    merged,post,target,gameGranted)
                                if not passedNative then return false,nativeReason end
                                -- Live component rows alone cannot prove that
                                -- BG3's Osiris casting registry recognizes
                                -- each newly game-owned spell.
                                for spell in pairs(gameGranted or {}) do
                                    local registered=Osi.HasSpell and Osi.HasSpell(actor,spell)
                                    if registered~=1 and registered~=true then
                                        return false,"Native cast registry missing: "..spell
                                    end
                                end
                                if merged.hbBuildPresetImport then
                                    return HBBuildPresetData.VerifyLiveImported(
                                        state.buildPresetDefinition,merged,post,state.originalSnapshot,actor)
                                end
                                return true,nil
                            end
                            local nativeOk,nativeWhy=HB_NativeFirstLevelRestore.Audit(merged,post,target)
                            if not nativeOk then return false,nativeWhy end
                            if merged.hbBuildPresetImport then
                                return HBBuildPresetData.VerifyLiveImported(
                                    state.buildPresetDefinition,merged,post,state.originalSnapshot,actor)
                            end
                            return true,nil
                        end)
                        local passed=audited and result==true
                        local function SendFinal(passedFinal,finalReason)
                            if passedFinal then
                                NativePresentationAfterAudit(actor,state.nativePresentation,target,
                                    merged,state.originalSnapshot)
                            end
                            RespecStartLog("NATIVE_L1_POSTREPLAY_AUDIT actor="..actor
                                .." successful="..tostring(passedFinal)
                                .." reason="..tostring(finalReason or ""))
                            PartialRespecChannel:SendToClient({NativeFirstLevelStatus={
                                Success=passedFinal,RestoredLevel=passedFinal and target or nil,
                                Text=passedFinal and ("Higher levels restored through level "..target)
                                    or ("Higher-level restoration needs verification: "
                                        ..tostring(finalReason or "unknown error")
                                        ..". Reload your original save.")}},
                                RespecViewerUser(actor))
                        end
                        -- Never hide a lost spell via an audit exemption. BG3
                        -- can remove real, source-backed higher-level grants in
                        -- a deferred native SpellBook refresh. Re-assert only
                        -- independently chosen class spells whose original CC
                        -- choice and progression source match exactly, then
                        -- audit again after another engine update window.
                        if not engineRemovalMode and not merged.hbBuildPresetImport
                            and not passed and audited and type(why)=="string"
                            and why:find("Live spell grant missing after restore: ",1,true)==1 then
                            NativePresentationTraceHotbar(actor,state.nativePresentation,
                                "before-class-spell-recovery")
                            local okRepair,repair,repairWhy=pcall(function()
                                local liveNow=Ext.Entity.Get(actor)
                                local post=PartialRespecSnapshot.InspectCharacter(actor)
                                local plan,refusal=HB_NativeFirstLevelRestore.PlanHistoricalSpellRecovery(
                                    merged,post,target)
                                if not plan then return nil,refusal end
                                if not liveNow or not liveNow.SpellBook or not liveNow.SpellBookPrepares then
                                    return nil,"Live spell components vanished"
                                end
                                Ext.Types.Unserialize(liveNow.SpellBook,plan.SpellBook)
                                liveNow:MarkChanged("SpellBook")
                                liveNow:Replicate("SpellBook")
                                Ext.Types.Unserialize(liveNow.SpellBookPrepares,plan.SpellBookPrepares)
                                liveNow:MarkChanged("SpellBookPrepares")
                                liveNow:Replicate("SpellBookPrepares")
                                return plan,nil
                            end)
                            if okRepair and repair then
                                RespecStartLog("NATIVE_L1_SECOND_SPELLBOOK_WRITE_NEEDED actor="..actor)
                                RespecStartLog("NATIVE_L1_PROVEN_CLASS_SPELL_RECOVERY actor="..actor
                                    .." count="..tostring(#repair.Spells)
                                    .." spells="..table.concat(repair.Spells,","))
                                Ext.Timer.WaitFor(850,function()
                                    local okAgain,matchAgain,whyAgain=pcall(function()
                                        local now=Ext.Entity.Get(actor)
                                        if not now or not now.EocLevel
                                            or tonumber(now.EocLevel.Level)~=target then
                                            return false,"Historical level changed during spell recovery"
                                        end
                                        return HB_NativeFirstLevelRestore.Audit(merged,
                                            PartialRespecSnapshot.InspectCharacter(actor),target)
                                    end)
                                    SendFinal(okAgain and matchAgain==true,
                                        okAgain and whyAgain or tostring(matchAgain))
                                end)
                                return
                            end
                            RespecStartLog("NATIVE_L1_PROVEN_CLASS_SPELL_RECOVERY_REFUSED actor="..actor
                                .." reason="..tostring(okRepair and repairWhy or repair))
                        end
                        SendFinal(passed,why or (not audited and tostring(result) or ""))
                        end -- RunNativeAudit
                        if engineRemovalMode then
                            -- Wait for the delayed native progression grant
                            -- (observed at +400 ms) before asking the engine
                            -- to remove only the Osiris additions. If this
                            -- call also destroys the class grant, our later
                            -- audit refuses the respec; it never claims a
                            -- successful build with a lost cast.
                            Ext.Timer.WaitFor(700,function()
                                local invoked,okClean,whyClean=pcall(
                                    VerifyEngineClassRoots,true,"before-remove-osiris")
                                if not invoked or not okClean then
                                    RefuseEngineCleanup(invoked and whyClean or okClean)
                                    return
                                end
                                Ext.Timer.WaitFor(900,function()
                                    local verified,okAfter,whyAfter=pcall(
                                        VerifyEngineClassRoots,false,"after-remove-osiris")
                                    if not verified or not okAfter then
                                        RefuseEngineCleanup(verified and whyAfter or okAfter)
                                        return
                                    end
                                    RunNativeAudit()
                                end)
                            end)
                        else
                            RunNativeAudit()
                        end
                    end)
                end)
                if not applied then
                    RespecStartLog("NATIVE_L1_RESTORE_RUNTIME_FAILURE actor="..actor
                        .." reason="..tostring(reason)
                        .." backup="..tostring(state.backupPath))
                    PartialRespecChannel:SendToClient({NativeFirstLevelStatus={
                        Success=false,Text="Higher-level restoration failed. Reload your original save. "
                        ..tostring(reason)}},RespecViewerUser(actor))
                end
            end)
        end)
        if not success then
            RespecStartLog("NATIVE_L1_RESTORE_REFUSED actor="..actor
                .." reason="..tostring(why)
                .." originalBackup="..tostring(state.backupPath))
            local actorNow=Ext.Entity.Get(actor)
            local safeFullFallback=actorNow and actorNow.EocLevel
                and tonumber(actorNow.EocLevel.Level)==1 or false
            -- Vanilla level one has ALREADY finished. Do not pretend this is
            -- transactional or forcibly recreate the original level one.
            PartialRespecChannel:SendToClient({NativeFirstLevelStatus={
                Success=false,FullRespecFallback=safeFullFallback,
                Text="Saved build not restored: "..tostring(why)
                ..". Reload your original save or level up normally."}},
                RespecViewerUser(actor))
        end
    end)
end

Ext.Osiris.RegisterListener("RespecCompleted", 1, "after", function(character)
    local characterGuid = Guid(character)
    if not PartialRespecEnabled then
        pendingRespec[characterGuid] = nil
        return
    end

    local state = pendingRespec[characterGuid]
    if not state then return end

    PartialRespecChannel:SendToClient({ Visible = false }, RespecViewerUser(characterGuid))
    if state.nativeFirstLevelRestore then
        pendingRespec[characterGuid]=nil
        NativePresentationTraceHotbar(characterGuid,state.nativePresentation,
            "native-respec-completed")
        RespecStartLog("NATIVE_L1_COMPLETED actor="..characterGuid
            .." savedLevel="..tostring(state.charLevel))
        FinishNativeFirstLevelRestore(characterGuid,state)
        return
    end

    if not state.level or not state.snapshot then
        pendingRespec[characterGuid] = nil
        PRPrint(1, "RespecCompleted: %s (full respec, no replay)", characterGuid)
        return
    end

    local targetLevel = state.level
    local snapshot = state.snapshot
    pendingRespec[characterGuid] = nil

    PRPrint(0, "RespecCompleted: replaying levels 1-%d for %s", targetLevel, characterGuid)

    local resolved,entity=pcall(Ext.Entity.Get,characterGuid)
    if not resolved or not entity then
        PRWarn(0, "Replay failed: cannot resolve entity for %s", characterGuid)
        RespecStartLog("RESPEC_COMPLETED_ENTITY_MISSING actor="..characterGuid
            .." error="..tostring(not resolved and entity or "nil entity"))
        if state.levelRespec==true then
            -- RespecCompleted has already fired; no native Confirm is left
            -- to reject. Queue one lookup on a fresh tick, then attempt the
            -- original snapshot recovery if still unavailable. Never leave
            -- a failure after vanilla respec completion wholly unreported.
            Ext.OnNextTick(function()
                local safe,later=pcall(Ext.Entity.Get,characterGuid)
                if safe and later then
                    ApplyReplay(later,snapshot,targetLevel,characterGuid,
                        state.experimentalEdits,true,state.originalSnapshot,state.backupPath)
                else
                    RespecStartLog("RESPEC_COMPLETED_ENTITY_RETRY_FAILED actor="..characterGuid)
                    QueueLevelReplayRecovery(characterGuid,state.originalSnapshot,targetLevel,
                        "entity absent after completed respec",state.backupPath)
                end
            end)
        end
        return
    end

    ApplyReplay(entity, snapshot, targetLevel, characterGuid, state.experimentalEdits,
        state.levelRespec==true, state.originalSnapshot, state.backupPath)
end)

Ext.Osiris.RegisterListener("RespecCancelled", 1, "after", function(character)
    local characterGuid = Guid(character)
    local state = pendingRespec[characterGuid]
    -- Always deliver UI cleanup, even if a previous rejected commit already
    -- cleared the pending session. The native historical wrapper exists on
    -- the client independently of server pendingRespec state.
    pendingRespec[characterGuid] = nil
    local okViewer,viewer=pcall(RespecViewerUser,characterGuid)
    if not okViewer or viewer==nil then
        RespecStartLog("RESPEC_CANCEL_CLEANUP_VIEWER_UNAVAILABLE actor="..characterGuid
            .." reason="..tostring(viewer))
        return
    end
    local okSend,sendError=pcall(function()
        PartialRespecChannel:SendToClient({Visible=false},viewer)
    end)
    RespecStartLog("RESPEC_CANCEL_CLEANUP actor="..tostring(characterGuid)
        .." pending="..tostring(state~=nil).." viewer="..tostring(viewer)
        .." sent="..tostring(okSend)
        ..(okSend and "" or (" reason="..tostring(sendError))))
end)

-- Experimental full-build replay. The sole supported edit is a single ExtraActions
-- selection per selected character level. Both independent data sources must agree:
-- CCLevelUp.LevelUps and the recorded ProgressionPassives for that exact level.
-- Do not mutate live components or any original snapshot until every edit validates.
local VALID_EXTRA_RESOURCES = {
    ExtraActions_Action = true,
    ExtraActions_BonusAction = true,
    ExtraActions_Reaction = true,
}

CopyPlainTable = function(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = CopyPlainTable(v) end
    return result
end

-- The historical spell catalog lists candidate spell IDs, but is not itself
-- a casting-level validator. Accept only same-rank replacements when both
-- installed spell stats expose a trustworthy numeric rank. Do not infer an
-- earlier-level slot from the current character's level-12 spellbook.
local function HistoricalSpellRank(id)
    local ok,stat=pcall(Ext.Stats.Get,tostring(id))
    if not ok or not stat then return nil end
    for _,field in ipairs({"Level","SpellLevel"}) do
        local got,value=pcall(function() return stat[field] end)
        local number=got and tonumber(value) or nil
        if number and number==math.floor(number) and number>=0 and number<=9 then
            return number
        end
    end
    return nil
end

local function HistoricalChosenSpellIds(record)
    local result={}
    if not record then return result end
    local function Scan(rows)
        for _,row in ipairs(rows or {}) do
            if type(row)=="string" and row~="" then
                -- Raw-string spell rows are view-only, but still count as
                -- recorded spells when checking whether a replacement would
                -- collide with a choice made at another level.
                result[#result+1]=row
            elseif type(row)=="table" then
                local single=row.SpellId or row.SpellID
                if single then result[#result+1]=tostring(single) end
                for _,value in ipairs(row.Spells or {}) do
                    if type(value)=="table" then
                        local id=value.SpellId or value.SpellID
                        if id then result[#result+1]=tostring(id) end
                    elseif type(value)=="string" then result[#result+1]=value end
                end
            end
        end
    end
    Scan(record.Spells)
    Scan(record.Upgrades and record.Upgrades.Spells)
    return result
end


-- Safely dismantle an already-recorded HB Elemental Adept when replacing the
-- ENTIRE feat with a verified simple feat. This is intentionally asymmetric:
-- adding Elemental Adept still requires creating its two native choice slots.
-- The GUID/list/slot count come from an in-game-generated provenance report.
local HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT = "fdf0be80-cc1e-4501-bd2e-7a1ea737362c"
local function RemoveExistingElementalAdeptEffects(history, levelEntries, oldFeatId)
    if tostring(oldFeatId)~=HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT
        or tostring(history.Feat or "")~=oldFeatId then
        return false,"Original Elemental Adept feat identity does not match recorded history"
    end
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return false,"Elemental Adept choice history is unavailable"
    end
    -- Never accidentally discard a spell, skill or ability choice associated
    -- with the feat. Other class choices at the same level remain untouched.
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and row~=upgrades.Passives
                    and (tostring(row.Type or "")=="Feat"
                        or tostring(row.Class or "")==oldFeatId) then
                    -- Passive rows are validated independently below.
                    local isPassive=false
                    for _,passiveRow in ipairs(upgrades.Passives) do
                        if passiveRow==row then isPassive=true;break end
                    end
                    if not isPassive then
                        return false,"Elemental Adept has an additional unverified secondary choice"
                    end
                end
            end
        end
    end
    for _,row in ipairs(history.Spells or {}) do
        if type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==oldFeatId) then
            return false,"Elemental Adept has an unverified spell choice"
        end
    end
    local elementList=ResolvePassiveList(HB_ELEMENTAL_ADEPT_LIST)
    if not elementList then return false,"Elemental Adept list could not be verified" end
    local rowIndex,recorded,elementSet=nil,nil,{}
    for i,row in ipairs(upgrades.Passives) do
        if tostring(row.Type or "")=="Feat" or tostring(row.Class or "")==oldFeatId then
            if rowIndex or tostring(row.Class or "")~=oldFeatId
                or not IsRecordedElementalAdeptRow(history,row) then
                return false,"Elemental Adept has ambiguous or incomplete feat-owned selections"
            end
            rowIndex,recorded=i,row
        end
    end
    if not recorded then return false,"Expected two recorded Elemental Adept choices" end
    for _,passive in ipairs(recorded.Passives) do elementSet[tostring(passive)]=true end
    local normalCounts,featCounts,replicaCounts={},{},{}
    local primary,replicate=0,0
    local primaryRecord,replicaRecord=nil,nil
    local function CountElements(ids,counts)
        if type(ids)~="table" then return false end
        for _,id in ipairs(ids) do
            id=tostring(id)
            if elementSet[id] then counts[id]=(counts[id] or 0)+1 end
        end
        return true
    end
    local function NoOtherFeatGrants(component)
        if type(component)~="table" then return false end
        for _,field in ipairs({"AddSpells","Proficiencies","Expertise"}) do
            if component[field]~=nil then
                if type(component[field])~="table" or next(component[field])~=nil then return false end
            end
        end
        for _,value in ipairs(component.AbilityImprovements or {}) do
            if tonumber(value)~=0 then return false end
        end
        return true
    end
    for _,entry in ipairs(levelEntries or {}) do
        for _,key in ipairs({"feat","replicatedFeat"}) do
            local record=entry[key]
            if record and tostring(record.Feat or "")==oldFeatId then
                if key=="feat" then
                    primary=primary+1;primaryRecord=record
                else
                    replicate=replicate+1;replicaRecord=record
                end
                if not NoOtherFeatGrants(record) then
                    return false,"Elemental Adept has extra feat effects that cannot be removed safely"
                end
                local counts=key=="feat" and featCounts or replicaCounts
                if not CountElements(record.AddPassives or {},counts) then
                    return false,"Elemental Adept passive component is malformed"
                end
                for _,id in ipairs(record.AddPassives or {}) do
                    if not elementSet[tostring(id)] then
                        return false,"Elemental Adept feat has an unexpected passive effect"
                    end
                end
            end
        end
        if entry.passives and entry.passives.AddPassives then
            if not CountElements(entry.passives.AddPassives,normalCounts) then
                return false,"Elemental Adept progression passives are malformed"
            end
        end
    end
    if primary~=1 or replicate~=1 then
        return false,"Elemental Adept primary/replicated progression components differ"
    end
    for id in pairs(elementSet) do
        if normalCounts[id]~=1 or featCounts[id]~=1
            or (replicaCounts[id] or 0)>1 then
            return false,"Elemental Adept passive grants are not uniquely attributable: "..id
        end
    end
    -- Replicated feats are observed both with and without mirrored passives.
    -- Reject a partial mirror, since that is not a simple two-slot record.
    local mirrored=0
    for _,n in pairs(replicaCounts) do mirrored=mirrored+n end
    if mirrored~=0 and mirrored~=2 then
        return false,"Elemental Adept replicated passive grants are incomplete"
    end
    -- All inspections have succeeded. Mutate ONLY the copied snapshot.
    local function FilterOwned(ids)
        local keep={}
        for _,id in ipairs(ids or {}) do
            if not elementSet[tostring(id)] then keep[#keep+1]=id end
        end
        return keep
    end
    for _,entry in ipairs(levelEntries) do
        if entry.passives and entry.passives.AddPassives then
            entry.passives.AddPassives=FilterOwned(entry.passives.AddPassives)
        end
    end
    primaryRecord.AddPassives=FilterOwned(primaryRecord.AddPassives)
    if replicaRecord.AddPassives then
        replicaRecord.AddPassives=FilterOwned(replicaRecord.AddPassives)
    end
    table.remove(upgrades.Passives,rowIndex)
    return true,nil
end


-- Complement of RemoveExistingElementalAdeptEffects. The historical choice
-- record shape and the exact Elemental Adept list are grounded in two real
-- serialized BG3 level-up reports (original Acid/Cold, persisted Acid/Fire).
-- Only the already-verified simple-feat progression shape can be upgraded.
local function AddRecordedElementalAdeptEffects(history,levelEntries,oldFeatId,choices,level)
    if tostring(history.Feat or "")~=oldFeatId then
        return false,"Source simple feat history changed before Elemental Adept addition"
    end
    if type(choices)~="table" or #choices~=2 or next(choices,2)~=nil then
        return false,"Elemental Adept requires exactly two elemental choices"
    end
    local allowed=ResolvePassiveList(HB_ELEMENTAL_ADEPT_LIST)
    if not allowed then return false,"Elemental Adept passive catalog is unavailable" end
    local seen={}
    for _,id in ipairs(choices) do
        if type(id)~="string" or not id:match("^ElementalAdept_[%a]+$")
            or not allowed.Set[id] or seen[id] then
            return false,"Elemental Adept choices must be two different allowed elements"
        end
        seen[id]=true
    end
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return false,"Cannot create choices without the original level-up upgrade structure"
    end
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==oldFeatId
                    or tostring(row.Class or "")==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT) then
                    return false,"Source feat has unexpected feat-owned secondary selections"
                end
            end
        end
    end
    for _,row in ipairs(history.Spells or {}) do
        if type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==oldFeatId) then
            return false,"Source feat has unverified recorded spell effects"
        end
    end
    local primary,replicated,normal=nil,nil,nil
    local primaryEntry,replicatedEntry,normalEntry=nil,nil,nil
    local priCount,repCount,normalCount=0,0,0
    local function FeatRecordClean(record)
        for _,key in ipairs({"AddPassives","AddSpells","Expertise","Proficiencies"}) do
            if record[key]~=nil and
                (type(record[key])~="table" or next(record[key])~=nil) then return false end
        end
        for _,value in ipairs(record.AbilityImprovements or {}) do
            if tonumber(value)~=0 then return false end
        end
        return true
    end
    -- Reject already granted elements ANYWHERE, including an unrelated
    -- progression bucket; never introduce duplicate passive grants.
    local bucketsGlobal=nil -- populated and checked by the caller below
    for _,entry in ipairs(levelEntries or {}) do
        if entry.feat and tostring(entry.feat.Feat or "")==oldFeatId then
            priCount=priCount+1;primary=entry.feat;primaryEntry=entry
            if not FeatRecordClean(primary) then
                return false,"Old simple feat carries incompatible progression grants"
            end
        end
        if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat or "")==oldFeatId then
            repCount=repCount+1;replicated=entry.replicatedFeat;replicatedEntry=entry
            if not FeatRecordClean(replicated) then
                return false,"Replicated simple feat carries incompatible progression grants"
            end
        end
        if entry.passives and type(entry.passives.AddPassives)=="table" then
            normalCount=normalCount+1;normal=entry.passives;normalEntry=entry
        end
        for _,kind in ipairs({"feat","replicatedFeat","passives"}) do
            local record=entry[kind]
            for _,id in ipairs(record and record.AddPassives or {}) do
                if seen[tostring(id)] then
                    return false,"An elemental choice is already granted in this progression level"
                end
            end
        end
    end
    if priCount~=1 or repCount~=1 or normalCount>1 then
        return false,"Expected exactly one old feat and replica, with at most one normal-passive component"
    end
    if not primary or not replicated or not primaryEntry or not replicatedEntry then
        return false,"Elemental Adept needs the original feat progression components"
    end
    -- Live Alert snapshots have one class-owned progression entity containing
    -- ProgressionFeat + ProgressionReplicatedFeat, but NO ProgressionPassives.
    -- Natural Elemental Adept grants both elemental choices in that same
    -- class progression (as well as in ProgressionFeat). Snapshot restore
    -- supports multiple components on a single progression entity. Creating
    -- a passives COMPONENT there avoids fabricating a second progression
    -- entity or guessing its metadata from a different level.
    local sourceMeta=primaryEntry.meta
    if primaryEntry~=replicatedEntry or type(sourceMeta)~="table"
        or tonumber(sourceMeta.Level)~=tonumber(level)
        or tostring(sourceMeta.SpellSourceType or "")~="ProgressionClass"
        or type(sourceMeta.Progression)~="string" or sourceMeta.Progression==""
        or type(sourceMeta.Source)~="string" or sourceMeta.Source=="" then
        return false,"Simple feat class progression metadata does not support safe elemental grants"
    end
    if normalCount==1 then
        -- Reject a race/subclass passives component from the same level;
        -- neither a feat choice nor its grants may be transplanted there.
        if type(normal)~="table" or type(normal.AddPassives)~="table"
            or (normal.RemovePassives~=nil and
                (type(normal.RemovePassives)~="table" or next(normal.RemovePassives)~=nil))
            or type(normalEntry.meta)~="table"
            or tostring(normalEntry.meta.Progression or "")~=sourceMeta.Progression
            or tostring(normalEntry.meta.Source or "")~=sourceMeta.Source then
            return false,"Existing level passive grants do not belong to the original feat progression"
        end
    end
    -- All inspections succeeded. Mutate only the candidate snapshot.
    -- With no existing ProgressionPassives, attach one to the VERIFIED
    -- feat-owning entity. Normal component shape comes from the already
    -- serialized BG3 progression snapshots (AddPassives / RemovePassives).
    if normalCount==0 then
        normal={AddPassives={},RemovePassives={}}
        primaryEntry.passives=normal
        RespecStartLog("HISTORICAL_ELEMENTAL_ADEPT_PASSIVES_CREATED level="..tostring(level)
            .." progression="..sourceMeta.Progression)
    end
    -- Preserve any unrelated class passives already in the component.
    primary.AddPassives={choices[1],choices[2]}
    -- The verified original provenance had primary FeatPassives only, with
    -- zero mirrored replica entries. Keep replica empty, as the game did.
    replicated.AddPassives={}
    normal.AddPassives[#normal.AddPassives+1]=choices[1]
    normal.AddPassives[#normal.AddPassives+1]=choices[2]
    upgrades.Passives[#upgrades.Passives+1]={
        Type="Feat",Class=HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT,
        SelectorId="",PassiveList=HB_ELEMENTAL_ADEPT_LIST,
        Passives={choices[1],choices[2]},ReplacePassives={},
        DefinitionIndex=0,Level=level,Multiclass=false,
        Subclass=history.Class,field_80=-1
    }
    return true,nil
end


-- Independent two-passive feat add/remove path for source-defined ASI and
-- Class Specialist. Never infer provenance from feat display names alone.
-- No client-provided IDs are trusted: both list membership and every owning
-- historical/progression record are verified before editing a copied snapshot.
-- Exact feat GUID flags from the user's supplied Feats.lsx; these are
-- additional negative safety evidence when Script Extender's runtime Feat
-- selectors/requirements accessor throws or omits its LSX member.
-- Treat unrecognized feats with unavailable runtime fields as PROTECTED.
local HB_GENERIC_FEATS=(function()
    local ok,value=pcall(Ext.Require,"Shared/HB_GenericFeatContracts.lua")
    if ok and type(value)=="table" then return value end
    return {PassiveSelectors=function() return nil end,
        Definition=function() return nil end, RequiredClass=function() return nil end,
        IsKnownFixedOnly=function() return false end}
end)()
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
	["1e0ac3c4-5bb5-42d7-941c-9de58d919732"]={s=true,r=false}, -- ClassDivergence_Artificer    ["26c6990b-d9f0-41a2-8108-209789fafc18"]={s=false,r=false}, -- CombatMedic
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

local function PairFeatStaticContract(featId,config)
    if not config then return false,"Unknown two-passive feat definition" end
    local ok,feat=pcall(Ext.StaticData.Get,featId,"Feat")
    if not ok or not feat then return false,"Two-passive feat static metadata unavailable" end
    -- The SE Feat accessor on some BG3 builds exposes the GUID/Name but
    -- omits the LSX Selectors member. Earlier builds rejected EVERY ASI and
    -- Class Specialist on that build. A NIL member is not evidence that the
    -- feat has no selector; its authoritative rule is the pinned GUID/name/
    -- exact list+selector contract audited against HB Feats.lsx.
    -- Never use this fallback for arbitrary feats or for non-nil runtime
    -- metadata: conflicts and extra selectors must still fail closed.
    local named,name=pcall(function() return feat.Name end)
    if not named then
        return false,"Feat identity could not be read from runtime static data"
    end
    if name~=nil and tostring(name)~="" and tostring(name)~=config.Name then
        RespecStartLog("HISTORICAL_PASSIVE_PAIR_NAME_MISMATCH feat="..tostring(featId)
            .." runtime="..tostring(name).." expected="..config.Name)
        return false,"Feat runtime identity differs from the HB source definition"
    end
    local read,selectors=pcall(function() return feat.Selectors end)
    -- On the observed game build, requesting the absent Feat.Selectors
    -- member THROWS, rather than returning nil. Both outcomes indicate
    -- unavailable runtime metadata, not a conflicting selector. Permit only
    -- our exact GUID/name/source-defined two-slot contract, with all
    -- historical/progression provenance checks still required below.
    -- When runtime data IS readable and non-nil, inspect it strictly.
    local sourcePinned=(not read or selectors==nil)
    local sourceReason=(not read) and "runtime_selectors_accessor_unavailable"
        or "runtime_selectors_absent"
    if sourcePinned then
        -- Fail closed for any ID outside the hard-coded HB definition
        -- whitelist. The source was audited by GUID against the exact LSX;
        -- passive membership, clean-source progression, choice count and
        -- feat ownership are independently checked before replay.
        if HB_PASSIVE_PAIR_FEATS[featId]~=config then
            return false,"Feat source selector contract is not whitelisted"
        end
        RespecStartLog("HISTORICAL_PASSIVE_PAIR_SOURCE_PINNED feat="..tostring(featId)
            .." name="..tostring(config.Name).." list="..tostring(config.List)
            .." reason="..sourceReason)
    end
    local exact=("SelectPassives(%s,2%s)"):format(config.List,
        config.Selector~="" and (","..config.Selector) or "")
    -- Ext.StaticData Feat.Selectors is an array on some SE/game builds, even
    -- when LSX declares a single selector expression. Checking type==string
    -- incorrectly rejects every complex feat on those builds. Read precisely
    -- ONE plain selector expression; never silently flatten, drop, or ignore
    -- additional selectors (especially from another mod).
    local function StaticSelectorText(value)
        if type(value)=="string" then return value end
        local kind=type(value)
        if kind~="table" and kind~="userdata" then return nil end
        local items={}
        local ok,err=pcall(function()
            for _,item in ipairs(value) do
                if #items>=2 then error("multiple selectors") end
                if type(item)~="string" then
                    -- Some SE arrays wrap a fixed string in a light object.
                    local got,inner=pcall(function() return item.Value end)
                    if got and type(inner)=="string" then item=inner end
                end
                if type(item)~="string" then error("unknown selector entry type") end
                items[#items+1]=item
            end
        end)
        if not ok or #items~=1 then return nil end
        if kind=="table" then
            -- ipairs alone can ignore nonarray keys; disallow such variants.
            local keys=0
            for k in pairs(value) do
                if k~=1 then return nil end
                keys=keys+1
            end
            if keys~=1 then return nil end
        end
        return items[1]
    end
    if not sourcePinned then
        local text=StaticSelectorText(selectors)
        if not text then
            RespecStartLog("HISTORICAL_PASSIVE_PAIR_SELECTOR_UNVERIFIED feat="..tostring(featId)
                .." kind="..type(selectors).." value="..tostring(selectors):sub(1,240))
            return false,"Feat selector could not be independently verified"
        end
        local normalized=text:gsub("%s+",""):gsub(";+$","")
        if normalized~=exact then
            RespecStartLog("HISTORICAL_PASSIVE_PAIR_SELECTOR_MISMATCH feat="..tostring(featId)
                .." actual="..normalized:sub(1,240).." expected="..exact)
            return false,"Feat selector differs from the HB source definition"
        end
    end
    local grant,added=pcall(function() return feat.PassivesAdded end)
    if not grant then
        -- Some engine builds also throw for an undefined PassivesAdded
        -- member. This is acceptable ONLY for the same pinned no-fixed-
        -- grant HB feat definition; all live progression component fields
        -- are still validated independently before replay.
        if HB_PASSIVE_PAIR_FEATS[featId]~=config then
            return false,"Feat passive grants cannot be verified"
        end
        RespecStartLog("HISTORICAL_PASSIVE_PAIR_NO_FIXED_GRANTS_SOURCE_PINNED feat="
            ..tostring(featId).." reason=runtime_passive_grant_accessor_unavailable")
        added=nil
    end
    local function IsEmptyGrant(value)
        if value==nil then return true end
        if type(value)=="string" then return value:match("%S")==nil end
        if type(value)=="table" then return next(value)==nil end
        if type(value)=="userdata" then
            local count=0
            local ok=pcall(function()
                for _ in ipairs(value) do count=count+1;break end
            end)
            return ok and count==0
        end
        return false
    end
    if not IsEmptyGrant(added) then
        RespecStartLog("HISTORICAL_PASSIVE_PAIR_FIXED_GRANTS_UNVERIFIED feat="..tostring(featId)
            .." kind="..type(added))
        return false,"Feat also grants unverified fixed passives"
    end
    return true,nil
end
local function ValidatePairIds(ids,config)
    if type(ids)~="table" or #ids~=2 or next(ids,2)~=nil then
        return nil,"Exactly two passive selections are required"
    end
    local list=ResolvePassiveList(config.List)
    if not list then return nil,"The feat's passive selector list is unavailable" end
    local owned={}
    for _,id in ipairs(ids) do
        if type(id)~="string" or not list.Set[id] or owned[id] then
            return nil,"Invalid or duplicated two-passive feat choice: "..tostring(id)
        end
        owned[id]=true
    end
    return owned,nil
end
local function CleanPairFeatComponent(record,allowed)
    if type(record)~="table" then return false end
    for _,field in ipairs({"AddSpells","Expertise","Proficiencies"}) do
        local value=record[field]
        if value~=nil and (type(value)~="table" or next(value)~=nil) then return false end
    end
    for _,value in ipairs(record.AbilityImprovements or {}) do
        if tonumber(value)~=0 then return false end
    end
    for _,id in ipairs(record.AddPassives or {}) do
        if not allowed or not allowed[tostring(id)] then return false end
    end
    if record.AddPassives~=nil and type(record.AddPassives)~="table" then return false end
    return true
end
-- Natural BG3 levels can serialize the two feat-owned passive picks as
-- one 2-slot row OR two separate 1-slot rows. The non-destructive historical
-- editor already recognizes both. Removal must agree instead of silently
-- refusing to remove an otherwise verified Class Specialist selection.
local function PairFeatRecordedRows(history,featId,config)
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return nil,nil,"Missing original feat choice history"
    end
    local indices,selected={},{}
    local count=0
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for i,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==featId) then
                    if rows~=upgrades.Passives
                        or tostring(row.Class or "")~=featId
                        or tostring(row.Type or "")~="Feat"
                        or tostring(row.PassiveList or "")~=config.List
                        or (tostring(row.SelectorId or "")~=""
                            and tostring(row.SelectorId or "")~=config.Selector)
                        or type(row.ReplacePassives)~="table"
                        or next(row.ReplacePassives)~=nil then
                        return nil,nil,"Feat passive row ownership or selector does not match"
                    end
                    local picks=row.Passives
                    if type(picks)~="table" or (#picks~=1 and #picks~=2)
                        or next(picks,#picks)~=nil then
                        return nil,nil,"Feat recorded passive row has an invalid slot count"
                    end
                    count=count+1
                    indices[#indices+1]=i
                    for _,id in ipairs(picks) do
                        id=tostring(id)
                        if selected[id] then
                            return nil,nil,"Feat recorded secondary passives are duplicated"
                        end
                        selected[id]=true
                    end
                end
            end
        end
    end
    for _,row in ipairs(history.Spells or {}) do
        if type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==featId) then
            return nil,nil,"Unexpected feat-owned spell history"
        end
    end
    local pairSize=0
    for _ in pairs(selected) do pairSize=pairSize+1 end
    if pairSize~=2 or (count~=1 and count~=2) then
        return nil,nil,"Expected exactly two feat-owned passive choices"
    end
    local list=ResolvePassiveList(config.List)
    if not list then return nil,nil,"Feat source passive list is unavailable" end
    for id in pairs(selected) do
        if not list.Set[id] then return nil,nil,"Feat secondary passive not in its selector list" end
    end
    return indices,selected,nil
end
local function RemoveRecordedPairFeatEffects(history,levelEntries,featId,config)
    if tostring(history.Feat or "")~=featId then
        return false,"Original feat ownership changed"
    end
    local contractOK,contractWhy=PairFeatStaticContract(featId,config)
    if not contractOK then return false,contractWhy end
    local rowIndices,selected,err=PairFeatRecordedRows(history,featId,config)
    if not rowIndices then return false,err end
    local primary,replica=0,0
    local prim,rep=nil,nil
    local pCount,rCount,nCount={},{},{}
    local function CountOwned(ids,dest)
        if type(ids)~="table" then return false end
        for _,id in ipairs(ids) do
            id=tostring(id)
            if selected[id] then dest[id]=(dest[id] or 0)+1 end
        end
        return true
    end
    for _,entry in ipairs(levelEntries) do
        for _,key in ipairs({"feat","replicatedFeat"}) do
            local rec=entry[key]
            if rec and tostring(rec.Feat or "")==featId then
                if key=="feat" then primary=primary+1;prim=rec else replica=replica+1;rep=rec end
                if not CleanPairFeatComponent(rec,selected)
                    or not CountOwned(rec.AddPassives or {},key=="feat" and pCount or rCount) then
                    return false,"Feat progression includes unverified effects"
                end
            end
        end
        if entry.passives and entry.passives.AddPassives then
            if not CountOwned(entry.passives.AddPassives,nCount) then
                return false,"Malformed normal progression passive grants"
            end
        end
    end
    if primary~=1 or replica~=1 then return false,"Feat primary/replicated records are not unique" end
    local mirror=0
    for id in pairs(selected) do
        if pCount[id]~=1 or nCount[id]~=1 or (rCount[id] or 0)>1 then
            return false,"Feat choice grants cannot be uniquely attributed: "..id
        end
        mirror=mirror+(rCount[id] or 0)
    end
    if mirror~=0 and mirror~=2 then return false,"Incomplete replicated feat choice mirror" end
    local function Filter(ids)
        local nextIds={}
        for _,id in ipairs(ids or {}) do if not selected[tostring(id)] then nextIds[#nextIds+1]=id end end
        return nextIds
    end
    for _,entry in ipairs(levelEntries) do
        if entry.passives and entry.passives.AddPassives then
            entry.passives.AddPassives=Filter(entry.passives.AddPassives)
        end
    end
    prim.AddPassives=Filter(prim.AddPassives)
    if rep.AddPassives then rep.AddPassives=Filter(rep.AddPassives) end
    -- Descending order preserves indexes when the feat had a split 1+1 row.
    table.sort(rowIndices,function(a,b) return a>b end)
    for _,index in ipairs(rowIndices) do
        table.remove(history.Upgrades.Passives,index)
    end
    return true,nil
end
local function AddRecordedPairFeatEffects(history,levelEntries,oldFeatId,newFeatId,choices,level,config)
    if tostring(history.Feat or "")~=oldFeatId then
        return false,"Source feat history differs from expected record"
    end
    local selected,why=ValidatePairIds(choices,config)
    if not selected then return false,why end
    local contractOK,contractWhy=PairFeatStaticContract(newFeatId,config)
    if not contractOK then return false,contractWhy end
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return false,"Cannot create feat selections without recorded upgrade structure"
    end
    -- Source must be an effect-free simple feat. All other original feat
    -- selections (including spells, skills and ability rows) are protected.
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==oldFeatId) then
                    return false,"Original feat already owns additional selections"
                end
            end
        end
    end
    for _,row in ipairs(history.Spells or {}) do
        if type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==oldFeatId) then
            return false,"Original feat owns recorded spell choices"
        end
    end
    local pri,rep,normal,owner=nil,nil,nil,nil
    local pn,rn,nn=0,0,0
    for _,entry in ipairs(levelEntries) do
        if entry.feat and tostring(entry.feat.Feat or "")==oldFeatId then
            pri=entry.feat;owner=entry;pn=pn+1
            if not CleanPairFeatComponent(pri,{}) then
                return false,"Original feat has unverified grant effects"
            end
        end
        if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat or "")==oldFeatId then
            rep=entry.replicatedFeat;rn=rn+1
            if not CleanPairFeatComponent(rep,{}) then
                return false,"Original replicated feat has unverified effects"
            end
        end
        if entry.passives and type(entry.passives.AddPassives)=="table" then
            normal=entry.passives;nn=nn+1
        end
        for _,key in ipairs({"feat","replicatedFeat","passives"}) do
            for _,id in ipairs(entry[key] and entry[key].AddPassives or {}) do
                if selected[tostring(id)] then return false,"Feat passive already granted at this level" end
            end
        end
    end
    if pn~=1 or rn~=1 or nn>1 or not pri or not rep or not owner then
        return false,"Source feat progression components cannot be attributed uniquely"
    end
    local meta=owner.meta
    if type(meta)~="table" or tonumber(meta.Level)~=tonumber(level)
        or tostring(meta.SpellSourceType or "")~="ProgressionClass"
        or type(meta.Source)~="string" or meta.Source==""
        or type(meta.Progression)~="string" or meta.Progression=="" then
        return false,"Source feat progression metadata is unavailable"
    end
    local replicaOwnerCount=0
    for _,entry in ipairs(levelEntries) do
        if entry.replicatedFeat==rep and entry==owner then replicaOwnerCount=replicaOwnerCount+1 end
        if entry.passives and entry.passives==normal then
            if type(entry.meta)~="table" or entry.meta.Progression~=meta.Progression
                or entry.meta.Source~=meta.Source
                or (entry.passives.RemovePassives~=nil and
                    (type(entry.passives.RemovePassives)~="table"
                    or next(entry.passives.RemovePassives)~=nil)) then
                return false,"Normal passives are owned by a different progression entity"
            end
        end
    end
    if replicaOwnerCount~=1 then return false,"Replicated feat is on a different progression entity" end
    if not normal then
        normal={AddPassives={},RemovePassives={}}
        owner.passives=normal
    end
    pri.AddPassives={choices[1],choices[2]}
    rep.AddPassives={}
    normal.AddPassives[#normal.AddPassives+1]=choices[1]
    normal.AddPassives[#normal.AddPassives+1]=choices[2]
    upgrades.Passives[#upgrades.Passives+1]={
        Type="Feat",Class=newFeatId,SelectorId=config.Selector,
        PassiveList=config.List,Passives={choices[1],choices[2]},
        ReplacePassives={},DefinitionIndex=0,Level=level,
        Multiclass=false,Subclass=history.Class,field_80=-1
    }
    return true,nil
end

-- Verified natural Accord of the Arcane CCLevelUp data (2026-10-14):
-- two cantrips in Upgrades.Spells[1] list ffad..., while their owned
-- ProgressionFeat + ProgressionSpells grants use list d136.... These two
-- different GUIDs are intentional. Ordinary learned-spell replay correctly
-- rejects this mismatch; only this exact feat-owned two-slot configuration
-- can rekey both grants with the choice on a copied snapshot.
-- Definition-driven historical passive-only Yokebreaker selector adapter.
-- The authoritative proof is the saved same-level Feat-owned CCLevelUp rows,
-- mirrored ProgressionFeat and exactly matching normal progression grants.
-- Fixed PassivesAdded are STAT-granted, NOT invented as new progression rows.
local function HBFGenericGroups(id)
    if HB_PASSIVE_PAIR_FEATS[id] or id==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT
        or id==HB_MULTIFACETED_FEAT_ID then return nil end
    return HB_GENERIC_FEATS.PassiveSelectors(id)
end
local function HBFGenericReqSatisfied(id,histories,level)
    local cls=HB_GENERIC_FEATS.RequiredClass(id)
    if cls==nil then return false,"Feat has a prerequisite expression that cannot be verified" end
    local feat=HB_GENERIC_FEATS.Definition(id)
    local got,record=pcall(Ext.StaticData.Get,id,"Feat")
    if not got or not record then return false,"Historical feat is not installed" end
    local read,raw=pcall(function() return record.Requirements end)
    if read and raw~=nil and raw~=false then
        local expression=nil
        if type(raw)=="string" then expression=raw
        elseif type(raw)=="table" or type(raw)=="userdata" then
            local ok,value=pcall(function()
                local pieces={}
                for _,entry in ipairs(raw) do
                    if type(entry)~="string" then entry=entry.Value end
                    if type(entry)~="string" then error("unsupported requirement") end
                    pieces[#pieces+1]=entry
                end
                return table.concat(pieces,";")
            end)
            if not ok then return false,"Installed feat requirements cannot be verified" end
            expression=value
        end
        if expression==nil
            or expression:gsub("%s+","")~=tostring(feat.Requirements or ""):gsub("%s+","") then
            return false,"Installed feat requirement differs from the pinned HB definition"
        end
    end
    if cls=="" then return true end
    for i=1,level do
        local h=histories[i]
        local classId=h and tostring(h.Class or "") or ""
        if classId~="" then
            local ok,data=pcall(Ext.StaticData.Get,classId,"ClassDescription")
            if ok and data then
                local got,name=pcall(function() return data.Name end)
                if got and tostring(name or ""):lower()==cls:lower() then return true end
            end
        end
    end
    return false,"Required "..cls.." class cannot be proved in historical levels 1-"..level
end
local function HBFGenericStaticContract(id,groups)
    local definition=HB_GENERIC_FEATS.Definition(id)
    if not definition or not groups then return false,"No pinned feat selector definition" end
    local ok,data=pcall(Ext.StaticData.Get,id,"Feat")
    if not ok or not data then return false,"Installed feat metadata is missing" end
    local named,name=pcall(function() return data.Name end)
    if not named or (name~=nil and tostring(name)~="" and tostring(name)~=definition.Name) then
        return false,"Installed feat identity does not match supplied feat definition"
    end
    local read,selectors=pcall(function() return data.Selectors end)
    if read and selectors~=nil and selectors~=false then
        local expressions={}
        if type(selectors)=="string" then
            for expression in selectors:gmatch("[^;]+") do
                if expression:match("%S") then expressions[#expressions+1]=expression end
            end
        elseif type(selectors)=="table" or type(selectors)=="userdata" then
            local safe=pcall(function()
                for _,expression in ipairs(selectors) do
                    if type(expression)~="string" then
                        expression=expression.Value
                    end
                    if type(expression)~="string" then error("unknown expression type") end
                    expressions[#expressions+1]=expression
                    if #expressions>#groups then error("unrecognized selector") end
                end
            end)
            if not safe then return false,"Installed selector metadata is unrecognizable" end
        else
            return false,"Installed feat selectors have an unsupported representation"
        end
        if #expressions~=#definition.Selectors then
            return false,"Installed feat selector count differs from its source definition"
        end
        for i,expression in ipairs(expressions) do
            local clean=tostring(expression):gsub("%s+",""):gsub(";+$","")
            local expected=tostring(definition.Selectors[i].Raw):gsub("%s+",""):gsub(";+$","")
            if clean~=expected then
                return false,"Installed feat selector expression differs from the source definition"
            end
        end
    end
    return true
end
local function HBFGenericValuesValid(groups,values)
    if type(values)~="table" then return nil,"Missing passive selector choices" end
    for key in pairs(values) do
        if type(key)~="number" or key~=math.floor(key) or key<1 or key>#groups then
            return nil,"Unexpected passive selector group"
        end
    end
    local all={}
    for index,g in ipairs(groups) do
        local rows=values[index]
        if type(rows)~="table" or #rows~=g.Count or next(rows,g.Count)~=nil then
            return nil,"Feat selector group "..index.." needs "..g.Count.." selections"
        end
        local list=ResolvePassiveList(g.List)
        if not list then return nil,"Passive list unavailable for group "..index end
        for _,id in ipairs(rows) do
            if type(id)~="string" or not list.Set[id] or all[id] then
                return nil,"Invalid or repeated passive option "..tostring(id)
            end
            all[id]=true
        end
    end
    return all
end
local function HBFGenericOwnedRows(history,featId,groups)
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return nil,nil,"Missing historical feat passive upgrade rows"
    end
    local indices,picks,counts,rowsByGroup={},{},{},{}
    for i=1,#groups do rowsByGroup[i]={} end
    local function FeatOwned(row)
        return type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==featId)
    end
    for name,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for i,row in ipairs(rows) do
                if FeatOwned(row) then
                    if name~="Passives" or tostring(row.Type or "")~="Feat"
                        or tostring(row.Class or "")~=featId then
                        return nil,nil,"Unaccounted-for feat secondary row"
                    end
                    local group=nil
                    for n,g in ipairs(groups) do
                        if tostring(row.PassiveList or "")==g.List
                            and tostring(row.SelectorId or "")==g.Selector
                            and tonumber(row.DefinitionIndex)==n-1 then
                            if group then return nil,nil,"Ambiguous repeated feat selector" end
                            group=n
                        end
                    end
                    if not group or type(row.Passives)~="table" or #row.Passives<1
                        or type(row.ReplacePassives)~="table" or next(row.ReplacePassives)~=nil then
                        return nil,nil,"Historical secondary row does not match feat definition"
                    end
                    local list=ResolvePassiveList(groups[group].List)
                    if not list then return nil,nil,"Historical feat passive list unavailable" end
                    for _,id in ipairs(row.Passives) do
                        id=tostring(id)
                        if not list.Set[id] or picks[id] then
                            return nil,nil,"Historical secondary choice is invalid or duplicated"
                        end
                        picks[id]=true
                        counts[group]=(counts[group] or 0)+1
                    end
                    rowsByGroup[group][#rowsByGroup[group]+1]=i
                    indices[#indices+1]=i
                end
            end
        end
    end
    for _,row in ipairs(history.Spells or {}) do
        if FeatOwned(row) then return nil,nil,"Unmatched historical feat spell row" end
    end
    for i,g in ipairs(groups) do
        if counts[i]~=g.Count or #rowsByGroup[i]<1 then
            return nil,nil,"Missing or incomplete saved feat group "..i
        end
    end
    return indices,picks
end
local function HBFGenericClean(rec,owned)
    if type(rec)~="table" then return false end
    for _,field in ipairs({"AddSpells","Expertise","Proficiencies"}) do
        if rec[field]~=nil and (type(rec[field])~="table" or next(rec[field])~=nil) then return false end
    end
    for _,amount in ipairs(rec.AbilityImprovements or {}) do
        if tonumber(amount)~=0 then return false end
    end
    if type(rec.AddPassives or {})~="table" then return false end
    for _,id in ipairs(rec.AddPassives or {}) do
        if not owned[tostring(id)] then return false end
    end
    return true
end
local function RemoveHBFGenericEffects(history,entries,id,level)
    if tostring(history.Feat or "")~=id then return false,"Feat history owner changed" end
    local groups=HBFGenericGroups(id)
    if not groups then return false,"Unsupported passive-only original feat" end
    local verified,reason=HBFGenericStaticContract(id,groups)
    if not verified then return false,reason end
    local indices,selected,err=HBFGenericOwnedRows(history,id,groups)
    if not indices then return false,err end
    local owner,pri,rep,pc,rc=nil,nil,nil,0,0
    local primary,mirror,normal={},{},{}
    local function Count(list,map)
        for _,entry in ipairs(list or {}) do
            entry=tostring(entry)
            if selected[entry] then map[entry]=(map[entry] or 0)+1 end
        end
    end
    for _,e in ipairs(entries) do
        if e.feat and tostring(e.feat.Feat or "")==id then
            pri=e.feat;owner=e;pc=pc+1
            if not HBFGenericClean(pri,selected) then return false,"Feat progression has other owned effects" end
            Count(pri.AddPassives,primary)
        end
        if e.replicatedFeat and tostring(e.replicatedFeat.Feat or "")==id then
            rep=e.replicatedFeat;rc=rc+1
            if not HBFGenericClean(rep,selected) then return false,"Replicated feat progression has other effects" end
            Count(rep.AddPassives,mirror)
        end
        if e.passives then Count(e.passives.AddPassives,normal) end
    end
    if pc~=1 or rc~=1 or not owner or owner.replicatedFeat~=rep
        or not owner.meta or tonumber(owner.meta.Level)~=level then
        return false,"Original feat owner/replica are not unique"
    end
    local meta=owner.meta
    if tostring(meta.SpellSourceType or "")~="ProgressionClass"
        or tostring(meta.Source or "")==""
        or tostring(meta.Progression or "")=="" then
        return false,"Original feat progression is not a verified class owner"
    end
    for _,e in ipairs(entries) do
        if e~=owner then
            for _,id in ipairs(e.passives and e.passives.AddPassives or {}) do
                if selected[tostring(id)] then
                    return false,"Feat secondary passive is also granted by unrelated progression"
                end
            end
        end
    end
    if not owner.passives or type(owner.passives.AddPassives)~="table" then
        return false,"Original feat's normal progression passive owner is missing"
    end
    local seenMirror=0
    for id in pairs(selected) do
        if primary[id]~=1 or normal[id]~=1 or (mirror[id] or 0)>1 then
            return false,"Historical choice progression mismatch: "..id
        end
        seenMirror=seenMirror+(mirror[id] or 0)
    end
    local total=0;for _ in pairs(selected) do total=total+1 end
    if seenMirror~=0 and seenMirror~=total then return false,"Partial feat mirror exists" end
    local function Filter(rows)
        local after={}
        for _,p in ipairs(rows or {}) do if not selected[tostring(p)] then after[#after+1]=p end end
        return after
    end
    pri.AddPassives=Filter(pri.AddPassives)
    rep.AddPassives=Filter(rep.AddPassives)
    for _,e in ipairs(entries) do
        if e.passives and e.passives.AddPassives then e.passives.AddPassives=Filter(e.passives.AddPassives) end
    end
    table.sort(indices,function(a,b) return a>b end)
    for _,i in ipairs(indices) do table.remove(history.Upgrades.Passives,i) end
    return true
end
local function AddHBFGenericEffects(history,entries,histories,buckets,oldId,newId,choices,level)
    if tostring(history.Feat or "")~=oldId then return false,"Original feat changed" end
    local groups=HBFGenericGroups(newId)
    if not groups then return false,"Replacement feat does not have supported passive-only selectors" end
    local matched,contractError=HBFGenericStaticContract(newId,groups)
    if not matched then return false,contractError end
    local req,why=HBFGenericReqSatisfied(newId,histories,level)
    if not req then return false,why end
    local selected,err=HBFGenericValuesValid(groups,choices)
    if not selected then return false,err end
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table" then
        return false,"Missing saved passive upgrade structure"
    end
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==oldId) then
                    return false,"Original feat still has secondary upgrades"
                end
            end
        end
    end
    local owner,pri,rep,pc,rc=nil,nil,nil,0,0
    local normalCount=0
    for _,e in ipairs(entries) do
        if e.feat and tostring(e.feat.Feat or "")==oldId then
            owner=e;pri=e.feat;pc=pc+1
            if not HBFGenericClean(pri,{}) then return false,"Old feat has unverified progression effects" end
        end
        if e.replicatedFeat and tostring(e.replicatedFeat.Feat or "")==oldId then
            rep=e.replicatedFeat;rc=rc+1
            if not HBFGenericClean(rep,{}) then return false,"Old replicated feat has effects" end
        end
        if e.passives then normalCount=normalCount+1 end
        for _,key in ipairs({"feat","replicatedFeat","passives"}) do
            for _,id in ipairs(e[key] and e[key].AddPassives or {}) do
                if selected[tostring(id)] then return false,"Passive already granted at this level" end
            end
        end
    end
    if pc~=1 or rc~=1 or normalCount>1 or not owner
        or owner.replicatedFeat~=rep then return false,"Feat progression owner is ambiguous" end
    local meta=owner.meta
    if type(meta)~="table" or tonumber(meta.Level)~=level
        or tostring(meta.SpellSourceType or "")~="ProgressionClass"
        or tostring(meta.Source or "")=="" or tostring(meta.Progression or "")=="" then
        return false,"Feat's class progression origin is not verified"
    end
    for _,e in ipairs(entries) do
        if e~=owner and e.passives then return false,"Additional class progression passive owner" end
    end
    for historicalLevel,h in ipairs(histories) do
        if historicalLevel~=level then
            for _,row in ipairs(h.Upgrades and h.Upgrades.Passives or {}) do
                for _,id in ipairs(row.Passives or {}) do
                    if selected[tostring(id)] then return false,"Passive already selected at level "..historicalLevel end
                end
            end
        end
    end
    for historicalLevel,others in pairs(buckets) do
        if tonumber(historicalLevel)~=level then
            for _,e in ipairs(others) do
                for _,key in ipairs({"feat","replicatedFeat","passives"}) do
                    for _,id in ipairs(e[key] and e[key].AddPassives or {}) do
                        if selected[tostring(id)] then return false,"Passive granted at another level" end
                    end
                end
            end
        end
    end
    local normal=owner.passives or {AddPassives={},RemovePassives={}}
    if type(normal.AddPassives)~="table" or
        (normal.RemovePassives~=nil and (type(normal.RemovePassives)~="table"
        or next(normal.RemovePassives)~=nil)) then return false,"Normal passive progression has unexpected shape" end
    pri.AddPassives={};rep.AddPassives={}
    for index,g in ipairs(groups) do
        local ids=choices[index]
        for _,id in ipairs(ids) do
            pri.AddPassives[#pri.AddPassives+1]=id
            normal.AddPassives[#normal.AddPassives+1]=id
        end
        upgrades.Passives[#upgrades.Passives+1]={Type="Feat",Class=newId,
            SelectorId=g.Selector,PassiveList=g.List,Passives=ids,
            ReplacePassives={},DefinitionIndex=index-1,Level=level,
            Multiclass=false,Subclass=history.Class,field_80=-1}
    end
    owner.passives=normal
    return true
end

local HB_ACCORD_FEAT_ID="cdcbc538-883b-401c-a8ed-1373fb6d1720"
local HB_ACCORD_SELECTOR_LIST="ffad33d2-e725-4655-ba80-0bc91e8002b3"
local HB_ACCORD_GRANT_LIST="d136c5d9-0ff0-43da-acce-a74a07f8d6bf"
local function PatchVerifiedAccordCantrip(history,levelEntries,record,from,to,level,slot)
    if tostring(history.Feat or "")~=HB_ACCORD_FEAT_ID
        or tostring(record.Type or "")~="Feat"
        or tostring(record.Class or "")~=HB_ACCORD_FEAT_ID
        or tostring(record.SelectorId or "")~="Cantrips"
        or tostring(record.SpellList or "")~=HB_ACCORD_SELECTOR_LIST
        or tonumber(record.DefinitionIndex)~=0
        or type(record.Spells)~="table" or #record.Spells~=2
        or tonumber(slot)<1 or tonumber(slot)>2
        or tostring(record.Spells[slot] or "")~=from
        or tostring(record.Spells[1])==tostring(record.Spells[2]) then
        return false,"Accord of the Arcane's original feat-owned cantrip selector differs"
    end
    if tonumber(HistoricalSpellRank(from))~=0 or tonumber(HistoricalSpellRank(to))~=0 then
        return false,"Accord replacement is not a verified cantrip"
    end
    local expected={}
    for _,id in ipairs(record.Spells) do expected[tostring(id)]=true end
    if expected[to] then return false,"Accord's other cantrip already uses that selection" end
    local owner=nil;local primaryCount,replicaCount=0,0
    for _,entry in ipairs(levelEntries) do
        if entry.feat and tostring(entry.feat.Feat or "")==HB_ACCORD_FEAT_ID then
            primaryCount=primaryCount+1
            owner=entry
        end
        if entry.replicatedFeat and
            tostring(entry.replicatedFeat.Feat or "")==HB_ACCORD_FEAT_ID then
            replicaCount=replicaCount+1
        end
    end
    if primaryCount~=1 or replicaCount~=1 or not owner
        or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=HB_ACCORD_FEAT_ID
        or not owner.meta or tonumber(owner.meta.Level)~=tonumber(level)
        or tostring(owner.meta.SpellSourceType or "")~="ProgressionClass" then
        return false,"Accord feat, replica, and owning class progression are ambiguous"
    end
    local primary=owner.feat
    if type(primary.AddSpells)~="table" or #primary.AddSpells~=2
        or type(owner.replicatedFeat.AddSpells or {})~="table"
        or #(owner.replicatedFeat.AddSpells or {})~=0
        or type(owner.spells)~="table"
        or type(owner.spells.AddSpells)~="table" or #owner.spells.AddSpells~=2 then
        return false,"Accord's original cantrip grant components do not match natural history"
    end
    local function VerifyGrants(rows)
        local found,sourceIndex={},nil
        for i,grant in ipairs(rows) do
            if type(grant)~="table" or grant.SpellId==nil
                or tostring(grant.SpellList or "")~=HB_ACCORD_GRANT_LIST then
                return nil,"Accord's granted spell list or component shape differs"
            end
            local id=tostring(grant.SpellId)
            if not expected[id] or found[id] then
                return nil,"Accord's granted cantrips are duplicated or foreign"
            end
            found[id]=true
            if id==from then sourceIndex=i end
        end
        if not sourceIndex or not found[tostring(record.Spells[3-slot])] then
            return nil,"Accord's source cantrip and retained cantrip do not match history"
        end
        return sourceIndex
    end
    local primaryIndex,why=VerifyGrants(primary.AddSpells)
    if not primaryIndex then return false,why end
    local normalIndex,reason=VerifyGrants(owner.spells.AddSpells)
    if not normalIndex then return false,reason end
    -- A same-level other class grant must not be accidentally rekeyed.
    for _,entry in ipairs(levelEntries) do
        if entry~=owner then
            for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                if tostring(grant.SpellId or "")==from
                    or tostring(grant.SpellId or "")==to then
                    return false,"Accord cantrip also appears in an unrelated progression grant"
                end
            end
        end
    end
    primary.AddSpells[primaryIndex].SpellId=to
    owner.spells.AddSpells[normalIndex].SpellId=to
    return true
end

-- Exact Accord of the Arcane records from natural BG3 historical level 4.
-- Selection SpellList and granted SpellList are different by design. Never
-- infer feat ownership from spell IDs alone or remove unrelated class spells.
local function HBAccordValidatePicks(ids)
    if type(ids)~="table" or #ids~=2 or next(ids,2)~=nil
        or type(ids[1])~="string" or type(ids[2])~="string"
        or ids[1]==ids[2] then
        return nil,"Accord requires exactly two different cantrips"
    end
    local valid={}
    for _,row in ipairs(ChoicesOptionSet("Cantrip",HB_ACCORD_SELECTOR_LIST)) do
        if HistoricalSpellRank(row.Id)==0 then valid[tostring(row.Id)]=true end
    end
    for _,id in ipairs(ids) do
        if not valid[id] then return nil,"Accord cantrip is not in the installed verified selection list: "..id end
    end
    return {[ids[1]]=true,[ids[2]]=true}
end
local function HBAccordOwner(history,levelEntries,featId,level)
    local owner,primary,replica=nil,0,0
    for _,entry in ipairs(levelEntries or {}) do
        if entry.feat and tostring(entry.feat.Feat or "")==featId then
            primary=primary+1;owner=entry
        end
        if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat or "")==featId then
            replica=replica+1
        end
    end
    if primary~=1 or replica~=1 or not owner or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=featId
        or type(owner.meta)~="table" or tonumber(owner.meta.Level)~=level
        or tostring(owner.meta.SpellSourceType or "")~="ProgressionClass"
        or tostring(owner.meta.Progression or "")==""
        or tostring(owner.meta.Source or "")=="" then
        return nil,"Accord primary, replica, or class progression owner cannot be proven"
    end
    return owner
end
local function HBAccordEmptyOtherGrants(component)
    if type(component)~="table" then return false end
    for _,key in ipairs({"AddPassives","Proficiencies","Expertise"}) do
        if component[key]~=nil and (type(component[key])~="table"
            or next(component[key])~=nil) then return false end
    end
    for _,v in ipairs(component.AbilityImprovements or {}) do
        if tonumber(v)~=0 then return false end
    end
    return true
end
local function HBAccordGrant(id)
    -- These fields are captured from actual, naturally selected Accord
    -- ProgressionFeat/ProgressionSpells records, not fabricated spell VMs.
    return {SpellId=id,SpellList=HB_ACCORD_GRANT_LIST,
        CastingAbility="None",Class="00000000-0000-0000-0000-000000000000",
        CooldownType="Default",PrepareType="AlwaysPrepared"}
end
local function HBAccordGrantMatches(row,id)
    return type(row)=="table" and tostring(row.SpellId or "")==id
        and tostring(row.SpellList or "")==HB_ACCORD_GRANT_LIST
        and tostring(row.CastingAbility or "") == "None"
        and tostring(row.Class or "") == "00000000-0000-0000-0000-000000000000"
        and tostring(row.CooldownType or "") == "Default"
        and tostring(row.PrepareType or "") == "AlwaysPrepared"
end
local function HBAccordVerifyGrants(rows,picks)
    if type(rows)~="table" or #rows~=2 then return false end
    local seen={}
    for _,grant in ipairs(rows) do
        if type(grant)~="table" then return false end
        local id=tostring(grant.SpellId or "")
        if not picks[id] or seen[id] or not HBAccordGrantMatches(grant,id) then
            return false
        end
        seen[id]=true
    end
    return true
end
local function RemoveRecordedAccordEffects(history,levelEntries,oldFeatId,level)
    if oldFeatId~=HB_ACCORD_FEAT_ID or history.Feat~=HB_ACCORD_FEAT_ID
        or type(history.Upgrades)~="table" or type(history.Upgrades.Spells)~="table" then
        return false,"Accord history is not available for a verified removal"
    end
    local upgrade=history.Upgrades
    local accordRow,accordIndex=nil,nil
    for family,rows in pairs(upgrade) do
        if type(rows)=="table" then
            for index,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==HB_ACCORD_FEAT_ID) then
                    if family~="Spells" or accordRow
                        or row.Type~="Feat" or row.Class~=HB_ACCORD_FEAT_ID
                        or row.SelectorId~="Cantrips"
                        or row.SpellList~=HB_ACCORD_SELECTOR_LIST
                        or tonumber(row.DefinitionIndex)~=0
                        or type(row.ReplaceSpells)~="table" or #row.ReplaceSpells~=0 then
                        return false,"Accord has additional or malformed feat-owned selections"
                    end
                    accordRow=row;accordIndex=index
                end
            end
        end
    end
    if not accordRow then return false,"Missing original Accord cantrip selection" end
    local picks,why=HBAccordValidatePicks(accordRow.Spells)
    if not picks then return false,why end
    local owner,error=HBAccordOwner(history,levelEntries,oldFeatId,level)
    if not owner then return false,error end
    local primary,replica=owner.feat,owner.replicatedFeat
    if not HBAccordEmptyOtherGrants(primary) or not HBAccordEmptyOtherGrants(replica)
        or type(replica.AddSpells or {})~="table" or #(replica.AddSpells or {})~=0
        or not HBAccordVerifyGrants(primary.AddSpells,picks)
        or type(owner.spells)~="table"
        or not HBAccordVerifyGrants(owner.spells.AddSpells,picks)
        or type(owner.spells.RemoveSpells or {})~="table"
        or #(owner.spells.RemoveSpells or {})~=0 then
        return false,"Accord feat and natural spell progression grants differ"
    end
    for _,entry in ipairs(levelEntries) do
        if entry~=owner then
            for _,component in ipairs({"feat","replicatedFeat","spells"}) do
                for _,grant in ipairs(entry[component] and entry[component].AddSpells or {}) do
                    if picks[tostring(grant.SpellId or "")] then
                        return false,"Accord cantrip also belongs to a foreign same-level progression"
                    end
                end
            end
        end
    end
    -- Only after complete provenance verification may the copied snapshot
    -- be modified. Preserve all unrelated class/subclass grants and maneuvers.
    table.remove(upgrade.Spells,accordIndex)
    primary.AddSpells={}
    owner.spells.AddSpells={}
    return true
end
local function AddRecordedAccordEffects(history,levelEntries,histories,buckets,
    sourceFeatId,ids,level)
    if tostring(history.Feat or "")~=sourceFeatId then
        return false,"Accord source feat history changed"
    end
    local picks,why=HBAccordValidatePicks(ids)
    if not picks then return false,why end
    if type(history.Upgrades)~="table" or type(history.Upgrades.Spells)~="table" then
        return false,"Historical spell upgrade array missing"
    end
    for _,rows in pairs(history.Upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and tostring(row.Type or "")=="Feat" then
                    return false,"Simple source feat contains a secondary feat upgrade"
                end
            end
        end
    end
    -- A different same-level historical spell selection must not already
    -- own either of the new Accord cantrips.
    for _,row in ipairs(history.Upgrades.Spells) do
        if type(row)=="table" then
            for _,id in ipairs(row.Spells or {}) do
                if picks[tostring(id)] then
                    return false,"Accord choice already belongs to a same-level spell selection"
                end
            end
        end
    end
    for i,h in ipairs(histories or {}) do
        if i~=level then
            if tostring(h.Feat or "")==HB_ACCORD_FEAT_ID then
                return false,"Accord already selected at character level "..i
            end
            for _,row in ipairs(h.Upgrades and h.Upgrades.Spells or {}) do
                for _,id in ipairs(row.Spells or {}) do
                    if picks[tostring(id)] then
                        return false,"Accord choice already selected at another level"
                    end
                end
            end
        end
    end
    for bucketLevel,entries in pairs(buckets or {}) do
        for _,entry in ipairs(entries) do
            for _,name in ipairs({"feat","replicatedFeat","spells"}) do
                for _,grant in ipairs(entry[name] and entry[name].AddSpells or {}) do
                    if picks[tostring(grant.SpellId or "")] then
                        return false,"Accord choice already granted by another progression"
                    end
                end
            end
        end
    end
    local owner,error=HBAccordOwner(history,levelEntries,sourceFeatId,level)
    if not owner then return false,error end
    local primary,replica=owner.feat,owner.replicatedFeat
    if not HBAccordEmptyOtherGrants(primary) or not HBAccordEmptyOtherGrants(replica)
        or type(primary.AddSpells or {})~="table" or #(primary.AddSpells or {})~=0
        or type(replica.AddSpells or {})~="table" or #(replica.AddSpells or {})~=0 then
        return false,"Simple source feat has unrelated effects"
    end
    local normal=owner.spells
    if normal and (type(normal)~="table" or type(normal.AddSpells)~="table"
        or type(normal.RemoveSpells or {})~="table"
        or #(normal.RemoveSpells or {})~=0) then
        return false,"Original class spell progression shape is unsupported"
    end
    normal=normal or {AddSpells={},RemoveSpells={}}
    -- The verified natural Accord package has exactly the two feat-owned
    -- normal spell grants on its owning progression. If this source already
    -- owns other spells, their provenance cannot be distinguished during
    -- later removal. Reject rather than build an add-only package.
    if type(normal.AddSpells)~="table" or #normal.AddSpells~=0 then
        return false,"Source progression already owns unrelated spells"
    end
    owner.spells=normal
    for _,id in ipairs(ids) do
        local grant=HBAccordGrant(id)
        primary.AddSpells[#primary.AddSpells+1]=grant
        normal.AddSpells[#normal.AddSpells+1]=HBAccordGrant(id)
    end
    history.Upgrades.Spells[#history.Upgrades.Spells+1]={
        Type="Feat",Class=HB_ACCORD_FEAT_ID,SelectorId="Cantrips",
        SpellList=HB_ACCORD_SELECTOR_LIST,Spells={ids[1],ids[2]},
        ReplaceSpells={},DefinitionIndex=0,Level=level,Multiclass=false,
        Subclass=history.Class
    }
    return true
end

-- A naturally selected Multifaceted feat owns four recorded skill slots.
-- Unlike a normal class skill, each recorded choice is also serialized in
-- the matching ProgressionFeat proficiency grant. The original generic
-- skill editor patched only ProgressionSkills, leaving the feat component
-- inconsistent after replay. This strict adapter handles EXISTING four-skill
-- packages; adding/removing Multifaceted, its archetype and trait selections
-- require independently verified provenance and remain protected.
local HB_MULTIFACETED_FEAT_ID="be0889d2-f9aa-472d-b942-592bff0f1ef3"
local function PatchVerifiedMultifacetedSkill(history,levelEntries,allHistories,
    allBuckets,row,from,to,level,slot)
    if tostring(history.Feat or "")~=HB_MULTIFACETED_FEAT_ID
        or type(row)~="table" or tostring(row.Type or "")~="Feat"
        or tostring(row.Class or "")~=HB_MULTIFACETED_FEAT_ID
        or type(row.Proficiencies)~="table"
        or tostring(row.Proficiencies[slot] or "")~=from
        or tostring(row.Skill or "")~=HB_MULTIFACETED_SKILL_LIST then
        return false,"Multifaceted's recorded skill selector is not verifiably feat-owned"
    end
    local upgrades=history.Upgrades or {}
    local selected,count,found={},0,false
    for _,choice in ipairs(upgrades.Skills or {}) do
        if type(choice)=="table" and (tostring(choice.Type or "")=="Feat"
            or tostring(choice.Class or "")==HB_MULTIFACETED_FEAT_ID) then
            if tostring(choice.Type or "")~="Feat"
                or tostring(choice.Class or "")~=HB_MULTIFACETED_FEAT_ID
                or type(choice.Proficiencies)~="table"
                or tostring(choice.Skill or "")~=HB_MULTIFACETED_SKILL_LIST then
                return false,"Multifaceted's four recorded skills have mixed ownership"
            end
            for _,id in ipairs(choice.Proficiencies) do
                id=tostring(id)
                if selected[id] or id=="" then
                    return false,"Multifaceted has duplicated or missing recorded skills"
                end
                selected[id]=true
                count=count+1
            end
            if choice==row then found=true end
        end
    end
    if not found or count~=4 or not selected[from] or selected[to] then
        return false,"Multifaceted requires four distinct feat-owned skill choices"
    end
    -- No other progression family can grant the source or target. If it
    -- does, changing map-like live skills could remove a legitimate grant.
    for oldLevel,otherHistory in ipairs(allHistories or {}) do
        if oldLevel~=level then
            for _,choice in ipairs(otherHistory.Upgrades and otherHistory.Upgrades.Skills or {}) do
                for _,id in ipairs(choice.Proficiencies or {}) do
                    if tostring(id)==to then
                        return false,"Multifaceted target skill already recorded at another level"
                    end
                end
            end
        end
    end
    for bucketLevel,otherEntries in pairs(allBuckets or {}) do
        if tonumber(bucketLevel)~=level then
            for _,entry in ipairs(otherEntries or {}) do
                for _,id in ipairs(entry.skills and entry.skills.Proficiencies or {}) do
                    if tostring(id)==to then
                        return false,"Multifaceted target already granted by another progression"
                    end
                end
            end
        end
    end
    local owner,primaryCount,replicaCount=nil,0,0
    for _,entry in ipairs(levelEntries) do
        if entry.feat and tostring(entry.feat.Feat or "")==HB_MULTIFACETED_FEAT_ID then
            primaryCount=primaryCount+1;owner=entry
        end
        if entry.replicatedFeat and
            tostring(entry.replicatedFeat.Feat or "")==HB_MULTIFACETED_FEAT_ID then
            replicaCount=replicaCount+1
        end
    end
    if primaryCount~=1 or replicaCount~=1 or owner==nil or not owner.meta
        or tonumber(owner.meta.Level)~=level or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=HB_MULTIFACETED_FEAT_ID then
        return false,"Multifaceted's primary and replicated feat ownership is ambiguous"
    end
    -- Compare all four exact currently recorded skills, not membership
    -- using transient Lua proxy values. The original selected map above is
    -- built from CCLevelUp and remains authoritative on EVERY edit in a
    -- multi-skill batch. Nothing is allowed to vanish or gain a fifth grant.
    local function MatchSelections(list,allowEmpty)
        if type(list)~="table" then return false end
        if allowEmpty and #list==0 then return true end
        if #list~=4 then return false end
        local found={}
        for _,raw in ipairs(list) do
            local id=tostring(raw or "")
            if id=="" or not selected[id] or found[id] or id==to then return false end
            found[id]=true
        end
        for id in pairs(selected) do if not found[id] then return false end end
        return true
    end
    local matchedFeat=MatchSelections(owner.feat.Proficiencies,false)
    local matchedProgression=owner.skills
        and MatchSelections(owner.skills.Proficiencies,false) or false
    if not matchedFeat or not matchedProgression then
        local function DescribeSkillIds(values)
            if type(values)~="table" then return "type="..type(values) end
            local parts={}
            for k,id in ipairs(values) do
                if k>8 then break end
                parts[#parts+1]=tostring(id)
            end
            return table.concat(parts,",")
        end
        RespecStartLog("HISTORICAL_MULTIFACETED_SKILL_MIRROR_REJECT level="..level
            .." slot="..slot.." from="..from.." to="..to
            .." featMatch="..tostring(matchedFeat)
            .." progressionMatch="..tostring(matchedProgression)
            .." historical="..DescribeSkillIds(row.Proficiencies)
            .." primary="..DescribeSkillIds(owner.feat.Proficiencies)
            .." progression="..DescribeSkillIds(owner.skills and owner.skills.Proficiencies)
            .." selectedCount="..count
            .." featCount="..tostring(#(owner.feat.Proficiencies or {}))
            .." progressionCount="..tostring(owner.skills and #(owner.skills.Proficiencies or {})))
        return false,"Multifaceted's recorded feat and progression skill grants disagree; inspect HB_RespecStart_Diagnostics.txt"
    end
    local replicated=owner.replicatedFeat.Proficiencies or {}
    if not MatchSelections(replicated,true) then
        return false,"Multifaceted's replicated skill grants are incomplete or inconsistent"
    end
    for _,entry in ipairs(levelEntries) do
        if entry~=owner then
            for _,family in ipairs({"feat","replicatedFeat","skills"}) do
                local grants=entry[family] and entry[family].Proficiencies or {}
                for _,id in ipairs(grants) do
                    if tostring(id)==from or tostring(id)==to then
                        return false,"Multifaceted skill also appears in another same-level progression"
                    end
                end
            end
        end
    end
    local function Rewrite(list)
        local changed=0
        for index,id in ipairs(list or {}) do
            if id==from then list[index]=to;changed=changed+1 end
        end
        return changed
    end
    if Rewrite(owner.feat.Proficiencies)~=1
        or Rewrite(owner.skills.Proficiencies)~=1 then
        return false,"Multifaceted skill mutation did not match the verified grant"
    end
    if #replicated==4 and Rewrite(replicated)~=1 then
        return false,"Multifaceted replica did not match the edited skill"
    end
    return true
end


-- First complete non-passive-only HB feat dismantling pilot. This accepts
-- ONLY the naturally recorded Multifaceted package (archetype, trait and
-- four skills), verified across CCLevelUp, ProgressionFeat and the matching
-- normal passive/skill components. The original historical snapshot is never
-- mutated: ValidateAndPatchOtherChoices passes a deep copy. New Multifaceted
-- creation is intentionally NOT enabled; it needs separately verified row
-- construction, grant ownership and eligibility at the original feat level.
-- Definition-driven feat-owned spell selection replay. Reuses the Accord
-- snapshot pattern (CCLevelUp + ProgressionFeat + ProgressionSpells) but
-- validates every installed list and exact historical owner first.
-- This never fabricates native selector ViewModels or touches live ECS data.
local function HBFSpellGroups(id)
    if id==HB_ACCORD_FEAT_ID then return nil end
    return HB_GENERIC_FEATS.SpellSelectors(id)
end
HB_GENERIC_SPELL_READER=Ext.Require("Shared/HB_GenericSpellCandidateReader.lua")
local function HBFSpellAllowed(group,id)
    -- A feat-created native spell option must be accepted by the identical
    -- source-owned list/rank resolver at server commit time. Do not use the
    -- ordinary historical/Accord list decoder, which can return partial C++
    -- collections even when this exact feat's selector is valid.
    return HB_GENERIC_SPELL_READER.Contains(group.List,group.Cantrip,id)
end
local function HBFSpellSelectionSet(groups,values)
    if type(values)~="table" then return nil,"Missing spell selections for the feat" end
    for key in pairs(values) do
        if type(key)~="number" or key~=math.floor(key) or key<1 or key>#groups then
            return nil,"Unrecognized feat spell selector group"
        end
    end
    local chosen={}
    for index,group in ipairs(groups) do
        local ids=values[index]
        if type(ids)~="table" or #ids~=group.Count then
            return nil,"Spell group "..index.." requires "..group.Count.." choices"
        end
        local count=0
        for key in pairs(ids) do
            if type(key)~="number" or key~=math.floor(key)
                or key<1 or key>group.Count then
                return nil,"Spell group has sparse or malformed choices"
            end
            count=count+1
        end
        if count~=group.Count then return nil,"Spell group is incomplete" end
        for _,spell in ipairs(ids) do
            if type(spell)~="string" or chosen[spell] or not HBFSpellAllowed(group,spell) then
                return nil,"Invalid, duplicated, or unlisted spell: "..tostring(spell)
            end
            chosen[spell]=true
        end
    end
    return chosen
end
local function HBFSpellOwnedRows(history,featId,groups)
    if type(history.Upgrades)~="table" or type(history.Upgrades.Spells)~="table" then
        return nil,nil,"Missing saved spell-selector upgrades"
    end
    local matches,chosen={},{}
    local byGroup={}
    for i=1,#groups do byGroup[i]={} end
    for family,rows in pairs(history.Upgrades) do
        if type(rows)=="table" then
            for index,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==featId) then
                    if family~="Spells" or tostring(row.Type or "")~="Feat"
                        or tostring(row.Class or "")~=featId then
                        return nil,nil,"Original feat has unrelated secondary upgrades"
                    end
                    local match=nil
                    for n,g in ipairs(groups) do
                        if tostring(row.SpellList or "")==g.List
                            and tostring(row.SelectorId or "")==g.Selector
                            and tonumber(row.DefinitionIndex)==g.Index-1 then
                            if match then return nil,nil,"Ambiguous source spell selector" end
                            match=n
                        end
                    end
                    if not match or type(row.Spells)~="table"
                        or type(row.ReplaceSpells)~="table" or #row.ReplaceSpells~=0 then
                        return nil,nil,"Original feat-owned spell row differs from the definition"
                    end
                    byGroup[match][#byGroup[match]+1]=index
                    matches[#matches+1]=index
                    for _,id in ipairs(row.Spells) do
                        id=tostring(id)
                        if chosen[id] or not HBFSpellAllowed(groups[match],id) then
                            return nil,nil,"Original feat spell is not a valid unique choice"
                        end
                        chosen[id]=true
                    end
                end
            end
        end
    end
    local seen={}
    for groupIndex,g in ipairs(groups) do
        local n=0
        for _,index in ipairs(byGroup[groupIndex]) do
            n=n+#(history.Upgrades.Spells[index].Spells or {})
        end
        if n~=g.Count or #byGroup[groupIndex]<1 then
            return nil,nil,"Original spell selector group missing choices: "..groupIndex
        end
    end
    return matches,chosen
end
local function HBFSpellOwner(entries,featId,level)
    local owner,p,r=nil,0,0
    for _,entry in ipairs(entries) do
        if entry.feat and tostring(entry.feat.Feat or "")==featId then
            owner=entry;p=p+1
        end
        if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat or "")==featId then r=r+1 end
    end
    if p~=1 or r~=1 or not owner or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=featId
        or type(owner.meta)~="table" or tonumber(owner.meta.Level)~=level
        or tostring(owner.meta.SpellSourceType or "")~="ProgressionClass"
        or tostring(owner.meta.Progression or "")==""
        or tostring(owner.meta.Source or "")=="" then
        return nil,"Feat's class progression owner cannot be uniquely verified"
    end
    return owner
end
local function HBFSpellNoOtherEffects(component)
    if type(component)~="table" then return false end
    for _,field in ipairs({"AddPassives","Proficiencies","Expertise"}) do
        if component[field]~=nil and (type(component[field])~="table"
            or next(component[field])~=nil) then return false end
    end
    for _,value in ipairs(component.AbilityImprovements or {}) do
        if tonumber(value)~=0 then return false end
    end
    -- BG3's replicated ProgressionFeat is often deliberately sparse:
    -- {Feat, field_10, field_14}, with no AddSpells member at all.
    -- Absence is an empty grant set; a malformed/non-table field is not.
    -- The primary feat component is still separately required to have an
    -- empty spell set before we append or remove feat-owned grants.
    return component.AddSpells==nil or type(component.AddSpells)=="table"
end
local function HBFSpellGrant(group,id)
    local list=group.GrantList~="" and group.GrantList or group.List
    return {SpellId=id,SpellList=list,
        CastingAbility=(group.CastingAbility~="" and group.CastingAbility or "None"),
        Class="00000000-0000-0000-0000-000000000000",
        CooldownType="Default",
        PrepareType=(group.PrepareType~="" and group.PrepareType or "AlwaysPrepared")}
end
local function HBFSpellGrantShapeEqual(left,right)
    if type(left)~="table" or type(right)~="table" then return false end
    for _,field in ipairs({"SpellId","SpellList","CastingAbility","Class", "CooldownType","PrepareType"}) do
        if tostring(left[field] or "")~=tostring(right[field] or "") then return false end
    end
    return true
end
local function RemoveHBFSpellEffects(history,entries,featId,level)
    if tostring(history.Feat or "")~=featId then return false,"Original feat changed" end
    local groups=HBFSpellGroups(featId)
    if not groups then return false,"Original feat does not have spell-only selectors" end
    local matched,err=HBFGenericStaticContract(featId,groups)
    if not matched then return false,err end
    local rowIndices,picked,why=HBFSpellOwnedRows(history,featId,groups)
    if not rowIndices then return false,why end
    local owner,ownership=HBFSpellOwner(entries,featId,level)
    if not owner then return false,ownership end
    if not HBFSpellNoOtherEffects(owner.feat)
        or not HBFSpellNoOtherEffects(owner.replicatedFeat)
        or type(owner.spells)~="table" or type(owner.spells.AddSpells)~="table"
        or type(owner.spells.RemoveSpells or {})~="table"
        or #(owner.spells.RemoveSpells or {})~=0
        or #(owner.replicatedFeat.AddSpells or {})~=0 then
        return false,"Original feat includes unverified nonspell progression effects"
    end
    local grants={}
    for _,entry in ipairs(owner.feat.AddSpells or {}) do
        local id=tostring(entry.SpellId or "")
        if not picked[id] or grants[id] then
            return false,"Feat's primary spell grants differ from saved secondary spells"
        end
        grants[id]=entry
    end
    local amount=0
    for id in pairs(picked) do
        if not grants[id] then return false,"Original spell has no feat-owned grant" end
        amount=amount+1
    end
    if amount~=#owner.feat.AddSpells then return false,"Unexpected spell grant count" end
    local normalMatches={}
    for _,grant in ipairs(owner.spells.AddSpells) do
        local id=tostring(grant.SpellId or "")
        if picked[id] then
            if normalMatches[id] or not HBFSpellGrantShapeEqual(grant,grants[id]) then
                return false,"Normal progression spell grant differs from the original feat"
            end
            normalMatches[id]=true
        end
    end
    for id in pairs(picked) do
        if not normalMatches[id] then return false,"Original feat spell is missing its normal progression owner" end
    end
    for _,entry in ipairs(entries) do
        if entry~=owner then
            for _,field in ipairs({"feat","replicatedFeat","spells"}) do
                for _,grant in ipairs(entry[field] and entry[field].AddSpells or {}) do
                    if picked[tostring(grant.SpellId or "")] then
                        return false,"Original feat spell is also granted by a foreign progression"
                    end
                end
            end
        end
    end
    local kept={}
    for _,grant in ipairs(owner.spells.AddSpells) do
        if not picked[tostring(grant.SpellId or "")] then kept[#kept+1]=grant end
    end
    owner.spells.AddSpells=kept
    owner.feat.AddSpells={}
    table.sort(rowIndices,function(a,b) return a>b end)
    for _,index in ipairs(rowIndices) do table.remove(history.Upgrades.Spells,index) end
    return true
end
local function AddHBFSpellEffects(history,entries,histories,buckets,oldId,newId,values,level)
    if tostring(history.Feat or "")~=oldId then return false,"Spell source feat changed" end
    local groups=HBFSpellGroups(newId)
    if not groups then return false,"Replacement has no supported spell-only selectors" end
    local contract,contractError=HBFGenericStaticContract(newId,groups)
    if not contract then return false,contractError end
    local requirement,requirementError=HBFGenericReqSatisfied(newId,histories,level)
    if not requirement then return false,requirementError end
    local picks,why=HBFSpellSelectionSet(groups,values)
    if not picks then return false,why end
    if type(history.Upgrades)~="table" or type(history.Upgrades.Spells)~="table" then
        return false,"Missing saved spell-upgrade array"
    end
    for _,rows in pairs(history.Upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==oldId) then
                    return false,"Original feat still has owned secondary selections"
                end
            end
        end
    end
    for recordedLevel,old in ipairs(histories or {}) do
        if recordedLevel~=level then
            for _,row in ipairs(old.Upgrades and old.Upgrades.Spells or {}) do
                for _,id in ipairs(row.Spells or {}) do
                    if picks[tostring(id)] then return false,"Spell already chosen at another level" end
                end
            end
        end
    end
    for _,oldEntries in pairs(buckets or {}) do
        for _,entry in ipairs(oldEntries) do
            for _,field in ipairs({"feat","replicatedFeat","spells"}) do
                for _,grant in ipairs(entry[field] and entry[field].AddSpells or {}) do
                    if picks[tostring(grant.SpellId or "")] then
                        return false,"Feat spell already belongs to another progression"
                    end
                end
            end
        end
    end
    local owner,ownership=HBFSpellOwner(entries,oldId,level)
    if not owner then return false,ownership end
    if not HBFSpellNoOtherEffects(owner.feat)
        or not HBFSpellNoOtherEffects(owner.replicatedFeat)
        or #(owner.feat.AddSpells or {})~=0
        or #(owner.replicatedFeat.AddSpells or {})~=0 then
        return false,"Source feat's progression is not an empty verified spell owner"
    end
    local normal=owner.spells or {AddSpells={},RemoveSpells={}}
    if type(normal.AddSpells)~="table" or type(normal.RemoveSpells or {})~="table"
        or #(normal.RemoveSpells or {})~=0 or #normal.AddSpells~=0 then
        return false,"Original class progression spells are not empty"
    end
    -- Different progressions at the same level may legitimately grant
    -- spells. We checked *every selected ID* against all feat, replicated,
    -- and normal progression grants in `buckets` above. Preserve any
    -- unrelated class/subclass spell owner without modifying its records.
    owner.spells=normal
    owner.feat.AddSpells=owner.feat.AddSpells or {}
    for index,g in ipairs(groups) do
        for _,id in ipairs(values[index]) do
            local grant=HBFSpellGrant(g,id)
            owner.feat.AddSpells[#owner.feat.AddSpells+1]=grant
            owner.spells.AddSpells[#owner.spells.AddSpells+1]=HBFSpellGrant(g,id)
        end
        history.Upgrades.Spells[#history.Upgrades.Spells+1]={
            Type="Feat",Class=newId,SelectorId=g.Selector,
            SpellList=g.List,Spells=values[index],ReplaceSpells={},
            DefinitionIndex=g.Index-1,Level=level,Multiclass=false,
            Subclass=history.Class}
    end
    return true
end

-- AddSpells is a fixed feat package, not a selection. Construct/remove the
-- recorded ProgressionFeat and matching ProgressionSpells payload atomically
-- on the copied snapshot. Unowned class/subclass spell grants are untouched.
local function HBFAutoLists(id)
    return HB_GENERIC_FEATS.AutoSpellLists(id)
end
local function HBFAutoIds(lists)
    local result,seen={},{}
    if type(lists)~="table" or #lists<1 then return nil,"Feat has no automatic spell lists" end
    for _,list in ipairs(lists) do
        local spells=RecordedListOptions(list,"SpellList","Spells")
        if #spells==0 then spells=HB_SPELL_LIST_CATALOG[tostring(list)] or {} end
        if #spells==0 then return nil,"Automatic spell list not available: "..tostring(list) end
        for _,raw in ipairs(spells) do
            local id=tostring(raw or "")
            local ok,stat=pcall(Ext.Stats.Get,id)
            if not ok or not stat or id=="" or seen[id] then
                return nil,"Automatic spell list contains unavailable or duplicate spell: "..id
            end
            seen[id]=list
            result[#result+1]={Id=id,List=list}
        end
    end
    return result,seen
end
local function HBFNoAutomaticRows(history,featId)
    for _,rows in pairs(history.Upgrades or {}) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==featId) then
                    return false
                end
            end
        end
    end
    return true
end
local function RemoveHBFAutomaticSpells(history,entries,featId,level)
    if tostring(history.Feat or "")~=featId then return false,"Automatic source feat changed" end
    local lists=HBFAutoLists(featId)
    if not lists then return false,"Original feat is not an automatic-spell package" end
    local valid,why=HBFGenericStaticContract(featId,lists)
    if not valid then return false,why end
    local granted,ids=HBFAutoIds(lists)
    if not granted then return false,ids end
    if not HBFNoAutomaticRows(history,featId) then
        return false,"Automatic feat unexpectedly owns editable CCLevelUp rows"
    end
    local owner,reason=HBFSpellOwner(entries,featId,level)
    if not owner then return false,reason end
    if not HBFSpellNoOtherEffects(owner.feat)
        or not HBFSpellNoOtherEffects(owner.replicatedFeat)
        or #(owner.replicatedFeat.AddSpells or {})~=0
        or type(owner.spells)~="table" or type(owner.spells.AddSpells)~="table"
        or #(owner.spells.RemoveSpells or {})~=0 then
        return false,"Automatic spell package contains unrelated progression effects"
    end
    local primary,normal={},{}
    for _,grant in ipairs(owner.feat.AddSpells or {}) do
        local id=tostring(grant.SpellId or "")
        if not ids[id] or primary[id] then
            return false,"Feat automatic spell grants differ from the definition"
        end
        primary[id]=grant
    end
    for _,grant in ipairs(owner.spells.AddSpells) do
        local id=tostring(grant.SpellId or "")
        if primary[id] then
            if normal[id] or not HBFSpellGrantShapeEqual(primary[id],grant) then
                return false,"Automatic spell's normal progression grant differs"
            end
            normal[id]=grant
        end
    end
    for id in pairs(primary) do
        if not normal[id] then return false,"Automatic feat spell provenance is incomplete: "..id end
    end
    -- Existing class/subclass/other-feat grants must remain untouched. The
    -- feat may have deliberately skipped a spell already granted elsewhere.
    local remaining={}
    for _,grant in ipairs(owner.spells.AddSpells) do
        if not primary[tostring(grant.SpellId or "")] then remaining[#remaining+1]=grant end
    end
    owner.spells.AddSpells=remaining
    owner.feat.AddSpells={}
    RespecStartLog("HISTORICAL_AUTO_SPELL_REMOVE level="..level
        .." feat="..featId.." ownedCount="..tostring((function() local n=0 for _ in pairs(primary) do n=n+1 end return n end)()))
    return true
end

local function AddHBFAutomaticSpells(history,entries,histories,buckets,from,to,level)
    if tostring(history.Feat or "")~=from then return false,"Automatic feat source changed" end
    local lists=HBFAutoLists(to)
    if not lists then return false,"Target feat has no automatic spell package" end
    local verified,why=HBFGenericStaticContract(to,lists)
    if not verified then return false,why end
    local eligible,eligibility=HBFGenericReqSatisfied(to,histories,level)
    if not eligible then return false,eligibility end
    local desired,ids=HBFAutoIds(lists)
    if not desired then return false,ids end
    if not HBFNoAutomaticRows(history,from) then
        return false,"Old feat still has secondary choice upgrades"
    end
    local owner,reason=HBFSpellOwner(entries,from,level)
    if not owner then return false,reason end
    if not HBFSpellNoOtherEffects(owner.feat)
        or not HBFSpellNoOtherEffects(owner.replicatedFeat)
        or #(owner.feat.AddSpells or {})~=0
        or #(owner.replicatedFeat.AddSpells or {})~=0 then
        return false,"Old feat has unverified spell effects"
    end
    local normal=owner.spells or {AddSpells={},RemoveSpells={}}
    if type(normal.AddSpells)~="table" or type(normal.RemoveSpells or {})~="table"
        or #(normal.RemoveSpells or {})~=0 then
        return false,"Original class progression spells cannot be verified"
    end
    -- A cleric already knows Turn Undead through their class. A Life Domain
    -- feat should neither reject that character nor re-grant/remove Turn
    -- Undead as if the feat owned it. Preserve other owners and add only the
    -- missing, feat-owned spells. This also supports same-level class grants.
    local external={}
    for _,otherHistory in ipairs(histories or {}) do
        for _,row in ipairs(otherHistory.Upgrades and otherHistory.Upgrades.Spells or {}) do
            for _,id in ipairs(row.Spells or {}) do
                if ids[tostring(id)] then external[tostring(id)]=true end
            end
        end
    end
    for _,bucket in pairs(buckets or {}) do
        for _,entry in ipairs(bucket) do
            for _,field in ipairs({"feat","replicatedFeat","spells"}) do
                for _,spell in ipairs(entry[field] and entry[field].AddSpells or {}) do
                    local id=tostring(spell.SpellId or "")
                    if ids[id] then external[id]=true end
                end
            end
        end
    end
    owner.spells=normal
    owner.feat.AddSpells=owner.feat.AddSpells or {}
    local added,shared={},{}
    for _,spell in ipairs(desired) do
        if external[spell.Id] then
            shared[#shared+1]=spell.Id
        else
            local group={List=spell.List,GrantList="",CastingAbility="",
                PrepareType="AlwaysPrepared"}
            owner.feat.AddSpells[#owner.feat.AddSpells+1]=HBFSpellGrant(group,spell.Id)
            owner.spells.AddSpells[#owner.spells.AddSpells+1]=HBFSpellGrant(group,spell.Id)
            added[#added+1]=spell.Id
        end
    end
    RespecStartLog("HISTORICAL_AUTO_SPELL_ADD level="..level.." feat="..to
        .." newlyOwned="..table.concat(added,",")
        .." retainedExternal="..table.concat(shared,","))
    return true
end

local function RemoveRecordedMultifacetedEffects(history,levelEntries,oldFeatId,level)
    if tostring(oldFeatId)~=HB_MULTIFACETED_FEAT_ID
        or tostring(history.Feat or "")~=oldFeatId then
        return false,"Multifaceted historical feat identity differs"
    end
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table"
        or type(upgrades.Skills)~="table" then
        return false,"Multifaceted secondary history is incomplete"
    end
    local archetypeList="4607f9c7-335c-443f-b075-a3f068c20a0d"
    local traitList="15eff335-46df-4268-9eea-aabcb6c13025"
    local owned,passiveRows,skillRow={}, {}, nil
    local function IsFeatOwned(row)
        return type(row)=="table" and (tostring(row.Type or "")=="Feat"
            or tostring(row.Class or "")==oldFeatId)
    end
    for family,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if IsFeatOwned(row) then
                    if family=="Passives" then
                        local selector=tostring(row.SelectorId or "")
                        local list=tostring(row.PassiveList or "")
                        local kind=(selector=="Archetypes" and list==archetypeList
                            and tonumber(row.DefinitionIndex)==0) and "archetype"
                            or ((selector=="Traits" and list==traitList
                                and tonumber(row.DefinitionIndex)==1) and "trait" or nil)
                        local ids=row.Passives
                        if not kind or passiveRows[kind]
                            or tostring(row.Type or "")~="Feat"
                            or tostring(row.Class or "")~=oldFeatId
                            or type(ids)~="table" or #ids~=1
                            or type(row.ReplacePassives)~="table"
                            or #row.ReplacePassives~=0 then
                            return false,"Multifaceted has extra or malformed feat passive choices"
                        end
                        local id=tostring(ids[1] or "")
                        if id=="" or owned[id] then
                            return false,"Multifaceted archetype/trait choices are duplicated"
                        end
                        owned[id]=true
                        passiveRows[kind]=row
                    elseif family=="Skills" then
                        if skillRow or tostring(row.Type or "")~="Feat"
                            or tostring(row.Class or "")~=oldFeatId
                            or tostring(row.Skill or "")~=HB_MULTIFACETED_SKILL_LIST
                            or tonumber(row.DefinitionIndex)~=0
                            or type(row.Proficiencies)~="table"
                            or #row.Proficiencies~=4 then
                            return false,"Multifaceted has unexpected skill selections"
                        end
                        skillRow=row
                    else
                        return false,"Multifaceted has additional unverified "..tostring(family).." selections"
                    end
                end
            end
        end
    end
    if not passiveRows.archetype or not passiveRows.trait or not skillRow then
        return false,"Multifaceted requires one archetype, one trait and four skills"
    end
    for _,spell in ipairs(history.Spells or {}) do
        if IsFeatOwned(spell) then
            return false,"Multifaceted owns an unverified spell grant"
        end
    end
    local skillSet={}
    for _,skill in ipairs(skillRow.Proficiencies) do
        skill=tostring(skill or "")
        if skill=="" or skillSet[skill] then
            return false,"Multifaceted has missing or duplicated skill choices"
        end
        skillSet[skill]=true
    end
    local function SetMatches(ids,set,required)
        if type(ids)~="table" then return false end
        if not required and #ids==0 then return true end
        local expected=0;for _ in pairs(set) do expected=expected+1 end
        if #ids~=expected then return false end
        local seen={}
        for _,id in ipairs(ids) do
            id=tostring(id or "")
            if not set[id] or seen[id] then return false end
            seen[id]=true
        end
        return true
    end
    local function NoExtra(record)
        if type(record)~="table" then return false end
        for _,field in ipairs({"AddSpells","Expertise"}) do
            local values=record[field]
            if values~=nil and (type(values)~="table" or next(values)~=nil) then
                return false
            end
        end
        for _,value in ipairs(record.AbilityImprovements or {}) do
            if tonumber(value)~=0 then return false end
        end
        return true
    end
    local owner=nil; local primaryCount,replicaCount=0,0
    local passiveGrantCounts,skillGrantCounts={},{}
    local function IncrementMatches(ids,set,counts)
        if type(ids)~="table" then return false end
        for _,value in ipairs(ids) do
            local id=tostring(value or "")
            if set[id] then counts[id]=(counts[id] or 0)+1 end
        end
        return true
    end
    for _,entry in ipairs(levelEntries or {}) do
        local f=entry.feat
        local rep=entry.replicatedFeat
        if f and tostring(f.Feat or "")==oldFeatId then
            owner=entry;primaryCount=primaryCount+1
            if not NoExtra(f) or not SetMatches(f.AddPassives,owned,true)
                or not SetMatches(f.Proficiencies,skillSet,true) then
                return false,"Multifaceted primary feat grants do not mirror recorded choices"
            end
        end
        if rep and tostring(rep.Feat or "")==oldFeatId then
            replicaCount=replicaCount+1
            if not NoExtra(rep) or not SetMatches(rep.AddPassives or {},owned,false)
                or not SetMatches(rep.Proficiencies or {},skillSet,false) then
                return false,"Multifaceted replicated feat has unexpected grants"
            end
        end
        if entry.passives and entry.passives.AddPassives then
            if not IncrementMatches(entry.passives.AddPassives,owned,passiveGrantCounts) then
                return false,"Multifaceted normal passive grants are malformed"
            end
        end
        if entry.skills and entry.skills.Proficiencies then
            if not IncrementMatches(entry.skills.Proficiencies,skillSet,skillGrantCounts) then
                return false,"Multifaceted normal skill grants are malformed"
            end
        end
    end
    if primaryCount~=1 or replicaCount~=1 or not owner
        or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=oldFeatId
        or type(owner.meta)~="table"
        or tonumber(owner.meta.Level)~=level
        or tostring(owner.meta.SpellSourceType or "")~="ProgressionClass"
        or not owner.passives or not owner.skills
        or not SetMatches(owner.skills.Proficiencies,skillSet,true)
        or type(owner.skills.Expertise)~="table" or #owner.skills.Expertise~=0 then
        return false,"Multifaceted feat and normal progression ownership is ambiguous"
    end
    for id in pairs(owned) do
        if passiveGrantCounts[id]~=1 then
            return false,"Multifaceted passive has a foreign or missing progression grant: "..id
        end
    end
    for id in pairs(skillSet) do
        if skillGrantCounts[id]~=1 then
            return false,"Multifaceted skill has a foreign or missing progression grant: "..id
        end
    end
    for _,entry in ipairs(levelEntries or {}) do
        if entry~=owner then
            for _,component in ipairs({"feat","replicatedFeat","passives","skills"}) do
                for _,id in ipairs(entry[component] and entry[component].Proficiencies or {}) do
                    if skillSet[tostring(id)] then
                        return false,"Multifaceted skill is granted by another same-level component"
                    end
                end
                for _,id in ipairs(entry[component] and entry[component].AddPassives or {}) do
                    if owned[tostring(id)] then
                        return false,"Multifaceted passive is granted by a different same-level component"
                    end
                end
            end
        end
    end
    -- Now and only now mutate the COPY. Keep unrelated class choices and
    -- passives, including Maneuvers awarded at the exact same character level.
    for index=#upgrades.Passives,1,-1 do
        local row=upgrades.Passives[index]
        if row==passiveRows.archetype or row==passiveRows.trait then
            table.remove(upgrades.Passives,index)
        end
    end
    for index=#upgrades.Skills,1,-1 do
        if upgrades.Skills[index]==skillRow then table.remove(upgrades.Skills,index) end
    end
    local function Without(ids,set)
        local kept={}
        for _,id in ipairs(ids or {}) do
            if not set[tostring(id)] then kept[#kept+1]=id end
        end
        return kept
    end
    owner.feat.AddPassives=Without(owner.feat.AddPassives,owned)
    owner.feat.Proficiencies=Without(owner.feat.Proficiencies,skillSet)
    owner.passives.AddPassives=Without(owner.passives.AddPassives,owned)
    owner.skills.Proficiencies=Without(owner.skills.Proficiencies,skillSet)
    if type(owner.replicatedFeat.AddPassives)=="table" then
        owner.replicatedFeat.AddPassives=Without(owner.replicatedFeat.AddPassives,owned)
    end
    if type(owner.replicatedFeat.Proficiencies)=="table" then
        owner.replicatedFeat.Proficiencies=Without(owner.replicatedFeat.Proficiencies,skillSet)
    end
    return true,nil
end


-- Reverse of verified Multifaceted dismantling. Construct exactly the natural
-- three CCLevelUp choice rows and matching progression components on a COPY.
-- This path never substitutes the GUID unless all six choices are present.
local function AddRecordedMultifacetedEffects(history,levelEntries,allHistories,allBuckets,
    oldFeatId,selections,level)
    if type(selections)~="table" or tostring(history.Feat or "")~=oldFeatId
        or oldFeatId==HB_MULTIFACETED_FEAT_ID then
        return false,"Multifaceted source feat identity or selections differ"
    end
    if not HBFeatXmlRule(HB_MULTIFACETED_FEAT_ID)
        or HBFeatXmlRule(HB_MULTIFACETED_FEAT_ID).Kind~="MixedChoices" then
        return false,"Installed Multifaceted feat definition changed"
    end
    local skillList=HB_MULTIFACETED_SKILL_LIST
    local archetypeList="4607f9c7-335c-443f-b075-a3f068c20a0d"
    local traitList="15eff335-46df-4268-9eea-aabcb6c13025"
    for section in pairs(selections) do
        if section~="Skills" and section~="Archetype" and section~="Trait" then
            return false,"Multifaceted selection payload contains an unknown group"
        end
    end
    local skills,arch,trait=selections.Skills,selections.Archetype,selections.Trait
    if type(skills)~="table" or #skills~=4 or type(arch)~="table"
        or #arch~=1 or type(trait)~="table" or #trait~=1 then
        return false,"Multifaceted needs one archetype, one trait and four skills"
    end
    local function DenseArray(values,expected)
        local count=0
        for index in pairs(values) do
            if type(index)~="number" or index~=math.floor(index)
                or index<1 or index>expected then return false end
            count=count+1
        end
        return count==expected
    end
    if not DenseArray(skills,4) or not DenseArray(arch,1)
        or not DenseArray(trait,1) then
        return false,"Multifaceted choice rows are not complete ordered arrays"
    end
    local passiveCatalogA,passiveCatalogT=ResolvePassiveList(archetypeList),ResolvePassiveList(traitList)
    if not passiveCatalogA or not passiveCatalogT then
        return false,"Multifaceted installed passive lists are unavailable"
    end
    local knownSkills={}
    for _,option in ipairs(ChoicesOptionSet("Skill",skillList)) do knownSkills[tostring(option.Id)]=true end
    local skillSet,passiveSet={},{}
    for _,id in ipairs(skills) do
        id=tostring(id or "")
        if not knownSkills[id] or skillSet[id] then
            return false,"Multifaceted skill outside list or duplicated"
        end
        skillSet[id]=true
    end
    local a,t=tostring(arch[1] or ""),tostring(trait[1] or "")
    if not passiveCatalogA.Set[a] or not passiveCatalogT.Set[t] or a==t then
        return false,"Multifaceted archetype or trait outside installed passive list"
    end
    passiveSet[a]=true;passiveSet[t]=true
    local upgrades=history.Upgrades
    if type(upgrades)~="table" or type(upgrades.Passives)~="table"
        or type(upgrades.Skills)~="table" then
        return false,"Multifaceted requires recorded passive and skill upgrade structures"
    end
    -- Verify a genuinely simple source; no feat-owned rows from other groups.
    for _,rows in pairs(upgrades) do
        if type(rows)=="table" then
            for _,row in ipairs(rows) do
                if type(row)=="table" and (tostring(row.Type or "")=="Feat"
                    or tostring(row.Class or "")==oldFeatId) then
                    return false,"Original feat has secondary choices"
                end
            end
        end
    end
    for _,h in ipairs(allHistories or {}) do
        if h~=history then
            if tostring(h.Feat or "")==HB_MULTIFACETED_FEAT_ID then
                return false,"Multifaceted already owned at another level"
            end
            for _,row in ipairs(h.Upgrades and h.Upgrades.Skills or {}) do
                for _,id in ipairs(row.Proficiencies or {}) do
                    if skillSet[tostring(id)] then return false,"Multifaceted skill recorded at another level" end
                end
            end
            for _,row in ipairs(h.Upgrades and h.Upgrades.Passives or {}) do
                for _,id in ipairs(row.Passives or {}) do
                    if passiveSet[tostring(id)] then return false,"Multifaceted passive already selected at another level" end
                end
            end
        end
    end
    for bucketLevel,entries in pairs(allBuckets or {}) do
        if tonumber(bucketLevel)~=level then
            for _,entry in ipairs(entries) do
                for _,component in ipairs({"feat","replicatedFeat","passives","skills"}) do
                    for _,id in ipairs(entry[component] and entry[component].Proficiencies or {}) do
                        if skillSet[tostring(id)] then return false,"Multifaceted skill already granted at another level" end
                    end
                    for _,id in ipairs(entry[component] and entry[component].AddPassives or {}) do
                        if passiveSet[tostring(id)] then return false,"Multifaceted passive already granted at another level" end
                    end
                end
            end
        end
    end
    local owner=nil;local p,r=0,0
    for _,entry in ipairs(levelEntries) do
        if entry.feat and tostring(entry.feat.Feat or "")==oldFeatId then
            p=p+1;owner=entry
        end
        if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat or "")==oldFeatId then r=r+1 end
        for _,component in ipairs({"feat","replicatedFeat","passives","skills"}) do
            for _,id in ipairs(entry[component] and entry[component].AddPassives or {}) do
                if passiveSet[tostring(id)] then return false,"Multifaceted passive already granted at same level" end
            end
            for _,id in ipairs(entry[component] and entry[component].Proficiencies or {}) do
                if skillSet[tostring(id)] then return false,"Multifaceted skill already granted at same level" end
            end
        end
    end
    if p~=1 or r~=1 or not owner or not owner.replicatedFeat
        or tostring(owner.replicatedFeat.Feat or "")~=oldFeatId
        or type(owner.meta)~="table" or tonumber(owner.meta.Level)~=level
        or tostring(owner.meta.SpellSourceType or "")~="ProgressionClass"
        or type(owner.meta.Progression)~="string" or owner.meta.Progression==""
        or type(owner.meta.Source)~="string" or owner.meta.Source=="" then
        return false,"Original simple feat progression owner not unique"
    end
    local pri,rep=owner.feat,owner.replicatedFeat
    local function EmptyGrants(component)
        if type(component)~="table" then return false end
        for _,field in ipairs({"AddPassives","Proficiencies","Expertise","AddSpells"}) do
            if component[field]~=nil and (type(component[field])~="table" or next(component[field])~=nil) then
                return false
            end
        end
        for _,n in ipairs(component.AbilityImprovements or {}) do
            if tonumber(n)~=0 then return false end
        end
        return true
    end
    if not EmptyGrants(pri) or not EmptyGrants(rep) then
        return false,"Source feat has unverified effects"
    end
    -- Existing normal progression records are class-owned. Only write into
    -- the primary feat's exact class progression, never a subclass owner.
    for _,entry in ipairs(levelEntries) do
        if entry~=owner then
            if entry.passives or entry.skills then
                return false,"Unrelated progression owns normal passive or skill component"
            end
        end
    end
    local normalPassives=owner.passives or {AddPassives={},RemovePassives={}}
    local normalSkills=owner.skills or {Expertise={},Proficiencies={}}
    if type(normalPassives.AddPassives)~="table"
        or (normalPassives.RemovePassives~=nil and
            (type(normalPassives.RemovePassives)~="table" or next(normalPassives.RemovePassives)~=nil))
        or type(normalSkills.Proficiencies)~="table"
        or type(normalSkills.Expertise)~="table" then
        return false,"Original progression grants have unexpected component shape"
    end
    -- Mirror the natural, user-provided level-8 CCLevelUp schema exactly.
    local function NewPassive(selector,list,index,id)
        return {Type="Feat",Class=HB_MULTIFACETED_FEAT_ID,
            SelectorId=selector,PassiveList=list,Passives={id},
            ReplacePassives={},DefinitionIndex=index,Level=level,
            Multiclass=false,Subclass=history.Class,field_80=-1}
    end
    upgrades.Passives[#upgrades.Passives+1]=NewPassive("Archetypes",archetypeList,0,a)
    upgrades.Passives[#upgrades.Passives+1]=NewPassive("Traits",traitList,1,t)
    upgrades.Skills[#upgrades.Skills+1]={Type="Feat",Class=HB_MULTIFACETED_FEAT_ID,
        Skill=skillList,Proficiencies={skills[1],skills[2],skills[3],skills[4]},
        DefinitionIndex=0,Level=level,Multiclass=false,Subclass=history.Class,
        field_60="",field_80=-1}
    pri.AddPassives={a,t};pri.Proficiencies={skills[1],skills[2],skills[3],skills[4]}
    rep.AddPassives={};rep.Proficiencies={}
    normalPassives.AddPassives[#normalPassives.AddPassives+1]=a
    normalPassives.AddPassives[#normalPassives.AddPassives+1]=t
    for _,id in ipairs(skills) do normalSkills.Proficiencies[#normalSkills.Proficiencies+1]=id end
    owner.passives=normalPassives;owner.skills=normalSkills
    return true,nil
end

-- All edits are made on a deep copy of a complete snapshot.  Never modify
-- live components before provenance, option and consistency checks succeed.
local HB_HISTORICAL_FEAT_CLASS_REQUIREMENTS={
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

local function HBServerHistoricalRequiredClass(featId,histories,level)
    local cls=HB_HISTORICAL_FEAT_CLASS_REQUIREMENTS[tostring(featId or ""):lower()]
    if not cls then return true end
    if HB_YOKEBREAKER_ALL_CLASSES_TEST then
        RespecStartLog("HISTORICAL_YOKEBREAKER_CLASS_TEST_BYPASS level="..tostring(level)
            .." feat="..tostring(featId).." class="..tostring(cls))
        return true
    end
    for i=1,level do
        local row=histories[i]
        local id=row and tostring(row.Class or "") or ""
        if id~="" and Ext.StaticData and Ext.StaticData.Get then
            local ok,record=pcall(Ext.StaticData.Get,id,"ClassDescription")
            if ok and record then
                local read,name=pcall(function() return record.Name end)
                if read and tostring(name or ""):lower()==cls:lower() then
                    return true
                end
            end
        end
    end
    return false,"Yokebreaker requires one "..cls.." level before or at feat level "..level
end

-- Feat replacement is a two-phase transaction on an isolated snapshot:
-- prove and dismantle the original feat's secondary-choice package, THEN
-- construct the new feat's independently validated choices. A source feat
-- does not need to appear on a separate allowlist for each target choice kind.
-- These booleans denote installed/source-backed dismantling ADAPTERS, not
-- assumptions about the feat's spellbook or its secondary effects.
local function HBVerifiedRemovedFeatChoicePackage(rule, removed)
    if not rule then
        -- Fixed-choice feats and definition-driven generic adapters can have
        -- no linked HB custom-description rule. Their normal source-removal
        -- guards still run and must succeed before this check is reached.
        return true
    end
    local kind=tostring(rule.Kind or "")
    local sourceHandlers={
        AbilityChoices=removed.Pair,
        CantripChoices=removed.Accord,
        MixedChoices=removed.Multifaceted,
        ElementChoices=removed.Elemental,
        PassiveChoices=removed.Pair or removed.Generic,
        SubclassGrant=removed.Generic or removed.GenericSpells
            or removed.AutoSpells,
    }
    if sourceHandlers[kind] then return true end
    -- UnknownHBFeat/MultipleHBChoices and any future secondary selector kind
    -- are NOT cleanly removable until a corresponding audited adapter exists.
    return false,"Historical source feat has unverified "..kind.." choices"
end

-- Likewise a target uses its own installed-selector constructor, regardless
-- of the old feat. Never claim unknown target choices are supported just
-- because the unrestricted feat-catalog experiment is enabled.
local function HBVerifiedNewFeatChoicePackage(rule, added)
    if not rule then return true end
    local kind=tostring(rule.Kind or "")
    local targetHandlers={
        AbilityChoices=added.Pair,
        CantripChoices=added.Accord,
        MixedChoices=added.Multifaceted,
        ElementChoices=added.Elemental,
        PassiveChoices=added.Pair or added.Generic,
        SubclassGrant=added.Generic or added.GenericSpells
            or added.AutoSpells,
    }
    if targetHandlers[kind] then return true end
    return false,"Historical replacement feat has unverified "..kind.." choices"
end

local function ValidateAndPatchOtherChoices(original, edits, maxLevel, nativeSwap)
    if type(edits) ~= "table" or #edits > maxLevel*12 then
        return nil, "Invalid historical choice edit batch"
    end
    local patched=CopyPlainTable(original)
    local histories=patched.components and patched.components.ccLevelUp and patched.components.ccLevelUp.LevelUps
    local buckets=patched.progressions and patched.progressions.buckets
    if not histories or not buckets then return nil,"Historical components unavailable" end
    -- All other spell edits are part of one transaction. A player may move a
    -- spell to an earlier level and manually replace its old slot. Validate
    -- against the resulting owned choices, not the already-displaced OLD ID.
    -- The exception below is intentionally unavailable for fixed grants,
    -- missing/ambiguous selectors, or an unverified progression owner.
    local plannedSpellRemovals={}
    local planAmbiguous={}
    for _,pending in ipairs(edits) do
        if (pending.Kind=="Spell" or pending.Kind=="Cantrip")
            and tonumber(pending.Level) and tonumber(pending.Level)>=2
            and tostring(pending.From or "")~=""
            and tostring(pending.From or "")~=tostring(pending.To or "") then
            local at=tonumber(pending.Level)
            local oldId=tostring(pending.From)
            local src=tostring(pending.Source or "")
            local i,j=tonumber(pending.EntryIndex),tonumber(pending.SlotIndex)
            local row=histories[at]
            local match=nil
            if row and i and j then
                for _,choice in ipairs(BuildOtherHistoricalChoices(row,at)) do
                    if choice.Editable and choice.Kind==pending.Kind
                        and choice.Source==src and choice.EntryIndex==i
                        and choice.SlotIndex==j and choice.From==oldId
                        and choice.List==tostring(pending.List or "") then
                        if match then match=nil;break end
                        match=choice
                    end
                end
            end
            -- The grant must be the single matching progression-owned row
            -- for that exact character level, as required during replay.
            if match and row then
                local owner=src=="Spells" and row.Spells and row.Spells[i]
                    or src=="Upgrades.Spells" and row.Upgrades
                        and row.Upgrades.Spells and row.Upgrades.Spells[i]
                local sourceId=tostring(owner and owner.Class or "")
                local ownerType=tostring(owner and owner.Type or "")
                local spellSource=ownerType=="Class" and "ProgressionClass"
                    or ownerType=="SubClass" and "ProgressionSubClass" or nil
                local grants=0
                if spellSource and sourceId~="" then
                    for _,entry in ipairs(buckets[at] or {}) do
                        for _,grant in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                            if tostring(grant.SpellId or grant.SpellID or "")==oldId then
                                local meta=entry.meta
                                if not meta or tonumber(meta.Level)~=at
                                    or tostring(meta.Source or "")~=sourceId
                                    or tostring(meta.SpellSourceType or "")~=spellSource then
                                    grants=-999;break
                                end
                                grants=grants+1
                            end
                        end
                        if grants<0 then break end
                    end
                end
                if grants==1 then
                    plannedSpellRemovals[at]=plannedSpellRemovals[at] or {}
                    if plannedSpellRemovals[at][oldId] then
                        planAmbiguous[at]=planAmbiguous[at] or {}
                        planAmbiguous[at][oldId]=true
                    end
                    plannedSpellRemovals[at][oldId]=true
                end
            end
        end
    end
    local function OriginalSpellWillBeReplaced(at,id)
        at=tonumber(at)
        return at and plannedSpellRemovals[at]
            and plannedSpellRemovals[at][id] == true
            and not (planAmbiguous[at] and planAmbiguous[at][id])
    end
    local used={}
    for _, e in ipairs(edits) do
        local level=tonumber(e.Level)
        local kind=tostring(e.Kind or "")
        local source=tostring(e.Source or "")
        local i=tonumber(e.EntryIndex); local j=tonumber(e.SlotIndex)
        local from=tostring(e.From or ""); local to=tostring(e.To or "")
        if not level or level~=math.floor(level) or level<1 or level>maxLevel
            or (level==1 and not (kind=="Skill" or kind=="Expertise"
                or kind=="Spell" or kind=="Cantrip"))
            or not i or i~=math.floor(i) or i<1 or not j or j~=math.floor(j) or j<1
            or from=="" or to=="" or (from==to and not
                (kind=="Feat" and e.GenericFeatChoices~=nil
                    and HBFSpellGroups(from)~=nil)) then
            return nil,"Malformed or unsupported historical selection"
        end
        local key=table.concat({level,kind,source,i,j},":")
        if used[key] then return nil,"Multiple edits target the same historical choice" end
        used[key]=true
        local history=histories[level]
        if not history then return nil,"Missing level-up record for level "..level end
        local recorded=BuildOtherHistoricalChoices(history,level)
        local origin=nil
        for _,c in ipairs(recorded) do
            if c.Kind==kind and c.Source==source and c.EntryIndex==i
                and c.SlotIndex==j and c.From==from and c.List==tostring(e.List or "") then
                origin=c;break
            end
        end
        if not origin or not origin.Editable then
            RespecStartLog("LEVEL_RESPEC_CHOICE_CATALOG_REJECT level="..level
                .." kind="..kind.." source="..source.." entry="..i.." slot="..j
                .." matched="..tostring(origin~=nil)
                .." editable="..tostring(origin and origin.Editable))
            return nil,"Selection catalog differs at level "..level
        end
        local valid=false
        for _,option in ipairs(origin.Options) do if option.Id==to then valid=true;break end end
        if not valid then return nil,"Replacement not in verified selection list at level "..level end
        local levelEntries=buckets[level] or {}
        if level==1 then
            local originRow=source=="Skills" and history.Upgrades and history.Upgrades.Skills[i]
                or source=="SkillExpertise" and history.Upgrades and history.Upgrades.SkillExpertise[i]
                or source=="Spells" and history.Spells and history.Spells[i]
                or source=="Upgrades.Spells" and history.Upgrades and history.Upgrades.Spells[i]
            if not originRow or tonumber(originRow.Level)~=1 then
                return nil,"Level-one selection record is missing or invalid"
            end
            local owner=tostring(originRow.Class or "")
            local role=tostring(originRow.Type or "")
            if not ((role=="Class" and owner==tostring(history.Class or ""))
                or (role=="SubClass" and owner==tostring(history.SubClass or ""))) then
                return nil,"Level-one choice owner is not its original class/subclass"
            end
            local owners=0
            for _,entry in ipairs(levelEntries) do
                local meta=entry.meta
                local component=(kind=="Skill" or kind=="Expertise") and entry.skills
                    or entry.spells
                local grants=component and (kind=="Skill" and component.Proficiencies
                    or kind=="Expertise" and component.Expertise
                    or component.AddSpells) or {}
                for _,grant in ipairs(grants) do
                    local id=(kind=="Spell" or kind=="Cantrip")
                        and tostring(type(grant)=="table" and (grant.SpellId or grant.SpellID) or "")
                        or tostring(grant)
                    if id==from then
                        if type(meta)~="table" or tonumber(meta.Level)~=1
                            or tostring(meta.Source or "")~=owner
                            or tostring(meta.SpellSourceType or "")~=
                                (role=="Class" and "ProgressionClass" or "ProgressionSubClass") then
                            return nil,"Level-one grant has conflicting or unknown ownership"
                        end
                        owners=owners+1
                    end
                end
            end
            if owners~=1 then
                return nil,"Level-one selection does not have one exclusively owned grant"
            end
        end
        if kind=="Feat" then
            local reqOk,reqError=HBServerHistoricalRequiredClass(to,histories,level)
            if not reqOk then return nil,reqError end
            if not IsValidGuid(history.Feat) or tostring(history.Feat)~=from then
                return nil,"Feat history mismatch" end
            -- A feat GUID swap cannot reconstruct feat-specific secondary
            -- selectors or assess a requirement against PREVIOUS-level stats.
            -- Do not allow the generic experimental replay to silently create
            -- a level-up record that could never have been selected normally.
            local featOK,feat=pcall(Ext.StaticData.Get,to,"Feat")
            if not featOK or not feat then
                return nil,"Replacement feat data unavailable for safety validation"
            end
            local fromOK,oldFeat=pcall(Ext.StaticData.Get,from,"Feat")
            if not fromOK or not oldFeat then
                return nil,"Original feat metadata unavailable for verifying secondary effects"
            end
            local function HasUnsupportedExpressions(record,field,id)
                -- SE can THROW when a field is missing. Never interpret that
                -- as proof that a Yokebreaker feat has no prerequisites or
                -- that Accord/Multifaceted has no secondary selectors.
                local source=HB_SOURCE_FEAT_CONTRACTS[tostring(id or ""):lower()]
                local sourceProtected=source and (field=="Selectors" and source.s
                    or field=="Requirements" and source.r)
                local ok,value=pcall(function() return record[field] end)
                if not ok or value==nil or value==false then
                    if source then return sourceProtected==true end
                    -- No definition and no readable runtime property.
                    return true
                end
                if type(value)=="string" then
                    return sourceProtected==true or value:match("%S")~=nil
                end
                if type(value)=="table" then
                    return sourceProtected==true or next(value)~=nil
                end
                return sourceProtected==true or tostring(value)~=""
            end
            -- The ORIGINAL feat's secondary selections are just as important
            -- as those of its replacement. Otherwise a GUID-only swap could
            -- preserve obsolete ASI/skill/spell upgrades from the old feat.
            local sourceRule=HBFeatXmlRule(from)
            local replacementRule=HBFeatXmlRule(to)
            local originalKnownFixed=HB_GENERIC_FEATS.IsKnownFixedOnly(from)
            local targetKnownFixed=HB_GENERIC_FEATS.IsKnownFixedOnly(to)
            local removeRecordedGeneric=HBFGenericGroups(from)~=nil
            local addRecordedGeneric=HBFGenericGroups(to)~=nil and from~=to
            local removeRecordedGenericSpell=HBFSpellGroups(from)~=nil
            local addRecordedGenericSpell=HBFSpellGroups(to)~=nil
                and (from~=to or (e.GenericFeatChoices~=nil and from==to))
            local removeRecordedAutoSpells=HBFAutoLists(from)~=nil
            local addRecordedAutoSpells=HBFAutoLists(to)~=nil and from~=to
            local removeRecordedAccord=from==HB_ACCORD_FEAT_ID
                and sourceRule and sourceRule.Kind=="CantripChoices"
            local removeRecordedPair=HB_PASSIVE_PAIR_FEATS[from]
            local removeRecordedMultifaceted=from==HB_MULTIFACETED_FEAT_ID
                and sourceRule and sourceRule.Kind=="MixedChoices"
            local removeRecordedElementalAdept=from==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT
                and sourceRule and sourceRule.Kind=="ElementChoices"
            -- Source and target are intentionally independent. The source
            -- handlers prove and remove what was historically owned; the
            -- destination handlers validate and build NEW choices. This
            -- admits any supported combination without pair-specific lists.
            local addRecordedPair=HB_PASSIVE_PAIR_FEATS[to]
            local addRecordedAccord=to==HB_ACCORD_FEAT_ID
                and replacementRule and replacementRule.Kind=="CantripChoices"
            local addRecordedMultifaceted=to==HB_MULTIFACETED_FEAT_ID
                and replacementRule and replacementRule.Kind=="MixedChoices"
            local addRecordedElementalAdept=to==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT
                and replacementRule and replacementRule.Kind=="ElementChoices"
            local verifiedSource,sourceReason=HBVerifiedRemovedFeatChoicePackage(sourceRule,{
                Pair=removeRecordedPair~=nil,
                Accord=not not removeRecordedAccord,
                Multifaceted=not not removeRecordedMultifaceted,
                Elemental=not not removeRecordedElementalAdept,
                Generic=removeRecordedGeneric,
                GenericSpells=removeRecordedGenericSpell,
                AutoSpells=removeRecordedAutoSpells,
            })
            if not verifiedSource then return nil,sourceReason end
            local verifiedTarget,targetReason=HBVerifiedNewFeatChoicePackage(replacementRule,{
                Pair=addRecordedPair~=nil,
                Accord=not not addRecordedAccord,
                Multifaceted=not not addRecordedMultifaceted,
                Elemental=not not addRecordedElementalAdept,
                Generic=addRecordedGeneric,
                GenericSpells=addRecordedGenericSpell,
                AutoSpells=addRecordedAutoSpells,
            })
            if not verifiedTarget then return nil,targetReason end
            if not HB_UNRESTRICTED_FEAT_TEST and sourceRule and not removeRecordedElementalAdept and not removeRecordedPair
                and not removeRecordedAccord
                and not removeRecordedMultifaceted then
                return nil,"Original HB feat grants "..sourceRule.Choices
                    .."; cannot remove its historical choices with a feat ID swap"
            end
            if not HB_UNRESTRICTED_FEAT_TEST and replacementRule and not addRecordedElementalAdept and not addRecordedPair
                and not addRecordedAccord
                and not addRecordedMultifaceted then
                return nil,"Replacement HB feat grants "..replacementRule.Choices
                    .."; these choices require faithful historical replay"
            end
            if not HB_UNRESTRICTED_FEAT_TEST and not removeRecordedElementalAdept and not removeRecordedPair
                and not removeRecordedMultifaceted and not removeRecordedAccord and HasUnsupportedExpressions(oldFeat,"Selectors",from) then
                return nil,"Original feat uses secondary selectors; its existing upgrades cannot be safely reassigned"
            end
            if not HB_UNRESTRICTED_FEAT_TEST and not addRecordedElementalAdept and not addRecordedPair
                and not addRecordedMultifaceted and not addRecordedAccord and HasUnsupportedExpressions(feat,"Selectors",to) then
                return nil,"Replacement feat uses secondary selectors requiring verified historical replay"
            end
            if not HB_UNRESTRICTED_FEAT_TEST and HasUnsupportedExpressions(feat,"Requirements",to) then
                return nil,"Replacement feat prerequisites cannot yet be verified for the historical level"
            end
            if HB_UNRESTRICTED_FEAT_TEST then
                RespecStartLog("HISTORICAL_FEAT_UNRESTRICTED_EXPERIMENT level="..tostring(level)
                    .." from="..from.." to="..to
                    .." sourceRule="..tostring(sourceRule and sourceRule.Kind or "none")
                    .." targetRule="..tostring(replacementRule and replacementRule.Kind or "none"))
            end
            -- A recorded Elemental Adept must first be fully dismantled
            -- BEFORE the two feat IDs are changed. Do not add a complex feat
            -- from a simple feat: that would require new choice rows.
            if removeRecordedGeneric then
                local removed,why=RemoveHBFGenericEffects(history,levelEntries,from,level)
                if not removed then return nil,why end
            end
            if removeRecordedGenericSpell then
                local removed,why=RemoveHBFSpellEffects(history,levelEntries,from,level)
                if not removed then return nil,why end
            end
            if removeRecordedAutoSpells then
                local removed,why=RemoveHBFAutomaticSpells(history,levelEntries,from,level)
                if not removed then return nil,why end
            end
            if removeRecordedAccord then
                local removed,why=RemoveRecordedAccordEffects(history,levelEntries,from,level)
                if not removed then return nil,why end
            end
            if removeRecordedMultifaceted then
                local removed,why=RemoveRecordedMultifacetedEffects(history,levelEntries,from,level)
                if not removed then return nil,why end
            end
            if removeRecordedElementalAdept then
                local removed,why=RemoveExistingElementalAdeptEffects(history,levelEntries,from)
                if not removed then return nil,why end
            end
            if removeRecordedPair then
                local removed,why=RemoveRecordedPairFeatEffects(history,levelEntries,from,removeRecordedPair)
                if not removed then return nil,why end
            end
            RespecStartLog("HISTORICAL_FEAT_PACKAGE_TRANSITION level="..tostring(level)
                .." from="..from.." to="..to
                .." source="..tostring(sourceRule and sourceRule.Kind or "fixed-or-generic")
                .." target="..tostring(replacementRule and replacementRule.Kind or "fixed-or-generic")
                .." sourceClean=true")
            if addRecordedAccord then
                local added,why=AddRecordedAccordEffects(
                    history,levelEntries,histories,buckets,from,e.AccordChoices,level)
                if not added then return nil,why end
            elseif e.AccordChoices~=nil then
                return nil,"Accord selections supplied for an unrelated feat"
            end
            if addRecordedMultifaceted then
                local added,why=AddRecordedMultifacetedEffects(
                    history,levelEntries,histories,buckets,from,e.MultifacetedChoices,level)
                if not added then return nil,why end
            elseif e.MultifacetedChoices~=nil then
                return nil,"Multifaceted selections supplied for a different feat"
            end
            if addRecordedAutoSpells then
                local added,why=AddHBFAutomaticSpells(
                    history,levelEntries,histories,buckets,from,to,level)
                if not added then return nil,why end
            end
            if addRecordedGeneric then
                local added,why=AddHBFGenericEffects(history,levelEntries,
                    histories,buckets,from,to,e.GenericFeatChoices,level)
                if not added then return nil,why end
            elseif addRecordedGenericSpell then
                local added,why=AddHBFSpellEffects(history,levelEntries,
                    histories,buckets,from,to,e.GenericFeatChoices,level)
                if not added then return nil,why end
            elseif e.GenericFeatChoices~=nil then
                return nil,"Feat group selections supplied for an unrelated feat"
            end
            if addRecordedPair then
                local choices=e.PassiveFeatChoices
                local added,why=AddRecordedPairFeatEffects(
                    history,levelEntries,from,to,choices,level,addRecordedPair)
                if not added then return nil,why end
                -- The same passive must not already have been granted by
                -- another level's class progression or feat component.
                local selected={}
                for _,id in ipairs(choices) do selected[tostring(id)]=true end
                for historyLevel,record in ipairs(histories) do
                    if historyLevel~=level then
                        for _,selection in ipairs(record.Upgrades and record.Upgrades.Passives or {}) do
                            for _,id in ipairs(selection.Passives or {}) do
                                if selected[tostring(id)] then
                                    return nil,"Feat passive already recorded at character level "..historyLevel
                                end
                            end
                        end
                    end
                end
                for otherLevel,otherEntries in pairs(buckets) do
                    if tonumber(otherLevel)~=level then
                        for _,entry in ipairs(otherEntries) do
                            for _,key in ipairs({"passives","feat","replicatedFeat"}) do
                                for _,id in ipairs(entry[key] and entry[key].AddPassives or {}) do
                                    if selected[tostring(id)] then
                                        return nil,"Selected feat passive already granted at another level: "..tostring(id)
                                    end
                                end
                            end
                        end
                    end
                end
            elseif e.PassiveFeatChoices~=nil then
                return nil,"Two-passive feat selections supplied for an unrelated feat"
            end
            if addRecordedElementalAdept then
                -- Explicit two-element pair is required on the SAME verified
                -- historical feat edit; a bare GUID swap is never sufficient.
                local elements=e.ElementChoices
                local added,why=AddRecordedElementalAdeptEffects(
                    history,levelEntries,from,elements,level)
                if not added then return nil,why end
                for bucketLevel,otherEntries in pairs(buckets) do
                    if tonumber(bucketLevel)~=level then
                        for _,otherEntry in ipairs(otherEntries) do
                            for _,componentName in ipairs({"passives","feat","replicatedFeat"}) do
                                for _,id in ipairs(otherEntry[componentName]
                                    and otherEntry[componentName].AddPassives or {}) do
                                    if tostring(id)==elements[1] or tostring(id)==elements[2] then
                                        return nil,"Elemental Adept element already granted at another level"
                                    end
                                end
                            end
                        end
                    end
                end
            elseif e.ElementChoices~=nil then
                return nil,"Secondary element choices supplied for a different feat"
            end
            local primary, replicate=0,0
            for _,entry in ipairs(levelEntries) do
                if entry.feat and tostring(entry.feat.Feat)==from then
                    entry.feat.Feat=to;primary=primary+1
                end
                if entry.replicatedFeat and tostring(entry.replicatedFeat.Feat)==from then
                    entry.replicatedFeat.Feat=to;replicate=replicate+1
                end
            end
            if primary~=1 or replicate~=1 then
                return nil,"Feat progression mismatch (not a simple historical feat)" end
            -- Feats carrying secondary selections must be edited via their
            -- own feat-specific selectors; substituting just the GUID would
            -- retain effects/choices from the old feat.
            for _,entry in ipairs(levelEntries) do
                local f=entry.feat
                if f and tostring(f.Feat)==to then
                    for _,field in ipairs({"AddPassives","AddSpells","Expertise","Proficiencies"}) do
                        if not HB_UNRESTRICTED_FEAT_TEST and not ((addRecordedElementalAdept or addRecordedPair
                            or addRecordedMultifaceted or addRecordedGeneric) and field=="AddPassives")
                            and not (addRecordedMultifaceted and field=="Proficiencies")
                            and not (addRecordedAccord and field=="AddSpells")
                            and type(f[field])=="table" and #f[field]>0 then
                            return nil,"Feat has additional "..field.." choices; replacement is not yet safe"
                        end
                    end
                    for _,n in ipairs(f.AbilityImprovements or {}) do
                        if not HB_UNRESTRICTED_FEAT_TEST and tonumber(n) and tonumber(n)~=0 then
                            return nil,"Ability-improvement feats need a dedicated effect editor"
                        end
                    end
                end
            end
            history.Feat=to
            if addRecordedGeneric then
                RespecStartLog("HISTORICAL_GENERIC_PASSIVE_FEAT_ADDED level="..level
                    .." feat="..to.." groups="..#(e.GenericFeatChoices or {}))
            end
            if removeRecordedGeneric then
                RespecStartLog("HISTORICAL_GENERIC_PASSIVE_FEAT_REMOVED level="..level
                    .." feat="..from)
            end
            if addRecordedPair then
                RespecStartLog("HISTORICAL_PASSIVE_PAIR_FEAT_ADDED level="..level
                    .." feat="..to.." ids="..table.concat(e.PassiveFeatChoices,","))
            end
            if removeRecordedPair then
                RespecStartLog("HISTORICAL_PASSIVE_PAIR_FEAT_REMOVED level="..level
                    .." feat="..from)
            end
            if addRecordedElementalAdept then
                RespecStartLog("HISTORICAL_ELEMENTAL_ADEPT_ADDED level="..level
                    .." previous="..from.." elements="
                    ..table.concat(e.ElementChoices,","))
            end
            if addRecordedAccord then
                RespecStartLog("HISTORICAL_ACCORD_ADDED level="..level
                    .." previous="..from.." cantrips="..table.concat(e.AccordChoices,","))
            end
            if removeRecordedAccord then
                RespecStartLog("HISTORICAL_ACCORD_REMOVED level="..level
                    .." previous="..from.." replacement="..to)
            end
            if addRecordedMultifaceted then
                RespecStartLog("HISTORICAL_MULTIFACETED_ADDED level="..level
                    .." previous="..from.." sixChoices=complete")
            end
            if removeRecordedMultifaceted then
                RespecStartLog("HISTORICAL_MULTIFACETED_REMOVED level="..level
                    .." previous="..from.." replacement="..to.." passiveChoices=2 skillChoices=4")
            end
            if removeRecordedElementalAdept then
                RespecStartLog("HISTORICAL_ELEMENTAL_ADEPT_REMOVED level="..level
                    .." previous="..from.." replacement="..to.." passives=2")
            end
        elseif kind=="Ability" then
            local row=history.Upgrades and history.Upgrades.AbilityBonuses
                and history.Upgrades.AbilityBonuses[i]
            if row and (tostring(row.Type or "")=="Feat"
                or (tostring(history.Feat or "")~=""
                    and tostring(row.Class or "")==tostring(history.Feat))) then
                return nil,"Feat-owned ability bonuses require verified feat-component replay"
            end
            if not row or tostring((row.Bonuses or {})[j])~=from then
                return nil,"Ability-bonus choice changed at level "..level end
            local amount=tonumber((row.BonusAmounts or {})[j])
            local a,b=HB_ABILITY_INDICES[from],HB_ABILITY_INDICES[to]
            if not amount or not a or not b then return nil,"Unknown ability improvement" end
            local count=0
            for _,entry in ipairs(levelEntries) do
                local vec=entry.abilityImprovements and entry.abilityImprovements.AbilityImprovements
                if vec and tonumber(vec[a]) and tonumber(vec[a])>=amount then
                    vec[a]=tonumber(vec[a])-amount
                    vec[b]=tonumber(vec[b] or 0)+amount
                    count=count+1
                end
            end
            if count~=1 then return nil,"Ability improvement components do not match history" end
            row.Bonuses[j]=to
        elseif kind=="Skill" or kind=="Expertise" then
            local arr=history.Upgrades and history.Upgrades[source]
            local row=arr and arr[i]
            local field=kind=="Skill" and "Proficiencies" or "Expertise"
            if not row or tostring((row[field] or {})[j])~=from then
                return nil,"Skill-selection provenance differs" end
            local owningFeat=tostring(history.Feat or "")
            local featOwned=(tostring(row.Type or "")=="Feat"
                or (owningFeat~="" and tostring(row.Class or "")==owningFeat))
            if featOwned then
                -- Never patch just the normal skill component for a feat-owned
                -- choice. That would leave feat effects (and saved history)
                -- disagreeing. Only the known four-slot Multifaceted form
                -- has a conservative secondary-skill replay contract.
                if kind~="Skill" or tostring(history.Feat or "")~=HB_MULTIFACETED_FEAT_ID then
                    return nil,"Feat-owned skill/expertise requires verified secondary replay"
                end
                local matched,why=PatchVerifiedMultifacetedSkill(
                    history,levelEntries,histories,buckets,row,from,to,level,j)
                if not matched then return nil,why end
                RespecStartLog("HISTORICAL_MULTIFACETED_SKILL_CHANGED level="..level
                    .." previous="..from.." replacement="..to)
            else
                local matches=0
                for _,entry in ipairs(levelEntries) do
                    for k,val in ipairs(entry.skills and entry.skills[field] or {}) do
                        if tostring(val)==from then
                            entry.skills[field][k]=to
                            matches=matches+1
                        end
                    end
                end
                if matches~=1 then return nil,"Skill progression differs at level "..level end
            end
            row[field][j]=to
        elseif kind=="Spell" or kind=="Cantrip" then
            local fromRank,toRank=HistoricalSpellRank(from),HistoricalSpellRank(to)
            if fromRank==nil or toRank==nil or fromRank~=toRank then
                return nil,"Spell rank cannot be verified or does not match the recorded pick"
            end
            if (kind=="Cantrip" and fromRank~=0)
                or (kind=="Spell" and fromRank==0) then
                return nil,"Recorded spell/cantrip category does not match installed spell rank"
            end
            -- Later iterations must not rewrite a spell acquired in another
            -- level or class. The replay swaps matching IDs in saved spellbook
            -- structures, so a repeated source would be ambiguous.
            for priorLevel,prior in ipairs(histories) do
                for _,id in ipairs(HistoricalChosenSpellIds(prior)) do
                    local inverse=nativeSwap and kind=="Spell" and level>1
                        and priorLevel==1 and id==nativeSwap.From
                        and from==nativeSwap.To and to==nativeSwap.Replacement
                    local movingAway=priorLevel~=level and id==to
                        and OriginalSpellWillBeReplaced(priorLevel,id)
                    if not inverse and not movingAway
                        and (id==to or (priorLevel~=level and id==from)) then
                        return nil,"Spell replacement conflicts with another recorded level"
                            .." [spell="..to.." source="..from.." editedLevel="..level
                            .." recordedLevel="..priorLevel.." recordedSpell="..id.."]"
                    end
                end
            end
            for bucketLevel,entries in pairs(buckets) do
                local priorLevel=tonumber(bucketLevel)
                if priorLevel~=level then
                    for _,pastEntry in ipairs(entries or {}) do
                        for _,old in ipairs(pastEntry.spells and pastEntry.spells.AddSpells or {}) do
                            local id=tostring(old.SpellId or old.SpellID or "")
                            local movingAway=id==to
                                and OriginalSpellWillBeReplaced(priorLevel,id)
                            if (id==from or id==to) and not movingAway and not
                                (nativeSwap and kind=="Spell" and level>1
                                    and priorLevel==1 and id==nativeSwap.From
                                    and from==nativeSwap.To and to==nativeSwap.Replacement) then
                                return nil,"Spell provenance is ambiguous across progression levels"
                                    .." [spell="..to.." source="..from.." editedLevel="..level
                                    .." progressionLevel="..tostring(priorLevel).." grant="..id.."]"
                            end
                        end
                    end
                end
            end
            local arr=(source=="Spells") and history.Spells
                or (source=="Upgrades.Spells" and history.Upgrades and history.Upgrades.Spells)
            local row=arr and arr[i]
            if not row then return nil,"Spell history not accessible" end
            local field=row.SpellId and "SpellId" or (row.SpellID and "SpellID")
            local target=field and row or ((row.Spells or {})[j])
            if not field and type(target)=="table" then
                field=target.SpellId and "SpellId" or (target.SpellID and "SpellID")
            end
            local current=type(target)=="table" and target[field] or target
            if tostring(current)~=from then return nil,"Spell choice changed in history" end
            -- A coincidentally matching spell ID could be a fixed class
            -- grant rather than the player's historical selector. Require
            -- the original CCLevelUp spell list to agree with the saved
            -- progression grant before changing the copied snapshot.
            local recordedSpellList=tostring(origin.List or "")
            if recordedSpellList=="" then
                return nil,"Original spell selector list is unavailable; cannot prove acquisition ownership"
            end
            local accordOwned=kind=="Cantrip" and source=="Upgrades.Spells"
                and tostring(history.Feat or "")==HB_ACCORD_FEAT_ID
            if accordOwned then
                local verified,why=PatchVerifiedAccordCantrip(
                    history,levelEntries,row,from,to,level,j)
                if not verified then return nil,why end
            else
                -- BG3 deliberately uses a selector list GUID (CCLevelUp)
                -- distinct from the grant list GUID (ProgressionSpells).
                -- Match by exact history row + same-level progression owner,
                -- not equality of the two unrelated list identifiers.
                if not CanonicalHistoricalSpellRow(history,row,source,kind,level) then
                    return nil,"Learned spell selector lacks verified original row provenance"
                end
                local ownerClass=tostring(row.Class or "")
                local count=0
                for _,entry in ipairs(levelEntries) do
                    for _,spell in ipairs(entry.spells and entry.spells.AddSpells or {}) do
                        if tostring(spell.SpellId or spell.SpellID)==from then
                            local meta=entry.meta
                            if type(spell)~="table" or not meta
                                or tonumber(meta.Level)~=level
                                or tostring(meta.Source or "")~=ownerClass
                                or (tostring(meta.SpellSourceType or "")~="ProgressionSubClass"
                                    and tostring(meta.SpellSourceType or "")~="ProgressionClass")
                                or not StrictRecordedSpellGuid(spell.SpellList) then
                                return nil,"Learned spell progression owner or grant list differs from recorded selector"
                            end
                            spell[spell.SpellId and "SpellId" or "SpellID"]=to
                            count=count+1
                        end
                    end
                end
                if count~=1 then
                    return nil,"Spell is not a uniquely owned same-level learned spell; no edit applied"
                end
            end
            if type(target)=="table" then target[field]=to else row.Spells[j]=to end
            -- Learned spell/prepared spell components are restored from the
            -- snapshot too. Spellbook records sometimes use SPELL IDS AS MAP
            -- KEYS, not only as values. The former algorithm overwrote an
            -- existing `to` entry if both source and target were already
            -- present. Preflight the entire copied structure BEFORE touching
            -- it; fail closed rather than clobber a separately learned spell.
            if not nativeSwap then
            local fields={"spellBook","spellBookPrepares","learnedSpells"}
            local inspected={}
            local function CheckSpellbookMap(root,depth)
                if type(root)~="table" or inspected[root] then return true end
                if depth>16 then return false,"Spellbook structure too deeply nested to edit safely" end
                inspected[root]=true
                if rawget(root,from)~=nil and rawget(root,to)~=nil then
                    return false,"Spellbook already contains both source and replacement; map-key collision"
                end
                for _,v in pairs(root) do
                    if type(v)=="table" then
                        local safe,reason=CheckSpellbookMap(v,depth+1)
                        if not safe then return false,reason end
                    end
                end
                return true
            end
            for _,name in ipairs(fields) do
                local safe,reason=CheckSpellbookMap(patched.components[name],0)
                if not safe then return nil,reason end
            end
            -- Take a stable snapshot of keys/children before rewriting any
            -- map key; mutating a Lua table during pairs() is undefined for
            -- newly inserted keys. A visited set also prevents double-work
            -- when component records share a nested table.
            local converted={}
            local function SwapExact(root,depth)
                if type(root)~="table" or converted[root] or depth>16 then return end
                converted[root]=true
                local valueKeys,children={},{}
                for k,v in pairs(root) do
                    if type(v)=="string" and v==from then
                        valueKeys[#valueKeys+1]=k
                    elseif type(v)=="table" then
                        children[#children+1]=v
                    end
                end
                for _,k in ipairs(valueKeys) do root[k]=to end
                local mapValue=rawget(root,from)
                if mapValue~=nil then
                    root[from]=nil
                    root[to]=mapValue
                end
                for _,child in ipairs(children) do SwapExact(child,depth+1) end
            end
            for _,name in ipairs(fields) do
                SwapExact(patched.components[name],0)
            end
            end -- native spell displacement is deferred until BG3 commits L1
        else
            return nil,"Unsupported selection kind "..kind
        end
    end
    -- Enforce original level-one expertise eligibility against the final
    -- class-owned skill selectors, not against the previous UI state.
    local editedLevelOne=false
    for _,edit in ipairs(edits) do
        if tonumber(edit.Level)==1 then editedLevelOne=true;break end
    end
    if editedLevelOne then
        local first=histories[1]
        local upgrades=first and first.Upgrades or {}
        local proficiencies,expertise={},{}
        for _,row in ipairs(upgrades.Skills or {}) do
            if tonumber(row.Level)==1 and tostring(row.Type)=="Class"
                and tostring(row.Class)==tostring(first.Class) then
                for _,skill in ipairs(row.Proficiencies or {}) do
                    proficiencies[tostring(skill)]=true
                end
            end
        end
        for _,row in ipairs(upgrades.SkillExpertise or {}) do
            if tonumber(row.Level)==1 and tostring(row.Type)=="Class"
                and tostring(row.Class)==tostring(first.Class) then
                for _,skill in ipairs(row.Expertise or {}) do
                    expertise[#expertise+1]=tostring(skill)
                end
            end
        end
        for _,skill in ipairs(expertise) do
            if not proficiencies[skill] then
                return nil,"Level-one Expertise requires a selected skill proficiency: "..skill
            end
        end
    end
    -- The replay can patch several levels in one request. Recheck edited
    -- spell targets against the FINAL historical state, independent of edit
    -- order. Readonly automatic progression grants are not conflated with
    -- recorded player selections.
    local newlyChosenSpells={}
    for _,edit in ipairs(edits) do
        if edit.Kind=="Spell" or edit.Kind=="Cantrip" then
            newlyChosenSpells[tostring(edit.To or "")]=true
        end
    end
    if next(newlyChosenSpells) then
        local counts={}
        for historyLevel,history in ipairs(histories) do
            -- BG3 can mirror one chosen spell in more than one level-up
            -- collection. Count unique choices per level, not serialization
            -- mirrors, while still rejecting a duplicate acquired elsewhere.
            local thisLevel={}
            for _,id in ipairs(HistoricalChosenSpellIds(history)) do
                id=tostring(id)
                if nativeSwap and historyLevel==1 and id==nativeSwap.From then id=nativeSwap.To end
                if newlyChosenSpells[id] then thisLevel[id]=true end
            end
            for id in pairs(thisLevel) do
                counts[id]=(counts[id] or 0)+1
                if counts[id]>1 then
                    return nil,"Spell is duplicated in the final recorded historical choices: "..id
                end
            end
        end
    end
    -- A genuine feat editor also blocks nonrepeatable feats already taken at
    -- an earlier level. The generic historical selector must enforce the same
    -- rule on the SERVER, against the final staged build (not current-level
    -- stats). Check after applying the entire batch so two simultaneous feat
    -- changes cannot bypass it by arriving in a different edit order.
    local editedFeatIds={}
    for _,edit in ipairs(edits) do
        if edit.Kind=="Feat" then editedFeatIds[tostring(edit.To)]=true end
    end
    -- Unrestricted feat transition testing never overrides the native
    -- one-copy restriction: the final staged build must not select a
    -- nonrepeatable feat at multiple character levels.
    if next(editedFeatIds) then
        local occurrences={}
        for level,history in ipairs(histories) do
            local id=history and history.Feat
            if IsValidGuid(id) then
                local key=tostring(id)
                local found=occurrences[key]
                if not found then found={};occurrences[key]=found end
                found[#found+1]=level
            end
        end
        for id in pairs(editedFeatIds) do
            local levels=occurrences[id]
            if levels and #levels>1 then
                local ok,feat=pcall(Ext.StaticData.Get,id,"Feat")
                local repeatable=false
                if ok and feat then
                    local read,value=pcall(function() return feat.CanBeTakenMultipleTimes end)
                    repeatable=read and value==true
                end
                if not repeatable then
                    return nil,"Nonrepeatable feat would appear at multiple historical levels"
                end
            end
        end
    end
    -- Prevent accidentally turning HB Ability Improvement's two passive
    -- ability picks into the same ability. Only enforce uniqueness within
    -- each ACTUALLY RECORDED AbilityBonuses row, never across independent
    -- class and feat upgrades at the same character level.
    for _,edit in ipairs(edits) do
        if edit.Kind=="Ability" then
            local level=tonumber(edit.Level)
            local history=histories[level]
            local rows=history and history.Upgrades and history.Upgrades.AbilityBonuses
            local group=rows and rows[tonumber(edit.EntryIndex)]
            if not group or type(group.Bonuses)~="table" then
                return nil,"Recorded ability-choice group is unavailable"
            end
            local seen={}
            for _,ability in ipairs(group.Bonuses) do
                ability=tostring(ability)
                if seen[ability] then
                    return nil,"Duplicate ability in a recorded historical ability-choice group at level "..level
                end
                seen[ability]=true
            end
        end
    end
    -- Reject selections that create repeats within one progression level's
    -- same-choice group (e.g. a class's two skill or cantrip choices).
    for level,history in ipairs(histories) do
        local seen={}
        for _,choice in ipairs(BuildOtherHistoricalChoices(history,level)) do
            if choice.Kind~="Feat" and choice.Kind~="Ability" then
                local key=table.concat({choice.Kind,choice.List,choice.From},"|")
                if seen[key] then
                    for _,edit in ipairs(edits) do
                        if tonumber(edit.Level)==level and edit.To==choice.From then
                            return nil,"Duplicate "..choice.Kind.." at character level "..level
                        end
                    end
                end
                seen[key]=true
            end
        end
    end
    return patched,nil
end

local function ValidateAndPatchExtraResources(original, edits, maxLevel)
    if type(edits) ~= "table" or #edits == 0 or #edits > maxLevel then
        return nil, "Invalid experimental edit list"
    end
    local patched = CopyPlainTable(original)
    local cc = patched.components and patched.components.ccLevelUp
    local histories = cc and cc.LevelUps
    local buckets = patched.progressions and patched.progressions.buckets
    if not histories or not buckets or #histories < maxLevel then
        return nil, "Missing historical level records"
    end
    local touched = {}
    for _, edit in ipairs(edits) do
        local level = type(edit) == "table" and tonumber(edit.Level)
        local from = type(edit) == "table" and tostring(edit.From)
        local to = type(edit) == "table" and tostring(edit.To)
        if not level or level ~= math.floor(level) or level <= 1 or level > maxLevel
            or touched[level] or not VALID_EXTRA_RESOURCES[from]
            or not VALID_EXTRA_RESOURCES[to] or from == to then
            return nil, "Invalid selection or duplicate level in edit"
        end
        touched[level] = true
        local upgrades = histories[level] and histories[level].Upgrades
        local selections = upgrades and upgrades.Passives
        local oldCount = 0
        for _, selection in ipairs(selections or {}) do
            if tostring(selection.SelectorId or "") == "ExtraActions" then
                for idx, id in ipairs(selection.Passives or {}) do
                    if tostring(id) == from then
                        selection.Passives[idx] = to
                        oldCount = oldCount + 1
                    end
                end
            end
        end
        if oldCount ~= 1 then
            return nil, "History not a unique Extra Resource choice at level " .. level
        end
        local bucketsAtLevel = buckets[level]
        local progressionMatches = 0
        for _, entry in ipairs(bucketsAtLevel or {}) do
            local component = entry.passives
            for index, id in ipairs(component and component.AddPassives or {}) do
                if tostring(id) == from then
                    component.AddPassives[index] = to
                    progressionMatches = progressionMatches + 1
                end
            end
        end
        if progressionMatches ~= 1 then
            return nil, "Progression mismatch at level " .. level .. " (" .. progressionMatches .. " matches)"
        end
    end
    -- Reject resources already chosen at another level; include staged swaps.
    local counts = {}
    for _, history in ipairs(histories) do
        for _, selection in ipairs(history.Upgrades and history.Upgrades.Passives or {}) do
            if tostring(selection.SelectorId or "") == "ExtraActions" then
                for _, id in ipairs(selection.Passives or {}) do
                    local key = tostring(id)
                    if VALID_EXTRA_RESOURCES[key] then
                        counts[key] = (counts[key] or 0) + 1
                        if counts[key] > 1 then
                            return nil, "Extra Resource already selected elsewhere: " .. key
                        end
                    end
                end
            end
        end
    end
    return patched, nil
end

-- Validate an arbitrary number of staged class/maneuver/other passive swaps.
-- Exact selector/list/old-pick provenance must match the saved level-up history.
-- Candidate membership is always rechecked server-side against PassiveList.
-- The entire patch is applied to a deep copy, never the source snapshot.
local function ValidateAndPatchClassPassives(original, edits, maxLevel, nativeFirstLevelPending)
    if type(edits) ~= "table" or #edits == 0 or #edits > 128 then
        return nil, "Invalid passive edit list"
    end
    local patched = CopyPlainTable(original)
    local histories = patched.components and patched.components.ccLevelUp and patched.components.ccLevelUp.LevelUps
    local buckets = patched.progressions and patched.progressions.buckets
    if not histories or not buckets or #histories < maxLevel then
        return nil, "Missing level history or progression buckets"
    end
    local touched = {}
    local pendingHistory, pendingProgression = {}, {}
    for _, edit in ipairs(edits) do
        if type(edit) ~= "table" then return nil, "Invalid passive edit record" end
        local level = tonumber(edit.Level)
        local selector, listGuid = tostring(edit.SelectorId or ""), tostring(edit.PassiveList or "")
        local from, to = tostring(edit.From or ""), tostring(edit.To or "")
        local list = ResolvePassiveList(listGuid)
        local recordedHistory=level and histories[level]
        local blankAbilitySelector=selector=="" and recordedHistory
            and HBFeatXmlRule(recordedHistory.Feat)
            and HBFeatXmlRule(recordedHistory.Feat).Kind=="AbilityChoices"
            and listGuid==HB_ABILITY_IMPROVEMENT_LIST
        local blankElementSelector=selector=="" and recordedHistory
            and HBFeatXmlRule(recordedHistory.Feat)
            and HBFeatXmlRule(recordedHistory.Feat).Kind=="ElementChoices"
            and listGuid==HB_ELEMENTAL_ADEPT_LIST
        local pairRule=recordedHistory and HB_PASSIVE_PAIR_FEATS[tostring(recordedHistory.Feat or "")]
        local blankPairSelector=selector=="" and pairRule and pairRule.List==listGuid
        if not level or level ~= math.floor(level) or level < 1 or level > maxLevel
            or (selector == "" and not blankElementSelector and not blankAbilitySelector
                and not blankPairSelector)
            or EDITOR_PROTECTED_SELECTORS[selector]
            or from == "" or from == to or not list or not list.Set[to] or not list.Set[from] then
            return nil, "Unavailable or invalid passive choice at character level " .. tostring(level)
        end
        local key = tostring(level) .. "|" .. selector .. "|" .. listGuid .. "|" .. from
        if touched[key] then return nil, "Same passive edited more than once: " .. from end
        touched[key] = true

        -- Level one does not use the ordinary level-up allocation pipeline.
        -- Only allow a passive replacement if an ACTUAL level-one history and
        -- progression entity survive; no class, subclass, ancestry or feat
        -- upgrades may be reconstructed from current stats.
        if level==1 then
            if not recordedHistory or not recordedHistory.Upgrades
                or IsValidGuid(recordedHistory.Feat) then
                return nil,"Original level-one passive history is unavailable or feat-owned"
            end
            if selector=="" then
                return nil,"Level-one passive requires a recorded named selector"
            end
        end
        local matchCount, oldCount = 0, 0
        local selectedOwnerSource,selectedOwnerRole=nil,nil
        for _, selection in ipairs(histories[level].Upgrades and histories[level].Upgrades.Passives or {}) do
            if tostring(selection.SelectorId or "") == selector
                and tostring(selection.PassiveList or "") == listGuid then
                matchCount = matchCount + 1
                if level==1 then
                    local role=tostring(selection.Type or "")
                    local source=tostring(selection.Class or "")
                    if tonumber(selection.Level)~=1 or not
                        ((role=="Class" and source==tostring(recordedHistory.Class or ""))
                        or (role=="SubClass" and source==tostring(recordedHistory.SubClass or ""))) then
                        return nil,"Level-one passive must belong to the original class/subclass"
                    end
                    selectedOwnerSource,selectedOwnerRole=source,role
                end
                if selection.ReplacePassives and #selection.ReplacePassives > 0 then
                    return nil, "Passive replacement selector unsupported at level " .. level
                end
                for index, id in ipairs(selection.Passives or {}) do
                    if tostring(id) == from then
                        pendingHistory[#pendingHistory+1] = {selection.Passives, index, to}
                        oldCount = oldCount + 1
                    end
                end
            end
        end
        if matchCount ~= 1 or oldCount ~= 1 then
            return nil, "Recorded selector or passive differs at character level " .. level
        end
        -- Secondary passives granted by a feat can be owned by the
        -- ProgressionFeat component rather than ProgressionPassives. A normal
        -- class passive must keep using the previously verified progression
        -- path. Only the exact CCLevelUp.Feat owner at THIS level may be
        -- modified; never infer ownership merely from the level number.
        local foundProgression, featOwned, foreignFeatOwners = 0, {feat=0,replicatedFeat=0}, 0
        local featId=tostring(histories[level].Feat or "")
        local featPatches={}
        for _, entry in ipairs(buckets[level] or {}) do
            local component = entry.passives
            for index, id in ipairs(component and component.AddPassives or {}) do
                if tostring(id) == from then
                    pendingProgression[#pendingProgression+1] = {component.AddPassives, index, to}
                    foundProgression = foundProgression + 1
                end
            end
            for _, keyName in ipairs({"feat", "replicatedFeat"}) do
                local owner=entry[keyName]
                local ids=owner and owner.AddPassives
                if type(ids)=="table" then
                    for index,id in ipairs(ids) do
                        if tostring(id)==from then
                            if IsValidGuid(featId) and tostring(owner.Feat or "")==featId then
                                featOwned[keyName]=featOwned[keyName]+1
                                featPatches[#featPatches+1]={ids,index,to}
                            else
                                foreignFeatOwners=foreignFeatOwners+1
                            end
                        elseif tostring(id)==to and tostring(owner.Feat or "")==featId then
                            return nil,"Replacement is already granted by the historical feat"
                        end
                    end
                end
            end
        end
        if level==1 then
            if foundProgression~=1 or #featPatches>0 or foreignFeatOwners>0 then
                return nil,"Level-one passive lacks one exclusively owned progression grant"
            end
            local exactOwners=0
            for _,entry in ipairs(buckets[level] or {}) do
                local ids=entry.passives and entry.passives.AddPassives or {}
                for _,id in ipairs(ids) do
                    if tostring(id)==from then
                        local meta=entry.meta
                        if type(meta)~="table" or tonumber(meta.Level)~=1
                            or tostring(meta.SpellSourceType or "")~=
                                (selectedOwnerRole=="Class" and "ProgressionClass"
                                    or "ProgressionSubClass")
                            or tostring(meta.Source or "")~=tostring(selectedOwnerSource or "")
                            or tostring(meta.Progression or "")=="" then
                            return nil,"Level-one passive progression metadata does not prove class ownership"
                        end
                        exactOwners=exactOwners+1
                    end
                end
            end
            if exactOwners~=1 then
                return nil,"Level-one passive grant cannot be attributed uniquely"
            end
        end
        if foreignFeatOwners>0 or featOwned.feat>1 or featOwned.replicatedFeat>1 then
            return nil,"Ambiguous feat-owned passive at character level "..level
        end
        local directFeatOwner=featOwned.feat+featOwned.replicatedFeat>0
        -- A recorded mixed-feat passive must not silently fall through to
        -- class progression editing when its owning feat component is
        -- missing/corrupt. Failing closed is essential for package safety.
        local levelFeatRule=HBFeatXmlRule(featId)
        if levelFeatRule and levelFeatRule.Kind=="MixedChoices"
            and not directFeatOwner then
            return nil,"Mixed-feat passive ownership cannot be proven"
        end
        if directFeatOwner then
            local rule=HBFeatXmlRule(featId)
            if not rule or (rule.Kind~="PassiveChoices" and rule.Kind~="ElementChoices"
                and rule.Kind~="AbilityChoices" and rule.Kind~="MixedChoices"
                and rule.Kind~="SubclassGrant") then
                return nil,"Feat-owned passive selector has unverified HB choice rules at level "..level
            end
            -- Never let a generic blank-selector edit through this path.
            -- Elemental Adept must retain exactly two distinct historical
            -- elements in the verified HB element list and exact feat owner.
            if rule.Kind=="ElementChoices" then
                local matchingRows=0
                for _,row in ipairs(histories[level].Upgrades.Passives or {}) do
                    if IsRecordedElementalAdeptRow(histories[level],row) then
                        matchingRows=matchingRows+1
                    end
                end
                if selector~="" or listGuid~=HB_ELEMENTAL_ADEPT_LIST
                    or matchingRows~=1 or not tostring(to):match("^ElementalAdept_[%a]+$") then
                    return nil,"Elemental Adept historical elements lack exact two-slot provenance at level "..level
                end
            end
            if rule.Kind=="MixedChoices" then
                if featId~="be0889d2-f9aa-472d-b942-592bff0f1ef3" then
                    return nil,"Unknown mixed feat passive package"
                end
                local selectedSkills,skillCount={},0
                for _,skillRow in ipairs(histories[level].Upgrades.Skills or {}) do
                    if tostring(skillRow.Type or "")=="Feat"
                        or tostring(skillRow.Class or "")==featId then
                        if tostring(skillRow.Type or "")~="Feat"
                            or tostring(skillRow.Class or "")~=featId then
                            return nil,"Multifaceted mixed package has foreign skill ownership"
                        end
                        for _,id in ipairs(skillRow.Proficiencies or {}) do
                            id=tostring(id)
                            if selectedSkills[id] or id=="" then
                                return nil,"Multifaceted has incomplete skill package"
                            end
                            selectedSkills[id]=true;skillCount=skillCount+1
                        end
                    end
                end
                if skillCount~=4 then
                    return nil,"Multifaceted archetype/trait requires four recorded feat skills"
                end
                if featOwned.feat~=1 or foundProgression~=1 then
                    return nil,"Multifaceted archetype/trait passive grants lack exact primary and progression ownership"
                end
            end
            if rule.Kind=="SubclassGrant" then
                -- Only edit two selections already granted by this exact
                -- Yokebreaker. The existing feat GUID and conditional
                -- subclass package (ConditionId, etc.) are not rewritten.
                -- Selector/list membership was verified against the static
                -- passive list via origin.Options above.
                if selector=="" or not IsValidGuid(listGuid)
                    or featOwned.feat~=1 or featOwned.replicatedFeat~=0
                    or foundProgression~=1 then
                    return nil,"Yokebreaker secondary passives lack verified package ownership"
                end
                local ownedRows=0
                for _,secondary in ipairs(histories[level].Upgrades.Passives or {}) do
                    if tostring(secondary.Type or "")=="Feat"
                        or tostring(secondary.Class or "")==featId then
                        if tostring(secondary.Type or "")~="Feat"
                            or tostring(secondary.Class or "")~=featId
                            or tostring(secondary.SelectorId or "")~=selector
                            or tostring(secondary.PassiveList or "")~=listGuid
                            or #(secondary.Passives or {})~=2
                            or next(secondary.ReplacePassives or {})~=nil then
                            return nil,"Yokebreaker feat-owned passive package is not a canonical two-choice selector"
                        end
                        ownedRows=ownedRows+1
                    end
                end
                if ownedRows~=1 then
                    return nil,"Yokebreaker requires one uniquely owned two-passive selector"
                end
            end
            if rule.Kind=="AbilityChoices" then
                local matchingRows=0
                for _,row in ipairs(histories[level].Upgrades.Passives or {}) do
                    if IsRecordedAbilityImprovementRow(histories[level],row) then
                        matchingRows=matchingRows+1
                    end
                end
                if (selector~="" and selector~="FeatASI") or listGuid~=HB_ABILITY_IMPROVEMENT_LIST
                    or matchingRows~=1 or not HB_ABILITY_IMPROVEMENT_IDS[to] then
                    return nil,"Ability Improvement lacks verified two-slot feat-owned history at level "..level
                end
            end
            if rule.Kind=="PassiveChoices" then
                local config=HB_PASSIVE_PAIR_FEATS[featId]
                local matched=0
                for _,row in ipairs(histories[level].Upgrades.Passives or {}) do
                    if IsRecordedPassivePairRow(histories[level],row) then matched=matched+1 end
                end
                if not config or config.List~=listGuid or (matched~=1 and matched~=2) then
                    return nil,"Class Specialist feat ownership or selector is not verified at level "..level
                end
            end
            local featIds={}
            for _,entry in ipairs(buckets[level] or {}) do
                for _,keyName in ipairs({"feat","replicatedFeat"}) do
                    local record=entry[keyName]
                    if record and tostring(record.Feat or "")==featId then
                        for _,id in ipairs(record.AddPassives or {}) do
                            id=tostring(id)
                            featIds[id]=true
                        end
                    end
                end
            end
            local selectedIds={}
            local count=0
            for _,selection in ipairs(histories[level].Upgrades and histories[level].Upgrades.Passives or {}) do
                for _,id in ipairs(selection.Passives or {}) do
                    id=tostring(id)
                    if featIds[id] then
                        if selectedIds[id] then
                            return nil,"Duplicated feat-owned historical selection at level "..level
                        end
                        selectedIds[id]=true
                        count=count+1
                    end
                end
            end
            if count~=2 then
                return nil,"Feat requires two verified passive slots at level "..level
            end
            if rule.Kind=="MixedChoices" then
                -- Reject unidentified extra passive effects. A two-selector
                -- Multifaceted variant can reuse the standard passive replay,
                -- but only if its primary feat owns EXACTLY these two picks.
                local featCount=0
                local historicallySelected={}
                for _,selection in ipairs(histories[level].Upgrades.Passives or {}) do
                    for _,id in ipairs(selection.Passives or {}) do
                        historicallySelected[tostring(id)]=true
                    end
                end
                for id in pairs(featIds) do
                    featCount=featCount+1
                    if not historicallySelected[id] then
                        return nil,"Multifaceted has an unattributed historical feat passive"
                    end
                end
                if featCount~=2 then
                    return nil,"Multifaceted archetype and trait are not exclusively attributable"
                end
            end
            if rule.Kind=="AbilityChoices" then
                local featCount=0
                for id in pairs(featIds) do
                    featCount=featCount+1
                    if not HB_ABILITY_IMPROVEMENT_IDS[id] or not list.Set[id] then
                        return nil,"Ability Improvement has unrelated feat passives at level "..level
                    end
                end
                if featCount~=2 then
                    return nil,"Ability Improvement has incomplete saved feat effect provenance at level "..level
                end
            end
            if rule.Kind=="ElementChoices" then
                local featCount=0
                for id in pairs(featIds) do
                    featCount=featCount+1
                    if not tostring(id):match("^ElementalAdept_[%a]+$") or not list.Set[id] then
                        return nil,"Elemental Adept feat has an unexpected passive effect at level "..level
                    end
                end
                if featCount~=2 then
                    return nil,"Elemental Adept feat does not have exactly two recorded effects at level "..level
                end
            end
        end
        -- Both component forms may exist for a single feat pick. Update
        -- both when present. A feat-only pick is also safe when its source
        -- matches the exact recorded feat once. No component means no edit.
        if foundProgression>1 or (foundProgression==0 and not directFeatOwner) then
            return nil,"Expected one progression or verified feat passive at level "..level
        end
        for _,patch in ipairs(featPatches) do
            pendingProgression[#pendingProgression+1]=patch
        end
    end
    for _, change in ipairs(pendingHistory) do change[1][change[2]] = change[3] end
    for _, change in ipairs(pendingProgression) do change[1][change[2]] = change[3] end
    -- Check the FINAL combined result, including non-edited later levels and
    -- other passive groups. A swap cannot create a duplicate at any level.
    local firstOccurrence = {}
    for level, history in ipairs(histories) do
        for _, selection in ipairs(history.Upgrades and history.Upgrades.Passives or {}) do
            for _, id in ipairs(selection.Passives or {}) do
                id = tostring(id)
                if firstOccurrence[id] then
                    for _, edit in ipairs(edits) do
                        if tostring(edit.To) == id then
                            -- In the native-first-level slider, BG3 may have
                            -- already removed the ORIGINAL level-one pick.
                            -- Defer that one possible stale collision until
                            -- its new CCLevelUp is committed and inspected.
                            -- Never defer a real level 2+ duplicate.
                            local staleFirst=(nativeFirstLevelPending==true and level>=2
                                and firstOccurrence[id]==1)
                            if not staleFirst then
                                return nil, ("%s already selected at character level %d"):format(id, firstOccurrence[id])
                            end
                        end
                    end
                else
                    firstOccurrence[id] = level
                end
            end
        end
    end
    return patched, nil
end

-- Record what the engine actually serialized for feats and their same-level
-- secondary choice history. Diagnostic only: these upgrades can be granted
-- independently by class/subclass progression, so do not assume they belong
-- to a feat or infer any currently missing allocation.
SaveHistoricalFeatSecondaryAudit = function(characterGuid, snapshot, maxLevel)
    local ok,err=pcall(function()
        local histories=snapshot.components and snapshot.components.ccLevelUp
            and snapshot.components.ccLevelUp.LevelUps or {}
        local buckets=snapshot.progressions and snapshot.progressions.buckets or {}
        local rows={}
        -- Scan feat-description metadata only once per Confirm, not once
        -- for every feat level; avoid stalling the native Confirm callback.
        local linkedDescriptions={}
        local descriptionOK,descriptionIds=pcall(Ext.StaticData.GetAll,"FeatDescription")
        if descriptionOK and type(descriptionIds)=="table" then
            for _,descriptionId in ipairs(descriptionIds) do
                local got,desc=pcall(Ext.StaticData.Get,descriptionId,"FeatDescription")
                if got and desc and desc.FeatId then
                    local id=tostring(desc.FeatId)
                    local list=linkedDescriptions[id]
                    if not list then list={};linkedDescriptions[id]=list end
                    list[#list+1]={
                        RecordId=tostring(descriptionId),
                        DisplayNameHandle=TranslatedDisplayNameHandle(desc.DisplayName),
                        DescriptionHandle=TranslatedDisplayNameHandle(desc.Description),
                    }
                end
            end
        end
        -- Snapshot provenance directly. BuildOtherHistoricalChoices would
        -- enumerate every installed feat candidate again for each feat level,
        -- even though the audit needs ONLY the choices actually recorded.
        local function RecordedChoiceRows(history)
            local result={}
            local function Add(kind,value,source,i,j,list)
                local id=tostring(value or "")
                if id=="" or #result>=200 then return end
                result[#result+1]={Kind=kind,RecordedId=id,Source=source,
                    List=tostring(list or ""),EntryIndex=i,SlotIndex=j,
                    AttributableToFeat=false}
            end
            local upgrades=history.Upgrades or {}
            for i,row in ipairs(upgrades.AbilityBonuses or {}) do
                for j,id in ipairs(row.Bonuses or {}) do
                    Add("Ability",id,"AbilityBonuses",i,j,row.AbilityBonus)
                end
            end
            for _,spec in ipairs({
                {"Skills","Proficiencies","Skill"},
                {"SkillExpertise","Expertise","Expertise"},
            }) do
                for i,row in ipairs(upgrades[spec[1]] or {}) do
                    for j,id in ipairs(row[spec[2]] or {}) do
                        Add(spec[3],id,spec[1],i,j,row.Skill)
                    end
                end
            end
            for i,row in ipairs(upgrades.Passives or {}) do
                for j,id in ipairs(row.Passives or {}) do
                    Add("Passive",id,"Upgrades.Passives",i,j,row.PassiveList or row.SelectorId)
                end
            end
            local function CollectSpells(array,source)
                for i,row in ipairs(array or {}) do
                    if type(row)=="string" then Add("Spell",row,source,i,1,"")
                    elseif type(row)=="table" then
                        local list=row.SpellList or row.SpellListId or row.SpellListID
                        local kind=tostring(row.SelectorId or ""):lower():find("cantrip",1,true)
                            and "Cantrip" or "Spell"
                        if row.SpellId or row.SpellID then
                            Add(kind,row.SpellId or row.SpellID,source,i,1,list)
                        else
                            for j,item in ipairs(row.Spells or {}) do
                                local id=type(item)=="table" and (item.SpellId or item.SpellID) or item
                                Add(kind,id,source,i,j,list)
                            end
                        end
                    end
                end
            end
            CollectSpells(history.Spells,"Spells")
            CollectSpells(upgrades.Spells,"Upgrades.Spells")
            return result
        end
        for level=1,maxLevel do
            local history=histories[level]
            if history and IsValidGuid(history.Feat) then
                local featId=tostring(history.Feat)
                local valid,static=pcall(Ext.StaticData.Get,featId,"Feat")
                local selectors,requirements=nil,nil
                if valid and static then
                    local function Describe(field)
                        local got,value=pcall(function() return static[field] end)
                        if not got or value==nil then return {Present=false} end
                        if type(value)=="string" then
                            return {Present=value:match("%S")~=nil,Text=value:sub(1,1200)}
                        end
                        if type(value)=="table" then
                            local count=0
                            for _ in pairs(value) do count=count+1 end
                            return {Present=count>0,Count=count,Kind="table"}
                        end
                        return {Present=tostring(value)~="",Kind=type(value)}
                    end
                    selectors=Describe("Selectors")
                    requirements=Describe("Requirements")
                end
                local upgrades=history.Upgrades or {}
                local xmlRule=HBFeatXmlRule(featId)
                local expectedSecondary=xmlRule and ({
                    AbilityChoices={Abilities=2},
                    CantripChoices={Cantrips=2},
                    PassiveChoices={ClassPassives=2},
                    ElementChoices={DamageTypes=2},
                    MixedChoices={Archetype=1,Trait=1,Skills=4},
                    SubclassGrant={FeatVariant=1},
                })[xmlRule.Kind] or nil
                local descriptions=linkedDescriptions[featId] or {}
                local associatedChoiceRows=RecordedChoiceRows(history)
                local verifiedPassiveSlots=0
                local candidateSpellSlots,candidateSkillSlots=0,0
                -- Additional nondestructive observations for Accord cantrips
                -- and Multifaceted skills. Same-level matches are evidence,
                -- NEVER an instruction to replay the spell/skill or proof
                -- of exclusive feat ownership without the saved CC row.
                local function MatchRecordedGrant(grants,id,field)
                    if type(grants)~="table" then return 0 end
                    local matches=0
                    for _,record in ipairs(grants) do
                        local value=record
                        if type(record)=="table" then
                            -- Unknown nested records stay unmatched. Never
                            -- infer a feat-owned skill from an arbitrary key.
                            value=field and (record[field]
                                or (field=="SpellId" and record.SpellID)) or nil
                        end
                        if value~=nil and tostring(value)==id then
                            matches=matches+1
                        end
                    end
                    return matches
                end
                for _,choiceRow in ipairs(associatedChoiceRows) do
                    if choiceRow.Kind=="Passive" then
                        local from=tostring(choiceRow.RecordedId)
                        local matchingPrimary,matchingReplica,foreignFeat,normalProgression=0,0,0,0
                        for _,entry in ipairs(buckets[level] or {}) do
                            for _,keyName in ipairs({"feat","replicatedFeat"}) do
                                local feat=entry[keyName]
                                for _,id in ipairs(feat and feat.AddPassives or {}) do
                                    if tostring(id)==from then
                                        if tostring(feat.Feat or "")==featId then
                                            if keyName=="feat" then
                                                matchingPrimary=matchingPrimary+1
                                            else matchingReplica=matchingReplica+1 end
                                        else
                                            foreignFeat=foreignFeat+1
                                        end
                                    end
                                end
                            end
                            for _,id in ipairs(entry.passives and entry.passives.AddPassives or {}) do
                                if tostring(id)==from then normalProgression=normalProgression+1 end
                            end
                        end
                        choiceRow.FeatOwnerEvidence={MatchingPrimaryFeatComponents=matchingPrimary,
                            MatchingReplicatedFeatComponents=matchingReplica,
                            ForeignFeatComponents=foreignFeat,
                            NormalProgressionComponents=normalProgression}
                        choiceRow.AttributableToFeat=matchingPrimary<=1 and matchingReplica<=1
                            and matchingPrimary+matchingReplica>0 and foreignFeat==0
                        if choiceRow.AttributableToFeat then
                            verifiedPassiveSlots=verifiedPassiveSlots+1
                        end
                    elseif choiceRow.Kind=="Cantrip" or choiceRow.Kind=="Spell"
                        or choiceRow.Kind=="Skill" or choiceRow.Kind=="Expertise" then
                        local id=tostring(choiceRow.RecordedId or "")
                        local isSpell=choiceRow.Kind=="Cantrip" or choiceRow.Kind=="Spell"
                        local componentField=isSpell and "AddSpells"
                            or (choiceRow.Kind=="Expertise" and "Expertise" or "Proficiencies")
                        local entryField=isSpell and "spells" or "skills"
                        local matchField=isSpell and "SpellId" or nil
                        local primary,replica,foreign,normal=0,0,0,0
                        for _,entry in ipairs(buckets[level] or {}) do
                            for _,keyName in ipairs({"feat","replicatedFeat"}) do
                                local record=entry[keyName]
                                local matched=MatchRecordedGrant(record and record[componentField],id,matchField)
                                if record and tostring(record.Feat or "")==featId then
                                    if keyName=="feat" then primary=primary+matched
                                    else replica=replica+matched end
                                else foreign=foreign+matched end
                            end
                            normal=normal+MatchRecordedGrant(entry[entryField]
                                and entry[entryField][componentField],id,matchField)
                        end
                        choiceRow.FeatOwnerEvidence={MatchingPrimaryFeatComponents=primary,
                            MatchingReplicatedFeatComponents=replica,
                            ForeignFeatComponents=foreign,
                            NormalProgressionComponents=normal}
                        -- This is not a verified editable slot: feat-owned
                        -- cantrips/skills require a natural serialization
                        -- example and an independent exact replay validator.
                        choiceRow.StructuralOwnerCandidate=primary==1
                            and replica<=1 and foreign==0
                        if choiceRow.StructuralOwnerCandidate then
                            if isSpell then candidateSpellSlots=candidateSpellSlots+1
                            else candidateSkillSlots=candidateSkillSlots+1 end
                        end
                    end
                end
                local components={}
                for index,entry in ipairs(buckets[level] or {}) do
                    components[#components+1]={Index=index,
                        FeatId=entry.feat and tostring(entry.feat.Feat or "") or nil,
                        ReplicatedFeatId=entry.replicatedFeat
                            and tostring(entry.replicatedFeat.Feat or "") or nil,
                        AbilityImprovements=entry.abilityImprovements
                            and entry.abilityImprovements.AbilityImprovements or nil,
                        FeatAbilityImprovements=entry.feat
                            and entry.feat.AbilityImprovements or nil,
                        FeatPassives=entry.feat and entry.feat.AddPassives or nil,
                        FeatSpells=entry.feat and entry.feat.AddSpells or nil,
                        ReplicatedFeatPassives=entry.replicatedFeat
                            and entry.replicatedFeat.AddPassives or nil,
                        ReplicatedFeatSpells=entry.replicatedFeat
                            and entry.replicatedFeat.AddSpells or nil,
                        ReplicatedFeatAbilityImprovements=entry.replicatedFeat
                            and entry.replicatedFeat.AbilityImprovements or nil,
                        NormalProgressionAbilityImprovements=entry.abilityImprovements
                            and entry.abilityImprovements.AbilityImprovements or nil,
                        NormalProgressionSkills=entry.skills and entry.skills or nil,
                        NormalProgressionPassives=entry.passives and entry.passives.AddPassives or nil,
                        NormalProgressionSpells=entry.spells and entry.spells or nil,
                        FeatProficiencies=entry.feat and entry.feat.Proficiencies or nil,
                        FeatExpertise=entry.feat and entry.feat.Expertise or nil,
                        ReplicatedFeatProficiencies=entry.replicatedFeat
                            and entry.replicatedFeat.Proficiencies or nil,
                        ReplicatedFeatExpertise=entry.replicatedFeat
                            and entry.replicatedFeat.Expertise or nil,
                        ProgressionMeta=entry.meta or nil}
                end
                -- Generic read-only package manifest: classify the exact
                -- components owned by THIS feat. Never infer grants from
                -- same-level class components or treat this inventory as
                -- permission to create/destroy a progression entity.
                local packageInventory={Version=2,Source="recorded progression",
                    ReplayEnabled=false,Primary={},Replicated={},
                    UnattributedSameLevel={},SelectionRows={}}
                local function PrimitiveIDs(value,kind)
                    local ids={}
                    if value~=nil and type(value)~="table" then
                        return {"[UNVERIFIED:"..kind.."]"}
                    end
                    for _,record in ipairs(value or {}) do
                        local id=type(record)=="table" and
                            (record.SpellId or record.SpellID or record.PassiveId)
                            or record
                        if type(id)=="string" and id~="" then
                            ids[#ids+1]=id
                        else
                            -- A structured grant needs a separate decoder;
                            -- never silently discard it when assessing safety.
                            ids[#ids+1]="[STRUCTURED:"..kind.."]"
                        end
                    end
                    return ids
                end
                local function GrantSummary(owner)
                    if type(owner)~="table" then return nil end
                    -- Include exact unknown/conditional component VALUES in a
                    -- read-only inventory. The previous report gave only keys
                    -- (for example ConditionId on a Yokebreaker feat), which
                    -- could never prove whether a package was safe to remove.
                    -- Export scalar evidence only; do not serialize live C++
                    -- userdata or turn this inventory into replay permission.
                    local opaque={}
                    local known={Feat=true,AddPassives=true,RemovePassives=true,
                        AddSpells=true,RemoveSpells=true,Proficiencies=true,
                        Expertise=true,AbilityImprovements=true}
                    for key,value in pairs(owner) do
                        if not known[key] then
                            local kind=type(value)
                            local scalar
                            if kind=="string" or kind=="number" or kind=="boolean" then
                                scalar=tostring(value):sub(1,256)
                            elseif kind=="nil" then
                                scalar="[nil]"
                            else
                                scalar="[STRUCTURED:"..kind.."]"
                            end
                            opaque[tostring(key)]=scalar
                        end
                    end
                    return {Passives=PrimitiveIDs(owner.AddPassives,"passive"),
                        RemovedPassives=PrimitiveIDs(owner.RemovePassives,"passive"),
                        Spells=PrimitiveIDs(owner.AddSpells,"spell"),
                        RemovedSpells=PrimitiveIDs(owner.RemoveSpells,"spell"),
                        Skills=PrimitiveIDs(owner.Proficiencies,"skill"),
                        Expertise=PrimitiveIDs(owner.Expertise,"expertise"),
                        AbilityEffects=owner.AbilityImprovements,
                        OtherComponentValues=opaque,
                        OtherComponentKeys=(function()
                            local extra={}
                            for key in pairs(owner) do
                                if key~="Feat" and key~="AddPassives" and key~="RemovePassives"
                                    and key~="AddSpells" and key~="RemoveSpells"
                                    and key~="Proficiencies" and key~="Expertise"
                                    and key~="AbilityImprovements" then extra[#extra+1]=tostring(key) end
                            end
                            table.sort(extra)
                            return extra
                        end)()}
                end
                for entryIndex,entry in ipairs(buckets[level] or {}) do
                    for _,name in ipairs({"feat","replicatedFeat"}) do
                        local owner=entry[name]
                        if owner and tostring(owner.Feat or "")==featId then
                            local family=name=="feat" and "Primary" or "Replicated"
                            packageInventory[family][#packageInventory[family]+1]={
                                Entry=entryIndex,Grants=GrantSummary(owner),Meta=entry.meta}
                        elseif owner then
                            packageInventory.UnattributedSameLevel[#packageInventory.UnattributedSameLevel+1]={
                                Entry=entryIndex,Family=name,FeatId=tostring(owner.Feat or "")}
                        end
                    end
                end
                packageInventory.RecordedSkillCatalogs={}
                local skillListSeen={}
                local packageRestrictions={}
                for _,row in ipairs(associatedChoiceRows) do
                    packageInventory.SelectionRows[#packageInventory.SelectionRows+1]={
                        Kind=row.Kind,RecordedId=row.RecordedId,
                        FeatOwnerEvidence=row.FeatOwnerEvidence,
                        AttributableToFeat=row.AttributableToFeat}
                    if (row.Kind=="Skill" or row.Kind=="Expertise") and row.List then
                        local listId=tostring(row.List)
                        if not skillListSeen[listId] then
                            skillListSeen[listId]=true
                            local candidates=RecordedListOptions(listId,"SkillList","Skills")
                            -- Only report the candidates from this ORIGINAL
                            -- saved skill-list GUID. Never substitute every
                            -- skill as an editable feat option.
                            packageInventory.RecordedSkillCatalogs[#packageInventory.RecordedSkillCatalogs+1]={
                                List=listId,ResolvedCount=#candidates,Candidates=candidates}
                            if #candidates==0 then
                                packageRestrictions[#packageRestrictions+1]=
                                    "Unresolved original feat skill list "..listId
                            end
                        end
                    end
                end
                for _,record in ipairs(packageInventory.Primary) do
                    local grant=record.Grants or {}
                    if grant.OtherComponentValues and grant.OtherComponentValues.ConditionId then
                        packageRestrictions[#packageRestrictions+1]=
                            "Conditional feat grant requires independent replay provenance"
                    end
                    for _,id in ipairs(grant.Skills or {}) do
                        if tostring(id):find("[STRUCTURED:",1,true) then
                            packageRestrictions[#packageRestrictions+1]=
                                "Structured skill grant requires an exact selector decoder"
                            break
                        end
                    end
                end
                packageInventory.UnverifiedReplayReasons=packageRestrictions
                rows[#rows+1]={Level=level,FeatId=featId,
                    PackageGrantInventory=packageInventory,
                    StaticAvailable=valid and static~=nil,
                    HBRuleKind=xmlRule and xmlRule.Kind or nil,
                    HBRuleText=xmlRule and xmlRule.Choices or nil,
                    RecordedUpgradeFamilies={
                        AbilityBonuses=upgrades.AbilityBonuses or {},
                        Skills=upgrades.Skills or {},
                        SkillExpertise=upgrades.SkillExpertise or {},
                        Spells=upgrades.Spells or {},
                        Passives=upgrades.Passives or {},
                    },
                    HBExpectedChoiceCounts=expectedSecondary,
                    LinkedDescriptions=descriptions,
                    SameLevelChoiceRows=associatedChoiceRows,
                    FeatChoiceOwnerVerified=false,
                    VerifiedFeatPassiveSlots=verifiedPassiveSlots,
                    CandidateSpellSlots=candidateSpellSlots,
                    CandidateSkillSlots=candidateSkillSlots,
                    SourceDefinitionFlags=HB_SOURCE_FEAT_CONTRACTS[featId:lower()],
                    Selectors=selectors,Requirements=requirements,
                    RecordedAbilityBonuses=upgrades.AbilityBonuses,
                    RecordedSkills=upgrades.Skills,
                    RecordedSkillExpertise=upgrades.SkillExpertise,
                    RecordedSpells=upgrades.Spells,
                    RecordedPassives=upgrades.Passives,
                    Components=components}
            end
        end
        local json=Ext.Json.Stringify({Version=8,CharacterGuid=characterGuid,
            EvidenceMode="Read-only snapshot, also available on opening the respec menu",
            Warning="Source definitions and same-level spell/skill matches are observations, NOT proof of historical feat ownership. Unverified secondary spell/skill replay remains disabled",
            Feats=rows},{Beautify=true,StringifyInternalTypes=false})
        if not json or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_FeatSecondary_Provenance.json",json) then
            error("Cannot write feat-secondary provenance report")
        end
        RespecStartLog("FEAT_SECONDARY_PROVENANCE actor="..characterGuid
            .." featLevels="..tostring(#rows))
    end)
    if not ok then
        RespecStartLog("FEAT_SECONDARY_PROVENANCE_ERROR actor="..characterGuid
            .." reason="..tostring(err))
    end
end

-- Read-only audit of original level-one foundations and exact spell acquisition
-- evidence. CCLevelUp is authoritative only for selections actually recorded;
-- ProgressionSpells / current spellbook grants are never assumed player picks.
-- This is also a blueprint for future level-one reconstruction: the vanilla
-- respec recreates level 1, while HB currently restores entities from level 2.
SaveLevelOneAndSpellProvenance = function(characterGuid,snapshot,maxLevel)
    local ok,err=pcall(function()
        local histories=snapshot.components and snapshot.components.ccLevelUp
            and snapshot.components.ccLevelUp.LevelUps or {}
        local buckets=snapshot.progressions and snapshot.progressions.buckets or {}
        local levelOne=histories[1]
        local originalBase={Version=1,CharacterGuid=characterGuid,
            Mode="read_only_original_snapshot",SafeHistoricalEditing=false,
            Reason="BG3 recreates its level-one progression during vanilla respec; replay presently restores levels 2 and above",
            HistoryPresent=type(levelOne)=="table",
            LevelOneHistory=levelOne and {
                Class=levelOne.Class,SubClass=levelOne.SubClass,
                Abilities=levelOne.Abilities,Feat=levelOne.Feat,
                AbilityBonuses=levelOne.Upgrades and levelOne.Upgrades.AbilityBonuses or {},
                Passives=levelOne.Upgrades and levelOne.Upgrades.Passives or {},
                Skills=levelOne.Upgrades and levelOne.Upgrades.Skills or {},
                SkillExpertise=levelOne.Upgrades and levelOne.Upgrades.SkillExpertise or {},
                Spells=levelOne.Spells or {},
                UpgradeSpells=levelOne.Upgrades and levelOne.Upgrades.Spells or {}
            } or nil,
            ProgressionEntries=buckets[1] or {},
            OriginalClassComposition=snapshot.components and snapshot.components.classes}
        local text=Ext.Json.Stringify(originalBase,
            {Beautify=true,StringifyInternalTypes=false})
        if not text or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_LevelOne_History_Provenance.json",text) then
            error("Cannot save level-one provenance")
        end
        local levels={}
        local sourceOnly=0;local observationOnly=0;local records=0
        for level=1,maxLevel do
            local history=histories[level]
            local levelRecords={}
            -- Serialized spell selectors may contain a nested SpellId or
            -- nested Spells array; record exact source rows without inferring
            -- which property variant represents a player decision.
            if history then
                for _,src in ipairs({{Name="Spells",Rows=history.Spells},
                        {Name="Upgrades.Spells",Rows=history.Upgrades and history.Upgrades.Spells}}) do
                    for index,row in ipairs(src.Rows or {}) do
                        levelRecords[#levelRecords+1]={Source=src.Name,
                            EntryIndex=index,Raw=row}
                    end
                end
            end
            local grants={}
            local spellComponents=0
            for progressionIndex,entry in ipairs(buckets[level] or {}) do
                local spell=entry.spells
                if spell then
                    spellComponents=spellComponents+1
                    grants[#grants+1]={ProgressionIndex=progressionIndex,
                        Meta=entry.meta and {
                            Level=entry.meta.Level,Source=entry.meta.Source,
                            SpellSourceType=entry.meta.SpellSourceType,
                            Progression=entry.meta.Progression} or nil,
                        AddSpells=spell.AddSpells or {},RemoveSpells=spell.RemoveSpells or {}}
                end
            end
            local hasHistory=#levelRecords>0
            local hasGrant=spellComponents>0
            if hasHistory or hasGrant then
                levels[#levels+1]={Level=level,HasCCLevelUp=history~=nil,
                    RecordedSelectionRows=levelRecords,ProgressionSpells=grants,
                    ExactReplayOwnershipVerified=false,
                    Interpretation=hasHistory and
                        "Recorded spell selectors; replay requires matching single progression grant and rank" or
                        "Progression grants without a recorded selection; view only"}
                if hasHistory then sourceOnly=sourceOnly+1 end
                if hasGrant and not hasHistory then observationOnly=observationOnly+1 end
                records=records+#levelRecords
            end
        end
        local payload={Version=1,CharacterGuid=characterGuid,CharacterLevel=maxLevel,
            Source="serialized original CCLevelUp and progression buckets (read only)",
            Summary={LevelsWithRecordedSelectors=sourceOnly,
                LevelsWithUnattributedProgressionGrants=observationOnly,
                RecordedRows=records},Levels=levels,
            WizardMissingHistoryPolicy="Never synthesize spell acquisition levels from current spellbook"}
        local serialized=Ext.Json.Stringify(payload,
            {Beautify=true,StringifyInternalTypes=false})
        if not serialized or not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_HistoricalSpell_Provenance.json",serialized) then
            error("Cannot save historical spell provenance")
        end
        RespecStartLog("LEVEL_ONE_SPELL_PROVENANCE actor="..characterGuid
            .." levelOne="..tostring(type(levelOne)=="table")
            .." recordedRows="..tostring(records)
            .." unattributedLevels="..tostring(observationOnly))
    end)
    if not ok then
        RespecStartLog("LEVEL_ONE_SPELL_PROVENANCE_ERROR actor="..characterGuid
            .." reason="..tostring(err))
    end
end

-- Capture the unmodified snapshot before attempting the full-build experiment.
-- Failing to make this safety copy cancels the operation.
local function SaveExperimentalBackup(characterGuid, snapshot)
    -- Only two disk copies per character, even after hundreds of respecs.
    -- The current and preceding untouched snapshots remain available for
    -- recovery if replay fails. In-memory replay still uses its own original.
    local path = ("HomeBrew/Backups/HB_LevelEditor_Original_%s.json"):format(characterGuid)
    local previous = ("HomeBrew/Backups/HB_LevelEditor_Original_%s_Previous.json"):format(characterGuid)
    local ok, err = pcall(function()
        local json = Ext.Json.Stringify(snapshot, { Beautify = true, StringifyInternalTypes = false })
        if not json then error("snapshot serialization failed") end
        -- Preserve the prior disk copy BEFORE replacing the current one.
        -- Do not enter a destructive respec if either write fails.
        local loaded, old = pcall(Ext.IO.LoadFile, path)
        if loaded and type(old) == "string" and #old > 0 then
            if not Ext.IO.SaveFile(previous, old) then
                error("could not preserve previous original snapshot")
            end
        end
        if not Ext.IO.SaveFile(path, json) then error("file write failed") end
    end)
    if not ok then return false, tostring(err) end
    return true, path
end

-- A test-only result file, created after the replay, to distinguish command
-- acceptance from real restoration of the selected historical option.
WriteHistoricalEditResult = function(characterGuid, edits)
    local target = Ext.Entity.Get(characterGuid)
    local ups = target and target.CCLevelUp and target.CCLevelUp.LevelUps
    local container = target and target.ProgressionContainer
    local buckets = container and container.Progressions
    local rows = {}
    for _, edit in ipairs(edits) do
        local level = tonumber(edit.Level)
        local history = ups and ups[level]
        local targetId = tostring(edit.To)
        local foundHistory, foundProgression = {}, {}
        local passiveEdit = edit.Type == "ClassPassive"
        local otherEdit = edit.Type ~= nil and not passiveEdit
        if otherEdit then
            for _,candidate in ipairs(BuildOtherHistoricalChoices(history,level)) do
                if candidate.Kind == edit.Type and candidate.Source == edit.Source
                    and candidate.EntryIndex == tonumber(edit.EntryIndex)
                    and candidate.SlotIndex == tonumber(edit.SlotIndex) then
                    foundHistory[#foundHistory+1] = tostring(candidate.From)
                end
            end
            for _,progression in ipairs(buckets and buckets[level] or {}) do
                local componentName = ({Feat="ProgressionFeat",Ability="ProgressionAbilityImprovements",
                    Spell="ProgressionSpells",Cantrip="ProgressionSpells",
                    Skill="ProgressionSkills",Expertise="ProgressionSkills"})[edit.Type]
                if componentName and progression[componentName] then
                    local ok,serialized=pcall(Ext.Types.Serialize,progression[componentName])
                    if ok and serialized then
                        -- The output records whether the restored progression
                        -- component contains the selected ID, not its full
                        -- semantic bonuses or spellbook effects.
                        local function Scan(data)
                            if type(data)~="table" then return end
                            for _,value in pairs(data) do
                                if tostring(value)==targetId then
                                    foundProgression[#foundProgression+1]=targetId
                                elseif type(value)=="table" then Scan(value) end
                            end
                        end
                        Scan(serialized)
                        if edit.Type=="Ability" and tonumber(edit.Level) then
                            local vec=serialized.AbilityImprovements or {}
                            if tonumber(vec[HB_ABILITY_INDICES[targetId]] or 0)>0 then
                                foundProgression[#foundProgression+1]=targetId
                            end
                        end
                    end
                end
            end
        elseif passiveEdit then
            for _, sel in ipairs(history and history.Upgrades and history.Upgrades.Passives or {}) do
                if tostring(sel.SelectorId or "") == tostring(edit.SelectorId) then
                    for _, id in ipairs(sel.Passives or {}) do foundHistory[#foundHistory+1] = tostring(id) end
                end
            end
        else
            foundHistory = ExtraResourceSelectionsAtLevel(history)
        end
        for _, entity in ipairs(buckets and buckets[level] or {}) do
            local comp = entity.ProgressionPassives
            if comp then
                local ok, data = pcall(Ext.Types.Serialize, comp)
                if ok and data then
                    for _, id in ipairs(data.AddPassives or {}) do
                        if passiveEdit or tostring(id):find("^ExtraActions_") then
                            foundProgression[#foundProgression+1] = tostring(id)
                        end
                    end
                end
            end
        end
        local historyMatches, progressionMatches = false, false
        for _, id in ipairs(foundHistory) do if id == targetId then historyMatches = true end end
        for _, id in ipairs(foundProgression) do if id == targetId then progressionMatches = true end end
        rows[#rows+1] = {
            Level = level, Kind = otherEdit and tostring(edit.Type)
                or (passiveEdit and "ClassPassive" or "ExtraResource"),
            Expected = targetId, From = tostring(edit.From),
            History = foundHistory, Progression = foundProgression,
            HistoryMatches = historyMatches, ProgressionMatches = progressionMatches,
        }
    end

    local ok, err = pcall(function()
        local json = Ext.Json.Stringify({
            Version = 1, CharacterLevel = target and target.EocLevel and target.EocLevel.Level,
            CharacterGuid = characterGuid, Results = rows,
        }, { Beautify = true, StringifyInternalTypes = false })
        if not Ext.IO.SaveFile("HomeBrew/Diagnostics/HB_LevelEditor_Result.json", json) then
            error("Unable to save result file")
        end
    end)
    if not ok then PRWarn(0, "Experimental result diagnostic failed: %s", tostring(err)) end
end

-- Net messages should be plain dense arrays. Checking only #list and
-- iterating with ipairs() can silently skip entries after a hole, or ignore
-- non-numeric keys. A malformed staged edit must NEVER turn into a seemingly
-- successful no-change replay. This checks structure only; choice provenance
-- and eligibility are still validated by the existing per-kind validators.
local function ValidateHistoricalEditBatch(edits, label, limit)
    if edits == nil then return true,nil end
    if type(edits) ~= "table" then
        return false,label.." must be an array"
    end
    local count,highest=0,0
    for index,entry in pairs(edits) do
        if type(index)~="number" or index<1 or index~=math.floor(index) then
            return false,label.." contains an unsupported index"
        end
        if type(entry)~="table" then
            return false,label.." contains an invalid edit record"
        end
        count=count+1
        if count>limit then return false,label.." exceeds the edit limit" end
        if index>highest then highest=index end
    end
    if count~=highest then
        return false,label.." contains missing entries"
    end
    return true,nil
end

-- Selective Respec rebuilds every original progression after the vanilla
-- Confirm. Verify the same shape ApplyProgressions() will require BEFORE
-- acknowledging the commit, not after DestroyExistingProgressions() runs.
-- Do not change ordinary Full / Partial Respec behavior with this guard.
ValidateLevelRespecReplayCoverage = function(snapshot, maxLevel)
    if type(snapshot)~="table" or snapshot.schemaVersion~=2 then
        return false,"Incompatible or missing original progression snapshot"
    end
    local components=snapshot.components
    local cc=components and components.ccLevelUp
    local records=cc and cc.LevelUps
    if type(records)~="table" then
        return false,"Original level-up records are unavailable"
    end
    if type(maxLevel)~="number" or maxLevel<1 or maxLevel>40
        or maxLevel~=math.floor(maxLevel) then
        return false,"Original character level is invalid"
    end
    local recordedClassLevels={}
    for level=1,maxLevel do
        local row=records[level]
        if type(row)~="table" or not IsValidGuid(row.Class)
            or tostring(row.Class)=="" then
            return false,"Original class history missing at level "..level
        end
        local id=tostring(row.Class)
        recordedClassLevels[id]=(recordedClassLevels[id] or 0)+1
    end
    -- A complete CCLevelUp sequence is not enough: the original Classes
    -- component must describe the same class distribution. Otherwise replay
    -- could reconstruct a full-level but DIFFERENT multiclass composition.
    local classComponent=components.classes
    local classRows=classComponent and classComponent.Classes
    if type(classRows)~="table" then
        return false,"Original class composition is unavailable"
    end
    local capturedClassLevels={}
    local capturedTotal,numberOfClasses=0,0
    for index,class in pairs(classRows) do
        if type(index)~="number" or index<1 or index~=math.floor(index)
            or type(class)~="table" or not IsValidGuid(class.ClassUUID) then
            return false,"Original class composition contains an invalid entry"
        end
        local amount=tonumber(class.Level)
        if not amount or amount<1 or amount~=math.floor(amount) then
            return false,"Original class composition has an invalid class level"
        end
        local id=tostring(class.ClassUUID)
        capturedClassLevels[id]=(capturedClassLevels[id] or 0)+amount
        capturedTotal=capturedTotal+amount
        numberOfClasses=numberOfClasses+1
    end
    if numberOfClasses==0 or capturedTotal~=maxLevel then
        return false,"Original class composition does not total the character level"
    end
    for id,amount in pairs(recordedClassLevels) do
        if capturedClassLevels[id]~=amount then
            return false,"Original class composition disagrees with level-up history"
        end
    end
    for id,amount in pairs(capturedClassLevels) do
        if recordedClassLevels[id]~=amount then
            return false,"Original class composition contains an unmatched class"
        end
    end
    local buckets=snapshot.progressions and snapshot.progressions.buckets
    if type(buckets)~="table" then
        return false,"Original progression buckets are unavailable"
    end
    for level=2,maxLevel do
        local bucket=buckets[level]
        if type(bucket)~="table" then
            return false,"Original progression bucket missing at level "..level
        end
        -- ipairs() silently stops at the first missing entry. A sparse
        -- progression bucket would therefore lose every entry after that
        -- hole during replay, even though its contents otherwise validate.
        local total,highest=0,0
        for index in pairs(bucket) do
            if type(index)~="number" or index<1 or index~=math.floor(index) then
                return false,"Unsupported progression index at level "..level
            end
            total=total+1
            if index>highest then highest=index end
        end
        if total~=highest then
            return false,"Sparse progression bucket at level "..level
        end
        for index,entry in ipairs(bucket) do
            if type(entry)~="table" then
                return false,("Invalid progression entry %d at level %d"):format(index,level)
            end
            -- SnapshotProgressionEntry serializes these known component
            -- payloads as plain tables. Bad component types, or an entity
            -- with no captured progression components at all, must be
            -- rejected BEFORE DestroyExistingProgressions() runs.
            local hasComponent=false
            for _,key in ipairs({"meta","abilityImprovements","feat","spells",
                "skills","passives","replicatedFeat","levelUp"}) do
                local payload=entry[key]
                if payload~=nil then
                    if type(payload)~="table" then
                        return false,("Invalid %s payload in progression %d at level %d")
                            :format(key,index,level)
                    end
                    hasComponent=true
                end
            end
            if not hasComponent then
                return false,("Empty progression entry %d at level %d")
                    :format(index,level)
            end
        end
    end
    return true,nil
end

local HBBuildPresetFiles=Ext.Require('Shared/PresetFiles.lua')
HBBuildPresetData=Ext.Require('Shared/BuildPresetData.lua')
local HBBuildPresetDir='HomeBrew/BuildPresets'
local function HandlePartialRespecMessage(message, user)
    if not PartialRespecEnabled then return end

    if type(message)=="table" and message.RecoverRespecMenu==true then
        if type(user)~="number" then return end
        local actor,why=ResolveActiveOwnedRespec(user)
        if not actor then
            RespecStartLog("RECOVERY_REJECT peer="..tostring(user).." reason="..tostring(why))
            return
        end
        local state=pendingRespec[actor]
        RespecStartLog("RECOVERY_REQUEST actor="..actor
            .." existing="..tostring(state~=nil)
            .." ready="..tostring(state and state.summaries~=nil))
        if state and state.summaries then
            SendPendingPopup(actor,state,"client_recovery")
        elseif not state then
            SafeRespecStart(actor,"client_recovery")
        end
        return
    end

    if type(message) ~= "table" or type(message.Character) ~= "string" then
        PRWarn(0, "PR choice rejected: invalid message")
        RespecStartLog("RESPEC_COMMIT_REJECT invalid_payload peer="..tostring(user))
        return
    end

    local characterGuid = Guid(message.Character)
    local requestId=type(message.RequestId)=="string" and message.RequestId or nil
    RespecStartLog("RESPEC_COMMIT_RECEIVED actor="..characterGuid
        .." peer="..tostring(user).." cutoff="..tostring(message.Level)
        .." mode="..(message.LevelRespecConfirm==true and "Level" or
            message.Cancelled==true and "Cancel" or "Partial")
        .." request="..tostring(requestId))
    local state = pendingRespec[characterGuid]
    if not state then
        PRWarn(1, "PR choice: no pending respec for %s", characterGuid)
        RespecStartLog("RESPEC_COMMIT_REJECT reason=no_pending_state actor="..characterGuid)
        return
    end

    -- Some companion respecs have reserved user ID 0. That MUST NOT turn
    -- the history-replay RPC into an unrestricted multiplayer operation.
    -- Check the peer's actual ownership through reserved user / PartyView,
    -- using the same guarded ownership routine as respec-menu recovery.
    if type(user) ~= "number"
        or not OwnedRespecActor(characterGuid, PeerToReservedUserID(user)) then
        PRWarn(0, "PR choice rejected for %s: caller is not the owner", characterGuid)
        RespecStartLog("LEVEL_RESPEC_OWNER_REJECT actor="..characterGuid
            .." peer="..tostring(user))
        -- No destructive action was taken. Report an owned-viewer error so
        -- single-player requests do not leave the Partial popup permanently busy.
        if requestId then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "The server could not verify respec ownership.",RequestId=requestId},
                RespecViewerUser(characterGuid))
        end
        return
    end
    -- Build presets are data exports/compatibility probes, NOT native respec
    -- commits. Reuse the exact owner check immediately above. No snapshot,
    -- progression or native-casting components are modified by these RPCs.
    if message.BuildPresetOperation then
        local operation=tostring(message.BuildPresetOperation)
        local function Answer(success,status)
            PartialRespecChannel:SendToClient({BuildPresetResult=true,
                BuildPresetOk=success,BuildPresetOperation=operation,
                BuildPresetStatus=tostring(status)},RespecViewerUser(characterGuid))
        end
        if state.nativeFirstLevelRestore or state.snapshot then
            Answer(false,'Finish or cancel the current respec transaction first.');return
        end
        local worked,result=pcall(function()
            local snapshot=PartialRespecSnapshot.SaveCharacter(
                'HomeBrew/Backups/HB_BuildPreset_Capture.json',characterGuid)
            if operation=='Save' then
                local name=HBBuildPresetFiles.CleanName(message.Name)
                local preset=HBBuildPresetData.Extract(snapshot,name)
                local filename=HBBuildPresetFiles.FileFor(name,'build')
                local current=Ext.IO.LoadFile(HBBuildPresetDir..'/'..filename)
                if current and current~='' then
                    local previous=HBBuildPresetFiles.Read(HBBuildPresetDir,filename)
                    if not previous or previous.Kind~='HomeBrewBuild' or previous.Name~=name then
                        error('A different preset already uses this filename.')
                    end
                    if message.Replace~=true then error('A preset with this name exists. Choose Replace to overwrite it.') end
                    if Ext.IO.SaveFile(HBBuildPresetDir..'/'..filename..'.bak',current)==false then
                        error('Could not preserve the previous preset.')
                    end
                end
                local ok,why=HBBuildPresetFiles.Write(HBBuildPresetDir,filename,preset)
                if not ok then error(why) end
                return 'Build saved: '..name..' ('..preset.LevelCount..' levels).'
            elseif operation=='CheckLoad' then
                local data,why=HBBuildPresetFiles.Read(HBBuildPresetDir,message.Filename)
                if not data then error(why) end
                local compatible,reason=HBBuildPresetData.Compatible(data,snapshot)
                if not compatible then error(reason) end
                local target=#snapshot.components.ccLevelUp.LevelUps
                local installed,why=HBBuildPresetData.CheckInstalled(data,target)
                if not installed then error(why) end
                return 'Compatible build: '..data.Name..'. Preparing historical selections…'
            end
            error('Unsupported build preset operation.')
        end)
        Answer(worked,worked and result or tostring(result):gsub('^.-:%d+: ',''))
        return
    end
    if state.levelRespec and state.snapshot then
        RespecStartLog("LEVEL_RESPEC_DUPLICATE_COMMIT_REJECT actor="..characterGuid)
        return
    end

    if message.Cancelled == true then
        PRPrint(1, "PR choice: cancel (full respec)")
        -- A declined experimental commit must not leave a stale untouched
        -- snapshot or backup-path flag on a later respec confirmation.
        state.level = nil
        state.snapshot = nil
        state.originalSnapshot = nil
        state.backupPath = nil
        state.experimentalEdits = nil
        state.levelRespec = nil
        state.nativeFirstLevelRestore = nil
        state.buildPresetDefinition = nil
        state.historicalCommitAttempted = nil
        return
    end


    if message.NativeFirstLevelSlider==true then
        if type(requestId)~="string" or requestId=="" then return end
        local autoBuild=message.BuildPresetAutoApply==true
        local function Refuse(why)
            local messageText=tostring(why or "Native level-one preparation failed")
            RespecStartLog("NATIVE_SLIDER_L1_PREPARE_REJECT actor="..characterGuid
                .." autoBuild="..tostring(autoBuild).." reason="..messageText)
            if autoBuild then
                PartialRespecChannel:SendToClient({RequestId=requestId,
                    ExperimentalError=messageText},RespecViewerUser(characterGuid))
            else
                PartialRespecChannel:SendToClient({RequestId=requestId,
                    NativeFirstLevelSliderError=messageText},RespecViewerUser(characterGuid))
            end
        end
        if state.charLevel<2 then Refuse("There are no higher levels to restore.");return end
        -- Automatic loading is never allowed to reuse a prepared historical
        -- transaction, or turn a manual level-one edit into an implicit
        -- confirmation. It starts from a clean unchanged respec snapshot.
        if autoBuild and (type(message.BuildPresetFile)~='string'
            or message.BuildPresetFile=='' or state.snapshot
            or state.nativeFirstLevelSlider or state.nativeFirstLevelRestore) then
            Refuse('Cannot automatically load this build in the current respec session.')
            return
        end
        if state.snapshot and not state.nativeFirstLevelSlider then
            Refuse("Another respec transaction is already prepared.");return
        end
        local base=state.nativeFirstLevelSlider and state.originalSnapshot or nil
        if not base then
            local ok,result=pcall(PartialRespecSnapshot.SaveCharacter,
                "HomeBrew/Backups/native_slider_"..characterGuid..".json",characterGuid)
            if not ok or type(result)~="table" then
                Refuse("Cannot capture a clean build: "..tostring(result));return
            end
            base=result
        end
        local valid,reason=ValidateLevelRespecReplayCoverage(base,state.charLevel)
        if valid then valid,reason=HB_NativeFirstLevelRestore.PreflightOriginal(base,state.charLevel) end
        if not valid then Refuse("Original build cannot be safely restored: "..tostring(reason));return end
        local copied,patched=pcall(CopyPlainTable,base)
        if not copied or type(patched)~="table" then Refuse("Cannot copy saved build");return end
        local nativeSwap=message.NativeLevelOneSpellSwap
        local deferredSpellEdits={}
        local directBuild=nil
        if message.BuildPresetFile~=nil then
            if type(message.BuildPresetFile)~='string' then
                Refuse('Invalid build preset filename.');return
            end
            local preset,why=HBBuildPresetFiles.Read(HBBuildPresetDir,message.BuildPresetFile)
            if not preset then Refuse('Build preset unavailable: '..tostring(why));return end
            local compatible,problem=HBBuildPresetData.Compatible(preset,base)
            if not compatible then Refuse('Build preset incompatible: '..tostring(problem));return end
            local installed,installWhy=HBBuildPresetData.CheckInstalled(preset,state.charLevel)
            if not installed then Refuse('Build preset definitions unavailable: '..tostring(installWhy));return end
            if autoBuild and preset.Version~=2 then
                Refuse('This older build format cannot be loaded automatically. Re-save it using the current version.')
                return
            end
            if preset.Version==2 then
                directBuild=preset
                if nativeSwap or #(message.ExperimentalOtherChoiceEdits or {})>0
                    or #(message.ExperimentalClassPassiveEdits or {})>0
                    or #(message.ExperimentalExtraResourceEdits or {})>0 then
                    Refuse('Build import cannot be mixed with manual staged edits.');return
                end
                local assembled,reason=HBBuildPresetData.Compose(preset,base)
                if not assembled then Refuse('Build reconstruction refused: '..tostring(reason));return end
                patched=assembled
                local matches,mismatch=HBBuildPresetData.MatchesSelections(preset,patched)
                if not matches then Refuse('Build selections incomplete: '..tostring(mismatch));return end
                RespecStartLog('BUILD_PRESET_CLASS_RECONSTRUCTION_STAGED actor='..characterGuid
                    ..' preset='..tostring(message.BuildPresetFile)
                    ..' presetLevels='..preset.LevelCount
                    ..' receivingLevel='..state.charLevel)
            end
        end
        if nativeSwap~=nil then
            if #(message.ExperimentalExtraResourceEdits or {})>0
                or #(message.ExperimentalClassPassiveEdits or {})>0 then
                Refuse("Use a separate Selective Respec for unrelated passive or resource edits during this spell exchange.")
                return
            end
            local validSwap,swapReason=HB_NativeFirstLevelRestore.PreflightInverseSpellSwap(
                base,nativeSwap,message.ExperimentalOtherChoiceEdits)
            if not validSwap then Refuse("Native first-level spell exchange is unsafe: "..tostring(swapReason));return end
            for _,e in ipairs(message.ExperimentalOtherChoiceEdits or {}) do
                if e.Kind=="Spell" then deferredSpellEdits[#deferredSpellEdits+1]=CopyPlainTable(e) end
            end
        end
        local batches=not directBuild and {
            {message.ExperimentalExtraResourceEdits,ValidateAndPatchExtraResources,"resources"},
            {message.ExperimentalClassPassiveEdits,ValidateAndPatchClassPassives,"passives"},
            {message.ExperimentalOtherChoiceEdits,ValidateAndPatchOtherChoices,"choices"},
        } or {}
        local limits={state.charLevel,128,state.charLevel*12}
        for i,batch in ipairs(batches) do
            local edits,validator,label=batch[1],batch[2],batch[3]
            if type(edits)~="table" or #edits>limits[i] then
                Refuse("Malformed or excessive "..label.." edits");return
            end
            local seen=0
            for key,edit in pairs(edits) do
                if type(key)~="number" or key<1 or key~=math.floor(key)
                    or type(edit)~="table" or tonumber(edit.Level)==nil
                    or tonumber(edit.Level)<2 or tonumber(edit.Level)>state.charLevel then
                    Refuse("Unsafe "..label.." edit at level one or unknown level");return
                end
                seen=seen+1
            end
            if seen~=#edits then Refuse("Sparse "..label.." edits");return end
            if #edits>0 then
                local ok,result,why=pcall(validator,patched,edits,state.charLevel,
                    (label=="choices" and nativeSwap)
                        or (label=="passives" and true) or nil)
                if not ok or not result then
                    Refuse("Higher-level "..label.." cannot be restored: "
                        ..tostring(why or result));return
                end
                patched=result
            end
        end
        -- A build import must apply every recorded choice, not merely a
        -- convenient subset. Refuse BEFORE native Confirm if a protected or
        -- unavailable choice was skipped during client staging. The server
        -- independently rereads the user-owned JSON file and compares all
        -- resulting CC level-up selectors; the client never supplies these
        -- grant identities as trusted restoration data.
        if message.BuildPresetFile~=nil and not directBuild then
            if type(message.BuildPresetFile)~='string' then
                Refuse('Invalid preset filename.');return
            end
            local preset,why=HBBuildPresetFiles.Read(HBBuildPresetDir,message.BuildPresetFile)
            if not preset then Refuse('Build preset unavailable: '..tostring(why));return end
            local compatible,why=HBBuildPresetData.Compatible(preset,base)
            if not compatible then Refuse('Build preset is incompatible: '..tostring(why));return end
            local matches,why=HBBuildPresetData.MatchesSelections(preset,patched)
            if not matches then
                Refuse('Build preset could not be fully reconstructed: '..tostring(why));return
            end
            RespecStartLog('BUILD_PRESET_FULL_COVERAGE_VERIFIED actor='..characterGuid
                ..' preset='..tostring(message.BuildPresetFile))
        end
        valid,reason=ValidateLevelRespecReplayCoverage(patched,state.charLevel)
        if valid then valid,reason=HB_NativeFirstLevelRestore.PreflightOriginal(patched,state.charLevel) end
        if not valid then Refuse("Edited build cannot be restored: "..tostring(reason));return end
        -- A disk backup is created only once, from the untouched snapshot.
        -- Re-entering L1 refreshes the staged higher-level edits atomically.
        local backup=state.backupPath
        if not backup then
            local saved,path=SaveExperimentalBackup(characterGuid,base)
            if not saved then Refuse("Cannot preserve original backup: "..tostring(path));return end
            backup=path
        end
        if not state.nativePresentation then
            local okCapture,present=pcall(NativePresentationCapture,Ext.Entity.Get(characterGuid))
            if okCapture then state.nativePresentation=present end
        end
        state.snapshot=patched
        state.originalSnapshot=base
        state.buildPresetDefinition=directBuild
        state.charLevel=tonumber(state.charLevel)
        state.nativeFirstLevelRestore=true
        state.nativeFirstLevelSlider=true
        state.nativeSpellSwap=nativeSwap and CopyPlainTable(nativeSwap) or nil
        state.nativeSpellDeferredEdits=deferredSpellEdits
        state.backupPath=backup
        RespecStartLog("NATIVE_SLIDER_L1_PREPARED actor="..characterGuid
            .." level="..state.charLevel.." backup="..tostring(backup)
            .." autoBuild="..tostring(autoBuild))
        if autoBuild then
            -- ACK only after COMPLETE source/target validation and a durable
            -- untouched recovery backup. Client now invokes BG3's original
            -- FinishCreating; RespecCompleted uses the existing native
            -- class/casting/hotbar restore and post-replay audits.
            PartialRespecChannel:SendToClient({RequestId=requestId,
                Character=characterGuid,Confirmed=true,AckMode='BuildPreset'},
                RespecViewerUser(characterGuid))
        else
            PartialRespecChannel:SendToClient({RequestId=requestId,
                NativeFirstLevelSliderPrepared=true},RespecViewerUser(characterGuid))
        end
        return
    end
    if message.NativeFirstLevelRestore == true then
        if not requestId or type(requestId)~="string" then return end
        if state.nativeFirstLevelRestore or state.snapshot then
            RespecStartLog("NATIVE_L1_DUPLICATE_COMMIT actor="..characterGuid)
            return
        end
        if state.charLevel<2 then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "There are no higher character levels to restore.",RequestId=requestId},
                RespecViewerUser(characterGuid))
            return
        end
        local captured,original=pcall(PartialRespecSnapshot.SaveCharacter,
            "HomeBrew/Backups/native_l1_"..characterGuid..".json",characterGuid)
        if not captured then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Could not capture the original build: "..tostring(original),RequestId=requestId},
                RespecViewerUser(characterGuid))
            return
        end
        local valid,why=ValidateLevelRespecReplayCoverage(original,state.charLevel)
        if valid then
            valid,why=HB_NativeFirstLevelRestore.PreflightOriginal(original,state.charLevel)
        end
        if not valid then
            RespecStartLog("NATIVE_L1_PREFLIGHT_REJECT actor="..characterGuid
                .." reason="..tostring(why))
            PartialRespecChannel:SendToClient({ExperimentalError=
                "This build cannot be restored safely: "..tostring(why),RequestId=requestId},
                RespecViewerUser(characterGuid))
            return
        end
        local saved,path=SaveExperimentalBackup(characterGuid,original)
        if not saved then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Could not save an untouched build backup: "..tostring(path),RequestId=requestId},
                RespecViewerUser(characterGuid))
            return
        end
        if not state.nativePresentation then
            local okCapture,present=pcall(NativePresentationCapture,Ext.Entity.Get(characterGuid))
            if okCapture then state.nativePresentation=present end
        end
        state.snapshot=original
        state.charLevel=tonumber(state.charLevel)
        state.nativeFirstLevelRestore=true
        state.backupPath=path
        RespecStartLog("NATIVE_L1_BACKUP_READY actor="..characterGuid
            .." target="..state.charLevel.." file="..path)
        PartialRespecChannel:SendToClient({Character=characterGuid,
            Confirmed=true,AckMode="NativeFirstLevel",RequestId=requestId},
            RespecViewerUser(characterGuid))
        return
    end

    -- Mark an attempted historical Confirm before any preflight or static
    -- feat validation. A later StartRespec can then reconstruct this still-
    -- untouched pending session instead of suppressing its new popup.
    if message.LevelRespecConfirm==true then
        state.historicalCommitAttempted=true
        if state.nativeFirstLevelSlider then
            RespecStartLog("NATIVE_SLIDER_L1_DISCARDED_FOR_HISTORICAL_COMMIT actor="..characterGuid)
            state.nativeFirstLevelRestore=nil
            state.nativeFirstLevelSlider=nil
            state.buildPresetDefinition=nil
            state.snapshot=nil
            state.originalSnapshot=nil
            state.backupPath=nil
        end
    end

    local level = tonumber(message.Level)
    if not level or level~=math.floor(level) or level < 1 or level > state.charLevel then
        PRWarn(0, "PR choice: invalid level %s", tostring(message.Level))
        if message.LevelRespecConfirm==true or requestId then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Invalid historical level; no changes were accepted.",RequestId=requestId},
                RespecViewerUser(characterGuid))
        end
        return
    end

    -- Reject malformed, keyed, oversized or sparse edit arrays before the
    -- expensive snapshot capture. Without this, ipairs() could drop a staged
    -- selection and the native Confirm might nevertheless be acknowledged.
    for _,spec in ipairs({
        {"ExperimentalExtraResourceEdits",state.charLevel},
        {"ExperimentalClassPassiveEdits",128},
        {"ExperimentalOtherChoiceEdits",state.charLevel*12},
    }) do
        local valid,reason=ValidateHistoricalEditBatch(message[spec[1]],spec[1],spec[2])
        if not valid then
            RespecStartLog("LEVEL_RESPEC_EDIT_BATCH_REJECT actor="..characterGuid
                .." reason="..tostring(reason))
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Historical edit data is incomplete: "..tostring(reason)},
                RespecViewerUser(characterGuid))
            return
        end
    end

    local entity = Ext.Entity.Get(characterGuid)
    if not entity then
        PRWarn(0, "PR choice: cannot resolve entity for snapshot")
        if message.LevelRespecConfirm==true then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Character data is unavailable; no changes were accepted."},
                RespecViewerUser(characterGuid))
        end
        return
    end

    -- Snapshot serialization can fail for unusual modded character
    -- components. Never let an exception silently abort the server handler
    -- and leave the native client waiting for confirmation indefinitely.
    local captured,snapshot=pcall(PartialRespecSnapshot.SaveCharacter,
        "HomeBrew/Backups/replay_" .. characterGuid .. ".json", entity)
    if not captured or type(snapshot)~="table" then
        RespecStartLog("LEVEL_RESPEC_CAPTURE_REJECT actor="..characterGuid
            .." reason="..tostring(snapshot))
        PartialRespecChannel:SendToClient({ExperimentalError=
            "Could not safely capture the character's progression: "..tostring(snapshot)},
            RespecViewerUser(characterGuid))
        return
    end

    -- Capture read-only feat/secondary evidence even if the historical
    -- replay is rejected for incomplete class history. This makes a
    -- fail-closed test useful for diagnosing unusual modded characters.
    if message.LevelRespecConfirm==true then
        SaveHistoricalFeatSecondaryAudit(characterGuid,snapshot,state.charLevel)
    end

    -- No historical Selective Respec can safely reach destructive replay if a
    -- class record or progression bucket is missing. The native Confirm must
    -- stay blocked while the original respec transaction is still intact.
    if message.LevelRespecConfirm==true then
        local complete,reason=ValidateLevelRespecReplayCoverage(snapshot,state.charLevel)
        if not complete then
            RespecStartLog("LEVEL_RESPEC_COVERAGE_REJECT actor="..characterGuid
                .." reason="..tostring(reason))
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Selective Respec cannot safely restore the full original build: "
                ..tostring(reason)..". Full Respec still works."},
                RespecViewerUser(characterGuid))
            return
        end
    end
    -- Validators patch serialized snapshot tables in-place. Save an entirely
    -- separate original copy *before* the first validator can mutate it.
    -- That copy is required for meaningful emergency recovery and diagnostics.
    local originalSnapshot=nil
    if message.LevelRespecConfirm==true then
        local copied,result=pcall(CopyPlainTable,snapshot)
        if not copied or type(result)~="table" then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Could not preserve an untouched historical recovery snapshot."},
                RespecViewerUser(characterGuid))
            return
        end
        originalSnapshot=result
    end
    local resourceEdits = message.ExperimentalExtraResourceEdits
    local passiveEdits = message.ExperimentalClassPassiveEdits
    local otherEdits = message.ExperimentalOtherChoiceEdits
    for _,featEdit in ipairs(otherEdits or {}) do
        if featEdit.Kind=="Feat" and featEdit.To==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT then
            for _,passiveEdit in ipairs(passiveEdits or {}) do
                if tonumber(passiveEdit.Level)==tonumber(featEdit.Level)
                    and tostring(passiveEdit.PassiveList or "")==HB_ELEMENTAL_ADEPT_LIST then
                    PartialRespecChannel:SendToClient({ExperimentalError=
                        "New Elemental Adept choices must use its native feat tab, not historic passive edits."},
                        RespecViewerUser(characterGuid))
                    return
                end
            end
        end
        if featEdit.Kind=="Feat"
            and tostring(featEdit.From or "")==HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT
            and tostring(featEdit.To or "")~=HB_ELEMENTAL_ADEPT_REPLACEABLE_FEAT then
            for _,passiveEdit in ipairs(passiveEdits or {}) do
                if tonumber(passiveEdit.Level)==tonumber(featEdit.Level)
                    and tostring(passiveEdit.PassiveList or "")==HB_ELEMENTAL_ADEPT_LIST then
                    PartialRespecChannel:SendToClient({ExperimentalError=
                        "Replace the feat without also staging edits to its elements."},
                        RespecViewerUser(characterGuid))
                    return
                end
            end
        end
    end
    if resourceEdits ~= nil or passiveEdits ~= nil or otherEdits ~= nil then
        if level ~= state.charLevel then
            PartialRespecChannel:SendToClient({ ExperimentalError = "Full-level replay required" }, RespecViewerUser(characterGuid))
            return
        end
        -- An unverified level-one edit must be refused BEFORE the state
        -- snapshot is patched. The historical UI remains navigable and the
        -- feature-verified level-2+ path is untouched.
        local levelOneRequested=false
        for _,batch in ipairs({passiveEdits or {},otherEdits or {},resourceEdits or {}}) do
            for _,edit in ipairs(batch) do
                if tonumber(edit.Level)==1 then levelOneRequested=true;break end
            end
            if levelOneRequested then break end
        end
        if levelOneRequested then
            RespecStartLog("LEVEL_ONE_NATIVE_GRANT_BRIDGE_PENDING actor="..characterGuid
                .." reason=original_native_selector_command_unverified")
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Level-one choice replay is temporarily disabled while its native class-grant integration is verified. Your original choices are unchanged."},
                RespecViewerUser(characterGuid))
            return
        end
        local patched = snapshot
        -- For the legacy experimental-edit path too, keep the safety backup
        -- unmodified when a validator mutates the working snapshot in-place.
        local untouched=originalSnapshot
        if not untouched then
            local copied,result=pcall(CopyPlainTable,snapshot)
            if not copied or type(result)~="table" then
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Could not preserve an untouched edit backup."},
                    RespecViewerUser(characterGuid))
                return
            end
            untouched=result
        end
        if resourceEdits and #resourceEdits > 0 then
            local valid, result, why = pcall(ValidateAndPatchExtraResources,
                patched, resourceEdits, state.charLevel)
            if not valid or not result then
                PartialRespecChannel:SendToClient({ ExperimentalError = tostring(why or result or "Resource validation failed") }, RespecViewerUser(characterGuid))
                return
            end
            patched = result
        end
        if passiveEdits and #passiveEdits > 0 then
            local valid, result, why = pcall(ValidateAndPatchClassPassives,
                patched, passiveEdits, state.charLevel)
            if not valid or not result then
                PartialRespecChannel:SendToClient({ ExperimentalError = tostring(why or result or "Passive validation failed") }, RespecViewerUser(characterGuid))
                return
            end
            patched = result
        end
        if otherEdits and #otherEdits > 0 then
            local valid, result, why = pcall(ValidateAndPatchOtherChoices,
                patched, otherEdits, state.charLevel)
            if not valid or not result then
                RespecStartLog("LEVEL_RESPEC_OTHER_CHOICE_REJECT actor="..characterGuid
                    .." reason="..tostring(why or result or "unknown"))
                PartialRespecChannel:SendToClient({ ExperimentalError = tostring(why or result or "Historical choice validation failed") }, RespecViewerUser(characterGuid))
                return
            end
            patched = result
        end
        if not (message.LevelRespecConfirm==true or (resourceEdits and #resourceEdits > 0)
                or (passiveEdits and #passiveEdits > 0) or (otherEdits and #otherEdits > 0)) then
            PartialRespecChannel:SendToClient({ ExperimentalError = "No staged edits" }, RespecViewerUser(characterGuid))
            return
        end
        -- An edited level-one class/subclass progression must be restored
        -- from its verified snapshot. The ordinary path continues to use
        -- vanilla level-one progression; only actual level-one selections
        -- opt into this carefully guarded reconstruction.
        local levelOneEdited=false
        for _,edit in ipairs(passiveEdits or {}) do
            if tonumber(edit.Level)==1 then levelOneEdited=true end
        end
        for _,edit in ipairs(otherEdits or {}) do
            if tonumber(edit.Level)==1 then levelOneEdited=true end
        end
        if levelOneEdited then
            local bucket=patched.progressions and patched.progressions.buckets
                and patched.progressions.buckets[1]
            if type(bucket)~="table" or #bucket==0 then
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Level-one progression ownership is unavailable; no edits applied."},
                    RespecViewerUser(characterGuid))
                return
            end
            local originalOne=untouched.components and untouched.components.ccLevelUp
                and untouched.components.ccLevelUp.LevelUps
                and untouched.components.ccLevelUp.LevelUps[1]
            local revisedOne=patched.components and patched.components.ccLevelUp
                and patched.components.ccLevelUp.LevelUps
                and patched.components.ccLevelUp.LevelUps[1]
            local function SameProtected(a,b,depth)
                if type(a)~=type(b) then return false end
                if type(a)~="table" then return a==b end
                if depth>16 then return false end
                for k,v in pairs(a) do
                    if not SameProtected(v,b[k],depth+1) then return false end
                end
                for k in pairs(b) do if a[k]==nil then return false end end
                return true
            end
            if not originalOne or not revisedOne then
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Original level-one foundation could not be verified."},
                    RespecViewerUser(characterGuid))
                return
            end
            local blocked=false
            for key,oldValue in pairs(originalOne) do
                if key~="Upgrades" and key~="Spells" then
                    if not SameProtected(oldValue,revisedOne[key],0) then blocked=true end
                end
            end
            if type(originalOne.Upgrades)~="table" or type(revisedOne.Upgrades)~="table" then
                blocked=true
            else
                for key,oldValue in pairs(originalOne.Upgrades) do
                    if key~="Passives" and key~="Spells" and key~="Skills"
                        and key~="SkillExpertise" then
                        if not SameProtected(oldValue,revisedOne.Upgrades[key],0) then
                            blocked=true
                        end
                    end
                end
            end
            if blocked then
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Level-one edits cannot change class, subclass, ability scores or identity."},
                    RespecViewerUser(characterGuid))
                return
            end
            -- Validate the WHOLE level-one diff before accepting the commit.
            -- Do not recreate any starting progression entity or ability bonus.
            local prepared,reason=PartialRespecSnapshot.ValidateLevelOneSurgery(
                characterGuid,untouched,patched)
            if not prepared then
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Level-one choice cannot be edited safely: "..tostring(reason)},
                    RespecViewerUser(characterGuid))
                return
            end
            patched.hbLevelOneSurgical=true
            -- Recovery opts in only AFTER writing an unmodified disk backup.
        end
        -- The original snapshot passed coverage checks, but an individual
        -- historical-edit validator may still have produced an invalid
        -- patched component or a sparse bucket. Revalidate the exact final
        -- replay payload before saving a backup or accepting Confirm.
        if message.LevelRespecConfirm==true then
            local complete,reason=ValidateLevelRespecReplayCoverage(patched,state.charLevel)
            if not complete then
                RespecStartLog("LEVEL_RESPEC_PATCHED_COVERAGE_REJECT actor="..characterGuid
                    .." reason="..tostring(reason))
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Edited progression is not safe to replay: "..tostring(reason)},
                    RespecViewerUser(characterGuid))
                return
            end
        end
        local saved, backup = SaveExperimentalBackup(characterGuid, untouched)
        if not saved then
            PartialRespecChannel:SendToClient({ ExperimentalError = "Cannot write unmodified backup: " .. tostring(backup) }, RespecViewerUser(characterGuid))
            return
        end
        snapshot = patched
        state.experimentalEdits = {}
        for _, edit in ipairs(resourceEdits or {}) do
            state.experimentalEdits[#state.experimentalEdits + 1] = edit
        end
        for _, edit in ipairs(passiveEdits or {}) do
            local row = CopyPlainTable(edit)
            row.Type = "ClassPassive"
            state.experimentalEdits[#state.experimentalEdits + 1] = row
        end
        for _, edit in ipairs(otherEdits or {}) do
            local row = CopyPlainTable(edit)
            row.Type = tostring(edit.Kind)
            state.experimentalEdits[#state.experimentalEdits + 1] = row
        end
        state.backupPath=backup
        PRPrint(0, "Selective Respec: %d validated changes at original level %d; backup %s",
            #state.experimentalEdits, level, backup)
    end

    -- No-change Selective Respec is still destructive (vanilla Confirm takes the
    -- character back to level one, then replay rebuilds it). Require a disk
    -- backup even when the request contains no edits at all.
    if message.LevelRespecConfirm==true and not state.backupPath then
        local saved,backup=SaveExperimentalBackup(characterGuid,originalSnapshot)
        if not saved then
            PartialRespecChannel:SendToClient({ExperimentalError=
                "Cannot preserve original build before Confirm: "..tostring(backup)},
                RespecViewerUser(characterGuid))
            return
        end
        state.backupPath=backup
    end

    state.level = level
    state.snapshot = snapshot
    state.originalSnapshot=originalSnapshot
    state.levelRespec = message.LevelRespecConfirm==true
    local ackMode=state.levelRespec and "Level" or "Partial"
    RespecStartLog("RESPEC_COMMIT_ACCEPTED actor="..characterGuid
        .." mode="..ackMode.." preserveThrough="..tostring(level)
        .." backup="..tostring(state.backupPath or "snapshot"))
    PartialRespecChannel:SendToClient({
        Character = characterGuid,
        Confirmed = true,
        AckMode=ackMode,
        RequestId=requestId,
    }, RespecViewerUser(characterGuid))

    PRPrint(0, "PR choice: keep levels 1-%d for %s", level, characterGuid)
end

PartialRespecChannel:SetHandler(function(message, user)
    local ok, err=pcall(HandlePartialRespecMessage,message,user)
    if ok then return end
    RespecStartLog("RESPEC_COMMIT_FATAL peer="..tostring(user)
        .." reason="..tostring(err))
    if type(message)=="table" and type(message.Character)=="string" then
        local actor=Guid(message.Character)
        if pendingRespec[actor] then
            local sendOK,sendErr=pcall(function()
                PartialRespecChannel:SendToClient({ExperimentalError=
                    "Respec preparation failed; no native confirmation was authorized. "
                    ..tostring(err), RequestId=message.RequestId},
                    RespecViewerUser(actor))
            end)
            if not sendOK then
                RespecStartLog("RESPEC_COMMIT_FATAL_REPLY_FAILED "..tostring(sendErr))
            end
        end
    end
end)
