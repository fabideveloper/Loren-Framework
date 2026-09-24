--!strict
--!optimize 2
--[[
	Signal (owner: signals lane). The free runner, connections and the listener classes:
	LocalSignal (Controller Signals, Testing), ClientSignal (proxy.Signals.X, with the pre-Connect
	backlog) and ServerEvent (Service.ClientEvents.X, listeners under xpcall).
	Spec: design/loren-2.0/IMPLEMENTATION.md section 3.8 (blueprint section 4, robust 4.4-4.5 and 4.10 E).

	- Signal.spawn runs a function on a pooled runner thread via task.spawn(thread, fn, ...), so a call
	  that does not yield allocates no thread. The pool is a small stack (not one slot), so a nested
	  spawn (a Dispatch runner delivering a ClientEvent to its listeners) also reuses a runner.
	- Every class shares one listener list: a doubly linked list of connection nodes in connection
	  order. A fire walks from the head and stops at the last node that existed when it started
	  (compared by connection serial, so the walk stays right when that tail node itself is
	  disconnected mid-fire). It skips nodes with Connected == false; a disconnected node keeps
	  `_next`, so a running fire continues past it.
	- Requiring this module has no side effects.
]]

local C = require(script.Parent.Constants)
local Log = require(script.Parent.Log)
local Types = require(script.Parent.Types)

type Connection = Types.Connection
type LocalSignal = Types.LocalSignal
type ClientSignal = Types.ClientSignal
type ServerEvent = Types.ServerEvent

type Fn = (...any) -> ...any

-- A connection node. Uniform shape: `connect` sets every field.
type Node = {
	Connected: boolean,
	_fn: Fn,
	_prev: Node?,
	_next: Node?,
	_id: number, -- connection serial within its signal; a fire stops at the serial it started with
	_once: boolean, -- Once/Wait: unlinked right before its single call (the `done` guard)
	Disconnect: (...any) -> (),
	Destroy: (...any) -> (),
}

-- The listener list every signal object carries.
type List = {
	_head: Node?,
	_tail: Node?,
	_serial: number,
}

type ClientState = {
	_head: Node?,
	_tail: Node?,
	_serial: number,
	_service: string,
	_name: string,
	_cap: number, -- backlog entries kept before the first Connect (0 = 1.5.1 behavior)
	_everConnected: boolean,
	_buffering: boolean, -- never connected and the window is open: deliveries go to the backlog
	_draining: boolean, -- a replay is scheduled or running: deliveries are appended behind it
	_q: { any }, -- packed entries at [_qFirst, _qLast]
	_qFirst: number,
	_qLast: number,
	_warned: boolean,
}

type EventState = {
	_head: Node?,
	_tail: Node?,
	_serial: number,
	_service: string,
	_name: string,
	_logAt: number, -- clock() before which listener errors are only counted
	_errors: number, -- listener errors not logged since the last line
	_logged: number, -- listener error lines issued
	_onError: (err: any) -> any, -- xpcall handler, one closure per event
}

local PREFIX = C.PREFIX
local HANDLER_LOG_INTERVAL = C.Limit.HANDLER_LOG_INTERVAL
local BACKLOG_MAX = C.Limit.BACKLOG_MAX
local BACKLOG_LATEST = C.BACKLOG_LATEST

local RUNNER_POOL_MAX = 16 -- idle runners kept; a burst of yielding calls cannot pin more threads
local WINDOW_MAX = 86400

local MSG_CLIENT_FIRE = PREFIX .. "Signals are server-to-client; fire ClientEvents from the client"
local MSG_EVENT_FIRE = PREFIX .. "ClientEvents are client-to-server; use Signals to send to clients"

-- Module state (reset by Signal._reset) ----------------------------------------------------------

local idle: { thread } = {}
local idleN = 0
local clock: () -> number = os.clock
local backlogDropped = 0
local allClient: { ClientState } = {}
local pending: { ClientState } = {}
local pendingN = 0
local pumpScheduled = false
local pumpThread: thread? = nil
local windowThread: thread? = nil
local windowClosed = false
local epoch = 0 -- bumped by _reset; a replay that sees a new epoch stops touching state

