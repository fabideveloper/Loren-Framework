--!strict
--[[
	Signal unit spec (signals lane; IMPLEMENTATION.md sections 3.8 and 10). Runs on the server in Run
	mode or Play, before the fixture boot, and requires the runtime modules directly.

	One test prints on purpose: the LocalSignal listener-error test makes the engine print one red
	script error containing "[Signal.spec] intentional" (listener errors reach the engine output).
	Loren's own warnings are captured through Log._test.setSink and asserted, not printed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local Log = require(Runtime.Log)
local Signal = require(Runtime.Signal)

local LocalSignal = Signal.LocalSignal
local ClientSignal = Signal.ClientSignal
local ServerEvent = Signal.ServerEvent
local T = Signal._test

local PREFIX = "(LORENঌ) "
local CLIENT_FIRE = "Signals are server-to-client; fire ClientEvents from the client"
local EVENT_FIRE = "ClientEvents are client-to-server; use Signals to send to clients"
local INTENTIONAL = "[Signal.spec] intentional listener error (expected in the output)"

-- Stand-in player for ServerEvent specs (no players are assumed).
local PLAYER = { UserId = 4242, Name = "SignalSpecPlayer" } :: any

-- Returns a listener that appends its first argument to `got`, and `got`.
local function collector(): ((...any) -> (), { any })
	local got = {}
	local function listener(...: any)
		table.insert(got, (...))
	end
	return listener, got
end

local function errorText(fn: () -> ()): string
	local ok, err = pcall(fn :: any)
	assert(not ok, "expected an error")
	return tostring(err)
end

-- Resets Log (full budget) and captures its warning lines instead of printing them.
local function captureWarnings(studio: boolean?): { string }
	local lines: { string } = {}
	Log._reset()
	Log._test.setSink(nil, function(line: string)
		table.insert(lines, line)
	end)
	if studio ~= nil then
		Log._test.setStudio(studio)
	end
	return lines
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)
	t.afterAll(function()
		Signal._reset()
		Loren.Testing.Reset()
	end)
	t.beforeEach(function()
		Signal._reset()
	end)
	t.afterEach(function()
		Signal._reset()
		Log._reset() -- restores the output sinks a test may have captured
	end)

	describe("Signal.spawn", function()
		it("runs the function before returning, with every argument including nil holes", function()
			local packed: any = nil
			Signal.spawn(function(...: any)
				packed = table.pack(...)
			end, nil, 2, nil)
			expect(packed).never.toBeNil()
			expect(packed.n).toBe(3)
			expect(packed[1]).toBeNil()
			expect(packed[2]).toBe(2)
			expect(packed[3]).toBeNil()
		end)

		it("reuses one runner thread for calls that do not yield", function()
			local seen = {}
			local function record()
				table.insert(seen, coroutine.running())
			end
			Signal.spawn(record)
			Signal.spawn(record)
			Signal.spawn(record)
			expect(seen[2]).toBe(seen[1])
			expect(seen[3]).toBe(seen[1])
			expect(seen[1]).never.toBe(coroutine.running())
			expect(T.idleRunners()).toBe(1)
		end)

		it("reuses pooled runners for nested spawns, so no thread is created per nested call", function()
			local inner = {}
			local function innerFn()
				table.insert(inner, coroutine.running())
			end
			local function outerFn()
				Signal.spawn(innerFn)
			end
			Signal.spawn(outerFn)
			Signal.spawn(outerFn)
			Signal.spawn(outerFn)
			expect(inner[2]).toBe(inner[1])
			expect(inner[3]).toBe(inner[1])
			expect(T.idleRunners()).toBe(2)
		end)

		it("gives a yielding call its own runner and pools that runner again when it finishes", function()
			local slow: thread? = nil
			local fast: thread? = nil
			Signal.spawn(function()
				slow = coroutine.running()
				task.wait(0.05)
			end)
			Signal.spawn(function()
				fast = coroutine.running()
			end)
			expect(slow).never.toBeNil()
			expect(fast).never.toBe(slow)
			task.wait(0.2)
			expect(T.topRunner()).toBe(slow)
		end)

		it("closes pooled runners on _reset", function()
			Signal.spawn(function() end)
			local runner = T.topRunner()
			expect(runner).never.toBeNil()
			Signal._reset()
			expect(T.idleRunners()).toBe(0)
			expect(coroutine.status(runner :: thread)).toBe("dead")
		end)
	end)

	describe("listeners (LocalSignal)", function()
		it("run in connection order with every argument", function()
			local sig = LocalSignal.new()
			local order = {}
			for i = 1, 5 do
				sig:Connect(function(a: any, b: any, c: any, ...: any)
					table.insert(order, { i, a, b, c, select("#", ...) })
				end)
			end
			sig:Fire("x", nil, 3)
			expect(#order).toBe(5)
			for i = 1, 5 do
				expect(order[i][1]).toBe(i)
				expect(order[i][2]).toBe("x")
				expect(order[i][3]).toBeNil()
				expect(order[i][4]).toBe(3)
				expect(order[i][5]).toBe(0)
			end
		end)

		it("skip a listener disconnected earlier in the same fire", function()
			local sig = LocalSignal.new()
			local calls = {}
			local connB: any
			sig:Connect(function()
				table.insert(calls, "A")
				connB:Disconnect()
			end)
			connB = sig:Connect(function()
				table.insert(calls, "B")
			end)
			sig:Connect(function()
				table.insert(calls, "C")
			end)
			sig:Fire()
			expect(calls).toEqual({ "A", "C" })
			expect(connB.Connected).toBe(false)
		end)

		it("run a listener connected during a fire only from the next fire", function()
			local sig = LocalSignal.new()
			local late = 0
			local added = false
			sig:Connect(function()
				if not added then
					added = true
					sig:Connect(function()
						late += 1
					end)
				end
			end)
			sig:Fire()
			expect(late).toBe(0)
			sig:Fire()
			expect(late).toBe(1)
		end)

		it("stop at the fire's last listener even when that tail is disconnected mid-fire", function()
			local sig = LocalSignal.new()
			local calls = {}
			local first = true
			local connB: any
			sig:Connect(function()
				table.insert(calls, "A")
				if first then
					first = false
					connB.Disconnect() -- the tail at fire start
					sig:Connect(function()
						table.insert(calls, "C")
					end)
				end
			end)
			connB = sig:Connect(function()
				table.insert(calls, "B")
			end)
			sig:Fire()
			expect(calls).toEqual({ "A" })
			sig:Fire()
			expect(calls).toEqual({ "A", "A", "C" })
		end)

		it("keep walking after a listener disconnects itself", function()
			local sig = LocalSignal.new()
			local calls = {}
			local selfConn: any
			selfConn = sig:Connect(function()
				table.insert(calls, "self")
				selfConn:Disconnect()
			end)
			sig:Connect(function()
				table.insert(calls, "next")
			end)
			sig:Fire()
			sig:Fire()
			expect(calls).toEqual({ "self", "next", "next" })
		end)

		it("Once runs exactly once and is disconnected before it is called", function()
			-- (no expect inside listeners: they run on a runner thread, not the test thread)
			local sig = LocalSignal.new()
			local count = 0
			local received: any = nil
			local connectedInside: boolean? = nil
			local conn: any
			conn = sig:Once(function(v: any)
				count += 1
				received = v
				connectedInside = conn.Connected
			end)
			sig:Fire(1)
			sig:Fire(2)
			expect(count).toBe(1)
			expect(received).toBe(1)
			expect(connectedInside).toBe(false)
			expect(T.listeners(sig)).toBe(0)
		end)

		it("Once runs exactly once when an earlier listener re-fires the signal", function()
			local sig = LocalSignal.new()
			local depth = 0
			local onceCount = 0
			sig:Connect(function()
				depth += 1
				if depth == 1 then
					sig:Fire()
				end
			end)
			sig:Once(function()
				onceCount += 1
			end)
			sig:Fire()
			expect(depth).toBe(2)
			expect(onceCount).toBe(1)
		end)

		it("Once runs exactly once when it re-fires the signal itself", function()
			local sig = LocalSignal.new()
			local onceCount = 0
			local other = 0
			sig:Once(function()
				onceCount += 1
				sig:Fire()
			end)
			sig:Connect(function()
				other += 1
			end)
			sig:Fire()
			expect(onceCount).toBe(1)
			expect(other).toBe(2)
		end)

		it("Wait yields until the next fire and returns its arguments, nil holes included", function()
			local sig = LocalSignal.new()
			task.delay(0.05, function()
				sig:Fire(1, nil, 3)
			end)
			local packed = table.pack(sig:Wait())
			expect(packed.n).toBe(3)
			expect(packed[1]).toBe(1)
			expect(packed[2]).toBeNil()
			expect(packed[3]).toBe(3)
			expect(T.listeners(sig)).toBe(0)
			expect(function()
				sig:Fire(4) -- nothing is waiting any more
			end).never.toThrow()
		end)

		it("DisconnectAll disconnects every connection, and later Connects still work", function()
			local sig = LocalSignal.new()
			local a, b = t.spy(), t.spy()
			local ca = sig:Connect(a.fn)
			local cb = sig:Connect(b.fn)
			sig:DisconnectAll()
			expect(ca.Connected).toBe(false)
			expect(cb.Connected).toBe(false)
			sig:Fire()
			expect(a.count).toBe(0)
			expect(b.count).toBe(0)
			ca.Disconnect() -- still safe
			local c = t.spy()
			sig:Connect(c.fn)
			sig:Fire()
			expect(c.count).toBe(1)
			expect(T.listeners(sig)).toBe(1)
		end)

		it("DisconnectAll during a fire stops the listeners after it", function()
			local sig = LocalSignal.new()
			local later = t.spy()
			sig:Connect(function()
				sig:DisconnectAll()
			end)
			sig:Connect(later.fn)
			sig:Fire()
			expect(later.count).toBe(0)
		end)

		it("Destroy disconnects every connection", function()
			local sig = LocalSignal.new()
			local s = t.spy()
			local conn = sig:Connect(s.fn)
			sig:Destroy()
			sig:Fire()
			expect(s.count).toBe(0)
			expect(conn.Connected).toBe(false)
		end)

		it("Disconnect works with '.' and ':', is idempotent and is per connection", function()
			local sig = LocalSignal.new()
			local s = t.spy()
			local c1 = sig:Connect(s.fn)
			local c2 = sig:Connect(s.fn) -- the same function twice: two connections
			c1.Disconnect()
			c1:Disconnect()
			c1.Destroy()
			expect(c1.Connected).toBe(false)
			expect(c2.Connected).toBe(true)
			sig:Fire()
			expect(s.count).toBe(1)
			c2:Destroy()
			c2.Disconnect()
			sig:Fire()
			expect(s.count).toBe(1)
			expect(T.listeners(sig)).toBe(0)
		end)

		it("reuse one runner across listeners and fires when nothing yields", function()
			local sig = LocalSignal.new()
			local threads = {}
			local function record()
				table.insert(threads, coroutine.running())
			end
			sig:Connect(record)
			sig:Connect(record)
			sig:Fire()
			sig:Fire()
			expect(#threads).toBe(4)
			for i = 2, 4 do
				expect(threads[i]).toBe(threads[1])
			end
			expect(threads[1]).never.toBe(coroutine.running())
		end)

		it("isolate a yielding listener: the fire returns and later listeners run first", function()
			local sig = LocalSignal.new()
			local order = {}
			sig:Connect(function()
				task.wait(0.05)
				table.insert(order, "slow")
			end)
			sig:Connect(function()
				table.insert(order, "fast")
			end)
			sig:Fire()
			expect(order).toEqual({ "fast" })
			task.wait(0.2)
			expect(order).toEqual({ "fast", "slow" })
		end)

		it("report a listener error to the output, still run later listeners and replace the runner", function()
			local sig = LocalSignal.new()
			local after = t.spy()
			sig:Connect(function()
				error(INTENTIONAL)
			end)
			sig:Connect(after.fn)
			Signal.spawn(function() end) -- pool exactly one runner
			local runner = T.topRunner()
			expect(runner).never.toBeNil()
			sig:Fire()
			expect(after.count).toBe(1)
			expect(coroutine.status(runner :: thread)).toBe("dead")
			expect(T.topRunner()).never.toBe(runner)
		end)

		it("raise a Loren error for '.' calls and non-function listeners", function()
			local sig = LocalSignal.new() :: any
			expect(function()
				sig.Connect(function() end)
			end).toThrow("must be called with ':'")
			expect(function()
				sig.Fire(1)
			end).toThrow("must be called with ':'")
			expect(function()
				sig:Connect(nil)
			end).toThrow("expects a function")
			expect(function()
				sig:Once(t.spy()) -- a callable table is not a function
			end).toThrow("expects a function")
			local text = errorText(function()
				sig:Connect(123)
			end)
			expect(string.find(text, PREFIX, 1, true)).never.toBeNil()
		end)
	end)

	describe("ClientSignal backlog", function()
		it("buffers before the first Connect and replays deferred, in order, with nil holes", function()
			local sig = ClientSignal.new("SignalSpec", "Boot", 8)
			ClientSignal.deliver(sig, 1, "a")
			ClientSignal.deliver(sig, 2, nil)
			ClientSignal.deliver(sig, 3, "c")
			local got: { any } = {}
			sig:Connect(function(...: any)
				table.insert(got, table.pack(...))
			end)
			expect(#got).toBe(0) -- never replayed inside Connect
			expect(T.backlog(sig).draining).toBe(true)
			task.wait()
			expect(#got).toBe(3)
			expect(got[1][1]).toBe(1)
			expect(got[1][2]).toBe("a")
			expect(got[2].n).toBe(2)
			expect(got[2][2]).toBeNil()
			expect(got[3][2]).toBe("c")
			expect(T.backlog(sig).draining).toBe(false)
			expect(T.pumpScheduled()).toBe(false)
		end)

		it("appends deliveries that arrive before the replay behind the backlog, then delivers live", function()
			local sig = ClientSignal.new("SignalSpec", "Appends", 8)
			local listener, got = collector()
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			sig:Connect(listener)
			ClientSignal.deliver(sig, 3) -- live, but the replay has not run yet
			expect(#got).toBe(0)
			task.wait()
			expect(got).toEqual({ 1, 2, 3 })
			ClientSignal.deliver(sig, 4) -- after the replay: synchronous
			expect(got).toEqual({ 1, 2, 3, 4 })
		end)

		it("delivers what a listener delivers during the replay after the remaining backlog", function()
			local sig = ClientSignal.new("SignalSpec", "DuringDrain", 8)
			local got = {}
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			sig:Connect(function(v: any)
				table.insert(got, v)
				if v == 1 then
					ClientSignal.deliver(sig, "x")
				end
			end)
			task.wait()
			expect(got).toEqual({ 1, 2, "x" } :: { any })
		end)

		it("replays to every listener connected before the replay runs", function()
			local sig = ClientSignal.new("SignalSpec", "Many", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			local la, gotA = collector()
			local lb, gotB = collector()
			sig:Connect(la)
			sig:Connect(lb)
			task.wait()
			expect(gotA).toEqual({ 1, 2 })
			expect(gotB).toEqual({ 1, 2 })
		end)

		it("gives a listener connected during the replay only the entries after its Connect", function()
			local sig = ClientSignal.new("SignalSpec", "JoinDuringDrain", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			ClientSignal.deliver(sig, 3)
			local late, gotLate = collector()
			local gotFirst = {}
			sig:Connect(function(v: any)
				table.insert(gotFirst, v)
				if v == 1 then
					sig:Connect(late)
				end
			end)
			task.wait()
			expect(gotFirst).toEqual({ 1, 2, 3 })
			expect(gotLate).toEqual({ 2, 3 })
			expect(T.pumpScheduled()).toBe(false)
		end)

		it("keeps at most Backlog entries, dropping the oldest, counting them and warning once", function()
			local lines = captureWarnings(true)
			local sig = ClientSignal.new("SignalSpec", "Capped", 3)
			for i = 1, 5 do
				ClientSignal.deliver(sig, i)
			end
			expect(T.backlog(sig).size).toBe(3)
			expect(Signal.stats().backlogDropped).toBe(2)
			expect(#lines).toBe(1)
			expect(lines[1]).toContain(PREFIX .. "SignalSpec.Signals.Capped: the backlog (3) filled up")
			local listener, got = collector()
			sig:Connect(listener)
			task.wait()
			expect(got).toEqual({ 3, 4, 5 })
		end)

		it("gives a first Once exactly one entry", function()
			local sig = ClientSignal.new("SignalSpec", "Once", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			ClientSignal.deliver(sig, 3)
			local s = t.spy()
			sig:Once(s.fn)
			task.wait()
			expect(s.count).toBe(1)
			expect(s.calls[1][1]).toBe(1)
		end)

		it("resumes a first Wait with the first entry", function()
			local sig = ClientSignal.new("SignalSpec", "Wait", 8)
			ClientSignal.deliver(sig, "first", 1)
			ClientSignal.deliver(sig, "second", 2)
			local a, b = sig:Wait()
			expect(a).toBe("first")
			expect(b).toBe(1)
		end)

		it("does not buffer with Backlog = 0 (1.5.1 behavior)", function()
			local sig = ClientSignal.new("SignalSpec", "Zero", 0)
			ClientSignal.deliver(sig, 1)
			local s = t.spy()
			sig:Connect(s.fn)
			task.wait()
			expect(s.count).toBe(0)
			ClientSignal.deliver(sig, 2)
			expect(s.count).toBe(1)
		end)

		it("is never re-armed after the replay", function()
			local sig = ClientSignal.new("SignalSpec", "Rearm", 8)
			ClientSignal.deliver(sig, 1)
			local first = t.spy()
			local conn = sig:Connect(first.fn)
			task.wait()
			expect(first.count).toBe(1)
			conn:Disconnect()
			ClientSignal.deliver(sig, 2) -- no listener: dropped
			local second = t.spy()
			sig:Connect(second.fn)
			task.wait()
			expect(second.count).toBe(0)
			expect(T.backlog(sig).buffering).toBe(false)
		end)

		it("stops buffering at a first Connect that finds an empty backlog", function()
			local sig = ClientSignal.new("SignalSpec", "Empty", 8)
			local conn = sig:Connect(function() end)
			conn:Disconnect()
			ClientSignal.deliver(sig, 1)
			local s = t.spy()
			sig:Connect(s.fn)
			task.wait()
			expect(s.count).toBe(0)
			expect(T.backlog(sig).size).toBe(0)
		end)

		it("discards the backlog of never-connected signals when the window ends", function()
			ClientSignal.startWindow(0.1)
			local early = ClientSignal.new("SignalSpec", "Early", 8)
			ClientSignal.deliver(early, 1)
			local connected = ClientSignal.new("SignalSpec", "Connected", 8)
			ClientSignal.deliver(connected, 1)
			local sc = t.spy()
			connected:Connect(sc.fn)
			task.wait(0.3)
			expect(T.windowClosed()).toBe(true)
			expect(T.backlog(early).size).toBe(0)
			local se = t.spy()
			early:Connect(se.fn)
			task.wait()
			expect(se.count).toBe(0)
			expect(sc.count).toBe(1)
			local late = ClientSignal.new("SignalSpec", "Late", 8) -- created after the window
			ClientSignal.deliver(late, 1)
			expect(T.backlog(late).buffering).toBe(false)
			expect(T.backlog(late).size).toBe(0)
		end)

		it("ends the window at once for 0 seconds", function()
			local sig = ClientSignal.new("SignalSpec", "WindowZero", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.startWindow(0)
			expect(T.windowClosed()).toBe(true)
			expect(T.backlog(sig).buffering).toBe(false)
			expect(T.backlog(sig).size).toBe(0)
		end)

		it("restarts the window: a second startWindow cancels the first timer", function()
			local sig = ClientSignal.new("SignalSpec", "Restart", 8)
			ClientSignal.startWindow(0.05)
			ClientSignal.startWindow(30)
			ClientSignal.deliver(sig, 1)
			task.wait(0.2)
			expect(T.windowClosed()).toBe(false)
			expect(T.backlog(sig).buffering).toBe(true)
			local listener, got = collector()
			sig:Connect(listener)
			task.wait()
			expect(got).toEqual({ 1 })
		end)

		it("replays to a first Once (one entry) and a Connect made before the replay (every entry)", function()
			local sig = ClientSignal.new("SignalSpec", "OnceAndConnect", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			local once = t.spy()
			sig:Once(once.fn)
			local listener, got = collector()
			sig:Connect(listener)
			task.wait()
			expect(once.count).toBe(1)
			expect(once.calls[1][1]).toBe(1)
			expect(got).toEqual({ 1, 2 })
			expect(T.listeners(sig)).toBe(1)
		end)

		it("clamps Backlog: 0xFFFF keeps the latest entry, larger values keep 1024", function()
			captureWarnings() -- the dropped entry warns once in Studio
			local latest = ClientSignal.new("SignalSpec", "Latest", 0xFFFF)
			expect(T.backlog(latest).cap).toBe(1)
			ClientSignal.deliver(latest, 1)
			ClientSignal.deliver(latest, 2)
			local listener, got = collector()
			latest:Connect(listener)
			task.wait()
			expect(got).toEqual({ 2 })
			expect(T.backlog(ClientSignal.new("SignalSpec", "Huge", 5000)).cap).toBe(1024)
			expect(T.backlog(ClientSignal.new("SignalSpec", "Negative", -3)).cap).toBe(0)
			expect(T.backlog(ClientSignal.new("SignalSpec", "NaN", 0 / 0)).cap).toBe(0)
		end)

		it("stops a replay when Signal._reset runs inside a listener", function()
			local sig = ClientSignal.new("SignalSpec", "Reset", 8)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			ClientSignal.deliver(sig, 3)
			local got = {}
			sig:Connect(function(v: any)
				table.insert(got, v)
				if v == 1 then
					Signal._reset()
				end
			end)
			task.wait()
			expect(got).toEqual({ 1 })
			expect(T.pumpScheduled()).toBe(false)
			expect(T.listeners(sig)).toBe(0)
		end)

		it("DisconnectAll disconnects every connection", function()
			local sig = ClientSignal.new("SignalSpec", "DisconnectAll", 0)
			local s = t.spy()
			local conn = sig:Connect(s.fn)
			sig:DisconnectAll()
			ClientSignal.deliver(sig, 1)
			expect(s.count).toBe(0)
			expect(conn.Connected).toBe(false)
		end)

		it("raises the wrong-side error from Fire, FireAll, FireFor and FireExcept", function()
			local sig = ClientSignal.new("SignalSpec", "WrongSide", 0) :: any
			for _, method in { "Fire", "FireAll", "FireFor", "FireExcept" } do
				local text = errorText(function()
					sig[method](sig, 1)
				end)
				expect(text).toContain(PREFIX .. CLIENT_FIRE)
			end
		end)
	end)

	describe("ServerEvent", function()
		it("passes (player, ...) to listeners in connection order", function()
			local ev = ServerEvent.new("SignalSpec", "Ping")
			local order: { { any } } = {}
			ev:Connect(function(player: any, ...: any)
				local entry: { any } = { "A", player, select("#", ...), ... }
				table.insert(order, entry)
			end)
			ev:Connect(function(player: any, ...: any)
				local entry: { any } = { "B", player, select("#", ...), ... }
				table.insert(order, entry)
			end)
			ServerEvent.deliver(ev, PLAYER, 1, nil)
			expect(#order).toBe(2)
			expect(order[1][1]).toBe("A")
			expect(order[1][2]).toBe(PLAYER)
			expect(order[1][3]).toBe(2)
			expect(order[1][4]).toBe(1)
			expect(order[2][1]).toBe("B")
		end)

		it("supports Once and Wait (Wait returns the player first)", function()
			local ev = ServerEvent.new("SignalSpec", "OnceWait")
			local once = t.spy()
			ev:Once(once.fn)
			ServerEvent.deliver(ev, PLAYER, "a")
			ServerEvent.deliver(ev, PLAYER, "b")
			expect(once.count).toBe(1)
			expect(once.calls[1][1]).toBe(PLAYER)
			expect(once.calls[1][2]).toBe("a")
			task.delay(0.05, function()
				ServerEvent.deliver(ev, PLAYER, "c", nil)
			end)
			local packed = table.pack(ev:Wait())
			expect(packed.n).toBe(3)
			expect(packed[1]).toBe(PLAYER)
			expect(packed[2]).toBe("c")
			expect(T.listeners(ev)).toBe(0)
		end)

		it("isolates listener errors (xpcall): later listeners run and the runner survives", function()
			local lines = captureWarnings()
			local ev = ServerEvent.new("SignalSpec", "Isolated")
			local after = t.spy()
			ev:Connect(function()
				error(INTENTIONAL)
			end)
			ev:Connect(after.fn)
			Signal.spawn(function() end) -- pool exactly one runner
			local runner = T.topRunner()
			expect(function()
				ServerEvent.deliver(ev, PLAYER, 1)
			end).never.toThrow()
			expect(after.count).toBe(1)
			expect(T.topRunner()).toBe(runner)
			expect(coroutine.status(runner :: thread)).toBe("suspended")
			expect(T.eventLog(ev)).toEqual({ logged = 1, suppressed = 0 })
			expect(#lines).toBe(1)
			expect(lines[1]).toContain(PREFIX .. "SignalSpec.ClientEvents.Isolated listener failed for uid=4242: ")
			expect(lines[1]).toContain(INTENTIONAL)
		end)

		it("logs listener errors at most once per event per 10 s and counts the rest", function()
			local lines = captureWarnings()
			local now = 1000
			T.setClock(function()
				return now
			end)
			local ev = ServerEvent.new("SignalSpec", "Throttled")
			ev:Connect(function()
				error(INTENTIONAL)
			end)
			ServerEvent.deliver(ev, PLAYER)
			expect(T.eventLog(ev)).toEqual({ logged = 1, suppressed = 0 })
			now = 1005
			ServerEvent.deliver(ev, PLAYER)
			ServerEvent.deliver(ev, PLAYER)
			expect(T.eventLog(ev)).toEqual({ logged = 1, suppressed = 2 })
			expect(#lines).toBe(1)
			now = 1010.5
			ServerEvent.deliver(ev, PLAYER)
			expect(T.eventLog(ev)).toEqual({ logged = 2, suppressed = 0 })
			expect(#lines).toBe(2)
			expect(lines[2]).toContain("SignalSpec.ClientEvents.Throttled listener failed for uid=4242 (+2 earlier")
			-- the throttle is per event
			local other = ServerEvent.new("SignalSpec", "Other")
			other:Connect(function()
				error(INTENTIONAL)
			end)
			now = 1011
			ServerEvent.deliver(other, PLAYER)
			ServerEvent.deliver(ev, PLAYER)
			expect(T.eventLog(other)).toEqual({ logged = 1, suppressed = 0 })
			expect(T.eventLog(ev)).toEqual({ logged = 2, suppressed = 1 })
			expect(#lines).toBe(3)
			expect(lines[3]).toContain("SignalSpec.ClientEvents.Other listener failed")
		end)

		it("raises the wrong-side error from Fire", function()
			local ev = ServerEvent.new("SignalSpec", "WrongSide") :: any
			for _, method in { "Fire", "FireAll", "FireFor", "FireExcept" } do
				local text = errorText(function()
					ev[method](ev, 1)
				end)
				expect(text).toContain(PREFIX .. EVENT_FIRE)
			end
		end)

		it("DisconnectAll disconnects every connection", function()
			local ev = ServerEvent.new("SignalSpec", "DisconnectAll")
			local s = t.spy()
			ev:Connect(s.fn)
			ev:Once(s.fn)
			ev:DisconnectAll()
			ServerEvent.deliver(ev, PLAYER)
			expect(s.count).toBe(0)
			expect(T.listeners(ev)).toBe(0)
		end)
	end)

	describe("Signal.stats", function()
		it("returns a fresh table that _reset zeroes", function()
			captureWarnings() -- the dropped entry warns once in Studio
			local sig = ClientSignal.new("SignalSpec", "Stats", 1)
			ClientSignal.deliver(sig, 1)
			ClientSignal.deliver(sig, 2)
			local a = Signal.stats()
			expect(a.backlogDropped).toBe(1)
			expect(Signal.stats()).never.toBe(a)
			Signal._reset()
			expect(Signal.stats().backlogDropped).toBe(0)
		end)
	end)
end
