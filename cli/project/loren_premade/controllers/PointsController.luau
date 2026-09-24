--[[
	PointsController (premade): a Controller using a Service.
	It needs the PointsService premade: loren inject service PointsService
]]
local PointsController = {
	Dependencies = { "PointsService" },
}

function PointsController:LorenBurn()
	local PointsService = self.Dependencies.PointsService

	PointsService.Signals.PointsChanged:Connect(function(total: number)
		print("Points:", total)
	end)

	PointsService:GetPoints()
		:andThen(function(total: number)
			print("Points:", total)
		end)
		:catch(warn)
end

return PointsController
