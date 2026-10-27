-- HomeBrew starting equipment options. All identifiers refer to installed game statistics.
local Catalog = {}
Catalog.Slots = Ext.Require('Shared/StartingGearItems.lua')

Catalog.BySlot={}
for _,slot in ipairs(Catalog.Slots) do
    Catalog.BySlot[slot.id]=slot
end
function Catalog.Find(slotID, stat)
    local slot=Catalog.BySlot[slotID]
    if not slot or type(stat)~='string' then return nil end
    if stat=='' then return slot, nil end
    for _,option in ipairs(slot.items) do
        if option[2]==stat then return slot, option end
    end
    return nil
end
function Catalog.Available(stat)
    if type(stat)~='string' or stat=='' then return false end
    local ok,result=pcall(function() return Ext.Stats.Get(stat) end)
    return ok and result~=nil
end
function Catalog.RootTemplate(stat)
    if not Catalog.Available(stat) then return nil end
    local current=stat
    for _=1,8 do
        local ok,obj=pcall(Ext.Stats.Get,current)
        if not ok or not obj then return nil end
        local success,root=pcall(function() return obj.RootTemplate end)
        if success and type(root)=='string' and root:match('^[0-9a-fA-F%-]+$') and #root==36 then
            return root
        end
        local found,parent=pcall(function() return obj.Using end)
        if not found or type(parent)~='string' or parent=='' or parent==current then return nil end
        current=parent
    end
    return nil
end
Catalog.TwoHanded={}
for _,slot in ipairs(Catalog.Slots) do
    for _,entry in ipairs(slot.items) do
        if entry[3] == true then Catalog.TwoHanded[entry[2]]=true end
    end
end
function Catalog.Conflict(choices)
    if choices.OffHand and Catalog.TwoHanded[choices.MainHand] then return 'A two-handed weapon cannot use an off-hand weapon.' end
    if choices.RangedOff and Catalog.TwoHanded[choices.Ranged] then return 'A two-handed weapon cannot use an off-hand weapon.' end
    return nil
end
return Catalog
