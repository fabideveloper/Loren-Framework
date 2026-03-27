--!strict
-- o iubesc pe lore
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Promise = require(ReplicatedStorage.LorenPackages.Promise)

local Loren = {}
Loren.IsServer = RunService:IsServer()
Loren.IsClient = RunService:IsClient()
Loren.IsOnFire = false

-- [[ Networking State ]]
local Bridge: RemoteEvent
local Handshake: RemoteFunction

local ServiceToId: { [string]: number } = {}
local IdToService: { [number]: string } = {}
local MethodToId: { [number]: { [string]: number } } = {}
local IdToMethod: { [number]: { [number]: string } } = {}
local SignalToId: { [number]: { [string]: number } } = {}
local IdToSignal: { [number]: { [number]: string } } = {}

local ClientSignals = {}
local PendingRequests = {}
local RequestId = 0

local RATE_LIMIT = 50 -- Max requests per second per player
local MAX_ARGUMENTS = 20 -- Max parameters allowed in a single call

local CallTracker: { [Player]: { Count: number, LastReset: number } } = {}

local Services: { [string]: any } = {}
local Controllers: { [string]: any } = {}

-- [[ Binary Internal Helpers ]]
local function PackHeader(reqId: number, sId: number, mId: number, pCount: number): buffer
	local b = buffer.create(5)
	buffer.writeu16(b, 0, reqId)
	buffer.writeu8(b, 2, sId)
	buffer.writeu8(b, 3, mId)
	buffer.writeu8(b, 4, pCount)
	return b
end

local function UnpackHeader(b: buffer)
	return buffer.readu16(b, 0), buffer.readu8(b, 2), buffer.readu8(b, 3), buffer.readu8(b, 4)
end

-- [[ Signal Class ]]
local Signal = {}
Signal.__index = Signal

function Signal.new(sId: number, sigId: number)
	return setmetatable({ _sId = sId, _sigId = sigId, _listeners = {} }, Signal)
end

function Signal:Fire(player: Player, ...)
	local header = PackHeader(0, self._sId, self._sigId, select("#", ...))
	Bridge:FireClient(player, header, ...)
end

function Signal:FireAll(...)
	local header = PackHeader(0, self._sId, self._sigId, select("#", ...))
	Bridge:FireAllClients(header, ...)
end

function Signal:Connect(callback: (...any) -> ())
	table.insert(self._listeners, callback)
	return {
		Disconnect = function()
			local idx = table.find(self._listeners, callback)
			if idx then
				table.remove(self._listeners, idx)
			end
		end,
	}
end

function Signal:_Execute(...)
	for _, callback in self._listeners do
		task.spawn(callback, ...)
	end
end

-- [[ Internal Core Helpers ]]
local function GetSuggestion(name: string): (string, string)
	local bestMatch, category, highestScore = "<unknown>", "<unknown>", 0
	local function score(target: string, input: string)
		local t, i = target:lower(), input:lower()
		if t == i then
			return 10
		end
		if t:find(i) then
			return 5
		end
		if t:sub(1, 3) == i:sub(1, 3) then
			return 3
		end
		return 0
	end

	local services = (Loren.IsServer and Services or ServiceToId) :: { [string]: any }
	for sName in services do
		local s = score(sName, name)
		if s > highestScore then
			highestScore, bestMatch, category = s, sName, "Service"
		end
	end
	for cName in Controllers do
		local s = score(cName, name)
		if s > highestScore then
			highestScore, bestMatch, category = s, cName, "Controller"
		end
	end
	return bestMatch, category
end

local function ThrowDependencyError(moduleName: string, depName: string)
	local suggestion, typeFound = GetSuggestion(depName)
	local message = string.format(
		"\n\t\t[LORENঌ FATAL ERROR]\n\t\t➤ Module [%s] requires '%s', but it is missing.\n\t\t➤ CHECK: Did you mean the %s: '%s'?\n",
		moduleName,
		depName,
		typeFound,
		suggestion
	)
	error(message, 0)
end

