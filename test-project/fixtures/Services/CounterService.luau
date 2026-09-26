-- Fixture: plain 1.5.1-style Service with a Signal and DOT-style middleware.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local CounterService = {
	Dependencies = {},
	Client = {},
	Signals = { "Changed" },
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
}

local counts = {}

-- Dot style (player, ...): the calling convention 1.5.1 actually uses. NaN-safe positive-form check.
CounterService.Middleware.Increment = function(player, n)
	return typeof(n) == "number" and n == n and n >= 1 and n <= 100
end

function CounterService:GetCount(player)
	return counts[player] or 0
end

function CounterService.Client:Increment(player, n)
	local value = (counts[player] or 0) + n
	counts[player] = value
	self.Server.Signals.Changed:Fire(player, value)
	return value
end

function CounterService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
	Players.PlayerRemoving:Connect(function(player)
		counts[player] = nil
	end)
end

function CounterService:LorenBurn()
	self.BurnCount += 1
end

return CounterService
