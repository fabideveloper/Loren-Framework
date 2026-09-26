--!strict
-- InstanceService: Instances round-trip by reference; an Instance the server can't see arrives as nil.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = ReplicatedStorage.LorenTest.Harness
local Env = require(Harness.Env)
local Budget = require(Harness.Budget)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local Instances = Env.proxy("InstanceService")

	local function nameOf(inst: any): (boolean, any, any)
		Budget.take(1)
		return Instances:NameOf(inst):await()
	end

	describe("InstanceService.NameOf", function()
		it("round-trips a replicated Instance and reads its Name on the server", function()
			local config = ReplicatedStorage:WaitForChild("TestConfig")
			local ok, inst, name = nameOf(config)
			expect(ok).toBe(true)
			expect(inst).toBe(config)
			expect(name).toBe("TestConfig")
		end)

		it("round-trips the LocalPlayer", function()
			local ok, inst, name = nameOf(Players.LocalPlayer)
			expect(ok).toBe(true)
			expect(inst).toBe(Players.LocalPlayer)
			expect(name).toBe(Players.LocalPlayer.Name)
		end)

		it("rejects when the Instance does not exist on the server (arrives as nil)", function()
			local localOnly = Instance.new("Folder")
			local ok = nameOf(localOnly)
			localOnly:Destroy()
			expect(ok).toBe(false)
		end)

		it("rejects nil", function()
			local ok = nameOf(nil)
			expect(ok).toBe(false)
		end)
	end)
end
