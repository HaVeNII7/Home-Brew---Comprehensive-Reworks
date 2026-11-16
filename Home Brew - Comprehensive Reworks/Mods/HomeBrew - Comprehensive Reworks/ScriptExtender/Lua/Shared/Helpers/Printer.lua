PRPrinter = VolitionCabinetPrinter:New {
    Prefix = "Partial Respec",
    ApplyColor = true,
    DebugLevel = 0,
}

if MCMLoaded then
    Ext.ModEvents.BG3MCM.MCM_Setting_Saved:Subscribe(function(payload)
        if not payload or payload.modUUID ~= ModuleUUID then return end

        if payload.settingId == "debug_level" then
            PRPrinter.DebugLevel = payload.value
        end
    end)
end

---@param debugLevel integer
---@param ... unknown
function PRPrint(debugLevel, ...)
    if _G.HB_DebugConsole ~= true then return end
    PRPrinter:SetFontColor(0, 255, 255)
    PRPrinter:Print(debugLevel, ...)
end

---@param debugLevel integer
---@param ... unknown
function PRWarn(debugLevel, ...)
    PRPrinter:SetFontColor(255, 100, 50)
    PRPrinter:PrintWarning(debugLevel, ...)
end
