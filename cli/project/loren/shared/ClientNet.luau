--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Codec = require(script.Parent.Codec)
local Schema = require(script.Parent.Schema)
local Manifest = require(script.Parent.Manifest)
local Signal = require(script.Parent.Signal)
local Bucket = require(script.Parent.Bucket)
local Config = require(script.Parent.Config)
local Errors = require(script.Parent.Errors)
local Log = require(script.Parent.Log)
local Calls = require(script.Parent.Calls)

type Writer = Types.Writer
type ReadCtx = Types.ReadCtx
type PayloadCodec = Types.PayloadCodec
type Req = Calls.Req
type BucketT = { tokens: number, stamp: number, rate: number, burst: number }

-- One networked member as the client sees it (built from the manifest; frozen).
export type ClientRoute = {
	id: number,
	kind: number,
	service: string,
	member: string,
	unreliable: boolean,
	ordered: boolean,
	coalesce: boolean,
	allowNonFinite: boolean,
	timeout: number,
	rate: number,
	burst: number,
	backlog: number,
	args: Types.PayloadCodec, -- Method/Event: C->S encode; Signal: S->C decode
	returns: Types.PayloadCodec | false, -- Method: S->C decode
	signal: Types.ClientSignal | false, -- Signal routes
	scalar: number, -- Signal routes: Schema.scalarOp of the Args, read inline by decodeFrame (0 = the codec decodes)
}

-- A C->S frame being filled or waiting in a channel queue (pooled).
type Frame = {
	buf: buffer,
	cap: number,
	n: number, -- bytes used, the 5-byte header included
	nmsg: number,
	refs: { any },
	nrefs: number,
	nodes: number, -- sidecar nodes (node rule)
	sideBytes: number, -- sidecar string bytes
	calls: { number }, -- call ids committed to this frame
	ncalls: number,
	events: number, -- event messages (EventsLost if the frame is dropped)
}

type Channel = {
	unreliable: boolean,
	open: Frame,
	queue: { Frame }, -- sealed frames, FIFO in [qhead, qtail]
	qhead: number,
	qtail: number,
	seq: number, -- seq of the next fired frame (wraps at 65536)
	frame: BucketT, -- admission mirror: frames per channel
	ringSeq: { number }, -- slot seq % 256 + 1: seq of the frame fired there (-1 = none)
	ringEvents: { number }, -- events in that frame
}

-- An S->C frame being received: pass 1 decodes it into `tape`, pass 2 delivers it. The first 5 fields: a Signal.Cursor.
type Batch = {
	owner: number,
	busy: boolean,
	pos: number, -- tape index of the entry being delivered
	node: any,
	stop: number,
	gen: number, -- generation at receive: a reset stops the frame
	n: number, -- tape slots in use (0 between segments)
	high: number, -- most slots used since `tape` was made (its array is at most 2x this, or TAPE_CAP0)
	tape: { any }, -- entries in frame order (E_* layouts below)
	now: number, -- the frame's clock (Ordered checks)
	refs: { any }?, -- the frame's refs (nil between frames)
	p: number, -- where pass 1 goes on after a SPLIT
	cursor: number, -- refs consumed before `p`
	decoding: boolean, -- pass 1 is running (a throw there still delivers the complete entries)
	why: string?, -- STOP: the structural error, reported after the tape (as `abort` does)
	route: ClientRoute?,
	num: number?,
}

local Limit = C.Limit
local Op = C.Op
local Err = C.Err
local Kind = C.Kind
local MemberFlag = C.MemberFlag
local Notice = C.Notice
local ErrFlag = C.ErrFlag
local Names = C.Names
local NetState = C.NetState
local PREFIX = C.PREFIX

local KIND_METHOD = Kind.Method
local KIND_EVENT = Kind.Event
local KIND_SIGNAL = Kind.Signal
local deliver = Signal.ClientSignal.deliver
local deliverIn = Signal.ClientSignal.deliverIn
local deliverIn1 = Signal.ClientSignal.deliverIn1
local quiet = Signal.ClientSignal.quiet
local drive = Signal.drive
local HEADER = C.C2S_HEADER
local CAT = Names.MemoryCategory
local ENCODE_OK = C.Encode.OK
local DECODE_MISSING = C.Decode.MISSING_INSTANCE
local NODE_CHARGE = Limit.NODE_CHARGE
local REF_CHARGE = Limit.REF_CHARGE
local MIN_CHARGE = Limit.MIN_CHARGE
local C2S_SEAL = Limit.C2S_SEAL
local C2S_MAX_MESSAGE = Limit.C2S_MAX_MESSAGE
local UNRELIABLE_SEAL = Limit.UNRELIABLE_SEAL
local MAX_REFS = Limit.MAX_REFS
local MAX_NODES = Limit.MAX_NODES
local MAX_MSGS = Limit.MAX_MSGS_PER_FRAME
local ERR_MSG_MAX = Limit.ERR_MSG_MAX
local RING = Limit.FRAME_RING
local ORDERED_RESET = Limit.ORDERED_RESET
local SEQ_MOD = 65536
local FRAME_CAP0 = 1024
local FRAME_KEEP_MAX = 4 * C2S_SEAL -- a recycled frame above this capacity gets a fresh small buffer
local FRAME_POOL_MAX = 64
local SCRATCH_CAP0 = 1024
local SCRATCH_KEEP = 2 * C2S_MAX_MESSAGE -- a larger scratch writer is replaced before the next encode
local ERR_FLAGS_KNOWN = bit32.bor(ErrFlag.Msg, ErrFlag.Data, ErrFlag.Incident)
-- A client restart re-sends HELLO; keep it past the server's REHELLO_MIN so it is never a violation.
local HELLO_SPACING = Limit.REHELLO_MIN + 1
local HELLO_RETRY = 2 * Limit.REHELLO_MIN

local PHASE_IDLE = 0
local PHASE_CONNECTING = 1
local PHASE_READY = 2
local PHASE_FAILED = 3

-- Tape entries. Every per-message effect (counters, logs, call state, user code) happens in pass 2, at its entry.
local E_SIGNAL = 1 -- [E_SIGNAL, signal, argc, args...]: MessagesIn, then the listeners
local E_SKIP = 2 -- [E_SKIP, messages, dropped]: Signals that deliver nothing (stale Ordered, a typed Instance nil)
local E_OK = 3 -- [E_OK, req, req.gen, argc, values...]
local E_MISSING = 4 -- [E_MISSING, req, req.gen]: an OK whose typed Instance arrived nil
local E_BAD = 5 -- [E_BAD, req, req.gen]: an OK that failed to decode (always the last entry)
local E_ERR = 6 -- [E_ERR, req, req.gen, code, msg, data, incident]
local E_NOTICE = 7 -- [E_NOTICE, kind, first, count]
local DONE = 0 -- pass 1: decoded to the end of the frame
local SPLIT = 1 -- pass 1: deliver the tape first, then decode on from b.p (see decodeFrame)
local STOP = 2 -- pass 1: a structural error (b.why) ends the frame after the tape
local TAPE_CAP0 = 1024
local TAPE_KEEP = 16384 -- a tape that held more slots is replaced after its frame

-- Schema ops that decodeFrame reads inline (O1); constants, so the compiler folds them
local S_BOOL = 1
local S_U8 = 2
local S_U16 = 3
local S_U32 = 4
local S_I8 = 5
local S_I16 = 6
local S_I32 = 7
local S_F32 = 8
local S_F64 = 9
local S_VECTOR3 = 12
local F32_ABS = 0x7FFFFFFF -- f32 bits without the sign: 0 is zero, below F32_NORMAL subnormal, above F32_INF NaN
local F32_NORMAL = 0x00800000
local F32_INF = 0x7F800000
do
	local op = C.SchemaOp
	assert(
		op.BOOL == S_BOOL
			and op.U8 == S_U8
			and op.U16 == S_U16
			and op.U32 == S_U32
			and op.I8 == S_I8
			and op.I16 == S_I16
			and op.I32 == S_I32
			and op.F32 == S_F32
			and op.F64 == S_F64
			and op.VECTOR3 == S_VECTOR3,
		PREFIX .. "ClientNet scalar ops are out of sync with Constants.luau"
	)
end

local ClientNet = {}

-- Frames and channels ------------------------------------------------------------------------------

local framePool: { Frame } = {}
local framePoolN = 0

local function newFrame(): Frame
	return {
		buf = buffer.create(FRAME_CAP0),
		cap = FRAME_CAP0,
		n = HEADER,
		nmsg = 0,
		refs = {},
		nrefs = 0,
		nodes = 0,
		sideBytes = 0,
		calls = {},
		ncalls = 0,
		events = 0,
	}
end

local function takeFrame(): Frame
	if framePoolN > 0 then
		local fr = framePool[framePoolN]
		framePool[framePoolN] = nil :: any
		framePoolN -= 1
		return fr
	end
	return newFrame()
end

