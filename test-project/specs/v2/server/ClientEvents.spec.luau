--!strict
-- 2.0 ClientEvents on the server: ServerEvent objects (Connect side only), listener isolation, and
-- the arrivals of the clients' Ping / Aim (unreliable, coalesced) / Seq (unreliable, Ordered).
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local noPlayers = not V2.hasPlayers()
	local evidence = { skip = noPlayers, timeout = V2.TEST_TIMEOUT }

	describe("v2 ServerEvent objects", function()
		it("ClientEvents is a frozen map whose unknown keys raise", function()
			local events = V2.service().ClientEvents
			expect(table.isfrozen(events)).toBe(true)
			expect(function()
				return events.NoSuchEvent
			end).toThrow()
		end)

		it("Fire raises: a ClientEvent goes from client to server only", function()
			local ping = V2.service().ClientEvents.Ping
			expect(function()
				ping:Fire("x")
			end).toThrow()
		end)

		it("Connect returns a connection; Disconnect works with '.' and ':' and is idempotent", function()
			local ping = V2.service().ClientEvents.Ping
			local connection = ping:Connect(function() end)
			expect(connection.Connected).toBe(true)
			connection.Disconnect()
			expect(connection.Connected).toBe(false)
			connection:Disconnect()
			connection.Disconnect()
			expect(connection.Connected).toBe(false)
		end)
	end)

	describe("v2 ClientEvent arrivals (driven by specs/v2/client)", function()
		it("Ping arrives as (player, ...) at every listener", function()
			local probe = V2.probe()
			V2.await("a Ping from a client", function()
				return probe.pings > 0
			end)
			expect(probe.pingBadPlayer).toBe(0)
		end, evidence)

		it("a listener that throws does not stop the listeners connected after it", function()
			local probe = V2.probe()
			V2.await("a Ping 'throw' command", function()
				return probe.thrown > 0 and V2.count(probe.commands, "throw") > 0
			end)
			-- onPing (connected after the throwing listener) counted every "throw" Ping.
			expect(V2.count(probe.commands, "throw")).toBeGreaterThanOrEqual(probe.thrown)
		end, evidence)

		it("Aim (unreliable, coalesced) arrives as a finite Vector3", function()
			local probe = V2.probe()
			V2.await("an Aim from a client", function()
				return probe.aims > 0
			end)
			expect(probe.aimBad).toBe(0)
		end, evidence)

		it("Seq (unreliable, Ordered) never delivers a value older than the last one", function()
			local probe = V2.probe()
			V2.await("a few Seq events from a client", function()
				return probe.seqs >= 3
			end)
			expect(probe.seqBad).toBe(0)
			expect(probe.seqRegressions).toBe(0)
		end, evidence)

		it("echoing arrivals back on Signals.Echo never failed", function()
			local probe = V2.probe()
			V2.await("an echoed Ping", function()
				return V2.count(probe.commands, "echo") > 0
			end)
			expect(probe.fireErrors).toBe(0)
		end, evidence)
	end)
end
