local difficultyLoaded, difficultyError = pcall(Ext.Require, "Client/DifficultyOrder.lua")
if not difficultyLoaded then
    Ext.Utils.Print("[HB Difficulty Browser] " .. tostring(difficultyError))
    if Ext.IO and Ext.IO.SaveFile then
        pcall(Ext.IO.SaveFile, "HomeBrew/Diagnostics/HB_DifficultyMenu_Diagnostics.txt", "HomeBrew difficulty menu v20: bootstrap error\n" .. tostring(difficultyError))
    end
end

local function OnSessionLoaded()
	-- Change "Musical Instrument" to "Trinket" on tooltips for BetterTooltips users.
	Ext.Loca.UpdateTranslatedString("h70a42b6bg2d66g48e1ga2d9g25afceabd190", "Trinket")
end

Ext.Events.SessionLoaded:Subscribe(OnSessionLoaded)

Ext.Require("Shared/_Init.lua")
Ext.Require("Client/_Init.lua")
