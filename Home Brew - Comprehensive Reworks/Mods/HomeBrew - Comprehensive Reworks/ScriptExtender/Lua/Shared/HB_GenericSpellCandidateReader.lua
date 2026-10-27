-- Read-only spell candidates for newly added feat-owned SelectSpells groups.
-- The client and authoritative server use the SAME catalog and rank checks.
-- Does not touch Accord, normal historical SpellSelector rows, or automatic AddSpells.
local M={}
local pinned=Ext.Require("Shared/HB_GenericSpellListFallback.lua") or {}
-- HB uses the full Accord of the Arcane cantrip pool for this additional
-- Yokebreaker selector. Keep the original SpellList UUID in the feat's
-- recorded selection; only its candidate catalog is shared with Accord.
local SHARED_ACCORD_CANTRIP_CATALOG={
    ["2bb484e2-1d3a-4177-84b4-2894f25ab2b1"]="ffad33d2-e725-4655-ba80-0bc91e8002b3",
}
local cache={}
local function SpellRank(id)
    if not (Ext.Stats and Ext.Stats.Get) then return nil end
    local ok,stat=pcall(Ext.Stats.Get,id)
    if not ok or not stat then return nil end
    local read,raw=pcall(function() return stat.Level end)
    local level=read and tonumber(raw) or nil
    if level==nil then
        read,raw=pcall(function() return stat.SpellLevel end)
        level=read and tonumber(raw) or nil
    end
    if level and level>=0 and level<=9 and level==math.floor(level) then return level end
    return nil
end
local function ReadInstalled(listId)
    local ids,seen={},{}
    local function Add(value)
        if type(value)~="string" then return end
        for id in value:gmatch("[^;,%s]+") do
            -- Reject malformed collection labels rather than inventing spell IDs.
            if id:match("^[%w]+_[%w_]+$") and not seen[id] then
                seen[id]=true;ids[#ids+1]=id
            end
        end
    end
    local function Parse(value)
        if type(value)=="string" then Add(value);return end
        if value==nil then return end
        for _,field in ipairs({"SpellId","Spell","StatsId","Id","Name","Value"}) do
            local ok,entry=pcall(function() return value[field] end)
            if ok and type(entry)=="string" then Add(entry);return end
        end
    end
    if not (Ext.StaticData and Ext.StaticData.Get) then return ids end
    local ok,list=pcall(Ext.StaticData.Get,listId,"SpellList")
    if not ok or not list then return ids end
    local got,raw=pcall(function() return list.Spells end)
    if not got or raw==nil then return ids end
    if type(raw)=="string" then
        Parse(raw)
    else
        local added={}
        local function ParseIndexed(index)
            if added[index] then return end
            local ok,item=pcall(function() return raw[index] end)
            if ok and item~=nil then added[index]=true;Parse(item) end
        end
        -- Read native Count/Size/Length independently, since Larian and SE
        -- proxies don't all expose the same collection accessor.
        local length=nil
        for _,field in ipairs({"Count","Size","Length"}) do
            local ok,n=pcall(function() return raw[field] end)
            n=ok and tonumber(n) or nil
            if n and n>=0 and n<=2048 and n==math.floor(n) then
                length=n;break
            end
        end
        if length then
            for i=0,length-1 do ParseIndexed(i) end
            -- A genuine Lua list may be 1-based; deduplicate by stat ID.
            if type(raw)=="table" then
                for i=1,length do ParseIndexed(i) end
            end
        else
            for i=0,2047 do
                local ok,item=pcall(function() return raw[i] end)
                if not ok or item==nil then
                    if i>0 then break end
                else ParseIndexed(i) end
            end
            for i=1,2048 do
                local ok,item=pcall(function() return raw[i] end)
                if not ok or item==nil then break end
                ParseIndexed(i)
            end
        end
        pcall(function()
            local n=0
            for k,item in pairs(raw) do
                if n>=2048 then break end
                if type(k)=="number" then Parse(item);n=n+1 end
            end
        end)
        if type(raw)=="table" and #ids==0 then Parse(raw) end
    end
    return ids
end
local function Filter(ids,cantrip)
    local result,seen={},{}
    for _,id in ipairs(ids) do
        local rank=SpellRank(id)
        if rank~=nil and ((cantrip and rank==0) or (not cantrip and rank>0))
            and not seen[id] then
            seen[id]=true;result[#result+1]=id
        end
    end
    table.sort(result)
    return result
end
function M.Ids(listId,cantrip)
    listId=tostring(listId or "")
    cantrip=cantrip==true
    local key=listId.."|"..tostring(cantrip)
    if cache[key] then return cache[key].Ids,cache[key].Info end
    local liveRaw=ReadInstalled(listId)
    local live=Filter(liveRaw,cantrip)
    local catalogId=(cantrip and SHARED_ACCORD_CANTRIP_CATALOG[listId]) or listId
    local pinnedRaw=pinned[catalogId] or {}
    local fallback=Filter(pinnedRaw,cantrip)
    local source="installed"
    local chosen=live
    -- Some SE C++ List proxies yield only one or two entries via []/ipairs.
    -- For source-pinned *exact GUIDs* only, recover the full authored catalog
    -- when the recovered installed entries are a small SUBSET of that catalog.
    -- A genuinely modded/replaced list with different IDs takes precedence.
    if #fallback>0 and #live<4 and #fallback>8 then
        local expected={}
        for _,id in ipairs(fallback) do expected[id]=true end
        local subset=true
        for _,id in ipairs(live) do
            if not expected[id] then subset=false;break end
        end
        if subset then chosen=fallback;source="source_pinned_partial_or_missing" end
    elseif #live==0 and #fallback>0 then
        chosen=fallback;source="source_pinned_missing"
    end
    -- Do not cache empty lists: the underlying static database may become
    -- available after initial loading. Successful lists are immutable per session.
    local info={Source=source,LiveRaw=#liveRaw,LiveEligible=#live,
        PinnedRaw=#pinnedRaw,PinnedEligible=#fallback,Eligible=#chosen,
        CandidateCatalog=(catalogId~=listId and catalogId or listId)}
    if #chosen>0 then cache[key]={Ids=chosen,Info=info} end
    return chosen,info
end
function M.Contains(listId,cantrip,id)
    id=tostring(id or "")
    for _,known in ipairs(M.Ids(listId,cantrip)) do
        if known==id then return true end
    end
    return false
end
return M
