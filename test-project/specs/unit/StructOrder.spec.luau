--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Runtime = ReplicatedStorage.LorenRuntime
local FrozenV2 = ServerStorage.LorenTest.Frozen.v2

type Side = { name: string, C: any, Codec: any, Schema: any }
type Shape = { [string]: any }
type Kind = { decode: Shape, wire: Shape, values: { any }, toggles: boolean }
type Family = { name: string, kinds: { string }, nilable: boolean }
type Path = { name: string, wrap: (s: Shape) -> { Shape }, values: (a: any, b: any, c: any) -> { any } }
type Mode = { c2s: boolean, anf: boolean }
type Checker = { mismatches: { string }, count: number }
type Built = { names: { string }, decode: Shape, wire: Shape, toggles: number }

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

local MAX_C2S = NOW.C.Limit.MAX_ARGS_C2S
local MAX_S2C = NOW.C.Limit.MAX_ARGS_S2C
local YIELD_AFTER = 0.05
local CONTEXT = 48
local TAIL = 160
local TRIES = 400
local SHARP = 3
local PLAIN = 2
local NAN = 0 / 0

local shown = Instance.new("Folder")
shown.Name = "StructOrderShown"
local ghost = Instance.new("Folder")
ghost.Name = "StructOrderGhost"

local function ordered(x: any, depth: number?): string
	local d = depth or 0
	if d > 16 then
		return "<too deep>"
	end
	local t = typeof(x)
	if t == "table" then
		local parts: { string } = {}
		for k, v in next, x do
			table.insert(parts, ordered(k, d + 1) .. "=" .. ordered(v, d + 1))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "number" then
		return if x ~= x then "nan" else string.format("%.17g", x)
	elseif t == "string" then
		return string.format("%q", x)
	elseif t == "Vector3" then
		return string.format("V3(%s,%s,%s)", ordered(x.X), ordered(x.Y), ordered(x.Z))
	elseif t == "Instance" then
		return "I:" .. (x :: Instance).Name
	end
	return t .. ":" .. tostring(x)
end

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

local function S(k: string, extra: { [string]: any }?): Shape
	local s: Shape = { k = k }
	if extra then
		for key, v in extra do
			s[key] = v
		end
	end
	return s
end

local U8, U16, STR, V3, ANY, INST, EI = S("u8"), S("u16"), S("string"), S("V3"), S("any"), S("inst"), S("EI")
local ENUM3 = S("enum", { items = { "A", "B", "C" } })
local ENUM4 = S("enum", { items = { "A", "B", "C", "D" } })

local function OPT(inner: Shape): Shape
	return S("opt", { inner = inner })
end
local function ARR(inner: Shape, max: number): Shape
	return S("arr", { inner = inner, max = max })
end
local function STRUCT(fields: { [string]: Shape }): Shape
	return S("struct", { fields = fields })
end

local function build(T: any, s: Shape): any
	local k = s.k
	if k == "u8" then
		return T.u8
	elseif k == "u16" then
		return T.u16
	elseif k == "string" then
		return T.string(8)
	elseif k == "V3" then
		return T.Vector3
	elseif k == "any" then
		return T.any
	elseif k == "inst" then
		return T.Instance()
	elseif k == "EI" then
		return T.EnumItem(Enum.Material)
	elseif k == "enum" then
		return T.enum(s.items)
	elseif k == "opt" then
		return T.optional(build(T, s.inner))
	elseif k == "arr" then
		return T.array(build(T, s.inner), s.max)
	elseif k == "struct" then
		local fields: { [string]: any } = {}
		for name, f in s.fields :: { [string]: Shape } do
			fields[name] = build(T, f)
		end
		return T.struct(fields)
	end
	error("StructOrder.spec: unknown shape " .. tostring(k))
end

