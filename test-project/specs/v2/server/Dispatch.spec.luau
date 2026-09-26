--!strict
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }

	local function errorsFor(member: string): { any }
		local out = {}
		for _, info in V2.probe().errors do
			if info.Service == "V2Service" and info.Member == member then
				table.insert(out, info)
			end
		end
		return out
	end

	describe("v2 OnError", function()
		it("rejects a non-function handler", function()
			local Loren = V2.loren()
			expect(function()
				Loren.OnError(5)
			end).toThrow("function")
		end)
	end)

	describe("v2 dispatch (driven by specs/v2/client)", function()
		it("awaits a returned Promise before replying", function()
			local probe = V2.probe()
			V2.await("a settled ReturnPromise call", function()
				return probe.promiseSettled > 0
			end)
			expect(V2.count(probe.handler, "ReturnPromise")).toBeGreaterThanOrEqual(probe.promiseSettled)
		end, evidence)

		it("runs RejectMe (Loren.Reject returned and thrown)", function()
			local probe = V2.probe()
			V2.await("a RejectMe call", function()
				return V2.count(probe.handler, "RejectMe") > 0
			end)
			-- A Reject is an answer, not a failure: it never reaches OnError.
			expect(#errorsFor("RejectMe")).toBe(0)
		end, evidence)

		it("reports a handler error to OnError with an incident id and a traceback", function()
			V2.await("a Boom call reported to OnError", function()
				return #errorsFor("Boom") > 0
			end)
			local info = errorsFor("Boom")[1]
			local texts = V2.service().Texts
			expect(table.isfrozen(info)).toBe(true)
			expect(typeof(info.Player)).toBe("Instance")
			expect(info.Player:IsA("Player")).toBe(true)
			expect(typeof(info.Incident)).toBe("string")
			expect(string.match(info.Incident, V2.HEX8)).never.toBeNil()
			expect(info.Message).toContain(texts.Boom)
			expect(typeof(info.Traceback)).toBe("string")
		end, evidence)

		it("logs a handler error with its incident id", function()
			local found: string? = nil
			V2.await("a logged Boom incident", function()
				for _, info in errorsFor("Boom") do
					found = V2.logLine("V2Service.Boom", "[" .. info.Incident .. "]")
					if found then
						return true
					end
				end
				return false
			end)
			expect(found).toContain(V2.service().Texts.Boom)
		end, evidence)

		it("keeps at most MaxRunningCalls yielded calls per player and answers the rest Busy", function()
			local probe = V2.probe()
			local Loren = V2.loren()
			V2.await("a Busy reply (the clients' Busy test)", function()
				return Loren.GetStats().Busy > 0
			end)
			expect(probe.slowActiveMax).toBeGreaterThan(0)
			expect(probe.slowActiveMax).toBeLessThanOrEqual(32) -- C.Default.MaxRunningCalls
			expect(probe.slowRunningSeen).toBeGreaterThan(0)
		end, evidence)

		it("runs Serial calls of a player one at a time", function()
			local probe = V2.probe()
			V2.await("a few SerialAdd calls", function()
				return probe.serialCalls >= 4
			end)
			expect(probe.serialOverlap).toBe(0)
		end, evidence)

		it("abandons a call past timeout + WatchdogGrace: it stays a zombie until it ends", function()
			local probe = V2.probe()
			V2.await("a Hang call that ended after being abandoned", function()
				return probe.hangEnded > 0
			end)
			expect(probe.hangZombiesSeen).toBeGreaterThanOrEqual(1)
		end, evidence)

		it("cancels a CancelOnTimeout call at timeout + WatchdogGrace (Slow never finishes)", function()
			local probe = V2.probe()
			V2.await("a long Slow call", function()
				return #probe.longSlow > 0
			end)
			-- Wait until every recorded long call would have finished had it not been cancelled.
			local last = 0
			for _, record in probe.longSlow do
				last = math.max(last, record.at + record.seconds + 1)
			end
			V2.await("the long Slow calls' natural end", function()
				return os.clock() >= last
			end, 40)
			for _, record in probe.longSlow do
				expect(record.finished).toBe(false)
			end
		end, evidence)

		it("zombie and running counts drain back to 0", function()
			local Loren = V2.loren()
			V2.await("an ended Hang call", function()
				return V2.probe().hangEnded > 0
			end)
			V2.await("RunningCalls and ZombieCalls back at 0", function()
				local stats = Loren.GetStats()
				return stats.RunningCalls == 0 and stats.ZombieCalls == 0
			end, 60)
		end, evidence)
	end)
end
