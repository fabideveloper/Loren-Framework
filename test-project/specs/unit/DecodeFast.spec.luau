--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local FrozenV2 = ServerStorage.LorenTest.Frozen.v2

local Loren = require(Runtime) :: any
local ClientNet = require(Runtime.ClientNet) :: any
local Calls = require(Runtime.Calls) :: any
local Proxy = require(Runtime.Proxy) :: any
local Log = require(Runtime.Log) :: any

type Side = { name: string, C: any, Codec: any, Schema: any }
type Shape = { [string]: any }
type Args = { n: number, [number]: any }
type Input = { b: buffer, lim: number, refs: { any }?, nrefs: number }
type Case = { name: string, args: { Shape }, wire: { Shape }?, rounds: number? }
type Encoded = { text: string, bytes: buffer?, refs: { any }, nrefs: number }
type Checker = { mismatches: { string }, count: number, work: number }

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

local D_MISSING = NOW.C.Decode.MISSING_INSTANCE
local MAX_C2S = NOW.C.Limit.MAX_ARGS_C2S
local MAX_S2C = NOW.C.Limit.MAX_ARGS_S2C
local ROUNDS = 150
local MUTATIONS = 6
local RANDOM_BUFFERS = 40
local SLIDE_BASE_MAX = 400
local SLIDE_ALL = 32
local SLIDE_SAMPLE = 16
local CLIENT_FRAMES = 300
local YIELD_AFTER = 0.05
local MISMATCHES_SHOWN = 4
local NAN, INF = 0 / 0, math.huge
local NEG0 = -1 / INF
local F32_MAX = 3.4028234663852886e38
local F64_MAX = 1.7976931348623157e308

local U8S = { 0, 1, 2, 3, 0x7F, 0x80, 0xFE, 0xFF, 100, 101 }
local U16S = { 0, 1, 2, 0x7FFF, 0x8000, 0xFFFF, 999, 1000, 1001 }
local U32S = { 0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 69999, 70000, 70001 }
local F32S = {
	0x00000000,
	0x80000000,
	0x7FC00000,
	0xFFC00000,
	0x7F800001,
	0x7F800000,
	0xFF800000,
	0x00000001,
	0x807FFFFF,
	0x00800000,
	0x7F7FFFFF,
	0xFF7FFFFF,
	0x3F800000,
	0xBF800000,
	0x41200000,
	0x41300000,
}
local F64S: { { number } } = {
	{ 0, 0 },
	{ 0, 0x80000000 },
	{ 0, 0x7FF80000 },
	{ 1, 0x7FF00000 },
	{ 0, 0x7FF00000 },
	{ 0, 0xFFF00000 },
	{ 1, 0 },
	{ 0xFFFFFFFF, 0x000FFFFF },
	{ 0xFFFFFFFF, 0x7FEFFFFF },
	{ 0xFFFFFFFF, 0xFFEFFFFF },
	{ 0, 0x3FF00000 },
	{ 0, 0x40590000 },
	{ 1, 0x40590000 },
}

local folderA = Instance.new("Folder")
folderA.Name = "DecodeFastA"
local folderB = Instance.new("Folder")
folderB.Name = "DecodeFastB"
local part = Instance.new("Part")
part.Name = "DecodeFastPart"
local instanceIds: { [Instance]: number } = { [folderA] = 1, [folderB] = 2, [part] = 3 }
local FUZZ_REFS: { any } = { folderA, part, { 1, 2 } }

local function noop(...: any) end

local function show(x: any, depth: number?): string
	local d = depth or 0
	if d > 64 then
		return "<too deep>"
	end
	local t = typeof(x)
	if t == "number" then
		if x ~= x then
			return "nan"
		elseif x == 0 then
			return if 1 / x < 0 then "-0" else "0"
		end
		return string.format("%.17g", x)
	elseif t == "string" then
		return string.format("%q", x)
	elseif t == "buffer" then
		return "buf" .. string.format("%q", buffer.tostring(x))
	elseif t == "table" then
		local parts: { string } = {}
		for k, value in next, x do
			table.insert(parts, show(k, d + 1) .. "=" .. show(value, d + 1))
		end
		table.sort(parts)
		local marks = (if getmetatable(x) ~= nil then "+mt" else "") .. (if table.isfrozen(x) then "+frozen" else "")
		return "{" .. table.concat(parts, ",") .. "}" .. marks
	elseif t == "Vector3" then
		return string.format("V3(%s,%s,%s)", show(x.X), show(x.Y), show(x.Z))
	elseif t == "Vector2" then
		return string.format("V2(%s,%s)", show(x.X), show(x.Y))
	elseif t == "Color3" then
		return string.format("C3(%s,%s,%s)", show(x.R), show(x.G), show(x.B))
	elseif t == "CFrame" then
		local parts: { string } = {}
		for _, c in { (x :: CFrame):GetComponents() } do
			table.insert(parts, show(c))
		end
		return "CF(" .. table.concat(parts, ",") .. ")"
	elseif t == "Instance" then
		return "I#" .. tostring(instanceIds[x] or ("?" .. (x :: Instance).Name))
	end
	return t .. ":" .. tostring(x)
end

local function hex(b: buffer, len: number): string
	local s = buffer.readstring(b, 0, math.min(len, 48))
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end)) .. (if len > 48 then ".." else "")
end

local function S(k: string, extra: { [string]: any }?): Shape
	local s: Shape = { k = k }
	if extra then
		for key, v in extra do
			s[key] = v
		end
	end
	return s
end

local BOOL, U8, U16, U32 = S("bool"), S("u8"), S("u16"), S("u32")
local I8, I16, I32 = S("i8"), S("i16"), S("i32")
local F32, F64 = S("f32"), S("f64")
local V3, V2, C3, CF = S("V3"), S("V2"), S("C3"), S("CF")
local ENUM, EI, ANY = S("enum"), S("EI"), S("any")

local function INT(lo: number, hi: number): Shape
	return S("int", { lo = lo, hi = hi })
end
local function U8R(lo: number, hi: number): Shape
	return S("u8r", { lo = lo, hi = hi })
end
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
local function STR(max: number, binary: boolean?): Shape
	return S("string", { max = max, binary = binary == true })
end
local function BUF(max: number): Shape
	return S("buffer", { max = max })
end
local function INST(class: string?): Shape
	return S("inst", { class = class })
end
local function OPT(inner: Shape): Shape
	return S("opt", { inner = inner })
end
local function ARR(inner: Shape, max: number, cap: number?): Shape
	return S("arr", { inner = inner, max = max, cap = cap or 12 })
end
local function MAP(key: Shape, inner: Shape, max: number): Shape
	return S("map", { key = key, inner = inner, max = max })
end
local function STRUCT(fields: { [string]: Shape }): Shape
	return S("struct", { fields = fields })
end

local ENUM_NAMES = { "A", "B", "C" }
local PLAIN: { [string]: string } = {
	bool = "bool",
	u8 = "u8",
	u16 = "u16",
	u32 = "u32",
	i8 = "i8",
	i16 = "i16",
	i32 = "i32",
	f32 = "f32",
	f64 = "f64",
	C3 = "Color3",
	CF = "CFrame",
	any = "any",
}
local INT_RANGE: { [string]: { number } } = {
	u8 = { 0, 255 },
	u16 = { 0, 65535 },
	u32 = { 0, 4294967295 },
	i8 = { -128, 127 },
	i16 = { -32768, 32767 },
	i32 = { -2147483648, 2147483647 },
}

