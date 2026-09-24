--!strict
--!optimize 2
--[[
	Loren 2.0 shared types. Read-only for every lane (owner: contract).
	Spec: design/loren-2.0/IMPLEMENTATION.md. Returns an empty frozen table; the types are the export.
	Records are uniform: every field is always present (use false, 0 or "" instead of nil where noted).
]]

export type Promise = any -- evaera Promise (ReplicatedStorage.LorenPackages.Promise)

-- Codec -----------------------------------------------------------------------------------------

-- Growable output buffer. Capacity lives in `cap` (buffer.len is not a fastcall).
export type Writer = {
	buf: buffer,
	cap: number,
	n: number, -- bytes written
	refs: { any }, -- sidecar values appended by this writer (1-based, first `nrefs` valid)
	nrefs: number,
	refBase: number, -- C->S: frame index of refs[1] (REF writes varint refBase + i - 1)
	indexedRefs: boolean, -- true: C->S (REF + varint index); false: S->C (REF only, sequential)
	inlineTables: boolean, -- false: every table goes to the sidecar (Config.InlineTables)
	unreliable: boolean, -- true: any value that needs the sidecar fails with Encode.NEEDS_REF
	nodes: number, -- sidecar nodes added (C->S byte-cost mirror and frame cap)
	sideBytes: number, -- string bytes inside sidecar tables
	inlineNodes: number, -- C->S: tagged values written in this message (same rule as ReadCtx.nodes; cap MAX_NODES)
	lossy: number, -- functions/threads/metatables dropped (Studio warns once per route)
	errArg: number, -- argument index of the last encode failure (0 = n/a)
}

-- Decode context, one reused per direction.
export type ReadCtx = {
	refs: { any }?, -- the frame's refs table
	nrefs: number, -- C->S: header nrefs; S->C: unused (0)
	cursor: number, -- S->C: refs consumed so far in this frame
	indexed: boolean, -- true: C->S REF carries a varint index
	hostile: boolean, -- true on the server: finite/depth/node/key/argc rules apply
	allowNonFinite: boolean, -- per route (set before each decode)
	err: number, -- Constants.Decode status (0 = ok); first failure wins
	errArg: number, -- 1-based argument index of the failure (0 = frame-level)
	nodes: number, -- inline tagged values in the current message (map keys excluded)
	-- hostile: elements announced by untyped ARRAY headers in the current message (<= MAX_NODES), so
	-- nested headers cannot all claim the same bytes before an element is read
	claimed: number,
	-- per ref (1-based) from walkSidecar; bit0 = contains a non-finite number; bit1 (hostile) = already
	-- referenced in this frame (an honest encoder gives every reference its own slot)
	refFlags: { number },
}

-- Compiled payload codec (Schema.compile). One per direction per route.
export type PayloadCodec = {
	typed: boolean,
	count: number, -- typed: number of fields; untyped: -1
	maxArgs: number, -- untyped: argc limit (20 C->S, 255 S->C); typed: count
	refs: boolean, -- may place values in the sidecar
	allowNonFinite: boolean,
	-- Appends the payload to w. Returns Constants.Encode status; w.errArg names the argument.
	encode: (w: Writer, n: number, ...any) -> number,
	-- Decodes one payload from b[o, lim). Returns (n, newOffset); sets ctx.err/ctx.errArg on failure.
	-- Writes values into argv[1..n]; the caller clears argv[1..n] after use.
	decode: (b: buffer, o: number, lim: number, ctx: ReadCtx, argv: { any }) -> (number, number),
}

-- Schema ----------------------------------------------------------------------------------------

export type StructField = { name: string, desc: Descriptor }

-- A `Loren.T` type descriptor (frozen; recognized by Schema.isDescriptor).
export type Descriptor = {
	op: number, -- Constants.SchemaOp
	lo: number, -- ints/floats: inclusive lower bound
	hi: number, -- ints/floats: inclusive upper bound; VECTOR3/VECTOR2: max magnitude (math.huge = none)
	max: number, -- STRING/BUFFER: max bytes; ARRAY/MAP: max count; else 0
	flags: number, -- Constants.DescFlag
	inner: Descriptor?, -- OPTIONAL/ARRAY element, MAP value
	key: Descriptor?, -- MAP key
	fields: { StructField }?, -- STRUCT, sorted by name (byte order)
	items: { string }?, -- ENUM names (wire index = position - 1)
	enumName: string?, -- ENUMITEM: name of the Enum (e.g. "Material")
	className: string?, -- INSTANCE: required class ("" = any Instance)
	root: Instance?, -- INSTANCE: server-only root; never serialized
	fixed: number, -- encoded byte size if constant, else -1
	minSize: number, -- minimum encoded bytes, C->S form (INSTANCE = 1); always >= 1
	refs: boolean, -- may use a sidecar slot (INSTANCE, ANY, or containing them)
}

