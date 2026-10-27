

local Base = {}
Base.Abilities = { "Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma" }
Base.Variable = "HB_AbilityBaseChoices_v1"
Base.Minimum, Base.Default, Base.Maximum = 1, 8, 20



Base.Costs = { -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 7, 9, 12, 15, 19, 23, 28 }
Base.Budget = 0

function Base.Integer(value, minimum, maximum)
    return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

function Base.Cost(value)
    return assert(Base.Costs[value], "Invalid ability base value")
end

function Base.Choices(value)
    local result, total, adjusted = {}, 0, false
    for index = 1, 6 do
        local choice = type(value) == "table" and value[index]
        result[index] = Base.Integer(choice, Base.Minimum, Base.Maximum) and choice or Base.Default
        if type(value) == "table" and choice ~= result[index] then adjusted = true end
        total = total + Base.Cost(result[index])
    end
    
    
    
    while total > Base.Budget do
        local index, highest = nil, Base.Default
        for candidate = 1, 6 do
            if result[candidate] > highest then index, highest = candidate, result[candidate] end
        end
        if not index then break end
        result[index] = highest - 1
        total = total - (Base.Cost(highest) - Base.Cost(highest - 1))
        adjusted = true
    end
    return result, adjusted
end

function Base.Available(choices)
    local total = 0
    for index = 1, 6 do total = total + Base.Cost(choices[index]) end
    return Base.Budget - total
end

function Base.CanChoose(choices, index, value)
    return Base.Integer(index, 1, 6) and Base.Integer(value, Base.Minimum, Base.Maximum)
        and Base.Available(choices) - (Base.Cost(value) - Base.Cost(choices[index])) >= 0
end

function Base.Passive(index, value)
    return "HB_AbilityBase_" .. Base.Abilities[index] .. "_" .. value
end

function Base.Channel() return Ext.Net.CreateChannel(ModuleUUID, "HB_AbilityBasePassives_v1") end

Ext.Vars.RegisterUserVariable(Base.Variable, {
    Server = true, Client = true, Persistent = true, SyncToClient = true,
    WriteableOnServer = true, WriteableOnClient = false,
})
return Base
