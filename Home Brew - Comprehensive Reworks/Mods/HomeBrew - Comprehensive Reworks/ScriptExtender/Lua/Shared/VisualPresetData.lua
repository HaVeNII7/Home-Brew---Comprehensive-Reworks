local M = {}
M.Version = 1
M.Selections = {
    {'SelectedHead','SelectableHeads'}, {'SelectedTopOfHead','SelectableTopOfHead'},
    {'SelectedChin','SelectableChin'}, {'SelectedJaw','SelectableJaw'},
    {'SelectedHair','SelectableHair'}, {'SelectedBeard','SelectableBeards'},
    {'SelectedHorn','SelectableHorns'}, {'SelectedTail','SelectableTail'},
    {'SelectedGenitals','SelectableGenitals'}, {'SelectedScales','SelectableScales'},
    {'SelectedScar','SelectableScars'}, {'SelectedTattoo','SelectableTattoos'},
    {'SelectedMakeup','SelectableMakeup'}, {'SelectedPiercing','SelectablePiercings'},
    {'SelectedSkinColour','SelectableSkinColours'}, {'SelectedEyeColour','SelectableEyeColours'},
    {'SelectedHairColour','SelectableHairColours'}, {'SelectedHighlightColour','SelectableHighlightColours'},
    {'SelectedGrayingColour','SelectableGrayingColours'}, {'SelectedTattooColour','SelectableTattooColours'},
    {'SelectedMakeupColour','SelectableMakeupColours'}, {'SelectedLipsMakeupColour','SelectableLipsMakeupColours'},
    {'SelectedHornColour','SelectableHornColours'}, {'SelectedHornTipColour','SelectableHornTipColours'},
    {'SelectedPassiveColour','SelectablePassiveColours'}, {'SelectedHeterochromiaEyeColour','SelectableEyeColours'},
}
M.Groups = {'ApperanceScalarAge','ApperanceScalarFreckles','ApperanceScalarFrecklesIntensity','ApperanceScalarVitiligo',
    'AppearanceHairGraying','AppearanceHairHighlights','AppearanceHornColor','AppearanceHornTipColor',
    'AppearanceLipsMakeup','AppearanceMakeup','AppearancePassive','AppearanceScars','AppearanceTattoos'}

