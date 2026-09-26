--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Metrics = require(Harness:WaitForChild("Metrics"))

local SignalWatcher = {}
SignalWatcher.__index = SignalWatcher

export type Summary = {
	name: string,
	expected: number?,
	received: number,
	lost: number?,
	reordered: number,
	duplicates: number,
	gaps: number,
	malformed: number,
	outOfRange: number,
	oneWayMs: Metrics.Summary,
}

export type SignalWatcher = {
	name: string,
	signal: any,
	connection: any,
	seen: { [number]: boolean },
	reorderedAt: { [number]: boolean },
	arrivals: number,
	duplicates: number,
	malformed: number,
	gaps: number,
	last: number?,
	maxSeen: number,
	oneWay: Metrics.Reservoir,
	start: (self: SignalWatcher) -> (),
	stop: (self: SignalWatcher) -> (),
	summarize: (self: SignalWatcher, first: number?, last: number?) -> Summary,
}

function SignalWatcher.new(signal: any, name: string?): SignalWatcher
	local self = setmetatable({
		name = name or "signal",
		signal = signal,
		connection = nil,
		seen = {},
		reorderedAt = {},
		arrivals = 0,
		duplicates = 0,
		malformed = 0,
		gaps = 0,
		last = nil,
		maxSeen = 0,
		oneWay = Metrics.Reservoir.new(20000),
	}, SignalWatcher)
	return self :: any
end

local function onSignal(self: SignalWatcher, index: any, _clock: any, serverTime: any)
	if typeof(index) ~= "number" or index ~= index or index % 1 ~= 0 then
		self.malformed += 1
		return
	end
	self.arrivals += 1
	local wasSeen = self.seen[index] == true
	if wasSeen then
		self.duplicates += 1
	else
		self.seen[index] = true
	end
	if index < self.maxSeen then
		self.reorderedAt[index] = true
		if not wasSeen and self.gaps > 0 then
			self.gaps -= 1 -- a late arrival fills a gap counted earlier
		end
	elseif self.last ~= nil and index > self.maxSeen + 1 then
		self.gaps += index - self.maxSeen - 1
	end
	if index > self.maxSeen then
		self.maxSeen = index
	end
	self.last = index
	if typeof(serverTime) == "number" then
		self.oneWay:add(math.max(0, workspace:GetServerTimeNow() - serverTime))
	end
end

function SignalWatcher.start(self: SignalWatcher)
	if self.connection then
		return
	end
	-- A plain function (1.5.1 runs listeners with task.spawn, which needs a real function).
	self.connection = self.signal:Connect(function(...)
		onSignal(self, ...)
	end)
end

function SignalWatcher.stop(self: SignalWatcher)
	local connection = self.connection
	self.connection = nil
	if connection then
		pcall(function()
			connection:Disconnect()
		end)
	end
end

function SignalWatcher.summarize(self: SignalWatcher, first: number?, last: number?): Summary
	local ms = {}
	for i, v in self.oneWay.values do
		ms[i] = v * 1000
	end
	local summary: Summary = {
		name = self.name,
		expected = nil,
		received = self.arrivals,
		lost = nil,
		reordered = 0,
		duplicates = self.duplicates,
		gaps = self.gaps,
		malformed = self.malformed,
		outOfRange = 0,
		oneWayMs = Metrics.summarize(ms),
	}
	if first and last then
		local expected = math.max(0, last - first + 1)
		local received, outOfRange, reordered = 0, 0, 0
		for index in self.seen do
			if index >= first and index <= last then
				received += 1
				if self.reorderedAt[index] then
					reordered += 1
				end
			else
				outOfRange += 1
			end
		end
		summary.expected = expected
		summary.received = received
		summary.lost = expected - received
		summary.reordered = reordered
		summary.outOfRange = outOfRange
	else
		for _ in self.reorderedAt do
			summary.reordered += 1
		end
	end
	return summary
end

return SignalWatcher
