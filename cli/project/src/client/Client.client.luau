local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddControllers(script.Parent.Controllers)

-- expect() rethrows a failed boot here, so it can never fail silently.
Loren.SetOnFire():expect()
