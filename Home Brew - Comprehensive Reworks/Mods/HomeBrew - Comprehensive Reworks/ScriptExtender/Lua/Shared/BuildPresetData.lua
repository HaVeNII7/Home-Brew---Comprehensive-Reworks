-- Portable historical selections, never spellbook/hotbar/HP/casting snapshots.
-- Data contract is shared between the server capture and client list preview.
local M={}
local NIL='00000000-0000-0000-0000-000000000000'
local MAX_LEVEL=40
local allowed={Abilities=true,AbilityBonuses=true,Feats=true,Passives=true,
    Skills=true,SkillExpertise=true,Spells=true}
local function copyPlain(item,depth)
    depth=depth or 0
    if depth>14 then error('Historical selection nesting is excessive.') end
    local kind=type(item)
    if kind=='string' then
        if #item>1024 then error('Historical value exceeds size limit.') end
        return item
    elseif kind=='number' then
        if item~=item or math.abs(item)>9007199254740991 then error('Invalid historical number.') end
        return item
    elseif kind=='boolean' then return item
    elseif kind=='table' then
        local result,count={},0
        for k,v in pairs(item) do
            count=count+1
            if count>150 then error('Historical selection list is too large.') end
            if type(k)~='string' and type(k)~='number' then error('Invalid historical key.') end
            result[k]=copyPlain(v,depth+1)
        end
        return result
    elseif kind=='nil' then return nil end
    error('Unsupported engine-only field in historical selection.')
end
local function plainSnapshot(snapshot)
    -- SE's in-memory component serializer can expose enum userdata in
    -- CCLevelUp/ProgressionMeta. Its own JSON serializer emits their known
    -- literal names, as in HB_LevelEditor_Original backups. Never retain
    -- userdata or native C++ entity handles in a community build preset.
    if Ext and Ext.Json and Ext.Json.Stringify and Ext.Json.Parse then
        local ok,text=pcall(Ext.Json.Stringify,snapshot,
            {Beautify=false,StringifyInternalTypes=false})
        if not ok or type(text)~='string' then
            error('Character history contains unserializable native fields.')
        end
        local decoded,value=pcall(Ext.Json.Parse,text)
        if not decoded or type(value)~='table' then
            error('Cannot normalize character history for portable preset.')
        end
        return value
    end
    return snapshot
end
local function validGuid(value)
    return type(value)=='string' and value:match('^[a-fA-F0-9]+%-[a-fA-F0-9]+%-[a-fA-F0-9]+%-[a-fA-F0-9]+%-[a-fA-F0-9]+$')~=nil
