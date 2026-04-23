--!strict

--[[
MIT License

Copyright (c) 2026 Fabian

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Promise = require(ReplicatedStorage.LorenPackages.Promise)

local Loren = {}
Loren.IsServer = RunService:IsServer()
Loren.IsClient = RunService:IsClient()
Loren.IsOnFire = false

local Bridge: RemoteEvent
local Handshake: RemoteFunction

local ServiceToId, IdToService = {}, {}
local MethodToId, IdToMethod = {}, {}
local SignalToId, IdToSignal = {}, {}

local ClientSignals, PendingRequests = {}, {}
local RequestId = 0

local RATE_LIMIT = 50
local MAX_ARGUMENTS = 20
local CallTracker: { [Player]: { Count: number, LastReset: number } } = {}

local Services: { [string]: any } = {}
local Controllers: { [string]: any } = {}

-- [[ Internal Helpers ]]

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

function Signal:Once(callback: (...any) -> ())
	local connection

	connection = self:Connect(function(...)
		if connection then
			connection.Disconnect()
		end
		callback(...)
	end)

	return connection
end

function Signal:_Execute(...)
	for _, callback: any in table.clone(self._listeners) do
		task.spawn(callback, ...)
	end
end

-- [[ Dependency Engine ]]
local function GetSuggestion(name: string): (string, string)
	local bestMatch, category, highestScore = "<unknown>", "<unknown>", 0
	local function score(t: string, i: string)
		t, i = t:lower(), i:lower()
		if t == i then
			return 10
		end
		if t:find(i) then
			return 5
		end
		return 0
	end

	local registry: { [string]: any } = (Loren.IsServer and Services or ServiceToId)
	for n in registry do
		local s = score(n, name)
		if s > highestScore then
			highestScore, bestMatch, category = s, n, "Service"
		end
	end
	for n in Controllers do
		local s = score(n, name)
		if s > highestScore then
			highestScore, bestMatch, category = s, n, "Controller"
		end
	end
	return bestMatch, category
end

local function CreateServiceProxy(serviceName: string)
	local sId = ServiceToId[serviceName]

	local signalsProxy = setmetatable({}, {
		__index = function(_, sigKey: string): any
			if SignalToId[sId] and SignalToId[sId][sigKey] then
				local sigId = SignalToId[sId][sigKey]
				if not ClientSignals[sId] then
					ClientSignals[sId] = {}
				end
				if not ClientSignals[sId][sigId] then
					ClientSignals[sId][sigId] = Signal.new(sId, sigId)
				end
				return ClientSignals[sId][sigId]
			end
			return nil
		end,
	})

	return setmetatable({}, {
		__index = function(_, key: string): any
			if key == "Signals" then
				return signalsProxy
			end

			return function(_, ...)
				local args, argCount = { ... }, select("#", ...)
				return Promise.new(function(resolve, reject, onCancel)
					RequestId = (RequestId % 65535) + 1
					local curId, mId = RequestId, (MethodToId[sId] and MethodToId[sId][key])
					if not sId or not mId then
						return reject("(LORENঌ) Missing Method: " .. key)
					end

					local header = PackHeader(curId, sId, mId, argCount)
					local timeoutThread = task.delay(10, function()
						local request = PendingRequests[curId]
						if request then
							PendingRequests[curId] = nil

							request.reject("(LORENঌ) Timeout")
						end
					end)
					PendingRequests[curId] = {
						resolve = resolve,
						reject = reject,
						timeout = timeoutThread,
					}
					onCancel(function()
						if PendingRequests[curId] then
							task.cancel(PendingRequests[curId].timeout)
							PendingRequests[curId] = nil
						end
					end)
					print("Client Outbox:", curId)
					Bridge:FireServer(header, table.unpack(args))
				end)
			end
		end,
	})
end

local function GetModule(name: string, requester: string)
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
	local sug, cat = GetSuggestion(name)
	error(
		string.format("\n[LORENঌ FATAL]\nModule [%s] needs '%s'.\nDid you mean %s: '%s'?", requester, name, cat, sug),
		0
	)
end

-- [[ Public API ]]

--[[
	@ Client
	Adds a list of ModuleScripts (or an instance containing module scripts as children) to the controllers registry
]]
function Loren.AddControllers(container: Instance | { Instance })
	if Loren.IsOnFire or not Loren.IsClient then
		return
	end
	for _, child in (typeof(container) == "Instance" and container:GetChildren() or container) :: { Instance } do
		if child:IsA("ModuleScript") then
			Controllers[child.Name] = require(child) :: any
		end
	end
end
--[[
	@ Server
	Adds a list of ModuleScripts (or an instance containing module scripts as children) to the services registry
]]
function Loren.AddServices(container: Instance | { Instance })
	if Loren.IsOnFire or not Loren.IsServer then
		return
	end
	for _, child in (typeof(container) == "Instance" and container:GetChildren() or container) :: { Instance } do
		if child:IsA("ModuleScript") then
			Services[child.Name] = require(child) :: any
		end
	end
end

--[[ 
	@ Server
	@ Client
	Runs LorenIgnite (Init) and LorenBurn (Start) on all Services/Controllers added to the registry
	Boots the Bridges and Handshakes between modules
]]
function Loren:SetOnFire()
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
			for sName, s in Services do
				sIdx += 1
				if s.Client then
					s.Client.Server = s
				end
				ServiceToId[sName], IdToService[sIdx] = sIdx, sName
				MethodToId[sIdx], IdToMethod[sIdx], SignalToId[sIdx], IdToSignal[sIdx] = {}, {}, {}, {}

				if s.Client then
					local mIdx = 0
					for mName, f in s.Client do
						if typeof(f) == "function" then
							mIdx += 1
							MethodToId[sIdx][mName], IdToMethod[sIdx][mIdx] = mIdx, mName
						end
					end
				end

				if s.Signals then
					local signalObjects = {}
					for sigIdx, sigName in ipairs(s.Signals) do
						SignalToId[sIdx][sigName], IdToSignal[sIdx][sigIdx] = sigIdx, sigName
						signalObjects[sigName] = Signal.new(sIdx, sigIdx)
					end
					s.Signals = signalObjects
				end
			end
			Handshake.OnServerInvoke = function()
				return ServiceToId, IdToService, MethodToId, IdToMethod, SignalToId, IdToSignal
			end
		else
			Bridge = ReplicatedStorage:WaitForChild("LorenBridge")
			Handshake = ReplicatedStorage:WaitForChild("LorenHandshake")
			ServiceToId, IdToService, MethodToId, IdToMethod, SignalToId, IdToSignal = Handshake:InvokeServer()
		end

		local registry = (self.IsServer and Services or Controllers)
		for name, mod in registry do
			if typeof(mod) == "table" and mod.Dependencies then
				local res = {}
				for _, d in mod.Dependencies do
					local ok, dep = pcall(GetModule, d, name)
					if ok then
						res[d] = dep
					else
						return reject(dep)
					end
				end
				mod.Dependencies = res
			end
		end

		if self.IsServer then
			Bridge.OnServerEvent:Connect(function(player, header, ...)
				local now = os.clock()
				local tracker: { Count: number, LastReset: number } = CallTracker[player]
					or { Count = 0, LastReset = now }
				if now - tracker.LastReset >= 1 then
					tracker.Count, tracker.LastReset = 0, now
				end
				tracker.Count += 1
				CallTracker[player] = tracker
				if tracker.Count > RATE_LIMIT then
					if player and typeof(player) == "Instance" then
						warn("(LORENঌ) Rate limit reached from calls from " .. player.Name)
					end

					return
				end

				if typeof(header) ~= "buffer" or buffer.len(header) ~= 5 then
					return
				end
				local reqId, sId, mId, pCount = UnpackHeader(header)
				print("Server Inbox:", reqId)
				if pCount > MAX_ARGUMENTS then
					return
				end

				local sName = IdToService[sId]
				local mName = sName and IdToMethod[sId] and IdToMethod[sId][mId]
				local s = sName and Services[sName]
				if not s or not mName or not s.Client[mName] then
					return
				end

				local args = table.pack(...)
				if s.Middleware and s.Middleware[mName] then
					local ok, err = s.Middleware[mName](player, table.unpack(args, 1, pCount))
					if not ok then
						return Bridge:FireClient(player, reqId, false, err or "Denied")
					end
				end

				local function packResults(...)
					return select("#", ...), { ... }
				end

				local count, results =
					packResults(pcall(s.Client[mName], s.Client, player, table.unpack(args, 1, pCount)))
				local success = results[1]

				local responseArgs = {}
				for i = 2, count do
					responseArgs[i - 1] = results[i]
				end
				Bridge:FireClient(player, reqId, success, table.unpack(responseArgs, 1, count - 1))
			end)
			Players.PlayerRemoving:Connect(function(p)
				CallTracker[p] = nil
			end)
		else
			Bridge.OnClientEvent:Connect(function(hid, ...)
				if typeof(hid) == "buffer" then
					local _, sId, sigId = UnpackHeader(hid)
					if ClientSignals[sId] and ClientSignals[sId][sigId] then
						ClientSignals[sId][sigId]:_Execute(...)
					end
				elseif PendingRequests[hid] then
					local request = PendingRequests[hid]
					PendingRequests[hid] = nil

					if request.timeout then
						task.cancel(request.timeout)
					end

					local success = select(1, ...)

					if success == false then
						request.reject(select(2, ...))
					else
						request.resolve(select(2, ...))
					end
				end
			end)
		end

		for _, mod in registry do
			if mod.LorenIgnite then
				mod:LorenIgnite()
			end
		end
		for _, mod in registry do
			if mod.LorenBurn then
				task.spawn(mod.LorenBurn, mod)
			end
		end
		print("(LORENঌ) Burning on " .. (Loren.IsServer and "Server" or "Client"))
		resolve(self)
	end)
end

return Loren
