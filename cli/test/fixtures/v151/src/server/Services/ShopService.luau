local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.LorenTypes)

local ShopService = {
	Dependencies = ({ "DataService" }) :: { Types.ServiceName },
	Client = {},
	Signals = { "Purchased" },
	Middleware = {
		-- explicit self in the table: 2.0 would deny every Gift call
		Gift = function(self, player, target)
			local helper = {
				check = function(self)
					return self ~= nil
				end,
			}
			return helper:check() and target ~= nil
		end,
		Sell = function(player, itemId)
			return itemId ~= nil
		end,
	},
}

function ShopService.Client:Buy(player, itemId)
	return true
end

function ShopService.Client:Sell(player, itemId)
	return true
end

function ShopService.Client:Gift(player, target)
	return true
end

function ShopService.Client:Try(player)
	return "a reserved name"
end

-- The 1.5.1 docs style: colon middleware (self is the player, player is the first argument)
function ShopService.Middleware:Buy(player, itemId)
	return type(itemId) == "string"
end

function ShopService.Middleware
	:Refund(
		player,
		orderId
	)
	return orderId ~= nil
end

--[[
function ShopService.Middleware:Commented(player)
end
]]
local note = "function ShopService.Middleware:InAString(player)"

return ShopService