local function noop(...: any) end

-- Runners --------------------------------------------------------------------------------------

local function runnerCall(me: thread, fn: Fn, ...: any)
	fn(...)
	-- Reached only when fn returned (it may have yielded in between). An error ends this thread
	-- instead (task.spawn reports it), so a failed runner is never pooled again.
	if idleN < RUNNER_POOL_MAX then
		idleN += 1
		idle[idleN] = me
	end
end

local function runnerLoop()
	-- The creator may be a Loren decode thread; user code on this runner is not Loren memory.
	debug.resetmemorycategory()
	local me = coroutine.running()
	-- Started with no arguments, so nothing a listener received stays referenced on this stack.
	while true do
		runnerCall(me, coroutine.yield())
	end
end

-- Signal.spawn: runs fn(...) now, on a pooled runner. Allocates a thread only when none is idle.
local function run(fn: Fn, ...: any)
	local runner: thread? = nil
	while idleN > 0 do
		local candidate = idle[idleN]
		idle[idleN] = nil
		idleN -= 1
		-- Skip a runner that someone else resumed or cancelled while it sat in the pool.
		if coroutine.status(candidate) == "suspended" then
			runner = candidate
			break
		end
	end
	if runner == nil then
		local created = coroutine.create(runnerLoop)
		coroutine.resume(created)
		runner = created
	end
	task.spawn(runner :: thread, fn, ...)
end

-- Listener lists -------------------------------------------------------------------------------

-- Unlinks a connected node in O(1). `_next` is kept, so a fire standing on this node continues.
local function unlink(sig: List, node: Node)
	node.Connected = false
	node._fn = noop
	local prev, nxt = node._prev, node._next
	if prev then
		prev._next = nxt
	else
		sig._head = nxt
	end
	if nxt then
		nxt._prev = prev
	else
		sig._tail = prev
	end
	node._prev = nil
end

local function connect(sig: List, fn: Fn, once: boolean): Node
	local serial = sig._serial + 1
	sig._serial = serial
	local tail = sig._tail
	local node: Node = {
		Connected = true,
		_fn = fn,
		_prev = tail,
		_next = nil,
		_id = serial,
		_once = once,
		Disconnect = noop,
		Destroy = noop,
	}
	-- Per-Connect closure: conn.Disconnect() and conn:Disconnect() both work; idempotent.
	local function disconnect(...: any)
		if node.Connected then
			unlink(sig, node)
		end
	end
	node.Disconnect = disconnect
	node.Destroy = disconnect
	if tail then
		tail._next = node
	else
		sig._head = node
	end
	sig._tail = node
	return node
end

local function disconnectAll(sig: List)
	local node = sig._head
	sig._head = nil
	sig._tail = nil
	while node do
		node.Connected = false
		node._fn = noop
		node._prev = nil
		node = node._next -- kept, so a running fire walks on and skips every node
	end
end

-- Runs every listener connected when the fire starts, in connection order, each on a runner.
local function fire(sig: List, ...: any)
	local stop = sig._serial
	local node = sig._head
	while node do
		if node._id > stop then
			break -- connected during this fire: runs from the next one
		end
		if node.Connected then
			local fn = node._fn
			if node._once then
				unlink(sig, node)
			end
			run(fn, ...)
		end
		node = node._next
	end
end

local function countConnected(sig: List): number
	local n = 0
	local node = sig._head
	while node do
		n += 1
		node = node._next
	end
	return n
end

local function afterWait(node: Node, ...: any): ...any
	node.Disconnect() -- no-op after a normal resume; a spurious resume must not leave it connected
	return ...
end

local function waiter(sig: List, class: string): Node
	if not coroutine.isyieldable() then
		error(PREFIX .. class .. ":Wait must be called from a thread that can yield", 3)
	end
	local thread = coroutine.running()
	return connect(sig, function(...: any)
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, ...)
		end
	end, true)