local function compile(side: Side, shapes: { Shape }, anf: boolean, c2s: boolean): any
	local descs: { any } = table.create(#shapes)
	for i, s in shapes do
		descs[i] = build(side.Schema.T, s)
	end
	return side.Schema.compile(descs, anf, if c2s then MAX_C2S else MAX_S2C, false)
end

local function kind(decode: Shape, wire: Shape, a: any, b: any): Kind
	return { decode = decode, wire = wire, values = { a, b }, toggles = a ~= b }
end

local KINDS: { [string]: Kind } = {
	u8 = kind(U8, U8, 3, 3),
	str = kind(STR, STR, "s", "s"),
	opt = kind(OPT(U8), OPT(U8), nil, 5),
	any = kind(ANY, ANY, nil, "x"),
	enum = kind(ENUM3, ENUM4, "A", "D"),
	ei = kind(EI, U16, Enum.Material.Plastic.Value, 65535),
	inst = kind(INST, INST, shown, ghost),
	opti = kind(OPT(INST), OPT(INST), nil, shown),
	v3 = kind(V3, V3, Vector3.one, Vector3.new(NAN, 1, 1)),
}

local FAMILIES: { Family } = {
	{
		name = "optional fields around required ones",
		kinds = { "opt", "u8", "opt", "str", "opt", "u8" },
		nilable = true,
	},
	{ name = "T.any fields that may be nil", kinds = { "any", "u8", "any", "u8", "any" }, nilable = true },
	{
		name = "a fixed struct with an enum, an EnumItem and a Vector3",
		kinds = { "enum", "ei", "u8", "v3" },
		nilable = true,
	},
	{ name = "Instances that may be missing", kinds = { "inst", "str", "inst", "u8" }, nilable = true },
	{
		name = "every kind at once",
		kinds = { "opt", "enum", "any", "inst", "u8", "str", "v3", "opti" },
		nilable = true,
	},
	{ name = "required fields only", kinds = { "u8", "v3", "str", "u8" }, nilable = false },
	{ name = "a fixed struct of required fields", kinds = { "u8", "v3", "u8", "u8" }, nilable = false },
}

local PATHS: { Path } = {
	{
		name = "alone (fixedStruct or struct)",
		wrap = function(s: Shape): { Shape }
			return { s }
		end,
		values = function(a: any, _: any, _: any): { any }
			return { a }
		end,
	},
	{
		name = "after a string (decodeFields' OP_STRUCT)",
		wrap = function(s: Shape): { Shape }
			return { STR, s }
		end,
		values = function(a: any, _: any, _: any): { any }
			return { "s", a }
		end,
	},
	{
		name = "three in an array",
		wrap = function(s: Shape): { Shape }
			return { ARR(s, 8) }
		end,
		values = function(a: any, b: any, c: any): { any }
			return { { a, b, c } }
		end,
	},
	{
		name = "inside another struct",
		wrap = function(s: Shape): { Shape }
			return { STRUCT({ inner = s, z = U8 }) }
		end,
		values = function(a: any, _: any, _: any): { any }
			return { { inner = a, z = 1 } }
		end,
	},
}

local MODES: { Mode } = {
	{ c2s = false, anf = false },
	{ c2s = false, anf = true },
	{ c2s = true, anf = false },
	{ c2s = true, anf = true },
}

local function modeName(m: Mode): string
	return (if m.c2s then "C->S" else "S->C") .. (if m.anf then ", AllowNonFinite" else "")
end

local function buildStruct(f: Family, names: { string }): Built
	local decode: { [string]: Shape } = {}
	local wire: { [string]: Shape } = {}
	local toggles = 0
	for i, name in names do
		local k = KINDS[f.kinds[i]]
		decode[name] = k.decode
		wire[name] = k.wire
		if k.toggles then
			toggles += 1
		end
	end
	return { names = names, decode = STRUCT(decode), wire = STRUCT(wire), toggles = toggles }
end

local function structValue(f: Family, b: Built, mask: number): { [string]: any }
	local v: { [string]: any } = {}
	local bit = 0
	for i, name in b.names do
		local k = KINDS[f.kinds[i]]
		local pick = 1
		if k.toggles then
			if bit32.btest(mask, bit32.lshift(1, bit)) then
				pick = 2
			end
			bit += 1
		end
		v[name] = k.values[pick]
	end
	return v
end

local function randomNames(rng: Random, count: number): { string }
	local seen: { [string]: boolean } = {}
	local names: { string } = {}
	while #names < count do
		local chars: { string } = {}
		for i = 1, rng:NextInteger(2, 7) do
			chars[i] = string.char(rng:NextInteger(97, 122))
		end
		local name = table.concat(chars)
		if not seen[name] then
			seen[name] = true
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

type Payload = { b: buffer, refs: { any }, nrefs: number }

local function encode(pc: any, c2s: boolean, values: { any }): Payload
	local w = OLD.Codec.newWriter(16, c2s)
	w.unreliable = false
	w.inlineTables = true
	local st = pc.encode(w, #values, table.unpack(values))
	assert(st == 0, "StructOrder.spec: the frozen encoder refused a value, status " .. tostring(st))
	local b = buffer.create(w.n)
	buffer.copy(b, 0, w.buf, 0, w.n)
	local refs: { any } = table.move(w.refs, 1, w.nrefs, 1, {})
	if not c2s then
		for i = 1, w.nrefs do
			if refs[i] == ghost then
				refs[i] = nil
			end
		end
	end
	return { b = b, refs = refs, nrefs = w.nrefs }
end

local function decode(side: Side, pc: any, c2s: boolean, input: Payload): (string, { any })
	local Codec = side.Codec
	local ctx = Codec.newReadCtx(c2s, c2s)
	local argv: { any } = {}
	if c2s then
		Codec.beginFrame(ctx, if input.nrefs > 0 then input.refs else nil, input.nrefs)
		if input.nrefs > 0 then
			local ok, st = pcall(Codec.walkSidecar, input.refs, input.nrefs, ctx)
			if not ok or st ~= 0 then
				return "walk " .. (if ok then tostring(st) else "threw"), argv
			end
		end
	else
		Codec.beginFrame(ctx, input.refs, 0)
	end
	Codec.beginMessage(ctx, pc.allowNonFinite)
	local ok, n, q = pcall(pc.decode, input.b, 0, buffer.len(input.b), ctx, argv)
	if not ok then
		return "decode threw", argv
	end
	local parts: { string } = {}
	for i = 1, tonumber(n) or 0 do
		parts[i] = ordered(argv[i])
	end
	local text = string.format(
		"err=%d errArg=%d n=%s q=%s cursor=%d args=%s",
		ctx.err,
		ctx.errArg,
		tostring(n),
		tostring(q),
		ctx.cursor,
		table.concat(parts, "; ")
	)
	return text, argv
end

local function templateOrder(f: Family, names: { string }, t: { [string]: any }): string
	local shape: { [string]: boolean } = {}
	for i, name in names do
		local k = f.kinds[i]
		if k ~= "opt" and k ~= "opti" then
			shape[name] = false
		end
	end
	local x: { [string]: any } = table.clone(table.freeze(shape))
	for _, name in names do
		x[name] = t[name]
	end
	return ordered(x)
end

local function sharp(f: Family, names: { string }): boolean
	local b = buildStruct(f, names)
	local enc = compile(OLD, { b.wire }, true, false)
	local dec = compile(OLD, { b.decode }, true, false)
	for mask = 0, 2 ^ b.toggles - 1 do
		tick()
		local _, argv = decode(OLD, dec, false, encode(enc, false, { structValue(f, b, mask) }))
		local t = argv[1]
		if type(t) == "table" and templateOrder(f, names, t) ~= ordered(t) then
			return true
		end
	end
	return false
end

type Sets = { list: { { string } }, sharp: number }

local function nameSets(index: number, f: Family): Sets
	local rng = Random.new(7000 + index)
	local list: { { string } } = {}
	local found = 0
	for try = 1, TRIES do
		local names = randomNames(rng, #f.kinds)
		if try <= PLAIN then
			table.insert(list, names)
		elseif found < SHARP and f.nilable and sharp(f, names) then
			found += 1
			table.insert(list, names)
		end
		if try >= PLAIN and (found >= SHARP or not f.nilable) then
			break
		end
	end
	return { list = list, sharp = found }
end

local function sweep(ck: Checker, f: Family, sets: { { string } })
	for _, names in sets do
		local b = buildStruct(f, names)
		local top = 2 ^ b.toggles
		for _, path in PATHS do
			for _, m in MODES do
				local shapes, wire = path.wrap(b.decode), path.wrap(b.wire)
				local enc = compile(OLD, wire, true, m.c2s)
				local now, old = compile(NOW, shapes, m.anf, m.c2s), compile(OLD, shapes, m.anf, m.c2s)
				for mask = 0, top - 1 do
					tick()
					local x = structValue(f, b, mask)
					local y = structValue(f, b, (mask + 1) % top)
					local z = structValue(f, b, top - 1 - mask)
					local input = encode(enc, m.c2s, path.values(x, y, z))
					local a = decode(NOW, now, m.c2s, input)
					local o = decode(OLD, old, m.c2s, input)
					if a ~= o then
						local what = string.format(
							"names %s, %s, %s, mask %d",
							table.concat(names, ","),
							path.name,
							modeName(m),
							mask
						)
						note(ck, what, a, o)
					end
				end
			end
		end
	end
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	t.afterAll(function()
		shown:Destroy()
		ghost:Destroy()
	end)

	describe("structs iterate in frozen v2's order on every decode path, both ways, AllowNonFinite on/off", function()
		for index, f in FAMILIES do
			it(f.name, function()
				local sets = nameSets(index, f)
				if f.nilable then
					expect(sets.sharp).toBeGreaterThan(0)
				end
				local ck = newChecker()
				sweep(ck, f, sets.list)
				check(ck)
			end, { timeout = 300 })
		end
	end)
end
