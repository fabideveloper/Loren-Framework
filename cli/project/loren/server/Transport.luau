--!strict
--!optimize 2

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Codec = require(Runtime.Codec)
local Log = require(Runtime.Log)
local Signal = require(Runtime.Signal)
local Outbox = require(script.Parent.Outbox)
local Dispatch = require(script.Parent.Dispatch)
local Limits = require(script.Parent.Limits)
local Violations = require(script.Parent.Violations)

type Route = Outbox.Route
type RouteTable = Outbox.RouteTable
type PlayerState = Outbox.PlayerState

type Parse = {
	owner: number,
	busy: boolean,
	pos: number,
	node: any,
	stop: number,
	ps: any,
	player: any,
	frame: buffer,
	len: number,
	nmsg: number,
	refs: any,
	nrefs: number,
	isUnreliable: boolean,
	seq: number,
	now: number,
	p: number,
	ev: any,
	evN: number,
	a1: any,
	args: { any },
}

local N = C.Names
local L = C.Limit
local V = C.Violation
local DROP = C.Drop
local ERR = C.Err

local C2S_HEADER = C.C2S_HEADER
local MIN_FRAME = L.MIN_FRAME
local C2S_MAX_FRAME = L.C2S_MAX_FRAME
local UNRELIABLE_MAX_FRAME = L.UNRELIABLE_MAX_FRAME
local MAX_MSGS = L.MAX_MSGS_PER_FRAME
local MIN_CHARGE = L.MIN_CHARGE
local REF_CHARGE = L.REF_CHARGE
local REHELLO_MIN = L.REHELLO_MIN
local ORDERED_RESET = L.ORDERED_RESET
local SEMANTIC_MIN = C.DECODE_SEMANTIC_MIN
local DECODE_NAME: { [number]: string } = C.DecodeName :: any
local PROTO = C.PROTO
local NEG_HELLO = -C.Op.HELLO
local KIND_METHOD = C.Kind.Method
local KIND_SIGNAL = C.Kind.Signal
local NOTICE_SHUTTING_DOWN = C.Notice.ShuttingDown
local ARGV_CLEAR_MAX = 256
local MEMORY_CATEGORY = N.MemoryCategory
local ABANDONED = -1
local DELIVER = -2
local NO_FRAME = buffer.create(0)

local V_ENVELOPE = V.Envelope
local V_EXTRA_ARGS = V.ExtraArgs
local V_FRAME_SIZE = V.FrameSize
local V_REFS = V.Refs
local V_FRAMING = V.Framing
local V_BAD_OP = V.BadOp
local V_ROUTE = V.Route
local V_BEFORE_HELLO = V.BeforeHello
local V_REPEAT_HELLO = V.RepeatHello
local V_DUPLICATE_CALL = V.DuplicateCall
local V_PAYLOAD = V.Payload
local V_SIDECAR = V.Sidecar

local DROP_FRAME = DROP.FrameDropped
local DROP_RATE_LIMITED = DROP.RateLimited
local DROP_BAD_REQUEST = DROP.BadRequest
local DROP_BUSY = DROP.Busy
local DROP_EVENT_LIMITED = DROP.EventLimited
local DROP_EVENT_BAD = DROP.EventBad
local DROP_STALE = DROP.Stale
local DROP_SUPPRESSED = DROP.RepliesSuppressed

local ADM_BUSY: number = Dispatch.BUSY

local readVarint = Codec.readVarint
local readHead = Codec.readHead
local beginFrame = Codec.beginFrame
local walkSidecar = Codec.walkSidecar
local admitFrame = Limits.admitFrame
local chargeBytes = Limits.chargeBytes
local takeRoute = Limits.takeRoute
local allowRateLimitedReply = Limits.allowRateLimitedReply
local allowBadRequestReply = Limits.allowBadRequestReply
local record = Violations.record
local drop = Violations.drop
local sendErr = Outbox.sendErr
local admit = Dispatch.admit
local accept = Dispatch.accept
local event = Dispatch.event
local mwState = Dispatch.mwState
local drive = Signal.drive
local deliverEvent = Signal.ServerEvent.deliver
local deliverEventIn = Signal.ServerEvent.deliverIn
local deliverEventIn1 = Signal.ServerEvent.deliverIn1
local quietEvent = Signal.ServerEvent.quiet

