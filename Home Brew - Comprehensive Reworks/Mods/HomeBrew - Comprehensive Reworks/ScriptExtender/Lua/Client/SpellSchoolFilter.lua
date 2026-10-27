

local FILTER_TYPE = "HB_CCSpellSchoolDamageFilter_v5"
local TEMPLATE_KEY = "HB_CCSpellSchoolItemsTemplate"
local HOST_NAME = "HB_SpellFilterResources"
local HEADER_NAME = "HB_SchoolFilterRoot"
local NATIVE_HEADER_NAME = "HB_NativeSchoolFilterRoot"
local INTERVAL_MS = 350
local MAX_CLASS_ROWS = 5
local ClassSpellIndex = Ext.Require("Shared/HB_ClassSpellIndex.lua")

local SCHOOLS = {
    "All Schools", "Abjuration", "Conjuration", "Divination", "Enchantment",
    "Evocation", "Illusion", "Necromancy", "Transmutation",
}
local SCHOOL_NAMES = {}
for index = 2, #SCHOOLS do SCHOOL_NAMES[SCHOOLS[index]:lower()] = SCHOOLS[index] end

local DAMAGE_TYPES = {
    "All Damage Types", "Acid", "Bludgeoning", "Cold", "Fire", "Force",
    "Lightning", "Necrotic", "Piercing", "Poison", "Psychic", "Radiant", "Slashing", "Thunder",
}
local DAMAGE_NAMES = {}
for index = 2, #DAMAGE_TYPES do DAMAGE_NAMES[DAMAGE_TYPES[index]:lower()] = DAMAGE_TYPES[index] end


local MANUAL_DAMAGE_TYPES = {
    Projectile_ChromaticOrb = {
        "Acid", "Cold", "Fire", "Force", "Lightning", "Necrotic",
        "Poison", "Psychic", "Radiant", "Thunder",
    },
    Shout_CrusadersMantle = { "Radiant", "Necrotic" },
    Shout_SpiritGuardians = { "Radiant", "Necrotic" },
    Shout_FrostflameArmament = { "Fire", "Cold" },
    Target_HungerOfHadar = { "Cold", "Acid" },
    Target_ElementalWeapon = {
        "Acid", "Cold", "Fire", "Force", "Lightning", "Necrotic",
        "Poison", "Psychic", "Radiant", "Thunder",
    },
    -- Weapon-dependent attacks have no single fixed DamageType in SpellData.
    -- Treat the physical possibilities as damaging rather than Non-Damaging.
    Zone_ConjureBarrage = { "Bludgeoning", "Piercing", "Slashing" },
    Projectile_EnsnaringStrike_Container = { "Bludgeoning", "Piercing", "Slashing" },
    -- This hybrid spell deals Necrotic damage even though it also heals allies.
    Target_WitherAndBloom = { "Necrotic" },
}
local damageCatalog, byName, byIcon, damageLookup = {}, {}, {}, {}
-- Exact HomeBrew SpellLists.lsx pool entries are authoritative when a native
-- presentation tile shares its icon/name with inherited or upcast stat variants.
local concentrationPoolIds = {}
local localizedNameCache = {}

local WIDGET_NAMES = {
    CharacterCreation = true, CharacterCreation_c = true,
    CharacterLevelUp = true, CharacterLevelUp_c = true,
    CharacterRespec = true, CharacterRespec_c = true,
}
local PREPARATION_LIST_NAMES = {
    ClassSpellAvailableItemsControl = true, availableSpells = true,
    HB_SchoolAvailableItemsControl = true,
}

local catalog = {}
local catalogReady = false
local catalogSchoolCount = 0
local catalogDamageCount = 0
local propertyCache = {}
local states = {}
local lastUpdate = 0
local queued = false
local resourceWarning = false
local updateWarning = false
local diagnosticLines = {}
local diagnosticDirty = false
local rootDiagnostic
local consoleJobs = {}
local deferredUI = Ext.UI and Ext.UI.Defer




local function DispatchUI(callback)
    if deferredUI then deferredUI(callback) else callback() end
end

local function Log(message)
    local line = "[HB Spell Filter] " .. message
    Ext.Utils.Print(line)
    diagnosticLines[#diagnosticLines + 1] = line
    if #diagnosticLines > 80 then table.remove(diagnosticLines, 1) end
    diagnosticDirty = true
end



local function Properties(object)
    if not object then return {} end
    local kind = type(object)
    if kind ~= "userdata" and kind ~= "table" then return {} end
    local typeName = object.Type
    if not typeName then return {} end
    local properties = propertyCache[typeName]
    if properties then return properties end
    properties = {}
    local typeInfo = object:TypeInfo()
    while typeInfo do
        for _, property in ipairs(typeInfo.Properties or {}) do properties[property.Name] = true end
        for _, property in ipairs(typeInfo.DependencyProperties or {}) do properties[property.Name] = true end
        typeInfo = typeInfo.Base
    end
    propertyCache[typeName] = properties
    return properties
end

local function Read(object, property)
    if object and Properties(object)[property] then return object[property] end
end

local function NormalizeSchool(value)
    if type(value) == "string" then return SCHOOL_NAMES[value:lower()] end
end



local function NameHandle(value)
    for _ = 1, 3 do
        if type(value) == "string" then return value:match("^[^;]+") end
        if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
        value = value.Handle
    end
end

local function DamageSignature(types)
    local names = {}
    for name in pairs(types) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ";")
end



