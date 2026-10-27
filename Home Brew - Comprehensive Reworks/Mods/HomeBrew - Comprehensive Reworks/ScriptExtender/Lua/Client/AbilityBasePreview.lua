


local Preview = {}


local rendered = {}
local scores = {}
local tooltipPages, eventMetadata = {}, {}

local function Unsubscribe(ids)
    
    
    pcall(function()
        local root = Ext.UI.GetRoot()
        if root and root.Unsubscribe then
            for _, id in ipairs(ids) do root:Unsubscribe(id) end
        end
    end)
end

local function ReleaseHooks(page)
    for _, hook in pairs(page.Hooks) do
        hook.Active = false
        Unsubscribe(hook.Ids)
    end
    page.Pending = {}
end

function Preview.Prune(pages)
    local live = {}
    for _, page in ipairs(pages) do live[tostring(page.Node)] = true end
    for token in pairs(rendered) do if not live[token] then rendered[token] = nil end end
    for token in pairs(scores) do if not live[token] then scores[token] = nil end end
    for token, page in pairs(tooltipPages) do
        if not live[token] then ReleaseHooks(page); tooltipPages[token] = nil end
    end
end

local function Normalize(text)
    
    local normalized = text:gsub("−", "-")
    for _, mark in ipairs({ "‎", "‏", "‪", "‫", "‬", "‭", "‮", "⁦", "⁧", "⁨", "⁩" }) do normalized = normalized:gsub(mark, "") end
    return (normalized:gsub(" ", " "):gsub(" ", " "))
end

local function Number(value)
    if type(value) == "number" then return value % 1 == 0 and value or nil end
    if type(value) ~= "string" then return nil end
    local number = tonumber(Normalize(value))
    return number and number % 1 == 0 and number or nil
end

local function Modifier(score) return math.floor((score - 10) / 2) end

function Preview.Delta(original, choice, included)
    local adjusted = math.max(1, original - (included or 0) + choice - 8)
    return Modifier(adjusted) - Modifier(original), adjusted
end

function Preview.HitPoints(original, delta, level, multiplier)
    return math.max(1, math.floor(original + delta * level * multiplier + 0.000001))
end

local function IsReference(value)
    return type(value) == "userdata" or type(value) == "table"
end

local function ObjectType(value)
    if not IsReference(value) then return nil end
    
    
    local ok, kind = pcall(function() return value.Type end)
    return ok and kind ~= nil and tostring(kind) or nil
end

