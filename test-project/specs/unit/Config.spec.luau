--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = ReplicatedStorage:WaitForChild("LorenRuntime")
local Loren = require(Runtime) :: any
local C = require(Runtime:WaitForChild("Constants")) :: any
local Config = require(Runtime:WaitForChild("Config")) :: any
local Log = require(Runtime:WaitForChild("Log")) :: any
local Registry = require(Runtime:WaitForChild("Registry")) :: any

local NAN = 0 / 0
local INF = math.huge

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local beforeAll, afterAll, beforeEach, afterEach = t.beforeAll, t.afterAll, t.beforeEach, t.afterEach

	local warnings: { string } = {}

	local function set(tbl: any): (boolean, string)
		local ok, err = pcall(function()
			Loren.Configure(tbl)
		end)
		return ok, if ok then "" else tostring(err)
	end

	beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
	end)

	afterAll(function()
		Loren.Testing.Reset()
	end)

	beforeEach(function()
		Config._reset()
		Log._reset()
		table.clear(warnings)
		Log._test.setStudio(true)
		Log._test.setSink(function() end, function(line: string)
			table.insert(warnings, line)
		end)
	end)

	afterEach(function()
		Config._reset()
		Log._reset()
	end)

	-- Key -> { good values..., bad = { bad values... } } (bad always includes NaN/inf for numbers).
	local NUMBER_BAD: { any } = { NAN, INF, -INF, "1", true }
	local cases: { [string]: { good: { any }, bad: { any } } } = {
		FrameRate = { good = { 0.5, 1, 1000 }, bad = { 0, -1 } },
		FrameBurst = { good = { 1, 1.5, 500 }, bad = { 0, 0.99 } },
		ByteRate = { good = { 1, 131072 }, bad = { 0, -5 } },
		ByteBurst = { good = { 1, 262144 }, bad = { 0, 0.5 } },
		MessageRate = { good = { 1, 600 }, bad = { 0 } },
		MessageBurst = { good = { 1, 600 }, bad = { 0 } },
		MethodRate = { good = { 0.1, 50 }, bad = { 0 } },
		MethodBurst = { good = { 1, 100 }, bad = { 0.9 } },
		EventRate = { good = { 0.1, 75 }, bad = { 0 } },
		EventBurst = { good = { 1, 150 }, bad = { 0 } },
		UnreliableEventRate = { good = { 0.1, 120 }, bad = { 0 } },
		UnreliableEventBurst = { good = { 1, 60 }, bad = { 0 } },
		MirrorFraction = { good = { 0.01, 0.5, 1 }, bad = { 0, 1.01, -0.5 } },
		MaxRunningCalls = { good = { 1, 32, 1000 }, bad = { 0, 1.5, -1 } },
		MaxQueuedCalls = { good = { 0, 64, 1024 }, bad = { -1, 2.5, 1025 } },
		MaxZombies = { good = { 1, 16 }, bad = { 0, 1.5 } },
		MaxZombiesPerRoute = { good = { 1, 4 }, bad = { 0, 3.5 } },
		SerialQueue = { good = { 0, 8, 1024 }, bad = { -1, 0.5, 1025 } },
		MaxPending = { good = { 1, 256, 4096 }, bad = { 0, 4097, 10.5 } },
		DefaultTimeout = { good = { 1, 10, 120 }, bad = { 0.99, 0, 121 } },
		WatchdogGrace = { good = { 0, 5, 0.5, 30 }, bad = { -0.1, 30.5 } },
		Backlog = { good = { 0, 64, 1024 }, bad = { -1, 1025, 1.5 } },
		BacklogWindow = { good = { 0, 10, 255 }, bad = { -1, 256, 2.5 } },
	}
	local BOOLEAN_KEYS = { "CancelOnTimeout", "StrictCycles", "CycleWarnings", "InlineTables", "MiddlewareArityCheck" }
	local SERVER_KEYS = {
		"FrameRate",
		"FrameBurst",
		"ByteRate",
		"ByteBurst",
		"MessageRate",
		"MessageBurst",
		"MethodRate",
		"MethodBurst",
		"EventRate",
		"EventBurst",
		"UnreliableEventRate",
		"UnreliableEventBurst",
		"MirrorFraction",
		"MaxRunningCalls",
		"MaxQueuedCalls",
		"MaxZombies",
		"MaxZombiesPerRoute",
		"SerialQueue",
		"MaxPending",
		"DefaultTimeout",
		"WatchdogGrace",
		"CancelOnTimeout",
		"Backlog",
		"BacklogWindow",
		"ForwardErrors",
		"MiddlewareArityCheck",
		"KickScore",
	}

	describe("defaults", function()
		it("resolve every key to C.Default plus an empty Members", function()
			local cfg = Config.get()
			local n = 0
			for key, value in C.Default do
				expect(cfg[key]).toBe(value)
				n += 1
			end
			expect(n).toBe(32)
			expect(cfg.Members).toEqual({})
		end)

		it("match the section 6 table", function()
			local cfg = Config.get()
			expect(cfg.FrameRate).toBe(120)
			expect(cfg.FrameBurst).toBe(140)
			expect(cfg.ByteRate).toBe(131072)
			expect(cfg.ByteBurst).toBe(262144)
			expect(cfg.MessageRate).toBe(600)
			expect(cfg.MessageBurst).toBe(600)
			expect(cfg.MethodRate).toBe(50)
			expect(cfg.MethodBurst).toBe(100)
			expect(cfg.EventRate).toBe(75)
			expect(cfg.EventBurst).toBe(150)
			expect(cfg.UnreliableEventRate).toBe(120)
			expect(cfg.UnreliableEventBurst).toBe(60)
			expect(cfg.MirrorFraction).toBe(0.9)
			expect(cfg.MaxRunningCalls).toBe(32)
			expect(cfg.MaxQueuedCalls).toBe(64)
			expect(cfg.MaxZombies).toBe(16)
			expect(cfg.MaxZombiesPerRoute).toBe(4)
			expect(cfg.SerialQueue).toBe(8)
			expect(cfg.MaxPending).toBe(256)
			expect(cfg.DefaultTimeout).toBe(10)
			expect(cfg.WatchdogGrace).toBe(5)
			expect(cfg.CancelOnTimeout).toBe(false)
			expect(cfg.Backlog).toBe(64)
			expect(cfg.BacklogWindow).toBe(10)
			expect(cfg.ForwardErrors).toBe("Studio")
			expect(cfg.StrictCycles).toBe(false)
			expect(cfg.CycleWarnings).toBe(false)
			expect(cfg.InlineTables).toBe(true)
			expect(cfg.MiddlewareArityCheck).toBe(true)
			expect(cfg.KickScore).toBe(false)
			expect(cfg.IgniteTimeout).toBe(false)
			expect(cfg.PromiseTraces).toBe("Studio")
		end)
	end)

	describe("numeric keys", function()
		for key, case in cases do
			it(key .. " accepts its range", function()
				for _, v in case.good do
					Config._reset()
					local ok, err = set({ [key] = v })
					expect(err).toBe("")
					expect(ok).toBe(true)
					if key == "DefaultTimeout" then
						expect(Config.get()[key]).toBe(math.round(v * 10) / 10)
					else
						expect(Config.get()[key]).toBe(v)
					end
				end
			end)

			it(key .. " rejects out-of-range, non-finite and wrong-type values", function()
				local bad = table.clone(case.bad)
				table.move(NUMBER_BAD, 1, #NUMBER_BAD, #bad + 1, bad)
				for _, v in bad do
					local ok, err = set({ [key] = v })
					expect(ok).toBe(false)
					expect(err).toContain("(LORENঌ) Configure: " .. key .. " must be")
					expect(Config.get()[key]).toBe(C.Default[key])
				end
			end)
		end

		it("rounds DefaultTimeout to 0.1 s", function()
			set({ DefaultTimeout = 2.34 })
			expect(Config.get().DefaultTimeout).toBe(2.3)
			set({ DefaultTimeout = 119.96 })
			expect(Config.get().DefaultTimeout).toBe(120)
		end)
	end)

	describe("boolean and enum keys", function()
		for _, key in BOOLEAN_KEYS do
			it(key .. " takes booleans only", function()
				expect((set({ [key] = not C.Default[key] }))).toBe(true)
				expect(Config.get()[key]).toBe(not C.Default[key])
				for _, v in { 1, "true", NAN } :: { any } do
					local ok, err = set({ [key] = v })
					expect(ok).toBe(false)
					expect(err).toContain(key .. " must be a boolean")
				end
			end)
		end

		it("ForwardErrors takes Studio, Never or Always", function()
			for _, v in { "Studio", "Never", "Always" } do
				expect((set({ ForwardErrors = v }))).toBe(true)
				expect(Config.get().ForwardErrors).toBe(v)
			end
			for _, v in { "studio", "", 1, true } :: { any } do
				expect((set({ ForwardErrors = v }))).toBe(false)
			end
		end)

		it("PromiseTraces takes Studio, Always or Never (client key)", function()
			for _, v in { "Studio", "Always", "Never" } do
				expect((set({ PromiseTraces = v }))).toBe(true)
			end
			for _, v in { "never", 0, false } :: { any } do
				expect((set({ PromiseTraces = v }))).toBe(false)
			end
		end)

		it("KickScore takes false or a number > 0", function()
			expect((set({ KickScore = 50 }))).toBe(true)
			expect(Config.get().KickScore).toBe(50)
			expect((set({ KickScore = false }))).toBe(true)
			expect(Config.get().KickScore).toBe(false)
			for _, v in { 0, -1, true, NAN, INF } :: { any } do
				expect((set({ KickScore = v }))).toBe(false)
			end
		end)

		it("IgniteTimeout takes false or a number > 0", function()
			expect((set({ IgniteTimeout = 0.5 }))).toBe(true)
			expect(Config.get().IgniteTimeout).toBe(0.5)
			expect((set({ IgniteTimeout = false }))).toBe(true)
			for _, v in { 0, -2, true, NAN, INF, "5" } :: { any } do
				expect((set({ IgniteTimeout = v }))).toBe(false)
			end
		end)
	end)

	describe("sides (running on the server)", function()
		it("applies server-only and both-side keys", function()
			for _, key in SERVER_KEYS do
				local cfg = Config.get()
				expect(cfg[key]).toBe(C.Default[key])
			end
			set({ FrameRate = 10, StrictCycles = true, InlineTables = false, IgniteTimeout = 3 })
			local cfg = Config.get()
			expect(cfg.FrameRate).toBe(10)
			expect(cfg.StrictCycles).toBe(true)
			expect(cfg.InlineTables).toBe(false)
			expect(cfg.IgniteTimeout).toBe(3)
			expect(#warnings).toBe(0)
		end)

		it("ignores the client-only key with one Studio warning", function()
			expect((set({ PromiseTraces = "Never" }))).toBe(true)
			expect(Config.get().PromiseTraces).toBe("Studio")
			set({ PromiseTraces = "Always" })
			expect(#warnings).toBe(1)
			expect(warnings[1]).toContain("PromiseTraces is a client-only key")
			expect(string.sub(warnings[1], 1, #C.PREFIX)).toBe(C.PREFIX)
		end)
	end)

	describe("set", function()
		it("merges keys across calls", function()
			set({ FrameRate = 10 })
			set({ ByteRate = 20 })
			local cfg = Config.get()
			expect(cfg.FrameRate).toBe(10)
			expect(cfg.ByteRate).toBe(20)
		end)

		it("changes nothing when one key is bad (atomic)", function()
			local ok = set({ FrameRate = 10, FrameBurst = 0 })
			expect(ok).toBe(false)
			expect(Config.get().FrameRate).toBe(120)
		end)

		it("rejects unknown keys with a suggestion", function()
			local ok, err = set({ FrameRAte = 1 })
			expect(ok).toBe(false)
			expect(err).toContain("unknown key 'FrameRAte'")
			expect(err).toContain("Did you mean 'FrameRate'?")
			local ok2, err2 = set({ members = {} })
			expect(ok2).toBe(false)
			expect(err2).toContain("Did you mean 'Members'?")
			local ok3, err3 = set({ Totally = 1 })
			expect(ok3).toBe(false)
			expect(err3).toContain("unknown key 'Totally'")
		end)

		it("rejects non-table input and non-string keys", function()
			expect((set(5))).toBe(false)
			expect((set(nil))).toBe(false)
			local ok, err = set({ [1] = 5 })
			expect(ok).toBe(false)
			expect(err).toContain("keys must be strings")
		end)

		it("points the error at the caller's line", function()
			local _, err = set({ Bogus = true })
			expect(err).toContain("Config.spec")
		end)

		it("works with the colon form", function()
			local ok = pcall(function()
				Loren:Configure({ FrameRate = 33 })
			end)
			expect(ok).toBe(true)
			expect(Config.get().FrameRate).toBe(33)
		end)
	end)

	describe("freeze", function()
		it("makes get() read-only with a stable identity", function()
			local before = Config.get()
			set({ FrameRate = 11 })
			expect(Config.get()).toBe(before)
			expect(Config.isFrozen()).toBe(false)
			Config.freeze()
			expect(Config.isFrozen()).toBe(true)
			expect(Config.get()).toBe(before)
			expect(table.isfrozen(Config.get())).toBe(true)
			expect(table.isfrozen(Config.get().Members)).toBe(true)
			expect(Config.get().FrameRate).toBe(11)
		end)

		it("rejects Configure after SetOnFire", function()
			Config.freeze()
			local ok, err = set({ FrameRate = 1 })
			expect(ok).toBe(false)
			expect(err).toContain("Configure must be called before SetOnFire")
		end)

		it("_reset restores the defaults, unfrozen, in a new table", function()
			local old = Config.get()
			set({ FrameRate = 1 })
			Config.freeze()
			Config._reset()
			expect(Config.isFrozen()).toBe(false)
			expect(Config.get()).never.toBe(old)
			expect(Config.get().FrameRate).toBe(120)
		end)
	end)

	describe("Members", function()
		it("stores frozen overrides and member() finds them", function()
			local ok, err = set({
				Members = {
					["Shop.Buy"] = { RateLimit = { 5, 10 }, Timeout = 30, Serial = true },
					["Shop.Ping"] = { CancelOnTimeout = true, AllowNonFinite = false },
				},
			})
			expect(err).toBe("")
			expect(ok).toBe(true)
			local buy = Config.member("Shop", "Buy")
			expect(buy.RateLimit).toEqual({ 5, 10 })
			expect(buy.Timeout).toBe(30)
			expect(buy.Serial).toBe(true)
			expect(table.isfrozen(buy)).toBe(true)
			expect(table.isfrozen(buy.RateLimit)).toBe(true)
			expect(Config.member("Shop", "Ping").CancelOnTimeout).toBe(true)
			expect(Config.member("Shop", "Nope")).toBeNil()
		end)

		it("merges Members across calls", function()
			set({ Members = { ["A.X"] = { Timeout = 5 } } })
			set({ Members = { ["B.Y"] = { Timeout = 6 } } })
			expect(Config.member("A", "X").Timeout).toBe(5)
			expect(Config.member("B", "Y").Timeout).toBe(6)
		end)

		it("rounds Timeout and checks its range", function()
			set({ Members = { ["A.X"] = { Timeout = 2.26 } } })
			expect(Config.member("A", "X").Timeout).toBe(2.3)
			for _, v in { 0.5, 121, NAN, INF, "5" } :: { any } do
				local ok, err = set({ Members = { ["A.Y"] = { Timeout = v } } })
				expect(ok).toBe(false)
				expect(err).toContain(".Timeout must be")
			end
		end)

		it("checks RateLimit", function()
			for _, v in
				{ { 5 }, { 0, 10 }, { 5, 0.5 }, { 5, 10, 15 }, { NAN, 10 }, { 5, INF }, 5, { a = 1, b = 2 } } :: { any }
			do
				local ok, err = set({ Members = { ["A.X"] = { RateLimit = v } } })
				expect(ok).toBe(false)
				expect(err).toContain("RateLimit must be")
			end
		end)

		it("checks boolean overrides", function()
			for _, key in { "Serial", "CancelOnTimeout", "AllowNonFinite" } do
				local ok, err = set({ Members = { ["A.X"] = { [key] = 1 } } })
				expect(ok).toBe(false)
				expect(err).toContain(key .. " must be a boolean")
			end
		end)

		it("rejects unknown override keys, bad member keys and non-tables", function()
			local ok, err = set({ Members = { ["A.X"] = { Rate = 5 } } })
			expect(ok).toBe(false)
			expect(err).toContain("is not an override key")
			local ok2, err2 = set({ Members = { Buy = { Timeout = 5 } } })
			expect(ok2).toBe(false)
			expect(err2).toContain('"Service.Member"')
			expect((set({ Members = { ["A.X"] = 5 } }))).toBe(false)
			expect((set({ Members = 5 }))).toBe(false)
		end)

		it("a bad Members entry changes nothing", function()
			set({ Members = { ["A.X"] = { Timeout = 5 } } })
			expect((set({ Members = { ["A.Y"] = { Timeout = 5 }, ["A.Z"] = { Timeout = 0 } } }))).toBe(false)
			expect(Config.member("A", "Y")).toBeNil()
			expect(Config.member("A", "X").Timeout).toBe(5)
		end)
	end)

	describe("check (SetOnFire cross-checks)", function()
		it("passes with the defaults", function()
			local report = Registry.newReport("Server")
			Config.check(report)
			expect(report.errors).toEqual({})
			expect(report.warnings).toEqual({})
		end)

		it("needs ByteBurst * MirrorFraction >= 131072", function()
			set({ ByteBurst = 131072, MirrorFraction = 0.9 })
			local report = Registry.newReport("Server")
			Config.check(report)
			expect(#report.errors).toBe(1)
			expect(report.errors[1]).toContain("ByteBurst * MirrorFraction")
			Config._reset()
			set({ ByteBurst = 131072, MirrorFraction = 1 })
			local ok = Registry.newReport("Server")
			Config.check(ok)
			expect(#ok.errors).toBe(0)
		end)

		it("needs FrameBurst and MessageBurst * MirrorFraction >= 1", function()
			set({ FrameBurst = 1, MessageBurst = 1, MirrorFraction = 0.5, ByteBurst = 1000000 })
			local report = Registry.newReport("Server")
			Config.check(report)
			expect(#report.errors).toBe(2)
			expect(report.errors[1]).toContain("FrameBurst * MirrorFraction")
			expect(report.errors[2]).toContain("MessageBurst * MirrorFraction")
		end)

		it('warns about ForwardErrors = "Always"', function()
			set({ ForwardErrors = "Always" })
			local report = Registry.newReport("Server")
			Config.check(report)
			expect(#report.errors).toBe(0)
			expect(#report.warnings).toBe(1)
			expect(report.warnings[1]).toContain("ForwardErrors")
		end)
	end)
end
