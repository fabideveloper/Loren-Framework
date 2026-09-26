local Players = game:GetService("Players")

local PointsService = {
	Dependencies = {},
	Client = {},
	Signals = { "PointsChanged" },
	Middleware = {},
}

local points: { [Player]: number } = {}

function PointsService:GetPoints(player: Player): number
	return points[player] or 0
end

function PointsService:AddPoints(player: Player, amount: number): number
	local total = (points[player] or 0) + amount
	points[player] = total
	self.Signals.PointsChanged:Fire(player, total)
	return total
end

-- Clients call PointsService:GetPoints() and get a Promise.
function PointsService.Client:GetPoints(player: Player): number
	return self.Server:GetPoints(player)
end

-- Runs before Client.GetPoints. Dot style: the first argument is the calling player.
function PointsService.Middleware.GetPoints(player: Player): boolean
	return player.Parent ~= nil
end

function PointsService:LorenIgnite()
	Players.PlayerRemoving:Connect(function(player)
		points[player] = nil
	end)
end

return PointsService
