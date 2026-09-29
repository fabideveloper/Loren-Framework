--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local FrozenV2 = ServerStorage.LorenTest.Frozen.v2

type Side = { name: string, C: any, Codec: any, Schema: any }
type Args = { n: number, [number]: any }
type Case = {
	name: string,
	build: ((T: any) -> { any })?,
	anf: boolean?,
	unreliable: boolean?,
	inline: boolean?,
	values: { Args },
}

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
local CUTS = 96
local MUTATION_SPOTS = 48
local RANDOM_BUFFERS = 150
local YIELD_EVERY = 400
local MISMATCHES_SHOWN = 4

local function args(...: any): Args
	return table.pack(...)
end

local function list(...: any): { any }
	return { ... }
end

local folderA = Instance.new("Folder")
folderA.Name = "FrozenA"
local folderB = Instance.new("Folder")
folderB.Name = "FrozenB"
local part = Instance.new("Part")
part.Name = "FrozenPart"
local instanceIds: { [Instance]: number } = { [folderA] = 1, [folderB] = 2, [part] = 3 }

local bools: { boolean } = table.create(1000, false)
for i = 1, 1000 do
	bools[i] = i % 3 == 0
end

local deep: { any } = {}
do
	local cur = deep
	for _ = 1, 40 do
		local nextLevel = {}
		cur[1] = nextLevel
		cur = nextLevel
	end
end
local cyclic: { [string]: any } = {}
cyclic.self = cyclic

local NAN, INF = 0 / 0, math.huge

local mixedKeys: { [any]: any } = {}
mixedKeys[true] = 1
mixedKeys[2.5] = "x"

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

local function hex(s: string): string
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

local function entity(id: any): { [string]: any }
	return { id = id, pos = Vector3.new(1, 2, 3), hp = 100, name = "orc", alive = true, tags = { 1, 2 } }
end

