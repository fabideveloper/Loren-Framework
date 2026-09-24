--!strict
-- Client boot through the public API (1.5.1 and 2.0; Loren-only checks skip on raw).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local notLoren = Env.isRaw

	describe("client boot", function()
		it("booted without an error", function()
			expect(Env.boot.error).toBeNil()
			expect(Env.boot.ok).toBe(true)
		end)

		it("has a proxy for every fixture service", function()
			for _, name in Env.SERVICE_NAMES do
				expect(Env.proxies[name]).never.toBeNil()
			end
		end)

		it("sets IsOnFire and IsClient, not IsServer", function()
			local Loren = Env.Loren
			expect(Loren.IsOnFire).toBe(true)
			expect(Loren.IsClient).toBe(true)
			expect(Loren.IsServer).toBe(false)
		end, { skip = notLoren })

		it("SetOnFire resolved with Loren", function()
			expect(Env.boot.value).toBe(Env.Loren)
		end, { skip = notLoren })

		it("a second SetOnFire resolves with Loren again", function()
			local ok, value = Env.Loren:SetOnFire():await()
			expect(ok).toBe(true)
			expect(value).toBe(Env.Loren)
		end, { skip = notLoren })

		it("ignited TestController once with its proxies injected, then burned it", function()
			local controller = Env.controller
			expect(controller.IgniteCount).toBe(1)
			expect(controller.IgnitedOnClient).toBe(true)
			expect(controller.IgniteSawProxy).toBe(true)
			expect(Env.waitUntil(function()
				return controller.BurnCount == 1
			end, 3)).toBe(true)
		end, { skip = notLoren })

		it("replaced TestController.Dependencies with a name -> proxy map", function()
			local deps = Env.controller.Dependencies
			for _, name in Env.SERVICE_NAMES do
				expect(deps[name]).toBe(Env.proxies[name])
			end
		end, { skip = notLoren })
	end)
end