-- Result of Loren.Method / Loren.Event / Loren.Signal (frozen; recognized by Schema.isSpec).
export type MemberSpec = {
	kind: number, -- Constants.Kind
	args: { Descriptor }?, -- nil = untyped
	returns: { Descriptor }?, -- Method only; nil = untyped
	timeout: number?, -- Method: seconds [1, 120]
	rate: number?, -- per-route bucket override
	burst: number?,
	serial: boolean, -- Method
	cancelOnTimeout: boolean?, -- Method; nil = Config.CancelOnTimeout
	unreliable: boolean, -- Event/Signal
	ordered: boolean, -- Event/Signal; requires unreliable
	coalesce: boolean?, -- Event; nil = default (true iff unreliable)
	backlog: number?, -- Signal; nil = Config.Backlog
	allowNonFinite: boolean,
}

-- Manifest --------------------------------------------------------------------------------------

export type ManifestLimits = {
	frameRate: number,
	frameBurst: number,
	byteRate: number,
	byteBurst: number,
	msgRate: number,
	msgBurst: number,
	mirror: number, -- MirrorFraction
	sealC2S: number,
	maxMessageC2S: number,
	unreliableMax: number,
	maxPending: number,
	maxNodes: number,
	maxArgs: number,
	maxRefs: number,
	maxDepth: number,
	flushHz: number,
	backlogWindow: number,
}

export type ManifestMember = {
	name: string,
	kind: number, -- Constants.Kind
	route: number, -- 1..65535
	flags: number, -- Constants.MemberFlag
	timeout: number, -- Method: seconds (manifest stores deciseconds); else 0
	rate: number, -- Method/Event client mirror source; Signal: 0
	burst: number,
	backlog: number, -- Signal; else 0
	args: { Descriptor }?, -- present iff flags has HasArgs
	returns: { Descriptor }?, -- present iff flags has HasReturns
}

export type ManifestService = { name: string, members: { ManifestMember } } -- members sorted by (name, kind)
export type ManifestModel = {
	proto: number,
	version: string,
	limits: ManifestLimits,
	services: { ManifestService }, -- sorted by name; networked services only
}

-- Registration ----------------------------------------------------------------------------------

export type ModuleRecord = {
	name: string, -- ModuleScript.Name (registry key)
	kind: string, -- "Service" | "Controller"
	module: any, -- the table the ModuleScript returned
	instance: Instance, -- the ModuleScript
	path: string, -- instance:GetFullName()
	deps: { string }, -- declared Dependencies names (validated copy, declaration order)
}

export type MemberDecl = {
	name: string,
	kind: number, -- Constants.Kind
	fn: ((...any) -> ...any)?, -- Method: module.Client[name]
	middleware: ((...any) -> ...any)?, -- module.Middleware[name]
	colon: boolean, -- middleware flagged colon-style: every call is denied (fail closed)
	spec: MemberSpec?, -- module.Spec[name]
}

export type ServiceDecl = {
	name: string,
	record: ModuleRecord,
	module: any,
	client: any, -- module.Client table, or false
	members: { MemberDecl }, -- network members only, sorted by (name, kind); a Signal may share a name
	networked: boolean, -- #members > 0
}

export type Report = {
	side: string, -- "Server" | "Client"
	errors: { string },
	warnings: { string },
}

-- Signals ---------------------------------------------------------------------------------------

-- Disconnect/Destroy are per-connection closures: conn.Disconnect() and conn:Disconnect() both work.
export type Connection = {
	Connected: boolean,
	Disconnect: (...any) -> (),
	Destroy: (...any) -> (),
}

export type LocalSignal = {
	Fire: (self: LocalSignal, ...any) -> (),
	Connect: (self: LocalSignal, fn: (...any) -> ()) -> Connection,
	Once: (self: LocalSignal, fn: (...any) -> ()) -> Connection,
	Wait: (self: LocalSignal) -> ...any,
	DisconnectAll: (self: LocalSignal) -> (),
	Destroy: (self: LocalSignal) -> (),
}

-- proxy.Signals.X (client). Fire/FireAll/FireFor/FireExcept exist and raise an error.
export type ClientSignal = {
	Connect: (self: ClientSignal, fn: (...any) -> ()) -> Connection,
	Once: (self: ClientSignal, fn: (...any) -> ()) -> Connection,
	Wait: (self: ClientSignal) -> ...any,
	DisconnectAll: (self: ClientSignal) -> (),
}

-- Service.Signals.X (server). Connect/Once/Wait exist and raise an error.
export type ServerSignal = {
	Fire: (self: ServerSignal, player: Player, ...any) -> (),
	FireAll: (self: ServerSignal, ...any) -> (),
	FireFor: (self: ServerSignal, players: { Player }, ...any) -> (),
	FireExcept: (self: ServerSignal, except: Player | { Player }, ...any) -> (),
}

-- Service.ClientEvents.X (server). Fire raises an error.
export type ServerEvent = {
	Connect: (self: ServerEvent, fn: (player: Player, ...any) -> ()) -> Connection,
	Once: (self: ServerEvent, fn: (player: Player, ...any) -> ()) -> Connection,
	Wait: (self: ServerEvent) -> ...any,
	DisconnectAll: (self: ServerEvent) -> (),
}

