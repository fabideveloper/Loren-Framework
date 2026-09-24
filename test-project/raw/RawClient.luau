--!strict
--!optimize 2
--[[
	RawClient: client side of the raw baseline. RawClient.connect() returns proxies shaped like
	Loren's (proxy:Method(...) -> Promise, proxy.Signals.Name:Connect/Once), so bots and specs
	run unchanged. Keeps nil holes (explicit argument counts); 10 s timeout like 1.5.1.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage:WaitForChild("LorenPackages"):WaitForChild("Promise")) :: any

local RawClient = {}

local TIMEOUT = 10
local SIGNALS = {
	CounterService = { "Changed" },
	BroadcastService = { "Tick" },
}

type Pending = { resolve: (...any) -> (), reject: (...any) -> (), timer: thread }

local remote: RemoteEvent? = nil
local nextId = 0
local pending: { [number]: Pending } = {}
local listeners: { [string]: { (...any) -> () } } = {}
local proxies: { [string]: any }? = nil

local function newSignal(key: string): any
	listeners[key] = listeners[key] or {}
	local signal = {}
	function signal.Connect(_self: any, fn: (...any) -> ())
		local list = listeners[key]
		table.insert(list, fn)
		local connection = {}
		function connection.Disconnect()
			local i = table.find(list, fn)
			if i then
				table.remove(list, i)
			end
		end
		return connection
	end
	function signal.Once(self: any, fn: (...any) -> ())
		local connection
		connection = self:Connect(function(...)
			connection.Disconnect()
			fn(...)
		end)
		return connection
	end
	return signal
end

local function call(service: string, method: string, ...: any): any
	local args = table.pack(...)
	return Promise.new(function(resolve, reject, onCancel)
		nextId += 1
		local id = nextId
		local timer = task.delay(TIMEOUT, function()
			if pending[id] then
				pending[id] = nil
				reject("Timeout")
			end
		end)
		pending[id] = { resolve = resolve, reject = reject, timer = timer }
		onCancel(function()
			local entry = pending[id]
			if entry then
				pending[id] = nil
				task.cancel(entry.timer)
			end
		end)
		local target = remote :: RemoteEvent
		target:FireServer(id, service, method, table.unpack(args, 1, args.n))
	end)
end

local function onEvent(first: any, ...: any)
	if typeof(first) == "number" then
		local entry = pending[first]
		if not entry then
			return
		end
		pending[first] = nil
		task.cancel(entry.timer)
		if (...) == true then
			entry.resolve(select(2, ...))
		else
			entry.reject(select(2, ...))
		end
	elseif typeof(first) == "string" then
		local list = listeners[first]
		if list then
			for _, fn in table.clone(list) do
				task.spawn(fn, ...)
			end
		end
	end
end

function RawClient.connect(): { [string]: any }
	if proxies then
		return proxies
	end
	local folder = ReplicatedStorage:WaitForChild("RawNet")
	local event = folder:WaitForChild("Remote") :: RemoteEvent
	remote = event
	event.OnClientEvent:Connect(onEvent)

	local built: { [string]: any } = {}
	for _, service in
		{
			"EchoService",
			"CounterService",
			"InventoryService",
			"InstanceService",
			"BroadcastService",
			"DependentService",
		}
	do
		local signals = {}
		for _, name in SIGNALS[service] or {} do
			signals[name] = newSignal(service .. "." .. name)
		end
		built[service] = setmetatable({ Signals = signals }, {
			__index = function(_, method: string)
				return function(_self: any, ...: any)
					return call(service, method, ...)
				end
			end,
		})
	end
	proxies = built
	return built
end

return RawClient
