-- Plan historical edits from portable choices. This module NEVER writes live
-- progression. The existing server validators/audits own all reconstruction.
local M={}
local NULL='00000000-0000-0000-0000-000000000000'
local ACCORD='cdcbc538-883b-401c-a8ed-1373fb6d1720'
local ELEMENT='fdf0be80-cc1e-4501-bd2e-7a1ea737362c'
local MULTI='be0889d2-f9aa-472d-b942-592bff0f1ef3'
local function tostringid(item)
    if type(item)=='string' then return item end
    if type(item)=='table' then return item.SpellId or item.SpellID end
end
local function opt(row,id)
    for _,item in ipairs(row.Options or {}) do
        if tostring(item.Id)==tostring(id) then return true end
    end
    return false
end
local function selectOwned(donor,list,feat)
    local selected={}
    for _,row in ipairs(list or {}) do
        if row.Type=='Feat' and tostring(row.Class)==feat then selected[#selected+1]=row end
    end
    return selected
end
local function choicesForFeat(donor,feat)
    local upgrades=donor.Upgrades or {}
    local result={}
    local passive=selectOwned(donor,upgrades.Passives,feat)
    local spells=selectOwned(donor,upgrades.Spells,feat)
    local skills=selectOwned(donor,upgrades.Skills,feat)
    if feat==ELEMENT then
        if #passive~=1 or #passive[1].Passives~=2 then
            error('Incomplete Elemental Adept choices in preset.') end
        result.ElementChoices=passive[1].Passives
    elseif feat==ACCORD then
        if #spells~=1 or #spells[1].Spells~=2 then error('Incomplete Accord cantrips in preset.') end
        result.AccordChoices={}
        for _,id in ipairs(spells[1].Spells) do
            result.AccordChoices[#result.AccordChoices+1]=tostringid(id)
        end
    elseif feat==MULTI then
        if #passive~=2 or #skills~=1 then
            error('Incomplete Multifaceted choices in preset.') end
        local a,t=nil,nil
        for _,row in ipairs(passive) do
            if row.SelectorId=='Archetypes' then a=row.Passives
            elseif row.SelectorId=='Traits' then t=row.Passives end
        end
        local sk=skills[1].Proficiencies
        if not a or #a~=1 or not t or #t~=1 or not sk or #sk~=4 then
            error('Incomplete Multifaceted package in preset.') end
        result.MultifacetedChoices={Archetype=a,Trait=t,Skills=sk}
    elseif #passive>0 or #spells>0 then
        if #spells>0 then
            if #passive>0 then error('Mixed unrecognized feat selectors cannot be imported automatically.') end
            result.GenericFeatChoices={}
            for _,row in ipairs(spells) do
                local picks={}
                for _,id in ipairs(row.Spells or {}) do picks[#picks+1]=tostringid(id) end
                result.GenericFeatChoices[#result.GenericFeatChoices+1]=picks
            end
        elseif #passive==1 and #passive[1].Passives==2 then
            -- The receiver uses its own feat rule to interpret two-choice
            -- passive packages; both shapes are included for compatibility.
            result.PassiveFeatChoices=passive[1].Passives
            result.GenericFeatChoices={passive[1].Passives}
        else
            result.GenericFeatChoices={}
            for _,row in ipairs(passive) do
                result.GenericFeatChoices[#result.GenericFeatChoices+1]=row.Passives or {}
            end
        end
    end
    return result
end
local function fromRow(donor,choice)
    if choice.Kind=='Feat' then return donor.Feat end
    local upgrades=donor.Upgrades or {}
    local source=choice.Source
    local entries=source=='Spells' and donor.Spells or upgrades[source]
    if source=='Upgrades.Spells' then entries=upgrades.Spells end
    if type(entries)~='table' then return nil end
    local entry=entries[choice.EntryIndex]
    if not entry then return nil end
    if choice.Kind=='Skill' or choice.Kind=='Expertise' then
        if tostring(entry.Skill or '')~=tostring(choice.List or '') then return nil end
        local picks=choice.Kind=='Skill' and entry.Proficiencies or entry.Expertise
        return type(picks)=='table' and picks[choice.SlotIndex] or nil
    elseif choice.Kind=='Ability' then
        if tostring(entry.AbilityBonus or '')~=tostring(choice.List or '') then return nil end
        return entry.Bonuses and entry.Bonuses[choice.SlotIndex]
    elseif choice.Kind=='Spell' or choice.Kind=='Cantrip' then
        if type(entry)=='string' then return choice.SlotIndex==1 and entry or nil end
        if tostring(entry.SpellList or entry.SpellListId or entry.SpellListID or '')
            ~=tostring(choice.List or '') then return nil end
        local item=entry.Spells and entry.Spells[choice.SlotIndex]
        return tostringid(item or (choice.SlotIndex==1 and entry.SpellId))
    end
    return nil
end
function M.Plan(preset,summaries)
    if type(preset)~='table' or type(preset.Levels)~='table'
        or type(summaries)~='table' or #summaries~=preset.LevelCount then
        return nil,'Preset and character levels do not match.'
    end
    local other,passives,resource={},{},{}
    local total=0
    for lvl=2,preset.LevelCount do
        local donor=preset.Levels[lvl]
        local choice=summaries[lvl] and summaries[lvl].LevelChoices
        if not donor or not choice or choice.HistoryAvailable==false then
            return nil,'Missing recorded choices at level '..lvl
        end
        local originalFeat=choice.Source and choice.Source.FeatId or NULL
        local newFeat=tostring(donor.Feat or NULL)
        if originalFeat==nil then originalFeat=NULL end
        local featChanged=tostring(originalFeat)~=newFeat
        for _,row in ipairs(choice.OtherChoices or {}) do
            if not (featChanged and row.Kind~='Feat'
                and tostring(row.FeatOwnerId or '')==tostring(originalFeat)) then
                local target=fromRow(donor,row)
                if type(target)~='string' or target=='' then
                    return nil,'Preset lacks a recorded '..tostring(row.Kind)..' slot at level '..lvl
                end
                if target~=tostring(row.From) then
                    if row.Editable~=true or not opt(row,target) then
                        return nil,'A preset choice is not available at level '..lvl..': '..target
                    end
                    local edit={Level=lvl,Kind=row.Kind,Source=row.Source,
                        List=row.List,EntryIndex=row.EntryIndex,SlotIndex=row.SlotIndex,
                        From=row.From,To=target}
                    if row.Kind=='Feat' then
                        local success,package=pcall(choicesForFeat,donor,target)
                        if not success then return nil,tostring(package) end
                        for k,v in pairs(package) do edit[k]=v end
                        if edit.GenericFeatChoices and edit.PassiveFeatChoices then
                            -- Pair feats use PassiveFeatChoices, not GenericFeatChoices.
                            edit.GenericFeatChoices=nil
                        end
                    end
                    other[#other+1]=edit;total=total+1
                end
            end
        end
        -- Only class-owned native selector groups should be modified here.
        -- Feat-owned passive rows are reconstructed by the feat constructor.
        for _,group in ipairs(choice.EditablePassiveGroups or {}) do
            if not (featChanged and group.FeatOwnerVerified
                and tostring(group.FeatOwnerId or '')==tostring(originalFeat)) then
                local found=nil
                for _,row in ipairs(donor.Upgrades.Passives or {}) do
                    if tostring(row.PassiveList or '')==tostring(group.PassiveList or '')
                        and tostring(row.SelectorId or '')==tostring(group.SelectorId or '') then
                        if found then return nil,'Ambiguous passive group at level '..lvl end
                        found=row
                    end
                end
                if not found or #found.Passives~=#(group.Picked or {}) then
                    return nil,'Cannot match passive selector at level '..lvl
                end
                -- Selector picks are sets, not positional slots: moving
                -- two chosen passives between positions is not a change.
                local originalSet,targetSet,removed,added={},{},{},{}
                for _,id in ipairs(group.Picked or {}) do
                    if originalSet[id] then return nil,'Duplicated original passive at level '..lvl end
                    originalSet[id]=true
                end
                for _,id in ipairs(found.Passives) do
                    if type(id)~='string' or targetSet[id] then
                        return nil,'Duplicated/invalid saved passive at level '..lvl end
                    targetSet[id]=true
                end
                for id in pairs(originalSet) do if not targetSet[id] then removed[#removed+1]=id end end
                for id in pairs(targetSet) do
                    if not originalSet[id] then
                        local exists=false
                        for _,candidate in ipairs(group.Options or {}) do
                            if tostring(candidate.PassiveId)==id then exists=true;break end
                        end
                        if not exists then return nil,'Unsupported passive '..id..' at level '..lvl end
                        added[#added+1]=id
                    end
                end
                if #removed~=#added then return nil,'Passive selector cardinality changed at level '..lvl end
                table.sort(removed);table.sort(added)
                for i,from in ipairs(removed) do
                    passives[#passives+1]={Level=lvl,SelectorId=group.SelectorId,
                        PassiveList=group.PassiveList,From=from,To=added[i]}
                    total=total+1
                end
            end
        end
        -- Extra-resource choices are component-owned and must not be guessed.
        -- If the original level had one, the exact ID must remain recorded in
        -- the imported level; generalized extra-resource staging comes later.
        local extra=choice.ExtraResources or {}
        for _,id in ipairs(extra) do
            local observed=false
            for _,row in ipairs(donor.Upgrades.Passives or {}) do
                for _,p in ipairs(row.Passives or {}) do if tostring(p)==tostring(id) then observed=true end end
            end
            if not observed then
                return nil,'An extra-resource choice needs manual review at level '..lvl
            end
        end
    end
    return {Other=other,Passives=passives,Resources=resource,Count=total}
end
return M