-- Empties a frame and returns it to the pool. `refsGiven`: its refs table went to FireServer.
local function recycle(fr: Frame, refsGiven: boolean)
	fr.n = HEADER
	fr.nmsg = 0
	fr.nodes = 0
	fr.sideBytes = 0
	fr.ncalls = 0
	fr.events = 0
	if fr.nrefs > 0 then
		if refsGiven then
			fr.refs = {} -- the engine may still hold the old table; never mutate it
		else
			table.clear(fr.refs)
		end
		fr.nrefs = 0
	end
	if fr.cap > FRAME_KEEP_MAX then
		fr.buf = buffer.create(FRAME_CAP0)
		fr.cap = FRAME_CAP0
	end
	if framePoolN < FRAME_POOL_MAX then
		framePoolN += 1
		framePool[framePoolN] = fr
	end
end

local function growFrame(fr: Frame, need: number)
	local cap = fr.cap
	while cap < need do
		cap *= 2
	end
	local nb = buffer.create(cap)
	buffer.copy(nb, 0, fr.buf, 0, fr.n)
	fr.buf = nb
	fr.cap = cap
end

-- Placeholder bucket before the manifest (never charged: nothing flushes before it).
local function emptyBucket(): BucketT
	return { tokens = 0, stamp = 0, rate = 0, burst = 0 }
end

local function newChannel(unreliable: boolean): Channel
	return {
		unreliable = unreliable,
		open = takeFrame(),
		queue = {},
		qhead = 1,
		qtail = 0,
		seq = 0,
		frame = emptyBucket(),
		ringSeq = table.create(RING, -1),
		ringEvents = table.create(RING, 0),
	}
end

-- State (all of it restored by _reset, except `generation` and `lastHelloAt`) ------------------------

local generation = 0 -- bumped by _reset; a connect() from an older generation gives up
local lastHelloAt = -math.huge -- kept across _reset: a restarted client spaces its HELLO (REHELLO_MIN)

local phase = PHASE_IDLE
local shuttingDown = false
local clock: () -> number = os.clock
local fireHook: ((unreliable: boolean, frame: buffer, refs: { any }?, nodes: number, sideBytes: number) -> ())? = nil

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil
local connections: { RBXScriptConnection } = {}

local model: Types.ManifestModel? = nil
local manifestError: string? = nil
local hellosSent = 0

-- Routes and per-route state (dense by route id)
local NO_ROUTES: { ClientRoute } = {}
table.freeze(NO_ROUTES :: any)
local routes: { ClientRoute } = NO_ROUTES
local routeBucket: { BucketT } = {} -- Method/Event mirror (rate, burst x MirrorFraction)
local sendSeq: { number } = {} -- Ordered senders: last seq written
local rxLast: { number } = {} -- Ordered Signals: last accepted seq (-1 = none)
local rxTime: { number } = {}
local coBuf: { buffer } = {} -- Coalesced events: pending message bytes (reused, grown by doubling)
local coCap: { number } = {} -- capacity of coBuf[id] (no buffer.len on the Fire path)
local coLen: { number } = {} -- 0 = nothing pending
local coList: { number } = {} -- coalesced route ids, in route order
local warnedLossy: { boolean } = {}
local warnedLost: { boolean } = {}

-- Channels, admission mirror, flush credit
local rel: Channel = newChannel(false)
local unr: Channel = newChannel(true)
local byteBucket: BucketT = emptyBucket()
local msgBucket: BucketT = emptyBucket()
local msgCap = MAX_MSGS
local unsentCap = 2 * MAX_MSGS
local unsent = 0 -- messages in open + queued frames, both channels
local interval = 1 / Limit.FLUSH_HZ
local acc = 0
local inlineTables = true

