--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Registry = require(Runtime:WaitForChild("Registry")) :: any
local Lifecycle = require(Runtime:WaitForChild("Lifecycle")) :: any
local RealServer = require(ServerScriptService:WaitForChild("LorenServer")) :: any

local FAILED_HEAD = "(LORENঌ) Boot failed on Server"
local NOT_NETWORKED = "(a Service is networked when it has a Client method, ClientEvent or Signal)"

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local prints: { string } = {}
	local warnings: { string } = {}
	local redErrors: { string } = {}

	local function reset()
		Loren.Testing.Reset({ Offline = true })
		table.clear(prints)
		table.clear(warnings)
		table.clear(redErrors)
		Log._test.setStudio(true)
		Log._test.setSink(function(line: string)
			table.insert(prints, line)
		end, function(line: string)
			table.insert(warnings, line)
		end)
		Lifecycle._test.setErrorSink(function(text: string)
			table.insert(redErrors, text)
		end)
	end

	local function service(name: string, module: any): any
		Registry._test.register("Service", name, module)
		return module
	end

	local function settle(p: any): (boolean, any)
		local ok, value = p:timeout(5):await()
		return ok, value
	end

	local function hasLine(list: { string }, text: string): string?
		for _, line in list do
			if string.find(line, text, 1, true) then
				return line
			end
		end
		return nil
	end

	local function fakeServer(overrides: { [string]: any }?): (any, { string })
		local calls: { string } = {}
		local o: { [string]: any } = overrides or {}
		local S: any = {}
		for modName: string, real: any in RealServer do
			local mod: any = {}
			for k: string, v: any in real do
				if type(v) == "function" then
					local key = modName .. "." .. k
					local original: any = v
					mod[k] = function(...: any): ...any
						table.insert(calls, key)
						local replacement: any = o[key]
						if replacement ~= nil then
							return (replacement :: any)(original, ...)
						end
						return original(...)
					end
				else
					mod[k] = v
				end
			end
			S[modName] = mod
		end
		Lifecycle._test.setServer(S)
		return S, calls
	end

	local function count(list: { string }, value: string): number
		local n = 0
		for _, v in list do
			if v == value then
				n += 1
			end
		end
		return n
	end

	-- Every failed boot: Failed state, rejection = the report, one red error, never opened.
	local function expectFailure(p: any, calls: { string }, needle: string): string
		local ok, err = settle(p)
		expect(ok).toBe(false)
		expect(typeof(err)).toBe("string")
		expect(string.sub(err, 1, #FAILED_HEAD)).toBe(FAILED_HEAD)
		expect(err).toContain(needle)
		expect(Loren.State).toBe("Failed")
		expect(Loren.IsReady).toBe(false)
		expect(Loren.IsOnFire).toBe(true)
		expect(#redErrors).toBe(1)
		expect(redErrors[1]).toBe(err)
		expect(calls).toContain("Transport.fail")
		expect(calls).never.toContain("Transport.open")
		return err
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
		-- Load LorenServer through the facade, so Testing.Reset also resets the server modules.
		Loren.OnError(function() end)
		expect(Lifecycle.loadedServer()).toBe(RealServer)
	end)

	afterAll(function()
		Loren.Testing.Reset()
	end)

	beforeEach(reset)
	afterEach(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	describe("offline server boot", function()
		it("reaches Ready with no modules and prints the boot line", function()
			local _, calls = fakeServer()
			local ok, value = settle(Loren.SetOnFire())
			expect(ok).toBe(true)
			expect(value).toBe(Loren)
			expect(Loren.State).toBe("Ready")
			expect(Loren.IsReady).toBe(true)
			expect(Loren.IsOnFire).toBe(true)
			expect(#prints).toBe(1)
			expect(
				string.match(prints[1], "^%(LORENঌ%) Burning on Server: 0 services, 0 routes, %d+ ms %(offline%)$")
			).toBeTruthy()
			expect(#redErrors).toBe(0)
			expect(Config.isFrozen()).toBe(true)
			expect(Registry._test.isLocked()).toBe(true)
			-- section 8.2 call order
			expect(calls).toEqual({
				"Transport.claim",
				"Limits.configure",
				"Violations.configure",
				"Routes.build",
				"Transport.prepare",
				"Transport.open",
			})
		end)

		it("counts services and routes in the boot line", function()
			local S: any = { Client = {}, Signals = { "Echo" } }
			function S.Client:Echo(_player: any, x: any)
				return x
			end
			service("EchoService", S)
			service("Plain", {})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(prints[1]).toContain("Burning on Server: 2 services, 2 routes, ")
		end)

		it("runs Ignite in dependency order, then every Burn, calling hooks as methods", function()
			local log: { string } = {}
			local function mod(name: string, deps: { string }?): any
				local m: any = { Dependencies = deps }
				function m:LorenIgnite()
					assert(self == m, "Ignite self")
					table.insert(log, "I:" .. name)
				end
				function m:LorenBurn()
					assert(self == m, "Burn self")
					table.insert(log, "B:" .. name)
				end
				return service(name, m)
			end
			mod("A", { "B" })
			mod("B", { "C" })
			mod("C")
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(log).toEqual({ "I:C", "I:B", "I:A", "B:C", "B:B", "B:A" })
			expect(Lifecycle._test.order()).toEqual({ "C", "B", "A" })
		end)

		it("injects Client.Server, Signals, ClientEvents and Dependencies (declared keys only)", function()
			local data = service("Data", {})
			local S: any = { Client = {}, Signals = { "Hit" }, ClientEvents = { "Ping" }, Dependencies = { "Data" } }
			function S.Client:Get() end
			local declaredSignals = S.Signals
			service("Shop", S)
			local bare = service("Bare", {})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(S.Client.Server).toBe(S)
			expect(typeof(S.Signals.Hit.FireAll)).toBe("function")
			expect(typeof(S.ClientEvents.Ping.Connect)).toBe("function")
			expect(S.Dependencies.Data).toBe(data)
			expect(S.Dependencies.Unknown).toBeNil()
			expect(hasLine(warnings, "Shop reads undeclared dependency 'Unknown'")).toBeTruthy()
			expect(rawget(bare, "Dependencies")).toBeNil()
			expect(rawget(bare, "Signals")).toBeNil()
			expect(rawget(bare, "ClientEvents")).toBeNil()
			-- Testing.Reset puts the declarations back
			Loren.Testing.Reset({ Offline = true })
			expect(S.Signals).toBe(declaredSignals)
			expect(S.Dependencies).toEqual({ "Data" })
			expect(S.Client.Server).toBeNil()
		end)

		it("boots a frozen module that declares no written keys", function()
			local ignited = false
			service(
				"Frozen",
				table.freeze({
					LorenIgnite = function()
						ignited = true
					end,
				})
			)
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(ignited).toBe(true)
		end)

		it("boots a Method and a Signal that share a name", function()
			local S: any = { Client = {}, Signals = { "Echo" } }
			function S.Client:Echo() end
			service("Svc", S)
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(Loren.State).toBe("Ready")
		end)

		it("allows cycles silently by default and runs the cycle in name order", function()
			local log: { string } = {}
			local function mod(name: string, deps: { string })
				service(name, {
					Dependencies = deps,
					LorenIgnite = function()
						table.insert(log, name)
					end,
				})
			end
			mod("B", { "A" })
			mod("A", { "B" })
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(log).toEqual({ "A", "B" })
			expect(hasLine(warnings, "Dependency cycle")).toBeNil()
		end)

		it("lists cycles in the boot warnings when CycleWarnings is on", function()
			Loren.Configure({ CycleWarnings = true })
			service("B", { Dependencies = { "A" } })
			service("A", { Dependencies = { "B" } })
			expect((settle(Loren.SetOnFire()))).toBe(true)
			local w = hasLine(warnings, "Boot warnings on Server (1):")
			expect(w).toBeTruthy()
			expect(w :: string).toContain("Dependency cycle: A -> B -> A")
		end)

		it("prints no warnings line when there are none", function()
			service("A", {})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(hasLine(warnings, "Boot warnings")).toBeNil()
		end)
	end)

	describe("failure at every step", function()
		it("step 2: Transport.claim refused", function()
			local _, calls = fakeServer({
				["Transport.claim"] = function()
					return false, "claim refused"
				end,
			})
			local err = expectFailure(Loren.SetOnFire(), calls, "  1. claim refused")
			expect(err).toContain("(1 problem)")
			expect(calls).never.toContain("Routes.build")
		end)

		it("step 3: validation errors (every problem in one report)", function()
			local _, calls = fakeServer()
			service("Bad", { Client = 5 })
			service("Shop", { Dependencies = { "DataServce" } })
			service("DataService", {})
			local err = expectFailure(Loren.SetOnFire(), calls, "Bad.Client must be a table")
			expect(err).toContain("(2 problems)")
			expect(err).toContain(
				"Shop.Dependencies: 'DataServce' is not a registered Service. Did you mean 'DataService'?"
			)
			expect(calls).never.toContain("Transport.prepare")
		end)

		it("step 3: the Configure cross-checks", function()
			local _, calls = fakeServer()
			Loren.Configure({ ByteBurst = 1000 })
			expectFailure(Loren.SetOnFire(), calls, "ByteBurst * MirrorFraction")
		end)

		it("step 3: a module that failed to load is reported once", function()
			local _, calls = fakeServer()
			local folder = Instance.new("Folder")
			folder.Name = "LorenLifecycleSpec"
			folder.Parent = game:GetService("ServerStorage")
			-- fails to load on purpose (its error in the Output is expected)
			local broken = (script.Parent._fixtures.IntentionalLoadError :: ModuleScript):Clone()
			broken.Name = "Broken"
			broken.Parent = folder
			Loren.AddServices(folder) -- requires (and fails) now
			folder:Destroy()
			service("User", { Dependencies = { "Broken" } })
			local err = expectFailure(Loren.SetOnFire(), calls, "Service 'Broken'")
			expect(err).toContain("failed to load")
			expect(err).toContain("(1 problem)")
		end)

		it("step 4: StrictCycles turns a cycle into an error", function()
			local _, calls = fakeServer()
			Loren.Configure({ StrictCycles = true })
			service("A", { Dependencies = { "B" } })
			service("B", { Dependencies = { "A" } })
			expectFailure(Loren.SetOnFire(), calls, "Dependency cycle: A -> B -> A (StrictCycles is on)")
		end)

		it("step 5: Routes.build reports an error", function()
			local _, calls = fakeServer({
				["Routes.build"] = function(_real: any, _decls: any, _cfg: any, report: any)
					table.insert(report.errors, "routes broke")
					return nil
				end,
			})
			expectFailure(Loren.SetOnFire(), calls, "routes broke")
			expect(calls).never.toContain("Transport.prepare")
		end)

		it("step 5: a throwing Limits.configure", function()
			local _, calls = fakeServer({
				["Limits.configure"] = function()
					error("limits broke")
				end,
			})
			local err = expectFailure(Loren.SetOnFire(), calls, "Internal error during the boot")
			expect(err).toContain("limits broke")
		end)

		it("step 6: an injection that throws", function()
			local _, calls = fakeServer()
			local client: any = setmetatable({}, {
				__newindex = function()
					error("read-only client")
				end,
			})
			rawset(client, "Get", function() end)
			service("Locked", { Client = client })
			local err = expectFailure(Loren.SetOnFire(), calls, "read-only client")
			expect(calls).never.toContain("Transport.prepare")
			expect(err).toContain("Internal error during the boot")
		end)

		it("step 7: a throwing Transport.prepare", function()
			local _, calls = fakeServer({
				["Transport.prepare"] = function()
					error("prepare broke")
				end,
			})
			expectFailure(Loren.SetOnFire(), calls, "prepare broke")
		end)

		it("step 8: an Ignite error stops the boot with the traceback", function()
			local _, calls = fakeServer()
			local later = false
			service("Boom", {
				LorenIgnite = function()
					error("ignite boom")
				end,
				LorenBurn = function()
					later = true
				end,
			})
			service("Next", {
				Dependencies = { "Boom" },
				LorenIgnite = function()
					later = true
				end,
			})
			local err = expectFailure(Loren.SetOnFire(), calls, "Service 'Boom': LorenIgnite failed: ")
			expect(err).toContain("ignite boom")
			expect(err).toContain("Lifecycle.spec") -- the traceback
			expect(later).toBe(false)
		end)

		it("after a failure, OnReady and repeat SetOnFire reject with the same report", function()
			fakeServer({
				["Transport.claim"] = function()
					return false, "nope"
				end,
			})
			local ok1, err1 = settle(Loren.SetOnFire())
			local ok2, err2 = settle(Loren.OnReady())
			local ok3, err3 = settle(Loren.SetOnFire())
			expect(ok1).toBe(false)
			expect(ok2).toBe(false)
			expect(ok3).toBe(false)
			expect(err2).toBe(err1)
			expect(err3).toBe(err1)
			expect(#redErrors).toBe(1)
		end)
	end)

	describe("Ignite and Burn", function()
		it("waits for a yielding Ignite and warns once", function()
			local log: { string } = {}
			service("Slow", {
				LorenIgnite = function()
					task.wait(0.1)
					table.insert(log, "Slow")
				end,
			})
			service("After", {
				Dependencies = { "Slow" },
				LorenIgnite = function()
					table.insert(log, "After")
				end,
			})
			local p = Loren.SetOnFire()
			expect(Loren.State).toBe("Booting")
			expect(Loren.IsOnFire).toBe(true)
			expect(Loren.IsReady).toBe(false)
			expect((settle(p))).toBe(true)
			expect(log).toEqual({ "Slow", "After" })
			local w =
				hasLine(warnings, "Slow:LorenIgnite yielded; the boot waits for it (move yielding work to LorenBurn)")
			expect(w).toBeTruthy()
			expect(Lifecycle._test.pendingTimers()).toBe(0)
		end)

		it("warns again while a yielding Ignite keeps running", function()
			Lifecycle._test.setTimings({ igniteWarn = 0.05 })
			service("Slow", {
				LorenIgnite = function()
					task.wait(0.3)
				end,
			})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(hasLine(warnings, "Slow:LorenIgnite is still running after 0.05 s")).toBeTruthy()
		end)

		it("IgniteTimeout fails the boot and cancels the Ignite thread", function()
			local _, calls = fakeServer()
			Loren.Configure({ IgniteTimeout = 0.1 })
			local resumed = false
			service("Hang", {
				LorenIgnite = function()
					task.wait(0.4)
					resumed = true
				end,
			})
			local started = os.clock()
			expectFailure(
				Loren.SetOnFire(),
				calls,
				"Service 'Hang': LorenIgnite did not finish within IgniteTimeout (0.1 s)"
			)
			expect(os.clock() - started < 0.35).toBe(true)
			task.wait(0.5)
			expect(resumed).toBe(false)
		end)

		it("isolates Burn errors and never waits for a yielding Burn", function()
			local log: { string } = {}
			service("A", {
				LorenBurn = function()
					error("burn boom")
				end,
			})
			service("B", {
				LorenBurn = function()
					table.insert(log, "B start")
					task.wait(0.2)
					table.insert(log, "B end")
				end,
			})
			service("C", {
				LorenBurn = function()
					table.insert(log, "C")
				end,
			})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			expect(Loren.State).toBe("Ready")
			expect(log).toEqual({ "B start", "C" })
			expect(hasLine(warnings, "Service 'A': LorenBurn failed: ")).toBeTruthy()
			expect(hasLine(warnings, "burn boom")).toBeTruthy()
		end)
	end)

	describe("readiness", function()
		it("starts Idle", function()
			expect(Loren.State).toBe("Idle")
			expect(Loren.IsOnFire).toBe(false)
			expect(Loren.IsReady).toBe(false)
		end)

		it("repeat SetOnFire calls share one boot", function()
			local ignites = 0
			service("A", {
				LorenIgnite = function()
					ignites += 1
					task.wait(0.05)
				end,
			})
			local p1 = Loren.SetOnFire()
			local p2 = Loren:SetOnFire()
			expect(p1).never.toBe(p2)
			local ok1, v1 = settle(p1)
			local ok2, v2 = settle(p2)
			expect(ok1 and ok2).toBe(true)
			expect(v1).toBe(Loren)
			expect(v2).toBe(Loren)
			local ok3, v3 = settle(Loren.SetOnFire())
			expect(ok3).toBe(true)
			expect(v3).toBe(Loren)
			expect(ignites).toBe(1)
			expect(#prints).toBe(1)
		end)

		it("a caller's cancel cannot stop the boot", function()
			service("Slow", {
				LorenIgnite = function()
					task.wait(0.1)
				end,
			})
			local p = Loren.SetOnFire()
			p:cancel()
			expect(p:getStatus()).toBe("Cancelled")
			expect(Lifecycle._test.hasGuard()).toBe(true)
			local ok, v = settle(Loren.OnReady())
			expect(ok).toBe(true)
			expect(v).toBe(Loren)
			expect(Loren.State).toBe("Ready")
		end)

		it("OnReady waits for SetOnFire and resolves at once when Ready", function()
			local early = Loren.OnReady()
			task.wait()
			expect(early:getStatus()).toBe("Started")
			expect(Loren.State).toBe("Idle")
			Loren.SetOnFire()
			local ok, v = settle(early)
			expect(ok).toBe(true)
			expect(v).toBe(Loren)
			local late = Loren:OnReady()
			expect(late:getStatus()).toBe("Resolved")
		end)

		it("Testing.Reset during a boot rejects it with Reset and returns to Idle", function()
			local burned = false
			service("Slow", {
				LorenIgnite = function()
					task.wait(0.2)
				end,
				LorenBurn = function()
					burned = true
				end,
			})
			local p = Loren.SetOnFire()
			expect(Loren.State).toBe("Booting")
			Loren.Testing.Reset({ Offline = true })
			local ok, err = settle(p)
			expect(ok).toBe(false)
			expect(err).toBe("(LORENঌ) Reset")
			expect(Loren.State).toBe("Idle")
			expect(Loren.IsOnFire).toBe(false)
			expect(Loren.IsReady).toBe(false)
			expect(Lifecycle._test.pendingTimers()).toBe(0)
			task.wait(0.3)
			expect(burned).toBe(false)
			expect(Loren.State).toBe("Idle")
		end)
	end)

	describe("shutdown (BindToClose)", function()
		it("runs LorenExtinguish in reverse order, all at once, between shutdown and the final flush", function()
			local _, calls = fakeServer()
			local function mod(name: string, deps: { string }?, hold: number)
				service(name, {
					Dependencies = deps,
					LorenExtinguish = function()
						table.insert(calls, "start:" .. name)
						task.wait(hold)
						table.insert(calls, "end:" .. name)
					end,
				})
			end
			mod("A", { "B" }, 0.1)
			mod("B", { "C" }, 0.05)
			mod("C", nil, 0)
			service("NoHook", {})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			table.clear(calls)
			Lifecycle._test.shutdown()
			expect(Loren.State).toBe("ShuttingDown")
			expect(calls[1]).toBe("Transport.shutdown")
			expect({ calls[2], calls[3], calls[4] }).toEqual({ "start:A", "start:B", "start:C" })
			expect(calls[#calls]).toBe("Transport.flushNow")
			expect(count(calls, "end:A")).toBe(1)
			expect(count(calls, "end:B")).toBe(1)
			expect(count(calls, "end:C")).toBe(1)
		end)

		it("stops waiting after the budget and names the hooks still running", function()
			local _, calls = fakeServer()
			Lifecycle._test.setTimings({ shutdownBudget = 0.2 })
			service("Hang", {
				LorenExtinguish = function()
					task.wait(3)
				end,
			})
			service("Quick", {
				LorenExtinguish = function()
					error("extinguish boom")
				end,
			})
			expect((settle(Loren.SetOnFire()))).toBe(true)
			local started = os.clock()
			Lifecycle._test.shutdown()
			local elapsed = os.clock() - started
			expect(elapsed >= 0.15).toBe(true)
			expect(elapsed < 1).toBe(true)
			expect(hasLine(warnings, "Shutdown budget (0.2 s) passed; LorenExtinguish still running in Hang")).toBeTruthy()
			expect(hasLine(warnings, "Service 'Quick': LorenExtinguish failed: ")).toBeTruthy()
			expect(calls[#calls]).toBe("Transport.flushNow")
		end)

		it("does nothing unless the boot is Ready", function()
			local _, calls = fakeServer()
			Lifecycle._test.shutdown()
			expect(Loren.State).toBe("Idle")
			expect(calls).toEqual({})
		end)
	end)

	describe("module lookup (server)", function()
		it("GetService returns the module table right after registration", function()
			local a = service("Alpha", {})
			expect(Loren.GetService("Alpha")).toBe(a)
			expect(Loren:GetService("Alpha")).toBe(a)
		end)

		it("GetService errors on unknown names with a suggestion", function()
			service("Alpha", {})
			local ok, err = pcall(function()
				Loren.GetService("alpah")
			end)
			expect(ok).toBe(false)
			expect(tostring(err)).toContain("GetService: 'alpah' is not a registered Service. Did you mean 'Alpha'?")
			expect(tostring(err)).toContain("Lifecycle.spec")
			expect(function()
				Loren.GetService(5)
			end).toThrow("GetService expects a Service name")
		end)

		it("GetController is client-only", function()
			expect(function()
				Loren.GetController("X")
			end).toThrow("GetController is client-only")
		end)

		it("Get returns registered modules only", function()
			local a = service("Alpha", {})
			expect(Loren.Get(a)).toBe(a)
			expect(function()
				Loren.Get({})
			end).toThrow("Get: the value is not a registered Service")
			expect(function()
				Loren.Get(5)
			end).toThrow("Get: the value is not a registered Service")
		end)
	end)

	describe("client dependency rules", function()
		local function rec(name: string, deps: { string }): any
			return { name = name, kind = "Controller", module = { Name = name }, deps = deps }
		end

		it("resolves Controllers and proxies; an unknown name warns and gets a placeholder", function()
			-- 1.5.1 gave every Service a proxy: a Controller may list a Service without network members
			local controllers = {
				UI = rec("UI", { "Input", "Shop", "Shpo" }),
				Input = rec("Input", {}),
			}
			local shopProxy = { proxy = "Shop" }
			local report = Registry.newReport("Client")
			local resolved = Lifecycle._test.resolveClientDeps(
				report,
				controllers,
				{ "Input", "UI" },
				function(n: string)
					return if n == "Shop" then shopProxy else nil
				end,
				{ "Shop" }
			)
			expect(resolved.UI.Input).toBe(controllers.Input.module)
			expect(resolved.UI.Shop).toBe(shopProxy)
			expect(#report.errors).toBe(0)
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toBe(
				"UI.Dependencies: 'Shpo' is not a Controller or a networked Service "
					.. NOT_NETWORKED
					.. "; it resolves to a placeholder that raises when used. Did you mean 'Shop'?"
			)
			local placeholder = resolved.UI.Shpo
			expect(placeholder).never.toBeNil()
			expect(table.isfrozen(placeholder)).toBe(true)
			expect(function()
				return placeholder.GetData
			end).toThrow("UI.Dependencies.Shpo: 'Shpo' is not a Controller or a networked Service")
			expect(function()
				return placeholder.Signals
			end).toThrow("cannot be used on the client")
		end)

		it("a Controller and a proxy with the same name: error if depended on, else a warning", function()
			local both = { proxy = "Both" }
			local function getProxy(n: string): any
				return if n == "Both" or n == "Shared" then both else nil
			end
			local controllers = {
				Both = rec("Both", {}),
				Shared = rec("Shared", {}),
				User = rec("User", { "Both" }),
			}
			local report = Registry.newReport("Client")
			Lifecycle._test.resolveClientDeps(
				report,
				controllers,
				{ "Both", "Shared", "User" },
				getProxy,
				{ "Both", "Shared" }
			)
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("'Both' is both a Controller and a networked Service")
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("'Shared' is both a Controller and a networked Service")
		end)
	end)
end
