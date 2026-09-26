--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Errors = require(script.Parent.Errors)
local Config = require(script.Parent.Config)

local Promise: any = require(ReplicatedStorage:WaitForChild("LorenPackages"):WaitForChild("Promise"))

local Err = C.Err
local Limit = C.Limit

local FREE = 0
local PENDING = 1
local QUARANTINED = 2

local ID_MAX = 65535
local SEQ_MOD = 65536
local POOL_MAX = 1024
local QUARANTINE_AFTER_CANCEL = Limit.QUARANTINE_AFTER_CANCEL
local QUARANTINE_AFTER_DEADLINE = Limit.QUARANTINE_AFTER_DEADLINE
local SWEEP_INTERVAL = Limit.SWEEP_INTERVAL

-- Shown by the Promise library instead of a per-call traceback (unhandled rejections).
local SOURCE = 'Loren remote call (Loren.Configure({ PromiseTraces = "Always" }) records call-site tracebacks)'

export type Req = {
	id: number, -- 1..65535 while in use; 0 when free
	gen: number, -- bumped on every alloc (stale-reference guard)
	route: any,
	state: number, -- FREE / PENDING / QUARANTINED
	deadline: number, -- enqueue time + route timeout
	sendTime: number, -- when the call's frame was fired; -1 while unsent
	seq: number, -- reliable frame seq the call was fired in; -1 while unsent
	qBase: number, -- cancel/timeout time + QUARANTINE_AFTER_CANCEL
	qUntil: number, -- quarantine end; math.huge while the frame is unsent
	resolve: any, -- Promise mode: the promise's resolve, else false
	reject: any, -- Promise mode: the promise's reject, else false
	thread: any, -- Try mode: the parked caller thread, else false
	cancelFn: () -> (), -- onCancel hook, created once per pooled record
}

local Calls = {}

-- State ----------------------------------------------------------------------------------------

local byId: { [number]: Req } = {} -- pending and quarantined calls
local live = 0 -- pending calls
local nextId = 0 -- last id handed out
local genCounter = 0 -- monotonic across _reset, so stale scratch entries never match
local maxPending = C.Default.MaxPending
local useTraces = true
local hasPrivateNew = type(Promise._new) == "function"
local pool: { any } = {}
local poolN = 0
local nextSweep = 0
local lateCount = 0
local timeoutCount = 0
local clock: () -> number = os.clock
local setup: Req? = nil -- the record the executor binds (set just before creating the Promise)

local batchReqs: { any } = {}
local batchGens: { number } = {}
local batchTop = 0

local function noop() end

-- Releases the id and returns the record to the pool. Callers read what they need first.
local function release(req: Req)
	local id = req.id
	if byId[id] == req then
		byId[id] = nil
	end
	if req.state == PENDING then
		live -= 1
	end
	req.state = FREE
	req.id = 0
	req.route = false
	req.resolve = false
	req.reject = false
	req.thread = false
	if poolN < POOL_MAX then
		poolN += 1
		pool[poolN] = req
	end
end

-- Pending -> quarantined (timeout or cancel at `now`). The id stays reserved with its route.
local function quarantine(req: Req, now: number)
	if req.state == PENDING then
		live -= 1
	end
	req.state = QUARANTINED
	req.resolve = false
	req.reject = false
	req.thread = false
	local base = now + QUARANTINE_AFTER_CANCEL
	req.qBase = base
	if req.sendTime >= 0 then
		req.qUntil = math.max(base, req.sendTime + req.route.timeout + QUARANTINE_AFTER_DEADLINE)
	else
		req.qUntil = math.huge -- decided when the frame fires (fired)
	end
end

local function onCancelled(req: Req)
	if req.state == PENDING then
		quarantine(req, clock())
	end
end

local function newReq(): Req
	local req: Req = {
		id = 0,
		gen = 0,
		route = false,
		state = FREE,
		deadline = 0,
		sendTime = -1,
		seq = -1,
		qBase = 0,
		qUntil = 0,
		resolve = false,
		reject = false,
		thread = false,
		cancelFn = noop,
	}
	req.cancelFn = function()
		onCancelled(req)
	end
	return req
end

-- Resumes a parked Try caller. A thread that was closed or resumed by someone else is skipped.
local function resume(th: thread, ...: any)
	if coroutine.status(th) == "suspended" then
		task.spawn(th, ...)
	end
end

-- The one Promise executor. evaera Promise runs it synchronously inside Promise.new/_new.
local function executor(resolve: any, reject: any, onCancel: any)
	local req = setup
	setup = nil
	if req then
		req.resolve = resolve
		req.reject = reject
		onCancel(req.cancelFn)
	end
