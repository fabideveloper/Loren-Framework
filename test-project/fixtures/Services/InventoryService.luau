-- Fixture: plain 1.5.1-style Service whose dot middleware returns false, "Invalid" on bad input.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loren = require(ReplicatedStorage.Shared.Loren)

local InventoryService = {
	Dependencies = {},
	Client = {},
	Signals = {},
	Middleware = {},
	IgniteCount = 0,
	BurnCount = 0,
}

local MAX_NAME = 32
local dropped = {}

InventoryService.Middleware.Drop = function(player, item, amount)
	if typeof(item) ~= "string" or #item == 0 or #item > MAX_NAME then
		return false, "Invalid"
	end
	-- Positive-form, NaN-safe: NaN and +-inf fail these comparisons.
	if typeof(amount) ~= "number" or not (amount >= 1 and amount <= 99) or amount % 1 ~= 0 then
		return false, "Invalid"
	end
	return true
end

-- Returns the total amount of `item` this player has dropped so far.
function InventoryService.Client:Drop(player, item, amount)
	local mine = dropped[player]
	if not mine then
		mine = {}
		dropped[player] = mine
	end
	mine[item] = (mine[item] or 0) + amount
	return mine[item]
end

function InventoryService:GetDropped(player, item)
	local mine = dropped[player]
	return mine and mine[item] or 0
end

function InventoryService:LorenIgnite()
	self.IgniteCount += 1
	self.IgnitedOnServer = Loren.IsServer
	Players.PlayerRemoving:Connect(function(player)
		dropped[player] = nil
	end)
end

function InventoryService:LorenBurn()
	self.BurnCount += 1
end

return InventoryService