local function build(T: any, s: Shape): any
	local k = s.k
	local plain = PLAIN[k]
	if plain then
		return T[plain]
	elseif k == "int" then
		return T.int(s.lo, s.hi)
	elseif k == "u8r" then
		return T.u8(s.lo, s.hi)
	elseif k == "f32r" then
		return T.f32(s.lo, s.hi)
	elseif k == "num" then
		return T.num(s.lo, s.hi)
	elseif k == "V3" then
		return if s.mag then T.Vector3(s.mag) else T.Vector3
	elseif k == "V2" then
		return if s.mag then T.Vector2(s.mag) else T.Vector2
	elseif k == "enum" then
		return T.enum(ENUM_NAMES)
	elseif k == "EI" then
		return T.EnumItem(Enum.Material)
	elseif k == "string" then
		return if s.binary then T.string(s.max, { Binary = true }) else T.string(s.max)
	elseif k == "buffer" then
		return T.buffer(s.max)
	elseif k == "inst" then
		return T.Instance(s.class)
	elseif k == "opt" then
		return T.optional(build(T, s.inner))
	elseif k == "arr" then
		return T.array(build(T, s.inner), s.max)
	elseif k == "map" then
		return T.map(build(T, s.key), build(T, s.inner), s.max)
	elseif k == "struct" then
		local fields: { [string]: any } = {}
		for name, f in s.fields :: { [string]: Shape } do
			fields[name] = build(T, f)
		end
		return T.struct(fields)
	end
	error("DecodeFast.spec: unknown shape " .. tostring(k))
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

local F32_EDGES = { 0, NEG0, 1, -1, 0.5, 0.1, 1e-45, 1.1754942e-38, F32_MAX, -F32_MAX, 16777217, 1e10 }
local F64_EDGES = { 0, NEG0, 5e-324, 2.2250738585072014e-308, F64_MAX, -F64_MAX, 1 / 3, 1e300, -1e-300 }
local NONFINITE = { NAN, INF, -INF }
local CHUNKS = { "a", "Z", "0", " ", "\0", "\u{E9}", "\u{20AC}", "\u{10348}" }
local MATERIALS = Enum.Material:GetEnumItems()
local ANY_VALUES: { any } =
	{ 1, -2.5, "s", true, false, { 1, 2 }, { a = 1 }, Vector3.one, folderA, part, NAN, 0, buffer.fromstring("b") }

