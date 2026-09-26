--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local C = require(ReplicatedStorage.LorenRuntime.Constants)
local Codec = require(ReplicatedStorage.LorenRuntime.Codec)
local Types = require(ReplicatedStorage.LorenRuntime.Types)

type Writer = Types.Writer
type ReadCtx = Types.ReadCtx

local D = C.Decode
local E = C.Encode
local Tag = C.Tag
local NODE_CHARGE = C.Limit.NODE_CHARGE

local NAN = 0 / 0
local INF = math.huge
local NEG_ZERO = 1 / -math.huge
local Lighting = game:GetService("Lighting")

-- [[ Helpers ]]

-- Heterogeneous tables are built from varargs so the type checker does not unify literal elements.
local function list(...: any): { any }
	return { ... }
end

-- kv(k1, v1, k2, v2, ...) -> { [k1] = v1, [k2] = v2, ... }
local function kv(...: any): { [any]: any }
	local t: { [any]: any } = {}
	for i = 1, select("#", ...), 2 do
		local k, v = select(i, ...)
		t[k] = v
	end
	return t
end

local function pack(...: any): { n: number, [number]: any }
	return table.pack(...)
end

local function hex(b: buffer, n: number?): string
	local len = n or buffer.len(b)
	local parts = table.create(len)
	for i = 0, len - 1 do
		parts[i + 1] = string.format("%02X", buffer.readu8(b, i))
	end
	return table.concat(parts, " ")
end

local function whex(w: Writer): string
	return hex(w.buf, w.n)
end