end

local function badSelf(class: string, method: string): never
	error(string.format("%s%s:%s must be called with ':' (signal:%s(...))", PREFIX, class, method, method), 3)
end

local function checkFn(class: string, method: string, fn: any)
	if type(fn) ~= "function" then
		error(string.format("%s%s:%s expects a function, got %s", PREFIX, class, method, typeof(fn)), 3)
	end
end

-- LocalSignal ----------------------------------------------------------------------------------

local LocalMethods = {}
local LocalMeta = {
	__index = LocalMethods,
	__tostring = function(_: any): string
		return "LocalSignal"
	end,
}

function LocalMethods.Fire(self: any, ...: any)
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "Fire")
	end
	fire(self, ...)
end

function LocalMethods.Connect(self: any, fn: any): Connection
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "Connect")
	end
	checkFn("LocalSignal", "Connect", fn)
	return connect(self, fn, false)
end

function LocalMethods.Once(self: any, fn: any): Connection
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "Once")
	end
	checkFn("LocalSignal", "Once", fn)
	return connect(self, fn, true)
end

function LocalMethods.Wait(self: any): ...any
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "Wait")
	end
	local node = waiter(self, "LocalSignal")
	return afterWait(node, coroutine.yield())
end

function LocalMethods.DisconnectAll(self: any)
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "DisconnectAll")
	end
	disconnectAll(self)
end

function LocalMethods.Destroy(self: any)
	if getmetatable(self) ~= LocalMeta then
		badSelf("LocalSignal", "Destroy")
	end
	disconnectAll(self)
end

table.freeze(LocalMethods)
table.freeze(LocalMeta)

local function newLocal(): LocalSignal
	local sig: List = { _head = nil, _tail = nil, _serial = 0 }
	return setmetatable(sig :: any, LocalMeta) :: any
end

-- ClientSignal backlog ---------------------------------------------------------------------------

local function clearQueue(sig: ClientState)
	sig._q = {}
	sig._qFirst = 1
	sig._qLast = 0
end

local function dropOldest(sig: ClientState)
	local first = sig._qFirst
	sig._q[first] = nil
	sig._qFirst = first + 1
	backlogDropped += 1
	if not sig._warned then
		sig._warned = true
		Log.studioOnce(
			"Signal.backlog." .. sig._service .. "." .. sig._name,
			string.format(
				"%s.Signals.%s: the backlog (%d) filled up before the first Connect, so the oldest messages"
					.. " are dropped. Connect in LorenIgnite, or raise Backlog in the Service Spec.",
				sig._service,
				sig._name,
				sig._cap
			)
		)
	end
end

-- Replays one signal's backlog to the listeners connected at each entry's turn.
-- Returns false when Signal._reset ran inside a listener (the new state is not ours to touch).
local function drain(sig: ClientState, myEpoch: number): boolean
	while sig._qFirst <= sig._qLast do
		local i = sig._qFirst
		local q = sig._q
		local entry = q[i]
		q[i] = nil
		sig._qFirst = i + 1
		fire(sig, table.unpack(entry, 1, entry.n))
		if epoch ~= myEpoch then
			return false
		end
	end
	clearQueue(sig)
	sig._draining = false -- buffering is already off: a signal is never re-armed
	return true
end

-- One deferred pump drains every signal first-connected before it runs. Signals first-connected by
-- a listener during the pump join the same loop, so no replay ever nests another task.defer.
local function pumpBody(myEpoch: number)
	local i = 1
	while i <= pendingN do
		if not drain(pending[i], myEpoch) then
			return
		end
		pending[i] = nil
		i += 1
	end
	pendingN = 0
	pumpScheduled = false
	pumpThread = nil
end

