--!strict
--[[
	ClientNet + Proxy (client-net) on the wire, without remotes: the manifest is installed offline,
	outgoing frames are captured instead of FireServer, server frames are crafted with the Codec and
	fed as OnClientEvent would, and the clock is fake. Runs on the server (Run mode or Play).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Codec = require(Runtime:WaitForChild("Codec")) :: any
local Schema = require(Runtime:WaitForChild("Schema")) :: any
local Manifest = require(Runtime:WaitForChild("Manifest")) :: any
local ClientNet = require(Runtime:WaitForChild("ClientNet")) :: any
local Calls = require(Runtime:WaitForChild("Calls")) :: any
local Proxy = require(Runtime:WaitForChild("Proxy")) :: any

local T = Schema.T
local F = C.MemberFlag
local K = C.Kind
local P = "(LORENঌ) "

-- Route ids of the fixture manifest
local AIM, SEQ, STREAM, BLOB, PING, HIT, PARTSIG, ECHO, FAST, NEEDSPART = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10

local function member(name: string, kind: number, id: number, flags: number, o: { [string]: any }): any
	local m: { [string]: any } = {
		name = name,
		kind = kind,
		route = id,
		flags = flags,
		timeout = o.timeout or 0,
		rate = o.rate or 0,
		burst = o.burst or 0,
		backlog = o.backlog or 0,
		args = o.args,
		returns = o.returns,
	}
	if o.args then
		m.flags = bit32.bor(m.flags, F.HasArgs)
	end
	if o.returns then
		m.flags = bit32.bor(m.flags, F.HasReturns)
	end
	return m
end

-- A fresh model (Proxy caches per model identity). Members sorted by name, as the server sends them.
local function makeModel(): any
	local U, O, CO = F.Unreliable, F.Ordered, F.Coalesce
	return {
		proto = C.PROTO,
		version = "2.0.0",
		limits = {
			frameRate = 120,
			frameBurst = 140,
			byteRate = 131072,
			byteBurst = 262144,
			msgRate = 600,
			msgBurst = 600,
			mirror = 0.9,
			sealC2S = 16384,
			maxMessageC2S = 65536,
			unreliableMax = 900,
			maxPending = 4096,
			maxNodes = 2048,
			maxArgs = 20,
			maxRefs = 255,
			maxDepth = 16,
			flushHz = 61,
			backlogWindow = 10,
		},
		services = {
			{
				name = "Svc",
				members = {
					member("Aim", K.Event, AIM, U + CO, { rate = 120, burst = 60, args = { T.Vector3 } }),
					member("Blob", K.Event, BLOB, U, { rate = 1000, burst = 1000, args = { T.string(2000) } }),
					member("Echo", K.Method, ECHO, 0, { timeout = 10, rate = 50, burst = 100 }),
					member("Fast", K.Method, FAST, 0, { timeout = 120, rate = 100000, burst = 100000 }),
					member("Hit", K.Signal, HIT, 0, { backlog = 64 }),
					member("NeedsPart", K.Method, NEEDSPART, 0, {
						timeout = 10,
						rate = 1000,
						burst = 1000,
						returns = { T.Instance("BasePart") },
					}),
					member("PartSig", K.Signal, PARTSIG, 0, { args = { T.Instance() } }),
					member("Ping", K.Event, PING, 0, { rate = 75, burst = 150 }),
					member("Seq", K.Event, SEQ, U + O, { rate = 1000, burst = 1000, args = { T.u32 } }),
					member("Stream", K.Signal, STREAM, U + O, { args = { T.u32 } }),
				},
			},
		},
	}
end

-- A copy of the server's admission buckets (§3.14 admitFrame, then chargeBytes for the sidecar).
local function newServerSim(t0: number): any
	local function bucket(rate: number, burst: number): any
		return { tok = burst, rate = rate, burst = burst, at = t0 }
	end
	local function refill(b: any, t: number)
		b.tok = math.min(b.burst, b.tok + (t - b.at) * b.rate)
		b.at = t
	end
	local sim: any = {
		rel = bucket(120, 140),
		unr = bucket(120, 140),
		bytes = bucket(131072, 262144),
		msgs = bucket(600, 600),
	}
	function sim.admit(
		unreliable: boolean,
		len: number,
		nrefs: number,
		nodes: number,
		side: number,
		nmsg: number,
		t: number
	): boolean
		local f = if unreliable then sim.unr else sim.rel
		refill(f, t)
		refill(sim.bytes, t)
		refill(sim.msgs, t)
		local cost = math.max(len, 64) + 16 * nrefs
		if f.tok < 1 or sim.bytes.tok < cost or sim.msgs.tok < nmsg then
			return false
		end
		f.tok -= 1
		sim.bytes.tok -= cost
		sim.msgs.tok -= nmsg
		local sidecar = 8 * nodes + side
		if sim.bytes.tok < sidecar then
			return false
		end
		sim.bytes.tok -= sidecar
		return true
	end
	return sim
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach = t.beforeAll, t.afterAll, t.beforeEach

	local now = 0
	local function clock(): number
		return now
	end
	local function noop() end

	local fired: { any } = {}
	local function capture(unreliable: boolean, frame: buffer, refs: { any }?, nodes: number, side: number)
		table.insert(
			fired,
			{ unreliable = unreliable, frame = frame, refs = refs, nodes = nodes, side = side, at = now }
		)
	end

	local model: any = nil

	local function route(id: number): any
		return ClientNet.routes()[id]
	end
	local function call(id: number, ...: any): any
		return ClientNet.call(route(id), false, select("#", ...), ...)
	end
	local function fire(id: number, ...: any)
		ClientNet.fire(route(id), select("#", ...), ...)
	end
	local function flush()
		ClientNet._test.flushNow()
	end
	local function stats(): any
		return ClientNet.getStats()
	end

	-- Parses a captured C->S frame: header and message boundaries.
	local function parse(frame: buffer): any
		local len = buffer.len(frame)
		local f: any = {
			seq = buffer.readu16(frame, 0),
			nmsg = buffer.readu16(frame, 2),
			nrefs = buffer.readu8(frame, 4),
			len = len,
			msgs = {},
		}
		local p = 5
		for _ = 1, f.nmsg do
			local mlen
			mlen, p = Codec.readVarint(frame, p, len)
			local h, q = Codec.readHead(frame, p, p + mlen)
			table.insert(f.msgs, { route = h, body = q, stop = p + mlen })
			p += mlen
		end
		f.stop = p
		return f
	end

	-- Call ids of the CALL messages in a frame, in order.
	local function callIds(frame: buffer): { number }
		local ids: { number } = {}
		for _, m in parse(frame).msgs do
			table.insert(ids, buffer.readu16(frame, m.body))
		end
		return ids
	end

	-- Builds an S->C frame; returns (frame, refs?).
	local function s2c(build: (any) -> ()): (buffer, { any }?)
		local w = Codec.newWriter(64, false)
		build(w)
		local b = buffer.create(w.n)
		buffer.copy(b, 0, w.buf, 0, w.n)
		if w.nrefs > 0 then
			return b, table.move(w.refs, 1, w.nrefs, 1, {})
		end
		return b, nil
	end
	local function okMsg(w: any, id: number, ...: any)
		Codec.writeU8(w, C.Op.OK)
		Codec.writeU16(w, id)
		Codec.writeArgs(w, 255, select("#", ...), ...)
	end
	local function errMsg(
		w: any,
		id: number,
		code: number,
		msg: string?,
		hasData: boolean,
		data: any,
		incident: number?
	)
		local flags = 0
		if msg then
			flags += C.ErrFlag.Msg
		end
		if hasData then
			flags += C.ErrFlag.Data
		end
		if incident then
			flags += C.ErrFlag.Incident
		end
		Codec.writeU8(w, C.Op.ERR)
		Codec.writeU16(w, id)
		Codec.writeU8(w, code)
		Codec.writeU8(w, flags)
		if msg then
			Codec.writeVarint(w, #msg)
			Codec.writeString(w, msg)
		end
		if hasData then
			Codec.writeValue(w, data, 0)
		end
		if incident then
			Codec.writeU32(w, incident)
		end
	end
	local function noticeMsg(w: any, kind: number, first: number, count: number)
		Codec.writeU8(w, C.Op.NOTICE)
		Codec.writeU8(w, kind)
		Codec.writeU16(w, first)
		Codec.writeU16(w, count)
	end
	local function manifestMsg(w: any, m: any)
		local bytes = Manifest.encode(m)
		Codec.writeU8(w, C.Op.MANIFEST)
		Codec.writeU32(w, buffer.len(bytes))
		Codec.writeBytes(w, bytes, 0, buffer.len(bytes))
	end
	-- Untyped signal (Hit).
	local function signalMsg(w: any, id: number, ...: any)
		Codec.writeHead(w, id)
		Codec.writeArgs(w, 255, select("#", ...), ...)
	end
	-- Typed signal through the route's compiled codec; seq for Ordered routes.
	local function typedSignal(w: any, id: number, seq: number?, ...: any)
		Codec.writeHead(w, id)
		if seq then
			Codec.writeU16(w, seq)
		end
		assert(route(id).args.encode(w, select("#", ...), ...) == 0, "fixture encode failed")
	end
	local function receive(frame: buffer, refs: { any }?, unreliable: boolean?)
		ClientNet._test.receive(frame, refs, unreliable)
	end
	local function counter(id: number): () -> number
		local n = 0
		route(id).signal:Connect(function()
			n += 1
		end)
		return function()
			return n
		end
	end

	local function fresh()
		ClientNet._reset()
		Calls._reset()
		Proxy._reset()
		now = 1000
		ClientNet._test.setClock(clock)
		table.clear(fired)
		ClientNet._test.setFire(capture)
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		ClientNet._reset()
		Calls._reset()
		Proxy._reset()
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		fresh()
		model = makeModel()
		ClientNet._test.loadManifest(model)
	end)

	describe("outgoing frames", function()
		it("puts a call in a frame: seq, nmsg, nrefs, then len, head, callId, payload", function()
			call(ECHO, 7, 2):catch(noop)
			flush()
			expect(#fired).toBe(1)
			expect(fired[1].unreliable).toBe(false)
			expect(fired[1].refs).toBeNil()
			-- 00 00 | 01 00 | 00 || 06 | 08 | 01 00 | 02 87 82
			expect(buffer.tostring(fired[1].frame)).toBe(string.char(0, 0, 1, 0, 0, 6, ECHO, 1, 0, 2, 0x87, 0x82))
			expect(stats().MessagesOut).toBe(1)
		end)

		it("seals reliable frames before 16 KiB of weight", function()
			local s = string.rep("x", 1000)
			for _ = 1, 40 do
				call(FAST, s):catch(noop)
			end
			flush()
			local total = 0
			for _, f in fired do
				local pf = parse(f.frame)
				total += pf.nmsg
				expect(pf.stop).toBe(pf.len)
				expect(pf.len + 8 * f.nodes + f.side).toBeLessThanOrEqual(16384)
			end
			expect(total).toBe(40)
			expect(#fired).toBe(3)
		end)

		it("counts sidecar nodes and string bytes in the seal weight", function()
			local function heavy(): any
				local tbl: { [string]: any } = { f = print } -- a function value sends the table to the sidecar
				for i = 1, 300 do
					tbl["k" .. i] = i
				end
				return tbl
			end
			for _ = 1, 12 do
				call(FAST, heavy()):catch(noop)
			end
			flush()
			local total = 0
			for _, f in fired do
				local pf = parse(f.frame)
				total += pf.nmsg
				expect(f.nodes).toBeGreaterThan(0)
				expect(f.side).toBeGreaterThan(0)
				expect(pf.nrefs).toBe(pf.nmsg)
				if pf.nmsg > 1 then
					expect(pf.len + 8 * f.nodes + f.side).toBeLessThanOrEqual(16384)
				end
			end
			expect(total).toBe(12)
			expect(#fired).toBeGreaterThan(1)
		end)

		it("keeps sidecar nodes per frame within 2048; one message over 2048 is BadArgument", function()
			local function sidecarTable(n: number): any
				local tbl: { [any]: any } = { f = print } -- a function value sends the table to the sidecar
				for i = 1, n do
					tbl[i] = i
				end
				return tbl
			end
			for _ = 1, 6 do
				call(FAST, sidecarTable(900)):catch(noop)
			end
			flush()
			local total = 0
			for _, f in fired do
				total += parse(f.frame).nmsg
				expect(f.nodes).toBeLessThanOrEqual(2048)
				expect(f.nodes).toBeGreaterThanOrEqual(900)
			end
			expect(total).toBe(6)
			expect(#fired).toBeGreaterThanOrEqual(3)
			-- The six sent calls await replies (no server; FAST timeout 120 s, the fake clock is frozen):
			-- a call stays pending until OK/ERR or its deadline (§3.17 Calls).
			expect(stats().PendingCalls).toBe(6)
			-- 2100 nodes: weight about 17 KB (not PayloadTooLarge), but over the node cap
			local ok, message, info = call(FAST, sidecarTable(2100)):await()
			expect(ok).toBe(false)
			expect(string.find(message, P .. "BadArgument", 1, true)).toBe(1)
			expect(string.find(message, "TooManyNodes", 1, true)).never.toBeNil()
			expect(info.Code).toBe("BadArgument")
			-- the rejected call allocated no call id
			expect(stats().PendingCalls).toBe(6)
			local before = #fired
			flush()
			expect(#fired).toBe(before)
		end)

		it("seals at 255 refs and re-encodes a moved message with ref index 0", function()
			local part = Instance.new("Part")
			for _ = 1, 256 do
				call(FAST, part):catch(noop)
			end
			flush()
			expect(#fired).toBe(2)
			local f1, f2 = parse(fired[1].frame), parse(fired[2].frame)
			expect(f1.nrefs).toBe(255)
			expect(f1.nmsg).toBe(255)
			expect(#(fired[1].refs :: any)).toBe(255)
			expect(f2.nrefs).toBe(1)
			expect(f2.nmsg).toBe(1)
			-- message body: callId u16, argc u8, REF tag, varint index (frame-absolute)
			local b1, b2 = fired[1].frame, fired[2].frame
			local last = f1.msgs[255]
			expect(buffer.readu8(b1, last.body + 3)).toBe(C.Tag.REF)
			expect((Codec.readVarint(b1, last.body + 4, last.stop))).toBe(254)
			local moved = f2.msgs[1]
			expect(buffer.readu8(b2, moved.body + 3)).toBe(C.Tag.REF)
			expect((Codec.readVarint(b2, moved.body + 4, moved.stop))).toBe(0)
			expect((fired[2].refs :: any)[1]).toBe(part)
		end)

		it("seals at msgCap messages and paces the rest with the message mirror", function()
			expect(ClientNet._test.state().msgCap).toBe(540) -- floor(600 * 0.9)
			for _ = 1, 600 do
				call(FAST):catch(noop)
			end
			flush()
			expect(#fired).toBe(1)
			expect(parse(fired[1].frame).nmsg).toBe(540)
			flush() -- no message tokens yet: the second frame waits
			expect(#fired).toBe(1)
			now += 60 / 540 + 0.001
			flush()
			expect(#fired).toBe(2)
			expect(parse(fired[2].frame).nmsg).toBe(60)
		end)

		it("rejects a message over 64 KiB with PayloadTooLarge before anything is queued", function()
			local ok, message, info = call(ECHO, string.rep("x", 70000)):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "PayloadTooLarge")
			expect(info.Code).toBe("PayloadTooLarge")
			flush()
			expect(#fired).toBe(0)
			expect(stats().PendingCalls).toBe(0)
		end)

		it("rejects more than 20 arguments with BadArgument at once", function()
			local args = table.create(21, 1)
			local ok, message, info = call(ECHO, table.unpack(args)):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "BadArgument: arg 21 (TooManyArgs)")
			expect(info.Arg).toBe(21)
			-- Try form: the same rejection as values, without yielding
			local r = table.pack(ClientNet.call(route(ECHO), true, 21, table.unpack(args)))
			expect(r[1]).toBe(false)
			expect(r[2]).toBe(P .. "BadArgument: arg 21 (TooManyArgs)")
		end)

		it("keeps unreliable frames within 900 bytes and raises for a single larger message", function()
			for _ = 1, 10 do
				fire(BLOB, string.rep("y", 200))
			end
			flush()
			local n = 0
			for _, f in fired do
				expect(f.unreliable).toBe(true)
				expect(f.refs).toBeNil()
				expect(buffer.len(f.frame)).toBeLessThanOrEqual(900)
				n += parse(f.frame).nmsg
			end
			expect(n).toBe(10)
			expect(function()
				fire(BLOB, string.rep("z", 1000))
			end).toThrow("over the unreliable limit")
			local before = #fired
			flush()
			expect(#fired).toBe(before)
		end)

		it("coalesces: only the latest Fire per flush is sent, for one mirror token", function()
			fire(AIM, Vector3.new(1, 0, 0))
			fire(AIM, Vector3.new(2, 0, 0))
			fire(AIM, Vector3.new(3, 0, 0))
			flush()
			expect(#fired).toBe(1)
			local f = parse(fired[1].frame)
			expect(fired[1].unreliable).toBe(true)
			expect(f.nmsg).toBe(1)
			expect(f.msgs[1].route).toBe(AIM)
			expect(buffer.readf32(fired[1].frame, f.msgs[1].body)).toBe(3)
			expect(ClientNet._test.routeBucket(AIM).tokens).toBeCloseTo(60 * 0.9 - 1, 3)
			flush()
			expect(#fired).toBe(1)
		end)

		it("writes Ordered event seqs 1, 2, 3", function()
			fire(SEQ, 10)
			fire(SEQ, 11)
			fire(SEQ, 12)
			flush()
			local f = parse(fired[1].frame)
			expect(f.nmsg).toBe(3)
			for i, m in f.msgs do
				expect(buffer.readu16(fired[1].frame, m.body)).toBe(i)
				expect(buffer.readu32(fired[1].frame, m.body + 2)).toBe(9 + i)
			end
		end)

		it("flushes at most 61 times per second at 240 Hz, once per step at 30 Hz; Flush shares the credit", function()
			local s0 = ClientNet._test.state().flushes
			for _ = 1, 240 do
				now += 1 / 240
				ClientNet._test.heartbeat(1 / 240)
			end
			local n240 = ClientNet._test.state().flushes - s0
			expect(n240).toBeLessThanOrEqual(61)
			expect(n240).toBeGreaterThanOrEqual(60)
			local s1 = ClientNet._test.state().flushes
			for _ = 1, 30 do
				now += 1 / 30
				ClientNet._test.heartbeat(1 / 30)
			end
			expect(ClientNet._test.state().flushes - s1).toBe(30)
			-- the carry is clamped to one interval: Loren.Flush gets exactly one more flush
			local s2 = ClientNet._test.state().flushes
			ClientNet.flush()
			ClientNet.flush()
			expect(ClientNet._test.state().flushes - s2).toBe(1)
		end)

		it("never fires a frame the server's buckets would refuse, even for a paced backlog", function()
			local sim = newServerSim(now)
			local refused, sentMsgs = 0, 0
			ClientNet._test.setFire(
				function(unreliable: boolean, frame: buffer, _refs: any, nodes: number, side: number)
					local nmsg = buffer.readu16(frame, 2)
					if
						not sim.admit(unreliable, buffer.len(frame), buffer.readu8(frame, 4), nodes, side, nmsg, now)
					then
						refused += 1
					end
					sentMsgs += nmsg
				end
			)
			-- ~1.7 MB queued at once (under the 2 x msgCap unsent bound): about 12 s of byte pacing
			local big = string.rep("p", 2000)
			for i = 1, 800 do
				local mixed: { [any]: any } = {} -- mixed keys: not an ARRAY or MAP, so it goes to the sidecar
				mixed[1] = i
				mixed[2] = "t"
				mixed.k = i
				call(FAST, big, mixed):catch(noop)
				if i % 5 == 0 then
					fire(BLOB, string.rep("u", 400))
				end
			end
			expect(ClientNet._test.state().unsent).toBe(960)
			for _ = 1, 240 * 25 do
				now += 1 / 240
				ClientNet._test.heartbeat(1 / 240)
			end
			expect(refused).toBe(0)
			expect(sentMsgs).toBe(960)
			expect(ClientNet._test.state().unsent).toBe(0)
			expect(stats().EventsLost).toBe(0)
			expect(stats().CallsRateLimited).toBe(0)
		end)

		it("refuses calls and drops events once 2 x msgCap messages are unsent", function()
			for _ = 1, 1080 do
				call(FAST):catch(noop)
			end
			expect(ClientNet._test.state().unsent).toBe(1080)
			local ok, message = call(FAST):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "RateLimited")
			fire(PING, 1)
			expect(stats().EventsLost).toBe(1)
		end)

		it("rejects TooManyInFlight past the manifest's pending cap, before anything is queued", function()
			fresh()
			local m = makeModel()
			m.limits.maxPending = 3
			ClientNet._test.loadManifest(m)
			for _ = 1, 3 do
				call(ECHO):catch(noop)
			end
			local ok, message, info = call(ECHO):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "TooManyInFlight")
			expect(info.Code).toBe("TooManyInFlight")
			expect(info.Service).toBe("Svc")
			expect(info.Member).toBe("Echo")
			-- Try form: the same rejection as values, without yielding
			local r = table.pack(ClientNet.call(route(ECHO), true, 0))
			expect(r[1]).toBe(false)
			expect(r[2]).toBe(P .. "TooManyInFlight")
			expect(ClientNet._test.state().unsent).toBe(3)
			expect(stats().PendingCalls).toBe(3)
			-- a settled call frees its slot
			flush()
			receive(s2c(function(w)
				okMsg(w, callIds(fired[1].frame)[1])
			end))
			expect(stats().PendingCalls).toBe(2)
			call(ECHO):catch(noop)
			expect(stats().PendingCalls).toBe(3)
		end)

		it("rejects the calls of a frame FireServer refused with BadArgument and counts its events", function()
			ClientNet._test.setFire(function()
				error("cannot serialize")
			end)
			local p = call(ECHO, 1)
			fire(PING, 1)
			flush()
			local ok, message, info = p:await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "BadArgument (Unserializable)")
			expect(info.Code).toBe("BadArgument")
			expect(stats().EventsLost).toBe(1)
			expect(stats().PendingCalls).toBe(0)
		end)

		it("refuses calls past the route mirror at once and drops events past it", function()
			for _ = 1, 90 do -- MethodBurst 100 * 0.9
				call(ECHO):catch(noop)
			end
			local ok, message, info = call(ECHO):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "RateLimited")
			expect(info.Code).toBe("RateLimited")
			expect(stats().CallsRateLimited).toBe(1)
			for _ = 1, 135 do -- EventBurst 150 * 0.9
				fire(PING)
			end
			expect(stats().EventsLost).toBe(0)
			fire(PING)
			expect(stats().EventsLost).toBe(1)
		end)

		it("rejects NotReady before a manifest and BootFailed after fail()", function()
			local r = route(ECHO)
			local pending = call(ECHO)
			ClientNet.fail()
			local _, m1 = pending:await()
			expect(m1).toBe(P .. "BootFailed")
			local _, m2 = ClientNet.call(r, false, 0):await()
			expect(m2).toBe(P .. "BootFailed")
			flush()
			expect(#fired).toBe(0)
			fresh()
			local _, m3 = ClientNet.call(r, false, 0):await()
			expect(m3).toBe(P .. "NotReady")
		end)
	end)

	describe("incoming frames", function()
		it("delivers signals with every value, nil holes included", function()
			local got: { any } = {}
			route(HIT).signal:Connect(function(...)
				table.insert(got, table.pack(...))
			end)
			receive(s2c(function(w)
				signalMsg(w, HIT, 7, nil, "x")
			end))
			expect(#got).toBe(1)
			expect(got[1].n).toBe(3)
			expect(got[1][1]).toBe(7)
			expect(got[1][2]).toBeNil()
			expect(got[1][3]).toBe("x")
			expect(stats().MessagesIn).toBe(1)
		end)

		it("buffers signals until the first Connect and replays them deferred", function()
			receive(s2c(function(w)
				signalMsg(w, HIT, 1)
				signalMsg(w, HIT, 2)
			end))
			local got: { any } = {}
			route(HIT).signal:Connect(function(v)
				table.insert(got, v)
			end)
			expect(#got).toBe(0)
			task.wait()
			expect(got).toEqual({ 1, 2 })
		end)

		it("drops stale Ordered signals but still decodes them; wraps; resets after 1 s of silence", function()
			local got: { any } = {}
			route(STREAM).signal:Connect(function(v)
				table.insert(got, v)
			end)
			local function streamFrame(...: number): buffer
				local seqs = { ... }
				return (
					s2c(function(w)
						for _, s in seqs do
							typedSignal(w, STREAM, s, s + 1000)
						end
					end)
				)
			end
			receive(streamFrame(5, 4, 5, 6), nil, true)
			expect(got).toEqual({ 1005, 1006 })
			now += 2
			receive(streamFrame(65534, 65535, 0, 65535), nil, true)
			expect(got).toEqual({ 1005, 1006, 66534, 66535, 1000 })
			now += 1.5
			receive(streamFrame(65535), nil, true)
			expect(got[6]).toBe(66535)
		end)

		it("drops a Signal whose Instance arrived nil (counted) and keeps decoding", function()
			local got: { any } = {}
			route(PARTSIG).signal:Connect(function(v)
				table.insert(got, v)
			end)
			local hits = counter(HIT)
			local part = Instance.new("Part")
			local frame = s2c(function(w)
				typedSignal(w, PARTSIG, nil, part)
				signalMsg(w, HIT, 1)
			end)
			receive(frame, {}) -- the Instance did not replicate: its ref slot is nil
			expect(#got).toBe(0)
			expect(stats().SignalsDropped).toBe(1)
			expect(hits()).toBe(1)
			receive(frame, { part })
			expect(got[1]).toBe(part)
		end)

		it("resolves OK replies with every value", function()
			local p = call(ECHO, 1)
			flush()
			local id = callIds(fired[1].frame)[1]
			receive(s2c(function(w)
				okMsg(w, id, 1, nil, 3)
			end))
			local r = table.pack(p:await())
			expect(r.n).toBe(4)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(1)
			expect(r[3]).toBeNil()
			expect(r[4]).toBe(3)
		end)

		it("maps every ERR code to (message, info)", function()
			local cases: { any } = {
				{ code = 1, msg = "nope", hasData = true, data = 5, want = "nope", name = "Rejected" },
				{ code = 1, msg = "", want = "", name = "Rejected" },
				{ code = 2, want = "Denied", name = "Denied" },
				{ code = 2, msg = "no access", want = "no access", name = "Denied" },
				{
					code = 3,
					msg = "Range",
					hasData = true,
					data = 2,
					want = P .. "BadRequest: arg 2 (Range)",
					name = "BadRequest",
					arg = 2,
				},
				{ code = 4, want = P .. "RateLimited", name = "RateLimited" },
				{ code = 5, want = P .. "Busy", name = "Busy" },
				{
					code = 6,
					incident = 0xa1b2c3d4,
					want = P .. "InternalError [a1b2c3d4]",
					name = "InternalError",
					hex = "a1b2c3d4",
				},
				{
					code = 6,
					msg = "boom",
					incident = 1,
					want = P .. "InternalError [00000001]: boom",
					name = "InternalError",
				},
				{ code = 7, incident = 0xff, want = P .. "BadResult [000000ff]", name = "BadResult" },
				{ code = 8, want = P .. "ShuttingDown", name = "ShuttingDown" },
				{ code = 42, msg = "x", incident = 3, want = P .. "InternalError", name = "InternalError" },
			}
			local promises: { any } = {}
			for i = 1, #cases do
				promises[i] = call(ECHO)
			end
			flush()
			local ids = callIds(fired[1].frame)
			receive(s2c(function(w)
				for i, c in cases do
					errMsg(w, ids[i], c.code, c.msg, c.hasData == true, c.data, c.incident)
				end
			end))
			for i, c in cases do
				local ok, message, info = promises[i]:await()
				expect(ok).toBe(false)
				expect(message).toBe(c.want)
				expect(info.Code).toBe(c.name)
				expect(info.Message).toBe(c.want)
				expect(info.Service).toBe("Svc")
				expect(info.Member).toBe("Echo")
				if c.arg then
					expect(info.Arg).toBe(c.arg)
					expect(info.Data).toBeNil()
				end
				if c.code == 1 and c.hasData then
					expect(info.Data).toBe(5)
				end
				if c.hex then
					expect(info.Incident).toBe(c.hex)
				end
			end
			local s = stats()
			expect(s.BadRequests).toBe(1)
			expect(s.Busy).toBe(1)
			expect(s.CallsRateLimited).toBe(1)
		end)

		it("rejects MissingInstance when a typed Instance reply arrives nil", function()
			local p = call(NEEDSPART)
			local q = call(NEEDSPART)
			flush()
			local ids = callIds(fired[1].frame)
			local part = Instance.new("Part")
			local frame = s2c(function(w)
				Codec.writeU8(w, C.Op.OK)
				Codec.writeU16(w, ids[1])
				Codec.writeU8(w, C.Op.OK)
				Codec.writeU16(w, ids[2])
			end)
			receive(frame, { nil :: any, part }) -- first ref slot empty (streamed out), second present
			local ok1, message, info = p:await()
			expect(ok1).toBe(false)
			expect(message).toBe(P .. "MissingInstance")
			expect(info.Code).toBe("MissingInstance")
			local ok2, v = q:await()
			expect(ok2).toBe(true)
			expect(v).toBe(part)
		end)

		it("drops the rest of a frame after an OK or ERR for an unknown call id", function()
			local hits = counter(HIT)
			receive(s2c(function(w)
				okMsg(w, 999)
				signalMsg(w, HIT, 1)
			end))
			expect(hits()).toBe(0)
			receive(s2c(function(w)
				errMsg(w, 998, C.Err.Busy, nil, false, nil, nil)
				signalMsg(w, HIT, 1)
			end))
			expect(hits()).toBe(0)
			receive(s2c(function(w)
				signalMsg(w, HIT, 1)
			end))
			expect(hits()).toBe(1)
		end)

		it("drops the rest of a frame after an unknown route, a Method route or a reserved op", function()
			local hits = counter(HIT)
			local function probe(build: (any) -> ())
				receive(s2c(function(w)
					build(w)
					signalMsg(w, HIT, 1)
				end))
			end
			probe(function(w)
				Codec.writeHead(w, 200) -- no such route
			end)
			probe(function(w)
				Codec.writeHead(w, ECHO) -- a Method route never travels S->C as a message head
				Codec.writeU8(w, 0)
			end)
			probe(function(w)
				Codec.writeU8(w, 0xF7) -- reserved control op
			end)
			probe(function(w)
				Codec.writeU8(w, C.Op.HELLO) -- C->S only
				Codec.writeU8(w, C.PROTO)
			end)
			probe(function(w)
				Codec.writeU8(w, 0x00) -- invalid head
			end)
			expect(hits()).toBe(0)
			-- a truncated Hit (argc says 2, one value present) is a structural error too
			receive(s2c(function(w)
				Codec.writeHead(w, HIT)
				Codec.writeU8(w, 2)
				Codec.writeU8(w, 0x81)
			end))
			expect(hits()).toBe(0)
			receive(s2c(function(w)
				signalMsg(w, HIT, 1)
			end))
			expect(hits()).toBe(1)
		end)

		it("decodes and drops a late reply (LateReplies) and keeps decoding", function()
			local p = call(ECHO, 1)
			p:catch(noop)
			flush()
			local id = callIds(fired[1].frame)[1]
			now += 10
			ClientNet._test.heartbeat(0) -- sweeper
			expect(p:getStatus()).toBe("Rejected")
			local hits = counter(HIT)
			receive(s2c(function(w)
				okMsg(w, id, "late", { 1, 2 })
				signalMsg(w, HIT, 1)
			end))
			expect(stats().LateReplies).toBe(1)
			expect(hits()).toBe(1)
		end)

		it("rejects the calls of FrameDropped runs (wrap-aware) and counts their events", function()
			ClientNet._test.setSeq(false, 65534)
			local a = call(ECHO)
			flush()
			local b = call(ECHO)
			fire(PING)
			flush()
			local c = call(ECHO)
			flush()
			expect(parse(fired[1].frame).seq).toBe(65534)
			expect(parse(fired[2].frame).seq).toBe(65535)
			expect(parse(fired[3].frame).seq).toBe(0)
			for _, p in { a, b, c } do
				p:catch(noop)
			end
			receive(s2c(function(w)
				noticeMsg(w, C.Notice.FrameDropped, 65535, 2)
			end))
			expect(a:getStatus()).toBe("Started")
			local _, mb = b:await()
			local _, mc = c:await()
			expect(mb).toBe(P .. "RateLimited")
			expect(mc).toBe(P .. "RateLimited")
			local s = stats()
			expect(s.FramesDropped).toBe(2)
			expect(s.EventsLost).toBe(1)
			expect(s.CallsRateLimited).toBe(2)
		end)

		it("counts events of unreliable FrameDropped runs once, and not after they leave the ring", function()
			fire(SEQ, 1)
			fire(SEQ, 2)
			flush() -- unreliable seq 0, two events
			local function drop(first: number)
				receive(s2c(function(w)
					noticeMsg(w, C.Notice.UFrameDropped, first, 1)
				end))
			end
			drop(0)
			expect(stats().EventsLost).toBe(2)
			drop(0)
			expect(stats().EventsLost).toBe(2)
			fire(SEQ, 3)
			flush() -- seq 1
			for _ = 1, 256 do -- seqs 2..257; seq 257 takes seq 1's ring slot
				now += 0.01
				fire(SEQ, 0)
				flush()
			end
			expect(ClientNet._test.state().unrSeq).toBe(258)
			drop(1)
			expect(stats().EventsLost).toBe(2)
			expect(stats().FramesDropped).toBe(3)
		end)

		it("ignores unknown NOTICE kinds; ShuttingDown rejects later calls locally", function()
			local hits = counter(HIT)
			receive(s2c(function(w)
				noticeMsg(w, 9, 0, 0)
				signalMsg(w, HIT, 1)
			end))
			expect(hits()).toBe(1)
			local pending = call(ECHO)
			pending:catch(noop)
			receive(s2c(function(w)
				noticeMsg(w, C.Notice.ShuttingDown, 0, 0)
				noticeMsg(w, C.Notice.OutboxOverflow, 0, 12)
			end))
			local ok, message, info = call(ECHO):await()
			expect(ok).toBe(false)
			expect(message).toBe(P .. "ShuttingDown")
			expect(info.Code).toBe("ShuttingDown")
			expect(pending:getStatus()).toBe("Started") -- pending calls keep waiting
			expect(stats().OutboxDropped).toBe(12)
		end)

		it("drops frames before the MANIFEST, installs it in-frame and delivers what follows", function()
			fresh()
			ClientNet._test.begin()
			local m = makeModel()
			receive(
				s2c(function(w)
					Codec.writeHead(w, STREAM)
					Codec.writeU16(w, 1)
					Codec.writeU32(w, 5)
				end),
				nil,
				true
			)
			receive(s2c(function(w)
				signalMsg(w, HIT, 1) -- an earlier session's frame: does not start with MANIFEST
			end))
			expect(stats().FramesIn).toBe(0)
			expect(#ClientNet.routes()).toBe(0)
			receive(s2c(function(w)
				manifestMsg(w, m)
				signalMsg(w, HIT, 7)
			end))
			expect(#ClientNet.routes()).toBe(10)
			expect(ClientNet._test.state().phase).toBe(2)
			local got: { any } = {}
			route(HIT).signal:Connect(function(v)
				table.insert(got, v)
			end)
			task.wait()
			expect(got).toEqual({ 7 })
		end)

		it("skips a repeated MANIFEST by its length", function()
			local before = ClientNet.routes()
			local hits = counter(HIT)
			receive(s2c(function(w)
				manifestMsg(w, makeModel())
				signalMsg(w, HIT, 1)
			end))
			expect(ClientNet.routes()).toBe(before)
			expect(hits()).toBe(1)
		end)

		it("records the reason of an unusable MANIFEST", function()
			fresh()
			ClientNet._test.begin()
			receive(s2c(function(w)
				Codec.writeU8(w, C.Op.MANIFEST)
				Codec.writeU32(w, 3)
				Codec.writeU8(w, 1) -- proto 1
				Codec.writeU8(w, 0)
				Codec.writeU8(w, 0)
			end))
			local reason = ClientNet._test.state().manifestError
			expect(type(reason)).toBe("string")
			expect(#ClientNet.routes()).toBe(0)
		end)
	end)

	describe("proxies", function()
		it("builds one cached proxy per service with prebuilt stubs", function()
			local proxies = Proxy.build(model)
			expect(Proxy.build(model)).toBe(proxies)
			local svc = Proxy.get("Svc")
			expect(svc).toBe(proxies.Svc)
			expect(svc.Echo).toBe(svc.Echo)
			expect(svc.Try.Echo).toBe(svc.Try.Echo)
			expect(svc.Signals.Hit).toBe(route(HIT).signal)
			expect(Proxy.names()).toEqual({ "Svc" })
			expect(Proxy.get("Nope")).toBeNil()
			for _, tbl in { svc, svc.Signals, svc.ClientEvents, svc.Try, svc.ClientEvents.Ping } do
				expect(table.isfrozen(tbl)).toBe(true)
			end
		end)

		it("raises for unknown keys with a suggestion and the member list", function()
			local svc = Proxy.build(model).Svc
			expect(function()
				return svc.Ecoh
			end).toThrow("Did you mean 'Echo'?")
			expect(function()
				return svc.echo
			end).toThrow("Did you mean 'Echo'?")
			expect(function()
				return svc.Zzzzzz
			end).toThrow("Svc has no method 'Zzzzzz'. Members: Echo, Fast, NeedsPart")
			expect(function()
				return svc.Hit
			end).toThrow("It is a Signal: use Svc.Signals.Hit.")
			expect(function()
				return svc.Ping
			end).toThrow("It is a ClientEvent")
			expect(function()
				return svc.Signals.Hti
			end).toThrow("has no Signal 'Hti'. Did you mean 'Hit'?")
			expect(function()
				return svc.ClientEvents.Nope
			end).toThrow("Members: Aim, Blob, Ping, Seq")
			expect(function()
				return svc.Try.Nope
			end).toThrow("Svc.Try has no method 'Nope'")
		end)

		it("raises for dot calls with arguments; Svc.M() with none still calls", function()
			local svc = Proxy.build(model).Svc
			expect(function()
				svc.Echo(1)
			end).toThrow("Call Svc:Echo(...) with ':'")
			expect(function()
				svc.Try.Echo(1)
			end).toThrow("Call Svc.Try:Echo(...) with ':'")
			local p = svc.Echo()
			expect(p:getStatus()).toBe("Started")
			p:catch(noop)
			flush()
			local f = parse(fired[1].frame)
			expect(buffer.readu8(fired[1].frame, f.msgs[1].body + 2)).toBe(0) -- argc 0
		end)

		it("returns a Promise from proxy:M() and (ok, ...) from proxy.Try:M()", function()
			local svc = Proxy.build(model).Svc
			local result: any = nil
			task.spawn(function()
				result = table.pack(svc.Try:Echo(5))
			end)
			expect(result).toBeNil()
			local p = svc:Echo(6)
			flush()
			local ids = callIds(fired[1].frame)
			receive(s2c(function(w)
				okMsg(w, ids[1], 5, "five")
				okMsg(w, ids[2], 6)
			end))
			expect(result[1]).toBe(true)
			expect(result[2]).toBe(5)
			expect(result[3]).toBe("five")
			local ok, v = p:await()
			expect(ok).toBe(true)
			expect(v).toBe(6)
		end)

		it("raises when Try runs where the thread cannot yield", function()
			local svc = Proxy.build(model).Svc
			local probe = setmetatable({}, {
				__index = function()
					return svc.Try:Echo()
				end,
			}) :: any
			expect(function()
				return probe.x
			end).toThrow("must run in a thread that can yield")
			expect(stats().PendingCalls).toBe(0)
		end)

		it("fires ClientEvents with ':' and raises for dot Fire with arguments, Connect and typos", function()
			local events = Proxy.build(model).Svc.ClientEvents
			local ev = events.Ping
			ev:Fire(1, 2)
			ev.Fire() -- no arguments: allowed, like proxy.M()
			expect(function()
				ev.Fire(1)
			end).toThrow("with ':'")
			expect(function()
				ev:Connect(function() end)
			end).toThrow("ClientEvents are client-to-server")
			expect(function()
				return ev.Fires
			end).toThrow("has no member 'Fires'")
			expect(function()
				events.Aim:Fire("not a vector")
			end).toThrow("Svc.Aim:Fire: arg 1")
			flush()
			local f = parse(fired[1].frame)
			expect(f.nmsg).toBe(2)
			expect(f.msgs[1].route).toBe(PING)
		end)
	end)
end
