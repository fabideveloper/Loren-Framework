--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(ReplicatedStorage.LorenRuntime.Constants)
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("v2 server readiness", function()
		it("is on fire and Ready", function()
			local Loren = V2.loren()
			expect(Loren.IsOnFire).toBe(true)
			expect(Loren.IsReady).toBe(true)
			expect(Loren.State).toBe(C.State.Ready)
			expect(Loren.IsServer).toBe(true)
			expect(Loren.IsClient).toBe(false)
		end)

		it("OnReady resolves at once with Loren, in both call forms", function()
			local Loren = V2.loren()
			for _, promise in { Loren.OnReady(), Loren:OnReady() } do
				expect(promise:getStatus()).toBe("Resolved")
				local ok, value = promise:await()
				expect(ok).toBe(true)
				expect(rawequal(value, Loren)).toBe(true)
			end
		end)

		it("a repeat SetOnFire shares the boot and resolves with Loren", function()
			local Loren = V2.loren()
			local ok, value = Loren.SetOnFire():await()
			expect(ok).toBe(true)
			expect(rawequal(value, Loren)).toBe(true)
		end)

		it("LorenIgnite ran while Booting (IsOnFire already true, IsReady false)", function()
			local ignite = V2.probe().ignite
			expect(ignite).never.toBeNil()
			expect(ignite.State).toBe(C.State.Booting)
			expect(ignite.IsReady).toBe(false)
			expect(ignite.IsOnFire).toBe(true)
			expect(ignite.GetService).toBe(true)
		end)

		it("OnReady awaited inside LorenBurn resolved with Loren at Ready", function()
			local probe = V2.probe()
			V2.await("LorenBurn's OnReady", function()
				return probe.burnReady ~= nil
			end, 10)
			local ready = probe.burnReady
			expect(ready.ok).toBe(true)
			expect(ready.SameLoren).toBe(true)
			expect(ready.State).toBe(C.State.Ready)
			expect(ready.IsReady).toBe(true)
		end, { timeout = 20 })

		it("GetStats works and says Server", function()
			local stats = V2.loren().GetStats()
			expect(stats.Side).toBe("Server")
		end)
	end)
end