end

-- Delivers a rejection to whichever side waits (captured before the record was changed).
local function deliverReject(
	th: any,
	rj: any,
	route: any,
	code: number,
	msg: string?,
	data: any,
	incident: number?,
	arg: number?
)
	local message, info = Errors.rejection(code, route.service, route.member, msg, data, incident, arg)
	if th then
		resume(th, false, message, info)
	elseif rj then
		(rj :: any)(message, info)
	end
end

-- Configuration ----------------------------------------------------------------------------------

-- At MANIFEST: pending cap from the manifest; Promise tracing from Config.PromiseTraces (client key).
function Calls.configure(pendingCap: number): ()
	if type(pendingCap) == "number" and pendingCap >= 1 then
		maxPending = math.min(math.floor(pendingCap), ID_MAX)
	else
		maxPending = C.Default.MaxPending
	end
	local traces = Config.get().PromiseTraces
	if traces == "Always" then
		useTraces = true
	elseif traces == "Never" then
		useTraces = false
	else
		useTraces = RunService:IsStudio()
	end
end

-- Allocation -------------------------------------------------------------------------------------

function Calls.canAlloc(): boolean
	return live < maxPending
end

-- Reserves an id for a new pending call. nil when the pending cap is reached or every id is in use.
function Calls.alloc(route: any, now: number): Req?
	if live >= maxPending then
		return nil
	end
	local id = nextId
	for _ = 1, ID_MAX do
		id = if id >= ID_MAX then 1 else id + 1
		if byId[id] == nil then
			nextId = id
			local req: Req
			if poolN > 0 then
				req = pool[poolN]
				pool[poolN] = nil
				poolN -= 1
			else
				req = newReq()
			end
			genCounter += 1
			req.id = id
			req.gen = genCounter
			req.route = route
			req.state = PENDING
			req.deadline = now + route.timeout
			req.sendTime = -1
			req.seq = -1
			req.qBase = 0
			req.qUntil = 0
			req.resolve = false
			req.reject = false
			req.thread = false
			byId[id] = req
			live += 1
			return req
		end
	end
	return nil
end

-- Promise for a committed call. No Loren closure per call (module executor + pooled cancelFn).
function Calls.promise(req: Req): Types.Promise
	setup = req
	local p
	if useTraces or not hasPrivateNew then
		p = Promise.new(executor)
	else
		p = Promise._new(SOURCE, executor)
	end
	setup = nil
	return p
end

-- Try: parks the caller until the call settles. Returns (true, ...) or (false, message, info).
function Calls.park(req: Req): ...any
	req.thread = coroutine.running()
	return coroutine.yield()
end

-- An already-rejected Promise for a local rejection (never thrown).
function Calls.rejected(message: string, info: Types.ErrorInfo): Types.Promise
	return Promise.reject(message, info)
end

-- Replies ----------------------------------------------------------------------------------------

-- The pending or quarantined record for a reply's call id, or nil (unknown id).
function Calls.lookup(id: number): Req?
	return byId[id]
end

function Calls.isPending(req: Req): boolean
	return req.state == PENDING
end

-- OK for a pending call. Values may contain nil holes (the caller passes exactly n values).
function Calls.resolve(req: Req, ...: any): ()
	if req.state ~= PENDING then
		return
	end
	local th, rs = req.thread, req.resolve
	release(req)
	if th then
		resume(th, true, ...)
	elseif rs then
		(rs :: any)(...)
	end
end

-- Rejects a pending call with (message, info) built by Errors.rejection.
function Calls.reject(req: Req, code: number, msg: string?, data: any, incident: number?, arg: number?): ()
	if req.state ~= PENDING then
		return
	end
	local route, th, rj = req.route, req.thread, req.reject
	release(req)
	deliverReject(th, rj, route, code, msg, data, incident, arg)
end

function Calls.late(req: Req): ()
	if req.state == QUARANTINED then
		lateCount += 1
		release(req)
	end
end

-- Frames ------------------------------------------------------------------------------------------

-- The call's reliable frame was fired with `seq` at `now`.
function Calls.fired(id: number, seq: number, now: number): ()
	local req = byId[id]
	if req == nil or req.seq >= 0 then
		return
	end
	req.seq = seq
	req.sendTime = now
	if req.state == QUARANTINED and req.qUntil == math.huge then
		req.qUntil = math.max(req.qBase, now + req.route.timeout + QUARANTINE_AFTER_DEADLINE)
	end
