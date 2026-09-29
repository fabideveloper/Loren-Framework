--!strict
-- Round 1.5 (design/loren-2.0/SIGNALS-RESEARCH.md O12): deliverIn1's one-listener path against the full walk (deliverIn).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local Signal = require(Runtime.Signal) :: any
local Log = require(Runtime.Log) :: any

local ClientSignal = Signal.ClientSignal
local ServerEvent = Signal.ServerEvent
local MSGS = { "a", "b", "c" }
local PLAYER = { UserId = 7, Name = "OneListener" }
local BOOM = "OneListener.spec: a listener failed on purpose"

type Push = (string) -> ()
type Scenario = {
	name: string,
	server: boolean?, -- ServerEvents only (a failing client listener kills its runner; Delivery.spec covers that)
	client: boolean?, -- ClientSignals only (Backlog)
	backlog: number?,
	setup: (sig: any, push: Push) -> (),
	after: ((sig: any, push: Push, again: () -> ()) -> ())?,
	want: { string }, -- the listener lines of the trail (lines without "=")
}

local function noop(...: any) end

-- The value a listener got: ClientSignals pass (value), ServerEvents (player, value)
local function last(...: any): any
	return (select(select("#", ...), ...))
end

local gates: { [string]: thread } = {}

local function park(key: string)
	gates[key] = coroutine.running()
	coroutine.yield()
end

local function open(key: string)
	local th = gates[key]
	gates[key] = nil
	if th then
		task.spawn(th)
	end
end

local function newSig(server: boolean, backlog: number?): any
	if server then
		return ServerEvent.new("One", "Ev")
	end
	return ClientSignal.new("One", "Sig", backlog or 0)
end

-- msgs in order from pooled runners, as ClientNet's pass 2 and Transport's runner do (one = deliverIn1, else deliverIn)
local function deliverAll(server: boolean, sig: any, one: boolean, push: Push)
	local cur: any = { owner = 0, busy = true, pos = 1, node = nil, stop = 0 }
	local function body(c: any, me: number)
		while c.pos <= #MSGS do
			local a = MSGS[c.pos]
			local ok: boolean?
			if server then
				ok = if one
					then ServerEvent.deliverIn1(c, me, sig, PLAYER, a)
					else ServerEvent.deliverIn(c, me, sig, PLAYER, a)
			else
				ok = if one then ClientSignal.deliverIn1(c, me, sig, a) else ClientSignal.deliverIn(c, me, sig, a)
			end
			if ok == nil then
				push("held=" .. a)
				break
			elseif not ok then
				return
			end
			c.pos += 1
		end
		c.busy = false
	end
	local done = Signal.drive(body, cur)
	local node = if cur.node == nil then "nil" else "set"
	push(string.format("drive=%s pos=%d node=%s stop=%d", tostring(done), cur.pos, node, cur.stop))
end

local function play(server: boolean, one: boolean, sc: Scenario): { string }
	Log._reset()
	Log._test.setSink(noop, noop)
	local trail: { string } = {}
	local function push(s: string)
		table.insert(trail, s)
	end
	local sig = newSig(server, sc.backlog)
	sc.setup(sig, push)
	deliverAll(server, sig, one, push)
	local after = sc.after
	if after then
		after(sig, push, function()
			deliverAll(server, sig, one, push)
		end)
	end
	push("listeners=" .. Signal._test.listeners(sig))
	if server then
		local log = Signal._test.eventLog(sig)
		push(string.format("logged=%d suppressed=%d", log.logged, log.suppressed))
	end
	Log._reset()
	return trail
end

local function listenerLines(trail: { string }): { string }
	local out: { string } = {}
	for _, line in trail do
		if not string.find(line, "=", 1, true) then
			table.insert(out, line)
		end
	end
	return out
end

-- Connects a listener that records "name:value" and then runs `extra` (value, connection)
local function listen(sig: any, push: Push, name: string, extra: ((string, any) -> ())?, once: boolean?): any
	local conn: any = nil
	local function fn(...: any)
		local v = last(...)
		push(name .. ":" .. tostring(v))
		if extra then
			extra(v, conn)
		end
	end
	conn = if once then sig:Once(fn) else sig:Connect(fn)
	return conn
end

