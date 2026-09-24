--!strict
-- CounterService: return values, DOT middleware denials, and the Changed signal (order, Once, Disconnect).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Counter = Env.proxy("CounterService")
	local Dependent = Env.proxy("DependentService")

	-- The server-side count, read through DependentService.Total.
	local function total(): number
		Budget.take(1)
		local ok, value = Dependent:Total():await()
		assert(ok, "Total() failed: " .. Env.reason(value))
		return value
	end

	local function increment(n: any): (boolean, any)
		Budget.take(1)
		return Counter:Increment(n):await()
	end

	describe("CounterService.Increment", function()
		it("returns the new count and fires Changed with it", function()
			local received = {}
			local connection = Counter.Signals.Changed:Connect(function(value)
				table.insert(received, value)
			end)
			local before = total()
			local ok, value = increment(5)
			local arrived = Env.waitUntil(function()
				return table.find(received, value) ~= nil
			end, 3)
			connection:Disconnect()
			expect(ok).toBe(true)
			expect(value).toBe(before + 5)
			expect(arrived).toBe(true)
		end)

		it("denies 0, 101 and -1 with the message 'Denied'", function()
			for _, bad in { 0, 101, -1 } do
				local ok, reason = increment(bad)
				expect(ok).toBe(false)
				expect(Env.reason(reason)).toContain("Denied")
			end
		end)

		it("rejects NaN, +-inf, strings, tables, booleans and nil", function()
			local bad: { any } = { 0 / 0, math.huge, -math.huge, "5", {}, true }
			for _, value in bad do
				local ok = increment(value)
				expect(ok).toBe(false)
			end
			local okNil = increment(nil)
			expect(okNil).toBe(false)
		end)

		it("does not change the count when a call is denied", function()
			local before = total()
			increment(0)
			increment(0 / 0)
			increment("10")
			expect(total()).toBe(before)
		end)
	end)

	describe("CounterService.Signals.Changed", function()
		it("arrives in order for concurrent increments", function()
			local received = {}
			local connection = Counter.Signals.Changed:Connect(function(value)
				table.insert(received, value)
			end)
			local before = total()
			Budget.take(10)
			local promises = {}
			for i = 1, 10 do
				promises[i] = Counter:Increment(1)
			end
			local values = {}
			for _, promise in promises do
				local ok, value = promise:await()
				expect(ok).toBe(true)
				table.insert(values, value)
			end
			local allArrived = Env.waitUntil(function()
				return #received >= 10
			end, 3)
			connection:Disconnect()
			expect(allArrived).toBe(true)
			for i = 1, 10 do
				expect(received[i]).toBe(before + i)
			end
			table.sort(values)
			for i = 1, 10 do
				expect(values[i]).toBe(before + i)
			end
		end)

		it("Once runs its listener a single time", function()
			local count = 0
			Counter.Signals.Changed:Once(function()
				count += 1
			end)
			increment(1)
			increment(1)
			task.wait(0.3)
			expect(count).toBe(1)
		end)

		it("Disconnect stops delivery", function()
			local count = 0
			local connection = Counter.Signals.Changed:Connect(function()
				count += 1
			end)
			increment(1)
			expect(Env.waitUntil(function()
				return count == 1
			end, 3)).toBe(true)
			connection:Disconnect()
			increment(1)
			task.wait(0.3)
			expect(count).toBe(1)
		end)
	end)
end
