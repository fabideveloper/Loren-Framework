--!strict
--!optimize 2
--[[
	Sampler: server measurements over a load window.
		local s = Sampler.start()   ...   local summary = s:stop()
	Records Heartbeat frame time (dt), Stats.DataSendKbps/DataReceiveKbps every 0.5 s (KB/s approx,
	total over all clients), memory every 2 s (Stats:GetTotalMemoryUsageMb, LuaHeap tag, gcinfo),
	and Output lines (LogService.MessageOut) by type, excluding the harness's own "(LORENঌ - TEST)" lines.
		Sampler.idle(seconds) -> { sendKbps, recvKbps }   baseline to subtract (no load running)
]]

-- The harness prefix; its own lines are excluded from the server log counts.
local HARNESS_TAG = "(LORENঌ - TEST)"

local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Harness = ReplicatedStorage:WaitForChild("LorenTest"):WaitForChild("Harness")
local Metrics = require(Harness:WaitForChild("Metrics"))

local Sampler = {}
Sampler.__index = Sampler

export type MemorySample = { t: number, totalMb: number, heapMb: number, gcKb: number }

export type Summary = {
	durationS: number,
	frameMs: Metrics.Summary,
	sendKbps: Metrics.Summary,
	recvKbps: Metrics.Summary,
	memory: {
		samples: { MemorySample },
		startTotalMb: number,
		endTotalMb: number,
		maxTotalMb: number,
		startHeapMb: number,
		endHeapMb: number,
		maxHeapMb: number,
		startGcKb: number,
		endGcKb: number,
		heapTrendMbPerMin: number,
	},
	logs: { warnings: number, errors: number, other: number, top: { [string]: number } },
}

export type Sampler = {
	started: number,
	running: boolean,
	frames: Metrics.Reservoir,
	send: { number },
	recv: { number },
	memory: { MemorySample },
	logs: { warnings: number, errors: number, other: number, top: { [string]: number } },
	connections: { RBXScriptConnection },
	thread: thread?,
	peek: (self: Sampler) -> MemorySample,
	stop: (self: Sampler) -> Summary,
}

local function heapMb(): number
	local ok, value = pcall(function()
		return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap)
	end)
	return if ok and typeof(value) == "number" then value else 0
end

local function memorySample(started: number): MemorySample
	return {
		t = os.clock() - started,
		totalMb = Stats:GetTotalMemoryUsageMb(),
		heapMb = heapMb(),
		gcKb = gcinfo(),
	}
end

function Sampler.start(): Sampler
	local self: Sampler = setmetatable({
		started = os.clock(),
		running = true,
		frames = Metrics.Reservoir.new(100000),
		send = {},
		recv = {},
		memory = {},
		logs = { warnings = 0, errors = 0, other = 0, top = {} },
		connections = {},
		thread = nil,
	}, Sampler) :: any

	table.insert(self.memory, memorySample(self.started))
	table.insert(
		self.connections,
		RunService.Heartbeat:Connect(function(dt: number)
			self.frames:add(dt)
		end)
	)
	table.insert(
		self.connections,
		LogService.MessageOut:Connect(function(message, messageType)
			if string.sub(message, 1, #HARNESS_TAG) == HARNESS_TAG then
				return
			end
			if messageType == Enum.MessageType.MessageWarning then
				self.logs.warnings += 1
			elseif messageType == Enum.MessageType.MessageError then
				self.logs.errors += 1
			else
				self.logs.other += 1
			end
			Metrics.bump(self.logs.top, message, 8)
		end)
	)
	self.thread = task.spawn(function()
		local tick = 0
		while self.running do
			task.wait(0.5)
			if not self.running then
				break
			end
			tick += 1
			table.insert(self.send, Stats.DataSendKbps)
			table.insert(self.recv, Stats.DataReceiveKbps)
			if tick % 4 == 0 then
				table.insert(self.memory, memorySample(self.started))
			end
		end
	end)
	return self
end

function Sampler.peek(self: Sampler): MemorySample
	return memorySample(self.started)
end

function Sampler.stop(self: Sampler): Summary
	self.running = false
	for _, connection in self.connections do
		connection:Disconnect()
	end
	table.clear(self.connections)
	local thread = self.thread
	if thread and coroutine.status(thread) == "suspended" then
		pcall(task.cancel, thread)
	end
	table.insert(self.memory, memorySample(self.started))

	local frameMs = {}
	for i, dt in self.frames.values do
		frameMs[i] = dt * 1000
	end
	local first, last = self.memory[1], self.memory[#self.memory]
	local maxTotal, maxHeap = 0, 0
	local heapPoints = {}
	-- Trend over the second half only: the first half includes warm-up allocation.
	local half = self.memory[math.max(1, math.floor(#self.memory / 2))].t
	for _, m in self.memory do
		maxTotal = math.max(maxTotal, m.totalMb)
		maxHeap = math.max(maxHeap, m.heapMb)
		if m.t >= half then
			table.insert(heapPoints, { t = m.t, v = m.heapMb })
		end
	end
	return {
		durationS = os.clock() - self.started,
		frameMs = Metrics.summarize(frameMs),
		sendKbps = Metrics.summarize(self.send),
		recvKbps = Metrics.summarize(self.recv),
		memory = {
			samples = self.memory,
			startTotalMb = first.totalMb,
			endTotalMb = last.totalMb,
			maxTotalMb = maxTotal,
			startHeapMb = first.heapMb,
			endHeapMb = last.heapMb,
			maxHeapMb = maxHeap,
			startGcKb = first.gcKb,
			endGcKb = last.gcKb,
			heapTrendMbPerMin = Metrics.slope(heapPoints) * 60,
		},
		logs = self.logs,
	}
end

function Sampler.idle(seconds: number): { sendKbps: number, recvKbps: number }
	local send, recv = {}, {}
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		task.wait(0.5)
		table.insert(send, Stats.DataSendKbps)
		table.insert(recv, Stats.DataReceiveKbps)
	end
	return { sendKbps = Metrics.summarize(send).mean, recvKbps = Metrics.summarize(recv).mean }
end

return Sampler
