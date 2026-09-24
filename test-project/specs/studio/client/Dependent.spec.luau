--!strict
-- DependentService reads CounterService through its injected Dependencies.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Counter = Env.proxy("CounterService")
	local Dependent = Env.proxy("DependentService")

	describe("DependentService.Total", function()
		it("returns the CounterService count for the caller", function()
			Budget.take(3)
			local ok1, before = Dependent:Total():await()
			local ok2, value = Counter:Increment(3):await()
			local ok3, after = Dependent:Total():await()
			expect(ok1 and ok2 and ok3).toBe(true)
			expect(value).toBe(before + 3)
			expect(after).toBe(value)
		end)
	end)
end
