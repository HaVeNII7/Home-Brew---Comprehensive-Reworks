MCMModuleUUID = "755a8a72-407f-4f0d-9a33-274ac0f0b53d"
MCMLoaded = Ext.Mod.IsModLoaded(MCMModuleUUID)

PartialRespecEnabled = true

if MCMLoaded then
    Ext.ModEvents.BG3MCM.MCM_Setting_Saved:Subscribe(function(payload)
        if payload
            and payload.modUUID == ModuleUUID
            and payload.settingId == "enabled" then
            PartialRespecEnabled = payload.value ~= false
        end
    end)
end

Ext.Require("Shared/Helpers/_Init.lua")

PartialRespecChannel = Ext.Net.CreateChannel(ModuleUUID, "PartialRespecFlow")

Ext.Vars.RegisterUserVariable("HB_LevelUpAssignedBuild_v1", {
    Server=true, Client=true, Persistent=true, SyncToClient=true,
    WriteableOnServer=true, WriteableOnClient=false,
})
