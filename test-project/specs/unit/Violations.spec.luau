--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Log = require(ReplicatedStorage.LorenRuntime.Log)
local Violations = require(ServerScriptService.LorenServer.Violations)

local V = C.Violation
local Drop = C.Drop
local KICK_MESSAGE = C.PREFIX .. "Disconnected: invalid network traffic"

local function fakePlayer(userId: number, kick: ((...any) -> ...any)?): any
	return {
		UserId = userId,
		Name = "Fake" .. userId,
		Kick = kick or function() end,
	}
end

local function config(overrides: { [string]: any }?): any
	local cfg: { [string]: any } = {}
	for k, v in C.Default :: any do
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

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local warned: { string } = {}
	local logNow = 0

	beforeAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		local Loren = require(ReplicatedStorage.LorenRuntime) :: any
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Violations._reset()
		Log._reset()
		warned = {}
		logNow = 0
		Log._test.setSink(function() end, function(line: string)
			table.insert(warned, line)
		end)
		Log._test.setClock(function()
			return logNow
		end)
	end)

	afterEach(function()
		Violations._reset()
		Log._reset()
	end)

	describe("module", function()
		it("is frozen", function()
			expect(table.isfrozen(Violations)).toBe(true)
		end)

		it("newPlayer starts clean, with the first summary one interval away", function()
			local pv = Violations.newPlayer(5)
			expect(pv.score).toBe(0)
			expect(pv.stamp).toBe(5)
			expect(pv.total).toBe(0)
			expect(pv.kicked).toBe(false)
			expect(pv.dirty).toBe(false)
			expect(pv.nextSummary).toBe(5 + C.Limit.SUMMARY_INTERVAL)
			expect(#pv.winViol).toBe(#C.ViolationName)
			expect(#pv.winDrop).toBe(C.DROP_KINDS)
			for _, n in pv.winDrop do
				expect(n).toBe(0)
			end
		end)
	end)

	describe("record", function()
		it("adds each kind's weight", function()
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0)
			expect(pv.score).toBe(C.ViolationWeight[V.Envelope])
			Violations.record(p, pv, V.Route, 0)
			Violations.record(p, pv, V.Payload, 0)
			expect(pv.score).toBe(10 + 5 + 2)
			expect(pv.total).toBe(3)
			expect(pv.winViol[V.Envelope]).toBe(1)
			expect(pv.winViol[V.Route]).toBe(1)
			expect(pv.winViol[V.Payload]).toBe(1)
			expect(pv.dirty).toBe(true)
		end)

		it("uses C.ViolationWeight for every kind (10 structural, 5 protocol, 2 payload)", function()
			local expected = {
				[V.Envelope] = 10,
				[V.ExtraArgs] = 10,
				[V.FrameSize] = 10,
				[V.Refs] = 10,
				[V.Framing] = 10,
				[V.BadOp] = 10,
				[V.Route] = 5,
				[V.BeforeHello] = 5,
				[V.RepeatHello] = 5,
				[V.DuplicateCall] = 5,
				[V.Payload] = 2,
				[V.Sidecar] = 2,
			}
			expect(#C.ViolationName).toBe(12)
			for kind = 1, #C.ViolationName do
				local p, pv = fakePlayer(kind), Violations.newPlayer(0)
				Violations.record(p, pv, kind, 0)
				expect(pv.score).toBe(expected[kind])
				expect(pv.winViol[kind]).toBe(1)
				expect(pv.pending[kind]).toBe(1)
			end
			expect(Violations.totals().violations).toBe(12)
		end)

		it("decays SCORE_DECAY points per second, never below zero", function()
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0) -- 10
			Violations.record(p, pv, V.Route, 3) -- 10 - 3 + 5
			expect(pv.score).toBe(12)
			Violations.record(p, pv, V.Payload, 100) -- max(0, 12 - 97) + 2
			expect(pv.score).toBe(2)
			expect(pv.stamp).toBe(100)
		end)

		it("does not decay or move the stamp for an older now", function()
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 10)
			Violations.record(p, pv, V.Envelope, 5)
			expect(pv.score).toBe(20)
			expect(pv.stamp).toBe(10)
		end)

		it("ignores numbers that are not violation kinds", function()
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			for _, kind in { 0, -1, 13, 99, 1.5 } do
				Violations.record(p, pv, kind, 0)
			end
			expect(pv.score).toBe(0)
			expect(pv.total).toBe(0)
			expect(pv.dirty).toBe(false)
			expect(Violations.totals().violations).toBe(0)
		end)

		it("counts server-wide totals across players", function()
			Violations.record(fakePlayer(1), Violations.newPlayer(0), V.Framing, 0)
			Violations.record(fakePlayer(2), Violations.newPlayer(0), V.Framing, 0)
			expect(Violations.totals().violations).toBe(2)
		end)
	end)

	describe("drop", function()
		it("counts per kind in the window and in the totals", function()
			local pv = Violations.newPlayer(0)
			Violations.drop(pv, Drop.RateLimited, 40)
			Violations.drop(pv, Drop.RateLimited, 2)
			Violations.drop(pv, Drop.FrameDropped, 1)
			expect(pv.winDrop[Drop.RateLimited]).toBe(42)
			expect(pv.winDrop[Drop.FrameDropped]).toBe(1)
			expect(pv.dirty).toBe(true)
			local totals = Violations.totals()
			expect(totals.drops[Drop.RateLimited]).toBe(42)
			expect(totals.drops[Drop.FrameDropped]).toBe(1)
			expect(#totals.drops).toBe(C.DROP_KINDS)
		end)

		it("accepts a nil player state (Departed)", function()
			Violations.drop(nil, Drop.Departed, 1)
			expect(Violations.totals().drops[Drop.Departed]).toBe(1)
		end)

		it("ignores numbers that are not drop kinds", function()
			local pv = Violations.newPlayer(0)
			for _, kind in { 0, C.DROP_KINDS + 1, 1.5, -3, 0 / 0 } do
				Violations.drop(pv, kind, 1)
			end
			expect(pv.dirty).toBe(false)
			for _, n in Violations.totals().drops do
				expect(n).toBe(0)
			end
		end)

		it("ignores counts that are not positive (no empty summary, no NaN totals)", function()
			local p, pv = fakePlayer(3), Violations.newPlayer(0)
			for _, n in { 0, -1, 0 / 0 } do
				Violations.drop(pv, Drop.Busy, n)
			end
			expect(pv.dirty).toBe(false)
			expect(pv.winDrop[Drop.Busy]).toBe(0)
			expect(Violations.totals().drops[Drop.Busy]).toBe(0)
			Violations.tick(p, pv, 30)
			expect(#warned).toBe(0)
		end)

		it("does not touch the score", function()
			local pv = Violations.newPlayer(0)
			Violations.drop(pv, Drop.Busy, 1000)
			expect(pv.score).toBe(0)
			expect(pv.total).toBe(0)
		end)

		it("totals() returns a fresh copy; _reset clears the totals", function()
			local pv = Violations.newPlayer(0)
			Violations.drop(pv, Drop.Stale, 3)
			Violations.record(fakePlayer(1), pv, V.Route, 0)
			local first = Violations.totals()
			first.drops[Drop.Stale] = 999
			expect(Violations.totals().drops[Drop.Stale]).toBe(3)
			Violations._reset()
			local after = Violations.totals()
			expect(after.violations).toBe(0)
			expect(after.drops[Drop.Stale]).toBe(0)
		end)
	end)

	describe("OnViolation", function()
		it("calls handlers at once with (player, kind, score, counts)", function()
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			local p, pv = fakePlayer(7), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0)
			expect(spy.count).toBe(1)
			local call = spy.calls[1]
			expect(call[1]).toBe(p)
			expect(call[2]).toBe("Envelope")
			expect(call[3]).toBe(10)
			expect(call[4]).toEqual({ Envelope = 1 })
			expect(table.isfrozen(call[4])).toBe(true)
		end)

		it("calls at most once per player per second with the counts since the last call", function()
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			local p, pv = fakePlayer(7), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0) -- call 1
			Violations.record(p, pv, V.Framing, 0.2)
			Violations.record(p, pv, V.Framing, 0.4)
			Violations.tick(p, pv, 0.5)
			expect(spy.count).toBe(1)
			Violations.tick(p, pv, 1.0) -- call 2: the pending counts
			expect(spy.count).toBe(2)
			expect(spy.calls[2][2]).toBe("Framing")
			expect(spy.calls[2][3]).toBeCloseTo(29.0, 6) -- 10, 19.8, 29.6 at 0.4, minus 0.6
			expect(spy.calls[2][4]).toEqual({ Framing = 2 })
			Violations.record(p, pv, V.Route, 1.5)
			expect(spy.count).toBe(2)
			Violations.record(p, pv, V.Route, 2.0) -- call 3
			expect(spy.count).toBe(3)
			expect(spy.calls[3][2]).toBe("Route")
			expect(spy.calls[3][3]).toBeCloseTo(38.0, 6)
			expect(spy.calls[3][4]).toEqual({ Route = 2 })
			Violations.tick(p, pv, 10) -- nothing pending
			expect(spy.count).toBe(3)
		end)

		it("throttles each player separately", function()
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			Violations.record(fakePlayer(1), Violations.newPlayer(0), V.Refs, 0)
			Violations.record(fakePlayer(2), Violations.newPlayer(0), V.Refs, 0)
			expect(spy.count).toBe(2)
		end)

		it("stays at <= 1 call per second under a violation flood", function()
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			local p, pv = fakePlayer(3), Violations.newPlayer(0)
			local total = 0
			for i = 0, 9999 do -- 1000 violations per second for 10 s
				Violations.record(p, pv, V.Framing, i / 1000)
				Violations.tick(p, pv, i / 1000)
			end
			expect(spy.count).toBeLessThanOrEqual(10)
			expect(spy.count).toBeGreaterThanOrEqual(9)
			for _, call in spy.calls do
				total += call[4].Framing
			end
			Violations.tick(p, pv, 11)
			total += spy.calls[spy.count][4].Framing
			expect(total).toBe(10000) -- nothing lost, nothing counted twice
		end)

		it("runs every handler even when one throws, and logs the error once through the budget", function()
			local good = t.spy()
			Violations.onViolation(function()
				error("boom")
			end)
			Violations.onViolation(good.fn)
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			expect(function()
				Violations.record(p, pv, V.BadOp, 0)
			end).never.toThrow()
			expect(good.count).toBe(1)
			expect(#warned).toBe(1)
			expect(warned[1]).toContain(C.PREFIX .. "OnViolation handler failed")
			expect(warned[1]).toContain("boom")
		end)

		it("runs handlers on their own threads (a yielding handler does not block record)", function()
			local finished = false
			Violations.onViolation(function()
				task.wait(0.05)
				finished = true
			end)
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			Violations.record(p, pv, V.Route, 0)
			expect(finished).toBe(false)
			local deadline = os.clock() + 3
			while not finished and os.clock() < deadline do
				task.wait()
			end
			expect(finished).toBe(true)
		end)

		it("delivers counts gathered before the first handler was added", function()
			local p, pv = fakePlayer(1), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0)
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			Violations.record(p, pv, V.Envelope, 0.1)
			expect(spy.count).toBe(1)
			expect(spy.calls[1][4]).toEqual({ Envelope = 2 })
		end)

		it("rejects a non-function", function()
			expect(function()
				Violations.onViolation(5 :: any)
			end).toThrow("OnViolation expects a function")
			expect(Violations._test.handlerCount()).toBe(0)
		end)

		it("_reset removes the handlers", function()
			local spy = t.spy()
			Violations.onViolation(spy.fn)
			Violations._reset()
			Violations.record(fakePlayer(1), Violations.newPlayer(0), V.Route, 0)
			expect(spy.count).toBe(0)
		end)
	end)

	describe("KickScore", function()
		it("kicks exactly once when the score reaches KickScore", function()
			Violations.configure(config({ KickScore = 25 }))
			local kick = t.spy()
			local p, pv = fakePlayer(1, kick.fn), Violations.newPlayer(0)
			Violations.record(p, pv, V.Envelope, 0)
			Violations.record(p, pv, V.Envelope, 0)
			expect(kick.count).toBe(0)
			Violations.record(p, pv, V.Envelope, 0) -- 30 >= 25
			expect(kick.count).toBe(1)
			expect(kick.calls[1][1]).toBe(p)
			expect(kick.calls[1][2]).toBe(KICK_MESSAGE)
			expect(pv.kicked).toBe(true)
			for _ = 1, 20 do
				Violations.record(p, pv, V.Envelope, 0)
			end
			expect(kick.count).toBe(1)
		end)

		it("counts decay: slow violations never reach KickScore", function()
			Violations.configure(config({ KickScore = 25 }))
			local kick = t.spy()
			local p, pv = fakePlayer(1, kick.fn), Violations.newPlayer(0)
			for i = 0, 100 do -- one weight-5 violation every 5 s
				Violations.record(p, pv, V.Route, i * 5)
			end
			expect(kick.count).toBe(0)
		end)

		it("never kicks when KickScore is false (the default)", function()
			local kick = t.spy()
			local p, pv = fakePlayer(1, kick.fn), Violations.newPlayer(0)
			for _ = 1, 100 do
				Violations.record(p, pv, V.Envelope, 0)
			end
			expect(kick.count).toBe(0)
			expect(Violations._test.kickScore()).toBe(false)
		end)

		it("treats a non-positive KickScore as off; _reset restores false", function()
			Violations.configure(config({ KickScore = 0 }))
			expect(Violations._test.kickScore()).toBe(false)
			Violations.configure(config({ KickScore = 40 }))
			expect(Violations._test.kickScore()).toBe(40)
			Violations._reset()
			expect(Violations._test.kickScore()).toBe(false)
		end)

		it("survives a Kick that throws", function()
			Violations.configure(config({ KickScore = 5 }))
			local p = fakePlayer(1, function()
				error("cannot kick")
			end)
			local pv = Violations.newPlayer(0)
			expect(function()
				Violations.record(p, pv, V.Envelope, 0)
			end).never.toThrow()
			expect(pv.kicked).toBe(true)
		end)
	end)

	describe("tick summaries", function()
		it("prints nothing before the window closes", function()
			local p, pv = fakePlayer(42), Violations.newPlayer(0)
			Violations.drop(pv, Drop.RateLimited, 5)
			Violations.record(p, pv, V.Route, 1)
			for s = 1, 29 do
				Violations.tick(p, pv, s)
			end
			expect(#warned).toBe(0)
		end)

		it("prints one line per window with the drop and violation counts", function()
			local p, pv = fakePlayer(42), Violations.newPlayer(0)
			Violations.drop(pv, Drop.FrameDropped, 17)
			for _ = 1, 40 do
				Violations.drop(pv, Drop.RateLimited, 1)
			end
			Violations.record(p, pv, V.Envelope, 25)
			Violations.tick(p, pv, 30)
			expect(#warned).toBe(1)
			expect(warned[1]).toBe(
				C.PREFIX .. "uid=42 last 30s: FrameDropped 17, RateLimited 40; violations Envelope 1 (score 5.0)"
			)
		end)

		it("resets the window after a summary", function()
			local p, pv = fakePlayer(42), Violations.newPlayer(0)
			Violations.drop(pv, Drop.EventLimited, 1)
			Violations.tick(p, pv, 30)
			expect(#warned).toBe(1)
			expect(pv.dirty).toBe(false)
			expect(pv.winDrop[Drop.EventLimited]).toBe(0)
			Violations.tick(p, pv, 31)
			Violations.drop(pv, Drop.Busy, 3)
			Violations.tick(p, pv, 59)
			expect(#warned).toBe(1)
			Violations.tick(p, pv, 60)
			expect(#warned).toBe(2)
			expect(warned[2]).toBe(C.PREFIX .. "uid=42 last 30s: Busy 3 (score 0.0)")
		end)

		it("prints violations alone when nothing was dropped", function()
			local p, pv = fakePlayer(9), Violations.newPlayer(0)
			Violations.record(p, pv, V.Route, 29)
			Violations.record(p, pv, V.Route, 29)
			Violations.tick(p, pv, 30)
			expect(warned[1]).toBe(C.PREFIX .. "uid=9 last 30s: violations Route 2 (score 9.0)")
		end)

		it("prints nothing for a quiet window, and windows keep closing every 30 s", function()
			local p, pv = fakePlayer(42), Violations.newPlayer(0)
			Violations.tick(p, pv, 30)
			expect(#warned).toBe(0)
			expect(pv.nextSummary).toBe(60)
			Violations.drop(pv, Drop.Stale, 2)
			Violations.tick(p, pv, 59)
			expect(#warned).toBe(0)
			Violations.tick(p, pv, 60)
			expect(#warned).toBe(1)
			expect(warned[1]).toBe(C.PREFIX .. "uid=42 last 30s: Stale 2 (score 0.0)")
		end)

		it("never logs per drop or per violation", function()
			local p, pv = fakePlayer(5), Violations.newPlayer(0)
			for i = 1, 10000 do
				Violations.drop(pv, (i % C.DROP_KINDS) + 1, 1)
			end
			for i = 0, 1799 do -- 60 ticks per second for 30 s, with violations in between
				local now = i / 60
				Violations.record(p, pv, (i % #C.ViolationName) + 1, now)
				Violations.tick(p, pv, now)
			end
			expect(#warned).toBe(0)
			expect(Log.suppressed()).toBe(0)
			Violations.tick(p, pv, 30)
			expect(#warned).toBe(1)
		end)

		it("shares the global log budget (10 lines, the rest counted as suppressed)", function()
			for uid = 1, 20 do
				local p, pv = fakePlayer(uid), Violations.newPlayer(0)
				Violations.drop(pv, Drop.FrameDropped, uid)
				Violations.tick(p, pv, 30)
			end
			expect(#warned).toBe(C.Limit.LOG_LINES_PER_MIN)
			expect(Log.suppressed()).toBe(20 - C.Limit.LOG_LINES_PER_MIN)
			logNow = 6.01
			Log.warn("next")
			expect(warned[#warned]).toBe(C.PREFIX .. "next (+10 suppressed)")
		end)

		it("formats with the exact contract text", function()
			local p, pv = fakePlayer(7), Violations.newPlayer(0)
			Violations.drop(pv, Drop.OutboxOverflow, 1)
			Violations.drop(pv, Drop.FrameDropped, 2)
			Violations.record(p, pv, V.Refs, 0)
			Violations.record(p, pv, V.ExtraArgs, 0)
			local text = Violations._test.buildSummary(7, pv, 1.5)
			expect(text).toBe(
				"uid=7 last 30s: FrameDropped 2, OutboxOverflow 1; violations ExtraArgs 1, Refs 1 (score 1.5)"
			)
		end)
	end)
end
