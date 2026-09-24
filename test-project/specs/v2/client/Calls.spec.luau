--!strict
-- 2.0 calls from the client: nil holes, -0, non-finite numbers, typed round trips, big payloads
-- (alone in their frame), PayloadTooLarge, the 20-argument limit, returned Promises, Serial FIFO,
-- per-method Timeout, CancelOnTimeout and zombies (the server side is in specs/v2/server/Dispatch).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Msg = V2.C.Msg

	describe("v2 untyped values", function()
		it("keeps nil holes and trailing nils", function()
			local P = V2.proxy()
			local r = V2.settle(P:Echo(1, nil, 3))
			expect(r[1]).toBe(true)
			expect(r.n).toBe(4)
			expect(r[2]).toBe(1)
			expect(r[3]).toBeNil()
			expect(r[4]).toBe(3)

			r = V2.settle(P:Echo(1, nil))
			expect(r[1]).toBe(true)
			expect(r.n).toBe(3)

			r = V2.settle(P:Echo(nil, nil, nil))
			expect(r[1]).toBe(true)
			expect(r.n).toBe(4)

			r = V2.settle(P:Echo())
			expect(r[1]).toBe(true)
			expect(r.n).toBe(1)
		end)

		it("keeps -0 and exact doubles", function()
			local P = V2.proxy()
			local r = V2.settle(P:Echo(-0, 0.1, 2 ^ 53, -2 ^ 40, 4294967296))
			expect(r[1]).toBe(true)
			expect(1 / r[2]).toBe(-math.huge)
			expect(r[3]).toBe(0.1)
			expect(r[4]).toBe(2 ^ 53)
			expect(r[5]).toBe(-2 ^ 40)
			expect(r[6]).toBe(4294967296)
		end)

		it("round-trips strings, buffers, vectors, colors and nested tables", function()
			local P = V2.proxy()
			local b = buffer.fromstring("\0\1\2\255")
			local nested = { list = { 1, 2, 3 }, map = { a = "x", b = { deep = true } }, empty = {} }
			local r = V2.settle(
				P:Echo("", "héllo", b, Vector3.new(1.5, -2, 3), Vector2.new(4, 5), Color3.new(1, 0, 0.5), nested)
			)
			expect(r[1]).toBe(true)
			expect(r[2]).toBe("")
			expect(r[3]).toBe("héllo")
			expect(typeof(r[4])).toBe("buffer")
			expect(buffer.tostring(r[4])).toBe("\0\1\2\255")
			expect(r[5]).toBe(Vector3.new(1.5, -2, 3))
			expect(r[6]).toBe(Vector2.new(4, 5))
			expect(r[7]).toBe(Color3.new(1, 0, 0.5))
			expect(r[8]).toEqual(nested)
		end)

		it("never lets NaN or infinity reach a handler (BadRequest or BadArgument)", function()
			local P = V2.proxy()
			local values: { any } = { 0 / 0, math.huge, { x = -math.huge } }
			for _, value in values do
				local r = V2.settle(P:Echo(value))
				expect(r[1]).toBe(false)
				local info = r[3]
				expect(info.Code == "BadRequest" or info.Code == "BadArgument").toBe(true)
				expect(info.Arg).toBe(1)
				expect(r[2]).toContain("NonFinite")
			end
		end)
	end)

	describe("v2 typed calls", function()
		it("round-trips typed arguments and returns", function()
			local P = V2.proxy()
			local r = V2.settle(P:TypedEcho("héllo", 200, Vector3.new(1.5, -2, 3)))
			expect(r[1]).toBe(true)
			expect(r.n).toBe(4)
			expect(r[2]).toBe("héllo")
			expect(r[3]).toBe(200)
			expect(r[4]).toBe(Vector3.new(1.5, -2, 3))
		end)

		it("round-trips a typed Instance", function()
			local P = V2.proxy()
			local folder = ReplicatedStorage:WaitForChild("V2Fixture", 10)
			expect(folder).never.toBeNil()
			local part = (folder :: Instance):WaitForChild("Part", 10)
			local r = V2.settle(P:NeedsPart(part, false))
			expect(r[1]).toBe(true)
			expect(rawequal(r[2], part)).toBe(true)
		end)
	end)

	describe("v2 payload sizes", function()
		it("sends a big payload alone while small calls in the same frame still work", function()
			local P = V2.proxy()
			local big = string.rep("a", 60000)
			local pBig = P:Echo(big)
			local pSmall = P:Echo("small")
			local pSmall2 = P:Echo("small", 2)
			local rBig, rSmall, rSmall2 = V2.settle(pBig), V2.settle(pSmall), V2.settle(pSmall2)
			expect(rBig[1]).toBe(true)
			expect(#rBig[2]).toBe(60000)
			expect(rBig[2] == big).toBe(true)
			expect(rSmall[1]).toBe(true)
			expect(rSmall[2]).toBe("small")
			expect(rSmall2[3]).toBe(2)
		end)

		it("receives a reply larger than a server frame (Big)", function()
			local P = V2.proxy()
			local r = V2.settle(P:Big(100000))
			expect(r[1]).toBe(true)
			expect(#r[2]).toBe(100000)
			expect(string.sub(r[2], 1, 3)).toBe("bbb")
		end)

		it("rejects a message over 64 KiB at once with PayloadTooLarge", function()
			local P = V2.proxy()
			local promise = P:Echo(string.rep("x", 70000))
			expect(V2.rejectedNow(promise)).toBe(true)
			local message = V2.rejection(expect, V2.settle(promise), "PayloadTooLarge", "Echo")
			expect(message).toBe(Msg.PayloadTooLarge)
		end)

		it("accepts 20 arguments and rejects 21 with BadArgument", function()
			local P = V2.proxy()
			local args = table.create(21, 7)
			local ok = V2.settle(P:Echo(table.unpack(args, 1, 20)))
			expect(ok[1]).toBe(true)
			expect(ok.n).toBe(21)
			local promise = P:Echo(table.unpack(args, 1, 21))
			expect(V2.rejectedNow(promise)).toBe(true)
			local message = V2.rejection(expect, V2.settle(promise), "BadArgument", "Echo")
			expect(string.sub(message, 1, #Msg.BadArgument)).toBe(Msg.BadArgument)
			expect(message).toContain("TooManyArgs")
		end)

		it("rejects a cyclic table with BadArgument", function()
			local P = V2.proxy()
			local cyclic: any = {}
			cyclic.self = cyclic
			local promise = P:Echo(cyclic)
			expect(V2.rejectedNow(promise)).toBe(true)
			local message = V2.rejection(expect, V2.settle(promise), "BadArgument", "Echo")
			expect(message).toContain("Cycle")
		end)
	end)

	describe("v2 handler results", function()
		it("a yielding handler resolves after it returns", function()
			local P = V2.proxy()
			local started = os.clock()
			local r = V2.settle(P:Slow(0.3))
			expect(r[1]).toBe(true)
			expect(r[2]).toBe(0.3)
			expect(os.clock() - started).toBeGreaterThanOrEqual(0.25)
		end)

		it("a returned Promise is awaited: its value is the reply", function()
			local P = V2.proxy()
			local r = V2.settle(P:ReturnPromise({ answer = 42 }))
			expect(r[1]).toBe(true)
			expect(r[2]).toEqual({ answer = 42 })
		end)

		it("a returned Promise rejecting with Loren.Reject is Rejected with its data", function()
			local P = V2.proxy()
			local message, info = V2.rejection(expect, V2.settle(P:ReturnPromise(9, true)), "Rejected", "ReturnPromise")
			expect(message).toBe(V2.Texts.PromiseRejected)
			expect(info.Data).toBe(9)
		end)

		it("runs Serial calls one at a time in call order", function()
			local P = V2.proxy()
			local promises = {}
			for i = 1, 8 do
				promises[i] = V2.hold(P:SerialAdd(i))
			end
			local results = {}
			for i = 1, 8 do
				local r = V2.settle(promises[i])
				expect(r[1]).toBe(true)
				results[i] = r[2]
			end
			for i = 2, 8 do
				expect(results[i] - results[i - 1]).toBe(i)
			end
		end)
	end)

	describe("v2 timeouts", function()
		it("uses the per-method Timeout (Hang: 2 s) and the exact 1.5.1 string", function()
			local P = V2.proxy()
			local started = os.clock()
			local message = V2.rejection(expect, V2.settle(P:Hang()), "Timeout", "Hang")
			local elapsed = os.clock() - started
			expect(message).toBe("(LORENঌ) Timeout")
			expect(elapsed).toBeGreaterThanOrEqual(1.8)
			expect(elapsed).toBeLessThan(4)
		end)

		it("times out a CancelOnTimeout call (Slow: 3 s); the server cancels it later", function()
			local P = V2.proxy()
			local started = os.clock()
			V2.rejection(expect, V2.settle(P:Slow(12)), "Timeout", "Slow")
			local elapsed = os.clock() - started
			expect(elapsed).toBeGreaterThanOrEqual(2.8)
			expect(elapsed).toBeLessThan(5)
		end)

		it("abandoned calls become zombies: their route answers Busy, other routes still run", function()
			local P = V2.proxy()
			local first = {}
			for i = 1, 5 do
				first[i] = V2.hold(P:Hang())
			end
			for i = 1, 5 do
				local r = V2.settle(first[i])
				expect(r[1]).toBe(false)
				local code = r[3].Code
				expect(code == "Timeout" or code == "Busy").toBe(true)
			end
			-- The server abandons them at receipt + 2 (Timeout) + 5 (WatchdogGrace); they stay zombies
			-- until Hang returns at 12 s. Now is ~8.5 s after the calls.
			task.wait(6.5)
			local message = V2.rejection(expect, V2.settle(P:Hang()), "Busy", "Hang")
			expect(message).toBe(Msg.Busy)
			local r = V2.settle(P:Echo("still running"))
			expect(r[1]).toBe(true)
			expect(r[2]).toBe("still running")
			-- Let the zombies end (12 s after the calls), so later Hang calls time out instead of Busy.
			task.wait(4)
		end, { timeout = 30 })
	end)
end
