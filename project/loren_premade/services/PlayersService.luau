-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
-- Loren
local Loren = require(ReplicatedStorage.Shared.Loren)

-- Modules
local Promise = require(ReplicatedStorage.Shared.Promise)
-- Profile Service
local ProfileService = require(ReplicatedStorage.Shared.PlayersService)

local ProfileService_Template = {}

local PlayerData = ProfileService.GetProfileStore("PlayerDataV0x0000" :: any, ProfileService_Template)
local Profiles = {}

-- Heart
local PlayersService = {
	Dependencies = {},

	Client = {},

	-- List signal names here. Loren injects them automatically.
	Signals = {},

	-- Optional: Security checks for Client functions
	Middleware = {
		-- Exclude replicating certain data to client (exploits)
		-- RequestData = function(Player : Player, Path : string)
		-- 	return true
		-- end
	},
}

local function SetupPlayer(Player: Player)
	local Profile = Profiles[Player]
	if not Profile then
		Player:Kick("An error has occured")
		return
	end
end

local function PlayerAdded(Player: Player)
	local Profile_Id = "Player_" .. Player.UserId
	local Profile = (PlayerData :: any):LoadProfileAsync(Profile_Id :: any)
	if Profile ~= nil then
		Profile:AddUserId(Player.UserId)
		Profile:Reconcile()
		Profile:ListenToRelease(function()
			Profiles[Player] = nil
			Player:Kick("Profile was loaded in another Server?")
		end)
		if Player:IsDescendantOf(Players) == true then
			Profiles[Player] = Profile
			task.spawn(SetupPlayer, Player)
		else
			Profile:Release()
		end
	else
		Player:Kick("Profile could'nt load")
	end
end

local function PlayerRemoving(Player: Player, ExitReason: Enum.PlayerExitReason)
	if Profiles[Player] then
		Profiles[Player].Data = ProfileService_Template
		Profiles[Player]:Release()
	end
end

function PlayersService:OverwriteData(Player: Player, Path: string, Data: any, ReturnPromise: boolean?)
	local function PerformUpdate()
		assert(
			typeof(Player) == "Instance" and Player:IsDescendantOf(Players),
			"PlayersService.OverwriteData — invalid player"
		)

		local profile = Profiles[Player]
		if not profile then
			error(`PlayersService.OverwriteData — profile not found for {Player.Name}`)
		end

		local keys = string.split(Path, ".")
		local current = profile.Data

		for i = 1, #keys - 1 do
			local key = keys[i]
			if typeof(current[key]) ~= "table" then
				error(`PlayersService.OverwriteData — Invalid path segment: {key} is not a table`)
			end
			current = current[key]
		end

		local finalKey = keys[#keys]
		current[finalKey] = Data
		return true
	end

	if ReturnPromise then
		return Promise.new(function(resolve, reject)
			local success, result = pcall(PerformUpdate)
			if success then
				resolve(result)
			else
				reject(result)
			end
		end)
	end

	return PerformUpdate()
end

function PlayersService:RequestData(Player: Player, Path: string): any | nil
	assert(
		typeof(Player) == "Instance" and Player:IsDescendantOf(Players),
		"PlayersService.RequestData — invalid player"
	)
	assert(
		typeof(Path) == "string",
		`PlayersService.RequestData - invalid Path type, expected string, got : {typeof(Path)}`
	)

	local profile = Profiles[Player]
	if not profile then
		local start = os.time()
		repeat
			task.wait()
		until Profiles[Player] or not Player or not Player:IsDescendantOf(Players) or (os.time() - start >= 10)
		profile = Profiles[Player]
		if not profile then
			warn("PlayersService.RequestData — profile not found " .. debug.traceback())
			if Player and Player:IsDescendantOf(Players) then
				Player:Kick("Profile not found.")
			end
			return nil
		end
	end
	local Paths = string.split(Path, ".")
	local DataRequested = profile.Data
	for _, DataPath in Paths do
		if string.len(DataPath) == 0 or not DataRequested then
			warn("Invalid data path.")
			return nil
		end
		DataRequested = DataRequested[DataPath]
	end
	return DataRequested
end

function PlayersService.Client:RequestData(Player: Player, Path: string)
	return self.Server:RequestData(Player, Path)
end

function PlayersService:LorenBurn()
	for _, Player in Players:GetPlayers() do
		task.spawn(PlayerAdded, Player)
	end

	Players.PlayerAdded:Connect(PlayerAdded)
	Players.PlayerRemoving:Connect(PlayerRemoving)
end

return PlayersService