local CASES: { Case } = {
	{
		name = "integers and bool",
		build = function(T: any): { any }
			return { T.bool, T.u8, T.u16, T.u32, T.i8, T.i16, T.i32 }
		end,
		values = {
			args(true, 0, 65535, 4294967295, -128, -32768, -2147483648),
			args(false, 255, 0, 0, 127, 32767, 2147483647),
			args(true, 256, 0, 0, 0, 0, 0),
			args(1, 0, 0, 0, 0, 0, 0),
			args(true, 1.5, 0, 0, 0, 0, 0),
			args(true, 0, 0, 0, 0, 0),
		},
	},
	{
		name = "bounded ints and floats",
		build = function(T: any): { any }
			return { T.int(-5, 5), T.int(0, 1000), T.f32, T.f64, T.num(-1, 1) }
		end,
		values = {
			args(-5, 1000, 1.5, 1e300, 0.5),
			args(5, 0, -0, -0, -1),
			args(0, 0, NAN, 0, 0),
			args(0, 0, 3.5e38, 0, 0),
			args(0, 0, 0, INF, 0),
			args(0, 0, 0, 0, 1.01),
			args(6, 0, 0, 0, 0),
			args(0, 0, 0.1, 0.1, 0),
		},
	},
	{
		name = "floats with AllowNonFinite",
		build = function(T: any): { any }
			return { T.f32, T.f64, T.Vector3 }
		end,
		anf = true,
		values = {
			args(NAN, INF, Vector3.new(NAN, -INF, 1)),
			args(-INF, NAN, Vector3.one),
			args(1, 2, Vector3.zero),
		},
	},
	{
		name = "strings and buffers",
		build = function(T: any): { any }
			return { T.string(8), T.string, T.buffer }
		end,
		values = {
			args("", "x", buffer.create(0)),
			args("12345678", string.rep("a", 300), buffer.fromstring("abc")),
			args("123456789", "", buffer.create(0)),
			args(5, "", buffer.create(0)),
			args("ok", "\255\0", buffer.create(1)),
			args("ok", "", "not a buffer"),
		},
	},
	{
		name = "vectors, Color3 and CFrame",
		build = function(T: any): { any }
			return { T.Vector3, T.Vector2, T.Color3, T.CFrame, T.Vector3(10) }
		end,
		values = {
			args(
				Vector3.new(1, 2, 3),
				Vector2.new(-1, 0.5),
				Color3.new(1, 0.5, 0),
				CFrame.new(1, 2, 3) * CFrame.Angles(0.1, 0.2, 0.3),
				Vector3.new(6, 8, 0)
			),
			args(Vector3.zero, Vector2.zero, Color3.new(), CFrame.identity, Vector3.new(10, 0, 0)),
			args(Vector3.new(NAN, 0, 0), Vector2.zero, Color3.new(), CFrame.identity, Vector3.zero),
			args(Vector3.one, Vector2.one, Color3.new(), CFrame.identity, Vector3.new(11, 0, 0)),
			args("x", Vector2.one, Color3.new(), CFrame.identity, Vector3.zero),
		},
	},
	{
		name = "enums",
		build = function(T: any): { any }
			return { T.enum({ "A", "B", "C" }), T.EnumItem(Enum.Material), T.optional(T.EnumItem(Enum.KeyCode)) }
		end,
		values = {
			args("B", Enum.Material.Grass, nil),
			args("C", Enum.Material.Plastic, Enum.KeyCode.E),
			args("D", Enum.Material.Grass, nil),
			args("A", Enum.KeyCode.A, nil),
		},
	},
	{
		name = "optionals",
		build = function(T: any): { any }
			return {
				T.optional(T.u8),
				T.optional(T.string(4)),
				T.optional(T.optional(T.bool)),
				T.optional(T.struct({ a = T.u8 })),
			}
		end,
		values = {
			args(nil, nil, nil, nil),
			args(3, "ab", false, { a = 1 }),
			args(3, "abcde", nil, nil),
			args(nil, nil, true, { a = 300 }),
		},
	},
	{
		name = "arrays",
		build = function(T: any): { any }
			return {
				T.array(T.u8, 4),
				T.array(T.bool, 1000),
				T.array(T.struct({ a = T.u8, b = T.f32 }), 3),
				T.array(T.string(4), 3),
			}
		end,
		values = {
			args({ 1, 2, 3 }, bools, { { a = 1, b = 0.5 }, { a = 2, b = -1 } }, { "ab", "" }),
			args({}, {}, {}, {}),
			args({ 1, 2, 3, 4, 5 }, {}, {}, {}),
			args(list(1, "x"), {}, {}, {}),
			args({}, list(true, 1), {}, {}),
			args({}, {}, { { a = 1 } }, {}),
		},
	},
	{
		name = "maps",
		build = function(T: any): { any }
			return { T.map(T.string(8), T.u16, 4), T.map(T.u8, T.bool, 4) }
		end,
		values = {
			args({ a = 1, b = 2 }, { [1] = true, [7] = false }),
			args({}, {}),
			args({ a = 1, b = 2, c = 3, d = 4, e = 5 }, {}),
			args({ [5] = 1 }, {}),
			args({}, { [256] = true }),
		},
	},
	{
		name = "Entity-like struct",
		build = function(T: any): { any }
			return {
				T.struct({
					id = T.u16,
					pos = T.Vector3,
					hp = T.u8,
					name = T.string(16),
					alive = T.bool,
					tags = T.optional(T.array(T.u8, 4)),
				}),
			}
		end,
		values = {
			args(entity(7)),
			args({ id = 1, pos = Vector3.zero, hp = 0, name = "", alive = false }),
			args(entity(70000)),
			args({ id = 1 }),
			args("x"),
		},
	},
	{
		name = "Instances (sidecar)",
		build = function(T: any): { any }
			return { T.Instance(), T.optional(T.Instance("Folder")), T.string(8), T.array(T.Instance(), 4) }
		end,
		values = {
			args(part, folderA, "x", list(folderA, part)),
			args(folderB, nil, "y", {}),
			args(part, part, "z", {}),
			args(nil, nil, "w", {}),
		},
	},
	{
		name = "Instances on an unreliable route",
		build = function(T: any): { any }
			return { T.u8, T.optional(T.Instance()) }
		end,
		unreliable = true,
		values = { args(1, nil), args(2, part) },
	},
	{
		name = "T.any",
		build = function(T: any): { any }
			return { T.any, T.optional(T.any), T.array(T.any, 3) }
		end,
		values = {
			args(1, nil, list("a", 2, true)),
			args({ x = { y = { 1, 2 } } }, "s", {}),
			args(function() end, nil, {}),
			args(part, Vector3.one, { part }),
			args(NAN, -0, { INF }),
		},
	},
	{
		name = "untyped",
		build = nil,
		values = {
			args(),
			args(nil),
			args(
				1,
				"a",
				nil,
				true,
				list(1, list(2, { 3 })),
				{ k = "v" },
				Vector3.new(1, 2, 3),
				CFrame.new(1, 2, 3),
				part,
				NAN,
				-0,
				2 ^ 40,
				buffer.fromstring("xyz"),
				Enum.Material.Grass,
				Color3.new(1, 0, 0),
				Vector2.new(1, 2),
				300,
				-70000
			),
			args({ [1] = "a", [3] = "c" }, setmetatable({ z = 1 }, {}), mixedKeys),
			args(function() end, coroutine.create(function() end)),
			args(table.unpack(table.create(25, 1))),
			args(cyclic),
			args(deep),
		},
	},
	{
		name = "untyped, unreliable",
		build = nil,
		unreliable = true,
		values = { args(1, "a", { 1, 2 }), args({ [1] = "a", [3] = "c" }), args(part) },
	},
	{
		name = "untyped, InlineTables off",
		build = nil,
		inline = false,
		values = { args({ 1, 2 }, { k = { 1 } }, "s"), args({}) },
	},
}

