--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Errors = require(Runtime.Errors)
local Config = require(Runtime.Config)
local Signal = require(Runtime.Signal)
local Log = require(Runtime.Log)
local Promise: any = require(ReplicatedStorage.LorenPackages.Promise)
local Outbox = require(script.Parent.Outbox)
local Violations = require(script.Parent.Violations)

type Route = Outbox.Route
type PlayerState = Outbox.PlayerState
type CallRec = Outbox.CallRec
type QueueEntry = Outbox.QueueEntry
type ErrorHandler = (info: { [string]: any }) -> ()

local PREFIX = C.PREFIX
local L = C.Limit
local D = C.Default
local ERR = C.Err
local ENCODE_NAME: { [number]: string } = C.EncodeName :: any
local KIND_METHOD = C.Kind.Method
local DROP_EVENT_DENIED = C.Drop.EventDenied
local WATCHDOG_INTERVAL = L.WATCHDOG_INTERVAL
local HANDLER_LOG_INTERVAL = L.HANDLER_LOG_INTERVAL
local ON_ERROR_RATE = L.ON_ERROR_RATE
local COLON_LOG_INTERVAL = 60

-- admit() results
local RUN = 0
local QUEUE = 1
local SERIAL = 2
local BUSY = 3

-- call outcomes (finish)
local RES_OK = 1
local RES_ERR = 2 -- handler threw / returned Promise rejected
local RES_DENIED = 3
local RES_FAULT = 4 -- middleware threw

-- middleware verdicts
local ALLOW = 0
local DENY = 1
local FAULT = 2

local isStudio = RunService:IsStudio()
local sendOk = Outbox.sendOk
local sendErr = Outbox.sendErr
local spawn = Signal.spawn
local deliver = Signal.ServerEvent.deliver
local isReject = Errors.isReject

-- Configuration (Dispatch.configure at boot; C.Default until then) ---------------------------------

local maxRunning: number = D.MaxRunningCalls
local maxQueued: number = D.MaxQueuedCalls
local maxZombies: number = D.MaxZombies
local maxZombiesPerRoute: number = D.MaxZombiesPerRoute
local serialCap: number = D.SerialQueue
local grace: number = D.WatchdogGrace
local arityCheck: boolean = D.MiddlewareArityCheck
local forwardErrors = false

-- State (restored by _reset) -------------------------------------------------------------------

local globalMw: { (...any) -> ...any } = {}
local globalMwN = 0
local errorHandlers: { ErrorHandler } = {}
local nextToken = 0 -- never reset: a thread from before a reset can never match a new call
local lastFinished = 0
local curThread: thread? = nil
local lastTrace: string? = nil
local traceRoute: Route? = nil
local traceThread: thread? = nil
local tracesBuilt = 0 -- tracebacks built by captureError (specs)
local zombieTokens: { [number]: PlayerState } = {} -- token -> owner, while the zombie thread lives
local zombieRecs: { [number]: CallRec } = {} -- token -> its abandoned record (thread, route)
local departed: { PlayerState } = {} -- players who left with yielded calls still before their deadline
-- Member middleware read at call time that differs from the boot value: its colon check (per route)
local liveMw: { [number]: any } = {}
local liveFn: { [number]: any } = {}
local liveColon: { [number]: boolean } = {}
local mwHinted: { [number]: boolean } = {} -- route id -> truthy-middleware hint shown (Studio)
local errLogAt: { [number]: number } = {} -- route id -> earliest next failure log line
local colonLogAt: { [number]: number } = {}
local onErrorWindow = 0
local onErrorCount = 0
local nextSweep = 0
local expired: { number } = {} -- sweep scratch (callIds)
local clock: () -> number = os.clock

local Dispatch = {}

-- admit() results, for Transport.
Dispatch.RUN = RUN
Dispatch.QUEUE = QUEUE
Dispatch.SERIAL = SERIAL
Dispatch.BUSY = BUSY

-- Helpers ------------------------------------------------------------------------------------------

local function readUserId(player: any): any
	return player.UserId
end

local function uidOf(player: any): string
	local ok, uid = pcall(readUserId, player)
	return if ok then tostring(uid) else "?"
