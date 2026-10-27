PRPrint(0, "Partial Respec (client) loaded")
Ext.Require("Client/PartialRespecUI.lua")
Ext.Require("Client/NativeHistoricalPreview.lua")
Ext.Require("Client/SpellSchoolFilter.lua")
Ext.Require("Client/AbilityMinimum.lua")
Ext.Require("Client/DifficultyOrder.lua")
Ext.Require("Client/NewGameSingleSave.lua")
Ext.Require("Client/NormalGameOver.lua")
Ext.Require("Client/VisualPresets.lua")
Ext.Require("Client/SaveOverwriteGuard.lua")

-- Save/load deep diagnostic probe intentionally disabled in production.
-- Ext.Require("Client/SaveLoadDiagnostics.lua")

-- Temporary, read-only Guardian transition diagnostics. Remove after investigation.
-- Ext.Require("Client/GuardianTransitionProbe.lua")