local function DamageFromTooltip(text, types)
    if type(text) ~= "string" then return false end
    local unknown, start = false, 1
    while true do
        local first, last = text:find("DealDamage%s*%b()", start)
        if not first then break end
        local call = text:sub(first, last):match("%((.*)%)")
        local args, depth, from = {}, 0, 1
        for index = 1, #call do
            local char = call:sub(index, index)
            if char == "(" then depth = depth + 1
            elseif char == ")" then depth = depth - 1
            elseif char == "," and depth == 0 then
                args[#args + 1] = call:sub(from, index - 1)
                from = index + 1
            end
        end
        args[#args + 1] = call:sub(from)
        local damage = (args[2] or ""):match("^%s*(.-)%s*$")
        local name = DAMAGE_NAMES[damage:lower()]
        if name then types[name] = true else unknown = true end
        start = last + 1
    end
    return unknown
end

-- SpellFlags is the installed SpellData flag string.  This is the same
-- IsConcentration flag used by HomeBrew's historical spell tooltips.
local function IsConcentrationSpell(flags)
    -- SpellFlags normally comes from SpellData as a semicolon-delimited flag
    -- string. Also tolerate an exposed flag table/set from a modded stat.
    if type(flags) == "table" then
        if flags.IsConcentration == true then return true end
        for key, value in pairs(flags) do
            if (key == "IsConcentration" and value) or value == "IsConcentration" then return true end
        end
        return false
    end
    local text = tostring(flags or "")
    for flag in text:gmatch("[^;,%s]+") do
        if flag == "IsConcentration" then return true end
    end
    return false
end

local function BuildCatalog()
    local entries, details, names, icons = {}, {}, {}, {}
    local withSchool, withDamage = 0, 0
    local ids = Ext.Stats.GetStats("SpellData")
    local function Index(index, value, entry)
        if type(value) ~= "string" or value == "" then return end
        index[value] = index[value] or {}
        table.insert(index[value], entry)
    end
    for _, id in ipairs(ids) do
        local stats = Ext.Stats.Get(id, nil, false)
        if stats then
            entries[id] = NormalizeSchool(stats.SpellSchool) or false
            if entries[id] then withSchool = withSchool + 1 end
            local types = {}
            local primary = type(stats.DamageType) == "string" and stats.DamageType or ""
            local name = DAMAGE_NAMES[primary:lower()]
            if name then types[name] = true end
            local unknown = primary ~= "" and primary:lower() ~= "none" and not name
            for _, field in ipairs({ "TooltipDamageList", "TooltipOnSave", "TooltipOnMiss" }) do
                if DamageFromTooltip(stats[field], types) then unknown = true end
            end
            local entry = {
                id = id, school = entries[id], level = stats.Level, icon = stats.Icon,
                primaryType = name, types = types, unknown = unknown, known = not unknown and (primary ~= "" or next(types) ~= nil),
                children = stats.ContainerSpells, displayHandle = NameHandle(stats.DisplayName),
                concentration = IsConcentrationSpell(stats.SpellFlags),
            }
            details[id] = entry
            Index(names, NameHandle(stats.DisplayName), entry)
            Index(icons, stats.Icon, entry)
        end
    end
    
    
    local function Resolve(entry, active)
        if entry.done then return end
        if active[entry.id] then return false end
        active[entry.id] = true
        if type(entry.children) == "string" and entry.children ~= "" then
            local known = true
            for id in entry.children:gmatch("[^;]+") do
                id = id:match("^%s*(.-)%s*$")
                local child = details[id]
                if child and Resolve(child, active) ~= false then
                    for name in pairs(child.types) do entry.types[name] = true end
                    if not child.known then known = false end
                else known = false end
            end
            entry.known = not entry.unknown and known
        end
        active[entry.id] = nil
        entry.signature = DamageSignature(entry.types)
        entry.done = true
        return true
    end
    for _, entry in pairs(details) do Resolve(entry, {}) end
    
    
    
    for _, entry in pairs(details) do
        if entry.primaryType and not entry.known then
            entry.types = { [entry.primaryType] = true }
            entry.known = true
            entry.signature = DamageSignature(entry.types)
        end
        local manual = MANUAL_DAMAGE_TYPES[entry.id]
        if manual then
            
            
            if not entry.known then
                entry.types = entry.primaryType and { [entry.primaryType] = true } or {}
            end
            for _, name in ipairs(manual) do entry.types[name] = true end
            entry.manualTypes = manual
            entry.known = true
            entry.signature = DamageSignature(entry.types)
        end
        if next(entry.types) then withDamage = withDamage + 1 end
    end
    local poolIds = {}
    for _, pool in ipairs(ClassSpellIndex.GetOptions()) do
        for id in pairs(pool.Spells) do
            if details[id] then poolIds[id] = true end
        end
    end
    concentrationPoolIds = poolIds
    catalog, damageCatalog, byName, byIcon, damageLookup = entries, details, names, icons, {}
    localizedNameCache = {}
    catalogSchoolCount, catalogDamageCount, catalogReady = withSchool, withDamage, true
    Log("Spell catalog ready: " .. #ids .. " loaded spell stats; " .. withSchool
        .. " have recognized schools; " .. withDamage .. " have explicit damage types.")
end

local ID_FIELDS = { "PrototypeID", "PrototypeId", "SpellId", "SpellID", "StatsId", "StatsID", "Id", "ID" }
local function SchoolForReference(reference)
    local spell = Read(reference, "Spell")
    
    
    
    local nativeSchool = Read(spell, "SpellSchool")
    local school = NormalizeSchool(nativeSchool)
    if school then return school, true, "native" end
    if type(nativeSchool) == "string" and nativeSchool:lower() == "none" then
        return false, true, "native"
    end
    nativeSchool = Read(reference, "SpellSchool")
    school = NormalizeSchool(nativeSchool)
    if school then return school, true, "native" end
    if type(spell) == "string" and catalog[spell] ~= nil then return catalog[spell], true end
    for _, object in ipairs({ spell, reference }) do
        if object and type(object) ~= "string" then
            for _, field in ipairs(ID_FIELDS) do
                local id = Read(object, field)
                if type(id) == "string" and catalog[id] ~= nil then return catalog[id], true end
            end
            
            
            for field in pairs(Properties(object)) do
                local lower = field:lower()
                if lower:find("spell", 1, true) or lower:find("prototype", 1, true)
                    or lower:find("stat", 1, true) or lower:match("id$") then
                    local value = object[field]
                    if type(value) == "string" and catalog[value] ~= nil then return catalog[value], true end
                end
            end
        end
    end
    return nil, false
end

local function DamageForReference(reference)
    local spell = Read(reference, "Spell")
    if type(spell) == "string" then
        local entry = damageCatalog[spell]
        if entry then return entry.types, entry.known end
    end
    for _, object in pairs({ spell, reference }) do
        if object and type(object) ~= "string" then
            for _, field in ipairs(ID_FIELDS) do
                local id = Read(object, field)
                local entry = type(id) == "string" and damageCatalog[id]
                if entry then return entry.types, entry.known end
            end
            for field in pairs(Properties(object)) do
                local lower = field:lower()
                if lower:find("spell", 1, true) or lower:find("prototype", 1, true)
                    or lower:find("stat", 1, true) or lower:match("id$") then
                    local value = object[field]
                    local entry = type(value) == "string" and damageCatalog[value]
                    if entry then return entry.types, entry.known end
                end
            end
        end
    end
    local name, icon = Read(spell, "Name"), Read(spell, "Icon")
    local school, level = NormalizeSchool(Read(spell, "SpellSchool")), Read(spell, "Level")
    if type(name) ~= "string" then name = nil else name = NameHandle(name) end
    if type(icon) ~= "string" then icon = nil end
    if type(level) ~= "number" then level = nil end
    local key = table.concat({ name or "", icon or "", school or "", tostring(level or "") }, "\31")
    local cached = damageLookup[key]
    if cached ~= nil then return cached and cached.types or nil, cached and cached.known or false end
    local candidates = (name and byName[name]) or (icon and byIcon[icon])
    local matches, iconMatches = {}, {}
    for _, entry in ipairs(candidates or {}) do
        if (not school or entry.school == school) and (not level or tonumber(entry.level) == level) then
            matches[#matches + 1] = entry
            if icon and entry.icon == icon then iconMatches[#iconMatches + 1] = entry end
        end
    end
    if #iconMatches > 0 then matches = iconMatches end
    local result = matches[1]
    
    
    local primary = result and result.primaryType
    local samePrimary = primary ~= nil
    for _, entry in ipairs(matches) do
        if entry.primaryType ~= primary then samePrimary = false end
    end
    for _, entry in ipairs(matches) do
        if not entry.known or entry.signature ~= result.signature then result = nil; break end
    end
    if not result then
        
        
        
        local forced = {}
        for _, entry in ipairs(matches) do
            for _, name in ipairs(entry.manualTypes or {}) do forced[name] = true end
        end
        if next(forced) then
            if samePrimary then forced[primary] = true end
            result = { types = forced, known = true }
        elseif samePrimary then
            result = { types = { [primary] = true }, known = true }
        end
    end
    damageLookup[key] = result or false
    return result and result.types or nil, result and result.known or false
end



-- Search the name the player actually sees, rather than an internal spell stat ID.
-- Localized names are cached so typing never repeatedly translates the entire list.
local function SearchableName(value)
    local handle = NameHandle(value)
    if type(handle) ~= "string" or handle == "" then return nil end
    local cached = localizedNameCache[handle]
    if cached ~= nil then return cached or nil end
    local name
    if Ext.Loca and Ext.Loca.GetTranslatedString then
        local ok, translated = pcall(Ext.Loca.GetTranslatedString, handle, handle)
        if ok and type(translated) == "string" and translated ~= "" and translated ~= handle
            and not translated:find("s_HandleUnknown", 1, true) then
            name = translated
        end
    end
    -- A native VM can already expose plain text rather than a localization handle.
    if not name and not handle:match("^[hH][%da-fgA-FG]+$")
        and not handle:match("^[%a]+_[%w_]+$")
        and not handle:find("TranslatedString", 1, true) then
        name = handle
    end
    localizedNameCache[handle] = name and name:lower() or false
    return localizedNameCache[handle] or nil
end

local function NameForReference(reference)
    local spell = Read(reference, "Spell")
    -- Spell.Name is the same value that the native Spell UI renders.
    for _, object in ipairs({ spell or false, reference or false }) do
        if object and type(object) ~= "string" then
            for _, field in ipairs({ "Name", "DisplayName" }) do
                local name = SearchableName(Read(object, field))
                if name then return name end
            end
        end
    end
    if type(spell) == "string" then
        local entry = damageCatalog[spell]
        if entry then return SearchableName(entry.displayHandle) end
    end
    -- Prefer exact spell identity if the native row exposes one.
    for _, object in ipairs({ spell, reference }) do
        if object and type(object) ~= "string" then
            for _, field in ipairs(ID_FIELDS) do
                local id = Read(object, field)
                local entry = type(id) == "string" and damageCatalog[id]
                if entry then
                    local name = SearchableName(entry.displayHandle)
                    if name then return name end
                end
            end
        end
    end
    -- Icon fallback only if every candidate has the same translated name.
    local icon = Read(spell, "Icon")
    local candidates = type(icon) == "string" and byIcon[icon]
    if candidates then
        local resolved
        for _, entry in ipairs(candidates) do
            local name = SearchableName(entry.displayHandle)
            if not name or (resolved and resolved ~= name) then return nil end
            resolved = name
        end
        return resolved
    end
end

-- Match a native spell tile to its installed class-list stat identity.
-- The vanilla UI often exposes a presentation-only spell VM (Name, Icon,
-- SpellSchool and Level), rather than a usable stats ID. Multiple installed
-- stats (variants, inherited forms, upcasts) may share those fields. Requiring
-- *all* of them to be in the class list was hiding only a tiny fraction of the
-- ordinary spells. Exact usable stat IDs still take absolute precedence.
-- Compare a visible native spell with the union of disabled class lists.
-- The native chooser often exposes a presentation VM rather than the exact
-- class-list stat ID. Stat IDs are strongest proof of membership, but a
-- nonmember variant cannot immediately veto a matching original spell.
local function ClassMember(reference,spells)
    if not spells or next(spells)==nil then return false end
    local spell=Read(reference,"Spell")
    local ids={}
    if type(spell)=="string" then ids[#ids+1]=spell end
    for _,object in ipairs({spell or false,reference or false}) do
        if object and type(object)~="string" then
            for _,field in ipairs(ID_FIELDS) do
                local id=Read(object,field)
                if type(id)=="string" and catalog[id]~=nil then ids[#ids+1]=id end
            end
        end
    end
    for _,id in ipairs(ids) do if spells[id]==true then return true end end
    local rawName=Read(spell,"Name") or Read(reference,"Name")
    local name=NameHandle(rawName)
    local visibleName=SearchableName(rawName)
    local icon=Read(spell,"Icon") or Read(reference,"Icon")
    local level=tonumber(Read(spell,"Level"))
    local school=NormalizeSchool(Read(spell,"SpellSchool"))
    if type(icon)~="string" or icon=="" then icon=nil end
    local candidates=name and byName[name] or nil
    -- Localized name strings and different native display handles are common
    -- in Noesis. An icon fallback still requires compatible school and rank.
    if not candidates and icon then candidates=byIcon[icon] end
    if not candidates then return false end
    local member,distinctNames=0,{}
    for _,candidate in ipairs(candidates) do
        local candidateName=SearchableName(candidate.displayHandle)
        local sameName=not visibleName or (candidateName and candidateName==visibleName)
        -- Exact native localization handles are also valid when translated
        -- text is unavailable or translated differently by an installed mod.
        if name and candidate.displayHandle==name then sameName=true end
        if sameName and (not icon or candidate.icon==icon)
            and (not level or tonumber(candidate.level)==level)
            and (not school or candidate.school==school) then
            distinctNames[candidateName or candidate.displayHandle or candidate.id]=true
            if spells[candidate.id]==true then member=member+1 end
        end
    end
    if member==0 then return false end
    if visibleName or (name and byName[name]) then return true end
    -- Without a native name we require an unambiguous icon/rank/school.
    local variants=0
    for _ in pairs(distinctNames) do variants=variants+1 end
    return variants==1
end


-- Resolve the installed IsConcentration flag for the native spell tile.  Exact
-- installed stat IDs are authoritative.  A presentation-only native VM may
-- expose just Name/Icon/SpellSchool/Level, so match those to installed stats.
-- Ambiguous shared icons or variants with conflicting flags remain unknown;
-- never label such a spell non-concentration by merely lacking a native flag.
local function ConcentrationForReference(reference)
    local spell = Read(reference, "Spell")
    -- Prefer the exact installed stat ID when BG3 exposes one. Mirrors the
    -- field resolution already used by the working School/Damage filters.
    if type(spell) == "string" then
        local exact = damageCatalog[spell]
        if exact then return exact.concentration, "exact" end
    end
    for _, object in ipairs({spell or false, reference or false}) do
        if object and type(object) ~= "string" then
            for _, field in ipairs(ID_FIELDS) do
                local id = Read(object, field)
                if type(id) == "string" and damageCatalog[id] then
                    return damageCatalog[id].concentration, "exact"
                end
            end
            for field in pairs(Properties(object)) do
                local lower = field:lower()
                if lower:find("spell", 1, true) or lower:find("prototype", 1, true)
                    or lower:find("stat", 1, true) or lower:match("id$") then
                    local id = object[field]
                    if type(id) == "string" and damageCatalog[id] then
                        return damageCatalog[id].concentration, "exact"
                    end
                end
            end
        end
    end

    -- Native spell tiles often provide presentation metadata instead of an ID.
    -- The five class pools have already been tested against these tiles, so
    -- resolve those canonical entries before inherited/upcast stat variants.
    local rawName = Read(spell, "Name") or Read(reference, "Name")
    local handle = NameHandle(rawName)
    local visibleName = SearchableName(rawName)
    local icon = Read(spell, "Icon") or Read(reference, "Icon")
    local school = NormalizeSchool(Read(spell, "SpellSchool") or Read(reference, "SpellSchool"))
    local level = tonumber(Read(spell, "Level") or Read(reference, "Level"))
    if type(icon) ~= "string" or icon == "" then icon = nil end
    local candidates = (handle and byName[handle]) or (icon and byIcon[icon])
    if not candidates then return nil, "unresolved" end

    local matched, canonical, distinctNames = {}, {}, {}
    for _, entry in ipairs(candidates) do
        local candidateName = SearchableName(entry.displayHandle)
        local sameName = not visibleName or (candidateName and candidateName == visibleName)
        if handle and entry.displayHandle == handle then sameName = true end
        if sameName and (not icon or entry.icon == icon)
            and (not school or entry.school == school)
            and (not level or tonumber(entry.level) == level) then
            matched[#matched + 1] = entry
            distinctNames[candidateName or entry.displayHandle or entry.id] = true
            if concentrationPoolIds[entry.id] then canonical[#canonical + 1] = entry end
        end
    end
    if #matched == 0 then return nil, "unresolved" end
    if not visibleName and not (handle and byName[handle]) then
        local count = 0
        for _ in pairs(distinctNames) do count = count + 1 end
        if count ~= 1 then return nil, "ambiguous-name" end
    end

    local function Consensus(entries)
        local value
        for _, entry in ipairs(entries) do
            if value ~= nil and value ~= entry.concentration then return nil end
            value = entry.concentration
        end
        return value
    end
    if #canonical > 0 then
        local result = Consensus(canonical)
        if result ~= nil then return result, "class-pool" end
        return nil, "conflicting-class-pool"
    end
    local result = Consensus(matched)
    if result ~= nil then return result, "stat-variants" end
    return nil, "conflicting-variants"
end

-- An omitted map entry is checked.  Per-category overrides are only false,
-- so a new character/picker starts with all schools and damage types visible.
local function CategoryEnabled(map, name)
    return not (map and map[name] == false)
end

local function CategoryCountDisabled(map, values)
    local disabled = 0
    for index = 2, #values do
        if not CategoryEnabled(map, values[index]) then disabled = disabled + 1 end
    end
    return disabled
end

local function AnyDamageSelected(state)
    for index = 2, #DAMAGE_TYPES do
        if CategoryEnabled(state.damageEnabled, DAMAGE_TYPES[index]) then return true end
    end
    return CategoryEnabled(state.damageEnabled, "Non-Damaging")
end

local function NewFilterVM(key)
    local vm = Ext.UI.Instantiate(FILTER_TYPE)
    vm.HB_Previous:SetHandler(function() end)
    vm.HB_Next:SetHandler(function() end)
    -- A bulk action must update the currently mounted Noesis checkboxes right
    -- away.  Deferring their IsChecked bindings until the next spell scan can
    -- leave stale visual checkmarks after an individual checkbox click.
    local function PublishCheckboxes(state)
        if not state then return end
        local live = state.headerVMs
        if not live or #live == 0 then live = { vm } end
        local options = state.classOptions or ClassSpellIndex.GetOptions()
        for _, target in ipairs(live) do
            local ok = pcall(function()
                local function Assign(field, value)
                    if target[field] ~= value then target[field] = value end
                end
                for index = 2, #SCHOOLS do
                    Assign("HB_SchoolEnabled_" .. index,
                        CategoryEnabled(state.schoolEnabled, SCHOOLS[index]))
                end
                for index = 2, #DAMAGE_TYPES do
                    Assign("HB_DamageEnabled_" .. index,
                        CategoryEnabled(state.damageEnabled, DAMAGE_TYPES[index]))
                end
                Assign("HB_DamageNonDamagingEnabled",
                    CategoryEnabled(state.damageEnabled, "Non-Damaging"))
                for row = 1, MAX_CLASS_ROWS do
                    local option = options[row]
                    Assign("HB_ClassEnabled_" .. row,
                        not option or not (state.disabledClasses or {})[option.Guid])
                end
                Assign("HB_ConcentrationEnabled", state.concentrationOnly == true)
                Assign("HB_NotConcentrationEnabled", state.nonConcentrationOnly == true)
            end)
            -- Mounted UI can be replaced during level navigation; the regular
            -- refresh will attach the new VM without inventing a checkbox state.
        end
    end
    vm.HB_Reset:SetHandler(function()
        vm.HB_SearchText = ""
        local state = states[key]
        if state then
            state.index, state.damageIndex, state.searchText = 1, 1, ""
            state.schoolEnabled, state.damageEnabled = {}, {}
            state.disabledClasses = {}
            state.concentrationOnly, state.nonConcentrationOnly = false, false
            state.filterOpen = false
            state.menuOpen, state.damageMenuOpen = false, false
            state.classMenuOpen, state.concentrationMenuOpen = false, false
            state.damageUnavailable = false
            state.hasFiltered = true
        end
        lastUpdate = 0
    end)
    vm.HB_ToggleFilter:SetHandler(function()
        local state = states[key]
        if state then state.filterOpen = not state.filterOpen end
        lastUpdate = 0
    end)
    vm.HB_Toggle:SetHandler(function()
        local state = states[key]
        if state then state.menuOpen = not state.menuOpen end
        lastUpdate = 0
    end)
    for index = 2, #SCHOOLS do
        local schoolName = SCHOOLS[index]
        vm["HB_School_" .. index]:SetHandler(function()
            local state = states[key]
            if state then
                state.schoolEnabled = state.schoolEnabled or {}
                state.schoolEnabled[schoolName] = not CategoryEnabled(state.schoolEnabled, schoolName)
                state.hasFiltered = true
                PublishCheckboxes(state)
            end
            lastUpdate = 0
        end)
    end
    -- Bulk checkbox commands affect only the expanded category.  Using the
    -- existing category maps preserves the same native tile filtering as
    -- clicking the individual checkboxes, without new polling or spell writes.
    local function SetAllCategories(field, names, checked, includeNonDamaging)
        local state = states[key]
        if state then
            local overrides = {}
            if not checked then
                for index = 2, #names do overrides[names[index]] = false end
                if includeNonDamaging then overrides["Non-Damaging"] = false end
            end
            state[field] = overrides
            state.hasFiltered = true
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end
    vm.HB_School_CheckAll:SetHandler(function()
        SetAllCategories("schoolEnabled", SCHOOLS, true, false)
    end)
    vm.HB_School_UncheckAll:SetHandler(function()
        SetAllCategories("schoolEnabled", SCHOOLS, false, false)
    end)
    vm.HB_Damage_CheckAll:SetHandler(function()
        SetAllCategories("damageEnabled", DAMAGE_TYPES, true, true)
    end)
    vm.HB_Damage_UncheckAll:SetHandler(function()
        SetAllCategories("damageEnabled", DAMAGE_TYPES, false, true)
    end)
    vm.HB_ToggleDamage:SetHandler(function()
        local state = states[key]
        if state then state.damageMenuOpen = not state.damageMenuOpen end
        lastUpdate = 0
    end)
    for index = 2, #DAMAGE_TYPES do
        local damageName = DAMAGE_TYPES[index]
        vm["HB_Damage_" .. index]:SetHandler(function()
            local state = states[key]
            if state then
                state.damageEnabled = state.damageEnabled or {}
                state.damageEnabled[damageName] = not CategoryEnabled(state.damageEnabled, damageName)
                state.hasFiltered = true
                PublishCheckboxes(state)
            end
            lastUpdate = 0
        end)
    end
    vm.HB_Damage_NonDamaging:SetHandler(function()
        local state = states[key]
        if state then
            state.damageEnabled = state.damageEnabled or {}
            state.damageEnabled["Non-Damaging"] = not CategoryEnabled(state.damageEnabled, "Non-Damaging")
            state.hasFiltered = true
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end)
    vm.HB_SearchChanged:SetHandler(function()
        -- Keep the source when multiple visible native spell selectors have headers.
        local state = states[key]
        if state then state.searchSource = vm end
        lastUpdate = 0
    end)
    vm.HB_ClearSearch:SetHandler(function()
        local state = states[key]
        if state then state.searchText = ""; state.searchSource = vm end
        vm.HB_SearchText = ""
        lastUpdate = 0
    end)
    vm.HB_ToggleClasses:SetHandler(function()
        local state=states[key]
        if state then
            state.classMenuOpen=not state.classMenuOpen
            lastUpdate=0
        end
    end)
    local function SetAllClassLists(checked)
        local state = states[key]
        if state then
            local disabled = {}
            if not checked then
                for _, option in ipairs(state.classOptions or ClassSpellIndex.GetOptions()) do
                    disabled[option.Guid] = true
                end
            end
            state.disabledClasses = disabled
            state.hasFiltered = true
            state.classCoverageDiagnostic = nil
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end
    vm.HB_Class_CheckAll:SetHandler(function() SetAllClassLists(true) end)
    vm.HB_Class_UncheckAll:SetHandler(function() SetAllClassLists(false) end)
    for row=1,MAX_CLASS_ROWS do
        local selectedRow=row
        vm["HB_Class_"..row]:SetHandler(function()
            local state=states[key]
            local option=state and state.classOptions and state.classOptions[selectedRow]
            if state and option then
                state.disabledClasses=state.disabledClasses or {}
                if state.disabledClasses[option.Guid] then
                    state.disabledClasses[option.Guid]=nil
                else
                    state.disabledClasses[option.Guid]=true
                end
                state.hasFiltered=true
                state.classCoverageDiagnostic=nil
                PublishCheckboxes(state)
                lastUpdate=0
            end
        end)
        vm["HB_ClassName_"..row]=""
        vm["HB_ClassEnabled_"..row]=true
        vm["HB_ClassVisible_"..row]=false
    end
    vm.HB_ToggleConcentrationMenu:SetHandler(function()
        local state = states[key]
        if state then state.concentrationMenuOpen = not state.concentrationMenuOpen end
        lastUpdate = 0
    end)
    local function SetAllConcentration(checked)
        local state = states[key]
        if state then
            state.concentrationOnly = checked
            state.nonConcentrationOnly = checked
            state.hasFiltered = true
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end
    vm.HB_Concentration_CheckAll:SetHandler(function() SetAllConcentration(true) end)
    vm.HB_Concentration_UncheckAll:SetHandler(function() SetAllConcentration(false) end)
    vm.HB_ToggleConcentration:SetHandler(function()
        local state = states[key]
        if state then
            state.concentrationOnly = not state.concentrationOnly
            state.hasFiltered = true
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end)
    vm.HB_ToggleNotConcentration:SetHandler(function()
        local state = states[key]
        if state then
            state.nonConcentrationOnly = not state.nonConcentrationOnly
            state.hasFiltered = true
            PublishCheckboxes(state)
        end
        lastUpdate = 0
    end)
    vm.HB_ConcentrationEnabled = false
    vm.HB_NotConcentrationEnabled = false
    vm.HB_ClassesHeader="Class"
    vm.HB_ClassesMenuOpen=false
    vm.HB_ConcentrationMenuOpen=false
    vm.HB_FilterOpen=false
    vm.HB_SearchText = ""
    vm.HB_DamageHeader = "Damage Type"
    vm.HB_DamageMenuOpen = false
    vm.HB_Visible = true
    vm.HB_Ready = true
    vm.HB_MenuOpen = false
    vm.HB_Header = "Spell School"
    vm.HB_Label = SCHOOLS[1]
    vm.HB_Status = ""
    return vm
end

local function Walk(node, callback, depth, path)
    if not node or depth > 80 then return end
    path = path or {}
    if callback(node, path) == false then return end
    local count = node.VisualChildrenCount
    for index = 1, count do
        path[#path + 1] = index
        Walk(node:VisualChild(index), callback, depth + 1, path)
        path[#path] = nil
    end
end

local function FindNamed(node, name)
    local found
    Walk(node, function(child)
        if found then return false end
        if Read(child, "Name") == name then found = child; return false end
    end, 0)
    return found
end

local function IsItemsControl(object)
    return object.Type:match("ItemsControl$") ~= nil or Properties(object).ItemsSource == true
end



local function IsAvailableList(control, rootDC)
    if Read(control, "IsVisible") == false then return false end
    local visibility = Read(control, "Visibility")
    if visibility == "Collapsed" or visibility == "Hidden" then return false end
    local named = PREPARATION_LIST_NAMES[Read(control, "Name")] == true
    if not named and not IsItemsControl(control) then return false end
    local dc = Read(control, "DataContext")
    if Read(dc, "IsActions") == true then return false end

    
    
    
    if named then return true end
    local source = Read(control, "ItemsSource")
    if not source or not dc then return false end

    local available = Read(dc, "Available")
    
    if available and PREPARATION_LIST_NAMES[Read(control, "Name")] then return true end
    if available and source == available then return true end

    local progression = Read(rootDC, "ClassProgressionDetails")
    if progression then
        local incoming = Read(progression, "InSpellsAvailable")
        local outgoing = Read(progression, "OutSpellsAvailable")
        if (incoming and source == incoming) or (outgoing and source == outgoing) then return true end
    end

    
    return PREPARATION_LIST_NAMES[Read(control, "Name")] == true
        and Read(dc, "Spells") ~= nil
end

local function CollectContainers(control, resolveDamage)
    local containers = {}
    Walk(control, function(child)
        if child ~= control and IsItemsControl(child) then return false end
        if child ~= control then
            local reference = Read(child, "DataContext")
            if reference and Read(reference, "Spell") ~= nil then
                local school, resolved, source = SchoolForReference(reference)
                local damage, damageResolved
                if resolveDamage then damage, damageResolved = DamageForReference(reference) end
                containers[#containers + 1] = {
                    element = child, reference = reference, school = school, resolved = resolved, source = source,
                    damage = damage, damageResolved = damageResolved,
                }
                return false
            end
        end
    end, 0)
    return containers
end




local function RecordPath(widget, path, node)
    local record = { indices = {}, counts = {}, name = Read(node, "Name"), kind = node.Type, instance = tostring(node) }
    local current = widget
    for index, childIndex in ipairs(path) do
        record.indices[index] = childIndex
        record.counts[index] = current.VisualChildrenCount
        current = current:VisualChild(childIndex)
    end
    return record
end

local function ResolvePath(widget, record)
    local current = widget
    for index, childIndex in ipairs(record.indices) do
        if not current or current.VisualChildrenCount ~= record.counts[index] then return end
        current = current:VisualChild(childIndex)
    end
    if current and current.Type == record.kind and Read(current, "Name") == record.name
        and tostring(current) == record.instance then return current end
end

local function CachedTargets(widget, targets, dc)
    if not targets then return end
    local lists, headers = {}, {}
    for _, record in ipairs(targets.lists) do
        local node = ResolvePath(widget, record)
        if not node or not IsAvailableList(node, dc) then return end
        lists[#lists + 1] = node
    end
    for _, record in ipairs(targets.headers) do
        local node = ResolvePath(widget, record)
        if not node or Read(node, "IsVisible") == false or Read(node, "Visibility") == "Collapsed"
            or Read(node, "Visibility") == "Hidden" then return end
        headers[#headers + 1] = node
    end
    return lists, headers
end




local function SelectorToken(widget, lists)
    local parts = { tostring((Read(widget, "DataContext"))) }
    for _, list in ipairs(lists) do
        local dc = Read(list, "DataContext")
        parts[#parts + 1] = tostring(list)
        parts[#parts + 1] = tostring(dc)
        parts[#parts + 1] = tostring((Read(dc, "IsCantrips")))
        parts[#parts + 1] = tostring((Read(dc, "IsActions")))
        local title = Read(dc, "Title")
        if type(title) == "string" then parts[#parts + 1] = title end
    end
    return table.concat(parts, "\31")
end

local function UpdateWidget(widget, template, seen, detectedName)
    local name = detectedName or Read(widget, "Name")
    local key = name .. ":" .. tostring(widget.PlayerId)
    seen[key] = true
    local state = states[key]
    if not state then state = { index = 1, damageIndex = 1, searchText = "", menuOpen = false, damageMenuOpen = false, classMenuOpen = false, disabledClasses = {}, concentrationOnly = false, nonConcentrationOnly = false, schoolEnabled = {}, damageEnabled = {}, filterOpen = false, concentrationMenuOpen = false }; states[key] = state end
    local dc = Read(widget, "DataContext")
    -- Historical Level Respec has its own independent School/Damage filters.
    -- This vanilla-only filter runs once a second and explicitly Collapses
    -- entries whose NotAvailable is true. Those are precisely the greyed-out
    -- historical spells that must STAY visible (and Selected is a separate
    -- clickable copy). Do not touch this native screen while HB owns its VM.
    -- This also prevents the asynchronous filter from overwriting historical
    -- ItemsControl templates or keeping stale cached visual paths.
    if Read(dc, "HB_NativeHistoricalOnlyPassives") == true then
        if not state.historicalSkipped then
            Log(name .. " player=" .. tostring(widget.PlayerId)
                .. "; historical Level Respec owns spell lists; vanilla filter suspended")
        end
        states[key] = { historicalSkipped=true }
        return
    elseif state.historicalSkipped then
        state = {index=1, damageIndex=1, searchText="", menuOpen=false, damageMenuOpen=false, classMenuOpen=false, disabledClasses={},concentrationOnly=false,nonConcentrationOnly=false,schoolEnabled={},damageEnabled={},filterOpen=false,concentrationMenuOpen=false}
        states[key]=state
    end
    local lists, headers = CachedTargets(widget, state.targets, dc)
    if not lists then
        lists, headers = {}, {}
        local targets = { lists = {}, headers = {} }
        Walk(widget, function(child, path)
            
            
            if Read(child, "IsVisible") == false then return false end
            local visibility = Read(child, "Visibility")
            if visibility == "Collapsed" or visibility == "Hidden" then return false end
            local childName = Read(child, "Name")
            if childName == "ClassSpellSelectedItemsControl" or childName == "selectedSpells" then return false end
            if childName == NATIVE_HEADER_NAME then
                if Read(Read(child, "DataContext"), "IsActions") ~= true then
                    headers[#headers + 1] = child
                    targets.headers[#targets.headers + 1] = RecordPath(widget, path, child)
                end
                return false
            end
            if IsAvailableList(child, dc) then
                lists[#lists + 1] = child
                targets.lists[#targets.lists + 1] = RecordPath(widget, path, child)
                return false
            end
        end, 0)
        state.targets = #lists > 0 and targets or nil
    end
    if #lists == 0 then
        
        
        if state.selectorToken then state.navigationPending = true end
        return
    end
    local selectorToken = SelectorToken(widget, lists)
    if state.navigationPending or (state.selectorToken and state.selectorToken ~= selectorToken) then
        state.selectorToken = selectorToken
        state.navigationPending = false
        state.index, state.damageIndex, state.searchText = 1, 1, ""
        state.schoolEnabled, state.damageEnabled = {}, {}
        state.disabledClasses, state.classOptions = {}, nil
        state.concentrationOnly, state.nonConcentrationOnly = false, false
        state.menuOpen, state.damageMenuOpen, state.classMenuOpen = false, false, false
        state.concentrationMenuOpen, state.filterOpen = false, false
        state.metadataUnavailable, state.damageUnavailable = false, false
        state.resetSearchPending = true
        state.searchSource = nil
        
        state.hasFiltered = state.hasFiltered or state.appliedIndex ~= nil
        state.targets, state.counts, state.diagnostic = nil, nil, nil
        state.headerVMs = nil
        
        
        Log(name .. " player=" .. tostring(widget.PlayerId) .. "; spell picker changed; filters reset; waiting for stable picker.")
        lastUpdate=Ext.Timer.MonotonicTime()-(INTERVAL_MS-125)
        return
    end
    state.selectorToken = selectorToken
    local nativeHeaders = #headers > 0
    local function HeaderVM(header)
        local vm = Read(header, "DataContext")
        if not vm or vm.Type ~= "se::" .. FILTER_TYPE then
            vm = NewFilterVM(key)
            header.DataContext = vm
        end
        return vm
    end
    local headerVMs = {}
    for _, header in ipairs(headers) do headerVMs[#headerVMs + 1] = HeaderVM(header) end
    if not nativeHeaders and template then
        -- The fallback filter embeds its header in the available-list template.
        -- Discover it before reading the query, including the first visible frame.
        for _, list in ipairs(lists) do
            if list.Template ~= template then list.Template = template end
            local header = FindNamed(list, HEADER_NAME)
            if header then headerVMs[#headerVMs + 1] = HeaderVM(header) end
        end
    end
    state.headerVMs = headerVMs
    if state.resetSearchPending and #headerVMs > 0 then
        for _, vm in ipairs(headerVMs) do vm.HB_SearchText = "" end
        state.resetSearchPending = false
    end
    -- Keep the original typed capitalization and spaces in the text box.
    -- Only the case-folded, trimmed copy is used to match displayed names.
    local raw = state.searchText or ""
    local sourceFound = false
    for _, vm in ipairs(headerVMs) do
        if vm == state.searchSource then
            raw = Read(vm, "HB_SearchText") or ""
            sourceFound = true
            break
        end
    end
    if not sourceFound then
        -- Poll fallback for builds where Noesis doesn't fire TextChanged.
        for _, vm in ipairs(headerVMs) do
            local value = Read(vm, "HB_SearchText")
            if type(value) == "string" and value ~= raw then
                raw = value
                break
            end
        end
    end
    if type(raw) ~= "string" then raw = "" end
    state.searchText = raw
    local query = raw:match("^%s*(.-)%s*$"):lower()
    -- The list is independent of the class currently being levelled. This is
    -- deliberate: a Cleric can disable Wizard, Druid, or any other class.
    local classOptions=ClassSpellIndex.GetOptions()
    state.classOptions=classOptions
    local disabled=state.disabledClasses or {}
    local disabledSet={}
    local disabledCount=0
    for _,classEntry in ipairs(classOptions) do
        if disabled[classEntry.Guid] then
            disabledCount=disabledCount+1
            for id in pairs(classEntry.Spells) do disabledSet[id]=true end
        end
    end
    local classFiltering=disabledCount>0
    -- Both boxes checked means both categories are included (no concentration
    -- restriction).  Only one checked requests an exclusive category.
    local concentrationFiltering = (state.concentrationOnly == true) ~= (state.nonConcentrationOnly == true)
    local requestedConcentration = state.concentrationOnly == true
    local groups = {}
    local availableCount, knownCount, renderedCount, nativeCount, damageKnownCount = 0, 0, 0, 0, 0
    
    
    
    local schoolDisabled = CategoryCountDisabled(state.schoolEnabled, SCHOOLS)
    local damageDisabled = CategoryCountDisabled(state.damageEnabled, DAMAGE_TYPES)
    local nonDamageDisabled = not CategoryEnabled(state.damageEnabled, "Non-Damaging")
    local schoolFiltering = schoolDisabled > 0
    local damageFiltering = damageDisabled > 0 or nonDamageDisabled
    local damageAnySelected = AnyDamageSelected(state)
    local schoolAnySelected = schoolDisabled < (#SCHOOLS - 1)
    local scanItems = schoolFiltering or damageFiltering or query ~= ""
        or classFiltering or concentrationFiltering or state.hasFiltered
        or state.metadataUnavailable or state.damageUnavailable
    local checkDamage = damageFiltering or state.damageUnavailable
    for _, list in ipairs(lists) do
        
        
        
        
        if not nativeHeaders and template and list.Template ~= template then list.Template = template end
        local containers = scanItems and CollectContainers(list, checkDamage) or {}
        if query ~= "" then
            for _, item in ipairs(containers) do item.searchName = NameForReference(item.reference) end
        end
        renderedCount = renderedCount + #containers
        groups[#groups + 1] = { containers = containers }
        for _, item in ipairs(containers) do
            if Read(item.reference, "NotAvailable") ~= true then
                availableCount = availableCount + 1
                if item.resolved then knownCount = knownCount + 1 end
                if item.source == "native" then nativeCount = nativeCount + 1 end
                if item.damageResolved then damageKnownCount = damageKnownCount + 1 end
            end
        end
    end

    
    
    local canFilter = not scanItems or nativeCount > 0 or (knownCount > 0 and catalogSchoolCount > 0)
        or (renderedCount > 0 and availableCount == 0)
    
    
    -- An unresolved school must not be assigned an invented category.
    local canDamageFilter = not checkDamage or not scanItems
        or damageKnownCount > 0 or (renderedCount > 0 and availableCount == 0)
    
    
    if schoolFiltering or damageFiltering or query ~= "" or classFiltering or concentrationFiltering then state.hasFiltered = true end
    local visibleCount = 0
    local classHidden, classUnmatched, classUnmatchedSamples = 0, 0, {}
    local concentrationKnown, concentrationUnknown, concentrationHidden = 0, 0, 0
    local concentrationPoolMatches, concentrationExactMatches = 0, 0
    local concentrationUnknownSamples = {}
    for _, group in ipairs(groups) do
        for _, item in ipairs(group.containers) do
            local excludedByClass = false
            if classFiltering then
                local ok,result=pcall(ClassMember,item.reference,disabledSet)
                if ok then
                    excludedByClass=result==true
                elseif not state.classNativeReadWarning then
                    state.classNativeReadWarning=true
                    Log("Class-list native identity lookup failed: "..tostring(result))
                end
            end
            if classFiltering and Read(item.reference,"NotAvailable") ~= true then
                if excludedByClass then
                    classHidden=classHidden+1
                else
                    classUnmatched=classUnmatched+1
                    if #classUnmatchedSamples<6 then
                        local ok,summary=pcall(function()
                            local spell=Read(item.reference,"Spell")
                            local id=type(spell)=="string" and spell or nil
                            if not id then
                                for _,field in ipairs(ID_FIELDS) do
                                    local candidate=Read(spell,field) or Read(item.reference,field)
                                    if type(candidate)=="string" then id=candidate;break end
                                end
                            end
                            local displayName=NameHandle(Read(spell,"Name"))
                            return tostring(id or displayName or spell)
                        end)
                        classUnmatchedSamples[#classUnmatchedSamples+1]=ok and summary or "unreadable-native-spell"
                    end
                end
            end
            local matchesConcentration = true
            if concentrationFiltering then
                local ok, value, source = pcall(ConcentrationForReference, item.reference)
                if not ok then
                    if not state.concentrationReadWarning then
                        state.concentrationReadWarning = true
                        Log("SpellFlags IsConcentration lookup failed: " .. tostring(value))
                    end
                    value = nil
                end
                if value == nil then
                    concentrationUnknown = concentrationUnknown + 1
                    matchesConcentration = false
                    if #concentrationUnknownSamples < 4 then
                        local spell = Read(item.reference, "Spell")
                        concentrationUnknownSamples[#concentrationUnknownSamples + 1] =
                            tostring(Read(spell, "Name") or Read(spell, "Icon") or spell)
                            .. " (" .. tostring(source or "lookup-error") .. ")"
                    end
                else
                    concentrationKnown = concentrationKnown + 1
                    if source == "class-pool" then concentrationPoolMatches = concentrationPoolMatches + 1 end
                    if source == "exact" then concentrationExactMatches = concentrationExactMatches + 1 end
                    matchesConcentration = value == requestedConcentration
                end
                if not matchesConcentration then concentrationHidden = concentrationHidden + 1 end
            end
            -- School / damage selections are inclusive within each category;
            -- class-list exclusions, concentration and search narrow further.
            local schoolMatch = not schoolFiltering or (schoolAnySelected
                and (not item.resolved or CategoryEnabled(state.schoolEnabled, item.school)))
            local damageMatch = true
            if damageFiltering then
                damageMatch = damageAnySelected
                if damageMatch and item.damageResolved then
                    if item.damage and next(item.damage) then
                        -- Unchecked damage types are exclusions. If a spell
                        -- deals Fire and Cold, unchecking either hides it.
                        for damage in pairs(item.damage) do
                            if not CategoryEnabled(state.damageEnabled, damage) then
                                damageMatch = false
                                break
                            end
                        end
                    else
                        damageMatch = CategoryEnabled(state.damageEnabled, "Non-Damaging")
                    end
                end
                -- An unresolved damage reference is left visible rather than
                -- being misclassified as non-damaging. If all boxes are off,
                -- every spell is hidden, regardless of metadata availability.
            end
            local visible = Read(item.reference, "NotAvailable") ~= true
                and schoolMatch and damageMatch
                and (query == "" or (item.searchName and item.searchName:find(query, 1, true) ~= nil))
                and not excludedByClass
                and matchesConcentration
            local visibility = visible and "Visible" or "Collapsed"
            if state.hasFiltered and Read(item.element, "Visibility") ~= visibility then
                item.element.Visibility = visibility
            end
            if visible then visibleCount = visibleCount + 1 end
        end
    end

    if classFiltering then
        -- Log once per chosen filter combination rather than each UI refresh.
        local disabledIds={}
        for guid in pairs(disabled) do if disabled[guid] then disabledIds[#disabledIds+1]=guid end end
        table.sort(disabledIds)
        local signature=table.concat(disabledIds,",")
        if state.classCoverageDiagnostic~=signature then
            state.classCoverageDiagnostic=signature
            local hiddenNames={}
            for _,classEntry in ipairs(classOptions) do
                if disabled[classEntry.Guid] then hiddenNames[#hiddenNames+1]=classEntry.Name end
            end
            Log(name.." player="..tostring(widget.PlayerId)
                .."; hidden classes="..table.concat(hiddenNames,",")
                .."; class-filter hidden="..tostring(classHidden)
                .." unmatched="..tostring(classUnmatched)
                .." rendered="..tostring(renderedCount)
                .."; unmatched samples="..table.concat(classUnmatchedSamples,";"))
        end
    else
        state.classCoverageDiagnostic=nil
    end
    if concentrationFiltering then
        local signature = tostring(requestedConcentration) .. ":" .. tostring(renderedCount)
        if state.concentrationDiagnostic ~= signature then
            state.concentrationDiagnostic = signature
            Log(name .. " player=" .. tostring(widget.PlayerId)
                .. "; concentration=" .. (requestedConcentration and "only" or "excluded")
                .. "; recognized=" .. tostring(concentrationKnown)
                .. "; exact=" .. tostring(concentrationExactMatches)
                .. "; canonical=" .. tostring(concentrationPoolMatches)
                .. "; unmatched=" .. tostring(concentrationUnknown)
                .. "; hidden=" .. tostring(concentrationHidden)
                .. "; unknown samples=" .. table.concat(concentrationUnknownSamples, ", "))
        end
    else
        state.concentrationDiagnostic = nil
    end
    local status = ""
    if scanItems then
        state.metadataUnavailable = not canFilter
        state.damageUnavailable = not canDamageFilter
    end
    if scanItems and renderedCount == 0 then
        status = "Spell choices not detected; showing all Spells."
    elseif query ~= "" and visibleCount == 0 and availableCount > 0 then
        status = "No matching Spells."
    elseif state.metadataUnavailable and schoolFiltering then
        status = "Some spell schools could not be identified."
    elseif state.damageUnavailable and damageFiltering then
        status = "Some damage types could not be identified."
    elseif (schoolFiltering or damageFiltering or query ~= "" or classFiltering or concentrationFiltering) and visibleCount == 0 and availableCount > 0 then
        status = "No matching Spells."
    end
    state.appliedIndex = state.index
    local function SetField(vm, field, value)
        if vm[field] ~= value then vm[field] = value end
    end
    
    for index, vm in ipairs(headerVMs) do
        SetField(vm, "HB_Visible", nativeHeaders or index == 1)
        if vm.HB_SearchText ~= (state.searchText or "") then
            SetField(vm, "HB_SearchText", state.searchText or "")
        end
        SetField(vm, "HB_Label", "Spell Filtering")
        SetField(vm, "HB_Header", "Spell School")
        SetField(vm, "HB_FilterOpen", state.filterOpen == true)
        SetField(vm, "HB_MenuOpen", state.menuOpen == true)
        for index = 2, #SCHOOLS do
            SetField(vm, "HB_SchoolEnabled_" .. index,
                CategoryEnabled(state.schoolEnabled, SCHOOLS[index]))
        end
        SetField(vm, "HB_DamageHeader", "Damage Type")
        SetField(vm, "HB_DamageMenuOpen", state.damageMenuOpen == true)
        for index = 2, #DAMAGE_TYPES do
            SetField(vm, "HB_DamageEnabled_" .. index,
                CategoryEnabled(state.damageEnabled, DAMAGE_TYPES[index]))
        end
        SetField(vm, "HB_DamageNonDamagingEnabled",
            CategoryEnabled(state.damageEnabled, "Non-Damaging"))
        SetField(vm, "HB_Status", status)
        SetField(vm, "HB_ClassesHeader", "Class")
        SetField(vm, "HB_ConcentrationMenuOpen", state.concentrationMenuOpen == true)
        SetField(vm, "HB_ConcentrationEnabled", state.concentrationOnly == true)
        SetField(vm, "HB_NotConcentrationEnabled", state.nonConcentrationOnly == true)
        SetField(vm,"HB_ClassesMenuOpen",state.classMenuOpen==true)
        for row=1,MAX_CLASS_ROWS do
            local option=classOptions[row]
            SetField(vm,"HB_ClassName_"..row,option and option.DisplayName or "")
            SetField(vm,"HB_ClassEnabled_"..row,not option or not disabled[option.Guid])
            SetField(vm,"HB_ClassVisible_"..row,option~=nil)
        end
        
        
        SetField(vm, "HB_Ready", true)
    end
    if not scanItems and state.counts then
        knownCount, availableCount, renderedCount, nativeCount = state.counts.known, state.counts.available, state.counts.rendered, state.counts.native
        damageKnownCount = state.counts.damageKnown
    else
        state.counts = { known = knownCount, available = availableCount, rendered = renderedCount, native = nativeCount, damageKnown = damageKnownCount }
    end
    local signature = #lists .. ":" .. #headerVMs .. ":" .. knownCount .. ":" .. availableCount .. ":" .. renderedCount .. ":" .. nativeCount .. ":" .. damageKnownCount .. ":" .. tostring(state.damageUnavailable)
    if state.diagnostic ~= signature then
        state.diagnostic = signature
        Log(name .. " player=" .. tostring(widget.PlayerId)
            .. "; available lists=" .. #lists .. "; school headers=" .. #headerVMs
            .. "; native headings=" .. #headers
            .. "; library=" .. tostring(widget:Resource("HB_SpellSchoolLibraryLoaded", true))
            .. "; rendered spell references=" .. renderedCount
            .. "; resolved school metadata=" .. knownCount .. "/" .. availableCount
            .. "; native school fields=" .. nativeCount
            .. "; resolved damage metadata=" .. damageKnownCount .. "/" .. availableCount)
        if checkDamage and availableCount > 0 and damageKnownCount == 0 then
            Log("No usable damage metadata matched. Unresolved Spells excluded; selected damage filter retained.")
            local sampled = 0
            for _, group in ipairs(groups) do
                for _, item in ipairs(group.containers) do
                    local spell = Read(item.reference, "Spell")
                    local name, icon = Read(spell, "Name"), Read(spell, "Icon")
                    Log("Damage lookup: Name=" .. tostring(name) .. "; Icon=" .. tostring(icon)
                        .. "; Level=" .. tostring(Read(spell, "Level"))
                        .. "; SpellSchool=" .. tostring(Read(spell, "SpellSchool"))
                        .. "; name candidates=" .. (byName[name] and #byName[name] or 0)
                        .. "; icon candidates=" .. (byIcon[icon] and #byIcon[icon] or 0))
                    sampled = sampled + 1
                    if sampled == 3 then break end
                end
                if sampled == 3 then break end
            end
        end
        if availableCount > 0 and knownCount == 0 then
            Log("No usable school metadata resolved. Filtering stays disabled; send these lines for diagnosis.")
            for _, group in ipairs(groups) do
                if group.containers[1] then
                    local spell = Read(group.containers[1].reference, "Spell")
                    if type(spell) == "string" then
                        Log("Unresolved spell string=" .. spell)
                    elseif spell then
                        local fields = {}
                        for field in pairs(Properties(spell)) do fields[#fields + 1] = field end
                        table.sort(fields)
                        Log("Unresolved spell VM " .. spell.Type .. "; fields=" .. table.concat(fields, ", "))
                        local sampled = 0
                        for _, field in ipairs(fields) do
                            local lower = field:lower()
                            if lower:find("spell", 1, true) or lower:find("prototype", 1, true)
                                or lower:find("stat", 1, true) or lower:match("id$")
                                or lower == "name" or lower == "identifier" or lower == "school" then
                                local ok, value = pcall(function() return spell[field] end)
                                if ok then Log("Spell." .. field .. " (" .. type(value) .. ")=" .. tostring(value)) end
                                sampled = sampled + 1
                                if sampled == 8 then break end
                            end
                        end
                    end
                    break
                end
            end
        end
    end
end

local function Update()
    local root = Ext.UI.GetRoot()
    if not root then return end
    local widgets, host, candidateNames = {}, nil, {}
    
    
    local content = root:Find("ContentRoot")
    if not content then
        if rootDiagnostic ~= "no-content-root" then
            rootDiagnostic = "no-content-root"
            Log("ContentRoot not found; waiting for UI state pages.")
        end
        return
    end
    for index = 1, content.ChildrenCount do
        local child = content:Child(index)
        if child then
            local name = Read(child, "Name")
            local filename
            if child.Type:match("UIWidget$") then
                filename = child.FileName
                if type(filename) == "string" then
                    local fromFile = filename:gsub("\\", "/"):match("([^/]+)%.xaml$")
                    if WIDGET_NAMES[fromFile] or fromFile == HOST_NAME then name = fromFile end
                end
                if #candidateNames < 12 then
                    candidateNames[#candidateNames + 1] = tostring(name) .. " [" .. tostring(filename) .. "]"
                end
            end
            if name == HOST_NAME then host = child end
            if WIDGET_NAMES[name] then widgets[#widgets + 1] = { node = child, name = name } end
        end
    end
    local seen = {}
    if #widgets > 0 then
        local template = host and host:Resource(TEMPLATE_KEY, true)
        if not template then
            if not resourceWarning then
                Log("Fallback resource host is missing. Native school headings can still initialize; check the UI state merge for replacement pages.")
                resourceWarning = true
            end
        end
        for _, widget in ipairs(widgets) do UpdateWidget(widget.node, template, seen, widget.name) end
    end
    local rootSignature = #widgets .. ":" .. table.concat(candidateNames, "; ")
    if rootDiagnostic ~= rootSignature then
        rootDiagnostic = rootSignature
        Log("Detected character pages=" .. #widgets .. "; UI pages=" .. table.concat(candidateNames, "; "))
    end
    for key in pairs(states) do if not seen[key] then states[key] = nil end end
end

if not Ext.UI or not Ext.UI.GetRoot or not Ext.UI.RegisterType or not Ext.UI.Instantiate then
    Log("The required SE 32 Noesis UI APIs are unavailable; check the client Script Extender installation.")
    return
end

local vmFields = {
    HB_Label = { Type = "String", Notify = true },
    HB_Status = { Type = "String", Notify = true },
    HB_Visible = { Type = "Bool", Notify = true },
    HB_Ready = { Type = "Bool", Notify = true },
    HB_MenuOpen = { Type = "Bool", Notify = true },
    HB_FilterOpen = { Type = "Bool", Notify = true },
    HB_ToggleFilter = { Type = "Command" },
    HB_Header = { Type = "String", Notify = true },
    HB_Previous = { Type = "Command" },
    HB_Next = { Type = "Command" },
    HB_Reset = { Type = "Command" },
    HB_Toggle = { Type = "Command" },
    HB_ToggleDamage = { Type = "Command" },
    HB_DamageHeader = { Type = "String", Notify = true },
    HB_DamageMenuOpen = { Type = "Bool", Notify = true },
    HB_Damage_NonDamaging = { Type = "Command" },
    HB_DamageNonDamagingEnabled = { Type = "Bool", Notify = true },
    HB_SearchText = { Type = "String", Notify = true },
    HB_SearchChanged = { Type = "Command" },
    HB_ClearSearch = { Type = "Command" },
    HB_ClassesHeader = { Type = "String", Notify = true },
    HB_ClassesMenuOpen = { Type = "Bool", Notify = true },
    HB_ToggleClasses = { Type = "Command" },
    HB_Class_CheckAll = { Type = "Command" },
    HB_Class_UncheckAll = { Type = "Command" },
    HB_School_CheckAll = { Type = "Command" },
    HB_School_UncheckAll = { Type = "Command" },
    HB_Damage_CheckAll = { Type = "Command" },
    HB_Damage_UncheckAll = { Type = "Command" },
    HB_Concentration_CheckAll = { Type = "Command" },
    HB_Concentration_UncheckAll = { Type = "Command" },
    HB_ConcentrationEnabled = { Type = "Bool", Notify = true },
    HB_ConcentrationMenuOpen = { Type = "Bool", Notify = true },
    HB_ToggleConcentrationMenu = { Type = "Command" },
    HB_NotConcentrationEnabled = { Type = "Bool", Notify = true },
    HB_ToggleConcentration = { Type = "Command" },
    HB_ToggleNotConcentration = { Type = "Command" },
}
for row=1,MAX_CLASS_ROWS do
    vmFields["HB_ClassName_"..row]={Type="String",Notify=true}
    vmFields["HB_ClassEnabled_"..row]={Type="Bool",Notify=true}
    vmFields["HB_ClassVisible_"..row]={Type="Bool",Notify=true}
    vmFields["HB_Class_"..row]={Type="Command"}
end
for index in ipairs(SCHOOLS) do
    vmFields["HB_School_" .. index] = { Type = "Command" }
    if index > 1 then vmFields["HB_SchoolEnabled_" .. index] = { Type = "Bool", Notify = true } end
end
for index in ipairs(DAMAGE_TYPES) do
    vmFields["HB_Damage_" .. index] = { Type = "Command" }
    if index > 1 then vmFields["HB_DamageEnabled_" .. index] = { Type = "Bool", Notify = true } end
end
Ext.UI.RegisterType(FILTER_TYPE, vmFields)

Log("Loaded spell school + damage + name + class pools + concentration filters v5.16 (nested multiselect concentration-match repair; SE 32 compatible); UI mode="
    .. (deferredUI and "deferred" or "client Tick") .. "; waiting for spell stats and character UI.")

Ext.Events.StatsLoaded:Subscribe(function()
    BuildCatalog()
    ClassSpellIndex.Build()
end)
Ext.Events.SessionLoaded:Subscribe(function()
    BuildCatalog()
    ClassSpellIndex.Build()
    local info=ClassSpellIndex.Summary()
    Log("Installed class spell-list index: classes="..tostring(info.Classes)
        .." lists="..tostring(info.Lists).." spells="..tostring(info.Spells)
        .." HB class pools="..tostring(info.HBPools or 0))
    Log("Class list filter groups="..#ClassSpellIndex.GetOptions().."; exact SpellLists.lsx pools, 80 IDs each")
    states = {}
    propertyCache = {}
    lastUpdate = 0
end)
local MenuScope = Ext.Require("Client/MenuScope.lua")
local lastScopePoll, scopeOpen = -100000, false
local function CharacterMenuVisible(now)
    if now - lastScopePoll >= (scopeOpen and 300 or 950) then
        lastScopePoll, scopeOpen = now, MenuScope.IsOpen('Character')
    end
    return scopeOpen
end

Ext.Events.Tick:Subscribe(function()
    
    
    if diagnosticDirty and Ext.IO and Ext.IO.SaveFile then
        diagnosticDirty = false
        local ok, saved = pcall(Ext.IO.SaveFile, "HomeBrew/Diagnostics/HB_SpellFilter_Diagnostics.txt", table.concat(diagnosticLines, "\n") .. "\n")
        if not ok or saved == false then
            Ext.Utils.Print("[HB Spell Filter] Could not write diagnostic report; console messages remain available.")
        end
    end
    if #consoleJobs > 0 then
        local jobs = consoleJobs
        consoleJobs = {}
        for _, job in ipairs(jobs) do
            DispatchUI(function()
                local ok, message = pcall(job)
                if not ok then Log("Diagnostic command failed: " .. tostring(message)) end
            end)
        end
    end
    if not catalogReady or queued then return end
    local now = Ext.Timer.MonotonicTime()
    if not CharacterMenuVisible(now) then return end
    if now - lastUpdate < INTERVAL_MS then return end
    lastUpdate = now
    queued = true
    DispatchUI(function()
        queued = false
        local ok, message = pcall(Update)
        if not ok and not updateWarning then
            Log("UI update failed: " .. tostring(message))
            updateWarning = true
        end
    end)
end)


Ext.RegisterConsoleCommand("hb_spellfilter_dump", function()
    consoleJobs[#consoleJobs + 1] = function()
        local root = Ext.UI.GetRoot()
        if not root then Log("No UI root."); return end
        Walk(root, function(widget)
            if not WIDGET_NAMES[Read(widget, "Name")] then return end
            local dc = Read(widget, "DataContext")
            Log(Read(widget, "Name") .. " / " .. dc.Type)
            Walk(widget, function(control)
                if not IsAvailableList(control, dc) then return end
                local items = CollectContainers(control)
                Log("Available list " .. tostring(Read(control, "Name")) .. ": " .. #items .. " rendered references")
                for index = 1, math.min(3, #items) do
                    local item = items[index]
                    local spell = Read(item.reference, "Spell")
                    local spellType = type(spell) == "string" and "stat ID string" or spell.Type
                    Log("Spell VM " .. tostring(spellType) .. "; school=" .. tostring(item.school) .. "; ID resolved=" .. tostring(item.resolved))
                    for _, field in ipairs(ID_FIELDS) do
                        local id = Read(spell, field)
                        if type(id) == "string" then Log(field .. "=" .. id) end
                    end
                    local names = {}
                    for property in pairs(Properties(spell)) do names[#names + 1] = property end
                    table.sort(names)
                    Log("Fields: " .. table.concat(names, ", "))
                end
                return false
            end, 0)
            return false
        end, 0)
    end
end)