local EMPTY_ROUTES: { Route } = table.freeze({}) :: any

-- Module state (restored by _reset) ----------------------------------------------------------------

local online = false -- prepared with remotes (or attached by a spec): frames, flushes, shutdown
local failed = false
local shuttingDown = false
local current: RouteTable? = nil
local routes: { Route } = EMPTY_ROUTES
local manifestMsg: buffer? = nil
local net: Folder? = nil
local reliable: RemoteEvent? = nil
local unreliable: UnreliableRemoteEvent? = nil
local connections: { RBXScriptConnection } = {}
local flushThread: thread? = nil
local flushScheduled = false
local generation = 0 -- bumped by prepare/_reset; an old flush thread sees it and ends
local clock: () -> number = os.clock
local parseFaultLogged = false
local spareParse: Parse? = nil

-- The server's decoder state: one ReadCtx and one argv (section 9 Scratch ownership).
local ctx: Types.ReadCtx = Codec.newReadCtx(true, true)
local argv: { any } = table.create(32)

local framesIn = 0
local bytesIn = 0
local messagesIn = 0

local Transport = {}

-- Helpers ------------------------------------------------------------------------------------------

local function clearArgv(n: number, max: number)
	local k = if n > max then n else max
	if k > ARGV_CLEAR_MAX then
		k = ARGV_CLEAR_MAX
	end
	for i = 1, k do
		argv[i] = nil
	end
end

local function disconnectAll()
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)
	flushThread = nil
	flushScheduled = false
end

local function destroyRemotes()
	Outbox.bind(nil, nil)
	if reliable ~= nil then
		reliable:Destroy()
		reliable = nil
	end
	if unreliable ~= nil then
		unreliable:Destroy()
		unreliable = nil
	end
end

-- HELLO (section 4.10 onHello). Returns 0 or RepeatHello.
local function onHello(ps: PlayerState, now: number): number
	if ps.helloed then
		if now - ps.lastHello < REHELLO_MIN then
			return if ps.helloOnly then 0 else V_REPEAT_HELLO
		end
		-- The client restarted: its calls are gone.
		Dispatch.abandonAll(ps)
	end
	table.clear(ps.rxSeq)
	table.clear(ps.rxSeqT)
	local m = manifestMsg
	if m == nil then
		return 0
	end
	Outbox.hello(ps, m, now)
	if shuttingDown then
		Outbox.notice(ps, NOTICE_SHUTTING_DOWN, 0, 0)
	end
	return 0
end

-- Receive ------------------------------------------------------------------------------------------

local function dropArgs(st: Parse)
	local n = st.evN
	st.a1 = nil
	if n > 1 then
		local args = st.args
		for i = 1, n do
			args[i] = nil
		end
	end
	st.evN = 0
end