local function CreateServiceProxy(serviceName: string)
	return setmetatable({}, {
		__index = function(_, key: string): any
			local sId = ServiceToId[serviceName]
			if SignalToId[sId] and SignalToId[sId][key] then
				local sigId = SignalToId[sId][key]
				if not ClientSignals[sId] then
					ClientSignals[sId] = {}
				end
				if not ClientSignals[sId][sigId] then
					ClientSignals[sId][sigId] = Signal.new(sId, sigId)
				end
				return ClientSignals[sId][sigId]
			end

			return function(_, ...)
				local args = { ... }
				local argCount = select("#", ...)
				return Promise.new(function(resolve, reject)
					RequestId = (RequestId + 1) % 65535
					local curId, mId = RequestId, (MethodToId[sId] and MethodToId[sId][key])
					if not sId or not mId then
						return reject("(LORENঌ) Unknown Method: " .. key)
					end

					PendingRequests[curId] = { resolve = resolve, reject = reject }
					Bridge:FireServer(PackHeader(curId, sId, mId, argCount), table.unpack(args))

					task.delay(10, function()
						if PendingRequests[curId] then
							PendingRequests[curId].reject("(LORENঌ) Timeout: " .. serviceName)
							PendingRequests[curId] = nil
						end
					end)
				end)
			end
		end,
	})
end

local function GetModule(name: string, requesterName: string): any
	if Loren.IsClient then
		if Controllers[name] then
			return Controllers[name]
		end
		if ServiceToId[name] then
			return CreateServiceProxy(name)
		end
	elseif Services[name] then
		return Services[name]
	end
	return ThrowDependencyError(requesterName, name)
end

-- [[ Public API ]]

--[[
	Loads ModuleScripts from a container (Instance or Table) into the Controller registry.
	Only active on the Client.
]]
function Loren.AddControllers(container: Instance | { Instance }): boolean
	if Loren.IsOnFire or not Loren.IsClient then
		return false
	end
	local instances = (typeof(container) == "Instance" and container:GetChildren() or container) :: { Instance }
	for _, child in instances do
		if child:IsA("ModuleScript") then
			Controllers[child.Name] = require(child) :: ScriptContext
		end
	end
	return true
end

--[[
	Loads ModuleScripts from a container (Instance or Table) into the Service registry.
	Only active on the Server.
]]
function Loren.AddServices(container: Instance | { Instance }): boolean
	if Loren.IsOnFire or not Loren.IsServer then
		return false
	end
	local instances = (typeof(container) == "Instance" and container:GetChildren() or container) :: { Instance }
	for _, child in instances do
		if child:IsA("ModuleScript") then
			Services[child.Name] = require(child) :: ScriptContext
		end
	end
	return true
end

