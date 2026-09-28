--!strict
--!optimize 2

-- Receive-side counters: client listeners for S->C runs, server listeners (with handler spans) for C->S runs.
local Payloads = require(script.Parent.Payloads)
local Probe = require(script.Parent.Probe)

local Recv = {}

local U16 = 65536
local HALF = 32768

export type Slot = { fn: ((any, any) -> ())? }

-- One receiving stream (a client in S->C, a player on the server in C->S).
export type Stream = {
	n: number,
	trues: number,
	reord: number,
	bad: number,
	brOk: number,
	last: number,
	cap: { any },
	capN: number,
}

-- Listener spans on the server: groups end at each remote invocation and each Heartbeat.
export type Span = {
	k: number,
	first: number,
	last: number,
	total: number,
	msgs: number,
	single: number,
}

export type ServerRun = {
	runtime: string,
	def: Payloads.Def,
	streams: { [Player]: Stream },
	span: Span,
	calls: { [Player]: number },
	bytes: { [Player]: number },
	refs: { [Player]: number },
	sampled: { [Player]: number },
	sampledBytes: { [Player]: number },
}

-- Every 30th table invocation is sized with RemotePacketSizeCounter (BridgeNet2 only).
local SAMPLE_EVERY = 30

local slots: { [string]: Slot } = {}

local function slotOf(lib: string, event: string): Slot
	local key = lib .. ":" .. event
	local existing = slots[key]
	if existing then
		return existing
	end
	local slot: Slot = { fn = nil }
	slots[key] = slot
	return slot
end

-- The bench listener for one (library, event): connect it once at boot; runs arm and disarm its slot.
function Recv.listener(lib: string, event: string, swapped: boolean?): (any, any) -> ()
	local slot = slotOf(lib, event)
	if swapped then
		return function(a: any, b: any)
			local fn = slot.fn
			if fn then
				fn(b, a)
			end
		end
	end
	return function(a: any, b: any)
		local fn = slot.fn
		if fn then
			fn(a, b)
		end
	end
end

function Recv.disarm(lib: string, event: string)
	slotOf(lib, event).fn = nil
end

function Recv.stream(capN: number): Stream
	return { n = 0, trues = 0, reord = 0, bad = 0, brOk = 0, last = U16 - 1, cap = table.create(capN), capN = capN }
end

-- Client (S->C): installs this run's handler for `lib` and returns the stream it counts into.
function Recv.armClient(lib: string, def: Payloads.Def, window: Probe.Window): Stream
	local capN = if def.kind == "array" or def.kind == "boolarray" then 1 else def.perFrame
	local st = Recv.stream(capN)
	local cap = st.cap
	local kind = def.kind
	local handler: (any, any) -> ()
	if kind == "bool" then
		handler = function(v: any)
			local n = st.n + 1
			st.n = n
			if window.open > 0 then
				st.brOk += 1
			end
			if v == true then
				st.trues += 1
			end
			if n <= capN then
				cap[n] = v
			end
		end
	elseif kind == "id" then
		handler = function(v: any)
			local n = st.n + 1
			st.n = n
			if window.open > 0 then
				st.brOk += 1
			end
			local id = if type(v) == "table" then v.id else nil
			if type(id) ~= "number" then
				st.bad += 1
				return
			end
			local d = (id - st.last) % U16
			if d == 0 or d >= HALF then
				st.reord += 1
			end
			st.last = id
			if n <= capN then
				cap[n] = v
			end
		end
	elseif kind == "array" then
		handler = function(v: any)
			local n = st.n + 1
			st.n = n
			if window.open > 0 then
				st.brOk += 1
			end
			local first = if type(v) == "table" and #v == 100 then v[1] else nil
			local id = if type(first) == "table" then first.id else nil
			if type(id) ~= "number" then
				st.bad += 1
				return
			end
			local d = (id - st.last) % U16
			if d == 0 or d >= HALF then
				st.reord += 1
			end
			st.last = id
			if n <= capN then
				cap[n] = v
			end
		end
	elseif kind == "boolarray" then
		handler = function(v: any)
			local n = st.n + 1
			st.n = n
			if window.open > 0 then
				st.brOk += 1
			end
			if type(v) ~= "table" or #v ~= 1000 then
				st.bad += 1
				return
			end
			if n <= capN then
				cap[n] = v
			end
		end
	else
		handler = function(v: any)
			local n = st.n + 1
			st.n = n
			if window.open > 0 then
				st.brOk += 1
			end
			if n <= capN then
				cap[n] = v
			end
		end
	end
	slotOf(lib, def.event).fn = handler
	return st
