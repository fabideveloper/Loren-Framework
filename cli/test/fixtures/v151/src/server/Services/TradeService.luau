local TradeService = {
	Client = {},
	Middleware = {},
	Spec = { MaxTrades = 5 },
}

TradeService.Client.Offer = function(self, player, offer)
	return true
end

function TradeService.Client:Accept(player, id)
	return true
end

function TradeService.Middleware:Offer(player, offer)
	return self:IsAllowed(player)
end

TradeService.Middleware.Accept = function(self, player, id)
	return id ~= nil
end

function TradeService:IsAllowed(player)
	return player ~= nil
end

return TradeService
