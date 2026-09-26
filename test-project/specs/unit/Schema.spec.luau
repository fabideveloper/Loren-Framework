--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Codec = require(ReplicatedStorage.LorenRuntime.Codec)
local Schema = require(ReplicatedStorage.LorenRuntime.Schema)

local T = Schema.T
local E, D, Op = C.Encode, C.Decode, C.SchemaOp
local F32_MAX, F64_MAX = C.Limit.F32_MAX, C.Limit.F64_MAX
local NAN, INF = 0 / 0, math.huge
local FUZZ_BUFFERS = 10000

-- C->S compile (Method/Event args); `true` = AllowNonFinite.
local function codec(descs: { any }?, allowNonFinite: boolean?): any
	return Schema.compile(descs :: any, allowNonFinite == true, C.Limit.MAX_ARGS_C2S, false)
end

local function encode(pc: any, c2s: boolean, ...: any): (number, buffer, { any }, number, number)
	local w = Codec.newWriter(16, c2s)
	local st = pc.encode(w, select("#", ...), ...)
	local out = buffer.create(w.n)
	buffer.copy(out, 0, w.buf, 0, w.n)
	return st, out, table.move(w.refs, 1, w.nrefs, 1, {}), w.nrefs, w.errArg
end

local function decode(
	pc: any,
	hostile: boolean,
	b: buffer,
	refs: { any }?,
	nrefs: number?,
	lim: number?
): (any, number, number, { any })
	local ctx = Codec.newReadCtx(hostile, hostile)
	local count = nrefs or 0
	local frameRefs = if count > 0 then refs else nil
	Codec.beginFrame(ctx, frameRefs, if hostile then count else 0)
	if hostile and count > 0 then
		local st = Codec.walkSidecar(frameRefs :: any, count, ctx)
		assert(st == 0, "the sidecar walk failed")
	end
	Codec.beginMessage(ctx, pc.allowNonFinite)
	local argv = {}
	local n, q = pc.decode(b, 0, if lim then lim else buffer.len(b), ctx, argv)
	return ctx, n, q, argv
end

-- Encode then decode on one side. Returns (decode status, argv, whole message consumed).
local function roundTrip(pc: any, c2s: boolean, ...: any): (number, { any }, boolean)
	local st, b, refs, nrefs = encode(pc, c2s, ...)
	if st ~= 0 then
		error("encode failed: " .. tostring(C.EncodeName[st]), 2)
	end
	local ctx, _, q, argv = decode(pc, c2s, b, refs, nrefs)
	return ctx.err, argv, q == buffer.len(b)
end

-- Raw bytes for hostile inputs: bytes().u8(1).f64(0 / 0).done()
local function bytes(): any
	local b = buffer.create(4096)
	local n = 0
	local self: any = {}
	function self.u8(v: number): any
		buffer.writeu8(b, n, v)
		n += 1
		return self
	end
	function self.u16(v: number): any
		buffer.writeu16(b, n, v)
		n += 2
		return self
	end
	function self.u32(v: number): any
		buffer.writeu32(b, n, v)
		n += 4
		return self
	end
	function self.f32(v: number): any
		buffer.writef32(b, n, v)
		n += 4
		return self
	end
	function self.f64(v: number): any
		buffer.writef64(b, n, v)
		n += 8
		return self
	end
	function self.str(s: string): any
		buffer.writestring(b, n, s)
		n += #s
		return self
	end
	function self.done(): buffer
		local out = buffer.create(n)
		buffer.copy(out, 0, b, 0, n)
		return out
	end
	return self
end

-- A mixed-type array (strict mode would infer a homogeneous literal).
local function list(...: any): { any }
	return { ... }
end

local function errorOf(fn: () -> ...any): string
	local ok, err = pcall(fn)
	return if ok then "" else tostring(err)
end

