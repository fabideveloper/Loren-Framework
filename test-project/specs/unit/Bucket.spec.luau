--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bucket = require(ReplicatedStorage.LorenRuntime.Bucket)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("module", function()
		it("is frozen and exports new/take/can/put", function()
			expect(table.isfrozen(Bucket)).toBe(true)
			expect(type(Bucket.new)).toBe("function")
			expect(type(Bucket.take)).toBe("function")
			expect(type(Bucket.can)).toBe("function")
			expect(type(Bucket.put)).toBe("function")
		end)
	end)

	describe("new", function()
		it("starts full, stamped at now", function()
			local b = Bucket.new(10, 5, 100)
			expect(b.tokens).toBe(5)
			expect(b.stamp).toBe(100)
			expect(b.rate).toBe(10)
			expect(b.burst).toBe(5)
		end)

		it("is a uniform record with exactly four fields", function()
			local b = Bucket.new(1, 1, 0)
			local keys = {}
			for k in b :: any do
				table.insert(keys, k)
			end
			table.sort(keys)
			expect(keys).toEqual({ "burst", "rate", "stamp", "tokens" })
		end)
	end)

	describe("take", function()
		it("takes while tokens last, then refuses", function()
			local b = Bucket.new(10, 3, 0)
			expect(Bucket.take(b, 1, 0)).toBe(true)
			expect(Bucket.take(b, 1, 0)).toBe(true)
			expect(Bucket.take(b, 1, 0)).toBe(true)
			expect(Bucket.take(b, 1, 0)).toBe(false)
			expect(b.tokens).toBe(0)
		end)

		it("refills with elapsed time at the rate", function()
			local b = Bucket.new(10, 3, 0)
			for _ = 1, 3 do
				Bucket.take(b, 1, 0)
			end
			expect(Bucket.take(b, 1, 0.05)).toBe(false) -- 0.5 token
			expect(b.tokens).toBeCloseTo(0.5, 9)
			expect(Bucket.take(b, 1, 0.1001)).toBe(true) -- 1.001 tokens
			expect(b.tokens).toBeCloseTo(0.001, 9)
			expect(b.stamp).toBe(0.1001)
		end)

		it("never refills beyond burst", function()
			local b = Bucket.new(1000, 4, 0)
			Bucket.take(b, 4, 0)
			expect(Bucket.take(b, 1, 1e6)).toBe(true)
			expect(b.tokens).toBe(3)
		end)

		it("supports fractional rates", function()
			local b = Bucket.new(10 / 60, 10, 0) -- 10 per minute
			expect(Bucket.take(b, 10, 0)).toBe(true)
			expect(Bucket.take(b, 1, 5.9)).toBe(false)
			expect(b.tokens).toBeCloseTo(5.9 / 6, 9)
			expect(Bucket.take(b, 1, 6.01)).toBe(true)
			expect(b.tokens).toBeCloseTo(0.01 / 6, 9)
		end)

		it("charges costs larger than 1 (bytes, message counts)", function()
			local b = Bucket.new(100, 100, 0)
			expect(Bucket.take(b, 60, 0)).toBe(true)
			expect(Bucket.take(b, 60, 0)).toBe(false)
			expect(b.tokens).toBe(40)
			expect(Bucket.take(b, 60, 0.21)).toBe(true) -- 40 + 21
			expect(b.tokens).toBeCloseTo(1, 9)
		end)

		it("takes exactly the remaining tokens (>=, not >)", function()
			local b = Bucket.new(1, 64, 0)
			expect(Bucket.take(b, 64, 0)).toBe(true)
			expect(b.tokens).toBe(0)
		end)

		it("stores the refilled tokens and the stamp even when it refuses", function()
			local b = Bucket.new(2, 10, 0)
			Bucket.take(b, 10, 0)
			expect(Bucket.take(b, 5, 1)).toBe(false)
			expect(b.tokens).toBe(2)
			expect(b.stamp).toBe(1)
			expect(Bucket.take(b, 5, 2)).toBe(false)
			expect(b.tokens).toBe(4) -- refilled from the stored 2, not from 0
		end)

		it("never admits a cost above burst", function()
			local b = Bucket.new(1e9, 100, 0)
			expect(Bucket.take(b, 101, 0)).toBe(false)
			expect(Bucket.take(b, 101, 1e6)).toBe(false)
			expect(b.tokens).toBe(100)
		end)

		it("a now older than the stamp refills nothing and keeps the stamp", function()
			local b = Bucket.new(10, 10, 5)
			Bucket.take(b, 10, 5)
			expect(Bucket.take(b, 1, 4)).toBe(false)
			expect(b.tokens).toBe(0)
			expect(b.stamp).toBe(5)
			expect(Bucket.take(b, 1, 5.1001)).toBe(true)
		end)

		it("a zero cost always passes and changes nothing", function()
			local b = Bucket.new(1, 1, 0)
			Bucket.take(b, 1, 0)
			expect(Bucket.take(b, 0, 0)).toBe(true)
			expect(b.tokens).toBe(0)
		end)
	end)

	describe("can", function()
		it("refills and compares without taking", function()
			local b = Bucket.new(10, 10, 0)
			Bucket.take(b, 10, 0)
			expect(Bucket.can(b, 1, 0.05)).toBe(false)
			expect(b.tokens).toBeCloseTo(0.5, 9)
			expect(b.stamp).toBe(0.05)
			expect(Bucket.can(b, 1, 0.1001)).toBe(true)
			expect(Bucket.can(b, 1, 0.1001)).toBe(true)
			expect(b.tokens).toBeCloseTo(1.001, 9)
		end)

		it("agrees with take on the same inputs", function()
			local rng = Random.new(1234)
			local a = Bucket.new(37, 50, 0)
			local b = Bucket.new(37, 50, 0)
			local now = 0
			for _ = 1, 5000 do
				now += rng:NextNumber(0, 0.05)
				local cost = rng:NextInteger(1, 20)
				local canTake = Bucket.can(a, cost, now)
				if canTake then
					a.tokens -= cost
				end
				expect(Bucket.take(b, cost, now)).toBe(canTake)
				expect(a.tokens).toBe(b.tokens)
			end
		end)
	end)

	describe("put", function()
		it("refunds and caps at burst", function()
			local b = Bucket.new(1, 10, 0)
			Bucket.take(b, 8, 0)
			Bucket.put(b, 3)
			expect(b.tokens).toBe(5)
			Bucket.put(b, 100)
			expect(b.tokens).toBe(10)
		end)
	end)

	describe("steady state", function()
		it("admits burst + rate * duration over a long run", function()
			local rate, burst = 50, 100
			local b = Bucket.new(rate, burst, 0)
			local taken = 0
			local steps = 240 * 10
			for i = 0, steps do
				local now = i / 240
				while Bucket.take(b, 1, now) do
					taken += 1
				end
			end
			-- 100 at t = 0, then 50/s for 10 s
			expect(taken).toBeGreaterThanOrEqual(burst + rate * 10 - 1)
			expect(taken).toBeLessThanOrEqual(burst + rate * 10)
		end)

		it("has no boundary double-burst (unlike a fixed window)", function()
			local b = Bucket.new(50, 50, 0)
			local taken = 0
			-- drain at the end of one second and the start of the next
			for _, now in { 0.999, 1.0, 1.001 } do
				while Bucket.take(b, 1, now) do
					taken += 1
				end
			end
			expect(taken).toBeLessThanOrEqual(50 + 1)
		end)
	end)
end
