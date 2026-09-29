--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")
local ServerScriptService = game:GetService("ServerScriptService")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local C = require(Runtime.Constants)
local Codec = require(Runtime.Codec)
local Schema = require(Runtime.Schema)
local Errors = require(Runtime.Errors)
local Config = require(Runtime.Config)
local Log = require(Runtime.Log)
local Signal = require(Runtime.Signal)
local Calls = require(Runtime.Calls) :: any
local ClientNet = require(Runtime.ClientNet) :: any
local Server = ServerScriptService.LorenServer
local Routes = require(Server.Routes)
local Transport = require(Server.Transport)
local Outbox = require(Server.Outbox) :: any
local Dispatch = require(Server.Dispatch)
local ServerSignal = require(Server.ServerSignal)
local Limits = require(Server.Limits)
local Violations = require(Server.Violations)

local K = C.Kind
local T = Schema.T
local OP = C.Op
local V_ROUTE = C.Violation.Route
local PREFIX = C.PREFIX
local BOOM = "Delivery.spec: a listener failed on purpose (expected in the output)"

type Fire = { channel: string, player: any, frame: buffer, refs: { any }? }

local function noop(...: any) end

local now = 1000
local rt: any = nil
local byName: { [string]: any } = {}
local fires: { Fire } = {}
local c2s: { any } = {}
local gates: { [string]: thread } = {}
local trail: { string } = {}
local nextUid = 0
local seqN = 0

local function gate(key: string): ...any
	gates[key] = coroutine.running()
	return coroutine.yield()
end

local function open(key: string, ...: any)
	local th = gates[key]
	assert(th ~= nil, "no parked Gate call " .. key)
	gates[key] = nil
	task.spawn(th, ...)
end

local function cleanupGates()
	for _, th in gates do
		pcall(task.cancel, th)
	end
	table.clear(gates)
end

local function member(kind: number, name: string, fn: any, spec: any): any
	return { name = name, kind = kind, fn = fn, spec = spec, middleware = nil, colon = false }
end

local function services(): any
	local M, E, S = K.Method, K.Event, K.Signal
	local members: { any } = {
		member(M, "Echo", function(_: any, _: any, ...: any): ...any
			return ...
		end),
		member(M, "Gate", function(_: any, _: any, key: any): any
			local mode, value = gate(key)
			if mode == "err" then
				return Errors.reject(value)
			end
			return value
		end),
		member(M, "Note", function(_: any, _: any, tag: any): any
			table.insert(trail, "call " .. tostring(tag))
			return tag
		end),
		member(M, "Tight", function(_: any, _: any, tag: any): any
			table.insert(trail, "tight " .. tostring(tag))
			return tag
		end, Schema.method({ RateLimit = { 1, 1 } })),
		member(E, "Ev"),
		member(E, "Ord", nil, Schema.event(T.string(32), { Unreliable = true, Ordered = true })),
		member(S, "Late", nil, Schema.signal({ Backlog = 8 })),
		member(S, "Need", nil, Schema.signal(T.string(32), T.Instance())),
		member(S, "Other"),
		member(S, "Sig"),
	}
	local client: { [string]: any } = {}
	for _, m: any in members do
		if m.kind == M then
			client[m.name] = m.fn
		end
	end
	local module = { Client = client, Signals = {}, ClientEvents = {}, Middleware = {} }
	return {
		{
			name = "S",
			record = { name = "S", kind = "Service", module = module, instance = script, path = "S", deps = {} },
			module = module,
			client = client,
			members = members,
			networked = true,
		},
	}
end

local function resetServer()
	Transport._reset()
	Routes._reset()
	Dispatch._reset()
	Outbox._reset()
	ServerSignal._reset()
	Limits._reset()
	Violations._reset()
end

local function setup()
	cleanupGates()
	Loren.Testing.Reset({ Offline = true })
	resetServer()
	Log._test.setSink(noop, noop)
	local c = Config.get()
	Limits.configure(c)
	Violations.configure(c)
	local report: any = { side = "Server", errors = {}, warnings = {} }
	rt = Routes.build(services(), c, report)
	assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
	byName = {}
	for _, r in rt.routes do
		byName[r.member] = r
	end
	fires = {}
	c2s = {}
	trail = {}
	Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
		table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
	end)
	now = 1000
	Transport._test.setClock(function(): number
		return now
	end)
	Transport._test.attach(rt)
	Dispatch._test.setForwardErrors(false)
end

local function frames(n: number)
	for _ = 1, n do
		task.wait()
	end
end

local function waitFor(predicate: () -> boolean, seconds: number)
	local deadline = os.clock() + seconds
	while not predicate() and os.clock() < deadline do
		task.wait()
	end
end

local function count(list: { string }, item: string): number
	local n = 0
	for _, v in list do
		if v == item then
			n += 1
		end
	end
	return n
end

local errorWatch: RBXScriptConnection? = nil

local function watchBoom(): { string }
	local reported: { string } = {}
	errorWatch = ScriptContext.Error:Connect(function(message: string)
		if string.find(message, BOOM, 1, true) then
			table.insert(reported, message)
		end
	end)
	return reported
end

local function stopWatch()
	local watch = errorWatch
	errorWatch = nil
	if watch then
		watch:Disconnect()
	end
end

local function captureWarnings(): { string }
	local lines: { string } = {}
	Log._reset()
	Log._test.setSink(noop, function(line: string)
		table.insert(lines, line)
	end)
	return lines
end

local function R(name: string): any
	local r = byName[name]
	assert(r ~= nil, "no route " .. name)
	return r
end

local function writerBytes(w: any): buffer
	local b = buffer.create(w.n)
	buffer.copy(b, 0, w.buf, 0, w.n)
	return b
end

