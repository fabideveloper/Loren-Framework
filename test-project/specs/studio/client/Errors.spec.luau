--!strict
-- Failure paths: handler errors, unknown methods, rejection value shape.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Echo = Env.proxy("EchoService")
	local Counter = Env.proxy("CounterService")

	describe("errors", function()
		it("a handler error rejects quickly instead of timing out", function()
			Budget.take(1)
			local started = os.clock()
			local ok = Echo:Size(123):await()
			expect(ok).toBe(false)
			expect(os.clock() - started).toBeLessThan(5)
		end)

		it("an unknown method never resolves (it throws or rejects)", function()
			local called, result = pcall(function()
				return (Echo :: any):NoSuchMethod(1)
			end)
			if called then
				local resolved = result:await()
				expect(resolved).toBe(false)
			end
		end)

		it("a denial rejects with a string as the first value", function()
			Budget.take(1)
			local ok, reason = Counter:Increment(0):await()
			expect(ok).toBe(false)
			expect(typeof(reason)).toBe("string")
		end)
	end)
end
