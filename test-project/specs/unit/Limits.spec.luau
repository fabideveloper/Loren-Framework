--!strict
-- Unit spec: LorenServer.Limits (limiter lane). Runs on the server in Studio (Run mode or Play).
-- Every Limits function takes `now`, so the clock here is fake and every result is deterministic.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Bucket = require(ReplicatedStorage.LorenRuntime.Bucket)
local Limits = require(ServerScriptService.LorenServer.Limits)

local D = C.Default

-- A resolved Config (C.Default plus overrides), like Config.get() returns.
local function config(overrides: { [string]: any }?): any
	local cfg: { [string]: any } = {}
	for k, v in D :: any do
		cfg[k] = v
	end
	cfg.Members = {}
	if overrides then
		for k, v in overrides do
			cfg[k] = v
		end
	end
	return cfg
end

type Frame = { unreliable: boolean, cost: number, nmsg: number }
type Arrival = { at: number, frame: Frame }
type SimOptions = {
	seconds: number,
	mirror: number,
	seed: number,
	frame: (rng: Random) -> Frame,
	jitter: (rng: Random, sentAt: number, seconds: number) -> number,
}

--[[
	An honest client with an endless backlog: it flushes at FLUSH_HZ and fires queued frames while its
	admission mirror (every server rate and burst x `mirror`) can pay for the whole frame, charging
	all three buckets at fire time (IMPLEMENTATION.md 3.17 Mirror). Each frame reaches the server after
	a fixed latency plus `jitter`; the server admits frames in arrival order. Returns (sent, refused).
]]
local function simulate(opts: SimOptions): (number, number)
	local m = opts.mirror
	local rng = Random.new(opts.seed)
	local cf = Bucket.new(D.FrameRate * m, D.FrameBurst * m, 0)
	local cu = Bucket.new(D.FrameRate * m, D.FrameBurst * m, 0)
	local cb = Bucket.new(D.ByteRate * m, D.ByteBurst * m, 0)
	local cm = Bucket.new(D.MessageRate * m, D.MessageBurst * m, 0)
	local arrivals: { Arrival } = {}
	local pending = opts.frame(rng)
	local hz = C.Limit.FLUSH_HZ
	for step = 0, math.floor(opts.seconds * hz) do
		local now = step / hz
		while true do
			local fb = if pending.unreliable then cu else cf
			if Bucket.can(fb, 1, now) and Bucket.can(cb, pending.cost, now) and Bucket.can(cm, pending.nmsg, now) then
				Bucket.take(fb, 1, now)
				Bucket.take(cb, pending.cost, now)
				Bucket.take(cm, pending.nmsg, now)
				table.insert(arrivals, { at = now + 0.05 + opts.jitter(rng, now, opts.seconds), frame = pending })
				pending = opts.frame(rng)
			else
				break
			end
		end
	end
	table.sort(arrivals, function(a: Arrival, b: Arrival): boolean
		return a.at < b.at
	end)
	local pl = Limits.newPlayer(0)
	local refused = 0
	for _, a in arrivals do
		local f = a.frame
		if not Limits.admitFrame(pl, f.unreliable, f.cost, f.nmsg, a.at) then
			refused += 1
		end
	end
	return #arrivals, refused
end

local MSG_CAP = math.min(C.Limit.MAX_MSGS_PER_FRAME, math.floor(D.MessageBurst * D.MirrorFraction))

local function randomJitter(rng: Random, _sentAt: number, _seconds: number): number
	return rng:NextNumber(0, 0.1)
end

-- Frames sent in the first half are 100 ms late, the rest on time: at the switch the server sees
-- 100 ms of traffic twice as dense as it was sent.
local function stepJitter(_rng: Random, sentAt: number, seconds: number): number
	return if sentAt < seconds / 2 then 0.1 else 0
end

local function smallFrame(rng: Random): Frame
	return { unreliable = false, cost = math.max(rng:NextInteger(8, 200), 64), nmsg = rng:NextInteger(1, 2) }
end

