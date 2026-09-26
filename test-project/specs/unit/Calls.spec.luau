--!strict
-- Calls (client-net): ids, quarantine, sweeper, Promise/Try settlement, fan-outs. Runs on the server.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Calls = require(Runtime:WaitForChild("Calls")) :: any

local TIMEOUT_MSG = "(LORENঌ) Timeout"
local QC = C.Limit.QUARANTINE_AFTER_CANCEL -- 60
local QD = C.Limit.QUARANTINE_AFTER_DEADLINE -- 40: past receipt + timeout + WatchdogGrace (max 30)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach = t.beforeAll, t.afterAll, t.beforeEach

	local now = 0
	local function clock(): number
		return now
	end

	local function route(timeout: number?): any
		return { service = "Svc", member = "M", timeout = timeout or 10 }
	end

	-- A pending call that is already "sent" in reliable frame `seq` at `at`.
	local function sent(r: any, seq: number, at: number): any
		local req = Calls.alloc(r, at)
		Calls.fired(req.id, seq, at)
		return req
	end

	local function silence(p: any)
		p:catch(function() end)
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		Calls._reset()
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Calls._reset()
		now = 100
		Calls._test.setClock(clock)
		Calls.configure(256)
	end)

	describe("ids", function()
		it("hands out ids round-robin from 1", function()
			local a = Calls.alloc(route(), now)
			local b = Calls.alloc(route(), now)
			local c = Calls.alloc(route(), now)
			expect(a.id).toBe(1)
			expect(b.id).toBe(2)
			expect(c.id).toBe(3)
			Calls.resolve(b)
			-- round-robin continues past the freed id instead of reusing it at once
			expect(Calls.alloc(route(), now).id).toBe(4)
		end)

		it("wraps at 65535 and skips live ids", function()
			Calls._test.setNextId(0)
			local one = Calls.alloc(route(), now)
			expect(one.id).toBe(1)
			Calls._test.setNextId(65534)
			expect(Calls.alloc(route(), now).id).toBe(65535)
			-- 1 is still pending, so the wrap lands on 2
			expect(Calls.alloc(route(), now).id).toBe(2)
		end)

		it("skips quarantined ids", function()
			local r = route()
			local req = sent(r, 0, now)
			local p = Calls.promise(req)
			p:cancel()
			expect(Calls._test.record(1).state).toBe("quarantined")
			Calls._test.setNextId(0)
			expect(Calls.alloc(r, now).id).toBe(2)
		end)

		it("refuses past the pending cap (TooManyInFlight is decided by the caller)", function()
			Calls.configure(2)
			expect(Calls.canAlloc()).toBe(true)
			Calls.alloc(route(), now)
			Calls.alloc(route(), now)
			expect(Calls.canAlloc()).toBe(false)
			expect(Calls.alloc(route(), now)).toBeNil()
			expect(Calls.pending()).toBe(2)
		end)
	end)

	describe("timeouts and quarantine", function()
		it("rejects an expired call with the exact 1.5.1 Timeout string and (message, info)", function()
			local req = sent(route(10), 0, now)
			local p = Calls.promise(req)
			Calls._test.sweepNow(now + 9.99)
			expect(p:getStatus()).toBe("Started")
			Calls._test.sweepNow(now + 10)
			local ok, message, info = p:await()
			expect(ok).toBe(false)
			expect(message).toBe(TIMEOUT_MSG)
			expect(info.Code).toBe("Timeout")
			expect(info.CodeId).toBe(C.Err.Timeout)
			expect(info.Service).toBe("Svc")
			expect(info.Member).toBe("M")
			expect(info.Message).toBe(TIMEOUT_MSG)
			expect(table.isfrozen(info)).toBe(true)
			expect(Calls.pending()).toBe(0)
			expect(Calls.timeouts()).toBe(1)
		end)

		it("resumes a parked Try caller with (false, Timeout, info) from the sweeper", function()
			local result: any = nil
			local req = sent(route(5), 0, 100)
			local id = req.id
			task.spawn(function()
				result = table.pack(Calls.park(req))
			end)
			expect(result).toBeNil()
			Calls._test.sweepNow(104.9)
			expect(result).toBeNil()
			Calls._test.sweepNow(105)
			expect(result).never.toBeNil()
			expect(result.n).toBe(3)
			expect(result[1]).toBe(false)
			expect(result[2]).toBe(TIMEOUT_MSG)
			expect(result[3].Code).toBe("Timeout")
			expect(result[3].Message).toBe(TIMEOUT_MSG)
			expect(Calls._test.record(id).state).toBe("quarantined")
			expect(Calls._test.record(id).qUntil).toBe(105 + QC) -- max(105 + 60, 100 + 5 + 40)
		end)

		it("skips a Try caller whose thread was cancelled", function()
			local req = sent(route(5), 0, 100)
			local th = task.spawn(function()
				Calls.park(req)
			end)
			task.cancel(th)
			Calls.resolve(req, 1) -- must not throw
			expect(Calls.pending()).toBe(0)
			expect(Calls._test.held()).toBe(0)
		end)

		it("quarantines until max(cancel + 60, send + timeout + 40)", function()
			expect(QC).toBe(60)
			expect(QD).toBe(40)
			expect(QD >= C.Limit.WATCHDOG_GRACE_MAX + 10).toBe(true)
			-- short timeout: the cancel bound wins
			local a = sent(route(10), 0, 100)
			local pa = Calls.promise(a)
			now = 102
			pa:cancel()
			expect(Calls._test.record(a.id).qUntil).toBe(102 + QC)
			-- long timeout: the deadline bound wins
			local b = sent(route(100), 1, 100)
			local pb = Calls.promise(b)
			pb:cancel()
			expect(Calls._test.record(b.id).qUntil).toBe(100 + 100 + QD)
			-- a timeout quarantines the same way
			local c = sent(route(10), 2, 100)
			silence(Calls.promise(c))
			Calls._test.sweepNow(110)
			expect(Calls._test.record(c.id).qUntil).toBe(110 + QC)
		end)

		it("decides the quarantine end of an unsent call when its frame fires", function()
			local r = route(100)
			local req = Calls.alloc(r, 100)
			local p = Calls.promise(req)
			now = 102
			p:cancel()
			expect(Calls._test.record(req.id).qUntil).toBe(math.huge)
			Calls._test.sweepNow(1e6) -- never freed while unsent
			expect(Calls._test.record(req.id)).never.toBeNil()
			Calls.fired(req.id, 7, 105)
			expect(Calls._test.record(req.id).qUntil).toBe(105 + 100 + QD) -- max(162, 105 + 100 + 40)
		end)

		it("frees a quarantined id exactly at its end", function()
			local req = sent(route(10), 0, 100)
			local p = Calls.promise(req)
			p:cancel() -- qUntil = 160
			Calls._test.sweepNow(159.99)
			expect(Calls._test.held()).toBe(1)
			Calls._test.sweepNow(160)
			expect(Calls._test.held()).toBe(0)
		end)

		it("counts a late reply and frees its id early", function()
			local req = sent(route(10), 0, 100)
			silence(Calls.promise(req))
			Calls._test.sweepNow(110)
			local rec = Calls.lookup(req.id)
			expect(rec).never.toBeNil()
			expect(Calls.isPending(rec)).toBe(false)
			expect(rec.route.member).toBe("M") -- the route is kept to decode the late reply
			Calls.late(rec)
			expect(Calls.lateReplies()).toBe(1)
			expect(Calls.lookup(req.id)).toBeNil()
		end)

		it("runs rejection handlers after the sweep, so they can start new calls", function()
			local started: any = nil
			local req = sent(route(10), 0, 100)
			Calls.promise(req):catch(function()
				started = Calls.alloc(route(10), 111)
			end)
			Calls._test.sweepNow(110)
			expect(started).never.toBeNil()
			expect(Calls.isPending(started)).toBe(true)
		end)

		it("keeps a batch intact when a settle starts another one (failAll inside a Timeout handler)", function()
			local a = sent(route(10), 0, 100)
			local b = sent(route(10), 1, 100)
			local c = sent(route(100), 2, 100)
			local failed = false
			local function onReject()
				if not failed then
					failed = true
					Calls.failAll() -- e.g. an Ignite awaiting this call throws and the boot fails
				end
			end
			local pa, pb, pc = Calls.promise(a), Calls.promise(b), Calls.promise(c)
			pa:catch(onReject)
			pb:catch(onReject)
			silence(pc)
			expect(function()
				Calls._test.sweepNow(110)
			end).never.toThrow()
			local _, ma = pa:await()
			local _, mb = pb:await()
			local _, mc = pc:await()
			-- the first expired call settles Timeout; the nested failAll rejects everything still pending
			expect(ma == TIMEOUT_MSG or mb == TIMEOUT_MSG).toBe(true)
			expect(ma == "(LORENঌ) BootFailed" or mb == "(LORENঌ) BootFailed").toBe(true)
			expect(mc).toBe("(LORENঌ) BootFailed")
			expect(Calls.timeouts()).toBe(1)
			expect(Calls.pending()).toBe(0)
			expect(Calls._test.held()).toBe(0)
		end)
	end)

	describe("settling", function()
		it("resolves a Promise with every value, nil holes included", function()
			local req = sent(route(), 0, now)
			local p = Calls.promise(req)
			Calls.resolve(req, 1, nil, 3)
			local r = table.pack(p:await())
			expect(r.n).toBe(4)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(1)
			expect(r[3]).toBeNil()
			expect(r[4]).toBe(3)
			expect(Calls._test.held()).toBe(0)
		end)

		it("resumes a Try caller with (true, ...) and (false, message, info)", function()
			local okResult: any, errResult: any = nil, nil
			local a = sent(route(), 0, now)
			task.spawn(function()
				okResult = table.pack(Calls.park(a))
			end)
			local b = sent(route(), 0, now)
			task.spawn(function()
				errResult = table.pack(Calls.park(b))
			end)
			expect(okResult).toBeNil()
			Calls.resolve(a, "x", nil)
			expect(okResult.n).toBe(3)
			expect(okResult[1]).toBe(true)
			expect(okResult[2]).toBe("x")
			Calls.reject(b, C.Err.Rejected, "nope", { reason = 1 }, nil, nil)
			expect(errResult[1]).toBe(false)
			expect(errResult[2]).toBe("nope")
			expect(errResult[3].Code).toBe("Rejected")
			expect(errResult[3].Data.reason).toBe(1)
		end)

		it("ignores a second settle of the same call", function()
			local req = sent(route(), 0, now)
			local p = Calls.promise(req)
			Calls.resolve(req, 1)
			Calls.reject(req, C.Err.Busy, nil, nil, nil, nil)
			local ok, v = p:await()
			expect(ok).toBe(true)
			expect(v).toBe(1)
		end)

		it("quarantines on Promise:cancel() and frees the pending slot", function()
			local req = sent(route(), 0, now)
			local p = Calls.promise(req)
			expect(Calls.pending()).toBe(1)
			p:cancel()
			expect(Calls.pending()).toBe(0)
			expect(Calls._test.record(req.id).state).toBe("quarantined")
		end)

		it("binds the executor synchronously (the record holds the promise's resolve)", function()
			local req = sent(route(), 0, now)
			local p = Calls.promise(req)
			expect(p:getStatus()).toBe("Started")
			expect(type(req.resolve)).toBe("function")
			expect(type(req.reject)).toBe("function")
			Calls.resolve(req, "ok")
			expect(p:getStatus()).toBe("Resolved")
		end)

		it("gives an already-rejected Promise for local rejections", function()
			local p = Calls.rejected("(LORENঌ) RateLimited", table.freeze({ Code = "RateLimited" }))
			local ok, message, info = p:await()
			expect(ok).toBe(false)
			expect(message).toBe("(LORENঌ) RateLimited")
			expect(info.Code).toBe("RateLimited")
		end)
	end)

	describe("fan-outs", function()
		it("rejects the calls of FrameDropped runs RateLimited, wrap-aware", function()
			local r = route()
			local seqs = { 65534, 65535, 0, 1, 5 }
			local promises: { any } = {}
			for i, s in seqs do
				promises[i] = Calls.promise(sent(r, s, now))
				silence(promises[i])
			end
			expect(Calls.dropped(65535, 3)).toBe(3)
			local expected = { "Started", "Rejected", "Rejected", "Rejected", "Started" }
			for i, p in promises do
				expect(p:getStatus()).toBe(expected[i])
			end
			local _, message, info = promises[2]:await()
			expect(message).toBe("(LORENঌ) RateLimited")
			expect(info.Code).toBe("RateLimited")
			-- unsent calls (seq -1) are never matched
			local unsentReq = Calls.alloc(r, now)
			local pu = Calls.promise(unsentReq)
			expect(Calls.dropped(0, 65535)).toBe(2) -- seqs 65534 and 5 (65535 - 65534 < 65535)
			expect(pu:getStatus()).toBe("Started")
			silence(pu)
		end)

		it("rejects a frame that could not be fired BadArgument and frees its ids", function()
			local req = Calls.alloc(route(), now)
			local p = Calls.promise(req)
			Calls.fireFailed(req.id)
			local ok, message, info = p:await()
			expect(ok).toBe(false)
			expect(message).toBe("(LORENঌ) BadArgument (Unserializable)")
			expect(info.Code).toBe("BadArgument")
			expect(Calls._test.held()).toBe(0)
		end)

		it("rejects every pending call BootFailed and drops quarantined ids", function()
			local r = route()
			local p1 = Calls.promise(sent(r, 0, now))
			local p2 = Calls.promise(sent(r, 1, now))
			local tryResult: any = nil
			local tr = sent(r, 2, now)
			task.spawn(function()
				tryResult = table.pack(Calls.park(tr))
			end)
			local q = Calls.promise(sent(r, 3, now))
			q:cancel()
			expect(Calls._test.held()).toBe(4)
			Calls.failAll()
			for _, p in { p1, p2 } do
				local ok, message, info = p:await()
				expect(ok).toBe(false)
				expect(message).toBe("(LORENঌ) BootFailed")
				expect(info.Code).toBe("BootFailed")
			end
			expect(tryResult[1]).toBe(false)
			expect(tryResult[2]).toBe("(LORENঌ) BootFailed")
			expect(Calls._test.held()).toBe(0)
			expect(Calls.pending()).toBe(0)
		end)
	end)
end
