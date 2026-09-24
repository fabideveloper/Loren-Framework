--!strict
--!optimize 2
--[[
	Loren 2.0 constants: wire bytes, error codes, decode/encode statuses, violation kinds and
	default limits. Read-only for every lane (owner: contract). Spec: design/loren-2.0/IMPLEMENTATION.md.
	Every nested table is frozen; the module has no side effects.
]]

local freeze = table.freeze

local C = {}

-- Protocol and names ---------------------------------------------------------------------------

C.PROTO = 2 -- HELLO proto byte and MANIFEST proto byte (1.5.1 is implicitly 1)
C.PREFIX = "(LORENঌ) " -- every Loren log line, error and rejection string starts with this

C.Names = freeze({
	RuntimeFolder = "LorenRuntime", -- ReplicatedStorage.LorenRuntime (shared runtime)
	ServerFolder = "LorenServer", -- ServerScriptService.LorenServer (server runtime)
	Packages = "LorenPackages", -- ReplicatedStorage.LorenPackages (Promise)
	NetFolder = "LorenNet", -- ReplicatedStorage.LorenNet (Folder, created by the server boot)
	Reliable = "Reliable", -- LorenNet.Reliable (RemoteEvent)
	Unreliable = "Unreliable", -- LorenNet.Unreliable (UnreliableRemoteEvent)
	StateAttr = "State", -- LorenNet attribute: one of C.NetState
	ProtoAttr = "Proto", -- LorenNet attribute: C.PROTO (number)
	MemoryCategory = "Loren",
})

-- LorenNet.State attribute values (what clients see)
C.NetState = freeze({
	Booting = "Booting",
	Ready = "Ready",
	Failed = "Failed",
	ShuttingDown = "ShuttingDown",
})

-- Loren.State values (facade)
C.State = freeze({
	Idle = "Idle",
	Booting = "Booting",
	Ready = "Ready",
	Failed = "Failed",
	ShuttingDown = "ShuttingDown",
})

-- Frames and heads -----------------------------------------------------------------------------

-- C->S frame header: seq:u16 nmsg:u16 nrefs:u8 (little-endian), then nmsg x (len:varint, head, body)
C.C2S_HEADER = 5
C.OFF_SEQ = 0
C.OFF_NMSG = 2
C.OFF_NREFS = 4

-- Route head byte ranges
C.Head = freeze({
	Invalid = 0x00, -- never valid
	Route1Max = 0xDF, -- 0x01..0xDF: route = byte (1..223)
	Route2Min = 0xE0, -- 0xE0..0xEE lo:u8: route = 224 + (byte - 0xE0) * 256 + lo (224..4063)
	Route2Max = 0xEE,
	Route3 = 0xEF, -- 0xEF u16: route = u16 (writer uses it for 4064..65535)
	ControlMin = 0xF0, -- 0xF0..0xFF: control op (0xF5..0xFF reserved)
})
C.ROUTE1_MAX = 223
C.ROUTE2_BASE = 224
C.ROUTE2_MAX = 4063
C.ROUTE_MAX = 65535

-- Control ops (head byte)
C.Op = freeze({
	HELLO = 0xF0, -- C->S: proto:u8
	MANIFEST = 0xF1, -- S->C: len:u32, manifest bytes
	OK = 0xF2, -- S->C: callId:u16, returns payload
	ERR = 0xF3, -- S->C: callId:u16 code:u8 flags:u8 [msg] [data] [incident:u32]
	NOTICE = 0xF4, -- S->C: kind:u8 first:u16 count:u16
})

-- NOTICE kinds
C.Notice = freeze({
	FrameDropped = 1, -- reliable C->S frames refused at admission: seqs first..first+count-1 (wrapping)
	UFrameDropped = 2, -- same, unreliable channel
	ShuttingDown = 3, -- first = 0, count = 0
	OutboxOverflow = 4, -- first = 0, count = messages dropped before HELLO (capped 65535)
})

-- ERR presence flags (other bits must be 0)
C.ErrFlag = freeze({
	Msg = 0x01, -- varint len (<= 256) + bytes
	Data = 0x02, -- one untyped tagged value
	Incident = 0x04, -- u32
})

-- Members and manifest -------------------------------------------------------------------------

C.Kind = freeze({
	Method = 1, -- C->S CALL, S->C OK/ERR
	Event = 2, -- C->S ClientEvent
	Signal = 3, -- S->C Signal
	-- 4 reserved (Properties, 2.1)
})

