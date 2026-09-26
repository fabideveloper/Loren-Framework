--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Metrics = require(Harness:WaitForChild("Metrics"))

local CallKit = {}
CallKit.__index = CallKit

export type Summary = {
	sent: number,
	ok: number,
	wrong: number,
	timeouts: number,
	errors: number,
	unsettled: number,
	rttMs: Metrics.Summary,
	reasons: { [string]: number },
}

type Call = () -> (any, (...any) -> boolean)

export type CallKit = {
	calls: { [string]: Call },
	order: { string },
	cursor: number,
	sent: number,
	ok: number,
	wrong: number,
	timeouts: number,
	errors: number,
	inFlight: number,
	reasons: { [string]: number },
	rtt: Metrics.Reservoir,
	fire: (self: CallKit, onSettled: ((outcome: string) -> ())?) -> (),
	summary: (self: CallKit) -> Summary,
}

CallKit.MIXES = {
	mixed = { "Echo", "Size", "Ping", "Increment", "Echo", "Total", "Drop", "NameOf" },
	echo = { "Echo" },
	light = { "Echo", "Ping", "Size" },
}

local function buildCalls(proxies: { [string]: any }, payload: string): { [string]: Call }
	-- An Instance both sides can see, for the Instance round trip.
	local target: Instance = ReplicatedStorage:FindFirstChild("TestConfig") or ReplicatedStorage
	local targetName = target.Name
	local size = #payload
	return {
		Echo = function()
			return proxies.EchoService:Echo(payload), function(v)
				return v == payload
			end
		end,
		Size = function()
			return proxies.EchoService:Size(payload), function(v)
				return v == size
			end
		end,
		Ping = function()
			return proxies.BroadcastService:Ping(), function(v)
				return v == true
			end
		end,
		Increment = function()
			return proxies.CounterService:Increment(1), function(v)
				return typeof(v) == "number"
			end
		end,
		Total = function()
			return proxies.DependentService:Total(), function(v)
				return typeof(v) == "number"
			end
		end,
		Drop = function()
			return proxies.InventoryService:Drop("Potion", 1), function(v)
				return typeof(v) == "number"
			end
		end,
		NameOf = function()
			return proxies.InstanceService:NameOf(target),
				function(inst, name)
					return inst == target and name == targetName
				end
		end,
	}
end

function CallKit.new(proxies: { [string]: any }, payloadSize: number?, mix: string?): CallKit
	local payload = string.rep("x", math.max(0, math.floor(payloadSize or 64)))
	local self = setmetatable({
		calls = buildCalls(proxies, payload),
		order = CallKit.MIXES[mix or "mixed"] or CallKit.MIXES.mixed,
		cursor = 1,
		sent = 0,
		ok = 0,
		wrong = 0,
		timeouts = 0,
		errors = 0,
		inFlight = 0,
		reasons = {},
		rtt = Metrics.Reservoir.new(20000),
	}, CallKit)
	return self :: any
end

local function settle(self: CallKit, started: number, outcome: string, reason: string?)
	self.inFlight -= 1
	if outcome == "ok" then
		self.ok += 1
		self.rtt:add(os.clock() - started)
	elseif outcome == "wrong" then
		self.wrong += 1
	elseif outcome == "timeout" then
		self.timeouts += 1
		Metrics.bump(self.reasons, reason or "Timeout")
	else
		self.errors += 1
		Metrics.bump(self.reasons, reason or "?")
	end
end

function CallKit.fire(self: CallKit, onSettled: ((outcome: string) -> ())?)
	local kind = self.order[self.cursor]
	self.cursor = self.cursor % #self.order + 1
	self.sent += 1
	self.inFlight += 1
	local started = os.clock()

	local function finish(outcome: string, reason: string?)
		settle(self, started, outcome, reason)
		if onSettled then
			pcall(onSettled, outcome)
		end
	end

	local ok, promise, check = pcall(self.calls[kind])
	if not ok then
		finish("error", "threw: " .. Env.reason(promise))
		return
	end
	local chained = pcall(function()
		promise:andThen(function(...)
			local good, right = pcall(check, ...)
			finish(if good and right then "ok" else "wrong", nil)
		end, function(err)
			local reason = Env.reason(err)
			finish(if string.find(reason, "Timeout", 1, true) then "timeout" else "error", reason)
		end)
	end)
	if not chained then
		finish("error", "not a Promise")
	end
end

function CallKit.summary(self: CallKit): Summary
	local ms = {}
	for i, v in self.rtt.values do
		ms[i] = v * 1000
	end
	return {
		sent = self.sent,
		ok = self.ok,
		wrong = self.wrong,
		timeouts = self.timeouts,
		errors = self.errors,
		unsettled = self.inFlight,
		rttMs = Metrics.summarize(ms),
		reasons = table.clone(self.reasons),
	}
end

return CallKit