-- Section 4.10 step 8: every message of an admitted frame. Returns 0, ABANDONED, DELIVER or a C.Violation kind.
@native
local function parse(st: Parse, me: number): number
	local c = ctx
	local len, nmsg = st.len, st.nmsg
	local isUnreliable = st.isUnreliable
	local now = st.now
	local i = st.pos
	local p = st.p
	if i == 0 then
		local ps: PlayerState = st.ps
		local nrefs = st.nrefs
		beginFrame(c, st.refs, nrefs)
		-- a. The sidecar, before the first message.
		if nrefs > 0 then
			local status, cost = walkSidecar(st.refs, nrefs, c)
			if status ~= 0 then
				return V_SIDECAR
			end
			if not chargeBytes(ps.lim, cost, now) then
				Outbox.recordDrop(ps, isUnreliable, st.seq)
				drop(ps.viol, DROP_FRAME, 1)
				return 0
			end
		end
	end
	-- b. Exactly nmsg messages.
	while i < nmsg do
		if st.owner ~= me then
			return ABANDONED
		end
		i += 1
		local ev: any = nil
		local evN = 0
		local a1: any = nil
		do
			local frame: buffer = st.frame
			local ps: PlayerState = st.ps
			local lim = ps.lim
			local viol = ps.viol
			local b0 = if p < len then buffer.readu8(frame, p) else 0x80
			local mlen, q0
			if b0 < 0x80 then
				mlen, q0 = b0, p + 1
			else
				mlen, q0 = readVarint(frame, p, len)
			end
			if mlen < 1 or mlen > len - q0 then
				return V_FRAMING
			end
			local mend = q0 + mlen
			local h, q = buffer.readu8(frame, q0), q0 + 1
			if h == 0 or h > 0xDF then
				h, q = readHead(frame, q0, mend)
			end
			if h == 0 then
				return V_FRAMING
			end
			if h < 0 then
				-- Control: only HELLO flows C->S.
				if h ~= NEG_HELLO then
					return V_BAD_OP
				end
				if isUnreliable or nmsg ~= 1 or st.nrefs ~= 0 or mlen ~= 2 then
					return V_FRAMING
				end
				if buffer.readu8(frame, q) ~= PROTO then
					return V_BAD_OP
				end
				local hs = onHello(ps, now)
				if hs ~= 0 then
					return hs
				end
				p = mend
				continue
			end
			if not ps.helloed then
				return V_BEFORE_HELLO
			end
			ps.helloOnly = false
			local route = routes[h]
			local kind = if route then route.kind else KIND_SIGNAL
			if kind == KIND_SIGNAL or (route :: Route).unreliable ~= isUnreliable then
				return V_ROUTE
			end
			local args = route.args
			if kind == KIND_METHOD then
				-- b.6 Method
				if not takeRoute(lim, h, route.rate, route.burst, now) then
					if q + 2 <= mend then
						local callId = buffer.readu16(frame, q)
						if callId ~= 0 and allowRateLimitedReply(lim, h, now) then
							sendErr(ps, callId, ERR.RateLimited, nil, nil, false, nil)
						else
							drop(viol, DROP_SUPPRESSED, 1)
						end
					end
					drop(viol, DROP_RATE_LIMITED, 1)
					p = mend
					continue
				end
				if q + 2 > mend then
					return V_FRAMING
				end
				local callId = buffer.readu16(frame, q)
				q += 2
				if callId == 0 or ps.callTok[callId] ~= nil then
					return V_DUPLICATE_CALL
				end
				if shuttingDown then
					sendErr(ps, callId, ERR.ShuttingDown, nil, nil, false, nil)
					p = mend
					continue
				end
				local adm = admit(ps, route)
				if adm == ADM_BUSY then
					sendErr(ps, callId, ERR.Busy, nil, nil, false, nil)
					drop(viol, DROP_BUSY, 1)
					p = mend
					continue
				end
				c.err = 0
				c.errArg = 0
				c.nodes = 0
				c.claimed = 0
				c.allowNonFinite = route.allowNonFinite
				local n, qe = args.decode(frame, q, mend, c, argv)
				local err = c.err
				if err ~= 0 then
					clearArgv(n, args.maxArgs)
					if err < SEMANTIC_MIN then
						return V_PAYLOAD
					end
					if allowBadRequestReply(lim, now) then
						sendErr(ps, callId, ERR.BadRequest, DECODE_NAME[err], c.errArg, true, nil)
					else
						drop(viol, DROP_SUPPRESSED, 1)
					end
					drop(viol, DROP_BAD_REQUEST, 1)
					p = mend
					continue
				end
				if qe ~= mend then
					clearArgv(n, args.maxArgs)
					return V_PAYLOAD
				end
				accept(ps, route, callId, adm, argv, n, now)
				if n == 1 then
					argv[1] = nil
				else
					clearArgv(n, 0)
				end
				messagesIn += 1
				p = mend
				continue
			end
			-- b.7 Event
			if not takeRoute(lim, h, route.rate, route.burst, now) then
				drop(viol, DROP_EVENT_LIMITED, 1)
				p = mend
				continue
			end
			if route.ordered then
				if q + 2 > mend then
					return V_FRAMING
				end
				local s = buffer.readu16(frame, q)
				q += 2
				local last = ps.rxSeq[h]
				if last ~= nil and now - ps.rxSeqT[h] <= ORDERED_RESET then
					local d = (s - last) % 65536
					if d == 0 or d >= 32768 then
						drop(viol, DROP_STALE, 1)
						p = mend
						continue
					end
				end
				ps.rxSeq[h] = s
				ps.rxSeqT[h] = now
			end
			c.err = 0
			c.errArg = 0
			c.nodes = 0
			c.claimed = 0
			c.allowNonFinite = route.allowNonFinite
			local n, qe = args.decode(frame, q, mend, c, argv)
			local err = c.err
			if err ~= 0 then
				clearArgv(n, args.maxArgs)
				if err < SEMANTIC_MIN then
					return V_PAYLOAD
				end
				drop(viol, DROP_EVENT_BAD, 1)
				p = mend
				continue
			end
			if qe ~= mend then
				clearArgv(n, args.maxArgs)
				return V_PAYLOAD
			end
			local module: any = route.module
			local guarded = mwState.n > 0
			if not guarded and type(module) == "table" then
				local t: any = rawget(module, "Middleware")
				guarded = if t == nil
					then getmetatable(module) ~= nil
					else type(t) == "table" and rawget(t, route.member) ~= nil
			end
			if guarded and event(ps, route, argv, n) then
				if n == 1 then
					argv[1] = nil
				else
					clearArgv(n, 0)
				end
				messagesIn += 1
				p = mend
				continue
			end
			local target: Types.ServerEvent = route.event :: any
			if me == 0 then
				if i < nmsg and not quietEvent(target) then
					st.pos = i
					st.p = mend
					st.ev = target
					st.evN = n
					if n == 1 then
						st.a1 = argv[1]
						argv[1] = nil
					elseif n > 1 then
						table.move(argv, 1, n, 1, st.args)
						clearArgv(n, 0)
					end
					return DELIVER
				end
				if n == 1 then
					deliverEvent(target, ps.player, argv[1])
					argv[1] = nil
				else
					deliverEvent(target, ps.player, table.unpack(argv, 1, n))
					clearArgv(n, 0)
				end
				messagesIn += 1
				p = mend
				continue
			end
			st.pos = i
			st.p = mend
			st.ev = target
			st.evN = n
			if n == 1 then
				a1 = argv[1]
				argv[1] = nil
				st.a1 = a1
			elseif n > 1 then
				table.move(argv, 1, n, 1, st.args)
				clearArgv(n, 0)
			end
			ev = target
			evN = n
			p = mend
		end
		local delivered = if evN == 1
			then deliverEventIn1(st, me, ev, st.player, a1)
			else deliverEventIn(st, me, ev, st.player, table.unpack(st.args, 1, evN))
		if not delivered then
			return ABANDONED
		end
		st.ev = nil
		if evN > 1 then
			dropArgs(st)
		else
			st.a1 = nil
			st.evN = 0
		end
		messagesIn += 1
	end
	-- c. Nothing may follow the last message.
	if p ~= len then
		return V_FRAMING
	end
	return 0
