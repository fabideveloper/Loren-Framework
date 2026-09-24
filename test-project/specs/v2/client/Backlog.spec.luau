--!strict
-- 2.0 client Signal backlog: the server fires BootSignal before anyone listens (LorenBurn, or on
-- join); V2Controller connects late and gets it exactly once; the backlog is never re-armed.
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("v2 backlog", function()
		it("the late listener (V2Controller) got BootSignal exactly once", function()
			local probe = V2.controller().Probe
			expect(V2.waitUntil(function()
				return probe.connectedAt ~= nil
			end, 10)).toBe(true)
			expect(probe.connectError).toBeNil()
			expect(V2.waitUntil(function()
				return #probe.boot > 0
			end, 5)).toBe(true)
			task.wait(0.5) -- a duplicate replay or a second fire would land by now
			expect(#probe.boot).toBe(1)
			local delivery = probe.boot[1]
			expect(delivery.kind == "burn" or delivery.kind == "join").toBe(true)
			expect(typeof(delivery.n)).toBe("number")
		end, { timeout = 20 })

		it("a later Connect gets no replay (the backlog was consumed)", function()
			local boot = V2.proxy().Signals.BootSignal
			local got = V2.collect(boot)
			local once = 0
			local onceConnection = boot:Once(function()
				once += 1
			end)
			task.wait(0.5)
			got.stop()
			onceConnection:Disconnect()
			expect(#got.list).toBe(0)
			expect(once).toBe(0)
		end)

		it("the delivery reached the late listener only once it had connected", function()
			local probe = V2.controller().Probe
			expect(#probe.boot).toBeGreaterThan(0)
			expect(probe.boot[1].at >= (probe.connectedAt :: number)).toBe(true)
		end)
	end)
end