-- Manifest member flags byte
C.MemberFlag = freeze({
	Unreliable = 0x01,
	Ordered = 0x02,
	Coalesce = 0x04,
	AllowNonFinite = 0x08,
	HasArgs = 0x10,
	HasReturns = 0x20,
	Serial = 0x40,
	-- 0x80 reserved (0)
})

C.BACKLOG_LATEST = 0xFFFF -- reserved manifest value; 2.0 never writes it (Backlog = 1 keeps the latest)

-- Untyped value tags ---------------------------------------------------------------------------

C.Tag = freeze({
	NIL = 0x00,
	FALSE = 0x01,
	TRUE = 0x02,
	U8 = 0x03, -- integer 0..255 (fixint covers 0..127)
	U16 = 0x04,
	U32 = 0x05,
	NU8 = 0x06, -- negative integer, magnitude u8
	NU16 = 0x07,
	NU32 = 0x08,
	F64 = 0x09, -- any other number: fractions, -0, NaN, +-inf, |v| > 2^32-1
	STR32 = 0x0A, -- u32 len + bytes (only when len > VARINT_MAX)
	STR = 0x0B, -- varint len + bytes
	BUF = 0x0C, -- varint len + bytes
	VEC3 = 0x0D, -- 3 x f32
	VEC2 = 0x0E, -- 2 x f32
	COLOR3 = 0x0F, -- 3 x f32
	ARRAY = 0x10, -- varint n + n values (plain array, no holes)
	MAP = 0x11, -- varint n + n (STR key, value) pairs (string keys only)
	REF = 0x12, -- sidecar value; C->S: + varint frame index; S->C: no bytes (next ref)
	BUF32 = 0x13, -- u32 len + bytes (only when len > VARINT_MAX)
	LastTag = 0x13, -- 0x14..0x7F are invalid (BAD_TAG)
	FixintBase = 0x80, -- 0x80..0xFF: integer (tag - 0x80), 0..127 (never -0)
})

-- Schema descriptor ops (manifest descriptor byte; see IMPLEMENTATION.md section 4.7)
C.SchemaOp = freeze({
	BOOL = 1,
	U8 = 2,
	U16 = 3,
	U32 = 4,
	I8 = 5,
	I16 = 6,
	I32 = 7,
	F32 = 8,
	F64 = 9,
	STRING = 10,
	BUFFER = 11,
	VECTOR3 = 12,
	VECTOR2 = 13,
	COLOR3 = 14,
	CFRAME = 15,
	ENUM = 16,
	ENUMITEM = 17,
	INSTANCE = 18,
	OPTIONAL = 19,
	ARRAY = 20,
	MAP = 21,
	STRUCT = 22,
	ANY = 23,
})

-- Descriptor flags
C.DescFlag = freeze({
	Binary = 0x01, -- STRING: skip the UTF-8 check
	Nilable = 0x01, -- INSTANCE: directly under OPTIONAL, a nil arrival is accepted
})

-- Errors ---------------------------------------------------------------------------------------

-- Wire codes 1..8 travel in ERR; 16.. are client-local only.
C.Err = freeze({
	Rejected = 1,
	Denied = 2,
	BadRequest = 3,
	RateLimited = 4,
	Busy = 5,
	InternalError = 6,
	BadResult = 7,
	ShuttingDown = 8,
	-- local (never on the wire)
	Timeout = 16,
	TooManyInFlight = 17,
	PayloadTooLarge = 18,
	BadArgument = 19,
	NotReady = 20,
	BootFailed = 21,
	MissingInstance = 22,
})
C.WIRE_ERR_MAX = 8

C.ErrName = freeze({
	[1] = "Rejected",
	[2] = "Denied",
	[3] = "BadRequest",
	[4] = "RateLimited",
	[5] = "Busy",
	[6] = "InternalError",
	[7] = "BadResult",
	[8] = "ShuttingDown",
	[16] = "Timeout",
	[17] = "TooManyInFlight",
	[18] = "PayloadTooLarge",
	[19] = "BadArgument",
	[20] = "NotReady",
	[21] = "BootFailed",
	[22] = "MissingInstance",
})

-- Fixed rejection strings. Rejected = msg verbatim; Denied = middleware msg or Msg.Denied (1.5.1 text).
C.Msg = freeze({
	Timeout = "(LORENঌ) Timeout", -- exact 1.5.1 string
	Denied = "Denied", -- exact 1.5.1 string
	BadRequest = "(LORENঌ) BadRequest",
	RateLimited = "(LORENঌ) RateLimited",
	Busy = "(LORENঌ) Busy",
	InternalError = "(LORENঌ) InternalError",
	BadResult = "(LORENঌ) BadResult",
	ShuttingDown = "(LORENঌ) ShuttingDown",
	TooManyInFlight = "(LORENঌ) TooManyInFlight",
	PayloadTooLarge = "(LORENঌ) PayloadTooLarge",
	BadArgument = "(LORENঌ) BadArgument",
	NotReady = "(LORENঌ) NotReady",
	BootFailed = "(LORENঌ) BootFailed",
	MissingInstance = "(LORENঌ) MissingInstance",
})