end

local function finishFrame(st: Parse, ok: boolean, status: any)
	local ps, player, now = st.ps, st.player, st.now
	if st.nrefs > 0 then
		beginFrame(ctx, nil, 0) -- releases the frame's refs
	end
	st.ps = nil
	st.player = nil
	st.frame = NO_FRAME
	st.refs = nil
	st.ev = nil
	dropArgs(st)
	if not ok then
		if not parseFaultLogged then
			parseFaultLogged = true
			Log.warnf("a frame from uid=%d failed to decode (backstop): %s", player.UserId, tostring(status))
		end
		clearArgv(0, ARGV_CLEAR_MAX)
		record(player, ps.viol, V_PAYLOAD, now)
	elseif status > 0 then
		record(player, ps.viol, status, now)
	end
end

local function deliverLoop(st: Parse, me: number): number
	local ev = st.ev
	if ev == nil then
		error("the frame parse stopped outside a listener", 0)
	end
	local n = st.evN
	local delivered = if n == 1
		then deliverEventIn1(st, me, ev, st.player, st.a1)
		else deliverEventIn(st, me, ev, st.player, table.unpack(st.args, 1, n))
	if not delivered then
		return ABANDONED
	end
	st.ev = nil
	dropArgs(st)
	messagesIn += 1
	return parse(st, me)
