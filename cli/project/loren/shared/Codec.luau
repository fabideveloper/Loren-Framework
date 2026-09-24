--!strict
--!optimize 2
--[[
	Codec (lane: codec). Growable Writer, LEB128 varints, route heads, untyped tagged values, the
	sender's sidecar copy and the server's sidecar walk. Spec: design/loren-2.0/IMPLEMENTATION.md
	§3.5 (rules), §4.3 (heads), §4.5 (tags).

	Pure: requiring it creates nothing. The only module state is reused scratch (the cycle set of the
	encoder and the explicit stack of the sidecar walk), always left empty between calls.

	Decoders never throw on malformed input. A failure sets ctx.err (Constants.Decode; first failure
	wins, except that a structural failure replaces a MISSING_INSTANCE recorded earlier in an S->C
	message) and returns. Encoders return Constants.Encode statuses and run no user code (next, rawget
	and rawlen only; never __iter/__len/__index), so the shared scratch writer is never re-entered.
]]

local C = require(script.Parent.Constants)
local Types = require(script.Parent.Types)

type Writer = Types.Writer
type ReadCtx = Types.ReadCtx

-- Tags and limits as literals so hot-path comparisons compile to constants; checked against
-- Constants below.
local T_NIL = 0x00
local T_FALSE = 0x01
local T_TRUE = 0x02
local T_U8 = 0x03
local T_U16 = 0x04
local T_U32 = 0x05
local T_NU8 = 0x06
local T_NU16 = 0x07
local T_NU32 = 0x08
local T_F64 = 0x09
local T_STR32 = 0x0A
local T_STR = 0x0B
local T_BUF = 0x0C
local T_VEC3 = 0x0D
local T_VEC2 = 0x0E
local T_COLOR3 = 0x0F
local T_ARRAY = 0x10
local T_MAP = 0x11
local T_REF = 0x12
local T_BUF32 = 0x13
local T_FIXINT = 0x80

local MAX_DEPTH = 16
local MAX_NODES = 2048
local MAX_REFS = 255
local MAX_ARGC = 255 -- argc is a u8
local VARINT_MAX = 2097151
local NODE_CHARGE = 8
local F64_MAX = 1.7976931348623157e308
local D_MISSING_INSTANCE = 43 -- the one status an S->C decode records and decodes past
local REF_USED = 2 -- ReadCtx.refFlags bit1 (hostile): the slot was already referenced in this frame

do
	local tag, lim = C.Tag, C.Limit
	assert(
		tag.NIL == T_NIL
			and tag.FALSE == T_FALSE
			and tag.TRUE == T_TRUE
			and tag.U8 == T_U8
			and tag.U16 == T_U16
			and tag.U32 == T_U32
			and tag.NU8 == T_NU8
			and tag.NU16 == T_NU16
			and tag.NU32 == T_NU32
			and tag.F64 == T_F64
			and tag.STR32 == T_STR32
			and tag.STR == T_STR
			and tag.BUF == T_BUF
			and tag.VEC3 == T_VEC3
			and tag.VEC2 == T_VEC2
			and tag.COLOR3 == T_COLOR3
			and tag.ARRAY == T_ARRAY
			and tag.MAP == T_MAP
			and tag.REF == T_REF
			and tag.BUF32 == T_BUF32
			and tag.FixintBase == T_FIXINT
			and lim.MAX_DEPTH == MAX_DEPTH
			and lim.MAX_NODES == MAX_NODES
			and lim.MAX_REFS == MAX_REFS
			and lim.VARINT_MAX == VARINT_MAX
			and lim.NODE_CHARGE == NODE_CHARGE
			and lim.F64_MAX == F64_MAX
			and C.Decode.MISSING_INSTANCE == D_MISSING_INSTANCE
			and C.Encode.OK == 0
			and C.Decode.OK == 0,
		C.PREFIX .. "Codec constants are out of sync with Constants.luau"
	)
end

local E_TOO_DEEP = C.Encode.TOO_DEEP
local E_CYCLE = C.Encode.CYCLE
local E_TOO_MANY_ARGS = C.Encode.TOO_MANY_ARGS
local E_NEEDS_REF = C.Encode.NEEDS_REF
local E_BAD_TYPE = C.Encode.BAD_TYPE
local E_TOO_LONG = C.Encode.TOO_LONG
local E_TOO_MANY_NODES = C.Encode.TOO_MANY_NODES
local E_BAD_KEY = C.Encode.BAD_KEY

local D_OVERRUN = C.Decode.OVERRUN
local D_BAD_TAG = C.Decode.BAD_TAG
local D_BAD_VARINT = C.Decode.BAD_VARINT
local D_BAD_REF = C.Decode.BAD_REF
local D_NONFINITE = C.Decode.NONFINITE
local D_TOO_DEEP = C.Decode.TOO_DEEP
local D_TOO_MANY_NODES = C.Decode.TOO_MANY_NODES
local D_BAD_KEY = C.Decode.BAD_KEY
local D_TOO_MANY_ARGS = C.Decode.TOO_MANY_ARGS

-- Scratch. `visiting` holds the tables on the current encode path (cycle detection); every level
-- removes its own mark on every return path. walkT/walkD are the sidecar walk's explicit stack.
local visiting: { [any]: boolean } = {}
local walkT: { any } = {}
local walkD: { number } = {}

-- [[ Writer ]] -------------------------------------------------------------------------------------

local function grow(w: Writer, need: number)
	local cap = w.cap
	if cap < 16 then
		cap = 16
	end
	while cap < need do
		cap *= 2
	end
	local nb = buffer.create(cap)
	buffer.copy(nb, 0, w.buf, 0, w.n)
	w.buf = nb
	w.cap = cap
