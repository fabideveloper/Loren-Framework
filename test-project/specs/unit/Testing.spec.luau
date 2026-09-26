--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Registry = require(Runtime:WaitForChild("Registry")) :: any
local Lifecycle = require(Runtime:WaitForChild("Lifecycle")) :: any

local Testing = Loren.Testing

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local prints: { string } = {}
	local player1 = { UserId = 1, Name = "One" }
	local player2 = { UserId = 2, Name = "Two" }

	local function newService(): any
		local S: any = {
			Client = {},
			Signals = { "Hit", "Score" },
			ClientEvents = { "Ping" },
			Dependencies = { "Data" },
			ignited = false,
		}
		function S.Client:Echo(_player: any, x: any)
			return x
		end
		function S:LorenIgnite()
			self.ignited = true
		end
		function S:Award(player: any, points: number)
			self.Signals.Score:Fire(player, points)
		end
		return S
	end

	beforeAll(function()
		Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		Testing.Reset()
	end)

	beforeEach(function()
		Testing.Reset({ Offline = true })
		table.clear(prints)
		Log._test.setSink(function(line: string)
			table.insert(prints, line)
		end, function() end)
	end)

	afterEach(function()
		Testing.Reset({ Offline = true })
	end)

	describe("Mount (Service)", function()
		it("wires Client.Server, Dependencies, Signals and ClientEvents without Ignite", function()
			local S = newService()
			local data = { Get = function() end }
			local mounted = Testing.Mount(S, { Dependencies = { Data = data } })
			expect(mounted).toBe(S)
			expect(S.Client.Server).toBe(S)
			expect(S.Dependencies.Data).toBe(data)
			expect(S.ignited).toBe(false)
			expect(typeof(S.Signals.Hit.Fire)).toBe("function")
			expect(typeof(S.ClientEvents.Ping.Connect)).toBe("function")
			expect(S.Client:Echo(player1, 5)).toBe(5)
			expect(Loren.State).toBe("Idle")
		end)

		it("defaults Dependencies to an empty table", function()
			local S = newService()
			Testing.Mount(S)
			expect(S.Dependencies).toEqual({})
		end)

		it("records Fire, FireAll, FireFor and FireExcept", function()
			local S = newService()
			Testing.Mount(S)
			S:Award(player1, 10)
			S.Signals.Hit:FireAll("boom", nil, 3)
			S.Signals.Hit:FireFor({ player1, player2 }, "x")
			S.Signals.Hit:FireExcept(player2)
			local score = Testing.Fired(S.Signals.Score)
			expect(#score).toBe(1)
			expect(score[1].Method).toBe("Fire")
			expect(score[1].Target).toBe(player1)
			expect(score[1].Args.n).toBe(1)
			expect(score[1].Args[1]).toBe(10)
			local hit = Testing.Fired(S.Signals.Hit)
			expect(#hit).toBe(3)
			expect(hit[1].Method).toBe("FireAll")
			expect(hit[1].Target).toBeNil()
			expect(hit[1].Args.n).toBe(3)
			expect(hit[1].Args[2]).toBeNil()
			expect(hit[1].Args[3]).toBe(3)
			expect(hit[2].Method).toBe("FireFor")
			expect(hit[2].Target).toEqual({ player1, player2 })
			expect(hit[3].Method).toBe("FireExcept")
			expect(hit[3].Target).toBe(player2)
			expect(hit[3].Args.n).toBe(0)
		end)

		it("Fired returns the live list, which the spec may clear", function()
			local S = newService()
			Testing.Mount(S)
			local list = Testing.Fired(S.Signals.Hit)
			S.Signals.Hit:FireAll(1)
			expect(#list).toBe(1)
			table.clear(list)
			S.Signals.Hit:FireAll(2)
			expect(#Testing.Fired(S.Signals.Hit)).toBe(1)
		end)

		it("recording Signals keep the server rules", function()
			local S = newService()
			Testing.Mount(S)
			expect(function()
				S.Signals.Hit.Fire(player1, 1)
			end).toThrow("must be called with ':'")
			expect(function()
				S.Signals.Hit:Connect(function() end)
			end).toThrow("server-to-client")
			expect(function()
				local _ = S.Signals.Hti
			end).toThrow("has no Signal 'Hti'")
			expect(function()
				local _ = S.ClientEvents.Pnig
			end).toThrow("has no ClientEvent 'Pnig'")
			expect(table.isfrozen(S.Signals)).toBe(true)
		end)

		it("Emit drives ClientEvents listeners with the player and every argument", function()
			local S = newService()
			Testing.Mount(S)
			local got: any = nil
			S.ClientEvents.Ping:Connect(function(...: any)
				got = table.pack(...)
			end)
			Testing.Emit(S.ClientEvents.Ping, player1, "a", nil, 3)
			expect(got.n).toBe(4)
			expect(got[1]).toBe(player1)
			expect(got[2]).toBe("a")
			expect(got[3]).toBeNil()
			expect(got[4]).toBe(3)
		end)

		it("Emit isolates a listener error", function()
			local S = newService()
			Testing.Mount(S)
			local second = false
			S.ClientEvents.Ping:Connect(function()
				error("listener boom")
			end)
			S.ClientEvents.Ping:Connect(function()
				second = true
			end)
			Testing.Emit(S.ClientEvents.Ping, player2)
			expect(second).toBe(true)
		end)

		it("Once listeners run once", function()
			local S = newService()
			Testing.Mount(S)
			local n = 0
			S.ClientEvents.Ping:Once(function()
				n += 1
			end)
			Testing.Emit(S.ClientEvents.Ping, player1)
			Testing.Emit(S.ClientEvents.Ping, player1)
			expect(n).toBe(1)
		end)

		it("mounting twice keeps working from the declarations", function()
			local S = newService()
			Testing.Mount(S)
			Testing.Mount(S, { Dependencies = { Data = 1 } })
			expect(S.Dependencies.Data).toBe(1)
			expect(typeof(S.Signals.Hit.FireAll)).toBe("function")
			expect(Registry.declared(S, "Signals")).toEqual({ "Hit", "Score" })
		end)

		it("mounts a frozen module without Dependencies, Signals or ClientEvents", function()
			local frozen = table.freeze({ Value = 1 })
			expect(Testing.Mount(frozen)).toBe(frozen)
		end)
	end)

	describe("Mount (Controller)", function()
		it("turns Signals into LocalSignals", function()
			local ctrl: any = { Signals = { "Changed" } }
			Testing.Mount(ctrl, { Kind = "Controller" })
			local got = nil
			ctrl.Signals.Changed:Connect(function(v: any)
				got = v
			end)
			ctrl.Signals.Changed:Fire(42)
			expect(got).toBe(42)
			expect(ctrl.Dependencies).toEqual({})
		end)
	end)

	describe("Mount validation", function()
		it("raises the report text at the caller's line", function()
			local ok, err = pcall(function()
				Testing.Mount({ Client = 5, Signals = { 1 } })
			end)
			expect(ok).toBe(false)
			local text = tostring(err)
			expect(text).toContain("Testing.Mount(Mounted) failed")
			expect(text).toContain("Mounted.Client must be a table")
			expect(text).toContain("Mounted.Signals[1] must be a name string")
			expect(text).toContain("Testing.spec")
		end)

		it("uses the Name option in messages", function()
			expect(function()
				Testing.Mount({ Client = 5 }, { Name = "ShopService" })
			end).toThrow("ShopService.Client must be a table")
		end)

		it("raises on a Method and a ClientEvent with one name", function()
			local S: any = { Client = {}, ClientEvents = { "Buy" } }
			function S.Client:Buy() end
			expect(function()
				Testing.Mount(S)
			end).toThrow("is both a Client method and a ClientEvent")
		end)

		it("rejects bad arguments and options", function()
			expect(function()
				Testing.Mount(5)
			end).toThrow("Testing.Mount expects a module table")
			expect(function()
				Testing.Mount({}, 5)
			end).toThrow("options must be a table")
			expect(function()
				Testing.Mount({}, { Kind = "Thing" })
			end).toThrow('Kind must be "Service" or "Controller"')
			expect(function()
				Testing.Mount({}, { Dependencies = 5 })
			end).toThrow("Dependencies must be a table")
			expect(function()
				Testing.Mount({}, { Deps = {} })
			end).toThrow("unknown option 'Deps'")
		end)

		it("Fired and Emit reject objects that Mount did not create", function()
			expect(function()
				Testing.Fired({})
			end).toThrow("Testing.Fired expects a Signals object")
			expect(function()
				Testing.Emit({}, player1)
			end).toThrow("Testing.Emit expects a ClientEvents object")
			local S = newService()
			Testing.Mount(S)
			expect(function()
				Testing.Emit(S.Signals.Hit, player1)
			end).toThrow("Testing.Emit expects a ClientEvents object")
		end)
	end)

	describe("dot and colon forms", function()
		it("drops a leading Loren.Testing argument", function()
			local S = newService()
			expect(Loren.Testing:Mount(S)).toBe(S)
			S.Signals.Hit:FireAll(1)
			expect(#Loren.Testing:Fired(S.Signals.Hit)).toBe(1)
			local n = 0
			S.ClientEvents.Ping:Connect(function()
				n += 1
			end)
			Loren.Testing:Emit(S.ClientEvents.Ping, player1)
			expect(n).toBe(1)
			Loren.Testing:Reset({ Offline = true })
			expect(Lifecycle._test.offline()).toBe(true)
		end)
	end)

	describe("Reset", function()
		it("puts every declaration Mount replaced back", function()
			local S = newService()
			local signals, events, deps = S.Signals, S.ClientEvents, S.Dependencies
			Testing.Mount(S)
			Testing.Reset({ Offline = true })
			expect(S.Signals).toBe(signals)
			expect(S.ClientEvents).toBe(events)
			expect(S.Dependencies).toBe(deps)
			expect(S.Client.Server).toBeNil()
		end)

		it("restores the require-time state of the runtime", function()
			Loren.Configure({ FrameRate = 5 })
			Registry._test.register("Service", "A", {})
			expect((Loren.SetOnFire():timeout(5):await())).toBe(true)
			expect(Loren.State).toBe("Ready")
			expect(Config.isFrozen()).toBe(true)
			expect(Loren.DumpManifest().version).toBe(Loren.Version)
			Testing.Reset({ Offline = true })
			expect(Loren.State).toBe("Idle")
			expect(Loren.IsOnFire).toBe(false)
			expect(Loren.IsReady).toBe(false)
			expect(Config.isFrozen()).toBe(false)
			expect(Config.get().FrameRate).toBe(C.Default.FrameRate)
			expect(Registry.records("Service")).toEqual({})
			expect(Registry._test.isLocked()).toBe(false)
			-- the server modules were reset too: the routes are gone
			expect(function()
				Loren.DumpManifest()
			end).toThrow("DumpManifest needs the routes")
			-- and the runtime boots again
			expect((Loren.SetOnFire():timeout(5):await())).toBe(true)
		end)

		it("sets the offline flag for the next boot", function()
			Testing.Reset({ Offline = true })
			expect(Lifecycle._test.offline()).toBe(true)
			Testing.Reset({ Offline = false })
			expect(Lifecycle._test.offline()).toBe(false)
			Testing.Reset()
			expect(Lifecycle._test.offline()).toBe(false)
			Testing.Reset({ Offline = true })
			Log._test.setSink(function(text: string) -- Reset restored the real sinks
				table.insert(prints, text)
			end, function() end)
			expect((Loren.SetOnFire():timeout(5):await())).toBe(true)
			local line: string? = nil
			for _, p in prints do
				if string.find(p, "Burning on Server", 1, true) then
					line = p
				end
			end
			expect(line).toBeTruthy()
			expect(line :: string).toContain("(offline)")
		end)

		it("destroys ReplicatedStorage.LorenNet", function()
			local net = Instance.new("Folder")
			net.Name = C.Names.NetFolder
			net.Parent = ReplicatedStorage
			Testing.Reset({ Offline = true })
			expect(ReplicatedStorage:FindFirstChild(C.Names.NetFolder)).toBeNil()
			expect(net.Parent).toBeNil()
		end)

		it("validates its options before resetting anything", function()
			Loren.Configure({ FrameRate = 7 })
			expect(function()
				Testing.Reset(5)
			end).toThrow("Testing.Reset options must be a table")
			expect(function()
				Testing.Reset({ Offline = 1 })
			end).toThrow("Offline must be a boolean")
			expect(function()
				Testing.Reset({ Online = true })
			end).toThrow("unknown option 'Online'")
			expect(Config.get().FrameRate).toBe(7)
		end)
	end)
end
