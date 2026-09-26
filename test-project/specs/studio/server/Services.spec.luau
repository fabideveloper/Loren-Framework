--!strict
-- The fixture Services after boot: lifecycle, Client.Server, Signals and Dependencies.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local skip = Env.isRaw -- raw has no Loren services

	describe("fixture services", function()
		it("ignited every service once on the server, then burned it once", function()
			for _, name in Env.SERVICE_NAMES do
				local service = Env.service(name)
				expect(service.IgniteCount).toBe(1)
				expect(service.IgnitedOnServer).toBe(true)
			end
			local burned = Env.waitUntil(function()
				for _, name in Env.SERVICE_NAMES do
					if Env.service(name).BurnCount ~= 1 then
						return false
					end
				end
				return true
			end, 3)
			expect(burned).toBe(true)
		end, { skip = skip })

		it("sets Client.Server to the service", function()
			for _, name in Env.SERVICE_NAMES do
				local service = Env.service(name)
				expect(service.Client.Server).toBe(service)
			end
		end, { skip = skip })

		it("turns Signals names into signals with Fire and FireAll", function()
			local changed = Env.service("CounterService").Signals.Changed
			local tick = Env.service("BroadcastService").Signals.Tick
			for _, signal in { changed, tick } do
				expect(signal).never.toBeNil()
				expect(typeof(signal.Fire)).toBe("function")
				expect(typeof(signal.FireAll)).toBe("function")
			end
		end, { skip = skip })

		it("injects Dependencies as a name -> service map", function()
			local dependent = Env.service("DependentService")
			expect(dependent.Dependencies.CounterService).toBe(Env.service("CounterService"))
		end, { skip = skip or (Env.is151 and Env.isRunMode) })

		it("had its dependency during LorenIgnite", function()
			expect(Env.service("DependentService").IgniteSawDependency).toBe(true)
		end, { skip = skip })
	end)
end
