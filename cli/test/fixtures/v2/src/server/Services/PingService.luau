local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local PingService = {
	Client = {},
	ClientEvents = { "Pinged" },
	Spec = {
		Ping = Loren.Method({ Loren.T.u8 }),
	},
	Middleware = {
		Pinged = function(player, n)
			return n ~= nil
		end,
	},
}

function PingService.Client:Ping(player, n)
	return n
end

function PingService.Middleware.Ping(player, n)
	return type(n) == "number"
end

return PingService
