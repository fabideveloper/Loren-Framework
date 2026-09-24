--!strict
--!optimize 2
--[[
	Outbox (owner lane: server-net): player states, the reliable and unreliable channels, the
	pre-HELLO outbox, OK/ERR/NOTICE messages and the per-frame flush.
	Spec: design/loren-2.0/IMPLEMENTATION.md sections 3.16 (PlayerState, Send path, Flush), 4.2, 4.4,
	4.10 (onHello) and 9.

	- Every S->C message is encoded once into the shared scratch writer (Outbox.begin) and then
	  committed: its bytes are copied (buffer.copy) and its refs moved (table.move) into the player's
	  channel, and its boundary (byte start, ref start, callId) is recorded. A broadcast commits the
	  same scratch to every target, so it costs one encode plus N copies.
	- Before HELLO the reliable channel is the outbox (OUTBOX_BYTES / OUTBOX_MSGS, OUTBOX_TTL after
	  join); unreliable messages are dropped. OK, ERR and NOTICE are never written before HELLO. The
	  HELLO puts MANIFEST (and a NOTICE OutboxOverflow) in front of everything already queued.
	- flushAll (Transport's parked flush thread, once per server frame; also Loren.Flush) swaps the
	  dirty list first, then flushes each helloed player under its own pcall: pending NOTICE runs,
	  frames sealed at S2C_SEAL (a larger message goes alone), each an exact-size copy plus a refs
	  slice. Every frame is staged before the channel is reset, and the channel is reset before the
	  first FireClient. A fire that errors is retried one message at a time; only the failing message
	  is lost, and an OK or a data-carrying ERR in it becomes a plain ERR BadResult in the next flush.
	- Requiring this module has no side effects (a buffer is not an Instance).
]]

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Runtime = ReplicatedStorage.LorenRuntime

local C = require(Runtime.Constants)
local Types = require(Runtime.Types)
local Codec = require(Runtime.Codec)
local Errors = require(Runtime.Errors)
local Log = require(Runtime.Log)
local Limits = require(script.Parent.Limits)
local Violations = require(script.Parent.Violations)

type Writer = Types.Writer
type PayloadCodec = Types.PayloadCodec

-- One network member of one service (built and frozen by Routes; defined here because every
-- server-net module needs it and Outbox is the lowest of them in the require graph).
export type Route = {
	id: number,
	kind: number, -- C.Kind
	service: string,
	member: string,
	fullName: string, -- "Svc.Member"
	unreliable: boolean,
	ordered: boolean,
	coalesce: boolean,
	serial: boolean,
	cancelOnTimeout: boolean,
	allowNonFinite: boolean,
	timeout: number, -- Method: seconds, rounded to 0.1 (the value the manifest ships); else 0
	rate: number,
	burst: number,
	fn: any, -- Method: module.Client[name] at boot; else false (Dispatch reads self[member] per call)
	self: any, -- Method: module.Client; else false
	module: any, -- Method/Event: the Service module (Dispatch reads Middleware[member] per call); else false
	middleware: any, -- module.Middleware[name] at boot, or false
	colon: boolean, -- the boot middleware looks colon-style: every call is denied while it is in place
	args: PayloadCodec, -- Method/Event: C->S decode; Signal: S->C encode
	returns: PayloadCodec | false, -- Method: S->C encode
	event: Types.ServerEvent | false,
	signal: Types.ServerSignal | false,
	info: { Service: string, Member: string, Kind: string }, -- frozen; passed to global middleware
}

export type RouteTable = {
	routes: { Route }, -- dense by id
	count: number,
	services: number, -- networked services (manifest services)
	manifestMsg: buffer, -- 0xF1 len:u32 + Manifest.encode(model)
	model: Types.ManifestModel,
	signals: { [string]: { [string]: Types.ServerSignal } },
	events: { [string]: { [string]: Types.ServerEvent } },
}

-- A call whose handler (or middleware) yielded. Allocated only then.
export type CallRec = {
	route: Route,
	token: number,
	thread: thread,
	deadline: number, -- receipt + route.timeout + WatchdogGrace
}

-- A call waiting in the player queue or a Serial queue.
export type QueueEntry = {
	callId: number,
	token: number,
	route: Route,
	receipt: number,
	args: { n: number, [number]: any },
}

-- FrameDropped runs (first, count) not yet reported, for one C->S channel.
export type DropRuns = {
	first: { number },
	count: { number },
	n: number,
}

export type Channel = {
	w: Writer, -- bytes + refs (refs only on the reliable channel)
	nmsg: number,
	starts: { number }, -- byte offset of message i
	refStarts: { number }, -- refs before message i
	callIds: { number }, -- > 0: OK or data-carrying ERR (BadResult fallback); < 0: plain ERR; 0: other
	-- The flush swaps these with the live arrays, so a retry reads stable boundaries.
	spareStarts: { number },
	spareRefStarts: { number },
	spareCallIds: { number },
	idle: number, -- consecutive flushes that used under a quarter of a large buffer
}

export type PlayerState = {
	player: Player,
	helloed: boolean,
	gone: boolean,
	joinedAt: number,
	lastHello: number,
	helloOnly: boolean, -- nothing but HELLO received since the last accepted HELLO (an honest retry)
	out: Channel, -- reliable
	uout: Channel, -- unreliable
	outboxBytes: number, -- pre-HELLO accounting
	outboxMsgs: number,
	outboxDropped: number, -- messages dropped before HELLO (NOTICE OutboxOverflow count)
	outboxExpired: boolean,
	overflowWarned: boolean,
	lim: Limits.PlayerLimits,
	viol: Violations.PlayerViolations,
	-- Dispatch state (section 4.11)
	callTok: { [number]: number }, -- callId -> token of the live call
	calls: { [number]: CallRec }, -- callId -> record (yielded calls only)
	running: number, -- yielded calls
	queued: number, -- entries in `queue`
	queue: { QueueEntry }, -- player queue (FIFO)
	zombies: number,
	routeZombies: { [number]: number },
	serialActive: { [number]: boolean },
	serialQ: { [number]: { QueueEntry } },
	readmit: { Route }, -- Serial routes whose occupant ended; the drain re-admits their queue head
	draining: boolean,
	-- Ordered ClientEvents receive state (per route id)
	rxSeq: { [number]: number },
	rxSeqT: { [number]: number },
	dropRuns: { DropRuns }, -- [1] reliable (NOTICE FrameDropped), [2] unreliable (UFrameDropped)
	dirty: boolean,
	index: number, -- position in the player list
}

type FireCapture = (channel: string, player: Player, frame: buffer, refs: { any }?) -> ()

local L = C.Limit
local OP_OK = C.Op.OK
local OP_ERR = C.Op.ERR
local OP_NOTICE = C.Op.NOTICE
local NOTICE_FRAME = C.Notice.FrameDropped
local NOTICE_UFRAME = C.Notice.UFrameDropped
local NOTICE_OVERFLOW = C.Notice.OutboxOverflow
local FLAG_MSG = C.ErrFlag.Msg
local FLAG_DATA = C.ErrFlag.Data
local FLAG_INCIDENT = C.ErrFlag.Incident
local ERR_BAD_RESULT = C.Err.BadResult
local DROP_OVERFLOW = C.Drop.OutboxOverflow
local DROP_EXPIRED = C.Drop.OutboxExpired
local DROP_UNRELIABLE_EARLY = C.Drop.UnreliableEarly
local DROP_DEPARTED = C.Drop.Departed

local S2C_SEAL = L.S2C_SEAL
local UNRELIABLE_SEAL = L.UNRELIABLE_SEAL
local OUTBOX_BYTES = L.OUTBOX_BYTES
local OUTBOX_MSGS = L.OUTBOX_MSGS
local OUTBOX_TTL = L.OUTBOX_TTL
local NOTICE_RUNS_MAX = L.NOTICE_RUNS_MAX
local NOTICE_SIZE = 6 -- op + kind:u8 first:u16 count:u16

local isStudio = RunService:IsStudio()
local SHRINK_ABOVE = 65536 -- channel buffers above this shrink after SHRINK_AFTER quiet flushes
local SHRINK_AFTER = 10
local SCRATCH_CAP0 = 1024
local SCRATCH_KEEP = 4 * S2C_SEAL -- a scratch grown past this by one big message is replaced before the next
local BOUNDARY_KEEP = 1024 -- boundary arrays that held more messages are replaced after their flush

local reserve = Codec.reserve
local resetWriter = Codec.resetWriter
local writeU8 = Codec.writeU8
local writeU16 = Codec.writeU16
local writeU32 = Codec.writeU32
local writeVarint = Codec.writeVarint
local writeString = Codec.writeString
local writeValue = Codec.writeValue

-- Module state (restored by _reset) ----------------------------------------------------------------

local states: { [any]: PlayerState } = {} -- Player -> state
-- Players that left (weak keys). A PlayerRemoving listener that runs after Loren's may still Fire to
-- the leaving Player (Parent is still Players then); adopt must not re-create its state.
local departedSet: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local list: { PlayerState } = {} -- dense; identity kept for the module's lifetime
local dirty: { PlayerState } = {}
local dirtyN = 0
local dirtySpare: { PlayerState } = {}
local flushing = false

local scratch: Writer = Codec.newWriter(SCRATCH_CAP0, false) -- the server's only encode target
local inlineTables = true

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil
local capture: FireCapture? = nil
local clock: () -> number = os.clock
local hintedLossy: { [number]: boolean } = {} -- route id -> lossy-returns hint shown (Studio)

-- Frame staging for the player being flushed (flushes never nest: `flushing`).
local stageBuf: { buffer } = {}
local stageRefs: { any } = {} -- refs slice or false
local stageNRefs: { number } = {}
local stageFrom: { number } = {}
local stageTo: { number } = {}

local framesOut = 0
local bytesOut = 0
local messagesOut = 0
local fireFailures = 0

local Outbox = {}

-- Helpers ------------------------------------------------------------------------------------------

local function readUserId(player: any): any
	return player.UserId
end

-- For log lines only (a test double may lack UserId).
local function uidOf(player: any): number
	local ok, uid = pcall(readUserId, player)
	return if ok and type(uid) == "number" then uid else 0
end

local function newChannel(cap: number): Channel
	return {
		w = Codec.newWriter(cap, false),
		nmsg = 0,
		starts = {},
		refStarts = {},
		callIds = {},
		spareStarts = {},
		spareRefStarts = {},
		spareCallIds = {},
		idle = 0,
	}
end

local function resetChannel(ch: Channel)
	resetWriter(ch.w)
	ch.nmsg = 0
end

local function markDirty(ps: PlayerState)
	if not ps.dirty then
		ps.dirty = true
		dirtyN += 1
		dirty[dirtyN] = ps
	end
end

-- Appends the scratch message `w` to the player's reliable channel and records its boundary.
-- callId: > 0 for OK and data-carrying ERR, -callId for a plain ERR, 0 otherwise. The caller has
-- already applied the HELLO/outbox rules.
@native
local function commit(ps: PlayerState, w: Writer, callId: number): ()
	local ch = ps.out
	local cw = ch.w
	local n = w.n
	local refBase = cw.nrefs
	local o = reserve(cw, n)
	buffer.copy(cw.buf, o, w.buf, 0, n)
	local nr = w.nrefs
	if nr > 0 then
		table.move(w.refs, 1, nr, refBase + 1, cw.refs)
		cw.nrefs = refBase + nr
	end
	local k = ch.nmsg + 1
	ch.nmsg = k
	ch.starts[k] = o
	ch.refStarts[k] = refBase
	ch.callIds[k] = callId
	messagesOut += 1
	if not ps.dirty then
		ps.dirty = true
		dirtyN += 1
		dirty[dirtyN] = ps
	end
end
Outbox.commit = commit

local function commitUnreliable(ps: PlayerState, w: Writer)
	local ch = ps.uout
	local cw = ch.w
	local n = w.n
	local o = reserve(cw, n)
	buffer.copy(cw.buf, o, w.buf, 0, n)
	local k = ch.nmsg + 1
	ch.nmsg = k
	ch.starts[k] = o
	messagesOut += 1
	markDirty(ps)
end

-- Writes a NOTICE straight into the reliable channel (no dirty mark: the flush calls it).
local function appendNotice(ps: PlayerState, kind: number, first: number, count: number)
	local ch = ps.out
	local cw = ch.w
	local refBase = cw.nrefs
	local o = reserve(cw, NOTICE_SIZE)
	local b = cw.buf
	buffer.writeu8(b, o, OP_NOTICE)
	buffer.writeu8(b, o + 1, kind)
	buffer.writeu16(b, o + 2, first)
	buffer.writeu16(b, o + 4, count)
	local k = ch.nmsg + 1
	ch.nmsg = k
	ch.starts[k] = o
	ch.refStarts[k] = refBase
	ch.callIds[k] = 0
	messagesOut += 1
end

-- TTL passed without HELLO: the outbox is cleared and later reliable messages are dropped.
local function expire(ps: PlayerState)
	local cleared = ps.out.nmsg
	resetChannel(ps.out)
	ps.outboxExpired = true
	ps.outboxBytes = 0
	ps.outboxMsgs = 0
	if cleared > 0 then
		ps.outboxDropped += cleared
		Violations.drop(ps.viol, DROP_EXPIRED, cleared)
	end
end

-- A reliable message to a player who has not sent HELLO yet (the outbox rules).
local function queueEarly(ps: PlayerState, w: Writer)
	if not ps.outboxExpired and clock() - ps.joinedAt > OUTBOX_TTL then
		expire(ps)
	end
	if ps.outboxExpired then
		ps.outboxDropped += 1
		Violations.drop(ps.viol, DROP_EXPIRED, 1)
		return
	end
	local bytes = ps.outboxBytes + w.n
	local msgs = ps.outboxMsgs + 1
	if bytes > OUTBOX_BYTES or msgs > OUTBOX_MSGS then
		ps.outboxDropped += 1
		Violations.drop(ps.viol, DROP_OVERFLOW, 1)
		if not ps.overflowWarned then
			ps.overflowWarned = Log.warnf(
				"uid=%d has not sent HELLO and its outbox is full (%d KiB / %d messages); newer messages are dropped",
				uidOf(ps.player),
				OUTBOX_BYTES // 1024,
				OUTBOX_MSGS
			)
		end
		return
	end
	ps.outboxBytes = bytes
	ps.outboxMsgs = msgs
	commit(ps, w, 0)
end

-- The scratch writer, reset for a new message. A buffer grown past SCRATCH_KEEP by an earlier
-- (large) message is dropped here, so one big Fire does not pin its memory for the server's lifetime.
local function takeScratch(): Writer
	local w = scratch
	if w.cap > SCRATCH_KEEP then
		w.buf = buffer.create(SCRATCH_CAP0)
		w.cap = SCRATCH_CAP0
	end
	resetWriter(w)
	return w
end

function Outbox.begin(unreliable: boolean): Writer
	local w = takeScratch()
	w.unreliable = unreliable
	return w
end

-- Clears the scratch writer after an aborted encode (drops the refs it holds).
function Outbox.abort(): ()
	resetWriter(scratch)
end

-- A reliable non-reply message (SIGNAL) for one player.
function Outbox.send(ps: PlayerState, w: Writer): ()
	if ps.helloed then
		if not ps.gone then
			commit(ps, w, 0)
		end
	elseif not ps.gone then
		queueEarly(ps, w)
	end
end

-- An unreliable message for one player: dropped (counted) before HELLO.
function Outbox.sendUnreliable(ps: PlayerState, w: Writer): ()
	if ps.gone then
		return
	end
	if ps.helloed then
		commitUnreliable(ps, w)
	else
		Violations.drop(ps.viol, DROP_UNRELIABLE_EARLY, 1)
	end
end

-- A Fire to a player who already left (no state): a no-op, counted in GetStats().SignalsDropped.
function Outbox.departed(): ()
	Violations.drop(nil, DROP_DEPARTED, 1)
end

-- Studio hint, once per route; no string is built outside Studio or after the first time.
local function lossyHint(route: Route)
	if not isStudio or hintedLossy[route.id] then
		return
	end
	hintedLossy[route.id] = true
	Log.studioOnce(
		"lossy-returns:" .. route.fullName,
		route.fullName
			.. " returned functions, threads or tables with metatables; they were sent as nil or plain tables"
	)
end

-- OK: callId + returns payload. Returns (C.Encode status, argument index); on failure nothing is
-- written and the caller replies BadResult.
function Outbox.sendOk(ps: PlayerState, route: Route, callId: number, n: number, ...: any): (number, number)
	if ps.gone or not ps.helloed then
		return 0, 0
	end
	if route.returns == false then
		return 0, 0
	end
	local returns: PayloadCodec = route.returns :: any
	local w = takeScratch()
	w.unreliable = false
	writeU8(w, OP_OK)
	writeU16(w, callId)
	local st = returns.encode(w, n, ...)
	if st ~= 0 then
		local arg = w.errArg
		resetWriter(w)
		return st, arg
	end
	if w.lossy > 0 then
		lossyHint(route)
	end
	commit(ps, w, callId)
	return 0, 0
end

-- ERR: callId code flags [msg] [data] [incident]. Returns a C.Encode status (only `data` can fail;
-- nothing is written then).
function Outbox.sendErr(
	ps: PlayerState,
	callId: number,
	code: number,
	msg: string?,
	data: any,
	hasData: boolean,
	incident: number?
): number
	if ps.gone or not ps.helloed then
		return 0
	end
	local w = takeScratch()
	w.unreliable = false
	writeU8(w, OP_ERR)
	writeU16(w, callId)
	writeU8(w, code)
	local flags = 0
	if msg ~= nil then
		flags += FLAG_MSG
	end
	if hasData then
		flags += FLAG_DATA
	end
	if incident ~= nil then
		flags += FLAG_INCIDENT
	end
	writeU8(w, flags)
	if msg ~= nil then
		local text = Errors.truncate(msg)
		writeVarint(w, #text)
		writeString(w, text)
	end
	if hasData then
		local st = writeValue(w, data, 0)
		if st ~= 0 then
			resetWriter(w)
			return st
		end
	end
	if incident ~= nil then
		writeU32(w, incident)
	end
	commit(ps, w, if hasData then callId else -callId)
	return 0
end

-- A NOTICE for a helloed player (ShuttingDown); goes out with the next flush.
function Outbox.notice(ps: PlayerState, kind: number, first: number, count: number): ()
	if ps.gone or not ps.helloed then
		return
	end
	appendNotice(ps, kind, first, count)
	markDirty(ps)
end

-- A C->S frame of this channel was refused at admission: extends or opens a FrameDropped run
-- (at most NOTICE_RUNS_MAX per channel per flush; further runs are not reported).
function Outbox.recordDrop(ps: PlayerState, unreliable: boolean, seq: number): ()
	if ps.gone or not ps.helloed then
		return
	end
	local runs = ps.dropRuns[if unreliable then 2 else 1]
	local n = runs.n
	if n > 0 then
		local count = runs.count[n]
		if count < 65535 and (runs.first[n] + count) % 65536 == seq then
			runs.count[n] = count + 1
			markDirty(ps)
			return
		end
	end
	if n < NOTICE_RUNS_MAX then
		n += 1
		runs.first[n] = seq
		runs.count[n] = 1
		runs.n = n
		markDirty(ps)
	end
end

-- Removes OK/ERR messages still in the channel (repeat HELLO: the restarted client has no pending
-- call with those ids, and an unknown id would abort the rest of its frame).
local function purgeReplies(ch: Channel)
	local nm = ch.nmsg
	if nm == 0 then
		return
	end
	local cw = ch.w
	local b = cw.buf
	local refs = cw.refs
	local total = cw.n
	local totalRefs = cw.nrefs
	local starts, refStarts, callIds = ch.starts, ch.refStarts, ch.callIds
	local wpos, rpos, k = 0, 0, 0
	for i = 1, nm do
		local s = starts[i]
		local e = if i < nm then starts[i + 1] else total
		local rs = refStarts[i]
		local re = if i < nm then refStarts[i + 1] else totalRefs
		if callIds[i] == 0 then
			k += 1
			if s ~= wpos then
				buffer.copy(b, wpos, b, s, e - s)
			end
			if re > rs and rs ~= rpos then
				table.move(refs, rs + 1, re, rpos + 1)
			end
			starts[k] = wpos
			refStarts[k] = rpos
			callIds[k] = 0
			wpos += e - s
			rpos += re - rs
		end
	end
	for i = rpos + 1, totalRefs do
		refs[i] = nil
	end
	cw.n = wpos
	cw.nrefs = rpos
	ch.nmsg = k
end

-- Puts MANIFEST (and a NOTICE OutboxOverflow when `dropped > 0`) in front of the queued messages.
local function prependManifest(ch: Channel, manifestMsg: buffer, dropped: number)
	local cw = ch.w
	local mlen = buffer.len(manifestMsg)
	local k = if dropped > 0 then 2 else 1
	local pre = if dropped > 0 then mlen + NOTICE_SIZE else mlen
	local oldN = cw.n
	reserve(cw, pre)
	local b = cw.buf
	if oldN > 0 then
		buffer.copy(b, pre, b, 0, oldN) -- overlapping copies act like memmove
	end
	buffer.copy(b, 0, manifestMsg, 0, mlen)
	if dropped > 0 then
		buffer.writeu8(b, mlen, OP_NOTICE)
		buffer.writeu8(b, mlen + 1, NOTICE_OVERFLOW)
		buffer.writeu16(b, mlen + 2, 0)
		buffer.writeu16(b, mlen + 4, math.min(dropped, 65535))
	end
	local nm = ch.nmsg
	local starts, refStarts, callIds = ch.starts, ch.refStarts, ch.callIds
	if nm > 0 then
		table.move(starts, 1, nm, 1 + k)
		table.move(refStarts, 1, nm, 1 + k)
		table.move(callIds, 1, nm, 1 + k)
		for i = 1 + k, nm + k do
			starts[i] += pre
		end
	end
	starts[1] = 0
	refStarts[1] = 0
	callIds[1] = 0
	if k == 2 then
		starts[2] = mlen
		refStarts[2] = 0
		callIds[2] = 0
	end
	ch.nmsg = nm + k
	messagesOut += k
end

-- An accepted HELLO (section 4.10 onHello; Transport has checked REHELLO_MIN and abandoned the
-- calls of a repeat HELLO): MANIFEST, then NOTICE OutboxOverflow if messages were dropped before
-- HELLO, then everything already queued (bytes and refs in order).
function Outbox.hello(ps: PlayerState, manifestMsg: buffer, now: number): ()
	if ps.gone then
		return
	end
	-- A first HELLO later than OUTBOX_TTL after join: the outbox has expired even if no message or
	-- flush has noticed it yet (its messages count in the OutboxOverflow NOTICE).
	if not ps.helloed and not ps.outboxExpired and now - ps.joinedAt > OUTBOX_TTL then
		expire(ps)
	end
	-- Runs recorded before this HELLO name frames of the previous session (seq restarts at 0).
	ps.dropRuns[1].n = 0
	ps.dropRuns[2].n = 0
	if ps.helloed then
		purgeReplies(ps.out)
	end
	prependManifest(ps.out, manifestMsg, ps.outboxDropped)
	ps.helloed = true
	ps.lastHello = now
	ps.helloOnly = true
	ps.outboxBytes = 0
	ps.outboxMsgs = 0
	ps.outboxDropped = 0
	ps.outboxExpired = false
	markDirty(ps)
end

-- Flush --------------------------------------------------------------------------------------------

local function fireReliable(player: Player, frame: buffer, refs: { any }?)
	local cap = capture
	if cap then
		cap("Reliable", player, frame, refs)
		return
	end
	local remote = reliableRemote
	if remote == nil then
		return
	end
	if refs then
		remote:FireClient(player, frame, refs)
	else
		remote:FireClient(player, frame)
	end
end

local function fireUnreliable(player: Player, frame: buffer)
	local cap = capture
	if cap then
		cap("Unreliable", player, frame, nil)
		return
	end
	local remote = unreliableRemote
	if remote ~= nil then
		remote:FireClient(player, frame)
	end
end

-- The reply in a lost message becomes ERR BadResult (new incident, logged, no msg) next flush.
local function replyLost(ps: PlayerState, callId: number, err: any)
	local incident = Errors.newIncident()
	Log.warnf(
		"a reply to uid=%d (call %d) could not be sent [%s]: %s",
		uidOf(ps.player),
		callId,
		Errors.hex(incident),
		tostring(err)
	)
	Outbox.sendErr(ps, callId, ERR_BAD_RESULT, nil, nil, false, incident)
end

-- A staged frame's FireClient errored: re-fire it one message at a time.
local function retryFrame(
	ps: PlayerState,
	frame: buffer,
	slice: { any }?,
	frameRefs: number,
	starts: { number },
	refStarts: { number },
	callIds: { number },
	from: number,
	to: number
)
	local player = ps.player
	local base = starts[from]
	local refBase = refStarts[from]
	local len = buffer.len(frame)
	for k = from, to do
		local ms = starts[k] - base
		local me = if k < to then starts[k + 1] - base else len
		local rs = refStarts[k] - refBase
		local re = if k < to then refStarts[k + 1] - refBase else frameRefs
		local msg = buffer.create(me - ms)
		buffer.copy(msg, 0, frame, ms, me - ms)
		local mrefs: { any }? = nil
		if re > rs and slice then
			local t = table.create(re - rs)
			table.move(slice, rs + 1, re, 1, t)
			mrefs = t
		end
		local ok, err = pcall(fireReliable :: any, player, msg, mrefs)
		if ok then
			framesOut += 1
			bytesOut += me - ms
		else
			fireFailures += 1
			local cid = callIds[k]
			if cid > 0 then
				replyLost(ps, cid, err)
			else
				Log.once("s2c-fire", "a message to uid=" .. uidOf(player) .. " could not be sent: " .. tostring(err))
			end
		end
	end
end

-- Large buffers that stay mostly empty for SHRINK_AFTER flushes drop to max(1 KiB, 2 x use).
-- A buffer grown past SCRATCH_KEEP (a burst far above one frame) is replaced at once: the player may
-- go quiet and never flush again. Called right after the channel was reset (its bytes are staged).
local function shrinkIfIdle(ch: Channel, used: number)
	local cw = ch.w
	if cw.cap > SCRATCH_KEEP and cw.n == 0 then
		cw.buf = buffer.create(SCRATCH_CAP0)
		cw.cap = SCRATCH_CAP0
		ch.idle = 0
		return
	end
	if cw.cap <= SHRINK_ABOVE or used * 4 >= cw.cap then
		ch.idle = 0
		return
	end
	ch.idle += 1
	if ch.idle >= SHRINK_AFTER and cw.n == 0 then
		local size = math.max(1024, used * 2)
		cw.buf = buffer.create(size)
		cw.cap = size
		ch.idle = 0
	end
end

local function flushReliable(ps: PlayerState)
	local ch = ps.out
	local cw = ch.w
	local total = cw.n
	if total == 0 then
		return
	end
	local nmsg = ch.nmsg
	local nrefs = cw.nrefs
	local starts, refStarts, callIds = ch.starts, ch.refStarts, ch.callIds
	local src = cw.buf
	local refs = cw.refs

	-- 1. Stage every frame (exact-size copies and ref slices). No user code runs here.
	local nf = 0
	local i = 1
	while i <= nmsg do
		local fs = starts[i]
		local j = nmsg
		if total - fs > S2C_SEAL then
			j = i
			while j < nmsg do
				local nextEnd = if j + 1 < nmsg then starts[j + 2] else total
				if nextEnd - fs > S2C_SEAL then
					break
				end
				j += 1
			end
		end
		local fe = if j < nmsg then starts[j + 1] else total
		local frame = buffer.create(fe - fs)
		buffer.copy(frame, 0, src, fs, fe - fs)
		local rs = refStarts[i]
		local re = if j < nmsg then refStarts[j + 1] else nrefs
		local slice: any = false
		if re > rs then
			local t = table.create(re - rs)
			table.move(refs, rs + 1, re, 1, t)
			slice = t
		end
		nf += 1
		stageBuf[nf] = frame
		stageRefs[nf] = slice
		stageNRefs[nf] = re - rs
		stageFrom[nf] = i
		stageTo[nf] = j
		i = j + 1
	end

	-- 2. Reset the channel before any fire. The boundary arrays become the spare set, so the retry
	--    path below keeps reading them even if something commits to this player meanwhile.
	ch.starts, ch.spareStarts = ch.spareStarts, starts
	ch.refStarts, ch.spareRefStarts = ch.spareRefStarts, refStarts
	ch.callIds, ch.spareCallIds = ch.spareCallIds, callIds
	ch.nmsg = 0
	resetWriter(cw)
	shrinkIfIdle(ch, total)

	-- 3. Fire each frame.
	local player = ps.player
	for f = 1, nf do
		local frame = stageBuf[f]
		local slice = stageRefs[f]
		stageBuf[f] = nil :: any
		stageRefs[f] = nil
		local sliceRefs: { any }? = if slice then slice else nil
		local ok = pcall(fireReliable, player, frame, sliceRefs)
		if ok then
			framesOut += 1
			bytesOut += buffer.len(frame)
		else
			retryFrame(ps, frame, sliceRefs, stageNRefs[f], starts, refStarts, callIds, stageFrom[f], stageTo[f])
		end
	end
	-- 4. Boundary arrays sized by a burst are not kept for the session (the retry above is done).
	if nmsg > BOUNDARY_KEEP and ch.spareStarts == starts then
		ch.spareStarts = {}
		ch.spareRefStarts = {}
		ch.spareCallIds = {}
	end
end

local function flushUnreliable(ps: PlayerState)
	local ch = ps.uout
	local cw = ch.w
	local total = cw.n
	if total == 0 then
		return
	end
	local nmsg = ch.nmsg
	local starts = ch.starts
	local src = cw.buf
	local nf = 0
	local i = 1
	while i <= nmsg do
		local fs = starts[i]
		local j = i
		while j < nmsg do
			local nextEnd = if j + 1 < nmsg then starts[j + 2] else total
			if nextEnd - fs > UNRELIABLE_SEAL then
				break
			end
			j += 1
		end
		local fe = if j < nmsg then starts[j + 1] else total
		local chunk = buffer.create(fe - fs)
		buffer.copy(chunk, 0, src, fs, fe - fs)
		nf += 1
		stageBuf[nf] = chunk
		i = j + 1
	end
	ch.nmsg = 0
	resetWriter(cw)
	shrinkIfIdle(ch, total)
	if nmsg > BOUNDARY_KEEP then
		ch.starts = {} -- sized by a burst; not kept for the session
	end
	local player = ps.player
	for f = 1, nf do
		local chunk = stageBuf[f]
		stageBuf[f] = nil :: any
		local ok, err = pcall(fireUnreliable :: any, player, chunk)
		if ok then
			framesOut += 1
			bytesOut += buffer.len(chunk)
		else
			fireFailures += 1
			Log.once(
				"s2c-ufire",
				"an unreliable message to uid=" .. uidOf(player) .. " could not be sent: " .. tostring(err)
			)
		end
	end
end

local function flushPlayer(ps: PlayerState)
	local runs = ps.dropRuns[1]
	for r = 1, runs.n do
		appendNotice(ps, NOTICE_FRAME, runs.first[r], runs.count[r])
	end
	runs.n = 0
	runs = ps.dropRuns[2]
	for r = 1, runs.n do
		appendNotice(ps, NOTICE_UFRAME, runs.first[r], runs.count[r])
	end
	runs.n = 0
	flushReliable(ps)
	flushUnreliable(ps)
end

local function flushOne(ps: PlayerState, now: number)
	if ps.helloed then
		flushPlayer(ps)
	elseif not ps.outboxExpired and now - ps.joinedAt > OUTBOX_TTL then
		-- Not helloed: skipped, the channel is the outbox (the client has no manifest yet).
		expire(ps)
	end
end

local function tickAll(now: number)
	for i = 1, #list do
		local ps = list[i]
		Violations.tick(ps.player, ps.viol, now)
	end
end

local function flushBody(now: number)
	-- Swap first: messages committed during this flush land in the next one.
	local d, dn = dirty, dirtyN
	dirty, dirtyN, dirtySpare = dirtySpare, 0, d
	for k = 1, dn do
		local ps = d[k]
		d[k] = nil :: any
		ps.dirty = false
		if not ps.gone then
			local ok, err = pcall(flushOne :: any, ps, now)
			if not ok then
				Log.once("flush-player", "flushing uid=" .. uidOf(ps.player) .. " failed: " .. tostring(err))
			end
		end
	end
	-- Summary lines: once per player per flush.
	local ok, err = pcall(tickAll :: any, now)
	if not ok then
		Log.once("flush-tick", "violation summaries failed: " .. tostring(err))
	end
end

-- One flush of every dirty player (section 3.16 Flush). Never nests.
function Outbox.flushAll(now: number?): ()
	if flushing then
		return
	end
	flushing = true
	local ok, err = pcall(flushBody :: any, now or clock())
	flushing = false
	if not ok then
		Log.once("flush", "flush failed: " .. tostring(err))
	end
end

-- Players ------------------------------------------------------------------------------------------

-- Creates the state of a joining player (idempotent: returns the existing one).
function Outbox.addPlayer(player: Player, now: number): PlayerState
	local existing = states[player]
	if existing then
		return existing
	end
	local ps: PlayerState = {
		player = player,
		helloed = false,
		gone = false,
		joinedAt = now,
		lastHello = 0,
		helloOnly = true,
		out = newChannel(512),
		uout = newChannel(64),
		outboxBytes = 0,
		outboxMsgs = 0,
		outboxDropped = 0,
		outboxExpired = false,
		overflowWarned = false,
		lim = Limits.newPlayer(now),
		viol = Violations.newPlayer(now),
		callTok = {},
		calls = {},
		running = 0,
		queued = 0,
		queue = {},
		zombies = 0,
		routeZombies = {},
		serialActive = {},
		serialQ = {},
		readmit = {},
		draining = false,
		rxSeq = {},
		rxSeqT = {},
		dropRuns = {
			{ first = {}, count = {}, n = 0 },
			{ first = {}, count = {}, n = 0 },
		},
		dirty = false,
		index = #list + 1,
	}
	states[player] = ps
	list[ps.index] = ps
	return ps
end

-- A leaving player: marked gone (late replies are discarded) and removed. Returns its state.
function Outbox.removePlayer(player: Player): PlayerState?
	local ps = states[player]
	if ps == nil then
		return nil
	end
	ps.gone = true
	states[player] = nil
	departedSet[player] = true
	local idx = ps.index
	local last = #list
	local tail = list[last]
	list[idx] = tail
	tail.index = idx
	list[last] = nil
	resetChannel(ps.out)
	resetChannel(ps.uout)
	return ps
end

function Outbox.get(player: any): PlayerState?
	if player == nil then
		return nil
	end
	return states[player]
end

-- A Player in the game whose PlayerAdded has not reached Loren yet (deferred events: a listener
-- connected before the boot runs first and may Fire to it). Online only; the later PlayerAdded finds
-- the same state. nil for a Player who is not (or no longer) in Players, or whose leave Loren has
-- already processed (a later PlayerRemoving listener firing to it would otherwise leak a state).
function Outbox.adopt(player: Player): PlayerState?
	local existing = states[player]
	if existing ~= nil then
		return existing
	end
	if reliableRemote == nil or departedSet[player] or player.Parent ~= PlayersService then
		return nil
	end
	return Outbox.addPlayer(player, clock())
end

-- The live player list (dense, same table for the module's lifetime; do not modify).
function Outbox.players(): { PlayerState }
	return list
end

-- Transport.prepare: the remotes flushes fire on (nil unbinds).
function Outbox.bind(reliable: RemoteEvent?, unreliable: UnreliableRemoteEvent?): ()
	reliableRemote = reliable
	unreliableRemote = unreliable
end

-- Dispatch.configure: Config.InlineTables for every server encode.
function Outbox.configure(inline: boolean): ()
	inlineTables = inline
	scratch.inlineTables = inline
end

-- (FramesOut, BytesOut, MessagesOut, Players, fire failures) for GetStats.
function Outbox.counters(): (number, number, number, number, number)
	return framesOut, bytesOut, messagesOut, #list, fireFailures
end

function Outbox._reset(): ()
	-- States from before the reset may still be referenced by handler threads: gone = no reply.
	for _, ps in list do
		ps.gone = true
	end
	table.clear(states)
	table.clear(departedSet)
	table.clear(list)
	table.clear(dirty)
	table.clear(dirtySpare)
	dirtyN = 0
	flushing = false
	takeScratch()
	scratch.unreliable = false
	inlineTables = true
	scratch.inlineTables = true
	reliableRemote = nil
	unreliableRemote = nil
	capture = nil
	clock = os.clock
	table.clear(hintedLossy)
	table.clear(stageBuf)
	table.clear(stageRefs)
	table.clear(stageNRefs)
	table.clear(stageFrom)
	table.clear(stageTo)
	framesOut = 0
	bytesOut = 0
	messagesOut = 0
	fireFailures = 0
end

Outbox._test = table.freeze({
	-- Replaces FireClient on both remotes: fn(channel "Reliable" | "Unreliable", player, frame, refs?).
	-- A capture that errors makes that fire fail (per-message retry path). nil restores the remotes.
	capture = function(fn: FireCapture?)
		capture = fn
	end,
	-- Replaces os.clock for the outbox TTL (nil restores it).
	setClock = function(fn: (() -> number)?)
		clock = fn or os.clock
	end,
	scratch = function(): Writer
		return scratch
	end,
	inlineTables = function(): boolean
		return inlineTables
	end,
	dirtyCount = function(): number
		return dirtyN
	end,
})

return table.freeze(Outbox)
