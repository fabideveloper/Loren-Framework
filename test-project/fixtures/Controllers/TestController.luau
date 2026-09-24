-- Fixture: plain 1.5.1-style Controller. Its resolved Dependencies are the service proxies
-- the Studio client harness hands to specs and bots.
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