local function pumpMain()
	local myEpoch = epoch
	local ok, err = pcall(pumpBody :: any, myEpoch)
	if not ok and epoch == myEpoch then
		-- Never leave a signal stuck in draining: drop what is left, deliver live from now on.
		for i = 1, pendingN do
			local sig = pending[i]
			if sig then
				sig._draining = false
				clearQueue(sig)
			end
		end
		pending = {}
		pendingN = 0
		pumpScheduled = false
		pumpThread = nil
		Log.warnf("Signal backlog replay failed: %s", tostring(err))
	end
end

local function schedule(sig: ClientState)
	pendingN += 1
	pending[pendingN] = sig
	if not pumpScheduled then
		pumpScheduled = true
		-- task.defer can refuse past the engine's re-entrancy depth; the next Heartbeat still drains.
		local ok, thread = pcall(task.defer :: any, pumpMain)
		pumpThread = if ok then thread else task.delay(0, pumpMain)
	end
end

-- First Connect/Once/Wait: stop buffering for good and replay (deferred) what was buffered.
local function markConnected(sig: ClientState)
	if sig._everConnected then
		return
	end
	sig._everConnected = true
	sig._buffering = false
	if sig._qLast >= sig._qFirst then
		sig._draining = true
		schedule(sig)
	end
end

local function deliverClient(signal: ClientSignal, ...: any)
	local sig: ClientState = signal :: any
	if sig._draining or sig._buffering then
		-- While draining the replay runs within the frame, so the bound there is only a safety net.
		local limit = if sig._draining then sig._cap + BACKLOG_MAX else sig._cap
		if sig._qLast - sig._qFirst + 1 >= limit then
			dropOldest(sig)
		end
		local last = sig._qLast + 1
		sig._qLast = last
		sig._q[last] = table.pack(...)
	else
		fire(sig, ...) -- after the first Connect: no listeners = dropped, as with RBXScriptSignal
	end
end

local function expireWindow()
	windowThread = nil
	windowClosed = true
	for _, sig in allClient do
		if sig._buffering then
			sig._buffering = false
			clearQueue(sig)
		end
	end
end

local function startWindow(seconds: number)
	local previous = windowThread
	windowThread = nil
	if previous and coroutine.status(previous) == "suspended" then
		task.cancel(previous)
	end
	if type(seconds) == "number" and seconds > 0 then
		windowThread = task.delay(math.min(seconds, WINDOW_MAX), expireWindow)
	else
		expireWindow()
	end
end

local function backlogCap(backlog: any): number
	if type(backlog) ~= "number" or not (backlog > 0) then
		return 0
	elseif backlog == BACKLOG_LATEST then
		return 1 -- reserved "latest" value: keep one entry
	elseif backlog > BACKLOG_MAX then
		return BACKLOG_MAX
	end
	return math.floor(backlog)
end

local ClientMethods = {}
local ClientMeta = {
	__index = ClientMethods,
	__tostring = function(self: any): string
		return "Signal " .. self._service .. "." .. self._name
	end,
}

function ClientMethods.Connect(self: any, fn: any): Connection
	if getmetatable(self) ~= ClientMeta then
		badSelf("Signal", "Connect")
	end
	checkFn("Signal", "Connect", fn)
	local node = connect(self, fn, false)
	markConnected(self)
	return node
end

function ClientMethods.Once(self: any, fn: any): Connection
	if getmetatable(self) ~= ClientMeta then
		badSelf("Signal", "Once")
	end
	checkFn("Signal", "Once", fn)
	local node = connect(self, fn, true)
	markConnected(self)
	return node
end

function ClientMethods.Wait(self: any): ...any
	if getmetatable(self) ~= ClientMeta then
		badSelf("Signal", "Wait")
	end
	local node = waiter(self, "Signal")
	markConnected(self)
	return afterWait(node, coroutine.yield())
end

function ClientMethods.DisconnectAll(self: any)
	if getmetatable(self) ~= ClientMeta then
		badSelf("Signal", "DisconnectAll")
	end
	disconnectAll(self)
end

function ClientMethods.Fire(_: any, ...: any)
	error(MSG_CLIENT_FIRE, 2)
end
function ClientMethods.FireAll(_: any, ...: any)
	error(MSG_CLIENT_FIRE, 2)
