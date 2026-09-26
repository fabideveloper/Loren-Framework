--!strict
--!optimize 2

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)
local Codec = require(script.Parent.Codec)

type Descriptor = Types.Descriptor
type StructField = Types.StructField
type MemberSpec = Types.MemberSpec
type PayloadCodec = Types.PayloadCodec
type Writer = Types.Writer
type ReadCtx = Types.ReadCtx

-- One compiled field list. Arrays are indexed by field (1..count) and frozen after construction.
type Prog = {
	count: number,
	root: boolean, -- top-level arguments: a failure at field i sets errArg = i
	names: any, -- { string }: struct field names (values are read and written by name), else false
	ops: { number }, -- C.SchemaOp, with one OPTIONAL level flattened into `opt`
	opt: { boolean }, -- the field has a presence byte
	run: { number }, -- > 0: first field of a fixed-size run (its total bytes); 0: inside a run; -1: variable
	fsz: { number }, -- fixed byte size of the op (0 = variable)
	lo: { number },
	hi: { number }, -- ints/floats: bounds; VECTOR3/VECTOR2: max magnitude (inf = none)
	max: { number }, -- STRING/BUFFER bytes, ARRAY/MAP count, ENUM item count
	pw: { number }, -- length/count prefix width (1, 2 or 4)
	flags: { number }, -- STRING: 1 = Binary; INSTANCE: 1 = Nilable
	emin: { number }, -- ARRAY/MAP: minimum C->S bytes per element / pair
	smin: { number }, -- ARRAY/MAP: minimum S->C bytes per element / pair (an Instance is 0 bytes S->C)
	efast: { number }, -- ARRAY: element op for the scalar loop (BOOL, ints, floats), else 0
	sub: { any },
	sub2: { any }, -- MAP value Prog, ENUM name -> index, ENUMITEM Value -> EnumItem, INSTANCE root (or false)
	anf: boolean, -- AllowNonFinite
}

local OP_BOOL = 1
local OP_U8 = 2
local OP_U16 = 3
local OP_U32 = 4
local OP_I8 = 5
local OP_I16 = 6
local OP_I32 = 7
local OP_F32 = 8
local OP_F64 = 9
local OP_STRING = 10
local OP_BUFFER = 11
local OP_VECTOR3 = 12
local OP_VECTOR2 = 13
local OP_COLOR3 = 14
local OP_CFRAME = 15
local OP_ENUM = 16
local OP_ENUMITEM = 17
local OP_INSTANCE = 18
local OP_OPTIONAL = 19
local OP_ARRAY = 20
local OP_MAP = 21
local OP_STRUCT = 22
local OP_ANY = 23

local D_OVERRUN = 1
local D_BAD_TAG = 2
local D_BAD_VARINT = 3
local D_BAD_REF = 4
local D_BAD_PRESENCE = 6
local D_NONFINITE = 32
local D_RANGE = 33
local D_TOO_LONG = 38
local D_BAD_UTF8 = 39
local D_BAD_ENUM = 40
local D_BAD_TYPE = 41
local D_BAD_INSTANCE = 42
local D_MISSING_INSTANCE = 43

local REF_USED = 2 -- ReadCtx.refFlags bit1 (hostile): the sidecar slot was already referenced this frame
local NESTED_PREALLOC = 64 -- hostile typed arrays of non-scalar elements: slots preallocated at most

local E_NEEDS_REF = 4
local E_BAD_TYPE = 5
local E_RANGE = 6
local E_NONFINITE = 7
local E_TOO_LONG = 8
local E_TOO_MANY_NODES = 9
local E_MISSING = 10
local E_BAD_UTF8 = 11
local E_TOO_MANY_VALUES = 12

local F32_MAX = 3.4028234663852886e38
local F64_MAX = 1.7976931348623157e308
local U32_MAX = 4294967295
local INF = math.huge
local MAX_DESC_DEPTH = 16
local MAX_TYPED_FIELDS = 32
local MAX_NAME = 255
local MAX_REFS = 255
local DEFAULT_MAX = 1024
local TIMEOUT_MIN = 1
local TIMEOUT_MAX = 120
local BACKLOG_MAX = 1024
local BINARY = 1 -- C.DescFlag.Binary
local NILABLE = 1 -- C.DescFlag.Nilable

local KIND_METHOD = 1
local KIND_EVENT = 2
local KIND_SIGNAL = 3

local function inSync(actual: any, expected: { [string]: number }): boolean
	for key, value in expected do
		if actual[key] ~= value then
			return false
		end
	end
	return true
end

assert(
	inSync(C.SchemaOp, {
		BOOL = OP_BOOL,
		U8 = OP_U8,
		U16 = OP_U16,
		U32 = OP_U32,
		I8 = OP_I8,
		I16 = OP_I16,
		I32 = OP_I32,
		F32 = OP_F32,
		F64 = OP_F64,
		STRING = OP_STRING,
		BUFFER = OP_BUFFER,
		VECTOR3 = OP_VECTOR3,
		VECTOR2 = OP_VECTOR2,
		COLOR3 = OP_COLOR3,
		CFRAME = OP_CFRAME,
		ENUM = OP_ENUM,
		ENUMITEM = OP_ENUMITEM,
		INSTANCE = OP_INSTANCE,
		OPTIONAL = OP_OPTIONAL,
		ARRAY = OP_ARRAY,
		MAP = OP_MAP,
		STRUCT = OP_STRUCT,
		ANY = OP_ANY,
	})
		and inSync(C.Decode, {
			OVERRUN = D_OVERRUN,
			BAD_TAG = D_BAD_TAG,
			BAD_VARINT = D_BAD_VARINT,
			BAD_REF = D_BAD_REF,
			BAD_PRESENCE = D_BAD_PRESENCE,
			NONFINITE = D_NONFINITE,
			RANGE = D_RANGE,
			TOO_LONG = D_TOO_LONG,
			BAD_UTF8 = D_BAD_UTF8,
			BAD_ENUM = D_BAD_ENUM,
			BAD_TYPE = D_BAD_TYPE,
			BAD_INSTANCE = D_BAD_INSTANCE,
			MISSING_INSTANCE = D_MISSING_INSTANCE,
		})
		and inSync(C.Encode, {
			NEEDS_REF = E_NEEDS_REF,
			BAD_TYPE = E_BAD_TYPE,
			RANGE = E_RANGE,
			NONFINITE = E_NONFINITE,
			TOO_LONG = E_TOO_LONG,
			TOO_MANY_NODES = E_TOO_MANY_NODES,
			MISSING = E_MISSING,
			BAD_UTF8 = E_BAD_UTF8,
			TOO_MANY_VALUES = E_TOO_MANY_VALUES,
		})
		and inSync(C.Limit, {
			F32_MAX = F32_MAX,
			F64_MAX = F64_MAX,
			MAX_DESC_DEPTH = MAX_DESC_DEPTH,
			MAX_TYPED_FIELDS = MAX_TYPED_FIELDS,
			MAX_NAME = MAX_NAME,
			MAX_REFS = MAX_REFS,
			DEFAULT_STRING_MAX = DEFAULT_MAX,
			DEFAULT_BUFFER_MAX = DEFAULT_MAX,
			DEFAULT_COUNT_MAX = DEFAULT_MAX,
			TIMEOUT_MIN = TIMEOUT_MIN,
			TIMEOUT_MAX = TIMEOUT_MAX,
			BACKLOG_MAX = BACKLOG_MAX,
		})
		and inSync(C.DescFlag, { Binary = BINARY, Nilable = NILABLE })
		and inSync(C.Kind, { Method = KIND_METHOD, Event = KIND_EVENT, Signal = KIND_SIGNAL }),
	C.PREFIX .. "Schema constants are out of sync with Constants.luau"
)

-- Encoded size of each op when constant (0 = variable), indexed by op.
local FIXED_SIZE: { number } = { 1, 1, 2, 4, 1, 2, 4, 4, 8, 0, 0, 12, 8, 12, 48, 1, 2, 0, 0, 0, 0, 0, 0 }
local OP_NAME: { string } = {
	"bool",
	"u8",
	"u16",
	"u32",
	"i8",
	"i16",
	"i32",
	"f32",
	"f64",
	"string",
	"buffer",
	"Vector3",
	"Vector2",
	"Color3",
	"CFrame",
	"enum",
	"EnumItem",
	"Instance",
	"optional",
	"array",
	"map",
	"struct",
	"any",
}
local INT_LO: { [number]: number } =
	{ [OP_U8] = 0, [OP_U16] = 0, [OP_U32] = 0, [OP_I8] = -128, [OP_I16] = -32768, [OP_I32] = -2147483648 }
local INT_HI: { [number]: number } =
	{ [OP_U8] = 255, [OP_U16] = 65535, [OP_U32] = U32_MAX, [OP_I8] = 127, [OP_I16] = 32767, [OP_I32] = 2147483647 }
-- T.map keys: bool, integers, floats, string, enum, EnumItem
local KEY_OPS: { [number]: boolean } = {
	[OP_BOOL] = true,
	[OP_U8] = true,
	[OP_U16] = true,
	[OP_U32] = true,
	[OP_I8] = true,
	[OP_I16] = true,
	[OP_I32] = true,
	[OP_F32] = true,
	[OP_F64] = true,
	[OP_STRING] = true,
	[OP_ENUM] = true,
	[OP_ENUMITEM] = true,
}

local DEPTH_TEXT = "types nest deeper than 16 levels"
local REF_FREE_TEXT = "Unreliable and Coalesce members need typed Args without T.Instance or T.any"

-- [[ Helpers ]] --------------------------------------------------------------------------------------------------

local function isInteger(v: any): boolean
	return type(v) == "number" and v % 1 == 0 and math.floor(v) == v
end

local function prefixWidth(max: number): number
	if max <= 255 then
		return 1
	elseif max <= 65535 then
		return 2
	end
	return 4
end

local function getEnum(name: string): any
	return (Enum :: any)[name]
end