-- Scratch (one per side): writer, read context, argv, failed-fire call ids
local w: Writer = Codec.newWriter(SCRATCH_CAP0, true)
local ctx: ReadCtx = Codec.newReadCtx(false, false)
local argv: { any } = {}
local failedIds: { number } = {}
local nfailed = 0
local callIdAt = 0 -- offset of the callId in the scratch writer (set by encodeMessage)
local abortLogged = false
local spare: Batch? = nil -- the batch the next frame decodes into (a nested receive gets a new one)
local fillN = 0 -- tape slots of complete entries (pass 1)
local claimed: { [Req]: boolean } = {} -- calls replied to earlier on the tape being filled
local claimedList: { Req } = {} -- the same calls in a list, so unclaim is O(replies), not O(the set's capacity)
local claimedN = 0
local lastClear = 0 -- tape slots the last clearTape touched (spec hook)

-- Stats
local framesIn, bytesIn, messagesIn = 0, 0, 0
local framesOut, bytesOut, messagesOut = 0, 0, 0
local framesDropped, eventsLost, callsRateLimited = 0, 0, 0
local badRequests, busyReplies, outboxDropped, signalsDropped = 0, 0, 0, 0
local flushes = 0

-- Helpers -------------------------------------------------------------------------------------------

local function varintSize(v: number): number
	return if v < 0x80 then 1 elseif v < 0x4000 then 2 else 3
end

-- Minimal LEB128 at offset o (v <= VARINT_MAX); returns the offset after it.
local function putVarint(b: buffer, o: number, v: number): number
	while v >= 0x80 do
		buffer.writeu8(b, o, bit32.bor(bit32.band(v, 0x7F), 0x80))
		v = bit32.rshift(v, 7)
		o += 1
	end
	buffer.writeu8(b, o, v)
	return o + 1
end

local function clearArgv(n: number)
	for i = 1, n do
		argv[i] = nil
	end
end

local function disconnectAll()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
end

-- Sends one frame. Returns (ok, error). Unreliable frames never carry refs.
local function send(
	unreliable: boolean,
	frame: buffer,
	refs: { any }?,
	nodes: number,
	sideBytes: number
): (boolean, any)
	local hook = fireHook
	if hook then
		return pcall(hook, unreliable, frame, refs, nodes, sideBytes)
	end
	if unreliable then
		local remote = unreliableRemote
		if remote == nil then
			return false, "no Unreliable remote"
		end
		return pcall(remote.FireServer, remote, frame)
	end
	local remote = reliableRemote
	if remote == nil then
		return false, "no Reliable remote"
	end
	if refs then
		return pcall(remote.FireServer, remote, frame, refs)
	end
	return pcall(remote.FireServer, remote, frame)
end

-- HELLO frame: seq nmsg=1 nrefs=0 | len=2 F0 proto. Sent alone, outside the flush credit.
local function sendHello()
	local seq = rel.seq
	local b = buffer.create(HEADER + 3)
	buffer.writeu16(b, 0, seq)
	buffer.writeu16(b, 2, 1)
	buffer.writeu8(b, 4, 0)
	buffer.writeu8(b, 5, 2)
	buffer.writeu8(b, 6, Op.HELLO)
	buffer.writeu8(b, 7, C.PROTO)
	lastHelloAt = os.clock()
	local ok, err = send(false, b, nil, 0, 0)
	if ok then
		rel.seq = (seq + 1) % SEQ_MOD
		local slot = seq % RING + 1
		rel.ringSeq[slot] = seq
		rel.ringEvents[slot] = 0
		hellosSent += 1
		framesOut += 1
		bytesOut += HEADER + 3
		messagesOut += 1
	else
		Log.once("cn:hello", "HELLO could not be sent: " .. tostring(err))
	end
end

-- Outgoing: encode, seal, commit ---------------------------------------------------------------------

-- Encodes one C->S message (head, [callId | seq], payload) into the scratch writer. Runs no user code.
local function encodeMessage(route: ClientRoute, refBase: number, seq: number, n: number, ...: any): number
	local sw = w
	if sw.cap > SCRATCH_KEEP then
		-- grown by an oversized payload (refused as PayloadTooLarge): not kept for the session
		sw.buf = buffer.create(SCRATCH_CAP0)
		sw.cap = SCRATCH_CAP0
	end
	Codec.resetWriter(sw)
	sw.refBase = refBase
	sw.unreliable = route.unreliable
	sw.inlineTables = inlineTables
	Codec.writeHead(sw, route.id)
	if route.kind == KIND_METHOD then
		callIdAt = sw.n
		Codec.writeU16(sw, 0) -- patched once the id is allocated
	elseif route.ordered then
		Codec.writeU16(sw, seq)
	end
	return route.args.encode(sw, n, ...)
end

-- Would adding a message (len bytes, its sidecar) to the channel's open frame need a seal first?
local function needsSeal(ch: Channel, len: number, nrefs: number, nodes: number, side: number): boolean
	local fr = ch.open
	if fr.nmsg == 0 then
		return false
	end
	if fr.nmsg >= msgCap then
		return true
	end
	local bytes = varintSize(len) + len
	if ch.unreliable then
		return fr.n + bytes > UNRELIABLE_SEAL
	end
	return fr.n + NODE_CHARGE * fr.nodes + fr.sideBytes + bytes + NODE_CHARGE * nodes + side > C2S_SEAL
		or fr.nrefs + nrefs > MAX_REFS
		or fr.nodes + nodes > MAX_NODES
end

local function seal(ch: Channel)
	local fr = ch.open
	if fr.nmsg == 0 then
		return
	end
	ch.qtail += 1
	ch.queue[ch.qtail] = fr
	ch.open = takeFrame()
end

-- Appends one message (len:varint + bytes, and its refs) to the open frame.
local function commit(
	ch: Channel,
	src: buffer,
	len: number,
	refs: { any }?,
	nrefs: number,
	nodes: number,
	side: number,
	callId: number,
	isEvent: boolean
)
	local fr = ch.open
	local need = fr.n + 3 + len
	if need > fr.cap then
		growFrame(fr, need)
	end
	local b = fr.buf
	local o = putVarint(b, fr.n, len)
	buffer.copy(b, o, src, 0, len)
	fr.n = o + len
	if nrefs > 0 and refs then
		table.move(refs, 1, nrefs, fr.nrefs + 1, fr.refs)
		fr.nrefs += nrefs
	end
	fr.nodes += nodes
	fr.sideBytes += side
	fr.nmsg += 1
	if callId > 0 then
		local k = fr.ncalls + 1
		fr.ncalls = k
		fr.calls[k] = callId
	end
	if isEvent then
		fr.events += 1
	end
	unsent += 1
end

local function warnLossy(route: ClientRoute)
	if not warnedLossy[route.id] then
		warnedLossy[route.id] = true
		Log.studioOnce(
			"cn:lossy:" .. route.service .. "." .. route.member,
			route.service
				.. "."
				.. route.member
				.. ": functions, threads or metatables in the arguments were dropped (they cannot be sent)"
		)
	end
end

local function loseEvent(route: ClientRoute)
	eventsLost += 1
	if not warnedLost[route.id] then
		warnedLost[route.id] = true
		Log.studioOnce(
			"cn:lost:" .. route.service .. "." .. route.member,
			route.service
				.. ".ClientEvents."
				.. route.member
				.. " events are being dropped by the client rate limit mirror (see Loren.GetStats().EventsLost)"
		)
	end
end

local function localReject(route: ClientRoute, try: boolean, code: number, reason: string?, arg: number?): ...any
	if code == Err.RateLimited then
		callsRateLimited += 1
	end
	local message, info =
		Errors.rejection(code, route.service, route.member, reason, nil, nil, if arg and arg > 0 then arg else nil)
	if try then
		return false, message, info
	end
	return Calls.rejected(message, info)
end

-- Flush ----------------------------------------------------------------------------------------------

-- Charges the whole frame to the admission mirror (frame, bytes, messages) if all three allow it.
local function admit(ch: Channel, fr: Frame, now: number): boolean
	local fb, bb, mb = ch.frame, byteBucket, msgBucket
	local cost = math.max(fr.n, MIN_CHARGE) + REF_CHARGE * fr.nrefs + NODE_CHARGE * fr.nodes + fr.sideBytes
	if cost > bb.burst then
		cost = bb.burst
	end
	local nmsg = fr.nmsg
	if nmsg > mb.burst then
		nmsg = mb.burst
	end
	if not (Bucket.can(fb, 1, now) and Bucket.can(bb, cost, now) and Bucket.can(mb, nmsg, now)) then
		return false
	end
	Bucket.take(fb, 1, now)
	Bucket.take(bb, cost, now)
	Bucket.take(mb, nmsg, now)
	return true
end

-- Writes the header, fires an exact-size copy and recycles the frame.
local function fireFrame(ch: Channel, fr: Frame, now: number)
	local seq = ch.seq
	local b = fr.buf
	local n = fr.n
	local nmsg = fr.nmsg
	local nrefs = fr.nrefs
	buffer.writeu16(b, 0, seq)
	buffer.writeu16(b, 2, nmsg)
	buffer.writeu8(b, 4, nrefs)
	local out = buffer.create(n)
	buffer.copy(out, 0, b, 0, n)
	local ok, err = send(ch.unreliable, out, if nrefs > 0 then fr.refs else nil, fr.nodes, fr.sideBytes)
	unsent -= nmsg
	if ok then
		ch.seq = (seq + 1) % SEQ_MOD
		local slot = seq % RING + 1
		ch.ringSeq[slot] = seq
		ch.ringEvents[slot] = fr.events
		framesOut += 1
		bytesOut += n
		messagesOut += nmsg
		local calls = fr.calls
		for i = 1, fr.ncalls do
			Calls.fired(calls[i], seq, now)
		end
		recycle(fr, nrefs > 0)
	else
		-- The frame is lost (an unserializable ref). Its calls reject after the flush (user code).
		eventsLost += fr.events
		local calls = fr.calls
		for i = 1, fr.ncalls do
			nfailed += 1
			failedIds[nfailed] = calls[i]
		end
		recycle(fr, false)
		Log.once("cn:fire", "a frame could not be sent (its calls reject BadArgument): " .. tostring(err))
	end
end

-- Fires queued frames in order while the mirror admits each one; the rest waits (pacing).
local function fireQueued(ch: Channel, now: number)
	local q = ch.queue
	while ch.qhead <= ch.qtail do
		local fr = q[ch.qhead]
		if not admit(ch, fr, now) then
			return
		end
		q[ch.qhead] = nil :: any
		ch.qhead += 1
		fireFrame(ch, fr, now)
	end
	ch.qhead = 1
	ch.qtail = 0
end

local function flushChannel(ch: Channel, now: number)
	fireQueued(ch, now)
	if ch.qtail < ch.qhead and ch.open.nmsg > 0 then
		seal(ch)
		fireQueued(ch, now)
	end
end

local function commitCoalesced(now: number)
	for _, id in coList do
		local len = coLen[id]
		if len > 0 then
			if unsent >= unsentCap then
				return
			end
			if Bucket.take(routeBucket[id], 1, now) then
				local ch = if routes[id].unreliable then unr else rel
				if needsSeal(ch, len, 0, 0, 0) then
					seal(ch)
				end
				commit(ch, coBuf[id], len, nil, 0, 0, 0, 0, true)
				coLen[id] = 0
			end
		end
	end
end

local function flush(now: number)
	flushes += 1
	if coList[1] ~= nil then
		commitCoalesced(now)
	end
	flushChannel(rel, now)
	flushChannel(unr, now)
end

-- Calls whose frame failed to fire reject BadArgument (runs user code; after the flush).
local function settleFailed()
	while nfailed > 0 do
		local id = failedIds[nfailed]
		nfailed -= 1
		Calls.fireFailed(id)
	end
end

local function flushFault(err: any)
	Log.once("cn:flush", "client flush failed: " .. tostring(err))
end

-- One flush if the credit allows: acc -= 1/FLUSH_HZ, carry clamped to one interval.
local function tryFlush(now: number, tagged: boolean): boolean
	if acc < interval then
		return false
	end
	acc -= interval
	if acc > interval then
		acc = interval
	end
	if tagged then
		debug.setmemorycategory(CAT)
	end
	local ok, err = pcall(flush :: any, now)
	if tagged then
		debug.resetmemorycategory()
	end
	if not ok then
		flushFault(err)
	end
	settleFailed()
	return true
end

local function onHeartbeat(dt: number)
	if phase ~= PHASE_READY then
		return
	end
	acc += dt
	local now = clock()
	tryFlush(now, true)
	Calls.sweep(now)
end

-- Incoming --------------------------------------------------------------------------------------------

-- "Dropped the rest of a server frame", where the one-pass decoder stopped; the text is built for the first one only.
local function abort(reason: string, route: ClientRoute?, num: number?)
	if abortLogged then
		return
	end
	abortLogged = true
	local detail = reason
	if route then
		detail ..= " for " .. route.service .. "." .. route.member
	end
	if num then
		detail ..= " " .. num
	end
	Log.once(
		"cn:abort",
		"dropped the rest of a server frame ("
			.. detail
			.. "); the client and server runtimes may be different versions"
	)
end

-- Ordered S->C receiver: wrap-aware, resets after ORDERED_RESET seconds of silence.
local function acceptSeq(id: number, seq: number, now: number): boolean
	local last = rxLast[id]
	if last >= 0 and now - rxTime[id] <= ORDERED_RESET then
		local d = (seq - last) % SEQ_MOD
		if d == 0 or d >= 32768 then
			return false
		end
	end
	rxLast[id] = seq
	rxTime[id] = now
	return true
end

-- Events lost in the frames of a NOTICE run, from the channel ring (runs older than it: uncounted).
local function ringLost(ch: Channel, first: number, count: number): number
	local lost = 0
	local start = if count > RING then count - RING else 0
	local ringSeq, ringEvents = ch.ringSeq, ch.ringEvents
	for i = start, count - 1 do
		local s = (first + i) % SEQ_MOD
		local slot = s % RING + 1
		if ringSeq[slot] == s then
			lost += ringEvents[slot]
			ringSeq[slot] = -1
		end
	end
	return lost
end

-- Builds every ClientRoute and the client state from a decoded manifest. Errors on a malformed model.
local function install(m: Types.ManifestModel)
	if m.proto ~= C.PROTO then
		error("protocol mismatch (server proto " .. tostring(m.proto) .. ", client " .. C.PROTO .. ")", 0)
	end
	local lim = m.limits
	local mirror = lim.mirror
	if type(mirror) ~= "number" or not (mirror > 0 and mirror <= 1) then
		error("malformed manifest (mirror)", 0)
	end
	local now = clock()
	local total = 0
	for _, svc in m.services do
		total += #svc.members
	end
	if total > C.ROUTE_MAX then
		error("malformed manifest (too many routes)", 0)
	end

	local newRoutes: { ClientRoute } = table.create(total) :: any
	local buckets: { BucketT } = table.create(total) :: any
	local seqs: { number } = table.create(total, 0)
	local lastRx: { number } = table.create(total, -1)
	local timeRx: { number } = table.create(total, 0)
	local coLens: { number } = table.create(total, 0)
	local coCaps: { number } = table.create(total, 0)
	local coBufs: { buffer } = table.create(total) :: any
	local flags1: { boolean } = table.create(total, false)
	local flags2: { boolean } = table.create(total, false)
	local coIds: { number } = {}
	local placeholder = buffer.create(0)
	local noBucket = emptyBucket()

	for _, svc in m.services do
		for _, mem in svc.members do
			local id = mem.route
			if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > total or newRoutes[id] ~= nil then
				error("malformed manifest (route ids)", 0)
			end
			local kind = mem.kind
			if kind ~= KIND_METHOD and kind ~= KIND_EVENT and kind ~= KIND_SIGNAL then
				error("malformed manifest (member kind " .. tostring(kind) .. ")", 0)
			end
			local flags = mem.flags
			local unreliable = bit32.btest(flags, MemberFlag.Unreliable)
			local ordered = bit32.btest(flags, MemberFlag.Ordered)
			local coalesce = kind == KIND_EVENT and bit32.btest(flags, MemberFlag.Coalesce)
			local allowNonFinite = bit32.btest(flags, MemberFlag.AllowNonFinite)
			local args = Schema.compile(
				mem.args,
				allowNonFinite,
				if kind == KIND_SIGNAL then Limit.MAX_ARGS_S2C else Limit.MAX_ARGS_C2S,
				unreliable
			)
			local returns: PayloadCodec | false = false
			if kind == KIND_METHOD then
				returns = Schema.compile(mem.returns, allowNonFinite, Limit.MAX_ARGS_S2C, false)
			end
			local signal: Types.ClientSignal | false = false
			if kind == KIND_SIGNAL then
				signal = Signal.ClientSignal.new(svc.name, mem.name, mem.backlog)
			end
			local route: ClientRoute = {
				id = id,
				kind = kind,
				service = svc.name,
				member = mem.name,
				unreliable = unreliable,
				ordered = ordered,
				coalesce = coalesce,
				allowNonFinite = allowNonFinite,
				timeout = mem.timeout,
				rate = mem.rate,
				burst = mem.burst,
				backlog = mem.backlog,
				args = args,
				returns = returns,
				signal = signal,
				scalar = if kind == KIND_SIGNAL then Schema.scalarOp(mem.args) else 0,
			}
			table.freeze(route :: any)
			newRoutes[id] = route
			if kind == KIND_SIGNAL then
				buckets[id] = noBucket
			else
				-- Mirror at MirrorFraction; a burst below 1 could never pass, so it is at least 1.
				buckets[id] = Bucket.new(mem.rate * mirror, math.max(1, mem.burst * mirror), now)
			end
			coBufs[id] = placeholder
			if coalesce then
				table.insert(coIds, id)
			end
		end
	end
	table.sort(coIds)

	table.freeze(newRoutes :: any)
	routes = newRoutes
	routeBucket = buckets
	sendSeq = seqs
	rxLast = lastRx
	rxTime = timeRx
	coLen = coLens
	coCap = coCaps
	coBuf = coBufs
	coList = coIds
	warnedLossy = flags1
	warnedLost = flags2

	rel.frame = Bucket.new(lim.frameRate * mirror, math.max(1, lim.frameBurst * mirror), now)
	unr.frame = Bucket.new(lim.frameRate * mirror, math.max(1, lim.frameBurst * mirror), now)
	byteBucket = Bucket.new(lim.byteRate * mirror, math.max(MIN_CHARGE, lim.byteBurst * mirror), now)
	msgBucket = Bucket.new(lim.msgRate * mirror, math.max(1, lim.msgBurst * mirror), now)
	for _ = 1, hellosSent do
		Bucket.take(rel.frame, 1, now)
		Bucket.take(byteBucket, MIN_CHARGE, now)
		Bucket.take(msgBucket, 1, now)
	end
	msgCap = math.clamp(math.floor(lim.msgBurst * mirror), 1, MAX_MSGS)
	unsentCap = 2 * msgCap
	local hz = lim.flushHz
	interval = 1 / (if type(hz) == "number" and hz >= 1 then hz else Limit.FLUSH_HZ)
	acc = 0
	inlineTables = Config.get().InlineTables ~= false
	Calls.configure(lim.maxPending)
	model = m
	phase = PHASE_READY
end

-- Forgets the calls pass 1 claimed (after each pass 1, and on a fault or reset).
local function unclaim()
	for i = 1, claimedN do
		claimed[claimedList[i]] = nil
		claimedList[i] = nil :: any
	end
	claimedN = 0
end

-- Pass 1 ends at a structural error: it is reported (abort) after the entries before it are delivered.
local function stop(b: Batch, why: string, route: ClientRoute?, num: number?): number
	table.clear(argv)
	b.why = why
	b.route = route
	b.num = num
	return STOP
end

-- Pass 1, b.p on into b.tape: no user code, no visible effect; a lookup the tape could change waits for it (SPLIT).
@native
local function decodeFrame(b: Batch, frame: buffer): number
	local tape = b.tape
	local len = buffer.len(frame)
	local now = b.now
	local rctx = ctx
	Codec.beginFrame(rctx, b.refs, 0)
	rctx.cursor = b.cursor
	local k = 0
	local skipAt = 0 -- the E_SKIP entry at the tape's end (0 = none): a run of skipped Signals shares one
	local dropSeen = false -- a FrameDropped NOTICE is on the tape
	local p = b.p
	while p < len do
		local h, q = buffer.readu8(frame, p), p + 1 -- the 1-byte route head inline (p < len): as Codec.readHead
		if h == 0 or h > 0xDF then
			h, q = Codec.readHead(frame, p, len)
		end
		if h > 0 then
			-- SIGNAL
			local route = routes[h]
			if route == nil or route.kind ~= KIND_SIGNAL then
				return stop(b, "unknown or non-Signal route", nil, h)
			end
			local seq = -1
			if route.ordered then
				if q + 2 > len then
					return stop(b, "truncated signal")
				end
				seq = buffer.readu16(frame, q)
				q += 2
			end
			local n = -1
			local e = 0 -- the decode status: after an inline read rctx.err is stale, so nothing below may read it
			local v1: any = nil -- the value of a 1-argument message (argv holds the others)
			local sop = route.scalar
			if sop ~= 0 then
				-- O1: as decodeFields reads it on the trusted side; what this cannot take goes to the codec (same error)
				if sop == S_BOOL then
					if q < len then
						local x = buffer.readu8(frame, q)
						if x == 1 then
							v1 = true
							n = 1
							q += 1
						elseif x == 0 then
							v1 = false
							n = 1
							q += 1
						end
					end
				elseif sop == S_VECTOR3 then
					if q + 12 <= len then
						local mx = bit32.band(buffer.readu32(frame, q), F32_ABS)
						local my = bit32.band(buffer.readu32(frame, q + 4), F32_ABS)
						local mz = bit32.band(buffer.readu32(frame, q + 8), F32_ABS)
						-- native code builds Vector3.new(readf32) without the f32 -> f64 -> f32 trip decodeFields makes
						if
							(mx == 0 or (mx >= F32_NORMAL and mx <= F32_INF))
							and (my == 0 or (my >= F32_NORMAL and my <= F32_INF))
							and (mz == 0 or (mz >= F32_NORMAL and mz <= F32_INF))
						then
							-- zero, normal and infinite: that trip keeps them in every float mode; the codec takes the rest
							v1 = Vector3.new(
								buffer.readf32(frame, q),
								buffer.readf32(frame, q + 4),
								buffer.readf32(frame, q + 8)
							)
							n = 1
							q += 12
						end
					end
				elseif sop == S_F32 then
					if q + 4 <= len then
						v1 = buffer.readf32(frame, q)
						n = 1
						q += 4
					end
				elseif sop == S_U8 then
					if q < len then
						v1 = buffer.readu8(frame, q)
						n = 1
						q += 1
					end
				elseif sop == S_U16 then
					if q + 2 <= len then
						v1 = buffer.readu16(frame, q)
						n = 1
						q += 2
					end
				elseif sop == S_U32 then
					if q + 4 <= len then
						v1 = buffer.readu32(frame, q)
						n = 1
						q += 4
					end
				elseif sop == S_I8 then
					if q < len then
						v1 = buffer.readi8(frame, q)
						n = 1
						q += 1
					end
				elseif sop == S_I16 then
					if q + 2 <= len then
						v1 = buffer.readi16(frame, q)
						n = 1
						q += 2
					end
				elseif sop == S_I32 then
					if q + 4 <= len then
						v1 = buffer.readi32(frame, q)
						n = 1
						q += 4
					end
				elseif sop == S_F64 then
					if q + 8 <= len then
						v1 = buffer.readf64(frame, q)
						n = 1
						q += 8
					end
				end
			end
			if n < 0 then
				-- Codec.beginMessage, inline
				rctx.err = 0
				rctx.errArg = 0
				rctx.nodes = 0
				rctx.claimed = 0
				rctx.allowNonFinite = route.allowNonFinite
				n, q = route.args.decode(frame, q, len, rctx, argv)
				e = rctx.err
				if e ~= 0 and e ~= DECODE_MISSING then
					return stop(b, "bad payload", route)
				end
				if n == 1 then
					v1 = argv[1]
					argv[1] = nil
				end
			end
			-- -1: delivered. 0: stale Ordered (decoded to keep the offset and ref cursor right). 1: an Instance nil.
			local dropped = -1
			if seq >= 0 and not acceptSeq(h, seq, now) then
				dropped = 0
			elseif e == DECODE_MISSING then
				dropped = 1
			end
			if dropped >= 0 then
				clearArgv(n)
				if skipAt > 0 then
					tape[skipAt + 1] += 1
					tape[skipAt + 2] += dropped
				else
					skipAt = k + 1
					tape[k + 1] = E_SKIP
					tape[k + 2] = 1
					tape[k + 3] = dropped
					k += 3
				end
			else
				tape[k + 1] = E_SIGNAL
				tape[k + 2] = route.signal
				tape[k + 3] = n
				if n == 1 then
					tape[k + 4] = v1
				elseif n == 2 then
					tape[k + 4], tape[k + 5] = argv[1], argv[2]
					argv[1], argv[2] = nil, nil
				elseif n == 3 then
					tape[k + 4], tape[k + 5], tape[k + 6] = argv[1], argv[2], argv[3]
					argv[1], argv[2], argv[3] = nil, nil, nil
				elseif n > 3 then
					table.move(argv, 1, n, k + 4, tape)
					clearArgv(n)
				end
				k += 3 + n
				skipAt = 0
			end
			fillN = k
			p = q
		elseif h < 0 then
			local op = -h
			if op == Op.OK then
				if q + 2 > len then
					return stop(b, "truncated OK")
				end
				local req = Calls.lookup(buffer.readu16(frame, q))
				if k > 0 and (req == nil or dropSeen or claimed[req]) then
					b.p = p
					b.cursor = rctx.cursor
					return SPLIT
				elseif req == nil then
					return stop(b, "OK for an unknown call id")
				end
				claimed[req] = true
				claimedN += 1
				claimedList[claimedN] = req
				q += 2
				local route: ClientRoute = req.route
				-- Codec.beginMessage, inline
				rctx.err = 0
				rctx.errArg = 0
				rctx.nodes = 0
				rctx.claimed = 0
				rctx.allowNonFinite = route.allowNonFinite
				local n
				n, q = (route.returns :: PayloadCodec).decode(frame, q, len, rctx, argv)
				local e = rctx.err
				if e ~= 0 and e ~= DECODE_MISSING then
					tape[k + 1] = E_BAD
					tape[k + 2] = req
					tape[k + 3] = req.gen
					fillN = k + 3
					return stop(b, "bad reply", route)
				end
				if e == DECODE_MISSING then
					clearArgv(n)
					tape[k + 1] = E_MISSING
					tape[k + 2] = req
					tape[k + 3] = req.gen
					k += 3
				else
					tape[k + 1] = E_OK
					tape[k + 2] = req
					tape[k + 3] = req.gen
					tape[k + 4] = n
					if n == 1 then
						tape[k + 5] = argv[1]
						argv[1] = nil
					elseif n > 1 then
						table.move(argv, 1, n, k + 5, tape)
						clearArgv(n)
					end
					k += 4 + n
				end
				skipAt = 0
				fillN = k
				p = q
			elseif op == Op.ERR then
				if q + 4 > len then
					return stop(b, "truncated ERR")
				end
				local req = Calls.lookup(buffer.readu16(frame, q))
				if k > 0 and (req == nil or dropSeen or claimed[req]) then
					b.p = p
					b.cursor = rctx.cursor
					return SPLIT
				elseif req == nil then
					return stop(b, "ERR for an unknown call id")
				end
				claimed[req] = true
				claimedN += 1
				claimedList[claimedN] = req
				local code = buffer.readu8(frame, q + 2)
				local flags = buffer.readu8(frame, q + 3)
				q += 4
				if bit32.band(flags, bit32.bnot(ERR_FLAGS_KNOWN)) ~= 0 then
					return stop(b, "bad ERR flags")
				end
				local msg: string? = nil
				if bit32.btest(flags, ErrFlag.Msg) then
					local mlen
					mlen, q = Codec.readVarint(frame, q, len)
					if mlen < 0 or mlen > ERR_MSG_MAX or mlen > len - q then
						return stop(b, "bad ERR message")
					end
					msg = buffer.readstring(frame, q, mlen)
					q += mlen
				end
				local data: any = nil
				if bit32.btest(flags, ErrFlag.Data) then
					Codec.beginMessage(rctx, true)
					data, q = Codec.readValue(frame, q, len, rctx, 0)
					if rctx.err ~= 0 then
						return stop(b, "bad ERR data")
					end
				end
				local incident: number? = nil
				if bit32.btest(flags, ErrFlag.Incident) then
					if q + 4 > len then
						return stop(b, "truncated ERR incident")
					end
					incident = buffer.readu32(frame, q)
					q += 4
				end
				tape[k + 1] = E_ERR
				tape[k + 2] = req
				tape[k + 3] = req.gen
				tape[k + 4] = code
				tape[k + 5] = msg
				tape[k + 6] = data
				tape[k + 7] = incident
				k += 7
				skipAt = 0
				fillN = k
				p = q
			elseif op == Op.NOTICE then
				if q + 5 > len then
					return stop(b, "truncated NOTICE")
				end
				local kind = buffer.readu8(frame, q)
				if kind == Notice.FrameDropped then
					dropSeen = true
				end
				tape[k + 1] = E_NOTICE
				tape[k + 2] = kind
				tape[k + 3] = buffer.readu16(frame, q + 1)
				tape[k + 4] = buffer.readu16(frame, q + 3)
				k += 4
				skipAt = 0
				fillN = k
				p = q + 5
			elseif op == Op.MANIFEST then
				if q + 4 > len then
					return stop(b, "truncated MANIFEST")
				end
				local mlen = buffer.readu32(frame, q)
				q += 4
				if mlen > len - q then
					return stop(b, "truncated MANIFEST")
				end
				if model == nil then
					if k > 0 then
						-- Never from a real server (a first MANIFEST opens its frame): installed after the tape.
						b.p = p
						b.cursor = rctx.cursor
						return SPLIT
					end
					local m, reason = Manifest.decode(frame, q, q + mlen)
					if m == nil then
						manifestError = reason or "malformed manifest"
						return stop(b, "malformed MANIFEST")
					end
					local ok, err = pcall(install :: any, m)
					if not ok then
						manifestError = tostring(err)
						return stop(b, "unusable MANIFEST")
					end
				end -- a MANIFEST after the first (repeat HELLO) is skipped by its length
				p = q + mlen
			else
				return stop(b, "unexpected control op", nil, op)
			end
		else
			return stop(b, "bad route head")
		end
	end
	return DONE
end

-- ERR for a pending call: counters and the unknown-code rule, then the rejection (user code).
local function rejectErr(req: Req, code: number, msg: string?, data: any, incident: number?)
	local arg: number? = nil
	if code == Err.BadRequest then
		arg = if type(data) == "number" then data else 0
		data = nil
		badRequests += 1
	elseif code == Err.RateLimited then
		callsRateLimited += 1
	elseif code == Err.Busy then
		busyReplies += 1
	elseif code < 1 or code > C.WIRE_ERR_MAX then
		Log.once("cn:errcode", "the server sent an unknown error code " .. code)
		code = Err.InternalError
		msg = nil
		data = nil
		incident = nil
	end
	Calls.reject(req, code, msg, data, incident, arg)
end

-- A NOTICE, in its place among the frame's other messages.
local function applyNotice(kind: number, first: number, count: number)
	if kind == Notice.FrameDropped then
		framesDropped += count
		eventsLost += ringLost(rel, first, count)
		local n = Calls.dropped(first, count) -- rejects the dropped calls (user code)
		callsRateLimited += n
	elseif kind == Notice.UFrameDropped then
		framesDropped += count
		eventsLost += ringLost(unr, first, count)
	elseif kind == Notice.ShuttingDown then
		shuttingDown = true
	elseif kind == Notice.OutboxOverflow then
		outboxDropped += count
		Log.studioOnce(
			"cn:outbox",
			count .. " server messages to this client were dropped before it connected (pre-HELLO outbox full)"
		)
	end -- unknown kinds are ignored (the body is always 5 bytes)
end

-- The call was released after pass 1's lookup (ClientNet.fail, a spec's sweep): the one-pass lookup failed here.
local function released(req: Req, g: number): boolean
	return req.gen ~= g or Calls.lookup(req.id) ~= req
