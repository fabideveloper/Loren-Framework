--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local FrozenV2 = ServerStorage.LorenTest.Frozen.v2
local Server = ServerScriptService.LorenServer

local Loren = require(Runtime) :: any
local C = require(Runtime.Constants) :: any
local Codec = require(Runtime.Codec) :: any
local Schema = require(Runtime.Schema) :: any
local Config = require(Runtime.Config) :: any
local Log = require(Runtime.Log) :: any
local Routes = require(Server.Routes) :: any
local Transport = require(Server.Transport) :: any
local Outbox = require(Server.Outbox) :: any
local Dispatch = require(Server.Dispatch) :: any
local ServerSignal = require(Server.ServerSignal) :: any
local Limits = require(Server.Limits) :: any
local Violations = require(Server.Violations) :: any

type Side = { name: string, C: any, Codec: any, Schema: any }
type Shape = { [string]: any }
type Args = { n: number, [number]: any }
type Checker = { mismatches: { string }, count: number }
type RouteDef = { name: string, args: { Shape }?, unreliable: boolean?, ordered: boolean?, anf: boolean? }
type PModel = { p: any, state: string, rel: { string }, refs: { any }, unr: { string } }
type Model = {
	defs: { RouteDef },
	olds: { [string]: any },
	seqs: { [string]: number },
	players: { PModel },
	of: { [any]: PModel },
	messagesOut: number,
	dropped: number,
	outboxDropped: number,
	ck: Checker,
}

local NOW: Side = { name = "runtime", C = C, Codec = Codec, Schema = Schema }
local OLD: Side = {
	name = "frozen v2",
	C = require(FrozenV2.Constants) :: any,
	Codec = require(FrozenV2.Codec) :: any,
	Schema = require(FrozenV2.Schema) :: any,
}

local K = C.Kind
local OP = C.Op
local LIM = C.Limit
local PREFIX = C.PREFIX
local SEAL = LIM.UNRELIABLE_SEAL
local KEEP = 4 * LIM.S2C_SEAL
local MAX_C2S = LIM.MAX_ARGS_C2S
local MAX_S2C = LIM.MAX_ARGS_S2C
local ENCODE_NAME: { [number]: string } = C.EncodeName
local E = C.Encode
local NAN, INF = 0 / 0, math.huge
local NEG0 = -1 / INF
local F32_MAX = 3.4028234663852886e38
local F64_MAX = 1.7976931348623157e308
local SENTINEL = 0xA5
local ROUNDS = 90
local YIELD_AFTER = 0.05
local MISMATCHES_SHOWN = 4
local LEAF_EDGE = 0.25
local MSG_SELF = PREFIX .. "Call Signals.X:Fire(...) with ':'"
local MSG_WRONG_SIDE = PREFIX .. "Service Signals are server-to-client; Connect on the client proxy"
local METHODS = { "Fire", "FireAll", "FireFor", "FireExcept" }

local folderA = Instance.new("Folder")
folderA.Name = "SendServerA"
local folderB = Instance.new("Folder")
folderB.Name = "SendServerB"
local part = Instance.new("Part")
part.Name = "SendServerPart"
local instanceIds: { [Instance]: number } = { [folderA] = 1, [folderB] = 2, [part] = 3 }

local cyclic: { [string]: any } = {}
cyclic.self = cyclic

local function noop(...: any) end

local function list(...: any): { any }
	return { ... }
end

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
		return "{" .. table.concat(parts, ",") .. "}" .. (if getmetatable(x) ~= nil then "+mt" else "")
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

local function hexOf(s: string): string
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

local function clip(s: string): string
	return if #s > 360 then string.sub(s, 1, 360) .. ".." else s
end

local function newChecker(): Checker
	return { mismatches = {}, count = 0 }
end

local function note(ck: Checker, what: string, got: string, want: string)
	ck.count += 1
	if #ck.mismatches < MISMATCHES_SHOWN then
		table.insert(ck.mismatches, string.format("%s\n    runtime: %s\n    expected: %s", what, clip(got), clip(want)))
	end
end

local function same(ck: Checker, what: string, got: string, want: string)
	if got ~= want then
		note(ck, what, got, want)
	end
end