type Encoded = { text: string, status: number, bytes: buffer?, refs: { any }, nrefs: number }

local function compile(side: Side, case: Case, c2s: boolean): any
	local descs = if case.build then case.build(side.Schema.T) else nil
	local max = if c2s then MAX_C2S else MAX_S2C
	return side.Schema.compile(descs, case.anf == true, max, case.unreliable == true)
end

local function encodeOn(side: Side, pc: any, case: Case, c2s: boolean, values: Args): Encoded
	local w = side.Codec.newWriter(16, c2s)
	w.unreliable = case.unreliable == true
	w.inlineTables = case.inline ~= false
	local ok, st = pcall(pc.encode, w, values.n, table.unpack(values, 1, values.n))
	if not ok then
		return { text = "encode threw", status = -1, bytes = nil, refs = {}, nrefs = 0 }
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
		text ..= " bytes=" .. hex(buffer.tostring(b)) .. " refs=" .. show(refs)
	end
	return { text = text, status = st, bytes = bytes, refs = refs, nrefs = w.nrefs }
end

type Input = { b: buffer, lim: number, refs: { any }?, nrefs: number }

local function decodeOn(side: Side, pc: any, c2s: boolean, input: Input): string
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
	local argv = {}
	local ok, n, q = pcall(pc.decode, input.b, 0, input.lim, ctx, argv)
	if not ok then
		return "decode threw" .. walk
	end
	local text = string.format("err=%d errArg=%d n=%s q=%s", ctx.err, ctx.errArg, tostring(n), tostring(q))
	text ..= string.format(" cursor=%d%s", ctx.cursor, walk)
	if c2s then
		local flags: { string } = {}
		for i = 1, nrefs do
			table.insert(flags, tostring(ctx.refFlags[i]))
		end
		text ..= " flags=" .. table.concat(flags, ",")
	end
	if ctx.err == 0 or ctx.err == D_MISSING then
		text ..= " argv=" .. show(argv)
	end
	return text
end

type Checker = {
	pcs: { any },
	c2s: boolean,
	mismatches: { string },
	count: number,
	work: number,
}

local function note(ck: Checker, what: string, a: string, b: string)
	ck.count += 1
	if #ck.mismatches < MISMATCHES_SHOWN then
		local now, old = string.sub(a, 1, 400), string.sub(b, 1, 400)
		table.insert(ck.mismatches, string.format("%s\n    %s: %s\n    %s: %s", what, NOW.name, now, OLD.name, old))
	end
end

local function sameDecode(ck: Checker, input: Input, what: string)
	ck.work += 1
	if ck.work % YIELD_EVERY == 0 then
		task.wait()
	end
	local a = decodeOn(NOW, ck.pcs[1], ck.c2s, input)
	local o = decodeOn(OLD, ck.pcs[2], ck.c2s, input)
	if a ~= o then
		note(ck, what, a, o)
	end
end