end

-- Pass 2 on a runner (Signal.drive): Signal and E_SKIP entries from b.pos; any other entry or a Backlog one ends it.
@native
local function deliverBody(b: Batch, me: number)
	local tape = b.tape
	local n = b.n
	local gen = b.gen
	local t = b.pos
	-- After a reset, a takeover still ends its message's listeners (the one-pass decoder's `fire` did), then stops.
	while t <= n and (generation == gen or b.node ~= nil) do
		local kind = tape[t]
		if kind == E_SIGNAL then
			local argc = tape[t + 2]
			local a = t + 3
			if b.node == nil then
				messagesIn += 1 -- a takeover goes on after b.node: its message is already counted
			end
			local ok
			if argc == 1 then
				ok = deliverIn1(b, me, tape[t + 1], tape[a])
			elseif argc == 0 then
				ok = deliverIn(b, me, tape[t + 1])
			elseif argc == 2 then
				ok = deliverIn(b, me, tape[t + 1], tape[a], tape[a + 1])
			elseif argc == 3 then
				ok = deliverIn(b, me, tape[t + 1], tape[a], tape[a + 1], tape[a + 2])
			else
				ok = deliverIn(b, me, tape[t + 1], table.unpack(tape, a, a + argc - 1))
			end
			if ok ~= true then
				if ok == nil then
					messagesIn -= 1 -- Backlog: deliverTape counts and queues it on the receiving thread, as before B2
					break
				end
				return -- this runner yielded or was left behind: the owner goes on
			end
			t = a + argc
			b.pos = t
		elseif kind == E_SKIP then
			messagesIn += tape[t + 1]
			signalsDropped += tape[t + 2]
			t += 3
			b.pos = t
		else
			break
		end
	end
	b.busy = false
