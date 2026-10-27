-- Read-only source-backed feat shapes. Never substitutes for CCLevelUp ownership.
-- Deliberately does not infer feat eligibility from present-day character stats.
local Catalog=Ext.Require("Shared/HB_FeatDefinitionCatalog.lua")
local M={Catalog=Catalog}
function M.Definition(id)
    return Catalog.Find(tostring(id or ""))
end
function M.PassiveSelectors(id)
    local definition=M.Definition(id)
    if not definition or #definition.Selectors==0 or #definition.PassivesRemoved>0 then return nil end
    local groups={}
    for i,s in ipairs(definition.Selectors) do
        if s.Kind~="SelectPassives" or type(s.SpellList)~="string" or s.SpellList==""
            or type(s.Count)~="number" or s.Count<1 or s.Count>4
            or s.Count~=math.floor(s.Count) then return nil end
        groups[#groups+1]={List=s.SpellList,Count=s.Count,Selector=tostring(s.Args[3] or ""),Index=i}
    end
    return groups
end
-- Only a single, explicit HB class-proficiency requirement is representable
-- using recorded class history; do not allow arbitrary engine expressions.
function M.RequiredClass(id)
    local f=M.Definition(id)
    if not f then return nil end
    if f.Requirements=="" then return "" end
    local cls=f.Requirements:match("^FeatRequirementProficiency%('HB_([%a]+)'%)$")
    if not cls then return nil end
    if cls=="Druids" then cls="Druid" end
    return cls
end

-- Spell selector recipes are authored once in Feats.lsx. Their native spell
-- UI is shared with Accord; replay validates spell ownership separately.
function M.SpellSelectors(id)
    local definition=M.Definition(id)
    if not definition or #definition.Selectors==0 or #definition.PassivesRemoved>0 then return nil end
    local groups={}
    for i,s in ipairs(definition.Selectors) do
        if s.Kind~="SelectSpells" or type(s.SpellList)~="string" or s.SpellList==""
            or type(s.Count)~="number" or s.Count<1 or s.Count>8
            or s.Count~=math.floor(s.Count) then return nil end
        local args=s.Args or {}
        local selector=tostring(args[4] or "")
        if selector=="" then return nil end
        local offset=(args[5]=="Spells" and type(args[7])=="string"
            and args[7]:match("^[0-9a-fA-F%-]+$") and #args[7]==36) and 1 or 0
        local ability=tostring(args[5+offset] or "")
        local grant=tostring(args[6+offset] or "")
        local prep=tostring(args[7+offset] or "")
        groups[#groups+1]={List=s.SpellList,Count=s.Count,Selector=selector,
            Index=i,Cantrip=selector=="Cantrips",CastingAbility=ability,
            GrantList=grant,PrepareType=prep}
    end
    return groups
end
-- Automatic AddSpells selectors are not player choices. They are kept
-- distinct so the editor never presents them as an editable spell menu.
function M.AutoSpellLists(id)
    local definition=M.Definition(id)
    if not definition or #definition.Selectors==0 then return nil end
    local lists={}
    for _,s in ipairs(definition.Selectors) do
        if s.Kind~="AddSpells" or type(s.SpellList)~="string" or s.SpellList=="" then return nil end
        lists[#lists+1]=s.SpellList
    end
    return lists
end
function M.IsKnownFixedOnly(id)
    local f=M.Definition(id)
    return f~=nil and #f.Selectors==0 and #f.PassivesRemoved==0
end
return M
