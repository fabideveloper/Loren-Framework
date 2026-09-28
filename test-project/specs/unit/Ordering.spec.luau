--!strict
-- Safety net for the signal rework (design/loren-2.0/SIGNALS-PERF.md, step 1): per-player order,
-- joins and HELLO during broadcasts, the pre-HELLO outbox, the Instance sidecar, the unreliable size
-- limit, fixed-size routes (B9 S7/C6), the server's in-frame order (B2) and the client's delivery order.
-- The server's captured frames are decoded per player; the client tests feed those same frames
-- (MANIFEST first) into ClientNet. Order is compared per flush as one stream (streamTo), not per
-- RemoteEvent frame, so B4/B8 may split frames. The multi-client version is specs/v2/*/Order.spec.luau.
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
local ClientNet = require(Runtime.ClientNet) :: any
local Server = ServerScriptService.LorenServer
local Routes = require(Server.Routes)
local Transport = require(Server.Transport)
local Outbox = require(Server.Outbox) :: any
local Dispatch = require(Server.Dispatch)
local ServerSignal = require(Server.ServerSignal)
local Limits = require(Server.Limits)
local Violations = require(Server.Violations)

local T = Schema.T
local K = C.Kind
local OP = C.Op
local LIM = C.Limit
local SEAL = LIM.UNRELIABLE_SEAL
local FRAME_DROPPED = C.Notice.FrameDropped
local REJECTED = C.Err.Rejected
local V_ROUTE = C.Violation.Route

type Fire = { channel: string, player: any, frame: buffer, refs: { any }? }

local function noop(...: any) end

-- Harness state (rebuilt by setup) -------------------------------------------------------------------

local now = 1000
local rt: any = nil
local byName: { [string]: any } = {}
local fires: { Fire } = {} -- S->C, captured from the outbox
local c2s: { any } = {} -- C->S, captured from ClientNet
local gates: { [string]: thread } = {}
local events: { any } = {} -- UEv deliveries on the server
local trail: { string } = {} -- server-side handler order (Ev listeners, Note calls)
local nextUid = 0
local seqN = 0

local function gate(key: string): ...any
	gates[key] = coroutine.running()
	return coroutine.yield()
end

-- Resumes a parked Gate call: ("ok", tag), ("err", tag) or ("fire", tag).
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
		-- "ok" replies tag, "err" rejects with tag, "fire" fires Sig(tag .. "!") to the caller first.
		member(M, "Gate", function(_: any, player: any, key: any): any
			local mode, tag = gate(key)
			if mode == "err" then
				return Errors.reject(tag)
			elseif mode == "fire" then
				rt.signals.S.Sig:Fire(player, tag .. "!")
			end
			return tag
		end),
		member(M, "Echo", function(_: any, _: any, ...: any): ...any
			return ...
		end),
		member(M, "Note", function(_: any, _: any, tag: any): any
			table.insert(trail, "call " .. tostring(tag))
			return tag
		end),
		member(E, "Ev", nil, Schema.event(T.string(32))),
		member(E, "UEv", nil, Schema.event(T.string(1000), { Unreliable = true })),
		member(S, "Need", nil, Schema.signal(T.string(32), T.Instance(), T.string(32))),
		member(S, "Opt", nil, Schema.signal(T.string(32), T.optional(T.Instance()), T.string(32))),
		member(S, "Pos", nil, Schema.signal(T.u16, T.Vector3)), -- fixed size (B9 S7/C6)
		member(S, "Sig"),
		member(S, "UPos", nil, Schema.signal(T.u16, { Unreliable = true, Ordered = true })), -- fixed, Ordered
		member(S, "USig", nil, Schema.signal(T.string(1000), { Unreliable = true })),
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
	events = {}
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
	rt.events.S.UEv:Connect(function(_: any, s: any)
		table.insert(events, s)
	end)
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

local function v(x: number): Vector3
	return Vector3.new(x, 0, 0)
end

-- C->S ------------------------------------------------------------------------------------------------

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

-- seq:u16 nmsg:u16 nrefs:u8, then len:varint + message for each (messages here stay under 128 B).
local function frameOf(msgs: { buffer }): buffer
	local total = 5
	for _, m in msgs do
		assert(buffer.len(m) < 128, "test message too long for a 1-byte length")
		total += 1 + buffer.len(m)
	end
	seqN = (seqN + 1) % 65536
	local b = buffer.create(total)
	buffer.writeu16(b, 0, seqN)
	buffer.writeu16(b, 2, #msgs)
	buffer.writeu8(b, 4, 0)
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

-- A reliable, unordered ClientEvent message.
local function eventMsg(name: string, ...: any): buffer
	local r = R(name)
	local w = Codec.newWriter(64, true)
	Codec.writeHead(w, r.id)
	assert(r.args.encode(w, select("#", ...), ...) == 0, "encode failed")
	return writerBytes(w)
end

-- A message whose head names a Signal route: a Route violation on the server.
local function signalHead(name: string): buffer
	local w = Codec.newWriter(8, true)
	Codec.writeHead(w, R(name).id)
	return writerBytes(w)
end

local function call(p: any, name: string, callId: number, ...: any)
	Transport._test.frame(false, p, frameOf({ callMsg(name, callId, ...) }), nil)
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

-- Removes and returns the captured fires to `p` (optionally one channel), in fire order.
local function takeFires(p: any, channel: string?): { Fire }
	local mine: { Fire }, keep: { Fire } = {}, {}
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

-- S->C decoding ------------------------------------------------------------------------------------------

local function show(x: any): string
	if typeof(x) == "Instance" then
		return (x :: Instance).Name
	elseif typeof(x) == "Vector3" then
		local vec = x :: Vector3
		return string.format("<%g,%g,%g>", vec.X, vec.Y, vec.Z)
	end
	return tostring(x)
end

local function joinArgs(argv: { any }, n: number): string
	local parts: { string } = {}
	for i = 1, n do
		table.insert(parts, show(argv[i]))
	end
	return table.concat(parts, " ")
end

-- One S->C frame as lines: "MANIFEST", "OK id values", "ERR id code msg", "NOTICE kind first count",
-- "<Signal> args" or "<Signal> #seq args" (Ordered). Instances by Name, an Instance that arrived nil as nil.
local function decode(frame: buffer, refs: { any }?): { string }
	local ctx = Codec.newReadCtx(false, false)
	Codec.beginFrame(ctx, refs, 0)
	local out: { string } = {}
	local o, lim = 0, buffer.len(frame)
	while o < lim do
		local h, q = Codec.readHead(frame, o, lim)
		assert(h ~= 0, "bad S->C head at " .. o)
		if h == -OP.MANIFEST then
			table.insert(out, "MANIFEST")
			o = q + 4 + buffer.readu32(frame, q)
		elseif h == -OP.OK then
			local argv = {}
			Codec.beginMessage(ctx, true)
			local n, e = Codec.readArgs(frame, q + 2, lim, ctx, argv, 255)
			assert(ctx.err == 0, "OK payload status " .. ctx.err)
			table.insert(out, string.format("OK %d %s", buffer.readu16(frame, q), joinArgs(argv, n)))
			o = e
		elseif h == -OP.ERR then
			local flags = buffer.readu8(frame, q + 3)
			local p = q + 4
			local msg = ""
			if bit32.btest(flags, C.ErrFlag.Msg) then
				local len, np = Codec.readVarint(frame, p, lim)
				msg = buffer.readstring(frame, np, len)
				p = np + len
			end
			if bit32.btest(flags, C.ErrFlag.Data) then
				Codec.beginMessage(ctx, true)
				local _, np = Codec.readValue(frame, p, lim, ctx, 0)
				p = np
			end
			if bit32.btest(flags, C.ErrFlag.Incident) then
				p += 4
			end
			local id, code = buffer.readu16(frame, q), buffer.readu8(frame, q + 2)
			table.insert(out, string.format("ERR %d %d %s", id, code, msg))
			o = p
		elseif h == -OP.NOTICE then
			local kind, first, count =
				buffer.readu8(frame, q), buffer.readu16(frame, q + 1), buffer.readu16(frame, q + 3)
			table.insert(out, string.format("NOTICE %d %d %d", kind, first, count))
			o = q + 5
		else
			assert(h > 0, "unexpected control op " .. -h)
			local r = rt.routes[h]
			local seq = ""
			if r.ordered then
				seq = " #" .. buffer.readu16(frame, q)
				q += 2
			end
			local argv = {}
			Codec.beginMessage(ctx, true)
			local n, e = r.args.decode(frame, q, lim, ctx, argv)
			assert(ctx.err == 0, r.member .. " payload status " .. ctx.err)
			table.insert(out, r.member .. seq .. " " .. joinArgs(argv, n))
			o = e
		end
	end
	return out
end

-- Everything fired to `p` on one channel since the last take, decoded and joined in fire order.
local function channelStream(p: any, channel: string): { string }
	local out: { string } = {}
	for _, f in takeFires(p, channel) do
		for _, line in decode(f.frame, f.refs) do
			table.insert(out, line)
		end
	end
	return out
end

local function streamTo(p: any): { string }
	return channelStream(p, "Reliable")
end

local function ustreamTo(p: any): { string }
	return channelStream(p, "Unreliable")
end

-- The refs of every reliable fire to `p`, joined in fire order.
local function refsTo(p: any): ({ any }, { string })
	local refs: { any }, lines: { string } = {}, {}
	for _, f in takeFires(p, "Reliable") do
		local list: { any } = f.refs or {}
		for _, ref in list do
			table.insert(refs, ref)
		end
		for _, line in decode(f.frame, f.refs) do
			table.insert(lines, line)
		end
	end
	return refs, lines
end

-- Flushes, then each player's reliable and unreliable stream of that flush (same order as `players`).
local function flushStreams(players: { any }): ({ { string } }, { { string } })
	flush()
	local rel: { { string } }, unr: { { string } } = {}, {}
	for i, p in players do
		rel[i] = streamTo(p)
		unr[i] = ustreamTo(p)
	end
	return rel, unr
end

local function notice(first: number, count: number): string
	return string.format("NOTICE %d %d %d", FRAME_DROPPED, first, count)
end

local function rejected(callId: number, msg: string): string
	return string.format("ERR %d %d %s", callId, REJECTED, msg)
end

local function folder(name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	return f
end

-- ClientNet, fed the server's frames ----------------------------------------------------------------------

local function toClient(p: any)
	for _, f in takeFires(p) do
		ClientNet._test.receive(f.frame, f.refs, f.channel == "Unreliable")
	end
end

local function toServer(p: any)
	ClientNet._test.flushNow()
	local list = c2s
	c2s = {}
	for _, f in list do
		Transport._test.frame(f.unreliable, p, f.frame, f.refs)
	end
end

-- HELLO for `p` (a player without one), then its first frame (MANIFEST) into a fresh ClientNet.
local function connectClient(p: any)
	ClientNet._test.setFire(function(unreliable: boolean, frame: buffer, refs: { any }?)
		table.insert(c2s, { unreliable = unreliable, frame = frame, refs = refs })
	end)
	ClientNet._test.begin()
	hello(p)
	flush()
	toClient(p)
	assert(#ClientNet.routes() == rt.count, "the client did not install the server's MANIFEST")
end

local function route(name: string): any
	return ClientNet.routes()[R(name).id]
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

	describe("per-player order (server outbox)", function()
		it("one flush: every Fire kind (variable and fixed size), OK, ERR and NOTICE keep call order", function()
			local p1, p2, p3 = newPlayer(), newPlayer(), newPlayer()
			call(p1, "Gate", 1, "a")
			call(p2, "Gate", 2, "b")
			flush()
			expect(#fires).toBe(0) -- both calls are parked: nothing to send yet
			local S = rt.signals.S
			local sig, pos, upos = S.Sig, S.Pos, S.UPos
			sig:Fire(p1, "1")
			upos:Fire(p1, 1)
			sig:FireAll("2")
			pos:FireAll(20, v(1)) -- fixed size between two variable-size broadcasts
			upos:FireAll(2)
			sig:FireAll("3")
			sig:Fire(p1, "4") -- per-player, two broadcasts, per-player
			pos:Fire(p1, 40, v(2))
			sig:FireFor({ p1, p2 }, "5")
			pos:FireFor({ p2, p3 }, 50, v(3))
			upos:FireFor({ p2, p3 }, 3)
			open("a", "ok", "6")
			sig:FireExcept(p1, "7")
			upos:FireExcept(p1, 4)
			Outbox.notice(st(p3), FRAME_DROPPED, 100, 5) -- a NOTICE at this point of p3's frame
			sig:FireAll("8")
			pos:FireExcept({ p2 }, 80, v(4))
			open("b", "err", "9")
			sig:FireExcept({ p2, p3 }, "10")
			call(p3, "Echo", 3, "11") -- answered at once
			sig:FireAll("12")
			Outbox.recordDrop(st(p1), false, 200) -- a FrameDropped run: its NOTICE ends the flush
			sig:Fire(p1, "13")
			local rel, unr = flushStreams({ p1, p2, p3 })
			expect(rel[1]).toEqual({
				"Sig 1",
				"Sig 2",
				"Pos 20 <1,0,0>",
				"Sig 3",
				"Sig 4",
				"Pos 40 <2,0,0>",
				"Sig 5",
				"OK 1 6",
				"Sig 8",
				"Pos 80 <4,0,0>",
				"Sig 10",
				"Sig 12",
				"Sig 13",
				notice(200, 1),
			})
			expect(rel[2]).toEqual({
				"Sig 2",
				"Pos 20 <1,0,0>",
				"Sig 3",
				"Sig 5",
				"Pos 50 <3,0,0>",
				"Sig 7",
				"Sig 8",
				rejected(2, "9"),
				"Sig 12",
			})
			expect(rel[3]).toEqual({
				"Sig 2",
				"Pos 20 <1,0,0>",
				"Sig 3",
				"Pos 50 <3,0,0>",
				"Sig 7",
				notice(100, 5),
				"Sig 8",
				"Pos 80 <4,0,0>",
				"OK 3 11",
				"Sig 12",
			})
			-- Ordered unreliable: one seq per route and Fire, each player's order kept.
			expect(unr[1]).toEqual({ "UPos #1 1", "UPos #2 2" })
			expect(unr[2]).toEqual({ "UPos #2 2", "UPos #3 3", "UPos #4 4" })
			expect(unr[3]).toEqual({ "UPos #2 2", "UPos #3 3", "UPos #4 4" })
			expect(#fires).toBe(0)
		end)

		it("across flushes: order holds from flush to flush; a flush-time NOTICE ends its own flush", function()
			local p1, p2, p3 = newPlayer(), newPlayer(), newPlayer()
			local players = { p1, p2, p3 }
			local S = rt.signals.S
			local sig, pos, upos = S.Sig, S.Pos, S.UPos
			sig:Fire(p1, "1")
			pos:Fire(p2, 11, v(1))
			sig:FireAll("2")
			upos:FireAll(1)
			Outbox.recordDrop(st(p2), false, 50)
			sig:Fire(p2, "3")
			local rel1, unr1 = flushStreams(players)
			sig:FireAll("4")
			pos:FireAll(44, v(4))
			sig:FireAll("5")
			sig:FireFor({ p2, p3 }, "6")
			upos:FireFor({ p1, p3 }, 2)
			pos:FireFor({ p1 }, 66, v(6))
			sig:Fire(p1, "7")
			local rel2, unr2 = flushStreams(players)
			local rel3, unr3 = flushStreams(players) -- nothing new: no fire at all
			expect(#fires).toBe(0)
			sig:FireExcept(p3, "8")
			pos:FireExcept(p1, 88, v(8))
			Outbox.notice(st(p3), FRAME_DROPPED, 60, 1)
			sig:FireAll("9")
			upos:Fire(p2, 3)
			local rel4, unr4 = flushStreams(players)
			expect(rel1).toEqual({
				{ "Sig 1", "Sig 2" },
				{ "Pos 11 <1,0,0>", "Sig 2", "Sig 3", notice(50, 1) },
				{ "Sig 2" },
			})
			expect(rel2).toEqual({
				{ "Sig 4", "Pos 44 <4,0,0>", "Sig 5", "Pos 66 <6,0,0>", "Sig 7" },
				{ "Sig 4", "Pos 44 <4,0,0>", "Sig 5", "Sig 6" },
				{ "Sig 4", "Pos 44 <4,0,0>", "Sig 5", "Sig 6" },
			})
			expect(rel3).toEqual({ {}, {}, {} })
			expect(rel4).toEqual({
				{ "Sig 8", "Sig 9" },
				{ "Sig 8", "Pos 88 <8,0,0>", "Sig 9" },
				{ "Pos 88 <8,0,0>", notice(60, 1), "Sig 9" },
			})
			expect(unr1).toEqual({ { "UPos #1 1" }, { "UPos #1 1" }, { "UPos #1 1" } })
			expect(unr2).toEqual({ { "UPos #2 2" }, {}, { "UPos #2 2" } })
			expect(unr3).toEqual({ {}, {}, {} })
			expect(unr4).toEqual({ {}, { "UPos #3 3" }, {} })
		end)

		it("a reply never overtakes a signal fired before it in the same flush", function()
			local p, other = newPlayer(), newPlayer()
			local sig = rt.signals.S.Sig
			call(p, "Gate", 1, "g1") -- received first, answered later
			sig:Fire(p, "before")
			call(p, "Echo", 2, "sync")
			open("g1", "fire", "x") -- the handler fires x!, then returns
			sig:Fire(p, "after")
			flush()
			expect(streamTo(p)).toEqual({ "Sig before", "OK 2 sync", "Sig x!", "OK 1 x", "Sig after" })
			call(p, "Gate", 3, "g3")
			sig:FireAll("b1")
			flush()
			expect(streamTo(p)).toEqual({ "Sig b1" })
			open("g3", "err", "late")
			sig:Fire(p, "b2")
			sig:FireAll("b3")
			flush()
			expect(streamTo(p)).toEqual({ rejected(3, "late"), "Sig b2", "Sig b3" })
			expect(streamTo(other)).toEqual({ "Sig b1", "Sig b3" })
		end)

		it("a failed fixed-size encode leaves the channels as they were; later OK/ERR touch only theirs", function()
			local p1, p2 = newPlayer(), newPlayer()
			local S = rt.signals.S
			call(p2, "Gate", 1, "g")
			S.Sig:Fire(p1, "a", folder("I1"))
			S.Pos:Fire(p1, 1, v(1))
			S.UPos:Fire(p1, 1)
			local out, uout = st(p1).out, st(p1).uout
			local function snapshot(): { any }
				return {
					out.w.n,
					out.nmsg,
					out.w.nrefs,
					buffer.readstring(out.w.buf, 0, out.w.n),
					uout.w.n,
					uout.nmsg,
					buffer.readstring(uout.w.buf, 0, uout.w.n),
				}
			end
			local before = snapshot()
			expect(function()
				S.Pos:Fire(p1, 70000, v(2))
			end).toThrow("arg 1")
			expect(function()
				S.Pos:Fire(p1, 2, "not a Vector3")
			end).toThrow("arg 2")
			expect(function()
				S.Pos:FireAll(2, Vector3.new(0 / 0, 0, 0))
			end).toThrow("arg 2")
			expect(function()
				S.Pos:FireFor({ p1, p2 }, -1, v(2))
			end).toThrow("arg 1")
			expect(function()
				S.Pos:FireExcept(p2, 1.5, v(2))
			end).toThrow("arg 1")
			expect(function()
				S.UPos:Fire(p1, 1.5)
			end).toThrow("arg 1")
			expect(snapshot()).toEqual(before)
			call(p2, "Echo", 2, "ok") -- sendOk to another player right after the failures
			open("g", "err", "no") -- and a sendErr
			expect(snapshot()).toEqual(before)
			S.Pos:Fire(p1, 3, v(3))
			flush()
			expect(streamTo(p1)).toEqual({ "Sig a I1", "Pos 1 <1,0,0>", "Pos 3 <3,0,0>" })
			expect(streamTo(p2)).toEqual({ "OK 2 ok", rejected(1, "no") })
			local u = ustreamTo(p1)
			expect(#u).toBe(1)
			expect(string.match(u[1], "^UPos #%d+ 1$")).never.toBeNil()
			expect(#fires).toBe(0)
		end)
	end)

	describe("joins and HELLO while broadcasts flow", function()
		it("nothing before HELLO; then MANIFEST first and the reliable traffic since the join, in order", function()
			local p1 = newPlayer()
			local S = rt.signals.S
			local sig, usig, pos, upos = S.Sig, S.USig, S.Pos, S.UPos
			sig:FireAll("b1") -- before the join: never for p2
			local p2 = newPlayer(false) -- joined (PlayerAdded), no HELLO yet
			local dropped = Transport.getStats().SignalsDropped
			sig:FireAll("b2")
			pos:FireAll(2, v(2)) -- fixed size into the pre-HELLO outbox
			usig:FireAll("u2") -- unreliable before HELLO: dropped and counted
			upos:FireAll(1)
			sig:Fire(p2, "own3")
			usig:Fire(p2, "uown")
			sig:FireExcept(p2, "x4")
			sig:FireFor({ p1 }, "f5")
			expect(st(p2).viol.winDrop[C.Drop.UnreliableEarly]).toBe(3)
			expect(Transport.getStats().SignalsDropped - dropped).toBe(3)
			flush()
			expect(#takeFires(p2)).toBe(0) -- the outbox waits for HELLO
			local p1First = streamTo(p1)
			local p1FirstU = ustreamTo(p1)
			sig:FireAll("b5")
			hello(p2) -- between two broadcasts of one flush
			sig:FireAll("b6")
			pos:FireAll(6, v(6))
			sig:Fire(p2, "own7")
			flush()
			expect(streamTo(p2)).toEqual({
				"MANIFEST",
				"Sig b2",
				"Pos 2 <2,0,0>",
				"Sig own3",
				"Sig b5",
				"Sig b6",
				"Pos 6 <6,0,0>",
				"Sig own7",
			})
			expect(#takeFires(p2)).toBe(0) -- nothing unreliable
			expect(p1First).toEqual({ "Sig b1", "Sig b2", "Pos 2 <2,0,0>", "Sig x4", "Sig f5" })
			expect(p1FirstU).toEqual({ "USig u2", "UPos #1 1" })
			expect(streamTo(p1)).toEqual({ "Sig b5", "Sig b6", "Pos 6 <6,0,0>" })
			expect(#fires).toBe(0)
		end)

		it("the only player has not sent HELLO: broadcasts still queue for it; HELLO gets MANIFEST first", function()
			local p = newPlayer(false)
			local S = rt.signals.S
			S.Sig:FireAll("b1")
			S.Pos:FireAll(2, v(2))
			S.Sig:FireFor({ p }, "f3")
			S.Pos:FireExcept({}, 4, v(4))
			flush()
			expect(#takeFires(p)).toBe(0)
			hello(p)
			flush()
			expect(streamTo(p)).toEqual({ "MANIFEST", "Sig b1", "Pos 2 <2,0,0>", "Sig f3", "Pos 4 <4,0,0>" })
			expect(#fires).toBe(0)
		end)

		it("a repeat HELLO mid-flush: MANIFEST first, replies purged, signals and later broadcasts kept", function()
			local p1, p2 = newPlayer(), newPlayer()
			local S = rt.signals.S
			call(p1, "Echo", 1, "stale") -- a reply for the old session
			S.Sig:FireAll("r1")
			S.Pos:Fire(p1, 1, v(1))
			now += LIM.REHELLO_MIN + 1
			hello(p1)
			S.Sig:FireAll("r2")
			S.Sig:Fire(p1, "own")
			flush()
			expect(streamTo(p1)).toEqual({ "MANIFEST", "Sig r1", "Pos 1 <1,0,0>", "Sig r2", "Sig own" })
			expect(streamTo(p2)).toEqual({ "Sig r1", "Sig r2" })
		end)
	end)

	describe("Instance sidecar", function()
		it("refs follow their messages per player when per-player and broadcast messages interleave", function()
			local p1, p2, p3 = newPlayer(), newPlayer(), newPlayer()
			local S = rt.signals.S
			local sig = S.Sig
			local i = { folder("I1"), folder("I2"), folder("I3"), folder("I4"), folder("I5") }
			sig:Fire(p1, "a", i[1])
			sig:FireAll("b", i[2])
			S.Pos:FireAll(7, v(7)) -- no refs between messages with refs
			sig:Fire(p1, "c", i[3])
			sig:FireFor({ p2, p3 }, "d", i[4])
			sig:FireExcept(p2, "e", i[5])
			sig:FireAll("f", 6)
			flush()
			local r1, l1 = refsTo(p1)
			local r2, l2 = refsTo(p2)
			local r3, l3 = refsTo(p3)
			expect(r1).toEqual({ i[1], i[2], i[3], i[5] })
			expect(r2).toEqual({ i[2], i[4] })
			expect(r3).toEqual({ i[2], i[4], i[5] })
			expect(l1).toEqual({ "Sig a I1", "Sig b I2", "Pos 7 <7,0,0>", "Sig c I3", "Sig e I5", "Sig f 6" })
			expect(l2).toEqual({ "Sig b I2", "Pos 7 <7,0,0>", "Sig d I4", "Sig f 6" })
			expect(l3).toEqual({ "Sig b I2", "Pos 7 <7,0,0>", "Sig d I4", "Sig e I5", "Sig f 6" })
		end)

		it("a hidden Instance arrives nil without shifting later args or refs (client decoder)", function()
			local p = newPlayer(false)
			local other = newPlayer()
			connectClient(p)
			local log: { string } = {}
			for _, name in { "Sig", "Opt", "Need", "Pos" } do
				route(name).signal:Connect(function(...: any)
					table.insert(log, name .. " " .. joinArgs({ ... }, select("#", ...)))
				end)
			end
			local vis, hid = folder("Vis"), folder("Hid")
			local S = rt.signals.S
			S.Sig:Fire(p, "a", hid, "a2") -- per player, untyped
			S.Sig:FireAll("b", hid, "b2") -- broadcast, untyped
			S.Opt:Fire(p, "c", hid, "c2") -- typed optional: nil in place
			S.Need:FireAll("d", hid, "d2") -- typed required: dropped and counted
			S.Pos:Fire(p, 5, v(5)) -- no refs: the cursor must not move
			S.Sig:Fire(p, "e", vis, "e2")
			S.Need:Fire(p, "f", vis, "f2")
			S.Opt:FireAll("g", vis, "g2")
			flush()
			local list = takeFires(p, "Reliable")
			expect(#list).toBeGreaterThan(0)
			local all: { any } = {}
			for _, f in list do
				local refs: { any } = f.refs or {}
				local seen: { any } = table.create(#refs) -- the engine sends nil for an Instance this client cannot see
				for k, ref in refs do
					table.insert(all, ref)
					if ref ~= hid then
						seen[k] = ref
					end
				end
				ClientNet._test.receive(f.frame, if f.refs then seen else nil)
			end
			expect(all).toEqual({ hid, hid, hid, hid, vis, vis, vis })
			expect(log).toEqual({
				"Sig a nil a2",
				"Sig b nil b2",
				"Opt c nil c2",
				"Pos 5 <5,0,0>",
				"Sig e Vis e2",
				"Need f Vis f2",
				"Opt g Vis g2",
			})
			expect(ClientNet.getStats().SignalsDropped).toBe(1)
			local theirs = refsTo(other)
			expect(theirs).toEqual({ hid, hid, vis }) -- only its broadcasts
		end)
	end)

	describe("unreliable size limit", function()
		it("server: exactly 900 B goes out alone; 901 B raises, queues and counts nothing; order kept", function()
			local p1, p2 = newPlayer(), newPlayer()
			local usig = rt.signals.S.USig
			local r = R("USig")
			local function sizeOf(len: number): number
				local w = Codec.newWriter(64, false)
				w.unreliable = true
				Codec.writeHead(w, r.id)
				assert(r.args.encode(w, 1, string.rep("u", len)) == 0, "encode failed")
				return w.n
			end
			local exact = SEAL - (sizeOf(800) - 800)
			expect(sizeOf(exact)).toBe(SEAL)
			local before = Transport.getStats()
			usig:Fire(p1, string.rep("u", exact))
			expect(function()
				usig:Fire(p1, string.rep("u", exact + 1))
			end).toThrow(string.format("the message is %d bytes", SEAL + 1))
			expect(function()
				usig:FireAll(string.rep("u", exact + 1))
			end).toThrow(string.format("limited to %d bytes", SEAL))
			expect(function()
				usig:FireFor({ p1, p2 }, string.rep("u", exact + 1))
			end).toThrow(string.format("limited to %d bytes", SEAL))
			local after = Transport.getStats()
			expect(after.MessagesOut - before.MessagesOut).toBe(1)
			expect(after.SignalsDropped).toBe(before.SignalsDropped)
			flush()
			local u = takeFires(p1, "Unreliable")
			expect(#u).toBe(1)
			expect(buffer.len(u[1].frame)).toBe(SEAL)
			expect(#takeFires(p2)).toBe(0)

			-- Per-player and broadcast unreliable messages: chunks of at most 900 B, each player's order kept.
			for k = 1, 6 do
				usig:Fire(p1, string.format("p%d.", k) .. string.rep("x", 296))
				usig:FireAll(string.format("a%d.", k) .. string.rep("y", 296))
			end
			flush()
			local function prefixes(p: any): { string }
				local out: { string } = {}
				for _, f in takeFires(p, "Unreliable") do
					expect(buffer.len(f.frame) <= SEAL).toBe(true)
					for _, line in decode(f.frame) do
						table.insert(out, string.match(line, "^USig (%w+)%.") or line)
					end
				end
				return out
			end
			expect(prefixes(p1)).toEqual({ "p1", "a1", "p2", "a2", "p3", "a3", "p4", "a4", "p5", "a5", "p6", "a6" })
			expect(prefixes(p2)).toEqual({ "a1", "a2", "a3", "a4", "a5", "a6" })
		end)

		it("client: a 900 B unreliable ClientEvent frame goes out; 1 B more raises and queues nothing", function()
			local p = newPlayer(false)
			connectClient(p)
			local ev = route("UEv")
			local function frameSize(len: number): number
				local w = Codec.newWriter(64, true)
				w.unreliable = true
				Codec.writeHead(w, ev.id)
				assert(ev.args.encode(w, 1, string.rep("c", len)) == 0, "encode failed")
				return C.C2S_HEADER + Codec.varintSize(w.n) + w.n
			end
			local exact = SEAL - (frameSize(800) - 800)
			expect(frameSize(exact)).toBe(SEAL)
			ClientNet.fire(ev, 1, string.rep("c", exact))
			expect(function()
				ClientNet.fire(ev, 1, string.rep("c", exact + 1))
			end).toThrow("over the unreliable limit")
			ClientNet._test.flushNow()
			expect(#c2s).toBe(1)
			expect(c2s[1].unreliable).toBe(true)
			expect(buffer.len(c2s[1].frame)).toBe(SEAL)
			expect(ClientNet.getStats().EventsLost).toBe(0)
			toServer(p)
			expect(#events).toBe(1)
			expect(#events[1]).toBe(exact)
		end)
	end)

	describe("server: the messages of one C->S frame", function()
		it("run in frame order; a yielding listener holds nothing back and nothing runs twice", function()
			local p = newPlayer()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "start " .. tostring(tag))
				if tag == "e1" then
					task.wait()
					table.insert(trail, "resumed e1")
				end
			end)
			local frame = frameOf({
				eventMsg("Ev", "e1"),
				eventMsg("Ev", "e2"),
				callMsg("Note", 1, "c3"),
				eventMsg("Ev", "e4"),
			})
			Transport._test.frame(false, p, frame, nil)
			expect(trail).toEqual({ "start e1", "start e2", "call c3", "start e4" })
			flush()
			expect(streamTo(p)).toEqual({ "OK 1 c3" })
			waitFor(function(): boolean
				return #trail >= 5
			end, 2)
			frames(3)
			expect(trail).toEqual({ "start e1", "start e2", "call c3", "start e4", "resumed e1" })
			expect(#fires).toBe(0)
		end)

		it("a bad message still ends the rest of its frame; the messages before it ran", function()
			local p = newPlayer()
			rt.events.S.Ev:Connect(function(_: any, tag: any)
				table.insert(trail, "start " .. tostring(tag))
			end)
			local before = st(p).viol.winViol[V_ROUTE] or 0
			local frame = frameOf({
				eventMsg("Ev", "e1"),
				callMsg("Note", 1, "c2"),
				signalHead("Sig"),
				eventMsg("Ev", "e3"),
			})
			Transport._test.frame(false, p, frame, nil)
			frames(3)
			expect(trail).toEqual({ "start e1", "call c2" })
			expect(st(p).viol.winViol[V_ROUTE]).toBe(before + 1)
			flush()
			expect(streamTo(p)).toEqual({ "OK 1 c2" })
		end)
	end)

	describe("client delivery order (ClientNet fed the server's frames)", function()
		it("signals (variable and fixed size), OK, ERR and NOTICE take effect in frame order", function()
			local p = newPlayer(false)
			connectClient(p)
			local log: { string } = {}
			local function note(text: string)
				table.insert(log, text .. " d" .. ClientNet.getStats().FramesDropped)
			end
			route("Sig").signal:Connect(function(tag: any)
				note("Sig " .. tostring(tag))
			end)
			route("Pos").signal:Connect(function(n: any)
				note("Pos " .. tostring(n))
			end)
			for _, key in { "a", "b", "c" } do
				ClientNet.call(route("Gate"), false, 1, key):andThen(function(value: any)
					note("ok " .. tostring(value))
				end, function(message: any)
					note("err " .. tostring(message))
				end)
			end
			toServer(p)
			expect(gates.c).never.toBeNil()
			local S = rt.signals.S
			S.Sig:Fire(p, "s1")
			open("a", "ok", "A")
			S.Pos:FireAll(2, v(2))
			S.Sig:FireAll("s2")
			open("b", "err", "B")
			Outbox.notice(st(p), FRAME_DROPPED, 40000, 2) -- seqs no call of this client was sent in
			S.Sig:Fire(p, "s3")
			open("c", "fire", "C")
			S.Pos:Fire(p, 4, v(4))
			flush()
			toClient(p)
			expect(log).toEqual({
				"Sig s1 d0",
				"ok A d0",
				"Pos 2 d0",
				"Sig s2 d0",
				"err B d0",
				"Sig s3 d2",
				"Sig C! d2",
				"ok C d2",
				"Pos 4 d2",
			})
		end)

		it("a yielding or failing listener holds nothing back; a call cancelled mid-frame is not resolved", function()
			local p = newPlayer(false)
			connectClient(p)
			local order: { string } = {}
			local pending: any = nil
			route("Sig").signal:Connect(function(tag: any)
				table.insert(order, "start " .. tostring(tag))
				if tag == "y" then
					task.wait()
					table.insert(order, "resumed y")
				elseif tag == "boom" then
					error("Ordering.spec: a listener failed on purpose", 0)
				elseif tag == "cancel" then
					pending:cancel()
				end
			end)
			local resolved = false
			pending = ClientNet.call(route("Gate"), false, 1, "k")
			pending:andThen(function()
				resolved = true
			end, noop)
			toServer(p)
			local sig = rt.signals.S.Sig
			sig:Fire(p, "y")
			sig:Fire(p, "boom")
			sig:Fire(p, "cancel")
			open("k", "ok", "K")
			sig:Fire(p, "z")
			flush()
			toClient(p)
			expect(order).toEqual({ "start y", "start boom", "start cancel", "start z" })
			expect(resolved).toBe(false)
			expect(pending:getStatus()).toBe("Cancelled")
			expect(ClientNet.getStats().LateReplies).toBe(1)
			waitFor(function(): boolean
				return #order >= 5
			end, 2)
			frames(3) -- a stale runner that resumes must not deliver anything a second time
			expect(order).toEqual({ "start y", "start boom", "start cancel", "start z", "resumed y" })
			expect(resolved).toBe(false)
			expect(ClientNet.getStats().LateReplies).toBe(1)
		end)
	end)
end
