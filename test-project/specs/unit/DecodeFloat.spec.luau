--!strict
-- Every special f32 and f64 bit pattern in every float slot of every decode fast path, bit for bit against frozen v2.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local FrozenV2 = ServerStorage.LorenTest.Frozen.v2
local ServerRuntime = ServerScriptService.LorenServer

local Loren = require(Runtime) :: any
local ClientNet = require(Runtime.ClientNet) :: any
local Calls = require(Runtime.Calls) :: any
local Proxy = require(Runtime.Proxy) :: any
local Config = require(Runtime.Config) :: any
local Log = require(Runtime.Log) :: any
local Routes = require(ServerRuntime.Routes) :: any
local Transport = require(ServerRuntime.Transport) :: any
local Outbox = require(ServerRuntime.Outbox) :: any
local Dispatch = require(ServerRuntime.Dispatch) :: any
local ServerSignal = require(ServerRuntime.ServerSignal) :: any
local Limits = require(ServerRuntime.Limits) :: any
local Violations = require(ServerRuntime.Violations) :: any

type Side = { name: string, C: any, Codec: any, Schema: any }
type Shape = { [string]: any }
type Case = { name: string, args: { Shape } }
type Group = { label: string, width: number, lo: number, hi: number, names: { string }? }
type Slot = { at: number, width: number, label: string }
type Marks = { groups: { Group }, n: number }
type Pattern = { label: string, width: number, lo: number, hi: number }
type Checker = { mismatches: { string }, count: number }

local NOW: Side = {
	name = "runtime",
	C = require(Runtime.Constants) :: any,
	Codec = require(Runtime.Codec) :: any,
	Schema = require(Runtime.Schema) :: any,
}
local OLD: Side = {
	name = "frozen v2",
	C = require(FrozenV2.Constants) :: any,
	Codec = require(FrozenV2.Codec) :: any,
	Schema = require(FrozenV2.Schema) :: any,
}

local C = NOW.C
local Codec = NOW.Codec
local MAX_C2S = C.Limit.MAX_ARGS_C2S
local MAX_S2C = C.Limit.MAX_ARGS_S2C
local SEMANTIC_MIN = C.DECODE_SEMANTIC_MIN
local DROP_EVENT_BAD = C.Drop.EventBad
local SVC = "DecodeFloat"
local YIELD_AFTER = 0.05 -- seconds of work between yields (Studio stops a script that never yields)
local CONTEXT = 48 -- characters shown before the first difference of two texts
local TAIL = 160 -- characters shown from there on

-- f32 bit patterns: zeros, subnormals, normals at the edges, infinities, signalling and quiet NaNs (sign and payload)
local F32_BITS: { { any } } = {
	{ 0x00000000, "+0" },
	{ 0x80000000, "-0" },
	{ 0x00000001, "the smallest subnormal" },
	{ 0x80000001, "minus the smallest subnormal" },
	{ 0x00000002, "a subnormal" },
	{ 0x00012345, "a subnormal" },
	{ 0x00400000, "half the smallest normal" },
	{ 0x80400000, "minus half the smallest normal" },
	{ 0x007FFFFF, "the largest subnormal" },
	{ 0x807FFFFF, "minus the largest subnormal" },
	{ 0x00800000, "the smallest normal" },
	{ 0x80800000, "minus the smallest normal" },
	{ 0x00800001, "just above the smallest normal" },
	{ 0x3F800000, "1" },
	{ 0xBF800000, "-1" },
	{ 0x3EAAAAAB, "1/3" },
	{ 0x4B7FFFFF, "16777215" },
	{ 0x7F7FFFFF, "the largest normal" },
	{ 0xFF7FFFFF, "minus the largest normal" },
	{ 0x7F800000, "inf" },
	{ 0xFF800000, "-inf" },
	{ 0x7F800001, "a signalling NaN" },
	{ 0xFF800001, "a negative signalling NaN" },
	{ 0x7FBFFFFF, "the largest signalling NaN" },
	{ 0xFFBFFFFF, "the largest negative signalling NaN" },
	{ 0x7FC00000, "the quiet NaN" },
	{ 0xFFC00000, "the negative quiet NaN" },
	{ 0x7FC00001, "a quiet NaN with a payload" },
	{ 0x7FD55555, "a quiet NaN with a payload" },
	{ 0x7FFFFFFF, "the largest quiet NaN" },
	{ 0xFFFFFFFF, "the largest negative quiet NaN" },
}
-- f64 bit patterns as { low word, high word, name }
local F64_BITS: { { any } } = {
	{ 0, 0, "+0" },
	{ 0, 0x80000000, "-0" },
	{ 1, 0, "the smallest subnormal" },
	{ 1, 0x80000000, "minus the smallest subnormal" },
	{ 0xFFFFFFFF, 0x000FFFFF, "the largest subnormal" },
	{ 0, 0x00100000, "the smallest normal" },
	{ 0, 0x36A00000, "2^-149 (the smallest f32 subnormal)" },
	{ 0, 0xB6A00000, "-2^-149" },
	{ 0, 0x38100000, "2^-126 (the smallest f32 normal)" },
	{ 0, 0x3FF00000, "1" },
	{ 0xFFFFFFFF, 0x7FEFFFFF, "the largest normal" },
	{ 0xFFFFFFFF, 0xFFEFFFFF, "minus the largest normal" },
	{ 0, 0x7FF00000, "inf" },
	{ 0, 0xFFF00000, "-inf" },
	{ 1, 0x7FF00000, "a signalling NaN" },
	{ 0, 0x7FF40000, "a signalling NaN" },
	{ 0, 0x7FF80000, "the quiet NaN" },
	{ 0, 0xFFF80000, "the negative quiet NaN" },
	{ 0x12345678, 0x7FF9ABCD, "a quiet NaN with a payload" },
	{ 0xFFFFFFFF, 0x7FFFFFFF, "the largest quiet NaN" },
	{ 0xFFFFFFFF, 0xFFFFFFFF, "the largest negative quiet NaN" },
}

