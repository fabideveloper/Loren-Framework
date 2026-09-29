--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local C = require(Runtime.Constants)
local Codec = require(Runtime.Codec)
local Schema = require(Runtime.Schema)
local Config = require(Runtime.Config)
local Log = require(Runtime.Log)
local Signal = require(Runtime.Signal)
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
local V = C.Violation
local DROP = C.Drop
local PREFIX = C.PREFIX
local BOOM = "ServerInline.spec: a listener failed on purpose (expected in the output)"

type Fire = { channel: string, player: any, frame: buffer, refs: { any }? }

local function noop(...: any) end

local now = 1000
local rt: any = nil
local byName: { [string]: any } = {}
local module: any = nil
local fires: { Fire } = {}
local trail: { string } = {}
local gates: { [string]: thread } = {}
local nextUid = 0
local seqN = 0

local function cleanupGates()
	for _, th in gates do
		pcall(task.cancel, th)
	end
	table.clear(gates)
end

local function member(kind: number, name: string, fn: any, spec: any, middleware: any): any
	return { name = name, kind = kind, fn = fn, spec = spec, middleware = middleware, colon = false }
end

local function services(): any
	local M, E, S = K.Method, K.Event, K.Signal
	local members: { any } = {
		member(M, "Note", function(_: any, _: any, tag: any): any
			table.insert(trail, "call " .. tostring(tag))
			return tag
		end),
		member(M, "Park", function(_: any, _: any, key: any): any
			gates[key] = coroutine.running()
			return coroutine.yield()
		end),
		member(E, "Ev"),
		member(E, "Flag", nil, Schema.event(T.bool)),
		member(E, "In", nil, Schema.event(T.struct({ seq = T.u16, moveX = T.i8, yaw = T.f32, jump = T.bool }))),
		member(E, "Small", nil, Schema.event(T.int(0, 10))),
		member(E, "Few", nil, Schema.event({ RateLimit = { 2, 2 } })),
		member(E, "Guarded", nil, nil, function(_: any, mode: any): boolean
			if mode == "slow" then
				task.wait()
			end
			return mode ~= "deny"
		end),
		member(S, "Sig"),
	}
	local client: { [string]: any } = {}
	local middleware: { [string]: any } = {}
	for _, m: any in members do
		if m.kind == M then
			client[m.name] = m.fn
		end
		if m.middleware then
			middleware[m.name] = m.middleware
		end
	end
	module = { Client = client, Signals = {}, ClientEvents = {}, Middleware = middleware }
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

