--!strict
--!optimize 2

-- Bracket probes (A before a library's own connection, B after it) and passive remote counters.
local RunService = game:GetService("RunService")

local Probe = {}

-- Open brackets of one runtime; a listener that runs while open > 0 is inside a measured window.
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

-- Every 30th table invocation is sized with RemotePacketSizeCounter (BridgeNet2 only).
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

-- Bytes seen by a counter: exact for buffers (+1 per ref), estimated from samples for tables.
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

-- Whichever probe runs first in an invocation opens the window, the other one closes it.
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

-- Probe A: connect it before the library connects to `signal`. A counter makes it count invocations too.
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

-- Probe B: connect it after the library's own connection exists; arms the bracket.
function Probe.closeB(br: Bracket, signal: RBXScriptSignal)
	table.insert(
		br.connections,
		signal:Connect(function()
			toggle(br)
		end)
	)
	br.armed = true
end

function Probe.reset(br: Bracket)
	br.total = 0
	br.windows = 0
end

-- A passive probe: fn(...) on every invocation, wherever it lands in the handler order.
function Probe.passive(signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	return signal:Connect(fn)
end

-- Fires three dummy Heartbeat connections for a few frames: "FIFO", "LIFO" or "mixed".
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