--[[
	Initializes the framework. Performs the binary handshake, resolves all dependencies, 
	and triggers the LorenIgnite and LorenBurn lifecycle phases.
]]
function Loren:SetOnFire(): any
	return Promise.new(function(resolve, reject)
		if self.IsOnFire then
			return resolve(self)
		end
		self.IsOnFire = true

		if self.IsServer then
			Bridge, Handshake = Instance.new("RemoteEvent"), Instance.new("RemoteFunction")
			Bridge.Name, Handshake.Name = "LorenBridge", "LorenHandshake"
			Bridge.Parent, Handshake.Parent = ReplicatedStorage, ReplicatedStorage

			local sIdx = 0
			for sName, service in Services do
				sIdx += 1
				if service.Client then
					service.Client.Server = service
				end
				ServiceToId[sName], IdToService[sIdx] = sIdx, sName
				MethodToId[sIdx], IdToMethod[sIdx], SignalToId[sIdx], IdToSignal[sIdx] = {}, {}, {}, {}

				if service.Client then
					local mIdx = 0
					for mName, func in service.Client do
						if typeof(func) == "function" then
							mIdx += 1
							MethodToId[sIdx][mName], IdToMethod[sIdx][mIdx] = mIdx, mName
						end
					end
				end

				if service.Signals then
					local sigIdx = 0
					for _, sigName in ipairs(service.Signals) do
						sigIdx += 1
						SignalToId[sIdx][sigName], IdToSignal[sIdx][sigIdx] = sigIdx, sigName
						service[sigName] = Signal.new(sIdx, sigIdx)
					end
				end
			end
			Handshake.OnServerInvoke = function()
				return ServiceToId, IdToService, MethodToId, IdToMethod, SignalToId, IdToSignal
			end
		else
			Bridge = ReplicatedStorage:WaitForChild("LorenBridge") :: RemoteEvent
			Handshake = ReplicatedStorage:WaitForChild("LorenHandshake") :: RemoteFunction
			local sToId, idToS, mToId, idToM, sigToId, idToSig = Handshake:InvokeServer()
			ServiceToId, IdToService, MethodToId, IdToMethod, SignalToId, IdToSignal =
				sToId, idToS, mToId, idToM, sigToId, idToSig
		end

		local registry = (self.IsServer and Services or Controllers)
		for name, module in registry do
			if typeof(module) == "table" and typeof(module.Dependencies) == "table" then
				local resolved = {}
				for _, depName in module.Dependencies do
					local ok, dep = pcall(GetModule, depName, name)
					if ok then
						resolved[depName] = dep
					else
						return reject(dep)
					end
				end
				module.Dependencies = resolved
			end
		end

		if self.IsServer then
			Bridge.OnServerEvent:Connect(function(player, header, ...)
				local now = os.clock()
				local data: { Count: number, LastReset: number } = CallTracker[player] or { Count = 0, LastReset = now }
				if now - data.LastReset >= 1 then
					data.Count = 0
					data.LastReset = now
				end
				data.Count += 1
				CallTracker[player] = data
				if data.Count > RATE_LIMIT then
					return
				end

				if typeof(header) ~= "buffer" or buffer.len(header) ~= 5 then
					return
				end
				local reqId, sId, mId, pCount = UnpackHeader(header)
				local actualCount = select("#", ...)

				if actualCount ~= pCount or actualCount > MAX_ARGUMENTS then
					warn("(LORENঌ) Blocked: Argument mismatch from " .. player.Name)
					return
				end

				local sName, mName = IdToService[sId], IdToMethod[sId][mId]
				local service = Services[sName]
				if not service or not service.Client[mName] then
					return
				end

				if service.Middleware and typeof(service.Middleware[mName]) == "function" then
					local success = service.Middleware[mName](player, ...)
					if not success then
						warn(
							string.format(
								"(LORENঌ) Blocked: %s called %s:%s (Middleware Rejected)",
								player.Name,
								sName,
								mName
							)
						)
						return Bridge:FireClient(player, reqId, nil)
					end
				end

				local result = Services[sName].Client[mName](Services[sName].Client, player, ...)
				Bridge:FireClient(player, reqId, result)
			end)

			game:GetService("Players").PlayerRemoving:Connect(function(player)
				if CallTracker[player] then
					CallTracker[player] = nil
				end
			end)
		else
			Bridge.OnClientEvent:Connect(function(headerOrId, result, ...)
				if typeof(headerOrId) == "buffer" then
					if buffer.len(headerOrId) ~= 5 then
						return
					end

					local _, sId, sigId = UnpackHeader(headerOrId)
					if ClientSignals[sId] and ClientSignals[sId][sigId] then
						ClientSignals[sId][sigId]:_Execute(result, ...)
					end
				elseif PendingRequests[headerOrId] then
					PendingRequests[headerOrId].resolve(result)
					PendingRequests[headerOrId] = nil
				end
			end)
		end

		for _, module in registry do
			if module.LorenIgnite then
				module:LorenIgnite()
			end
		end
		for _, module in registry do
			if module.LorenBurn then
				task.spawn(module.LorenBurn, module)
			end
		end

		print("(LORENঌ) Awakened on " .. (self.IsServer and "Server" or "Client"))
		resolve(self)
	end)
end

--[[
	Retrieves a required package from ReplicatedStorage.LorenPackages.
]]
function Loren.import(moduleName: string): any
	local packages = ReplicatedStorage:FindFirstChild("LorenPackages") :: Folder
	local found = packages and packages:FindFirstChild(moduleName)
	if found then
		return require(found) :: ScriptContext
	end
	error("(LORENঌ) Package '" .. moduleName .. "' not found.")
end

return Loren