local function randomBuffer(rng: Random, maxLen: number): buffer
	local n = rng:NextInteger(0, maxLen)
	local b = buffer.create(n)
	for i = 0, n - 1 do
		-- small values are likelier to form valid counts, lengths, presence bytes and ops
		local roll = rng:NextNumber()
		local v = if roll < 0.5 then rng:NextInteger(0, 3) elseif roll < 0.6 then 255 else rng:NextInteger(0, 255)
		buffer.writeu8(b, i, v)
	end
	return b
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local root: Instance, part: Instance, outside: Instance

	t.beforeAll(function()
		root = Instance.new("Folder")
		root.Name = "SchemaSpecRoot"
		part = Instance.new("Part")
		part.Parent = root
		outside = Instance.new("Part")
	end)

	t.afterAll(function()
		root:Destroy()
		outside:Destroy()
	end)

	describe("T catalogue", function()
		it("has frozen scalar descriptors with the documented ops and wire sizes", function()
			local sizes: { [string]: { number } } = {
				bool = { Op.BOOL, 1 },
				u8 = { Op.U8, 1 },
				u16 = { Op.U16, 2 },
				u32 = { Op.U32, 4 },
				i8 = { Op.I8, 1 },
				i16 = { Op.I16, 2 },
				i32 = { Op.I32, 4 },
				f32 = { Op.F32, 4 },
				f64 = { Op.F64, 8 },
				Vector3 = { Op.VECTOR3, 12 },
				Vector2 = { Op.VECTOR2, 8 },
				Color3 = { Op.COLOR3, 12 },
				CFrame = { Op.CFRAME, 48 },
			}
			for name, spec in sizes do
				local d = T[name]
				expect(Schema.isDescriptor(d)).toBe(true)
				expect(table.isfrozen(d)).toBe(true)
				expect(d.op).toBe(spec[1])
				expect(d.fixed).toBe(spec[2])
				expect(d.minSize).toBe(spec[2])
				expect(d.refs).toBe(false)
			end
			expect(T.boolean).toBe(T.bool)
			expect(T.u8.lo).toBe(0)
			expect(T.u8.hi).toBe(255)
			expect(T.i32.lo).toBe(-2147483648)
			expect(T.u32.hi).toBe(4294967295)
			expect(T.any.op).toBe(Op.ANY)
			expect(T.any.refs).toBe(true)
			expect(T.any.minSize).toBe(1)
			expect(T.string.fixed).toBe(-1)
			expect(Schema.isDescriptor({ op = 1 })).toBe(false)
			expect(Schema.isDescriptor(nil)).toBe(false)
			expect(table.isfrozen(T :: any)).toBe(true)
		end)

		it("refines integer bounds inside the type range", function()
			local d = T.u8(1, 10)
			expect(d.op).toBe(Op.U8)
			expect(d.lo).toBe(1)
			expect(d.hi).toBe(10)
			expect(T.u16(5).hi).toBe(65535)
			expect(T.i32(nil, 0).lo).toBe(-2147483648)
			expect(T.i8(-128, 127).lo).toBe(-128)
			local bads: { { any } } =
				{ { 0, 256 }, { -1, 5 }, { 1.5, 2 }, { 5, 1 }, { "a", 2 }, { NAN, 1 }, { 0, INF } }
			for _, bad in bads do
				expect(function()
					T.u8(bad[1], bad[2])
				end).toThrow(C.PREFIX .. "T.u8")
			end
			expect(function()
				T.i8(-129, 0)
			end).toThrow("inside -128..127")
			expect(function()
				T.u8(1, 2, 3)
			end).toThrow("takes (lo, hi)")
		end)

		it("T.int picks the smallest integer type", function()
			local cases: { { any } } = {
				{ 0, 0, "U8" },
				{ 0, 255, "U8" },
				{ 0, 256, "U16" },
				{ 0, 65535, "U16" },
				{ 0, 65536, "U32" },
				{ 0, 4294967295, "U32" },
				{ -1, 127, "I8" },
				{ -128, 127, "I8" },
				{ -129, 0, "I16" },
				{ -1, 32767, "I16" },
				{ -1, 32768, "I32" },
				{ -32769, 0, "I32" },
				{ -2147483648, 2147483647, "I32" },
			}
			for _, case in cases do
				local d = T.int(case[1], case[2])
				expect(d.op).toBe((Op :: any)[case[3]])
				expect(d.lo).toBe(case[1])
				expect(d.hi).toBe(case[2])
			end
			local badInts: { { any } } = {
				{ 0, 4294967296 },
				{ -1, 2147483648 },
				{ -2147483649, 0 },
				{ 1.5, 2 },
				{ nil, 5 },
				{ 5, 1 },
				{ 0, INF },
			}
			for _, bad in badInts do
				expect(function()
					T.int(bad[1], bad[2])
				end).toThrow(C.PREFIX .. "T.int")
			end
		end)

		it("refines float bounds, finite only, f32 bounds rounded outward to f32 values", function()
			expect(T.f32.lo).toBe(-F32_MAX)
			expect(T.f32.hi).toBe(F32_MAX)
			expect(T.f64.lo).toBe(-F64_MAX)
			expect(T.f64.hi).toBe(F64_MAX)
			expect(T.f64(0, 1).hi).toBe(1)
			local r = T.f32(0.1, 0.3)
			expect(r.lo <= 0.1).toBe(true)
			expect(r.hi >= 0.3).toBe(true)
			expect(0.1 - r.lo < 1e-8).toBe(true)
			expect(r.hi - 0.3 < 1e-7).toBe(true)
			local scratch = buffer.create(4)
			for _, bound in { r.lo, r.hi } do
				buffer.writef32(scratch, 0, bound)
				expect(buffer.readf32(scratch, 0)).toBe(bound)
			end
			expect(T.num(0, 1).op).toBe(Op.F64)
			expect(T.num(-2, 2).lo).toBe(-2)
			local badFloats: { { any } } = { { NAN, 1 }, { 0, INF }, { -INF, 0 }, { 2, 1 }, { "0", 1 } }
			for _, bad in badFloats do
				expect(function()
					T.f64(bad[1], bad[2])
				end).toThrow(C.PREFIX .. "T.f64")
			end
			expect(function()
				T.f32(0, 1e39)
			end).toThrow("f32 range")
			expect(function()
				T.num(0)
			end).toThrow("T.num")
			expect(function()
				T.num()
			end).toThrow("T.num")
		end)

		it("refines strings and buffers (max bytes, prefix width, Binary)", function()
			expect(T.string.max).toBe(1024)
			expect(T.string.flags).toBe(0)
			expect(T.string.minSize).toBe(2)
			expect(T.string(255).minSize).toBe(1)
			expect(T.string(256).minSize).toBe(2)
			expect(T.string(65535).minSize).toBe(2)
			expect(T.string(65536).minSize).toBe(4)
			expect(T.string(0).max).toBe(0)
			expect(T.string(10, { Binary = true }).flags).toBe(C.DescFlag.Binary)
			expect(T.string(nil, { Binary = true }).max).toBe(1024)
			expect(T.buffer.max).toBe(1024)
			expect(T.buffer(300).max).toBe(300)
			expect(T.buffer(300).minSize).toBe(2)
			for _, fn in
				{
					function()
						T.string(-1)
					end,
					function()
						T.string(1.5)
					end,
					function()
						T.string(4294967296)
					end,
					function()
						T.string(10, { Binary = 1 })
					end,
					function()
						T.string(10, { Utf8 = true })
					end,
					function()
						T.string(10, 5)
					end,
					function()
						T.buffer(-1)
					end,
					function()
						T.buffer(1, 2)
					end,
				}
			do
				expect(fn).toThrow(C.PREFIX .. "T.")
			end
		end)

		it("refines vectors with a max magnitude; other scalars cannot be called", function()
			expect(T.Vector3.hi).toBe(INF)
			expect(T.Vector3(10).hi).toBe(10)
			expect(T.Vector2(2.5).hi).toBe(2.5)
			local badMagnitudes: { any } = { 0, -1, NAN, "x" }
			for _, bad in badMagnitudes do
				expect(function()
					T.Vector3(bad)
				end).toThrow("maxMagnitude")
			end
			expect(function()
				T.Vector2(1, 2)
			end).toThrow("takes (maxMagnitude)")
			for _, name in { "bool", "Color3", "CFrame", "any" } do
				expect(function()
					T[name]()
				end).toThrow("cannot be called")
			end
			expect(function()
				T.optional(T.u8)()
			end).toThrow("cannot be called")
		end)

		it("iterates descriptors like the frozen tables they are (a for loop never runs the refine call)", function()
			-- Luau calls a table with __call and no __iter when a generic for iterates it (FORGPREP fallback)
			local descs: { any } =
				{ T.u8, T.i16(-5, 5), T.string(9), T.optional(T.u8), T.array(T.bool, 3), T.struct({ a = T.bool }) }
			for _, d in descs do
				local viaFor: { [any]: any }, viaNext: { [any]: any } = {}, {}
				for k, v in d do
					viaFor[k] = v
				end
				for k, v in next, d do
					viaNext[k] = v
				end
				expect(viaFor).toEqual(viaNext)
				expect(viaFor.op).toBe(d.op)
			end
		end)

		it("T.enum takes 1..255 unique names of 1..255 bytes", function()
			local e = T.enum({ "Red", "Green" })
			expect(e.op).toBe(Op.ENUM)
			expect(e.items).toEqual({ "Red", "Green" })
			expect(e.fixed).toBe(1)
			local many = {}
			for i = 1, 255 do
				many[i] = "n" .. i
			end
			expect(#T.enum(many).items).toBe(255)
			expect(T.enum({ string.rep("x", 255) }).items[1]).toHaveLength(255)
			table.insert(many, "n256")
			local badEnums: { any } =
				{ {}, { A = 1 }, { "A", "A" }, { "" }, { string.rep("x", 256) }, many, { 1 }, "A", list("A", nil, "B") }
			for _, bad in badEnums do
				expect(function()
					T.enum(bad)
				end).toThrow(C.PREFIX .. "T.enum")
			end
		end)

		it("T.EnumItem takes an Enum; every engine Enum is accepted or rejected with the value range", function()
			local d = T.EnumItem(Enum.Material)
			expect(d.op).toBe(Op.ENUMITEM)
			expect(d.enumName).toBe("Material")
			expect(d.fixed).toBe(2)
			local badEnumArgs: { any } = { "Material", Enum.Material.Plastic, 5 }
			for _, bad in badEnumArgs do
				expect(function()
					T.EnumItem(bad)
				end).toThrow("expected an Enum")
			end
			local unexpected = {}
			for _, enum in Enum:GetEnums() do
				local ok, err = pcall(T.EnumItem, enum)
				if not ok and not string.find(tostring(err), "outside 0..65535", 1, true) then
					table.insert(unexpected, tostring(enum) .. ": " .. tostring(err))
				end
			end
			expect(unexpected).toEqual({})
		end)

		it("T.Instance takes a class name and a server-only root", function()
			local d = T.Instance()
			expect(d.op).toBe(Op.INSTANCE)
			expect(d.className).toBe("")
			expect(d.root).toBeNil()
			expect(d.refs).toBe(true)
			expect(d.minSize).toBe(1)
			expect(d.flags).toBe(0)
			local r = T.Instance("BasePart", root)
			expect(r.className).toBe("BasePart")
			expect(r.root).toBe(root)
			expect(function()
				T.Instance(5)
			end).toThrow("className")
			expect(function()
				T.Instance("Part", "x")
			end).toThrow("root must be an Instance")
			expect(function()
				T.Instance(string.rep("x", 256))
			end).toThrow("className")
		end)

		it("T.optional marks an inner Instance Nilable", function()
			local o = T.optional(T.u8)
			expect(o.op).toBe(Op.OPTIONAL)
			expect(o.inner).toBe(T.u8)
			expect(o.minSize).toBe(1)
			expect(o.fixed).toBe(-1)
			local oi = T.optional(T.Instance("Part"))
			expect(oi.inner.flags).toBe(C.DescFlag.Nilable)
			expect(oi.inner.className).toBe("Part")
			expect(oi.refs).toBe(true)
			expect(function()
				T.optional(5)
			end).toThrow("T.optional")
			expect(function()
				T.optional(nil)
			end).toThrow("T.optional")
		end)

		it("T.array and T.map check element, key and count arguments", function()
			local a = T.array(T.u8)
			expect(a.max).toBe(1024)
			expect(a.minSize).toBe(2)
			expect(a.inner).toBe(T.u8)
			expect(T.array(T.u8, 10).minSize).toBe(1)
			expect(T.array(T.Instance()).refs).toBe(true)
			for _, bad in { { 5 }, { T.u8, -1 }, { T.u8, 1.5 }, { T.u8, "9" } } do
				expect(function()
					T.array(bad[1], bad[2])
				end).toThrow("T.array")
			end
			local m = T.map(T.string, T.u8, 5)
			expect(m.key).toBe(T.string)
			expect(m.inner).toBe(T.u8)
			expect(m.max).toBe(5)
			expect(m.minSize).toBe(1)
			for _, key in
				{
					T.bool,
					T.u8,
					T.i32,
					T.f32,
					T.f64,
					T.num(0, 1),
					T.string(4),
					T.enum({ "A" }),
					T.EnumItem(Enum.Material),
				}
			do
				expect(Schema.isDescriptor(T.map(key, T.any))).toBe(true)
			end
			for _, key in
				{ T.Vector3, T.CFrame, T.Instance(), T.any, T.optional(T.u8), T.array(T.u8), T.struct({ a = T.u8 }) }
			do
				expect(function()
					T.map(key, T.u8)
				end).toThrow("keys must be")
			end
			expect(function()
				T.map(T.u8, 5)
			end).toThrow("T.map")
		end)

		it("T.struct sorts field names bytewise and needs 1..255 fields", function()
			local s = T.struct({ b = T.u8, a = T.u16, C = T.bool })
			expect(s.op).toBe(Op.STRUCT)
			local names = {}
			for i, field in s.fields do
				names[i] = field.name
			end
			expect(names).toEqual({ "C", "a", "b" })
			expect(s.fields[2].desc).toBe(T.u16)
			expect(s.fixed).toBe(4)
			expect(s.minSize).toBe(4)
			expect(T.struct({ a = T.string }).fixed).toBe(-1)
			expect(T.struct({ a = T.Instance() }).refs).toBe(true)
			local wide = {}
			for i = 1, 255 do
				wide["f" .. i] = T.bool
			end
			expect(#T.struct(wide).fields).toBe(255)
			wide.f256 = T.bool
			for _, bad in { {}, wide, { [1] = T.u8 }, { a = 5 }, T.u8, { [string.rep("x", 256)] = T.u8 } } do
				expect(function()
					T.struct(bad)
				end).toThrow(C.PREFIX .. "T.struct")
			end
		end)

		it("nests at most 16 levels", function()
			local d = T.u8
			for _ = 1, 15 do
				d = T.optional(d)
			end
			expect(Schema._test.descDepth(d)).toBe(16)
			expect(Schema.check({ d }, false)).toBeNil()
			expect(function()
				T.optional(d)
			end).toThrow("deeper than 16")
			expect(function()
				T.array(d)
			end).toThrow("deeper than 16")
			expect(function()
				T.map(T.u8, d)
			end).toThrow("deeper than 16")
			expect(function()
				T.struct({ a = d })
			end).toThrow("deeper than 16")
		end)

		it("errors on unknown T members with a suggestion and prints readably", function()
			expect(function()
				return T.vector3
			end).toThrow("Did you mean 'Vector3'")
			expect(function()
				return T.u64
			end).toThrow("has no type 'u64'")
			expect(tostring(T.u8(1, 2))).toBe("T.u8(1, 2)")
			expect(tostring(T.string(5))).toBe("T.string(max 5)")
			expect(tostring(T.EnumItem(Enum.Material))).toBe("T.EnumItem(Enum.Material)")
		end)
	end)

	describe("member specs", function()
		it("takes positional types, then an options table", function()
			local spec = Schema.method(T.u8, T.string)
			expect(Schema.isSpec(spec)).toBe(true)
			expect(Schema.isDescriptor(spec)).toBe(false)
			expect(table.isfrozen(spec)).toBe(true)
			expect(spec.kind).toBe(C.Kind.Method)
			expect(spec.args).toEqual({ T.u8, T.string })
			expect(spec.returns).toBeNil()
			expect(spec.timeout).toBeNil()
			expect(spec.rate).toBeNil()
			expect(spec.serial).toBe(false)
			expect(spec.cancelOnTimeout).toBeNil()
			expect(spec.unreliable).toBe(false)
			expect(spec.ordered).toBe(false)
			expect(spec.coalesce).toBeNil()
			expect(spec.backlog).toBeNil()
			expect(spec.allowNonFinite).toBe(false)

			local full = Schema.method(T.u8, {
				Returns = { T.bool },
				Timeout = 2.34,
				RateLimit = { 2, 4 },
				Serial = true,
				CancelOnTimeout = true,
				AllowNonFinite = true,
			})
			expect(full.args).toEqual({ T.u8 })
			expect(full.returns).toEqual({ T.bool })
			expect(full.timeout).toBe(2.3)
			expect(full.rate).toBe(2)
			expect(full.burst).toBe(4)
			expect(full.serial).toBe(true)
			expect(full.cancelOnTimeout).toBe(true)
			expect(full.allowNonFinite).toBe(true)
			expect(Schema.method(T.u8, { CancelOnTimeout = false }).cancelOnTimeout).toBe(false)
		end)

		it("is untyped without types and typed (possibly empty) with Args", function()
			expect(Schema.method().args).toBeNil()
			expect(Schema.method(nil).args).toBeNil()
			expect(Schema.method({}).args).toBeNil()
			expect(Schema.method({ Timeout = 5 }).args).toBeNil()
			local empty = Schema.event({ Args = {} })
			expect(empty.kind).toBe(C.Kind.Event)
			expect(empty.args).toEqual({})
			local aim =
				Schema.event(T.Vector3, { Unreliable = true, Ordered = true, Coalesce = false, RateLimit = { 60, 90 } })
			expect(aim.unreliable).toBe(true)
			expect(aim.ordered).toBe(true)
			expect(aim.coalesce).toBe(false)
			expect(aim.rate).toBe(60)
			expect(aim.burst).toBe(90)
			local hit = Schema.signal(T.u8, { Unreliable = true, Backlog = 0 })
			expect(hit.kind).toBe(C.Kind.Signal)
			expect(hit.backlog).toBe(0)
			expect(Schema.signal({ Args = { T.u8 }, Backlog = 1024 }).backlog).toBe(1024)
			local max = {}
			for i = 1, 32 do
				max[i] = T.u8
			end
			expect(#(Schema.method(table.unpack(max)).args :: any)).toBe(32)
			expect(#(Schema.method({ Args = max }).args :: any)).toBe(32)
			expect(Schema.method({ Timeout = 1 }).timeout).toBe(1)
			expect(Schema.method({ Timeout = 120 }).timeout).toBe(120)
		end)

		it("rejects bad arguments and options with the member kind in the message", function()
			local over = {}
			for i = 1, 33 do
				over[i] = T.u8
			end
			local cases: { { any } } = {
				{ "Loren.Method", "Args given twice", Schema.method, T.u8, { Args = { T.u8 } } },
				{ "Loren.Method", "unknown option 'Foo'", Schema.method, { Timeout = 5, Foo = 1 } },
				{ "Loren.Method", "did you mean 'Timeout'", Schema.method, { timeout = 5 } },
				{ "Loren.Event", "unknown option 'Timeout'", Schema.event, { Timeout = 5 } },
				{ "Loren.Signal", "unknown option 'Coalesce'", Schema.signal, { Coalesce = true } },
				{ "Loren.Method", "unknown option 'Unreliable'", Schema.method, { Unreliable = true } },
				{ "Loren.Event", "Ordered requires Unreliable", Schema.event, { Ordered = true } },
				{
					"Loren.Signal",
					"Ordered requires Unreliable",
					Schema.signal,
					{ Ordered = true, Unreliable = false },
				},
				{ "Loren.Method", "Timeout must be", Schema.method, { Timeout = 0.5 } },
				{ "Loren.Method", "Timeout must be", Schema.method, { Timeout = 121 } },
				{ "Loren.Method", "Timeout must be", Schema.method, { Timeout = NAN } },
				{ "Loren.Method", "Timeout must be", Schema.method, { Timeout = "5" } },
				{ "Loren.Method", "RateLimit must be", Schema.method, { RateLimit = { 0, 1 } } },
				{ "Loren.Method", "RateLimit must be", Schema.method, { RateLimit = { 1, 0.5 } } },
				{ "Loren.Method", "RateLimit must be", Schema.method, { RateLimit = { 1 } } },
				{ "Loren.Event", "RateLimit must be", Schema.event, { RateLimit = { rate = 1, burst = 2 } } },
				{ "Loren.Event", "RateLimit must be", Schema.event, { RateLimit = { 1, NAN } } },
				{ "Loren.Event", "RateLimit must be", Schema.event, { RateLimit = { INF, 2 } } },
				{ "Loren.Event", "RateLimit must be", Schema.event, { RateLimit = 5 } },
				{ "Loren.Signal", "Backlog must be", Schema.signal, { Backlog = -1 } },
				{ "Loren.Signal", "Backlog must be", Schema.signal, { Backlog = 1025 } },
				{ "Loren.Signal", "Backlog must be", Schema.signal, { Backlog = 1.5 } },
				{ "Loren.Method", "Serial must be true or false", Schema.method, { Serial = "yes" } },
				{ "Loren.Method", "at most 32", Schema.method, table.unpack(over) },
				{ "Loren.Method", "at most 32", Schema.method, { Args = over } },
				{ "Loren.Method", "argument 2", Schema.method, T.u8, 5 },
				{ "Loren.Method", "argument 1", Schema.method, 5, T.u8 },
				{ "Loren.Method", "argument 1", Schema.method, { Timeout = 5 }, T.u8 },
				{ "Loren.Method", "pass types as arguments", Schema.method, { T.u8 } },
				{ "Loren.Method", "member spec", Schema.method, Schema.method() },
				{ "Loren.Event", "Args[2] is not a Loren.T type", Schema.event, { Args = { T.u8, 5 } } },
				{ "Loren.Event", "plain array", Schema.event, { Args = { A = T.u8 } } },
				{ "Loren.Method", "Returns must be an array", Schema.method, { Returns = 5 } },
			}
			for _, case in cases do
				local message = errorOf(function()
					case[3](table.unpack(case, 4))
				end)
				expect(message).toContain(C.PREFIX .. case[1] .. ": ")
				expect(message).toContain(case[2])
			end
		end)
	end)

	describe("check", function()
		it("requires typed Args without Instance or any for unreliable and coalesced members", function()
			local text = "Unreliable and Coalesce members need typed Args without T.Instance or T.any"
			expect(Schema.check(nil, false)).toBeNil()
			expect(Schema.check(nil, true)).toBe(text)
			expect(Schema.check({}, true)).toBeNil()
			expect(Schema.check({ T.u8, T.Vector3(1), T.array(T.struct({ a = T.f32 })) }, true)).toBeNil()
			for _, refDesc in
				{
					T.Instance(),
					T.any,
					T.optional(T.Instance()),
					T.array(T.any),
					T.map(T.string, T.Instance()),
					T.struct({ a = T.u8, b = T.optional(T.any) }),
				}
			do
				expect(Schema.check({ T.u8, refDesc }, true)).toBe(text)
				expect(Schema.check({ T.u8, refDesc }, false)).toBeNil()
			end
		end)
	end)

	describe("compile", function()
		it("builds frozen untyped and typed codecs", function()
			local untyped = Schema.compile(nil, false, 20, false)
			expect(table.isfrozen(untyped)).toBe(true)
			expect(untyped.typed).toBe(false)
			expect(untyped.count).toBe(-1)
			expect(untyped.maxArgs).toBe(20)
			expect(untyped.refs).toBe(true)
			expect(Schema.compile(nil, false, 20, true).refs).toBe(false)
			local err, argv = roundTrip(untyped, true, 1, "a", nil, { x = 1 })
			expect(err).toBe(0)
			expect(argv[1]).toBe(1)
			expect(argv[2]).toBe("a")
			expect(argv[3]).toBeNil()
			expect(argv[4]).toEqual({ x = 1 })

			local typed = codec({ T.u8, T.Instance() }, true)
			expect(table.isfrozen(typed)).toBe(true)
			expect(typed.typed).toBe(true)
			expect(typed.count).toBe(2)
			expect(typed.maxArgs).toBe(2)
			expect(typed.refs).toBe(true)
			expect(typed.allowNonFinite).toBe(true)
			expect(codec({ T.u8 }).refs).toBe(false)
			expect(Schema.compile({ T.Instance() }, false, 20, true).refs).toBe(false)

			local empty = codec({})
			local st, b = encode(empty, true)
			expect(st).toBe(0)
			expect(b).toHaveLength(0)
			local ctx, n = decode(empty, true, b)
			expect(ctx.err).toBe(0)
			expect(n).toBe(0)
			expect(function()
				Schema.compile({ 5 } :: any, false, 20, false)
			end).toThrow("Schema.compile")
		end)
	end)

	describe("typed round trips", function()
		it("scalars at their edges, both directions, with one bounds check per fixed run", function()
			local pc = codec({ T.bool, T.u8, T.u16, T.u32, T.i8, T.i16, T.i32, T.f32, T.f64 })
			local rows: { { any } } = {
				{ true, 255, 65535, 4294967295, -128, -32768, -2147483648, 1.5, 0.1 },
				{ false, 0, 0, 0, 127, 32767, 2147483647, -F32_MAX, -0 },
				{ true, 7, 300, 70000, -1, -300, -70000, F32_MAX, F64_MAX },
			}
			for _, row in rows do
				local st, b = encode(pc, true, table.unpack(row))
				expect(st).toBe(0)
				expect(b).toHaveLength(27)
				for _, c2s in { true, false } do
					local err, argv, whole = roundTrip(pc, c2s, table.unpack(row))
					expect(err).toBe(0)
					expect(whole).toBe(true)
					for i = 1, 9 do
						expect(argv[i]).toBe(row[i])
					end
				end
			end
			local _, argv = roundTrip(pc, true, table.unpack(rows[2]))
			expect(1 / argv[9]).toBe(-INF) -- -0 kept
		end)

		it("strings, binary strings and buffers", function()
			local pc = codec({ T.string, T.string(10, { Binary = true }), T.buffer(5), T.string(300) })
			local long = string.rep("é", 150) -- 300 bytes, valid UTF-8, u16 prefix
			local st, b = encode(pc, true, "héllo", "\255\0x", buffer.fromstring("ab"), long)
			expect(st).toBe(0)
			expect(b).toHaveLength(2 + 6 + 1 + 3 + 1 + 2 + 2 + 300)
			for _, c2s in { true, false } do
				local err, argv = roundTrip(pc, c2s, "héllo", "\255\0x", buffer.fromstring("ab"), long)
				expect(err).toBe(0)
				expect(argv[1]).toBe("héllo")
				expect(argv[2]).toBe("\255\0x")
				expect(buffer.tostring(argv[3])).toBe("ab")
				expect(argv[4]).toBe(long)
			end
			local err, argv = roundTrip(pc, true, "", "", buffer.create(0), "")
			expect(err).toBe(0)
			expect(argv[1]).toBe("")
			expect(buffer.len(argv[3])).toBe(0)
		end)

		it("Vector3, Vector2, Color3 exactly and CFrame losslessly", function()
			local pc = codec({ T.Vector3, T.Vector2, T.Color3, T.CFrame })
			local cf = CFrame.new(1.5, -2.25, 1e6) * CFrame.Angles(0.1, 0.2, 0.3)
			local values: { any } = { Vector3.new(1.5, -2, 3.25), Vector2.new(-1, 0.5), Color3.new(0.25, 0.5, 1), cf }
			for _, c2s in { true, false } do
				local err, argv = roundTrip(pc, c2s, table.unpack(values))
				expect(err).toBe(0)
				expect(argv[1]).toBe(values[1])
				expect(argv[2]).toBe(values[2])
				expect(argv[3]).toBe(values[3])
				expect({ argv[4]:GetComponents() }).toEqual({ cf:GetComponents() })
			end
		end)

		it("enums, EnumItems and Instances (indexed refs C->S, sequential S->C)", function()
			local pc = codec({
				T.enum({ "A", "B", "C" }),
				T.EnumItem(Enum.Material),
				T.Instance("BasePart"),
				T.optional(T.Instance()),
			})
			local st, b, refs, nrefs = encode(pc, true, "C", Enum.Material.Grass, part, nil)
			expect(st).toBe(0)
			-- index 2, u16 Value, ref index 0, absent
			local expected = bytes().u8(2).u16(Enum.Material.Grass.Value).u8(0).u8(0).done()
			expect(buffer.tostring(b)).toBe(buffer.tostring(expected))
			expect(nrefs).toBe(1)
			expect(refs[1]).toBe(part)
			for _, c2s in { true, false } do
				local err, argv = roundTrip(pc, c2s, "C", Enum.Material.Grass, part, root)
				expect(err).toBe(0)
				expect(argv[1]).toBe("C")
				expect(argv[2]).toBe(Enum.Material.Grass)
				expect(argv[3]).toBe(part)
				expect(argv[4]).toBe(root)
			end
			local _, sb, srefs = encode(pc, false, "A", Enum.Material.Plastic, part, root)
			expect(sb).toHaveLength(1 + 2 + 0 + 1) -- S->C Instances cost no bytes
			expect(srefs).toEqual({ part, root })
		end)

		it("optional, array, map, struct and any, nested", function()
			local pc = codec({
				T.optional(T.u8),
				T.array(T.u16),
				T.map(T.string, T.u8),
				T.struct({ a = T.u8, b = T.optional(T.string) }),
				T.any,
				T.array(T.struct({ id = T.u16, pos = T.Vector3 }), 100),
				T.map(T.f64, T.array(T.bool)),
				T.optional(T.optional(T.i32)),
			})
			local values: { any } = {
				nil,
				{ 1, 2, 65535 },
				{ x = 1, y = 2 },
				{ a = 5 },
				list(1, "two", { 3 }),
				{ { id = 1, pos = Vector3.new(1, 2, 3) }, { id = 2, pos = Vector3.zero } },
				{ [1.5] = { true, false }, [-2] = {} },
				7,
			}
			for _, c2s in { true, false } do
				local err, argv, whole = roundTrip(pc, c2s, table.unpack(values, 1, 8))
				expect(err).toBe(0)
				expect(whole).toBe(true)
				for i = 1, 8 do
					expect(argv[i]).toEqual(values[i])
				end
			end
			local err, argv = roundTrip(pc, true, 3, {}, {}, { a = 1, b = "x" }, nil, {}, {}, nil)
			expect(err).toBe(0)
			expect(argv[1]).toBe(3)
			expect(argv[4]).toEqual({ a = 1, b = "x" })
			expect(argv[5]).toBeNil()
			expect(argv[8]).toBeNil()
		end)

		it("Blink shapes: Entities 100 x 6 u8 and Booleans 1000 x bool", function()
			local entity = T.struct({ id = T.u8, x = T.u8, y = T.u8, z = T.u8, hp = T.u8, kind = T.u8 })
			local entities = codec({ T.array(entity, 100) })
			local list = {}
			for i = 1, 100 do
				list[i] = { id = i, x = i % 7, y = 255, z = 0, hp = 100, kind = i % 3 }
			end
			local st, b = encode(entities, true, list)
			expect(st).toBe(0)
			expect(b).toHaveLength(1 + 600)
			local err, argv = roundTrip(entities, false, list)
			expect(err).toBe(0)
			expect(argv[1]).toEqual(list)

			local booleans = codec({ T.array(T.bool, 1000) })
			local flags = {}
			for i = 1, 1000 do
				flags[i] = i % 3 == 0
			end
			local st2, b2 = encode(booleans, true, flags)
			expect(st2).toBe(0)
			expect(b2).toHaveLength(2 + 1000)
			local err2, argv2 = roundTrip(booleans, true, flags)
			expect(err2).toBe(0)
			expect(argv2[1]).toEqual(flags)
		end)

		it("numeric arrays use the scalar loop with the same checks", function()
			local pc = codec({ T.array(T.i16(-5, 5)), T.array(T.f32), T.array(T.u32) })
			local err, argv = roundTrip(pc, true, { -5, 0, 5 }, { 1.5, -0.25 }, { 4294967295, 0 })
			expect(err).toBe(0)
			expect(argv[1]).toEqual({ -5, 0, 5 })
			expect(argv[2]).toEqual({ 1.5, -0.25 })
			expect(argv[3]).toEqual({ 4294967295, 0 })
			local st1, _, _, _, errArg1 = encode(pc, true, { 0, 6 }, {}, {})
			expect(st1).toBe(E.RANGE)
			expect(errArg1).toBe(1)
			local st2, _, _, _, errArg2 = encode(pc, true, {}, { NAN }, {})
			expect(st2).toBe(E.NONFINITE)
			expect(errArg2).toBe(2)
			local st3 = encode(pc, true, {}, {}, list(1, "2"))
			expect(st3).toBe(E.BAD_TYPE)
		end)
	end)

	describe("sender validation", function()
		local function status(pc: any, ...: any): (number, number)
			local st, _, _, _, errArg = encode(pc, true, ...)
			return st, errArg
		end

		it("names the failing top-level argument", function()
			local st, errArg = status(codec({ T.u8, T.string(3) }), 1, "long")
			expect(st).toBe(E.TOO_LONG)
			expect(errArg).toBe(2)
			st, errArg = status(codec({ T.u8 }), 1, 2)
			expect(st).toBe(E.TOO_MANY_VALUES)
			expect(errArg).toBe(2)
			st, errArg = status(codec({ T.u8, T.u8 }), 1)
			expect(st).toBe(E.MISSING)
			expect(errArg).toBe(2)
			st, errArg = status(codec({ T.bool, T.array(T.struct({ a = T.u8 })) }), true, { { a = 1 }, { a = 256 } })
			expect(st).toBe(E.RANGE)
			expect(errArg).toBe(2)
			st, errArg = status(codec({ T.u8, T.struct({ a = T.u8, b = T.string }) }), 1, { a = 1 })
			expect(st).toBe(E.MISSING)
			expect(errArg).toBe(2)
		end)

		it("checks integers and floats (finite unless AllowNonFinite, bounds always)", function()
			local u8 = codec({ T.u8(1, 10) })
			expect(status(u8, "5")).toBe(E.BAD_TYPE)
			expect(status(u8, 1.5)).toBe(E.RANGE)
			expect(status(u8, 11)).toBe(E.RANGE)
			expect(status(u8, 0)).toBe(E.RANGE)
			expect(status(u8, NAN)).toBe(E.NONFINITE)
			expect(status(u8, INF)).toBe(E.NONFINITE)
			expect(status(u8, 10)).toBe(0)
			local f64 = codec({ T.f64 })
			expect(status(f64, NAN)).toBe(E.NONFINITE)
			expect(status(f64, -INF)).toBe(E.NONFINITE)
			expect(status(codec({ T.f64 }, true), NAN)).toBe(0)
			expect(status(codec({ T.f64 }, true), INF)).toBe(0)
			expect(status(codec({ T.f64(0, 1) }), 2)).toBe(E.RANGE)
			expect(status(codec({ T.f64(0, 1) }, true), 2)).toBe(E.RANGE)
			expect(status(codec({ T.f64(0, 1) }, true), NAN)).toBe(0)
			expect(status(codec({ T.f32 }), 1e39)).toBe(E.RANGE)
			expect(status(codec({ T.f32 }, true), 1e39)).toBe(E.RANGE)
			expect(status(codec({ T.f32 }, true), INF)).toBe(0)
			expect(status(codec({ T.f32(0, 0.1) }), 0.1)).toBe(0)
		end)

		it("checks strings, buffers and vectors", function()
			expect(status(codec({ T.string }), "\255")).toBe(E.BAD_UTF8)
			expect(status(codec({ T.string(4, { Binary = true }) }), "\255")).toBe(0)
			expect(status(codec({ T.string(2) }), "abc")).toBe(E.TOO_LONG)
			expect(status(codec({ T.string }), 5)).toBe(E.BAD_TYPE)
			expect(status(codec({ T.buffer(2) }), buffer.create(3))).toBe(E.TOO_LONG)
			expect(status(codec({ T.buffer }), "ab")).toBe(E.BAD_TYPE)
			expect(status(codec({ T.Vector3 }), Vector3.new(0, NAN, 0))).toBe(E.NONFINITE)
			expect(status(codec({ T.Vector3 }, true), Vector3.new(0, NAN, 0))).toBe(0)
			expect(status(codec({ T.Vector3(1) }), Vector3.new(2, 0, 0))).toBe(E.RANGE)
			expect(status(codec({ T.Vector3(1) }), Vector3.new(0.6, 0.6, 0))).toBe(0)
			expect(status(codec({ T.Vector3 }), Vector2.new(1, 1))).toBe(E.BAD_TYPE)
			expect(status(codec({ T.Vector2(1) }), Vector2.new(1, 1))).toBe(E.RANGE)
			expect(status(codec({ T.Color3 }), Color3.new(NAN, 0, 0))).toBe(E.NONFINITE)
			expect(status(codec({ T.CFrame }), CFrame.new(NAN, 0, 0))).toBe(E.NONFINITE)
			expect(status(codec({ T.CFrame }, true), CFrame.new(INF, 0, 0))).toBe(0)
		end)

		it("checks enums, EnumItems and Instances", function()
			local enum = codec({ T.enum({ "A", "B" }) })
			expect(status(enum, "C")).toBe(E.RANGE)
			expect(status(enum, 1)).toBe(E.BAD_TYPE)
			expect(status(codec({ T.EnumItem(Enum.Material) }), Enum.KeyCode.A)).toBe(E.BAD_TYPE)
			expect(status(codec({ T.EnumItem(Enum.Material) }), "Grass")).toBe(E.BAD_TYPE)
			local inst = codec({ T.Instance("BasePart") })
			expect(status(inst, root)).toBe(E.BAD_TYPE)
			expect(status(inst, nil)).toBe(E.MISSING)
			expect(status(inst, {})).toBe(E.BAD_TYPE)
			expect(status(inst, part)).toBe(0)
			local w = Codec.newWriter(16, true)
			w.unreliable = true
			expect(inst.encode(w, 1, part)).toBe(E.NEEDS_REF)
			local many = table.create(256, part)
			local refsCodec = codec({ T.array(T.Instance()) })
			expect(status(refsCodec, table.create(255, part))).toBe(0)
			expect(status(refsCodec, many)).toBe(E.TOO_MANY_NODES)
			expect((encode(refsCodec, false, many))).toBe(0) -- S->C refs are not capped
		end)

		it("checks arrays, maps and structs", function()
			expect(status(codec({ T.array(T.u8, 2) }), { 1, 2, 3 })).toBe(E.TOO_LONG)
			expect(status(codec({ T.array(T.u8) }), "x")).toBe(E.BAD_TYPE)
			expect(status(codec({ T.array(T.bool) }), list(true, 1))).toBe(E.BAD_TYPE)
			expect(status(codec({ T.map(T.string, T.u8, 2) }), { a = 1, b = 2, c = 3 })).toBe(E.TOO_LONG)
			expect(status(codec({ T.map(T.string, T.u8) }), { [1] = 1 })).toBe(E.BAD_TYPE)
			expect(status(codec({ T.map(T.string, T.u8) }), { a = 300 })).toBe(E.RANGE)
			expect(status(codec({ T.map(T.f64, T.u8) }), { [INF] = 1 })).toBe(E.NONFINITE)
			expect(status(codec({ T.map(T.f64, T.u8) }, true), { [INF] = 1 })).toBe(0)
			expect(status(codec({ T.struct({ a = T.u8 }) }), 5)).toBe(E.BAD_TYPE)
			expect(status(codec({ T.struct({ a = T.u8 }) }), nil)).toBe(E.MISSING)
			expect(status(codec({ T.struct({ a = T.optional(T.u8) }) }), {})).toBe(0)
		end)

		it("never calls metamethods: arrays and structs are read raw", function()
			local proxy = setmetatable({}, {
				__index = function()
					error("metamethod called")
				end,
				__len = function()
					error("metamethod called")
				end,
			})
			expect(status(codec({ T.array(T.u8) }), proxy)).toBe(0) -- rawlen = 0
			expect(status(codec({ T.struct({ a = T.optional(T.u8) }) }), proxy)).toBe(0)
		end)
	end)

	describe("receiver validation (server, hostile)", function()
		local function hostile(pc: any, b: buffer, refs: { any }?, nrefs: number?): (number, number, { any })
			local ctx, _, _, argv = decode(pc, true, b, refs, nrefs)
			return ctx.err, ctx.errArg, argv
		end

		it(
			"uses the positive form for floats: NaN and +-inf fail unless AllowNonFinite, bounds always apply",
			function()
				for _, value in { NAN, INF, -INF } do
					local err, errArg = hostile(codec({ T.f64 }), bytes().f64(value).done())
					expect(err).toBe(D.NONFINITE)
					expect(errArg).toBe(1)
					local ok, _, argv = hostile(codec({ T.f64 }, true), bytes().f64(value).done())
					expect(ok).toBe(0)
					expect(argv[1]).toBe(value)
				end
				expect((hostile(codec({ T.f32 }), bytes().f32(NAN).done()))).toBe(D.NONFINITE)
				expect((hostile(codec({ T.f64(0, 10) }), bytes().f64(11).done()))).toBe(D.RANGE)
				expect((hostile(codec({ T.f64(0, 10) }, true), bytes().f64(11).done()))).toBe(D.RANGE)
				expect((hostile(codec({ T.f64(0, 10) }, true), bytes().f64(INF).done()))).toBe(0)
				expect((hostile(codec({ T.f64(0, 10) }), bytes().f64(-0.0).done()))).toBe(0)
				expect((hostile(codec({ T.array(T.f64) }), bytes().u16(2).f64(1).f64(NAN).done()))).toBe(D.NONFINITE)
			end
		)

		it("checks integer ranges and names the argument", function()
			local pc = codec({ T.u8, T.u8, T.u8(1, 10) })
			local err, errArg = hostile(pc, bytes().u8(0).u8(0).u8(11).done())
			expect(err).toBe(D.RANGE)
			expect(errArg).toBe(3)
			expect((hostile(pc, bytes().u8(0).u8(0).u8(10).done()))).toBe(0)
			expect((hostile(codec({ T.array(T.i8(-1, 1)) }), bytes().u16(2).u8(1).u8(0xFE).done()))).toBe(D.RANGE)
		end)

		it("rejects bad bool and presence bytes as structural", function()
			expect((hostile(codec({ T.bool }), bytes().u8(2).done()))).toBe(D.BAD_TAG)
			expect((hostile(codec({ T.array(T.bool) }), bytes().u16(2).u8(1).u8(7).done()))).toBe(D.BAD_TAG)
			expect((hostile(codec({ T.optional(T.u8) }), bytes().u8(2).u8(1).done()))).toBe(D.BAD_PRESENCE)
			local err, _, argv = hostile(codec({ T.optional(T.u8), T.u8 }), bytes().u8(0).u8(9).done())
			expect(err).toBe(0)
			expect(argv[1]).toBeNil()
			expect(argv[2]).toBe(9)
		end)

		it("checks strings: UTF-8 unless Binary, max length, length vs bytes left", function()
			local bad = bytes().u8(2).str("\195\40").done()
			expect((hostile(codec({ T.string(10) }), bad))).toBe(D.BAD_UTF8)
			expect((hostile(codec({ T.string(10, { Binary = true }) }), bad))).toBe(0)
			expect((hostile(codec({ T.string(3) }), bytes().u8(5).str("abcde").done()))).toBe(D.TOO_LONG)
			expect((hostile(codec({ T.string(10) }), bytes().u8(5).str("ab").done()))).toBe(D.OVERRUN)
			expect((hostile(codec({ T.buffer(3) }), bytes().u8(4).str("abcd").done()))).toBe(D.TOO_LONG)
		end)

		it("checks counts against max and against the bytes left before allocating", function()
			expect((hostile(codec({ T.array(T.u8, 3) }), bytes().u8(5).str("\1\2\3\4\5").done()))).toBe(D.TOO_LONG)
			expect((hostile(codec({ T.array(T.u8, 60000) }), bytes().u16(50000).str("\1\2\3").done()))).toBe(D.OVERRUN)
			local structs = codec({ T.array(T.struct({ a = T.u32 }), 100) })
			expect((hostile(structs, bytes().u8(3).u32(1).u32(2).done()))).toBe(D.OVERRUN) -- 3 x 4 B > 8 B
			expect((hostile(codec({ T.array(T.Instance()) }), bytes().u16(4000).u8(0).done(), { part }, 1))).toBe(
				D.OVERRUN
			)
			expect((hostile(codec({ T.map(T.u8, T.u8, 60000) }), bytes().u16(10000).u8(1).u8(2).done()))).toBe(
				D.OVERRUN
			)
			expect((hostile(codec({ T.map(T.u8, T.u8, 1) }), bytes().u8(2).str("\1\1\2\2").done()))).toBe(D.TOO_LONG)
		end)

		it("checks enum indexes and EnumItem values", function()
			expect((hostile(codec({ T.enum({ "A", "B", "C" }) }), bytes().u8(3).done()))).toBe(D.BAD_ENUM)
			local _, _, argv = hostile(codec({ T.enum({ "A", "B", "C" }) }), bytes().u8(2).done())
			expect(argv[1]).toBe("C")
			expect((hostile(codec({ T.EnumItem(Enum.Material) }), bytes().u16(65535).done()))).toBe(D.BAD_ENUM)
			local _, _, argv2 =
				hostile(codec({ T.EnumItem(Enum.Material) }), bytes().u16(Enum.Material.Slate.Value).done())
			expect(argv2[1]).toBe(Enum.Material.Slate)
		end)

		it("checks vector, color and CFrame components and magnitudes", function()
			local nanY = bytes().f32(0).f32(NAN).f32(0).done()
			expect((hostile(codec({ T.Vector3 }), nanY))).toBe(D.NONFINITE)
			expect((hostile(codec({ T.Vector3 }, true), nanY))).toBe(0)
			expect((hostile(codec({ T.Vector3(1) }), bytes().f32(2).f32(0).f32(0).done()))).toBe(D.RANGE)
			expect((hostile(codec({ T.Vector2 }), bytes().f32(INF).f32(0).done()))).toBe(D.NONFINITE)
			expect((hostile(codec({ T.Vector2(1) }), bytes().f32(1).f32(1).done()))).toBe(D.RANGE)
			expect((hostile(codec({ T.Color3 }), bytes().f32(0).f32(0).f32(NAN).done()))).toBe(D.NONFINITE)
			local cf = bytes()
			for i = 1, 12 do
				cf.f32(if i == 9 then NAN else 0)
			end
			expect((hostile(codec({ T.CFrame }), cf.done()))).toBe(D.NONFINITE)
		end)

		it("NaN map keys are NONFINITE even with AllowNonFinite; infinite keys pass with it", function()
			local pcAnf = codec({ T.map(T.f64, T.u8) }, true)
			local err, errArg = hostile(pcAnf, bytes().u16(1).f64(NAN).u8(1).done())
			expect(err).toBe(D.NONFINITE)
			expect(errArg).toBe(1)
			local ok, _, argv = hostile(pcAnf, bytes().u16(1).f64(INF).u8(1).done())
			expect(ok).toBe(0)
			expect(argv[1][INF]).toBe(1)
			expect((hostile(codec({ T.map(T.f64, T.u8) }), bytes().u16(1).f64(INF).u8(1).done()))).toBe(D.NONFINITE)
			expect((hostile(codec({ T.map(T.f32, T.u8) }, true), bytes().u16(1).f32(NAN).u8(1).done()))).toBe(
				D.NONFINITE
			)
		end)

		it("checks Instances: index, missing, type, class, root and Nilable", function()
			local any = codec({ T.Instance() })
			expect((hostile(any, bytes().u8(1).done(), { part }, 1))).toBe(D.BAD_REF)
			expect((hostile(any, bytes().u8(0).done(), {}, 1))).toBe(D.MISSING_INSTANCE)
			expect((hostile(codec({ T.optional(T.Instance()) }), bytes().u8(1).u8(0).done(), {}, 1))).toBe(0)
			expect((hostile(codec({ T.optional(T.Instance()) }), bytes().u8(0).done()))).toBe(0)
			expect((hostile(any, bytes().u8(0).done(), { {} }, 1))).toBe(D.BAD_TYPE)
			expect((hostile(codec({ T.Instance("BasePart") }), bytes().u8(0).done(), { root }, 1))).toBe(D.BAD_INSTANCE)
			local rooted = codec({ T.Instance("BasePart", root) })
			expect((hostile(rooted, bytes().u8(0).done(), { outside }, 1))).toBe(D.BAD_INSTANCE)
			local ok, _, argv = hostile(rooted, bytes().u8(1).done(), { outside, part }, 2)
			expect(ok).toBe(0)
			expect(argv[1]).toBe(part)
			expect((hostile(any, bytes().u8(0x80).u8(0x80).u8(0x80).done(), { part }, 1))).toBe(D.BAD_VARINT)
			expect((hostile(any, bytes().u8(0x80).done(), { part }, 1))).toBe(D.OVERRUN)
		end)

		it("rejects a second reference to one sidecar slot in a frame (BadRef), typed or untyped", function()
			local two = codec({ T.Instance(), T.Instance() })
			expect((hostile(two, bytes().u8(0).u8(0).done(), { part }, 1))).toBe(D.BAD_REF)
			local ok, _, argv = hostile(two, bytes().u8(0).u8(1).done(), { part, part }, 2)
			expect(ok).toBe(0)
			expect(argv[1]).toBe(part)
			expect(argv[2]).toBe(part)
			-- typed and untyped references share the frame's flags
			local mixed = codec({ T.Instance(), T.any })
			expect((hostile(mixed, bytes().u8(0).u8(C.Tag.REF).u8(0).done(), { part }, 1))).toBe(D.BAD_REF)
			-- an honest client writer gives every value its own slot
			local st, b, refs, nrefs = encode(two, true, part, part)
			expect(st).toBe(0)
			expect(nrefs).toBe(2)
			local ctx = decode(two, true, b, refs, nrefs)
			expect(ctx.err).toBe(0)
		end)

		it("decodes hostile arrays of non-scalar elements past the 64-slot preallocation", function()
			local rows = {}
			for i = 1, 200 do
				rows[i] = { i % 256, (i * 7) % 256 }
			end
			local err, argv, whole = roundTrip(codec({ T.array(T.array(T.u8, 4), 300) }), true, rows)
			expect(err).toBe(0)
			expect(whole).toBe(true)
			expect(#argv[1]).toBe(200)
			expect(argv[1][200][2]).toBe((200 * 7) % 256)
			-- a count larger than the elements that follow still fails (and allocates little)
			local short = bytes().u16(300).u8(1).u8(5).done()
			expect((hostile(codec({ T.array(T.array(T.u8, 4), 300) }), short))).toBe(D.OVERRUN)
		end)
	end)

	describe("client decode (trusted)", function()
		it("skips semantic checks", function()
			local function client(pc: any, b: buffer): (number, { any })
				local ctx, _, _, argv = decode(pc, false, b)
				return ctx.err, argv
			end
			local err, argv = client(codec({ T.f64 }), bytes().f64(NAN).done())
			expect(err).toBe(0)
			expect(argv[1] ~= argv[1]).toBe(true)
			err, argv = client(codec({ T.u8(1, 10) }), bytes().u8(11).done())
			expect(err).toBe(0)
			expect(argv[1]).toBe(11)
			err = client(codec({ T.string(1) }), bytes().u8(2).str("\255\255").done())
			expect(err).toBe(0)
			err = client(codec({ T.bool }), bytes().u8(2).done())
			expect(err).toBe(D.BAD_TAG) -- structural on both sides
		end)

		it("records MISSING_INSTANCE, finishes the message and keeps the ref cursor for the next one", function()
			local first = codec({ T.Instance(), T.u8, T.Instance() })
			local second = codec({ T.u8, T.Instance() })
			local frame = bytes().u8(7).u8(9).done() -- two S->C messages, one byte each
			local refs: { any } = { nil, part, root }
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, refs, 0)
			Codec.beginMessage(ctx, false)
			local argv = {}
			local n, q = first.decode(frame, 0, 2, ctx, argv)
			expect(ctx.err).toBe(D.MISSING_INSTANCE)
			expect(n).toBe(3)
			expect(q).toBe(1)
			expect(argv[2]).toBe(7)
			expect(argv[3]).toBe(part)
			expect(ctx.cursor).toBe(2)
			Codec.beginMessage(ctx, false)
			local argv2 = {}
			local _, q2 = second.decode(frame, 1, 2, ctx, argv2)
			expect(ctx.err).toBe(0)
			expect(q2).toBe(2)
			expect(argv2[1]).toBe(9)
			expect(argv2[2]).toBe(root)
		end)

		it("bounds S->C arrays of 0-byte Instance elements by their declared max", function()
			local pc = codec({ T.array(T.Instance(), 4) })
			local refs = { part, root, part, root }
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, refs, 0)
			Codec.beginMessage(ctx, false)
			local argv = {}
			local _, q = pc.decode(bytes().u8(4).done(), 0, 1, ctx, argv)
			expect(ctx.err).toBe(0)
			expect(q).toBe(1)
			expect(argv[1]).toEqual(refs)
			Codec.beginFrame(ctx, refs, 0)
			Codec.beginMessage(ctx, false)
			local _, q2 = pc.decode(bytes().u8(200).done(), 0, 1, ctx, {})
			expect(ctx.err).toBe(D.OVERRUN)
			expect(q2 <= 1).toBe(true)
			expect(ctx.cursor).toBe(0) -- nothing consumed
		end)

		it("a structural failure after a missing Instance wins", function()
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, {}, 0)
			Codec.beginMessage(ctx, false)
			codec({ T.Instance(), T.bool }).decode(bytes().u8(2).done(), 0, 1, ctx, {})
			expect(ctx.err).toBe(D.BAD_TAG)
		end)
	end)

	describe("decode fuzz", function()
		local function fuzzCodecs(): { any }
			return {
				codec({ T.u8, T.u16, T.f32, T.bool }),
				codec({ T.string(64), T.buffer(16), T.optional(T.string) }),
				codec({ T.Vector3(100), T.Vector2, T.Color3, T.CFrame }),
				codec({
					T.enum({ "A", "B", "C" }),
					T.EnumItem(Enum.Material),
					T.optional(T.Instance("BasePart", root)),
				}),
				codec({ T.array(T.u8, 300), T.array(T.f64), T.array(T.bool, 5000) }),
				codec({
					T.map(T.string, T.array(T.i16)),
					T.struct({ a = T.u8, b = T.optional(T.any), c = T.map(T.f64, T.bool) }),
				}, true),
				codec({ T.any, T.array(T.any), T.optional(T.optional(T.i32)) }),
				codec({ T.array(T.struct({ id = T.u16, hp = T.u8, pos = T.Vector3 }), 100), T.array(T.Instance()) }),
			}
		end

		-- valid values for each fuzz codec (same order)
		local function fuzzValues(): { { any } }
			return {
				{ 7, 300, 1.5, true },
				{ "hello", buffer.fromstring("xy"), "opt" },
				{ Vector3.new(1, 2, 3), Vector2.new(1, 2), Color3.new(1, 0, 0), CFrame.new(1, 2, 3) },
				{ "B", Enum.Material.Grass, part },
				{ { 1, 2, 3 }, { 1.5, -2 }, { true, false } },
				{ { a = { 1, -2 }, b = {} }, { a = 1, b = "x", c = { [1.5] = true } } },
				{ "x", list(1, "two"), 5 },
				{ { { id = 1, hp = 2, pos = Vector3.one } }, { part, root } },
			}
		end

		local function fuzz(pc: any, hostileSide: boolean, seed: number): (number, string?)
			local rng = Random.new(seed)
			local refs: { any } = { part, root, {} }
			local argv = {}
			local ctx = Codec.newReadCtx(hostileSide, hostileSide)
			local problems, first = 0, nil
			for iter = 1, FUZZ_BUFFERS do
				local b = randomBuffer(rng, 48)
				local lim = buffer.len(b)
				Codec.beginFrame(ctx, refs, if hostileSide then 3 else 0)
				if hostileSide then
					Codec.walkSidecar(refs, 3, ctx)
				end
				Codec.beginMessage(ctx, pc.allowNonFinite)
				local ok, n, q = pcall(pc.decode, b, 0, lim, ctx, argv)
				if not ok or type(q) ~= "number" or q < 0 or q > lim or n ~= pc.count then
					problems += 1
					if first == nil then
						first = string.format(
							"buffer %s: %s",
							buffer.tostring(b):gsub(".", function(c)
								return string.format("%02x", string.byte(c))
							end),
							if ok then "offset " .. tostring(q) else tostring(n)
						)
					end
				end
				table.clear(argv)
				if iter % 2500 == 0 then
					task.wait()
				end
			end
			return problems, first
		end

		it("never throws or overruns on 10,000 random buffers per codec (server)", function()
			for index, pc in fuzzCodecs() do
				local problems, first = fuzz(pc, true, 1000 + index)
				expect(first).toBeNil()
				expect(problems).toBe(0)
			end
		end, { timeout = 120 })

		it("never throws or overruns on 10,000 random buffers per codec (client)", function()
			-- includes the S->C array of Instances (0 bytes per element: bounded by its declared max)
			local codecs = fuzzCodecs()
			for index = 1, #codecs do
				local problems, first = fuzz(codecs[index], false, 2000 + index)
				expect(first).toBeNil()
				expect(problems).toBe(0)
			end
		end, { timeout = 120 })

		it("fails every truncation of a valid message without reading past the cut", function()
			local codecs, values = fuzzCodecs(), fuzzValues()
			for index, pc in codecs do
				local row = values[index]
				local st, b, refs, nrefs = encode(pc, true, table.unpack(row, 1, pc.count))
				expect(st).toBe(0)
				local len = buffer.len(b)
				local ctx, _, q = decode(pc, true, b, refs, nrefs)
				expect(ctx.err).toBe(0)
				expect(q).toBe(len)
				local bad = {}
				for cut = 0, len - 1 do
					local cctx, _, cq = decode(pc, true, b, refs, nrefs, cut)
					if cctx.err == 0 or cq > cut then
						table.insert(bad, cut)
					end
				end
				expect(bad).toEqual({})
			end
		end, { timeout = 60 })

		it("readDescriptor never throws on random bytes", function()
			local rng = Random.new(77)
			local problems = 0
			for iter = 1, FUZZ_BUFFERS do
				local b = randomBuffer(rng, 40)
				-- ops are 1..23: bias the first byte into range so the parsers are exercised
				if buffer.len(b) > 0 then
					buffer.writeu8(b, 0, rng:NextInteger(0, 24))
				end
				local ok, d, q = pcall(Schema.readDescriptor, b, 0, buffer.len(b), 1)
				if not ok or q > buffer.len(b) or (d ~= nil and not Schema.isDescriptor(d)) then
					problems += 1
				end
				if iter % 2500 == 0 then
					task.wait()
				end
			end
			expect(problems).toBe(0)
		end, { timeout = 60 })
	end)
end