end

local function parseBody(st: Parse, me: number)
	local ok, status = pcall(deliverLoop, st, me)
	if st.owner ~= me then
		return
	end
	st.busy = false
	finishFrame(st, ok, status)
end

local function newParse(): Parse
	return {
		owner = 0,
		busy = false,
		pos = 0,
		node = nil,
		stop = 0,
		ps = nil,
		player = nil,
		frame = NO_FRAME,
		len = 0,
		nmsg = 0,
		refs = nil,
		nrefs = 0,
		isUnreliable = false,
		seq = 0,
		now = 0,
		p = 0,
		ev = nil,
		evN = 0,
		a1 = nil,
		args = {},
	}
end

-- One remote invocation (section 4.10 steps 1-8). `extra` = arguments after (frame, refs).
local function onFrame(isUnreliable: boolean, player: Player, frame: any, refs: any, extra: number)
	local ps = Outbox.get(player)
	if ps == nil or ps.gone then
		return
	end
	local now = clock()
	if typeof(frame) ~= "buffer" then
		record(player, ps.viol, V_ENVELOPE, now)
		return
	end
	if extra ~= 0 then
		record(player, ps.viol, V_EXTRA_ARGS, now)
		return
	end
	local b: buffer = frame
	local len = buffer.len(b)
	if len < MIN_FRAME or len > (if isUnreliable then UNRELIABLE_MAX_FRAME else C2S_MAX_FRAME) then
		record(player, ps.viol, V_FRAME_SIZE, now)
		return
	end
	local seq = buffer.readu16(b, C.OFF_SEQ)
	local nmsg = buffer.readu16(b, C.OFF_NMSG)
	local nrefs = buffer.readu8(b, C.OFF_NREFS)
	if isUnreliable then
		if nrefs ~= 0 or refs ~= nil then
			record(player, ps.viol, V_REFS, now)
			return
		end
	else
		if (nrefs == 0) ~= (refs == nil) then
			record(player, ps.viol, V_REFS, now)
			return
		end
		if nrefs > 0 and type(refs) ~= "table" then
			record(player, ps.viol, V_ENVELOPE, now)
			return
		end
	end
	if nmsg == 0 or nmsg > MAX_MSGS or 2 * nmsg > len - C2S_HEADER then
		record(player, ps.viol, V_FRAMING, now)
		return
	end
	if not admitFrame(ps.lim, isUnreliable, math.max(len, MIN_CHARGE) + REF_CHARGE * nrefs, nmsg, now) then
		Outbox.recordDrop(ps, isUnreliable, seq)
		drop(ps.viol, DROP_FRAME, 1)
		return
	end
	framesIn += 1
	bytesIn += len
	local st = spareParse or newParse()
	spareParse = nil
	st.ps = ps
	st.player = player
	st.frame = b
	st.len = len
	st.nmsg = nmsg
	st.refs = refs
	st.nrefs = nrefs
	st.isUnreliable = isUnreliable
	st.seq = seq
	st.now = now
	st.pos = 0
	st.p = C2S_HEADER
	st.node = nil
	st.ev = nil
	st.evN = 0
	st.owner = 0
	st.busy = true
	local ok, status = pcall(parse, st, 0)
	if ok and status == DELIVER then
		local driven, done = pcall(drive, parseBody, st)
		if not driven or not done then
			st.busy = false
			finishFrame(st, false, if driven then "the frame parse stopped outside a listener" else done)
		end
	else
		st.busy = false
		finishFrame(st, ok, status)
	end
	spareParse = st
end

local function onPlayerAdded(player: Player)
	-- A deferred PlayerAdded can run after the player already left.
	if player.Parent ~= Players then
		return
	end
	Outbox.addPlayer(player, clock())
end

local function onPlayerRemoving(player: Player)
	local ps = Outbox.removePlayer(player)
	if ps ~= nil then
		Dispatch.onLeave(ps)
	end