end

local function wantDetails(route: Route): boolean
	local now = clock()
	if #errorHandlers > 0 and (now >= onErrorWindow or onErrorCount < ON_ERROR_RATE) then
		return true
	end
	local at = errLogAt[route.id]
	return (at == nil or now >= at) and Log.allowed()
end

local function captureError(err: any): any
	if isReject(err) then
		return err
	end
	local route = traceRoute
	if route == nil or traceThread ~= coroutine.running() or wantDetails(route) then
		lastTrace = debug.traceback(nil, 2)
		tracesBuilt += 1
	else
		lastTrace = nil
	end
	return err
end

-- Reads and clears the stashed traceback (called right after a failed xpcall, before any yield).
local function takeTrace(): string?
	local t = lastTrace
	lastTrace = nil
	return t
end

local function errorText(err: any): string
	if type(err) == "string" then
		return err
	end
	local ok, text = pcall(tostring, err)
	if ok and type(text) == "string" then
		return text
	end
	return "(" .. typeof(err) .. " error)"
end

local function runErrorHandler(fn: ErrorHandler, info: { [string]: any })
	debug.resetmemorycategory()
	local ok, err = pcall(fn :: any, info)
	if not ok then
		Log.warnf("OnError handler failed: %s", tostring(err))
	end
end

-- Loren.OnError handlers: at most ON_ERROR_RATE calls per second, each on its own thread.
local function notifyError(route: Route, player: any, incident: number, text: string, trace: string?)
	local n = #errorHandlers
	if n == 0 then
		return
	end
	local now = clock()
	if now >= onErrorWindow then
		onErrorWindow = now + 1
		onErrorCount = 0
	end
	if onErrorCount >= ON_ERROR_RATE then
		return
	end
	onErrorCount += 1
	local info: { [string]: any } = {
		Service = route.service,
		Member = route.member,
		Player = player,
		Incident = Errors.hex(incident),
		Message = text,
		Traceback = trace or "",
	}
	table.freeze(info)
	for i = 1, n do
		task.spawn(runErrorHandler, errorHandlers[i], info)
	end
end