-- Decode statuses: 0 ok; 1..31 structural (violation, abort the frame); 32.. semantic (BadRequest / drop)
C.Decode = freeze({
	OK = 0,
	OVERRUN = 1, -- read past the message/frame end, or a count larger than the bytes left
	BAD_TAG = 2, -- unknown tag, bad bool byte, non-STR map key, NIL inside an inline array/map
	BAD_VARINT = 3, -- truncated or longer than 3 bytes
	BAD_REF = 4, -- ref index >= nrefs, refs missing, or a sidecar entry of a type honest encoders never send
	TRAILING = 5, -- decoder stopped before the message end
	BAD_PRESENCE = 6, -- OPTIONAL presence byte not 0/1
	-- semantic
	NONFINITE = 32,
	RANGE = 33,
	TOO_DEEP = 34,
	TOO_MANY_NODES = 35,
	BAD_KEY = 36, -- sidecar table key not string/boolean/finite number
	TOO_MANY_ARGS = 37,
	TOO_LONG = 38, -- string/buffer/array/map over the declared max
	BAD_UTF8 = 39,
	BAD_ENUM = 40,
	BAD_TYPE = 41, -- sidecar value of the wrong type for a typed field
	BAD_INSTANCE = 42, -- wrong class or outside the server-only root
	MISSING_INSTANCE = 43, -- non-optional Instance arrived nil
})
C.DECODE_SEMANTIC_MIN = 32

-- Reason names sent in ERR BadRequest msg and used in Studio warnings
C.DecodeName = freeze({
	[1] = "Overrun",
	[2] = "BadTag",
	[3] = "BadVarint",
	[4] = "BadRef",
	[5] = "Trailing",
	[6] = "BadPresence",
	[32] = "NonFinite",
	[33] = "Range",
	[34] = "TooDeep",
	[35] = "TooManyNodes",
	[36] = "BadKey",
	[37] = "TooManyArgs",
	[38] = "TooLong",
	[39] = "BadUtf8",
	[40] = "BadEnum",
	[41] = "BadType",
	[42] = "BadInstance",
	[43] = "MissingInstance",
})

-- Encode statuses (sender side; never cross the wire)
C.Encode = freeze({
	OK = 0,
	TOO_DEEP = 1, -- nesting > MAX_DEPTH
	CYCLE = 2,
	TOO_MANY_ARGS = 3,
	NEEDS_REF = 4, -- a value needs the sidecar on an unreliable route
	BAD_TYPE = 5, -- typed field got the wrong Lua type
	RANGE = 6,
	NONFINITE = 7,
	TOO_LONG = 8, -- over a declared max, or a count > VARINT_MAX
	TOO_MANY_NODES = 9, -- C->S only: inline values per message or sidecar nodes > MAX_NODES
	MISSING = 10, -- nil for a non-optional typed field
	BAD_UTF8 = 11,
	TOO_MANY_VALUES = 12, -- more values than a typed codec declares
	BAD_KEY = 13, -- C->S sidecar table key that is not a string, boolean or finite number
})

C.EncodeName = freeze({
	[1] = "TooDeep",
	[2] = "Cycle",
	[3] = "TooManyArgs",
	[4] = "NeedsRef",
	[5] = "BadType",
	[6] = "Range",
	[7] = "NonFinite",
	[8] = "TooLong",
	[9] = "TooManyNodes",
	[10] = "Missing",
	[11] = "BadUtf8",
	[12] = "TooManyValues",
	[13] = "BadKey",
})

-- Violations (modified-client evidence; never replied to) ---------------------------------------

C.Violation = freeze({
	Envelope = 1, -- frame not a buffer, refs of the wrong type
	ExtraArgs = 2, -- more remote arguments than (frame, refs)
	FrameSize = 3, -- len < 5 or > 72 KiB (reliable) / > 1000 B (unreliable)
	Refs = 4, -- refs present iff nrefs > 0 violated; refs on the unreliable channel
	Framing = 5, -- nmsg 0 or > MAX_MSGS_PER_FRAME, bad message len, bad head, leftover bytes, HELLO not alone
	BadOp = 6, -- S->C control op or reserved op from a client, or HELLO with a wrong proto
	Route = 7, -- unknown route, S->C route, wrong channel for the route
	BeforeHello = 8, -- a route message before HELLO
	RepeatHello = 9, -- HELLO again within REHELLO_MIN seconds of the last accepted one, after other messages
	DuplicateCall = 10, -- callId 0, or a callId that is still live
	Payload = 11, -- structural decode failure (C.Decode 1..31)
	Sidecar = 12, -- sidecar entry is a buffer/function/thread, or a walk structure error
})

