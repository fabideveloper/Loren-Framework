--!strict
-- BroadcastService: Ping, and the Tick signal the server fires at 10/s during "check".
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Broadcast = Env.proxy("BroadcastService")

	describe("BroadcastService", function()
		it("Ping resolves with true", function()
			Budget.take(1)
			local ok, value = Broadcast:Ping():await()
			expect(ok).toBe(true)
			expect(value).toBe(true)
		end)

		-- Strictly increasing overall; the last 8 (live) Ticks consecutive. 2.0 may first replay a
		-- capped backlog of Ticks fired before the first Connect (BLUEPRINT section 4), which can leave
		-- one gap between the replay and the live stream; 1.5.1 simply drops those.
		it("Tick (FireAll) arrives in index order, live Ticks without gaps", function()
			local seen: { { index: any, clock: any, serverTime: any } } = {}
			local connection = Broadcast.Signals.Tick:Connect(function(index: any, clock: any, serverTime: any)
				table.insert(seen, { index = index, clock = clock, serverTime = serverTime })
			end)
			task.wait(1.2)
			local enough = Env.waitUntil(function()
				return #seen >= 8
			end, 6)
			connection:Disconnect()
			expect(enough).toBe(true)
			expect(typeof(seen[1].index)).toBe("number")
			expect(typeof(seen[1].clock)).toBe("number")
			for k = 2, #seen do
				expect(seen[k].index).toBeGreaterThan(seen[k - 1].index)
			end
			for k = #seen - 6, #seen do
				expect(seen[k].index).toBe(seen[k - 1].index + 1)
			end
		end)
	end)
end