local function frameOf(msgs: { buffer }, nrefs: number?): buffer
	local total = 5
	for _, m in msgs do
		assert(buffer.len(m) < 128, "test message too long for a 1-byte length")
		total += 1 + buffer.len(m)
	end
	seqN = (seqN + 1) % 65536
	local b = buffer.create(total)
	buffer.writeu16(b, 0, seqN)
	buffer.writeu16(b, 2, #msgs)
	buffer.writeu8(b, 4, nrefs or 0)
	local o = 5
	for _, m in msgs do
		buffer.writeu8(b, o, buffer.len(m))
		buffer.copy(b, o + 1, m, 0, buffer.len(m))
		o += 1 + buffer.len(m)
	end
	return b
end

local function callMsg(name: string, callId: number, ...: any): buffer
	local r = R(name)
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	Codec.writeU16(w, callId)
	assert(r.args.encode(w, select("#", ...), ...) == 0, "encode failed")
	return writerBytes(w)
end

local function eventMsg(name: string, ...: any): (buffer, { any })
	local r = R(name)
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	assert(r.args.encode(w, select("#", ...), ...) == 0, "encode failed")
	return writerBytes(w), table.move(w.refs, 1, w.nrefs, 1, {})
end

local function ev(tag: string): buffer
	return (eventMsg("Ev", tag))
end

local function ordMsg(seq: number, tag: string): buffer
	local r = R("Ord")
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	Codec.writeU16(w, seq)
	assert(r.args.encode(w, 1, tag) == 0, "encode failed")
	return writerBytes(w)
end

local function signalHead(name: string): buffer
	local w = Codec.newWriter(8, true)
	Codec.writeHead(w, R(name).id)
	return writerBytes(w)
end

local function hello(p: any)
	local m = buffer.create(2)
	buffer.writeu8(m, 0, OP.HELLO)
	buffer.writeu8(m, 1, C.PROTO)
	Transport._test.frame(false, p, frameOf({ m }), nil)
end

local function flush()
	Transport._test.flush()
end

local function st(p: any): any
	return Transport._test.state(p)
end

local function takeFires(p: any): { Fire }
	local mine: { Fire }, keep: { Fire } = {}, {}
	for _, f in fires do
		if f.player == p then
			table.insert(mine, f)
		else
			table.insert(keep, f)
		end
	end
	fires = keep
	return mine
end

local function newPlayer(helloNow: boolean?): any
	nextUid += 1
	local p: any = { UserId = nextUid, Name = "Player" .. nextUid }
	p.Kick = noop
	Transport._test.addPlayer(p)
	if helloNow ~= false then
		hello(p)
		flush()
		takeFires(p)
	end
	return p
end

local function argvClear(): boolean
	local argv = Transport._test.argv()
	for i = 1, 64 do
		if argv[i] ~= nil then
			return false
		end
	end
	return true
end

local function toClient(p: any): number
	flush()
	local list = takeFires(p)
	for _, f in list do
		ClientNet._test.receive(f.frame, f.refs, f.channel == "Unreliable")
	end
	return #list
end

local function toClientHiding(p: any, hidden: Instance): number
	flush()
	local list = takeFires(p)
	for _, f in list do
		local refs = f.refs
		local seen: { any }? = nil
		if refs then
			local kept: { any } = table.create(#refs)
			for k, ref in refs do
				if ref ~= hidden then
					kept[k] = ref
				end
			end
			seen = kept
		end
		ClientNet._test.receive(f.frame, seen, f.channel == "Unreliable")
	end
	return #list
end

local function toServer(p: any)
	ClientNet._test.flushNow()
	local list = c2s
	c2s = {}
	for _, f in list do
		Transport._test.frame(f.unreliable, p, f.frame, f.refs)
	end
end

local function connectClient(p: any)
	ClientNet._test.setFire(function(unreliable: boolean, frame: buffer, refs: { any }?)
		table.insert(c2s, { unreliable = unreliable, frame = frame, refs = refs })
	end)
	ClientNet._test.begin()
	hello(p)
	toClient(p)
	assert(#ClientNet.routes() == rt.count, "the client did not install the server's MANIFEST")
end

local function route(name: string): any
	return ClientNet.routes()[R(name).id]
end

local function client(): (any, any)
	local p = newPlayer(false)
	connectClient(p)
	return p, route("Sig").signal
end

local function fireAll(p: any, tags: { string })
	local sig = rt.signals.S.Sig
	for _, tag in tags do
		sig:Fire(p, tag)
	end
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeEach(function()
		setup()
	end)
	t.afterEach(function()
		stopWatch()
		cleanupGates()
		Log._reset()
	end)
	t.afterAll(function()
		cleanupGates()
		resetServer()
		Loren.Testing.Reset()
	end)

	describe("client: one delivery runner per frame", function()
		it("a yield in listener k delays neither listener k+1 nor later messages; nothing runs twice", function()
			local p, sig = client()
			local log: { string } = {}
			local threads: { [string]: thread } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				threads["1:" .. tag] = coroutine.running()
				if tag == "y" then
					task.wait()
					table.insert(log, "1:y resumed")
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
				threads["2:" .. tag] = coroutine.running()
				if tag == "z" then
					task.wait()
					table.insert(log, "2:z resumed")
				end
			end)
			fireAll(p, { "a", "y", "b", "z" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "1:a", "2:a", "1:y", "2:y", "1:b", "2:b", "1:z", "2:z" })
			expect(threads["2:a"]).toBe(threads["1:a"])
			expect(threads["1:y"]).toBe(threads["1:a"])
			expect(threads["2:y"]).never.toBe(threads["1:y"])
			expect(threads["2:z"]).toBe(threads["2:y"])
			expect(threads["1:a"]).never.toBe(coroutine.running())
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			waitFor(function(): boolean
				return #log >= 10
			end, 2)
			frames(3)
			expect(#log).toBe(10)
			expect(count(log, "1:y resumed")).toBe(1)
			expect(count(log, "2:z resumed")).toBe(1)
			for _, entry in { "1:a", "2:a", "1:y", "2:y", "1:b", "2:b", "1:z", "2:z" } do
				expect(count(log, entry)).toBe(1)
			end
		end)

		it("a listener error is reported as before (its runner dies with it); the rest of the frame runs", function()
			local p, sig = client()
			local reported = watchBoom()
			local log: { string } = {}
			local failed: thread? = nil
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "boom" then
					failed = coroutine.running()
					error(BOOM, 0)
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
			end)
			fireAll(p, { "a", "boom", "b" })
			toClient(p)
			expect(log).toEqual({ "1:a", "2:a", "1:boom", "2:boom", "1:b", "2:b" })
			expect(failed).never.toBeNil()
			expect(coroutine.status(failed :: thread)).toBe("dead")
			waitFor(function(): boolean
				return #reported > 0
			end, 2)
			stopWatch()
			expect(#reported).toBe(1)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
		end)

		it("Disconnect inside a listener (itself or a later one) holds for the rest of the frame", function()
			local p, sig = client()
			local log: { string } = {}
			local conn1: any, conn3: any
			conn1 = sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "x" then
					conn1:Disconnect()
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
				if tag == "y" then
					conn3.Disconnect()
				end
			end)
			conn3 = sig:Connect(function(tag: any)
				table.insert(log, "3:" .. tag)
			end)
			fireAll(p, { "a", "x", "y", "b" })
			toClient(p)
			expect(log).toEqual({ "1:a", "2:a", "3:a", "1:x", "2:x", "3:x", "2:y", "2:b" })
			expect(conn1.Connected).toBe(false)
			expect(conn3.Connected).toBe(false)
		end)

		it("Connect inside a listener: the new listener gets later messages of the frame, not this one", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "c" then
					sig:Connect(function(v: any)
						table.insert(log, "new:" .. v)
					end)
				end
			end)
			fireAll(p, { "a", "c", "d", "e" })
			toClient(p)
			expect(log).toEqual({ "1:a", "1:c", "1:d", "new:d", "1:e", "new:e" })
		end)

		it("Once and Wait during a frame: Once runs once; a Wait inside a listener gets the next message", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "WL " .. tag)
				if tag == "a" then
					local got = sig:Wait()
					table.insert(log, "WL got " .. tostring(got))
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "L " .. tag)
			end)
			local once = t.spy()
			sig:Once(once.fn)
			local waited: any = nil
			task.spawn(function()
				waited = table.pack(sig:Wait())
			end)
			fireAll(p, { "a", "b", "c" })
			toClient(p)
			expect(log).toEqual({ "WL a", "L a", "WL b", "L b", "WL got b", "WL c", "L c" })
			expect(once.count).toBe(1)
			expect(once.calls[1][1]).toBe("a")
			expect(waited).never.toBeNil()
			expect(waited.n).toBe(1)
			expect(waited[1]).toBe("a")
			expect(Signal._test.listeners(sig)).toBe(2)
			frames(2)
			expect(#log).toBe(7)
		end)

		it("Testing.Reset inside a listener stops the rest of the frame: later signals, replies and NOTICEs", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, tag)
				if tag == "reset" then
					Loren.Testing.Reset({ Offline = true })
				end
			end)
			local resolved = false
			local pending = ClientNet.call(route("Gate"), false, 1, "k")
			pending:andThen(function()
				resolved = true
			end, noop)
			toServer(p)
			fireAll(p, { "a", "reset" })
			open("k", "ok", "K")
			Outbox.notice(st(p), C.Notice.ShuttingDown, 0, 0)
			fireAll(p, { "after" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "a", "reset" })
			expect(resolved).toBe(false)
			expect(ClientNet._test.state().shuttingDown).toBe(false)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			frames(2)
			expect(log).toEqual({ "a", "reset" })
			expect(resolved).toBe(false)
		end)

		it("Testing.Reset in a listener that then yields: the takeover ends the message, the frame stops", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "reset" then
					Loren.Testing.Reset({ Offline = true })
					task.wait()
					table.insert(log, "1:reset resumed")
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
			end)
			fireAll(p, { "a", "reset", "after" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "1:a", "2:a", "1:reset" })
			expect(ClientNet.getStats().MessagesIn).toBe(0)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			waitFor(function(): boolean
				return #log >= 4
			end, 2)
			frames(2)
			expect(log).toEqual({ "1:a", "2:a", "1:reset", "1:reset resumed" })
		end)

		it("a takeover keeps the message's listener snapshot: one connected just before a yield waits", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "c" then
					sig:Connect(function(v: any)
						table.insert(log, "new:" .. v)
					end)
					task.wait()
					table.insert(log, "1:c resumed")
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
			end)
			fireAll(p, { "a", "c", "d" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "1:a", "2:a", "1:c", "2:c", "1:d", "2:d", "new:d" })
			waitFor(function(): boolean
				return #log >= 8
			end, 2)
			frames(2)
			expect(log[8]).toBe("1:c resumed")
			expect(#log).toBe(8)
		end)

		it("a runner parked in Wait, resumed by the next frame, delivers nothing more of its own frame", function()
			local p, sig = client()
			local other = route("Other").signal
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "WL " .. tag)
				if tag == "a" then
					local got = other:Wait()
					table.insert(log, "WL got " .. tostring(got))
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "L " .. tag)
			end)
			fireAll(p, { "a", "a2" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "WL a", "L a", "WL a2", "L a2" })
			local S = rt.signals.S
			S.Other:Fire(p, "x")
			S.Sig:Fire(p, "b")
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "WL a", "L a", "WL a2", "L a2", "WL got x", "WL b", "L b" })
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			frames(2)
			expect(#log).toBe(7)
		end)

		it("a yield and an error in one message: two takeovers in a row, each listener once, then the next", function()
			local p, sig = client()
			local reported = watchBoom()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "1:" .. tag)
				if tag == "y" then
					task.wait()
					table.insert(log, "1:y resumed")
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "2:" .. tag)
				if tag == "y" then
					error(BOOM, 0)
				end
			end)
			sig:Connect(function(tag: any)
				table.insert(log, "3:" .. tag)
			end)
			fireAll(p, { "y", "b" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "1:y", "2:y", "3:y", "1:b", "2:b", "3:b" })
			waitFor(function(): boolean
				return #log >= 7 and #reported >= 1
			end, 2)
			frames(2)
			stopWatch()
			expect(log[7]).toBe("1:y resumed")
			expect(#log).toBe(7)
			expect(#reported).toBe(1)
		end)
	end)

	describe("client: replies in their place", function()
		it("OK (also of a handler that yielded), a Try caller and signals keep frame order past a yield", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "sig " .. tag)
				if tag == "s1" then
					task.wait()
					table.insert(log, "s1 resumed")
				end
			end)
			local function onOk(v: any)
				table.insert(log, "ok " .. tostring(v))
			end
			local function onErr(m: any)
				table.insert(log, "err " .. tostring(m))
			end
			ClientNet.call(route("Gate"), false, 1, "g"):andThen(onOk, onErr)
			task.spawn(function()
				local ok, v = ClientNet.call(route("Gate"), true, 1, "t")
				table.insert(log, "try " .. tostring(ok) .. " " .. tostring(v))
			end)
			toServer(p)
			expect(gates.g).never.toBeNil()
			expect(gates.t).never.toBeNil()
			fireAll(p, { "s1" })
			open("g", "ok", "G")
			fireAll(p, { "s2" })
			ClientNet.call(route("Echo"), false, 1, "E"):andThen(onOk, onErr)
			toServer(p)
			fireAll(p, { "s3" })
			open("t", "ok", "T")
			fireAll(p, { "s4" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "sig s1", "ok G", "sig s2", "ok E", "sig s3", "try true T", "sig s4" })
			waitFor(function(): boolean
				return #log >= 8
			end, 2)
			frames(2)
			expect(log[8]).toBe("s1 resumed")
			expect(#log).toBe(8)
		end)

		it("a listener cancelling pending calls mid-frame: their later OK and ERR are late replies", function()
			local p, sig = client()
			local settled: { string } = {}
			local a = ClientNet.call(route("Gate"), false, 1, "a")
			a:andThen(function()
				table.insert(settled, "a ok")
			end, function()
				table.insert(settled, "a err")
			end)
			local b = ClientNet.call(route("Gate"), false, 1, "b")
			b:andThen(function()
				table.insert(settled, "b ok")
			end, function()
				table.insert(settled, "b err")
			end)
			toServer(p)
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, tag)
				if tag == "cancel" then
					a:cancel()
					b:cancel()
					task.wait()
					table.insert(log, "resumed")
				end
			end)
			local late = ClientNet.getStats().LateReplies
			fireAll(p, { "cancel" })
			open("a", "ok", "A")
			open("b", "err", "B")
			fireAll(p, { "z" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "cancel", "z" })
			expect(settled).toEqual({})
			expect(a:getStatus()).toBe("Cancelled")
			expect(b:getStatus()).toBe("Cancelled")
			expect(ClientNet.getStats().LateReplies - late).toBe(2)
			waitFor(function(): boolean
				return #log >= 3
			end, 2)
			frames(2)
			expect(log).toEqual({ "cancel", "z", "resumed" })
			expect(settled).toEqual({})
		end)

		it("an OK or ERR for a call a NOTICE released earlier in its frame drops the rest, as before B2", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, tag)
			end)
			local lines = captureWarnings()
			local seqA = ClientNet._test.state().relSeq
			local a = ClientNet.call(route("Echo"), false, 1, "A")
			a:catch(noop)
			Outbox.notice(st(p), C.Notice.FrameDropped, seqA, 1)
			toServer(p)
			fireAll(p, { "x1" })
			expect(toClient(p)).toBe(1)
			local okA, messageA = a:await()
			expect(okA).toBe(false)
			expect(tostring(messageA)).toContain("RateLimited")
			expect(log).toEqual({})
			expect(table.concat(lines, "\n")).toContain("OK for an unknown call id")
			local seqB = ClientNet._test.state().relSeq
			local b = ClientNet.call(route("Gate"), false, 1, "g")
			b:catch(noop)
			toServer(p)
			Outbox.notice(st(p), C.Notice.FrameDropped, seqB, 1)
			open("g", "err", "E")
			fireAll(p, { "x2" })
			expect(toClient(p)).toBe(1)
			local okB, messageB = b:await()
			expect(okB).toBe(false)
			expect(tostring(messageB)).toContain("RateLimited")
			expect(log).toEqual({})
			fireAll(p, { "x3" })
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "x3" })
		end)

		it("a bad OK rejects its call, then logs the abort, even after a Testing.Reset in its catch", function()
			client()
			local lines = captureWarnings()
			local function capture(line: string)
				table.insert(lines, line)
			end
			Calls._test.setNextId(900)
			local rejection: any = nil
			ClientNet.call(route("Echo"), false, 1, "x"):catch(function(message: any)
				rejection = message
				Loren.Testing.Reset({ Offline = true })
				Log._test.setSink(noop, capture)
			end)
			local frame = buffer.create(4)
			buffer.writeu8(frame, 0, OP.OK)
			buffer.writeu16(frame, 1, 901)
			buffer.writeu8(frame, 3, 1)
			ClientNet._test.receive(frame, nil)
			expect(rejection).never.toBeNil()
			expect(tostring(rejection)).toContain("InternalError")
			expect(#lines).toBe(1)
			expect(lines[1]).toContain("dropped the rest of a server frame (bad reply for S.Echo)")
		end)

		it("CallsRateLimited keeps a local RateLimited raised in the catch of a call a NOTICE dropped", function()
			local p = client()
			ClientNet._test.setClock(function(): number
				return now
			end)
			local seq = ClientNet._test.state().relSeq
			local dropped = ClientNet.call(route("Gate"), false, 1, "d")
			toServer(p)
			local first = ClientNet.call(route("Tight"), false, 1, "t1")
			expect(first:getStatus()).toBe("Started")
			local retried: any = nil
			dropped:catch(function()
				retried = ClientNet.call(route("Tight"), false, 1, "t2")
				retried:catch(noop)
			end)
			local base = ClientNet.getStats().CallsRateLimited
			Outbox.notice(st(p), C.Notice.FrameDropped, seq, 1)
			expect(toClient(p)).toBe(1)
			expect(dropped:getStatus()).toBe("Rejected")
			expect(retried).never.toBeNil()
			expect(retried:getStatus()).toBe("Rejected")
			expect(ClientNet.getStats().CallsRateLimited - base).toBe(2)
		end)
	end)

	describe("client: Backlog before the first Connect", function()
		it("buffers in frame order past a mid-frame Connect; replays deferred, then delivers live", function()
			local p = newPlayer(false)
			connectClient(p)
			local late = route("Late").signal
			local got: { string } = {}
			route("Other").signal:Connect(function(tag: any)
				table.insert(got, "other " .. tag)
				late:Connect(function(v: any)
					table.insert(got, "late " .. v)
				end)
			end)
			local S = rt.signals.S
			S.Late:Fire(p, "1")
			S.Late:Fire(p, "2")
			S.Other:Fire(p, "x")
			S.Late:Fire(p, "3")
			S.Late:Fire(p, "4")
			expect(toClient(p)).toBe(1)
			expect(got).toEqual({ "other x" })
			task.wait()
			expect(got).toEqual({ "other x", "late 1", "late 2", "late 3", "late 4" })
			S.Late:Fire(p, "5")
			toClient(p)
			expect(got[6]).toBe("late 5")
			expect(#got).toBe(6)
		end)

		it("a Backlog message in a run queues on the receiving thread (a throwing log sink: as before B2)", function()
			local p, sig = client()
			local late = route("Late").signal
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, tag)
			end)
			local failure = "Delivery.spec: the log sink failed on purpose"
			local lines: { string } = {}
			Log._reset()
			Log._test.setSink(noop, function(line: string)
				if string.find(line, "filled up", 1, true) then
					error(failure, 0)
				end
				table.insert(lines, line)
			end)
			local S = rt.signals.S
			for i = 1, 8 do
				S.Late:Fire(p, tostring(i))
			end
			S.Sig:Fire(p, "a")
			S.Late:Fire(p, "9")
			S.Sig:Fire(p, "b")
			local base = ClientNet.getStats()
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "a" })
			local stats = ClientNet.getStats()
			expect(stats.MessagesIn - base.MessagesIn).toBe(10)
			expect(stats.SignalsDropped - base.SignalsDropped).toBe(1)
			expect(Signal._test.backlog(late).size).toBe(7)
			expect(#lines).toBe(1)
			expect(lines[1]).toContain("a server frame failed to decode: " .. failure)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
		end)
	end)

	describe("client: every per-message effect at its message (as the one-pass decoder)", function()
		it("a listener sees MessagesIn and SignalsDropped as of its own message", function()
			local p, sig = client()
			local base = ClientNet.getStats()
			local log: { string } = {}
			local function note(what: string)
				local s = ClientNet.getStats()
				local m, l = s.MessagesIn - base.MessagesIn, s.SignalsDropped - base.SignalsDropped
				table.insert(log, string.format("%s m%d l%d", what, m, l))
			end
			sig:Connect(function(tag: any)
				note("Sig " .. tostring(tag))
			end)
			route("Need").signal:Connect(function(tag: any)
				note("Need " .. tostring(tag))
			end)
			local hid, vis = Instance.new("Folder"), Instance.new("Folder")
			local S = rt.signals.S
			S.Sig:Fire(p, "a")
			S.Need:Fire(p, "n1", hid)
			S.Sig:Fire(p, "b")
			S.Need:Fire(p, "n2", vis)
			S.Sig:Fire(p, "c")
			expect(toClientHiding(p, hid)).toBe(1)
			expect(log).toEqual({ "Sig a m1 l0", "Sig b m3 l1", "Need n2 m4 l1", "Sig c m5 l1" })
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			hid:Destroy()
			vis:Destroy()
		end)

		it("NOTICE effects keep their place among the listeners (FramesDropped, ShuttingDown)", function()
			local p, sig = client()
			local base = ClientNet.getStats().FramesDropped
			local log: { string } = {}
			sig:Connect(function(tag: any)
				local dropped = ClientNet.getStats().FramesDropped - base
				local closing = ClientNet._test.state().shuttingDown
				table.insert(log, string.format("%s d%d %s", tag, dropped, tostring(closing)))
			end)
			local S = rt.signals.S
			S.Sig:Fire(p, "a")
			Outbox.notice(st(p), C.Notice.UFrameDropped, 0, 2)
			S.Sig:Fire(p, "b")
			Outbox.notice(st(p), C.Notice.ShuttingDown, 0, 0)
			S.Sig:Fire(p, "c")
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "a d0 false", "b d2 false", "c d2 true" })
		end)

		it("a structural error is logged after the listeners of the messages before it", function()
			local p, sig = client()
			local order: { string } = {}
			Log._reset()
			Log._test.setSink(noop, function(line: string)
				table.insert(order, "log " .. line)
			end)
			sig:Connect(function(tag: any)
				table.insert(order, "sig " .. tostring(tag))
			end)
			rt.signals.S.Sig:Fire(p, "a")
			rt.signals.S.Sig:Fire(p, "b")
			flush()
			local list = takeFires(p)
			expect(#list).toBe(1)
			local good = list[1].frame
			local len = buffer.len(good)
			local bad = buffer.create(len + 1)
			buffer.copy(bad, 0, good, 0, len)
			buffer.writeu8(bad, len, 0xF7)
			ClientNet._test.receive(bad, list[1].refs)
			expect(#order).toBe(3)
			expect(order[1]).toBe("sig a")
			expect(order[2]).toBe("sig b")
			expect(order[3]).toContain("dropped the rest of a server frame (unexpected control op")
		end)

		it("a reply's call is looked up after the messages before it ran (a call made there is found)", function()
			local p, sig = client()
			local log: { string } = {}
			Calls._test.setNextId(700)
			sig:Connect(function(tag: any)
				table.insert(log, "sig " .. tostring(tag))
				if tag == "call" then
					ClientNet.call(route("Echo"), false, 1, "sent"):andThen(function(v: any)
						table.insert(log, "ok " .. tostring(v))
					end, noop)
				end
			end)
			rt.signals.S.Sig:Fire(p, "call")
			expect(Outbox.sendOk(st(p), R("Echo"), 701, 1, "reply")).toBe(0)
			rt.signals.S.Sig:Fire(p, "after")
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "sig call", "ok reply", "sig after" })
		end)

		it("a second reply for one call in a frame drops the rest after the first one ran", function()
			local p, sig = client()
			local log: { string } = {}
			sig:Connect(function(tag: any)
				table.insert(log, "sig " .. tostring(tag))
			end)
			local lines = captureWarnings()
			Calls._test.setNextId(800)
			ClientNet.call(route("Echo"), false, 1, "e"):andThen(function(v: any)
				table.insert(log, "ok " .. tostring(v))
			end, noop)
			local ps = st(p)
			expect(Outbox.sendOk(ps, R("Echo"), 801, 1, "one")).toBe(0)
			expect(Outbox.sendOk(ps, R("Echo"), 801, 1, "two")).toBe(0)
			rt.signals.S.Sig:Fire(p, "x")
			expect(toClient(p)).toBe(1)
			expect(log).toEqual({ "ok one" })
			expect(#lines).toBe(1)
			expect(lines[1]).toContain("OK for an unknown call id")
		end)
	end)

	describe("client: the tape after a burst", function()
		it("a 1000-message frame leaves nothing behind; the next 1-message frame clears only its own slots", function()
			local p, sig = client()
			local got = 0
			sig:Connect(function()
				got += 1
			end)
			fireAll(p, table.create(999, "x"))
			rt.signals.S.Sig:Fire(p, { "a table the tape must not keep" })
			expect(toClient(p)).toBe(1)
			expect(got).toBe(1000)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			expect(ClientNet._test.tapeStats().high).toBe(4000)
			fireAll(p, { "y" })
			expect(toClient(p)).toBe(1)
			expect(got).toBe(1001)
			local stats = ClientNet._test.tapeStats()
			expect(stats.lastClear).toBe(4)
			expect(stats.high).toBe(4000)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
		end)

		it("a frame past TAPE_KEEP (16384 slots) replaces the tape; the next small frame is O(1) again", function()
			local p, sig = client()
			local got = 0
			sig:Connect(function()
				got += 1
			end)
			fireAll(p, table.create(4200, "x"))
			expect(toClient(p)).toBe(1)
			expect(got).toBe(4200)
			expect(ClientNet._test.tapeStats().high).toBe(0)
			expect(ClientNet._test.tapeEmpty()).toBe(true)
			fireAll(p, { "y" })
			expect(toClient(p)).toBe(1)
			expect(got).toBe(4201)
			expect(ClientNet._test.tapeStats().lastClear).toBe(4)
		end)
	end)

	describe("server: the frame parse runs on a runner", function()
		it("a yielding ClientEvent listener: the frame goes on in order; violation and cleanup happen once", function()
			local p = newPlayer()
			local held: any = nil
			rt.events.S.Ev:Connect(function(_: any, tag: any, inst: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "y" then
					held = inst
					task.wait(0.05)
					table.insert(trail, "1:y resumed")
				end
			end)
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			local part = Instance.new("Folder")
			local yMsg, yRefs = eventMsg("Ev", "y", part)
			expect(#yRefs).toBe(1)
			local frame = frameOf({
				ev("a"),
				yMsg,
				callMsg("Note", 1, "c"),
				ev("b"),
				signalHead("Sig"),
				ev("never"),
			}, 1)
			local violations = Violations.totals().violations
			local messages = Transport.getStats().MessagesIn
			Transport._test.frame(false, p, frame, yRefs)
			expect(trail).toEqual({ "1:a", "2:a", "1:y", "2:y", "call c", "1:b", "2:b" })
			expect(held).toBe(part)
			expect(st(p).viol.winViol[V_ROUTE]).toBe(1)
			expect(Violations.totals().violations - violations).toBe(1)
			expect(Transport.getStats().MessagesIn - messages).toBe(4)
			expect(argvClear()).toBe(true)
			expect(Transport._test.refsHeld()).toBe(false)
			waitFor(function(): boolean
				return #trail >= 8
			end, 2)
			frames(3)
			expect(trail).toEqual({ "1:a", "2:a", "1:y", "2:y", "call c", "1:b", "2:b", "1:y resumed" })
			expect(st(p).viol.winViol[V_ROUTE]).toBe(1)
			expect(Violations.totals().violations - violations).toBe(1)
			expect(Transport.getStats().MessagesIn - messages).toBe(4)
			expect(argvClear()).toBe(true)
			expect(Transport._test.refsHeld()).toBe(false)
			flush()
			local out = takeFires(p)
			expect(#out).toBe(1)
			local h, q = Codec.readHead(out[1].frame, 0, buffer.len(out[1].frame))
			expect(h).toBe(-OP.OK)
			expect(buffer.readu16(out[1].frame, q)).toBe(1)
		end)

		it("a ClientEvent listener error is logged as before; later listeners and messages still run", function()
			local p = newPlayer()
			local lines = captureWarnings()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "boom" then
					error(BOOM, 0)
				end
			end)
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("boom"), ev("b") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:boom", "2:boom", "1:b", "2:b" })
			expect(#lines).toBe(1)
			expect(lines[1]).toContain(PREFIX .. "S.ClientEvents.Ev listener failed for uid=" .. p.UserId .. ": ")
			expect(lines[1]).toContain(BOOM)
			expect(argvClear()).toBe(true)
		end)

		it("a log sink that throws on a listener's failure line stops only that line's runner, as before B2", function()
			local p = newPlayer()
			Log._reset()
			Log._test.setSink(noop, function(line: string)
				if string.find(line, "listener failed", 1, true) then
					error(BOOM, 0)
				end
			end)
			local reported = watchBoom()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "boom" then
					error("Delivery.spec: a listener error for the throwing log sink", 0)
				end
			end)
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			local violations = Violations.totals().violations
			local messages = Transport.getStats().MessagesIn
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("boom"), ev("b") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:boom", "2:boom", "1:b", "2:b" })
			expect(Transport.getStats().MessagesIn - messages).toBe(3)
			expect(Violations.totals().violations - violations).toBe(0)
			waitFor(function(): boolean
				return #reported >= 1
			end, 2)
			stopWatch()
			expect(#reported).toBe(1)
		end)

		it("Disconnect and Once inside one frame follow the listener rules", function()
			local p = newPlayer()
			local e = rt.events.S.Ev
			local conn2: any
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "x" then
					conn2:Disconnect()
				end
			end)
			conn2 = e:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			e:Once(function(_: any, tag: any)
				table.insert(trail, "once:" .. tostring(tag))
			end)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x"), ev("b") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "once:a", "1:x", "1:b" })
		end)

		it("two yields in one message: each takeover goes on after the listener that yielded; counted once", function()
			local p = newPlayer()
			local e = rt.events.S.Ev
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(trail, "1:y resumed")
				end
			end)
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(trail, "2:y resumed")
				end
			end)
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "3:" .. tostring(tag))
			end)
			local violations = Violations.totals().violations
			local messages = Transport.getStats().MessagesIn
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("y"), ev("b"), signalHead("Sig") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "3:a", "1:y", "2:y", "3:y", "1:b", "2:b", "3:b" })
			expect(Transport.getStats().MessagesIn - messages).toBe(3)
			expect(Violations.totals().violations - violations).toBe(1)
			expect(st(p).viol.winViol[V_ROUTE]).toBe(1)
			waitFor(function(): boolean
				return #trail >= 11
			end, 2)
			frames(3)
			expect(#trail).toBe(11)
			expect(count(trail, "1:y resumed")).toBe(1)
			expect(count(trail, "2:y resumed")).toBe(1)
			expect(Transport.getStats().MessagesIn - messages).toBe(3)
			expect(Violations.totals().violations - violations).toBe(1)
			expect(argvClear()).toBe(true)
		end)

		it("after a takeover every check charges once: a rate-limited call, its ERR and the drop counter", function()
			local p = newPlayer()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "ev " .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(trail, "ev y resumed")
				end
			end)
			local limited = Violations.totals().drops[C.Drop.RateLimited] or 0
			local messages = Transport.getStats().MessagesIn
			local frame = frameOf({ callMsg("Tight", 1, "t1"), ev("y"), callMsg("Tight", 2, "t2"), ev("b") })
			Transport._test.frame(false, p, frame, nil)
			expect(trail).toEqual({ "tight t1", "ev y", "ev b" })
			expect((Violations.totals().drops[C.Drop.RateLimited] or 0) - limited).toBe(1)
			expect(Transport.getStats().MessagesIn - messages).toBe(3)
			waitFor(function(): boolean
				return #trail >= 4
			end, 2)
			frames(3)
			expect(trail).toEqual({ "tight t1", "ev y", "ev b", "ev y resumed" })
			expect((Violations.totals().drops[C.Drop.RateLimited] or 0) - limited).toBe(1)
			expect(Transport.getStats().MessagesIn - messages).toBe(3)
			flush()
			local out = takeFires(p)
			expect(#out).toBe(1)
			local b = out[1].frame
			local len = buffer.len(b)
			local h, q = Codec.readHead(b, 0, len)
			expect(h).toBe(-OP.OK)
			expect(buffer.readu16(b, q)).toBe(1)
			local rctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(rctx, out[1].refs, 0)
			Codec.beginMessage(rctx, false)
			local values: { any } = {}
			local n
			n, q = R("Tight").returns.decode(b, q + 2, len, rctx, values)
			expect(n).toBe(1)
			expect(values[1]).toBe("t1")
			h, q = Codec.readHead(b, q, len)
			expect(h).toBe(-OP.ERR)
			expect(buffer.readu16(b, q)).toBe(2)
			expect(buffer.readu8(b, q + 2)).toBe(C.Err.RateLimited)
			expect(q + 4).toBe(len)
		end)

		it("after a takeover an Ordered seq is checked once: the stale copy drops once, rxSeq moves once", function()
			local p = newPlayer()
			rt.events.S.Ord:Connect(function(_: any, tag: any)
				table.insert(trail, "ord " .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(trail, "ord y resumed")
				end
			end)
			local h = R("Ord").id
			Transport._test.frame(true, p, frameOf({ ordMsg(5, "y"), ordMsg(5, "dup"), ordMsg(6, "b") }), nil)
			expect(trail).toEqual({ "ord y", "ord b" })
			expect(st(p).viol.winDrop[C.Drop.Stale]).toBe(1)
			expect(st(p).rxSeq[h]).toBe(6)
			waitFor(function(): boolean
				return #trail >= 3
			end, 2)
			frames(3)
			expect(trail).toEqual({ "ord y", "ord b", "ord y resumed" })
			expect(st(p).viol.winDrop[C.Drop.Stale]).toBe(1)
			expect(st(p).rxSeq[h]).toBe(6)
		end)

		it("a Once listener that yields: called once, and the listeners after it go on at once", function()
			local p = newPlayer()
			local e = rt.events.S.Ev
			local conn = e:Once(function(_: any, tag: any)
				table.insert(trail, "once:" .. tostring(tag))
				task.wait()
				table.insert(trail, "once resumed")
			end)
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("b") }), nil)
			expect(trail).toEqual({ "once:a", "2:a", "2:b" })
			expect(conn.Connected).toBe(false)
			waitFor(function(): boolean
				return #trail >= 4
			end, 2)
			frames(2)
			expect(trail).toEqual({ "once:a", "2:a", "2:b", "once resumed" })
		end)

		it("Testing.Reset in a listener that yields: later listeners still get the message, as before B2", function()
			local p = newPlayer()
			local e = rt.events.S.Ev
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "reset" then
					Loren.Testing.Reset({ Offline = true })
					task.wait()
					table.insert(trail, "1:reset resumed")
				end
			end)
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "2:" .. tostring(tag))
			end)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("reset"), ev("after") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:reset", "2:reset" })
			expect(Transport.getStats().MessagesIn).toBe(1)
			expect(Violations.totals().violations).toBe(1)
			expect(argvClear()).toBe(true)
			waitFor(function(): boolean
				return #trail >= 5
			end, 2)
			frames(2)
			expect(trail).toEqual({ "1:a", "2:a", "1:reset", "2:reset", "1:reset resumed" })
		end)

		it("a parked listener does not keep its frame alive (no slot of the parked stack holds it)", function()
			local p = newPlayer()
			local weak: any = setmetatable({}, { __mode = "v" })
			local parked: thread? = nil
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				if tag == "park" then
					parked = coroutine.running()
					coroutine.yield()
				end
			end)
			local function send()
				local frame = frameOf({ ev("pad1"), ev("park"), ev("pad2") })
				weak.frame = frame
				Transport._test.frame(false, p, frame, nil)
			end
			send()
			expect(parked).never.toBeNil()
			local rounds = 0
			local junk: { any } = {}
			local deadline = os.clock() + 10
			weak.control = buffer.create(64)
			while rounds < 2 and os.clock() < deadline do
				for i = 1, 200 do
					junk[i] = table.create(1024, 0)
				end
				table.clear(junk)
				task.wait()
				if weak.control == nil then
					rounds += 1
					weak.control = buffer.create(64)
				end
			end
			if rounds >= 2 then
				expect(weak.frame).toBeNil()
			else
				warn("Delivery.spec: fewer than 2 collections within 10 s; the parked-frame check was not conclusive")
			end
			pcall(task.cancel, parked :: thread)
		end, { timeout = 20 })
	end)

	describe("LocalSignal: one runner per Fire", function()
		it("a nested Fire whose listener yields finishes before the outer listeners go on", function()
			local sig = Signal.LocalSignal.new()
			local log: { string } = {}
			sig:Connect(function(v: any)
				table.insert(log, "A" .. v)
				if v == 1 then
					sig:Fire(2)
				end
			end)
			sig:Connect(function(v: any)
				table.insert(log, "B" .. v)
				if v == 2 then
					task.wait()
					table.insert(log, "B2 resumed")
				end
			end)
			sig:Connect(function(v: any)
				table.insert(log, "C" .. v)
			end)
			sig:Fire(1)
			expect(log).toEqual({ "A1", "A2", "B2", "C2", "B1", "C1" })
			waitFor(function(): boolean
				return #log >= 7
			end, 2)
			frames(2)
			expect(log).toEqual({ "A1", "A2", "B2", "C2", "B1", "C1", "B2 resumed" })
		end)

		it("an error in a nested Fire, then a yield in the outer Fire: each listener once, in order", function()
			local sig = Signal.LocalSignal.new()
			local reported = watchBoom()
			local log: { string } = {}
			sig:Connect(function(v: any)
				table.insert(log, "A" .. v)
				if v == 1 then
					sig:Fire(2)
				end
			end)
			sig:Connect(function(v: any)
				table.insert(log, "B" .. v)
				if v == 2 then
					error(BOOM, 0)
				end
				task.wait()
				table.insert(log, "B1 resumed")
			end)
			sig:Connect(function(v: any)
				table.insert(log, "C" .. v)
			end)
			sig:Fire(1)
			expect(log).toEqual({ "A1", "A2", "B2", "C2", "B1", "C1" })
			waitFor(function(): boolean
				return #log >= 7 and #reported >= 1
			end, 2)
			frames(2)
			stopWatch()
			expect(log).toEqual({ "A1", "A2", "B2", "C2", "B1", "C1", "B1 resumed" })
			expect(#reported).toBe(1)
		end)
	end)

	describe("Signal.drive", function()
		it("revokes a runner that stopped before reaching user code, so it never goes on with the delivery", function()
			local cur: any = { owner = 0, busy = true, pos = 1, node = nil, stop = 0 }
			local parked: thread? = nil
			local after: { string } = {}
			local function body(c: any, me: number)
				parked = coroutine.running()
				coroutine.yield()
				table.insert(after, if c.owner == me then "still the owner" else "revoked")
			end
			expect(Signal.drive(body, cur)).toBe(false)
			expect(cur.busy).toBe(false)
			expect(parked).never.toBeNil()
			task.spawn(parked :: thread)
			expect(after).toEqual({ "revoked" })
		end)
	end)
end