local function pick(rng: Random, list: { any }): any
	return list[rng:NextInteger(1, #list)]
end

local function genInt(rng: Random, lo: number, hi: number): number
	local roll = rng:NextNumber()
	if roll < 0.15 then
		return lo
	elseif roll < 0.3 then
		return hi
	elseif roll < 0.33 then
		return hi + 1
	end
	return rng:NextInteger(lo, hi)
end

local function genFloat(rng: Random, edges: { number }, scale: number): number
	local roll = rng:NextNumber()
	if roll < 0.05 then
		return pick(rng, NONFINITE)
	elseif roll < 0.35 then
		return pick(rng, edges)
	end
	return (rng:NextNumber() * 2 - 1) * scale
end

local function genIn(rng: Random, lo: number, hi: number): number
	local roll = rng:NextNumber()
	if roll < 0.15 then
		return lo
	elseif roll < 0.3 then
		return hi
	elseif roll < 0.35 then
		return pick(rng, NONFINITE)
	end
	return lo + (hi - lo) * rng:NextNumber()
end

local function genString(rng: Random, max: number, binary: boolean): string
	local cap = if rng:NextNumber() < 0.1 then max else math.min(max, 12)
	local target = rng:NextInteger(0, cap)
	local parts: { string } = {}
	local n = 0
	while n < target do
		local c = if binary then string.char(rng:NextInteger(0, 255)) else pick(rng, CHUNKS)
		if n + #c > target then
			break
		end
		table.insert(parts, c)
		n += #c
	end
	return table.concat(parts)
end

local function genVector(rng: Random, mag: number?, two: boolean): any
	if mag then
		local roll = rng:NextNumber()
		if roll < 0.1 then
			return if two then Vector2.new(mag, 0) else Vector3.new(0, mag, 0)
		elseif roll < 0.13 then
			return if two then Vector2.new(0, mag * 1.01) else Vector3.new(mag * 1.01, 0, 0)
		end
		local c = mag / 1.8
		local function r(): number
			return (rng:NextNumber() * 2 - 1) * c
		end
		return if two then Vector2.new(r(), r()) else Vector3.new(r(), r(), r())
	end
	local function f(): number
		return genFloat(rng, F32_EDGES, 1e4)
	end
	return if two then Vector2.new(f(), f()) else Vector3.new(f(), f(), f())
end

local function gen(rng: Random, s: Shape): any
	local k = s.k
	local range = INT_RANGE[k]
	if range then
		return genInt(rng, range[1], range[2])
	elseif k == "bool" then
		return rng:NextInteger(0, 1) == 1
	elseif k == "int" or k == "u8r" then
		return genInt(rng, s.lo, s.hi)
	elseif k == "f32" then
		return genFloat(rng, F32_EDGES, 1e6)
	elseif k == "f64" then
		return genFloat(rng, F64_EDGES, 1e12)
	elseif k == "f32r" or k == "num" then
		return genIn(rng, s.lo, s.hi)
	elseif k == "V3" then
		return genVector(rng, s.mag, false)
	elseif k == "V2" then
		return genVector(rng, s.mag, true)
	elseif k == "C3" then
		if rng:NextNumber() < 0.1 then
			return Color3.new(genFloat(rng, F32_EDGES, 10), 0, 1)
		end
		return Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber())
	elseif k == "CF" then
		local roll = rng:NextNumber()
		if roll < 0.1 then
			return CFrame.identity
		elseif roll < 0.15 then
			return CFrame.new(pick(rng, NONFINITE), 0, 0)
		end
		local pos = Vector3.new(genFloat(rng, F32_EDGES, 1e3), rng:NextNumber() * 100, rng:NextNumber() * -100)
		return CFrame.new(pos) * CFrame.Angles(rng:NextNumber() * 6, rng:NextNumber() * 6, rng:NextNumber() * 6)
	elseif k == "enum" then
		return if rng:NextNumber() < 0.05 then "Z" else pick(rng, ENUM_NAMES)
	elseif k == "EI" then
		return if rng:NextNumber() < 0.05 then Enum.KeyCode.A else pick(rng, MATERIALS)
	elseif k == "string" then
		return genString(rng, s.max, s.binary)
	elseif k == "buffer" then
		return buffer.fromstring(genString(rng, s.max, true))
	elseif k == "inst" then
		if rng:NextNumber() < 0.05 then
			return nil
		end
		local class = s.class
		return if class == "Folder" then pick(rng, { folderA, folderB }) else pick(rng, { folderA, folderB, part })
	elseif k == "opt" then
		return if rng:NextNumber() < 0.3 then nil else gen(rng, s.inner)
	elseif k == "arr" then
		local top = math.min(s.max, s.cap)
		local cnt = if rng:NextNumber() < 0.1
			then rng:NextInteger(math.max(0, top - 3), top)
			else rng:NextInteger(0, math.min(top, 6))
		local t: { any } = table.create(cnt)
		for i = 1, cnt do
			t[i] = gen(rng, s.inner)
		end
		return t
	elseif k == "map" then
		local m: { [any]: any } = {}
		for _ = 1, rng:NextInteger(0, math.min(s.max, 5)) do
			local key = gen(rng, s.key)
			if key ~= nil and key == key then
				m[key] = gen(rng, s.inner)
			end
		end
		return m
	elseif k == "struct" then
		local t: { [string]: any } = {}
		for name, f in s.fields :: { [string]: Shape } do
			t[name] = gen(rng, f)
		end
		return t
	elseif k == "any" then
		return if rng:NextNumber() < 0.15 then nil else pick(rng, ANY_VALUES)
	end
	error("DecodeFast.spec: unknown shape " .. tostring(k))
end

local function genArgs(rng: Random, shapes: { Shape }): Args
	local n = #shapes
	local values: Args = { n = n }
	for i = 1, n do
		values[i] = gen(rng, shapes[i])
	end
	return values
end

local function encodeText(side: Side, pc: any, c2s: boolean, values: Args): Encoded
	local w = side.Codec.newWriter(16, c2s)
	w.unreliable = false
	w.inlineTables = true
	local ok, st = pcall(pc.encode, w, values.n, table.unpack(values, 1, values.n))
	if not ok then
		return { text = "encode threw", bytes = nil, refs = {}, nrefs = 0 }
	end
	local refs = table.move(w.refs, 1, w.nrefs, 1, {})
	local text = string.format(
		"status=%d errArg=%d lossy=%d nodes=%d sideBytes=%d inlineNodes=%d",
		st,
		w.errArg,
		w.lossy,
		w.nodes,
		w.sideBytes,
		w.inlineNodes
	)
	local bytes: buffer? = nil
	if st == 0 then
		local b = buffer.create(w.n)
		buffer.copy(b, 0, w.buf, 0, w.n)
		bytes = b
		text ..= " bytes=" .. hex(b, w.n) .. " refs=" .. show(refs)
	end
	return { text = text, bytes = bytes, refs = refs, nrefs = w.nrefs }
end

local function decodeText(side: Side, pc: any, c2s: boolean, input: Input): string
	local Codec = side.Codec
	local refs, nrefs = input.refs, input.nrefs
	local ctx = Codec.newReadCtx(c2s, c2s)
	local walk = ""
	if c2s then
		Codec.beginFrame(ctx, if nrefs > 0 then refs else nil, nrefs)
		if nrefs > 0 then
			local ok, st, cost = pcall(Codec.walkSidecar, refs, nrefs, ctx)
			if not ok then
				return "walk threw"
			end
			walk = string.format(" walk=%d cost=%d", st, cost)
			if st ~= 0 then
				return walk
			end
		end
	else
		Codec.beginFrame(ctx, refs, 0)
	end
	Codec.beginMessage(ctx, pc.allowNonFinite)
	local argv: { any } = {}
	local ok, n, q = pcall(pc.decode, input.b, 0, input.lim, ctx, argv)
	if not ok then
		return "decode threw" .. walk
	end
	local text = string.format(
		"err=%d errArg=%d n=%s q=%s cursor=%d nodes=%d claimed=%d%s",
		ctx.err,
		ctx.errArg,
		tostring(n),
		tostring(q),
		ctx.cursor,
		ctx.nodes,
		ctx.claimed,
		walk
	)
	if c2s then
		local flags: { string } = {}
		for i = 1, nrefs do
			table.insert(flags, tostring(ctx.refFlags[i]))
		end
		text ..= " flags=" .. table.concat(flags, ",")
	end
	return text .. " argv=" .. show(argv)
end

local function note(ck: Checker, what: string, a: string, b: string)
	ck.count += 1
	if #ck.mismatches < MISMATCHES_SHOWN then
		local now, old = string.sub(a, 1, 400), string.sub(b, 1, 400)
		table.insert(ck.mismatches, string.format("%s\n    %s: %s\n    %s: %s", what, NOW.name, now, OLD.name, old))
	end
end

local lastYield = os.clock()

local function tick(ck: Checker)
	ck.work += 1
	if os.clock() - lastYield > YIELD_AFTER then
		task.wait()
		lastYield = os.clock()
	end
end

local function check(ck: Checker)
	if ck.count > 0 then
		local shown = table.concat(ck.mismatches, "\n  ")
		error(string.format("%d mismatch(es); first %d:\n  %s", ck.count, #ck.mismatches, shown), 0)
	end
end

local function sameDecode(ck: Checker, pcs: { any }, c2s: boolean, input: Input, what: string)
	tick(ck)
	local a = decodeText(NOW, pcs[1], c2s, input)
	local o = decodeText(OLD, pcs[2], c2s, input)
	if a ~= o then
		note(ck, what, a, o)
	end
end

local function copyOf(b: buffer, extra: number?): buffer
	local len = buffer.len(b)
	local c = buffer.create(len + (extra or 0))
	buffer.copy(c, 0, b, 0, len)
	return c
end

local function variant(valid: Input, b: buffer, lim: number): Input
	return { b = b, lim = lim, refs = valid.refs, nrefs = valid.nrefs }
end

local function mutate(rng: Random, valid: Input): (Input, string)
	local len = valid.lim
	local kind = rng:NextInteger(1, 6)
	if len == 0 or kind == 1 then
		local extra = rng:NextInteger(1, 3)
		local b = copyOf(valid.b, extra)
		for i = len, len + extra - 1 do
			buffer.writeu8(b, i, rng:NextInteger(0, 255))
		end
		return variant(valid, b, len + extra), "trailing bytes"
	elseif kind == 2 then
		local cut = rng:NextInteger(0, len - 1)
		return variant(valid, valid.b, cut), "cut at " .. cut
	elseif kind == 4 and len >= 4 then
		local at = rng:NextInteger(0, len - 4)
		local b = copyOf(valid.b)
		local x = pick(rng, F32S)
		buffer.writeu32(b, at, x)
		return variant(valid, b, len), string.format("f32 %08x at %d", x, at)
	elseif kind == 5 and len >= 8 then
		local at = rng:NextInteger(0, len - 8)
		local b = copyOf(valid.b)
		local x = pick(rng, F64S)
		buffer.writeu32(b, at, x[1])
		buffer.writeu32(b, at + 4, x[2])
		return variant(valid, b, len), string.format("f64 %08x%08x at %d", x[2], x[1], at)
	elseif kind == 6 and len >= 2 then
		local at = rng:NextInteger(0, len - 2)
		local b = copyOf(valid.b)
		if at + 4 <= len and rng:NextNumber() < 0.5 then
			local x = pick(rng, U32S)
			buffer.writeu32(b, at, x)
			return variant(valid, b, len), string.format("u32 %d at %d", x, at)
		end
		local x = pick(rng, U16S)
		buffer.writeu16(b, at, x)
		return variant(valid, b, len), string.format("u16 %d at %d", x, at)
	end
	local at = rng:NextInteger(0, len - 1)
	local b = copyOf(valid.b)
	local x = if rng:NextNumber() < 0.7 then pick(rng, U8S) else rng:NextInteger(0, 255)
	buffer.writeu8(b, at, x)
	return variant(valid, b, len), string.format("byte %d = %d", at, x)
end

local function slide(ck: Checker, pcs: { any }, c2s: boolean, rng: Random, valid: Input, where: string)
	local len = valid.lim
	for cut = 0, len - 1 do
		if cut < SLIDE_ALL or rng:NextInteger(1, SLIDE_SAMPLE) == 1 then
			local what = string.format("%s: cut at %d of %d", where, cut, len)
			sameDecode(ck, pcs, c2s, variant(valid, valid.b, cut), what)
		end
	end
	for at = 0, len - 1 do
		if at < SLIDE_ALL or rng:NextInteger(1, SLIDE_SAMPLE) == 1 then
			local function try(width: number, x: any)
				local b = copyOf(valid.b)
				if width == 1 then
					buffer.writeu8(b, at, x)
				elseif width == 2 then
					buffer.writeu16(b, at, x)
				elseif width == 4 then
					buffer.writeu32(b, at, x)
				else
					buffer.writeu32(b, at, x[1])
					buffer.writeu32(b, at + 4, x[2])
				end
				local what = string.format("%s: %d-byte pattern %s at %d", where, width, show(x), at)
				sameDecode(ck, pcs, c2s, variant(valid, b, len), what)
			end
			for _, x in U8S do
				try(1, x)
			end
			if at + 2 <= len then
				for _, x in U16S do
					try(2, x)
				end
			end
			if at + 4 <= len then
				for _, x in U32S do
					try(4, x)
				end
				for _, x in F32S do
					try(4, x)
				end
			end
			if at + 8 <= len then
				for _, x in F64S do
					try(8, x)
				end
			end
		end
	end
end

type RefVariant = { name: string, refs: { any }, nrefs: number }

local function refVariants(c2s: boolean, refs: { any }, nrefs: number): { RefVariant }
	local out: { RefVariant } = {}
	if c2s then
		local str = table.clone(refs)
		str[1] = "not an Instance"
		table.insert(out, { name = "C->S ref 1 a string", refs = str, nrefs = nrefs })
		local hole = table.clone(refs)
		hole[1] = nil
		table.insert(out, { name = "C->S ref 1 nil", refs = hole, nrefs = nrefs })
	else
		local hidden: { any } = {}
		for k = 1, nrefs do
			if typeof(refs[k]) ~= "Instance" then
				hidden[k] = refs[k]
			end
		end
		table.insert(out, { name = "Instances hidden", refs = hidden, nrefs = nrefs })
		local none: { any } = {}
		local shifted: { any } = table.move(refs, 2, nrefs, 1, {})
		table.insert(out, { name = "no refs", refs = none, nrefs = nrefs })
		table.insert(out, { name = "refs shifted", refs = shifted, nrefs = nrefs })
	end
	return out
end

local function randomBuffer(rng: Random, maxLen: number): buffer
	local n = rng:NextInteger(0, maxLen)
	local b = buffer.create(n)
	for i = 0, n - 1 do
		local roll = rng:NextNumber()
		local x = if roll < 0.5 then rng:NextInteger(0, 3) elseif roll < 0.6 then 255 else rng:NextInteger(0, 255)
		buffer.writeu8(b, i, x)
	end
	return b
end

local function runCase(case: Case, index: number): Checker
	local ck: Checker = { mismatches = {}, count = 0, work = 0 }
	local wire = case.wire or case.args
	for _, c2s in { false, true } do
		for _, anf in { false, true } do
			local dir = (if c2s then "C->S" else "S->C") .. (if anf then ", AllowNonFinite" else "")
			local pcs = { compile(NOW, case.args, anf, c2s), compile(OLD, case.args, anf, c2s) }
			local enc = { compile(NOW, wire, true, c2s), compile(OLD, wire, true, c2s) }
			local rng = Random.new(index * 1000 + (if c2s then 10 else 0) + (if anf then 1 else 0))
			local base: Input? = nil
			for r = 1, case.rounds or ROUNDS do
				local values = genArgs(rng, wire)
				local ea = encodeText(NOW, enc[1], c2s, values)
				local eo = encodeText(OLD, enc[2], c2s, values)
				tick(ck)
				if ea.text ~= eo.text then
					note(ck, string.format("%s round %d: encode", dir, r), ea.text, eo.text)
					continue
				end
				local b = eo.bytes
				if b == nil then
					continue
				end
				local len = buffer.len(b)
				local refs: { any }? = if eo.nrefs > 0 then eo.refs else nil
				local valid: Input = { b = b, lim = len, refs = refs, nrefs = eo.nrefs }
				local where = string.format("%s round %d (%s)", dir, r, hex(b, len))
				sameDecode(ck, pcs, c2s, valid, where)
				if eo.nrefs > 0 then
					for _, v in refVariants(c2s, eo.refs, eo.nrefs) do
						local input: Input = { b = b, lim = len, refs = v.refs, nrefs = v.nrefs }
						sameDecode(ck, pcs, c2s, input, where .. ", " .. v.name)
					end
				end
				for _ = 1, MUTATIONS do
					local input, what = mutate(rng, valid)
					sameDecode(ck, pcs, c2s, input, where .. ", " .. what)
				end
				if base == nil and len > 0 and len <= SLIDE_BASE_MAX then
					base = valid
				end
			end
			if base then
				slide(ck, pcs, c2s, rng, base, dir .. " slide")
			end
			for r = 1, RANDOM_BUFFERS do
				local b = randomBuffer(rng, 48)
				local input: Input = { b = b, lim = buffer.len(b), refs = FUZZ_REFS, nrefs = if c2s then 3 else 0 }
				local what = string.format("%s random buffer %d (%s)", dir, r, hex(b, buffer.len(b)))
				sameDecode(ck, pcs, c2s, input, what)
			end
		end
	end
	return ck
end

local ENTITY = STRUCT({
	id = U16,
	position = V3,
	orientation = V3,
	health = U8,
	alive = BOOL,
	moving = BOOL,
	crouched = BOOL,
})
local INPUT = STRUCT({ seq = U16, moveX = I8, moveZ = I8, yaw = F32, jump = BOOL, sprint = BOOL })
local PAIR = STRUCT({ a = U8, b = F32 })
local EVERY_FIELDS: { [string]: Shape } = {
	b = BOOL,
	u8 = U8,
	u16 = U16,
	u32 = U32,
	i8 = I8,
	i16 = I16,
	i32 = I32,
	f32 = F32,
	f64 = F64,
	c3 = C3,
	cf = CF,
	e = ENUM,
	ei = EI,
}
local function every(v3: Shape, v2: Shape, r: Shape, q: Shape, fr: Shape, nm: Shape): Shape
	local fields = table.clone(EVERY_FIELDS)
	fields.v3, fields.v2, fields.r, fields.q, fields.fr, fields.nm = v3, v2, r, q, fr, nm
	return STRUCT(fields)
end
local EVERY = every(V3M(10), V2M(5), INT(-5, 5), U8R(10, 20), F32R(-1, 1), NUM(0, 100))
local EVERY_WIRE = every(V3, V2, I8, U8, F32, F64)
local LOOSE = STRUCT({ name = STR(8), tag = OPT(U8), hp = U8, pos = V3, data = BUF(4) })
local HOLDER = STRUCT({ who = INST(), n = U8, maybe = OPT(INST("Folder")) })

local CASES: { Case } = {}
local SINGLES: { { any } } = {
	{ "bool", BOOL },
	{ "u8", U8 },
	{ "u16", U16 },
	{ "u32", U32 },
	{ "i8", I8 },
	{ "i16", I16 },
	{ "i32", I32 },
	{ "f32", F32 },
	{ "f64", F64 },
	{ "Vector3", V3 },
	{ "Vector2", V2 },
	{ "Color3", C3 },
	{ "CFrame", CF },
	{ "enum", ENUM },
	{ "EnumItem", EI },
	{ "T.int(-5, 5) from any i8", INT(-5, 5), I8 },
	{ "T.int(0, 1000) from any u16", INT(0, 1000), U16 },
	{ "T.int(-40000, 40000) from any i32", INT(-40000, 40000), I32 },
	{ "T.u8(10, 20) from any u8", U8R(10, 20), U8 },
	{ "T.f32(-1, 1) from any f32", F32R(-1, 1), F32 },
	{ "T.num(0, 100) from any f64", NUM(0, 100), F64 },
	{ "T.Vector3(10) from any Vector3", V3M(10), V3 },
	{ "T.Vector2(5) from any Vector2", V2M(5), V2 },
}
for _, s in SINGLES do
	table.insert(CASES, { name = "one " .. s[1], args = { s[2] }, wire = if s[3] then { s[3] } else nil })
end
local MORE: { Case } = {
	{ name = "a tuple of every integer, bool and float", args = { BOOL, U8, U16, U32, I8, I16, I32, F32, F64 } },
	{
		name = "a tuple of the other fixed types, bounded",
		args = { V3M(10), V2M(5), C3, CF, ENUM, EI, INT(-5, 5), F32R(-1, 1), NUM(0, 100) },
		wire = { V3, V2, C3, CF, ENUM, EI, I8, F32, F64 },
	},
	{ name = "a fixed tuple, then a string", args = { U8, V3, STR(8) } },
	{ name = "the bench Entity", args = { ENTITY } },
	{ name = "the bench Input", args = { INPUT } },
	{ name = "a struct of every fixed type", args = { EVERY }, wire = { EVERY_WIRE } },
	{ name = "a variable-size struct (string, optional, buffer)", args = { LOOSE } },
	{ name = "a struct with Instances", args = { HOLDER } },
	{ name = "a struct with T.any", args = { STRUCT({ x = ANY, y = U8 }) } },
	{
		name = "a struct holding a struct, an array and a map",
		args = { STRUCT({ inner = STRUCT({ a = U8, b = V3 }), list = ARR(U8, 4), m = MAP(STR(4), U8, 4) }) },
	},
	{ name = "a struct after another argument", args = { U8, ENTITY } },
	{ name = "two structs", args = { PAIR, ENTITY } },
	{ name = "Instances around structs", args = { U8, INST(), ENTITY, OPT(INST("Folder")) } },
	{ name = "an optional struct", args = { OPT(ENTITY) } },
	{ name = "an optional optional struct", args = { OPT(OPT(PAIR)) } },
	{ name = "Entity[100] (fireall100)", args = { ARR(ENTITY, 100, 100) }, rounds = 40 },
	{ name = "Input[1000] (a u16 count)", args = { ARR(INPUT, 1000, 40) }, rounds = 80 },
	{ name = "a struct array with a u32 count", args = { ARR(PAIR, 70000) } },
	{ name = "an array of every-fixed-type structs", args = { ARR(EVERY, 8) }, wire = { ARR(EVERY_WIRE, 8) } },
	{ name = "an array of variable-size structs", args = { ARR(LOOSE, 8) } },
	{ name = "an array of structs with Instances", args = { ARR(HOLDER, 4) } },
	{ name = "an array of optional structs", args = { ARR(OPT(PAIR), 6) } },
	{ name = "arrays of arrays of structs", args = { ARR(ARR(PAIR, 3), 3) } },
	{ name = "maps of structs", args = { MAP(U8, ENTITY, 4), MAP(STR(4), HOLDER, 3) } },
	{
		name = "strings: valid and invalid UTF-8 on the wire",
		args = { STR(16), STRUCT({ s = STR(8), t = U8 }), ARR(STRUCT({ s = STR(4) }), 3) },
		wire = { STR(16, true), STRUCT({ s = STR(8, true), t = U8 }), ARR(STRUCT({ s = STR(4, true) }), 3) },
	},
	{
		name = "scalar arrays (the efast loops)",
		args = { ARR(BOOL, 100), ARR(I16, 8), ARR(F32R(-1, 1), 8) },
		wire = { ARR(BOOL, 100), ARR(I16, 8), ARR(F32, 8) },
	},
	{
		name = "integer arrays with narrowed bounds (O10's range check in the efast loop)",
		args = { ARR(INT(-5, 5), 8), ARR(U8R(10, 20), 8), ARR(INT(0, 1000), 8) },
		wire = { ARR(I8, 8), ARR(U8, 8), ARR(U16, 8) },
	},
	{
		name = "maps with float, enum and EnumItem keys",
		args = { MAP(F32, U8, 4), MAP(F64, U8, 4), MAP(ENUM, U8, 3), MAP(EI, U8, 3) },
	},
	{ name = "an array of structs with T.any (nil too)", args = { ARR(STRUCT({ x = ANY, y = U8 }), 4) } },
	{ name = "a struct of optional fields only (no template)", args = { STRUCT({ a = OPT(U8), b = OPT(BOOL) }) } },
	{
		name = "optional-only structs nested and in an array",
		args = { STRUCT({ inner = STRUCT({ a = OPT(U8) }), n = U8 }), ARR(STRUCT({ a = OPT(U8) }), 4) },
	},
}
for _, c in MORE do
	table.insert(CASES, c)
end

local SVC = "DecodeFast"
type Route = { name: string, args: { Shape }?, wire: { Shape }?, ordered: boolean? }
local ROUTES: { Route } = {
	{ name = "Bool", args = { BOOL } },
	{ name = "U8", args = { U8 } },
	{ name = "U16", args = { U16 } },
	{ name = "U32", args = { U32 } },
	{ name = "I8", args = { I8 } },
	{ name = "I16", args = { I16 } },
	{ name = "I32", args = { I32 } },
	{ name = "F32", args = { F32 } },
	{ name = "F64", args = { F64 } },
	{ name = "Vec", args = { V3 } },
	{ name = "VecMax", args = { V3M(10) }, wire = { V3 } },
	{ name = "Small", args = { INT(-5, 5) }, wire = { I8 } },
	{ name = "Unit", args = { F32R(-1, 1) }, wire = { F32 } },
	{ name = "Ord", args = { BOOL }, ordered = true },
	{ name = "OrdVec", args = { V3 }, ordered = true },
	{ name = "Pair", args = { U8, BOOL } },
	{ name = "Ent", args = { ENTITY } },
	{ name = "Ents", args = { ARR(ENTITY, 100, 5) } },
	{ name = "Need", args = { INST() } },
	{ name = "Maybe", args = { OPT(BOOL) } },
	{ name = "Untyped" },
}
local SCALAR_BYTES: { [string]: number } =
	{ bool = 1, u8 = 1, u16 = 2, u32 = 4, i8 = 1, i16 = 2, i32 = 4, f32 = 4, f64 = 8, V3 = 12 }

local function makeModel(): any
	local F, K = NOW.C.MemberFlag, NOW.C.Kind
	local members: { any } = {}
	for id, r in ROUTES do
		local flags = F.AllowNonFinite
		if r.ordered then
			flags = bit32.bor(flags, F.Unreliable, F.Ordered)
		end
		local args = if r.args then buildList(NOW.Schema.T, r.args) else nil
		if args then
			flags = bit32.bor(flags, F.HasArgs)
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
			args = args,
			returns = nil,
		})
	end
	return {
		proto = NOW.C.PROTO,
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

type Outcome = { lines: { string }, reason: string?, messagesIn: number, dropped: number }

local function oracle(decoders: { any }, frame: buffer, refs: { any }?): Outcome
	local Codec = OLD.Codec
	local ctx = Codec.newReadCtx(false, false)
	Codec.beginFrame(ctx, refs, 0)
	local out: Outcome = { lines = {}, reason = nil, messagesIn = 0, dropped = 0 }
	local last: { [number]: number } = {}
	local len = buffer.len(frame)
	local p = 0
	while p < len do
		local h, q = Codec.readHead(frame, p, len)
		local r = ROUTES[h]
		assert(r ~= nil, "DecodeFast.spec: a generated frame names an unknown route")
		local seq = -1
		if r.ordered then
			if q + 2 > len then
				out.reason = "truncated signal"
				return out
			end
			seq = buffer.readu16(frame, q)
			q += 2
		end
		Codec.beginMessage(ctx, true)
		local argv: { any } = {}
		local n, q2 = decoders[h].decode(frame, q, len, ctx, argv)
		local e = ctx.err
		if e ~= 0 and e ~= D_MISSING then
			out.reason = "bad payload for " .. SVC .. "." .. r.name
			return out
		end
		out.messagesIn += 1
		local stale = false
		if seq >= 0 then
			local l = last[h]
			if l ~= nil then
				local d = (seq - l) % 65536
				stale = d == 0 or d >= 32768
			end
			if not stale then
				last[h] = seq
			end
		end
		if not stale then
			if e == D_MISSING then
				out.dropped += 1
			else
				table.insert(out.lines, h .. ":" .. show(table.pack(table.unpack(argv, 1, n))))
			end
		end
		p = q2
	end
	return out
end

local function throughClient(frame: buffer, refs: { any }?): Outcome
	ClientNet._reset()
	Calls._reset()
	Proxy._reset()
	ClientNet._test.setClock(function(): number
		return 1000
	end)
	ClientNet._test.loadManifest(makeModel())
	Log._reset()
	local out: Outcome = { lines = {}, reason = nil, messagesIn = 0, dropped = 0 }
	Log._test.setSink(noop, function(line: string)
		local why = string.match(line, "server frame %((.-)%)")
		if why and out.reason == nil then
			out.reason = why
		end
	end)
	for id, route in ClientNet.routes() do
		route.signal:Connect(function(...: any)
			table.insert(out.lines, id .. ":" .. show(table.pack(...)))
		end)
	end
	ClientNet._test.receive(frame, refs)
	local stats = ClientNet.getStats()
	out.messagesIn = stats.MessagesIn
	out.dropped = stats.SignalsDropped
	Log._reset()
	return out
end

local function outcomeText(o: Outcome): string
	return string.format(
		"in=%d dropped=%d reason=%s\n      %s",
		o.messagesIn,
		o.dropped,
		tostring(o.reason),
		table.concat(o.lines, "\n      ")
	)
end

type Msg = { id: number, body: buffer, refs: { any } }

local function frameOf(msgs: { Msg }, cutLast: number?): (buffer, { any }?)
	local total = 0
	for _, m in msgs do
		total += 1 + buffer.len(m.body)
	end
	if cutLast then
		total -= buffer.len(msgs[#msgs].body) - cutLast
	end
	local b = buffer.create(total)
	local refs: { any } = {}
	local p = 0
	for i, m in msgs do
		buffer.writeu8(b, p, m.id)
		p += 1
		local n = if cutLast and i == #msgs then cutLast else buffer.len(m.body)
		buffer.copy(b, p, m.body, 0, n)
		p += n
		for _, ref in m.refs do
			table.insert(refs, ref)
		end
	end
	return b, if #refs > 0 then refs else nil
end

local function message(rng: Random, encoders: { any }, id: number, seqs: { [number]: number }): Msg
	local r = ROUTES[id]
	for _ = 1, 50 do
		local w = OLD.Codec.newWriter(32, false)
		w.inlineTables = true
		if r.ordered then
			local s = seqs[id] or rng:NextInteger(0, 65535)
			local roll = rng:NextNumber()
			s = if roll < 0.7 then (s + 1) % 65536 elseif roll < 0.85 then s else (s - rng:NextInteger(1, 3)) % 65536
			seqs[id] = s
			OLD.Codec.writeU16(w, s)
		end
		local values: Args
		if r.args then
			values = genArgs(rng, r.wire or r.args)
		else
			values = { n = rng:NextInteger(0, 3) }
			for i = 1, values.n do
				values[i] = if rng:NextNumber() < 0.2 then nil else pick(rng, ANY_VALUES)
			end
		end
		local st = encoders[id].encode(w, values.n, table.unpack(values, 1, values.n))
		if st == 0 then
			local body = buffer.create(w.n)
			buffer.copy(body, 0, w.buf, 0, w.n)
			return { id = id, body = body, refs = table.move(w.refs, 1, w.nrefs, 1, {}) }
		end
	end
	error("DecodeFast.spec: no encodable value for route " .. r.name)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.afterAll(function()
		ClientNet._reset()
		Calls._reset()
		Proxy._reset()
		Log._reset()
		Loren.Testing.Reset()
		folderA:Destroy()
		folderB:Destroy()
		part:Destroy()
	end)

	describe("compiled shapes (fixed runs, keys, templates)", function()
		local T = NOW.Schema.T
		local prog = NOW.Schema._test.prog

		it("marks a prog of fixed-size required fields with its size, offsets and keys", function()
			local p = prog({ T.u8, T.bool, T.Vector3, T.f64 })
			expect(p.fixed).toBe(22)
			expect(p.offs).toEqual({ 0, 1, 2, 14 })
			expect(p.keys).toEqual({ 1, 2, 3, 4 })
			expect(p.tpl).toBe(false)
			expect(prog({ T.u8, T.optional(T.u8) }).fixed).toBe(0)
			expect(prog({ T.u8, T.string }).fixed).toBe(0)
			expect(prog({ T.Instance() }).fixed).toBe(0)
			expect(prog({}).fixed).toBe(0)
		end)

		it("lays out the bench Entity as one 30-byte run in field-name order", function()
			local root = prog({ build(T, ENTITY) })
			expect(root.fixed).toBe(0)
			local sp = root.sub[1]
			expect(sp.fixed).toBe(30)
			expect(sp.keys).toEqual({ "alive", "crouched", "health", "id", "moving", "orientation", "position" })
			expect(sp.offs).toEqual({ 0, 1, 2, 3, 5, 6, 18 })
		end)

		it("builds a frozen template only when every field always gets a value on that side", function()
			local EMPTY = NOW.Schema._test.EMPTY
			local sp = prog({ T.struct({ a = T.u8, c = T.string }) }).sub[1]
			expect(table.isfrozen(sp.tpl)).toBe(true)
			expect(getmetatable(sp.tpl)).toBeNil()
			expect(sp.tpl).toEqual({ a = false, c = false })
			expect(sp.htpl).toBe(sp.tpl)
			expect(sp.fixed).toBe(0)
			for _, s in { T.struct({ a = T.u8, b = T.optional(T.u8) }), T.struct({ a = T.u8, b = T.any }) } do
				local p = prog({ s }).sub[1]
				expect(p.tpl).toBe(false)
				expect(p.htpl).toBe(false)
			end
			local mixed = prog({ T.struct({ a = T.string, b = T.enum({ "X" }), c = T.Instance() }) }).sub[1]
			expect(mixed.tpl).toBe(false)
			expect(mixed.htpl).toEqual({ a = false, b = false, c = false })
			local fixed = prog({ T.struct({ a = T.u8, b = T.EnumItem(Enum.Material) }) }).sub[1]
			expect(fixed.fixed).toBe(3)
			expect(fixed.tpl).toBe(EMPTY)
			expect(fixed.htpl).toEqual({ a = false, b = false })
			expect(table.isfrozen(EMPTY)).toBe(true)
			expect(next(EMPTY)).toBeNil()
		end)

		it("checks integer bounds on hostile decode only when they are narrower than the type", function()
			local p = prog({ T.u8, T.u8(1, 5), T.int(-5, 5), T.i32, T.u32, T.int(0, 65535), T.f32 })
			expect(p.rng).toEqual({ false, true, true, false, false, false, false })
		end)

		it("decodes each struct into a fresh, unfrozen table without a metatable", function()
			for _, c2s in { false, true } do
				local pc = NOW.Schema.compile({ build(T, ENTITY) }, false, MAX_S2C, false)
				local arr = NOW.Schema.compile({ T.array(build(T, ENTITY), 4) }, false, MAX_S2C, false)
				local value = {
					id = 7,
					position = Vector3.one,
					orientation = Vector3.zero,
					health = 9,
					alive = true,
					moving = false,
					crouched = true,
				}
				local function decodeOne(codec: any, ...: any): any
					local w = NOW.Codec.newWriter(64, c2s)
					expect(codec.encode(w, select("#", ...), ...)).toBe(0)
					local ctx = NOW.Codec.newReadCtx(c2s, c2s)
					NOW.Codec.beginFrame(ctx, nil, 0)
					NOW.Codec.beginMessage(ctx, false)
					local argv: { any } = {}
					local n, q = codec.decode(w.buf, 0, w.n, ctx, argv)
					expect(ctx.err).toBe(0)
					expect(n).toBe(1)
					expect(q).toBe(w.n)
					return argv[1]
				end
				local a = decodeOne(pc, value)
				local b = decodeOne(pc, value)
				expect(a).never.toBe(b)
				expect(table.isfrozen(a)).toBe(false)
				expect(getmetatable(a)).toBeNil()
				expect(a).toEqual(value)
				a.health = 200
				a.extra = true
				expect(decodeOne(pc, value)).toEqual(value)
				local list = decodeOne(arr, { value, value, value })
				expect(#list).toBe(3)
				expect(list[1]).never.toBe(list[2])
				expect(table.isfrozen(list[3])).toBe(false)
				expect(list[2]).toEqual(value)
			end
		end)

		it("reads one required bool, integer, float or Vector3 inline on the client (Schema.scalarOp)", function()
			local op = NOW.C.SchemaOp
			local scalarOp = NOW.Schema.scalarOp
			expect(scalarOp({ T.bool })).toBe(op.BOOL)
			expect(scalarOp({ T.u8 })).toBe(op.U8)
			expect(scalarOp({ T.int(-5, 5) })).toBe(op.I8)
			expect(scalarOp({ T.u32 })).toBe(op.U32)
			expect(scalarOp({ T.f32(-1, 1) })).toBe(op.F32)
			expect(scalarOp({ T.f64 })).toBe(op.F64)
			expect(scalarOp({ T.Vector3 })).toBe(op.VECTOR3)
			expect(scalarOp({ T.Vector3(10) })).toBe(op.VECTOR3)
			local others: { { any } } =
				{ { T.optional(T.bool) }, { T.Vector2 }, { T.CFrame }, { T.string }, { T.bool, T.bool }, {} }
			for _, descs in others do
				expect(scalarOp(descs)).toBe(0)
			end
			expect(scalarOp(nil)).toBe(0)
		end)
	end)

	describe("decoders against the frozen v2 interpreter (values, status, errArg, cursors, flags, argv)", function()
		for index, case in CASES do
			it(case.name, function()
				local ck = runCase(case, index)
				if ck.count > 0 then
					local shown = table.concat(ck.mismatches, "\n  ")
					error(string.format("%d mismatch(es); first %d:\n  %s", ck.count, #ck.mismatches, shown), 0)
				end
			end, { timeout = 120 })
		end
	end)

	describe("ClientNet frames against the frozen v2 decoder (O1 inline scalars and the codec path)", function()
		local decoders: { any } = {}
		local encoders: { any } = {}

		t.beforeAll(function()
			Loren.Testing.Reset({ Offline = true })
			for id, r in ROUTES do
				decoders[id] = if r.args
					then OLD.Schema.compile(buildList(OLD.Schema.T, r.args), true, MAX_S2C, false)
					else OLD.Schema.compile(nil, true, MAX_S2C, false)
				encoders[id] = if r.args
					then OLD.Schema.compile(buildList(OLD.Schema.T, r.wire or r.args), true, MAX_S2C, false)
					else decoders[id]
			end
		end)

		local function same(frame: buffer, refs: { any }?, what: string, ck: Checker)
			tick(ck)
			local want = outcomeText(oracle(decoders, frame, refs))
			local got = outcomeText(throughClient(frame, refs))
			if got ~= want then
				note(ck, what .. " (" .. hex(frame, buffer.len(frame)) .. ")", got, want)
			end
		end

		local function leavesTail(id: number, body: buffer, refs: { any }): boolean
			local rctx = OLD.Codec.newReadCtx(false, false)
			OLD.Codec.beginFrame(rctx, refs, 0)
			OLD.Codec.beginMessage(rctx, true)
			local start = if ROUTES[id].ordered then 2 else 0
			local ok, _, q = pcall(decoders[id].decode, body, start, buffer.len(body), rctx, {})
			local e = rctx.err
			return ok and (e == 0 or e == D_MISSING) and q < buffer.len(body)
		end

		local function messageOf(name: string, ...: any): Msg
			local id = 0
			for i, r in ROUTES do
				if r.name == name then
					id = i
				end
			end
			assert(id > 0, "DecodeFast.spec: no route " .. name)
			local w = OLD.Codec.newWriter(64, false)
			w.inlineTables = true
			assert(encoders[id].encode(w, select("#", ...), ...) == 0, "DecodeFast.spec: encode failed for " .. name)
			local body = buffer.create(w.n)
			buffer.copy(body, 0, w.buf, 0, w.n)
			return { id = id, body = body, refs = table.move(w.refs, 1, w.nrefs, 1, {}) }
		end

		it("delivers every edge value of each inline scalar, then stops at a bad or cut one", function()
			local ck: Checker = { mismatches = {}, count = 0, work = 0 }
			for id, r in ROUTES do
				local a = r.args
				local k = if a and #a == 1 then a[1].k else nil
				local width = if k then SCALAR_BYTES[k] else nil
				if k == "int" or k == "f32r" then
					width = if k == "int" then 1 else 4
				end
				if width == nil then
					continue
				end
				local bodies: { buffer } = {}
				local seqBytes = if r.ordered then 2 else 0
				local function add(fill: (buffer, number) -> ())
					local body = buffer.create(seqBytes + (width :: number))
					if r.ordered then
						buffer.writeu16(body, 0, #bodies + 1)
					end
					fill(body, seqBytes)
					table.insert(bodies, body)
				end
				local w = width :: number
				if w == 1 then
					for _, x in U8S do
						add(function(b: buffer, o: number)
							buffer.writeu8(b, o, x)
						end)
					end
				elseif w == 2 then
					for _, x in U16S do
						add(function(b: buffer, o: number)
							buffer.writeu16(b, o, x)
						end)
					end
				elseif w == 4 then
					for _, x in (if k == "f32" or k == "f32r" then F32S else U32S) :: { number } do
						add(function(b: buffer, o: number)
							buffer.writeu32(b, o, x)
						end)
					end
				elseif w == 8 then
					for _, x in F64S do
						add(function(b: buffer, o: number)
							buffer.writeu32(b, o, x[1])
							buffer.writeu32(b, o + 4, x[2])
						end)
					end
				else
					for c = 0, 2 do
						for _, x in F32S do
							add(function(b: buffer, o: number)
								buffer.writeu32(b, o, 0x3F800000)
								buffer.writeu32(b, o + 4, 0x3F800000)
								buffer.writeu32(b, o + 8, 0x3F800000)
								buffer.writeu32(b, o + 4 * c, x)
							end)
						end
					end
				end
				local all: { Msg } = {}
				for i, body in bodies do
					local msg: Msg = { id = id, body = body, refs = {} }
					table.insert(all, msg)
					local frame = frameOf({ msg })
					same(frame, nil, string.format("%s edge value %d", r.name, i), ck)
				end
				local frame = frameOf(all)
				same(frame, nil, r.name .. " all edge values", ck)
				for cut = 0, buffer.len(all[#all].body) - 1 do
					local cutFrame = frameOf(all, cut)
					same(cutFrame, nil, string.format("%s cut at %d", r.name, cut), ck)
				end
			end
			check(ck)
		end, { timeout = 120 })

		it("matches on random frames of mixed routes, with a corrupt or cut last message", function()
			local ck: Checker = { mismatches = {}, count = 0, work = 0 }
			local rng = Random.new(20260929)
			for f = 1, CLIENT_FRAMES do
				local seqs: { [number]: number } = {}
				local msgs: { Msg } = {}
				for _ = 1, rng:NextInteger(1, 10) do
					table.insert(msgs, message(rng, encoders, rng:NextInteger(1, #ROUTES), seqs))
				end
				local roll = rng:NextNumber()
				local frame: buffer, refs: { any }?
				local what = "frame " .. f
				if roll < 0.2 then
					local last = msgs[#msgs]
					local cut = rng:NextInteger(0, math.max(0, buffer.len(last.body) - 1))
					frame, refs = frameOf(msgs, cut)
					what ..= ", last message cut at " .. cut
				elseif roll < 0.45 then
					local last = msgs[#msgs]
					if buffer.len(last.body) > 0 then
						local body = copyOf(last.body)
						local at = rng:NextInteger(0, buffer.len(body) - 1)
						local x = if rng:NextNumber() < 0.6 then pick(rng, U8S) else rng:NextInteger(0, 255)
						buffer.writeu8(body, at, x)
						if not leavesTail(last.id, body, last.refs) then
							msgs[#msgs] = { id = last.id, body = body, refs = last.refs }
							what ..= string.format(", last message byte %d = %d", at, x)
						end
					end
					frame, refs = frameOf(msgs)
				else
					frame, refs = frameOf(msgs)
				end
				same(frame, refs, what, ck)
				if refs then
					local hidden: { any } = {}
					for i, ref in refs do
						if typeof(ref) ~= "Instance" then
							hidden[i] = ref
						end
					end
					same(frame, hidden, what .. ", Instances hidden", ck)
				end
			end
			check(ck)
		end, { timeout = 120 })

		it("keeps an Ordered scalar's order checks after the decode (stale, repeated, wrapped, bad)", function()
			local ck: Checker = { mismatches = {}, count = 0, work = 0 }
			local ORD = 0
			for id, r in ROUTES do
				if r.name == "Ord" then
					ORD = id
				end
			end
			local function msg(seq: number, byte: number): Msg
				local body = buffer.create(3)
				buffer.writeu16(body, 0, seq)
				buffer.writeu8(body, 2, byte)
				return { id = ORD, body = body, refs = {} }
			end
			local frames: { { Msg } } = {
				{ msg(5, 1), msg(4, 0), msg(5, 1), msg(6, 0) },
				{ msg(65534, 1), msg(65535, 0), msg(0, 1), msg(65535, 1) },
				{ msg(1, 1), msg(1, 2) },
				{ msg(9, 0), msg(3, 7) },
				{ msg(9, 0), msg(10, 0x80) },
			}
			for i, msgs in frames do
				same(frameOf(msgs), nil, "Ordered frame " .. i, ck)
				same(frameOf(msgs, 1), nil, "Ordered frame " .. i .. ", last seq cut", ck)
			end
			check(ck)
		end)

		it("reads inline scalars and structs right after Signals whose Instance arrived nil", function()
			local ck: Checker = { mismatches = {}, count = 0, work = 0 }
			local ent = {
				id = 7,
				position = Vector3.one,
				orientation = Vector3.zero,
				health = 9,
				alive = true,
				moving = false,
				crouched = true,
			}
			local msgs: { Msg } = {
				messageOf("Need", folderA),
				messageOf("Bool", true),
				messageOf("Ent", ent),
				messageOf("Need", part),
				messageOf("U8", 7),
			}
			local frame, refs = frameOf(msgs)
			assert(refs ~= nil, "DecodeFast.spec: the Need messages carry refs")
			local variants: { { any } } = { refs, {}, { nil :: any, part }, { folderA } }
			for i, seen in variants do
				same(frame, seen, "Instance frame, refs variant " .. i, ck)
			end
			for cut = 0, buffer.len(msgs[#msgs].body) - 1 do
				local cutFrame, cutRefs = frameOf(msgs, cut)
				same(cutFrame, cutRefs, string.format("Instance frame, last message cut at %d", cut), ck)
				same(cutFrame, {}, string.format("Instance frame, Instances hidden, last message cut at %d", cut), ck)
			end
			check(ck)
		end)
	end)

	describe("ClientNet replies against the frozen v2 decoder (O23 arities, struct and fixed returns)", function()
		type Method = { name: string, returns: { Shape }? }
		local METHODS: { Method } = {
			{ name = "Any" },
			{ name = "Ent", returns = { ENTITY } },
			{ name = "Ents", returns = { ARR(ENTITY, 100, 5) } },
			{ name = "Two", returns = { U8, BOOL } },
			{ name = "Vec", returns = { V3 } },
		}
		local decoders: { any } = {}
		local encoders: { any } = {}

		t.beforeAll(function()
			Loren.Testing.Reset({ Offline = true })
			for id, m in METHODS do
				local returns = m.returns
				decoders[id] = if returns
					then OLD.Schema.compile(buildList(OLD.Schema.T, returns), true, MAX_S2C, false)
					else OLD.Schema.compile(nil, true, MAX_S2C, false)
				encoders[id] = decoders[id]
			end
		end)

		local function replyModel(): any
			local F, K = NOW.C.MemberFlag, NOW.C.Kind
			local members: { any } = {}
			for id, m in METHODS do
				local returns = if m.returns then buildList(NOW.Schema.T, m.returns) else nil
				table.insert(members, {
					name = m.name,
					kind = K.Method,
					route = id,
					flags = bit32.bor(F.AllowNonFinite, if returns then F.HasReturns else 0),
					timeout = 60,
					rate = 1000,
					burst = 1000,
					backlog = 0,
					args = nil,
					returns = returns,
				})
			end
			local model = makeModel()
			model.services = { { name = SVC, members = members } }
			return model
		end

		local function reply(id: number, values: Args): (string, string)
			ClientNet._reset()
			Calls._reset()
			Proxy._reset()
			ClientNet._test.setClock(function(): number
				return 1000
			end)
			local sent: { buffer } = {}
			ClientNet._test.setFire(function(_: boolean, frame: buffer)
				table.insert(sent, frame)
			end)
			ClientNet._test.loadManifest(replyModel())
			local got: any = "not resumed"
			task.spawn(function()
				got = table.pack(ClientNet.call(ClientNet.routes()[id], true, 0))
			end)
			ClientNet._test.flushNow()
			assert(#sent == 1, "DecodeFast.spec: the call was not sent")
			local call = sent[1]
			local mlen, p = NOW.Codec.readVarint(call, 5, buffer.len(call))
			local _, q = NOW.Codec.readHead(call, p, p + mlen)
			local callId = buffer.readu16(call, q)
			local w = OLD.Codec.newWriter(64, false)
			w.inlineTables = true
			OLD.Codec.writeU8(w, OLD.C.Op.OK)
			OLD.Codec.writeU16(w, callId)
			assert(encoders[id].encode(w, values.n, table.unpack(values, 1, values.n)) == 0, "reply encode failed")
			local frame = buffer.create(w.n)
			buffer.copy(frame, 0, w.buf, 0, w.n)
			local refs: { any }? = if w.nrefs > 0 then table.move(w.refs, 1, w.nrefs, 1, {}) else nil
			local ctx = OLD.Codec.newReadCtx(false, false)
			OLD.Codec.beginFrame(ctx, refs, 0)
			OLD.Codec.beginMessage(ctx, true)
			local argv: { any } = {}
			local n, qe = decoders[id].decode(frame, 3, w.n, ctx, argv)
			assert(ctx.err == 0 and qe == w.n, "DecodeFast.spec: the frozen decoder refused a valid reply")
			local want = show(table.pack(true, table.unpack(argv, 1, n)))
			ClientNet._test.receive(frame, refs)
			return show(got), want
		end

		local function methodId(name: string): number
			for i, m in METHODS do
				if m.name == name then
					return i
				end
			end
			error("DecodeFast.spec: no method " .. name)
		end

		it("resolves untyped replies (0-5 values, nil holes) and struct, tuple and array replies", function()
			local ck: Checker = { mismatches = {}, count = 0, work = 0 }
			local function try(name: string, values: Args)
				tick(ck)
				local got, want = reply(methodId(name), values)
				if got ~= want then
					note(ck, name .. " " .. show(values), got, want)
				end
			end
			local untyped: { Args } = {
				{ n = 0 },
				{ n = 1, 1 },
				{ n = 1, nil },
				{ n = 2, 1, nil },
				{ n = 2, nil, 2 },
				{ n = 3, nil, "x", nil },
				{ n = 4, 1, nil, 3, nil },
				{ n = 5, 1, 2, 3, 4, 5 },
			}
			for _, values in untyped do
				try("Any", values)
			end
			local rng = Random.new(20260930)
			for _, name in { "Ent", "Ents", "Two", "Vec" } do
				local id = methodId(name)
				local shapes = METHODS[id].returns :: { Shape }
				local sent = 0
				for _ = 1, 200 do
					local values = genArgs(rng, shapes)
					local w = OLD.Codec.newWriter(64, false)
					w.inlineTables = true
					if encoders[id].encode(w, values.n, table.unpack(values, 1, values.n)) == 0 then
						try(name, values)
						sent += 1
						if sent >= 20 then
							break
						end
					end
				end
				assert(sent > 0, "DecodeFast.spec: no encodable reply for " .. name)
			end
			check(ck)
		end, { timeout = 120 })
	end)
end
