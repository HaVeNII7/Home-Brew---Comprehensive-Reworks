-- HomeBrew-owned preset files. Deliberately independent of the CPF registry.
local M = {}
local function cleanName(name)
    if type(name) ~= 'string' then error('Preset name must be text.') end
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    if #name == 0 or #name > 64 or name:find('[%c/\\]') then
        error('Preset name must be 1-64 characters and cannot contain slashes or control characters.')
    end
    return name
end
M.CleanName=cleanName

local function safeFile(name)
    if type(name) ~= 'string' then return nil end
    if name:find('[/\\]') then return nil end
    if not name or not name:match('^[%w_%- %.]+%.json$') or name:find('..',1,true)
        or #name>150 then return nil end
    return name
end

local function full(dir,file) return dir..'/'..file end
local function sorted(result)
    table.sort(result,function(a,b) return a:lower()<b:lower() end)
    return result
end

local lastDiscovery='No preset discovery attempted.'
function M.LastDiscoveryReport() return lastDiscovery end
function M.Discover(dir)
    if not Ext.IO or type(Ext.IO.FindFiles)~='function' then
        lastDiscovery='Ext.IO.FindFiles unavailable (Script Extender v33+ required).'
        return nil,'Automatic preset file discovery requires Script Extender v33 or newer.'
    end
    local accepted,seen={},{}
    local probes,validResults,rawEntries,rejected={},0,0,0
    local root=dir:gsub('\\','/'):lower():gsub('/+$','')
    local function consider(candidate)
        if type(candidate)~='string' then return end
        candidate=candidate:gsub('\\','/')
        -- Reject traversal before extracting the filename. A full absolute
        -- path is fine as long as it ends inside the requested HomeBrew folder.
        if candidate:find('/../',1,true) or candidate:find('/./',1,true)
            or candidate:match('^%.%.?/') then rejected=rejected+1;return end
        local value=candidate:lower()
        local pos=value:find(root..'/',1,true)
        local suffix=pos and candidate:sub(pos+#root+1) or candidate
        -- The SE result can include the whole user-profile path or only a
        -- basename; it must never authorize files from another directory.
        if candidate:find('/') and not pos then rejected=rejected+1;return end
        if suffix:find('/') then rejected=rejected+1;return end
        local file=safeFile(suffix)
        if not file then rejected=rejected+1;return end
        if seen[file:lower()] then return end
        -- Validate against the same relative IO root used by SaveFile. The
        -- enumeration alone must never make an unreadable/packed entry visible.
        local ok,body=pcall(Ext.IO.LoadFile,full(dir,file))
        if not ok or type(body)~='string' or body=='' then rejected=rejected+1;return end
        seen[file:lower()]=true
        accepted[#accepted+1]=file
    end
    local function walk(values,depth)
        if depth>3 then return end
        local kind=type(values)
        if kind=='string' then rawEntries=rawEntries+1;consider(values);return end
        if kind~='table' and kind~='userdata' then return end
        -- Handles std::vector proxies as well as Lua tables and the
        -- occasional structured result {Files={...}} or {Path=...}.
        local ok=pcall(function()
            for k,v in pairs(values) do
                if type(v)=='string' then rawEntries=rawEntries+1;consider(v)
                elseif type(k)=='string' and v==true then rawEntries=rawEntries+1;consider(k)
                elseif type(v)=='table' or type(v)=='userdata' then walk(v,depth+1) end
            end
        end)
        if not ok then
            pcall(function()
                local n=#values
                for i=1,math.min(n,1025) do walk(values[i],depth+1) end
            end)
        end
        if kind=='userdata' or kind=='table' then
            for _,field in ipairs({'Path','Filename','FileName','Name'}) do
                local good,v=pcall(function() return values[field] end)
                if good and type(v)=='string' then rawEntries=rawEntries+1;consider(v) end
            end
        end
    end
    -- SE's SaveFile/LoadFile prepend "/Script Extender" to the user-profile
    -- root. FindFiles does NOT prepend that directory: it searches the path
    -- passed to it relative to the requested root. Thus enumerating `dir`
    -- directly sees a different directory than the one we wrote to.
    -- The "user" context is the supported user-profile root (not
    -- "UserProfile"). FindFiles returns names relative to its search path.
    local searchPath='Script Extender/'..dir
    local calls={
        {'se-user-folder',function()
            return Ext.IO.FindFiles(searchPath,'*.json','user',false,false)
        end},
    }
    for _,call in ipairs(calls) do
        local ok,result=pcall(call[2])
        if ok and (type(result)=='table' or type(result)=='userdata' or type(result)=='string') then
            validResults=validResults+1
            local before=#accepted
            walk(result,0)
            probes[#probes+1]=call[1]..':'..type(result)..'+'..(#accepted-before)
        else
            -- Only record the error kind, not a user's absolute profile path.
            probes[#probes+1]=call[1]..':'..(ok and tostring(type(result)) or 'error')
        end
    end
    if #accepted>1024 then return nil,'Too many preset files in '..dir end
    lastDiscovery='folder='..dir..' calls='..table.concat(probes,',')
       ..' raw='..rawEntries..' accepted='..#accepted..' rejected='..rejected
    if validResults==0 then return nil,'Script Extender could not enumerate '..dir end
    return sorted(accepted)
end
function M.Read(dir,file)
    file=safeFile(file)
    if not file then return nil,'Unsafe preset filename.' end
    local path=full(dir,file)
    local body=Ext.IO.LoadFile(path)
    if type(body)~='string' or body=='' then return nil,'Cannot read preset '..file end
    if #body>2*1024*1024 then return nil,'Preset exceeds size limit.' end
    local ok,obj=pcall(Ext.Json.Parse,body)
    if not ok or type(obj)~='table' then return nil,'Malformed JSON preset '..file end
    return obj,nil,body
end
function M.Write(dir,file,value)
    file=safeFile(file)
    if not file then return false,'Unsafe preset filename.' end
    local ok,encoded=pcall(Ext.Json.Stringify,value,{Beautify=true,StringifyInternalTypes=false})
    if not ok or type(encoded)~='string' or #encoded>2*1024*1024 then
        return false,'Preset cannot be safely serialized.'
    end
    local path=full(dir,file)
    if Ext.IO.SaveFile(path,encoded)==false then return false,'Could not write '..path end
    if Ext.IO.LoadFile(path)~=encoded then return false,'Could not verify '..path end
    return true
end
function M.FileFor(name,tag)
    cleanName(name)
    -- Files are stable for the same display name; collisions are detected
    -- by the caller before saving and existing filenames are reused.
    local slug=name:gsub('[^%w%-_ ]','_'):gsub('%s+','_'):sub(1,70)
    if slug=='' then slug='Preset' end
    return (tag or 'preset')..'_'..slug..'.json'
end
function M.Tombstone(dir,file)
    -- SE exposes no reliable delete-file API. Tombstones are portable JSON
    -- and can be removed manually; they never show in the load list.
    local obj,err=M.Read(dir,file)
    if not obj then return false,err end
    obj.Deleted=true
    return M.Write(dir,file,obj)
end
return M