local f32Scratch = buffer.create(4)

local function toF32(x: number): number
	buffer.writef32(f32Scratch, 0, x)
	return buffer.readf32(f32Scratch, 0)
end

-- The next f32 after x (x itself an f32) toward +inf (up) or -inf.
local function f32Step(x: number, up: boolean): number
	if x == 0 then
		buffer.writeu32(f32Scratch, 0, if up then 0x00000001 else 0x80000001)
	else
		buffer.writef32(f32Scratch, 0, x)
		local bits = buffer.readu32(f32Scratch, 0)
		-- the magnitude grows when moving away from zero
		buffer.writeu32(f32Scratch, 0, if (x > 0) == up then bits + 1 else bits - 1)
	end
	return buffer.readf32(f32Scratch, 0)
end

local function f32Down(x: number): number
	local r = toF32(x)
	if r > x then
		r = f32Step(r, false)
	end
	return r
end

local function f32Up(x: number): number
	local r = toF32(x)
	if r < x then
		r = f32Step(r, true)
	end
	return r
end

-- [[ Descriptors ]] ----------------------------------------------------------------------------------------------

local DescMeta: { [string]: any } = {}
local SpecMeta: { [string]: any } = {}

local function isDescriptor(v: any): boolean
	return type(v) == "table" and getmetatable(v) == DescMeta
end

local function isSpec(v: any): boolean
	return type(v) == "table" and getmetatable(v) == SpecMeta
end

local function newDesc(op: number, fixed: number, minSize: number, refs: boolean): Descriptor
	return {
		op = op,
		lo = 0,
		hi = 0,
		max = 0,
		flags = 0,
		fixed = fixed,
		minSize = minSize,
		refs = refs,
	}
end

local function seal(d: Descriptor): Descriptor
	setmetatable(d :: any, DescMeta)
	table.freeze(d :: any)
	return d
end

-- Nesting depth (a scalar is 1). Memoized: descriptors are immutable and may be shared (a DAG).
local depthCache: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function descDepth(d: Descriptor): number
	local cached = depthCache[d]
	if cached then
		return cached
	end
	local op = d.op
	local depth = 1
	if op == OP_OPTIONAL or op == OP_ARRAY then
		depth = 1 + descDepth(d.inner :: Descriptor)
	elseif op == OP_MAP then
		depth = 1 + math.max(descDepth(d.key :: Descriptor), descDepth(d.inner :: Descriptor))
	elseif op == OP_STRUCT then
		local fields = d.fields :: { StructField }
		local deepest = 0
		for i = 1, #fields do
			deepest = math.max(deepest, descDepth(fields[i].desc))
		end
		depth = 1 + deepest
	end
	depthCache[d] = depth
	return depth
end

-- Minimum encoded bytes S->C (Descriptor.minSize is the C->S form; they differ only for Instances).
local function sminOf(d: Descriptor): number
	local op = d.op
	if op == OP_INSTANCE then
		return 0
	elseif op == OP_STRUCT then
		local fields = d.fields :: { StructField }
		local total = 0
		for i = 1, #fields do
			total += sminOf(fields[i].desc)
		end
		return total
	end
	return d.minSize
end

local function mkInt(op: number, lo: any, hi: any): (Descriptor?, string?)
	local tlo, thi = INT_LO[op], INT_HI[op]
	if lo == nil then
		lo = tlo
	end
	if hi == nil then
		hi = thi
	end
	if not isInteger(lo) or not isInteger(hi) then
		return nil, "lo and hi must be integers"
	end
	if lo < tlo or hi > thi then
		return nil, string.format("lo and hi must be inside %.0f..%.0f", tlo, thi)
	end
	if lo > hi then
		return nil, "lo must not be greater than hi"
	end
	local size = FIXED_SIZE[op]
	local d = newDesc(op, size, size, false)
	d.lo = lo
	d.hi = hi
	return seal(d), nil
end

local function mkFloat(op: number, lo: any, hi: any): (Descriptor?, string?)
	local tmax = if op == OP_F32 then F32_MAX else F64_MAX
	if lo == nil then
		lo = -tmax
	end
	if hi == nil then
		hi = tmax
	end
	if type(lo) ~= "number" or type(hi) ~= "number" then
		return nil, "lo and hi must be numbers"
	end
	-- positive form: NaN and +-inf fail
	if not (lo >= -tmax and lo <= tmax and hi >= -tmax and hi <= tmax) then
		return nil,
			if op == OP_F32 then "lo and hi must be finite and inside the f32 range" else "lo and hi must be finite"
	end
	if lo > hi then
		return nil, "lo must not be greater than hi"
	end
	if op == OP_F32 then
		lo = f32Down(lo)
		hi = f32Up(hi)
	end
	local size = FIXED_SIZE[op]
	local d = newDesc(op, size, size, false)
	d.lo = lo
	d.hi = hi
	return seal(d), nil
end

local function checkMax(max: any, what: string): string?
	if not isInteger(max) or max < 0 or max > U32_MAX then
		return what .. " must be an integer in 0..4294967295"
	end
	return nil
end

local function mkString(max: any, binary: boolean): (Descriptor?, string?)
	local err = checkMax(max, "maxBytes")
	if err then
		return nil, err
	end
	local d = newDesc(OP_STRING, -1, prefixWidth(max), false)
	d.max = max
	d.flags = if binary then BINARY else 0
	return seal(d), nil
end

local function mkBuffer(max: any): (Descriptor?, string?)
	local err = checkMax(max, "maxBytes")
	if err then
		return nil, err
	end
	local d = newDesc(OP_BUFFER, -1, prefixWidth(max), false)
	d.max = max
	return seal(d), nil
end

local function mkVector(op: number, maxMagnitude: any): (Descriptor?, string?)
	if maxMagnitude == nil then
		maxMagnitude = INF
	end
	if type(maxMagnitude) ~= "number" or not (maxMagnitude > 0) then
		return nil, "maxMagnitude must be a number > 0"
	end
	local size = FIXED_SIZE[op]
	local d = newDesc(op, size, size, false)
	d.hi = maxMagnitude
	return seal(d), nil
end

local function mkEnum(names: any): (Descriptor?, string?)
	if type(names) ~= "table" or isDescriptor(names) then
		return nil, 'expected an array of names, e.g. T.enum({ "Red", "Green" })'
	end
	local n = rawlen(names)
	local keys = 0
	for _ in next, names do
		keys += 1
	end
	if keys ~= n then
		return nil, "names must be a plain array (no holes or named keys)"
	end
	if n < 1 or n > 255 then
		return nil, "needs 1..255 names"
	end
	local items: { string } = table.create(n) :: any
	local seen: { [string]: boolean } = {}
	for i = 1, n do
		local name = rawget(names, i)
		if type(name) ~= "string" or #name < 1 or #name > MAX_NAME then
			return nil, string.format("name %d must be a string of 1..255 bytes", i)
		end
		if seen[name] then
			return nil, string.format("duplicate name '%s'", name)
		end
		seen[name] = true
		items[i] = name
	end
	table.freeze(items :: any)
	local d = newDesc(OP_ENUM, 1, 1, false)
	d.items = items
	return seal(d), nil
end

local function mkEnumItem(enum: any): (Descriptor?, string?)
	if typeof(enum) ~= "Enum" then
		return nil, "expected an Enum, e.g. T.EnumItem(Enum.Material)"
	end
	local name = tostring(enum)
	local ok, same = pcall(getEnum, name)
	if not ok or same ~= enum then
		return nil, "Enum." .. name .. " cannot be found by name"
	end
	for _, item in enum:GetEnumItems() do
		local value = item.Value
		if not isInteger(value) or value < 0 or value > 65535 then
			return nil, string.format("Enum.%s.%s has Value %s, outside 0..65535", name, item.Name, tostring(value))
		end
	end
	local d = newDesc(OP_ENUMITEM, 2, 2, false)
	d.enumName = name
	return seal(d), nil
end

local function mkInstance(className: any, root: any, nilable: boolean): (Descriptor?, string?)
	if className == nil then
		className = ""
	end
	if type(className) ~= "string" or #className > MAX_NAME then
		return nil, "className must be a string of at most 255 bytes"
	end
	if root ~= nil and typeof(root) ~= "Instance" then
		return nil, "root must be an Instance"
	end
	local d = newDesc(OP_INSTANCE, -1, 1, true)
	d.className = className
	d.root = root
	d.flags = if nilable then NILABLE else 0
	return seal(d), nil
end

local function mkOptional(inner: any): (Descriptor?, string?)
	if not isDescriptor(inner) then
		return nil, "expected a Loren.T type"
	end
	local t = inner :: Descriptor
	-- directly under OPTIONAL, an Instance that arrives nil (streamed out, not replicated) is accepted
	if t.op == OP_INSTANCE and t.flags ~= NILABLE then
		t = (mkInstance(t.className, t.root, true)) :: Descriptor
	end
	if descDepth(t) >= MAX_DESC_DEPTH then
		return nil, DEPTH_TEXT
	end
	local d = newDesc(OP_OPTIONAL, -1, 1, t.refs)
	d.inner = t
	return seal(d), nil
end

local function mkArray(inner: any, max: any): (Descriptor?, string?)
	if not isDescriptor(inner) then
		return nil, "expected a Loren.T element type"
	end
	if max == nil then
		max = DEFAULT_MAX
	end
	local err = checkMax(max, "maxCount")
	if err then
		return nil, err
	end
	local t = inner :: Descriptor
	if descDepth(t) >= MAX_DESC_DEPTH then
		return nil, DEPTH_TEXT
	end
	local d = newDesc(OP_ARRAY, -1, prefixWidth(max), t.refs)
	d.inner = t
	d.max = max
	return seal(d), nil
end