end

local active: ServerRun? = nil

local function closeGroup(span: Span)
	local k = span.k
	if k == 0 then
		return
	end
	if k >= 2 then
		span.total += (span.last - span.first) * k / (k - 1)
		span.msgs += k
	else
		span.single += 1
	end
	span.k = 0
end

-- Server (C->S): installs this run's handler for `lib` (every player) and makes it the active run.
function Recv.armServer(lib: string, runtime: string, def: Payloads.Def): ServerRun
	local run: ServerRun = {
		runtime = runtime,
		def = def,
		streams = {},
		span = { k = 0, first = 0, last = 0, total = 0, msgs = 0, single = 0 },
		calls = {},
		bytes = {},
		refs = {},
		sampled = {},
		sampledBytes = {},
	}
	local span = run.span
	local streams = run.streams
	local capN = def.perFrame
	slotOf(lib, def.event).fn = function(player: any, v: any)
		local now = os.clock()
		if span.k == 0 then
			span.first = now
		end
		span.last = now
		span.k += 1
		local st = streams[player]
		if st == nil then
			st = Recv.stream(capN)
			streams[player] = st
		end
		local n = st.n + 1
		st.n = n
		local seq = if type(v) == "table" then v.seq else nil
		if type(seq) ~= "number" then
			st.bad += 1
			return
		end
		local d = (seq - st.last) % U16
		if d == 0 or d >= HALF then
			st.reord += 1
		end
		st.last = seq
		if n <= capN then
			st.cap[n] = v
		end
	end
	active = run
	return run
end

-- A frozen copy of a server run's counters (the live run keeps counting, e.g. while a backlog settles).
function Recv.snapshot(run: ServerRun): ServerRun
	closeGroup(run.span)
	local streams: { [Player]: Stream } = {}
	for player, st in run.streams do
		streams[player] = table.clone(st)
	end
	return {
		runtime = run.runtime,
		def = run.def,
		streams = streams,
		span = table.clone(run.span),
		calls = table.clone(run.calls),
		bytes = table.clone(run.bytes),
		refs = table.clone(run.refs),
		sampled = table.clone(run.sampled),
		sampledBytes = table.clone(run.sampledBytes),
	}
end

function Recv.finishServer(lib: string, run: ServerRun)
	closeGroup(run.span)
	slotOf(lib, run.def.event).fn = nil
	if active == run then
		active = nil
	end
end

-- Passive server probe on one of `runtime`'s remotes: counts the invocation and ends the current span group.
function Recv.serverProbe(runtime: string, sizeOf: ((any) -> number)?, player: Player, a1: any, a2: any)
	local run = active
	if run == nil or run.runtime ~= runtime then
		return
	end
	closeGroup(run.span)
	local calls = (run.calls[player] or 0) + 1
	run.calls[player] = calls
	if typeof(a1) == "buffer" then
		run.bytes[player] = (run.bytes[player] or 0) + buffer.len(a1)
	elseif sizeOf ~= nil and calls % SAMPLE_EVERY == 1 then
		run.sampled[player] = (run.sampled[player] or 0) + 1
		run.sampledBytes[player] = (run.sampledBytes[player] or 0) + sizeOf(a1)
	end
	if type(a2) == "table" then
		run.refs[player] = (run.refs[player] or 0) + #a2
	end
end

-- Bytes one player sent in a run: exact for buffers (+1 per ref), estimated for tables.
function Recv.serverBytes(run: ServerRun, player: Player): (number, boolean)
	local refs = run.refs[player] or 0
	local sampled = run.sampled[player] or 0
	if sampled > 0 then
		return (run.sampledBytes[player] or 0) / sampled * (run.calls[player] or 0) + refs, true
	end
	return (run.bytes[player] or 0) + refs, false
end

-- Server Heartbeat (connected after every bracket): ends the span group of the frame.
function Recv.serverFrame()
	local run = active
	if run then
		closeGroup(run.span)
	end
end

return Recv