end

local function newWriter(cap: number, indexedRefs: boolean): Writer
	local size = if cap >= 16 then math.ceil(cap) else 16
	return {
		buf = buffer.create(size),
		cap = size,
		n = 0,
		refs = {},
		nrefs = 0,
		refBase = 0,
		indexedRefs = indexedRefs,
		inlineTables = true,
		unreliable = false,
		nodes = 0,
		sideBytes = 0,
		inlineNodes = 0,
		lossy = 0,
		errArg = 0,
	}
end

-- Once per message. Keeps buf/cap and the owner's flags (indexedRefs, inlineTables, unreliable).
local function resetWriter(w: Writer)
	w.n = 0
	local refs = w.refs
	for i = 1, w.nrefs do
		refs[i] = nil
	end
	w.nrefs = 0
	w.refBase = 0
	w.nodes = 0
	w.sideBytes = 0
	w.inlineNodes = 0
	w.lossy = 0
	w.errArg = 0
	-- Only non-empty if an encode was aborted by an engine error (e.g. a buffer over 1 GiB).
	if next(visiting) ~= nil then
		table.clear(visiting)
	end
end

-- Returns the write offset and advances n. Read w.buf only after this call (grow replaces it).
local function reserve(w: Writer, k: number): number
	local o = w.n
	local need = o + k
	if need > w.cap then
		grow(w, need)
	end
	w.n = need
	return o
end

local function writeU8(w: Writer, v: number)
	local o = reserve(w, 1)
	buffer.writeu8(w.buf, o, v)
end

local function writeU16(w: Writer, v: number)
	local o = reserve(w, 2)
	buffer.writeu16(w.buf, o, v)
end

local function writeU32(w: Writer, v: number)
	local o = reserve(w, 4)
	buffer.writeu32(w.buf, o, v)
end

local function writeI32(w: Writer, v: number)
	local o = reserve(w, 4)
	buffer.writei32(w.buf, o, v)
end

local function writeF32(w: Writer, v: number)
	local o = reserve(w, 4)
	buffer.writef32(w.buf, o, v)
end

local function writeF64(w: Writer, v: number)
	local o = reserve(w, 8)
	buffer.writef64(w.buf, o, v)
end

local function writeBytes(w: Writer, src: buffer, off: number, len: number)
	local o = reserve(w, len)
	buffer.copy(w.buf, o, src, off, len)
end