local SCENARIOS: { Scenario } = {
	{
		name = "one listener gets every message",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A")
		end,
		want = { "A:a", "A:b", "A:c" },
	},
	{
		name = "the only listener disconnects itself on b",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function(v: string, conn: any)
				if v == "b" then
					conn:Disconnect()
				end
			end)
		end,
		want = { "A:a", "A:b" },
	},
	{
		name = "the only listener connects B on a: B starts at the next message",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function(v: string)
				if v == "a" then
					listen(sig, push, "B")
				end
			end)
		end,
		want = { "A:a", "A:b", "B:b", "A:c", "B:c" },
	},
	{
		name = "the only listener disconnects itself and connects B on a",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function(v: string, conn: any)
				if v == "a" then
					conn:Disconnect()
					listen(sig, push, "B")
				end
			end)
		end,
		want = { "A:a", "B:b", "B:c" },
	},
	{
		name = "a lone Once runs once; the listener it connects starts at the next message",
		setup = function(sig: any, push: Push)
			listen(sig, push, "O", function()
				listen(sig, push, "A")
			end, true)
		end,
		want = { "O:a", "A:b", "A:c" },
	},
	{
		name = "a Once next to one listener: after it, the listener is alone",
		setup = function(sig: any, push: Push)
			listen(sig, push, "O", nil, true)
			listen(sig, push, "A")
		end,
		want = { "O:a", "A:a", "A:b", "A:c" },
	},
	{
		name = "a Wait next to one listener gets the first message only",
		setup = function(sig: any, push: Push)
			task.spawn(function()
				local got = table.pack(sig:Wait())
				push("W:" .. tostring(got[got.n]))
			end)
			listen(sig, push, "A")
		end,
		want = { "W:a", "A:a", "A:b", "A:c" },
	},
	{
		name = "one of two listeners disconnects the other on a: the rest go to it alone",
		setup = function(sig: any, push: Push)
			local first = listen(sig, push, "A")
			listen(sig, push, "B", function(v: string)
				if v == "a" then
					first:Disconnect()
				end
			end)
		end,
		want = { "A:a", "B:a", "B:b", "B:c" },
	},
	{
		name = "the only listener yields on a: a takeover delivers b and c; a finishes when resumed",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function(v: string)
				if v == "a" then
					park("one")
					push("A:a resumed")
				end
			end)
		end,
		after = function()
			open("one")
		end,
		want = { "A:a", "A:b", "A:c", "A:a resumed" },
	},
	{
		name = "DisconnectAll inside the only listener",
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function()
				sig:DisconnectAll()
			end)
		end,
		want = { "A:a" },
	},
	{
		name = "a failing only listener: logged once, the next messages still run",
		server = true,
		setup = function(sig: any, push: Push)
			listen(sig, push, "A", function(v: string)
				if v == "b" then
					error(BOOM, 0)
				end
			end)
		end,
		want = { "A:a", "A:b", "A:c" },
	},
	{
		name = "Backlog before the first Connect: held, then delivered once connected",
		client = true,
		backlog = 8,
		setup = function() end,
		after = function(sig: any, push: Push, again: () -> ())
			listen(sig, push, "A")
			again()
		end,
		want = { "A:a", "A:b", "A:c" },
	},
	{
		name = "a replay (draining) holds the messages even with one listener; after it, the listener gets them",
		client = true,
		backlog = 8,
		setup = function(sig: any, push: Push)
			ClientSignal.deliver(sig, "x") -- buffered before the first Connect
			listen(sig, push, "A") -- starts the deferred replay: draining until it ran
		end,
		after = function(_: any, _: Push, again: () -> ())
			task.wait()
			again()
		end,
		want = { "A:x", "A:a", "A:b", "A:c" },
	},
}

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeEach(function()
		Loren.Testing.Reset({ Offline = true }) -- also reopens the Backlog window
	end)
	t.afterEach(function()
		for key in gates do
			open(key)
		end
		Log._reset()
	end)
	t.afterAll(function()
		Loren.Testing.Reset()
	end)

	describe("one listener (O12): the same trail as the full walk", function()
		for _, sc in SCENARIOS do
			for _, server in { false, true } do
				if (server and sc.client) or (not server and sc.server) then
					continue
				end
				local side = if server then "ServerEvent" else "ClientSignal"
				it(side .. ": " .. sc.name, function()
					local walked = play(server, false, sc)
					local solo = play(server, true, sc)
					expect(listenerLines(solo)).toEqual(sc.want)
					expect(solo).toEqual(walked)
				end)
			end
		end
	end)
end