local function unhex(s: string): buffer
	local bytes = {}
	for h in string.gmatch(s, "%x%x") do
		table.insert(bytes, tonumber(h, 16) :: number)
	end
	local b = buffer.create(#bytes)
	for i, v in bytes do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

-- Exact-size copy of what a writer holds.
local function bytesOf(w: Writer): buffer
	local b = buffer.create(w.n)
	buffer.copy(b, 0, w.buf, 0, w.n)
	return b
end

local function isNegZero(x: any): boolean
	return type(x) == "number" and x == 0 and 1 / x < 0
end

local function finite(x: number): boolean
	return x >= -C.Limit.F64_MAX and x <= C.Limit.F64_MAX
end

-- levels tables around leaf: nest(1, 1) = { 1 } (the leaf is at depth `levels`)
local function nest(levels: number, leaf: any): any
	local v = leaf
	for _ = 1, levels do
		v = { v }
	end
	return v
end

-- Deep equality: NaN equals NaN, buffers compare by content (-0 is checked separately).
local function same(a: any, b: any): boolean
	if a == b then
		return true
	end
	local ta, tb = typeof(a), typeof(b)
	if ta ~= tb then
		return false
	elseif ta == "number" then
		return a ~= a and b ~= b
	elseif ta == "buffer" then
		return buffer.tostring(a) == buffer.tostring(b)
	elseif ta ~= "table" then
		return false
	end
	for k, v in a do
		if not same(v, rawget(b, k)) then
			return false
		end
	end
	for k in b do
		if rawget(a, k) == nil then
			return false
		end
	end
	return true
end

type Decoded = { n: number, o: number, err: number, errArg: number, argv: { any }, ctx: ReadCtx }

local function decodeArgs(
	b: buffer,
	hostile: boolean,
	refs: { any }?,
	nrefs: number,
	allow: boolean?,
	max: number?,
	lim: number?
): Decoded
	local ctx = Codec.newReadCtx(hostile, hostile)
	Codec.beginFrame(ctx, refs, if hostile then nrefs else 0)
	Codec.beginMessage(ctx, allow == true)
	local argv: { any } = {}
	local n, o = Codec.readArgs(b, 0, lim or buffer.len(b), ctx, argv, max or 255)
	return { n = n, o = o, err = ctx.err, errArg = ctx.errArg, argv = argv, ctx = ctx }
end

-- Decodes what w holds with the rules of its direction (C->S writers are read with server rules).
local function decodeWriter(w: Writer, allow: boolean?, max: number?): Decoded
	return decodeArgs(bytesOf(w), w.indexedRefs, if w.nrefs > 0 then w.refs else nil, w.nrefs, allow, max)
end

local function encodeArgs(indexed: boolean, ...: any): (Writer, number)
	local w = Codec.newWriter(64, indexed)
	local st = Codec.writeArgs(w, 255, select("#", ...), ...)
	return w, st
end

local function encodeValue(indexed: boolean, v: any): (Writer, number)
	local w = Codec.newWriter(16, indexed)
	local st = Codec.writeValue(w, v, 0)
	return w, st
end

local function walk(refs: { any }, nrefs: number): (number, number, ReadCtx)
	local ctx = Codec.newReadCtx(true, true)
	Codec.beginFrame(ctx, refs, nrefs)
	local st, cost = Codec.walkSidecar(refs, nrefs, ctx)
	return st, cost, ctx
end

-- [[ Random inputs ]]

local INTERESTING = {
	0x00,
	0x01,
	0x02,
	0x03,
	0x04,
	0x05,
	0x06,
	0x07,
	0x08,
	0x09,
	0x0A,
	0x0B,
	0x0C,
	0x0D,
	0x0E,
	0x0F,
	0x10,
	0x11,
	0x12,
	0x13,
	0x14,
	0x7F,
	0x80,
	0x81,
	0xDF,
	0xE0,
	0xEE,
	0xEF,
	0xF0,
	0xFF,
}

-- Biased toward tags, small counts and varint continuation bytes, so decoding gets past the first byte.
local function randomBuffer(rng: Random, maxLen: number): buffer
	local len = rng:NextInteger(0, maxLen)
	local b = buffer.create(len)
	for i = 0, len - 1 do
		local byte
		if i == 0 and rng:NextNumber() < 0.7 then
			byte = rng:NextInteger(0, 4)
		elseif rng:NextNumber() < 0.6 then
			byte = INTERESTING[rng:NextInteger(1, #INTERESTING)]
		else
			byte = rng:NextInteger(0, 255)
		end
		buffer.writeu8(b, i, byte)
	end
	return b
end

local function randomString(rng: Random, maxLen: number): string
	local len = rng:NextInteger(0, maxLen)
	local chars = table.create(len)
	for i = 1, len do
		chars[i] = string.char(rng:NextInteger(0, 255))
	end
	return table.concat(chars)
end

-- Encodable values. sidecar = inside a table that goes through the sidecar (no buffers: C->S rule).
local function randomValue(rng: Random, depth: number, sidecar: boolean): any
	local pick = rng:NextInteger(1, if depth >= 4 then 9 else 12)
	if pick == 1 then
		return rng:NextInteger(0, 127)
	elseif pick == 2 then
		return rng:NextInteger(-4294967296, 4294967296)
	elseif pick == 3 then
		return (rng:NextNumber() - 0.5) * 10 ^ rng:NextInteger(-20, 300)
	elseif pick == 4 then
		return randomString(rng, 24)
	elseif pick == 5 then
		return rng:NextNumber() < 0.5
	elseif pick == 6 then
		return Vector3.new(rng:NextNumber() * 1000 - 500, rng:NextInteger(-5, 5), rng:NextNumber())
	elseif pick == 7 then
		return Vector2.new(rng:NextNumber(), -rng:NextNumber() * 1e6)
	elseif pick == 8 then
		return Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber())
	elseif pick == 9 then
		if sidecar then
			return randomString(rng, 8)
		end
		local b = buffer.create(rng:NextInteger(0, 16))
		for i = 0, buffer.len(b) - 1 do
			buffer.writeu8(b, i, rng:NextInteger(0, 255))
		end
		return b
	elseif pick == 10 then
		local n = rng:NextInteger(0, 5)
		local arr = table.create(n)
		for i = 1, n do
			arr[i] = randomValue(rng, depth + 1, sidecar)
		end
		return arr
	elseif pick == 11 then
		local map = {}
		for _ = 1, rng:NextInteger(1, 4) do
			map[randomString(rng, 6)] = randomValue(rng, depth + 1, sidecar)
		end
		return map
	end
	-- a boolean key: always the sidecar
	return kv(1, randomValue(rng, depth + 1, true), true, randomValue(rng, depth + 1, true), "k", workspace)
end

-- Anything a hostile remote table could hold (and more).
local function randomJunk(rng: Random, depth: number): any
	local pick = rng:NextInteger(1, if depth >= 20 then 12 else 14)
	if pick == 1 then
		return NAN
	elseif pick == 2 then
		return (rng:NextNumber() - 0.5) * INF
	elseif pick == 3 then
		return randomString(rng, 10)
	elseif pick == 4 then
		return rng:NextNumber() < 0.5
	elseif pick == 5 then
		return buffer.create(2)
	elseif pick == 6 then
		return function() end
	elseif pick == 7 then
		return coroutine.create(function() end)
	elseif pick == 8 then
		return Vector3.new(NAN, 1, 2)
	elseif pick == 9 then
		return CFrame.new(rng:NextNumber(), NAN, 0)
	elseif pick == 10 then
		return workspace
	elseif pick == 11 then
		return Enum.Material.Plastic
	elseif pick == 12 then
		return rng:NextInteger(-5, 5)
	end
	local t: { [any]: any } = {}
	for _ = 1, rng:NextInteger(0, 6) do
		local kp = rng:NextInteger(1, 6)
		local key: any = if kp == 1
			then randomString(rng, 4)
			elseif kp == 2 then rng:NextInteger(1, 10)
			elseif kp == 3 then rng:NextNumber() < 0.5
			elseif kp == 4 then workspace
			elseif kp == 5 then INF
			else {}
		t[key] = randomJunk(rng, depth + 1)
	end
	return t
end

-- [[ Datatypes checked by walkSidecar ]]

-- Sum of the components: non-finite iff one of them is (NaN and inf propagate; inf - inf is NaN).
local function sum(...: number): number
	local s = 0
	for i = 1, select("#", ...) do
		s += (select(i, ...))
	end
	return s
end

local function sumV3(v: Vector3): number
	return v.X + v.Y + v.Z
end

local function sumCFrame(v: CFrame): number
	return sum(v:GetComponents())
end

type DatatypeCase = {
	name: string,
	make: () -> any, -- a value with one non-finite component (the engine may refuse or sanitize it)
	probe: (any) -> number,
	finite: () -> any,
}

local DATATYPES: { DatatypeCase } = {
	{
		name = "Vector3",
		make = function()
			return Vector3.new(NAN, 0, 0)
		end,
		probe = function(v)
			return sumV3(v)
		end,
		finite = function()
			return Vector3.new(1, 2, 3)
		end,
	},
	{
		name = "Vector2",
		make = function()
			return Vector2.new(0, INF)
		end,
		probe = function(v)
			return v.X + v.Y
		end,
		finite = function()
			return Vector2.new(1, 2)
		end,
	},
	{
		name = "CFrame",
		make = function()
			return CFrame.new(NAN, 0, 0)
		end,
		probe = function(v)
			return sumCFrame(v)
		end,
		finite = function()
			return CFrame.new(1, 2, 3)
		end,
	},
	{
		name = "CFrame rotation",
		make = function()
			return CFrame.new(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, NAN)
		end,
		probe = function(v)
			return sumCFrame(v)
		end,
		finite = function()
			return CFrame.Angles(1, 2, 3)
		end,
	},
	{
		name = "Color3",
		make = function()
			return Color3.new(0, NAN, 0)
		end,
		probe = function(v)
			return v.R + v.G + v.B
		end,
		finite = function()
			return Color3.new(0.1, 0.2, 0.3)
		end,
	},
	{
		name = "UDim",
		make = function()
			return UDim.new(NAN, 5)
		end,
		probe = function(v)
			return v.Scale + v.Offset
		end,
		finite = function()
			return UDim.new(0.5, 5)
		end,
	},
	{
		name = "UDim2",
		make = function()
			return UDim2.new(0, 1, INF, 2)
		end,
		probe = function(v)
			return v.X.Scale + v.X.Offset + v.Y.Scale + v.Y.Offset
		end,
		finite = function()
			return UDim2.new(0.5, 1, 0.25, 2)
		end,
	},
	{
		name = "Rect",
		make = function()
			return Rect.new(0, 0, INF, 1)
		end,
		probe = function(v)
			return v.Min.X + v.Min.Y + v.Max.X + v.Max.Y
		end,
		finite = function()
			return Rect.new(0, 0, 1, 1)
		end,
	},
	{
		name = "NumberRange",
		make = function()
			return NumberRange.new(0, INF)
		end,
		probe = function(v)
			return v.Min + v.Max
		end,
		finite = function()
			return NumberRange.new(1, 2)
		end,
	},
	{
		name = "Ray",
		make = function()
			return Ray.new(Vector3.zero, Vector3.new(0, NAN, 0))
		end,
		probe = function(v)
			return sumV3(v.Origin) + sumV3(v.Direction)
		end,
		finite = function()
			return Ray.new(Vector3.zero, Vector3.one)
		end,
	},
	{
		name = "Region3",
		make = function()
			return Region3.new(Vector3.zero, Vector3.new(INF, 1, 1))
		end,
		probe = function(v)
			return sumCFrame(v.CFrame) + sumV3(v.Size)
		end,
		finite = function()
			return Region3.new(Vector3.zero, Vector3.one)
		end,
	},
	{
		name = "NumberSequence",
		make = function()
			return NumberSequence.new(NAN)
		end,
		probe = function(v)
			local s = 0
			for _, kp in v.Keypoints do
				s += kp.Time + kp.Value + kp.Envelope
			end
			return s
		end,
		finite = function()
			return NumberSequence.new(0.5)
		end,
	},
	{
		name = "ColorSequence",
		make = function()
			return ColorSequence.new(Color3.new(NAN, 0, 0))
		end,
		probe = function(v)
			local s = 0
			for _, kp in v.Keypoints do
				s += kp.Time + kp.Value.R + kp.Value.G + kp.Value.B
			end
			return s
		end,
		finite = function()
			return ColorSequence.new(Color3.new(1, 0, 0))
		end,
	},
	{
		name = "PhysicalProperties",
		make = function()
			return PhysicalProperties.new(NAN, 0.3, 0.5)
		end,
		probe = function(v)
			return v.Density + v.Friction + v.Elasticity + v.FrictionWeight + v.ElasticityWeight
		end,
		finite = function()
			return PhysicalProperties.new(1, 0.3, 0.5)
		end,
	},
}

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("module", function()
		it("is frozen and exports the contract API", function()
			expect(table.isfrozen(Codec)).toBe(true)
			local names = {
				"newWriter",
				"resetWriter",
				"reserve",
				"writeU8",
				"writeU16",
				"writeU32",
				"writeI32",
				"writeF32",
				"writeF64",
				"writeBytes",
				"writeString",
				"writeVarint",
				"varintSize",
				"readVarint",
				"writeHead",
				"headSize",
				"readHead",
				"addRef",
				"writeValue",
				"writeArgs",
				"readValue",
				"readArgs",
				"copyTable",
				"walkSidecar",
				"newReadCtx",
				"beginFrame",
				"beginMessage",
			}
			local missing = {}
			for _, name in names do
				if type((Codec :: any)[name]) ~= "function" then
					table.insert(missing, name)
				end
			end
			expect(table.concat(missing, ", ")).toBe("")
		end)

		it("leaves its scratch empty", function()
			Codec._reset()
			expect(Codec._test.visitingCount()).toBe(0)
			expect(Codec._test.walkStackCount()).toBe(0)
		end)
	end)

	describe("Writer", function()
		it("newWriter starts empty with every contract field", function()
			local w = Codec.newWriter(8, true)
			expect(w.cap >= 8).toBe(true)
			expect(buffer.len(w.buf)).toBe(w.cap)
			expect(w.n).toBe(0)
			expect(w.nrefs).toBe(0)
			expect(w.refBase).toBe(0)
			expect(w.indexedRefs).toBe(true)
			expect(w.inlineTables).toBe(true)
			expect(w.unreliable).toBe(false)
			expect(w.nodes).toBe(0)
			expect(w.sideBytes).toBe(0)
			expect(w.inlineNodes).toBe(0)
			expect(w.lossy).toBe(0)
			expect(w.errArg).toBe(0)
			expect(Codec.newWriter(64, false).indexedRefs).toBe(false)
		end)

		it("reserve grows by doubling and keeps the bytes already written", function()
			local w = Codec.newWriter(16, false)
			for i = 0, 99 do
				Codec.writeU8(w, i)
			end
			expect(w.n).toBe(100)
			expect(w.cap).toBe(128)
			expect(buffer.len(w.buf)).toBe(128)
			local wrong = 0
			for i = 0, 99 do
				if buffer.readu8(w.buf, i) ~= i then
					wrong += 1
				end
			end
			expect(wrong).toBe(0)
			local o = Codec.reserve(w, 1000)
			expect(o).toBe(100)
			expect(w.n).toBe(1100)
			expect(w.cap).toBe(2048)
			expect(buffer.readu8(w.buf, 99)).toBe(99)
		end)

		it("fixed-width writers are little-endian", function()
			local w = Codec.newWriter(16, false)
			Codec.writeU8(w, 0xAB)
			Codec.writeU16(w, 0x1234)
			Codec.writeU32(w, 0xDEADBEEF)
			Codec.writeI32(w, -2)
			Codec.writeF32(w, 1.5)
			Codec.writeF64(w, -2)
			expect(whex(w)).toBe("AB 34 12 EF BE AD DE FE FF FF FF 00 00 C0 3F 00 00 00 00 00 00 00 C0")
		end)

		it("writeString and writeBytes copy raw bytes without a prefix", function()
			local w = Codec.newWriter(16, false)
			Codec.writeString(w, "hi")
			Codec.writeBytes(w, unhex("01 02 03 04"), 1, 2)
			Codec.writeString(w, "")
			expect(whex(w)).toBe("68 69 02 03")
		end)

		it("addRef appends to the sidecar; C->S also writes the frame index (refBase)", function()
			local w = Codec.newWriter(16, true)
			w.refBase = 5
			Codec.addRef(w, workspace)
			expect(whex(w)).toBe("05")
			expect(w.nrefs).toBe(1)
			expect(w.nodes).toBe(1)
			expect(w.refs[1]).toBe(workspace)
			w.refBase = 200
			Codec.addRef(w, Lighting)
			expect(whex(w)).toBe("05 C9 01") -- 201 = 0xC9 as LEB128: C9 01
			local s = Codec.newWriter(16, false)
			Codec.addRef(s, workspace)
			expect(s.n).toBe(0)
			expect(s.nrefs).toBe(1)
		end)

		it("resetWriter clears per-message state and keeps the owner's flags", function()
			local w = Codec.newWriter(16, true)
			w.inlineTables = false
			w.refBase = 3
			Codec.addRef(w, workspace)
			w.lossy = 2
			w.errArg = 4
			w.sideBytes = 5
			w.inlineNodes = 6
			Codec.resetWriter(w)
			expect(w.n).toBe(0)
			expect(w.nrefs).toBe(0)
			expect(w.refs[1]).toBeNil()
			expect(w.refBase).toBe(0)
			expect(w.nodes).toBe(0)
			expect(w.sideBytes).toBe(0)
			expect(w.inlineNodes).toBe(0)
			expect(w.lossy).toBe(0)
			expect(w.errArg).toBe(0)
			expect(w.inlineTables).toBe(false)
			expect(w.indexedRefs).toBe(true)
		end)
	end)

	describe("varint", function()
		local cases: { { any } } = {
			{ 0, "00" },
			{ 1, "01" },
			{ 127, "7F" },
			{ 128, "80 01" },
			{ 300, "AC 02" },
			{ 16383, "FF 7F" },
			{ 16384, "80 80 01" },
			{ 2097151, "FF FF 7F" },
		}

		it("writes the minimal 1/2/3-byte form and reads it back", function()
			for _, case in cases do
				local v, bytes = case[1] :: number, case[2] :: string
				local w = Codec.newWriter(16, false)
				Codec.writeVarint(w, v)
				expect(whex(w)).toBe(bytes)
				expect(Codec.varintSize(v)).toBe(w.n)
				local got, o = Codec.readVarint(w.buf, 0, w.n)
				expect(got).toBe(v)
				expect(o).toBe(w.n)
			end
		end)

		it("reads at an offset and stops at lim", function()
			local b = unhex("FF 80 01 05")
			local v, o = Codec.readVarint(b, 1, 4)
			expect(v).toBe(128)
			expect(o).toBe(3)
			local v2, o2 = Codec.readVarint(b, 1, 2) -- continuation byte, then lim
			expect(v2).toBe(-1)
			expect(o2).toBe(1)
			local v3, o3 = Codec.readVarint(b, 4, 4)
			expect(v3).toBe(-1)
			expect(o3).toBe(4)
		end)

		it("accepts non-minimal forms", function()
			local v, o = Codec.readVarint(unhex("80 00"), 0, 2)
			expect(v).toBe(0)
			expect(o).toBe(2)
			v, o = Codec.readVarint(unhex("FF 80 00"), 0, 3)
			expect(v).toBe(127)
			expect(o).toBe(3)
		end)

		it("rejects a third byte with 0x80 set and truncated input with (-1, o)", function()
			for _, h in { "80 80 80 01", "FF FF FF", "80", "80 80", "" } do
				local b = unhex(h)
				local v, o = Codec.readVarint(b, 0, buffer.len(b))
				expect(v).toBe(-1)
				expect(o).toBe(0)
			end
		end)
	end)

	describe("route head", function()
		it("writes 1/2/3-byte heads at the boundaries", function()
			local cases: { { any } } = {
				{ 1, "01" },
				{ 223, "DF" },
				{ 224, "E0 00" },
				{ 225, "E0 01" },
				{ 479, "E0 FF" },
				{ 480, "E1 00" },
				{ 4063, "EE FF" },
				{ 4064, "EF E0 0F" },
				{ 65535, "EF FF FF" },
			}
			for _, case in cases do
				local route, bytes = case[1] :: number, case[2] :: string
				local w = Codec.newWriter(16, false)
				Codec.writeHead(w, route)
				expect(whex(w)).toBe(bytes)
				expect(Codec.headSize(route)).toBe(w.n)
			end
		end)

		it("round-trips every route 1..65535", function()
			local w = Codec.newWriter(16, false)
			local bad = 0
			local first = ""
			for route = 1, 65535 do
				Codec.resetWriter(w)
				Codec.writeHead(w, route)
				local h, o = Codec.readHead(w.buf, 0, w.n)
				if h ~= route or o ~= w.n or o ~= Codec.headSize(route) then
					bad += 1
					if first == "" then
						first = string.format("route %d -> %d at %d", route, h, o)
					end
				end
			end
			expect(first).toBe("")
			expect(bad).toBe(0)
		end)

		it("returns 0 for 0x00, 0xEF 0000 and truncated heads; accepts a non-minimal 0xEF head", function()
			for _, h in { "00", "EF 00 00", "E0", "EE", "EF 01", "EF", "" } do
				local b = unhex(h)
				local r, o = Codec.readHead(b, 0, buffer.len(b))
				expect(r).toBe(0)
				expect(o).toBe(0)
			end
			local r, o = Codec.readHead(unhex("EF 05 00"), 0, 3)
			expect(r).toBe(5)
			expect(o).toBe(3)
			-- lim is respected even when the buffer is longer
			local r2, o2 = Codec.readHead(unhex("E0 05"), 0, 1)
			expect(r2).toBe(0)
			expect(o2).toBe(0)
		end)

		it("returns -op for the control bytes 0xF0..0xFF", function()
			local bad = 0
			for op = 0xF0, 0xFF do
				local b = buffer.create(1)
				buffer.writeu8(b, 0, op)
				local r, o = Codec.readHead(b, 0, 1)
				if r ~= -op or o ~= 1 then
					bad += 1
				end
			end
			expect(bad).toBe(0)
		end)
	end)

	describe("untyped encoding (byte-exact)", function()
		local f = function() end
		local cases: { { any } } = {
			{ "nil", nil, "00" },
			{ "false", false, "01" },
			{ "true", true, "02" },
			{ "0", 0, "80" },
			{ "5", 5, "85" },
			{ "127", 127, "FF" },
			{ "128", 128, "03 80" },
			{ "255", 255, "03 FF" },
			{ "256", 256, "04 00 01" },
			{ "65535", 65535, "04 FF FF" },
			{ "65536", 65536, "05 00 00 01 00" },
			{ "4294967295", 4294967295, "05 FF FF FF FF" },
			{ "-1", -1, "06 01" },
			{ "-255", -255, "06 FF" },
			{ "-256", -256, "07 00 01" },
			{ "-65535", -65535, "07 FF FF" },
			{ "-65536", -65536, "08 00 00 01 00" },
			{ "-4294967295", -4294967295, "08 FF FF FF FF" },
			{ "2^32", 4294967296, "09 00 00 00 00 00 00 F0 41" },
			{ "-2^32", -4294967296, "09 00 00 00 00 00 00 F0 C1" },
			{ "0.5", 0.5, "09 00 00 00 00 00 00 E0 3F" },
			{ "-0", NEG_ZERO, "09 00 00 00 00 00 00 00 80" },
			{ "inf", INF, "09 00 00 00 00 00 00 F0 7F" },
			{ "-inf", -INF, "09 00 00 00 00 00 00 F0 FF" },
			{ "empty string", "", "0B 00" },
			{ "string", "ab", "0B 02 61 62" },
			{ "buffer", unhex("01 02"), "0C 02 01 02" },
			{ "Vector3", Vector3.new(1, 2, 3), "0D 00 00 80 3F 00 00 00 40 00 00 40 40" },
			{ "Vector2", Vector2.new(1, 2), "0E 00 00 80 3F 00 00 00 40" },
			{ "Color3", Color3.new(1, 0, 0.5), "0F 00 00 80 3F 00 00 00 00 00 00 00 3F" },
			{ "empty table", {}, "10 00" },
			{ "array", { 1, 2 }, "10 02 81 82" },
			{ "frozen array", table.freeze({ 1, 2 }), "10 02 81 82" },
			{ "nested array", { {} }, "10 01 10 00" },
			{ "string map", { a = 1 }, "11 01 0B 01 61 81" },
			{ "function (lossy)", f, "00" },
		}

		it("writes each tag exactly as §4.5 specifies", function()
			expect(isNegZero(NEG_ZERO)).toBe(true)
			local problems = {}
			for _, case in cases do
				for _, indexed in { false, true } do
					local w, st = encodeValue(indexed, case[2])
					if st ~= 0 or whex(w) ~= case[3] then
						table.insert(
							problems,
							string.format(
								"%s (indexed=%s): status %d, bytes %s",
								case[1],
								tostring(indexed),
								st,
								whex(w)
							)
						)
					end
				end
			end
			expect(table.concat(problems, "\n")).toBe("")
		end)

		it("writes NaN as F64", function()
			local w, st = encodeValue(false, NAN)
			expect(st).toBe(0)
			expect(w.n).toBe(9)
			expect(buffer.readu8(w.buf, 0)).toBe(Tag.F64)
			local v = buffer.readf64(w.buf, 1)
			expect(v ~= v).toBe(true)
		end)

		it("writes the §4.12 example Shop:Buy(7, 2) as 02 87 82", function()
			local w, st = encodeArgs(true, 7, 2)
			expect(st).toBe(0)
			expect(whex(w)).toBe("02 87 82")
		end)

		it("writes REF with no index S->C and a varint index C->S", function()
			local s = encodeValue(false, workspace)
			expect(whex(s)).toBe("12")
			expect(s.refs[1]).toBe(workspace)
			local c = encodeValue(true, workspace)
			expect(whex(c)).toBe("12 00")
			local w = Codec.newWriter(16, true)
			w.refBase = 3
			expect(Codec.writeValue(w, workspace, 0)).toBe(0)
			expect(whex(w)).toBe("12 03")
		end)
	end)

	describe("untyped round trip", function()
		local values: { any } = {
			true,
			false,
			0,
			1,
			127,
			128,
			255,
			256,
			65535,
			65536,
			4294967295,
			4294967296,
			-1,
			-127,
			-128,
			-255,
			-256,
			-65535,
			-65536,
			-4294967295,
			-4294967296,
			0.5,
			-0.5,
			0.1,
			1 / 3,
			math.pi,
			2 ^ 53,
			-(2 ^ 53),
			1e300,
			-1e-300,
			5e-324,
			-5e-324,
			C.Limit.F64_MAX,
			"",
			"a",
			string.rep("x", 127),
			string.rep("y", 128),
			string.rep("z", 16384),
			"\0\255 bytes",
			buffer.create(0),
			unhex("00 FF 10"),
			Vector3.new(0.1, -2.5, 1e10),
			Vector3.zero,
			Vector2.new(-0.25, 3e5),
			Color3.new(0.1, 0.2, 0.3),
			{},
			{ 1, 2, 3 },
			list("a", { true, false }, { x = 1 }),
			{ a = 1, b = "two", c = { 3 } },
			nest(16, "leaf"),
		}

		it("decodes every value to itself, S->C (client rules) and C->S (server rules)", function()
			local problems = {}
			for i, v in values do
				for _, indexed in { false, true } do
					local w, st = encodeArgs(indexed, v)
					if st ~= 0 then
						table.insert(
							problems,
							string.format("#%d indexed=%s: encode status %d", i, tostring(indexed), st)
						)
						continue
					end
					local r = decodeWriter(w)
					if r.err ~= 0 or r.n ~= 1 or r.o ~= w.n or not same(r.argv[1], v) then
						table.insert(
							problems,
							string.format(
								"#%d indexed=%s: err %d n %d o %d/%d",
								i,
								tostring(indexed),
								r.err,
								r.n,
								r.o,
								w.n
							)
						)
					end
				end
			end
			expect(table.concat(problems, "\n")).toBe("")
		end)

		it("keeps -0 in both directions", function()
			for _, indexed in { false, true } do
				local w = encodeArgs(indexed, NEG_ZERO)
				expect(whex(w)).toBe("01 09 00 00 00 00 00 00 00 80")
				local r = decodeWriter(w)
				expect(r.err).toBe(0)
				expect(isNegZero(r.argv[1])).toBe(true)
			end
		end)

		it("carries NaN and infinities S->C", function()
			local w = encodeArgs(false, NAN, INF, -INF)
			local r = decodeWriter(w)
			expect(r.err).toBe(0)
			expect(r.n).toBe(3)
			expect(r.argv[1] ~= r.argv[1]).toBe(true)
			expect(r.argv[2]).toBe(INF)
			expect(r.argv[3]).toBe(-INF)
		end)

		it("keeps nil holes (argc counts every argument)", function()
			for _, indexed in { false, true } do
				local w, st = encodeArgs(indexed, nil, 1, nil, "x", nil)
				expect(st).toBe(0)
				expect(whex(w)).toBe("05 00 81 00 0B 01 78 00")
				local r = decodeWriter(w)
				expect(r.err).toBe(0)
				expect(r.n).toBe(5)
				expect(r.argv[1]).toBeNil()
				expect(r.argv[2]).toBe(1)
				expect(r.argv[3]).toBeNil()
				expect(r.argv[4]).toBe("x")
				expect(r.argv[5]).toBeNil()
			end
			local w0 = encodeArgs(false)
			expect(whex(w0)).toBe("00")
			local r0 = decodeWriter(w0)
			expect(r0.err).toBe(0)
			expect(r0.n).toBe(0)
			expect(r0.o).toBe(1)
		end)

		it("keeps f64, Vector3, Vector2 and Color3 values exact", function()
			local exact = { 0.1, 1 / 3, 5e-324, -1e-300, 2 ^ 53 + 2 }
			for _, v in exact do
				local r = decodeWriter((encodeArgs(true, v)))
				expect(r.argv[1] == v).toBe(true)
			end
			local v3 = Vector3.new(0.1, -2.5, 1e10)
			local v2 = Vector2.new(1 / 3, -7.125)
			local c3 = Color3.new(0.1, 0.2, 0.3)
			local r = decodeWriter((encodeArgs(false, v3, v2, c3)))
			expect(r.argv[1] == v3).toBe(true)
			expect(r.argv[2] == v2).toBe(true)
			expect(r.argv[3] == c3).toBe(true)
			expect(typeof(r.argv[1])).toBe("Vector3")
			expect(typeof(r.argv[2])).toBe("Vector2")
			expect(typeof(r.argv[3])).toBe("Color3")
		end)

		it("switches to u32 lengths above 2097151 bytes (STR32, BUF32)", function()
			local ctx = Codec.newReadCtx(false, false)
			local s1 = string.rep("a", 2097151)
			local w1 = encodeValue(false, s1)
			expect(hex(w1.buf, 4)).toBe("0B FF FF 7F")
			expect(w1.n).toBe(4 + 2097151)
			local v1, o1 = Codec.readValue(w1.buf, 0, w1.n, ctx, 0)
			expect(v1 == s1).toBe(true)
			expect(o1).toBe(w1.n)

			local s2 = s1 .. "b"
			local w2 = encodeValue(false, s2)
			expect(hex(w2.buf, 5)).toBe("0A 00 00 20 00")
			local v2, o2 = Codec.readValue(w2.buf, 0, w2.n, ctx, 0)
			expect(v2 == s2).toBe(true)
			expect(o2).toBe(w2.n)

			local big = buffer.create(2097152)
			buffer.writeu8(big, 2097151, 7)
			local w3 = encodeValue(false, big)
			expect(hex(w3.buf, 5)).toBe("13 00 00 20 00")
			local v3 = Codec.readValue(w3.buf, 0, w3.n, ctx, 0)
			expect(buffer.len(v3)).toBe(2097152)
			expect(buffer.readu8(v3, 2097151)).toBe(7)

			-- a short STR32 (non-minimal) is accepted
			local v4 = Codec.readValue(unhex("0A 01 00 00 00 61"), 0, 6, ctx, 0)
			expect(v4).toBe("a")
		end)

		it("sends Instances and other datatypes through sequential refs S->C", function()
			local cf = CFrame.new(1, 2, 3)
			local w, st = encodeArgs(false, workspace, cf, Enum.Material.Plastic, 5, { 1, workspace })
			expect(st).toBe(0)
			expect(whex(w)).toBe("05 12 12 12 85 10 02 81 12")
			expect(w.nrefs).toBe(4)
			local r = decodeWriter(w)
			expect(r.err).toBe(0)
			expect(r.argv[1]).toBe(workspace)
			expect(r.argv[2]).toBe(cf)
			expect(r.argv[3]).toBe(Enum.Material.Plastic)
			expect(r.argv[4]).toBe(5)
			expect(r.argv[5][2]).toBe(workspace)
			expect(r.ctx.cursor).toBe(4)
		end)

		it("writes frame-absolute ref indexes C->S", function()
			local w = Codec.newWriter(64, true)
			w.refBase = 2
			expect(Codec.writeArgs(w, 20, 3, workspace, 7, { Lighting })).toBe(0)
			expect(whex(w)).toBe("03 12 02 87 10 01 12 03")
			local frameRefs: { any } = { false, false }
			table.move(w.refs, 1, w.nrefs, 3, frameRefs)
			local r = decodeArgs(bytesOf(w), true, frameRefs, 4)
			expect(r.err).toBe(0)
			expect(r.argv[1]).toBe(workspace)
			expect(r.argv[2]).toBe(7)
			expect(r.argv[3][1]).toBe(Lighting)
		end)

		it("continues the sequential ref cursor across the messages of one frame", function()
			local w = Codec.newWriter(64, false)
			Codec.writeArgs(w, 255, 1, workspace)
			local m1 = w.n
			local cf = CFrame.new(4, 5, 6)
			Codec.writeArgs(w, 255, 2, 7, cf)
			local b = bytesOf(w)
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, w.refs, 0)
			local argv: { any } = {}
			Codec.beginMessage(ctx, false)
			local n1, o1 = Codec.readArgs(b, 0, buffer.len(b), ctx, argv, 255)
			expect(n1).toBe(1)
			expect(o1).toBe(m1)
			expect(argv[1]).toBe(workspace)
			Codec.beginMessage(ctx, false)
			local n2, o2 = Codec.readArgs(b, o1, buffer.len(b), ctx, argv, 255)
			expect(n2).toBe(2)
			expect(o2).toBe(buffer.len(b))
			expect(argv[2]).toBe(cf)
			expect(ctx.cursor).toBe(2)
		end)
	end)

	describe("sender rules", function()
		it("turns top-level functions and threads into nil and counts them as lossy", function()
			local w = Codec.newWriter(16, true)
			local st = Codec.writeArgs(w, 20, 2, function() end, coroutine.create(function() end))
			expect(st).toBe(0)
			expect(whex(w)).toBe("02 00 00")
			expect(w.lossy).toBe(2)
		end)

		it("sends a table holding a function through the sidecar, never NIL inside ARRAY/MAP", function()
			local f = function() end
			for _, indexed in { false, true } do
				local w, st = encodeValue(indexed, list(1, 2, f))
				expect(st).toBe(0)
				expect(buffer.readu8(w.buf, 0)).toBe(Tag.REF)
				expect(w.refs[1]).toEqual({ 1, 2 })
				expect(w.lossy).toBe(1)

				local wm, stm = encodeValue(indexed, { a = 1, b = f })
				expect(stm).toBe(0)
				expect(buffer.readu8(wm.buf, 0)).toBe(Tag.REF)
				expect(wm.refs[1]).toEqual({ a = 1 })

				-- the outer array stays inline; the inner table (with the function) becomes a REF
				local wn, stn = encodeArgs(indexed, list(1, { f }))
				expect(stn).toBe(0)
				expect(whex(wn)).toBe(if indexed then "01 10 02 81 12 00" else "01 10 02 81 12")
				expect(wn.refs[1]).toEqual({})
				local r = decodeWriter(wn)
				expect(r.err).toBe(0)
			end
		end)

		it("drops metatables through the sidecar without running any metamethod", function()
			local trap = setmetatable({ 1, 2, x = 3 }, {
				__index = function()
					error("__index ran")
				end,
				__len = function()
					error("__len ran")
				end,
				__iter = function()
					error("__iter ran")
				end,
				__newindex = function()
					error("__newindex ran")
				end,
			})
			for _, indexed in { false, true } do
				local w, st = encodeValue(indexed, trap)
				expect(st).toBe(0)
				expect(buffer.readu8(w.buf, 0)).toBe(Tag.REF)
				expect(w.refs[1]).toEqual({ 1, 2, x = 3 })
				expect(getmetatable(w.refs[1])).toBeNil()
				expect(w.lossy).toBe(1)
			end
			local locked = setmetatable({ 1 }, { __metatable = "locked" })
			local w, st = encodeValue(true, locked)
			expect(st).toBe(0)
			expect(w.refs[1]).toEqual({ 1 })
			expect(w.lossy).toBe(1)
		end)

		it("fails cycles with Cycle and leaves no scratch behind", function()
			local a = {}
			a.self = a
			local b: { any } = { 1 }
			b[2] = b
			local c: { [any]: any } = { 1, x = true }
			c.me = c
			local d = {}
			local e = { d, x = 1 }
			d[1] = e
			local cyclic: { any } = { a, b, c, d }
			for _, v in cyclic do
				for _, indexed in { false, true } do
					local _, st = encodeValue(indexed, v)
					expect(st).toBe(E.CYCLE)
					expect(Codec._test.visitingCount()).toBe(0)
				end
			end
			-- a shared subtable is not a cycle (inline and sidecar)
			local s = { 1 }
			expect(select(2, encodeValue(true, { s, s }))).toBe(0)
			local w, st = encodeValue(false, { s, s, x = 1 })
			expect(st).toBe(0)
			expect(w.refs[1]).toEqual({ { 1 }, { 1 }, x = 1 })
		end)

		it("fails values deeper than 16 with TooDeep (inline and in the sidecar)", function()
			for _, indexed in { false, true } do
				expect(select(2, encodeValue(indexed, nest(16, 1)))).toBe(0)
				expect(select(2, encodeValue(indexed, nest(17, 1)))).toBe(E.TOO_DEEP)
				-- sidecar depth counts from the ref'd table (as walkSidecar does)
				expect(select(2, encodeValue(indexed, { nest(15, 1), x = 1 }))).toBe(0)
				expect(select(2, encodeValue(indexed, { nest(16, 1), x = 1 }))).toBe(E.TOO_DEEP)
				expect(Codec._test.visitingCount()).toBe(0)
			end
			local w = Codec.newWriter(16, true)
			expect(Codec.writeArgs(w, 20, 2, 1, nest(17, 1))).toBe(E.TOO_DEEP)
			expect(w.errArg).toBe(2)
		end)

		it("caps C->S messages at 2048 inline values (S->C is uncapped)", function()
			local w = Codec.newWriter(64, true)
			expect(Codec.writeValue(w, table.create(2047, 1), 0)).toBe(0)
			expect(w.inlineNodes).toBe(2048)
			Codec.resetWriter(w)
			expect(Codec.writeValue(w, table.create(2048, 1), 0)).toBe(E.TOO_MANY_NODES)
			Codec.resetWriter(w)
			expect(Codec.writeArgs(w, 20, 2, table.create(1023, 1), table.create(1022, 1))).toBe(0)
			expect(w.inlineNodes).toBe(2047)
			Codec.resetWriter(w)
			expect(Codec.writeArgs(w, 20, 2, table.create(1023, 1), table.create(1024, 1))).toBe(E.TOO_MANY_NODES)
			expect(w.errArg).toBe(2)
			local s = Codec.newWriter(64, false)
			expect(Codec.writeValue(s, table.create(5000, 1), 0)).toBe(0)
		end)

		it("caps C->S sidecar nodes at 2048 per message", function()
			local ok = table.create(2046, true) :: { [any]: any }
			ok.x = true -- 2047 values + 1 ref slot
			local w, st = encodeValue(true, ok)
			expect(st).toBe(0)
			expect(w.nodes).toBe(2048)
			local over = table.create(2047, true) :: { [any]: any }
			over.x = true
			expect(select(2, encodeValue(true, over))).toBe(E.TOO_MANY_NODES)
			expect(select(2, encodeValue(false, over))).toBe(0)
		end)

		it("caps C->S messages at 255 refs (the frame header's nrefs is a u8)", function()
			local w, st = encodeValue(true, table.create(255, workspace))
			expect(st).toBe(0)
			expect(w.nrefs).toBe(255)
			expect(select(2, encodeValue(true, table.create(256, workspace)))).toBe(E.TOO_MANY_NODES)
			expect(select(2, encodeValue(false, table.create(300, workspace)))).toBe(0)
		end)

		it("sends every table through the sidecar when inlineTables is false", function()
			local w = Codec.newWriter(16, false)
			w.inlineTables = false
			expect(Codec.writeValue(w, { 1, 2 }, 0)).toBe(0)
			expect(Codec.writeValue(w, {}, 0)).toBe(0)
			expect(Codec.writeValue(w, 5, 0)).toBe(0)
			expect(whex(w)).toBe("12 12 85")
			expect(w.refs[1]).toEqual({ 1, 2 })
			expect(w.refs[2]).toEqual({})
		end)

		it("refuses values that need the sidecar on unreliable writers (NeedsRef)", function()
			local w = Codec.newWriter(16, false)
			w.unreliable = true
			expect(Codec.writeValue(w, workspace, 0)).toBe(E.NEEDS_REF)
			expect(Codec.writeValue(w, { 1, x = 2 }, 0)).toBe(E.NEEDS_REF)
			expect(Codec.writeValue(w, CFrame.new(), 0)).toBe(E.NEEDS_REF)
			Codec.resetWriter(w)
			expect(Codec.writeValue(w, { 1, 2 }, 0)).toBe(0)
			expect(Codec.writeValue(w, Vector3.one, 0)).toBe(0)
			expect(w.nrefs).toBe(0)
		end)

		it("rejects buffers and bad keys in C->S sidecar tables; S->C copies them", function()
			local buf = buffer.fromstring("xy")
			expect(select(2, encodeValue(true, { 1, x = buf }))).toBe(E.BAD_TYPE)
			expect(select(2, encodeValue(true, { { [workspace] = 1 } }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, { [workspace] = 1 }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, { [INF] = 1 }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, { [-INF] = 1 }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, { [{}] = 1 }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, { [Vector3.one] = 1 }))).toBe(E.BAD_KEY)
			expect(select(2, encodeValue(true, kv(true, 1, 1.5, 2, -3, 3, "s", 4)))).toBe(0)
			expect(Codec._test.visitingCount()).toBe(0)

			local w, st = encodeValue(false, { 1, x = buf })
			expect(st).toBe(0)
			local copied = w.refs[1].x
			expect(buffer.tostring(copied)).toBe("xy")
			buffer.writeu8(buf, 0, 0x7A) -- a later change to the source is not in the snapshot
			expect(buffer.tostring(copied)).toBe("xy")
			expect(select(2, encodeValue(false, { [workspace] = 1 }))).toBe(0)
		end)

		it("takes a Fire-time snapshot of sidecar tables", function()
			local src = { 1, x = { 2 } }
			local w = encodeValue(false, src)
			src.x[1] = 99
			src[1] = 98
			expect(w.refs[1]).toEqual({ 1, x = { 2 } })
		end)

		it("counts sidecar nodes and string bytes by the node rule", function()
			local w, st = encodeValue(true, { a = "xy", [1] = 5, sub = { 1, 2 } })
			expect(st).toBe(0)
			expect(w.nrefs).toBe(1)
			expect(w.nodes).toBe(6) -- 1 slot + 3 values + 2 values in sub
			expect(w.sideBytes).toBe(6) -- "a" + "xy" + "sub"
			expect(w.inlineNodes).toBe(1)
		end)

		it("fails more than max arguments with TooManyArgs and errArg = max + 1", function()
			local w = Codec.newWriter(16, true)
			expect(Codec.writeArgs(w, 20, 21, table.unpack(table.create(21, 1)))).toBe(E.TOO_MANY_ARGS)
			expect(w.errArg).toBe(21)
			expect(w.n).toBe(0)
			Codec.resetWriter(w)
			expect(Codec.writeArgs(w, 20, 20, table.unpack(table.create(20, 1)))).toBe(0)
		end)

		it("names the failing argument in errArg", function()
			local cyc = {}
			cyc.self = cyc
			local w = Codec.newWriter(16, true)
			expect(Codec.writeArgs(w, 20, 3, 1, cyc, 2)).toBe(E.CYCLE)
			expect(w.errArg).toBe(2)
		end)

		it("copyTable returns a deep copy and a status", function()
			local w = Codec.newWriter(16, false)
			local inner = { 2 }
			local copy, st = Codec.copyTable(w, { 1, inner, f = function() end }, 0)
			expect(st).toBe(0)
			expect(copy).toEqual(list(1, { 2 }))
			expect(copy[2]).never.toBe(inner)
			expect(w.lossy).toBe(1)
			expect(select(2, Codec.copyTable(w, nest(16, 1), 0))).toBe(0)
			expect(select(2, Codec.copyTable(w, nest(17, 1), 0))).toBe(E.TOO_DEEP)
		end)
	end)

	describe("node counts", function()
		it("encoder and decoder agree on inline nodes and sidecar cost", function()
			local w, st = encodeArgs(
				true,
				list(1, { 2, 3 }, { a = "b" }),
				"s",
				{ x = { y = { 1 } } },
				kv(1, 1, "n", "mixed", 5, workspace),
				workspace
			)
			expect(st).toBe(0)
			expect(w.inlineNodes).toBe(14)
			local r = decodeWriter(w)
			expect(r.err).toBe(0)
			expect(r.ctx.nodes).toBe(w.inlineNodes)
			local wst, cost = walk(w.refs, w.nrefs)
			expect(wst).toBe(0)
			expect(cost).toBe(NODE_CHARGE * w.nodes + w.sideBytes)
		end)
	end)

	describe("hostile decode (server rules)", function()
		it("rejects NaN and infinities unless AllowNonFinite", function()
			for _, bad in { NAN, INF, -INF } do
				local w = encodeArgs(true, 1, bad)
				local r = decodeWriter(w)
				expect(r.err).toBe(D.NONFINITE)
				expect(r.errArg).toBe(2)
				expect(r.n).toBe(1)
				local ok = decodeWriter(w, true)
				expect(ok.err).toBe(0)
				expect(ok.n).toBe(2)
				expect(same(ok.argv[2], bad)).toBe(true)
			end
		end)

		it("rejects non-finite Vector3, Vector2 and Color3 components unless AllowNonFinite", function()
			local cases = {
				"01 0D 00 00 C0 7F 00 00 00 00 00 00 00 00", -- Vector3(NaN, 0, 0)
				"01 0D 00 00 00 00 00 00 80 7F 00 00 00 00", -- Vector3(0, inf, 0)
				"01 0D 00 00 00 00 00 00 00 00 00 00 80 FF", -- Vector3(0, 0, -inf)
				"01 0E 00 00 00 00 00 00 C0 7F", -- Vector2(0, NaN)
				"01 0F 00 00 80 7F 00 00 00 00 00 00 00 00", -- Color3(inf, 0, 0)
			}
			for _, h in cases do
				local b = unhex(h)
				local r = decodeArgs(b, true, nil, 0)
				expect(r.err).toBe(D.NONFINITE)
				expect(r.errArg).toBe(1)
				expect(r.n).toBe(0)
				local allowed = decodeArgs(b, true, nil, 0, true)
				expect(allowed.err).toBe(0)
				expect(allowed.n).toBe(1)
				local client = decodeArgs(b, false, nil, 0)
				expect(client.err).toBe(0)
			end
		end)

		it("rejects a REF whose sidecar entry holds a non-finite value (refFlags)", function()
			local refs = { { 1, NAN } }
			local ctx = Codec.newReadCtx(true, true)
			Codec.beginFrame(ctx, refs, 1)
			local st = Codec.walkSidecar(refs, 1, ctx)
			expect(st).toBe(0)
			expect(ctx.refFlags[1]).toBe(1)
			local b = unhex("01 12 00")
			local argv: { any } = {}
			Codec.beginMessage(ctx, false)
			local n = Codec.readArgs(b, 0, 3, ctx, argv, 20)
			expect(ctx.err).toBe(D.NONFINITE)
			expect(ctx.errArg).toBe(1)
			expect(n).toBe(0)
			-- the next frame carries the same sidecar again (a slot may be referenced once per frame)
			Codec.beginFrame(ctx, refs, 1)
			expect(Codec.walkSidecar(refs, 1, ctx)).toBe(0)
			Codec.beginMessage(ctx, true)
			n = Codec.readArgs(b, 0, 3, ctx, argv, 20)
			expect(ctx.err).toBe(0)
			expect(n).toBe(1)
			expect(argv[1]).toBe(refs[1])
		end)

		it("rejects a second reference to the same sidecar slot in one frame (BadRef, structural)", function()
			local big = table.create(100, 1)
			local refs = { big, workspace }
			local ctx = Codec.newReadCtx(true, true)
			Codec.beginFrame(ctx, refs, 2)
			expect(Codec.walkSidecar(refs, 2, ctx)).toBe(0)
			local argv: { any } = {}
			-- one message referencing slot 0 twice
			Codec.beginMessage(ctx, false)
			Codec.readArgs(unhex("02 12 00 12 00"), 0, 5, ctx, argv, 20)
			expect(ctx.err).toBe(D.BAD_REF)
			expect(ctx.err < C.DECODE_SEMANTIC_MIN).toBe(true)
			table.clear(argv)
			-- one reference per message across two messages of the frame: the second one fails
			Codec.beginFrame(ctx, refs, 2)
			Codec.walkSidecar(refs, 2, ctx)
			Codec.beginMessage(ctx, false)
			local n = Codec.readArgs(unhex("01 12 01"), 0, 3, ctx, argv, 20)
			expect(ctx.err).toBe(0)
			expect(n).toBe(1)
			expect(argv[1]).toBe(workspace)
			Codec.beginMessage(ctx, false)
			Codec.readArgs(unhex("01 12 01"), 0, 3, ctx, argv, 20)
			expect(ctx.err).toBe(D.BAD_REF)
			-- an honest writer gives every value its own slot, even the same table twice
			local w = Codec.newWriter(32, true)
			Codec.writeArgs(w, 20, 2, workspace, workspace)
			expect(w.nrefs).toBe(2)
			local r = decodeWriter(w)
			expect(r.err).toBe(0)
			expect(r.argv[1]).toBe(workspace)
			expect(r.argv[2]).toBe(workspace)
		end)

		it("reserves ARRAY claims per message: nested headers cannot all claim the same bytes", function()
			local parts = { "01" }
			for _ = 1, 17 do
				table.insert(parts, "10 EE 0F") -- ARRAY, varint 2030
			end
			local b = unhex(table.concat(parts, " "))
			local padded = buffer.create(buffer.len(b) + 2100)
			buffer.copy(padded, 0, b, 0, buffer.len(b))
			local ctx = Codec.newReadCtx(true, true)
			Codec.beginFrame(ctx, nil, 0)
			Codec.beginMessage(ctx, false)
			local argv: { any } = {}
			Codec.readArgs(padded, 0, buffer.len(padded), ctx, argv, 20)
			expect(ctx.err).toBe(D.TOO_MANY_NODES)
			expect(ctx.claimed <= C.Limit.MAX_NODES).toBe(true)
			-- honest nested arrays within MAX_NODES still decode, and beginMessage resets the claims
			local rows = table.create(40)
			for i = 1, 40 do
				rows[i] = table.create(50, i)
			end
			local w = Codec.newWriter(64, true)
			expect(Codec.writeArgs(w, 20, 1, rows)).toBe(0)
			local r = decodeWriter(w)
			expect(r.err).toBe(0)
			expect(r.ctx.claimed).toBe(40 + 40 * 50)
			expect(same(r.argv[1], rows)).toBe(true)
		end)

		it("fails depth 17 with TooDeep (server) and BadTag (client: no honest server writes it)", function()
			local deep16 = "01 " .. string.rep("10 01 ", 16) .. "81"
			local deep17 = "01 " .. string.rep("10 01 ", 17) .. "81"
			expect(whex((encodeArgs(true, nest(16, 1))))).toBe(deep16)
			local ok = decodeArgs(unhex(deep16), true, nil, 0)
			expect(ok.err).toBe(0)
			expect(same(ok.argv[1], nest(16, 1))).toBe(true)
			local r = decodeArgs(unhex(deep17), true, nil, 0)
			expect(r.err).toBe(D.TOO_DEEP)
			expect(r.errArg).toBe(1)
			local client = decodeArgs(unhex(deep17), false, nil, 0)
			expect(client.err).toBe(D.BAD_TAG)
		end)

		it("fails more than 2048 inline values with TooManyNodes", function()
			local okArr = decodeArgs(bytesOf((encodeArgs(false, table.create(2047, 1)))), true, nil, 0)
			expect(okArr.err).toBe(0)
			expect(okArr.ctx.nodes).toBe(2048)
			local serverOver = decodeArgs(bytesOf((encodeArgs(false, table.create(2048, 1)))), true, nil, 0)
			expect(serverOver.err).toBe(D.TOO_MANY_NODES)
			expect(serverOver.errArg).toBe(1)
			local map = {}
			for i = 1, 2048 do
				map["k" .. i] = true
			end
			expect(decodeArgs(bytesOf((encodeArgs(false, map))), true, nil, 0).err).toBe(D.TOO_MANY_NODES)
			-- counted across arguments
			local spread =
				decodeArgs(bytesOf((encodeArgs(false, table.create(1024, 1), table.create(1023, 1)))), true, nil, 0)
			expect(spread.err).toBe(D.TOO_MANY_NODES)
			expect(spread.errArg).toBe(2)
			local fits =
				decodeArgs(bytesOf((encodeArgs(false, table.create(1024, 1), table.create(1022, 1)))), true, nil, 0)
			expect(fits.err).toBe(0)
			-- the client side has no inline cap
			expect(decodeWriter((encodeArgs(false, table.create(5000, 1)))).err).toBe(0)
		end)

		it("fails more than max arguments with TooManyArgs (errArg = max + 1)", function()
			local w21 = encodeArgs(false, table.unpack(table.create(21, 1)))
			local r = decodeArgs(bytesOf(w21), true, nil, 0, false, 20)
			expect(r.err).toBe(D.TOO_MANY_ARGS)
			expect(r.errArg).toBe(21)
			expect(r.n).toBe(0)
			local w20 = encodeArgs(false, table.unpack(table.create(20, 1)))
			local ok = decodeArgs(bytesOf(w20), true, nil, 0, false, 20)
			expect(ok.err).toBe(0)
			expect(ok.n).toBe(20)
		end)

		it("fails tags 0x14..0x7F with BadTag on both sides", function()
			local bad = {}
			for tag = 0x14, 0x7F do
				local b = buffer.create(2)
				buffer.writeu8(b, 0, 1)
				buffer.writeu8(b, 1, tag)
				for _, hostile in { true, false } do
					local r = decodeArgs(b, hostile, nil, 0)
					if r.err ~= D.BAD_TAG or r.errArg ~= 1 then
						table.insert(bad, string.format("0x%02X hostile=%s -> %d", tag, tostring(hostile), r.err))
					end
				end
			end
			expect(table.concat(bad, ", ")).toBe("")
		end)

		it("fails NIL inside arrays and maps with BadTag (top-level nil is fine)", function()
			for _, h in { "01 10 01 00", "01 10 02 81 00", "01 11 01 0B 01 61 00" } do
				expect(decodeArgs(unhex(h), true, nil, 0).err).toBe(D.BAD_TAG)
				expect(decodeArgs(unhex(h), false, nil, 0).err).toBe(D.BAD_TAG)
			end
			local ok = decodeArgs(unhex("02 00 81"), true, nil, 0)
			expect(ok.err).toBe(0)
			expect(ok.n).toBe(2)
		end)

		it("fails map keys that are not STR/STR32 with BadTag", function()
			-- (each buffer holds at least 3 bytes per pair, so the key tag is reached)
			expect(decodeArgs(unhex("01 11 01 81 81 81"), true, nil, 0).err).toBe(D.BAD_TAG)
			expect(decodeArgs(unhex("01 11 01 12 00 81"), true, { workspace }, 1).err).toBe(D.BAD_TAG)
			expect(decodeArgs(unhex("01 11 01 81 81 81"), false, nil, 0).err).toBe(D.BAD_TAG)
			local r = decodeArgs(unhex("01 11 01 0A 01 00 00 00 61 81"), true, nil, 0)
			expect(r.err).toBe(0)
			expect(r.argv[1]).toEqual({ a = 1 })
		end)

		it("fails a ref index >= nrefs with BadRef", function()
			expect(decodeArgs(unhex("01 12 00"), true, nil, 0).err).toBe(D.BAD_REF)
			local ok = decodeArgs(unhex("01 12 00"), true, { workspace }, 1)
			expect(ok.err).toBe(0)
			expect(ok.argv[1]).toBe(workspace)
			expect(decodeArgs(unhex("01 12 01"), true, { workspace }, 1).err).toBe(D.BAD_REF)
			expect(decodeArgs(unhex("01 12 FF 01"), true, table.create(255, workspace), 255).err).toBe(D.BAD_REF)
			-- a nil ref (streamed out) is legal
			local holes: { any } = table.create(2)
			holes[2] = workspace
			local r = decodeArgs(unhex("02 12 00 12 01"), true, holes, 2)
			expect(r.err).toBe(0)
			expect(r.argv[1]).toBeNil()
			expect(r.argv[2]).toBe(workspace)
		end)

		it("fails counts and lengths beyond the bytes left with Overrun", function()
			for _, h in { "01 10 05 81", "01 0B 05 61", "05 81", "01 11 01 0B 00", "01 0C 03 00", "01 05 00 00" } do
				expect(decodeArgs(unhex(h), true, nil, 0).err).toBe(D.OVERRUN)
				expect(decodeArgs(unhex(h), false, nil, 0).err).toBe(D.OVERRUN)
			end
		end)

		it("fails an overlong varint with BadVarint", function()
			expect(decodeArgs(unhex("01 0B 80 80 80 01"), true, nil, 0).err).toBe(D.BAD_VARINT)
			expect(decodeArgs(unhex("01 10 80 80 80 01"), false, nil, 0).err).toBe(D.BAD_VARINT)
		end)

		it("stops at the last argument and leaves trailing bytes to the caller", function()
			local r = decodeArgs(unhex("01 81 99"), true, nil, 0)
			expect(r.err).toBe(0)
			expect(r.n).toBe(1)
			expect(r.o).toBe(2)
		end)

		it("beginMessage resets the per-message fields and keeps the ref cursor", function()
			local ctx = Codec.newReadCtx(false, false)
			expect(ctx.hostile).toBe(false)
			expect(ctx.indexed).toBe(false)
			expect(ctx.refs).toBeNil()
			expect(ctx.refFlags[255]).toBe(0)
			ctx.err, ctx.errArg, ctx.nodes, ctx.cursor = 3, 2, 9, 4
			Codec.beginMessage(ctx, true)
			expect(ctx.err).toBe(0)
			expect(ctx.errArg).toBe(0)
			expect(ctx.nodes).toBe(0)
			expect(ctx.allowNonFinite).toBe(true)
			expect(ctx.cursor).toBe(4)
			Codec.beginFrame(ctx, nil, 0)
			expect(ctx.cursor).toBe(0)
		end)
	end)

	describe("walkSidecar", function()
		it("accepts nil slots, tables, Instances and datatypes", function()
			local refs: { any } = table.create(7)
			refs[1] = workspace
			refs[3] = CFrame.new(1, 2, 3)
			refs[4] = Enum.Material.Plastic
			refs[5] = kv(1, 1, 2, "a", 3, true, "x", Vector3.one, "y", { z = workspace }, 1.5, false, true, 0)
			refs[6] = UDim2.new(1, 2, 3, 4)
			refs[7] = BrickColor.new("Bright red")
			local st, _, ctx = walk(refs, 7)
			expect(st).toBe(0)
			local flagged = 0
			for i = 1, 7 do
				flagged += ctx.refFlags[i]
			end
			expect(flagged).toBe(0)
		end)

		it("fails top-level strings, numbers, booleans, buffers, functions and threads with BadRef", function()
			for _, v in list("s", 1, true, buffer.create(1), function() end, coroutine.create(function() end)) do
				expect((walk({ v }, 1))).toBe(D.BAD_REF)
			end
		end)

		it("fails functions, threads and buffers inside tables with BadRef", function()
			expect((walk({ { function() end } }, 1))).toBe(D.BAD_REF)
			expect((walk({ { x = coroutine.create(function() end) } }, 1))).toBe(D.BAD_REF)
			expect((walk({ { { buffer.create(1) } } }, 1))).toBe(D.BAD_REF)
			expect(Codec._test.walkStackCount()).toBe(0)
		end)

		it("fails keys that are not strings, booleans or finite numbers with BadKey", function()
			for _, key in { workspace, INF, -INF, {}, Vector3.one, Enum.Material.Plastic } do
				local tbl: { [any]: any } = {}
				tbl[key] = 1
				expect((walk({ tbl }, 1))).toBe(D.BAD_KEY)
				expect((walk({ { inner = tbl } }, 1))).toBe(D.BAD_KEY)
			end
			expect((walk({ kv(true, 1, 1.5, 1, -3, 1, "s", 1) }, 1))).toBe(0)
			expect(Codec._test.walkStackCount()).toBe(0)
		end)

		it("fails values deeper than 16 below a ref with TooDeep", function()
			expect((walk({ nest(16, 1) }, 1))).toBe(0)
			expect((walk({ nest(17, 1) }, 1))).toBe(D.TOO_DEEP)
			expect((walk({ nest(17, {}) }, 1))).toBe(D.TOO_DEEP)
			expect(Codec._test.walkStackCount()).toBe(0)
		end)

		it("fails more than 2048 nodes per frame with TooManyNodes", function()
			expect((walk({ table.create(2047, 1) }, 1))).toBe(0)
			expect((walk({ table.create(2048, 1) }, 1))).toBe(D.TOO_MANY_NODES)
			expect((walk({ table.create(1000, 1), table.create(1046, 1) }, 2))).toBe(0)
			expect((walk({ table.create(1000, 1), table.create(1047, 1) }, 2))).toBe(D.TOO_MANY_NODES)
			-- a huge hostile table stops at the cap
			expect((walk({ table.create(100000, 1) }, 1))).toBe(D.TOO_MANY_NODES)
			expect(Codec._test.walkStackCount()).toBe(0)
		end)

		it("returns the node-rule cost (8 per node + string bytes)", function()
			local st, cost = walk({ { a = "xy", [1] = 5, sub = { 1, 2 } }, workspace }, 2)
			expect(st).toBe(0)
			expect(cost).toBe(NODE_CHARGE * 7 + 6)
			local holes: { any } = table.create(2)
			local st2, cost2 = walk(holes, 2)
			expect(st2).toBe(0)
			expect(cost2).toBe(NODE_CHARGE * 2)
		end)

		it("flags non-finite numbers and vectors inside tables, and top-level vectors", function()
			local _, _, ctx = walk(
				{ { 1, NAN }, { x = { y = INF } }, { 1, 2 }, Vector3.new(0, -INF, 0), { Vector3.new(NAN, 0, 0) } },
				5
			)
			expect(ctx.refFlags[1]).toBe(1)
			expect(ctx.refFlags[2]).toBe(1)
			expect(ctx.refFlags[3]).toBe(0)
			expect(ctx.refFlags[4]).toBe(1)
			expect(ctx.refFlags[5]).toBe(1)
		end)

		it("flags non-finite components of every listed datatype, at the top level and inside tables", function()
			local problems = {}
			local poisoned: { [string]: boolean } = {}
			for _, case in DATATYPES do
				local made, v = pcall(case.make)
				if made then
					local nonFinite = not finite(case.probe(v))
					poisoned[case.name] = nonFinite
					for _, wrapped in { false, true } do
						local st, _, ctx = walk({ if wrapped then { x = v } else v }, 1)
						local want = if nonFinite then 1 else 0
						if st ~= 0 or ctx.refFlags[1] ~= want then
							table.insert(
								problems,
								string.format(
									"%s wrapped=%s: status %d flag %d (want %d)",
									case.name,
									tostring(wrapped),
									st,
									ctx.refFlags[1],
									want
								)
							)
						end
					end
				end
				local st, _, ctx = walk({ case.finite() }, 1)
				if st ~= 0 or ctx.refFlags[1] ~= 0 then
					table.insert(problems, case.name .. ": a finite value was flagged")
				end
			end
			expect(table.concat(problems, "\n")).toBe("")
			-- the engine certainly keeps these non-finite, so the checks above were exercised
			expect(poisoned.Vector3).toBe(true)
			expect(poisoned.Vector2).toBe(true)
			expect(poisoned.CFrame).toBe(true)
		end)

		it("beginFrame clears the flags of the previous frame", function()
			local ctx = Codec.newReadCtx(true, true)
			local refs = { { NAN }, { NAN } }
			Codec.beginFrame(ctx, refs, 2)
			Codec.walkSidecar(refs, 2, ctx)
			expect(ctx.refFlags[1]).toBe(1)
			expect(ctx.refFlags[2]).toBe(1)
			Codec.beginFrame(ctx, { workspace }, 1)
			expect(ctx.refFlags[1]).toBe(0)
			expect(ctx.refFlags[2]).toBe(0)
		end)
	end)

	describe("S->C decode after MISSING_INSTANCE", function()
		it("keeps decoding to the message end and keeps the ref cursor right", function()
			local w = Codec.newWriter(64, false)
			Codec.writeArgs(w, 255, 3, workspace, { 1, workspace }, 9)
			local m1 = w.n
			Codec.writeArgs(w, 255, 1, workspace)
			local b = bytesOf(w)
			-- the first ref was streamed out and arrives nil
			local refs: { any } = table.create(3)
			refs[2] = workspace
			refs[3] = Lighting
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, refs, 0)
			Codec.beginMessage(ctx, false)
			ctx.err = D.MISSING_INSTANCE -- recorded by a typed Instance field earlier in this message
			local argv: { any } = {}
			local n, o = Codec.readArgs(b, 0, buffer.len(b), ctx, argv, 255)
			expect(n).toBe(3)
			expect(o).toBe(m1)
			expect(ctx.err).toBe(D.MISSING_INSTANCE)
			expect(argv[1]).toBeNil()
			expect(argv[2][2]).toBe(workspace)
			expect(argv[3]).toBe(9)
			expect(ctx.cursor).toBe(2)
			Codec.beginMessage(ctx, false)
			local n2, o2 = Codec.readArgs(b, o, buffer.len(b), ctx, argv, 255)
			expect(ctx.err).toBe(0)
			expect(n2).toBe(1)
			expect(o2).toBe(buffer.len(b))
			expect(argv[1]).toBe(Lighting)
			expect(ctx.cursor).toBe(3)
		end)

		it("lets a later structural failure replace MISSING_INSTANCE; otherwise the first failure wins", function()
			local ctx = Codec.newReadCtx(false, false)
			Codec.beginFrame(ctx, nil, 0)
			Codec.beginMessage(ctx, false)
			ctx.err = D.MISSING_INSTANCE
			Codec.readArgs(unhex("01 14"), 0, 2, ctx, {}, 255)
			expect(ctx.err).toBe(D.BAD_TAG)
			local h = Codec.newReadCtx(true, true)
			Codec.beginFrame(h, nil, 0)
			Codec.beginMessage(h, false)
			h.err = D.RANGE
			Codec.readArgs(unhex("01 14"), 0, 2, h, {}, 20)
			expect(h.err).toBe(D.RANGE)
		end)
	end)

	describe("fuzz", function()
		it("random buffers never throw and never return an offset past lim (10 000 per decoder)", function()
			local rng = Random.new(20260924)
			local refs: { any } = { workspace, { 1 }, nil, CFrame.new() }
			local client = Codec.newReadCtx(false, false)
			local server = Codec.newReadCtx(true, true)
			local argv: { any } = {}
			local throws, past = 0, 0
			local first = ""
			local function note(what: string, ok: boolean, detail: any)
				if not ok then
					throws += 1
				else
					past += 1
				end
				if first == "" then
					first = what .. ": " .. tostring(detail)
				end
			end
			for i = 1, 10000 do
				local b = randomBuffer(rng, 48)
				local len = buffer.len(b)

				Codec.beginFrame(client, refs, 0)
				Codec.beginMessage(client, false)
				local ok, n, o = pcall(Codec.readArgs, b, 0, len, client, argv, 255)
				if not ok or o > len or n < 0 or n > 255 then
					note("client readArgs", ok, if ok then o else n)
				end
				table.clear(argv)

				Codec.beginFrame(server, refs, rng:NextInteger(0, 4))
				server.refFlags[2] = 1
				Codec.beginMessage(server, rng:NextNumber() < 0.5)
				ok, n, o = pcall(Codec.readArgs, b, 0, len, server, argv, 20)
				if not ok or o > len or n < 0 or n > 20 then
					note("server readArgs", ok, if ok then o else n)
				end
				table.clear(argv)

				local start = rng:NextInteger(0, len)
				Codec.beginMessage(server, false)
				local vok, _, vo = pcall(Codec.readValue, b, start, len, server, 0)
				if not vok or vo > len or vo < start then
					note("readValue", vok, vo)
				end
				local hok, h, ho = pcall(Codec.readHead, b, start, len)
				if not hok or ho > len or ho < start or h < -255 or h > 65535 or (h < 0 and h > -240) then
					note("readHead", hok, h)
				end
				local rok, v, ro = pcall(Codec.readVarint, b, start, len)
				if not rok or ro > len or ro < start or (v ~= -1 and (v < 0 or v > C.Limit.VARINT_MAX)) then
					note("readVarint", rok, v)
				end
				if i % 1000 == 0 then
					task.wait()
				end
			end
			expect(first).toBe("")
			expect(throws).toBe(0)
			expect(past).toBe(0)
		end, { timeout = 60 })

		it("mutated valid messages never throw and never pass lim", function()
			local rng = Random.new(7)
			local throws, past = 0, 0
			local first = ""
			for i = 1, 3000 do
				local v = randomValue(rng, 0, false)
				for _, hostile in { false, true } do
					local w = Codec.newWriter(64, hostile)
					if Codec.writeArgs(w, 20, 1, v) == 0 then
						local b = bytesOf(w)
						for _ = 1, rng:NextInteger(1, 3) do
							buffer.writeu8(b, rng:NextInteger(0, w.n - 1), rng:NextInteger(0, 255))
						end
						local refs = if w.nrefs > 0 then w.refs else nil
						local ok, r = pcall(function(): Decoded
							return decodeArgs(b, hostile, refs, w.nrefs, false, 20)
						end)
						if not ok then
							throws += 1
							if first == "" then
								first = tostring(r)
							end
						elseif r.o > buffer.len(b) then
							past += 1
						end
					end
				end
				if i % 500 == 0 then
					task.wait()
				end
			end
			expect(first).toBe("")
			expect(throws).toBe(0)
			expect(past).toBe(0)
		end, { timeout = 60 })

		it("every truncation of a valid message fails without passing lim", function()
			local samples = {
				pack(7, 2),
				pack("hello", true, false, nil, -5, 70000, 0.25, -4294967295),
				pack(list(1, list(2, { 3 })), { a = 1, b = { c = "d" } }, {}),
				pack(Vector3.new(1, 2, 3), Vector2.new(4, 5), Color3.new(0.5, 0.25, 1)),
				pack(buffer.fromstring("bytes"), string.rep("s", 200)),
				pack(workspace, { 1, x = workspace }, CFrame.new(1, 2, 3)),
				pack(nil),
				pack(),
			}
			local problems = {}
			for si, p in samples do
				for _, hostile in { false, true } do
					local w = Codec.newWriter(64, hostile)
					local st = Codec.writeArgs(w, 20, p.n, table.unpack(p, 1, p.n))
					if st ~= 0 then
						table.insert(problems, string.format("sample %d: encode status %d", si, st))
						continue
					end
					local b = bytesOf(w)
					local len = buffer.len(b)
					local refs = if w.nrefs > 0 then w.refs else nil
					local full = decodeArgs(b, hostile, refs, w.nrefs, false, 20)
					if full.err ~= 0 or full.o ~= len or full.n ~= p.n then
						table.insert(
							problems,
							string.format("sample %d hostile=%s: full decode failed", si, tostring(hostile))
						)
					end
					for cut = 0, len - 1 do
						local r = decodeArgs(b, hostile, refs, w.nrefs, false, 20, cut)
						if r.err == 0 or r.o > cut then
							table.insert(
								problems,
								string.format(
									"sample %d hostile=%s cut %d: err %d o %d",
									si,
									tostring(hostile),
									cut,
									r.err,
									r.o
								)
							)
						end
					end
				end
			end
			expect(table.concat(problems, "\n")).toBe("")
		end)

		it("random values round-trip in both directions and node counts agree", function()
			local rng = Random.new(42)
			local problems = {}
			for i = 1, 1500 do
				local v = randomValue(rng, 0, false)
				for _, indexed in { false, true } do
					local w = Codec.newWriter(64, indexed)
					local st = Codec.writeArgs(w, 20, 1, v)
					if st ~= 0 then
						table.insert(
							problems,
							string.format("#%d indexed=%s: encode status %d", i, tostring(indexed), st)
						)
						continue
					end
					local r = decodeWriter(w)
					if r.err ~= 0 or r.n ~= 1 or r.o ~= w.n or not same(r.argv[1], v) then
						table.insert(
							problems,
							string.format(
								"#%d indexed=%s: err %d, equal %s",
								i,
								tostring(indexed),
								r.err,
								tostring(same(r.argv[1], v))
							)
						)
					elseif indexed then
						if r.ctx.nodes ~= w.inlineNodes then
							table.insert(
								problems,
								string.format("#%d: inline nodes %d vs %d", i, r.ctx.nodes, w.inlineNodes)
							)
						end
						if w.nrefs > 0 then
							local wst, cost = walk(w.refs, w.nrefs)
							if wst ~= 0 or cost ~= NODE_CHARGE * w.nodes + w.sideBytes then
								table.insert(
									problems,
									string.format(
										"#%d: walk status %d cost %d vs %d",
										i,
										wst,
										cost,
										NODE_CHARGE * w.nodes + w.sideBytes
									)
								)
							end
						end
					end
				end
				if #problems >= 10 then
					break
				end
				if i % 300 == 0 then
					task.wait()
				end
			end
			expect(Codec._test.visitingCount()).toBe(0)
			expect(table.concat(problems, "\n")).toBe("")
		end, { timeout = 60 })

		it("random hostile sidecar tables never make walkSidecar throw or leak its stack", function()
			local rng = Random.new(99)
			local ctx = Codec.newReadCtx(true, true)
			local throws, leaks = 0, 0
			local first = ""
			for i = 1, 2000 do
				local n = rng:NextInteger(0, 5)
				local refs: { any } = table.create(n)
				for j = 1, n do
					if rng:NextNumber() < 0.9 then
						refs[j] = randomJunk(rng, 0)
					end
				end
				Codec.beginFrame(ctx, refs, n)
				local ok, st, cost = pcall(Codec.walkSidecar, refs, n, ctx)
				if not ok or type(st) ~= "number" or cost < 0 then
					throws += 1
					if first == "" then
						first = tostring(st)
					end
				end
				if Codec._test.walkStackCount() ~= 0 then
					leaks += 1
				end
				if i % 500 == 0 then
					task.wait()
				end
			end
			expect(first).toBe("")
			expect(throws).toBe(0)
			expect(leaks).toBe(0)
		end, { timeout = 60 })
	end)
end