local function copyOf(b: buffer): buffer
	local c = buffer.create(buffer.len(b))
	buffer.copy(c, 0, b, 0, buffer.len(b))
	return c
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

local function fuzzValid(ck: Checker, rng: Random, valid: Input, where: string)
	local b, len = valid.b, valid.lim
	for cut = 0, len - 1 do
		if cut < CUTS or rng:NextInteger(1, 8) == 1 then
			local input: Input = { b = b, lim = cut, refs = valid.refs, nrefs = valid.nrefs }
			sameDecode(ck, input, string.format("%s: cut at %d of %d", where, cut, len))
		end
	end
	for _ = 1, math.min(MUTATION_SPOTS, len) do
		local at = rng:NextInteger(0, len - 1)
		local old = buffer.readu8(b, at)
		for _, x in { 0, 1, 0x7F, 0x80, 0xFF, (old + 1) % 256 } do
			if x ~= old then
				local m = copyOf(b)
				buffer.writeu8(m, at, x)
				local input: Input = { b = m, lim = len, refs = valid.refs, nrefs = valid.nrefs }
				sameDecode(ck, input, string.format("%s: byte %d = %d", where, at, x))
			end
		end
	end
end

local function runCase(case: Case, index: number): Checker
	local ck: Checker = { pcs = {}, c2s = false, mismatches = {}, count = 0, work = 0 }
	for _, c2s in { false, true } do
		local dir = if c2s then "C->S" else "S->C"
		ck.c2s = c2s
		ck.pcs = { compile(NOW, case, c2s), compile(OLD, case, c2s) }
		local rng = Random.new(index * 10 + (if c2s then 1 else 0))
		local fuzzed = false
		for vi, values in case.values do
			local where = string.format("%s value %d", dir, vi)
			local ea = encodeOn(NOW, ck.pcs[1], case, c2s, values)
			local eo = encodeOn(OLD, ck.pcs[2], case, c2s, values)
			if ea.text ~= eo.text then
				note(ck, where .. ": encode", ea.text, eo.text)
				continue
			end
			local b = ea.bytes
			if b == nil then
				continue
			end
			local refs: { any }? = if ea.nrefs > 0 then ea.refs else nil
			local valid: Input = { b = b, lim = buffer.len(b), refs = refs, nrefs = ea.nrefs }
			sameDecode(ck, valid, where .. ": decode")
			if not c2s and ea.nrefs > 0 then
				local hidden: { any } = table.create(ea.nrefs)
				for k, ref in ea.refs do
					if typeof(ref) ~= "Instance" then
						hidden[k] = ref
					end
				end
				local input: Input = { b = b, lim = valid.lim, refs = hidden, nrefs = ea.nrefs }
				sameDecode(ck, input, where .. ": decode, Instances hidden")
			end
			if not fuzzed then
				fuzzed = true
				fuzzValid(ck, rng, valid, where)
			end
		end
		local fuzzRefs: { any } = { folderA, part, { 1, 2 } }
		for r = 1, RANDOM_BUFFERS do
			local b = randomBuffer(rng, 48)
			local input: Input = { b = b, lim = buffer.len(b), refs = fuzzRefs, nrefs = if c2s then 3 else 0 }
			sameDecode(ck, input, string.format("%s: random buffer %d (%s)", dir, r, hex(buffer.tostring(b))))
		end
	end
	return ck
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.afterAll(function()
		folderA:Destroy()
		folderB:Destroy()
		part:Destroy()
	end)

	describe("frozen v2 interpreter (the differential reference)", function()
		it("is a separate copy of the same wire version", function()
			expect(OLD.Schema).never.toBe(NOW.Schema)
			expect(OLD.Codec).never.toBe(NOW.Codec)
			expect(OLD.C.PROTO).toBe(NOW.C.PROTO)
		end)

		for index, case in CASES do
			it(case.name .. ": runtime and frozen v2 agree (encode, decode, cuts, mutations, random bytes)", function()
				local ck = runCase(case, index)
				if ck.count > 0 then
					local shown = table.concat(ck.mismatches, "\n  ")
					error(string.format("%d mismatch(es); first %d:\n  %s", ck.count, #ck.mismatches, shown), 0)
				end
			end, { timeout = 60 })
		end
	end)
end