-- Raw bytes, no prefix.
local function writeString(w: Writer, s: string)
	local o = reserve(w, #s)
	buffer.writestring(w.buf, o, s)
end

-- [[ Varint ]] -------------------------------------------------------------------------------------

local function varintSize(v: number): number
	return if v < 0x80 then 1 elseif v < 0x4000 then 2 else 3
end

-- Minimal LEB128 of 0 <= v <= VARINT_MAX at o (capacity already reserved); returns the next offset.
local function putVarint(b: buffer, o: number, v: number): number
	if v < 0x80 then
		buffer.writeu8(b, o, v)
		return o + 1
	elseif v < 0x4000 then
		buffer.writeu8(b, o, bit32.bor(bit32.band(v, 0x7F), 0x80))
		buffer.writeu8(b, o + 1, bit32.rshift(v, 7))
		return o + 2
	end
	buffer.writeu8(b, o, bit32.bor(bit32.band(v, 0x7F), 0x80))
	buffer.writeu8(b, o + 1, bit32.bor(bit32.band(bit32.rshift(v, 7), 0x7F), 0x80))
	buffer.writeu8(b, o + 2, bit32.band(bit32.rshift(v, 14), 0x7F))
	return o + 3
end

local function writeVarint(w: Writer, v: number)
	local o = reserve(w, varintSize(v))
	putVarint(w.buf, o, v)
end

-- (value, next offset), or (-1, o) when truncated at lim or when the 3rd byte has 0x80 set.
-- Non-minimal forms are accepted.
@native
local function readVarint(b: buffer, o: number, lim: number): (number, number)
	if o >= lim then
		return -1, o
	end
	local b0 = buffer.readu8(b, o)
	if b0 < 0x80 then
		return b0, o + 1
	end
	if o + 1 >= lim then
		return -1, o
	end
	local b1 = buffer.readu8(b, o + 1)
	if b1 < 0x80 then
		return b0 - 0x80 + b1 * 0x80, o + 2
	end
	if o + 2 >= lim then
		return -1, o
	end
	local b2 = buffer.readu8(b, o + 2)
	if b2 >= 0x80 then
		return -1, o
	end
	return b0 - 0x80 + (b1 - 0x80) * 0x80 + b2 * 0x4000, o + 3
end

-- [[ Route head (§4.3) ]] ----------------------------------------------------------------------------

local function headSize(route: number): number
	return if route <= 0xDF then 1 elseif route <= 4063 then 2 else 3
end

-- route: 1..65535 (Routes guarantees the range).
local function writeHead(w: Writer, route: number)
	if route <= 0xDF then
		local o = reserve(w, 1)
		buffer.writeu8(w.buf, o, route)
	elseif route <= 4063 then
		local r = route - 224
		local o = reserve(w, 2)
		local b = w.buf
		buffer.writeu8(b, o, 0xE0 + bit32.rshift(r, 8))
		buffer.writeu8(b, o + 1, bit32.band(r, 0xFF))
	else
		local o = reserve(w, 3)
		local b = w.buf
		buffer.writeu8(b, o, 0xEF)
		buffer.writeu16(b, o + 1, route)
	end
end

-- (route > 0, next offset); (-op, next offset) for 0xF0..0xFF; (0, o) for 0x00, 0xEF 0000 or truncation.
@native
local function readHead(b: buffer, o: number, lim: number): (number, number)
	if o >= lim then
		return 0, o
	end
	local h = buffer.readu8(b, o)
	if h <= 0xDF then
		if h == 0 then
			return 0, o
		end
		return h, o + 1
	elseif h >= 0xF0 then
		return -h, o + 1
	elseif h == 0xEF then
		if o + 3 > lim then
			return 0, o
		end
		local r = buffer.readu16(b, o + 1)
		if r == 0 then
			return 0, o
		end
		return r, o + 3
	end
	if o + 2 > lim then
		return 0, o
	end
	return 224 + (h - 0xE0) * 256 + buffer.readu8(b, o + 1), o + 2
end

-- [[ Encode ]] -------------------------------------------------------------------------------------

-- Appends v to the sidecar (v may be nil). C->S also writes the frame-absolute varint index. Counts 1
-- node. Does not write a tag: typed Instance fields call it directly, writeValue writes REF first.
local function addRef(w: Writer, v: any)
	local n = w.nrefs + 1
	w.nrefs = n
	w.refs[n] = v
	w.nodes += 1
	if w.indexedRefs then
		local idx = w.refBase + n - 1
		local o = reserve(w, varintSize(idx))
		putVarint(w.buf, o, idx)
	end
end

-- Tagged string: STR (varint length), or STR32 above VARINT_MAX. Values and map keys.
local function writeStr(w: Writer, s: string)
	local len = #s
	local n = w.n
	if len <= VARINT_MAX then
		local hl = if len < 0x80 then 1 elseif len < 0x4000 then 2 else 3
		local need = n + 1 + hl + len
		if need > w.cap then
			grow(w, need)
		end
		local b = w.buf
		buffer.writeu8(b, n, T_STR)
		putVarint(b, n + 1, len)
		buffer.writestring(b, n + 1 + hl, s)
		w.n = need
	else
		local need = n + 5 + len
		if need > w.cap then
			grow(w, need)
		end
		local b = w.buf
		buffer.writeu8(b, n, T_STR32)
		buffer.writeu32(b, n + 1, len)
		buffer.writestring(b, n + 5, s)
		w.n = need
	end
end

-- Tagged buffer: BUF (varint length), or BUF32 above VARINT_MAX. The bytes are copied (a snapshot).
local function writeBuf(w: Writer, src: buffer)
	local len = buffer.len(src)
	local n = w.n
	if len <= VARINT_MAX then
		local hl = if len < 0x80 then 1 elseif len < 0x4000 then 2 else 3
		local need = n + 1 + hl + len
		if need > w.cap then
			grow(w, need)
		end
		local b = w.buf
		buffer.writeu8(b, n, T_BUF)
		putVarint(b, n + 1, len)
		buffer.copy(b, n + 1 + hl, src, 0, len)
		w.n = need
	else
		local need = n + 5 + len
		if need > w.cap then
			grow(w, need)
		end
		local b = w.buf
		buffer.writeu8(b, n, T_BUF32)
		buffer.writeu32(b, n + 1, len)
		buffer.copy(b, n + 5, src, 0, len)
		w.n = need
	end
end

-- REF tag + sidecar slot. A C->S message can never hold more than MAX_REFS refs (the frame header's
-- nrefs is a u8), so the 256th ref of one message fails here instead of producing an unsendable frame.
local function writeRef(w: Writer, v: any): number
	local indexed = w.indexedRefs
	if indexed and w.nrefs >= MAX_REFS then
		return E_TOO_MANY_NODES
	end
	local o = reserve(w, 1)
	buffer.writeu8(w.buf, o, T_REF)
	addRef(w, v)
	if indexed and w.nodes > MAX_NODES then
		return E_TOO_MANY_NODES
	end
	return 0
end

-- Deep copy of t (at `depth` inside the sidecar; values inside are depth + 1) for the sidecar.
-- Node rule: every kept value counts 1 node (w.nodes); string keys and string values count their
-- bytes (w.sideBytes). cs = C->S rules (buffers, keys, the node cap).
local function copyRec(w: Writer, t: { [any]: any }, depth: number, cs: boolean): (any, number)
	if visiting[t] then
		return nil, E_CYCLE
	end
	if getmetatable(t :: any) ~= nil then
		w.lossy += 1
	end
	visiting[t] = true
	local out: { [any]: any } = table.create(rawlen(t)) :: any
	local vd = depth + 1
	for k, x in next, t do
		local tx = type(x)
		if tx == "function" or tx == "thread" then
			w.lossy += 1
			continue
		end
		local tk = type(k)
		if tk == "string" then
			w.sideBytes += #k
		elseif tk == "number" then
			if cs and not (k >= -F64_MAX and k <= F64_MAX) then
				visiting[t] = nil
				return nil, E_BAD_KEY
			end
		elseif tk ~= "boolean" then
			if cs then
				visiting[t] = nil
				return nil, E_BAD_KEY
			elseif tk == "function" or tk == "thread" then
				w.lossy += 1
				continue
			end
		end
		if vd > MAX_DEPTH then
			visiting[t] = nil
			return nil, E_TOO_DEEP
		end
		local nodes = w.nodes + 1
		w.nodes = nodes
		if cs and nodes > MAX_NODES then
			visiting[t] = nil
			return nil, E_TOO_MANY_NODES
		end
		if tx == "table" then
			local copy, st = copyRec(w, x, vd, cs)
			if st ~= 0 then
				visiting[t] = nil
				return nil, st
			end
			out[k] = copy
		elseif tx == "string" then
			w.sideBytes += #x
			out[k] = x
		elseif tx == "buffer" then
			if cs then
				visiting[t] = nil
				return nil, E_BAD_TYPE
			end
			local len = buffer.len(x)
			local nb = buffer.create(len)
			buffer.copy(nb, 0, x, 0, len)
			out[k] = nb
		else
			out[k] = x
		end
	end
	visiting[t] = nil
	return out, 0
end

-- Sidecar deep copy for the sender: (copy, C.Encode status). depth = t's depth inside the sidecar
-- (writeValue passes 0: the server's walkSidecar counts depth from each ref, not from the message).
local function copyTable(w: Writer, t: { [any]: any }, depth: number): (any, number)
	return copyRec(w, t, depth, w.indexedRefs)
end

-- One tagged value (§4.5). Returns a C.Encode status; on failure the message is partial and the
-- caller discards it (resetWriter).
@native
local function writeValue(w: Writer, v: any, depth: number): number
	if depth > MAX_DEPTH then
		return E_TOO_DEEP
	end
	if w.indexedRefs then
		local nodes = w.inlineNodes + 1
		w.inlineNodes = nodes
		if nodes > MAX_NODES then
			return E_TOO_MANY_NODES
		end
	end
	local t = type(v)
	if t == "number" then
		local n = w.n
		if n + 9 > w.cap then
			grow(w, n + 9)
		end
		local b = w.buf
		if v >= 0 then
			-- `v % 1 == 0` is false for NaN and inf. -0 passes it (and v >= 0), so it is excluded here
			-- (1 / -0 is -inf) and falls through to F64, which keeps its sign. The engine flushes
			-- subnormal results to zero, so `5e-324 % 1 == 0` is true there: a non-zero fixint must also
			-- be >= 1 (and a negative integer <= -1, below), which sends subnormals of either sign as F64
			-- (§3.5 "otherwise F64 (exact)").
			if v <= 127 and v % 1 == 0 and (v >= 1 or (v == 0 and 1 / v > 0)) then
				buffer.writeu8(b, n, T_FIXINT + v)
				w.n = n + 1
				return 0
			elseif v > 127 and v <= 0xFFFFFFFF and v % 1 == 0 then
				if v <= 0xFF then
					buffer.writeu8(b, n, T_U8)
					buffer.writeu8(b, n + 1, v)
					w.n = n + 2
				elseif v <= 0xFFFF then
					buffer.writeu8(b, n, T_U16)
					buffer.writeu16(b, n + 1, v)
					w.n = n + 3
				else
					buffer.writeu8(b, n, T_U32)
					buffer.writeu32(b, n + 1, v)
					w.n = n + 5
				end
				return 0
			end
		elseif v >= -0xFFFFFFFF and v <= -1 and v % 1 == 0 then
			local m = -v
			if m <= 0xFF then
				buffer.writeu8(b, n, T_NU8)
				buffer.writeu8(b, n + 1, m)
				w.n = n + 2
			elseif m <= 0xFFFF then
				buffer.writeu8(b, n, T_NU16)
				buffer.writeu16(b, n + 1, m)
				w.n = n + 3
			else
				buffer.writeu8(b, n, T_NU32)
				buffer.writeu32(b, n + 1, m)
				w.n = n + 5
			end
			return 0
		end
		-- Fractions, -0, NaN, +-inf and integers beyond 32 bits: exact f64 (the receiver decides).
		buffer.writeu8(b, n, T_F64)
		buffer.writef64(b, n + 1, v)
		w.n = n + 9
		return 0
	elseif t == "string" then
		writeStr(w, v)
		return 0
	elseif t == "table" then
		if visiting[v] then
			return E_CYCLE
		end
		if w.inlineTables and getmetatable(v) == nil then
			-- Classify with one raw pass: a plain array (keys exactly 1..rawlen) or a string map, with no
			-- function/thread values (NIL is never valid inside ARRAY/MAP, so such tables use the sidecar).
			local len = rawlen(v)
			local count = 0
			local arr = true
			local map = true
			local plain = true
			for k, x in next, v do
				local tx = type(x)
				if tx == "function" or tx == "thread" then
					plain = false
					break
				end
				count += 1
				if type(k) == "string" then
					arr = false
				else
					map = false
					if arr and not (type(k) == "number" and k >= 1 and k <= len and k % 1 == 0) then
						arr = false
					end
				end
				if not (arr or map) then
					plain = false
					break
				end
			end
			if plain then
				if arr and count == len then
					-- ARRAY (an empty table is ARRAY 0)
					if len > VARINT_MAX then
						return E_TOO_LONG
					end
					local o = reserve(w, 1 + varintSize(len))
					local b = w.buf
					buffer.writeu8(b, o, T_ARRAY)
					putVarint(b, o + 1, len)
					visiting[v] = true
					local d = depth + 1
					for i = 1, len do
						local st = writeValue(w, rawget(v, i), d)
						if st ~= 0 then
							visiting[v] = nil
							return st
						end
					end
					visiting[v] = nil
					return 0
				elseif map then
					-- MAP: count >= 1 string keys; keys are STR values and are not counted as nodes
					if count > VARINT_MAX then
						return E_TOO_LONG
					end
					local o = reserve(w, 1 + varintSize(count))
					local b = w.buf
					buffer.writeu8(b, o, T_MAP)
					putVarint(b, o + 1, count)
					visiting[v] = true
					local d = depth + 1
					for k, x in next, v do
						writeStr(w, k)
						local st = writeValue(w, x, d)
						if st ~= 0 then
							visiting[v] = nil
							return st
						end
					end
					visiting[v] = nil
					return 0
				end
			end
		end
		-- Mixed, sparse, non-string keys, a metatable, a function/thread value or inlineTables == false.
		if w.unreliable then
			return E_NEEDS_REF
		end
		local copy, st = copyRec(w, v, 0, w.indexedRefs)
		if st ~= 0 then
			return st
		end
		return writeRef(w, copy)
	elseif t == "boolean" then
		local o = reserve(w, 1)
		buffer.writeu8(w.buf, o, if v then T_TRUE else T_FALSE)
		return 0
	elseif t == "nil" then
		local o = reserve(w, 1)
		buffer.writeu8(w.buf, o, T_NIL)
		return 0
	elseif t == "vector" then
		local o = reserve(w, 13)
		local b = w.buf
		buffer.writeu8(b, o, T_VEC3)
		buffer.writef32(b, o + 1, v.X)
		buffer.writef32(b, o + 5, v.Y)
		buffer.writef32(b, o + 9, v.Z)
		return 0
	elseif t == "userdata" then
		local ty = typeof(v)
		if ty == "Vector2" then
			local o = reserve(w, 9)
			local b = w.buf
			buffer.writeu8(b, o, T_VEC2)
			buffer.writef32(b, o + 1, v.X)
			buffer.writef32(b, o + 5, v.Y)
			return 0
		elseif ty == "Color3" then
			local o = reserve(w, 13)
			local b = w.buf
			buffer.writeu8(b, o, T_COLOR3)
			buffer.writef32(b, o + 1, v.R)
			buffer.writef32(b, o + 5, v.G)
			buffer.writef32(b, o + 9, v.B)
			return 0
		elseif ty == "Vector3" then -- engines where Vector3 is not the native vector type
			local o = reserve(w, 13)
			local b = w.buf
			buffer.writeu8(b, o, T_VEC3)
			buffer.writef32(b, o + 1, v.X)
			buffer.writef32(b, o + 5, v.Y)
			buffer.writef32(b, o + 9, v.Z)
			return 0
		end
		-- Instance, EnumItem, CFrame, UDim2, ...: engine serialization through the sidecar.
		if w.unreliable then
			return E_NEEDS_REF
		end
		return writeRef(w, v)
	elseif t == "buffer" then
		writeBuf(w, v)
		return 0
	end
	-- function / thread: nil, as 1.5.1 remotes did (the caller warns once per route in Studio).
	w.lossy += 1
	local o = reserve(w, 1)
	buffer.writeu8(w.buf, o, T_NIL)
	return 0
end

-- argc:u8 + n tagged values (nil holes kept). n > max -> TOO_MANY_ARGS with errArg = max + 1.
@native
local function writeArgs(w: Writer, max: number, n: number, ...: any): number
	if n > max or n > MAX_ARGC then
		w.errArg = math.min(max, MAX_ARGC) + 1
		return E_TOO_MANY_ARGS
	end
	local o = reserve(w, 1)
	buffer.writeu8(w.buf, o, n)
	for i = 1, n do
		local st = writeValue(w, (select(i, ...)), 0)
		if st ~= 0 then
			w.errArg = i
			return st
		end
	end
	return 0
end

-- [[ Decode ]] -------------------------------------------------------------------------------------

-- First failure wins, except that a failure after a MISSING_INSTANCE (S->C only: recorded, then the
-- message is decoded to its end) replaces it, so a corrupt stream still aborts the frame.
local function fail(ctx: ReadCtx, code: number)
	local e = ctx.err
	if e == 0 or e == D_MISSING_INSTANCE then
		ctx.err = code
	end
end

-- readVarint returned -1 at o: three bytes were available -> overlong, else truncated.
local function failVarint(ctx: ReadCtx, o: number, lim: number)
	fail(ctx, if lim - o >= 3 then D_BAD_VARINT else D_OVERRUN)
end

-- One tagged value from b[o, lim). Returns (value, next offset); on failure (nil, offset <= lim) with
-- ctx.err set. Hostile (server): depth, node, finite and REF-flag rules. Non-hostile (client): only
-- structural failures; nesting beyond MAX_DEPTH (which no honest encoder writes) is BAD_TAG, so a
-- corrupt stream cannot recurse without bound.
@native
local function readValue(b: buffer, o: number, lim: number, ctx: ReadCtx, depth: number): (any, number)
	local hostile = ctx.hostile
	local nodes = ctx.nodes + 1
	ctx.nodes = nodes
	if depth > MAX_DEPTH then
		fail(ctx, if hostile then D_TOO_DEEP else D_BAD_TAG)
		return nil, o
	end
	if hostile and nodes > MAX_NODES then
		fail(ctx, D_TOO_MANY_NODES)
		return nil, o
	end
	if o >= lim then
		fail(ctx, D_OVERRUN)
		return nil, o
	end
	local tag = buffer.readu8(b, o)
	o += 1
	if tag >= T_FIXINT then
		return tag - T_FIXINT, o
	elseif tag <= T_TRUE then
		if tag == T_NIL then
			return nil, o
		end
		return tag == T_TRUE, o
	elseif tag <= T_NU32 then
		local m = 0
		if tag == T_U8 or tag == T_NU8 then
			if o + 1 > lim then
				fail(ctx, D_OVERRUN)
				return nil, o
			end
			m = buffer.readu8(b, o)
			o += 1
		elseif tag == T_U16 or tag == T_NU16 then
			if o + 2 > lim then
				fail(ctx, D_OVERRUN)
				return nil, o
			end
			m = buffer.readu16(b, o)
			o += 2
		else
			if o + 4 > lim then
				fail(ctx, D_OVERRUN)
				return nil, o
			end
			m = buffer.readu32(b, o)
			o += 4
		end
		if tag >= T_NU8 then
			return -m, o
		end
		return m, o
	elseif tag == T_F64 then
		if o + 8 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local v = buffer.readf64(b, o)
		if hostile and not (v >= -F64_MAX and v <= F64_MAX) and not ctx.allowNonFinite then
			fail(ctx, D_NONFINITE)
			return nil, o
		end
		return v, o + 8
	elseif tag == T_STR then
		local len, p = readVarint(b, o, lim)
		if len < 0 then
			failVarint(ctx, o, lim)
			return nil, o
		end
		if len > lim - p then
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		return buffer.readstring(b, p, len), p + len
	elseif tag == T_ARRAY then
		local count, p = readVarint(b, o, lim)
		if count < 0 then
			failVarint(ctx, o, lim)
			return nil, o
		end
		if count > lim - p then -- every element is at least one byte
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		if hostile then
			-- Every element counts one node. Claims add up per message, so nested headers cannot all
			-- preallocate against the same remaining bytes (an honest message claims <= its nodes).
			local claimed = ctx.claimed + count
			if nodes + count > MAX_NODES or claimed > MAX_NODES then
				fail(ctx, D_TOO_MANY_NODES)
				return nil, p
			end
			ctx.claimed = claimed
		end
		local t = table.create(count)
		local d = depth + 1
		for i = 1, count do
			if p < lim and buffer.readu8(b, p) == T_NIL then
				fail(ctx, D_BAD_TAG)
				return nil, p
			end
			local v, q = readValue(b, p, lim, ctx, d)
			p = q
			local e = ctx.err
			if e ~= 0 and e ~= D_MISSING_INSTANCE then
				return nil, p
			end
			t[i] = v
		end
		return t, p
	elseif tag == T_MAP then
		local count, p = readVarint(b, o, lim)
		if count < 0 then
			failVarint(ctx, o, lim)
			return nil, o
		end
		if count * 3 > lim - p then -- every pair is at least 3 bytes (0B 00 + a 1-byte value)
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		if hostile and nodes + count > MAX_NODES then
			fail(ctx, D_TOO_MANY_NODES)
			return nil, p
		end
		local t: { [string]: any } = {}
		local d = depth + 1
		for _ = 1, count do
			if p >= lim then
				fail(ctx, D_OVERRUN)
				return nil, p
			end
			local kt = buffer.readu8(b, p)
			local klen = 0
			local q = 0
			if kt == T_STR then
				klen, q = readVarint(b, p + 1, lim)
				if klen < 0 then
					failVarint(ctx, p + 1, lim)
					return nil, p
				end
			elseif kt == T_STR32 then
				if p + 5 > lim then
					fail(ctx, D_OVERRUN)
					return nil, p
				end
				klen = buffer.readu32(b, p + 1)
				q = p + 5
			else
				fail(ctx, D_BAD_TAG)
				return nil, p
			end
			if klen > lim - q then
				fail(ctx, D_OVERRUN)
				return nil, q
			end
			local key = buffer.readstring(b, q, klen)
			p = q + klen
			if p < lim and buffer.readu8(b, p) == T_NIL then
				fail(ctx, D_BAD_TAG)
				return nil, p
			end
			local v, r = readValue(b, p, lim, ctx, d)
			p = r
			local e = ctx.err
			if e ~= 0 and e ~= D_MISSING_INSTANCE then
				return nil, p
			end
			t[key] = v
		end
		return t, p
	elseif tag == T_REF then
		local refs = ctx.refs
		if ctx.indexed then
			local idx, p = readVarint(b, o, lim)
			if idx < 0 then
				failVarint(ctx, o, lim)
				return nil, o
			end
			if idx >= ctx.nrefs then
				fail(ctx, D_BAD_REF)
				return nil, p
			end
			if hostile then
				-- One reference per slot: a reused index would deliver the same (byte-charged once)
				-- sidecar value again and again. Honest encoders never reuse one.
				local flags = ctx.refFlags
				local f = flags[idx + 1] or 0
				if f >= REF_USED then
					fail(ctx, D_BAD_REF)
					return nil, p
				end
				flags[idx + 1] = f + REF_USED
				if bit32.band(f, 1) ~= 0 and not ctx.allowNonFinite then
					fail(ctx, D_NONFINITE)
					return nil, p
				end
			end
			-- nil is legal: streamed out or never replicated
			if refs == nil then
				return nil, p
			end
			return rawget(refs, idx + 1), p
		end
		local c = ctx.cursor + 1
		ctx.cursor = c
		if refs == nil then
			return nil, o
		end
		return rawget(refs, c), o
	elseif tag == T_VEC3 then
		if o + 12 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local x = buffer.readf32(b, o)
		local y = buffer.readf32(b, o + 4)
		local z = buffer.readf32(b, o + 8)
		if
			hostile
			and not (x >= -F64_MAX and x <= F64_MAX and y >= -F64_MAX and y <= F64_MAX and z >= -F64_MAX and z <= F64_MAX)
			and not ctx.allowNonFinite
		then
			fail(ctx, D_NONFINITE)
			return nil, o
		end
		return Vector3.new(x, y, z), o + 12
	elseif tag == T_BUF then
		local len, p = readVarint(b, o, lim)
		if len < 0 then
			failVarint(ctx, o, lim)
			return nil, o
		end
		if len > lim - p then
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		local nb = buffer.create(len)
		buffer.copy(nb, 0, b, p, len)
		return nb, p + len
	elseif tag == T_VEC2 then
		if o + 8 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local x = buffer.readf32(b, o)
		local y = buffer.readf32(b, o + 4)
		if
			hostile
			and not (x >= -F64_MAX and x <= F64_MAX and y >= -F64_MAX and y <= F64_MAX)
			and not ctx.allowNonFinite
		then
			fail(ctx, D_NONFINITE)
			return nil, o
		end
		return Vector2.new(x, y), o + 8
	elseif tag == T_COLOR3 then
		if o + 12 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local r = buffer.readf32(b, o)
		local g = buffer.readf32(b, o + 4)
		local bl = buffer.readf32(b, o + 8)
		if
			hostile
			and not (r >= -F64_MAX and r <= F64_MAX and g >= -F64_MAX and g <= F64_MAX and bl >= -F64_MAX and bl <= F64_MAX)
			and not ctx.allowNonFinite
		then
			fail(ctx, D_NONFINITE)
			return nil, o
		end
		return Color3.new(r, g, bl), o + 12
	elseif tag == T_STR32 then
		if o + 4 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local len = buffer.readu32(b, o)
		local p = o + 4
		if len > lim - p then
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		return buffer.readstring(b, p, len), p + len
	elseif tag == T_BUF32 then
		if o + 4 > lim then
			fail(ctx, D_OVERRUN)
			return nil, o
		end
		local len = buffer.readu32(b, o)
		local p = o + 4
		if len > lim - p then
			fail(ctx, D_OVERRUN)
			return nil, p
		end
		local nb = buffer.create(len)
		buffer.copy(nb, 0, b, p, len)
		return nb, p + len
	end
	-- 0x14..0x7F
	fail(ctx, D_BAD_TAG)
	return nil, o
end

-- argc:u8 + argc values into argv[1..argc]. Returns (number of argv slots written, next offset); on
-- failure ctx.err is set, ctx.errArg names the argument (TOO_MANY_ARGS: max + 1) and the count
-- covers only the slots written, so the caller can clear exactly those.
@native
local function readArgs(b: buffer, o: number, lim: number, ctx: ReadCtx, argv: { any }, max: number): (number, number)
	if o >= lim then
		fail(ctx, D_OVERRUN)
		return 0, o
	end
	local argc = buffer.readu8(b, o)
	o += 1
	if argc > lim - o then -- every value is at least one byte
		fail(ctx, D_OVERRUN)
		return 0, o
	end
	if ctx.hostile and argc > max then
		fail(ctx, D_TOO_MANY_ARGS)
		if ctx.errArg == 0 then
			ctx.errArg = max + 1
		end
		return 0, o
	end
	for i = 1, argc do
		local v, p = readValue(b, o, lim, ctx, 0)
		o = p
		local e = ctx.err
		if e ~= 0 and e ~= D_MISSING_INSTANCE then
			if ctx.errArg == 0 then
				ctx.errArg = i
			end
			return i - 1, o
		end
		argv[i] = v
	end
	return argc, o
end

-- [[ Sidecar walk (server, C->S) ]] ---------------------------------------------------------------

local function fin(x: number): boolean
	return x >= -F64_MAX and x <= F64_MAX
end

local function finVector3(v: any): boolean
	return fin(v.X) and fin(v.Y) and fin(v.Z)
end

-- false when a datatype listed in §3.5 walkSidecar has a non-finite component. Unlisted datatypes
-- pass (handlers validate them).
local function datatypeFinite(v: any): boolean
	local ty = typeof(v)
	if ty == "Instance" or ty == "EnumItem" then
		return true
	elseif ty == "CFrame" then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = v:GetComponents()
		return fin(x)
			and fin(y)
			and fin(z)
			and fin(r00)
			and fin(r01)
			and fin(r02)
			and fin(r10)
			and fin(r11)
			and fin(r12)
			and fin(r20)
			and fin(r21)
			and fin(r22)
	elseif ty == "Vector3" then
		return finVector3(v)
	elseif ty == "Vector2" then
		return fin(v.X) and fin(v.Y)
	elseif ty == "Color3" then
		return fin(v.R) and fin(v.G) and fin(v.B)
	elseif ty == "UDim" then
		return fin(v.Scale) and fin(v.Offset)
	elseif ty == "UDim2" then
		local x, y = v.X, v.Y
		return fin(x.Scale) and fin(x.Offset) and fin(y.Scale) and fin(y.Offset)
	elseif ty == "Rect" then
		local lo, hi = v.Min, v.Max
		return fin(lo.X) and fin(lo.Y) and fin(hi.X) and fin(hi.Y)
	elseif ty == "NumberRange" then
		return fin(v.Min) and fin(v.Max)
	elseif ty == "Ray" then
		return finVector3(v.Origin) and finVector3(v.Direction)
	elseif ty == "Region3" then
		return datatypeFinite(v.CFrame) and finVector3(v.Size)
	elseif ty == "NumberSequence" then
		for _, kp in v.Keypoints do
			if not (fin(kp.Time) and fin(kp.Value) and fin(kp.Envelope)) then
				return false
			end
		end
		return true
	elseif ty == "ColorSequence" then
		for _, kp in v.Keypoints do
			local c = kp.Value
			if not (fin(kp.Time) and fin(c.R) and fin(c.G) and fin(c.B)) then
				return false
			end
		end
		return true
	elseif ty == "PhysicalProperties" then
		return fin(v.Density)
			and fin(v.Friction)
			and fin(v.Elasticity)
			and fin(v.FrictionWeight)
			and fin(v.ElasticityWeight)
	end
	return true
end

-- Validates the sidecar of one C->S frame before any message is read (after admission). Returns
-- (C.Decode status, byte cost = NODE_CHARGE * nodes + string bytes); any non-zero status is a Sidecar
-- violation. Sets ctx.refFlags[i] = 1 when ref i holds a non-finite number or datatype component.
-- The walk is iterative (explicit stack) and bounded by MAX_NODES: every table visited was counted as
-- a node, so neither huge nor deeply nested input can make it recurse or loop without bound.
@native
local function walkSidecar(refs: { any }, nrefs: number, ctx: ReadCtx): (number, number)
	local flags = ctx.refFlags
	local nodes = 0
	local bytes = 0
	for i = 1, nrefs do
		nodes += 1 -- every ref slot, nil included
		local v = rawget(refs, i)
		local tv = type(v)
		local flag = 0
		if tv == "table" then
			local status = 0
			local sp = 1
			walkT[1] = v
			walkD[1] = 0
			while sp > 0 do
				local t = walkT[sp]
				local vd = walkD[sp] + 1
				walkT[sp] = nil
				sp -= 1
				for k, x in next, t do
					local tk = type(k)
					if tk == "string" then
						bytes += #k
					elseif tk == "number" then
						if not (k >= -F64_MAX and k <= F64_MAX) then
							status = D_BAD_KEY
							break
						end
					elseif tk ~= "boolean" then
						status = D_BAD_KEY
						break
					end
					if vd > MAX_DEPTH then
						status = D_TOO_DEEP
						break
					end
					nodes += 1
					if nodes > MAX_NODES then
						status = D_TOO_MANY_NODES
						break
					end
					local tx = type(x)
					if tx == "table" then
						sp += 1
						walkT[sp] = x
						walkD[sp] = vd
					elseif tx == "number" then
						if not (x >= -F64_MAX and x <= F64_MAX) then
							flag = 1
						end
					elseif tx == "string" then
						bytes += #x
					elseif tx == "vector" then
						if not (fin(x.X) and fin(x.Y) and fin(x.Z)) then
							flag = 1
						end
					elseif tx == "userdata" then
						if flag == 0 and not datatypeFinite(x) then
							flag = 1
						end
					elseif tx ~= "boolean" then -- function, thread, buffer
						status = D_BAD_REF
						break
					end
				end
				if status ~= 0 then
					break
				end
			end
			if status ~= 0 then
				for j = 1, sp do
					walkT[j] = nil
				end
				return status, NODE_CHARGE * nodes + bytes
			end
		elseif tv == "vector" then
			if not (fin(v.X) and fin(v.Y) and fin(v.Z)) then
				flag = 1
			end
		elseif tv == "userdata" then
			if not datatypeFinite(v) then
				flag = 1
			end
		elseif tv ~= "nil" then
			-- string, number, boolean, buffer, function, thread: honest encoders inline these
			return D_BAD_REF, NODE_CHARGE * nodes + bytes
		end
		if nodes > MAX_NODES then
			return D_TOO_MANY_NODES, NODE_CHARGE * nodes + bytes
		end
		flags[i] = flag
	end
	return 0, NODE_CHARGE * nodes + bytes
end

-- [[ Read contexts ]] -------------------------------------------------------------------------------

local function newReadCtx(hostile: boolean, indexed: boolean): ReadCtx
	return {
		refs = nil,
		nrefs = 0,
		cursor = 0,
		indexed = indexed,
		hostile = hostile,
		allowNonFinite = false,
		err = 0,
		errArg = 0,
		nodes = 0,
		claimed = 0,
		refFlags = table.create(MAX_REFS, 0),
	}
end

-- Per frame: clears the previous frame's ref flags (non-finite and used bits). S->C passes
-- nrefs = 0 (unused; refs are consumed in order).
local function beginFrame(ctx: ReadCtx, refs: { any }?, nrefs: number)
	local flags = ctx.refFlags
	for i = 1, ctx.nrefs do
		flags[i] = 0
	end
	ctx.refs = refs
	ctx.nrefs = nrefs
	ctx.cursor = 0
	ctx.err = 0
	ctx.errArg = 0
end

-- Per message (the ref cursor is per frame and is kept).
local function beginMessage(ctx: ReadCtx, allowNonFinite: boolean)
	ctx.err = 0
	ctx.errArg = 0
	ctx.nodes = 0
	ctx.claimed = 0
	ctx.allowNonFinite = allowNonFinite
end

-- [[ Module ]] -------------------------------------------------------------------------------------

local function reset()
	table.clear(visiting)
	table.clear(walkT)
	table.clear(walkD)
end

local function count(t: { [any]: any }): number
	local n = 0
	for _ in next, t do
		n += 1
	end
	return n
end

return table.freeze({
	newWriter = newWriter,
	resetWriter = resetWriter,
	reserve = reserve,
	writeU8 = writeU8,
	writeU16 = writeU16,
	writeU32 = writeU32,
	writeI32 = writeI32,
	writeF32 = writeF32,
	writeF64 = writeF64,
	writeBytes = writeBytes,
	writeString = writeString,
	writeVarint = writeVarint,
	varintSize = varintSize,
	readVarint = readVarint,
	writeHead = writeHead,
	headSize = headSize,
	readHead = readHead,
	addRef = addRef,
	writeValue = writeValue,
	writeArgs = writeArgs,
	readValue = readValue,
	readArgs = readArgs,
	copyTable = copyTable,
	walkSidecar = walkSidecar,
	newReadCtx = newReadCtx,
	beginFrame = beginFrame,
	beginMessage = beginMessage,
	_reset = reset,
	_test = table.freeze({
		-- tables on the encoder's cycle path (0 between calls)
		visitingCount = function(): number
			return count(visiting)
		end,
		-- tables left on the sidecar walk stack (0 between calls)
		walkStackCount = function(): number
			return count(walkT)
		end,
		datatypeFinite = datatypeFinite,
	}),
})