C.ViolationName = freeze({
	[1] = "Envelope",
	[2] = "ExtraArgs",
	[3] = "FrameSize",
	[4] = "Refs",
	[5] = "Framing",
	[6] = "BadOp",
	[7] = "Route",
	[8] = "BeforeHello",
	[9] = "RepeatHello",
	[10] = "DuplicateCall",
	[11] = "Payload",
	[12] = "Sidecar",
})

C.ViolationWeight = freeze({
	[1] = 10,
	[2] = 10,
	[3] = 10,
	[4] = 10,
	[5] = 10,
	[6] = 10,
	[7] = 5,
	[8] = 5,
	[9] = 5,
	[10] = 5,
	[11] = 2,
	[12] = 2,
})

-- Per-player drop counters (summary logs and GetStats; not violations)
C.Drop = freeze({
	FrameDropped = 1, -- frames refused at admission (either channel)
	RateLimited = 2, -- calls refused by a route bucket
	BadRequest = 3, -- calls with semantic decode failures
	Busy = 4,
	EventLimited = 5, -- events refused by a route bucket
	EventBad = 6, -- events with semantic decode failures
	EventDenied = 7, -- events denied by middleware
	Stale = 8, -- Ordered unreliable events older than the last seen
	OutboxOverflow = 9,
	OutboxExpired = 10,
	UnreliableEarly = 11, -- unreliable S->C before HELLO
	RepliesSuppressed = 12, -- RateLimited/BadRequest replies over their caps
	Departed = 13, -- Fire to a player who left (global counter; no player state)
})

C.DropName = freeze({
	[1] = "FrameDropped",
	[2] = "RateLimited",
	[3] = "BadRequest",
	[4] = "Busy",
	[5] = "EventLimited",
	[6] = "EventBad",
	[7] = "EventDenied",
	[8] = "Stale",
	[9] = "OutboxOverflow",
	[10] = "OutboxExpired",
	[11] = "UnreliableEarly",
	[12] = "RepliesSuppressed",
	[13] = "Departed",
})
C.DROP_KINDS = 13

-- Fixed protocol limits (not configurable) ------------------------------------------------------