end
function ClientMethods.FireFor(_: any, ...: any)
	error(MSG_CLIENT_FIRE, 2)
end
function ClientMethods.FireExcept(_: any, ...: any)
	error(MSG_CLIENT_FIRE, 2)
end

table.freeze(ClientMethods)
table.freeze(ClientMeta)

local function newClient(service: string, name: string, backlog: number): ClientSignal
	local cap = backlogCap(backlog)
	local sig: ClientState = {
		_head = nil,
		_tail = nil,
		_serial = 0,
		_service = service,
		_name = name,
		_cap = cap,
		_everConnected = false,
		_buffering = cap > 0 and not windowClosed,
		_draining = false,
		_q = {},
		_qFirst = 1,
		_qLast = 0,
		_warned = false,
	}
	table.insert(allClient, sig)
	return setmetatable(sig :: any, ClientMeta) :: any
end

-- ServerEvent ----------------------------------------------------------------------------------

local function uidOf(player: any): string
	if typeof(player) == "Instance" then
		if player:IsA("Player") then
			return tostring(player.UserId)
		end
		return player.Name
	elseif type(player) == "table" then
		return tostring(rawget(player, "UserId"))
	end
	return tostring(player)
end

-- Runs inside the xpcall handler: decides whether this error gets a log line before any string
-- (traceback included) is built. A client cannot cause more than one line per event per 10 s.
local function eventErrorText(ev: EventState, err: any): string?
	local now = clock()
	if now < ev._logAt or not Log.allowed() then
		ev._errors += 1
		return nil
	end
	ev._logAt = now + HANDLER_LOG_INTERVAL
	if type(err) == "string" then
		return err
	end
	local ok, text = pcall(tostring, err)
	if ok and type(text) == "string" then
		return text
	end
	return "(" .. typeof(err) .. " error)"
end

local function runProtected(ev: EventState, fn: Fn, player: any, ...: any)
	local ok, trace = xpcall(fn, ev._onError, player, ...)
	if not ok and trace ~= nil then
		ev._logged += 1
		local earlier = ev._errors
		ev._errors = 0
		if earlier > 0 then
			Log.warnf(
				"%s.ClientEvents.%s listener failed for uid=%s (+%d earlier errors not shown): %s",
				ev._service,
				ev._name,
				uidOf(player),
				earlier,
				tostring(trace)
			)
		else
			Log.warnf(
				"%s.ClientEvents.%s listener failed for uid=%s: %s",
				ev._service,
				ev._name,
				uidOf(player),
				tostring(trace)
			)
		end
	end
end

local function deliverEvent(event: ServerEvent, player: Player, ...: any)
	local ev: EventState = event :: any
	local stop = ev._serial
	local node = ev._head
	while node do
		if node._id > stop then
			break
		end
		if node.Connected then
			local fn = node._fn
			if node._once then
				unlink(ev, node)
			end
			run(runProtected, ev, fn, player, ...)
		end
		node = node._next
	end
end

local EventMethods = {}
local EventMeta = {
	__index = EventMethods,
	__tostring = function(self: any): string
		return "ClientEvent " .. self._service .. "." .. self._name
	end,
}

function EventMethods.Connect(self: any, fn: any): Connection
	if getmetatable(self) ~= EventMeta then
		badSelf("ClientEvent", "Connect")
	end
	checkFn("ClientEvent", "Connect", fn)
	return connect(self, fn, false)
end

function EventMethods.Once(self: any, fn: any): Connection
	if getmetatable(self) ~= EventMeta then
		badSelf("ClientEvent", "Once")
	end
	checkFn("ClientEvent", "Once", fn)
	return connect(self, fn, true)
end

function EventMethods.Wait(self: any): ...any
	if getmetatable(self) ~= EventMeta then
		badSelf("ClientEvent", "Wait")
	end
	local node = waiter(self, "ClientEvent")
	return afterWait(node, coroutine.yield())
end