local function Properties(object)
    local result, seen = {}, {}
    if not ObjectType(object) then return result end
    local info = object:TypeInfo()
    while info do
        for _, property in ipairs(info.Properties or {}) do
            if not seen[property.Name] then result[#result + 1], seen[property.Name] = property.Name, true end
        end
        info = info.Base
    end
    table.sort(result)
    return result
end

local function Ability(object, read, base)
    local index = read(object, "AbilityValue")
    if base.Integer(index, 1, 6) then return index end
    for _, field in ipairs({ "Ability", "AbilityId", "AbilityType" }) do
        local value = read(object, field)
        if base.Integer(value, 1, 6) then return value end
        local name = tostring(value)
        for candidate, ability in ipairs(base.Abilities) do if name == ability then return candidate end end
    end
end

local function IsObject(value)
    return ObjectType(value) ~= nil
end

local function Events(object)
    local kind = ObjectType(object)
    if not kind then return {} end
    if eventMetadata[kind] then return eventMetadata[kind] end
    local events = {}
    local info = object:TypeInfo()
    while info do
        for _, event in ipairs(info.RoutedEvents or {}) do events[tostring(event.Name)] = true end
        info = info.Base
    end
    eventMetadata[kind] = events
    return events
end

local function RefreshTooltip(token, root)
    local page = tooltipPages[token]
    if not page or page.Running then return end
    local frame = page.Frame
    page.Running = true
    local ok, failure = pcall(function()
        
        
        if tostring(frame.Read(frame.Widget, "DataContext")) ~= tostring(frame.Native) then return end
        Preview.Update(frame.Widget, frame.Native, frame.Key, frame.State,
            frame.Rows, frame.Base, frame.Read, frame.Walk, frame.Observe, root)
    end)
    page.Running = false
    if not ok then frame.Observe("tooltip-opening-retry:" .. frame.Key,
        "Tooltip opening preview will retry after UI rebuild: " .. tostring(failure)) end
end

local HookTooltip
local function OpenTooltip(token, root)
    if not IsObject(root) then return end
    local page = tooltipPages[token]
    if not page then return end
    
    
    HookTooltip(page, root, {"Loaded", "Opened"}, function(target)
        OpenTooltip(token, target)
    end)
    RefreshTooltip(token, root)
    if not Ext.UI.Defer then return end
    
    
    page.Pending[tostring(root)] = root
    if page.Queued then return end
    page.Queued = true
    local ok = pcall(Ext.UI.Defer, function()
        page.Queued = false
        local pending = page.Pending
        page.Pending = {}
        if tooltipPages[token] ~= page then return end
        for tooltipToken, tooltip in pairs(pending) do
            local hook = page.Hooks[tooltipToken]
            if hook and hook.Active then RefreshTooltip(token, tooltip) end
        end
    end)
    if not ok then page.Queued, page.Pending = false, {} end
end

HookTooltip = function(page, object, names, callback)
    local token = tostring(object)
    page.Seen[token] = true
    if page.Hooks[token] then return end
    local hook = {Ids = {}, Active = true}
    page.Hooks[token] = hook
    local ok = pcall(function()
        if not object.Subscribe then return end
        local events = Events(object)
        for _, name in ipairs(names) do
            if events[name] then
                local id = object:Subscribe(name, function(target, args)
                    if hook.Active then callback(target, args) end
                end)
                if type(id) == "number" and id ~= 0 then hook.Ids[#hook.Ids + 1] = id end
            end
        end
    end)
    if not ok then
        hook.Active = false
        Unsubscribe(hook.Ids)
        page.Hooks[token] = nil
        page.Frame.Observe("tooltip-hook-retry:" .. page.Frame.Key,
            "Tooltip opening hooks unavailable during UI rebuild; periodic preview remains active.")
    end
end



local function ReplaceNumber(text, old, value, signed)
    if type(text) ~= "string" then return end
    local source = text:gsub("−", "-")
    local count, token = 0, nil
    for item in source:gmatch("[%+%-]?%d+%.?%d*") do count, token = count + 1, item end
    if count ~= 1 or Number(token) ~= old then return end
    local replacement = ((signed or token:sub(1, 1) == "+") and value >= 0 and "+" or "") .. string.format("%.0f", value)
    if value < 0 and text:find("−", 1, true) then replacement = replacement:gsub("-", "−") end
    return (source:gsub("[%+%-]?%d+%.?%d*", function() return replacement end, 1))
end

local function NumericToken(text)
    local first, last, count = nil, nil, 0
    local offset = 1
    while true do
        local start, finish = text:find("%d+%.?%d*", offset)
        if not start then break end
        count, first, last = count + 1, start, finish
        offset = finish + 1
    end
    if count ~= 1 then return end
    local sign = text:sub(first - 1, first - 1)
    if sign == "+" or sign == "-" then first = first - 1
    elseif first > 3 and text:sub(first - 3, first - 1) == "−" then first = first - 3 end
    return first, last
end

local function Content(node, read)
    local parts, seen, count = {}, {}, 0
    local function Collect(collection, depth)
        if not IsReference(collection) then return end
        if depth > 8 then error("Inline preview exceeds bounded depth") end
        for index = 1, 129 do
            local entry = collection[index]
            if entry == nil then break end
            count = count + 1
            if count > 128 then error("Inline preview exceeds bounded scan") end
            if IsObject(entry) and not seen[tostring(entry)] then
                seen[tostring(entry)] = true
                local text = read(entry, "Text")
                if type(text) == "string" then
                    parts[#parts + 1] = { Node = entry, Text = text }
                elseif (ObjectType(entry) or ""):lower():find("linebreak", 1, true) then
                    parts[#parts + 1] = { Text = "\n" }
                else Collect(read(entry, "Inlines"), depth + 1) end
            end
        end
    end
    
    
    local ok = pcall(Collect, read(node, "Inlines"), 0)
    if ok and #parts > 0 then
        local texts = {}
        for index, part in ipairs(parts) do texts[index] = part.Text end
        return { Text = table.concat(texts), Parts = parts, Mode = "Inlines" }
    end
    local text = read(node, "Text")
    if type(text) == "string" then return { Text = text, Mode = "Text" } end
end

local function WriteContent(node, content, updated, range)
    if content.Mode == "Text" then node.Text = updated; return end
    local first, last, replacement
    if range then
        first, last, replacement = range.First, range.Last, range.Replacement
    else
        first, last = NumericToken(content.Text)
        local newFirst, newLast = NumericToken(updated)
        if not first or not newFirst then return false end
        replacement = updated:sub(newFirst, newLast)
    end
    local newSign, digits = replacement:match("^([%+%-]?)(.*)$")
    if replacement:sub(1, 3) == "−" then newSign, digits = "−", replacement:sub(4) end
    local position, signPlaced, digitsPlaced = 1, false, false
    local writes = {}
    for _, part in ipairs(content.Parts) do
        local finish = position + #part.Text - 1
        if part.Node and finish >= first and position <= last then
            local start = math.max(first, position) - position + 1
            local stop = math.min(last, finish) - position + 1
            local oldPiece = part.Text:sub(start, stop)
            local newPiece = ""
            if oldPiece:find("%d") then
                if not digitsPlaced then
                    newPiece, digitsPlaced = (signPlaced and "" or newSign) .. digits, true
                end
            elseif not signPlaced and not digitsPlaced then newPiece, signPlaced = newSign, true end
            writes[#writes + 1] = { Node = part.Node,
                Text = part.Text:sub(1, start - 1) .. newPiece .. part.Text:sub(stop + 1) }
        end
        position = finish + 1
    end
    if not digitsPlaced then return false end
    for _, write in ipairs(writes) do write.Node.Text = write.Text end
end

function Preview.IsProjected(node, state, read)
    local previous = state.derivedText and state.derivedText[tostring(node)]
    if not previous or previous.DisplayContext ~= tostring(read(node, "DataContext")) then return false end
    local content = Content(node, read)
    return content and content.Text == previous.Written or false
end

function Preview.Score(node, state, index, original, value, read, label, range)
    local content = Content(node, read)
    local shown = content and Number(range and content.Text:sub(range.First, range.Last) or content.Text)
    if shown == nil and label and content then
        local first, last = NumericToken(content.Text)
        if first then shown = Number(content.Text:sub(first, last)) end
    end
    if shown == nil then return false end
    local token = tostring(node)
    state.scoreText = state.scoreText or {}
    local previous = state.scoreText[token]
    
    
    if shown ~= original and not (previous and previous.Index == index and content.Text == previous.Written) then return false end
    local updated
    if range then
        range = {First = range.First, Last = range.Last, Replacement = string.format("%.0f", value)}
        updated = content.Text:sub(1, range.First - 1) .. range.Replacement .. content.Text:sub(range.Last + 1)
    else updated = ReplaceNumber(content.Text, shown, value) end
    if not updated or (updated ~= content.Text and WriteContent(node, content, updated, range) == false) then return false end
    state.scoreText[token] = { Index = index, Written = updated }
    return true, content.Mode
end

function Preview.Update(widget, native, key, state, rows, base, read, walk, observe, tooltipRoot)
    local widgetToken = tostring(widget)
    local page
    if not tooltipRoot then
        page = tooltipPages[widgetToken] or {Hooks = {}, Pending = {}}
        tooltipPages[widgetToken] = page
        page.Frame = {Widget = widget, Native = native, Key = key, State = state,
            Rows = rows, Base = base, Read = read, Walk = walk, Observe = observe}
        page.Seen = {}
        HookTooltip(page, widget, {"ToolTipOpening"}, function(target, args)
            local source = args and args.Source or target
            OpenTooltip(widgetToken, read(source, "ToolTip") or read(target, "ToolTip"))
        end)
    end
    local accepted = state.ackSource and state.lastSource and state.ackSource == state.lastSource.Source
    local deltas = {}
    for index = 1, 6 do
        
        
        local original = state.offsets and Number(state.offsets.Scores[index]) or Number(read(rows[index], "Value"))
        if original then
            local included = accepted and state.offsets and original == state.offsets.Scores[index] and state.offsets.Applied[index] or 0
            deltas[index] = accepted and Preview.Delta(original, state.choices[index], included) or 0
        end
    end
    local targets, visited, schemas, identities, count = {}, {}, {}, {}, 0
    local hpDelta
    local function AddHealth(object)
        if hpDelta == nil then return end
        local token = tostring(object)
        targets[token] = targets[token] or {}
        for _, field in ipairs({ "Value", "Max" }) do
            local original = Number(read(object, field))
            if original then targets[token][field] = { Original = original,
                Value = Preview.HitPoints(original, hpDelta, 1, 1), OnlyNamed = false } end
        end
    end
    local function Add(object, field, index)
        if not index or deltas[index] == nil then return end
        local original = Number(read(object, field))
        if original == nil then return end
        local token = tostring(object)
        targets[token] = targets[token] or {}
        local delta = deltas[index]
        
        
        local score = ObjectType(object) == "ls.VMAbility" and Number(read(object, "Value"))
        if field ~= "Value" and score then
            local included = accepted and state.offsets and score == state.offsets.Scores[index] and state.offsets.Applied[index] or 0
            delta = accepted and Preview.Delta(score, state.choices[index], included) or 0
        end
        targets[token][field] = { Original = original, Value = original + delta, Signed = true,
            OnlyNamed = field ~= "Value" and field ~= "AdditionalValue" and field ~= "Modifier" and field ~= "AbilityModifier"
                and field ~= "ModifierValue" and field ~= "SavingThrow" and field ~= "SavingThrowBonus" }
    end
    local function Schema(object, path)
        local kind = ObjectType(object)
        if not kind or schemas[kind] then return end
        schemas[kind] = true
        local values = {}
        for _, field in ipairs({ "Value", "AdditionalValue", "Modifier", "AbilityValue", "IDString" }) do
            local value = read(object, field)
            if value ~= nil then
                local printed = type(value) == "string" and string.format("%q", value) or tostring(value)
                values[#values + 1] = field .. "=" .. type(value) .. ":" .. printed
            end
        end
        observe("derived-schema:" .. key .. ":" .. kind,
            "Derived preview model: " .. path .. "; type=" .. kind
            .. "; fields=" .. table.concat(Properties(object), ",") .. "; values=" .. table.concat(values, ","))
    end
    local Inspect
    local function InspectModel(object, path, role, index, depth)
        if not IsReference(object) or depth > 5 or count >= 300 then return end
        local token = tostring(object)
        if visited[token] then return end
        visited[token], count = true, count + 1
        local kind = ObjectType(object)
        if not kind or kind:lower():find("collection", 1, true) then
            
            
            for childIndex = 1, 300 do
                if count >= 300 then break end
                local ok, entry = pcall(function() return object[childIndex] end)
                if not ok then
                    observe("derived-collection:" .. key .. ":" .. path,
                        "Derived preview collection unavailable during rebuild: " .. path)
                    break
                end
                if entry == nil then break end
                Inspect(entry, path .. "[" .. childIndex .. "]", role, index, depth + 1)
            end
            return
        end
        index = Ability(object, read, base) or index
        kind = kind:lower()
        for _, field in ipairs({ "Stat", "StatType", "StatId" }) do
            if tostring(read(object, field)) == "Initiative" then role, index = "derived", 2 end
        end
        if kind:find("initiative", 1, true) then role, index = "derived", 2 end
        if kind:find("modifier", 1, true) or kind:find("savingthrow", 1, true)
            or kind:find("skill", 1, true) or kind:find("abilitybonus", 1, true) then role = "derived" end
        if role == "container" and index and not kind:find("ability", 1, true) then role = "derived" end
        local id = read(object, "IDString")
        if index and (role == "derived" or role == "ability" or role == "health") and type(id) == "string" and id ~= "" then
            local identity = kind .. ":" .. id
            local previous = identities[identity]
            if previous == nil then identities[identity] = { Role = role, Index = index }
            elseif previous and previous.Index ~= index then identities[identity] = false end
        end
        if role == "health" then AddHealth(object)
        elseif role == "derived" and index then
            Add(object, "Value", index)
            
            
            
            
            if kind == "ls.vmbaseroll" or (kind == "ls.vmstat" and Number(read(object, "Value")) == nil) then
                Add(object, "AdditionalValue", index)
            end
        end
        Schema(object, path)
        for _, field in ipairs(Properties(object)) do
            local normalized = field:lower():gsub("_", "")
            local child = read(object, field)
            local nextRole, nextIndex = nil, role ~= "health" and index or nil
            if normalized == "initiative" or normalized == "initiativebonus" then
                nextRole, nextIndex = "derived", 2
                if not IsReference(child) then Add(object, field, 2) end
            elseif normalized == "modifier" or normalized == "abilitymodifier" or normalized == "modifiervalue" then
                nextRole = "derived"
                if not IsReference(child) then Add(object, field, index) end
            elseif normalized == "savingthrow" or normalized == "savingthrowbonus" then
                nextRole = "derived"
                if not IsReference(child) then Add(object, field, index) end
            elseif normalized == "abilities" then nextRole, nextIndex = "ability", nil
            elseif normalized == "skills" or normalized == "savingthrows" then nextRole = "derived"
            elseif normalized == "health" or normalized == "hitpoints" or normalized == "maxhp"
                or normalized == "vitality" or normalized == "bonuses" or normalized == "modifiers"
                or normalized == "sources" or normalized == "breakdown" then nextRole = "container" end
            for candidate, ability in ipairs(base.Abilities) do
                if normalized == ability:lower() .. "modifier" then
                    nextRole, nextIndex = "derived", candidate
                    if not IsReference(child) then Add(object, field, candidate) end
                end
            end
            if nextRole and IsReference(child) then
                Inspect(child, path .. "." .. field, nextRole, nextIndex, depth + 1)
            end
        end
    end
    Inspect = function(object, path, role, index, depth)
        local ok, failure = pcall(InspectModel, object, path, role, index, depth)
        if not ok then
            observe("derived-model:" .. key .. ":" .. path,
                "Derived preview model unavailable during rebuild: " .. path .. "; " .. tostring(failure))
        end
    end
    for index = 1, 6 do Inspect(rows[index], base.Abilities[index], "ability", index, 0) end
    local dummy = read(native, "DummyCharacter")
    local stats = read(dummy, "Stats")
    local health = read(stats, "Health")
    if ObjectType(health) == "ls.VMRangeStat" then
        local levelValue = read(stats, "Level")
        local level = Number(levelValue) or (IsObject(levelValue) and Number(read(levelValue, "Value")))
        local snapshot = state.offsets and state.offsets.Health
        level = level or (snapshot and snapshot.Level)
        if not level and (state.page == "CharacterCreation" or state.page == "CharacterCreation_c") then level = 1 end
        local multiplier = snapshot and snapshot.Multiplier or 1
        if level and level >= 1 and multiplier > 0 and deltas[3] ~= nil then
            hpDelta = deltas[3] * level * multiplier
            Inspect(health, "DummyCharacter.Stats.Health", "health", 3, 0)
            observe("derived-hp:" .. key, "HP preview: level=" .. level .. "; multiplier=" .. multiplier
                .. "; Constitution modifier change=" .. deltas[3] .. "; HP change=" .. hpDelta)
        else observe("derived-hp:" .. key, "HP preview awaiting native level/Constitution values") end
    end
    if stats then Inspect(stats, "DummyCharacter.Stats", "container", nil, 0) end
    rendered[widgetToken] = rendered[widgetToken] or {}
    state.derivedText = rendered[widgetToken]
    scores[widgetToken] = scores[widgetToken] or {}
    state.scoreText = scores[widgetToken]
    local mounted, inlineMounted, inlineSeen, tooltipRoots, tooltipSeen, unmatched = 0, 0, 0, {}, {}, 0
    local function Parent(node)
        
        
        local ok, parent = pcall(function() return node.VisualParent end)
        return ok and parent or nil
    end
    local function Context(node)
        local context = read(node, "DataContext")
        if IsObject(context) and not targets[tostring(context)] then
            local kind = ObjectType(context):lower()
            local id = read(context, "IDString")
            local identity = type(id) == "string" and id ~= "" and identities[kind .. ":" .. id]
            if identity then
                
                
                Inspect(context, "visual:" .. tostring(read(node, "Name")), identity.Role, identity.Index, 0)
            elseif kind:find("ability", 1, true) or kind:find("modifier", 1, true)
                or kind:find("initiative", 1, true) or kind:find("skill", 1, true)
                or kind:find("savingthrow", 1, true) then
                Inspect(context, "visual:" .. tostring(read(node, "Name")), nil, nil, 0)
            end
        end
        return context
    end
    local headerScopes, baseLeaves, baseLabels, numericLeaves = {}, {}, {}, {}
    local function TooltipParent(node)
        local parent = Parent(node)
        if parent then return parent end
        
        local ok, logical = pcall(function() return node.Parent end)
        return ok and logical or nil
    end
    local function OwnerIndex(node)
        local owner, seen = node, {}
        for depth = 0, 24 do
            if not owner or seen[tostring(owner)] then break end
            seen[tostring(owner)] = true
            local context = read(owner, "DataContext")
            if ObjectType(context) == "ls.VMAbility" then
                local index = Ability(context, read, base)
                if index then return index end
            elseif ObjectType(context) == "ls.VMTooltipAbility" then
                local index = headerScopes["tooltip:" .. tostring(context)]
                if index then return index end
            end
            owner = TooltipParent(owner)
        end
    end
    local function TooltipIndex(node)
        local index = OwnerIndex(node)
        local owner, seen = node, {}
        for depth = 0, 24 do
            if index or not owner or seen[tostring(owner)] then break end
            local token = tostring(owner)
            seen[token] = true
            if headerScopes[token] then return headerScopes[token] end
            owner = TooltipParent(owner)
        end
        return index
    end
    local function RememberHeader(node, index)
        local owner, seen = node, {}
        for depth = 0, 24 do
            if not owner or seen[tostring(owner)] then break end
            local token = tostring(owner)
            seen[token] = true
            if headerScopes[token] == nil then headerScopes[token] = index
            elseif headerScopes[token] ~= index then headerScopes[token] = false end
            local context = read(owner, "DataContext")
            if ObjectType(context) == "ls.VMTooltipAbility" then
                local contextToken = "tooltip:" .. tostring(context)
                if headerScopes[contextToken] == nil then headerScopes[contextToken] = index
                elseif headerScopes[contextToken] ~= index then headerScopes[contextToken] = false end
            end
            owner = TooltipParent(owner)
        end
    end
    local function HeaderRange(text)
        
        
        local first = text:find("%(")
        if not first then return end
        local numberFirst, numberLast = text:find("[%+%-]?%d+%.?%d*", first + 1)
        if not numberFirst or not Normalize(text:sub(first + 1, numberFirst - 1)):match("^%s*$")
            or not Normalize(text:sub(numberLast + 1)):match("^%s*%)") then return end
        local label = Normalize(text:sub(1, first - 1)):match("^%s*(.-)%s*$")
        return label, {First = numberFirst, Last = numberLast}
    end
    local function BaseRange(text)
        
        
        
        if not text:find("Base", 1, true) then return end
        local offset, result = 1, nil
        while true do
            local first, last = text:find("[%+%-]?%d+%.?%d*", offset)
            if not first then break end
            if Normalize(text:sub(last + 1)):match("^%s*Base%f[%A]") then
                if result then return end 
                result = {First = first, Last = last}
            end
            offset = last + 1
        end
        return result
    end
    local function Header(node, text)
        
        
        local label, range = HeaderRange(text)
        if not label then return false end
        if label == "" then
            
            
            
            local name = tostring(read(node, "Name")):lower():gsub("_", "")
            if name ~= "titlevalue" or ObjectType(read(node, "DataContext")) ~= "ls.VMAbility"
                or not Normalize(text):match("^%s*%(%s*[%+%-]?%d+%.?%d*%s*%)%s*$") then return false end
        end
        local index
        for candidate, ability in ipairs(base.Abilities) do
            if label:lower() == ability:lower() then index = candidate; break end
        end
        index = index or OwnerIndex(node)
        if not index then return false end
        local original = Number(read(rows[index], "Value"))
        if not original then return false end
        local included = accepted and state.offsets and original == state.offsets.Scores[index] and state.offsets.Applied[index] or 0
        local _, value = Preview.Delta(original, accepted and state.choices[index] or 8, included)
        if Preview.Score(node, state, index, original, value, read, true, range) then
            RememberHeader(node, index)
            observe("derived-header:" .. key .. ":" .. tostring(node),
                "Ability tooltip header: index=" .. index .. "; native=" .. original .. "; shown=" .. value)
            return true
        end
        return false
    end
    local function Visit(node)
        local tooltip = read(node, "ToolTip")
        if IsObject(tooltip) and not tooltipSeen[tostring(tooltip)] then
            tooltipSeen[tostring(tooltip)] = true
            tooltipRoots[#tooltipRoots + 1] = tooltip
            if page then
                HookTooltip(page, tooltip, {"Loaded", "Opened"}, function(target)
                    OpenTooltip(widgetToken, target)
                end)
            end
        end
        local context = Context(node)
        local displayContext = tostring(context)
        local content = Content(node, read)
        if content and content.Mode == "Inlines" then inlineSeen = inlineSeen + 1 end
        local text = content and content.Text
        if type(text) == "string" and text ~= "" then
            local token = tostring(node)
            local previous = state.derivedText[token]
            local name = tostring(read(node, "Name")):lower():gsub("_", "")
            local headerLabel = HeaderRange(text)
            local baseRange = BaseRange(text)
            local baseLabel = Normalize(text):match("^%s*Base%s*$") ~= nil
            if headerLabel or baseRange or baseLabel then
                observe("tooltip-text:" .. key .. ":" .. token,
                    "Tooltip caption/base text: name=" .. name .. "; type=" .. tostring(ObjectType(node))
                    .. "; context=" .. tostring(ObjectType(context) or type(context))
                    .. "; content=" .. string.format("%q", text:sub(1, 500)))
            end
            if name == "description" and not baseLabel then return false end
            if Number(text) ~= nil then numericLeaves[token] = node end
            if baseLabel then
                if #baseLabels < 24 then baseLabels[#baseLabels + 1] = node end
                return false
            end
            if baseRange and #baseLeaves < 24 then
                baseLeaves[#baseLeaves + 1] = node
            end
            if Header(node, text) then return false end
            if baseRange then
                return false
            end
            if name == "title" or name == "description" or name == "displayname" then return false end
            local owner, scope, seen = node, name, {}
            for depth = 0, 12 do
                if not owner or seen[tostring(owner)] then break end
                seen[tostring(owner)] = true
                context = depth == 0 and context or Context(owner)
                local ownerName = tostring(read(owner, "Name")):lower():gsub("_", "")
                if ownerName == "title" or ownerName == "description" or ownerName == "displayname" then return false end
                scope = scope .. "/" .. ownerName .. "@" .. (ObjectType(context) or type(context))
                local fields = context and targets[tostring(context)]
                for field, projection in pairs(fields or {}) do
                    local sourceText, sourceOriginal = text, projection.Original
                    if previous and previous.Context == tostring(context) and previous.Field == field
                        and text == previous.Written then sourceText, sourceOriginal = previous.Native, previous.Original end
                    local eligible = not projection.OnlyNamed or scope:find(field:lower():gsub("_", ""), 1, true)
                    
                    
                    if depth > 0 and Number(sourceText) == nil then eligible = false end
                    local updated = eligible and ReplaceNumber(sourceText, sourceOriginal, projection.Value, projection.Signed)
                    if updated then
                        if text ~= updated and WriteContent(node, content, updated) == false then break end
                        state.derivedText[token] = { Context = tostring(context), DisplayContext = displayContext,
                            Field = field, Native = sourceText, Original = sourceOriginal, Written = updated, Mode = content.Mode }
                        mounted = mounted + 1
                        if content.Mode == "Inlines" then inlineMounted = inlineMounted + 1 end
                        observe("derived-value:" .. key .. ":" .. token, "Derived preview: type=" .. tostring(ObjectType(context))
                            .. "; field=" .. field .. "; native=" .. projection.Original .. "; shown=" .. projection.Value
                            .. "; parent depth=" .. depth .. "; content=" .. content.Mode)
                        return false
                    end
                end
                
                if fields then break end
                owner = Parent(owner)
            end
            if NumericToken(text) ~= nil and unmatched < 20 then
                unmatched = unmatched + 1
                local kind = ObjectType(context) or type(context)
                observe("derived-unmatched:" .. key .. ":" .. token,
                    "Derived preview unmatched: name=" .. name .. "; text=" .. string.format("%q", text)
                    .. "; context=" .. kind .. "; parents=" .. scope)
            end
        end
        
        
        if text ~= nil and text ~= "" then return false end
    end
    local function SafeVisit(node)
        local ok, descend = pcall(Visit, node)
        if ok then return descend end
        observe("derived-retry:" .. key, "Derived preview will retry after UI rebuild: " .. tostring(descend))
    end
    if tooltipRoot then
        tooltipRoots[1], tooltipSeen[tostring(tooltipRoot)] = tooltipRoot, true
    else walk(widget, SafeVisit, 0, { count = 0 }) end
    for index = 1, math.min(#tooltipRoots, 24) do
        local tooltip = tooltipRoots[index]
        
        
        local ok, error = pcall(function() walk(tooltip, SafeVisit, 0, { count = 0 }, true) end)
        if not ok then observe("derived-tooltip:" .. key, "Tooltip preview unavailable during rebuild: " .. tostring(error)) end
    end
    
    
    
    for _, node in ipairs(baseLeaves) do
        local ok, failure = pcall(function()
            local index = TooltipIndex(node)
            local original = index and Number(read(rows[index], "BaseValue"))
            if original then
                local value = math.max(1, original + (accepted and state.choices[index] - 8 or 0))
                local content = Content(node, read)
                local range = content and BaseRange(content.Text)
                if range and Preview.Score(node, state, index, original, value, read, true, range) then
                    observe("derived-base:" .. key .. ":" .. tostring(node),
                        "Ability tooltip base: index=" .. index .. "; native=" .. original .. "; shown=" .. value)
                end
            end
        end)
        if not ok then observe("derived-base-retry:" .. key, "Ability tooltip base will retry: " .. tostring(failure)) end
    end
    
    
    
    for _, label in ipairs(baseLabels) do
        local ok, failure = pcall(function()
            local index = TooltipIndex(label)
            local original = index and Number(read(rows[index], "BaseValue"))
            if not original then return end
            local value = math.max(1, original + (accepted and state.choices[index] - 8 or 0))
            local candidates, candidateCount, owner, ancestors = {}, 0, label, {}
            for depth = 1, 6 do
                owner = TooltipParent(owner)
                if not owner or ancestors[tostring(owner)] then break end
                ancestors[tostring(owner)] = true
                walk(owner, function(node)
                    local token = tostring(node)
                    if numericLeaves[token] and not candidates[token] then
                        local content = Content(node, read)
                        local shown = content and Number(content.Text)
                        local previous = state.scoreText[token]
                        if shown == original or (previous and previous.Index == index and content and content.Text == previous.Written) then
                            candidates[token], candidateCount = node, candidateCount + 1
                        end
                    end
                    local content = Content(node, read)
                    if content and content.Text ~= "" then return false end
                end, 0, {count = 0}, true)
                if candidateCount == 1 then
                    local _, node = next(candidates)
                    if Preview.Score(node, state, index, original, value, read) then
                        observe("derived-split-base:" .. key .. ":" .. tostring(label),
                            "Ability tooltip split Base: index=" .. index .. "; native=" .. original .. "; shown=" .. value .. "; row depth=" .. depth)
                    end
                    return
                elseif candidateCount > 1 then break end
            end
            observe("derived-split-base-unmatched:" .. key .. ":" .. tostring(label),
                "Ability tooltip split Base awaiting unique numeric leaf: index=" .. index .. "; candidates=" .. candidateCount)
        end)
        if not ok then observe("derived-split-base-retry:" .. key, "Ability tooltip split Base will retry: " .. tostring(failure)) end
    end
    if page then
        for token, hook in pairs(page.Hooks) do
            if not page.Seen[token] then
                hook.Active = false
                Unsubscribe(hook.Ids)
                page.Hooks[token] = nil
            end
        end
        observe("derived-count:" .. key, "Derived preview text widgets=" .. mounted)
        observe("derived-inlines:" .. key, "Derived preview inline text widgets=" .. inlineMounted .. "; inline blocks scanned=" .. inlineSeen)
    end
end

return Preview
