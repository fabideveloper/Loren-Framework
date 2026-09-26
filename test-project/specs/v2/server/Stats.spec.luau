--!strict
local Players = game:GetService("Players")

local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }

	local COUNTERS = {
		"FramesIn",
		"FramesOut",
		"BytesIn",
		"BytesOut",
		"MessagesIn",
		"MessagesOut",
		"FramesDropped",
		"EventsLost",
		"CallsRateLimited",
		"BadRequests",
		"Busy",
		"Violations",
		"LateReplies",
		"OutboxDropped",
		"SignalsDropped",
		"RunningCalls",
		"ZombieCalls",
		"PendingCalls",
		"Players",
		"Routes",
	}

	describe("v2 GetStats (server)", function()
		it("returns every field: Side and non-negative integer counters", function()
			local stats = V2.loren().GetStats()
			expect(stats.Side).toBe("Server")
			for _, key in COUNTERS do
				local value = stats[key]
				expect(typeof(value)).toBe("number")
				expect(value >= 0 and value == math.floor(value)).toBe(true)
			end
		end)

		it("returns a fresh table on every call, in both call forms", function()
			local Loren = V2.loren()
			local a = Loren.GetStats()
			local b = Loren:GetStats()
			expect(rawequal(a, b)).toBe(false)
			a.FramesIn = -1
			expect(Loren.GetStats().FramesIn).never.toBe(-1)
		end)

		it("counts the routes (V2Service alone has 23)", function()
			expect(V2.loren().GetStats().Routes).toBeGreaterThanOrEqual(23)
		end)

		it("a client-only field (PendingCalls) is 0 on the server", function()
			expect(V2.loren().GetStats().PendingCalls).toBe(0)
		end)

		it("counts the players and their traffic", function()
			local Loren = V2.loren()
			V2.await("traffic from the clients", function()
				local stats = Loren.GetStats()
				return stats.FramesIn > 0 and stats.MessagesIn > 0 and stats.BytesIn > 0 and stats.FramesOut > 0
			end)
			V2.await("every player counted", function()
				return Loren.GetStats().Players == #Players:GetPlayers()
			end, 30)
		end, evidence)

		it("honest clients cause no violations and no dropped frames", function()
			local Loren = V2.loren()
			-- After the clients' heaviest v2 tests (TooManyInFlight and Busy run hundreds of calls).
			V2.await("the clients' Busy test", function()
				return Loren.GetStats().Busy > 0
			end)
			local stats = Loren.GetStats()
			expect(stats.Violations).toBe(0)
			expect(stats.FramesDropped).toBe(0)
		end, evidence)
	end)

	describe("v2 OnViolation", function()
		it("takes a function (any time) and rejects anything else", function()
			local Loren = V2.loren()
			Loren.OnViolation(function() end)
			expect(function()
				Loren.OnViolation(5)
			end).toThrow("function")
		end)
	end)
end
