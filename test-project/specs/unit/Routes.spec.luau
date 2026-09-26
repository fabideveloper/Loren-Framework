--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Runtime = ReplicatedStorage.LorenRuntime
local Loren = require(Runtime) :: any
local C = require(Runtime.Constants)
local Codec = require(Runtime.Codec)
local Schema = require(Runtime.Schema)
local Manifest = require(Runtime.Manifest)
local Version = require(Runtime.Version)
local Routes = require(ServerScriptService.LorenServer.Routes)
local ServerSignal = require(ServerScriptService.LorenServer.ServerSignal)

local T = Schema.T
local K = C.Kind
local F = C.MemberFlag
local D = C.Default
local L = C.Limit

type MemberInput = { name: string, kind: number, spec: any?, middleware: any?, colon: boolean? }

local function noop() end

-- A resolved Config (C.Default plus overrides), like Config.get() returns.
local function config(overrides: { [string]: any }?): any
	local cfg: { [string]: any } = {}
	for k, v in D :: any do
		cfg[k] = v
	end
	cfg.Members = {}
	if overrides then
		for k, v in overrides do
			cfg[k] = v
		end
	end
	return cfg
end

local function newReport(): any
	return { side = "Server", errors = {}, warnings = {} }
end

-- A ServiceDecl: members sorted by (name, kind); Methods get a Client function.
local function service(name: string, members: { MemberInput }, extra: { [string]: any }?): any
	local list = {}
	local client: { [string]: any } = {}
	for _, m in members do
		local fn = if m.kind == K.Method then noop else nil
		table.insert(list, {
			name = m.name,
			kind = m.kind,
			fn = fn,
			middleware = m.middleware,
			colon = m.colon == true,
			spec = m.spec,
		})
		if fn then
			client[m.name] = fn
		end
	end
	table.sort(list, function(a: any, b: any): boolean
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.kind < b.kind
	end)
	local module: { [string]: any } = { Client = client }
	if extra then
		for k, v in extra do
			module[k] = v
		end
	end
	return {
		name = name,
		record = { name = name, kind = "Service", module = module, instance = script, path = name, deps = {} },
		module = module,
		client = client,
		members = list,
		networked = #list > 0,
	}
end

local function build(decls: { any }, overrides: { [string]: any }?): (any, any)
	local report = newReport()
	local rt = Routes.build(decls :: any, config(overrides), report)
	return rt, report
end

local function find(rt: any, fullName: string, kind: number?): any
	for _, r in rt.routes do
		if r.fullName == fullName and (kind == nil or r.kind == kind) then
			return r
		end
	end
	return nil
end

local function anyContains(list: { string }, needle: string): boolean
	for _, s in list do
		if string.find(s, needle, 1, true) then
			return true
		end
	end
	return false
end