-- proxy.ClientEvents.X (client). Connect raises an error.
export type ClientEvent = {
	Fire: (self: ClientEvent, ...any) -> (),
}

-- Client proxy for a networked Service: methods are fields; unknown keys raise an error.
export type ServiceProxy = {
	Signals: { [string]: ClientSignal },
	ClientEvents: { [string]: ClientEvent },
	Try: { [string]: any }, -- proxy.Try:Method(...) -> (ok, ...)
	[string]: any,
}

-- Errors ----------------------------------------------------------------------------------------

-- Second value of every Loren rejection (frozen).
export type ErrorInfo = {
	Code: string, -- Constants.ErrName value, e.g. "Timeout"
	CodeId: number, -- Constants.Err value
	Message: string, -- same string as the first rejection value
	Service: string,
	Member: string,
	Incident: string?, -- 8 lowercase hex digits (InternalError, BadResult)
	Arg: number?, -- BadRequest / BadArgument argument index
	Data: any, -- Loren.Reject data
}

export type RejectSentinel = {
	Message: string,
	Data: any,
}

-- Config ----------------------------------------------------------------------------------------

export type MemberOverride = {
	RateLimit: { number }?, -- { rate, burst }
	Timeout: number?,
	Serial: boolean?,
	CancelOnTimeout: boolean?,
	AllowNonFinite: boolean?,
}

-- Resolved configuration (Config.get()); keys match Constants.Default plus Members.
export type Config = {
	FrameRate: number,
	FrameBurst: number,
	ByteRate: number,
	ByteBurst: number,
	MessageRate: number,
	MessageBurst: number,
	MethodRate: number,
	MethodBurst: number,
	EventRate: number,
	EventBurst: number,
	UnreliableEventRate: number,
	UnreliableEventBurst: number,
	MirrorFraction: number,
	MaxRunningCalls: number,
	MaxQueuedCalls: number,
	MaxZombies: number,
	MaxZombiesPerRoute: number,
	SerialQueue: number,
	MaxPending: number,
	DefaultTimeout: number,
	WatchdogGrace: number,
	CancelOnTimeout: boolean,
	Backlog: number,
	BacklogWindow: number,
	ForwardErrors: string,
	StrictCycles: boolean,
	InlineTables: boolean,
	MiddlewareArityCheck: boolean,
	KickScore: number | false,
	IgniteTimeout: number | false,
	PromiseTraces: string,
	Members: { [string]: MemberOverride },
}

-- Stats (Loren.GetStats(); fields that do not apply to a side are 0) -----------------------------

export type Stats = {
	Side: string, -- "Server" | "Client"
	FramesIn: number,
	FramesOut: number,
	BytesIn: number,
	BytesOut: number,
	MessagesIn: number,
	MessagesOut: number,
	FramesDropped: number, -- server: refused at admission; client: reported by NOTICE
	EventsLost: number, -- client: events in dropped frames + mirror-refused events
	CallsRateLimited: number,
	BadRequests: number,
	Busy: number,
	Violations: number,
	LateReplies: number,
	OutboxDropped: number,
	SignalsDropped: number, -- missing Instance, unreliable before HELLO, backlog overflow
	RunningCalls: number,
	ZombieCalls: number,
	PendingCalls: number,
	Players: number,
	Routes: number,
}

-- Public facade -----------------------------------------------------------------------------------

-- Every function accepts the dot and the colon form at runtime (a leading Loren argument is dropped).
-- Functions with parameters are typed (...any) so both forms check on both type solvers. Exception: Get is
-- generic so Loren.Get(require(m)) keeps the module type; Loren:Get(m) runs but does not type-check.
export type Loren = {
	IsServer: boolean,
	IsClient: boolean,
	IsOnFire: boolean,
	IsReady: boolean,
	State: string,
	Version: string,
	Errors: { [string]: string },
	T: any,
	Testing: {
		Mount: (...any) -> any,
		Reset: (...any) -> (),
		Fired: (...any) -> { any },
		Emit: (...any) -> (),
	},
	AddServices: (...any) -> (),
	AddControllers: (...any) -> (),
	SetOnFire: (self: any?) -> Promise,
	OnReady: (self: any?) -> Promise,
	GetService: (...any) -> any,
	GetController: (...any) -> any,
	Get: <T>(module: T) -> T,
	Configure: (...any) -> (),
	AddMiddleware: (...any) -> (),
	OnViolation: (...any) -> (),
	OnError: (...any) -> (),
	Flush: (self: any?) -> (),
	GetStats: (self: any?) -> Stats,
	DumpManifest: (self: any?) -> ManifestModel,
	Reject: (...any) -> RejectSentinel,
	Method: (...any) -> any,
	Event: (...any) -> any,
	Signal: (...any) -> any,
}

return table.freeze({})
