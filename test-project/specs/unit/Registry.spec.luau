--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Registry = require(Runtime:WaitForChild("Registry")) :: any

local T = Loren.T

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local warnings: { string } = {}
	local sandbox: Folder = nil :: any

	local function folder(name: string, parent: Instance): Folder
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
		return f
	end

	-- A ModuleScript that returns a (frozen) table.
	local function tableModule(name: string, parent: Instance): ModuleScript
		local m = (Runtime:WaitForChild("Version") :: ModuleScript):Clone()
		m.Name = name
		m.Parent = parent
		return m
	end

	local function brokenModule(name: string, parent: Instance): ModuleScript
		local m = (script.Parent._fixtures.IntentionalLoadError :: ModuleScript):Clone()
		m.Name = name
		m.Parent = parent
		return m
	end

	-- A ModuleScript that returns a function (a clone of this spec).
	local function functionModule(name: string, parent: Instance): ModuleScript
		local m = (script :: ModuleScript):Clone()
		m.Name = name
		m.Parent = parent
		return m
	end

	local function names(kind: string): { string }
		return Registry.names(kind)
	end

	local function check(kind: string): any
		local report = Registry.newReport("Server")
		Registry.checkModules(report, kind)
		return report
	end

	-- Registers `module` as Service `name` and builds the declarations: (report, decl).
	local function build(module: any, name: string?): (any, any)
		Registry._test.register("Service", name or "Svc", module)
		local report = Registry.newReport("Server")
		local decls = Registry.buildServices(report, Config.get())
		return report, decls[1]
	end

	local function findWarning(list: { string }, text: string): string?
		for _, w in list do
			if string.find(w, text, 1, true) then
				return w
			end
		end
		return nil
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Registry._reset()
		Config._reset()
		Log._reset()
		table.clear(warnings)
		Log._test.setStudio(true)
		Log._test.setSink(function() end, function(line: string)
			table.insert(warnings, line)
		end)
		sandbox = folder("LorenRegistrySpec", ServerStorage)
	end)

	afterEach(function()
		Registry._reset()
		Config._reset()
		Log._reset()
		sandbox:Destroy()
	end)

	describe("add", function()
		it("registers direct ModuleScript children and requires them at add time", function()
			local a = tableModule("Alpha", sandbox)
			tableModule("Beta", sandbox)
			Loren.AddServices(sandbox)
			expect(names("Service")).toEqual({ "Alpha", "Beta" })
			local rec = Registry.records("Service").Alpha
			expect(rec.name).toBe("Alpha")
			expect(rec.kind).toBe("Service")
			expect(rec.instance).toBe(a)
			expect(rec.path).toBe(a:GetFullName())
			expect(rec.module.Version).toBe((require(Runtime:WaitForChild("Version")) :: any).Version)
			expect(rec.deps).toEqual({})
		end)

		it("accepts an array of ModuleScripts", function()
			local a = tableModule("A", sandbox)
			local b = tableModule("B", sandbox)
			Loren.AddServices({ a, b })
			expect(names("Service")).toEqual({ "A", "B" })
		end)

		it("works with the colon form and across several calls", function()
			local one = folder("One", sandbox)
			local two = folder("Two", sandbox)
			tableModule("A", one)
			tableModule("B", two)
			Loren:AddServices(one)
			Loren.AddServices(two)
			expect(names("Service")).toEqual({ "A", "B" })
		end)

		it("skips ModuleScripts inside sub-Folders with one Studio warning (1.5.1 behavior)", function()
			tableModule("Top", sandbox)
			local sub = folder("Sub", sandbox)
			local nested = tableModule("Nested", sub)
			Loren.AddServices(sandbox)
			expect(names("Service")).toEqual({ "Top" })
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("skipped ModuleScripts inside sub-Folders")
			expect(warnings[1]).toContain(nested:GetFullName())
			expect(warnings[1]).toContain("Recursive = true")
		end)

		it("Recursive descends Folders but never a ModuleScript's children", function()
			local sub = folder("Sub", sandbox)
			local deep = folder("Deep", sub)
			tableModule("InSub", sub)
			tableModule("InDeep", deep)
			local parentModule = tableModule("Parent", sandbox)
			tableModule("Child", parentModule)
			Loren.AddServices(sandbox, { Recursive = true })
			expect(names("Service")).toEqual({ "InDeep", "InSub", "Parent" })
			expect(#warnings).toBe(0)
		end)

		it("Recursive = false keeps the 1.5.1 behavior", function()
			tableModule("Top", sandbox)
			tableModule("Nested", folder("Sub", sandbox))
			Loren.AddServices(sandbox, { Recursive = false })
			expect(names("Service")).toEqual({ "Top" })
		end)

		it("adding the same ModuleScript twice is a no-op", function()
			local a = tableModule("A", sandbox)
			Loren.AddServices(sandbox)
			Loren.AddServices({ a })
			expect(names("Service")).toEqual({ "A" })
			expect(check("Service").errors).toEqual({})
		end)

		it("reports duplicate names with both paths", function()
			local first = tableModule("Dup", sandbox)
			local second = tableModule("Dup", folder("Sub", sandbox))
			Loren.AddServices(sandbox, { Recursive = true })
			local report = check("Service")
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Duplicate Service name 'Dup'")
			expect(report.errors[1]).toContain(first:GetFullName())
			expect(report.errors[1]).toContain(second:GetFullName())
		end)

		it("stores a load error and reports it in checkModules", function()
			local m = brokenModule("Broken", sandbox)
			tableModule("Fine", sandbox)
			Loren.AddServices(sandbox)
			expect(names("Service")).toEqual({ "Fine" })
			expect(Registry.isFailed("Service", "Broken")).toBe(true)
			local report = check("Service")
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Service 'Broken'")
			expect(report.errors[1]).toContain(m:GetFullName())
			expect(report.errors[1]).toContain("failed to load")
		end)

		it("reports a module that does not return a table", function()
			functionModule("NotATable", sandbox)
			Loren.AddServices(sandbox)
			local report = check("Service")
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("must return a table, got function")
		end)

		it("AddControllers on the server warns once in Studio and registers nothing", function()
			tableModule("Ctrl", sandbox)
			Loren.AddControllers(sandbox)
			Loren.AddControllers(sandbox)
			expect(names("Controller")).toEqual({})
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("AddControllers is client-only")
		end)

		it("raises after SetOnFire (lock), at the caller's line", function()
			tableModule("A", sandbox)
			Registry.lock()
			local ok, err = pcall(function()
				Loren.AddServices(sandbox)
			end)
			expect(ok).toBe(false)
			expect(tostring(err)).toContain("AddServices/AddControllers must be called before SetOnFire")
			expect(tostring(err)).toContain("Registry.spec")
			expect(names("Service")).toEqual({})
		end)

		it("validates the container", function()
			local a = tableModule("A", sandbox)
			local function adds(...: any): string
				local args = table.pack(...)
				local ok, err = pcall(function()
					Loren.AddServices(table.unpack(args, 1, args.n))
				end)
				expect(ok).toBe(false)
				return tostring(err)
			end
			expect(adds(5)).toContain("expects a container Instance or an array of Instances")
			expect(adds(nil)).toContain("expects a container Instance or an array of Instances")
			expect(adds({ 5 })).toContain("expects a container Instance or an array of Instances")
			expect(adds({ [2] = a })).toContain("expects a container Instance or an array of Instances")
			expect(adds({ x = a })).toContain("expects a container Instance or an array of Instances")
		end)

		it("validates the options", function()
			tableModule("A", sandbox)
			local function adds(opts: any): string
				local ok, err = pcall(function()
					Loren.AddServices(sandbox, opts)
				end)
				expect(ok).toBe(false)
				return tostring(err)
			end
			expect(adds(5)).toContain("options must be a table")
			expect(adds({ Recursiv = true })).toContain("unknown option 'Recursiv'")
			expect(adds({ Recursive = 1 })).toContain("Recursive must be a boolean")
			expect(names("Service")).toEqual({})
		end)
	end)

	describe("checkModules", function()
		it("lets a frozen module without Dependencies, Signals or ClientEvents boot", function()
			tableModule("FrozenFine", sandbox)
			Loren.AddServices(sandbox)
			expect(table.isfrozen(Registry.records("Service").FrozenFine.module)).toBe(true)
			local report = check("Service")
			expect(report.errors).toEqual({})
			local report2 = Registry.newReport("Server")
			Registry.buildServices(report2, Config.get())
			expect(report2.errors).toEqual({})
		end)

		it("rejects a frozen module that Loren must write to", function()
			Registry._test.register("Service", "F1", table.freeze({ Dependencies = {} }))
			Registry._test.register("Service", "F2", table.freeze({ Signals = {}, ClientEvents = {} }))
			local report = check("Service")
			expect(#report.errors).toBe(2)
			expect(report.errors[1]).toContain("Service 'F1'")
			expect(report.errors[1]).toContain("is frozen, but Loren must replace its Dependencies")
			expect(report.errors[2]).toContain("Signals and ClientEvents")
		end)

		it("rejects a frozen Client table", function()
			Registry._test.register("Service", "FC", { Client = table.freeze({}) })
			local report = check("Service")
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Client is frozen")
		end)

		it("validates Dependencies as an array of names", function()
			Registry._test.register("Service", "D1", { Dependencies = "Data" })
			Registry._test.register("Service", "D2", { Dependencies = { 1 } })
			Registry._test.register("Service", "D3", { Dependencies = { Data = true } })
			Registry._test.register("Service", "D4", { Dependencies = { "A", nil :: any, "B" } })
			local report = check("Service")
			expect(#report.errors).toBe(4)
			expect(report.errors[1]).toContain("D1.Dependencies must be an array of names")
			expect(report.errors[2]).toContain("D2.Dependencies[1] must be a name string")
			expect(report.errors[3]).toContain("has the key 'Data'")
			expect(report.errors[4]).toContain("D4.Dependencies")
		end)

		it("warns about duplicate Dependencies and keeps one of each", function()
			Registry._test.register("Service", "Svc", { Dependencies = { "A", "B", "A" } })
			local report = check("Service")
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("Svc.Dependencies lists 'A' twice")
			expect(Registry.records("Service").Svc.deps).toEqual({ "A", "B" })
		end)

		it("needs hooks to be functions (callable tables allowed)", function()
			local callable = setmetatable({}, { __call = function() end })
			Registry._test.register("Service", "H1", { LorenIgnite = 5 })
			Registry._test.register("Service", "H2", { LorenBurn = "x", LorenExtinguish = true })
			Registry._test.register("Service", "H3", { LorenIgnite = callable })
			local report = check("Service")
			expect(#report.errors).toBe(3)
			expect(report.errors[1]).toContain("Service 'H1': LorenIgnite must be a function (got number)")
		end)

		it("validates Controller Signals lists and leaves a Controller's own Signals table alone", function()
			-- 1.5.1 never touched Controller.Signals: a map of the module's own signal objects still boots
			local own = { ItemAdded = { Fire = function() end } }
			Registry._test.register("Controller", "Own", { Signals = own })
			Registry._test.register("Controller", "Mixed", { Signals = { 1 } })
			Registry._test.register("Controller", "FrozenOwn", table.freeze({ Signals = own }))
			Registry._test.register("Controller", "Ok", { Signals = { "Changed", "Changed" } })
			Registry._test.register("Controller", "FrozenList", table.freeze({ Signals = { "A" } }))
			local report = check("Controller")
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Controller 'FrozenList'")
			expect(report.errors[1]).toContain("must replace its Signals")
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("Ok.Signals lists 'Changed' twice")
			expect(Registry.controllerSignals({ Signals = own })).toBeNil()
			expect(Registry.controllerSignals({ Signals = { 1 } })).toBeNil()
			expect(Registry.controllerSignals({})).toBeNil()
			expect(Registry.controllerSignals({ Signals = { "A", "B", "A" } })).toEqual({ "A", "B" })
			-- Testing.Mount (Kind = "Controller") keeps the own table, and turns a list into LocalSignals
			local mountedOwn: any = { Signals = own }
			Loren.Testing.Mount(mountedOwn, { Kind = "Controller", Name = "OwnMount" })
			expect(mountedOwn.Signals).toBe(own)
			local mountedList: any = { Signals = { "Opened" } }
			Loren.Testing.Mount(mountedList, { Kind = "Controller", Name = "ListMount" })
			expect(typeof(mountedList.Signals.Opened.Fire)).toBe("function")
		end)
	end)

	describe("buildServices", function()
		it("turns Client functions into Methods", function()
			local S: any = { Client = {} }
			function S.Client:Beta() end
			function S.Client:Alpha() end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(report.warnings).toEqual({})
			expect(decl.name).toBe("Svc")
			expect(decl.module).toBe(S)
			expect(decl.client).toBe(S.Client)
			expect(decl.networked).toBe(true)
			expect(#decl.members).toBe(2)
			local m = decl.members[1]
			expect(m.name).toBe("Alpha")
			expect(m.kind).toBe(C.Kind.Method)
			expect(m.fn).toBe(S.Client.Alpha)
			expect(m.colon).toBe(false)
			expect(m.middleware).toBeNil()
			expect(m.spec).toBeNil()
		end)

		it("keeps a module without network members as a non-networked decl", function()
			local report, decl = build({})
			expect(report.errors).toEqual({})
			expect(decl.networked).toBe(false)
			expect(decl.client).toBe(false)
			expect(decl.members).toEqual({})
		end)

		it("returns one decl per Service, sorted by name", function()
			Registry._test.register("Service", "Zed", {})
			Registry._test.register("Service", "Abe", {})
			local report = Registry.newReport("Server")
			local decls = Registry.buildServices(report, Config.get())
			expect(#decls).toBe(2)
			expect(decls[1].name).toBe("Abe")
			expect(decls[2].name).toBe("Zed")
		end)

		it("sorts members by (name, kind); a Signal may share a Method's name", function()
			local S: any = { Client = {}, Signals = { "Echo", "Alpha" }, ClientEvents = { "Ping" } }
			function S.Client:Echo() end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			local got = {}
			for _, m in decl.members do
				table.insert(got, m.name .. ":" .. m.kind)
			end
			expect(got).toEqual({
				"Alpha:" .. C.Kind.Signal,
				"Echo:" .. C.Kind.Method,
				"Echo:" .. C.Kind.Signal,
				"Ping:" .. C.Kind.Event,
			})
		end)

		it("rejects a Client that is not a table", function()
			local report = build({ Client = 5 })
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Svc.Client must be a table")
		end)

		it("warns about reserved Client names and skips them", function()
			local S: any = { Client = {} }
			for name in C.ReservedClientNames do
				S.Client[name] = function() end
			end
			function S.Client:Real() end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(5)
			expect(findWarning(report.warnings, "Svc.Client.Try uses a reserved name and is not networked")).toBeTruthy()
			expect(findWarning(report.warnings, "Svc.Client.Server uses a reserved name")).toBeTruthy()
			expect(#decl.members).toBe(1)
			expect(decl.members[1].name).toBe("Real")
		end)

		it("ignores non-function Client fields with a Studio warning (Server is silent)", function()
			local S: any = { Client = { Count = 5 } }
			S.Client.Server = S
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(report.warnings).toEqual({})
			expect(decl.networked).toBe(false)
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("Svc.Client.Count is not a function")
		end)

		it("validates Signals and ClientEvents as arrays of names", function()
			local cases: { { any } } = {
				{ { Signals = "X" }, "Svc.Signals must be an array of names" },
				{ { Signals = { 1 } }, "Svc.Signals[1] must be a name string" },
				{ { Signals = { X = true } }, "per-member options go in Spec" },
				{ { ClientEvents = 5 }, "Svc.ClientEvents must be an array of names" },
				{ { ClientEvents = { true } }, "Svc.ClientEvents[1] must be a name string" },
				{ { ClientEvents = { Ping = "x" } }, "has the key 'Ping'" },
			}
			for _, case in cases do
				Registry._reset()
				local report = build(case[1])
				expect(#report.errors).toBe(1)
				expect(report.errors[1]).toContain(case[2])
			end
		end)

		it("warns about names listed twice and keeps one", function()
			local report, decl = build({ Signals = { "A", "A" }, ClientEvents = { "E", "E" } })
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(2)
			expect(findWarning(report.warnings, "Svc.Signals lists 'A' twice")).toBeTruthy()
			expect(findWarning(report.warnings, "Svc.ClientEvents lists 'E' twice")).toBeTruthy()
			expect(#decl.members).toBe(2)
		end)

		it("rejects a Method and a ClientEvent with the same name", function()
			local S: any = { Client = {}, ClientEvents = { "Ping" } }
			function S.Client:Ping() end
			local report = build(S)
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("'Ping' is both a Client method and a ClientEvent")
		end)

		it("rejects names longer than 255 bytes", function()
			local long = string.rep("n", 256)
			local ok255 = string.rep("n", 255)
			local S: any = { Client = {}, Signals = { long }, ClientEvents = { long .. "e" } }
			S.Client[long] = function() end
			S.Client[ok255] = function() end
			local report, decl = build(S)
			expect(#report.errors).toBe(3)
			expect(findWarning(report.errors, "Svc.Client: member names are limited to 255 bytes")).toBeTruthy()
			expect(findWarning(report.errors, "Svc.Signals: member names are limited to 255 bytes")).toBeTruthy()
			expect(findWarning(report.errors, "Svc.ClientEvents: member names are limited to 255 bytes")).toBeTruthy()
			expect(#decl.members).toBe(1)
			Registry._reset()
			local report2 = build({}, string.rep("S", 256))
			expect(#report2.errors).toBe(1)
			expect(report2.errors[1]).toContain("is longer than 255 bytes")
		end)
	end)

	describe("Middleware", function()
		it("attaches middleware to Methods and ClientEvents", function()
			local S: any = { Client = {}, ClientEvents = { "Ping" }, Middleware = {} }
			function S.Client:Buy(_player: any, _item: any) end
			function S.Middleware.Buy(_player: any, _item: any)
				return true
			end
			function S.Middleware.Ping(_player: any)
				return true
			end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(report.warnings).toEqual({})
			expect(decl.members[1].middleware).toBe(S.Middleware.Buy)
			expect(decl.members[1].colon).toBe(false)
			expect(decl.members[2].middleware).toBe(S.Middleware.Ping)
		end)

		it("flags colon-defined middleware with the exact warning (fail closed)", function()
			local S: any = { Client = {}, Middleware = {} }
			function S.Client:Buy(_player: any, _item: any) end
			function S.Middleware:Buy(_player: any, _item: any)
				return true
			end
			local report, decl = build(S, "AdminService")
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toBe(
				"AdminService.Middleware.Buy looks colon-defined (3 parameters, like Client:Buy). Middleware is "
					.. "called as (player, ...args) without self, so every Buy call is DENIED until you write: "
					.. "function AdminService.Middleware.Buy(player, ...)"
			)
			expect(decl.members[1].colon).toBe(true)
			expect(decl.members[1].middleware).toBe(S.Middleware.Buy)
		end)

		it("does not flag vararg, short or differently sized middleware", function()
			local S: any = { Client = {}, Middleware = {} }
			function S.Client:A(_p: any, _x: any) end
			function S.Middleware.A(_p: any, ...: any)
				return true
			end
			function S.Client:B(_p: any, _x: any) end
			function S.Middleware.B(_p: any, _x: any) -- dot style: 2 parameters, Client:B has 3
				return true
			end
			S.Client.C = function() end
			S.Middleware.C = function()
				return true
			end
			local report, decl = build(S)
			expect(report.warnings).toEqual({})
			for _, m in decl.members do
				expect(m.colon).toBe(false)
			end
		end)

		it("flags a colon-looking pair with 2 parameters", function()
			local S: any = { Client = {}, Middleware = {} }
			function S.Client:Ping(_p: any) end
			function S.Middleware:Ping(_p: any)
				return true
			end
			local report, decl = build(S)
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("(2 parameters, like Client:Ping)")
			expect(decl.members[1].colon).toBe(true)
		end)

		it("skips the check when MiddlewareArityCheck is false", function()
			Loren.Configure({ MiddlewareArityCheck = false })
			local S: any = { Client = {}, Middleware = {} }
			function S.Client:Buy(_player: any, _item: any) end
			function S.Middleware:Buy(_player: any, _item: any)
				return true
			end
			local report, decl = build(S)
			expect(report.warnings).toEqual({})
			expect(decl.members[1].colon).toBe(false)
		end)

		it("never checks ClientEvent middleware for colons", function()
			local S: any = { ClientEvents = { "Ping" }, Middleware = {} }
			function S.Middleware:Ping(_player: any, _x: any)
				return true
			end
			local report, decl = build(S)
			expect(report.warnings).toEqual({})
			expect(decl.members[1].colon).toBe(false)
		end)

		it("warns about orphan keys with a suggestion and ignores them", function()
			local S: any = { Client = {}, Middleware = {} }
			function S.Client:Buy() end
			S.Middleware.Buyy = function()
				return true
			end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("Svc.Middleware.Buyy matches no Client method or ClientEvent")
			expect(report.warnings[1]).toContain("Did you mean 'Buy'?")
			expect(decl.members[1].middleware).toBeNil()
		end)

		it("rejects non-table Middleware and non-function entries", function()
			local report = build({ Middleware = 5 })
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Svc.Middleware must be a table of functions")
			Registry._reset()
			local S: any = { Client = {}, Middleware = { Buy = 5 } }
			function S.Client:Buy() end
			local report2 = build(S)
			expect(#report2.errors).toBe(1)
			expect(report2.errors[1]).toContain("Svc.Middleware.Buy must be a function (got number)")
		end)
	end)

	describe("Spec", function()
		it("attaches specs by name and kind", function()
			local S: any = {
				Client = {},
				Signals = { "Echo" },
				ClientEvents = { "Aim" },
				Spec = {
					Buy = Loren.Method(T.u8),
					Echo = Loren.Signal(),
					Aim = Loren.Event(),
				},
			}
			function S.Client:Buy() end
			function S.Client:Echo() end
			local report, decl = build(S)
			expect(report.errors).toEqual({})
			expect(report.warnings).toEqual({})
			local byKey = {}
			for _, m in decl.members do
				byKey[m.name .. ":" .. m.kind] = m
			end
			expect(byKey["Buy:" .. C.Kind.Method].spec).toBe(S.Spec.Buy)
			expect(byKey["Aim:" .. C.Kind.Event].spec).toBe(S.Spec.Aim)
			expect(byKey["Echo:" .. C.Kind.Signal].spec).toBe(S.Spec.Echo)
			expect(byKey["Echo:" .. C.Kind.Method].spec).toBeNil()
		end)

		it("rejects a kind mismatch", function()
			local S: any = { Client = {}, Spec = { Buy = Loren.Event() } }
			function S.Client:Buy() end
			local report = build(S)
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toBe("Svc.Spec.Buy is a Loren.Event but Buy is a Client method")
		end)

		it("warns about orphan keys with a suggestion", function()
			local S: any = { Client = {}, Spec = { Buyy = Loren.Method() } }
			function S.Client:Buy() end
			local report = build(S)
			expect(report.errors).toEqual({})
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("Svc.Spec.Buyy matches no Client method, ClientEvent or Signal")
			expect(report.warnings[1]).toContain("Did you mean 'Buy'?")
		end)

		it("rejects a non-table Spec and values that are not specs", function()
			local report = build({ Spec = 5 })
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("Svc.Spec must be a table")
			Registry._reset()
			local S: any = { Client = {}, Spec = { Buy = T.u8 } }
			function S.Client:Buy() end
			local report2 = build(S)
			expect(#report2.errors).toBe(1)
			expect(report2.errors[1]).toContain("Svc.Spec.Buy must be Loren.Method(...)")
		end)
	end)

	describe("suggest", function()
		it("matches case-insensitively first", function()
			expect(Registry.suggest("dataservice", { "DataService", "Other" })).toBe("DataService")
		end)

		it("accepts a Levenshtein distance up to 2", function()
			expect(Registry.suggest("DataServce", { "DataService" })).toBe("DataService")
			expect(Registry.suggest("DtaServce", { "DataService" })).toBe("DataService")
			expect(Registry.suggest("DtServce", { "DataService" })).toBeNil()
			expect(Registry.suggest("Completely", { "DataService" })).toBeNil()
			expect(Registry.suggest("X", {})).toBeNil()
		end)

		it("breaks ties by byte order", function()
			expect(Registry.suggest("Ab", { "Ac", "Aa" })).toBe("Aa")
		end)
	end)

	describe("reports", function()
		it("newReport, err and warn", function()
			local report = Registry.newReport("Client")
			expect(report).toEqual({ side = "Client", errors = {}, warnings = {} })
			Registry.err(report, "e1")
			Registry.warn(report, "w1")
			expect(report.errors).toEqual({ "e1" })
			expect(report.warnings).toEqual({ "w1" })
		end)

		it("formats a failed boot (section 8.4)", function()
			local report = Registry.newReport("Server")
			Registry.err(report, "ShopService.Dependencies: 'DataServce' is not a registered Service.")
			Registry.err(report, "second\nline")
			Registry.warn(report, "AdminService.Middleware.Kick looks colon-defined")
			expect(Registry.format(report, true)).toBe(
				"(LORENঌ) Boot failed on Server (2 problems):\n"
					.. "  1. ShopService.Dependencies: 'DataServce' is not a registered Service.\n"
					.. "  2. second\n"
					.. "     line\n"
					.. "Warnings (1):\n"
					.. "  - AdminService.Middleware.Kick looks colon-defined"
			)
			local one = Registry.newReport("Client")
			Registry.err(one, "x")
			expect(Registry.format(one, true)).toBe("(LORENঌ) Boot failed on Client (1 problem):\n  1. x")
		end)

		it("formats boot warnings, or nothing", function()
			local report = Registry.newReport("Server")
			expect(Registry.format(report, false)).toBe("")
			Registry.warn(report, "a")
			Registry.warn(report, "b")
			expect(Registry.format(report, false)).toBe("(LORENঌ) Boot warnings on Server (2):\n  - a\n  - b")
		end)
	end)

	describe("depsMap", function()
		it("returns the resolved map and warns once per undeclared key", function()
			local rec = Registry._test.register("Service", "Shop", {})
			local data = {}
			local map = Registry.depsMap(rec, { Data = data })
			expect(map.Data).toBe(data)
			expect(map.Other).toBeNil()
			expect(map.Other).toBeNil()
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("Shop reads undeclared dependency 'Other'")
			expect(table.isfrozen(map)).toBe(false)
		end)
	end)

	describe("lock, records and _reset", function()
		it("records() is empty for an unknown kind and after _reset", function()
			Registry._test.register("Service", "A", {})
			expect(Registry.records("Service").A).toBeTruthy()
			expect(Registry.records("Nope")).toEqual({})
			Registry._reset()
			expect(Registry.records("Service")).toEqual({})
		end)

		it("_reset unlocks and restores keys Loren replaced", function()
			local declared = { "Hit" }
			local module: any = { Signals = declared }
			Registry.inject(module, "Signals", { Hit = true })
			Registry.inject(module, "Dependencies", {})
			expect(Registry.declared(module, "Signals")).toBe(declared)
			Registry.lock()
			expect(Registry._test.isLocked()).toBe(true)
			Registry._reset()
			expect(Registry._test.isLocked()).toBe(false)
			expect(module.Signals).toBe(declared)
			expect(module.Dependencies).toBeNil()
		end)

		it("Get finds registered modules only", function()
			local module = {}
			Registry._test.register("Service", "A", module)
			expect(Loren.Get(module)).toBe(module)
			expect(Registry.recordOf(module).name).toBe("A")
			expect(function()
				Loren.Get({})
			end).toThrow("is not a registered Service")
		end)
	end)
end