function M.Read(object, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
end

function M.Count(object)
    if object == nil then return 0 end
    local ok, result = pcall(function() return #object end)
    if ok and type(result) == 'number' then return result end
    return M.Read(object,'Count') or 0
end

local function Atom(value)
    local kind = type(value)
    if kind == 'string' then
        if value == '' or value:find('s_HandleUnknown',1,true) then return nil end
        return value
    end
    if kind == 'number' or kind == 'boolean' then return value end
    local handle = M.Read(value,'Handle')
    if handle ~= nil and handle ~= value then return Atom(handle) end
end

function M.Properties(object)
    local ok, values = pcall(function() return object:GetAllProperties() end)
    if ok and type(values) == 'table' then return values end
    return type(object) == 'table' and object or {}
end

function M.Identity(object)
    if not object then return nil end
    local result = {}
    -- Material options expose Description in addition to Guid/Name/Icon.
    -- Preserve it as an extra discriminator only for materials, so other
    -- existing appearance/race identities retain their prior semantics.
    local material = tostring(M.Read(object,'Type')):find('VMSelectableMaterial',1,true)~=nil
    for key, value in pairs(M.Properties(object)) do
        local low = tostring(key):lower()
        if low == 'isnull' or (material and low == 'description') or
            (not low:match('^is') and not low:match('^has') and
            (low:find('guid',1,true) or low:find('uuid',1,true) or low:find('id',1,true)
            or low:find('name',1,true) or low:find('icon',1,true) or low:find('resource',1,true)
            or low == 'color' or low == 'colour' or low == 'text')) then
            local atom = Atom(value)
            if atom ~= nil then result[tostring(key)] = atom end
        end
    end
    if next(result) then return result end
end

local function SameIdentity(object, identity)
    if not identity then return false end
    for key, expected in pairs(identity) do
        if Atom(M.Read(object,key)) ~= expected then return false end
    end
    return true
end

-- Character creation can supply a new race VM whose presentation Name is
-- different from the one recorded by a previous campaign. Prefer verified
-- stable race IDs over localized/display metadata. Never accept conflicting IDs.
local function SameRace(object, identity)
    if not object or type(identity)~='table' then return false end
    local anchored=false
    for _,key in ipairs({'Guid','UUID','IDString'}) do
        local expected=identity[key]
        local actual=Atom(M.Read(object,key))
        if type(expected)=='string' and expected~='' and type(actual)=='string' and actual~='' then
            if key=='Guid' or key=='UUID' then
                if actual:lower()~=expected:lower() then return false end
            elseif actual~=expected then return false end
            anchored=true
        end
    end
    -- Older/custom identities without a shared stable identifier still require
    -- the original strict comparison; don't match based only on a display name.
    return anchored or SameIdentity(object,identity)
end

local function BodyIdentity(value)
    local result=Atom(value)
    if result~=nil then return result end
    -- Some native pages expose the same fixed BG3 enum as userdata. Only map
    -- explicitly known members; don't turn arbitrary userdata into a body type.
    if type(value)=='userdata' or type(value)=='table' then
        local ok,label=pcall(tostring,value)
        if ok and type(label)=='string' then
            local member=label:match('^BodyTypeAndShape%.([%a]+)$') or label
            if member=='Male' or member=='Female' or member=='MaleStrong' or member=='FemaleStrong' then
                return member
            end
        end
    end
end

-- Read-only compatibility detail for diagnostics; never treats a failed race
-- check as an override or tries to select a different race on the player's behalf.
function M.CompatibilityTrace(context,preset)
    local selected=M.Read(context,'SelectedRace')
    local saved=preset and preset.Race or {}
    return 'savedRaceGuid='..tostring(saved.Guid or saved.UUID)
        ..'; liveRaceGuid='..tostring(Atom(M.Read(selected,'Guid')) or Atom(M.Read(selected,'UUID')))
        ..'; savedRaceID='..tostring(saved.IDString)
        ..'; liveRaceID='..tostring(Atom(M.Read(selected,'IDString')))
        ..'; savedRaceName='..tostring(saved.Name)
        ..'; liveRaceName='..tostring(Atom(M.Read(selected,'Name')))
        ..'; savedBody='..tostring(preset and preset.Body)
        ..'; liveBody='..tostring(BodyIdentity(M.Read(context,'BodyTypeAndShape')))
        ..'; rawLiveBody='..tostring(M.Read(context,'BodyTypeAndShape'))
        ..'; initialized='..tostring(M.Read(context,'IsInitialized'))
end

local function EquivalentRepeatedIdentity(identity)
    if type(identity)~='table' then return false end
    if identity.IsNull==true then return true end
    for key,value in pairs(identity) do
        local lower=tostring(key):lower()
        if (lower=='guid' or lower=='uuid' or lower:match('guid$') or lower:match('uuid$'))
            and type(value)=='string' then
            local hex=value:gsub('%-','')
            if #hex==32 and hex:match('^%x+$') and hex:find('[1-9a-fA-F]') then
                return true
            end
        end
    end
    return false
end

-- Only use an index for duplicates when their exact game-owned selected
-- object can be proven, and the complete exposed option catalogue is recorded.
-- This is a guarded fallback, not permission to guess among similar cosmetics.
local function SameObject(a,b)
    if a==nil or b==nil then return false end
    if rawequal(a,b) then return true end
    local ok,equal=pcall(function() return a==b end)
    return ok and equal==true
end

local function SameDescriptor(a,b)
    if type(a)~='table' or type(b)~='table' then return a==nil and b==nil end
    for key,value in pairs(a) do if b[key]~=value then return false end end
    for key,value in pairs(b) do if a[key]~=value then return false end end
    return true
end

local function Catalogue(collection)
    local count=M.Count(collection)
    if type(count)~='number' or count<1 or count>512 or count%1~=0 then
        error('The appearance option list is too large to disambiguate safely.')
    end
    local result={}
    for i=1,count do result[i]=M.Identity(M.Read(collection,i)) or {} end
    return result
end

local function CheckChoice(collection,choice,label)
    local count=M.Count(collection)
    if type(choice)~='table' or type(choice.Index)~='number' or choice.Index%1~=0
        or choice.Index<1 or choice.Index>count or type(choice.Catalogue)~='table'
        or #choice.Catalogue~=count or count>512 then
        error('Saved '..tostring(label or 'appearance')..' selection has invalid disambiguation data.')
    end
    for i=1,count do
        if not SameDescriptor(M.Identity(M.Read(collection,i)),choice.Catalogue[i]) then
            error('The '..tostring(label or 'appearance')..' options changed since this preset was saved.')
        end
    end
    return M.Read(collection,choice.Index)
end

local function CaptureChoice(collection,selected,identity,label)
    local matches={}
    for i=1,M.Count(collection) do
        local candidate=M.Read(collection,i)
        if SameIdentity(candidate,identity) then
            matches[#matches+1]={Index=i,Item=candidate}
        end
    end
    if #matches==0 then error('An appearance option is still loading. Try saving again.') end
    if #matches==1 or EquivalentRepeatedIdentity(identity) then return nil end

    -- Prefer raw Lua object identity. Some SE bridges produce distinct proxies
    -- for the same C++ instance; equality is accepted only when exactly one
    -- matching option equals the currently selected game-owned object.
    local raw,byEquality={},{ }
    for _,candidate in ipairs(matches) do
        if rawequal(candidate.Item,selected) then raw[#raw+1]=candidate.Index end
        if SameObject(candidate.Item,selected) then byEquality[#byEquality+1]=candidate.Index end
    end
    local indexes=#raw==1 and raw or byEquality
    if #indexes~=1 then
        error('More than one appearance option matches this preset ('..tostring(label)
            ..'; '..#matches..' entries; selected native option cannot be identified uniquely).')
    end
    return {Index=indexes[1],Catalogue=Catalogue(collection)}
end

function M.Find(collection, identity, label, choice)
    if choice~=nil then
        local candidate=CheckChoice(collection,choice,label)
        if not SameIdentity(candidate,identity) then
            error('The saved '..tostring(label or 'appearance')..' option no longer matches its position.')
        end
        return candidate
    end
    local match, matches=nil,0
    for i=1,M.Count(collection) do
        local candidate=M.Read(collection,i)
        if SameIdentity(candidate,identity) then
            matches=matches+1
            if not match then match=candidate end
        end
    end
    if matches>1 and not EquivalentRepeatedIdentity(identity) then
        error('More than one appearance option matches this preset ('..tostring(label or 'unknown slot')
            ..'; '..matches..' matches without a stable GUID or explicit empty option).')
    end
    return match
end

local function Primitive(value)
    return type(value)=='boolean' or (type(value)=='number' and value==value and math.abs(value)<1e9)
end

local function Descriptor(object, label)
    local identity = M.Identity(object)
    if not identity then
        label=label:gsub('^Selected',''):gsub('(%l)(%u)','%1 %2'):lower()
        error('This '..label..' option cannot be saved yet.')
    end
    return identity
end

function M.Compatible(context, preset)
    if not SameRace(M.Read(context,'SelectedRace'),preset.Race) then return false,'Select the preset\'s race before loading it.' end
    if preset.SubRace and not SameRace(M.Read(context,'SelectedSubRace'),preset.SubRace) then
        return false,'Select the preset\'s subrace before loading it.'
    end
    local body = BodyIdentity(M.Read(context,'BodyTypeAndShape'))
    if preset.Body ~= nil and body ~= preset.Body then return false,'Select the preset\'s body type before loading it.' end
    for _, entry in ipairs(preset.BodyOptions or {}) do
        if not M.Find(M.Read(context,entry.Source),entry.Identity,entry.Source,entry.Choice) then
            return false,'This preset needs a different body type or an appearance mod that is not loaded.'
        end
    end
    return true
end

local function ActiveGroup(context,name)
    if name~='AppearancePassive' then return true end
    if M.Read(context,'IsDragonborn')==true then return true end
    local scales=M.Read(context,'SelectedScales')
    return scales~=nil and M.Read(scales,'IsNull')~=true
end

-- Both New Game and the Magic Mirror use the character appearance context.
-- In the mirror IsCreation may be false; restrict editing to an initialized,
-- unlocked appearance context with a real race and body type instead.
function M.CanEdit(context)
    return context~=nil and M.Read(context,'IsInitialized')==true
        and M.Read(context,'IsLocked')~=true
        and M.Read(M.Read(context,'SelectedOrigin'),'IsLockedAppearance')~=true
        and M.Read(context,'SelectedRace')~=nil
        and M.Read(context,'BodyTypeAndShape')~=nil
end

function M.Capture(context)
    if not M.CanEdit(context) then
        error('Choose a character whose appearance can be edited.')
    end
    local result = {Version=M.Version,Race=Descriptor(M.Read(context,'SelectedRace'),'race'),
        Body=BodyIdentity(M.Read(context,'BodyTypeAndShape')),Selections={},Groups={},BodyOptions={}}
    local subrace = M.Read(context,'SelectedSubRace')
    if subrace then result.SubRace=Descriptor(subrace,'subrace') end
    local heterochromia = M.Read(context,'HeterochromiaEnabled')
    if type(heterochromia)=='boolean' then result.Heterochromia=heterochromia end
    for _, pair in ipairs(M.Selections) do
        local selected, source = M.Read(context,pair[1]), M.Read(context,pair[2])
        -- Chin is normally absent on vanilla characters. Record that absence
        -- explicitly so a modded Chin slot can be cleared when a preset loads.
        if pair[1]=='SelectedChin' and (not selected or M.Read(selected,'IsNull')==true) then
            result.Selections.SelectedChin={Source=pair[2],None=true}
        elseif selected and (pair[1]~='SelectedHeterochromiaEyeColour' or heterochromia) then
            local identity=Descriptor(selected,pair[1])
            local choice=CaptureChoice(source,selected,identity,pair[1])
            result.Selections[pair[1]]={Source=pair[2],Identity=identity,Choice=choice}
            if pair[1]=='SelectedHead' or pair[1]=='SelectedGenitals' then
                result.BodyOptions[#result.BodyOptions+1]={Source=pair[2],Identity=identity,Choice=choice}
            end
        end
    end
    if not next(result.Selections) then error('Appearance options are not ready yet.') end
    for _, name in ipairs(M.Groups) do
        local group = M.Read(context,name)
        if group and ActiveGroup(context,name) then
            local saved={Options={}}
            local value=M.Read(group,'Value')
            if Primitive(value) then saved.Value=value end
            local options=M.Read(group,'ColorOptions')
            for i=1,M.Count(options) do
                local option=M.Read(options,i)
                local current=M.Read(option,'Value')
                if Primitive(current) then
                    saved.Options[#saved.Options+1]={Identity=M.Identity(option),Index=i,Value=current,
                        Kind=Atom(M.Read(option,'ListItemType'))}
                end
            end
            local empty=M.Read(group,'EmptyMaterialSelected')
            if name=='AppearancePassive' and M.Read(context,'IsDragonborn')==true and type(empty)=='boolean' then saved.EmptyMaterial=empty end
            if saved.Value~=nil or #saved.Options>0 or saved.EmptyMaterial~=nil then result.Groups[name]=saved end
        end
    end
    return result
end

local function Option(group, saved)
    local options=M.Read(group,'ColorOptions')
    if saved.Identity then return M.Find(options,saved.Identity,'appearance group option') end
    local candidate=M.Read(options,saved.Index)
    if candidate and Atom(M.Read(candidate,'ListItemType'))==saved.Kind then return candidate end
end

local function CheckValue(object, value)
    if not Primitive(value) or type(M.Read(object,'Value'))~=type(value) then error('A saved appearance setting is no longer available.') end
    if type(value)=='number' then
        local min,max=M.Read(object,'Min'),M.Read(object,'Max')
        if (type(min)=='number' and value<min) or (type(max)=='number' and value>max) then
            error('A saved appearance setting is outside the available range.')
        end
    end
end

function M.Validate(context, preset)
    if type(preset)~='table' or preset.Version~=M.Version or type(preset.Selections)~='table'
        or type(preset.Groups)~='table' then error('This preset has an unsupported format.') end
    local compatible,reason=M.Compatible(context,preset)
    if not compatible then error(reason) end
    local known={}
    for _,pair in ipairs(M.Selections) do known[pair[1]]=pair[2] end
    for key,selection in pairs(preset.Selections) do
        if type(selection)~='table' or not known[key] or selection.Source~=known[key] then
            error('An appearance option used by this preset is unavailable.')
        end
        if key=='SelectedChin' and selection.None==true then
            if selection.Identity~=nil then error('Invalid empty Chin selection.') end
        elseif type(selection.Identity)~='table' or not next(selection.Identity)
            or not M.Find(M.Read(context,selection.Source),selection.Identity,key,selection.Choice) then
            error('An appearance option used by this preset is unavailable.')
        end
    end
    local allowed={};for _,name in ipairs(M.Groups) do allowed[name]=true end
    for name,saved in pairs(preset.Groups) do
        if ActiveGroup(context,name) then
        local group=M.Read(context,name)
        if not allowed[name] or not group or type(saved.Options)~='table' then error('An appearance setting used by this preset is unavailable.') end
        if saved.Value~=nil then CheckValue(group,saved.Value) end
        for _,option in ipairs(saved.Options) do
            local target=Option(group,option)
            if not target then error('An appearance slider used by this preset is unavailable.') end
            CheckValue(target,option.Value)
        end
        end
    end
end

local function Execute(context, name, parameter)
    local command=M.Read(context,name)
    if not command then error('The game\'s appearance update command is unavailable.') end
    if parameter~=nil then command:Execute(parameter) else command:Execute() end
end

-- A missing SelectedChin in existing v1 presets means it was not selected
-- when saved. Never treat the first modded option as an implicit None.
local function ChinSelection(preset)
    local selection=preset.Selections.SelectedChin
    if selection==nil and preset.Version==M.Version then
        return {Source='SelectableChin',None=true}
    end
    return selection
end

local function SetEmptyChin(context)
    local options=M.Read(context,'SelectableChin')
    local empty
    for i=1,M.Count(options) do
        local candidate=M.Read(options,i)
        if M.Read(candidate,'IsNull')==true then
            if empty then error('Multiple empty Chin options; cannot safely restore None.') end
            empty=candidate
        end
    end
    if empty then
        -- Prefer a game-owned empty entry if this mod supplies one.
        context.SelectedChin=empty
    else
        local current=M.Read(context,'SelectedChin')
        if current~=nil and M.Read(current,'IsNull')~=true then
            -- No proven game-owned None item to assign. Do not fabricate a
            -- null native pointer or gamble on setting a C++ property to nil.
            error('No engine-owned empty Chin option is exposed; Chin was not changed.')
        end
    end
end

local function ApplyValues(context,preset)
    -- Native tickboxes bind Value one-way: ValueChanged performs the toggle.
    -- Apply palette filters before selecting colours, since a toggle can rebuild them.
    for _,name in ipairs(M.Groups) do
        local saved=preset.Groups[name]
        if saved and ActiveGroup(context,name) then
            for _,setting in ipairs(saved.Options) do
                if type(setting.Value)=='boolean' then
                    local target=Option(M.Read(context,name),setting)
                    if not target then error('An appearance checkbox changed while loading the preset.') end
                    if M.Read(target,'Value')~=setting.Value then
                        Execute(context,'ValueChanged',target)
                    end
                end
            end
        end
    end
    if preset.Heterochromia~=nil then context.HeterochromiaEnabled=preset.Heterochromia end
    for _,pair in ipairs(M.Selections) do
        local selection=pair[1]=='SelectedChin' and ChinSelection(preset) or preset.Selections[pair[1]]
        if selection then
            if pair[1]=='SelectedChin' and selection.None==true then
                SetEmptyChin(context)
            else
                local option=M.Find(M.Read(context,selection.Source),selection.Identity,pair[1],selection.Choice)
                if not option then error('An appearance option changed while loading the preset.') end
                context[pair[1]]=option
            end
        end
    end
    for _,name in ipairs(M.Groups) do
        local saved=preset.Groups[name]
        if saved and ActiveGroup(context,name) then
            local group=M.Read(context,name)
            if M.Read(context,'IsDragonborn')==true and saved.EmptyMaterial~=nil and M.Read(group,'EmptyMaterialSelected')~=saved.EmptyMaterial then
                group.EmptyMaterialSelected=saved.EmptyMaterial
                Execute(context,'DragonbornDraconicLinesToggleCommand')
            end
            if saved.Value~=nil then group.Value=saved.Value end
            for _,setting in ipairs(saved.Options) do
                local target=Option(group,setting)
                if not target then error('An appearance slider changed while loading the preset.') end
                if type(setting.Value)~='boolean' then target.Value=setting.Value end
            end
        end
    end
    if preset.Heterochromia==false then Execute(context,'DisableHeterochromia') end
    Execute(context,'AppearanceValueChanged')
end

function M.Apply(context,preset)
    local before=M.Capture(context)
    M.Validate(context,preset)
    local ok,reason=pcall(ApplyValues,context,preset)
    if not ok then
        local restored,failure=pcall(ApplyValues,context,before)
        error(tostring(reason)..(restored and ' The previous appearance was restored.' or ' Restoration failed: '..tostring(failure)))
    end
end

function M.Matches(context,preset)
    local function Equal(a,b)
        if type(a)=='number' and type(b)=='number' then return math.abs(a-b)<0.0001 end
        return a==b
    end
    for key,selection in pairs(preset.Selections) do
        if key=='SelectedChin' and selection.None==true then
            local current=M.Read(context,'SelectedChin')
            if current~=nil and M.Read(current,'IsNull')~=true then return false,key end
        else
            local selected=M.Read(context,key)
            if not SameIdentity(selected,selection.Identity) then return false,key end
            if selection.Choice~=nil then
                local expected=M.Find(M.Read(context,selection.Source),selection.Identity,key,selection.Choice)
                if not SameObject(selected,expected) then return false,key end
            end
        end
    end
    if preset.Heterochromia~=nil and M.Read(context,'HeterochromiaEnabled')~=preset.Heterochromia then
        return false,'HeterochromiaEnabled'
    end
    for name,saved in pairs(preset.Groups) do
        if ActiveGroup(context,name) then
        local group=M.Read(context,name)
        if saved.Value~=nil and not Equal(M.Read(group,'Value'),saved.Value) then return false,name..'.Value' end
        if M.Read(context,'IsDragonborn')==true and saved.EmptyMaterial~=nil and M.Read(group,'EmptyMaterialSelected')~=saved.EmptyMaterial then return false,name..'.EmptyMaterialSelected' end
        for _,setting in ipairs(saved.Options) do
            if not Equal(M.Read(Option(group,setting),'Value'),setting.Value) then return false,name..'.ColorOptions' end
        end
        end
    end
    return true
end

-- Partial loading retains each setting independently. Race/body remain mandatory.
function M.ValidateAvailable(context,preset)
    if type(preset)~='table' or preset.Version~=M.Version or type(preset.Selections)~='table'
        or type(preset.Groups)~='table' then error('This preset has an unsupported format.') end
    if not M.CanEdit(context) then
        error('Choose a character whose appearance can be edited.')
    end
    local compatible,reason=M.Compatible(context,{Race=preset.Race,SubRace=preset.SubRace,
        Body=preset.Body,BodyOptions=preset.Body==nil and preset.BodyOptions or nil})
    if not compatible then error(reason) end
end

function M.ApplyAvailable(context,preset)
    M.ValidateAvailable(context,preset)
    local result={Checks={},Skipped={}}
    local function Try(label,expected,fn)
        local ok,err=pcall(fn)
        if ok then result.Checks[#result.Checks+1]={Label=label,Expected=expected}
        else result.Skipped[#result.Skipped+1]=label..': '..tostring(err) end
    end
    local function GroupExpected(name,saved)
        return {Selections={},Groups={[name]=saved}}
    end
    -- Filters can rebuild palettes; update them before selecting colours.
    for _,name in ipairs(M.Groups) do
        local saved=preset.Groups[name]
        if type(saved)=='table' and ActiveGroup(context,name) then
            for _,setting in ipairs(type(saved.Options)=='table' and saved.Options or {}) do
                if type(setting)=='table' and type(setting.Value)=='boolean' then
                    Try(name..'.checkbox',GroupExpected(name,{Options={setting}}),function()
                        local target=Option(M.Read(context,name),setting)
                        if not target then error('Unavailable checkbox') end
                        CheckValue(target,setting.Value)
                        if M.Read(target,'Value')~=setting.Value then Execute(context,'ValueChanged',target) end
                    end)
                end
            end
        end
    end
    if type(preset.Heterochromia)=='boolean' then
        Try('HeterochromiaEnabled',{Selections={},Groups={},Heterochromia=preset.Heterochromia},function()
            context.HeterochromiaEnabled=preset.Heterochromia
            if preset.Heterochromia==false then Execute(context,'DisableHeterochromia') end
        end)
    end
    for _,pair in ipairs(M.Selections) do
        local selection=pair[1]=='SelectedChin' and ChinSelection(preset) or preset.Selections[pair[1]]
        if selection~=nil then
            Try(pair[1],{Selections={[pair[1]]=selection},Groups={}},function()
                if type(selection)~='table' or selection.Source~=pair[2] then error('Invalid appearance option') end
                if pair[1]=='SelectedChin' and selection.None==true then
                    if selection.Identity~=nil then error('Invalid empty Chin selection') end
                    SetEmptyChin(context)
                else
                    if type(selection.Identity)~='table' or not next(selection.Identity) then error('Invalid appearance option') end
                    local target=M.Find(M.Read(context,pair[2]),selection.Identity,pair[1],selection.Choice)
                    if not target then error('Unavailable appearance option') end
                    context[pair[1]]=target
                end
            end)
        end
    end
    for _,name in ipairs(M.Groups) do
        local saved=preset.Groups[name]
        if type(saved)=='table' and ActiveGroup(context,name) then
            if saved.EmptyMaterial~=nil and M.Read(context,'IsDragonborn')==true then
                Try(name..'.EmptyMaterialSelected',GroupExpected(name,{Options={},EmptyMaterial=saved.EmptyMaterial}),function()
                    if type(saved.EmptyMaterial)~='boolean' then error('Invalid material toggle') end
                    local group=M.Read(context,name)
                    if not group then error('Unavailable material') end
                    if M.Read(group,'EmptyMaterialSelected')~=saved.EmptyMaterial then
                        group.EmptyMaterialSelected=saved.EmptyMaterial
                        Execute(context,'DragonbornDraconicLinesToggleCommand')
                    end
                end)
            end
            if saved.Value~=nil then
                Try(name..'.Value',GroupExpected(name,{Options={},Value=saved.Value}),function()
                    local group=M.Read(context,name);CheckValue(group,saved.Value);group.Value=saved.Value
                end)
            end
            for i,setting in ipairs(type(saved.Options)=='table' and saved.Options or {}) do
                if type(setting)=='table' and type(setting.Value)~='boolean' then
                    Try(name..'.option'..i,GroupExpected(name,{Options={setting}}),function()
                        local target=Option(M.Read(context,name),setting)
                        if not target then error('Unavailable slider') end
                        CheckValue(target,setting.Value);target.Value=setting.Value
                    end)
                end
            end
        end
    end
    local ok,err=pcall(Execute,context,'AppearanceValueChanged')
    if not ok then result.Skipped[#result.Skipped+1]='Appearance refresh: '..tostring(err) end
    return result
end

function M.VerifyAvailable(context,result)
    local retained=0
    local skipped={}
    for _,reason in ipairs(result.Skipped) do skipped[#skipped+1]=reason end
    for _,check in ipairs(result.Checks) do
        local ok,matched=pcall(M.Matches,context,check.Expected)
        if ok and matched then retained=retained+1
        else skipped[#skipped+1]=check.Label..': not retained by the game' end
    end
    return retained,skipped
end

function M.CleanName(name)
    if type(name)~='string' then error('Enter a preset name.') end
    name=name:gsub('^%s+',''):gsub('%s+$','')
    if name=='' or #name>192 or name:find('[%c]') then error('Enter a preset name of up to 64 characters.') end
    return name
end
function M.BodyLabel(body)
    local numbers={Female=1,Male=2,FemaleStrong=3,MaleStrong=4}
    local number=numbers[body]
    return number and ('Body Type '..number) or 'Body Type Unknown'
end
return M
