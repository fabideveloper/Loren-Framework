--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local C = V2.C

	describe("v2 client readiness", function()
		it("is on fire and Ready, as a client", function()
			local Loren = V2.loren()
			expect(string.sub(Loren.Version, 1, 2)).toBe("2.")
			expect(Loren.IsOnFire).toBe(true)
			expect(Loren.IsReady).toBe(true)
			expect(Loren.State).toBe(C.State.Ready)
			expect(Loren.IsClient).toBe(true)
			expect(Loren.IsServer).toBe(false)
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
			local ok, value = Loren:SetOnFire():await()
			expect(ok).toBe(true)
			expect(rawequal(value, Loren)).toBe(true)
		end)

		it("V2Controller's LorenIgnite ran while Booting, with its proxy already resolved", function()
			local ignite = V2.controller().Probe.ignite
			expect(ignite).never.toBeNil()
			expect(ignite.State).toBe(C.State.Booting)
			expect(ignite.IsReady).toBe(false)
			expect(ignite.IsOnFire).toBe(true)
			expect(ignite.HasProxy).toBe(true)
			expect(ignite.SameProxy).toBe(true)
		end)

		it("OnReady awaited inside LorenBurn resolved with Loren at Ready", function()
			local probe = V2.controller().Probe
			expect(V2.waitUntil(function()
				return probe.burnReady ~= nil
			end, 10)).toBe(true)
			local ready = probe.burnReady
			expect(ready.ok).toBe(true)
			expect(ready.SameLoren).toBe(true)
			expect(ready.State).toBe(C.State.Ready)
			expect(ready.IsReady).toBe(true)
		end, { timeout = 15 })

		it("sees LorenNet Ready with the two remotes and no RemoteFunction", function()
			local net = ReplicatedStorage:FindFirstChild(C.Names.NetFolder)
			expect(net).never.toBeNil()
			expect((net :: Instance):GetAttribute(C.Names.StateAttr)).toBe(C.NetState.Ready)
			local reliable = (net :: Instance):FindFirstChild(C.Names.Reliable)
			local unreliable = (net :: Instance):FindFirstChild(C.Names.Unreliable)
			expect(reliable and reliable.ClassName).toBe("RemoteEvent")
			expect(unreliable and unreliable.ClassName).toBe("UnreliableRemoteEvent")
			for _, child in (net :: Instance):GetDescendants() do
				expect(child:IsA("RemoteFunction")).toBe(false)
			end
		end)

		it("GetStats says Client", function()
			local stats = V2.loren().GetStats()
			expect(stats.Side).toBe("Client")
			expect(typeof(stats.PendingCalls)).toBe("number")
		end)
	end)

	describe("v2 controller lookups", function()
		it("GetController and Get return the registered table", function()
			local Loren = V2.loren()
			local module: any = require(ReplicatedStorage.LorenTest.V2Controllers.V2Controller)
			expect(rawequal(Loren.GetController("V2Controller"), module)).toBe(true)
			expect(rawequal(Loren.Get(module), module)).toBe(true)
		end)

		it("GetController of an unknown name raises", function()
			local Loren = V2.loren()
			expect(function()
				Loren.GetController("NoSuchController")
			end).toThrow()
		end)
	end)

	describe("v2 server-only facade functions raise on the client", function()
		it("AddMiddleware, OnViolation, OnError and DumpManifest", function()
			local Loren = V2.loren()
			local function noop() end
			expect(function()
				Loren.AddMiddleware(noop)
			end).toThrow("server-only")
			expect(function()
				Loren.OnViolation(noop)
			end).toThrow("server-only")
			expect(function()
				Loren.OnError(noop)
			end).toThrow("server-only")
			expect(function()
				Loren.DumpManifest()
			end).toThrow("server-only")
		end)
	end)
end
