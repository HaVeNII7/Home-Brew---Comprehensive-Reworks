local DEBUG = false
local function log(m) if DEBUG then Ext.Utils.Print("[ReturnFix] "..m) end end

local V = {
  ACTIVE        = "RET_ACTIVE",        -- 1 after snapshot until OnThrown clears
  MAIN_TEMPL    = "RET_MAIN_TEMPL",    -- template in main slot at snapshot
  OFF_TEMPL     = "RET_OFF_TEMPL",     -- template in off slot  at snapshot
  HAD_OFFHAND   = "RET_HAD_OFFHAND",   -- 1 if any off-hand item existed
}
local NULL_UUID = "00000000-0000-0000-0000-000000000000"

-- quick “returning” test for re-equip step
local function IsReturning(it)
  if not it then return false end
  return  Osi.HasActiveStatus(it,"MAG_THROWING_RETURN_TO_OWNER")		==1
      or Osi.HasActiveStatus(it,"WILD_MAGIC_BARBARIAN_WEAPON_INFUSION") ==1
      or Osi.HasActiveStatus(it,"TAVERN_BRAWLER")						==1
      or Osi.HasActiveStatus(it,"MAG_THE_THORNS_WEAPON_BOND")   ==1
      or Osi.HasActiveStatus(it,"ThrownReturn")                 ==1
      or Osi.HasActiveStatus(it,"INFUSION_RETURNING_WEAPON")    ==1
      or Osi.HasActiveStatus(it,"RR_THROWING_RETURN_TO_OWNER")  ==1
end

local function ClearVars(c)
  for _,k in pairs{V.ACTIVE,V.HAD_OFFHAND} do
    Osi.SetVarInteger(c,k,0) end
  for _,k in pairs{V.MAIN_TEMPL,V.OFF_TEMPL} do
    Osi.SetVarUUID(c,k,NULL_UUID) end
  log("Cleared vars on "..c)
end

-- ── 0.  Clear on manual gear changes (skip while throw active) ────────
for _,ev in ipairs{"Equipped","Unequipped"} do
  Ext.Osiris.RegisterListener(ev,2,"after",function(_,c)
    if Osi.GetVarInteger(c,V.ACTIVE)==0 then ClearVars(c)
    else log(ev.." during throw → skip") end
  end)
end

-- ── 1.  Snapshot *template IDs* of both hand slots at UsingSpell ──────
Ext.Osiris.RegisterListener("UsingSpell",5,"after",
function(c,s,st)
  if (s=="Throw_Throw" or s=="Throw_FrenziedThrow") and st=="throw" then
    ClearVars(c)

    local main = Osi.GetEquippedItem(c,"Melee Main Weapon")
    local off  = Osi.GetEquippedItem(c,"Melee Offhand Weapon")
    local mainTempl = main and Osi.GetTemplate(main) or NULL_UUID
    local offTempl  = off  and Osi.GetTemplate(off)  or NULL_UUID

    Osi.SetVarUUID(c,V.MAIN_TEMPL, mainTempl)
    Osi.SetVarUUID(c,V.OFF_TEMPL,  offTempl)
    Osi.SetVarInteger(c,V.HAD_OFFHAND, off and 1 or 0)
    Osi.SetVarInteger(c,V.ACTIVE,1)

    log(("Snapshot  mainTempl:%s  offTempl:%s"):format(mainTempl,offTempl))
  end
end)

-- ── 2.  OnThrown: decide by template match ────────────────────────────
Ext.Osiris.RegisterListener("OnThrown", 7, "after",
function(item, itemTemplate, char)

    -- 1️⃣  Bail out immediately if the landed item is NOT a returning weapon
    if not IsReturning(item) then
        log("Not a returning weapon → leave it where it landed")
        ClearVars(char)            -- tidy up any throw-tracking flags
        return
    end

    -- 2️⃣  Genuine returning weapon → continue 
    Osi.ToInventory(item, char, 1, 1, 0)

  local mainTempl = Osi.GetVarUUID(char,V.MAIN_TEMPL)
  local offTempl  = Osi.GetVarUUID(char,V.OFF_TEMPL)
  local hadOff    = Osi.GetVarInteger(char,V.HAD_OFFHAND)

  local fromMain = (itemTemplate == mainTempl)
  local fromOff  = (itemTemplate == offTempl)

  if not (fromMain or fromOff) then
    log("Template mismatch → backpack throw, keep in bag")
    ClearVars(char)
    return
  end

  if not IsReturning(item) then                -- safety: weapon lost status
    log("Matched hand slot but not returning → keep in bag")
    ClearVars(char)
    return
  end

  log(("Hand re-equip  main?%s off?%s"):format(fromMain,fromOff))

  local slid = Osi.GetEquippedItem(char,"Melee Main Weapon")
  if fromMain and slid then Osi.Unequip(char,slid) end

  Osi.Equip(char,item,1,1,0)

  if fromMain and hadOff==1 and slid
     and Osi.IsInInventoryOf(slid,char)==1 then
    Osi.Equip(char,slid,1,1,0)
  end

  ClearVars(char)
end)