end
function M.Extract(snapshot,name)
    snapshot=plainSnapshot(snapshot)
    if type(snapshot)~='table' or snapshot.schemaVersion~=2 then
        error('Original level-up history is unavailable.')
    end
    local classes=snapshot.components and snapshot.components.classes and snapshot.components.classes.Classes
    local ups=snapshot.components and snapshot.components.ccLevelUp and snapshot.components.ccLevelUp.LevelUps
    if type(ups)~='table' or type(classes)~='table' or #ups<1 or #ups>MAX_LEVEL then
        error('Cannot capture a complete class and level-up history.')
    end
    local result={Kind='HomeBrewBuild',Version=2,Name=name,LevelCount=#ups,Classes={},Levels={},ClassProgressions={}}
    for _,entry in ipairs(classes) do
        result.Classes[#result.Classes+1]={ClassUUID=tostring(entry.ClassUUID),
            SubClassUUID=tostring(entry.SubClassUUID or NIL),Level=tonumber(entry.Level)}
    end
    for level,source in ipairs(ups) do
        if not validGuid(source.Class) then error('Class history missing at level '..level) end
        local row={Level=level,Class=tostring(source.Class),SubClass=tostring(source.SubClass or NIL),
            Feat=tostring(source.Feat or NIL),Spells=copyPlain(source.Spells or {}),Upgrades={}}
        for key in pairs(allowed) do
            if key~='Abilities' then
                row.Upgrades[key]=copyPlain(source.Upgrades and source.Upgrades[key] or {})
            end
        end
        row.Abilities=copyPlain(source.Abilities or {})
        result.Levels[#result.Levels+1]=row
        if level>=2 then
            local entries={}
            local bucket=snapshot.progressions and snapshot.progressions.buckets
                and snapshot.progressions.buckets[level]
            if type(bucket)~='table' then
                error('Historical progression entities are unavailable at level '..level)
            end
            for _,entry in ipairs(bucket) do
                local meta=type(entry)=='table' and entry.meta
                if type(meta)=='table' and (meta.SpellSourceType=='ProgressionClass'
                    or meta.SpellSourceType=='ProgressionSubClass') then
                    -- These are per-level grants, not a character SpellBook or
                    -- runtime entity. A new character supplies its own race,
                    -- background, level-one, HP, hotbar and casting state.
                    local safe={}
                    for _,part in ipairs({'meta','feat','replicatedFeat','passives',
                        'spells','skills','abilityImprovements','levelUp'}) do
                        if entry[part]~=nil then safe[part]=copyPlain(entry[part]) end
                    end
                    entries[#entries+1]=safe
                end
            end
            result.ClassProgressions[level-1]=entries
        end
    end
    local ok,err=M.Validate(result)
    if not ok then error(err) end
    return result
end
function M.Validate(preset)
    if type(preset)~='table' or preset.Kind~='HomeBrewBuild' or (preset.Version~=1 and preset.Version~=2)
        or type(preset.Name)~='string' or #preset.Name<1 or #preset.Name>64
        or type(preset.LevelCount)~='number' or preset.LevelCount<1
        or preset.LevelCount>MAX_LEVEL or preset.LevelCount%1~=0
        or type(preset.Levels)~='table' or #preset.Levels~=preset.LevelCount
        or type(preset.Classes)~='table' or #preset.Classes<1 or #preset.Classes>MAX_LEVEL then
        return false,'Unsupported or incomplete build preset.'
    end
    local composition,levelSum={},0
    for _,entry in ipairs(preset.Classes) do
        if not validGuid(entry.ClassUUID) or not validGuid(entry.SubClassUUID)
            or type(entry.Level)~='number' or entry.Level<1 or entry.Level%1~=0 then
            return false,'Invalid class composition.'
        end
        composition[entry.ClassUUID]=(composition[entry.ClassUUID] or 0)+entry.Level
        levelSum=levelSum+entry.Level
    end
    if levelSum~=preset.LevelCount then return false,'Class levels do not add up.' end
    local recorded={}
    for level,row in ipairs(preset.Levels) do
        if type(row)~='table' or row.Level~=level or not validGuid(row.Class)
            or not validGuid(row.SubClass) or not validGuid(row.Feat)
            or type(row.Upgrades)~='table' or type(row.Spells)~='table'
            or type(row.Abilities)~='table' then
            return false,'Invalid historical record at level '..level
        end
        for key in pairs(allowed) do
            if key~='Abilities' and type(row.Upgrades[key])~='table' then
                return false,'Missing '..key..' choices at level '..level
            end
        end
        recorded[row.Class]=(recorded[row.Class] or 0)+1
    end
    for uuid,count in pairs(composition) do
        if recorded[uuid]~=count then return false,'Class progression differs from class totals.' end
    end
    for uuid in pairs(recorded) do
        if not composition[uuid] then return false,'Unknown historical class.' end
    end
    if preset.Version==2 then
        local templates=preset.ClassProgressions
        if type(templates)~='table' then return false,'Missing class progression templates.' end
        local classSub={}
        for _,record in ipairs(preset.Classes) do
            classSub[record.ClassUUID]=record.SubClassUUID
        end
        local classLevels={}
        for i,row in ipairs(preset.Levels) do
            if row.SubClass~=NIL and row.SubClass~=classSub[row.Class] then
                return false,'Recorded subclass does not belong to the class at level '..i
            end
            classLevels[row.Class]=(classLevels[row.Class] or 0)+1
            if i>=2 then
                local list=templates[i-1]
                if type(list)~='table' or #list<1 or #list>12 then
                    return false,'Missing or excessive class grants at level '..i
                end
                local owners={}
                for j,entry in ipairs(list) do
                    local m=type(entry)=='table' and entry.meta
                    if type(m)~='table' or not validGuid(m.Progression)
                        or not validGuid(m.Source) or m.Level~=i
                        or m.ClassLevel~=classLevels[row.Class] then
                        return false,'Invalid class grant identity at level '..i
                    end
                    local role=m.SpellSourceType
                    if role=='ProgressionClass' then
                        if m.Source~=row.Class then
                            return false,'Foreign class progression at level '..i
                        end
                    elseif role=='ProgressionSubClass' then
                        local sub=classSub[row.Class]
                        if sub==NIL or m.Source~=sub then
                            return false,'Foreign subclass progression at level '..i
                        end
                    else
                        return false,'Only class/subclass grant templates are portable.'
                    end
                    local identity=role..'|'..m.Progression
                    if owners[identity] then return false,'Repeated progression owner at level '..i end
                    owners[identity]=true
                    for key,value in pairs(entry) do
                        if key~='meta' and key~='feat' and key~='replicatedFeat'
                            and key~='passives' and key~='spells' and key~='skills'
                            and key~='abilityImprovements' and key~='levelUp' then
                            return false,'Unsupported engine field in class template.'
                        end
                        if type(value)~='table' then
                            return false,'Malformed class template component.'
                        end
                    end
                end
                -- Every explicitly chosen spell/passive must have a grant in
                -- the original same-level progression blueprint. This does
                -- not assert that arbitrary new stat IDs are installed, but
                -- prevents an imported CC selector from claiming powers the
                -- source progression never recorded.
                local function HasGrant(id,parts,field)
                    for _,entry in ipairs(list) do
                        for _,part in ipairs(parts) do
                            local obj=entry[part]
                            for _,grant in ipairs(obj and obj[field] or {}) do
                                local got=type(grant)=='table' and grant.SpellId or grant
                                if tostring(got)==tostring(id) then return true end
                            end
                        end
                    end
                    return false
                end
                for _,sel in ipairs(row.Upgrades.Passives or {}) do
                    for _,id in ipairs(sel.Passives or {}) do
                        if not HasGrant(id,{'passives','feat'},'AddPassives') then
                            return false,'Unbacked passive choice at level '..i..': '..tostring(id)
                        end
                    end
                end
                for _,sel in ipairs(row.Upgrades.Spells or {}) do
                    for _,id in ipairs(sel.Spells or {}) do
                        local proto=type(id)=='table' and (id.SpellId or id.SpellID) or id
                        if not HasGrant(proto,{'spells','feat'},'AddSpells') then
                            return false,'Unbacked spell selection at level '..i..': '..tostring(proto)
                        end
                    end
                end
                for _,entry in ipairs(list) do
                    for _,part in ipairs({'feat','replicatedFeat'}) do
                        local feat=entry[part] and entry[part].Feat
                        if feat and tostring(feat)~=NIL
                            and tostring(feat)~=row.Feat then
                            return false,'Progression feat differs from history at level '..i
                        end
                    end
                end
            end
        end
        for key in pairs(templates) do
            if type(key)~='number' or key<1 or key>=preset.LevelCount
                or key%1~=0 then return false,'Unexpected class template index.' end
        end
    end
    return true
end
-- Compare every portable player selection after the existing historical
-- validators have constructed a candidate build. This prevents a seemingly
-- successful import where a read-only/protected slot was silently skipped.
local function selectionAtom(item)
    if type(item)=='string' then return item end
    if type(item)=='table' then
        return tostring(item.SpellId or item.SpellID or item.Id or '')
    end
    return tostring(item or '')
end
local function joined(list)
    local result={}
    for _,item in ipairs(list or {}) do result[#result+1]=selectionAtom(item) end
    table.sort(result)
    return table.concat(result,'\31')
end
local function Rows(row,section)
    local upgrades=row.Upgrades or {}
    local records=section=='BaseSpells' and (row.Spells or {})
        or upgrades[section] or {}
    local result={}
    for _,entry in ipairs(records) do
        local key,picks='',nil
        if section=='BaseSpells' then
            key='base'
            picks=type(entry)=='table' and entry.Spells or {selectionAtom(entry)}
        elseif section=='Passives' then
            key=table.concat({tostring(entry.Type or ''),tostring(entry.Class or ''),
                tostring(entry.PassiveList or '')},'|')
            picks=entry.Passives
        elseif section=='Spells' then
            if type(entry)=='string' then key='raw';picks={entry}
            else
                key=table.concat({tostring(entry.Type or ''),tostring(entry.Class or ''),
                    tostring(entry.SpellList or '')},'|')
                picks=entry.Spells or {entry.SpellId}
            end
        elseif section=='Skills' or section=='SkillExpertise' then
            key=table.concat({tostring(entry.Type or ''),tostring(entry.Class or ''),
                tostring(entry.Skill or '')},'|')
            picks=section=='Skills' and entry.Proficiencies or entry.Expertise
        elseif section=='AbilityBonuses' then
            key=table.concat({tostring(entry.Type or ''),tostring(entry.Class or ''),
                tostring(entry.AbilityBonus or '')},'|')
            picks={}
            for i,ability in ipairs(entry.Bonuses or {}) do
                picks[#picks+1]=tostring(ability)..':'
                    ..tostring((entry.BonusAmounts or {})[i] or '?')
            end
        else
            error('Unsupported portable selection group.')
        end
        result[#result+1]=key..'='..joined(picks)
    end
    table.sort(result)
    return table.concat(result,'\30')
end
function M.MatchesSelections(preset,patched)
    local valid,reason=M.Validate(preset)
    if not valid then return false,reason end
    local worked,actual=pcall(M.Extract,patched,preset.Name)
    if not worked then return false,'Could not verify reconstructed build: '..tostring(actual) end
    if actual.LevelCount>preset.LevelCount then return false,'Character is above saved build level.' end
    for level=2,actual.LevelCount do
        local saved,live=preset.Levels[level],actual.Levels[level]
        if saved.Class~=live.Class or saved.SubClass~=live.SubClass
            or saved.Feat~=live.Feat then
            return false,'Class, subclass or feat differs at level '..level
        end
        if #saved.Abilities~=#live.Abilities then
            return false,'Base ability assignments differ at level '..level
        end
        for i,value in ipairs(saved.Abilities) do
            if value~=live.Abilities[i] then
                return false,'Base ability assignments differ at level '..level
            end
        end
        if #saved.Upgrades.Feats~=#live.Upgrades.Feats then
            return false,'Embedded feat selections differ at level '..level
        end
        -- Embedded feats are uncommon but never silently discard one.
        local function sameFeatRecord(a,b)
            if type(a)~=type(b) then return false end
            if type(a)~='table' then return a==b end
            for key,value in pairs(a) do if not sameFeatRecord(value,b[key]) then return false end end
            for key in pairs(b) do if a[key]==nil then return false end end
            return true
        end
        if not sameFeatRecord(saved.Upgrades.Feats,live.Upgrades.Feats) then
            return false,'Embedded feat selections differ at level '..level
        end
        for _,section in ipairs({'BaseSpells','AbilityBonuses','Passives',
            'Spells','Skills','SkillExpertise'}) do
            local okA,a=pcall(Rows,saved,section)
            local okB,b=pcall(Rows,live,section)
            if not okA or not okB or a~=b then
                return false,'Preset '..section..' selections differ at level '..level
            end
        end
    end
    return true
end

-- A preset is a progression recipe, not a saved-game character copy.
-- Only the native first-level CLASS and SUBCLASS need match. Never import
-- another character's race/background/first-level choices.
function M.Compatible(preset,snapshot)
    local valid,why=M.Validate(preset)
    if not valid then return false,why end
    if type(snapshot)~='table' or type(snapshot.components)~='table'
        or type(snapshot.components.ccLevelUp)~='table' then
        return false,'Current character progression is unavailable.'
    end
    local rows=snapshot.components.ccLevelUp.LevelUps
    if type(rows)~='table' or #rows<1 then
        return false,'Receiving character level-up history is missing.'
    end
    if #rows>preset.LevelCount then
        return false,'Preset ends at level '..preset.LevelCount
            ..'; a higher-level character cannot safely mix extra levels.'
    end
    local first=rows[1]
    if tostring(first.Class or NIL)~=preset.Levels[1].Class
        or tostring(first.SubClass or NIL)~=preset.Levels[1].SubClass then
        return false,'Starting class or subclass differs from the saved build.'
    end
    if preset.Version==1 then
        if #rows~=preset.LevelCount then
            return false,'Legacy V1 presets require the same character level.'
        end
        -- Legacy V1 files have choices only, not enough source-owned
        -- progression grants to change a level's class.
        for i=2,#rows do
            if preset.Levels[i].Class~=tostring(rows[i].Class)
                or preset.Levels[i].SubClass~=tostring(rows[i].SubClass or NIL) then
                return false,'Legacy preset cannot change a class at level '..i
            end
        end
    end
    return true
end
-- A shared preset may reference class, feat or spell definitions that are
-- not installed in the recipient's game. Check only the receiving character's
-- prefix; later levels of a longer preset are intentionally ignored.
function M.CheckInstalled(preset,target)
    if not Ext then return true end -- standalone offline test environment
    if not Ext.StaticData or not Ext.StaticData.Get or not Ext.Stats
        or not Ext.Stats.Get then
        return false,'Installed game definitions cannot be inspected.'
    end
    local seen={}
    local function StaticClass(id,level)
        if id==NIL or seen[id] then return true end
        local ok,entry=pcall(Ext.StaticData.Get,id,'ClassDescription')
        if not ok or not entry then
            return false,'Build class or subclass is not installed at level '..level
        end
        seen[id]=true
        return true
    end
    local function Stat(id,label,level)
        if type(id)~='string' or id=='' then return false,'Invalid '..label end
        local ok,value=pcall(Ext.Stats.Get,id)
        if not ok or not value then
            return false,'Build '..label..' is not installed at level '..level..': '..id
        end
        return true
    end
    local subs={}
    for _,row in ipairs(preset.Classes) do subs[row.ClassUUID]=row.SubClassUUID end
    for level=1,target do
        local row=preset.Levels[level]
        local yes,why=StaticClass(row.Class,level)
        if not yes then return false,why end
        yes,why=StaticClass(subs[row.Class] or NIL,level)
        if not yes then return false,why end
        if level>=2 then
            if row.Feat~=NIL then
                local ok,feat=pcall(Ext.StaticData.Get,row.Feat,'Feat')
                if not ok or not feat then return false,'Build feat is not installed at level '..level end
            end
            for _,entry in ipairs(row.Upgrades.Passives or {}) do
                for _,id in ipairs(entry.Passives or {}) do
                    yes,why=Stat(id,'passive',level)
                    if not yes then return false,why end
                end
            end
            for _,entry in ipairs(row.Upgrades.Spells or {}) do
                for _,id in ipairs(entry.Spells or {}) do
                    local value=type(id)=='table' and (id.SpellId or id.SpellID) or id
                    yes,why=Stat(value,'spell',level)
                    if not yes then return false,why end
                end
            end
        end
    end
    return true
end
local function Copy(value)
    return copyPlain(value)
end
local function TrustedCopy(value,depth)
    if type(value)~='table' then return value end
    if (depth or 0)>32 then error('Character snapshot nesting exceeds safe bounds.') end
    local result={}
    for k,v in pairs(value) do result[k]=TrustedCopy(v,(depth or 0)+1) end
    return result
end
-- Build a candidate snapshot BEFORE native Confirm. The donor contributes
-- only serialized class-owned grant components and its recorded level-up
-- choices; no donor spellbooks, race/background entities, casting pointers,
-- hotbar, HP or level one are carried across characters.
function M.Compose(preset,receiver)
    receiver=plainSnapshot(receiver)
    local valid,why=M.Compatible(preset,receiver)
    if not valid then return nil,why end
    if preset.Version~=2 then
        return nil,'Legacy preset needs native selection staging (no progression templates).'
    end
    local out=TrustedCopy(receiver)
    local old=receiver.components.ccLevelUp.LevelUps
    local target=#old
    local newups={Copy(old[1])}
    local counts,subs={},{}
    counts[newups[1].Class]=1
    -- A longer preset may earn its subclass only after the recipient's
    -- current level. Use choices actually reached, not final donor totals.
    if tostring(newups[1].SubClass or NIL)~=NIL then
        subs[newups[1].Class]=newups[1].SubClass
    end
    local newclasses={}
    local classOrder={newups[1].Class}
    for i=2,target do
        local row=preset.Levels[i]
        if row.Feat~=NIL and row.Feat==tostring(newups[1].Feat or NIL) then
            -- Do not silently produce a duplicate nonrepeatable level-one
            -- feat when importing the higher-level choice package.
            return nil,'An imported feat is already present at level one.'
        end
        -- A portable preset's Level number is a FILE ordinal, not a field
        -- in BG3's CCLevelUp.LevelUps C++ record. Its Upgrades also omit
        -- engine-owned fields such as Equipment, and its top-level record
        -- omits AccessorySet. Copying the entire preset row created a
        -- spurious Level field and discarded the native shape; the strict
        -- post-replay audit then (correctly) refused the mismatched history.
        -- Start with THIS recipient's actual serialized level-up record and
        -- replace ONLY the portable, validated player choices. This keeps
        -- engine-owned structure intact, without importing donor runtime
        -- data or ignoring differences in the final audit.
        local originalRow=old[i]
        if type(originalRow)~='table' or type(originalRow.Upgrades)~='table'
            or type(originalRow.Upgrades.Equipment)~='table'
            or next(originalRow.Upgrades.Equipment)~=nil then
            return nil,'Native equipment history cannot be transferred at level '..i
        end
        -- A nonempty accessory set from the receiver must not be copied
        -- into a different class when the portable preset has no owner proof.
        if row.Class~=originalRow.Class
            and tostring(originalRow.AccessorySet or NIL)~=NIL then
            return nil,'Class-specific accessory history cannot be transferred at level '..i
        end
        local nativeRow=Copy(originalRow)
        nativeRow.Class=row.Class
        nativeRow.SubClass=row.SubClass
        nativeRow.Feat=row.Feat
        nativeRow.Spells=Copy(row.Spells)
        nativeRow.Abilities=Copy(row.Abilities)
        for key in pairs(allowed) do
            if key~='Abilities' then
                nativeRow.Upgrades[key]=Copy(row.Upgrades[key])
            end
        end
        newups[i]=nativeRow
        if tostring(row.SubClass or NIL)~=NIL then
            subs[row.Class]=row.SubClass
        end
        counts[row.Class]=(counts[row.Class] or 0)+1
        if counts[row.Class]==1 then classOrder[#classOrder+1]=row.Class end
    end
    for _,class in ipairs(classOrder) do
        newclasses[#newclasses+1]={ClassUUID=class,Level=counts[class],
            SubClassUUID=subs[class] or NIL}
    end
    out.components.ccLevelUp.LevelUps=newups
    out.components.classes.Classes=newclasses
    for i=2,target do
        local retained={}
        local bucket=receiver.progressions and receiver.progressions.buckets
            and receiver.progressions.buckets[i]
        if type(bucket)~='table' then return nil,'Receiving level '..i..' lacks progression records.' end
        for _,entry in ipairs(bucket) do
            local role=entry.meta and entry.meta.SpellSourceType
            if role~='ProgressionClass' and role~='ProgressionSubClass' then
                retained[#retained+1]=Copy(entry)
            end
        end
        for _,entry in ipairs(preset.ClassProgressions[i-1] or {}) do
            retained[#retained+1]=Copy(entry)
        end
        if #retained<1 then return nil,'No verified progression at level '..i end
        out.progressions.buckets[i]=retained
    end
    -- Do not take donor SpellBook or copied live casting entries. The
    -- existing native restoration pass owns those; later audits must prove
    -- the selected class grants actually appeared.
    local classChanged=false
    for i=2,target do
        if tostring(old[i].Class or NIL)~=tostring(newups[i].Class or NIL)
            or tostring(old[i].SubClass or NIL)~=tostring(newups[i].SubClass or NIL) then
            classChanged=true;break
        end
    end
    out.hbBuildPresetImport={Name=preset.Name,Level=target,Version=2,
        ClassChange=classChanged}
    return out
end
-- Native caster remains game-owned on class-changing imports. Check
-- every imported level's class progression, its chosen passives, and its
-- directly selected spells after engine restoration. This is deliberately
-- stricter than a UI success acknowledgement: missing class grants fail.
local function Set(list,key)
    local result={}
    for _,entry in ipairs(list or {}) do
        local id=type(entry)=='table' and tostring(entry[key] or '')
            or tostring(entry or '')
        if id~='' then result[id]=(result[id] or 0)+1 end
    end
    return result
end
local function SameItems(a,b,key)
    local x,y=Set(a,key),Set(b,key)
    for id,n in pairs(x) do if y[id]~=n then return false end end
    for id,n in pairs(y) do if x[id]~=n then return false end end
    return true
end
-- Each historical spell selection grants ONE independent root spell.
-- BG3 may materialize _2.._6 cast variants (and other spell containers)
-- using the SAME OriginatorPrototype, class, and progression owner. Those
-- children are not additional historical selections. Counting all entries
-- with a matching OriginatorPrototype made a completely correct Wizard
-- import fail the audit merely because it could upcast a selected spell.
-- Require one (and only one) exact root identity with the correct owner.
-- Never accept children instead of a missing root, or a duplicate root.
-- ProgressionClass/SubClass selections have no direct spell source.
-- Feat selections instead retain the selected feat GUID as SpellId.Source;
-- their ProgressionSource is still the character class GUID. Check BOTH
-- fields, so valid feat spells are not misclassified as missing and no
-- unrelated cast source can satisfy the imported selection audit.
local function MatchLiveSpell(rows,id,progressionOwner,role,directSource)
    local roots,variants=0,0
    directSource=directSource or NIL
    for _,entry in ipairs(rows or {}) do
        local sid=type(entry)=='table' and (entry.Id or entry) or nil
        if type(sid)=='table' and tostring(sid.SourceType or '')==role
            and tostring(sid.ProgressionSource or '')==progressionOwner
            and tostring(sid.Source or NIL)==directSource then
            local origin=tostring(sid.OriginatorPrototype or '')
            if sid.Prototype==id and (origin==id or origin=='') then
                roots=roots+1
            elseif origin==id then
                variants=variants+1
            end
        end
    end
    return roots==1,roots,variants
end
function M.VerifyLiveImported(preset,expected,observed,original,actor)
    local ok,why=M.Validate(preset)
    if not ok then return false,why end
    if not expected.hbBuildPresetImport then return false,'Not a build import.' end
    local target=expected.hbBuildPresetImport.Level
    local cc=observed.components and observed.components.ccLevelUp
    local liveRows=cc and cc.LevelUps
    if type(liveRows)~='table' or #liveRows~=target then
        return false,'Imported level-up records are incomplete.'
    end
    local selectionsMatch,selectionsWhy=M.MatchesSelections(preset,observed)
    if not selectionsMatch then
        return false,'Imported higher-level choices differ: '..tostring(selectionsWhy)
    end
    local expClasses=expected.components and expected.components.classes
        and expected.components.classes.Classes
    local liveClasses=observed.components and observed.components.classes
        and observed.components.classes.Classes
    local function ClassCounts(rows)
        local map={}
        for _,row in ipairs(rows or {}) do
            local uuid=tostring(row.ClassUUID or '')
            if map[uuid] then return nil end
            map[uuid]={Level=tonumber(row.Level),SubClass=tostring(row.SubClassUUID or NIL)}
        end
        return map
    end
    local wanted,actual=ClassCounts(expClasses),ClassCounts(liveClasses)
    if not wanted or not actual then return false,'Invalid imported class totals.' end
    for uuid,row in pairs(wanted) do
        if not actual[uuid] or actual[uuid].Level~=row.Level
            or actual[uuid].SubClass~=row.SubClass then
            return false,'Imported class distribution differs: '..uuid
        end
    end
    for uuid in pairs(actual) do if not wanted[uuid] then
        return false,'Unexpected extra class after import.'
    end end
    local have=observed.components and observed.components.spellBook
        and observed.components.spellBook.Spells
    if type(have)~='table' then return false,'Live SpellBook is unavailable.' end
    for level=2,target do
        local want=expected.progressions and expected.progressions.buckets
            and expected.progressions.buckets[level]
        local got=observed.progressions and observed.progressions.buckets
            and observed.progressions.buckets[level]
        if type(want)~='table' or type(got)~='table' or #want~=#got then
            return false,'Progression count differs at imported level '..level
        end
        local used={}
        for _,entry in ipairs(want) do
            local wm=entry.meta
            if type(wm)=='table' and (wm.SpellSourceType=='ProgressionClass'
                or wm.SpellSourceType=='ProgressionSubClass') then
                local found=0
                for j,live in ipairs(got) do
                    local lm=live.meta
                    if not used[j] and type(lm)=='table'
                        and tostring(lm.Progression)==tostring(wm.Progression)
                        and tostring(lm.Source)==tostring(wm.Source)
                        and tostring(lm.SpellSourceType)==tostring(wm.SpellSourceType)
                        and tonumber(lm.Level)==level
                        and tonumber(lm.ClassLevel)==tonumber(wm.ClassLevel) then
                        if not SameItems(entry.passives and entry.passives.AddPassives,
                            live.passives and live.passives.AddPassives)
                            or not SameItems(entry.spells and entry.spells.AddSpells,
                                live.spells and live.spells.AddSpells,'SpellId')
                            or not SameItems(entry.feat and entry.feat.AddPassives,
                                live.feat and live.feat.AddPassives) then
                            return false,'An imported progression grant changed at level '..level
                        end
                        local beforeFeat=entry.feat and entry.feat.Feat
                        local afterFeat=live.feat and live.feat.Feat
                        if tostring(beforeFeat or NIL)~=tostring(afterFeat or NIL) then
                            return false,'A progression feat changed at level '..level
                        end
                        used[j]=true;found=found+1
                    end
                end
                if found~=1 then return false,'Class progression owner missing at level '..level end
            end
        end
        local row=preset.Levels[level]
        if actor and Osi and Osi.HasPassive then
            for _,selector in ipairs(row.Upgrades.Passives or {}) do
                for _,id in ipairs(selector.Passives or {}) do
                    local present=Osi.HasPassive(actor,tostring(id))
                    if present~=1 and present~=true then
                        return false,'Imported passive is not active: '..tostring(id)
                    end
                end
            end
        end
        for _,selector in ipairs(row.Upgrades.Spells or {}) do
            local picks=selector.Spells or {}
            local role=selector.Type=='Class' and 'ProgressionClass'
                or selector.Type=='SubClass' and 'ProgressionSubClass'
                or selector.Type=='Feat' and 'Feat' or nil
            if not role then return false,'Unsupported imported spell source.' end
            local owner=tostring(selector.Class or '')
            local directSource=NIL
            if role=='Feat' then
                -- CCLevelUp records the feat GUID in selector.Class, while
                -- the spellbook stores it in Id.Source (not ProgressionSource).
                -- Never accept another feat's spell as this choice's grant.
                directSource=owner
                owner=tostring(row.Class or '')
                if directSource==NIL or directSource~=tostring(row.Feat or NIL) then
                    return false,'Imported feat spell owner differs from recorded feat at level '..level
                end
            end
            if owner=='' then return false,'Imported spell ownership missing.' end
            for _,pick in ipairs(picks) do
                local id=type(pick)=='table' and (pick.SpellId or pick.SpellID) or pick
                if type(id)~='string' then
                    return false,'Invalid imported spell choice: '..tostring(id)
                end
                local validRoot,rootCount,variantCount=MatchLiveSpell(have,id,owner,role,directSource)
                if not validRoot then
                    return false,'Imported spell missing with correct class owner: '..tostring(id)
                        ..' [independentRoots='..tostring(rootCount)
                        ..' sameOwnerVariants='..tostring(variantCount)
                        ..' role='..tostring(role)..' progressionOwner='..owner
                        ..' directSource='..directSource..']'
                end
            end
        end
    end
    return true,nil
end
return M
