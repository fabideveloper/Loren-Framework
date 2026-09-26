--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local C = require(Runtime.Constants)
local Codec = require(Runtime.Codec)
local Schema = require(Runtime.Schema)
local Errors = require(Runtime.Errors)
local Config = require(Runtime.Config)
local Log = require(Runtime.Log)
local Promise = require(ReplicatedStorage.LorenPackages.Promise) :: any
local Server = ServerScriptService.LorenServer
local Routes = require(Server.Routes)
local Transport = require(Server.Transport)
local Outbox = require(Server.Outbox)
local Dispatch = require(Server.Dispatch)
local ServerSignal = require(Server.ServerSignal)
local Limits = require(Server.Limits)
local Violations = require(Server.Violations)

local T = Schema.T
local K = C.Kind
local V = C.Violation
local DROP = C.Drop
local ERR = C.Err
local OP = C.Op
local NOTICE = C.Notice
local LIM = C.Limit

type Msg = { [string]: any }

local function noop(...: any) end

-- Harness state (rebuilt by setup) -------------------------------------------------------------------

local now = 1000
local rt: any = nil
local byName: { [string]: any } = {}
local fires: { any } = {}
local log: { any } = {} -- handler / middleware order
local evLog: { any } = {} -- ClientEvent deliveries
local gates: { [any]: thread } = {} -- yielded handlers by key
local pendingResolve: any = nil
local nextUid = 0
local seqN = 0

-- A handler that yields until open(key, ...) resumes it; returns what open passed.
local function gate(key: any): ...any
	gates[key] = coroutine.running()
	return coroutine.yield()
end

local function open(key: any, ...: any)
	local th = gates[key]
	assert(th ~= nil, "no yielded handler for " .. tostring(key))
	gates[key] = nil
	task.spawn(th, ...)
end

local function member(kind: number, name: string, fn: any, spec: any, middleware: any, colon: boolean?): any
	return { name = name, kind = kind, fn = fn, spec = spec, middleware = middleware, colon = colon == true }
end

local function service(name: string, members: { any }): any
	table.sort(members, function(a: any, b: any): boolean
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.kind < b.kind
	end)
	local client: { [string]: any } = {}
	local middleware: { [string]: any } = {}
	for _, m in members do
		if m.kind == K.Method then
			client[m.name] = m.fn
		end
		if m.middleware then
			middleware[m.name] = m.middleware
		end
	end
	-- Dispatch reads Middleware[member] and Client[member] per call, as real modules hold them
	local module = { Client = client, Signals = {}, ClientEvents = {}, Middleware = middleware }
	return {
		name = name,
		record = { name = name, kind = "Service", module = module, instance = script, path = name, deps = {} },
		module = module,
		client = client,
		members = members,
		networked = true,
	}
end

local function standard(): { any }
	local M, E, S = K.Method, K.Event, K.Signal
	local members = {
		member(M, "Echo", function(_, _, ...)
			return ...
		end),
		member(M, "Wait", function(_, _, key)
			table.insert(log, key)
			return gate(key)
		end),
		member(M, "Typed", function(_, _, v)
			return v
		end, Schema.method(T.int(0, 10))),
		member(M, "Limited", function()
			return true
		end, Schema.method({ RateLimit = { 1, 1 } })),
		member(
			M,
			"Ser",
			function(_, _, key)
				table.insert(log, key)
				return gate(key)
			end,
			Schema.method({ Serial = true }),
			function(_, key)
				table.insert(log, "mw:" .. tostring(key))
				return true
			end
		),
		member(M, "Cancel", function(_, _, key)
			return gate(key)
		end, Schema.method({ CancelOnTimeout = true, Timeout = 1 })),
		member(M, "Rej", function(_, _, msg, data)
			return Errors.reject(msg, data)
		end),
		member(M, "Throw", function(_, _, kind)
			if kind == "reject" then
				error(Errors.reject("thrown"))
			end
			error("secret detail")
		end),
		member(M, "Prom", function(_, _, mode)
			if mode == "ok" then
				return Promise.resolve(5)
			elseif mode == "reject" then
				return Promise.reject(Errors.reject("nope", 9))
			elseif mode == "pending" then
				return Promise.new(function(resolve)
					pendingResolve = resolve
				end)
			end
			return Promise.reject("boom")
		end),
		member(M, "Resume", function(_, _, key, own)
			open(key)
			if own ~= nil then
				return gate(own)
			end
			return "done"
		end),
		member(
			M,
			"Guard",
			function()
				return "ran"
			end,
			nil,
			function(_: any, mode: any): ...any
				if mode == "allow" then
					return true
				elseif mode == "reason" then
					return false, "nope"
				elseif mode == "truthy" then
					return 1
				end
				return nil
			end
		),
		member(
			M,
			"Colon",
			function()
				return "ran"
			end,
			nil,
			function()
				return true
			end,
			true
		),
		member(E, "Ev"),
		member(E, "Fast", nil, Schema.event(T.u8, { Unreliable = true, Ordered = true })),
		member(E, "Slow", nil, Schema.event({ RateLimit = { 1, 1 } })),
		member(E, "GuardEv", nil, nil, function(_, mode)
			return mode == "allow"
		end),
		member(S, "Sig"),
		member(S, "USig", nil, Schema.signal(T.string, { Unreliable = true })),
		member(S, "OSig", nil, Schema.signal(T.u8, { Unreliable = true, Ordered = true })),
	}
	for i = 1, 9 do
		table.insert(
			members,
			member(M, "Z" .. i, function(_, _, key)
				return gate(key)
			end)
		)
	end
	return { service("S", members) }
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

local function cleanupGates()
	for _, th in gates do
		pcall(task.cancel, th)
	end
	table.clear(gates)
end

local function setup(cfg: { [string]: any }?)
	cleanupGates()
	Loren.Testing.Reset({ Offline = true })
	resetServer()
	Log._test.setSink(noop, noop)
	if cfg then
		Config.set(cfg)
	end
	local c = Config.get()
	Limits.configure(c)
	Violations.configure(c)
	table.clear(log)
	table.clear(evLog)
	pendingResolve = nil
	local report = { side = "Server", errors = {}, warnings = {} }
	rt = Routes.build(standard() :: any, c, report)
	assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
	byName = {}
	for _, r in rt.routes do
		byName[r.member] = r
	end
	fires = {}
	Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
		table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
	end)
	now = 1000
	Transport._test.setClock(function(): number
		return now
	end)
	Transport._test.attach(rt)
	Dispatch._test.setForwardErrors(false)
	rt.events.S.Ev:Connect(function(player: any, ...: any)
		table.insert(evLog, { player = player, args = table.pack(...) })
	end)
	rt.events.S.Fast:Connect(function(player: any, v: any)
		table.insert(evLog, { player = player, v = v })
	end)
	rt.events.S.GuardEv:Connect(function(player: any, mode: any)
		table.insert(evLog, { player = player, mode = mode })
	end)
end

-- C->S bytes -------------------------------------------------------------------------------------------

local function varint(v: number): { number }
	if v < 0x80 then
		return { v }
	elseif v < 0x4000 then
		return { bit32.bor(bit32.band(v, 0x7F), 0x80), bit32.rshift(v, 7) }
	end
	return {
		bit32.bor(bit32.band(v, 0x7F), 0x80),
		bit32.bor(bit32.band(bit32.rshift(v, 7), 0x7F), 0x80),
		bit32.rshift(v, 14),
	}
end

