--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Codec = require(ReplicatedStorage.LorenRuntime.Codec)
local Schema = require(ReplicatedStorage.LorenRuntime.Schema)
local Manifest = require(ReplicatedStorage.LorenRuntime.Manifest)

local T = Schema.T
local Op, F, K = C.SchemaOp, C.MemberFlag, C.Kind
local F32_MAX, F64_MAX = C.Limit.F32_MAX, C.Limit.F64_MAX
local INF, NAN = math.huge, 0 / 0
local FUZZ_BUFFERS = 10000
local ROOT_NAME = "ManifestSpecRootQZ"
local HEADER_BYTES = 54 -- proto, str8 "2.0.0", limits (47 B): everything before serviceCount

-- Raw little-endian bytes: wire().u8(2).str8("2.0.0").done()
local function wire(): any
	local b = buffer.create(8192)
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
	function self.str8(s: string): any
		buffer.writeu8(b, n, #s)
		buffer.writestring(b, n + 1, s)
		n += 1 + #s
		return self
	end
	function self.done(): buffer
		local out = buffer.create(n)
		buffer.copy(out, 0, b, 0, n)
		return out
	end
	return self
end

local function limits(mirror: number?): any
	return {
		frameRate = 120,
		frameBurst = 140,
		byteRate = 131072,
		byteBurst = 262144,
		msgRate = 600,
		msgBurst = 600,
		mirror = mirror or 0.5, -- exact in f32, so the identity holds
		sealC2S = 16384,
		maxMessageC2S = 65536,
		unreliableMax = 900,
		maxPending = 256,
		maxNodes = 2048,
		maxArgs = 20,
		maxRefs = 255,
		maxDepth = 16,
		flushHz = 61,
		backlogWindow = 10,
	}
end

local function model(services: { any }, mirror: number?): any
	return { proto = C.PROTO, version = "2.0.0", limits = limits(mirror), services = services }
end

-- A ManifestMember with its kind's defaults; HasArgs/HasReturns follow args/returns (what the encoder writes).
local function member(m: { [string]: any }): any
	local kind = m.kind
	local flags = m.flags or 0
	if m.args ~= nil then
		flags = bit32.bor(flags, F.HasArgs)
	end
	if m.returns ~= nil then
		flags = bit32.bor(flags, F.HasReturns)
	end
	return {
		name = m.name,
		kind = kind,
		route = m.route,
		flags = flags,
		timeout = if m.timeout ~= nil then m.timeout elseif kind == K.Method then 10 else 0,
		rate = if m.rate ~= nil then m.rate elseif kind == K.Signal then 0 else 5,
		burst = if m.burst ~= nil then m.burst elseif kind == K.Signal then 0 else 10,
		backlog = m.backlog or 0,
		args = m.args,
		returns = m.returns,
	}
end

-- One descriptor per op (1..23), in op order.
local function everyOp(root: Instance?): { any }
	return {
		T.bool,
		T.u8(1, 9),
		T.u16,
		T.u32(0, 100000),
		T.i8,
		T.i16(-5, 5),
		T.i32,
		T.f32(0.1, 0.3),
		T.num(-1, 1),
		T.string(300, { Binary = true }),
		T.buffer(70000),
		T.Vector3(50),
		T.Vector2,
		T.Color3,
		T.CFrame,
		T.enum({ "A", "B" }),
		T.EnumItem(Enum.Material),
		T.Instance("BasePart", root),
		T.optional(T.Instance()),
		T.array(T.u8, 10),
		T.map(T.string, T.any, 5),
		T.struct({ b = T.u8, a = T.array(T.struct({ x = T.f64 }), 3) }),
		T.any,
	}
end

-- Every kind, every member flag, every descriptor op, 1/2/3-byte-head routes, a Method and a Signal sharing a name.
local function fullModel(root: Instance?): any
	return model({
		{
			name = "Alpha",
			members = {
				member({
					name = "Buy",
					kind = K.Method,
					route = 300,
					flags = F.Serial + F.AllowNonFinite,
					timeout = 2.5,
					args = everyOp(root),
					returns = { T.bool, T.optional(T.Instance("Part")) },
				}),
				member({ name = "Buy", kind = K.Signal, route = 4064, backlog = 64 }),
				member({ name = "Call", kind = K.Method, route = 65535, timeout = 120, rate = 1, burst = 1 }),
				member({
					name = "Move",
					kind = K.Event,
					route = 1,
					flags = F.Unreliable + F.Ordered + F.Coalesce + F.AllowNonFinite,
					rate = 120,
					burst = 60,
					args = { T.Vector3(100), T.u8 },
				}),
				member({ name = "Ping", kind = K.Event, route = 2, rate = 75, burst = 150, args = {} }),
				member({
					name = "Tick",
					kind = K.Signal,
					route = 3,
					flags = F.Unreliable + F.Ordered,
					args = { T.f32 },
				}),
			},
		},
		{
			name = "Beta",
			members = {
				member({
					name = "Get",
					kind = K.Method,
					route = 224,
					rate = 50,
					burst = 100,
					returns = { T.array(T.string(20)) },
				}),
			},
		},
		{
			name = "Zed",
			members = {
				member({
					name = "Changed",
					kind = K.Signal,
					route = 4063,
					backlog = 1024,
					args = { T.optional(T.optional(T.u8)) },
				}),
			},
		},
	})
end

local function manual(services: { any }, proto: number?, mirror: number?, trailing: boolean?): buffer
	local w = wire()
	w.u8(proto or C.PROTO).str8("2.0.0")
	for _, v in { 120, 140, 131072, 262144, 600, 600, mirror or 0.5 } do
		w.f32(v)
	end
	w.u32(16384).u32(65536).u16(900).u16(256).u16(2048)
	w.u8(20).u8(255).u8(16).u8(61).u8(10)
	w.u16(#services)
	for _, s in services do
		w.str8(s.name).u16(#s.members)
		for _, m in s.members do
			w.str8(m.name).u8(m.kind).u16(m.route).u8(m.flags or 0)
			if m.kind == K.Method then
				w.u16(m.ds or 100).f32(m.rate or 5).f32(m.burst or 10)
			elseif m.kind == K.Event then
				w.f32(m.rate or 5).f32(m.burst or 10)
			else
				w.u16(m.backlog or 0)
			end
			local desc: ((any) -> ())? = m.desc
			if desc then
				desc(w)
			end
		end
	end
	if trailing then
		w.u8(0)
	end
	return w.done()
end

local function oneService(members: { any }): { any }
	return { { name = "S", members = members } }
end

-- A Signal whose Args section is written raw by desc(w) (count byte + descriptors).
local function withArgs(desc: (any) -> ()): buffer
	return manual(oneService({ { name = "M", kind = K.Signal, route = 1, flags = F.HasArgs, desc = desc } }))
end

-- Args = { levels x OPTIONAL around BOOL }: nesting depth levels + 1.
local function nestedArgs(levels: number): (any) -> ()
	return function(w: any)
		w.u8(1)
		for _ = 1, levels do
			w.u8(Op.OPTIONAL)
		end
		w.u8(Op.BOOL)
	end
end

local function decodeAll(b: buffer): (any, string?)
	return Manifest.decode(b, 0, buffer.len(b))
end

local function descBytes(d: any): string
	local w = Codec.newWriter(64, false)
	Schema.writeDescriptor(w, d)
	return string.sub(buffer.tostring(w.buf), 1, w.n)
end

local function collectOps(d: any, seen: { [number]: boolean })
	seen[d.op] = true
	if d.inner then
		collectOps(d.inner, seen)
	end
	if d.key then
		collectOps(d.key, seen)
	end
	if d.fields then
		for _, field in d.fields do
			collectOps(field.desc, seen)
		end
	end
end

-- nil when decode kept its contract on b[0, lim): no throw, (model, nil) or (nil, reason string).
local function contractProblem(b: buffer, lim: number): string?
	local ok, m, reason = pcall(Manifest.decode, b, 0, lim)
	if not ok then
		return "threw: " .. tostring(m)
	end
	if m == nil then
		if type(reason) ~= "string" or reason == "" then
			return "nil without a reason"
		end
	elseif type(m) ~= "table" or reason ~= nil then
		return "bad result shape"
	end
	return nil
end

local function hex(b: buffer, lim: number): string
	local s = string.sub(buffer.tostring(b), 1, lim)
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

-- small values are likelier to form valid counts, name lengths, kinds, flags and ops
local function randomByte(rng: Random): number
	local roll = rng:NextNumber()
	return if roll < 0.4
		then rng:NextInteger(0, 3)
		elseif roll < 0.7 then rng:NextInteger(1, 23)
		elseif roll < 0.75 then 255
		else rng:NextInteger(0, 255)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("encode -> decode", function()
		it("decodes to the model it was encoded from (every kind, flag and descriptor op)", function()
			local original = fullModel(nil)
			-- the fixture really covers every op, kind and flag
			local ops: { [number]: boolean } = {}
			local kinds: { [number]: boolean } = {}
			local flags = 0
			for _, s in original.services do
				for _, m in s.members do
					kinds[m.kind] = true
					flags = bit32.bor(flags, m.flags)
					for _, list in { m.args or {}, m.returns or {} } do
						for _, d in list do
							collectOps(d, ops)
						end
					end
				end
			end
			for name: any, op: any in Op :: any do
				expect(if ops[op] then name else "missing " .. name).toBe(name)
			end
			expect(kinds).toEqual({ [K.Method] = true, [K.Event] = true, [K.Signal] = true })
			expect(flags).toBe(0x7F)

			local bytes = Manifest.encode(original)
			local decoded: any, reason = decodeAll(bytes)
			expect(reason).toBeNil()
			expect(decoded).toEqual(fullModel(nil))
			expect(decoded.proto).toBe(C.PROTO)
			expect(decoded.version).toBe("2.0.0")
			local buy = decoded.services[1].members[1]
			expect(buy.timeout).toBe(2.5)
			expect(Schema.isDescriptor(buy.args[22])).toBe(true)
			expect(table.isfrozen(buy.args)).toBe(true)
			expect(Schema.isDescriptor(buy.returns[2].inner)).toBe(true)
			expect(buy.returns[2].inner.flags).toBe(C.DescFlag.Nilable)
			expect(decoded.services[1].members[5].args).toEqual({}) -- typed, zero Args
			expect(decoded.services[1].members[3].args).toBeNil() -- untyped
			-- the decoded model encodes to the same bytes
			expect(buffer.tostring(Manifest.encode(decoded))).toBe(buffer.tostring(bytes))
		end)

		it("decodes a manifest inside a larger buffer at an offset", function()
			local bytes = Manifest.encode(fullModel(nil))
			local len = buffer.len(bytes)
			local big = buffer.create(len + 9)
			buffer.fill(big, 0, 0xAB)
			buffer.copy(big, 5, bytes, 0, len)
			local decoded: any, reason = Manifest.decode(big, 5, 5 + len)
			expect(reason).toBeNil()
			expect(decoded).toEqual(fullModel(nil))
		end)

		it("stores f32 fields as their f32 image", function()
			local bytes = Manifest.encode(model({}, 0.9))
			local decoded: any = decodeAll(bytes)
			local scratch = buffer.create(4)
			buffer.writef32(scratch, 0, 0.9)
			expect(decoded.limits.mirror).toBe(buffer.readf32(scratch, 0))
			expect(decoded.limits.mirror).toBeCloseTo(0.9, 6)
		end)
	end)

	describe("bytes", function()
		it("are exact-size and follow the §4.7 layout", function()
			expect(Manifest.encode(model({}))).toHaveLength(HEADER_BYTES + 2)
			local m = model(oneService({
				member({ name = "A", kind = K.Method, route = 7, flags = F.Serial, timeout = 2.5, args = { T.u8 } }),
				member({ name = "B", kind = K.Event, route = 300, flags = F.Unreliable }),
				member({ name = "C", kind = K.Signal, route = 4064, backlog = 64 }),
				member({
					name = "D",
					kind = K.Method,
					route = 8,
					returns = { T.string(300, { Binary = true }), T.Instance("Part") },
				}),
			}))
			local expected = manual(oneService({
				{
					name = "A",
					kind = K.Method,
					route = 7,
					flags = F.HasArgs + F.Serial,
					ds = 25,
					desc = function(w: any)
						w.u8(1).u8(Op.U8).f64(0).f64(255)
					end,
				},
				{ name = "B", kind = K.Event, route = 300, flags = F.Unreliable },
				{ name = "C", kind = K.Signal, route = 4064, backlog = 64 },
				{
					name = "D",
					kind = K.Method,
					route = 8,
					flags = F.HasReturns,
					desc = function(w: any)
						w.u8(2).u8(Op.STRING).u8(C.DescFlag.Binary).u32(300).u8(Op.INSTANCE).str8("Part").u8(0)
					end,
				},
			}))
			local bytes = Manifest.encode(m)
			expect(buffer.len(bytes)).toBe(buffer.len(expected))
			expect(hex(bytes, buffer.len(bytes))).toBe(hex(expected, buffer.len(expected)))
		end)

		it("write every descriptor op as in §4.7 and read it back", function()
			local root = Instance.new("Folder")
			local cases: { { any } } = {
				{ T.bool, wire().u8(Op.BOOL) },
				{ T.Color3, wire().u8(Op.COLOR3) },
				{ T.CFrame, wire().u8(Op.CFRAME) },
				{ T.any, wire().u8(Op.ANY) },
				{ T.i16(-5, 5), wire().u8(Op.I16).f64(-5).f64(5) },
				{ T.u32, wire().u8(Op.U32).f64(0).f64(4294967295) },
				{ T.f64, wire().u8(Op.F64).f64(-F64_MAX).f64(F64_MAX) },
				{ T.f32, wire().u8(Op.F32).f64(-F32_MAX).f64(F32_MAX) },
				{ T.string, wire().u8(Op.STRING).u8(0).u32(1024) },
				{ T.string(300, { Binary = true }), wire().u8(Op.STRING).u8(1).u32(300) },
				{ T.buffer(7), wire().u8(Op.BUFFER).u32(7) },
				{ T.Vector3, wire().u8(Op.VECTOR3).f64(INF) },
				{ T.Vector2(2.5), wire().u8(Op.VECTOR2).f64(2.5) },
				{ T.enum({ "A", "BC" }), wire().u8(Op.ENUM).u8(2).str8("A").str8("BC") },
				{ T.EnumItem(Enum.Material), wire().u8(Op.ENUMITEM).str8("Material") },
				{ T.Instance("Part", root), wire().u8(Op.INSTANCE).str8("Part").u8(0), T.Instance("Part") },
				{ T.optional(T.Instance()), wire().u8(Op.OPTIONAL).u8(Op.INSTANCE).str8("").u8(1) },
				{ T.array(T.u8, 3), wire().u8(Op.ARRAY).u32(3).u8(Op.U8).f64(0).f64(255) },
				{ T.map(T.string(4), T.bool, 9), wire().u8(Op.MAP).u32(9).u8(Op.STRING).u8(0).u32(4).u8(Op.BOOL) },
				{
					T.struct({ b = T.bool, a = T.u8 }),
					wire().u8(Op.STRUCT).u8(2).str8("a").u8(Op.U8).f64(0).f64(255).str8("b").u8(Op.BOOL),
				},
			}
			for _, case in cases do
				local expected = case[2].done()
				local s = descBytes(case[1])
				expect(hex(buffer.fromstring(s), #s)).toBe(hex(expected, buffer.len(expected)))
				local d, q = Schema.readDescriptor(expected, 0, buffer.len(expected), 1)
				expect(q).toBe(buffer.len(expected))
				expect(Schema.isDescriptor(d)).toBe(true)
				expect(d).toEqual(case[3] or case[1])
			end
			root:Destroy()
		end)

		it("are deterministic and never carry Instance roots", function()
			local root = Instance.new("Folder")
			root.Name = ROOT_NAME
			local a = Manifest.encode(fullModel(root))
			local b = Manifest.encode(fullModel(root))
			local c = Manifest.encode(fullModel(nil))
			expect(buffer.tostring(a)).toBe(buffer.tostring(b))
			expect(buffer.tostring(a)).toBe(buffer.tostring(c))
			expect(string.find(buffer.tostring(a), ROOT_NAME, 1, true)).toBeNil()
			expect(descBytes(T.Instance("BasePart", root))).toBe(descBytes(T.Instance("BasePart")))
			local decoded: any = decodeAll(a)
			local inst = decoded.services[1].members[1].args[18]
			expect(inst.op).toBe(Op.INSTANCE)
			expect(inst.className).toBe("BasePart")
			expect(inst.root).toBeNil()
			root:Destroy()
		end)
	end)

	describe("decode rejects", function()
		it("a protocol mismatch before anything else", function()
			local valid = oneService({ { name = "X", kind = K.Signal, route = 1 } })
			for _, proto in { 0, 1, 3, 255 } do
				local m, reason = decodeAll(manual(valid, proto))
				expect(m).toBeNil()
				expect(reason).toBe("protocol mismatch")
			end
			local m, reason = decodeAll(buffer.fromstring("\1"))
			expect(m).toBeNil()
			expect(reason).toBe("protocol mismatch")
		end)

		it("bad arguments and bounds without throwing", function()
			local bytes = Manifest.encode(model({}))
			local len = buffer.len(bytes)
			local cases: { { any } } = {
				{ "bad arguments", "x", 0, 1 },
				{ "bad arguments", nil, 0, 0 },
				{ "bad arguments", bytes, "0", len },
				{ "bad bounds", bytes, 0, len + 1 },
				{ "bad bounds", bytes, -1, len },
				{ "bad bounds", bytes, 0.5, len },
				{ "bad bounds", bytes, 5, 4 },
				{ "bad bounds", bytes, 0, NAN },
				{ "truncated", bytes, 0, 0 },
			}
			for _, case in cases do
				local ok, m, reason = pcall(Manifest.decode, case[2], case[3], case[4])
				expect(ok).toBe(true)
				expect(m).toBeNil()
				expect(reason).toBe(case[1])
			end
		end)

		it("malformed fields with a reason", function()
			local function signal(name: string, route: number): any
				return { name = name, kind = K.Signal, route = route }
			end
			local cases: { { any } } = {
				{ "bad limits", manual(oneService({}), nil, 2) },
				{ "bad limits", manual(oneService({}), nil, 0) },
				{ "bad limits", manual(oneService({}), nil, NAN) },
				{ "bad service name or order", manual({ { name = "b", members = {} }, { name = "a", members = {} } }) },
				{ "bad service name or order", manual({ { name = "a", members = {} }, { name = "a", members = {} } }) },
				{ "bad service name or order", manual({ { name = "", members = {} } }) },
				{ "bad member name or order", manual(oneService({ signal("B", 1), signal("A", 2) })) },
				{ "bad member name or order", manual(oneService({ signal("A", 1), signal("A", 2) })) },
				{
					"bad member name or order",
					manual(oneService({ signal("A", 1), { name = "A", kind = K.Method, route = 2 } })),
				},
				{ "bad member name or order", manual(oneService({ signal("", 1) })) },
				{ "bad member kind", manual(oneService({ { name = "A", kind = 0, route = 1 } })) },
				{ "bad member kind", manual(oneService({ { name = "A", kind = 4, route = 1 } })) },
				{ "bad route", manual(oneService({ signal("A", 0) })) },
				{ "bad route", manual(oneService({ signal("A", 5), signal("B", 5) })) },
				{
					"bad route",
					manual({
						{ name = "A", members = { signal("X", 9) } },
						{ name = "B", members = { signal("Y", 9) } },
					}),
				},
				{
					"bad member flags",
					manual(oneService({ { name = "A", kind = K.Signal, route = 1, flags = 0x80 } })),
				},
				{
					"bad member flags",
					manual(oneService({ { name = "A", kind = K.Event, route = 1, flags = F.HasReturns } })),
				},
				{ "bad timeout", manual(oneService({ { name = "A", kind = K.Method, route = 1, ds = 9 } })) },
				{ "bad timeout", manual(oneService({ { name = "A", kind = K.Method, route = 1, ds = 1201 } })) },
				{ "bad backlog", manual(oneService({ { name = "A", kind = K.Signal, route = 1, backlog = 1025 } })) },
				{
					"bad backlog",
					manual(oneService({ { name = "A", kind = K.Signal, route = 1, backlog = C.BACKLOG_LATEST } })),
				},
				{ "bad rate limit", manual(oneService({ { name = "A", kind = K.Event, route = 1, rate = 0 } })) },
				{ "bad rate limit", manual(oneService({ { name = "A", kind = K.Event, route = 1, rate = -1 } })) },
				{ "bad rate limit", manual(oneService({ { name = "A", kind = K.Event, route = 1, rate = INF } })) },
				{ "bad rate limit", manual(oneService({ { name = "A", kind = K.Method, route = 1, burst = NAN } })) },
				{ "trailing bytes", manual(oneService({ signal("A", 1) }), nil, nil, true) },
			}
			for _, case in cases do
				local m, reason = decodeAll(case[2])
				expect(m).toBeNil()
				expect(reason).toBe(case[1])
			end
		end)

		it("malformed descriptors", function()
			local bad: { (any) -> () } = {
				function(w)
					w.u8(1).u8(0) -- op 0
				end,
				function(w)
					w.u8(1).u8(24) -- op past ANY
				end,
				function(w)
					w.u8(33)
					for _ = 1, 33 do
						w.u8(Op.BOOL)
					end
				end,
				function(w)
					w.u8(5).u8(Op.BOOL) -- count larger than the bytes left
				end,
				function(w)
					w.u8(1).u8(Op.STRUCT).u8(0) -- empty struct
				end,
				function(w)
					w.u8(1).u8(Op.STRUCT).u8(2).str8("b").u8(Op.BOOL).str8("a").u8(Op.BOOL) -- unsorted
				end,
				function(w)
					w.u8(1).u8(Op.STRUCT).u8(2).str8("a").u8(Op.BOOL).str8("a").u8(Op.BOOL) -- duplicate
				end,
				function(w)
					w.u8(1).u8(Op.STRUCT).u8(1).str8("").u8(Op.BOOL) -- empty field name
				end,
				function(w)
					w.u8(1).u8(Op.ENUM).u8(0) -- no names
				end,
				function(w)
					w.u8(1).u8(Op.ENUM).u8(2).str8("A").str8("A") -- duplicate names
				end,
				function(w)
					w.u8(1).u8(Op.ENUM).u8(1).str8("") -- empty name
				end,
				function(w)
					w.u8(1).u8(Op.STRING).u8(2).u32(10) -- unknown string flag
				end,
				function(w)
					w.u8(1).u8(Op.INSTANCE).str8("").u8(2) -- unknown Instance flag
				end,
				function(w)
					w.u8(1).u8(Op.ENUMITEM).str8("NotAnEnumQZ")
				end,
				function(w)
					w.u8(1).u8(Op.U8).f64(5).f64(1) -- lo > hi
				end,
				function(w)
					w.u8(1).u8(Op.U8).f64(0).f64(256) -- outside the type
				end,
				function(w)
					w.u8(1).u8(Op.I32).f64(1.5).f64(2) -- not an integer
				end,
				function(w)
					w.u8(1).u8(Op.F64).f64(NAN).f64(1)
				end,
				function(w)
					w.u8(1).u8(Op.F64).f64(0).f64(INF)
				end,
				function(w)
					w.u8(1).u8(Op.F32).f64(0).f64(1e39)
				end,
				function(w)
					w.u8(1).u8(Op.VECTOR3).f64(0)
				end,
				function(w)
					w.u8(1).u8(Op.VECTOR2).f64(NAN)
				end,
				function(w)
					w.u8(1).u8(Op.MAP).u32(5).u8(Op.VECTOR3).f64(INF).u8(Op.BOOL) -- bad key type
				end,
				function(w)
					w.u8(1).u8(Op.ARRAY).u32(5) -- element descriptor missing
				end,
				function(w)
					w.u8(1).u8(Op.U16).f64(0) -- truncated bounds
				end,
				nestedArgs(16), -- depth 17
			}
			for index, desc in bad do
				local m, reason = decodeAll(withArgs(desc))
				expect(m == nil and index or "decoded case " .. index).toBe(index)
				expect(reason).toBe("bad descriptor")
			end
		end)

		it("counts larger than the bytes left, before allocating", function()
			local services = Manifest.encode(model({}))
			buffer.writeu16(services, HEADER_BYTES, 65535)
			local m, reason = decodeAll(services)
			expect(m).toBeNil()
			expect(reason).toBe("truncated")
			local members = manual(oneService({}))
			buffer.writeu16(members, buffer.len(members) - 2, 65535)
			m, reason = decodeAll(members)
			expect(m).toBeNil()
			expect(reason).toBe("truncated")
		end)
	end)

	describe("decode accepts", function()
		it("the edges of every checked field", function()
			local decoded: any = decodeAll(manual(
				oneService({
					{ name = "A", kind = K.Method, route = 1, ds = 10 },
					{ name = "A", kind = K.Signal, route = 2, backlog = 1024 },
					{ name = "B", kind = K.Method, route = 65535, ds = 1200 },
					{ name = "C", kind = K.Signal, route = 3, flags = F.HasArgs, desc = nestedArgs(15) }, -- depth 16
				}),
				nil,
				1
			))
			expect(decoded).never.toBeNil()
			local members = decoded.services[1].members
			expect(members[1].timeout).toBe(1)
			expect(members[2].kind).toBe(K.Signal)
			expect(members[2].backlog).toBe(1024)
			expect(members[3].timeout).toBe(120)
			expect(Schema._test.descDepth(members[4].args[1])).toBe(16)
			expect(decoded.limits.mirror).toBe(1)
		end)
	end)

	describe("fuzz", function()
		it("every truncation of a valid manifest fails with a reason and never throws", function()
			for _, bytes in { Manifest.encode(fullModel(nil)), Manifest.encode(model({})) } do
				local len = buffer.len(bytes)
				local bad = {}
				for cut = 0, len - 1 do
					-- lim = cut on the whole buffer: a decoder that read past lim would succeed here
					local ok, m, reason = pcall(Manifest.decode, bytes, 0, cut)
					if not ok or m ~= nil or type(reason) ~= "string" then
						table.insert(bad, cut)
					end
				end
				expect(bad).toEqual({})
			end
		end, { timeout = 60 })

		it("never throws on 10,000 random buffers", function()
			local rng = Random.new(4242)
			local first: string? = nil
			local problems = 0
			for iter = 1, FUZZ_BUFFERS do
				local n = rng:NextInteger(0, 120)
				local b = buffer.create(n)
				for i = 0, n - 1 do
					buffer.writeu8(b, i, randomByte(rng))
				end
				if n > 0 and rng:NextNumber() < 0.9 then
					buffer.writeu8(b, 0, C.PROTO)
				end
				local problem = contractProblem(b, n)
				if problem then
					problems += 1
					first = first or (problem .. " on " .. hex(b, n))
				end
				if iter % 1000 == 0 then
					task.wait()
				end
			end
			expect(first).toBeNil()
			expect(problems).toBe(0)
		end, { timeout = 120 })

		it("never throws on 10,000 valid headers with random service data", function()
			local header = string.sub(buffer.tostring(Manifest.encode(model({}))), 1, HEADER_BYTES)
			local rng = Random.new(777)
			local first: string? = nil
			local problems = 0
			for iter = 1, FUZZ_BUFFERS do
				local tail = rng:NextInteger(0, 160)
				local b = buffer.create(HEADER_BYTES + tail)
				buffer.writestring(b, 0, header)
				for i = HEADER_BYTES, HEADER_BYTES + tail - 1 do
					buffer.writeu8(b, i, randomByte(rng))
				end
				local n = buffer.len(b)
				local problem = contractProblem(b, n)
				if problem then
					problems += 1
					first = first or (problem .. " on " .. hex(b, n))
				end
				if iter % 1000 == 0 then
					task.wait()
				end
			end
			expect(first).toBeNil()
			expect(problems).toBe(0)
		end, { timeout = 120 })

		it("never throws on 10,000 mutations of a full manifest", function()
			local valid = Manifest.encode(fullModel(nil))
			local len = buffer.len(valid)
			local rng = Random.new(99)
			local b = buffer.create(len)
			local first: string? = nil
			local problems = 0
			for iter = 1, FUZZ_BUFFERS do
				buffer.copy(b, 0, valid, 0, len)
				for _ = 1, rng:NextInteger(1, 3) do
					buffer.writeu8(b, rng:NextInteger(HEADER_BYTES, len - 1), randomByte(rng))
				end
				local lim = if rng:NextNumber() < 0.2 then rng:NextInteger(0, len) else len
				local problem = contractProblem(b, lim)
				if problem then
					problems += 1
					first = first or (problem .. " on " .. hex(b, lim))
				end
				if iter % 1000 == 0 then
					task.wait()
				end
			end
			expect(first).toBeNil()
			expect(problems).toBe(0)
		end, { timeout = 120 })
	end)

	describe("encode", function()
		it("raises on a malformed model (a server bug) instead of writing bytes clients reject", function()
			local over = table.create(33, T.u8)
			local cases: { { any } } = {
				{ "sorted", model({ { name = "b", members = {} }, { name = "a", members = {} } }) },
				{
					"sorted",
					model(oneService({
						member({ name = "B", kind = K.Signal, route = 1 }),
						member({ name = "A", kind = K.Signal, route = 2 }),
					})),
				},
				{
					"reuses route",
					model(oneService({
						member({ name = "A", kind = K.Signal, route = 5 }),
						member({ name = "B", kind = K.Signal, route = 5 }),
					})),
				},
				{ "route", model(oneService({ member({ name = "A", kind = K.Signal, route = 0 }) })) },
				{ "route", model(oneService({ member({ name = "A", kind = K.Signal, route = 65536 }) })) },
				{ "rate", model(oneService({ member({ name = "A", kind = K.Event, route = 1, rate = 0 }) })) },
				{ "burst", model(oneService({ member({ name = "A", kind = K.Method, route = 1, burst = INF }) })) },
				{ "rate", model(oneService({ member({ name = "A", kind = K.Event, route = 1, rate = 1e-50 }) })) },
				{ "timeout", model(oneService({ member({ name = "A", kind = K.Method, route = 1, timeout = 0.5 }) })) },
				{ "timeout", model(oneService({ member({ name = "A", kind = K.Method, route = 1, timeout = NAN }) })) },
				{
					"backlog",
					model(oneService({ member({ name = "A", kind = K.Signal, route = 1, backlog = 2000 }) })),
				},
				{
					"Returns but is not a Method",
					model(oneService({ member({ name = "A", kind = K.Event, route = 1, returns = { T.u8 } }) })),
				},
				{
					"at most 32",
					model(oneService({ member({ name = "A", kind = K.Method, route = 1, args = over }) })),
				},
				{
					"is not a Loren.T type",
					model(oneService({ member({ name = "A", kind = K.Signal, route = 1, args = { 5 } }) })),
				},
				{
					"255 bytes",
					model(oneService({ member({ name = string.rep("x", 256), kind = K.Signal, route = 1 }) })),
				},
				{ "unknown kind", model(oneService({ member({ name = "A", kind = 4, route = 1 }) })) },
				{ "flags", model(oneService({ member({ name = "A", kind = K.Signal, route = 1, flags = 0x80 }) })) },
				{ "limits.mirror", model({}, 1.5) },
				{ "limits.mirror", model({}, 0) },
				{ "no name", model({ { name = "", members = {} } }) },
			}
			for _, case in cases do
				local ok, err = pcall(Manifest.encode, case[2])
				expect(ok).toBe(false)
				expect(tostring(err)).toContain(C.PREFIX .. "Manifest.encode: ")
				expect(tostring(err)).toContain(case[1])
			end
		end)
	end)
end