end

-- Flush --------------------------------------------------------------------------------------------

local function flushLoop(gen: number)
	while generation == gen do
		flushScheduled = false
		local now = clock()
		debug.setmemorycategory(MEMORY_CATEGORY)
		Outbox.flushAll(now)
		debug.resetmemorycategory()
		-- The watchdog may start queued calls (user code): outside the Loren memory category.
		local ok, err = pcall(Dispatch.sweep :: any, now)
		if not ok then
			Log.once("sweep", "the call watchdog failed: " .. tostring(err))
		end
		coroutine.yield()
	end
end

local function newFlushThread(): thread
	local gen = generation
	return coroutine.create(function()
		flushLoop(gen)
	end)
end

local function onHeartbeat()
	if flushScheduled then
		return
	end
	local thread = flushThread
	if thread == nil then
		return
	end
	if coroutine.status(thread) == "dead" then
		thread = newFlushThread()
		flushThread = thread
	end
	flushScheduled = true
	task.defer(thread)
end

-- API ----------------------------------------------------------------------------------------------

-- Server boot step 2: creates and parents LorenNet (State "Booting", Proto 2). Offline: nothing.
function Transport.claim(offline: boolean): (boolean, string?)
	if offline then
		return true, nil
	end
	if ReplicatedStorage:FindFirstChild(N.NetFolder) ~= nil then
		return false, "ReplicatedStorage.LorenNet already exists (two Loren runtimes?)"
	end
	local folder = Instance.new("Folder")
	folder.Name = N.NetFolder
	folder:SetAttribute(N.StateAttr, C.NetState.Booting)
	folder:SetAttribute(N.ProtoAttr, C.PROTO)
	folder.Parent = ReplicatedStorage
	net = folder
	failed = false
	return true, nil
end

function Transport.prepare(rt: RouteTable, offline: boolean): ()
	disconnectAll()
	destroyRemotes()
	current = rt
	routes = rt.routes
	manifestMsg = rt.manifestMsg
	shuttingDown = false
	Dispatch.configure()
	generation += 1
	if offline then
		online = false
		return
	end
	local rel = Instance.new("RemoteEvent")
	rel.Name = N.Reliable
	local unrel = Instance.new("UnreliableRemoteEvent")
	unrel.Name = N.Unreliable
	reliable = rel
	unreliable = unrel
	-- Listeners exist before the remotes are visible, so no early frame is queued by the engine.
	table.insert(
		connections,
		rel.OnServerEvent:Connect(function(player: Player, frame: any, refs: any, ...: any)
			onFrame(false, player, frame, refs, select("#", ...))
		end)
	)
	table.insert(
		connections,
		unrel.OnServerEvent:Connect(function(player: Player, frame: any, refs: any, ...: any)
			onFrame(true, player, frame, refs, select("#", ...))
		end)
	)
	Outbox.bind(rel, unrel)
	table.insert(connections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(connections, Players.PlayerRemoving:Connect(onPlayerRemoving))
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	flushThread = newFlushThread()
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))
	online = true
end

-- Server boot step 10: parents the remotes, then LorenNet.State = "Ready". Offline: no-op.
function Transport.open(): ()
	local folder = net
	if not online or folder == nil then
		return
	end
	if reliable ~= nil then
		reliable.Parent = folder
	end
	if unreliable ~= nil then
		unreliable.Parent = folder
	end
	folder:SetAttribute(N.StateAttr, C.NetState.Ready)
end

-- Boot failure (safe at any step, idempotent): remotes destroyed, State "Failed".
function Transport.fail(): ()
	if failed then
		return
	end
	failed = true
	disconnectAll()
	destroyRemotes()
	online = false
	local list = Outbox.players()
	for i = #list, 1, -1 do
		local ps = Outbox.removePlayer(list[i].player)
		if ps ~= nil then
			Dispatch.onLeave(ps)
		end
	end
	if net ~= nil then
		net:SetAttribute(N.StateAttr, C.NetState.Failed)
	end
end