end

-- Pass 2 on the receiving thread: every entry's effects at its place, a Signal run on deliverBody. False: frame ends.
@native
local function deliverTape(b: Batch): boolean
	local tape = b.tape
	local n = b.n
	local gen = b.gen
	local t = b.pos
	while t <= n do
		if generation ~= gen then
			return false -- a reset in user code: the one-pass decoder stopped here too
		end
		local kind = tape[t]
		if kind == E_SIGNAL then
			local sig = tape[t + 1]
			local argc = tape[t + 2]
			local a = t + 3
			local after = a + argc
			if after > n or quiet(sig) then -- the last entry, no listener or Backlog: Signal's own path, as before B2
				messagesIn += 1
				if argc == 1 then
					deliver(sig, tape[a])
				elseif argc == 0 then
					deliver(sig)
				elseif argc == 2 then
					deliver(sig, tape[a], tape[a + 1])
				elseif argc == 3 then
					deliver(sig, tape[a], tape[a + 1], tape[a + 2])
				else
					deliver(sig, table.unpack(tape, a, after - 1))
				end
				t = after
			else
				b.pos = t
				b.node = nil
				b.busy = true
				if not drive(deliverBody, b) then
					error("a delivery runner stopped outside a listener", 0)
				end
				t = b.pos
			end
		elseif kind == E_SKIP then
			messagesIn += tape[t + 1]
			signalsDropped += tape[t + 2]
			t += 3
		elseif kind == E_NOTICE then
			local nk, first, count = tape[t + 1], tape[t + 2], tape[t + 3]
			t += 4
			messagesIn += 1
			applyNotice(nk, first, count)
		else -- a reply: E_OK, E_ERR, E_MISSING or E_BAD
			local req: Req = tape[t + 1]
			if released(req, tape[t + 2]) then
				abort(if kind == E_ERR then "ERR for an unknown call id" else "OK for an unknown call id")
				return false
			end
			if kind == E_OK then
				local argc = tape[t + 3]
				local a = t + 4
				t = a + argc
				messagesIn += 1
				if not Calls.isPending(req) then
					Calls.late(req)
				elseif argc == 1 then
					Calls.resolve(req, tape[a])
				elseif argc == 0 then
					Calls.resolve(req)
				elseif argc == 2 then
					Calls.resolve(req, tape[a], tape[a + 1]) -- O23: unpack from a > 1 is the slow path
				elseif argc == 3 then
					Calls.resolve(req, tape[a], tape[a + 1], tape[a + 2])
				else
					Calls.resolve(req, table.unpack(tape, a, t - 1))
				end
			elseif kind == E_ERR then
				local code, msg, data, incident = tape[t + 3], tape[t + 4], tape[t + 5], tape[t + 6]
				t += 7
				messagesIn += 1
				if Calls.isPending(req) then
					rejectErr(req, code, msg, data, incident)
				else
					Calls.late(req)
				end
			elseif kind == E_MISSING then
				t += 3
				messagesIn += 1
				if Calls.isPending(req) then
					Calls.reject(req, Err.MissingInstance, nil, nil, nil, nil)
				else
					Calls.late(req)
				end
			else -- E_BAD: never counted (the one-pass decoder dropped the frame before counting it)
				if Calls.isPending(req) then
					Calls.reject(req, Err.InternalError, nil, nil, nil, nil)
				end
				abort(b.why :: string, b.route, b.num) -- the last entry; logged even after a reset, as before B2
				return false
			end
		end
	end
	return true