-- One failure line per route per HANDLER_LOG_INTERVAL (and within Log's global budget).
local function logFailure(route: Route, player: any, what: string, incident: number?, text: string, trace: string?)
	local now = clock()
	local at = errLogAt[route.id]
	if (at ~= nil and now < at) or not Log.allowed() then
		return
	end
	local tag = if incident then " [" .. Errors.hex(incident) .. "]" else ""
	local tail = if trace then "\n" .. trace else ""
	if Log.warnf("%s %s for uid=%s%s: %s%s", route.fullName, what, uidOf(player), tag, text, tail) then
		errLogAt[route.id] = now + HANDLER_LOG_INTERVAL
	end
end

local function internalError(ps: PlayerState, route: Route, callId: number, err: any, trace: string?, what: string)
	local incident = Errors.newIncident()
	local text: string? = nil
	if forwardErrors or wantDetails(route) then
		local t = errorText(err)
		text = t
		logFailure(route, ps.player, what, incident, t, trace)
		notifyError(route, ps.player, incident, t, trace)
	end
	sendErr(ps, callId, ERR.InternalError, if forwardErrors then text else nil, nil, false, incident)
end

-- ERR BadResult. The text ("<what> [<arg>] <EncodeName>") is built only when it will be used.
local function badResult(ps: PlayerState, route: Route, callId: number, what: string, st: number, arg: number)
	local incident = Errors.newIncident()
	local text: string? = nil
	if forwardErrors or wantDetails(route) then
		local name = ENCODE_NAME[st] or tostring(st)
		local t = if arg > 0 then string.format("%s %d %s", what, arg, name) else what .. " " .. name
		text = t
		logFailure(route, ps.player, "returned values that cannot be sent", incident, t, nil)
		notifyError(route, ps.player, incident, t, nil)
	end
	sendErr(ps, callId, ERR.BadResult, if forwardErrors then text else nil, nil, false, incident)
end

local function sendRejected(ps: PlayerState, route: Route, callId: number, rej: any)
	local msg = rawget(rej, "Message")
	local data = rawget(rej, "Data")
	local st = sendErr(ps, callId, ERR.Rejected, if type(msg) == "string" then msg else "", data, data ~= nil, nil)
	if st ~= 0 then
		badResult(ps, route, callId, "Reject data", st, 0)
	end
end

-- The reply for a finished call (the token matched and the player is still here).
local function reply(ps: PlayerState, route: Route, callId: number, kind: number, trace: string?, ...: any)
	if kind == RES_OK then
		local first = ...
		if isReject(first) then
			sendRejected(ps, route, callId, first)
			return
		end
		local st, arg = sendOk(ps, route, callId, select("#", ...), ...)
		if st ~= 0 then
			badResult(ps, route, callId, "result", st, arg)
		end
	elseif kind == RES_ERR then
		local err = ...
		if isReject(err) then
			sendRejected(ps, route, callId, err)
		else
			internalError(ps, route, callId, err, trace, "failed")
		end
	elseif kind == RES_DENIED then
		local msg = ...
		sendErr(ps, callId, ERR.Denied, msg, nil, false, nil)
	else
		internalError(ps, route, callId, (...), trace, "middleware failed")
	end
end

-- Call lifecycle -----------------------------------------------------------------------------------

local drain: (ps: PlayerState) -> ()

local function threadEnded(ps: PlayerState, route: Route)
	if route.serial then
		local id = route.id
		ps.serialActive[id] = nil
		local q = ps.serialQ[id]
		if q ~= nil and #q > 0 then
			table.insert(ps.readmit, route)
		end
	end
	if #ps.readmit > 0 or (ps.queued > 0 and ps.running < maxRunning) then
		drain(ps)
	end
end

local function endZombie(ps: PlayerState, route: Route)
	ps.zombies -= 1
	local id = route.id
	local left = (ps.routeZombies[id] or 1) - 1
	if left > 0 then
		ps.routeZombies[id] = left
	else
		ps.routeZombies[id] = nil
	end
end

local function finish(
	ps: PlayerState,
	route: Route,
	callId: number,
	token: number,
	kind: number,
	trace: string?,
	...: any
)
	if ps.callTok[callId] == token then
		ps.callTok[callId] = nil
		local rec = ps.calls[callId]
		if rec ~= nil and rec.token == token then
			ps.calls[callId] = nil
			ps.running -= 1
		end
		if not ps.gone then
			local ok, err = pcall(reply :: any, ps, route, callId, kind, trace, ...)
			if not ok then
				Log.once("reply:" .. route.fullName, route.fullName .. ": the reply failed: " .. tostring(err))
			end
		end
	elseif zombieTokens[token] ~= nil then
		-- An abandoned call's thread ended (zombie end): no reply.
		zombieTokens[token] = nil
		zombieRecs[token] = nil
		endZombie(ps, route)
	end
	threadEnded(ps, route)
	-- Last, so a call finished by a nested one still reads as finished by its own token.
	lastFinished = token
end

local function awaitPromise(p: any): ...any
	if getmetatable(p) == Promise then
		return p:await()
	end
	return Promise.resolve(p):await()
end

local function settleAwait(ps: PlayerState, route: Route, callId: number, token: number, called: boolean, ...: any)
	if not called then
		return finish(ps, route, callId, token, RES_ERR, nil, (...))
	end
	local resolved = ...
	if resolved then
		return finish(ps, route, callId, token, RES_OK, nil, select(2, ...))
	end
	return finish(ps, route, callId, token, RES_ERR, nil, (select(2, ...)))
end

local function settle(ps: PlayerState, route: Route, callId: number, token: number, ok: boolean, ...: any)
	if not ok then
		return finish(ps, route, callId, token, RES_ERR, takeTrace(), ...)
	end
	local first = ...
	if type(first) == "table" and Promise.is(first) then
		-- Awaited on this thread: the call counts as yielded until the Promise settles.
		return settleAwait(ps, route, callId, token, pcall(awaitPromise, first))
	end
	return finish(ps, route, callId, token, RES_OK, nil, ...)
end

-- Evaluates one middleware result (section 3.16): (verdict, reason or error, traceback).
local function evalMw(route: Route, ok: boolean, a: any, b: any): (number, any, string?)
	if not ok then
		return FAULT, a, takeTrace()
	end
	if type(a) == "table" and Promise.is(a) then
		local called, resolved, x, y = pcall(awaitPromise, a)
		if not called then
			return FAULT, resolved, nil
		elseif not resolved then
			return FAULT, x, nil
		end
		a, b = x, y
	end
	if a == true then
		return ALLOW, nil, nil
	elseif a == false or a == nil then
		return DENY, if type(b) == "string" then b else nil, nil
	end
	if isStudio and not mwHinted[route.id] then
		-- once per route, and no string is built outside Studio
		mwHinted[route.id] = true
		Log.studioOnce(
			"mw-truthy:" .. route.fullName,
			string.format(
				"%s: middleware returned %s, not true; the call is denied (return true to allow)",
				route.fullName,
				typeof(a)
			)
		)
	end
	return DENY, nil, nil
end

local function warnColon(route: Route)
	local now = clock()
	local at = colonLogAt[route.id]
	if at ~= nil and now < at then
		return
	end
	if
		Log.warnf(
			"%s denied: %s.Middleware.%s looks colon-defined. Middleware is called as (player, ...args) without self; write function %s.Middleware.%s(player, ...)",
			route.fullName,
			route.service,
			route.member,
			route.service,
			route.member
		)
	then
		colonLogAt[route.id] = now + COLON_LOG_INTERVAL
	end
end

local function indexKey(t: any, k: string): any
	return t[k]
end

-- module.Middleware read as the boot read it: raw first, then a metatable's __index under pcall.
local function middlewareTable(module: any): any
	if type(module) ~= "table" then
		return nil
	end
	local t = rawget(module, "Middleware")
	if t == nil and getmetatable(module) ~= nil then
		local ok, v = pcall(indexKey, module, "Middleware")
		if ok then
			t = v
		end
	end
	return t
end

-- The boot's colon rule (Registry.buildDecl) for a middleware and handler read at call time.
local function looksColon(mw: any, fn: any): boolean
	if type(mw) ~= "function" or type(fn) ~= "function" then
		return false
	end
	local ma: number, mv: boolean = (debug.info :: any)(mw, "a")
	local fa: number, fv: boolean = (debug.info :: any)(fn, "a")
	return ma == fa and ma >= 2 and not mv and not fv
end

local function memberMiddleware(route: Route, fn: any): (any, boolean)
	local t = middlewareTable(route.module)
	local mw = if type(t) == "table" then rawget(t, route.member) else nil
	if mw == nil then
		return nil, false
	end
	if mw == route.middleware and fn == route.fn then
		return mw, route.colon
	end
	local id = route.id
	if liveMw[id] ~= mw or liveFn[id] ~= fn then
		liveMw[id] = mw
		liveFn[id] = fn
		liveColon[id] = arityCheck and route.kind == KIND_METHOD and looksColon(mw, fn)
	end
	return mw, liveColon[id] == true
end

-- Global middleware in order, then the member's `mw` (nil = none). (verdict, reason or error, traceback)
local function runMiddleware(route: Route, mw: any, colon: boolean, player: Player, ...: any): (number, any, string?)
	for i = 1, globalMwN do
		local verdict, why, trace = evalMw(route, xpcall(globalMw[i], captureError, player, route.info, ...))
		if verdict ~= ALLOW then
			return verdict, why, trace
		end
	end
	if mw == nil then
		return ALLOW, nil, nil
	end
	if colon then
		warnColon(route)
		return DENY, nil, nil
	end
	return evalMw(route, xpcall(mw, captureError, player, ...))
end

local function runCall(ps: PlayerState, route: Route, callId: number, token: number, _n: number, ...: any)
	local thread = coroutine.running()
	curThread = thread
	traceRoute = route
	traceThread = thread
	local player = ps.player
	local client = route.self
	local fn: any = rawget(client, route.member) :: any
	local mw, colon = memberMiddleware(route, fn)
	if globalMwN > 0 or mw ~= nil then
		local verdict, why, trace = runMiddleware(route, mw, colon, player, ...)
		if verdict == DENY then
			return finish(ps, route, callId, token, RES_DENIED, nil, why)
		elseif verdict == FAULT then
			return finish(ps, route, callId, token, RES_FAULT, trace, why)
		end
		-- a middleware Promise may have yielded: this thread runs the handler now
		traceRoute = route
		traceThread = thread
	end
	return settle(ps, route, callId, token, xpcall(fn, captureError, client, player, ...))
end

-- Starts a call now. If it yields, allocates its CallRec (it now counts as running).
local function startCall(
	ps: PlayerState,
	route: Route,
	callId: number,
	token: number,
	receipt: number,
	n: number,
	...: any
)
	local prevThread = curThread
	curThread = nil
	spawn(runCall, ps, route, callId, token, n, ...)
	local thread = curThread
	curThread = prevThread
	if lastFinished == token then
		return -- finished without yielding
	end
	if thread ~= nil and coroutine.status(thread) == "suspended" then
		local rec: CallRec = {
			route = route,
			token = token,
			thread = thread,
			deadline = receipt + route.timeout + grace,
		}
		ps.calls[callId] = rec
		ps.running += 1
		if route.serial then
			ps.serialActive[route.id] = true
		end
	else
		-- The runner ended without reaching finish (an internal fault): release the call.
		if ps.callTok[callId] == token then
			ps.callTok[callId] = nil
		end
		threadEnded(ps, route)
	end
end

local function startEntry(ps: PlayerState, e: QueueEntry)
	local args = e.args
	startCall(ps, e.route, e.callId, e.token, e.receipt, args.n, table.unpack(args, 1, args.n))
end

-- A queued entry that will never run: its id is free again, no reply.
local function dropEntry(ps: PlayerState, e: QueueEntry)
	if ps.callTok[e.callId] == e.token then
		ps.callTok[e.callId] = nil
	end
end

-- The next live entry of a Serial queue (expired ones are dropped).
local function popSerial(ps: PlayerState, id: number, now: number): QueueEntry?
	local q = ps.serialQ[id]
	while q ~= nil and #q > 0 do
		local e = table.remove(q, 1) :: QueueEntry
		if now > e.receipt + e.route.timeout then
			dropEntry(ps, e)
		else
			return e
		end
	end
	return nil
end

local function drainBody(ps: PlayerState)
	local now = clock()
	while not ps.gone do
		local readmit = ps.readmit
		if #readmit > 0 then
			local route = table.remove(readmit, 1) :: Route
			local id = route.id
			if not ps.serialActive[id] then
				local e = popSerial(ps, id, now)
				if e ~= nil then
					if ps.running >= maxRunning then
						-- Waits in the player queue and keeps the route occupied.
						ps.serialActive[id] = true
						table.insert(ps.queue, e)
						ps.queued += 1
					else
						startEntry(ps, e)
					end
				end
			end
		elseif ps.queued > 0 and ps.running < maxRunning then
			local e = table.remove(ps.queue, 1) :: QueueEntry
			ps.queued -= 1
			if now > e.receipt + e.route.timeout then
				dropEntry(ps, e)
				if e.route.serial then
					-- It occupied its Serial route: free it as if its thread had ended.
					local id = e.route.id
					ps.serialActive[id] = nil
					local q = ps.serialQ[id]
					if q ~= nil and #q > 0 then
						table.insert(readmit, e.route)
					end
				end
			else
				startEntry(ps, e)
			end
		else
			break
		end
	end
end

drain = function(ps: PlayerState)
	if ps.draining then
		return
	end
	ps.draining = true
	local ok, err = pcall(drainBody :: any, ps)
	ps.draining = false
	if not ok then
		Log.once("drain", "starting queued calls failed: " .. tostring(err))
	end
end

local function abandon(ps: PlayerState, callId: number, rec: CallRec)
	ps.calls[callId] = nil
	if ps.callTok[callId] == rec.token then
		ps.callTok[callId] = nil
	end
	ps.running -= 1
	local route = rec.route
	local thread = rec.thread
	local status = coroutine.status(thread)
	if status == "dead" then
		threadEnded(ps, route)
		return
	end
	if route.cancelOnTimeout and status == "suspended" and pcall(task.cancel, thread) then
		threadEnded(ps, route)
		return
	end
	local token = rec.token
	zombieTokens[token] = ps
	zombieRecs[token] = rec
	ps.zombies += 1
	local id = route.id
	ps.routeZombies[id] = (ps.routeZombies[id] or 0) + 1
end

local function expireQueued(ps: PlayerState, now: number): boolean
	local any = false
	local q = ps.queue
	local n = #q
	if n > 0 then
		local j = 0
		for i = 1, n do
			local e = q[i]
			local route = e.route
			if now > e.receipt + route.timeout then
				any = true
				dropEntry(ps, e)
				ps.queued -= 1
				if route.serial then
					-- It occupied its Serial route: free it as if its thread had ended.
					local id = route.id
					ps.serialActive[id] = nil
					local sq = ps.serialQ[id]
					if sq ~= nil and #sq > 0 then
						table.insert(ps.readmit, route)
					end
				end
			else
				j += 1
				q[j] = e
			end
		end
		for i = j + 1, n do
			q[i] = nil :: any
		end
	end
	for _, sq in ps.serialQ do
		local m = #sq
		if m > 0 then
			local j = 0
			for i = 1, m do
				local e = sq[i]
				if now > e.receipt + e.route.timeout then
					any = true
					dropEntry(ps, e)
				else
					j += 1
					sq[j] = e
				end
			end
			for i = j + 1, m do
				sq[i] = nil :: any
			end
		end
	end
	return any
end

local function sweepPlayer(ps: PlayerState, now: number)
	local n = 0
	for callId, rec in ps.calls do
		if now >= rec.deadline or coroutine.status(rec.thread) == "dead" then
			n += 1
			expired[n] = callId
		end
	end
	for k = 1, n do
		local callId = expired[k]
		expired[k] = nil :: any
		local rec = ps.calls[callId]
		if rec ~= nil and (now >= rec.deadline or coroutine.status(rec.thread) == "dead") then
			abandon(ps, callId, rec)
		end
	end
	local dropped = expireQueued(ps, now)
	if (n > 0 or dropped) and (#ps.readmit > 0 or (ps.queued > 0 and ps.running < maxRunning)) then
		drain(ps)
	end
end

local function sweepZombies()
	local n = 0
	for token, rec in zombieRecs do
		if coroutine.status(rec.thread) == "dead" then
			n += 1
			expired[n] = token
		end
	end
	for k = 1, n do
		local token = expired[k]
		expired[k] = nil :: any
		local rec = zombieRecs[token]
		local ps = zombieTokens[token]
		zombieRecs[token] = nil
		zombieTokens[token] = nil
		if rec ~= nil and ps ~= nil then
			endZombie(ps, rec.route)
			threadEnded(ps, rec.route)
		end
	end
end

local function sweepDeparted(now: number)
	for i = #departed, 1, -1 do
		local ps = departed[i]
		local n = 0
		for callId, rec in ps.calls do
			if now >= rec.deadline or coroutine.status(rec.thread) == "dead" then
				n += 1
				expired[n] = callId
			end
		end
		for k = 1, n do
			local callId = expired[k]
			expired[k] = nil :: any
			local rec = ps.calls[callId]
			if rec ~= nil then
				ps.calls[callId] = nil
				if ps.callTok[callId] == rec.token then
					ps.callTok[callId] = nil
				end
				ps.running -= 1
				local thread = rec.thread
				if rec.route.cancelOnTimeout and coroutine.status(thread) == "suspended" then
					pcall(task.cancel, thread)
				end
			end
		end
		if next(ps.calls) == nil then
			local last = #departed
			departed[i] = departed[last]
			departed[last] = nil
		end
	end
end

local function runEvent(ps: PlayerState, route: Route, mw: any, colon: boolean, _n: number, ...: any)
	traceRoute = route
	traceThread = coroutine.running()
	local player = ps.player
	local verdict, why, trace = runMiddleware(route, mw, colon, player, ...)
	if verdict == ALLOW then
		if not ps.gone then
			deliver(route.event :: any, player, ...)
		end
		return
	end
	Violations.drop(ps.viol, DROP_EVENT_DENIED, 1)
	if verdict == FAULT then
		logFailure(route, player, "middleware failed", nil, errorText(why), trace)
	end
end

-- API ----------------------------------------------------------------------------------------------

-- Transport.prepare: reads the call caps and policies (Config is frozen by then).
function Dispatch.configure(): ()
	local cfg = Config.get()
	maxRunning = cfg.MaxRunningCalls
	maxQueued = cfg.MaxQueuedCalls
	maxZombies = cfg.MaxZombies
	maxZombiesPerRoute = cfg.MaxZombiesPerRoute
	serialCap = cfg.SerialQueue
	grace = cfg.WatchdogGrace
	arityCheck = cfg.MiddlewareArityCheck
	local fe = cfg.ForwardErrors
	forwardErrors = fe == "Always" or (fe == "Studio" and isStudio)
	Outbox.configure(cfg.InlineTables)
end

-- Section 4.11 admit: a pure check before decode. Returns RUN, QUEUE, SERIAL or BUSY.
function Dispatch.admit(ps: PlayerState, route: Route): number
	local id = route.id
	local rz = ps.routeZombies[id] or 0
	if rz >= maxZombiesPerRoute or (rz >= 1 and ps.zombies >= maxZombies) then
		return BUSY
	end
	if route.serial and ps.serialActive[id] then
		local q = ps.serialQ[id]
		if (if q then #q else 0) >= serialCap then
			return BUSY
		end
		return SERIAL
	end
	if ps.running >= maxRunning or ps.queued > 0 then
		if ps.queued >= maxQueued then
			return BUSY
		end
		return QUEUE
	end
	return RUN
end

function Dispatch.accept(
	ps: PlayerState,
	route: Route,
	callId: number,
	adm: number,
	argv: { any },
	n: number,
	now: number
): ()
	nextToken += 1
	local token = nextToken
	ps.callTok[callId] = token
	if adm == RUN then
		startCall(ps, route, callId, token, now, n, table.unpack(argv, 1, n))
		return
	end
	local entry: QueueEntry = {
		callId = callId,
		token = token,
		route = route,
		receipt = now,
		args = table.pack(table.unpack(argv, 1, n)),
	}
	if adm == QUEUE then
		table.insert(ps.queue, entry)
		ps.queued += 1
		if route.serial then
			ps.serialActive[route.id] = true -- the queued call occupies its Serial route
		end
	else
		local q = ps.serialQ[route.id]
		if q == nil then
			q = {}
			ps.serialQ[route.id] = q
		end
		table.insert(q, entry)
	end
end

-- An accepted ClientEvent (after decode). argv as for accept.
function Dispatch.event(ps: PlayerState, route: Route, argv: { any }, n: number): ()
	local mw, colon = memberMiddleware(route, false)
	if globalMwN == 0 and mw == nil then
		deliver(route.event :: any, ps.player, table.unpack(argv, 1, n))
	else
		spawn(runEvent, ps, route, mw, colon, n, table.unpack(argv, 1, n))
	end
end

-- The watchdog (flush thread, every frame; runs every WATCHDOG_INTERVAL).
function Dispatch.sweep(now: number): ()
	if now < nextSweep then
		return
	end
	nextSweep = now + WATCHDOG_INTERVAL
	local list = Outbox.players()
	for i = #list, 1, -1 do
		local ps = list[i]
		-- A non-empty Serial queue always has an occupant: running, queued or a zombie.
		if ps ~= nil and (ps.running > 0 or ps.queued > 0 or ps.zombies > 0) then
			sweepPlayer(ps, now)
		end
	end
	if next(zombieRecs) ~= nil then
		sweepZombies()
	end
	if #departed > 0 then
		sweepDeparted(now)
	end
end

function Dispatch.abandonAll(ps: PlayerState): ()
	for _, e in ps.queue do
		dropEntry(ps, e)
		if e.route.serial then
			ps.serialActive[e.route.id] = nil
		end
	end
	table.clear(ps.queue)
	ps.queued = 0
	for _, q in ps.serialQ do
		for _, e in q do
			dropEntry(ps, e)
		end
		table.clear(q)
	end
	table.clear(ps.readmit)
	local n = 0
	for callId in ps.calls do
		n += 1
		expired[n] = callId
	end
	for k = 1, n do
		local callId = expired[k]
		expired[k] = nil :: any
		local rec = ps.calls[callId]
		if rec ~= nil then
			abandon(ps, callId, rec)
		end
	end
end

function Dispatch.onLeave(ps: PlayerState): ()
	table.clear(ps.queue)
	ps.queued = 0
	for _, q in ps.serialQ do
		table.clear(q)
	end
	table.clear(ps.readmit)
	for token, owner in zombieTokens do
		if owner == ps then
			zombieTokens[token] = nil
			zombieRecs[token] = nil
		end
	end
	if next(ps.calls) ~= nil and not table.find(departed, ps) then
		table.insert(departed, ps)
	end
end

-- Loren.AddMiddleware (server, before SetOnFire): fn(player, info, ...) -> true to allow.
function Dispatch.addMiddleware(fn: (player: Player, info: any, ...any) -> ...any): ()
	if type(fn) ~= "function" then
		error(PREFIX .. "AddMiddleware expects a function(player, info, ...), got " .. typeof(fn), 3)
	end
	if Config.isFrozen() then
		error(PREFIX .. "AddMiddleware must be called before SetOnFire", 3)
	end
	globalMwN += 1
	globalMw[globalMwN] = fn
end

-- Loren.OnError (server, any time): fn({ Service, Member, Player, Incident, Message, Traceback }).
function Dispatch.onError(fn: (info: { [string]: any }) -> ()): ()
	if type(fn) ~= "function" then
		error(PREFIX .. "OnError expects a function, got " .. typeof(fn), 3)
	end
	table.insert(errorHandlers, fn)
end

-- (RunningCalls, ZombieCalls) over the current players, for GetStats.
function Dispatch.counters(): (number, number)
	local running, zombies = 0, 0
	for _, ps in Outbox.players() do
		running += ps.running
		zombies += ps.zombies
	end
	return running, zombies
end

function Dispatch._reset(): ()
	table.clear(globalMw)
	globalMwN = 0
	table.clear(errorHandlers)
	lastFinished = 0
	curThread = nil
	lastTrace = nil
	traceRoute = nil
	traceThread = nil
	tracesBuilt = 0
	table.clear(zombieTokens)
	table.clear(zombieRecs)
	table.clear(departed)
	table.clear(liveMw)
	table.clear(liveFn)
	table.clear(liveColon)
	table.clear(mwHinted)
	table.clear(errLogAt)
	table.clear(colonLogAt)
	onErrorWindow = 0
	onErrorCount = 0
	nextSweep = 0
	table.clear(expired)
	maxRunning = D.MaxRunningCalls
	maxQueued = D.MaxQueuedCalls
	maxZombies = D.MaxZombies
	maxZombiesPerRoute = D.MaxZombiesPerRoute
	serialCap = D.SerialQueue
	grace = D.WatchdogGrace
	arityCheck = D.MiddlewareArityCheck
	forwardErrors = false
	clock = os.clock
end

Dispatch._test = table.freeze({
	RUN = RUN,
	QUEUE = QUEUE,
	SERIAL = SERIAL,
	BUSY = BUSY,
	-- Replaces os.clock for queue expiry, log throttles and OnError windows (nil restores it).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
	end,
	-- Forces the ForwardErrors decision (nil re-reads Config on the next configure).
	setForwardErrors = function(value: boolean)
		forwardErrors = value
	end,
	liveZombies = function(): number
		local n = 0
		for _ in zombieTokens do
			n += 1
		end
		return n
	end,
	-- Departed players whose yielded calls are still watched.
	departedCount = function(): number
		return #departed
	end,
	-- Tracebacks built for failing handlers and middleware since the last reset.
	tracesBuilt = function(): number
		return tracesBuilt
	end,
	middlewareCount = function(): number
		return globalMwN
	end,
})

return table.freeze(Dispatch)