local function verdict(ck: Checker)
	if ck.count > 0 then
		local shown = table.concat(ck.mismatches, "\n  ")
		error(string.format("%d mismatch(es); first %d:\n  %s", ck.count, #ck.mismatches, shown), 0)
	end
end

local lastYield = os.clock()

local function tick()
	if os.clock() - lastYield > YIELD_AFTER then
		task.wait()
		lastYield = os.clock()
	end
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

local function rep(s: Shape, n: number): { Shape }
	local out: { Shape } = table.create(n) :: any
	for i = 1, n do
		out[i] = s
	end
	return out
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
	error("SendServer.spec: unknown shape " .. tostring(k))
end

local function buildList(T: any, shapes: { Shape }): { any }
	local descs: { any } = table.create(#shapes)
	for i, s in shapes do
		descs[i] = build(T, s)
	end
	return descs
end

local F32_EDGES = { 0, NEG0, 1, -1, 0.5, 0.1, 1e-45, 1.1754942e-38, F32_MAX, -F32_MAX, 16777217, 1e10, 3.5e38 }
local F64_EDGES = { 0, NEG0, 5e-324, 2.2250738585072014e-308, F64_MAX, -F64_MAX, 1 / 3, 1e300, -1e-300 }
local NONFINITE = { NAN, INF, -INF }
local CHUNKS = { "a", "Z", "0", " ", "\0", "\u{E9}", "\u{20AC}", "\u{10348}" }
local MATERIALS = Enum.Material:GetEnumItems()
local WRONG: { any } = {
	"x",
	7,
	1.5,
	-1,
	true,
	false,
	{},
	Vector3.one,
	Vector2.one,
	Color3.new(1, 0, 0),
	CFrame.identity,
	Enum.KeyCode.A,
	Enum.Material.Grass,
	buffer.create(1),
	folderA,
	NAN,
}
local ANY_VALUES: { any } =
	{ 1, -2.5, "s", true, false, { 1, 2 }, { a = 1 }, Vector3.one, folderA, part, NAN, 0, buffer.fromstring("b") }

local function pick(rng: Random, list: { any }): any
	return list[rng:NextInteger(1, #list)]
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

local function edgeInt(rng: Random, lo: number, hi: number): any
	local roll = rng:NextInteger(1, 9)
	if roll == 1 then
		return lo
	elseif roll == 2 then
		return hi
	elseif roll == 3 then
		return hi + 1
	elseif roll == 4 then
		return lo - 1
	elseif roll == 5 then
		return lo + 0.5
	elseif roll == 6 then
		return pick(rng, NONFINITE)
	elseif roll == 7 then
		return NEG0
	elseif roll == 8 then
		return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
	end
	return rng:NextInteger(lo, hi)
end

local function edgeFloat(rng: Random, edges: { number }, scale: number): any
	local roll = rng:NextNumber()
	if roll < 0.15 then
		return pick(rng, NONFINITE)
	elseif roll < 0.25 then
		return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
	elseif roll < 0.8 then
		return pick(rng, edges)
	end
	return (rng:NextNumber() * 2 - 1) * scale
end

local function edgeIn(rng: Random, lo: number, hi: number): any
	local roll = rng:NextInteger(1, 7)
	if roll == 1 then
		return lo
	elseif roll == 2 then
		return hi
	elseif roll == 3 then
		return pick(rng, NONFINITE)
	elseif roll == 4 then
		return hi + math.max(math.abs(hi), 1) * 1e-6
	elseif roll == 5 then
		return lo - math.max(math.abs(lo), 1) * 1e-6
	elseif roll == 6 then
		return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
	end
	return lo + (hi - lo) * rng:NextNumber()
end

local function plainVector(rng: Random, mag: number?, two: boolean): any
	local c = if mag then mag / 1.8 else 1000
	local function r(): number
		return (rng:NextNumber() * 2 - 1) * c
	end
	return if two then Vector2.new(r(), r()) else Vector3.new(r(), r(), r())
end

local function edgeVector(rng: Random, mag: number?, two: boolean): any
	local roll = rng:NextInteger(1, 6)
	if roll == 1 and mag then
		return if two then Vector2.new(mag, 0) else Vector3.new(0, mag, 0)
	elseif roll == 2 and mag then
		return if two then Vector2.new(0, mag * 1.01) else Vector3.new(mag * 1.01, 0, 0)
	elseif roll == 3 then
		local f = edgeFloat(rng, F32_EDGES, 1e4)
		local x = if type(f) == "number" then f else 1
		return if two then Vector2.new(x, 1) else Vector3.new(1, x, 2)
	elseif roll == 4 then
		return if two then Vector3.one else Vector2.one
	elseif roll == 5 then
		return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
	end
	return plainVector(rng, mag, two)
end

local function plainCFrame(rng: Random): CFrame
	local pos = Vector3.new(rng:NextNumber() * 100, rng:NextNumber() * -100, rng:NextNumber() * 10)
	return CFrame.new(pos) * CFrame.Angles(rng:NextNumber() * 6, rng:NextNumber() * 6, rng:NextNumber() * 6)
end

local function gen(rng: Random, s: Shape, level: number): any
	local k = s.k
	local edgy = rng:NextNumber() < level
	local range = INT_RANGE[k]
	if range then
		return if edgy then edgeInt(rng, range[1], range[2]) else rng:NextInteger(range[1], range[2])
	elseif k == "bool" then
		if edgy then
			return if rng:NextNumber() < 0.4 then nil else pick(rng, WRONG)
		end
		return rng:NextInteger(0, 1) == 1
	elseif k == "int" or k == "u8r" then
		return if edgy then edgeInt(rng, s.lo, s.hi) else rng:NextInteger(s.lo, s.hi)
	elseif k == "f32" then
		return if edgy then edgeFloat(rng, F32_EDGES, 1e6) else (rng:NextNumber() * 2 - 1) * 1e6
	elseif k == "f64" then
		return if edgy then edgeFloat(rng, F64_EDGES, 1e12) else (rng:NextNumber() * 2 - 1) * 1e12
	elseif k == "f32r" or k == "num" then
		return if edgy then edgeIn(rng, s.lo, s.hi) else s.lo + (s.hi - s.lo) * rng:NextNumber()
	elseif k == "V3" then
		return if edgy then edgeVector(rng, s.mag, false) else plainVector(rng, s.mag, false)
	elseif k == "V2" then
		return if edgy then edgeVector(rng, s.mag, true) else plainVector(rng, s.mag, true)
	elseif k == "C3" then
		if edgy then
			local roll = rng:NextInteger(1, 3)
			if roll == 1 then
				return Color3.new(pick(rng, NONFINITE), 0, 1)
			elseif roll == 2 then
				return Color3.new(pick(rng, F32_EDGES), 1, 0)
			end
			return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
		end
		return Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber())
	elseif k == "CF" then
		if edgy then
			local roll = rng:NextInteger(1, 4)
			if roll == 1 then
				return CFrame.identity
			elseif roll == 2 then
				return CFrame.new(pick(rng, NONFINITE), 0, 0)
			elseif roll == 3 then
				return CFrame.new(0, 0, 0, pick(rng, NONFINITE), 0, 0, 0, 1, 0, 0, 0, 1)
			end
			return if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
		end
		return plainCFrame(rng)
	elseif k == "enum" then
		if edgy then
			return pick(rng, { "Z", "", 1, Enum.KeyCode.A, "A" })
		end
		return pick(rng, ENUM_NAMES)
	elseif k == "EI" then
		if edgy then
			return pick(rng, { Enum.KeyCode.A, "Grass", 1, Enum.Material.Grass })
		end
		return pick(rng, MATERIALS)
	elseif k == "string" then
		if edgy then
			local roll = rng:NextInteger(1, 4)
			if roll == 1 then
				return string.rep("a", s.max + 1)
			elseif roll == 2 then
				return "\255\254"
			elseif roll == 3 then
				return 5
			end
			return nil
		end
		return genString(rng, s.max, s.binary)
	elseif k == "buffer" then
		if edgy then
			return if rng:NextNumber() < 0.5 then buffer.create(s.max + 1) else "x"
		end
		return buffer.fromstring(genString(rng, s.max, true))
	elseif k == "inst" then
		if edgy then
			return pick(rng, { "x", 5, part, folderA })
		end
		local class = s.class
		return if class == "Folder" then pick(rng, { folderA, folderB }) else pick(rng, { folderA, folderB, part })
	elseif k == "opt" then
		if rng:NextNumber() < 0.3 then
			return nil
		end
		return gen(rng, s.inner, level)
	elseif k == "arr" then
		if edgy and rng:NextNumber() < 0.2 then
			return if rng:NextNumber() < 0.5 then nil else "x"
		end
		local top = math.min(s.max, s.cap)
		local cnt = if rng:NextNumber() < 0.15
			then rng:NextInteger(math.max(0, top - 3), top)
			else rng:NextInteger(0, math.min(top, 6))
		if edgy and s.max <= 200 and rng:NextNumber() < 0.2 then
			cnt = s.max + 1
		end
		local t: { any } = table.create(cnt)
		local inner = level / math.max(cnt, 1)
		for i = 1, cnt do
			t[i] = gen(rng, s.inner, inner)
		end
		if edgy and cnt > 0 and rng:NextNumber() < 0.5 then
			t[rng:NextInteger(1, cnt)] = if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
		end
		return t
	elseif k == "map" then
		if edgy and rng:NextNumber() < 0.3 then
			return if rng:NextNumber() < 0.5 then nil else 5
		end
		local m: { [any]: any } = {}
		local cnt = if edgy then rng:NextInteger(0, s.max + 1) else rng:NextInteger(0, math.min(s.max, 5))
		for _ = 1, cnt do
			local key = gen(rng, s.key, 0)
			if key ~= nil and key == key then
				m[key] = gen(rng, s.inner, level / 2)
			end
		end
		return m
	elseif k == "struct" then
		if edgy and rng:NextNumber() < 0.2 then
			return if rng:NextNumber() < 0.5 then nil else "x"
		end
		local t: { [string]: any } = {}
		for name, f in s.fields :: { [string]: Shape } do
			t[name] = gen(rng, f, level / 2)
		end
		return t
	elseif k == "any" then
		if edgy then
			return pick(rng, { cyclic, noop, setmetatable({ z = 1 }, {}), { [1] = "a", [3] = "c" }, CFrame.identity })
		end
		return pick(rng, ANY_VALUES)
	end
	error("SendServer.spec: unknown shape " .. tostring(k))
end

local function genArgs(rng: Random, shapes: { Shape }): Args
	local n = #shapes
	local values: Args = { n = n }
	for i = 1, n do
		values[i] = gen(rng, shapes[i], LEAF_EDGE)
	end
	local roll = rng:NextNumber()
	if roll < 0.04 then
		values.n = n + 1
		values[n + 1] = if rng:NextNumber() < 0.5 then nil else pick(rng, WRONG)
	elseif roll < 0.08 and n > 0 then
		values[n] = nil
		values.n = n - 1
	end
	return values
end

local function genAnyValue(rng: Random): any
	local roll = rng:NextInteger(1, 17)
	if roll == 1 then
		return nil
	elseif roll == 2 then
		return rng:NextInteger(-300, 300)
	elseif roll == 3 then
		return rng:NextNumber() * 1e6
	elseif roll == 4 then
		return genString(rng, 40, false)
	elseif roll == 5 then
		return list(1, "a", true)
	elseif roll == 6 then
		return { k = "v", n = 2 }
	elseif roll == 7 then
		return pick(rng, { folderA, folderB, part })
	elseif roll == 8 then
		return Vector3.new(rng:NextNumber(), 1, 2)
	elseif roll == 9 then
		return CFrame.new(1, 2, 3)
	elseif roll == 10 then
		return Enum.Material.Grass
	elseif roll == 11 then
		return buffer.fromstring("xy")
	elseif roll == 12 then
		return setmetatable({ z = 1 }, {})
	elseif roll == 13 then
		return { [1] = "a", [3] = "c" }
	elseif roll == 14 then
		return noop
	elseif roll == 15 then
		return pick(rng, { NAN, INF, NEG0, 2 ^ 40, -70000 })
	elseif roll == 16 then
		return { nested = list(1, list(2, { part })) }
	end
	return Color3.new(1, 0, 0)
end

local function genAnyArgs(rng: Random): Args
	local roll = rng:NextNumber()
	if roll < 0.01 then
		return table.pack(table.unpack(table.create(256, 1)))
	elseif roll < 0.02 then
		return table.pack(1, cyclic)
	end
	local n = rng:NextInteger(0, 4)
	local values: Args = { n = n }
	for i = 1, n do
		values[i] = genAnyValue(rng)
	end
	return values
end

local function compile(side: Side, shapes: { Shape }, anf: boolean, c2s: boolean): any
	return side.Schema.compile(buildList(side.Schema.T, shapes), anf, if c2s then MAX_C2S else MAX_S2C, false)
end

local function writerText(w: any, st: number): string
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
	if st == 0 then
		local raw = buffer.readstring(w.buf, 0, w.n)
		text ..= " bytes=" .. (if w.n <= 4096 then hexOf(raw) else "raw:" .. raw) .. " refs=" .. show(refs)
	end
	return text
end

local function encodeText(side: Side, pc: any, c2s: boolean, values: Args): string
	local w = side.Codec.newWriter(16, c2s)
	w.unreliable = false
	w.inlineTables = true
	local ok, st = pcall(pc.encode, w, values.n, table.unpack(values, 1, values.n))
	if not ok then
		return "encode threw"
	end
	return writerText(w, st)
end

local function fieldsText(plan: any, c2s: boolean, values: Args): string
	local w = Codec.newWriter(16, c2s)
	w.unreliable = false
	w.inlineTables = true
	local ok, st = pcall(Schema.encodeFields, w, plan.prog, nil, table.unpack(values, 1, values.n))
	if not ok then
		return "encode threw"
	end
	return writerText(w, st)
end

local function putText(plan: any, values: Args, off: number): string
	local size = plan.size
	local b = buffer.create(off + size + 8)
	buffer.fill(b, 0, SENTINEL)
	local ok: boolean, st: any, arg: any
	if plan.count == 1 then
		ok, st = pcall(plan.put, b, off, values[1])
		arg = 1
	else
		ok, st, arg = pcall(plan.putN, b, off, table.unpack(values, 1, values.n))
	end
	if not ok then
		return "put threw"
	end
	for i = 0, buffer.len(b) - 1 do
		if (i < off or i >= off + size) and buffer.readu8(b, i) ~= SENTINEL then
			return string.format("put wrote outside its %d bytes at %d", size, i - off)
		end
	end
	local text = string.format("status=%d errArg=%d", st, if st ~= 0 then arg else 0)
	if st == 0 then
		text ..= " bytes=" .. hexOf(buffer.readstring(b, off, size))
	end
	return text
end

local function oldPutText(pc: any, c2s: boolean, values: Args): string
	local w = OLD.Codec.newWriter(16, c2s)
	local ok, st = pcall(pc.encode, w, values.n, table.unpack(values, 1, values.n))
	if not ok then
		return "put threw"
	end
	local text = string.format("status=%d errArg=%d", st, w.errArg)
	if st == 0 then
		text ..= " bytes=" .. hexOf(buffer.readstring(w.buf, 0, w.n))
	end
	return text
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
local EVERY = STRUCT({
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
	v3 = V3M(10),
	v2 = V2M(5),
	r = INT(-5, 5),
	q = U8R(10, 20),
	fr = F32R(-1, 1),
	nm = NUM(0, 100),
})

type ECase = { name: string, args: { Shape }, rounds: number? }

local ECASES: { ECase } = {}
for _, s in
	{
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
		{ "T.int(-5, 5)", INT(-5, 5) },
		{ "T.int(0, 1000)", INT(0, 1000) },
		{ "T.int(-40000, 40000)", INT(-40000, 40000) },
		{ "T.u8(10, 20)", U8R(10, 20) },
		{ "T.f32(-1, 1)", F32R(-1, 1) },
		{ "T.num(0, 100)", NUM(0, 100) },
		{ "T.Vector3(10)", V3M(10) },
		{ "T.Vector2(5)", V2M(5) },
		{ "string", STR(16) },
		{ "buffer", BUF(8) },
		{ "Instance", INST() },
		{ "any", ANY },
	} :: { { any } }
do
	table.insert(ECASES, { name = "one " .. s[1], args = { s[2] } })
end
for _, c in
	{
		{ name = "every integer, bool and float", args = { BOOL, U8, U16, U32, I8, I16, I32, F32, F64 } },
		{
			name = "the other fixed types, bounded",
			args = { V3M(10), V2M(5), C3, CF, ENUM, EI, INT(-5, 5), F32R(-1, 1), NUM(0, 100) },
		},
		{ name = "three u8", args = { U8, U8, U8 } },
		{ name = "a fixed tuple, then a string", args = { U8, V3, STR(8) } },
		{ name = "the bench Entity", args = { ENTITY } },
		{ name = "the bench Input", args = { INPUT } },
		{ name = "a struct of every fixed type", args = { EVERY } },
		{ name = "a struct after an argument", args = { U8, ENTITY } },
		{ name = "two structs", args = { PAIR, ENTITY } },
		{ name = "a struct holding a struct", args = { STRUCT({ inner = PAIR, n = U8 }) } },
		{ name = "a struct with an optional field", args = { STRUCT({ a = OPT(U8), b = U8 }) } },
		{ name = "a struct with an Instance", args = { STRUCT({ who = INST(), n = U8 }) } },
		{ name = "a struct with T.any", args = { STRUCT({ x = ANY, y = U8 }) } },
		{ name = "an optional struct", args = { OPT(ENTITY) } },
		{ name = "an optional optional struct", args = { OPT(OPT(PAIR)) } },
		{ name = "Entity[100] (fireall100)", args = { ARR(ENTITY, 100, 100) }, rounds = 50 },
		{ name = "Input[1000] (a u16 count)", args = { ARR(INPUT, 1000, 40) } },
		{ name = "a struct array with a u32 count", args = { ARR(PAIR, 70000) } },
		{ name = "an array of every-fixed-type structs", args = { ARR(EVERY, 8) } },
		{ name = "an array of optional structs", args = { ARR(OPT(PAIR), 6) } },
		{ name = "arrays of arrays of structs", args = { ARR(ARR(PAIR, 3), 3) } },
		{ name = "an array of variable-size structs", args = { ARR(STRUCT({ s = STR(4), n = U8 }), 4) } },
		{ name = "maps of structs", args = { MAP(U8, ENTITY, 4), MAP(STR(4), PAIR, 3) } },
		{ name = "scalar arrays", args = { ARR(BOOL, 100), ARR(I16, 8), ARR(F32R(-1, 1), 8), ARR(INT(-5, 5), 8) } },
		{ name = "optionals and a fixed tail", args = { OPT(U8), OPT(STR(4)), U16, V3 } },
	} :: { ECase }
do
	table.insert(ECASES, c)
end

local function runECase(case: ECase, index: number): Checker
	local ck = newChecker()
	for _, c2s in { false, true } do
		for _, anf in { false, true } do
			local dir = (if c2s then "C->S" else "S->C") .. (if anf then ", AllowNonFinite" else "")
			local now = compile(NOW, case.args, anf, c2s)
			local old = compile(OLD, case.args, anf, c2s)
			local plan: any = Schema.plan(now)
			if plan == nil or plan.count ~= #case.args then
				note(ck, dir .. ": plan count", tostring(plan and plan.count), tostring(#case.args))
				continue
			end
			local rng = Random.new(index * 1000 + (if c2s then 10 else 0) + (if anf then 1 else 0))
			local count: number = #case.args
			local fixed: number = plan.size
			for r = 1, case.rounds or ROUNDS do
				tick()
				local values = genArgs(rng, case.args)
				local where = string.format("%s round %d", dir, r)
				local want = encodeText(OLD, old, c2s, values)
				same(ck, where .. ": codec encode", encodeText(NOW, now, c2s, values), want)
				if values.n <= count then
					same(ck, where .. ": Schema.encodeFields", fieldsText(plan, c2s, values), want)
					if fixed > 0 then
						local got = putText(plan, values, rng:NextInteger(0, 9))
						same(ck, where .. ": plan put", got, oldPutText(old, c2s, values))
					end
				end
			end
		end
	end
	return ck
end

local now = 1000
local rt: any = nil
local byName: { [string]: any } = {}
local fires: { any } = {}
local nextUid = 0
local seqN = 0

local function member(name: string, spec: any): any
	return { name = name, kind = K.Signal, fn = nil, spec = spec, middleware = nil, colon = false }
end

local function service(members: { any }): any
	table.sort(members, function(a: any, b: any): boolean
		return a.name < b.name
	end)
	local module = { Client = {}, Signals = {}, ClientEvents = {}, Middleware = {} }
	return {
		name = "S",
		record = { name = "S", kind = "Service", module = module, instance = script, path = "S", deps = {} },
		module = module,
		client = module.Client,
		members = members,
		networked = true,
	}
end

local function specOf(def: RouteDef): any
	local args = def.args
	if args == nil then
		return nil
	end
	local opts: { [string]: any } = {}
	if def.unreliable then
		opts.Unreliable = true
	end
	if def.ordered then
		opts.Ordered = true
	end
	if def.anf then
		opts.AllowNonFinite = true
	end
	local descs = buildList(Schema.T, args)
	if #descs == 0 then
		opts.Args = {}
		return Schema.signal(opts)
	end
	table.insert(descs, opts)
	return Schema.signal(table.unpack(descs))
end

local function resetServer()
	Transport._reset()
	Routes._reset()
	Dispatch._reset()
	Outbox._reset()
	ServerSignal._reset()
	Limits._reset()
	Violations._reset()
end

local function setup(defs: { RouteDef }, extra: { any }?)
	Loren.Testing.Reset({ Offline = true })
	resetServer()
	Log._test.setSink(noop, noop)
	local c = Config.get()
	Limits.configure(c)
	Violations.configure(c)
	local members: { any } = {}
	for _, def in defs do
		table.insert(members, member(def.name, specOf(def)))
	end
	if extra then
		for _, m in extra do
			table.insert(members, m)
		end
	end
	local report = { side = "Server", errors = {}, warnings = {} }
	rt = Routes.build({ service(members) }, c, report)
	assert(rt ~= nil, "Routes.build failed: " .. table.concat(report.errors, "; "))
	byName = {}
	for _, r in rt.routes do
		byName[r.member] = r
	end
	fires = {}
	Outbox._test.capture(function(channel: string, player: any, frame: buffer, refs: { any }?)
		table.insert(fires, { channel = channel, player = player, frame = frame, refs = refs })
	end)
	now = 1000
	Transport._test.setClock(function(): number
		return now
	end)
	Transport._test.attach(rt)
	ServerSignal._test.setPlayerCheck(function(p: any): boolean
		return type(p) == "table" and p.UserId ~= nil
	end)
end

local function hello(p: any)
	seqN = (seqN + 1) % 65536
	local b = buffer.create(8)
	buffer.writeu16(b, 0, seqN)
	buffer.writeu16(b, 2, 1)
	buffer.writeu8(b, 4, 0)
	buffer.writeu8(b, 5, 2)
	buffer.writeu8(b, 6, OP.HELLO)
	buffer.writeu8(b, 7, C.PROTO)
	Transport._test.frame(false, p, b, nil)
end

local function takeFires(p: any, channel: string?): { any }
	local mine: { any }, keep: { any } = {}, {}
	for _, f in fires do
		if f.player == p and (channel == nil or f.channel == channel) then
			table.insert(mine, f)
		else
			table.insert(keep, f)
		end
	end
	fires = keep
	return mine
end

local function newPlayer(helloNow: boolean): any
	nextUid += 1
	local p: any = { UserId = nextUid, Name = "P" .. nextUid }
	p.Kick = noop
	Transport._test.addPlayer(p)
	if helloNow then
		hello(p)
		Transport._test.flush()
		takeFires(p)
	end
	return p
end

local function oldCodec(def: RouteDef): any
	local args = def.args
	local descs = if args then buildList(OLD.Schema.T, args) else nil
	return OLD.Schema.compile(descs, def.anf == true, MAX_S2C, def.unreliable == true)
end

local function newModel(defs: { RouteDef }): Model
	local m: Model = {
		defs = defs,
		olds = {},
		seqs = {},
		players = {},
		of = {},
		messagesOut = 0,
		dropped = 0,
		outboxDropped = 0,
		ck = newChecker(),
	}
	for _, def in defs do
		m.olds[def.name] = oldCodec(def)
		m.seqs[def.name] = 0
	end
	return m
end

local function baseline(m: Model)
	local stats = Transport.getStats()
	m.messagesOut = stats.MessagesOut
	m.dropped = stats.SignalsDropped
	m.outboxDropped = stats.OutboxDropped
end

local function addPlayer(m: Model, helloNow: boolean): PModel
	local p = newPlayer(helloNow)
	local pm: PModel = { p = p, state = if helloNow then "helloed" else "early", rel = {}, refs = {}, unr = {} }
	table.insert(m.players, pm)
	m.of[p] = pm
	if helloNow then
		m.messagesOut += 1
	end
	return pm
end

local function helloPlayer(m: Model, pm: PModel)
	hello(pm.p)
	pm.state = "helloed"
	table.insert(pm.rel, 1, buffer.tostring(rt.manifestMsg))
	m.messagesOut += 1
end

local function removePlayer(pm: PModel)
	Transport._test.removePlayer(pm.p)
	pm.state = "gone"
	table.clear(pm.rel)
	table.clear(pm.refs)
	table.clear(pm.unr)
end

local function def(m: Model, name: string): RouteDef
	for _, d in m.defs do
		if d.name == name then
			return d
		end
	end
	error("SendServer.spec: no route " .. name)
end

local function oldMessage(m: Model, d: RouteDef, seq: number, values: Args): (number, number, string, { any })
	local w = OLD.Codec.newWriter(64, false)
	w.unreliable = d.unreliable == true
	w.inlineTables = true
	OLD.Codec.writeHead(w, byName[d.name].id)
	if d.ordered then
		OLD.Codec.writeU16(w, seq)
	end
	local st = m.olds[d.name].encode(w, values.n, table.unpack(values, 1, values.n))
	if st ~= 0 then
		return st, w.errArg, "", {}
	end
	if d.unreliable and w.n > SEAL then
		return -1, w.n, "", {}
	end
	return 0, 0, buffer.readstring(w.buf, 0, w.n), table.move(w.refs, 1, w.nrefs, 1, {})
end

local function encodeError(fullName: string, st: number, detail: number): string
	if st == -1 then
		return string.format(
			"%s%s:Fire: the message is %d bytes; unreliable Signals are limited to %d bytes",
			PREFIX,
			fullName,
			detail,
			SEAL
		)
	end
	return string.format("%s%s:Fire: arg %d %s", PREFIX, fullName, detail, ENCODE_NAME[st] or tostring(st))
end

local function targetError(fullName: string, method: string, what: string, got: any): string
	return string.format("%s%s:%s: %s (got %s)", PREFIX, fullName, method, what, typeof(got))
end

local at: any = function(f: any, ...: any)
	f(...)
end

local function raise(text: string)
	error(text, 2)
end

local function raisedAt(text: string): string
	local ok, err = pcall(at, raise, text)
	assert(not ok, "raise returned")
	return tostring(err)
end

local function isTarget(x: any): boolean
	return type(x) == "table" and x.UserId ~= nil
end

local function deliver(m: Model, pm: PModel, d: RouteDef, bytes: string, refs: { any })
	if pm.state == "gone" then
		m.dropped += 1
	elseif d.unreliable then
		if pm.state == "helloed" then
			table.insert(pm.unr, bytes)
			m.messagesOut += 1
		else
			m.dropped += 1
		end
	else
		table.insert(pm.rel, bytes)
		table.move(refs, 1, #refs, #pm.refs + 1, pm.refs)
		m.messagesOut += 1
	end
end

local function sendWith(m: Model, where: string, d: RouteDef, method: string, target: any, values: Args)
	local obj = rt.signals.S[d.name]
	local fullName = "S." .. d.name
	local want: string? = nil
	local single = false
	if method == "Fire" then
		if not isTarget(target) then
			want = targetError(fullName, "Fire", "argument 1 must be a Player", target)
		end
	elseif method == "FireFor" then
		if type(target) ~= "table" or isTarget(target) then
			want = targetError(fullName, "FireFor", "argument 1 must be an array of Players", target)
		else
			for i = 1, rawlen(target) do
				local e = rawget(target, i)
				if not isTarget(e) then
					want = targetError(fullName, "FireFor", "entry " .. i .. " is not a Player", e)
					break
				end
			end
		end
	elseif method == "FireExcept" then
		single = isTarget(target)
		if not single then
			if type(target) ~= "table" then
				want = targetError(fullName, "FireExcept", "argument 1 must be a Player or an array of Players", target)
			else
				for i = 1, rawlen(target) do
					local e = rawget(target, i)
					if not isTarget(e) then
						want = targetError(fullName, "FireExcept", "entry " .. i .. " is not a Player", e)
						break
					end
				end
			end
		end
	end
	local bytes, refs = "", {}
	if want == nil then
		if d.ordered then
			m.seqs[d.name] = (m.seqs[d.name] + 1) % 65536
		end
		local st, detail, b, r = oldMessage(m, d, m.seqs[d.name], values)
		if st ~= 0 then
			want = encodeError(fullName, st, detail)
		end
		bytes, refs = b, r
	end
	local argv: { any } = { obj }
	local argc = 1
	if method ~= "FireAll" then
		argc += 1
		argv[argc] = target
	end
	for i = 1, values.n do
		argv[argc + i] = values[i]
	end
	argc += values.n
	local ok, err = pcall(at, obj[method], table.unpack(argv, 1, argc))
	if want ~= nil then
		same(m.ck, where .. ": the error", if ok then "no error" else tostring(err), raisedAt(want))
	elseif not ok then
		note(m.ck, where .. ": raised", tostring(err), "no error")
	elseif method == "Fire" then
		deliver(m, m.of[target], d, bytes, refs)
	elseif method == "FireAll" then
		for _, pm in m.players do
			if pm.state ~= "gone" then
				deliver(m, pm, d, bytes, refs)
			end
		end
	elseif method == "FireFor" then
		for i = 1, rawlen(target) do
			deliver(m, m.of[rawget(target, i)], d, bytes, refs)
		end
	else
		local out: { [any]: boolean } = {}
		if single then
			out[target] = true
		else
			for i = 1, rawlen(target) do
				out[rawget(target, i)] = true
			end
		end
		for _, pm in m.players do
			if pm.state ~= "gone" and not out[pm.p] then
				deliver(m, pm, d, bytes, refs)
			end
		end
	end
	local seq = ServerSignal._test.lastSeq(byName[d.name].id)
	same(m.ck, where .. ": the Ordered seq", tostring(seq), tostring(m.seqs[d.name]))
end

local function chunksOf(list: { string }): { string }
	local out: { string } = {}
	local cur: { string } = {}
	local size = 0
	for _, msg in list do
		if #cur > 0 and size + #msg > SEAL then
			table.insert(out, table.concat(cur))
			table.clear(cur)
			size = 0
		end
		table.insert(cur, msg)
		size += #msg
	end
	if #cur > 0 then
		table.insert(out, table.concat(cur))
	end
	return out
end

local function chunksText(list: { string }): string
	local parts: { string } = {}
	for i, c in list do
		parts[i] = hexOf(c)
	end
	return table.concat(parts, " | ")
end

local function flushCheck(m: Model, where: string)
	Transport._test.flush()
	for _, pm in m.players do
		local mine = takeFires(pm.p)
		local name = pm.p.Name
		if pm.state ~= "helloed" then
			same(m.ck, where .. ": fires to " .. name .. " (" .. pm.state .. ")", tostring(#mine), "0")
			continue
		end
		local rel: { string } = {}
		local refs: { any } = {}
		local unr: { string } = {}
		for _, f in mine do
			if f.channel == "Reliable" then
				table.insert(rel, buffer.tostring(f.frame))
				local slice: { any } = f.refs or {}
				table.move(slice, 1, #slice, #refs + 1, refs)
			else
				table.insert(unr, buffer.tostring(f.frame))
			end
		end
		same(m.ck, where .. ": reliable bytes to " .. name, hexOf(table.concat(rel)), hexOf(table.concat(pm.rel)))
		same(m.ck, where .. ": refs to " .. name, show(refs), show(pm.refs))
		same(m.ck, where .. ": unreliable fires to " .. name, chunksText(unr), chunksText(chunksOf(pm.unr)))
		table.clear(pm.rel)
		table.clear(pm.refs)
		table.clear(pm.unr)
	end
	local stats = Transport.getStats()
	same(m.ck, where .. ": MessagesOut", tostring(stats.MessagesOut), tostring(m.messagesOut))
	same(m.ck, where .. ": SignalsDropped", tostring(stats.SignalsDropped), tostring(m.dropped))
	same(m.ck, where .. ": OutboxDropped", tostring(stats.OutboxDropped), tostring(m.outboxDropped))
end

local function randomTarget(m: Model, rng: Random, method: string): any
	local function anyPlayer(): any
		return m.players[rng:NextInteger(1, #m.players)].p
	end
	local bad = rng:NextNumber() < 0.08
	if method == "Fire" then
		if bad then
			local roll = rng:NextInteger(1, 4)
			if roll == 1 then
				return nil
			end
			return if roll == 2 then "nobody" elseif roll == 3 then workspace else { x = 1 }
		end
		return anyPlayer()
	elseif method == "FireFor" then
		if bad then
			local roll = rng:NextInteger(1, 3)
			if roll == 1 then
				return "x"
			elseif roll == 2 then
				return anyPlayer()
			end
			return { anyPlayer(), "nobody" }
		end
		local list: { any } = {}
		for i = 1, rng:NextInteger(0, 3) do
			list[i] = anyPlayer()
		end
		return list
	elseif method == "FireExcept" then
		if bad then
			return if rng:NextNumber() < 0.5 then 5 else { "nobody" }
		end
		if rng:NextNumber() < 0.5 then
			return anyPlayer()
		end
		local list: { any } = {}
		for i = 1, rng:NextInteger(0, 2) do
			list[i] = anyPlayer()
		end
		return list
	end
	return nil
end

local function randomValues(rng: Random, d: RouteDef): Args
	local args = d.args
	if args == nil then
		return genAnyArgs(rng)
	end
	return genArgs(rng, args)
end

local function scenario(m: Model, rng: Random, steps: number, lifecycle: boolean)
	for step = 1, steps do
		tick()
		local roll = rng:NextNumber()
		local where = "step " .. step
		if roll < 0.08 then
			flushCheck(m, where)
		elseif lifecycle and roll < 0.11 then
			local pm = m.players[rng:NextInteger(1, #m.players)]
			local present = 0
			for _, x in m.players do
				if x.state ~= "gone" then
					present += 1
				end
			end
			if pm.state == "early" then
				helloPlayer(m, pm)
			elseif pm.state == "helloed" and present > 2 and rng:NextNumber() < 0.3 then
				removePlayer(pm)
			else
				addPlayer(m, false)
			end
		else
			local d = pick(rng, m.defs)
			local method = pick(rng, METHODS)
			local target = randomTarget(m, rng, method)
			local values = randomValues(rng, d)
			sendWith(m, string.format("%s S.%s:%s", where, d.name, method), d, method, target, values)
		end
	end
	flushCheck(m, "the last flush")
end

local function entity(id: number): { [string]: any }
	return {
		id = id,
		position = Vector3.new(id, 2, 3),
		orientation = Vector3.new(0, id / 2, 0),
		health = id % 256,
		alive = true,
		moving = id % 2 == 0,
		crouched = false,
	}
end

local ROUTES: { RouteDef } = {
	{ name = "Bool", args = { BOOL } },
	{ name = "W16", args = { U16 } },
	{ name = "Ent", args = { ENTITY } },
	{ name = "Every", args = { EVERY } },
	{ name = "Pos", args = { U16, V3 } },
	{ name = "Tuple", args = { BOOL, I8, F32, ENUM, EI, V2, C3, CF, INT(-5, 5), NUM(0, 100) } },
	{ name = "Many", args = { U8, U8, U8 } },
	{ name = "Zero", args = {} },
	{ name = "Ents", args = { ARR(ENTITY, 100, 12) } },
	{ name = "Str", args = { STR(64) } },
	{ name = "Opt", args = { OPT(ENTITY), U8 } },
	{ name = "Inst", args = { INST(), U8 } },
	{ name = "AnyT", args = { ANY, U8 } },
	{ name = "Any" },
	{ name = "Large", args = rep(CF, 22) },
	{ name = "UBool", args = { BOOL }, unreliable = true },
	{ name = "UPos", args = { U16 }, unreliable = true, ordered = true },
	{ name = "UEnt", args = { ENTITY }, unreliable = true, ordered = true },
	{ name = "UEvery", args = { EVERY }, unreliable = true, anf = true },
	{ name = "UStr", args = { STR(1000) }, unreliable = true },
	{ name = "OStr", args = { STR(64) }, unreliable = true, ordered = true },
	{ name = "UBig", args = rep(CF, 19), unreliable = true },
	{ name = "Nf", args = { F32, V3, F64 }, anf = true },
}

local function snapshot(ps: any): string
	local parts: { string } = {}
	for _, ch in { ps.out, ps.uout } do
		local w = ch.w
		table.insert(
			parts,
			string.format(
				"n=%d nmsg=%d nrefs=%d bytes=%s starts=%s",
				w.n,
				ch.nmsg,
				w.nrefs,
				hexOf(buffer.readstring(w.buf, 0, w.n)),
				show(table.move(ch.starts, 1, ch.nmsg, 1, {}))
			)
		)
	end
	return table.concat(parts, " / ")
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.afterAll(function()
		resetServer()
		Loren.Testing.Reset()
		folderA:Destroy()
		folderB:Destroy()
		part:Destroy()
	end)

	describe("the new encoders against the frozen v2 encoder", function()
		it("Schema.plan: fixed sizes and entry points per shape", function()
			local function planFor(shapes: { Shape }?): any
				local descs = if shapes then buildList(Schema.T, shapes) else nil
				return Schema.plan(Schema.compile(descs, false, MAX_S2C, false))
			end
			expect(planFor(nil)).toBeNil()
			local cases: { { any } } = {
				{ { BOOL }, 1, "put" },
				{ { U16 }, 2, "put" },
				{ { ENTITY }, 30, "put" },
				{ { EVERY }, 124, "put" },
				{ { U16, V3 }, 14, "putN" },
				{ { U8, U8, U8 }, 3, "putN" },
				{ { U8, ENTITY }, 0, "" },
				{ { OPT(ENTITY) }, 0, "" },
				{ { STR(8) }, 0, "" },
				{ { ARR(ENTITY, 100) }, 0, "" },
				{ {}, 0, "" },
				{ { STRUCT({ inner = PAIR }) }, 0, "" },
			}
			for _, c in cases do
				local plan = planFor(c[1])
				expect(plan).never.toBeNil()
				expect(plan.count).toBe(#c[1])
				expect(plan.size).toBe(c[2])
				if c[3] == "put" then
					expect(type(plan.put)).toBe("function")
				elseif c[3] == "putN" then
					expect(type(plan.putN)).toBe("function")
					expect(plan.put).toBeNil()
				else
					expect(plan.put).toBeNil()
					expect(plan.putN).toBeNil()
				end
			end
			local pc = Schema.compile(buildList(Schema.T, { ENTITY }), false, MAX_S2C, false)
			expect(Schema.plan(pc)).toBe(Schema.plan(pc))
			expect(table.isfrozen(Schema.plan(pc))).toBe(true)
		end)

		for index, case in ECASES do
			it(case.name .. ": codec encode, Schema.encodeFields and the plan's put match frozen v2", function()
				verdict(runECase(case, index))
			end, { timeout = 120 })
		end

		it("fixed-struct arrays with a hole or a bad element at every index", function()
			local ck = newChecker()
			local bads: { any } =
				{ "nil", "x", 5, { a = 300, b = 0 }, { a = 1 }, {}, setmetatable({ a = 1, b = 2 }, {}) }
			for _, c2s in { false, true } do
				local now = compile(NOW, { ARR(PAIR, 8) }, false, c2s)
				local old = compile(OLD, { ARR(PAIR, 8) }, false, c2s)
				for size = 1, 6 do
					for at = 1, size do
						for bi, bad in bads do
							local arr: { any } = {}
							for i = 1, size do
								arr[i] = { a = i, b = i / 4 }
							end
							arr[at] = if bad == "nil" then nil else bad
							local values = table.pack(arr)
							local where = string.format("%s %d elements, bad #%d at %d", tostring(c2s), size, bi, at)
							same(ck, where, encodeText(NOW, now, c2s, values), encodeText(OLD, old, c2s, values))
						end
					end
				end
			end
			verdict(ck)
		end)

		it("fixed-struct arrays on both sides of the one-reservation limit", function()
			local ck = newChecker()
			local shapes = { ARR(STRUCT({ c = CF }), 30000) }
			for _, c2s in { false, true } do
				local now = compile(NOW, shapes, false, c2s)
				local old = compile(OLD, shapes, false, c2s)
				for _, cnt in { 21845, 21846 } do
					local arr: { any } = table.create(cnt)
					for i = 1, cnt do
						arr[i] = { c = CFrame.new(i, 0, 0) }
					end
					local values = table.pack(arr)
					local where = string.format("%s %d elements", tostring(c2s), cnt)
					same(ck, where .. " valid", encodeText(NOW, now, c2s, values), encodeText(OLD, old, c2s, values))
					arr[cnt] = { c = CFrame.new(NAN, 0, 0) }
					same(ck, where .. " last NaN", encodeText(NOW, now, c2s, values), encodeText(OLD, old, c2s, values))
					arr[1] = "x"
					same(
						ck,
						where .. " first bad",
						encodeText(NOW, now, c2s, values),
						encodeText(OLD, old, c2s, values)
					)
					task.wait()
				end
			end
			verdict(ck)
		end, { timeout = 60 })
	end)

	describe("errors raised by the Signal methods", function()
		it("encode errors: the same text, errArg and caller's line on every path and method", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			local p2 = addPlayer(m, true).p
			local early = addPlayer(m, false).p
			baseline(m)
			local cf = CFrame.identity
			local cases: { { any } } = {
				{ "Bool", table.pack(5) },
				{ "Bool", table.pack(nil) },
				{ "Bool", table.pack() },
				{ "Bool", table.pack(true, 1) },
				{ "Bool", table.pack(true, nil) },
				{ "W16", table.pack(65536) },
				{ "W16", table.pack(-1) },
				{ "W16", table.pack(1.5) },
				{ "W16", table.pack(NAN) },
				{ "W16", table.pack(INF) },
				{ "Ent", table.pack({ id = 1 }) },
				{ "Ent", table.pack("x") },
				{ "Ent", table.pack(nil) },
				{ "Ent", table.pack(entity(1), 2) },
				{ "Every", table.pack({ b = true }) },
				{ "Pos", table.pack(70000, Vector3.one) },
				{ "Pos", table.pack(1, Vector3.new(NAN, 0, 0)) },
				{ "Pos", table.pack(1) },
				{ "Pos", table.pack(1, Vector3.one, 3) },
				{ "Tuple", table.pack(true, 1, 0.5, "Z", Enum.Material.Grass, Vector2.one, Color3.new(), cf, 0, 1) },
				{ "Tuple", table.pack(true, 1, 0.5, "A", Enum.KeyCode.A, Vector2.one, Color3.new(), cf, 0, 1) },
				{ "Tuple", table.pack(true, 1, 0.5, "A", Enum.Material.Grass, Vector2.one, Color3.new(), cf, 6, 1) },
				{ "Tuple", table.pack(true, 1, 0.5, "A", Enum.Material.Grass, Vector2.one, Color3.new(), cf, 0, 101) },
				{ "Many", table.pack(1, 2, 300) },
				{ "Zero", table.pack(1) },
				{ "Ents", table.pack(list(entity(1), "x")) },
				{ "Ents", table.pack(table.create(101, entity(2))) },
				{ "Str", table.pack(string.rep("x", 65)) },
				{ "Str", table.pack("\255") },
				{ "Opt", table.pack({ id = 1 }, 1) },
				{ "Opt", table.pack(nil, 256) },
				{ "Inst", table.pack(nil, 1) },
				{ "Inst", table.pack("x", 1) },
				{ "AnyT", table.pack(cyclic, 1) },
				{ "Any", table.pack(cyclic) },
				{ "Any", table.pack(table.unpack(table.create(256, 1))) },
				{ "Large", table.pack(table.unpack(table.create(22, CFrame.new(NAN, 0, 0)))) },
				{ "UBool", table.pack("x") },
				{ "UPos", table.pack(-1) },
				{ "UEnt", table.pack({}) },
				{ "UEvery", table.pack({ b = 1 }) },
				{ "UStr", table.pack(string.rep("u", 1001)) },
				{ "UStr", table.pack(string.rep("u", 898)) },
				{ "OStr", table.pack(5) },
				{ "UBig", table.pack(table.unpack(table.create(19, cf))) },
				{ "Nf", table.pack(3.5e38, Vector3.one, 1) },
				{ "Nf", table.pack(NAN, Vector3.new(INF, 0, 0), -INF) },
				{ "Opt", table.pack(entity(1), 2) },
			}
			for ci, c in cases do
				local d = def(m, c[1])
				for _, method in METHODS do
					local target: any = if method == "Fire"
						then p1
						elseif method == "FireFor" then { p1, early }
						elseif method == "FireExcept" then p2
						else nil
					sendWith(m, string.format("case %d S.%s:%s", ci, d.name, method), d, method, target, c[2])
				end
				sendWith(m, string.format("case %d S.%s:Fire early", ci, d.name), d, "Fire", early, c[2])
				tick()
			end
			flushCheck(m, "after the error cases")
			verdict(m.ck)
		end, { timeout = 60 })

		it("target errors: the same text and caller's line; no seq taken", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			baseline(m)
			local targets: { { any } } = {
				{ "Fire", nil },
				{ "Fire", "nobody" },
				{ "Fire", workspace },
				{ "Fire", { x = 1 } },
				{ "FireFor", "x" },
				{ "FireFor", p1 },
				{ "FireFor", { p1, "nobody" } },
				{ "FireFor", { p1, p1, 5 } },
				{ "FireExcept", 5 },
				{ "FireExcept", { "nobody" } },
				{ "FireExcept", { p1, workspace } },
			}
			for _, name in { "Bool", "UPos", "Ent", "OStr", "Any", "Pos" } do
				local d = def(m, name)
				for ti, tc in targets do
					local values = if d.args == nil then table.pack(1) else table.pack()
					sendWith(m, string.format("S.%s target %d", name, ti), d, tc[1], tc[2], values)
				end
			end
			flushCheck(m, "after the target errors")
			verdict(m.ck)
		end)

		it("a dot call, Methods through the metatable and another Signal's method", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p = addPlayer(m, true).p
			baseline(m)
			local Sig = rt.signals.S
			local methods = getmetatable(Sig.Bool).__index
			expect(tostring(Sig.Bool)).toBe("Signal S.Bool")
			expect(rawget(Sig.Bool, "_route")).toBe(byName.Bool)
			expect(ServerSignal._test.routeOf(Sig.Bool)).toBe(byName.Bool)
			expect(table.isfrozen(Sig.Bool)).toBe(true)
			local function check(what: string, f: any, want: string?, ...: any)
				local ok, err = pcall(at, f, ...)
				if want then
					same(m.ck, what, if ok then "no error" else tostring(err), raisedAt(want))
				elseif not ok then
					note(m.ck, what, tostring(err), "no error")
				end
			end
			local function expectTo(name: string, seq: number, values: Args)
				local d = def(m, name)
				local _, _, bytes, refs = oldMessage(m, d, seq, values)
				deliver(m, m.of[p], d, bytes, refs)
			end
			check("Methods.FireAll", methods.FireAll, nil, Sig.Bool, true)
			expectTo("Bool", 0, table.pack(true))
			check("Methods.Fire with Str", methods.Fire, nil, Sig.Str, p, "hi")
			expectTo("Str", 0, table.pack("hi"))
			check("Bool.Fire on Ent", Sig.Bool.Fire, nil, Sig.Ent, p, entity(4))
			expectTo("Ent", 0, table.pack(entity(4)))
			m.seqs.UPos = 1
			check("Bool.FireAll on UPos", Sig.Bool.FireAll, nil, Sig.UPos, 9)
			expectTo("UPos", 1, table.pack(9))
			check("Methods.Fire bad value", methods.Fire, encodeError("S.Bool", E.BAD_TYPE, 1), Sig.Bool, p, 5)
			check("Bool.FireAll on Ent, bad", Sig.Bool.FireAll, encodeError("S.Ent", E.BAD_TYPE, 1), Sig.Ent, 5)
			local bad = targetError("S.Str", "FireFor", "argument 1 must be an array of Players", "x")
			check("Bool.FireFor on Str, bad target", Sig.Bool.FireFor, bad, Sig.Str, "x", "v")
			check("Methods.Fire, not a Signal", methods.Fire, MSG_SELF, {}, p, true)
			check("dot Fire", Sig.Bool.Fire, MSG_SELF, p, true)
			check("dot FireAll", Sig.Bool.FireAll, MSG_SELF, true)
			check("dot FireFor", Sig.Bool.FireFor, MSG_SELF, nil, { p }, true)
			check("dot FireExcept", Sig.Bool.FireExcept, MSG_SELF, "x", p, true)
			check("Connect", Sig.Bool.Connect, MSG_WRONG_SIDE, Sig.Bool, noop)
			check("Wait", Sig.Bool.Wait, MSG_WRONG_SIDE, Sig.Bool)
			expect(ServerSignal._test.lastSeq(byName.UPos.id)).toBe(1)
			flushCheck(m, "after the cross calls")
			verdict(m.ck)
		end)

		it("variable-size errors through Methods and another Signal's method point at the caller", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p = addPlayer(m, true).p
			local q = addPlayer(m, true).p
			baseline(m)
			local Sig = rt.signals.S
			local methods = getmetatable(Sig.Bool).__index
			local cases: { { any } } = {
				{ "Str", table.pack(5) },
				{ "Str", table.pack(string.rep("s", 65)) },
				{ "Any", table.pack(cyclic) },
				{ "Any", table.pack(table.unpack(table.create(256, 1))) },
				{ "Opt", table.pack(entity(1), 2, 3) },
				{ "Opt", table.pack({ id = 1 }, 1) },
				{ "UStr", table.pack(string.rep("u", SEAL - 2)) },
				{ "UStr", table.pack(string.rep("u", 1001)) },
			}
			for ci, c in cases do
				local d = def(m, c[1])
				local st, detail = oldMessage(m, d, 0, c[2])
				local want = raisedAt(encodeError("S." .. d.name, st, detail))
				expect(st ~= 0).toBe(true)
				local values = c[2] :: Args
				for _, method in METHODS do
					local lead: { any } = if method == "Fire"
						then { p }
						elseif method == "FireFor" then { { p, q } }
						elseif method == "FireExcept" then { q }
						else {}
					local argv: { any } = table.clone(lead)
					for i = 1, values.n do
						argv[#lead + i] = values[i]
					end
					local argc = #lead + values.n
					for _, via in { "Methods", "Bool" } do
						local f = if via == "Methods" then methods[method] else Sig.Bool[method]
						local ok, err = pcall(at, f, Sig[d.name], table.unpack(argv, 1, argc))
						same(
							m.ck,
							string.format("case %d S.%s:%s through %s", ci, d.name, method, via),
							if ok then "no error" else tostring(err),
							want
						)
					end
				end
				tick()
			end
			flushCheck(m, "after the variable-size errors")
			verdict(m.ck)
		end)

		it("Methods and another Signal's method reuse one set of senders per Signal until _reset", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p = addPlayer(m, true).p
			baseline(m)
			local Sig = rt.signals.S
			local methods = getmetatable(Sig.Bool).__index
			local function expectTo(name: string, values: Args)
				local d = def(m, name)
				local _, _, bytes, refs = oldMessage(m, d, 0, values)
				deliver(m, m.of[p], d, bytes, refs)
			end
			expect(ServerSignal._test.senders(Sig.Str)).toBeNil()
			methods.Fire(Sig.Str, p, "a")
			expectTo("Str", table.pack("a"))
			local first = ServerSignal._test.senders(Sig.Str)
			expect(first).never.toBeNil()
			for i = 1, 50 do
				Sig.Bool.Fire(Sig.Str, p, "b" .. i)
				expectTo("Str", table.pack("b" .. i))
				methods.FireAll(Sig.Str, "c" .. i)
				expectTo("Str", table.pack("c" .. i))
				Sig.Ent.FireFor(Sig.Str, { p }, "d" .. i)
				expectTo("Str", table.pack("d" .. i))
			end
			expect(ServerSignal._test.senders(Sig.Str)).toBe(first)
			Sig.Bool:Fire(p, true)
			expectTo("Bool", table.pack(true))
			Sig.Ent:FireAll(entity(2))
			expectTo("Ent", table.pack(entity(2)))
			expect(ServerSignal._test.senders(Sig.Bool)).toBeNil()
			expect(ServerSignal._test.senders(Sig.Ent)).toBeNil()
			local notSignal = {}
			expect((pcall(methods.Fire, notSignal, p, true))).toBe(false)
			expect(ServerSignal._test.senders(notSignal)).toBeNil()
			flushCheck(m, "after the cached calls")
			verdict(m.ck)
			ServerSignal._reset()
			expect(ServerSignal._test.senders(Sig.Str)).toBeNil()
		end)
	end)

	describe("frames byte-identical to the frozen encoder, per player", function()
		it("one helloed player (every fixed FireAll and Fire is written straight into its channel)", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			addPlayer(m, true)
			baseline(m)
			scenario(m, Random.new(11), 900, false)
			verdict(m.ck)
		end, { timeout = 120 })

		it("three players, one before HELLO and one that left, with joins and HELLOs on the way", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			addPlayer(m, true)
			addPlayer(m, true)
			addPlayer(m, true)
			addPlayer(m, false)
			local gone = addPlayer(m, true)
			baseline(m)
			removePlayer(gone)
			scenario(m, Random.new(22), 1400, true)
			verdict(m.ck)
		end, { timeout = 120 })

		it("route heads of 2 and 3 bytes on every path", function()
			local extra: { any } = {}
			for i = 1, 300 do
				table.insert(
					extra,
					member(string.format("U%04d", i), Schema.signal(Schema.T.bool, { Unreliable = true }))
				)
			end
			for i = 1, 4100 do
				table.insert(extra, member(string.format("R%04d", i), nil))
			end
			local probes: { RouteDef } = {
				{ name = "U0250a", args = { BOOL }, unreliable = true },
				{ name = "U0250b", args = { U16 }, unreliable = true, ordered = true },
				{ name = "U0250c", args = { ENTITY }, unreliable = true, ordered = true },
				{ name = "U0250d", args = { STR(64) }, unreliable = true, ordered = true },
				{ name = "R0001a", args = { BOOL } },
				{ name = "R0001b", args = { ENTITY } },
				{ name = "R0001c", args = { STR(64) } },
				{ name = "R0001d" },
				{ name = "R0001e", args = { U16, V3 } },
				{ name = "R4090a", args = { BOOL } },
				{ name = "R4090b", args = { ENTITY } },
				{ name = "R4090c", args = { STR(64) } },
				{ name = "R4090d" },
				{ name = "R4090e", args = { U16, V3 } },
			}
			setup(probes, extra)
			for _, d in probes do
				local want = if string.sub(d.name, 1, 5) == "R4090" then 3 else 2
				expect(Codec.headSize(byName[d.name].id)).toBe(want)
			end
			local seqs: { [string]: number } = {}
			for round, players in { 1, 3 } do
				local m = newModel(probes)
				for name, s in seqs do
					m.seqs[name] = s
				end
				for _ = 1, players do
					addPlayer(m, true)
				end
				if round == 2 then
					addPlayer(m, false)
				end
				baseline(m)
				scenario(m, Random.new(33 + players), 500, false)
				verdict(m.ck)
				seqs = m.seqs
				for _, pm in m.players do
					if pm.state ~= "gone" then
						removePlayer(pm)
					end
				end
			end
		end, { timeout = 120 })

		it("messages of 1 to 16 bytes through every copy path", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			local p2 = addPlayer(m, true).p
			local p3 = addPlayer(m, true).p
			local early = addPlayer(m, false)
			baseline(m)
			local sized: { { any } } = {
				{ "Zero", table.pack() },
				{ "Any", table.pack() },
				{ "Bool", table.pack(true) },
				{ "Any", table.pack(nil) },
				{ "W16", table.pack(513) },
				{ "Many", table.pack(1, 2, 3) },
				{ "UBool", table.pack(false) },
				{ "UPos", table.pack(7) },
			}
			for k = 0, 12 do
				table.insert(sized, list("Any", table.pack(string.rep("s", k))))
			end
			for k = 0, 13 do
				table.insert(sized, list("UStr", table.pack(string.rep("u", k))))
			end
			local sizes: { [number]: boolean } = {}
			for si, c in sized do
				local d = def(m, c[1])
				local _, _, bytes = oldMessage(m, d, m.seqs[d.name] + 1, c[2])
				sizes[#bytes] = true
				local where = string.format("sized %d (%d bytes) S.%s", si, #bytes, d.name)
				sendWith(m, where .. ":Fire", d, "Fire", p1, c[2])
				sendWith(m, where .. ":FireAll", d, "FireAll", nil, c[2])
				sendWith(m, where .. ":FireFor", d, "FireFor", { p1, p2, early.p }, c[2])
				sendWith(m, where .. ":FireExcept one", d, "FireExcept", p3, c[2])
				sendWith(m, where .. ":FireExcept list", d, "FireExcept", { p2 }, c[2])
				sendWith(m, where .. ":Fire early", d, "Fire", early.p, c[2])
			end
			for len = 1, 16 do
				expect(sizes[len]).toBe(true)
			end
			flushCheck(m, "three players")
			helloPlayer(m, early)
			flushCheck(m, "after HELLO")
			for _, pm in m.players do
				if pm.p ~= p1 then
					removePlayer(pm)
				end
			end
			for si, c in sized do
				local d = def(m, c[1])
				sendWith(m, string.format("alone %d S.%s:FireAll", si, d.name), d, "FireAll", nil, c[2])
				sendWith(m, string.format("alone %d S.%s:Fire", si, d.name), d, "Fire", p1, c[2])
			end
			flushCheck(m, "one player")
			verdict(m.ck)
		end)
	end)

	describe("pre-HELLO outbox, unreliable limit and refs", function()
		it("fixed and variable messages wait in the outbox and follow MANIFEST at HELLO", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			local early = addPlayer(m, false)
			baseline(m)
			local list: { { any } } = {
				{ "Bool", table.pack(true) },
				{ "Ent", table.pack(entity(7)) },
				{ "Pos", table.pack(9, Vector3.new(1, 2, 3)) },
				{ "Ents", table.pack({ entity(1), entity(2) }) },
				{ "Any", table.pack("x", folderA, { 1, 2 }) },
				{ "Inst", table.pack(part, 3) },
				{ "UBool", table.pack(true) },
				{ "UEnt", table.pack(entity(3)) },
				{ "OStr", table.pack("o") },
			}
			for li, c in list do
				local d = def(m, c[1])
				for _, method in METHODS do
					local target: any = if method == "Fire"
						then early.p
						elseif method == "FireFor" then { early.p, p1 }
						elseif method == "FireExcept" then { p1 }
						else nil
					sendWith(m, string.format("outbox %d S.%s:%s", li, d.name, method), d, method, target, c[2])
				end
			end
			flushCheck(m, "before HELLO")
			expect(Transport._test.state(early.p).out.nmsg > 0).toBe(true)
			helloPlayer(m, early)
			flushCheck(m, "after HELLO")
			verdict(m.ck)
		end)

		it("the outbox cap and TTL drop fixed-size messages as before", function()
			setup(ROUTES)
			local p = newPlayer(false)
			local Sig = rt.signals.S
			local model = newModel(ROUTES)
			local parts: { string } = {}
			for i = 1, LIM.OUTBOX_MSGS + 3 do
				local v = i % 3 == 0
				Sig.Bool:Fire(p, v)
				if i <= LIM.OUTBOX_MSGS then
					local _, _, bytes = oldMessage(model, def(model, "Bool"), 0, table.pack(v))
					table.insert(parts, bytes)
				end
			end
			local ps = Transport._test.state(p)
			expect(ps.outboxDropped).toBe(3)
			expect(ps.out.nmsg).toBe(LIM.OUTBOX_MSGS)
			expect(Transport.getStats().OutboxDropped).toBe(3)
			hello(p)
			Transport._test.flush()
			local got: { string } = {}
			for _, f in takeFires(p, "Reliable") do
				table.insert(got, buffer.tostring(f.frame))
			end
			local notice = buffer.create(6)
			buffer.writeu8(notice, 0, OP.NOTICE)
			buffer.writeu8(notice, 1, C.Notice.OutboxOverflow)
			buffer.writeu16(notice, 2, 0)
			buffer.writeu16(notice, 4, 3)
			local want = buffer.tostring(rt.manifestMsg) .. buffer.tostring(notice) .. table.concat(parts)
			expect(hexOf(table.concat(got))).toBe(hexOf(want))
			local q = newPlayer(false)
			Sig.Ent:Fire(q, entity(1))
			Sig.Ent:FireAll(entity(2))
			now += LIM.OUTBOX_TTL + 1
			Sig.Ent:Fire(q, entity(3))
			Sig.Pos:FireAll(1, Vector3.one)
			local qs = Transport._test.state(q)
			expect(qs.outboxExpired).toBe(true)
			expect(qs.outboxDropped).toBe(4)
			expect(qs.out.nmsg).toBe(0)
			hello(q)
			Transport._test.flush()
			local qgot: { string } = {}
			for _, f in takeFires(q, "Reliable") do
				table.insert(qgot, buffer.tostring(f.frame))
			end
			buffer.writeu16(notice, 4, 4)
			expect(hexOf(table.concat(qgot))).toBe(hexOf(buffer.tostring(rt.manifestMsg) .. buffer.tostring(notice)))
		end, { timeout = 60 })

		it("unreliable limit: 900 B goes out; 901 B and an oversized fixed route raise and queue nothing", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			local p2 = addPlayer(m, true).p
			baseline(m)
			local d = def(m, "UStr")
			local exact = table.pack(string.rep("u", SEAL - 3))
			local over = table.pack(string.rep("u", SEAL - 2))
			local _, _, exactBytes = oldMessage(m, d, 0, exact)
			expect(#exactBytes).toBe(SEAL)
			local big = table.pack(table.unpack(table.create(19, CFrame.identity)))
			for _, method in METHODS do
				local target: any = if method == "Fire"
					then p1
					elseif method == "FireFor" then { p1, p2 }
					elseif method == "FireExcept" then p2
					else nil
				sendWith(m, "exact " .. method, d, method, target, exact)
				sendWith(m, "over " .. method, d, method, target, over)
				sendWith(m, "UBig " .. method, def(m, "UBig"), method, target, big)
			end
			flushCheck(m, "the limit")
			verdict(m.ck)
		end)

		it("refs follow their messages on every method and path", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p1 = addPlayer(m, true).p
			local p2 = addPlayer(m, true).p
			local p3 = addPlayer(m, true).p
			baseline(m)
			local rng = Random.new(44)
			for step = 1, 300 do
				local name = pick(rng, { "Any", "Inst", "AnyT", "Bool", "Ent", "Str" })
				local d = def(m, name)
				local values = if name == "Any"
					then table.pack(pick(rng, { folderA, part, "s" }), pick(rng, { folderB, 1, { part } }))
					elseif name == "Inst" then table.pack(pick(rng, { folderA, folderB, part }), step % 256)
					elseif name == "AnyT" then table.pack(pick(rng, { part, { x = folderA }, 5 }), 1)
					else randomValues(rng, d)
				local method = pick(rng, METHODS)
				local target: any = if method == "Fire"
					then pick(rng, { p1, p2, p3 })
					elseif method == "FireFor" then { pick(rng, { p1, p2 }), p3 }
					elseif method == "FireExcept" then pick(rng, { p1, { p2 } })
					else nil
				sendWith(m, string.format("refs %d S.%s:%s", step, name, method), d, method, target, values)
				if step % 50 == 0 then
					flushCheck(m, "refs " .. step)
				end
			end
			flushCheck(m, "refs end")
			verdict(m.ck)
		end)
	end)

	describe("scratch writers and channels", function()
		it("a failed direct encode leaves the channel as it was", function()
			setup(ROUTES)
			local p = newPlayer(true)
			local Sig = rt.signals.S
			Sig.Any:Fire(p, "a", folderA)
			Sig.Bool:Fire(p, true)
			Sig.UPos:Fire(p, 1)
			Sig.Ent:FireAll(entity(5))
			local ps = Transport._test.state(p)
			local before = snapshot(ps)
			local seq = ServerSignal._test.lastSeq(byName.UPos.id)
			for _, f in
				{
					function()
						Sig.Bool:Fire(p, 5)
					end,
					function()
						Sig.Bool:FireAll(nil)
					end,
					function()
						Sig.Ent:Fire(p, { id = 1 })
					end,
					function()
						Sig.Ent:FireAll(entity(70000))
					end,
					function()
						Sig.UPos:Fire(p, 1.5)
					end,
					function()
						Sig.UPos:FireAll(-1)
					end,
					function()
						Sig.Pos:Fire(p, 1, "x")
					end,
					function()
						Sig.Every:FireAll({})
					end,
					function()
						Sig.Bool:Fire(p, true, 2)
					end,
				}
			do
				expect(f).toThrow()
			end
			expect(snapshot(ps)).toBe(before)
			expect(ServerSignal._test.lastSeq(byName.UPos.id)).toBe(seq + 2)
			local w = ps.out.w
			local fill = w.cap - w.n - 8
			expect(fill > 200).toBe(true)
			Sig.Any:Fire(p, string.rep("f", fill))
			expect(w.cap - w.n < 31).toBe(true)
			local cap = w.cap
			before = snapshot(ps)
			expect(function()
				Sig.Ent:Fire(p, { id = 1 })
			end).toThrow()
			expect(snapshot(ps)).toBe(before)
			expect(w.cap > cap).toBe(true)
			local n, nmsg = w.n, ps.out.nmsg
			Sig.Ent:Fire(p, entity(6))
			expect(w.n).toBe(n + 31)
			expect(ps.out.nmsg).toBe(nmsg + 1)
		end)

		it("a fixed-size send drops the refs and a burst-sized buffer the shared scratch still holds", function()
			setup(ROUTES)
			local m = newModel(ROUTES)
			local p = addPlayer(m, true).p
			addPlayer(m, true)
			baseline(m)
			local scratch = Outbox._test.scratch()
			local function send(name: string, method: string, target: any, values: Args)
				sendWith(m, "S." .. name .. ":" .. method, def(m, name), method, target, values)
			end
			send("Any", "Fire", p, table.pack(part))
			expect(scratch.nrefs).toBe(1)
			send("Bool", "Fire", p, table.pack(true))
			expect(scratch.nrefs).toBe(0)
			send("Any", "FireAll", nil, table.pack(folderA))
			expect(scratch.nrefs).toBe(1)
			send("Ent", "FireAll", nil, table.pack(entity(9)))
			expect(scratch.nrefs).toBe(0)
			send("Inst", "FireFor", { p }, table.pack(folderB, 1))
			expect(scratch.nrefs).toBe(1)
			send("UPos", "FireExcept", p, table.pack(3))
			expect(scratch.nrefs).toBe(0)
			send("Any", "Fire", p, table.pack(string.rep("x", 300000)))
			expect(scratch.cap > KEEP).toBe(true)
			send("Bool", "FireAll", nil, table.pack(false))
			expect(scratch.cap <= KEEP).toBe(true)
			expect(ServerSignal._test.fixed().cap).toBe(1024)
			expect(ServerSignal._test.fixed().nrefs).toBe(0)
			flushCheck(m, "scratch")
			verdict(m.ck)
		end)

		it("a thrown encode leaves visiting set until the next reset (O8)", function()
			Codec._reset()
			local w = Codec.newWriter(16, false)
			w.cap = 1e9
			local list = table.create(40, 1)
			local ok = pcall(Codec.writeValue, w, list, 0)
			expect(ok).toBe(false)
			expect(Codec._test.visitingCount()).toBe(1)
			local v = Codec.newWriter(16, false)
			Codec.resetWriter(v)
			expect(Codec._test.visitingCount()).toBe(0)
			expect(Codec.writeValue(v, list, 0)).toBe(0)
			expect(Codec._test.visitingCount()).toBe(0)
			Codec.resetWriter(v)
			local map = { a = { 1 }, b = { c = 2 } }
			expect(Codec.writeValue(v, map, 0)).toBe(0)
			expect(Codec.writeValue(v, map, 0)).toBe(0)
			expect(Codec._test.visitingCount()).toBe(0)
			local u = Codec.newWriter(16, false)
			u.cap = 1e9
			expect(pcall(Codec.writeValue, u, { k = list }, 0)).toBe(false)
			expect(Codec._test.visitingCount() > 0).toBe(true)
			Codec.resetWriter(v)
			expect(Codec._test.visitingCount()).toBe(0)
			expect(Codec.writeValue(v, list, 0)).toBe(0)
			Codec._reset()
		end)
	end)
end
