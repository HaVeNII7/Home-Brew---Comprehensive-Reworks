
if _G.HB_NormalGameOverServerLoaded then return end
_G.HB_NormalGameOverServerLoaded = true

local channel = "HB_NormalGameOver_v3"
local sequence = 0
Ext.Osiris.RegisterListener("PROC_HB_RequestNormalGameOver", 0, "after", function()
    sequence = sequence + 1
    local payload = tostring(Ext.Timer.MonotonicTime()) .. ":" .. tostring(sequence)
    Ext.Net.BroadcastMessage(channel, payload)
    Ext.Utils.Print("[HB Game Over] Non-Ironman party wipe: requested normal defeat panel.")
end)
Ext.Utils.Print("[HB Game Over] Server routing listener loaded.")
