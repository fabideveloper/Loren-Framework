local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local TestController = {
	Dependencies = {
		"EchoService",
		"CounterService",
		"InventoryService",
		"InstanceService",
		"BroadcastService",
		"DependentService",
	},
	IgniteCount = 0,
	BurnCount = 0,
}

function TestController:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnClient = Loren.IsClient
	self.IgniteSawProxy = self.Dependencies.EchoService ~= nil
end

function TestController:LorenBurn()
	self.BurnCount += 1
end

return TestController
