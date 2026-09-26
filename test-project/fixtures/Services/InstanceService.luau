-- Fixture: plain 1.5.1-style Service that round-trips Instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local InstanceService = {
	Dependencies = {},
	Client = {},
	Signals = {},
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
}

function InstanceService.Client:NameOf(player, inst)
	return inst, inst.Name -- errors if inst arrives as nil (not replicated to the server)
end

function InstanceService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
end

function InstanceService:LorenBurn()
	self.BurnCount += 1
end

return InstanceService
