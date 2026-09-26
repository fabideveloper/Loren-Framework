--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Env = require(ReplicatedStorage.LorenTest.Harness.Env)
local C = require(ReplicatedStorage.LorenRuntime.Constants)
local V2 = require(script.Parent._V2)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local K = C.Kind
	local F = C.MemberFlag

	local function has(flags: number, flag: number): boolean
		return bit32.band(flags, flag) ~= 0
	end

	describe("v2 server boot", function()
		it("booted 2.x with the v2 fixtures (a Method and a Signal share the name Echo)", function()
			expect(Env.boot.error).toBeNil()
			expect(Env.boot.ok).toBe(true)
			local Loren = V2.loren()
			expect(string.sub(Loren.Version, 1, 2)).toBe("2.")
			expect(Loren.State).toBe("Ready")
			expect(rawequal(Loren.GetService("V2Service"), V2.service())).toBe(true)
		end)

		it("Shared.Loren is the shim: it returns the ReplicatedStorage.LorenRuntime facade", function()
			local viaShim: any = require(ReplicatedStorage.Shared.Loren)
			local runtime: any = require(ReplicatedStorage.LorenRuntime)
			expect(ReplicatedStorage.LorenRuntime:IsA("ModuleScript")).toBe(true)
			expect(rawequal(viaShim, runtime)).toBe(true)
			expect(rawequal(viaShim, V2.loren())).toBe(true)
		end)

		it("ReplicatedStorage.LorenNet is Ready with proto 2", function()
			local net = ReplicatedStorage:FindFirstChild(C.Names.NetFolder)
			expect(net).never.toBeNil()
			expect((net :: Instance).ClassName).toBe("Folder")
			expect((net :: Instance):GetAttribute(C.Names.StateAttr)).toBe(C.NetState.Ready)
			expect((net :: Instance):GetAttribute(C.Names.ProtoAttr)).toBe(C.PROTO)
		end)

		it("has exactly the two remotes: Reliable (RemoteEvent) and Unreliable (UnreliableRemoteEvent)", function()
			local net = ReplicatedStorage:WaitForChild(C.Names.NetFolder)
			local reliable = net:FindFirstChild(C.Names.Reliable)
			local unreliable = net:FindFirstChild(C.Names.Unreliable)
			expect(reliable).never.toBeNil()
			expect(unreliable).never.toBeNil()
			expect((reliable :: Instance).ClassName).toBe("RemoteEvent")
			expect((unreliable :: Instance).ClassName).toBe("UnreliableRemoteEvent")
			local remotes = 0
			for _, child in net:GetDescendants() do
				if child:IsA("BaseRemoteEvent") or child:IsA("RemoteFunction") then
					remotes += 1
				end
			end
			expect(remotes).toBe(2)
		end)

		it("creates no RemoteFunction and no 1.5.1 LorenBridge", function()
			expect(ReplicatedStorage:FindFirstChild("LorenBridge")).toBeNil()
			for _, root in { ReplicatedStorage:WaitForChild(C.Names.NetFolder), ReplicatedStorage.LorenRuntime } do
				for _, child in root:GetDescendants() do
					expect(child:IsA("RemoteFunction")).toBe(false)
				end
			end
		end)

		it("opened the remotes only at Ready (LorenIgnite saw State Booting and no remotes)", function()
			local ignite = V2.probe().ignite
			expect(ignite).never.toBeNil()
			expect(ignite.NetState).toBe(C.NetState.Booting)
			expect(ignite.RemotesVisible).toBe(false)
		end)
	end)

	describe("v2 server wiring", function()
		it("replaced the declared keys: Signals, ClientEvents, Client.Server", function()
			local service = V2.service()
			expect(rawequal(service.Client.Server, service)).toBe(true)
			expect(table.isfrozen(service.Signals)).toBe(true)
			expect(table.isfrozen(service.ClientEvents)).toBe(true)
			for _, name in { "BootSignal", "Echo", "Hit", "Stream" } do
				expect(service.Signals[name]).never.toBeNil()
			end
			for _, name in { "Aim", "Ping", "Seq" } do
				expect(service.ClientEvents[name]).never.toBeNil()
			end
			expect(typeof(service.Client.Echo)).toBe("function")
		end)

		it("Loren.Get is the identity for a registered module and errors otherwise", function()
			local Loren = V2.loren()
			local service = V2.service()
			expect(rawequal(Loren.Get(service), service)).toBe(true)
			expect(function()
				Loren.Get({})
			end).toThrow()
		end)

		it("GetService of an unknown name errors with a suggestion", function()
			local Loren = V2.loren()
			expect(function()
				Loren.GetService("V2Servce")
			end).toThrow("V2Service")
		end)
	end)

	describe("v2 manifest (DumpManifest)", function()
		it("ships every V2Service member with its kind, flags, timeout and rate", function()
			local model = V2.loren().DumpManifest()
			expect(model.proto).toBe(C.PROTO)
			expect(model.limits.mirror).toBeCloseTo(C.Default.MirrorFraction, 5)

			local echoMethod = V2.member(model, "Echo", K.Method)
			local echoSignal = V2.member(model, "Echo", K.Signal)
			expect(echoMethod).never.toBeNil()
			expect(echoSignal).never.toBeNil()
			expect(echoMethod.route).never.toBe(echoSignal.route)
			expect(echoMethod.timeout).toBe(C.Default.DefaultTimeout)

			expect(V2.member(model, "Hang", K.Method).timeout).toBe(2)
			expect(V2.member(model, "Slow", K.Method).timeout).toBe(3)
			expect(has(V2.member(model, "SerialAdd", K.Method).flags, F.Serial)).toBe(true)
			expect(has(V2.member(model, "Echo", K.Method).flags, F.Serial)).toBe(false)

			local limited = V2.member(model, "Limited", K.Method)
			expect(limited.rate).toBe(2)
			expect(limited.burst).toBe(2)

			local typed = V2.member(model, "TypedEcho", K.Method)
			expect(has(typed.flags, F.HasArgs)).toBe(true)
			expect(has(typed.flags, F.HasReturns)).toBe(true)
			expect(#typed.args).toBe(3)
			expect(#typed.returns).toBe(3)
			expect(has(echoMethod.flags, F.HasArgs)).toBe(false)

			local needs = V2.member(model, "NeedsPart", K.Method)
			expect(needs.args[1].op).toBe(C.SchemaOp.INSTANCE)
			expect(needs.args[1].className).toBe("BasePart")

			local aim = V2.member(model, "Aim", K.Event)
			expect(has(aim.flags, F.Unreliable)).toBe(true)
			expect(has(aim.flags, F.Coalesce)).toBe(true)
			expect(has(aim.flags, F.Ordered)).toBe(false)
			local seq = V2.member(model, "Seq", K.Event)
			expect(has(seq.flags, F.Unreliable)).toBe(true)
			expect(has(seq.flags, F.Ordered)).toBe(true)
			local ping = V2.member(model, "Ping", K.Event)
			expect(has(ping.flags, F.Unreliable)).toBe(false)

			local stream = V2.member(model, "Stream", K.Signal)
			expect(has(stream.flags, F.Unreliable)).toBe(true)
			expect(#stream.args).toBe(3)
			expect(#V2.member(model, "Hit", K.Signal).args).toBe(2)
			expect(V2.member(model, "BootSignal", K.Signal).backlog).toBe(C.Default.Backlog)
			expect(V2.member(model, "MwColon", K.Method)).never.toBeNil()
		end)

		it("gives every route a distinct id in 1..65535", function()
			local model = V2.loren().DumpManifest()
			local seen: { [number]: boolean } = {}
			local count = 0
			for _, service in model.services do
				for _, member in service.members do
					expect(member.route >= 1 and member.route <= C.ROUTE_MAX).toBe(true)
					expect(seen[member.route]).toBeNil()
					seen[member.route] = true
					count += 1
				end
			end
			expect(count).toBeGreaterThanOrEqual(23) -- V2Service alone: 16 Methods, 3 Events, 4 Signals
		end)
	end)
end