end

function Calls.fireFailed(id: number): ()
	local req = byId[id]
	if req == nil or req.seq >= 0 then
		return
	end
	if req.state == PENDING then
		Calls.reject(req, Err.BadArgument, "Unserializable", nil, nil, nil)
	else
		release(req)
	end
end

function Calls.dropped(first: number, count: number): number
	local base = batchTop
	local k = base
	for _, req in byId do
		local s = req.seq
		if s >= 0 and (s - first) % SEQ_MOD < count then
			k += 1
			batchReqs[k] = req
			batchGens[k] = req.gen
		end
	end
	batchTop = k
	local n = 0
	for i = base + 1, k do
		local req = batchReqs[i] :: Req
		batchReqs[i] = nil
		if req.gen == batchGens[i] then
			if req.state == PENDING then
				n += 1
				Calls.reject(req, Err.RateLimited, nil, nil, nil, nil)
			elseif req.state == QUARANTINED then
				release(req) -- never processed by the server
			end
		end
	end
	batchTop = base
	return n
end

-- Sweeper -------------------------------------------------------------------------------------------

function Calls.sweep(now: number): ()
	if now < nextSweep then
		return
	end
	nextSweep = now + SWEEP_INTERVAL
	local base = batchTop
	local k = base
	for _, req in byId do
		local st = req.state
		if st == PENDING then
			if now >= req.deadline then
				k += 1
				batchReqs[k] = req
				batchGens[k] = req.gen
			end
		elseif now >= req.qUntil then
			release(req) -- clears an existing key during traversal (allowed)
		end
	end
	batchTop = k
	for i = base + 1, k do
		local req = batchReqs[i] :: Req
		batchReqs[i] = nil
		if req.gen == batchGens[i] and req.state == PENDING then
			local route, th, rj = req.route, req.thread, req.reject
			quarantine(req, now)
			timeoutCount += 1
			deliverReject(th, rj, route, Err.Timeout, nil, nil, nil, nil)
		end
	end
	batchTop = base
end

-- Boot failure: every pending call rejects BootFailed; quarantined ids are dropped.
function Calls.failAll(): ()
	local base = batchTop
	local k = base
	for _, req in byId do
		if req.state == PENDING then
			k += 1
			batchReqs[k] = req
			batchGens[k] = req.gen
		else
			release(req)
		end
	end
	batchTop = k
	for i = base + 1, k do
		local req = batchReqs[i] :: Req
		batchReqs[i] = nil
		if req.gen == batchGens[i] and req.state == PENDING then
			Calls.reject(req, Err.BootFailed, nil, nil, nil, nil)
		end
	end
	batchTop = base
end

-- Stats ---------------------------------------------------------------------------------------------

function Calls.pending(): number
	return live
end

function Calls.lateReplies(): number
	return lateCount
end

function Calls.timeouts(): number
	return timeoutCount
end

-- Reset ---------------------------------------------------------------------------------------------

function Calls._reset(): ()
	byId = {}
	live = 0
	nextId = 0
	maxPending = C.Default.MaxPending
	useTraces = true
	pool = {}
	poolN = 0
	nextSweep = 0
	lateCount = 0
	timeoutCount = 0
	clock = os.clock
	setup = nil
	table.clear(batchReqs)
	batchTop = 0
end

local STATE_NAME = { [FREE] = "free", [PENDING] = "pending", [QUARANTINED] = "quarantined" }

Calls._test = table.freeze({
	-- Fake clock for cancel-time quarantine (nil restores os.clock).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
	end,
	-- The next alloc starts after this id (tests id wrap-around).
	setNextId = function(id: number)
		nextId = id
	end,
	-- Snapshot of one record, or nil.
	record = function(id: number): { [string]: any }?
		local r = byId[id]
		if r == nil then
			return nil
		end
		return {
			id = r.id,
			state = STATE_NAME[r.state],
			seq = r.seq,
			sendTime = r.sendTime,
			deadline = r.deadline,
			qUntil = r.qUntil,
			try = r.thread ~= false,
		}
	end,
	-- Ids in use (pending + quarantined).
	held = function(): number
		local n = 0
		for _ in byId do
			n += 1
		end
		return n
	end,
	usesTraces = function(): boolean
		return useTraces or not hasPrivateNew
	end,
	maxPending = function(): number
		return maxPending
	end,
	-- Forces the next sweep to run regardless of SWEEP_INTERVAL.
	sweepNow = function(now: number)
		nextSweep = 0
		Calls.sweep(now)
	end,
})

return table.freeze(Calls)