function Transport.shutdown(): ()
	if not online then
		return
	end
	shuttingDown = true
	for _, ps in Outbox.players() do
		if ps.helloed then
			Outbox.notice(ps, NOTICE_SHUTTING_DOWN, 0, 0)
		end
	end
	if net ~= nil then
		net:SetAttribute(N.StateAttr, C.NetState.ShuttingDown)
	end
	Outbox.flushAll(clock())
end

-- Loren.Flush() on the server: the flush body, now (no-op before networking exists).
function Transport.flushNow(): ()
	if not online then
		return
	end
	Outbox.flushAll(clock())
end

-- Loren.GetStats() on the server (a fresh table; zeros before boot).
function Transport.getStats(): Types.Stats
	local totals = Violations.totals()
	local drops = totals.drops
	local framesOut, bytesOut, messagesOut, players = Outbox.counters()
	local running, zombies = Dispatch.counters()
	local rt = current
	return {
		Side = "Server",
		FramesIn = framesIn,
		FramesOut = framesOut,
		BytesIn = bytesIn,
		BytesOut = bytesOut,
		MessagesIn = messagesIn,
		MessagesOut = messagesOut,
		FramesDropped = drops[DROP_FRAME] or 0,
		EventsLost = 0,
		CallsRateLimited = drops[DROP_RATE_LIMITED] or 0,
		BadRequests = drops[DROP_BAD_REQUEST] or 0,
		Busy = drops[DROP_BUSY] or 0,
		Violations = totals.violations,
		LateReplies = 0,
		OutboxDropped = (drops[DROP.OutboxOverflow] or 0) + (drops[DROP.OutboxExpired] or 0),
		SignalsDropped = (drops[DROP.UnreliableEarly] or 0) + (drops[DROP.Departed] or 0),
		RunningCalls = running,
		ZombieCalls = zombies,
		PendingCalls = 0,
		Players = players,
		Routes = if rt then rt.count else 0,
	}
end

function Transport._reset(): ()
	generation += 1
	disconnectAll()
	destroyRemotes()
	if net ~= nil then
		net:Destroy()
		net = nil
	end
	online = false
	failed = false
	shuttingDown = false
	current = nil
	routes = EMPTY_ROUTES
	manifestMsg = nil
	clock = os.clock
	parseFaultLogged = false
	beginFrame(ctx, nil, 0)
	table.clear(argv)
	framesIn = 0
	bytesIn = 0
	messagesIn = 0
end

-- Spec hooks (section 10): drive the receive path with test doubles and captured fires.
Transport._test = table.freeze({
	attach = function(rt: RouteTable)
		disconnectAll()
		destroyRemotes()
		current = rt
		routes = rt.routes
		manifestMsg = rt.manifestMsg
		shuttingDown = false
		failed = false
		Dispatch.configure()
		online = true
	end,
	-- A player state for `player` (a real Player or a double { UserId = n, Kick = fn }).
	addPlayer = function(player: any): PlayerState
		return Outbox.addPlayer(player, clock())
	end,
	-- The leave path (PlayerRemoving).
	removePlayer = function(player: any)
		onPlayerRemoving(player)
	end,
	-- One remote invocation: frame(unreliable, player, frame, refs, ...extra).
	frame = function(isUnreliable: boolean, player: any, frame: any, refs: any, ...: any)
		onFrame(isUnreliable, player, frame, refs, select("#", ...))
	end,
	-- Replaces os.clock in Transport, Outbox and Dispatch (nil restores it).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
		Outbox._test.setClock(fn)
		Dispatch._test.setClock(fn)
	end,
	-- One flush (as the Heartbeat loop would run it) and one watchdog pass.
	flush = function()
		Outbox.flushAll(clock())
	end,
	sweep = function(now: number?)
		Dispatch.sweep(now or clock())
	end,
	state = function(player: any): PlayerState?
		return Outbox.get(player)
	end,
	isShuttingDown = function(): boolean
		return shuttingDown
	end,
	-- The decoder's argv (every slot must be nil between frames).
	argv = function(): { any }
		return argv
	end,
	refsHeld = function(): boolean
		return ctx.refs ~= nil
	end,
	net = function(): Folder?
		return net
	end,
})

return table.freeze(Transport)
