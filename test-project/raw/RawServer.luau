--!strict
--!optimize 2
--[[
	RawServer: the fixture API (Echo/Counter/Inventory/Instance/Broadcast/Dependent) on one plain
	RemoteEvent, with no framework. It is the "raw" baseline for the compare scenario.

	Wire: C->S FireServer(reqId, service, method, ...args)
	      S->C FireClient(player, reqId, ok, ...results)     reply
	      S->C FireClient/FireAllClients("Service.Signal", ...) signal
	Same validation as the fixture middleware; no rate limiting (that is the point of a raw baseline).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RawServer = {}

type Handler = (Player, ...any) -> ...any
type Validator = (Player, ...any) -> (boolean, string?)

local remote: RemoteEvent = nil :: any
local started = false

local counts: { [Player]: number } = {}
local dropped: { [Player]: { [string]: number } } = {}
local tickIndex = 0
local ticking: RBXScriptConnection? = nil

type MethodStats = { calls: number, errors: number, denied: number, time: number, maxTime: number }
local methodStats: { [string]: MethodStats } = {}

local function statFor(name: string): MethodStats
	local s = methodStats[name]
	if not s then
		s = { calls = 0, errors = 0, denied = 0, time = 0, maxTime = 0 }
		methodStats[name] = s
	end
	return s
end

local handlers: { [string]: { [string]: Handler } } = {
	EchoService = {
		Echo = function(_player, ...)
			return ...
		end,
		Size = function(_player, s: any)
			return #s
		end,
	},
	CounterService = {
		Increment = function(player, n: any)
			local value = (counts[player] or 0) + n
			counts[player] = value
			remote:FireClient(player, "CounterService.Changed", value)
			return value
		end,
	},
	InventoryService = {
		Drop = function(player, item: any, amount: any)
			local mine = dropped[player]
			if not mine then
				mine = {}
				dropped[player] = mine
			end
			mine[item] = (mine[item] or 0) + amount
			return mine[item]
		end,
	},
	InstanceService = {
		NameOf = function(_player, inst)
			return inst, inst.Name
		end,
	},
	BroadcastService = {
		Ping = function(_player)
			return true
		end,
	},
	DependentService = {
		Total = function(player)
			return counts[player] or 0
		end,
	},
}

local validators: { [string]: Validator } = {
	["CounterService.Increment"] = function(_player, n)
		return typeof(n) == "number" and n == n and n >= 1 and n <= 100, nil
	end,
	["InventoryService.Drop"] = function(_player, item, amount)
		if typeof(item) ~= "string" or #item == 0 or #item > 32 then
			return false, "Invalid"
		end
		if typeof(amount) ~= "number" or not (amount >= 1 and amount <= 99) or amount % 1 ~= 0 then
			return false, "Invalid"
		end
		return true, nil
	end,
}

local function onCall(player: Player, reqId: any, service: any, method: any, ...: any)
	if typeof(reqId) ~= "number" or typeof(service) ~= "string" or typeof(method) ~= "string" then
		return -- junk: dropped silently
	end
	local serviceHandlers = handlers[service]
	local handler = serviceHandlers and serviceHandlers[method]
	if not handler then
		remote:FireClient(player, reqId, false, "Missing Method: " .. string.sub(service .. "." .. method, 1, 64))
		return
	end
	local key = service .. "." .. method
	local stat = statFor(key)
	local validator = validators[key]
	if validator then
		local ok, message = validator(player, ...)
		if not ok then
			stat.denied += 1
			remote:FireClient(player, reqId, false, message or "Denied")
			return
		end
	end
	local t0 = os.clock()
	local results = table.pack(pcall(handler, player, ...))
	local elapsed = os.clock() - t0
	stat.calls += 1
	stat.time += elapsed
	if elapsed > stat.maxTime then
		stat.maxTime = elapsed
	end
	if results[1] then
		remote:FireClient(player, reqId, true, table.unpack(results, 2, results.n))
	else
		stat.errors += 1
		remote:FireClient(player, reqId, false, tostring(results[2]))
	end
end

function RawServer.start()
	if started then
		return
	end
	started = true
	local folder = Instance.new("Folder")
	folder.Name = "RawNet"
	remote = Instance.new("RemoteEvent")
	remote.Name = "Remote"
	remote.Parent = folder
	remote.OnServerEvent:Connect(onCall)
	folder.Parent = ReplicatedStorage
	Players.PlayerRemoving:Connect(function(player)
		counts[player] = nil
		dropped[player] = nil
	end)
end

function RawServer.fireTick(): number
	tickIndex += 1
	remote:FireAllClients("BroadcastService.Tick", tickIndex, os.clock(), workspace:GetServerTimeNow())
	return tickIndex
end

function RawServer.getIndex(): number
	return tickIndex
end

function RawServer.startTicking(rate: number): number
	RawServer.stopTicking()
	local first = tickIndex + 1
	local carry = 0
	local maxPerFrame = math.max(2, rate * 0.25)
	ticking = RunService.Heartbeat:Connect(function(dt: number)
		carry = math.min(carry + dt * rate, maxPerFrame)
		while carry >= 1 do
			carry -= 1
			RawServer.fireTick()
		end
	end)
	return first
end

function RawServer.stopTicking(): number
	if ticking then
		ticking:Disconnect()
		ticking = nil
	end
	return tickIndex
end

function RawServer.fireBurst(n: number): (number, number)
	local first = tickIndex + 1
	for _ = 1, n do
		RawServer.fireTick()
	end
	return first, tickIndex
end

function RawServer.getCount(player: Player): number
	return counts[player] or 0
end

function RawServer.getStats(): { [string]: MethodStats }
	return methodStats
end

function RawServer.resetStats()
	table.clear(methodStats)
end

return RawServer