-- `count` reliable Events named e00001.. (zero-padded: byte order = numeric order).
local function manyEvents(count: number): any
	local members: { MemberInput } = table.create(count) :: any
	for i = 1, count do
		members[i] = { name = string.format("e%05d", i), kind = K.Event }
	end
	return service("Gen", members)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.beforeAll(function()
		Loren.Testing.Reset({ Offline = true })
		Routes._reset()
		ServerSignal._reset()
	end)
	t.afterAll(function()
		Routes._reset()
		ServerSignal._reset()
		Loren.Testing.Reset()
	end)

	describe("numbering", function()
		it("sorts by (group, service, member, kind) and numbers 1..N", function()
			local a = service("A", {
				{ name = "m", kind = K.Method },
				{ name = "e", kind = K.Event },
				{ name = "u", kind = K.Event, spec = Schema.event(T.u8, { Unreliable = true }) },
				{ name = "s", kind = K.Signal },
				{ name = "us", kind = K.Signal, spec = Schema.signal(T.u8, { Unreliable = true }) },
			}, { Signals = {}, ClientEvents = {} })
			local b = service("B", {
				{ name = "a", kind = K.Method },
				{ name = "z", kind = K.Event, spec = Schema.event(T.u8, { Unreliable = true }) },
			}, { ClientEvents = {} })
			local rt, report = build({ b, a })
			expect(#report.errors).toBe(0)
			expect(rt).never.toBeNil()
			local order = {}
			for id, r in rt.routes do
				expect(r.id).toBe(id)
				order[id] = r.fullName
			end
			-- group 1 unreliable Events/Signals, 2 reliable Events, 3 reliable Signals, 4 Methods
			expect(order).toEqual({ "A.u", "A.us", "B.z", "A.e", "A.s", "A.m", "B.a" })
			expect(rt.count).toBe(7)
			expect(rt.services).toBe(2)
			expect(table.isfrozen(rt.routes)).toBe(true)
			expect(table.isfrozen(rt.routes[1])).toBe(true)
			expect(Routes.current()).toBe(rt)
		end)

		it("gives a Method and a Signal with the same name separate routes", function()
			local a = service("A", {
				{ name = "x", kind = K.Method },
				{ name = "x", kind = K.Signal },
			}, { Signals = {} })
			local rt, report = build({ a })
			expect(#report.errors).toBe(0)
			expect(find(rt, "A.x", K.Signal).id).toBe(1)
			expect(find(rt, "A.x", K.Method).id).toBe(2)
			local members = rt.model.services[1].members
			expect(members[1].kind).toBe(K.Method)
			expect(members[2].kind).toBe(K.Signal)
		end)

		it("uses 1/2/3-byte heads at routes 223/224/4063/4064", function()
			local rt, report = build({ manyEvents(4064) })
			expect(#report.errors).toBe(0)
			expect(rt.count).toBe(4064)
			for _, id in { 1, 223, 224, 4063, 4064 } do
				expect(rt.routes[id].fullName).toBe(string.format("Gen.e%05d", id))
			end
			local sizes = { [223] = 1, [224] = 2, [4063] = 2, [4064] = 3 }
			for id, size in sizes do
				expect(Codec.headSize(id)).toBe(size)
				local w = Codec.newWriter(8, false)
				Codec.writeHead(w, id)
				expect(w.n).toBe(size)
				local h, q = Codec.readHead(w.buf, 0, w.n)
				expect(h).toBe(id)
				expect(q).toBe(size)
			end
		end)

		it("fails with more than 65535 routes", function()
			local rt, report = build({ manyEvents(65536) })
			expect(rt).toBeNil()
			expect(anyContains(report.errors, "65535")).toBe(true)
		end)

		it("numbers deterministically", function()
			local function decls()
				return {
					service("Z", { { name = "b", kind = K.Method }, { name = "a", kind = K.Event } }),
					service("Y", { { name = "c", kind = K.Signal } }, { Signals = {} }),
				}
			end
			local rt1 = build(decls())
			local rt2 = build(decls())
			for id = 1, rt1.count do
				expect(rt1.routes[id].fullName).toBe(rt2.routes[id].fullName)
			end
			expect(buffer.tostring(rt1.manifestMsg)).toBe(buffer.tostring(rt2.manifestMsg))
		end)
	end)

	describe("options", function()
		it("applies the defaults", function()
			local a = service("A", {
				{ name = "m", kind = K.Method },
				{ name = "e", kind = K.Event },
				{ name = "u", kind = K.Event, spec = Schema.event(T.u8, { Unreliable = true }) },
				{ name = "s", kind = K.Signal },
			}, { Signals = {} })
			local rt = build({ a })
			local m, e, u = find(rt, "A.m"), find(rt, "A.e"), find(rt, "A.u")
			expect(m.timeout).toBe(D.DefaultTimeout)
			expect(m.rate).toBe(D.MethodRate)
			expect(m.burst).toBe(D.MethodBurst)
			expect(m.serial).toBe(false)
			expect(m.cancelOnTimeout).toBe(D.CancelOnTimeout)
			expect(e.rate).toBe(D.EventRate)
			expect(e.burst).toBe(D.EventBurst)
			expect(e.coalesce).toBe(false)
			expect(u.rate).toBe(D.UnreliableEventRate)
			expect(u.burst).toBe(D.UnreliableEventBurst)
			expect(u.coalesce).toBe(true) -- default on for unreliable Events
			local sm
			for _, mm in rt.model.services[1].members do
				if mm.name == "s" then
					sm = mm
				end
			end
			expect(sm.backlog).toBe(D.Backlog)
			expect(m.info.Service).toBe("A")
			expect(m.info.Member).toBe("m")
			expect(m.info.Kind).toBe("Method")
			expect(table.isfrozen(m.info)).toBe(true)
			expect(m.fn).toBe(noop)
			expect(e.fn).toBe(false)
			expect(m.middleware).toBe(false)
		end)

		it("takes Spec values over the defaults and Members over Spec", function()
			local spec = Schema.method({ Timeout = 2.34, RateLimit = { 5, 7 }, Serial = true, CancelOnTimeout = true })
			local a = service("A", {
				{ name = "m", kind = K.Method, spec = spec },
				{ name = "n", kind = K.Method, spec = spec },
				{ name = "e", kind = K.Event, spec = Schema.event({ RateLimit = { 3, 4 } }) },
			})
			local rt, report = build({ a }, {
				Members = {
					["A.n"] = {
						Timeout = 3.14,
						RateLimit = { 1, 2 },
						Serial = false,
						CancelOnTimeout = false,
						AllowNonFinite = true,
					},
					["A.e"] = { RateLimit = { 9, 10 } },
				},
			})
			expect(#report.errors).toBe(0)
			expect(#report.warnings).toBe(0)
			local m, n, e = find(rt, "A.m"), find(rt, "A.n"), find(rt, "A.e")
			expect(m.timeout).toBe(2.3)
			expect(m.rate).toBe(5)
			expect(m.burst).toBe(7)
			expect(m.serial).toBe(true)
			expect(m.cancelOnTimeout).toBe(true)
			expect(m.allowNonFinite).toBe(false)
			expect(n.timeout).toBe(3.1) -- rounded to the value the manifest ships
			expect(n.rate).toBe(1)
			expect(n.burst).toBe(2)
			expect(n.serial).toBe(false)
			expect(n.cancelOnTimeout).toBe(false)
			expect(n.allowNonFinite).toBe(true)
			expect(e.rate).toBe(9)
			expect(e.burst).toBe(10)
		end)

		it("honours Coalesce and Backlog from the Spec", function()
			local a = service("A", {
				{ name = "c", kind = K.Event, spec = Schema.event(T.u8, { Coalesce = true }) },
				{ name = "u", kind = K.Event, spec = Schema.event(T.u8, { Unreliable = true, Coalesce = false }) },
				{ name = "s", kind = K.Signal, spec = Schema.signal({ Backlog = 5 }) },
			}, { Signals = {} })
			local rt, report = build({ a })
			expect(#report.errors).toBe(0)
			expect(find(rt, "A.c").coalesce).toBe(true)
			expect(find(rt, "A.u").coalesce).toBe(false)
			for _, mm in rt.model.services[1].members do
				if mm.name == "c" then
					expect(bit32.btest(mm.flags, F.Coalesce)).toBe(true)
				elseif mm.name == "s" then
					expect(mm.backlog).toBe(5)
				elseif mm.name == "u" then
					expect(bit32.btest(mm.flags, F.Coalesce)).toBe(false)
					expect(bit32.btest(mm.flags, F.Unreliable)).toBe(true)
				end
			end
		end)

		it("warns about Members keys that name no Method or ClientEvent", function()
			local a = service("A", {
				{ name = "Buy", kind = K.Method },
				{ name = "Tick", kind = K.Signal },
			}, { Signals = {} })
			local rt, report = build({ a }, {
				Members = {
					["A.Buyy"] = { Timeout = 2 },
					["A.Tick"] = { Timeout = 2 },
					["Nope.X"] = { Timeout = 2 },
				},
			})
			expect(rt).never.toBeNil()
			expect(#report.errors).toBe(0)
			expect(#report.warnings).toBe(3)
			expect(anyContains(report.warnings, 'Members["A.Buyy"]')).toBe(true)
			expect(anyContains(report.warnings, "Did you mean 'A.Buy'?")).toBe(true)
			expect(anyContains(report.warnings, "does not apply to Signals")).toBe(true)
			expect(anyContains(report.warnings, 'Members["Nope.X"]')).toBe(true)
			expect(find(rt, "A.Buy").timeout).toBe(D.DefaultTimeout)
		end)
	end)

	describe("unreliable constraints", function()
		local cases: { { any } } = {
			{ "an untyped unreliable Event", Schema.event({ Unreliable = true }) },
			{ "an unreliable Event with T.any", Schema.event(T.any, { Unreliable = true }) },
			{ "an unreliable Event with T.Instance", Schema.event(T.Instance("Part"), { Unreliable = true }) },
			{ "a coalesced reliable Event with T.any", Schema.event(T.any, { Coalesce = true }) },
		}
		for _, case in cases do
			it("rejects " .. case[1], function()
				local a = service("A", { { name = "x", kind = K.Event, spec = case[2] } })
				local rt, report = build({ a })
				expect(rt).toBeNil()
				expect(#report.errors).toBe(1)
				expect(string.sub(report.errors[1], 1, 5)).toBe("A.x: ")
			end)
		end

		it("rejects an untyped unreliable Signal", function()
			local a = service("A", { { name = "s", kind = K.Signal, spec = Schema.signal({ Unreliable = true }) } })
			local rt, report = build({ a })
			expect(rt).toBeNil()
			expect(anyContains(report.errors, "A.s: ")).toBe(true)
		end)

		it("accepts typed unreliable and Ordered members", function()
			local a = service("A", {
				{
					name = "o",
					kind = K.Event,
					spec = Schema.event(T.u8, T.Vector3, { Unreliable = true, Ordered = true }),
				},
				{ name = "s", kind = K.Signal, spec = Schema.signal(T.u16, { Unreliable = true, Ordered = true }) },
			}, { Signals = {} })
			local rt, report = build({ a })
			expect(#report.errors).toBe(0)
			local o = find(rt, "A.o")
			expect(o.unreliable).toBe(true)
			expect(o.ordered).toBe(true)
			expect(o.args.typed).toBe(true)
			expect(o.args.count).toBe(2)
		end)
	end)

	describe("objects and maps", function()
		it("creates Signals / ClientEvents maps for every declaring module, networked or not", function()
			local quiet = service("Quiet", {}, { Signals = {}, ClientEvents = {} })
			local a = service("A", {
				{ name = "s", kind = K.Signal },
				{ name = "e", kind = K.Event },
			}, { Signals = {}, ClientEvents = {} })
			local rt, report = build({ quiet, a })
			expect(#report.errors).toBe(0)
			expect(rt.signals.Quiet).never.toBeNil()
			expect(rt.events.Quiet).never.toBeNil()
			expect(rt.services).toBe(1) -- only networked services are in the manifest
			local sig = rt.signals.A.s
			local ev = rt.events.A.e
			expect(find(rt, "A.s").signal).toBe(sig)
			expect(find(rt, "A.e").event).toBe(ev)
			expect(table.isfrozen(rt.signals.A)).toBe(true)
			expect(function()
				return (rt.signals.A :: any).missing
			end).toThrow("has no 'missing'")
			expect(function()
				(rt.events.A :: any).extra = true
			end).toThrow()
			expect(type(sig.Fire)).toBe("function")
			expect(function()
				sig:Connect(noop)
			end).toThrow("Service Signals are server-to-client")
		end)

		it("stores the member middleware and the colon flag", function()
			local function mw()
				return true
			end
			local a = service("A", {
				{ name = "m", kind = K.Method, middleware = mw },
				{ name = "c", kind = K.Method, middleware = mw, colon = true },
			})
			local rt = build({ a })
			expect(find(rt, "A.m").middleware).toBe(mw)
			expect(find(rt, "A.m").colon).toBe(false)
			expect(find(rt, "A.c").colon).toBe(true)
			expect(find(rt, "A.m").self).toBe(a.client)
		end)
	end)

	describe("manifest", function()
		it("ships a MANIFEST message that decodes to the model", function()
			local a = service("A", {
				{ name = "m", kind = K.Method, spec = Schema.method(T.u8, { Returns = { T.string }, Timeout = 4 }) },
				{ name = "e", kind = K.Event, spec = Schema.event(T.u8, { Unreliable = true, Ordered = true }) },
				{ name = "s", kind = K.Signal, spec = Schema.signal({ Backlog = 3 }) },
			}, { Signals = {} })
			local b = service("B", { { name = "x", kind = K.Method } })
			local rt, report = build({ b, a }, { MaxPending = 100, BacklogWindow = 7 })
			expect(#report.errors).toBe(0)
			local msg = rt.manifestMsg
			expect(buffer.readu8(msg, 0)).toBe(C.Op.MANIFEST)
			local len = buffer.readu32(msg, 1)
			expect(buffer.len(msg)).toBe(5 + len)
			local model, reason = Manifest.decode(msg, 5, 5 + len)
			expect(reason).toBeNil()
			assert(model, "decoded")
			expect(model.proto).toBe(C.PROTO)
			expect(model.version).toBe(Version.Version)
			expect(model.limits.maxPending).toBe(100)
			expect(model.limits.backlogWindow).toBe(7)
			expect(model.limits.maxArgs).toBe(L.MAX_ARGS_C2S)
			expect(#model.services).toBe(2)
			expect(model.services[1].name).toBe("A")
			expect(model.services[2].name).toBe("B")
			for si, s in model.services do
				local ref = rt.model.services[si]
				expect(#s.members).toBe(#ref.members)
				for mi, m in s.members do
					local r = ref.members[mi]
					expect(m.name).toBe(r.name)
					expect(m.kind).toBe(r.kind)
					expect(m.route).toBe(r.route)
					expect(m.flags).toBe(r.flags)
					expect(m.timeout).toBe(r.timeout)
					expect(m.backlog).toBe(r.backlog)
					expect(rt.routes[m.route].member).toBe(m.name)
				end
			end
			local am = model.services[1].members
			-- A: e (Event), m (Method), s (Signal) by name
			expect(am[1].name).toBe("e")
			expect(bit32.btest(am[1].flags, F.Ordered)).toBe(true)
			expect(am[2].timeout).toBe(4)
			expect(bit32.btest(am[2].flags, F.HasArgs)).toBe(true)
			expect(bit32.btest(am[2].flags, F.HasReturns)).toBe(true)
			expect(am[3].backlog).toBe(3)
		end)

		it("dump returns a deep, mutable copy", function()
			local rt = build({ service("A", { { name = "m", kind = K.Method } }) })
			local copy = Routes.dump()
			expect(copy).never.toBe(rt.model)
			expect(table.isfrozen(copy)).toBe(false)
			expect(copy.services[1].members[1].name).toBe("m")
			copy.services[1].name = "Changed"
			expect(rt.model.services[1].name).toBe("A")
		end)

		it("dump raises before a build and current() is nil after _reset", function()
			Routes._reset()
			expect(Routes.current()).toBeNil()
			expect(function()
				Routes.dump()
			end).toThrow("DumpManifest")
		end)
	end)
end