local function mkMap(key: any, value: any, max: any): (Descriptor?, string?)
	if not isDescriptor(key) or not isDescriptor(value) then
		return nil, "expected Loren.T key and value types"
	end
	local k, v = key :: Descriptor, value :: Descriptor
	if not KEY_OPS[k.op] then
		return nil, "keys must be T.bool, an integer, a float, T.string, T.enum or T.EnumItem"
	end
	if max == nil then
		max = DEFAULT_MAX
	end
	local err = checkMax(max, "maxCount")
	if err then
		return nil, err
	end
	if math.max(descDepth(k), descDepth(v)) >= MAX_DESC_DEPTH then
		return nil, DEPTH_TEXT
	end
	local d = newDesc(OP_MAP, -1, prefixWidth(max), v.refs)
	d.key = k
	d.inner = v
	d.max = max
	return seal(d), nil
end

-- names must be sorted (bytewise) and unique; descs[i] belongs to names[i].
local function mkStruct(names: { string }, descs: { Descriptor }): (Descriptor?, string?)
	local n = #names
	if n < 1 or n > 255 then
		return nil, "a struct needs 1..255 fields"
	end
	local fields: { StructField } = table.create(n) :: any
	local fixed, minSize, refs, deepest = 0, 0, false, 0
	for i = 1, n do
		local name, desc = names[i], descs[i]
		if #name < 1 or #name > MAX_NAME then
			return nil, "field names must be 1..255 bytes"
		end
		if i > 1 and not (names[i - 1] < name) then
			return nil, "field names must be unique and sorted"
		end
		local field: StructField = { name = name, desc = desc }
		table.freeze(field :: any)
		fields[i] = field
		if fixed >= 0 and desc.fixed >= 0 then
			fixed += desc.fixed
		else
			fixed = -1
		end
		minSize += desc.minSize
		refs = refs or desc.refs
		deepest = math.max(deepest, descDepth(desc))
	end
	if deepest >= MAX_DESC_DEPTH then
		return nil, DEPTH_TEXT
	end
	table.freeze(fields :: any)
	local d = newDesc(OP_STRUCT, fixed, minSize, refs)
	d.fields = fields
	return seal(d), nil
end

local function describe(d: Descriptor): string
	local op = d.op
	local name = "T." .. (OP_NAME[op] or "?")
	if op >= OP_U8 and op <= OP_F64 then
		return string.format("%s(%s, %s)", name, tostring(d.lo), tostring(d.hi))
	elseif op == OP_STRING or op == OP_BUFFER or op == OP_ARRAY or op == OP_MAP then
		return string.format("%s(max %.0f)", name, d.max)
	elseif op == OP_ENUMITEM then
		return string.format("T.EnumItem(Enum.%s)", tostring(d.enumName))
	elseif op == OP_INSTANCE then
		return string.format('T.Instance("%s")', tostring(d.className))
	end
	return name
end

local function stringOptions(opts: any): (boolean, string?)
	if opts == nil then
		return false, nil
	end
	if type(opts) ~= "table" or isDescriptor(opts) then
		return false, "options must be a table like { Binary = true }"
	end
	for key, value in next, opts do
		if key ~= "Binary" then
			return false, "unknown option '" .. tostring(key) .. "' (the only option is Binary)"
		end
		if type(value) ~= "boolean" then
			return false, "Binary must be true or false"
		end
	end
	return opts.Binary == true, nil
end

-- Refinement: T.u8(lo, hi), T.f32(lo, hi), T.string(max, opts), T.buffer(max), T.Vector3(maxMagnitude).
DescMeta.__call = function(self: Descriptor, ...: any): Descriptor
	local op = self.op
	local n = select("#", ...)
	local a, b = ...
	local d: Descriptor?, err: string? = nil, nil
	if op >= OP_U8 and op <= OP_I32 then
		if n > 2 then
			err = "takes (lo, hi)"
		else
			d, err = mkInt(op, a, b)
		end
	elseif op == OP_F32 or op == OP_F64 then
		if n > 2 then
			err = "takes (lo, hi)"
		else
			d, err = mkFloat(op, a, b)
		end
	elseif op == OP_STRING then
		if n > 2 then
			err = "takes (maxBytes, { Binary = true }?)"
		else
			local binary, oerr = stringOptions(b)
			if oerr then
				err = oerr
			else
				d, err = mkString(if a == nil then DEFAULT_MAX else a, binary)
			end
		end
	elseif op == OP_BUFFER then
		if n > 1 then
			err = "takes (maxBytes)"
		else
			d, err = mkBuffer(if a == nil then DEFAULT_MAX else a)
		end
	elseif op == OP_VECTOR3 or op == OP_VECTOR2 then
		if n > 1 then
			err = "takes (maxMagnitude)"
		else
			d, err = mkVector(op, a)
		end
	else
		err = "has no parameters and cannot be called"
	end
	if d == nil then
		local reason: string = if err then err else "invalid arguments"
		error(C.PREFIX .. "T." .. OP_NAME[op] .. ": " .. reason, 2)
	end
	return d
end
DescMeta.__tostring = describe
DescMeta.__iter = function(self: Descriptor)
	return next, self
end
table.freeze(DescMeta)

-- [[ T catalogue ]] ----------------------------------------------------------------------------------------------

local BOOL = seal(newDesc(OP_BOOL, 1, 1, false))
local COLOR3 = seal(newDesc(OP_COLOR3, 12, 12, false))
local CFRAME = seal(newDesc(OP_CFRAME, 48, 48, false))
local ANY = seal(newDesc(OP_ANY, -1, 1, true))

local T: { [string]: any } = {
	bool = BOOL,
	boolean = BOOL,
	u8 = (mkInt(OP_U8, nil, nil)),
	u16 = (mkInt(OP_U16, nil, nil)),
	u32 = (mkInt(OP_U32, nil, nil)),
	i8 = (mkInt(OP_I8, nil, nil)),
	i16 = (mkInt(OP_I16, nil, nil)),
	i32 = (mkInt(OP_I32, nil, nil)),
	f32 = (mkFloat(OP_F32, nil, nil)),
	f64 = (mkFloat(OP_F64, nil, nil)),
	string = (mkString(DEFAULT_MAX, false)),
	buffer = (mkBuffer(DEFAULT_MAX)),
	Vector3 = (mkVector(OP_VECTOR3, nil)),
	Vector2 = (mkVector(OP_VECTOR2, nil)),
	Color3 = COLOR3,
	CFrame = CFRAME,
	any = ANY,
}

-- Smallest integer type holding lo..hi (unsigned when lo >= 0).
T.int = function(lo: any, hi: any): Descriptor
	if not isInteger(lo) or not isInteger(hi) then
		error(C.PREFIX .. "T.int: takes (lo, hi) integers", 2)
	end
	if lo > hi then
		error(C.PREFIX .. "T.int: lo must not be greater than hi", 2)
	end
	local op: number? = nil
	if lo >= 0 then
		op = if hi <= 255 then OP_U8 elseif hi <= 65535 then OP_U16 elseif hi <= U32_MAX then OP_U32 else nil
	elseif lo >= -128 and hi <= 127 then
		op = OP_I8
	elseif lo >= -32768 and hi <= 32767 then
		op = OP_I16
	elseif lo >= -2147483648 and hi <= 2147483647 then
		op = OP_I32
	end
	if op == nil then
		error(string.format("%sT.int: no integer type holds %.0f..%.0f (u32 or i32 at most)", C.PREFIX, lo, hi), 2)
	end
	return (mkInt(op, lo, hi)) :: Descriptor
end

-- Bounded f64.
T.num = function(lo: any, hi: any): Descriptor
	if lo == nil or hi == nil then
		error(C.PREFIX .. "T.num: takes (lo, hi)", 2)
	end
	local d, err = mkFloat(OP_F64, lo, hi)
	if d == nil then
		error(C.PREFIX .. "T.num: " .. (err :: string), 2)
	end
	return d
end

T.enum = function(names: any): Descriptor
	local d, err = mkEnum(names)
	if d == nil then
		error(C.PREFIX .. "T.enum: " .. (err :: string), 2)
	end
	return d
end

T.EnumItem = function(enum: any): Descriptor
	local d, err = mkEnumItem(enum)
	if d == nil then
		error(C.PREFIX .. "T.EnumItem: " .. (err :: string), 2)
	end
	return d
end

T.Instance = function(className: any, root: any): Descriptor
	local d, err = mkInstance(className, root, false)
	if d == nil then
		error(C.PREFIX .. "T.Instance: " .. (err :: string), 2)
	end
	return d
end

T.optional = function(inner: any): Descriptor
	local d, err = mkOptional(inner)
	if d == nil then
		error(C.PREFIX .. "T.optional: " .. (err :: string), 2)
	end
	return d
end

T.array = function(inner: any, maxCount: any): Descriptor
	local d, err = mkArray(inner, maxCount)
	if d == nil then
		error(C.PREFIX .. "T.array: " .. (err :: string), 2)
	end
	return d
end

T.map = function(key: any, value: any, maxCount: any): Descriptor
	local d, err = mkMap(key, value, maxCount)
	if d == nil then
		error(C.PREFIX .. "T.map: " .. (err :: string), 2)
	end
	return d
end