local function hugeFrame(rng: Random): Frame
	local nrefs = rng:NextInteger(0, 255)
	return { unreliable = false, cost = rng:NextInteger(16392, 65544) + 16 * nrefs, nmsg = rng:NextInteger(1, 4) }
end

local function manyMessages(rng: Random): Frame
	return { unreliable = false, cost = rng:NextInteger(200, 4000), nmsg = rng:NextInteger(100, MSG_CAP) }
end

local function mixedFrame(rng: Random): Frame
	local unreliable = rng:NextNumber() < 0.3
	local r = rng:NextNumber()
	local len = if r < 0.7
		then rng:NextInteger(8, 2000)
		elseif r < 0.95 then rng:NextInteger(2000, 16392)
		else rng:NextInteger(16392, 65544)
	local nrefs = if rng:NextNumber() < 0.2 then rng:NextInteger(1, 255) else 0
	if unreliable then
		len = math.min(len, 900)
		nrefs = 0
	end
	local nmsg = if rng:NextNumber() < 0.9 then rng:NextInteger(1, 8) else rng:NextInteger(9, MSG_CAP)
	return { unreliable = unreliable, cost = math.max(len, 64) + 16 * nrefs, nmsg = nmsg }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	beforeAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Limits._reset()
	end)

	afterEach(function()
		Limits._reset()
	end)

	describe("module", function()
		it("is frozen", function()
			expect(table.isfrozen(Limits)).toBe(true)
		end)
	end)

	describe("configure / newPlayer", function()
		it("uses C.Default before configure", function()
			local pl = Limits.newPlayer(3)
			expect(pl.frame.rate).toBe(D.FrameRate)
			expect(pl.frame.burst).toBe(D.FrameBurst)
			expect(pl.uframe.rate).toBe(D.FrameRate)
			expect(pl.uframe.burst).toBe(D.FrameBurst)
			expect(pl.bytes.rate).toBe(D.ByteRate)
			expect(pl.bytes.burst).toBe(D.ByteBurst)
			expect(pl.msgs.rate).toBe(D.MessageRate)
			expect(pl.msgs.burst).toBe(D.MessageBurst)
			expect(pl.badReq.rate).toBe(C.Limit.BR_REPLY_RATE)
			expect(pl.badReq.burst).toBe(16)
		end)

		it("starts every bucket full at now, with no route state", function()
			local pl = Limits.newPlayer(7)
			for _, b in { pl.frame, pl.uframe, pl.bytes, pl.msgs, pl.badReq } do
				expect(b.tokens).toBe(b.burst)
				expect(b.stamp).toBe(7)
			end
			expect(next(pl.rtok)).toBeNil()
			expect(next(pl.rstamp)).toBeNil()
			expect(next(pl.rlNext)).toBeNil()
		end)

		it("gives each player and each channel its own buckets", function()
			local a, b = Limits.newPlayer(0), Limits.newPlayer(0)
			expect(a.frame).never.toBe(b.frame)
			expect(a.bytes).never.toBe(b.bytes)
			expect(a.frame).never.toBe(a.uframe)
			expect(a.rtok).never.toBe(b.rtok)
		end)

		it("configure sets the admission rates; _reset restores C.Default", function()
			Limits.configure(config({
				FrameRate = 10,
				FrameBurst = 20,
				ByteRate = 1000,
				ByteBurst = 2000,
				MessageRate = 30,
				MessageBurst = 40,
			}))
			local pl = Limits.newPlayer(0)
			expect(pl.frame.rate).toBe(10)
			expect(pl.uframe.burst).toBe(20)
			expect(pl.bytes.rate).toBe(1000)
			expect(pl.bytes.tokens).toBe(2000)
			expect(pl.msgs.rate).toBe(30)
			expect(pl.msgs.burst).toBe(40)
			expect(Limits._test.settings()).toEqual({
				FrameRate = 10,
				FrameBurst = 20,
				ByteRate = 1000,
				ByteBurst = 2000,
				MessageRate = 30,
				MessageBurst = 40,
			})
			Limits._reset()
			local again = Limits.newPlayer(0)
			expect(again.frame.rate).toBe(D.FrameRate)
			expect(again.bytes.burst).toBe(D.ByteBurst)
			expect(again.msgs.burst).toBe(D.MessageBurst)
		end)
	end)

	describe("admitFrame", function()
		it("admits and charges one frame, the byte cost and nmsg messages", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, 1000, 10, 0)).toBe(true)
			expect(pl.frame.tokens).toBe(D.FrameBurst - 1)
			expect(pl.uframe.tokens).toBe(D.FrameBurst)
			expect(pl.bytes.tokens).toBe(D.ByteBurst - 1000)
			expect(pl.msgs.tokens).toBe(D.MessageBurst - 10)
		end)

		it("keeps one frame bucket per channel", function()
			Limits.configure(config({ FrameRate = 1, FrameBurst = 2 }))
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(true)
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(true)
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(false)
			expect(Limits.admitFrame(pl, true, 64, 1, 0)).toBe(true)
			expect(Limits.admitFrame(pl, true, 64, 1, 0)).toBe(true)
			expect(Limits.admitFrame(pl, true, 64, 1, 0)).toBe(false)
		end)

		it("charges nothing when the frame bucket is empty", function()
			Limits.configure(config({ FrameRate = 1, FrameBurst = 1 }))
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, 100, 5, 0)).toBe(true)
			local bytes, msgs = pl.bytes.tokens, pl.msgs.tokens
			expect(Limits.admitFrame(pl, false, 100, 5, 0)).toBe(false)
			expect(pl.bytes.tokens).toBe(bytes)
			expect(pl.msgs.tokens).toBe(msgs)
			expect(pl.frame.tokens).toBe(0)
		end)

		it("charges nothing when the byte bucket cannot pay", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, D.ByteBurst + 1, 1, 0)).toBe(false)
			expect(pl.frame.tokens).toBe(D.FrameBurst)
			expect(pl.bytes.tokens).toBe(D.ByteBurst)
			expect(pl.msgs.tokens).toBe(D.MessageBurst)
		end)

		it("charges nothing when the message bucket cannot pay", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, true, 64, D.MessageBurst + 1, 0)).toBe(false)
			expect(pl.uframe.tokens).toBe(D.FrameBurst)
			expect(pl.bytes.tokens).toBe(D.ByteBurst)
			expect(pl.msgs.tokens).toBe(D.MessageBurst)
		end)

		it("admits a cost equal to the byte tokens left, then refuses", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, D.ByteBurst, 1, 0)).toBe(true)
			expect(pl.bytes.tokens).toBe(0)
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(false)
		end)

		it("charges nmsg per frame and refills messages with time", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, 64, 300, 0)).toBe(true)
			expect(Limits.admitFrame(pl, false, 64, 300, 0)).toBe(true)
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(false)
			expect(Limits.admitFrame(pl, false, 64, 300, 0.5)).toBe(true) -- 600/s x 0.5 s
			expect(Limits.admitFrame(pl, false, 64, 1, 0.5)).toBe(false)
		end)

		it("refills frames with time at FrameRate", function()
			local pl = Limits.newPlayer(0)
			for _ = 1, D.FrameBurst do
				expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(true)
			end
			expect(Limits.admitFrame(pl, false, 64, 1, 0)).toBe(false)
			expect(Limits.admitFrame(pl, false, 64, 1, 0.5 / D.FrameRate)).toBe(false)
			expect(Limits.admitFrame(pl, false, 64, 1, 1.01 / D.FrameRate)).toBe(true)
		end)

		it("shares the byte and message buckets across both channels", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.admitFrame(pl, false, 200000, 1, 0)).toBe(true)
			expect(Limits.admitFrame(pl, true, 100000, 1, 0)).toBe(false)
			expect(Limits.admitFrame(pl, true, 60000, 1, 0)).toBe(true)
			expect(pl.bytes.tokens).toBe(D.ByteBurst - 260000)
		end)

		it("holds a flood to burst + rate x time", function()
			local pl = Limits.newPlayer(0)
			local admitted = 0
			for i = 0, 9999 do -- 1000 tiny frames per second for 10 s
				if Limits.admitFrame(pl, false, 64, 1, i / 1000) then
					admitted += 1
				end
			end
			expect(admitted).toBeLessThanOrEqual(D.FrameBurst + D.FrameRate * 10)
			expect(admitted).toBeGreaterThanOrEqual(D.FrameBurst + D.FrameRate * 10 - 2)
		end)
	end)

	describe("chargeBytes", function()
		it("charges only the byte bucket", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.chargeBytes(pl, 5000, 0)).toBe(true)
			expect(pl.bytes.tokens).toBe(D.ByteBurst - 5000)
			expect(pl.frame.tokens).toBe(D.FrameBurst)
			expect(pl.msgs.tokens).toBe(D.MessageBurst)
		end)

		it("refuses without charging when the bucket cannot pay", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.chargeBytes(pl, D.ByteBurst - 100, 0)).toBe(true)
			expect(Limits.chargeBytes(pl, 101, 0)).toBe(false)
			expect(pl.bytes.tokens).toBe(100)
		end)
	end)

	describe("takeRoute", function()
		it("starts full at burst on first use", function()
			local pl = Limits.newPlayer(0)
			expect(pl.rtok[7]).toBeNil()
			for _ = 1, 5 do
				expect(Limits.takeRoute(pl, 7, 50, 5, 0)).toBe(true)
			end
			expect(Limits.takeRoute(pl, 7, 50, 5, 0)).toBe(false)
			expect(pl.rtok[7]).toBe(0)
		end)

		it("keeps routes and players independent", function()
			local a, b = Limits.newPlayer(0), Limits.newPlayer(0)
			expect(Limits.takeRoute(a, 1, 1, 1, 0)).toBe(true)
			expect(Limits.takeRoute(a, 1, 1, 1, 0)).toBe(false)
			expect(Limits.takeRoute(a, 2, 1, 1, 0)).toBe(true)
			expect(Limits.takeRoute(b, 1, 1, 1, 0)).toBe(true)
		end)

		it("refills at the route rate, capped at burst", function()
			local pl = Limits.newPlayer(0)
			for _ = 1, 3 do
				Limits.takeRoute(pl, 9, 2, 3, 0)
			end
			expect(Limits.takeRoute(pl, 9, 2, 3, 0.4)).toBe(false) -- 0.8 tokens
			expect(Limits.takeRoute(pl, 9, 2, 3, 0.51)).toBe(true) -- 1.02 tokens
			local passed = 0
			for _ = 1, 10 do
				if Limits.takeRoute(pl, 9, 2, 3, 1000) then
					passed += 1
				end
			end
			expect(passed).toBe(3)
		end)

		it("keeps the refilled tokens when it refuses", function()
			local pl = Limits.newPlayer(0)
			expect(Limits.takeRoute(pl, 4, 1, 1, 0)).toBe(true)
			expect(Limits.takeRoute(pl, 4, 1, 1, 0.5)).toBe(false)
			expect(pl.rtok[4]).toBe(0.5)
			expect(pl.rstamp[4]).toBe(0.5)
			expect(Limits.takeRoute(pl, 4, 1, 1, 1)).toBe(true)
		end)

		it("works for 1-, 2- and 3-byte route ids", function()
			local pl = Limits.newPlayer(0)
			for _, route in { 1, 223, 224, 4063, 4064, 65535 } do
				expect(Limits.takeRoute(pl, route, 50, 1, 0)).toBe(true)
				expect(Limits.takeRoute(pl, route, 50, 1, 0)).toBe(false)
			end
		end)

		it("holds a 1000/s call flood to burst + rate x time", function()
			local pl = Limits.newPlayer(0)
			local passed = 0
			for i = 0, 9999 do
				if Limits.takeRoute(pl, 5, D.MethodRate, D.MethodBurst, i / 1000) then
					passed += 1
				end
			end
			expect(passed).toBeLessThanOrEqual(D.MethodBurst + D.MethodRate * 10)
			expect(passed).toBeGreaterThanOrEqual(D.MethodBurst + D.MethodRate * 10 - 2)
		end)
	end)

	describe("reply caps", function()
		it("allows one RateLimited reply per route per player per second", function()
			local a, b = Limits.newPlayer(0), Limits.newPlayer(0)
			expect(Limits.allowRateLimitedReply(a, 3, 0)).toBe(true)
			expect(Limits.allowRateLimitedReply(a, 3, 0)).toBe(false)
			expect(Limits.allowRateLimitedReply(a, 3, 0.999)).toBe(false)
			expect(Limits.allowRateLimitedReply(a, 4, 0.5)).toBe(true)
			expect(Limits.allowRateLimitedReply(b, 3, 0.5)).toBe(true)
			expect(Limits.allowRateLimitedReply(a, 3, C.Limit.RL_REPLY_INTERVAL)).toBe(true)
			expect(Limits.allowRateLimitedReply(a, 3, 1.5)).toBe(false)
		end)

		it("sends 10 RateLimited replies for a 10 s flood on one route", function()
			local pl = Limits.newPlayer(0)
			local replies = 0
			for i = 0, 9999 do
				if Limits.allowRateLimitedReply(pl, 1, i / 1000) then
					replies += 1
				end
			end
			expect(replies).toBe(10)
		end)

		it("allows 16 BadRequest replies at once, then 16 per second", function()
			local pl = Limits.newPlayer(0)
			for _ = 1, 16 do
				expect(Limits.allowBadRequestReply(pl, 0)).toBe(true)
			end
			expect(Limits.allowBadRequestReply(pl, 0)).toBe(false)
			expect(Limits.allowBadRequestReply(pl, 0.5 / 16)).toBe(false)
			expect(Limits.allowBadRequestReply(pl, 1.01 / 16)).toBe(true)
			local replies = 0
			for i = 0, 9999 do
				if Limits.allowBadRequestReply(pl, 1 + i / 1000) then
					replies += 1
				end
			end
			-- tokens left after the first second (< 16) + 16/s for 10 s
			expect(replies).toBeGreaterThanOrEqual(16 * 10 - 1)
			expect(replies).toBeLessThanOrEqual(16 + 16 * 10)
		end)
	end)

	describe("honest client mirror (MirrorFraction)", function()
		it("never refuses a mirror-paced client sending tiny frames", function()
			local sent, refused = simulate({
				seconds = 20,
				mirror = D.MirrorFraction,
				seed = 1,
				frame = smallFrame,
				jitter = stepJitter,
			})
			expect(sent).toBeGreaterThan(1500)
			expect(refused).toBe(0)
		end)

		it("never refuses a mirror-paced client sending 64 KiB frames with refs", function()
			local sent, refused = simulate({
				seconds = 20,
				mirror = D.MirrorFraction,
				seed = 2,
				frame = hugeFrame,
				jitter = randomJitter,
			})
			expect(sent).toBeGreaterThan(30)
			expect(refused).toBe(0)
		end)

		it("never refuses a mirror-paced client sending frames of many messages", function()
			local sent, refused = simulate({
				seconds = 20,
				mirror = D.MirrorFraction,
				seed = 3,
				frame = manyMessages,
				jitter = stepJitter,
			})
			expect(sent).toBeGreaterThan(20)
			expect(refused).toBe(0)
		end)

		it("never refuses a mirror-paced client on both channels with mixed frames", function()
			local sent, refused = simulate({
				seconds = 30,
				mirror = D.MirrorFraction,
				seed = 4,
				frame = mixedFrame,
				jitter = randomJitter,
			})
			expect(sent).toBeGreaterThan(100)
			expect(refused).toBe(0)
		end)

		it("control: a client pacing at 100% of the server rate does get refused under the same jitter", function()
			local sent, refused = simulate({
				seconds = 20,
				mirror = 1,
				seed = 1,
				frame = smallFrame,
				jitter = stepJitter,
			})
			expect(sent).toBeGreaterThan(1500)
			expect(refused).toBeGreaterThan(0)
		end)
	end)
end