end

-- Empties slots [1, n] in O(n): table.clear walks the whole array (at most 2 x `high`), so only for 4n >= that.
@native
local function clearTape(b: Batch, n: number)
	b.n = 0
	if n <= 0 then
		return
	end
	local tape = b.tape
	local high = b.high
	if n > high then
		high = n
		b.high = n
	end
	local cap = if 2 * high > TAPE_CAP0 then 2 * high else TAPE_CAP0
	if 4 * n >= cap then
		table.clear(tape)
		lastClear = cap
	else
		for i = 1, n do
			tape[i] = nil
		end
		lastClear = n
	end
	if n > TAPE_KEEP then
		b.tape = table.create(TAPE_CAP0) -- after a burst the big array is not kept (the old one is empty)
		b.high = 0
	end
end

-- Pass 1 then pass 2, for each segment of the frame (one, unless decodeFrame SPLITs). Under onFrame's pcall.
local function receive(b: Batch, frame: buffer)
	while true do
		fillN = 0
		b.decoding = true
		debug.setmemorycategory(CAT)
		local status = decodeFrame(b, frame)
		debug.resetmemorycategory()
		b.decoding = false
		if claimedN > 0 then
			unclaim()
		end
		local n = fillN
		if n > 0 then
			b.n = n
			b.pos = 1
			local going = deliverTape(b)
			clearTape(b, n)
			if not going then
				return
			end
		end
		if generation ~= b.gen then
			return
		elseif status == STOP then
			abort(b.why :: string, b.route, b.num)
			return
		elseif status ~= SPLIT then
			return
		end
	end
end

-- A throw under onFrame's pcall: in pass 1 the complete entries still run, then the log; in pass 2 the rest drops.
local function onFault(b: Batch, err: any)
	table.clear(argv)
	unclaim()
	if b.decoding then
		b.decoding = false
		debug.resetmemorycategory()
		local n = fillN
		if n > 0 then
			b.n = n
			b.pos = 1
			local ok, going = pcall(deliverTape, b)
			clearTape(b, n)
			if not ok then
				err = going -- a fault at an earlier message: the one-pass decoder never got further
			elseif not going then
				return
			end
		end
		if generation ~= b.gen then
			return
		end
	else
		clearTape(b, b.n)
	end
	Log.once("cn:decode", "a server frame failed to decode: " .. tostring(err))
end

local function newBatch(): Batch
	return {
		owner = 0,
		busy = false,
		pos = 1,
		node = nil,
		stop = 0,
		gen = 0,
		n = 0,
		high = 0,
		tape = table.create(TAPE_CAP0),
		now = 0,
		refs = nil,
		p = 0,
		cursor = 0,
		decoding = false,
		why = nil,
		route = nil,
		num = nil,
	}
end

