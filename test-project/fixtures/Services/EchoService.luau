-- Fixture: plain 1.5.1-style Service. Must run unchanged on 1.5.1 and 2.0.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local EchoService = {
	Dependencies = {},
	Client = {},
	Signals = {},
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
}

function EchoService.Client:Echo(player, ...)
	return ...
end

function EchoService.Client:Size(player, s)
	return #s -- errors for non-string/table input on purpose: a handler error must reject the call
end

function EchoService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
end

function EchoService:LorenBurn()
	self.BurnCount += 1
end

return EchoService
