-- Fixture: plain 1.5.1-style Service with a Dependency on another Service.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local DependentService = {
	Dependencies = { "CounterService" },
	Client = {},
	Signals = {},
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
	IgniteSawDependency = false,
}

-- Returns the caller's CounterService count, read through the injected dependency.
function DependentService.Client:Total(player)
	return self.Server.Dependencies.CounterService:GetCount(player)
end

function DependentService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
	local counter = self.Dependencies.CounterService
	self.IgniteSawDependency = typeof(counter) == "table" and typeof(counter.GetCount) == "function"
end

function DependentService:LorenBurn()
	self.BurnCount += 1
end

return DependentService