-- OnClientEvent (both remotes). `refs` only ever comes on the reliable remote.
local function onFrame(unreliable: boolean, frame: any, refs: any)
	if typeof(frame) ~= "buffer" or (refs ~= nil and type(refs) ~= "table") then
		return
	end
	if phase ~= PHASE_READY and phase ~= PHASE_CONNECTING then
		return
	end
	local len = buffer.len(frame)
	if model == nil then
		if unreliable or len < 1 or buffer.readu8(frame, 0) ~= Op.MANIFEST then
			return
		end
	end
	framesIn += 1
	bytesIn += len
	local b = spare or newBatch()
	spare = nil
	b.gen = generation
	b.now = clock()
	b.refs = refs
	b.p = 0
	b.cursor = 0
	local ok, err = pcall(receive :: any, b, frame)
	if not ok then
		onFault(b, err)
	end
	if refs ~= nil then
		ctx.refs = nil -- the decoder lets go of the frame's Instances too (a client frame never sets ctx.nrefs)
	end
	b.refs = nil -- nothing of this frame stays referenced (a parked listener's runner may still hold `b`)
	b.why = nil
	b.route = nil
	b.node = nil
	spare = b
end

local function onReliable(frame: any, refs: any)
	onFrame(false, frame, refs)
end

local function onUnreliable(frame: any)
	onFrame(true, frame, nil)
end

-- API ------------------------------------------------------------------------------------------------

function ClientNet.connect(): (Types.ManifestModel?, string?)
	if phase == PHASE_READY and model ~= nil then
		return model, nil
	elseif phase ~= PHASE_IDLE then
		return nil, if phase == PHASE_FAILED then "client network failed" else "already connecting"
	end
	phase = PHASE_CONNECTING
	local gen = generation
	local function stale(): boolean
		return generation ~= gen
	end
	-- A reset or a ClientNet.fail() during one of the waits below ends this connect.
	local function stopped(): string?
		if generation ~= gen then
			return "reset"
		elseif phase == PHASE_FAILED then
			return "client network failed"
		end
		return nil
	end
	local function failWith(reason: string): (Types.ManifestModel?, string?)
		if not stale() then
			phase = PHASE_FAILED
			disconnectAll()
		end
		return nil, reason
	end

	-- 1. ReplicatedStorage.LorenNet in State Ready or ShuttingDown (Failed -> give up).
	local started = os.clock()
	local warned = false
	local net: Instance? = nil
	while true do
		local why = stopped()
		if why then
			return nil, why
		end
		if net == nil or net.Parent ~= ReplicatedStorage then
			net = ReplicatedStorage:FindFirstChild(Names.NetFolder)
		end
		if net then
			local proto = net:GetAttribute(Names.ProtoAttr)
			if proto ~= nil and proto ~= C.PROTO then
				return failWith("protocol mismatch (server Proto " .. tostring(proto) .. ", client " .. C.PROTO .. ")")
			end
			local state = net:GetAttribute(Names.StateAttr)
			if state == NetState.Ready or state == NetState.ShuttingDown then
				local r = net:FindFirstChild(Names.Reliable)
				local u = net:FindFirstChild(Names.Unreliable)
				if r and u then
					if not r:IsA("RemoteEvent") or not u:IsA("UnreliableRemoteEvent") then
						return failWith("protocol mismatch (LorenNet remotes have the wrong classes)")
					end
					reliableRemote = r :: RemoteEvent
					unreliableRemote = u :: UnreliableRemoteEvent
					if state == NetState.ShuttingDown then
						shuttingDown = true
					end
					break
				end
			elseif state == NetState.Failed then
				return failWith("server boot failed")
			end
		end
		if not warned and os.clock() - started >= Limit.WAIT_WARN_NET then
			warned = true
			Log.warn(
				"still waiting for ReplicatedStorage.LorenNet to be Ready after "
					.. Limit.WAIT_WARN_NET
					.. " s (did the server call Loren.SetOnFire()?)"
			)
		end
		task.wait()
	end
	local netFolder = net :: Instance

	-- 2. Listeners before anything is sent.
	table.insert(connections, (reliableRemote :: RemoteEvent).OnClientEvent:Connect(onReliable))
	table.insert(connections, (unreliableRemote :: UnreliableRemoteEvent).OnClientEvent:Connect(onUnreliable))

	-- 3. HELLO (a restarted client waits until the server accepts a repeat HELLO).
	local spacing = lastHelloAt + HELLO_SPACING - os.clock()
	if spacing > 0 then
		task.wait(spacing)
		local why = stopped()
		if why then
			return nil, why
		end
	end
	sendHello()

	-- 4. Heartbeat: flush credit and the call sweeper.
	table.insert(connections, RunService.Heartbeat:Connect(onHeartbeat))

	-- 5. MANIFEST (decoded by onFrame). HELLO is repeated every HELLO_RETRY while none arrives.
	local helloStarted = os.clock()
	local warnedManifest = false
	while model == nil do
		local why = stopped()
		if why then
			return nil, why
		end
		local reason = manifestError
		if reason then
			return failWith(reason)
		end
		if netFolder:GetAttribute(Names.StateAttr) == NetState.Failed then
			return failWith("server boot failed")
		end
		local t = os.clock()
		if not warnedManifest and t - helloStarted >= Limit.WAIT_WARN_MANIFEST then
			warnedManifest = true
			Log.warn("still waiting for the server MANIFEST after " .. Limit.WAIT_WARN_MANIFEST .. " s")
		end
		if t - lastHelloAt >= HELLO_RETRY then
			sendHello()
		end
		task.wait()
	end
	return model, nil
end

-- Routes dense by id (after connect). Frozen.
function ClientNet.routes(): { ClientRoute }
	return routes
end

-- A Method call: a Promise, or (ok, ...) when `try` (the caller parks until the reply).
function ClientNet.call(route: ClientRoute, try: boolean, n: number, ...: any): ...any
	local code = 0
	if phase ~= PHASE_READY then
		code = if phase == PHASE_FAILED then Err.BootFailed else Err.NotReady
	elseif shuttingDown then
		code = Err.ShuttingDown
	elseif not Calls.canAlloc() then
		code = Err.TooManyInFlight
	elseif unsent >= unsentCap then
		code = Err.RateLimited
	end
	local now = clock()
	if code == 0 and not Bucket.can(routeBucket[route.id], 1, now) then
		code = Err.RateLimited
	end
	if code ~= 0 then
		return localReject(route, try, code, nil, 0)
	end
	if try and not coroutine.isyieldable() then
		error(PREFIX .. route.service .. ".Try:" .. route.member .. "() must run in a thread that can yield", 3)
	end

	local ch = rel
	local st = encodeMessage(route, ch.open.nrefs, 0, n, ...)
	if st ~= ENCODE_OK then
		local arg = w.errArg
		Codec.resetWriter(w)
		return localReject(route, try, Err.BadArgument, C.EncodeName[st], arg)
	end
	if w.lossy > 0 then
		warnLossy(route)
	end
	local len, nrefs, nodes, side = w.n, w.nrefs, w.nodes, w.sideBytes
	local reason: string? = nil
	local failCode = 0
	if len + NODE_CHARGE * nodes + side > C2S_MAX_MESSAGE then
		failCode = Err.PayloadTooLarge
	elseif nodes > MAX_NODES then
		failCode, reason = Err.BadArgument, "TooManyNodes"
	elseif nrefs > MAX_REFS then
		failCode, reason = Err.BadArgument, "TooManyRefs"
	end
	if failCode ~= 0 then
		Codec.resetWriter(w)
		return localReject(route, try, failCode, reason, 0)
	end
	if needsSeal(ch, len, nrefs, nodes, side) then
		seal(ch)
		if nrefs > 0 then
			-- Ref indexes are frame-absolute: re-encode for the new frame (same values, no user code).
			st = encodeMessage(route, 0, 0, n, ...)
			if st ~= ENCODE_OK then
				Codec.resetWriter(w)
				return localReject(route, try, Err.BadArgument, C.EncodeName[st], 0)
			end
			len, nrefs, nodes, side = w.n, w.nrefs, w.nodes, w.sideBytes
		end
	end
	local req = Calls.alloc(route, now)
	if req == nil then
		Codec.resetWriter(w)
		return localReject(route, try, Err.TooManyInFlight, nil, 0)
	end
	buffer.writeu16(w.buf, callIdAt, req.id)
	Bucket.take(routeBucket[route.id], 1, now)
	commit(ch, w.buf, len, w.refs, nrefs, nodes, side, req.id, false)
	Codec.resetWriter(w)
	if try then
		return Calls.park(req)
	end
	return Calls.promise(req)
end

function ClientNet.fire(route: ClientRoute, n: number, ...: any): ()
	if phase ~= PHASE_READY then
		eventsLost += 1
		return
	end
	local id = route.id
	local unreliable = route.unreliable
	local ch = if unreliable then unr else rel
	local seq = 0
	if route.ordered then
		seq = (sendSeq[id] + 1) % SEQ_MOD
		sendSeq[id] = seq
	end
	local st = encodeMessage(route, if unreliable then 0 else ch.open.nrefs, seq, n, ...)
	if st ~= ENCODE_OK then
		local arg = w.errArg
		Codec.resetWriter(w)
		error(
			string.format(
				"%s%s.%s:Fire: arg %d %s",
				PREFIX,
				route.service,
				route.member,
				arg,
				C.EncodeName[st] or tostring(st)
			),
			3
		)
	end
	if w.lossy > 0 then
		warnLossy(route)
	end
	local len, nrefs, nodes, side = w.n, w.nrefs, w.nodes, w.sideBytes
	local problem: string? = nil
	if unreliable then
		if HEADER + varintSize(len) + len > UNRELIABLE_SEAL then
			problem = string.format(
				"%d bytes is over the unreliable limit (%d bytes per frame, header included)",
				HEADER + varintSize(len) + len,
				UNRELIABLE_SEAL
			)
		end
	elseif len + NODE_CHARGE * nodes + side > C2S_MAX_MESSAGE then
		problem = string.format("payload too large (%d, max %d)", len + NODE_CHARGE * nodes + side, C2S_MAX_MESSAGE)
	elseif nodes > MAX_NODES then
		problem = "more than " .. MAX_NODES .. " table values in the arguments"
	elseif nrefs > MAX_REFS then
		problem = "more than " .. MAX_REFS .. " Instances or other non-plain values in the arguments"
	end
	if problem then
		Codec.resetWriter(w)
		error(PREFIX .. route.service .. "." .. route.member .. ":Fire: " .. problem, 3)
	end

	if route.coalesce and nrefs == 0 then
		-- Keep only the latest message; committed at the next flush (one mirror token per sent message).
		local buf = coBuf[id]
		local cap = coCap[id]
		if cap < len then
			cap = math.max(64, 2 * cap)
			while cap < len do
				cap *= 2
			end
			buf = buffer.create(cap)
			coBuf[id] = buf
			coCap[id] = cap
		end
		buffer.copy(buf, 0, w.buf, 0, len)
		coLen[id] = len
		Codec.resetWriter(w)
		return
	end
	if unsent >= unsentCap or not Bucket.take(routeBucket[id], 1, clock()) then
		Codec.resetWriter(w)
		loseEvent(route)
		return
	end
	if needsSeal(ch, len, nrefs, nodes, side) then
		seal(ch)
		if nrefs > 0 then
			st = encodeMessage(route, 0, seq, n, ...)
			if st ~= ENCODE_OK then
				Codec.resetWriter(w)
				loseEvent(route)
				return
			end
			len, nrefs, nodes, side = w.n, w.nrefs, w.nodes, w.sideBytes
		end
	end
	commit(ch, w.buf, len, w.refs, nrefs, nodes, side, 0, true)
	Codec.resetWriter(w)
end

-- Loren.Flush on the client: one flush if the credit allows, else the next Heartbeat sends.
function ClientNet.flush(): ()
	if phase ~= PHASE_READY then
		return
	end
	tryFlush(clock(), false)
end

-- Client boot failure: stop the network; pending and later calls reject BootFailed.
function ClientNet.fail(): ()
	phase = PHASE_FAILED
	disconnectAll()
	local r, u = reliableRemote, unreliableRemote
	if r ~= nil then
		table.insert(connections, r.OnClientEvent:Connect(onReliable))
	end
	if u ~= nil then
		table.insert(connections, u.OnClientEvent:Connect(onUnreliable))
	end
	for _, ch in { rel, unr } do
		while ch.qhead <= ch.qtail do
			recycle(ch.queue[ch.qhead], false)
			ch.queue[ch.qhead] = nil :: any
			ch.qhead += 1
		end
		ch.qhead = 1
		ch.qtail = 0
		local fr = ch.open
		if fr.nmsg > 0 then
			ch.open = takeFrame()
			recycle(fr, false)
		end
	end
	unsent = 0
	for id in coLen do
		coLen[id] = 0
	end
	Calls.failAll()
end

function ClientNet.getStats(): Types.Stats
	local sig = Signal.stats()
	return {
		Side = "Client",
		FramesIn = framesIn,
		FramesOut = framesOut,
		BytesIn = bytesIn,
		BytesOut = bytesOut,
		MessagesIn = messagesIn,
		MessagesOut = messagesOut,
		FramesDropped = framesDropped,
		EventsLost = eventsLost,
		CallsRateLimited = callsRateLimited,
		BadRequests = badRequests,
		Busy = busyReplies,
		Violations = 0,
		LateReplies = Calls.lateReplies(),
		OutboxDropped = outboxDropped,
		SignalsDropped = signalsDropped + sig.backlogDropped,
		RunningCalls = 0,
		ZombieCalls = 0,
		PendingCalls = Calls.pending(),
		Players = 0,
		Routes = #routes,
	}
end

function ClientNet._reset(): ()
	generation += 1
	disconnectAll()
	phase = PHASE_IDLE
	shuttingDown = false
	clock = os.clock
	fireHook = nil
	reliableRemote = nil
	unreliableRemote = nil
	model = nil
	manifestError = nil
	hellosSent = 0
	routes = NO_ROUTES
	routeBucket = {}
	sendSeq = {}
	rxLast = {}
	rxTime = {}
	coBuf = {}
	coCap = {}
	coLen = {}
	coList = {}
	warnedLossy = {}
	warnedLost = {}
	rel = newChannel(false)
	unr = newChannel(true)
	byteBucket = emptyBucket()
	msgBucket = emptyBucket()
	msgCap = MAX_MSGS
	unsentCap = 2 * MAX_MSGS
	unsent = 0
	interval = 1 / Limit.FLUSH_HZ
	acc = 0
	inlineTables = true
	Codec.resetWriter(w)
	Codec.beginFrame(ctx, nil, 0)
	table.clear(argv)
	spare = nil -- a frame being received keeps its own batch, and parks it here when it ends
	fillN = 0
	table.clear(claimed)
	table.clear(claimedList)
	claimedN = 0
	lastClear = 0
	nfailed = 0
	abortLogged = false
	framesIn, bytesIn, messagesIn = 0, 0, 0
	framesOut, bytesOut, messagesOut = 0, 0, 0
	framesDropped, eventsLost, callsRateLimited = 0, 0, 0
	badRequests, busyReplies, outboxDropped, signalsDropped = 0, 0, 0, 0
	flushes = 0
end

-- Spec hooks (unit specs run on the server with no remotes).
ClientNet._test = table.freeze({
	-- Installs a decoded manifest model directly: routes, mirror, flush credit (no remotes, no Heartbeat).
	loadManifest = function(m: Types.ManifestModel)
		install(m)
	end,
	-- CONNECTING without a network, so a MANIFEST can arrive through `receive`.
	begin = function()
		phase = PHASE_CONNECTING
	end,
	-- Fake clock for buckets, deadlines and ordering (nil restores os.clock; Calls too).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
		Calls._test.setClock(fn)
	end,
	setFire = function(fn: ((boolean, buffer, { any }?, number, number) -> ())?)
		fireHook = fn
	end,
	-- Feeds one S->C frame exactly as OnClientEvent would.
	receive = function(frame: any, refs: any, unreliable: boolean?)
		onFrame(unreliable == true, frame, refs)
	end,
	-- One Heartbeat step with a fake dt (flush credit + sweeper).
	heartbeat = function(dt: number)
		onHeartbeat(dt)
	end,
	-- A flush that ignores the credit (still paced by the admission mirror).
	flushNow = function()
		if phase == PHASE_READY then
			local ok, err = pcall(flush :: any, clock())
			if not ok then
				flushFault(err)
			end
			settleFailed()
		end
	end,
	setSeq = function(unreliable: boolean, seq: number)
		local ch = if unreliable then unr else rel
		ch.seq = seq % SEQ_MOD
	end,
	state = function(): { [string]: any }
		return {
			phase = phase,
			unsent = unsent,
			unsentCap = unsentCap,
			msgCap = msgCap,
			acc = acc,
			interval = interval,
			flushes = flushes,
			relSeq = rel.seq,
			unrSeq = unr.seq,
			relQueued = rel.qtail - rel.qhead + 1,
			unrQueued = unr.qtail - unr.qhead + 1,
			relOpen = rel.open.nmsg,
			unrOpen = unr.open.nmsg,
			shuttingDown = shuttingDown,
			manifestError = manifestError,
			tokens = {
				relFrame = rel.frame.tokens,
				unrFrame = unr.frame.tokens,
				bytes = byteBucket.tokens,
				messages = msgBucket.tokens,
			},
		}
	end,
	routeBucket = function(id: number): BucketT
		return routeBucket[id]
	end,
	-- True when nothing of the last frame is held: no tape values or refs in the spare batch, no refs in the decoder.
	tapeEmpty = function(): boolean
		local b = spare
		return ctx.refs == nil and (b == nil or (b.n == 0 and b.refs == nil and b.node == nil and next(b.tape) == nil))
	end,
	-- `high`: most tape slots used since the tape was made; `lastClear`: slots the last frame's clear touched.
	tapeStats = function(): { high: number, lastClear: number }
		local b = spare
		return { high = if b then b.high else 0, lastClear = lastClear }
	end,
})

return table.freeze(ClientNet)