local function raw(list: { number }): buffer
	local b = buffer.create(#list)
	for i, v in list do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

local function writerBytes(w: any): buffer
	local b = buffer.create(w.n)
	buffer.copy(b, 0, w.buf, 0, w.n)
	return b
end

-- seq:u16 nmsg:u16 nrefs:u8, then len:varint + message for each.
local function frameOf(seq: number, msgs: { buffer }, nrefs: number?, nmsg: number?): buffer
	local total = 5
	for _, m in msgs do
		total += #varint(buffer.len(m)) + buffer.len(m)
	end
	local b = buffer.create(total)
	buffer.writeu16(b, 0, seq)
	buffer.writeu16(b, 2, nmsg or #msgs)
	buffer.writeu8(b, 4, nrefs or 0)
	local o = 5
	for _, m in msgs do
		local len = buffer.len(m)
		for _, byte in varint(len) do
			buffer.writeu8(b, o, byte)
			o += 1
		end
		buffer.copy(b, o, m, 0, len)
		o += len
	end
	return b
end

local function R(name: string): any
	local r = byName[name]
	assert(r ~= nil, "no route " .. name)
	return r
end

local function headOnly(name: string): buffer
	local w = Codec.newWriter(8, true)
	Codec.writeHead(w, R(name).id)
	return writerBytes(w)
end

local function callMsg(name: string, callId: number, ...: any): buffer
	local r = R(name)
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	Codec.writeU16(w, callId)
	local st = r.args.encode(w, select("#", ...), ...)
	assert(st == 0, "encode failed: " .. st)
	return writerBytes(w)
end

local function eventMsg(name: string, seq: number?, ...: any): buffer
	local r = R(name)
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	if seq ~= nil then
		Codec.writeU16(w, seq)
	end
	local st = r.args.encode(w, select("#", ...), ...)
	assert(st == 0, "encode failed: " .. st)
	return writerBytes(w)
end

-- Typed(0..10) call carrying a raw byte (50 = out of range).
local function typedRaw(callId: number, byte: number): buffer
	local w = Codec.newWriter(8, true)
	Codec.writeHead(w, R("Typed").id)
	Codec.writeU16(w, callId)
	Codec.writeU8(w, byte)
	return writerBytes(w)
end

local function nanCall(callId: number): buffer
	local w = Codec.newWriter(16, true)
	Codec.writeHead(w, R("Echo").id)
	Codec.writeU16(w, callId)
	Codec.writeU8(w, 1)
	Codec.writeU8(w, C.Tag.F64)
	Codec.writeF64(w, 0 / 0)
	return writerBytes(w)
end

local function send(p: any, msgs: { buffer }, unreliable: boolean?, seq: number?)
	local s = seq
	if s == nil then
		seqN = (seqN + 1) % 65536
		s = seqN
	end
	Transport._test.frame(unreliable == true, p, frameOf(s :: number, msgs), nil)
end

local function call(p: any, name: string, callId: number, ...: any)
	send(p, { callMsg(name, callId, ...) })
end

local function hello(p: any)
	send(p, { raw({ OP.HELLO, C.PROTO }) })
end

-- S->C decoding -------------------------------------------------------------------------------------

local function decodeFrame(b: buffer, refs: { any }?): { Msg }
	local ctx = Codec.newReadCtx(false, false)
	Codec.beginFrame(ctx, refs, 0)
	local out: { Msg } = {}
	local o, lim = 0, buffer.len(b)
	while o < lim do
		local h, q = Codec.readHead(b, o, lim)
		assert(h ~= 0, "bad S->C head at " .. o)
		local m: Msg
		if h == -OP.MANIFEST then
			local len = buffer.readu32(b, q)
			m = { op = "MANIFEST", len = len }
			o = q + 4 + len
		elseif h == -OP.OK then
			local argv = {}
			Codec.beginMessage(ctx, true)
			local n, e = Codec.readArgs(b, q + 2, lim, ctx, argv, 255)
			assert(ctx.err == 0, "OK payload status " .. ctx.err)
			m = { op = "OK", callId = buffer.readu16(b, q), n = n, args = argv }
			o = e
		elseif h == -OP.ERR then
			local flags = buffer.readu8(b, q + 3)
			m = { op = "ERR", callId = buffer.readu16(b, q), code = buffer.readu8(b, q + 2), flags = flags }
			local p = q + 4
			if bit32.btest(flags, C.ErrFlag.Msg) then
				local len, np = Codec.readVarint(b, p, lim)
				m.msg = buffer.readstring(b, np, len)
				p = np + len
			end
			if bit32.btest(flags, C.ErrFlag.Data) then
				Codec.beginMessage(ctx, true)
				local v, np = Codec.readValue(b, p, lim, ctx, 0)
				assert(ctx.err == 0, "ERR data status " .. ctx.err)
				m.data = v
				m.hasData = true
				p = np
			end
			if bit32.btest(flags, C.ErrFlag.Incident) then
				m.incident = buffer.readu32(b, p)
				p += 4
			end
			o = p
		elseif h == -OP.NOTICE then
			m = {
				op = "NOTICE",
				kind = buffer.readu8(b, q),
				first = buffer.readu16(b, q + 1),
				count = buffer.readu16(b, q + 3),
			}
			o = q + 5
		else
			assert(h > 0, "unexpected control op " .. -h)
			local r = rt.routes[h]
			m = { op = "SIGNAL", route = h, name = r.member }
			local p = q
			if r.ordered then
				m.seq = buffer.readu16(b, p)
				p += 2
			end
			local argv = {}
			Codec.beginMessage(ctx, true)
			local n, e = r.args.decode(b, p, lim, ctx, argv)
			assert(ctx.err == 0, "SIGNAL payload status " .. ctx.err)
			m.n = n
			m.args = argv
			o = e
		end
		table.insert(out, m)
	end
	return out
end

-- Removes and returns the captured fires to `p` (optionally one channel).
local function takeFires(p: any, channel: string?): { any }
	local mine, keep = {}, {}
	for _, f in fires do
		if f.player == p and (channel == nil or f.channel == channel) then
			table.insert(mine, f)
		else
			table.insert(keep, f)
		end
	end
	fires = keep
	return mine
end

local function received(p: any, channel: string?): { Msg }
	local out = {}
	for _, f in takeFires(p, channel) do
		for _, m in decodeFrame(f.frame, f.refs) do
			table.insert(out, m)
		end
	end
	return out
end

local function flushTo(p: any, channel: string?): { Msg }
	Transport._test.flush()
	return received(p, channel)
end

-- A mixed-type array literal for toEqual.
local function list(...: any): { any }
	return { ... }
end

local function only(msgs: { Msg }, op: string): { Msg }
	local out = {}
	for _, m in msgs do
		if m.op == op then
			table.insert(out, m)
		end
	end
	return out
end

local function newPlayer(helloNow: boolean?): any
	nextUid += 1
	local p: any = { UserId = nextUid, Name = "Player" .. nextUid, kicks = 0 }
	p.Kick = function(self: any)
		self.kicks += 1
	end
	Transport._test.addPlayer(p)
	if helloNow ~= false then
		hello(p)
		Transport._test.flush()
		takeFires(p)
	end
	return p
end

local function st(p: any): any
	return Transport._test.state(p)
end

local function viol(p: any, kind: number): number
	return st(p).viol.winViol[kind]
end

local function violTotal(p: any): number
	local n = 0
	for _, c in st(p).viol.winViol do
		n += c
	end
	return n
end

local function dropped(p: any, kind: number): number
	return st(p).viol.winDrop[kind]
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

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeEach(function()
		setup()
	end)
	t.afterEach(function()
		cleanupGates()
	end)
	t.afterAll(function()
		cleanupGates()
		resetServer()
		Loren.Testing.Reset()
	end)

	describe("receive pipeline violations", function()
		local cases: { { any } } = {
			{
				"Envelope: frame is not a buffer",
				V.Envelope,
				function(p)
					Transport._test.frame(false, p, "frame", nil)
				end,
			},
			{
				"Envelope: refs is not a table",
				V.Envelope,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 1) }, 1), "refs")
				end,
			},
			{
				"ExtraArgs",
				V.ExtraArgs,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 1) }), nil, "extra")
				end,
			},
			{
				"FrameSize: shorter than the header",
				V.FrameSize,
				function(p)
					Transport._test.frame(false, p, buffer.create(4), nil)
				end,
			},
			{
				"FrameSize: reliable over 72 KiB",
				V.FrameSize,
				function(p)
					Transport._test.frame(false, p, buffer.create(LIM.C2S_MAX_FRAME + 1), nil)
				end,
			},
			{
				"FrameSize: unreliable over 1000 B",
				V.FrameSize,
				function(p)
					Transport._test.frame(true, p, buffer.create(LIM.UNRELIABLE_MAX_FRAME + 1), nil)
				end,
			},
			{
				"Refs: unreliable frame with a refs table",
				V.Refs,
				function(p)
					Transport._test.frame(true, p, frameOf(1, { eventMsg("Fast", 1, 1) }), {})
				end,
			},
			{
				"Refs: unreliable frame with nrefs",
				V.Refs,
				function(p)
					Transport._test.frame(true, p, frameOf(1, { eventMsg("Fast", 1, 1) }, 1), nil)
				end,
			},
			{
				"Refs: reliable refs without nrefs",
				V.Refs,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 1) }), { 1 })
				end,
			},
			{
				"Refs: reliable nrefs without refs",
				V.Refs,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 1) }, 1), nil)
				end,
			},
			{
				"Framing: nmsg 0",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, raw({ 1, 0, 0, 0, 0, 0 }), nil)
				end,
			},
			{
				"Framing: nmsg over the cap",
				V.Framing,
				function(p)
					local msgs = table.create(LIM.MAX_MSGS_PER_FRAME + 1, callMsg("Echo", 1))
					Transport._test.frame(false, p, frameOf(1, msgs), nil)
				end,
			},
			{
				"Framing: nmsg larger than the bytes",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ 1 }) }, 0, 3), nil)
				end,
			},
			{
				"Framing: zero message length",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, raw({ 1, 0, 1, 0, 0, 0x00, 0x05 }), nil)
				end,
			},
			{
				"Framing: message length past the frame",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, raw({ 1, 0, 1, 0, 0, 0x05, 0x01 }), nil)
				end,
			},
			{
				"Framing: head 0x00",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ 0x00, 0x01 }) }), nil)
				end,
			},
			{
				"Framing: HELLO not alone",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ OP.HELLO, C.PROTO }), callMsg("Echo", 1) }), nil)
				end,
			},
			{
				"Framing: bytes after the last message",
				V.Framing,
				function(p)
					local f = frameOf(1, { callMsg("Echo", 1) })
					local b = buffer.create(buffer.len(f) + 1)
					buffer.copy(b, 0, f)
					Transport._test.frame(false, p, b, nil)
				end,
			},
			{
				"Framing: CALL without a callId",
				V.Framing,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { headOnly("Echo") }), nil)
				end,
			},
			{
				"BadOp: a server-to-client op",
				V.BadOp,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ OP.OK, 1, 0 }) }), nil)
				end,
			},
			{
				"BadOp: a reserved op",
				V.BadOp,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ 0xF7 }) }), nil)
				end,
			},
			{
				"BadOp: HELLO with a wrong proto",
				V.BadOp,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ OP.HELLO, C.PROTO + 1 }) }), nil)
				end,
			},
			{
				"Route: unknown route",
				V.Route,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { raw({ 0xDF, 1, 0, 0 }) }), nil)
				end,
			},
			{
				"Route: a Signal route",
				V.Route,
				function(p)
					local w = Codec.newWriter(8, true)
					Codec.writeHead(w, R("Sig").id)
					Codec.writeU8(w, 0)
					Transport._test.frame(false, p, frameOf(1, { writerBytes(w) }), nil)
				end,
			},
			{
				"Route: a reliable Event on the unreliable channel",
				V.Route,
				function(p)
					Transport._test.frame(true, p, frameOf(1, { eventMsg("Ev", nil, 1) }), nil)
				end,
			},
			{
				"DuplicateCall: callId 0",
				V.DuplicateCall,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 0) }), nil)
				end,
			},
			{
				"Payload: an invalid tag",
				V.Payload,
				function(p)
					local w = Codec.newWriter(8, true)
					Codec.writeHead(w, R("Echo").id)
					Codec.writeU16(w, 1)
					Codec.writeU8(w, 1)
					Codec.writeU8(w, 0x14)
					Transport._test.frame(false, p, frameOf(1, { writerBytes(w) }), nil)
				end,
			},
			{
				"Payload: bytes left in the message",
				V.Payload,
				function(p)
					local m = typedRaw(1, 5)
					local b = buffer.create(buffer.len(m) + 1)
					buffer.copy(b, 0, m)
					Transport._test.frame(false, p, frameOf(1, { b }), nil)
				end,
			},
			{
				"Sidecar: a function in refs",
				V.Sidecar,
				function(p)
					Transport._test.frame(false, p, frameOf(1, { callMsg("Echo", 1) }, 1), { noop })
				end,
			},
		}
		for _, case in cases do
			it(case[1], function()
				local p = newPlayer()
				case[3](p)
				expect(viol(p, case[2])).toBe(1)
				expect(violTotal(p)).toBe(1)
				expect(Violations.totals().violations).toBe(1)
				expect(argvClear()).toBe(true)
			end)
		end

		it("BeforeHello: a route message before HELLO", function()
			local p = newPlayer(false)
			call(p, "Echo", 1, "x")
			expect(viol(p, V.BeforeHello)).toBe(1)
			hello(p)
			expect(#only(flushTo(p), "OK")).toBe(0)
		end)

		it("RepeatHello: a second HELLO within REHELLO_MIN after other messages", function()
			local p = newPlayer()
			call(p, "Echo", 1, "x")
			expect(#only(flushTo(p), "OK")).toBe(1)
			hello(p)
			expect(viol(p, V.RepeatHello)).toBe(1)
			expect(#flushTo(p)).toBe(0)
			now += LIM.REHELLO_MIN + 0.1
			hello(p)
			expect(viol(p, V.RepeatHello)).toBe(1)
			local msgs = flushTo(p)
			expect(msgs[1].op).toBe("MANIFEST")
		end)

		it("ignores an early repeat HELLO before any other message (an honest retry) without a violation", function()
			local p = newPlayer() -- HELLO accepted, MANIFEST flushed
			now += 1
			hello(p) -- the client's retry while MANIFEST was in flight, bunched by uplink delay
			expect(violTotal(p)).toBe(0)
			expect(#flushTo(p)).toBe(0) -- ignored: no second MANIFEST
			call(p, "Echo", 1, "x")
			expect(#only(flushTo(p), "OK")).toBe(1)
			hello(p)
			expect(viol(p, V.RepeatHello)).toBe(1)
		end)

		it("DuplicateCall: a callId that is still live", function()
			local p = newPlayer()
			call(p, "Wait", 5, "w")
			expect(st(p).callTok[5]).never.toBeNil()
			call(p, "Echo", 5, "again")
			expect(viol(p, V.DuplicateCall)).toBe(1)
			open("w", "done")
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].args[1]).toBe("done")
		end)

		it("stops the frame at the violation; earlier messages were dispatched", function()
			local p = newPlayer()
			send(p, { callMsg("Echo", 1, "a"), raw({ 0xDF }), callMsg("Echo", 2, "b") })
			expect(viol(p, V.Route)).toBe(1)
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].callId).toBe(1)
		end)

		it("ignores frames from players without a state", function()
			Transport._test.frame(false, { UserId = 999 }, "junk", nil)
			expect(Violations.totals().violations).toBe(0)
		end)
	end)

	describe("admission and reply caps", function()
		it("reports refused frames as FrameDropped runs (wrap-aware)", function()
			local p = newPlayer()
			st(p).lim.frame.tokens = 0
			for _, s in { 10, 11, 12, 20, 65535, 0 } do
				send(p, { callMsg("Echo", 1, "x") }, false, s)
			end
			local msgs = flushTo(p)
			expect(#only(msgs, "OK")).toBe(0)
			local notices = only(msgs, "NOTICE")
			expect(notices).toEqual({
				{ op = "NOTICE", kind = NOTICE.FrameDropped, first = 10, count = 3 },
				{ op = "NOTICE", kind = NOTICE.FrameDropped, first = 20, count = 1 },
				{ op = "NOTICE", kind = NOTICE.FrameDropped, first = 65535, count = 2 },
			})
			expect(dropped(p, DROP.FrameDropped)).toBe(6)
			expect(Transport.getStats().FramesDropped).toBe(6)
			expect(violTotal(p)).toBe(0)
			expect(#only(flushTo(p), "NOTICE")).toBe(0) -- runs are sent once
		end)

		it("reports at most NOTICE_RUNS_MAX runs per channel per flush", function()
			local p = newPlayer()
			st(p).lim.frame.tokens = 0
			for i = 0, LIM.NOTICE_RUNS_MAX do
				send(p, { callMsg("Echo", 1) }, false, 100 + 2 * i)
			end
			expect(#only(flushTo(p), "NOTICE")).toBe(LIM.NOTICE_RUNS_MAX)
			expect(dropped(p, DROP.FrameDropped)).toBe(LIM.NOTICE_RUNS_MAX + 1)
		end)

		it("reports unreliable refusals as UFrameDropped", function()
			local p = newPlayer()
			st(p).lim.uframe.tokens = 0
			send(p, { eventMsg("Fast", 1, 1) }, true, 7)
			local notices = only(flushTo(p), "NOTICE")
			expect(#notices).toBe(1)
			expect(notices[1].kind).toBe(NOTICE.UFrameDropped)
			expect(notices[1].first).toBe(7)
			expect(#evLog).toBe(0)
		end)

		it("refuses a frame whose sidecar cost the byte bucket cannot pay", function()
			local p = newPlayer()
			st(p).lim.bytes.tokens = 100
			local refs = { { string.rep("x", 200) } }
			Transport._test.frame(false, p, frameOf(33, { callMsg("Echo", 1) }, 1), refs)
			expect(dropped(p, DROP.FrameDropped)).toBe(1)
			local notices = only(flushTo(p), "NOTICE")
			expect(#notices).toBe(1)
			expect(notices[1].first).toBe(33)
			expect(violTotal(p)).toBe(0)
		end)

		it("sends no FrameDropped runs to a player before HELLO", function()
			local p = newPlayer(false)
			st(p).lim.frame.tokens = 0
			send(p, { callMsg("Echo", 1) }, false, 3)
			expect(dropped(p, DROP.FrameDropped)).toBe(1)
			hello(p)
			expect(st(p).helloed).toBe(false) -- the HELLO frame was refused too
			expect(#flushTo(p)).toBe(0)
		end)

		it("replies RateLimited at most once per route per second", function()
			local p = newPlayer()
			call(p, "Limited", 1)
			call(p, "Limited", 2)
			call(p, "Limited", 3)
			local msgs = flushTo(p)
			local ok, errs = only(msgs, "OK"), only(msgs, "ERR")
			expect(#ok).toBe(1)
			expect(ok[1].callId).toBe(1)
			expect(#errs).toBe(1)
			expect(errs[1].callId).toBe(2)
			expect(errs[1].code).toBe(ERR.RateLimited)
			expect(errs[1].flags).toBe(0)
			expect(dropped(p, DROP.RateLimited)).toBe(2)
			expect(dropped(p, DROP.RepliesSuppressed)).toBe(1)
			now += 1.5
			call(p, "Limited", 4)
			call(p, "Limited", 5)
			msgs = flushTo(p)
			expect(only(msgs, "OK")[1].callId).toBe(4)
			expect(only(msgs, "ERR")[1].callId).toBe(5)
			expect(Transport.getStats().CallsRateLimited).toBe(3)
		end)

		it("replies BadRequest with the reason and the argument index", function()
			local p = newPlayer()
			send(p, { nanCall(1) })
			send(p, { typedRaw(2, 50) })
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(2)
			expect(errs[1].code).toBe(ERR.BadRequest)
			expect(errs[1].msg).toBe("NonFinite")
			expect(errs[1].data).toBe(1)
			expect(errs[2].msg).toBe("Range")
			expect(errs[2].data).toBe(1)
			expect(errs[2].incident).toBeNil()
			expect(dropped(p, DROP.BadRequest)).toBe(2)
			expect(violTotal(p)).toBe(0)
			expect(argvClear()).toBe(true)
			expect(st(p).callTok[1]).toBeNil()
		end)

		it("caps BadRequest replies at 16 per burst", function()
			local p = newPlayer()
			local msgs = {}
			for i = 1, 20 do
				msgs[i] = typedRaw(i, 50)
			end
			send(p, msgs)
			expect(#only(flushTo(p), "ERR")).toBe(Limits._test.BR_REPLY_BURST)
			expect(dropped(p, DROP.BadRequest)).toBe(20)
			expect(dropped(p, DROP.RepliesSuppressed)).toBe(20 - Limits._test.BR_REPLY_BURST)
		end)

		it("counts dispatched messages and dispatches a valid call", function()
			local p = newPlayer()
			call(p, "Typed", 1, 7)
			local ok = only(flushTo(p), "OK")
			expect(ok[1].args[1]).toBe(7)
			local stats = Transport.getStats()
			expect(stats.MessagesIn).toBe(1)
			expect(stats.Routes).toBe(rt.count)
			expect(stats.Players).toBe(1)
			expect(stats.Side).toBe("Server")
			expect(argvClear()).toBe(true)
		end)
	end)

	describe("HELLO and the outbox", function()
		it("never flushes a player before HELLO; MANIFEST goes first", function()
			local p = newPlayer(false)
			rt.signals.S.Sig:FireAll("early")
			Transport._test.flush()
			expect(#takeFires(p)).toBe(0)
			expect(st(p).out.nmsg).toBe(1)
			hello(p)
			local f = takeFires(p)
			expect(#f).toBe(0) -- HELLO only queues; the flush sends
			Transport._test.flush()
			f = takeFires(p)
			expect(#f).toBe(1)
			local manifest = rt.manifestMsg
			local head = buffer.create(buffer.len(manifest))
			buffer.copy(head, 0, f[1].frame, 0, buffer.len(manifest))
			expect(buffer.tostring(head)).toBe(buffer.tostring(manifest))
			local msgs = decodeFrame(f[1].frame, f[1].refs)
			expect(msgs[1].op).toBe("MANIFEST")
			expect(msgs[2].op).toBe("SIGNAL")
			expect(msgs[2].args[1]).toBe("early")
			expect(#msgs).toBe(2)
		end)

		it("drops unreliable messages before HELLO", function()
			local p = newPlayer(false)
			rt.signals.S.USig:FireAll("u")
			expect(dropped(p, DROP.UnreliableEarly)).toBe(1)
			expect(Transport.getStats().SignalsDropped).toBe(1)
			hello(p)
			expect(#flushTo(p, "Unreliable")).toBe(0)
		end)

		it("caps the outbox at OUTBOX_MSGS and reports the overflow after MANIFEST", function()
			local p = newPlayer(false)
			local sig = rt.signals.S.Sig
			for i = 1, LIM.OUTBOX_MSGS + 4 do
				sig:Fire(p, i)
			end
			expect(st(p).outboxDropped).toBe(4)
			expect(dropped(p, DROP.OutboxOverflow)).toBe(4)
			hello(p)
			local msgs = flushTo(p)
			expect(msgs[1].op).toBe("MANIFEST")
			expect(msgs[2]).toEqual({ op = "NOTICE", kind = NOTICE.OutboxOverflow, first = 0, count = 4 })
			local sigs = only(msgs, "SIGNAL")
			expect(#sigs).toBe(LIM.OUTBOX_MSGS)
			expect(sigs[1].args[1]).toBe(1)
			expect(sigs[#sigs].args[1]).toBe(LIM.OUTBOX_MSGS)
			expect(Transport.getStats().OutboxDropped).toBe(4)
		end)

		it("caps the outbox at OUTBOX_BYTES", function()
			local p = newPlayer(false)
			local big = string.rep("b", 60000)
			for _ = 1, 5 do
				rt.signals.S.Sig:Fire(p, big)
			end
			expect(st(p).outboxDropped).toBe(1)
			hello(p)
			local msgs = flushTo(p)
			expect(#only(msgs, "SIGNAL")).toBe(4)
			expect(only(msgs, "NOTICE")[1].count).toBe(1)
		end)

		it("clears the outbox OUTBOX_TTL after join and drops later messages until HELLO", function()
			local p = newPlayer(false)
			local sig = rt.signals.S.Sig
			sig:Fire(p, 1)
			now += LIM.OUTBOX_TTL + 1
			sig:Fire(p, 2)
			expect(st(p).out.nmsg).toBe(0)
			expect(st(p).outboxExpired).toBe(true)
			expect(st(p).outboxDropped).toBe(2)
			hello(p)
			local msgs = flushTo(p)
			expect(msgs[1].op).toBe("MANIFEST")
			expect(msgs[2]).toEqual({ op = "NOTICE", kind = NOTICE.OutboxOverflow, first = 0, count = 2 })
			expect(#only(msgs, "SIGNAL")).toBe(0)
			sig:Fire(p, 3)
			local after = only(flushTo(p), "SIGNAL")
			expect(#after).toBe(1)
			expect(after[1].args[1]).toBe(3)
		end)

		it("expires the outbox at a HELLO later than OUTBOX_TTL even with no message in between", function()
			local p = newPlayer(false)
			rt.signals.S.Sig:Fire(p, "stale")
			now += LIM.OUTBOX_TTL + 1
			hello(p)
			expect(dropped(p, DROP.OutboxExpired)).toBe(1) -- read before the flush's summary window closes
			local msgs = flushTo(p)
			expect(msgs[1].op).toBe("MANIFEST")
			expect(msgs[2]).toEqual({ op = "NOTICE", kind = NOTICE.OutboxOverflow, first = 0, count = 1 })
			expect(#only(msgs, "SIGNAL")).toBe(0)
			expect(Transport.getStats().OutboxDropped).toBe(1)
		end)

		it("repeat HELLO: abandons live calls, purges replies, resends MANIFEST first, resets Ordered state", function()
			local p = newPlayer()
			send(p, { eventMsg("Fast", 100, 1) }, true)
			expect(#evLog).toBe(1)
			call(p, "Wait", 7, "w")
			expect(st(p).running).toBe(1)
			call(p, "Echo", 8, "stale reply")
			rt.signals.S.Sig:Fire(p, "kept")
			now += LIM.REHELLO_MIN + 1
			hello(p)
			local ps = st(p)
			expect(ps.running).toBe(0)
			expect(ps.callTok[7]).toBeNil()
			expect(ps.zombies).toBe(1)
			local msgs = flushTo(p)
			expect(msgs[1].op).toBe("MANIFEST")
			expect(#only(msgs, "OK")).toBe(0)
			local sigs = only(msgs, "SIGNAL")
			expect(#sigs).toBe(1)
			expect(sigs[1].args[1]).toBe("kept")
			-- the zombie's thread ends: no reply, counters released
			open("w", "late")
			expect(ps.zombies).toBe(0)
			expect(#only(flushTo(p), "OK")).toBe(0)
			-- Ordered receive state was reset: an older seq is accepted again
			send(p, { eventMsg("Fast", 50, 2) }, true)
			expect(#evLog).toBe(2)
			expect(evLog[2].v).toBe(2)
		end)

		it("sends NOTICE ShuttingDown and refuses new calls while shutting down; events still run", function()
			local p = newPlayer()
			Transport.shutdown()
			local notices = only(received(p), "NOTICE")
			expect(#notices).toBe(1)
			expect(notices[1].kind).toBe(NOTICE.ShuttingDown)
			call(p, "Echo", 1, "x")
			send(p, { eventMsg("Ev", nil, "still") })
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].code).toBe(ERR.ShuttingDown)
			expect(#evLog).toBe(1)
		end)
	end)

	describe("flush and seals", function()
		it("seals reliable frames at 64 KiB; a larger message goes alone", function()
			local p = newPlayer()
			local sig = rt.signals.S.Sig
			local chunk = string.rep("a", 30000)
			sig:Fire(p, chunk)
			sig:Fire(p, chunk)
			sig:Fire(p, chunk)
			Transport._test.flush()
			local f = takeFires(p, "Reliable")
			expect(#f).toBe(2)
			expect(#decodeFrame(f[1].frame)).toBe(2)
			expect(#decodeFrame(f[2].frame)).toBe(1)
			for _, x in f do
				expect(buffer.len(x.frame) <= LIM.S2C_SEAL).toBe(true)
				expect(x.refs).toBeNil()
			end
			sig:Fire(p, string.rep("z", 70000))
			Transport._test.flush()
			f = takeFires(p, "Reliable")
			expect(#f).toBe(1)
			expect(buffer.len(f[1].frame) > LIM.S2C_SEAL).toBe(true)
		end)

		it("slices refs per frame", function()
			local p = newPlayer()
			local sig = rt.signals.S.Sig
			sig:Fire(p, workspace)
			sig:Fire(p, string.rep("z", 70000))
			sig:Fire(p, game)
			Transport._test.flush()
			local f = takeFires(p, "Reliable")
			expect(#f).toBe(3)
			expect(f[1].refs).toEqual({ workspace })
			expect(f[2].refs).toBeNil()
			expect(f[3].refs).toEqual({ game })
			expect(decodeFrame(f[3].frame, f[3].refs)[1].args[1]).toBe(game)
		end)

		it("splits unreliable traffic into fires of at most 900 B, in order", function()
			local p = newPlayer()
			local usig = rt.signals.S.USig
			for i = 1, 20 do
				usig:Fire(p, string.format("%03d", i) .. string.rep("u", 97))
			end
			Transport._test.flush()
			local f = takeFires(p, "Unreliable")
			expect(#f >= 3).toBe(true)
			local seen = 0
			for _, x in f do
				expect(buffer.len(x.frame) <= LIM.UNRELIABLE_SEAL).toBe(true)
				expect(x.refs).toBeNil()
				for _, m in decodeFrame(x.frame) do
					seen += 1
					expect(string.sub(m.args[1], 1, 3)).toBe(string.format("%03d", seen))
				end
			end
			expect(seen).toBe(20)
		end)

		it("raises for an unreliable message over 900 B and keeps working", function()
			local p = newPlayer()
			local usig = rt.signals.S.USig
			expect(function()
				usig:Fire(p, string.rep("u", 1000))
			end).toThrow("limited to 900")
			usig:Fire(p, "ok")
			local msgs = flushTo(p, "Unreliable")
			expect(#msgs).toBe(1)
			expect(msgs[1].args[1]).toBe("ok")
		end)

		it("does not keep burst-sized buffers: scratch writer, channel buffer, boundary arrays", function()
			local p = newPlayer()
			local keep = 4 * LIM.S2C_SEAL
			rt.signals.S.Sig:Fire(p, string.rep("x", 300000))
			expect(Outbox._test.scratch().cap > keep).toBe(true)
			rt.signals.S.Sig:Fire(p, "small")
			expect(Outbox._test.scratch().cap <= keep).toBe(true)
			local ps = st(p)
			expect(ps.out.w.cap > keep).toBe(true)
			local msgs = only(flushTo(p), "SIGNAL")
			expect(#msgs).toBe(2)
			expect(#msgs[1].args[1]).toBe(300000)
			expect(ps.out.w.cap <= keep).toBe(true)
			-- one flush of 2000 messages: the boundary arrays it used are replaced afterwards
			for i = 1, 2000 do
				rt.signals.S.Sig:Fire(p, i)
			end
			local used = ps.out.starts
			expect(#only(flushTo(p), "SIGNAL")).toBe(2000)
			expect(ps.out.spareStarts ~= used).toBe(true)
			expect(#ps.out.spareStarts).toBe(0)
			rt.signals.S.Sig:Fire(p, "after")
			expect(only(flushTo(p), "SIGNAL")[1].args[1]).toBe("after")
		end)

		it("makes no empty fires", function()
			newPlayer()
			Transport._test.flush()
			Transport._test.flush()
			expect(#fires).toBe(0)
		end)

		it("retries a failing frame per message; a lost OK becomes ERR BadResult", function()
			local p = newPlayer()
			Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
				if string.find(buffer.tostring(frame), "POISON", 1, true) then
					error("fire failed")
				end
				table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
			end)
			call(p, "Echo", 1, "fine")
			call(p, "Echo", 2, "POISON")
			rt.signals.S.Sig:Fire(p, "after")
			local msgs = flushTo(p)
			expect(#msgs).toBe(2)
			expect(msgs[1].op).toBe("OK")
			expect(msgs[1].callId).toBe(1)
			expect(msgs[2].op).toBe("SIGNAL")
			local next = flushTo(p)
			expect(#next).toBe(1)
			expect(next[1].op).toBe("ERR")
			expect(next[1].callId).toBe(2)
			expect(next[1].code).toBe(ERR.BadResult)
			expect(next[1].flags).toBe(C.ErrFlag.Incident)
			expect(next[1].msg).toBeNil()
		end)

		it("a lost ERR with data becomes BadResult; a lost plain ERR is only dropped", function()
			local p = newPlayer()
			Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
				if string.find(buffer.tostring(frame), "POISON", 1, true) then
					error("fire failed")
				end
				table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
			end)
			call(p, "Rej", 3, "no", "POISON")
			call(p, "Rej", 4, "POISON")
			expect(#flushTo(p)).toBe(0)
			local next = flushTo(p)
			expect(#next).toBe(1)
			expect(next[1].callId).toBe(3)
			expect(next[1].code).toBe(ERR.BadResult)
			expect(next[1].incident).never.toBeNil()
		end)
	end)

	describe("call states", function()
		it("runs 32, queues 64, then replies Busy", function()
			local p = newPlayer()
			local msgs = {}
			for i = 1, 97 do
				msgs[i] = callMsg("Wait", i, i)
			end
			send(p, msgs)
			local ps = st(p)
			expect(ps.running).toBe(32)
			expect(ps.queued).toBe(64)
			expect(#log).toBe(32)
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].callId).toBe(97)
			expect(errs[1].code).toBe(ERR.Busy)
			expect(dropped(p, DROP.Busy)).toBe(1)
			expect(Transport.getStats().RunningCalls).toBe(32)
			open(1, "one")
			expect(ps.running).toBe(32)
			expect(ps.queued).toBe(63)
			expect(log[33]).toBe(33) -- FIFO
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].args[1]).toBe("one")
		end)

		it("zombies: 4 per route block that route only", function()
			local p = newPlayer()
			for i = 1, 4 do
				call(p, "Z1", i, i)
			end
			now += 10 + Config.get().WatchdogGrace + 1
			Transport._test.sweep(now)
			local ps = st(p)
			expect(ps.running).toBe(0)
			expect(ps.zombies).toBe(4)
			expect(ps.routeZombies[R("Z1").id]).toBe(4)
			expect(ps.callTok[1]).toBeNil()
			call(p, "Z1", 5, 5)
			call(p, "Z2", 6, 6)
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].callId).toBe(5)
			expect(errs[1].code).toBe(ERR.Busy)
			expect(ps.running).toBe(1) -- Z2 runs
			open(1)
			expect(ps.zombies).toBe(3)
			expect(#only(flushTo(p), "OK")).toBe(0) -- a zombie end never replies
			call(p, "Z1", 7, 7)
			expect(ps.running).toBe(2)
			expect(Transport.getStats().ZombieCalls).toBe(3)
		end)

		it("zombies: 16 per player block routes holding one; zombie-free routes still run", function()
			local p = newPlayer()
			local id = 0
			for r = 1, 8 do
				for _ = 1, 2 do
					id += 1
					call(p, "Z" .. r, id, id)
				end
			end
			now += 10 + Config.get().WatchdogGrace + 1
			Transport._test.sweep(now)
			local ps = st(p)
			expect(ps.zombies).toBe(16)
			call(p, "Z1", 100, 100)
			call(p, "Z9", 101, 101)
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].callId).toBe(100)
			expect(ps.running).toBe(1)
			expect(ps.callTok[101]).never.toBeNil()
		end)

		it("Serial: runs calls of one route in FIFO order, middleware included", function()
			local p = newPlayer()
			send(p, { callMsg("Ser", 1, 1), callMsg("Ser", 2, 2), callMsg("Ser", 3, 3) })
			expect(log).toEqual(list("mw:1", 1))
			open(1)
			expect(log).toEqual(list("mw:1", 1, "mw:2", 2))
			open(2)
			expect(log).toEqual(list("mw:1", 1, "mw:2", 2, "mw:3", 3))
			open(3)
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(3)
			expect(ok[1].callId).toBe(1)
			expect(ok[2].callId).toBe(2)
			expect(ok[3].callId).toBe(3)
			expect(st(p).serialActive[R("Ser").id]).toBeNil()
		end)

		it("Serial: keeps FIFO across the player queue", function()
			setup({ MaxRunningCalls = 1 })
			local p = newPlayer()
			send(p, {
				callMsg("Wait", 1, "n1"),
				callMsg("Ser", 2, "s1"),
				callMsg("Ser", 3, "s2"),
				callMsg("Wait", 4, "n2"),
			})
			local ps = st(p)
			expect(ps.queued).toBe(2) -- s1 and n2; s2 waits in the Serial queue
			expect(ps.serialActive[R("Ser").id]).toBe(true)
			open("n1")
			expect(log).toEqual({ "n1", "mw:s1", "s1" })
			open("s1")
			expect(log).toEqual({ "n1", "mw:s1", "s1", "mw:s2", "s2" })
			open("s2")
			expect(log[#log]).toBe("n2")
			open("n2")
			expect(#only(flushTo(p), "OK")).toBe(4)
			expect(ps.running).toBe(0)
			expect(ps.queued).toBe(0)
		end)

		it("drops queue entries older than their timeout; a dropped Serial occupant frees the route", function()
			setup({ MaxRunningCalls = 1 })
			local p = newPlayer()
			call(p, "Wait", 1, "a")
			call(p, "Wait", 2, "b") -- player queue, receipt 1000
			call(p, "Ser", 3, "s1") -- player queue, occupies Ser
			now += 6
			call(p, "Ser", 4, "s2") -- Serial queue, receipt 1006
			now += 5 -- 1011: b and s1 expired (timeout 10), s2 not
			open("a")
			expect(log).toEqual({ "a", "mw:s2", "s2" })
			local ps = st(p)
			expect(ps.callTok[2]).toBeNil()
			expect(ps.callTok[3]).toBeNil()
			open("s2")
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(2)
			expect(ok[1].callId).toBe(1)
			expect(ok[2].callId).toBe(4)
		end)

		it("detects yields by token when a handler synchronously resumes another call", function()
			local p = newPlayer()
			call(p, "Wait", 1, "b")
			local ps = st(p)
			expect(ps.running).toBe(1)
			call(p, "Resume", 2, "b")
			expect(ps.running).toBe(0)
			expect(next(ps.calls)).toBeNil()
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(2)
			expect(ok[1].callId).toBe(1)
			expect(ok[2].callId).toBe(2)
			expect(ok[2].args[1]).toBe("done")
		end)

		it("counts the resuming call as yielded when it yields after finishing another", function()
			local p = newPlayer()
			call(p, "Wait", 1, "b")
			call(p, "Resume", 2, "b", "own")
			local ps = st(p)
			expect(ps.running).toBe(1)
			expect(ps.calls[1]).toBeNil()
			expect(ps.calls[2]).never.toBeNil()
			open("own", "late")
			expect(ps.running).toBe(0)
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(2)
			expect(ok[2].args[1]).toBe("late")
		end)

		it("watchdog: abandons a call past receipt + timeout + WatchdogGrace", function()
			local p = newPlayer()
			call(p, "Wait", 1, "w")
			local deadline = 1000 + 10 + Config.get().WatchdogGrace
			Transport._test.sweep(deadline - 0.5)
			local ps = st(p)
			expect(ps.running).toBe(1)
			now = deadline + 0.5
			Transport._test.sweep(now)
			expect(ps.running).toBe(0)
			expect(ps.zombies).toBe(1)
			expect(ps.callTok[1]).toBeNil()
			open("w", "late")
			expect(ps.zombies).toBe(0)
			expect(#flushTo(p)).toBe(0)
		end)

		it("CancelOnTimeout: cancels the thread instead of leaving a zombie", function()
			local p = newPlayer()
			call(p, "Cancel", 1, "c")
			local th = gates["c"]
			expect(th).never.toBeNil()
			now = 1000 + 1 + Config.get().WatchdogGrace + 0.1
			Transport._test.sweep(now)
			local ps = st(p)
			expect(coroutine.status(th)).toBe("dead")
			expect(ps.running).toBe(0)
			expect(ps.zombies).toBe(0)
			expect(ps.callTok[1]).toBeNil()
			gates["c"] = nil
			expect(#flushTo(p)).toBe(0)
		end)

		it("forgets a leaving player: late finishes reply nothing", function()
			local p = newPlayer()
			call(p, "Wait", 1, "w")
			local ps = st(p)
			Transport._test.removePlayer(p)
			expect(ps.gone).toBe(true)
			expect(st(p)).toBeNil()
			open("w", "late")
			Transport._test.flush()
			expect(#fires).toBe(0)
		end)

		it("drops Serial queue entries behind a zombie occupant once the client timed out on them", function()
			local p = newPlayer()
			call(p, "Ser", 1, "hang") -- occupies Ser and never returns
			call(p, "Ser", 2, "q1") -- Serial queue
			call(p, "Ser", 3, "q2")
			local ps = st(p)
			local id = R("Ser").id
			expect(#ps.serialQ[id]).toBe(2)
			now += 10 + Config.get().WatchdogGrace + 1
			Transport._test.sweep(now)
			expect(ps.zombies).toBe(1)
			expect(ps.serialActive[id]).toBe(true) -- the zombie still occupies the route
			expect(#ps.serialQ[id]).toBe(0)
			expect(ps.callTok[2]).toBeNil()
			expect(ps.callTok[3]).toBeNil()
			-- the client reuses the ids after its quarantine: never a DuplicateCall
			call(p, "Echo", 2, "again")
			call(p, "Echo", 3, "again")
			expect(violTotal(p)).toBe(0)
			expect(#only(flushTo(p), "OK")).toBe(2)
			open("hang")
			expect(ps.zombies).toBe(0)
			expect(ps.serialActive[id]).toBeNil()
			expect(#flushTo(p)).toBe(0)
		end)

		it("drops expired player-queue entries in the sweep even while every slot stays busy", function()
			setup({ MaxRunningCalls = 1 })
			local p = newPlayer()
			call(p, "Wait", 1, "busy") -- holds the only slot
			call(p, "Echo", 2, "queued") -- player queue
			local ps = st(p)
			expect(ps.queued).toBe(1)
			now += 10.5 -- past receipt + timeout, before the running call's deadline
			Transport._test.sweep(now)
			expect(ps.queued).toBe(0)
			expect(ps.callTok[2]).toBeNil()
			expect(ps.running).toBe(1)
			open("busy", "done")
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].callId).toBe(1)
		end)

		it("releases a yielded call whose thread died without finishing (no zombie)", function()
			local p = newPlayer()
			call(p, "Ser", 1, "dies")
			call(p, "Ser", 2, "next") -- waits behind it in the Serial queue
			local ps = st(p)
			local th = gates["dies"]
			gates["dies"] = nil
			task.cancel(th) -- the handler's own code cancelled its thread
			now += 1
			Transport._test.sweep(now)
			expect(ps.zombies).toBe(0)
			expect(ps.callTok[1]).toBeNil()
			expect(ps.running).toBe(1) -- "next" runs
			expect(log[#log]).toBe("next")
			open("next", "ran")
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].callId).toBe(2)
			expect(ps.serialActive[R("Ser").id]).toBeNil()
		end)

		it("releases a zombie whose thread died without finishing", function()
			local p = newPlayer()
			call(p, "Z1", 1, "z")
			now += 10 + Config.get().WatchdogGrace + 1
			Transport._test.sweep(now)
			local ps = st(p)
			expect(ps.zombies).toBe(1)
			task.cancel(gates["z"])
			gates["z"] = nil
			now += 1
			Transport._test.sweep(now)
			expect(ps.zombies).toBe(0)
			expect(ps.routeZombies[R("Z1").id]).toBeNil()
			expect(Dispatch._test.liveZombies()).toBe(0)
			expect(Transport.getStats().ZombieCalls).toBe(0)
		end)

		it("still cancels a leaving player's CancelOnTimeout calls at their deadline", function()
			local p = newPlayer()
			call(p, "Cancel", 1, "c") -- Timeout 1, CancelOnTimeout
			call(p, "Wait", 2, "w") -- Timeout 10, left running
			local th = gates["c"]
			local grace = Config.get().WatchdogGrace
			Transport._test.removePlayer(p)
			expect(Dispatch._test.departedCount()).toBe(1)
			now += 0.5
			Transport._test.sweep(now)
			expect(coroutine.status(th)).toBe("suspended") -- before its deadline
			now = 1000 + 1 + grace + 0.1
			Transport._test.sweep(now)
			expect(coroutine.status(th)).toBe("dead")
			gates["c"] = nil
			expect(Dispatch._test.departedCount()).toBe(1) -- "w" is still watched
			now = 1000 + 10 + grace + 0.1
			Transport._test.sweep(now)
			expect(Dispatch._test.departedCount()).toBe(0)
			expect(coroutine.status(gates["w"])).toBe("suspended") -- not CancelOnTimeout
			open("w", "late")
			Transport._test.flush()
			expect(#fires).toBe(0)
		end)

		it("fail forgets every player; late finishes reply nothing", function()
			local p = newPlayer()
			local early = newPlayer(false)
			rt.signals.S.Sig:Fire(early, "queued")
			call(p, "Wait", 1, "w")
			local ps = st(p)
			Transport.fail()
			expect(ps.gone).toBe(true)
			expect(st(p)).toBeNil()
			expect(st(early)).toBeNil()
			expect(Transport.getStats().Players).toBe(0)
			open("w", "late")
			Transport._test.flush()
			expect(#fires).toBe(0)
		end)
	end)

	describe("replies", function()
		it("awaits a returned Promise", function()
			local p = newPlayer()
			call(p, "Prom", 1, "ok")
			call(p, "Prom", 2, "reject")
			call(p, "Prom", 3, "boom")
			local msgs = flushTo(p)
			local ok, errs = only(msgs, "OK"), only(msgs, "ERR")
			expect(ok[1].callId).toBe(1)
			expect(ok[1].args[1]).toBe(5)
			expect(errs[1].callId).toBe(2)
			expect(errs[1].code).toBe(ERR.Rejected)
			expect(errs[1].msg).toBe("nope")
			expect(errs[1].data).toBe(9)
			expect(errs[2].callId).toBe(3)
			expect(errs[2].code).toBe(ERR.InternalError)
			expect(errs[2].incident).never.toBeNil()
		end)

		it("counts a pending Promise as a yielded call until it settles", function()
			local p = newPlayer()
			call(p, "Prom", 1, "pending")
			local ps = st(p)
			expect(ps.running).toBe(1)
			pendingResolve(7)
			task.wait()
			task.wait()
			expect(ps.running).toBe(0)
			local ok = only(flushTo(p), "OK")
			expect(#ok).toBe(1)
			expect(ok[1].args[1]).toBe(7)
		end)

		it("sends Reject returned or thrown as ERR Rejected", function()
			local p = newPlayer()
			call(p, "Rej", 1, "no", { a = 1 })
			call(p, "Rej", 2, "plain")
			call(p, "Throw", 3, "reject")
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(3)
			expect(errs[1].code).toBe(ERR.Rejected)
			expect(errs[1].msg).toBe("no")
			expect(errs[1].data).toEqual({ a = 1 })
			expect(errs[2].msg).toBe("plain")
			expect(errs[2].hasData).toBeNil()
			expect(errs[3].msg).toBe("thrown")
			expect(errs[3].incident).toBeNil()
		end)

		it("sanitizes InternalError unless ForwardErrors allows the text; OnError gets the details", function()
			local p = newPlayer()
			local seen = {}
			Dispatch.onError(function(info)
				table.insert(seen, info)
			end)
			call(p, "Throw", 1, "error")
			local errs = only(flushTo(p), "ERR")
			expect(errs[1].code).toBe(ERR.InternalError)
			expect(errs[1].flags).toBe(C.ErrFlag.Incident)
			expect(errs[1].msg).toBeNil()
			expect(#seen).toBe(1)
			expect(seen[1].Service).toBe("S")
			expect(seen[1].Member).toBe("Throw")
			expect(seen[1].Player).toBe(p)
			expect(seen[1].Incident).toBe(Errors.hex(errs[1].incident))
			expect(string.find(seen[1].Message, "secret detail", 1, true) ~= nil).toBe(true)
			Dispatch._test.setForwardErrors(true)
			call(p, "Throw", 2, "error")
			errs = only(flushTo(p), "ERR")
			expect(errs[1].flags).toBe(C.ErrFlag.Incident + C.ErrFlag.Msg)
			expect(string.find(errs[1].msg, "secret detail", 1, true) ~= nil).toBe(true)
		end)

		it("keeps nil holes and `false, msg` returns", function()
			local p = newPlayer()
			call(p, "Echo", 1, nil, 2, nil)
			call(p, "Echo", 2, false, "x")
			local ok = only(flushTo(p), "OK")
			expect(ok[1].n).toBe(3)
			expect(ok[1].args[2]).toBe(2)
			expect(ok[2].args[1]).toBe(false)
			expect(ok[2].args[2]).toBe("x")
		end)
	end)

	describe("middleware", function()
		it("allows only an exact true; false, msg denies with msg; other values deny", function()
			local p = newPlayer()
			call(p, "Guard", 1, "allow")
			call(p, "Guard", 2, "reason")
			call(p, "Guard", 3, "truthy")
			call(p, "Guard", 4, "none")
			local msgs = flushTo(p)
			local ok, errs = only(msgs, "OK"), only(msgs, "ERR")
			expect(#ok).toBe(1)
			expect(ok[1].args[1]).toBe("ran")
			expect(#errs).toBe(3)
			expect(errs[1].code).toBe(ERR.Denied)
			expect(errs[1].msg).toBe("nope")
			expect(errs[2].code).toBe(ERR.Denied)
			expect(errs[2].msg).toBeNil()
			expect(errs[3].msg).toBeNil()
		end)

		it("reads the member middleware and handler on every call (set or replaced after boot)", function()
			local p = newPlayer()
			local module = R("Echo").module
			local mw = module.Middleware
			local client = R("Echo").self
			call(p, "Echo", 1, "a") -- no middleware at boot
			mw.Echo = function(_: any, v: any): boolean -- set later, as a LorenIgnite would
				return v == "ok"
			end
			call(p, "Echo", 2, "no")
			call(p, "Echo", 3, "ok")
			local original = client.Echo
			client.Echo = function(_: any, _p: any, v: any): string -- a wrapper installed after boot
				return "wrapped:" .. v
			end
			call(p, "Echo", 4, "ok")
			mw.Echo = nil
			client.Echo = original
			call(p, "Echo", 5, "free")
			local msgs = flushTo(p)
			local ok, errs = only(msgs, "OK"), only(msgs, "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].callId).toBe(2)
			expect(errs[1].code).toBe(ERR.Denied)
			expect(#ok).toBe(4)
			expect(ok[2].args[1]).toBe("ok")
			expect(ok[3].args[1]).toBe("wrapped:ok")
			expect(ok[4].args[1]).toBe("free")
			-- a replacement written colon-style (same parameters as the handler) is denied
			mw.Typed = function(_: any, _p: any, _v: any): boolean
				return true
			end
			call(p, "Typed", 6, 3)
			mw.Typed = function(_: any, _v: any): boolean
				return true
			end
			call(p, "Typed", 7, 4)
			msgs = flushTo(p)
			expect(only(msgs, "ERR")[1].callId).toBe(6)
			expect(only(msgs, "ERR")[1].code).toBe(ERR.Denied)
			expect(only(msgs, "OK")[1].args[1]).toBe(4)
			-- ClientEvents too
			mw.Ev = function(): boolean
				return false
			end
			send(p, { eventMsg("Ev", nil, 1) })
			expect(#evLog).toBe(0)
			expect(dropped(p, DROP.EventDenied)).toBe(1)
			mw.Ev = nil
			send(p, { eventMsg("Ev", nil, 2) })
			expect(#evLog).toBe(1)
		end)

		it("builds a handler traceback only when it will be logged or given to OnError", function()
			local p = newPlayer()
			call(p, "Throw", 1, "error") -- the route's first failure is logged with its traceback
			expect(Dispatch._test.tracesBuilt()).toBe(1)
			for i = 2, 20 do
				call(p, "Throw", i, "error") -- the route's log line is throttled for 10 s
			end
			expect(Dispatch._test.tracesBuilt()).toBe(1)
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(20)
			for _, e in errs do
				expect(e.code).toBe(ERR.InternalError)
				expect(e.incident).never.toBeNil()
			end
			local seen = {}
			Dispatch.onError(function(info)
				table.insert(seen, info)
			end)
			call(p, "Throw", 21, "error") -- OnError takes the details
			expect(Dispatch._test.tracesBuilt()).toBe(2)
			task.wait()
			expect(#seen).toBe(1)
			expect(#seen[1].Traceback > 0).toBe(true)
		end)

		it("denies every call of a colon-flagged middleware", function()
			local p = newPlayer()
			call(p, "Colon", 1)
			local errs = only(flushTo(p), "ERR")
			expect(#errs).toBe(1)
			expect(errs[1].code).toBe(ERR.Denied)
		end)

		it("runs global middleware first with the route info", function()
			local p = newPlayer()
			local infos = {}
			Dispatch.addMiddleware(function(player, info, ...)
				table.insert(infos, info)
				return info.Member ~= "Echo"
			end)
			call(p, "Echo", 1, "x")
			call(p, "Typed", 2, 3)
			local msgs = flushTo(p)
			expect(only(msgs, "ERR")[1].code).toBe(ERR.Denied)
			expect(only(msgs, "OK")[1].args[1]).toBe(3)
			expect(infos[1]).toBe(R("Echo").info)
			expect(infos[1].Kind).toBe("Method")
		end)

		it("drops denied ClientEvents and delivers allowed ones", function()
			local p = newPlayer()
			send(p, { eventMsg("GuardEv", nil, "deny"), eventMsg("GuardEv", nil, "allow") })
			expect(#evLog).toBe(1)
			expect(evLog[1].mode).toBe("allow")
			expect(evLog[1].player).toBe(p)
			expect(dropped(p, DROP.EventDenied)).toBe(1)
			expect(#flushTo(p)).toBe(0)
		end)
	end)

	describe("ClientEvents", function()
		it("delivers events with the player and every argument", function()
			local p = newPlayer()
			send(p, { eventMsg("Ev", nil, 1, nil, "three") })
			expect(#evLog).toBe(1)
			expect(evLog[1].player).toBe(p)
			expect(evLog[1].args.n).toBe(3)
			expect(evLog[1].args[3]).toBe("three")
			expect(argvClear()).toBe(true)
		end)

		it("drops Ordered events older than the last one; silence resets the receiver", function()
			local p = newPlayer()
			for _, s in { 5, 4, 5, 6 } do
				send(p, { eventMsg("Fast", s, s) }, true)
			end
			expect(#evLog).toBe(2)
			expect(evLog[1].v).toBe(5)
			expect(evLog[2].v).toBe(6)
			expect(dropped(p, DROP.Stale)).toBe(2)
			send(p, { eventMsg("Fast", 65535, 9) }, true)
			expect(#evLog).toBe(2) -- (65535 - 6) % 65536 >= 32768: stale
			now += LIM.ORDERED_RESET + 0.5
			send(p, { eventMsg("Fast", 1, 1) }, true)
			expect(#evLog).toBe(3)
		end)

		it("drops rate-limited events without a reply", function()
			local p = newPlayer()
			send(p, { eventMsg("Slow", nil, 1), eventMsg("Slow", nil, 2) })
			expect(dropped(p, DROP.EventLimited)).toBe(1)
			expect(#flushTo(p)).toBe(0)
		end)
	end)

	describe("ServerSignal", function()
		it("FireFor and FireExcept reach exactly their targets", function()
			local p1, p2, p3 = newPlayer(), newPlayer(), newPlayer()
			local sig = rt.signals.S.Sig
			sig:FireFor({ p1, p2 }, "for")
			sig:FireExcept(p1, "except one")
			sig:FireExcept({ p1, p2 }, "except two")
			Transport._test.flush()
			local function texts(p: any): { any }
				local out = {}
				for _, m in received(p) do
					table.insert(out, m.args[1])
				end
				return out
			end
			expect(texts(p1)).toEqual({ "for" })
			expect(texts(p2)).toEqual({ "for", "except one" })
			expect(texts(p3)).toEqual({ "except one", "except two" })
		end)

		it("counts Fire to a departed player as dropped, without an error", function()
			ServerSignal._test.setPlayerCheck(function(p: any): boolean
				return type(p) == "table" and p.UserId ~= nil
			end)
			local p1, p2 = newPlayer(), newPlayer()
			Transport._test.removePlayer(p2)
			local sig = rt.signals.S.Sig
			sig:Fire(p2, "gone")
			sig:FireFor({ p1, p2 }, "both")
			expect(Transport.getStats().SignalsDropped).toBe(2)
			Transport._test.flush()
			expect(#received(p1)).toBe(1)
			expect(#fires).toBe(0)
		end)

		it("raises on misuse at the caller", function()
			local p = newPlayer()
			local sig = rt.signals.S.Sig
			expect(function()
				sig:Fire("nobody", 1)
			end).toThrow("must be a Player")
			expect(function()
				sig:FireFor("nobody", 1)
			end).toThrow("array of Players")
			expect(function()
				rt.signals.S.USig:Fire(p, 5)
			end).toThrow("S.USig:Fire: arg 1 BadType")
			expect(function()
				sig:Connect(noop)
			end).toThrow("Service Signals are server-to-client; Connect on the client proxy")
			expect(function()
				sig.Fire(p, 1)
			end).toThrow()
			-- the scratch writer is clean after a failed encode
			sig:Fire(p, "after")
			local msgs = flushTo(p)
			expect(#msgs).toBe(1)
			expect(msgs[1].args[1]).toBe("after")
		end)

		it("Ordered Signals carry one shared seq per route, starting at 1", function()
			local p1, p2 = newPlayer(), newPlayer()
			local osig = rt.signals.S.OSig
			osig:FireAll(1)
			osig:FireAll(2)
			osig:Fire(p1, 3)
			expect(ServerSignal._test.lastSeq(R("OSig").id)).toBe(3)
			Transport._test.flush()
			local m1, m2 = received(p1), received(p2)
			expect(#m1).toBe(3)
			expect(m1[1].seq).toBe(1)
			expect(m1[2].seq).toBe(2)
			expect(m1[3].seq).toBe(3)
			expect(#m2).toBe(2)
			expect(m2[2].seq).toBe(2)
		end)

		it("FireAll reaches pre-HELLO players on reliable routes only", function()
			local early = newPlayer(false)
			local ready = newPlayer()
			rt.signals.S.Sig:FireAll("r")
			rt.signals.S.USig:FireAll("u")
			expect(st(early).out.nmsg).toBe(1)
			expect(dropped(early, DROP.UnreliableEarly)).toBe(1)
			Transport._test.flush()
			expect(#received(ready)).toBe(2)
			expect(#received(early)).toBe(0)
		end)
	end)
end
