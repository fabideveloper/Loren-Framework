local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddServices(script.Parent.Services)

-- expect() rethrows a failed boot here, so it can never fail silently.
Loren.SetOnFire():expect()
