local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

Loren.AddControllers(script.Parent.Controllers)
Loren:SetOnFire()
