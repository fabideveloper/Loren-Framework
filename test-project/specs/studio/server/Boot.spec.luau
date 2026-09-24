--!strict
-- Server boot through the public API.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local notLoren = Env.isRaw

	describe("server boot", function()
		it("booted without an error", function()
			expect(Env.boot.error).toBeNil()
			expect(Env.boot.ok).toBe(true)
		end)

		it("sets IsOnFire and IsServer", function()
			expect(Env.Loren.IsOnFire).toBe(true)
			expect(Env.Loren.IsServer).toBe(true)
		end, { skip = notLoren })

		-- 1.5.1 bug net:arch-11: in Studio Run mode IsClient is also true on the server (fixed in 2.0).
		it("IsClient is false on the server", function()
			expect(Env.Loren.IsClient).toBe(false)
		end, { skip = notLoren or (Env.is151 and Env.isRunMode) })

		it("SetOnFire resolved with Loren", function()
			expect(Env.boot.value).toBe(Env.Loren)
		end, { skip = notLoren })

		it("a second SetOnFire resolves with Loren again", function()
			local ok, value = Env.Loren:SetOnFire():await()
			expect(ok).toBe(true)
			expect(value).toBe(Env.Loren)
		end, { skip = notLoren })
	end)
end
