--!strict
--!optimize 2

local RunService = game:GetService("RunService")

local Probe = {}

export type Window = { open: number }

export type Bracket = {
	window: Window,
	total: number,
	windows: number,
	opened: boolean,
	armed: boolean,
	t0: number,
	connections: { RBXScriptConnection },
}

export type Counter = {
	calls: number,
	bytes: number,
	refs: number,
	sampled: number,
	sampledBytes: number,
	sizeOf: ((any) -> number)?,
}

local SAMPLE_EVERY = 30

function Probe.window(): Window
	return { open = 0 }
end

function Probe.counter(sizeOf: ((any) -> number)?): Counter
	return { calls = 0, bytes = 0, refs = 0, sampled = 0, sampledBytes = 0, sizeOf = sizeOf }
end

function Probe.resetCounter(c: Counter)
	c.calls = 0
	c.bytes = 0
	c.refs = 0
	c.sampled = 0
	c.sampledBytes = 0
end

function Probe.bytes(c: Counter): (number, boolean)
	if c.sampled > 0 then
		return c.sampledBytes / c.sampled * c.calls + c.refs, true
	end
	return c.bytes + c.refs, false
end

local function count(c: Counter, a1: any, a2: any)
	local calls = c.calls + 1
	c.calls = calls
	if typeof(a1) == "buffer" then
		c.bytes += buffer.len(a1)
	elseif c.sizeOf ~= nil and calls % SAMPLE_EVERY == 1 then
		c.sampled += 1
		c.sampledBytes += (c.sizeOf :: (any) -> number)(a1)
	end
	if type(a2) == "table" then
		c.refs += #a2
	end
end

function Probe.bracket(window: Window): Bracket
	return { window = window, total = 0, windows = 0, opened = false, armed = false, t0 = 0, connections = {} }
end

local function toggle(br: Bracket)
	if not br.armed then
		return
	end
	if br.opened then
		br.total += os.clock() - br.t0
		br.opened = false
		br.windows += 1
		br.window.open -= 1
	else
		br.opened = true
		br.window.open += 1
		br.t0 = os.clock()
	end
end

function Probe.openA(br: Bracket, signal: RBXScriptSignal, counter: Counter?)
	local connection: RBXScriptConnection
	if counter then
		connection = signal:Connect(function(a1: any, a2: any)
			if br.opened then
				toggle(br)
				count(counter, a1, a2)
			else
				count(counter, a1, a2)
				toggle(br)
			end
		end)
	else
		connection = signal:Connect(function()
			toggle(br)
		end)
	end
	table.insert(br.connections, connection)
end

function Probe.closeB(br: Bracket, signal: RBXScriptSignal)
	table.insert(
		br.connections,
		signal:Connect(function()
			toggle(br)
		end)
	)
	br.armed = true
end

local function deferredToggle(br: Bracket): () -> ()
	local queued = false
	local thread = coroutine.create(function()
		while true do
			queued = false
			toggle(br)
			coroutine.yield()
		end
	end)
	return function()
		if not queued then
			queued = true
			task.defer(thread)
		end
	end
end

function Probe.openDeferredA(br: Bracket, signal: RBXScriptSignal)
	table.insert(br.connections, signal:Connect(deferredToggle(br)))
end

function Probe.closeDeferredB(br: Bracket, signal: RBXScriptSignal)
	table.insert(br.connections, signal:Connect(deferredToggle(br)))
	RunService.PreSimulation:Once(function()
		br.armed = true
	end)
end

function Probe.reset(br: Bracket)
	br.total = 0
	br.windows = 0
end

function Probe.passive(signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	return signal:Connect(fn)
end

function Probe.connectOrder(): string
	local seen: { number } = {}
	local connections: { RBXScriptConnection } = {}
	for i = 1, 3 do
		connections[i] = RunService.Heartbeat:Connect(function()
			table.insert(seen, i)
		end)
	end
	local deadline = os.clock() + 3
	while #seen < 15 and os.clock() < deadline do
		task.wait()
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	local groups = #seen // 3
	if groups == 0 then
		return "mixed"
	end
	local fifo, lifo = true, true
	for g = 0, groups - 1 do
		local a, b, c = seen[g * 3 + 1], seen[g * 3 + 2], seen[g * 3 + 3]
		if not (a == 1 and b == 2 and c == 3) then
			fifo = false
		end
		if not (a == 3 and b == 2 and c == 1) then
			lifo = false
		end
	end
	return if fifo then "FIFO" elseif lifo then "LIFO" else "mixed"
end

return Probe