local F32_PATTERNS: { Pattern } = {}
for _, e in F32_BITS do
	table.insert(F32_PATTERNS, { label = string.format("%08x (%s)", e[1], e[2]), width = 4, lo = e[1], hi = 0 })
end
local F64_PATTERNS: { Pattern } = {}
for _, e in F64_BITS do
	local label = string.format("%08x%08x (%s)", e[2], e[1], e[3])
	table.insert(F64_PATTERNS, { label = label, width = 8, lo = e[1], hi = e[2] })
end

local function patternsFor(width: number): { Pattern }
	return if width == 4 then F32_PATTERNS else F64_PATTERNS
end

local function noop(...: any) end

-- Exact texts: every number as its f64 bits (NaN sign and payload, -0 and subnormals kept) ----------------

local scratch = buffer.create(8)

local function bits(x: number): string
	buffer.writef64(scratch, 0, x)
	return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
end

local function exact(x: any, depth: number?): string
	local d = depth or 0
	if d > 32 then
		return "<too deep>"
	end
	local t = typeof(x)
	if t == "number" then
		return bits(x)
	elseif t == "Vector3" then
		return string.format("V3(%s,%s,%s)", bits(x.X), bits(x.Y), bits(x.Z))
	elseif t == "Vector2" then
		return string.format("V2(%s,%s)", bits(x.X), bits(x.Y))
	elseif t == "Color3" then
		return string.format("C3(%s,%s,%s)", bits(x.R), bits(x.G), bits(x.B))
	elseif t == "CFrame" then
		local parts: { string } = {}
		for _, c in { (x :: CFrame):GetComponents() } do
			table.insert(parts, bits(c))
		end
		return "CF(" .. table.concat(parts, ",") .. ")"
	elseif t == "table" then
		local parts: { string } = {}
		for k, v in next, x do
			table.insert(parts, exact(k, d + 1) .. "=" .. exact(v, d + 1))
		end
		table.sort(parts)
		local marks = (if getmetatable(x) ~= nil then "+mt" else "") .. (if table.isfrozen(x) then "+frozen" else "")
		return "{" .. table.concat(parts, ",") .. "}" .. marks
	elseif t == "string" then
		return string.format("%q", x)
	end
	return t .. ":" .. tostring(x)
end

-- Mismatches: all of them are listed, each from just before its first differing character -------------------

local lastYield = os.clock()

local function tick()
	if os.clock() - lastYield > YIELD_AFTER then
		task.wait()
		lastYield = os.clock()
	end
end

local function newChecker(): Checker
	return { mismatches = {}, count = 0 }
end

