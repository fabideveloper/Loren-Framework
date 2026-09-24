--!strict
--!optimize 2
--[[
	Soak: long steady load that looks for leaks on the client.

		local bot = Soak.new(proxies, { rate = 30, payloadSize = 64, sampleEvery = 5 })
		bot:start() ... bot:stop(); bot:waitIdle(12); bot:summary()

	Runs a CallSpammer ("mixed"), and every second churns signal connections (20 Connect +
	Disconnect on Tick and Changed) and cancels a few calls right after sending them, which
	exercises the framework's cleanup paths. Samples gcinfo() and Stats memory every sampleEvery
	seconds; summary().memory reports start/end/max and the least-squares trend in KB/min.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Metrics = require(Harness:WaitForChild("Metrics"))
local CallSpammer = require(script.Parent:WaitForChild("CallSpammer"))

local Soak = {}
Soak.__index = Soak

export type Options = { rate: number, payloadSize: number?, sampleEvery: number? }

export type Soak = {
	proxies: { [string]: any },
	spammer: CallSpammer.CallSpammer,
	sampleEvery: number,
	running: boolean,
	threads: { thread },
	startedAt: number,
	samples: { { t: number, gcKb: number, totalMb: number } },
	churned: number,
	cancelled: number,
	churnErrors: number,
	start: (self: Soak) -> (),
	stop: (self: Soak) -> (),
	waitIdle: (self: Soak, timeout: number) -> boolean,
	summary: (self: Soak) -> { [string]: any },
}

function Soak.new(proxies: { [string]: any }, options: Options): Soak
	local self = setmetatable({
		proxies = proxies,
		spammer = CallSpammer.new(proxies, { rate = options.rate, payloadSize = options.payloadSize, mix = "mixed" }),
		sampleEvery = options.sampleEvery or 5,
		running = false,
		threads = {},
		startedAt = 0,
		samples = {},
		churned = 0,
		cancelled = 0,
		churnErrors = 0,
	}, Soak)
	return self :: any
end

local function sample(self: Soak)
	table.insert(self.samples, {
		t = os.clock() - self.startedAt,
		gcKb = gcinfo(),
		totalMb = Stats:GetTotalMemoryUsageMb(),
	})
end

local function churn(self: Soak)
	local ok = pcall(function()
		local signals: { any } = {
			self.proxies.BroadcastService.Signals.Tick,
			self.proxies.CounterService.Signals.Changed,
		}
		for _, signal in signals do
			local connections: { any } = {}
			for _ = 1, 10 do
				local connection = signal:Connect(function() end)
				table.insert(connections, connection)
			end
			for _, connection in connections do
				connection:Disconnect()
			end
			self.churned += #connections
		end
		-- Send then cancel: the framework must drop the late reply and free the pending entry.
		for _ = 1, 2 do
			local promise = self.proxies.BroadcastService:Ping()
			promise:cancel()
			self.cancelled += 1
		end
	end)
	if not ok then
		self.churnErrors += 1
	end
end

function Soak.start(self: Soak)
	if self.running then
		return
	end
	self.running = true
	self.startedAt = os.clock()
	sample(self)
	self.spammer:start()
	table.insert(
		self.threads,
		task.spawn(function()
			while self.running do
				task.wait(self.sampleEvery)
				if self.running then
					sample(self)
				end
			end
		end)
	)
	table.insert(
		self.threads,
		task.spawn(function()
			while self.running do
				task.wait(1)
				if self.running then
					churn(self)
				end
			end
		end)
	)
end

function Soak.stop(self: Soak)
	if not self.running then
		return
	end
	self.running = false
	self.spammer:stop()
	for _, thread in self.threads do
		if coroutine.status(thread) == "suspended" then
			pcall(task.cancel, thread)
		end
	end
	table.clear(self.threads)
	sample(self)
end

function Soak.waitIdle(self: Soak, timeout: number): boolean
	return self.spammer:waitIdle(timeout)
end

function Soak.summary(self: Soak): { [string]: any }
	local summary = self.spammer:summary()
	local points = {}
	local maxKb = 0
	for _, s in self.samples do
		table.insert(points, { t = s.t, v = s.gcKb })
		maxKb = math.max(maxKb, s.gcKb)
	end
	local first = self.samples[1]
	local last = self.samples[#self.samples]
	summary.memory = {
		samples = #self.samples,
		startKb = if first then first.gcKb else 0,
		endKb = if last then last.gcKb else 0,
		maxKb = maxKb,
		trendKbPerMin = Metrics.slope(points) * 60,
		startTotalMb = if first then first.totalMb else 0,
		endTotalMb = if last then last.totalMb else 0,
	}
	summary.churned = self.churned
	summary.cancelled = self.cancelled
	summary.churnErrors = self.churnErrors
	return summary
end

return Soak