function EventMethods.DisconnectAll(self: any)
	if getmetatable(self) ~= EventMeta then
		badSelf("ClientEvent", "DisconnectAll")
	end
	disconnectAll(self)
end

function EventMethods.Fire(_: any, ...: any)
	error(MSG_EVENT_FIRE, 2)
end
function EventMethods.FireAll(_: any, ...: any)
	error(MSG_EVENT_FIRE, 2)
end
function EventMethods.FireFor(_: any, ...: any)
	error(MSG_EVENT_FIRE, 2)
end
function EventMethods.FireExcept(_: any, ...: any)
	error(MSG_EVENT_FIRE, 2)
end

table.freeze(EventMethods)
table.freeze(EventMeta)

local function newEvent(service: string, name: string): ServerEvent
	local ev: EventState = {
		_head = nil,
		_tail = nil,
		_serial = 0,
		_service = service,
		_name = name,
		_logAt = -math.huge,
		_errors = 0,
		_logged = 0,
		_onError = noop,
	}
	ev._onError = function(err: any): any
		local text = eventErrorText(ev, err)
		if text == nil then
			return nil
		end
		return debug.traceback(text, 2)
	end
	return setmetatable(ev :: any, EventMeta) :: any
end

-- Stats and reset --------------------------------------------------------------------------------

local function stats(): { backlogDropped: number }
	return { backlogDropped = backlogDropped }
end

local function reset()
	epoch += 1
	local pumpT = pumpThread
	pumpThread = nil
	if pumpT and coroutine.status(pumpT) == "suspended" then
		task.cancel(pumpT)
	end
	pumpScheduled = false
	pending = {}
	pendingN = 0
	local windowT = windowThread
	windowThread = nil
	if windowT and coroutine.status(windowT) == "suspended" then
		task.cancel(windowT)
	end
	windowClosed = false
	-- Signals from before the reset become inert: no listeners, no backlog, never buffering again.
	for _, sig in allClient do
		disconnectAll(sig)
		sig._everConnected = true
		sig._buffering = false
		sig._draining = false
		clearQueue(sig)
	end
	allClient = {}
	backlogDropped = 0
	-- Pooled runners are this module's own threads: close them (a runner still running a listener
	-- is not pooled and returns to the fresh pool when it finishes).
	for i = 1, idleN do
		local runner = idle[i]
		if coroutine.status(runner) == "suspended" then
			task.cancel(runner)
		end
	end
	idle = {}
	idleN = 0
	clock = os.clock
end

local test = table.freeze({
	-- Replaces the clock of the ServerEvent log throttle (nil restores os.clock).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
	end,
	idleRunners = function(): number
		return idleN
	end,
	-- The runner the next Signal.spawn will take (nil when the pool is empty).
	topRunner = function(): thread?
		return if idleN > 0 then idle[idleN] else nil
	end,
	-- Listeners currently linked (connected) on any signal object.
	listeners = function(sig: any): number
		return countConnected(sig)
	end,
	backlog = function(sig: any): {
		cap: number,
		size: number,
		everConnected: boolean,
		buffering: boolean,
		draining: boolean,
	}
		local s: ClientState = sig
		return {
			cap = s._cap,
			size = s._qLast - s._qFirst + 1,
			everConnected = s._everConnected,
			buffering = s._buffering,
			draining = s._draining,
		}
	end,
	eventLog = function(ev: any): { logged: number, suppressed: number }
		local e: EventState = ev
		return { logged = e._logged, suppressed = e._errors }
	end,
	pumpScheduled = function(): boolean
		return pumpScheduled
	end,
	windowClosed = function(): boolean
		return windowClosed
	end,
})

return table.freeze({
	spawn = run,
	LocalSignal = table.freeze({
		new = newLocal,
	}),
	ClientSignal = table.freeze({
		new = newClient,
		deliver = deliverClient,
		startWindow = startWindow,
	}),
	ServerEvent = table.freeze({
		new = newEvent,
		deliver = deliverEvent,
	}),
	stats = stats,
	_reset = reset,
	_test = test,
})