local function bytes(list: { number }): buffer
	local b = buffer.create(#list)
	for k, x in list do
		buffer.writeu8(b, k - 1, x)
	end
	return b
end

local function rawFrame(nmsg: number, body: { buffer }, nrefs: number?): buffer
	local total = 5
	for _, part in body do
		total += buffer.len(part)
	end
	seqN = (seqN + 1) % 65536
	local b = buffer.create(total)
	buffer.writeu16(b, 0, seqN)
	buffer.writeu16(b, 2, nmsg)
	buffer.writeu8(b, 4, nrefs or 0)
	local o = 5
	for _, part in body do
		buffer.copy(b, o, part, 0, buffer.len(part))
		o += buffer.len(part)
	end
	return b
end

local function prefixed(m: buffer): buffer
	assert(buffer.len(m) < 128, "test message too long for a 1-byte length")
	local b = buffer.create(buffer.len(m) + 1)
	buffer.writeu8(b, 0, buffer.len(m))
	buffer.copy(b, 1, m, 0, buffer.len(m))
	return b
end

local function frameOf(msgs: { buffer }, nrefs: number?): buffer
	local body: { buffer } = {}
	for k, m in msgs do
		body[k] = prefixed(m)
	end
	return rawFrame(#msgs, body, nrefs)
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

local function headMsg(id: number, payload: { number }): buffer
	local w = Codec.newWriter(16, true)
	Codec.writeHead(w, id)
	for _, x in payload do
		Codec.writeU8(w, x)
	end
	return writerBytes(w)
end

local function hello(p: any)
	Transport._test.frame(false, p, frameOf({ bytes({ OP.HELLO, C.PROTO }) }), nil)
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

local function newPlayer(): any
	nextUid += 1
	local p: any = { UserId = nextUid, Name = "Player" .. nextUid }
	p.Kick = noop
	Transport._test.addPlayer(p)
	hello(p)
	flush()
	takeFires(p)
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

local function messagesIn(): number
	return Transport.getStats().MessagesIn
end

local function violations(): number
	return Violations.totals().violations
end

local function listen(prefix: string): any
	return rt.events.S.Ev:Connect(function(_: any, tag: any)
		table.insert(trail, prefix .. tostring(tag))
	end)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeEach(function()
		setup()
	end)
	t.afterEach(function()
		cleanupGates()
		Log._reset()
	end)
	t.afterAll(function()
		cleanupGates()
		resetServer()
		Loren.Testing.Reset()
	end)

	describe("server: the runner's parse calls the listeners itself", function()
		it("nothing yields: one runner delivers every message after the first (the last one too), in order", function()
			local p = newPlayer()
			local threads: { thread } = {}
			local seen: { number } = {}
			local base = messagesIn()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(threads, coroutine.running())
				table.insert(seen, messagesIn() - base)
				table.insert(trail, "1:" .. tostring(tag))
			end)
			listen("2:")
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("b"), ev("c"), ev("d") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:b", "2:b", "1:c", "2:c", "1:d", "2:d" })
			expect(seen).toEqual({ 0, 1, 2, 3 })
			for k = 2, 4 do
				expect(threads[k]).toBe(threads[1])
			end
			expect(threads[1]).never.toBe(coroutine.running())
			expect(messagesIn() - base).toBe(4)
			expect(argvClear()).toBe(true)
		end)

		it("a yield at message k of 30 hands the rest to one takeover: every listener once, counted once", function()
			local p = newPlayer()
			local part = Instance.new("Folder")
			local got: any = {}
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(trail, "1:y resumed")
				end
			end)
			rt.events.S.Ev:Connect(function(_: any, tag: any, ...: any)
				table.insert(trail, "2:" .. tostring(tag))
				if tag == "y" then
					got = table.pack(...)
				end
			end)
			local yMsg, yRefs = eventMsg("Ev", "y", part, 7)
			local msgs: { buffer } = {}
			local want: { string } = {}
			for k = 1, 30 do
				local tag = if k == 12 then "y" else tostring(k)
				msgs[k] = if k == 12 then yMsg else ev(tag)
				table.insert(want, "1:" .. tag)
				table.insert(want, "2:" .. tag)
			end
			table.insert(msgs, (eventMsg("Ev")))
			table.insert(want, "1:nil")
			table.insert(want, "2:nil")
			table.insert(msgs, headMsg(R("Sig").id, {}))
			local base, viol = messagesIn(), violations()
			Transport._test.frame(false, p, frameOf(msgs, 1), yRefs)
			expect(trail).toEqual(want)
			expect(got.n).toBe(2)
			expect(got[1]).toBe(part)
			expect(got[2]).toBe(7)
			expect(messagesIn() - base).toBe(31)
			expect(violations() - viol).toBe(1)
			expect(st(p).viol.winViol[V.Route]).toBe(1)
			expect(argvClear()).toBe(true)
			expect(Transport._test.refsHeld()).toBe(false)
			waitFor(function(): boolean
				return #trail > #want
			end, 2)
			frames(3)
			table.insert(want, "1:y resumed")
			expect(trail).toEqual(want)
			expect(messagesIn() - base).toBe(31)
			expect(violations() - viol).toBe(1)
			expect(argvClear()).toBe(true)
		end)

		it("a yield in the last message's listener: the frame ends once, after its listeners", function()
			local p = newPlayer()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "last" then
					task.wait()
					table.insert(trail, "1:last resumed")
				end
			end)
			listen("2:")
			local frame = rawFrame(2, { prefixed(ev("a")), prefixed(ev("last")), bytes({ 0 }) })
			local base, viol = messagesIn(), violations()
			Transport._test.frame(false, p, frame, nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:last", "2:last" })
			expect(messagesIn() - base).toBe(2)
			expect(violations() - viol).toBe(1)
			expect(st(p).viol.winViol[V.Framing]).toBe(1)
			waitFor(function(): boolean
				return #trail >= 5
			end, 2)
			frames(2)
			expect(trail).toEqual({ "1:a", "2:a", "1:last", "2:last", "1:last resumed" })
			expect(messagesIn() - base).toBe(2)
			expect(violations() - viol).toBe(1)
		end)

		it("listener errors mid-frame are logged as before; the frame goes on; a second one only counts", function()
			local p = newPlayer()
			local lines = captureWarnings()
			local e = rt.events.S.Ev
			e:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if string.sub(tag, 1, 1) == "x" then
					error(BOOM, 0)
				end
			end)
			listen("2:")
			local base = messagesIn()
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x1"), ev("b"), ev("x2"), ev("c") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:x1", "2:x1", "1:b", "2:b", "1:x2", "2:x2", "1:c", "2:c" })
			expect(#lines).toBe(1)
			expect(lines[1]).toContain(PREFIX .. "S.ClientEvents.Ev listener failed for uid=" .. p.UserId .. ": ")
			expect(lines[1]).toContain(BOOM)
			local counts = Signal._test.eventLog(e)
			expect(counts.logged).toBe(1)
			expect(counts.suppressed).toBe(1)
			expect(messagesIn() - base).toBe(5)
			expect(argvClear()).toBe(true)
		end)

		it("a listener that fails after a takeover logs its own player, though the parse state was reused", function()
			local a = newPlayer()
			local b = newPlayer()
			local lines = captureWarnings()
			local parked: thread? = nil
			rt.events.S.Ev:Connect(function(player: any, tag: any)
				table.insert(trail, tostring(player.UserId) .. ":" .. tostring(tag))
				if tag == "y" then
					parked = coroutine.running()
					coroutine.yield()
					error(BOOM, 0)
				end
			end)
			Transport._test.frame(false, a, frameOf({ ev("1"), ev("y"), ev("2") }), nil)
			Transport._test.frame(false, b, frameOf({ ev("3"), ev("4") }), nil)
			local ua, ub = tostring(a.UserId), tostring(b.UserId)
			expect(trail).toEqual({ ua .. ":1", ua .. ":y", ua .. ":2", ub .. ":3", ub .. ":4" })
			expect(#lines).toBe(0)
			expect(parked).never.toBeNil()
			local base = messagesIn()
			task.spawn(parked :: thread)
			expect(#lines).toBe(1)
			expect(lines[1]).toContain(PREFIX .. "S.ClientEvents.Ev listener failed for uid=" .. ua .. ": ")
			expect(#trail).toBe(5)
			expect(messagesIn()).toBe(base)
			expect(argvClear()).toBe(true)
		end)

		it("Testing.Reset in a listener mid-frame (no yield): the parse goes on in the reset state", function()
			local p = newPlayer()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "1:" .. tostring(tag))
				if tag == "reset" then
					Loren.Testing.Reset({ Offline = true })
				end
			end)
			listen("2:")
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("b"), ev("reset"), ev("c"), ev("d") }), nil)
			expect(trail).toEqual({ "1:a", "2:a", "1:b", "2:b", "1:reset", "2:reset" })
			expect(messagesIn()).toBe(1)
			expect(violations()).toBe(1)
			expect(argvClear()).toBe(true)
		end)

		it("typed arguments decode on the runner: a fresh table per struct message, scalars as values", function()
			local p = newPlayer()
			local inputs: { any } = {}
			local flags: { any } = {}
			listen("ev ")
			rt.events.S.In:Connect(function(_: any, v: any)
				table.insert(inputs, v)
			end)
			rt.events.S.Flag:Connect(function(_: any, v: any)
				table.insert(flags, v)
			end)
			local i1 = { seq = 1, moveX = -2, yaw = 0.5, jump = true }
			local i2 = { seq = 65535, moveX = 127, yaw = -1.25, jump = false }
			local frame = frameOf({
				ev("a"),
				(eventMsg("In", i1)),
				(eventMsg("Flag", true)),
				(eventMsg("In", i2)),
				(eventMsg("Flag", false)),
			})
			Transport._test.frame(false, p, frame, nil)
			expect(trail).toEqual({ "ev a" })
			expect(#inputs).toBe(2)
			expect(inputs[1]).toEqual(i1)
			expect(inputs[2]).toEqual(i2)
			expect(inputs[1]).never.toBe(inputs[2])
			expect(table.isfrozen(inputs[1])).toBe(false)
			expect(flags).toEqual({ true, false })
			expect(argvClear()).toBe(true)
		end)

		it("Methods keep their threads and middleware its spawn: a yield in either never holds the frame", function()
			local p = newPlayer()
			listen("ev ")
			rt.events.S.Guarded:Connect(function(_: any, mode: any)
				table.insert(trail, "guarded " .. tostring(mode))
			end)
			local frame = frameOf({
				ev("a"),
				callMsg("Park", 1, "k"),
				(eventMsg("Guarded", "slow")),
				ev("b"),
			})
			Transport._test.frame(false, p, frame, nil)
			expect(trail).toEqual({ "ev a", "ev b" })
			expect(gates.k).never.toBeNil()
			expect(Transport.getStats().RunningCalls).toBe(1)
			waitFor(function(): boolean
				return #trail >= 3
			end, 2)
			expect(trail).toEqual({ "ev a", "ev b", "guarded slow" })
			local th = gates.k
			gates.k = nil :: any
			task.spawn(th, "done")
			expect(Transport.getStats().RunningCalls).toBe(0)
			flush()
			local out = takeFires(p)
			expect(#out).toBe(1)
			local h, q = Codec.readHead(out[1].frame, 0, buffer.len(out[1].frame))
			expect(h).toBe(-OP.OK)
			expect(buffer.readu16(out[1].frame, q)).toBe(1)
		end)
	end)

	describe("server: hostile messages met by the runner's parse", function()
		local function hostile(bad: buffer): (any, number, number)
			local p = newPlayer()
			table.clear(trail)
			local base, viol = messagesIn(), violations()
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("b"), bad, ev("c") }), nil)
			return p, messagesIn() - base, violations() - viol
		end

		it("structural faults end the frame there, once, before any later listener", function()
			listen("ev ")
			local cases: { { any } } = {
				{ "unknown route", headMsg(rt.count + 1, { 1 }), V.Route },
				{ "Signal route", headMsg(R("Sig").id, {}), V.Route },
				{ "HELLO not alone", bytes({ OP.HELLO, C.PROTO }), V.Framing },
				{ "S->C op", bytes({ OP.OK, 0, 1 }), V.BadOp },
				{ "zero head", bytes({ 0 }), V.Framing },
				{ "bad bool byte", headMsg(R("Flag").id, { 2 }), V.Payload },
				{ "bytes after the payload", headMsg(R("Flag").id, { 1, 0 }), V.Payload },
				{ "truncated struct", headMsg(R("In").id, { 1, 0, 2 }), V.Payload },
				{ "call id 0", callMsg("Note", 0, "x"), V.DuplicateCall },
			}
			for _, case in cases do
				local p, messages, viol = hostile(case[2])
				expect({ case[1], trail }).toEqual({ case[1], { "ev a", "ev b" } })
				expect({ case[1], messages, viol }).toEqual({ case[1], 2, 1 })
				expect({ case[1], st(p).viol.winViol[case[3]] }).toEqual({ case[1], 1 })
				expect(argvClear()).toBe(true)
			end
		end)

		it("a message longer than the frame is a Framing fault at that message", function()
			local p = newPlayer()
			listen("ev ")
			local short = bytes({ 60, R("Ev").id })
			local base, viol = messagesIn(), violations()
			Transport._test.frame(false, p, rawFrame(3, { prefixed(ev("a")), prefixed(ev("b")), short }), nil)
			expect(trail).toEqual({ "ev a", "ev b" })
			expect(messagesIn() - base).toBe(2)
			expect(violations() - viol).toBe(1)
			expect(st(p).viol.winViol[V.Framing]).toBe(1)
		end)

		it("semantic faults and rate limits drop only their message; the frame goes on", function()
			listen("ev ")
			local p, messages, viol = hostile(headMsg(R("Small").id, { 50 }))
			expect(trail).toEqual({ "ev a", "ev b", "ev c" })
			expect(messages).toBe(3)
			expect(viol).toBe(0)
			expect(st(p).viol.winDrop[DROP.EventBad]).toBe(1)
			rt.events.S.Few:Connect(function(_: any, v: any)
				table.insert(trail, "few " .. tostring(v))
			end)
			local q = newPlayer()
			table.clear(trail)
			local base = messagesIn()
			local frame = frameOf({
				ev("a"),
				(eventMsg("Few", 1)),
				(eventMsg("Few", 2)),
				(eventMsg("Few", 3)),
				(eventMsg("Few", 4)),
				ev("b"),
			})
			Transport._test.frame(false, q, frame, nil)
			expect(trail).toEqual({ "ev a", "few 1", "few 2", "ev b" })
			expect(messagesIn() - base).toBe(4)
			expect(st(q).viol.winDrop[DROP.EventLimited]).toBe(2)
			expect(argvClear()).toBe(true)
		end)
	end)

	describe("server: the middleware probe runs per message (nothing cached)", function()
		it("a member middleware set, removed or reached through a metatable applies from the next message", function()
			local p = newPlayer()
			local mw = module.Middleware
			local function deny(_: any, tag: any): boolean
				return tag ~= "x"
			end
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "ev " .. tostring(tag))
				if tag == "arm" then
					mw.Ev = deny
				end
			end)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("arm"), ev("x"), ev("y") }), nil)
			expect(trail).toEqual({ "ev a", "ev arm", "ev y" })
			expect(st(p).viol.winDrop[DROP.EventDenied]).toBe(1)
			mw.Ev = nil
			table.clear(trail)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x") }), nil)
			expect(trail).toEqual({ "ev a", "ev x" })
			module.Middleware = nil
			setmetatable(module :: any, { __index = { Middleware = { Ev = deny } } })
			table.clear(trail)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x"), ev("b") }), nil)
			expect(trail).toEqual({ "ev a", "ev b" })
			expect(st(p).viol.winDrop[DROP.EventDenied]).toBe(2)
			setmetatable(module :: any, nil)
			module.Middleware = 5
			table.clear(trail)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x") }), nil)
			expect(trail).toEqual({ "ev a", "ev x" })
			module.Middleware = mw
			expect(argvClear()).toBe(true)
		end)

		it("global middleware sends every ClientEvent through Dispatch.event; a reset clears the count", function()
			local p = newPlayer()
			listen("ev ")
			expect(Dispatch.mwState.n).toBe(0)
			local infos: { any } = {}
			Dispatch.addMiddleware(function(_: any, info: any, tag: any): boolean
				table.insert(infos, info)
				return tag ~= "x"
			end)
			expect(Dispatch.mwState.n).toBe(1)
			Transport._test.frame(false, p, frameOf({ ev("a"), ev("x"), ev("b") }), nil)
			expect(trail).toEqual({ "ev a", "ev b" })
			expect(#infos).toBe(3)
			expect(infos[1]).toBe(R("Ev").info)
			expect(st(p).viol.winDrop[DROP.EventDenied]).toBe(1)
			Dispatch._reset()
			expect(Dispatch.mwState.n).toBe(0)
		end)
	end)

	describe("server: a parked listener keeps nothing of its frame", function()
		it("a listener the runner's parse called holds neither the frame nor its PlayerState", function()
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
				local frame = frameOf({ ev("pad1"), ev("pad2"), ev("park"), ev("pad3") })
				weak.frame = frame
				weak.ps = st(p)
				Transport._test.frame(false, p, frame, nil)
			end
			send()
			expect(parked).never.toBeNil()
			Transport._test.removePlayer(p)
			flush()
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
				expect(weak.ps).toBeNil()
			else
				warn("ServerInline.spec: fewer than 2 collections in 10 s; the parked check was not conclusive")
			end
			pcall(task.cancel, parked :: thread)
		end, { timeout = 20 })
	end)
end
