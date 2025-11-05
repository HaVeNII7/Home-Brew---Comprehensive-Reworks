Ext.Osiris.RegisterListener("SavegameLoaded", 0, "after", function()
    --Set Alfira as a trader and add new trade table
    Osi.SetCanTrade("4a405fba-3000-4c63-97e5-a8001ebb883c", 1)
    Osi.SetCustomTradeTreasure("4a405fba-3000-4c63-97e5-a8001ebb883c", "JWL_AlfiraTrade")
end)