C.Limit = freeze({
	VARINT_MAX = 2097151, -- 3-byte LEB128 max
	VARINT_MAX_BYTES = 3,
	C2S_SEAL = 16384, -- client seals a reliable frame before its weight (bytes + 8/node + sidecar strings) passes this
	C2S_MAX_MESSAGE = 65536, -- one message's weight (head + body + sidecar cost); larger = PayloadTooLarge
	C2S_MAX_FRAME = 73728, -- server envelope bound, reliable (72 KiB)
	S2C_SEAL = 65536, -- server seals a reliable frame; a larger message goes alone
	UNRELIABLE_SEAL = 900, -- per fire, both directions (C->S includes the 5 B header)
	UNRELIABLE_MAX_FRAME = 1000, -- server envelope bound, unreliable
	MIN_FRAME = 5,
	MAX_MSGS_PER_FRAME = 1024, -- client seals at this count; more = Framing violation
	MAX_REFS = 255, -- nrefs is a u8
	MAX_ARGS_C2S = 20, -- untyped argc from clients (real count)
	MAX_ARGS_S2C = 255, -- untyped argc server -> client
	MAX_TYPED_FIELDS = 32, -- typed Args/Returns per member
	MAX_DEPTH = 16, -- untyped nesting (inline and sidecar walks separately)
	MAX_NODES = 2048, -- untyped inline values per message (map keys excluded); sidecar nodes per C->S frame
	MAX_DESC_DEPTH = 16, -- schema descriptor nesting
	MAX_NAME = 255, -- service/member/field name bytes
	ERR_MSG_MAX = 256, -- ERR msg bytes (longer messages are truncated)
	MIN_CHARGE = 64, -- byte cost floor per frame
	REF_CHARGE = 16, -- byte cost per ref
	NODE_CHARGE = 8, -- byte cost per sidecar node (+ string bytes)
	FLUSH_HZ = 61, -- client flush credits per second
	OUTBOX_BYTES = 262144, -- pre-HELLO reliable outbox per player
	OUTBOX_MSGS = 4096,
	OUTBOX_TTL = 120, -- seconds after join
	REHELLO_MIN = 5, -- seconds between accepted HELLOs from one player
	NOTICE_RUNS_MAX = 8, -- FrameDropped runs reported per channel per flush
	FRAME_RING = 256, -- client: recent fired frames per channel (seq, event count) for NOTICE matching
	ORDERED_RESET = 1, -- seconds of silence that reset an Ordered receiver
	BACKLOG_MAX = 1024, -- per-signal Backlog upper bound
	SWEEP_INTERVAL = 0.1, -- client pending-call sweeper
	WATCHDOG_INTERVAL = 0.25, -- server watchdog sweep
	QUARANTINE_AFTER_CANCEL = 60,
	-- quarantine until max(cancel + 60, send + timeout + 40): past the server's last possible reply
	-- (receipt + timeout + WatchdogGrace, grace <= WATCHDOG_GRACE_MAX) with 10 s left for latency
	QUARANTINE_AFTER_DEADLINE = 40,
	WATCHDOG_GRACE_MAX = 30, -- WatchdogGrace upper bound (Configure)
	QUEUE_MAX = 1024, -- MaxQueuedCalls and SerialQueue upper bound (Configure)
	TIMEOUT_MIN = 1,
	TIMEOUT_MAX = 120,
	SHUTDOWN_BUDGET = 25,
	WAIT_WARN_NET = 60, -- client: warn if LorenNet/Ready is not seen (keeps waiting)
	WAIT_WARN_MANIFEST = 30, -- client: warn if MANIFEST is not seen (keeps waiting)
	IGNITE_WARN = 30, -- seconds before a second "still waiting" warning for a yielding Ignite
	SUMMARY_INTERVAL = 30, -- per-player drop summary
	LOG_LINES_PER_MIN = 10, -- global Loren warning budget
	RL_REPLY_INTERVAL = 1, -- RateLimited replies: 1 per route per player per second
	BR_REPLY_RATE = 16, -- BadRequest replies per player per second (burst 16)
	ON_VIOLATION_INTERVAL = 1, -- OnViolation at most once per player per second
	ON_ERROR_RATE = 10, -- OnError calls per second
	HANDLER_LOG_INTERVAL = 10, -- full handler error log once per route per 10 s
	SCORE_DECAY = 1, -- violation score points removed per second
	F32_MAX = 3.4028234663852886e38,
	F64_MAX = 1.7976931348623157e308,
	DEFAULT_STRING_MAX = 1024,
	DEFAULT_BUFFER_MAX = 1024,
	DEFAULT_COUNT_MAX = 1024,
})

-- Client method names that cannot be networked (warning; the member is skipped)
C.ReservedClientNames = freeze({
	Server = true,
	Signals = true,
	ClientEvents = true,
	Properties = true,
	Try = true,
})

-- Configurable defaults (Loren.Configure keys; see IMPLEMENTATION.md section 6) ------------------

C.Default = freeze({
	-- server limits (clients mirror them at MirrorFraction)
	FrameRate = 120, -- per channel per player
	FrameBurst = 140,
	ByteRate = 131072, -- per player, both channels
	ByteBurst = 262144,
	MessageRate = 600, -- per player, charged nmsg at admission
	MessageBurst = 600,
	MethodRate = 50, -- per route per player
	MethodBurst = 100,
	EventRate = 75, -- reliable ClientEvents, per route per player
	EventBurst = 150,
	UnreliableEventRate = 120,
	UnreliableEventBurst = 60,
	MirrorFraction = 0.9,
	-- dispatch caps (per player)
	MaxRunningCalls = 32,
	MaxQueuedCalls = 64,
	MaxZombies = 16,
	MaxZombiesPerRoute = 4,
	SerialQueue = 8, -- per player per Serial route
	-- client
	MaxPending = 256,
	-- calls
	DefaultTimeout = 10,
	WatchdogGrace = 5,
	CancelOnTimeout = false,
	-- signals
	Backlog = 64,
	BacklogWindow = 10,
	-- policies
	ForwardErrors = "Studio", -- "Studio" | "Never" | "Always"
	StrictCycles = false,
	InlineTables = true,
	MiddlewareArityCheck = true,
	KickScore = false :: number | false,
	IgniteTimeout = false :: number | false, -- seconds; when set, a longer Ignite fails the boot
	PromiseTraces = "Studio", -- "Studio" | "Always" | "Never"
})

return freeze(C)
