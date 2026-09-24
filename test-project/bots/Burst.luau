--!strict
--!optimize 2
--[[
	Burst: fires `size` calls in a single frame every `interval` seconds and measures how long each
	burst takes to settle (last reply of the burst), plus per-call latency and outcomes.

		local bot = Burst.new(proxies, { size = 60, interval = 2, payloadSize = 64 })
		bot:start() ... bot:stop(); bot:waitIdle(12); bot:summary()

	A burst larger than 1.5.1's 50 calls/s window loses the excess to silent drops (10 s Timeouts);
	2.0 should serve it or reject the excess fast with RateLimited.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Env = require(Harness:WaitForChild("Env"))
local Metrics = require(Harness:WaitForChild("Metrics"))
local CallKit = require(script.Parent:WaitForChild("CallKit"))

local Burst = {}
Burst.__index = Burst

export type Options = { size: number, interval: number?, payloadSize: number? }

export type Burst = {
	kit: CallKit.CallKit,
	size: number,
	interval: number,
	running: boolean,
	thread: thread?,
	bursts: number,
	settleTimes: { number },
	start: (self: Burst) -> (),
	stop: (self: Burst) -> (),
	waitIdle: (self: Burst, timeout: number) -> boolean,
	summary: (self: Burst) -> { [string]: any },
}

function Burst.new(proxies: { [string]: any }, options: Options): Burst
	local self = setmetatable({
		kit = CallKit.new(proxies, options.payloadSize, "light"),
		size = math.max(1, math.floor(options.size)),
		interval = options.interval or 2,
		running = false,
		thread = nil,
		bursts = 0,
		settleTimes = {},
	}, Burst)
	return self :: any
end

local function fireBurst(self: Burst)
	self.bursts += 1
	local started = os.clock()
	local outstanding = self.size
	local function onSettled(_outcome: string)
		outstanding -= 1
		if outstanding == 0 then
			table.insert(self.settleTimes, (os.clock() - started) * 1000)
		end
	end
	for _ = 1, self.size do
		self.kit:fire(onSettled)
	end
end

function Burst.start(self: Burst)
	if self.running then
		return
	end
	self.running = true
	self.thread = task.spawn(function()
		while self.running do
			fireBurst(self)
			task.wait(self.interval)
		end
	end)
end

function Burst.stop(self: Burst)
	self.running = false
	local thread = self.thread
	self.thread = nil
	if thread and coroutine.status(thread) == "suspended" then
		pcall(task.cancel, thread)
	end
end

function Burst.waitIdle(self: Burst, timeout: number): boolean
	return Env.waitUntil(function()
		return self.kit.inFlight <= 0
	end, timeout, 0.1)
end

function Burst.summary(self: Burst): { [string]: any }
	local summary: { [string]: any } = self.kit:summary() :: any
	summary.bursts = self.bursts
	summary.burstSize = self.size
	summary.settleMs = Metrics.summarize(self.settleTimes)
	return summary
end

return Burst
