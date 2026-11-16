
if _G.HB_NormalGameOverServerLoaded then return end
_G.HB_NormalGameOverServerLoaded = true

local channel = Ext.Net.CreateChannel("486d1526-3505-4b09-9790-0f6a60f5ac0f", "HB_NormalGameOver_v4")
local sequence = 0
Ext.Osiris.RegisterListener("PROC_HB_RequestNormalGameOver", 0, "after", function()
    sequence = sequence + 1
    local payload = tostring(Ext.Timer.MonotonicTime()) .. ":" .. tostring(sequence)
    channel:Broadcast({Payload=payload})
    if _G.HB_DebugConsole == true then
        Ext.Utils.Print("[HB Game Over] Non-Ironman party wipe: requested normal defeat panel.")
    end
end)
if _G.HB_DebugConsole == true then Ext.Utils.Print("[HB Game Over] Server routing listener loaded.") end