local function note(ck: Checker, what: string, a: string, b: string)
	local i = 1
	local n = math.min(#a, #b)
	while i <= n and string.byte(a, i) == string.byte(b, i) do
		i += 1
	end
	local from = math.max(1, i - CONTEXT)
	local cut = if from > 1 then ".." else ""
	local now, old = cut .. string.sub(a, from, i + TAIL), cut .. string.sub(b, from, i + TAIL)
	ck.count += 1
	table.insert(ck.mismatches, string.format("%s\n      %s: %s\n      %s: %s", what, NOW.name, now, OLD.name, old))
end

local function check(ck: Checker)
	if ck.count > 0 then
		error(string.format("%d mismatch(es), all of them:\n  %s", ck.count, table.concat(ck.mismatches, "\n  ")), 0)
	end
end

-- Shapes, built into descriptors by each side's own T ----------------------------------------------------------

local function S(k: string, extra: { [string]: any }?): Shape
	local s: Shape = { k = k }
	if extra then
		for key, v in extra do
			s[key] = v
		end
	end
	return s
end

local BOOL, U16, F32, F64 = S("bool"), S("u16"), S("f32"), S("f64")
local V3, V2, C3, CF = S("V3"), S("V2"), S("C3"), S("CF")

local function F32R(lo: number, hi: number): Shape
	return S("f32r", { lo = lo, hi = hi })
end
local function NUM(lo: number, hi: number): Shape
	return S("num", { lo = lo, hi = hi })
end
local function V3M(mag: number): Shape
	return S("V3", { mag = mag })
end
local function V2M(mag: number): Shape
	return S("V2", { mag = mag })
end
local function STR(max: number): Shape
	return S("string", { max = max })
end
local function ARR(inner: Shape, max: number): Shape
	return S("arr", { inner = inner, max = max })
end
local function STRUCT(fields: { [string]: Shape }): Shape
	return S("struct", { fields = fields })
end

local function build(T: any, s: Shape): any
	local k = s.k
	if k == "bool" then
		return T.bool
	elseif k == "u16" then
		return T.u16
	elseif k == "f32" then
		return T.f32
	elseif k == "f64" then
		return T.f64
	elseif k == "f32r" then
		return T.f32(s.lo, s.hi)
	elseif k == "num" then
		return T.num(s.lo, s.hi)
	elseif k == "V3" then
		return if s.mag then T.Vector3(s.mag) else T.Vector3
	elseif k == "V2" then
		return if s.mag then T.Vector2(s.mag) else T.Vector2
	elseif k == "C3" then
		return T.Color3
	elseif k == "CF" then
		return T.CFrame
	elseif k == "string" then
		return T.string(s.max)
	elseif k == "arr" then
		return T.array(build(T, s.inner), s.max)
	elseif k == "struct" then
		local fields: { [string]: any } = {}
		for name, f in s.fields :: { [string]: Shape } do
			fields[name] = build(T, f)
		end
		return T.struct(fields)
	end
	error("DecodeFloat.spec: unknown shape " .. tostring(k))
end

local function buildList(T: any, shapes: { Shape }): { any }
	local descs: { any } = table.create(#shapes)
	for i, s in shapes do
		descs[i] = build(T, s)
	end
	return descs
end

local function compile(side: Side, shapes: { Shape }, anf: boolean, c2s: boolean): any
	return side.Schema.compile(buildList(side.Schema.T, shapes), anf, if c2s then MAX_C2S else MAX_S2C, false)
end

-- Baseline values: the first component of each float group holds a unique marker, found again in the encoding ----

local COMPONENTS: { [string]: { string } } = {
	V3 = { "X", "Y", "Z" },
	V2 = { "X", "Y" },
	C3 = { "R", "G", "B" },
	CF = { "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22" },
}

-- 0.5 + n/1024 (exact in f32 and f64, inside every bound used here) as the f32 or f64 group's first component
local function mark(mk: Marks, width: number, label: string, names: { string }?): number
	mk.n += 1
	assert(mk.n < 128, "DecodeFloat.spec: too many float groups in one baseline")
	local v = 0.5 + mk.n / 1024
	if width == 4 then
		buffer.writef32(scratch, 0, v)
		table.insert(mk.groups, { label = label, width = 4, lo = buffer.readu32(scratch, 0), hi = 0, names = names })
	else
		buffer.writef64(scratch, 0, v)
		local lo, hi = buffer.readu32(scratch, 0), buffer.readu32(scratch, 4)
		table.insert(mk.groups, { label = label, width = 8, lo = lo, hi = hi, names = nil })
	end
	return v
end

local function value(mk: Marks, s: Shape, label: string): any
	local k = s.k
	if k == "bool" then
		return true
	elseif k == "u16" then
		return 7
	elseif k == "string" then
		return "ab"
	elseif k == "f32" or k == "f32r" then
		return mark(mk, 4, label)
	elseif k == "f64" or k == "num" then
		return mark(mk, 8, label)
	elseif k == "V3" then
		return Vector3.new(mark(mk, 4, label, COMPONENTS.V3), 1, 1)
	elseif k == "V2" then
		return Vector2.new(mark(mk, 4, label, COMPONENTS.V2), 1)
	elseif k == "C3" then
		return Color3.new(mark(mk, 4, label, COMPONENTS.C3), 1, 1)
	elseif k == "CF" then
		return CFrame.new(mark(mk, 4, label, COMPONENTS.CF), 1, 1)
	elseif k == "arr" then
		local t: { any } = {}
		for i = 1, 3 do
			t[i] = value(mk, s.inner, string.format("%s[%d]", label, i))
		end
		return t
	elseif k == "struct" then
		local names: { string } = {}
		for name in s.fields :: { [string]: Shape } do
			table.insert(names, name)
		end
		table.sort(names)
		local t: { [string]: any } = {}
		for _, name in names do
			t[name] = value(mk, s.fields[name], label .. "." .. name)
		end
		return t
	end
	error("DecodeFloat.spec: no baseline value for shape " .. tostring(k))
end

local function baseline(shapes: { Shape }): ({ any }, { Group })
	local mk: Marks = { groups = {}, n = 0 }
	local values: { any } = {}
	for i, s in shapes do
		values[i] = value(mk, s, "arg " .. i)
	end
	return values, mk.groups
end

local function bytesOf(w: any): buffer
	local b = buffer.create(w.n)
	buffer.copy(b, 0, w.buf, 0, w.n)
	return b
end

-- The frozen side's payload for these values (no refs: every shape here is fixed-size or a string).
local function encodePayload(pc: any, c2s: boolean, values: { any }): buffer
	local w = OLD.Codec.newWriter(64, c2s)
	local st = pc.encode(w, #values, table.unpack(values))
	assert(st == 0, "DecodeFloat.spec: the frozen encoder refused a baseline value, status " .. tostring(st))
	return bytesOf(w)
end

-- Every float slot of a payload: each group's marker found exactly once, then its components 4 bytes apart
local function locate(b: buffer, groups: { Group }): { Slot }
	local len = buffer.len(b)
	local slots: { Slot } = {}
	for _, g in groups do
		local found, hits = -1, 0
		for at = 0, len - g.width do
			if buffer.readu32(b, at) == g.lo and (g.width == 4 or buffer.readu32(b, at + 4) == g.hi) then
				found = at
				hits += 1
			end
		end
		assert(hits == 1, string.format("DecodeFloat.spec: the marker of %s is in the payload %d times", g.label, hits))
		local names = g.names
		if names then
			for c, name in names do
				table.insert(slots, { at = found + (c - 1) * 4, width = 4, label = g.label .. "." .. name })
			end
		else
			table.insert(slots, { at = found, width = g.width, label = g.label })
		end
	end
	return slots
end

local function withPattern(b: buffer, at: number, p: Pattern): buffer
	local c = buffer.create(buffer.len(b))
	buffer.copy(c, 0, b, 0, buffer.len(b))
	buffer.writeu32(c, at, p.lo)
	if p.width == 8 then
		buffer.writeu32(c, at + 4, p.hi)
	end
	return c
end

-- Cases --------------------------------------------------------------------------------------------------------

local THING = STRUCT({
	v3 = V3,
	v2 = V2,
	c3 = C3,
	cf = CF,
	f = F32,
	d = F64,
	unit = F32R(-1, 1),
	pct = NUM(0, 100),
	near = V3M(10),
	flat = V2M(5),
	id = U16,
	ok = BOOL,
})
local TUPLE: { Shape } = { V3, V2, C3, CF, F32, F64, F32R(-1, 1), NUM(0, 100), V3M(10), V2M(5) }
local LOOSE = STRUCT({ s = STR(4), v3 = V3, v2 = V2, c3 = C3, cf = CF, f = F32, d = F64 })

local SCHEMA_CASES: { Case } = {
	{ name = "one Vector3 (fixedArgs, the codec path of an O1 route)", args = { V3 } },
	{ name = "one T.Vector3(10)", args = { V3M(10) } },
	{ name = "one Vector2", args = { V2 } },
	{ name = "one T.Vector2(5)", args = { V2M(5) } },
	{ name = "one Color3", args = { C3 } },
	{ name = "one CFrame", args = { CF } },
	{ name = "one f32", args = { F32 } },
	{ name = "one T.f32(-1, 1)", args = { F32R(-1, 1) } },
	{ name = "one f64", args = { F64 } },
	{ name = "one T.num(0, 100)", args = { NUM(0, 100) } },
	{ name = "a tuple of every float type (fixedArgs)", args = TUPLE },
	{ name = "a struct of every float type (fixedStruct)", args = { THING } },
	{ name = "that struct after a string (decodeFields hands it to fixedRun)", args = { STR(4), THING } },
	{ name = "three of those structs in an array (fixedRun over the elements)", args = { ARR(THING, 8) } },
	{ name = "a struct with a string (decodeFields alone)", args = { LOOSE } },
	{ name = "f32, Vector3 and f64 arrays (the element loops)", args = { ARR(F32, 4), ARR(V3, 4), ARR(F64, 4) } },
}

type ClientRoute = { name: string, args: { Shape }, ordered: boolean? }
local CLIENT_ROUTES: { ClientRoute } = {
	{ name = "Vec", args = { V3 } },
	{ name = "VecMax", args = { V3M(10) } },
	{ name = "OrdVec", args = { V3 }, ordered = true },
	{ name = "F32", args = { F32 } },
	{ name = "Unit", args = { F32R(-1, 1) } },
	{ name = "F64", args = { F64 } },
	{ name = "Tuple", args = TUPLE },
	{ name = "Thing", args = { THING } },
	{ name = "Things", args = { ARR(THING, 8) } },
}

type ServerEvent = { name: string, args: { Shape }, anf: boolean? }
local SERVER_EVENTS: { ServerEvent } = {
	{ name = "Vec", args = { V3 } },
	{ name = "VecAnf", args = { V3 }, anf = true },
	{ name = "VecMax", args = { V3M(10) } },
	{ name = "F32", args = { F32 } },
	{ name = "Unit", args = { F32R(-1, 1) }, anf = true },
	{ name = "F64", args = { F64 }, anf = true },
	{ name = "Tuple", args = TUPLE },
	{ name = "TupleAnf", args = TUPLE, anf = true },
	{ name = "Thing", args = { THING } },
	{ name = "ThingAnf", args = { THING }, anf = true },
	{ name = "Things", args = { ARR(THING, 8) }, anf = true },
	{ name = "Late", args = { STR(4), THING } },
}

-- Schema decoders: one decode as text (status, errArg, count, cursor, counters, argv) --------------------------

local function decodeText(side: Side, pc: any, c2s: boolean, b: buffer): string
	local SideCodec = side.Codec
	local ctx = SideCodec.newReadCtx(c2s, c2s)
	SideCodec.beginFrame(ctx, nil, 0)
	SideCodec.beginMessage(ctx, pc.allowNonFinite)
	local argv: { any } = {}
	local ok, n, q = pcall(pc.decode, b, 0, buffer.len(b), ctx, argv)
	if not ok then
		return "decode threw" -- the texts name each side's module: only the fact is compared
	end
	return string.format(
		"err=%d errArg=%d n=%s q=%s cursor=%d nodes=%d claimed=%d argv=%s",
		ctx.err,
		ctx.errArg,
		tostring(n),
		tostring(q),
		ctx.cursor,
		ctx.nodes,
		ctx.claimed,
		exact(argv)
	)
end

local function sweepSchema(ck: Checker, case: Case)
	for _, c2s in { false, true } do
		for _, anf in { false, true } do
			local dir = (if c2s then "C->S" else "S->C") .. (if anf then ", AllowNonFinite" else "")
			local now, old = compile(NOW, case.args, anf, c2s), compile(OLD, case.args, anf, c2s)
			local values, groups = baseline(case.args)
			local base = encodePayload(old, c2s, values)
			local function same(b: buffer, what: string)
				tick()
				local a, o = decodeText(NOW, now, c2s, b), decodeText(OLD, old, c2s, b)
				if a ~= o then
					note(ck, dir .. ": " .. what, a, o)
				end
			end
			same(base, "the baseline")
			for _, slot in locate(base, groups) do
				for _, p in patternsFor(slot.width) do
					same(withPattern(base, slot.at, p), slot.label .. " = " .. p.label)
				end
			end
		end
	end
end

-- ClientNet: frames of one route, one message per pattern, against the frozen decoder walking the same frame ----

local clientDecoders: { any } = {}
local clientLines: { string } = {}
local clientReason: string? = nil
local clientSeq = 0

local function clientModel(): any
	local F, K = C.MemberFlag, C.Kind
	local members: { any } = {}
	for id, r in CLIENT_ROUTES do
		local flags = bit32.bor(F.AllowNonFinite, F.HasArgs)
		if r.ordered then
			flags = bit32.bor(flags, F.Unreliable, F.Ordered)
		end
		table.insert(members, {
			name = r.name,
			kind = K.Signal,
			route = id,
			flags = flags,
			timeout = 0,
			rate = 0,
			burst = 0,
			backlog = 0,
			args = buildList(NOW.Schema.T, r.args),
			returns = nil,
		})
	end
	return {
		proto = C.PROTO,
		version = "2.0.0",
		limits = {
			frameRate = 120,
			frameBurst = 140,
			byteRate = 131072,
			byteBurst = 262144,
			msgRate = 600,
			msgBurst = 600,
			mirror = 0.9,
			sealC2S = 16384,
			maxMessageC2S = 65536,
			unreliableMax = 900,
			maxPending = 4096,
			maxNodes = 2048,
			maxArgs = 20,
			maxRefs = 255,
			maxDepth = 16,
			flushHz = 61,
			backlogWindow = 10,
		},
		services = { { name = SVC, members = members } },
	}
end

local function clientSetup()
	Loren.Testing.Reset({ Offline = true })
	ClientNet._reset()
	Calls._reset()
	Proxy._reset()
	ClientNet._test.setClock(function(): number
		return 1000
	end)
	ClientNet._test.loadManifest(clientModel())
	Log._reset()
	Log._test.setSink(noop, function(line: string)
		local why = string.match(line, "server frame %((.-)%)")
		if why and clientReason == nil then
			clientReason = why
		end
	end)
	for id, route in ClientNet.routes() do
		route.signal:Connect(function(...: any)
			table.insert(clientLines, id .. ":" .. exact(table.pack(...)))
		end)
	end
	for id, r in CLIENT_ROUTES do
		clientDecoders[id] = compile(OLD, r.args, true, false)
	end
end

-- The frozen v2 decoder walking the frame as ClientNet does (every Ordered seq here is fresh)
local function clientOracle(frame: buffer): ({ string }, string?)
	local OldCodec = OLD.Codec
	local ctx = OldCodec.newReadCtx(false, false)
	OldCodec.beginFrame(ctx, nil, 0)
	local lines: { string } = {}
	local len = buffer.len(frame)
	local p = 0
	while p < len do
		local h, q = OldCodec.readHead(frame, p, len)
		local r = CLIENT_ROUTES[h]
		assert(r ~= nil, "DecodeFloat.spec: a generated frame names an unknown route")
		if r.ordered then
			if q + 2 > len then
				return lines, "truncated signal"
			end
			q += 2
		end
		OldCodec.beginMessage(ctx, true)
		local argv: { any } = {}
		local n, q2 = clientDecoders[h].decode(frame, q, len, ctx, argv)
		if ctx.err ~= 0 then
			return lines, "bad payload for " .. SVC .. "." .. r.name
		end
		table.insert(lines, h .. ":" .. exact(table.pack(table.unpack(argv, 1, n))))
		p = q2
	end
	return lines, nil
end

-- One frame of route `id`: this payload once per pattern at `slot`, each message with its route head (and seq)
local function clientFrame(id: number, payload: buffer, slot: Slot): buffer
	local ordered = CLIENT_ROUTES[id].ordered == true
	local pats = patternsFor(slot.width)
	local size = 1 + (if ordered then 2 else 0) + buffer.len(payload)
	local b = buffer.create(size * #pats)
	for i, p in pats do
		local o = (i - 1) * size
		buffer.writeu8(b, o, id)
		o += 1
		if ordered then
			clientSeq = (clientSeq + 1) % 65536
			buffer.writeu16(b, o, clientSeq)
			o += 2
		end
		buffer.copy(b, o, withPattern(payload, slot.at, p), 0, buffer.len(payload))
	end
	return b
end

local function sweepClient(ck: Checker, id: number)
	local r = CLIENT_ROUTES[id]
	local values, groups = baseline(r.args)
	local payload = encodePayload(clientDecoders[id], false, values)
	for _, slot in locate(payload, groups) do
		tick()
		local pats = patternsFor(slot.width)
		local frame = clientFrame(id, payload, slot)
		table.clear(clientLines)
		clientReason = nil
		ClientNet._test.receive(frame, nil)
		local want, wantReason = clientOracle(frame)
		for i = 1, math.max(#clientLines, #want, #pats) do
			local got, expected = clientLines[i] or "(nothing)", want[i] or "(nothing)"
			if got ~= expected then
				local p = pats[i]
				note(ck, string.format("%s %s = %s", r.name, slot.label, if p then p.label else "?"), got, expected)
			end
		end
		if clientReason ~= wantReason then
			note(ck, r.name .. " " .. slot.label .. ": the frame's end", tostring(clientReason), tostring(wantReason))
		end
	end
end

-- Server: C->S frames through Transport (the hostile decoders), against the frozen decoder's C->S result ---------

local serverNow = 1000
local rt: any = nil
local trail: { string } = {}
local frameSeq = 0
local nextUid = 0
local routeIds: { [string]: number } = {}
local serverDecoders: { [string]: any } = {}
local tickCodec: any = nil

local function resetServer()
	Transport._reset()
	Routes._reset()
	Dispatch._reset()
	Outbox._reset()
	ServerSignal._reset()
	Limits._reset()
	Violations._reset()
end

local function serverServices(): any
	local K = C.Kind
	local members: { any } = {
		{ name = "Tick", kind = K.Event, fn = nil, spec = nil, middleware = nil, colon = false },
	}
	for _, e in SERVER_EVENTS do
		local list: { any } = buildList(NOW.Schema.T, e.args)
		if e.anf then
			table.insert(list, { AllowNonFinite = true })
		end
		local spec = NOW.Schema.event(table.unpack(list))
		table.insert(members, { name = e.name, kind = K.Event, fn = nil, spec = spec, middleware = nil, colon = false })
	end
	local module = { Client = {}, Signals = {}, ClientEvents = {}, Middleware = {} }
	return {
		{
			name = "S",
			record = { name = "S", kind = "Service", module = module, instance = script, path = "S", deps = {} },
			module = module,
			client = {},
			members = members,
			networked = true,
		},
	}
end

local function serverSetup()
	Loren.Testing.Reset({ Offline = true })
	resetServer()
	Log._test.setSink(noop, noop)
	local c = Config.get()
	Limits.configure(c)
	Violations.configure(c)
	local report: any = { side = "Server", errors = {}, warnings = {} }
	rt = Routes.build(serverServices(), c, report)
	assert(rt ~= nil, "DecodeFloat.spec: Routes.build failed: " .. table.concat(report.errors, "; "))
	for _, r in rt.routes do
		routeIds[r.member] = r.id
	end
	Outbox._test.capture(noop)
	serverNow = 1000
	Transport._test.setClock(function(): number
		return serverNow
	end)
	Transport._test.attach(rt)
	Dispatch._test.setForwardErrors(false)
	rt.events.S.Tick:Connect(function(_: any, k: any)
		table.insert(trail, "tick " .. tostring(k))
	end)
	for _, e in SERVER_EVENTS do
		rt.events.S[e.name]:Connect(function(_: any, ...: any)
			table.insert(trail, "args " .. exact(table.pack(...)))
		end)
		serverDecoders[e.name] = compile(OLD, e.args, e.anf == true, true)
	end
	tickCodec = OLD.Schema.compile(nil, true, MAX_C2S, false)
end

-- A C->S message: the route head, then the payload.
local function c2sMessage(id: number, payload: buffer): buffer
	local w = Codec.newWriter(buffer.len(payload) + 4, true)
	Codec.writeHead(w, id)
	Codec.writeBytes(w, payload, 0, buffer.len(payload))
	return bytesOf(w)
end

-- seq:u16 nmsg:u16 nrefs:u8, then each message behind its varint length.
local function c2sFrame(msgs: { buffer }): buffer
	frameSeq = (frameSeq + 1) % 65536
	local w = Codec.newWriter(64, true)
	Codec.writeU16(w, frameSeq)
	Codec.writeU16(w, #msgs)
	Codec.writeU8(w, 0)
	for _, m in msgs do
		Codec.writeVarint(w, buffer.len(m))
		Codec.writeBytes(w, m, 0, buffer.len(m))
	end
	return bytesOf(w)
end

local function tickMessage(k: number): buffer
	local w = OLD.Codec.newWriter(16, true)
	assert(tickCodec.encode(w, 1, k) == 0, "DecodeFloat.spec: the tick did not encode")
	return c2sMessage(routeIds.Tick, bytesOf(w))
end

local function newPlayer(): any
	nextUid += 1
	local p: any = { UserId = nextUid, Name = "DecodeFloat" .. nextUid }
	p.Kick = noop
	Transport._test.addPlayer(p)
	local hello = buffer.create(2)
	buffer.writeu8(hello, 0, C.Op.HELLO)
	buffer.writeu8(hello, 1, C.PROTO)
	Transport._test.frame(false, p, c2sFrame({ hello }), nil)
	Transport._test.flush()
	return p
end

-- One frame from `p` (the clock moves on first, so no bucket is ever short): (violations, EventBad drops) it caused
local function send(p: any, msgs: { buffer }): (number, number)
	serverNow += 10
	local before = Violations.totals()
	table.clear(trail)
	Transport._test.frame(false, p, c2sFrame(msgs), nil)
	local after = Violations.totals()
	local drops = (after.drops[DROP_EVENT_BAD] or 0) - (before.drops[DROP_EVENT_BAD] or 0)
	return after.violations - before.violations, drops
end

-- What the server must do with this payload: the frozen C->S decode's args, or a drop, or a violation
local function frozenEvent(e: ServerEvent, payload: buffer): string
	local OldCodec = OLD.Codec
	local ctx = OldCodec.newReadCtx(true, true)
	OldCodec.beginFrame(ctx, nil, 0)
	OldCodec.beginMessage(ctx, e.anf == true)
	local argv: { any } = {}
	local ok, n, q = pcall(serverDecoders[e.name].decode, payload, 0, buffer.len(payload), ctx, argv)
	if not ok then
		return "decode threw"
	elseif ctx.err == 0 and q == buffer.len(payload) then
		return "args " .. exact(table.pack(table.unpack(argv, 1, n)))
	elseif ctx.err >= SEMANTIC_MIN then
		return "dropped"
	end
	return "violation"
end

-- The trail split at its ticks: segment k is what the listeners got after tick k (0: before the first)
local function segments(list: { string }): { [number]: string }
	local out: { [number]: string } = { [0] = "" }
	local k = 0
	for _, line in list do
		local t = tonumber(string.match(line, "^tick (%d+)$"))
		if t then
			k = t
			out[k] = if out[k] then out[k] .. "tick again; " else ""
		else
			out[k] = (out[k] or "(no tick) ") .. line .. "; "
		end
	end
	return out
end

-- Every pattern at every slot of event `e`: one frame per slot, each pattern's message behind a tick of its own
local function sweepServer(ck: Checker, e: ServerEvent)
	local p = newPlayer()
	local values, groups = baseline(e.args)
	local payload = encodePayload(serverDecoders[e.name], true, values)
	for _, slot in locate(payload, groups) do
		tick()
		local pats = patternsFor(slot.width)
		local msgs: { buffer } = {}
		local want: { string } = {}
		local wantDrops, wantViolations = 0, 0
		for k, pat in pats do
			local body = withPattern(payload, slot.at, pat)
			table.insert(msgs, tickMessage(k))
			table.insert(msgs, c2sMessage(routeIds[e.name], body))
			table.insert(want, "tick " .. k)
			local outcome = frozenEvent(e, body)
			if outcome == "dropped" then
				wantDrops += 1
			elseif outcome == "violation" or outcome == "decode threw" then
				wantViolations = 1
				table.insert(want, "violation")
				break -- a structural fault ends the frame there
			else
				table.insert(want, outcome)
			end
		end
		local violations, drops = send(p, msgs)
		local got = table.clone(trail)
		if violations > 0 then
			table.insert(got, "violation")
		end
		local g, w = segments(got), segments(want)
		for i = 1, #pats + 1 do
			local k = i - 1
			local a, b = g[k] or "(no tick)", w[k] or "(no tick)"
			if a ~= b then
				local what = if k == 0 then "before the first tick" else pats[k].label
				note(ck, string.format("%s %s = %s", e.name, slot.label, what), a, b)
			end
		end
		if drops ~= wantDrops or math.min(violations, 1) ~= wantViolations then
			local a = string.format("EventBad drops %d, violations %d", drops, violations)
			local b = string.format("EventBad drops %d, violations %d", wantDrops, wantViolations)
			note(ck, e.name .. " " .. slot.label .. ": the frame's counters", a, b)
		end
	end
end

-- The one-argument events once more, one message per frame (the parse delivers it without a runner)
local function sweepServerSingles(ck: Checker)
	for _, e in SERVER_EVENTS do
		if #e.args ~= 1 or e.args[1].k == "struct" or e.args[1].k == "arr" then
			continue
		end
		local p = newPlayer()
		local values, groups = baseline(e.args)
		local payload = encodePayload(serverDecoders[e.name], true, values)
		for _, slot in locate(payload, groups) do
			for _, pat in patternsFor(slot.width) do
				tick()
				local body = withPattern(payload, slot.at, pat)
				local want = frozenEvent(e, body)
				local violations, drops = send(p, { c2sMessage(routeIds[e.name], body) })
				local got = if #trail > 0
					then table.concat(trail, "; ")
					elseif drops > 0 then "dropped"
					elseif violations > 0 then "violation"
					else "nothing"
				if want == "decode threw" then
					want = "violation"
				end
				if got ~= want then
					note(ck, string.format("%s alone, %s = %s", e.name, slot.label, pat.label), got, want)
				end
			end
		end
	end
end

-- fixedRun: it builds a Vector3 only from zero, normal and infinite components, and hands the rest back ----------

local ONE_F32 = 0x3F800000

-- A subnormal or NaN f32: fixedRun must hand it to decodeFields whatever the hostile guard says
local function special(x: number): boolean
	local m = bit32.band(x, 0x7FFFFFFF)
	return (m > 0 and m < 0x00800000) or m > 0x7F800000
end

local function present(x: any): string
	return tostring(x ~= nil)
end

-- The frozen v2 decode of the Vector3 at o, as text
local function frozenVector(pc: any, hostile: boolean, b: buffer, o: number): string
	local OldCodec = OLD.Codec
	local ctx = OldCodec.newReadCtx(hostile, hostile)
	OldCodec.beginFrame(ctx, nil, 0)
	OldCodec.beginMessage(ctx, pc.allowNonFinite)
	local argv: { any } = {}
	pc.decode(b, o, o + 12, ctx, argv)
	return if ctx.err == 0 then exact(argv[1]) else "err " .. tostring(ctx.err)
end

-- Three Vector3s of ones, the middle one with the pattern in component c: one run into argv, and a run of three structs
local function sweepFixedRun(ck: Checker, hostile: boolean, anf: boolean)
	local Schema = NOW.Schema
	local fixedRun = Schema._test.fixedRun
	local root = Schema._test.prog({ Schema.T.Vector3 }, anf)
	local sp = Schema._test.prog({ Schema.T.struct({ p = Schema.T.Vector3 }) }, anf).sub[1]
	local tpl = if hostile then sp.htpl else sp.tpl
	local old = compile(OLD, { V3 }, anf, hostile)
	for c = 0, 2 do
		for _, p in F32_PATTERNS do
			tick()
			local b = buffer.create(36)
			for at = 0, 32, 4 do
				buffer.writeu32(b, at, ONE_F32)
			end
			buffer.writeu32(b, 12 + c * 4, p.lo)
			local guarded = hostile and not anf and bit32.band(p.lo, 0x7FFFFFFF) >= 0x7F800000
			local doubt = special(p.lo) or guarded
			local what = string.format("component %d = %s", c + 1, p.label)
			local argv: { any } = {}
			local k = fixedRun(b, 12, hostile, root, argv, false, 1, 1)
			local want = if doubt then 1 else 2
			if k ~= want then
				note(ck, what .. ": fixedRun's return, one run into argv", tostring(k), tostring(want))
			elseif k == 2 then
				local a, o = exact(argv[1]), frozenVector(old, hostile, b, 12)
				if a ~= o then
					note(ck, what .. ": the Vector3 it built", a, o)
				end
			end
			local list: { any } = {}
			k = fixedRun(b, 0, hostile, sp, list, tpl, 1, 3)
			local got =
				string.format("return %d, stored %s %s %s", k, present(list[1]), present(list[2]), present(list[3]))
			local kept = tostring(not doubt)
			local expected = string.format("return %d, stored true %s %s", if doubt then 2 else 4, kept, kept)
			if got ~= expected then
				note(ck, what .. ": a run of 3 structs", got, expected)
			elseif not doubt then
				local a, o = exact(list[2].p), frozenVector(old, hostile, b, 12)
				if a ~= o then
					note(ck, what .. ": element 2's Vector3", a, o)
				end
			end
		end
	end
end

-- Test body ----------------------------------------------------------------------------------------------------

return function(t: any)
	local describe, it = t.describe, t.it

	t.afterAll(function()
		ClientNet._reset()
		Calls._reset()
		Proxy._reset()
		resetServer()
		Log._reset()
		Loren.Testing.Reset()
	end)

	describe("float bit patterns in Schema decoders vs frozen v2 (both directions, AllowNonFinite on/off)", function()
		for _, case in SCHEMA_CASES do
			it(case.name, function()
				local ck = newChecker()
				sweepSchema(ck, case)
				check(ck)
			end, { timeout = 300 })
		end
	end)

	describe("fixedRun builds a Vector3 only from zero, normal or infinite f32s (the rest to decodeFields)", function()
		for _, hostile in { false, true } do
			for _, anf in { false, true } do
				local side = (if hostile then "hostile" else "trusted") .. (if anf then ", AllowNonFinite" else "")
				it(side .. ": every f32 pattern in each component, one run and a run of structs", function()
					local ck = newChecker()
					sweepFixedRun(ck, hostile, anf)
					check(ck)
				end, { timeout = 120 })
			end
		end
	end)

	describe("float bit patterns in ClientNet frames against frozen v2 (O1 inline scalars, the codec)", function()
		t.beforeAll(function()
			clientSetup()
		end)
		for id, r in CLIENT_ROUTES do
			it(r.name .. ": every pattern in every float slot, delivered bit for bit", function()
				local ck = newChecker()
				sweepClient(ck, id)
				check(ck)
			end, { timeout = 300 })
		end
	end)

	describe("float bit patterns in server ClientEvents against frozen v2 (Transport's hostile decode)", function()
		t.beforeAll(function()
			serverSetup()
		end)
		for _, e in SERVER_EVENTS do
			it(e.name .. ": every pattern in every float slot, delivered, dropped or refused as frozen v2", function()
				local ck = newChecker()
				sweepServer(ck, e)
				check(ck)
			end, { timeout = 300 })
		end
		it("one-argument events one message per frame: the same values and drops", function()
			local ck = newChecker()
			sweepServerSingles(ck)
			check(ck)
		end, { timeout = 300 })
	end)
end
