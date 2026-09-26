--!strict
-- InventoryService: middleware returning (false, "Invalid") rejects with that message.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Inventory = Env.proxy("InventoryService")

	local function drop(item: any, amount: any): (boolean, any)
		Budget.take(1)
		return Inventory:Drop(item, amount):await()
	end

	describe("InventoryService.Drop", function()
		it("returns the running total per item", function()
			local ok1, first = drop("Sword", 2)
			local ok2, second = drop("Sword", 3)
			expect(ok1).toBe(true)
			expect(ok2).toBe(true)
			expect(second).toBe(first + 3)
		end)

		it("rejects bad input with the middleware's message 'Invalid'", function()
			local cases: { { any } } = {
				{ 123, 1 },
				{ "", 1 },
				{ string.rep("x", 33), 1 },
				{ "Sword", 0 },
				{ "Sword", 100 },
				{ "Sword", -1 },
				{ "Sword", 1.5 },
				{ "Sword", "3" },
				{ true, 1 },
			}
			for _, case in cases do
				local ok, reason = drop(case[1], case[2])
				expect(ok).toBe(false)
				expect(Env.reason(reason)).toContain("Invalid")
			end
			local okNil, reasonNil = drop(nil, 1)
			expect(okNil).toBe(false)
			expect(Env.reason(reasonNil)).toContain("Invalid")
		end)

		it("rejects NaN and infinite amounts", function()
			local okNan = drop("Sword", 0 / 0)
			local okInf = drop("Sword", math.huge)
			expect(okNan).toBe(false)
			expect(okInf).toBe(false)
		end)

		it("does not change the total when a drop is rejected", function()
			local _, before = drop("Shield", 1)
			drop("Shield", 0)
			drop("Shield", 0 / 0)
			local ok, after = drop("Shield", 1)
			expect(ok).toBe(true)
			expect(after).toBe(before + 1)
		end)
	end)
end
