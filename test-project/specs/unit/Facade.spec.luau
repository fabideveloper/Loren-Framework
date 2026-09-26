--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local Version = require(Runtime:WaitForChild("Version")) :: any
local Errors = require(Runtime:WaitForChild("Errors")) :: any
local Schema = require(Runtime:WaitForChild("Schema")) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Registry = require(Runtime:WaitForChild("Registry")) :: any

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local warnings: { string } = {}

	local function quiet()
		table.clear(warnings)
		Log._test.setStudio(true)
		Log._test.setSink(function() end, function(line: string)
			table.insert(warnings, line)
		end)
	end

	local function boot(): any
		local ok, value = Loren.SetOnFire():timeout(5):await()
		expect(ok).toBe(true)
		return value
	end

	-- pcall around a closure, so an error raised at level 3 by a lane is attributed to this file.
	local function fails(fn: () -> ()): string
		local ok: boolean, err: any = pcall(fn)
		expect(ok).toBe(false)
		return tostring(err)
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Loren.Testing.Reset({ Offline = true })
		quiet()
	end)

	afterEach(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	describe("fields", function()
		it("IsServer and IsClient follow RunService (IsClient == false in Run mode)", function()
			expect(Loren.IsServer).toBe(RunService:IsServer())
			expect(Loren.IsServer).toBe(true)
			expect(Loren.IsClient).toBe(false)
		end)

		it("Version is a 2.x version", function()
			expect(string.sub(Loren.Version, 1, 2)).toBe("2.")
			expect(Loren.Version).toBe(Version.Version)
			expect(table.isfrozen(Version)).toBe(true)
		end)

		it("Errors and T are the lane tables", function()
			expect(Loren.Errors).toBe(Errors.Public)
			expect(Loren.T).toBe(Schema.T)
		end)

		it("State, IsOnFire and IsReady start Idle", function()
			expect(Loren.State).toBe(C.State.Idle)
			expect(Loren.IsOnFire).toBe(false)
			expect(Loren.IsReady).toBe(false)
		end)

		it("Loren.Testing is frozen", function()
			expect(table.isfrozen(Loren.Testing)).toBe(true)
			expect(typeof(Loren.Testing.Mount)).toBe("function")
			expect(typeof(Loren.Testing.Fired)).toBe("function")
			expect(typeof(Loren.Testing.Emit)).toBe("function")
			expect(typeof(Loren.Testing.Reset)).toBe("function")
		end)

		it("the shim (ReplicatedStorage.Shared.Loren) returns this facade", function()
			local shared = ReplicatedStorage:FindFirstChild("Shared")
			local shim = shared and shared:FindFirstChild("Loren")
			expect(shim).toBeTruthy()
			local requireAny: (any) -> any = require :: any -- a run-time path the type checker cannot follow
			expect(requireAny(shim)).toBe(Loren)
		end)
	end)

	describe("dot and colon forms", function()
		it("AddServices", function()
			local folder = Instance.new("Folder")
			local m1 = (Runtime:WaitForChild("Version") :: ModuleScript):Clone()
			m1.Name = "One"
			m1.Parent = folder
			local m2 = m1:Clone()
			m2.Name = "Two"
			m2.Parent = folder
			folder.Parent = game:GetService("ServerStorage")
			Loren.AddServices({ m1 })
			Loren:AddServices({ m2 })
			folder:Destroy()
			expect(Registry.names("Service")).toEqual({ "One", "Two" })
		end)

		it("AddControllers (ignored on the server, both forms)", function()
			local folder = Instance.new("Folder")
			Loren.AddControllers(folder)
			Loren:AddControllers(folder)
			expect(Registry.names("Controller")).toEqual({})
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("AddControllers is client-only")
		end)

		it("SetOnFire and OnReady", function()
			local p1 = Loren.SetOnFire()
			local p2 = Loren:SetOnFire()
			local p3 = Loren.OnReady()
			local p4 = Loren:OnReady()
			for _, p in { p1, p2, p3, p4 } do
				local ok, value = p:timeout(5):await()
				expect(ok).toBe(true)
				expect(value).toBe(Loren)
			end
		end)

		it("GetService, GetController and Get", function()
			local mod = {}
			Registry._test.register("Service", "Shop", mod)
			expect(Loren.GetService("Shop")).toBe(mod)
			expect(Loren:GetService("Shop")).toBe(mod)
			expect(Loren.Get(mod)).toBe(mod)
			expect((Loren :: any):Get(mod)).toBe(mod)
			expect(fails(function()
				Loren.GetController("X")
			end)).toContain("GetController is client-only")
			expect(fails(function()
				Loren:GetController("X")
			end)).toContain("GetController is client-only")
		end)

		it("Configure", function()
			Loren.Configure({ FrameRate = 10 })
			Loren:Configure({ ByteRate = 20 })
			expect(Config.get().FrameRate).toBe(10)
			expect(Config.get().ByteRate).toBe(20)
		end)

		it("AddMiddleware, OnViolation and OnError", function()
			local fn = function()
				return true
			end
			Loren.AddMiddleware(fn)
			Loren:AddMiddleware(fn)
			Loren.OnViolation(function() end)
			Loren:OnViolation(function() end)
			Loren.OnError(function() end)
			Loren:OnError(function() end)
			for _, name in { "AddMiddleware", "OnViolation", "OnError" } do
				expect(fails(function()
					Loren[name](5)
				end)).toContain(name .. " expects a function, got number")
				expect(fails(function()
					Loren[name](Loren, "x")
				end)).toContain(name .. " expects a function, got string")
			end
		end)

		it("Flush, GetStats and DumpManifest", function()
			-- before networking exists: no-op and zeros
			Loren.Flush()
			Loren:Flush()
			local s1 = Loren.GetStats()
			local s2 = Loren:GetStats()
			expect(s1.Side).toBe("Server")
			expect(s2.Side).toBe("Server")
			expect(s1.Routes).toBe(0)
			expect(s1).never.toBe(s2)
			expect(fails(function()
				Loren.DumpManifest()
			end)).toContain("DumpManifest needs the routes")
			local S: any = { Client = {} }
			function S.Client:Ping() end
			Registry._test.register("Service", "Svc", S)
			boot()
			Loren.Flush()
			Loren:Flush()
			expect(Loren.GetStats().Routes).toBe(1)
			local model = Loren.DumpManifest()
			expect(Loren:DumpManifest()).toEqual(model) -- a fresh copy each call
			expect(model.version).toBe(Version.Version)
			expect(model.proto).toBe(C.PROTO)
			expect(model.services[1].name).toBe("Svc")
		end)

		it("Reject", function()
			expect(Errors.isReject(Loren.Reject("a", 1))).toBe(true)
			local r = Loren:Reject("b", 2)
			expect(r.Message).toBe("b")
			expect(r.Data).toBe(2)
		end)

		it("Method, Event and Signal", function()
			local T = Loren.T
			local pairsOf = {
				{ Loren.Method(T.u8), Loren:Method(T.u8), C.Kind.Method },
				{ Loren.Event(), Loren:Event(), C.Kind.Event },
				{ Loren.Signal(T.u8), Loren:Signal(T.u8), C.Kind.Signal },
			}
			for _, row in pairsOf do
				expect(Schema.isSpec(row[1])).toBe(true)
				expect(Schema.isSpec(row[2])).toBe(true)
				expect(row[1].kind).toBe(row[3])
				expect(row[2].kind).toBe(row[3])
			end
			expect(#Loren:Method(T.u8, T.u8).args).toBe(2)
		end)

		it("keeps nil holes after stripping Loren", function()
			local r = Loren:Reject(nil, 5)
			expect(r.Message).toBe("")
			expect(r.Data).toBe(5)
		end)
	end)

	describe("rules", function()
		it("AddMiddleware after SetOnFire is an error", function()
			boot()
			expect(fails(function()
				Loren.AddMiddleware(function() end)
			end)).toContain("AddMiddleware must be called before SetOnFire")
		end)

		it("Configure and AddServices after SetOnFire are errors at the caller's line", function()
			boot()
			local e1 = fails(function()
				Loren.Configure({ FrameRate = 1 })
			end)
			expect(e1).toContain("Configure must be called before SetOnFire")
			expect(e1).toContain("Facade.spec")
			local e2 = fails(function()
				Loren.AddServices({})
			end)
			expect(e2).toContain("AddServices/AddControllers must be called before SetOnFire")
			expect(e2).toContain("Facade.spec")
		end)

		it("unknown names error at the caller's line with a suggestion", function()
			Registry._test.register("Service", "Inventory", {})
			local err = fails(function()
				Loren.GetService("Inventroy")
			end)
			expect(err).toContain("Did you mean 'Inventory'?")
			expect(err).toContain("Facade.spec")
		end)

		it("IsOnFire, IsReady and State follow the boot", function()
			local p = Loren.SetOnFire()
			expect(Loren.IsOnFire).toBe(true)
			expect((p:timeout(5):await())).toBe(true)
			expect(Loren.IsReady).toBe(true)
			expect(Loren.State).toBe(C.State.Ready)
			Loren.Testing.Reset({ Offline = true })
			expect(Loren.IsOnFire).toBe(false)
			expect(Loren.IsReady).toBe(false)
			expect(Loren.State).toBe(C.State.Idle)
		end)
	end)
end