T.struct = function(shape: any): Descriptor
	if type(shape) ~= "table" or isDescriptor(shape) then
		error(C.PREFIX .. "T.struct: takes a table { name = T.type, ... }", 2)
	end
	local names: { string } = {}
	for key: any, value: any in next, shape do
		if type(key) ~= "string" then
			error(C.PREFIX .. "T.struct: field names must be strings", 2)
		end
		if not isDescriptor(value) then
			error(C.PREFIX .. "T.struct: field '" .. key .. "' is not a Loren.T type", 2)
		end
		table.insert(names, key)
	end
	table.sort(names) -- Luau compares strings bytewise
	local descs: { Descriptor } = table.create(#names) :: any
	for i, name in names do
		descs[i] = rawget(shape, name) :: any
	end
	local d, err = mkStruct(names, descs)
	if d == nil then
		error(C.PREFIX .. "T.struct: " .. (err :: string), 2)
	end
	return d
end

local T_NAMES: { string } = {}
for name in T do
	table.insert(T_NAMES, name)
end
table.sort(T_NAMES)

setmetatable(T, {
	__index = function(_: any, key: any): any
		local hint = ""
		if type(key) == "string" then
			local lower = string.lower(key)
			for _, name in T_NAMES do
				if string.lower(name) == lower then
					hint = " Did you mean '" .. name .. "'?"
					break
				end
			end
		end
		error(
			string.format(
				"%sLoren.T has no type '%s'.%s Types: %s",
				C.PREFIX,
				tostring(key),
				hint,
				table.concat(T_NAMES, ", ")
			),
			2
		)
	end,
})
table.freeze(T)

-- [[ Member specs ]] ---------------------------------------------------------------------------------------------

local KIND_NAME: { string } = { "Method", "Event", "Signal" }
local OPTIONS: { { [string]: boolean } } = {
	{
		Args = true,
		Returns = true,
		Timeout = true,
		RateLimit = true,
		Serial = true,
		CancelOnTimeout = true,
		AllowNonFinite = true,
	},
	{ Args = true, Unreliable = true, Ordered = true, Coalesce = true, RateLimit = true, AllowNonFinite = true },
	{ Args = true, Unreliable = true, Ordered = true, Backlog = true, AllowNonFinite = true },
}
local OPTION_LIST: { string } = {
	"Args, Returns, Timeout, RateLimit, Serial, CancelOnTimeout, AllowNonFinite",
	"Args, Unreliable, Ordered, Coalesce, RateLimit, AllowNonFinite",
	"Args, Unreliable, Ordered, Backlog, AllowNonFinite",
}

SpecMeta.__tostring = function(spec: any): string
	return "Loren." .. (KIND_NAME[spec.kind] or "?") .. "(...)"
end
table.freeze(SpecMeta)

-- A frozen copy of an array of descriptors (Args, Returns, compile input).
local function descList(v: any, what: string): ({ Descriptor }?, string?)
	if type(v) ~= "table" or isDescriptor(v) then
		return nil, what .. " must be an array of Loren.T types"
	end
	local n = rawlen(v)
	local keys = 0
	for _ in next, v do
		keys += 1
	end
	if keys ~= n then
		return nil, what .. " must be a plain array (no holes or named keys)"
	end
	if n > MAX_TYPED_FIELDS then
		return nil, string.format("%s has %d types; at most %d are allowed", what, n, MAX_TYPED_FIELDS)
	end
	local list: { Descriptor } = table.create(n) :: any
	for i = 1, n do
		local d = rawget(v, i)
		if not isDescriptor(d) then
			return nil, string.format("%s[%d] is not a Loren.T type", what, i)
		end
		list[i] = d :: any
	end
	table.freeze(list :: any)
	return list, nil
end

local function parseRateLimit(v: any): (number?, number?)
	if type(v) ~= "table" or isDescriptor(v) or rawlen(v) ~= 2 then
		return nil, nil
	end
	local keys = 0
	for _ in next, v do
		keys += 1
	end
	local rate, burst = rawget(v, 1), rawget(v, 2)
	if keys ~= 2 or type(rate) ~= "number" or type(burst) ~= "number" then
		return nil, nil
	end
	-- the manifest ships both as f32, so they must fit one
	if not (rate > 0 and rate <= F32_MAX and burst >= 1 and burst <= F32_MAX) then
		return nil, nil
	end
	return rate, burst
end

local function suggestKey(key: string, allowed: { [string]: boolean }): string
	local lower = string.lower(key)
	for name in allowed do
		if string.lower(name) == lower then
			return " (did you mean '" .. name .. "'?)"
		end
	end
	return ""
end

-- Loren.Method/Event/Signal(desc1, desc2, ..., options?). Returns (spec, nil) or (nil, reason).
local function parseSpec(kind: number, ...: any): (MemberSpec?, string?)
	local n = select("#", ...)
	local positional: { Descriptor } = {}
	local opts: any = nil
	for i = 1, n do
		local v = select(i, ...)
		if isDescriptor(v) then
			table.insert(positional, v)
		elseif i == n and (v == nil or (type(v) == "table" and not isSpec(v))) then
			opts = v
		else
			return nil,
				string.format(
					"argument %d is a %s, not a Loren.T type%s",
					i,
					if isSpec(v) then "member spec" else typeof(v),
					if i == n then " or an options table" else ""
				)
		end
	end
	if #positional > MAX_TYPED_FIELDS then
		return nil, string.format("%d types given; at most %d are allowed", #positional, MAX_TYPED_FIELDS)
	end

	table.freeze(positional :: any)
	local args: { Descriptor }? = if #positional > 0 then positional else nil
	local returns: { Descriptor }? = nil
	local timeout: number?, rate: number?, burst: number? = nil, nil, nil
	local serial, unreliable, ordered, allowNonFinite = false, false, false, false
	local cancelOnTimeout: boolean?, coalesce: boolean?, backlog: number? = nil, nil, nil

	if opts ~= nil then
		local allowed = OPTIONS[kind]
		for key: any, value: any in next, opts do
			if type(key) ~= "string" then
				if isDescriptor(value) then
					return nil, "pass types as arguments, Loren.X(T.u8, T.string), or as { Args = { T.u8, T.string } }"
				end
				return nil, "option names must be strings"
			end
			local name = key :: string
			if not allowed[name] then
				return nil,
					string.format(
						"unknown option '%s'%s. Options: %s",
						name,
						suggestKey(name, allowed),
						OPTION_LIST[kind]
					)
			end
			if key == "Args" or key == "Returns" then
				if key == "Args" and #positional > 0 then
					return nil, "Args given twice: as arguments and as the Args option"
				end
				local list, err = descList(value, key)
				if list == nil then
					return nil, err
				end
				if key == "Args" then
					args = list
				else
					returns = list
				end
			elseif key == "Timeout" then
				if type(value) ~= "number" or not (value >= TIMEOUT_MIN and value <= TIMEOUT_MAX) then
					return nil, "Timeout must be a number of seconds in 1..120"
				end
				timeout = math.round(value * 10) / 10 -- the manifest ships deciseconds
			elseif key == "RateLimit" then
				local r, b = parseRateLimit(value)
				if r == nil then
					return nil, "RateLimit must be { rate, burst } with rate > 0 and burst >= 1"
				end
				rate, burst = r, b
			elseif key == "Backlog" then
				if not isInteger(value) or value < 0 or value > BACKLOG_MAX then
					return nil, "Backlog must be an integer in 0..1024"
				end
				backlog = value
			elseif type(value) ~= "boolean" then
				return nil, key .. " must be true or false"
			elseif key == "Serial" then
				serial = value
			elseif key == "CancelOnTimeout" then
				cancelOnTimeout = value
			elseif key == "Unreliable" then
				unreliable = value
			elseif key == "Ordered" then
				ordered = value
			elseif key == "Coalesce" then
				coalesce = value
			else -- AllowNonFinite
				allowNonFinite = value
			end
		end
	end

	if ordered and not unreliable then
		return nil, "Ordered requires Unreliable = true (reliable traffic is already ordered)"
	end

	local spec: MemberSpec = {
		kind = kind,
		args = args,
		returns = returns,
		timeout = timeout,
		rate = rate,
		burst = burst,
		serial = serial,
		cancelOnTimeout = cancelOnTimeout,
		unreliable = unreliable,
		ordered = ordered,
		coalesce = coalesce,
		backlog = backlog,
		allowNonFinite = allowNonFinite,
	}
	setmetatable(spec :: any, SpecMeta)
	table.freeze(spec :: any)
	return spec, nil
end

-- [[ Compile: descriptors -> op-lists ]] -------------------------------------------------------------------------

local function buildProg(descs: { Descriptor }, names: any, root: boolean, anf: boolean): Prog
	local n = #descs
	local ops: { number } = table.create(n, 0)
	local opt: { boolean } = table.create(n, false)
	local run: { number } = table.create(n, 0)
	local fsz: { number } = table.create(n, 0)
	local lo: { number } = table.create(n, 0)
	local hi: { number } = table.create(n, 0)
	local max: { number } = table.create(n, 0)
	local pw: { number } = table.create(n, 0)
	local flags: { number } = table.create(n, 0)
	local emin: { number } = table.create(n, 0)
	local smin: { number } = table.create(n, 0)
	local efast: { number } = table.create(n, 0)
	local sub: { any } = table.create(n, false) :: any
	local sub2: { any } = table.create(n, false) :: any
	for i = 1, n do
		local d = descs[i]
		if d.op == OP_OPTIONAL then
			opt[i] = true
			d = d.inner :: Descriptor
		end
		local op = d.op
		ops[i] = op
		fsz[i] = FIXED_SIZE[op]
		lo[i] = d.lo
		hi[i] = d.hi
		max[i] = d.max
		flags[i] = d.flags
		if op == OP_STRING or op == OP_BUFFER then
			pw[i] = prefixWidth(d.max)
		elseif op == OP_ARRAY then
			local e = d.inner :: Descriptor
			local ep = buildProg({ e }, false, false, anf)
			pw[i] = prefixWidth(d.max)
			emin[i] = e.minSize
			smin[i] = sminOf(e)
			sub[i] = ep
			if not ep.opt[1] and ep.ops[1] <= OP_F64 then
				efast[i] = ep.ops[1]
			end
		elseif op == OP_MAP then
			local k, e = d.key :: Descriptor, d.inner :: Descriptor
			pw[i] = prefixWidth(d.max)
			emin[i] = k.minSize + e.minSize
			smin[i] = sminOf(k) + sminOf(e)
			sub[i] = buildProg({ k }, false, false, anf)
			sub2[i] = buildProg({ e }, false, false, anf)
		elseif op == OP_STRUCT then
			local fields = d.fields :: { StructField }
			local fdescs: { Descriptor } = table.create(#fields) :: any
			local fnames: { string } = table.create(#fields) :: any
			for j, field in fields do
				fdescs[j] = field.desc
				fnames[j] = field.name
			end
			table.freeze(fnames :: any)
			sub[i] = buildProg(fdescs, fnames, false, anf)
		elseif op == OP_OPTIONAL then
			-- a second OPTIONAL level: its own one-field Prog (which flattens it again)
			sub[i] = buildProg({ d }, false, false, anf)
		elseif op == OP_ENUM then
			local items = d.items :: { string }
			local index: { [string]: number } = {}
			for j, name in items do
				index[name] = j - 1
			end
			table.freeze(index :: any)
			max[i] = #items
			sub[i] = items
			sub2[i] = index
		elseif op == OP_ENUMITEM then
			local enum = getEnum(d.enumName :: string)
			local byValue: { [number]: any } = {}
			for _, item in enum:GetEnumItems() do
				if byValue[item.Value] == nil then
					byValue[item.Value] = item
				end
			end
			table.freeze(byValue :: any)
			sub[i] = enum
			sub2[i] = byValue
		elseif op == OP_INSTANCE then
			sub[i] = d.className or ""
			sub2[i] = d.root or false
		end
	end
	local i = 1
	while i <= n do
		if fsz[i] > 0 and not opt[i] then
			local j, total = i, 0
			while j <= n and fsz[j] > 0 and not opt[j] do
				total += fsz[j]
				j += 1
			end
			run[i] = total
			i = j
		else
			run[i] = -1
			i += 1
		end
	end
	for _, list in { ops, opt, run, fsz, lo, hi, max, pw, flags, emin, smin, efast, sub, sub2 } :: { any } do
		table.freeze(list :: any)
	end
	local prog: Prog = {
		count = n,
		root = root,
		names = names,
		ops = ops,
		opt = opt,
		run = run,
		fsz = fsz,
		lo = lo,
		hi = hi,
		max = max,
		pw = pw,
		flags = flags,
		emin = emin,
		smin = smin,
		efast = efast,
		sub = sub,
		sub2 = sub2,
		anf = anf,
	}
	table.freeze(prog :: any)
	return prog
end

-- [[ Interpreters ]] ---------------------------------------------------------------------------------------------

-- S->C only: a non-Nilable Instance arrived nil somewhere in the message being decoded (see the header).
local missing = false

local function encodeFail(w: Writer, p: Prog, i: number, st: number): number
	if p.root then
		w.errArg = i
	end
	return st
end

local function decodeFail(ctx: ReadCtx, code: number, p: Prog, i: number, o: number): (number, any)
	ctx.err = code
	if p.root then
		ctx.errArg = i
	end
	return o, nil
end

-- A nested decode already set ctx.err; name the top-level argument.
local function decodePass(ctx: ReadCtx, p: Prog, i: number, o: number): (number, any)
	if p.root then
		ctx.errArg = i
	end
	return o, nil
end

@native
local function encodeFields(w: Writer, p: Prog, src: any, ...: any): number
	local names = p.names
	local ops, opt, run = p.ops, p.opt, p.run
	local b = w.buf
	local off = 0
	for i = 1, p.count do
		local v: any
		if names then
			v = rawget(src, names[i])
		else
			v = select(i, ...)
		end
		local r = run[i]
		if r > 0 then
			off = Codec.reserve(w, r)
			b = w.buf
		elseif r < 0 and opt[i] then
			if v == nil then
				local po = Codec.reserve(w, 1)
				buffer.writeu8(w.buf, po, 0)
				continue
			end
			local po = Codec.reserve(w, 1 + p.fsz[i])
			b = w.buf
			buffer.writeu8(b, po, 1)
			off = po + 1
		end
		local op = ops[i]
		local st = 0
		if op <= OP_F64 then
			if op == OP_BOOL then
				if v == true then
					buffer.writeu8(b, off, 1)
				elseif v == false then
					buffer.writeu8(b, off, 0)
				else
					st = if v == nil then E_MISSING else E_BAD_TYPE
				end
				off += 1
			elseif type(v) ~= "number" then
				st = if v == nil then E_MISSING else E_BAD_TYPE
			elseif op <= OP_I32 then
				if not (v % 1 == 0 and math.floor(v) == v and v >= p.lo[i] and v <= p.hi[i]) then
					st = if v >= -F64_MAX and v <= F64_MAX then E_RANGE else E_NONFINITE
				elseif op == OP_U8 then
					buffer.writeu8(b, off, v)
					off += 1
				elseif op == OP_U16 then
					buffer.writeu16(b, off, v)
					off += 2
				elseif op == OP_U32 then
					buffer.writeu32(b, off, v)
					off += 4
				elseif op == OP_I8 then
					buffer.writei8(b, off, v)
					off += 1
				elseif op == OP_I16 then
					buffer.writei16(b, off, v)
					off += 2
				else
					buffer.writei32(b, off, v)
					off += 4
				end
			else
				-- out of range fails; a non-finite value passes only with AllowNonFinite
				if not (v >= p.lo[i] and v <= p.hi[i]) and (not p.anf or (v >= -F64_MAX and v <= F64_MAX)) then
					st = if v >= -F64_MAX and v <= F64_MAX then E_RANGE else E_NONFINITE
				elseif op == OP_F32 then
					buffer.writef32(b, off, v)
					off += 4
				else
					buffer.writef64(b, off, v)
					off += 8
				end
			end
		elseif op <= OP_ENUMITEM then
			if op == OP_STRING then
				if type(v) ~= "string" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local len = #v
					if len > p.max[i] then
						st = E_TOO_LONG
					elseif p.flags[i] == 0 and utf8.len(v) == nil then
						st = E_BAD_UTF8
					else
						local pw = p.pw[i]
						local po = Codec.reserve(w, pw + len)
						b = w.buf
						if pw == 1 then
							buffer.writeu8(b, po, len)
						elseif pw == 2 then
							buffer.writeu16(b, po, len)
						else
							buffer.writeu32(b, po, len)
						end
						buffer.writestring(b, po + pw, v)
					end
				end
			elseif op == OP_BUFFER then
				if type(v) ~= "buffer" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local len = buffer.len(v)
					if len > p.max[i] then
						st = E_TOO_LONG
					else
						local pw = p.pw[i]
						local po = Codec.reserve(w, pw + len)
						b = w.buf
						if pw == 1 then
							buffer.writeu8(b, po, len)
						elseif pw == 2 then
							buffer.writeu16(b, po, len)
						else
							buffer.writeu32(b, po, len)
						end
						buffer.copy(b, po + pw, v, 0, len)
					end
				end
			elseif op == OP_VECTOR3 then
				if typeof(v) ~= "Vector3" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local x, y, z = v.X, v.Y, v.Z
					if
						not p.anf
						and not (
							x >= -F64_MAX
							and x <= F64_MAX
							and y >= -F64_MAX
							and y <= F64_MAX
							and z >= -F64_MAX
							and z <= F64_MAX
						)
					then
						st = E_NONFINITE
					elseif p.hi[i] <= F64_MAX and not (v.Magnitude <= p.hi[i]) then
						st = E_RANGE
					else
						buffer.writef32(b, off, x)
						buffer.writef32(b, off + 4, y)
						buffer.writef32(b, off + 8, z)
					end
				end
				off += 12
			elseif op == OP_VECTOR2 then
				if typeof(v) ~= "Vector2" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local x, y = v.X, v.Y
					if not p.anf and not (x >= -F64_MAX and x <= F64_MAX and y >= -F64_MAX and y <= F64_MAX) then
						st = E_NONFINITE
					elseif p.hi[i] <= F64_MAX and not (v.Magnitude <= p.hi[i]) then
						st = E_RANGE
					else
						buffer.writef32(b, off, x)
						buffer.writef32(b, off + 4, y)
					end
				end
				off += 8
			elseif op == OP_COLOR3 then
				if typeof(v) ~= "Color3" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local cr, cg, cb = v.R, v.G, v.B
					if
						not p.anf
						and not (
							cr >= -F64_MAX
							and cr <= F64_MAX
							and cg >= -F64_MAX
							and cg <= F64_MAX
							and cb >= -F64_MAX
							and cb <= F64_MAX
						)
					then
						st = E_NONFINITE
					else
						buffer.writef32(b, off, cr)
						buffer.writef32(b, off + 4, cg)
						buffer.writef32(b, off + 8, cb)
					end
				end
				off += 12
			elseif op == OP_CFRAME then
				if typeof(v) ~= "CFrame" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = v:GetComponents()
					if
						not p.anf
						and not (
							x >= -F64_MAX
							and x <= F64_MAX
							and y >= -F64_MAX
							and y <= F64_MAX
							and z >= -F64_MAX
							and z <= F64_MAX
							and r00 >= -F64_MAX
							and r00 <= F64_MAX
							and r01 >= -F64_MAX
							and r01 <= F64_MAX
							and r02 >= -F64_MAX
							and r02 <= F64_MAX
							and r10 >= -F64_MAX
							and r10 <= F64_MAX
							and r11 >= -F64_MAX
							and r11 <= F64_MAX
							and r12 >= -F64_MAX
							and r12 <= F64_MAX
							and r20 >= -F64_MAX
							and r20 <= F64_MAX
							and r21 >= -F64_MAX
							and r21 <= F64_MAX
							and r22 >= -F64_MAX
							and r22 <= F64_MAX
						)
					then
						st = E_NONFINITE
					else
						buffer.writef32(b, off, x)
						buffer.writef32(b, off + 4, y)
						buffer.writef32(b, off + 8, z)
						buffer.writef32(b, off + 12, r00)
						buffer.writef32(b, off + 16, r01)
						buffer.writef32(b, off + 20, r02)
						buffer.writef32(b, off + 24, r10)
						buffer.writef32(b, off + 28, r11)
						buffer.writef32(b, off + 32, r12)
						buffer.writef32(b, off + 36, r20)
						buffer.writef32(b, off + 40, r21)
						buffer.writef32(b, off + 44, r22)
					end
				end
				off += 48
			elseif op == OP_ENUM then
				if type(v) ~= "string" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				else
					local index = p.sub2[i][v]
					if index == nil then
						st = E_RANGE
					else
						buffer.writeu8(b, off, index)
					end
				end
				off += 1
			else -- OP_ENUMITEM
				if typeof(v) ~= "EnumItem" then
					st = if v == nil then E_MISSING else E_BAD_TYPE
				elseif v.EnumType ~= p.sub[i] then
					st = E_BAD_TYPE
				else
					buffer.writeu16(b, off, v.Value)
				end
				off += 2
			end
		elseif op == OP_INSTANCE then
			if typeof(v) ~= "Instance" then
				st = if v == nil then E_MISSING else E_BAD_TYPE
			elseif p.sub[i] ~= "" and not v:IsA(p.sub[i]) then
				st = E_BAD_TYPE
			elseif w.unreliable then
				st = E_NEEDS_REF
			elseif w.indexedRefs and w.nrefs >= MAX_REFS then
				-- this message alone would already need more refs than a C->S frame can carry
				st = E_TOO_MANY_NODES
			else
				Codec.addRef(w, v)
			end
		elseif op == OP_ANY then
			st = Codec.writeValue(w, v, 0)
		elseif op == OP_ARRAY then
			if type(v) ~= "table" then
				st = if v == nil then E_MISSING else E_BAD_TYPE
			else
				local cnt = rawlen(v)
				if cnt > p.max[i] then
					st = E_TOO_LONG
				else
					local pw = p.pw[i]
					local eop = p.efast[i]
					local ep: Prog = p.sub[i]
					local po = Codec.reserve(w, pw + (if eop ~= 0 then cnt * FIXED_SIZE[eop] else 0))
					b = w.buf
					if pw == 1 then
						buffer.writeu8(b, po, cnt)
					elseif pw == 2 then
						buffer.writeu16(b, po, cnt)
					else
						buffer.writeu32(b, po, cnt)
					end
					if eop ~= 0 then
						-- scalar elements: one reservation, a tight loop
						local q = po + pw
						local elo, ehi, anf = ep.lo[1], ep.hi[1], p.anf
						for k = 1, cnt do
							local x = rawget(v, k)
							if eop == OP_BOOL then
								if x == true then
									buffer.writeu8(b, q, 1)
								elseif x == false then
									buffer.writeu8(b, q, 0)
								else
									st = if x == nil then E_MISSING else E_BAD_TYPE
									break
								end
								q += 1
							elseif type(x) ~= "number" then
								st = if x == nil then E_MISSING else E_BAD_TYPE
								break
							elseif eop <= OP_I32 then
								if not (x % 1 == 0 and math.floor(x) == x and x >= elo and x <= ehi) then
									st = if x >= -F64_MAX and x <= F64_MAX then E_RANGE else E_NONFINITE
									break
								end
								if eop == OP_U8 then
									buffer.writeu8(b, q, x)
									q += 1
								elseif eop == OP_U16 then
									buffer.writeu16(b, q, x)
									q += 2
								elseif eop == OP_U32 then
									buffer.writeu32(b, q, x)
									q += 4
								elseif eop == OP_I8 then
									buffer.writei8(b, q, x)
									q += 1
								elseif eop == OP_I16 then
									buffer.writei16(b, q, x)
									q += 2
								else
									buffer.writei32(b, q, x)
									q += 4
								end
							else
								if not (x >= elo and x <= ehi) and (not anf or (x >= -F64_MAX and x <= F64_MAX)) then
									st = if x >= -F64_MAX and x <= F64_MAX then E_RANGE else E_NONFINITE
									break
								end
								if eop == OP_F32 then
									buffer.writef32(b, q, x)
									q += 4
								else
									buffer.writef64(b, q, x)
									q += 8
								end
							end
						end
					else
						for k = 1, cnt do
							st = encodeFields(w, ep, nil, rawget(v, k))
							if st ~= 0 then
								break
							end
						end
					end
				end
			end
		elseif op == OP_STRUCT then
			if type(v) ~= "table" then
				st = if v == nil then E_MISSING else E_BAD_TYPE
			else
				st = encodeFields(w, p.sub[i], v)
			end
		elseif op == OP_MAP then
			if type(v) ~= "table" then
				st = if v == nil then E_MISSING else E_BAD_TYPE
			else
				local pw = p.pw[i]
				local po = Codec.reserve(w, pw)
				local mx = p.max[i]
				local kp: Prog, vp: Prog = p.sub[i], p.sub2[i]
				local cnt = 0
				for key, value in next, v do
					cnt += 1
					if cnt > mx then
						st = E_TOO_LONG
						break
					end
					st = encodeFields(w, kp, nil, key)
					if st ~= 0 then
						break
					end
					st = encodeFields(w, vp, nil, value)
					if st ~= 0 then
						break
					end
				end
				if st == 0 then
					b = w.buf
					if pw == 1 then
						buffer.writeu8(b, po, cnt)
					elseif pw == 2 then
						buffer.writeu16(b, po, cnt)
					else
						buffer.writeu32(b, po, cnt)
					end
				end
			end
		else -- OP_OPTIONAL (a second OPTIONAL level)
			st = encodeFields(w, p.sub[i], nil, v)
		end
		if st ~= 0 then
			return encodeFail(w, p, i, st)
		end
	end
	return 0
end

@native
local function decodeFields(b: buffer, o: number, lim: number, ctx: ReadCtx, p: Prog, dst: any): (number, any)
	local names = p.names
	local ops, opt, run = p.ops, p.opt, p.run
	local hostile = ctx.hostile
	local v: any = nil
	for i = 1, p.count do
		v = nil
		local r = run[i]
		if r > 0 then
			if o + r > lim then
				return decodeFail(ctx, D_OVERRUN, p, i, o)
			end
		elseif r < 0 and opt[i] then
			if o >= lim then
				return decodeFail(ctx, D_OVERRUN, p, i, o)
			end
			local present = buffer.readu8(b, o)
			o += 1
			if present == 0 then
				if dst then
					if names then
						dst[names[i]] = nil
					else
						dst[i] = nil
					end
				end
				continue
			elseif present ~= 1 then
				return decodeFail(ctx, D_BAD_PRESENCE, p, i, o)
			end
			local f = p.fsz[i]
			if f > 0 and o + f > lim then
				return decodeFail(ctx, D_OVERRUN, p, i, o)
			end
		end
		local op = ops[i]
		if op <= OP_F64 then
			if op == OP_BOOL then
				local x = buffer.readu8(b, o)
				o += 1
				if x == 1 then
					v = true
				elseif x == 0 then
					v = false
				else
					return decodeFail(ctx, D_BAD_TAG, p, i, o)
				end
			elseif op <= OP_I32 then
				if op == OP_U8 then
					v = buffer.readu8(b, o)
					o += 1
				elseif op == OP_U16 then
					v = buffer.readu16(b, o)
					o += 2
				elseif op == OP_U32 then
					v = buffer.readu32(b, o)
					o += 4
				elseif op == OP_I8 then
					v = buffer.readi8(b, o)
					o += 1
				elseif op == OP_I16 then
					v = buffer.readi16(b, o)
					o += 2
				else
					v = buffer.readi32(b, o)
					o += 4
				end
				if hostile and not (v >= p.lo[i] and v <= p.hi[i]) then
					return decodeFail(ctx, D_RANGE, p, i, o)
				end
			else
				if op == OP_F32 then
					v = buffer.readf32(b, o)
					o += 4
				else
					v = buffer.readf64(b, o)
					o += 8
				end
				if hostile and not (v >= p.lo[i] and v <= p.hi[i]) then
					if v >= -F64_MAX and v <= F64_MAX then
						return decodeFail(ctx, D_RANGE, p, i, o)
					elseif not p.anf then
						return decodeFail(ctx, D_NONFINITE, p, i, o)
					end
				end
			end
		elseif op <= OP_ENUMITEM then
			if op == OP_STRING or op == OP_BUFFER then
				local pw = p.pw[i]
				if o + pw > lim then
					return decodeFail(ctx, D_OVERRUN, p, i, o)
				end
				local len = if pw == 1
					then buffer.readu8(b, o)
					elseif pw == 2 then buffer.readu16(b, o)
					else buffer.readu32(b, o)
				o += pw
				if len > lim - o then
					return decodeFail(ctx, D_OVERRUN, p, i, o)
				end
				if hostile and len > p.max[i] then
					return decodeFail(ctx, D_TOO_LONG, p, i, o)
				end
				if op == OP_STRING then
					local s = buffer.readstring(b, o, len)
					o += len
					if hostile and p.flags[i] == 0 and utf8.len(s) == nil then
						return decodeFail(ctx, D_BAD_UTF8, p, i, o)
					end
					v = s
				else
					local copy = buffer.create(len)
					buffer.copy(copy, 0, b, o, len)
					o += len
					v = copy
				end
			elseif op == OP_VECTOR3 then
				local x, y, z = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
				o += 12
				if
					hostile
					and not p.anf
					and not (
						x >= -F64_MAX
						and x <= F64_MAX
						and y >= -F64_MAX
						and y <= F64_MAX
						and z >= -F64_MAX
						and z <= F64_MAX
					)
				then
					return decodeFail(ctx, D_NONFINITE, p, i, o)
				end
				v = Vector3.new(x, y, z)
				if hostile and p.hi[i] <= F64_MAX and not (v.Magnitude <= p.hi[i]) then
					return decodeFail(ctx, D_RANGE, p, i, o)
				end
			elseif op == OP_VECTOR2 then
				local x, y = buffer.readf32(b, o), buffer.readf32(b, o + 4)
				o += 8
				if
					hostile
					and not p.anf
					and not (x >= -F64_MAX and x <= F64_MAX and y >= -F64_MAX and y <= F64_MAX)
				then
					return decodeFail(ctx, D_NONFINITE, p, i, o)
				end
				v = Vector2.new(x, y)
				if hostile and p.hi[i] <= F64_MAX and not (v.Magnitude <= p.hi[i]) then
					return decodeFail(ctx, D_RANGE, p, i, o)
				end
			elseif op == OP_COLOR3 then
				local cr, cg, cb = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
				o += 12
				if
					hostile
					and not p.anf
					and not (
						cr >= -F64_MAX
						and cr <= F64_MAX
						and cg >= -F64_MAX
						and cg <= F64_MAX
						and cb >= -F64_MAX
						and cb <= F64_MAX
					)
				then
					return decodeFail(ctx, D_NONFINITE, p, i, o)
				end
				v = Color3.new(cr, cg, cb)
			elseif op == OP_CFRAME then
				local x, y, z = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
				local r00, r01, r02 = buffer.readf32(b, o + 12), buffer.readf32(b, o + 16), buffer.readf32(b, o + 20)
				local r10, r11, r12 = buffer.readf32(b, o + 24), buffer.readf32(b, o + 28), buffer.readf32(b, o + 32)
				local r20, r21, r22 = buffer.readf32(b, o + 36), buffer.readf32(b, o + 40), buffer.readf32(b, o + 44)
				o += 48
				if
					hostile
					and not p.anf
					and not (
						x >= -F64_MAX
						and x <= F64_MAX
						and y >= -F64_MAX
						and y <= F64_MAX
						and z >= -F64_MAX
						and z <= F64_MAX
						and r00 >= -F64_MAX
						and r00 <= F64_MAX
						and r01 >= -F64_MAX
						and r01 <= F64_MAX
						and r02 >= -F64_MAX
						and r02 <= F64_MAX
						and r10 >= -F64_MAX
						and r10 <= F64_MAX
						and r11 >= -F64_MAX
						and r11 <= F64_MAX
						and r12 >= -F64_MAX
						and r12 <= F64_MAX
						and r20 >= -F64_MAX
						and r20 <= F64_MAX
						and r21 >= -F64_MAX
						and r21 <= F64_MAX
						and r22 >= -F64_MAX
						and r22 <= F64_MAX
					)
				then
					return decodeFail(ctx, D_NONFINITE, p, i, o)
				end
				v = CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
			elseif op == OP_ENUM then
				local x = buffer.readu8(b, o)
				o += 1
				if hostile and x >= p.max[i] then
					return decodeFail(ctx, D_BAD_ENUM, p, i, o)
				end
				v = p.sub[i][x + 1]
			else -- OP_ENUMITEM
				local x = buffer.readu16(b, o)
				o += 2
				v = p.sub2[i][x]
				if v == nil and hostile then
					return decodeFail(ctx, D_BAD_ENUM, p, i, o)
				end
			end
		elseif op == OP_INSTANCE then
			local refs = ctx.refs
			if ctx.indexed then
				local index, q = Codec.readVarint(b, o, lim)
				if index < 0 then
					return decodeFail(ctx, if lim - o >= 3 then D_BAD_VARINT else D_OVERRUN, p, i, o)
				end
				o = q
				if index >= ctx.nrefs then
					return decodeFail(ctx, D_BAD_REF, p, i, o)
				end
				if hostile then
					-- one reference per sidecar slot per frame (as Codec.readValue's REF)
					local flags = ctx.refFlags
					local f = flags[index + 1] or 0
					if f >= REF_USED then
						return decodeFail(ctx, D_BAD_REF, p, i, o)
					end
					flags[index + 1] = f + REF_USED
				end
				v = if refs then rawget(refs, index + 1) else nil
			else
				local cursor = ctx.cursor + 1
				ctx.cursor = cursor
				v = if refs then rawget(refs, cursor) else nil
			end
			if v == nil then
				if p.flags[i] ~= NILABLE then
					if hostile then
						return decodeFail(ctx, D_MISSING_INSTANCE, p, i, o)
					end
					missing = true
				end
			elseif hostile then
				if typeof(v) ~= "Instance" then
					return decodeFail(ctx, D_BAD_TYPE, p, i, o)
				end
				local className = p.sub[i]
				if className ~= "" and not v:IsA(className) then
					return decodeFail(ctx, D_BAD_INSTANCE, p, i, o)
				end
				local root = p.sub2[i]
				if root and not v:IsDescendantOf(root) then
					return decodeFail(ctx, D_BAD_INSTANCE, p, i, o)
				end
			end
		elseif op == OP_ANY then
			v, o = Codec.readValue(b, o, lim, ctx, 0)
			if ctx.err ~= 0 then
				return decodePass(ctx, p, i, o)
			end
		elseif op == OP_ARRAY or op == OP_MAP then
			local pw = p.pw[i]
			if o + pw > lim then
				return decodeFail(ctx, D_OVERRUN, p, i, o)
			end
			local cnt = if pw == 1
				then buffer.readu8(b, o)
				elseif pw == 2 then buffer.readu16(b, o)
				else buffer.readu32(b, o)
			o += pw
			-- a count larger than the bytes left is structural; it is checked before anything is allocated
			local emin = if hostile then p.emin[i] else p.smin[i]
			if cnt * emin > lim - o then
				return decodeFail(ctx, D_OVERRUN, p, i, o)
			end
			if cnt > p.max[i] then
				if hostile then
					return decodeFail(ctx, D_TOO_LONG, p, i, o)
				elseif emin == 0 then
					return decodeFail(ctx, D_OVERRUN, p, i, o)
				end
			end
			if op == OP_ARRAY then
				local eop = p.efast[i]
				local t: { any } =
					table.create(if hostile and eop == 0 and cnt > NESTED_PREALLOC then NESTED_PREALLOC else cnt) :: any
				local ep: Prog = p.sub[i]
				if eop ~= 0 then
					-- scalar elements: emin == smin == the element size, so the count check covered every read
					if eop == OP_BOOL then
						for k = 1, cnt do
							local x = buffer.readu8(b, o)
							o += 1
							if x == 1 then
								t[k] = true
							elseif x == 0 then
								t[k] = false
							else
								return decodeFail(ctx, D_BAD_TAG, p, i, o)
							end
						end
					elseif eop <= OP_I32 then
						local elo, ehi = ep.lo[1], ep.hi[1]
						for k = 1, cnt do
							local x = 0
							if eop == OP_U8 then
								x = buffer.readu8(b, o)
								o += 1
							elseif eop == OP_U16 then
								x = buffer.readu16(b, o)
								o += 2
							elseif eop == OP_U32 then
								x = buffer.readu32(b, o)
								o += 4
							elseif eop == OP_I8 then
								x = buffer.readi8(b, o)
								o += 1
							elseif eop == OP_I16 then
								x = buffer.readi16(b, o)
								o += 2
							else
								x = buffer.readi32(b, o)
								o += 4
							end
							if hostile and not (x >= elo and x <= ehi) then
								return decodeFail(ctx, D_RANGE, p, i, o)
							end
							t[k] = x
						end
					else
						local elo, ehi, anf = ep.lo[1], ep.hi[1], p.anf
						for k = 1, cnt do
							local x = 0
							if eop == OP_F32 then
								x = buffer.readf32(b, o)
								o += 4
							else
								x = buffer.readf64(b, o)
								o += 8
							end
							if hostile and not (x >= elo and x <= ehi) then
								if x >= -F64_MAX and x <= F64_MAX then
									return decodeFail(ctx, D_RANGE, p, i, o)
								elseif not anf then
									return decodeFail(ctx, D_NONFINITE, p, i, o)
								end
							end
							t[k] = x
						end
					end
				else
					for k = 1, cnt do
						local x: any
						o, x = decodeFields(b, o, lim, ctx, ep, nil)
						if ctx.err ~= 0 then
							return decodePass(ctx, p, i, o)
						end
						t[k] = x
					end
				end
				v = t
			else
				local m = {}
				local kp: Prog, vp: Prog = p.sub[i], p.sub2[i]
				for _ = 1, cnt do
					local key: any, value: any
					o, key = decodeFields(b, o, lim, ctx, kp, nil)
					if ctx.err ~= 0 then
						return decodePass(ctx, p, i, o)
					end
					if key == nil then
						-- only an unknown enum value on the trusted side decodes to nil (hostile: BAD_ENUM first)
						return decodeFail(ctx, D_BAD_TAG, p, i, o)
					elseif key ~= key then
						-- NaN cannot be a table key: always NONFINITE, even with AllowNonFinite
						return decodeFail(ctx, if hostile then D_NONFINITE else D_BAD_TAG, p, i, o)
					end
					o, value = decodeFields(b, o, lim, ctx, vp, nil)
					if ctx.err ~= 0 then
						return decodePass(ctx, p, i, o)
					end
					m[key] = value
				end
				v = m
			end
		elseif op == OP_STRUCT then
			local t = {}
			o = decodeFields(b, o, lim, ctx, p.sub[i], t)
			if ctx.err ~= 0 then
				return decodePass(ctx, p, i, o)
			end
			v = t
		else -- OP_OPTIONAL (a second OPTIONAL level)
			o, v = decodeFields(b, o, lim, ctx, p.sub[i], nil)
			if ctx.err ~= 0 then
				return decodePass(ctx, p, i, o)
			end
		end
		if dst then
			if names then
				dst[names[i]] = v
			else
				dst[i] = v
			end
		end
	end
	return o, v
end

local function typedCodec(prog: Prog, count: number, refs: boolean, anf: boolean): PayloadCodec
	local codec: PayloadCodec = {
		typed = true,
		count = count,
		maxArgs = count,
		refs = refs,
		allowNonFinite = anf,
		encode = function(w: Writer, n: number, ...: any): number
			if n > count then
				w.errArg = count + 1
				return E_TOO_MANY_VALUES
			end
			return encodeFields(w, prog, nil, ...)
		end,
		decode = function(b: buffer, o: number, lim: number, ctx: ReadCtx, argv: { any }): (number, number)
			missing = false
			local q = decodeFields(b, o, lim, ctx, prog, argv)
			if missing then
				missing = false
				if ctx.err == 0 then
					ctx.err = D_MISSING_INSTANCE
				end
			end
			return count, q
		end,
	}
	table.freeze(codec :: any)
	return codec
end

local function untypedCodec(maxArgs: number, refs: boolean, anf: boolean): PayloadCodec
	local codec: PayloadCodec = {
		typed = false,
		count = -1,
		maxArgs = maxArgs,
		refs = refs,
		allowNonFinite = anf,
		encode = function(w: Writer, n: number, ...: any): number
			return Codec.writeArgs(w, maxArgs, n, ...)
		end,
		decode = function(b: buffer, o: number, lim: number, ctx: ReadCtx, argv: { any }): (number, number)
			return Codec.readArgs(b, o, lim, ctx, argv, maxArgs)
		end,
	}
	table.freeze(codec :: any)
	return codec
end

-- [[ Descriptor bytes (§4.7) ]] -----------------------------------------------------------------------------------

local function writeStr8(w: Writer, s: string)
	Codec.writeU8(w, #s)
	Codec.writeString(w, s)
end

local function writeDescriptor(w: Writer, d: Descriptor): ()
	if not isDescriptor(d) then
		error(C.PREFIX .. "Schema.writeDescriptor: not a Loren.T type", 2)
	end
	local op = d.op
	Codec.writeU8(w, op)
	if op >= OP_U8 and op <= OP_F64 then
		Codec.writeF64(w, d.lo)
		Codec.writeF64(w, d.hi)
	elseif op == OP_STRING then
		Codec.writeU8(w, d.flags)
		Codec.writeU32(w, d.max)
	elseif op == OP_BUFFER then
		Codec.writeU32(w, d.max)
	elseif op == OP_VECTOR3 or op == OP_VECTOR2 then
		Codec.writeF64(w, d.hi)
	elseif op == OP_ENUM then
		local items = d.items :: { string }
		Codec.writeU8(w, #items)
		for _, name in items do
			writeStr8(w, name)
		end
	elseif op == OP_ENUMITEM then
		writeStr8(w, d.enumName :: string)
	elseif op == OP_INSTANCE then
		writeStr8(w, d.className or "") -- the root is server-only and never written
		Codec.writeU8(w, d.flags)
	elseif op == OP_OPTIONAL then
		writeDescriptor(w, d.inner :: Descriptor)
	elseif op == OP_ARRAY then
		Codec.writeU32(w, d.max)
		writeDescriptor(w, d.inner :: Descriptor)
	elseif op == OP_MAP then
		Codec.writeU32(w, d.max)
		writeDescriptor(w, d.key :: Descriptor)
		writeDescriptor(w, d.inner :: Descriptor)
	elseif op == OP_STRUCT then
		local fields = d.fields :: { StructField }
		Codec.writeU8(w, #fields)
		for _, field in fields do
			writeStr8(w, field.name)
			writeDescriptor(w, field.desc)
		end
	end
end

local function readStr8(b: buffer, o: number, lim: number): (string?, number)
	if o >= lim then
		return nil, o
	end
	local n = buffer.readu8(b, o)
	if n > lim - o - 1 then
		return nil, o
	end
	return buffer.readstring(b, o + 1, n), o + 1 + n
end

local function readDescriptor(b: buffer, o: number, lim: number, depth: number): (Descriptor?, number)
	if depth > MAX_DESC_DEPTH or o < 0 or o >= lim then
		return nil, o
	end
	local op = buffer.readu8(b, o)
	o += 1
	if op == OP_BOOL then
		return BOOL, o
	elseif op == OP_COLOR3 then
		return COLOR3, o
	elseif op == OP_CFRAME then
		return CFRAME, o
	elseif op == OP_ANY then
		return ANY, o
	elseif op >= OP_U8 and op <= OP_F64 then
		if lim - o < 16 then
			return nil, o
		end
		local lo, hi = buffer.readf64(b, o), buffer.readf64(b, o + 8)
		local d = if op <= OP_I32 then (mkInt(op, lo, hi)) else (mkFloat(op, lo, hi))
		return d, o + 16
	elseif op == OP_STRING then
		if lim - o < 5 then
			return nil, o
		end
		local flags = buffer.readu8(b, o)
		if flags > BINARY then
			return nil, o
		end
		return (mkString(buffer.readu32(b, o + 1), flags == BINARY)), o + 5
	elseif op == OP_BUFFER then
		if lim - o < 4 then
			return nil, o
		end
		return (mkBuffer(buffer.readu32(b, o))), o + 4
	elseif op == OP_VECTOR3 or op == OP_VECTOR2 then
		if lim - o < 8 then
			return nil, o
		end
		return (mkVector(op, buffer.readf64(b, o))), o + 8
	elseif op == OP_ENUM then
		if o >= lim then
			return nil, o
		end
		local n = buffer.readu8(b, o)
		o += 1
		local names: { string } = table.create(n) :: any
		for i = 1, n do
			local name: string?
			name, o = readStr8(b, o, lim)
			if name == nil then
				return nil, o
			end
			names[i] = name
		end
		return (mkEnum(names)), o
	elseif op == OP_ENUMITEM then
		local name: string?
		name, o = readStr8(b, o, lim)
		if name == nil then
			return nil, o
		end
		local ok, enum = pcall(getEnum, name)
		if not ok then
			return nil, o
		end
		return (mkEnumItem(enum)), o
	elseif op == OP_INSTANCE then
		local className: string?
		className, o = readStr8(b, o, lim)
		if className == nil or o >= lim then
			return nil, o
		end
		local flags = buffer.readu8(b, o)
		if flags > NILABLE then
			return nil, o
		end
		return (mkInstance(className, nil, flags == NILABLE)), o + 1
	elseif op == OP_OPTIONAL then
		local inner: Descriptor?
		inner, o = readDescriptor(b, o, lim, depth + 1)
		if inner == nil then
			return nil, o
		end
		return (mkOptional(inner)), o
	elseif op == OP_ARRAY then
		if lim - o < 4 then
			return nil, o
		end
		local max = buffer.readu32(b, o)
		local inner: Descriptor?
		inner, o = readDescriptor(b, o + 4, lim, depth + 1)
		if inner == nil then
			return nil, o
		end
		return (mkArray(inner, max)), o
	elseif op == OP_MAP then
		if lim - o < 4 then
			return nil, o
		end
		local max = buffer.readu32(b, o)
		local key: Descriptor?, value: Descriptor?
		key, o = readDescriptor(b, o + 4, lim, depth + 1)
		if key == nil then
			return nil, o
		end
		value, o = readDescriptor(b, o, lim, depth + 1)
		if value == nil then
			return nil, o
		end
		return (mkMap(key, value, max)), o
	elseif op == OP_STRUCT then
		if o >= lim then
			return nil, o
		end
		local n = buffer.readu8(b, o)
		o += 1
		local names: { string } = table.create(n) :: any
		local descs: { Descriptor } = table.create(n) :: any
		for i = 1, n do
			local name: string?, desc: Descriptor?
			name, o = readStr8(b, o, lim)
			if name == nil then
				return nil, o
			end
			desc, o = readDescriptor(b, o, lim, depth + 1)
			if desc == nil then
				return nil, o
			end
			names[i] = name
			descs[i] = desc
		end
		-- mkStruct rejects unsorted or duplicate names: the wire order is the field order on both sides
		return (mkStruct(names, descs)), o
	end
	return nil, o
end

-- [[ Module ]] ---------------------------------------------------------------------------------------------------

local Schema = {}

Schema.T = T
Schema.isDescriptor = isDescriptor
Schema.isSpec = isSpec

function Schema.method(...: any): MemberSpec
	local spec, err = parseSpec(KIND_METHOD, ...)
	if spec == nil then
		-- level 3: the facade's Loren.Method is one frame between the user's line and this one
		error(C.PREFIX .. "Loren.Method: " .. (err :: string), 3)
	end
	return spec
end

function Schema.event(...: any): MemberSpec
	local spec, err = parseSpec(KIND_EVENT, ...)
	if spec == nil then
		error(C.PREFIX .. "Loren.Event: " .. (err :: string), 3)
	end
	return spec
end

function Schema.signal(...: any): MemberSpec
	local spec, err = parseSpec(KIND_SIGNAL, ...)
	if spec == nil then
		error(C.PREFIX .. "Loren.Signal: " .. (err :: string), 3)
	end
	return spec
end

-- Boot check (Routes): nil when fine, else a problem text. refFree = the member is unreliable or coalesced.
function Schema.check(descs: { Descriptor }?, refFree: boolean): string?
	if descs ~= nil then
		for i = 1, #descs do
			if descDepth(descs[i]) > MAX_DESC_DEPTH then
				return DEPTH_TEXT
			end
		end
	end
	if refFree then
		if descs == nil then
			return REF_FREE_TEXT
		end
		for i = 1, #descs do
			if descs[i].refs then
				return REF_FREE_TEXT
			end
		end
	end
	return nil
end

-- descs nil = untyped (argc + tagged values, at most maxArgs); else typed fields in order.
function Schema.compile(
	descs: { Descriptor }?,
	allowNonFinite: boolean,
	maxArgs: number,
	unreliable: boolean
): PayloadCodec
	local anf = allowNonFinite == true
	if descs == nil then
		-- an unreliable writer fails with NEEDS_REF instead of using the sidecar
		return untypedCodec(maxArgs, not unreliable, anf)
	end
	local list, err = descList(descs, "Args")
	if list == nil then
		error(C.PREFIX .. "Schema.compile: " .. (err :: string), 2)
	end
	local refs = false
	for i = 1, #list do
		if list[i].refs then
			refs = true
		end
	end
	return typedCodec(buildProg(list, false, true, anf), #list, refs and not unreliable, anf)
end

Schema.writeDescriptor = writeDescriptor
Schema.readDescriptor = readDescriptor

Schema._test = table.freeze({
	descDepth = descDepth,
	prefixWidth = prefixWidth,
	f32Down = f32Down,
	f32Up = f32Up,
	describe = describe,
})

return table.freeze(Schema)
