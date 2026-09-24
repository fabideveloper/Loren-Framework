--!strict
--!optimize 2
--[[
	Lifecycle (owner lane: lifecycle): the boot and shutdown state machine on both sides, dependency
	injection and readiness.
	Spec: IMPLEMENTATION.md sections 3.11 and 8; robust.md section 5; compat.md section 5.2.

	- SetOnFire creates one root Promise (with an internal :catch, held strongly so a caller's
	  :cancel() can never cancel it) and runs the boot on a plain thread. Callers get
	  `root:andThen()` children that resolve with Loren at Ready or reject with the report text.
	- Every problem found before the first Ignite goes into one report; a failure at any step tears
	  the network down (Transport.fail / ClientNet.fail), sets State = "Failed", prints the report red
	  with task.spawn(error, text, 0) (even when nobody handles the Promise), then rejects the root.
	- Ignite runs in dependency order on its own thread under xpcall; a yielding Ignite is waited for
	  (the boot thread is resumed exactly once) with warnings, and IgniteTimeout can fail it.
	- This module is the only writer of Loren.IsOnFire, Loren.IsReady and Loren.State.
	- `_reset` (Testing.Reset) bumps a generation counter: every thread of an older boot stops
	  touching state when it resumes.
	No side effects on require.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local Log = require(script.Parent.Log)
local Registry = require(script.Parent.Registry)
local Topo = require(script.Parent.Topo)
local Signal = require(script.Parent.Signal)
local ClientNet = require(script.Parent.ClientNet)
local Proxy = require(script.Parent.Proxy)

-- ReplicatedStorage.LorenPackages.Promise (WaitForChild only matters on a still-replicating client).
local Promise: any = require(ReplicatedStorage:WaitForChild("LorenPackages"):WaitForChild("Promise"))

type Report = Types.Report
type ModuleRecord = Types.ModuleRecord

type BootCtx = {
	report: Report,
	S: any, -- the LorenServer index (server)
	claimed: boolean, -- Transport.claim succeeded (so Transport.fail applies)
}

local PREFIX = C.PREFIX
local STATE = C.State
local IS_SERVER = RunService:IsServer()
local NOT_NETWORKED = "(a Service is networked when it has a Client method, ClientEvent or Signal)"

local function defaultErrorSink(text: string)
	task.spawn(error :: any, text, 0)
end

-- Bound by the facade --------------------------------------------------------------------------------
local loren: any = nil
local serverLoader: ((peek: boolean?) -> any)? = nil

-- Test hooks (set through _test, restored by _reset) -----------------------------------------------
local testServer: ((peek: boolean?) -> any)? = nil
local errorSink: (string) -> () = defaultErrorSink
local igniteWarnAfter: number = C.Limit.IGNITE_WARN
local shutdownBudget: number = C.Limit.SHUTDOWN_BUDGET

-- Boot state -----------------------------------------------------------------------------------------
local state: string = STATE.Idle
local gen = 0 -- bumped by _reset; a thread from an older boot compares and stops
local offlineFlag = false
local root: any = nil -- the one boot Promise
local rootGuard: any = nil -- its internal :catch consumer (Promise consumers are weak keys: keep it alive)
local rootResolve: ((...any) -> ())? = nil
local rootReject: ((...any) -> ())? = nil
local bootThread: thread? = nil
local netUp = false -- server: Transport prepared; client: connected with a manifest
local manifestReady = false -- client: proxies built
local igniteOrder: { string } = {}
local bootServer: any = nil -- the server index used by the boot (for shutdown)
local timers: { [thread]: boolean } = {} -- Ignite warning/timeout timers (cancelled by _reset)

local Lifecycle = {}

local function noop() end

local function setState(s: string)
	state = s
	if loren then
		loren.State = s
	end
end

local function ensureRoot(): any
	if root == nil then
		local resolveFn: any, rejectFn: any = nil, nil
		root = Promise.new(function(resolve: any, reject: any)
			resolveFn = resolve
			rejectFn = reject
		end)
		rootResolve = resolveFn
		rootReject = rejectFn
		rootGuard = root:catch(noop)
	end
	return root
end

-- xpcall handler: "<error>\n<traceback>" (any error value, including a Loren.Reject table).
local function traceback(err: any): string
	local text: string
	if type(err) == "string" then
		text = err
	else
		local ok, s = pcall(tostring, err)
		text = if ok and type(s) == "string" then s else "<" .. typeof(err) .. " error>"
	end
	local trace = debug.traceback(nil, 2)
	return text .. "\n" .. (string.gsub(trace, "\n+$", ""))
end

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

local function cycleReport(report: Report, cycles: { string }, strict: boolean)
	for _, cycle in cycles do
		if strict then
			table.insert(report.errors, "Dependency cycle: " .. cycle .. " (StrictCycles is on)")
		else
			table.insert(
				report.warnings,
				"Dependency cycle: " .. cycle .. " (allowed; inside a cycle, Ignite and Burn run in name order)"
			)
		end
	end
end

-- The server index: the _test override, else the facade's lazy loader.
function Lifecycle.server(peek: boolean?): any
	if testServer then
		return testServer(peek)
	end
	if serverLoader then
		return serverLoader(peek)
	end
	if peek then
		return nil
	end
	error(PREFIX .. "Loren is not bound: require ReplicatedStorage.LorenRuntime", 2)
end

-- Failure ---------------------------------------------------------------------------------------------

local function finishFailed(report: Report)
	netUp = false
	setState(STATE.Failed)
	if loren then
		loren.IsReady = false
	end
	if #report.errors == 0 then
		table.insert(report.errors, "the boot failed without a reason")
	end
	local text = Registry.format(report, true)
	-- Print before rejecting (as step 10 prints before resolving): the Promise library runs rejection
	-- handlers and resumes :await() threads synchronously inside reject, so anything after it runs
	-- after the failure was already observed. Under pcall, so a failing sink can never leave the root
	-- pending (the default sink's task.spawn(error) reports on its own thread either way).
	local sinkOk, sinkErr = pcall(errorSink :: any, text)
	if not sinkOk then
		Log.warn("the boot-failure error sink failed: " .. tostring(sinkErr))
	end
	if rootReject then
		rootReject(text)
	end
end

local function failServer(ctx: BootCtx, myGen: number, reason: string?)
	if myGen ~= gen or state ~= STATE.Booting then
		return
	end
	if reason then
		table.insert(ctx.report.errors, reason)
	end
	-- Transport.fail is safe at any step (section 8.2), also before or after a refused claim.
	if ctx.S ~= nil then
		local ok, e = pcall(function()
			ctx.S.Transport.fail()
		end)
		if not ok then
			table.insert(ctx.report.errors, "Transport.fail failed: " .. tostring(e))
		end
	end
	finishFailed(ctx.report)
end

local function failClient(ctx: BootCtx, myGen: number, reason: string?)
	if myGen ~= gen or state ~= STATE.Booting then
		return
	end
	if reason then
		table.insert(ctx.report.errors, reason)
	end
	local ok, e = pcall(ClientNet.fail :: any)
	if not ok then
		table.insert(ctx.report.errors, "ClientNet.fail failed: " .. tostring(e))
	end
	finishFailed(ctx.report)
end

-- Hooks -----------------------------------------------------------------------------------------------

-- Runs module:LorenIgnite() on its own thread. Returns nil on success or the failure text. If the
-- hook yields, the boot thread parks until it ends (resumed exactly once, never after a reset).
local function ignite(label: string, rec: ModuleRecord, myGen: number): string?
	local module = rec.module
	local fn = Registry.field(module, "LorenIgnite")
	if fn == nil then
		return nil
	end
	local done = false
	local ok = true
	local errText = ""
	local waiting: thread? = nil
	local resumed = false
	local function wake()
		if waiting and not resumed and myGen == gen then
			resumed = true
			task.defer(waiting)
		end
	end
	local worker = task.spawn(function()
		local success, e = xpcall(fn, traceback, module)
		done = true
		if not success then
			ok = false
			errText = e
		end
		wake()
	end)
	if not done then
		Log.warn(rec.name .. ":LorenIgnite yielded; the boot waits for it (move yielding work to LorenBurn)")
		local timedOut = false
		local limit = Config.get().IgniteTimeout
		local warnTimer = task.delay(igniteWarnAfter, function()
			if not done and myGen == gen then
				Log.warn(
					string.format(
						"%s:LorenIgnite is still running after %g s; the boot is waiting for it",
						rec.name,
						igniteWarnAfter
					)
				)
			end
		end)
		timers[warnTimer] = true
		local limitTimer: thread? = nil
		if type(limit) == "number" then
			limitTimer = task.delay(limit, function()
				if not done and myGen == gen then
					timedOut = true
					pcall(task.cancel, worker)
					wake()
				end
			end)
			timers[limitTimer :: thread] = true
		end
		waiting = coroutine.running()
		while not resumed do
			coroutine.yield()
		end
		timers[warnTimer] = nil
		pcall(task.cancel, warnTimer)
		if limitTimer then
			timers[limitTimer] = nil
			pcall(task.cancel, limitTimer)
		end
		if timedOut then
			return string.format(
				"%s '%s': LorenIgnite did not finish within IgniteTimeout (%g s); its thread was cancelled",
				label,
				rec.name,
				limit :: number
			)
		end
	end
	if ok then
		return nil
	end
	return string.format("%s '%s': LorenIgnite failed: %s", label, rec.name, errText)
end

local function burnBody(label: string, rec: ModuleRecord, fn: any)
	local ok, e = xpcall(fn, traceback, rec.module)
	if not ok then
		Log.warn(string.format("%s '%s': LorenBurn failed: %s", label, rec.name, tostring(e)))
	end
end

-- Spawns every LorenBurn in order; errors are logged per module and never fail the boot.
local function burnAll(label: string, map: { [string]: ModuleRecord }, order: { string })
	for _, name in order do
		local rec = map[name]
		local fn = Registry.field(rec.module, "LorenBurn")
		if fn ~= nil then
			task.spawn(burnBody, label, rec, fn)
		end
	end
end

type Tracker = { pending: number, running: { [string]: boolean } }

local function extinguishBody(track: Tracker, rec: ModuleRecord, fn: any)
	local ok, e = xpcall(fn, traceback, rec.module)
	if not ok then
		Log.warn(string.format("Service '%s': LorenExtinguish failed: %s", rec.name, tostring(e)))
	end
	track.pending -= 1
	track.running[rec.name] = nil
end

-- BindToClose (section 8.5): ShuttingDown, NOTICE, LorenExtinguish in reverse order (all started at
-- once, up to SHUTDOWN_BUDGET), then a final flush.
local function shutdown(myGen: number)
	if myGen ~= gen or state ~= STATE.Ready then
		return
	end
	setState(STATE.ShuttingDown)
	local S = bootServer
	if S ~= nil then
		local ok, e = pcall(function()
			S.Transport.shutdown()
		end)
		if not ok then
			Log.warn("Transport.shutdown failed: " .. tostring(e))
		end
	end
	local services = Registry.records("Service")
	local track: Tracker = { pending = 0, running = {} }
	for i = #igniteOrder, 1, -1 do
		local rec = services[igniteOrder[i]]
		local fn = if rec then Registry.field(rec.module, "LorenExtinguish") else nil
		if rec and fn ~= nil then
			track.pending += 1
			track.running[rec.name] = true
			task.spawn(extinguishBody, track, rec, fn)
		end
	end
	local deadline = os.clock() + shutdownBudget
	while track.pending > 0 and os.clock() < deadline do
		task.wait()
	end
	if track.pending > 0 then
		local names: { string } = {}
		for name in track.running do
			table.insert(names, name)
		end
		table.sort(names)
		Log.warn(
			string.format(
				"Shutdown budget (%g s) passed; LorenExtinguish still running in %s",
				shutdownBudget,
				table.concat(names, ", ")
			)
		)
	end
	if S ~= nil and myGen == gen then
		local ok, e = pcall(function()
			S.Transport.flushNow()
		end)
		if not ok then
			Log.warn("final flush failed: " .. tostring(e))
		end
	end
end

local function printBoot(line: string, report: Report)
	Log.info(line)
	local warnings = Registry.format(report, false)
	if warnings ~= "" then
		Log.warn(string.sub(warnings, #PREFIX + 1)) -- Log adds the prefix
	end
end

-- Server boot (section 8.2) ---------------------------------------------------------------------------

local function serverSteps(ctx: BootCtx, myGen: number, started: number)
	-- Step 1 (Config.freeze, Registry.lock, State = Booting) ran in setOnFire.
	local offline = offlineFlag or not RunService:IsRunning()
	local S = Lifecycle.server()
	ctx.S = S
	bootServer = S

	-- 2. Claim ReplicatedStorage.LorenNet (State = "Booting") before anything else.
	local claimed, reason = S.Transport.claim(offline)
	if not claimed then
		return failServer(ctx, myGen, reason or "Transport.claim failed")
	end
	ctx.claimed = true

	-- 3. Validate everything into one report.
	local report = ctx.report
	local cfg = Config.get()
	Config.check(report)
	Registry.checkModules(report, "Service")
	local decls = Registry.buildServices(report, cfg)

	-- 4. Dependencies and the Ignite order.
	local services = Registry.records("Service")
	local names = Registry.names("Service")
	local resolvedOf: { [string]: { [string]: any } } = {}
	for _, name in names do
		local resolved: { [string]: any } = {}
		for _, dep in services[name].deps do
			local target = services[dep]
			if target then
				resolved[dep] = target.module
			elseif not Registry.isFailed("Service", dep) then
				table.insert(
					report.errors,
					string.format("%s.Dependencies: '%s' is not a registered Service.", name, dep)
						.. Registry.suggestion(dep, names, "Services")
				)
			end
		end
		resolvedOf[name] = resolved
	end
	local order, cycles = Topo.order(names, function(name: string): { string }
		return services[name].deps
	end)
	cycleReport(report, cycles, cfg.StrictCycles)

	-- 5. Limits and routes; any error so far fails the boot with the whole report.
	S.Limits.configure(cfg)
	S.Violations.configure(cfg)
	local rt = S.Routes.build(decls, cfg, report)
	if myGen ~= gen then
		return
	end
	if #report.errors > 0 or rt == nil then
		return failServer(ctx, myGen)
	end

	-- 6. Inject declared keys only (a frozen module without them stays valid).
	for _, decl in decls do
		local module = decl.module
		local name = decl.name
		if type(decl.client) == "table" then
			Registry.inject(decl.client, "Server", module)
		end
		if Registry.declared(module, "Signals") ~= nil and rt.signals[name] ~= nil then
			Registry.inject(module, "Signals", rt.signals[name])
		end
		if Registry.declared(module, "ClientEvents") ~= nil and rt.events[name] ~= nil then
			Registry.inject(module, "ClientEvents", rt.events[name])
		end
		if Registry.declared(module, "Dependencies") ~= nil then
			Registry.inject(module, "Dependencies", Registry.depsMap(decl.record, resolvedOf[name]))
		end
	end

	-- 7. Remotes (unparented), listeners, players, flush loop.
	S.Transport.prepare(rt, offline)
	netUp = true

	-- 8. Ignite in order; the first failure stops the boot.
	igniteOrder = order
	for _, name in order do
		local problem = ignite("Service", services[name], myGen)
		if myGen ~= gen then
			return
		end
		if problem then
			return failServer(ctx, myGen, problem)
		end
	end

	-- 9. Burn in order (spawned; never fails the boot).
	burnAll("Service", services, order)
	if myGen ~= gen or state ~= STATE.Booting then
		return
	end

	-- 10. Open the network and go Ready.
	S.Transport.open()
	setState(STATE.Ready)
	loren.IsReady = true
	if not offline then
		game:BindToClose(function()
			shutdown(myGen)
		end)
	end
	local ms = math.floor((os.clock() - started) * 1000 + 0.5)
	printBoot(
		string.format(
			"Burning on Server: %s, %s, %d ms%s",
			plural(#names, "service"),
			plural(rt.count or 0, "route"),
			ms,
			if offline then " (offline)" else ""
		),
		report
	)
	if rootResolve then
		rootResolve(loren)
	end
end

-- Client boot (section 8.3) ---------------------------------------------------------------------------

-- What a Controller Dependency that names neither a Controller nor a networked Service resolves to.
-- 1.5.1 gave every Service name a proxy, and the client cannot tell a Service without network
-- members from a typo (the manifest lists networked Services only), so the boot only warns and the
-- name gets this placeholder: any use raises with the reason at the caller's line.
local function missingDependency(owner: string, dep: string): any
	local msg = string.format(
		"%s%s.Dependencies.%s: '%s' is not a Controller or a networked Service %s, so it cannot be used on the client",
		PREFIX,
		owner,
		dep,
		dep,
		NOT_NETWORKED
	)
	local placeholder = setmetatable({}, {
		__index = function(_: any, _key: any): any
			error(msg, 2)
		end,
		__tostring = function(): string
			return "missing dependency '" .. dep .. "'"
		end,
	})
	return table.freeze(placeholder)
end

-- Resolves Controller Dependencies to Controllers and proxies; returns name -> resolved map.
-- An unknown name is a warning (and a placeholder that raises when used), not a boot error.
local function resolveClientDeps(
	report: Report,
	controllers: { [string]: ModuleRecord },
	names: { string },
	getProxy: (name: string) -> any,
	proxyNames: { string }
): { [string]: { [string]: any } }
	local candidates: { string } = {}
	table.move(names, 1, #names, 1, candidates)
	table.move(proxyNames, 1, #proxyNames, #names + 1, candidates)
	local dependedOn: { [string]: boolean } = {}
	local resolvedOf: { [string]: { [string]: any } } = {}
	for _, name in names do
		local resolved: { [string]: any } = {}
		for _, dep in controllers[name].deps do
			local ctrl = controllers[dep]
			local proxy = getProxy(dep)
			if ctrl and proxy ~= nil then
				dependedOn[dep] = true
				table.insert(
					report.errors,
					string.format(
						"%s.Dependencies: '%s' is both a Controller and a networked Service; rename one of them",
						name,
						dep
					)
				)
			elseif ctrl then
				resolved[dep] = ctrl.module
			elseif proxy ~= nil then
				resolved[dep] = proxy
			elseif not Registry.isFailed("Controller", dep) then
				table.insert(
					report.warnings,
					string.format(
						"%s.Dependencies: '%s' is not a Controller or a networked Service %s; it resolves to a placeholder that raises when used.",
						name,
						dep,
						NOT_NETWORKED
					) .. Registry.suggestion(dep, candidates, "Available")
				)
				resolved[dep] = missingDependency(name, dep)
			end
		end
		resolvedOf[name] = resolved
	end
	local shared: { string } = {}
	for _, pname in proxyNames do
		if controllers[pname] and not dependedOn[pname] then
			table.insert(shared, pname)
		end
	end
	table.sort(shared)
	for _, pname in shared do
		table.insert(
			report.warnings,
			string.format(
				"'%s' is both a Controller and a networked Service; GetController and GetService return different objects",
				pname
			)
		)
	end
	return resolvedOf
end

local function clientSteps(ctx: BootCtx, myGen: number, started: number)
	-- 1. Validate the Controllers before any network wait.
	local report = ctx.report
	Registry.checkModules(report, "Controller")
	if #report.errors > 0 then
		return failClient(ctx, myGen)
	end

	-- 2. LorenNet, State, remotes, listeners, HELLO, MANIFEST (warns while waiting, never times out).
	local model, reason = ClientNet.connect()
	if myGen ~= gen then
		return
	end
	if model == nil then
		return failClient(ctx, myGen, "Could not join the server: " .. tostring(reason))
	end
	netUp = true

	-- 3. Proxies.
	Proxy.build(model)
	manifestReady = true
	local proxyNames = table.clone(Proxy.names())
	table.sort(proxyNames)

	-- 4-5. Dependencies (Controllers and proxies) and the order (proxies are not edges).
	local cfg = Config.get()
	local controllers = Registry.records("Controller")
	local names = Registry.names("Controller")
	local resolvedOf = resolveClientDeps(report, controllers, names, Proxy.get, proxyNames)
	local order, cycles = Topo.order(names, function(name: string): { string }
		return controllers[name].deps
	end)
	cycleReport(report, cycles, cfg.StrictCycles)
	if #report.errors > 0 then
		return failClient(ctx, myGen)
	end

	-- 6. Inject declared keys only: Signals names -> LocalSignals, Dependencies map.
	for _, name in names do
		local rec = controllers[name]
		local module = rec.module
		local signalNames = Registry.controllerSignals(module)
		if signalNames ~= nil then
			local map: { [string]: any } = {}
			for _, signalName in signalNames do
				map[signalName] = Signal.LocalSignal.new()
			end
			Registry.inject(module, "Signals", map)
		end
		if Registry.declared(module, "Dependencies") ~= nil then
			Registry.inject(module, "Dependencies", Registry.depsMap(rec, resolvedOf[name]))
		end
	end

	-- 7. Ignite, then Burn.
	igniteOrder = order
	for _, name in order do
		local problem = ignite("Controller", controllers[name], myGen)
		if myGen ~= gen then
			return
		end
		if problem then
			return failClient(ctx, myGen, problem)
		end
	end
	burnAll("Controller", controllers, order)
	if myGen ~= gen or state ~= STATE.Booting then
		return
	end

	-- 8. The backlog window starts at Ready.
	Signal.ClientSignal.startWindow(model.limits.backlogWindow)
	setState(STATE.Ready)
	loren.IsReady = true
	local ms = math.floor((os.clock() - started) * 1000 + 0.5)
	printBoot(
		string.format(
			"Burning on Client: %s, %s, %d ms",
			plural(#names, "controller"),
			plural(#proxyNames, "service"),
			ms
		),
		report
	)
	if rootResolve then
		rootResolve(loren)
	end
end

local function bootMain(myGen: number, started: number)
	local ctx: BootCtx = {
		report = Registry.newReport(if IS_SERVER then "Server" else "Client"),
		S = nil,
		claimed = false,
	}
	local steps: any = if IS_SERVER then serverSteps else clientSteps
	local ok, e = xpcall(steps, traceback, ctx, myGen, started)
	if not ok then
		local reason = "Internal error during the boot: " .. tostring(e)
		if IS_SERVER then
			failServer(ctx, myGen, reason)
		else
			failClient(ctx, myGen, reason)
		end
	end
	if myGen == gen then
		bootThread = nil
	end
end

-- API -------------------------------------------------------------------------------------------------

-- The facade, at require: stores the references and writes the initial facade fields.
function Lifecycle.bind(facade: any, getServer: (peek: boolean?) -> any): ()
	loren = facade
	serverLoader = getServer
	facade.State = state
	facade.IsOnFire = state ~= STATE.Idle
	facade.IsReady = state == STATE.Ready or state == STATE.ShuttingDown
end

-- Loren.SetOnFire: the first call starts the boot; every call returns a child of the one root.
function Lifecycle.setOnFire(): Types.Promise
	if loren == nil then
		error(PREFIX .. "Loren is not bound: require ReplicatedStorage.LorenRuntime", 3)
	end
	ensureRoot()
	if state == STATE.Idle then
		Config.freeze()
		Registry.lock()
		setState(STATE.Booting)
		loren.IsOnFire = true
		loren.IsReady = false
		bootThread = task.spawn(bootMain, gen, os.clock())
	end
	return root:andThen()
end

-- Loren.OnReady: resolves with Loren at Ready (at once if Ready), rejects if the boot fails.
function Lifecycle.onReady(): Types.Promise
	ensureRoot()
	return root:andThen()
end

-- Loren.GetService. Server: the module table (right after AddServices). Client: the proxy (after
-- the manifest). Errors point at the caller of the facade (level 3).
function Lifecycle.getService(name: string): any
	if type(name) ~= "string" then
		error(PREFIX .. "GetService expects a Service name (string), got " .. typeof(name), 3)
	end
	if IS_SERVER then
		local rec = Registry.records("Service")[name]
		if rec then
			return rec.module
		end
		error(
			PREFIX
				.. "GetService: '"
				.. name
				.. "' is not a registered Service."
				.. Registry.suggestion(name, Registry.names("Service"), "Services"),
			3
		)
	end
	if not manifestReady then
		error(
			PREFIX
				.. "GetService('"
				.. name
				.. "') was called before the client received the server manifest; call Loren.OnReady() first",
			3
		)
	end
	local proxy = Proxy.get(name)
	if proxy ~= nil then
		return proxy
	end
	local hint = if Registry.records("Controller")[name]
		then " '" .. name .. "' is a Controller: use Loren.GetController."
		else Registry.suggestion(name, Proxy.names(), "Services")
	error(PREFIX .. "GetService: '" .. name .. "' is not a networked Service " .. NOT_NETWORKED .. "." .. hint, 3)
end

-- Loren.GetController (client only).
function Lifecycle.getController(name: string): any
	if IS_SERVER then
		error(PREFIX .. "GetController is client-only (Controllers run on clients; use GetService on the server)", 3)
	end
	if type(name) ~= "string" then
		error(PREFIX .. "GetController expects a Controller name (string), got " .. typeof(name), 3)
	end
	local rec = Registry.records("Controller")[name]
	if rec then
		return rec.module
	end
	error(
		PREFIX
			.. "GetController: '"
			.. name
			.. "' is not a registered Controller."
			.. Registry.suggestion(name, Registry.names("Controller"), "Controllers"),
		3
	)
end

-- Loren.Get(require(m)): the module itself if it is registered on this side.
function Lifecycle.get(module: any): any
	if type(module) == "table" and Registry.recordOf(module) ~= nil then
		return module
	end
	error(
		PREFIX
			.. "Get: the value is not a registered "
			.. (if IS_SERVER then "Service" else "Controller")
			.. " (pass require(ModuleScript) of a module added with Loren."
			.. (if IS_SERVER then "AddServices" else "AddControllers")
			.. ")",
		3
	)
end

function Lifecycle.setOffline(offline: boolean): ()
	offlineFlag = offline == true
end

-- The LorenServer index if the facade already required it, else nil. `load` (server only, for
-- Testing.Reset): also require ServerScriptService.LorenServer when it exists, because specs may have
-- required its modules directly (same module instances, never reset otherwise). Requiring the
-- index has no side effects; the client never loads it.
function Lifecycle.loadedServer(load: boolean?): any?
	if serverLoader == nil then
		return nil
	end
	local S = serverLoader(true)
	if
		S == nil
		and load
		and IS_SERVER
		and game:GetService("ServerScriptService"):FindFirstChild(C.Names.ServerFolder) ~= nil
	then
		S = serverLoader(false)
	end
	return S
end

-- Whether the network side exists (Loren.Flush is a no-op before).
function Lifecycle.netUp(): boolean
	return netUp
end

function Lifecycle._reset(): ()
	gen += 1
	local th = bootThread
	bootThread = nil
	if th and th ~= coroutine.running() then
		pcall(task.cancel, th)
	end
	for timer in timers do
		pcall(task.cancel, timer)
	end
	table.clear(timers)
	-- Rejected last: reject runs handlers and resumes :await() threads synchronously, so they must
	-- see the reset state.
	local pendingReject = if root ~= nil and root:getStatus() == Promise.Status.Started then rootReject else nil
	root = nil
	rootGuard = nil
	rootResolve = nil
	rootReject = nil
	state = STATE.Idle
	if loren then
		loren.State = STATE.Idle
		loren.IsOnFire = false
		loren.IsReady = false
	end
	offlineFlag = false
	netUp = false
	manifestReady = false
	igniteOrder = {}
	bootServer = nil
	testServer = nil
	errorSink = defaultErrorSink
	igniteWarnAfter = C.Limit.IGNITE_WARN
	shutdownBudget = C.Limit.SHUTDOWN_BUDGET
	if pendingReject then
		pendingReject(PREFIX .. "Reset")
	end
end

Lifecycle._test = table.freeze({
	-- Replaces the LorenServer index for boots and facade server calls: a table (the fake index),
	-- a loader function (peek) -> index, or nil to restore the facade loader.
	setServer = function(server: any)
		if server == nil then
			testServer = nil
		elseif type(server) == "function" then
			testServer = server
		else
			testServer = function(_peek: boolean?): any
				return server
			end
		end
	end,
	-- Captures the boot-failure red error instead of printing it (nil restores).
	setErrorSink = function(fn: ((string) -> ())?)
		errorSink = fn or defaultErrorSink
	end,
	-- Shorter timers for specs: { igniteWarn = s, shutdownBudget = s }.
	setTimings = function(t: { igniteWarn: number?, shutdownBudget: number? })
		igniteWarnAfter = t.igniteWarn or igniteWarnAfter
		shutdownBudget = t.shutdownBudget or shutdownBudget
	end,
	-- Runs the BindToClose sequence now (offline boots never bind it). Yields.
	shutdown = function()
		shutdown(gen)
	end,
	order = function(): { string }
		return table.clone(igniteOrder)
	end,
	state = function(): string
		return state
	end,
	-- The flag set by Testing.Reset({ Offline = ... }) for the next boot.
	offline = function(): boolean
		return offlineFlag
	end,
	-- Ignite timers still pending (0 after every boot and after _reset).
	pendingTimers = function(): number
		local n = 0
		for _ in timers do
			n += 1
		end
		return n
	end,
	hasGuard = function(): boolean
		return rootGuard ~= nil
	end,
	resolveClientDeps = resolveClientDeps,
})

return table.freeze(Lifecycle)
