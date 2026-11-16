-- Persistent gameplay state: safe migration of legacy JWL distribution flags and
-- Scroll Transmog escrow provenance. This module is loaded before SessionLoaded
-- and registers its persistent ModVar before the game's save data is restored.
-- Never create a second, file-based or cross-campaign gameplay ledger.
local Store = {}
local KEY = 'HB_PersistentGameplay_v1'
local MOD = ModuleUUID or '486d1526-3505-4b09-9790-0f6a60f5ac0f'
local ready, snapshot, reason = false, nil, nil
local warned = {}
local function WarnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    if Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print('[HB Persistent Gameplay] ' .. message)
    end
end
-- Only ordinary JSON-compatible data can enter ModVars. No native objects,
-- partial tables, or unbounded structures are silently discarded.
local function Copy(value, seen, depth)
    local kind = type(value)
    if kind == 'string' or kind == 'boolean' then return value end
    if kind == 'number' then
        if value == value and value ~= math.huge and value ~= -math.huge then return value end
        error('non-finite-number')
    end
    if kind ~= 'table' then error('unsupported-type:' .. kind) end
    if depth > 18 then error('table-depth-limit') end
    if seen[value] then error('cyclic-table') end
    seen[value] = true
    local nextValue = {}
    local count = 0
    for key, item in pairs(value) do
        if type(key) ~= 'string' then error('non-string-key') end
        count = count + 1
        if count > 6000 then error('table-size-limit') end
        nextValue[key] = Copy(item, seen, depth + 1)
    end
    seen[value] = nil
    return nextValue
end
local function Clone(value)
    local ok, result = pcall(Copy, value, {}, 0)
    return ok and result or nil, ok and nil or tostring(result)
end
local function Equal(a, b, depth)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    if depth > 20 then return false end
    for key, value in pairs(a) do if not Equal(value, b[key], depth + 1) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function Holder()
    if not Ext.Vars or type(Ext.Vars.GetModVariables) ~= 'function' then return nil end
    local ok, vars = pcall(Ext.Vars.GetModVariables, MOD)
    return ok and vars or nil
end
local function ReadLegacy()
    local legacy = rawget(_G, 'PersistentVars')
    return type(legacy) == 'table' and legacy or nil
end
local function Initialize()
    ready, snapshot, reason = false, nil, nil
    local vars = Holder()
    if not vars then
        reason = 'mod-variable-holder-unavailable'
        WarnOnce('holder', 'Modern save storage unavailable; legacy save data retained without modification.')
        return
    end
    local ok, current = pcall(function() return vars[KEY] end)
    if not ok or (current ~= nil and type(current) ~= 'table') then
        reason = 'invalid-modern-data'
        WarnOnce('modern', 'Invalid current save ledger; retaining original legacy data. Do not overwrite this save.')
        return
    end
    local modern, modernError = Clone(current or {})
    if not modern then
        reason = 'unreadable-modern-data:' .. tostring(modernError)
        WarnOnce('modern-data', 'Current save ledger could not be verified; no migration performed.')
        return
    end
    local legacy = ReadLegacy()
    local converted, errorText = Clone(legacy or {})
    if not converted then
        reason = 'unreadable-legacy-data:' .. tostring(errorText)
        WarnOnce('legacy', 'Legacy save ledger cannot be migrated safely; keeping the original intact.')
        return
    end
    -- Preserve *all* legacy fields, including old distribution flags and
    -- escrow records, not just the fields currently known to this version.
    for key, value in pairs(converted) do
        if modern[key] == nil then
            modern[key] = value
        elseif not Equal(modern[key], value, 0) then
            reason = 'conflicting-ledger:' .. tostring(key)
            WarnOnce('conflict', 'Conflicting modern/legacy save records; migration refused, save unchanged.')
            return
        end
    end
    -- Readback matters: do not throw away legacy data if the new ModVar cannot
    -- be written, or is silently rejected by this SE runtime.
    local written = pcall(function() vars[KEY] = modern end)
    local verified, result = pcall(function() return vars[KEY] end)
    if not written or not verified or type(result) ~= 'table' or not Equal(result, modern, 0) then
        reason = 'modern-readback-failed'
        WarnOnce('readback', 'Modern save ledger write/readback failed; original legacy data preserved.')
        return
    end
    snapshot, ready = modern, true
    -- The old table is now represented in a registered persistent ModVar.
    -- Clear it for *this* save session so SE no longer writes deprecated data
    -- to new saves. Older saves remain readable on their next load/migration.
    PersistentVars = nil
end
if Ext.Vars and type(Ext.Vars.RegisterModVariable) == 'function' then
    local ok, err = pcall(Ext.Vars.RegisterModVariable, MOD, KEY, {
        Server=true, Client=false, Persistent=true,
        WriteableOnServer=true, SyncToClient=false,
    })
    if not ok then WarnOnce('register', 'Unable to register modern gameplay storage: ' .. tostring(err)) end
else
    WarnOnce('register-missing', 'Modern ModVar API missing; using legacy save storage for compatibility.')
end
if Ext.Events and Ext.Events.SessionLoaded then
    Ext.Events.SessionLoaded:Subscribe(Initialize)
end
function Store.Read()
    if ready then return Clone(snapshot) end
    -- If migration cannot complete, never pretend a new empty save exists.
    -- Keep the previous save's legacy data intact for critical transmog
    -- rollback and distribution duplicate protection.
    if reason and (reason:find('invalid-modern-data', 1, true)
        or reason:find('unreadable-modern-data', 1, true)
        or reason:find('conflicting-ledger', 1, true)
        or reason:find('unreadable-legacy-data', 1, true)
        or reason:find('modern-readback-failed', 1, true)) then
        return nil
    end
    local old = ReadLegacy()
    return old and Clone(old) or nil
end
function Store.Commit(value)
    local data, copyError = Clone(value)
    if not data then return false, 'invalid-ledger:' .. tostring(copyError) end
    if not ready then
        if reason and (reason:find('invalid-modern-data', 1, true)
            or reason:find('unreadable-modern-data', 1, true)
            or reason:find('conflicting-ledger', 1, true)
            or reason:find('unreadable-legacy-data', 1, true)
            or reason:find('modern-readback-failed', 1, true)) then
            return false, reason
        end
        if ReadLegacy() ~= nil then
            PersistentVars = data
            return true, 'legacy-fallback'
        end
        return false, reason or 'save-ledger-not-ready'
    end
    local vars = Holder()
    if not vars then return false, 'mod-variable-holder-lost' end
    local ok = pcall(function() vars[KEY] = data end)
    local verified, got = pcall(function() return vars[KEY] end)
    if not ok or not verified or type(got) ~= 'table' or not Equal(got, data, 0) then
        return false, 'modern-ledger-readback-failed'
    end
    snapshot = data
    return true
end
function Store.TransmogRecords()
    local state = Store.Read()
    return type(state) == 'table' and state.HBScrollTransmogRecords or nil
end
function Store.AddTransmog(id, record)
    local state = Store.Read()
    if type(state) ~= 'table' then return false, 'save-ledger-unavailable' end
    state.HBScrollTransmogRecords = state.HBScrollTransmogRecords or {}
    if type(state.HBScrollTransmogRecords) ~= 'table' then return false, 'invalid-escrow-ledger' end
    if state.HBScrollTransmogRecords[id] ~= nil then return false, 'duplicate-transmog-record' end
    state.HBScrollTransmogRecords[id] = record
    return Store.Commit(state)
end
function Store.Ready() return ready end
return Store
